const std = @import("std");
const SimpleAnalysis = @import("evm/analysis2.zig").SimpleAnalysis;
const Opcode = @import("opcodes/opcode.zig").Enum;

test "SimpleAnalysis correctly maps instructions and skips PUSH data" {
    const allocator = std.testing.allocator;
    
    // Bytecode: PUSH2 0x5B00, JUMPDEST, STOP
    // The 0x5B in PUSH data should be skipped
    const code = &[_]u8{
        0x61, 0x5B, 0x00,  // PUSH2 0x5B00 (0x5B is at position 1, part of push data)
        0x5B,              // JUMPDEST at position 3 (actual instruction)
        0x00,              // STOP at position 4
    };
    
    const result = try SimpleAnalysis.analyze(allocator, code);
    defer result.analysis.deinit(allocator);
    defer allocator.free(result.metadata);
    
    // Verify instruction mapping: position 1 and 2 should NOT be instruction starts
    try std.testing.expectEqual(SimpleAnalysis.MAX_USIZE, result.analysis.getInstIdx(1));
    try std.testing.expectEqual(SimpleAnalysis.MAX_USIZE, result.analysis.getInstIdx(2));
    
    // Positions 0, 3, and 4 should be instruction starts
    try std.testing.expectEqual(@as(u16, 0), result.analysis.getInstIdx(0)); // PUSH2
    try std.testing.expectEqual(@as(u16, 1), result.analysis.getInstIdx(3)); // JUMPDEST
    try std.testing.expectEqual(@as(u16, 2), result.analysis.getInstIdx(4)); // STOP
    
    // Verify total instruction count
    try std.testing.expectEqual(@as(u16, 3), result.analysis.inst_count);
}

test "SimpleAnalysis with basic EVM sequence" {
    const allocator = std.testing.allocator;
    
    // Code from failing test: 
    // 0x60 0x80 0x60 0x40 0x52 0x34 0x80 0x15 0x61 0x0 0xf
    const code = &[_]u8{
        0x60, 0x80,  // PUSH1 0x80 (pos 0)
        0x60, 0x40,  // PUSH1 0x40 (pos 2)
        0x52,        // MSTORE (pos 4)
        0x34,        // CALLVALUE (pos 5)
        0x80,        // DUP1 (pos 6)
        0x15,        // ISZERO (pos 7)
        0x61, 0x00, 0x0f,  // PUSH2 0x000f (pos 8)
    };
    
    const result = try SimpleAnalysis.analyze(allocator, code);
    defer result.analysis.deinit(allocator);
    defer allocator.free(result.metadata);
    
    // Verify instruction mapping for each actual instruction start
    try std.testing.expectEqual(@as(u16, 0), result.analysis.getInstIdx(0)); // PUSH1 0x80
    try std.testing.expectEqual(@as(u16, 1), result.analysis.getInstIdx(2)); // PUSH1 0x40
    try std.testing.expectEqual(@as(u16, 2), result.analysis.getInstIdx(4)); // MSTORE
    try std.testing.expectEqual(@as(u16, 3), result.analysis.getInstIdx(5)); // CALLVALUE
    try std.testing.expectEqual(@as(u16, 4), result.analysis.getInstIdx(6)); // DUP1
    try std.testing.expectEqual(@as(u16, 5), result.analysis.getInstIdx(7)); // ISZERO
    try std.testing.expectEqual(@as(u16, 6), result.analysis.getInstIdx(8)); // PUSH2
    
    // Positions 1, 3, 9, 10 should not be instruction starts (PUSH data)
    try std.testing.expectEqual(SimpleAnalysis.MAX_USIZE, result.analysis.getInstIdx(1));
    try std.testing.expectEqual(SimpleAnalysis.MAX_USIZE, result.analysis.getInstIdx(3));
    try std.testing.expectEqual(SimpleAnalysis.MAX_USIZE, result.analysis.getInstIdx(9));
    try std.testing.expectEqual(SimpleAnalysis.MAX_USIZE, result.analysis.getInstIdx(10));
    
    try std.testing.expectEqual(@as(u16, 7), result.analysis.inst_count);
}

test "SimpleAnalysis with ERC20 constructor pattern" {
    const allocator = std.testing.allocator;
    
    // Typical Solidity constructor pattern
    const code = &[_]u8{
        0x60, 0x80,     // PUSH1 0x80 (pos 0)
        0x60, 0x40,     // PUSH1 0x40 (pos 2)  
        0x52,           // MSTORE (pos 4)
        0x34,           // CALLVALUE (pos 5)
        0x80,           // DUP1 (pos 6)
        0x15,           // ISZERO (pos 7)
        0x60, 0x0F,     // PUSH1 0x0F (pos 8)
        0x57,           // JUMPI (pos 10)
        0x60, 0x00,     // PUSH1 0x00 (pos 11)
        0x80,           // DUP1 (pos 13)
        0xFD,           // REVERT (pos 14)
        0x5B,           // JUMPDEST (pos 15)
        0x50,           // POP (pos 16)
        0x60, 0x00,     // PUSH1 0x00 (pos 17)
        0x00,           // STOP (pos 19)
    };
    
    const result = try SimpleAnalysis.analyze(allocator, code);
    defer result.analysis.deinit(allocator);
    defer allocator.free(result.metadata);
    
    // Verify key instruction positions
    try std.testing.expectEqual(@as(u16, 0), result.analysis.getInstIdx(0));  // PUSH1 0x80
    try std.testing.expectEqual(@as(u16, 1), result.analysis.getInstIdx(2));  // PUSH1 0x40
    try std.testing.expectEqual(@as(u16, 2), result.analysis.getInstIdx(4));  // MSTORE
    try std.testing.expectEqual(@as(u16, 9), result.analysis.getInstIdx(15)); // JUMPDEST
    try std.testing.expectEqual(@as(u16, 12), result.analysis.getInstIdx(19)); // STOP
    
    // Verify PUSH data positions are not instruction starts
    try std.testing.expectEqual(SimpleAnalysis.MAX_USIZE, result.analysis.getInstIdx(1));  // PUSH1 data
    try std.testing.expectEqual(SimpleAnalysis.MAX_USIZE, result.analysis.getInstIdx(3));  // PUSH1 data
    try std.testing.expectEqual(SimpleAnalysis.MAX_USIZE, result.analysis.getInstIdx(9));  // PUSH1 data
    try std.testing.expectEqual(SimpleAnalysis.MAX_USIZE, result.analysis.getInstIdx(12)); // PUSH1 data
    try std.testing.expectEqual(SimpleAnalysis.MAX_USIZE, result.analysis.getInstIdx(18)); // PUSH1 data
    
    // Total instruction count should be 13
    try std.testing.expectEqual(@as(u16, 13), result.analysis.inst_count);
}