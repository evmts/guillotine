//! FastLZ compression size estimation for Optimism L1 fee calculation.
//!
//! Based on the Rust implementation from op-revm:
//! https://github.com/ethereum-optimism/optimism/blob/develop/rust/op-revm/src/fast_lz.rs
//!
//! This is a direct port of the FastLZ compression algorithm used to estimate
//! the compressed size of transaction data for L1 fee calculations in Optimism.
//!
//! SAFETY: This algorithm relies on `idx_limit = input.len - 13` to ensure all
//! array accesses within the main loop are in bounds. Do not add defensive
//! bounds checks that would alter the algorithm's behavior.

const std = @import("std");

/// Returns the length of the data after compression through FastLZ.
///
/// Based on:
/// - https://github.com/Vectorized/solady/blob/5315d937d79b335c668896d7533ac603adac5315/js/solady.js
/// - https://github.com/ethereum-optimism/op-geth/blob/647c346e2bef36219cc7b47d76b1cb87e7ca29e4/core/types/rollup_cost.go#L411
pub fn flzCompressLen(input: []const u8) u32 {
    // Early return for small inputs - algorithm requires at least 13 bytes.
    if (input.len < 13) {
        return literals(@intCast(input.len), 0);
    }
    if (input.len > std.math.maxInt(u32)) {
        @branchHint(.unlikely);
        return std.math.maxInt(u32);
    }

    var idx: u32 = 2;
    const input_len_u32: u32 = @intCast(input.len);
    const idx_limit: u32 = input_len_u32 - 13;

    var anchor: u32 = 0;
    var size: u32 = 0;
    var htab: [8192]u32 = @as([8192]u32, @splat(0));

    while (idx < idx_limit) {
        var r: u32 = undefined;
        var distance: u32 = undefined;

        // Inner loop: find a match or reach idx_limit
        while (true) {
            const seq = readU24(input, idx);
            const hash = hashFn(seq);
            r = htab[hash];
            htab[hash] = idx;
            distance = idx - r;
            if (idx >= idx_limit) {
                break;
            }
            idx += 1;
            if (distance < 8192 and seq == readU24(input, r)) {
                break;
            }
        }

        if (idx >= idx_limit) {
            break;
        }

        idx -= 1;

        if (idx > anchor) {
            size = literals(idx - anchor, size);
        }

        const len = cmp(input, .{
            .prev_offset = r + 3,
            .curr_offset = idx + 3,
            .limit = idx_limit + 9,
        });
        size = flzMatch(len, size);

        idx = setNextHash(&htab, input, idx + len);
        idx = setNextHash(&htab, input, idx);
        anchor = idx;
    }

    return literals(input_len_u32 - anchor, size);
}

const MatchRange = struct {
    prev_offset: u32,
    curr_offset: u32,
    limit: u32,
};

fn literals(r: u32, size: u32) u32 {
    const new_size = size + 0x21 * (r / 0x20);
    const remainder = r % 0x20;
    if (remainder != 0) {
        return new_size + remainder + 1;
    } else {
        return new_size;
    }
}

/// Compare bytes at two positions and return match length.
/// SAFETY: Caller must ensure range offsets are valid for the algorithm's invariants.
/// The algorithm guarantees this through idx_limit = input.len - 13.
inline fn cmp(input: []const u8, range: MatchRange) u32 {
    var l: u32 = 0;
    var max_len = range.limit - range.curr_offset;
    while (l < max_len) {
        const a = input[@as(usize, range.prev_offset + l)];
        const b = input[@as(usize, range.curr_offset + l)];
        if (a != b) {
            max_len = 0;
        }
        l += 1;
    }
    return l;
}

fn flzMatch(l: u32, size: u32) u32 {
    const adjusted_l = l - 1;
    const new_size = size + (3 * (adjusted_l / 262));
    if (adjusted_l % 262 >= 6) {
        return new_size + 3;
    } else {
        return new_size + 2;
    }
}

fn setNextHash(htab: *[8192]u32, input: []const u8, idx: u32) u32 {
    htab[hashFn(readU24(input, idx))] = idx;
    return idx + 1;
}

fn hashFn(v: u32) u16 {
    const hash = (@as(u64, v) *% 2654435769) >> 19;
    // Mask first to ensure value fits in u16 (0x1fff = 13 bits)
    return @as(u16, @intCast(hash & 0x1fff));
}

fn readU24(input: []const u8, idx: u32) u32 {
    const i = @as(usize, @intCast(idx));
    return @as(u32, input[i]) +
        (@as(u32, input[i + 1]) << 8) +
        (@as(u32, input[i + 2]) << 16);
}

// =============================================================================
// Tests
// =============================================================================

test "flz_compress_len - empty input" {
    const input: []const u8 = &[_]u8{};
    try std.testing.expectEqual(@as(u32, 0), flzCompressLen(input));
}

test "flz_compress_len - short hex FACADE" {
    const input = [_]u8{ 0xFA, 0xCA, 0xDE };
    try std.testing.expectEqual(@as(u32, 4), flzCompressLen(&input));
}

test "flz_compress_len - thousand zeros" {
    const input = @as([1000]u8, @splat(0));
    const result = flzCompressLen(&input);
    // Expected: 21 (from Rust test vectors)
    try std.testing.expectEqual(@as(u32, 21), result);
}

test "flz_compress_len - thousand forty twos" {
    const input = @as([1000]u8, @splat(42));
    const result = flzCompressLen(&input);
    // Expected: 21 (from Rust test vectors)
    try std.testing.expectEqual(@as(u32, 21), result);
}

test "flz_compress_len - sample contract call" {
    // Transaction from Rust test: 02f901550a758302df14...
    const input = [_]u8{
        0x02, 0xf9, 0x01, 0x55, 0x0a, 0x75, 0x83, 0x02, 0xdf, 0x14, 0x83, 0xbe, 0x21, 0xb8, 0x83, 0x04,
        0x74, 0x3f, 0x94, 0xf8, 0x0e, 0x51, 0xaf, 0xb6, 0x13, 0xd7, 0x64, 0xfa, 0x61, 0x75, 0x1a, 0xff,
        0xd3, 0x31, 0x3c, 0x19, 0x0a, 0x86, 0xbb, 0x87, 0x01, 0x51, 0xbd, 0x62, 0xfd, 0x12, 0xad, 0xb8,
        0xe4, 0x1e, 0xf2, 0x4f, 0x3f, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x6e, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0xaf, 0x88, 0xd0, 0x65, 0xe7, 0x7c, 0x8c, 0xc2, 0x23, 0x93, 0x27, 0xc5, 0xed, 0xb3, 0xa4,
        0x32, 0x26, 0x8e, 0x58, 0x31, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03,
        0xc1, 0xe5, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0xa0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x14, 0x8c, 0x89, 0xed, 0x21, 0x9d, 0x02, 0xf1, 0xa5, 0xbe, 0x01, 0x2c, 0x68, 0x9b, 0x4f,
        0x5b, 0x73, 0x18, 0x27, 0xbe, 0xbe, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0xc0, 0x01, 0xa0, 0x33, 0xfd, 0x89, 0xcb, 0x37, 0xc3, 0x1b, 0x2c, 0xba, 0x46, 0xb6,
        0x46, 0x6e, 0x04, 0x0c, 0x61, 0xfc, 0x9b, 0x2a, 0x36, 0x75, 0xa7, 0xf5, 0xf4, 0x93, 0xeb, 0xd5,
        0xad, 0x77, 0xc4, 0x97, 0xf8, 0xa0, 0x7c, 0xdf, 0x65, 0x68, 0x0e, 0x23, 0x83, 0x92, 0x69, 0x30,
        0x19, 0xb4, 0x09, 0x2f, 0x61, 0x02, 0x22, 0xe7, 0x1b, 0x7c, 0xec, 0x06, 0x44, 0x9c, 0xb9, 0x22,
        0xb9, 0x3b, 0x6a, 0x12, 0x74, 0x4e,
    };
    const result = flzCompressLen(&input);
    // Expected: 202 (from Rust test vectors)
    try std.testing.expectEqual(@as(u32, 202), result);
}

test "flz_compress_len - no repeats incremental" {
    var input = std.ArrayList(u8).empty;
    defer input.deinit(std.testing.allocator);

    var prev_len: u32 = 0;

    for (0..256) |i| {
        try input.append(std.testing.allocator, @intCast(i));
        const len = flzCompressLen(input.items);
        // Each new unique byte should increase compressed size
        try std.testing.expect(len > prev_len);
        prev_len = len;
    }
}

test "flz_compress_len - various sizes" {
    // Test that we don't crash on various input sizes
    var buf: [2000]u8 = undefined;

    for (0..2000) |size| {
        // Fill with pattern
        for (0..size) |i| {
            buf[i] = @intCast(i % 256);
        }
        const result = flzCompressLen(buf[0..size]);
        // Just verify we get a reasonable result without crashing
        try std.testing.expect(result <= size + 10);
    }
}

test "flz_compress_len - boundary cases" {
    // Test around the 13-byte boundary
    const input_12 = @as([12]u8, @splat(0xAB));
    const result_12 = flzCompressLen(&input_12);
    try std.testing.expectEqual(@as(u32, 13), result_12); // literals(12, 0) = 13

    const input_13 = @as([13]u8, @splat(0xAB));
    const result_13 = flzCompressLen(&input_13);
    try std.testing.expect(result_13 > 0);

    const input_14 = @as([14]u8, @splat(0xAB));
    const result_14 = flzCompressLen(&input_14);
    try std.testing.expect(result_14 > 0);
}
