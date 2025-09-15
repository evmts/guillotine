# CLAUDE.md - Precompiles Module

## MISSION CRITICAL: Precompiled Contract Security
**Precompile bugs enable consensus attacks, fund theft, system compromise.** Must match reference implementations exactly.

## Precompile Address Space (IMMUTABLE)
- **0x01**: ECDSA signature recovery (ecrecover) - 3000 gas
- **0x02**: SHA-256 hash function
- **0x03**: RIPEMD-160 hash function
- **0x04**: Identity function (data copy)
- **0x05**: Modular exponentiation (EIP-198) - dynamic gas
- **0x06**: BN254 elliptic curve addition (EIP-196) - 150 gas
- **0x07**: BN254 scalar multiplication (EIP-196)
- **0x08**: BN254 bilinear pairing check (EIP-197) - 45000 + 34000*pairs
- **0x09**: BLAKE2F compression (EIP-152) - rounds = gas

## Critical Implementations

### ECRECOVER (0x01)
```zig
pub fn ecrecover(input: []const u8) !PrecompileResult {
    if (input.len != 128) return invalid_result(3000);

    const message_hash = input[0..32];
    const v = bytes_to_uint256(input[32..64]);
    const r = bytes_to_uint256(input[64..96]);
    const s = bytes_to_uint256(input[96..128]);

    // CRITICAL validations
    if (v != 27 and v != 28) return invalid_result(3000);
    if (r == 0 or r >= SECP256K1_N) return invalid_result(3000);
    if (s == 0 or s >= SECP256K1_N) return invalid_result(3000);
    if (s > SECP256K1_N / 2) return invalid_result(3000); // EIP-2: prevent malleability

    const public_key = crypto.recover_public_key(message_hash.*, r, s, v - 27) orelse return invalid_result(3000);
    const address = crypto.derive_address(public_key);

    var output: [32]u8 = [_]u8{0} ** 32;
    @memcpy(output[12..32], &address); // Right-padded
    return PrecompileResult{ .success = true, .output = output, .gas_used = 3000 };
}
```

### MODEXP (0x05) - Gas Critical
```zig
pub fn modexp_gas_cost(input: []const u8) u64 {
    if (input.len < 96) return 0;
    const base_len = bytes_to_uint256(input[0..32]);
    const exp_len = bytes_to_uint256(input[32..64]);
    const mod_len = bytes_to_uint256(input[64..96]);

    const max_len = @max(@max(base_len, exp_len), mod_len);
    const complexity = calculate_complexity(max_len);
    const iteration_count = calculate_iteration_count(exp_len, exp_bytes);
    return @max(200, complexity * iteration_count / 3);
}
```

### BN254 Operations (0x06-0x08)
```zig
pub fn validate_g1_point(x: u256, y: u256) bool {
    if (x >= BN254_FIELD_MODULUS or y >= BN254_FIELD_MODULUS) return false;
    if (x == 0 and y == 0) return true; // Point at infinity

    // y² = x³ + 3 (mod p)
    const x_cubed = mod_pow(x, 3, BN254_FIELD_MODULUS);
    const rhs = add_mod(x_cubed, 3, BN254_FIELD_MODULUS);
    const y_squared = mod_pow(y, 2, BN254_FIELD_MODULUS);
    return y_squared == rhs;
}

pub fn bn254_pairing_check(input: []const u8) !PrecompileResult {
    if (input.len % 192 != 0) return invalid_result(45000);
    const pair_count = input.len / 192;
    const gas_cost = 45000 + 34000 * pair_count;

    // Parse and validate all G1/G2 point pairs
    // Perform pairing check: e(p1, q1) * e(p2, q2) * ... == 1
    const result = crypto.bn254_pairing_check(pairs);
    var output: [32]u8 = [_]u8{0} ** 32;
    output[31] = if (result) 1 else 0;
    return PrecompileResult{ .success = true, .output = output, .gas_used = gas_cost };
}
```

### BLAKE2F (0x09)
```zig
pub fn blake2f(input: []const u8) !PrecompileResult {
    if (input.len != 213) return invalid_result(0);
    const rounds = bytes_to_uint32(input[0..4]);
    const f = input[212]; // Final flag
    if (f != 0 and f != 1) return invalid_result(0);

    const result = crypto.blake2f_compress(rounds, h, m, t, f == 1);
    return PrecompileResult{ .success = true, .output = result, .gas_used = rounds };
}
```

## Error Handling
```zig
// CRITICAL: Always consume gas even on failure
pub fn safe_execute_precompile(address: u8, input: []const u8, gas_limit: u64) !PrecompileResult {
    const result = switch (address) {
        0x01 => ecrecover(input),
        0x02 => sha256_hash(input),
        // ... other precompiles
        else => return PrecompileError.InvalidAddress,
    } catch |err| return PrecompileResult{
        .success = false,
        .output = &[_]u8{},
        .gas_used = estimate_failure_gas_cost(address, input.len),
    };

    if (result.gas_used > gas_limit) return PrecompileError.OutOfGas;
    return result;
}
```

## Testing Requirements
- **Unit Tests**: All precompiles with valid/invalid inputs, edge cases, gas calculations
- **EIP Compliance**: Official test vectors, gas cost validation
- **Security**: Malformed input fuzzing, large inputs, memory exhaustion, timing attacks

## Emergency Procedures
1. **Bug Discovery**: Disable affected precompile, assess fund exposure
2. **Reference Validation**: Compare with other implementations
3. **Fix Development**: Minimal targeted fix with comprehensive testing

**Precompiles are consensus-critical. Exact specification compliance over performance.**