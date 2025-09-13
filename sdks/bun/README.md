# Guillotine Bun SDK

> Experimental/PoC: This SDK is a vibecoded proof-of-concept. APIs are unstable and may change. We're looking for early users to try it and tell us what APIs you want — please open an issue or ping us on Telegram.

📚 **[View Full Documentation](https://guillotine.dev/sdks/bun)**

## Status

- Maturity: Experimental proof‑of‑concept
- API stability: Unstable; breaking changes expected
- Feedback: https://github.com/evmts/Guillotine/issues or Telegram https://t.me/+ANThR9bHDLAwMjUx

High-performance EVM implementation for Bun using FFI bindings to the Guillotine Zig EVM.

## Installation

```bash
bun add @guillotine/bun
```

## Building from Source

### Prerequisites

- [Zig](https://ziglang.org/) compiler (version 0.14.1 or later)
- [Bun](https://bun.sh/) runtime

### Build Steps

1. Build the Guillotine shared library from the project root:
   ```bash
   cd ../..  # Navigate to guillotine project root
   zig build shared -Doptimize=ReleaseFast
   ```

2. Build the TypeScript bindings:
   ```bash
   cd sdks/bun
   bun build src/index.ts --outdir dist --target bun
   ```

3. Or use the provided build script:
   ```bash
   ./build.sh
   ```

## Usage

```typescript
import { createEVM, CallType, hexToBytes, bytesToHex } from "@guillotine/bun";

// Create EVM instance
const evm = createEVM({
  number: 1n,
  timestamp: BigInt(Date.now()),
  gasLimit: 30_000_000n,
  coinbase: "0x0000000000000000000000000000000000000000",
  baseFee: 1_000_000_000n,
  chainId: 1n,
});

// Set up accounts
evm.setBalance("0x1234567890123456789012345678901234567890", 10n ** 18n);

// Deploy contract
const deployResult = evm.call({
  caller: "0x1234567890123456789012345678901234567890",
  to: "0x0000000000000000000000000000000000000000",
  value: 0n,
  input: contractBytecode,
  gas: 1_000_000n,
  callType: CallType.CREATE,
});

// Execute contract call
const result = evm.call({
  caller: "0x1234567890123456789012345678901234567890",
  to: contractAddress,
  value: 0n,
  input: calldata,
  gas: 100_000n,
  callType: CallType.CALL,
});

// Clean up
evm.destroy();
```

## API Reference

### `createEVM(blockInfo: BlockInfo): GuillotineEVM`

Creates a new EVM instance with the specified block configuration.

### `GuillotineEVM`

The main EVM instance class that provides methods for interacting with the EVM state and executing transactions.

#### Methods

- `setBalance(address: string, balance: bigint): void`
  - Sets the balance of an account
  - `address`: Ethereum address (with or without '0x' prefix)
  - `balance`: Balance in wei as a bigint

- `setCode(address: string, code: Uint8Array): void`
  - Sets the bytecode for a contract account
  - `address`: Contract address
  - `code`: Contract bytecode as Uint8Array

- `call(params: CallParams): EvmResult`
  - Executes an EVM call/transaction and commits state changes
  - `params`: Call parameters (see CallParams interface)
  - Returns: Execution result with gas usage and output

- `simulate(params: CallParams): EvmResult`
  - Simulates an EVM call without committing state changes
  - Same parameters and return as `call()` but state remains unchanged
  - Useful for gas estimation and testing

- `destroy(): void`
  - Cleans up the EVM instance and releases native resources
  - **Important**: Always call this when done to prevent memory leaks

### Types

#### `BlockInfo`
```typescript
interface BlockInfo {
  number: bigint;
  timestamp: bigint;
  gasLimit: bigint;
  coinbase: string;
  baseFee: bigint;
  chainId: bigint;
  difficulty?: bigint;
  prevRandao?: Uint8Array;
}
```

#### `CallParams`
```typescript
interface CallParams {
  caller: string;      // Address of the account making the call
  to: string;          // Target address (use zero address for CREATE)
  value: bigint;       // Wei value to transfer
  input: Uint8Array;   // Call data (constructor args for CREATE/CREATE2)
  gas: bigint;         // Gas limit for the call
  callType: CallType;  // Type of call (CALL, DELEGATECALL, etc.)
  salt?: bigint;       // Salt for CREATE2 (required for CREATE2 calls)
}
```

#### `CallType`
```typescript
enum CallType {
  CALL = 0,         // Standard call - can modify state, transfer value
  DELEGATECALL = 1, // Delegate call - executes in caller's context
  STATICCALL = 2,   // Static call - cannot modify state, no value transfer
  CREATE = 3,       // Deploy new contract
  CREATE2 = 4,      // Deploy with deterministic address
}
```

#### `EvmResult`
```typescript
interface EvmResult {
  success: boolean;     // Whether the execution succeeded
  gasLeft: bigint;      // Remaining gas after execution
  output: Uint8Array;   // Return data (empty if reverted without data)
  error?: string;       // Error message if execution failed
}
```

### Utility Functions

- `hexToBytes(hex: string): Uint8Array`
  - Converts hex string to Uint8Array
  - Handles both "0x" prefixed and plain hex strings
  - Example: `hexToBytes("0x1234")` → `Uint8Array([0x12, 0x34])`

- `bytesToHex(bytes: Uint8Array): string`
  - Converts Uint8Array to hex string with "0x" prefix
  - Example: `bytesToHex(Uint8Array([0x12, 0x34]))` → `"0x1234"`

## Testing

Run the test suite:

```bash
bun test
```

## Example

See `example.ts` for a complete example of deploying and interacting with a smart contract.

```bash
bun run example.ts
```

## Performance

The Guillotine EVM is optimized for performance:
- Zero-copy FFI calls where possible
- Efficient memory management
- Native Zig performance for EVM execution
- Minimal JavaScript overhead

## Benchmarks

Bun SDK timings on local machine using official fixtures:

- erc20-mint: 0.60 ms (gasUsed: 65,703, outputLen: 2,317)
- ten-thousand-hashes: 0.23 ms (gasUsed: 21,058, outputLen: 151)
- snailtracer: 0.80 ms (gasUsed: 24,928, outputLen: 17,608)

Notes:
- Bytecode and calldata are loaded from `src/_test_utils/fixtures/<case>/{bytecode,calldata}.txt`.
- Gas limits used: erc20-mint: `5_000_000`, ten-thousand-hashes: `10_000_000`, snailtracer: `10_000_000`.
- Each case executes once; results are indicative and will vary by hardware and OS.

Reproduce locally:

### Run Benchmarks

1) First ensure the shared library is built:
   ```bash
   # From the Guillotine project root
   zig build shared -Doptimize=ReleaseFast
   ```

2) Save this benchmark script as `bench.ts` in the `sdks/bun` directory:

   ```typescript
   import { createEVM, CallType, hexToBytes } from "./src/index";
   import { readFileSync } from "fs";
   import { join } from "path";

   function loadHexFile(filepath: string): Uint8Array {
     const content = readFileSync(filepath, "utf8").trim();
     return hexToBytes(content.replace(/^0x/, ""));
   }

   function benchmark(name: string, bytecodePath: string, calldataPath: string, gasLimit: bigint) {
     const evm = createEVM({
       number: 1n,
       timestamp: BigInt(Math.floor(Date.now() / 1000)),
       gasLimit: 30_000_000n,
       coinbase: "0x0000000000000000000000000000000000000000",
       baseFee: 1_000_000_000n,
       chainId: 1n,
       difficulty: 0n,
     });

     try {
       const caller = "0x1234567890123456789012345678901234567890";
       const contractAddress = "0x2222222222222222222222222222222222222222";
       
       // Set up accounts and contract
       evm.setBalance(caller, 10n ** 18n);
       evm.setCode(contractAddress, loadHexFile(bytecodePath));
       const calldata = loadHexFile(calldataPath);
       
       // Execute and time
       const startTime = performance.now();
       const result = evm.call({
         caller,
         to: contractAddress,
         value: 0n,
         input: calldata,
         gas: gasLimit,
         callType: CallType.CALL,
       });
       const endTime = performance.now();
       
       const executionTime = (endTime - startTime).toFixed(2);
       const gasUsed = Number(gasLimit - result.gasLeft);
       
       console.log(`[${name}] ${executionTime} ms, success=${result.success}, gasUsed=${gasUsed}, outputLen=${result.output.length}`);
     } finally {
       evm.destroy();
     }
   }

   // Run benchmarks (adjust paths as needed for your setup)
   const fixturesPath = "../../src/_test_utils/fixtures";
   benchmark("erc20-mint", join(fixturesPath, "erc20-mint/bytecode.txt"), join(fixturesPath, "erc20-mint/calldata.txt"), 5_000_000n);
   benchmark("ten-thousand-hashes", join(fixturesPath, "ten-thousand-hashes/bytecode.txt"), join(fixturesPath, "ten-thousand-hashes/calldata.txt"), 10_000_000n);
   benchmark("snailtracer", join(fixturesPath, "snailtracer/bytecode.txt"), join(fixturesPath, "snailtracer/calldata.txt"), 10_000_000n);
   ```

3) Run the benchmark:
   ```bash
   bun run bench.ts
   ```

## Error Handling

The SDK provides detailed error information when operations fail:

```typescript
const result = evm.call(params);

if (!result.success) {
  console.log("Call failed:", result.error);
  console.log("Gas used:", params.gas - result.gasLeft);
  console.log("Revert data:", bytesToHex(result.output));
}
```

### Common Error Scenarios

- **Out of Gas**: `result.success = false`, `result.gasLeft = 0n`
- **Revert**: `result.success = false`, `result.output` contains revert data
- **Invalid Jump**: `result.success = false`, execution stops at invalid jump destination
- **Stack Underflow/Overflow**: `result.success = false`, stack operation failed
- **Invalid Opcode**: `result.success = false`, encountered undefined opcode

### Best Practices

1. **Always destroy EVM instances**:
   ```typescript
   const evm = createEVM(blockInfo);
   try {
     // Use EVM
   } finally {
     evm.destroy(); // Prevent memory leaks
   }
   ```

2. **Handle errors gracefully**:
   ```typescript
   try {
     evm.setBalance(address, balance);
   } catch (error) {
     console.error("Failed to set balance:", error.message);
   }
   ```

3. **Use appropriate gas limits**:
   ```typescript
   // Too low: execution will fail
   // Too high: wastes gas but doesn't affect correctness
   const result = evm.call({ ...params, gas: 1_000_000n });
   ```

## License

MIT
