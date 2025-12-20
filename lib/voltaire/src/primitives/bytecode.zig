/// Bytecode utilities and validation
/// This module provides abstractions for working with EVM bytecode,
/// including jump destination analysis and bytecode traversal.
const std = @import("std");
const Opcode = @import("opcode.zig").Opcode;

/// Represents analyzed bytecode with pre-validated jump destinations
pub const Bytecode = struct {
    /// Raw bytecode bytes
    code: []const u8,

    /// Pre-analyzed valid JUMPDEST positions
    valid_jumpdests: std.AutoArrayHashMap(u32, void),

    /// Initialize bytecode with jump destination analysis
    pub fn init(allocator: std.mem.Allocator, code: []const u8) !Bytecode {
        var valid_jumpdests = std.AutoArrayHashMap(u32, void).init(allocator);
        errdefer valid_jumpdests.deinit();

        try analyzeJumpDests(code, &valid_jumpdests);

        return Bytecode{
            .code = code,
            .valid_jumpdests = valid_jumpdests,
        };
    }

    /// Clean up resources
    pub fn deinit(self: *Bytecode) void {
        self.valid_jumpdests.deinit();
    }

    /// Check if a position is a valid JUMPDEST
    pub fn isValidJumpDest(self: *const Bytecode, pc: u32) bool {
        return self.valid_jumpdests.contains(pc);
    }

    /// Get bytecode length
    pub fn len(self: *const Bytecode) usize {
        return self.code.len;
    }

    /// Get opcode byte at position
    pub fn getOpcode(self: *const Bytecode, pc: u32) ?u8 {
        if (pc >= self.code.len) {
            return null;
        }
        return self.code[pc];
    }

    /// Get typed Opcode enum at position
    pub fn getOpcodeEnum(self: *const Bytecode, pc: u32) ?Opcode {
        const byte = self.getOpcode(pc) orelse return null;
        return @enumFromInt(byte);
    }

    /// Read immediate data for PUSH operations
    /// Returns the N bytes following the current PC (for PUSHN instructions)
    pub fn readImmediate(self: *const Bytecode, pc: u32, size: u8) ?u256 {
        const pc_usize: usize = @intCast(pc);
        const size_usize: usize = size;

        // Check if we have enough bytes: current position + 1 (opcode) + size
        if (pc_usize + 1 + size_usize > self.code.len) {
            return null;
        }

        var result: u256 = 0;
        var i: u8 = 0;
        while (i < size) : (i += 1) {
            const idx: usize = pc_usize + 1 + i;
            result = (result << 8) | self.code[idx];
        }
        return result;
    }
};

/// Analyze bytecode to identify valid JUMPDEST locations
/// This must skip over PUSH instruction immediate data to avoid
/// treating data bytes as instructions
fn analyzeJumpDests(code: []const u8, valid_jumpdests: *std.AutoArrayHashMap(u32, void)) !void {
    var pc: u32 = 0;

    while (pc < code.len) {
        const opcode = code[pc];

        // Check if this is a JUMPDEST (0x5b)
        if (opcode == 0x5b) {
            try valid_jumpdests.put(pc, {});
            pc += 1;
        } else if (opcode >= 0x60 and opcode <= 0x7f) {
            // PUSH1 (0x60) through PUSH32 (0x7f)
            // Calculate number of bytes to push: opcode - 0x5f
            // e.g., PUSH1 (0x60) = 0x60 - 0x5f = 1 byte
            //       PUSH32 (0x7f) = 0x7f - 0x5f = 32 bytes
            const push_size = opcode - 0x5f;

            // Skip the PUSH opcode itself and all its immediate data bytes
            // This prevents treating immediate data as opcodes
            pc += 1 + push_size;
        } else {
            // All other opcodes are single byte
            pc += 1;
        }
    }
}

test "analyzeJumpDests: simple JUMPDEST" {
    const code = [_]u8{ 0x5b, 0x00, 0x5b }; // JUMPDEST, STOP, JUMPDEST
    var valid_jumpdests = std.AutoArrayHashMap(u32, void).init(std.testing.allocator);
    defer valid_jumpdests.deinit();

    try analyzeJumpDests(&code, &valid_jumpdests);

    try std.testing.expect(valid_jumpdests.contains(0));
    try std.testing.expect(valid_jumpdests.contains(2));
    try std.testing.expect(!valid_jumpdests.contains(1));
}

test "analyzeJumpDests: PUSH data containing JUMPDEST opcode" {
    const code = [_]u8{
        0x60, 0x5b, // PUSH1 0x5b (pushes JUMPDEST opcode as data)
        0x5b, // JUMPDEST (actual valid jump destination)
    };
    var valid_jumpdests = std.AutoArrayHashMap(u32, void).init(std.testing.allocator);
    defer valid_jumpdests.deinit();

    try analyzeJumpDests(&code, &valid_jumpdests);

    // Only position 2 should be valid (the actual JUMPDEST)
    // Position 1 (the 0x5b in PUSH data) should NOT be valid
    try std.testing.expect(!valid_jumpdests.contains(0));
    try std.testing.expect(!valid_jumpdests.contains(1));
    try std.testing.expect(valid_jumpdests.contains(2));
}

test "analyzeJumpDests: PUSH32 with embedded JUMPDEST bytes" {
    var code: [34]u8 = undefined;
    code[0] = 0x7f; // PUSH32
    // Fill with 32 bytes of data, including some 0x5b (JUMPDEST) bytes
    for (1..33) |i| {
        code[i] = if (i % 2 == 0) 0x5b else 0x00;
    }
    code[33] = 0x5b; // Actual JUMPDEST after PUSH32

    var valid_jumpdests = std.AutoArrayHashMap(u32, void).init(std.testing.allocator);
    defer valid_jumpdests.deinit();

    try analyzeJumpDests(&code, &valid_jumpdests);

    // Only position 33 should be valid
    try std.testing.expect(!valid_jumpdests.contains(0));
    for (1..33) |i| {
        try std.testing.expect(!valid_jumpdests.contains(@intCast(i)));
    }
    try std.testing.expect(valid_jumpdests.contains(33));
}

test "Bytecode: initialization and queries" {
    const code = [_]u8{ 0x60, 0x01, 0x5b, 0x00 }; // PUSH1 1, JUMPDEST, STOP

    var bytecode = try Bytecode.init(std.testing.allocator, &code);
    defer bytecode.deinit();

    try std.testing.expectEqual(@as(usize, 4), bytecode.len());
    try std.testing.expect(!bytecode.isValidJumpDest(0));
    try std.testing.expect(!bytecode.isValidJumpDest(1));
    try std.testing.expect(bytecode.isValidJumpDest(2));
    try std.testing.expect(!bytecode.isValidJumpDest(3));
}

test "Bytecode: readImmediate" {
    const code = [_]u8{ 0x60, 0xff, 0x61, 0x12, 0x34 }; // PUSH1 0xff, PUSH2 0x1234

    var bytecode = try Bytecode.init(std.testing.allocator, &code);
    defer bytecode.deinit();

    // Read PUSH1 immediate (1 byte)
    if (bytecode.readImmediate(0, 1)) |value| {
        try std.testing.expectEqual(@as(u256, 0xff), value);
    } else {
        try std.testing.expect(false); // Should not be null
    }

    // Read PUSH2 immediate (2 bytes)
    if (bytecode.readImmediate(2, 2)) |value| {
        try std.testing.expectEqual(@as(u256, 0x1234), value);
    } else {
        try std.testing.expect(false); // Should not be null
    }

    // Try to read beyond bytecode (should return null)
    try std.testing.expect(bytecode.readImmediate(3, 2) == null);
}

test "Bytecode.init: empty bytecode" {
    const code = [_]u8{};

    var bytecode = try Bytecode.init(std.testing.allocator, &code);
    defer bytecode.deinit();

    try std.testing.expectEqual(@as(usize, 0), bytecode.len());
    try std.testing.expect(!bytecode.isValidJumpDest(0));
}

test "Bytecode.init: no valid jump destinations" {
    const code = [_]u8{ 0x60, 0x01, 0x60, 0x02, 0x01, 0x00 }; // PUSH1 1, PUSH1 2, ADD, STOP

    var bytecode = try Bytecode.init(std.testing.allocator, &code);
    defer bytecode.deinit();

    try std.testing.expectEqual(@as(usize, 6), bytecode.len());
    try std.testing.expect(!bytecode.isValidJumpDest(0));
    try std.testing.expect(!bytecode.isValidJumpDest(1));
    try std.testing.expect(!bytecode.isValidJumpDest(2));
    try std.testing.expect(!bytecode.isValidJumpDest(3));
    try std.testing.expect(!bytecode.isValidJumpDest(4));
    try std.testing.expect(!bytecode.isValidJumpDest(5));
}

test "Bytecode.init: multiple consecutive JUMPDESTs" {
    const code = [_]u8{ 0x5b, 0x5b, 0x5b, 0x00 }; // JUMPDEST, JUMPDEST, JUMPDEST, STOP

    var bytecode = try Bytecode.init(std.testing.allocator, &code);
    defer bytecode.deinit();

    try std.testing.expect(bytecode.isValidJumpDest(0));
    try std.testing.expect(bytecode.isValidJumpDest(1));
    try std.testing.expect(bytecode.isValidJumpDest(2));
    try std.testing.expect(!bytecode.isValidJumpDest(3));
}

test "Bytecode.deinit: memory cleanup" {
    const code = [_]u8{ 0x5b, 0x60, 0x01, 0x5b, 0x00 }; // JUMPDEST, PUSH1 1, JUMPDEST, STOP

    var bytecode = try Bytecode.init(std.testing.allocator, &code);
    bytecode.deinit();

    // If memory cleanup is incorrect, this would fail in debug builds
    // Testing that deinit completes without error
}

test "Bytecode.isValidJumpDest: boundary checks" {
    const code = [_]u8{ 0x5b, 0x00 }; // JUMPDEST, STOP

    var bytecode = try Bytecode.init(std.testing.allocator, &code);
    defer bytecode.deinit();

    try std.testing.expect(bytecode.isValidJumpDest(0));
    try std.testing.expect(!bytecode.isValidJumpDest(1));
    try std.testing.expect(!bytecode.isValidJumpDest(2));
    try std.testing.expect(!bytecode.isValidJumpDest(100));
    try std.testing.expect(!bytecode.isValidJumpDest(0xffffffff));
}

test "Bytecode.readImmediate: PUSH1 edge cases" {
    const code = [_]u8{ 0x60, 0x00, 0x60, 0xff }; // PUSH1 0x00, PUSH1 0xff

    var bytecode = try Bytecode.init(std.testing.allocator, &code);
    defer bytecode.deinit();

    // PUSH1 with zero value
    if (bytecode.readImmediate(0, 1)) |value| {
        try std.testing.expectEqual(@as(u256, 0x00), value);
    } else {
        try std.testing.expect(false);
    }

    // PUSH1 with max byte value
    if (bytecode.readImmediate(2, 1)) |value| {
        try std.testing.expectEqual(@as(u256, 0xff), value);
    } else {
        try std.testing.expect(false);
    }
}

test "Bytecode.readImmediate: PUSH32 full word" {
    var code: [33]u8 = undefined;
    code[0] = 0x7f; // PUSH32
    // Fill with max value bytes
    for (1..33) |i| {
        code[i] = 0xff;
    }

    var bytecode = try Bytecode.init(std.testing.allocator, &code);
    defer bytecode.deinit();

    if (bytecode.readImmediate(0, 32)) |value| {
        try std.testing.expectEqual(@as(u256, 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff), value);
    } else {
        try std.testing.expect(false);
    }
}

test "Bytecode.readImmediate: PUSH32 with zeros" {
    var code: [33]u8 = undefined;
    code[0] = 0x7f; // PUSH32
    // Fill with zeros
    for (1..33) |i| {
        code[i] = 0x00;
    }

    var bytecode = try Bytecode.init(std.testing.allocator, &code);
    defer bytecode.deinit();

    if (bytecode.readImmediate(0, 32)) |value| {
        try std.testing.expectEqual(@as(u256, 0), value);
    } else {
        try std.testing.expect(false);
    }
}

test "Bytecode.readImmediate: various PUSH sizes" {
    // Test PUSH1 through PUSH8
    const code = [_]u8{
        0x60, 0x01, // PUSH1 0x01
        0x61, 0x01, 0x02, // PUSH2 0x0102
        0x62, 0x01, 0x02, 0x03, // PUSH3 0x010203
        0x63, 0x01, 0x02, 0x03, 0x04, // PUSH4 0x01020304
        0x67, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, // PUSH8 0x0102030405060708
    };

    var bytecode = try Bytecode.init(std.testing.allocator, &code);
    defer bytecode.deinit();

    // PUSH1
    if (bytecode.readImmediate(0, 1)) |value| {
        try std.testing.expectEqual(@as(u256, 0x01), value);
    } else {
        try std.testing.expect(false);
    }

    // PUSH2
    if (bytecode.readImmediate(2, 2)) |value| {
        try std.testing.expectEqual(@as(u256, 0x0102), value);
    } else {
        try std.testing.expect(false);
    }

    // PUSH3
    if (bytecode.readImmediate(5, 3)) |value| {
        try std.testing.expectEqual(@as(u256, 0x010203), value);
    } else {
        try std.testing.expect(false);
    }

    // PUSH4
    if (bytecode.readImmediate(9, 4)) |value| {
        try std.testing.expectEqual(@as(u256, 0x01020304), value);
    } else {
        try std.testing.expect(false);
    }

    // PUSH8
    if (bytecode.readImmediate(14, 8)) |value| {
        try std.testing.expectEqual(@as(u256, 0x0102030405060708), value);
    } else {
        try std.testing.expect(false);
    }
}

test "Bytecode.readImmediate: boundary overflow protection" {
    const code = [_]u8{ 0x60, 0x01 }; // PUSH1 0x01

    var bytecode = try Bytecode.init(std.testing.allocator, &code);
    defer bytecode.deinit();

    // Try to read more bytes than available
    try std.testing.expect(bytecode.readImmediate(0, 2) == null);
    try std.testing.expect(bytecode.readImmediate(1, 1) == null);
    try std.testing.expect(bytecode.readImmediate(0, 32) == null);
}

test "Bytecode.readImmediate: at end of bytecode" {
    const code = [_]u8{ 0x60, 0x01, 0x60 }; // PUSH1 0x01, PUSH1 (incomplete)

    var bytecode = try Bytecode.init(std.testing.allocator, &code);
    defer bytecode.deinit();

    // First PUSH1 should work
    if (bytecode.readImmediate(0, 1)) |value| {
        try std.testing.expectEqual(@as(u256, 0x01), value);
    } else {
        try std.testing.expect(false);
    }

    // Second PUSH1 is incomplete (no immediate data)
    try std.testing.expect(bytecode.readImmediate(2, 1) == null);
}

test "analyzeJumpDests: PUSH inside PUSH data should not be treated as instruction" {
    const code = [_]u8{
        0x61, 0x60, 0x5b, // PUSH2 0x605b (contains PUSH1 opcode and JUMPDEST opcode as data)
        0x5b, // JUMPDEST (actual valid jump destination)
    };
    var valid_jumpdests = std.AutoArrayHashMap(u32, void).init(std.testing.allocator);
    defer valid_jumpdests.deinit();

    try analyzeJumpDests(&code, &valid_jumpdests);

    // Only position 3 should be valid
    try std.testing.expect(!valid_jumpdests.contains(0));
    try std.testing.expect(!valid_jumpdests.contains(1));
    try std.testing.expect(!valid_jumpdests.contains(2));
    try std.testing.expect(valid_jumpdests.contains(3));
}

test "analyzeJumpDests: incomplete PUSH at end of bytecode" {
    const code = [_]u8{
        0x5b, // JUMPDEST
        0x62, 0x01, // PUSH3 with only 2 bytes (incomplete)
    };
    var valid_jumpdests = std.AutoArrayHashMap(u32, void).init(std.testing.allocator);
    defer valid_jumpdests.deinit();

    try analyzeJumpDests(&code, &valid_jumpdests);

    // Only position 0 should be valid
    try std.testing.expect(valid_jumpdests.contains(0));
    try std.testing.expect(!valid_jumpdests.contains(1));
    try std.testing.expect(!valid_jumpdests.contains(2));
}

test "analyzeJumpDests: all PUSH opcodes PUSH1-PUSH32" {
    // Create bytecode with all PUSH opcodes followed by JUMPDEST
    var code: [32 * 34 + 1]u8 = undefined;
    var offset: usize = 0;

    // PUSH1 through PUSH32
    var push_num: u8 = 1;
    while (push_num <= 32) : (push_num += 1) {
        const opcode: u8 = 0x5f + push_num; // PUSH1 = 0x60, PUSH2 = 0x61, ..., PUSH32 = 0x7f
        code[offset] = opcode;
        offset += 1;

        // Fill with dummy data
        var i: u8 = 0;
        while (i < push_num) : (i += 1) {
            code[offset] = 0xaa;
            offset += 1;
        }
    }

    // Add final JUMPDEST
    code[offset] = 0x5b;
    const final_jumpdest_pos: u32 = @intCast(offset);

    var valid_jumpdests = std.AutoArrayHashMap(u32, void).init(std.testing.allocator);
    defer valid_jumpdests.deinit();

    try analyzeJumpDests(&code, &valid_jumpdests);

    // Only the final position should be a valid JUMPDEST
    try std.testing.expect(valid_jumpdests.contains(final_jumpdest_pos));

    // Verify none of the PUSH data bytes are treated as JUMPDEST
    var pos: u32 = 0;
    while (pos < final_jumpdest_pos) : (pos += 1) {
        try std.testing.expect(!valid_jumpdests.contains(pos));
    }
}

test "Bytecode.getOpcode: boundary checks" {
    const code = [_]u8{ 0x60, 0x01, 0x5b }; // PUSH1 1, JUMPDEST

    var bytecode = try Bytecode.init(std.testing.allocator, &code);
    defer bytecode.deinit();

    try std.testing.expectEqual(@as(u8, 0x60), bytecode.getOpcode(0).?);
    try std.testing.expectEqual(@as(u8, 0x01), bytecode.getOpcode(1).?);
    try std.testing.expectEqual(@as(u8, 0x5b), bytecode.getOpcode(2).?);
    try std.testing.expect(bytecode.getOpcode(3) == null);
    try std.testing.expect(bytecode.getOpcode(100) == null);
}

test "Bytecode.getOpcodeEnum: valid opcodes" {
    const code = [_]u8{ 0x60, 0x01, 0x5b, 0x00 }; // PUSH1 1, JUMPDEST, STOP

    var bytecode = try Bytecode.init(std.testing.allocator, &code);
    defer bytecode.deinit();

    try std.testing.expectEqual(Opcode.PUSH1, bytecode.getOpcodeEnum(0).?);
    try std.testing.expectEqual(@as(u8, 0x01), @intFromEnum(bytecode.getOpcodeEnum(1).?));
    try std.testing.expectEqual(Opcode.JUMPDEST, bytecode.getOpcodeEnum(2).?);
    try std.testing.expectEqual(Opcode.STOP, bytecode.getOpcodeEnum(3).?);
    try std.testing.expect(bytecode.getOpcodeEnum(4) == null);
}

test "Bytecode: large bytecode performance" {
    // Create a large bytecode (10KB) with scattered JUMPDESTs
    const allocator = std.testing.allocator;
    const size = 10 * 1024;
    const code = try allocator.alloc(u8, size);
    defer allocator.free(code);

    // Fill with various opcodes including JUMPDESTs every 100 bytes
    for (0..size) |i| {
        if (i % 100 == 0) {
            code[i] = 0x5b; // JUMPDEST
        } else if (i % 50 == 0) {
            code[i] = 0x60; // PUSH1
        } else {
            code[i] = 0x00; // STOP
        }
    }

    var bytecode = try Bytecode.init(allocator, code);
    defer bytecode.deinit();

    try std.testing.expectEqual(size, bytecode.len());

    // Verify some JUMPDESTs
    try std.testing.expect(bytecode.isValidJumpDest(0));
    try std.testing.expect(bytecode.isValidJumpDest(100));
    try std.testing.expect(bytecode.isValidJumpDest(200));
    try std.testing.expect(!bytecode.isValidJumpDest(50));
    try std.testing.expect(!bytecode.isValidJumpDest(150));
}

test "Bytecode: complex real-world-like bytecode" {
    // Simulate a more complex bytecode pattern like a simple contract
    // Position calculation:
    // 0-1: PUSH1 0x80, 2-3: PUSH1 0x40, 4: MSTORE, 5: JUMPDEST,
    // 6-7: PUSH1 0x00, 8: CALLDATALOAD, 9-10: PUSH1 0xe0, 11: SHR,
    // 12-16: PUSH4 0x12345678, 17: JUMPDEST, 18: EQ,
    // 19-21: PUSH2 0x001e, 22: JUMPI, 23: JUMPDEST, 24: STOP
    const code = [_]u8{
        // Constructor-like pattern
        0x60, 0x80, // PUSH1 0x80 (pos 0-1)
        0x60, 0x40, // PUSH1 0x40 (pos 2-3)
        0x52, // MSTORE (pos 4)
        0x5b, // JUMPDEST (pos 5)
        0x60, 0x00, // PUSH1 0x00 (pos 6-7)
        0x35, // CALLDATALOAD (pos 8)
        0x60, 0xe0, // PUSH1 0xe0 (pos 9-10)
        0x1c, // SHR (pos 11)
        0x63, 0x12, 0x34, 0x56, 0x78, // PUSH4 0x12345678 (pos 12-16)
        0x5b, // JUMPDEST (pos 17)
        0x14, // EQ (pos 18)
        0x61, 0x00, 0x1e, // PUSH2 0x001e (pos 19-21)
        0x57, // JUMPI (pos 22)
        0x5b, // JUMPDEST (pos 23)
        0x00, // STOP (pos 24)
    };

    var bytecode = try Bytecode.init(std.testing.allocator, &code);
    defer bytecode.deinit();

    // Verify JUMPDESTs at correct positions
    try std.testing.expect(bytecode.isValidJumpDest(5));
    try std.testing.expect(bytecode.isValidJumpDest(17));
    try std.testing.expect(bytecode.isValidJumpDest(23));

    // Verify non-JUMPDESTs
    try std.testing.expect(!bytecode.isValidJumpDest(0));
    try std.testing.expect(!bytecode.isValidJumpDest(7));
    try std.testing.expect(!bytecode.isValidJumpDest(15)); // Inside PUSH4 data
    try std.testing.expect(!bytecode.isValidJumpDest(20)); // Inside PUSH2 data

    // Test readImmediate for various PUSH operations
    if (bytecode.readImmediate(0, 1)) |value| {
        try std.testing.expectEqual(@as(u256, 0x80), value);
    } else {
        try std.testing.expect(false);
    }

    if (bytecode.readImmediate(12, 4)) |value| {
        try std.testing.expectEqual(@as(u256, 0x12345678), value);
    } else {
        try std.testing.expect(false);
    }

    if (bytecode.readImmediate(19, 2)) |value| {
        try std.testing.expectEqual(@as(u256, 0x001e), value);
    } else {
        try std.testing.expect(false);
    }
}

test "Bytecode: PUSH32 followed immediately by JUMPDEST" {
    var code: [34]u8 = undefined;
    code[0] = 0x7f; // PUSH32
    for (1..33) |i| {
        code[i] = @intCast(i);
    }
    code[33] = 0x5b; // JUMPDEST

    var bytecode = try Bytecode.init(std.testing.allocator, &code);
    defer bytecode.deinit();

    // Only position 33 should be JUMPDEST
    try std.testing.expect(!bytecode.isValidJumpDest(0));
    for (1..33) |i| {
        try std.testing.expect(!bytecode.isValidJumpDest(@intCast(i)));
    }
    try std.testing.expect(bytecode.isValidJumpDest(33));

    // Verify PUSH32 data can be read
    if (bytecode.readImmediate(0, 32)) |value| {
        var expected: u256 = 0;
        for (1..33) |i| {
            expected = (expected << 8) | i;
        }
        try std.testing.expectEqual(expected, value);
    } else {
        try std.testing.expect(false);
    }
}

test "Bytecode: bytecode ending with incomplete PUSH should not crash" {
    const code = [_]u8{
        0x60, 0x01, // PUSH1 0x01 (complete)
        0x61, 0x02, // PUSH2 0x02?? (incomplete, missing 1 byte)
    };

    var bytecode = try Bytecode.init(std.testing.allocator, &code);
    defer bytecode.deinit();

    try std.testing.expectEqual(@as(usize, 4), bytecode.len());

    // First PUSH1 should work
    if (bytecode.readImmediate(0, 1)) |value| {
        try std.testing.expectEqual(@as(u256, 0x01), value);
    } else {
        try std.testing.expect(false);
    }

    // Second PUSH2 is incomplete
    try std.testing.expect(bytecode.readImmediate(2, 2) == null);

    // No crashes during jump dest analysis
    try std.testing.expect(!bytecode.isValidJumpDest(0));
    try std.testing.expect(!bytecode.isValidJumpDest(2));
}
