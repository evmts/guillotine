## PR 6: Side-by-Side Execution (Primary EVM vs Mini EVM)

**COMPREHENSIVE IMPLEMENTATION GUIDE**

Execute bytecode simultaneously in the primary EVM and the Mini EVM, render a live, step-by-step comparison, and highlight divergences with precise diffs. This PR builds on:

- PR 1 (Interpreter Debug Hooks) for pausable stepping
- PR 2 (Standard Memory Tracer)
- PR 3 (Mini EVM Comparator and `debug/shadow.zig`)
- PR 4 (Devtool refactor to tracer-driven execution)

This document provides **EVERYTHING** needed to implement PR 6 end-to-end: exact code touch points, APIs, data structures, memory ownership rules, UI contracts, tests, and comprehensive Zig patterns with complete examples.

### Why side-by-side?

- Faster debugging: immediately see where and how primary diverges from Mini
- Deterministic reproduction: lockstep execution driven by debug hooks ensures consistent step indices
- Minimal overhead mode: per-call comparison when step-by-step isn't needed

## CODEBASE UNDERSTANDING - CRITICAL CONTEXT

After thorough analysis, here's the complete current state:

### Current Architecture Analysis

**Primary EVM (`src/evm/evm/call.zig`)**:
- Uses analysis-based execution via `interpret()` function
- Code is pre-analyzed into instruction blocks with `CodeAnalysis.from_code()`
- Frame tracks `instruction: *const Instruction` pointer into analysis blocks
- Supports debug logging but **NO debug hooks system exists yet**
- Complex frame management with snapshot handling for nested calls
- Memory-optimized Frame structure with cache-aligned hot fields

**Mini EVM (`src/evm/evm/call_mini.zig`)**:
- Uses simple PC-based execution with basic loop: `while (pc < call_code.len)`
- No analysis - direct bytecode interpretation
- Handles PUSH, JUMP, JUMPI, PC, STOP, RETURN, REVERT inline
- Delegates other opcodes to jump table: `operation.execute(context)`
- **Much simpler control flow but same Frame/Host interface**

**Current Devtool (`src/devtool/evm.zig`) - After PR 4**:
- Now uses tracer-driven execution instead of custom `stepExecute()` logic
- Integrated with debug hooks from PR 1 for pausable stepping
- Uses standard memory tracer from PR 2 for state capture
- Ready for dual-engine integration

### Components Available From Previous PRs
- **PR 1**: Debug hooks system (`src/evm/debug_hooks.zig`) with `OnStepFn` callbacks
- **PR 2**: Standard memory tracer for state capture and serialization  
- **PR 3**: Shadow comparator (`src/evm/debug/shadow.zig`) and Mini per-step API (`execute_single_op`)
- **PR 4**: Devtool refactored to use tracer-driven execution via debug hooks

### PR 6 Components To Implement  
- Side-by-side dual execution mode in devtool
- Integration of existing shadow comparator for real-time comparison
- UI components for rendering side-by-side state
- Enhanced step-by-step comparison with mismatch highlighting

### Critical Frame Structure Details (Cache-Optimized Layout)

```zig
pub const Frame = struct {
    // === FIRST CACHE LINE (64 bytes) - ULTRA HOT ===
    gas_remaining: u64,           // 8 bytes - every opcode checks this
    stack: Stack,                 // 32 bytes - every opcode accesses (4 pointers)  
    analysis: *const CodeAnalysis, // 8 bytes - for JUMP validation
    host: Host,                   // 16 bytes - gas costs, hardfork checks
    
    // === SECOND CACHE LINE - MEMORY OPERATIONS ===
    memory: Memory,               // 72 bytes - MLOAD/MSTORE/KECCAK256/LOG
    
    // === THIRD CACHE LINE - STORAGE OPERATIONS ===  
    state: DatabaseInterface,     // 16 bytes - SLOAD/SSTORE access
    contract_address: Address,    // 20 bytes
    depth: u16,                   // 2 bytes - reentrancy checks
    is_static: bool,              // 1 byte - SSTORE restrictions
    
    // === FOURTH CACHE LINE - CALL CONTEXT ===
    caller: Address,              // 20 bytes - CALLER opcode
    value: u256,                  // 32 bytes - CALLVALUE opcode
    input_buffer: []const u8,     // per-frame input exposure
    output_buffer: []const u8,    // per-frame output exposure
}
```

## DETAILED IMPLEMENTATION SCOPE

### Core Functionality To Implement

**1. Dual-Execution Engine (`src/devtool/evm.zig` enhancements)**:
- `ComparisonMode` enum: `{ off, per_call, per_step }`
- `run_both_per_call()`: Execute both engines once, compare final `CallResult`  
- `run_both_per_step()`: Lockstep execution driven by debug hooks from PR 1
- `SideBySideRun` data structure for comprehensive comparison results

**2. Integration Layer**:
- Leverage `src/evm/debug/shadow.zig` (from PR 3) for state comparisons
- Use debug hooks (from PR 1) to pause primary EVM at each step
- Drive Mini EVM step-by-step using `execute_single_op` (from PR 3)
- Real-time mismatch detection and detailed diff reporting

**3. UI Enhancements**:
- `ComparisonView.tsx` component for side-by-side visualization  
- Live step timeline with mismatch highlighting
- Expandable diff sections for stack, memory, storage divergences
- Performance metrics comparison (gas usage deltas)

## COMPREHENSIVE ZIG IMPLEMENTATION GUIDE

### Critical Zig Language Patterns For This PR

**1. Optional Function Pointers (Debug Hooks Pattern)**:
```zig
// From PR 1 debug hooks - zero overhead when unset
pub const DebugHooks = struct {
    user_ctx: ?*anyopaque = null,
    on_step: ?OnStepFn = null,
    on_message: ?OnMessageFn = null,

    // Zero-cost abstraction usage:
    pub fn call_on_step(self: *const DebugHooks, frame: *Frame, pc: usize, opcode: u8) !StepControl {
        if (self.on_step) |callback| {
            return callback(self.user_ctx, frame, pc, opcode);
        }
        return .cont; // Default behavior
    }
};
```

**2. Error Union and Control Flow Patterns**:
```zig
// PR 1 established execution control via error returns
pub const StepControl = enum { cont, pause, abort };

// Hook functions return errors for control flow
const OnStepFn = *const fn (user_ctx: ?*anyopaque, frame: *Frame, pc: usize, opcode: u8) anyerror!StepControl;

// Usage in interpreter loop (PR 1):
if (evm.debug_hooks) |*hooks| {
    const control = hooks.call_on_step(frame, pc, opcode) catch |err| switch (err) {
        error.DebugAbort => return ExecutionError.Error.DebugAbort,
        error.DebugPaused => return ExecutionError.Error.DebugPaused,
        else => return err,
    };
    
    switch (control) {
        .pause => return ExecutionError.Error.DebugPaused,
        .abort => return ExecutionError.Error.DebugAbort,  
        .cont => {}, // Continue execution
    }
}
```

**3. Memory Management Patterns (Critical for PR 6)**:
```zig
// Pattern 1: Allocate with cleanup guarantee
const shadow_result = try shadow.compare_step(primary_frame, mini_frame, pc_primary, pc_mini, cfg, allocator);
defer if (shadow_result) |result| {
    if (result.lhs_summary) |summary| allocator.free(summary);
    if (result.rhs_summary) |summary| allocator.free(summary);  
};

// Pattern 2: Transfer ownership to caller
pub fn create_comparison_summary(allocator: Allocator, ...) ![]const u8 {
    const summary = try allocator.alloc(u8, estimated_size);
    // ... populate summary ...
    return summary; // Caller now owns, must free
}

// Pattern 3: Temporary allocations with errdefer
const temp_buffer = try allocator.alloc(u8, size);
errdefer allocator.free(temp_buffer); // Clean up on error
const result = process_data(temp_buffer) catch |err| {
    // errdefer will clean up automatically
    return err;
};
allocator.free(temp_buffer); // Successful path cleanup
return result;
```

**4. Struct Layout and Initialization Patterns**:
```zig
// Side-by-side step data - optimized for JSON serialization
pub const SideBySideStep = struct {
    step_index: usize,
    
    // Primary state (grouped for cache efficiency)  
    primary: struct {
        pc: usize,
        gas_before: u64,
        gas_after: u64, 
        stack_size: usize,
        opcode: u8,
        opcode_name: []const u8, // String literal, no alloc needed
    },
    
    // Mini state (parallel structure)
    mini: struct {
        pc: usize, 
        gas_before: u64,
        gas_after: u64,
        stack_size: usize,
        opcode: u8,
        opcode_name: []const u8,
    },
    
    // Optional mismatch details
    mismatch: ?ShadowMismatch = null,
    
    // Compact initialization
    pub fn init_matching(step_idx: usize, primary_state: anytype, mini_state: anytype) SideBySideStep {
        return .{
            .step_index = step_idx,
            .primary = primary_state,
            .mini = mini_state,
            .mismatch = null,
        };
    }
};
```

## PRIMARY INTEGRATION POINTS (Updated with PR Context)

**Core EVM Entry Points**:
- `src/evm/evm/call.zig` → Primary analysis-based execution
  - Already integrated with debug hooks (PR 1) via `interpret()` 
  - Calls `hooks.call_on_step()` before each opcode dispatch
- `src/evm/evm/call_mini.zig` → Mini PC-based execution  
  - Enhanced in PR 3 with `execute_single_op()` for stepping
  - Simple loop structure: `while (pc < code.len)` with inline opcode handling

**Debug Hook Integration Points (From PR 1)**:
- `src/evm/evm/interpret.zig` → Primary interpreter with hook calls
- `src/evm/execution/system.zig` → CALL-family opcodes with `OnMessageFn` hooks
- `src/evm/evm.zig` → EVM struct with `debug_hooks: ?DebugHooks` field

**Shadow Comparison (From PR 3)**:  
- `src/evm/debug/shadow.zig` → State comparison and diff generation
- `src/evm/evm.zig` → Shadow configuration and last mismatch storage

**Tracer-Driven Devtool (From PR 4)**:
- `src/devtool/evm.zig` → Now uses hooks instead of custom `stepExecute()` 
- Integrated with memory tracer (PR 2) for state serialization

## COMPLETE SHADOW COMPARATOR API (From PR 3)

The shadow comparator from PR 3 provides comprehensive state comparison between primary and mini EVM executions:

```zig
// src/evm/debug/shadow.zig - Complete API Reference
const std = @import("std");
const ExecutionError = @import("../execution/execution_error.zig");
const CallResult = @import("../evm/call_result.zig").CallResult;
const Frame = @import("../frame.zig").Frame;

pub const ShadowMode = enum { 
    off,      // No comparison
    per_call, // Compare only final CallResult
    per_step  // Compare at each step
};

pub const ShadowConfig = struct {
    mode: ShadowMode = .per_call,
    stack_compare_limit: usize = 64,     // Compare top N stack elements
    memory_window: usize = 256,          // Bytes to compare around recent writes
    storage_key_limit: usize = 32,       // Max storage keys to compare per step
    enable_detailed_diffs: bool = true,  // Generate human-readable summaries
    
    // Performance optimizations  
    skip_identical_steps: bool = true,   // Only report mismatches
    max_summary_length: usize = 512,     // Truncate long diff summaries
};

pub const ShadowMismatch = struct {
    context: enum { per_call, per_step },
    step_index: usize = 0,               // Step number in execution
    op_pc: usize = 0,                    // Program counter (per_step only)
    opcode: u8 = 0,                      // Current opcode (per_step only)
    
    // Mismatch classification
    field: enum { 
        success,      // CallResult.success differs
        gas_left,     // Gas remaining differs  
        output,       // Return/revert data differs
        logs,         // Event logs differ
        storage,      // Storage state differs
        stack,        // Stack contents differ
        memory,       // Memory contents differ
        pc,           // Program counter differs (shouldn't happen)
        execution_error // Different execution errors
    },
    
    // Human-readable summaries (caller must free)
    lhs_summary: []const u8,  // Primary EVM state description
    rhs_summary: []const u8,  // Mini EVM state description
    
    // Quick initialization helper
    pub fn init_step_mismatch(
        step_idx: usize, 
        pc: usize, 
        opcode: u8, 
        field_type: @TypeOf(field), 
        lhs: []const u8, 
        rhs: []const u8
    ) ShadowMismatch {
        return .{
            .context = .per_step,
            .step_index = step_idx,
            .op_pc = pc,
            .opcode = opcode,
            .field = field_type,
            .lhs_summary = lhs,
            .rhs_summary = rhs,
        };
    }
};

/// Compare final call results (per-call mode)
/// Returns null if identical, ShadowMismatch if different
/// Caller must free mismatch.lhs_summary and mismatch.rhs_summary
pub fn compare_call_results(
    primary: CallResult,
    mini: CallResult,
    allocator: std.mem.Allocator
) !?ShadowMismatch {
    // Fast path: identical results
    if (primary.success == mini.success and 
        primary.gas_left == mini.gas_left and
        std.mem.eql(u8, primary.output orelse &.{}, mini.output orelse &.{})) {
        return null;
    }
    
    // Generate detailed diff
    const lhs_summary = try std.fmt.allocPrint(allocator, 
        "Primary: success={}, gas_left={}, output_len={}", 
        .{ primary.success, primary.gas_left, if (primary.output) |o| o.len else 0 });
    errdefer allocator.free(lhs_summary);
    
    const rhs_summary = try std.fmt.allocPrint(allocator,
        "Mini: success={}, gas_left={}, output_len={}",
        .{ mini.success, mini.gas_left, if (mini.output) |o| o.len else 0 });
    errdefer allocator.free(rhs_summary);
    
    // Determine primary mismatch type
    const field_type: @TypeOf(ShadowMismatch.field) = blk: {
        if (primary.success != mini.success) break :blk .success;
        if (primary.gas_left != mini.gas_left) break :blk .gas_left;
        break :blk .output;
    };
    
    return ShadowMismatch{
        .context = .per_call,
        .field = field_type,
        .lhs_summary = lhs_summary,
        .rhs_summary = rhs_summary,
    };
}

/// Compare execution state at single step (per-step mode)  
/// Returns null if identical, ShadowMismatch if different
/// Caller must free mismatch.lhs_summary and mismatch.rhs_summary
pub fn compare_step(
    primary_frame: *const Frame,
    mini_frame: *const Frame,
    pc_primary: usize,
    pc_mini: usize,
    cfg: ShadowConfig,
    step_index: usize,
    opcode: u8,
    allocator: std.mem.Allocator
) !?ShadowMismatch {
    // Fast path: PC and gas match (most common case)
    if (pc_primary == pc_mini and 
        primary_frame.gas_remaining == mini_frame.gas_remaining and
        primary_frame.stack.size() == mini_frame.stack.size()) {
        
        // Quick stack comparison (top few elements)
        const stack_check_depth = @min(cfg.stack_compare_limit, primary_frame.stack.size());
        var i: usize = 0;
        while (i < stack_check_depth) : (i += 1) {
            const primary_val = primary_frame.stack.peek(i) catch break;
            const mini_val = mini_frame.stack.peek(i) catch break;
            if (primary_val != mini_val) break;
        } else {
            // Stacks match, likely identical step
            if (cfg.skip_identical_steps) return null;
        }
    }
    
    // Generate detailed comparison
    if (pc_primary != pc_mini) {
        const lhs = try std.fmt.allocPrint(allocator, "pc={}", .{pc_primary});
        errdefer allocator.free(lhs);
        const rhs = try std.fmt.allocPrint(allocator, "pc={}", .{pc_mini});
        errdefer allocator.free(rhs);
        
        return ShadowMismatch.init_step_mismatch(step_index, pc_primary, opcode, .pc, lhs, rhs);
    }
    
    if (primary_frame.gas_remaining != mini_frame.gas_remaining) {
        const lhs = try std.fmt.allocPrint(allocator, "gas={}", .{primary_frame.gas_remaining});
        errdefer allocator.free(lhs);
        const rhs = try std.fmt.allocPrint(allocator, "gas={}", .{mini_frame.gas_remaining});
        errdefer allocator.free(rhs);
        
        return ShadowMismatch.init_step_mismatch(step_index, pc_primary, opcode, .gas_left, lhs, rhs);
    }
    
    // Stack comparison with detailed diff
    if (primary_frame.stack.size() != mini_frame.stack.size()) {
        const lhs = try std.fmt.allocPrint(allocator, "stack_size={}", .{primary_frame.stack.size()});
        errdefer allocator.free(lhs);
        const rhs = try std.fmt.allocPrint(allocator, "stack_size={}", .{mini_frame.stack.size()});  
        errdefer allocator.free(rhs);
        
        return ShadowMismatch.init_step_mismatch(step_index, pc_primary, opcode, .stack, lhs, rhs);
    }
    
    // Detailed stack value comparison
    const stack_size = primary_frame.stack.size();
    const check_depth = @min(cfg.stack_compare_limit, stack_size);
    
    var mismatch_idx: ?usize = null;
    for (0..check_depth) |i| {
        const primary_val = primary_frame.stack.peek(i) catch continue;
        const mini_val = mini_frame.stack.peek(i) catch continue;
        if (primary_val != mini_val) {
            mismatch_idx = i;
            break;
        }
    }
    
    if (mismatch_idx) |idx| {
        const primary_val = primary_frame.stack.peek(idx) catch 0;
        const mini_val = mini_frame.stack.peek(idx) catch 0;
        
        const lhs = try std.fmt.allocPrint(allocator, "stack[{}]=0x{x}", .{ idx, primary_val });
        errdefer allocator.free(lhs);
        const rhs = try std.fmt.allocPrint(allocator, "stack[{}]=0x{x}", .{ idx, mini_val });
        errdefer allocator.free(rhs);
        
        return ShadowMismatch.init_step_mismatch(step_index, pc_primary, opcode, .stack, lhs, rhs);
    }
    
    // No mismatch found
    return null;
}

/// Cleanup utility for ShadowMismatch  
pub fn free_mismatch(mismatch: *ShadowMismatch, allocator: std.mem.Allocator) void {
    allocator.free(mismatch.lhs_summary);
    allocator.free(mismatch.rhs_summary);
}
```

**EVM Integration (From PR 3):**
```zig
// src/evm/evm.zig additions from PR 3
pub const DebugShadow = @import("debug/shadow.zig");

// Add to Evm struct:  
shadow_mode: DebugShadow.ShadowMode = .off,
shadow_cfg: DebugShadow.ShadowConfig = .{},
last_shadow_mismatch: ?DebugShadow.ShadowMismatch = null,

// Cleanup method
pub fn free_last_shadow_mismatch(self: *Evm) void {
    if (self.last_shadow_mismatch) |*mismatch| {
        DebugShadow.free_mismatch(mismatch, self.allocator);
        self.last_shadow_mismatch = null;
    }
}
```

## COMPLETE DEBUG HOOKS API (From PR 1)

The debug hooks system from PR 1 enables pausable, controllable execution for comparison:

```zig
// src/evm/debug_hooks.zig - Complete API with Examples
const std = @import("std");
const ExecutionError = @import("execution/execution_error.zig");
const Frame = @import("frame.zig").Frame;
const CallParams = @import("host.zig").CallParams;

/// Control execution flow from debug hooks
pub const StepControl = enum { 
    cont,   // Continue normal execution
    pause,  // Pause execution (return DebugPaused error)
    abort   // Abort execution (return DebugAbort error)
};

/// Message hook phases for CALL-family opcodes  
pub const MessagePhase = enum { before, after };

/// Step-by-step execution hook - called before each opcode
/// user_ctx: Opaque context pointer passed to hooks
/// frame: Current execution frame (read-only recommended)
/// pc: Program counter (analysis-based for primary, PC-based for mini)  
/// opcode: Current opcode byte being executed
/// Returns: StepControl to continue/pause/abort, or error to propagate
pub const OnStepFn = *const fn (
    user_ctx: ?*anyopaque, 
    frame: *const Frame, 
    pc: usize, 
    opcode: u8
) anyerror!StepControl;

/// Message/Call hook - called around CALL-family opcodes
/// user_ctx: Opaque context pointer
/// params: Call parameters (to, value, input, etc.)
/// phase: .before (pre-call) or .after (post-call)
pub const OnMessageFn = *const fn (
    user_ctx: ?*anyopaque, 
    params: *const CallParams, 
    phase: MessagePhase
) anyerror!void;

/// Debug hooks container - zero overhead when unset
pub const DebugHooks = struct {
    user_ctx: ?*anyopaque = null,
    on_step: ?OnStepFn = null,
    on_message: ?OnMessageFn = null,
    
    // Helper method for safe step hook invocation
    pub fn call_on_step(
        self: *const DebugHooks, 
        frame: *const Frame, 
        pc: usize, 
        opcode: u8
    ) !StepControl {
        if (self.on_step) |hook_fn| {
            return hook_fn(self.user_ctx, frame, pc, opcode);
        }
        return .cont;
    }
    
    // Helper method for safe message hook invocation
    pub fn call_on_message(
        self: *const DebugHooks, 
        params: *const CallParams, 
        phase: MessagePhase
    ) !void {
        if (self.on_message) |hook_fn| {
            try hook_fn(self.user_ctx, params, phase);
        }
    }
};

/// Example: Pausable step counter for devtool integration
pub const StepCounterContext = struct {
    steps_taken: usize = 0,
    max_steps: usize,
    should_pause_next: bool = false,
    
    // Step hook implementation
    pub fn on_step_hook(
        user_ctx: ?*anyopaque, 
        frame: *const Frame, 
        pc: usize, 
        opcode: u8
    ) anyerror!StepControl {
        const ctx = @as(*StepCounterContext, @ptrCast(@alignCast(user_ctx.?)));
        ctx.steps_taken += 1;
        
        std.log.debug("Step {}: PC={}, opcode=0x{x}, gas={}", .{
            ctx.steps_taken, pc, opcode, frame.gas_remaining
        });
        
        if (ctx.should_pause_next) {
            ctx.should_pause_next = false;
            return .pause;
        }
        
        if (ctx.steps_taken >= ctx.max_steps) {
            return .abort;
        }
        
        return .cont;
    }
    
    pub fn get_hooks(self: *StepCounterContext) DebugHooks {
        return .{
            .user_ctx = @ptrCast(self),
            .on_step = on_step_hook,
            .on_message = null,
        };
    }
};
```

**Integration into EVM (From PR 1):**

```zig
// src/evm/execution/execution_error.zig additions
pub const Error = error{
    // ... existing errors ...
    
    /// Debug hook requested pause - not a real error
    DebugPaused,
    
    /// Debug hook requested abort - not a real error  
    DebugAborted,
};
```

```zig  
// src/evm/evm.zig additions
const DebugHooks = @import("debug_hooks.zig").DebugHooks;

// Add to Evm struct:
debug_hooks: ?DebugHooks = null,

// Public API for setting hooks
pub fn set_debug_hooks(self: *Evm, hooks: ?DebugHooks) void {
    self.debug_hooks = hooks;
}

pub fn clear_debug_hooks(self: *Evm) void {
    self.debug_hooks = null;
}
```

**Integration into Interpreter (From PR 1):**

```zig
// src/evm/evm/interpret.zig modifications (example pattern)
pub fn interpret(evm: *Evm, frame: *Frame) ExecutionError.Error!void {
    // ... existing setup ...
    
    while (frame.instruction.arg != .end_execution) {
        const current_pc = derive_pc_from_instruction(frame); // PC mapping logic
        const opcode = get_current_opcode(frame); // Extract from analysis
        
        // DEBUG HOOK: Call on_step before opcode execution
        if (evm.debug_hooks) |*hooks| {
            const control = hooks.call_on_step(frame, current_pc, opcode) catch |err| switch (err) {
                error.DebugPaused => return ExecutionError.Error.DebugPaused,
                error.DebugAborted => return ExecutionError.Error.DebugAborted,
                else => return err, // Propagate unexpected errors
            };
            
            switch (control) {
                .pause => return ExecutionError.Error.DebugPaused,
                .abort => return ExecutionError.Error.DebugAborted,
                .cont => {}, // Continue with normal execution
            }
        }
        
        // Normal opcode execution continues...
        const operation = frame.instruction.opcode_fn;
        try operation(@ptrCast(frame));
        
        frame.instruction = frame.instruction.next_instruction;
    }
}

// Helper function for PC derivation from analysis (already exists in devtool)
fn derive_pc_from_instruction(frame: *const Frame) usize {
    // Use analysis.inst_to_pc mapping or fallback logic
    const analysis = frame.analysis;
    const instruction_index = get_instruction_index(frame); // Implementation detail
    
    if (instruction_index < analysis.inst_to_pc.len) {
        return analysis.inst_to_pc[instruction_index];
    } else {
        // Fallback: estimate from instruction offset 
        return estimate_pc_from_offset(frame);
    }
}
```

**Integration into CALL opcodes (From PR 1):**

```zig
// src/evm/execution/system.zig modifications for op_call
pub fn op_call(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    const evm_ptr = @as(*Evm, @ptrCast(@alignCast(frame.host.ptr)));
    
    // ... extract call parameters ...
    
    const params = CallParams{ .call = .{
        .to = to_addr,
        .caller = frame.contract_address,
        .input = input_data,
        .value = value,
        .gas = gas_limit,
    }};
    
    // DEBUG HOOK: Message hook before call
    if (evm_ptr.debug_hooks) |*hooks| {
        hooks.call_on_message(&params, .before) catch |err| {
            // Message hooks don't control execution flow, just log errors
            std.log.warn("Message hook error (before): {}", .{err});
        };
    }
    
    // Execute the call
    const call_result = evm_ptr.call(params) catch |err| {
        // ... error handling ...
        return err;
    };
    
    // DEBUG HOOK: Message hook after call  
    if (evm_ptr.debug_hooks) |*hooks| {
        hooks.call_on_message(&params, .after) catch |err| {
            std.log.warn("Message hook error (after): {}", .{err});
        };
    }
    
    // ... rest of opcode implementation ...
}
```

## COMPLETE MINI EVM PER-STEP API (From PR 3)

Enhanced `src/evm/evm/call_mini.zig` with step-by-step execution control:

```zig
// src/evm/evm/call_mini.zig additions from PR 3

/// Execute a single opcode and return next PC
/// This is the core building block for step-by-step mini EVM execution
/// Returns the next program counter after executing the opcode at `pc`
pub fn execute_single_op(
    self: *Evm, 
    frame: *Frame, 
    code: []const u8, 
    pc: usize
) ExecutionError.Error!usize {
    if (pc >= code.len) {
        return ExecutionError.Error.OutOfOffset;
    }
    
    const opcode = code[pc];
    const operation = self.table.get_operation(opcode);
    
    // Validate opcode
    if (operation.undefined) {
        return ExecutionError.Error.InvalidOpcode;
    }
    
    // Check gas requirements
    if (frame.gas_remaining < operation.constant_gas) {
        return ExecutionError.Error.OutOfGas;
    }
    
    // Check stack requirements
    if (frame.stack.size() < operation.min_stack) {
        return ExecutionError.Error.StackUnderflow;
    }
    if (frame.stack.size() > operation.max_stack) {
        return ExecutionError.Error.StackOverflow;
    }
    
    // Consume gas
    frame.gas_remaining -= operation.constant_gas;
    
    // Handle special opcodes that require custom PC management
    const opcode_mod = @import("../opcodes/opcode.zig");
    
    switch (opcode) {
        @intFromEnum(opcode_mod.Enum.STOP) => {
            return ExecutionError.Error.STOP;
        },
        
        @intFromEnum(opcode_mod.Enum.JUMP) => {
            const dest = try frame.stack.pop();
            if (dest > code.len) {
                return ExecutionError.Error.InvalidJump;
            }
            
            const dest_pc = @as(usize, @intCast(dest));
            if (dest_pc >= code.len or code[dest_pc] != @intFromEnum(opcode_mod.Enum.JUMPDEST)) {
                return ExecutionError.Error.InvalidJump;
            }
            
            return dest_pc;
        },
        
        @intFromEnum(opcode_mod.Enum.JUMPI) => {
            const dest = try frame.stack.pop();
            const cond = try frame.stack.pop();
            
            if (cond != 0) {
                if (dest > code.len) {
                    return ExecutionError.Error.InvalidJump;
                }
                
                const dest_pc = @as(usize, @intCast(dest));
                if (dest_pc >= code.len or code[dest_pc] != @intFromEnum(opcode_mod.Enum.JUMPDEST)) {
                    return ExecutionError.Error.InvalidJump;
                }
                
                return dest_pc;
            } else {
                return pc + 1;
            }
        },
        
        @intFromEnum(opcode_mod.Enum.PC) => {
            try frame.stack.append(@intCast(pc));
            return pc + 1;
        },
        
        @intFromEnum(opcode_mod.Enum.JUMPDEST) => {
            // JUMPDEST is a no-op
            return pc + 1;
        },
        
        @intFromEnum(opcode_mod.Enum.RETURN) => {
            const offset = try frame.stack.pop();
            const size = try frame.stack.pop();
            
            if (size > 0) {
                const offset_usize = @as(usize, @intCast(offset));
                const size_usize = @as(usize, @intCast(size));
                const data = try frame.memory.get_slice(offset_usize, size_usize);
                try frame.host.set_output(data);
            }
            
            return ExecutionError.Error.RETURN;
        },
        
        @intFromEnum(opcode_mod.Enum.REVERT) => {
            const offset = try frame.stack.pop();
            const size = try frame.stack.pop();
            
            if (size > 0) {
                const offset_usize = @as(usize, @intCast(offset));
                const size_usize = @as(usize, @intCast(size));
                const data = try frame.memory.get_slice(offset_usize, size_usize);
                try frame.host.set_output(data);
            }
            
            return ExecutionError.Error.REVERT;
        },
        
        else => {
            // Handle PUSH opcodes specially
            if (opcode_mod.is_push(opcode)) {
                const push_size = opcode_mod.get_push_size(opcode);
                if (pc + push_size >= code.len) {
                    return ExecutionError.Error.OutOfOffset;
                }
                
                var value: u256 = 0;
                const data_start = pc + 1;
                const data_end = @min(data_start + push_size, code.len);
                const data = code[data_start..data_end];
                
                // Convert bytes to u256 (big-endian)
                for (data) |byte| {
                    value = (value << 8) | byte;
                }
                
                try frame.stack.append(value);
                return pc + 1 + push_size;
            }
            
            // For all other opcodes, use the execution function
            const context: *anyopaque = @ptrCast(frame);
            try operation.execute(context);
            return pc + 1;
        }
    }
}

/// Single-step mini EVM state for external control
pub const MiniStepState = struct {
    frame: Frame,
    pc: usize,
    code: []const u8,
    completed: bool = false,
    execution_error: ?ExecutionError.Error = null,
    
    pub fn init(
        allocator: std.mem.Allocator,
        params: CallParams,
        evm: *Evm
    ) !MiniStepState {
        // Extract call info similar to call_mini
        const call_data = switch (params) {
            .call => |cd| cd,
            .staticcall => |cd| cd,
            else => return error.UnsupportedCallType,
        };
        
        const code = evm.state.get_code(call_data.to);
        const host = Host.init(evm);
        
        // Create analysis for frame initialization
        const analysis = try evm.analysis_cache.?.getOrAnalyze(code, &evm.table);
        
        var frame = try Frame.init(
            call_data.gas,
            params == .staticcall,
            0, // depth
            call_data.to,
            call_data.caller,
            if (params == .staticcall) 0 else call_data.value,
            analysis,
            host,
            evm.state.database,
            allocator
        );
        
        frame.input_buffer = call_data.input;
        
        return MiniStepState{
            .frame = frame,
            .pc = 0,
            .code = code,
        };
    }
    
    pub fn deinit(self: *MiniStepState, allocator: std.mem.Allocator) void {
        self.frame.deinit(allocator);
    }
    
    /// Execute one step and update state
    pub fn step(self: *MiniStepState, evm: *Evm) void {
        if (self.completed) return;
        
        const next_pc = evm.execute_single_op(&self.frame, self.code, self.pc) catch |err| {
            self.execution_error = err;
            self.completed = true;
            return;
        };
        
        self.pc = next_pc;
        
        // Check if execution should stop
        if (self.execution_error) |err| {
            switch (err) {
                ExecutionError.Error.STOP,
                ExecutionError.Error.RETURN,
                ExecutionError.Error.REVERT => {
                    self.completed = true;
                },
                else => {
                    self.completed = true;
                }
            }
        }
    }
    
    /// Get current execution state for comparison
    pub fn get_state(self: *const MiniStepState) struct {
        pc: usize,
        gas_remaining: u64,
        stack_size: usize,
        completed: bool,
        error: ?ExecutionError.Error,
    } {
        return .{
            .pc = self.pc,
            .gas_remaining = self.frame.gas_remaining,
            .stack_size = self.frame.stack.size(),
            .completed = self.completed,
            .error = self.execution_error,
        };
    }
};

/// Enhanced call_mini with step-by-step support
pub fn call_mini_with_stepping(
    self: *Evm, 
    params: CallParams, 
    mode: enum { per_call, per_step }
) ExecutionError.Error!CallResult {
    switch (mode) {
        .per_call => return call_mini(self, params), // Original implementation
        .per_step => {
            // Initialize step state for external control
            var step_state = MiniStepState.init(self.allocator, params, self) catch |err| {
                return switch (err) {
                    else => ExecutionError.Error.DatabaseCorrupted,
                };
            };
            defer step_state.deinit(self.allocator);
            
            // Store step state for external access
            // Note: This would require adding step_state to Evm struct
            // self.mini_step_state = &step_state;
            
            // Run to completion for per-step mode demonstration
            // In practice, external controller would drive this
            while (!step_state.completed) {
                step_state.step(self);
            }
            
            // Return result based on final state
            const success = if (step_state.execution_error) |err| switch (err) {
                ExecutionError.Error.STOP => true,
                ExecutionError.Error.RETURN => true,
                else => false,
            } else false;
            
            return CallResult{
                .success = success,
                .gas_left = step_state.frame.gas_remaining,
                .output = self.current_output,
            };
        }
    }
}
```

**Key Features of the Mini Per-Step API:**

1. **`execute_single_op()`**: Core stepping function that executes exactly one opcode
   - Handles all opcode types including PUSH, JUMP, JUMPI with correct PC management
   - Returns next PC or appropriate execution error
   - Maintains exact compatibility with full `call_mini` behavior

2. **`MiniStepState`**: Encapsulates stepping state for external control
   - Contains Frame, PC, and execution status
   - Provides `step()` method for single-step advancement
   - Exposes state for comparison via `get_state()`

3. **Perfect Alignment**: Each `execute_single_op()` call corresponds to one primary EVM step
   - Primary EVM pauses via debug hooks 
   - Mini EVM advances via `execute_single_op()`
   - Both engines stay in perfect lockstep

## COMPLETE DEVTOOL DUAL-EXECUTION IMPLEMENTATION (`src/devtool/evm.zig`)

After PR 4, devtool uses tracer-driven execution. PR 6 adds dual-engine mode with comprehensive comparison:

```zig
// src/devtool/evm.zig additions for PR 6

const DebugShadow = @import("evm").DebugShadow;
const MiniStepState = @import("evm").MiniStepState;

/// Comparison execution modes
pub const ComparisonMode = enum { 
    off,      // Single engine execution
    per_call, // Compare final results only  
    per_step  // Step-by-step comparison with pause on mismatch
};

/// Single step comparison data
pub const SideBySideStep = struct {
    step_index: usize,
    
    // Primary EVM state
    primary: struct {
        pc: usize,
        gas_before: u64,
        gas_after: u64, 
        stack_size: usize,
        opcode: u8,
        opcode_name: []const u8,
    },
    
    // Mini EVM state  
    mini: struct {
        pc: usize,
        gas_before: u64,
        gas_after: u64,
        stack_size: usize,
        opcode: u8,
        opcode_name: []const u8,
    },
    
    // Comparison result
    mismatch: ?DebugShadow.ShadowMismatch = null,
    execution_time_ns: u64 = 0, // Performance timing
    
    pub fn init_step(
        step_idx: usize,
        primary_state: anytype,
        mini_state: anytype,
        mismatch: ?DebugShadow.ShadowMismatch
    ) SideBySideStep {
        return .{
            .step_index = step_idx,
            .primary = primary_state,
            .mini = mini_state, 
            .mismatch = mismatch,
        };
    }
    
    pub fn free_mismatch(self: *SideBySideStep, allocator: std.mem.Allocator) void {
        if (self.mismatch) |*m| {
            DebugShadow.free_mismatch(m, allocator);
            self.mismatch = null;
        }
    }
};

/// Complete side-by-side execution results
pub const SideBySideRun = struct {
    mode: ComparisonMode,
    steps: []SideBySideStep,
    
    // Final call results
    final_call_primary: @import("evm").CallResult,
    final_call_mini: @import("evm").CallResult,
    
    // Analysis  
    diverged_at: ?usize = null,      // Step index of first mismatch
    total_steps: usize,
    execution_time_ns: u64 = 0,
    
    // Performance metrics
    primary_gas_used: u64,
    mini_gas_used: u64,
    gas_delta: i64, // mini - primary (negative means mini used less)
    
    pub fn init(
        allocator: std.mem.Allocator,
        mode: ComparisonMode,
        capacity: usize,
        primary_result: @import("evm").CallResult,
        mini_result: @import("evm").CallResult
    ) !SideBySideRun {
        return .{
            .mode = mode,
            .steps = try allocator.alloc(SideBySideStep, capacity),
            .final_call_primary = primary_result,
            .final_call_mini = mini_result,
            .total_steps = 0,
            .primary_gas_used = 0, // Will be calculated
            .mini_gas_used = 0,    // Will be calculated
            .gas_delta = 0,
        };
    }
    
    pub fn deinit(self: *SideBySideRun, allocator: std.mem.Allocator) void {
        // Free all step mismatches
        for (self.steps[0..self.total_steps]) |*step| {
            step.free_mismatch(allocator);
        }
        allocator.free(self.steps);
        
        // Free output buffers if owned by run
        if (self.final_call_primary.output) |output| {
            allocator.free(output);
        }
        if (self.final_call_mini.output) |output| {
            allocator.free(output);
        }
    }
    
    /// Add a step comparison result
    pub fn add_step(self: *SideBySideRun, step: SideBySideStep) void {
        if (self.total_steps < self.steps.len) {
            self.steps[self.total_steps] = step;
            self.total_steps += 1;
            
            // Check for first divergence
            if (self.diverged_at == null and step.mismatch != null) {
                self.diverged_at = step.step_index;
            }
        }
    }
    
    /// Calculate final performance metrics
    pub fn finalize_metrics(self: *SideBySideRun, initial_gas: u64) void {
        self.primary_gas_used = initial_gas - self.final_call_primary.gas_left;
        self.mini_gas_used = initial_gas - self.final_call_mini.gas_left;
        self.gas_delta = @as(i64, @intCast(self.mini_gas_used)) - @as(i64, @intCast(self.primary_gas_used));
    }
};

/// Dual execution context for step-by-step comparison
pub const DualExecutionContext = struct {
    allocator: std.mem.Allocator,
    
    // Primary EVM control
    primary_evm: *@import("evm").Evm,
    primary_hooks: @import("evm").DebugHooks,
    primary_paused: bool = false,
    primary_step_count: usize = 0,
    
    // Mini EVM control  
    mini_state: ?MiniStepState = null,
    mini_step_count: usize = 0,
    
    // Comparison tracking
    current_run: ?*SideBySideRun = null,
    shadow_config: DebugShadow.ShadowConfig,
    max_steps: usize = 10000, // Safety limit
    
    /// Step hook implementation for primary EVM
    pub fn primary_step_hook(
        user_ctx: ?*anyopaque,
        frame: *const @import("evm").Frame,
        pc: usize,
        opcode: u8
    ) anyerror!@import("evm").StepControl {
        const ctx = @as(*DualExecutionContext, @ptrCast(@alignCast(user_ctx.?)));
        
        // Capture primary state before opcode execution
        const primary_gas_before = frame.gas_remaining;
        const primary_stack_size = frame.stack.size();
        
        // Step mini EVM to match
        if (ctx.mini_state) |*mini| {
            mini.step(ctx.primary_evm);
            ctx.mini_step_count += 1;
        }
        
        // Compare states at this step
        if (ctx.current_run) |run| {
            const mini_state = if (ctx.mini_state) |mini| mini.get_state() else .{
                .pc = 0, .gas_remaining = 0, .stack_size = 0, 
                .completed = true, .error = .STOP
            };
            
            // Create step comparison
            const mismatch = if (ctx.mini_state) |mini| blk: {
                break :blk DebugShadow.compare_step(
                    frame,
                    &mini.frame,
                    pc,
                    mini_state.pc,
                    ctx.shadow_config,
                    ctx.primary_step_count,
                    opcode,
                    ctx.allocator
                ) catch null;
            } else null;
            
            const step_data = SideBySideStep.init_step(
                ctx.primary_step_count,
                .{
                    .pc = pc,
                    .gas_before = primary_gas_before,
                    .gas_after = primary_gas_before, // Will be updated post-execution
                    .stack_size = primary_stack_size,
                    .opcode = opcode,
                    .opcode_name = get_opcode_name(opcode),
                },
                .{
                    .pc = mini_state.pc,
                    .gas_before = mini_state.gas_remaining,
                    .gas_after = mini_state.gas_remaining,
                    .stack_size = mini_state.stack_size,
                    .opcode = opcode, // Should be same
                    .opcode_name = get_opcode_name(opcode),
                },
                mismatch
            );
            
            run.add_step(step_data);
            
            // Pause on mismatch for interactive debugging
            if (mismatch != null and ctx.shadow_config.mode == .per_step) {
                std.log.info("Execution mismatch at step {}, PC={}", .{ ctx.primary_step_count, pc });
                return .pause;
            }
        }
        
        ctx.primary_step_count += 1;
        
        // Safety: prevent infinite execution  
        if (ctx.primary_step_count >= ctx.max_steps) {
            std.log.warn("Max steps limit reached: {}", .{ctx.max_steps});
            return .abort;
        }
        
        return .cont;
    }
    
    pub fn get_primary_hooks(self: *DualExecutionContext) @import("evm").DebugHooks {
        return .{
            .user_ctx = @ptrCast(self),
            .on_step = primary_step_hook,
            .on_message = null,
        };
    }
    
    /// Initialize for dual execution
    pub fn init(
        allocator: std.mem.Allocator,
        primary_evm: *@import("evm").Evm
    ) DualExecutionContext {
        return .{
            .allocator = allocator,
            .primary_evm = primary_evm,
            .primary_hooks = undefined, // Set by get_primary_hooks()
            .shadow_config = .{
                .mode = .per_step,
                .skip_identical_steps = false, // Capture all for UI
            },
        };
    }
    
    pub fn deinit(self: *DualExecutionContext) void {
        if (self.mini_state) |*mini| {
            mini.deinit(self.allocator);
        }
    }
};

/// Add to DevtoolEvm struct (existing fields + new additions):
comparison_mode: ComparisonMode = .off,
dual_context: ?DualExecutionContext = null,
last_comparison_run: ?*SideBySideRun = null,

/// Set comparison mode and initialize dual execution if needed
pub fn set_comparison_mode(self: *DevtoolEvm, mode: ComparisonMode) !void {
    self.comparison_mode = mode;
    
    if (mode != .off) {
        // Initialize dual execution context
        if (self.dual_context == null) {
            self.dual_context = DualExecutionContext.init(self.allocator, &self.evm);
        }
    } else {
        // Clean up dual execution
        if (self.dual_context) |*ctx| {
            ctx.deinit();
            self.dual_context = null;
        }
    }
}

/// Execute both engines with final result comparison only
pub fn run_both_per_call(
    self: *DevtoolEvm,
    params: @import("evm").CallParams
) !SideBySideRun {
    const start_time = std.time.nanoTimestamp();
    
    // Run primary EVM
    const primary_result = try self.evm.call(params);
    
    // Run mini EVM  
    const mini_result = try self.evm.call_mini(params);
    
    const end_time = std.time.nanoTimestamp();
    
    // Compare final results
    const final_mismatch = try DebugShadow.compare_call_results(
        primary_result, 
        mini_result, 
        self.allocator
    );
    
    // Create run result
    var run = try SideBySideRun.init(
        self.allocator,
        .per_call,
        1, // Single comparison step
        primary_result,
        mini_result
    );
    
    run.execution_time_ns = @as(u64, @intCast(end_time - start_time));
    run.finalize_metrics(params.call.gas); // Assuming .call variant
    
    if (final_mismatch) |mismatch| {
        // Add single comparison step showing final result mismatch
        const step = SideBySideStep{
            .step_index = 0,
            .primary = .{
                .pc = 0, // Not applicable for per-call
                .gas_before = params.call.gas,
                .gas_after = primary_result.gas_left,
                .stack_size = 0,
                .opcode = 0x00, // STOP equivalent
                .opcode_name = "FINAL",
            },
            .mini = .{
                .pc = 0,
                .gas_before = params.call.gas,
                .gas_after = mini_result.gas_left,
                .stack_size = 0,
                .opcode = 0x00,
                .opcode_name = "FINAL", 
            },
            .mismatch = mismatch,
        };
        run.add_step(step);
    }
    
    return run;
}

/// Execute both engines step-by-step with real-time comparison
pub fn run_both_per_step(
    self: *DevtoolEvm,
    params: @import("evm").CallParams,
    max_steps: usize
) !SideBySideRun {
    if (self.dual_context == null) {
        return error.ComparisonModeNotEnabled;
    }
    
    var ctx = &self.dual_context.?;
    ctx.max_steps = max_steps;
    ctx.primary_step_count = 0;
    ctx.mini_step_count = 0;
    
    // Initialize mini EVM stepping state
    ctx.mini_state = try MiniStepState.init(self.allocator, params, &self.evm);
    errdefer if (ctx.mini_state) |*mini| mini.deinit(self.allocator);
    
    // Create run tracking
    var run = try SideBySideRun.init(
        self.allocator,
        .per_step,
        max_steps,
        .{ .success = false, .gas_left = 0, .output = &.{} }, // Placeholder
        .{ .success = false, .gas_left = 0, .output = &.{} }  // Placeholder
    );
    errdefer run.deinit(self.allocator);
    
    ctx.current_run = &run;
    defer ctx.current_run = null;
    
    // Set debug hooks for primary EVM
    const hooks = ctx.get_primary_hooks();
    self.evm.set_debug_hooks(hooks);
    defer self.evm.clear_debug_hooks();
    
    const start_time = std.time.nanoTimestamp();
    
    // Execute primary with step-by-step pausing
    // The hook will drive mini EVM and capture comparisons
    const primary_result = self.evm.call(params) catch |err| switch (err) {
        @import("evm").ExecutionError.Error.DebugPaused => {
            // Handle paused execution - could implement resume logic
            std.log.info("Execution paused at step {} due to mismatch", .{ctx.primary_step_count});
            return err; // Or create partial result
        },
        @import("evm").ExecutionError.Error.DebugAborted => {
            std.log.warn("Execution aborted at step {}", .{ctx.primary_step_count});
            return err;
        },
        else => return err,
    };
    
    // Get mini final result
    const mini_final = if (ctx.mini_state) |mini| mini.get_state() else .{
        .pc = 0, .gas_remaining = 0, .stack_size = 0, .completed = true, .error = .STOP
    };
    
    const mini_result = @import("evm").CallResult{
        .success = if (mini_final.error) |err| switch (err) {
            .STOP, .RETURN => true,
            else => false,
        } else false,
        .gas_left = mini_final.gas_remaining,
        .output = self.evm.current_output,
    };
    
    const end_time = std.time.nanoTimestamp();
    
    // Update run with final results
    run.final_call_primary = primary_result;
    run.final_call_mini = mini_result;
    run.execution_time_ns = @as(u64, @intCast(end_time - start_time));
    run.finalize_metrics(params.call.gas);
    
    // Clean up mini state
    if (ctx.mini_state) |*mini| {
        mini.deinit(self.allocator);
        ctx.mini_state = null;
    }
    
    return run;
}

/// Helper function for opcode name lookup
fn get_opcode_name(opcode: u8) []const u8 {
    const opcode_mod = @import("evm").Opcode;
    return opcode_mod.name_from_byte(opcode) orelse "UNKNOWN";
}
```

Implementation details:

### Per-call path

1. Build `CallParams` (typically `.call` or `.staticcall`) from the devtool’s loaded bytecode/context
2. Primary: `const res_primary = try evm.call(params);`
3. Mini: `const res_mini = try evm.call_mini(params);`
4. Compare: `const mismatch = try DebugShadow.compare_call_results(res_primary, res_mini, allocator);`
5. Populate `SideBySideRun{ steps = &.{}, final_call_* = ..., diverged_at = if (mismatch != null) 0 else null }`
6. Free any allocations in the mismatch summaries when done

Notes:

- Precompiles are handled by both
- For nested calls via opcodes, step comparison is preferred; per-call compare can be done at `onMessage(.after)` in PR 1 hooks

### Per-step path

Prerequisites: PR 1 hooks integrated; PR 3 Mini per-step API added.

Driver outline:

1. Enable `evm.shadow_mode = .per_step` and set `evm.last_shadow_mismatch = null`
2. Install `DebugHooks` with an `on_step` that returns `.pause` every step
3. Initialize primary call via `evm.call(params)` in a loop that resumes on `DebugPaused`
4. Maintain a Mini frame and program counter
5. On each primary pause:
   - Capture primary state: `pc_primary`, `gas_before/after`, stack depth (from `Frame`)
   - Drive exactly one Mini step: `pc_mini = try execute_single_op(mini_frame, code, pc_mini)`
   - Compare via `DebugShadow.compare_step(primary_frame, mini_frame, pc_primary, pc_mini, cfg, allocator)`
   - If mismatch, set `diverged_at = step_index`, store `last_shadow_mismatch`, and stop unless UI requests continue
6. Repeat until STOP/RETURN/REVERT (primary call completes) or max_steps reached

Primary PC and instruction mapping:

- Primary uses analysis with an instruction pointer (`frame.instruction`) into `analysis.instructions`
- Compute PC from instruction index using `analysis.inst_to_pc[idx]` with fallback logic already present in `src/devtool/evm.zig` serialization code (see mapping in `serializeEvmState`)

Mini PC is the current `pc` used by `execute_single_op`

Gas before/after: capture from `frame.gas_remaining` before/after invoking the opcode (the hook can capture `gas_before` and the step return can expose `gas_after`)

Memory window: optional; if implementing windowed diffs, capture last write span or compute a minimal dirty region.

Storage per-step: optional; if Mini tracks a per-step write set and primary can expose a journal slice for the step, compare keys and new values.

### Exact primary structures you’ll use

- `Frame` (hot fields), see around these fields for reference:

```44:80:src/evm/frame.zig
pub const Frame = struct {
    instruction: *const @import("instruction.zig").Instruction,
    gas_remaining: u64,
    stack: Stack,
    memory: Memory,
    analysis: *const CodeAnalysis,
    depth: u10,
    is_static: bool,
    contract_address: primitives.Address.Address,
    state: DatabaseInterface,
    host: Host,
    caller: primitives.Address.Address,
    value: u256,
    // ...
};
```

- PC mapping hint (already used in devtool): walk `analysis.inst_to_pc` and derive PC when not directly mapped. See `serializeEvmState` in `src/devtool/evm.zig` for the derivation logic.

### JSON for UI (side-by-side)

Add a new endpoint similar to `stepEvmHandler` that returns a JSON payload for the latest step pair and an array buffer when running continuously. Suggested shape:

```json
{
  "mode": "per_step",
  "stepIndex": 12,
  "primary": {
    "pc": 42,
    "gasBefore": 50000,
    "gasAfter": 49970,
    "stackSize": 3
  },
  "mini": { "pc": 42, "gasBefore": 50000, "gasAfter": 49970, "stackSize": 3 },
  "mismatch": {
    "field": "stack",
    "lhs": "top: 0x01, 0x02, ...",
    "rhs": "top: 0x01, 0x03, ..."
  }
}
```

On divergence, keep returning the same index with an attached mismatch until user requests continue/step.

## UI: `ComparisonView.tsx`

Add a new Solid/React-equivalent component that:

- Renders two columns: Primary and Mini
- Header row: opcode name, PC, gas used (delta), stack depth
- Body: minimal hex dumps (stack top N, memory window), color-diffed when mismatch
- Badge row: mismatch field, clickable to expand diff
- Timeline scrubber uses step index; stepping is driven by devtool endpoints

Data flows:

- Fetch state via new devtool endpoints
- Existing `serializeEvmState` remains for the single-engine view
- For dual mode, either extend the existing state or provide a separate endpoint/JSON

## Tests

### Unit/differential tests (Zig)

Add tests under `test/differential/` that compare primary `call()` vs `call_mini()` on simple programs. You can adapt from existing tests; relevant imports and patterns are present in `src/evm/evm/call.zig` test blocks and other files. Suggested cases:

- Arithmetic/control flow: `PUSH1 1; PUSH1 2; ADD; STOP`
- Memory ops: `MSTORE/MLOAD`, ensure return data parity
- Storage ops: `SSTORE/SLOAD` where Mini tracks writes and primary handles journal correctly
- CALL/STATICCALL returning data and gas accounting (may require loading simple runtime code into the `MemoryDatabase`)

Per-step tests:

- Construct tiny bytecode where a known difference can be toggled (e.g., force a different gas delta). Assert `compare_step` returns a mismatch at the exact opcode.

### Devtool headless tests

Add `test/devtool/` for headless runner tests (no UI). Smoke-test `run_both_per_call` and `run_both_per_step` against simple bytecode; assert no mismatch for canonical paths and proper mismatch surface for contrived differences.

## Memory management and Zig patterns

- Ownership:
  - `compare_*` returns optional `ShadowMismatch` with allocated `lhs_summary`/`rhs_summary` → caller frees
  - In Mini per-call, `call_mini` duplicates `current_output` into `mini_output` and resets VM `current_output`; be careful to free on VM deinit
  - In primary per-call, `CallResult.output` is a VM-owned view in `call.zig` (do not free), whereas in CALL-family opcode sites in `system.zig` buffers are freed explicitly after copying to memory
- Use `defer` for in-scope allocations and `errdefer` when transferring ownership
- Casting patterns for hooks and host access:
  - `const evm_ptr = @as(*Evm, @ptrCast(@alignCast(frame.host.ptr)));`
- Nullable function pointers:
  - `if (hooks.on_step) |cb| { ... }`
- Error mapping:
  - Hook errors → `DebugAbort`; pause → `DebugPaused`
- Don’t store frame pointers beyond callback scope; borrows are ephemeral

## Performance considerations

- Guard all debug/hook code with nullable checks and build flags (PR 3 suggests a `build_options.enable_shadow_compare` defaulting on in Debug and off in Release)
- Per-step comparisons should be allocation-light; compare integers directly and only format summaries on mismatch
- For memory diffs, prefer preview windows instead of full dumps

## Common pitfalls

- PC mapping: primary uses analysis; ensure you derive PC correctly from `frame.instruction` + `analysis.inst_to_pc`. See the mapping logic in `src/devtool/evm.zig` (`serializeEvmState`).
- Ownership of `CallResult.output`: in primary `call()`, output is a view into frame buffer; do not free. In `system.zig` handlers, buffers returned from host are freed after copying.
- Don’t modify VM state in comparator; only read and compare
- Ensure snapshots are handled correctly during nested calls in Mini and primary paths

## Step-by-step implementation checklist

1. Ensure PR 1 hooks exist and are wired (on_step/on_message), export types in `src/evm/root.zig`; add `set_debug_hooks()` on `Evm`
2. Land PR 3 comparator with `debug/shadow.zig` and Mini per-step API
3. Devtool:
   - Add `ComparisonMode` and `run_both_per_call`, `run_both_per_step`
   - Add new endpoint in `src/devtool/app.zig` analogous to `stepEvmHandler` returning side-by-side JSON
   - Wire UI to new endpoint (`ComparisonView.tsx`)
4. Tests:
   - Add differential tests for per-call and per-step
   - Add headless devtool smoke tests
5. Build flags:
   - Introduce `build_options.enable_shadow_compare` as in PR 3
6. Run and keep green after every edit:
   - `zig build && zig build test`

## Code references (for quick navigation)

```20:63:src/evm/evm/call_mini.zig
pub inline fn call_mini(self: *Evm, params: CallParams) ExecutionError.Error!CallResult {
    // Simplified execution with PC-based loop; extend with execute_single_op for per-step
}
```

```31:116:src/evm/evm/call.zig
pub inline fn call(self: *Evm, params: CallParams) ExecutionError.Error!CallResult {
    // Analysis-based execution via interpret(); VM-owned output view semantics
}
```

```831:972:src/evm/execution/system.zig
pub fn op_call(context: *anyopaque) ExecutionError.Error!void {
    // Host call, snapshot handling, output copy to memory, buffer free
}
```

```480:761:src/devtool/evm.zig
pub fn stepExecute(self: *DevtoolEvm) !DebugStepResult {
    // Current analysis-first stepping; PR 4 replaces this with tracer-driven hooks
}
```

```1:74:src/devtool/debug_state.zig
pub const DebugState = struct { /* UI capture helpers (opcode name, gas, stack size, etc.) */ };
```

## Example usage (devtool, per-call)

```zig
var run = try self.run_both_per_call(params);
if (run.diverged_at) |idx| {
    // surface mismatch to UI; summaries owned by caller → free after rendering
} else {
    // results equal; show final outputs and gas
}
```

## Acceptance criteria

- per-call mode: identical results for canonical samples (success flag, gas_left, output bytes)
- per-step mode: step indices align; PC, gas deltas, top-of-stack match; mismatches highlighted with compact summaries
- Works with pause/resume and breakpoints; both engines stay in sync by step index
- No allocations or noticeable overhead when comparison mode is off

## Build & test protocol (mandatory)

After every edit, run:

```bash
zig build && zig build test
```

Never proceed with a broken build or failing test.

---

If anything behaves unexpectedly, add logging at the exact execution point and verify assumptions with evidence rather than guessing. Prefer step-by-step tracing through the first divergent opcode.
