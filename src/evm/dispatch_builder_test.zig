const std = @import("std");
const testing = std.testing;
const bytecode_mod = @import("bytecode.zig");
const Opcode = @import("opcode_data.zig").Opcode;
const dispatch_builder = @import("dispatch_builder.zig");

// Test frame type for testing
const TestFrame = struct {
    pub const WordType = u256;
    pub const PcType = u32;
    pub const BytecodeConfig = @import("bytecode_config.zig").BytecodeConfig{
        .max_bytecode_size = 1024,
        .max_initcode_size = 49152,
    };
    
    pub const Error = error{
        TestError,
        Stop,
    };
};

// Mock dispatch Item type
const MockItem = union {
    opcode_handler: *const fn (frame: *TestFrame, cursor: [*]const MockItem) TestFrame.Error!noreturn,
    push_inline: struct { value: u64 },
    push_pointer: struct { value: *TestFrame.WordType },
    jump_dest: struct { gas: u64 },
    pc: struct { value: u32 },
    first_block_gas: struct { gas: u64 },
};

// Mock handlers
fn mockStop(frame: *TestFrame, cursor: [*]const MockItem) TestFrame.Error!noreturn {
    _ = frame;
    _ = cursor;
    return TestFrame.Error.Stop;
}

fn mockAdd(frame: *TestFrame, cursor: [*]const MockItem) TestFrame.Error!noreturn {
    _ = frame;
    _ = cursor;
    return TestFrame.Error.Stop;
}

fn mockPush1(frame: *TestFrame, cursor: [*]const MockItem) TestFrame.Error!noreturn {
    _ = frame;
    _ = cursor;
    return TestFrame.Error.Stop;
}

// Create test handler array
fn createTestHandlers() [256]*const fn (frame: *TestFrame, cursor: [*]const MockItem) TestFrame.Error!noreturn {
    var handlers: [256]*const fn (frame: *TestFrame, cursor: [*]const MockItem) TestFrame.Error!noreturn = undefined;
    
    for (&handlers) |*handler| {
        handler.* = &mockStop;
    }
    
    handlers[@intFromEnum(Opcode.STOP)] = &mockStop;
    handlers[@intFromEnum(Opcode.ADD)] = &mockAdd;
    handlers[@intFromEnum(Opcode.PUSH1)] = &mockPush1;
    
    return handlers;
}

test "DispatchBuilder - build with empty bytecode" {
    const allocator = testing.allocator;
    const handlers = createTestHandlers();
    
    const Bytecode = bytecode_mod.Bytecode(TestFrame.BytecodeConfig);
    var bytecode = try Bytecode.init(allocator, &[_]u8{});
    defer bytecode.deinit();
    
    const DispatchBuilder = dispatch_builder.DispatchBuilder(TestFrame, MockItem);
    const items = try DispatchBuilder.build(allocator, &bytecode, &handlers);
    defer allocator.free(items);
    
    // Should have at least 2 STOP handlers for safety
    try testing.expect(items.len >= 2);
    try testing.expect(items[items.len - 1].opcode_handler == &mockStop);
    try testing.expect(items[items.len - 2].opcode_handler == &mockStop);
}

test "DispatchBuilder - build with complex instruction sequence" {
    const allocator = testing.allocator;
    const handlers = createTestHandlers();
    
    // Create bytecode: PUSH1 10, PUSH1 20, ADD, STOP
    const Bytecode = bytecode_mod.Bytecode(TestFrame.BytecodeConfig);
    var bytecode = try Bytecode.init(allocator, &[_]u8{
        @intFromEnum(Opcode.PUSH1), 10,
        @intFromEnum(Opcode.PUSH1), 20,
        @intFromEnum(Opcode.ADD),
        @intFromEnum(Opcode.STOP),
    });
    defer bytecode.deinit();
    
    const DispatchBuilder = dispatch_builder.DispatchBuilder(TestFrame, MockItem);
    const items = try DispatchBuilder.build(allocator, &bytecode, &handlers);
    defer allocator.free(items);
    
    // Verify structure: [first_block_gas], PUSH1, metadata, PUSH1, metadata, ADD, STOP, STOP, STOP
    try testing.expect(items.len >= 8);
    
    // Find first handler (skip first_block_gas if present)
    var handler_index: usize = 0;
    if (items.len > 0) {
        switch (items[0]) {
            .first_block_gas => handler_index = 1,
            else => handler_index = 0,
        }
    }
    
    // First PUSH1
    try testing.expect(items[handler_index].opcode_handler == &mockPush1);
    try testing.expect(items[handler_index + 1].push_inline.value == 10);
    
    // Second PUSH1  
    try testing.expect(items[handler_index + 2].opcode_handler == &mockPush1);
    try testing.expect(items[handler_index + 3].push_inline.value == 20);
    
    // ADD
    try testing.expect(items[handler_index + 4].opcode_handler == &mockAdd);
}

test "DispatchBuilder - buildWithOwnership memory management" {
    const allocator = testing.allocator;
    const handlers = createTestHandlers();
    
    // Create bytecode with large PUSH that needs pointer storage
    var push16_data = [_]u8{@intFromEnum(Opcode.PUSH16)} ++ [_]u8{0xFF} ** 16;
    const Bytecode = bytecode_mod.Bytecode(TestFrame.BytecodeConfig);
    var bytecode = try Bytecode.init(allocator, &push16_data);
    defer bytecode.deinit();
    
    const DispatchBuilder = dispatch_builder.DispatchBuilder(TestFrame, MockItem);
    const owned = try DispatchBuilder.buildWithOwnership(allocator, &bytecode, &handlers);
    defer {
        for (owned.push_pointers) |ptr| {
            allocator.destroy(ptr);
        }
        if (owned.push_pointers.len > 0) allocator.free(owned.push_pointers);
        allocator.free(owned.items);
    }
    
    try testing.expect(owned.items.len >= 4); // Handler + metadata + 2 STOP handlers
    try testing.expect(owned.push_pointers.len == 1); // One large value pointer
    
    // Verify the large value was stored correctly
    const expected_value: u256 = (1 << 128) - 1; // 16 bytes of 0xFF
    try testing.expect(owned.push_pointers[0].* == expected_value);
}

test "DispatchBuilder - AllocatedMemory tracking and cleanup" {
    const allocator = testing.allocator;
    
    // Test the AllocatedMemory helper directly
    const DispatchBuilder = dispatch_builder.DispatchBuilder(TestFrame, MockItem);
    var allocated = DispatchBuilder.AllocatedMemory.init();
    defer allocated.deinit(allocator);
    
    // Add some test pointers
    const ptr1 = try allocator.create(TestFrame.WordType);
    const ptr2 = try allocator.create(TestFrame.WordType);
    ptr1.* = 123;
    ptr2.* = 456;
    
    try allocated.pointers.append(allocator, ptr1);
    try allocated.pointers.append(allocator, ptr2);
    
    try testing.expect(allocated.pointers.items.len == 2);
    try testing.expect(allocated.pointers.items[0].* == 123);
    try testing.expect(allocated.pointers.items[1].* == 456);
    
    // deinit will clean up the pointers
}

test "DispatchBuilder - processRegularOpcode edge cases" {
    // This tests the internal helper functions through public API
    const allocator = testing.allocator;
    const handlers = createTestHandlers();
    
    // Test PC opcode which adds metadata
    const Bytecode = bytecode_mod.Bytecode(TestFrame.BytecodeConfig);
    var bytecode = try Bytecode.init(allocator, &[_]u8{@intFromEnum(Opcode.PC)});
    defer bytecode.deinit();
    
    const DispatchBuilder = dispatch_builder.DispatchBuilder(TestFrame, MockItem);
    const items = try DispatchBuilder.build(allocator, &bytecode, &handlers);
    defer allocator.free(items);
    
    // Find PC handler (skip first_block_gas if present)
    var pc_index: usize = 0;
    if (items.len > 0) {
        switch (items[0]) {
            .first_block_gas => pc_index = 1,
            else => pc_index = 0,
        }
    }
    
    // Should have PC handler + metadata
    try testing.expect(items[pc_index + 1].pc.value == 0); // PC at position 0
}

test "DispatchBuilder - processPushOpcode inline vs pointer" {
    const allocator = testing.allocator;
    const handlers = createTestHandlers();
    
    // Test small PUSH (inline)
    {
        const Bytecode = bytecode_mod.Bytecode(TestFrame.BytecodeConfig);
        var bytecode = try Bytecode.init(allocator, &[_]u8{ @intFromEnum(Opcode.PUSH1), 42 });
        defer bytecode.deinit();
        
        const DispatchBuilder = dispatch_builder.DispatchBuilder(TestFrame, MockItem);
        const items = try DispatchBuilder.build(allocator, &bytecode, &handlers);
        defer allocator.free(items);
        
        // Find PUSH1 metadata
        var found_inline = false;
        for (items) |item| {
            switch (item) {
                .push_inline => |meta| {
                    found_inline = true;
                    try testing.expect(meta.value == 42);
                },
                else => {},
            }
        }
        try testing.expect(found_inline);
    }
    
    // Test large PUSH (pointer)
    {
        var push32_data = [_]u8{@intFromEnum(Opcode.PUSH32)} ++ [_]u8{0xFF} ** 32;
        const Bytecode = bytecode_mod.Bytecode(TestFrame.BytecodeConfig);
        var bytecode = try Bytecode.init(allocator, &push32_data);
        defer bytecode.deinit();
        
        const DispatchBuilder = dispatch_builder.DispatchBuilder(TestFrame, MockItem);
        const owned = try DispatchBuilder.buildWithOwnership(allocator, &bytecode, &handlers);
        defer {
            for (owned.push_pointers) |ptr| {
                allocator.destroy(ptr);
            }
            if (owned.push_pointers.len > 0) allocator.free(owned.push_pointers);
            allocator.free(owned.items);
        }
        
        // Should have pointer metadata
        var found_pointer = false;
        for (owned.items) |item| {
            switch (item) {
                .push_pointer => |meta| {
                    found_pointer = true;
                    const expected: u256 = (1 << 256) - 1; // 32 bytes of 0xFF
                    try testing.expect(meta.value.* == expected);
                },
                else => {},
            }
        }
        try testing.expect(found_pointer);
    }
}

test "DispatchBuilder - error handling and cleanup paths" {
    var failing_allocator = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 3 });
    const handlers = createTestHandlers();
    
    const Bytecode = bytecode_mod.Bytecode(TestFrame.BytecodeConfig);
    var bytecode = try Bytecode.init(testing.allocator, &[_]u8{ @intFromEnum(Opcode.PUSH1), 42 });
    defer bytecode.deinit();
    
    const DispatchBuilder = dispatch_builder.DispatchBuilder(TestFrame, MockItem);
    const result = DispatchBuilder.build(failing_allocator.allocator(), &bytecode, &handlers);
    
    // Should fail with OutOfMemory
    try testing.expectError(error.OutOfMemory, result);
}