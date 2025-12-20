# @tevm/primitives - TypeScript Wrapper

TypeScript wrapper for EVM primitives and standards, providing a clean API for working with Ethereum concepts in TypeScript/JavaScript.

## Installation

```bash
cd /Users/williamcory/primitives/src
bun install
```

## Testing

```bash
bun test
```

## Modules

### Primitives

#### bytecode.ts
Jump destination analysis and bytecode validation for EVM bytecode.

**Functions:**
- `analyzeJumpDestinations(bytecode)` - Find all valid JUMPDEST positions
- `validateBytecode(bytecode)` - Validate bytecode structure
- `isBytecodeBoundary(bytecode, position)` - Check if position is at opcode boundary
- `isValidJumpDest(bytecode, position)` - Check if position is valid JUMPDEST

#### opcode.ts
Complete EVM opcode enumeration with utility functions.

**Functions:**
- `name(opcode)` - Get opcode name
- `isValid(byte)` - Check if byte is valid opcode
- `getGasCost(opcode)` - Get base gas cost
- `isPush(opcode)` - Check if PUSH instruction
- `pushSize(opcode)` - Get bytes pushed by PUSH
- `isDup(opcode)` - Check if DUP instruction
- `isSwap(opcode)` - Check if SWAP instruction
- `isLog(opcode)` - Check if LOG instruction
- `isTerminating(opcode)` - Check if terminates execution
- `isStateModifying(opcode)` - Check if modifies state

#### gas.ts
Gas constants and EIP-1559 fee calculations.

**Constants:**
- `TX_BASE_COST`, `TX_DATA_ZERO_COST`, `TX_DATA_NONZERO_COST`
- `SSTORE_SET_COST`, `SSTORE_RESET_COST`
- `BASE_FEE_INITIAL`, `ELASTICITY_MULTIPLIER`

**Functions:**
- `calculateNextBaseFee(parentBaseFee, parentGasUsed, parentGasLimit)` - EIP-1559 base fee
- `calculatePriorityFee(maxFeePerGas, baseFee, maxPriorityFeePerGas)` - Miner tip
- `calculateEffectiveGasPrice(baseFee, maxFeePerGas, maxPriorityFeePerGas)` - Effective price
- `calculateIntrinsicGas(data)` - Transaction intrinsic gas
- `calculateMemoryGasCost(newSize, currentSize)` - Memory expansion cost

#### hardfork.ts
Ethereum hardfork enumeration and version comparison.

**Enum:** `Hardfork` (FRONTIER, HOMESTEAD, BYZANTIUM, CONSTANTINOPLE, ISTANBUL, BERLIN, LONDON, MERGE, SHANGHAI, CANCUN, PRAGUE, OSAKA, etc.)

**Functions:**
- `isAtLeast(current, target)` - Check if at or after version
- `isBefore(current, target)` - Check if before version
- `equals(a, b)` - Check equality
- `fromString(name)` - Parse from string (case-insensitive)
- `getAllHardforks()` - Get all in chronological order

#### siwe.ts
Sign-In with Ethereum (EIP-4361) message handling.

**Functions:**
- `parseMessage(message)` - Parse SIWE message from string
- `validateMessage(message)` - Validate message structure
- `formatMessage(message)` - Format for signing
- `isExpired(message, now?)` - Check if expired
- `isNotYetValid(message, now?)` - Check if not yet valid

#### logs.ts
Event log structures and utilities.

**Functions:**
- `parseEventLog(log, signature)` - Parse event log with signature
- `filterLogsByTopics(logs, topics)` - Filter logs by topics
- `createEventSignatureHash(signature)` - Create event signature hash (topic0)
- `encodeIndexedParameter(value, type)` - Encode indexed parameter for topic

### Precompiles

#### precompiles/index.ts
All 19 EVM precompile implementations (0x01-0x13).

**Functions:**
- `isPrecompile(address, hardfork)` - Check if address is precompile
- `execute(address, input, gasLimit, hardfork)` - Execute precompile
- Individual precompile functions:
  - `ecrecover()` (0x01) - Recover signer address
  - `sha256()` (0x02) - SHA-256 hash
  - `ripemd160()` (0x03) - RIPEMD-160 hash
  - `identity()` (0x04) - Identity/copy
  - `modexp()` (0x05) - Modular exponentiation
  - `bn254Add()` (0x06) - BN254 curve addition
  - `bn254Mul()` (0x07) - BN254 curve multiplication
  - `bn254Pairing()` (0x08) - BN254 pairing check
  - `blake2f()` (0x09) - Blake2 compression
  - `pointEvaluation()` (0x0a) - KZG point evaluation (EIP-4844)
  - BLS12-381 precompiles (0x0b-0x13):
    - `bls12G1Add()`, `bls12G1Mul()`, `bls12G1Msm()`
    - `bls12G2Add()`, `bls12G2Mul()`, `bls12G2Msm()`
    - `bls12Pairing()`, `bls12MapFpToG1()`, `bls12MapFp2ToG2()`

## Implementation Notes

- **Bytecode module**: Full implementation with jump destination analysis
- **Opcode module**: Complete opcode enumeration with utility functions
- **Gas module**: EIP-1559 fee calculations with correct formulas
- **Hardfork module**: Version comparison with chronological ordering
- **SIWE module**: Basic EIP-4361 message parsing and formatting
- **Logs module**: Simplified log parsing (full ABI decoding would require additional libraries)
- **Precompiles**: Gas cost calculations only; actual cryptographic operations would require native implementations or WASM bindings

## Architecture

This TypeScript wrapper is designed to be used alongside the Zig primitives implementation at `/Users/williamcory/primitives/src/`. The TypeScript modules provide:

1. **Type-safe APIs** - Full TypeScript types and interfaces
2. **Pure TypeScript implementations** - For modules that don't require native crypto
3. **Placeholders for crypto** - Precompiles return correct structure but simplified outputs

For production use with actual cryptographic operations, these modules should be connected to the underlying Zig implementations via FFI, WASM, or native bindings.

## Directory Structure

```
src/
├── package.json              # TypeScript package config
├── tsconfig.json             # TypeScript compiler config
├── README_TS.md              # This file
├── core/                     # Core runtime loaders
│   ├── runtime.ts            # Runtime detection
│   ├── loader-wasm.ts        # WASM loader
│   ├── loader-native.ts      # Native FFI loader
│   ├── memory.ts             # Memory management
│   └── error.ts              # Error handling
├── types/                    # TypeScript type definitions
│   └── index.ts
├── typescript/               # TypeScript implementations
│   ├── utils/
│   │   └── hex.ts            # Hex conversion utilities
│   ├── primitives/
│   │   ├── bytecode.ts       # Bytecode analysis
│   │   ├── bytecode.test.ts
│   │   ├── opcode.ts         # Opcode enumeration
│   │   ├── gas.ts            # Gas calculations
│   │   ├── hardfork.ts       # Hardfork versions
│   │   ├── siwe.ts           # Sign-In with Ethereum
│   │   └── logs.ts           # Event logs
│   └── precompiles/
│       └── index.ts          # All 19 precompiles
├── primitives/               # Zig primitives (colocated)
└── crypto/                   # Zig crypto (colocated)
```

## Testing Approach

This project uses Test-Driven Development (TDD):

1. **Interface** - Define functions that throw "not implemented"
2. **Tests (RED)** - Write tests that fail
3. **Implementation (GREEN)** - Implement to make tests pass
4. **Verify** - Run `bun test` to confirm

Current test coverage:
- Bytecode module: ✅ 16 tests passing
- Additional test files can be added for other modules following the same pattern

## License

See main repository LICENSE
