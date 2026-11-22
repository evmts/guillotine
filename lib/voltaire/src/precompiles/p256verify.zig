//! P256VERIFY precompile (0x100): ECDSA verification over secp256r1 / NIST P-256.
//!
//! Specifications:
//! - EIP-7951 (Ethereum mainnet, Osaka): gas 6900.
//!   https://github.com/ethereum/EIPs/blob/master/EIPS/eip-7951.md
//! - RIP-7212 (OP Stack Fjord through Jovian, Base Fjord through Jovian): gas 3450.
//!   https://github.com/ethereum/RIPs/blob/master/RIPS/rip-7212.md
//!
//! Both specifications share one verification function; only the gas cost differs,
//! so `execute` takes the gas cost as a parameter.
//!
//! Input (exactly 160 bytes): h (32) || r (32) || s (32) || qx (32) || qy (32).
//! Output: 32 bytes `0x00..01` for a valid signature, 0 bytes otherwise.
//! The call fails only with `error.OutOfGas`; every invalid input returns empty output
//! and consumes the full gas cost.
//!
//! Validation (EIP-7951 "Input Validation"):
//! 1. input length is 160
//! 2. 0 < r < n and 0 < s < n
//! 3. qx < p and qy < p
//! 4. (qx, qy) satisfies the curve equation
//! 5. (qx, qy) is not (0, 0)
//! Then R' = (h * s^-1) * G + (r * s^-1) * Q; fail if R' is infinity; succeed iff R'.x mod n == r.
//!
//! Malleability: neither EIP-7951 nor RIP-7212 requires low-s. Both (r, s) and (r, n - s)
//! verify. `h` is not reduced or range-checked before use; h >= n and h == 0 are legal.
//!
//! Implementation note: `std.crypto.sign.ecdsa` is not used because it rejects h == 0
//! (`error.SignatureVerificationFailed`), which EIP-7951 accepts.

const std = @import("std");
const primitives = @import("voltaire");
const Address = primitives.Address;
const common = @import("common.zig");
const PrecompileError = common.PrecompileError;
const PrecompileResult = common.PrecompileResult;

const P256 = std.crypto.ecc.P256;
const Scalar = P256.scalar.Scalar;

/// Precompile address 0x0000000000000000000000000000000000000100.
pub const P256VERIFY_ADDRESS: Address = Address.fromU256(0x100);

/// EIP-7951 gas cost (Ethereum Osaka and later).
pub const GAS_COST_EIP7951: u64 = 6900;

/// RIP-7212 gas cost (OP Stack and Base, Fjord through Jovian).
pub const GAS_COST_RIP7212: u64 = 3450;

/// Exact input length in bytes.
pub const INPUT_LENGTH: usize = 160;

/// Execute P256VERIFY with the given gas cost.
///
/// Returns `error.OutOfGas` when `gas_limit < gas_cost`. Otherwise returns `gas_cost` as gas used
/// and a 32-byte `0x00..01` output for a valid signature or a 0-byte output for anything else.
/// The caller owns `output` and frees it with `PrecompileResult.deinit`.
pub fn execute(
    allocator: std.mem.Allocator,
    input: []const u8,
    gas_limit: u64,
    gas_cost: u64,
) PrecompileError!PrecompileResult {
    if (gas_limit < gas_cost) return error.OutOfGas;

    const valid = input.len == INPUT_LENGTH and verify(
        input[0..32],
        input[32..64],
        input[64..96],
        input[96..128],
        input[128..160],
    );

    if (!valid) {
        const empty = try allocator.alloc(u8, 0);
        return PrecompileResult{ .output = empty, .gas_used = gas_cost };
    }

    const output = try allocator.alloc(u8, 32);
    @memset(output, 0);
    output[31] = 1;
    return PrecompileResult{ .output = output, .gas_used = gas_cost };
}

/// Verify a secp256r1 ECDSA signature over a 32-byte message hash.
///
/// All values are 32-byte big-endian integers. Returns false for any invalid encoding,
/// out-of-range value, off-curve or infinity public key, or failed signature equation.
pub fn verify(
    hash: *const [32]u8,
    r: *const [32]u8,
    s: *const [32]u8,
    x: *const [32]u8,
    y: *const [32]u8,
) bool {
    // 0 < r < n and 0 < s < n. fromBytes rejects values >= n (NonCanonical).
    const r_scalar = Scalar.fromBytes(r.*, .big) catch return false;
    const s_scalar = Scalar.fromBytes(s.*, .big) catch return false;
    if (r_scalar.isZero() or s_scalar.isZero()) return false;

    // (0, 0) encodes infinity. P256.fromAffineCoordinates maps it to the identity
    // instead of rejecting it, so reject it explicitly first.
    const zero = [_]u8{0} ** 32;
    if (std.mem.eql(u8, x, &zero) and std.mem.eql(u8, y, &zero)) return false;

    // qx < p, qy < p (NonCanonical) and curve equation (InvalidEncoding).
    const q = P256.fromSerializedAffineCoordinates(x.*, y.*, .big) catch return false;
    q.rejectIdentity() catch return false;

    // u1 = h * s^-1 mod n, u2 = r * s^-1 mod n. h is any 256-bit integer; reduce mod n.
    var h_wide = [_]u8{0} ** 48;
    @memcpy(h_wide[16..], hash);
    const h_scalar = Scalar.fromBytes48(h_wide, .big);
    const s_inv = s_scalar.invert();
    const scalar1 = h_scalar.mul(s_inv).toBytes(.big);
    const scalar2 = r_scalar.mul(s_inv).toBytes(.big);

    // R' = u1*G + u2*Q. mulDoubleBasePublic returns IdentityElement when R' is infinity.
    const point = P256.mulDoubleBasePublic(P256.basePoint, scalar1, q, scalar2, .big) catch return false;

    // R'.x is in [0, p); reduce mod n and compare with r.
    const rx = point.affineCoordinates().x.toBytes(.big);
    var rx_wide = [_]u8{0} ** 48;
    @memcpy(rx_wide[16..], &rx);
    const rx_scalar = Scalar.fromBytes48(rx_wide, .big);
    return rx_scalar.equivalent(r_scalar);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

fn hexToBytes(comptime hex: []const u8) [hex.len / 2]u8 {
    var out: [hex.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, hex) catch unreachable;
    return out;
}

// Vectors below are copied verbatim from go-ethereum
// core/vm/testdata/precompiles/p256Verify.json (master, fetched 2026-11-22), which
// carries the RIP-7212 reference vector and Wycheproof ecdsa_secp256r1_sha256_p1363 cases.

// "CallP256Verify": the RIP-7212 reference vector. Expected: valid.
const rip7212_reference = hexToBytes(
    "4cee90eb86eaa050036147a12d49004b6b9c72bd725d39d4785011fe190f0b4d" ++
        "a73bd4903f0ce3b639bbbf6e8e80d16931ff4bcf5993d58468e8fb19086e8cac" ++
        "36dbcd03009df8c59286b162af3bd7fcc0450c9aa81be5d10d312af6c66b1d60" ++
        "4aebd3099c618202fcfe16ae7770b0c49ab5eadf74b754204a3bb6060e44eff3" ++
        "7618b065f9832de4ca6ca971a7a1adc826d0f7c00181a5fb2ddf79ae00b4e10e",
);

// Wycheproof #1 "signature malleability": high-s signature. Expected: valid.
const wycheproof_1_malleability = hexToBytes(
    "bb5a52f42f9c9261ed4361f59422a1e30036e7c32b270c8807a419feca605023" ++
        "2ba3a8be6b94d5ec80a6d9d1190a436effe50d85a1eee859b8cc6af9bd5c2e18" ++
        "4cd60b855d442f5b3c7b11eb6c4e0ae7525fe710fab9aa7c77a67f79e6fadd76" ++
        "2927b10512bae3eddcfe467828128bad2903269919f7086069c8c4df6c732838" ++
        "c7787964eaac00e5921fb1498a60f4606766b3d9685001558d1a974e7341513e",
);

test "P256VERIFY constants" {
    try testing.expectEqual(@as(u256, 0x100), P256VERIFY_ADDRESS.toU256());
    try testing.expectEqual(@as(u64, 6900), GAS_COST_EIP7951);
    try testing.expectEqual(@as(u64, 3450), GAS_COST_RIP7212);
    try testing.expectEqual(@as(usize, 160), INPUT_LENGTH);
}

test "P256VERIFY RIP-7212 reference vector verifies" {
    const result = try execute(testing.allocator, &rip7212_reference, 10_000, GAS_COST_EIP7951);
    defer result.deinit(testing.allocator);
    try testing.expectEqual(GAS_COST_EIP7951, result.gas_used);
    try testing.expectEqual(@as(usize, 32), result.output.len);
    try testing.expectEqualSlices(u8, &([_]u8{0} ** 31 ++ [_]u8{1}), result.output);
}

test "P256VERIFY RIP-7212 gas cost is parameterized" {
    const result = try execute(testing.allocator, &rip7212_reference, GAS_COST_RIP7212, GAS_COST_RIP7212);
    defer result.deinit(testing.allocator);
    try testing.expectEqual(GAS_COST_RIP7212, result.gas_used);
    try testing.expectEqual(@as(usize, 32), result.output.len);
}

test "P256VERIFY accepts high-s (malleable) signature" {
    const result = try execute(testing.allocator, &wycheproof_1_malleability, 10_000, GAS_COST_EIP7951);
    defer result.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 32), result.output.len);
}

test "P256VERIFY accepts both s and n - s" {
    // Flip s of the reference vector to n - s; both must verify.
    const n: u256 = 0xffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551;
    var input = rip7212_reference;
    const s = std.mem.readInt(u256, input[64..96], .big);
    std.mem.writeInt(u256, input[64..96], n - s, .big);
    try testing.expect(verify(input[0..32], input[32..64], input[64..96], input[96..128], input[128..160]));
}

test "P256VERIFY out of gas" {
    try testing.expectError(error.OutOfGas, execute(testing.allocator, &rip7212_reference, GAS_COST_EIP7951 - 1, GAS_COST_EIP7951));
    try testing.expectError(error.OutOfGas, execute(testing.allocator, &rip7212_reference, GAS_COST_RIP7212 - 1, GAS_COST_RIP7212));
    try testing.expectError(error.OutOfGas, execute(testing.allocator, &[_]u8{}, 0, GAS_COST_EIP7951));
}

test "P256VERIFY wrong input length returns empty output and charges gas" {
    const lengths = [_]usize{ 0, 1, 159, 161, 192 };
    for (lengths) |len| {
        var buf: [192]u8 = undefined;
        @memset(&buf, 0);
        const copy_len = @min(len, rip7212_reference.len);
        @memcpy(buf[0..copy_len], rip7212_reference[0..copy_len]);
        const result = try execute(testing.allocator, buf[0..len], 10_000, GAS_COST_EIP7951);
        defer result.deinit(testing.allocator);
        try testing.expectEqual(GAS_COST_EIP7951, result.gas_used);
        try testing.expectEqual(@as(usize, 0), result.output.len);
    }
}

test "P256VERIFY rejects r = 0, s = 0, r = n, s = n, r > n" {
    const n_bytes = hexToBytes("ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551");
    const zero = [_]u8{0} ** 32;
    const max = [_]u8{0xff} ** 32;
    const cases = [_]struct { offset: usize, value: [32]u8 }{
        .{ .offset = 32, .value = zero },
        .{ .offset = 64, .value = zero },
        .{ .offset = 32, .value = n_bytes },
        .{ .offset = 64, .value = n_bytes },
        .{ .offset = 32, .value = max },
        .{ .offset = 64, .value = max },
    };
    for (cases) |c| {
        var input = rip7212_reference;
        @memcpy(input[c.offset .. c.offset + 32], &c.value);
        const result = try execute(testing.allocator, &input, 10_000, GAS_COST_EIP7951);
        defer result.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 0), result.output.len);
        try testing.expectEqual(GAS_COST_EIP7951, result.gas_used);
    }
}

test "P256VERIFY rejects point at infinity (0, 0)" {
    var input = rip7212_reference;
    @memset(input[96..160], 0);
    try testing.expect(!verify(input[0..32], input[32..64], input[64..96], input[96..128], input[128..160]));
}

test "P256VERIFY rejects point not on curve" {
    var input = rip7212_reference;
    input[159] ^= 1;
    try testing.expect(!verify(input[0..32], input[32..64], input[64..96], input[96..128], input[128..160]));
}

test "P256VERIFY rejects coordinates >= p" {
    const p_bytes = hexToBytes("ffffffff00000001000000000000000000000000ffffffffffffffffffffffff");
    var input_x = rip7212_reference;
    @memcpy(input_x[96..128], &p_bytes);
    try testing.expect(!verify(input_x[0..32], input_x[32..64], input_x[64..96], input_x[96..128], input_x[128..160]));

    // qx + p is the same field element as qx but non-canonical; must fail.
    const p: u256 = 0xffffffff00000001000000000000000000000000ffffffffffffffffffffffff;
    var input_y = rip7212_reference;
    const qy = std.mem.readInt(u256, input_y[128..160], .big);
    const sum = @addWithOverflow(qy, p);
    if (sum[1] == 0) {
        std.mem.writeInt(u256, input_y[128..160], sum[0], .big);
        try testing.expect(!verify(input_y[0..32], input_y[32..64], input_y[64..96], input_y[96..128], input_y[128..160]));
    }
}

test "P256VERIFY rejects modified hash, r, and s" {
    const offsets = [_]usize{ 0, 32, 64 };
    for (offsets) |offset| {
        var input = rip7212_reference;
        input[offset + 31] ^= 0x01;
        const result = try execute(testing.allocator, &input, 10_000, GAS_COST_EIP7951);
        defer result.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 0), result.output.len);
    }
}

test "P256VERIFY accepts zero hash (std.crypto.ecdsa would reject it)" {
    // Sign h = 0 with a deterministic key: k = 1 gives R = G, r = Gx mod n.
    // s = k^-1 * (h + r*d) = r*d mod n. Pick d = 1, so Q = G and s = r.
    const gx = hexToBytes("6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296");
    const gy = hexToBytes("4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5");
    const h = [_]u8{0} ** 32;
    try testing.expect(verify(&h, &gx, &gx, &gx, &gy));

    // Same signature with h = n (≡ 0 mod n) must also verify: h is reduced, not bounded.
    const n_bytes = hexToBytes("ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551");
    try testing.expect(verify(&n_bytes, &gx, &gx, &gx, &gy));
}

test "P256VERIFY rejects signature whose R' is infinity" {
    // Q = G, r = s = 1, h = n - 1: u1 = -1, u2 = 1, R' = -G + G = infinity.
    const gx = hexToBytes("6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296");
    const gy = hexToBytes("4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5");
    const h = hexToBytes("ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632550");
    var one = [_]u8{0} ** 32;
    one[31] = 1;
    try testing.expect(!verify(&h, &one, &one, &gx, &gy));
}

test "P256VERIFY round trip with std.crypto ECDSA signer" {
    const Ecdsa = std.crypto.sign.ecdsa.EcdsaP256Sha256;
    const seed = [_]u8{0x42} ** Ecdsa.KeyPair.seed_length;
    const key_pair = try Ecdsa.KeyPair.generateDeterministic(seed);
    const msg = "guillotine p256verify";
    var h: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(msg, &h, .{});
    const sig = try key_pair.sign(msg, null);
    const pk = key_pair.public_key.toUncompressedSec1();

    var input: [160]u8 = undefined;
    @memcpy(input[0..32], &h);
    @memcpy(input[32..64], &sig.r);
    @memcpy(input[64..96], &sig.s);
    @memcpy(input[96..160], pk[1..65]);

    const result = try execute(testing.allocator, &input, GAS_COST_EIP7951, GAS_COST_EIP7951);
    defer result.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 32), result.output.len);
    try testing.expectEqual(@as(u8, 1), result.output[31]);
}
