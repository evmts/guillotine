const std = @import("std");
const ExecutionError = @import("../execution/execution_error.zig");
const build_options = @import("build_options");
const Tracer = @import("../tracer.zig").Tracer;
const Frame = @import("../frame.zig").Frame;
const Log = @import("../log.zig");
const Evm = @import("../evm.zig");
const builtin = @import("builtin");
const UnreachableHandler = @import("../analysis.zig").UnreachableHandler;
const Instruction = @import("../instruction.zig").Instruction;
const Tag = @import("../instruction.zig").Tag;
const execution = @import("../execution/package.zig");

// Hoist U256 type alias used by fused arithmetic ops
const U256 = @import("primitives").Uint(256, 4);

const SAFE = builtin.mode == .Debug or builtin.mode == .ReleaseSafe;
const MAX_ITERATIONS = 10_000_000; // TODO set this to a real problem

/// Convert bytecode slice to u256, handling variable length (0-32 bytes)
fn bytesToU256(bytes: []const u8) u256 {
    std.debug.assert(bytes.len <= 32);

    if (bytes.len == 0) return 0;

    // For full 32 bytes, use readInt directly
    if (bytes.len == 32) {
        return std.mem.readInt(u256, bytes[0..32], .big);
    }

    // For partial bytes, pad with zeros on the left (big-endian)
    var padded: [32]u8 = [_]u8{0} ** 32;
    @memcpy(padded[32 - bytes.len ..], bytes);
    return std.mem.readInt(u256, &padded, .big);
}

fn pre_step(self: *Evm, frame: *Frame, inst: *const Instruction, loop_iterations: *usize) void {
    if (comptime SAFE) {
        loop_iterations.* += 1;
        if (loop_iterations.* > MAX_ITERATIONS) {
            unreachable;
        }
    }

    if (comptime build_options.enable_tracing) {
        const analysis = frame.analysis;
        const instructions = analysis.instructions;
        if (self.tracer) |writer| {
            if (frame.depth > 0) {
                Log.debug("pre_step: HAS TRACER at depth={}, self_ptr=0x{x}", .{ frame.depth, @intFromPtr(self) });
            }
            // Derive index of current instruction for tracing
            const base: [*]const @TypeOf(inst.*) = instructions.ptr;
            const idx = (@intFromPtr(inst) - @intFromPtr(base)) / @sizeOf(@TypeOf(inst.*));
            const pc_u16 = analysis.inst_to_pc[idx];
            if (pc_u16 != std.math.maxInt(u16)) {
                const pc: usize = pc_u16;
                const opcode: u8 = if (pc < analysis.code_len) frame.analysis.code[pc] else 0x00;
                const stack_len: usize = frame.stack.size();
                const stack_view: []const u256 = frame.stack.data[0..stack_len];
                const gas_cost: u64 = 0; // Block-based validation; per-op gas not tracked here
                const mem_size: usize = frame.memory.size();
                var tr = Tracer.init(writer);
                _ = tr.trace(pc, opcode, stack_view, frame.gas_remaining, gas_cost, mem_size, @intCast(frame.depth)) catch {};
                if (frame.depth > 0) {
                    Log.debug("Tracing nested call: pc={}, depth={}, opcode=0x{x}, code_len={}", .{ pc, frame.depth, opcode, analysis.code_len });
                }
            }
        } else if (frame.depth > 0) {
            Log.debug("No tracer available for nested call at depth={}, self_ptr=0x{x}", .{ frame.depth, @intFromPtr(self) });
        }
    }
}

/// Internal method to execute contract bytecode using block-based execution.
/// This loop is highly optimized for performance.
///
/// This version translates bytecode to an instruction stream before execution,
/// enabling better branch prediction and cache locality.
///
/// Time complexity: O(n) where n is the number of opcodes executed.
/// Memory: Uses provided Frame, no internal allocations.
///
/// The caller is responsible for creating and managing the Frame and its components.
pub fn interpret(self: *Evm, frame: *Frame) ExecutionError.Error!void {
    {
        // The interpreter currently depends on frame.host which is a pointer back
        // to self. Because of this state on self should only ever be modified
        // by a single evm run at a time
        self.require_one_thread();

        // Handle empty bytecode - valid case that executes successfully (implicit STOP)
        // Also handle single instruction case (just block_info with no opcodes)
        if (frame.analysis.instructions.len <= 1) {
            return;
        }
    }

    // Use tailcall dispatch if enabled
    if (comptime !build_options.disable_tailcall_dispatch) {
        // Import tailcall modules only when enabled to avoid circular dependencies
        const threadify = @import("threadify.zig");
        
        const ops = try threadify.build(self.allocator, frame.analysis);
        defer self.allocator.free(ops);
        
        // Store ops array and starting index in frame for tailcall dispatch
        frame.tailcall_ops = @ptrCast(ops.ptr);
        frame.tailcall_index = 0;
        
        // Start execution with first instruction
        // Use .auto to let compiler decide between tail call and regular call
        const frame_ptr = @as(*anyopaque, @ptrCast(frame));
        const first_fn = ops[0];
        return @call(.auto, first_fn, .{frame_ptr});
    }

    // Otherwise use switch-based interpreter
    var i: u16 = 0;
    var loop_iterations: usize = 0;
    const analysis = frame.analysis;
    const instructions = analysis.instructions;

    dispatch: switch (instructions[i].tag) {
        // .block_info runs before any series of opcodes and aggregates stack requirements and
        // gas validation for all opcodes in a single instruction
        // TODO: Calling it block is unfortunate because it has nothing to do with a blockchain block
        // We will rename in future to opcode_series
        .block_info => {
            @branchHint(.likely);
            const instruction = &instructions[i];
            Log.debug("[BLOCK_INFO] Processing block at instruction.id={}", .{instruction.id});
            pre_step(self, frame, instruction, &loop_iterations);

            const params = analysis.getInstructionParams(.block_info, instruction.id);

            // Set to next instruction right away
            i += 1;

            if (frame.gas_remaining < params.gas_cost) {
                @branchHint(.unlikely);
                frame.gas_remaining = 0;
                return ExecutionError.Error.OutOfGas;
            }
            frame.gas_remaining -= params.gas_cost;

            const current_stack_size: u16 = @intCast(frame.stack.size());
            if (current_stack_size < params.stack_req) {
                @branchHint(.cold);
                return ExecutionError.Error.StackUnderflow;
            }
            if (current_stack_size + params.stack_max_growth > 1024) {
                @branchHint(.cold);
                return ExecutionError.Error.StackOverflow;
            }
            continue :dispatch instructions[i].tag;
        },

        // .noop does nothing but go to next instruction
        // In future this will get optimized away to not needing to exist
        .noop => {
            const instruction = &instructions[i];
            pre_step(self, frame, instruction, &loop_iterations);

            i += 1;

            continue :dispatch instructions[i].tag;
        },
        .conditional_jump_invalid => {
            const instruction = &instructions[i];
            pre_step(self, frame, instruction, &loop_iterations);

            i += 1;

            const condition = frame.stack.pop_unsafe();
            if (condition != 0) {
                @branchHint(.cold);
                return ExecutionError.Error.InvalidJump;
            }

            continue :dispatch instructions[i].tag;
        },
        .conditional_jump_idx => {
            return ExecutionError.Error.InvalidJump;
        },
        .conditional_jump_pc => {
            const instruction = &instructions[i];
            pre_step(self, frame, instruction, &loop_iterations);

            const params = analysis.getInstructionParams(.conditional_jump_pc, instruction.id);

            const condition = frame.stack.pop_unsafe();

            i = if (condition != 0) params.jump_idx else i + 1;

            continue :dispatch instructions[i].tag;
        },
        // Many jumps have a known jump destination and we handle that here.
        .jump_pc => {
            const instruction = &instructions[i];
            pre_step(self, frame, instruction, &loop_iterations);
            const params = analysis.getInstructionParams(.jump_pc, instruction.id);
            i = params.jump_idx;
            continue :dispatch instructions[i].tag;
        },
        // This is a jump that is not known until compile time because
        // it is pushed to stack dynamically
        .jump_unresolved => {
            @branchHint(.unlikely);
            const instruction = &instructions[i];
            pre_step(self, frame, instruction, &loop_iterations);
            if (frame.stack.size() < 1) {
                @branchHint(.cold);
                return ExecutionError.Error.StackUnderflow;
            }
            const dest = frame.stack.pop_unsafe();
            if (!frame.valid_jumpdest(dest)) {
                @branchHint(.cold);
                return ExecutionError.Error.InvalidJump;
            }
            const dest_usize: usize = @intCast(dest);
            const idx = analysis.pc_to_block_start[dest_usize];
            if (idx == std.math.maxInt(u16) or idx >= instructions.len) {
                @branchHint(.cold);
                return ExecutionError.Error.InvalidJump;
            }
            i = idx;

            continue :dispatch instructions[i].tag;
        },
        // Some conditional jumps are not known until runtime because the value is a dynamic value
        .conditional_jump_unresolved => {
            const instruction = &instructions[i];
            pre_step(self, frame, instruction, &loop_iterations);
            if (frame.stack.size() < 2) {
                @branchHint(.cold);
                return ExecutionError.Error.StackUnderflow;
            }

            const dest = frame.stack.pop_unsafe();
            const condition = frame.stack.pop_unsafe();

            i = if (condition != 0) blk: {
                if (!frame.valid_jumpdest(dest)) {
                    return ExecutionError.Error.InvalidJump;
                }
                const dest_usize: usize = @intCast(dest);
                const idx = analysis.pc_to_block_start[dest_usize];
                if (idx == std.math.maxInt(u16) or idx >= instructions.len) {
                    return ExecutionError.Error.InvalidJump;
                }
                break :blk idx;
            } else i + 1;

            continue :dispatch instructions[i].tag;
        },
        // .word abstracts the common pattern of pushing a static value onto the stack
        // Instead of storing it as a u256 we dynamically read it from the bytecode on request
        // This allows us to keep our instruction bytecode compact without needing to include u256
        .word => {
            @branchHint(.likely);
            const instruction = &instructions[i];
            pre_step(self, frame, instruction, &loop_iterations);

            const params = analysis.getInstructionParams(.word, instruction.id);
            const word_bytes = params.word_bytes;

            i += 1;

            frame.stack.append_unsafe(bytesToU256(word_bytes));

            continue :dispatch instructions[i].tag;
        },
        // .pc handles the PC opcode. Since Frame doesn't include pc this is treated as a oen of atm
        // TODO: In future we want to remove this. This can be a .exec instead
        .pc => {
            @branchHint(.unlikely);
            const instruction = &instructions[i];
            pre_step(self, frame, instruction, &loop_iterations);

            const params = analysis.getInstructionParams(.pc, instruction.id);

            i += 1;

            frame.stack.append_unsafe(@as(u256, params.pc_value));

            continue :dispatch instructions[i].tag;
        },
        // Handle all real EVM opcodes directly
        .op_stop => {
            return error.STOP;
        },
        .op_add => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.arithmetic.op_add(frame);
            continue :dispatch next_tag;
        },
        .op_mul => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.arithmetic.op_mul(frame);
            continue :dispatch next_tag;
        },
        .op_sub => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.arithmetic.op_sub(frame);
            continue :dispatch next_tag;
        },
        .op_div => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.arithmetic.op_div(frame);
            continue :dispatch next_tag;
        },
        .op_sdiv => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.arithmetic.op_sdiv(frame);
            continue :dispatch next_tag;
        },
        .op_mod => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.arithmetic.op_mod(frame);
            continue :dispatch next_tag;
        },
        .op_smod => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.arithmetic.op_smod(frame);
            continue :dispatch next_tag;
        },
        .op_addmod => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.arithmetic.op_addmod(frame);
            continue :dispatch next_tag;
        },
        .op_mulmod => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.arithmetic.op_mulmod(frame);
            continue :dispatch next_tag;
        },
        .op_exp => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.arithmetic.op_exp(frame);
            continue :dispatch next_tag;
        },
        .op_signextend => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.arithmetic.op_signextend(frame);
            continue :dispatch next_tag;
        },

        // Comparison opcodes
        .op_lt => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.comparison.op_lt(frame);
            continue :dispatch next_tag;
        },
        .op_gt => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.comparison.op_gt(frame);
            continue :dispatch next_tag;
        },
        .op_slt => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.comparison.op_slt(frame);
            continue :dispatch next_tag;
        },
        .op_sgt => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.comparison.op_sgt(frame);
            continue :dispatch next_tag;
        },
        .op_eq => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.comparison.op_eq(frame);
            continue :dispatch next_tag;
        },
        .op_iszero => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.comparison.op_iszero(frame);
            continue :dispatch next_tag;
        },

        // Bitwise opcodes
        .op_and => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.bitwise.op_and(frame);
            continue :dispatch next_tag;
        },
        .op_or => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.bitwise.op_or(frame);
            continue :dispatch next_tag;
        },
        .op_xor => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.bitwise.op_xor(frame);
            continue :dispatch next_tag;
        },
        .op_not => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.bitwise.op_not(frame);
            continue :dispatch next_tag;
        },
        .op_byte => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.bitwise.op_byte(frame);
            continue :dispatch next_tag;
        },
        .op_shl => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.bitwise.op_shl(frame);
            continue :dispatch next_tag;
        },
        .op_shr => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.bitwise.op_shr(frame);
            continue :dispatch next_tag;
        },
        .op_sar => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.bitwise.op_sar(frame);
            continue :dispatch next_tag;
        },

        // Crypto opcodes
        .op_keccak256 => {
            // KECCAK256 already handles its own gas internally
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.crypto.op_keccak256(frame);
            continue :dispatch next_tag;
        },

        // Stack operations
        .op_pop => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.stack.op_pop(frame);
            continue :dispatch next_tag;
        },
        .op_push0 => {
            // PUSH0 is handled via .word tag, shouldn't reach here
            Log.err("PUSH0 reached in direct dispatch - should be handled via .word tag", .{});
            unreachable;
        },
        .op_dup1 => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.stack.op_dup1(frame);
            continue :dispatch next_tag;
        },
        .op_dup2 => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.stack.op_dup2(frame);
            continue :dispatch next_tag;
        },
        .op_dup3 => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.stack.op_dup3(frame);
            continue :dispatch next_tag;
        },
        .op_dup4 => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.stack.op_dup4(frame);
            continue :dispatch next_tag;
        },
        .op_dup5 => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.stack.op_dup5(frame);
            continue :dispatch next_tag;
        },
        .op_dup6 => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.stack.op_dup6(frame);
            continue :dispatch next_tag;
        },
        .op_dup7 => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.stack.op_dup7(frame);
            continue :dispatch next_tag;
        },
        .op_dup8 => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.stack.op_dup8(frame);
            continue :dispatch next_tag;
        },
        .op_dup9 => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.stack.op_dup9(frame);
            continue :dispatch next_tag;
        },
        .op_dup10 => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.stack.op_dup10(frame);
            continue :dispatch next_tag;
        },
        .op_dup11 => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.stack.op_dup11(frame);
            continue :dispatch next_tag;
        },
        .op_dup12 => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.stack.op_dup12(frame);
            continue :dispatch next_tag;
        },
        .op_dup13 => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.stack.op_dup13(frame);
            continue :dispatch next_tag;
        },
        .op_dup14 => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.stack.op_dup14(frame);
            continue :dispatch next_tag;
        },
        .op_dup15 => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.stack.op_dup15(frame);
            continue :dispatch next_tag;
        },
        .op_dup16 => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.stack.op_dup16(frame);
            continue :dispatch next_tag;
        },
        .op_swap1 => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.stack.op_swap1(frame);
            continue :dispatch next_tag;
        },
        .op_swap2 => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.stack.op_swap2(frame);
            continue :dispatch next_tag;
        },
        .op_swap3 => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.stack.op_swap3(frame);
            continue :dispatch next_tag;
        },
        .op_swap4 => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.stack.op_swap4(frame);
            continue :dispatch next_tag;
        },
        .op_swap5 => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.stack.op_swap5(frame);
            continue :dispatch next_tag;
        },
        .op_swap6 => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.stack.op_swap6(frame);
            continue :dispatch next_tag;
        },
        .op_swap7 => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.stack.op_swap7(frame);
            continue :dispatch next_tag;
        },
        .op_swap8 => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.stack.op_swap8(frame);
            continue :dispatch next_tag;
        },
        .op_swap9 => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.stack.op_swap9(frame);
            continue :dispatch next_tag;
        },
        .op_swap10 => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.stack.op_swap10(frame);
            continue :dispatch next_tag;
        },
        .op_swap11 => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.stack.op_swap11(frame);
            continue :dispatch next_tag;
        },
        .op_swap12 => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.stack.op_swap12(frame);
            continue :dispatch next_tag;
        },
        .op_swap13 => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.stack.op_swap13(frame);
            continue :dispatch next_tag;
        },
        .op_swap14 => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.stack.op_swap14(frame);
            continue :dispatch next_tag;
        },
        .op_swap15 => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.stack.op_swap15(frame);
            continue :dispatch next_tag;
        },
        .op_swap16 => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.stack.op_swap16(frame);
            continue :dispatch next_tag;
        },

        // Memory operations
        .op_mload => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.memory.op_mload(frame);
            continue :dispatch next_tag;
        },
        .op_mstore => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.memory.op_mstore(frame);
            continue :dispatch next_tag;
        },
        .op_mstore8 => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.memory.op_mstore8(frame);
            continue :dispatch next_tag;
        },
        .op_msize => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.memory.op_msize(frame);
            continue :dispatch next_tag;
        },
        .op_mcopy => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.memory.op_mcopy(frame);
            continue :dispatch next_tag;
        },

        // Storage operations
        .op_sload => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.storage.op_sload(frame);
            continue :dispatch next_tag;
        },
        .op_sstore => {
            // Dynamic gas for SSTORE
            const dynamic_gas_fn = @import("../gas/dynamic_gas.zig").sstore_dynamic_gas;
            const gas_cost = try dynamic_gas_fn(frame);
            try frame.consume_gas(gas_cost);

            i += 1;
            const next_tag = instructions[i].tag;
            try execution.storage.op_sstore(frame);
            continue :dispatch next_tag;
        },
        .op_tload => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.storage.op_tload(frame);
            continue :dispatch next_tag;
        },
        .op_tstore => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.storage.op_tstore(frame);
            continue :dispatch next_tag;
        },

        // Control flow
        .op_jump => {
            // JUMP is handled via synthetic tags, shouldn't reach here
            unreachable;
        },
        .op_jumpi => {
            // JUMPI is handled via synthetic tags, shouldn't reach here
            unreachable;
        },
        .op_pc => {
            // PC is handled via synthetic .pc tag, shouldn't reach here
            unreachable;
        },
        .op_jumpdest => {
            // JUMPDEST is a noop
            i += 1;
            continue :dispatch instructions[i].tag;
        },
        .op_gas => {
            // GAS opcode simply pushes the remaining gas onto the stack
            frame.stack.append_unsafe(@as(u256, frame.gas_remaining));
            i += 1;
            continue :dispatch instructions[i].tag;
        },

        // Push operations (handled via .word synthetic tag)
        .op_push1, .op_push2, .op_push3, .op_push4, .op_push5, .op_push6, .op_push7, .op_push8, .op_push9, .op_push10, .op_push11, .op_push12, .op_push13, .op_push14, .op_push15, .op_push16, .op_push17, .op_push18, .op_push19, .op_push20, .op_push21, .op_push22, .op_push23, .op_push24, .op_push25, .op_push26, .op_push27, .op_push28, .op_push29, .op_push30, .op_push31, .op_push32 => {
            // PUSH instructions are handled via .word tag, shouldn't reach here
            unreachable;
        },

        // Environment opcodes
        .op_address => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.environment.op_address(frame);
            continue :dispatch next_tag;
        },
        .op_balance => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.environment.op_balance(frame);
            continue :dispatch next_tag;
        },
        .op_origin => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.environment.op_origin(frame);
            continue :dispatch next_tag;
        },
        .op_caller => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.environment.op_caller(frame);
            continue :dispatch next_tag;
        },
        .op_callvalue => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.environment.op_callvalue(frame);
            continue :dispatch next_tag;
        },
        .op_calldataload => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.environment.op_calldataload(frame);
            continue :dispatch next_tag;
        },
        .op_calldatasize => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.environment.op_calldatasize(frame);
            continue :dispatch next_tag;
        },
        .op_calldatacopy => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.environment.op_calldatacopy(frame);
            continue :dispatch next_tag;
        },
        .op_codesize => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.environment.op_codesize(frame);
            continue :dispatch next_tag;
        },
        .op_codecopy => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.environment.op_codecopy(frame);
            continue :dispatch next_tag;
        },
        .op_gasprice => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.environment.op_gasprice(frame);
            continue :dispatch next_tag;
        },
        .op_extcodesize => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.environment.op_extcodesize(frame);
            continue :dispatch next_tag;
        },
        .op_extcodecopy => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.environment.op_extcodecopy(frame);
            continue :dispatch next_tag;
        },
        .op_returndatasize => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.environment.op_returndatasize(frame);
            continue :dispatch next_tag;
        },
        .op_returndatacopy => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.environment.op_returndatacopy(frame);
            continue :dispatch next_tag;
        },
        .op_extcodehash => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.environment.op_extcodehash(frame);
            continue :dispatch next_tag;
        },
        .op_selfbalance => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.environment.op_selfbalance(frame);
            continue :dispatch next_tag;
        },

        // Block opcodes
        .op_blockhash => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.block.op_blockhash(frame);
            continue :dispatch next_tag;
        },
        .op_coinbase => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.block.op_coinbase(frame);
            continue :dispatch next_tag;
        },
        .op_timestamp => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.block.op_timestamp(frame);
            continue :dispatch next_tag;
        },
        .op_number => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.block.op_number(frame);
            continue :dispatch next_tag;
        },
        .op_difficulty => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.block.op_difficulty(frame);
            continue :dispatch next_tag;
        },
        .op_gaslimit => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.block.op_gaslimit(frame);
            continue :dispatch next_tag;
        },
        .op_chainid => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.environment.op_chainid(frame);
            continue :dispatch next_tag;
        },
        .op_basefee => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.block.op_basefee(frame);
            continue :dispatch next_tag;
        },
        .op_blobhash => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.block.op_blobhash(frame);
            continue :dispatch next_tag;
        },
        .op_blobbasefee => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.block.op_blobbasefee(frame);
            continue :dispatch next_tag;
        },

        // Log operations
        .op_log0 => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.log.log_0(frame);
            continue :dispatch next_tag;
        },
        .op_log1 => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.log.log_1(frame);
            continue :dispatch next_tag;
        },
        .op_log2 => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.log.log_2(frame);
            continue :dispatch next_tag;
        },
        .op_log3 => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.log.log_3(frame);
            continue :dispatch next_tag;
        },
        .op_log4 => {
            i += 1;
            const next_tag = instructions[i].tag;
            try execution.log.log_4(frame);
            continue :dispatch next_tag;
        },

        // System operations
        .op_create => {
            @branchHint(.cold);
            // Dynamic gas for CREATE
            const dynamic_gas_fn = @import("../gas/dynamic_gas.zig").create_dynamic_gas;
            const gas_cost = try dynamic_gas_fn(frame);
            try frame.consume_gas(gas_cost);

            i += 1;
            const next_tag = instructions[i].tag;
            try execution.system.op_create(frame);
            continue :dispatch next_tag;
        },
        .op_call => {
            // Dynamic gas for CALL
            const dynamic_gas_fn = @import("../gas/dynamic_gas.zig").call_dynamic_gas;
            const gas_cost = try dynamic_gas_fn(frame);
            try frame.consume_gas(gas_cost);

            i += 1;
            const next_tag = instructions[i].tag;
            try execution.system.op_call(frame);
            continue :dispatch next_tag;
        },
        .op_callcode => {
            // Dynamic gas for CALLCODE
            const dynamic_gas_fn = @import("../gas/dynamic_gas.zig").callcode_dynamic_gas;
            const gas_cost = try dynamic_gas_fn(frame);
            try frame.consume_gas(gas_cost);

            i += 1;
            const next_tag = instructions[i].tag;
            try execution.system.op_callcode(frame);
            continue :dispatch next_tag;
        },
        .op_return => {
            try execution.control.op_return(frame);
            return error.RETURN;
        },
        .op_delegatecall => {
            // Dynamic gas for DELEGATECALL
            const dynamic_gas_fn = @import("../gas/dynamic_gas.zig").delegatecall_dynamic_gas;
            const gas_cost = try dynamic_gas_fn(frame);
            try frame.consume_gas(gas_cost);

            i += 1;
            const next_tag = instructions[i].tag;
            try execution.system.op_delegatecall(frame);
            continue :dispatch next_tag;
        },
        .op_create2 => {
            @branchHint(.cold);
            // Dynamic gas for CREATE2
            const dynamic_gas_fn = @import("../gas/dynamic_gas.zig").create2_dynamic_gas;
            const gas_cost = try dynamic_gas_fn(frame);
            try frame.consume_gas(gas_cost);

            i += 1;
            const next_tag = instructions[i].tag;
            try execution.system.op_create2(frame);
            continue :dispatch next_tag;
        },
        .op_staticcall => {
            // Dynamic gas for STATICCALL
            const dynamic_gas_fn = @import("../gas/dynamic_gas.zig").staticcall_dynamic_gas;
            const gas_cost = try dynamic_gas_fn(frame);
            try frame.consume_gas(gas_cost);

            i += 1;
            const next_tag = instructions[i].tag;
            try execution.system.op_staticcall(frame);
            continue :dispatch next_tag;
        },
        .op_revert => {
            try execution.control.op_revert(frame);
            return error.REVERT;
        },
        .op_invalid => {
            return error.INVALID;
        },
        .op_selfdestruct => {
            @branchHint(.cold);
            try execution.system.op_selfdestruct(frame);
            return error.STOP;
        },
    }
}

test "BEGINBLOCK: upfront OutOfGas when gas < block base cost" {
    const allocator = std.testing.allocator;
    const OpcodeMetadata = @import("../opcode_metadata/opcode_metadata.zig");
    const Analysis = @import("../analysis.zig").CodeAnalysis;
    const MemoryDatabase = @import("../state/memory_database.zig").MemoryDatabase;
    const AccessList = @import("../access_list/access_list.zig").AccessList;
    const CallJournal = @import("../call_frame_stack.zig").CallJournal;
    const Host = @import("../host.zig").Host;
    const SelfDestruct = @import("../self_destruct.zig").SelfDestruct;
    const CreatedContracts = @import("../created_contracts.zig").CreatedContracts;
    const primitives = @import("primitives");

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
    const host = Host.init(&vm);

    // Gas is less than block base cost (5*3 = 15)
    var frame = try Frame.init(
        10, // gas_remaining
        false, // static_call
        0, // call_depth
        primitives.Address.ZERO_ADDRESS, // contract_address
        primitives.Address.ZERO_ADDRESS, // caller
        0, // value
        &analysis,
        host,
        db_interface,
        allocator,
    );
    defer frame.deinit(allocator);

    const result = interpret(&vm, &frame);
    try std.testing.expectError(ExecutionError.Error.OutOfGas, result);
}

test "interpret: keccak+pop+JUMPDEST+STOP fragment halts with STOP" {
    const allocator = std.testing.allocator;
    const OpcodeMetadata = @import("../opcode_metadata/opcode_metadata.zig");
    const Analysis = @import("../analysis.zig").CodeAnalysis;
    const MemoryDatabase = @import("../state/memory_database.zig").MemoryDatabase;
    const Host = @import("../host.zig").Host;
    const primitives = @import("primitives");

    const code = &[_]u8{
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0x20, // KECCAK256
        0x50, // POP
        0x5b, // JUMPDEST
        0x00, // STOP
    };

    var analysis = try Analysis.from_code(allocator, code, &OpcodeMetadata.DEFAULT);
    defer analysis.deinit();

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();

    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    const host = Host.init(&vm);

    var frame = try Frame.init(
        100000, // gas_remaining
        false, // static
        0, // depth
        primitives.Address.ZERO_ADDRESS, // contract
        primitives.Address.ZERO_ADDRESS, // caller
        0, // value
        &analysis,
        host,
        db_interface,
        allocator,
    );
    defer frame.deinit(allocator);

    try std.testing.expectError(ExecutionError.Error.STOP, interpret(&vm, &frame));
}

test "interpret: fused PUSH+JUMP to forward JUMPDEST halts with STOP" {
    const allocator = std.testing.allocator;
    const OpcodeMetadata = @import("../opcode_metadata/opcode_metadata.zig");
    const Analysis = @import("../analysis.zig").CodeAnalysis;
    const MemoryDatabase = @import("../state/memory_database.zig").MemoryDatabase;
    const Host = @import("../host.zig").Host;
    const primitives = @import("primitives");

    const code = &[_]u8{ 0x60, 0x03, 0x56, 0x5b, 0x00 }; // PUSH1 3; JUMP; JUMPDEST; STOP
    var analysis = try Analysis.from_code(allocator, code, &OpcodeMetadata.DEFAULT);
    defer analysis.deinit();

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();

    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    const host = Host.init(&vm);
    var frame = try Frame.init(
        100000,
        false,
        0,
        primitives.Address.ZERO_ADDRESS,
        primitives.Address.ZERO_ADDRESS,
        0,
        &analysis,
        host,
        db_interface,
        allocator,
    );
    defer frame.deinit(allocator);

    try std.testing.expectError(ExecutionError.Error.STOP, interpret(&vm, &frame));
}

test "BEGINBLOCK: stack underflow detected at block entry" {
    const allocator = std.testing.allocator;
    const OpcodeMetadata = @import("../opcode_metadata/opcode_metadata.zig");
    const Analysis = @import("../analysis.zig").CodeAnalysis;
    const MemoryDatabase = @import("../state/memory_database.zig").MemoryDatabase;
    const AccessList = @import("../access_list/access_list.zig").AccessList;
    const CallJournal = @import("../call_frame_stack.zig").CallJournal;
    const Host = @import("../host.zig").Host;
    const SelfDestruct = @import("../self_destruct.zig").SelfDestruct;
    const CreatedContracts = @import("../created_contracts.zig").CreatedContracts;
    const primitives = @import("primitives");

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

    const host = Host.init(&vm);

    var frame = try Frame.init(
        1000,
        false,
        0,
        primitives.Address.ZERO_ADDRESS,
        primitives.Address.ZERO_ADDRESS,
        0,
        &analysis,
        host,
        db_interface,
        allocator,
    );
    defer frame.deinit(allocator);

    // Stack is empty -> should fail at BEGINBLOCK
    const result = interpret(&vm, &frame);
    try std.testing.expectError(ExecutionError.Error.StackUnderflow, result);
}

test "BEGINBLOCK: stack overflow detected from max growth" {
    const allocator = std.testing.allocator;
    const OpcodeMetadata = @import("../opcode_metadata/opcode_metadata.zig");
    const Analysis = @import("../analysis.zig").CodeAnalysis;
    const MemoryDatabase = @import("../state/memory_database.zig").MemoryDatabase;
    const AccessList = @import("../access_list/access_list.zig").AccessList;
    const CallJournal = @import("../call_frame_stack.zig").CallJournal;
    const Host = @import("../host.zig").Host;
    const SelfDestruct = @import("../self_destruct.zig").SelfDestruct;
    const CreatedContracts = @import("../created_contracts.zig").CreatedContracts;
    const primitives = @import("primitives");
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

    const host = Host.init(&vm);

    var frame = try Frame.init(
        1000,
        false,
        0,
        primitives.Address.ZERO_ADDRESS,
        primitives.Address.ZERO_ADDRESS,
        0,
        &analysis,
        host,
        db_interface,
        allocator,
    );
    defer frame.deinit(allocator);

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
    const Analysis = @import("../analysis.zig").CodeAnalysis;
    const MemoryDatabase = @import("../state/memory_database.zig").MemoryDatabase;
    const AccessList = @import("../access_list/access_list.zig").AccessList;
    const CallJournal = @import("../call_frame_stack.zig").CallJournal;
    const Host = @import("../host.zig").Host;
    const SelfDestruct = @import("../self_destruct.zig").SelfDestruct;
    const CreatedContracts = @import("../created_contracts.zig").CreatedContracts;
    const primitives = @import("primitives");

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
    const host = Host.init(&vm);

    var frame = try Frame.init(
        1_000_000,
        false,
        0,
        primitives.Address.ZERO_ADDRESS,
        primitives.Address.ZERO_ADDRESS,
        0,
        &analysis,
        host,
        db_interface,
        allocator,
    );
    defer frame.deinit(allocator);

    try interpret(&vm, &frame);
    const output = host.get_output();
    try std.testing.expect(output.len == 32);
    try std.testing.expect(output[31] == 1);
}

test "interpret: minimal dispatcher executes selected branch and returns 32 bytes" {
    const allocator = std.testing.allocator;
    const OpcodeMetadata = @import("../opcode_metadata/opcode_metadata.zig");
    const Analysis = @import("../analysis.zig").CodeAnalysis;
    const MemoryDatabase = @import("../state/memory_database.zig").MemoryDatabase;
    const Host = @import("../host.zig").Host;
    const primitives = @import("primitives");

    // Build minimal dispatcher that checks for selector 0x11223344 and returns 32-byte 0x01 on match
    // Layout:
    // 00: PUSH1 0x00; 02: CALLDATALOAD; 03: PUSH1 0xe0; 05: SHR; 06: PUSH4 0x11223344; 0b: EQ
    // 0c: PUSH1 0x16; 0e: JUMPI; fallback: 0f: PUSH1 0x00; 11: PUSH1 0x00; 13: REVERT
    // 14: JUMPDEST; 15: PUSH1 0x01; 17: PUSH1 0x1f; 19: MSTORE; 1a: PUSH1 0x20; 1c: PUSH1 0x00; 1e: RETURN
    const code = &[_]u8{
        0x60, 0x00,
        0x35, 0x60,
        0xe0, 0x1c,
        0x63, 0x11,
        0x22, 0x33,
        0x44, 0x14,
        0x60, 0x16,
        0x57, 0x60,
        0x00, 0x60,
        0x00, 0xfd,
        0x5b, 0x60,
        0x01, 0x60,
        0x1f, 0x52,
        0x60, 0x20,
        0x60, 0x00,
        0xf3,
    };

    var analysis = try Analysis.from_code(allocator, code, &OpcodeMetadata.DEFAULT);
    defer analysis.deinit();

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();

    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    const host = Host.init(&vm);

    // Case 1: matching selector 0x11223344
    var frame1 = try Frame.init(
        1_000_000,
        false,
        0,
        primitives.Address.ZERO_ADDRESS,
        primitives.Address.ZERO_ADDRESS,
        0,
        &analysis,
        host,
        db_interface,
        allocator,
    );
    defer frame1.deinit(allocator);

    const calldata_match = [_]u8{ 0x11, 0x22, 0x33, 0x44 };
    vm.current_input = &calldata_match;

    try interpret(&vm, &frame1);
    const out1 = host.get_output();
    try std.testing.expect(out1.len == 32);
    try std.testing.expect(out1[31] == 1);

    // Case 2: non-matching selector -> fallback REVERT with empty output
    var frame2 = try Frame.init(
        1_000_000,
        false,
        0,
        primitives.Address.ZERO_ADDRESS,
        primitives.Address.ZERO_ADDRESS,
        0,
        &analysis,
        host,
        db_interface,
        allocator,
    );
    defer frame2.deinit(allocator);

    const calldata_nomatch = [_]u8{ 0xaa, 0xbb, 0xcc, 0xdd };
    vm.current_input = &calldata_nomatch;
    const err2 = interpret(&vm, &frame2);
    try std.testing.expectError(ExecutionError.Error.REVERT, err2);
}

test "interpret: dispatcher using AND 0xffffffff extracts selector and returns 32 bytes" {
    const allocator = std.testing.allocator;
    const OpcodeMetadata = @import("../opcode_metadata/opcode_metadata.zig");
    const Analysis = @import("../analysis.zig").CodeAnalysis;
    const MemoryDatabase = @import("../state/memory_database.zig").MemoryDatabase;
    const Host = @import("../host.zig").Host;
    const primitives = @import("primitives");

    // Bytecode that masks selector with AND 0xffffffff instead of SHR
    const code = &[_]u8{
        0x60, 0x00, // PUSH1 0
        0x35, // CALLDATALOAD
        0x63, 0xff, 0xff, 0xff, 0xff, // PUSH4 0xffffffff
        0x16, // AND
        0x63, 0x30, 0x62, 0x7b, 0x7c, // PUSH4 0x30627b7c
        0x14, // EQ
        0x60, 0x16, // PUSH1 0x16
        0x57, // JUMPI
        0x60, 0x00, // PUSH1 0
        0x60, 0x00, // PUSH1 0
        0xfd, // REVERT
        0x5b, // JUMPDEST @ 0x16
        0x60, 0x01, // PUSH1 1
        0x60, 0x1f, // PUSH1 31
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3, // RETURN
    };

    var analysis = try Analysis.from_code(allocator, code, &OpcodeMetadata.DEFAULT);
    defer analysis.deinit();

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();

    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    const host = Host.init(&vm);

    var frame = try Frame.init(
        1_000_000,
        false,
        0,
        primitives.Address.ZERO_ADDRESS,
        primitives.Address.ZERO_ADDRESS,
        0,
        &analysis,
        host,
        db_interface,
        allocator,
    );
    defer frame.deinit(allocator);

    const selector = [_]u8{ 0x30, 0x62, 0x7b, 0x7c };
    vm.current_input = &selector;

    try interpret(&vm, &frame);
    const out = host.get_output();
    try std.testing.expect(out.len == 32);
    try std.testing.expect(out[31] == 1);
}

test "bytesToU256 correctly converts bytecode to u256" {
    // Test single byte
    const bytes1 = [_]u8{0x42};
    try std.testing.expectEqual(@as(u256, 0x42), bytesToU256(bytes1[0..]));

    // Test two bytes
    const bytes2 = [_]u8{ 0x12, 0x34 };
    try std.testing.expectEqual(@as(u256, 0x1234), bytesToU256(bytes2[0..]));

    // Test 32 bytes (max) - all 0xFF bytes
    const bytes32 = [_]u8{0xFF} ** 32;
    const expected32 = std.math.maxInt(u256); // All bits set
    try std.testing.expectEqual(expected32, bytesToU256(bytes32[0..]));

    // Test partial slice of larger array
    const bytes_partial = [_]u8{ 0xAA, 0xBB, 0xCC, 0xDD, 0xEE };
    try std.testing.expectEqual(@as(u256, 0xAABBCC), bytesToU256(bytes_partial[0..3]));
}

test "interpret: ERC20 bench dispatcher returns 32 bytes for 0x30627b7c selector under direct interpret" {
    const allocator = std.testing.allocator;
    const MemoryDatabase = @import("../state/memory_database.zig").MemoryDatabase;
    const OpcodeMetadata = @import("../opcode_metadata/opcode_metadata.zig");
    const Analysis = @import("../analysis.zig").CodeAnalysis;
    const primitives = @import("primitives");

    // Read initcode and calldata from official bench files
    const initcode_hex_path = "/Users/williamcory/guillotine/bench/official/cases/erc20-transfer/bytecode.txt";
    const calldata_hex_path = "/Users/williamcory/guillotine/bench/official/cases/erc20-transfer/calldata.txt";

    const init_f = try std.fs.openFileAbsolute(initcode_hex_path, .{});
    defer init_f.close();
    const init_hex = try init_f.readToEndAlloc(allocator, 64 * 1024);
    defer allocator.free(init_hex);
    const init_bytes = try allocator.alloc(u8, init_hex.len / 2);
    defer allocator.free(init_bytes);
    _ = try std.fmt.hexToBytes(init_bytes, std.mem.trim(u8, init_hex, " \t\n\r"));

    const cal_f = try std.fs.openFileAbsolute(calldata_hex_path, .{});
    defer cal_f.close();
    const cal_hex = try cal_f.readToEndAlloc(allocator, 1024);
    defer allocator.free(cal_hex);
    const cal_bytes = try allocator.alloc(u8, std.mem.trim(u8, cal_hex, " \t\n\r").len / 2);
    defer allocator.free(cal_bytes);
    _ = try std.fmt.hexToBytes(cal_bytes, std.mem.trim(u8, cal_hex, " \t\n\r"));

    // Setup VM and deploy to get runtime code
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();

    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    const deployer = primitives.Address.ZERO_ADDRESS;
    const create_res = try vm.create_contract(deployer, 0, init_bytes, 50_000_000);
    try std.testing.expect(create_res.success);
    const contract_addr = create_res.address;

    // Fetch deployed runtime code
    const runtime = vm.state.get_code(contract_addr);
    try std.testing.expect(runtime.len > 100);

    // Analyze and execute directly with interpreter, bypassing call()
    var analysis = try Analysis.from_code(allocator, runtime, &OpcodeMetadata.DEFAULT);
    defer analysis.deinit();

    const host = @import("../host.zig").Host.init(&vm);
    var frame = try Frame.init(
        5_000_000,
        false,
        0,
        contract_addr,
        deployer,
        0,
        &analysis,
        host,
        db_interface,
        allocator,
    );
    defer frame.deinit(allocator);

    // Set calldata to the 4-byte selector used by the bench
    vm.current_input = cal_bytes;

    // Run interpreter
    try interpret(&vm, &frame);
    const out = host.get_output();
    try std.testing.expect(out.len >= 32);
    try std.testing.expect(out[out.len - 1] == 1);
}

test "interpret: simple JUMP to valid JUMPDEST" {
    const allocator = std.testing.allocator;
    const OpcodeMetadata = @import("../opcode_metadata/opcode_metadata.zig");
    const MemoryDatabase = @import("../state/memory_database.zig").MemoryDatabase;
    const Analysis = @import("../analysis.zig").CodeAnalysis;
    const Host = @import("../host.zig").Host;
    const primitives = @import("primitives");

    // Simple jump: PUSH1 0x05, JUMP, INVALID, INVALID, JUMPDEST, STOP
    const code = &[_]u8{
        0x60, 0x05, // PUSH1 0x05
        0x56, // JUMP
        0xfe, // INVALID
        0xfe, // INVALID
        0x5b, // JUMPDEST at PC 5
        0x00, // STOP
    };

    var analysis = try Analysis.from_code(allocator, code, &OpcodeMetadata.DEFAULT);
    defer analysis.deinit();

    // Verify JUMPDEST is valid
    try std.testing.expect(analysis.jumpdest_array.is_valid_jumpdest(5));

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();

    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    const host = Host.init(&vm);

    var frame = try Frame.init(
        100000,
        false,
        0,
        primitives.Address.ZERO_ADDRESS,
        primitives.Address.ZERO_ADDRESS,
        0,
        &analysis,
        host,
        db_interface,
        allocator,
    );
    defer frame.deinit(allocator);

    // Should execute successfully with STOP
    try std.testing.expectError(ExecutionError.Error.STOP, interpret(&vm, &frame));
}

test "interpret: JUMP to invalid destination (not JUMPDEST)" {
    const allocator = std.testing.allocator;
    const OpcodeMetadata = @import("../opcode_metadata/opcode_metadata.zig");
    const MemoryDatabase = @import("../state/memory_database.zig").MemoryDatabase;
    const Analysis = @import("../analysis.zig").CodeAnalysis;
    const Host = @import("../host.zig").Host;
    const primitives = @import("primitives");

    // Jump to non-JUMPDEST: PUSH1 0x04, JUMP, INVALID, ADD, STOP
    const code = &[_]u8{
        0x60, 0x04, // PUSH1 0x04
        0x56, // JUMP
        0xfe, // INVALID
        0x01, // ADD at PC 4 (not a JUMPDEST)
        0x00, // STOP
    };

    var analysis = try Analysis.from_code(allocator, code, &OpcodeMetadata.DEFAULT);
    defer analysis.deinit();

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();

    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    const host = Host.init(&vm);

    var frame = try Frame.init(
        100000,
        false,
        0,
        primitives.Address.ZERO_ADDRESS,
        primitives.Address.ZERO_ADDRESS,
        0,
        &analysis,
        host,
        db_interface,
        allocator,
    );
    defer frame.deinit(allocator);

    // Should fail with InvalidJump
    try std.testing.expectError(ExecutionError.Error.InvalidJump, interpret(&vm, &frame));
}

test "interpret: JUMP to out-of-bounds destination" {
    const allocator = std.testing.allocator;
    const OpcodeMetadata = @import("../opcode_metadata/opcode_metadata.zig");
    const MemoryDatabase = @import("../state/memory_database.zig").MemoryDatabase;
    const Analysis = @import("../analysis.zig").CodeAnalysis;
    const Host = @import("../host.zig").Host;
    const primitives = @import("primitives");

    // Jump beyond code size: PUSH1 0xFF, JUMP, STOP
    const code = &[_]u8{
        0x60, 0xFF, // PUSH1 0xFF (255, way beyond code size)
        0x56, // JUMP
        0x00, // STOP
    };

    var analysis = try Analysis.from_code(allocator, code, &OpcodeMetadata.DEFAULT);
    defer analysis.deinit();

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();

    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    const host = Host.init(&vm);

    var frame = try Frame.init(
        100000,
        false,
        0,
        primitives.Address.ZERO_ADDRESS,
        primitives.Address.ZERO_ADDRESS,
        0,
        &analysis,
        host,
        db_interface,
        allocator,
    );
    defer frame.deinit(allocator);

    // Should fail with InvalidJump
    try std.testing.expectError(ExecutionError.Error.InvalidJump, interpret(&vm, &frame));
}

test "interpret: JUMPI with true condition" {
    const allocator = std.testing.allocator;
    const OpcodeMetadata = @import("../opcode_metadata/opcode_metadata.zig");
    const MemoryDatabase = @import("../state/memory_database.zig").MemoryDatabase;
    const Analysis = @import("../analysis.zig").CodeAnalysis;
    const Host = @import("../host.zig").Host;
    const primitives = @import("primitives");

    // JUMPI with true condition: PUSH1 0x08, PUSH1 0x01, JUMPI, INVALID, INVALID, JUMPDEST, STOP
    const code = &[_]u8{
        0x60, 0x08, // PUSH1 0x08 (destination)
        0x60, 0x01, // PUSH1 0x01 (condition = true)
        0x57, // JUMPI
        0xfe, // INVALID
        0xfe, // INVALID
        0x5b, // JUMPDEST at PC 8
        0x00, // STOP
    };

    var analysis = try Analysis.from_code(allocator, code, &OpcodeMetadata.DEFAULT);
    defer analysis.deinit();

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();

    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    const host = Host.init(&vm);

    var frame = try Frame.init(
        100000,
        false,
        0,
        primitives.Address.ZERO_ADDRESS,
        primitives.Address.ZERO_ADDRESS,
        0,
        &analysis,
        host,
        db_interface,
        allocator,
    );
    defer frame.deinit(allocator);

    // Should jump over INVALID and reach STOP
    try std.testing.expectError(ExecutionError.Error.STOP, interpret(&vm, &frame));
}

test "interpret: JUMPI with false condition" {
    const allocator = std.testing.allocator;
    const OpcodeMetadata = @import("../opcode_metadata/opcode_metadata.zig");
    const MemoryDatabase = @import("../state/memory_database.zig").MemoryDatabase;
    const Analysis = @import("../analysis.zig").CodeAnalysis;
    const Host = @import("../host.zig").Host;
    const primitives = @import("primitives");

    // JUMPI with false condition: PUSH1 0x08, PUSH1 0x00, JUMPI, STOP, INVALID, JUMPDEST, INVALID
    const code = &[_]u8{
        0x60, 0x08, // PUSH1 0x08 (destination)
        0x60, 0x00, // PUSH1 0x00 (condition = false)
        0x57, // JUMPI
        0x00, // STOP (should execute this)
        0xfe, // INVALID
        0x5b, // JUMPDEST at PC 8
        0xfe, // INVALID
    };

    var analysis = try Analysis.from_code(allocator, code, &OpcodeMetadata.DEFAULT);
    defer analysis.deinit();

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();

    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    const host = Host.init(&vm);

    var frame = try Frame.init(
        100000,
        false,
        0,
        primitives.Address.ZERO_ADDRESS,
        primitives.Address.ZERO_ADDRESS,
        0,
        &analysis,
        host,
        db_interface,
        allocator,
    );
    defer frame.deinit(allocator);

    // Should not jump and reach STOP
    try std.testing.expectError(ExecutionError.Error.STOP, interpret(&vm, &frame));
}

test "interpret: JUMPI to invalid destination with true condition" {
    const allocator = std.testing.allocator;
    const OpcodeMetadata = @import("../opcode_metadata/opcode_metadata.zig");
    const MemoryDatabase = @import("../state/memory_database.zig").MemoryDatabase;
    const Analysis = @import("../analysis.zig").CodeAnalysis;
    const Host = @import("../host.zig").Host;
    const primitives = @import("primitives");

    // JUMPI to non-JUMPDEST: PUSH1 0x06, PUSH1 0x01, JUMPI, STOP, ADD
    const code = &[_]u8{
        0x60, 0x06, // PUSH1 0x06 (destination - not a JUMPDEST)
        0x60, 0x01, // PUSH1 0x01 (condition = true)
        0x57, // JUMPI
        0x00, // STOP
        0x01, // ADD at PC 6 (not a JUMPDEST)
    };

    var analysis = try Analysis.from_code(allocator, code, &OpcodeMetadata.DEFAULT);
    defer analysis.deinit();

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();

    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    const host = Host.init(&vm);

    var frame = try Frame.init(
        100000,
        false,
        0,
        primitives.Address.ZERO_ADDRESS,
        primitives.Address.ZERO_ADDRESS,
        0,
        &analysis,
        host,
        db_interface,
        allocator,
    );
    defer frame.deinit(allocator);

    // Should fail with InvalidJump
    try std.testing.expectError(ExecutionError.Error.InvalidJump, interpret(&vm, &frame));
}

test "interpret: PC opcode returns correct program counter" {
    const allocator = std.testing.allocator;
    const OpcodeMetadata = @import("../opcode_metadata/opcode_metadata.zig");
    const MemoryDatabase = @import("../state/memory_database.zig").MemoryDatabase;
    const Analysis = @import("../analysis.zig").CodeAnalysis;
    const Host = @import("../host.zig").Host;
    const primitives = @import("primitives");

    // Test PC at different positions: PC, PC, PC, STOP
    const code = &[_]u8{
        0x58, // PC at position 0
        0x58, // PC at position 1
        0x58, // PC at position 2
        0x00, // STOP
    };

    var analysis = try Analysis.from_code(allocator, code, &OpcodeMetadata.DEFAULT);
    defer analysis.deinit();

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();

    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    const host = Host.init(&vm);

    var frame = try Frame.init(
        100000,
        false,
        0,
        primitives.Address.ZERO_ADDRESS,
        primitives.Address.ZERO_ADDRESS,
        0,
        &analysis,
        host,
        db_interface,
        allocator,
    );
    defer frame.deinit(allocator);

    // Execute and check stack
    try std.testing.expectError(ExecutionError.Error.STOP, interpret(&vm, &frame));

    // Should have pushed 0, 1, 2 onto stack
    try std.testing.expectEqual(@as(usize, 3), frame.stack.size());
    try std.testing.expectEqual(@as(u256, 2), frame.stack.data[2]);
    try std.testing.expectEqual(@as(u256, 1), frame.stack.data[1]);
    try std.testing.expectEqual(@as(u256, 0), frame.stack.data[0]);
}

test "interpret: word instruction pushes correct values" {
    const allocator = std.testing.allocator;
    const OpcodeMetadata = @import("../opcode_metadata/opcode_metadata.zig");
    const MemoryDatabase = @import("../state/memory_database.zig").MemoryDatabase;
    const Analysis = @import("../analysis.zig").CodeAnalysis;
    const Host = @import("../host.zig").Host;
    const primitives = @import("primitives");

    // Various PUSH operations with different sizes
    const code = &[_]u8{
        0x60, 0x42, // PUSH1 0x42
        0x61, 0x12, 0x34, // PUSH2 0x1234
        0x63, 0xDE, 0xAD, 0xBE, 0xEF, // PUSH4 0xDEADBEEF
        0x00, // STOP
    };

    var analysis = try Analysis.from_code(allocator, code, &OpcodeMetadata.DEFAULT);
    defer analysis.deinit();

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();

    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    const host = Host.init(&vm);

    var frame = try Frame.init(
        100000,
        false,
        0,
        primitives.Address.ZERO_ADDRESS,
        primitives.Address.ZERO_ADDRESS,
        0,
        &analysis,
        host,
        db_interface,
        allocator,
    );
    defer frame.deinit(allocator);

    // Execute
    try std.testing.expectError(ExecutionError.Error.STOP, interpret(&vm, &frame));

    // Check stack values
    try std.testing.expectEqual(@as(usize, 3), frame.stack.size());
    try std.testing.expectEqual(@as(u256, 0xDEADBEEF), frame.stack.data[2]);
    try std.testing.expectEqual(@as(u256, 0x1234), frame.stack.data[1]);
    try std.testing.expectEqual(@as(u256, 0x42), frame.stack.data[0]);
}

test "interpret: dynamic gas calculation for memory expansion" {
    const allocator = std.testing.allocator;
    const OpcodeMetadata = @import("../opcode_metadata/opcode_metadata.zig");
    const MemoryDatabase = @import("../state/memory_database.zig").MemoryDatabase;
    const Analysis = @import("../analysis.zig").CodeAnalysis;
    const Host = @import("../host.zig").Host;
    const primitives = @import("primitives");

    // MLOAD with large offset to trigger memory expansion
    const code = &[_]u8{
        0x61, 0x01, 0x00, // PUSH2 0x0100 (256)
        0x51, // MLOAD
        0x50, // POP
        0x00, // STOP
    };

    var analysis = try Analysis.from_code(allocator, code, &OpcodeMetadata.DEFAULT);
    defer analysis.deinit();

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();

    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    const host = Host.init(&vm);

    // Test with insufficient gas for memory expansion
    var frame_low_gas = try Frame.init(
        100, // Very low gas
        false,
        0,
        primitives.Address.ZERO_ADDRESS,
        primitives.Address.ZERO_ADDRESS,
        0,
        &analysis,
        host,
        db_interface,
        allocator,
    );
    defer frame_low_gas.deinit(allocator);

    // Should fail with OutOfGas
    try std.testing.expectError(ExecutionError.Error.OutOfGas, interpret(&vm, &frame_low_gas));

    // Test with sufficient gas
    var frame_high_gas = try Frame.init(
        100000,
        false,
        0,
        primitives.Address.ZERO_ADDRESS,
        primitives.Address.ZERO_ADDRESS,
        0,
        &analysis,
        host,
        db_interface,
        allocator,
    );
    defer frame_high_gas.deinit(allocator);

    // Should succeed
    try std.testing.expectError(ExecutionError.Error.STOP, interpret(&vm, &frame_high_gas));
}

test "interpret: noop instruction advances correctly" {
    const allocator = std.testing.allocator;
    const OpcodeMetadata = @import("../opcode_metadata/opcode_metadata.zig");
    const MemoryDatabase = @import("../state/memory_database.zig").MemoryDatabase;
    const Analysis = @import("../analysis.zig").CodeAnalysis;
    const Host = @import("../host.zig").Host;
    const primitives = @import("primitives");

    // Code with JUMPDEST (which becomes noop) and arithmetic
    const code = &[_]u8{
        0x60, 0x02, // PUSH1 2
        0x60, 0x03, // PUSH1 3
        0x5b, // JUMPDEST (noop)
        0x01, // ADD
        0x00, // STOP
    };

    var analysis = try Analysis.from_code(allocator, code, &OpcodeMetadata.DEFAULT);
    defer analysis.deinit();

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();

    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    const host = Host.init(&vm);

    var frame = try Frame.init(
        100000,
        false,
        0,
        primitives.Address.ZERO_ADDRESS,
        primitives.Address.ZERO_ADDRESS,
        0,
        &analysis,
        host,
        db_interface,
        allocator,
    );
    defer frame.deinit(allocator);

    // Execute
    try std.testing.expectError(ExecutionError.Error.STOP, interpret(&vm, &frame));

    // Check result
    try std.testing.expectEqual(@as(usize, 1), frame.stack.size());
    try std.testing.expectEqual(@as(u256, 5), frame.stack.data[0]);
}

test "interpret: conditional_jump_invalid with true condition" {
    const allocator = std.testing.allocator;
    const OpcodeMetadata = @import("../opcode_metadata/opcode_metadata.zig");
    const MemoryDatabase = @import("../state/memory_database.zig").MemoryDatabase;
    const Analysis = @import("../analysis.zig").CodeAnalysis;
    const Host = @import("../host.zig").Host;
    const primitives = @import("primitives");

    // JUMPI to invalid location (will be analyzed as conditional_jump_invalid)
    const code = &[_]u8{
        0x60, 0xFF, // PUSH1 0xFF (invalid jump dest)
        0x60, 0x01, // PUSH1 1 (true condition)
        0x57, // JUMPI
        0x00, // STOP
    };

    var analysis = try Analysis.from_code(allocator, code, &OpcodeMetadata.DEFAULT);
    defer analysis.deinit();

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();

    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    const host = Host.init(&vm);

    var frame = try Frame.init(
        100000,
        false,
        0,
        primitives.Address.ZERO_ADDRESS,
        primitives.Address.ZERO_ADDRESS,
        0,
        &analysis,
        host,
        db_interface,
        allocator,
    );
    defer frame.deinit(allocator);

    // Should fail with InvalidJump
    try std.testing.expectError(ExecutionError.Error.InvalidJump, interpret(&vm, &frame));
}

test "interpret: conditional_jump_invalid with false condition continues" {
    const allocator = std.testing.allocator;
    const OpcodeMetadata = @import("../opcode_metadata/opcode_metadata.zig");
    const MemoryDatabase = @import("../state/memory_database.zig").MemoryDatabase;
    const Analysis = @import("../analysis.zig").CodeAnalysis;
    const Host = @import("../host.zig").Host;
    const primitives = @import("primitives");

    // JUMPI to invalid location but with false condition
    const code = &[_]u8{
        0x60, 0xFF, // PUSH1 0xFF (invalid jump dest)
        0x60, 0x00, // PUSH1 0 (false condition)
        0x57, // JUMPI
        0x00, // STOP
    };

    var analysis = try Analysis.from_code(allocator, code, &OpcodeMetadata.DEFAULT);
    defer analysis.deinit();

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();

    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    const host = Host.init(&vm);

    var frame = try Frame.init(
        100000,
        false,
        0,
        primitives.Address.ZERO_ADDRESS,
        primitives.Address.ZERO_ADDRESS,
        0,
        &analysis,
        host,
        db_interface,
        allocator,
    );
    defer frame.deinit(allocator);

    // Should continue to STOP (not jump)
    try std.testing.expectError(ExecutionError.Error.STOP, interpret(&vm, &frame));
}

test "interpret: jump_unresolved with empty stack causes underflow" {
    const allocator = std.testing.allocator;
    const OpcodeMetadata = @import("../opcode_metadata/opcode_metadata.zig");
    const MemoryDatabase = @import("../state/memory_database.zig").MemoryDatabase;
    const Analysis = @import("../analysis.zig").CodeAnalysis;
    const Host = @import("../host.zig").Host;
    const primitives = @import("primitives");

    // Dynamic JUMP with empty stack
    const code = &[_]u8{
        0x56, // JUMP (no destination on stack)
        0x00, // STOP
    };

    var analysis = try Analysis.from_code(allocator, code, &OpcodeMetadata.DEFAULT);
    defer analysis.deinit();

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();

    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    const host = Host.init(&vm);

    var frame = try Frame.init(
        100000,
        false,
        0,
        primitives.Address.ZERO_ADDRESS,
        primitives.Address.ZERO_ADDRESS,
        0,
        &analysis,
        host,
        db_interface,
        allocator,
    );
    defer frame.deinit(allocator);

    // Should fail with StackUnderflow
    try std.testing.expectError(ExecutionError.Error.StackUnderflow, interpret(&vm, &frame));
}

test "interpret: conditional_jump_unresolved with insufficient stack" {
    const allocator = std.testing.allocator;
    const OpcodeMetadata = @import("../opcode_metadata/opcode_metadata.zig");
    const MemoryDatabase = @import("../state/memory_database.zig").MemoryDatabase;
    const Analysis = @import("../analysis.zig").CodeAnalysis;
    const Host = @import("../host.zig").Host;
    const primitives = @import("primitives");

    // JUMPI with only one stack item (needs two)
    const code = &[_]u8{
        0x60, 0x05, // PUSH1 5 (only destination, no condition)
        0x57, // JUMPI
        0x00, // STOP
    };

    var analysis = try Analysis.from_code(allocator, code, &OpcodeMetadata.DEFAULT);
    defer analysis.deinit();

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();

    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    const host = Host.init(&vm);

    var frame = try Frame.init(
        100000,
        false,
        0,
        primitives.Address.ZERO_ADDRESS,
        primitives.Address.ZERO_ADDRESS,
        0,
        &analysis,
        host,
        db_interface,
        allocator,
    );
    defer frame.deinit(allocator);

    // Should fail with StackUnderflow
    try std.testing.expectError(ExecutionError.Error.StackUnderflow, interpret(&vm, &frame));
}

test "interpret: complex control flow with multiple jumps" {
    const allocator = std.testing.allocator;
    const OpcodeMetadata = @import("../opcode_metadata/opcode_metadata.zig");
    const MemoryDatabase = @import("../state/memory_database.zig").MemoryDatabase;
    const Analysis = @import("../analysis.zig").CodeAnalysis;
    const Host = @import("../host.zig").Host;
    const primitives = @import("primitives");

    // Complex control flow: multiple jumps and conditional jumps
    const code = &[_]u8{
        // Start: push 5
        0x60, 0x05, // PUSH1 5
        // Jump to first section
        0x60, 0x08, // PUSH1 8
        0x56, // JUMP
        0xfe, // INVALID (skipped)
        0xfe, // INVALID (skipped)
        // First section at 8
        0x5b, // JUMPDEST
        0x60, 0x03, // PUSH1 3
        0x01, // ADD (5 + 3 = 8)
        // Conditional jump to second section
        0x60, 0x16, // PUSH1 22
        0x60, 0x01, // PUSH1 1
        0x57, // JUMPI (should jump)
        0xfe, // INVALID (skipped)
        0xfe, // INVALID (skipped)
        // Second section at 22
        0x5b, // JUMPDEST
        0x60, 0x02, // PUSH1 2
        0x02, // MUL (8 * 2 = 16)
        0x00, // STOP
    };

    var analysis = try Analysis.from_code(allocator, code, &OpcodeMetadata.DEFAULT);
    defer analysis.deinit();

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();

    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    const host = Host.init(&vm);

    var frame = try Frame.init(
        100000,
        false,
        0,
        primitives.Address.ZERO_ADDRESS,
        primitives.Address.ZERO_ADDRESS,
        0,
        &analysis,
        host,
        db_interface,
        allocator,
    );
    defer frame.deinit(allocator);

    // Execute
    try std.testing.expectError(ExecutionError.Error.STOP, interpret(&vm, &frame));

    // Check final result
    try std.testing.expectEqual(@as(usize, 1), frame.stack.size());
    try std.testing.expectEqual(@as(u256, 16), frame.stack.data[0]);
}

test "interpret: maximum stack depth" {
    const allocator = std.testing.allocator;
    const OpcodeMetadata = @import("../opcode_metadata/opcode_metadata.zig");
    const MemoryDatabase = @import("../state/memory_database.zig").MemoryDatabase;
    const Analysis = @import("../analysis.zig").CodeAnalysis;
    const Host = @import("../host.zig").Host;
    const primitives = @import("primitives");
    const Stack = @import("../stack/stack.zig");

    // Try to push beyond stack limit
    var code = std.ArrayList(u8).init(allocator);
    defer code.deinit();

    // Generate code that pushes Stack.CAPACITY + 1 items
    var i: usize = 0;
    while (i < Stack.CAPACITY + 1) : (i += 1) {
        try code.appendSlice(&[_]u8{ 0x60, 0x01 }); // PUSH1 1
    }
    try code.append(0x00); // STOP

    var analysis = try Analysis.from_code(allocator, code.items, &OpcodeMetadata.DEFAULT);
    defer analysis.deinit();

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();

    var vm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    const host = Host.init(&vm);

    var frame = try Frame.init(
        10000000, // Lots of gas
        false,
        0,
        primitives.Address.ZERO_ADDRESS,
        primitives.Address.ZERO_ADDRESS,
        0,
        &analysis,
        host,
        db_interface,
        allocator,
    );
    defer frame.deinit(allocator);

    // Should fail with StackOverflow
    try std.testing.expectError(ExecutionError.Error.StackOverflow, interpret(&vm, &frame));
}

test "interpret: large bytesToU256 conversion" {
    // Test edge cases for bytesToU256

    // Empty bytes
    const empty: []const u8 = &[_]u8{};
    try std.testing.expectEqual(@as(u256, 0), bytesToU256(empty));

    // Single byte with high bit set
    const high_bit = [_]u8{0x80};
    try std.testing.expectEqual(@as(u256, 0x80), bytesToU256(high_bit[0..]));

    // 31 bytes (one less than full)
    const bytes31 = [_]u8{0xFF} ** 31;
    const expected31: u256 = ((@as(u256, 1) << 248) - 1); // 31 bytes of 0xFF
    try std.testing.expectEqual(expected31, bytesToU256(bytes31[0..]));

    // Mixed bytes pattern
    const mixed = [_]u8{ 0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0 };
    try std.testing.expectEqual(@as(u256, 0x123456789ABCDEF0), bytesToU256(mixed[0..]));
}

