# Guillotine Data Directory

## Overview

The `data/` directory contains external data files required for Guillotine's EVM implementation. This directory serves as a centralized repository for cryptographic parameters, trusted setups, and other reference data needed for Ethereum protocol compliance.

## Directory Structure

```
data/
└── kzg/
    └── trusted_setup.txt    # KZG Ceremony trusted setup parameters (792KB)
```

## KZG Directory (`kzg/`)

### Overview
The KZG directory contains cryptographic parameters for the KZG (Kate-Zaverucha-Goldberg) polynomial commitment scheme, which is essential for Ethereum's EIP-4844 implementation (Proto-Danksharding). This enables efficient verification of blob transactions and data availability proofs.

### Files

#### `trusted_setup.txt`
- **Purpose**: KZG trusted setup parameters from the Ethereum KZG Ceremony
- **Size**: 807,177 bytes (792KB)
- **Format**: Text file with hex-encoded BLS12-381 curve points
- **Lines**: 8,259 total lines
- **Source**: Generated from the official Ethereum KZG Ceremony with 140,000+ contributors

**File Structure:**
```
4096                    # Number of G1 points
65                      # Number of G2 points
<G1_0 hex encoding>     # g^(tau^0) on BLS12-381
<G1_1 hex encoding>     # g^(tau^1) on BLS12-381
...
<G1_4095 hex encoding>  # g^(tau^4095) on BLS12-381
<G2_0 hex encoding>     # G2 generator points
...
<G2_64 hex encoding>    # Final G2 point
```

Each hex-encoded point is 96 characters long (48 bytes) for G1 points and similar for G2 points.

## Usage in Guillotine

### Code Integration
The trusted setup data is consumed by several components:

1. **Embedded Usage** (Primary):
   - File: `src/precompiles/kzg_setup.zig`
   - Method: `@embedFile("../kzg/trusted_setup.txt")` 
   - Usage: Embedded directly into binary at compile time

2. **Runtime Loading** (Alternative):
   - File: `test/evm/precompiles_test.zig`
   - Method: File path reference `"data/kzg/trusted_setup.txt"`
   - Usage: Loaded at runtime for testing scenarios

### Related Components
- `src/crypto/c_kzg.zig`: C library bindings for KZG operations
- `src/precompiles/precompiles.zig`: EIP-4844 point evaluation precompile (0x0A)
- `lib/c-kzg-4844/`: External C KZG library integration

### Initialization
```zig
// Initialize KZG with embedded data (preferred)
try kzg_setup.init();

// Initialize KZG with file path (testing)
try kzg_setup.initFromFile(allocator, "data/kzg/trusted_setup.txt");
```

## Security Considerations

### Trusted Setup Security
- **Trust Model**: Requires only one honest participant from 140,000+ ceremony contributors
- **Verification**: Parameters can be verified against official ceremony outputs
- **Integrity**: File integrity is critical for security; any corruption could compromise KZG proofs

### File Integrity
The trusted setup file should not be modified. To verify integrity:
1. Compare with official ceremony outputs
2. Check file size (exactly 807,177 bytes)
3. Verify line count (exactly 8,259 lines)

## Data Generation and Updates

### Trusted Setup Source
The trusted setup parameters come from the official Ethereum KZG Ceremony:
- **Ceremony Period**: Multiple rounds of contribution
- **Security**: Based on discrete logarithm assumption in BLS12-381
- **Permanence**: These parameters are fixed and should never change

### Updating Data
❌ **WARNING**: Never modify `trusted_setup.txt` manually!

If updates are needed:
1. Verify new parameters come from official Ethereum sources
2. Update both `data/kzg/trusted_setup.txt` and `src/kzg/trusted_setup.txt`
3. Run full test suite: `zig build test-opcodes`
4. Verify EIP-4844 precompile functionality

## Testing

### Validation Tests
The trusted setup is validated through:
- **Unit Tests**: `src/precompiles/kzg_setup.zig` (embedded tests)
- **Integration Tests**: `test/evm/precompiles_test.zig` (file loading tests)
- **EIP-4844 Tests**: Point evaluation precompile verification

### Running Tests
```bash
# Test KZG setup initialization
zig build test-opcodes

# Test EIP-4844 precompile functionality  
zig build && zig build test-opcodes
```

## Maintenance

### File Synchronization
The data directory maintains copies of files also present in `src/`:
- `data/kzg/trusted_setup.txt` ←→ `src/kzg/trusted_setup.txt`
- These should always remain identical

### Version Control
- All files in `data/` are tracked in Git
- Large binary files use Git LFS where appropriate
- No sensitive data should be stored in this directory

## Future Extensions

The data directory is structured to accommodate additional data types:
- **State Test Fixtures**: Reference test cases from Ethereum test suite
- **Benchmark Data**: Performance testing datasets  
- **Configuration Files**: Protocol-specific parameter sets
- **Reference Implementations**: Golden outputs for differential testing

## Dependencies

### Build Requirements
- **c-kzg-4844**: External C library for KZG operations
- **BLS12-381**: Elliptic curve cryptography support
- **File System Access**: Required for runtime loading scenarios

### Runtime Requirements
- No runtime file system access needed when using embedded data
- File system access required only for testing scenarios

---

**Note**: This directory is essential for EIP-4844 compliance. Do not modify files without understanding the cryptographic implications.