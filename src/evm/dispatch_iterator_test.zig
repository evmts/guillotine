const std = @import("std");
const testing = std.testing;
const bytecode_mod = @import("bytecode.zig");
const Opcode = @import("opcode_data.zig").Opcode;
const dispatch_iterator = @import("dispatch_iterator.zig");
const dispatch_utils = @import("dispatch_utils.zig");

// Test frame type for testing
const TestFrame = struct {
    pub const WordType = u256;
    pub const PcType = u32;
    pub const BytecodeConfig = @import("bytecode_config.zig").BytecodeConfig{
        .max_bytecode_size = 1024,
        .max_initcode_size = 49152,
    };
};

// Mock dispatch Item for testing  
const MockItem = union {
    opcode_handler: *const fn () void,
    push_inline: struct { value: u64 },
    push_pointer: struct { value: *const u256 },
    jump_dest: struct { gas: u64 },
    pc: struct { value: u32 },
    first_block_gas: struct { gas: u64 },
};

test "ScheduleIterator - init with empty schedule" {
    const allocator = testing.allocator;
    
    const Bytecode = bytecode_mod.Bytecode(TestFrame.BytecodeConfig);
    var bytecode = try Bytecode.init(allocator, &[_]u8{});
    defer bytecode.deinit();

    const schedule: []const MockItem = &.{};
    
    const ScheduleIterator = dispatch_iterator.ScheduleIterator(TestFrame);
    var iter = ScheduleIterator.init(schedule, &bytecode);
    
    try testing.expect(iter.schedule.len == 0);
    try testing.expect(iter.pc == 0);
    try testing.expect(iter.schedule_index == 0);
}

test "ScheduleIterator - next() with empty schedule returns null" {
    const allocator = testing.allocator;
    
    const Bytecode = bytecode_mod.Bytecode(TestFrame.BytecodeConfig);
    var bytecode = try Bytecode.init(allocator, &[_]u8{});
    defer bytecode.deinit();

    const schedule: []const MockItem = &.{};
    
    const ScheduleIterator = dispatch_iterator.ScheduleIterator(TestFrame);
    var iter = ScheduleIterator.init(schedule, &bytecode);
    
    const entry = iter.next();
    try testing.expect(entry == null);
}

test "ScheduleIterator - handles first_block_gas skipping" {
    const allocator = testing.allocator;
    
    // Create bytecode that will generate first_block_gas > 0
    const Bytecode = bytecode_mod.Bytecode(TestFrame.BytecodeConfig);
    var bytecode = try Bytecode.init(allocator, &[_]u8{ @intFromEnum(Opcode.PUSH1), 42 });
    defer bytecode.deinit();

    const mock_handler = &struct {
        fn handler() void {}
    }.handler;
    
    // Schedule with first_block_gas entry
    const schedule = [_]MockItem{
        .{ .first_block_gas = .{ .gas = 3 } }, // First block gas 
        .{ .opcode_handler = mock_handler }, // PUSH1 handler
        .{ .push_inline = .{ .value = 42 } }, // PUSH1 value
    };
    
    const ScheduleIterator = dispatch_iterator.ScheduleIterator(TestFrame);
    var iter = ScheduleIterator.init(&schedule, &bytecode);
    
    // Should skip first_block_gas and start with actual opcodes
    const entry = iter.next();
    try testing.expect(entry != null);
    try testing.expect(entry.?.pc == 0);
    try testing.expect(entry.?.schedule_index == 1); // Skipped first_block_gas at index 0
}

test "ScheduleIterator - PC advancement logic" {
    const allocator = testing.allocator;
    
    const Bytecode = bytecode_mod.Bytecode(TestFrame.BytecodeConfig);
    var bytecode = try Bytecode.init(allocator, &[_]u8{
        @intFromEnum(Opcode.PUSH1), 10, // PC 0-1
        @intFromEnum(Opcode.ADD),       // PC 2
    });
    defer bytecode.deinit();

    const mock_handler = &struct {
        fn handler() void {}
    }.handler;
    
    const schedule = [_]MockItem{
        .{ .opcode_handler = mock_handler }, // PUSH1 handler
        .{ .push_inline = .{ .value = 10 } }, // PUSH1 value
        .{ .opcode_handler = mock_handler }, // ADD handler
    };
    
    const ScheduleIterator = dispatch_iterator.ScheduleIterator(TestFrame);
    var iter = ScheduleIterator.init(&schedule, &bytecode);
    
    // First entry - PUSH1
    const entry1 = iter.next();
    try testing.expect(entry1 != null);
    try testing.expect(entry1.?.pc == 0);
    try testing.expect(entry1.?.schedule_index == 0);
    
    // Second entry - ADD
    const entry2 = iter.next();  
    try testing.expect(entry2 != null);
    try testing.expect(entry2.?.pc == 1); // PC should advance
    try testing.expect(entry2.?.schedule_index == 2); // Should skip metadata
}

test "ScheduleIterator - Entry type detection accuracy" {
    const allocator = testing.allocator;
    
    const Bytecode = bytecode_mod.Bytecode(TestFrame.BytecodeConfig);
    var bytecode = try Bytecode.init(allocator, &[_]u8{
        @intFromEnum(Opcode.JUMPDEST),
    });
    defer bytecode.deinit();

    const mock_handler = &struct {
        fn handler() void {}
    }.handler;
    
    const schedule = [_]MockItem{
        .{ .opcode_handler = mock_handler }, // JUMPDEST handler
        .{ .jump_dest = .{ .gas = 1 } }, // JUMPDEST metadata
    };
    
    const ScheduleIterator = dispatch_iterator.ScheduleIterator(TestFrame);
    var iter = ScheduleIterator.init(&schedule, &bytecode);
    
    const entry = iter.next();
    try testing.expect(entry != null);
    try testing.expect(entry.?.op_data == .regular); // Currently simplified - all handlers are regular
}

test "ScheduleIterator - metadata advancement" {
    const allocator = testing.allocator;
    
    const Bytecode = bytecode_mod.Bytecode(TestFrame.BytecodeConfig);
    var bytecode = try Bytecode.init(allocator, &[_]u8{
        @intFromEnum(Opcode.PUSH1), 10,
        @intFromEnum(Opcode.PC),
        @intFromEnum(Opcode.JUMPDEST),
    });
    defer bytecode.deinit();

    const mock_handler = &struct {
        fn handler() void {}
    }.handler;
    
    const schedule = [_]MockItem{
        .{ .opcode_handler = mock_handler }, // PUSH1 handler
        .{ .push_inline = .{ .value = 10 } }, // PUSH1 metadata
        .{ .opcode_handler = mock_handler }, // PC handler  
        .{ .pc = .{ .value = 2 } }, // PC metadata
        .{ .opcode_handler = mock_handler }, // JUMPDEST handler
        .{ .jump_dest = .{ .gas = 1 } }, // JUMPDEST metadata
    };
    
    const ScheduleIterator = dispatch_iterator.ScheduleIterator(TestFrame);
    var iter = ScheduleIterator.init(&schedule, &bytecode);
    
    // Should advance properly through handlers and skip metadata
    var entry_count: usize = 0;
    var schedule_indices = std.ArrayList(usize){};
    defer schedule_indices.deinit(allocator);
    
    while (iter.next()) |entry| {
        entry_count += 1;
        try schedule_indices.append(allocator, entry.schedule_index);
    }
    
    try testing.expect(entry_count == 3); // 3 handlers
    try testing.expect(schedule_indices.items[0] == 0); // PUSH1 handler at 0
    try testing.expect(schedule_indices.items[1] == 2); // PC handler at 2
    try testing.expect(schedule_indices.items[2] == 4); // JUMPDEST handler at 4
}