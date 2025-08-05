# Guillotine Bytecode Analysis and Execution Research

## Executive Summary

Guillotine implements a traditional interpreter with several sophisticated optimizations:

1. **BitVec-based Jump Validation** - O(1) jump destination checks using bitmaps
2. **Code Analysis Caching** - LRU cache for analyzed bytecode (configurable)
3. **Stack Height Pre-computation** - Static table for fast stack validation
4. **Optimized PUSH Handling** - PUSH1-8 values stored inline in operations
5. **Direct Jump Table Dispatch** - Function pointer array for O(1) dispatch

While not using EVMOne's advanced block-based execution, Guillotine achieves good performance through careful optimization of the traditional interpreter model.

## Architecture Overview

### Core Components

```
evm.zig                    - Main VM implementation
frame/contract.zig         - Contract execution context  
frame/code_analysis.zig    - Bytecode analysis structures
frame/bitvec.zig          - Bit vector for jump destinations
jump_table/jump_table.zig  - Opcode dispatch table
evm/interpret.zig         - Main interpreter loop
```

### Key Data Structures

#### 1. CodeAnalysis
```zig
pub const CodeAnalysis = struct {
    code_segments: BitVec64,        // Marks code vs data bytes
    jumpdest_bitmap: BitVec64,      // Valid JUMPDEST positions
    block_gas_costs: ?[]const u32,  // Optional block gas costs
    max_stack_depth: u16,           // Max stack requirement
    has_dynamic_jumps: bool,        // Contains JUMP/JUMPI
    has_static_jumps: bool,         // Contains static jumps
    has_selfdestruct: bool,        // Contains SELFDESTRUCT
    has_create: bool,               // Contains CREATE/CREATE2
};
```

#### 2. BitVec64 (Optimized Bit Vector)
```zig
pub const BitVec64 = BitVec(u64);

pub fn BitVec(comptime T: type) type {
    return struct {
        bits: []T,              // Bit storage in T-sized chunks
        size: usize,            // Total bits
        owned: bool,            // Memory ownership flag
        cached_ptr: [*]T,       // Cached pointer for speed
    };
}
```

#### 3. Contract (Execution Context)
```zig
pub const Contract = struct {
    // Identity
    address: Address,
    caller: Address,
    value: u256,
    
    // Code
    code: []const u8,
    code_hash: [32]u8,
    code_size: u64,
    analysis: ?*const CodeAnalysis,
    
    // Gas
    gas: u64,
    gas_refund: u64,
    
    // Storage tracking
    storage_access: ?*HashMap(u256, bool),  // Warm/cold slots
    original_storage: ?*HashMap(u256, u256), // Original values
    
    // Optimization flags
    has_jumpdests: bool,
    is_empty: bool,
    is_static: bool,
};
```

#### 4. JumpTable
```zig
pub const JumpTable = struct {
    table: [256]?*const Operation align(64), // Cache-aligned
    
    pub fn execute(self: *const JumpTable, pc: usize, 
                   interpreter: Interpreter, state: State, 
                   opcode: u8) !ExecutionResult {
        const operation = self.get_operation(opcode);
        
        // Validate stack requirements ONCE
        try validate_stack_requirements(state.stack, operation);
        
        // Consume gas
        try state.consume_gas(operation.constant_gas);
        
        // Execute operation
        return operation.execute(pc, interpreter, state);
    }
};
```

## Bytecode Analysis Algorithm

### Overview
Guillotine performs bytecode analysis on-demand when the first jump occurs, then caches the results by code hash.

### 1. Code vs Data Analysis
```zig
pub fn codeBitmap(allocator: Allocator, code: []const u8) !BitVec64 {
    var bitmap = try BitVec64.init(allocator, code.len);
    
    // Mark all positions as code initially
    for (0..code.len) |i| {
        bitmap.setUnchecked(i);
    }
    
    // Scan for PUSH instructions and mark data bytes
    var i: usize = 0;
    while (i < code.len) {
        const op = code[i];
        
        if (opcode.is_push(op)) {
            const push_bytes = opcode.get_push_size(op);
            
            // Mark push data bytes as non-code
            var j: usize = 1;
            while (j <= push_bytes and i + j < code.len) : (j += 1) {
                bitmap.clearUnchecked(i + j);
            }
            
            i += push_bytes + 1;
        } else {
            i += 1;
        }
    }
    
    return bitmap;
}
```

### 2. JUMPDEST Analysis
```zig
pub fn analyze_code(allocator: Allocator, code: []const u8, 
                   code_hash: [32]u8) !?*const CodeAnalysis {
    // Check cache first
    if (analysis_cache) |*cache| {
        if (cache.get(code_hash)) |cached| {
            return cached;
        }
    }
    
    const analysis = try allocator.create(CodeAnalysis);
    
    // Create code/data bitmap
    analysis.code_segments = try BitVec64.codeBitmap(allocator, code);
    
    // Create JUMPDEST bitmap
    analysis.jumpdest_bitmap = try BitVec64.init(allocator, code.len);
    
    // Scan for JUMPDESTs in code segments only
    var i: usize = 0;
    while (i < code.len) {
        const op = code[i];
        
        if (op == @intFromEnum(Opcode.JUMPDEST) and 
            analysis.code_segments.isSetUnchecked(i)) {
            analysis.jumpdest_bitmap.setUnchecked(i);
        }
        
        if (opcode.is_push(op)) {
            i += opcode.get_push_size(op) + 1;
        } else {
            i += 1;
        }
    }
    
    // Detect special opcodes
    analysis.has_dynamic_jumps = contains_op(code, &[_]u8{JUMP, JUMPI});
    analysis.has_selfdestruct = contains_op(code, &[_]u8{SELFDESTRUCT});
    analysis.has_create = contains_op(code, &[_]u8{CREATE, CREATE2});
    
    // Cache the analysis
    cache.put(code_hash, analysis) catch {};
    
    return analysis;
}
```

### 3. Jump Validation (O(1))
```zig
pub fn valid_jumpdest(self: *Contract, allocator: Allocator, 
                     dest: u256) bool {
    // Fast paths
    if (self.is_empty or dest >= self.code_size) return false;
    if (!self.has_jumpdests) return false;
    
    // Lazy analysis
    if (self.analysis == null) {
        self.analysis = analyze_code(allocator, self.code, self.code_hash) 
                       catch return false;
    }
    
    const analysis = self.analysis orelse return false;
    const pos = @intCast(u32, @min(dest, maxInt(u32)));
    
    // O(1) bitmap lookup
    return analysis.jumpdest_bitmap.isSetUnchecked(pos);
}
```

## Execution Model

### 1. Main Interpreter Loop
```zig
pub fn interpret(self: *Vm, contract: *Contract, input: []const u8, 
                is_static: bool) !RunResult {
    self.depth += 1;
    defer self.depth -= 1;
    
    var frame = Frame{
        .gas_remaining = contract.gas,
        .pc = 0,
        .contract = contract,
        .allocator = self.allocator,
        .memory = try Memory.init_default(self.allocator),
        .stack = .{},
        // ... other fields
    };
    defer frame.deinit();
    
    // Main dispatch loop
    while (frame.pc < contract.code_size) {
        const opcode = contract.get_op(frame.pc);
        
        // Execute through jump table
        const result = try self.table.execute(
            frame.pc, self, &frame, opcode
        );
        
        // Advance PC
        if (frame.pc unchanged) {
            frame.pc += result.bytes_consumed;
        }
    }
    
    return RunResult.init(
        initial_gas,
        frame.gas_remaining,
        .Success,
        null,
        output,
    );
}
```

### 2. Jump Table Dispatch
```zig
pub fn execute(self: *const JumpTable, pc: usize, 
              interpreter: Interpreter, frame: State, 
              opcode: u8) !ExecutionResult {
    const operation = self.get_operation(opcode);
    
    // Handle undefined opcodes
    if (operation.undefined) {
        frame.gas_remaining = 0;
        return error.InvalidOpcode;
    }
    
    // CRITICAL: Validate stack requirements ONCE
    // This enables safe use of pop_unsafe() in operations
    if (comptime builtin.mode == .ReleaseFast) {
        try validate_stack_requirements_fast(
            frame.stack.size,
            opcode,
            operation.min_stack,
            operation.max_stack,
        );
    } else {
        try validate_stack_requirements(&frame.stack, operation);
    }
    
    // Consume gas
    if (operation.constant_gas > 0) {
        try frame.consume_gas(operation.constant_gas);
    }
    
    // Execute operation
    return operation.execute(pc, interpreter, frame);
}
```

### 3. Stack Validation Optimization
```zig
// Pre-computed stack height changes for all opcodes
pub const STACK_HEIGHT_CHANGES = blk: {
    var table: [256]i8 = [_]i8{0} ** 256;
    
    table[0x01] = -1; // ADD: pop 2, push 1
    table[0x02] = -1; // MUL: pop 2, push 1
    table[0x08] = -2; // ADDMOD: pop 3, push 1
    table[0x50] = -1; // POP: pop 1, push 0
    table[0x51] = 0;  // MLOAD: pop 1, push 1
    table[0x5f] = 1;  // PUSH0: push 1
    
    // PUSH1-PUSH32: all push 1
    for (0x60..0x80) |opcode| {
        table[opcode] = 1;
    }
    
    // DUP1-DUP16: all push 1
    for (0x80..0x90) |opcode| {
        table[opcode] = 1;
    }
    
    // ... etc
    break :blk table;
};
```

## Key Optimizations

### 1. BitVec Jump Validation
- **Traditional**: Linear search through JUMPDEST array O(n)
- **Guillotine**: Bitmap lookup O(1)
- **Memory**: 1 bit per bytecode position

### 2. Code Analysis Caching
- **LRU Cache**: Configurable size (default 1024 entries)
- **Simple Cache**: Fallback HashMap for size-optimized builds
- **Key**: Code hash (Keccak256)
- **Value**: Analyzed code metadata

### 3. Unsafe Stack Operations
Since stack validation happens once in jump_table.execute():
```zig
// Operations can use unsafe variants:
pub fn op_add(stack: *Stack) void {
    const b = stack.pop_unsafe();  // No bounds check
    const a = stack.pop_unsafe();  // No bounds check
    stack.append_unsafe(a + b);    // No capacity check
}
```

### 4. PUSH Optimization (Already Implemented)
```zig
// PUSH1-8 store value inline
pub const make_push_small = struct {
    fn execute(pc: usize, _: Interpreter, state: State) !ExecutionResult {
        const n = state.contract.code[pc] - 0x60 + 1;
        var value: u64 = 0;
        
        // Build value from bytes
        for (0..n) |i| {
            value = (value << 8) | state.contract.code[pc + 1 + i];
        }
        
        state.stack.append_unsafe(value);
        return .{ .bytes_consumed = n + 1 };
    }
};
```

### 5. Memory Pool for Storage Maps
```zig
pub const StoragePool = struct {
    access_maps: ArrayList(*HashMap(u256, bool)),
    storage_maps: ArrayList(*HashMap(u256, u256)),
    
    pub fn borrow_access_map(self: *StoragePool) !*HashMap(u256, bool) {
        if (self.access_maps.popOrNull()) |map| {
            map.clearRetainingCapacity();
            return map;
        }
        // Create new if pool empty
        return createHashMap(u256, bool, self.allocator);
    }
};
```

## Performance Characteristics

### Memory Usage
- **Code Analysis**: ~2 bits per bytecode byte (code + jumpdest bitmaps)
- **Contract**: ~400 bytes base + optional storage maps
- **Stack**: 8KB fixed (1024 * 8 bytes)
- **Memory**: Dynamic, doubles on growth

### Time Complexity
- **Analysis**: O(n) single pass, cached
- **Jump Validation**: O(1) bitmap lookup
- **Dispatch**: O(1) array indexing
- **Stack Validation**: O(1) with pre-computed table

### Cache Behavior
- **Jump Table**: 64-byte aligned for cache lines
- **Operations**: Function pointers in contiguous array
- **Stack**: Likely in L1 cache during execution

## Testing Strategy

### BitVec Tests
```zig
test "BitVec codeBitmap with PUSH instructions" {
    const code = &[_]u8{ 
        0x60, 0x10,  // PUSH1 0x10
        0x60, 0x20,  // PUSH1 0x20
        0x01         // ADD
    };
    var bitmap = try BitVec64.codeBitmap(allocator, code);
    
    try expect(bitmap.isSet(0));  // PUSH1 opcode
    try expect(!bitmap.isSet(1)); // 0x10 (data)
    try expect(bitmap.isSet(2));  // PUSH1 opcode
    try expect(!bitmap.isSet(3)); // 0x20 (data)
    try expect(bitmap.isSet(4));  // ADD opcode
}
```

### Jump Validation Tests
```zig
test "valid_jumpdest with cached analysis" {
    var contract = Contract.init(code_with_jumpdests);
    
    // First call triggers analysis
    try expect(contract.valid_jumpdest(allocator, 10));
    try expect(contract.analysis != null);
    
    // Second call uses cached analysis
    try expect(!contract.valid_jumpdest(allocator, 5));
}
```

### Stack Validation Tests
```zig
test "stack height changes table" {
    try expectEqual(@as(i8, -1), get_stack_height_change(0x01)); // ADD
    try expectEqual(@as(i8, -2), get_stack_height_change(0x08)); // ADDMOD
    try expectEqual(@as(i8, 1), get_stack_height_change(0x5f));  // PUSH0
    try expectEqual(@as(i8, 0), get_stack_height_change(0x90));  // SWAP1
}
```

## Differences from EVMOne

| Feature | EVMOne | Guillotine |
|---------|--------|------------|
| Execution Model | Block-based with BEGINBLOCK | Traditional per-instruction |
| Analysis | Always performed, transformed | On-demand, cached |
| Jump Validation | Binary search on sorted array | O(1) bitmap lookup |
| Stack Validation | Once per block | Once per instruction (optimized) |
| Gas Checking | Once per block | Per instruction |
| Memory Layout | 16-byte instructions | Direct bytecode execution |
| PUSH Storage | Union with inline/pointer | Inline in operation for PUSH1-8 |

## Size Optimization Features

1. **Configurable Caching**: Can disable LRU cache for smaller binary
2. **ReleaseFast Mode**: Uses pre-computed tables instead of dynamic checks
3. **Unsafe Operations**: Eliminates redundant bounds checks
4. **Direct Bytecode**: No transformation overhead
5. **Lazy Analysis**: Only analyzes code that uses jumps

## Future Optimization Opportunities

1. **Block-Based Execution**: Adopt EVMOne's BEGINBLOCK approach
2. **SIMD Jump Analysis**: Already partially implemented for x86_64
3. **Inline Caching**: Cache frequently executed code paths
4. **Tiered Compilation**: JIT for hot code paths
5. **Parallel Analysis**: Analyze bytecode in background thread

## Conclusion

Guillotine implements a sophisticated traditional interpreter with several key optimizations:
- O(1) jump validation via bitmaps (better than EVMOne's O(log n))
- Comprehensive code analysis with caching
- Pre-computed stack validation tables
- Optimized memory management with pooling

While it doesn't use EVMOne's block-based execution model, Guillotine achieves good performance through careful optimization of the traditional approach. The architecture is clean, well-documented, and provides a solid foundation for future enhancements.