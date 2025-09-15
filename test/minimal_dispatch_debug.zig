const std = @import("std");

// Minimal reproduction of the dispatch issue
test "minimal dispatch debug" {
    // The exact problematic bytecode sequence from CALL test
    const test_bytecode = &[_]u8{
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
        0x60, // PC=13: PUSH1
        0x20, // PC=14: value 32
        0x60, // PC=15: PUSH1
        0x00, // PC=16: value 0
        0xf3, // PC=17: RETURN
    };

    std.debug.print("\n=== Bytecode Analysis ===\n", .{});
    std.debug.print("Looking for PUSH+MSTORE patterns:\n", .{});

    var i: usize = 0;
    while (i < test_bytecode.len) {
        const opcode = test_bytecode[i];

        // Check for PUSH1 + MSTORE pattern
        if (opcode == 0x60 and i + 2 < test_bytecode.len) {
            const value = test_bytecode[i + 1];
            const next_op = test_bytecode[i + 2];

            if (next_op == 0x52) { // MSTORE
                std.debug.print("✓ Found PUSH1+MSTORE fusion at PC={d}: PUSH1 {d} MSTORE\n", .{i, value});
                i += 3; // Skip the fused sequence
                continue;
            }
        }

        // Check for PUSH0 (no fusion possible)
        if (opcode == 0x5f) {
            std.debug.print("  PC={d}: PUSH0 (no fusion)\n", .{i});
        }

        i += 1;

        // Skip PUSH immediate data
        if (opcode >= 0x60 and opcode <= 0x7f) {
            const push_size = opcode - 0x5f;
            i += push_size;
        }
    }

    std.debug.print("\n=== Key Finding ===\n", .{});
    std.debug.print("PUSH1+MSTORE fusion SHOULD occur at PC=10-12\n", .{});
    std.debug.print("But Frame is incorrectly reporting it at PC=0 (which is PUSH0)\n", .{});
    std.debug.print("This suggests the dispatch schedule indices are misaligned.\n", .{});
}