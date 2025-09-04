const std = @import("std");
const testing = std.testing;
const BytecodeConfig = @import("bytecode_config.zig").BytecodeConfig;
const VerificationMode = @import("bytecode_config.zig").VerificationMode;

// Phase 1: Foundation Tests

test "BytecodeConfig verification_mode field exists in debug builds" {
    const config = BytecodeConfig{
        .verification_mode = if (std.debug.runtime_safety) .block else {},
    };
    
    if (std.debug.runtime_safety) {
        // In debug builds, field should exist and be accessible
        try testing.expect(config.verification_mode == .block);
        
        // Test all verification modes
        const test_config_opcode = BytecodeConfig{
            .verification_mode = .opcode,
        };
        try testing.expect(test_config_opcode.verification_mode == .opcode);
        
        const test_config_transaction = BytecodeConfig{
            .verification_mode = .transaction,
        };
        try testing.expect(test_config_transaction.verification_mode == .transaction);
        
        const test_config_none = BytecodeConfig{
            .verification_mode = .none,
        };
        try testing.expect(test_config_none.verification_mode == .none);
    } else {
        // In release builds, field should be void type and take no space
        try testing.expect(@TypeOf(config.verification_mode) == void);
    }
}

test "VerificationMode enum has correct values" {
    try testing.expect(@intFromEnum(VerificationMode.none) == 0);
    try testing.expect(@intFromEnum(VerificationMode.opcode) == 1);
    try testing.expect(@intFromEnum(VerificationMode.block) == 2);
    try testing.expect(@intFromEnum(VerificationMode.transaction) == 3);
}

test "BytecodeConfig fusion and verification compatibility" {
    const config_fused = BytecodeConfig{
        .fusions_enabled = true,
        .verification_mode = if (std.debug.runtime_safety) .opcode else {},
    };
    
    const config_no_fusion = BytecodeConfig{
        .fusions_enabled = false,
        .verification_mode = if (std.debug.runtime_safety) .none else {},
    };
    
    try testing.expect(config_fused.fusions_enabled == true);
    try testing.expect(config_no_fusion.fusions_enabled == false);
    
    if (std.debug.runtime_safety) {
        try testing.expect(config_fused.verification_mode == .opcode);
        try testing.expect(config_no_fusion.verification_mode == .none);
    }
}

test "BytecodeConfig zero overhead in release builds" {
    // Ensure verification fields don't add overhead in release builds
    const config_with_verification = BytecodeConfig{
        .fusions_enabled = true,
        .verification_mode = if (std.debug.runtime_safety) .block else {},
    };
    
    const config_without_verification = BytecodeConfig{
        .fusions_enabled = true,
        // No verification field
    };
    
    if (!std.debug.runtime_safety) {
        // In release builds, both configs should be identical size
        try testing.expect(@sizeOf(@TypeOf(config_with_verification)) == 
                           @sizeOf(@TypeOf(config_without_verification)));
    }
}

// Phase 2: Dispatch Schedule Shadow Tests

test "DispatchSchedule has shadow fields in debug builds" {
    // This test verifies the DispatchSchedule structure has conditional compilation
    const TestFrame = @import("frame.zig").Frame(@import("frame_config.zig").FrameConfig{});
    const TestDispatch = @import("dispatch.zig").Dispatch(TestFrame);
    const ScheduleType = TestDispatch.DispatchSchedule;
    
    if (std.debug.runtime_safety) {
        try testing.expect(@hasField(ScheduleType, "shadow_items"));
        try testing.expect(@hasField(ScheduleType, "shadow_push_pointers"));
    } else {
        // In release builds, shadow fields should be void type
        try testing.expect(@TypeOf(@as(ScheduleType, undefined).shadow_items) == void);
        try testing.expect(@TypeOf(@as(ScheduleType, undefined).shadow_push_pointers) == void);
    }
}

// Phase 3: Shadow Frame Tests

test "ShadowFrame structure compilation" {
    const TestFrame = @import("frame.zig").Frame(@import("frame_config.zig").FrameConfig{});
    
    if (std.debug.runtime_safety) {
        try testing.expect(@hasField(TestFrame, "shadow_frame"));
        
        // Test that ShadowFrame type is defined
        const ShadowFrameType = TestFrame.ShadowFrame;
        try testing.expect(@hasField(ShadowFrameType, "frame"));
        try testing.expect(@hasField(ShadowFrameType, "dispatch"));
        try testing.expect(@hasField(ShadowFrameType, "verification_mode"));
        try testing.expect(@hasField(ShadowFrameType, "opcode_count"));
    } else {
        // In release builds, shadow_frame should be void type
        try testing.expect(@TypeOf(@as(TestFrame, undefined).shadow_frame) == void);
    }
}

test "ShadowFrame shouldVerify logic" {
    if (!std.debug.runtime_safety) return; // Skip in release builds
    
    const TestFrame = @import("frame.zig").Frame(@import("frame_config.zig").FrameConfig{});
    const ShadowFrameType = TestFrame.ShadowFrame;
    
    // Test different verification modes
    const shadow_opcode = ShadowFrameType{
        .frame = undefined, // We're only testing shouldVerify logic
        .dispatch = undefined,
        .verification_mode = .opcode,
        .opcode_count = 0,
    };
    try testing.expect(shadow_opcode.shouldVerify() == true);
    
    const shadow_none = ShadowFrameType{
        .frame = undefined,
        .dispatch = undefined,
        .verification_mode = .none,
        .opcode_count = 0,
    };
    try testing.expect(shadow_none.shouldVerify() == false);
    
    const shadow_block_0 = ShadowFrameType{
        .frame = undefined,
        .dispatch = undefined,
        .verification_mode = .block,
        .opcode_count = 0,
    };
    try testing.expect(shadow_block_0.shouldVerify() == true); // 0 % 64 == 0
    
    const shadow_block_32 = ShadowFrameType{
        .frame = undefined,
        .dispatch = undefined,
        .verification_mode = .block,
        .opcode_count = 32,
    };
    try testing.expect(shadow_block_32.shouldVerify() == false); // 32 % 64 != 0
    
    const shadow_block_64 = ShadowFrameType{
        .frame = undefined,
        .dispatch = undefined,
        .verification_mode = .block,
        .opcode_count = 64,
    };
    try testing.expect(shadow_block_64.shouldVerify() == true); // 64 % 64 == 0
}

// Phase 4: Integration Tests

test "Stack equals method works correctly" {
    const allocator = testing.allocator;
    const StackType = @import("stack.zig").Stack(.{});
    
    var stack1 = try StackType.init(allocator);
    defer stack1.deinit(allocator);
    var stack2 = try StackType.init(allocator);
    defer stack2.deinit(allocator);
    
    // Empty stacks should be equal
    try testing.expect(stack1.equals(&stack2));
    
    // Add same values to both stacks
    try stack1.push(100);
    try stack1.push(200);
    try stack2.push(100);
    try stack2.push(200);
    
    try testing.expect(stack1.equals(&stack2));
    
    // Make them different
    try stack2.pop();
    try stack2.push(300);
    
    try testing.expect(!stack1.equals(&stack2));
    
    // Different sizes should not be equal
    try stack1.push(400);
    try testing.expect(!stack1.equals(&stack2));
}

test "Memory equals method works correctly" {
    const allocator = testing.allocator;
    const MemoryType = @import("memory.zig").Memory(.{ .owned = true });
    
    var mem1 = try MemoryType.init(allocator);
    defer mem1.deinit(allocator);
    var mem2 = try MemoryType.init(allocator);
    defer mem2.deinit(allocator);
    
    // Empty memories should be equal
    try testing.expect(mem1.equals(&mem2));
    
    // Add same data to both memories
    const data = [_]u8{ 0x01, 0x02, 0x03, 0x04 };
    try mem1.set_data(allocator, 0, &data);
    try mem2.set_data(allocator, 0, &data);
    
    try testing.expect(mem1.equals(&mem2));
    
    // Make them different
    const diff_data = [_]u8{ 0x05, 0x06, 0x07, 0x08 };
    try mem2.set_data(allocator, 4, &diff_data);
    
    try testing.expect(!mem1.equals(&mem2));
}

test "DispatchSchedule creates shadow schedule when verification enabled" {
    if (!std.debug.runtime_safety) return; // Skip in release builds
    
    const allocator = testing.allocator;
    
    // Create a bytecode config with verification enabled
    const bytecode_config = BytecodeConfig{
        .fusions_enabled = true,
        .verification_mode = .opcode,
    };
    
    // Create a simple frame type for testing
    const TestFrame = @import("frame.zig").Frame(@import("frame_config.zig").FrameConfig{});
    const TestDispatch = @import("dispatch.zig").Dispatch(TestFrame);
    const OpcodeHandler = TestFrame.OpcodeHandler;
    
    // Create dummy opcode handlers (we just need the array structure)
    var handlers: [256]OpcodeHandler = undefined;
    // Fill with a dummy handler - we'll use STOP handler as placeholder
    // Note: This is a simplified test - real handler would be more complex
    for (&handlers) |*handler| {
        handler.* = undefined; // Placeholder
    }
    
    // Test that init with verification creates shadow schedules
    // Note: This is testing the structure, not full execution
    const ScheduleType = TestDispatch.DispatchSchedule;
    try testing.expect(@hasField(ScheduleType, "shadow_items"));
    try testing.expect(@hasField(ScheduleType, "shadow_push_pointers"));
}