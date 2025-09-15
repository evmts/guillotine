# guillotine-rs

> **Experimental/PoC**: This SDK is a proof-of-concept. APIs are unstable and may change. We're looking for early users to try it and tell us what APIs you want — please open an issue or ping us on Telegram.

📚 **[View Full Documentation](https://docs.rs/guillotine-rs)**

## Status

- **Maturity**: Experimental proof-of-concept
- **API stability**: Unstable; breaking changes expected
- **Feedback**: [GitHub Issues](https://github.com/evmts/Guillotine/issues) or [Telegram](https://t.me/+ANThR9bHDLAwMjUx)

A safe Rust wrapper around the Guillotine EVM - a high-performance Ethereum Virtual Machine implementation written in Zig.

## Overview

This crate provides idiomatic Rust bindings to Guillotine, allowing Rust developers to leverage a fast, native EVM implementation. The wrapper offers both standard and stateful (high-performance) APIs with zero-copy FFI where possible. The bindings are designed with safety, performance, and ease of use in mind.

## Installation

Add this to your `Cargo.toml`:

```toml
[dependencies]
guillotine-rs = "0.1.0"
```

### Configuration via Feature Flags

Guillotine can be configured at compile-time through Cargo feature flags:

```toml
[dependencies]
guillotine-rs = { version = "0.1.0", features = ["tracing", "bench"] }
```

Available features:
- **`tracing`**: Enable execution tracing for debugging
- **`bench`**: Enable optimizations and benchmarking capabilities
- **Hardfork selection**: `hardfork-frontier`, `hardfork-homestead`, `hardfork-byzantium`, `hardfork-berlin`, `hardfork-london`, `hardfork-shanghai`, `hardfork-cancun`
- **Optimization**: `optimize-fast`, `optimize-small`, `optimize-safe`
- **Configuration**: `max-call-depth-256/512/2048`, `stack-size-256/512/2048`, `large-memory-limit`, `small-memory-limit`, `large-arena`, `small-arena`
- **Testing**: `disable-precompiles`, `disable-fusion`, `disable-gas-checks` (⚠️ testing only), `disable-balance-checks` (⚠️ testing only)

### Build Requirements

This crate builds the Guillotine EVM from source automatically. You need:

1. **Zig compiler** (0.15.1 or later) - [Install from ziglang.org](https://ziglang.org/download/)
   ```bash
   # macOS
   brew install zig
   
   # Ubuntu/Debian
   snap install zig --classic
   
   # Windows
   winget install zig.zig
   ```

2. **Git** - For downloading source if not in a git repository
3. **Curl** - For downloading cryptographic dependencies (KZG trusted setup)

The build process will:
- Automatically clone the Guillotine repository if needed
- Build the Zig static library with appropriate optimizations
- Build required Rust crypto dependencies (bn254, revm wrappers)
- Generate FFI bindings using bindgen

**Note**: First build may take several minutes. Subsequent builds are much faster.

## Features

- **Safe API**: All unsafe FFI calls are wrapped in safe Rust abstractions
- **Zero-copy Operations**: Minimizes data copying between Rust and Zig for maximum performance
- **Dual APIs**: Standard `Evm` for general use, `StatefulEvm` for high-performance scenarios
- **Idiomatic Rust**: Uses standard Rust patterns like `Result`, `Option`, and RAII
- **Alloy Integration**: Full compatibility with alloy-primitives types (Address, U256, Bytes, etc.)
- **Thread-safe**: VM instances can be safely sent between threads
- **Comprehensive Error Handling**: All errors are properly propagated with context
- **Transaction Builder**: Fluent API for constructing complex transactions
- **Batch Operations**: Efficient bulk state updates for testing and setup

## Usage

### Quick Start

```rust
use guillotine_ffi::{Evm, EvmBuilder, ExecutionResult, CallType};
use alloy_primitives::{Address, U256, address};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    // Initialize FFI layer (call once at program start)
    guillotine_ffi::initialize();
    
    // Create EVM with custom configuration
    let mut evm = EvmBuilder::new()
        .with_block_number(1000)
        .with_chain_id(1)
        .build()?;

    // Set up accounts
    let sender = address!("1111111111111111111111111111111111111111");
    let receiver = address!("2222222222222222222222222222222222222222");

    evm.set_balance(sender, U256::from(1_000_000_000_000_000_000u64))?;

    // Simple transfer using transaction builder
    let result = evm.transact()
        .from(sender)
        .to(receiver)
        .value(U256::from(1_000_000_000_000_000u64))
        .gas_limit(21000)
        .execute()?;

    println!("Transfer successful: {}", result.is_success());
    println!("Gas used: {}", result.gas_used);

    Ok(())
}
```

### Contract Deployment and Interaction

```rust
use guillotine_ffi::{Evm, CallType, bytecode_from_hex, address_from_hex};
use alloy_primitives::U256;

fn deploy_and_call_contract() -> Result<(), Box<dyn std::error::Error>> {
    guillotine_ffi::initialize();
    let mut evm = Evm::new()?;
    
    let deployer = address_from_hex("0x1111111111111111111111111111111111111111")?;
    evm.set_balance(deployer, U256::from(1_000_000_000_000_000_000u64))?;

    // Simple contract that stores and returns a value
    let bytecode = bytecode_from_hex("0x608060405234801561001057600080fd5b50...")?;
    
    // Deploy contract using CREATE
    let deploy_result = evm.transact()
        .from(deployer)
        .input(bytecode)
        .gas_limit(500_000)
        .call_type(CallType::Create)
        .execute()?;

    if let Some(contract_addr) = deploy_result.created_address {
        println!("Contract deployed at: {:?}", contract_addr);
        
        // Call contract function
        let call_data = bytecode_from_hex("0x2e64cec1")?; // retrieve()
        let call_result = evm.execute(deployer, Some(contract_addr), 
                                     U256::ZERO, &call_data, 100_000)?;
        
        println!("Contract call result: {:02x?}", call_result.output());
    }

    Ok(())
}
```

### High-Performance Stateful API

For benchmarking or high-throughput scenarios, use `StatefulEvm` which avoids recreation overhead:

```rust
use guillotine_ffi::{StatefulEvm, StatefulEvmConfig, StateUpdate};
use alloy_primitives::{Address, U256, address};

fn high_performance_usage() -> Result<(), Box<dyn std::error::Error>> {
    // Create with custom configuration
    let config = StatefulEvmConfig {
        block_number: 1000,
        chain_id: 1,
        gas_limit: 30_000_000,
        ..Default::default()
    };
    
    let mut evm = StatefulEvm::with_config(config)?;
    
    // Batch setup for efficiency
    let updates = vec![
        StateUpdate::SetBalance {
            address: address!("1111111111111111111111111111111111111111"),
            balance: U256::from(1_000_000_000_000_000_000u64),
        },
        StateUpdate::SetBalance {
            address: address!("2222222222222222222222222222222222222222"),
            balance: U256::from(500_000_000_000_000_000u64),
        },
        StateUpdate::SetCode {
            address: address!("3333333333333333333333333333333333333333"),
            code: vec![0x60, 0x42, 0x60, 0x00, 0x55], // PUSH1 0x42, PUSH1 0x00, SSTORE
        },
    ];
    
    evm.batch_updates(updates)?;
    
    // Execute many transactions efficiently
    for i in 0..1000 {
        let result = evm.execute(
            address!("1111111111111111111111111111111111111111"),
            Some(address!("3333333333333333333333333333333333333333")),
            U256::ZERO,
            &[],
            100_000,
        )?;
        
        assert!(result.is_success(), "Transaction {} failed", i);
    }
    
    // Reset state for next test (much faster than recreating)
    evm.reset()?;
    
    Ok(())
}
```

### Advanced Examples

#### Working with Logs and Events

```rust
use guillotine_ffi::{Evm, CallType};
use alloy_primitives::{U256, address, bytes};

fn test_event_logs() -> Result<(), Box<dyn std::error::Error>> {
    guillotine_ffi::initialize();
    let mut evm = Evm::new()?;
    
    let caller = address!("1111111111111111111111111111111111111111");
    let contract = address!("2222222222222222222222222222222222222222");
    
    evm.set_balance(caller, U256::from(1_000_000_000_000_000_000u64))?;
    
    // Contract that emits an event: LOG1 with topic and data
    let log_code = bytes!("7f1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef60005260206000a1");
    evm.set_code(contract, &log_code)?;
    
    let result = evm.execute(caller, Some(contract), U256::ZERO, &[], 100_000)?;
    
    println!("Logs emitted: {}", result.logs.len());
    for log in &result.logs {
        println!("Log from: {:?}", log.address);
        println!("Topics: {:?}", log.topics);
        println!("Data: {:02x?}", log.data);
    }
    
    Ok(())
}
```

#### Testing with Tracing

```rust
use guillotine_ffi::{Evm, types};

fn test_with_tracing() -> Result<(), Box<dyn std::error::Error>> {
    guillotine_ffi::initialize();
    
    // Create EVM with tracing enabled
    let mut evm = Evm::with_tracing(types::default_block_info())?;
    
    let caller = address!("1111111111111111111111111111111111111111");
    evm.set_balance(caller, U256::from(1_000_000_000_000_000_000u64))?;
    
    let result = evm.execute(caller, Some(caller), U256::from(1000), &[], 21000)?;
    
    // Trace data (if available) provides execution details
    if let Some(trace) = &result.trace_json {
        println!("Execution trace: {}", trace);
    }
    
    Ok(())
}
```

## Architecture

The crate is structured in several key modules:

1. **FFI Layer** (`ffi` module): Auto-generated and manual bindings to Guillotine's C API
2. **Types** (`types` module): Common types like `ExecutionResult`, `Log`, `CallType`, etc.
3. **Standard API** (root module): `Evm` with transaction builder for general use
4. **Stateful API** (`stateful` module): `StatefulEvm` for high-performance scenarios with zero-copy operations

### API Overview

#### Standard EVM (`Evm`)
- General-purpose EVM for most use cases
- Automatic FFI initialization
- Transaction builder pattern for fluent API
- Supports both regular execution and simulation
- Optional tracing support

#### Stateful EVM (`StatefulEvm`) 
- High-performance API for benchmarking and bulk operations
- Avoids VM recreation overhead
- Zero-copy operations where possible
- Batch state update capabilities
- Fast state reset functionality

#### Key Types
- `ExecutionResult`: Transaction execution results with gas usage, outputs, and logs
- `CallType`: Enum for different call types (Call, Create, StaticCall, etc.)
- `Log`: Event log entries with address, topics, and data
- `StateUpdate`: Batch operation types for efficient state setup

## Performance

Guillotine is designed for high performance with:
- **Minimal allocations**: Arena-based memory management in Zig
- **Efficient dispatch**: Jump table-based opcode dispatch
- **Bytecode fusion**: Advanced instruction combining for common patterns
- **Zero-copy FFI**: Rust slices directly reference Zig memory where safe
- **Stateful operations**: Reuse EVM instances to avoid setup/teardown costs

### Performance Tips

1. **Use StatefulEvm for bulk operations**: Avoids VM recreation overhead
2. **Batch state updates**: Use `batch_updates()` instead of individual calls
3. **Enable appropriate features**: `optimize-fast` for maximum speed, `large-arena` for memory-intensive workloads
4. **Reset instead of recreate**: `evm.reset()` is much faster than creating new instances

## Benchmarks

Run comprehensive benchmarks comparing Guillotine to revm:

```bash
# Build with benchmarking optimizations
cargo build --release --features bench

# Run comparison benchmarks
cargo bench --features bench

# View HTML reports
open target/criterion/report/index.html
```

Benchmarks include:
- Simple transfers
- Arithmetic operations
- Memory operations
- Contract deployment
- Complex contract interactions

## Safety

This crate ensures safety by:
- **Wrapping all unsafe FFI calls**: No unsafe code in public API
- **Proper lifetime management**: RAII ensures resources are freed
- **Input validation**: All parameters validated before FFI calls
- **Error propagation**: Zig errors properly converted to Rust `Result`
- **Memory safety**: No exposed raw pointers; all allocations tracked
- **Thread safety**: VM instances are `Send + Sync`

## Development and Testing

### Building from Source

Prerequisites:
- Rust 1.75+ (for latest alloy-primitives compatibility)  
- Zig 0.15.1+ 
- Git and curl for dependency downloads

```bash
# Clone the repository
git clone https://github.com/evmts/guillotine
cd guillotine/sdks/rust

# Build with full optimizations
cargo build --release

# Run tests (many require FFI so they're ignored by default)
cargo test -- --ignored

# Run specific integration tests
cargo test test_full_evm_workflow -- --ignored --nocapture
```

### Feature Configuration Examples

```toml
# Performance-optimized build
[dependencies]
guillotine-rs = { 
    version = "0.1.0", 
    features = ["optimize-fast", "large-arena", "large-memory-limit"] 
}

# Minimal size build
[dependencies]
guillotine-rs = { 
    version = "0.1.0", 
    features = ["optimize-small", "small-arena", "disable-precompiles"] 
}

# Testing/debugging build
[dev-dependencies]
guillotine-rs = { 
    version = "0.1.0", 
    features = ["tracing", "disable-gas-checks"] 
}
```

## Troubleshooting

### Common Issues

#### Build Failures

**"Zig compiler not found"**
- Install Zig 0.15.1+ from [ziglang.org](https://ziglang.org/download/)
- Ensure `zig` is in your PATH

**"Failed to download Guillotine source"**  
- Check internet connection and git installation
- Corporate firewalls may block git clone - try using git with proxy settings

**"KZG trusted setup download failed"**
- Ensure curl is installed and can access GitHub
- Some corporate environments block external downloads

#### Runtime Issues

**"Failed to create Guillotine VM"**
- Check that `guillotine_ffi::initialize()` was called first
- Verify sufficient memory is available

**FFI/Binding Errors**
- Ensure matching Rust and Zig ABI compatibility
- Try rebuilding from scratch: `cargo clean && cargo build`

### Getting Help

- **GitHub Issues**: [Report bugs or request features](https://github.com/evmts/Guillotine/issues)
- **Telegram**: [Join the community chat](https://t.me/+ANThR9bHDLAwMjUx)
- **Documentation**: [API docs on docs.rs](https://docs.rs/guillotine-rs)

## License

This project is dual-licensed under MIT or Apache-2.0, same as the main Guillotine project.

## Contributing

Contributions are welcome! This is an experimental project and we're actively seeking feedback on:

- API design and ergonomics
- Performance optimizations  
- Additional EVM features needed
- Integration examples and use cases
- Documentation improvements

Please read the main [Guillotine contributing guidelines](https://github.com/evmts/Guillotine/blob/main/CONTRIBUTING.md) before submitting PRs.

### Development Workflow

1. Fork the repository
2. Create a feature branch
3. Make your changes in `sdks/rust/`
4. Add tests for new functionality
5. Ensure `cargo test -- --ignored` passes
6. Update documentation as needed
7. Submit a pull request

We especially welcome:
- New examples and documentation
- Performance benchmarks and optimizations
- Integration with other Rust crypto/blockchain crates
- Bug reports with minimal reproducible examples
