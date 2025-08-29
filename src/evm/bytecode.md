# Bytecode

Secure, high-performance EVM bytecode representation and analysis.

Note: This module is currently marked deprecated in favor of `bytecode4.zig`. The API here remains supported and used throughout the codebase, but new work may target the successor. This document reflects the current behavior of `src/evm/bytecode.zig`.

## Synopsis

```zig
const BytecodeType = Bytecode(config);
var bytecode = try BytecodeType.init(allocator, code);
const is_valid = bytecode.isValidJumpDest(pc);
const opcode = bytecode.getOpcode(pc);
```

## Description

Two-phase security model with rigorous validation followed by optimized execution using precomputed bitmaps. Supports EIP-170 contract size limits, EIP-3860 initcode restrictions, Solidity metadata parsing, and efficient pattern detection.

## Architecture & Design

### Core Design Principles

1. **Security-First Design**: Two-phase model treating all bytecode as untrusted during validation
2. **Performance Optimization**: Cache-aligned bitmaps, prefetching, and optional SIMD in hot paths
3. **Memory Safety**: Bounds-checked operations with bitmap-based validation
4. **EVM Compliance**: Full support for EIP-170, EIP-3860, and Ethereum specification
5. **Optimization Analysis**: Iterator with fusion hints and statistics gathering

### Two-Phase Security Model

```zig
// Phase 1 - Validation (buildBitmapsAndValidate):
// - Treat ALL bytecode as untrusted and potentially malicious
// - Use safe std library functions with runtime checks
// - Validate assumptions about bytecode structure
// - Check for invalid opcodes, truncated PUSH instructions, invalid jump destinations
// - Build validated bitmaps marking safe regions

// Phase 2 - Execution (after successful validation):
// - Use unsafe builtins when appropriate for performance (@enumFromInt)
// - Bitmap lookups ensure only valid positions accessed
// - Zero runtime safety overhead in release builds
```

### Bytecode Architecture

```zig
pub fn Bytecode(comptime cfg: BytecodeConfig) type {
    return struct {
        // Code Representation
        full_code: []const u8,              // Complete bytecode with metadata
        runtime_code: []const u8,           // Executable code without metadata
        metadata: ?SolidityMetadata,        // Parsed Solidity metadata

        // Memory Management
        allocator: std.mem.Allocator,       // Resource allocator

        // Legacy bitmaps (byte-granularity)
        is_push_data: []u8,                 // Marks PUSH instruction data bytes
        is_op_start: []u8,                  // Marks valid opcode start positions
        is_jumpdest: []u8,                  // Marks valid JUMPDEST locations

        // Packed per-byte flags (4 bits/byte), enables fast iteration and fusion hints
        //   - is_push_data, is_op_start, is_jumpdest, is_fusion_candidate
        packed_bitmap: []PackedBits,

        // Iterator over instructions and fusions
        pub const Iterator = struct { /* ... see Iterator API below ... */ };

        // Configuration Types
        pub const PcType = cfg.PcType();    // Smart PC type (u8/u12/u16/u32)
        pub const Stats = BytecodeStats;    // Analysis statistics
    };
}
```

### Smart Configuration System

```zig
pub const BytecodeConfig = struct {
    max_bytecode_size: u32 = 24576,      // EIP-170 limit
    max_initcode_size: u32 = 49152,      // EIP-3860 limit (2x bytecode)
    vector_length: comptime_int = auto,   // Auto-detected SIMD width
    
    // Smart PC type selection
    pub fn PcType(comptime self: BytecodeConfig) type {
        return if (self.max_bytecode_size <= std.math.maxInt(u8))
            u8    // Tiny contracts (≤255 bytes)
        else if (self.max_bytecode_size <= std.math.maxInt(u12))
            u12   // Small contracts (≤4095 bytes) 
        else if (self.max_bytecode_size <= std.math.maxInt(u16))
            u16   // Standard contracts (≤65535 bytes)
        else
            u32;  // Large contracts
    }
};
```

## API Reference

### Factory Function and Configuration

```zig
// Create configured Bytecode type
pub fn Bytecode(comptime cfg: BytecodeConfig) type

// Default configuration for Ethereum mainnet
const BytecodeDefault = Bytecode(.{});

// Custom configuration example
const BytecodeCustom = Bytecode(.{
    .max_bytecode_size = 32768,     // 32KB limit
    .max_initcode_size = 65536,     // 64KB initcode
    .vector_length = 16,            // Force 16-byte SIMD
});
```

### Bytecode Creation and Management

```zig
// Initialize from contract bytecode
pub fn init(allocator: std.mem.Allocator, code: []const u8) ValidationError!Self

// Initialize from initcode with EIP-3860 validation
pub fn initFromInitcode(allocator: std.mem.Allocator, initcode: []const u8) ValidationError!Self

// Clean up resources
pub fn deinit(self: *Self) void

// Usage example
const allocator = std.heap.page_allocator;
const contract_code = &[_]u8{ 0x60, 0x40, 0x52, 0x60, 0x80, 0xf3 };

var bytecode = try BytecodeDefault.init(allocator, contract_code);
defer bytecode.deinit();
```

### Error Handling

```zig
pub const ValidationError = error{
    InvalidOpcode,           // Undefined opcode encountered
    TruncatedPush,          // PUSH instruction with insufficient data
    InvalidJumpDestination,  // Invalid jump target
    OutOfMemory,            // Memory allocation failure
    InitcodeTooLarge,       // Initcode exceeds EIP-3860 limit
    BytecodeTooLarge,       // Runtime bytecode exceeds EIP-170 limit
};

// Validation example with error handling
var bytecode = BytecodeDefault.init(allocator, untrusted_code) catch |err| {
    return switch (err) {
        error.InvalidOpcode => log.err("Bytecode contains invalid opcode"),
        error.TruncatedPush => log.err("PUSH instruction truncated"),
        error.InitcodeTooLarge => log.err("Initcode too large: {} bytes", .{untrusted_code.len}),
        error.BytecodeTooLarge => log.err("Runtime bytecode too large: {} bytes", .{untrusted_code.len}),
        else => err,
    };
};
```

### Basic Access Operations

```zig
// Get bytecode length
pub inline fn len(self: Self) PcType

// Get raw bytecode slice  
pub inline fn raw(self: Self) []const u8

// Get bytecode without Solidity metadata
pub fn rawWithoutMetadata(self: Self) []const u8

// Safe byte access with bounds checking
pub inline fn get(self: Self, index: PcType) ?u8

// Unsafe byte access (bounds pre-validated)
pub inline fn get_unsafe(self: Self, index: PcType) u8

// Opcode access
pub inline fn getOpcode(self: Self, pc: PcType) ?u8
pub inline fn getOpcodeUnsafe(self: Self, pc: PcType) u8

// Usage examples
const bytecode_length = bytecode.len();
const raw_bytes = bytecode.raw();
const first_byte = bytecode.get(0) orelse return error.EmptyBytecode;
const opcode = bytecode.getOpcode(pc) orelse return error.InvalidPC;
```

### Jump Destination Validation

```zig
// Check if position is valid jump target (O(1) bitmap lookup)
pub fn isValidJumpDest(self: Self, pc: PcType) bool

// Usage in EVM execution
if (bytecode.isValidJumpDest(jump_target)) {
    // Safe to jump to target
    frame.pc = jump_target;
} else {
    return error.InvalidJump;
}

// Implementation uses precomputed bitmap
pub fn isValidJumpDest(self: Self, pc: PcType) bool {
    if (pc >= self.len()) return false;
    const byte_idx = pc >> BITMAP_SHIFT;  // Divide by 8 efficiently
    const bit_idx = pc & BITMAP_MASK;     // Modulo 8 efficiently
    return (self.is_jumpdest[byte_idx] & (@as(u8, 1) << @intCast(bit_idx))) != 0;
}
```

### EIP-3860 Initcode Support

```zig
// Calculate gas cost for initcode (2 gas per 32-byte word)
pub fn calculateInitcodeGas(initcode_len: usize) u64

// EIP-3860 gas calculation
const initcode = &[_]u8{0x60, 0x80, 0x60, 0x40, 0x52, /* ... */};
const gas_cost = BytecodeDefault.calculateInitcodeGas(initcode.len);
// Returns: (initcode.len + 31) / 32 * 2 gas

// Initcode size validation
var bytecode = BytecodeDefault.initFromInitcode(allocator, large_initcode) catch |err| {
    return switch (err) {
        error.InitcodeTooLarge => {
            log.err("Initcode size {} exceeds limit {}", .{ large_initcode.len, 49152 });
            return error.InitcodeTooLarge;
        },
        else => err,
    };
};
```

### Solidity Metadata Support

```zig
// Solidity metadata structure
pub const SolidityMetadata = struct {
    ipfs_hash: [34]u8,         // 0x12 0x20 + 32-byte digest
    solc_version: [3]u8,       // major, minor, patch
    metadata_length: usize,    // Length including trailing 2-byte length field
};

// Metadata parsing (automatic during init). If present, runtime_code excludes metadata
var bytecode = try BytecodeDefault.init(allocator, solidity_contract);
if (bytecode.metadata) |meta| {
    log.info("Contract has metadata: {} bytes", .{meta.metadata_length});
    log.info("IPFS multihash prefix: 0x12 0x20, digest: {s}", .{std.fmt.fmtSliceHexLower(meta.ipfs_hash[2..])});
    log.info("solc version: {}.{}.{}", .{ meta.solc_version[0], meta.solc_version[1], meta.solc_version[2] });
}

// Get runtime code without metadata
const runtime_code = bytecode.rawWithoutMetadata();
```

## Performance Characteristics

### Iterator and Packed Bits

Packed per-byte flags drive fast iteration and fusion detection. The Iterator yields decoded instruction data without re-analyzing each time:

```zig
pub const OpcodeData = union(enum) {
    regular: struct { opcode: u8 },
    push:    struct { value: u256, size: u8 },
    jumpdest: struct { gas_cost: u16 },
    push_add_fusion: struct { value: u256 },
    push_mul_fusion: struct { value: u256 },
    stop: void,
    invalid: void,
};

var it = bytecode.createIterator();
while (it.next()) |item| {
    switch (item) {
        .regular => |r| { /* ... */ },
        .push => |p| { /* ... */ },
        .push_add_fusion => |f| { /* ... */ },
        else => {},
    }
}
```

### Cache-Aligned Bitmap Storage

```zig
// Cache-aligned bitmap allocation for optimal memory access
const CACHE_LINE_SIZE = 64;

// Align bitmaps to cache line boundaries
const aligned_bytes = (bitmap_bytes + CACHE_LINE_SIZE - 1) & ~@as(usize, CACHE_LINE_SIZE - 1);
self.is_push_data = allocator.alignedAlloc(u8, CACHE_LINE_SIZE, aligned_bytes);
self.is_op_start = allocator.alignedAlloc(u8, CACHE_LINE_SIZE, aligned_bytes);
self.is_jumpdest = allocator.alignedAlloc(u8, CACHE_LINE_SIZE, aligned_bytes);
```

### Bitmap Operations Performance

1. **O(1) Jump Validation**: Precomputed JUMPDEST bitmap enables constant-time validation
2. **Bit Manipulation**: Efficient bit operations using shift and mask
3. **Memory Layout**: Sequential bitmap storage for cache efficiency
4. **Prefetching**: Automatic prefetching for large bytecode analysis

```zig
// Efficient bitmap bit setting using bit manipulation
const byte_idx = pc >> BITMAP_SHIFT;        // Equivalent to pc / 8
const bit_mask = @as(u8, 1) << @intCast(pc & BITMAP_MASK); // pc % 8
bitmap[byte_idx] |= bit_mask;
```

### Memory Usage Optimization

```zig
// Smart type selection reduces memory usage
// Small contracts (≤255 bytes): u8 PC type saves 75% memory vs u32
// Medium contracts (≤4095 bytes): u12 PC type optimal balance
// Standard contracts (≤24576 bytes): u16 PC type covers most real-world cases
// Large contracts: u32 PC type for maximum flexibility

// Memory usage examples:
// 1KB contract with u8 PC: ~384 bytes bitmap storage
// 24KB contract with u16 PC: ~9KB bitmap storage  
// 64KB contract with u32 PC: ~24KB bitmap storage
```

## Testing

### Test Coverage

Comprehensive testing covers all major functionality:

1. **Bytecode Validation**: Valid/invalid opcode handling, truncated PUSH detection
2. **Jump Destination Analysis**: JUMPDEST validation, edge cases, boundary conditions
3. **Configuration Testing**: PC type selection, size limits, SIMD capabilities
4. **EIP Support**: EIP-170 size limits, EIP-3860 initcode validation
5. **Metadata Parsing**: Solidity metadata detection and extraction
6. **Performance**: SIMD operations, cache alignment, bitmap efficiency
7. **Error Handling**: All error conditions and recovery scenarios

### Test Execution

```bash
# Run all bytecode tests
zig build test

# Run bytecode-specific tests
zig build test -- --test-filter "Bytecode"

# Run with debug information
zig build test -Dlog-level=debug
```

### Critical Test Scenarios

```zig
test "Bytecode.init and basic getters" {
    const allocator = std.testing.allocator;
    const code = [_]u8{ 0x60, 0x40, 0x52, 0x00 }; // PUSH1 0x40, MSTORE, STOP
    
    var bytecode = try BytecodeDefault.init(allocator, &code);
    defer bytecode.deinit();
    
    try std.testing.expectEqual(@as(BytecodeDefault.PcType, 4), bytecode.len());
    try std.testing.expectEqualSlices(u8, &code, bytecode.raw());
    try std.testing.expectEqual(@as(?u8, 0x60), bytecode.get(0));
    try std.testing.expectEqual(@as(?u8, null), bytecode.get(4)); // Out of bounds
}

test "Bytecode.isValidJumpDest" {
    const allocator = std.testing.allocator;
    // PUSH1 0x04, JUMPDEST, STOP
    const code = [_]u8{ 0x60, 0x04, 0x5b, 0x00 };
    
    var bytecode = try BytecodeDefault.init(allocator, &code);
    defer bytecode.deinit();
    
    try std.testing.expect(!bytecode.isValidJumpDest(0)); // PUSH1
    try std.testing.expect(!bytecode.isValidJumpDest(1)); // PUSH1 data
    try std.testing.expect(bytecode.isValidJumpDest(2));  // JUMPDEST
    try std.testing.expect(!bytecode.isValidJumpDest(3)); // STOP
}

test "Bytecode EIP-3860 initcode validation" {
    const allocator = std.testing.allocator;
    
    // Small initcode (under limit)
    const small_initcode = &[_]u8{ 0x60, 0x80, 0x60, 0x40, 0x52 };
    var bytecode = try BytecodeDefault.initFromInitcode(allocator, small_initcode);
    defer bytecode.deinit();
    
    // Large initcode (over limit)
    const large_initcode = &[_]u8{0x00} ** 50000;
    try std.testing.expectError(error.InitcodeTooLarge, 
        BytecodeDefault.initFromInitcode(allocator, large_initcode));
}

test "Bytecode gas calculation" {
    // Test EIP-3860 gas calculation
    try std.testing.expectEqual(@as(u64, 1 * 2), BytecodeDefault.calculateInitcodeGas(32));   // 1 word
    try std.testing.expectEqual(@as(u64, 2 * 2), BytecodeDefault.calculateInitcodeGas(33));   // 2 words
    try std.testing.expectEqual(@as(u64, 2 * 2), BytecodeDefault.calculateInitcodeGas(64));   // 2 words
    try std.testing.expectEqual(@as(u64, 3 * 2), BytecodeDefault.calculateInitcodeGas(65));   // 3 words
}
```

## Context within EVM

### Integration with Planner

The Bytecode module provides validated code for the Planner's optimization:

```zig
// Planner uses validated bytecode for safe optimization
pub fn create_plan(self: *Planner, bytecode: BytecodeType) !Plan {
    // Use precomputed bitmaps for safe instruction stream construction
    for (0..bytecode.len()) |pc| {
        if (bytecode.isValidOpcode(pc)) {
            const opcode = bytecode.getOpcodeUnsafe(pc);
            // Safe to use unsafe access - validation complete
        }
    }
}
```

### Frame Integration

Frame uses Bytecode for instruction fetching and validation:

```zig
// Frame execution with validated bytecode
pub fn execute(frame: *Frame, bytecode: BytecodeType) !void {
    while (frame.pc < bytecode.len()) {
        // O(1) bounds check using precomputed length
        const opcode = bytecode.getOpcodeUnsafe(frame.pc);
        
        // Execute opcode safely
        try frame.execute_opcode(opcode);
        
        // Jump validation using bitmap
        if (opcode == JUMP or opcode == JUMPI) {
            const target = try frame.stack.pop();
            if (!bytecode.isValidJumpDest(@intCast(target))) {
                return error.InvalidJump;
            }
        }
    }
}
```

### Host Interface Coordination

Bytecode integrates with Host for contract code retrieval:

```zig
// Host provides bytecode to EVM for execution
pub fn get_code(self: *Host, address: Address) []const u8 {
    // Raw bytecode from storage
    const raw_code = self.database.get_code_by_address(address);
    
    // EVM validates and wraps in Bytecode structure
    var bytecode = Bytecode.init(allocator, raw_code) catch {
        return &.{}; // Invalid bytecode returns empty
    };
    
    return bytecode.raw();
}
```

## EVM Specification Compliance

### EIP-170: Contract Size Limit

```zig
// Default configuration enforces EIP-170 limits
max_bytecode_size: u32 = 24576,  // 24KB maximum contract size

// Validation during contract creation
pub fn validate_contract_size(code: []const u8) bool {
    return code.len <= 24576;
}
```

### EIP-3860: Initcode Size and Gas

```zig
// EIP-3860 initcode limits (2x contract size)
max_initcode_size: u32 = 49152,  // 48KB maximum initcode

// Gas calculation: 2 gas per 32-byte word
pub fn calculateInitcodeGas(initcode_len: usize) u64 {
    const words = (initcode_len + 31) / 32;
    return words * 2;  // EIP-3860 specification
}

// Validation during contract deployment
if (initcode.len > max_initcode_size) {
    return error.InitcodeTooLarge;
}
```

### JUMPDEST Validation

```zig
// EVM specification: JUMPDEST must not be in PUSH data
fn buildJumpDestBitmap(self: *Self) void {
    for (0..self.runtime_code.len) |i| {
        // Only mark JUMPDEST if not in PUSH data
        if (self.runtime_code[i] == JUMPDEST and !self.isPushData(i)) {
            self.setJumpDestBit(i);
        }
    }
}

// Jump validation during execution
pub fn isValidJumpDest(self: Self, pc: PcType) bool {
    return pc < self.len() and self.getJumpDestBit(pc);
}
```

### Solidity Metadata Handling

```zig
// Solidity metadata format: 0xa2 0x64 'i' 'p' 'f' 's' 0x58 0x22 <32 bytes hash> 0x64 'sol' 'c' 0x43 <version> 0x00 0x33
pub const SolidityMetadata = struct {
    metadata_length: usize,
    ipfs_hash: ?[34]u8,        // IPFS multihash
    swarm_hash: ?[32]u8,       // Swarm hash
    experimental: bool,        // Experimental compiler flag
};

// Automatic metadata separation during init
const metadata = parseSolidityMetadataFromBytes(code);
const runtime_code = if (metadata) |m| 
    code[0..code.len - m.metadata_length]
else 
    code;
```

### Security Guarantees

The Bytecode module provides strong security guarantees:

1. **Input Validation**: All bytecode treated as untrusted until validated
2. **Bounds Checking**: Safe access methods prevent buffer overflows
3. **Opcode Validation**: Invalid opcodes rejected during initialization
4. **PUSH Truncation**: Truncated PUSH instructions detected and rejected
5. **Jump Safety**: Invalid jump destinations prevented through bitmap validation

## Advanced Features

### SIMD Pattern Detection

```zig
// Fusion opportunity detection using SIMD
fn findFusionPatternsSimd(self: Self, comptime L: comptime_int) !ArrayList(Stats.Fusion) {
    // Parallel pattern matching for PUSH+OP sequences
    const splat_add: @Vector(L, u8) = @splat(@intFromEnum(Opcode.ADD));
    const splat_mul: @Vector(L, u8) = @splat(@intFromEnum(Opcode.MUL));
    
    // Vector comparison finds fusion opportunities efficiently
    const v: @Vector(L, u8) = bytecode_slice[start..start+L];
    const matches_add: @Vector(L, bool) = v == splat_add;
    const matches_mul: @Vector(L, bool) = v == splat_mul;
}
```

### Statistics Collection

```zig
pub const BytecodeStats = struct {
    opcode_counts: [256]u32,           // Frequency of each opcode
    push_values: []const PushValue,    // PUSH instruction values
    potential_fusions: []const Fusion, // Optimization opportunities  
    jumpdests: []const usize,          // JUMPDEST locations
    jumps: []const Jump,               // JUMP/JUMPI instructions
    backwards_jumps: usize,            // Loop detection
    is_create_code: bool,              // Contract vs initcode
    
    pub fn analyze(allocator: Allocator, bytecode: []const u8) !BytecodeStats;
};
```

The Bytecode module serves as the foundation for secure, high-performance EVM bytecode handling, providing comprehensive validation, optimization analysis, and EVM specification compliance while maintaining optimal runtime performance through cache-conscious design.
