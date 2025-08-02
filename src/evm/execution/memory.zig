const std = @import("std");
const Operation = @import("../opcodes/operation.zig");
const Log = @import("../log.zig");
const ExecutionError = @import("execution_error.zig");
const Stack = @import("../stack/stack.zig");
const Frame = @import("../frame/frame.zig");
const Memory = @import("../memory/memory.zig");
const GasConstants = @import("primitives").GasConstants;

// Common copy operation helper
fn perform_copy_operation(frame: *Frame, mem_offset: usize, size: usize) !void {
    // Calculate memory expansion gas cost
    const new_size = mem_offset + size;
    const new_size_u64 = @as(u64, @intCast(new_size));
    const gas_cost = frame.memory.get_expansion_cost(new_size_u64);
    try frame.consume_gas(gas_cost);

    // Dynamic gas for copy operation
    const word_size = (size + 31) / 32;
    try frame.consume_gas(GasConstants.CopyGas * word_size);

    // Ensure memory is available
    _ = try frame.memory.ensure_context_capacity(new_size);
}

pub fn op_mload(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    const zone = tracy.zone(@src(), "op_mload\x00");
    defer zone.end();
    
    _ = pc;
    _ = interpreter;

    const frame = state;

    std.debug.assert(frame.stack.size() >= 1);

    // Get offset from top of stack unsafely - bounds checking is done in jump_table.zig
    const offset = frame.stack.peek_unsafe().*;

    // Check offset bounds
    if (offset > std.math.maxInt(usize)) {
        @branchHint(.unlikely);
        return ExecutionError.Error.OutOfOffset;
    }
    const offset_usize = @as(usize, @intCast(offset));

    // Unified memory check and expansion - combines gas calculation, consumption, and expansion
    try frame.check_memory_and_expand(offset_usize, 32);

    // Direct memory read for better performance
    const mem_slice = frame.get_memory_slice();
    const value = std.mem.readInt(u256, mem_slice[offset_usize..][0..32], .big);

    // Replace top of stack with loaded value unsafely - bounds checking is done in jump_table.zig
    frame.stack.set_top_unsafe(value);

    return Operation.ExecutionResult{};
}

pub fn op_mstore(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    const zone = tracy.zone(@src(), "op_mstore\x00");
    defer zone.end();
    
    _ = pc;
    _ = interpreter;

    const frame = state;

    std.debug.assert(frame.stack.size() >= 2);

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

    // Unified memory check and expansion - combines gas calculation, consumption, and expansion
    try frame.check_memory_and_expand(offset_usize, 32);

    // Direct memory write for better performance
    const mem_slice = frame.get_memory_slice();
    std.mem.writeInt(u256, mem_slice[offset_usize..][0..32], value, .big);

    return Operation.ExecutionResult{};
}

pub fn op_mstore8(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    const zone = tracy.zone(@src(), "op_mstore8\x00");
    defer zone.end();
    
    _ = pc;
    _ = interpreter;

    const frame = state;

    std.debug.assert(frame.stack.size() >= 2);

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

    // Unified memory check and expansion - combines gas calculation, consumption, and expansion
    try frame.check_memory_and_expand(offset_usize, 1);

    // Direct memory write for better performance
    const mem_slice = frame.get_memory_slice();
    const byte_value = @as(u8, @truncate(value));
    mem_slice[offset_usize] = byte_value;

    return Operation.ExecutionResult{};
}

pub fn op_msize(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    const zone = tracy.zone(@src(), "op_msize\x00");
    defer zone.end();
    
    _ = pc;
    _ = interpreter;

    const frame = state;

    std.debug.assert(frame.stack.size() < Stack.CAPACITY);

    // MSIZE returns the size in bytes, but memory is always expanded in 32-byte words
    // So we need to round up to the nearest word boundary
    const size = frame.memory.context_size();
    const aligned_size = std.mem.alignForward(usize, size, 32);

    // Push result unsafely - bounds checking is done in jump_table.zig
    frame.stack.append_unsafe(@as(u256, @intCast(aligned_size)));

    return Operation.ExecutionResult{};
}

pub fn op_mcopy(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    const zone = tracy.zone(@src(), "op_mcopy\x00");
    defer zone.end();
    
    _ = pc;
    _ = interpreter;

    const frame = state;

    std.debug.assert(frame.stack.size() >= 3);

    // Pop three values unsafely - bounds checking is done in jump_table.zig
    // EVM stack order per EIP-5656: [dst, src, length] (top to bottom)
    const dest = frame.stack.pop_unsafe();
    const src = frame.stack.pop_unsafe();
    const length = frame.stack.pop_unsafe();

    if (length == 0) {
        @branchHint(.unlikely);
        return Operation.ExecutionResult{};
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
    _ = try frame.memory.ensure_context_capacity(max_addr);

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

    return Operation.ExecutionResult{};
}

pub fn op_calldataload(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    const zone = tracy.zone(@src(), "op_calldataload\x00");
    defer zone.end();
    
    _ = pc;
    _ = interpreter;

    const frame = state;

    std.debug.assert(frame.stack.size() >= 1);

    // Get offset from top of stack unsafely - bounds checking is done in jump_table.zig
    const offset = frame.stack.peek_unsafe().*;

    // Check offset bounds
    if (offset > std.math.maxInt(usize)) {
        @branchHint(.unlikely);
        // Replace top of stack with 0 if offset is out of bounds
        frame.stack.set_top_unsafe(0);
        return Operation.ExecutionResult{};
    }
    const offset_usize = @as(usize, @intCast(offset));

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

pub fn op_calldatasize(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    const zone = tracy.zone(@src(), "op_calldatasize\x00");
    defer zone.end();
    
    _ = pc;
    _ = interpreter;

    const frame = state;

    std.debug.assert(frame.stack.size() < Stack.CAPACITY);

    // Push result unsafely - bounds checking is done in jump_table.zig
    frame.stack.append_unsafe(@as(u256, @intCast(frame.input.len)));

    return Operation.ExecutionResult{};
}

pub fn op_calldatacopy(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    const zone = tracy.zone(@src(), "op_calldatacopy\x00");
    defer zone.end();
    
    _ = pc;
    _ = interpreter;

    const frame = state;

    std.debug.assert(frame.stack.size() >= 3);

    // Pop three values unsafely - bounds checking is done in jump_table.zig
    // EVM stack order: [..., size, data_offset, mem_offset] (top to bottom)
    const mem_offset = frame.stack.pop_unsafe();
    const data_offset = frame.stack.pop_unsafe();
    const size = frame.stack.pop_unsafe();

    if (size == 0) {
        @branchHint(.unlikely);
        return Operation.ExecutionResult{};
    }

    // Check bounds
    if (mem_offset > std.math.maxInt(usize) or data_offset > std.math.maxInt(usize) or size > std.math.maxInt(usize)) {
        @branchHint(.unlikely);
        return ExecutionError.Error.OutOfOffset;
    }
    const mem_offset_usize = @as(usize, @intCast(mem_offset));
    const data_offset_usize = @as(usize, @intCast(data_offset));
    const size_usize = @as(usize, @intCast(size));

    // Common copy operation handling (gas calculation and memory expansion)
    try perform_copy_operation(frame, mem_offset_usize, size_usize);

    // Copy calldata to memory
    try frame.memory.set_data_bounded(mem_offset_usize, frame.input, data_offset_usize, size_usize);

    return Operation.ExecutionResult{};
}

pub fn op_codesize(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    const zone = tracy.zone(@src(), "op_codesize\x00");
    defer zone.end();
    
    _ = pc;
    _ = interpreter;

    const frame = state;

    std.debug.assert(frame.stack.size() < Stack.CAPACITY);

    // Push result unsafely - bounds checking is done in jump_table.zig
    frame.stack.append_unsafe(@as(u256, @intCast(frame.contract.code.len)));

    return Operation.ExecutionResult{};
}

pub fn op_codecopy(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    const zone = tracy.zone(@src(), "op_codecopy\x00");
    defer zone.end();
    
    _ = pc;
    _ = interpreter;

    const frame = state;

    std.debug.assert(frame.stack.size() >= 3);

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

    // Check bounds
    if (mem_offset > std.math.maxInt(usize) or code_offset > std.math.maxInt(usize) or size > std.math.maxInt(usize)) {
        @branchHint(.unlikely);
        return ExecutionError.Error.OutOfOffset;
    }
    const mem_offset_usize = @as(usize, @intCast(mem_offset));
    const code_offset_usize = @as(usize, @intCast(code_offset));
    const size_usize = @as(usize, @intCast(size));

    // Common copy operation handling (gas calculation and memory expansion)
    try perform_copy_operation(frame, mem_offset_usize, size_usize);

    // Copy code to memory
    try frame.memory.set_data_bounded(mem_offset_usize, frame.contract.code, code_offset_usize, size_usize);

    Log.debug("CODECOPY: copied {} bytes from code[{}..{}] to memory[{}..{}]", .{ size_usize, code_offset_usize, code_offset_usize + size_usize, mem_offset_usize, mem_offset_usize + size_usize });

    return Operation.ExecutionResult{};
}

pub fn op_returndatasize(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    const zone = tracy.zone(@src(), "op_returndatasize\x00");
    defer zone.end();
    
    _ = pc;
    _ = interpreter;

    const frame = state;

    std.debug.assert(frame.stack.size() < Stack.CAPACITY);

    // Push result unsafely - bounds checking is done in jump_table.zig
    frame.stack.append_unsafe(@as(u256, @intCast(frame.return_data.size())));

    return Operation.ExecutionResult{};
}

pub fn op_returndatacopy(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    const zone = tracy.zone(@src(), "op_returndatacopy\x00");
    defer zone.end();
    
    _ = pc;
    _ = interpreter;

    const frame = state;

    std.debug.assert(frame.stack.size() >= 3);

    // Pop three values unsafely - bounds checking is done in jump_table.zig
    // EVM stack order: [..., size, data_offset, mem_offset] (top to bottom)
    const mem_offset = frame.stack.pop_unsafe();
    const data_offset = frame.stack.pop_unsafe();
    const size = frame.stack.pop_unsafe();

    if (size == 0) {
        @branchHint(.unlikely);
        return Operation.ExecutionResult{};
    }

    // Check bounds
    if (mem_offset > std.math.maxInt(usize) or data_offset > std.math.maxInt(usize) or size > std.math.maxInt(usize)) {
        @branchHint(.unlikely);
        return ExecutionError.Error.OutOfOffset;
    }
    const mem_offset_usize = @as(usize, @intCast(mem_offset));
    const data_offset_usize = @as(usize, @intCast(data_offset));
    const size_usize = @as(usize, @intCast(size));

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

// Testing imports and definitions
const testing = std.testing;
const MemoryDatabase = @import("../state/memory_database.zig");
const primitives = @import("primitives");
const Vm = @import("../evm.zig");
const Contract = @import("../frame/contract.zig");
const tracy = @import("../tracy_support.zig");
const Address = primitives.Address;

const FuzzMemoryOperation = struct {
    op_type: MemoryOpType,
    offset: u256,
    value: u256 = 0,
    size: u256 = 0,
    src_offset: u256 = 0,
    data_offset: u256 = 0,
    gas_limit: u64 = 1000000,
    calldata: []const u8 = &.{},
    code: []const u8 = &.{},
    return_data: []const u8 = &.{},
    expected_error: ?ExecutionError.Error = null,
};

const MemoryOpType = enum {
    mload,
    mstore,
    mstore8,
    msize,
    mcopy,
    calldataload,
    calldatasize,
    calldatacopy,
    codesize,
    codecopy,
    returndatasize,
    returndatacopy,
};

fn fuzz_memory_operations(allocator: std.mem.Allocator, operations: []const FuzzMemoryOperation) !void {
    for (operations) |op| {
        var memory_db = MemoryDatabase.init(allocator);
        defer memory_db.deinit();

        const db_interface = memory_db.to_database_interface();
        var vm = try Vm.init(allocator, db_interface, null, null);
        defer vm.deinit();

        var contract = try Contract.init(allocator, op.code, .{
            .address = Address.ZERO,
        });
        defer contract.deinit(allocator, null);

        var frame = try Frame.init(allocator, &vm, op.gas_limit, contract, Address.ZERO, op.calldata);
        defer frame.deinit();

        // Set up return data if needed
        if (op.return_data.len > 0) {
            frame.return_data.set(op.return_data);
        }

        // Execute the operation based on type
        const result = switch (op.op_type) {
            .mload => blk: {
                try frame.stack.append(op.offset);
                break :blk op_mload(0, &Operation.Interpreter{ .vm = &vm }, &Operation.State{ .frame = &frame });
            },
            .mstore => blk: {
                try frame.stack.append(op.offset);
                try frame.stack.append(op.value);
                break :blk op_mstore(0, &Operation.Interpreter{ .vm = &vm }, &Operation.State{ .frame = &frame });
            },
            .mstore8 => blk: {
                try frame.stack.append(op.offset);
                try frame.stack.append(op.value);
                break :blk op_mstore8(0, &Operation.Interpreter{ .vm = &vm }, &Operation.State{ .frame = &frame });
            },
            .msize => blk: {
                break :blk op_msize(0, &Operation.Interpreter{ .vm = &vm }, &Operation.State{ .frame = &frame });
            },
            .mcopy => blk: {
                try frame.stack.append(op.offset); // dest
                try frame.stack.append(op.src_offset); // src
                try frame.stack.append(op.size); // size
                break :blk op_mcopy(0, &Operation.Interpreter{ .vm = &vm }, &Operation.State{ .frame = &frame });
            },
            .calldataload => blk: {
                try frame.stack.append(op.offset);
                break :blk op_calldataload(0, &Operation.Interpreter{ .vm = &vm }, &Operation.State{ .frame = &frame });
            },
            .calldatasize => blk: {
                break :blk op_calldatasize(0, &Operation.Interpreter{ .vm = &vm }, &Operation.State{ .frame = &frame });
            },
            .calldatacopy => blk: {
                try frame.stack.append(op.offset); // mem_offset
                try frame.stack.append(op.data_offset); // data_offset
                try frame.stack.append(op.size); // size
                break :blk op_calldatacopy(0, &Operation.Interpreter{ .vm = &vm }, &Operation.State{ .frame = &frame });
            },
            .codesize => blk: {
                break :blk op_codesize(0, &Operation.Interpreter{ .vm = &vm }, &Operation.State{ .frame = &frame });
            },
            .codecopy => blk: {
                try frame.stack.append(op.offset); // mem_offset
                try frame.stack.append(op.data_offset); // code_offset
                try frame.stack.append(op.size); // size
                break :blk op_codecopy(0, &Operation.Interpreter{ .vm = &vm }, &Operation.State{ .frame = &frame });
            },
            .returndatasize => blk: {
                break :blk op_returndatasize(0, &Operation.Interpreter{ .vm = &vm }, &Operation.State{ .frame = &frame });
            },
            .returndatacopy => blk: {
                try frame.stack.append(op.offset); // mem_offset
                try frame.stack.append(op.data_offset); // data_offset
                try frame.stack.append(op.size); // size
                break :blk op_returndatacopy(0, &Operation.Interpreter{ .vm = &vm }, &Operation.State{ .frame = &frame });
            },
        };

        // Validate the result
        try validate_memory_result(&frame, op, result);
    }
}

fn validate_memory_result(frame: *const Frame, op: FuzzMemoryOperation, result: anyerror!Operation.ExecutionResult) !void {
    if (op.expected_error) |expected_err| {
        try testing.expectError(expected_err, result);
        return;
    }

    try result;

    // Validate stack results for operations that push values
    switch (op.op_type) {
        .mload, .calldataload => {
            try testing.expectEqual(@as(usize, 1), frame.stack.size());
            // Additional validation can be done based on specific test cases
        },
        .msize, .calldatasize, .codesize, .returndatasize => {
            try testing.expectEqual(@as(usize, 1), frame.stack.size());
        },
        .mstore, .mstore8, .mcopy, .calldatacopy, .codecopy, .returndatacopy => {
            // These operations don't push to stack
            try testing.expectEqual(@as(usize, 0), frame.stack.size());
        },
    }
}

test "fuzz_memory_basic_operations" {
    const allocator = std.testing.allocator;

    const test_calldata = [_]u8{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88 };
    const test_code = [_]u8{ 0x60, 0x00, 0x60, 0x00, 0x50, 0x00 }; // PUSH1 0 PUSH1 0 POP STOP

    const operations = [_]FuzzMemoryOperation{
        // Basic MSTORE and MLOAD
        .{
            .op_type = .mstore,
            .offset = 0,
            .value = 0x123456789abcdef0,
        },
        .{
            .op_type = .mload,
            .offset = 0,
        },
        // MSTORE8 test
        .{
            .op_type = .mstore8,
            .offset = 32,
            .value = 0xAB,
        },
        // MSIZE test
        .{
            .op_type = .msize,
        },
        // Calldata operations
        .{
            .op_type = .calldatasize,
            .calldata = &test_calldata,
        },
        .{
            .op_type = .calldataload,
            .offset = 0,
            .calldata = &test_calldata,
        },
        // Code operations
        .{
            .op_type = .codesize,
            .code = &test_code,
        },
    };

    try fuzz_memory_operations(allocator, &operations);
}

test "fuzz_memory_edge_cases" {
    const allocator = std.testing.allocator;

    const operations = [_]FuzzMemoryOperation{
        // Large offset MLOAD (should expand memory)
        .{
            .op_type = .mload,
            .offset = 1024,
        },
        // Large offset MSTORE
        .{
            .op_type = .mstore,
            .offset = 2048,
            .value = std.math.maxInt(u256),
        },
        // Very large offset (should fail)
        .{
            .op_type = .mload,
            .offset = std.math.maxInt(u256),
            .expected_error = ExecutionError.Error.OutOfOffset,
        },
        // Zero size copy operations
        .{
            .op_type = .mcopy,
            .offset = 0,
            .src_offset = 0,
            .size = 0,
        },
        .{
            .op_type = .calldatacopy,
            .offset = 0,
            .data_offset = 0,
            .size = 0,
        },
        // Out of bounds return data copy
        .{
            .op_type = .returndatacopy,
            .offset = 0,
            .data_offset = 100,
            .size = 10,
            .return_data = &[_]u8{ 1, 2, 3, 4, 5 },
            .expected_error = ExecutionError.Error.ReturnDataOutOfBounds,
        },
    };

    try fuzz_memory_operations(allocator, &operations);
}

test "fuzz_memory_copy_operations" {
    const allocator = std.testing.allocator;

    const test_data = [_]u8{} ** 64; // 64 bytes of zeros
    const code_data = [_]u8{ 0x60, 0x40, 0x60, 0x00, 0x52 } ** 10; // Some bytecode pattern

    const operations = [_]FuzzMemoryOperation{
        // Basic MCOPY
        .{
            .op_type = .mstore,
            .offset = 0,
            .value = 0xdeadbeef,
        },
        .{
            .op_type = .mcopy,
            .offset = 32, // dest
            .src_offset = 0, // src
            .size = 32,
        },
        // Overlapping MCOPY (forward overlap)
        .{
            .op_type = .mcopy,
            .offset = 16, // dest
            .src_offset = 0, // src
            .size = 32,
        },
        // Overlapping MCOPY (backward overlap)
        .{
            .op_type = .mcopy,
            .offset = 0, // dest
            .src_offset = 16, // src
            .size = 32,
        },
        // CALLDATACOPY
        .{
            .op_type = .calldatacopy,
            .offset = 64,
            .data_offset = 0,
            .size = 64,
            .calldata = &test_data,
        },
        // CODECOPY
        .{
            .op_type = .codecopy,
            .offset = 128,
            .data_offset = 0,
            .size = 50,
            .code = &code_data,
        },
        // RETURNDATACOPY
        .{
            .op_type = .returndatacopy,
            .offset = 256,
            .data_offset = 0,
            .size = 32,
            .return_data = &test_data[0..32],
        },
    };

    try fuzz_memory_operations(allocator, &operations);
}

test "fuzz_memory_gas_consumption" {
    const allocator = std.testing.allocator;

    const operations = [_]FuzzMemoryOperation{
        // Test insufficient gas for memory expansion
        .{
            .op_type = .mload,
            .offset = 100000, // Large offset requiring memory expansion
            .gas_limit = 100, // Not enough gas
            .expected_error = ExecutionError.Error.OutOfGas,
        },
        // Test insufficient gas for copy operation
        .{
            .op_type = .mcopy,
            .offset = 0,
            .src_offset = 0,
            .size = 10000, // Large copy
            .gas_limit = 100, // Not enough gas
            .expected_error = ExecutionError.Error.OutOfGas,
        },
    };

    try fuzz_memory_operations(allocator, &operations);
}

test "fuzz_memory_random_operations" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();

    var operations = std.ArrayList(FuzzMemoryOperation).init(allocator);
    defer operations.deinit();

    // Generate random test data
    var random_calldata: [128]u8 = undefined;
    var random_code: [256]u8 = undefined;
    var random_return_data: [64]u8 = undefined;

    random.bytes(&random_calldata);
    random.bytes(&random_code);
    random.bytes(&random_return_data);

    var i: usize = 0;
    while (i < 30) : (i += 1) {
        const op_type_idx = random.intRangeAtMost(usize, 0, 11);
        const op_types = [_]MemoryOpType{ .mload, .mstore, .mstore8, .msize, .mcopy, .calldataload, .calldatasize, .calldatacopy, .codesize, .codecopy, .returndatasize, .returndatacopy };
        const op_type = op_types[op_type_idx];

        const offset = random.intRangeAtMost(u256, 0, 10000);
        const value = random.int(u256);
        const size = random.intRangeAtMost(u256, 0, 1000);
        const src_offset = random.intRangeAtMost(u256, 0, 1000);
        const data_offset = random.intRangeAtMost(u256, 0, 100);
        const gas_limit = random.intRangeAtMost(u64, 10000, 1000000);

        try operations.append(.{
            .op_type = op_type,
            .offset = offset,
            .value = value,
            .size = size,
            .src_offset = src_offset,
            .data_offset = data_offset,
            .gas_limit = gas_limit,
            .calldata = &random_calldata,
            .code = &random_code,
            .return_data = &random_return_data,
        });
    }

    try fuzz_memory_operations(allocator, operations.items);
}

test "optimized_memory_operations_basic" {
    const allocator = std.testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    var contract = try Contract.init(allocator, &[_]u8{0x01}, .{ .address = Address.ZERO });
    defer contract.deinit(allocator, null);

    var frame = try Frame.init(allocator, &vm, 1000000, contract, Address.ZERO, &.{});
    defer frame.deinit();

    // Test optimized MSTORE operation
    try frame.stack.append(0); // offset
    try frame.stack.append(0x123456789abcdef0); // value
    
    const interpreter_ptr: *Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: *Operation.State = @ptrCast(&frame);
    _ = try vm.table.execute(0, interpreter_ptr, state_ptr, 0x52); // MSTORE opcode

    // Test optimized MLOAD operation
    try frame.stack.append(0); // offset
    _ = try vm.table.execute(0, interpreter_ptr, state_ptr, 0x51); // MLOAD opcode

    const result = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0x123456789abcdef0), result);
}

test "unified_memory_check_function" {
    const allocator = std.testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    var contract = try Contract.init(allocator, &[_]u8{}, .{ .address = Address.ZERO });
    defer contract.deinit(allocator, null);

    var frame = try Frame.init(allocator, &vm, 1000000, contract, Address.ZERO, &.{});
    defer frame.deinit();

    // Test unified memory check with no expansion needed
    const initial_gas = frame.gas_remaining;
    try frame.check_memory_and_expand(0, 0);
    try std.testing.expectEqual(initial_gas, frame.gas_remaining); // No gas consumed

    // Test unified memory check with expansion
    try frame.check_memory_and_expand(0, 32);
    try std.testing.expect(frame.gas_remaining < initial_gas); // Gas was consumed for expansion
    try std.testing.expectEqual(@as(usize, 32), frame.memory.context_size());

    // Test getting direct memory slice
    const mem_slice = frame.get_memory_slice();
    try std.testing.expectEqual(@as(usize, 32), mem_slice.len);
}
