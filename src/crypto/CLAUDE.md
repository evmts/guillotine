# CLAUDE.md - Crypto Module

## MISSION CRITICAL: Cryptographic Security Foundation
**Any vulnerability enables theft.** Constant-time, side-channel resistant, specification-compliant.

## Core Specifications (IMMUTABLE)
- **Hash**: Keccak-256 (NOT SHA3-256) - different padding
- **Signatures**: ECDSA over secp256k1
- **Addresses**: Last 20 bytes of Keccak256(public_key)
- **Curves**: secp256k1, BN254 (alt_bn128)
- **Precompiles**: 0x01-0x09 cryptographic functions

## Critical Implementations

### Keccak-256 (CONSENSUS CRITICAL)
```zig
pub fn keccak256(data: []const u8) [32]u8 {
    var hasher = std.crypto.hash.sha3.Keccak256.init(.{});
    hasher.update(data);
    var result: [32]u8 = undefined;
    hasher.final(&result);
    return result;
}

// CRITICAL: Verify Keccak-256, NOT SHA3-256
comptime {
    const expected = hex_decode("4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45");
    if (!std.mem.eql(u8, &expected, &keccak256("abc"))) {
        @compileError("Keccak256 implementation incorrect");
    }
}
```

### Address Operations
```zig
pub fn derive_address(public_key: [64]u8) [20]u8 {
    const hash = keccak256(&public_key);
    return hash[12..32]; // Last 20 bytes
}

pub fn derive_contract_address(deployer: [20]u8, nonce: u64) [20]u8 {
    const rlp_encoded = rlp_encode_address_nonce(deployer, nonce);
    const hash = keccak256(rlp_encoded);
    return hash[12..32];
}
```

### ECDSA Signatures (FUND SAFETY CRITICAL)
```zig
pub fn recover_public_key(message_hash: [32]u8, signature: [65]u8) !?[64]u8 {
    const r = signature[0..32];
    const s = signature[32..64];
    const v = signature[64];

    // Validate components
    if (!is_valid_signature_component(r, s, v)) return null;
    if (is_malleable_signature(s)) return null; // EIP-2
    if (v < 27 or v > 30) return null;

    return secp256k1.recover_public_key(message_hash, r, s, v - 27);
}
```

### BN254 Operations (EIP-196/197)
```zig
pub fn validate_bn254_point(x: u256, y: u256) bool {
    // y² = x³ + 3 (mod p)
    const x_cubed = modular_pow(x, 3, BN254_FIELD_MODULUS);
    const y_squared = modular_pow(y, 2, BN254_FIELD_MODULUS);
    return y_squared == add_mod(x_cubed, 3, BN254_FIELD_MODULUS);
}
```

## Constant-Time Operations (CRITICAL)
```zig
pub fn constant_time_compare(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var result: u8 = 0;
    for (a, b) |byte_a, byte_b| {
        result |= byte_a ^ byte_b;
    }
    return result == 0;
}

pub fn constant_time_select(condition: bool, if_true: u256, if_false: u256) u256 {
    const mask = @as(u256, @intFromBool(condition)) - 1;
    return (if_true & mask) | (if_false & ~mask);
}
```

## Security Requirements
- **Side-Channel Resistance**: Constant-time operations, no timing leaks
- **Input Validation**: Validate all signature components, curve points
- **Memory Safety**: Secure memory clearing, bounds checking
- **Specification Compliance**: Exact EIP implementation

## Testing & Errors
**Tests**: Hash function vectors, ECDSA edge cases, BN254 validation, timing attacks
**Errors**: InvalidSignature/PublicKey/Point/Scalar/Modulus, HashFailure

## Emergency Procedures
1. **Vulnerability**: Assess scope, isolate operations, audit code
2. **Side-Channel**: Monitor timing/power/cache patterns, implement mitigations

**Remember: Cryptographic security is non-negotiable. Any weakness enables fund theft.**