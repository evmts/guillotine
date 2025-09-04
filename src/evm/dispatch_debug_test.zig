const std = @import("std");
const testing = std.testing;
const bytecode_mod = @import("bytecode.zig");
const Opcode = @import("opcode_data.zig").Opcode;
const dispatch_debug = @import("dispatch_debug.zig");

// Test frame type for testing
const TestFrame = struct {
    pub const WordType = u256;
    pub const PcType = u32;
    pub const BytecodeConfig = @import("bytecode_config.zig").BytecodeConfig{
        .max_bytecode_size = 1024,
        .max_initcode_size = 49152,
    };
};

// Mock dispatch type for testing
const MockDispatch = struct {
    cursor: [*]const Item,
    
    pub const Item = union {
        opcode_handler: *const fn () void,
        push_inline: struct { value: u64 },
        push_pointer: struct { value: *const u256 },
        jump_dest: struct { gas: u64 },
        pc: struct { value: u32 },
        first_block_gas: struct { gas: u64 },
    };
};

test "pretty_print - basic functionality with PUSH1 ADD STOP" {
    const allocator = testing.allocator;
    
    // Create simple bytecode: PUSH1 0x42, ADD, STOP
    const code = [_]u8{ @intFromEnum(Opcode.PUSH1), 0x42, @intFromEnum(Opcode.ADD), @intFromEnum(Opcode.STOP) };
    const Bytecode = bytecode_mod.Bytecode(TestFrame.BytecodeConfig);
    var bytecode = try Bytecode.init(allocator, &code);
    defer bytecode.deinit();

    // Create mock schedule items
    const mock_handler = &struct {
        fn handler() void {}
    }.handler;
    
    const schedule = [_]MockDispatch.Item{
        .{ .opcode_handler = mock_handler }, // PUSH1 handler
        .{ .push_inline = .{ .value = 0x42 } }, // PUSH1 value
        .{ .opcode_handler = mock_handler }, // ADD handler  
        .{ .opcode_handler = mock_handler }, // STOP handler
        .{ .opcode_handler = mock_handler }, // Safety STOP
    };

    // Test pretty_print
    const formatted = try dispatch_debug.pretty_print(TestFrame, allocator, &schedule, &bytecode);
    defer allocator.free(formatted);

    // Verify the output contains expected elements
    try testing.expect(std.mem.indexOf(u8, formatted, "=== EVM Dispatch Instruction Stream ===") != null);
    try testing.expect(std.mem.indexOf(u8, formatted, "--- Original Bytecode ---") != null);
    try testing.expect(std.mem.indexOf(u8, formatted, "--- Dispatch Instruction Stream ---") != null);
    try testing.expect(std.mem.indexOf(u8, formatted, "--- Summary ---") != null);
    try testing.expect(std.mem.indexOf(u8, formatted, "PUSH1") != null);
    try testing.expect(std.mem.indexOf(u8, formatted, "0x42") != null);

    // Verify it's a non-empty string
    try testing.expect(formatted.len > 100);
}

test "pretty_print - empty bytecode formatting" {
    const allocator = testing.allocator;
    
    // Create empty bytecode
    const Bytecode = bytecode_mod.Bytecode(TestFrame.BytecodeConfig);
    var bytecode = try Bytecode.init(allocator, &[_]u8{});
    defer bytecode.deinit();

    // Create minimal schedule (just safety STOP handlers)
    const mock_handler = &struct {
        fn handler() void {}
    }.handler;
    
    const schedule = [_]MockDispatch.Item{
        .{ .opcode_handler = mock_handler }, // Safety STOP
        .{ .opcode_handler = mock_handler }, // Safety STOP
    };

    const formatted = try dispatch_debug.pretty_print(TestFrame, allocator, &schedule, &bytecode);
    defer allocator.free(formatted);

    // Verify basic structure is present
    try testing.expect(std.mem.indexOf(u8, formatted, "=== EVM Dispatch Instruction Stream ===") != null);
    try testing.expect(std.mem.indexOf(u8, formatted, "(empty)") != null);
    try testing.expect(formatted.len > 50);
}

test "pretty_print - large bytecode with multiple PUSH types" {
    const allocator = testing.allocator;
    
    // Create bytecode with different PUSH sizes
    const code = [_]u8{
        @intFromEnum(Opcode.PUSH1), 0x01,
        @intFromEnum(Opcode.PUSH2), 0x12, 0x34,
        @intFromEnum(Opcode.PUSH4), 0x11, 0x22, 0x33, 0x44,
        @intFromEnum(Opcode.ADD),
        @intFromEnum(Opcode.STOP),
    };
    
    const Bytecode = bytecode_mod.Bytecode(TestFrame.BytecodeConfig);
    var bytecode = try Bytecode.init(allocator, &code);
    defer bytecode.deinit();

    const mock_handler = &struct {
        fn handler() void {}
    }.handler;
    
    const test_value: u256 = 0x11223344;
    const schedule = [_]MockDispatch.Item{
        .{ .opcode_handler = mock_handler }, // PUSH1
        .{ .push_inline = .{ .value = 0x01 } },
        .{ .opcode_handler = mock_handler }, // PUSH2  
        .{ .push_inline = .{ .value = 0x1234 } },
        .{ .opcode_handler = mock_handler }, // PUSH4
        .{ .push_pointer = .{ .value = &test_value } },
        .{ .opcode_handler = mock_handler }, // ADD
        .{ .opcode_handler = mock_handler }, // STOP
        .{ .opcode_handler = mock_handler }, // Safety STOP
    };

    const formatted = try dispatch_debug.pretty_print(TestFrame, allocator, &schedule, &bytecode);
    defer allocator.free(formatted);

    // Verify multiple PUSH types are shown
    try testing.expect(std.mem.indexOf(u8, formatted, "PUSH1") != null);
    try testing.expect(std.mem.indexOf(u8, formatted, "PUSH2") != null);  
    try testing.expect(std.mem.indexOf(u8, formatted, "PUSH4") != null);
    try testing.expect(std.mem.indexOf(u8, formatted, "0x1234") != null);
    try testing.expect(formatted.len > 200);
}

test "pretty_print - ANSI color code inclusion" {
    const allocator = testing.allocator;
    
    const code = [_]u8{ @intFromEnum(Opcode.STOP) };
    const Bytecode = bytecode_mod.Bytecode(TestFrame.BytecodeConfig);
    var bytecode = try Bytecode.init(allocator, &code);
    defer bytecode.deinit();

    const mock_handler = &struct {
        fn handler() void {}
    }.handler;
    
    const schedule = [_]MockDispatch.Item{
        .{ .opcode_handler = mock_handler }, // STOP
        .{ .opcode_handler = mock_handler }, // Safety STOP
    };

    const formatted = try dispatch_debug.pretty_print(TestFrame, allocator, &schedule, &bytecode);
    defer allocator.free(formatted);

    // Verify ANSI color codes are present
    try testing.expect(std.mem.indexOf(u8, formatted, "\x1b[") != null); // ANSI escape sequence
    try testing.expect(std.mem.indexOf(u8, formatted, "\x1b[0m") != null); // Reset code
    try testing.expect(std.mem.indexOf(u8, formatted, "\x1b[1m") != null); // Bold code
}

test "pretty_print - memory allocation limits" {
    const allocator = testing.allocator;
    
    // Test with reasonable sized bytecode to ensure no allocation issues
    var large_code = std.ArrayList(u8){};
    defer large_code.deinit(allocator);
    
    // Create bytecode with many simple operations
    for (0..100) |_| {
        try large_code.append(allocator, @intFromEnum(Opcode.STOP));
    }
    
    const Bytecode = bytecode_mod.Bytecode(TestFrame.BytecodeConfig);
    var bytecode = try Bytecode.init(allocator, large_code.items);
    defer bytecode.deinit();

    const mock_handler = &struct {
        fn handler() void {}
    }.handler;
    
    // Create corresponding schedule
    var schedule = std.ArrayList(MockDispatch.Item){};
    defer schedule.deinit(allocator);
    
    for (0..102) |_| { // 100 handlers + 2 safety
        try schedule.append(allocator, .{ .opcode_handler = mock_handler });
    }

    const formatted = try dispatch_debug.pretty_print(TestFrame, allocator, schedule.items, &bytecode);
    defer allocator.free(formatted);

    // Should handle large input without issues
    try testing.expect(formatted.len > 1000);
    try testing.expect(std.mem.indexOf(u8, formatted, "Compression ratio") != null);
}