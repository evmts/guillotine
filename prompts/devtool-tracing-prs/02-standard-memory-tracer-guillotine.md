## PR 2: Standard Memory Tracer for Guillotine

### Problem

Devtool needs full, structured per-step state snapshots (pc, opcode, gas before/after, stack, memory, storage diffs, logs) to visualize and scrub execution. The current built-in tracer streams REVM-like JSON lines and cannot provide structured, in-process access or bounded memory capture.

The interpreter uses a block-based execution model with pre-validation and aggregated gas charging, so per-op gas accounting cannot be naïvely derived without understanding the instruction stream produced by analysis. We must integrate at the correct hook points and derive values accurately from the frame and analysis data structures.

### Guillotine EVM Architecture Overview

**Core Components:**
- **Frame**: Execution context containing stack, memory, gas, and state
- **Instruction Stream**: Pre-analyzed bytecode converted to structured operations 
- **Block-Based Execution**: Groups instructions for bulk gas validation and stack checks
- **Hook System**: `pre_step()` function called before each instruction with compile-time guards
- **Module System**: Organized as Zig modules with explicit imports (defined in `build.zig`)

**Execution Flow:**
1. Bytecode → `CodeAnalysis` → instruction stream with PC mapping
2. Block-based validation charges gas for multiple ops upfront
3. `interpret()` loop dispatches on instruction tags (.block_info, .exec, .dynamic_gas, etc.)
4. `pre_step()` called before each instruction when `build_options.enable_tracing` is true
5. Instruction execution mutates Frame state (stack, memory, storage)

**Memory Management:**
- All allocations use explicit allocators passed down
- `defer` patterns mandatory immediately after allocation  
- Frame owns Stack (32KB) and Memory (4KB initial, expandable)
- State managed through DatabaseInterface abstraction
- Journaling system tracks revertible changes

### What Exists Today (Key References)

**Current Tracer Implementation (`src/evm/tracer.zig`)**:
- Simple struct with `std.io.AnyWriter` for JSON output
- `trace()` method writes REVM-compatible JSON lines 
- Stack values serialized as hex strings with minimal formatting
- Opcode names resolved via `opcodes.get_name(op_enum)`
- Gas values formatted as hex strings: `"0x{x}"`
- No memory data capture (only memory size)
- Hardcoded fields: `{"pc":123,"op":1,"gas":"0x1e8480","gasCost":"0x0","stack":["0xa","0x14"],"depth":0,"returnData":"0x","refund":"0x0","memSize":1024,"opName":"ADD"}`

**Critical Implementation Details:**
```zig
// src/evm/tracer.zig key methods:
pub fn trace(
    self: *Tracer,
    pc: usize,
    opcode: u8,
    stack: []const u256,
    gas: u64,
    gas_cost: u64,          // Always 0 in current hook due to block-based charging
    memory_size: usize,     // Only size, no memory content
    depth: u32,
) !void {
    // Resolves opcode enum and name
    const op_enum = std.meta.intToEnum(opcodes.Enum, opcode) catch opcodes.Enum.INVALID;
    const op_name = opcodes.get_name(op_enum);
    
    // Stack serialized as JSON array of hex strings
    for (stack, 0..) |value, i| {
        const hex_str = try std.fmt.bufPrint(&hex_buf, "0x{x}", .{value});
        // Outputs: ["0xa", "0x14", ...]
    }
}
```

**EVM Integration (`src/evm/evm.zig`)**:
```zig
pub const Evm = struct {
    // ... other fields
    
    /// Optional tracer for capturing execution traces  
    tracer: ?std.io.AnyWriter = null,
    /// Open file handle used by tracer when tracing to file
    trace_file: ?std.fs.File = null,
    
    // File-based tracing API
    pub fn enable_tracing_to_path(self: *Evm, path: []const u8, append: bool) !void {
        // Opens file and assigns writer to self.tracer
        const file = if (append) 
            try std.fs.cwd().openFile(path, .{ .mode = .write_only, .end_pos = null })
        else 
            try std.fs.cwd().createFile(path, .{});
        self.trace_file = file;
        self.tracer = file.writer().any();
    }
    
    pub fn disable_tracing(self: *Evm) void {
        if (self.trace_file) |file| file.close();
        self.tracer = null;
        self.trace_file = null;
    }
};
```

**Interpreter Hook System (`src/evm/evm/interpret.zig`)**:

The core hook is `pre_step()` called before each instruction:
```zig
inline fn pre_step(self: *Evm, frame: *Frame, inst: *const Instruction, loop_iterations: *usize) void {
    // Infinite loop protection (Debug/ReleaseSafe only)
    if (comptime SAFE) {
        loop_iterations.* += 1;
        if (loop_iterations.* > MAX_ITERATIONS) unreachable;
    }

    // Tracing integration (compile-time guard)
    if (comptime build_options.enable_tracing) {
        const analysis = frame.analysis;
        if (self.tracer) |writer| {
            // CRITICAL: Map instruction pointer back to PC
            const base: [*]const @TypeOf(inst.*) = analysis.instructions.ptr;
            const idx = (@intFromPtr(inst) - @intFromPtr(base)) / @sizeOf(@TypeOf(inst.*));
            
            if (idx < analysis.inst_to_pc.len) {
                const pc_u16 = analysis.inst_to_pc[idx];
                if (pc_u16 != std.math.maxInt(u16)) {
                    const pc: usize = pc_u16;
                    const opcode: u8 = if (pc < analysis.code_len) frame.analysis.code[pc] else 0x00;
                    
                    // Access current frame state
                    const stack_len: usize = frame.stack.size();
                    const stack_view: []const u256 = frame.stack.data[0..stack_len];
                    const mem_size: usize = frame.memory.size();
                    
                    // Call existing tracer
                    var tr = Tracer.init(writer);
                    _ = tr.trace(pc, opcode, stack_view, frame.gas_remaining, 0, mem_size, @intCast(frame.depth)) catch {};
                }
            }
        }
    }
}
```

**Key Analysis Points:**
- **PC Mapping**: Uses `analysis.inst_to_pc[idx]` to map instruction index → original PC
- **Opcode Resolution**: Looks up original bytecode at PC: `frame.analysis.code[pc]`
- **State Access**: Direct access to Frame fields (stack, memory, gas, depth)
- **Compile-time Optimization**: Entire tracing block compiled out unless `build_options.enable_tracing`
- **Error Handling**: Tracing errors are silently ignored (`catch {}`)

**Block-Based Execution Model** (`src/evm/evm/interpret.zig`):

The core interpreter loop operates on instruction streams, not raw bytecode:
```zig
pub fn interpret(self: *Evm, frame: *Frame) ExecutionError.Error!void {
    var instruction: *const Instruction = &frame.analysis.instructions[0];
    var loop_iterations: usize = 0;

    dispatch: switch (instruction.tag) {
        // Pre-charges gas for entire instruction block
        .block_info => {
            pre_step(self, frame, instruction, &loop_iterations);
            const block_inst = analysis.getInstructionParams(.block_info, instruction.id);
            
            // Validate gas for entire block upfront
            if (frame.gas_remaining < block_inst.gas_cost) {
                frame.gas_remaining = 0;
                return ExecutionError.Error.OutOfGas;
            }
            frame.gas_remaining -= block_inst.gas_cost;
            
            // Validate stack requirements for entire block
            if (current_stack_size < block_inst.stack_req) {
                return ExecutionError.Error.StackUnderflow;
            }
            if (current_stack_size + block_inst.stack_max_growth > 1024) {
                return ExecutionError.Error.StackOverflow;
            }
            
            instruction = block_inst.next_inst;
            continue :dispatch instruction.tag;
        },
        
        // Execute single opcode
        .exec => {
            pre_step(self, frame, instruction, &loop_iterations);  // ← Hook here
            const exec_inst = analysis.getInstructionParams(.exec, instruction.id);
            try exec_inst.exec_fn(frame);  // ← Frame state mutated here
            instruction = exec_inst.next_inst;
            continue :dispatch instruction.tag;
        },
        
        // Execute opcode with dynamic gas calculation
        .dynamic_gas => {
            pre_step(self, frame, instruction, &loop_iterations);  // ← Hook here
            const dyn_inst = analysis.getInstructionParams(.dynamic_gas, instruction.id);
            const additional_gas = try dyn_inst.gas_fn(frame);
            if (frame.gas_remaining < additional_gas) {
                frame.gas_remaining = 0;
                return ExecutionError.Error.OutOfGas;
            }
            frame.gas_remaining -= additional_gas;
            try dyn_inst.exec_fn(frame);  // ← Frame state mutated here
            instruction = dyn_inst.next_inst;
            continue :dispatch instruction.tag;
        },
        
        // No-op instructions
        .noop => {
            pre_step(self, frame, instruction, &loop_iterations);
            const noop_inst = analysis.getInstructionParams(.noop, instruction.id);
            instruction = noop_inst.next_inst;
            continue :dispatch instruction.tag;
        },
        
        // Jump handling
        .conditional_jump_pc => {
            pre_step(self, frame, instruction, &loop_iterations);
            const cjp_inst = analysis.getInstructionParams(.conditional_jump_pc, instruction.id);
            const condition = frame.stack.pop_unsafe();
            
            if (condition != 0) {
                instruction = cjp_inst.jump_target;  // Jump taken
            } else {
                instruction = cjp_inst.next_inst;    // Fall through
            }
            continue :dispatch instruction.tag;
        },
        // ... other jump variants
    }
}
```

**Critical Implications for Tracing:**
- **Pre/Post Hook Locations**: `pre_step()` called before execution, need post-step hook after `exec_fn(frame)`
- **Gas Semantics**: Block-based charging means `gas_cost` in `pre_step` is always 0, need to track gas deltas
- **State Mutation Points**: Frame state changes during `exec_fn()` and `gas_fn()` calls
- **PC→Instruction Mapping**: Analysis provides `inst_to_pc` array for reverse mapping

**Core Execution State Types and APIs:**

**Frame Structure (`src/evm/frame.zig`)**:
```zig
pub const Frame = struct {
    // FIRST CACHE LINE (64 bytes) - ULTRA HOT
    gas_remaining: u64,              // Current gas available
    stack: Stack,                    // 32 bytes - EVM stack (1024 x u256)
    analysis: *const CodeAnalysis,   // Bytecode analysis with PC mapping
    host: Host,                      // 16 bytes - hardfork checks, gas costs

    // SECOND CACHE LINE - MEMORY OPERATIONS  
    memory: Memory,                  // 72 bytes - EVM memory (MLOAD/MSTORE)

    // THIRD CACHE LINE - STORAGE OPERATIONS
    state: DatabaseInterface,        // Database for storage operations
    contract_address: primitives.Address.Address,  // 20 bytes - current contract
    depth: u16,                      // Call depth for reentrancy checks
    is_static: bool,                 // Static call context (no SSTORE)

    // FOURTH CACHE LINE - CALL CONTEXT
    caller: primitives.Address.Address,  // 20 bytes - caller address  
    value: u256,                     // 32 bytes - call value
    input_buffer: []const u8 = &.{}, // Call input data
    output_buffer: []const u8 = &.{}, // Return/revert data

    // Key API methods:
    pub fn consume_gas(self: *Frame, amount: u64) ExecutionError.Error!void;
    pub fn valid_jumpdest(self: *Frame, dest: u256) bool;
    pub fn get_storage(self: *const Frame, slot: u256) u256;
    pub fn set_storage(self: *Frame, slot: u256, value: u256) !void;
    pub fn get_original_storage(self: *const Frame, slot: u256) u256;
    pub fn get_transient_storage(self: *const Frame, slot: u256) u256;
    pub fn set_transient_storage(self: *Frame, slot: u256, value: u256) !void;
    pub fn access_address(self: *Frame, addr: primitives.Address.Address) ExecutionError.Error!u64;
    pub fn mark_storage_slot_warm(self: *Frame, slot: u256) !bool;
    pub fn set_output(self: *Frame, data: []const u8) ExecutionError.Error!void;
    pub fn adjust_gas_refund(self: *Frame, delta: i64) void;
};
```

**Stack API (`src/evm/stack/stack.zig`)**:
```zig
pub const Stack = struct {
    current: [*]u256,      // Current stack top pointer
    base: [*]u256,         // Stack base pointer  
    limit: [*]u256,        // Stack limit (base + 1024)
    data: *[CAPACITY]u256, // Actual stack data (32KB allocation)

    pub const CAPACITY: usize = 1024;  // EVM spec limit

    // Core API
    pub fn size(self: *const Stack) usize;
    pub fn is_empty(self: *const Stack) bool;
    pub fn is_full(self: *const Stack) bool;
    pub fn append(self: *Stack, value: u256) Error!void;
    pub fn append_unsafe(self: *Stack, value: u256) void;
    pub fn pop(self: *Stack) Error!u256;
    pub fn pop_unsafe(self: *Stack) u256;
    pub fn peek(self: *const Stack) Error!u256;
    pub fn peek_unsafe(self: *const Stack) u256;
    
    // DUP/SWAP operations
    pub fn dup(self: *Stack, n: usize) Error!void;
    pub fn swap(self: *Stack, n: usize) Error!void;
    
    // Direct access for tracing (safe slice of active data)
    // Use: frame.stack.data[0..frame.stack.size()]
};
```

**Memory API (`src/evm/memory/memory.zig`)**:
```zig
pub const Memory = struct {
    my_checkpoint: usize,                   // Current memory checkpoint
    memory_limit: u64,                      // Maximum memory size (gas limit)
    shared_buffer_ref: *std.ArrayList(u8),  // Shared memory buffer
    allocator: std.mem.Allocator,          // For allocations
    owns_buffer: bool,                      // Whether this instance owns buffer

    // Size and access
    pub inline fn size(self: *const Memory) usize;           // Current memory size
    pub inline fn get_memory_ptr(self: *const Memory) [*]u8; // Direct memory pointer  
    pub inline fn get_checkpoint(self: *const Memory) usize; // Current checkpoint
    
    // Memory operations
    pub fn get_expansion_cost(self: *Memory, new_size: u64) u64;
    pub fn charge_and_ensure(self: *Memory, frame: anytype, new_size: u64) !void;
    
    // For bounded memory capture:
    // memory_slice = memory.shared_buffer_ref.items[checkpoint..checkpoint+size()]
};
```

**State Management and Journaling (`src/evm/state/state.zig`, `src/evm/call_frame_stack.zig`)**:

```zig
// EVM state container
pub const EvmState = struct {
    allocator: std.mem.Allocator,
    database: DatabaseInterface,              // Persistent storage backend
    transient_storage: std.AutoHashMap(StorageKey, u256), // EIP-1153 TSTORE/TLOAD
    logs: std.ArrayList(EvmLog),             // Event logs (LOG0-LOG4)
    selfdestructs: std.AutoHashMap(Address, Address), // SELFDESTRUCT tracking
    
    // Access logs for bounded capture
    // logs.items[from_index..]  gives new logs since last capture
};

// Journal for revertible operations
pub const CallJournal = struct {
    entries: ArrayList(JournalEntry),        // All revertible changes
    next_snapshot_id: u32,                   // Snapshot ID counter
    original_storage: AutoHashMap(Address, AutoHashMap(u256, u256)), // Original values

    pub fn record_storage_change(
        self: *CallJournal, 
        snapshot_id: u32, 
        address: Address, 
        key: u256, 
        original_value: u256
    ) !void;
    
    pub fn get_original_storage(self: *const CallJournal, address: Address, key: u256) ?u256;
    pub fn create_snapshot(self: *CallJournal) u32;
    pub fn revert_to_snapshot(self: *CallJournal, snapshot_id: u32) void;
};

// Journal entry types
pub const JournalEntry = union(enum) {
    storage_change: struct {
        snapshot_id: u32,
        address: Address,
        key: u256,
        original_value: u256,
    },
    balance_change: struct {
        snapshot_id: u32,
        address: Address,
        original_balance: u256,
    },
    log_entry: struct {
        snapshot_id: u32,
        // Mark log entries for removal on revert
    },
    // ... other entry types
};
```

**For tracing storage changes:**
- Journal tracks all storage modifications with original values
- Use journal entry count as "from" marker for incremental capture
- `journal.entries[from_index..]` gives storage changes since last step
- Original values available via `get_original_storage(address, key)`

### Goals

- Implement a structured, in-process tracer that consumes interpreter hooks and records full step data for the UI.
- Provide retrieval APIs: get full trace or incremental steps for live streaming.
- Maintain strict memory ownership; allow configurable, bounded memory capture.
- Preserve zero overhead in release builds or when tracing is disabled, using existing compile-time guards.

### Scope and Architecture

Introduce `src/evm/tracing/` with three files:

- `tracer.zig`: interface (vtable-like) and shared data structs.
- `standard_tracer.zig`: default in-process tracer implementation (collects and stores steps with bounded snapshots; can stream).
- `capture_utils.zig`: helpers to efficiently snapshot stack/memory/storage/logs with minimal copies and safe ownership.

Do not remove the existing `src/evm/tracer.zig` JSON streaming tracer; keep it for file-based tracing. The new in-process tracer is additive and pluggable.

### Files to Add

- `src/evm/tracing/tracer.zig`
- `src/evm/tracing/standard_tracer.zig`
- `src/evm/tracing/capture_utils.zig`

### Integration

- `src/evm/root.zig`: export tracer types.
- `src/evm/evm.zig`: add `set_tracer(tracer: ?TracerHandle)` and call tracer via hooks.
- `src/evm/evm/interpret.zig`: insert post-step capture calls next to existing `pre_step()` sites.

### Data Model (summarized)

- StepInfo: pc, opcode, op_name, gas_before, depth, address, caller, is_static, stack_size, memory_size.
- StepResult: gas_after, gas_cost, stack_snapshot, memory_snapshot (+ window), storage_changes, logs_emitted, error.
- StructLog: pc, op string, gas before, gas_cost, depth, stack snapshot, memory snapshot (bounded).
- ExecutionTrace: gas_used, failed, return_value, struct_logs[].

### Memory Strategy

- Bounded memory capture: configurable max bytes; when exceeded, capture window around accessed region plus summary sizes.
- Stack captured as copy of current stack; for very deep stacks, allow truncation with tail note.
- Storage captured as per-step modified slots only.

### Tests

- Unit tests under `test/evm/`:
  - Trace simple arithmetic and verify struct logs sequence.
  - Trace memory ops (MSTORE/MLOAD/MCOPY) and verify memory window.
  - Trace storage ops (SSTORE/SLOAD) and verify changed slots.
  - Control flow (JUMP/JUMPI) including invalids; verify pc mapping and error reporting.
  - Logs (LOG0-LOG4) and bounded data capture.
  - Zero-overhead when no tracer set (compile-time guard + sanity perf guard).

### Acceptance Criteria

- Tracer compiles, integrates, and produces deterministic struct logs for known bytecode samples.
- Tests cover arithmetic, memory, storage, logs, control flow, and error steps.
- No allocations on hot path when tracing is disabled.
- Bounded capture obeys configuration limits.

### Notes

- Opcode-to-string mapping should reuse existing opcode metadata where possible.
- Consider mapping `analysis` instruction index back to original PC for UI (PR 5).

### Gas Semantics and Limitations

- The interpreter pre-charges aggregated gas per block in `.block_info`. As a result, per-op `gas_cost = gas_before - gas_after` at `.exec` boundaries may not align perfectly with spec per-op costs. This is acceptable for PR 2 (UI tracing). We can later apportion block base costs across ops once we expose block boundaries to the tracer (PR 5).

### Detailed Implementation Guide (Step-by-step)

#### Step 1: Core Tracer Interface (`src/evm/tracing/tracer.zig`)

**Define the data structures following Zig conventions:**

```zig
const std = @import("std");
const primitives = @import("primitives");
const Address = primitives.Address.Address;

/// Configuration for tracing bounds
pub const TracerConfig = struct {
    memory_max_bytes: usize = 1024,
    stack_max_items: usize = 32,
    log_data_max_bytes: usize = 512,
};

/// Pre-execution step information
pub const StepInfo = struct {
    pc: usize,
    opcode: u8,
    op_name: []const u8,
    gas_before: u64,
    depth: u16,
    address: Address,
    caller: Address,
    is_static: bool,
    stack_size: usize,
    memory_size: usize,
};

/// Post-execution step results with bounded captures
pub const StepResult = struct {
    gas_after: u64,
    gas_cost: u64,                    // Computed as gas_before - gas_after
    stack_snapshot: ?[]u256,          // Bounded copy, null if too large
    memory_snapshot: ?[]u8,           // Bounded copy or window
    storage_changes: []StorageChange, // Only changes this step
    logs_emitted: []LogEntry,         // Only logs this step
    error_info: ?ExecutionErrorInfo,  // Set if step failed
};

/// Storage change entry
pub const StorageChange = struct {
    address: Address,
    key: u256,
    value: u256,
    original_value: u256,
};

/// Log entry with bounded data
pub const LogEntry = struct {
    address: Address,
    topics: []const u256,           // Always include all topics
    data: []const u8,               // Bounded by log_data_max_bytes
    data_truncated: bool,           // True if original data was larger
};

/// Combined step entry for structured logs
pub const StructLog = struct {
    pc: usize,
    op: []const u8,        // Opcode name
    gas: u64,              // gas_before
    gas_cost: u64,         // gas consumed
    depth: u16,
    stack: ?[]const u256,  // null if bounded out
    memory: ?[]const u8,   // null if bounded out  
    storage: []const StorageChange,
    logs: []const LogEntry,
    error_info: ?ExecutionErrorInfo,
};

/// Complete execution trace
pub const ExecutionTrace = struct {
    gas_used: u64,
    failed: bool,
    return_value: []const u8,
    struct_logs: []const StructLog,
    
    /// Must be called to free all allocations
    pub fn deinit(self: *ExecutionTrace, allocator: std.mem.Allocator) void {
        // Free all nested allocations...
    }
};

/// Zero-allocation tracer interface using function pointers
pub const TracerVTable = struct {
    on_pre_step: *const fn (ptr: *anyopaque, step_info: StepInfo) void,
    on_post_step: *const fn (ptr: *anyopaque, step_result: StepResult) void,  
    on_finish: *const fn (ptr: *anyopaque, return_value: []const u8, success: bool) void,
};

/// Type-erased tracer handle
pub const TracerHandle = struct {
    ptr: *anyopaque,
    vtable: *const TracerVTable,
    
    pub fn on_pre_step(self: TracerHandle, step_info: StepInfo) void {
        self.vtable.on_pre_step(self.ptr, step_info);
    }
    
    pub fn on_post_step(self: TracerHandle, step_result: StepResult) void {
        self.vtable.on_post_step(self.ptr, step_result);
    }
    
    pub fn on_finish(self: TracerHandle, return_value: []const u8, success: bool) void {
        self.vtable.on_finish(self.ptr, return_value, success);
    }
};
```

**Key Zig Patterns Used:**
- **Struct naming**: `PascalCase` for types, `snake_case` for fields/functions
- **Optional pointers**: `?[]u256` for bounded data that might be null
- **VTable pattern**: Function pointers for zero-cost abstractions
- **Error unions**: Consistent with existing codebase error handling
- **Memory management**: Explicit `deinit()` methods for cleanup

#### Step 2: Standard Tracer Implementation (`src/evm/tracing/standard_tracer.zig`)

**Core tracer struct with proper Zig memory management:**

```zig
const std = @import("std");
const tracer = @import("tracer.zig");
const capture_utils = @import("capture_utils.zig");
const Allocator = std.mem.Allocator;

/// In-memory tracer that collects execution traces with bounded snapshots
pub const StandardTracer = struct {
    // Memory management
    allocator: Allocator,
    config: tracer.TracerConfig,
    
    // Execution state tracking
    struct_logs: std.ArrayList(tracer.StructLog),
    gas_used: u64,
    failed: bool,
    return_value: std.ArrayList(u8),
    
    // Per-step tracking for delta calculation
    last_journal_size: usize,
    last_log_count: usize,
    
    // VTable for type erasure
    const VTABLE = tracer.TracerVTable{
        .on_pre_step = on_pre_step_impl,
        .on_post_step = on_post_step_impl,
        .on_finish = on_finish_impl,
    };

    /// Initialize tracer with allocator and config
    pub fn init(allocator: Allocator, config: tracer.TracerConfig) !StandardTracer {
        return StandardTracer{
            .allocator = allocator,
            .config = config,
            // MEMORY ALLOCATION: ArrayList for struct logs
            // Expected growth: ~1KB per 100 instructions
            // Lifetime: Until get_trace() or deinit()
            .struct_logs = std.ArrayList(tracer.StructLog).init(allocator),
            .gas_used = 0,
            .failed = false,
            .return_value = std.ArrayList(u8).init(allocator),
            .last_journal_size = 0,
            .last_log_count = 0,
        };
    }

    /// Clean up all allocations
    pub fn deinit(self: *StandardTracer) void {
        // Free struct logs and all nested allocations
        for (self.struct_logs.items) |*log| {
            self.free_struct_log(log);
        }
        self.struct_logs.deinit();
        self.return_value.deinit();
    }

    /// Get type-erased tracer handle for EVM integration
    pub fn handle(self: *StandardTracer) tracer.TracerHandle {
        return tracer.TracerHandle{
            .ptr = @ptrCast(self),
            .vtable = &VTABLE,
        };
    }

    /// Extract final execution trace (transfers ownership)
    pub fn get_trace(self: *StandardTracer) !tracer.ExecutionTrace {
        // Transfer ownership of struct_logs to trace
        const logs_slice = try self.struct_logs.toOwnedSlice();
        const return_slice = try self.return_value.toOwnedSlice();
        
        return tracer.ExecutionTrace{
            .gas_used = self.gas_used,
            .failed = self.failed,
            .return_value = return_slice,
            .struct_logs = logs_slice,
        };
    }

    // VTable implementations
    fn on_pre_step_impl(ptr: *anyopaque, step_info: tracer.StepInfo) void {
        const self: *StandardTracer = @ptrCast(@alignCast(ptr));
        self.on_pre_step(step_info);
    }

    fn on_post_step_impl(ptr: *anyopaque, step_result: tracer.StepResult) void {
        const self: *StandardTracer = @ptrCast(@alignCast(ptr));
        self.on_post_step(step_result);
    }

    fn on_finish_impl(ptr: *anyopaque, return_value: []const u8, success: bool) void {
        const self: *StandardTracer = @ptrCast(@alignCast(ptr));
        self.on_finish(return_value, success);
    }

    // Implementation methods
    fn on_pre_step(self: *StandardTracer, step_info: tracer.StepInfo) void {
        // Store step info for later combination with post_step results
        // We'll build the StructLog in on_post_step when we have complete data
    }

    fn on_post_step(self: *StandardTracer, step_result: tracer.StepResult) void {
        // Build complete StructLog entry combining pre/post step data
        const struct_log = tracer.StructLog{
            .pc = step_result.pc,  // Will be passed from step_info stored earlier
            .op = step_result.op_name,
            .gas = step_result.gas_before,
            .gas_cost = step_result.gas_cost,
            .depth = step_result.depth,
            .stack = step_result.stack_snapshot,
            .memory = step_result.memory_snapshot,
            .storage = step_result.storage_changes,
            .logs = step_result.logs_emitted,
            .error_info = step_result.error_info,
        };
        
        self.struct_logs.append(struct_log) catch |err| {
            // Handle allocation failure gracefully
            std.debug.print("StandardTracer: Failed to append struct log: {}\n", .{err});
        };
    }

    fn on_finish(self: *StandardTracer, return_value: []const u8, success: bool) void {
        self.failed = !success;
        // Copy return value
        self.return_value.appendSlice(return_value) catch |err| {
            std.debug.print("StandardTracer: Failed to store return value: {}\n", .{err});
        };
    }

    /// Helper to free individual struct log allocations  
    fn free_struct_log(self: *StandardTracer, log: *tracer.StructLog) void {
        if (log.stack) |stack| self.allocator.free(stack);
        if (log.memory) |memory| self.allocator.free(memory);
        self.allocator.free(log.storage);
        self.allocator.free(log.logs);
    }
};
```

#### Step 3: Capture Utilities (`src/evm/tracing/capture_utils.zig`)

**Bounded capture functions with proper error handling:**

```zig
const std = @import("std");
const tracer = @import("tracer.zig");
const Frame = @import("../frame.zig").Frame;
const Memory = @import("../memory/memory.zig").Memory;
const CallJournal = @import("../call_frame_stack.zig").CallJournal;
const EvmState = @import("../state/state.zig").EvmState;
const Allocator = std.mem.Allocator;

/// Copy stack data with bounds checking
pub fn copy_stack_bounded(
    allocator: Allocator,
    stack_data: []const u256,
    max_items: usize,
) !?[]u256 {
    if (stack_data.len == 0) return null;
    
    const copy_count = @min(stack_data.len, max_items);
    if (copy_count == 0) return null;
    
    // MEMORY ALLOCATION: Stack snapshot
    // Size: copy_count * 32 bytes
    // Lifetime: Until StructLog is freed
    const stack_copy = try allocator.alloc(u256, copy_count);
    @memcpy(stack_copy, stack_data[0..copy_count]);
    
    return stack_copy;
}

/// Copy memory with optional windowing around accessed region
pub fn copy_memory_bounded(
    allocator: Allocator,
    memory: *const Memory,
    max_bytes: usize,
    accessed_region: ?struct { start: usize, len: usize },
) !?[]u8 {
    const memory_size = memory.size();
    if (memory_size == 0) return null;
    
    const copy_size = @min(memory_size, max_bytes);
    if (copy_size == 0) return null;
    
    // MEMORY ALLOCATION: Memory snapshot  
    // Size: copy_size bytes
    // Lifetime: Until StructLog is freed
    const memory_copy = try allocator.alloc(u8, copy_size);
    
    if (accessed_region) |region| {
        // Create window around accessed region
        const window_start = if (region.start >= max_bytes / 2) 
            region.start - max_bytes / 2 
        else 
            0;
        const window_end = @min(memory_size, window_start + max_bytes);
        
        const memory_ptr = memory.get_memory_ptr();
        const checkpoint = memory.get_checkpoint();
        const source_slice = memory_ptr[checkpoint + window_start..checkpoint + window_end];
        
        @memcpy(memory_copy, source_slice);
    } else {
        // Copy from beginning
        const memory_ptr = memory.get_memory_ptr();
        const checkpoint = memory.get_checkpoint();
        const source_slice = memory_ptr[checkpoint..checkpoint + copy_size];
        
        @memcpy(memory_copy, source_slice);
    }
    
    return memory_copy;
}

/// Collect storage changes since given journal index
pub fn collect_storage_changes_since(
    allocator: Allocator,
    journal: *const CallJournal,
    from_index: usize,
) ![]tracer.StorageChange {
    const entries = journal.entries.items;
    if (from_index >= entries.len) {
        return try allocator.alloc(tracer.StorageChange, 0);
    }
    
    // Count storage changes
    var change_count: usize = 0;
    for (entries[from_index..]) |entry| {
        if (entry == .storage_change) change_count += 1;
    }
    
    if (change_count == 0) {
        return try allocator.alloc(tracer.StorageChange, 0);
    }
    
    // MEMORY ALLOCATION: Storage changes array
    // Size: change_count * ~80 bytes per entry  
    // Lifetime: Until StructLog is freed
    const changes = try allocator.alloc(tracer.StorageChange, change_count);
    
    var i: usize = 0;
    for (entries[from_index..]) |entry| {
        switch (entry) {
            .storage_change => |sc| {
                changes[i] = tracer.StorageChange{
                    .address = sc.address,
                    .key = sc.key,
                    .value = sc.original_value,  // Will be updated to current value
                    .original_value = sc.original_value,
                };
                i += 1;
            },
            else => continue,
        }
    }
    
    return changes;
}

/// Copy recent log entries with bounded data
pub fn copy_logs_bounded(
    allocator: Allocator,
    evm_state: *const EvmState,
    from_index: usize,
    log_data_max_bytes: usize,
) ![]tracer.LogEntry {
    const logs = evm_state.logs.items;
    if (from_index >= logs.len) {
        return try allocator.alloc(tracer.LogEntry, 0);
    }
    
    const new_logs = logs[from_index..];
    if (new_logs.len == 0) {
        return try allocator.alloc(tracer.LogEntry, 0);
    }
    
    // MEMORY ALLOCATION: Log entries array
    // Size: new_logs.len * ~200 bytes per entry (varies by data size)
    // Lifetime: Until StructLog is freed
    const log_entries = try allocator.alloc(tracer.LogEntry, new_logs.len);
    
    for (new_logs, 0..) |log, i| {
        const data_size = @min(log.data.len, log_data_max_bytes);
        
        // Copy topic data (always include all topics)
        const topics_copy = try allocator.dupe(u256, log.topics);
        
        // Copy bounded log data
        const data_copy = try allocator.alloc(u8, data_size);
        @memcpy(data_copy, log.data[0..data_size]);
        
        log_entries[i] = tracer.LogEntry{
            .address = log.address,
            .topics = topics_copy,
            .data = data_copy,
            .data_truncated = log.data.len > log_data_max_bytes,
        };
    }
    
    return log_entries;
}
```

#### Step 4: EVM Integration Points

**Add to `src/evm/evm.zig`:**
```zig
pub const Evm = struct {
    // ... existing fields ...
    
    /// Optional in-process tracer for structured data collection
    inproc_tracer: ?tracer.TracerHandle = null,
    
    /// Set structured tracer (replaces any existing tracer)
    pub fn set_tracer(self: *Evm, tracer_handle: ?tracer.TracerHandle) void {
        self.inproc_tracer = tracer_handle;
    }
};
```

**Enhance `pre_step` in `src/evm/evm/interpret.zig`:**
```zig
inline fn pre_step(self: *Evm, frame: *Frame, inst: *const Instruction, loop_iterations: *usize) void {
    // ... existing safety checks ...
    
    if (comptime build_options.enable_tracing) {
        // Handle existing JSON tracer
        if (self.tracer) |writer| {
            // ... existing JSON tracing logic ...
        }
        
        // NEW: Handle structured tracer
        if (self.inproc_tracer) |tracer_handle| {
            const analysis = frame.analysis;
            const base: [*]const @TypeOf(inst.*) = analysis.instructions.ptr;
            const idx = (@intFromPtr(inst) - @intFromPtr(base)) / @sizeOf(@TypeOf(inst.*));
            
            if (idx < analysis.inst_to_pc.len) {
                const pc_u16 = analysis.inst_to_pc[idx];
                if (pc_u16 != std.math.maxInt(u16)) {
                    const pc: usize = pc_u16;
                    const opcode: u8 = if (pc < analysis.code_len) frame.analysis.code[pc] else 0x00;
                    
                    // Build StepInfo
                    const step_info = tracer.StepInfo{
                        .pc = pc,
                        .opcode = opcode,
                        .op_name = get_opcode_name(opcode),
                        .gas_before = frame.gas_remaining,
                        .depth = frame.depth,
                        .address = frame.contract_address,
                        .caller = frame.caller,
                        .is_static = frame.is_static,
                        .stack_size = frame.stack.size(),
                        .memory_size = frame.memory.size(),
                    };
                    
                    tracer_handle.on_pre_step(step_info);
                }
            }
        }
    }
}
```

**Add post-step hook after instruction execution:**
```zig
// After each exec_fn(frame) call, add:
if (comptime build_options.enable_tracing) {
    if (self.inproc_tracer) |tracer_handle| {
        // Compute gas cost and build StepResult
        const gas_after = frame.gas_remaining;
        const gas_cost = gas_before - gas_after;  // Store gas_before in pre_step
        
        // ... capture bounded snapshots using capture_utils functions ...
        
        const step_result = tracer.StepResult{
            .gas_after = gas_after,
            .gas_cost = gas_cost,
            .stack_snapshot = stack_snapshot,
            .memory_snapshot = memory_snapshot,
            .storage_changes = storage_changes,
            .logs_emitted = log_entries,
            .error_info = null,  // Set if error occurred
        };
        
        tracer_handle.on_post_step(step_result);
    }
}
```

### Comprehensive Test Implementation

**Following Guillotine's zero-abstraction test philosophy:**

```zig
// In test/evm/tracer_comprehensive_test.zig
const std = @import("std");
const CodeAnalysis = @import("evm").analysis.CodeAnalysis;
const MemoryDatabase = @import("evm").state.MemoryDatabase;
const Evm = @import("evm").Evm;
const Frame = @import("evm").Frame;
const Host = @import("evm").Host;
const Address = @import("primitives").Address.Address;
const StandardTracer = @import("evm").tracing.StandardTracer;
const TracerConfig = @import("evm").tracing.TracerConfig;
const interpret = @import("evm").interpret;
const ExecutionError = @import("evm").ExecutionError;
const Log = @import("evm").Log;

test "StandardTracer: arithmetic sequence captures stack and gas changes" {
    const allocator = std.testing.allocator;
    
    // PUSH 2, PUSH 3, ADD, POP, STOP
    const bytecode = [_]u8{ 0x60, 0x02, 0x60, 0x03, 0x01, 0x50, 0x00 };
    
    // 1. Setup EVM infrastructure (no abstractions)
    var analysis = try CodeAnalysis.init(allocator, &bytecode);
    defer analysis.deinit(allocator);
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();
    
    var evm = try Evm.init(allocator, db_interface, null, null);
    defer evm.deinit();
    
    const host = Host.init(&evm);
    var frame = try Frame.init(
        1000000,        // gas_remaining
        false,          // is_static
        0,              // depth
        Address.ZERO,   // contract_address
        Address.ZERO,   // caller
        0,              // value
        &analysis,
        host,
        db_interface,
        allocator,
    );
    defer frame.deinit(allocator);
    
    // 2. Setup tracer with bounded config
    const tracer_config = TracerConfig{
        .memory_max_bytes = 256,
        .stack_max_items = 16, 
        .log_data_max_bytes = 256,
    };
    var standard_tracer = try StandardTracer.init(allocator, tracer_config);
    defer standard_tracer.deinit();
    
    // 3. Install tracer on EVM
    evm.set_tracer(standard_tracer.handle());
    
    // 4. Execute bytecode
    const execution_result = interpret(&evm, &frame);
    try std.testing.expect(execution_result == ExecutionError.Error.STOP or execution_result == {});
    
    // 5. Extract and verify trace (no helper functions)
    var execution_trace = try standard_tracer.get_trace();
    defer execution_trace.deinit(allocator);
    
    // Verify basic execution properties
    try std.testing.expect(!execution_trace.failed);
    try std.testing.expect(execution_trace.gas_used > 0);
    try std.testing.expect(execution_trace.struct_logs.len >= 5); // PUSH2 + PUSH2 + ADD + POP + STOP
    
    // Verify individual steps (explicit expectations)
    const logs = execution_trace.struct_logs;
    
    // First step: PUSH 2
    try std.testing.expectEqual(@as(usize, 0), logs[0].pc);
    try std.testing.expectEqualSlices(u8, "PUSH1", logs[0].op);
    try std.testing.expectEqual(@as(u16, 0), logs[0].depth);
    try std.testing.expect(logs[0].stack != null);
    try std.testing.expectEqual(@as(usize, 1), logs[0].stack.?.len); // After PUSH, stack has 1 item
    try std.testing.expectEqual(@as(u256, 2), logs[0].stack.?[0]);
    
    // Third step: ADD
    const add_step = logs[2];
    try std.testing.expectEqual(@as(usize, 4), add_step.pc);
    try std.testing.expectEqualSlices(u8, "ADD", add_step.op);
    try std.testing.expect(add_step.stack != null);
    try std.testing.expectEqual(@as(usize, 1), add_step.stack.?.len); // After ADD, stack has 1 item
    try std.testing.expectEqual(@as(u256, 5), add_step.stack.?[0]); // 2 + 3 = 5
    
    // Verify gas accounting
    var total_gas_cost: u64 = 0;
    for (logs) |log| {
        total_gas_cost += log.gas_cost;
    }
    try std.testing.expectEqual(execution_trace.gas_used, total_gas_cost);
}

test "StandardTracer: memory operations capture bounded memory snapshots" {
    const allocator = std.testing.allocator;
    
    // PUSH 32 bytes of data, MSTORE, MLOAD sequence  
    const bytecode = [_]u8{
        0x7f, 0x48, 0x65, 0x6c, 0x6c, 0x6f, 0x2c, 0x20, 0x57, 0x6f, 0x72, 0x6c, 0x64, 0x21, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, // PUSH32 "Hello, World!" + padding
        0x60, 0x00, // PUSH 0 (memory offset)  
        0x52,       // MSTORE
        0x60, 0x00, // PUSH 0 (memory offset)
        0x51,       // MLOAD
        0x00,       // STOP
    };
    
    // Full setup (no abstractions)
    var analysis = try CodeAnalysis.init(allocator, &bytecode);
    defer analysis.deinit(allocator);
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();
    
    var evm = try Evm.init(allocator, db_interface, null, null);
    defer evm.deinit();
    
    const host = Host.init(&evm);
    var frame = try Frame.init(1000000, false, 0, Address.ZERO, Address.ZERO, 0, &analysis, host, db_interface, allocator);
    defer frame.deinit(allocator);
    
    // Small memory bounds to test bounded capture
    const tracer_config = TracerConfig{
        .memory_max_bytes = 64,  // Small limit to test windowing
        .stack_max_items = 16,
        .log_data_max_bytes = 256,
    };
    var standard_tracer = try StandardTracer.init(allocator, tracer_config);
    defer standard_tracer.deinit();
    
    evm.set_tracer(standard_tracer.handle());
    
    // Execute
    const execution_result = interpret(&evm, &frame);
    try std.testing.expect(execution_result == ExecutionError.Error.STOP or execution_result == {});
    
    // Verify memory captures
    var execution_trace = try standard_tracer.get_trace();
    defer execution_trace.deinit(allocator);
    
    try std.testing.expect(!execution_trace.failed);
    
    // Find MSTORE step
    var mstore_step: ?@import("evm").tracing.StructLog = null;
    for (execution_trace.struct_logs) |log| {
        if (std.mem.eql(u8, log.op, "MSTORE")) {
            mstore_step = log;
            break;
        }
    }
    
    try std.testing.expect(mstore_step != null);
    const mstore = mstore_step.?;
    
    // Verify memory was captured and contains expected data
    try std.testing.expect(mstore.memory != null);
    try std.testing.expect(mstore.memory.?.len <= tracer_config.memory_max_bytes);
    
    // Check that "Hello" is in the captured memory
    const memory_data = mstore.memory.?;
    const hello_bytes = "Hello";
    var found_hello = false;
    for (0..memory_data.len - hello_bytes.len) |i| {
        if (std.mem.eql(u8, memory_data[i..i + hello_bytes.len], hello_bytes)) {
            found_hello = true;
            break;
        }
    }
    try std.testing.expect(found_hello);
}

test "StandardTracer: bounded capture respects limits and handles oversized data" {
    const allocator = std.testing.allocator;
    
    // Very restrictive bounds to test boundary conditions
    const tracer_config = TracerConfig{
        .memory_max_bytes = 16,   // Very small
        .stack_max_items = 2,     // Very small  
        .log_data_max_bytes = 8,  // Very small
    };
    var standard_tracer = try StandardTracer.init(allocator, tracer_config);
    defer standard_tracer.deinit();
    
    // Create large stack by pushing many items
    const bytecode = [_]u8{
        0x60, 0x01, // PUSH 1
        0x60, 0x02, // PUSH 2  
        0x60, 0x03, // PUSH 3
        0x60, 0x04, // PUSH 4 (exceed stack limit)
        0x00,       // STOP
    };
    
    // Full setup
    var analysis = try CodeAnalysis.init(allocator, &bytecode);
    defer analysis.deinit(allocator);
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();
    
    var evm = try Evm.init(allocator, db_interface, null, null);
    defer evm.deinit();
    
    const host = Host.init(&evm);
    var frame = try Frame.init(1000000, false, 0, Address.ZERO, Address.ZERO, 0, &analysis, host, db_interface, allocator);
    defer frame.deinit(allocator);
    
    evm.set_tracer(standard_tracer.handle());
    
    const execution_result = interpret(&evm, &frame);
    try std.testing.expect(execution_result == ExecutionError.Error.STOP or execution_result == {});
    
    var execution_trace = try standard_tracer.get_trace();
    defer execution_trace.deinit(allocator);
    
    // Find step with maximum stack items
    var max_stack_size: usize = 0;
    for (execution_trace.struct_logs) |log| {
        if (log.stack) |stack| {
            max_stack_size = @max(max_stack_size, stack.len);
        }
    }
    
    // Verify stack was bounded
    try std.testing.expect(max_stack_size <= tracer_config.stack_max_items);
    
    // At least some steps should have been captured
    try std.testing.expect(execution_trace.struct_logs.len > 0);
}

test "StandardTracer: zero overhead when no tracer set" {
    const allocator = std.testing.allocator;
    
    const bytecode = [_]u8{ 0x60, 0x01, 0x60, 0x02, 0x01, 0x00 }; // Simple ADD
    
    var analysis = try CodeAnalysis.init(allocator, &bytecode);
    defer analysis.deinit(allocator);
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();
    
    var evm = try Evm.init(allocator, db_interface, null, null);
    defer evm.deinit();
    
    const host = Host.init(&evm);
    var frame = try Frame.init(1000000, false, 0, Address.ZERO, Address.ZERO, 0, &analysis, host, db_interface, allocator);
    defer frame.deinit(allocator);
    
    // No tracer set - should have zero impact
    try std.testing.expect(evm.inproc_tracer == null);
    
    const start_time = std.time.microTimestamp();
    const execution_result = interpret(&evm, &frame);
    const end_time = std.time.microTimestamp();
    
    try std.testing.expect(execution_result == ExecutionError.Error.STOP or execution_result == {});
    
    // Basic smoke test - execution completes quickly without tracer overhead
    try std.testing.expect(end_time - start_time < 10_000); // Less than 10ms
}
```

### Critical Zig Implementation Notes

**Memory Management Patterns:**
```zig
// ALWAYS use defer immediately after allocation
const data = try allocator.alloc(u8, size);
defer allocator.free(data);

// For ArrayList transfers of ownership
const owned_slice = try list.toOwnedSlice();
// Caller now owns the slice, must free it

// For complex nested structures
pub fn deinit(self: *ExecutionTrace, allocator: Allocator) void {
    for (self.struct_logs) |*log| {
        if (log.stack) |stack| allocator.free(stack);
        if (log.memory) |memory| allocator.free(memory);
        allocator.free(log.storage);
        allocator.free(log.logs);
    }
    allocator.free(self.struct_logs);
    allocator.free(self.return_value);
}
```

**Error Handling:**
```zig
// Use error unions consistently
pub fn copy_stack_bounded(...) !?[]u256 {
    // Functions can fail (!) and return optional (?)
}

// Error propagation
try some_function(); // Propagates error up
some_function() catch |err| {
    // Handle specific error
    return err; // Or handle gracefully
};
```

**Comptime Optimizations:**
```zig
// Use comptime for zero-cost abstractions
if (comptime build_options.enable_tracing) {
    // This entire block compiled out if tracing disabled
}
```

**Import Patterns:**
```zig
// Module imports follow build.zig structure
const evm = @import("evm");           // References EVM module
const primitives = @import("primitives"); // References primitives module

// Local imports in same directory
const tracer = @import("tracer.zig");
const capture_utils = @import("capture_utils.zig");
```
```

### Module System Integration

**Add to `src/evm/root.zig`:**
```zig
// Export new tracing types
pub const tracing = struct {
    pub const TracerConfig = @import("tracing/tracer.zig").TracerConfig;
    pub const TracerHandle = @import("tracing/tracer.zig").TracerHandle;
    pub const StandardTracer = @import("tracing/standard_tracer.zig").StandardTracer;
    pub const ExecutionTrace = @import("tracing/tracer.zig").ExecutionTrace;
    pub const StructLog = @import("tracing/tracer.zig").StructLog;
};
```

**Update `build.zig` to include new files in evm module (no changes needed - files are automatically included).**

### Essential Debugging and Development Notes

**Compile-Time Tracing Control:**
- Set `enable_tracing = true` in build options for development  
- Tracing is compile-time controlled for zero overhead in release
- Use `zig build -Denable_tracing=true` to enable tracing in builds

**Memory Debugging:**
```zig
// In debug mode, check for leaks
test "StandardTracer: no memory leaks" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok); // Will panic if leaks detected
    const allocator = gpa.allocator();
    
    var tracer = try StandardTracer.init(allocator, .{});
    defer tracer.deinit();
    
    // ... use tracer ...
    
    var trace = try tracer.get_trace();
    defer trace.deinit(allocator);
}
```

**Performance Considerations:**
- Tracing has significant overhead - only enable for debugging
- Bounded capture prevents excessive memory usage  
- VTable dispatch adds minimal overhead vs direct calls
- Consider streaming/incremental capture for long executions

**Integration with Existing JSON Tracer:**
- Both JSON and structured tracers can run simultaneously
- JSON tracer writes to `std.io.AnyWriter`  
- Structured tracer collects in-memory for programmatic access
- Choose based on use case (file output vs UI integration)

### Common Pitfalls and Solutions

**Memory Management:**
- ❌ Forgetting `defer deinit()` after `init()`
- ❌ Not calling `trace.deinit(allocator)` after `get_trace()`
- ❌ Using allocations without proper error handling
- ✅ Always use `defer` immediately after successful allocation
- ✅ Handle allocation failures gracefully in tracer code

**Bounded Capture:**
- ❌ Copying entire memory/stack without bounds checking
- ❌ Unbounded log data causing memory bloat
- ✅ Respect configuration limits strictly
- ✅ Provide truncation indicators when data is bounded

**Error Handling:**
- ❌ Propagating tracer errors to execution (breaks EVM)
- ❌ Ignoring allocation failures silently
- ✅ Catch and log tracer errors, continue execution
- ✅ Graceful degradation when memory is exhausted

**Hook Integration:**
- ❌ Modifying Frame state in tracer hooks
- ❌ Blocking execution waiting for tracer operations
- ✅ Read-only access to Frame state in hooks
- ✅ Asynchronous/non-blocking tracer operations

### Build/Run Commands

**Development with tracing enabled:**
```bash
# Build with tracing support
zig build -Denable_tracing=true

# Run tests with tracing
zig build test -Denable_tracing=true

# Always verify build and tests pass
zig build && zig build test
```

**Performance verification:**
```bash
# Build release without tracing (zero overhead)
zig build -Doptimize=ReleaseFast -Denable_tracing=false

# Benchmark to ensure no overhead when disabled
zig build bench -Doptimize=ReleaseFast -Denable_tracing=false
```

**Key files to create/modify:**
- ✅ `src/evm/tracing/tracer.zig` (new)
- ✅ `src/evm/tracing/standard_tracer.zig` (new) 
- ✅ `src/evm/tracing/capture_utils.zig` (new)
- ✅ `src/evm/evm.zig` (add `inproc_tracer` field and `set_tracer()`)
- ✅ `src/evm/evm/interpret.zig` (enhance `pre_step()`, add post-step hooks)
- ✅ `src/evm/root.zig` (export tracing types)
- ✅ `test/evm/tracer_comprehensive_test.zig` (new test file)

This comprehensive implementation guide provides everything needed to build a production-quality structured tracer for Guillotine's devtool, following proper Zig conventions and the existing codebase patterns.
