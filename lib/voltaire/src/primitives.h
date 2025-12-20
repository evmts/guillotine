/**
 * Primitives C API
 *
 * C bindings for Ethereum primitives library
 * Provides address operations, hashing, hex utilities, and more.
 *
 * AUTO-GENERATED - DO NOT EDIT MANUALLY
 * Generated from src/c_api.zig by scripts/generate_c_header.zig
 */

#ifndef PRIMITIVES_H
#define PRIMITIVES_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// ============================================================================
// Error Codes
// ============================================================================

/** Operation completed successfully */
#define PRIMITIVES_SUCCESS 0

/** Invalid hexadecimal string */
#define PRIMITIVES_ERROR_INVALID_HEX -1

/** Invalid length for operation */
#define PRIMITIVES_ERROR_INVALID_LENGTH -2

/** Invalid checksum (EIP-55) */
#define PRIMITIVES_ERROR_INVALID_CHECKSUM -3

/** Out of memory */
#define PRIMITIVES_ERROR_OUT_OF_MEMORY -4

/** Invalid input parameter */
#define PRIMITIVES_ERROR_INVALID_INPUT -5

/** Invalid signature */
#define PRIMITIVES_ERROR_INVALID_SIGNATURE -6


// ============================================================================
// Types
// ============================================================================

/** Ethereum address (20 bytes) */
typedef struct {
    uint8_t bytes[20];
} PrimitivesAddress;

/** Hash value (32 bytes) - used for Keccak-256, etc. */
typedef struct {
    uint8_t bytes[32];
} PrimitivesHash;

/** 256-bit unsigned integer (32 bytes, big-endian) */
typedef struct {
    uint8_t bytes[32];
} PrimitivesU256;

/** Signature structure (65 bytes: r + s + v) */
typedef struct {
    uint8_t r[32];
    uint8_t s[32];
    uint8_t v;
} PrimitivesSignature;


// ============================================================================
// Address API
// ============================================================================

/**
 * Create address from hex string (with or without 0x prefix)
 * Returns PRIMITIVES_SUCCESS on success
 */
int primitives_address_from_hex(const char * hex, PrimitivesAddress * out_address);

/**
 * Convert address to hex string (42 bytes: "0x" + 40 hex chars)
 * buf must be at least 42 bytes
 */
int primitives_address_to_hex(const PrimitivesAddress * address, uint8_t * buf);

/**
 * Convert address to checksummed hex (EIP-55)
 * buf must be at least 42 bytes
 */
int primitives_address_to_checksum_hex(const PrimitivesAddress * address, uint8_t * buf);

/**
 * Check if address is zero address
 */
bool primitives_address_is_zero(const PrimitivesAddress * address);

/**
 * Compare two addresses for equality
 */
bool primitives_address_equals(const PrimitivesAddress * a, const PrimitivesAddress * b);

/**
 * Validate EIP-55 checksum
 */
bool primitives_address_validate_checksum(const char * hex);

// ============================================================================
// Keccak-256 API
// ============================================================================

/**
 * Compute Keccak-256 hash of input data
 */
int primitives_keccak256(const uint8_t * data, size_t data_len, PrimitivesHash * out_hash);

/**
 * Convert hash to hex string (66 bytes: "0x" + 64 hex chars)
 * buf must be at least 66 bytes
 */
int primitives_hash_to_hex(const PrimitivesHash * hash, uint8_t * buf);

/**
 * Create hash from hex string
 */
int primitives_hash_from_hex(const char * hex, PrimitivesHash * out_hash);

/**
 * Compare two hashes for equality (constant-time)
 */
bool primitives_hash_equals(const PrimitivesHash * a, const PrimitivesHash * b);

// ============================================================================
// Hex utilities API
// ============================================================================

/**
 * Convert hex string to bytes
 * Returns the number of bytes written, or negative error code
 */
int primitives_hex_to_bytes(const char * hex, uint8_t * out_buf, size_t buf_len);

/**
 * Convert bytes to hex string
 * Returns the number of characters written (including 0x prefix), or negative error code
 */
int primitives_bytes_to_hex(const uint8_t * data, size_t data_len, uint8_t * out_buf, size_t buf_len);

// ============================================================================
// U256 utilities API
// ============================================================================

/**
 * Parse u256 from hex string
 */
int primitives_u256_from_hex(const char * hex, PrimitivesU256 * out_u256);

/**
 * Convert u256 to hex string (66 bytes: "0x" + 64 hex chars)
 */
int primitives_u256_to_hex(const PrimitivesU256 * value_u256, uint8_t * buf, size_t buf_len);

// ============================================================================
// EIP-191 Personal Message Signing
// ============================================================================

/**
 * Hash a message using EIP-191 personal message format
 */
int primitives_eip191_hash_message(const uint8_t * message, size_t message_len, PrimitivesHash * out_hash);

// ============================================================================
// Address derivation
// ============================================================================

/**
 * Calculate CREATE contract address (from sender and nonce)
 */
int primitives_calculate_create_address(const PrimitivesAddress * sender, uint64_t nonce, PrimitivesAddress * out_address);

// ============================================================================
// Cryptographic Signatures (secp256k1)
// ============================================================================

/**
 * Recover public key from ECDSA signature
 * Returns PRIMITIVES_SUCCESS on success
 */
int primitives_secp256k1_recover_pubkey(const uint8_t * message_hash, const uint8_t * r, const uint8_t * s, uint8_t v, uint8_t * out_pubkey);

/**
 * Recover Ethereum address from ECDSA signature
 */
int primitives_secp256k1_recover_address(const uint8_t * message_hash, const uint8_t * r, const uint8_t * s, uint8_t v, PrimitivesAddress * out_address);

/**
 * Derive public key from private key
 */
int primitives_secp256k1_pubkey_from_private(const uint8_t * private_key, uint8_t * out_pubkey);

/**
 * Validate ECDSA signature components
 */
bool primitives_secp256k1_validate_signature(const uint8_t * r, const uint8_t * s);

// ============================================================================
// Hash Algorithms (SHA256, RIPEMD160)
// ============================================================================

/**
 * Compute SHA256 hash of input data
 */
int primitives_sha256(const uint8_t * data, size_t data_len, uint8_t * out_hash);

/**
 * Compute RIPEMD160 hash of input data
 */
int primitives_ripemd160(const uint8_t * data, size_t data_len, uint8_t * out_hash);

// ============================================================================
// RLP Encoding/Decoding
// ============================================================================

/**
 * Encode bytes as RLP
 * Returns the number of bytes written, or negative error code
 */
int primitives_rlp_encode_bytes(const uint8_t * data, size_t data_len, uint8_t * out_buf, size_t buf_len);

/**
 * Encode unsigned integer as RLP
 * value_bytes must be 32 bytes (big-endian u256)
 */
int primitives_rlp_encode_uint(const uint8_t * value_bytes, uint8_t * out_buf, size_t buf_len);

/**
 * Convert RLP bytes to hex string
 */
int primitives_rlp_to_hex(const uint8_t * rlp_data, size_t rlp_len, uint8_t * out_buf, size_t buf_len);

/**
 * Convert hex string to RLP bytes
 */
int primitives_rlp_from_hex(const char * hex, uint8_t * out_buf, size_t buf_len);

// ============================================================================
// Transaction Operations
// ============================================================================

/**
 * Detect transaction type from serialized data
 * Returns type (0-4) or negative error code
 */
int primitives_tx_detect_type(const uint8_t * data, size_t data_len);

// ============================================================================
// Signature Utilities
// ============================================================================

/**
 * Normalize signature to canonical form (low-s)
 * Modifies signature in-place if needed
 * Returns true if normalization was performed
 */
bool primitives_signature_normalize(uint8_t * r, uint8_t * s);

/**
 * Check if signature is in canonical form
 */
bool primitives_signature_is_canonical(const uint8_t * r, const uint8_t * s);

/**
 * Parse signature from DER or compact format
 * Input: 64 or 65 byte signature (r + s + optional v)
 * Output: r, s, v components
 */
int primitives_signature_parse(const uint8_t * sig_data, size_t sig_len, uint8_t * out_r, uint8_t * out_s, uint8_t * out_v);

/**
 * Serialize signature to compact format (64 or 65 bytes)
 * include_v: if true, append v byte to create 65-byte signature
 */
int primitives_signature_serialize(const uint8_t * r, const uint8_t * s, uint8_t v, bool include_v, uint8_t * out_buf);

// ============================================================================
// Wallet Generation
// ============================================================================

/**
 * Generate a cryptographically secure random private key
 */
int primitives_generate_private_key(uint8_t * out_private_key);

/**
 * Compress public key from uncompressed format (64 bytes) to compressed (33 bytes)
 */
int primitives_compress_public_key(const uint8_t * uncompressed, uint8_t * out_compressed);

// ============================================================================
// Bytecode Operations
// ============================================================================

/**
 * Analyze bytecode to find valid JUMPDEST locations
 * Returns the number of valid jump destinations found
 * out_jumpdests must have space for at least max_jumpdests u32 values
 */
int primitives_bytecode_analyze_jumpdests(const uint8_t * code, size_t code_len, uint32_t * out_jumpdests, size_t max_jumpdests);

/**
 * Check if a position is at a bytecode boundary (not inside PUSH data)
 */
bool primitives_bytecode_is_boundary(const uint8_t * code, size_t code_len, uint32_t position);

/**
 * Check if a position is a valid JUMPDEST
 */
bool primitives_bytecode_is_valid_jumpdest(const uint8_t * code, size_t code_len, uint32_t position);

/**
 * Validate bytecode for basic correctness
 * Returns PRIMITIVES_SUCCESS if valid, error code otherwise
 */
int primitives_bytecode_validate(const uint8_t * code, size_t code_len);

// ============================================================================
// Solidity Packed Hashing
// ============================================================================

/**
 * Compute keccak256 of tightly packed arguments
 * This mimics Solidity's abi.encodePacked followed by keccak256
 */
int primitives_solidity_keccak256(const uint8_t * packed_data, size_t data_len, PrimitivesHash * out_hash);

/**
 * Compute SHA256 of tightly packed arguments
 */
int primitives_solidity_sha256(const uint8_t * packed_data, size_t data_len, uint8_t * out_hash);

// ============================================================================
// Additional Hash Algorithms
// ============================================================================

/**
 * Compute Blake2b hash (for EIP-152)
 */
int primitives_blake2b(const uint8_t * data, size_t data_len, uint8_t * out_hash);

// ============================================================================
// CREATE2 Address Calculation
// ============================================================================

/**
 * Calculate CREATE2 contract address
 * Formula: keccak256(0xff ++ sender ++ salt ++ keccak256(init_code))[12:]
 */
int primitives_calculate_create2_address(const PrimitivesAddress * sender, const uint8_t * salt, const uint8_t * init_code, size_t init_code_len, PrimitivesAddress * out_address);

// ============================================================================
// Version info
// ============================================================================

const char * primitives_version_string(void);

// ============================================================================
// WASM Memory Management
// ============================================================================


#ifdef __cplusplus
}
#endif

#endif /* PRIMITIVES_H */
