const std = @import("std");
const testing = std.testing;
const primitives = @import("primitives");
const evm_mod = @import("evm");
const log = @import("log");

// Import specific types we need
const bytecode_mod = evm_mod.bytecode;
const Opcode = evm_mod.opcodes.Opcode;
const OpcodeSynthetic = evm_mod.opcodes.OpcodeSynthetic;

// Helper to create Bytecode type with fusion enabled
const BytecodeWithFusion = evm_mod.Bytecode(.{
    .max_bytecode_size = 1024,
    .fusions_enabled = true,
});

// Note: Constant folding tests removed - compiler handles constant folding

// Test multi-PUSH patterns
test "multi-PUSH: two consecutive PUSH1 operations should fuse" {
    const allocator = testing.allocator;
    
    // Bytecode: PUSH1 5, PUSH1 3
    const bytecode = [_]u8{
        0x60, 0x05, // PUSH1 5
        0x60, 0x03, // PUSH1 3
    };
    
    var bc = try BytecodeWithFusion.init(allocator, &bytecode);
    defer bc.deinit();
    
    const fusion_data = bc.getFusionData(0);
    try testing.expect(fusion_data == .multi_push);
    try testing.expectEqual(@as(u8, 2), fusion_data.multi_push.count);
    try testing.expectEqual(@as(u8, 4), fusion_data.multi_push.original_length);
}

test "multi-PUSH: three consecutive PUSH operations should fuse" {
    const allocator = testing.allocator;
    
    // Bytecode: PUSH1 5, PUSH2 0x1234, PUSH1 3
    const bytecode = [_]u8{
        0x60, 0x05,       // PUSH1 5
        0x61, 0x12, 0x34, // PUSH2 0x1234
        0x60, 0x03,       // PUSH1 3
    };
    
    var bc = try BytecodeWithFusion.init(allocator, &bytecode);
    defer bc.deinit();
    
    const fusion_data = bc.getFusionData(0);
    try testing.expect(fusion_data == .multi_push);
    try testing.expectEqual(@as(u8, 3), fusion_data.multi_push.count);
    try testing.expectEqual(@as(u8, 7), fusion_data.multi_push.original_length);
}

// Test multi-POP patterns
test "multi-POP: two consecutive POP operations should fuse" {
    const allocator = testing.allocator;
    
    // Bytecode: POP, POP
    const bytecode = [_]u8{
        0x50, // POP
        0x50, // POP
    };
    
    var bc = try BytecodeWithFusion.init(allocator, &bytecode);
    defer bc.deinit();
    
    const fusion_data = bc.getFusionData(0);
    try testing.expect(fusion_data == .multi_pop);
    try testing.expectEqual(@as(u8, 2), fusion_data.multi_pop.count);
    try testing.expectEqual(@as(u8, 2), fusion_data.multi_pop.original_length);
}

test "multi-POP: three consecutive POP operations should fuse" {
    const allocator = testing.allocator;
    
    // Bytecode: POP, POP, POP
    const bytecode = [_]u8{
        0x50, // POP
        0x50, // POP
        0x50, // POP
    };
    
    var bc = try BytecodeWithFusion.init(allocator, &bytecode);
    defer bc.deinit();
    
    const fusion_data = bc.getFusionData(0);
    try testing.expect(fusion_data == .multi_pop);
    try testing.expectEqual(@as(u8, 3), fusion_data.multi_pop.count);
    try testing.expectEqual(@as(u8, 3), fusion_data.multi_pop.original_length);
}

// Test ISZERO-JUMPI pattern
test "ISZERO-JUMPI: pattern should be detected and fused" {
    const allocator = testing.allocator;
    
    // Bytecode: ISZERO, PUSH2 target, JUMPI
    const bytecode = [_]u8{
        0x15,             // ISZERO
        0x61, 0x00, 0x08, // PUSH2 0x0008
        0x57,             // JUMPI
    };
    
    var bc = try BytecodeWithFusion.init(allocator, &bytecode);
    defer bc.deinit();
    
    const fusion_data = bc.getFusionData(0);
    try testing.expect(fusion_data == .iszero_jumpi);
    try testing.expectEqual(@as(u16, 0x0008), fusion_data.iszero_jumpi.target);
    try testing.expectEqual(@as(u8, 5), fusion_data.iszero_jumpi.original_length);
}

// Test DUP2-MSTORE-PUSH pattern
test "DUP2-MSTORE-PUSH: pattern should be detected and fused" {
    const allocator = testing.allocator;
    
    // Bytecode: DUP2, MSTORE, PUSH1 value
    const bytecode = [_]u8{
        0x81,       // DUP2
        0x52,       // MSTORE
        0x60, 0x42, // PUSH1 0x42
    };
    
    var bc = try BytecodeWithFusion.init(allocator, &bytecode);
    defer bc.deinit();
    
    const fusion_data = bc.getFusionData(0);
    try testing.expect(fusion_data == .dup2_mstore_push);
    try testing.expectEqual(@as(u8, 0x42), fusion_data.dup2_mstore_push.push_value);
    try testing.expectEqual(@as(u8, 4), fusion_data.dup2_mstore_push.original_length);
}

// Handler execution test will be added after implementing handlers

// Test priority ordering - longer patterns should be detected first
test "pattern priority: ISZERO-JUMPI detected before other patterns" {
    const allocator = testing.allocator;
    
    // This bytecode contains ISZERO-JUMPI pattern
    const bytecode = [_]u8{
        0x15,       // ISZERO
        0x60, 0x08, // PUSH1 8 (jump target)
        0x57,       // JUMPI
        0x00,       // STOP
    };
    
    var bc = try BytecodeWithFusion.init(allocator, &bytecode);
    defer bc.deinit();
    
    // Should detect ISZERO-JUMPI fusion
    const fusion_data = bc.getFusionData(0);
    try testing.expect(fusion_data == .iszero_jumpi);
    try testing.expectEqual(@as(u256, 8), fusion_data.iszero_jumpi.target);
}