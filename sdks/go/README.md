# Guillotine Go Bindings (WIP)

Go bindings and design notes for integrating the Zig EVM.

## Overview

This directory documents the intended Go bindings. The reference implementation lives in a separate repository; examples here illustrate the intended API shape and memory‑safety constraints when calling into the Zig/C layer.

## Components

### Packages (planned)

- `primitives` — Address, U256, Hash, Bytes
- `evm` — EVM execution (C API)
- `stack` — Stack helpers
- `errors` — Error types

### Support Files

- `cgo.go` — C API bridge and lifetime management
- `go.mod` — Module definition and versions
- `DESIGN.md` — Design rationale and FFI invariants

## Features

### High-Performance EVM Execution

- **Native performance** - Direct C API integration with minimal overhead
- **Memory safety** - Automatic resource management with finalizers
- **Concurrency safe** - All operations protected with appropriate locks
- **Error handling** - Comprehensive Go error types for all failure modes

### Ethereum Primitives

- **Address handling** - 20-byte Ethereum addresses with validation
- **U256 arithmetic** - 256-bit unsigned integer operations
- **Hash operations** - 32-byte Keccak-256 hash handling
- **Dynamic bytes** - Efficient byte array management

### EVM State Management

- **Account balances** - Get/set account ETH balances
- **Contract code** - Deploy and retrieve contract bytecode
- **Storage operations** - Read/write contract storage slots
- **Execution context** - Full control over execution parameters

## Usage Examples

### Basic EVM Execution

```go
package main

import (
    "fmt"
    evm "github.com/evmts/guillotine/bindings/go/evm"
    primitives "github.com/evmts/guillotine/bindings/go/primitives"
)

func main() {
    // Create new EVM instance
    vm, err := evm.New()
    if err != nil {
        panic(err)
    }
    defer vm.Close()
    
    // Prepare execution parameters
    bytecode, _ := primitives.BytesFromHex("0x6001600101")  // PUSH1 1, PUSH1 1, ADD
    params := evm.ExecutionParams{
        Bytecode: bytecode,
        Caller:   primitives.ZeroAddress(),
        To:       primitives.ZeroAddress(),
        Value:    primitives.ZeroU256(),
        Input:    primitives.EmptyBytes(),
        GasLimit: 100000,
    }
    
    // Execute bytecode
    result, err := vm.Execute(params)
    if err != nil {
        panic(err)
    }
    
    fmt.Printf("Success: %v\n", result.Success())
    fmt.Printf("Gas used: %d\n", result.GasUsed())
    fmt.Printf("Return data: %s\n", result.ReturnData().Hex())
}
```

### Account State Management

```go
// Set up account state
address := primitives.MustAddressFromHex("0x742d35Cc6635C0532925a3b8D96fdc0c52b81ea5")
balance := primitives.MustU256FromDecimal("1000000000000000000") // 1 ETH
code, _ := primitives.BytesFromHex("0x608060405234801561...")

err = vm.SetBalance(address, balance)
if err != nil {
    panic(err)
}

err = vm.SetCode(address, code)
if err != nil {
    panic(err)
}

// Read account state
currentBalance, err := vm.GetBalance(address)
if err != nil {
    panic(err)
}

contractCode, err := vm.GetCode(address)
if err != nil {
    panic(err)
}
```

### Storage Operations

```go
// Set storage slot
address := primitives.MustAddressFromHex("0x742d35Cc6635C0532925a3b8D96fdc0c52b81ea5")
key := primitives.MustU256FromHex("0x0000000000000000000000000000000000000000000000000000000000000001")
value := primitives.MustU256FromDecimal("42")

err = vm.SetStorage(address, key, value)
if err != nil {
    panic(err)
}

// Read storage slot
storedValue, err := vm.GetStorage(address, key)
if err != nil {
    panic(err)
}

fmt.Printf("Stored value: %s\n", storedValue.Decimal())
```

### Working with Primitives

```go
// Address operations
addr1 := primitives.ZeroAddress()
addr2, err := primitives.AddressFromHex("0x742d35Cc6635C0532925a3b8D96fdc0c52b81ea5")
if err != nil {
    panic(err)
}

// U256 operations
big1 := primitives.ZeroU256()
big2, err := primitives.U256FromDecimal("123456789")
if err != nil {
    panic(err)
}

result := big1.Add(big2)
fmt.Printf("Result: %s\n", result.Hex())

// Bytes operations
data1 := primitives.EmptyBytes()
data2, err := primitives.BytesFromHex("0xdeadbeef")
if err != nil {
    panic(err)
}

combined := data1.Append(data2)
```

## API Reference (preview)

### EVM Operations

- `New() (*EVM, error)` - Create new EVM instance
- `Close() error` - Close EVM and release resources
- `Execute(params ExecutionParams) (*ExecutionResult, error)` - Execute bytecode

### Account Management

- `SetBalance(address Address, balance U256) error` - Set account balance
- `GetBalance(address Address) (U256, error)` - Get account balance
- `SetCode(address Address, code Bytes) error` - Set contract code
- `GetCode(address Address) (Bytes, error)` - Get contract code

### Storage Operations

- `SetStorage(address Address, key U256, value U256) error` - Set storage slot
- `GetStorage(address Address, key U256) (U256, error)` - Get storage slot

### Primitive Types

#### Address
- `ZeroAddress() Address` - Create zero address
- `AddressFromHex(hex string) (Address, error)` - Parse from hex string
- `(a Address) Hex() string` - Convert to hex string
- `(a Address) Array() [20]byte` - Get raw byte array

#### U256
- `ZeroU256() U256` - Create zero value
- `U256FromDecimal(dec string) (U256, error)` - Parse from decimal
- `U256FromHex(hex string) (U256, error)` - Parse from hex
- `(u U256) Add(other U256) U256` - Addition
- `(u U256) Hex() string` - Convert to hex string

#### Bytes
- `EmptyBytes() Bytes` - Create empty bytes
- `BytesFromHex(hex string) (Bytes, error)` - Parse from hex
- `(b Bytes) Append(other Bytes) Bytes` - Concatenate bytes
- `(b Bytes) Data() []byte` - Get raw data

## Important Considerations

### Memory Management

- **Automatic cleanup** - EVM instances use finalizers for safe cleanup
- **Explicit cleanup** - Always call `Close()` for deterministic resource release
- **C memory handling** - Internal C memory is automatically managed
- **Go memory safety** - All operations are memory-safe from Go perspective

### Error Handling

- **Go error conventions** - All operations return proper Go errors
- **Typed errors** - Specific error types for different failure conditions
- **Error propagation** - C API errors are properly translated to Go errors
- **Validation** - Input validation prevents common usage errors

### Performance Considerations

- **Zero-copy operations** - Minimal data copying between Go and C
- **Concurrent access** - Thread-safe operations with reader-writer locks
- **Resource pooling** - EVM instances can be reused for multiple executions
- **Memory efficiency** - Optimized memory usage for large-scale applications

### Platform Support

- **Cross-platform** - Works on Linux, macOS, and Windows
- **CGO requirements** - Requires CGO and C compiler for building
- **Static linking** - Can be statically linked with Guillotine library
- **Dynamic linking** - Supports dynamic linking for smaller binaries

## Testing

The module includes comprehensive tests covering:

- **Unit tests** - Test individual components and functions
- **Integration tests** - Test complete EVM execution scenarios
- **Benchmark tests** - Performance benchmarks against reference implementations
- **Property tests** - Randomized testing for edge cases

```bash
# Run all tests
go test ./...

# Run with race detection
go test -race ./...

# Run benchmarks
go test -bench=. ./...
```

## Development Workflow

1. **Import** - Add module to your Go project dependencies
2. **Initialize** - Create EVM instance with proper error handling
3. **Configure** - Set up accounts, balances, and contract code
4. **Execute** - Run bytecode with appropriate gas limits
5. **Inspect** - Examine execution results and state changes
6. **Cleanup** - Properly close EVM instances to free resources

The Go bindings provide a production-ready interface to Guillotine EVM, suitable for building Ethereum-compatible applications, testing frameworks, and blockchain infrastructure in Go.
