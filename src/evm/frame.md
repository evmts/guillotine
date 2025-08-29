# Frame

Lightweight execution context for EVM operations.

## Synopsis

```zig
const FrameType = Frame(config);
var frame = try FrameType.init(allocator, gas_remaining, database, caller, value, calldata, block_info, evm_ptr, self_destruct);
const result = try frame.interpret(bytecode);
```

## Description

Frame handles direct opcode execution including stack manipulation, arithmetic, memory access, and storage operations. It serves as the core execution engine for individual EVM operations but does NOT handle program counter tracking, jumps, or external calls (which are managed by Plan and Host/EVM respectively).

## Architecture & Design

### Core Design Principles

1. **Opcode Execution Focus**: Direct execution of individual EVM opcodes with minimal overhead
2. **Stack-Based Operations**: Efficient stack manipulation following EVM specification
3. **Memory Management**: Dynamic memory expansion with gas accounting
4. **Storage Interface**: Clean separation between execution and storage through Database interface
5. **Gas Tracking**: Precise gas consumption accounting for all operations
6. **Modular Configuration**: Compile-time configuration for optimal code generation

### Frame Architecture

```zig
pub fn Frame(comptime config: FrameConfig) type {
    return struct {
        // Execution State
        stack: Stack,                          // EVM stack operations
        gas_remaining: GasType,                // Current gas available
        memory: Memory,                        // EVM memory operations
        
        // External Interfaces
        database: config.DatabaseType,         // Storage access interface
        evm_ptr: *anyopaque,                   // EVM instance pointer
        
        // Execution Context
        caller: Address,                       // Message sender (msg.sender)
        value: WordType,                       // Value being transferred (msg.value)
        calldata: []const u8,                  // Input data (msg.data)
        contract_address: Address,             // Current contract address
        
        // Output Management
        output: []u8,                          // Execution output data
        log_items: [*]Log,                     // Event logs
        
        // Environment
        block_info: BlockInfo,                 // Block-level information
        allocator: std.mem.Allocator,          // Memory allocator
        self_destruct: ?*SelfDestruct,         // SELFDESTRUCT tracking
    };
}
```

### Smart Configuration System

Frame uses intelligent type selection based on configuration parameters:

```zig
pub const FrameConfig = struct {
    stack_size: u16 = 1024,                   // Maximum stack depth
    memory_limit: u32 = 134_217_728,          // 128MB memory limit
    memory_initial_capacity: u32 = 4096,      // Initial memory allocation
    max_bytecode_size: u32 = 24576,           // Maximum contract size (EIP-170)
    max_initcode_size: u32 = 49152,           // Maximum init code size (EIP-3860)
    vector_length: u8 = 64,                   // SIMD optimization width
    
    // Smart type selection for gas tracking
    pub fn GasType(self: FrameConfig) type {
        return i64;  // Signed for efficient underflow detection
    }
    
    // Smart type selection for program counter
    pub fn PcType(self: FrameConfig) type {
        return if (self.max_bytecode_size <= std.math.maxInt(u16))
            u16
        else
            u32;
    }
};
```

### Component Integration

Frame integrates tightly with specialized EVM components:

```zig
// Stack component for EVM stack operations
pub const Stack = stack_mod.Stack(.{
    .stack_size = config.stack_size,
    .WordType = config.WordType,
});

// Memory component for EVM memory management
pub const Memory = memory_mod.Memory(.{
    .initial_capacity = config.memory_initial_capacity,
    .memory_limit = config.memory_limit,
    .owned = true,
});

// Bytecode validation and analysis
pub const Bytecode = bytecode_mod.Bytecode(.{
    .max_bytecode_size = config.max_bytecode_size,
    .max_initcode_size = config.max_initcode_size,
    .vector_length = config.vector_length,
    .fusions_enabled = false,
});
```

## API Reference

### Frame Creation and Management

```zig
// Create Frame instance with execution context
pub fn init(
    allocator: std.mem.Allocator,
    gas_remaining: GasType,
    database: config.DatabaseType,
    caller: Address,
    value: WordType,
    calldata: []const u8,
    block_info: BlockInfo,
    evm_ptr: *anyopaque,
    self_destruct: ?*SelfDestruct
) Error!Self

// Clean up Frame resources
pub fn deinit(self: *Self, allocator: std.mem.Allocator) void

// Configuration examples
const config = FrameConfig{
    .stack_size = 1024,
    .memory_limit = 67_108_864,  // 64MB
    .memory_initial_capacity = 4096,
    .max_bytecode_size = 24576,
    .WordType = u256,
    .DatabaseType = MemoryDatabase,
};

const FrameType = Frame(config);
```

### Execution Context Setup

```zig
// Initialize Frame for contract execution
var frame = try FrameType.init(
    allocator,
    1_000_000,              // gas_remaining
    database,               // storage interface
    caller_address,         // msg.sender
    transfer_value,         // msg.value (in wei)
    input_data,            // msg.data
    block_info,            // block context
    evm_instance,          // EVM pointer for external calls
    self_destruct_list     // SELFDESTRUCT tracking (null for static calls)
);
defer frame.deinit(allocator);
```

### Bytecode Execution

#### Basic Execution

```zig
// Execute bytecode without tracing
pub fn interpret(self: *Self, bytecode_raw: []const u8) Error!Success

// Execute with custom tracer
pub fn interpret_with_tracer(
    self: *Self, 
    bytecode_raw: []const u8, 
    comptime TracerType: ?type, 
    tracer_instance: if (TracerType) |T| *T else void
) Error!Success

// Basic execution example
const contract_code = [_]u8{ 0x60, 0x42, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3 };
const result = try frame.interpret(&contract_code);

switch (result) {
    .Stop => {}, // Normal termination
    .Return => {}, // RETURN opcode executed
    .SelfDestruct => {}, // SELFDESTRUCT opcode executed
}
```

#### Execution Results

```zig
pub const Success = enum {
    Stop,         // STOP opcode - normal termination
    Return,       // RETURN opcode - return with data
    SelfDestruct, // SELFDESTRUCT opcode - contract destruction
};

pub const Error = error{
    StackOverflow,      // Stack exceeded maximum depth
    StackUnderflow,     // Stack underflow during pop operation
    REVERT,            // REVERT opcode executed
    BytecodeTooLarge,  // Bytecode exceeds size limits
    AllocationError,   // Memory allocation failure
    InvalidJump,       // JUMP to invalid destination
    InvalidOpcode,     // Undefined or unsupported opcode
    OutOfBounds,       // Memory or storage access violation
    OutOfGas,          // Insufficient gas for operation
    GasOverflow,       // Gas calculation overflow
    InvalidAmount,     // Invalid value amount
    WriteProtection,   // Write operation in static context
};
```

### Gas Management

```zig
// Consume gas with overflow checking
pub fn consumeGasChecked(self: *Self, amount: u64) Error!void

// Consume gas without checking (for pre-validated operations)
pub fn consumeGasUnchecked(self: *Self, amount: u64) void

// Gas consumption examples
try frame.consumeGasChecked(3);           // Basic arithmetic operation
try frame.consumeGasChecked(375);         // Keccak256 hash operation
try frame.consumeGasChecked(20000);       // Storage write (SSTORE)

// Check remaining gas
if (frame.gas_remaining < minimum_required) {
    return Error.OutOfGas;
}
```

### Stack Operations

Frame provides direct access to the EVM stack through the stack component:

```zig
// Stack manipulation (used internally by opcode handlers)
const a = frame.stack.pop_unsafe();       // Remove top item
const b = frame.stack.peek_unsafe();      // View top item without removing
frame.stack.push_unsafe(result);          // Add new item
frame.stack.set_top_unsafe(value);        // Modify top item in place

// Safe stack operations with bounds checking
const value = try frame.stack.pop();
try frame.stack.push(new_value);

// Stack introspection
const depth = frame.stack.len();
const is_empty = frame.stack.is_empty();
const capacity = frame.stack.capacity();
```

### Memory Operations

```zig
// Memory access and expansion
const data = try frame.memory.get_slice(offset, length);
try frame.memory.set_data(offset, data);

// Memory expansion with gas costs
const expansion_cost = frame.memory.expansion_cost(new_size);
try frame.consumeGasChecked(expansion_cost);
try frame.memory.expand_to_size(new_size);

// Memory size tracking
const current_size = frame.memory.size();
const next_word_boundary = frame.memory.next_word_multiple(size);
```

### Storage Interface

```zig
// Storage operations through database interface
const current_value = try frame.database.get_storage(contract_address, key);
try frame.database.set_storage(contract_address, key, new_value);

// Account operations
const account = try frame.database.get_account(address);
const balance = account.balance;
const nonce = account.nonce;
const code = try frame.database.get_code(address);
```

### Output Management

```zig
// Set execution output data
pub fn setOutput(self: *Self, data: []const u8) Error!void

// Get current output
pub fn getOutput(self: *const Self) []const u8

// Usage examples
try frame.setOutput(return_data);         // RETURN opcode
const result_data = frame.getOutput();    // Retrieve output after execution
```

### Log Management

```zig
// Add event logs
pub fn appendLog(self: *Self, allocator: std.mem.Allocator, log_entry: Log) error{OutOfMemory}!void

// Retrieve logs
pub fn getLogSlice(self: *const Self) []const Log
pub fn getLogCount(self: *const Self) u16

// Log management
pub fn deinitLogs(self: *Self, allocator: std.mem.Allocator) void

// Usage example
const log_entry = Log{
    .address = contract_address,
    .topics = &[_]u256{ event_signature, indexed_param1 },
    .data = event_data,
};
try frame.appendLog(allocator, log_entry);
```

## Opcode Handler Architecture

### Handler Pattern

Frame uses a function pointer table for efficient opcode dispatch:

```zig
// Opcode handler signature
pub const OpcodeHandler = *const fn (frame: *Self, dispatch: Dispatch) Error!Success;

// Handler table (256 entries for all possible opcodes)
pub const opcode_handlers: [256]OpcodeHandler = stack_frame_handlers.getOpcodeHandlers(Self);

// Example handler implementation
pub fn add(frame: *Self, dispatch: Dispatch) Error!Success {
    const b = frame.stack.pop_unsafe();
    const a = frame.stack.pop_unsafe();
    const result = a +% b;  // Wrapping addition
    frame.stack.push_unsafe(result);
    
    // Continue execution
    return dispatch.next().opcode_handler(frame, dispatch.advance());
}
```

### Handler Categories

Frame implements handlers for all EVM opcode categories:

```zig
// Arithmetic Operations (0x01-0x0b)
// ADD, MUL, SUB, DIV, SDIV, MOD, SMOD, ADDMOD, MULMOD, EXP, SIGNEXTEND

// Comparison Operations (0x10-0x1d)  
// LT, GT, SLT, SGT, EQ, ISZERO, AND, OR, XOR, NOT, BYTE, SHL, SHR, SAR

// Keccak256 Operations (0x20)
// KECCAK256

// Environment Information (0x30-0x3f)
// ADDRESS, BALANCE, ORIGIN, CALLER, CALLVALUE, CALLDATALOAD, etc.

// Block Information (0x40-0x48)
// BLOCKHASH, COINBASE, TIMESTAMP, NUMBER, PREVRANDAO, GASLIMIT, etc.

// Storage Operations (0x50-0x5f)
// POP, MLOAD, MSTORE, MSTORE8, SLOAD, SSTORE, JUMP, JUMPI, etc.

// Push Operations (0x60-0x7f)
// PUSH1, PUSH2, ..., PUSH32

// Duplicate Operations (0x80-0x8f)
// DUP1, DUP2, ..., DUP16

// Swap Operations (0x90-0x9f)
// SWAP1, SWAP2, ..., SWAP16

// Log Operations (0xa0-0xa4)
// LOG0, LOG1, LOG2, LOG3, LOG4

// System Operations (0xf0-0xff)
// CREATE, CALL, CALLCODE, RETURN, DELEGATECALL, CREATE2, STATICCALL, REVERT, SELFDESTRUCT
```

## Performance Characteristics

### Memory Layout Optimization

Frame is carefully designed for cache efficiency:

```zig
// Hot path fields grouped together (first 64 bytes)
stack: Stack,                    // 16 bytes - Most frequently accessed
gas_remaining: GasType,          // 8 bytes - Checked on every operation  
memory: Memory,                  // 16 bytes - Memory operations
database: config.DatabaseType,   // 8 bytes - Storage interface
log_items: [*]Log,              // 8 bytes - Event logging
evm_ptr: *anyopaque,            // 8 bytes - EVM instance

// Context fields (next cache line)
value: WordType,                // 32 bytes - Call value
caller: Address,                // 20 bytes - Caller address
contract_address: Address,      // 20 bytes - Contract address

// Less frequently accessed fields
calldata: []const u8,           // 16 bytes - Input data
output: []u8,                   // 16 bytes - Output buffer
allocator: std.mem.Allocator,   // 16 bytes - Allocator
block_info: BlockInfo,          // ~188 bytes - Block context
```

### Execution Performance

1. **Zero-Cost Abstraction**: Compile-time configuration eliminates runtime overhead
2. **Handler Table Dispatch**: O(1) opcode lookup using function pointers
3. **Unsafe Operations**: Pre-validated operations use `_unsafe` variants for speed
4. **Branch Prediction**: Cold branch hints for error conditions
5. **Memory Pooling**: Reuse of allocations where possible

```zig
// Performance-critical operations use unsafe variants after validation
if (frame.stack.len() >= 2) {  // Bounds check once
    const b = frame.stack.pop_unsafe();   // No bounds check
    const a = frame.stack.pop_unsafe();   // No bounds check
    frame.stack.push_unsafe(a + b);       // No bounds check
}
```

### Gas Accounting Performance

```zig
// Efficient gas tracking with signed integers
gas_remaining: GasType,  // i64 for efficient underflow detection

// Fast underflow check
pub fn consumeGasChecked(self: *Self, amount: u64) Error!void {
    const amt = std.math.cast(GasType, amount) orelse return Error.OutOfGas;
    self.gas_remaining -= amt;
    if (self.gas_remaining < 0) return Error.OutOfGas;  // Single comparison
}
```

## Testing

### Test Coverage

Frame testing covers comprehensive functionality:

1. **Opcode Execution**: All 256 opcodes with various inputs and edge cases
2. **Stack Operations**: Overflow, underflow, and capacity management
3. **Memory Operations**: Expansion, access patterns, and gas costs
4. **Storage Interface**: Database interactions and error handling
5. **Gas Accounting**: Consumption, overflow, and underflow scenarios
6. **Error Handling**: All error conditions and recovery patterns
7. **Configuration**: Different configuration options and type selection

### Test Execution

```bash
# Run all Frame tests
zig build test

# Run Frame-specific tests  
zig build test -- --test-filter "Frame"

# Debug logging during tests
const test_config = FrameConfig{
    .stack_size = 256,
    .memory_limit = 1048576,  // 1MB for testing
    .WordType = u256,
    .DatabaseType = MemoryDatabase,
};
```

### Critical Test Scenarios

```zig
test "Frame arithmetic operations" {
    const allocator = std.testing.allocator;
    const config = FrameConfig{};
    const FrameType = Frame(config);
    
    // Setup test environment
    var db = MemoryDatabase.init(allocator);
    defer db.deinit();
    
    var frame = try FrameType.init(
        allocator,
        1000000,              // gas
        db.to_database_interface(),
        caller_address,
        0,                    // value
        &.{},                 // calldata
        test_block_info,
        test_evm_ptr,
        null                  // self_destruct
    );
    defer frame.deinit(allocator);
    
    // Test ADD operation: PUSH1 2, PUSH1 3, ADD
    const bytecode = [_]u8{ 0x60, 0x02, 0x60, 0x03, 0x01 };
    const result = try frame.interpret(&bytecode);
    
    // Verify result
    try std.testing.expectEqual(Frame.Success.Stop, result);
    try std.testing.expectEqual(@as(u256, 5), frame.stack.peek_unsafe());
}

test "Frame memory expansion" {
    // ... test memory operations and gas costs
}

test "Frame gas accounting" {
    // ... verify precise gas consumption
}

test "Frame error conditions" {
    // ... test all error scenarios
}
```

## Context within EVM

### Integration with EVM Execution

Frame serves as the core execution engine within the broader EVM architecture:

```zig
// EVM creates and manages Frame instances for bytecode execution
const frame_result = try evm.execute_frame(
    contract_code,
    input_data,
    gas_limit,
    contract_address,
    caller_address,
    value_amount,
    is_static_call,
    snapshot_id
);

// EVM handles Frame results and manages state transitions
switch (frame_result) {
    .Stop => return CallResult.success(gas_left, output),
    .Return => return CallResult.success_with_output(gas_left, output),
    .SelfDestruct => {
        try evm.self_destruct.mark(contract_address, beneficiary);
        return CallResult.success(gas_left, &.{});
    },
}
```

### Plan Integration

Frame execution is coordinated with the Plan component for program control:

```zig
// Plan manages program counter and jump destinations
// Frame executes individual opcodes as directed by Plan

// Dispatch provides the coordination interface
pub const Dispatch = struct {
    cursor: [*]const DispatchEntry,
    jump_table: *const JumpTable,
    
    pub fn next(self: Dispatch) DispatchEntry {
        return self.cursor[0];
    }
    
    pub fn advance(self: Dispatch) Dispatch {
        return Dispatch{ .cursor = self.cursor + 1, .jump_table = self.jump_table };
    }
};
```

### Host Interface Integration

Frame delegates external operations to the EVM through the Host interface:

```zig
// Frame uses EVM pointer for external calls
pub inline fn getEvm(self: *const Self) *DefaultEvm {
    return @as(*DefaultEvm, @ptrCast(@alignCast(self.evm_ptr)));
}

// External operations handled by EVM:
// - Inner calls (CALL, DELEGATECALL, STATICCALL)
// - Contract creation (CREATE, CREATE2)  
// - Environment queries (BALANCE, EXTCODESIZE, etc.)
// - Block information access
```

### Database Integration

Frame coordinates with the database for state access:

```zig
// Storage operations
const value = try frame.database.get_storage(address, key);
try frame.database.set_storage(address, key, new_value);

// Account operations
const account = try frame.database.get_account(address);
const code = try frame.database.get_code(address);
```

## EVM Specification Compliance

### Opcode Semantics

Frame implements exact EVM opcode semantics:

1. **Stack Operations**: Precise stack manipulation following EVM specification
2. **Arithmetic**: Wrapping arithmetic and modular operations  
3. **Memory**: Dynamic expansion with quadratic gas costs
4. **Storage**: Persistent storage with gas refund mechanisms
5. **Control Flow**: JUMP/JUMPI with destination validation
6. **Logging**: Event emission with indexed topics

### Gas Model Accuracy

```zig
// Gas costs match EVM specification exactly
const ADD_GAS = 3;
const MUL_GAS = 5;
const SSTORE_SET_GAS = 20000;
const SSTORE_RESET_GAS = 5000;

// Dynamic gas costs
const memory_expansion_cost = (new_size * new_size) / 512 - (old_size * old_size) / 512;
const keccak_gas = 30 + 6 * ((data.len + 31) / 32);
```

### Hard Fork Support

Frame supports all major Ethereum hard fork changes:

```zig
// EIP-150: Gas cost changes
// EIP-158: State clearing
// EIP-161: State trie clearing
// EIP-214: STATICCALL opcode
// EIP-1283: SSTORE gas changes  
// EIP-1344: CHAINID opcode
// EIP-1884: Gas cost increases
// EIP-2200: SSTORE gas changes
// EIP-3529: Gas refund reductions
// EIP-3541: Reject contracts starting with 0xEF
// EIP-3855: PUSH0 opcode
```

### Error Handling Compliance

```zig
// Frame provides comprehensive error handling for all EVM failure modes
pub const Error = error{
    StackOverflow,       // Stack depth exceeds 1024
    StackUnderflow,      // Pop from empty stack
    REVERT,             // REVERT opcode execution
    BytecodeTooLarge,   // Contract size exceeds limits
    AllocationError,    // Memory allocation failure
    InvalidJump,        // JUMP to invalid destination
    InvalidOpcode,      // Undefined opcode (0x0c-0x0f, etc.)
    OutOfBounds,        // Memory/storage access violation
    OutOfGas,          // Insufficient gas for operation
    GasOverflow,       // Gas calculation overflow
    InvalidAmount,     // Invalid numeric amount
    WriteProtection,   // Write in static context
};
```

### Predefined Configurations

```zig
// Standard Ethereum configuration
const ethereum_config = FrameConfig{
    .stack_size = 1024,           // EVM specification
    .memory_limit = 134_217_728,   // 128MB reasonable limit
    .max_bytecode_size = 24576,    // EIP-170
    .max_initcode_size = 49152,    // EIP-3860
    .WordType = u256,             // Standard EVM word size
};

// Performance-optimized configuration
const fast_config = FrameConfig{
    .stack_size = 1024,
    .memory_limit = 67_108_864,    // 64MB
    .memory_initial_capacity = 8192,
    .vector_length = 128,          // Larger SIMD width
    .WordType = u256,
};

// Size-optimized configuration
const small_config = FrameConfig{
    .stack_size = 512,             // Reduced stack
    .memory_limit = 16_777_216,    // 16MB
    .memory_initial_capacity = 1024,
    .max_bytecode_size = 12288,    // Smaller contracts
    .WordType = u256,
};
```

Frame serves as the foundational execution engine for EVM operations, providing efficient, specification-compliant opcode execution while maintaining clean architectural boundaries with the broader EVM system components.