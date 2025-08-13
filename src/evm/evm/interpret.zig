const std = @import("std");
const ExecutionError = @import("../execution/execution_error.zig");
const build_options = @import("build_options");
const Tracer = @import("../tracer.zig").Tracer;
const Frame = @import("../frame.zig").Frame;
const Log = @import("../log.zig");
const Evm = @import("../evm.zig");
const builtin = @import("builtin");

// Hoist U256 type alias used by fused arithmetic ops
const U256 = @import("primitives").Uint(256, 4);

const SAFE = builtin.mode == .Debug or builtin.mode == .ReleaseSafe;
const MAX_ITERATIONS = 10_000_000; // TODO set this to a real problem

// Private inline functions for jump handling
inline fn handle_jump(self: *Evm, frame: *Frame, current_index: *usize) ExecutionError.Error!void {
    const dest = frame.stack.pop_unsafe();
    const analysis = frame.analysis;
    Log.debug("[interpret] JUMP requested to dest={} (inst_idx={}, depth={}, gas={})", .{ dest, current_index.*, self.depth, frame.gas_remaining });
    if (!frame.valid_jumpdest(dest)) {
        Log.debug("[interpret] JUMP invalid destination: dest={} (code_len={})", .{ dest, analysis.code_len });
        return ExecutionError.Error.InvalidJump;
    }
    Log.debug("[interpret] JUMP valid destination: dest={} -> jumping", .{dest});
    const dest_usize: usize = @intCast(dest);
    const idx = analysis.pc_to_block_start[dest_usize];
    if (idx == std.math.maxInt(u16) or idx >= analysis.instructions.len) {
        Log.debug("[interpret] JUMP pc_to_block_start invalid mapping: dest={} idx={} inst_len={}", .{ dest, idx, analysis.instructions.len });
        return ExecutionError.Error.InvalidJump;
    }
    current_index.* = idx;
}

inline fn handle_jumpi(self: *Evm, frame: *Frame, current_index: *usize) ExecutionError.Error!void {
    const pops = frame.stack.pop2_unsafe();
    const analysis = frame.analysis;
    // EVM JUMPI consumes (dest, cond) with dest on top. pop2_unsafe returns {a=second, b=top}.
    const dest = pops.b;
    const condition = pops.a;
    Log.debug("[interpret] JUMPI requested to dest={} cond={} (inst_idx={}, depth={}, gas={})", .{ dest, condition, current_index.*, self.depth, frame.gas_remaining });
    if (condition != 0) {
        if (!frame.valid_jumpdest(dest)) {
            Log.debug("[interpret] JUMPI invalid destination on true branch: dest={} (code_len={})", .{ dest, analysis.code_len });
            return ExecutionError.Error.InvalidJump;
        }
        Log.debug("[interpret] JUMPI condition true, jumping to dest {}", .{dest});
        const dest_usize: usize = @intCast(dest);
        const idx = analysis.pc_to_block_start[dest_usize];
        if (idx == std.math.maxInt(u16) or idx >= analysis.instructions.len) {
            Log.debug("[interpret] JUMPI pc_to_block_start invalid mapping: dest={} idx={} inst_len={}", .{ dest, idx, analysis.instructions.len });
            return ExecutionError.Error.InvalidJump;
        }
        current_index.* = idx;
    } else {
        Log.debug("[interpret] JUMPI condition false, fallthrough to next instruction", .{});
        current_index.* += 1;
    }
}

inline fn handle_dynamic_jump(self: *Evm, frame: *Frame, current_index: *usize) ExecutionError.Error!void {
    // Backtrace last few original PCs/opcodes to understand control flow
    var bt: usize = 1;
    const analysis = frame.analysis;
    while (bt <= 4 and current_index.* >= bt) : (bt += 1) {
        const iprev = current_index.* - bt;
        const pcprev16 = analysis.inst_to_pc[iprev];
        if (pcprev16 == std.math.maxInt(u16)) break;
        const pcprev: usize = pcprev16;
        const opprev: u8 = if (pcprev < analysis.code_len) analysis.code[pcprev] else 0x00;
        Log.debug("[interpret] backtrace[-{}]: inst_idx={} pc={} op=0x{x}", .{ bt, iprev, pcprev, opprev });
    }
    const dest = frame.stack.pop_unsafe();
    Log.debug("[interpret] Dynamic JUMP to dest={} (inst_idx={}, depth={}, gas={})", .{ dest, current_index.*, self.depth, frame.gas_remaining });
    if (!frame.valid_jumpdest(dest)) {
        Log.debug("[interpret] Dynamic JUMP invalid destination: dest={} (code_len={})", .{ dest, analysis.code_len });
        return ExecutionError.Error.InvalidJump;
    }
    const dest_usize: usize = @intCast(dest);
    const idx = analysis.pc_to_block_start[dest_usize];
    if (idx == std.math.maxInt(u16) or idx >= analysis.instructions.len) {
        Log.debug("[interpret] Dynamic JUMP pc_to_block_start invalid mapping: dest={} idx={} inst_len={}", .{ dest, idx, analysis.instructions.len });
        return ExecutionError.Error.InvalidJump;
    }
    Log.debug("[interpret] Dynamic JUMP mapping: dest_pc={} -> beginblock_inst_idx={}", .{ dest_usize, idx });
    Log.debug("[interpret] Dynamic JUMP resolved to instruction index {} for dest {}", .{ idx, dest });
    current_index.* = idx;
}

inline fn handle_dynamic_jumpi(self: *Evm, frame: *Frame, current_index: *usize) ExecutionError.Error!void {
    const analysis = frame.analysis;
    // Backtrace before conditional jump as well
    var bt: usize = 1;
    while (bt <= 4 and current_index.* >= bt) : (bt += 1) {
        const iprev = current_index.* - bt;
        const pcprev16 = analysis.inst_to_pc[iprev];
        if (pcprev16 == std.math.maxInt(u16)) break;
        const pcprev: usize = pcprev16;
        const opprev: u8 = if (pcprev < analysis.code_len) analysis.code[pcprev] else 0x00;
        Log.debug("[interpret] backtrace[-{}]: inst_idx={} pc={} op=0x{x}", .{ bt, iprev, pcprev, opprev });
    }
    const pops = frame.stack.pop2_unsafe();
    // EVM JUMPI consumes (dest, cond) with dest on top. pop2_unsafe returns {a=second, b=top}.
    const dest = pops.b;
    const condition = pops.a;
    Log.debug("[interpret] Dynamic JUMPI to dest={} cond={} (inst_idx={}, depth={}, gas={})", .{ dest, condition, current_index.*, self.depth, frame.gas_remaining });
    if (condition != 0) {
        if (!frame.valid_jumpdest(dest)) {
            Log.debug("[interpret] Dynamic JUMPI invalid destination on true branch: dest={} (code_len={})", .{ dest, analysis.code_len });
            return ExecutionError.Error.InvalidJump;
        }
        const dest_usize: usize = @intCast(dest);
        const idx = analysis.pc_to_block_start[dest_usize];
        if (idx == std.math.maxInt(u16) or idx >= analysis.instructions.len) {
            Log.debug("[interpret] Dynamic JUMPI pc_to_block_start invalid mapping: dest={} idx={} inst_len={}", .{ dest, idx, analysis.instructions.len });
            return ExecutionError.Error.InvalidJump;
        }
        Log.debug("[interpret] Dynamic JUMPI mapping: dest_pc={} -> beginblock_inst_idx={}", .{ dest_usize, idx });
        Log.debug("[interpret] Dynamic JUMPI condition true, jumping to instruction index {} for dest {}", .{ idx, dest });
        current_index.* = idx;
    } else {
        Log.debug("[interpret] Dynamic JUMPI condition false, fallthrough", .{});
        current_index.* += 1;
    }
}

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
    {
        self.require_one_thread();
    }

    const analysis = frame.analysis;
    const instructions = analysis.instructions;
    Log.debug("[interpret] Starting with {} instructions (incl. sentinel), gas={}", .{ instructions.len, frame.gas_remaining });
    const frame_opaque: *anyopaque = @ptrCast(frame);

    var current_index: usize = 0;
    var next_instruction: *const @TypeOf(instructions[0]) = &instructions[0];
    var loop_iterations: usize = 0;
    while (true) {
        if (comptime SAFE) {
            loop_iterations += 1;
            if (loop_iterations > MAX_ITERATIONS) {
                unreachable;
            }
        }

        const inst = next_instruction;

        // Optional tracing hook (compile-time gated; zero runtime overhead when disabled)
        if (comptime build_options.enable_tracing) {
            if (self.tracer) |writer| {
                if (current_index < analysis.inst_to_pc.len) {
                    const pc_u16 = analysis.inst_to_pc[current_index];
                    if (pc_u16 != std.math.maxInt(u16)) {
                        const pc: usize = pc_u16;
                        const opcode: u8 = if (pc < analysis.code_len) analysis.code[pc] else 0x00;
                        const stack_len: usize = frame.stack.size();
                        const stack_view: []const u256 = frame.stack.data[0..stack_len];
                        const gas_cost: u64 = 0; // Block-based validation; per-op gas not tracked here
                        const mem_size: usize = frame.memory.size();
                        var tr = Tracer.init(writer);
                        _ = tr.trace(pc, opcode, stack_view, frame.gas_remaining, gas_cost, mem_size, @intCast(frame.depth)) catch {};
                    }
                }
            }
        }
        switch (inst.arg) {
            // BEGINBLOCK instructions - validate entire basic block upfront
            // This eliminates per-instruction gas and stack validation for the entire block
            .block_info => |block| {
                // Compute current stack size once for logging and validation
                const current_stack_size: u16 = @intCast(frame.stack.size());
                // Debug: show block-level validation details
                const dbg_pc: usize = if (current_index < analysis.inst_to_pc.len) blk: {
                    const pc16 = analysis.inst_to_pc[current_index];
                    break :blk if (pc16 == std.math.maxInt(u16)) 0 else pc16;
                } else 0;
                Log.debug("[interpret] BEGINBLOCK at inst_idx={} pc={} gas_cost={} stack_req={} max_growth={} curr_stack={}", .{
                    current_index,
                    dbg_pc,
                    block.gas_cost,
                    block.stack_req,
                    block.stack_max_growth,
                    current_stack_size,
                });
                // Validate gas for the entire block up-front
                if (frame.gas_remaining < block.gas_cost) {
                    @branchHint(.cold);
                    frame.gas_remaining = 0;
                    return ExecutionError.Error.OutOfGas;
                }
                frame.gas_remaining -= block.gas_cost;

                // Validate stack requirements for this block
                if (current_stack_size < block.stack_req) {
                    Log.debug("[interpret] StackUnderflow at block entry: need {} have {}", .{ block.stack_req, current_stack_size });
                    return ExecutionError.Error.StackUnderflow;
                }
                // EVM stack limit is 1024
                if (current_stack_size + block.stack_max_growth > 1024) {
                    return ExecutionError.Error.StackOverflow;
                }

                // Advance to the next instruction in the block
                // Keep a reference to the opcode function pointer to avoid warnings
                const op_fn_dbg = inst.opcode_fn;
                current_index += 1;
                next_instruction = &instructions[current_index];
                // Note: The opcode_fn for BEGINBLOCK is a no-op; validation is handled here
                _ = op_fn_dbg;
            },
            // For jumps we handle them inline as they are preprocessed by analysis
            // 1. Handle dynamic jumps validating it is a valid jumpdest
            // 2. Handle optional jump
            // 3. Handle normal jump
            .jump_target => |jump_target| {
                switch (jump_target.jump_type) {
                    .jump => try handle_jump(self, frame, &current_index),
                    .jumpi => try handle_jumpi(self, frame, &current_index),
                    .other => {
                        Log.debug("[interpret] Jump target type .other redirecting flow (inst_idx from {} to target)", .{current_index});
                        // Fallback: advance to next instruction if mapping is not applicable
                        current_index += 1;
                    },
                }
                next_instruction = &instructions[current_index];
            },
            .word => |value| {
                const pc_dbg: usize = if (current_index < analysis.inst_to_pc.len) blk: {
                    const pc16 = analysis.inst_to_pc[current_index];
                    break :blk if (pc16 == std.math.maxInt(u16)) 0 else pc16;
                } else 0;
                const op_dbg: u8 = if (pc_dbg < analysis.code_len) analysis.code[pc_dbg] else 0x00;
                Log.debug("[interpret] PUSH at pc={} op=0x{x} value={x}", .{ pc_dbg, op_dbg, value });
                current_index += 1;
                next_instruction = &instructions[current_index];
                frame.stack.append_unsafe(value);
                // After pushing the word, run the associated op (e.g., ADD/SUB/etc.)
                const op_fn = inst.opcode_fn;
                op_fn(frame_opaque) catch |err| {
                    if (err == ExecutionError.Error.InvalidOpcode) {
                        frame.gas_remaining = 0;
                    }
                    return err;
                };
            },
            .pc_value => |pc| {
                Log.debug("[interpret] PC at pc={} pushing value={}", .{ pc, pc });
                current_index += 1;
                next_instruction = &instructions[current_index];
                frame.stack.append_unsafe(@as(u256, pc));
            },
            // Fusion cases are no longer needed; handled via `.word` + opcode_fn
            .keccak => |params| {
                current_index += 1;
                next_instruction = &instructions[current_index];
                // Consume precomputed gas cost
                if (frame.gas_remaining < params.gas_cost) {
                    @branchHint(.cold);
                    frame.gas_remaining = 0;
                    return ExecutionError.Error.OutOfGas;
                }
                frame.gas_remaining -= params.gas_cost;
                // If size provided at analysis time, use it; otherwise pop from stack
                const size = if (params.size) |imm| @as(u256, @intCast(imm)) else frame.stack.pop_unsafe();
                const offset = frame.stack.pop_unsafe();

                // Bounds checking
                if (offset > std.math.maxInt(usize) or size > std.math.maxInt(usize)) {
                    @branchHint(.unlikely);
                    return ExecutionError.Error.OutOfOffset;
                }

                const offset_usize = @as(usize, @intCast(offset));
                const size_usize = @as(usize, @intCast(size));

                if (size == 0) {
                    @branchHint(.unlikely);
                    // Hash of empty data = keccak256("")
                    const empty_hash: u256 = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;
                    frame.stack.append_unsafe(empty_hash);
                } else {
                    // Memory expansion already handled, just get the data
                    _ = try frame.memory.ensure_context_capacity(offset_usize + size_usize);
                    const data = try frame.memory.get_slice(offset_usize, size_usize);

                    // Hash using Keccak256
                    var hash: [32]u8 = undefined;
                    std.crypto.hash.sha3.Keccak256.hash(data, &hash, .{});

                    const result = std.mem.readInt(u256, &hash, .big);
                    frame.stack.append_unsafe(result);
                }
            },
            .none => {
                @branchHint(.likely);
                // Debug logging for all instructions
                const pc_val = if (current_index < analysis.inst_to_pc.len) analysis.inst_to_pc[current_index] else std.math.maxInt(u16);
                const opcode_at_pc = if (pc_val != std.math.maxInt(u16) and pc_val < analysis.code_len) analysis.code[pc_val] else 0xFF;
                Log.debug("[interpret] Executing instruction at index {} (pc={}, opcode=0x{x})", .{ current_index, pc_val, opcode_at_pc });
                // Handle dynamic JUMP/JUMPI at runtime if needed
                Log.debug("[interpret] inst_jump_type.len={}, current_index={}", .{ analysis.inst_jump_type.len, current_index });
                if (current_index >= analysis.inst_jump_type.len) {
                    Log.err("[interpret] ERROR: current_index {} >= inst_jump_type.len {}", .{ current_index, analysis.inst_jump_type.len });
                    return ExecutionError.Error.InvalidOpcode;
                }
                const jt = analysis.inst_jump_type[current_index];
                switch (jt) {
                    .jump => {
                        try handle_dynamic_jump(self, frame, &current_index);
                        next_instruction = &instructions[current_index];
                        continue; // proceed to next loop iteration of the while-loop
                    },
                    .jumpi => {
                        try handle_dynamic_jumpi(self, frame, &current_index);
                        next_instruction = &instructions[current_index];
                        continue; // handled; proceed to next while-loop iteration
                    },
                    .other => {
                        // Most opcodes now have .none - no individual gas/stack validation needed
                        // Gas and stack validation is handled by BEGINBLOCK instructions
                        // Cache function pointer before advancing index
                        const op_fn = inst.opcode_fn;
                        current_index += 1;
                        next_instruction = &instructions[current_index];
                        op_fn(frame_opaque) catch |err| {
                            // Frame already manages its own output, no need to copy
                            Log.debug("[interpret] Opcode at index {} returned error: {}", .{ current_index - 1, err });

                            // Handle gas exhaustion for InvalidOpcode specifically
                            if (err == ExecutionError.Error.InvalidOpcode) {
                                frame.gas_remaining = 0;
                            }

                            // CRITICAL DEBUG: Log when STOP error is returned (which RETURN uses)
                            if (err == ExecutionError.Error.STOP) {
                                const pc_for_debug = if (current_index - 1 < analysis.inst_to_pc.len)
                                    analysis.inst_to_pc[current_index - 1]
                                else
                                    std.math.maxInt(u16);
                                const opcode_for_debug = if (pc_for_debug != std.math.maxInt(u16) and pc_for_debug < analysis.code_len)
                                    analysis.code[pc_for_debug]
                                else
                                    0xFF;
                                Log.debug("[interpret] STOP error from opcode 0x{x} at PC={}, depth={}, should halt execution", .{ opcode_for_debug, pc_for_debug, self.depth });
                            }

                            return err;
                        };
                    },
                }
            },
            .gas_cost => |cost| {
                // Legacy path - kept for compatibility
                // Cache function pointer before advancing index
                const op_fn = inst.opcode_fn;
                current_index += 1;
                next_instruction = &instructions[current_index];
                if (frame.gas_remaining < cost) {
                    @branchHint(.cold);
                    frame.gas_remaining = 0;
                    return ExecutionError.Error.OutOfGas;
                }
                frame.gas_remaining -= cost;

                // Execute the opcode after charging gas
                op_fn(frame_opaque) catch |err| {
                    if (err == ExecutionError.Error.InvalidOpcode) {
                        frame.gas_remaining = 0;
                    }
                    return err;
                };
            },
            .dynamic_gas => |dyn_gas| {
                // New path for opcodes with dynamic gas
                // Cache function pointer before advancing index
                const op_fn = inst.opcode_fn;
                current_index += 1;
                next_instruction = &instructions[current_index];

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
                op_fn(frame_opaque) catch |err| {
                    if (err == ExecutionError.Error.InvalidOpcode) {
                        frame.gas_remaining = 0;
                    }
                    return err;
                };
            },
        }
    }

    Log.debug("[interpret] Reached end of instructions without STOP/RETURN, current_index={}, len={}", .{ current_index, instructions.len });

    // CRITICAL DEBUG: This should rarely happen - most contracts end with STOP/RETURN/REVERT
    // If we're seeing this during contract deployment, it likely means RETURN didn't halt execution
    if (current_index < analysis.inst_to_pc.len) {
        const last_pc = if (current_index > 0 and current_index - 1 < analysis.inst_to_pc.len)
            analysis.inst_to_pc[current_index - 1]
        else
            std.math.maxInt(u16);
        if (last_pc != std.math.maxInt(u16) and last_pc < analysis.code_len) {
            const last_opcode = analysis.code[last_pc];
            Log.debug("[interpret] WARNING: Last executed opcode was 0x{x} at PC={}, but execution continued!", .{ last_opcode, last_pc });
        }
    }
}

test "BEGINBLOCK: upfront OutOfGas when gas < block base cost" {
    const allocator = std.testing.allocator;
    const OpcodeMetadata = @import("../opcode_metadata/opcode_metadata.zig");
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
    var analysis = try Analysis.from_code(allocator, code, &OpcodeMetadata.DEFAULT);
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

    // Evm implements Host interface
    const host = Host.init(vm);

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
        host,
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
    const OpcodeMetadata = @import("../opcode_metadata/opcode_metadata.zig");
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
    var analysis = try Analysis.from_code(allocator, code, &OpcodeMetadata.DEFAULT);
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

    const host = Host.init(vm);

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
        host,
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
    const OpcodeMetadata = @import("../opcode_metadata/opcode_metadata.zig");
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
    var analysis = try Analysis.from_code(allocator, code, &OpcodeMetadata.DEFAULT);
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

    const host = Host.init(vm);

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
        host,
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

test "dynamic jump returns 32-byte true" {
    const allocator = std.testing.allocator;
    const OpcodeMetadata = @import("../opcode_metadata/opcode_metadata.zig");
    const Analysis = @import("../analysis.zig");
    const MemoryDatabase = @import("../state/memory_database.zig").MemoryDatabase;
    const AccessList = @import("../access_list/access_list.zig").AccessList;
    const CallJournal = @import("../call_frame_stack.zig").CallJournal;
    const Host = @import("../host.zig").Host;
    const SelfDestruct = @import("../self_destruct.zig").SelfDestruct;
    const CreatedContracts = @import("../created_contracts.zig").CreatedContracts;
    const Address = @import("primitives").Address.Address;

    // Bytecode:
    // 00: PUSH1 0x05
    // 02: JUMP              -> to 0x05
    // 03: STOP              (not executed)
    // 04: PUSH1 0x00        (padding)
    // 05: JUMPDEST
    // 06: PUSH1 0x01        (value true)
    // 08: PUSH1 0x1f        (offset 31)
    // 0a: MSTORE            (store true at [31..63])
    // 0b: PUSH1 0x20        (size 32)
    // 0d: PUSH1 0x00        (offset 0)
    // 0f: RETURN
    const code = &[_]u8{
        0x60, 0x05, // PUSH1 0x05
        0x56, // JUMP
        0x00, // STOP
        0x60, 0x00, // PUSH1 0x00 (padding)
        0x5B, // JUMPDEST @ 0x05
        0x60, 0x01, // PUSH1 0x01
        0x60, 0x1F, // PUSH1 0x1f
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 0x20
        0x60, 0x00, // PUSH1 0x00
        0xF3, // RETURN
    };

    var analysis = try Analysis.from_code(allocator, code, &OpcodeMetadata.DEFAULT);
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

    // Evm implements Host
    const host = Host.init(vm);

    var frame = try Frame.init(
        1_000_000,
        false,
        0,
        Address.ZERO,
        Address.ZERO,
        0,
        &analysis,
        host,
        db_interface,
        Frame.ChainRules.DEFAULT,
        &self_destruct,
        &[_]u8{},
        allocator,
        false,
        false,
    );
    defer frame.deinit();

    try interpret(&vm, &frame);
    const output = host.get_output();
    try std.testing.expect(output.len == 32);
    try std.testing.expect(output[31] == 1);
}
