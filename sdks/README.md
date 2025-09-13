# Guillotine SDK Collection

Welcome to the Guillotine SDK collection! This directory contains language bindings and SDKs that provide idiomatic interfaces to the Guillotine EVM - a high-performance Ethereum Virtual Machine implementation written in Zig.

## ⚡ What is Guillotine?

Guillotine is an ultrafast EVM implementation designed for every language and platform. Built in Zig with performance as the primary goal, it provides the foundation for these language-specific SDKs through FFI (Foreign Function Interface) bindings.

## 📦 Available SDKs

| Language/Platform | Status | Description | Best For |
|-------------------|--------|-------------|----------|
| **[Bun](./bun/)** | 🟡 Experimental PoC | TypeScript/JavaScript SDK optimized for Bun runtime | High-performance Node.js apps, modern JS tooling |
| **[C](./c/)** | 🟡 Experimental PoC | Core C bindings for direct FFI access | Embedded systems, language bridges, maximum control |
| **[Go](./go/)** | 🟢 Production Ready | Clean Go bindings with native types | Backend services, blockchain tooling, Go applications |
| **[Python](./python/)** | 🟡 Experimental PoC | Full Python bindings with type safety | Data analysis, prototyping, Python applications |
| **[Rust](./rust/)** | 🟡 Experimental PoC | Safe Rust wrapper with zero-copy FFI | Performance-critical Rust apps, memory safety |
| **[Swift](./swift/)** | 🟡 Experimental PoC | Native Swift bindings for Apple platforms | iOS/macOS apps, Swift backend services |
| **[TypeScript](./typescript/)** | 🟡 Experimental PoC | WebAssembly-powered TS/JS implementation | Browser applications, universal JavaScript |

### Status Legend
- 🟢 **Production Ready**: Stable APIs, comprehensive features
- 🟡 **Experimental PoC**: Proof-of-concept, APIs may change, seeking user feedback
- 🔴 **Planned**: Not yet implemented

## 🎯 Choosing an SDK

### For Web Development
- **TypeScript**: Browser-compatible via WebAssembly, universal JavaScript support
- **Bun**: Optimized for server-side with Bun's FFI performance benefits

### For Backend Services
- **Go**: Production-ready with excellent tooling and performance
- **Rust**: Maximum safety with zero-cost abstractions
- **Python**: Rapid prototyping and data analysis workflows

### For Mobile/Desktop
- **Swift**: Native iOS/macOS applications
- **C**: Cross-platform foundation for other language bindings

### For System Programming
- **C**: Direct access to all Guillotine features
- **Rust**: Memory safety with performance
- **Zig**: Direct access to the core implementation

## 🚀 Getting Started

Each SDK has its own installation and setup process. Here's a quick overview:

### Quick Start Examples

#### Bun/TypeScript
```bash
cd bun/
bun install @guillotine/bun
# See bun/README.md for full setup
```

#### Go
```bash
cd go/
make install
go mod tidy
# See go/README.md for examples
```

#### Python
```bash
cd python/
pip install guillotine-evm
# See python/README.md for usage
```

#### Rust
```bash
cd rust/
cargo add guillotine-rs
# See rust/README.md for configuration
```

## 🏗️ Architecture Overview

All SDKs follow a similar architectural pattern:

```
SDK Language Interface
         ↓
Language-Specific Bindings
         ↓
C FFI Layer (src/root_c.zig)
         ↓
Guillotine Core (Zig EVM)
```

### Common Features Across SDKs

- **EVM Execution**: Execute Ethereum bytecode with full EVM compatibility
- **State Management**: Manage account balances, storage, and contract code
- **Call Types**: Support for CALL, STATICCALL, DELEGATECALL, CREATE, CREATE2
- **Gas Metering**: Accurate gas calculation and limits
- **Transaction Simulation**: Preview transaction effects without committing state
- **Block Context**: Configure block parameters (number, timestamp, coinbase, etc.)

### Performance Characteristics

- **Zero-copy operations**: Minimal data copying between language boundaries
- **Native Zig performance**: Core EVM execution at near-native speeds
- **Optimized bytecode analysis**: Advanced bytecode fusion and optimization
- **Memory efficiency**: Careful memory management and pooling

## 🔧 Building from Source

### Prerequisites

All SDKs require the Guillotine core library to be built first:

```bash
# From the Guillotine root directory
zig build
# or for maximum performance:
zig build -Doptimize=ReleaseFast
```

### Individual SDK Build

Each SDK has specific build instructions:

- **Bun**: `bun run build`
- **Go**: `make install`
- **Python**: `pip install -e .`
- **Rust**: `cargo build --release`
- **Swift**: `swift build`
- **TypeScript**: `npm run build`

See individual README files for detailed instructions.

## 🧪 Development Status

### Current State (Alpha)

> **⚠️ DO NOT USE IN PRODUCTION**
> 
> All SDKs are currently in experimental/proof-of-concept stage. APIs are unstable and may change significantly.

### What's Working
- Basic EVM execution and state management
- Core opcode support for Ethereum mainnet
- FFI bindings for all supported languages
- Example applications and test suites

### Known Limitations
- APIs are unstable and subject to change
- Limited network support (Ethereum mainnet only)
- Some advanced features may be incomplete
- Documentation is evolving

### Feedback Requested

We're actively seeking feedback from early users:
- **GitHub Issues**: https://github.com/evmts/Guillotine/issues
- **Telegram**: https://t.me/+ANThR9bHDLAwMjUx

## 🔄 API Consistency

While each SDK provides language-idiomatic interfaces, they share common concepts:

### Core Types
- **Address**: 20-byte Ethereum addresses
- **U256/BigInt**: 256-bit integers for values and gas
- **Bytes**: Variable-length byte arrays
- **Hash**: 32-byte hash values

### Execution Model
```
1. Create EVM instance with block configuration
2. Set up account state (balances, code, storage)
3. Execute calls/transactions
4. Inspect results (success, gas usage, outputs, logs)
5. Clean up resources
```

### Error Handling
- Language-appropriate error types
- Detailed error messages and context
- Proper resource cleanup on errors

## 📚 Documentation

- **Individual SDK docs**: See each SDK's README.md
- **Full documentation**: https://guillotine.dev/sdks/
- **API references**: Available in each SDK directory
- **Examples**: Complete working examples in each SDK

## 🤝 Contributing

Contributions are welcome! Please see the main project's contributing guidelines:

1. **Core development**: Contribute to the Zig implementation
2. **SDK improvements**: Enhance language bindings and APIs
3. **Documentation**: Improve examples and documentation
4. **Testing**: Add test cases and benchmarks

### SDK Development Guidelines

- **Idiomatic APIs**: Follow language-specific conventions
- **Type safety**: Provide strong typing where possible
- **Memory safety**: Ensure proper resource management
- **Performance**: Minimize overhead in language bindings
- **Documentation**: Include comprehensive examples

## 📄 License

All SDKs inherit the same license as the main Guillotine project. See the main LICENSE file for details.

## 🗺️ Roadmap

### Beta Goals
- **API Stabilization**: Lock in core APIs across all SDKs
- **Network Support**: Add OP Stack and Arbitrum compatibility  
- **Production Features**: Enhanced error handling, logging, monitoring
- **Performance Optimization**: Further optimize FFI overhead
- **Comprehensive Testing**: Extensive test suites and benchmarks

### Future Considerations
- **Additional Languages**: Java, C#, Kotlin, Ruby
- **Advanced Features**: Debugging tools, profilers, tracers
- **Cloud Integration**: SDK-specific cloud deployment guides
- **Developer Tooling**: Language server protocols, IDE plugins