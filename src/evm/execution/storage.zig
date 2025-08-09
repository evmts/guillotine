const std = @import("std");
const ExecutionError = @import("execution_error.zig");
const Frame = @import("../frame.zig").Frame;
const GasConstants = @import("primitives").GasConstants;
const primitives = @import("primitives");
const storage_costs = @import("../gas/storage_costs.zig");

pub fn op_sload(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    std.debug.assert(frame.stack.size() >= 1);

    const slot = frame.stack.peek_unsafe().*;

    if (frame.is_at_least(.BERLIN)) {
        const is_cold = frame.mark_storage_slot_warm(slot) catch {
            return ExecutionError.Error.OutOfMemory;
        };
        const gas_cost = if (is_cold) GasConstants.ColdSloadCost else GasConstants.WarmStorageReadCost;
        try frame.consume_gas(gas_cost);
    } else {
        // Pre-Berlin: gas is handled by jump table constant_gas
        // For Istanbul, this would be 800 gas set in the jump table
    }

    const value = frame.get_storage(slot);

    frame.stack.set_top_unsafe(value);
}

/// SSTORE opcode - Store value in persistent storage
pub fn op_sstore(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    if (frame.is_static()) {
        @branchHint(.unlikely);
        return ExecutionError.Error.WriteProtection;
    }

    // EIP-1706: Disable SSTORE with gasleft lower than call stipend (2300)
    // This prevents reentrancy attacks by ensuring enough gas remains for exception handling
    if (frame.is_at_least(.ISTANBUL) and frame.gas_remaining <= GasConstants.SstoreSentryGas) {
        @branchHint(.unlikely);
        return ExecutionError.Error.OutOfGas;
    }

    std.debug.assert(frame.stack.size() >= 2);

    // Stack order: [..., value, slot] where slot is on top
    const popped = frame.stack.pop2_unsafe();
    const value = popped.a; // First popped (was second from top)
    const slot = popped.b; // Second popped (was top)

    const current_value = frame.get_storage(slot);
    const original_value = frame.get_original_storage(slot);

    const is_cold = frame.mark_storage_slot_warm(slot) catch {
        return ExecutionError.Error.OutOfMemory;
    };

    var total_gas: u64 = 0;
    // Compute full EIP-2200/EIP-3529 cost using original/current/new
    const hardfork = frame.getHardfork();
    const cost = storage_costs.calculateSstoreCost(hardfork, original_value, current_value, value, is_cold);
    total_gas += cost.gas;

    // Consume all gas at once
    try frame.consume_gas(total_gas);

    try frame.set_storage(slot, value);

    // Apply refund delta if any
    if (cost.refund > 0) frame.add_gas_refund(cost.refund);
}

pub fn op_tload(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    // TODO: Add hardfork validation for EIP-1153 (Cancun)
    // if (!frame.flags.is_eip1153) {
    //     return ExecutionError.Error.InvalidOpcode;
    // }

    // Gas is already handled by jump table constant_gas = 100

    std.debug.assert(frame.stack.size() >= 1);

    // Get slot from top of stack unsafely - bounds checking is done in jump_table.zig
    const slot = frame.stack.peek_unsafe().*;

    const value = frame.get_transient_storage(slot);

    // Replace top of stack with loaded value unsafely - bounds checking is done in jump_table.zig
    frame.stack.set_top_unsafe(value);
}

pub fn op_tstore(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    // TODO: Add hardfork validation for EIP-1153 (Cancun)
    // if (!frame.flags.is_eip1153) {
    //     return ExecutionError.Error.InvalidOpcode;
    // }

    if (frame.is_static()) {
        @branchHint(.unlikely);
        return ExecutionError.Error.WriteProtection;
    }

    // Gas is already handled by jump table constant_gas = 100

    std.debug.assert(frame.stack.size() >= 2);

    // Pop two values unsafely using batch operation - bounds checking is done in jump_table.zig
    // Stack order: [..., value, slot] where slot is on top
    const popped = frame.stack.pop2_unsafe();
    const value = popped.a; // First popped (was second from top)
    const slot = popped.b; // Second popped (was top)

    try frame.set_transient_storage(slot, value);
}

// TODO: Update fuzz testing functions to use ExecutionContext pattern
// Fuzz testing functions for storage operations
pub fn fuzz_storage_operations_DISABLED(allocator: std.mem.Allocator, operations: []const FuzzStorageOperation) !void {
    // Disabled until ExecutionContext refactor is complete
    _ = allocator;
    _ = operations;
    return;
}

const FuzzStorageOperation = struct {
    op_type: StorageOpType,
    contract_address: primitives.Address,
    slot: u256,
    value: u256,
    initial_storage_value: u256 = 0,
    is_static: bool = false,
    is_berlin: bool = true,
    is_istanbul: bool = true,
    gas_limit: u64 = 1000000,
};

const StorageOpType = enum {
    sload,
    sstore,
    tload,
    tstore,
};

fn validate_storage_result_DISABLED(frame: *const Frame, vm: *const Frame, op: FuzzStorageOperation, result: anyerror!void) !void {
    _ = frame;
    _ = vm;
    _ = op;
    _ = result;
    return;
}

test "fuzz_storage_basic_operations" {
    const allocator = std.testing.allocator;

    const operations = [_]FuzzStorageOperation{
        .{
            .op_type = .sload,
            .contract_address = primitives.Address.from_u256(0x123456),
            .slot = 0,
            .value = 0,
        },
        .{
            .op_type = .sstore,
            .contract_address = primitives.Address.from_u256(0x123456),
            .slot = 0,
            .value = 42,
        },
        .{
            .op_type = .sload,
            .contract_address = primitives.Address.from_u256(0x123456),
            .slot = 0,
            .value = 0,
            .initial_storage_value = 42,
        },
        .{
            .op_type = .tload,
            .contract_address = primitives.Address.from_u256(0x123456),
            .slot = 0,
            .value = 0,
        },
        .{
            .op_type = .tstore,
            .contract_address = primitives.Address.from_u256(0x123456),
            .slot = 0,
            .value = 100,
        },
    };

    _ = allocator;
    _ = operations;
    // TODO: Re-enable when fuzz functions are updated for ExecutionContext
    // try fuzz_storage_operations(allocator, &operations);
}

test "fuzz_storage_static_context" {
    const allocator = std.testing.allocator;

    const operations = [_]FuzzStorageOperation{
        .{
            .op_type = .sstore,
            .contract_address = primitives.Address.from_u256(0x123456),
            .slot = 0,
            .value = 42,
            .is_static = true,
        },
        .{
            .op_type = .tstore,
            .contract_address = primitives.Address.from_u256(0x123456),
            .slot = 0,
            .value = 100,
            .is_static = true,
        },
        .{
            .op_type = .sload,
            .contract_address = primitives.Address.from_u256(0x123456),
            .slot = 0,
            .value = 0,
            .is_static = true,
        },
        .{
            .op_type = .tload,
            .contract_address = primitives.Address.from_u256(0x123456),
            .slot = 0,
            .value = 0,
            .is_static = true,
        },
    };

    _ = allocator;
    _ = operations;
    // TODO: Re-enable when fuzz functions are updated for ExecutionContext
    // try fuzz_storage_operations(allocator, &operations);
}

test "fuzz_storage_edge_cases" {
    const allocator = std.testing.allocator;

    const operations = [_]FuzzStorageOperation{
        .{
            .op_type = .sload,
            .contract_address = primitives.Address.from_u256(0),
            .slot = 0,
            .value = 0,
        },
        .{
            .op_type = .sload,
            .contract_address = primitives.Address.from_u256(std.math.maxInt(u256)),
            .slot = std.math.maxInt(u256),
            .value = 0,
        },
        .{
            .op_type = .sstore,
            .contract_address = primitives.Address.from_u256(0x123456),
            .slot = std.math.maxInt(u256),
            .value = std.math.maxInt(u256),
        },
        .{
            .op_type = .tload,
            .contract_address = primitives.Address.from_u256(0x123456),
            .slot = std.math.maxInt(u256),
            .value = 0,
        },
        .{
            .op_type = .tstore,
            .contract_address = primitives.Address.from_u256(0x123456),
            .slot = std.math.maxInt(u256),
            .value = std.math.maxInt(u256),
        },
    };

    _ = allocator;
    _ = operations;
    // TODO: Re-enable when fuzz functions are updated for ExecutionContext
    // try fuzz_storage_operations(allocator, &operations);
}

test "fuzz_storage_random_operations" {
    const allocator = std.testing.allocator;
    // TODO: Re-enable when fuzz functions are updated for ExecutionContext
    _ = allocator;
}
