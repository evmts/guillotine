const std = @import("std");
const testing = std.testing;
const bytecode_mod = @import("bytecode.zig");
const Opcode = @import("opcode_data.zig").Opcode;
const dispatch_schedule = @import("dispatch_schedule.zig");

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

// Mock dispatch type
const MockDispatch = struct {
    cursor: [*]const Item,
    
    pub const Item = union {
        opcode_handler: *const fn (frame: *TestFrame, cursor: [*]const Item) TestFrame.Error!noreturn,
        push_inline: struct { value: u64 },
        push_pointer: struct { value: *TestFrame.WordType },
        jump_dest: struct { gas: u64 },
        pc: struct { value: u32 },
        first_block_gas: struct { gas: u64 },
    };
    
    pub const BuildOwned = struct {
        items: []Item,
        push_pointers: []*TestFrame.WordType,
    };
};

// Mock handler functions
fn mockStop(frame: *TestFrame, cursor: [*]const MockDispatch.Item) TestFrame.Error!noreturn {
    _ = frame;
    _ = cursor;
    return TestFrame.Error.Stop;
}

fn mockPush1(frame: *TestFrame, cursor: [*]const MockDispatch.Item) TestFrame.Error!noreturn {
    _ = frame;
    _ = cursor;
    return TestFrame.Error.Stop;
}

test "DispatchSchedule - init with simple bytecode" {
    const allocator = testing.allocator;
    
    const Bytecode = bytecode_mod.Bytecode(TestFrame.BytecodeConfig);
    var bytecode = try Bytecode.init(allocator, &[_]u8{ @intFromEnum(Opcode.PUSH1), 42 });
    defer bytecode.deinit();

    // Create mock BuildOwned result
    var items = [_]MockDispatch.Item{
        .{ .opcode_handler = &mockPush1 },
        .{ .push_inline = .{ .value = 42 } },
        .{ .opcode_handler = &mockStop },
        .{ .opcode_handler = &mockStop },
    };
    
    const owned = MockDispatch.BuildOwned{
        .items = &items,
        .push_pointers = &.{}, // No pointer pushes for simple test
    };
    
    const DispatchSchedule = dispatch_schedule.DispatchSchedule(TestFrame, MockDispatch);
    var schedule = DispatchSchedule.fromOwned(allocator, owned);
    defer schedule.deinit();
    
    try testing.expect(schedule.items.len == 4);
    try testing.expect(schedule.push_pointers.len == 0);
}

test "DispatchSchedule - deinit cleans up push pointers" {
    const allocator = testing.allocator;
    
    // Create mock items with pointer pushes
    const ptr1 = try allocator.create(TestFrame.WordType);
    const ptr2 = try allocator.create(TestFrame.WordType);
    ptr1.* = 123;
    ptr2.* = 456;
    
    var items = [_]MockDispatch.Item{
        .{ .opcode_handler = &mockPush1 },
        .{ .push_pointer = .{ .value = ptr1 } },
        .{ .opcode_handler = &mockPush1 },
        .{ .push_pointer = .{ .value = ptr2 } },
        .{ .opcode_handler = &mockStop },
    };
    
    const push_ptrs = [_]*TestFrame.WordType{ ptr1, ptr2 };
    
    const owned = MockDispatch.BuildOwned{
        .items = &items,
        .push_pointers = @constCast(&push_ptrs),
    };
    
    const DispatchSchedule = dispatch_schedule.DispatchSchedule(TestFrame, MockDispatch);
    var schedule = DispatchSchedule.fromOwned(allocator, owned);
    
    try testing.expect(schedule.push_pointers.len == 2);
    try testing.expect(schedule.push_pointers[0] == ptr1);
    try testing.expect(schedule.push_pointers[1] == ptr2);
    
    // deinit should clean up the pointers
    schedule.deinit();
    
    // Pointers are now freed - don't access them
}

test "DispatchSchedule - getDispatch returns valid cursor" {
    const allocator = testing.allocator;
    
    var items = [_]MockDispatch.Item{
        .{ .opcode_handler = &mockStop },
        .{ .opcode_handler = &mockStop },
    };
    
    const owned = MockDispatch.BuildOwned{
        .items = &items,
        .push_pointers = &.{},
    };
    
    const DispatchSchedule = dispatch_schedule.DispatchSchedule(TestFrame, MockDispatch);
    var schedule = DispatchSchedule.fromOwned(allocator, owned);
    defer schedule.deinit();
    
    const dispatch = schedule.getDispatch();
    try testing.expect(dispatch.cursor == items.ptr);
}

test "DispatchSchedule - error handling during init" {
    var failing_allocator = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 1 });
    
    // This simulates what would happen if allocation fails during construction
    // The actual error would come from the dispatch builder, not the schedule itself
    
    var items = [_]MockDispatch.Item{
        .{ .opcode_handler = &mockStop },
    };
    
    const owned = MockDispatch.BuildOwned{
        .items = &items,
        .push_pointers = &.{},
    };
    
    const DispatchSchedule = dispatch_schedule.DispatchSchedule(TestFrame, MockDispatch);
    
    // This should work since we're just wrapping existing owned data
    var schedule = DispatchSchedule.fromOwned(failing_allocator.allocator(), owned);
    defer schedule.deinit();
    
    try testing.expect(schedule.items.len == 1);
}

test "DispatchSchedule - mixed inline and pointer pushes" {
    const allocator = testing.allocator;
    
    // Create mixed push types
    const large_value_ptr = try allocator.create(TestFrame.WordType);
    large_value_ptr.* = 0x123456789ABCDEF0123456789ABCDEF0;
    
    var items = [_]MockDispatch.Item{
        .{ .opcode_handler = &mockPush1 }, // Small PUSH (inline)
        .{ .push_inline = .{ .value = 42 } },
        .{ .opcode_handler = &mockPush1 }, // Large PUSH (pointer)  
        .{ .push_pointer = .{ .value = large_value_ptr } },
        .{ .opcode_handler = &mockStop },
    };
    
    const push_ptrs = [_]*TestFrame.WordType{ large_value_ptr };
    
    const owned = MockDispatch.BuildOwned{
        .items = &items,
        .push_pointers = @constCast(&push_ptrs),
    };
    
    const DispatchSchedule = dispatch_schedule.DispatchSchedule(TestFrame, MockDispatch);
    var schedule = DispatchSchedule.fromOwned(allocator, owned);
    defer schedule.deinit();
    
    try testing.expect(schedule.items.len == 5);
    try testing.expect(schedule.push_pointers.len == 1);
    
    // Verify inline value
    try testing.expect(schedule.items[1].push_inline.value == 42);
    
    // Verify pointer value
    try testing.expect(schedule.items[3].push_pointer.value.* == 0x123456789ABCDEF0123456789ABCDEF0);
}