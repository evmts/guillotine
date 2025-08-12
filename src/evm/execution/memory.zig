const std = @import("std");
const builtin = @import("builtin");
const Operation = @import("../opcodes/operation.zig");
const Log = @import("../log.zig");
const ExecutionError = @import("execution_error.zig");
const Frame = @import("../frame.zig").Frame;
const Stack = @import("../stack/stack.zig");
const GasConstants = @import("primitives").GasConstants;

// Safety check constants - only enabled in Debug and ReleaseSafe modes
// These checks are redundant after analysis.zig validates operations
const SAFE_STACK_CHECKS = builtin.mode != .ReleaseFast and builtin.mode != .ReleaseSmall;
const SAFE_MEMORY_EXPANSION = builtin.mode != .ReleaseFast and builtin.mode != .ReleaseSmall;

pub fn op_mload(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    if (SAFE_STACK_CHECKS) {
        if (frame.stack.size() < 1) {
            @branchHint(.cold);
            unreachable;
        }
    }

    // Get offset from top of stack unsafely - bounds checking is done in jump_table.zig
    const offset = try frame.stack.peek();

    // Check offset bounds
    if (offset > std.math.maxInt(usize)) {
        @branchHint(.unlikely);
        return ExecutionError.Error.OutOfOffset;
    }
    const offset_usize = @as(usize, @intCast(offset));
    const new_size = offset_usize + 32;

    // Calculate memory expansion gas cost
    const new_size_u64 = @as(u64, @intCast(new_size));
    const gas_cost = frame.memory.get_expansion_cost(new_size_u64);
    try frame.consume_gas(gas_cost);

    // Ensure memory is available - expand to word boundary to match gas calculation
    const aligned_size = std.mem.alignForward(usize, new_size, 32);
    if (SAFE_MEMORY_EXPANSION) {
        _ = try frame.memory.ensure_context_capacity(aligned_size);
    } else {
        // In fast modes, we trust that gas charging validated the expansion
        _ = frame.memory.ensure_context_capacity(aligned_size) catch unreachable;
    }

    // Read 32 bytes from memory - use unsafe variant since we just ensured capacity
    const value = if (SAFE_MEMORY_EXPANSION) 
        try frame.memory.get_u256(offset_usize)
    else 
        frame.memory.get_u256_unsafe(offset_usize);
    
    Log.debug("MLOAD: offset={} -> value={x:0>64}", .{ offset_usize, value });

    // Replace top of stack with loaded value unsafely - bounds checking is done in jump_table.zig
    try frame.stack.set_top(value);
}

pub fn op_mstore(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    if (SAFE_STACK_CHECKS) {
        if (frame.stack.size() < 2) {
            @branchHint(.cold);
            unreachable;
        }
    }

    // Pop two values unsafely using batch operation - bounds checking is done in jump_table.zig
    // EVM Stack: [..., value, offset] where offset is on top
    const popped = try frame.stack.pop2();
    const value = popped.a; // First popped (was second from top)
    const offset = popped.b; // Second popped (was top)

    // Check offset bounds
    if (offset > std.math.maxInt(usize)) {
        @branchHint(.unlikely);
        return ExecutionError.Error.OutOfOffset;
    }
    const offset_usize = @as(usize, @intCast(offset));
    const new_size = offset_usize + 32; // MSTORE writes 32 bytes

    // Calculate memory expansion gas cost
    const new_size_u64 = @as(u64, @intCast(new_size));
    const gas_cost = frame.memory.get_expansion_cost(new_size_u64);
    try frame.consume_gas(gas_cost);

    // Ensure memory is available - expand to word boundary to match gas calculation
    const aligned_size = std.mem.alignForward(usize, new_size, 32);
    if (SAFE_MEMORY_EXPANSION) {
        _ = try frame.memory.ensure_context_capacity(aligned_size);
    } else {
        // In fast modes, we trust that gas charging validated the expansion
        _ = frame.memory.ensure_context_capacity(aligned_size) catch unreachable;
    }

    // Write 32 bytes to memory (big-endian)
    var bytes: [32]u8 = undefined;
    std.mem.writeInt(u256, &bytes, value, .big);

    // Debug logging
    Log.debug("MSTORE: offset={}, value={x:0>64}, first_few_bytes={x}", .{ offset_usize, value, std.fmt.fmtSliceHexLower(bytes[0..@min(16, bytes.len)]) });

    // Use unsafe write since we just ensured capacity
    if (SAFE_MEMORY_EXPANSION) {
        try frame.memory.set_data(offset_usize, &bytes);
    } else {
        frame.memory.set_data_unsafe(offset_usize, &bytes);
    }
}

pub fn op_mstore8(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    if (SAFE_STACK_CHECKS) {
        if (frame.stack.size() < 2) {
            @branchHint(.cold);
            unreachable;
        }
    }

    // Pop two values unsafely using batch operation - bounds checking is done in jump_table.zig
    // EVM Stack: [..., value, offset] where offset is on top
    const popped = try frame.stack.pop2();
    const value = popped.a; // First popped (was second from top)
    const offset = popped.b; // Second popped (was top)

    // Check offset bounds
    if (offset > std.math.maxInt(usize)) {
        @branchHint(.unlikely);
        return ExecutionError.Error.OutOfOffset;
    }
    const offset_usize = @as(usize, @intCast(offset));
    const new_size = offset_usize + 1;

    // Calculate memory expansion gas cost
    const new_size_u64 = @as(u64, @intCast(new_size));
    const gas_cost = frame.memory.get_expansion_cost(new_size_u64);
    try frame.consume_gas(gas_cost);

    // Ensure memory is available - expand to word boundary to match gas calculation
    const aligned_size = std.mem.alignForward(usize, new_size, 32);
    if (SAFE_MEMORY_EXPANSION) {
        _ = try frame.memory.ensure_context_capacity(aligned_size);
    } else {
        // In fast modes, we trust that gas charging validated the expansion
        _ = frame.memory.ensure_context_capacity(aligned_size) catch unreachable;
    }

    // Write single byte to memory
    const byte_value = @as(u8, @truncate(value));
    const bytes = [_]u8{byte_value};
    if (SAFE_MEMORY_EXPANSION) {
        try frame.memory.set_data(offset_usize, &bytes);
    } else {
        frame.memory.set_data_unsafe(offset_usize, &bytes);
    }
}

pub fn op_msize(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    if (SAFE_STACK_CHECKS) {
        if (frame.stack.size() >= Stack.CAPACITY) {
            @branchHint(.cold);
            unreachable;
        }
    }

    // MSIZE returns the size in bytes, but memory is always expanded in 32-byte words
    // So we need to round up to the nearest word boundary
    const size = frame.memory.context_size();
    const aligned_size = std.mem.alignForward(usize, size, 32);

    // Push result unsafely - bounds checking is done in jump_table.zig
    try frame.stack.append(@as(u256, @intCast(aligned_size)));
}

pub fn op_mcopy(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    // EIP-5656 validation should be handled during bytecode analysis phase,
    // not at runtime. Invalid MCOPY opcodes should be rejected during code analysis.

    if (SAFE_STACK_CHECKS) {
        if (frame.stack.size() < 3) {
            @branchHint(.cold);
            unreachable;
        }
    }

    // Pop three values unsafely - bounds checking is done in jump_table.zig
    // EVM stack order per EIP-5656: [dst, src, length] (top to bottom)
    const dest = try frame.stack.pop();
    const src = try frame.stack.pop();
    const length = try frame.stack.pop();

    if (length == 0) {
        @branchHint(.unlikely);
        return;
    }

    // Check bounds
    if (dest > std.math.maxInt(usize) or src > std.math.maxInt(usize) or length > std.math.maxInt(usize)) {
        @branchHint(.unlikely);
        return ExecutionError.Error.OutOfOffset;
    }
    const dest_usize = @as(usize, @intCast(dest));
    const src_usize = @as(usize, @intCast(src));
    const length_usize = @as(usize, @intCast(length));

    // Calculate memory expansion gas cost
    const max_addr = @max(dest_usize + length_usize, src_usize + length_usize);
    const memory_gas = frame.memory.get_expansion_cost(@as(u64, @intCast(max_addr)));
    try frame.consume_gas(memory_gas);

    // Dynamic gas for copy operation
    const word_size = (length_usize + 31) / 32;
    try frame.consume_gas(GasConstants.CopyGas * word_size);

    // Ensure memory is available for both source and destination
    if (SAFE_MEMORY_EXPANSION) {
        _ = try frame.memory.ensure_context_capacity(max_addr);
    } else {
        // In fast modes, we trust that gas charging validated the expansion
        _ = frame.memory.ensure_context_capacity(max_addr) catch unreachable;
    }

    // Copy with overlap handling
    // Get memory slice and handle overlapping copy
    const mem_slice = frame.memory.slice();
    if (mem_slice.len >= max_addr) {
        @branchHint(.likely);
        // Handle overlapping memory copy correctly
        if (dest_usize > src_usize and dest_usize < src_usize + length_usize) {
            @branchHint(.unlikely);
            // Forward overlap: dest is within source range, copy backwards
            std.mem.copyBackwards(u8, mem_slice[dest_usize .. dest_usize + length_usize], mem_slice[src_usize .. src_usize + length_usize]);
        } else if (src_usize > dest_usize and src_usize < dest_usize + length_usize) {
            @branchHint(.unlikely);
            // Backward overlap: src is within dest range, copy forwards
            std.mem.copyForwards(u8, mem_slice[dest_usize .. dest_usize + length_usize], mem_slice[src_usize .. src_usize + length_usize]);
        } else {
            // No overlap, either direction is fine
            std.mem.copyForwards(u8, mem_slice[dest_usize .. dest_usize + length_usize], mem_slice[src_usize .. src_usize + length_usize]);
        }
    } else {
        return ExecutionError.Error.OutOfOffset;
    }
}
