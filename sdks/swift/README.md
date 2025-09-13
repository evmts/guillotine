# Guillotine EVM Swift SDK

A comprehensive Swift SDK for the Guillotine EVM implementation, providing type-safe Ethereum primitives, EVM execution capabilities, and future compiler integrations.

## Architecture

The SDK is organized into modular components:

- **GuillotineEVM**: Core EVM execution and state management
- **GuillotinePrimitives**: Type-safe Ethereum primitives (`Address`, `U256`, `Bytes`, `Hash`)
- **GuillotineCompilers**: Future Solidity/Vyper compiler interfaces (placeholders)
- **GuillotineFFI**: Low-level FFI bindings to the Zig implementation

## Requirements

- Swift 5.9+
- macOS 12.0+ / iOS 15.0+
- Guillotine shared library built (`libguillotine_ffi.dylib`)

## Building the Shared Library

Before using the Swift SDK, you need to build the Guillotine shared library:

```bash
cd ../..  # Navigate to Guillotine root
zig build
```

This will create `libguillotine_ffi.dylib` in `zig-out/lib/`.

## Installation

### Swift Package Manager

Add this package to your `Package.swift`:

```swift
dependencies: [
    .package(path: "path/to/Guillotine/sdks/swift")
]
```

Then import the modules you need:

```swift
import GuillotineEVM        // For EVM execution
import GuillotinePrimitives // For standalone primitives
```

## Core Types

### Address

Ethereum addresses with comprehensive functionality:

```swift
import GuillotinePrimitives

// Create from hex string (with proper error handling)
let address = try Address(hex: "0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb9")

// String literal support
let address: Address = "0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb9"

// Convenience methods
let zero = Address.zero
let random = Address.random()

// Access raw bytes and hex representation
print(address.hexString)  // "0x742d35cc6634c0532925a3b844bc9e7595f0beb9"
print(address.rawBytes)   // [UInt8] array
```

### U256

256-bit unsigned integers with arithmetic operations:

```swift
// Create from various sources
let value1 = U256(42)
let value2 = try U256(hex: "0x1a2b3c")
let value3: U256 = 1000  // ExpressibleByIntegerLiteral

// Convenience methods for Ether
let oneEther = U256.ether(1.0)
let twoPointFiveEther = U256.ether(2.5)

// Arithmetic with overflow protection
let sum = try value1.adding(value2)
let diff = try value2.subtracting(value1)

// Convert to UInt64 if possible
if let uint64Value = value1.uint64Value {
    print("Fits in UInt64: \(uint64Value)")
}

// Comparison operations
let isGreater = value2 > value1
let areEqual = value1 == value2
```

### Bytes

Type-safe byte array handling:

```swift
let bytecode = Bytes([0x60, 0x42, 0x60, 0x00, 0x52])
let data = try Bytes(hex: "0x6042600052") 
```

## EVM Execution

### Basic EVM Usage

```swift
import GuillotineEVM

// Initialize EVM (done automatically)
GuillotineEVM.initialize()

// Create block context with enhanced BlockInfo
let coinbase = Address.zero
let blockInfo = BlockInfo(
    number: 1,
    timestamp: 1000,
    gasLimit: 30_000_000,
    coinbase: coinbase,
    baseFee: 1_000_000_000,
    chainId: 1,
    difficulty: 0,  // Optional, defaults to 0
    prevRandao: Data(repeating: 0, count: 32)  // Optional
)

// Create EVM instance
let evm = try GuillotineEVM(blockInfo: blockInfo)

// Set up accounts with balances
let account: Address = "0x0000000000000000000000000000000000000010"
let balance = U256.ether(1.0)  // 1 ETH
try evm.setBalance(address: account, balance: balance)

// Deploy contract bytecode
let contractAddress: Address = "0x0000000000000000000000000000000000000020"
let bytecode = Data([
    0x60, 0x2a,  // PUSH1 42
    0x60, 0x00,  // PUSH1 0
    0x52,        // MSTORE
    0x60, 0x20,  // PUSH1 32
    0x60, 0x00,  // PUSH1 0
    0xf3         // RETURN
])
try evm.setCode(address: contractAddress, code: bytecode)
```

### Call Execution

```swift
// Execute calls with comprehensive parameters
let params = CallParameters(
    caller: account,
    to: contractAddress,
    value: .zero,  // U256.zero
    input: Data(),
    gas: 100_000,
    callType: .call,
    salt: nil  // For CREATE2 calls
)

let result = try evm.call(params)
print("Success: \(result.success)")
print("Gas left: \(result.gasLeft)")
print("Output: \(result.output.map { String(format: "%02x", $0) }.joined())")
if let error = result.error {
    print("Error: \(error)")
}
```

### Call Types

All EVM call types are supported:

```swift
// Regular call
CallParameters(callType: .call)

// Delegate call
CallParameters(callType: .delegateCall)

// Static call (read-only)
CallParameters(callType: .staticCall) 

// Contract creation
CallParameters(callType: .create)

// CREATE2 with salt
CallParameters(
    callType: .create2,
    salt: U256(0x1234567890abcdef)
)
```

### State Simulation

Simulate calls without committing state changes:

```swift
let result = try evm.simulate(params)
// EVM state remains unchanged regardless of the call result
```

## Advanced Examples

### Multiple Account Setup

```swift
let accounts = [
    ("0x0000000000000000000000000000000000000010", U256.ether(1.0)),
    ("0x0000000000000000000000000000000000000020", U256.ether(0.5)),
    ("0x0000000000000000000000000000000000000030", U256.ether(0.1))
]

for (addressHex, balance) in accounts {
    let address: Address = addressHex
    try evm.setBalance(address: address, balance: balance)
}
```

### Contract with Constructor Data

```swift
// Deploy contract with initialization
let constructorData = Data([/* constructor parameters */])
let deployParams = CallParameters(
    caller: deployer,
    to: Address.zero,  // CREATE call
    value: .zero,
    input: bytecode + constructorData,
    gas: 1_000_000,
    callType: .create
)

let deployResult = try evm.call(deployParams)
if deployResult.success {
    let contractAddress = try Address(Array(deployResult.output.suffix(20)))
    print("Contract deployed at: \(contractAddress)")
}
```

## Error Handling

The SDK provides comprehensive error handling:

### EVM Errors

```swift
do {
    let result = try evm.call(params)
} catch EVMError.initializationFailed(let message) {
    print("EVM initialization failed: \(message)")
} catch EVMError.callFailed(let message) {
    print("Call execution failed: \(message)")
} catch EVMError.operationFailed(let message) {
    print("Operation failed: \(message)")
} catch EVMError.simulationFailed(let message) {
    print("Simulation failed: \(message)")
}
```

### Primitives Errors

```swift
do {
    let address = try Address(hex: "0xinvalidhex")
} catch PrimitivesError.invalidHexString(let hex) {
    print("Invalid hex: \(hex)")
} catch PrimitivesError.invalidLength(let expected, let actual) {
    print("Wrong length: expected \(expected), got \(actual)")
}

do {
    let result = try value1.adding(value2)
} catch PrimitivesError.overflow {
    print("Arithmetic overflow occurred")
}
```

## Testing

Run the complete test suite:

```bash
swift test
```

Individual test targets:

```bash
swift test --filter GuillotineEVMTests
swift test --filter GuillotinePrimitivesTests
```

Make sure the Guillotine shared library is built before running tests.

## Thread Safety

All types are designed to be `Sendable` and thread-safe:

- `Address`, `U256`, `Bytes` are immutable value types
- `GuillotineEVM` manages its own thread safety internally
- Error types conform to `Sendable`

## Future Features

### Compiler Integration (Coming Soon)

```swift
import GuillotineCompilers

// Solidity compilation (placeholder)
let solidity = """
pragma solidity ^0.8.0;
contract HelloWorld {
    function greet() public pure returns (string memory) {
        return "Hello, World!";
    }
}
"""

// This will be implemented in future versions
let compiled = try SolidityCompiler.compile(solidity)
```

## Performance Considerations

- Primitive types use efficient internal representations
- Memory is managed automatically with proper cleanup
- FFI calls are minimized through batching where possible
- State modifications are atomic through the underlying Zig implementation

## Important Notes

1. **Precompiled Contracts**: Addresses 0x01-0x09 are reserved for precompiled contracts
2. **Memory Management**: EVM instances and results are automatically cleaned up
3. **Initialization**: Global initialization is handled automatically by `GuillotineEVM`
4. **Error Recovery**: Always use proper error handling for all EVM operations
5. **Gas Calculation**: Gas usage is accurately tracked by the underlying Zig implementation

## Codable Support

All primitive types support `Codable` for easy serialization:

```swift
let address: Address = "0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb9"
let value = U256.ether(2.5)

// Encode to JSON
let encoder = JSONEncoder()
let addressData = try encoder.encode(address)
let valueData = try encoder.encode(value)

// Decode from JSON
let decoder = JSONDecoder()
let decodedAddress = try decoder.decode(Address.self, from: addressData)
let decodedValue = try decoder.decode(U256.self, from: valueData)
```

## License

See the main Guillotine repository for license information.