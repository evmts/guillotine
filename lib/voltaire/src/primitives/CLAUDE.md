# CLAUDE.md - Primitives Module

## MISSION CRITICAL: Fund Safety First
**Bugs in address calculations, crypto operations, or transaction handling = catastrophic fund loss.**

## Memory Safety Patterns (CRITICAL)
```zig
// Pattern 1: Same scope cleanup
const data = try allocator.create(Data);
defer allocator.destroy(data);

// Pattern 2: Ownership transfer with error cleanup
const data = try allocator.create(Data);
errdefer allocator.destroy(data);
data.* = try Data.init(allocator);
return data; // Ownership transferred
```

## Address Operations - ZERO TOLERANCE

**File: `address.zig`**
- **Format**: Exactly 20 bytes, no exceptions
- **Hex Validation**: 42 characters ("0x" + 40 hex digits)
- **Checksum**: EIP-55 checksum for user inputs
- **Contract Addresses**: RLP encoding of (deployer_address, nonce)
- **CREATE2**: keccak256(0xff, deployer, salt, init_code_hash)

**DANGER**: Never trust user input, exact Ethereum spec compliance required

## Cryptographic Operations - NO SHORTCUTS
- All hashes MUST use Keccak256 (NOT SHA3)
- ECDSA secp256k1 signature verification
- Public key recovery with edge case handling
- Never accept malleable signatures

## Transaction Handling - Fund Transfer Safety

**File: `transaction.zig`**

**Types**: Legacy (0), EIP-2930 (1), EIP-1559 (2), EIP-4844 (3), EIP-7702 (4)

**CRITICAL VALIDATIONS**:
- Chain ID replay protection
- Nonce ordering/uniqueness
- Gas limit (21000 minimum for transfers)
- Signature malleability checks
- Access list format validation
- Blob transaction KZG proof verification

## RLP Encoding - Serialization Correctness

**File: `rlp.zig`**

**ZERO TOLERANCE**:
- Length prefixes minimal (no leading zeros)
- List encoding preserves order
- String vs list distinction critical
- Buffer bounds checking on ALL operations

**Performance**: Single-pass encoding, streaming decode, zero-copy where possible

## Gas Constants - Economic Security

**File: `gas_constants.zig`**

**IMMUTABLE** (never modify):
- Base transaction: 21000 gas
- Contract creation: 32000 gas
- Storage operations: EIP-2929 pricing
- Memory expansion: quadratic costs

**Hardfork Compatibility**: Gas costs change with upgrades, maintain backward compatibility

## Testing Requirements

**Unit Tests MUST Cover**:
- **Address**: All conversions, edge cases, invalid inputs
- **Crypto**: EIP test vectors
- **RLP**: Malformed inputs, large datasets
- **Transaction**: All types, invalid signatures
- **Numeric**: Overflow conditions, unit conversions

**Differential Testing**: Compare with revm, official Ethereum test vectors, other EVMs

## Performance (Hot Paths)
1. Address to/from hex conversion
2. RLP encoding/decoding
3. Hash operations (Keccak256)
4. Signature verification
5. Transaction validation

**Strategy**: Pre-allocate buffers, reuse allocators, arena allocation, stack for small data

## Error Handling
- **Critical** (abort): Memory failures, crypto failures, invalid signatures, gas exceeded
- **Recoverable** (return error): Invalid format, parsing failures, validation errors

## Security
- **Input Validation**: NEVER trust external input
- **Side-Channel**: Constant-time for sensitive data
- **Integer Overflow**: Overflow-checked arithmetic

## Common Pitfalls
1. Hex strings: Validate "0x" prefix, even length
2. Address checksum: EIP-55 for user addresses
3. RLP: Empty strings ≠ empty lists
4. Gas: Include all costs (intrinsic gas)
5. Signatures: Reject high-s values (EIP-2)

**Remember: Correctness first, performance second. Incorrect implementation can lose millions.**