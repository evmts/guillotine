# CLAUDE.md - KZG Module

## MISSION CRITICAL: KZG Polynomial Commitments for EIP-4844
**KZG errors enable invalid blob data or consensus failures.** Perfect specification compliance mandatory.

## KZG Commitment Scheme (EIP-4844)
- **Polynomial Commitments**: Cryptographic commitments to blob data polynomials
- **Point Evaluation Proofs**: Verify polynomial evaluations without revealing data
- **BLS12-381 Curve**: Specific elliptic curve for KZG operations
- **Trusted Setup**: Pre-computed parameters from KZG ceremony

## Key Responsibilities
- **Blob Commitment**: Generate KZG commitments for blob data
- **Proof Verification**: Validate KZG proofs for blob transactions
- **Polynomial Operations**: Evaluate polynomials at specific points
- **Curve Operations**: BLS12-381 elliptic curve arithmetic
- **Field Arithmetic**: Operations in BLS12-381 scalar field

## Critical KZG Operations
```zig
// Blob to KZG commitment
pub fn blob_to_kzg_commitment(blob: *const Blob) !KzgCommitment {
    const polynomial = blob_to_polynomial(blob);
    return compute_kzg_commitment(polynomial);
}

// KZG proof computation
pub fn compute_kzg_proof(blob: *const Blob, z: BlsScalar) !struct { KzgProof, BlsScalar } {
    const polynomial = blob_to_polynomial(blob);
    const y = evaluate_polynomial(polynomial, z);
    const proof = compute_quotient_polynomial_proof(polynomial, z, y);
    return .{ proof, y };
}
```

## BLS12-381 Operations
- **G1 Group**: Base group for commitments/proofs
- **G2 Group**: Extended group for trusted setup
- **Pairing Operations**: Bilinear pairing for proof verification
- **Field Arithmetic**: Modular operations in prime fields
- **Point Validation**: Ensure valid curve elements

## Polynomial Operations
```zig
// Convert blob to polynomial coefficients
fn blob_to_polynomial(blob: *const Blob) [FIELD_ELEMENTS_PER_BLOB]BlsScalar {
    var coeffs: [FIELD_ELEMENTS_PER_BLOB]BlsScalar = undefined;
    for (blob.data, 0..) |chunk, i| {
        coeffs[i] = bytes_to_bls_field(chunk);
    }
    return coeffs;
}

// Horner's method evaluation
fn evaluate_polynomial(coeffs: []const BlsScalar, x: BlsScalar) BlsScalar {
    var result = BlsScalar.zero();
    for (coeffs) |coeff| {
        result = result.mul(x).add(coeff);
    }
    return result;
}
```

## Critical Safety
- Validate BLS12-381 points on curve and correct subgroup
- Ensure scalars within valid field range
- Constant-time operations (prevent side-channel attacks)
- Verify trusted setup authenticity
- Handle point-at-infinity correctly

## Performance & Security
- **Optimization**: Multi-scalar multiplication, precomputed tables, parallel operations
- **Security**: Constant-time ops, point/field validation, setup authenticity, rigorous proof verification
- **Memory**: Efficient allocation for large polynomial operations

## Testing & Errors
- **Testing**: Official KZG test vectors, curve operations, polynomial properties, fuzzing, benchmarking
- **Errors**: InvalidBlob/Commitment/Proof/Point/Scalar, TrustedSetupError, PolynomialError

```zig
pub fn verify_kzg_proof(commitment: *const KzgCommitment, z: BlsScalar, y: BlsScalar, proof: *const KzgProof) KzgError!bool {
    if (!commitment.is_valid() or !proof.is_valid()) return KzgError.InvalidPoint;
    if (!z.is_valid() or !y.is_valid()) return KzgError.InvalidScalar;
    return verify_pairing_equation(commitment, z, y, proof);
}
```

## Emergency Procedures
- Invalid proof detection/handling
- Setup parameter corruption recovery
- Cryptographic failure handling
- Memory exhaustion for large operations
- Consensus divergence detection

**KZG commitments are cryptographic security primitives. Implementation errors compromise blob transaction security.**