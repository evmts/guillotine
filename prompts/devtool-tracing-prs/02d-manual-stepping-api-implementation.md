# Manual Stepping API Implementation Guide

## Overview

This document provides a comprehensive guide to implement a clean manual stepping API for the Guillotine EVM tracer system. The goal is to enable developers to execute EVM bytecode instruction-by-instruction with full control over execution flow, state inspection, and debugging capabilities.

## Background Context

### Current State Analysis

The existing codebase has partial stepping infrastructure:

1. **Memory Tracer** (`src/evm/tracing/memory_tracer.zig`):
   - Contains step modes: `passive`, `single_step`, `breakpoint` (lines 114-118)
   - Has incomplete `step_once()` method (line 675) marked as "Phase 3"
   - Implements control flow hooks but lacks clean API

2. **Interpreter** (`src/evm/evm/interpret.zig`):
   - Supports pause/resume via `DebugPaused` error (lines 334, 390)
   - Has tracer control flow integration (lines 329-337, 385-393)
   - Missing state preservation for resumption

3. **EVM Core** (`src/evm/evm.zig`):
   - Has `resume_execution` method (line 426) - currently unused for stepping
   - Missing execution state management

### What We're Building

A complete stepping API that provides:
- **Instruction-level stepping**: Execute one instruction at a time
- **Block-level stepping**: Execute entire analysis blocks (series of opcodes)
- **Breakpoint management**: Set/remove breakpoints at specific PCs
- **State inspection**: Full access to stack, memory, storage between steps
- **Execution control**: Pause, resume, step-over, run-to-completion
- **Rich debugging info**: Complete transition data for each step

## Architecture Overview

### New Components to Create

```
src/evm/tracing/
├── stepping_context.zig      # Main stepping API
├── execution_state.zig       # Execution state management
└── step_types.zig           # Types and enums for stepping
```

### Modified Components

```
src/evm/evm.zig              # Add execution state tracking
src/evm/evm/interpret.zig    # Enhanced pause/resume support
src/evm/tracing/memory_tracer.zig  # Complete stepping methods
test/evm/stepping_test.zig   # Comprehensive stepping tests
```

## Implementation Guide

### Step 1: Create Core Types and Enums

**File**: `src/evm/tracing/step_types.zig`

```zig
//! Core types and enums for the stepping API
//! 
//! This module defines all the data structures needed for manual EVM stepping,
//! including execution states, step results, and frame inspection data.

const std = @import("std");
const tracer = @import("trace_types.zig");
const ExecutionError = @import("../execution/execution_error.zig");

/// Represents the current state of EVM execution
pub const ExecutionState = enum {
    /// Ready to start new execution
    ready,
    /// Currently executing instructions
    running,
    /// Paused at instruction boundary (can resume)
    paused,
    /// Execution completed successfully
    completed,
    /// Execution failed with error
    failed,
    
    /// Check if execution can be resumed
    pub fn can_resume(self: ExecutionState) bool {
        return self == .paused;
    }
    
    /// Check if execution is active (running or paused)
    pub fn is_active(self: ExecutionState) bool {
        return self == .running or self == .paused;
    }
};

/// Result of a stepping operation
pub const StepResult = struct {
    /// Current execution status
    status: StepStatus,
    /// Transition data from the step (if any)
    transition: ?StepTransition = null,
    /// Current frame state snapshot
    frame_state: FrameState,
    /// Error information (if status is .failed)
    error_info: ?ExecutionError.Error = null,
    /// Analysis block information (for block stepping)
    block_info: ?BlockInfo = null,
};

/// Status after a stepping operation
pub const StepStatus = enum {
    /// Paused at instruction boundary
    paused,
    /// Execution completed successfully  
    completed,
    /// Execution failed with error
    failed,
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
    address: tracer.Address,

    // Post-execution state
    gas_after: u64,
    gas_cost: u64,
    stack_size_after: usize,
    memory_size_after: usize,

    // State changes (optional detailed tracking)
    stack_snapshot: ?[]const u256,
    memory_snapshot: ?[]const u8,
    storage_changes: []const tracer.StorageChange,
    logs_emitted: []const tracer.LogEntry,
    error_info: ?tracer.ExecutionErrorInfo,
    
    /// Get the net stack change from this instruction
    pub fn get_stack_delta(self: StepTransition) i32 {
        return @as(i32, @intCast(self.stack_size_after)) - @as(i32, @intCast(self.stack_size_before));
    }
    
    /// Check if this instruction modified memory
    pub fn modified_memory(self: StepTransition) bool {
        return self.memory_size_after != self.memory_size_before;
    }
};

/// Current frame state for inspection
pub const FrameState = struct {
    stack_size: usize,
    memory_size: usize, 
    gas_remaining: u64,
    depth: u16,
    contract_address: tracer.Address,
    caller: tracer.Address,
    is_static: bool,
};

/// Information about an analysis block
pub const BlockInfo = struct {
    /// Starting PC of the block
    start_pc: usize,
    /// Ending PC of the block  
    end_pc: usize,
    /// Number of instructions in the block
    instruction_count: usize,
    /// Total gas cost for the block
    total_gas_cost: u64,
    /// Stack requirements for the block
    stack_requirements: u16,
    /// Maximum stack growth in the block
    stack_max_growth: u16,
};

/// Stepping mode configuration
pub const SteppingMode = enum {
    /// Execute one instruction at a time
    single_instruction,
    /// Execute one analysis block at a time
    single_block,
    /// Run until breakpoint
    breakpoint,
    /// Run to completion
    continuous,
};

/// Frame inspection data for debugging
pub const FrameInspection = struct {
    /// Current stack data (read-only view)
    stack_data: []const u256,
    /// Current memory data (read-only view) 
    memory_data: []const u8,
    /// Gas remaining
    gas_remaining: u64,
    /// Call depth
    depth: u16,
    /// Contract being executed
    contract_address: tracer.Address,
    /// Caller address
    caller: tracer.Address,
    /// Whether this is a static call
    is_static: bool,
    
    /// Get value at top of stack (most recent push)
    pub fn stack_top(self: FrameInspection) ?u256 {
        if (self.stack_data.len == 0) return null;
        return self.stack_data[self.stack_data.len - 1];
    }
    
    /// Get stack value at index from top (0 = top, 1 = second from top, etc.)
    pub fn stack_peek(self: FrameInspection, index: usize) ?u256 {
        if (index >= self.stack_data.len) return null;
        return self.stack_data[self.stack_data.len - 1 - index];
    }
    
    /// Read memory at offset (returns null if out of bounds)
    pub fn read_memory(self: FrameInspection, offset: usize, length: usize) ?[]const u8 {
        if (offset + length > self.memory_data.len) return null;
        return self.memory_data[offset..offset + length];
    }
};
```

### Step 2: Create Execution State Management

**File**: `src/evm/tracing/execution_state.zig`

```zig
//! Execution state management for resumable EVM execution
//!
//! This module handles saving and restoring execution state to enable
//! pausing and resuming EVM execution at instruction boundaries.

const std = @import("std");
const Frame = @import("../frame.zig").Frame;
const step_types = @import("step_types.zig");

/// Manages execution state for pause/resume functionality
pub const ExecutionStateManager = struct {
    /// Current execution state
    state: step_types.ExecutionState,
    /// Frame being executed (when paused)
    paused_frame: ?*Frame,
    /// Instruction index where we paused
    paused_instruction_index: u16,
    /// PC where we paused (for verification)
    paused_pc: usize,
    
    pub fn init() ExecutionStateManager {
        return ExecutionStateManager{
            .state = .ready,
            .paused_frame = null,
            .paused_instruction_index = 0,
            .paused_pc = 0,
        };
    }
    
    /// Mark execution as started
    pub fn start_execution(self: *ExecutionStateManager) void {
        self.state = .running;
        self.paused_frame = null;
        self.paused_instruction_index = 0;
        self.paused_pc = 0;
    }
    
    /// Save state when pausing execution
    pub fn pause_execution(self: *ExecutionStateManager, frame: *Frame, instruction_index: u16, pc: usize) void {
        self.state = .paused;
        self.paused_frame = frame;
        self.paused_instruction_index = instruction_index;
        self.paused_pc = pc;
    }
    
    /// Check if we can resume execution with the given frame
    pub fn can_resume_with_frame(self: *ExecutionStateManager, frame: *Frame) bool {
        return self.state == .paused and self.paused_frame == frame;
    }
    
    /// Get the instruction index to resume from
    pub fn get_resume_index(self: *ExecutionStateManager) u16 {
        std.debug.assert(self.state == .paused);
        return self.paused_instruction_index;
    }
    
    /// Mark execution as completed
    pub fn complete_execution(self: *ExecutionStateManager) void {
        self.state = .completed;
        self.paused_frame = null;
        self.paused_instruction_index = 0;
        self.paused_pc = 0;
    }
    
    /// Mark execution as failed
    pub fn fail_execution(self: *ExecutionStateManager) void {
        self.state = .failed;
        self.paused_frame = null;
        self.paused_instruction_index = 0;
        self.paused_pc = 0;
    }
    
    /// Reset to ready state
    pub fn reset(self: *ExecutionStateManager) void {
        self.state = .ready;
        self.paused_frame = null;
        self.paused_instruction_index = 0;
        self.paused_pc = 0;
    }
    
    /// Get current state
    pub fn get_state(self: *ExecutionStateManager) step_types.ExecutionState {
        return self.state;
    }
};
```

### Step 3: Enhance the EVM Core with State Management

**Modifications to**: `src/evm/evm.zig`

Add these fields to the `Evm` struct:

```zig
// Add after existing fields in Evm struct (around line 50)

// === Execution State Management ===
execution_state_manager: ExecutionStateManager,
```

Add these imports at the top:

```zig
const ExecutionStateManager = @import("tracing/execution_state.zig").ExecutionStateManager;
const step_types = @import("tracing/step_types.zig");
```

Modify the `init` method to initialize the state manager:

```zig
// In the init method, add this line after other initializations:
.execution_state_manager = ExecutionStateManager.init(),
```

Add these new methods to the `Evm` struct:

```zig
/// Get current execution state
pub fn get_execution_state(self: *Evm) step_types.ExecutionState {
    return self.execution_state_manager.get_state();
}

/// Reset execution state to ready
pub fn reset_execution_state(self: *Evm) void {
    self.execution_state_manager.reset();
}

/// Check if execution can be resumed with the given frame
pub fn can_resume_execution(self: *Evm, frame: *Frame) bool {
    return self.execution_state_manager.can_resume_with_frame(frame);
}
```

### Step 4: Enhance the Interpreter for Resumable Execution

**Modifications to**: `src/evm/evm/interpret.zig`

Add these imports at the top:

```zig
const step_types = @import("../tracing/step_types.zig");
```

Modify the `interpret` function signature and implementation:

```zig
/// Enhanced interpret function with resumable execution support
pub fn interpret(self: *Evm, frame: *Frame) ExecutionError.Error!void {
    {
        // Existing thread safety check
        self.require_one_thread();
        std.debug.assert(frame.analysis.instructions.len >= 2);
    }

    // Check if we're resuming from a paused state
    var i: u16 = if (self.execution_state_manager.can_resume_with_frame(frame))
        self.execution_state_manager.get_resume_index()
    else
        0;

    // Mark execution as started (unless resuming)
    if (self.execution_state_manager.get_state() != .paused) {
        self.execution_state_manager.start_execution();
    }

    var loop_iterations: usize = 0;
    const analysis = frame.analysis;
    const instructions = analysis.instructions;
    var instruction = &instructions[i];

    dispatch: switch (instruction.tag) {
        // ... existing switch cases remain the same ...
        
        // Modify the control flow checks in .exec, .dynamic_gas, and .word cases:
        
        .exec => {
            @branchHint(.likely);
            check_loop_iterations(&loop_iterations);

            // ... existing pre-step tracing code ...

            const params = analysis.getInstructionParams(.exec, instruction.id);

            // Set to next instruction right away
            i += 1;
            const next_instruction = &instructions[i];
            instruction = next_instruction;

            try params.exec_fn(frame);

            // Enhanced post-step tracing with pause support
            if (comptime build_options.enable_tracing) {
                post_step(self, frame, gas_before, &pre_state);
                
                // Check for control decision from tracer
                if (self.inproc_tracer) |tracer_handle| {
                    const control = tracer_handle.get_step_control();
                    switch (control) {
                        .cont => {},  // Continue normally
                        .pause => {
                            // Save state for resumption
                            const current_pc = if (i < analysis.inst_to_pc.len) 
                                analysis.inst_to_pc[i] 
                            else 
                                analysis.code_len;
                            self.execution_state_manager.pause_execution(frame, i, current_pc);
                            return ExecutionError.Error.DebugPaused;
                        },
                        .abort => {
                            self.execution_state_manager.fail_execution();
                            return ExecutionError.Error.DebugAbort;
                        },
                    }
                }
            }

            continue :dispatch next_instruction.tag;
        },
        
        // Apply similar changes to .dynamic_gas, .word, and .pc cases...
        // (Replace the existing control flow checks with the enhanced version above)
    }
    
    // On successful completion
    self.execution_state_manager.complete_execution();
}
```

### Step 5: Complete the Memory Tracer Stepping Methods

**Modifications to**: `src/evm/tracing/memory_tracer.zig`

Add these imports:

```zig
const step_types = @import("step_types.zig");
```

Replace the incomplete `step_once` method and add new methods:

```zig
/// Execute one instruction step (replaces incomplete step_once)
/// This requires the EVM and frame to be provided for actual execution
pub fn execute_single_step(self: *MemoryTracer, evm: *anyopaque, frame: *anyopaque) !?step_types.StepTransition {
    // Cast back to proper types - this is safe because we control the calling context
    const evm_ptr: *@import("../evm.zig") = @ptrCast(@alignCast(evm));
    const frame_ptr: *@import("../frame.zig").Frame = @ptrCast(@alignCast(frame));
    
    // Set single-step mode
    self.set_step_mode(.single_step);
    
    // Execute until pause
    const result = evm_ptr.interpret(frame_ptr);
    
    return switch (result) {
        ExecutionError.Error.DebugPaused => self.last_transition,
        else => |err| return err,
    };
}

/// Execute until the next analysis block boundary
pub fn execute_single_block(self: *MemoryTracer, evm: *anyopaque, frame: *anyopaque) !?step_types.StepTransition {
    const evm_ptr: *@import("../evm.zig") = @ptrCast(@alignCast(evm));
    const frame_ptr: *@import("../frame.zig").Frame = @ptrCast(@alignCast(frame));
    
    // Set block-step mode (custom mode for block stepping)
    self.set_step_mode(.block_step);
    
    const result = evm_ptr.interpret(frame_ptr);
    
    return switch (result) {
        ExecutionError.Error.DebugPaused => self.last_transition,
        else => |err| return err,
    };
}

/// Continue execution until breakpoint or completion
pub fn execute_until_breakpoint(self: *MemoryTracer, evm: *anyopaque, frame: *anyopaque) !?step_types.StepTransition {
    const evm_ptr: *@import("../evm.zig") = @ptrCast(@alignCast(evm));
    const frame_ptr: *@import("../frame.zig").Frame = @ptrCast(@alignCast(frame));
    
    self.set_step_mode(.breakpoint);
    
    const result = evm_ptr.interpret(frame_ptr);
    
    return switch (result) {
        ExecutionError.Error.DebugPaused => self.last_transition,
        ExecutionError.Error.STOP => self.last_transition,
        else => |err| return err,
    };
}
```

Update the step mode enum to include block stepping:

```zig
// Update the step_mode enum (around line 114)
step_mode: enum {
    passive, // Normal tracing (default)
    single_step, // Pause after each instruction
    block_step, // Pause after each analysis block
    breakpoint, // Pause at specific PCs
} = .passive,
```

Update the `get_step_control_impl` method to handle block stepping:

```zig
/// Get current control decision (enhanced for block stepping)
fn get_step_control_impl(ptr: *anyopaque) tracer.StepControl {
    const self: *MemoryTracer = @ptrCast(@alignCast(ptr));

    // Check step mode
    const control = switch (self.step_mode) {
        .passive => tracer.StepControl.cont,
        .single_step => tracer.StepControl.pause,
        .block_step => blk: {
            // For block stepping, we need to check if we're at a block boundary
            // This requires cooperation with the analysis system
            if (self.last_transition) |trans| {
                // Check if the next instruction starts a new block
                // This is a simplified check - in practice you'd check the analysis
                if (self.is_block_boundary(trans.pc)) {
                    break :blk tracer.StepControl.pause;
                }
            }
            break :blk tracer.StepControl.cont;
        },
        .breakpoint => blk: {
            // Check if we're at a breakpoint
            if (self.last_transition) |trans| {
                if (self.breakpoints.contains(trans.pc)) {
                    break :blk tracer.StepControl.pause;
                }
            }
            break :blk tracer.StepControl.cont;
        },
    };

    // Reset pending control and return
    const result = if (self.pending_control != tracer.StepControl.cont)
        self.pending_control
    else
        control;

    self.pending_control = tracer.StepControl.cont; // Reset for next step
    return result;
}

/// Check if the given PC is at a block boundary
/// This is a helper method for block stepping
fn is_block_boundary(self: *MemoryTracer, pc: usize) bool {
    // This would need to be implemented based on the analysis system
    // For now, return false - this needs integration with the code analysis
    _ = self;
    _ = pc;
    return false; // TODO: Implement based on analysis block boundaries
}
```

### Step 6: Create the Main Stepping Context API

**File**: `src/evm/tracing/stepping_context.zig`

```zig
//! High-level stepping API for EVM execution
//!
//! This module provides a clean, safe API for manual stepping through EVM execution.
//! It handles all the low-level details of tracer management, state preservation,
//! and execution control.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Evm = @import("../evm.zig");
const Frame = @import("../frame.zig").Frame;
const MemoryTracer = @import("memory_tracer.zig").MemoryTracer;
const tracer = @import("trace_types.zig");
const step_types = @import("step_types.zig");
const ExecutionError = @import("../execution/execution_error.zig");

/// High-level stepping context for EVM execution debugging
pub const SteppingContext = struct {
    evm: *Evm,
    frame: *Frame,
    tracer: MemoryTracer,
    allocator: Allocator,
    current_mode: step_types.SteppingMode,
    
    /// Initialize a new stepping context
    pub fn init(evm: *Evm, frame: *Frame, allocator: Allocator) !SteppingContext {
        // Create tracer with reasonable defaults for debugging
        var memory_tracer = try MemoryTracer.init(allocator, tracer.TracerConfig{
            .stack_max_items = 1024,
            .memory_max_bytes = 1024 * 1024, // 1MB memory snapshots
        });
        
        // Set up for single instruction stepping by default
        memory_tracer.set_step_mode(.single_step);
        
        // Install the tracer in the EVM
        evm.set_tracer(memory_tracer.handle());
        
        return SteppingContext{
            .evm = evm,
            .frame = frame,
            .tracer = memory_tracer,
            .allocator = allocator,
            .current_mode = .single_instruction,
        };
    }
    
    /// Clean up resources
    pub fn deinit(self: *SteppingContext) void {
        // Remove tracer from EVM
        self.evm.set_tracer(null);
        
        // Clean up tracer
        self.tracer.deinit();
    }
    
    /// Execute a single instruction step
    pub fn step_instruction(self: *SteppingContext) !step_types.StepResult {
        self.current_mode = .single_instruction;
        self.tracer.set_step_mode(.single_step);
        
        return self.execute_step();
    }
    
    /// Execute a single analysis block step
    pub fn step_block(self: *SteppingContext) !step_types.StepResult {
        self.current_mode = .single_block;
        self.tracer.set_step_mode(.block_step);
        
        return self.execute_step();
    }
    
    /// Continue execution until next breakpoint
    pub fn continue_to_breakpoint(self: *SteppingContext) !step_types.StepResult {
        self.current_mode = .breakpoint;
        self.tracer.set_step_mode(.breakpoint);
        
        return self.execute_step();
    }
    
    /// Run execution to completion without further pausing
    pub fn run_to_completion(self: *SteppingContext) !step_types.StepResult {
        self.current_mode = .continuous;
        self.tracer.set_step_mode(.passive);
        
        return self.execute_step();
    }
    
    /// Set a breakpoint at the specified PC
    pub fn set_breakpoint(self: *SteppingContext, pc: usize) !void {
        try self.tracer.add_breakpoint(pc);
    }
    
    /// Remove a breakpoint at the specified PC
    pub fn remove_breakpoint(self: *SteppingContext, pc: usize) bool {
        return self.tracer.remove_breakpoint(pc);
    }
    
    /// Clear all breakpoints
    pub fn clear_breakpoints(self: *SteppingContext) void {
        self.tracer.clear_breakpoints();
    }
    
    /// Execute until a specific condition is met
    pub fn step_until(self: *SteppingContext, condition: *const fn (step_types.StepTransition) bool) !step_types.StepResult {
        while (true) {
            const result = try self.step_instruction();
            
            switch (result.status) {
                .paused => {
                    if (result.transition) |trans| {
                        if (condition(trans)) {
                            return result;
                        }
                    }
                    // Continue stepping
                    continue;
                },
                .completed, .failed => {
                    return result;
                },
            }
        }
    }
    
    /// Get current frame state for inspection
    pub fn inspect_frame(self: *SteppingContext) step_types.FrameInspection {
        const stack_size = self.frame.stack.size();
        const memory_size = self.frame.memory.size();
        
        return step_types.FrameInspection{
            .stack_data = if (stack_size > 0) self.frame.stack.data[0..stack_size] else &.{},
            .memory_data = if (memory_size > 0) self.frame.memory.data[0..memory_size] else &.{},
            .gas_remaining = self.frame.gas_remaining,
            .depth = self.frame.depth,
            .contract_address = self.frame.contract_address,
            .caller = self.frame.caller,
            .is_static = self.frame.is_static,
        };
    }
    
    /// Get the complete execution trace collected so far
    pub fn get_trace(self: *SteppingContext) !tracer.ExecutionTrace {
        return self.tracer.get_trace();
    }
    
    /// Get current execution state
    pub fn get_execution_state(self: *SteppingContext) step_types.ExecutionState {
        return self.evm.get_execution_state();
    }
    
    /// Modify the top stack value (for debugging purposes)
    /// WARNING: This modifies execution state and should only be used for debugging
    pub fn modify_stack_top(self: *SteppingContext, value: u256) !void {
        if (self.frame.stack.size() == 0) {
            return error.StackEmpty;
        }
        const stack_size = self.frame.stack.size();
        self.frame.stack.data[stack_size - 1] = value;
    }
    
    /// Modify stack value at index from top (0 = top, 1 = second from top, etc.)
    /// WARNING: This modifies execution state and should only be used for debugging
    pub fn modify_stack_at(self: *SteppingContext, index: usize, value: u256) !void {
        const stack_size = self.frame.stack.size();
        if (index >= stack_size) {
            return error.StackIndexOutOfBounds;
        }
        self.frame.stack.data[stack_size - 1 - index] = value;
    }
    
    /// Reset execution state to ready (for restarting execution)
    pub fn reset(self: *SteppingContext) void {
        self.evm.reset_execution_state();
        self.tracer.reset();
    }
    
    // === Private Implementation ===
    
    /// Core execution step implementation
    fn execute_step(self: *SteppingContext) !step_types.StepResult {
        const result = self.evm.interpret(self.frame);
        
        // Capture current frame state
        const frame_state = step_types.FrameState{
            .stack_size = self.frame.stack.size(),
            .memory_size = self.frame.memory.size(),
            .gas_remaining = self.frame.gas_remaining,
            .depth = self.frame.depth,
            .contract_address = self.frame.contract_address,
            .caller = self.frame.caller,
            .is_static = self.frame.is_static,
        };
        
        return switch (result) {
            ExecutionError.Error.DebugPaused => step_types.StepResult{
                .status = .paused,
                .transition = self.convert_transition(self.tracer.last_transition),
                .frame_state = frame_state,
            },
            ExecutionError.Error.STOP => step_types.StepResult{
                .status = .completed,
                .transition = self.convert_transition(self.tracer.last_transition),
                .frame_state = frame_state,
            },
            else => |err| step_types.StepResult{
                .status = .failed,
                .transition = self.convert_transition(self.tracer.last_transition),
                .frame_state = frame_state,
                .error_info = err,
            },
        };
    }
    
    /// Convert internal tracer transition to public API type
    fn convert_transition(self: *SteppingContext, transition: ?MemoryTracer.StepTransition) ?step_types.StepTransition {
        const trans = transition orelse return null;
        
        return step_types.StepTransition{
            .pc = trans.pc,
            .opcode = trans.opcode,
            .op_name = trans.op_name,
            .gas_before = trans.gas_before,
            .stack_size_before = trans.stack_size_before,
            .memory_size_before = trans.memory_size_before,
            .depth = trans.depth,
            .address = trans.address,
            .gas_after = trans.gas_after,
            .gas_cost = trans.gas_cost,
            .stack_size_after = trans.stack_size_after,
            .memory_size_after = trans.memory_size_after,
            .stack_snapshot = trans.stack_snapshot,
            .memory_snapshot = trans.memory_snapshot,
            .storage_changes = trans.storage_changes,
            .logs_emitted = trans.logs_emitted,
            .error_info = trans.error_info,
        };
    }
};

/// Utility functions for common stepping patterns
pub const SteppingUtils = struct {
    /// Create a condition function that stops at a specific opcode
    pub fn stop_at_opcode(target_opcode: u8) *const fn (step_types.StepTransition) bool {
        const ConditionImpl = struct {
            fn check(transition: step_types.StepTransition) bool {
                return transition.opcode == target_opcode;
            }
        };
        return ConditionImpl.check;
    }
    
    /// Create a condition function that stops when gas falls below threshold
    pub fn stop_at_gas_threshold(threshold: u64) *const fn (step_types.StepTransition) bool {
        const ConditionImpl = struct {
            fn check(transition: step_types.StepTransition) bool {
                return transition.gas_after < threshold;
            }
        };
        return ConditionImpl.check;
    }
    
    /// Create a condition function that stops when stack size reaches target
    pub fn stop_at_stack_size(target_size: usize) *const fn (step_types.StepTransition) bool {
        const ConditionImpl = struct {
            fn check(transition: step_types.StepTransition) bool {
                return transition.stack_size_after == target_size;
            }
        };
        return ConditionImpl.check;
    }
};
```

### Step 7: Understanding Block-Level Stepping

**Analysis Block Concept**

In the Guillotine EVM, bytecode is pre-analyzed and converted into "instruction blocks" for performance. Each block represents a sequence of opcodes that can be executed together with pre-calculated gas costs and stack requirements.

**Block Stepping Implementation**

To implement block stepping, we need to:

1. **Identify Block Boundaries**: Each block ends with control flow (jumps, calls, returns) or the next instruction starts a new block.

2. **Track Block Information**: Capture metadata about each block (start/end PC, instruction count, gas cost).

3. **Enhanced Block Detection**: Modify the tracer to recognize when we've reached the end of a block.

**Implementation in memory_tracer.zig**:

```zig
/// Enhanced block boundary detection for block stepping
fn is_block_boundary(self: *MemoryTracer, pc: usize) bool {
    // Access the analysis from the current execution context
    // This requires coordination with the frame/analysis system
    
    // For now, implement a simple heuristic:
    // - Control flow instructions end blocks (JUMP, JUMPI, CALL, RETURN, etc.)
    // - Block starts are marked in the analysis
    
    if (self.last_transition) |trans| {
        // Check if the current instruction is a control flow instruction
        const opcode = trans.opcode;
        const is_control_flow = switch (opcode) {
            0x56, 0x57 => true, // JUMP, JUMPI
            0xf0, 0xf1, 0xf2, 0xf4 => true, // CREATE, CALL, CALLCODE, DELEGATECALL
            0xfa, 0xfd => true, // STATICCALL, REVERT
            0xf3, 0xff => true, // RETURN, SELFDESTRUCT
            0x00 => true, // STOP
            else => false,
        };
        
        if (is_control_flow) {
            return true;
        }
        
        // TODO: Integrate with analysis system to check if PC starts a new block
        // This would require access to the analysis.pc_to_block_start mapping
    }
    
    return false;
}

/// Get information about the current analysis block
pub fn get_current_block_info(self: *MemoryTracer) ?step_types.BlockInfo {
    // This requires integration with the analysis system
    // For now, return null - this needs access to the Frame/Analysis
    
    // TODO: Implement by accessing frame.analysis and using:
    // - analysis.pc_to_block_start to find block boundaries
    // - analysis.getInstructionParams to get gas costs
    // - instruction analysis to count instructions in block
    
    return null;
}
```

### Step 8: Comprehensive Testing Strategy

**File**: `test/evm/stepping_test.zig`

```zig
//! Comprehensive tests for the manual stepping API
//!
//! This test suite covers all aspects of the stepping API including:
//! - Single instruction stepping
//! - Block-level stepping  
//! - Breakpoint management
//! - State inspection and modification
//! - Error handling and edge cases
//! - Realistic debugging scenarios

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

// EVM imports
const Evm = @import("evm").Evm;
const Frame = @import("evm").Frame;
const Analysis = @import("evm").CodeAnalysis;
const MemoryDatabase = @import("evm").MemoryDatabase;
const Host = @import("evm").Host;
const ExecutionError = @import("evm").ExecutionError;

// Stepping API imports
const SteppingContext = @import("evm").SteppingContext;
const step_types = @import("evm").step_types;
const SteppingUtils = @import("evm").SteppingUtils;

// Test utilities
const primitives = @import("primitives");
const OpcodeMetadata = @import("evm").OpcodeMetadata;

/// Test single instruction stepping with simple arithmetic
test "stepping: single instruction stepping with ADD operation" {
    const allocator = testing.allocator;
    
    // Bytecode: PUSH1 5, PUSH1 10, ADD, STOP
    const code = &[_]u8{ 0x60, 0x05, 0x60, 0x0a, 0x01, 0x00 };
    
    var evm_setup = try setup_evm(allocator, code);
    defer evm_setup.deinit();
    
    var stepper = try SteppingContext.init(evm_setup.evm, evm_setup.frame, allocator);
    defer stepper.deinit();
    
    // Step 1: PUSH1 5
    {
        const result = try stepper.step_instruction();
        try testing.expect(result.status == .paused);
        try testing.expect(result.transition != null);
        
        const trans = result.transition.?;
        try testing.expectEqual(@as(usize, 0), trans.pc);
        try testing.expectEqual(@as(u8, 0x60), trans.opcode);
        try testing.expectEqual(@as(usize, 1), trans.stack_size_after);
        
        // Inspect frame state
        const inspection = stepper.inspect_frame();
        try testing.expectEqual(@as(usize, 1), inspection.stack_data.len);
        try testing.expectEqual(@as(u256, 5), inspection.stack_top().?);
    }
    
    // Step 2: PUSH1 10
    {
        const result = try stepper.step_instruction();
        try testing.expect(result.status == .paused);
        
        const inspection = stepper.inspect_frame();
        try testing.expectEqual(@as(usize, 2), inspection.stack_data.len);
        try testing.expectEqual(@as(u256, 10), inspection.stack_top().?);
        try testing.expectEqual(@as(u256, 5), inspection.stack_peek(1).?);
    }
    
    // Step 3: ADD
    {
        const result = try stepper.step_instruction();
        try testing.expect(result.status == .paused);
        
        const trans = result.transition.?;
        try testing.expectEqual(@as(u8, 0x01), trans.opcode); // ADD
        try testing.expectEqual(@as(i32, -1), trans.get_stack_delta()); // 2 pops, 1 push = -1
        
        const inspection = stepper.inspect_frame();
        try testing.expectEqual(@as(usize, 1), inspection.stack_data.len);
        try testing.expectEqual(@as(u256, 15), inspection.stack_top().?); // 5 + 10 = 15
    }
    
    // Step 4: STOP
    {
        const result = try stepper.step_instruction();
        try testing.expect(result.status == .completed);
        
        const trans = result.transition.?;
        try testing.expectEqual(@as(u8, 0x00), trans.opcode); // STOP
    }
}

/// Test breakpoint functionality with conditional jumps
test "stepping: breakpoints with conditional jump execution" {
    const allocator = testing.allocator;
    
    // Bytecode: PUSH1 1, PUSH1 8, JUMPI, INVALID, INVALID, JUMPDEST, PUSH1 42, STOP
    const code = &[_]u8{
        0x60, 0x01, // PUSH1 1 (condition = true)
        0x60, 0x08, // PUSH1 8 (jump destination)  
        0x57,       // JUMPI
        0xfe,       // INVALID (should be skipped)
        0xfe,       // INVALID (should be skipped)
        0x5b,       // JUMPDEST at PC 8
        0x60, 0x2a, // PUSH1 42
        0x00,       // STOP
    };
    
    var evm_setup = try setup_evm(allocator, code);
    defer evm_setup.deinit();
    
    var stepper = try SteppingContext.init(evm_setup.evm, evm_setup.frame, allocator);
    defer stepper.deinit();
    
    // Set breakpoint at JUMPDEST (PC 8)
    try stepper.set_breakpoint(8);
    
    // Continue to breakpoint
    const result = try stepper.continue_to_breakpoint();
    try testing.expect(result.status == .paused);
    
    if (result.transition) |trans| {
        try testing.expectEqual(@as(usize, 8), trans.pc);
        try testing.expectEqual(@as(u8, 0x5b), trans.opcode); // JUMPDEST
    }
    
    // Verify we're at the correct location
    const inspection = stepper.inspect_frame();
    try testing.expectEqual(@as(usize, 0), inspection.stack_data.len); // JUMPI consumed both values
    
    // Continue execution
    const final_result = try stepper.run_to_completion();
    try testing.expect(final_result.status == .completed);
    
    // Verify final state
    const final_inspection = stepper.inspect_frame();
    try testing.expectEqual(@as(u256, 42), final_inspection.stack_top().?);
}

/// Test state modification during stepping
test "stepping: modify stack values during execution" {
    const allocator = testing.allocator;
    
    // Bytecode: PUSH1 10, PUSH1 20, ADD, STOP  
    const code = &[_]u8{ 0x60, 0x0a, 0x60, 0x14, 0x01, 0x00 };
    
    var evm_setup = try setup_evm(allocator, code);
    defer evm_setup.deinit();
    
    var stepper = try SteppingContext.init(evm_setup.evm, evm_setup.frame, allocator);
    defer stepper.deinit();
    
    // Step through first two PUSHes
    _ = try stepper.step_instruction(); // PUSH1 10
    _ = try stepper.step_instruction(); // PUSH1 20
    
    // Verify initial stack state
    var inspection = stepper.inspect_frame();
    try testing.expectEqual(@as(u256, 20), inspection.stack_top().?);
    try testing.expectEqual(@as(u256, 10), inspection.stack_peek(1).?);
    
    // Modify stack values
    try stepper.modify_stack_top(100);        // Change 20 to 100
    try stepper.modify_stack_at(1, 50);       // Change 10 to 50
    
    // Verify modifications
    inspection = stepper.inspect_frame();
    try testing.expectEqual(@as(u256, 100), inspection.stack_top().?);
    try testing.expectEqual(@as(u256, 50), inspection.stack_peek(1).?);
    
    // Execute ADD
    _ = try stepper.step_instruction();
    
    // Verify modified result
    inspection = stepper.inspect_frame();
    try testing.expectEqual(@as(u256, 150), inspection.stack_top().?); // 100 + 50 = 150
}

/// Test step_until functionality with custom conditions
test "stepping: step_until with custom conditions" {
    const allocator = testing.allocator;
    
    // Bytecode: PUSH1 1, PUSH1 2, PUSH1 3, PUSH1 4, ADD, ADD, ADD, STOP
    const code = &[_]u8{
        0x60, 0x01, // PUSH1 1
        0x60, 0x02, // PUSH1 2  
        0x60, 0x03, // PUSH1 3
        0x60, 0x04, // PUSH1 4
        0x01,       // ADD (4 + 3 = 7)
        0x01,       // ADD (7 + 2 = 9)
        0x01,       // ADD (9 + 1 = 10)
        0x00,       // STOP
    };
    
    var evm_setup = try setup_evm(allocator, code);
    defer evm_setup.deinit();
    
    var stepper = try SteppingContext.init(evm_setup.evm, evm_setup.frame, allocator);
    defer stepper.deinit();
    
    // Step until we hit an ADD opcode
    const add_condition = SteppingUtils.stop_at_opcode(0x01);
    const result = try stepper.step_until(add_condition);
    
    try testing.expect(result.status == .paused);
    if (result.transition) |trans| {
        try testing.expectEqual(@as(u8, 0x01), trans.opcode);
        try testing.expectEqual(@as(usize, 4), trans.stack_size_before); // All 4 values pushed
    }
    
    // Step until stack size reaches 1 (after all ADDs)
    const stack_condition = SteppingUtils.stop_at_stack_size(1);
    const final_result = try stepper.step_until(stack_condition);
    
    try testing.expect(final_result.status == .paused);
    const inspection = stepper.inspect_frame();
    try testing.expectEqual(@as(usize, 1), inspection.stack_data.len);
}

/// Test memory operations and inspection
test "stepping: memory operations with inspection" {
    const allocator = testing.allocator;
    
    // Bytecode: PUSH1 0x42, PUSH1 0x00, MSTORE, PUSH1 0x20, PUSH1 0x00, MLOAD, STOP
    const code = &[_]u8{
        0x60, 0x42, // PUSH1 0x42 (value)
        0x60, 0x00, // PUSH1 0x00 (offset)
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 0x20 (size)
        0x60, 0x00, // PUSH1 0x00 (offset)
        0x51,       // MLOAD
        0x00,       // STOP
    };
    
    var evm_setup = try setup_evm(allocator, code);
    defer evm_setup.deinit();
    
    var stepper = try SteppingContext.init(evm_setup.evm, evm_setup.frame, allocator);
    defer stepper.deinit();
    
    // Step through the setup
    _ = try stepper.step_instruction(); // PUSH1 0x42
    _ = try stepper.step_instruction(); // PUSH1 0x00
    
    // Execute MSTORE
    const mstore_result = try stepper.step_instruction();
    try testing.expect(mstore_result.status == .paused);
    
    if (mstore_result.transition) |trans| {
        try testing.expectEqual(@as(u8, 0x52), trans.opcode); // MSTORE
        try testing.expect(trans.modified_memory());
    }
    
    // Inspect memory after MSTORE
    const inspection = stepper.inspect_frame();
    try testing.expect(inspection.memory_data.len >= 32);
    
    // Check that value was stored correctly (0x42 at the end of the 32-byte word)
    const memory_word = inspection.read_memory(0, 32).?;
    try testing.expectEqual(@as(u8, 0x42), memory_word[31]);
    
    // Continue and check MLOAD restores the value
    _ = try stepper.step_instruction(); // PUSH1 0x20
    _ = try stepper.step_instruction(); // PUSH1 0x00
    _ = try stepper.step_instruction(); // MLOAD
    
    const final_inspection = stepper.inspect_frame();
    try testing.expectEqual(@as(u256, 0x42), final_inspection.stack_top().?);
}

/// Test complex control flow with multiple jumps
test "stepping: complex control flow with nested jumps" {
    const allocator = testing.allocator;
    
    // Complex bytecode with nested jumps and function calls
    const code = &[_]u8{
        // Main: call function at 0x10
        0x60, 0x10, // PUSH1 0x10 (function address)
        0x56,       // JUMP to function
        0x5b,       // JUMPDEST (return point)
        0x60, 0x99, // PUSH1 0x99 (final result)
        0x00,       // STOP
        
        // Padding to reach 0x10
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        
        // Function at 0x10: adds 10 to top of stack, then returns
        0x5b,       // JUMPDEST (function start)
        0x60, 0x0a, // PUSH1 10
        0x01,       // ADD
        0x60, 0x03, // PUSH1 0x03 (return address)
        0x56,       // JUMP (return)
    };
    
    var evm_setup = try setup_evm(allocator, code);
    defer evm_setup.deinit();
    
    var stepper = try SteppingContext.init(evm_setup.evm, evm_setup.frame, allocator);
    defer stepper.deinit();
    
    // Set breakpoints at key locations
    try stepper.set_breakpoint(0x10); // Function entry
    try stepper.set_breakpoint(0x03); // Return point
    
    // Track execution flow
    var execution_trace = std.ArrayList(usize).init(allocator);
    defer execution_trace.deinit();
    
    // Execute until completion, recording PCs
    while (true) {
        const result = try stepper.step_instruction();
        
        if (result.transition) |trans| {
            try execution_trace.append(trans.pc);
        }
        
        if (result.status != .paused) break;
    }
    
    // Verify we hit the expected execution path
    try testing.expect(execution_trace.items.len > 0);
    
    // Check that we visited both the function and return point
    const trace_slice = execution_trace.items;
    const visited_function = std.mem.indexOfScalar(usize, trace_slice, 0x10) != null;
    const visited_return = std.mem.indexOfScalar(usize, trace_slice, 0x03) != null;
    
    try testing.expect(visited_function);
    try testing.expect(visited_return);
}

/// Test error handling and recovery
test "stepping: error handling with stack underflow" {
    const allocator = testing.allocator;
    
    // Bytecode that causes stack underflow: ADD with empty stack
    const code = &[_]u8{ 0x01, 0x00 }; // ADD, STOP
    
    var evm_setup = try setup_evm(allocator, code);
    defer evm_setup.deinit();
    
    var stepper = try SteppingContext.init(evm_setup.evm, evm_setup.frame, allocator);
    defer stepper.deinit();
    
    // Execute ADD - should fail with stack underflow
    const result = try stepper.step_instruction();
    try testing.expect(result.status == .failed);
    try testing.expect(result.error_info != null);
    
    // Verify execution state
    try testing.expect(stepper.get_execution_state() == .failed);
}

/// Test gas tracking during execution
test "stepping: gas consumption tracking" {
    const allocator = testing.allocator;
    
    // Bytecode with known gas costs
    const code = &[_]u8{
        0x60, 0x01, // PUSH1 (3 gas)
        0x60, 0x02, // PUSH1 (3 gas)  
        0x01,       // ADD (3 gas)
        0x00,       // STOP (0 gas)
    };
    
    var evm_setup = try setup_evm(allocator, code);
    defer evm_setup.deinit();
    
    var stepper = try SteppingContext.init(evm_setup.evm, evm_setup.frame, allocator);
    defer stepper.deinit();
    
    const initial_gas = stepper.inspect_frame().gas_remaining;
    var total_gas_used: u64 = 0;
    
    // Step through and track gas usage
    while (true) {
        const result = try stepper.step_instruction();
        
        if (result.transition) |trans| {
            total_gas_used += trans.gas_cost;
        }
        
        if (result.status != .paused) break;
    }
    
    const final_gas = stepper.inspect_frame().gas_remaining;
    const actual_gas_used = initial_gas - final_gas;
    
    // Verify gas accounting
    try testing.expectEqual(actual_gas_used, total_gas_used);
    try testing.expect(total_gas_used > 0); // Should have used some gas
}

/// Test pause and resume functionality  
test "stepping: pause and resume execution state" {
    const allocator = testing.allocator;
    
    const code = &[_]u8{
        0x60, 0x01, // PUSH1 1
        0x60, 0x02, // PUSH1 2
        0x60, 0x03, // PUSH1 3
        0x00,       // STOP
    };
    
    var evm_setup = try setup_evm(allocator, code);
    defer evm_setup.deinit();
    
    var stepper = try SteppingContext.init(evm_setup.evm, evm_setup.frame, allocator);
    defer stepper.deinit();
    
    // Step partway through
    _ = try stepper.step_instruction(); // PUSH1 1
    _ = try stepper.step_instruction(); // PUSH1 2
    
    // Verify paused state
    try testing.expect(stepper.get_execution_state() == .paused);
    
    // Check we can resume
    try testing.expect(stepper.evm.can_resume_execution(stepper.frame));
    
    // Continue execution
    _ = try stepper.step_instruction(); // PUSH1 3
    const final_result = try stepper.step_instruction(); // STOP
    
    try testing.expect(final_result.status == .completed);
    try testing.expect(stepper.get_execution_state() == .completed);
}

/// Helper function to set up EVM with bytecode
fn setup_evm(allocator: Allocator, code: []const u8) !EvmSetup {
    var analysis = try Analysis.from_code(allocator, code, &OpcodeMetadata.DEFAULT);
    
    var memory_db = MemoryDatabase.init(allocator);
    const db_interface = memory_db.to_database_interface();
    
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    
    const host = Host.init(&evm);
    
    var frame = try Frame.init(
        1000000, // gas_remaining
        false,   // static
        0,       // depth
        primitives.Address.ZERO_ADDRESS, // contract
        primitives.Address.ZERO_ADDRESS, // caller
        0,       // value
        &analysis,
        host,
        db_interface,
        allocator,
    );
    
    return EvmSetup{
        .allocator = allocator,
        .analysis = analysis,
        .memory_db = memory_db,
        .evm = evm,
        .frame = frame,
    };
}

/// Test setup helper struct
const EvmSetup = struct {
    allocator: Allocator,
    analysis: Analysis,
    memory_db: MemoryDatabase,
    evm: Evm,
    frame: Frame,
    
    fn deinit(self: *EvmSetup) void {
        self.frame.deinit(self.allocator);
        self.evm.deinit();
        self.memory_db.deinit();
        self.analysis.deinit();
    }
};
```

### Step 9: Integration with Build System

**Modifications to**: `build.zig`

Add the new stepping modules to the build configuration:

```zig
// In the evm module configuration, add the new files:
const evm_module = b.addModule("evm", .{
    .root_source_file = b.path("src/evm/root.zig"),
    .imports = &.{
        .{ .name = "primitives", .module = primitives_module },
        .{ .name = "rlp", .module = rlp_module },
        .{ .name = "build_options", .module = build_options },
    },
});

// Make sure the new stepping tests are included
const stepping_tests = b.addTest(.{
    .name = "stepping-tests",
    .root_source_file = b.path("test/evm/stepping_test.zig"),
    .target = target,
    .optimize = optimize,
});

stepping_tests.root_module.addImport("evm", evm_module);
stepping_tests.root_module.addImport("primitives", primitives_module);
```

**Modifications to**: `src/evm/root.zig`

Export the new stepping API:

```zig
// Add these exports to make the stepping API available
pub const SteppingContext = @import("tracing/stepping_context.zig").SteppingContext;
pub const SteppingUtils = @import("tracing/stepping_context.zig").SteppingUtils;
pub const step_types = @import("tracing/step_types.zig");
pub const ExecutionStateManager = @import("tracing/execution_state.zig").ExecutionStateManager;
```

### Step 10: Documentation and Usage Examples

**File**: `docs/stepping_api_guide.md`

```markdown
# Stepping API Usage Guide

## Quick Start

```zig
const std = @import("std");
const evm = @import("evm");

// Setup your EVM and frame (see setup_evm helper in tests)
var evm_setup = try setup_evm(allocator, bytecode);
defer evm_setup.deinit();

// Create stepping context
var stepper = try evm.SteppingContext.init(evm_setup.evm, evm_setup.frame, allocator);
defer stepper.deinit();

// Step through execution
while (true) {
    const result = try stepper.step_instruction();
    
    // Inspect current state
    const inspection = stepper.inspect_frame();
    std.debug.print("PC: {}, Stack size: {}, Gas: {}\n", 
        .{ result.transition.?.pc, inspection.stack_data.len, inspection.gas_remaining });
    
    if (result.status != .paused) break;
}
```

## Advanced Features

### Breakpoints
```zig
try stepper.set_breakpoint(0x10);  // Break at PC 0x10
try stepper.set_breakpoint(0x20);  // Break at PC 0x20

const result = try stepper.continue_to_breakpoint();
```

### Conditional Stepping
```zig
// Step until ADD opcode
const add_condition = evm.SteppingUtils.stop_at_opcode(0x01);
const result = try stepper.step_until(add_condition);

// Step until low gas
const gas_condition = evm.SteppingUtils.stop_at_gas_threshold(1000);
const result = try stepper.step_until(gas_condition);
```

### State Modification
```zig
// Modify stack for debugging
try stepper.modify_stack_top(0x1234);
try stepper.modify_stack_at(1, 0x5678);
```
```

## Best Practices

### 1. **Memory Management**
- Always call `deinit()` on stepping contexts
- Use defer to ensure cleanup
- Be aware that stepping contexts hold references to EVM and Frame

### 2. **Performance Considerations**
- Stepping has overhead - only use for debugging
- Limit memory snapshots size via tracer config
- Use `run_to_completion()` for final execution

### 3. **Error Handling**
- Check step result status before accessing transition data
- Handle failed executions gracefully
- Reset stepping context for retry scenarios

### 4. **Testing Patterns**
- Test both successful and failed execution paths
- Verify gas consumption matches expectations
- Test edge cases like stack overflow/underflow
- Use realistic bytecode in tests

## Implementation Quality Checklist

### ✅ Completeness
- [ ] All stepping modes implemented (instruction, block, breakpoint, continuous)
- [ ] State inspection API complete
- [ ] Error handling comprehensive
- [ ] Memory management proper
- [ ] Documentation thorough

### ✅ Correctness  
- [ ] All tests pass
- [ ] Gas accounting accurate
- [ ] State transitions correct
- [ ] Memory safety verified
- [ ] Edge cases handled

### ✅ Performance
- [ ] Minimal overhead when not stepping
- [ ] Efficient state capture
- [ ] Proper resource cleanup
- [ ] No memory leaks

### ✅ Usability
- [ ] Clean, intuitive API
- [ ] Good error messages
- [ ] Comprehensive examples
- [ ] Helper utilities provided

## Migration Guide

### Removing Obsolete Code

After implementing the new stepping API:

1. **Remove incomplete methods** from `MemoryTracer`:
   ```zig
   // DELETE this incomplete method:
   pub fn step_once(self: *MemoryTracer) !?StepTransition {
       // Old incomplete implementation
   }
   ```

2. **Update existing tests** that might use the old incomplete API

3. **Verify no dead code** remains in the tracing system

### Backward Compatibility

The new API is designed to be additive - existing tracing functionality remains unchanged. Only the incomplete stepping methods are replaced with the complete implementation.

---

This comprehensive refactoring provides a production-ready manual stepping API that enables powerful EVM debugging capabilities while maintaining the performance and architecture principles of the Guillotine EVM.