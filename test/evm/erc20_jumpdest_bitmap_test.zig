const std = @import("std");
const evm = @import("evm");

test "check ERC20 jumpdest bitmap" {
    const allocator = std.testing.allocator;

    // The exact problematic bytecode from ERC20
    const bytecode = [_]u8{
        0x60, 0x80, // PUSH1 0x80
        0x60, 0x40, // PUSH1 0x40  
        0x52,       // MSTORE (position 4)
        0x34,       // CALLVALUE (position 5)
        0x80,       // DUP1 (position 6)
        0x15,       // ISZERO (position 7)
        0x61, 0x00, 0x0f, // PUSH2 0x000f (position 8-10)
        0x57,       // JUMPI (position 11)
        0x5f,       // PUSH0 (position 12)
        0x5f,       // PUSH0 (position 13)
        0xfd,       // REVERT (position 14)
        0x5b,       // JUMPDEST (position 15)
        0x50,       // POP (position 16)
        0x00,       // STOP (position 17)
    };

    // Create code bitmap to identify JUMPDESTs
    const createCodeBitmap = @import("evm").createCodeBitmap;
    var code_bitmap = try createCodeBitmap(allocator, &bytecode);
    defer code_bitmap.deinit();

    std.debug.print("\n=== Code Bitmap ===\n", .{});
    for (0..bytecode.len) |pc| {
        if (!code_bitmap.isSet(pc)) {
            std.debug.print("PC {}: DATA (opcode=0x{x})\n", .{ pc, bytecode[pc] });
        } else {
            const opcode_name = switch (bytecode[pc]) {
                0x00 => "STOP",
                0x15 => "ISZERO",
                0x34 => "CALLVALUE",
                0x50 => "POP",
                0x52 => "MSTORE",
                0x57 => "JUMPI",
                0x5b => "JUMPDEST",
                0x5f => "PUSH0",
                0x60 => "PUSH1",
                0x61 => "PUSH2",
                0x80 => "DUP1",
                0xfd => "REVERT",
                else => "UNKNOWN",
            };
            std.debug.print("PC {}: CODE {} (0x{x})\n", .{ pc, opcode_name, bytecode[pc] });
        }
    }

    // Check specific positions
    try std.testing.expect(!code_bitmap.isSet(1));  // PUSH1 data
    try std.testing.expect(!code_bitmap.isSet(3));  // PUSH1 data
    try std.testing.expect(code_bitmap.isSet(5));   // CALLVALUE
    try std.testing.expect(!code_bitmap.isSet(9));  // PUSH2 data
    try std.testing.expect(!code_bitmap.isSet(10)); // PUSH2 data
    try std.testing.expect(code_bitmap.isSet(15));  // JUMPDEST

    // Now check jumpdest array
    const OpcodeMetadata = @import("evm").OpcodeMetadata;
    var analysis = try @import("evm").CodeAnalysis.from_code(allocator, &bytecode, &OpcodeMetadata.DEFAULT);
    defer analysis.deinit();

    std.debug.print("\n=== Jumpdest Array ===\n", .{});
    for (0..bytecode.len) |pc| {
        if (analysis.jumpdest_array.is_valid_jumpdest(pc)) {
            std.debug.print("PC {} is a valid jumpdest\n", .{pc});
        }
    }

    // Position 5 should NOT be a valid jumpdest
    try std.testing.expect(!analysis.jumpdest_array.is_valid_jumpdest(5));
    // Position 15 should be a valid jumpdest
    try std.testing.expect(analysis.jumpdest_array.is_valid_jumpdest(15));

    // Print instruction analysis
    std.debug.print("\n=== Instruction Analysis ===\n", .{});
    for (analysis.instructions, 0..) |inst, i| {
        std.debug.print("Inst[{}]: tag={s}, id={}\n", .{ i, @tagName(inst.tag), inst.id });
    }
}