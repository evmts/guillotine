# Guillotine Go Bindings

Go bindings for the Guillotine EVM implementation, providing a clean and idiomatic Go interface to the high-performance Zig EVM.

## Overview

The Go bindings provide a production-ready interface to Guillotine EVM using native Go types and patterns. The API has been designed to be minimal, clean, and idiomatic to Go conventions.

## Key Design Decisions

### Native Go Types
- Uses `[]byte` for byte arrays (no custom Bytes wrapper)
- Uses `*big.Int` for 256-bit integers (standard Go practice)
- Uses `[20]byte` for addresses via the `primitives.Address` type
- No unnecessary wrapper types around native Go types

### Single Unified Call Interface
Instead of multiple methods (`ExecuteCall`, `ExecuteStaticCall`, etc.), there is a single `Call` method that accepts different parameter types implementing the `CallParams` interface:

```go
// All call types use the same method
result, err := vm.Call(params)
```

## Installation

```bash
go get github.com/evmts/guillotine/sdks/go
```

## Usage Examples

### Basic EVM Execution

```go
package main

import (
    "fmt"
    "math/big"
    
    "github.com/evmts/guillotine/sdks/go/evm"
    "github.com/evmts/guillotine/sdks/go/primitives"
)

func main() {
    // Create new EVM instance
    vm, err := evm.New()
    if err != nil {
        panic(err)
    }
    defer vm.Destroy()
    
    // Execute a simple CALL
    caller, _ := primitives.AddressFromHex("0x742d35Cc6634C0532925a3b8266C95839487a15")
    to, _ := primitives.AddressFromHex("0x8e729aeFa69c91B3266C95839d866fc48fB1ea15")
    
    result, err := vm.Call(evm.Call{
        Caller: caller,
        To:     to,
        Value:  big.NewInt(100),
        Input:  []byte{0x01, 0x02, 0x03},
        Gas:    1000000,
    })
    
    if err != nil {
        panic(err)
    }
    
    fmt.Printf("Success: %v\n", result.Success)
    fmt.Printf("Gas left: %d\n", result.GasLeft)
    fmt.Printf("Output: %x\n", result.Output)
}
```

### Contract Creation

```go
// Deploy a new contract using CREATE
initCode := []byte{0x60, 0x80, 0x60, 0x40, 0x52} // Contract initialization code

result, err := vm.Call(evm.Create{
    Caller:   caller,
    Value:    big.NewInt(0),
    InitCode: initCode,
    Gas:      2000000,
})

if err != nil {
    panic(err)
}

// Or use CREATE2 for deterministic addresses
salt := big.NewInt(12345)

result, err = vm.Call(evm.Create2{
    Caller:   caller,
    Value:    big.NewInt(0),
    InitCode: initCode,
    Salt:     salt,
    Gas:      2000000,
})
```

### Different Call Types

```go
// STATICCALL - read-only execution
result, err := vm.Call(evm.Staticcall{
    Caller: caller,
    To:     contractAddress,
    Input:  []byte{0x70, 0xa0, 0x82, 0x31}, // balanceOf selector
    Gas:    50000,
})

// DELEGATECALL - execute in caller's context
result, err = vm.Call(evm.Delegatecall{
    Caller: caller,
    To:     implementationAddress,
    Input:  calldata,
    Gas:    100000,
})

// CALLCODE - legacy, similar to delegatecall
result, err = vm.Call(evm.Callcode{
    Caller: caller,
    To:     libraryAddress,
    Value:  big.NewInt(0),
    Input:  calldata,
    Gas:    100000,
})
```

### State Management

```go
// Set account balance
address, _ := primitives.AddressFromHex("0x742d35Cc6635C0532925a3b8266C95839487a15")
balance := big.NewInt(1000000000000000000) // 1 ETH in wei

err = vm.SetBalance(address, balance)
if err != nil {
    panic(err)
}

// Get account balance
currentBalance, err := vm.GetBalance(address)
if err != nil {
    panic(err)
}
fmt.Printf("Balance: %s wei\n", currentBalance.String())

// Set contract code
bytecode := []byte{0x60, 0x80, 0x60, 0x40, 0x52} // Contract bytecode
err = vm.SetCode(address, bytecode)

// Get contract code
code, err := vm.GetCode(address)
fmt.Printf("Code: %x\n", code)

// Storage operations
slot := big.NewInt(0)
value := big.NewInt(42)

err = vm.SetStorage(address, slot, value)
storedValue, err := vm.GetStorage(address, slot)
fmt.Printf("Storage[0]: %s\n", storedValue.String())
```

### Working with Call Results

```go
result, err := vm.Call(params)
if err != nil {
    // Handle execution error
    log.Printf("Execution failed: %v", err)
    return
}

// Check execution status
if !result.Success {
    log.Printf("Call reverted: %s", result.ErrorInfo)
    return
}

// Access execution data
fmt.Printf("Gas used: %d\n", result.GasLeft)
fmt.Printf("Output: %x\n", result.Output)

// Process logs
for _, log := range result.Logs {
    fmt.Printf("Log from %s\n", log.Address.Hex())
    for i, topic := range log.Topics {
        fmt.Printf("  Topic[%d]: %s\n", i, topic.Text(16))
    }
    fmt.Printf("  Data: %x\n", log.Data)
}

// Check for self-destructs
for _, sd := range result.SelfDestructs {
    fmt.Printf("Contract %s self-destructed, beneficiary: %s\n", 
        sd.Contract.Hex(), sd.Beneficiary.Hex())
}

// Accessed addresses (for access lists)
for _, addr := range result.AccessedAddresses {
    fmt.Printf("Accessed: %s\n", addr.Hex())
}

// Accessed storage slots
for _, storage := range result.AccessedStorage {
    fmt.Printf("Storage access: %s[%s]\n", 
        storage.Address.Hex(), storage.Slot.Text(16))
}
```

## API Reference

### EVM Instance

```go
// Create a new EVM instance
func New() (*EVM, error)

// Close the EVM instance and free resources
func (evm *EVM) Destroy() error

// Execute any type of EVM call
func (evm *EVM) Call(params CallParams) (*CallResult, error)
```

### Call Parameter Types

All types implement the `CallParams` interface:

```go
type Call struct {
    Caller primitives.Address
    To     primitives.Address
    Value  *big.Int
    Input  []byte
    Gas    uint64
}

type Staticcall struct {
    Caller primitives.Address
    To     primitives.Address
    Input  []byte
    Gas    uint64
}

type Delegatecall struct {
    Caller primitives.Address
    To     primitives.Address
    Input  []byte
    Gas    uint64
}

type Create struct {
    Caller   primitives.Address
    Value    *big.Int
    InitCode []byte
    Gas      uint64
}

type Create2 struct {
    Caller   primitives.Address
    Value    *big.Int
    InitCode []byte
    Salt     *big.Int
    Gas      uint64
}
```

### State Management

```go
// Balance operations
func (evm *EVM) SetBalance(address primitives.Address, balance *big.Int) error
func (evm *EVM) GetBalance(address primitives.Address) (*big.Int, error)

// Code operations
func (evm *EVM) SetCode(address primitives.Address, code []byte) error
func (evm *EVM) GetCode(address primitives.Address) ([]byte, error)

// Storage operations
func (evm *EVM) SetStorage(address primitives.Address, key, value *big.Int) error
func (evm *EVM) GetStorage(address primitives.Address, key *big.Int) (*big.Int, error)
```

### Result Types

```go
type CallResult struct {
    Success           bool
    GasLeft           uint64
    Output            []byte
    Logs              []LogEntry
    SelfDestructs     []SelfDestructRecord
    AccessedAddresses []primitives.Address
    AccessedStorage   []StorageAccessRecord
    ErrorInfo         string
}

type LogEntry struct {
    Address primitives.Address
    Topics  []*big.Int
    Data    []byte
}

type SelfDestructRecord struct {
    Contract    primitives.Address
    Beneficiary primitives.Address
}

type StorageAccessRecord struct {
    Address primitives.Address
    Slot    *big.Int
}
```

### Address Type

The `primitives.Address` type provides useful methods while wrapping `[20]byte`:

```go
// Create addresses
addr := primitives.ZeroAddress()
addr, err := primitives.AddressFromHex("0x742d35Cc6634C0532925a3b8266C95839487a15")

// Convert formats
hex := addr.Hex()           // "0x742d..."
bytes := addr.Bytes()        // []byte (copy)
array := addr.Array()        // [20]byte

// Check properties
if addr.IsZero() { ... }
if addr.Equal(other) { ... }
```

## Performance Considerations

- **Zero-copy FFI** - Minimal copying between Go and C layers
- **Native types** - No overhead from unnecessary wrappers
- **Thread-safe** - All operations properly synchronized
- **Memory management** - Automatic cleanup with finalizers

## Testing

```bash
# Run all tests
go test ./...

# Run with race detection
go test -race ./...

# Run benchmarks
go test -bench=. ./...

# Verbose output
go test -v ./...
```

## Building

The bindings require CGO and link against the Guillotine library:

```bash
# Build the Zig library first
cd ../..
zig build

# Then build the Go bindings
cd sdks/go
go build ./...
```

## License

See the LICENSE file in the repository root.