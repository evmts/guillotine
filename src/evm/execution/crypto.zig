const std = @import("std");
const ExecutionError = @import("execution_error.zig");
const Frame = @import("../frame.zig").Frame;
const primitives = @import("primitives");
const Log = @import("../log.zig");

// Imports for tests
const Vm = @import("../evm.zig");
const Operation = @import("../opcodes/operation.zig");
const MemoryDatabase = @import("../state/memory_database.zig");

// Stack buffer sizes for common hash operations
const SMALL_BUFFER_SIZE = 64; // Most common (addresses, small data)
const MEDIUM_BUFFER_SIZE = 256; // Common for event data
const LARGE_BUFFER_SIZE = 1024; // Reasonable max for stack allocation

/// Optimized hash function using tiered stack buffers for small inputs.
/// Falls back to memory system for larger inputs.
inline fn hash_with_stack_buffer(data: []const u8) [32]u8 {
    var hash: [32]u8 = undefined;

    if (data.len <= SMALL_BUFFER_SIZE) {
        @branchHint(.likely); // Most common case - addresses and small data
        var buffer: [SMALL_BUFFER_SIZE]u8 = undefined;
        @memcpy(buffer[0..data.len], data);
        std.crypto.hash.sha3.Keccak256.hash(buffer[0..data.len], &hash, .{});
    } else if (data.len <= MEDIUM_BUFFER_SIZE) {
        @branchHint(.likely); // Common case - event data and medium-sized inputs
        var buffer: [MEDIUM_BUFFER_SIZE]u8 = undefined;
        @memcpy(buffer[0..data.len], data);
        std.crypto.hash.sha3.Keccak256.hash(buffer[0..data.len], &hash, .{});
    } else if (data.len <= LARGE_BUFFER_SIZE) {
        @branchHint(.unlikely); // Less common but still reasonable for stack
        var buffer: [LARGE_BUFFER_SIZE]u8 = undefined;
        @memcpy(buffer[0..data.len], data);
        std.crypto.hash.sha3.Keccak256.hash(buffer[0..data.len], &hash, .{});
    } else {
        @branchHint(.cold); // Very large data - hash directly from memory
        std.crypto.hash.sha3.Keccak256.hash(data, &hash, .{});
    }

    return hash;
}

pub fn op_sha3(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    std.debug.assert(frame.stack.size() >= 2);

    // Debug: show what's on stack before popping
    if (frame.stack.size() >= 2) {
        const top = try frame.stack.peek_unsafe();
        const second = try frame.stack.peek_n(1);
        Log.debug("KECCAK256 stack before pop: top={}, second={}", .{ top, second });
    }

    const offset = frame.stack.pop_unsafe();
    const size = frame.stack.pop_unsafe();

    Log.debug("KECCAK256 opcode: offset={}, size={} (stack_size={})", .{ offset, size, frame.stack.size() });

    // Check bounds before anything else
    if (offset > std.math.maxInt(usize) or size > std.math.maxInt(usize)) {
        @branchHint(.unlikely);
        return ExecutionError.Error.OutOfOffset;
    }

    if (size == 0) {
        @branchHint(.unlikely);
        // Hash of empty data = keccak256("") independent of offset
        const empty_hash: u256 = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;
        frame.stack.append_unsafe(empty_hash);
        return;
    }

    const offset_usize = @as(usize, @intCast(offset));
    const size_usize = @as(usize, @intCast(size));

    // Check if offset + size would overflow
    const end = std.math.add(usize, offset_usize, size_usize) catch {
        @branchHint(.unlikely);
        return ExecutionError.Error.OutOfOffset;
    };

    // Check if the end position exceeds reasonable memory limits
    const memory_limits = @import("../constants/memory_limits.zig");
    if (end > memory_limits.MAX_MEMORY_SIZE) {
        @branchHint(.unlikely);
        return ExecutionError.Error.OutOfOffset;
    }

    // Charge gas and ensure memory is available
    try frame.memory.charge_and_ensure(frame, @as(u64, end));

    // Dynamic gas cost for hashing
    const word_size = (size_usize + 31) / 32;
    const gas_cost = 6 * word_size;
    try frame.consume_gas(gas_cost);

    // Get data and hash using optimized stack buffer approach
    const data = try frame.memory.get_slice(offset_usize, size_usize);

    // Debug logging
    Log.debug("KECCAK256: offset={}, size={}, data={x}", .{ offset_usize, size_usize, std.fmt.fmtSliceHexLower(data) });

    // Calculate keccak256 hash using optimized tiered stack buffers
    const hash = hash_with_stack_buffer(data);

    // Convert hash to u256 using std.mem for efficiency
    const result = std.mem.readInt(u256, &hash, .big);

    Log.debug("KECCAK256: hash result={x:0>64}", .{result});

    frame.stack.append_unsafe(result);
}

// Alias for backwards compatibility
pub const op_keccak256 = op_sha3;

/// Optimized SHA3 handler for when gas costs are precomputed during analysis.
/// This version skips dynamic gas calculations and uses the precomputed total.
pub fn op_sha3_precomputed(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    std.debug.assert(frame.stack.size() >= 2);

    const offset = frame.stack.pop_unsafe();
    const size = frame.stack.pop_unsafe();

    // Check bounds before anything else
    if (offset > std.math.maxInt(usize) or size > std.math.maxInt(usize)) {
        @branchHint(.unlikely);
        return ExecutionError.Error.OutOfOffset;
    }

    if (size == 0) {
        @branchHint(.unlikely);
        // Even with size 0, we need to validate the offset is reasonable
        if (offset > 0) {
            // Check if offset is beyond reasonable memory limits
            const offset_usize = @as(usize, @intCast(offset));
            const memory_limits = @import("../constants/memory_limits.zig");
            if (offset_usize > memory_limits.MAX_MEMORY_SIZE) {
                @branchHint(.unlikely);
                return ExecutionError.Error.OutOfOffset;
            }
        }
        // Hash of empty data = keccak256("")
        const empty_hash: u256 = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;
        frame.stack.append_unsafe(empty_hash);
        return;
    }

    const offset_usize = @as(usize, @intCast(offset));
    const size_usize = @as(usize, @intCast(size));

    // Check if offset + size would overflow
    const end = std.math.add(usize, offset_usize, size_usize) catch {
        @branchHint(.unlikely);
        return ExecutionError.Error.OutOfOffset;
    };

    // Check if the end position exceeds reasonable memory limits
    const memory_limits = @import("../constants/memory_limits.zig");
    if (end > memory_limits.MAX_MEMORY_SIZE) {
        @branchHint(.unlikely);
        return ExecutionError.Error.OutOfOffset;
    }

    // NOTE: Gas has already been charged by the interpreter using precomputed values
    // We still need to ensure memory is available (but without charging gas)
    _ = try frame.memory.ensure_context_capacity(@intCast(end));

    // Get data and hash using optimized stack buffer approach
    const data = try frame.memory.get_slice(offset_usize, size_usize);

    // Calculate keccak256 hash using optimized tiered stack buffers
    const hash = hash_with_stack_buffer(data);

    // Convert hash to u256 using std.mem for efficiency
    const result = std.mem.readInt(u256, &hash, .big);

    frame.stack.append_unsafe(result);
}

// FIXME: All test functions that used Frame/Contract have been removed
// They need to be rewritten to use ExecutionContext when the migration is complete
