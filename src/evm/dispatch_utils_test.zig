const std = @import("std");
const testing = std.testing;
const bytecode_mod = @import("bytecode.zig");
const Opcode = @import("opcode_data.zig").Opcode;
const OpcodeSynthetic = @import("opcode_synthetic.zig").OpcodeSynthetic;
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

test "calculateFirstBlockGas - empty bytecode returns 0" {
    const allocator = testing.allocator;
    
    const Bytecode = bytecode_mod.Bytecode(TestFrame.BytecodeConfig);
    var bytecode = try Bytecode.init(allocator, &[_]u8{});
    defer bytecode.deinit();

    const gas = dispatch_utils.calculateFirstBlockGas(&bytecode);
    try testing.expect(gas == 0);
}

test "calculateFirstBlockGas - single STOP instruction" {
    const allocator = testing.allocator;
    
    const Bytecode = bytecode_mod.Bytecode(TestFrame.BytecodeConfig);
    var bytecode = try Bytecode.init(allocator, &[_]u8{@intFromEnum(Opcode.STOP)});
    defer bytecode.deinit();

    const gas = dispatch_utils.calculateFirstBlockGas(&bytecode);
    try testing.expect(gas == 0); // STOP has 0 gas cost
}

test "calculateFirstBlockGas - block ending with JUMPDEST" {
    const allocator = testing.allocator;
    
    const Bytecode = bytecode_mod.Bytecode(TestFrame.BytecodeConfig);
    var bytecode = try Bytecode.init(allocator, &[_]u8{
        @intFromEnum(Opcode.PUSH1), 42, // 3 gas
        @intFromEnum(Opcode.ADD), // 3 gas
        @intFromEnum(Opcode.JUMPDEST), // 1 gas (but terminates block)
    });
    defer bytecode.deinit();

    const gas = dispatch_utils.calculateFirstBlockGas(&bytecode);
    try testing.expect(gas == 6); // PUSH1(3) + ADD(3), JUMPDEST not included
}

test "calculateFirstBlockGas - block ending with JUMP" {
    const allocator = testing.allocator;
    
    const Bytecode = bytecode_mod.Bytecode(TestFrame.BytecodeConfig);
    var bytecode = try Bytecode.init(allocator, &[_]u8{
        @intFromEnum(Opcode.PUSH1), 10, // 3 gas
        @intFromEnum(Opcode.PUSH1), 20, // 3 gas
        @intFromEnum(Opcode.MUL), // 5 gas
        @intFromEnum(Opcode.JUMP), // 8 gas
    });
    defer bytecode.deinit();

    const gas = dispatch_utils.calculateFirstBlockGas(&bytecode);
    try testing.expect(gas == 19); // 3 + 3 + 5 + 8
}

test "calculateFirstBlockGas - overflow handling" {
    const allocator = testing.allocator;
    
    // Create bytecode that would overflow gas calculation
    var large_bytecode = std.ArrayList(u8){};
    defer large_bytecode.deinit(allocator);

    // Add many expensive operations that would overflow
    for (0..10000) |_| {
        try large_bytecode.append(allocator, @intFromEnum(Opcode.SSTORE)); // Very expensive operation
    }

    const Bytecode = bytecode_mod.Bytecode(TestFrame.BytecodeConfig);
    var bytecode = try Bytecode.init(allocator, large_bytecode.items);
    defer bytecode.deinit();

    const gas = dispatch_utils.calculateFirstBlockGas(&bytecode);
    // Should not overflow - returns current gas on overflow
    try testing.expect(gas < std.math.maxInt(u64));
}

test "getSyntheticOpcode - maps fusion types correctly" {
    // Test inline variants
    try testing.expect(dispatch_utils.getSyntheticOpcode(.push_add, true) == @intFromEnum(OpcodeSynthetic.PUSH_ADD_INLINE));
    try testing.expect(dispatch_utils.getSyntheticOpcode(.push_mul, true) == @intFromEnum(OpcodeSynthetic.PUSH_MUL_INLINE));
    try testing.expect(dispatch_utils.getSyntheticOpcode(.push_sub, true) == @intFromEnum(OpcodeSynthetic.PUSH_SUB_INLINE));
    try testing.expect(dispatch_utils.getSyntheticOpcode(.push_div, true) == @intFromEnum(OpcodeSynthetic.PUSH_DIV_INLINE));
    try testing.expect(dispatch_utils.getSyntheticOpcode(.push_and, true) == @intFromEnum(OpcodeSynthetic.PUSH_AND_INLINE));
    try testing.expect(dispatch_utils.getSyntheticOpcode(.push_or, true) == @intFromEnum(OpcodeSynthetic.PUSH_OR_INLINE));
    try testing.expect(dispatch_utils.getSyntheticOpcode(.push_xor, true) == @intFromEnum(OpcodeSynthetic.PUSH_XOR_INLINE));
    try testing.expect(dispatch_utils.getSyntheticOpcode(.push_jump, true) == @intFromEnum(OpcodeSynthetic.PUSH_JUMP_INLINE));
    try testing.expect(dispatch_utils.getSyntheticOpcode(.push_jumpi, true) == @intFromEnum(OpcodeSynthetic.PUSH_JUMPI_INLINE));
}

test "getSyntheticOpcode - inline vs pointer variants" {
    // Test pointer variants  
    try testing.expect(dispatch_utils.getSyntheticOpcode(.push_add, false) == @intFromEnum(OpcodeSynthetic.PUSH_ADD_POINTER));
    try testing.expect(dispatch_utils.getSyntheticOpcode(.push_mul, false) == @intFromEnum(OpcodeSynthetic.PUSH_MUL_POINTER));
    try testing.expect(dispatch_utils.getSyntheticOpcode(.push_sub, false) == @intFromEnum(OpcodeSynthetic.PUSH_SUB_POINTER));
    try testing.expect(dispatch_utils.getSyntheticOpcode(.push_div, false) == @intFromEnum(OpcodeSynthetic.PUSH_DIV_POINTER));
    try testing.expect(dispatch_utils.getSyntheticOpcode(.push_and, false) == @intFromEnum(OpcodeSynthetic.PUSH_AND_POINTER));
    try testing.expect(dispatch_utils.getSyntheticOpcode(.push_or, false) == @intFromEnum(OpcodeSynthetic.PUSH_OR_POINTER));
    try testing.expect(dispatch_utils.getSyntheticOpcode(.push_xor, false) == @intFromEnum(OpcodeSynthetic.PUSH_XOR_POINTER));
    try testing.expect(dispatch_utils.getSyntheticOpcode(.push_jump, false) == @intFromEnum(OpcodeSynthetic.PUSH_JUMP_POINTER));
    try testing.expect(dispatch_utils.getSyntheticOpcode(.push_jumpi, false) == @intFromEnum(OpcodeSynthetic.PUSH_JUMPI_POINTER));
}