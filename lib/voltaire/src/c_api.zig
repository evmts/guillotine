const std = @import("std");
const primitives = @import("voltaire");
const crypto = @import("crypto");
const builtin = @import("builtin");

// Error codes for C API
pub const PRIMITIVES_SUCCESS: c_int = 0;
pub const PRIMITIVES_ERROR_INVALID_HEX: c_int = -1;
pub const PRIMITIVES_ERROR_INVALID_LENGTH: c_int = -2;
pub const PRIMITIVES_ERROR_INVALID_CHECKSUM: c_int = -3;
pub const PRIMITIVES_ERROR_OUT_OF_MEMORY: c_int = -4;
pub const PRIMITIVES_ERROR_INVALID_INPUT: c_int = -5;
pub const PRIMITIVES_ERROR_INVALID_SIGNATURE: c_int = -6;

// C-compatible Address type (20 bytes)
pub const PrimitivesAddress = extern struct {
    bytes: [20]u8,
};

// C-compatible Hash type (32 bytes)
pub const PrimitivesHash = extern struct {
    bytes: [32]u8,
};

// C-compatible U256 type (32 bytes, big-endian)
pub const PrimitivesU256 = extern struct {
    bytes: [32]u8,
};

// ============================================================================
// Address API
// ============================================================================

/// Create address from hex string (with or without 0x prefix)
/// Returns PRIMITIVES_SUCCESS on success
export fn primitives_address_from_hex(
    hex: [*:0]const u8,
    out_address: *PrimitivesAddress,
) c_int {
    const hex_slice = std.mem.span(hex);
    const addr = primitives.Address.fromHex(hex_slice) catch {
        return PRIMITIVES_ERROR_INVALID_HEX;
    };
    @memcpy(&out_address.bytes, &addr.bytes);
    return PRIMITIVES_SUCCESS;
}

/// Convert address to hex string (42 bytes: "0x" + 40 hex chars)
/// buf must be at least 42 bytes
export fn primitives_address_to_hex(
    address: *const PrimitivesAddress,
    buf: [*]u8,
) c_int {
    const addr = primitives.Address{ .bytes = address.bytes };
    const hex = addr.toHex();
    @memcpy(buf[0..42], &hex);
    return PRIMITIVES_SUCCESS;
}

/// Convert address to checksummed hex (EIP-55)
/// buf must be at least 42 bytes
export fn primitives_address_to_checksum_hex(
    address: *const PrimitivesAddress,
    buf: [*]u8,
) c_int {
    const addr = primitives.Address{ .bytes = address.bytes };
    const hex = addr.toChecksumHex();
    @memcpy(buf[0..42], &hex);
    return PRIMITIVES_SUCCESS;
}

/// Check if address is zero address
export fn primitives_address_is_zero(
    address: *const PrimitivesAddress,
) bool {
    const addr = primitives.Address{ .bytes = address.bytes };
    return addr.isZero();
}

/// Compare two addresses for equality
export fn primitives_address_equals(
    a: *const PrimitivesAddress,
    b: *const PrimitivesAddress,
) bool {
    const addr_a = primitives.Address{ .bytes = a.bytes };
    const addr_b = primitives.Address{ .bytes = b.bytes };
    return addr_a.equals(addr_b);
}

/// Validate EIP-55 checksum
export fn primitives_address_validate_checksum(
    hex: [*:0]const u8,
) bool {
    const hex_slice = std.mem.span(hex);
    return primitives.Address.isValidChecksum(hex_slice);
}

// ============================================================================
// Keccak-256 API
// ============================================================================

/// Compute Keccak-256 hash of input data
export fn primitives_keccak256(
    data: [*]const u8,
    data_len: usize,
    out_hash: *PrimitivesHash,
) c_int {
    const input = data[0..data_len];
    const hash = crypto.HashUtils.keccak256(input);
    @memcpy(&out_hash.bytes, &hash);
    return PRIMITIVES_SUCCESS;
}

/// Convert hash to hex string (66 bytes: "0x" + 64 hex chars)
/// buf must be at least 66 bytes
export fn primitives_hash_to_hex(
    hash: *const PrimitivesHash,
    buf: [*]u8,
) c_int {
    const hex = crypto.HashUtils.toHex(hash.bytes);
    @memcpy(buf[0..66], &hex);
    return PRIMITIVES_SUCCESS;
}

/// Create hash from hex string
export fn primitives_hash_from_hex(
    hex: [*:0]const u8,
    out_hash: *PrimitivesHash,
) c_int {
    const hex_slice = std.mem.span(hex);
    const hash = crypto.HashUtils.fromHex(hex_slice) catch {
        return PRIMITIVES_ERROR_INVALID_HEX;
    };
    @memcpy(&out_hash.bytes, &hash);
    return PRIMITIVES_SUCCESS;
}

/// Compare two hashes for equality (constant-time)
export fn primitives_hash_equals(
    a: *const PrimitivesHash,
    b: *const PrimitivesHash,
) bool {
    return crypto.HashUtils.equal(a.bytes, b.bytes);
}

// ============================================================================
// Hex utilities API
// ============================================================================

/// Convert hex string to bytes
/// Returns the number of bytes written, or negative error code
export fn primitives_hex_to_bytes(
    hex: [*:0]const u8,
    out_buf: [*]u8,
    buf_len: usize,
) c_int {
    const hex_slice = std.mem.span(hex);

    // We need an allocator for temporary conversion
    // Since we can't use C allocator easily, use a stack buffer for small conversions
    var stack_buf: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&stack_buf);
    const allocator = fba.allocator();

    const bytes = primitives.Hex.hexToBytes(allocator, hex_slice) catch {
        return PRIMITIVES_ERROR_INVALID_HEX;
    };
    defer allocator.free(bytes);

    if (bytes.len > buf_len) {
        return PRIMITIVES_ERROR_INVALID_LENGTH;
    }

    @memcpy(out_buf[0..bytes.len], bytes);
    return @intCast(bytes.len);
}

/// Convert bytes to hex string
/// Returns the number of characters written (including 0x prefix), or negative error code
export fn primitives_bytes_to_hex(
    data: [*]const u8,
    data_len: usize,
    out_buf: [*]u8,
    buf_len: usize,
) c_int {
    const input = data[0..data_len];
    const required_len = 2 + (data_len * 2); // "0x" + 2 chars per byte

    if (buf_len < required_len) {
        return PRIMITIVES_ERROR_INVALID_LENGTH;
    }

    var stack_buf: [2048]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&stack_buf);
    const allocator = fba.allocator();

    const hex = primitives.Hex.bytesToHex(allocator, input) catch {
        return PRIMITIVES_ERROR_OUT_OF_MEMORY;
    };
    defer allocator.free(hex);

    @memcpy(out_buf[0..hex.len], hex);
    return @intCast(hex.len);
}

// ============================================================================
// U256 utilities API
// ============================================================================

/// Parse u256 from hex string
export fn primitives_u256_from_hex(
    hex: [*:0]const u8,
    out_u256: *PrimitivesU256,
) c_int {
    const hex_slice = std.mem.span(hex);
    const value = primitives.Hex.hexToU256(hex_slice) catch {
        return PRIMITIVES_ERROR_INVALID_HEX;
    };

    // Convert u256 to big-endian bytes
    var bytes: [32]u8 = undefined;
    std.mem.writeInt(u256, &bytes, value, .big);
    @memcpy(&out_u256.bytes, &bytes);
    return PRIMITIVES_SUCCESS;
}

/// Convert u256 to hex string (66 bytes: "0x" + 64 hex chars)
export fn primitives_u256_to_hex(
    value_u256: *const PrimitivesU256,
    buf: [*]u8,
    buf_len: usize,
) c_int {
    if (buf_len < 66) {
        return PRIMITIVES_ERROR_INVALID_LENGTH;
    }

    const value = std.mem.readInt(u256, &value_u256.bytes, .big);

    var stack_buf: [256]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&stack_buf);
    const allocator = fba.allocator();

    const hex = primitives.Hex.u256ToHex(allocator, value) catch {
        return PRIMITIVES_ERROR_OUT_OF_MEMORY;
    };
    defer allocator.free(hex);

    @memcpy(buf[0..hex.len], hex);
    return PRIMITIVES_SUCCESS;
}

// ============================================================================
// EIP-191 Personal Message Signing
// ============================================================================

/// Hash a message using EIP-191 personal message format
export fn primitives_eip191_hash_message(
    message: [*]const u8,
    message_len: usize,
    out_hash: *PrimitivesHash,
) c_int {
    const msg = message[0..message_len];

    // Use a heap allocator to support large messages (up to 1MB+)
    // FixedBufferAllocator with small stack buffers caused OOM for >5KB
    const allocator = std.heap.page_allocator;

    const hash = crypto.HashUtils.eip191HashMessage(msg, allocator) catch {
        return PRIMITIVES_ERROR_OUT_OF_MEMORY;
    };
    @memcpy(&out_hash.bytes, &hash);
    return PRIMITIVES_SUCCESS;
}

// ============================================================================
// Address derivation
// ============================================================================

/// Calculate CREATE contract address (from sender and nonce)
export fn primitives_calculate_create_address(
    sender: *const PrimitivesAddress,
    nonce: u64,
    out_address: *PrimitivesAddress,
) c_int {
    const sender_addr = primitives.Address{ .bytes = sender.bytes };

    var stack_buf: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&stack_buf);
    const allocator = fba.allocator();

    const addr = primitives.Address.calculateCreateAddress(allocator, sender_addr, nonce) catch {
        return PRIMITIVES_ERROR_OUT_OF_MEMORY;
    };

    @memcpy(&out_address.bytes, &addr.bytes);
    return PRIMITIVES_SUCCESS;
}

// ============================================================================
// Cryptographic Signatures (secp256k1)
// ============================================================================

/// Signature structure for C API (65 bytes: r + s + v)
pub const PrimitivesSignature = extern struct {
    r: [32]u8,
    s: [32]u8,
    v: u8,
};

/// Recover public key from ECDSA signature
/// Returns PRIMITIVES_SUCCESS on success
export fn primitives_secp256k1_recover_pubkey(
    message_hash: *const [32]u8,
    r: *const [32]u8,
    s: *const [32]u8,
    v: u8,
    out_pubkey: *[64]u8,
) c_int {
    const pubkey = crypto.secp256k1.recoverPubkey(message_hash, r, s, v) catch {
        return PRIMITIVES_ERROR_INVALID_SIGNATURE;
    };
    @memcpy(out_pubkey, &pubkey);
    return PRIMITIVES_SUCCESS;
}

/// Recover Ethereum address from ECDSA signature
export fn primitives_secp256k1_recover_address(
    message_hash: *const [32]u8,
    r: *const [32]u8,
    s: *const [32]u8,
    v: u8,
    out_address: *PrimitivesAddress,
) c_int {
    // Parse r and s as u256 (big-endian)
    const r_u256 = std.mem.readInt(u256, r, .big);
    const s_u256 = std.mem.readInt(u256, s, .big);

    // Convert v to recovery ID (handle both 0-1 and 27-28 formats)
    var recovery_id: u8 = undefined;
    if (v >= 27 and v <= 28) {
        recovery_id = v - 27;
    } else if (v <= 1) {
        recovery_id = v;
    } else {
        return PRIMITIVES_ERROR_INVALID_SIGNATURE;
    }

    const addr = crypto.secp256k1.unauditedRecoverAddress(
        message_hash,
        recovery_id,
        r_u256,
        s_u256,
    ) catch {
        return PRIMITIVES_ERROR_INVALID_SIGNATURE;
    };

    @memcpy(&out_address.bytes, &addr.bytes);
    return PRIMITIVES_SUCCESS;
}

/// Derive public key from private key
export fn primitives_secp256k1_pubkey_from_private(
    private_key: *const [32]u8,
    out_pubkey: *[64]u8,
) c_int {
    // Use generator point and scalar multiplication
    const G = crypto.secp256k1.AffinePoint.generator();
    const scalar = std.mem.readInt(u256, private_key, .big);

    if (scalar == 0 or scalar >= crypto.secp256k1.SECP256K1_N) {
        return PRIMITIVES_ERROR_INVALID_INPUT;
    }

    const pubkey_point = G.scalarMul(scalar);

    if (pubkey_point.infinity or !pubkey_point.isOnCurve()) {
        return PRIMITIVES_ERROR_INVALID_INPUT;
    }

    // Serialize public key as uncompressed (x || y)
    std.mem.writeInt(u256, out_pubkey[0..32], pubkey_point.x, .big);
    std.mem.writeInt(u256, out_pubkey[32..64], pubkey_point.y, .big);

    return PRIMITIVES_SUCCESS;
}

/// Validate ECDSA signature components
export fn primitives_secp256k1_validate_signature(
    r: *const [32]u8,
    s: *const [32]u8,
) bool {
    const r_u256 = std.mem.readInt(u256, r, .big);
    const s_u256 = std.mem.readInt(u256, s, .big);

    return crypto.secp256k1.unauditedValidateSignature(r_u256, s_u256);
}

// ============================================================================
// Hash Algorithms (SHA256, RIPEMD160)
// ============================================================================

/// Compute SHA256 hash of input data
export fn primitives_sha256(
    data: [*]const u8,
    data_len: usize,
    out_hash: *[32]u8,
) c_int {
    const input = data[0..data_len];
    crypto.HashAlgorithms.SHA256.hash(input, out_hash) catch {
        return PRIMITIVES_ERROR_INVALID_INPUT;
    };
    return PRIMITIVES_SUCCESS;
}

/// Compute RIPEMD160 hash of input data
export fn primitives_ripemd160(
    data: [*]const u8,
    data_len: usize,
    out_hash: *[20]u8,
) c_int {
    const input = data[0..data_len];
    crypto.HashAlgorithms.RIPEMD160.hash(input, out_hash) catch {
        return PRIMITIVES_ERROR_INVALID_INPUT;
    };
    return PRIMITIVES_SUCCESS;
}

// ============================================================================
// RLP Encoding/Decoding
// ============================================================================

/// Encode bytes as RLP
/// Returns the number of bytes written, or negative error code
export fn primitives_rlp_encode_bytes(
    data: [*]const u8,
    data_len: usize,
    out_buf: [*]u8,
    buf_len: usize,
) c_int {
    const input = data[0..data_len];

    var stack_buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&stack_buf);
    const allocator = fba.allocator();

    const encoded = primitives.Rlp.encodeBytes(allocator, input) catch {
        return PRIMITIVES_ERROR_OUT_OF_MEMORY;
    };
    defer allocator.free(encoded);

    if (encoded.len > buf_len) {
        return PRIMITIVES_ERROR_INVALID_LENGTH;
    }

    @memcpy(out_buf[0..encoded.len], encoded);
    return @intCast(encoded.len);
}

/// Encode unsigned integer as RLP
/// value_bytes must be 32 bytes (big-endian u256)
export fn primitives_rlp_encode_uint(
    value_bytes: *const [32]u8,
    out_buf: [*]u8,
    buf_len: usize,
) c_int {
    const value = std.mem.readInt(u256, value_bytes, .big);

    var stack_buf: [512]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&stack_buf);
    const allocator = fba.allocator();

    // Convert u256 to minimal bytes
    var value_buf: [32]u8 = undefined;
    std.mem.writeInt(u256, &value_buf, value, .big);

    // Find first non-zero byte
    var start: usize = 0;
    while (start < 32 and value_buf[start] == 0) : (start += 1) {}

    const minimal_bytes = if (start == 32) &[_]u8{} else value_buf[start..];

    const encoded = primitives.Rlp.encodeBytes(allocator, minimal_bytes) catch {
        return PRIMITIVES_ERROR_OUT_OF_MEMORY;
    };
    defer allocator.free(encoded);

    if (encoded.len > buf_len) {
        return PRIMITIVES_ERROR_INVALID_LENGTH;
    }

    @memcpy(out_buf[0..encoded.len], encoded);
    return @intCast(encoded.len);
}

/// Convert RLP bytes to hex string
export fn primitives_rlp_to_hex(
    rlp_data: [*]const u8,
    rlp_len: usize,
    out_buf: [*]u8,
    buf_len: usize,
) c_int {
    const input = rlp_data[0..rlp_len];

    var stack_buf: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&stack_buf);
    const allocator = fba.allocator();

    const hex = primitives.Rlp.bytesToHex(allocator, input) catch {
        return PRIMITIVES_ERROR_OUT_OF_MEMORY;
    };
    defer allocator.free(hex);

    if (hex.len > buf_len) {
        return PRIMITIVES_ERROR_INVALID_LENGTH;
    }

    @memcpy(out_buf[0..hex.len], hex);
    return @intCast(hex.len);
}

/// Convert hex string to RLP bytes
export fn primitives_rlp_from_hex(
    hex: [*:0]const u8,
    out_buf: [*]u8,
    buf_len: usize,
) c_int {
    const hex_slice = std.mem.span(hex);

    var stack_buf: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&stack_buf);
    const allocator = fba.allocator();

    const bytes = primitives.Rlp.hexToBytes(allocator, hex_slice) catch {
        return PRIMITIVES_ERROR_INVALID_HEX;
    };
    defer allocator.free(bytes);

    if (bytes.len > buf_len) {
        return PRIMITIVES_ERROR_INVALID_LENGTH;
    }

    @memcpy(out_buf[0..bytes.len], bytes);
    return @intCast(bytes.len);
}

// ============================================================================
// Transaction Operations
// ============================================================================

/// Detect transaction type from serialized data
/// Returns type (0-4) or negative error code
export fn primitives_tx_detect_type(
    data: [*]const u8,
    data_len: usize,
) c_int {
    const input = data[0..data_len];
    const tx_type = primitives.Transaction.detectTransactionType(input);

    return switch (tx_type) {
        .legacy => 0,
        .eip2930 => 1,
        .eip1559 => 2,
        .eip4844 => 3,
        .eip7702 => 4,
    };
}

// ============================================================================
// Signature Utilities
// ============================================================================

/// Normalize signature to canonical form (low-s)
/// Modifies signature in-place if needed
/// Returns true if normalization was performed
export fn primitives_signature_normalize(
    r: *[32]u8,
    s: *[32]u8,
) bool {
    _ = r; // r is not needed for normalization, only s
    const s_u256 = std.mem.readInt(u256, s, .big);

    // Check if s is in the upper half of the curve order
    const half_n = crypto.secp256k1.SECP256K1_N / 2;

    if (s_u256 > half_n) {
        // Normalize: s' = N - s
        const normalized_s = crypto.secp256k1.SECP256K1_N - s_u256;
        std.mem.writeInt(u256, s, normalized_s, .big);
        return true;
    }

    return false;
}

/// Check if signature is in canonical form
export fn primitives_signature_is_canonical(
    r: *const [32]u8,
    s: *const [32]u8,
) bool {
    const r_u256 = std.mem.readInt(u256, r, .big);
    const s_u256 = std.mem.readInt(u256, s, .big);

    return crypto.secp256k1.unauditedValidateSignature(r_u256, s_u256);
}

/// Parse signature from DER or compact format
/// Input: 64 or 65 byte signature (r + s + optional v)
/// Output: r, s, v components
export fn primitives_signature_parse(
    sig_data: [*]const u8,
    sig_len: usize,
    out_r: *[32]u8,
    out_s: *[32]u8,
    out_v: *u8,
) c_int {
    if (sig_len == 64) {
        // Compact format: r(32) + s(32)
        @memcpy(out_r, sig_data[0..32]);
        @memcpy(out_s, sig_data[32..64]);
        out_v.* = 0; // No v provided
        return PRIMITIVES_SUCCESS;
    } else if (sig_len == 65) {
        // Compact format with v: r(32) + s(32) + v(1)
        @memcpy(out_r, sig_data[0..32]);
        @memcpy(out_s, sig_data[32..64]);
        out_v.* = sig_data[64];
        return PRIMITIVES_SUCCESS;
    } else {
        return PRIMITIVES_ERROR_INVALID_LENGTH;
    }
}

/// Serialize signature to compact format (64 or 65 bytes)
/// include_v: if true, append v byte to create 65-byte signature
export fn primitives_signature_serialize(
    r: *const [32]u8,
    s: *const [32]u8,
    v: u8,
    include_v: bool,
    out_buf: [*]u8,
) c_int {
    @memcpy(out_buf[0..32], r);
    @memcpy(out_buf[32..64], s);

    if (include_v) {
        out_buf[64] = v;
        return 65;
    }

    return 64;
}

// ============================================================================
// Wallet Generation
// ============================================================================

/// Generate a cryptographically secure random private key
export fn primitives_generate_private_key(
    out_private_key: *[32]u8,
) c_int {
    var rng = std.crypto.random;

    // Generate random 32 bytes
    rng.bytes(out_private_key);

    // Ensure the key is valid (< secp256k1 curve order)
    const key_value = std.mem.readInt(u256, out_private_key, .big);
    if (key_value == 0 or key_value >= crypto.secp256k1.SECP256K1_N) {
        // Invalid key, regenerate (extremely rare)
        return primitives_generate_private_key(out_private_key);
    }

    return PRIMITIVES_SUCCESS;
}

/// Compress public key from uncompressed format (64 bytes) to compressed (33 bytes)
export fn primitives_compress_public_key(
    uncompressed: *const [64]u8,
    out_compressed: *[33]u8,
) c_int {
    const x_bytes = uncompressed[0..32];
    const y_bytes = uncompressed[32..64];

    const y = std.mem.readInt(u256, y_bytes, .big);

    // Prefix: 0x02 if y is even, 0x03 if y is odd
    out_compressed[0] = if (y & 1 == 0) 0x02 else 0x03;

    // Copy x coordinate
    @memcpy(out_compressed[1..33], x_bytes);

    return PRIMITIVES_SUCCESS;
}

// ============================================================================
// Bytecode Operations
// ============================================================================

/// Analyze bytecode to find valid JUMPDEST locations
/// Returns the number of valid jump destinations found
/// out_jumpdests must have space for at least max_jumpdests u32 values
export fn primitives_bytecode_analyze_jumpdests(
    code: [*]const u8,
    code_len: usize,
    out_jumpdests: [*]u32,
    max_jumpdests: usize,
) c_int {
    const bytecode = code[0..code_len];

    var count: usize = 0;
    var pc: u32 = 0;

    while (pc < bytecode.len and count < max_jumpdests) {
        const opcode = bytecode[pc];

        // Check if this is a JUMPDEST (0x5b)
        if (opcode == 0x5b) {
            out_jumpdests[count] = pc;
            count += 1;
            pc += 1;
        } else if (opcode >= 0x60 and opcode <= 0x7f) {
            // PUSH1-PUSH32: skip immediate data
            const push_size = opcode - 0x5f;
            pc += 1 + push_size;
        } else {
            pc += 1;
        }
    }

    return @intCast(count);
}

/// Check if a position is at a bytecode boundary (not inside PUSH data)
export fn primitives_bytecode_is_boundary(
    code: [*]const u8,
    code_len: usize,
    position: u32,
) bool {
    const bytecode = code[0..code_len];

    if (position >= bytecode.len) {
        return false;
    }

    var pc: u32 = 0;
    while (pc < position) {
        const opcode = bytecode[pc];

        if (opcode >= 0x60 and opcode <= 0x7f) {
            // PUSH1-PUSH32
            const push_size = opcode - 0x5f;
            pc += 1 + push_size;

            // If we jumped past the position, it's inside PUSH data
            if (pc > position) {
                return false;
            }
        } else {
            pc += 1;
        }
    }

    return pc == position;
}

/// Check if a position is a valid JUMPDEST
export fn primitives_bytecode_is_valid_jumpdest(
    code: [*]const u8,
    code_len: usize,
    position: u32,
) bool {
    const bytecode = code[0..code_len];

    // Must be at a boundary
    if (!primitives_bytecode_is_boundary(code, code_len, position)) {
        return false;
    }

    // Must be within bounds and be JUMPDEST opcode
    if (position >= bytecode.len) {
        return false;
    }

    return bytecode[position] == 0x5b;
}

/// Validate bytecode for basic correctness
/// Returns PRIMITIVES_SUCCESS if valid, error code otherwise
export fn primitives_bytecode_validate(
    code: [*]const u8,
    code_len: usize,
) c_int {
    const bytecode = code[0..code_len];

    var pc: usize = 0;
    while (pc < bytecode.len) {
        const opcode = bytecode[pc];

        if (opcode >= 0x60 and opcode <= 0x7f) {
            // PUSH1-PUSH32
            const push_size: usize = opcode - 0x5f;

            // Check if we have enough bytes for the PUSH data
            if (pc + 1 + push_size > bytecode.len) {
                return PRIMITIVES_ERROR_INVALID_INPUT;
            }

            pc += 1 + push_size;
        } else {
            pc += 1;
        }
    }

    return PRIMITIVES_SUCCESS;
}

// ============================================================================
// Solidity Packed Hashing
// ============================================================================

/// Compute keccak256 of tightly packed arguments
/// This mimics Solidity's abi.encodePacked followed by keccak256
export fn primitives_solidity_keccak256(
    packed_data: [*]const u8,
    data_len: usize,
    out_hash: *PrimitivesHash,
) c_int {
    const input = packed_data[0..data_len];
    const hash = crypto.HashUtils.keccak256(input);
    @memcpy(&out_hash.bytes, &hash);
    return PRIMITIVES_SUCCESS;
}

/// Compute SHA256 of tightly packed arguments
export fn primitives_solidity_sha256(
    packed_data: [*]const u8,
    data_len: usize,
    out_hash: *[32]u8,
) c_int {
    const input = packed_data[0..data_len];
    crypto.HashAlgorithms.SHA256.hash(input, out_hash) catch {
        return PRIMITIVES_ERROR_INVALID_INPUT;
    };
    return PRIMITIVES_SUCCESS;
}

// ============================================================================
// Additional Hash Algorithms
// ============================================================================

/// Compute Blake2b hash (for EIP-152)
export fn primitives_blake2b(
    data: [*]const u8,
    data_len: usize,
    out_hash: *[64]u8,
) c_int {
    const input = data[0..data_len];
    std.crypto.hash.blake2.Blake2b512.hash(input, out_hash, .{});
    return PRIMITIVES_SUCCESS;
}

// ============================================================================
// CREATE2 Address Calculation
// ============================================================================

/// Calculate CREATE2 contract address
/// Formula: keccak256(0xff ++ sender ++ salt ++ keccak256(init_code))[12:]
export fn primitives_calculate_create2_address(
    sender: *const PrimitivesAddress,
    salt: *const [32]u8,
    init_code: [*]const u8,
    init_code_len: usize,
    out_address: *PrimitivesAddress,
) c_int {
    const sender_addr = primitives.Address{ .bytes = sender.bytes };
    const salt_u256 = std.mem.readInt(u256, salt, .big);
    const code = init_code[0..init_code_len];

    var stack_buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&stack_buf);
    const allocator = fba.allocator();

    const addr = primitives.Address.calculateCreate2Address(
        allocator,
        sender_addr,
        salt_u256,
        code,
    ) catch {
        return PRIMITIVES_ERROR_OUT_OF_MEMORY;
    };

    @memcpy(&out_address.bytes, &addr.bytes);
    return PRIMITIVES_SUCCESS;
}

// ============================================================================
// Version info
// ============================================================================

export fn primitives_version_string() [*:0]const u8 {
    return "primitives-0.1.0";
}

// ============================================================================
// WASM Memory Management
// ============================================================================

// Note: For WASM, we use a simplified memory model where JavaScript manages
// the linear memory directly. The functions use stack-based allocators internally,
// so no explicit malloc/free exports are needed. JavaScript will allocate buffers
// in the linear memory and pass pointers to these functions.

// Note: Removed main() function that was causing conflicts with C example builds.
// WASM builds don't actually require a main() function when using export functions.
