const std = @import("std");
const Operation = @import("../opcodes/operation.zig");
const Log = @import("../log.zig");
const ExecutionError = @import("execution_error.zig");
const Stack = @import("../stack/stack.zig");
const Frame = @import("../frame/frame.zig");
const Memory = @import("../memory/memory.zig");
const gas_constants = @import("../constants/gas_constants.zig");


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

    if (offset > std.math.maxInt(usize)) {
        @branchHint(.unlikely);
        return ExecutionError.Error.OutOfOffset;
    }

    const offset_usize = @as(usize, @intCast(offset));

    // Calculate memory expansion gas cost
    const current_size = frame.memory.context_size();
    const new_size = offset_usize + 32;
    const gas_cost = gas_constants.memory_gas_cost(current_size, new_size);

    try frame.consume_gas(gas_cost);

    // Ensure memory is available - expand to word boundary to match gas calculation
    const word_aligned_size = ((offset_usize + 32 + 31) / 32) * 32;
    _ = try frame.memory.ensure_context_capacity(word_aligned_size);

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

    if (offset > std.math.maxInt(usize)) {
        @branchHint(.unlikely);
        return ExecutionError.Error.OutOfOffset;
    }

    const offset_usize = @as(usize, @intCast(offset));

    // Calculate memory expansion gas cost
    const current_size = frame.memory.context_size();
    const new_size = offset_usize + 32; // MSTORE writes 32 bytes
    const expansion_gas_cost = gas_constants.memory_gas_cost(current_size, new_size);

    try frame.consume_gas(expansion_gas_cost);

    // Ensure memory is available - expand to word boundary to match gas calculation
    const word_aligned_size = ((offset_usize + 32 + 31) / 32) * 32;
    _ = try frame.memory.ensure_context_capacity(word_aligned_size);

    // Write 32 bytes to memory (big-endian)
    var bytes: [32]u8 = undefined;
    // Convert u256 to big-endian bytes
    var temp = value;
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        bytes[31 - i] = @intCast(temp & 0xFF);
        temp = temp >> 8;
    }
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

    if (offset > std.math.maxInt(usize)) {
        @branchHint(.unlikely);
        return ExecutionError.Error.OutOfOffset;
    }

    const offset_usize = @as(usize, @intCast(offset));

    // Calculate memory expansion gas cost
    const current_size = frame.memory.context_size();
    const new_size = offset_usize + 1;
    const gas_cost = gas_constants.memory_gas_cost(current_size, new_size);
    try frame.consume_gas(gas_cost);

    // Ensure memory is available - expand to word boundary to match gas calculation
    const word_aligned_size = ((new_size + 31) / 32) * 32;
    _ = try frame.memory.ensure_context_capacity(word_aligned_size);

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
    const word_aligned_size = ((size + 31) / 32) * 32;

    // Push result unsafely - bounds checking is done in jump_table.zig
    frame.stack.append_unsafe(@as(u256, @intCast(word_aligned_size)));

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

    if (dest > std.math.maxInt(usize) or src > std.math.maxInt(usize) or size > std.math.maxInt(usize)) {
        @branchHint(.unlikely);
        return ExecutionError.Error.OutOfOffset;
    }

    const dest_usize = @as(usize, @intCast(dest));
    const src_usize = @as(usize, @intCast(src));
    const size_usize = @as(usize, @intCast(size));

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

    if (offset > std.math.maxInt(usize)) {
        @branchHint(.unlikely);
        // Replace top of stack with 0
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

    if (mem_offset > std.math.maxInt(usize) or data_offset > std.math.maxInt(usize) or size > std.math.maxInt(usize)) {
        @branchHint(.unlikely);
        return ExecutionError.Error.OutOfOffset;
    }

    const mem_offset_usize = @as(usize, @intCast(mem_offset));
    const data_offset_usize = @as(usize, @intCast(data_offset));
    const size_usize = @as(usize, @intCast(size));

    // Calculate memory expansion gas cost
    const current_size = frame.memory.context_size();
    const new_size = mem_offset_usize + size_usize;
    const memory_gas = gas_constants.memory_gas_cost(current_size, new_size);
    try frame.consume_gas(memory_gas);

    // Dynamic gas for copy operation
    const word_size = (size_usize + 31) / 32;
    try frame.consume_gas(gas_constants.COPY_GAS * word_size);

    // Ensure memory is available
    _ = try frame.memory.ensure_context_capacity(mem_offset_usize + size_usize);

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

    if (mem_offset > std.math.maxInt(usize) or code_offset > std.math.maxInt(usize) or size > std.math.maxInt(usize)) return ExecutionError.Error.OutOfOffset;

    const mem_offset_usize = @as(usize, @intCast(mem_offset));
    const code_offset_usize = @as(usize, @intCast(code_offset));
    const size_usize = @as(usize, @intCast(size));

    // Calculate memory expansion gas cost
    const current_size = frame.memory.context_size();
    const new_size = mem_offset_usize + size_usize;
    const memory_gas = gas_constants.memory_gas_cost(current_size, new_size);
    try frame.consume_gas(memory_gas);

    // Dynamic gas for copy operation
    const word_size = (size_usize + 31) / 32;
    try frame.consume_gas(gas_constants.COPY_GAS * word_size);

    // Ensure memory is available
    _ = try frame.memory.ensure_context_capacity(mem_offset_usize + size_usize);

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

    // Calculate memory expansion gas cost
    const current_size = frame.memory.context_size();
    const new_size = mem_offset_usize + size_usize;
    const memory_gas = gas_constants.memory_gas_cost(current_size, new_size);
    try frame.consume_gas(memory_gas);

    // Dynamic gas for copy operation
    const word_size = (size_usize + 31) / 32;
    try frame.consume_gas(gas_constants.COPY_GAS * word_size);

    // Ensure memory is available
    _ = try frame.memory.ensure_context_capacity(mem_offset_usize + size_usize);

    // Copy return data to memory
    const return_data = frame.return_data.get();
    try frame.memory.set_data(mem_offset_usize, return_data[data_offset_usize .. data_offset_usize + size_usize]);

    return Operation.ExecutionResult{};
}

// ============================================================================
// BENCHMARKS - Memory Operations Performance Testing
// ============================================================================

/// Benchmark configuration for memory operations
const MemoryBenchmarkConfig = struct {
    iterations: usize = 10000,
    warmup_iterations: usize = 1000,
};

/// Benchmark MLOAD opcode performance
pub fn benchmark_mload_opcode(allocator: std.mem.Allocator, config: MemoryBenchmarkConfig) !u64 {
    const Vm = @import("../evm.zig");
    const MemoryDatabase = @import("../state/memory_database.zig");
    const Contract = @import("../frame/contract.zig");
    const primitives = @import("primitives");
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.toDatabaseInterface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();
    
    var contract = try Contract.init(allocator, &[_]u8{0x51}, .{ .address = primitives.Address.ZERO });
    defer contract.deinit(allocator, null);
    
    var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.ZERO, &.{});
    defer frame.deinit();
    
    // Pre-populate memory with some data
    _ = try frame.memory.ensure_context_capacity(1024);
    try frame.memory.set_u256(0, 0x123456789ABCDEF0);
    
    // Warmup
    var i: usize = 0;
    while (i < config.warmup_iterations) : (i += 1) {
        frame.stack.reset();
        frame.gas_remaining = 1000000;
        try frame.stack.append(0); // Load from offset 0
        _ = try op_mload(0, @ptrCast(&vm), @ptrCast(&frame));
    }
    
    // Benchmark
    const start_time = std.time.nanoTimestamp();
    i = 0;
    while (i < config.iterations) : (i += 1) {
        frame.stack.reset();
        frame.gas_remaining = 1000000;
        try frame.stack.append(0); // Load from offset 0
        _ = try op_mload(0, @ptrCast(&vm), @ptrCast(&frame));
    }
    const end_time = std.time.nanoTimestamp();
    
    return @intCast(end_time - start_time);
}

/// Benchmark MSTORE opcode performance
pub fn benchmark_mstore_opcode(allocator: std.mem.Allocator, config: MemoryBenchmarkConfig) !u64 {
    const Vm = @import("../evm.zig");
    const MemoryDatabase = @import("../state/memory_database.zig");
    const Contract = @import("../frame/contract.zig");
    const primitives = @import("primitives");
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.toDatabaseInterface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();
    
    var contract = try Contract.init(allocator, &[_]u8{0x52}, .{ .address = primitives.Address.ZERO });
    defer contract.deinit(allocator, null);
    
    var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.ZERO, &.{});
    defer frame.deinit();
    
    // Warmup
    var i: usize = 0;
    while (i < config.warmup_iterations) : (i += 1) {
        frame.stack.reset();
        frame.gas_remaining = 1000000;
        try frame.stack.append(0x123456789ABCDEF0); // Value to store
        try frame.stack.append(32); // Offset to store at
        _ = try op_mstore(0, @ptrCast(&vm), @ptrCast(&frame));
    }
    
    // Benchmark
    const start_time = std.time.nanoTimestamp();
    i = 0;
    while (i < config.iterations) : (i += 1) {
        frame.stack.reset();
        frame.gas_remaining = 1000000;
        try frame.stack.append(0x123456789ABCDEF0); // Value to store
        try frame.stack.append(32); // Offset to store at
        _ = try op_mstore(0, @ptrCast(&vm), @ptrCast(&frame));
    }
    const end_time = std.time.nanoTimestamp();
    
    return @intCast(end_time - start_time);
}

/// Benchmark CALLDATALOAD opcode performance
pub fn benchmark_calldataload_opcode(allocator: std.mem.Allocator, config: MemoryBenchmarkConfig) !u64 {
    const Vm = @import("../evm.zig");
    const MemoryDatabase = @import("../state/memory_database.zig");
    const Contract = @import("../frame/contract.zig");
    const primitives = @import("primitives");
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.toDatabaseInterface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();
    
    var contract = try Contract.init(allocator, &[_]u8{0x35}, .{ .address = primitives.Address.ZERO });
    defer contract.deinit(allocator, null);
    
    // Create some test call data
    const test_input = &[_]u8{ 0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0 } ** 8; // 64 bytes
    var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.ZERO, test_input);
    defer frame.deinit();
    
    // Warmup
    var i: usize = 0;
    while (i < config.warmup_iterations) : (i += 1) {
        frame.stack.reset();
        try frame.stack.append(0); // Offset to load from
        _ = try op_calldataload(0, @ptrCast(&vm), @ptrCast(&frame));
    }
    
    // Benchmark
    const start_time = std.time.nanoTimestamp();
    i = 0;
    while (i < config.iterations) : (i += 1) {
        frame.stack.reset();
        try frame.stack.append(0); // Offset to load from
        _ = try op_calldataload(0, @ptrCast(&vm), @ptrCast(&frame));
    }
    const end_time = std.time.nanoTimestamp();
    
    return @intCast(end_time - start_time);
}

/// Run all memory opcode benchmarks and print results
pub fn run_all_memory_benchmarks(allocator: std.mem.Allocator) !void {
    const config = MemoryBenchmarkConfig{};
    
    std.log.info("Running memory opcode benchmarks...", .{});
    
    const mload_time = try benchmark_mload_opcode(allocator, config);
    const mstore_time = try benchmark_mstore_opcode(allocator, config);
    const calldataload_time = try benchmark_calldataload_opcode(allocator, config);
    
    // Calculate ns per operation
    const mload_ns_per_op = mload_time / config.iterations;
    const mstore_ns_per_op = mstore_time / config.iterations;
    const calldataload_ns_per_op = calldataload_time / config.iterations;
    
    std.log.info("MLOAD:        {} ns/op ({} total ns)", .{ mload_ns_per_op, mload_time });
    std.log.info("MSTORE:       {} ns/op ({} total ns)", .{ mstore_ns_per_op, mstore_time });
    std.log.info("CALLDATALOAD: {} ns/op ({} total ns)", .{ calldataload_ns_per_op, calldataload_time });
}

test "memory_opcode_benchmarks" {
    const allocator = std.testing.allocator;
    
    // Run smaller benchmark for testing
    const test_config = MemoryBenchmarkConfig{
        .iterations = 100,
        .warmup_iterations = 10,
    };
    
    // Test that benchmarks execute without errors
    _ = try benchmark_mload_opcode(allocator, test_config);
    _ = try benchmark_mstore_opcode(allocator, test_config);
    _ = try benchmark_calldataload_opcode(allocator, test_config);
}
