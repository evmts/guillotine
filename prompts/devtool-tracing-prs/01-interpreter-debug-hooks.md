## PR 1: Interpreter Debug Hooks (onStep/onMessage) in Core EVM

### Problem

The devtool currently duplicates interpreter logic to step opcodes. We want core-driven stepping with optional callbacks that can pause/inspect execution, and lifecycle hooks for message calls (CALL/CREATE and variants). The tracer today is write-only and cannot pause control flow.

### Goals

- Add optional debug hooks in the interpreter to support stepping and message lifecycle observation without duplicating interpreter logic.
- Zero overhead when hooks are unset.
- Preserve existing semantics for STOP/RETURN/REVERT and error propagation.

### Scope

- Add a `DebugHooks` interface with optional callbacks:
  - `onStep(user_ctx, frame, pc, opcode) -> StepControl` where `StepControl = { continue, pause, abort }`.
  - `onMessage(user_ctx, params, phase)` where `phase = { before, after }` and `params` covers CALL/CREATE metadata.
- Wire hooks in `interpret.zig` before and after opcode dispatch; and in message send/return sites in `execution/system.zig` (CALL-family) and any create paths.
- Hooks must not allocate on hot paths; passing pointers/slices borrowed from current frame is allowed but must be documented as ephemeral.

### Files to Change

- `src/evm/evm/interpret.zig`: inject onStep callbacks at each iteration, respecting `StepControl` (pause/abort). Ensure no extra cost when hooks are null.
- `src/evm/execution/system.zig`: wrap CALL/DELEGATECALL/STATICCALL/CREATE/CREATE2 with `onMessage(before)` and `onMessage(after)`.
- `src/evm/evm.zig`: expose `set_debug_hooks(hooks: ?DebugHooks)` on `Evm`.
- `src/evm/root.zig`: export `DebugHooks`, `StepControl`, `MessagePhase`.

### Proposed API (Zig)

```zig
pub const StepControl = enum { continue, pause, abort };

pub const MessagePhase = enum { before, after };

pub const OnStepFn = *const fn (user_ctx: ?*anyopaque, frame: *Frame, pc: usize, opcode: u8) anyerror!StepControl;
pub const OnMessageFn = *const fn (user_ctx: ?*anyopaque, params: *const CallParams, phase: MessagePhase) anyerror!void;

pub const DebugHooks = struct {
    user_ctx: ?*anyopaque = null,
    on_step: ?OnStepFn = null,
    on_message: ?OnMessageFn = null,
};
```

### Execution Semantics

- If `on_step` returns `pause`, `interpret` should yield control by returning a distinct status (e.g., `ExecutionStatus.Paused`) containing current PC and frame references for resumption. If returning `abort`, unwind with a controlled error `error.DebugAbort`.
- When paused, resumption API should continue from the same PC. This can be implemented by keeping the `Frame` alive and exposing `resume()` on `Evm` that restarts the loop without reinitialization.
- If hooks error, treat as `abort` and propagate `error.DebugAbort`.

### Performance

- Branch on a nullable function pointer only; no allocations.
- Mark hook invocations `inline` guarded by `if (hooks.on_step) |cb|` patterns.

### Tests

- `test/evm/instruction_test.zig`:
  - Step through `PUSH1 PUSH1 ADD STOP` and validate `on_step` receives PCs/opcodes in order and that `pause` pauses execution precisely between steps.
  - Validate `abort` aborts with `error.DebugAbort`.
- `test/evm/opcodes/system_test.zig`:
  - Validate `on_message(before)` and `on_message(after)` fire around CALL and record depth/params.

### Acceptance Criteria

- New APIs compile and are exported via `src/evm/root.zig`.
- All existing tests pass; new tests added for pause/abort/message hooks.
- Zero-overhead when hooks are unset (verified by code inspection; microbench optional).

### Notes

- STOP/RETURN/REVERT semantics unchanged—these still exit via current mechanism; hooks are additive.
- Devtool will consume these hooks in later PRs to drive single-step.

---

## Comprehensive Implementation Guide

### Why this PR exists

The current devtool re-implements stepping logic outside of the core EVM. This adds maintenance cost and can drift from real semantics. We want:

- A per-opcode step hook to observe or pause execution
- A message lifecycle hook around CALL/CREATE-family operations

Both must be zero-overhead when unset and preserve STOP/RETURN/REVERT semantics.

### Codebase Architecture Understanding

#### EVM Execution Architecture
The Guillotine EVM uses a block-based execution model where:

1. **Block-based Execution**: Bytecode is analyzed and transformed into instruction blocks before execution
2. **Hot Path Optimization**: Critical execution paths are optimized for cache performance
3. **Tagged Dispatch**: Instructions are dispatched using a tagged union pattern for efficiency
4. **Memory Layout**: All structs are carefully laid out to optimize cache locality

#### Key Struct Layout (Cache-Optimized)
The `Evm` struct is organized into cache lines:

```zig
// FIRST CACHE LINE (64 bytes) - ULTRA HOT
allocator: std.mem.Allocator,     // 16 bytes
access_list: AccessList,          // 24 bytes 
journal: CallJournal,             // 24 bytes

// SECOND CACHE LINE - STATE MANAGEMENT  
state: EvmState,                  // 16 bytes
created_contracts: CreatedContracts, // 24 bytes
self_destruct: SelfDestruct,      // 24 bytes

// THIRD CACHE LINE - EXECUTION CONTROL
internal_arena: std.heap.ArenaAllocator, // 16 bytes
table: OpcodeMetadata,            // Large struct
depth: u11,                       // 2 bytes
read_only: bool,                  // 1 byte
is_executing: bool,               // 1 byte
// ... additional execution flags

// COLD DATA
tracer: ?std.io.AnyWriter = null, // 16 bytes - debugging only
```

#### Frame Execution Context
```zig
// Frame layout optimized for opcode access patterns
pub const Frame = struct {
    // FIRST CACHE LINE - accessed by every opcode
    gas_remaining: u64,           // 8 bytes
    stack: Stack,                 // 32 bytes
    analysis: *const CodeAnalysis, // 8 bytes
    host: Host,                   // 16 bytes
    
    // SECOND CACHE LINE - memory operations
    memory: Memory,               // 72 bytes
    
    // THIRD CACHE LINE - storage operations  
    state: DatabaseInterface,     // 16 bytes
    contract_address: primitives.Address.Address, // 20 bytes
    depth: u16,                   // 2 bytes
    is_static: bool,              // 1 byte
    
    // Additional context...
};
```

---

## High-level design

- Add `DebugHooks` with optional callbacks:
  - `on_step(user_ctx, frame, pc, opcode) -> StepControl { cont, pause, abort }`
  - `on_message(user_ctx, params, phase)` where `phase ∈ { before, after }`, `params = CallParams`
- Store on `Evm` as `debug_hooks: ?DebugHooks`
- Expose `Evm.set_debug_hooks(hooks: ?DebugHooks)`
- In interpreter, compute `(pc, opcode)` via existing analysis and call `on_step` just before executing the opcode
- In `execution/system.zig`, call `on_message(.before)` before host call, `on_message(.after)` after result
- Pausing returns a dedicated debug pause; resumption continues from same `Frame.instruction`
- Aborting returns a dedicated debug abort

Zero overhead:

- Guarded by nullable function pointer branches
- No allocations

### Understanding the Existing Tracing Pattern

The codebase already has tracing infrastructure we need to mirror:

#### Current Tracing Implementation (interpret.zig:44-73)
```zig
if (comptime build_options.enable_tracing) {
    if (self.tracer) |writer| {
        // Derive index of current instruction for tracing
        const base: [*]const @TypeOf((frame.instruction).*) = instructions.ptr;
        const idx = (@intFromPtr(frame.instruction) - @intFromPtr(base)) / @sizeOf(@TypeOf((frame.instruction).*));
        if (idx < analysis.inst_to_pc.len) {
            const pc_u16 = analysis.inst_to_pc[idx];
            if (pc_u16 != std.math.maxInt(u16)) {
                const pc: usize = pc_u16;
                const opcode: u8 = if (pc < analysis.code_len) analysis.code[pc] else 0x00;
                const stack_len: usize = frame.stack.size();
                const stack_view: []const u256 = frame.stack.data[0..stack_len];
                const gas_cost: u64 = 0; // Block-based validation; per-op gas not tracked here
                const mem_size: usize = frame.memory.size();
                var tr = Tracer.init(writer);
                _ = tr.trace(pc, opcode, stack_view, frame.gas_remaining, gas_cost, mem_size, @intCast(frame.depth)) catch {};
            }
        }
    }
}
```

**Key Insight**: The PC computation pattern is already established. We need to use the exact same pattern for debug hooks.

#### PC Mapping Algorithm Understanding
1. **Instruction Pointer Distance**: Calculate instruction index from pointer arithmetic
2. **PC Lookup**: Use `analysis.inst_to_pc[idx]` to map instruction index to program counter
3. **Opcode Extraction**: Extract original opcode from `analysis.code[pc]`
4. **Validation**: Check bounds with `std.math.maxInt(u16)` sentinel value

This pattern is **performance-critical** and must be replicated exactly for debug hooks.

---

## Where to inject hooks (precise locations)

### Understanding the Interpreter Execution Flow

The interpreter uses a tagged dispatch pattern with these instruction types:

```zig
// From interpret.zig dispatch switch
dispatch: switch (instruction.tag) {
    .block_info => {}, // Gas validation and stack checks for instruction blocks
    .exec => {},       // Execute single opcode function  
    .dynamic_gas => {}, // Execute with dynamic gas calculation
    .noop => {},       // No-operation (optimized away)
    .conditional_jump_invalid => {}, // Invalid conditional jump
    .conditional_jump_pc => {},     // Known conditional jump target
    .jump_pc => {},                // Known jump target
    .jump_unresolved => {},        // Dynamic jump (stack-based)
    .conditional_jump_unresolved => {}, // Dynamic conditional jump
    .word => {},       // Push constant word to stack
    .pc => {},         // PC opcode special handling
}
```

### 1) Interpreter loop: `src/evm/evm/interpret.zig`

#### Hook Injection Points

**CRITICAL**: Debug hooks must be injected in the `pre_step` function or inline in each dispatch case. The pre_step function is called for every instruction type and already computes PC/opcode.

#### Current pre_step Function (interpret.zig:36-73)
```zig
inline fn pre_step(self: *Evm, frame: *Frame, inst: *const Instruction, loop_iterations: *usize) void {
    // Loop iteration safety check
    if (comptime SAFE) {
        loop_iterations.* += 1;
        if (loop_iterations.* > MAX_ITERATIONS) {
            unreachable;
        }
    }

    // EXISTING TRACING - THIS IS WHERE WE ADD DEBUG HOOKS
    if (comptime build_options.enable_tracing) {
        const analysis = frame.analysis;
        if (self.tracer) |writer| {
            // PC/opcode computation - REPLICATE THIS EXACTLY
            const base: [*]const @TypeOf(inst.*) = analysis.instructions.ptr;
            const idx = (@intFromPtr(inst) - @intFromPtr(base)) / @sizeOf(@TypeOf(inst.*));
            if (idx < analysis.inst_to_pc.len) {
                const pc_u16 = analysis.inst_to_pc[idx];
                if (pc_u16 != std.math.maxInt(u16)) {
                    const pc: usize = pc_u16;
                    const opcode: u8 = if (pc < analysis.code_len) frame.analysis.code[pc] else 0x00;
                    // ... tracing logic
                }
            }
        }
    }
}
```

**IMPLEMENTATION STRATEGY**: Add debug hook logic immediately after the tracing block in `pre_step`.

#### Hook Injection Pattern:
```zig
// AFTER existing tracing block, add:
if (self.debug_hooks) |hooks| {
    if (hooks.on_step) |step_fn| {
        const analysis = frame.analysis;
        const base: [*]const @TypeOf(inst.*) = analysis.instructions.ptr;
        const idx = (@intFromPtr(inst) - @intFromPtr(base)) / @sizeOf(@TypeOf(inst.*));
        if (idx < analysis.inst_to_pc.len) {
            const pc_u16 = analysis.inst_to_pc[idx];
            if (pc_u16 != std.math.maxInt(u16)) {
                const pc: usize = pc_u16;
                const opcode: u8 = if (pc < analysis.code_len) frame.analysis.code[pc] else 0x00;
                
                const decision = step_fn(hooks.user_ctx, frame, pc, opcode) catch {
                    // Return debug error - will be caught by caller
                    return; // This becomes problematic - pre_step is void!
                };
                
                // Handle pause/abort - PROBLEM: pre_step returns void!
                // We need to modify the approach...
            }
        }
    }
}
```

**CRITICAL PROBLEM IDENTIFIED**: `pre_step` returns `void`, but we need to handle pause/abort control flow. 

**SOLUTION**: Don't put debug hooks in `pre_step`. Instead, add debug hook calls directly in each dispatch case where error handling is possible.

#### Corrected Hook Injection Strategy

Inject debug hooks directly in the main dispatch cases. For example, in the `.exec` case:

```zig
.exec => {
    @branchHint(.likely);
    pre_step(self, frame, instruction, &loop_iterations); // Existing tracing
    
    // ADD DEBUG HOOKS HERE
    if (self.debug_hooks) |hooks| {
        if (hooks.on_step) |step_fn| {
            const analysis = frame.analysis;
            const base: [*]const Instruction = analysis.instructions.ptr;
            const idx = (@intFromPtr(instruction) - @intFromPtr(base)) / @sizeOf(Instruction);
            if (idx < analysis.inst_to_pc.len) {
                const pc_u16 = analysis.inst_to_pc[idx];
                if (pc_u16 != std.math.maxInt(u16)) {
                    const pc: usize = pc_u16;
                    const opcode: u8 = if (pc < analysis.code_len) frame.analysis.code[pc] else 0x00;
                    
                    const decision = step_fn(hooks.user_ctx, frame, pc, opcode) catch return ExecutionError.Error.DebugAbort;
                    switch (decision) {
                        .cont => {},
                        .pause => return ExecutionError.Error.DebugPaused,
                        .abort => return ExecutionError.Error.DebugAbort,
                    }
                }
            }
        }
    }
    
    // Continue with normal execution
    const exec_inst = analysis.getInstructionParams(.exec, instruction.id);
    const exec_fun = exec_inst.exec_fn;
    const next_instruction = exec_inst.next_inst;
    
    try exec_fun(frame);
    instruction = next_instruction;
    continue :dispatch instruction.tag;
},
```

**PERFORMANCE NOTE**: This pattern must be repeated in all dispatch cases that execute opcodes:
- `.exec` - Single opcode execution
- `.dynamic_gas` - Opcode with dynamic gas calculation  
- `.word` - PUSH operations
- `.pc` - PC opcode

Other cases (`.jump_*`, `.conditional_jump_*`, `.noop`, `.block_info`) don't execute opcodes directly but may still need hooks for debugging control flow.

### 2) Message hooks around CALL-family

#### Understanding the CALL Implementation Pattern

`src/evm/execution/system.zig` contains all CALL-family implementations. Each follows a similar pattern:

1. **Stack Parameter Extraction**: Pop parameters from EVM stack
2. **Validation**: Check static context, depth limits, etc.
3. **Memory Management**: Handle calldata and return data memory
4. **Gas Calculation**: Determine gas limit for call
5. **Snapshot Creation**: Create journal snapshot for revertibility
6. **Host Call**: Execute the actual call via `host.call(call_params)`
7. **Result Handling**: Process return data, update gas, push success flag

#### CALL Implementation Analysis (system.zig:831-972)

```zig
pub fn op_call(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    
    // 1. Stack parameter extraction
    const gas = frame.stack.pop_unsafe();
    const to = frame.stack.pop_unsafe();
    const value = frame.stack.pop_unsafe();
    const args_offset = frame.stack.pop_unsafe();
    const args_size = frame.stack.pop_unsafe();
    const ret_offset = frame.stack.pop_unsafe();
    const ret_size = frame.stack.pop_unsafe();
    
    // 2. Validation
    if (frame.is_static and value != 0) {
        return ExecutionError.Error.WriteProtection;
    }
    if (validate_call_depth(frame)) {
        frame.stack.append_unsafe(0);
        return;
    }
    
    // 3-4. Memory and gas handling...
    
    // 5. Snapshot creation
    const snapshot = frame.host.create_snapshot();
    const host = frame.host;
    
    // 6. CRITICAL HOOK INJECTION POINT: Create call parameters
    const call_params = CallParams{ .call = .{
        .caller = frame.contract_address,
        .to = to_address,
        .value = value,
        .input = args,
        .gas = gas_limit,
    } };
    
    // >>> INSERT on_message(.before) HERE <<<
    
    // 7. Perform the call
    const call_result = host.call(call_params) catch {
        frame.host.revert_to_snapshot(snapshot);
        try frame.stack.append(0);
        return;
    };
    
    // >>> INSERT on_message(.after) HERE <<<
    
    // 8. Result handling...
}
```

#### Hook Injection Points for CALL-family

**Before Hook Location**: Right after `call_params` construction, before `host.call()`
**After Hook Location**: Immediately after successful `host.call()`, before result processing

#### Implementation Pattern for All CALL Operations:

```zig
// BEFORE HOOK (after call_params construction)
const evm_ptr = @as(*Evm, @ptrCast(@alignCast(frame.host.ptr)));
if (evm_ptr.debug_hooks) |hooks| {
    if (hooks.on_message) |msg_fn| {
        msg_fn(hooks.user_ctx, &call_params, .before) catch return ExecutionError.Error.DebugAbort;
    }
}

// Host call
const call_result = host.call(call_params) catch {
    // Error handling
};

// AFTER HOOK (after successful call)
if (evm_ptr.debug_hooks) |hooks| {
    if (hooks.on_message) |msg_fn| {
        msg_fn(hooks.user_ctx, &call_params, .after) catch return ExecutionError.Error.DebugAbort;
    }
}
```

#### All CALL-family Operations to Modify:

1. **`op_call`** (lines ~831-972): Regular CALL with value transfer
2. **`op_callcode`** (lines ~974-1090): CALLCODE (deprecated, execute at current address)
3. **`op_delegatecall`** (lines ~1093-1204): DELEGATECALL (preserve caller context)
4. **`op_staticcall`** (lines ~1207-1300+): STATICCALL (read-only call)

#### Key Differences in CallParams Structure:

```zig
// CallParams union variants (host.zig:7-54)
pub const CallParams = union(enum) {
    call: struct { caller: Address, to: Address, value: u256, input: []const u8, gas: u64 },
    callcode: struct { caller: Address, to: Address, value: u256, input: []const u8, gas: u64 },  
    delegatecall: struct { caller: Address, to: Address, input: []const u8, gas: u64 }, // No value!
    staticcall: struct { caller: Address, to: Address, input: []const u8, gas: u64 },   // No value!
    create: struct { caller: Address, value: u256, init_code: []const u8, gas: u64 },
    create2: struct { caller: Address, value: u256, init_code: []const u8, salt: u256, gas: u64 },
};
```

**IMPORTANT**: DELEGATECALL and STATICCALL don't have value fields - the hook implementation must handle this correctly.

### 3) Message hooks around CREATE-family

#### Understanding CREATE Operations

CREATE and CREATE2 operations also use the host call pattern, but with different parameter structures.

#### CREATE Implementation (system.zig:534-676)

```zig
pub fn op_create(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    
    // Stack extraction and validation...
    
    // Hook injection point - CREATE params
    const call_params = CallParams{ .create = .{
        .caller = frame.contract_address,
        .value = value,
        .init_code = init_code, 
        .gas = gas_for_create,
    } };
    
    // >>> INSERT on_message(.before) HERE <<<
    
    const call_result = host.call(call_params) catch {
        // Error handling
    };
    
    // >>> INSERT on_message(.after) HERE <<<
    
    // Result processing...
}
```

#### CREATE2 Implementation (system.zig:678-828)

```zig
pub fn op_create2(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    
    // Stack extraction and validation...
    
    // Hook injection point - CREATE2 params
    const call_params = CallParams{ .create2 = .{
        .caller = frame.contract_address,
        .value = value,
        .init_code = init_code,
        .salt = salt,
        .gas = gas_for_create,
    } };
    
    // >>> INSERT on_message(.before) HERE <<<
    
    const call_result = host.call(call_params) catch {
        // Error handling
    };
    
    // >>> INSERT on_message(.after) HERE <<<
    
    // Result processing...
}
```

#### CREATE vs CREATE2 Key Differences:

1. **CREATE**: Address determined by `keccak256(deployer, nonce)`
2. **CREATE2**: Address determined by `keccak256(0xff, deployer, salt, keccak256(init_code))`
3. **Stack Parameters**: CREATE2 has additional `salt` parameter
4. **CallParams Structure**: CREATE2 includes salt field

#### All CREATE-family Operations to Modify:

1. **`op_create`** (lines ~534-676): Basic contract creation
2. **`op_create2`** (lines ~678-828): Deterministic contract creation with salt

**Note**: Both CREATE operations follow the same host call pattern as CALL operations, so the same hook injection pattern applies.

### Parameter type for `on_message`

#### CallParams Structure Deep Dive

The `CallParams` type is already exported and used throughout the system. Understanding its structure is critical for hook implementation.

#### Export Location (root.zig:149)
```zig
pub const CallParams = @import("host.zig").CallParams;
```

#### Full CallParams Definition (host.zig:6-54)
```zig
/// Call operation parameters for different call types
pub const CallParams = union(enum) {
    /// Regular CALL operation
    call: struct {
        caller: Address,      // Address making the call
        to: Address,          // Address being called
        value: u256,          // Wei amount to transfer
        input: []const u8,    // Call data
        gas: u64,            // Gas limit
    },
    /// CALLCODE operation: execute external code with current storage/context
    callcode: struct {
        caller: Address,      // Address making the call
        to: Address,          // Address of code to execute
        value: u256,          // Wei amount to transfer
        input: []const u8,    // Call data
        gas: u64,            // Gas limit
    },
    /// DELEGATECALL operation (preserves caller context)
    delegatecall: struct {
        caller: Address,      // Original caller, not current contract
        to: Address,          // Address of code to execute
        input: []const u8,    // Call data (no value field!)
        gas: u64,            // Gas limit
    },
    /// STATICCALL operation (read-only)
    staticcall: struct {
        caller: Address,      // Address making the call
        to: Address,          // Address being called
        input: []const u8,    // Call data (no value field!)
        gas: u64,            // Gas limit
    },
    /// CREATE operation
    create: struct {
        caller: Address,      // Address creating the contract
        value: u256,          // Wei amount to send to new contract
        init_code: []const u8, // Constructor bytecode
        gas: u64,            // Gas limit
    },
    /// CREATE2 operation
    create2: struct {
        caller: Address,      // Address creating the contract
        value: u256,          // Wei amount to send to new contract
        init_code: []const u8, // Constructor bytecode
        salt: u256,          // Salt for deterministic address
        gas: u64,            // Gas limit
    },
};
```

#### Critical Implementation Details:

1. **Union Type**: `CallParams` is a tagged union - only one variant is active at a time
2. **Address Type**: Uses `primitives.Address.Address` (20-byte Ethereum address)
3. **Memory Lifetimes**: `input` and `init_code` slices are borrowed - valid only during hook execution
4. **Value Handling**: Only `call`, `callcode`, `create`, and `create2` have value fields
5. **Gas Units**: All gas values are `u64` in wei units

#### Hook Implementation Considerations:

```zig
// Example hook implementation handling different call types
fn on_message_impl(user_ctx: ?*anyopaque, params: *const CallParams, phase: MessagePhase) anyerror!void {
    switch (params.*) {
        .call => |call_data| {
            // call_data.caller, call_data.to, call_data.value, call_data.input, call_data.gas
        },
        .delegatecall => |del_data| {
            // del_data.caller, del_data.to, del_data.input, del_data.gas
            // Note: No value field!
        },
        .create => |create_data| {
            // create_data.caller, create_data.value, create_data.init_code, create_data.gas
        },
        // ... handle other variants
    }
}
```

**WARNING**: The `input` and `init_code` slices are only valid during the hook call. Do not store these pointers beyond the hook execution - they point to temporary memory that may be freed or reused.

---

## API to add

### 1. Create `src/evm/debug_hooks.zig`

This file will contain all debug hook types and interfaces.

```zig
//! Debug hooks for EVM execution tracing and control
//!
//! This module provides callback interfaces for debugging and development tools
//! to observe and control EVM execution without modifying core execution logic.
//!
//! ## Zero-Overhead Design
//!
//! - All hooks are guarded by nullable function pointer checks
//! - No memory allocations in hot paths
//! - Hooks receive borrowed references with ephemeral lifetimes
//! - Comptime optimization eliminates hook overhead when disabled
//!
//! ## Usage
//!
//! ```zig
//! const evm_mod = @import("evm");
//! 
//! fn my_step_hook(ctx: ?*anyopaque, frame: *evm_mod.Frame, pc: usize, opcode: u8) anyerror!evm_mod.StepControl {
//!     std.log.info("Executing opcode 0x{x:0>2} at PC {}", .{ opcode, pc });
//!     return .cont;
//! }
//! 
//! fn my_message_hook(ctx: ?*anyopaque, params: *const evm_mod.CallParams, phase: evm_mod.MessagePhase) anyerror!void {
//!     switch (phase) {
//!         .before => std.log.info("Starting call...", .{}),
//!         .after => std.log.info("Call completed", .{}),
//!     }
//! }
//! 
//! var hooks = evm_mod.DebugHooks{
//!     .on_step = my_step_hook,
//!     .on_message = my_message_hook,
//! };
//! evm.set_debug_hooks(hooks);
//! ```

const std = @import("std");
const Frame = @import("frame.zig").Frame;
const CallParams = @import("host.zig").CallParams;

/// Control flow decision for step hooks
pub const StepControl = enum {
    /// Continue execution normally
    cont,
    /// Pause execution and return control to caller
    /// Execution can be resumed by calling the EVM again
    pause,
    /// Abort execution immediately with DebugAbort error
    abort,
};

/// Message call lifecycle phase
pub const MessagePhase = enum {
    /// Called before host.call() is invoked
    before,
    /// Called after host.call() returns (success or failure)
    after,
};

/// Step hook function signature
/// 
/// Called before each opcode execution with current execution context.
/// 
/// **Parameters:**
/// - `user_ctx`: Optional user-provided context pointer
/// - `frame`: Current execution frame (borrowed reference - do not store!)
/// - `pc`: Program counter (bytecode offset) 
/// - `opcode`: Raw opcode byte being executed
/// 
/// **Returns:**
/// - `StepControl` indicating whether to continue, pause, or abort
/// 
/// **Error Handling:**
/// - Any error returned will be converted to `DebugAbort`
/// 
/// **Lifetime Constraints:**
/// - Frame pointer is only valid during hook execution
/// - Do not store frame or any pointers derived from it
/// - Memory contents may change after hook returns
pub const OnStepFn = *const fn (
    user_ctx: ?*anyopaque,
    frame: *Frame,
    pc: usize,
    opcode: u8,
) anyerror!StepControl;

/// Message hook function signature
/// 
/// Called before and after CALL/CREATE family operations.
/// 
/// **Parameters:**
/// - `user_ctx`: Optional user-provided context pointer  
/// - `params`: Call parameters (borrowed reference - do not store!)
/// - `phase`: Whether this is before or after the call
/// 
/// **Error Handling:**
/// - Any error returned will be converted to `DebugAbort`
/// 
/// **Lifetime Constraints:**
/// - CallParams pointer is only valid during hook execution
/// - Input/init_code slices within params are ephemeral
/// - Do not store any pointers from params beyond hook execution
pub const OnMessageFn = *const fn (
    user_ctx: ?*anyopaque,
    params: *const CallParams,
    phase: MessagePhase,
) anyerror!void;

/// Debug hooks configuration
/// 
/// Contains optional callback functions for debugging EVM execution.
/// All fields are optional - only non-null hooks will be invoked.
/// 
/// **Zero-Overhead Guarantee:**
/// - When debug_hooks is null on Evm, no performance impact
/// - When individual hooks are null, minimal branch overhead
/// - No memory allocations in hook infrastructure
/// 
/// **Thread Safety:**
/// - Hooks are called from the same thread as EVM execution
/// - User is responsible for any thread synchronization in hook implementations
/// - Do not call EVM methods from within hooks (undefined behavior)
pub const DebugHooks = struct {
    /// Optional user context passed to all hook functions
    /// Useful for maintaining state across hook invocations
    user_ctx: ?*anyopaque = null,
    
    /// Step hook - called before each opcode execution
    /// Set to null to disable step debugging
    on_step: ?OnStepFn = null,
    
    /// Message hook - called before/after CALL/CREATE operations
    /// Set to null to disable message tracing
    on_message: ?OnMessageFn = null,
    
    /// Create DebugHooks with step debugging only
    pub fn step_only(step_fn: OnStepFn, ctx: ?*anyopaque) DebugHooks {
        return DebugHooks{
            .user_ctx = ctx,
            .on_step = step_fn,
        };
    }
    
    /// Create DebugHooks with message tracing only
    pub fn message_only(msg_fn: OnMessageFn, ctx: ?*anyopaque) DebugHooks {
        return DebugHooks{
            .user_ctx = ctx,
            .on_message = msg_fn,
        };
    }
    
    /// Create DebugHooks with both step and message hooks
    pub fn full(step_fn: OnStepFn, msg_fn: OnMessageFn, ctx: ?*anyopaque) DebugHooks {
        return DebugHooks{
            .user_ctx = ctx,
            .on_step = step_fn,
            .on_message = msg_fn,
        };
    }
};

// Compile-time validation
comptime {
    // Ensure function pointers have expected size
    std.debug.assert(@sizeOf(OnStepFn) == @sizeOf(*const fn() void));
    std.debug.assert(@sizeOf(OnMessageFn) == @sizeOf(*const fn() void));
    
    // Ensure DebugHooks has reasonable size (should fit in cache line)
    std.debug.assert(@sizeOf(DebugHooks) <= 64);
}
```

### 2. Export in `src/evm/root.zig`

Add these exports after the existing exports (around line 225):

```zig
/// Debug hooks for EVM execution tracing and stepping
pub const debug_hooks = @import("debug_hooks.zig");
pub const DebugHooks = debug_hooks.DebugHooks;
pub const StepControl = debug_hooks.StepControl;
pub const MessagePhase = debug_hooks.MessagePhase;
pub const OnStepFn = debug_hooks.OnStepFn;
pub const OnMessageFn = debug_hooks.OnMessageFn;
```

### 3. Add to `src/evm/evm.zig`

#### Add field to Evm struct (after line 119, with other cold data):

```zig
// === DEBUG AND DEVELOPMENT ===
/// Optional debug hooks for development and debugging tools
/// When null, zero performance overhead
/// Placed in cold section as debug hooks are rarely used in production
debug_hooks: ?@import("debug_hooks.zig").DebugHooks = null,
```

#### Add setter method (after other public methods):

```zig
/// Set debug hooks for execution tracing and control
/// 
/// **Parameters:**
/// - `hooks`: Debug hooks configuration, or null to disable
/// 
/// **Performance Impact:**
/// - When hooks is null: Zero overhead
/// - When hooks is non-null but individual callbacks are null: Minimal branch overhead
/// - When callbacks are set: Overhead proportional to hook implementation
/// 
/// **Thread Safety:**
/// - This method is not thread-safe
/// - Must be called when EVM is not executing
/// - Hooks will be used by subsequent EVM executions on the same thread
pub fn set_debug_hooks(self: *Evm, hooks: ?@import("debug_hooks.zig").DebugHooks) void {
    self.debug_hooks = hooks;
}

/// Get current debug hooks configuration (for introspection)
pub fn get_debug_hooks(self: *const Evm) ?@import("debug_hooks.zig").DebugHooks {
    return self.debug_hooks;
}

/// Check if debug stepping is enabled
pub fn is_step_debugging_enabled(self: *const Evm) bool {
    return self.debug_hooks != null and self.debug_hooks.?.on_step != null;
}

/// Check if message tracing is enabled  
pub fn is_message_tracing_enabled(self: *const Evm) bool {
    return self.debug_hooks != null and self.debug_hooks.?.on_message != null;
}
```

### 4. Update Evm.init() (around line 243)

Add debug_hooks initialization:

```zig
// In the Evm struct initialization:
.debug_hooks = null, // Add this line
```

#### Type Safety and Error Handling

**CRITICAL**: The debug hook infrastructure must handle errors gracefully:

```zig
// Error mapping in hook calls
const decision = step_fn(hooks.user_ctx, frame, pc, opcode) catch |err| switch (err) {
    error.OutOfMemory => return ExecutionError.Error.OutOfMemory,
    else => return ExecutionError.Error.DebugAbort,
};
```

This ensures that hook errors are properly categorized and don't crash the EVM.

---

## Interpreter integration details

### Understanding Interpreter Control Flow

The interpreter uses a complex tagged dispatch system. Understanding this is critical for proper hook integration.

#### Dispatch Loop Structure (interpret.zig:120-321)

```zig
pub fn interpret(self: *Evm, frame: *Frame) ExecutionError.Error!void {
    // Initialization...
    var instruction: *const Instruction = &frame.analysis.instructions[0];
    var loop_iterations: usize = 0;
    const analysis = frame.analysis;

    dispatch: switch (instruction.tag) {
        .block_info => {
            // Gas and stack validation for instruction blocks
            pre_step(self, frame, instruction, &loop_iterations);
            // ... validation logic
            instruction = block_inst.next_inst;
            continue :dispatch instruction.tag;
        },
        .exec => {
            // Single opcode execution - MAIN HOOK INJECTION POINT
            @branchHint(.likely);
            pre_step(self, frame, instruction, &loop_iterations);
            
            // >>> DEBUG HOOKS GO HERE <<<
            
            const exec_inst = analysis.getInstructionParams(.exec, instruction.id);
            const exec_fun = exec_inst.exec_fn;
            const next_instruction = exec_inst.next_inst;
            
            try exec_fun(frame); // This calls the actual opcode function
            instruction = next_instruction;
            continue :dispatch instruction.tag;
        },
        .dynamic_gas => {
            // Opcode with dynamic gas calculation - ALSO NEEDS HOOKS
            // ... similar pattern
        },
        .word => {
            // PUSH operations - ALSO NEEDS HOOKS
            // ... push constant to stack
        },
        // ... other instruction types
    }
}
```

### Hook Injection Strategy

#### Problem with pre_step Approach
The `pre_step` function is `inline` and returns `void`, making error handling impossible. We need a different approach.

#### Solution: Direct Injection in Dispatch Cases

Inject hooks directly in each dispatch case that executes user opcodes:

```zig
.exec => {
    @branchHint(.likely);
    pre_step(self, frame, instruction, &loop_iterations); // Existing tracing
    
    // DEBUG HOOK INJECTION
    if (self.debug_hooks) |hooks| {
        if (hooks.on_step) |step_fn| {
            // Use same PC computation as tracing (critical for correctness)
            const base: [*]const Instruction = analysis.instructions.ptr;
            const idx = (@intFromPtr(instruction) - @intFromPtr(base)) / @sizeOf(Instruction);
            if (idx < analysis.inst_to_pc.len) {
                const pc_u16 = analysis.inst_to_pc[idx];
                if (pc_u16 != std.math.maxInt(u16)) {
                    const pc: usize = pc_u16;
                    const opcode: u8 = if (pc < analysis.code_len) frame.analysis.code[pc] else 0x00;
                    
                    const decision = step_fn(hooks.user_ctx, frame, pc, opcode) catch |err| switch (err) {
                        error.OutOfMemory => return ExecutionError.Error.OutOfMemory,
                        else => return ExecutionError.Error.DebugAbort,
                    };
                    
                    switch (decision) {
                        .cont => {}, // Continue normal execution
                        .pause => return ExecutionError.Error.DebugPaused,
                        .abort => return ExecutionError.Error.DebugAbort,
                    }
                }
            }
        }
    }
    
    // Continue with normal opcode execution
    const exec_inst = analysis.getInstructionParams(.exec, instruction.id);
    const exec_fun = exec_inst.exec_fn;
    const next_instruction = exec_inst.next_inst;
    
    try exec_fun(frame);
    instruction = next_instruction;
    continue :dispatch instruction.tag;
},
```

#### Hook Injection Locations

This pattern must be repeated in these dispatch cases:

1. **`.exec`** - Most common case, executes single opcodes
2. **`.dynamic_gas`** - Opcodes with runtime gas calculation
3. **`.word`** - PUSH operations (PUSH1-PUSH32)
4. **`.pc`** - PC opcode special case

Other cases (jumps, control flow) may not need hooks, or may need specialized handling.

#### Performance-Critical Details

1. **Branch Prediction**: `@branchHint(.likely)` on common paths
2. **Cache Optimization**: Group null checks to minimize cache misses
3. **Inlining**: Keep hook checks inline to avoid call overhead
4. **Error Path**: Optimize for successful execution, error handling is cold

### Error Type Additions

#### Add to ExecutionError.Error (execution_error.zig)

Add these two new error types after the existing errors (around line 100+):

```zig
/// Debug hook requested execution abort
/// This is a controlled termination for debugging purposes
/// Should be handled by the debugging tool, not treated as an error
DebugAbort,

/// Debug hook requested execution pause
/// Execution can be resumed by calling interpret() again
/// The current frame state is preserved for resumption
DebugPaused,
```

#### Error Handling Semantics

**DebugPaused Behavior:**
- Current instruction pointer is NOT advanced
- Frame state is preserved completely
- Resumption calls `interpret(self, frame)` again
- Execution continues from the same opcode

**DebugAbort Behavior:**
- Execution terminates immediately
- Frame state is preserved for inspection
- No automatic cleanup beyond normal error handling

#### Resumption Implementation

```zig
// In calling code (e.g., devtool)
const result = evm.interpret(frame);
switch (result) {
    ExecutionError.Error.DebugPaused => {
        // Handle pause - UI interaction, inspection, etc.
        // Frame is still valid and can be resumed
        
        // Resume when user chooses to continue
        try evm.interpret(frame); // Continues from same instruction
    },
    ExecutionError.Error.DebugAbort => {
        // Handle abort - cleanup, show state, etc.
        return; // Don't continue execution
    },
    else => |err| return err, // Normal error handling
}
```

### Critical Implementation Notes

1. **PC Calculation**: Must use exactly the same algorithm as tracing for consistency
2. **Error Mapping**: Hook errors must be properly categorized  
3. **Frame Preservation**: Pause must not modify frame state
4. **Thread Safety**: Hooks are called on same thread as execution
5. **Memory Lifetime**: All pointers passed to hooks are ephemeral

### Testing Considerations

```zig
// Test pattern for debug hooks
test "debug hooks step execution" {
    var step_count: u32 = 0;
    
    fn test_step_hook(ctx: ?*anyopaque, frame: *Frame, pc: usize, opcode: u8) anyerror!StepControl {
        const counter = @ptrCast(*u32, @alignCast(@alignOf(u32), ctx.?));
        counter.* += 1;
        
        // Pause on 3rd instruction
        if (counter.* == 3) return .pause;
        return .cont;
    }
    
    var hooks = DebugHooks{ 
        .user_ctx = &step_count,
        .on_step = test_step_hook,
    };
    
    evm.set_debug_hooks(hooks);
    
    const result = evm.interpret(frame);
    try expect(result == ExecutionError.Error.DebugPaused);
    try expect(step_count == 3);
    
    // Resume execution
    hooks.on_step = null; // Disable stepping
    evm.set_debug_hooks(hooks);
    try evm.interpret(frame); // Should complete normally
}
```

---

## Message integration details

### Understanding Host Interface Architecture

#### EVM-to-Host Connection
The `Frame.host` field contains a `Host` interface that points back to the `Evm` instance:

```zig
// Host struct (host.zig:76-81)
pub const Host = struct {
    ptr: *anyopaque,        // Points to Evm instance
    vtable: *const VTable,  // Function pointer table
};
```

#### Getting Evm Instance from Frame
```zig
// This pattern is used throughout system.zig
const evm_ptr = @as(*Evm, @ptrCast(@alignCast(frame.host.ptr)));
```

**CRITICAL**: This cast is the standard way to access the Evm instance from opcode handlers. It's used extensively in the existing codebase and is safe.

### Hook Integration Pattern for All CALL/CREATE Operations

#### Template for Hook Injection

```zig
// Generic pattern for all op_* functions in system.zig
pub fn op_call(context: *anyopaque) ExecutionError.Error!void {
    const frame = @as(*Frame, @ptrCast(@alignCast(context)));
    
    // ... parameter extraction and validation ...
    
    // Create call parameters
    const call_params = CallParams{ .call = .{
        .caller = frame.contract_address,
        .to = to_address,
        .value = value,
        .input = args,
        .gas = gas_limit,
    } };
    
    // GET EVM INSTANCE FOR DEBUG HOOKS
    const evm_ptr = @as(*Evm, @ptrCast(@alignCast(frame.host.ptr)));
    
    // BEFORE HOOK
    if (evm_ptr.debug_hooks) |hooks| {
        if (hooks.on_message) |msg_fn| {
            msg_fn(hooks.user_ctx, &call_params, .before) catch |err| switch (err) {
                error.OutOfMemory => return ExecutionError.Error.OutOfMemory,
                else => return ExecutionError.Error.DebugAbort,
            };
        }
    }
    
    // PERFORM HOST CALL
    const call_result = host.call(call_params) catch {
        frame.host.revert_to_snapshot(snapshot);
        try frame.stack.append(0);
        return;
    };
    
    // AFTER HOOK (before result processing)
    if (evm_ptr.debug_hooks) |hooks| {
        if (hooks.on_message) |msg_fn| {
            msg_fn(hooks.user_ctx, &call_params, .after) catch |err| switch (err) {
                error.OutOfMemory => return ExecutionError.Error.OutOfMemory,
                else => return ExecutionError.Error.DebugAbort,
            };
        }
    }
    
    // ... result processing and cleanup ...
}
```

### Specific Integration Points

#### 1. op_call (system.zig:831-972)

**Before Hook Location**: After line 926 (after `call_params` construction)
**After Hook Location**: After line 934 (after successful `host.call`)

```zig
// Around line 926 - BEFORE HOOK
const call_params = CallParams{ .call = .{
    .caller = frame.contract_address,
    .to = to_address,
    .value = value,
    .input = args,
    .gas = gas_limit,
} };

const evm_ptr = @as(*Evm, @ptrCast(@alignCast(frame.host.ptr)));
if (evm_ptr.debug_hooks) |hooks| {
    if (hooks.on_message) |msg_fn| {
        msg_fn(hooks.user_ctx, &call_params, .before) catch |err| switch (err) {
            error.OutOfMemory => return ExecutionError.Error.OutOfMemory,
            else => return ExecutionError.Error.DebugAbort,
        };
    }
}

// Perform the call using the host's call method
const call_result = host.call(call_params) catch {
    // On error, revert the snapshot and push 0 (failure)
    frame.host.revert_to_snapshot(snapshot);
    try frame.stack.append(0);
    return;
};

// Around line 934 - AFTER HOOK  
if (evm_ptr.debug_hooks) |hooks| {
    if (hooks.on_message) |msg_fn| {
        msg_fn(hooks.user_ctx, &call_params, .after) catch |err| switch (err) {
            error.OutOfMemory => return ExecutionError.Error.OutOfMemory,
            else => return ExecutionError.Error.DebugAbort,
        };
    }
}
```

#### 2. op_callcode (system.zig:974-1091)

**CallParams Structure**: Same as `op_call` but with different execution context

```zig
const call_params = CallParams{ .callcode = .{
    .caller = frame.contract_address,
    .to = to_address,
    .value = value,
    .input = args,
    .gas = gas_limit,
} };
```

#### 3. op_delegatecall (system.zig:1093-1204)

**CallParams Structure**: No value field (DELEGATECALL doesn't transfer value)

```zig
const call_params = CallParams{ .delegatecall = .{
    .caller = frame.caller, // Preserve original caller!
    .to = to_address,
    .input = args,
    .gas = gas_limit,
} };
```

**CRITICAL**: DELEGATECALL preserves the original caller from the frame, not the current contract address.

#### 4. op_staticcall (system.zig:1207-1300+)

**CallParams Structure**: No value field (STATICCALL is read-only)

```zig
const call_params = CallParams{ .staticcall = .{
    .caller = frame.contract_address,
    .to = to_address,
    .input = args,
    .gas = gas_limit,
} };
```

#### 5. op_create (system.zig:534-676)

**CallParams Structure**: Uses init_code instead of input

```zig
const call_params = CallParams{ .create = .{
    .caller = frame.contract_address,
    .value = value,
    .init_code = init_code,
    .gas = gas_for_create,
} };
```

#### 6. op_create2 (system.zig:678-828)

**CallParams Structure**: Includes salt for deterministic address

```zig
const call_params = CallParams{ .create2 = .{
    .caller = frame.contract_address,
    .value = value,
    .init_code = init_code,
    .salt = salt,
    .gas = gas_for_create,
} };
```

### Memory Management and Lifetime Issues

#### Buffer Management in CALL operations

**CRITICAL**: Some operations allocate and free output buffers. Hooks must be called BEFORE cleanup:

```zig
// From op_call around line 965
if (call_result.output) |out_buf| {
    const evm_ptr = @as(*Evm, @ptrCast(@alignCast(frame.host.ptr)));
    evm_ptr.allocator.free(out_buf); // Buffer freed here!
}
```

**SOLUTION**: After hooks must be called BEFORE this cleanup:

```zig
// AFTER HOOK - must come before buffer cleanup
if (evm_ptr.debug_hooks) |hooks| {
    if (hooks.on_message) |msg_fn| {
        msg_fn(hooks.user_ctx, &call_params, .after) catch |err| switch (err) {
            error.OutOfMemory => return ExecutionError.Error.OutOfMemory,
            else => return ExecutionError.Error.DebugAbort,
        };
    }
}

// THEN cleanup (existing code)
if (call_result.output) |out_buf| {
    const evm_ptr = @as(*Evm, @ptrCast(@alignCast(frame.host.ptr)));
    evm_ptr.allocator.free(out_buf);
}
```

### Error Handling Strategy

#### Hook Error Classification

```zig
msg_fn(hooks.user_ctx, &call_params, .before) catch |err| switch (err) {
    // Preserve critical errors
    error.OutOfMemory => return ExecutionError.Error.OutOfMemory,
    error.OutOfGas => return ExecutionError.Error.OutOfGas,
    
    // Map all other hook errors to DebugAbort
    else => return ExecutionError.Error.DebugAbort,
};
```

#### Snapshot Handling with Hook Errors

**IMPORTANT**: If hooks fail, we must still handle snapshots correctly:

```zig
// Before hook can fail - snapshot already created
if (evm_ptr.debug_hooks) |hooks| {
    if (hooks.on_message) |msg_fn| {
        msg_fn(hooks.user_ctx, &call_params, .before) catch |err| {
            // Revert snapshot on hook failure
            frame.host.revert_to_snapshot(snapshot);
            try frame.stack.append(0);
            
            switch (err) {
                error.OutOfMemory => return ExecutionError.Error.OutOfMemory,
                else => return ExecutionError.Error.DebugAbort,
            }
        };
    }
}
```

### Testing Considerations

#### Message Hook Test Pattern

```zig
test "message hooks capture CALL operations" {
    var before_calls: u32 = 0;
    var after_calls: u32 = 0;
    
    fn test_msg_hook(ctx: ?*anyopaque, params: *const CallParams, phase: MessagePhase) anyerror!void {
        const counters = @ptrCast(*[2]u32, @alignCast(@alignOf([2]u32), ctx.?));
        
        switch (phase) {
            .before => {
                counters[0] += 1;
                // Verify params are correct for operation type
                switch (params.*) {
                    .call => |call_data| {
                        // Validate call parameters
                    },
                    else => unreachable, // Should be call type
                }
            },
            .after => {
                counters[1] += 1;
            },
        }
    }
    
    var counters = [2]u32{0, 0};
    var hooks = DebugHooks{
        .user_ctx = &counters,
        .on_message = test_msg_hook,
    };
    
    evm.set_debug_hooks(hooks);
    
    // Execute contract with CALL operation
    const result = try evm.call_contract(/* ... */);
    
    try expect(counters[0] == 1); // One before hook
    try expect(counters[1] == 1); // One after hook
}
```

### Performance Optimization

#### Minimize Hook Overhead

1. **Early Exit**: Check `debug_hooks` first, then individual hook pointers
2. **Cache EVM Pointer**: Compute `evm_ptr` once per function if calling multiple hooks
3. **Error Path Optimization**: Make hook success the fast path
4. **Inline Hint**: Consider `@inline` for hook wrapper functions if profiling shows benefit

```zig
// Optimized pattern for functions with multiple potential hook calls
const evm_ptr = @as(*Evm, @ptrCast(@alignCast(frame.host.ptr)));
const hooks = evm_ptr.debug_hooks; // Cache debug_hooks

if (hooks) |h| {
    if (h.on_message) |msg_fn| {
        // Before hook
    }
}

// ... call execution ...

if (hooks) |h| {
    if (h.on_message) |msg_fn| {
        // After hook  
    }
}
```

This pattern reduces redundant pointer chasing and null checks.

---

## Types you'll interact with

### Understanding Critical Data Structures

#### Frame Structure (Complete Layout)

The `Frame` is the core execution context. Understanding its layout is critical for hook implementation:

```zig
/// Frame represents the entire execution state of the EVM as it executes opcodes
/// Layout optimized for actual opcode access patterns and cache performance
pub const Frame = struct {
    // === FIRST CACHE LINE (64 bytes) - ULTRA HOT ===
    // Every single instruction accesses these fields
    gas_remaining: u64,                    // 8 bytes - checked/consumed by every opcode
    stack: Stack,                          // 32 bytes - accessed by every opcode (4 pointers)
    analysis: *const CodeAnalysis,         // 8 bytes - control flow (JUMP/JUMPI validation)
    host: Host,                           // 16 bytes - needed for hardfork checks, gas costs
    
    // === SECOND CACHE LINE - MEMORY OPERATIONS ===
    memory: Memory,                        // 72 bytes - MLOAD/MSTORE/MCOPY/LOG*/KECCAK256
    
    // === THIRD CACHE LINE - STORAGE OPERATIONS ===
    // SLOAD/SSTORE access these together
    state: DatabaseInterface,              // 16 bytes
    contract_address: primitives.Address.Address, // 20 bytes
    depth: u16,                           // 2 bytes - for reentrancy checks
    is_static: bool,                      // 1 byte - for SSTORE restrictions
    // 3 bytes padding
    
    // === FOURTH CACHE LINE - CALL CONTEXT ===
    // Primarily used during CALL/CREATE operations
    caller: primitives.Address.Address,    // 20 bytes
    value: u256,                          // 32 bytes
    
    // Per-frame I/O buffers exposed via Host
    input_buffer: []const u8 = &.{},      // Input data slice
    output_buffer: []const u8 = &.{},     // Output data slice
    
    // Methods you'll use in hooks...
    pub fn consume_gas(self: *Frame, amount: u64) ExecutionError.Error!void { /* ... */ }
    pub fn valid_jumpdest(self: *Frame, dest: u256) bool { /* ... */ }
};
```

#### Key Frame Fields for Hook Implementation

**Execution State:**
- `gas_remaining: u64` - Current gas remaining
- `depth: u16` - Call depth (0 = top level, increments with CALL/CREATE)
- `is_static: bool` - Whether this is a static (read-only) call context

**Memory and Stack:**
- `stack: Stack` - EVM execution stack (max 1024 u256 values)
- `memory: Memory` - Byte-addressable memory (grows as needed)

**Contract Context:**
- `contract_address: primitives.Address.Address` - Address of current contract
- `caller: primitives.Address.Address` - Address that called this contract
- `value: u256` - Wei value sent with the call

**Analysis and Host:**
- `analysis: *const CodeAnalysis` - Bytecode analysis results
- `host: Host` - Interface back to EVM for external operations

#### Stack Structure (stack/stack.zig)

```zig
pub const Stack = struct {
    /// Maximum stack depth per EVM specification
    pub const CAPACITY: usize = 1024;
    
    /// Stack data storage - exactly 1024 u256 values (32KB total)
    data: []u256,
    
    /// Current stack size (number of items, not bytes)
    len: u16,
    
    /// Get current stack size
    pub fn size(self: *const Stack) usize { return self.len; }
    
    /// Push value (with bounds checking)
    pub fn append(self: *Stack, value: u256) StackError!void { /* ... */ }
    
    /// Push value (no bounds checking - used in hot paths after validation)
    pub fn append_unsafe(self: *Stack, value: u256) void { /* ... */ }
    
    /// Pop value (with bounds checking)
    pub fn pop(self: *Stack) StackError!u256 { /* ... */ }
    
    /// Pop value (no bounds checking - used in hot paths after validation)
    pub fn pop_unsafe(self: *Stack) u256 { /* ... */ }
};
```

#### Memory Structure (memory/memory.zig)

```zig
pub const Memory = struct {
    /// Initial memory capacity (4KB)
    pub const INITIAL_CAPACITY: usize = 4 * 1024;
    
    /// Default memory limit (for gas calculation)
    pub const DEFAULT_MEMORY_LIMIT: usize = 128 * 1024 * 1024; // 128MB
    
    /// Current memory size (in bytes)
    pub fn size(self: *const Memory) usize { /* ... */ }
    
    /// Read slice from memory
    pub fn get_slice(self: *const Memory, offset: usize, length: usize) ![]const u8 { /* ... */ }
    
    /// Write data to memory
    pub fn set_data_bounded(self: *Memory, offset: usize, data: []const u8, data_offset: usize, length: usize) !void { /* ... */ }
};
```

### Instruction and PC mapping

#### Understanding the Block-Based Execution Model

The EVM uses a sophisticated block-based execution system that transforms bytecode into optimized instruction blocks.

#### Instruction Structure (instruction.zig)

```zig
/// Tagged instruction for block-based execution
/// Uses tagged union for efficient dispatch
pub const Instruction = struct {
    /// Instruction type tag for dispatch
    tag: Tag,
    
    /// Instruction ID for parameter lookup
    id: u16,
    
    /// Instruction type tags
    pub const Tag = enum {
        block_info,              // Gas/stack validation block
        exec,                   // Single opcode execution
        dynamic_gas,            // Opcode with dynamic gas calculation
        noop,                   // No-operation (optimized away)
        conditional_jump_invalid, // Invalid conditional jump destination
        conditional_jump_pc,     // Known conditional jump destination
        jump_pc,                // Known jump destination
        jump_unresolved,        // Dynamic jump (stack-based destination)
        conditional_jump_unresolved, // Dynamic conditional jump
        word,                   // PUSH constant word
        pc,                     // PC opcode special case
    };
    
    /// Compile-time instruction templates
    pub const STOP: Instruction = .{ .tag = .exec, .id = 0 };
    pub const INVALID: Instruction = .{ .tag = .exec, .id = 1 };
    // ... more predefined instructions
};
```

#### PC Mapping Algorithm (CRITICAL for Hook Implementation)

The PC (Program Counter) mapping is complex but essential for debug hooks:

```zig
// From interpret.zig tracing block - THIS IS THE CANONICAL IMPLEMENTATION
const analysis = frame.analysis;

// 1. Get instruction array base pointer
const base: [*]const Instruction = analysis.instructions.ptr;

// 2. Calculate instruction index from pointer arithmetic
const idx = (@intFromPtr(instruction) - @intFromPtr(base)) / @sizeOf(Instruction);

// 3. Bounds check
if (idx < analysis.inst_to_pc.len) {
    // 4. Look up PC from instruction index
    const pc_u16 = analysis.inst_to_pc[idx];
    
    // 5. Check for valid PC (sentinel value check)
    if (pc_u16 != std.math.maxInt(u16)) {
        const pc: usize = pc_u16;
        
        // 6. Extract original opcode from bytecode
        const opcode: u8 = if (pc < analysis.code_len) 
            frame.analysis.code[pc] 
        else 
            0x00; // Default to STOP if out of bounds
        
        // pc and opcode are now available for hooks
    }
}
```

#### Why This Algorithm is Complex

1. **Block Transformation**: Original bytecode is analyzed and transformed into instruction blocks
2. **Instruction Indexing**: Each transformed instruction has an index in the `instructions` array
3. **PC Mapping**: The `inst_to_pc` array maps instruction indices back to original bytecode offsets
4. **Sentinel Values**: `std.math.maxInt(u16)` indicates invalid/unmappable instructions
5. **Bounds Safety**: Multiple bounds checks prevent crashes on malformed bytecode

#### CodeAnalysis Structure

```zig
/// Bytecode analysis results
pub const CodeAnalysis = struct {
    /// Original bytecode
    code: []const u8,
    
    /// Original bytecode length
    code_len: usize,
    
    /// Transformed instruction array
    instructions: []Instruction,
    
    /// Mapping from instruction index to PC
    inst_to_pc: []u16,
    
    /// Mapping from PC to instruction block start
    pc_to_block_start: []u16,
    
    /// Jump destination validation
    jumpdest_array: JumpdestArray,
    
    // ... other analysis data
};
```

#### Critical Implementation Notes

1. **Pointer Arithmetic Safety**: The instruction index calculation uses pointer difference and size division
2. **Bounds Checking**: Multiple layers of bounds checking prevent array access violations
3. **Sentinel Handling**: `std.math.maxInt(u16)` is used as "invalid" marker throughout
4. **Performance**: This calculation is done for every hook invocation - it must be fast
5. **Consistency**: Hook implementations MUST use this exact algorithm for PC calculation

#### Debug Hook PC Calculation Template

```zig
// Template for PC calculation in debug hooks
// MUST be identical to tracing implementation
inline fn calculate_pc_and_opcode(frame: *Frame, instruction: *const Instruction) struct { pc: usize, opcode: u8 } {
    const analysis = frame.analysis;
    const base: [*]const Instruction = analysis.instructions.ptr;
    const idx = (@intFromPtr(instruction) - @intFromPtr(base)) / @sizeOf(Instruction);
    
    if (idx < analysis.inst_to_pc.len) {
        const pc_u16 = analysis.inst_to_pc[idx];
        if (pc_u16 != std.math.maxInt(u16)) {
            const pc: usize = pc_u16;
            const opcode: u8 = if (pc < analysis.code_len) analysis.code[pc] else 0x00;
            return .{ .pc = pc, .opcode = opcode };
        }
    }
    
    // Fallback for invalid mappings
    return .{ .pc = 0, .opcode = 0x00 };
}
```

**CRITICAL**: This PC calculation must be identical in all hook injection points to ensure consistent behavior with tracing.

### CallParams (Complete Understanding)

#### CallParams Union Structure (host.zig:6-54)

```zig
/// Call operation parameters for different call types
pub const CallParams = union(enum) {
    /// Regular CALL operation (0xF1)
    /// Transfers value, executes at target address with target's storage
    call: struct {
        caller: Address,      // Address making the call (msg.sender)
        to: Address,          // Address being called (target contract)
        value: u256,          // Wei amount to transfer
        input: []const u8,    // Call data (function selector + parameters)
        gas: u64,            // Gas limit for the call
    },
    
    /// CALLCODE operation (0xF2) - DEPRECATED
    /// Like CALL but executes code at caller's address with caller's storage
    callcode: struct {
        caller: Address,      // Address making the call
        to: Address,          // Address of code to execute (but at caller's address)
        value: u256,          // Wei amount to transfer
        input: []const u8,    // Call data
        gas: u64,            // Gas limit
    },
    
    /// DELEGATECALL operation (0xF4)
    /// Preserves original caller context (msg.sender, msg.value)
    /// No value transfer, executes at current address with current storage
    delegatecall: struct {
        caller: Address,      // ORIGINAL caller (not current contract!)
        to: Address,          // Address of code to execute
        input: []const u8,    // Call data (NO VALUE FIELD!)
        gas: u64,            // Gas limit
        // NOTE: value preserved from parent call context
    },
    
    /// STATICCALL operation (0xFA)
    /// Read-only call - no state changes allowed
    staticcall: struct {
        caller: Address,      // Address making the call
        to: Address,          // Address being called
        input: []const u8,    // Call data (NO VALUE FIELD!)
        gas: u64,            // Gas limit
        // NOTE: value is implicitly 0 for static calls
    },
    
    /// CREATE operation (0xF0)
    /// Deploy new contract with CREATE address calculation
    create: struct {
        caller: Address,      // Address creating the contract (deployer)
        value: u256,          // Wei amount to send to new contract
        init_code: []const u8, // Constructor bytecode (init code)
        gas: u64,            // Gas limit for deployment
        // Address calculated as: keccak256(deployer, nonce)
    },
    
    /// CREATE2 operation (0xF5)
    /// Deploy new contract with deterministic address
    create2: struct {
        caller: Address,      // Address creating the contract (deployer)
        value: u256,          // Wei amount to send to new contract
        init_code: []const u8, // Constructor bytecode (init code)
        salt: u256,          // Salt for deterministic address calculation
        gas: u64,            // Gas limit for deployment
        // Address calculated as: keccak256(0xff, deployer, salt, keccak256(init_code))
    },
};
```

#### Address Type Details

```zig
// primitives.Address.Address is a 20-byte Ethereum address
pub const Address = struct {
    bytes: [20]u8,
    
    pub const ZERO: Address = Address{ .bytes = [_]u8{0} ** 20 };
    
    pub fn eql(self: Address, other: Address) bool {
        return std.mem.eql(u8, &self.bytes, &other.bytes);
    }
    
    pub fn format(self: Address, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        // Formats as 0x1234...abcd
    }
};
```

#### Memory Lifetime and Safety

**CRITICAL SAFETY REQUIREMENTS:**

1. **Ephemeral Slices**: `input` and `init_code` slices are only valid during hook execution
2. **No Storage**: Never store these slice pointers beyond hook return
3. **Copy If Needed**: If hook needs to retain data, copy to owned memory
4. **Stack Allocated**: CallParams struct itself is stack-allocated and safe to access

#### Hook Implementation Pattern

```zig
fn example_message_hook(user_ctx: ?*anyopaque, params: *const CallParams, phase: MessagePhase) anyerror!void {
    switch (params.*) {
        .call => |call_data| {
            std.log.info("CALL: {} -> {}, value={}, gas={}", .{
                call_data.caller, call_data.to, call_data.value, call_data.gas
            });
            
            // Safe: accessing stack-allocated data
            if (call_data.input.len > 4) {
                const selector = std.mem.readInt(u32, call_data.input[0..4], .big);
                std.log.info("Function selector: 0x{x:0>8}", .{selector});
            }
            
            // UNSAFE: Don't do this!
            // global_input_ptr = call_data.input.ptr; // WILL CRASH LATER!
        },
        
        .delegatecall => |del_data| {
            // Note: no value field in delegatecall
            std.log.info("DELEGATECALL: {} -> {}, gas={}", .{
                del_data.caller, del_data.to, del_data.gas
            });
        },
        
        .create => |create_data| {
            std.log.info("CREATE: deployer={}, value={}, init_code_len={}", .{
                create_data.caller, create_data.value, create_data.init_code.len
            });
            
            // Safe: reading init code during hook
            if (create_data.init_code.len > 0) {
                const first_opcode = create_data.init_code[0];
                std.log.info("First opcode in init code: 0x{x:0>2}", .{first_opcode});
            }
        },
        
        .create2 => |create2_data| {
            std.log.info("CREATE2: deployer={}, salt=0x{x}, init_code_len={}", .{
                create2_data.caller, create2_data.salt, create2_data.init_code.len
            });
        },
        
        .staticcall => |static_data| {
            // Note: no value field in staticcall (implicitly 0)
            std.log.info("STATICCALL: {} -> {}, gas={}", .{
                static_data.caller, static_data.to, static_data.gas
            });
        },
        
        .callcode => |code_data| {
            // CALLCODE is deprecated but still supported
            std.log.info("CALLCODE: {} -> {}, value={}", .{
                code_data.caller, code_data.to, code_data.value
            });
        },
    }
}
```

#### Gas Units and Limits

- All gas values are in **wei units**
- `gas` field represents the **gas limit** allocated to the operation
- Actual gas consumption may be less than the limit
- Gas accounting is handled by the EVM, not by hooks

#### Phase-Based Hook Behavior

**Before Phase (`.before`)**:
- Called after parameters are constructed but before host call
- All parameters are valid and represent intended operation
- Can be used to log, validate, or modify debugging state
- Errors will abort the operation

**After Phase (`.after`)**:
- Called after host call completes (success or failure)
- Parameters are still valid but represent completed operation
- Can be used to log results, update debugging state
- Errors will abort current execution but won't affect call result

#### Advanced Hook Usage

```zig
// Example: Track call depth and gas usage
const CallTracker = struct {
    depth: u32 = 0,
    gas_used: u64 = 0,
    
    fn track_message(self: *CallTracker, params: *const CallParams, phase: MessagePhase) anyerror!void {
        switch (phase) {
            .before => {
                self.depth += 1;
                const gas_limit = switch (params.*) {
                    inline else => |data| data.gas,
                };
                std.log.info("[DEPTH {}] Starting call with gas limit {}", .{ self.depth, gas_limit });
            },
            .after => {
                defer self.depth -= 1;
                std.log.info("[DEPTH {}] Call completed", .{self.depth});
            },
        }
    }
};

var tracker = CallTracker{};
var hooks = DebugHooks{
    .user_ctx = &tracker,
    .on_message = CallTracker.track_message,
};
```

---

## Performance and safety constraints

### Zero-Overhead Design Requirements

#### Branch Prediction Optimization
```zig
// CORRECT: Optimize for common case (no debug hooks)
if (self.debug_hooks) |hooks| { // Likely to be null in production
    if (hooks.on_step) |step_fn| { // Only check if hooks exist
        // Hook execution (rare path)
    }
}
```

#### Memory Access Patterns
1. **Cache Efficiency**: Debug hooks are in cold section of Evm struct
2. **Minimal Indirection**: Only one level of pointer indirection for hooks
3. **Grouped Checks**: Check both hook existence and callback in same conditional block

#### Performance Measurement
```zig
// Before/after performance test pattern
const start = std.time.nanoTimestamp();
// Execute with/without hooks
const end = std.time.nanoTimestamp();
const overhead_ns = end - start;
```

### Memory Safety Constraints

#### Strict Lifetime Rules

**Rule 1: No Pointer Storage Beyond Hook Execution**
```zig
// SAFE: Use data during hook execution
fn safe_hook(ctx: ?*anyopaque, frame: *Frame, pc: usize, opcode: u8) anyerror!StepControl {
    const stack_size = frame.stack.size(); // Safe: immediate use
    const gas = frame.gas_remaining;       // Safe: value copy
    return .cont;
}

// UNSAFE: Storing pointers
var global_frame_ptr: *Frame = undefined; // NEVER DO THIS!
fn unsafe_hook(ctx: ?*anyopaque, frame: *Frame, pc: usize, opcode: u8) anyerror!StepControl {
    global_frame_ptr = frame; // WILL CRASH! Frame may be freed after hook
    return .cont;
}
```

**Rule 2: Slice Data is Ephemeral**
```zig
fn message_hook(ctx: ?*anyopaque, params: *const CallParams, phase: MessagePhase) anyerror!void {
    switch (params.*) {
        .call => |call_data| {
            // SAFE: Immediate use
            const input_len = call_data.input.len;
            
            // SAFE: Copy if needed for later use
            const allocator = get_allocator_somehow();
            const owned_copy = try allocator.dupe(u8, call_data.input);
            defer allocator.free(owned_copy);
            
            // UNSAFE: Storing slice pointer
            // global_input_slice = call_data.input; // WILL CRASH!
        },
    }
}
```

### Execution Semantics Preservation

#### STOP/RETURN/REVERT Unchanged

**Critical Requirement**: Normal termination opcodes must work exactly as before:

```zig
// Debug hooks must not interfere with these execution results:
// - ExecutionError.Error.STOP (0x00 opcode)
// - ExecutionError.Error.RETURN (0xF3 opcode)  
// - ExecutionError.Error.REVERT (0xFD opcode)
// - ExecutionError.Error.INVALID (0xFE opcode)

// Hook implementation must pass these through unchanged:
if (execution_result == ExecutionError.Error.STOP) {
    // Debug hooks should NOT convert this to DebugAbort or DebugPaused
    return execution_result; // Pass through unchanged
}
```

#### Instruction Pointer Management

**Pause Semantics**: When `StepControl.pause` is returned:

1. **Do NOT advance instruction pointer**
2. **Preserve all frame state exactly**
3. **Return `DebugPaused` immediately**
4. **Next `interpret()` call continues from same instruction**

```zig
// CORRECT pause implementation:
switch (decision) {
    .pause => {
        // Do NOT do: instruction = next_instruction;
        return ExecutionError.Error.DebugPaused;
    },
    .cont => {
        // Continue with normal execution
        try exec_fun(frame);
        instruction = next_instruction; // Only advance on continue
    },
}
```

### Error Handling and Propagation

#### Hook Error Classification

```zig
// CORRECT error handling pattern
const decision = step_fn(hooks.user_ctx, frame, pc, opcode) catch |err| switch (err) {
    // Preserve system-critical errors
    error.OutOfMemory => return ExecutionError.Error.OutOfMemory,
    error.OutOfGas => return ExecutionError.Error.OutOfGas,
    
    // Convert debug-specific errors
    error.UserAbortRequested => return ExecutionError.Error.DebugAbort,
    error.BreakpointHit => return ExecutionError.Error.DebugPaused,
    
    // Default: convert unknown hook errors to DebugAbort
    else => return ExecutionError.Error.DebugAbort,
};
```

#### Snapshot Management with Hook Errors

**Critical**: Hook failures must not corrupt EVM state:

```zig
// In CALL-family operations:
const snapshot = frame.host.create_snapshot();

// BEFORE hook with proper cleanup
if (evm_ptr.debug_hooks) |hooks| {
    if (hooks.on_message) |msg_fn| {
        msg_fn(hooks.user_ctx, &call_params, .before) catch |err| {
            // Clean up on hook failure
            frame.host.revert_to_snapshot(snapshot);
            try frame.stack.append(0); // Push failure
            
            return switch (err) {
                error.OutOfMemory => ExecutionError.Error.OutOfMemory,
                else => ExecutionError.Error.DebugAbort,
            };
        };
    }
}

// Continue with host call...
```

### Thread Safety and Reentrancy

#### Single-Thread Assumption

**Current Limitation**: EVM assumes single-threaded execution:

```zig
// From evm.zig - thread tracking
initial_thread_id: std.Thread.Id,

// Enforced in interpret()
self.require_one_thread(); // Asserts same thread as initialization
```

**Hook Requirements**:
- Hooks are called on same thread as EVM execution
- Hooks must not call EVM methods (undefined behavior)
- Hooks must not spawn threads that access EVM state
- User responsible for any synchronization in hook implementation

#### Reentrancy Prevention

```zig
// FORBIDDEN: Don't call EVM from hooks
fn bad_hook(ctx: ?*anyopaque, frame: *Frame, pc: usize, opcode: u8) anyerror!StepControl {
    const evm_ptr = get_evm_somehow();
    // NEVER DO THIS - will deadlock or corrupt state!
    const result = evm_ptr.call_contract(/* ... */); 
    return .cont;
}

// CORRECT: Only observe and modify hook-local state
fn good_hook(ctx: ?*anyopaque, frame: *Frame, pc: usize, opcode: u8) anyerror!StepControl {
    var state = @ptrCast(*HookState, @alignCast(@alignOf(HookState), ctx.?));
    state.instruction_count += 1;
    
    if (state.should_pause_at_count == state.instruction_count) {
        return .pause;
    }
    return .cont;
}
```

### Performance Testing and Validation

#### Zero-Overhead Verification

```zig
// Performance test template
test "debug hooks zero overhead when disabled" {
    const iterations = 1_000_000;
    
    // Test without hooks
    evm.set_debug_hooks(null);
    const start_no_hooks = std.time.nanoTimestamp();
    for (0..iterations) |_| {
        try evm.execute_single_opcode();
    }
    const time_no_hooks = std.time.nanoTimestamp() - start_no_hooks;
    
    // Test with hooks but null callbacks
    var empty_hooks = DebugHooks{}; // All callbacks null
    evm.set_debug_hooks(empty_hooks);
    const start_null_hooks = std.time.nanoTimestamp();
    for (0..iterations) |_| {
        try evm.execute_single_opcode();
    }
    const time_null_hooks = std.time.nanoTimestamp() - start_null_hooks;
    
    // Overhead should be minimal (< 5%)
    const overhead_percent = (time_null_hooks - time_no_hooks) * 100 / time_no_hooks;
    try expect(overhead_percent < 5);
}
```

#### Memory Leak Detection

```zig
test "debug hooks no memory leaks" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){}; 
    defer _ = gpa.detectLeaks(); // Will fail test if leaks detected
    const allocator = gpa.allocator();
    
    // Test with hooks that might leak
    var hooks = DebugHooks{ .on_step = test_step_hook };
    evm.set_debug_hooks(hooks);
    
    // Execute many operations
    try execute_complex_contract(evm);
    
    evm.set_debug_hooks(null);
    // gpa.detectLeaks() called by defer - will catch any leaks
}
```

### Debugging the Debug Hooks

#### Common Implementation Mistakes

1. **PC Calculation Wrong**: Use exact algorithm from tracing
2. **Instruction Pointer Not Preserved**: Don't advance on pause
3. **Error Mapping Incorrect**: Preserve system errors, map others to DebugAbort
4. **Memory Lifetime Violations**: Don't store ephemeral pointers
5. **Performance Impact**: Guard with null checks, use branch hints

#### Validation Checklist

- [ ] PC calculation matches tracing exactly
- [ ] Pause preserves instruction pointer
- [ ] Abort returns DebugAbort error
- [ ] Continue executes opcode normally
- [ ] STOP/RETURN/REVERT semantics unchanged
- [ ] No memory allocations in hook infrastructure
- [ ] No pointer storage beyond hook execution
- [ ] Error mapping preserves system errors
- [ ] Snapshot cleanup on hook failures
- [ ] Performance overhead < 5% when hooks disabled

---

## Exact edits checklist

1. Create `src/evm/debug_hooks.zig` with `StepControl`, `MessagePhase`, `OnStepFn`, `OnMessageFn`, `DebugHooks`
2. Export types in `src/evm/root.zig`
3. Add `debug_hooks` field and `set_debug_hooks` to `src/evm/evm.zig`
4. Add `DebugAbort` and `DebugPaused` in `src/evm/execution/execution_error.zig`
5. Wire `on_step` in `src/evm/evm/interpret.zig`
6. Wire `on_message` in `src/evm/execution/system.zig` for CALL/CALLCODE/DELEGATECALL/STATICCALL/CREATE/CREATE2

---

## Testing plan

### on_step sequencing and pause

- Program: `PUSH1 0x01; PUSH1 0x02; ADD; STOP`
- Verify `on_step` receives `[PUSH1, PUSH1, ADD, STOP]` with correct PCs
- Pause on `ADD`: expect `error.DebugPaused`; resume and finish
- Abort on `ADD`: expect `error.DebugAbort`

### on_message before/after

- CALL: verify `.before` and `.after` phases with expected params
- CREATE/CREATE2: verify phases around creation
- STATICCALL: verify phases and no state changes

Hooks unset: no behavior change. Hook error: map to `DebugAbort`.

---

## Zig patterns (quick reference)

- Nullable function pointers

  ```zig
  if (hooks.on_step) |cb| {
      const res = cb(hooks.user_ctx, frame, pc, opcode) catch return ExecutionError.Error.DebugAbort;
  }
  ```

- anyopaque

  - Use `*anyopaque` for opaque contexts; cast back with `@ptrCast(@alignCast(...))` only when you own the pointer

- Error handling

  - Map hook errors to `DebugAbort`

- Keep hot paths lean; no allocations or formatting

---

## Example usage (consumer)

```zig
const evm_mod = @import("evm");
const DebugHooks = evm_mod.DebugHooks;
const StepControl = evm_mod.StepControl;

fn on_step(_: ?*anyopaque, _: *evm_mod.Frame, _: usize, _: u8) anyerror!StepControl { return .cont; }
fn on_message(_: ?*anyopaque, _: *const evm_mod.CallParams, _: evm_mod.MessagePhase) anyerror!void {}

var hooks = DebugHooks{ .on_step = on_step, .on_message = on_message };
vm.set_debug_hooks(hooks);
```

---

## Acceptance criteria

### Code Quality Requirements

#### API Export Validation
- [ ] `DebugHooks` exported from `src/evm/root.zig`
- [ ] `StepControl` exported from `src/evm/root.zig`
- [ ] `MessagePhase` exported from `src/evm/root.zig`
- [ ] `OnStepFn` exported from `src/evm/root.zig`
- [ ] `OnMessageFn` exported from `src/evm/root.zig`
- [ ] `Evm.set_debug_hooks()` method available
- [ ] `Evm.get_debug_hooks()` method available
- [ ] All types properly documented with doc comments

#### Hook Injection Verification
- [ ] Step hooks in `.exec` dispatch case
- [ ] Step hooks in `.dynamic_gas` dispatch case
- [ ] Step hooks in `.word` dispatch case
- [ ] Step hooks in `.pc` dispatch case
- [ ] Message hooks in `op_call` before/after host call
- [ ] Message hooks in `op_callcode` before/after host call
- [ ] Message hooks in `op_delegatecall` before/after host call
- [ ] Message hooks in `op_staticcall` before/after host call
- [ ] Message hooks in `op_create` before/after host call
- [ ] Message hooks in `op_create2` before/after host call

#### Error Type Implementation
- [ ] `ExecutionError.Error.DebugAbort` added
- [ ] `ExecutionError.Error.DebugPaused` added
- [ ] Error documentation explains debug-specific semantics
- [ ] Error mapping preserves system errors (OutOfMemory, OutOfGas)
- [ ] Hook errors properly converted to DebugAbort

### Functional Testing Requirements

#### Step Hook Testing
```zig
test "step hook sequence validation" {
    // Program: PUSH1 0x01; PUSH1 0x02; ADD; STOP
    const bytecode = [_]u8{ 0x60, 0x01, 0x60, 0x02, 0x01, 0x00 };
    
    var step_log = std.ArrayList(struct { pc: usize, opcode: u8 }).init(allocator);
    defer step_log.deinit();
    
    fn record_steps(ctx: ?*anyopaque, frame: *Frame, pc: usize, opcode: u8) anyerror!StepControl {
        var log = @ptrCast(*std.ArrayList(struct { pc: usize, opcode: u8 }), @alignCast(@alignOf(*anyopaque), ctx.?));
        try log.append(.{ .pc = pc, .opcode = opcode });
        return .cont;
    }
    
    var hooks = DebugHooks{ .user_ctx = &step_log, .on_step = record_steps };
    evm.set_debug_hooks(hooks);
    
    try evm.execute(bytecode);
    
    // Validate exact sequence: PUSH1, PUSH1, ADD, STOP
    try expect(step_log.items.len == 4);
    try expect(step_log.items[0].pc == 0 and step_log.items[0].opcode == 0x60); // PUSH1
    try expect(step_log.items[1].pc == 2 and step_log.items[1].opcode == 0x60); // PUSH1
    try expect(step_log.items[2].pc == 4 and step_log.items[2].opcode == 0x01); // ADD
    try expect(step_log.items[3].pc == 5 and step_log.items[3].opcode == 0x00); // STOP
}

test "step hook pause and resume" {
    var step_count: u32 = 0;
    
    fn pause_on_third(ctx: ?*anyopaque, frame: *Frame, pc: usize, opcode: u8) anyerror!StepControl {
        const counter = @ptrCast(*u32, @alignCast(@alignOf(u32), ctx.?));
        counter.* += 1;
        if (counter.* == 3) return .pause;
        return .cont;
    }
    
    var hooks = DebugHooks{ .user_ctx = &step_count, .on_step = pause_on_third };
    evm.set_debug_hooks(hooks);
    
    const result = evm.execute(bytecode);
    try expectError(ExecutionError.Error.DebugPaused, result);
    try expect(step_count == 3);
    
    // Resume execution
    hooks.on_step = null; // Disable stepping
    evm.set_debug_hooks(hooks);
    try evm.execute(bytecode); // Should complete normally
}

test "step hook abort" {
    fn always_abort(ctx: ?*anyopaque, frame: *Frame, pc: usize, opcode: u8) anyerror!StepControl {
        return .abort;
    }
    
    var hooks = DebugHooks{ .on_step = always_abort };
    evm.set_debug_hooks(hooks);
    
    const result = evm.execute(bytecode);
    try expectError(ExecutionError.Error.DebugAbort, result);
}
```

#### Message Hook Testing
```zig
test "message hook CALL operations" {
    var before_count: u32 = 0;
    var after_count: u32 = 0;
    var call_type: ?CallParams.Tag = null;
    
    fn track_calls(ctx: ?*anyopaque, params: *const CallParams, phase: MessagePhase) anyerror!void {
        const counters = @ptrCast(*struct { before: *u32, after: *u32, call_type: *?CallParams.Tag }, @alignCast(@alignOf(*anyopaque), ctx.?));
        
        switch (phase) {
            .before => {
                counters.before.* += 1;
                counters.call_type.* = std.meta.activeTag(params.*);
                
                // Validate parameters based on call type
                switch (params.*) {
                    .call => |call_data| {
                        try expect(call_data.caller.bytes != [_]u8{0} ** 20);
                        try expect(call_data.to.bytes != [_]u8{0} ** 20);
                        try expect(call_data.gas > 0);
                    },
                    else => {},
                }
            },
            .after => {
                counters.after.* += 1;
            },
        }
    }
    
    var context = .{ .before = &before_count, .after = &after_count, .call_type = &call_type };
    var hooks = DebugHooks{ .user_ctx = &context, .on_message = track_calls };
    evm.set_debug_hooks(hooks);
    
    // Execute contract that makes a CALL
    const calling_contract = compile_contract_with_call();
    try evm.execute(calling_contract);
    
    try expect(before_count == 1);
    try expect(after_count == 1);
    try expect(call_type.? == .call);
}

test "message hook CREATE operations" {
    var create_params: ?CallParams = null;
    
    fn capture_create(ctx: ?*anyopaque, params: *const CallParams, phase: MessagePhase) anyerror!void {
        if (phase == .before) {
            const storage = @ptrCast(*?CallParams, @alignCast(@alignOf(?CallParams), ctx.?));
            storage.* = params.*; // Safe to copy struct (not slices!)
        }
    }
    
    var hooks = DebugHooks{ .user_ctx = &create_params, .on_message = capture_create };
    evm.set_debug_hooks(hooks);
    
    // Execute CREATE operation
    const creator_contract = compile_contract_with_create();
    try evm.execute(creator_contract);
    
    try expect(create_params != null);
    switch (create_params.?) {
        .create => |create_data| {
            try expect(create_data.value == 0); // No value in test
            try expect(create_data.gas > 0);
        },
        else => unreachable,
    }
}
```

### Performance Requirements

#### Zero-Overhead Validation
```zig
test "zero overhead when hooks disabled" {
    const iterations = 100_000;
    const simple_bytecode = [_]u8{ 0x60, 0x01, 0x60, 0x02, 0x01, 0x00 }; // PUSH1 1, PUSH1 2, ADD, STOP
    
    // Baseline: no hooks
    evm.set_debug_hooks(null);
    const start_baseline = std.time.nanoTimestamp();
    for (0..iterations) |_| {
        try evm.execute(simple_bytecode);
        evm.reset_state();
    }
    const time_baseline = std.time.nanoTimestamp() - start_baseline;
    
    // Test: hooks struct but null callbacks
    var empty_hooks = DebugHooks{};
    evm.set_debug_hooks(empty_hooks);
    const start_empty = std.time.nanoTimestamp();
    for (0..iterations) |_| {
        try evm.execute(simple_bytecode);
        evm.reset_state();
    }
    const time_empty = std.time.nanoTimestamp() - start_empty;
    
    // Overhead should be < 5%
    const overhead_percent = (time_empty - time_baseline) * 100 / time_baseline;
    try expect(overhead_percent < 5);
}
```

### Regression Testing Requirements

#### Existing Test Compatibility
- [ ] All existing unit tests pass
- [ ] All existing integration tests pass
- [ ] All existing differential tests pass
- [ ] ERC20 benchmark tests still pass
- [ ] Official EVM benchmark suite still passes
- [ ] No performance degradation in benchmarks

#### Test Coverage Requirements

```bash
# Must achieve minimum test coverage
zig build test-coverage
# Debug hooks code must have >95% line coverage
# Integration points must have >90% line coverage
```

### Documentation Requirements

#### API Documentation
- [ ] All public types have comprehensive doc comments
- [ ] Usage examples in doc comments
- [ ] Safety and lifetime constraints documented
- [ ] Performance characteristics documented
- [ ] Error conditions documented

#### Implementation Documentation
- [ ] Hook injection points documented in code
- [ ] PC calculation algorithm documented
- [ ] Error handling strategy documented
- [ ] Memory lifetime rules documented
- [ ] Thread safety assumptions documented

### Integration Testing

#### Real-World Usage Simulation
```zig
test "devtool integration pattern" {
    // Simulate how the devtool will actually use debug hooks
    var execution_trace = ExecutionTrace.init(allocator);
    defer execution_trace.deinit();
    
    var breakpoints = std.ArrayList(usize).init(allocator);
    defer breakpoints.deinit();
    try breakpoints.append(10); // Breakpoint at PC 10
    
    fn devtool_step_hook(ctx: ?*anyopaque, frame: *Frame, pc: usize, opcode: u8) anyerror!StepControl {
        const state = @ptrCast(*DevtoolState, @alignCast(@alignOf(DevtoolState), ctx.?));
        
        // Record execution step
        try state.trace.append(.{
            .pc = pc,
            .opcode = opcode,
            .gas = frame.gas_remaining,
            .stack_size = frame.stack.size(),
        });
        
        // Check for breakpoints
        for (state.breakpoints.items) |bp| {
            if (pc == bp) {
                return .pause; // Hit breakpoint
            }
        }
        
        return .cont;
    }
    
    var devtool_state = DevtoolState{
        .trace = &execution_trace,
        .breakpoints = &breakpoints,
    };
    
    var hooks = DebugHooks{
        .user_ctx = &devtool_state,
        .on_step = devtool_step_hook,
    };
    
    evm.set_debug_hooks(hooks);
    
    // Execute until breakpoint
    const result = evm.execute(complex_bytecode);
    try expectError(ExecutionError.Error.DebugPaused, result);
    
    // Verify trace was captured
    try expect(execution_trace.items.len > 0);
    try expect(execution_trace.items[execution_trace.items.len - 1].pc == 10);
}
```

### Final Validation Checklist

#### Code Review Requirements
- [ ] PC calculation uses exact same algorithm as tracing
- [ ] All hook injection points have proper error handling
- [ ] Memory lifetimes are correctly managed
- [ ] Performance overhead is minimized
- [ ] Thread safety assumptions are documented
- [ ] All edge cases are handled

#### Testing Requirements
- [ ] Step hook sequence validation passes
- [ ] Step hook pause/resume functionality works
- [ ] Step hook abort functionality works
- [ ] Message hook captures all CALL types
- [ ] Message hook captures all CREATE types
- [ ] Hook errors are properly mapped to DebugAbort
- [ ] Zero-overhead performance test passes
- [ ] All existing tests remain green
- [ ] Memory leak detection passes

#### Documentation Requirements
- [ ] Implementation guide is complete and accurate
- [ ] API documentation is comprehensive
- [ ] Safety constraints are clearly documented
- [ ] Performance characteristics are documented
- [ ] Integration examples are provided

**SUCCESS CRITERIA**: All checkboxes must be completed before the PR is considered ready for review.