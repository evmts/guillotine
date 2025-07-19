const std = @import("std");
const Operation = @import("../opcodes/operation.zig");
const Log = @import("../log.zig");
const ExecutionError = @import("execution_error.zig");
const Stack = @import("../stack/stack.zig");
const Frame = @import("../frame/frame.zig");
const Memory = @import("../memory/memory.zig");
const gas_constants = @import("../constants/gas_constants.zig");

// Helper to check if u256 fits in usize and convert to usize
fn check_offset_bounds(value: u256) ExecutionError.Error!usize {
    if (value > std.math.maxInt(usize)) {
        @branchHint(.unlikely);
        return ExecutionError.Error.OutOfOffset;
    }
    return @as(usize, @intCast(value));
}

// Helper to calculate memory expansion gas cost and consume it
fn calculate_memory_gas(frame: *Frame, new_size: usize) !void {
    const current_size = frame.memory.context_size();
    const gas_cost = gas_constants.memory_gas_cost(current_size, new_size);
    try frame.consume_gas(gas_cost);
}

// Helper to calculate word-aligned size
fn word_aligned_size(size: usize) usize {
    return ((size + 31) / 32) * 32;
}

// Helper to convert u256 to big-endian bytes
fn u256_to_big_endian_bytes(value: u256) [32]u8 {
    var bytes: [32]u8 = undefined;
    var temp = value;
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        bytes[31 - i] = @intCast(temp & 0xFF);
        temp = temp >> 8;
    }
    return bytes;
}

// Common copy operation helper
fn perform_copy_operation(frame: *Frame, mem_offset: usize, size: usize) !void {
    // Calculate memory expansion gas cost
    const new_size = mem_offset + size;
    try calculate_memory_gas(frame, new_size);
    
    // Dynamic gas for copy operation
    const word_size = (size + 31) / 32;
    try frame.consume_gas(gas_constants.COPY_GAS * word_size);
    
    // Ensure memory is available
    _ = try frame.memory.ensure_context_capacity(new_size);
}

pub fn op_mload(pc: usize, interpreter: *Operation.Interpreter, state: *Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;

    const frame = @as(*Frame, @ptrCast(@alignCast(state)));

    if (frame.stack.size < 1) {
        @branchHint(.cold);
        unreachable;
    }

    // Get offset from top of stack unsafely - bounds checking is done in jump_table.zig
    const offset = frame.stack.peek_unsafe().*;

    const offset_usize = try check_offset_bounds(offset);
    const new_size = offset_usize + 32;
    
    try calculate_memory_gas(frame, new_size);

    // Ensure memory is available - expand to word boundary to match gas calculation
    const aligned_size = word_aligned_size(new_size);
    _ = try frame.memory.ensure_context_capacity(aligned_size);

    // Read 32 bytes from memory
    const value = try frame.memory.get_u256(offset_usize);

    // Replace top of stack with loaded value unsafely - bounds checking is done in jump_table.zig
    frame.stack.set_top_unsafe(value);

    return Operation.ExecutionResult{};
}

pub fn op_mstore(pc: usize, interpreter: *Operation.Interpreter, state: *Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;

    const frame = @as(*Frame, @ptrCast(@alignCast(state)));

    if (frame.stack.size < 2) {
        @branchHint(.cold);
        unreachable;
    }

    // Pop two values unsafely using batch operation - bounds checking is done in jump_table.zig
    // EVM Stack: [..., value, offset] where offset is on top
    const popped = frame.stack.pop2_unsafe();
    const value = popped.a; // First popped (was second from top)
    const offset = popped.b; // Second popped (was top)

    const offset_usize = try check_offset_bounds(offset);
    const new_size = offset_usize + 32; // MSTORE writes 32 bytes
    
    try calculate_memory_gas(frame, new_size);

    // Ensure memory is available - expand to word boundary to match gas calculation
    const aligned_size = word_aligned_size(new_size);
    _ = try frame.memory.ensure_context_capacity(aligned_size);

    // Write 32 bytes to memory (big-endian)
    const bytes = u256_to_big_endian_bytes(value);
    try frame.memory.set_data(offset_usize, &bytes);

    return Operation.ExecutionResult{};
}

pub fn op_mstore8(pc: usize, interpreter: *Operation.Interpreter, state: *Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;

    const frame = @as(*Frame, @ptrCast(@alignCast(state)));

    if (frame.stack.size < 2) {
        @branchHint(.cold);
        unreachable;
    }

    // Pop two values unsafely using batch operation - bounds checking is done in jump_table.zig
    // EVM Stack: [..., value, offset] where offset is on top
    const popped = frame.stack.pop2_unsafe();
    const value = popped.a; // First popped (was second from top)
    const offset = popped.b; // Second popped (was top)

    const offset_usize = try check_offset_bounds(offset);
    const new_size = offset_usize + 1;
    
    try calculate_memory_gas(frame, new_size);

    // Ensure memory is available - expand to word boundary to match gas calculation
    const aligned_size = word_aligned_size(new_size);
    _ = try frame.memory.ensure_context_capacity(aligned_size);

    // Write single byte to memory
    const byte_value = @as(u8, @truncate(value));
    const bytes = [_]u8{byte_value};
    try frame.memory.set_data(offset_usize, &bytes);

    return Operation.ExecutionResult{};
}

pub fn op_msize(pc: usize, interpreter: *Operation.Interpreter, state: *Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;

    const frame = @as(*Frame, @ptrCast(@alignCast(state)));

    if (frame.stack.size >= Stack.CAPACITY) {
        @branchHint(.cold);
        unreachable;
    }

    // MSIZE returns the size in bytes, but memory is always expanded in 32-byte words
    // So we need to round up to the nearest word boundary
    const size = frame.memory.context_size();
    const aligned_size = word_aligned_size(size);

    // Push result unsafely - bounds checking is done in jump_table.zig
    frame.stack.append_unsafe(@as(u256, @intCast(aligned_size)));

    return Operation.ExecutionResult{};
}

pub fn op_mcopy(pc: usize, interpreter: *Operation.Interpreter, state: *Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;

    const frame = @as(*Frame, @ptrCast(@alignCast(state)));

    if (frame.stack.size < 3) {
        @branchHint(.cold);
        unreachable;
    }

    // Pop three values unsafely - bounds checking is done in jump_table.zig
    // EVM stack order: [..., dest, src, size] (top to bottom)
    const size = frame.stack.pop_unsafe();
    const src = frame.stack.pop_unsafe();
    const dest = frame.stack.pop_unsafe();

    if (size == 0) {
        @branchHint(.unlikely);
        return Operation.ExecutionResult{};
    }

    const dest_usize = try check_offset_bounds(dest);
    const src_usize = try check_offset_bounds(src);
    const size_usize = try check_offset_bounds(size);

    // Calculate memory expansion gas cost
    const current_size = frame.memory.context_size();
    const max_addr = @max(dest_usize + size_usize, src_usize + size_usize);
    const memory_gas = gas_constants.memory_gas_cost(current_size, max_addr);
    try frame.consume_gas(memory_gas);

    // Dynamic gas for copy operation
    const word_size = (size_usize + 31) / 32;
    try frame.consume_gas(gas_constants.COPY_GAS * word_size);

    // Ensure memory is available for both source and destination
    _ = try frame.memory.ensure_context_capacity(max_addr);

    // Copy with overlap handling
    // Get memory slice and handle overlapping copy
    const mem_slice = frame.memory.slice();
    if (mem_slice.len >= max_addr) {
        @branchHint(.likely);
        // Handle overlapping memory copy correctly
        if (dest_usize > src_usize and dest_usize < src_usize + size_usize) {
            @branchHint(.unlikely);
            // Forward overlap: dest is within source range, copy backwards
            std.mem.copyBackwards(u8, mem_slice[dest_usize .. dest_usize + size_usize], mem_slice[src_usize .. src_usize + size_usize]);
        } else if (src_usize > dest_usize and src_usize < dest_usize + size_usize) {
            @branchHint(.unlikely);
            // Backward overlap: src is within dest range, copy forwards
            std.mem.copyForwards(u8, mem_slice[dest_usize .. dest_usize + size_usize], mem_slice[src_usize .. src_usize + size_usize]);
        } else {
            // No overlap, either direction is fine
            std.mem.copyForwards(u8, mem_slice[dest_usize .. dest_usize + size_usize], mem_slice[src_usize .. src_usize + size_usize]);
        }
    } else {
        return ExecutionError.Error.OutOfOffset;
    }

    return Operation.ExecutionResult{};
}

pub fn op_calldataload(pc: usize, interpreter: *Operation.Interpreter, state: *Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;

    const frame = @as(*Frame, @ptrCast(@alignCast(state)));

    if (frame.stack.size < 1) {
        @branchHint(.cold);
        unreachable;
    }

    // Get offset from top of stack unsafely - bounds checking is done in jump_table.zig
    const offset = frame.stack.peek_unsafe().*;

    const offset_usize = check_offset_bounds(offset) catch {
        // Replace top of stack with 0 if offset is out of bounds
        frame.stack.set_top_unsafe(0);
        return Operation.ExecutionResult{};
    };

    // Read 32 bytes from calldata (pad with zeros)
    var result: u256 = 0;

    var i: isize = -32;
    while (i < 0) : (i += 1) {
        const idx = @as(usize, @intCast(i + 32));
        if (offset_usize + idx < frame.input.len) {
            @branchHint(.likely);
            result = (result << 8) | frame.input[offset_usize + idx];
        } else {
            result = result << 8;
        }
    }

    // Replace top of stack with loaded value unsafely - bounds checking is done in jump_table.zig
    frame.stack.set_top_unsafe(result);

    return Operation.ExecutionResult{};
}

pub fn op_calldatasize(pc: usize, interpreter: *Operation.Interpreter, state: *Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;

    const frame = @as(*Frame, @ptrCast(@alignCast(state)));

    if (frame.stack.size >= Stack.CAPACITY) {
        @branchHint(.cold);
        unreachable;
    }

    // Push result unsafely - bounds checking is done in jump_table.zig
    frame.stack.append_unsafe(@as(u256, @intCast(frame.input.len)));

    return Operation.ExecutionResult{};
}

pub fn op_calldatacopy(pc: usize, interpreter: *Operation.Interpreter, state: *Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;

    const frame = @as(*Frame, @ptrCast(@alignCast(state)));

    if (frame.stack.size < 3) {
        @branchHint(.cold);
        unreachable;
    }

    // Pop three values unsafely - bounds checking is done in jump_table.zig
    // EVM stack order: [..., size, data_offset, mem_offset] (top to bottom)
    const mem_offset = frame.stack.pop_unsafe();
    const data_offset = frame.stack.pop_unsafe();
    const size = frame.stack.pop_unsafe();

    if (size == 0) {
        @branchHint(.unlikely);
        return Operation.ExecutionResult{};
    }

    const mem_offset_usize = try check_offset_bounds(mem_offset);
    const data_offset_usize = try check_offset_bounds(data_offset);
    const size_usize = try check_offset_bounds(size);

    // Common copy operation handling (gas calculation and memory expansion)
    try perform_copy_operation(frame, mem_offset_usize, size_usize);

    // Copy calldata to memory
    try frame.memory.set_data_bounded(mem_offset_usize, frame.input, data_offset_usize, size_usize);

    return Operation.ExecutionResult{};
}

pub fn op_codesize(pc: usize, interpreter: *Operation.Interpreter, state: *Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;

    const frame = @as(*Frame, @ptrCast(@alignCast(state)));

    if (frame.stack.size >= Stack.CAPACITY) {
        @branchHint(.cold);
        unreachable;
    }

    // Push result unsafely - bounds checking is done in jump_table.zig
    frame.stack.append_unsafe(@as(u256, @intCast(frame.contract.code.len)));

    return Operation.ExecutionResult{};
}

pub fn op_codecopy(pc: usize, interpreter: *Operation.Interpreter, state: *Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;

    const frame = @as(*Frame, @ptrCast(@alignCast(state)));

    if (frame.stack.size < 3) {
        @branchHint(.cold);
        unreachable;
    }

    // Pop three values unsafely - bounds checking is done in jump_table.zig
    // EVM stack order: [..., size, code_offset, mem_offset] (top to bottom)
    const mem_offset = frame.stack.pop_unsafe();
    const code_offset = frame.stack.pop_unsafe();
    const size = frame.stack.pop_unsafe();

    Log.debug("CODECOPY: mem_offset={}, code_offset={}, size={}, code_len={}", .{ mem_offset, code_offset, size, frame.contract.code.len });

    if (size == 0) {
        @branchHint(.unlikely);
        Log.debug("CODECOPY: size is 0, returning early", .{});
        return Operation.ExecutionResult{};
    }

    const mem_offset_usize = try check_offset_bounds(mem_offset);
    const code_offset_usize = try check_offset_bounds(code_offset);
    const size_usize = try check_offset_bounds(size);

    // Common copy operation handling (gas calculation and memory expansion)
    try perform_copy_operation(frame, mem_offset_usize, size_usize);

    // Copy code to memory
    try frame.memory.set_data_bounded(mem_offset_usize, frame.contract.code, code_offset_usize, size_usize);

    Log.debug("CODECOPY: copied {} bytes from code[{}..{}] to memory[{}..{}]", .{ size_usize, code_offset_usize, code_offset_usize + size_usize, mem_offset_usize, mem_offset_usize + size_usize });

    return Operation.ExecutionResult{};
}

pub fn op_returndatasize(pc: usize, interpreter: *Operation.Interpreter, state: *Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;

    const frame = @as(*Frame, @ptrCast(@alignCast(state)));

    if (frame.stack.size >= Stack.CAPACITY) {
        @branchHint(.cold);
        unreachable;
    }

    // Push result unsafely - bounds checking is done in jump_table.zig
    frame.stack.append_unsafe(@as(u256, @intCast(frame.return_data.size())));

    return Operation.ExecutionResult{};
}

pub fn op_returndatacopy(pc: usize, interpreter: *Operation.Interpreter, state: *Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;

    const frame = @as(*Frame, @ptrCast(@alignCast(state)));

    if (frame.stack.size < 3) {
        @branchHint(.cold);
        unreachable;
    }

    // Pop three values unsafely - bounds checking is done in jump_table.zig
    // EVM stack order: [..., size, data_offset, mem_offset] (top to bottom)
    const mem_offset = frame.stack.pop_unsafe();
    const data_offset = frame.stack.pop_unsafe();
    const size = frame.stack.pop_unsafe();

    if (size == 0) {
        @branchHint(.unlikely);
        return Operation.ExecutionResult{};
    }

    const mem_offset_usize = try check_offset_bounds(mem_offset);
    const data_offset_usize = try check_offset_bounds(data_offset);
    const size_usize = try check_offset_bounds(size);

    // Check bounds
    if (data_offset_usize + size_usize > frame.return_data.size()) {
        @branchHint(.unlikely);
        return ExecutionError.Error.ReturnDataOutOfBounds;
    }

    // Common copy operation handling (gas calculation and memory expansion)
    try perform_copy_operation(frame, mem_offset_usize, size_usize);

    // Copy return data to memory
    const return_data = frame.return_data.get();
    try frame.memory.set_data(mem_offset_usize, return_data[data_offset_usize .. data_offset_usize + size_usize]);

    return Operation.ExecutionResult{};
}
