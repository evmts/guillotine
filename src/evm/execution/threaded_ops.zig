const std = @import("std");
const Frame = @import("../frame/frame.zig");
const Stack = @import("../stack/stack.zig");
const ThreadedInstruction = @import("../frame/threaded_instruction.zig").ThreadedInstruction;
const ThreadedExecFunc = @import("../frame/threaded_instruction.zig").ThreadedExecFunc;
const primitives = @import("primitives");
const crypto = @import("crypto");
const Log = @import("../log.zig");

/// Helper to get next instruction
inline fn getNextInstruction(instr: *const ThreadedInstruction, state: *Frame) ?*const ThreadedInstruction {
    const current_idx = (@intFromPtr(instr) - @intFromPtr(state.instructions.?.ptr)) / @sizeOf(ThreadedInstruction);
    if (current_idx + 1 < state.instructions.?.len) {
        return &state.instructions.?[current_idx + 1];
    }
    return null;
}

/// Generic wrapper for simple operations
pub fn makeThreadedOp(comptime op_fn: fn (*Frame) void) ThreadedExecFunc {
    return struct {
        fn exec(instr: *const ThreadedInstruction, state: *Frame) ?*const ThreadedInstruction {
            op_fn(state);
            return getNextInstruction(instr, state);
        }
    }.exec;
}

/// Wrapper for operations that can fail
pub fn makeThreadedOpWithError(comptime op_fn: fn (*Frame) anyerror!void) ThreadedExecFunc {
    return struct {
        fn exec(instr: *const ThreadedInstruction, state: *Frame) ?*const ThreadedInstruction {
            op_fn(state) catch |err| {
                Log.debug("[THREADED] Operation failed with error: {}", .{err});
                state.return_reason = .Invalid;
                return null;
            };
            return getNextInstruction(instr, state);
        }
    }.exec;
}

// Arithmetic operations
pub const op_add_threaded = makeThreadedOp(struct {
    fn op(state: *Frame) void {
        const b = state.stack.pop_unsafe();
        const a = state.stack.pop_unsafe();
        state.stack.append_unsafe(a +% b);
    }
}.op);

pub const op_mul_threaded = makeThreadedOp(struct {
    fn op(state: *Frame) void {
        const b = state.stack.pop_unsafe();
        const a = state.stack.pop_unsafe();
        state.stack.append_unsafe(a *% b);
    }
}.op);

pub const op_sub_threaded = makeThreadedOp(struct {
    fn op(state: *Frame) void {
        const b = state.stack.pop_unsafe();
        const a = state.stack.pop_unsafe();
        state.stack.append_unsafe(a -% b);
    }
}.op);

pub const op_div_threaded = makeThreadedOp(struct {
    fn op(state: *Frame) void {
        const b = state.stack.pop_unsafe();
        const a = state.stack.pop_unsafe();
        if (b == 0) {
            state.stack.append_unsafe(0);
        } else {
            state.stack.append_unsafe(a / b);
        }
    }
}.op);

pub const op_sdiv_threaded = makeThreadedOp(struct {
    fn op(state: *Frame) void {
        const b = state.stack.pop_unsafe();
        const a = state.stack.pop_unsafe();
        if (b == 0) {
            state.stack.append_unsafe(0);
        } else {
            const a_signed: i256 = @bitCast(a);
            const b_signed: i256 = @bitCast(b);
            const result_signed = @divTrunc(a_signed, b_signed);
            state.stack.append_unsafe(@bitCast(result_signed));
        }
    }
}.op);

pub const op_mod_threaded = makeThreadedOp(struct {
    fn op(state: *Frame) void {
        const b = state.stack.pop_unsafe();
        const a = state.stack.pop_unsafe();
        if (b == 0) {
            state.stack.append_unsafe(0);
        } else {
            state.stack.append_unsafe(a % b);
        }
    }
}.op);

pub const op_smod_threaded = makeThreadedOp(struct {
    fn op(state: *Frame) void {
        const b = state.stack.pop_unsafe();
        const a = state.stack.pop_unsafe();
        if (b == 0) {
            state.stack.append_unsafe(0);
        } else {
            const a_signed: i256 = @bitCast(a);
            const b_signed: i256 = @bitCast(b);
            const result_signed = @rem(a_signed, b_signed);
            state.stack.append_unsafe(@bitCast(result_signed));
        }
    }
}.op);

pub const op_addmod_threaded = makeThreadedOp(struct {
    fn op(state: *Frame) void {
        const n = state.stack.pop_unsafe();
        const b = state.stack.pop_unsafe();
        const a = state.stack.pop_unsafe();
        if (n == 0) {
            state.stack.append_unsafe(0);
        } else {
            // Use 512-bit arithmetic to prevent overflow
            const a_wide: u512 = a;
            const b_wide: u512 = b;
            const n_wide: u512 = n;
            const result = (a_wide + b_wide) % n_wide;
            state.stack.append_unsafe(@intCast(result));
        }
    }
}.op);

pub const op_mulmod_threaded = makeThreadedOp(struct {
    fn op(state: *Frame) void {
        const n = state.stack.pop_unsafe();
        const b = state.stack.pop_unsafe();
        const a = state.stack.pop_unsafe();
        if (n == 0) {
            state.stack.append_unsafe(0);
        } else {
            // Use 512-bit arithmetic to prevent overflow
            const a_wide: u512 = a;
            const b_wide: u512 = b;
            const n_wide: u512 = n;
            const result = (a_wide * b_wide) % n_wide;
            state.stack.append_unsafe(@intCast(result));
        }
    }
}.op);

pub const op_exp_threaded = makeThreadedOp(struct {
    fn op(state: *Frame) void {
        const exp = state.stack.pop_unsafe();
        const base = state.stack.pop_unsafe();
        // TODO: Implement proper EXP with gas metering
        var result: u256 = 1;
        var b = base;
        var e = exp;
        while (e > 0) : (e >>= 1) {
            if (e & 1 == 1) {
                result *%= b;
            }
            b *%= b;
        }
        state.stack.append_unsafe(result);
    }
}.op);

pub const op_signextend_threaded = makeThreadedOp(struct {
    fn op(state: *Frame) void {
        const ext = state.stack.pop_unsafe();
        const value = state.stack.pop_unsafe();
        if (ext >= 32) {
            state.stack.append_unsafe(value);
        } else {
            const bits = @as(u9, @intCast((ext + 1) * 8));
            const mask = (@as(u256, 1) << @intCast(bits)) - 1;
            const sign_bit_pos = @as(u8, @intCast(bits - 1));
            const sign_bit = (@as(u256, 1) << sign_bit_pos);
            if ((value & sign_bit) != 0) {
                state.stack.append_unsafe(value | (~mask));
            } else {
                state.stack.append_unsafe(value & mask);
            }
        }
    }
}.op);

// Comparison operations
pub const op_lt_threaded = makeThreadedOp(struct {
    fn op(state: *Frame) void {
        const b = state.stack.pop_unsafe();
        const a = state.stack.pop_unsafe();
        state.stack.append_unsafe(if (a < b) 1 else 0);
    }
}.op);

pub const op_gt_threaded = makeThreadedOp(struct {
    fn op(state: *Frame) void {
        const b = state.stack.pop_unsafe();
        const a = state.stack.pop_unsafe();
        state.stack.append_unsafe(if (a > b) 1 else 0);
    }
}.op);

pub const op_slt_threaded = makeThreadedOp(struct {
    fn op(state: *Frame) void {
        const b = state.stack.pop_unsafe();
        const a = state.stack.pop_unsafe();
        const a_signed: i256 = @bitCast(a);
        const b_signed: i256 = @bitCast(b);
        state.stack.append_unsafe(if (a_signed < b_signed) 1 else 0);
    }
}.op);

pub const op_sgt_threaded = makeThreadedOp(struct {
    fn op(state: *Frame) void {
        const b = state.stack.pop_unsafe();
        const a = state.stack.pop_unsafe();
        const a_signed: i256 = @bitCast(a);
        const b_signed: i256 = @bitCast(b);
        state.stack.append_unsafe(if (a_signed > b_signed) 1 else 0);
    }
}.op);

pub const op_eq_threaded = makeThreadedOp(struct {
    fn op(state: *Frame) void {
        const b = state.stack.pop_unsafe();
        const a = state.stack.pop_unsafe();
        state.stack.append_unsafe(if (a == b) 1 else 0);
    }
}.op);

pub const op_iszero_threaded = makeThreadedOp(struct {
    fn op(state: *Frame) void {
        const a = state.stack.pop_unsafe();
        state.stack.append_unsafe(if (a == 0) 1 else 0);
    }
}.op);

// Bitwise operations
pub const op_and_threaded = makeThreadedOp(struct {
    fn op(state: *Frame) void {
        const b = state.stack.pop_unsafe();
        const a = state.stack.pop_unsafe();
        state.stack.append_unsafe(a & b);
    }
}.op);

pub const op_or_threaded = makeThreadedOp(struct {
    fn op(state: *Frame) void {
        const b = state.stack.pop_unsafe();
        const a = state.stack.pop_unsafe();
        state.stack.append_unsafe(a | b);
    }
}.op);

pub const op_xor_threaded = makeThreadedOp(struct {
    fn op(state: *Frame) void {
        const b = state.stack.pop_unsafe();
        const a = state.stack.pop_unsafe();
        state.stack.append_unsafe(a ^ b);
    }
}.op);

pub const op_not_threaded = makeThreadedOp(struct {
    fn op(state: *Frame) void {
        const a = state.stack.pop_unsafe();
        state.stack.append_unsafe(~a);
    }
}.op);

pub const op_byte_threaded = makeThreadedOp(struct {
    fn op(state: *Frame) void {
        const value = state.stack.pop_unsafe();
        const byte_index = state.stack.pop_unsafe();
        if (byte_index >= 32) {
            state.stack.append_unsafe(0);
        } else {
            const shift = @as(u8, @intCast(31 - byte_index)) * 8;
            state.stack.append_unsafe((value >> shift) & 0xFF);
        }
    }
}.op);

pub const op_shl_threaded = makeThreadedOp(struct {
    fn op(state: *Frame) void {
        const value = state.stack.pop_unsafe();
        const shift = state.stack.pop_unsafe();
        if (shift >= 256) {
            state.stack.append_unsafe(0);
        } else {
            state.stack.append_unsafe(value << @intCast(shift));
        }
    }
}.op);

pub const op_shr_threaded = makeThreadedOp(struct {
    fn op(state: *Frame) void {
        const value = state.stack.pop_unsafe();
        const shift = state.stack.pop_unsafe();
        if (shift >= 256) {
            state.stack.append_unsafe(0);
        } else {
            state.stack.append_unsafe(value >> @intCast(shift));
        }
    }
}.op);

pub const op_sar_threaded = makeThreadedOp(struct {
    fn op(state: *Frame) void {
        const value = state.stack.pop_unsafe();
        const shift = state.stack.pop_unsafe();
        const value_signed: i256 = @bitCast(value);
        if (shift >= 256) {
            state.stack.append_unsafe(if (value_signed < 0) @bitCast(@as(i256, -1)) else 0);
        } else {
            state.stack.append_unsafe(@bitCast(value_signed >> @intCast(shift)));
        }
    }
}.op);

// Hash operation
pub const op_keccak256_threaded = makeThreadedOpWithError(struct {
    fn op(state: *Frame) !void {
        const size = state.stack.pop_unsafe();
        const offset = state.stack.pop_unsafe();

        // TODO: Implement proper gas calculation and memory expansion
        if (size == 0) {
            // Hash of empty data is c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470
            const empty_hash = [32]u8{
                0xc5, 0xd2, 0x46, 0x01, 0x86, 0xf7, 0x23, 0x3c,
                0x92, 0x7e, 0x7d, 0xb2, 0xdc, 0xc7, 0x03, 0xc0,
                0xe5, 0x00, 0xb6, 0x53, 0xca, 0x82, 0x27, 0x3b,
                0x7b, 0xfa, 0xd8, 0x04, 0x5d, 0x85, 0xa4, 0x70,
            };
            state.stack.append_unsafe(@bitCast(empty_hash));
            return;
        }

        const data = try state.memory.get_slice(@intCast(offset), @intCast(size));
        const hash = crypto.HashUtils.keccak256(data);
        state.stack.append_unsafe(@bitCast(hash));
    }
}.op);

// Environment operations
pub const op_address_threaded = makeThreadedOp(struct {
    fn op(state: *Frame) void {
        state.stack.append_unsafe(primitives.Address.to_u256(state.contract.address));
    }
}.op);

pub const op_balance_threaded = makeThreadedOpWithError(struct {
    fn op(state: *Frame) !void {
        const addr_bytes = state.stack.pop_unsafe();
        _ = addr_bytes;
        // TODO: Get balance from state
        state.stack.append_unsafe(0);
    }
}.op);

pub const op_origin_threaded = makeThreadedOp(struct {
    fn op(state: *Frame) void {
        // TODO: Get origin from VM context
        state.stack.append_unsafe(0);
    }
}.op);

pub const op_caller_threaded = makeThreadedOp(struct {
    fn op(state: *Frame) void {
        state.stack.append_unsafe(primitives.Address.to_u256(state.contract.caller));
    }
}.op);

pub const op_callvalue_threaded = makeThreadedOp(struct {
    fn op(state: *Frame) void {
        state.stack.append_unsafe(state.contract.value);
    }
}.op);

pub const op_calldataload_threaded = makeThreadedOp(struct {
    fn op(state: *Frame) void {
        const offset = state.stack.pop_unsafe();
        if (offset >= state.input.len) {
            state.stack.append_unsafe(0);
        } else {
            const offset_usize: usize = @intCast(@min(offset, std.math.maxInt(usize)));
            var value: u256 = 0;
            const remaining = state.input.len - offset_usize;
            const copy_len = @min(32, remaining);

            // Copy bytes and pad with zeros
            var bytes: [32]u8 = [_]u8{0} ** 32;
            @memcpy(bytes[0..copy_len], state.input[offset_usize..][0..copy_len]);
            value = std.mem.readInt(u256, &bytes, .big);
            state.stack.append_unsafe(value);
        }
    }
}.op);

pub const op_calldatasize_threaded = makeThreadedOp(struct {
    fn op(state: *Frame) void {
        state.stack.append_unsafe(state.input.len);
    }
}.op);

pub const op_calldatacopy_threaded = makeThreadedOpWithError(struct {
    fn op(state: *Frame) !void {
        const size = state.stack.pop_unsafe();
        const data_offset = state.stack.pop_unsafe();
        const dest_offset = state.stack.pop_unsafe();

        if (size == 0) return;

        const size_usize: usize = @intCast(@min(size, std.math.maxInt(usize)));
        const data_offset_usize: usize = @intCast(@min(data_offset, std.math.maxInt(usize)));
        const dest_offset_usize: usize = @intCast(@min(dest_offset, std.math.maxInt(usize)));

        // TODO: Implement memory write with proper bounds checking
        _ = size_usize;
        _ = data_offset_usize;
        _ = dest_offset_usize;
    }
}.op);

pub const op_codesize_threaded = makeThreadedOp(struct {
    fn op(state: *Frame) void {
        state.stack.append_unsafe(state.contract.code_size);
    }
}.op);

pub const op_codecopy_threaded = makeThreadedOpWithError(struct {
    fn op(state: *Frame) !void {
        // CODECOPY pops in order: destOffset, offset, size (top to bottom)
        const dest_offset = state.stack.pop_unsafe();
        const code_offset = state.stack.pop_unsafe();
        const size = state.stack.pop_unsafe();
        
        Log.debug("[CODECOPY] size={}, code_offset={}, dest_offset={}, code_size={}", 
            .{size, code_offset, dest_offset, state.contract.code_size});

        if (size == 0) return;

        const size_usize: usize = @intCast(@min(size, std.math.maxInt(usize)));
        const code_offset_usize: usize = @intCast(@min(code_offset, std.math.maxInt(usize)));
        const dest_offset_usize: usize = @intCast(@min(dest_offset, std.math.maxInt(usize)));
        
        // Ensure memory capacity for the write
        if (size_usize > 0) {
            _ = try state.memory.ensure_context_capacity(dest_offset_usize + size_usize);
        }
        
        // Copy code to memory
        const end_offset = std.math.add(usize, code_offset_usize, size_usize) catch std.math.maxInt(usize);
        const actual_end = @min(end_offset, state.contract.code_size);
        const actual_size = if (actual_end > code_offset_usize) actual_end - code_offset_usize else 0;
        
        if (actual_size > 0) {
            const code_slice = state.contract.code[code_offset_usize..actual_end];
            Log.debug("[CODECOPY] Copying {} bytes from code[{}..{}] to memory[{}]", 
                .{actual_size, code_offset_usize, actual_end, dest_offset_usize});
            try state.memory.set_data(dest_offset_usize, code_slice);
        }
        
        // Zero-pad if we're reading past the end of code
        if (size_usize > actual_size) {
            const pad_size = size_usize - actual_size;
            const pad_offset = dest_offset_usize + actual_size;
            // Memory is already zero-initialized after resize
            _ = pad_offset;
            _ = pad_size;
        }
        
        Log.debug("[CODECOPY] Operation completed successfully", .{});
    }
}.op);

pub const op_gasprice_threaded = makeThreadedOp(struct {
    fn op(state: *Frame) void {
        // TODO: Get gas price from VM context
        state.stack.append_unsafe(0);
    }
}.op);

pub const op_extcodesize_threaded = makeThreadedOpWithError(struct {
    fn op(state: *Frame) !void {
        const addr_bytes = state.stack.pop_unsafe();
        _ = addr_bytes;
        // TODO: Get code size from state
        state.stack.append_unsafe(0);
    }
}.op);

pub const op_extcodecopy_threaded = makeThreadedOpWithError(struct {
    fn op(state: *Frame) !void {
        const size = state.stack.pop_unsafe();
        const code_offset = state.stack.pop_unsafe();
        const dest_offset = state.stack.pop_unsafe();
        const addr_bytes = state.stack.pop_unsafe();

        if (size == 0) return;

        // TODO: Implement extcodecopy
        _ = addr_bytes;
        _ = code_offset;
        _ = dest_offset;
    }
}.op);

pub const op_returndatasize_threaded = makeThreadedOp(struct {
    fn op(state: *Frame) void {
        state.stack.append_unsafe(state.return_data.size());
    }
}.op);

pub const op_returndatacopy_threaded = makeThreadedOpWithError(struct {
    fn op(state: *Frame) !void {
        const size = state.stack.pop_unsafe();
        const data_offset = state.stack.pop_unsafe();
        const dest_offset = state.stack.pop_unsafe();

        if (size == 0) return;

        // TODO: Implement returndatacopy
        _ = data_offset;
        _ = dest_offset;
    }
}.op);

pub const op_extcodehash_threaded = makeThreadedOpWithError(struct {
    fn op(state: *Frame) !void {
        const addr_bytes = state.stack.pop_unsafe();
        _ = addr_bytes;
        // TODO: Get code hash from state
        state.stack.append_unsafe(0);
    }
}.op);

// Block operations
pub const op_blockhash_threaded = makeThreadedOp(struct {
    fn op(state: *Frame) void {
        const block_number = state.stack.pop_unsafe();
        // TODO: Get block hash
        _ = block_number;
        state.stack.append_unsafe(0);
    }
}.op);

pub const op_coinbase_threaded = makeThreadedOp(struct {
    fn op(state: *Frame) void {
        // TODO: Get coinbase from VM context
        state.stack.append_unsafe(0);
    }
}.op);

pub const op_timestamp_threaded = makeThreadedOp(struct {
    fn op(state: *Frame) void {
        // TODO: Get timestamp from VM context
        state.stack.append_unsafe(0);
    }
}.op);

pub const op_number_threaded = makeThreadedOp(struct {
    fn op(state: *Frame) void {
        // TODO: Get block number from VM context
        state.stack.append_unsafe(0);
    }
}.op);

pub const op_difficulty_threaded = makeThreadedOp(struct {
    fn op(state: *Frame) void {
        // TODO: Get difficulty from VM context
        state.stack.append_unsafe(0);
    }
}.op);

pub const op_gaslimit_threaded = makeThreadedOp(struct {
    fn op(state: *Frame) void {
        // TODO: Get gas limit from VM context
        state.stack.append_unsafe(30_000_000);
    }
}.op);

pub const op_chainid_threaded = makeThreadedOp(struct {
    fn op(state: *Frame) void {
        // TODO: Get chain ID from VM context
        state.stack.append_unsafe(1); // mainnet
    }
}.op);

pub const op_selfbalance_threaded = makeThreadedOpWithError(struct {
    fn op(state: *Frame) !void {
        // TODO: Get self balance from state
        state.stack.append_unsafe(0);
    }
}.op);

pub const op_basefee_threaded = makeThreadedOp(struct {
    fn op(state: *Frame) void {
        // TODO: Get base fee from VM context
        state.stack.append_unsafe(0);
    }
}.op);

// Memory operations
pub const op_mload_threaded = makeThreadedOpWithError(struct {
    fn op(state: *Frame) !void {
        const offset = state.stack.pop_unsafe();
        const offset_usize: usize = @intCast(@min(offset, std.math.maxInt(usize)));

        // TODO: Implement proper memory expansion
        const value = try state.memory.get_u256(offset_usize);
        state.stack.append_unsafe(value);
    }
}.op);

pub const op_mstore_threaded = makeThreadedOpWithError(struct {
    fn op(state: *Frame) !void {
        // Stack order: [value, offset] with offset on top
        const offset = state.stack.pop_unsafe(); // top
        const value = state.stack.pop_unsafe(); // second from top
        const offset_usize: usize = @intCast(@min(offset, std.math.maxInt(usize)));

        // TODO: Implement proper memory expansion
        try state.memory.set_u256(offset_usize, value);
    }
}.op);

pub const op_mstore8_threaded = makeThreadedOpWithError(struct {
    fn op(state: *Frame) !void {
        // Stack order: [value, offset] with offset on top
        const offset = state.stack.pop_unsafe(); // top
        const value = state.stack.pop_unsafe(); // second from top
        const offset_usize: usize = @intCast(@min(offset, std.math.maxInt(usize)));

        // TODO: Implement proper memory expansion
        try state.memory.set_data(offset_usize, &[_]u8{@intCast(value & 0xFF)});
    }
}.op);

pub const op_sload_threaded = makeThreadedOpWithError(struct {
    fn op(state: *Frame) !void {
        const key = state.stack.pop_unsafe();
        // TODO: Load from storage
        _ = key;
        state.stack.append_unsafe(0);
    }
}.op);

pub const op_sstore_threaded = makeThreadedOpWithError(struct {
    fn op(state: *Frame) !void {
        const value = state.stack.pop_unsafe();
        const key = state.stack.pop_unsafe();
        // TODO: Store to storage
        _ = key;
        _ = value;
    }
}.op);

pub const op_msize_threaded = makeThreadedOp(struct {
    fn op(state: *Frame) void {
        state.stack.append_unsafe(state.memory.size());
    }
}.op);

// Stack operations with embedded values
pub fn op_push_small_threaded(instr: *const ThreadedInstruction, state: *Frame) ?*const ThreadedInstruction {
    state.stack.append_unsafe(@as(u256, instr.arg.small_push));
    return getNextInstruction(instr, state);
}

pub fn op_push_large_threaded(instr: *const ThreadedInstruction, state: *Frame) ?*const ThreadedInstruction {
    const value = state.push_values.?[instr.arg.large_push_idx];
    state.stack.append_unsafe(value);
    return getNextInstruction(instr, state);
}

pub fn op_pop_threaded(instr: *const ThreadedInstruction, state: *Frame) ?*const ThreadedInstruction {
    _ = state.stack.pop_unsafe();
    return getNextInstruction(instr, state);
}

// Control flow
pub fn op_jump_threaded(instr: *const ThreadedInstruction, state: *Frame) ?*const ThreadedInstruction {
    _ = instr;
    const target = state.stack.pop_unsafe();

    // Use pre-validated jump destination
    if (target > std.math.maxInt(u32)) return null;
    const target_idx = state.jumpdest_map.?.get(@intCast(target)) orelse return null;

    return &state.instructions.?[target_idx];
}

pub fn op_jumpi_threaded(instr: *const ThreadedInstruction, state: *Frame) ?*const ThreadedInstruction {
    const target = state.stack.pop_unsafe();
    const condition = state.stack.pop_unsafe();

    if (condition != 0) {
        if (target > std.math.maxInt(u32)) return null;
        const target_idx = state.jumpdest_map.?.get(@intCast(target)) orelse return null;
        return &state.instructions.?[target_idx];
    }

    return getNextInstruction(instr, state);
}

pub fn op_jumpdest_threaded(instr: *const ThreadedInstruction, state: *Frame) ?*const ThreadedInstruction {
    return getNextInstruction(instr, state);
}

// Block boundaries
pub fn opx_beginblock_threaded(instr: *const ThreadedInstruction, state: *Frame) ?*const ThreadedInstruction {
    const block = instr.arg.block_info;
    
    const stack_size: i32 = @intCast(state.stack.size());
    Log.debug("Block begin: stack_size={}, stack_req={}, gas_cost={}, max_growth={}", .{stack_size, block.stack_req, block.gas_cost, block.stack_max_growth});

    // Consume gas for entire block
    if (state.gas_remaining < block.gas_cost) {
        state.return_reason = .OutOfGas;
        return null;
    }
    state.gas_remaining -= block.gas_cost;

    // Validate stack requirements
    if (stack_size < block.stack_req) {
        Log.debug("Block validation FAILED: stack_size={} < stack_req={}", .{stack_size, block.stack_req});
        state.return_reason = .Invalid;
        return null;
    }
    if (stack_size + block.stack_max_growth > Stack.CAPACITY) {
        state.return_reason = .Invalid;
        return null;
    }

    state.current_block_gas = block.gas_cost;
    return getNextInstruction(instr, state);
}

// Termination
pub fn op_stop_threaded(instr: *const ThreadedInstruction, state: *Frame) ?*const ThreadedInstruction {
    _ = instr;
    state.return_reason = .Stop;
    return null;
}

pub fn op_return_threaded(instr: *const ThreadedInstruction, state: *Frame) ?*const ThreadedInstruction {
    _ = instr;
    // Stack order: [size, offset] with offset on top
    const offset = state.stack.pop_unsafe(); // top
    const size = state.stack.pop_unsafe(); // second from top
    
    Log.debug("[RETURN] offset={}, size={}", .{offset, size});

    // Set output data
    if (size > 0) {
        const size_usize: usize = @intCast(@min(size, std.math.maxInt(usize)));
        const offset_usize: usize = @intCast(@min(offset, std.math.maxInt(usize)));

        const data = state.memory.get_slice(offset_usize, size_usize) catch |err| {
            Log.debug("[RETURN] Failed to get memory slice: {}", .{err});
            state.return_reason = .Invalid;
            return null;
        };
        state.output = data;
        Log.debug("[RETURN] Set output data, len={}", .{data.len});
    }

    state.return_reason = .Return;
    return null;
}

pub fn op_revert_threaded(instr: *const ThreadedInstruction, state: *Frame) ?*const ThreadedInstruction {
    _ = instr;
    // Stack order: [size, offset] with offset on top
    const offset = state.stack.pop_unsafe(); // top
    const size = state.stack.pop_unsafe(); // second from top

    // Set output data
    if (size > 0) {
        const size_usize: usize = @intCast(@min(size, std.math.maxInt(usize)));
        const offset_usize: usize = @intCast(@min(offset, std.math.maxInt(usize)));

        const data = state.memory.get_slice(offset_usize, size_usize) catch return null;
        state.output = data;
    }

    state.return_reason = .Revert;
    return null;
}

// Operations with embedded PC value
pub fn op_pc_threaded(instr: *const ThreadedInstruction, state: *Frame) ?*const ThreadedInstruction {
    state.stack.append_unsafe(@as(u256, instr.arg.pc_value));
    return getNextInstruction(instr, state);
}

// Operations with gas correction
pub fn op_gas_threaded(instr: *const ThreadedInstruction, state: *Frame) ?*const ThreadedInstruction {
    const correction: i64 = @as(i64, @intCast(state.current_block_gas)) - @as(i64, instr.arg.gas_correction);
    const gas: u256 = @intCast(@as(i64, @intCast(state.gas_remaining)) + correction);
    state.stack.append_unsafe(gas);
    return getNextInstruction(instr, state);
}

// Invalid operation
pub fn op_invalid_threaded(instr: *const ThreadedInstruction, state: *Frame) ?*const ThreadedInstruction {
    _ = instr;
    _ = state;
    return null;
}

// DUP operations generator
pub fn makeDupThreaded(comptime n: u8) ThreadedExecFunc {
    return struct {
        fn exec(instr: *const ThreadedInstruction, state: *Frame) ?*const ThreadedInstruction {
            state.stack.dup_unsafe(n);
            return getNextInstruction(instr, state);
        }
    }.exec;
}

// SWAP operations generator
pub fn makeSwapThreaded(comptime n: u8) ThreadedExecFunc {
    return struct {
        fn exec(instr: *const ThreadedInstruction, state: *Frame) ?*const ThreadedInstruction {
            state.stack.swap_unsafe(n);
            return getNextInstruction(instr, state);
        }
    }.exec;
}

// Pre-generated DUP operations
pub const op_dup1_threaded = makeDupThreaded(1);
pub const op_dup2_threaded = makeDupThreaded(2);
pub const op_dup3_threaded = makeDupThreaded(3);
pub const op_dup4_threaded = makeDupThreaded(4);
pub const op_dup5_threaded = makeDupThreaded(5);
pub const op_dup6_threaded = makeDupThreaded(6);
pub const op_dup7_threaded = makeDupThreaded(7);
pub const op_dup8_threaded = makeDupThreaded(8);
pub const op_dup9_threaded = makeDupThreaded(9);
pub const op_dup10_threaded = makeDupThreaded(10);
pub const op_dup11_threaded = makeDupThreaded(11);
pub const op_dup12_threaded = makeDupThreaded(12);
pub const op_dup13_threaded = makeDupThreaded(13);
pub const op_dup14_threaded = makeDupThreaded(14);
pub const op_dup15_threaded = makeDupThreaded(15);
pub const op_dup16_threaded = makeDupThreaded(16);

// Pre-generated SWAP operations
pub const op_swap1_threaded = makeSwapThreaded(1);
pub const op_swap2_threaded = makeSwapThreaded(2);
pub const op_swap3_threaded = makeSwapThreaded(3);
pub const op_swap4_threaded = makeSwapThreaded(4);
pub const op_swap5_threaded = makeSwapThreaded(5);
pub const op_swap6_threaded = makeSwapThreaded(6);
pub const op_swap7_threaded = makeSwapThreaded(7);
pub const op_swap8_threaded = makeSwapThreaded(8);
pub const op_swap9_threaded = makeSwapThreaded(9);
pub const op_swap10_threaded = makeSwapThreaded(10);
pub const op_swap11_threaded = makeSwapThreaded(11);
pub const op_swap12_threaded = makeSwapThreaded(12);
pub const op_swap13_threaded = makeSwapThreaded(13);
pub const op_swap14_threaded = makeSwapThreaded(14);
pub const op_swap15_threaded = makeSwapThreaded(15);
pub const op_swap16_threaded = makeSwapThreaded(16);

// LOG operations generator
pub fn makeLogThreaded(comptime topics: u8) ThreadedExecFunc {
    return struct {
        fn exec(instr: *const ThreadedInstruction, state: *Frame) ?*const ThreadedInstruction {
            _ = topics;
            // TODO: Implement LOG operations
            return getNextInstruction(instr, state);
        }
    }.exec;
}

// Pre-generated LOG operations
pub const op_log0_threaded = makeLogThreaded(0);
pub const op_log1_threaded = makeLogThreaded(1);
pub const op_log2_threaded = makeLogThreaded(2);
pub const op_log3_threaded = makeLogThreaded(3);
pub const op_log4_threaded = makeLogThreaded(4);

/// Get threaded function for an opcode
pub fn getThreadedFunction(opcode: u8) ThreadedExecFunc {
    return switch (opcode) {
        // Arithmetic
        0x01 => op_add_threaded,
        0x02 => op_mul_threaded,
        0x03 => op_sub_threaded,
        0x04 => op_div_threaded,
        0x05 => op_sdiv_threaded,
        0x06 => op_mod_threaded,
        0x07 => op_smod_threaded,
        0x08 => op_addmod_threaded,
        0x09 => op_mulmod_threaded,
        0x0a => op_exp_threaded,
        0x0b => op_signextend_threaded,

        // Comparison
        0x10 => op_lt_threaded,
        0x11 => op_gt_threaded,
        0x12 => op_slt_threaded,
        0x13 => op_sgt_threaded,
        0x14 => op_eq_threaded,
        0x15 => op_iszero_threaded,

        // Bitwise
        0x16 => op_and_threaded,
        0x17 => op_or_threaded,
        0x18 => op_xor_threaded,
        0x19 => op_not_threaded,
        0x1a => op_byte_threaded,
        0x1b => op_shl_threaded,
        0x1c => op_shr_threaded,
        0x1d => op_sar_threaded,

        // Hash
        0x20 => op_keccak256_threaded,

        // Environment
        0x30 => op_address_threaded,
        0x31 => op_balance_threaded,
        0x32 => op_origin_threaded,
        0x33 => op_caller_threaded,
        0x34 => op_callvalue_threaded,
        0x35 => op_calldataload_threaded,
        0x36 => op_calldatasize_threaded,
        0x37 => op_calldatacopy_threaded,
        0x38 => op_codesize_threaded,
        0x39 => op_codecopy_threaded,
        0x3a => op_gasprice_threaded,
        0x3b => op_extcodesize_threaded,
        0x3c => op_extcodecopy_threaded,
        0x3d => op_returndatasize_threaded,
        0x3e => op_returndatacopy_threaded,
        0x3f => op_extcodehash_threaded,

        // Block
        0x40 => op_blockhash_threaded,
        0x41 => op_coinbase_threaded,
        0x42 => op_timestamp_threaded,
        0x43 => op_number_threaded,
        0x44 => op_difficulty_threaded,
        0x45 => op_gaslimit_threaded,
        0x46 => op_chainid_threaded,
        0x47 => op_selfbalance_threaded,
        0x48 => op_basefee_threaded,

        // Stack operations
        0x50 => op_pop_threaded,
        0x51 => op_mload_threaded,
        0x52 => op_mstore_threaded,
        0x53 => op_mstore8_threaded,
        0x54 => op_sload_threaded,
        0x55 => op_sstore_threaded,
        0x59 => op_msize_threaded,

        // PUSH operations (handled by analysis, but need mapping)
        0x60...0x7f => op_push_small_threaded, // PUSH1-PUSH32 will use appropriate handler

        // Control flow
        0x56 => op_jump_threaded,
        0x57 => op_jumpi_threaded,
        0x58 => op_pc_threaded,
        0x5a => op_gas_threaded,
        0x5b => op_jumpdest_threaded,

        // System
        0x00 => op_stop_threaded,
        0xf3 => op_return_threaded,
        0xfd => op_revert_threaded,

        // DUP operations
        0x80 => op_dup1_threaded,
        0x81 => op_dup2_threaded,
        0x82 => op_dup3_threaded,
        0x83 => op_dup4_threaded,
        0x84 => op_dup5_threaded,
        0x85 => op_dup6_threaded,
        0x86 => op_dup7_threaded,
        0x87 => op_dup8_threaded,
        0x88 => op_dup9_threaded,
        0x89 => op_dup10_threaded,
        0x8a => op_dup11_threaded,
        0x8b => op_dup12_threaded,
        0x8c => op_dup13_threaded,
        0x8d => op_dup14_threaded,
        0x8e => op_dup15_threaded,
        0x8f => op_dup16_threaded,

        // SWAP operations
        0x90 => op_swap1_threaded,
        0x91 => op_swap2_threaded,
        0x92 => op_swap3_threaded,
        0x93 => op_swap4_threaded,
        0x94 => op_swap5_threaded,
        0x95 => op_swap6_threaded,
        0x96 => op_swap7_threaded,
        0x97 => op_swap8_threaded,
        0x98 => op_swap9_threaded,
        0x99 => op_swap10_threaded,
        0x9a => op_swap11_threaded,
        0x9b => op_swap12_threaded,
        0x9c => op_swap13_threaded,
        0x9d => op_swap14_threaded,
        0x9e => op_swap15_threaded,
        0x9f => op_swap16_threaded,

        // LOG operations
        0xa0 => op_log0_threaded,
        0xa1 => op_log1_threaded,
        0xa2 => op_log2_threaded,
        0xa3 => op_log3_threaded,
        0xa4 => op_log4_threaded,

        // Invalid/undefined
        else => op_invalid_threaded,
    };
}
