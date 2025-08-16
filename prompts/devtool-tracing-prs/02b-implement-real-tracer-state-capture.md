# 02b-implement-real-tracer-state-capture.md

## Overview: Real Tracer State Capture Implementation

This document provides comprehensive implementation details for replacing fake tracer data with real EVM state capture in `interpret.zig`. Currently, the tracer captures fake/empty data for stack changes, memory changes, storage changes, and log entries.

## Missing Features Analysis

Based on analysis of `src/evm/evm/interpret.zig` lines 138-180, the following features are using fake/placeholder data:

### 1. Stack Changes (Real-time Stack Tracking)
**Current State**: Lines 156-160 create empty stack changes
```zig
const stack_changes = tracer.createEmptyStackChanges(allocator) catch tracer.StackChanges{
    .items_pushed = @constCast(&[_]u256{}),
    .items_popped = @constCast(&[_]u256{}),
    .current_stack = @constCast(&[_]u256{}),
};
```

### 2. Memory Changes (Delta Memory Tracking) 
**Current State**: Lines 161-165 create empty memory changes
```zig
const memory_changes = tracer.createEmptyMemoryChanges(allocator) catch tracer.MemoryChanges{
    .offset = 0,
    .data = @constCast(&[_]u8{}),
    .current_memory = @constCast(&[_]u8{}),
};
```

### 3. Storage Changes (Journal-based Storage Tracking)
**Current State**: Line 150 creates empty storage changes
```zig
const storage_changes = capture_utils.create_empty_storage_changes(allocator) catch @constCast(&[_]tracer.StorageChange{});
```

### 4. Log Entries (EVM Event Log Capture)
**Current State**: Line 153 creates empty log entries
```zig
const logs_emitted = capture_utils.create_empty_log_entries(allocator) catch @constCast(&[_]tracer.LogEntry{});
```

### 5. Memory Snapshot (Windowed Memory Capture)
**Current State**: Line 147 uses basic bounded copy without access region info
```zig
const memory_snapshot = capture_utils.copy_memory_bounded(allocator, &frame.memory, 1024, null) catch null;
```

## Implementation Plan

## Feature 1: Real Stack Changes Tracking

### Problem
Stack changes are not tracked during opcode execution. We need to capture what was pushed and popped for each instruction.

### Solution
Implement pre/post stack state comparison to detect changes.

### Files to Modify
- `src/evm/evm/interpret.zig` (main implementation)
- `src/evm/tracing/capture_utils.zig` (helper functions)

### Implementation Details

#### A. Add Stack State Capture in `capture_utils.zig`

Add new function to capture real stack changes:

```zig
/// Capture actual stack changes between pre and post execution states
/// Returns StackChanges with real pushed/popped items and current stack state
/// Caller owns returned memory and must call deinit()
pub fn capture_stack_changes(
    allocator: Allocator,
    stack_before: []const u256,
    stack_after: []const u256,
    max_items: usize,
) !tracer.StackChanges {
    // Calculate what was pushed and popped
    var items_pushed: []u256 = undefined;
    var items_popped: []u256 = undefined;
    
    if (stack_after.len > stack_before.len) {
        // Items were pushed
        const push_count = stack_after.len - stack_before.len;
        items_pushed = try allocator.alloc(u256, push_count);
        errdefer allocator.free(items_pushed);
        
        // Copy the newly pushed items (they're at the end of stack_after)
        @memcpy(items_pushed, stack_after[stack_before.len..]);
        
        items_popped = try allocator.alloc(u256, 0);
    } else if (stack_before.len > stack_after.len) {
        // Items were popped
        const pop_count = stack_before.len - stack_after.len;
        items_popped = try allocator.alloc(u256, pop_count);
        errdefer allocator.free(items_popped);
        
        // Copy the popped items (they were at the end of stack_before)
        @memcpy(items_popped, stack_before[stack_after.len..]);
        
        items_pushed = try allocator.alloc(u256, 0);
    } else {
        // No change in stack size, but items might have changed (rare case)
        items_pushed = try allocator.alloc(u256, 0);
        items_popped = try allocator.alloc(u256, 0);
    }
    errdefer allocator.free(items_pushed);
    errdefer allocator.free(items_popped);
    
    // Copy current stack state (bounded)
    const copy_count = @min(stack_after.len, max_items);
    const current_stack = try allocator.alloc(u256, copy_count);
    errdefer allocator.free(current_stack);
    
    if (copy_count > 0) {
        @memcpy(current_stack, stack_after[0..copy_count]);
    }
    
    return tracer.StackChanges{
        .items_pushed = items_pushed,
        .items_popped = items_popped,
        .current_stack = current_stack,
    };
}
```

#### B. Modify `interpret.zig` to Use Real Stack Changes

Replace lines 156-160 in the `post_step` function:

```zig
// OLD CODE (remove):
const stack_changes = tracer.createEmptyStackChanges(allocator) catch tracer.StackChanges{
    .items_pushed = @constCast(&[_]u256{}),
    .items_popped = @constCast(&[_]u256{}), 
    .current_stack = @constCast(&[_]u256{}),
};

// NEW CODE:
// Capture stack before state (add this to pre_step or track separately)
const stack_before_len = frame.stack.size();
const stack_before_data: []const u256 = if (stack_before_len > 0) 
    frame.stack.data[0..stack_before_len] 
else 
    &.{};

// In post_step, capture stack after state
const stack_after_len = frame.stack.size(); 
const stack_after_data: []const u256 = if (stack_after_len > 0)
    frame.stack.data[0..stack_after_len]
else
    &.{};

// Capture real stack changes
const stack_changes = capture_utils.capture_stack_changes(
    allocator, 
    stack_before_data, 
    stack_after_data, 
    32 // max items to capture
) catch tracer.createEmptyStackChanges(allocator) catch tracer.StackChanges{
    .items_pushed = @constCast(&[_]u256{}),
    .items_popped = @constCast(&[_]u256{}), 
    .current_stack = @constCast(&[_]u256{}),
};
```

### Implementation Notes

1. **Stack Access Pattern**: The EVM stack in `src/evm/stack/stack.zig` stores data in `data: *[CAPACITY]u256` with current pointer tracking size.

2. **Memory Management**: All allocated slices must be freed by calling `deinit()` on the StackChanges struct.

3. **Bounded Capture**: Limit stack items captured to prevent excessive memory usage (recommend 32 items max).

---

## Feature 2: Real Memory Changes Tracking

### Problem
Memory changes are not tracked during opcode execution. We need to detect which memory regions were modified and capture the changes.

### Solution
Implement memory delta tracking by comparing memory state before and after execution.

### Implementation Details

#### A. Add Memory Change Detection in `capture_utils.zig`

```zig
/// Capture actual memory changes between pre and post execution states
/// Detects modified regions and captures the changes
/// Returns MemoryChanges with real modification data
/// Caller owns returned memory and must call deinit()
pub fn capture_memory_changes(
    allocator: Allocator,
    memory_before: []const u8,
    memory_after: []const u8,
    max_bytes: usize,
) !tracer.MemoryChanges {
    // Find the modified region
    const min_len = @min(memory_before.len, memory_after.len);
    const max_len = @max(memory_before.len, memory_after.len);
    
    var first_diff_offset: ?usize = null;
    var last_diff_offset: usize = 0;
    
    // Find first difference
    for (0..min_len) |i| {
        if (memory_before[i] != memory_after[i]) {
            if (first_diff_offset == null) {
                first_diff_offset = i;
            }
            last_diff_offset = i;
        }
    }
    
    // Check if memory was extended
    if (memory_after.len > memory_before.len) {
        if (first_diff_offset == null) {
            first_diff_offset = memory_before.len;
        }
        last_diff_offset = memory_after.len - 1;
    }
    
    // If no differences found, return empty changes
    if (first_diff_offset == null) {
        return tracer.MemoryChanges{
            .offset = 0,
            .data = try allocator.alloc(u8, 0),
            .current_memory = try allocator.alloc(u8, 0),
        };
    }
    
    const diff_offset = first_diff_offset.?;
    const diff_len = last_diff_offset - diff_offset + 1;
    
    // Capture the changed data (bounded)
    const capture_len = @min(diff_len, max_bytes);
    const changed_data = try allocator.alloc(u8, capture_len);
    errdefer allocator.free(changed_data);
    
    @memcpy(changed_data, memory_after[diff_offset..diff_offset + capture_len]);
    
    // Capture bounded current memory state
    const current_memory_len = @min(memory_after.len, max_bytes);
    const current_memory = try allocator.alloc(u8, current_memory_len);
    errdefer allocator.free(current_memory);
    
    if (current_memory_len > 0) {
        @memcpy(current_memory, memory_after[0..current_memory_len]);
    }
    
    return tracer.MemoryChanges{
        .offset = @intCast(diff_offset),
        .data = changed_data,
        .current_memory = current_memory,
    };
}
```

#### B. Add Memory State Capture Helpers

```zig
/// Create a snapshot of current memory state for comparison
/// Returns owned slice that caller must free
pub fn snapshot_memory_state(
    allocator: Allocator,
    memory: *const Memory,
) ![]u8 {
    const size = memory.context_size();
    if (size == 0) return try allocator.alloc(u8, 0);
    
    const snapshot = try allocator.alloc(u8, size);
    errdefer allocator.free(snapshot);
    
    const memory_ptr = memory.get_memory_ptr();
    const checkpoint = memory.get_checkpoint();
    const source_slice = memory_ptr[checkpoint..checkpoint + size];
    
    @memcpy(snapshot, source_slice);
    return snapshot;
}
```

#### C. Modify `interpret.zig` for Real Memory Changes

Add memory tracking to the interpreter:

```zig
// In pre_step function, add memory snapshot capture
// This requires modifying the function signature to store pre-state
inline fn pre_step(
    self: *Evm, 
    frame: *Frame, 
    inst: *const Instruction, 
    loop_iterations: *usize,
    pre_state: *PreStepState  // Add this parameter
) void {
    // ... existing code ...
    
    // Capture memory state before execution (add this)
    if (comptime build_options.enable_tracing and self.inproc_tracer != null) {
        pre_state.memory_snapshot = capture_utils.snapshot_memory_state(
            self.allocator, 
            &frame.memory
        ) catch null;
    }
}

// Define PreStepState struct (add near top of file)
const PreStepState = struct {
    memory_snapshot: ?[]u8 = null,
    
    pub fn deinit(self: *PreStepState, allocator: std.mem.Allocator) void {
        if (self.memory_snapshot) |snapshot| {
            allocator.free(snapshot);
        }
    }
};

// In post_step function, replace fake memory changes:
// OLD CODE (remove):
const memory_changes = tracer.createEmptyMemoryChanges(allocator) catch tracer.MemoryChanges{
    .offset = 0,
    .data = @constCast(&[_]u8{}),
    .current_memory = @constCast(&[_]u8{}),
};

// NEW CODE:
const memory_changes = if (pre_state.memory_snapshot) |before_snapshot| blk: {
    const after_snapshot = capture_utils.snapshot_memory_state(allocator, &frame.memory) catch break :blk tracer.createEmptyMemoryChanges(allocator) catch tracer.MemoryChanges{
        .offset = 0,
        .data = @constCast(&[_]u8{}),
        .current_memory = @constCast(&[_]u8{}),
    };
    defer allocator.free(after_snapshot);
    
    break :blk capture_utils.capture_memory_changes(
        allocator,
        before_snapshot,
        after_snapshot,
        1024 // max bytes to capture
    ) catch tracer.createEmptyMemoryChanges(allocator) catch tracer.MemoryChanges{
        .offset = 0,
        .data = @constCast(&[_]u8{}),
        .current_memory = @constCast(&[_]u8{}),
    };
} else tracer.createEmptyMemoryChanges(allocator) catch tracer.MemoryChanges{
    .offset = 0,
    .data = @constCast(&[_]u8{}),
    .current_memory = @constCast(&[_]u8{}),
};
```

---

## Feature 3: Real Storage Changes Tracking

### Problem
Storage changes are not captured from the call journal system. The EVM tracks storage changes in the journal for reverting, but these aren't exposed to the tracer.

### Solution
Hook into the `CallJournal` system in `src/evm/call_frame_stack.zig` to capture storage changes since the last step.

### Files Involved
- `src/evm/call_frame_stack.zig` - Contains `CallJournal` and `JournalEntry` definitions
- `src/evm/tracing/capture_utils.zig` - Storage change capture functions
- `src/evm/evm/interpret.zig` - Integration point

### Implementation Details

#### A. Update Storage Change Capture in `capture_utils.zig`

The existing `collect_storage_changes_since` function needs improvement:

```zig
/// Enhanced storage change collection with proper current value tracking
/// Captures storage changes from journal entries since the given index
/// Returns array of StorageChange with correct current values
pub fn collect_storage_changes_enhanced(
    allocator: Allocator,
    journal: *const CallJournal,
    from_index: usize,
    state_db: anytype, // Database interface to get current values
) ![]tracer.StorageChange {
    const entries = journal.entries.items;
    if (from_index >= entries.len) {
        return try allocator.alloc(tracer.StorageChange, 0);
    }

    // Count and collect unique storage changes since from_index
    var changes_map = std.AutoHashMap(struct { address: Address, key: u256 }, tracer.StorageChange).init(allocator);
    defer changes_map.deinit();

    for (entries[from_index..]) |entry| {
        switch (entry) {
            .storage_change => |sc| {
                const key_pair = .{ .address = sc.address, .key = sc.key };
                
                // Get current value from state database
                const current_value = state_db.get_storage(sc.address, sc.key);
                
                const change = tracer.StorageChange{
                    .address = sc.address,
                    .key = sc.key,
                    .value = current_value,
                    .original_value = sc.original_value,
                };
                
                // Overwrite if duplicate key (keep most recent change)
                try changes_map.put(key_pair, change);
            },
            else => continue,
        }
    }

    // Convert map to array
    const change_count = changes_map.count();
    const changes = try allocator.alloc(tracer.StorageChange, change_count);
    errdefer allocator.free(changes);

    var iterator = changes_map.iterator();
    var i: usize = 0;
    while (iterator.next()) |entry| {
        changes[i] = entry.value_ptr.*;
        i += 1;
    }

    return changes;
}
```

#### B. Add Journal Index Tracking in `interpret.zig`

Add journal size tracking to capture only new changes:

```zig
// Add to pre_step function signature and implementation:
inline fn pre_step(
    self: *Evm, 
    frame: *Frame, 
    inst: *const Instruction, 
    loop_iterations: *usize,
    pre_state: *PreStepState
) void {
    // ... existing code ...
    
    // Capture journal state before execution
    if (comptime build_options.enable_tracing and self.inproc_tracer != null) {
        if (frame.host.getJournal()) |journal| {
            pre_state.journal_size_before = journal.entries.items.len;
        }
    }
}

// Update PreStepState struct:
const PreStepState = struct {
    memory_snapshot: ?[]u8 = null,
    journal_size_before: usize = 0,
    
    pub fn deinit(self: *PreStepState, allocator: std.mem.Allocator) void {
        if (self.memory_snapshot) |snapshot| {
            allocator.free(snapshot);
        }
    }
};

// In post_step function, replace fake storage changes:
// OLD CODE (remove):
const storage_changes = capture_utils.create_empty_storage_changes(allocator) catch @constCast(&[_]tracer.StorageChange{});

// NEW CODE:
const storage_changes = if (frame.host.getJournal()) |journal| blk: {
    break :blk capture_utils.collect_storage_changes_enhanced(
        allocator,
        journal,
        pre_state.journal_size_before,
        frame.db // Pass database interface for current values
    ) catch try allocator.alloc(tracer.StorageChange, 0);
} else try allocator.alloc(tracer.StorageChange, 0);
```

#### C. Add Journal Access to Host Interface

The host interface may need to expose the journal. Add to `src/evm/host.zig`:

```zig
pub fn getJournal(self: *const Host) ?*const CallJournal {
    // Implementation depends on how journal is stored in Evm
    // This needs to be implemented based on the actual Evm structure
    return &self.evm.journal; // Adjust based on actual field name
}
```

---

## Feature 4: Real Log Entries Tracking

### Problem
Log entries emitted by LOG0-LOG4 opcodes are not captured. These are stored in the EVM state but not passed to the tracer.

### Solution
Track log entries from the EVM's log storage and capture new entries since the last step.

### Files Involved
- `src/evm/state/evm_log.zig` - Log entry definitions
- `src/evm/evm.zig` - Main EVM state with logs
- `src/evm/tracing/capture_utils.zig` - Log capture functions

### Implementation Details

#### A. Add Log Tracking in `interpret.zig`

```zig
// Update PreStepState to track log count:
const PreStepState = struct {
    memory_snapshot: ?[]u8 = null,
    journal_size_before: usize = 0,
    log_count_before: usize = 0,
    
    pub fn deinit(self: *PreStepState, allocator: std.mem.Allocator) void {
        if (self.memory_snapshot) |snapshot| {
            allocator.free(snapshot);
        }
    }
};

// In pre_step function:
inline fn pre_step(
    self: *Evm, 
    frame: *Frame, 
    inst: *const Instruction, 
    loop_iterations: *usize,
    pre_state: *PreStepState
) void {
    // ... existing code ...
    
    // Capture log count before execution
    if (comptime build_options.enable_tracing and self.inproc_tracer != null) {
        pre_state.log_count_before = self.getLogs().len;
    }
}

// In post_step function, replace fake log entries:
// OLD CODE (remove):
const logs_emitted = capture_utils.create_empty_log_entries(allocator) catch @constCast(&[_]tracer.LogEntry{});

// NEW CODE:
const logs_emitted = blk: {
    const current_logs = self.getLogs();
    if (current_logs.len > pre_state.log_count_before) {
        break :blk capture_utils.copy_logs_bounded(
            allocator,
            current_logs,
            pre_state.log_count_before,
            512 // max bytes per log data
        ) catch try allocator.alloc(tracer.LogEntry, 0);
    } else {
        break :blk try allocator.alloc(tracer.LogEntry, 0);
    }
};
```

#### B. Add Log Access Methods to EVM

Add to `src/evm/evm.zig` if not already present:

```zig
/// Get all logs emitted during this execution
pub fn getLogs(self: *const Evm) []const EvmLog {
    return self.logs.items; // Adjust based on actual field name/structure
}
```

---

## Feature 5: Enhanced Memory Snapshot with Access Region

### Problem
Memory snapshots don't utilize the access region information, which would provide better context around memory operations.

### Solution
Detect memory access patterns during opcode execution and provide this context to the snapshot function.

### Implementation Details

#### A. Add Memory Access Detection

For opcodes that access memory (MLOAD, MSTORE, MSIZE, etc.), capture the accessed region:

```zig
// In interpret.zig, enhance pre_step to detect memory access opcodes:
inline fn pre_step(
    self: *Evm, 
    frame: *Frame, 
    inst: *const Instruction, 
    loop_iterations: *usize,
    pre_state: *PreStepState
) void {
    // ... existing code ...
    
    // Detect memory access patterns for better snapshots
    if (comptime build_options.enable_tracing and self.inproc_tracer != null) {
        // Determine if this instruction will access memory
        const base: [*]const Instruction = frame.analysis.instructions.ptr;
        const idx = (@intFromPtr(inst) - @intFromPtr(base)) / @sizeOf(Instruction);
        
        if (idx < frame.analysis.inst_to_pc.len) {
            const pc_u16 = frame.analysis.inst_to_pc[idx];
            if (pc_u16 != std.math.maxInt(u16)) {
                const pc: usize = pc_u16;
                const opcode: u8 = if (pc < frame.analysis.code_len) frame.analysis.code[pc] else 0x00;
                
                // Predict memory access for this opcode
                pre_state.memory_access_region = predictMemoryAccess(opcode, frame);
            }
        }
    }
}

// Add memory access prediction function:
fn predictMemoryAccess(opcode: u8, frame: *Frame) ?struct { start: usize, len: usize } {
    return switch (opcode) {
        0x51 => { // MLOAD
            if (frame.stack.size() >= 1) {
                const offset = frame.stack.data[frame.stack.size() - 1];
                if (offset <= std.math.maxInt(usize)) {
                    return .{ .start = @intCast(offset), .len = 32 };
                }
            }
            return null;
        },
        0x52 => { // MSTORE
            if (frame.stack.size() >= 2) {
                const offset = frame.stack.data[frame.stack.size() - 1];
                if (offset <= std.math.maxInt(usize)) {
                    return .{ .start = @intCast(offset), .len = 32 };
                }
            }
            return null;
        },
        0x53 => { // MSTORE8
            if (frame.stack.size() >= 2) {
                const offset = frame.stack.data[frame.stack.size() - 1];
                if (offset <= std.math.maxInt(usize)) {
                    return .{ .start = @intCast(offset), .len = 1 };
                }
            }
            return null;
        },
        // Add more memory opcodes as needed
        else => null,
    };
}

// Update PreStepState:
const PreStepState = struct {
    memory_snapshot: ?[]u8 = null,
    journal_size_before: usize = 0,
    log_count_before: usize = 0,
    memory_access_region: ?struct { start: usize, len: usize } = null,
    
    pub fn deinit(self: *PreStepState, allocator: std.mem.Allocator) void {
        if (self.memory_snapshot) |snapshot| {
            allocator.free(snapshot);
        }
    }
};

// Update memory snapshot to use access region:
const memory_snapshot = capture_utils.copy_memory_bounded(
    allocator, 
    &frame.memory, 
    1024, 
    pre_state.memory_access_region
) catch null;
```

---

## Integration Steps

### Step 1: Modify Function Signatures

Update the `post_step` function to accept a `PreStepState` parameter:

```zig
inline fn post_step(
    self: *Evm, 
    frame: *Frame, 
    gas_before: u64,
    pre_state: *const PreStepState
) void {
    // Implementation with real state capture as detailed above
}
```

### Step 2: Update All Call Sites

Update all calls to `pre_step` and `post_step` throughout `interpret.zig`:

```zig
// In the main interpreter dispatch loop:
.exec => {
    @branchHint(.likely);
    
    const gas_before = frame.gas_remaining;
    var pre_state = PreStepState{};
    defer pre_state.deinit(self.allocator);
    
    pre_step(self, frame, instruction, &loop_iterations, &pre_state);
    
    // ... opcode execution ...
    
    post_step(self, frame, gas_before, &pre_state);
    
    instruction = next_instruction;
    continue :dispatch instruction.tag;
},
```

### Step 3: Add Required Imports

Add necessary imports to `interpret.zig`:

```zig
const std = @import("std");
const ExecutionError = @import("../execution/execution_error.zig");
const build_options = @import("build_options");
const tracer = @import("../tracing/trace_types.zig");
const JSONTracer = @import("../tracing/json_tracer.zig").JSONTracer;
const capture_utils = @import("../tracing/capture_utils.zig");
const opcodes = @import("../opcodes/opcode.zig");
const Frame = @import("../frame.zig").Frame;
const Log = @import("../log.zig");
const Evm = @import("../evm.zig");
const builtin = @import("builtin");
const UnreachableHandler = @import("../analysis.zig").UnreachableHandler;
const Instruction = @import("../instruction.zig").Instruction;
const Tag = @import("../instruction.zig").Tag;
const CallJournal = @import("../call_frame_stack.zig").CallJournal; // Add this
const EvmLog = @import("../state/evm_log.zig"); // Add this
const Memory = @import("../memory/memory.zig").Memory; // Add this
```

### Step 4: Error Handling

Add proper error handling for memory allocation failures:

```zig
// In post_step function, wrap all allocations with error handling:
const stack_changes = capture_utils.capture_stack_changes(
    allocator, 
    stack_before_data, 
    stack_after_data, 
    32
) catch |err| switch (err) {
    error.OutOfMemory => {
        // Log warning and use empty changes
        Log.warn("Failed to capture stack changes: out of memory");
        tracer.createEmptyStackChanges(allocator) catch tracer.StackChanges{
            .items_pushed = @constCast(&[_]u256{}),
            .items_popped = @constCast(&[_]u256{}), 
            .current_stack = @constCast(&[_]u256{}),
        }
    },
    else => return err,
};
```

---

## Testing Strategy

### Unit Tests

Add tests for each capture function in `capture_utils.zig`:

```zig
test "capture_stack_changes detects pushes" {
    const allocator = std.testing.allocator;
    
    const before = [_]u256{ 10, 20 };
    const after = [_]u256{ 10, 20, 30 };
    
    const changes = try capture_stack_changes(allocator, &before, &after, 32);
    defer changes.deinit(allocator);
    
    try std.testing.expectEqual(@as(usize, 1), changes.items_pushed.len);
    try std.testing.expectEqual(@as(u256, 30), changes.items_pushed[0]);
    try std.testing.expectEqual(@as(usize, 0), changes.items_popped.len);
}

test "capture_memory_changes detects modifications" {
    const allocator = std.testing.allocator;
    
    const before = [_]u8{ 0x00, 0x11, 0x22, 0x33 };
    const after = [_]u8{ 0x00, 0xFF, 0x22, 0x33 };
    
    const changes = try capture_memory_changes(allocator, &before, &after, 1024);
    defer changes.deinit(allocator);
    
    try std.testing.expectEqual(@as(u64, 1), changes.offset);
    try std.testing.expectEqual(@as(usize, 1), changes.data.len);
    try std.testing.expectEqual(@as(u8, 0xFF), changes.data[0]);
}
```

### Integration Tests

Add integration tests in the `interpret.zig` test section:

```zig
test "interpret: real tracer captures stack changes" {
    // Setup VM and tracer
    // Execute code that pushes/pops stack items
    // Verify tracer captured real stack changes
}

test "interpret: real tracer captures memory changes" {
    // Setup VM and tracer
    // Execute MSTORE instruction
    // Verify tracer captured memory modification
}
```

---

## Zig-Specific Implementation Notes

### Memory Management
- All allocated slices must be freed using `allocator.free()`
- Use `errdefer` for cleanup on allocation failures
- The `tracer.StackChanges` and `tracer.MemoryChanges` structs have `deinit()` methods

### Error Handling
- Functions return error unions like `![]u256`
- Use `catch` blocks to handle allocation failures gracefully
- Prefer `try` for propagating errors up the call stack

### Performance Considerations
- Use `@min()` and `@max()` for bounds checking
- Memory copying with `@memcpy()` is optimized by the compiler
- Stack allocation is preferred over heap when possible

### Compilation Guards
- Use `comptime build_options.enable_tracing` to eliminate tracing code in non-tracing builds
- Debug assertions with `std.debug.assert()` are compiled out in release builds

---

## File Dependencies Summary

### Modified Files
1. `src/evm/evm/interpret.zig` - Main integration (lines 118-183)
2. `src/evm/tracing/capture_utils.zig` - New capture functions
3. `src/evm/host.zig` - Add journal access method
4. `src/evm/evm.zig` - Add log access method (if needed)

### Key Data Structures
- `Frame.stack` - Stack data access via `frame.stack.data[0..frame.stack.size()]`
- `Frame.memory` - Memory access via `memory.get_memory_ptr()` and windowing functions
- `CallJournal.entries` - Storage change tracking
- `Evm.logs` - Log entry storage

### Memory Ownership
- All capture functions return owned memory that must be freed
- PreStepState manages temporary snapshots and cleans up in deinit()
- StepResult manages all captured data and provides deinit() for cleanup

This implementation provides comprehensive real-time EVM state capture while maintaining memory efficiency and proper Zig ownership semantics.

---

## Comprehensive Testing Strategy for New Features

### Overview of Testing Requirements

The existing `test/evm/memory_tracer_test.zig` file provides a foundation for testing the tracer, but needs exhaustive tests for the new real state capture features. This section provides detailed guidance on adding comprehensive tests to verify with 100% certainty that all new features work correctly.

### Test File Organization

Add these tests to `test/evm/memory_tracer_test.zig` following the zero-abstraction philosophy:
- Each test is completely self-contained
- No helper functions or abstractions
- All setup is explicit and inline
- Every test documents the exact behavior being verified

---

## Test Suite 1: Stack Changes Tracking

### Test 1.1: Basic Stack Push Detection
```zig
test "MemoryTracer: real stack changes - detect single push operation" {
    const allocator = std.testing.allocator;
    
    // Bytecode: PUSH1 42, STOP
    const bytecode = [_]u8{ 0x60, 0x2A, 0x00 };
    
    // Full EVM setup (following zero-abstraction pattern)
    const table = &OpcodeMetadata.DEFAULT;
    var analysis = try CodeAnalysis.from_code(allocator, &bytecode, table);
    defer analysis.deinit();
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();
    
    var evm_instance = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm_instance.deinit();
    
    const host = Host.init(&evm_instance);
    var frame = try Frame.init(1000000, false, 0, AddressHelpers.ZERO, AddressHelpers.ZERO, 0, &analysis, host, db_interface, allocator);
    defer frame.deinit(allocator);
    
    const tracer_config = TracerConfig{
        .memory_max_bytes = 256,
        .stack_max_items = 32,
        .log_data_max_bytes = 256,
    };
    
    var memory_tracer = try MemoryTracer.init(allocator, tracer_config);
    defer memory_tracer.deinit();
    
    evm_instance.set_tracer(memory_tracer.handle());
    
    // Execute
    const execution_result = evm_instance.interpret(&frame);
    execution_result catch {};
    
    // Get trace and verify stack changes
    var execution_trace = try memory_tracer.get_trace();
    defer execution_trace.deinit(allocator);
    
    // Find the PUSH1 operation in the trace
    var found_push = false;
    for (execution_trace.struct_logs) |log| {
        if (std.mem.eql(u8, log.op, "PUSH1")) {
            found_push = true;
            
            // Verify stack changes show item was pushed
            if (log.stack_changes) |changes| {
                try std.testing.expectEqual(@as(usize, 1), changes.items_pushed.len);
                try std.testing.expectEqual(@as(u256, 0x2A), changes.items_pushed[0]);
                try std.testing.expectEqual(@as(usize, 0), changes.items_popped.len);
                try std.testing.expectEqual(@as(usize, 1), changes.current_stack.len);
            } else {
                try std.testing.expect(false); // Should have stack changes
            }
        }
    }
    try std.testing.expect(found_push);
}
```

### Test 1.2: Stack Pop Detection
```zig
test "MemoryTracer: real stack changes - detect pop operation" {
    const allocator = std.testing.allocator;
    
    // Bytecode: PUSH1 10, PUSH1 20, POP, STOP
    const bytecode = [_]u8{ 0x60, 0x0A, 0x60, 0x14, 0x50, 0x00 };
    
    // Full setup...
    const table = &OpcodeMetadata.DEFAULT;
    var analysis = try CodeAnalysis.from_code(allocator, &bytecode, table);
    defer analysis.deinit();
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();
    
    var evm_instance = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm_instance.deinit();
    
    const host = Host.init(&evm_instance);
    var frame = try Frame.init(1000000, false, 0, AddressHelpers.ZERO, AddressHelpers.ZERO, 0, &analysis, host, db_interface, allocator);
    defer frame.deinit(allocator);
    
    const tracer_config = TracerConfig{};
    var memory_tracer = try MemoryTracer.init(allocator, tracer_config);
    defer memory_tracer.deinit();
    
    evm_instance.set_tracer(memory_tracer.handle());
    
    const execution_result = evm_instance.interpret(&frame);
    execution_result catch {};
    
    var execution_trace = try memory_tracer.get_trace();
    defer execution_trace.deinit(allocator);
    
    // Find POP operation and verify stack changes
    for (execution_trace.struct_logs) |log| {
        if (std.mem.eql(u8, log.op, "POP")) {
            if (log.stack_changes) |changes| {
                try std.testing.expectEqual(@as(usize, 0), changes.items_pushed.len);
                try std.testing.expectEqual(@as(usize, 1), changes.items_popped.len);
                try std.testing.expectEqual(@as(u256, 0x14), changes.items_popped[0]); // Should pop 20
                try std.testing.expectEqual(@as(usize, 1), changes.current_stack.len); // One item remains
            } else {
                try std.testing.expect(false); // Should have stack changes
            }
        }
    }
}
```

### Test 1.3: Complex Stack Operations (DUP, SWAP)
```zig
test "MemoryTracer: real stack changes - DUP and SWAP operations" {
    const allocator = std.testing.allocator;
    
    // Bytecode: PUSH1 1, PUSH1 2, DUP2, SWAP1, STOP
    const bytecode = [_]u8{ 
        0x60, 0x01, // PUSH1 1
        0x60, 0x02, // PUSH1 2
        0x81,       // DUP2 (duplicate 2nd stack item)
        0x90,       // SWAP1 (swap top 2 items)
        0x00        // STOP
    };
    
    // Full setup...
    const table = &OpcodeMetadata.DEFAULT;
    var analysis = try CodeAnalysis.from_code(allocator, &bytecode, table);
    defer analysis.deinit();
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();
    
    var evm_instance = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm_instance.deinit();
    
    const host = Host.init(&evm_instance);
    var frame = try Frame.init(1000000, false, 0, AddressHelpers.ZERO, AddressHelpers.ZERO, 0, &analysis, host, db_interface, allocator);
    defer frame.deinit(allocator);
    
    const tracer_config = TracerConfig{};
    var memory_tracer = try MemoryTracer.init(allocator, tracer_config);
    defer memory_tracer.deinit();
    
    evm_instance.set_tracer(memory_tracer.handle());
    
    const execution_result = evm_instance.interpret(&frame);
    execution_result catch {};
    
    var execution_trace = try memory_tracer.get_trace();
    defer execution_trace.deinit(allocator);
    
    // Verify DUP2 operation
    for (execution_trace.struct_logs) |log| {
        if (std.mem.eql(u8, log.op, "DUP2")) {
            if (log.stack_changes) |changes| {
                try std.testing.expectEqual(@as(usize, 1), changes.items_pushed.len);
                try std.testing.expectEqual(@as(u256, 1), changes.items_pushed[0]); // Duplicates item at index 1
                try std.testing.expectEqual(@as(usize, 0), changes.items_popped.len);
                try std.testing.expectEqual(@as(usize, 3), changes.current_stack.len); // Now 3 items
            } else {
                try std.testing.expect(false);
            }
        }
        
        if (std.mem.eql(u8, log.op, "SWAP1")) {
            if (log.stack_changes) |changes| {
                // SWAP doesn't change stack size, but reorders items
                try std.testing.expectEqual(@as(usize, 3), changes.current_stack.len);
                // Top two items should be swapped
                try std.testing.expectEqual(@as(u256, 2), changes.current_stack[2]); // Top
                try std.testing.expectEqual(@as(u256, 1), changes.current_stack[1]); // Second
            } else {
                try std.testing.expect(false);
            }
        }
    }
}
```

### Test 1.4: Stack Boundary Conditions
```zig
test "MemoryTracer: real stack changes - bounded capture at configured limit" {
    const allocator = std.testing.allocator;
    
    // Generate bytecode that pushes many items to test bounded capture
    var bytecode = std.ArrayList(u8).init(allocator);
    defer bytecode.deinit();
    
    // Push 50 items onto stack
    for (0..50) |i| {
        try bytecode.append(0x60); // PUSH1
        try bytecode.append(@intCast(i));
    }
    try bytecode.append(0x00); // STOP
    
    // Setup with small stack capture limit
    const table = &OpcodeMetadata.DEFAULT;
    var analysis = try CodeAnalysis.from_code(allocator, bytecode.items, table);
    defer analysis.deinit();
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();
    
    var evm_instance = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm_instance.deinit();
    
    const host = Host.init(&evm_instance);
    var frame = try Frame.init(1000000, false, 0, AddressHelpers.ZERO, AddressHelpers.ZERO, 0, &analysis, host, db_interface, allocator);
    defer frame.deinit(allocator);
    
    const tracer_config = TracerConfig{
        .memory_max_bytes = 256,
        .stack_max_items = 10, // Small limit - only capture 10 items
        .log_data_max_bytes = 256,
    };
    
    var memory_tracer = try MemoryTracer.init(allocator, tracer_config);
    defer memory_tracer.deinit();
    
    evm_instance.set_tracer(memory_tracer.handle());
    
    const execution_result = evm_instance.interpret(&frame);
    execution_result catch {};
    
    var execution_trace = try memory_tracer.get_trace();
    defer execution_trace.deinit(allocator);
    
    // Verify stack is bounded to configured limit
    for (execution_trace.struct_logs) |log| {
        if (log.stack_changes) |changes| {
            try std.testing.expect(changes.current_stack.len <= tracer_config.stack_max_items);
        }
    }
}
```

---

## Test Suite 2: Memory Changes Tracking

### Test 2.1: Basic Memory Write Detection
```zig
test "MemoryTracer: real memory changes - detect MSTORE operation" {
    const allocator = std.testing.allocator;
    
    // Bytecode: PUSH1 0x42, PUSH1 0x00, MSTORE, STOP
    const bytecode = [_]u8{ 
        0x60, 0x42, // PUSH1 0x42 (value)
        0x60, 0x00, // PUSH1 0x00 (offset)
        0x52,       // MSTORE
        0x00        // STOP
    };
    
    // Full setup...
    const table = &OpcodeMetadata.DEFAULT;
    var analysis = try CodeAnalysis.from_code(allocator, &bytecode, table);
    defer analysis.deinit();
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();
    
    var evm_instance = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm_instance.deinit();
    
    const host = Host.init(&evm_instance);
    var frame = try Frame.init(1000000, false, 0, AddressHelpers.ZERO, AddressHelpers.ZERO, 0, &analysis, host, db_interface, allocator);
    defer frame.deinit(allocator);
    
    const tracer_config = TracerConfig{};
    var memory_tracer = try MemoryTracer.init(allocator, tracer_config);
    defer memory_tracer.deinit();
    
    evm_instance.set_tracer(memory_tracer.handle());
    
    const execution_result = evm_instance.interpret(&frame);
    execution_result catch {};
    
    var execution_trace = try memory_tracer.get_trace();
    defer execution_trace.deinit(allocator);
    
    // Find MSTORE and verify memory changes
    for (execution_trace.struct_logs) |log| {
        if (std.mem.eql(u8, log.op, "MSTORE")) {
            if (log.memory_changes) |changes| {
                try std.testing.expectEqual(@as(u64, 0), changes.offset);
                try std.testing.expectEqual(@as(usize, 32), changes.data.len);
                // Value 0x42 should be at end of 32-byte word (big-endian)
                try std.testing.expectEqual(@as(u8, 0x42), changes.data[31]);
                // Memory should have been expanded to at least 32 bytes
                try std.testing.expect(changes.current_memory.len >= 32);
            } else {
                try std.testing.expect(false); // Should have memory changes
            }
        }
    }
}
```

### Test 2.2: Memory Expansion Detection
```zig
test "MemoryTracer: real memory changes - detect memory expansion" {
    const allocator = std.testing.allocator;
    
    // Bytecode: Store at offset 64 to force memory expansion
    const bytecode = [_]u8{ 
        0x60, 0xFF, // PUSH1 0xFF (value)
        0x60, 0x40, // PUSH1 0x40 (offset 64)
        0x52,       // MSTORE
        0x00        // STOP
    };
    
    // Full setup...
    const table = &OpcodeMetadata.DEFAULT;
    var analysis = try CodeAnalysis.from_code(allocator, &bytecode, table);
    defer analysis.deinit();
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();
    
    var evm_instance = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm_instance.deinit();
    
    const host = Host.init(&evm_instance);
    var frame = try Frame.init(1000000, false, 0, AddressHelpers.ZERO, AddressHelpers.ZERO, 0, &analysis, host, db_interface, allocator);
    defer frame.deinit(allocator);
    
    const tracer_config = TracerConfig{};
    var memory_tracer = try MemoryTracer.init(allocator, tracer_config);
    defer memory_tracer.deinit();
    
    evm_instance.set_tracer(memory_tracer.handle());
    
    const execution_result = evm_instance.interpret(&frame);
    execution_result catch {};
    
    var execution_trace = try memory_tracer.get_trace();
    defer execution_trace.deinit(allocator);
    
    // Verify memory expansion
    for (execution_trace.struct_logs) |log| {
        if (std.mem.eql(u8, log.op, "MSTORE")) {
            if (log.memory_changes) |changes| {
                try std.testing.expectEqual(@as(u64, 64), changes.offset);
                // Memory should expand to at least 96 bytes (64 + 32)
                try std.testing.expect(changes.current_memory.len >= 96);
            } else {
                try std.testing.expect(false);
            }
        }
    }
}
```

### Test 2.3: Multiple Memory Operations
```zig
test "MemoryTracer: real memory changes - track multiple memory modifications" {
    const allocator = std.testing.allocator;
    
    // Multiple memory operations
    const bytecode = [_]u8{ 
        0x60, 0x11, 0x60, 0x00, 0x52, // MSTORE 0x11 at 0x00
        0x60, 0x22, 0x60, 0x20, 0x52, // MSTORE 0x22 at 0x20
        0x60, 0x33, 0x60, 0x10, 0x53, // MSTORE8 0x33 at 0x10
        0x00 // STOP
    };
    
    // Full setup...
    const table = &OpcodeMetadata.DEFAULT;
    var analysis = try CodeAnalysis.from_code(allocator, &bytecode, table);
    defer analysis.deinit();
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();
    
    var evm_instance = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm_instance.deinit();
    
    const host = Host.init(&evm_instance);
    var frame = try Frame.init(1000000, false, 0, AddressHelpers.ZERO, AddressHelpers.ZERO, 0, &analysis, host, db_interface, allocator);
    defer frame.deinit(allocator);
    
    const tracer_config = TracerConfig{};
    var memory_tracer = try MemoryTracer.init(allocator, tracer_config);
    defer memory_tracer.deinit();
    
    evm_instance.set_tracer(memory_tracer.handle());
    
    const execution_result = evm_instance.interpret(&frame);
    execution_result catch {};
    
    var execution_trace = try memory_tracer.get_trace();
    defer execution_trace.deinit(allocator);
    
    // Count memory operations
    var mstore_count: u32 = 0;
    var mstore8_count: u32 = 0;
    
    for (execution_trace.struct_logs) |log| {
        if (std.mem.eql(u8, log.op, "MSTORE")) {
            mstore_count += 1;
            if (log.memory_changes) |changes| {
                // Each MSTORE should show different memory state
                try std.testing.expect(changes.data.len > 0);
                try std.testing.expect(changes.current_memory.len > 0);
            }
        }
        if (std.mem.eql(u8, log.op, "MSTORE8")) {
            mstore8_count += 1;
            if (log.memory_changes) |changes| {
                // MSTORE8 modifies single byte
                try std.testing.expect(changes.data.len >= 1);
            }
        }
    }
    
    try std.testing.expectEqual(@as(u32, 2), mstore_count);
    try std.testing.expectEqual(@as(u32, 1), mstore8_count);
}
```

### Test 2.4: Memory Access Region Windowing
```zig
test "MemoryTracer: enhanced memory snapshot with access region" {
    const allocator = std.testing.allocator;
    
    // Access memory at specific offset to test windowing
    const bytecode = [_]u8{ 
        0x60, 0xAB, // PUSH1 0xAB
        0x61, 0x01, 0x00, // PUSH2 0x0100 (offset 256)
        0x52, // MSTORE
        0x61, 0x01, 0x00, // PUSH2 0x0100
        0x51, // MLOAD
        0x00 // STOP
    };
    
    // Full setup...
    const table = &OpcodeMetadata.DEFAULT;
    var analysis = try CodeAnalysis.from_code(allocator, &bytecode, table);
    defer analysis.deinit();
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();
    
    var evm_instance = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm_instance.deinit();
    
    const host = Host.init(&evm_instance);
    var frame = try Frame.init(1000000, false, 0, AddressHelpers.ZERO, AddressHelpers.ZERO, 0, &analysis, host, db_interface, allocator);
    defer frame.deinit(allocator);
    
    const tracer_config = TracerConfig{
        .memory_max_bytes = 128, // Small window to test windowing
        .stack_max_items = 32,
        .log_data_max_bytes = 256,
    };
    
    var memory_tracer = try MemoryTracer.init(allocator, tracer_config);
    defer memory_tracer.deinit();
    
    evm_instance.set_tracer(memory_tracer.handle());
    
    const execution_result = evm_instance.interpret(&frame);
    execution_result catch {};
    
    var execution_trace = try memory_tracer.get_trace();
    defer execution_trace.deinit(allocator);
    
    // Verify memory windowing around access region
    for (execution_trace.struct_logs) |log| {
        if (std.mem.eql(u8, log.op, "MLOAD")) {
            if (log.memory) |memory| {
                // Memory snapshot should be bounded to config limit
                try std.testing.expect(memory.len <= tracer_config.memory_max_bytes);
                // Should capture window around accessed region
                // This tests the enhanced memory snapshot with access region feature
            }
        }
    }
}
```

---

## Test Suite 3: Storage Changes Tracking

### Test 3.1: Basic Storage Write Detection
```zig
test "MemoryTracer: real storage changes - detect SSTORE operation" {
    const allocator = std.testing.allocator;
    
    // Bytecode: Store value 999 at storage slot 1
    const bytecode = [_]u8{ 
        0x61, 0x03, 0xE7, // PUSH2 0x03E7 (999)
        0x60, 0x01,       // PUSH1 0x01 (slot)
        0x55,             // SSTORE
        0x00              // STOP
    };
    
    // Full setup...
    const table = &OpcodeMetadata.DEFAULT;
    var analysis = try CodeAnalysis.from_code(allocator, &bytecode, table);
    defer analysis.deinit();
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();
    
    var evm_instance = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm_instance.deinit();
    
    const host = Host.init(&evm_instance);
    var frame = try Frame.init(1000000, false, 0, AddressHelpers.ZERO, AddressHelpers.ZERO, 0, &analysis, host, db_interface, allocator);
    defer frame.deinit(allocator);
    
    const tracer_config = TracerConfig{};
    var memory_tracer = try MemoryTracer.init(allocator, tracer_config);
    defer memory_tracer.deinit();
    
    evm_instance.set_tracer(memory_tracer.handle());
    
    const execution_result = evm_instance.interpret(&frame);
    execution_result catch {};
    
    var execution_trace = try memory_tracer.get_trace();
    defer execution_trace.deinit(allocator);
    
    // Find SSTORE and verify storage changes
    for (execution_trace.struct_logs) |log| {
        if (std.mem.eql(u8, log.op, "SSTORE")) {
            try std.testing.expect(log.storage.len > 0);
            const storage_change = log.storage[0];
            try std.testing.expectEqual(@as(u256, 1), storage_change.key);
            try std.testing.expectEqual(@as(u256, 999), storage_change.value);
            try std.testing.expectEqual(@as(u256, 0), storage_change.original_value);
        }
    }
}
```

### Test 3.2: Storage Read-Modify-Write Pattern
```zig
test "MemoryTracer: real storage changes - SLOAD followed by SSTORE" {
    const allocator = std.testing.allocator;
    
    // Bytecode: Load from slot, increment, store back
    const bytecode = [_]u8{ 
        0x60, 0x01, // PUSH1 0x01 (slot)
        0x54,       // SLOAD
        0x60, 0x01, // PUSH1 0x01
        0x01,       // ADD
        0x60, 0x01, // PUSH1 0x01 (slot)
        0x55,       // SSTORE
        0x00        // STOP
    };
    
    // Full setup...
    const table = &OpcodeMetadata.DEFAULT;
    var analysis = try CodeAnalysis.from_code(allocator, &bytecode, table);
    defer analysis.deinit();
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();
    
    var evm_instance = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm_instance.deinit();
    
    // Pre-set storage value
    try evm_instance.state.set_storage(AddressHelpers.ZERO, 1, 100);
    
    const host = Host.init(&evm_instance);
    var frame = try Frame.init(1000000, false, 0, AddressHelpers.ZERO, AddressHelpers.ZERO, 0, &analysis, host, db_interface, allocator);
    defer frame.deinit(allocator);
    
    const tracer_config = TracerConfig{};
    var memory_tracer = try MemoryTracer.init(allocator, tracer_config);
    defer memory_tracer.deinit();
    
    evm_instance.set_tracer(memory_tracer.handle());
    
    const execution_result = evm_instance.interpret(&frame);
    execution_result catch {};
    
    var execution_trace = try memory_tracer.get_trace();
    defer execution_trace.deinit(allocator);
    
    // Verify SLOAD doesn't create storage changes, but SSTORE does
    var found_sload = false;
    var found_sstore = false;
    
    for (execution_trace.struct_logs) |log| {
        if (std.mem.eql(u8, log.op, "SLOAD")) {
            found_sload = true;
            // SLOAD shouldn't have storage changes
            try std.testing.expectEqual(@as(usize, 0), log.storage.len);
        }
        if (std.mem.eql(u8, log.op, "SSTORE")) {
            found_sstore = true;
            try std.testing.expect(log.storage.len > 0);
            const storage_change = log.storage[0];
            try std.testing.expectEqual(@as(u256, 1), storage_change.key);
            try std.testing.expectEqual(@as(u256, 101), storage_change.value); // Incremented
            try std.testing.expectEqual(@as(u256, 100), storage_change.original_value);
        }
    }
    
    try std.testing.expect(found_sload);
    try std.testing.expect(found_sstore);
}
```

### Test 3.3: Multiple Storage Slots
```zig
test "MemoryTracer: real storage changes - multiple storage slots modified" {
    const allocator = std.testing.allocator;
    
    // Modify multiple storage slots
    const bytecode = [_]u8{ 
        0x60, 0xAA, 0x60, 0x01, 0x55, // Store 0xAA at slot 1
        0x60, 0xBB, 0x60, 0x02, 0x55, // Store 0xBB at slot 2
        0x60, 0xCC, 0x60, 0x03, 0x55, // Store 0xCC at slot 3
        0x00 // STOP
    };
    
    // Full setup...
    const table = &OpcodeMetadata.DEFAULT;
    var analysis = try CodeAnalysis.from_code(allocator, &bytecode, table);
    defer analysis.deinit();
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();
    
    var evm_instance = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm_instance.deinit();
    
    const host = Host.init(&evm_instance);
    var frame = try Frame.init(1000000, false, 0, AddressHelpers.ZERO, AddressHelpers.ZERO, 0, &analysis, host, db_interface, allocator);
    defer frame.deinit(allocator);
    
    const tracer_config = TracerConfig{};
    var memory_tracer = try MemoryTracer.init(allocator, tracer_config);
    defer memory_tracer.deinit();
    
    evm_instance.set_tracer(memory_tracer.handle());
    
    const execution_result = evm_instance.interpret(&frame);
    execution_result catch {};
    
    var execution_trace = try memory_tracer.get_trace();
    defer execution_trace.deinit(allocator);
    
    // Count storage operations and verify each
    var sstore_count: u32 = 0;
    const expected_values = [_]u256{ 0xAA, 0xBB, 0xCC };
    
    for (execution_trace.struct_logs) |log| {
        if (std.mem.eql(u8, log.op, "SSTORE")) {
            try std.testing.expect(log.storage.len > 0);
            const storage_change = log.storage[0];
            
            // Verify slot and value match expectations
            if (sstore_count < 3) {
                try std.testing.expectEqual(sstore_count + 1, storage_change.key);
                try std.testing.expectEqual(expected_values[sstore_count], storage_change.value);
            }
            
            sstore_count += 1;
        }
    }
    
    try std.testing.expectEqual(@as(u32, 3), sstore_count);
}
```

---

## Test Suite 4: Log Entries Tracking

### Test 4.1: Basic LOG0 Event
```zig
test "MemoryTracer: real log entries - capture LOG0 event" {
    const allocator = std.testing.allocator;
    
    // Bytecode: Store data in memory then emit LOG0
    const bytecode = [_]u8{ 
        0x60, 0x42,       // PUSH1 0x42 (data)
        0x60, 0x00,       // PUSH1 0x00 (offset)
        0x52,             // MSTORE
        0x60, 0x20,       // PUSH1 0x20 (length)
        0x60, 0x00,       // PUSH1 0x00 (offset)
        0xa0,             // LOG0
        0x00              // STOP
    };
    
    // Full setup...
    const table = &OpcodeMetadata.DEFAULT;
    var analysis = try CodeAnalysis.from_code(allocator, &bytecode, table);
    defer analysis.deinit();
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();
    
    var evm_instance = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm_instance.deinit();
    
    const host = Host.init(&evm_instance);
    var frame = try Frame.init(1000000, false, 0, AddressHelpers.ZERO, AddressHelpers.ZERO, 0, &analysis, host, db_interface, allocator);
    defer frame.deinit(allocator);
    
    const tracer_config = TracerConfig{};
    var memory_tracer = try MemoryTracer.init(allocator, tracer_config);
    defer memory_tracer.deinit();
    
    evm_instance.set_tracer(memory_tracer.handle());
    
    const execution_result = evm_instance.interpret(&frame);
    execution_result catch {};
    
    var execution_trace = try memory_tracer.get_trace();
    defer execution_trace.deinit(allocator);
    
    // Find LOG0 and verify log entry
    for (execution_trace.struct_logs) |log| {
        if (std.mem.eql(u8, log.op, "LOG0")) {
            try std.testing.expect(log.logs.len > 0);
            const log_entry = log.logs[0];
            
            try std.testing.expectEqual(@as(usize, 0), log_entry.topics.len); // LOG0 has no topics
            try std.testing.expectEqual(@as(usize, 32), log_entry.data.len);
            try std.testing.expectEqual(@as(u8, 0x42), log_entry.data[31]); // Value at end
            try std.testing.expect(!log_entry.data_truncated);
        }
    }
}
```

### Test 4.2: LOG with Topics (LOG1, LOG2, LOG3, LOG4)
```zig
test "MemoryTracer: real log entries - capture LOG3 with topics" {
    const allocator = std.testing.allocator;
    
    // Bytecode: Emit LOG3 (Transfer event simulation)
    const bytecode = [_]u8{ 
        0x60, 0x64,       // PUSH1 0x64 (amount = 100)
        0x60, 0x00,       // PUSH1 0x00 (offset)
        0x52,             // MSTORE (store amount in memory)
        // Push topics (in reverse order for stack)
        0x60, 0x99,       // PUSH1 0x99 (to address, simplified)
        0x60, 0x88,       // PUSH1 0x88 (from address, simplified)
        0x60, 0x77,       // PUSH1 0x77 (event signature, simplified)
        // Emit LOG3
        0x60, 0x20,       // PUSH1 0x20 (data length)
        0x60, 0x00,       // PUSH1 0x00 (data offset)
        0xa3,             // LOG3
        0x00              // STOP
    };
    
    // Full setup...
    const table = &OpcodeMetadata.DEFAULT;
    var analysis = try CodeAnalysis.from_code(allocator, &bytecode, table);
    defer analysis.deinit();
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();
    
    var evm_instance = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm_instance.deinit();
    
    const host = Host.init(&evm_instance);
    var frame = try Frame.init(1000000, false, 0, AddressHelpers.ZERO, AddressHelpers.ZERO, 0, &analysis, host, db_interface, allocator);
    defer frame.deinit(allocator);
    
    const tracer_config = TracerConfig{};
    var memory_tracer = try MemoryTracer.init(allocator, tracer_config);
    defer memory_tracer.deinit();
    
    evm_instance.set_tracer(memory_tracer.handle());
    
    const execution_result = evm_instance.interpret(&frame);
    execution_result catch {};
    
    var execution_trace = try memory_tracer.get_trace();
    defer execution_trace.deinit(allocator);
    
    // Find LOG3 and verify log entry with topics
    for (execution_trace.struct_logs) |log| {
        if (std.mem.eql(u8, log.op, "LOG3")) {
            try std.testing.expect(log.logs.len > 0);
            const log_entry = log.logs[0];
            
            try std.testing.expectEqual(@as(usize, 3), log_entry.topics.len); // LOG3 has 3 topics
            try std.testing.expectEqual(@as(u256, 0x77), log_entry.topics[0]); // Event signature
            try std.testing.expectEqual(@as(u256, 0x88), log_entry.topics[1]); // From address
            try std.testing.expectEqual(@as(u256, 0x99), log_entry.topics[2]); // To address
            try std.testing.expectEqual(@as(usize, 32), log_entry.data.len);
            try std.testing.expectEqual(@as(u8, 0x64), log_entry.data[31]); // Amount
        }
    }
}
```

### Test 4.3: Bounded Log Data Capture
```zig
test "MemoryTracer: real log entries - bounded log data capture" {
    const allocator = std.testing.allocator;
    
    // Generate bytecode that emits a log with large data
    var bytecode = std.ArrayList(u8).init(allocator);
    defer bytecode.deinit();
    
    // Store 256 bytes of data in memory
    for (0..8) |i| {
        try bytecode.append(0x60); // PUSH1
        try bytecode.append(@intCast(0xFF - i)); // Different values
        try bytecode.append(0x60); // PUSH1
        try bytecode.append(@intCast(i * 32)); // Offset
        try bytecode.append(0x52); // MSTORE
    }
    
    // Emit LOG0 with 256 bytes of data
    try bytecode.append(0x61); // PUSH2
    try bytecode.append(0x01); // 256 (length)
    try bytecode.append(0x00);
    try bytecode.append(0x60); // PUSH1
    try bytecode.append(0x00); // 0 (offset)
    try bytecode.append(0xa0); // LOG0
    try bytecode.append(0x00); // STOP
    
    // Setup with small log data limit
    const table = &OpcodeMetadata.DEFAULT;
    var analysis = try CodeAnalysis.from_code(allocator, bytecode.items, table);
    defer analysis.deinit();
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();
    
    var evm_instance = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm_instance.deinit();
    
    const host = Host.init(&evm_instance);
    var frame = try Frame.init(1000000, false, 0, AddressHelpers.ZERO, AddressHelpers.ZERO, 0, &analysis, host, db_interface, allocator);
    defer frame.deinit(allocator);
    
    const tracer_config = TracerConfig{
        .memory_max_bytes = 1024,
        .stack_max_items = 32,
        .log_data_max_bytes = 64, // Small limit for log data
    };
    
    var memory_tracer = try MemoryTracer.init(allocator, tracer_config);
    defer memory_tracer.deinit();
    
    evm_instance.set_tracer(memory_tracer.handle());
    
    const execution_result = evm_instance.interpret(&frame);
    execution_result catch {};
    
    var execution_trace = try memory_tracer.get_trace();
    defer execution_trace.deinit(allocator);
    
    // Verify log data is bounded
    for (execution_trace.struct_logs) |log| {
        if (std.mem.eql(u8, log.op, "LOG0")) {
            try std.testing.expect(log.logs.len > 0);
            const log_entry = log.logs[0];
            
            // Data should be truncated to configured limit
            try std.testing.expect(log_entry.data.len <= tracer_config.log_data_max_bytes);
            try std.testing.expect(log_entry.data_truncated); // Should indicate truncation
        }
    }
}
```

---

## Test Suite 5: Integration and Edge Cases

### Test 5.1: Complete ERC20 Transfer with All Features
```zig
test "MemoryTracer: integration - complete ERC20 transfer with all state changes" {
    // This test is already provided in memory_tracer_test.zig as 
    // "MemoryTracer: real-world ERC20 transfer simulation with comprehensive tracing"
    // but should be enhanced to verify all new features work together
    
    // The test should verify:
    // 1. Stack changes during arithmetic operations
    // 2. Memory changes when preparing log data
    // 3. Storage changes for balance updates
    // 4. Log entries for Transfer event
    // 5. Proper bounded capture of all data
}
```

### Test 5.2: Error Conditions and Recovery
```zig
test "MemoryTracer: error handling - capture state before revert" {
    const allocator = std.testing.allocator;
    
    // Bytecode that modifies state then reverts
    const bytecode = [_]u8{ 
        0x60, 0x42, 0x60, 0x01, 0x55, // Store 0x42 at slot 1
        0x60, 0x00, 0x60, 0x00, 0xfd, // REVERT with empty data
    };
    
    // Full setup...
    const table = &OpcodeMetadata.DEFAULT;
    var analysis = try CodeAnalysis.from_code(allocator, &bytecode, table);
    defer analysis.deinit();
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();
    
    var evm_instance = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm_instance.deinit();
    
    const host = Host.init(&evm_instance);
    var frame = try Frame.init(1000000, false, 0, AddressHelpers.ZERO, AddressHelpers.ZERO, 0, &analysis, host, db_interface, allocator);
    defer frame.deinit(allocator);
    
    const tracer_config = TracerConfig{};
    var memory_tracer = try MemoryTracer.init(allocator, tracer_config);
    defer memory_tracer.deinit();
    
    evm_instance.set_tracer(memory_tracer.handle());
    
    const execution_result = evm_instance.interpret(&frame);
    execution_result catch {}; // Expect REVERT
    
    var execution_trace = try memory_tracer.get_trace();
    defer execution_trace.deinit(allocator);
    
    // Should have captured SSTORE before revert
    var found_sstore = false;
    for (execution_trace.struct_logs) |log| {
        if (std.mem.eql(u8, log.op, "SSTORE")) {
            found_sstore = true;
            // Storage change should be captured even though transaction reverts
            try std.testing.expect(log.storage.len > 0);
        }
    }
    try std.testing.expect(found_sstore);
    
    // Trace should indicate failure
    try std.testing.expect(execution_trace.failed);
}
```

### Test 5.3: Memory Allocation Stress Test
```zig
test "MemoryTracer: stress test - handle many allocations without leaks" {
    const allocator = std.testing.allocator;
    
    // Complex bytecode with many operations
    var bytecode = std.ArrayList(u8).init(allocator);
    defer bytecode.deinit();
    
    // Generate 100 operations that each allocate tracer memory
    for (0..100) |i| {
        // Push, store to memory, store to storage, emit log
        try bytecode.append(0x60);
        try bytecode.append(@intCast(i & 0xFF));
        try bytecode.append(0x60);
        try bytecode.append(@intCast(i * 8));
        try bytecode.append(0x52); // MSTORE
    }
    try bytecode.append(0x00); // STOP
    
    // Run with allocation tracking
    const table = &OpcodeMetadata.DEFAULT;
    var analysis = try CodeAnalysis.from_code(allocator, bytecode.items, table);
    defer analysis.deinit();
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();
    
    var evm_instance = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm_instance.deinit();
    
    const host = Host.init(&evm_instance);
    var frame = try Frame.init(10000000, false, 0, AddressHelpers.ZERO, AddressHelpers.ZERO, 0, &analysis, host, db_interface, allocator);
    defer frame.deinit(allocator);
    
    const tracer_config = TracerConfig{
        .memory_max_bytes = 64, // Small to force many bounded captures
        .stack_max_items = 8,
        .log_data_max_bytes = 32,
    };
    
    var memory_tracer = try MemoryTracer.init(allocator, tracer_config);
    defer memory_tracer.deinit();
    
    evm_instance.set_tracer(memory_tracer.handle());
    
    const execution_result = evm_instance.interpret(&frame);
    execution_result catch {};
    
    var execution_trace = try memory_tracer.get_trace();
    defer execution_trace.deinit(allocator); // Should properly free all allocations
    
    // Verify we captured many operations
    try std.testing.expect(execution_trace.struct_logs.len >= 50);
    
    // All memory should be properly freed by defer statements
    // Memory leak detection would catch any issues here
}
```

---

## Test Execution Guidelines

### Running the Tests

```bash
# Run all tracer tests
zig build test --filter "MemoryTracer"

# Run with verbose output to see trace details
zig build test --filter "MemoryTracer" 2>&1 | less

# Run with memory leak detection
zig build test --filter "MemoryTracer" -Drelease-safe=true
```

### Debugging Failed Tests

When a test fails, use these debugging strategies:

1. **Enable Debug Logging**: Set `std.testing.log_level = .debug` in the test
2. **Print Trace Details**: Use `std.log.warn()` to output captured data
3. **Check Memory**: Verify allocations are properly freed with `defer`
4. **Validate Assumptions**: Ensure bytecode produces expected operations

### Performance Validation

Run performance tests to ensure tracing doesn't excessively impact execution:

```zig
test "MemoryTracer: performance - measure overhead percentage" {
    // Already provided in memory_tracer_test.zig
    // Ensures tracing overhead is reasonable (< 10000% in debug builds)
}
```

### Coverage Verification

Ensure all new capture functions are tested:
- [ ] `capture_stack_changes` - Stack push/pop detection
- [ ] `capture_memory_changes` - Memory delta tracking
- [ ] `collect_storage_changes_enhanced` - Storage modifications
- [ ] `copy_logs_bounded` - Log entry capture
- [ ] `predictMemoryAccess` - Access region detection

---

## Expected Test Results

When all features are correctly implemented:

1. **Stack Changes**: All tests should show accurate push/pop counts and values
2. **Memory Changes**: Tests should capture exact modified regions and data
3. **Storage Changes**: SSTORE operations should show correct key/value pairs
4. **Log Entries**: LOG0-LOG4 should capture topics and data correctly
5. **Bounded Capture**: All data should respect configured limits
6. **Performance**: Overhead should be reasonable (< 10000% in debug)
7. **Memory Safety**: No leaks detected, all allocations properly freed

This comprehensive testing ensures the real tracer state capture implementation is robust, accurate, and production-ready.