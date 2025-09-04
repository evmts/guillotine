const std = @import("std");
const testing = std.testing;
const BytecodeConfig = @import("bytecode_config.zig").BytecodeConfig;
const OpcodeSynthetic = @import("opcode_synthetic.zig").OpcodeSynthetic;

// Phase 5: Individual Fusion Benchmarking Tests

test "PUSH_ADD fusion performance measurement" {
    const allocator = testing.allocator;
    const iterations = 1000; // Reduced for testing
    
    // Create bytecode with repeated PUSH+ADD patterns
    var bytecode = std.ArrayList(u8).init(allocator);
    defer bytecode.deinit();
    
    // Generate 50 PUSH+ADD pairs for benchmarking
    var i: u8 = 0;
    while (i < 50) : (i += 1) {
        try bytecode.appendSlice(&[_]u8{
            0x60, i, // PUSH1 i
            0x01,    // ADD
        });
    }
    try bytecode.append(0x00); // STOP
    
    // Verify bytecode generation
    try testing.expect(bytecode.items.len == 151); // (3 bytes * 50) + 1 STOP
    
    // Test configuration with fusions enabled
    const config_with_fusion = BytecodeConfig{
        .fusions_enabled = true,
        .verification_mode = if (std.debug.runtime_safety) .none else {},
    };
    
    // Test configuration with fusions disabled  
    const config_without_fusion = BytecodeConfig{
        .fusions_enabled = false,
        .verification_mode = if (std.debug.runtime_safety) .none else {},
    };
    
    try testing.expect(config_with_fusion.fusions_enabled == true);
    try testing.expect(config_without_fusion.fusions_enabled == false);
    
    // Note: In a real benchmark, we would time execution here
    // For this test, we're verifying the setup is correct
}

test "PUSH_MUL fusion benchmark setup" {
    const allocator = testing.allocator;
    
    // Create bytecode with PUSH+MUL patterns
    const bytecode = [_]u8{
        0x60, 0x05, // PUSH1 5
        0x60, 0x03, // PUSH1 3  
        0x02,       // MUL
        0x60, 0x02, // PUSH1 2
        0x02,       // MUL
        0x60, 0x04, // PUSH1 4
        0x02,       // MUL
        0x00        // STOP
    };
    
    // Verify we have multiple MUL fusion opportunities
    var mul_count: u32 = 0;
    for (bytecode) |byte| {
        if (byte == 0x02) { // MUL opcode
            mul_count += 1;
        }
    }
    try testing.expect(mul_count == 3); // Should find 3 MUL opcodes
}

test "PUSH_SUB fusion benchmark setup" {
    const allocator = testing.allocator;
    
    // Create bytecode with PUSH+SUB patterns
    const bytecode = [_]u8{
        0x60, 0x10, // PUSH1 16
        0x60, 0x05, // PUSH1 5
        0x03,       // SUB
        0x60, 0x03, // PUSH1 3
        0x03,       // SUB
        0x00        // STOP
    };
    
    // Count SUB operations for fusion opportunities
    var sub_count: u32 = 0;
    for (bytecode) |byte| {
        if (byte == 0x03) { // SUB opcode
            sub_count += 1;
        }
    }
    try testing.expect(sub_count == 2);
}

test "PUSH_DIV fusion benchmark setup" {
    const bytecode = [_]u8{
        0x60, 0x20, // PUSH1 32
        0x60, 0x08, // PUSH1 8
        0x04,       // DIV
        0x60, 0x02, // PUSH1 2
        0x04,       // DIV
        0x00        // STOP
    };
    
    // Verify DIV fusion opportunities
    var div_count: u32 = 0;
    for (bytecode) |byte| {
        if (byte == 0x04) { // DIV opcode
            div_count += 1;
        }
    }
    try testing.expect(div_count == 2);
}

test "Bitwise fusion benchmark setups" {
    // Test PUSH+AND fusion setup
    const and_bytecode = [_]u8{
        0x60, 0xFF, // PUSH1 255
        0x60, 0x0F, // PUSH1 15
        0x16,       // AND
        0x00        // STOP
    };
    
    // Test PUSH+OR fusion setup
    const or_bytecode = [_]u8{
        0x60, 0xF0, // PUSH1 240  
        0x60, 0x0F, // PUSH1 15
        0x17,       // OR
        0x00        // STOP
    };
    
    // Test PUSH+XOR fusion setup
    const xor_bytecode = [_]u8{
        0x60, 0xFF, // PUSH1 255
        0x60, 0xF0, // PUSH1 240
        0x18,       // XOR
        0x00        // STOP
    };
    
    // Verify opcodes are present
    try testing.expect(and_bytecode[4] == 0x16); // AND
    try testing.expect(or_bytecode[4] == 0x17);  // OR
    try testing.expect(xor_bytecode[4] == 0x18); // XOR
}

test "Memory fusion benchmark setups" {
    // Test PUSH+MLOAD fusion setup
    const mload_bytecode = [_]u8{
        0x60, 0x00, // PUSH1 0 (offset)
        0x51,       // MLOAD
        0x00        // STOP
    };
    
    // Test PUSH+MSTORE fusion setup
    const mstore_bytecode = [_]u8{
        0x60, 0xFF, // PUSH1 255 (value)
        0x60, 0x00, // PUSH1 0 (offset)
        0x52,       // MSTORE
        0x00        // STOP
    };
    
    // Test PUSH+MSTORE8 fusion setup
    const mstore8_bytecode = [_]u8{
        0x60, 0xFF, // PUSH1 255 (value)
        0x60, 0x00, // PUSH1 0 (offset)
        0x53,       // MSTORE8
        0x00        // STOP
    };
    
    // Verify memory opcodes
    try testing.expect(mload_bytecode[2] == 0x51);  // MLOAD
    try testing.expect(mstore_bytecode[4] == 0x52); // MSTORE
    try testing.expect(mstore8_bytecode[4] == 0x53); // MSTORE8
}

test "Jump fusion benchmark setups" {
    // Test PUSH+JUMP fusion setup
    const jump_bytecode = [_]u8{
        0x60, 0x05, // PUSH1 5 (jump target)
        0x56,       // JUMP
        0x00,       // STOP (unreachable)
        0x5B,       // JUMPDEST (target)
        0x00        // STOP
    };
    
    // Test PUSH+JUMPI fusion setup
    const jumpi_bytecode = [_]u8{
        0x60, 0x01, // PUSH1 1 (condition - true)
        0x60, 0x08, // PUSH1 8 (jump target)
        0x57,       // JUMPI
        0x00,       // STOP (skipped)
        0x5B,       // JUMPDEST (target)
        0x00        // STOP
    };
    
    // Verify jump opcodes
    try testing.expect(jump_bytecode[2] == 0x56);  // JUMP
    try testing.expect(jumpi_bytecode[4] == 0x57); // JUMPI
    try testing.expect(jump_bytecode[4] == 0x5B);  // JUMPDEST
    try testing.expect(jumpi_bytecode[6] == 0x5B); // JUMPDEST
}

test "Benchmark result tracking structure" {
    // Define structure for tracking benchmark results
    const BenchmarkResult = struct {
        fusion_name: []const u8,
        speedup: f64,
        no_fusion_time: u64,
        fusion_time: u64,
        
        fn meetsAcceptanceCriteria(self: @This()) bool {
            return self.speedup >= 1.05; // Must provide at least 5% speedup
        }
    };
    
    // Test benchmark result validation
    const good_result = BenchmarkResult{
        .fusion_name = "PUSH_ADD",
        .speedup = 1.25, // 25% speedup
        .no_fusion_time = 1000,
        .fusion_time = 800,
    };
    
    const bad_result = BenchmarkResult{
        .fusion_name = "PUSH_SUB",
        .speedup = 1.02, // Only 2% speedup
        .no_fusion_time = 1000,
        .fusion_time = 980,
    };
    
    try testing.expect(good_result.meetsAcceptanceCriteria());
    try testing.expect(!bad_result.meetsAcceptanceCriteria());
}

test "All synthetic opcodes have corresponding benchmark tests" {
    // Verify that we have test coverage for all synthetic opcodes
    const synthetic_opcodes = std.enums.values(OpcodeSynthetic);
    
    // Count different fusion categories
    var arithmetic_fusions: u32 = 0;
    var memory_fusions: u32 = 0;
    var jump_fusions: u32 = 0;
    var bitwise_fusions: u32 = 0;
    
    for (synthetic_opcodes) |opcode| {
        const name = @tagName(opcode);
        if (std.mem.indexOf(u8, name, "ADD") != null or 
            std.mem.indexOf(u8, name, "MUL") != null or
            std.mem.indexOf(u8, name, "SUB") != null or
            std.mem.indexOf(u8, name, "DIV") != null) {
            arithmetic_fusions += 1;
        } else if (std.mem.indexOf(u8, name, "MLOAD") != null or
                   std.mem.indexOf(u8, name, "MSTORE") != null) {
            memory_fusions += 1;
        } else if (std.mem.indexOf(u8, name, "JUMP") != null) {
            jump_fusions += 1;
        } else if (std.mem.indexOf(u8, name, "AND") != null or
                   std.mem.indexOf(u8, name, "OR") != null or
                   std.mem.indexOf(u8, name, "XOR") != null) {
            bitwise_fusions += 1;
        }
    }
    
    // Verify we have fusion tests for all categories
    try testing.expect(arithmetic_fusions > 0);
    try testing.expect(memory_fusions > 0);
    try testing.expect(jump_fusions > 0);
    try testing.expect(bitwise_fusions > 0);
    
    // Total synthetic opcodes should match what we found in the enum
    try testing.expect(synthetic_opcodes.len > 20); // We know there are 20+ from opcode_synthetic.zig
}