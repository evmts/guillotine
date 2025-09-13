# Guillotine Go Bindings

Go bindings for the Guillotine EVM implementation, providing a clean and idiomatic Go interface to the high-performance Zig EVM.

## Overview

The Go bindings provide a production-ready interface to Guillotine EVM using native Go types and patterns. The API has been designed to be minimal, clean, and idiomatic to Go conventions.

### Features

- **High Performance**: Zero-copy FFI with minimal overhead between Go and Zig
- **Type Safety**: Strong typing with native Go types (`*big.Int`, `[]byte`, etc.)
- **Thread Safety**: Concurrent access protection with proper synchronization
- **Memory Management**: Automatic resource cleanup with finalizers
- **Comprehensive API**: Support for all EVM operations (CALL, CREATE, storage, etc.)
- **Tracing Support**: Optional JSON-RPC compatible execution tracing
- **Block Context**: Configurable block environment for EVM execution

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

### Prerequisites

- Go 1.21 or later
- Zig compiler (for building the underlying Guillotine library)
- C compiler (CGO is required)

### Install from source

1. Clone the repository:
```bash
git clone https://github.com/evmts/guillotine.git
cd guillotine/sdks/go
```

2. Build the Zig library and install Go dependencies:
```bash
make install
```

This will:
- Build the Guillotine Zig library with optimizations
- Download Go module dependencies
- Set up the necessary shared libraries

### Using as a dependency

Add to your `go.mod`:

```bash
go get github.com/evmts/guillotine/sdks/go
```

**Important**: You need to build the Guillotine library first:

```bash
# Navigate to your module cache or clone the repo
git clone https://github.com/evmts/guillotine.git
cd guillotine/sdks/go
make install
```

Or use the library from a local clone:

```go
// In your go.mod
replace github.com/evmts/guillotine/sdks/go => /path/to/local/guillotine/sdks/go
```

### Available make targets

```bash
make install  # Build Zig library and download Go dependencies
make build    # Build only the Zig library
make test     # Run Go tests (builds library first)
make clean    # Clean build artifacts
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

### EVM with Custom Block Context

```go
package main

import (
    "math/big"
    
    "github.com/evmts/guillotine/sdks/go/evm"
    "github.com/evmts/guillotine/sdks/go/primitives"
    guillotine "github.com/evmts/guillotine/sdks/go"
)

func main() {
    // Configure custom block context
    blockInfo := &guillotine.BlockInfo{
        Number:     12345678,
        Timestamp:  1640995200, // Jan 1, 2022
        GasLimit:   30000000,
        Coinbase:   primitives.ZeroAddress(),
        BaseFee:    20000000000, // 20 gwei
        ChainID:    1,           // Ethereum mainnet
        Difficulty: 0,
        PrevRandao: [32]byte{},
    }
    
    // Create EVM with custom block context
    vmHandle, err := guillotine.NewVMHandle(blockInfo)
    if err != nil {
        panic(err)
    }
    defer vmHandle.Destroy()
    
    // Use the VMHandle directly or wrap in evm.EVM...
}
```

### EVM with Tracing

```go
package main

import (
    "fmt"
    "math/big"
    
    "github.com/evmts/guillotine/sdks/go/evm"
    "github.com/evmts/guillotine/sdks/go/primitives"
)

func main() {
    // Create EVM instance with tracing enabled
    vm, err := evm.NewTracing()
    if err != nil {
        panic(err)
    }
    defer vm.Destroy()
    
    // Set up a simple contract
    contractAddr, _ := primitives.AddressFromHex("0x1000000000000000000000000000000000000000")
    bytecode := []byte{0x60, 0x42, 0x60, 0x00, 0x52} // PUSH1 0x42, PUSH1 0x00, MSTORE
    
    err = vm.SetCode(contractAddr, bytecode)
    if err != nil {
        panic(err)
    }
    
    // Execute with tracing
    result, err := vm.Call(evm.Call{
        Caller: primitives.ZeroAddress(),
        To:     contractAddr,
        Value:  big.NewInt(0),
        Input:  []byte{},
        Gas:    1000000,
    })
    
    if err != nil {
        panic(err)
    }
    
    // Access trace data
    if len(result.TraceJSON) > 0 {
        fmt.Printf("Trace JSON: %s\n", string(result.TraceJSON))
    }
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

// Access the created contract address
if result.CreatedAddress != nil {
    fmt.Printf("Created contract at: %s\n", result.CreatedAddress.Hex())
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

if result.CreatedAddress != nil {
    fmt.Printf("CREATE2 contract at: %s\n", result.CreatedAddress.Hex())
}
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
// Create a new EVM instance with default block context
func New() (*EVM, error)

// Create a new EVM instance with JSON-RPC tracing enabled
func NewTracing() (*EVM, error)

// Close the EVM instance and free resources
func (evm *EVM) Destroy() error

// Execute any type of EVM call
func (evm *EVM) Call(params CallParams) (*CallResult, error)
```

### Low-level VM Handle

```go
// Create a VM handle with optional custom block context
func NewVMHandle(blockInfo ...*BlockInfo) (*VMHandle, error)

// Create a VM handle with tracing and optional custom block context
func NewTracingVMHandle(blockInfo ...*BlockInfo) (*VMHandle, error)

// Execute call with low-level parameters
func (vm *VMHandle) Call(params *CallParams) (*CallResult, error)

// State management methods
func (vm *VMHandle) SetBalance(address [20]byte, balance [32]byte) error
func (vm *VMHandle) GetBalance(address [20]byte) ([32]byte, error)
func (vm *VMHandle) SetCode(address [20]byte, code []byte) error
func (vm *VMHandle) GetCode(address [20]byte) ([]byte, error)
func (vm *VMHandle) SetStorage(address [20]byte, key, value [32]byte) error
func (vm *VMHandle) GetStorage(address [20]byte, key [32]byte) ([32]byte, error)

// Close the VM handle
func (vm *VMHandle) Destroy() error
```

### Block Context Configuration

```go
type BlockInfo struct {
    Number     uint64
    Timestamp  uint64
    GasLimit   uint64
    Coinbase   primitives.Address
    BaseFee    uint64
    ChainID    uint64
    Difficulty uint64
    PrevRandao [32]byte
}
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
    CreatedAddress    *primitives.Address // Address of created contract (CREATE/CREATE2 only)
    TraceJSON         []byte              // JSON-RPC trace data (tracing mode only)
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

### Primitive Types

#### Address Type

The `primitives.Address` type provides useful methods while wrapping `[20]byte`:

```go
// Create addresses
addr := primitives.ZeroAddress()
addr, err := primitives.AddressFromHex("0x742d35Cc6634C0532925a3b8266C95839487a15")
addr, err := primitives.AddressFromBytes([]byte{0x01, 0x02, ...}) // 20 bytes required

// Convert formats
hex := addr.Hex()           // "0x742d..."
bytes := addr.Bytes()       // []byte (copy)
array := addr.Array()       // [20]byte

// Check properties
if addr.IsZero() { ... }
if addr.Equal(other) { ... }

// Text marshaling (JSON compatible)
text, _ := addr.MarshalText()
addr.UnmarshalText(text)
```

#### Hash Type

The `primitives.Hash` type wraps `[32]byte` for 32-byte hash values:

```go
// Create hashes
hash := primitives.ZeroHash()
hash, err := primitives.HashFromHex("0x1234...")
hash, err := primitives.HashFromBytes([]byte{0x01, 0x02, ...}) // 32 bytes required

// Convert formats
hex := hash.Hex()          // "0x1234..."
bytes := hash.Bytes()      // []byte (copy)
array := hash.Array()      // [32]byte

// Properties
if hash.IsZero() { ... }
if hash.Equal(other) { ... }
```

## Performance Considerations

- **Zero-copy FFI** - Minimal copying between Go and C layers
- **Native types** - No overhead from unnecessary wrappers
- **Thread-safe** - All operations properly synchronized
- **Memory management** - Automatic cleanup with finalizers

## Testing

The Go bindings include comprehensive tests covering all functionality:

```bash
# Build the Zig library and run all tests
make test

# Or run tests manually (requires built library)
go test ./...

# Run with race detection
go test -race ./...

# Run benchmarks
go test -bench=. ./...

# Verbose output
go test -v ./...

# Run specific test packages
go test ./evm              # EVM functionality tests
go test ./primitives       # Primitive types tests
```

### Test Coverage

- **EVM Operations**: All call types (CALL, CREATE, DELEGATECALL, etc.)
- **State Management**: Balance, code, and storage operations
- **Error Handling**: Invalid inputs and execution failures
- **Memory Safety**: Resource cleanup and garbage collection
- **Concurrency**: Thread-safe operations
- **Integration Tests**: Complex multi-step scenarios
- **Benchmarks**: Performance comparison tests

## Building

The bindings require CGO and link against the Guillotine library:

```bash
# Build the Zig library first
cd ../..
zig build -Doptimize=ReleaseFast

# Then build the Go bindings
cd sdks/go
go build ./...
```

### Build Requirements

- **Go 1.21+**: Modern Go version with generics support
- **Zig compiler**: For building the underlying Guillotine library  
- **CGO enabled**: Required for FFI bindings to Zig library
- **C compiler**: GCC, Clang, or MSVC for linking

### Cross-compilation

The bindings support cross-compilation to any platform supported by both Go and Zig:

```bash
# Build for specific platform
GOOS=linux GOARCH=amd64 go build ./...

# Note: You'll need to cross-compile the Zig library for the target platform first
cd ../..
zig build -Doptimize=ReleaseFast -Dtarget=x86_64-linux-gnu
```

## Error Handling

The Go bindings provide structured error handling with specific error types:

### Common Error Types

```go
var (
    ErrInitializationFailed = errors.New("failed to initialize Guillotine")
    ErrVMCreationFailed     = errors.New("failed to create VM instance")
    ErrVMClosed             = errors.New("VM instance has been closed")
    ErrExecutionFailed      = errors.New("EVM execution failed")
    ErrInvalidInput         = errors.New("invalid input")
)
```

### Error Handling Patterns

```go
// Check for execution errors
result, err := vm.Call(params)
if err != nil {
    switch {
    case errors.Is(err, guillotine.ErrVMClosed):
        log.Fatal("VM was closed unexpectedly")
    case errors.Is(err, guillotine.ErrExecutionFailed):
        log.Printf("Execution failed: %v", err)
        // Handle execution failure...
    default:
        log.Printf("Unexpected error: %v", err)
    }
    return
}

// Check execution success
if !result.Success {
    log.Printf("EVM execution reverted: %s", result.ErrorInfo)
    // Handle revert...
}
```

### Troubleshooting

**Build Issues:**
- Ensure Zig library is built first with `make build`
- Check that CGO is enabled: `go env CGO_ENABLED` should return `1`
- Verify C compiler is available in PATH

**Runtime Issues:**
- Always call `Destroy()` to prevent memory leaks
- Use `defer vm.Destroy()` immediately after creation
- Check that gas limits are sufficient for contract execution

**Performance Issues:**
- Use `NewTracing()` only when debugging; tracing adds overhead
- Consider reusing EVM instances instead of creating new ones frequently
- Profile with `go test -bench=.` to identify bottlenecks

## License

See the LICENSE file in the repository root.