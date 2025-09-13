# Frame Module

## Overview

The Frame module provides the lightweight execution context for EVM operations in Guillotine. It serves as the core orchestrator for opcode execution, handling direct instruction dispatch including stack manipulation, arithmetic operations, memory access, and storage operations.

The Frame is designed with clear separation of concerns:
- **Frame**: Handles opcode execution and state management
- **Dispatch**: Manages bytecode preprocessing and opcode dispatch (integrated)  
- **Host/EVM**: Manages CALL/CREATE operations (external)
- **Environment**: Provides context queries (external)

## Core Components

### Primary Files

- **`frame.zig`** - Main Frame implementation with opcode dispatch, dispatch cache, and execution context
- **`frame_config.zig`** - Configuration options for stack size, memory limits, gas tracking, and platform optimizations
- **`frame_handlers.zig`** - Handler registration, opcode dispatch management, and tracing support
- **`call_params.zig`** - Parameter structures for EVM calls (CALL, CALLCODE, DELEGATECALL, STATICCALL, CREATE, CREATE2)
- **`call_result.zig`** - Result structures for EVM call returns with comprehensive state tracking
- **`block_info_config.zig`** - Block-level configuration for difficulty and base fee types

### Testing and Integration

- `frame_tests.zig` — Comprehensive test suite covering frame operations
- `frame_c.zig` — C interface bindings for external integration
- `frame_bench.zig` — Performance benchmarks for frame operations

## Key Data Structures

### Frame Structure
The Frame is a compile-time parameterized type that adapts to configuration:

```zig
pub fn Frame(comptime config: FrameConfig) type {
    return struct {
        // CACHE LINE 1 (0-63 bytes) - ULTRA HOT PATH
        stack: Stack,                    // 16B - Stack operations
        gas_remaining: GasType,          // 8B - Gas tracking (i32/i64)
        memory: Memory,                  // 16B - Memory operations
        dispatch: Dispatch,              // 16B - Dispatch cursor and metadata
        database: config.DatabaseType,  // 8B - Storage access
        
        // CACHE LINE 2 (64-127 bytes) - WARM PATH
        value: *const WordType,                   // 8B - Call value (pointer)
        evm_ptr: *anyopaque,                     // 8B - EVM instance pointer
        length_prefixed_calldata: ?[*]const u8,  // 8B - Calldata pointer
        caller: Address,                         // 20B - Calling address
        contract_address: Address,               // 20B - Current contract
        
        // CACHE LINE 3+ (128+ bytes) - COLD PATH
        output: []u8,                           // 16B - Output data slice
        code: []const u8,                       // 16B - Contract code
        u256_constants: []const WordType,       // 16B - Dispatch constants
        authorized_address: ?Address,           // 21B - EIP-3074 auth
        jump_table: *const JumpTable,           // 8B - Jump validation
    };
}
```

### Global Dispatch Cache
A thread-safe LRU cache for bytecode dispatch schedules:

```zig
const DispatchCache = struct {
    entries: [256]?DispatchCacheEntry,
    hits: u64,
    misses: u64,
    mutex: std.Thread.Mutex,
    
    fn lookup(bytecode: []const u8) ?CachedDispatch;
    fn insert(bytecode: []const u8, schedule: []const u8, jump_table: []const u8) !void;
    fn getStatistics() CacheStats;
};
```

### Call Parameters
The module defines a comprehensive tagged union for all EVM call types:

```zig
pub fn CallParams(comptime config: anytype) type {
    return union(enum) {
        call: struct { caller: Address, to: Address, value: u256, input: []const u8, gas: u64 },
        callcode: struct { caller: Address, to: Address, value: u256, input: []const u8, gas: u64 },
        delegatecall: struct { caller: Address, to: Address, input: []const u8, gas: u64 },
        staticcall: struct { caller: Address, to: Address, input: []const u8, gas: u64 },
        create: struct { caller: Address, value: u256, init_code: []const u8, gas: u64 },
        create2: struct { caller: Address, value: u256, init_code: []const u8, salt: u256, gas: u64 },
        
        pub fn getGas(self: @This()) u64;
        pub fn setGas(self: *@This(), gas: u64) void;
        pub fn getCaller(self: @This()) Address;
        pub fn hasValue(self: @This()) bool;
        pub fn isReadOnly(self: @This()) bool;
        pub fn isCreate(self: @This()) bool;
        pub fn clone(self: @This(), allocator: std.mem.Allocator) !@This();
        pub fn validate(self: @This()) ValidationError!void;
    };
}
```

### Call Results
Comprehensive result structures with memory management:

```zig
pub fn CallResult(comptime config: anytype) type {
    return struct {
        success: bool,
        gas_left: u64,
        output: []const u8,
        logs: []const Log = &.{},
        selfdestructs: []const SelfDestructRecord = &.{},
        accessed_addresses: []const Address = &.{},
        accessed_storage: []const StorageAccess = &.{},
        trace: ?ExecutionTrace = null,
        error_info: ?[]const u8 = null,
        created_address: ?Address = null,
        
        pub fn success_with_output(gas_left: u64, output: []const u8) @This();
        pub fn failure_with_error(gas_left: u64, error_info: []const u8) @This();
        pub fn revert_with_data(gas_left: u64, revert_data: []const u8) @This();
        pub fn toOwnedResult(self: @This(), allocator: std.mem.Allocator) !@This();
        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void;
        pub fn gasConsumed(self: @This(), original_gas: u64) u64;
    };
}
```

## Architecture and Performance

### Frame Configuration System
The Frame uses compile-time configuration for optimal performance:

```zig
pub const FrameConfig = struct {
    stack_size: u12 = 1024,                    // Maximum stack size
    WordType: type = u256,                     // EVM word type (u256/u128/etc.)
    max_bytecode_size: u32 = 24576,           // Maximum contract code size
    memory_limit: u64 = 0xFFFFFF,             // Memory expansion limit
    DatabaseType: type,                        // Storage backend (required)
    TracerType: ?type = null,                  // Optional execution tracer
    disable_gas_checks: bool = false,          // For testing/development
    disable_fusion: bool = false,              // Disable bytecode optimization
    vector_length: comptime_int = 1,           // SIMD vector length
    
    pub fn PcType(comptime self: Self) type;   // Auto-sized PC type (u8-u32)
    pub fn GasType(comptime self: Self) type;  // Auto-sized gas type (i32/i64)
    pub fn StackIndexType(comptime self: Self) type; // Auto-sized stack index
};
```

### Dispatch Cache Optimization
- **Global LRU Cache**: Thread-safe dispatch schedule caching (256 entries)
- **Bytecode Keys**: Direct bytecode comparison for cache lookup
- **Jump Table Caching**: Pre-computed JUMP/JUMPI destination validation
- **Reference Counting**: Safe concurrent access to cached data
- **Statistics Tracking**: Cache hit/miss monitoring for performance tuning

### Memory Layout Optimization
- **Cache Line Organization**: Hot path data fits in first 64 bytes
- **SIMD Support**: Configurable vector operations for arithmetic/bitwise ops
- **Zero-Copy Operations**: Direct bytecode and calldata access
- **Arena Allocation**: Temporary data allocated from EVM call arena

### Handler System
- **Static Dispatch**: Compile-time handler registration (256 handlers)
- **Synthetic Opcodes**: Bytecode fusion for common patterns (PUSH+ADD, etc.)
- **Tail Call Optimization**: Platform-aware tail call modifiers
- **Tracing Integration**: Zero-cost abstraction for execution tracing

## Usage Examples

### Basic Frame Configuration and Initialization
```zig
const FrameConfig = @import("frame_config.zig").FrameConfig;
const MemoryDatabase = @import("../storage/memory_database.zig").MemoryDatabase;

// Configure frame with custom parameters
const config = FrameConfig{
    .stack_size = 1024,
    .WordType = u256,
    .max_bytecode_size = 24576,
    .memory_limit = 0x100000, // 1MB
    .DatabaseType = MemoryDatabase,
    .TracerType = null, // No tracing
    .disable_gas_checks = false,
    .vector_length = 1, // No SIMD
};

// Create Frame type from config
const MyFrame = @import("frame.zig").Frame(config);

// Initialize global dispatch cache for performance
@import("frame.zig").initGlobalCache(allocator);
defer @import("frame.zig").deinitGlobalCache();

// Initialize frame instance
var database = MemoryDatabase.init(allocator);
defer database.deinit();

const call_value: u256 = 0;
var frame = try MyFrame.init(
    allocator,
    100_000, // gas_remaining
    database,
    caller_address,
    &call_value,
    call_data,
    evm_ptr
);
defer frame.deinit(allocator);
```

### Executing Bytecode with Tracing
```zig
// Configure frame with debugging tracer
const DebugConfig = FrameConfig{
    .DatabaseType = MemoryDatabase,
    .TracerType = MyDebugTracer,
    // ... other config
};
const DebugFrame = @import("frame.zig").Frame(DebugConfig);

var tracer = MyDebugTracer.init();
var frame = try DebugFrame.init(/* ... */);

// Execute with tracing
try frame.interpret_with_tracer(bytecode, MyDebugTracer, &tracer);
```

### Working with Call Parameters and Results
```zig
const CallParams = @import("call_params.zig").CallParams(config);
const CallResult = @import("call_result.zig").CallResult(config);

// Create call parameters
const call_params = CallParams{ .call = .{
    .caller = caller_address,
    .to = contract_address,
    .value = 1000,
    .input = call_data,
    .gas = 21000,
} };

// Validate parameters
try call_params.validate();

// After execution, handle results
const result = CallResult.success_with_output(18500, return_data);
const gas_consumed = result.gasConsumed(21000); // 2500
const has_output = result.hasOutput(); // true

// Create owned copy for long-term storage
const owned_result = try result.toOwnedResult(allocator);
defer {
    var mutable_result = owned_result;
    mutable_result.deinit(allocator);
}
```

## Integration Notes

### With EVM Module
The Frame integrates with the main EVM via opaque pointers and arena allocation:
- **Arena Allocator**: All temporary Frame data uses EVM's call-scoped arena
- **Context Access**: Frame accesses EVM context through `getEvm()` method
- **Opaque Pointers**: Type-erased EVM reference for compile-time flexibility

### With Dispatch Module
Frame includes integrated dispatch preprocessing:
- **Bytecode Analysis**: One-pass validation and analysis during dispatch creation
- **Schedule Generation**: Compile-time optimized instruction sequences
- **Jump Table**: Pre-computed destination validation for JUMP/JUMPI

### With Storage Module  
Frame coordinates with configurable storage backends:
- **Generic Database**: `config.DatabaseType` allows pluggable storage
- **Direct Access**: Hot-path storage operations bypass abstraction layers
- **Transaction Context**: Frame manages storage through database interface

### With Handler System
Modular opcode handler organization:
- **Standard Handlers**: Basic EVM opcodes in separate modules
- **Synthetic Handlers**: Fusion optimizations for common patterns
- **Tracing Handlers**: Zero-cost wrapper for execution monitoring
- **Platform Optimization**: Tail-call and SIMD optimizations where supported

## Error Handling

The Frame uses Zig's error union system with execution-specific error types:

```zig
pub const Error = error{
    StackOverflow,        // Stack exceeds configured limit
    StackUnderflow,       // Pop from empty stack
    REVERT,               // Contract reverted execution
    BytecodeTooLarge,     // Bytecode exceeds max_bytecode_size
    AllocationError,      // Memory allocation failed
    InvalidJump,          // Jump to invalid destination
    InvalidOpcode,        // Unrecognized opcode
    OutOfBounds,          // Memory/storage access bounds violation
    OutOfGas,             // Insufficient gas for operation
    GasOverflow,          // Gas calculation overflow
    InvalidAmount,        // Invalid value/amount parameter
    WriteProtection,      // Write operation in read-only context
    
    // Success termination cases (not actual errors)
    Stop,                 // Normal execution stop
    Return,               // Contract returned
    SelfDestruct,         // Contract self-destructed
};
```

### Error Handling Patterns
- **Automatic Cleanup**: Defer patterns ensure resource cleanup on errors
- **Gas Accounting**: Out-of-gas errors properly account for consumed gas
- **Context Preservation**: Error state maintains execution context for debugging
- **Memory Safety**: Arena allocation prevents memory leaks on error paths

### Debugging Support
- **Pretty Print**: Comprehensive frame state visualization with ANSI colors
- **Execution Tracing**: Optional zero-cost tracing for debugging and analysis
- **Cache Statistics**: Performance monitoring of dispatch cache effectiveness

## C API Integration

The frame module provides C bindings for external integration:

```c
// Error codes
#define EVM_SUCCESS 0
#define EVM_ERROR_OUT_OF_GAS -3
#define EVM_ERROR_INVALID_OPCODE -5

// Frame operations through C API
typedef struct frame_c_api {
    int (*init)(/* parameters */);
    int (*interpret)(/* bytecode */);
    void (*deinit)(void);
} FrameAPI;
```

For detailed C API usage, see `frame_c.zig` for the complete interface.
