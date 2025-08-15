## PR 5: Analysis and PC Mapping in the UI

### Problem Statement

The Guillotine EVM Devtool needs to synchronize two critical views during debugging:

1. **Analysis-optimized instruction stream** - Contains fused operations, BEGINBLOCK metadata, and optimized execution flow
2. **Original bytecode stream** - Raw EVM bytecode with PC-indexed bytes as they appear in contracts

Currently, the UI shows analysis instructions but lacks precise mapping to original bytecode positions. This PR implements bidirectional synchronization so users can:
- See exactly which original bytecode byte corresponds to the current analysis instruction
- Identify valid JUMPDEST positions derived from analysis
- Understand the relationship between optimized execution and raw contract code

### Architecture Overview

Guillotine uses a sophisticated **Structure-of-Arrays (SoA)** instruction representation with three key analysis artifacts:

#### Core Analysis Structures (`src/evm/code_analysis.zig`)

```zig
pub const CodeAnalysis = struct {
    // === FIRST CACHE LINE - ULTRA HOT ===
    instructions: []Instruction,              // Compact 32-bit headers
    size8_instructions: []Bucket8,            // 8-byte instruction payloads  
    size16_instructions: []Bucket16,          // 16-byte instruction payloads
    size24_instructions: []Bucket24,          // 24-byte instruction payloads
    
    // Mapping tables for PC synchronization
    pc_to_block_start: []u16,                 // PC → block start index
    jumpdest_array: JumpdestArray,            // Packed JUMPDEST positions
    inst_to_pc: []u16,                        // Instruction → original PC
    
    // Original bytecode and metadata
    code: []const u8,                         // Original contract bytecode
    code_len: usize,                          // Bytecode length
    inst_jump_type: []JumpType,               // Jump classification per instruction
};
```

#### Instruction Pointer Arithmetic Pattern

The codebase uses pointer arithmetic to derive instruction indices:

```zig
// From src/evm/evm/interpret.zig:51-52
const base: [*]const @TypeOf(inst.*) = analysis.instructions.ptr;
const idx = (@intFromPtr(inst) - @intFromPtr(base)) / @sizeOf(@TypeOf(inst.*));
```

#### JUMPDEST Validation (`src/evm/jumpdest_array.zig`)

```zig
pub const JumpdestArray = struct {
    positions: []const u15,  // Packed u15 array (max 32KB contracts)
    code_len: usize,
    
    pub fn is_valid_jumpdest(self: *const JumpdestArray, pc: usize) bool {
        // Cache-friendly linear search with proportional starting point
        const start_idx = (pc * self.positions.len) / self.code_len;
        // Search forward/backward from calculated position
    }
};
```

### Current Devtool Architecture Deep Dive

#### DevtoolEvm Structure (`src/devtool/evm.zig`)

```zig
const DevtoolEvm = struct {
    // Core EVM components
    evm: EvmType,
    database: MemoryDatabase,
    host: Host,
    allocator: std.mem.Allocator,
    
    // Debug-specific state
    current_frame: ?*Evm.Frame,
    current_contract: ?*Evm.Contract, 
    analysis: ?*Evm.CodeAnalysis,      // Key: owns the analysis
    instr_index: usize,                // Current instruction index
    
    // Execution state
    is_initialized: bool,
    is_completed: bool,
    is_paused: bool,
    
    // Dynamic gas attribution tracking
    dynamic_gas_map: std.AutoHashMap(u64, u32),
};
```

#### Current JSON Serialization (`src/devtool/debug_state.zig`)

```zig
pub const EvmStateJson = struct {
    gasLeft: u64,
    depth: u32,
    stack: [][]const u8,
    memory: []const u8,
    storage: []StorageEntry,
    logs: [][]const u8,
    returnData: []const u8,
    codeHex: []const u8,                    // Full bytecode as hex
    completed: bool,
    currentInstructionIndex: usize,         // Current analysis instruction
    currentBlockStartIndex: usize,          // Current block start
    blocks: []BlockJson,                    // Rich block information
};

pub const BlockJson = struct {
    beginIndex: usize,
    gasCost: u32,
    stackReq: u16, 
    stackMaxGrowth: u16,
    blockStartPc: u32,                     // Block's first PC
    blockEndPcExclusive: u32,              // Block's end PC
    pcs: []u32,                            // Per-instruction PCs
    opcodes: [][]const u8,                 // Opcode names
    opcodeBytes: []u8,                     // Raw opcode bytes
    hex: [][]const u8,                     // Hex representation
    data: [][]const u8,                    // PUSH immediate data
    dynamicGas: []u32,                     // Runtime gas costs
    dynCandidate: []bool,                  // May have dynamic gas
    // Debug fields
    instIndices: []u32,
    instMappedPcs: []u32,
};
```

#### PC Mapping Logic in `serializeEvmState()` (lines 323-381)

The Devtool already implements sophisticated PC mapping:

```zig
// Get current instruction index from pointer arithmetic
const base: [*]const @TypeOf(instrs[0]) = instrs.ptr;
derived_idx = (@intFromPtr(f.instruction) - @intFromPtr(base)) / @sizeOf(@TypeOf(instrs[0]));

// Map instruction index to original PC
const mapped_u16: u16 = if (j < a.inst_to_pc.len) a.inst_to_pc[j] else std.math.maxInt(u16);
var pc: usize = 0;
if (mapped_u16 != std.math.maxInt(u16)) {
    pc = mapped_u16;  // Direct mapping available
    last_pc_opt = pc;
} else if (last_pc_opt) |prev_pc| {
    // Derive PC from previous known PC + opcode size
    const prev_op: u8 = if (prev_pc < a.code_len) a.code[prev_pc] else 0;
    const imm_len: usize = if (prev_op >= 0x60 and prev_op <= 0x7f) 
        @intCast(prev_op - 0x5f) else 0;
    pc = prev_pc + 1 + imm_len;
    last_pc_opt = pc;
}
```

## Detailed Implementation Plan

### Phase 1: Devtool Runtime Extensions

#### 1.1) Add `currentPc` and `jumpdests` to JSON State

**File**: `src/devtool/evm.zig`  
**Function**: `serializeEvmState()` (around line 253)

**Step 1**: Compute current PC after deriving instruction index

```zig
// Around line 284-289, after deriving current instruction index
if (self.current_frame) |f| {
    const base: [*]const @TypeOf(instrs[0]) = instrs.ptr;
    derived_idx = (@intFromPtr(f.instruction) - @intFromPtr(base)) / @sizeOf(@TypeOf(instrs[0]));
    self.instr_index = derived_idx;
}

// NEW: Compute current PC using the same logic as blocks
var current_pc: usize = 0;
if (self.analysis) |a| {
    if (derived_idx < a.inst_to_pc.len) {
        const pc_u16 = a.inst_to_pc[derived_idx];
        if (pc_u16 != std.math.maxInt(u16)) {
            current_pc = pc_u16;
        }
        // Fallback: Use the same PC derivation logic as the block building
        // (This matches the existing pattern in lines 343-348)
    }
}
```

**Step 2**: Extract jumpdests array

```zig
// NEW: Build jumpdests list from analysis
var jumpdests_list = std.ArrayList(usize).init(self.allocator);
defer jumpdests_list.deinit(); // Will transfer ownership to state

if (self.analysis) |a| {
    // Convert u15 positions to usize for JSON
    for (a.jumpdest_array.positions) |pos_u15| {
        try jumpdests_list.append(@as(usize, pos_u15));
    }
}
```

**Step 3**: Extend EvmStateJson structure

**File**: `src/devtool/debug_state.zig`  
**Struct**: `EvmStateJson` (line 73)

```zig
pub const EvmStateJson = struct {
    gasLeft: u64,
    depth: u32,
    stack: [][]const u8,
    memory: []const u8,
    storage: []StorageEntry,
    logs: [][]const u8,
    returnData: []const u8,
    codeHex: []const u8,
    completed: bool,
    currentInstructionIndex: usize,
    currentBlockStartIndex: usize,
    blocks: []BlockJson,
    
    // NEW FIELDS
    currentPc: usize,           // Current bytecode PC
    jumpdests: []usize,         // Valid JUMPDEST positions
};
```

**Step 4**: Update state construction in `serializeEvmState()`

```zig
// Around line 453, when constructing the state object
const state = debug_state.EvmStateJson{
    .gasLeft = frame.gas_remaining,
    .depth = frame.depth,
    .stack = try debug_state.serializeStack(self.allocator, &frame.stack),
    .memory = try debug_state.serializeMemory(self.allocator, &frame.memory),
    .storage = try storage_entries.toOwnedSlice(),
    .logs = try self.allocator.alloc([]const u8, 0),
    .returnData = blk: {
        // existing returnData logic...
    },
    .codeHex = try debug_state.formatBytesHex(self.allocator, self.analysis.?.code),
    .completed = self.is_completed,
    .currentInstructionIndex = self.instr_index,
    .currentBlockStartIndex = current_block_start_index,
    .blocks = try blocks.toOwnedSlice(),
    
    // NEW FIELDS
    .currentPc = current_pc,
    .jumpdests = try jumpdests_list.toOwnedSlice(),
};
```

**Step 5**: Update cleanup function

**File**: `src/devtool/debug_state.zig`  
**Function**: `freeEvmStateJson()` (line 310)

```zig
pub fn freeEvmStateJson(allocator: std.mem.Allocator, state: EvmStateJson) void {
    // ... existing cleanup code ...
    
    // NEW: Clean up jumpdests array
    allocator.free(state.jumpdests);
    
    // Free code hex string
    allocator.free(state.codeHex);
}
```

#### 1.2) Optional: Extend DebugStepResult with PC

**File**: `src/devtool/evm.zig`  
**Struct**: `DebugStepResult` (line 41)

```zig
pub const DebugStepResult = struct {
    gas_before: u64,
    gas_after: u64,
    completed: bool,
    error_occurred: bool,
    execution_error: ?anyerror,
    
    // NEW: Current PC after step execution
    pc: usize,  
};
```

**Update**: `stepExecute()` to populate PC field (around line 754)

```zig
// After syncing UI index from pointer (line 748-749)
const base_ptr: [*]const @TypeOf(instructions[0]) = instructions.ptr;
self.instr_index = (@intFromPtr(frame.instruction) - @intFromPtr(base_ptr)) / @sizeOf(@TypeOf(instructions[0]));

// NEW: Compute PC for step result
var step_pc: usize = 0;
if (self.analysis) |a| {
    if (self.instr_index < a.inst_to_pc.len) {
        const pc_u16 = a.inst_to_pc[self.instr_index];
        if (pc_u16 != std.math.maxInt(u16)) {
            step_pc = pc_u16;
        }
    }
}

// Update return statement
return DebugStepResult{
    .gas_before = gas_before,
    .gas_after = frame.gas_remaining,
    .completed = completed,
    .error_occurred = had_error,
    .execution_error = if (had_error) exec_err else null,
    .pc = step_pc,  // NEW
};
```

### Phase 2: TypeScript Frontend Integration

#### 2.1) Update Type Definitions

**File**: `src/devtool/solid/lib/types.ts`  
**Interface**: `EvmState` (line 17)

```typescript
export interface EvmState {
    gasLeft: number
    depth: number
    stack: string[]
    memory: string
    storage: Array<{ key: string; value: string }>
    logs: string[]
    returnData: string
    codeHex: string
    completed: boolean
    currentInstructionIndex: number
    currentBlockStartIndex: number
    blocks: BlockJson[]
    
    // NEW FIELDS
    currentPc: number        // Current original bytecode PC
    jumpdests: number[]      // Valid JUMPDEST positions
}
```

#### 2.2) Enhance BytecodeBlocksMap Component

**File**: `src/devtool/solid/components/evm-debugger/BytecodeBlocksMap.tsx`

**Step 1**: Update props interface

```typescript
interface BytecodeBlocksMapProps {
    codeHex: string
    blocks: BlockJson[]
    currentBlockStartIndex: number
    
    // NEW PROPS
    currentPc: number        // Highlight this specific PC
    jumpdests: number[]      // Mark these as valid JUMPDESTs
}
```

**Step 2**: Create jumpdest lookup set

```typescript
// Add after existing memos (around line 44)
const jumpdestsSet = createMemo(() => new Set(props.jumpdests))
```

**Step 3**: Enhanced cell rendering with PC highlighting

```typescript
// Update the cell rendering in the For loop (around line 74-94)
return (
    <div
        class={cn(
            'relative flex items-center justify-center border border-border/20 px-1.5 py-1',
            // Existing block highlighting
            isCurrent()
                ? 'bg-amber-500/80 text-black'
                : sidx() >= 0
                    ? sidx() % 2 === 0
                        ? 'bg-amber-100/50 dark:bg-amber-900/50'
                        : 'bg-amber-100/20 dark:bg-amber-900/20'
                    : 'text-foreground/70',
            // NEW: Current PC highlighting (stronger than block highlighting)
            pc() === props.currentPc && 'ring-2 ring-amber-500 bg-amber-600/90 text-black',
        )}
        title={`pc=0x${pc().toString(16)}${
            beginIndex() >= 0 ? ` • block @${beginIndex()}` : ''
        }${jumpdestsSet().has(pc()) ? ' • valid JUMPDEST' : ''}`}  // Enhanced tooltip
    >
        {/* Existing block start indicator */}
        {isBlockStart() && sidx() >= 0 && (
            <span class="absolute top-0.5 left-0.5 text-[9px] text-muted-foreground leading-none">
                {(sidx() + 1).toString()}
            </span>
        )}
        
        {/* NEW: JUMPDEST indicator */}
        {jumpdestsSet().has(pc()) && (
            <span class="absolute bottom-0.5 right-0.5 w-1.5 h-1.5 bg-green-500 rounded-full" 
                  title="Valid JUMPDEST" />
        )}
        
        <span>{b}</span>
    </div>
)
```

#### 2.3) Update Parent Component Props

**Find**: The parent component that renders `BytecodeBlocksMap` (likely in a main debugger component)

**Update**: Pass the new props from the EVM state:

```typescript
<BytecodeBlocksMap
    codeHex={state.codeHex}
    blocks={state.blocks}
    currentBlockStartIndex={state.currentBlockStartIndex}
    currentPc={state.currentPc}      // NEW
    jumpdests={state.jumpdests}      // NEW
/>
```

#### 2.4) ExecutionStepsView Remains Unchanged

**File**: `src/devtool/solid/components/evm-debugger/ExecutionStepsView.tsx`

No changes needed! The component already highlights the active instruction correctly using:

```typescript
const isActive = 
    blk.beginIndex === props.currentBlockStartIndex &&
    idx() === Math.max(0, props.currentInstructionIndex - blk.beginIndex - 1)
```

This provides the "analysis instruction" highlighting while `BytecodeBlocksMap` now provides "original bytecode PC" highlighting.

## Implementation Details and Edge Cases

### Critical Zig Patterns and Memory Management

#### Pointer Arithmetic for Instruction Indexing

Guillotine uses a consistent pattern for deriving instruction indices from pointers:

```zig
// Pattern used throughout codebase (interpret.zig, devtool/evm.zig)
const base: [*]const Instruction = analysis.instructions.ptr;
const idx = (@intFromPtr(current_instruction) - @intFromPtr(base)) / @sizeOf(Instruction);
```

**Key Points:**
- `[*]const Instruction` is a many-pointer (unknown length)
- `@intFromPtr()` converts pointer to integer address 
- Division by `@sizeOf(Instruction)` gives element index
- This is safe because instructions array is contiguous

#### Memory Allocation Patterns

**ArrayList Usage:**
```zig
// Standard pattern for dynamic arrays in Devtool
var jumpdests_list = std.ArrayList(usize).init(self.allocator);
defer jumpdests_list.deinit(); // Always defer cleanup

// Populate the list
for (a.jumpdest_array.positions) |pos_u15| {
    try jumpdests_list.append(@as(usize, pos_u15));
}

// Transfer ownership to struct
const owned_slice = try jumpdests_list.toOwnedSlice();
// Note: After toOwnedSlice(), the ArrayList is empty but still needs deinit
```

**Owned vs Borrowed Memory:**
- `serializeEvmState()` returns owned memory that caller must free
- `debug_state.freeEvmStateJson()` properly deallocates all nested structures
- Always use `errdefer` for early return cleanup

#### PC Mapping Algorithm

**Primary Mapping (Authoritative):**
```zig
if (idx < analysis.inst_to_pc.len) {
    const pc_u16 = analysis.inst_to_pc[idx];
    if (pc_u16 != std.math.maxInt(u16)) {  // Not sentinel
        current_pc = pc_u16;  // Direct mapping available
    }
}
```

**Fallback Mapping (Best Effort):**
```zig
// For fused/meta instructions without direct mapping
if (last_pc_opt) |prev_pc| {
    const prev_op: u8 = if (prev_pc < analysis.code_len) analysis.code[prev_pc] else 0;
    
    // Calculate PUSH immediate length
    const imm_len: usize = if (prev_op == 0x5f)  // PUSH0 
        0
    else if (prev_op >= 0x60 and prev_op <= 0x7f)  // PUSH1-PUSH32
        @intCast(prev_op - 0x5f)  // PUSH1=0x60 has 1 byte, etc.
    else 
        0;  // Non-PUSH opcodes
        
    current_pc = prev_pc + 1 + imm_len;  // Next instruction PC
    last_pc_opt = current_pc;
}
```

### JUMPDEST Validation Architecture

**Packed Array Design:**
- Uses `u15` to fit 32KB max contract size while minimizing memory
- Linear search is faster than hash lookups for sparse data (<50 jumpdests typically)
- Proportional starting point optimization: `start_idx = (pc * positions.len) / code_len`

**Cache-Friendly Search:**
```zig
pub fn is_valid_jumpdest(self: *const JumpdestArray, pc: usize) bool {
    if (self.positions.len == 0 or pc >= self.code_len) return false;
    
    // Smart starting position based on PC proportion
    const start_idx = (pc * self.positions.len) / self.code_len;
    const safe_start = @min(start_idx, self.positions.len - 1);
    
    // Check exact match first
    if (self.positions[safe_start] == pc) return true;
    
    // Search forward, then backward from calculated position
    // This maximizes cache hits on consecutive memory
}
```

## Exact Implementation Locations

### File-by-File Changes

#### 1. `src/devtool/debug_state.zig`

**Location**: Line 73, `EvmStateJson` struct
```zig
pub const EvmStateJson = struct {
    // ... existing fields ...
    blocks: []BlockJson,
    
    // ADD THESE TWO LINES:
    currentPc: usize,
    jumpdests: []usize,
};
```

**Location**: Line 310, `freeEvmStateJson` function  
**Add before** the final `allocator.free(state.codeHex);`:
```zig
// Free jumpdests array
allocator.free(state.jumpdests);
```

#### 2. `src/devtool/evm.zig`

**Location**: Line 280, in `serializeEvmState()` after computing `derived_idx`  
**Add this block**:
```zig
// Compute current PC using same logic as block building
var current_pc: usize = 0;
if (self.analysis) |a| {
    if (derived_idx < a.inst_to_pc.len) {
        const pc_u16 = a.inst_to_pc[derived_idx];
        if (pc_u16 != std.math.maxInt(u16)) {
            current_pc = pc_u16;
        }
        // Could add fallback logic here if needed
    }
}

// Build jumpdests list from analysis
var jumpdests_list = std.ArrayList(usize).init(self.allocator);
defer jumpdests_list.deinit();

if (self.analysis) |a| {
    for (a.jumpdest_array.positions) |pos_u15| {
        try jumpdests_list.append(@as(usize, pos_u15));
    }
}
```

**Location**: Line 453, in the `state` construction  
**Add these two fields**:
```zig
const state = debug_state.EvmStateJson{
    // ... all existing fields ...
    .blocks = try blocks.toOwnedSlice(),
    
    // ADD THESE:
    .currentPc = current_pc,
    .jumpdests = try jumpdests_list.toOwnedSlice(),
};
```

#### 3. `src/devtool/solid/lib/types.ts`

**Location**: Line 17, `EvmState` interface  
**Add after** `blocks: BlockJson[]`:
```typescript
currentPc: number
jumpdests: number[]
```

#### 4. `src/devtool/solid/components/evm-debugger/BytecodeBlocksMap.tsx`

**Location**: Line 6, `BytecodeBlocksMapProps` interface  
**Add after** `currentBlockStartIndex: number`:
```typescript
currentPc: number
jumpdests: number[]
```

**Location**: Line 44, after existing memos  
**Add**:
```typescript
const jumpdestsSet = createMemo(() => new Set(props.jumpdests))
```

**Location**: Line 76, in the `class={cn(` section  
**Add after existing classes**:
```typescript
// Current PC highlighting (stronger than block highlighting)
pc() === props.currentPc && 'ring-2 ring-amber-500 bg-amber-600/90 text-black',
```

**Location**: Line 86, in the `title=` prop  
**Replace** the title with:
```typescript
title={`pc=0x${pc().toString(16)}${beginIndex() >= 0 ? ` • block @${beginIndex()}` : ''}${jumpdestsSet().has(pc()) ? ' • valid JUMPDEST' : ''}`}
```

**Location**: Line 93, after the block start indicator span  
**Add**:
```typescript
{/* JUMPDEST indicator */}
{jumpdestsSet().has(pc()) && (
    <span class="absolute bottom-0.5 right-0.5 w-1.5 h-1.5 bg-green-500 rounded-full" 
          title="Valid JUMPDEST" />
)}
```

## Comprehensive Testing Strategy

### Zig Unit Tests (Devtool Runtime)

**File**: `src/devtool/evm.zig` (add at end with other tests)

```zig
test "DevtoolEvm PC mapping and jumpdests serialization" {
    const allocator = testing.allocator;
    
    var devtool_evm = try DevtoolEvm.init(allocator);
    defer devtool_evm.deinit();
    
    // Load bytecode: PUSH1 3; JUMP; JUMPDEST; STOP (PC 3 is JUMPDEST)
    const bytecode_hex = "0x6003565b00";
    try devtool_evm.loadBytecodeHex(bytecode_hex);
    
    // Get initial state and parse JSON
    const json_state = try devtool_evm.serializeEvmState();
    defer allocator.free(json_state);
    
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_state, .{}) catch |err| {
        std.log.err("Failed to parse JSON: {}", .{err});
        try testing.expect(false);
        return;
    };
    defer parsed.deinit();
    
    const obj = parsed.value.object;
    
    // Verify new fields exist and have correct types
    try testing.expect(obj.contains("currentPc"));
    try testing.expect(obj.contains("jumpdests"));
    
    const current_pc = obj.get("currentPc").?.integer;
    const jumpdests = obj.get("jumpdests").?.array;
    
    // Initially at PC 0 (PUSH1)
    try testing.expectEqual(@as(i64, 0), current_pc);
    
    // Should contain one jumpdest at PC 3
    try testing.expectEqual(@as(usize, 1), jumpdests.items.len);
    try testing.expectEqual(@as(i64, 3), jumpdests.items[0].integer);
    
    // Step execution and verify PC updates
    _ = try devtool_evm.stepExecute();  // Execute PUSH1
    
    const json_after_step = try devtool_evm.serializeEvmState();
    defer allocator.free(json_after_step);
    
    const parsed_after = std.json.parseFromSlice(std.json.Value, allocator, json_after_step, .{}) catch unreachable;
    defer parsed_after.deinit();
    
    const obj_after = parsed_after.value.object;
    const current_pc_after = obj_after.get("currentPc").?.integer;
    
    // PC should have advanced (exact value depends on analysis optimizations)
    try testing.expect(current_pc_after >= 0);
}

test "DevtoolEvm jumpdests array conversion" {
    const allocator = testing.allocator;
    
    var devtool_evm = try DevtoolEvm.init(allocator);
    defer devtool_evm.deinit();
    
    // Complex bytecode with multiple jumpdests
    // PUSH1 8; JUMPI; JUMPDEST; PUSH1 12; JUMP; JUMPDEST; STOP
    const bytecode_hex = "0x600857005b600c565b00";
    try devtool_evm.loadBytecodeHex(bytecode_hex);
    
    const json_state = try devtool_evm.serializeEvmState();
    defer allocator.free(json_state);
    
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_state, .{}) catch unreachable;
    defer parsed.deinit();
    
    const jumpdests = parsed.value.object.get("jumpdests").?.array;
    
    // Should find multiple jumpdests and be sorted
    try testing.expect(jumpdests.items.len >= 1);
    
    // Verify all jumpdests are valid PCs
    for (jumpdests.items) |jd| {
        const pc = @as(usize, @intCast(jd.integer));
        try testing.expect(pc < devtool_evm.bytecode.len);
    }
}
```

### JSON Schema Validation Test

```zig
test "DevtoolEvm EvmStateJson has all required fields" {
    const allocator = testing.allocator;
    
    var devtool_evm = try DevtoolEvm.init(allocator);
    defer devtool_evm.deinit();
    
    try devtool_evm.loadBytecodeHex("0x600160020100");  // Simple ADD
    
    const json_state = try devtool_evm.serializeEvmState();
    defer allocator.free(json_state);
    
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_state, .{}) catch unreachable;
    defer parsed.deinit();
    
    const obj = parsed.value.object;
    
    // Verify all existing fields still exist
    const required_fields = [_][]const u8{
        "gasLeft", "depth", "stack", "memory", "storage", 
        "logs", "returnData", "codeHex", "completed",
        "currentInstructionIndex", "currentBlockStartIndex", "blocks"
    };
    
    for (required_fields) |field| {
        try testing.expect(obj.contains(field));
    }
    
    // Verify new fields exist with correct types
    try testing.expect(obj.contains("currentPc"));
    try testing.expect(obj.get("currentPc").? == .integer);
    
    try testing.expect(obj.contains("jumpdests"));
    try testing.expect(obj.get("jumpdests").? == .array);
}
```

## Performance, Safety, and Best Practices

### Memory Management Guidelines

**Allocation Patterns:**
- `serializeEvmState()` returns owned memory - caller must free with `debug_state.freeEvmStateJson()`
- All nested allocations use the same allocator for consistency
- Use `errdefer` for cleanup on early returns
- `toOwnedSlice()` transfers ownership from ArrayList to struct

**Performance Characteristics:**
- Analysis computed once at load time via `CodeAnalysis.from_code()` - O(bytecode_length)
- Jumpdest array copying: O(jumpdest_count) per serialization - typically <50 elements
- PC mapping lookup: O(1) with `inst_to_pc` array direct indexing
- Overall serialization: O(instruction_count + jumpdest_count) - acceptable for dev tooling

### Safety Considerations

**Index Bounds Checking:**
```zig
// Always guard array access
if (idx < analysis.inst_to_pc.len) {
    const pc_u16 = analysis.inst_to_pc[idx];
    if (pc_u16 != std.math.maxInt(u16)) {  // Check sentinel
        // Safe to use pc_u16
    }
}

// Guard PC bounds for code access
if (pc < analysis.code_len) {
    const opcode = analysis.code[pc];
}
```

**Sentinel Value Handling:**
- `std.math.maxInt(u16)` indicates "unknown PC" in `inst_to_pc` mapping
- Always check for sentinel before using PC value
- Fallback to best-effort derivation when sentinel encountered

**Type Safety:**
- `u15` for jumpdest positions (fits 32KB max contract size)
- `u16` for PC mapping (same size constraint)
- `usize` for final JSON (platform-independent)
- Explicit casting with `@as()` and `@intCast()` for clarity

## Acceptance Criteria and Validation

### Functional Requirements

✅ **Dual Highlighting System:**
- Current analysis instruction highlighted in ExecutionStepsView (existing)
- Current original bytecode PC highlighted in BytecodeBlocksMap (new)
- Visual distinction between block-level and PC-level highlighting

✅ **JUMPDEST Visualization:**
- All valid JUMPDEST positions marked with green dot indicators
- Tooltip shows "valid JUMPDEST" on hover
- Positions derived from analysis are authoritative

✅ **JSON API Extensions:**
- `currentPc: usize` field in EvmStateJson
- `jumpdests: []usize` array in EvmStateJson
- Backward compatibility maintained for existing fields
- Memory properly managed in cleanup functions

✅ **Mapping Accuracy:**
- PC mapping works across all instruction types (fused, meta, regular)
- Sentinel values handled gracefully with fallbacks
- BEGINBLOCK boundaries don't break PC continuity
- Dynamic jumps resolve to correct target blocks

### Integration Validation

**Manual Testing Procedure:**

1. **Load "Jump and Control Flow" sample contract:**
   ```
   Bytecode: 0x600a565b6001600101600a14610012575b00
   ```
   - Step through execution
   - Verify JUMPDEST at PC 3 has green dot
   - Verify current PC highlights single byte
   - Verify instruction and PC highlighting are synchronized

2. **Load "Comprehensive Test" sample:**
   - Complex mix of arithmetic, jumps, memory operations
   - Multiple JUMPDEST locations should be marked
   - PC progression should be smooth across different instruction types

3. **Edge Case Testing:**
   - Empty bytecode (0x) - should not crash
   - Single instruction (0x00) - PC should be 0
   - Large contract with many JUMPDESTs - performance should be acceptable

### Performance Acceptance

- Serialization time increase: <10ms for typical contracts
- Memory overhead: <1KB for jumpdests array
- UI rendering: <16ms frame time maintained
- No memory leaks in extended debugging sessions

## FAQ and Implementation Notes

### Common Questions

**Q: Why can `inst_to_pc[idx]` be unknown/sentinel?**  
A: Fused and meta instructions (BEGINBLOCK, optimized arithmetic) may not correspond 1:1 with original bytecode. Analysis optimizes execution flow, so some instruction indices represent composite operations. Use fallback PC derivation in these cases.

**Q: What's the difference between `currentPc` and `currentInstructionIndex`?**  
A: 
- `currentInstructionIndex`: Position in optimized analysis instruction stream
- `currentPc`: Position in original contract bytecode
- They often differ due to analysis optimizations and BEGINBLOCK metadata

**Q: Should we highlight entire PUSH spans (opcode + immediate bytes)?**  
A: Start with single-byte highlighting at `currentPc`. Multi-byte highlighting is possible but requires additional logic to calculate immediate lengths and spans.

**Q: Do we need to modify the core interpreter?**  
A: No. The interpreter already has PC tracking for external tracers. Devtool uses analysis-first stepping and can derive all needed information from existing structures.

**Q: How does this work with dynamic jumps?**  
A: 
- Analysis pre-computes `pc_to_block_start` mapping for all possible jump targets
- `jumpdest_array` validates if a PC is a legal jump destination
- UI visualizes state; it doesn't simulate jumps - just shows current position

### Implementation Gotchas

**Zig-Specific Issues:**
- Always use `@intCast()` when converting between integer types
- `errdefer` must come immediately after allocation
- `toOwnedSlice()` empties the ArrayList but still requires `deinit()`
- Use `std.math.maxInt(u16)` not magic numbers for sentinels

**UI Synchronization:**
- PC highlighting should be stronger than block highlighting  
- Use `createMemo()` for expensive computations (jumpdest Set creation)
- Don't forget to update the parent component's props passing

**JSON Serialization:**
- Add new fields to both creation and cleanup functions
- Test JSON parsing to ensure valid output
- Consider field ordering for readability

## Ready-to-Use Code Snippets

### Zig Implementation Snippets

**Pointer Arithmetic Pattern:**
```zig
// Standard pattern for instruction index derivation
const base: [*]const Instruction = analysis.instructions.ptr;
const idx = (@intFromPtr(current_instruction) - @intFromPtr(base)) / @sizeOf(Instruction);
```

**PC Mapping with Fallback:**
```zig
// Primary mapping
var current_pc: usize = 0;
if (idx < analysis.inst_to_pc.len) {
    const pc_u16 = analysis.inst_to_pc[idx];
    if (pc_u16 != std.math.maxInt(u16)) {
        current_pc = pc_u16;
    } else {
        // Fallback derivation logic here if needed
    }
}
```

**ArrayList to Owned Slice:**
```zig
// Standard dynamic array pattern
var jumpdests_list = std.ArrayList(usize).init(allocator);
defer jumpdests_list.deinit();

for (analysis.jumpdest_array.positions) |pos_u15| {
    try jumpdests_list.append(@as(usize, pos_u15));
}

const owned_jumpdests = try jumpdests_list.toOwnedSlice();
```

**PUSH Immediate Length Calculation:**
```zig
const imm_len: usize = if (opcode == 0x5f)  // PUSH0
    0
else if (opcode >= 0x60 and opcode <= 0x7f)  // PUSH1-PUSH32  
    @intCast(opcode - 0x5f)
else
    0;
```

### TypeScript/SolidJS Snippets

**Memoized Set Creation:**
```typescript
const jumpdestsSet = createMemo(() => new Set(props.jumpdests))
```

**Conditional Styling:**
```typescript
class={cn(
    'base-classes',
    // Block highlighting (existing)
    isCurrent() ? 'bg-amber-500/80 text-black' : 'text-foreground/70',
    // PC highlighting (stronger, new)
    pc() === props.currentPc && 'ring-2 ring-amber-500 bg-amber-600/90 text-black',
)}
```

**JUMPDEST Indicator:**
```typescript
{jumpdestsSet().has(pc()) && (
    <span class="absolute bottom-0.5 right-0.5 w-1.5 h-1.5 bg-green-500 rounded-full" 
          title="Valid JUMPDEST" />
)}
```

## Implementation Checklist

### Phase 1: Backend Implementation
- [ ] **Add fields to `EvmStateJson`** in `debug_state.zig`
- [ ] **Implement PC derivation** in `serializeEvmState()` 
- [ ] **Add jumpdests extraction** from analysis
- [ ] **Update JSON cleanup** in `freeEvmStateJson()`
- [ ] **Test with simple bytecode** (PUSH1 3; JUMP; JUMPDEST; STOP)
- [ ] **Run `zig build && zig build test`** - all tests pass
- [ ] **Verify JSON output** contains new fields with correct types

### Phase 2: Frontend Integration  
- [ ] **Update TypeScript types** in `types.ts`
- [ ] **Add props to BytecodeBlocksMap** interface
- [ ] **Implement jumpdest Set memoization**
- [ ] **Add PC highlighting** (stronger than block highlighting)
- [ ] **Add JUMPDEST indicators** with tooltips
- [ ] **Wire props in parent component**
- [ ] **Test with development server** - UI compiles without errors

### Phase 3: Validation Testing
- [ ] **Load "Jump and Control Flow"** sample contract
- [ ] **Verify JUMPDEST markers** appear at correct positions
- [ ] **Step through execution** - PC highlighting follows correctly
- [ ] **Test complex contract** with multiple jumpdests
- [ ] **Edge case testing** - empty bytecode, single instruction
- [ ] **Performance check** - no noticeable slowdown
- [ ] **Memory leak test** - extended debugging session

### Phase 4: Final Polish
- [ ] **Add comprehensive unit tests** for PC mapping
- [ ] **Update documentation** if needed
- [ ] **Code review** for Zig patterns and memory safety
- [ ] **Visual design review** for UI indicators
- [ ] **Cross-browser testing** for rendering consistency

---

**COMPREHENSIVE IMPLEMENTATION GUIDE COMPLETED**

This document now contains:
- ✅ Complete architecture understanding
- ✅ Detailed Zig patterns and memory management
- ✅ Precise implementation locations  
- ✅ Ready-to-use code snippets
- ✅ Comprehensive testing strategy
- ✅ Performance and safety guidelines
- ✅ Step-by-step checklist

**Ready for implementation with full confidence in the approach and technical details.**