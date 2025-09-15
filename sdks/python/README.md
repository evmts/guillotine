# Guillotine EVM Python Bindings

> Experimental/PoC: This SDK is a vibecoded proof-of-concept. APIs are unstable and may change. We're looking for early users to try it and tell us what APIs you want — please open an issue or ping us on Telegram.

📚 **[View Full Documentation](https://guillotine.dev/sdks/python)**

## Status

- Maturity: Experimental proof‑of‑concept
- API stability: Unstable; breaking changes expected
- Feedback: https://github.com/evmts/Guillotine/issues or Telegram https://t.me/+ANThR9bHDLAwMjUx

Python bindings for the Guillotine EVM - a high-performance Ethereum Virtual Machine implementation written in Zig.

## Features

- **High Performance**: Direct bindings to the optimized Zig EVM implementation
- **Type Safety**: Full Python type hints and runtime type checking
- **Comprehensive API**: Support for EVM execution, state management, and primitives
- **Bytecode Analysis**: Advanced bytecode inspection and optimization
- **Precompiled Contracts**: Built-in support for Ethereum precompiles
- **Cross Platform**: Works on Linux, macOS, and Windows
- **Memory Safe**: Proper memory management and cleanup

## Installation

```bash
pip install guillotine-evm
```

## Quick Start

### Bun-parity API

```python
from guillotine_evm import EVM, BlockInfo, CallType, CallParams

# Create EVM instance with block context
evm = EVM(BlockInfo(
    number=1,
    timestamp=1,
    gas_limit=30_000_000,
    coinbase="0x" + "00" * 20,
    base_fee=1_000_000_000,
    chain_id=1,
))

# Set up accounts
caller = "0x" + "11" * 20
to = "0x" + "22" * 20
evm.set_balance(caller, 10**18)

# Helper function to create simple return bytecode
def push32_return_bytes(data: bytes) -> bytes:
    assert len(data) == 32
    return bytes([0x7F]) + data + bytes([0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xF3])

# Deploy contract that returns 42 (0x2a)
ret = (b"\x00" * 31) + b"\x2a"
evm.set_code(to, push32_return_bytes(ret))

# Execute contract call
result = evm.call(CallParams(
    caller=caller,
    to=to,
    value=0,
    input=b"",
    gas=100_000,
    call_type=CallType.CALL,
))

print("Success:", result.success)
print("Gas left:", result.gas_left)
print("Output:", result.output.hex())

# Clean up
evm.destroy()
```

### Basic EVM Usage (Alternative API)

```python
from guillotine_evm import EVM, Address, U256

# Simple bytecode execution
with EVM() as evm:
    # Simple bytecode: PUSH1 42, PUSH1 0, RETURN (returns 42)
    bytecode = bytes.fromhex("602a6000f3")
    
    result = evm.execute(
        bytecode=bytecode,
        gas_limit=100000
    )
    
    print(f"Success: {result.success}")
    print(f"Gas used: {result.gas_used}")
    print(f"Return data: {result.return_data.hex()}")
```

## API Overview

### Core Components

The Python bindings provide several main components:

- **EVM**: Main execution engine with two APIs (Bun-parity and native)  
- **Primitives**: Core Ethereum types (Address, U256, Hash, Bytes)
- **Bytecode**: Bytecode analysis and optimization tools
- **Precompiles**: Access to Ethereum precompiled contracts
- **Planner**: Bytecode optimization and performance analysis
- **Exceptions**: Comprehensive error handling

### EVM Execution

```python
from guillotine_evm import EVM, BlockInfo, CallType, CallParams, EvmResult

# Bun-parity API - explicit block context
evm = EVM(BlockInfo(
    number=1,
    timestamp=1,
    gas_limit=30_000_000,
    coinbase="0x0000000000000000000000000000000000000000",
    base_fee=1_000_000_000,
    chain_id=1,
))

# Execute calls
result: EvmResult = evm.call(CallParams(...))
result: EvmResult = evm.simulate(CallParams(...))  # Read-only

evm.destroy()
```

### Primitives

```python
from guillotine_evm import Address, U256, Hash

# Address operations
addr = Address.from_hex("0x1234567890123456789012345678901234567890")
zero_addr = Address.zero()
print(f"Is zero: {addr.is_zero()}")
print(f"Checksum: {addr.to_checksum()}")

# U256 with EVM semantics
num1 = U256.from_int(42)
num2 = U256.from_hex("0x2a")
num3 = U256.from_ether(1.5)  # 1.5 ETH in wei
result = num1 + num2  # Overflow wrapping like EVM
print(f"In Gwei: {num3.to_gwei()}")

# Hash operations
hash_val = Hash.from_hex("0x1234...")
keccak = Hash.keccak256(b"Hello, Ethereum!")
```

### Bytecode Analysis

```python
from guillotine_evm import Bytecode, Opcode, Instruction

# Analyze bytecode
bytecode = Bytecode.from_hex("608060405234801561001057...")
stats = bytecode.statistics()
print(f"Instructions: {stats.instruction_count}")
print(f"Gas estimate: {stats.gas_estimate}")
print(f"Complexity score: {stats.complexity_score}")

# Inspect instructions
for pc, instruction in bytecode.instructions():
    print(f"PC {pc:04x}: {instruction}")

# Find jump destinations
jump_dests = list(bytecode.jump_destinations())
```

### Precompiled Contracts

```python
from guillotine_evm import (
    ecrecover, sha256, ripemd160, identity, modexp,
    ecadd, ecmul, ecpairing, blake2f,
    is_precompile_address, create_precompile_address
)

# Use precompiles directly
hash_result = sha256(b"Hello, world!")
copied = identity(b"data")

# Cryptographic operations
base = U256.from_int(2)
exp = U256.from_int(10)
mod = U256.from_int(1000)
result = modexp(base, exp, mod)  # 2^10 % 1000

# Check addresses
addr = create_precompile_address(1)  # ECRECOVER
print(f"Is precompile: {is_precompile_address(addr)}")
```

### Performance Optimization

```python
from guillotine_evm import Planner, Bytecode

# Analyze and optimize bytecode
with Planner() as planner:
    bytecode = Bytecode.from_hex("6001600201...")
    
    # Create optimized execution plan
    plan = planner.plan(bytecode)
    print(f"Optimization ratio: {plan.optimization_ratio:.2f}x")
    
    # Performance analysis
    complexity = planner.analyze_complexity(bytecode)
    gain = planner.estimate_performance_gain(bytecode)
    
    # Cache statistics
    cache_stats = planner.cache_stats()
    print(f"Cache hit rate: {cache_stats.hit_rate:.1%}")
```

## Examples

See comprehensive examples in:
- `examples.py` - Basic usage patterns and API demonstrations
- `examples_comprehensive.py` - Advanced features and performance optimization

Run examples:
```bash
cd sdks/python
python examples.py
python examples_comprehensive.py
```

## Error Handling

The bindings provide comprehensive error handling with specific exception types:

```python
from guillotine_evm import (
    GuillotineError, ExecutionError, InvalidAddressError,
    ValidationError, OutOfGasError, InvalidBytecodeError
)

try:
    # Invalid operations will raise specific errors
    addr = Address.from_hex("0x123")  # Too short
except InvalidAddressError as e:
    print(f"Invalid address: {e}")

try:
    with EVM() as evm:
        result = evm.execute(bytecode=b"", gas_limit=50000)
except ExecutionError as e:
    print(f"Execution failed: {e}")
    if e.gas_used is not None:
        print(f"Gas used before failure: {e.gas_used}")
```

## Development

### Setup

```bash
# Clone the repository
git clone https://github.com/evmts/guillotine.git
cd guillotine/sdks/python

# Install development dependencies
pip install -e ".[dev]"

# Run tests
pytest tests/

# Run type checking  
mypy guillotine_evm

# Format code
black guillotine_evm tests
ruff check guillotine_evm tests
```

### Building from Source

The Python bindings require the Guillotine EVM library to be built first:

```bash
# Build the main Zig project
cd ../..
zig build

# Build Python bindings
cd sdks/python
python -m build
```

## Architecture

The Python bindings use CFFI to interface with the native Guillotine EVM library:

```
Python API (guillotine_evm)
    ↓
CFFI Bindings (guillotine_evm._ffi*)
    ↓  
C FFI Layer (Zig C ABI exports)
    ↓
Guillotine EVM Core (Zig)
```

## Package Structure

```
guillotine_evm/
├── __init__.py           # Main exports
├── evm_ffi.py           # Bun-parity EVM API  
├── evm_enhanced.py      # Enhanced EVM features
├── primitives_enhanced.py # Ethereum primitive types
├── bytecode.py          # Bytecode analysis tools
├── planner.py          # Optimization and planning
├── precompiles.py      # Precompiled contract support
├── exceptions.py       # Error types
├── _ffi*.py            # CFFI bindings (multiple variants)
└── py.typed           # Type checking marker
```

## Performance

Guillotine EVM is designed for high performance:

- **Zero-copy operations**: Minimal memory allocations and copies
- **Direct C bindings**: Low-overhead CFFI interface to native code
- **Optimized bytecode analysis**: Advanced static analysis and optimization
- **Memory safety**: Proper resource cleanup with context managers
- **Batch operations**: Efficient processing of multiple operations
- **Caching**: Intelligent caching of analysis results and execution plans

## API Reference

### Core Types

| Type | Description | Key Methods |
|------|-------------|-------------|
| `EVM` | Main execution engine | `call()`, `simulate()`, `set_balance()`, `set_code()` |
| `Address` | 20-byte Ethereum address | `from_hex()`, `to_checksum()`, `is_zero()` |
| `U256` | 256-bit unsigned integer | `from_int()`, `from_ether()`, `to_gwei()`, arithmetic ops |
| `Hash` | 32-byte hash value | `from_hex()`, `keccak256()`, `zero()` |
| `Bytecode` | EVM bytecode with analysis | `statistics()`, `instructions()`, `jump_destinations()` |
| `Planner` | Bytecode optimizer | `plan()`, `analyze_complexity()`, `cache_stats()` |

### Call Types

| Type | Value | Description |
|------|-------|-------------|  
| `CallType.CALL` | 0 | Regular contract call |
| `CallType.DELEGATECALL` | 1 | Delegate call (preserves caller context) |
| `CallType.STATICCALL` | 2 | Read-only call |
| `CallType.CREATE` | 3 | Contract creation |
| `CallType.CREATE2` | 4 | CREATE2 contract creation |

### Result Types

- `EvmResult`: Contains `success`, `gas_left`, `output`, `error`
- `DeployResult`: Contains `success`, `contract_address`, `gas_used`, `error`
- `BytecodeStats`: Contains `instruction_count`, `gas_estimate`, `complexity_score`, etc.
- `Plan`: Contains `optimization_ratio`, `instruction_count`, `has_jump_table`, etc.
- `CacheStats`: Contains `size`, `capacity`, `hit_rate`

## License

MIT License - see the LICENSE file for details.

## Contributing

Contributions are welcome! Please see the main project's CONTRIBUTING.md for guidelines.

## Version History

- **0.1.0** - Initial experimental release
  - Basic EVM execution with Bun-parity API
  - Comprehensive primitive types (Address, U256, Hash)
  - Bytecode analysis and optimization tools
  - Precompiled contract support
  - CFFI-based native bindings
