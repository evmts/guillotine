/// KZG trusted setup data wrapper
///
/// This module provides access to the embedded trusted setup file used for
/// EIP-4844 blob verification. The trusted setup is embedded at compile time
/// to avoid runtime file I/O dependencies.
///
/// The trusted setup contains:
/// - 4096 G1 points in monomial and Lagrange form
/// - 65 G2 points in monomial form
/// - Generated from the Ethereum KZG Ceremony
///
/// Format: Text file with points in hex format
/// Size: ~788KB (4096 G1 points + 65 G2 points)
///
/// Usage:
/// ```zig
/// const kzg_trusted_setup = @import("kzg_trusted_setup.zig");
/// const setup_data = kzg_trusted_setup.data;
/// try c_kzg.loadTrustedSetupFromText(setup_data, 0);
/// ```
const std = @import("std");

/// Embedded trusted setup data from the KZG ceremony
/// Format: Text file with G1 and G2 points in hex format
/// Size: ~4096 G1 points + 65 G2 points
/// Re-export from c_kzg module to avoid duplicate embedding
pub const data = @import("c_kzg").embedded_trusted_setup;

/// Known-good SHA256 hash of the trusted setup data
/// This hash is from the official Ethereum KZG Ceremony trusted setup
/// Hash: d39b9f2d047cc9dca2de58f264b6a09448ccd34db967881a6713eacacf0f26b7
pub const EXPECTED_SHA256: [32]u8 = .{
    0xd3, 0x9b, 0x9f, 0x2d, 0x04, 0x7c, 0xc9, 0xdc, 0xa2, 0xde, 0x58, 0xf2, 0x64, 0xb6, 0xa0, 0x94,
    0x48, 0xcc, 0xd3, 0x4d, 0xb9, 0x67, 0x88, 0x1a, 0x67, 0x13, 0xea, 0xca, 0xcf, 0x0f, 0x26, 0xb7,
};

/// Errors that can occur when working with trusted setup
pub const TrustedSetupError = error{
    IntegrityCheckFailed,
    MissingG1CountLine,
    MissingG2CountLine,
    InvalidG1Count,
    InvalidG2Count,
};

/// Verify the SHA256 hash of the embedded trusted setup data
/// Returns error if the hash doesn't match the expected value
pub fn verifyIntegrity() TrustedSetupError!void {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(data);
    var computed_hash: [32]u8 = undefined;
    hasher.final(&computed_hash);

    // Constant-time comparison to prevent timing attacks
    var result: u8 = 0;
    for (computed_hash, EXPECTED_SHA256) |computed, expected| {
        result |= computed ^ expected;
    }

    if (result != 0) {
        return TrustedSetupError.IntegrityCheckFailed;
    }
}

/// Parse the header to get the number of G1 and G2 points
pub fn parseHeader() TrustedSetupError!struct { n_g1: usize, n_g2: usize } {
    var lines = std.mem.splitScalar(u8, data, '\n');

    const n_g1_line = lines.next() orelse return TrustedSetupError.MissingG1CountLine;
    const n_g1 = std.fmt.parseInt(usize, std.mem.trim(u8, n_g1_line, " \t\r\n"), 10) catch {
        return TrustedSetupError.InvalidG1Count;
    };

    const n_g2_line = lines.next() orelse return TrustedSetupError.MissingG2CountLine;
    const n_g2 = std.fmt.parseInt(usize, std.mem.trim(u8, n_g2_line, " \t\r\n"), 10) catch {
        return TrustedSetupError.InvalidG2Count;
    };

    return .{ .n_g1 = n_g1, .n_g2 = n_g2 };
}

/// Expected values from the Ethereum KZG Ceremony
pub const EXPECTED_G1_POINTS = 4096;
pub const EXPECTED_G2_POINTS = 65;

/// Verify the trusted setup has the expected format and integrity
pub fn verify() TrustedSetupError!void {
    // First verify SHA256 integrity
    try verifyIntegrity();

    // Then verify header format
    const header = try parseHeader();
    if (header.n_g1 != EXPECTED_G1_POINTS or header.n_g2 != EXPECTED_G2_POINTS) {
        return TrustedSetupError.InvalidG1Count;
    }
}

test "trusted setup embedded" {
    const testing = std.testing;

    // Verify data is embedded and non-empty
    try testing.expect(data.len > 0);

    // Should be approximately 788KB
    try testing.expect(data.len > 700_000);
    try testing.expect(data.len < 900_000);

    // Should start with the expected header format
    try testing.expect(std.mem.startsWith(u8, data, "4096\n65\n"));
}

test "trusted setup SHA256 integrity verification" {
    // Verify the SHA256 hash matches the expected value
    try verifyIntegrity();
}

test "trusted setup integrity check detects tampering" {
    const testing = std.testing;

    // Create a modified copy of the data
    var tampered_data = std.ArrayList(u8).empty;
    defer tampered_data.deinit(testing.allocator);
    try tampered_data.appendSlice(testing.allocator, data);

    // Tamper with one byte
    if (tampered_data.items.len > 100) {
        tampered_data.items[100] ^= 0xFF;
    }

    // Compute hash of tampered data
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(tampered_data.items);
    var tampered_hash: [32]u8 = undefined;
    hasher.final(&tampered_hash);

    // Verify the hash is different
    var hashes_differ = false;
    for (tampered_hash, EXPECTED_SHA256) |computed, expected| {
        if (computed != expected) {
            hashes_differ = true;
            break;
        }
    }
    try testing.expect(hashes_differ);
}

test "trusted setup header parsing" {
    const testing = std.testing;

    const header = try parseHeader();
    try testing.expectEqual(@as(usize, EXPECTED_G1_POINTS), header.n_g1);
    try testing.expectEqual(@as(usize, EXPECTED_G2_POINTS), header.n_g2);
}

test "trusted setup verification" {
    try verify();
}
