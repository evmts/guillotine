const std = @import("std");
const Operation = @import("../opcodes/operation.zig");
const ExecutionError = @import("execution_error.zig");
const Stack = @import("../stack/stack.zig");
const Frame = @import("../frame/frame.zig");
const Vm = @import("../evm.zig");
const gas_constants = @import("../constants/gas_constants.zig");
const primitives = @import("primitives");

// Compile-time verification that this file is being used
const COMPILE_TIME_LOG_VERSION = "2024_LOG_FIX_V2";

// Import Log struct from VM
const Log = Vm.Log;

// Import helper functions from error_mapping

pub fn make_log(comptime num_topics: u8) fn (usize, *Operation.Interpreter, *Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    return struct {
        pub fn log(pc: usize, interpreter: *Operation.Interpreter, state: *Operation.State) ExecutionError.Error!Operation.ExecutionResult {
            _ = pc;

            const frame = @as(*Frame, @ptrCast(@alignCast(state)));
            const vm = @as(*Vm, @ptrCast(@alignCast(interpreter)));

            // Check if we're in a static call
            if (frame.is_static) {
                @branchHint(.unlikely);
                return ExecutionError.Error.WriteProtection;
            }

            // REVM EXACT MATCH: Pop offset first, then len (revm: popn!([offset, len]))
            const offset = try frame.stack.pop();
            const size = try frame.stack.pop();

            // Early bounds checking to avoid unnecessary topic pops on invalid input
            if (offset > std.math.maxInt(usize) or size > std.math.maxInt(usize)) {
                @branchHint(.unlikely);
                return ExecutionError.Error.OutOfOffset;
            }

            // Stack-allocated topics array - zero heap allocations for LOG operations
            var topics: [4]u256 = undefined;
            // Pop N topics in reverse order (LIFO stack order) for efficient processing
            for (0..num_topics) |i| {
                topics[num_topics - 1 - i] = try frame.stack.pop();
            }

            const offset_usize = @as(usize, @intCast(offset));
            const size_usize = @as(usize, @intCast(size));

            if (size_usize == 0) {
                @branchHint(.unlikely);
                // Empty data - emit empty log without memory operations
                try vm.emit_log(frame.contract.address, topics[0..num_topics], &[_]u8{});
                return Operation.ExecutionResult{};
            }

            // Convert to usize for memory operations

            // Note: Base LOG gas (375) and topic gas (375 * N) are handled by jump table as constant_gas
            // We only need to handle dynamic costs: memory expansion and data bytes

            // 1. Calculate memory expansion gas cost
            const current_size = frame.memory.context_size();
            const new_size = offset_usize + size_usize;
            const memory_gas = gas_constants.memory_gas_cost(current_size, new_size);

            // Memory expansion gas calculated

            try frame.consume_gas(memory_gas);

            // 2. Dynamic gas for data
            const byte_cost = gas_constants.LogDataGas * size_usize;

            // Calculate dynamic gas for data

            try frame.consume_gas(byte_cost);

            // Gas consumed successfully

            // Ensure memory is available
            _ = try frame.memory.ensure_context_capacity(offset_usize + size_usize);

            // Get log data
            const data = try frame.memory.get_slice(offset_usize, size_usize);

            // Emit log with data

            // Add log
            try vm.emit_log(frame.contract.address, topics[0..num_topics], data);

            return Operation.ExecutionResult{};
        }
    }.log;
}

// Runtime dispatch version for LOG operations (used in ReleaseSmall mode)
pub fn log_n(pc: usize, interpreter: *Operation.Interpreter, state: *Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    const frame = @as(*Frame, @ptrCast(@alignCast(state)));
    const vm = @as(*Vm, @ptrCast(@alignCast(interpreter)));
    const opcode = frame.contract.code[pc];
    const num_topics = opcode - 0xa0; // LOG0 is 0xa0

    // Check if we're in a static call
    if (frame.is_static) {
        @branchHint(.unlikely);
        return ExecutionError.Error.WriteProtection;
    }

    // Pop offset and size
    const offset = try frame.stack.pop();
    const size = try frame.stack.pop();

    // Early bounds checking for better error handling
    const offset_usize = std.math.cast(usize, offset) orelse return ExecutionError.Error.InvalidOffset;
    const size_usize = std.math.cast(usize, size) orelse return ExecutionError.Error.InvalidSize;

    // Stack-allocated topics array - zero heap allocations for LOG operations
    var topics: [4]u256 = undefined;
    // Pop N topics in reverse order for efficient processing
    for (0..num_topics) |i| {
        topics[num_topics - 1 - i] = try frame.stack.pop();
    }

    if (size_usize == 0) {
        @branchHint(.unlikely);
        // Empty data - emit empty log without memory operations
        try vm.emit_log(frame.contract.address, topics[0..num_topics], &[_]u8{});
        return Operation.ExecutionResult{};
    }

    // 1. Calculate memory expansion gas cost
    const current_size = frame.memory.context_size();
    const new_size = offset_usize + size_usize;
    const memory_gas = gas_constants.memory_gas_cost(current_size, new_size);

    try frame.consume_gas(memory_gas);

    // 2. Dynamic gas for data
    const byte_cost = gas_constants.LogDataGas * size_usize;
    try frame.consume_gas(byte_cost);

    // Ensure memory is available
    _ = try frame.memory.ensure_context_capacity(offset_usize + size_usize);

    // Get log data
    const data = try frame.memory.get_slice(offset_usize, size_usize);

    // Emit the log
    try vm.emit_log(frame.contract.address, topics[0..num_topics], data);

    return Operation.ExecutionResult{};
}

// LOG operations are now generated directly in jump_table.zig using make_log()

// Test imports
const testing = std.testing;
const MemoryDatabase = @import("../state/memory_database.zig");

// Test LOG0 opcode (no topics)
test "log0_basic_functionality" {
    const allocator = std.testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    var contract = try @import("../frame/contract.zig").init(allocator, &[_]u8{0xA0}, .{ .address = primitives.Address.Address.ZERO });
    defer contract.deinit(allocator, null);

    var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.Address.ZERO, &.{});
    defer frame.deinit();

    // Set up data in memory
    const test_data = "Hello, LOG0!";
    try frame.memory.set_bytes(0, test_data);

    // Push offset and size to stack
    try frame.stack.push(0); // offset
    try frame.stack.push(test_data.len); // size

    const log_fn = make_log(0);
    const interpreter_ptr: *Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: *Operation.State = @ptrCast(&frame);
    _ = try log_fn(0, interpreter_ptr, state_ptr);

    // Verify log was emitted
    try testing.expect(vm.state.logs.items.len == 1);
    const log = vm.state.logs.items[0];
    try testing.expect(log.topics.len == 0);
    try testing.expectEqualSlices(u8, test_data, log.data);
    try testing.expect(std.meta.eql(log.address, primitives.Address.Address.ZERO));
}

test "log0_empty_data" {
    const allocator = std.testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    var contract = try @import("../frame/contract.zig").init(allocator, &[_]u8{0xA0}, .{ .address = primitives.Address.Address.ZERO });
    defer contract.deinit(allocator, null);

    var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.Address.ZERO, &.{});
    defer frame.deinit();

    // Push offset and size (0) to stack
    try frame.stack.push(0); // offset
    try frame.stack.push(0); // size (empty)

    const log_fn = make_log(0);
    const interpreter_ptr: *Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: *Operation.State = @ptrCast(&frame);
    _ = try log_fn(0, interpreter_ptr, state_ptr);

    // Verify empty log was emitted
    try testing.expect(vm.state.logs.items.len == 1);
    const log = vm.state.logs.items[0];
    try testing.expect(log.topics.len == 0);
    try testing.expect(log.data.len == 0);
    try testing.expect(std.meta.eql(log.address, primitives.Address.Address.ZERO));
}

test "log0_static_call_fails" {
    const allocator = std.testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    var contract = try @import("../frame/contract.zig").init(allocator, &[_]u8{0xA0}, .{ .address = primitives.Address.Address.ZERO });
    defer contract.deinit(allocator, null);

    var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.Address.ZERO, &.{});
    defer frame.deinit();
    
    // Set static context
    frame.is_static = true;

    // Push offset and size to stack
    try frame.stack.push(0); // offset
    try frame.stack.push(10); // size

    const log_fn = make_log(0);
    const interpreter_ptr: *Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: *Operation.State = @ptrCast(&frame);
    const result = log_fn(0, interpreter_ptr, state_ptr);

    // Verify it fails with WriteProtection error
    try testing.expectError(ExecutionError.Error.WriteProtection, result);
}

test "log0_gas_consumption" {
    const allocator = std.testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    var contract = try @import("../frame/contract.zig").init(allocator, &[_]u8{0xA0}, .{ .address = primitives.Address.Address.ZERO });
    defer contract.deinit(allocator, null);

    var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.Address.ZERO, &.{});
    defer frame.deinit();

    const initial_gas = frame.gas_remaining;
    const data_size = 100;

    // Set up test data in memory
    for (0..data_size) |i| {
        try frame.memory.set_byte(i, @intCast(i % 256));
    }

    // Push offset and size to stack
    try frame.stack.push(0); // offset
    try frame.stack.push(data_size); // size

    const log_fn = make_log(0);
    const interpreter_ptr: *Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: *Operation.State = @ptrCast(&frame);
    _ = try log_fn(0, interpreter_ptr, state_ptr);

    // Verify gas was consumed
    const gas_used = initial_gas - frame.gas_remaining;
    
    // Gas calculation: memory expansion + data cost (8 gas per byte)
    const expected_data_cost = gas_constants.LogDataGas * data_size;
    try testing.expect(gas_used >= expected_data_cost);
}

test "log0_memory_expansion" {
    const allocator = std.testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    var contract = try @import("../frame/contract.zig").init(allocator, &[_]u8{0xA0}, .{ .address = primitives.Address.Address.ZERO });
    defer contract.deinit(allocator, null);

    var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.Address.ZERO, &.{});
    defer frame.deinit();

    const offset = 1000;
    const size = 100;

    // Set up test data at high offset
    for (0..size) |i| {
        try frame.memory.set_byte(offset + i, 0xFF);
    }

    // Push offset and size to stack
    try frame.stack.push(offset);
    try frame.stack.push(size);

    const log_fn = make_log(0);
    const interpreter_ptr: *Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: *Operation.State = @ptrCast(&frame);
    _ = try log_fn(0, interpreter_ptr, state_ptr);

    // Verify memory was expanded and log contains correct data
    try testing.expect(vm.state.logs.items.len == 1);
    const log = vm.state.logs.items[0];
    try testing.expect(log.data.len == size);
    
    // All bytes should be 0xFF
    for (log.data) |byte| {
        try testing.expect(byte == 0xFF);
    }
}

// Test LOG1 opcode (1 topic)
test "log1_basic_functionality" {
    const allocator = std.testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    var contract = try @import("../frame/contract.zig").init(allocator, &[_]u8{0xA1}, .{ .address = primitives.Address.Address.ZERO });
    defer contract.deinit(allocator, null);

    var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.Address.ZERO, &.{});
    defer frame.deinit();

    // Set up data in memory
    const test_data = "LOG1 data";
    try frame.memory.set_bytes(0, test_data);

    // Push topic, offset and size to stack (stack is LIFO)
    try frame.stack.push(0); // offset
    try frame.stack.push(test_data.len); // size
    try frame.stack.push(0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef); // topic1

    const log_fn = make_log(1);
    const interpreter_ptr: *Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: *Operation.State = @ptrCast(&frame);
    _ = try log_fn(0, interpreter_ptr, state_ptr);

    // Verify log was emitted with 1 topic
    try testing.expect(vm.state.logs.items.len == 1);
    const log = vm.state.logs.items[0];
    try testing.expect(log.topics.len == 1);
    try testing.expect(log.topics[0] == 0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef);
    try testing.expectEqualSlices(u8, test_data, log.data);
    try testing.expect(std.meta.eql(log.address, primitives.Address.Address.ZERO));
}

test "log1_static_call_fails" {
    const allocator = std.testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    var contract = try @import("../frame/contract.zig").init(allocator, &[_]u8{0xA1}, .{ .address = primitives.Address.Address.ZERO });
    defer contract.deinit(allocator, null);

    var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.Address.ZERO, &.{});
    defer frame.deinit();
    
    // Set static context
    frame.is_static = true;

    // Push topic, offset and size to stack (stack is LIFO)
    try frame.stack.push(0); // offset
    try frame.stack.push(10); // size
    try frame.stack.push(0x1111); // topic1

    const log_fn = make_log(1);
    const interpreter_ptr: *Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: *Operation.State = @ptrCast(&frame);
    const result = log_fn(0, interpreter_ptr, state_ptr);

    // Verify it fails with WriteProtection error
    try testing.expectError(ExecutionError.Error.WriteProtection, result);
}

// Test LOG2 opcode (2 topics)
test "log2_basic_functionality" {
    const allocator = std.testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    var contract = try @import("../frame/contract.zig").init(allocator, &[_]u8{0xA2}, .{ .address = primitives.Address.Address.ZERO });
    defer contract.deinit(allocator, null);

    var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.Address.ZERO, &.{});
    defer frame.deinit();

    const test_data = "LOG2 event data";
    try frame.memory.set_bytes(0, test_data);

    // Push topics, offset and size to stack (stack is LIFO)
    try frame.stack.push(0); // offset
    try frame.stack.push(test_data.len); // size
    try frame.stack.push(0xAAAA); // topic2
    try frame.stack.push(0xBBBB); // topic1

    const log_fn = make_log(2);
    const interpreter_ptr: *Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: *Operation.State = @ptrCast(&frame);
    _ = try log_fn(0, interpreter_ptr, state_ptr);

    // Verify log was emitted with 2 topics
    try testing.expect(vm.state.logs.items.len == 1);
    const log = vm.state.logs.items[0];
    try testing.expect(log.topics.len == 2);
    try testing.expect(log.topics[0] == 0xBBBB); // First topic pushed (topic1)
    try testing.expect(log.topics[1] == 0xAAAA); // Second topic pushed (topic2)
    try testing.expectEqualSlices(u8, test_data, log.data);
}

// Test LOG3 opcode (3 topics)
test "log3_basic_functionality" {
    const allocator = std.testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    var contract = try @import("../frame/contract.zig").init(allocator, &[_]u8{0xA3}, .{ .address = primitives.Address.Address.ZERO });
    defer contract.deinit(allocator, null);

    var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.Address.ZERO, &.{});
    defer frame.deinit();

    const test_data = "LOG3 data with 3 topics";
    try frame.memory.set_bytes(0, test_data);

    // Push topics, offset and size to stack (stack is LIFO)
    try frame.stack.push(0); // offset
    try frame.stack.push(test_data.len); // size
    try frame.stack.push(0xCCCC); // topic3
    try frame.stack.push(0xDDDD); // topic2
    try frame.stack.push(0xEEEE); // topic1

    const log_fn = make_log(3);
    const interpreter_ptr: *Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: *Operation.State = @ptrCast(&frame);
    _ = try log_fn(0, interpreter_ptr, state_ptr);

    // Verify log was emitted with 3 topics
    try testing.expect(vm.state.logs.items.len == 1);
    const log = vm.state.logs.items[0];
    try testing.expect(log.topics.len == 3);
    try testing.expect(log.topics[0] == 0xEEEE); // First topic pushed (topic1)
    try testing.expect(log.topics[1] == 0xDDDD); // Second topic pushed (topic2)
    try testing.expect(log.topics[2] == 0xCCCC); // Third topic pushed (topic3)
    try testing.expectEqualSlices(u8, test_data, log.data);
}

// Test LOG4 opcode (4 topics - maximum)
test "log4_basic_functionality" {
    const allocator = std.testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    var contract = try @import("../frame/contract.zig").init(allocator, &[_]u8{0xA4}, .{ .address = primitives.Address.Address.ZERO });
    defer contract.deinit(allocator, null);

    var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.Address.ZERO, &.{});
    defer frame.deinit();

    const test_data = "LOG4 maximum topics test";
    try frame.memory.set_bytes(0, test_data);

    // Push topics, offset and size to stack (stack is LIFO)
    try frame.stack.push(0); // offset
    try frame.stack.push(test_data.len); // size
    try frame.stack.push(0x4444444444444444444444444444444444444444444444444444444444444444); // topic4
    try frame.stack.push(0x3333333333333333333333333333333333333333333333333333333333333333); // topic3
    try frame.stack.push(0x2222222222222222222222222222222222222222222222222222222222222222); // topic2
    try frame.stack.push(0x1111111111111111111111111111111111111111111111111111111111111111); // topic1

    const log_fn = make_log(4);
    const interpreter_ptr: *Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: *Operation.State = @ptrCast(&frame);
    _ = try log_fn(0, interpreter_ptr, state_ptr);

    // Verify log was emitted with 4 topics (maximum)
    try testing.expect(vm.state.logs.items.len == 1);
    const log = vm.state.logs.items[0];
    try testing.expect(log.topics.len == 4);
    try testing.expect(log.topics[0] == 0x1111111111111111111111111111111111111111111111111111111111111111);
    try testing.expect(log.topics[1] == 0x2222222222222222222222222222222222222222222222222222222222222222);
    try testing.expect(log.topics[2] == 0x3333333333333333333333333333333333333333333333333333333333333333);
    try testing.expect(log.topics[3] == 0x4444444444444444444444444444444444444444444444444444444444444444);
    try testing.expectEqualSlices(u8, test_data, log.data);
}

// Test edge cases and error conditions
test "log_empty_data_all_opcodes" {
    const allocator = std.testing.allocator;

    // Test all LOG opcodes with empty data
    inline for (0..5) |num_topics| {
        var memory_db = MemoryDatabase.init(allocator);
        defer memory_db.deinit();

        const db_interface = memory_db.to_database_interface();
        var vm = try Vm.init(allocator, db_interface, null, null);
        defer vm.deinit();

        const opcode = 0xA0 + num_topics;
        var contract = try @import("../frame/contract.zig").init(allocator, &[_]u8{@intCast(opcode)}, .{ .address = primitives.Address.Address.ZERO });
        defer contract.deinit(allocator, null);

        var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.Address.ZERO, &.{});
        defer frame.deinit();

        // Push offset and size (0 for empty data)
        try frame.stack.push(0); // offset
        try frame.stack.push(0); // size (empty)

        // Push required number of topics
        var i: usize = 0;
        while (i < num_topics) : (i += 1) {
            try frame.stack.push(0x1000 + i); // topics
        }

        const log_fn = make_log(@intCast(num_topics));
        const interpreter_ptr: *Operation.Interpreter = @ptrCast(&vm);
        const state_ptr: *Operation.State = @ptrCast(&frame);
        _ = try log_fn(0, interpreter_ptr, state_ptr);

        // Verify empty log was emitted with correct number of topics
        try testing.expect(vm.state.logs.items.len == 1);
        const log = vm.state.logs.items[0];
        try testing.expect(log.topics.len == num_topics);
        try testing.expect(log.data.len == 0);
    }
}

test "log_large_data_memory_expansion" {
    const allocator = std.testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    var contract = try @import("../frame/contract.zig").init(allocator, &[_]u8{0xA1}, .{ .address = primitives.Address.Address.ZERO });
    defer contract.deinit(allocator, null);

    var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.Address.ZERO, &.{});
    defer frame.deinit();

    const large_offset = 10000;
    const large_size = 5000;
    
    // Fill memory with test pattern at large offset
    for (0..large_size) |i| {
        try frame.memory.set_byte(large_offset + i, @intCast((i * 3) % 256));
    }

    // Push topic, offset and size to stack
    try frame.stack.push(large_offset); // offset
    try frame.stack.push(large_size); // size
    try frame.stack.push(0xDEADBEEF); // topic

    const initial_gas = frame.gas_remaining;
    
    const log_fn = make_log(1);
    const interpreter_ptr: *Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: *Operation.State = @ptrCast(&frame);
    _ = try log_fn(0, interpreter_ptr, state_ptr);

    // Verify gas was consumed for memory expansion and data
    const gas_used = initial_gas - frame.gas_remaining;
    const expected_data_cost = gas_constants.LogDataGas * large_size;
    try testing.expect(gas_used >= expected_data_cost);

    // Verify log contains correct data
    try testing.expect(vm.state.logs.items.len == 1);
    const log = vm.state.logs.items[0];
    try testing.expect(log.topics.len == 1);
    try testing.expect(log.topics[0] == 0xDEADBEEF);
    try testing.expect(log.data.len == large_size);
    
    // Verify data pattern is correct
    for (0..large_size) |i| {
        const expected_byte: u8 = @intCast((i * 3) % 256);
        try testing.expect(log.data[i] == expected_byte);
    }
}

test "log_gas_calculation_precision" {
    const allocator = std.testing.allocator;

    // Test various data sizes to verify precise gas calculation
    const test_sizes = [_]usize{ 1, 32, 100, 1000, 2048 };
    
    for (test_sizes) |data_size| {
        var memory_db = MemoryDatabase.init(allocator);
        defer memory_db.deinit();

        const db_interface = memory_db.to_database_interface();
        var vm = try Vm.init(allocator, db_interface, null, null);
        defer vm.deinit();

        var contract = try @import("../frame/contract.zig").init(allocator, &[_]u8{0xA2}, .{ .address = primitives.Address.Address.ZERO });
        defer contract.deinit(allocator, null);

        var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.Address.ZERO, &.{});
        defer frame.deinit();

        // Set up memory with test data
        for (0..data_size) |i| {
            try frame.memory.set_byte(i, 0xAB);
        }

        const initial_gas = frame.gas_remaining;
        const initial_memory_size = frame.memory.context_size();

        // Push topics, offset and size to stack
        try frame.stack.push(0); // offset
        try frame.stack.push(data_size); // size
        try frame.stack.push(0x1111); // topic2
        try frame.stack.push(0x2222); // topic1

        const log_fn = make_log(2);
        const interpreter_ptr: *Operation.Interpreter = @ptrCast(&vm);
        const state_ptr: *Operation.State = @ptrCast(&frame);
        _ = try log_fn(0, interpreter_ptr, state_ptr);

        const gas_used = initial_gas - frame.gas_remaining;
        
        // Calculate expected gas costs
        const data_gas = gas_constants.LogDataGas * data_size;
        const memory_expansion_gas = gas_constants.memory_gas_cost(initial_memory_size, data_size);
        const min_expected_gas = data_gas + memory_expansion_gas;
        
        try testing.expect(gas_used >= min_expected_gas);
        
        // Verify log was created correctly
        try testing.expect(vm.state.logs.items.len == 1);
        const log = vm.state.logs.items[0];
        try testing.expect(log.data.len == data_size);
        try testing.expect(log.topics.len == 2);
    }
}

test "log_bounds_checking" {
    const allocator = std.testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    var contract = try @import("../frame/contract.zig").init(allocator, &[_]u8{0xA0}, .{ .address = primitives.Address.Address.ZERO });
    defer contract.deinit(allocator, null);

    var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.Address.ZERO, &.{});
    defer frame.deinit();

    // Test with very large offset that exceeds usize
    try frame.stack.push(std.math.maxInt(u256)); // extremely large offset
    try frame.stack.push(100); // size

    const log_fn = make_log(0);
    const interpreter_ptr: *Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: *Operation.State = @ptrCast(&frame);
    const result = log_fn(0, interpreter_ptr, state_ptr);

    // Should fail with OutOfOffset error
    try testing.expectError(ExecutionError.Error.OutOfOffset, result);
}

test "log_multiple_logs_same_transaction" {
    const allocator = std.testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    var contract = try @import("../frame/contract.zig").init(allocator, &[_]u8{0xA1}, .{ .address = primitives.Address.Address.ZERO });
    defer contract.deinit(allocator, null);

    var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.Address.ZERO, &.{});
    defer frame.deinit();

    // Emit multiple logs in the same transaction
    for (0..3) |i| {
        const test_data = "Log entry number ";
        try frame.memory.set_bytes(0, test_data);

        try frame.stack.push(0); // offset
        try frame.stack.push(test_data.len); // size
        try frame.stack.push(0x1000 + i); // unique topic per log

        const log_fn = make_log(1);
        const interpreter_ptr: *Operation.Interpreter = @ptrCast(&vm);
        const state_ptr: *Operation.State = @ptrCast(&frame);
        _ = try log_fn(0, interpreter_ptr, state_ptr);
    }

    // Verify all logs were emitted
    try testing.expect(vm.state.logs.items.len == 3);
    
    for (0..3) |i| {
        const log = vm.state.logs.items[i];
        try testing.expect(log.topics.len == 1);
        try testing.expect(log.topics[0] == 0x1000 + i);
        try testing.expectEqualSlices(u8, "Log entry number ", log.data);
    }
}

test "log_runtime_dispatch_log_n" {
    const allocator = std.testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    // Test the runtime dispatch version (log_n function)
    const opcodes = [_]u8{ 0xA0, 0xA1, 0xA2, 0xA3, 0xA4 }; // LOG0 through LOG4

    for (opcodes, 0..) |opcode, expected_topics| {
        var contract = try @import("../frame/contract.zig").init(allocator, &[_]u8{opcode}, .{ .address = primitives.Address.Address.ZERO });
        defer contract.deinit(allocator, null);

        var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.Address.ZERO, &.{});
        defer frame.deinit();

        const test_data = "Runtime dispatch test";
        try frame.memory.set_bytes(0, test_data);

        // Push offset and size
        try frame.stack.push(0); // offset
        try frame.stack.push(test_data.len); // size

        // Push required topics
        for (0..expected_topics) |i| {
            try frame.stack.push(0x5000 + i);
        }

        const interpreter_ptr: *Operation.Interpreter = @ptrCast(&vm);
        const state_ptr: *Operation.State = @ptrCast(&frame);
        _ = try log_n(0, interpreter_ptr, state_ptr);

        // Verify log was created with correct number of topics
        const log_index = vm.state.logs.items.len - 1;
        const log = vm.state.logs.items[log_index];
        try testing.expect(log.topics.len == expected_topics);
        try testing.expectEqualSlices(u8, test_data, log.data);

        // Verify topic values are correct
        for (0..expected_topics) |i| {
            try testing.expect(log.topics[i] == 0x5000 + (expected_topics - 1 - i));
        }
    }
}
