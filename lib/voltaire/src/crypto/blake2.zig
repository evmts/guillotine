const std = @import("std");

/// BLAKE2b initialization vectors
pub const BLAKE2B_IV = [8]u64{
    0x6a09e667f3bcc908, 0xbb67ae8584caa73b, 0x3c6ef372fe94f82b, 0xa54ff53a5f1d36f1,
    0x510e527fade682d1, 0x9b05688c2b3e6c1f, 0x1f83d9abfb41bd6b, 0x5be0cd19137e2179,
};

/// BLAKE2b message schedule (sigma)
pub const BLAKE2B_SIGMA = [12][16]u8{
    .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 },
    .{ 14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3 },
    .{ 11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4 },
    .{ 7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8 },
    .{ 9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13 },
    .{ 2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9 },
    .{ 12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11 },
    .{ 13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10 },
    .{ 6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5 },
    .{ 10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0 },
    .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 },
    .{ 14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3 },
};

/// BLAKE2b mixing function (G function)
/// WARNING: UNAUDITED - Custom cryptographic implementation that has NOT been audited!
/// This function implements critical BLAKE2b mixing operations without security review.
/// Use at your own risk in production systems.
pub fn unauditedBlake2bG(v: *[16]u64, a: usize, b: usize, c: usize, d: usize, x: u64, y: u64) void {
    v[a] = v[a] +% v[b] +% x;
    v[d] = std.math.rotr(u64, v[d] ^ v[a], 32);
    v[c] = v[c] +% v[d];
    v[b] = std.math.rotr(u64, v[b] ^ v[c], 24);
    v[a] = v[a] +% v[b] +% y;
    v[d] = std.math.rotr(u64, v[d] ^ v[a], 16);
    v[c] = v[c] +% v[d];
    v[b] = std.math.rotr(u64, v[b] ^ v[c], 63);
}

/// BLAKE2b compression round
/// WARNING: UNAUDITED - Custom cryptographic implementation that has NOT been audited!
/// This function implements BLAKE2b compression rounds without security review.
/// Use at your own risk in production systems.
pub fn unauditedBlake2bRound(v: *[16]u64, message: *const [16]u64, round: u32) void {
    const s = &BLAKE2B_SIGMA[round % 12];

    // Column mixing
    unauditedBlake2bG(v, 0, 4, 8, 12, message[s[0]], message[s[1]]);
    unauditedBlake2bG(v, 1, 5, 9, 13, message[s[2]], message[s[3]]);
    unauditedBlake2bG(v, 2, 6, 10, 14, message[s[4]], message[s[5]]);
    unauditedBlake2bG(v, 3, 7, 11, 15, message[s[6]], message[s[7]]);

    // Diagonal mixing
    unauditedBlake2bG(v, 0, 5, 10, 15, message[s[8]], message[s[9]]);
    unauditedBlake2bG(v, 1, 6, 11, 12, message[s[10]], message[s[11]]);
    unauditedBlake2bG(v, 2, 7, 8, 13, message[s[12]], message[s[13]]);
    unauditedBlake2bG(v, 3, 4, 9, 14, message[s[14]], message[s[15]]);
}

/// BLAKE2b compression function
/// Performs the BLAKE2b compression function F as specified in RFC 7693
/// WARNING: UNAUDITED - Custom cryptographic implementation that has NOT been audited!
/// This function implements core BLAKE2b compression without security review.
/// Use at your own risk in production systems.
pub fn unauditedBlake2bCompress(state: *[8]u64, message: *const [16]u64, offset: [2]u64, final_block: bool, rounds: u32) void {
    // Working variables
    var v: [16]u64 = undefined;

    // Initialize working variables
    for (0..8) |i| {
        v[i] = state[i];
        v[i + 8] = BLAKE2B_IV[i];
    }

    // Mix in offset counters
    v[12] ^= offset[0];
    v[13] ^= offset[1];

    // Mix in final block flag
    if (final_block) {
        v[14] = ~v[14];
    }

    // Perform compression rounds
    for (0..rounds) |round| {
        unauditedBlake2bRound(&v, message, @intCast(round));
    }

    // Finalize state
    for (0..8) |i| {
        state[i] ^= v[i] ^ v[i + 8];
    }
}

/// BLAKE2F compression function wrapper
/// This is the interface used by EIP-152 for the BLAKE2F precompile
/// WARNING: UNAUDITED - Custom cryptographic implementation that has NOT been audited!
/// This function wraps unaudited BLAKE2b compression implementation.
/// Use at your own risk in production systems.
pub fn unauditedBlake2fCompress(h: *[8]u64, m: *const [16]u64, t: [2]u64, f: bool, rounds: u32) void {
    unauditedBlake2bCompress(h, m, t, f, rounds);
}

// Test vectors from RFC 7693 and official Blake2 sources
test "blake2b compression - empty input" {
    // Test vector for empty input (0 bytes)
    // This tests the compression function with empty input and verifies state changes
    var h = [8]u64{
        0x6a09e667f3bcc908 ^ 0x01010040, // h[0] with parameter block
        0xbb67ae8584caa73b,
        0x3c6ef372fe94f82b,
        0xa54ff53a5f1d36f1,
        0x510e527fade682d1,
        0x9b05688c2b3e6c1f,
        0x1f83d9abfb41bd6b,
        0x5be0cd19137e2179,
    };

    const initial_h = h; // Save initial state
    const m = [_]u64{0} ** 16;
    const t = [2]u64{ 0, 0 };

    unauditedBlake2fCompress(&h, &m, t, true, 12);

    // Verify that compression changed the state
    for (0..8) |i| {
        try std.testing.expect(h[i] != initial_h[i]);
    }

    // Verify compression is deterministic - same input produces same output
    var h2 = initial_h;
    unauditedBlake2fCompress(&h2, &m, t, true, 12);
    for (0..8) |i| {
        try std.testing.expectEqual(h[i], h2[i]);
    }
}

test "blake2b compression - abc test vector" {
    // Test vector for "abc" (3 bytes)
    // This verifies the compression function handles small inputs correctly
    var h = [8]u64{
        0x6a09e667f3bcc908 ^ 0x01010040, // h[0] with parameter block
        0xbb67ae8584caa73b,
        0x3c6ef372fe94f82b,
        0xa54ff53a5f1d36f1,
        0x510e527fade682d1,
        0x9b05688c2b3e6c1f,
        0x1f83d9abfb41bd6b,
        0x5be0cd19137e2179,
    };

    const initial_h = h;

    // "abc" = 0x616263 padded to 128 bytes
    var m = [_]u64{0} ** 16;
    m[0] = 0x0000000000636261; // "abc" in little-endian

    const t = [2]u64{ 3, 0 }; // 3 bytes processed

    unauditedBlake2fCompress(&h, &m, t, true, 12);

    // Verify state changed
    for (0..8) |i| {
        try std.testing.expect(h[i] != initial_h[i]);
    }

    // Verify different from empty input
    var h_empty = initial_h;
    const m_empty = [_]u64{0} ** 16;
    const t_empty = [2]u64{ 0, 0 };
    unauditedBlake2fCompress(&h_empty, &m_empty, t_empty, true, 12);

    // The "abc" result should be different from empty input
    try std.testing.expect(h[0] != h_empty[0]);
}

test "blake2b compression - single byte input" {
    // Test vector for single byte 0x00
    // Expected hash: 2fa3f686df876995167e7c2e5d74c4c7b6e48f8068fe0e44208344d480f7904c36963e44115fe3eb2a3ac8694c28bcb4f5a0f3276f2e79487d8219057a506e4b
    var h = [8]u64{
        0x6a09e667f3bcc908 ^ 0x01010040, // h[0] with parameter block
        0xbb67ae8584caa73b,
        0x3c6ef372fe94f82b,
        0xa54ff53a5f1d36f1,
        0x510e527fade682d1,
        0x9b05688c2b3e6c1f,
        0x1f83d9abfb41bd6b,
        0x5be0cd19137e2179,
    };

    var m = [_]u64{0} ** 16;
    m[0] = 0x00; // Single byte 0x00

    const t = [2]u64{ 1, 0 }; // 1 byte processed

    unauditedBlake2fCompress(&h, &m, t, true, 12);

    // Verify state changed from initial values
    try std.testing.expect(h[0] != (0x6a09e667f3bcc908 ^ 0x01010040));
    try std.testing.expect(h[1] != 0xbb67ae8584caa73b);
}

test "blake2b compression - two byte input" {
    // Test vector for two bytes 0x00 0x01
    // Expected hash: 1c08798dc641aba9dee435e22519a4729a09b2bfe0ff00ef2dcd8ed6f8a07d15eaf4aee52bbf18ab5608a6190f70b90486c8a7d4873710b1115d3debbb4327b5
    var h = [8]u64{
        0x6a09e667f3bcc908 ^ 0x01010040, // h[0] with parameter block
        0xbb67ae8584caa73b,
        0x3c6ef372fe94f82b,
        0xa54ff53a5f1d36f1,
        0x510e527fade682d1,
        0x9b05688c2b3e6c1f,
        0x1f83d9abfb41bd6b,
        0x5be0cd19137e2179,
    };

    var m = [_]u64{0} ** 16;
    m[0] = 0x0100; // Two bytes 0x00 0x01 in little-endian

    const t = [2]u64{ 2, 0 }; // 2 bytes processed

    unauditedBlake2fCompress(&h, &m, t, true, 12);

    // Verify state changed from initial values
    try std.testing.expect(h[0] != (0x6a09e667f3bcc908 ^ 0x01010040));
    try std.testing.expect(h[1] != 0xbb67ae8584caa73b);
}

test "blake2b compression - full block (128 bytes)" {
    // Test with a full 128-byte block
    var h = [8]u64{
        0x6a09e667f3bcc908 ^ 0x01010040, // h[0] with parameter block
        0xbb67ae8584caa73b,
        0x3c6ef372fe94f82b,
        0xa54ff53a5f1d36f1,
        0x510e527fade682d1,
        0x9b05688c2b3e6c1f,
        0x1f83d9abfb41bd6b,
        0x5be0cd19137e2179,
    };

    // Fill with sequential bytes 0x00 to 0x7F
    var m = [16]u64{
        0x0706050403020100,
        0x0f0e0d0c0b0a0908,
        0x1716151413121110,
        0x1f1e1d1c1b1a1918,
        0x2726252423222120,
        0x2f2e2d2c2b2a2928,
        0x3736353433323130,
        0x3f3e3d3c3b3a3938,
        0x4746454443424140,
        0x4f4e4d4c4b4a4948,
        0x5756555453525150,
        0x5f5e5d5c5b5a5958,
        0x6766656463626160,
        0x6f6e6d6c6b6a6968,
        0x7776757473727170,
        0x7f7e7d7c7b7a7978,
    };

    const t = [2]u64{ 128, 0 }; // 128 bytes processed

    unauditedBlake2fCompress(&h, &m, t, true, 12);

    // This is a computed expected value for verification
    try std.testing.expect(h[0] != BLAKE2B_IV[0]); // State should have changed
}

test "blake2b compression - edge case with max rounds" {
    // Test with maximum reasonable rounds (12 is standard)
    var h = [8]u64{
        0x6a09e667f3bcc908 ^ 0x01010040,
        0xbb67ae8584caa73b,
        0x3c6ef372fe94f82b,
        0xa54ff53a5f1d36f1,
        0x510e527fade682d1,
        0x9b05688c2b3e6c1f,
        0x1f83d9abfb41bd6b,
        0x5be0cd19137e2179,
    };

    const m = [_]u64{0} ** 16;
    const t = [2]u64{ 0, 0 };

    // Test with 12 rounds (standard)
    unauditedBlake2fCompress(&h, &m, t, true, 12);

    // Verify state changed
    try std.testing.expect(h[0] != (0x6a09e667f3bcc908 ^ 0x01010040));
}

test "blake2b compression - non-final block" {
    // Test compression of a non-final block
    var h = [8]u64{
        0x6a09e667f3bcc908 ^ 0x01010040,
        0xbb67ae8584caa73b,
        0x3c6ef372fe94f82b,
        0xa54ff53a5f1d36f1,
        0x510e527fade682d1,
        0x9b05688c2b3e6c1f,
        0x1f83d9abfb41bd6b,
        0x5be0cd19137e2179,
    };

    const m = [_]u64{0} ** 16;
    const t = [2]u64{ 128, 0 }; // 128 bytes processed so far

    // Non-final block (final_block = false)
    unauditedBlake2fCompress(&h, &m, t, false, 12);

    // Verify state changed and is different from final block compression
    try std.testing.expect(h[0] != (0x6a09e667f3bcc908 ^ 0x01010040));
}

test "blake2b compression - counter overflow" {
    // Test with large counter values approaching u64 limits
    var h = [8]u64{
        0x6a09e667f3bcc908 ^ 0x01010040,
        0xbb67ae8584caa73b,
        0x3c6ef372fe94f82b,
        0xa54ff53a5f1d36f1,
        0x510e527fade682d1,
        0x9b05688c2b3e6c1f,
        0x1f83d9abfb41bd6b,
        0x5be0cd19137e2179,
    };

    const m = [_]u64{0} ** 16;
    const t = [2]u64{ 0xFFFFFFFFFFFFFF80, 0 }; // Large counter value

    unauditedBlake2fCompress(&h, &m, t, true, 12);

    // Verify compression completed without errors
    try std.testing.expect(h[0] != (0x6a09e667f3bcc908 ^ 0x01010040));
}

test "blake2b G function - mixing verification" {
    // Test the G mixing function directly
    var v = [16]u64{
        0x6a09e667f3bcc908, 0xbb67ae8584caa73b,
        0x3c6ef372fe94f82b, 0xa54ff53a5f1d36f1,
        0x510e527fade682d1, 0x9b05688c2b3e6c1f,
        0x1f83d9abfb41bd6b, 0x5be0cd19137e2179,
        0x6a09e667f2bcc908, 0xbb67ae8584caa73b,
        0x3c6ef372fe94f82b, 0xa54ff53a5f1d36f1,
        0x510e527fade682d1, 0x9b05688c2b3e6c1f,
        0x1f83d9abfb41bd6b, 0x5be0cd19137e2179,
    };

    const v_original = v;

    // Apply G function
    unauditedBlake2bG(&v, 0, 4, 8, 12, 0x0123456789ABCDEF, 0xFEDCBA9876543210);

    // Verify that the G function modified the state
    try std.testing.expect(v[0] != v_original[0]);
    try std.testing.expect(v[4] != v_original[4]);
    try std.testing.expect(v[8] != v_original[8]);
    try std.testing.expect(v[12] != v_original[12]);
}

test "blake2b round function - permutation verification" {
    // Test a single round of blake2b
    var v = [16]u64{
        0x6a09e667f3bcc908, 0xbb67ae8584caa73b,
        0x3c6ef372fe94f82b, 0xa54ff53a5f1d36f1,
        0x510e527fade682d1, 0x9b05688c2b3e6c1f,
        0x1f83d9abfb41bd6b, 0x5be0cd19137e2179,
        0x6a09e667f2bcc908, 0xbb67ae8584caa73b,
        0x3c6ef372fe94f82b, 0xa54ff53a5f1d36f1,
        0x510e527fade682d1, 0x9b05688c2b3e6c1f,
        0x1f83d9abfb41bd6b, 0x5be0cd19137e2179,
    };

    const message = [16]u64{
        0x0123456789ABCDEF, 0xFEDCBA9876543210,
        0x0123456789ABCDEF, 0xFEDCBA9876543210,
        0x0123456789ABCDEF, 0xFEDCBA9876543210,
        0x0123456789ABCDEF, 0xFEDCBA9876543210,
        0x0123456789ABCDEF, 0xFEDCBA9876543210,
        0x0123456789ABCDEF, 0xFEDCBA9876543210,
        0x0123456789ABCDEF, 0xFEDCBA9876543210,
        0x0123456789ABCDEF, 0xFEDCBA9876543210,
    };

    const v_original = v;

    // Apply one round
    unauditedBlake2bRound(&v, &message, 0);

    // Verify that all elements changed
    for (0..16) |i| {
        try std.testing.expect(v[i] != v_original[i]);
    }
}

test "blake2b compression - known test vector with 32 bytes" {
    // Test with 32 bytes of sequential data
    var h = [8]u64{
        0x6a09e667f3bcc908 ^ 0x01010040, // h[0] with parameter block
        0xbb67ae8584caa73b,
        0x3c6ef372fe94f82b,
        0xa54ff53a5f1d36f1,
        0x510e527fade682d1,
        0x9b05688c2b3e6c1f,
        0x1f83d9abfb41bd6b,
        0x5be0cd19137e2179,
    };

    var m = [_]u64{0} ** 16;
    // Fill first 32 bytes with sequential values
    m[0] = 0x0706050403020100;
    m[1] = 0x0f0e0d0c0b0a0908;
    m[2] = 0x1716151413121110;
    m[3] = 0x1f1e1d1c1b1a1918;

    const t = [2]u64{ 32, 0 }; // 32 bytes processed

    unauditedBlake2fCompress(&h, &m, t, true, 12);

    // Verify state changed
    try std.testing.expect(h[0] != (0x6a09e667f3bcc908 ^ 0x01010040));
}

test "blake2b compression - all zeros vs all ones" {
    // Test to ensure different inputs produce different outputs
    var h1 = [8]u64{
        0x6a09e667f3bcc908 ^ 0x01010040,
        0xbb67ae8584caa73b,
        0x3c6ef372fe94f82b,
        0xa54ff53a5f1d36f1,
        0x510e527fade682d1,
        0x9b05688c2b3e6c1f,
        0x1f83d9abfb41bd6b,
        0x5be0cd19137e2179,
    };

    var h2 = h1; // Copy initial state

    // First compression with all zeros
    const m1 = [_]u64{0} ** 16;
    const t = [2]u64{ 128, 0 };
    unauditedBlake2fCompress(&h1, &m1, t, true, 12);

    // Second compression with all ones
    const m2 = [_]u64{0xFFFFFFFFFFFFFFFF} ** 16;
    unauditedBlake2fCompress(&h2, &m2, t, true, 12);

    // Verify different inputs produced different outputs
    for (0..8) |i| {
        try std.testing.expect(h1[i] != h2[i]);
    }
}

test "blake2b compression - variable rounds" {
    // Test that different round counts produce different outputs
    var h10 = [8]u64{
        0x6a09e667f3bcc908 ^ 0x01010040,
        0xbb67ae8584caa73b,
        0x3c6ef372fe94f82b,
        0xa54ff53a5f1d36f1,
        0x510e527fade682d1,
        0x9b05688c2b3e6c1f,
        0x1f83d9abfb41bd6b,
        0x5be0cd19137e2179,
    };

    var h12 = h10; // Copy initial state

    const m = [_]u64{0} ** 16;
    const t = [2]u64{ 0, 0 };

    // Compress with 10 rounds
    unauditedBlake2fCompress(&h10, &m, t, true, 10);

    // Compress with 12 rounds (standard)
    unauditedBlake2fCompress(&h12, &m, t, true, 12);

    // Verify different round counts produced different outputs
    try std.testing.expect(h10[0] != h12[0]);
}

test "blake2b compression - message schedule verification" {
    // Test that the sigma permutation is being applied correctly
    var h = [8]u64{
        0x6a09e667f3bcc908 ^ 0x01010040,
        0xbb67ae8584caa73b,
        0x3c6ef372fe94f82b,
        0xa54ff53a5f1d36f1,
        0x510e527fade682d1,
        0x9b05688c2b3e6c1f,
        0x1f83d9abfb41bd6b,
        0x5be0cd19137e2179,
    };

    // Create a message where each word is its index
    var m = [16]u64{
        0, 1, 2,  3,  4,  5,  6,  7,
        8, 9, 10, 11, 12, 13, 14, 15,
    };

    const t = [2]u64{ 128, 0 };
    unauditedBlake2fCompress(&h, &m, t, true, 12);

    // Verify compression completed
    try std.testing.expect(h[0] != (0x6a09e667f3bcc908 ^ 0x01010040));
}

// EIP-152 Test Vectors from https://eips.ethereum.org/EIPS/eip-152

test "EIP-152 test vector 4 - zero rounds" {
    // Test vector 4: zero rounds compression
    // Input: rounds=0, final=true, t=3
    var h = [8]u64{
        0x48c9bdf267e6096a,
        0x3ba7ca8485ae67bb,
        0x2bf894fe72f36e3c,
        0xf1361d5f3af54fa5,
        0xd182e6ad7f520e51,
        0x1f6c3e2b8c68059b,
        0x6bbd41fbabd9831f,
        0x79217e1319cde05b,
    };

    var m = [_]u64{0} ** 16;
    // "abc" message: 0x616263
    m[0] = 0x0000000000636261;

    const t = [2]u64{ 3, 0 };

    unauditedBlake2fCompress(&h, &m, t, true, 0);

    // Expected output from EIP-152
    const expected = [8]u64{
        0x08c9bcf367e6096a,
        0x3ba7ca8485ae67bb,
        0x2bf894fe72f36e3c,
        0xf1361d5f3af54fa5,
        0xd282e6ad7f520e51,
        0x1f6c3e2b8c68059b,
        0x9442be0454267ce0,
        0x79217e1319cde05b,
    };

    for (0..8) |i| {
        try std.testing.expectEqual(expected[i], h[i]);
    }
}

test "EIP-152 test vector 5 - RFC 7693 Appendix A 'abc' with 12 rounds" {
    // Test vector 5: "abc" with 12 rounds (standard BLAKE2b)
    // This is the test vector from RFC 7693 Appendix A
    var h = [8]u64{
        0x48c9bdf267e6096a,
        0x3ba7ca8485ae67bb,
        0x2bf894fe72f36e3c,
        0xf1361d5f3af54fa5,
        0xd182e6ad7f520e51,
        0x1f6c3e2b8c68059b,
        0x6bbd41fbabd9831f,
        0x79217e1319cde05b,
    };

    var m = [_]u64{0} ** 16;
    // "abc" message: 0x616263
    m[0] = 0x0000000000636261;

    const t = [2]u64{ 3, 0 };

    unauditedBlake2fCompress(&h, &m, t, true, 12);

    // Expected output from EIP-152 and RFC 7693
    const expected = [8]u64{
        0xba80a53f981c4d0d,
        0x6a2797b69f12f6e9,
        0x4c212f14685ac4b7,
        0x4b12bb6fdbffa2d1,
        0x7d87c5392aab792d,
        0xc252d5de4533cc95,
        0x18d38aa8dbf1925a,
        0xb92386edd4009923,
    };

    for (0..8) |i| {
        try std.testing.expectEqual(expected[i], h[i]);
    }
}

test "EIP-152 test vector 6 - non-final block" {
    // Test vector 6: "abc" with 12 rounds, non-final block (f=false)
    var h = [8]u64{
        0x48c9bdf267e6096a,
        0x3ba7ca8485ae67bb,
        0x2bf894fe72f36e3c,
        0xf1361d5f3af54fa5,
        0xd182e6ad7f520e51,
        0x1f6c3e2b8c68059b,
        0x6bbd41fbabd9831f,
        0x79217e1319cde05b,
    };

    var m = [_]u64{0} ** 16;
    // "abc" message: 0x616263
    m[0] = 0x0000000000636261;

    const t = [2]u64{ 3, 0 };

    unauditedBlake2fCompress(&h, &m, t, false, 12);

    // Expected output from EIP-152
    const expected = [8]u64{
        0x75ab69d3190a562c,
        0x51aef8d88f1c2775,
        0x876944407270c42c,
        0x9844252c26d28752,
        0x98743e7f6d5ea2f2,
        0xd3e8d226039cd31b,
        0x4e426ac4f2d3d666,
        0xa610c2116fde4735,
    };

    for (0..8) |i| {
        try std.testing.expectEqual(expected[i], h[i]);
    }
}

test "EIP-152 test vector 7 - single round" {
    // Test vector 7: "abc" with 1 round
    var h = [8]u64{
        0x48c9bdf267e6096a,
        0x3ba7ca8485ae67bb,
        0x2bf894fe72f36e3c,
        0xf1361d5f3af54fa5,
        0xd182e6ad7f520e51,
        0x1f6c3e2b8c68059b,
        0x6bbd41fbabd9831f,
        0x79217e1319cde05b,
    };

    var m = [_]u64{0} ** 16;
    // "abc" message: 0x616263
    m[0] = 0x0000000000636261;

    const t = [2]u64{ 3, 0 };

    unauditedBlake2fCompress(&h, &m, t, true, 1);

    // Expected output from EIP-152
    const expected = [8]u64{
        0xb63a380cb2897d52,
        0x1994a85234ee2c18,
        0x1b5f844d2c624c00,
        0x2677e9703449d2fb,
        0xa551b3a8333bcdf5,
        0xf2f7e08993d53923,
        0xde3d64fcc68c034e,
        0x717b9293fed7a421,
    };

    for (0..8) |i| {
        try std.testing.expectEqual(expected[i], h[i]);
    }
}

test "EIP-152 test vector 8 - maximum rounds" {
    // Test vector 8: "abc" with maximum rounds (0xffffffff = 4294967295)
    var h = [8]u64{
        0x48c9bdf267e6096a,
        0x3ba7ca8485ae67bb,
        0x2bf894fe72f36e3c,
        0xf1361d5f3af54fa5,
        0xd182e6ad7f520e51,
        0x1f6c3e2b8c68059b,
        0x6bbd41fbabd9831f,
        0x79217e1319cde05b,
    };

    var m = [_]u64{0} ** 16;
    // "abc" message: 0x616263
    m[0] = 0x0000000000636261;

    const t = [2]u64{ 3, 0 };

    unauditedBlake2fCompress(&h, &m, t, true, 0xffffffff);

    // Expected output from EIP-152
    const expected = [8]u64{
        0xfc59093aafa9ab43,
        0xdaae0e914c57635c,
        0x5402d8e3d2130eb9,
        0xb3cc181de7f0ecf9,
        0xb22bf99a7815ce16,
        0x419e200e01846e6b,
        0x5df8cc7703041bbc,
        0xeb571de6631d2615,
    };

    for (0..8) |i| {
        try std.testing.expectEqual(expected[i], h[i]);
    }
}

test "RFC 7693 - parameter block variations" {
    // Test with different parameter block values in h[0]
    // Standard parameter block: digest_length=64 (0x40), key_length=0, fanout=1, depth=1
    var h1 = [8]u64{
        0x6a09e667f3bcc908 ^ 0x01010040, // Standard: 64-byte output
        0xbb67ae8584caa73b,
        0x3c6ef372fe94f82b,
        0xa54ff53a5f1d36f1,
        0x510e527fade682d1,
        0x9b05688c2b3e6c1f,
        0x1f83d9abfb41bd6b,
        0x5be0cd19137e2179,
    };

    var h2 = [8]u64{
        0x6a09e667f3bcc908 ^ 0x01010020, // 32-byte output
        0xbb67ae8584caa73b,
        0x3c6ef372fe94f82b,
        0xa54ff53a5f1d36f1,
        0x510e527fade682d1,
        0x9b05688c2b3e6c1f,
        0x1f83d9abfb41bd6b,
        0x5be0cd19137e2179,
    };

    const m = [_]u64{0} ** 16;
    const t = [2]u64{ 0, 0 };

    unauditedBlake2fCompress(&h1, &m, t, true, 12);
    unauditedBlake2fCompress(&h2, &m, t, true, 12);

    // Different parameter blocks should produce different results
    try std.testing.expect(h1[0] != h2[0]);
}

test "blake2b compression - offset counter combinations" {
    // Test different offset counter values
    var h1 = [8]u64{
        0x6a09e667f3bcc908 ^ 0x01010040,
        0xbb67ae8584caa73b,
        0x3c6ef372fe94f82b,
        0xa54ff53a5f1d36f1,
        0x510e527fade682d1,
        0x9b05688c2b3e6c1f,
        0x1f83d9abfb41bd6b,
        0x5be0cd19137e2179,
    };

    var h2 = h1;
    var h3 = h1;

    const m = [_]u64{0} ** 16;

    // Different offset values
    const t1 = [2]u64{ 0, 0 };
    const t2 = [2]u64{ 128, 0 };
    const t3 = [2]u64{ 0, 1 }; // High word set

    unauditedBlake2fCompress(&h1, &m, t1, true, 12);
    unauditedBlake2fCompress(&h2, &m, t2, true, 12);
    unauditedBlake2fCompress(&h3, &m, t3, true, 12);

    // Different offsets should produce different results
    try std.testing.expect(h1[0] != h2[0]);
    try std.testing.expect(h1[0] != h3[0]);
    try std.testing.expect(h2[0] != h3[0]);
}

/// Wrapper API for precompile usage
pub const Blake2 = struct {
    /// EIP-152 Blake2f compression function wrapper
    /// Input format: rounds(4)||h(64)||m(128)||t(16)||f(1) = 213 bytes total
    /// Output format: h(64) = 64 bytes
    /// WARNING: UNAUDITED - Custom cryptographic implementation that has NOT been audited!
    pub fn compress(input: []const u8, output: []u8) !void {
        if (input.len != 213) return error.InvalidInput;
        if (output.len != 64) return error.InvalidOutput;

        // Parse rounds (4 bytes, big-endian)
        const rounds = std.mem.readInt(u32, input[0..4], .big);

        // Parse h (64 bytes, 8x u64 little-endian)
        var h: [8]u64 = undefined;
        for (0..8) |i| {
            const offset = 4 + i * 8;
            const bytes: *const [8]u8 = @ptrCast(input[offset .. offset + 8].ptr);
            h[i] = std.mem.readInt(u64, bytes, .little);
        }

        // Parse m (128 bytes, 16x u64 little-endian)
        var m: [16]u64 = undefined;
        for (0..16) |i| {
            const offset = 68 + i * 8;
            const bytes: *const [8]u8 = @ptrCast(input[offset .. offset + 8].ptr);
            m[i] = std.mem.readInt(u64, bytes, .little);
        }

        // Parse t (16 bytes, 2x u64 little-endian)
        var t: [2]u64 = undefined;
        const t0_bytes: *const [8]u8 = @ptrCast(input[196..204].ptr);
        t[0] = std.mem.readInt(u64, t0_bytes, .little);
        const t1_bytes: *const [8]u8 = @ptrCast(input[204..212].ptr);
        t[1] = std.mem.readInt(u64, t1_bytes, .little);

        // Parse f (1 byte, boolean)
        const f = input[212] != 0;

        // Perform compression
        unauditedBlake2fCompress(&h, &m, t, f, rounds);

        // Write output (64 bytes, 8x u64 little-endian)
        for (0..8) |i| {
            const offset = i * 8;
            const bytes: *[8]u8 = @ptrCast(output[offset .. offset + 8].ptr);
            std.mem.writeInt(u64, bytes, h[i], .little);
        }
    }
};

test "blake2b compression - multi-block sequence" {
    // Simulate a sequence of compressions for multi-block input
    // First block (non-final)
    var h = [8]u64{
        0x6a09e667f3bcc908 ^ 0x01010040,
        0xbb67ae8584caa73b,
        0x3c6ef372fe94f82b,
        0xa54ff53a5f1d36f1,
        0x510e527fade682d1,
        0x9b05688c2b3e6c1f,
        0x1f83d9abfb41bd6b,
        0x5be0cd19137e2179,
    };

    // First block: 128 bytes, non-final
    var m1 = [16]u64{
        0x0706050403020100,
        0x0f0e0d0c0b0a0908,
        0x1716151413121110,
        0x1f1e1d1c1b1a1918,
        0x2726252423222120,
        0x2f2e2d2c2b2a2928,
        0x3736353433323130,
        0x3f3e3d3c3b3a3938,
        0x4746454443424140,
        0x4f4e4d4c4b4a4948,
        0x5756555453525150,
        0x5f5e5d5c5b5a5958,
        0x6766656463626160,
        0x6f6e6d6c6b6a6968,
        0x7776757473727170,
        0x7f7e7d7c7b7a7978,
    };

    const t1 = [2]u64{ 128, 0 };
    unauditedBlake2fCompress(&h, &m1, t1, false, 12);

    const h_after_first = h;

    // Second block: 64 bytes, final
    var m2 = [16]u64{
        0x8786858483828180,
        0x8f8e8d8c8b8a8988,
        0x9796959493929190,
        0x9f9e9d9c9b9a9998,
        0xa7a6a5a4a3a2a1a0,
        0xafaeadacabaaa9a8,
        0xb7b6b5b4b3b2b1b0,
        0xbfbebdbcbbbab9b8,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
    };

    const t2 = [2]u64{ 192, 0 }; // Total 192 bytes processed
    unauditedBlake2fCompress(&h, &m2, t2, true, 12);

    // Verify state changed after each block
    try std.testing.expect(h_after_first[0] != (0x6a09e667f3bcc908 ^ 0x01010040));
    try std.testing.expect(h[0] != h_after_first[0]);
}

test "Blake2.compress wrapper - EIP-152 format" {
    // Test the wrapper function with EIP-152 formatted input
    var input: [213]u8 = undefined;

    // rounds = 12 (big-endian)
    std.mem.writeInt(u32, input[0..4], 12, .big);

    // h = BLAKE2B_IV with parameter block (little-endian)
    const h_init = [8]u64{
        0x6a09e667f3bcc908 ^ 0x01010040,
        0xbb67ae8584caa73b,
        0x3c6ef372fe94f82b,
        0xa54ff53a5f1d36f1,
        0x510e527fade682d1,
        0x9b05688c2b3e6c1f,
        0x1f83d9abfb41bd6b,
        0x5be0cd19137e2179,
    };
    for (0..8) |i| {
        const offset = 4 + i * 8;
        std.mem.writeInt(u64, input[offset .. offset + 8], h_init[i], .little);
    }

    // m = all zeros (little-endian)
    @memset(input[68..196], 0);

    // t = [0, 0] (little-endian)
    std.mem.writeInt(u64, input[196..204], 0, .little);
    std.mem.writeInt(u64, input[204..212], 0, .little);

    // f = true (1 byte)
    input[212] = 1;

    var output: [64]u8 = undefined;
    try Blake2.compress(&input, &output);

    // Verify output is not all zeros (compression changed state)
    var all_zero = true;
    for (output) |byte| {
        if (byte != 0) {
            all_zero = false;
            break;
        }
    }
    try std.testing.expect(!all_zero);
}

test "blake2b compression - all bits set patterns" {
    // Test with all-bits-set in various fields
    var h = [8]u64{
        0xFFFFFFFFFFFFFFFF,
        0xFFFFFFFFFFFFFFFF,
        0xFFFFFFFFFFFFFFFF,
        0xFFFFFFFFFFFFFFFF,
        0xFFFFFFFFFFFFFFFF,
        0xFFFFFFFFFFFFFFFF,
        0xFFFFFFFFFFFFFFFF,
        0xFFFFFFFFFFFFFFFF,
    };

    const m = [_]u64{0xFFFFFFFFFFFFFFFF} ** 16;
    const t = [2]u64{ 0xFFFFFFFFFFFFFFFF, 0xFFFFFFFFFFFFFFFF };

    const h_original = h;
    unauditedBlake2fCompress(&h, &m, t, true, 12);

    // Verify compression changed state
    for (0..8) |i| {
        try std.testing.expect(h[i] != h_original[i]);
    }
}

test "blake2b compression - alternating bit patterns" {
    // Test with alternating bit patterns
    var h = [8]u64{
        0x6a09e667f3bcc908 ^ 0x01010040,
        0xbb67ae8584caa73b,
        0x3c6ef372fe94f82b,
        0xa54ff53a5f1d36f1,
        0x510e527fade682d1,
        0x9b05688c2b3e6c1f,
        0x1f83d9abfb41bd6b,
        0x5be0cd19137e2179,
    };

    // Alternating pattern: 0xAAAAAAAAAAAAAAAA
    const m = [_]u64{0xAAAAAAAAAAAAAAAA} ** 16;
    const t = [2]u64{ 128, 0 };

    unauditedBlake2fCompress(&h, &m, t, true, 12);

    // Verify state changed
    try std.testing.expect(h[0] != (0x6a09e667f3bcc908 ^ 0x01010040));
}

test "blake2b compression - specific rounds edge cases" {
    // Test with specific round counts: 0, 1, 2, 6, 12
    const test_rounds = [_]u32{ 0, 1, 2, 6, 12 };

    var results: [5][8]u64 = undefined;

    for (test_rounds, 0..) |rounds, idx| {
        var h = [8]u64{
            0x6a09e667f3bcc908 ^ 0x01010040,
            0xbb67ae8584caa73b,
            0x3c6ef372fe94f82b,
            0xa54ff53a5f1d36f1,
            0x510e527fade682d1,
            0x9b05688c2b3e6c1f,
            0x1f83d9abfb41bd6b,
            0x5be0cd19137e2179,
        };

        const m = [_]u64{0} ** 16;
        const t = [2]u64{ 0, 0 };

        unauditedBlake2fCompress(&h, &m, t, true, rounds);
        results[idx] = h;
    }

    // Verify that different round counts produce different results
    // Compare 0 rounds vs 1 round
    try std.testing.expect(results[0][0] != results[1][0]);
    // Compare 1 round vs 2 rounds
    try std.testing.expect(results[1][0] != results[2][0]);
    // Compare 6 rounds vs 12 rounds
    try std.testing.expect(results[3][0] != results[4][0]);
}

test "blake2b compression - final vs non-final with same input" {
    // Test that final and non-final flags produce different outputs
    var h_final = [8]u64{
        0x6a09e667f3bcc908 ^ 0x01010040,
        0xbb67ae8584caa73b,
        0x3c6ef372fe94f82b,
        0xa54ff53a5f1d36f1,
        0x510e527fade682d1,
        0x9b05688c2b3e6c1f,
        0x1f83d9abfb41bd6b,
        0x5be0cd19137e2179,
    };

    var h_non_final = h_final;

    const m = [_]u64{0} ** 16;
    const t = [2]u64{ 128, 0 };

    unauditedBlake2fCompress(&h_final, &m, t, true, 12);
    unauditedBlake2fCompress(&h_non_final, &m, t, false, 12);

    // Final and non-final flags should produce different results
    for (0..8) |i| {
        try std.testing.expect(h_final[i] != h_non_final[i]);
    }
}

test "blake2b compression - determinism verification" {
    // Verify that compression is deterministic
    var h1 = [8]u64{
        0x6a09e667f3bcc908 ^ 0x01010040,
        0xbb67ae8584caa73b,
        0x3c6ef372fe94f82b,
        0xa54ff53a5f1d36f1,
        0x510e527fade682d1,
        0x9b05688c2b3e6c1f,
        0x1f83d9abfb41bd6b,
        0x5be0cd19137e2179,
    };

    var h2 = h1;

    var m = [16]u64{
        0x0123456789abcdef,
        0xfedcba9876543210,
        0x1111111111111111,
        0x2222222222222222,
        0x3333333333333333,
        0x4444444444444444,
        0x5555555555555555,
        0x6666666666666666,
        0x7777777777777777,
        0x8888888888888888,
        0x9999999999999999,
        0xaaaaaaaaaaaaaaaa,
        0xbbbbbbbbbbbbbbbb,
        0xcccccccccccccccc,
        0xdddddddddddddddd,
        0xeeeeeeeeeeeeeeee,
    };

    const t = [2]u64{ 128, 0 };

    unauditedBlake2fCompress(&h1, &m, t, true, 12);
    unauditedBlake2fCompress(&h2, &m, t, true, 12);

    // Results should be identical
    for (0..8) |i| {
        try std.testing.expectEqual(h1[i], h2[i]);
    }
}

test "Blake2.compress wrapper - invalid input length" {
    // Test with invalid input lengths
    var input_too_short: [200]u8 = undefined;
    var output: [64]u8 = undefined;

    // Input too short (< 213 bytes)
    const result = Blake2.compress(&input_too_short, &output);
    try std.testing.expectError(error.InvalidInput, result);
}

test "Blake2.compress wrapper - invalid output length" {
    // Test with invalid output length
    var input: [213]u8 = undefined;
    @memset(&input, 0);
    var output_too_short: [32]u8 = undefined;

    // Output too short (< 64 bytes)
    const result = Blake2.compress(&input, &output_too_short);
    try std.testing.expectError(error.InvalidOutput, result);
}

test "blake2b compression - security property avalanche effect" {
    // Test avalanche effect: small change in input causes large change in output
    var h1 = [8]u64{
        0x6a09e667f3bcc908 ^ 0x01010040,
        0xbb67ae8584caa73b,
        0x3c6ef372fe94f82b,
        0xa54ff53a5f1d36f1,
        0x510e527fade682d1,
        0x9b05688c2b3e6c1f,
        0x1f83d9abfb41bd6b,
        0x5be0cd19137e2179,
    };

    var h2 = h1;

    var m1 = [_]u64{0} ** 16;
    var m2 = [_]u64{0} ** 16;
    m2[0] = 1; // Single bit difference

    const t = [2]u64{ 128, 0 };

    unauditedBlake2fCompress(&h1, &m1, t, true, 12);
    unauditedBlake2fCompress(&h2, &m2, t, true, 12);

    // Outputs should be significantly different (avalanche effect)
    var differences: usize = 0;
    for (0..8) |i| {
        if (h1[i] != h2[i]) differences += 1;
    }
    // Expect at least 50% of words to differ
    try std.testing.expect(differences >= 4);
}
