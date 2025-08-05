const std = @import("std");
const Operation = @import("../opcodes/operation.zig");
const ExecutionError = @import("execution_error.zig");
const Stack = @import("../stack/stack.zig");
const Evm = @import("../evm.zig");
const Frame = @import("../frame/frame_fat.zig");
const GasConstants = @import("primitives").GasConstants;
const primitives = @import("primitives");

// Compile-time verification that this file is being used
const COMPILE_TIME_LOG_VERSION = "2024_LOG_FIX_V2";

// Import Log struct from VM
const Log = Evm.Log;

// Import helper functions from error_mapping

pub fn make_log(comptime num_topics: u8) fn (*Evm, *Frame) ExecutionError.Error!Operation.ExecutionResult {
    return struct {
        pub fn log(vm: *Evm, frame: *Frame) ExecutionError.Error!Operation.ExecutionResult {

            // Check if we're in a static call
            if (frame.is_static) {
                @branchHint(.unlikely);
                return ExecutionError.Error.WriteProtection;
            }

            // REVM EXACT MATCH: Pop offset first, then len (revm: popn!([offset, len]))
            const offset = try frame.stack_pop();
            const size = try frame.stack_pop();

            // Early bounds checking to avoid unnecessary topic pops on invalid input
            if (offset > std.math.maxInt(usize) or size > std.math.maxInt(usize)) {
                @branchHint(.unlikely);
                return ExecutionError.Error.OutOfOffset;
            }

            // Stack-allocated topics array - zero heap allocations for LOG operations
            var topics: [4]u256 = undefined;
            // Pop N topics in reverse order (LIFO stack order) for efficient processing
            for (0..num_topics) |i| {
                topics[num_topics - 1 - i] = try frame.stack_pop();
            }

            const offset_usize = @as(usize, @intCast(offset));
            const size_usize = @as(usize, @intCast(size));

            if (size_usize == 0) {
                @branchHint(.unlikely);
                // Empty data - emit empty log without memory operations
                try vm.emit_log(frame.address, topics[0..num_topics], &[_]u8{});
                return Operation.ExecutionResult{};
            }

            // Convert to usize for memory operations

            // Note: Base LOG gas (375) and topic gas (375 * N) are handled by jump table as constant_gas
            // We only need to handle dynamic costs: memory expansion and data bytes

            // 1. Calculate memory expansion gas cost
            const new_size = offset_usize + size_usize;
            const memory_gas = frame.memory_get_expansion_cost(@as(u64, @intCast(new_size)));

            // Memory expansion gas calculated

            try frame.consume_gas(memory_gas);

            // 2. Dynamic gas for data
            const byte_cost = GasConstants.LogDataGas * size_usize;

            // Calculate dynamic gas for data

            try frame.consume_gas(byte_cost);

            // Gas consumed successfully

            // Ensure memory is available
            frame.memory_ensure_capacity(offset_usize + size_usize) catch |err| switch (err) {
                error.OutOfGas => return error.OutOfGas,
                error.AllocationError => return error.OutOfMemory,
                error.Overflow => return error.OutOfMemory,
                error.OutOfMemory => return error.OutOfMemory,
            };

            // Get log data
            const data = frame.memory_get_slice(@intCast(offset_usize), @intCast(size_usize));

            // Emit log with data

            // Add log
            try vm.emit_log(frame.address, topics[0..num_topics], data);

            return Operation.ExecutionResult{};
        }
    }.log;
}

// Runtime dispatch versions for LOG operations (used in ReleaseSmall mode)
// Each LOG operation gets its own function to avoid opcode detection issues

pub fn log_0(vm: *Evm, frame: *Frame) ExecutionError.Error!Operation.ExecutionResult {
    return log_impl(0, vm, frame);
}

pub fn log_1(vm: *Evm, frame: *Frame) ExecutionError.Error!Operation.ExecutionResult {
    return log_impl(1, vm, frame);
}

pub fn log_2(vm: *Evm, frame: *Frame) ExecutionError.Error!Operation.ExecutionResult {
    return log_impl(2, vm, frame);
}

pub fn log_3(vm: *Evm, frame: *Frame) ExecutionError.Error!Operation.ExecutionResult {
    return log_impl(3, vm, frame);
}

pub fn log_4(vm: *Evm, frame: *Frame) ExecutionError.Error!Operation.ExecutionResult {
    return log_impl(4, vm, frame);
}

// Common implementation for all LOG operations
fn log_impl(num_topics: u8, vm: *Evm, frame: *Frame) ExecutionError.Error!Operation.ExecutionResult {
    
    // Check if we're in a static call
    if (frame.is_static) {
        @branchHint(.unlikely);
        return ExecutionError.Error.WriteProtection;
    }

    // Pop offset and size
    const offset = try frame.stack_pop();
    const size = try frame.stack_pop();

    // Early bounds checking for better error handling
    const offset_usize = std.math.cast(usize, offset) orelse return ExecutionError.Error.InvalidOffset;
    const size_usize = std.math.cast(usize, size) orelse return ExecutionError.Error.InvalidSize;

    // Stack-allocated topics array - zero heap allocations for LOG operations
    var topics: [4]u256 = undefined;
    // Pop N topics in reverse order for efficient processing
    for (0..num_topics) |i| {
        topics[num_topics - 1 - i] = try frame.stack_pop();
    }

    if (size_usize == 0) {
        @branchHint(.unlikely);
        // Empty data - emit empty log without memory operations
        try vm.emit_log(frame.address, topics[0..num_topics], &[_]u8{});
        return Operation.ExecutionResult{};
    }

    // 1. Calculate memory expansion gas cost
    const new_size = offset_usize + size_usize;
    const memory_gas = frame.memory_get_expansion_cost(@as(u64, @intCast(new_size)));

    try frame.consume_gas(memory_gas);

    // 2. Dynamic gas for data
    const byte_cost = GasConstants.LogDataGas * size_usize;
    try frame.consume_gas(byte_cost);

    // Ensure memory is available
    _ = try frame.memory.ensure_context_capacity(offset_usize + size_usize);

    // Get log data
    const data = try frame.memory_get_slice(offset_usize, size_usize);

    // Emit the log
    try vm.emit_log(frame.address, topics[0..num_topics], data);

    return Operation.ExecutionResult{};
}

// LOG operations are now generated directly in jump_table.zig using make_log()

// =============================================================================
// TESTS
// =============================================================================

const testing = std.testing;
const MemoryDatabase = @import("../state/memory_database.zig");
const Address = primitives.Address.Address;

test "LOG0 emits correct number of topics" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null);
    defer vm.deinit();
    
    var contract = try @import("../frame/contract.zig").init(allocator, &[_]u8{0xa0}, .{ .address = Address.ZERO });
    defer contract.deinit(allocator, null);
    
    var frame = try Frame.init(allocator, &vm, 1000000, contract, Address.ZERO, &.{});
    defer frame.deinit();
    
    const log_data = "Hello LOG0";
    try frame.memory.set_data(0, log_data);
    try frame.stack_push(0); // offset
    try frame.stack_push(log_data.len); // size
    
    const log0_fn = make_log(0);
    const result = try log0_fn(0, @ptrCast(&vm), @ptrCast(&frame));
    
    try testing.expect(result.exit_code == null);
    try testing.expectEqual(@as(usize, 1), vm.state.logs.items.len);
    try testing.expectEqual(@as(usize, 0), vm.state.logs.items[0].topics.len);
    try testing.expectEqualSlices(u8, log_data, vm.state.logs.items[0].data);
    try testing.expectEqual(Address.ZERO, vm.state.logs.items[0].address);
}

test "LOG1 emits correct number of topics" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null);
    defer vm.deinit();
    
    var contract = try @import("../frame/contract.zig").init(allocator, &[_]u8{0xa1}, .{ .address = Address.ZERO });
    defer contract.deinit(allocator, null);
    
    var frame = try Frame.init(allocator, &vm, 1000000, contract, Address.ZERO, &.{});
    defer frame.deinit();
    
    const log_data = "Hello LOG1";
    const topic1: u256 = 0x1111111111111111111111111111111111111111111111111111111111111111;
    
    try frame.memory.set_data(0, log_data);
    try frame.stack_push(0); // offset
    try frame.stack_push(log_data.len); // size
    try frame.stack_push(topic1); // topic0
    
    const log1_fn = make_log(1);
    const result = try log1_fn(0, @ptrCast(&vm), @ptrCast(&frame));
    
    try testing.expect(result.exit_code == null);
    try testing.expectEqual(@as(usize, 1), vm.state.logs.items.len);
    try testing.expectEqual(@as(usize, 1), vm.state.logs.items[0].topics.len);
    try testing.expectEqual(topic1, vm.state.logs.items[0].topics[0]);
    try testing.expectEqualSlices(u8, log_data, vm.state.logs.items[0].data);
}

test "LOG2 emits correct number of topics" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null);
    defer vm.deinit();
    
    var contract = try @import("../frame/contract.zig").init(allocator, &[_]u8{0xa2}, .{ .address = Address.ZERO });
    defer contract.deinit(allocator, null);
    
    var frame = try Frame.init(allocator, &vm, 1000000, contract, Address.ZERO, &.{});
    defer frame.deinit();
    
    const log_data = "Hello LOG2";
    const topic1: u256 = 0x1111111111111111111111111111111111111111111111111111111111111111;
    const topic2: u256 = 0x2222222222222222222222222222222222222222222222222222222222222222;
    
    try frame.memory.set_data(0, log_data);
    try frame.stack_push(0); // offset
    try frame.stack_push(log_data.len); // size
    try frame.stack_push(topic1); // topic0
    try frame.stack_push(topic2); // topic1
    
    const log2_fn = make_log(2);
    const result = try log2_fn(0, @ptrCast(&vm), @ptrCast(&frame));
    
    try testing.expect(result.exit_code == null);
    try testing.expectEqual(@as(usize, 1), vm.state.logs.items.len);
    try testing.expectEqual(@as(usize, 2), vm.state.logs.items[0].topics.len);
    try testing.expectEqual(topic1, vm.state.logs.items[0].topics[0]);
    try testing.expectEqual(topic2, vm.state.logs.items[0].topics[1]);
    try testing.expectEqualSlices(u8, log_data, vm.state.logs.items[0].data);
}

test "LOG3 emits correct number of topics" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null);
    defer vm.deinit();
    
    var contract = try @import("../frame/contract.zig").init(allocator, &[_]u8{0xa3}, .{ .address = Address.ZERO });
    defer contract.deinit(allocator, null);
    
    var frame = try Frame.init(allocator, &vm, 1000000, contract, Address.ZERO, &.{});
    defer frame.deinit();
    
    const log_data = "Hello LOG3";
    const topic1: u256 = 0x1111111111111111111111111111111111111111111111111111111111111111;
    const topic2: u256 = 0x2222222222222222222222222222222222222222222222222222222222222222;
    const topic3: u256 = 0x3333333333333333333333333333333333333333333333333333333333333333;
    
    try frame.memory.set_data(0, log_data);
    try frame.stack_push(0); // offset
    try frame.stack_push(log_data.len); // size
    try frame.stack_push(topic1); // topic0
    try frame.stack_push(topic2); // topic1
    try frame.stack_push(topic3); // topic2
    
    const log3_fn = make_log(3);
    const result = try log3_fn(0, @ptrCast(&vm), @ptrCast(&frame));
    
    try testing.expect(result.exit_code == null);
    try testing.expectEqual(@as(usize, 1), vm.state.logs.items.len);
    try testing.expectEqual(@as(usize, 3), vm.state.logs.items[0].topics.len);
    try testing.expectEqual(topic1, vm.state.logs.items[0].topics[0]);
    try testing.expectEqual(topic2, vm.state.logs.items[0].topics[1]);
    try testing.expectEqual(topic3, vm.state.logs.items[0].topics[2]);
    try testing.expectEqualSlices(u8, log_data, vm.state.logs.items[0].data);
}

test "LOG4 emits correct number of topics" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null);
    defer vm.deinit();
    
    var contract = try @import("../frame/contract.zig").init(allocator, &[_]u8{0xa4}, .{ .address = Address.ZERO });
    defer contract.deinit(allocator, null);
    
    var frame = try Frame.init(allocator, &vm, 1000000, contract, Address.ZERO, &.{});
    defer frame.deinit();
    
    const log_data = "Hello LOG4";
    const topic1: u256 = 0x1111111111111111111111111111111111111111111111111111111111111111;
    const topic2: u256 = 0x2222222222222222222222222222222222222222222222222222222222222222;
    const topic3: u256 = 0x3333333333333333333333333333333333333333333333333333333333333333;
    const topic4: u256 = 0x4444444444444444444444444444444444444444444444444444444444444444;
    
    try frame.memory.set_data(0, log_data);
    try frame.stack_push(0); // offset
    try frame.stack_push(log_data.len); // size
    try frame.stack_push(topic1); // topic0
    try frame.stack_push(topic2); // topic1
    try frame.stack_push(topic3); // topic2
    try frame.stack_push(topic4); // topic3
    
    const log4_fn = make_log(4);
    const result = try log4_fn(0, @ptrCast(&vm), @ptrCast(&frame));
    
    try testing.expect(result.exit_code == null);
    try testing.expectEqual(@as(usize, 1), vm.state.logs.items.len);
    try testing.expectEqual(@as(usize, 4), vm.state.logs.items[0].topics.len);
    try testing.expectEqual(topic1, vm.state.logs.items[0].topics[0]);
    try testing.expectEqual(topic2, vm.state.logs.items[0].topics[1]);
    try testing.expectEqual(topic3, vm.state.logs.items[0].topics[2]);
    try testing.expectEqual(topic4, vm.state.logs.items[0].topics[3]);
    try testing.expectEqualSlices(u8, log_data, vm.state.logs.items[0].data);
}

test "LOG operations with zero-length data" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null);
    defer vm.deinit();
    
    var contract = try @import("../frame/contract.zig").init(allocator, &[_]u8{0xa0}, .{ .address = Address.ZERO });
    defer contract.deinit(allocator, null);
    
    var frame = try Frame.init(allocator, &vm, 1000000, contract, Address.ZERO, &.{});
    defer frame.deinit();
    
    try frame.stack_push(0); // offset
    try frame.stack_push(0); // size (zero length)
    
    const log0_fn = make_log(0);
    const result = try log0_fn(0, @ptrCast(&vm), @ptrCast(&frame));
    
    try testing.expect(result.exit_code == null);
    try testing.expectEqual(@as(usize, 1), vm.state.logs.items.len);
    try testing.expectEqual(@as(usize, 0), vm.state.logs.items[0].topics.len);
    try testing.expectEqual(@as(usize, 0), vm.state.logs.items[0].data.len);
}

test "LOG operations with large data sizes" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null);
    defer vm.deinit();
    
    var contract = try @import("../frame/contract.zig").init(allocator, &[_]u8{0xa0}, .{ .address = Address.ZERO });
    defer contract.deinit(allocator, null);
    
    var frame = try Frame.init(allocator, &vm, 1000000, contract, Address.ZERO, &.{});
    defer frame.deinit();
    
    // Create large data array (1KB)
    const large_data = try allocator.alloc(u8, 1024);
    defer allocator.free(large_data);
    
    for (large_data, 0..) |*byte, i| {
        byte.* = @intCast(i % 256);
    }
    
    try frame.memory.set_data(0, large_data);
    try frame.stack_push(0); // offset
    try frame.stack_push(large_data.len); // size
    
    const log0_fn = make_log(0);
    const result = try log0_fn(0, @ptrCast(&vm), @ptrCast(&frame));
    
    try testing.expect(result.exit_code == null);
    try testing.expectEqual(@as(usize, 1), vm.state.logs.items.len);
    try testing.expectEqual(@as(usize, 0), vm.state.logs.items[0].topics.len);
    try testing.expectEqual(large_data.len, vm.state.logs.items[0].data.len);
    try testing.expectEqualSlices(u8, large_data, vm.state.logs.items[0].data);
}

test "LOG operations fail in static call context" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null);
    defer vm.deinit();
    
    var contract = try @import("../frame/contract.zig").init(allocator, &[_]u8{0xa0}, .{ .address = Address.ZERO });
    defer contract.deinit(allocator, null);
    
    var frame = try Frame.init(allocator, &vm, 1000000, contract, Address.ZERO, &.{});
    defer frame.deinit();
    
    frame.is_static = true; // Set static context
    
    const log_data = "Should fail";
    try frame.memory.set_data(0, log_data);
    try frame.stack_push(0); // offset
    try frame.stack_push(log_data.len); // size
    
    const log0_fn = make_log(0);
    const result = log0_fn(0, @ptrCast(&vm), @ptrCast(&frame));
    
    try testing.expectError(ExecutionError.Error.WriteProtection, result);
    try testing.expectEqual(@as(usize, 0), vm.state.logs.items.len);
}

test "LOG operations with memory offset beyond bounds" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null);
    defer vm.deinit();
    
    var contract = try @import("../frame/contract.zig").init(allocator, &[_]u8{0xa0}, .{ .address = Address.ZERO });
    defer contract.deinit(allocator, null);
    
    var frame = try Frame.init(allocator, &vm, 1000000, contract, Address.ZERO, &.{});
    defer frame.deinit();
    
    const large_offset: u256 = std.math.maxInt(usize) + 1;
    try frame.stack_push(large_offset); // Invalid offset
    try frame.stack_push(100); // size
    
    const log0_fn = make_log(0);
    const result = log0_fn(0, @ptrCast(&vm), @ptrCast(&frame));
    
    try testing.expectError(ExecutionError.Error.OutOfOffset, result);
}

test "LOG operations trigger memory expansion" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null);
    defer vm.deinit();
    
    var contract = try @import("../frame/contract.zig").init(allocator, &[_]u8{0xa0}, .{ .address = Address.ZERO });
    defer contract.deinit(allocator, null);
    
    var frame = try Frame.init(allocator, &vm, 1000000, contract, Address.ZERO, &.{});
    defer frame.deinit();
    
    const initial_memory_size = frame.memory.context_size();
    const offset: u256 = 1000;
    const size: u256 = 100;
    
    // Set data beyond current memory size
    const test_data = "Memory expansion test";
    try frame.memory.set_data(@intCast(offset), test_data);
    
    try frame.stack_push(offset);
    try frame.stack_push(size);
    
    const log0_fn = make_log(0);
    const result = try log0_fn(0, @ptrCast(&vm), @ptrCast(&frame));
    
    try testing.expect(result.exit_code == null);
    try testing.expect(frame.memory.context_size() > initial_memory_size);
    try testing.expectEqual(@as(usize, 1), vm.state.logs.items.len);
}

test "LOG address is correctly recorded" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null);
    defer vm.deinit();
    
    const test_address = Address{ .inner = [_]u8{0x12} ++ [_]u8{0x34} ** 19 };
    var contract = try @import("../frame/contract.zig").init(allocator, &[_]u8{0xa0}, .{ .address = test_address });
    defer contract.deinit(allocator, null);
    
    var frame = try Frame.init(allocator, &vm, 1000000, contract, Address.ZERO, &.{});
    defer frame.deinit();
    
    const log_data = "Address test";
    try frame.memory.set_data(0, log_data);
    try frame.stack_push(0); // offset
    try frame.stack_push(log_data.len); // size
    
    const log0_fn = make_log(0);
    const result = try log0_fn(0, @ptrCast(&vm), @ptrCast(&frame));
    
    try testing.expect(result.exit_code == null);
    try testing.expectEqual(@as(usize, 1), vm.state.logs.items.len);
    try testing.expectEqual(test_address, vm.state.logs.items[0].address);
}

test "Multiple LOG operations in sequence" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null);
    defer vm.deinit();
    
    var contract = try @import("../frame/contract.zig").init(allocator, &[_]u8{0xa0}, .{ .address = Address.ZERO });
    defer contract.deinit(allocator, null);
    
    var frame = try Frame.init(allocator, &vm, 1000000, contract, Address.ZERO, &.{});
    defer frame.deinit();
    
    // First LOG0
    const log_data1 = "First log";
    try frame.memory.set_data(0, log_data1);
    try frame.stack_push(0);
    try frame.stack_push(log_data1.len);
    
    const log0_fn = make_log(0);
    _ = try log0_fn(0, @ptrCast(&vm), @ptrCast(&frame));
    
    // Second LOG1 
    const log_data2 = "Second log";
    const topic: u256 = 0xabcdef;
    try frame.memory.set_data(50, log_data2);
    try frame.stack_push(50);
    try frame.stack_push(log_data2.len);
    try frame.stack_push(topic);
    
    const log1_fn = make_log(1);
    _ = try log1_fn(0, @ptrCast(&vm), @ptrCast(&frame));
    
    try testing.expectEqual(@as(usize, 2), vm.state.logs.items.len);
    try testing.expectEqual(@as(usize, 0), vm.state.logs.items[0].topics.len);
    try testing.expectEqual(@as(usize, 1), vm.state.logs.items[1].topics.len);
    try testing.expectEqual(topic, vm.state.logs.items[1].topics[0]);
}

test "log_2 runtime dispatch function" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null);
    defer vm.deinit();
    
    // Test LOG2 using runtime dispatch (opcode 0xa2)
    var contract = try @import("../frame/contract.zig").init(allocator, &[_]u8{0xa2}, .{ .address = Address.ZERO });
    defer contract.deinit(allocator, null);
    
    var frame = try Frame.init(allocator, &vm, 1000000, contract, Address.ZERO, &.{});
    defer frame.deinit();
    
    const log_data = "Runtime dispatch";
    const topic1: u256 = 0x1111;
    const topic2: u256 = 0x2222;
    
    try frame.memory.set_data(0, log_data);
    try frame.stack_push(0); // offset
    try frame.stack_push(log_data.len); // size
    try frame.stack_push(topic1); // topic0
    try frame.stack_push(topic2); // topic1
    
    const result = try log_2(0, @ptrCast(&vm), @ptrCast(&frame));
    
    try testing.expect(result.exit_code == null);
    try testing.expectEqual(@as(usize, 1), vm.state.logs.items.len);
    try testing.expectEqual(@as(usize, 2), vm.state.logs.items[0].topics.len);
    try testing.expectEqual(topic1, vm.state.logs.items[0].topics[0]);
    try testing.expectEqual(topic2, vm.state.logs.items[0].topics[1]);
    try testing.expectEqualSlices(u8, log_data, vm.state.logs.items[0].data);
}

const FuzzLogOperation = struct {
    num_topics: u8,
    topics: [4]u256,
    data_offset: usize,
    data_size: usize,
    data_content: []const u8,
    is_static: bool,
    expected_result: enum { success, write_protection, out_of_gas },
};

fn fuzz_log_operations(allocator: std.mem.Allocator, operations: []const FuzzLogOperation) !void {
    for (operations) |op| {
        var memory_db = MemoryDatabase.init(allocator);
        defer memory_db.deinit();
        
        const db_interface = memory_db.to_database_interface();
        var vm = try Evm.init(allocator, db_interface, null, null);
        defer vm.deinit();
        
        const opcode = 0xa0 + op.num_topics;
        var contract = try @import("../frame/contract.zig").init(allocator, &[_]u8{opcode}, .{ .address = Address.ZERO });
        defer contract.deinit(allocator, null);
        
        var frame = try Frame.init(allocator, &vm, 1000000, contract, Address.ZERO, &.{});
        defer frame.deinit();
        
        frame.is_static = op.is_static;
        
        if (op.data_content.len > 0) {
            try frame.memory.set_data(op.data_offset, op.data_content);
        }
        
        try frame.stack_push(op.data_offset);
        try frame.stack_push(op.data_size);
        
        var i: usize = 0;
        while (i < op.num_topics) : (i += 1) {
            try frame.stack_push(op.topics[i]);
        }
        
        const log_fn = make_log(op.num_topics);
        const result = log_fn(0, @ptrCast(&vm), @ptrCast(&frame));
        
        switch (op.expected_result) {
            .success => {
                _ = try result;
                try testing.expect(vm.state.logs.items.len > 0);
                const logged = vm.state.logs.items[vm.state.logs.items.len - 1];
                try testing.expectEqual(op.num_topics, logged.topics.len);
            },
            .write_protection => {
                try testing.expectError(ExecutionError.Error.WriteProtection, result);
            },
            .out_of_gas => {
                try testing.expectError(ExecutionError.Error.OutOfGas, result);
            },
        }
    }
}

test "fuzz_log_basic_operations" {
    const allocator = testing.allocator;
    
    const operations = [_]FuzzLogOperation{
        .{ .num_topics = 0, .topics = undefined, .data_offset = 0, .data_size = 10, .data_content = "0123456789", .is_static = false, .expected_result = .success },
        .{ .num_topics = 1, .topics = .{ 0x1111, undefined, undefined, undefined }, .data_offset = 0, .data_size = 5, .data_content = "Hello", .is_static = false, .expected_result = .success },
        .{ .num_topics = 4, .topics = .{ 0x1111, 0x2222, 0x3333, 0x4444 }, .data_offset = 50, .data_size = 8, .data_content = "MaxTopics", .is_static = false, .expected_result = .success },
    };
    
    try fuzz_log_operations(allocator, &operations);
}

test "fuzz_log_edge_cases" {
    const allocator = testing.allocator;
    
    const operations = [_]FuzzLogOperation{
        .{ .num_topics = 0, .topics = undefined, .data_offset = 0, .data_size = 0, .data_content = "", .is_static = false, .expected_result = .success },
        .{ .num_topics = 2, .topics = .{ 0xaaaa, 0xbbbb, undefined, undefined }, .data_offset = 0, .data_size = 5, .data_content = "Test", .is_static = true, .expected_result = .write_protection },
        .{ .num_topics = 1, .topics = .{ std.math.maxInt(u256), undefined, undefined, undefined }, .data_offset = 0, .data_size = 3, .data_content = "Max", .is_static = false, .expected_result = .success },
    };
    
    try fuzz_log_operations(allocator, &operations);
}

test "fuzz_log_random_operations" {
    const allocator = testing.allocator;
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();
    
    var operations = std.ArrayList(FuzzLogOperation).init(allocator);
    defer operations.deinit();
    
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        const num_topics = random.intRangeAtMost(u8, 0, 4);
        var topics: [4]u256 = undefined;
        
        var j: usize = 0;
        while (j < num_topics) : (j += 1) {
            topics[j] = random.int(u256);
        }
        
        const data_size = random.intRangeAtMost(usize, 0, 200);
        const data_offset = random.intRangeAtMost(usize, 0, 100);
        
        const data_content = try allocator.alloc(u8, data_size);
        defer allocator.free(data_content);
        random.bytes(data_content);
        
        const is_static = random.boolean();
        const expected_result = if (is_static) FuzzLogOperation.expected_result.write_protection else FuzzLogOperation.expected_result.success;
        
        try operations.append(.{
            .num_topics = num_topics,
            .topics = topics,
            .data_offset = data_offset,
            .data_size = data_size,
            .data_content = data_content,
            .is_static = is_static,
            .expected_result = expected_result,
        });
    }
    
    try fuzz_log_operations(allocator, operations.items);
}
