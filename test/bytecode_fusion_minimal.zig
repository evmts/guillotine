const std = @import("std");

test "minimal bytecode fusion detection" {
    std.testing.log_level = .debug;

    std.debug.print("\n=== Minimal fusion test ===\n", .{});

    // Simple bytecode with PUSH1+MSTORE that should fuse
    const simple_fusion = &[_]u8{
        0x60, // PC=0: PUSH1
        0x00, // PC=1: value 0
        0x52, // PC=2: MSTORE
    };

    // The problematic CALL bytecode
    const call_bytecode = &[_]u8{
        0x5f, // PC=0: PUSH0
        0x5f, // PC=1: PUSH0
        0x5f, // PC=2: PUSH0
        0x5f, // PC=3: PUSH0
        0x5f, // PC=4: PUSH0
        0x30, // PC=5: ADDRESS
        0x61, // PC=6: PUSH2
        0x27, // PC=7: value byte 1
        0x10, // PC=8: value byte 2
        0xf1, // PC=9: CALL
        0x60, // PC=10: PUSH1
        0x00, // PC=11: value 0
        0x52, // PC=12: MSTORE
    };

    std.debug.print("\nAnalyzing simple fusion bytecode:\n", .{});
    for (simple_fusion, 0..) |byte, i| {
        std.debug.print("  PC={}: 0x{x:0>2}\n", .{i, byte});
    }

    std.debug.print("\nAnalyzing CALL bytecode:\n", .{});
    for (call_bytecode, 0..) |byte, i| {
        std.debug.print("  PC={}: 0x{x:0>2}", .{i, byte});
        if (i == 10) std.debug.print(" <- PUSH1+MSTORE fusion should be here", .{});
        std.debug.print("\n", .{});
    }

    std.debug.print("\nFusion should occur at PC=10-12 in CALL bytecode, NOT at PC=0\n", .{});
}