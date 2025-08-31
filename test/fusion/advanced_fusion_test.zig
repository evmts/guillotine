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

// Test constant folding patterns
test "constant folding: PUSH1 5, PUSH1 3, ADD should fold to PUSH 8" {
    const allocator = testing.allocator;
    
    // Bytecode: PUSH1 5, PUSH1 3, ADD
    const bytecode = [_]u8{
        0x60, 0x05, // PUSH1 5
        0x60, 0x03, // PUSH1 3
        0x01,       // ADD
    };
    
    // Create bytecode analyzer with fusion enabled
    var bc = try BytecodeWithFusion.init(allocator, &bytecode);
    defer bc.deinit();
    
    // Check that the pattern is detected as a fusion candidate
    const fusion_data = bc.getFusionData(0);
    try testing.expect(fusion_data == .constant_fold);
    try testing.expectEqual(@as(u256, 8), fusion_data.constant_fold.value);
    try testing.expectEqual(@as(u8, 5), fusion_data.constant_fold.original_length);
}

test "constant folding: PUSH1 10, PUSH1 2, SUB should fold to PUSH 8" {
    const allocator = testing.allocator;
    
    // Bytecode: PUSH1 10, PUSH1 2, SUB
    const bytecode = [_]u8{
        0x60, 0x0A, // PUSH1 10
        0x60, 0x02, // PUSH1 2
        0x03,       // SUB
    };
    
    var bc = try BytecodeWithFusion.init(allocator, &bytecode);
    defer bc.deinit();
    
    const fusion_data = bc.getFusionData(0);
    try testing.expect(fusion_data == .constant_fold);
    try testing.expectEqual(@as(u256, 8), fusion_data.constant_fold.value);
    try testing.expectEqual(@as(u8, 5), fusion_data.constant_fold.original_length);
}

test "constant folding: PUSH1 4, PUSH1 2, MUL should fold to PUSH 8" {
    const allocator = testing.allocator;
    
    // Bytecode: PUSH1 4, PUSH1 2, MUL
    const bytecode = [_]u8{
        0x60, 0x04, // PUSH1 4
        0x60, 0x02, // PUSH1 2
        0x02,       // MUL
    };
    
    var bc = try BytecodeWithFusion.init(allocator, &bytecode);
    defer bc.deinit();
    
    const fusion_data = bc.getFusionData(0);
    try testing.expect(fusion_data == .constant_fold);
    try testing.expectEqual(@as(u256, 8), fusion_data.constant_fold.value);
    try testing.expectEqual(@as(u8, 5), fusion_data.constant_fold.original_length);
}

test "constant folding: complex pattern PUSH1 4, PUSH1 2, PUSH1 3, SHL, SUB" {
    const allocator = testing.allocator;
    
    // Bytecode: PUSH1 4, PUSH1 2, PUSH1 3, SHL, SUB
    // This computes: 4 - (2 << 3) = 4 - 16 = -12 (wrapping to large positive)
    const bytecode = [_]u8{
        0x60, 0x04, // PUSH1 4
        0x60, 0x02, // PUSH1 2
        0x60, 0x03, // PUSH1 3
        0x1B,       // SHL (correct opcode)
        0x03,       // SUB
    };
    
    var bc = try BytecodeWithFusion.init(allocator, &bytecode);
    defer bc.deinit();
    
    const fusion_data = bc.getFusionData(0);
    try testing.expect(fusion_data == .constant_fold);
    // 4 - 16 with wrapping arithmetic
    const expected: u256 = @as(u256, 4) -% @as(u256, 16);
    try testing.expectEqual(expected, fusion_data.constant_fold.value);
    try testing.expectEqual(@as(u8, 8), fusion_data.constant_fold.original_length);
}

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
test "pattern priority: longer patterns detected before shorter ones" {
    const allocator = testing.allocator;
    
    // This bytecode could match either:
    // 1. 3-PUSH fusion (PUSH1, PUSH1, PUSH1)
    // 2. Constant folding (PUSH1 5, PUSH1 3, ADD)
    // Constant folding should win because it's checked first
    const bytecode = [_]u8{
        0x60, 0x05, // PUSH1 5
        0x60, 0x03, // PUSH1 3
        0x01,       // ADD
        0x60, 0x02, // PUSH1 2
    };
    
    var bc = try BytecodeWithFusion.init(allocator, &bytecode);
    defer bc.deinit();
    
    // Should detect constant folding, not multi-push
    const fusion_data = bc.getFusionData(0);
    try testing.expect(fusion_data == .constant_fold);
    try testing.expectEqual(@as(u256, 8), fusion_data.constant_fold.value);
}