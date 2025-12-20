# Architecture Deep Dive

This document provides a comprehensive understanding of both EVM implementations with actual code excerpts and detailed explanations.

## Two EVM Implementations

Guillotine contains two complete EVM implementations:

| Implementation | Location | Philosophy |
|----------------|----------|------------|
| **Mini** | `mini/src/` | Clarity over performance |
| **Performance** | `src/` | Speed via dispatch optimization |

Both are spec-compliant and support Frontier through Prague.

## Core Components

### 1. EVM Orchestrator

The EVM orchestrator manages high-level execution: call stack, state access, gas refunds.

#### Mini EVM (Traditional)

```zig
// mini/src/evm.zig - Complete state management in one file (94KB)
pub fn Evm(comptime config: EvmConfig) type {
    return struct {
        // State maps
        balances: std.AutoHashMap(Address, u256),
        nonces: std.AutoHashMap(Address, u64),
        code: std.AutoHashMap(Address, []const u8),
        storage: Storage,

        // Transaction state
        gas_refund: i64,
        warm_addresses: std.AutoHashMap(Address, void),
        warm_storage_slots: std.AutoHashMap(StorageSlotKey, void),

        // Execution context
        origin: Address,
        gas_price: u256,
        block_context: BlockContext,
    };
}
```

#### Performance EVM (Modular)

```zig
// src/evm.zig - Delegates to specialized modules (~270KB system)
pub fn Evm(comptime config: EvmConfig) type {
    return struct {
        // Modular state management
        journal: Journal,              // src/storage/journal.zig
        access_list: AccessList,       // src/storage/access_list.zig
        database: *Database,           // src/storage/database.zig

        // Execution support
        call_arena: GrowingArenaAllocator,
        tracer: Tracer,
    };
}
```

### 2. Frame (Execution Context)

The Frame manages a single call's execution: stack, memory, gas, bytecode.

#### Mini Frame

```zig
// mini/src/frame.zig:50-70
stack: std.ArrayList(u256),           // Bounds-checked every operation
memory: std.AutoHashMap(u32, u8),     // Sparse byte storage
memory_size: u32,
pc: u32,                               // Program counter into bytecode
gas_remaining: i64,
bytecode: Bytecode,                    // With JUMPDEST analysis
caller: Address,
address: Address,
value: u256,
calldata: []const u8,
```

#### Performance Frame

```zig
// src/frame/frame.zig:134-157
// CACHE LINE 1 (hot data)
stack: Stack,                          // Cache-aligned, pre-validated ops
gas_remaining: GasType,
evm_ptr: *anyopaque,
database: *anyopaque,
memory: Memory,
contract_address: Address,
caller: Address,

// Less frequently accessed
value: WordType,
calldata_slice: []const u8,
code: []const u8,
jump_table: *const Dispatch.JumpTable,
dispatch: Dispatch,                    // Schedule cursor
instruction_counter: LoopSafetyCounter,
```

### 3. Stack Implementation

#### Mini Stack (ArrayList)

```zig
// mini/src/frame.zig:161-176
pub fn pushStack(self: *Self, value: u256) EvmError!void {
    if (self.stack.items.len >= 1024) {
        return error.StackOverflow;  // Check every push
    }
    try self.stack.append(self.allocator, value);
}

pub fn popStack(self: *Self) EvmError!u256 {
    if (self.stack.items.len == 0) {
        return error.StackUnderflow;  // Check every pop
    }
    const value = self.stack.items[self.stack.items.len - 1];
    self.stack.items.len -= 1;
    return value;
}
```

#### Performance Stack (Cache-Aligned Array)

```zig
// src/stack/stack.zig - Pointer-based, downward growth
pub fn Stack(comptime config: StackConfig) type {
    return struct {
        // Pre-allocated array, 64-byte cache line aligned
        data: [stack_capacity]WordType align(64),
        stack_ptr: usize,  // Points to next free slot

        // Unsafe operations (caller validates first)
        pub inline fn pop_unsafe(self: *Self) WordType {
            self.stack_ptr += 1;
            return self.data[self.stack_ptr - 1];
        }

        pub inline fn push_unsafe(self: *Self, value: WordType) void {
            self.stack_ptr -= 1;
            self.data[self.stack_ptr] = value;
        }

        // Binary operation without intermediate storage
        pub inline fn binary_op_unsafe(
            self: *Self,
            comptime op: fn (WordType, WordType) WordType
        ) void {
            const a = self.data[self.stack_ptr];
            self.stack_ptr += 1;
            self.data[self.stack_ptr] = op(self.data[self.stack_ptr], a);
        }
    };
}
```

## Execution Flow

### Mini EVM: Sequential Interpretation

```
1. Read opcode at PC
2. Switch on opcode (256 cases)
3. Execute handler
4. Increment PC
5. Repeat until STOP/RETURN/REVERT
```

```zig
// mini/src/frame.zig:540-553
pub fn execute(self: *Self) EvmError!void {
    while (!self.stopped and !self.reverted and self.pc < self.bytecode.len()) {
        try self.step();
    }
}

pub fn step(self: *Self) EvmError!void {
    const opcode = self.bytecode.getOpcode(self.pc) orelse {
        return error.InvalidOpcode;
    };

    // Giant switch statement
    switch (opcode) {
        0x01 => try ArithmeticHandlers.add(self),
        0x02 => try ArithmeticHandlers.mul(self),
        // ... 256 cases
    }
}
```

### Performance EVM: Dispatch Execution

```
1. Preprocess bytecode → dispatch schedule
2. Schedule[0] = block gas metadata
3. Schedule[1].handler(frame, cursor)
4. Handler tail-calls next handler
5. Repeat until Stop/Return/Revert error
```

```zig
// src/frame/frame.zig - Entry point
pub fn interpret(
    self: *Self,
    schedule: [*]const Dispatch.Item,
    jump_table: *const Dispatch.JumpTable,
    bytecode_raw: []const u8,
) Error!void {
    // Validate first block
    const first_block = schedule[0].first_block_gas;
    if (self.gas_remaining < first_block.gas) {
        return Error.OutOfGas;
    }
    self.gas_remaining -= first_block.gas;

    // Start tail-call chain (NEVER returns normally)
    self.code = bytecode_raw;
    self.jump_table = jump_table;
    return @call(.always_tail, schedule[1].opcode_handler, .{self, schedule + 1});
}
```

## Dispatch System

### Schedule Structure

```zig
// src/preprocessor/dispatch.zig:32-40
pub const Item = union(enum) {
    opcode_handler: OpcodeHandler,      // Function pointer
    jump_dest: JumpDestMetadata,        // Block gas/stack info
    push_inline: PushInlineMetadata,    // Small values (≤8 bytes)
    push_pointer: PushPointerMetadata,  // Large values (>8 bytes)
    pc: PcMetadata,
    jump_static: JumpStaticMetadata,    // Pre-resolved jumps
    first_block_gas: FirstBlockMetadata,
};
```

### Handler Pattern

```zig
// Every handler follows this pattern
pub fn add(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
    // 1. Tracer sync (debug builds)
    self.beforeInstruction(.ADD, cursor);

    // 2. Execute (pre-validated, use unsafe)
    self.stack.binary_op_unsafe(struct {
        fn op(top: WordType, second: WordType) WordType {
            return top +% second;
        }
    }.op);

    // 3. Tail-call next handler (NEVER returns)
    const next = dispatch.getOpData(.ADD);
    return @call(.always_tail, next.handler, .{self, next.cursor});
}
```

## State Management

### Storage Model

```zig
// Both implementations track:
// 1. Current storage (modified during tx)
// 2. Original storage (snapshot at tx start, for refunds)
// 3. Transient storage (EIP-1153, cleared per tx)

// Mini: Direct HashMaps
storage: std.AutoHashMap(StorageSlotKey, u256),
original_storage: std.AutoHashMap(StorageSlotKey, u256),
transient: std.AutoHashMap(StorageSlotKey, u256),

// Performance: Structured Storage module
// src/storage/database.zig + src/storage/journal.zig
```

### Journal System (Performance Only)

```zig
// src/storage/journal.zig:14-40
pub fn Journal(comptime config: JournalConfig) type {
    return struct {
        entries: std.ArrayList(Entry),
        next_snapshot_id: SnapshotIdType,

        pub fn create_snapshot(self: *Self) SnapshotIdType {
            const id = self.next_snapshot_id;
            self.next_snapshot_id +|= 1;
            return id;
        }

        pub fn revert_to_snapshot(self: *Self, snapshot_id: SnapshotIdType) void {
            // Remove entries with snapshot_id >= target
            var write_idx: usize = 0;
            for (self.entries.items) |entry| {
                if (entry.snapshot_id < snapshot_id) {
                    self.entries.items[write_idx] = entry;
                    write_idx += 1;
                }
            }
            self.entries.shrinkRetainingCapacity(write_idx);
        }

        pub fn record_storage_change(
            self: *Self,
            snapshot_id: SnapshotIdType,
            address: Address,
            key: WordType,
            original_value: WordType,
        ) !void {
            try self.entries.append(self.allocator,
                Entry.storage_change(snapshot_id, address, key, original_value));
        }
    };
}
```

### Access List (EIP-2929)

```zig
// Both implementations track warm/cold access
// First access: cold cost (2600 address, 2100 storage)
// Subsequent: warm cost (100)

// Mini: Simple HashMaps
warm_addresses: std.AutoHashMap(Address, void),
warm_storage_slots: std.AutoHashMap(StorageSlotKey, void),

// Performance: Structured AccessList
// src/storage/access_list.zig
pub fn access_address(self: *Self, address: Address) u64 {
    if (self.addresses.contains(address)) {
        return WARM_ACCOUNT_ACCESS;  // 100
    }
    try self.addresses.put(address, {});
    return COLD_ACCOUNT_ACCESS;  // 2600
}
```

## Bytecode Analysis

### JUMPDEST Tracking

Both implementations analyze bytecode to identify valid jump destinations:

```zig
// JUMPDEST (0x5B) is only valid at instruction boundaries
// NOT valid inside PUSH data

// Bytecode: [PUSH1, 0x5B, JUMPDEST]
//              0     1      2
// Position 1 contains 0x5B but is PUSH data, not a valid JUMPDEST
// Position 2 is a valid JUMPDEST

fn analyzeJumpDests(code: []const u8) JumpDestSet {
    var set = JumpDestSet{};
    var pc: usize = 0;
    while (pc < code.len) {
        const opcode = code[pc];
        if (opcode == 0x5B) {  // JUMPDEST
            set.add(pc);
            pc += 1;
        } else if (opcode >= 0x60 and opcode <= 0x7F) {  // PUSH1-PUSH32
            pc += 1 + (opcode - 0x5F);  // Skip push data
        } else {
            pc += 1;
        }
    }
    return set;
}
```

### Fusion Detection (Performance Only)

```zig
// src/bytecode/bytecode_analyze.zig
fn detectFusions(code: []const u8, pc: usize) ?SyntheticOpcode {
    // PUSH + ADD pattern
    if (isPush(code[pc]) and nextOpcode(code, pc) == 0x01) {
        return .PUSH_ADD_INLINE;
    }

    // PUSH4 + EQ + PUSH + JUMPI (function dispatch)
    if (code[pc] == 0x63 and matchesFunctionDispatch(code, pc)) {
        return .FUNCTION_DISPATCH;
    }

    return null;
}
```

## Handler Categories

### Instruction Handlers

Both implementations organize handlers by category:

| Category | Opcodes | Files |
|----------|---------|-------|
| Arithmetic | ADD, SUB, MUL, DIV, MOD, EXP, etc. | `handlers_arithmetic.zig` |
| Bitwise | AND, OR, XOR, NOT, SHL, SHR, SAR | `handlers_bitwise.zig` |
| Comparison | LT, GT, EQ, ISZERO, SLT, SGT | `handlers_comparison.zig` |
| Stack | PUSH0-32, POP, DUP1-16, SWAP1-16 | `handlers_stack.zig` |
| Memory | MLOAD, MSTORE, MSTORE8, MSIZE, MCOPY | `handlers_memory.zig` |
| Storage | SLOAD, SSTORE, TLOAD, TSTORE | `handlers_storage.zig` |
| Control | JUMP, JUMPI, JUMPDEST, PC, STOP | `handlers_jump.zig` / `handlers_control_flow.zig` |
| Context | ADDRESS, CALLER, ORIGIN, CALLVALUE, etc. | `handlers_context.zig` |
| Block | BLOCKHASH, COINBASE, TIMESTAMP, etc. | `handlers_block.zig` |
| System | CALL, CREATE, RETURN, REVERT, etc. | `handlers_system.zig` |
| Log | LOG0-LOG4 | `handlers_log.zig` |
| Keccak | KECCAK256 | `handlers_keccak.zig` |

### Synthetic Handlers (Performance Only)

```zig
// src/instructions/handlers_*_synthetic.zig
// Fused operations for common patterns

handlers_arithmetic_synthetic.zig  // PUSH+ADD, PUSH+MUL, etc.
handlers_bitwise_synthetic.zig     // PUSH+AND, PUSH+OR, etc.
handlers_memory_synthetic.zig      // PUSH+MSTORE, PUSH+MLOAD, etc.
handlers_jump_synthetic.zig        // Static jump resolution
```

## Memory Allocation

### Mini: Standard Allocator

```zig
// Uses provided allocator directly
allocator: std.mem.Allocator,

// Stack and memory use allocator
stack: std.ArrayList(u256),
memory: std.AutoHashMap(u32, u8),
```

### Performance: Arena Allocator

```zig
// Transaction-scoped arena
// All allocations freed at once when transaction completes
call_arena: GrowingArenaAllocator,

// Frame uses arena for all allocations
pub fn init(allocator: std.mem.Allocator, ...) Error!Self {
    var stack = Stack.init(allocator, null) catch return Error.AllocationError;
    var memory = Memory.init(allocator) catch return Error.AllocationError;
    // ...
}
```

## Configuration

Both implementations use compile-time configuration:

```zig
// Mini
pub const EvmConfig = struct {
    hardfork: Hardfork = .CANCUN,
    gas_metering: bool = true,
    // ...
};

// Performance
pub const FrameConfig = struct {
    WordType: type = u256,
    stack_size: usize = 1024,
    max_bytecode_size: usize = 24576,
    memory_limit: usize = 0x1000000,
    fusions_enabled: bool = true,
    loop_quota: ?u64 = 300_000_000,
    // ...
};
```

## Key Architectural Differences Summary

| Aspect | Mini | Performance |
|--------|------|-------------|
| Execution | PC-based loop | Dispatch tail-calls |
| Stack | `ArrayList` with checks | Cache-aligned array, unsafe ops |
| Memory | Sparse `HashMap` | Word-aligned pages |
| State | Direct maps | Journal + Database |
| Handlers | Return after execution | Tail-call to next |
| Fusion | None | 30+ synthetic opcodes |
| Validation | Per-operation | Preprocessing |
| Files | ~46 | ~158 |
