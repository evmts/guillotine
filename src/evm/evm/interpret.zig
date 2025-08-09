const std = @import("std");
const ExecutionError = @import("../execution/execution_error.zig");
const Frame = @import("../frame.zig").Frame;
const Log = @import("../log.zig");
const Evm = @import("../evm.zig");
const builtin = @import("builtin");

const SAFE = builtin.mode == .Debug or builtin.mode == .ReleaseSafe;
const MAX_ITERATIONS = 10_000_000; // TODO set this to a real problem

/// Execute contract bytecode using block-based execution.
///
/// This version translates bytecode to an instruction stream before execution,
/// enabling better branch prediction and cache locality.
///
/// Time complexity: O(n) where n is the number of opcodes executed.
/// Memory: Uses provided Frame, no internal allocations.
///
/// The caller is responsible for creating and managing the Frame and its components.
pub inline fn interpret(self: *Evm, frame: *Frame) ExecutionError.Error!void {
    self.require_one_thread();

    Log.debug("[interpret] Starting with {} instructions, gas={}", .{ frame.analysis.instructions.len, frame.gas_remaining });

    // Frame is provided by caller, get the analysis from it
    const instructions = frame.analysis.instructions;
    var current_index: usize = 0;
    var loop_iterations: usize = 0;

    while (current_index < instructions.len) {
        @branchHint(.likely);
        const nextInstruction = instructions[current_index];

        // In safe mode we make sure we don't loop too much. If this happens
        if (comptime SAFE) {
            loop_iterations += 1;
            if (loop_iterations > MAX_ITERATIONS) {
                Log.err("interpret: Infinite loop detected after {} iterations at pc={}, depth={}, gas={}. This should never happen and indicates either the limit was set too low or a high severity bug has been found in EVM", .{ loop_iterations, current_index, self.depth, frame.gas_remaining });
                unreachable;
            }
        }

        // Handle instruction
        switch (nextInstruction.arg) {
            // BEGINBLOCK instructions - validate entire basic block upfront
            // This eliminates per-instruction gas and stack validation for the entire block
            .block_info => |block| {
                // Validate gas for the entire block up-front
                if (frame.gas_remaining < block.gas_cost) {
                    @branchHint(.cold);
                    frame.gas_remaining = 0;
                    return ExecutionError.Error.OutOfGas;
                }
                frame.gas_remaining -= block.gas_cost;

                // Validate stack requirements for this block
                const current_stack_size: u16 = @intCast(frame.stack.size());
                if (current_stack_size < block.stack_req) {
                    return ExecutionError.Error.StackUnderflow;
                }
                // EVM stack limit is 1024
                if (current_stack_size + block.stack_max_growth > 1024) {
                    return ExecutionError.Error.StackOverflow;
                }

                // Advance to the next instruction in the block
                current_index += 1;
                // Note: The opcode_fn for BEGINBLOCK is a no-op; validation is handled here
                _ = nextInstruction.opcode_fn; // keep reference to avoid warnings
            },
            // For jumps we handle them inline as they are preprocessed by analysis
            // 1. Handle dynamic jumps validating it is a valid jumpdest
            // 2. Handle optional jump
            // 3. Handle normal jump
            .jump_target => |jump_target| {
                switch (jump_target.jump_type) {
                    .jump => {
                        const dest = frame.stack.pop_unsafe();
                        if (!frame.valid_jumpdest(dest)) {
                            return ExecutionError.Error.InvalidJump;
                        }
                        current_index = @intFromPtr(jump_target.instruction) - @intFromPtr(instructions.ptr);
                    },
                    .jumpi => {
                        const pops = frame.stack.pop2_unsafe();
                        const dest = pops.a;
                        const condition = pops.b;
                        if (condition != 0) {
                            if (!frame.valid_jumpdest(dest)) {
                                return ExecutionError.Error.InvalidJump;
                            }
                            current_index = @intFromPtr(jump_target.instruction) - @intFromPtr(instructions.ptr);
                        } else {
                            current_index += 1;
                        }
                    },
                    .other => {
                        current_index = @intFromPtr(jump_target.instruction) - @intFromPtr(instructions.ptr);
                    },
                }
            },
            .push_value => |value| {
                current_index += 1;
                Log.debug("[interpret] PUSH value: {x}", .{value});
                try frame.stack.append(value);
            },
            .none => {
                @branchHint(.likely);
                // Handle dynamic JUMP/JUMPI at runtime if needed
                const jt = frame.analysis.inst_jump_type[current_index];
                switch (jt) {
                    .jump => {
                        const dest = frame.stack.pop_unsafe();
                        if (!frame.valid_jumpdest(dest)) {
                            return ExecutionError.Error.InvalidJump;
                        }
                        const dest_usize: usize = @intCast(dest);
                        const idx = frame.analysis.pc_to_block_start[dest_usize];
                        if (idx == std.math.maxInt(u16) or idx >= instructions.len) {
                            return ExecutionError.Error.InvalidJump;
                        }
                        current_index = idx;
                        break; // proceed to next loop iteration
                    },
                    .jumpi => {
                        const pops = frame.stack.pop2_unsafe();
                        const dest = pops.a;
                        const condition = pops.b;
                        if (condition != 0) {
                            if (!frame.valid_jumpdest(dest)) {
                                return ExecutionError.Error.InvalidJump;
                            }
                            const dest_usize: usize = @intCast(dest);
                            const idx = frame.analysis.pc_to_block_start[dest_usize];
                            if (idx == std.math.maxInt(u16) or idx >= instructions.len) {
                                return ExecutionError.Error.InvalidJump;
                            }
                            current_index = idx;
                        } else {
                            current_index += 1;
                        }
                        break; // handled
                    },
                    .other => {
                        // Most opcodes now have .none - no individual gas/stack validation needed
                        // Gas and stack validation is handled by BEGINBLOCK instructions
                        current_index += 1;
                        nextInstruction.opcode_fn(@ptrCast(frame)) catch |err| {
                            // Frame already manages its own output, no need to copy
                            Log.debug("[interpret] Opcode at index {} returned error: {}", .{ current_index - 1, err });

                            // Handle gas exhaustion for InvalidOpcode specifically
                            if (err == ExecutionError.Error.InvalidOpcode) {
                                frame.gas_remaining = 0;
                            }

                            return err;
                        };
                    },
                }
            },
            .gas_cost => |cost| {
                // Legacy path - kept for compatibility
                current_index += 1;
                if (frame.gas_remaining < cost) {
                    @branchHint(.cold);
                    frame.gas_remaining = 0;
                    return ExecutionError.Error.OutOfGas;
                }
                frame.gas_remaining -= cost;

                // Execute the opcode after charging gas
                nextInstruction.opcode_fn(@ptrCast(frame)) catch |err| {
                    if (err == ExecutionError.Error.InvalidOpcode) {
                        frame.gas_remaining = 0;
                    }
                    return err;
                };
            },
            .dynamic_gas => |dyn_gas| {
                // New path for opcodes with dynamic gas
                current_index += 1;

                // Charge static gas first
                if (frame.gas_remaining < dyn_gas.static_cost) {
                    @branchHint(.cold);
                    frame.gas_remaining = 0;
                    return ExecutionError.Error.OutOfGas;
                }
                frame.gas_remaining -= dyn_gas.static_cost;

                // Calculate and charge dynamic gas if function exists
                if (dyn_gas.gas_fn) |gas_fn| {
                    const additional_gas = gas_fn(frame) catch |err| {
                        // If dynamic gas calculation fails, it's usually OutOfOffset
                        if (err == ExecutionError.Error.OutOfOffset) {
                            return err;
                        }
                        // For other errors, treat as out of gas
                        frame.gas_remaining = 0;
                        return ExecutionError.Error.OutOfGas;
                    };

                    if (frame.gas_remaining < additional_gas) {
                        @branchHint(.cold);
                        frame.gas_remaining = 0;
                        return ExecutionError.Error.OutOfGas;
                    }
                    frame.gas_remaining -= additional_gas;
                }

                // Execute the opcode after all gas is charged
                nextInstruction.opcode_fn(@ptrCast(frame)) catch |err| {
                    if (err == ExecutionError.Error.InvalidOpcode) {
                        frame.gas_remaining = 0;
                    }
                    return err;
                };
            },
        }
    }

    Log.debug("[interpret] Reached end of instructions without STOP/RETURN, current_index={}, len={}", .{ current_index, instructions.len });
}

test "BEGINBLOCK: upfront OutOfGas when gas < block base cost" {
    const allocator = std.testing.allocator;
    const JumpTable = @import("../jump_table/jump_table.zig");
    const Analysis = @import("../analysis.zig");
    const MemoryDatabase = @import("../state/memory_database.zig").MemoryDatabase;
    const AccessList = @import("../access_list/access_list.zig").AccessList;
    const CallJournal = @import("../call_frame_stack.zig").CallJournal;
    const Host = @import("../host.zig").Host;
    const SelfDestruct = @import("../self_destruct.zig").SelfDestruct;
    const CreatedContracts = @import("../created_contracts.zig").CreatedContracts;
    const Address = @import("primitives").Address.Address;

    // Simple block with 5 x PUSH1 (5*3 gas) then STOP
    const code = &[_]u8{ 0x60, 0x01, 0x60, 0x02, 0x60, 0x03, 0x60, 0x04, 0x60, 0x05, 0x00 };
    var analysis = try Analysis.from_code(allocator, code, &JumpTable.DEFAULT);
    defer analysis.deinit();

    // Setup VM and environment
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();

    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    var access_list = AccessList.init(allocator, @import("../access_list/context.zig").Context.init());
    defer access_list.deinit();
    var journal = CallJournal.init(allocator);
    defer journal.deinit();
    var self_destruct = SelfDestruct.init(allocator);
    defer self_destruct.deinit();
    var created_contracts = CreatedContracts.init(allocator);
    defer created_contracts.deinit();

    var host_impl = vm; // Evm implements Host interface
    var host = Host.init(&host_impl);

    // Gas is less than block base cost (5*3 = 15)
    var frame = try Frame.init(
        10, // gas_remaining
        false, // static
        0, // depth
        Address.ZERO, // contract
        Address.ZERO, // caller
        0, // value
        &analysis,
        &access_list,
        &journal,
        &host,
        0, // snapshot_id
        db_interface,
        Frame.ChainRules.DEFAULT,
        &self_destruct,
        &created_contracts,
        &[_]u8{}, // input
        allocator,
        null,
        false,
        false,
    );
    defer frame.deinit();

    const result = interpret(&vm, &frame);
    try std.testing.expectError(ExecutionError.Error.OutOfGas, result);
}

test "BEGINBLOCK: stack underflow detected at block entry" {
    const allocator = std.testing.allocator;
    const JumpTable = @import("../jump_table/jump_table.zig");
    const Analysis = @import("../analysis.zig");
    const MemoryDatabase = @import("../state/memory_database.zig").MemoryDatabase;
    const AccessList = @import("../access_list/access_list.zig").AccessList;
    const CallJournal = @import("../call_frame_stack.zig").CallJournal;
    const Host = @import("../host.zig").Host;
    const SelfDestruct = @import("../self_destruct.zig").SelfDestruct;
    const CreatedContracts = @import("../created_contracts.zig").CreatedContracts;
    const Address = @import("primitives").Address.Address;

    // Block with ADD (requires 2 stack items) then STOP
    const code = &[_]u8{ 0x01, 0x00 };
    var analysis = try Analysis.from_code(allocator, code, &JumpTable.DEFAULT);
    defer analysis.deinit();

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    var access_list = AccessList.init(allocator, @import("../access_list/context.zig").Context.init());
    defer access_list.deinit();
    var journal = CallJournal.init(allocator);
    defer journal.deinit();
    var self_destruct = SelfDestruct.init(allocator);
    defer self_destruct.deinit();
    var created_contracts = CreatedContracts.init(allocator);
    defer created_contracts.deinit();

    var host_impl = vm;
    var host = Host.init(&host_impl);

    var frame = try Frame.init(
        1000,
        false,
        0,
        Address.ZERO,
        Address.ZERO,
        0,
        &analysis,
        &access_list,
        &journal,
        &host,
        0,
        db_interface,
        Frame.ChainRules.DEFAULT,
        &self_destruct,
        &created_contracts,
        &[_]u8{},
        allocator,
        null,
        false,
        false,
    );
    defer frame.deinit();

    // Stack is empty -> should fail at BEGINBLOCK
    const result = interpret(&vm, &frame);
    try std.testing.expectError(ExecutionError.Error.StackUnderflow, result);
}

test "BEGINBLOCK: stack overflow detected from max growth" {
    const allocator = std.testing.allocator;
    const JumpTable = @import("../jump_table/jump_table.zig");
    const Analysis = @import("../analysis.zig");
    const MemoryDatabase = @import("../state/memory_database.zig").MemoryDatabase;
    const AccessList = @import("../access_list/access_list.zig").AccessList;
    const CallJournal = @import("../call_frame_stack.zig").CallJournal;
    const Host = @import("../host.zig").Host;
    const SelfDestruct = @import("../self_destruct.zig").SelfDestruct;
    const CreatedContracts = @import("../created_contracts.zig").CreatedContracts;
    const Address = @import("primitives").Address.Address;
    const Stack = @import("../stack/stack.zig");

    // Block with PUSH1 then STOP (max_growth = +1)
    const code = &[_]u8{ 0x60, 0x01, 0x00 };
    var analysis = try Analysis.from_code(allocator, code, &JumpTable.DEFAULT);
    defer analysis.deinit();

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    var access_list = AccessList.init(allocator, @import("../access_list/context.zig").Context.init());
    defer access_list.deinit();
    var journal = CallJournal.init(allocator);
    defer journal.deinit();
    var self_destruct = SelfDestruct.init(allocator);
    defer self_destruct.deinit();
    var created_contracts = CreatedContracts.init(allocator);
    defer created_contracts.deinit();

    var host_impl = vm;
    var host = Host.init(&host_impl);

    var frame = try Frame.init(
        1000,
        false,
        0,
        Address.ZERO,
        Address.ZERO,
        0,
        &analysis,
        &access_list,
        &journal,
        &host,
        0,
        db_interface,
        Frame.ChainRules.DEFAULT,
        &self_destruct,
        &created_contracts,
        &[_]u8{},
        allocator,
        null,
        false,
        false,
    );
    defer frame.deinit();

    // Fill stack to capacity
    var i: usize = 0;
    while (i < Stack.CAPACITY) : (i += 1) {
        frame.stack.append_unsafe(0);
    }

    const result = interpret(&vm, &frame);
    try std.testing.expectError(ExecutionError.Error.StackOverflow, result);
}
