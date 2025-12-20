const std = @import("std");
const ripemd160_impl = @import("ripemd160.zig");
const blake2_impl = @import("blake2.zig");

pub const HashError = error{
    OutputBufferTooSmall,
};

/// SHA256 cryptographic hash function
/// Produces a 256-bit (32-byte) digest
pub const SHA256 = struct {
    pub const OUTPUT_SIZE: usize = 32;

    /// Compute SHA256 hash of input data
    pub fn hash(input: []const u8, output: []u8) HashError!void {
        if (output.len < OUTPUT_SIZE) {
            return HashError.OutputBufferTooSmall;
        }

        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(input);
        hasher.final(output[0..OUTPUT_SIZE]);
    }

    /// Compute SHA256 hash and return as fixed-size array
    pub fn hashFixed(input: []const u8) [OUTPUT_SIZE]u8 {
        var result: [OUTPUT_SIZE]u8 = undefined;
        hash(input, &result) catch unreachable; // Buffer size is guaranteed correct
        return result;
    }
};

test "SHA256 hash computation" {
    const test_input = "hello world";
    var output: [SHA256.OUTPUT_SIZE]u8 = undefined;

    try SHA256.hash(test_input, &output);

    // Known SHA256 hash of "hello world"
    const expected = [_]u8{
        0xb9, 0x4d, 0x27, 0xb9, 0x93, 0x4d, 0x3e, 0x08,
        0xa5, 0x2e, 0x52, 0xd7, 0xda, 0x7d, 0xab, 0xfa,
        0xc4, 0x84, 0xef, 0xe3, 0x7a, 0x53, 0x80, 0xee,
        0x90, 0x88, 0xf7, 0xac, 0xe2, 0xef, 0xcd, 0xe9,
    };

    try std.testing.expectEqualSlices(u8, &expected, &output);
}

test "SHA256 hashFixed function" {
    const test_input = "hello world";
    const result = SHA256.hashFixed(test_input);

    const expected = [_]u8{
        0xb9, 0x4d, 0x27, 0xb9, 0x93, 0x4d, 0x3e, 0x08,
        0xa5, 0x2e, 0x52, 0xd7, 0xda, 0x7d, 0xab, 0xfa,
        0xc4, 0x84, 0xef, 0xe3, 0x7a, 0x53, 0x80, 0xee,
        0x90, 0x88, 0xf7, 0xac, 0xe2, 0xef, 0xcd, 0xe9,
    };

    try std.testing.expectEqual(expected, result);
}

/// RIPEMD160 cryptographic hash function
/// Produces a 160-bit (20-byte) digest
pub const RIPEMD160 = struct {
    pub const OUTPUT_SIZE: usize = 20;

    /// Compute RIPEMD160 hash of input data
    pub fn hash(input: []const u8, output: []u8) HashError!void {
        if (output.len < OUTPUT_SIZE) {
            return HashError.OutputBufferTooSmall;
        }

        const result = ripemd160_impl.unauditedHash(input);
        @memcpy(output[0..OUTPUT_SIZE], &result);
    }

    /// Compute RIPEMD160 hash and return as fixed-size array
    pub fn hashFixed(input: []const u8) [OUTPUT_SIZE]u8 {
        return ripemd160_impl.unauditedHash(input);
    }
};

test "RIPEMD160 hash computation" {
    const test_input = "abc";
    var output: [RIPEMD160.OUTPUT_SIZE]u8 = undefined;

    try RIPEMD160.hash(test_input, &output);

    // Known RIPEMD160 hash of "abc"
    const expected = [_]u8{
        0x8e, 0xb2, 0x08, 0xf7, 0xe0, 0x5d, 0x98, 0x7a,
        0x9b, 0x04, 0x4a, 0x8e, 0x98, 0xc6, 0xb0, 0x87,
        0xf1, 0x5a, 0x0b, 0xfc,
    };

    try std.testing.expectEqualSlices(u8, &expected, &output);
}

test "RIPEMD160 hashFixed function" {
    const test_input = "";
    const result = RIPEMD160.hashFixed(test_input);

    // Known RIPEMD160 hash of empty string
    const expected = [_]u8{
        0x9c, 0x11, 0x85, 0xa5, 0xc5, 0xe9, 0xfc, 0x54,
        0x61, 0x28, 0x08, 0x97, 0x7e, 0xe8, 0xf5, 0x48,
        0xb2, 0x25, 0x8d, 0x31,
    };

    try std.testing.expectEqual(expected, result);
}

/// BLAKE2F compression function
/// EIP-152 compatible compression function for BLAKE2b
pub const BLAKE2F = struct {
    pub const STATE_SIZE: usize = 8; // 8 x 64-bit words
    pub const MESSAGE_SIZE: usize = 16; // 16 x 64-bit words
    pub const OUTPUT_SIZE: usize = 64; // 64 bytes

    /// Perform BLAKE2F compression
    /// WARNING: UNAUDITED - Custom cryptographic implementation that has NOT been audited!
    /// This function wraps unaudited BLAKE2b compression implementation.
    /// Use at your own risk in production systems.
    /// @param h State vector (8 x 64-bit words)
    /// @param m Message block (16 x 64-bit words)
    /// @param t Offset counters (2 x 64-bit words)
    /// @param f Final block flag
    /// @param rounds Number of rounds to perform
    pub fn unauditedCompress(h: *[STATE_SIZE]u64, m: *const [MESSAGE_SIZE]u64, t: [2]u64, f: bool, rounds: u32) void {
        blake2_impl.unauditedBlake2fCompress(h, m, t, f, rounds);
    }

    /// Parse and compress from EIP-152 format input
    /// WARNING: UNAUDITED - Custom cryptographic implementation that has NOT been audited!
    /// This function wraps unaudited BLAKE2b compression implementation.
    /// Use at your own risk in production systems.
    /// @param input 213-byte input (rounds + h + m + t + f)
    /// @param output 64-byte output buffer
    pub fn unauditedCompressEip152(input: []const u8, output: []u8) !void {
        if (input.len != 213) return error.InvalidInputLength;
        if (output.len < OUTPUT_SIZE) return error.OutputBufferTooSmall;

        // Parse rounds (big-endian)
        const rounds = std.mem.readInt(u32, input[0..4][0..4], .big);

        // Parse h (state vector) - 8 x 64-bit little-endian words
        var h: [STATE_SIZE]u64 = undefined;
        for (0..8) |i| {
            const offset = 4 + i * 8;
            h[i] = std.mem.readInt(u64, input[offset .. offset + 8][0..8], .little);
        }

        // Parse m (message block) - 16 x 64-bit little-endian words
        var m: [MESSAGE_SIZE]u64 = undefined;
        for (0..16) |i| {
            const offset = 68 + i * 8;
            m[i] = std.mem.readInt(u64, input[offset .. offset + 8][0..8], .little);
        }

        // Parse t (offset counters) - 2 x 64-bit little-endian
        const t = [2]u64{
            std.mem.readInt(u64, input[196..204][0..8], .little),
            std.mem.readInt(u64, input[204..212][0..8], .little),
        };

        // Parse f (final flag)
        const f = input[212];
        if (f != 0 and f != 1) return error.InvalidFinalFlag;

        // Perform compression
        unauditedCompress(&h, &m, t, f != 0, rounds);

        // Write result to output (little-endian)
        for (0..8) |i| {
            const offset = i * 8;
            std.mem.writeInt(u64, output[offset .. offset + 8][0..8], h[i], .little);
        }
    }
};
