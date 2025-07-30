# GuillotineEVM Go Bindings

Go bindings for the Guillotine EVM, providing a high-performance, thread-safe interface to the Ethereum Virtual Machine.

## Features

- **Complete EVM Implementation**: Full Ethereum Virtual Machine with gas accounting, state management, and precompiles
- **Go-First Design**: Leverages Go's goroutines, channels, and error handling patterns
- **High Performance**: Direct CGO interop with the native Zig implementation
- **Thread Safe**: Safe for concurrent use across multiple goroutines
- **Memory Efficient**: Automatic garbage collection with proper resource cleanup
- **Comprehensive Testing**: Full test suite with Go's testing framework

## Installation

```bash
go get github.com/evmts/guillotine/bindings/go
```

## Quick Start

```go
package main

import (
    "fmt"
    "log"

    "github.com/evmts/guillotine/bindings/go/evm"
    "github.com/evmts/guillotine/bindings/go/primitives"
)

func main() {
    // Create EVM instance
    vm, err := evm.New()
    if err != nil {
        log.Fatal(err)
    }
    defer vm.Close()

    // Execute bytecode
    bytecode := primitives.NewBytes([]byte{0x60, 0x42}) // PUSH1 0x42
    result, err := vm.Execute(evm.ExecutionParams{
        Bytecode: bytecode,
        GasLimit: 1000000,
    })
    if err != nil {
        log.Fatal(err)
    }

    fmt.Printf("Execution successful: %t\n", result.IsSuccess())
    fmt.Printf("Gas used: %d\n", result.GasUsed())
}
```

## Core Types

### Primitives

- **`Address`**: 20-byte Ethereum address with hex string support
- **`U256`**: 256-bit unsigned integer with arithmetic operations
- **`Hash`**: 32-byte hash value for blockchain data
- **`Bytes`**: Variable-length byte arrays with hex encoding

### EVM Execution

- **`EVM`**: Main execution engine with goroutine safety
- **`ExecutionResult`**: Comprehensive execution results with gas usage and return data
- **`GuillotineError`**: Typed error handling for all EVM operations

## Examples

### Working with Addresses

```go
// Create from hex string
addr, err := primitives.AddressFromHex("0x1234567890123456789012345678901234567890")
if err != nil {
    log.Fatal(err)
}

// Create zero address
zero := primitives.ZeroAddress()

// Convert to/from bytes
bytes := addr.Bytes()
fromBytes, err := primitives.AddressFromBytes(bytes)
if err != nil {
    log.Fatal(err)
}
```

### Working with U256

```go
// Create from uint64
value := primitives.NewU256(12345)

// Create from hex
bigValue, err := primitives.U256FromHex("0x1fffffffffffffffffffffffffffffffffffff")
if err != nil {
    log.Fatal(err)
}

// Arithmetic operations
sum, err := value.Add(primitives.NewU256(100))
if err != nil {
    log.Fatal(err)
}

difference, err := bigValue.Sub(primitives.NewU256(1))
if err != nil {
    log.Fatal(err)
}
```

### EVM State Management

```go
vm, err := evm.New()
if err != nil {
    log.Fatal(err)
}
defer vm.Close()

// Set account balance
addr, _ := primitives.AddressFromHex("0x1234567890123456789012345678901234567890")
err = vm.SetBalance(addr, primitives.NewU256(1000))
if err != nil {
    log.Fatal(err)
}

// Deploy contract code
contractCode := primitives.NewBytes([]byte{0x60, 0x80, 0x60, 0x40, 0x52})
err = vm.SetCode(addr, contractCode)
if err != nil {
    log.Fatal(err)
}

// Execute with parameters
result, err := vm.Execute(evm.ExecutionParams{
    Bytecode: contractCode,
    Caller:   primitives.ZeroAddress(),
    To:       addr,
    Value:    primitives.NewU256(100),
    Input:    primitives.NewBytes([]byte{0x01, 0x02, 0x03}),
    GasLimit: 1000000,
})
if err != nil {
    log.Fatal(err)
}
```

## Architecture

The Go bindings follow a three-layer architecture:

1. **CGO Layer**: C interop that bridges to the native Zig implementation
2. **Primitives Package**: Core Ethereum types with Go-native APIs
3. **EVM Package**: High-level EVM execution engine with goroutine safety

### Thread Safety

All types are designed for safe concurrent use. The EVM type uses internal synchronization to ensure thread safety across multiple goroutines.

### Memory Management

The Go bindings use Go's garbage collector for memory management. Native Zig resources are automatically cleaned up when Go objects are finalized.

## Testing

Run the test suite:

```bash
go test ./...
```

## Error Handling

The Go bindings use Go's standard error handling patterns:

```go
result, err := vm.Execute(params)
if err != nil {
    var guillotineErr *evm.GuillotineError
    if errors.As(err, &guillotineErr) {
        switch guillotineErr.Type {
        case evm.ErrorExecutionFailed:
            // Handle execution failure
        case evm.ErrorInvalidBytecode:
            // Handle invalid bytecode
        default:
            // Handle other guillotine errors
        }
    } else {
        // Handle other errors
    }
}
```

## Performance

The Go bindings provide minimal overhead over the native Zig implementation. All performance-critical operations are handled by the native code with efficient CGO integration.

## License

Same as the main Guillotine project.