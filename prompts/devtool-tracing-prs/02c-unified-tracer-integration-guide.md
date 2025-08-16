# Unified Tracer Integration Guide: Complete Implementation Instructions

## Table of Contents
1. [Overview](#overview)
2. [Prerequisites](#prerequisites)
3. [Understanding the Current Architecture](#understanding-the-current-architecture)
4. [Phase 1: Extending MemoryTracer](#phase-1-extending-memorytracer)
5. [Phase 2: Updating Type Definitions](#phase-2-updating-type-definitions)
6. [Phase 3: Interpreter Integration](#phase-3-interpreter-integration)
7. [Phase 4: Message Hook Integration](#phase-4-message-hook-integration)
8. [Phase 5: Testing](#phase-5-testing)
9. [Common Pitfalls and Solutions](#common-pitfalls-and-solutions)

## Overview

This guide will walk you through integrating a unified tracer system that combines data collection with execution control. The goal is to evolve the existing `MemoryTracer` to support both passive tracing (current behavior) and active debugging (stepping, breakpoints, etc.).

### What We're Building

We're enhancing the existing `MemoryTracer` at `src/evm/tracing/memory_tracer.zig` to:
- Keep all existing functionality (backward compatible)
- Add execution control (pause/continue/abort)
- Support manual stepping through code
- Provide complete state transitions (before AND after each operation)
- Support granular callbacks for different use cases

### Why This Design?

Currently, we have two separate systems:
1. **DebugHooks** (`src/evm/debug_hooks.zig`) - Controls execution but limited visibility
2. **MemoryTracer** (`src/evm/tracing/memory_tracer.zig`) - Collects data but can't control

We're unifying them into one powerful system that does both.

## Prerequisites

### Understanding Zig Basics

Before starting, you should understand these Zig concepts:

#### 1. **Optional Types** (marked with `?`)
```zig
// Optional means it can be null
var maybe_value: ?u32 = null;  // Can be null
maybe_value = 42;               // Or have a value

// Check if has value
if (maybe_value) |value| {
    // value is unwrapped here (type u32, not ?u32)
}
```

#### 2. **Error Unions** (marked with `!`)
```zig
// Function can return error OR value
fn might_fail() !u32 {
    if (bad_condition) return error.SomethingBad;
    return 42;
}

// Handle errors
const result = might_fail() catch |err| {
    // Handle error
    return err;
};
// Or propagate with try
const result = try might_fail(); // Propagates error up
```

#### 3. **Pointers and References**
```zig
var x: u32 = 42;
var ptr: *u32 = &x;        // Pointer to x
var const_ptr: *const u32 = &x; // Can't modify through this

// Function pointers
const MyFn = *const fn(x: u32) void;
```

#### 4. **Struct Methods**
```zig
const MyStruct = struct {
    value: u32,
    
    // Method (self is pointer)
    pub fn increment(self: *MyStruct) void {
        self.value += 1;
    }
    
    // Const method (can't modify)
    pub fn getValue(self: *const MyStruct) u32 {
        return self.value;
    }
};
```

#### 5. **Memory Management**
```zig
// Always use defer for cleanup
const data = try allocator.alloc(u8, 100);
defer allocator.free(data);  // Will run when scope exits
```

### Understanding the Codebase Structure

Key files you'll be working with:
- `src/evm/tracing/memory_tracer.zig` - Main tracer implementation
- `src/evm/tracing/trace_types.zig` - Type definitions
- `src/evm/evm/interpret.zig` - Interpreter that calls hooks
- `src/evm/execution/system.zig` - CALL/CREATE operations
- `src/evm/debug_hooks.zig` - Current debug hooks (reference)

## Understanding the Current Architecture

### Current MemoryTracer Flow

Look at `src/evm/tracing/memory_tracer.zig` lines 130-238:

```zig
// Current flow is:
// 1. step_before_impl stores pre-state (line 130)
fn step_before_impl(ptr: *anyopaque, step_info: tracer.StepInfo) void {
    const self: *MemoryTracer = @ptrCast(@alignCast(ptr));
    self.on_pre_step(step_info);  // Just stores info
}

// 2. step_after_impl builds complete log (line 135)
fn step_after_impl(ptr: *anyopaque, step_result: tracer.StepResult) void {
    const self: *MemoryTracer = @ptrCast(@alignCast(ptr));
    self.on_post_step(step_result); // Combines with stored pre-state
}
```

The tracer is passive - it only observes and records.

### Current DebugHooks Flow

Look at `src/evm/debug_hooks.zig` lines 80-85:

```zig
// Returns control decision
pub const OnStepFn = *const fn (
    user_ctx: ?*anyopaque,
    frame: *Frame,
    pc: usize,
    opcode: u8,
) anyerror!StepControl;  // Can return cont/pause/abort
```

Debug hooks can control but have limited visibility.

## Phase 1: Extending MemoryTracer

### Step 1.1: Add Control Types to MemoryTracer

Open `src/evm/tracing/memory_tracer.zig` and add these types after line 32 (after the struct declaration begins):

```zig
pub const MemoryTracer = struct {
    // ... existing fields (lines 34-50) ...
    
    // ADD THESE NEW TYPES (insert after line 32):
    
    /// Control flow decision (copied from debug_hooks.zig)
    pub const StepControl = enum {
        cont,    // Continue execution
        pause,   // Pause and return control
        abort,   // Abort execution
    };
    
    /// Complete step transition with before/after state
    pub const StepTransition = struct {
        // Pre-execution state
        pc: usize,
        opcode: u8,
        op_name: []const u8,
        gas_before: u64,
        stack_size_before: usize,
        memory_size_before: usize,
        depth: u16,
        address: Address,
        
        // Post-execution state  
        gas_after: u64,
        gas_cost: u64,
        stack_size_after: usize,
        memory_size_after: usize,
        
        // Changes (optional detailed tracking)
        stack_snapshot: ?[]const u256,
        memory_snapshot: ?[]const u8,
        storage_changes: []const StorageChange,
        logs_emitted: []const LogEntry,
        error_info: ?ExecutionErrorInfo,
    };
    
    /// Message event for CALL/CREATE
    pub const MessageEvent = struct {
        phase: enum { before, after },
        params: CallParams,
        result: ?CallResult,  // null for 'before' phase
        depth: u16,
        gas_before: u64,
        gas_after: ?u64,      // null for 'before' phase
    };
    
    // ... rest of existing struct ...
```

### Step 1.2: Add New Fields to MemoryTracer

After the existing fields (around line 50), add:

```zig
    // ... existing fields (lines 34-50) ...
    
    // ADD THESE NEW FIELDS:
    
    // === Execution Control ===
    step_mode: enum {
        passive,        // Normal tracing (default)
        single_step,    // Pause after each instruction  
        breakpoint,     // Pause at specific PCs
    } = .passive,
    
    breakpoints: std.AutoHashMap(usize, void),
    
    // === Callback Types ===
    pub const OnStepTransitionFn = *const fn(
        self: *MemoryTracer,
        transition: StepTransition,
    ) anyerror!StepControl;
    
    pub const OnBeforeStepFn = *const fn(
        self: *MemoryTracer,
        info: tracer.StepInfo,
    ) anyerror!void;
    
    pub const OnAfterStepFn = *const fn(
        self: *MemoryTracer,
        result: tracer.StepResult,
    ) anyerror!void;
    
    // === New Callbacks ===
    on_step_transition: ?OnStepTransitionFn = null,
    on_before_step_hook: ?OnBeforeStepFn = null,
    on_after_step_hook: ?OnAfterStepFn = null,
    
    // === Transition Storage ===
    transitions: std.ArrayList(StepTransition),
    last_transition: ?StepTransition = null,
```

### Step 1.3: Update init() Method

Find the `init()` method (around line 61) and update it:

```zig
pub fn init(allocator: Allocator, config: tracer.TracerConfig) !MemoryTracer {
    return MemoryTracer{
        .allocator = allocator,
        .config = config,
        .struct_logs = std.ArrayList(tracer.StructLog).init(allocator),
        .gas_used = 0,
        .failed = false,
        .return_value = std.ArrayList(u8).init(allocator),
        .current_step_info = null,
        .last_journal_size = 0,
        .last_log_count = 0,
        
        // ADD THESE INITIALIZATIONS:
        .step_mode = .passive,
        .breakpoints = std.AutoHashMap(usize, void).init(allocator),
        .on_step_transition = null,
        .on_before_step_hook = null,
        .on_after_step_hook = null,
        .transitions = std.ArrayList(StepTransition).init(allocator),
        .last_transition = null,
    };
}
```

### Step 1.4: Update deinit() Method

Find the `deinit()` method (around line 80) and add cleanup:

```zig
pub fn deinit(self: *MemoryTracer) void {
    // ... existing cleanup (lines 82-86) ...
    
    // ADD THIS CLEANUP:
    self.breakpoints.deinit();
    
    // Clean up transitions
    for (self.transitions.items) |*trans| {
        if (trans.stack_snapshot) |stack| {
            self.allocator.free(stack);
        }
        if (trans.memory_snapshot) |memory| {
            self.allocator.free(memory);
        }
        self.allocator.free(trans.storage_changes);
        self.allocator.free(trans.logs_emitted);
    }
    self.transitions.deinit();
}
```

### Step 1.5: Add Control Methods

Add these new methods after the existing methods (around line 340):

```zig
// === NEW CONTROL METHODS ===

/// Set execution mode
pub fn set_step_mode(self: *MemoryTracer, mode: @TypeOf(self.step_mode)) void {
    self.step_mode = mode;
}

/// Add a breakpoint at PC
pub fn add_breakpoint(self: *MemoryTracer, pc: usize) !void {
    try self.breakpoints.put(pc, {});
}

/// Remove a breakpoint
pub fn remove_breakpoint(self: *MemoryTracer, pc: usize) bool {
    return self.breakpoints.remove(pc);
}

/// Clear all breakpoints
pub fn clear_breakpoints(self: *MemoryTracer) void {
    self.breakpoints.clearAndFree();
}

/// Execute one step (requires EVM support - see Phase 3)
pub fn step_once(self: *MemoryTracer) !?StepTransition {
    self.set_step_mode(.single_step);
    // After Phase 3, this will cause execution to pause after one instruction
    return self.last_transition;
}

/// Continue execution until breakpoint
pub fn continue_execution(self: *MemoryTracer) void {
    self.set_step_mode(.breakpoint);
}
```

### Step 1.6: Create Transition Builder

Add this helper method to build transitions from pre/post state:

```zig
/// Build complete transition from pre and post state
fn build_transition(
    self: *MemoryTracer,
    info: tracer.StepInfo,
    result: tracer.StepResult,
) !StepTransition {
    // Copy stack if within bounds
    var stack_copy: ?[]u256 = null;
    if (result.stack_snapshot) |stack| {
        if (stack.len <= self.config.stack_max_items) {
            stack_copy = try self.allocator.dupe(u256, stack);
        }
    }
    
    // Copy memory if within bounds
    var memory_copy: ?[]u8 = null;
    if (result.memory_snapshot) |memory| {
        if (memory.len <= self.config.memory_max_bytes) {
            memory_copy = try self.allocator.dupe(u8, memory);
        }
    }
    
    return StepTransition{
        // Pre-state from info
        .pc = info.pc,
        .opcode = info.opcode,
        .op_name = info.op_name,
        .gas_before = info.gas_before,
        .stack_size_before = info.stack_size,
        .memory_size_before = info.memory_size,
        .depth = info.depth,
        .address = info.address,
        
        // Post-state from result
        .gas_after = result.gas_after,
        .gas_cost = result.gas_cost,
        .stack_size_after = info.stack_size + 
            result.stack_changes.getPushCount() - 
            result.stack_changes.getPopCount(),
        .memory_size_after = info.memory_size + 
            (if (result.memory_changes.wasModified()) 
                result.memory_changes.getModificationSize() 
            else 0),
        
        // Snapshots and changes
        .stack_snapshot = stack_copy,
        .memory_snapshot = memory_copy,
        .storage_changes = try self.allocator.dupe(
            tracer.StorageChange,
            result.storage_changes
        ),
        .logs_emitted = try self.allocator.dupe(
            tracer.LogEntry,
            result.logs_emitted
        ),
        .error_info = result.error_info,
    };
}
```

### Step 1.7: Enhance VTable Implementation

The VTable needs updating to support control flow. Find the VTable implementation (around line 130) and modify:

```zig
// Update the on_post_step method to build transitions and check control
fn step_after_impl(ptr: *anyopaque, step_result: tracer.StepResult) void {
    const self: *MemoryTracer = @ptrCast(@alignCast(ptr));
    
    // Call optional after hook first
    if (self.on_after_step_hook) |hook| {
        hook(self, step_result) catch |err| {
            std.log.warn("on_after_step_hook error: {}", .{err});
        };
    }
    
    // Original behavior - build struct log
    self.on_post_step(step_result);
    
    // NEW: Build and store transition if we have pre-state
    if (self.current_step_info) |info| {
        const transition = self.build_transition(info, step_result) catch {
            std.log.warn("Failed to build transition", .{});
            return;
        };
        
        // Store transition
        self.transitions.append(transition) catch {};
        self.last_transition = transition;
        
        // Call transition callback if set
        if (self.on_step_transition) |callback| {
            const control = callback(self, transition) catch .abort;
            // NOTE: We can't actually control here yet - see Phase 3
            // This will be connected in interpreter integration
            _ = control;
        }
    }
}
```

## Phase 2: Updating Type Definitions

### Step 2.1: Extend TracerVTable

Open `src/evm/tracing/trace_types.zig` and find the `TracerVTable` struct (around line 412). We need to add control support:

```zig
pub const TracerVTable = struct {
    /// Called before each opcode execution
    step_before: *const fn (ptr: *anyopaque, step_info: StepInfo) void,
    /// Called after each opcode execution  
    step_after: *const fn (ptr: *anyopaque, step_result: StepResult) void,
    
    // ADD THIS NEW FIELD:
    /// Get control decision for current step (optional)
    get_step_control: ?*const fn (ptr: *anyopaque) StepControl = null,
    
    /// Called when execution completes
    finalize: *const fn (ptr: *anyopaque, final_result: FinalResult) void,
    /// Get the complete execution trace
    get_trace: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!ExecutionTrace,
    /// Clean up tracer resources
    deinit: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) void,
};
```

Now add the StepControl type if not already present (around line 40):

```zig
/// Control flow decision
pub const StepControl = enum {
    cont,    // Continue execution
    pause,   // Pause execution  
    abort,   // Abort execution
};
```

### Step 2.2: Update TracerHandle

In the same file, find `TracerHandle` (around line 426) and add a control method:

```zig
pub const TracerHandle = struct {
    ptr: *anyopaque,
    vtable: *const TracerVTable,
    
    // ... existing methods ...
    
    // ADD THIS METHOD:
    /// Get control decision (returns .cont if not supported)
    pub fn getStepControl(self: TracerHandle) StepControl {
        if (self.vtable.get_step_control) |get_control| {
            return get_control(self.ptr);
        }
        return .cont;  // Default to continue
    }
};
```

### Step 2.3: Back to MemoryTracer - Add Control Support

Go back to `src/evm/tracing/memory_tracer.zig` and add the control implementation.

First, add a field to track pending control decisions (around line 50):

```zig
    // ADD THIS FIELD:
    pending_control: StepControl = .cont,
```

Then add the control method implementation (around line 350):

```zig
/// Get current control decision
fn get_step_control_impl(ptr: *anyopaque) StepControl {
    const self: *MemoryTracer = @ptrCast(@alignCast(ptr));
    
    // Check step mode
    const control = switch (self.step_mode) {
        .passive => .cont,
        .single_step => .pause,
        .breakpoint => blk: {
            // Check if we're at a breakpoint
            if (self.last_transition) |trans| {
                if (self.breakpoints.contains(trans.pc)) {
                    break :blk .pause;
                }
            }
            break :blk .cont;
        },
    };
    
    // Reset pending control and return
    const result = if (self.pending_control != .cont) 
        self.pending_control 
    else 
        control;
        
    self.pending_control = .cont;  // Reset for next step
    return result;
}
```

Update the VTABLE constant (around line 52):

```zig
const VTABLE = tracer.TracerVTable{
    .step_before = step_before_impl,
    .step_after = step_after_impl,
    .get_step_control = get_step_control_impl,  // ADD THIS
    .finalize = finalize_impl,
    .get_trace = get_trace_impl,
    .deinit = deinit_impl,
};
```

## Phase 3: Interpreter Integration

This is the most complex part. We need to make the interpreter check for control decisions.

### Step 3.1: Understanding Current Interpreter Flow

Open `src/evm/evm/interpret.zig` and look at how tracing currently works (lines 96-150):

```zig
// Current flow in pre_step (line 44):
if (comptime build_options.enable_tracing) {
    // ... existing JSON tracer ...
    
    // Structured tracer (line 99)
    if (self.inproc_tracer) |tracer_handle| {
        // Builds StepInfo and calls step_before
    }
}

// And in post_step (line 154):
if (self.inproc_tracer) |tracer_handle| {
    // Builds StepResult and calls step_after
}
```

### Step 3.2: Add Control Check After Post-Step

Find the main interpreter loop in `interpret()` function. Look for the `.exec` case (around line 335):

```zig
.exec => {
    @branchHint(.likely);
    const analysis = frame.analysis;
    
    // Pre-step captures state
    pre_step(self, frame, instruction, &loop_iterations);
    
    // ... existing debug hooks check (lines 350-360) ...
    
    // Capture gas before execution
    const gas_before = frame.gas_remaining;
    
    // Execute the instruction
    const exec_inst = analysis.getInstructionParams(.exec, instruction.id);
    const exec_fun = exec_inst.exec_fn;
    const next_instruction = exec_inst.next_inst;
    
    try exec_fun(frame);  // <-- Actual execution
    
    // ADD THIS: Post-step and control check
    if (comptime build_options.enable_tracing) {
        post_step(self, frame, gas_before, null);
        
        // Check for control decision from tracer
        if (self.inproc_tracer) |tracer_handle| {
            const control = tracer_handle.getStepControl();
            switch (control) {
                .cont => {},  // Continue normally
                .pause => return ExecutionError.Error.DebugPaused,
                .abort => return ExecutionError.Error.DebugAbort,
            }
        }
    }
    
    instruction = next_instruction;
    continue :dispatch instruction.tag;
},
```

### Step 3.3: Add Same Pattern to Other Instruction Types

Apply the same control check pattern to:
- `.dynamic_gas` case (around line 391)
- `.word` case (around line 598)  
- `.pc` case (around line 663)

For each, add after the instruction execution:

```zig
// After instruction execution, before continue:
if (comptime build_options.enable_tracing) {
    post_step(self, frame, gas_before, null);
    
    if (self.inproc_tracer) |tracer_handle| {
        const control = tracer_handle.getStepControl();
        switch (control) {
            .cont => {},
            .pause => return ExecutionError.Error.DebugPaused,
            .abort => return ExecutionError.Error.DebugAbort,
        }
    }
}
```

### Step 3.4: Add Resume Support

The EVM needs a way to resume after pause. Open `src/evm/evm.zig` and add (around line 400):

```zig
/// Resume execution after a pause
/// Frame must be the same one that was paused
pub fn resume(self: *Evm, frame: *Frame) ExecutionError.Error!void {
    // Clear any pending pause state in tracer
    if (self.inproc_tracer) |tracer_handle| {
        // Tracer should continue from where it left off
        // The frame still has its instruction pointer
    }
    
    // Continue interpretation
    return self.interpret(frame);
}
```

## Phase 4: Message Hook Integration

### Step 4.1: Find CALL Implementation

Open `src/evm/execution/system.zig` and find `op_call` function (around line 831).

Look for where `CallParams` is created (around line 989):

```zig
const call_params = CallParams{ .call = .{
    .caller = frame.contract_address,
    .to = to_address,
    .value = value,
    .input = args,
    .gas = gas_limit,
} };
```

### Step 4.2: Add Message Hooks

Right after creating `call_params` and before the actual call:

```zig
// Create call parameters (existing code)
const call_params = CallParams{ .call = .{
    .caller = frame.contract_address,
    .to = to_address,
    .value = value,
    .input = args,
    .gas = gas_limit,
} };

// ADD THIS: Message before hook
if (comptime build_options.enable_tracing) {
    // Get EVM instance for tracer access
    const evm_ptr = @as(*Evm, @ptrCast(@alignCast(frame.host.ptr)));
    
    if (evm_ptr.inproc_tracer) |tracer_handle| {
        // Build message event
        const before_event = MessageEvent{
            .phase = .before,
            .params = call_params,
            .result = null,
            .depth = frame.depth,
            .gas_before = frame.gas_remaining,
            .gas_after = null,
        };
        
        // Call message hook if tracer supports it
        // (This requires extending TracerVTable - similar to step control)
        tracer_handle.onMessageEvent(before_event);
    }
}

// Existing call execution
const snapshot = frame.host.create_snapshot();
const call_result = host.call(call_params) catch {
    // ... error handling ...
};

// ADD THIS: Message after hook
if (comptime build_options.enable_tracing) {
    const evm_ptr = @as(*Evm, @ptrCast(@alignCast(frame.host.ptr)));
    
    if (evm_ptr.inproc_tracer) |tracer_handle| {
        const after_event = MessageEvent{
            .phase = .after,
            .params = call_params,
            .result = call_result,
            .depth = frame.depth,
            .gas_before = gas_before_call,
            .gas_after = frame.gas_remaining,
        };
        
        tracer_handle.onMessageEvent(after_event);
    }
}
```

### Step 4.3: Apply to Other Call Types

Apply the same pattern to:
- `op_callcode` (line ~974)
- `op_delegatecall` (line ~1093)
- `op_staticcall` (line ~1207)
- `op_create` (line ~534)
- `op_create2` (line ~678)

## Phase 5: Testing

### Step 5.1: Create Basic Test

Create a test file `test/evm/unified_tracer_test.zig`:

```zig
const std = @import("std");
const testing = std.testing;
const evm_module = @import("evm");
const MemoryTracer = evm_module.tracing.MemoryTracer;
const TracerConfig = evm_module.tracing.TracerConfig;

test "MemoryTracer: single stepping through instructions" {
    const allocator = testing.allocator;
    
    // Create tracer with stepping enabled
    var tracer = try MemoryTracer.init(allocator, TracerConfig{});
    defer tracer.deinit();
    
    // Track steps
    var step_count: u32 = 0;
    const StepRecorder = struct {
        count: *u32,
        
        fn on_transition(self: *MemoryTracer, trans: MemoryTracer.StepTransition) !MemoryTracer.StepControl {
            _ = self;
            _ = trans;
            const counter = @fieldParentPtr(@This(), "count", @field(@This(), "count"));
            counter.count.* += 1;
            return .cont;  // Continue for this test
        }
    };
    
    // Set callback
    tracer.on_step_transition = StepRecorder.on_transition;
    
    // Create simple bytecode: PUSH1 0x05, PUSH1 0x03, ADD
    const bytecode = [_]u8{ 0x60, 0x05, 0x60, 0x03, 0x01 };
    
    // ... setup EVM and frame (see existing tests for pattern) ...
    
    // Execute with tracer
    evm.set_tracer(tracer.handle());
    try evm.interpret(frame);
    
    // Verify we captured all steps
    try testing.expect(step_count >= 3); // At least PUSH, PUSH, ADD
    try testing.expect(tracer.transitions.items.len == step_count);
}

test "MemoryTracer: breakpoint functionality" {
    const allocator = testing.allocator;
    
    var tracer = try MemoryTracer.init(allocator, TracerConfig{});
    defer tracer.deinit();
    
    // Set breakpoint at PC 2 (second PUSH)
    try tracer.add_breakpoint(2);
    tracer.set_step_mode(.breakpoint);
    
    // Execute and expect pause
    // ... setup and run ...
    
    const result = evm.interpret(frame);
    try testing.expectEqual(ExecutionError.Error.DebugPaused, result);
    
    // Verify we stopped at the breakpoint
    const last_trans = tracer.last_transition.?;
    try testing.expectEqual(@as(usize, 2), last_trans.pc);
}

test "MemoryTracer: step_once functionality" {
    const allocator = testing.allocator;
    
    var tracer = try MemoryTracer.init(allocator, TracerConfig{});
    defer tracer.deinit();
    
    // ... setup EVM ...
    
    // Step through one instruction at a time
    var steps_taken: u32 = 0;
    while (steps_taken < 5) : (steps_taken += 1) {
        const trans = try tracer.step_once();
        if (trans) |t| {
            // Verify we have transition data
            try testing.expect(t.pc >= 0);
            try testing.expect(t.gas_cost > 0);
        } else {
            break; // Execution complete
        }
        
        // Resume for next step
        const result = evm.resume(frame);
        if (result != .DebugPaused) break;
    }
    
    try testing.expect(steps_taken > 0);
}
```

### Step 5.2: Run Tests

```bash
# Build with tracing enabled
zig build -Denable_tracing=true

# Run tests
zig build test -Denable_tracing=true

# Verify no memory leaks
zig build test -Denable_tracing=true --verbose
```

## Common Pitfalls and Solutions

### Pitfall 1: Forgetting Comptime Guards

**Problem**: Tracing code runs even when disabled.

**Solution**: Always wrap tracing code with:
```zig
if (comptime build_options.enable_tracing) {
    // Tracing code here
}
```

### Pitfall 2: Memory Leaks

**Problem**: Allocated memory not freed.

**Solution**: Always use defer immediately after allocation:
```zig
const data = try allocator.alloc(u8, size);
defer allocator.free(data);
```

### Pitfall 3: Null Pointer Access

**Problem**: Accessing optional without checking.

**Solution**: Always check optionals:
```zig
if (self.on_step_transition) |callback| {
    // Safe to use callback here
}
```

### Pitfall 4: Type Casting Errors

**Problem**: Incorrect pointer casts.

**Solution**: Use proper cast functions:
```zig
// Correct way to cast anyopaque
const self: *MemoryTracer = @ptrCast(@alignCast(ptr));
```

### Pitfall 5: Control Flow Not Working

**Problem**: Tracer returns pause but execution continues.

**Solution**: Ensure interpreter checks control:
1. Verify `getStepControl` is called
2. Check ExecutionError.Error has DebugPaused/DebugAbort
3. Ensure interpreter handles these errors

### Pitfall 6: Import Errors

**Problem**: Can't import modules.

**Solution**: Use module names from build.zig:
```zig
const evm = @import("evm");        // Not "../evm.zig"
const primitives = @import("primitives");
```

### Pitfall 7: Struct Initialization

**Problem**: Missing required fields.

**Solution**: Initialize all fields:
```zig
return MemoryTracer{
    .allocator = allocator,
    .config = config,
    // ... all fields must be listed
};
```

## Verification Checklist

Before considering the implementation complete:

- [ ] MemoryTracer compiles without errors
- [ ] All existing tests still pass
- [ ] New control methods work (step_once, breakpoints)
- [ ] Transitions are captured with complete state
- [ ] Memory is properly managed (no leaks)
- [ ] Control flow works (pause/resume)
- [ ] Message hooks fire for CALL/CREATE
- [ ] Backward compatibility maintained
- [ ] Documentation updated

## Quick Reference

### Key Files Modified

1. `src/evm/tracing/memory_tracer.zig` - Main implementation
2. `src/evm/tracing/trace_types.zig` - Type definitions
3. `src/evm/evm/interpret.zig` - Control flow integration
4. `src/evm/execution/system.zig` - Message hooks
5. `src/evm/evm.zig` - Resume support

### Key Types Added

- `StepTransition` - Complete state transition
- `MessageEvent` - CALL/CREATE events
- `StepControl` - Control flow enum
- Callback function types

### Key Methods Added

- `step_once()` - Single step execution
- `add_breakpoint()` - Set breakpoints
- `set_step_mode()` - Change execution mode
- `getStepControl()` - Get control decision

## Next Steps

After implementing:

1. Test thoroughly with simple bytecode
2. Test with complex contracts (loops, calls)
3. Integrate with devtool UI
4. Add performance benchmarks
5. Document API for users

## Getting Help

If stuck:

1. Check existing test files for patterns
2. Look at how current tracer/debug hooks work
3. Use `zig build -Denable-tracing=true test-memory-tracer` for detailed errors
4. Check Zig documentation for language questions (MCP zig-docs)
5. Refer to the prompt files in this directory for context

Remember: The goal is evolution, not revolution. Keep existing functionality working while adding new capabilities.