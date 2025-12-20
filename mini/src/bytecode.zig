/// Bytecode utilities and validation
/// This module provides abstractions for working with EVM bytecode,
/// including jump destination analysis and bytecode traversal.
const std = @import("std");

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

    /// Get opcode at position
    pub fn getOpcode(self: *const Bytecode, pc: u32) ?u8 {
        if (pc >= self.code.len) {
            return null;
        }
        return self.code[pc];
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
