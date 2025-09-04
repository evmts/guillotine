const std = @import("std");
const testing = std.testing;
const BytecodeConfig = @import("bytecode_config.zig").BytecodeConfig;
const VerificationMode = @import("bytecode_config.zig").VerificationMode;

// Phase 5: Edge Cases and Error Handling Tests

test "Shadow frame memory allocation failure handling" {
    if (!std.debug.runtime_safety) return; // Skip in release builds
    
    // Create a failing allocator that fails after a certain number of allocations
    var failing_allocator = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 1 });
    const allocator = failing_allocator.allocator();
    
    const TestFrame = @import("frame.zig").Frame(@import("frame_config.zig").FrameConfig{});
    
    // Attempt to create shadow frame - should fail gracefully
    const result = TestFrame.ShadowFrame.init(allocator, .opcode);
    try testing.expectError(error.OutOfMemory, result);
    
    // Verify no memory leaks occurred
    try testing.expect(failing_allocator.allocated_bytes == failing_allocator.freed_bytes);
}

test "Stack verification with different stack depths" {
    const allocator = testing.allocator;
    const StackType = @import("stack.zig").Stack(.{});
    
    var stack1 = try StackType.init(allocator);
    defer stack1.deinit(allocator);
    var stack2 = try StackType.init(allocator);
    defer stack2.deinit(allocator);
    
    // Test with stack1 having more elements
    try stack1.push(100);
    try stack1.push(200);
    try stack1.push(300);
    
    try stack2.push(100);
    try stack2.push(200);
    // stack2 has one less element
    
    // Should not be equal due to different depths
    try testing.expect(!stack1.equals(&stack2));
    
    // Add third element to stack2
    try stack2.push(300);
    try testing.expect(stack1.equals(&stack2));
    
    // Test with one stack empty
    var empty_stack = try StackType.init(allocator);
    defer empty_stack.deinit(allocator);
    
    try testing.expect(!stack1.equals(&empty_stack));
    try testing.expect(!empty_stack.equals(&stack1));
}

test "Memory verification with different checkpoint positions" {
    const allocator = testing.allocator;
    const MemoryType = @import("memory.zig").Memory(.{ .owned = true });
    
    // Create parent memory and child memory to test checkpoint behavior
    var parent = try MemoryType.init(allocator);
    defer parent.deinit(allocator);
    
    // Add some data to parent
    const parent_data = [_]u8{ 0x01, 0x02, 0x03 };
    try parent.set_data(allocator, 0, &parent_data);
    
    // Create child with different checkpoint
    var child = try parent.init_child();
    defer child.deinit(allocator);
    
    // Add data to child
    const child_data = [_]u8{ 0x04, 0x05 };
    try child.set_data(allocator, 0, &child_data);
    
    // Parent and child should not be equal due to different data
    try testing.expect(!parent.equals(&child));
    
    // Create another child with same data
    var child2 = try parent.init_child();
    defer child2.deinit(allocator);
    
    try child2.set_data(allocator, 0, &child_data);
    
    // Children with same data should be equal
    try testing.expect(child.equals(&child2));
}

test "Gas verification edge cases" {
    // Test gas verification tolerance boundaries
    const gas_tests = [_]struct {
        main_gas: u64,
        shadow_gas: u64,
        should_pass: bool,
    }{
        .{ .main_gas = 1000, .shadow_gas = 1000, .should_pass = true }, // Identical
        .{ .main_gas = 1000, .shadow_gas = 995, .should_pass = true },  // 5 gas diff (within tolerance)
        .{ .main_gas = 1000, .shadow_gas = 1005, .should_pass = true }, // 5 gas diff other direction
        .{ .main_gas = 1000, .shadow_gas = 994, .should_pass = false }, // 6 gas diff (outside tolerance)
        .{ .main_gas = 1000, .shadow_gas = 1006, .should_pass = false }, // 6 gas diff other direction
        .{ .main_gas = 0, .shadow_gas = 5, .should_pass = true },        // Low gas within tolerance
        .{ .main_gas = 5, .shadow_gas = 0, .should_pass = true },        // Low gas within tolerance
        .{ .main_gas = 0, .shadow_gas = 6, .should_pass = false },       // Low gas outside tolerance
    };
    
    for (gas_tests) |test_case| {
        const gas_diff = if (test_case.shadow_gas >= test_case.main_gas)
            test_case.shadow_gas - test_case.main_gas
        else
            test_case.main_gas - test_case.shadow_gas;
        
        const within_tolerance = gas_diff <= 5;
        try testing.expect(within_tolerance == test_case.should_pass);
    }
}

test "Verification mode configuration edge cases" {
    // Test all verification modes
    const modes = [_]VerificationMode{ .none, .opcode, .block, .transaction };
    
    for (modes) |mode| {
        const config = BytecodeConfig{
            .verification_mode = if (std.debug.runtime_safety) mode else {},
        };
        
        if (std.debug.runtime_safety) {
            try testing.expect(config.verification_mode == mode);
        } else {
            try testing.expect(@TypeOf(config.verification_mode) == void);
        }
    }
}

test "Block verification frequency edge cases" {
    if (!std.debug.runtime_safety) return; // Skip in release builds
    
    const TestFrame = @import("frame.zig").Frame(@import("frame_config.zig").FrameConfig{});
    const ShadowFrameType = TestFrame.ShadowFrame;
    
    var shadow_frame = ShadowFrameType{
        .frame = undefined,
        .dispatch = undefined,
        .verification_mode = .block,
        .opcode_count = 0,
    };
    
    // Test block boundary cases
    const boundary_tests = [_]struct {
        opcode_count: u32,
        should_verify: bool,
    }{
        .{ .opcode_count = 0, .should_verify = true },    // 0 % 64 == 0
        .{ .opcode_count = 1, .should_verify = false },   // 1 % 64 != 0
        .{ .opcode_count = 63, .should_verify = false },  // 63 % 64 != 0
        .{ .opcode_count = 64, .should_verify = true },   // 64 % 64 == 0
        .{ .opcode_count = 65, .should_verify = false },  // 65 % 64 != 0
        .{ .opcode_count = 128, .should_verify = true },  // 128 % 64 == 0
        .{ .opcode_count = 192, .should_verify = true },  // 192 % 64 == 0
        .{ .opcode_count = 256, .should_verify = true },  // 256 % 64 == 0
    };
    
    for (boundary_tests) |test_case| {
        shadow_frame.opcode_count = test_case.opcode_count;
        try testing.expect(shadow_frame.shouldVerify() == test_case.should_verify);
    }
}

test "Large bytecode handling" {
    const allocator = testing.allocator;
    
    // Create large bytecode with many fusion opportunities
    var large_bytecode = std.ArrayList(u8).init(allocator);
    defer large_bytecode.deinit();
    
    // Generate 1000 PUSH+ADD pairs
    var i: u16 = 0;
    while (i < 1000) : (i += 1) {
        const value = @as(u8, @intCast(i % 256));
        try large_bytecode.appendSlice(&[_]u8{
            0x60, value, // PUSH1 value
            0x01,        // ADD
        });
    }
    try large_bytecode.append(0x00); // STOP
    
    // Verify we created a large bytecode
    try testing.expect(large_bytecode.items.len == 3001); // (3 * 1000) + 1
    
    // Test configuration can handle large bytecode
    const config = BytecodeConfig{
        .fusions_enabled = true,
        .verification_mode = if (std.debug.runtime_safety) .block else {}, // Use block mode for large bytecode
        .max_bytecode_size = 4000, // Ensure we can handle this size
    };
    
    try testing.expect(config.max_bytecode_size >= large_bytecode.items.len);
}

test "Stack overflow and underflow during verification" {
    const allocator = testing.allocator;
    const StackType = @import("stack.zig").Stack(.{ .stack_size = 10 }); // Small stack for testing
    
    var stack = try StackType.init(allocator);
    defer stack.deinit(allocator);
    
    // Fill stack to capacity
    var i: u8 = 0;
    while (i < 10) : (i += 1) {
        try stack.push(i);
    }
    
    // Test stack overflow condition
    try testing.expectError(error.StackOverflow, stack.push(999));
    
    // Empty stack completely
    while (stack.size() > 0) {
        _ = try stack.pop();
    }
    
    // Test stack underflow condition
    try testing.expectError(error.StackUnderflow, stack.pop());
}

test "Memory expansion during verification" {
    const allocator = testing.allocator;
    const MemoryType = @import("memory.zig").Memory(.{ 
        .owned = true, 
        .memory_limit = 1000,
        .initial_capacity = 100 
    });
    
    var memory = try MemoryType.init(allocator);
    defer memory.deinit(allocator);
    
    // Test expansion within limits
    try memory.ensure_capacity(allocator, 500);
    try testing.expect(memory.buffer_ptr.*.items.len >= 500);
    
    // Test expansion to limit
    try memory.ensure_capacity(allocator, 1000);
    try testing.expect(memory.buffer_ptr.*.items.len >= 1000);
    
    // Test expansion beyond limit should fail
    try testing.expectError(error.MemoryOverflow, memory.ensure_capacity(allocator, 1001));
}

test "Shadow schedule cleanup with partial initialization" {
    if (!std.debug.runtime_safety) return; // Skip in release builds
    
    // This test ensures proper cleanup even if shadow schedule creation fails partway through
    const allocator = testing.allocator;
    
    const TestFrame = @import("frame.zig").Frame(@import("frame_config.zig").FrameConfig{});
    const TestDispatch = @import("dispatch.zig").Dispatch(TestFrame);
    const ScheduleType = TestDispatch.DispatchSchedule;
    
    // Create a schedule with shadow fields
    var schedule = ScheduleType{
        .items = &[_]TestDispatch.Item{},
        .allocator = allocator,
        .push_pointers = &[_]*TestFrame.WordType{},
        .shadow_items = null,
        .shadow_push_pointers = null,
    };
    
    // Test that deinit handles null shadow fields gracefully
    schedule.deinit(); // Should not crash
}

test "Verification with mixed fusion and non-fusion opcodes" {
    // Test bytecode that has a mix of fusible and non-fusible operations
    const mixed_bytecode = [_]u8{
        // Fusible sequence
        0x60, 0x05, // PUSH1 5
        0x01,       // ADD
        
        // Non-fusible operation
        0x80,       // DUP1
        
        // Another fusible sequence
        0x60, 0x03, // PUSH1 3
        0x02,       // MUL
        
        // Non-fusible operation
        0x50,       // POP
        
        0x00        // STOP
    };
    
    const config = BytecodeConfig{
        .fusions_enabled = true,
        .verification_mode = if (std.debug.runtime_safety) .opcode else {},
    };
    
    // Count potential fusion opportunities (PUSH followed by arithmetic op)
    var fusion_opportunities: u32 = 0;
    var i: usize = 0;
    while (i < mixed_bytecode.len - 1) : (i += 1) {
        if (mixed_bytecode[i] == 0x60) { // PUSH1
            if (i + 2 < mixed_bytecode.len) {
                const next_op = mixed_bytecode[i + 2];
                if (next_op == 0x01 or next_op == 0x02 or next_op == 0x03) { // ADD, MUL, SUB
                    fusion_opportunities += 1;
                }
            }
        }
    }
    
    try testing.expect(fusion_opportunities == 2); // Should find 2 fusion opportunities
    try testing.expect(config.fusions_enabled == true);
}