//! Memory operations for the Ethereum Virtual Machine
//!
//! This module implements memory-related opcodes including MLOAD, MSTORE,
//! MSTORE8, MSIZE, MCOPY, CALLDATACOPY, CODECOPY, EXTCODECOPY, and RETURNDATACOPY.
//!
//! ## Memory Model
//! - Memory is byte-addressable and expands on demand
//! - Memory expansion costs gas quadratically
//! - All memory is initialized to zero
//! - Memory is local to each execution context
//!
//! ## Gas Costs
//! - MLOAD, MSTORE, MSTORE8: 3 gas + memory expansion
//! - MSIZE: 2 gas
//! - Copy operations: 3 gas + 3 per word + memory expansion

const std = @import("std");
const builtin = @import("builtin");
const Operation = @import("../opcodes/operation.zig");
const Log = @import("../log.zig");
const ExecutionError = @import("execution_error.zig");
const Frame = @import("../stack_frame.zig").StackFrame;
const Stack = @import("../stack/stack.zig");
const GasConstants = @import("primitives").GasConstants;

// Safety check constants - only enabled in Debug and ReleaseSafe modes
// These checks are redundant after analysis.zig validates operations
const SAFE_STACK_CHECKS = builtin.mode != .ReleaseFast and builtin.mode != .ReleaseSmall;
const SAFE_MEMORY_EXPANSION = builtin.mode != .ReleaseFast and builtin.mode != .ReleaseSmall;

/// MLOAD opcode (0x51) - Load word from memory
///
/// Loads 32 bytes from memory starting at the given offset.
/// Stack: [offset] → [value]
pub fn op_mload(frame: *Frame) ExecutionError.Error!void {
    if (SAFE_STACK_CHECKS) {
        if (frame.stack.size() < 1) {
            @branchHint(.cold);
            unreachable;
        }
    }

    // Get offset from top of stack unsafely - bounds checking is done in jump_table.zig
    const offset = try frame.stack.peek_unsafe();

    // Check offset bounds
    if (offset > std.math.maxInt(usize)) {
        @branchHint(.unlikely);
        return ExecutionError.Error.OutOfOffset;
    }
    const offset_usize = @as(usize, @intCast(offset));
    const new_size = offset_usize + 32;

    // Charge gas and ensure memory is available - expand to word boundary
    const aligned_size = std.mem.alignForward(usize, new_size, 32);
    try frame.memory.charge_and_ensure(frame, @as(u64, @intCast(aligned_size)));

    // Read 32 bytes from memory - use unsafe variant since we just ensured capacity
    const value = if (SAFE_MEMORY_EXPANSION)
        try frame.memory.get_u256(offset_usize)
    else
        frame.memory.get_u256_unsafe(offset_usize);

    Log.debug("MLOAD: offset={} -> value={x:0>64}", .{ offset_usize, value });

    // Replace top of stack with loaded value unsafely - bounds checking is done in jump_table.zig
    frame.stack.set_top_unsafe(value);
}

/// MSTORE opcode (0x52) - Store word to memory
///
/// Stores 32 bytes to memory starting at the given offset.
/// Stack: [offset, value] → []
pub fn op_mstore(frame: *Frame) ExecutionError.Error!void {
    if (SAFE_STACK_CHECKS) {
        if (frame.stack.size() < 2) {
            @branchHint(.cold);
            unreachable;
        }
    }

    // Pop two values unsafely using batch operation - bounds checking is done in jump_table.zig
    // EVM Stack: [..., value, offset] where offset is on top
    const popped = frame.stack.pop2_unsafe();
    const value = popped.a; // First popped (was second from top)
    const offset = popped.b; // Second popped (was top)

    // Check offset bounds
    if (offset > std.math.maxInt(usize)) {
        @branchHint(.unlikely);
        return ExecutionError.Error.OutOfOffset;
    }
    const offset_usize = @as(usize, @intCast(offset));
    const new_size = offset_usize + 32; // MSTORE writes 32 bytes

    // Charge gas and ensure memory is available - expand to word boundary
    const aligned_size = std.mem.alignForward(usize, new_size, 32);
    try frame.memory.charge_and_ensure(frame, @as(u64, @intCast(aligned_size)));

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

/// MSTORE8 opcode (0x53) - Store byte to memory
///
/// Stores a single byte (LSB of the value) to memory at the given offset.
/// Stack: [offset, value] → []
pub fn op_mstore8(frame: *Frame) ExecutionError.Error!void {
    if (SAFE_STACK_CHECKS) {
        if (frame.stack.size() < 2) {
            @branchHint(.cold);
            unreachable;
        }
    }

    // Pop two values unsafely using batch operation - bounds checking is done in jump_table.zig
    // EVM Stack: [..., value, offset] where offset is on top
    const popped = frame.stack.pop2_unsafe();
    const value = popped.a; // First popped (was second from top)
    const offset = popped.b; // Second popped (was top)

    // Check offset bounds
    if (offset > std.math.maxInt(usize)) {
        @branchHint(.unlikely);
        return ExecutionError.Error.OutOfOffset;
    }
    const offset_usize = @as(usize, @intCast(offset));
    const new_size = offset_usize + 1;

    // Charge gas and ensure memory is available - expand to word boundary
    const aligned_size = std.mem.alignForward(usize, new_size, 32);
    try frame.memory.charge_and_ensure(frame, @as(u64, @intCast(aligned_size)));

    // Write single byte to memory
    const byte_value = @as(u8, @truncate(value));
    const bytes = [_]u8{byte_value};
    if (SAFE_MEMORY_EXPANSION) {
        try frame.memory.set_data(offset_usize, &bytes);
    } else {
        frame.memory.set_data_unsafe(offset_usize, &bytes);
    }
}

/// MSIZE opcode (0x59) - Get size of active memory
///
/// Returns the size of active memory in bytes, rounded up to the nearest word (32 bytes).
/// Stack: [] → [size]
pub fn op_msize(frame: *Frame) ExecutionError.Error!void {
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
    frame.stack.append_unsafe(@as(u256, @intCast(aligned_size)));
}

/// MCOPY opcode (0x5E) - Copy memory areas
///
/// Copies data within memory from source to destination (EIP-5656, Cancun).
/// Handles overlapping regions correctly.
/// Stack: [dest, src, length] → []
pub fn op_mcopy(frame: *Frame) ExecutionError.Error!void {

    if (SAFE_STACK_CHECKS) {
        if (frame.stack.size() < 3) {
            @branchHint(.cold);
            unreachable;
        }
    }

    // Pop three values unsafely - bounds checking is done in jump_table.zig
    // EVM stack order per EIP-5656: [dst, src, length] (top to bottom)
    const dest = frame.stack.pop_unsafe();
    const src = frame.stack.pop_unsafe();
    const length = frame.stack.pop_unsafe();

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

    // Calculate max memory address needed
    const max_addr = @max(dest_usize + length_usize, src_usize + length_usize);

    // Charge gas and ensure memory is available
    try frame.memory.charge_and_ensure(frame, @as(u64, @intCast(max_addr)));

    // Dynamic gas for copy operation
    const word_size = (length_usize + 31) / 32;
    try frame.consume_gas(GasConstants.CopyGas * word_size);

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