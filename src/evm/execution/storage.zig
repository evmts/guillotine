const std = @import("std");
const Operation = @import("../opcodes/operation.zig");
const ExecutionError = @import("execution_error.zig");
const Stack = @import("../stack/stack.zig");
const Frame = @import("../frame/frame.zig");
const Vm = @import("../evm.zig");
const gas_constants = @import("../constants/gas_constants.zig");
const primitives = @import("primitives");
const storage_costs = @import("../gas/storage_costs.zig");

pub fn op_sload(pc: usize, interpreter: *Operation.Interpreter, state: *Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;

    const frame = @as(*Frame, @ptrCast(@alignCast(state)));
    const vm = @as(*Vm, @ptrCast(@alignCast(interpreter)));

    if (frame.stack.size < 1) unreachable;

    const slot = frame.stack.peek_unsafe().*;

    if (vm.chain_rules.is_berlin) {
        const is_cold = frame.contract.mark_storage_slot_warm(frame.allocator, slot, null) catch {
            return ExecutionError.Error.OutOfMemory;
        };
        const gas_cost = if (is_cold) gas_constants.ColdSloadCost else gas_constants.WarmStorageReadCost;
        try frame.consume_gas(gas_cost);
    } else {
        // Pre-Berlin: gas is handled by jump table constant_gas
        // For Istanbul, this would be 800 gas set in the jump table
    }

    const value = vm.state.get_storage(frame.contract.address, slot);

    frame.stack.set_top_unsafe(value);

    return Operation.ExecutionResult{};
}

/// SSTORE opcode - Store value in persistent storage
pub fn op_sstore(pc: usize, interpreter: *Operation.Interpreter, state: *Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;

    const frame = @as(*Frame, @ptrCast(@alignCast(state)));
    const vm = @as(*Vm, @ptrCast(@alignCast(interpreter)));

    if (frame.is_static) {
        @branchHint(.unlikely);
        return ExecutionError.Error.WriteProtection;
    }

    // EIP-1706: Disable SSTORE with gasleft lower than call stipend (2300)
    // This prevents reentrancy attacks by ensuring enough gas remains for exception handling
    if (vm.chain_rules.is_istanbul and frame.gas_remaining <= gas_constants.SstoreSentryGas) {
        @branchHint(.unlikely);
        return ExecutionError.Error.OutOfGas;
    }

    if (frame.stack.size < 2) unreachable;

    // Stack order: [..., value, slot] where slot is on top
    const popped = frame.stack.pop2_unsafe();
    const value = popped.a; // First popped (was second from top)
    const slot = popped.b; // Second popped (was top)

    const current_value = vm.state.get_storage(frame.contract.address, slot);

    const is_cold = frame.contract.mark_storage_slot_warm(frame.allocator, slot, null) catch {
        return ExecutionError.Error.OutOfMemory;
    };

    var total_gas: u64 = 0;

    if (is_cold) {
        @branchHint(.unlikely);
        total_gas += gas_constants.ColdSloadCost;
    }

    // Get storage cost based on current hardfork and value change
    const hardfork = vm.chain_rules.getHardfork();
    const cost = storage_costs.calculateStorageCost(hardfork, current_value, value);
    total_gas += cost.gas;

    // Consume all gas at once
    try frame.consume_gas(total_gas);

    try vm.state.set_storage(frame.contract.address, slot, value);
    
    // Apply refund if any
    if (cost.refund > 0) {
        frame.contract.add_gas_refund(cost.refund);
    }

    return Operation.ExecutionResult{};
}

pub fn op_tload(pc: usize, interpreter: *Operation.Interpreter, state: *Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;

    const frame = @as(*Frame, @ptrCast(@alignCast(state)));
    const vm = @as(*Vm, @ptrCast(@alignCast(interpreter)));

    // Gas is already handled by jump table constant_gas = 100

    if (frame.stack.size < 1) unreachable;

    // Get slot from top of stack unsafely - bounds checking is done in jump_table.zig
    const slot = frame.stack.peek_unsafe().*;

    const value = vm.state.get_transient_storage(frame.contract.address, slot);

    // Replace top of stack with loaded value unsafely - bounds checking is done in jump_table.zig
    frame.stack.set_top_unsafe(value);

    return Operation.ExecutionResult{};
}

pub fn op_tstore(pc: usize, interpreter: *Operation.Interpreter, state: *Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;

    const frame = @as(*Frame, @ptrCast(@alignCast(state)));
    const vm = @as(*Vm, @ptrCast(@alignCast(interpreter)));

    if (frame.is_static) {
        @branchHint(.unlikely);
        return ExecutionError.Error.WriteProtection;
    }

    // Gas is already handled by jump table constant_gas = 100

    if (frame.stack.size < 2) unreachable;

    // Pop two values unsafely using batch operation - bounds checking is done in jump_table.zig
    // Stack order: [..., value, slot] where slot is on top
    const popped = frame.stack.pop2_unsafe();
    const value = popped.a; // First popped (was second from top)
    const slot = popped.b; // Second popped (was top)

    try vm.state.set_transient_storage(frame.contract.address, slot, value);

    return Operation.ExecutionResult{};
}

