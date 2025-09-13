# Stack Module

## Overview

The Stack module provides a high-performance EVM stack implementation with pointer-based operations and downward growth for optimal CPU cache performance. The stack supports up to 4095 elements with configurable word types (defaults to 1024 u256 words per EVM specification) and provides both safe and unsafe operation variants.

Key features include 64-byte cache line alignment, automatic index type selection based on capacity (u4/u8/u12), zero-cost abstractions through compile-time configuration, bytecode fusion support, and comprehensive bounds checking for memory safety.

## Core Components

### Primary Files

- **`stack.zig`** - Core stack implementation with pointer-based downward growth
- **`stack_config.zig`** - Configuration options for stack size, word type, and fusion settings  
- **`stack_c.zig`** - C FFI interface with lifecycle, push/pop, and bulk operations
- **`stack_bench.zig`** - Performance benchmarks comparing with REVM and direct operations

## Key Data Structures

### Stack Structure
```zig
pub fn Stack(comptime config: StackConfig) type {
    return struct {
        pub const WordType = config.WordType;
        pub const IndexType = config.StackIndexType();
        pub const stack_capacity = config.stack_size;

        pub const Error = error{
            StackOverflow,
            StackUnderflow,
            AllocationError,
        };

        const Self = @This();

        // Ownership: pointer to aligned memory returned by alignedAlloc
        buf_ptr: [*]align(64) WordType,

        // Downward stack growth: stack_ptr points to next empty slot
        // Push: *stack_ptr = value; stack_ptr -= 1;
        // Pop: stack_ptr += 1; return *stack_ptr;
        stack_ptr: [*]WordType,
    };
}
```

### Stack Configuration
```zig
pub const StackConfig = struct {
    stack_size: u12 = 1024,         // Maximum 4095, EVM standard 1024
    WordType: type = u256,           // Up to u512 supported
    fusions_enabled: bool = true,    // Enable opcode fusion optimizations

    pub fn StackIndexType(comptime self: StackConfig) type {
        return if (self.stack_size <= std.math.maxInt(u4))
            u4
        else if (self.stack_size <= std.math.maxInt(u8))
            u8
        else if (self.stack_size <= std.math.maxInt(u12))
            u12
        else
            @compileError("StackConfig stack_size is too large!");
    }
    
    pub fn validate(comptime self: StackConfig) void {
        if (self.stack_size > 4095) @compileError("stack_size cannot exceed 4095");
        if (@bitSizeOf(self.WordType) > 512) @compileError("WordType cannot exceed u512");
    }
};
```

## Performance Considerations

### Downward Growth Pattern
Stack grows downward for optimal cache locality and branch prediction:
```zig
// Push operation (fast path)
pub inline fn push(self: *Self, value: WordType) Error!void {
    if (@intFromPtr(self.stack_ptr) <= @intFromPtr(self.stack_limit())) {
        return Error.StackOverflow;
    }
    self.push_unsafe(value);
}

// Pop operation (fast path)  
pub inline fn pop(self: *Self) Error!WordType {
    if (@intFromPtr(self.stack_ptr) >= @intFromPtr(self.stack_base())) {
        return Error.StackUnderflow;
    }
    return self.pop_unsafe();
}
```

### Cache Line Alignment
Stack memory is allocated with 64-byte alignment for optimal CPU cache utilization:
```zig
pub fn init(allocator: std.mem.Allocator) Error!Self {
    const memory = allocator.alignedAlloc(WordType, @enumFromInt(6), stack_capacity) catch return Error.AllocationError;
    errdefer allocator.free(memory);

    const base_ptr: [*]align(64) WordType = memory.ptr;

    return Self{
        .buf_ptr = base_ptr,
        .stack_ptr = base_ptr + stack_capacity,  // Start at end (empty)
    };
}
```

### Unsafe Operations
Performance-critical paths use unsafe variants with assertion-based validation:
```zig
pub inline fn push_unsafe(self: *Self, value: WordType) void {
    @branchHint(.likely);
    std.debug.assert(@intFromPtr(self.stack_ptr) > @intFromPtr(self.stack_limit()));
    self.stack_ptr -= 1;
    self.stack_ptr[0] = value;
}

pub inline fn pop_unsafe(self: *Self) WordType {
    @branchHint(.likely);
    std.debug.assert(@intFromPtr(self.stack_ptr) < @intFromPtr(self.stack_base()));
    const value = self.stack_ptr[0];
    self.stack_ptr += 1;
    return value;
}
```

### Index Type Optimization
Stack uses optimal index types based on capacity:
```zig
// Automatically selects smallest type: u4 (≤15), u8 (≤255), u12 (≤4095)
pub fn StackIndexType(comptime self: StackConfig) type {
    return if (self.stack_size <= std.math.maxInt(u4))
        u4
    else if (self.stack_size <= std.math.maxInt(u8))
        u8
    else if (self.stack_size <= std.math.maxInt(u12))
        u12
    else
        @compileError("StackConfig stack_size is too large!");
}
```

## Usage Examples

### Basic Stack Operations
```zig
const StackConfig = @import("stack_config.zig").StackConfig;
const Stack = @import("stack.zig").Stack;

// Configure stack for EVM
const config = StackConfig{
    .stack_size = 1024,
    .WordType = u256,
    .fusions_enabled = true,
};

const StackType = Stack(config);
var stack = try StackType.init(allocator);
defer stack.deinit(allocator);

// Push values onto stack
try stack.push(0x123456789ABCDEF);
try stack.push(0xFEDCBA987654321);

// Pop values from stack (LIFO order)
const value1 = try stack.pop(); // 0xFEDCBA987654321
const value2 = try stack.pop(); // 0x123456789ABCDEF
```

### Stack Inspection
```zig
// Push some test values
try stack.push(100);
try stack.push(200);
try stack.push(300);

// Peek at top without removing
const top = try stack.peek(); // Returns 300
std.debug.assert(top == 300);
std.debug.assert(stack.size() == 3); // Size unchanged

// Access stack contents via slice (0 = top, 1 = second, etc.)
const slice = stack.get_slice();
const second = slice[1]; // Returns 200
const third = slice[2];  // Returns 100
```

### Stack Manipulation
```zig
// Set top value directly  
try stack.push(42);
try stack.set_top(99); // Changes top from 42 to 99

// Duplicate values (DUP operations)
try stack.push(123);
try stack.push(456);
try stack.dup1(); // Duplicate top item (456) to top
// Stack now: [456, 456, 123, ...]

// Generic DUP operations
try stack.dup_n(2); // Duplicate 2nd item from top

// Swap values (SWAP operations)
try stack.push(111);
try stack.push(222);
try stack.swap1(); // Swap top two items
// Stack now: [111, 222, ...]

// Generic SWAP operations
try stack.swap_n(3); // Swap top with 3rd item from top
```

### Unsafe Operations (Performance Critical)
```zig
// In performance-critical code with pre-validated conditions
std.debug.assert(stack.size() >= 2); // Ensure sufficient items

const b = stack.pop_unsafe();   // No bounds checking
const a = stack.peek_unsafe();  // No bounds checking
const result = a + b;
stack.set_top_unsafe(result);   // No bounds checking
```

### Optimized Binary Operations
For arithmetic operations, the stack provides an optimized binary operation function:
```zig
// Optimized for arithmetic operations like ADD, MUL, SUB, DIV
// Pops top item, applies operation with second item, replaces second with result
pub inline fn binary_op_unsafe(self: *Self, comptime op: fn(a: WordType, b: WordType) WordType) void {
    @branchHint(.likely);
    std.debug.assert(@intFromPtr(self.stack_ptr) + @sizeOf(WordType) < @intFromPtr(self.stack_base()));
    const top = self.stack_ptr[0];
    const second = self.stack_ptr[1];
    self.stack_ptr[1] = op(top, second);
    self.stack_ptr += 1;
}

// Usage example in arithmetic handlers:
stack.binary_op_unsafe(struct {
    fn add(a: u256, b: u256) u256 { return a +% b; }
}.add);
```

### Batch Operations
```zig
// Push multiple values efficiently
const values = [_]u256{100, 200, 300, 400};
for (values) |value| {
    try stack.push(value);
}

// Pop multiple values
var results: [4]u256 = undefined;
var i: usize = 0;
while (i < 4) : (i += 1) {
    results[i] = try stack.pop();
}
```

## EVM Integration

### Opcode Support
Stack operations directly support EVM opcodes:

#### PUSH Operations
PUSH operations are handled by instruction handlers, not directly by the stack. The stack provides push methods:
```zig
// Basic push (with overflow check)
try stack.push(value);

// Unsafe push (no bounds check, assertions only)
stack.push_unsafe(value);
```

#### DUP Operations  
```zig
// Generic DUP implementation (DUP1-DUP16)
pub fn dup_n(self: *Self, n: u8) Error!void {
    const current_elements = self.size_internal();
    if (current_elements < n) return Error.StackUnderflow;
    if (@intFromPtr(self.stack_ptr) <= @intFromPtr(self.stack_limit())) return Error.StackOverflow;
    
    const value = self.stack_ptr[n - 1];  // nth-from-top at index n-1
    self.push_unsafe(value);
}

// Individual DUP functions (DUP1-DUP16)
pub fn dup1(self: *Self) Error!void { return self.dup_n(1); }
pub fn dup2(self: *Self) Error!void { return self.dup_n(2); }
// ... dup3-dup16 similarly implemented
```

#### SWAP Operations
```zig
// Generic SWAP implementation (SWAP1-SWAP16)
pub fn swap_n(self: *Self, n: u8) Error!void {
    const current_elements = self.size_internal();
    if (current_elements < n + 1) return Error.StackUnderflow;
    
    // Swap top with nth item using std.mem.swap
    std.mem.swap(WordType, &self.stack_ptr[0], &self.stack_ptr[n]);
}

// Individual SWAP functions (SWAP1-SWAP16)
pub fn swap1(self: *Self) Error!void { return self.swap_n(1); }
pub fn swap2(self: *Self) Error!void { return self.swap_n(2); }
// ... swap3-swap16 similarly implemented
```

### Gas Integration
Stack operations have minimal gas costs in EVM:
```zig
pub const StackGasCosts = struct {
    pub const PUSH = 3;   // PUSH1-PUSH32
    pub const POP = 2;    // POP  
    pub const DUP = 3;    // DUP1-DUP16
    pub const SWAP = 3;   // SWAP1-SWAP16
};
```

## Error Handling

Stack uses comprehensive error types for different failure modes:

### Error Categories
```zig
pub const Error = error{
    StackOverflow,    // Exceeds maximum capacity (configurable, default 1024)
    StackUnderflow,   // Pop/access on empty stack
    AllocationError,  // Memory allocation failure
};
```

### Error Propagation
```zig
// Safe operations propagate errors
const result = stack.pop() catch |err| switch (err) {
    Error.StackUnderflow => {
        log.debug("Stack underflow detected", .{});
        return Error.StackUnderflow;
    },
    else => return err,
};

// Unsafe operations assert preconditions
std.debug.assert(stack.size() > 0); // Must verify before unsafe pop
const value = stack.pop_unsafe(); // No error handling needed
```

## Integration Notes

### With Frame Module
Stack integrates with Frame for:
- Opcode parameter extraction and validation
- Result storage for arithmetic and logical operations
- Gas cost accounting for stack operations

### With Instructions Module
Stack handlers provide:
- Direct manipulation for all stack-based opcodes
- Efficient bulk operations for complex instructions
- Type-safe value exchange with other components

### With Memory Module
Coordination with Memory for:
- Offset validation from stack values
- Size parameters for memory operations
- Error propagation for resource limits

## Memory Management

Stack manages its own aligned memory allocation:

### Initialization
```zig
pub fn init(allocator: std.mem.Allocator) Error!Self {
    const memory = allocator.alignedAlloc(WordType, @enumFromInt(6), stack_capacity) catch return Error.AllocationError;
    errdefer allocator.free(memory);

    const base_ptr: [*]align(64) WordType = memory.ptr;

    return Self{
        .buf_ptr = base_ptr,
        .stack_ptr = base_ptr + stack_capacity,  // Points to end (empty state)
    };
}
```

### Cleanup
```zig
pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    const memory_slice = self.buf_ptr[0..stack_capacity];
    allocator.free(memory_slice);
}
```

All memory operations use defer patterns for guaranteed cleanup and proper error handling throughout the execution chain.

## C API Interface

The stack provides a complete C FFI interface for external integration:

### Lifecycle Management
```c
// Create and destroy stack instances
StackHandle* evm_stack_create(void);
void evm_stack_destroy(StackHandle* handle);
int evm_stack_reset(StackHandle* handle);
```

### Basic Operations
```c
// Push/pop operations with different data types
int evm_stack_push_u64(StackHandle* handle, uint64_t value);
int evm_stack_push_bytes(StackHandle* handle, const uint8_t bytes[32]);
int evm_stack_pop_u64(StackHandle* handle, uint64_t* value_out);
int evm_stack_pop_bytes(StackHandle* handle, uint8_t bytes_out[32]);

// Peek operations
int evm_stack_peek_u64(const StackHandle* handle, uint64_t* value_out);
int evm_stack_peek_bytes(const StackHandle* handle, uint8_t bytes_out[32]);
int evm_stack_peek_at(const StackHandle* handle, uint32_t depth, uint8_t bytes_out[32]);
```

### Stack Operations
```c
// EVM stack manipulation
int evm_stack_dup(StackHandle* handle, uint32_t depth);  // DUP1-DUP16
int evm_stack_swap(StackHandle* handle, uint32_t depth); // SWAP1-SWAP16

// Stack information
uint32_t evm_stack_size(const StackHandle* handle);
int evm_stack_is_empty(const StackHandle* handle);
int evm_stack_is_full(const StackHandle* handle);
uint32_t evm_stack_capacity(const StackHandle* handle);
```

### Error Codes
```c
#define EVM_STACK_SUCCESS           0
#define EVM_STACK_ERROR_NULL_POINTER -1
#define EVM_STACK_ERROR_OVERFLOW    -2
#define EVM_STACK_ERROR_UNDERFLOW   -3
#define EVM_STACK_ERROR_OUT_OF_MEMORY -4
```

## Performance Benchmarks

The stack implementation includes comprehensive benchmarks comparing operations with REVM:

### Benchmark Categories
- **Basic Operations**: Push/pop sequences of various sizes
- **Stack Operations**: DUP/SWAP operation performance  
- **Unsafe Operations**: Maximum performance with pre-validated conditions
- **EVM Integration**: Full bytecode execution comparison with REVM
- **Bulk Operations**: Large data set manipulation

Performance is optimized for:
- Cache-friendly memory layout with 64-byte alignment
- Branch prediction with @branchHint directives
- Minimal bounds checking in unsafe variants
- Optimal index type selection based on stack size