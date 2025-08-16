# Shadow Execution Integration Guide - Complete Implementation

## Executive Summary

This document provides a comprehensive guide for integrating shadow execution into the Guillotine EVM codebase. Shadow execution runs the Mini EVM (PC-based interpreter) alongside the main EVM (analysis-based interpreter) to validate correctness through differential testing. The implementation supports both per-call comparison (comparing final results) and per-step comparison (comparing state at each instruction), with zero overhead when disabled.

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Current State Analysis](#current-state-analysis)
3. [Integration Strategy](#integration-strategy)
4. [Implementation Details](#implementation-details)
5. [Tracer Integration](#tracer-integration)
6. [Testing and Validation](#testing-and-validation)
7. [Performance Considerations](#performance-considerations)
8. [Code Examples](#code-examples)

---

## Architecture Overview

### Key Components

1. **Main EVM** (`src/evm/evm.zig`, `src/evm/evm/interpret.zig`)
   - Analysis-based execution using instruction blocks
   - Optimized for performance with pre-computed jump destinations
   - Uses `Frame` for execution context

2. **Mini EVM** (`src/evm/evm/call_mini.zig`)
   - PC-based execution with lazy jump validation
   - Simple interpreter loop without optimization
   - Reference implementation for correctness validation

3. **Shadow Module** (`src/evm/shadow/shadow.zig`)
   - Comparison functions for call results and states
   - Mismatch tracking and reporting
   - Build-time conditional compilation

4. **Tracer Infrastructure** (`src/evm/tracing/`)
   - Step-by-step execution hooks
   - State capture at each instruction
   - Extensible tracer interface

### Execution Flow

```
Main EVM Execution
    ├── Pre-step (tracer hook)
    ├── Execute instruction
    ├── [SHADOW: Execute same in Mini EVM]
    ├── [SHADOW: Compare states]
    ├── Post-step (tracer hook)
    └── Continue or handle mismatch
```

---

## Current State Analysis

### What's Already Implemented

Based on the git status and diffs, we have:

1. **Build Configuration** (`build.zig`)
   ```zig
   const enable_shadow_compare = b.option(bool, "enable-shadow-compare", ...) orelse false;
   build_options.addOption(bool, "enable_shadow_compare", enable_shadow_compare);
   ```

2. **Shadow Module** (`src/evm/shadow/shadow.zig`)
   - `ShadowMode` enum: `off`, `per_call`, `per_step`
   - `ShadowMismatch` struct with memory management
   - `compare_call_results()` function

3. **EVM Integration** (`src/evm/evm.zig`)
   ```zig
   // Fields added to Evm struct
   shadow_mode: DebugShadow.ShadowMode = .off,
   shadow_cfg: DebugShadow.ShadowConfig = .{},
   last_shadow_mismatch: ?DebugShadow.ShadowMismatch = null,
   
   // API methods
   pub fn set_shadow_mode(self: *Evm, mode: DebugShadow.ShadowMode) void
   pub fn take_last_shadow_mismatch(self: *Evm) ?DebugShadow.ShadowMismatch
   pub fn is_shadow_enabled(self: *Evm) bool
   ```

4. **System Operations** (`src/evm/execution/system.zig`)
   - Per-call comparison injected in all 6 system ops (CALL, STATICCALL, DELEGATECALL, CALLCODE, CREATE, CREATE2)
   - Pattern: Execute main → Execute mini → Compare → Handle mismatch

### What Needs to Change

1. **Remove `execute_single_op.zig`** - Already deleted (duplicated logic)
2. **Integrate per-step comparison** into main execution loop
3. **Create shadow-aware tracer** for detailed comparison
4. **Fix test infrastructure** to use new approach

---

## Integration Strategy

### Design Principles

1. **Zero Overhead When Disabled**
   - Use `comptime` checks for build-time elimination
   - No allocations or comparisons when `enable_shadow_compare=false`

2. **Automatic Validation**
   - Once enabled, ALL execution gets shadow validation
   - No test changes required

3. **Fail-Fast in Debug**
   - Debug builds: Immediately error on mismatch
   - Release builds: Log and continue

4. **Reuse Existing Infrastructure**
   - Leverage tracer hooks for step comparison
   - Use existing Mini EVM for reference execution

---

## Implementation Details

### Step 1: Prepare Mini EVM for Step Execution

**File:** `src/evm/evm/execute_mini_step.zig`

Add a step-by-step execution mode for call_mini.zig:

```zig
/// Execute a single instruction in Mini EVM and return next PC
/// This is extracted from the main loop to support per-step shadow comparison
pub fn execute_mini_step(
    self: *Evm, 
    frame: *Frame, 
    pc: usize,
    code: []const u8
) struct { 
    next_pc: usize, 
    error: ?ExecutionError.Error,
    terminated: bool 
} {
    if (pc >= code.len) {
        return .{ .next_pc = pc, .error = ExecutionError.Error.OutOfOffset, .terminated = true };
    }
    
    const op = code[pc];
    const operation = self.table.get_operation(op);
    
    // Check if opcode is undefined
    if (operation.undefined) {
        return .{ .next_pc = pc, .error = ExecutionError.Error.InvalidOpcode, .terminated = true };
    }
    
    // Gas validation
    if (frame.gas_remaining < operation.constant_gas) {
        return .{ .next_pc = pc, .error = ExecutionError.Error.OutOfGas, .terminated = true };
    }
    frame.gas_remaining -= operation.constant_gas;
    
    // Stack validation
    if (frame.stack.size() < operation.min_stack) {
        return .{ .next_pc = pc, .error = ExecutionError.Error.StackUnderflow, .terminated = true };
    }
    if (frame.stack.size() > operation.max_stack) {
        return .{ .next_pc = pc, .error = ExecutionError.Error.StackOverflow, .terminated = true };
    }
    
    // Handle specific opcodes
    switch (op) {
        @intFromEnum(opcode_mod.Enum.STOP) => {
            return .{ .next_pc = pc, .error = ExecutionError.Error.STOP, .terminated = true };
        },
        @intFromEnum(opcode_mod.Enum.JUMP) => {
            const dest = frame.stack.pop() catch |err| {
                return .{ .next_pc = pc, .error = err, .terminated = true };
            };
            
            if (dest > code.len) {
                return .{ .next_pc = pc, .error = ExecutionError.Error.InvalidJump, .terminated = true };
            }
            
            const dest_usize = @as(usize, @intCast(dest));
            if (dest_usize >= code.len or code[dest_usize] != @intFromEnum(opcode_mod.Enum.JUMPDEST)) {
                return .{ .next_pc = pc, .error = ExecutionError.Error.InvalidJump, .terminated = true };
            }
            
            return .{ .next_pc = dest_usize, .error = null, .terminated = false };
        },
        // ... handle other control flow opcodes ...
        else => {
            // Handle PUSH opcodes
            if (opcode_mod.is_push(op)) {
                const push_size = opcode_mod.get_push_size(op);
                // ... push logic ...
                return .{ .next_pc = pc + 1 + push_size, .error = null, .terminated = false };
            }
            
            // Execute through jump table
            const context: *anyopaque = @ptrCast(frame);
            operation.execute(context) catch |err| {
                return .{ .next_pc = pc, .error = err, .terminated = true };
            };
            
            return .{ .next_pc = pc + 1, .error = null, .terminated = false };
        },
    }
}
```

### Step 2: Add Per-Step Shadow Comparison to Main Execution

**File:** `src/evm/evm/interpret.zig`

Add shadow comparison after instruction execution. This needs to be added in THREE places:
1. After `.exec` instruction execution (line ~323)
2. After `.dynamic_gas` instruction execution (line ~379)
3. After other instruction types that execute opcodes

```zig
// Add this helper function in a new file `src/evm/evm/shadow_compare_step.zig`
inline fn shadow_compare_step(
    self: *Evm,
    frame: *Frame,
    inst: *const Instruction,
    analysis: *const CodeAnalysis
) void {
    // Only compile this code if shadow comparison is enabled
    if (!comptime (@hasDecl(build_options, "enable_shadow_compare") and 
                   build_options.enable_shadow_compare)) return;
    
    // Only run if shadow mode is per_step
    if (self.shadow_mode != .per_step) return;
    
    // Get the PC for current instruction
    const base: [*]const @TypeOf(inst.*) = analysis.instructions.ptr;
    const idx = (@intFromPtr(inst) - @intFromPtr(base)) / @sizeOf(@TypeOf(inst.*));
    const pc_u16 = analysis.inst_to_pc[idx];
    if (pc_u16 == std.math.maxInt(u16)) return;
    const pc: usize = pc_u16;
    
    // Create a mini frame for comparison (share stack/memory with main frame)
    var mini_frame = Frame{
        .stack = frame.stack,  // Share the same stack
        .memory = frame.memory,  // Share the same memory
        .gas_remaining = frame.gas_remaining,
        .depth = frame.depth,
        .is_static = frame.is_static,
        .contract_address = frame.contract_address,
        .msg_sender = frame.msg_sender,
        .msg_value = frame.msg_value,
        .input_buffer = frame.input_buffer,
        .returndata = frame.returndata,
        .host = frame.host,
        .analysis = frame.analysis,
        .allocator = frame.allocator,
    };
    
    // Execute same instruction in mini EVM
    const result = execute_mini_step(self, &mini_frame, pc, analysis.code);
    
    // Compare gas consumption
    if (mini_frame.gas_remaining != frame.gas_remaining) {
        const mismatch = DebugShadow.ShadowMismatch.create(
            .per_step,
            pc,
            .gas_left,
            std.fmt.allocPrint(self.allocator, "{}", .{frame.gas_remaining}) catch "?",
            std.fmt.allocPrint(self.allocator, "{}", .{mini_frame.gas_remaining}) catch "?",
            self.allocator
        ) catch return;
        
        // Store mismatch
        if (self.last_shadow_mismatch) |old| {
            var mutable = old;
            mutable.deinit(self.allocator);
        }
        self.last_shadow_mismatch = mismatch;
        
        // In debug mode, fail immediately
        if (comptime builtin.mode == .Debug) {
            @panic("Shadow mismatch detected!");
        }
    }
    
    // Compare stack (already shared, so should match)
    // Compare memory (already shared, so should match)
    // The main difference would be in control flow and gas
}

// Then in the interpret function in interpret.zig, add after line 323 (after exec_fn):
try params.exec_fn(frame);

// ADD THIS LINE:
if (comptime build_options.enable_shadow_compare) {
    shadow_compare_step(self, frame, instruction, analysis);
}

// Similarly after line 379 (after dynamic_gas exec_fn):
try params.exec_fn(frame);

// ADD THIS LINE:
if (comptime build_options.enable_shadow_compare) {
    shadow_compare_step(self, frame, instruction, analysis);
}
```

### Step 3: Update Shadow Module for Step Comparison

**File:** `src/evm/shadow/shadow.zig`

Add step comparison function:

```zig
/// Compare execution state at instruction level
pub fn compare_step_state(
    main_frame: *const Frame,
    mini_frame: *const Frame,
    pc: usize,
    allocator: std.mem.Allocator,
) !?ShadowMismatch {
    // Gas comparison
    if (main_frame.gas_remaining != mini_frame.gas_remaining) {
        var main_buf: [32]u8 = undefined;
        var mini_buf: [32]u8 = undefined;
        const main_str = try std.fmt.bufPrint(&main_buf, "{}", .{main_frame.gas_remaining});
        const mini_str = try std.fmt.bufPrint(&mini_buf, "{}", .{mini_frame.gas_remaining});
        return try ShadowMismatch.create(.per_step, pc, .gas_left, main_str, mini_str, allocator);
    }
    
    // Stack size comparison
    if (main_frame.stack.size() != mini_frame.stack.size()) {
        var main_buf: [32]u8 = undefined;
        var mini_buf: [32]u8 = undefined;
        const main_str = try std.fmt.bufPrint(&main_buf, "size={}", .{main_frame.stack.size()});
        const mini_str = try std.fmt.bufPrint(&mini_buf, "size={}", .{mini_frame.stack.size()});
        return try ShadowMismatch.create(.per_step, pc, .stack, main_str, mini_str, allocator);
    }
    
    // Stack content comparison (top N elements)
    const stack_size = main_frame.stack.size();
    const compare_count = @min(16, stack_size); // Compare top 16 elements
    
    var i: usize = 0;
    while (i < compare_count) : (i += 1) {
        const main_val = main_frame.stack.data[stack_size - 1 - i];
        const mini_val = mini_frame.stack.data[stack_size - 1 - i];
        
        if (main_val != mini_val) {
            var main_buf: [80]u8 = undefined;
            var mini_buf: [80]u8 = undefined;
            const main_str = try std.fmt.bufPrint(&main_buf, "stack[{}]=0x{x}", .{i, main_val});
            const mini_str = try std.fmt.bufPrint(&mini_buf, "stack[{}]=0x{x}", .{i, mini_val});
            var mismatch = try ShadowMismatch.create(.per_step, pc, .stack, main_str, mini_str, allocator);
            mismatch.diff_index = i;
            return mismatch;
        }
    }
    
    // Memory size comparison
    if (main_frame.memory.size() != mini_frame.memory.size()) {
        var main_buf: [32]u8 = undefined;
        var mini_buf: [32]u8 = undefined;
        const main_str = try std.fmt.bufPrint(&main_buf, "size={}", .{main_frame.memory.size()});
        const mini_str = try std.fmt.bufPrint(&mini_buf, "size={}", .{mini_frame.memory.size()});
        return try ShadowMismatch.create(.per_step, pc, .memory, main_str, mini_str, allocator);
    }
    
    return null; // No mismatch
}
```

---

## Tracer Integration

### Creating a Shadow Comparison Tracer

**File:** `src/evm/tracing/shadow_tracer.zig` (new file)

```zig
const std = @import("std");
const tracer = @import("trace_types.zig");
const MemoryTracer = @import("memory_tracer.zig").MemoryTracer;
const DebugShadow = @import("../shadow/shadow.zig");
const Evm = @import("../evm.zig");

/// Shadow tracer that extends MemoryTracer with shadow comparison
pub const ShadowTracer = struct {
    /// Base memory tracer for state capture
    base: MemoryTracer,
    
    /// Reference to EVM for shadow execution
    evm: *Evm,
    
    /// Mini EVM state
    mini_frame: ?*Frame = null,
    mini_pc: usize = 0,
    
    /// Shadow mismatches detected
    mismatches: std.ArrayList(DebugShadow.ShadowMismatch),
    
    const Self = @This();
    
    /// VTable for tracer interface
    const VTABLE = tracer.TracerVTable{
        .on_step_before = on_step_before_impl,
        .on_step_after = on_step_after_impl,
        .on_step_transition = on_step_transition_impl,
        .on_message_before = MemoryTracer.onMessageBefore_impl,
        .on_message_after = MemoryTracer.onMessageAfter_impl,
        .on_message_transition = MemoryTracer.onMessageTransition_impl,
        .on_execution_end = on_execution_end_impl,
    };
    
    pub fn init(allocator: std.mem.Allocator, evm: *Evm) !Self {
        return Self{
            .base = try MemoryTracer.init(allocator),
            .evm = evm,
            .mismatches = std.ArrayList(DebugShadow.ShadowMismatch).init(allocator),
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.base.deinit();
        for (self.mismatches.items) |*mismatch| {
            mismatch.deinit(self.base.allocator);
        }
        self.mismatches.deinit();
    }
    
    pub fn handle(self: *Self) tracer.TracerHandle {
        return tracer.TracerHandle{
            .ptr = @ptrCast(self),
            .vtable = &VTABLE,
        };
    }
    
    fn on_step_before_impl(ptr: *anyopaque, step_info: tracer.StepInfo) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        
        // Let base tracer capture state
        MemoryTracer.on_step_before_impl(&self.base, step_info);
        
        // Initialize mini frame if needed
        if (self.mini_frame == null) {
            // Create mini frame that shares memory/stack with main frame
            // This needs access to the current frame which we get from step_info
        }
    }
    
    fn on_step_after_impl(ptr: *anyopaque, step_result: tracer.StepResult) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        
        // Let base tracer capture state
        MemoryTracer.on_step_after_impl(&self.base, step_result);
        
        // Execute same instruction in mini EVM
        if (self.mini_frame) |mini_frame| {
            const result = execute_mini_step(self.evm, mini_frame, self.mini_pc, 
                                            self.evm.current_code);
            
            // Compare states
            if (result.error == null) {
                // Compare gas, stack, memory
                const mismatch = DebugShadow.compare_step_state(
                    self.evm.current_frame,
                    mini_frame,
                    self.mini_pc,
                    self.base.allocator
                ) catch null;
                
                if (mismatch) |m| {
                    self.mismatches.append(m) catch {};
                    
                    // In debug mode, we could panic here
                    if (comptime builtin.mode == .Debug) {
                        std.log.err("Shadow mismatch at PC {}: {}", .{self.mini_pc, m.field});
                    }
                }
                
                self.mini_pc = result.next_pc;
            }
        }
    }
    
    fn on_step_transition_impl(ptr: *anyopaque, step_info: tracer.StepInfo, 
                               step_result: tracer.StepResult) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        MemoryTracer.on_step_transition_impl(&self.base, step_info, step_result);
    }
    
    fn on_execution_end_impl(ptr: *anyopaque, result: tracer.ExecutionResult) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        MemoryTracer.on_execution_end_impl(&self.base, result);
        
        // Report any mismatches
        if (self.mismatches.items.len > 0) {
            std.log.err("Shadow execution found {} mismatches", .{self.mismatches.items.len});
            for (self.mismatches.items) |mismatch| {
                std.log.err("  PC {}: {} - main: {s}, mini: {s}", .{
                    mismatch.op_pc,
                    mismatch.field,
                    mismatch.lhs_summary,
                    mismatch.rhs_summary,
                });
            }
        }
    }
};
```

---

## Testing and Validation

### Test Configuration

**File:** `test/shadow/integration_test.zig`

```zig
const std = @import("std");
const testing = std.testing;
const Evm = @import("evm").Evm;
const ShadowTracer = @import("evm").tracing.ShadowTracer;

test "shadow execution with tracer" {
    const allocator = testing.allocator;
    
    // Create EVM
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var evm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, 0, false, null);
    defer evm.deinit();
    
    // Enable shadow mode
    evm.set_shadow_mode(.per_step);
    
    // Create shadow tracer
    var shadow_tracer = try ShadowTracer.init(allocator, &evm);
    defer shadow_tracer.deinit();
    
    // Attach tracer
    evm.set_tracer(shadow_tracer.handle());
    
    // Execute code
    const code = [_]u8{
        0x60, 0x05, // PUSH1 5
        0x60, 0x0a, // PUSH1 10
        0x01,       // ADD
        0x00,       // STOP
    };
    
    const result = try evm.call(.{
        .call = .{
            .caller = Address.ZERO,
            .to = Address.ZERO,
            .value = 0,
            .input = &.{},
            .gas = 100000,
        },
    });
    
    // Check for mismatches
    try testing.expect(shadow_tracer.mismatches.items.len == 0);
}
```

### Running Tests

```bash
# Build with shadow comparison enabled
zig build -Denable-shadow-compare=true

# Run shadow tests
zig build test-shadow -Denable-shadow-compare=true

# Run all tests with shadow validation
zig build test -Denable-shadow-compare=true
```

---

## Performance Considerations

### Build-Time Optimization

```zig
// All shadow code is eliminated at compile time when disabled
if (!comptime (@hasDecl(build_options, "enable_shadow_compare") and 
               build_options.enable_shadow_compare)) return;
```

### Runtime Optimization

1. **Per-Call Mode**: ~2x overhead (executes everything twice)
2. **Per-Step Mode**: ~2.5x overhead (additional comparison per instruction)
3. **Disabled**: Zero overhead (code not compiled)

### Memory Management

```zig
// Proper cleanup pattern for mismatches
if (self.last_shadow_mismatch) |old| {
    var mutable = old;
    mutable.deinit(allocator);
}
self.last_shadow_mismatch = new_mismatch;
```

---

## Code Examples

### Example 1: Enabling Shadow Mode in a Test

```zig
test "my test with shadow validation" {
    var evm = try createEvm();
    defer evm.deinit();
    
    // Enable per-call shadow comparison
    evm.set_shadow_mode(.per_call);
    
    // Run test - shadow comparison happens automatically
    const result = try evm.call(params);
    
    // Check if there was a mismatch
    if (evm.take_last_shadow_mismatch()) |mismatch| {
        defer mismatch.deinit(allocator);
        std.log.err("Shadow mismatch: {}", .{mismatch.field});
        return error.ShadowMismatch;
    }
}
```

### Example 2: Using Shadow Tracer for Detailed Comparison

```zig
// Create and attach shadow tracer
var shadow_tracer = try ShadowTracer.init(allocator, &evm);
defer shadow_tracer.deinit();

evm.set_tracer(shadow_tracer.handle());
evm.set_shadow_mode(.per_step);

// Execute - tracer captures all state
const result = try evm.call(params);

// Get detailed trace with shadow comparison
const trace = try shadow_tracer.base.get_trace();
defer trace.deinit(allocator);

// Check mismatches
for (shadow_tracer.mismatches.items) |mismatch| {
    std.log.err("Mismatch at PC {}: {}", .{mismatch.op_pc, mismatch.field});
}
```

### Example 3: Conditional Shadow Mode Based on Build

```zig
// In your main test setup
if (comptime builtin.mode == .Debug) {
    // Always validate in debug builds
    evm.set_shadow_mode(.per_step);
} else if (std.os.getenv("SHADOW_VALIDATE")) |_| {
    // Opt-in for release builds via env var
    evm.set_shadow_mode(.per_call);
}
```

---

## Migration Path

### Phase 1: Clean Up Current Implementation
1. Remove duplicate execute_single_op.zig ✓
2. Keep per-call comparison in system.zig ✓
3. Update tests to not reference execute_single_op

### Phase 2: Add Per-Step Support
1. Implement execute_mini_step in call_mini.zig
2. Add shadow_compare_step to interpret.zig
3. Update shadow.zig with compare_step_state

### Phase 3: Tracer Integration
1. Create ShadowTracer
2. Add tracer tests
3. Document tracer usage

### Phase 4: Production Readiness
1. Performance benchmarks
2. Memory leak testing
3. Documentation updates

---

## Best Practices

### DO:
- ✅ Use `comptime` for build-time elimination
- ✅ Clean up mismatches with `defer`
- ✅ Check shadow_mode before comparison
- ✅ Use per-call for production, per-step for debugging
- ✅ Log mismatches in release, panic in debug

### DON'T:
- ❌ Forget to free mismatch memory
- ❌ Run per-step in production (too slow)
- ❌ Modify shared state between EVMs
- ❌ Ignore comparison failures
- ❌ Duplicate execution logic

---

## Troubleshooting

### Common Issues

1. **"Shadow mismatch: gas_left"**
   - Check gas calculation in both EVMs
   - Verify operation costs match

2. **"Shadow mismatch: stack"**
   - Check PUSH opcode handling
   - Verify stack operations

3. **Memory leaks**
   - Ensure all mismatches are freed
   - Use defer for cleanup

4. **Performance degradation**
   - Check if shadow mode is accidentally enabled
   - Use per-call instead of per-step

---

## Conclusion

This integration provides:
1. **Automatic validation** - Just set a flag
2. **Zero overhead** when disabled
3. **Detailed debugging** with tracers
4. **Production safety** - Fail fast in debug, log in release

The implementation leverages existing infrastructure (tracers, Mini EVM) while adding minimal complexity. The key insight is that shadow comparison should happen inline with main execution, not as a separate pass, ensuring consistency and efficiency.