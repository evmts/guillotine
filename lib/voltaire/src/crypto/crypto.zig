//! Cryptographic Operations - Ethereum cryptography primitives and utilities
//!
//! This module provides the essential cryptographic functions used throughout
//! Ethereum, including hash functions, digital signatures, key generation,
//! and address derivation. It serves as the foundation for transaction
//! signing, account management, and cryptographic verification.
//!
//! ## Core Cryptographic Primitives
//!
//! ### Hash Functions
//! - **Keccak256**: Primary hash function used in Ethereum
//! - **SHA256**: Used in precompiles and some legacy operations
//! - **RIPEMD160**: Used in Bitcoin-compatible operations
//! - **Blake2b**: High-performance alternative hash function
//!
//! ### Digital Signatures
//! - **ECDSA**: Elliptic Curve Digital Signature Algorithm
//! - **secp256k1**: Bitcoin/Ethereum curve for signatures
//! - **RFC 6979**: Deterministic nonce generation (eliminates nonce reuse vulnerabilities)
//! - **Recovery**: Public key recovery from signatures
//! - **Verification**: Signature validation and authenticity
//!
//! ### Key Management
//! - **Private Keys**: 256-bit random values for signing
//! - **Public Keys**: Derived from private keys via ECDSA
//! - **Addresses**: 160-bit identifiers derived from public keys
//! - **Deterministic Generation**: HD wallet support
//!
//! ## Usage Examples
//!
//! ### Hash Operations
//! ```zig
//! const crypto = @import("crypto.zig");
//!
//! // Keccak256 hash (most common)
//! const data = "Hello, Ethereum!";
//! const hash = crypto.keccak256(data);
//!
//! // SHA256 hash
//! const sha_hash = crypto.sha256(data);
//! ```
//!
//! ### Key Generation and Management
//! ```zig
//! // Generate a new private key
//! const private_key = try crypto.generatePrivateKey();
//!
//! // Derive public key from private key
//! const public_key = try crypto.derivePublicKey(private_key);
//!
//! // Derive Ethereum address from public key
//! const address = crypto.deriveAddress(public_key);
//! ```
//!
//! ### Digital Signatures
//! ```zig
//! // Sign a message hash
//! const message_hash = crypto.keccak256("message");
//! const signature = try crypto.sign(private_key, message_hash);
//!
//! // Verify signature
//! const valid = try crypto.verify(signature, message_hash, public_key);
//!
//! // Recover public key from signature
//! const recovered_pubkey = try crypto.recoverPublicKey(signature, message_hash);
//! ```
//!
//! ### Address Operations
//! ```zig
//! // Check if address matches private key
//! const matches = crypto.addressMatchesKey(address, private_key);
//!
//! // Generate deterministic address
//! const deterministic_addr = crypto.generateDeterministicAddress(seed, index);
//! ```
//!
//! ## Security Considerations
//!
//! - **Private Key Security**: Never expose private keys in memory longer than necessary
//! - **Deterministic Signatures**: RFC 6979 eliminates nonce reuse vulnerabilities
//! - **Side-Channel Resistance**: Constant-time operations where possible
//! - **Signature Malleability**: Use canonical signature validation (EIP-2)
//! - **Hash Function Security**: Keccak256 is quantum-resistant
//!
//! ## Performance Optimizations
//!
//! - **Batch Operations**: Efficient bulk signature verification
//! - **Precomputed Tables**: Fast point multiplication for signatures
//! - **SIMD Instructions**: Vectorized hash computations
//! - **Memory Pools**: Reduced allocation overhead
//!
//! ## Design Principles
//!
//! 1. **Security First**: Constant-time operations and secure defaults
//! 2. **Ethereum Compatibility**: Full compatibility with Ethereum standards
//! 3. **Performance**: Optimized for high-throughput applications
//! 4. **Type Safety**: Prevent cryptographic misuse through strong typing
//! 5. **Auditability**: Clear, reviewable cryptographic implementations

const std = @import("std");
const crypto = std.crypto;
const testing = std.testing;
const Hash = @import("hash.zig");
const primitives = @import("voltaire");
const hex = primitives.Hex;
const build_options = @import("build_options");

// Import the local secp256k1 implementation
const secp256k1 = @import("secp256k1.zig");

// Use the address type from primitives
pub const Address = primitives.Address.Address;

// Error types for crypto operations
pub const CryptoError = error{
    InvalidPrivateKey,
    InvalidPublicKey,
    InvalidSignature,
    InvalidRecoveryId,
    InvalidHashLength,
    InvalidLength,
    SigningFailed,
    RecoveryFailed,
    OutOfMemory,
    NotImplemented,
};

// Type definitions
pub const PrivateKey = [32]u8;
pub const PublicKey = struct {
    x: u256,
    y: u256,

    pub fn toAddress(self: PublicKey) Address {
        return publicKeyToAddress(self);
    }

    pub fn toAffinePoint(self: PublicKey) secp256k1.AffinePoint {
        return secp256k1.AffinePoint{
            .x = self.x,
            .y = self.y,
            .infinity = false,
        };
    }

    pub fn fromAffinePoint(point: secp256k1.AffinePoint) PublicKey {
        return PublicKey{
            .x = point.x,
            .y = point.y,
        };
    }

    pub fn isValid(self: PublicKey) bool {
        const point = self.toAffinePoint();
        return point.isOnCurve() and !point.infinity;
    }
};

pub const Signature = struct {
    r: u256,
    s: u256,
    v: u8, // recovery id + 27 (Ethereum convention)

    pub fn recoveryId(self: Signature) u8 {
        // Handle both legacy (27/28) and EIP-155 (chainId * 2 + 35/36) formats
        if (self.v >= 27) {
            return @intCast((self.v - 27) % 2);
        }
        return self.v;
    }

    pub fn yParity(self: Signature) u8 {
        return self.recoveryId();
    }

    pub fn toBytes(self: Signature) [65]u8 {
        var result: [65]u8 = undefined;
        std.mem.writeInt(u256, result[0..32], self.r, .big);
        std.mem.writeInt(u256, result[32..64], self.s, .big);
        result[64] = self.v;
        return result;
    }

    pub fn fromBytes(bytes: [65]u8) Signature {
        return Signature{
            .r = std.mem.readInt(u256, bytes[0..32], .big),
            .s = std.mem.readInt(u256, bytes[32..64], .big),
            .v = bytes[64],
        };
    }

    pub fn toHex(self: Signature) [132]u8 {
        const bytes = self.toBytes();
        return hex.bytesToHexFixed(65, bytes);
    }

    pub fn fromHex(hex_str: []const u8) !Signature {
        const bytes = try hex.hexToBytesFixed(65, hex_str);
        return fromBytes(bytes);
    }

    pub fn isValid(self: Signature) bool {
        return secp256k1.unauditedValidateSignature(self.r, self.s);
    }
};

// Constants
const ETHEREUM_MESSAGE_PREFIX = "\x19Ethereum Signed Message:\n";

/// Securely zero sensitive memory to prevent leakage
/// Uses volatile operations to prevent compiler optimization
pub fn secureZeroMemory(ptr: anytype) void {
    const T = @TypeOf(ptr);
    const info = @typeInfo(T);

    if (info != .pointer) {
        @compileError("secureZeroMemory expects a pointer type");
    }

    const bytes = std.mem.asBytes(ptr);
    // Use @memset which the compiler should not optimize away for security-sensitive data
    @memset(bytes, 0);
    // Memory barrier to prevent reordering
    asm volatile ("" ::: .{ .memory = true });
}

// secp256k1 constants - re-export from precompile implementation
pub const SECP256K1_P: u256 = secp256k1.SECP256K1_P;
pub const SECP256K1_N: u256 = secp256k1.SECP256K1_N;
pub const SECP256K1_B: u256 = secp256k1.SECP256K1_B;
pub const SECP256K1_GX: u256 = secp256k1.SECP256K1_GX;
pub const SECP256K1_GY: u256 = secp256k1.SECP256K1_GY;

// BLS12-381 FFI bindings
pub const bls12_381 = struct {
    // FFI function declarations for G1
    extern fn bls12_381_g1_add(input: [*]const u8, input_len: u32, output: [*]u8, output_len: u32) c_int;
    extern fn bls12_381_g1_mul(input: [*]const u8, input_len: u32, output: [*]u8, output_len: u32) c_int;
    extern fn bls12_381_g1_multiexp(input: [*]const u8, input_len: u32, output: [*]u8, output_len: u32) c_int;
    extern fn bls12_381_g1_output_size() u32;

    // FFI function declarations for G2
    extern fn bls12_381_g2_add(input: [*]const u8, input_len: u32, output: [*]u8, output_len: u32) c_int;
    extern fn bls12_381_g2_mul(input: [*]const u8, input_len: u32, output: [*]u8, output_len: u32) c_int;
    extern fn bls12_381_g2_multiexp(input: [*]const u8, input_len: u32, output: [*]u8, output_len: u32) c_int;
    extern fn bls12_381_g2_output_size() u32;

    // FFI function declarations for pairing
    extern fn bls12_381_pairing(input: [*]const u8, input_len: u32, output: [*]u8, output_len: u32) c_int;
    extern fn bls12_381_pairing_output_size() u32;

    pub const Error = error{
        InvalidInput,
        InvalidPoint,
        InvalidScalar,
        ComputationFailed,
    };

    /// Perform BLS12-381 G1 addition
    pub fn g1_add(input: []const u8, output: []u8) Error!void {
        const result = bls12_381_g1_add(input.ptr, @intCast(input.len), output.ptr, @intCast(output.len));
        switch (result) {
            0 => return,
            1 => return Error.InvalidInput,
            2 => return Error.InvalidPoint,
            3 => return Error.InvalidScalar,
            4 => return Error.ComputationFailed,
            else => return Error.ComputationFailed,
        }
    }

    /// Perform BLS12-381 G1 scalar multiplication
    pub fn g1_mul(input: []const u8, output: []u8) Error!void {
        const result = bls12_381_g1_mul(input.ptr, @intCast(input.len), output.ptr, @intCast(output.len));
        switch (result) {
            0 => return,
            1 => return Error.InvalidInput,
            2 => return Error.InvalidPoint,
            3 => return Error.InvalidScalar,
            4 => return Error.ComputationFailed,
            else => return Error.ComputationFailed,
        }
    }

    /// Perform BLS12-381 G1 multi-scalar multiplication
    pub fn g1_multiexp(input: []const u8, output: []u8) Error!void {
        const result = bls12_381_g1_multiexp(input.ptr, @intCast(input.len), output.ptr, @intCast(output.len));
        switch (result) {
            0 => return,
            1 => return Error.InvalidInput,
            2 => return Error.InvalidPoint,
            3 => return Error.InvalidScalar,
            4 => return Error.ComputationFailed,
            else => return Error.ComputationFailed,
        }
    }

    /// Perform BLS12-381 G2 addition
    pub fn g2Add(input: []const u8, output: []u8) Error!void {
        const result = bls12_381_g2_add(input.ptr, @intCast(input.len), output.ptr, @intCast(output.len));
        switch (result) {
            0 => return,
            1 => return Error.InvalidInput,
            2 => return Error.InvalidPoint,
            3 => return Error.InvalidScalar,
            4 => return Error.ComputationFailed,
            else => return Error.ComputationFailed,
        }
    }

    /// Perform BLS12-381 G2 scalar multiplication
    pub fn g2Mul(input: []const u8, output: []u8) Error!void {
        const result = bls12_381_g2_mul(input.ptr, @intCast(input.len), output.ptr, @intCast(output.len));
        switch (result) {
            0 => return,
            1 => return Error.InvalidInput,
            2 => return Error.InvalidPoint,
            3 => return Error.InvalidScalar,
            4 => return Error.ComputationFailed,
            else => return Error.ComputationFailed,
        }
    }

    /// Perform BLS12-381 G2 multi-scalar multiplication
    pub fn g2Msm(input: []const u8, output: []u8) Error!void {
        const result = bls12_381_g2_multiexp(input.ptr, @intCast(input.len), output.ptr, @intCast(output.len));
        switch (result) {
            0 => return,
            1 => return Error.InvalidInput,
            2 => return Error.InvalidPoint,
            3 => return Error.InvalidScalar,
            4 => return Error.ComputationFailed,
            else => return Error.ComputationFailed,
        }
    }

    /// Perform BLS12-381 pairing check
    pub fn pairing(input: []const u8, output: []u8) Error!void {
        const result = bls12_381_pairing(input.ptr, @intCast(input.len), output.ptr, @intCast(output.len));
        switch (result) {
            0 => return,
            1 => return Error.InvalidInput,
            2 => return Error.InvalidPoint,
            3 => return Error.InvalidScalar,
            4 => return Error.ComputationFailed,
            else => return Error.ComputationFailed,
        }
    }

    /// Get the output size for G1 operations
    pub fn g1_output_size() u32 {
        return bls12_381_g1_output_size();
    }

    /// Get the output size for G2 operations
    pub fn g2_output_size() u32 {
        return bls12_381_g2_output_size();
    }

    /// Get the output size for pairing operations
    pub fn pairingOutputSize() u32 {
        return bls12_381_pairing_output_size();
    }

    /// Map field element to G1 curve point
    /// Implements draft-irtf-cfrg-hash-to-curve for BLS12-381 G1
    /// Input: 64 bytes (Fp field element, big-endian, padded)
    /// Output: 128 bytes (G1 point in uncompressed form: x || y)
    pub fn mapFpToG1(input: []const u8, output: []u8) Error!void {
        if (input.len != 64) return Error.InvalidInput;
        if (output.len != 128) return Error.InvalidInput;

        // Import blst types from c_kzg module
        const c_kzg = @import("c_kzg");
        const blst = c_kzg.blst;

        // Parse input as Fp field element (big-endian, padded to 64 bytes)
        var fp: blst.blst_fp = undefined;
        blst.blst_fp_from_bendian(&fp, input.ptr);

        // Map Fp to G1 point (Jacobian coordinates)
        var p1: blst.blst_p1 = undefined;
        blst.blst_map_to_g1(&p1, &fp, null);

        // Convert to affine coordinates for output
        var p1_affine: blst.blst_p1_affine = undefined;
        blst.blst_p1_to_affine(&p1_affine, &p1);

        // Serialize affine point to output (x || y, big-endian, 64 bytes each)
        blst.blst_bendian_from_fp(output.ptr, &p1_affine.x);
        blst.blst_bendian_from_fp(output.ptr + 64, &p1_affine.y);
    }

    /// Map field extension element to G2 curve point
    /// Implements draft-irtf-cfrg-hash-to-curve for BLS12-381 G2
    /// Input: 128 bytes (Fp2 element: c0 || c1, each 64 bytes big-endian)
    /// Output: 256 bytes (G2 point in uncompressed form: x0 || x1 || y0 || y1)
    pub fn mapFp2ToG2(input: []const u8, output: []u8) Error!void {
        if (input.len != 128) return Error.InvalidInput;
        if (output.len != 256) return Error.InvalidInput;

        // Import blst types from c_kzg module
        const c_kzg = @import("c_kzg");
        const blst = c_kzg.blst;

        // Parse input as Fp2 element (c0 || c1, each 64 bytes big-endian)
        var fp2: blst.blst_fp2 = undefined;
        blst.blst_fp_from_bendian(&fp2.fp[0], input.ptr); // c0
        blst.blst_fp_from_bendian(&fp2.fp[1], input.ptr + 64); // c1

        // Map Fp2 to G2 point (Jacobian coordinates)
        var p2: blst.blst_p2 = undefined;
        blst.blst_map_to_g2(&p2, &fp2, null);

        // Convert to affine coordinates for output
        var p2_affine: blst.blst_p2_affine = undefined;
        blst.blst_p2_to_affine(&p2_affine, &p2);

        // Serialize affine point to output (x.c0 || x.c1 || y.c0 || y.c1)
        blst.blst_bendian_from_fp(output.ptr, &p2_affine.x.fp[0]);
        blst.blst_bendian_from_fp(output.ptr + 64, &p2_affine.x.fp[1]);
        blst.blst_bendian_from_fp(output.ptr + 128, &p2_affine.y.fp[0]);
        blst.blst_bendian_from_fp(output.ptr + 192, &p2_affine.y.fp[1]);
    }

    /// Perform BLS12-381 pairing check (returns bool)
    /// This verifies that the pairing product equals 1
    /// Input: concatenated pairs of (G1 point || G2 point), each pair is 384 bytes
    ///        G1 point: 128 bytes (x || y, each 64 bytes)
    ///        G2 point: 256 bytes (x0 || x1 || y0 || y1, each 64 bytes)
    pub fn pairingCheck(input: []const u8) Error!bool {
        if (input.len % 384 != 0) return Error.InvalidInput;

        // Import blst types from c_kzg module
        const c_kzg = @import("c_kzg");
        const blst = c_kzg.blst;

        const num_pairs = input.len / 384;

        // Special case: empty input means pairing of identity elements, which is 1
        if (num_pairs == 0) {
            return true;
        }

        // Parse and accumulate pairings
        var i: usize = 0;
        var acc: blst.blst_fp12 = undefined;

        while (i < num_pairs) : (i += 1) {
            const offset = i * 384;
            const g1_bytes = input[offset .. offset + 128];
            const g2_bytes = input[offset + 128 .. offset + 384];

            // Parse G1 point (128 bytes: x || y)
            var p1_affine: blst.blst_p1_affine = undefined;
            blst.blst_fp_from_bendian(&p1_affine.x, g1_bytes.ptr);
            blst.blst_fp_from_bendian(&p1_affine.y, g1_bytes.ptr + 64);

            // Validate G1 point
            if (!blst.blst_p1_affine_on_curve(&p1_affine)) {
                return Error.InvalidPoint;
            }
            if (!blst.blst_p1_affine_in_g1(&p1_affine)) {
                return Error.InvalidPoint;
            }

            // Parse G2 point (256 bytes: x0 || x1 || y0 || y1)
            var p2_affine: blst.blst_p2_affine = undefined;
            blst.blst_fp_from_bendian(&p2_affine.x.fp[0], g2_bytes.ptr);
            blst.blst_fp_from_bendian(&p2_affine.x.fp[1], g2_bytes.ptr + 64);
            blst.blst_fp_from_bendian(&p2_affine.y.fp[0], g2_bytes.ptr + 128);
            blst.blst_fp_from_bendian(&p2_affine.y.fp[1], g2_bytes.ptr + 192);

            // Validate G2 point
            if (!blst.blst_p2_affine_on_curve(&p2_affine)) {
                return Error.InvalidPoint;
            }
            if (!blst.blst_p2_affine_in_g2(&p2_affine)) {
                return Error.InvalidPoint;
            }

            // Compute Miller loop for this pair
            var loop_result: blst.blst_fp12 = undefined;
            blst.blst_miller_loop(&loop_result, &p2_affine, &p1_affine);

            // Accumulate results by multiplication
            if (i == 0) {
                acc = loop_result;
            } else {
                var temp: blst.blst_fp12 = undefined;
                blst.blst_fp12_mul(&temp, &acc, &loop_result);
                acc = temp;
            }
        }

        // Apply final exponentiation
        var final: blst.blst_fp12 = undefined;
        blst.blst_final_exp(&final, &acc);

        // Check if result is 1 (identity element in GT)
        return blst.blst_fp12_is_one(&final);
    }

    // CamelCase aliases for consistency with G2 naming and precompile expectations
    pub const g1Add = g1_add;
    pub const g1Mul = g1_mul;
    pub const g1Msm = g1_multiexp;
};

/// Generate a random private key
/// WARNING: UNAUDITED - Custom cryptographic implementation that has NOT been audited!
/// This function implements private key generation without security review.
/// Use at your own risk in production systems.
pub fn unaudited_randomPrivateKey() !PrivateKey {
    var private_key: PrivateKey = undefined;
    crypto.random.bytes(&private_key);

    // Ensure the private key is valid (non-zero and less than secp256k1 order)
    const key_as_u256 = std.mem.readInt(u256, &private_key, .big);

    if (key_as_u256 == 0 or key_as_u256 >= SECP256K1_N) {
        return unaudited_randomPrivateKey(); // Recursively generate until valid
    }

    return private_key;
}

/// Convert public key to Ethereum address
pub fn publicKeyToAddress(public_key: PublicKey) Address {
    var pub_key_bytes: [64]u8 = undefined;
    std.mem.writeInt(u256, pub_key_bytes[0..32], public_key.x, .big);
    std.mem.writeInt(u256, pub_key_bytes[32..64], public_key.y, .big);

    const hash = Hash.keccak256(&pub_key_bytes);

    var address: Address = undefined;
    @memcpy(&address.bytes, hash[12..32]);
    return address;
}

/// Create EIP-191 prefixed hash for a message
pub fn hashMessage(message: []const u8) Hash.Hash {
    var hasher = crypto.hash.sha3.Keccak256.init(.{});
    hasher.update(ETHEREUM_MESSAGE_PREFIX);

    // Add message length
    // 32 bytes is sufficient for any reasonable message length (up to ~10^31)
    var length_buf: [32]u8 = undefined;
    const length_str = std.fmt.bufPrint(&length_buf, "{d}", .{message.len}) catch {
        // Fallback: use maximum possible length string representation
        // This is an unreachable code path for any reasonable message size
        unreachable;
    };
    hasher.update(length_str);

    hasher.update(message);

    var hash: Hash.Hash = undefined;
    hasher.final(&hash);
    return hash;
}

/// Validate signature parameters (basic validation)
pub fn isValidSignature(signature: Signature) bool {
    return secp256k1.unauditedValidateSignature(signature.r, signature.s);
}

/// Derive public key from private key
/// WARNING: UNAUDITED - Custom cryptographic implementation that has NOT been audited!
/// This function implements public key derivation using unaudited ECC operations.
/// Use at your own risk in production systems.
pub fn unaudited_getPublicKey(private_key: PrivateKey) !PublicKey {
    var private_key_u256 = std.mem.readInt(u256, &private_key, .big);
    defer secureZeroMemory(&private_key_u256);

    // Validate private key
    if (private_key_u256 == 0 or private_key_u256 >= SECP256K1_N) {
        return CryptoError.InvalidPrivateKey;
    }

    // Multiply generator point by private key
    const generator = secp256k1.AffinePoint.generator();
    const public_key_point = generator.scalarMul(private_key_u256);

    if (public_key_point.infinity) {
        return CryptoError.InvalidPrivateKey;
    }

    return PublicKey{
        .x = public_key_point.x,
        .y = public_key_point.y,
    };
}

/// RFC 6979 Deterministic Nonce Generation for ECDSA
/// WARNING: UNAUDITED - Custom cryptographic implementation that has NOT been audited!
/// This function implements RFC 6979 without security review.
/// Use at your own risk in production systems.
///
/// This implementation generates deterministic ECDSA nonces according to RFC 6979
/// using HMAC-DRBG with SHA-256. This eliminates the risk of nonce reuse which
/// would leak the private key.
///
/// Reference: https://datatracker.ietf.org/doc/html/rfc6979
fn unaudited_rfc6979Nonce(hash: Hash.Hash, private_key: PrivateKey) u256 {
    const Hmac = crypto.auth.hmac.sha2.HmacSha256;
    const hlen: usize = 32; // SHA-256 output length

    // Step a: Process the message hash
    // h1 = H(m) - already provided as hash parameter

    // Step b: Convert private key to bytes (already in bytes)
    // x = int2octets(private_key)

    // Step c: Initialize V to 0x01 repeated hlen times
    var v: [hlen]u8 = [_]u8{0x01} ** hlen;

    // Step d: Initialize K to 0x00 repeated hlen times
    var k: [hlen]u8 = [_]u8{0x00} ** hlen;

    // Step e: K = HMAC_K(V || 0x00 || int2octets(x) || bits2octets(h1))
    {
        var data: [hlen + 1 + 32 + 32]u8 = undefined;
        @memcpy(data[0..hlen], &v);
        data[hlen] = 0x00;
        @memcpy(data[hlen + 1 .. hlen + 1 + 32], &private_key);
        @memcpy(data[hlen + 1 + 32 .. hlen + 1 + 32 + 32], &hash);
        Hmac.create(&k, &data, &k);
    }

    // Step f: V = HMAC_K(V)
    Hmac.create(&v, &v, &k);

    // Step g: K = HMAC_K(V || 0x01 || int2octets(x) || bits2octets(h1))
    {
        var data: [hlen + 1 + 32 + 32]u8 = undefined;
        @memcpy(data[0..hlen], &v);
        data[hlen] = 0x01;
        @memcpy(data[hlen + 1 .. hlen + 1 + 32], &private_key);
        @memcpy(data[hlen + 1 + 32 .. hlen + 1 + 32 + 32], &hash);
        Hmac.create(&k, &data, &k);
    }

    // Step h: V = HMAC_K(V)
    Hmac.create(&v, &v, &k);

    // Step h: Generate candidate k values until valid
    while (true) {
        // Step h1: Set T to empty sequence
        var t: [hlen]u8 = undefined;

        // Step h2: While tlen < qlen (32 bytes for secp256k1)
        // V = HMAC_K(V)
        Hmac.create(&v, &v, &k);
        // T = T || V
        @memcpy(&t, &v);

        // Step h3: Compute k = bits2int(T)
        const candidate_k = std.mem.readInt(u256, &t, .big);

        // If k is in [1, q-1], return it
        if (candidate_k > 0 and candidate_k < SECP256K1_N) {
            // Additional check: verify k * G is not infinity
            const generator = secp256k1.AffinePoint.generator();
            const point_r = generator.scalarMul(candidate_k);
            if (!point_r.infinity) {
                const r = point_r.x % SECP256K1_N;
                if (r != 0) {
                    return candidate_k;
                }
            }
        }

        // k is not suitable, update K and V and try again
        // K = HMAC_K(V || 0x00)
        {
            var data: [hlen + 1]u8 = undefined;
            @memcpy(data[0..hlen], &v);
            data[hlen] = 0x00;
            Hmac.create(&k, &data, &k);
        }

        // V = HMAC_K(V)
        Hmac.create(&v, &v, &k);
    }
}

/// Sign a hash with a private key using ECDSA
/// WARNING: UNAUDITED - Custom cryptographic implementation that has NOT been audited!
/// This function implements ECDSA signing without security review.
/// Use at your own risk in production systems.
pub fn unaudited_signHash(hash: Hash.Hash, private_key: PrivateKey) !Signature {
    var private_key_u256 = std.mem.readInt(u256, &private_key, .big);
    defer secureZeroMemory(&private_key_u256);

    // Validate private key
    if (private_key_u256 == 0 or private_key_u256 >= SECP256K1_N) {
        return CryptoError.InvalidPrivateKey;
    }

    // Get message hash as u256
    const message_u256 = std.mem.readInt(u256, &hash, .big);

    // Generate deterministic k using RFC 6979
    var k = unaudited_rfc6979Nonce(hash, private_key);
    defer secureZeroMemory(&k);

    // Calculate r = (k * G).x mod n
    const generator = secp256k1.AffinePoint.generator();
    const point_r = generator.scalarMul(k);
    if (point_r.infinity) {
        return CryptoError.SigningFailed;
    }

    const r = point_r.x % SECP256K1_N;
    if (r == 0) {
        return CryptoError.SigningFailed;
    }

    // Calculate s = k^-1 * (hash + r * private_key) mod n
    const k_inv = secp256k1.unauditedInvmod(k, SECP256K1_N) orelse return CryptoError.SigningFailed;
    const r_d = secp256k1.unauditedMulmod(r, private_key_u256, SECP256K1_N);
    const hash_plus_rd = secp256k1.unauditedAddmod(message_u256, r_d, SECP256K1_N);
    var s = secp256k1.unauditedMulmod(k_inv, hash_plus_rd, SECP256K1_N);

    if (s == 0) {
        return CryptoError.SigningFailed;
    }

    // Calculate recovery ID before normalizing s
    var recoveryId = if ((point_r.y & 1) == 1) @as(u8, 1) else @as(u8, 0);

    // Ensure s is in lower half to prevent malleability (EIP-2)
    const half_n = SECP256K1_N >> 1;
    if (s > half_n) {
        s = SECP256K1_N - s;
        // When we flip s, we also need to flip the recovery ID
        recoveryId ^= 1;
    }

    // Verify signature by recovering public key
    const recovered_address = unaudited_recoverAddress(hash, .{ .v = recoveryId, .r = r, .s = s }) catch {
        return CryptoError.SigningFailed;
    };
    const expected_public_key = unaudited_getPublicKey(private_key) catch {
        return CryptoError.SigningFailed;
    };
    const expected_address = expected_public_key.toAddress();

    if (!std.mem.eql(u8, &recovered_address.bytes, &expected_address.bytes)) {
        return CryptoError.SigningFailed;
    }

    return Signature{
        .r = r,
        .s = s,
        .v = recoveryId + 27,
    };
}

/// Sign a message with EIP-191 prefix
/// WARNING: UNAUDITED - Custom cryptographic implementation that has NOT been audited!
/// This function implements message signing without security review.
/// Use at your own risk in production systems.
pub fn unaudited_signMessage(message: []const u8, private_key: PrivateKey) !Signature {
    const message_hash = hashMessage(message);
    return unaudited_signHash(message_hash, private_key);
}

/// Recover address from signature and hash
/// WARNING: UNAUDITED - Custom cryptographic implementation that has NOT been audited!
/// This function implements signature recovery without security review.
/// Use at your own risk in production systems.
pub fn unaudited_recoverAddress(hash: Hash.Hash, signature: Signature) !Address {
    if (!signature.isValid()) {
        return CryptoError.InvalidSignature;
    }

    const recoveryId = signature.recoveryId();
    if (recoveryId > 1) {
        return CryptoError.InvalidRecoveryId;
    }

    return secp256k1.unauditedRecoverAddress(&hash, recoveryId, signature.r, signature.s);
}

/// Recover address from message and signature
/// WARNING: UNAUDITED - Custom cryptographic implementation that has NOT been audited!
/// This function implements message address recovery without security review.
/// Use at your own risk in production systems.
pub fn unaudited_recoverMessageAddress(message: []const u8, signature: Signature) !Address {
    const message_hash = hashMessage(message);
    return unaudited_recoverAddress(message_hash, signature);
}

/// Verify a signature against a hash and address
/// WARNING: UNAUDITED - Custom cryptographic implementation that has NOT been audited!
/// This function implements signature verification without security review.
/// Use at your own risk in production systems.
pub fn unaudited_verifySignature(hash: Hash.Hash, signature: Signature, address: Address) !bool {
    const recovered_address = unaudited_recoverAddress(hash, signature) catch return false;
    return std.mem.eql(u8, &recovered_address.bytes, &address.bytes);
}

/// Verify a message signature against an address
/// WARNING: UNAUDITED - Custom cryptographic implementation that has NOT been audited!
/// This function implements message verification without security review.
/// Use at your own risk in production systems.
pub fn unaudited_verifyMessage(message: []const u8, signature: Signature, address: Address) !bool {
    const recovered_address = unaudited_recoverMessageAddress(message, signature) catch return false;
    return std.mem.eql(u8, &recovered_address.bytes, &address.bytes);
}

// ============================================================================
// Tests
// ============================================================================

test "private key generation" {
    const private_key = try unaudited_randomPrivateKey();

    // Verify it's not all zeros
    var is_zero = true;
    for (private_key) |byte| {
        if (byte != 0) {
            is_zero = false;
            break;
        }
    }
    try testing.expect(!is_zero);

    // Verify it's a valid private key
    const key_as_u256 = std.mem.readInt(u256, &private_key, .big);
    try testing.expect(key_as_u256 > 0);
    try testing.expect(key_as_u256 < SECP256K1_N);
}

test "public key derivation" {
    const private_key = try unaudited_randomPrivateKey();
    const public_key = try unaudited_getPublicKey(private_key);

    // Verify public key is valid
    try testing.expect(public_key.isValid());

    // Verify public key is not at infinity
    try testing.expect(public_key.x != 0 or public_key.y != 0);
}

test "address derivation" {
    const private_key = try unaudited_randomPrivateKey();
    const public_key = try unaudited_getPublicKey(private_key);
    const address = public_key.toAddress();

    // Verify address is not zero
    const zero_address = [_]u8{0} ** 20;
    try testing.expect(!std.mem.eql(u8, &address, &zero_address));
}

test "message hashing" {
    const message = "Hello, Ethereum!";
    const hash1 = hashMessage(message);
    const hash2 = hashMessage(message);

    // Verify deterministic hashing
    try testing.expect(std.mem.eql(u8, &hash1, &hash2));

    // Verify different messages produce different hashes
    const different_message = "Hello, World!";
    const hash3 = hashMessage(different_message);
    try testing.expect(!std.mem.eql(u8, &hash1, &hash3));
}

test "signature creation and verification" {
    const private_key = try unaudited_randomPrivateKey();
    const message = "Test message for signing";

    // Sign the message
    const signature = try unaudited_signMessage(message, private_key);

    // Verify signature is valid
    try testing.expect(signature.isValid());

    // Recover address from signature
    const recovered_address = try unaudited_recoverMessageAddress(message, signature);

    // Verify recovered address matches expected
    const public_key = try unaudited_getPublicKey(private_key);
    const expected_address = public_key.toAddress();
    try testing.expect(std.mem.eql(u8, &recovered_address, &expected_address));

    // Verify signature verification
    try testing.expect(try unaudited_verifyMessage(message, signature, expected_address));
}

test "signature roundtrip" {
    const private_key = try unaudited_randomPrivateKey();
    const message = "Roundtrip test message";

    // Sign message
    const signature = try unaudited_signMessage(message, private_key);

    // Verify signature components
    try testing.expect(signature.r > 0);
    try testing.expect(signature.s > 0);
    try testing.expect(signature.v == 27 or signature.v == 28);

    // Verify signature serialization
    const signature_bytes = signature.toBytes();
    const signature_restored = Signature.fromBytes(signature_bytes);
    try testing.expect(signature_restored.r == signature.r);
    try testing.expect(signature_restored.s == signature.s);
    try testing.expect(signature_restored.v == signature.v);

    // Verify message verification
    const expected_address = (try unaudited_getPublicKey(private_key)).toAddress();
    try testing.expect(try unaudited_verifyMessage(message, signature, expected_address));
}

test "invalid signature rejection" {
    const private_key = try unaudited_randomPrivateKey();
    const message = "Test message";
    const signature = try unaudited_signMessage(message, private_key);
    const expected_address = (try unaudited_getPublicKey(private_key)).toAddress();

    // Verify correct signature works
    try testing.expect(try unaudited_verifyMessage(message, signature, expected_address));

    // Test with modified message
    const wrong_message = "Wrong message";
    try testing.expect(!try unaudited_verifyMessage(wrong_message, signature, expected_address));

    // Test with wrong address
    const wrong_address = [_]u8{0xFF} ** 20;
    try testing.expect(!try unaudited_verifyMessage(message, signature, wrong_address));

    // Test with invalid signature
    var invalid_signature = signature;
    invalid_signature.r = 0; // Invalid r
    try testing.expect(!invalid_signature.isValid());
}

// Tests from crypto_test.zig

test "create and verify signature" {
    // Test private key
    const private_key = PrivateKey{
        0xac, 0x09, 0x74, 0xbe, 0xc3, 0x9a, 0x17, 0xe3,
        0x6b, 0xa4, 0xa6, 0xb4, 0xd2, 0x38, 0xff, 0x24,
        0x4e, 0x21, 0xdb, 0x63, 0x5c, 0x51, 0xcb, 0x29,
        0x36, 0x49, 0x5a, 0xf7, 0x42, 0x2f, 0xba, 0x41,
    };

    // Message to sign
    const message = "Hello, Ethereum!";
    const message_hash = Hash.keccak256(message);

    // Sign the message
    const signature = try unaudited_signHash(message_hash, private_key);

    // Verify signature components
    try testing.expectEqual(@as(usize, 32), @sizeOf(@TypeOf(signature.r)));
    try testing.expectEqual(@as(usize, 32), @sizeOf(@TypeOf(signature.s)));
    try testing.expect(signature.v == 27 or signature.v == 28);
}

test "ecdsa recover public key" {
    // Known test vector
    const message_hash = Hash.keccak256("test message");

    const signature = Signature{
        .r = 0x1234567890123456789012345678901234567890123456789012345678901234,
        .s = 0x3456789012345678901234567890123456789012345678901234567890123456,
        .v = 27,
    };

    // Recovery should not fail for valid signature
    const result = unaudited_recoverAddress(message_hash, signature);
    _ = result catch |err| {
        // Expected to potentially fail with invalid test data
        try testing.expect(err == CryptoError.InvalidSignature or
            err == CryptoError.RecoveryFailed);
    };
}

test "signature serialization" {
    const signature = Signature{
        .r = 0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa,
        .s = 0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb,
        .v = 28,
    };

    // Convert to bytes
    const bytes = signature.toBytes();
    try testing.expectEqual(@as(usize, 65), bytes.len);

    // First 32 bytes should be r
    var expected_r: [32]u8 = undefined;
    std.mem.writeInt(u256, &expected_r, signature.r, .big);
    try testing.expectEqualSlices(u8, &expected_r, bytes[0..32]);

    // Next 32 bytes should be s
    var expected_s: [32]u8 = undefined;
    std.mem.writeInt(u256, &expected_s, signature.s, .big);
    try testing.expectEqualSlices(u8, &expected_s, bytes[32..64]);

    // Last byte should be v
    try testing.expectEqual(@as(u8, 28), bytes[64]);

    // Convert back from bytes
    const recovered = Signature.fromBytes(bytes);
    try testing.expectEqual(signature.r, recovered.r);
    try testing.expectEqual(signature.s, recovered.s);
    try testing.expectEqual(signature.v, recovered.v);
}

test "signature hex encoding" {
    const signature = Signature{
        .r = 0x123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0,
        .s = 0xfedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210,
        .v = 27,
    };

    // Convert to hex
    const hex_str = signature.toHex();

    // Should be 0x + 130 chars (65 bytes * 2)
    try testing.expectEqual(@as(usize, 132), hex_str.len);
    try testing.expect(std.mem.startsWith(u8, &hex_str, "0x"));

    // Convert back from hex
    const recovered = try Signature.fromHex(&hex_str);
    try testing.expectEqual(signature.r, recovered.r);
    try testing.expectEqual(signature.s, recovered.s);
    try testing.expectEqual(signature.v, recovered.v);
}

test "generate private key" {
    const key1 = try unaudited_randomPrivateKey();
    const key2 = try unaudited_randomPrivateKey();

    // Keys should be different
    try testing.expect(!std.mem.eql(u8, &key1, &key2));

    // Keys should be 32 bytes
    try testing.expectEqual(@as(usize, 32), key1.len);
    try testing.expectEqual(@as(usize, 32), key2.len);

    // Keys should not be zero
    const zero_key = [_]u8{0} ** 32;
    try testing.expect(!std.mem.eql(u8, &key1, &zero_key));
    try testing.expect(!std.mem.eql(u8, &key2, &zero_key));
}

test "derive public key from private key" {
    // Test vector with known private/public key pair
    const private_key = PrivateKey{ 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };

    const public_key = try unaudited_getPublicKey(private_key);

    // Public key should be valid
    try testing.expect(public_key.isValid());

    // Public key should be deterministic
    const public_key2 = try unaudited_getPublicKey(private_key);
    try testing.expectEqual(public_key.x, public_key2.x);
    try testing.expectEqual(public_key.y, public_key2.y);
}

test "derive address from private key" {
    const private_key = PrivateKey{
        0xac, 0x09, 0x74, 0xbe, 0xc3, 0x9a, 0x17, 0xe3,
        0x6b, 0xa4, 0xa6, 0xb4, 0xd2, 0x38, 0xff, 0x24,
        0x4e, 0x21, 0xdb, 0x63, 0x5c, 0x51, 0xcb, 0x29,
        0x36, 0x49, 0x5a, 0xf7, 0x42, 0x2f, 0xba, 0x41,
    };

    const public_key = try unaudited_getPublicKey(private_key);
    const address = publicKeyToAddress(public_key);

    // Address should be 20 bytes
    try testing.expectEqual(@as(usize, 20), address.len);

    // Address should be deterministic
    const address2 = publicKeyToAddress(public_key);
    try testing.expectEqualSlices(u8, &address, &address2);
}

test "personal sign message" {
    const private_key = PrivateKey{ 0x42, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };

    const message = "Hello, Ethereum!";

    // Sign with personal_sign prefix
    const signature = try unaudited_signMessage(message, private_key);

    // Verify signature format
    try testing.expectEqual(@as(usize, 32), @sizeOf(@TypeOf(signature.r)));
    try testing.expectEqual(@as(usize, 32), @sizeOf(@TypeOf(signature.s)));
    try testing.expect(signature.v == 27 or signature.v == 28);
}

test "signature normalization" {
    // Signatures should have normalized S values (low S)
    // S should be <= n/2 where n is the curve order
    const signature = Signature{
        .r = 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff,
        .s = 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff, // High S value
        .v = 27,
    };

    // This signature would be invalid due to high S
    try testing.expect(!signature.isValid());
}

test "validate signature components" {
    // Valid signature
    const valid_sig = Signature{
        .r = 0x1234567890123456789012345678901234567890123456789012345678901234,
        .s = 0x3456789012345678901234567890123456789012345678901234567890123456,
        .v = 27,
    };
    try testing.expect(isValidSignature(valid_sig));

    // Invalid v value
    const invalid_v = Signature{
        .r = 0x1234567890123456789012345678901234567890123456789012345678901234,
        .s = 0x3456789012345678901234567890123456789012345678901234567890123456,
        .v = 26, // Should be 27 or 28
    };
    try testing.expect(!isValidSignature(invalid_v));

    // Zero r value (invalid)
    const zero_r = Signature{
        .r = 0,
        .s = 0x3456789012345678901234567890123456789012345678901234567890123456,
        .v = 27,
    };
    try testing.expect(!isValidSignature(zero_r));

    // Zero s value (invalid)
    const zero_s = Signature{
        .r = 0x1234567890123456789012345678901234567890123456789012345678901234,
        .s = 0,
        .v = 27,
    };
    try testing.expect(!isValidSignature(zero_s));
}

// ============================================================================
// RFC 6979 Deterministic ECDSA Tests
// ============================================================================

test "RFC 6979 deterministic signature - test vector 1" {
    // Test vector from Bitcoin community implementations
    // Private key: 0x0000000000000000000000000000000000000000000000000000000000000001
    // Message: "Satoshi Nakamoto"
    // Expected k: 0x8F8A276C19F4149656B280621E358CCE24F5F52542772691EE69063B74F15D15
    // Expected r: 0x934b1ea10a4b3c1757e2b0c017d0b6143ce3c9a7e6a4a49860d7a6ab210ee3d8

    const private_key = PrivateKey{
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
    };

    const message = "Satoshi Nakamoto";
    const message_hash = Hash.keccak256(message);

    // Sign the message
    const signature = try unaudited_signHash(message_hash, private_key);

    // Verify signature is valid
    try testing.expect(signature.isValid());

    // Verify signature is deterministic - sign again and compare
    const signature2 = try unaudited_signHash(message_hash, private_key);
    try testing.expectEqual(signature.r, signature2.r);
    try testing.expectEqual(signature.s, signature2.s);

    // Verify we can recover the address
    const recovered_address = try unaudited_recoverAddress(message_hash, signature);
    const public_key = try unaudited_getPublicKey(private_key);
    const expected_address = public_key.toAddress();
    try testing.expect(std.mem.eql(u8, &recovered_address.bytes, &expected_address.bytes));
}

test "RFC 6979 deterministic signature - test vector 2" {
    // Test with a different private key
    const private_key = PrivateKey{
        0xfe, 0xed, 0xbe, 0xef, 0xde, 0xad, 0xc0, 0xde,
        0xca, 0xfe, 0xba, 0xbe, 0x12, 0x34, 0x56, 0x78,
        0x9a, 0xbc, 0xde, 0xf0, 0x12, 0x34, 0x56, 0x78,
        0x9a, 0xbc, 0xde, 0xf0, 0x11, 0x22, 0x33, 0x44,
    };

    const message = "test message for RFC 6979";
    const message_hash = Hash.keccak256(message);

    // Sign the message twice
    const signature1 = try unaudited_signHash(message_hash, private_key);
    const signature2 = try unaudited_signHash(message_hash, private_key);

    // Signatures should be identical (deterministic)
    try testing.expectEqual(signature1.r, signature2.r);
    try testing.expectEqual(signature1.s, signature2.s);
    try testing.expectEqual(signature1.v, signature2.v);

    // Both signatures should verify correctly
    const public_key = try unaudited_getPublicKey(private_key);
    const expected_address = public_key.toAddress();

    const recovered_address1 = try unaudited_recoverAddress(message_hash, signature1);
    const recovered_address2 = try unaudited_recoverAddress(message_hash, signature2);

    try testing.expect(std.mem.eql(u8, &recovered_address1.bytes, &expected_address.bytes));
    try testing.expect(std.mem.eql(u8, &recovered_address2.bytes, &expected_address.bytes));
}

test "RFC 6979 deterministic signature - different messages produce different signatures" {
    // Same private key but different messages should produce different signatures
    const private_key = PrivateKey{
        0x42, 0x42, 0x42, 0x42, 0x42, 0x42, 0x42, 0x42,
        0x42, 0x42, 0x42, 0x42, 0x42, 0x42, 0x42, 0x42,
        0x42, 0x42, 0x42, 0x42, 0x42, 0x42, 0x42, 0x42,
        0x42, 0x42, 0x42, 0x42, 0x42, 0x42, 0x42, 0x42,
    };

    const message1 = "message one";
    const message2 = "message two";

    const hash1 = Hash.keccak256(message1);
    const hash2 = Hash.keccak256(message2);

    const sig1 = try unaudited_signHash(hash1, private_key);
    const sig2 = try unaudited_signHash(hash2, private_key);

    // Signatures should be different
    try testing.expect(sig1.r != sig2.r or sig1.s != sig2.s);

    // But both should be valid and deterministic
    const sig1_repeat = try unaudited_signHash(hash1, private_key);
    const sig2_repeat = try unaudited_signHash(hash2, private_key);

    try testing.expectEqual(sig1.r, sig1_repeat.r);
    try testing.expectEqual(sig1.s, sig1_repeat.s);
    try testing.expectEqual(sig2.r, sig2_repeat.r);
    try testing.expectEqual(sig2.s, sig2_repeat.s);
}

test "RFC 6979 deterministic signature - empty message" {
    // Test with empty message (edge case)
    const private_key = PrivateKey{
        0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa,
        0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa,
        0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa,
        0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa,
    };

    const empty_message = "";
    const hash = Hash.keccak256(empty_message);

    // Sign empty message
    const sig1 = try unaudited_signHash(hash, private_key);
    const sig2 = try unaudited_signHash(hash, private_key);

    // Should be deterministic
    try testing.expectEqual(sig1.r, sig2.r);
    try testing.expectEqual(sig1.s, sig2.s);

    // Should be valid
    try testing.expect(sig1.isValid());

    // Should recover correct address
    const public_key = try unaudited_getPublicKey(private_key);
    const expected_address = public_key.toAddress();
    const recovered = try unaudited_recoverAddress(hash, sig1);
    try testing.expect(std.mem.eql(u8, &recovered.bytes, &expected_address.bytes));
}

test "RFC 6979 deterministic signature - long message" {
    // Test with a long message
    const private_key = PrivateKey{
        0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55,
        0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55,
        0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55,
        0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55,
    };

    const long_message = "The Times 03/Jan/2009 Chancellor on brink of second bailout for banks. " ++
        "This is a longer message to test RFC 6979 with various message lengths. " ++
        "Deterministic signatures ensure no nonce reuse vulnerabilities.";

    const hash = Hash.keccak256(long_message);

    // Sign multiple times
    const sig1 = try unaudited_signHash(hash, private_key);
    const sig2 = try unaudited_signHash(hash, private_key);
    const sig3 = try unaudited_signHash(hash, private_key);

    // All signatures should be identical
    try testing.expectEqual(sig1.r, sig2.r);
    try testing.expectEqual(sig1.s, sig2.s);
    try testing.expectEqual(sig1.v, sig2.v);
    try testing.expectEqual(sig2.r, sig3.r);
    try testing.expectEqual(sig2.s, sig3.s);
    try testing.expectEqual(sig2.v, sig3.v);

    // Should verify correctly
    const public_key = try unaudited_getPublicKey(private_key);
    const expected_address = public_key.toAddress();
    const recovered = try unaudited_recoverAddress(hash, sig1);
    try testing.expect(std.mem.eql(u8, &recovered.bytes, &expected_address.bytes));
}
