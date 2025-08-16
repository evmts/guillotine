# Shadow Execution Refactoring Guide: From Flawed Per-Step to Correct Per-Block Implementation

## Executive Summary

This document provides a complete guide for refactoring the shadow execution system in the Guillotine EVM. The current implementation has a fundamental architectural flaw: it attempts to compare states between two EVMs that execute at different granularities. This guide explains the problem, the solution, and provides step-by-step instructions for implementing a correct shadow execution system.

## Table of Contents

1. [Understanding the Problem](#understanding-the-problem)
2. [The Solution: Per-Block Comparison](#the-solution-per-block-comparison)
3. [Architecture Overview](#architecture-overview)
4. [Implementation Plan](#implementation-plan)
5. [Detailed Code Changes](#detailed-code-changes)
6. [Testing Strategy](#testing-strategy)
7. [API Design](#api-design)
8. [Migration Checklist](#migration-checklist)

---

## Understanding the Problem

### What Are We Building?

The Guillotine EVM has two execution modes:

1. **Main EVM** (Optimized)
   - Located in: `src/evm/evm/interpret.zig`
   - Uses pre-analyzed bytecode with instruction blocks
   - Executes multiple opcodes per "step"
   - Example: One step might execute `[PUSH1 0x05, PUSH1 0x0a, ADD]` as a single unit

2. **Mini EVM** (Reference)
   - Located in: `src/evm/evm/call_mini.zig`
   - Simple PC-based interpreter
   - Executes one opcode at a time
   - Example: Three steps to execute `PUSH1 0x05`, `PUSH1 0x0a`, `ADD`

### The Current Flaw

The current per-step comparison (`src/evm/evm/shadow_compare_step.zig`) tries to:
1. Execute an instruction block in Main EVM (multiple opcodes)
2. Execute ONE opcode in Mini EVM
3. Compare states ❌ **This can never match!**

### Why This Matters

Shadow execution validates that our optimized EVM produces identical results to a simple bytecode interpreter. This is critical for:
- Correctness validation
- Debugging opcode implementations
- Ensuring optimization doesn't break functionality

---

## The Solution: Per-Block Comparison

### Conceptual Design

Instead of comparing after each opcode (impossible due to granularity mismatch), we will:

1. **Per-Call Mode** (for normal testing)
   - Execute entire call in both EVMs
   - Compare final states
   - Zero overhead when disabled

2. **Per-Block Mode** (for detailed tracing)
   - Main EVM executes one instruction block
   - Mini EVM executes ALL opcodes that comprise that block
   - Compare states after both complete the same work
   - Used by ShadowTracer for debugging

### Key Insight

The smallest unit where states can match is after both EVMs have executed the same sequence of opcodes - which means after a complete instruction block.

---

## Architecture Overview

### File Structure

```
src/evm/
├── evm.zig                          # Main EVM struct with shadow mode configuration
├── evm/
│   ├── interpret.zig                # Main EVM interpreter (analysis-based)
│   ├── call_mini.zig                # Mini EVM full call execution
│   ├── execute_mini_block.zig       # NEW: Execute block of opcodes in Mini EVM
│   └── shadow_compare_block.zig     # NEW: Compare states after block execution
├── shadow/
│   └── shadow.zig                   # Shadow comparison logic
└── tracing/
    └── shadow_tracer.zig            # NEW: Tracer with per-block comparison
```

### Data Flow

```
Normal Execution (per-call):
  Main EVM → Execute Call → Result ┐
                                    ├→ Compare → Report
  Mini EVM → Execute Call → Result ┘

Traced Execution (per-block):
  Main EVM → Execute Block → State ┐
                                    ├→ Compare → Continue/Report
  Mini EVM → Execute Block → State ┘
```

---

## Implementation Plan

### Phase 1: Remove Broken Per-Step Code

1. Delete `src/evm/evm/execute_mini_step.zig`
2. Delete `src/evm/evm/shadow_compare_step.zig`
3. Remove per-step mode from `shadow.zig`
4. Clean up any references in `interpret.zig`

### Phase 2: Implement Per-Block Execution

1. Create `execute_mini_block.zig` for block-wise mini execution
2. Create `shadow_compare_block.zig` for block comparison
3. Update shadow module with per-block mode

### Phase 3: Integrate with Tracer

1. Create `ShadowTracer` that uses per-block comparison
2. Add hooks in main interpreter for block boundaries
3. Implement comprehensive testing

---

## Detailed Code Changes

### 1. Remove File: `src/evm/evm/execute_mini_step.zig`

**Action**: Delete this file completely. It's fundamentally flawed.

### 2. Remove File: `src/evm/evm/shadow_compare_step.zig`

**Action**: Delete this file completely. Will be replaced with block comparison.

### 3. New File: `src/evm/evm/execute_mini_block.zig`

Create this file to execute a block of opcodes in the Mini EVM:

```zig
const std = @import("std");
const ExecutionError = @import("../execution/execution_error.zig");
const Frame = @import("../frame.zig").Frame;
const Evm = @import("../evm.zig");
const opcode_mod = @import("../opcodes/opcode.zig");
const Log = @import("../log.zig");

/// Result of block execution in Mini EVM
pub const BlockResult = struct {
    /// Final PC after executing the block
    final_pc: usize,
    /// Number of opcodes executed
    opcodes_executed: usize,
    /// Error if execution failed
    @"error": ?ExecutionError.Error,
    /// Whether execution terminated (STOP, RETURN, REVERT, etc.)
    terminated: bool,
};

/// Execute a block of opcodes in Mini EVM to match Main EVM's instruction block
/// 
/// This function executes opcodes starting from `start_pc` until:
/// 1. It reaches `end_pc` (exclusive)
/// 2. It encounters a terminating opcode (STOP, RETURN, REVERT)
/// 3. It encounters a jump that leaves the block
/// 4. An error occurs
///
/// @param self - The EVM instance
/// @param frame - The execution frame (stack, memory, etc.)
/// @param start_pc - Starting PC of the block
/// @param end_pc - Ending PC of the block (exclusive)
/// @param code - The bytecode being executed
/// @return BlockResult with execution details
pub fn execute_mini_block(
    self: *Evm,
    frame: *Frame,
    start_pc: usize,
    end_pc: usize,
    code: []const u8,
) BlockResult {
    Log.debug("[execute_mini_block] Executing block from PC {} to {}", .{ start_pc, end_pc });
    
    var pc = start_pc;
    var opcodes_executed: usize = 0;
    
    // Execute opcodes until we reach the end of the block or terminate
    while (pc < end_pc and pc < code.len) {
        const op = code[pc];
        const operation = self.table.get_operation(op);
        
        Log.debug("[execute_mini_block] PC={}, opcode=0x{x:0>2}", .{ pc, op });
        
        // Check if opcode is undefined
        if (operation.undefined) {
            return BlockResult{
                .final_pc = pc,
                .opcodes_executed = opcodes_executed,
                .@"error" = ExecutionError.Error.InvalidOpcode,
                .terminated = true,
            };
        }
        
        // Gas validation
        if (frame.gas_remaining < operation.constant_gas) {
            return BlockResult{
                .final_pc = pc,
                .opcodes_executed = opcodes_executed,
                .@"error" = ExecutionError.Error.OutOfGas,
                .terminated = true,
            };
        }
        frame.gas_remaining -= operation.constant_gas;
        
        // Stack validation
        if (frame.stack.size() < operation.min_stack) {
            return BlockResult{
                .final_pc = pc,
                .opcodes_executed = opcodes_executed,
                .@"error" = ExecutionError.Error.StackUnderflow,
                .terminated = true,
            };
        }
        if (frame.stack.size() > operation.max_stack) {
            return BlockResult{
                .final_pc = pc,
                .opcodes_executed = opcodes_executed,
                .@"error" = ExecutionError.Error.StackOverflow,
                .terminated = true,
            };
        }
        
        // Handle specific opcodes that affect control flow
        switch (op) {
            @intFromEnum(opcode_mod.Enum.STOP) => {
                return BlockResult{
                    .final_pc = pc,
                    .opcodes_executed = opcodes_executed + 1,
                    .@"error" = ExecutionError.Error.STOP,
                    .terminated = true,
                };
            },
            @intFromEnum(opcode_mod.Enum.JUMP) => {
                const dest = frame.stack.pop() catch |err| {
                    return BlockResult{
                        .final_pc = pc,
                        .opcodes_executed = opcodes_executed,
                        .@"error" = err,
                        .terminated = true,
                    };
                };
                
                // Validate jump destination
                if (dest > code.len) {
                    return BlockResult{
                        .final_pc = pc,
                        .opcodes_executed = opcodes_executed,
                        .@"error" = ExecutionError.Error.InvalidJump,
                        .terminated = true,
                    };
                }
                
                const dest_usize = @as(usize, @intCast(dest));
                if (dest_usize >= code.len or code[dest_usize] != @intFromEnum(opcode_mod.Enum.JUMPDEST)) {
                    return BlockResult{
                        .final_pc = pc,
                        .opcodes_executed = opcodes_executed,
                        .@"error" = ExecutionError.Error.InvalidJump,
                        .terminated = true,
                    };
                }
                
                // Jump leaves the current block
                return BlockResult{
                    .final_pc = dest_usize,
                    .opcodes_executed = opcodes_executed + 1,
                    .@"error" = null,
                    .terminated = false,
                };
            },
            @intFromEnum(opcode_mod.Enum.JUMPI) => {
                const dest = frame.stack.pop() catch |err| {
                    return BlockResult{
                        .final_pc = pc,
                        .opcodes_executed = opcodes_executed,
                        .@"error" = err,
                        .terminated = true,
                    };
                };
                const cond = frame.stack.pop() catch |err| {
                    return BlockResult{
                        .final_pc = pc,
                        .opcodes_executed = opcodes_executed,
                        .@"error" = err,
                        .terminated = true,
                    };
                };
                
                if (cond != 0) {
                    // Taking the jump
                    if (dest > code.len) {
                        return BlockResult{
                            .final_pc = pc,
                            .opcodes_executed = opcodes_executed,
                            .@"error" = ExecutionError.Error.InvalidJump,
                            .terminated = true,
                        };
                    }
                    
                    const dest_usize = @as(usize, @intCast(dest));
                    if (dest_usize >= code.len or code[dest_usize] != @intFromEnum(opcode_mod.Enum.JUMPDEST)) {
                        return BlockResult{
                            .final_pc = pc,
                            .opcodes_executed = opcodes_executed,
                            .@"error" = ExecutionError.Error.InvalidJump,
                            .terminated = true,
                        };
                    }
                    
                    return BlockResult{
                        .final_pc = dest_usize,
                        .opcodes_executed = opcodes_executed + 1,
                        .@"error" = null,
                        .terminated = false,
                    };
                }
                
                // Not taking jump, continue to next instruction
                pc += 1;
                opcodes_executed += 1;
                continue;
            },
            @intFromEnum(opcode_mod.Enum.PC) => {
                frame.stack.append(@intCast(pc)) catch |err| {
                    return BlockResult{
                        .final_pc = pc,
                        .opcodes_executed = opcodes_executed,
                        .@"error" = err,
                        .terminated = true,
                    };
                };
                pc += 1;
                opcodes_executed += 1;
                continue;
            },
            @intFromEnum(opcode_mod.Enum.RETURN) => {
                const offset = frame.stack.pop() catch |err| {
                    return BlockResult{
                        .final_pc = pc,
                        .opcodes_executed = opcodes_executed,
                        .@"error" = err,
                        .terminated = true,
                    };
                };
                const size = frame.stack.pop() catch |err| {
                    return BlockResult{
                        .final_pc = pc,
                        .opcodes_executed = opcodes_executed,
                        .@"error" = err,
                        .terminated = true,
                    };
                };
                
                // Set return data
                if (size > 0) {
                    const offset_usize = @as(usize, @intCast(offset));
                    const size_usize = @as(usize, @intCast(size));
                    const data = frame.memory.get_slice(offset_usize, size_usize) catch |err| {
                        return BlockResult{
                            .final_pc = pc,
                            .opcodes_executed = opcodes_executed,
                            .@"error" = err,
                            .terminated = true,
                        };
                    };
                    frame.host.set_output(data) catch {
                        return BlockResult{
                            .final_pc = pc,
                            .opcodes_executed = opcodes_executed,
                            .@"error" = ExecutionError.Error.DatabaseCorrupted,
                            .terminated = true,
                        };
                    };
                }
                
                return BlockResult{
                    .final_pc = pc,
                    .opcodes_executed = opcodes_executed + 1,
                    .@"error" = ExecutionError.Error.RETURN,
                    .terminated = true,
                };
            },
            @intFromEnum(opcode_mod.Enum.REVERT) => {
                const offset = frame.stack.pop() catch |err| {
                    return BlockResult{
                        .final_pc = pc,
                        .opcodes_executed = opcodes_executed,
                        .@"error" = err,
                        .terminated = true,
                    };
                };
                const size = frame.stack.pop() catch |err| {
                    return BlockResult{
                        .final_pc = pc,
                        .opcodes_executed = opcodes_executed,
                        .@"error" = err,
                        .terminated = true,
                    };
                };
                
                // Set revert data
                if (size > 0) {
                    const offset_usize = @as(usize, @intCast(offset));
                    const size_usize = @as(usize, @intCast(size));
                    const data = frame.memory.get_slice(offset_usize, size_usize) catch |err| {
                        return BlockResult{
                            .final_pc = pc,
                            .opcodes_executed = opcodes_executed,
                            .@"error" = err,
                            .terminated = true,
                        };
                    };
                    frame.host.set_output(data) catch {
                        return BlockResult{
                            .final_pc = pc,
                            .opcodes_executed = opcodes_executed,
                            .@"error" = ExecutionError.Error.DatabaseCorrupted,
                            .terminated = true,
                        };
                    };
                }
                
                return BlockResult{
                    .final_pc = pc,
                    .opcodes_executed = opcodes_executed + 1,
                    .@"error" = ExecutionError.Error.REVERT,
                    .terminated = true,
                };
            },
            else => {
                // Handle PUSH opcodes
                if (opcode_mod.is_push(op)) {
                    const push_size = opcode_mod.get_push_size(op);
                    
                    if (pc + push_size >= code.len) {
                        return BlockResult{
                            .final_pc = pc,
                            .opcodes_executed = opcodes_executed,
                            .@"error" = ExecutionError.Error.OutOfOffset,
                            .terminated = true,
                        };
                    }
                    
                    // Read push data
                    var value: u256 = 0;
                    const data_start = pc + 1;
                    const data_end = @min(data_start + push_size, code.len);
                    const data = code[data_start..data_end];
                    
                    // Convert bytes to u256 (big-endian)
                    for (data) |byte| {
                        value = (value << 8) | byte;
                    }
                    
                    frame.stack.append(value) catch |err| {
                        return BlockResult{
                            .final_pc = pc,
                            .opcodes_executed = opcodes_executed,
                            .@"error" = err,
                            .terminated = true,
                        };
                    };
                    
                    pc += 1 + push_size;
                    opcodes_executed += 1;
                    continue;
                }
                
                // For all other opcodes, use the execution function
                const context: *anyopaque = @ptrCast(frame);
                operation.execute(context) catch |err| {
                    return BlockResult{
                        .final_pc = pc,
                        .opcodes_executed = opcodes_executed,
                        .@"error" = err,
                        .terminated = true,
                    };
                };
                
                pc += 1;
                opcodes_executed += 1;
            },
        }
    }
    
    // Reached end of block normally
    return BlockResult{
        .final_pc = pc,
        .opcodes_executed = opcodes_executed,
        .@"error" = null,
        .terminated = false,
    };
}
```

### 4. New File: `src/evm/evm/shadow_compare_block.zig`

Create this file for block-level comparison:

```zig
const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const Frame = @import("../frame.zig").Frame;
const Evm = @import("../evm.zig");
const DebugShadow = @import("../shadow/shadow.zig");
const execute_mini_block = @import("execute_mini_block.zig");
const ExecutionError = @import("../execution/execution_error.zig");
const Instruction = @import("../instruction.zig").Instruction;
const CodeAnalysis = @import("../analysis.zig").CodeAnalysis;
const Log = @import("../log.zig");

/// Information about an instruction block for shadow comparison
pub const BlockInfo = struct {
    /// Starting PC of the block
    start_pc: usize,
    /// Ending PC of the block (exclusive)
    end_pc: usize,
    /// Number of instructions in the block
    instruction_count: usize,
};

/// Get block information from the current instruction in the analysis
pub fn get_block_info(
    inst: *const Instruction,
    analysis: *const CodeAnalysis,
) ?BlockInfo {
    // Get the index of the current instruction
    const base: [*]const @TypeOf(inst.*) = analysis.instructions.ptr;
    const current_idx = (@intFromPtr(inst) - @intFromPtr(base)) / @sizeOf(@TypeOf(inst.*));
    
    // Get PC of current instruction
    const start_pc_u16 = analysis.inst_to_pc[current_idx];
    if (start_pc_u16 == std.math.maxInt(u16)) return null;
    const start_pc = @as(usize, start_pc_u16);
    
    // Find the end of the block by looking for the next instruction's PC
    // or a control flow change
    var end_pc = start_pc + 1; // Default to single instruction
    var instruction_count: usize = 1;
    
    // Scan forward to find block boundary
    var idx = current_idx + 1;
    while (idx < analysis.instructions.len) : (idx += 1) {
        const next_pc_u16 = analysis.inst_to_pc[idx];
        if (next_pc_u16 != std.math.maxInt(u16)) {
            end_pc = @as(usize, next_pc_u16);
            break;
        }
        instruction_count += 1;
    }
    
    // If we didn't find another PC, the block extends to the end of code
    if (idx >= analysis.instructions.len) {
        end_pc = analysis.code.len;
    }
    
    return BlockInfo{
        .start_pc = start_pc,
        .end_pc = end_pc,
        .instruction_count = instruction_count,
    };
}

/// Shadow comparison helper for per-block execution
/// This function is called after the main interpreter executes an instruction block
pub inline fn shadow_compare_block(
    self: *Evm,
    frame: *Frame,
    inst: *const Instruction,
    analysis: *const CodeAnalysis,
) void {
    // Only compile this code if shadow comparison is enabled
    if (!comptime (@hasDecl(build_options, "enable_shadow_compare") and
                   build_options.enable_shadow_compare)) return;
    
    // Only run if shadow mode is per_block (used by tracer)
    // Note: per_call mode is handled separately in system.zig
    if (self.shadow_mode != .per_block) return;
    
    // Get block information
    const block_info = get_block_info(inst, analysis) orelse {
        Log.debug("[shadow_compare_block] Could not determine block info", .{});
        return;
    };
    
    Log.debug("[shadow_compare_block] Comparing block from PC {} to {}", .{
        block_info.start_pc,
        block_info.end_pc,
    });
    
    // Create a mini frame for comparison (clones stack and memory)
    var mini_frame = Frame.init(
        frame.gas_remaining,
        frame.is_static,
        frame.depth,
        frame.contract_address,
        frame.caller,
        frame.value,
        frame.analysis,
        frame.host,
        frame.state,
        self.allocator,
    ) catch {
        Log.err("[shadow_compare_block] Failed to create mini frame", .{});
        return;
    };
    defer mini_frame.deinit(self.allocator);
    
    // Copy stack state
    const stack_size = frame.stack.size();
    @memcpy(mini_frame.stack.data[0..stack_size], frame.stack.data[0..stack_size]);
    mini_frame.stack.current = mini_frame.stack.base + stack_size;
    
    // Copy memory state
    if (frame.memory.context_size() > 0) {
        const mem_size = frame.memory.context_size();
        const src = frame.memory.get_slice(0, mem_size) catch {
            Log.err("[shadow_compare_block] Failed to get source memory", .{});
            return;
        };
        mini_frame.memory.set_data(0, src) catch {
            Log.err("[shadow_compare_block] Failed to set mini memory", .{});
            return;
        };
    }
    
    // Copy input buffer and returndata
    mini_frame.input_buffer = frame.input_buffer;
    mini_frame.returndata = frame.returndata;
    
    // Execute the entire block in mini EVM
    const result = execute_mini_block.execute_mini_block(
        self,
        &mini_frame,
        block_info.start_pc,
        block_info.end_pc,
        analysis.code,
    );
    
    Log.debug("[shadow_compare_block] Block execution result: opcodes_executed={}, error={s}", .{
        result.opcodes_executed,
        if (result.@"error") |e| @errorName(e) else "none",
    });
    
    // Compare states if block executed successfully or with expected termination
    if (result.@"error" == null or
        result.@"error" == ExecutionError.Error.STOP or
        result.@"error" == ExecutionError.Error.RETURN or
        result.@"error" == ExecutionError.Error.REVERT) {
        
        // Compare execution state
        const mismatch = DebugShadow.compare_block(
            frame,
            &mini_frame,
            block_info.start_pc,
            block_info.end_pc,
            self.shadow_cfg,
            self.allocator,
        ) catch null;
        
        if (mismatch) |m| {
            // Store mismatch
            if (self.last_shadow_mismatch) |old| {
                var mutable = old;
                mutable.deinit(self.allocator);
            }
            self.last_shadow_mismatch = m;
            
            Log.err("[shadow_compare_block] Mismatch in block {}-{}: field={s}, main={s}, mini={s}", .{
                block_info.start_pc,
                block_info.end_pc,
                @tagName(m.field),
                m.lhs_summary,
                m.rhs_summary,
            });
            
            // In debug mode, fail immediately
            if (comptime builtin.mode == .Debug) {
                @panic("Shadow block mismatch detected!");
            }
        } else {
            Log.debug("[shadow_compare_block] Block comparison passed", .{});
        }
    } else if (result.@"error") |err| {
        Log.err("[shadow_compare_block] Mini EVM error in block {}-{}: {s}", .{
            block_info.start_pc,
            block_info.end_pc,
            @errorName(err),
        });
    }
}
```

### 5. Update: `src/evm/shadow/shadow.zig`

Update the shadow module to support per-block comparison:

```zig
// Update the ShadowMode enum
pub const ShadowMode = enum {
    /// Shadow execution disabled
    off,
    /// Compare at end of each call (for testing)
    per_call,
    /// Compare after each instruction block (for tracing/debugging)
    per_block,
};

// Add new comparison function for blocks
/// Compare execution state after executing a block of instructions
pub fn compare_block(
    main_frame: *const Frame,
    mini_frame: *const Frame,
    block_start_pc: usize,
    block_end_pc: usize,
    config: ShadowConfig,
    allocator: std.mem.Allocator,
) !?ShadowMismatch {
    // Gas comparison
    if (main_frame.gas_remaining != mini_frame.gas_remaining) {
        const main_str = try std.fmt.allocPrint(allocator, "{}", .{main_frame.gas_remaining});
        const mini_str = try std.fmt.allocPrint(allocator, "{}", .{mini_frame.gas_remaining});
        return try ShadowMismatch.create(
            .per_block,
            block_start_pc,
            .gas_left,
            main_str,
            mini_str,
            allocator,
        );
    }
    
    // Stack size comparison
    if (main_frame.stack.size() != mini_frame.stack.size()) {
        const main_str = try std.fmt.allocPrint(allocator, "size={}", .{main_frame.stack.size()});
        const mini_str = try std.fmt.allocPrint(allocator, "size={}", .{mini_frame.stack.size()});
        return try ShadowMismatch.create(
            .per_block,
            block_start_pc,
            .stack,
            main_str,
            mini_str,
            allocator,
        );
    }
    
    // Stack content comparison
    const stack_size = main_frame.stack.size();
    const compare_count = @min(16, stack_size); // Compare top 16 elements
    
    var i: usize = 0;
    while (i < compare_count) : (i += 1) {
        const main_val = main_frame.stack.data[stack_size - 1 - i];
        const mini_val = mini_frame.stack.data[stack_size - 1 - i];
        
        if (main_val != mini_val) {
            const main_str = try std.fmt.allocPrint(allocator, "stack[{}]=0x{x}", .{ i, main_val });
            const mini_str = try std.fmt.allocPrint(allocator, "stack[{}]=0x{x}", .{ i, mini_val });
            var mismatch = try ShadowMismatch.create(
                .per_block,
                block_start_pc,
                .stack,
                main_str,
                mini_str,
                allocator,
            );
            mismatch.diff_index = i;
            return mismatch;
        }
    }
    
    // Memory size comparison (if configured)
    if (config.compare_memory) {
        if (main_frame.memory.size() != mini_frame.memory.size()) {
            const main_str = try std.fmt.allocPrint(allocator, "size={}", .{main_frame.memory.size()});
            const mini_str = try std.fmt.allocPrint(allocator, "size={}", .{mini_frame.memory.size()});
            return try ShadowMismatch.create(
                .per_block,
                block_start_pc,
                .memory,
                main_str,
                mini_str,
                allocator,
            );
        }
        
        // Memory content comparison (first 256 bytes if configured)
        if (config.compare_memory_content) {
            const mem_size = @min(256, main_frame.memory.size());
            const main_mem = main_frame.memory.get_slice(0, mem_size) catch &.{};
            const mini_mem = mini_frame.memory.get_slice(0, mem_size) catch &.{};
            
            for (main_mem, mini_mem, 0..) |main_byte, mini_byte, offset| {
                if (main_byte != mini_byte) {
                    const main_str = try std.fmt.allocPrint(allocator, "mem[{}]=0x{x:0>2}", .{ offset, main_byte });
                    const mini_str = try std.fmt.allocPrint(allocator, "mem[{}]=0x{x:0>2}", .{ offset, mini_byte });
                    return try ShadowMismatch.create(
                        .per_block,
                        block_start_pc,
                        .memory,
                        main_str,
                        mini_str,
                        allocator,
                    );
                }
            }
        }
    }
    
    return null; // No mismatch
}
```

### 6. New File: `src/evm/tracing/shadow_tracer.zig`

Create the ShadowTracer that uses per-block comparison:

```zig
const std = @import("std");
const tracer = @import("trace_types.zig");
const MemoryTracer = @import("memory_tracer.zig").MemoryTracer;
const DebugShadow = @import("../shadow/shadow.zig");
const Evm = @import("../evm.zig");
const Frame = @import("../frame.zig").Frame;
const execute_mini_block = @import("../evm/execute_mini_block.zig");
const shadow_compare_block = @import("../evm/shadow_compare_block.zig");
const Log = @import("../log.zig");

/// Shadow tracer that compares Main EVM with Mini EVM execution
/// Supports both per-call and per-block comparison modes
pub const ShadowTracer = struct {
    /// Base memory tracer for state capture
    base: MemoryTracer,
    
    /// Reference to EVM for shadow execution
    evm: *Evm,
    
    /// Comparison mode
    mode: DebugShadow.ShadowMode,
    
    /// Configuration for comparison
    config: DebugShadow.ShadowConfig,
    
    /// Shadow mismatches detected during execution
    mismatches: std.ArrayList(DebugShadow.ShadowMismatch),
    
    /// Statistics
    blocks_compared: usize = 0,
    mismatches_found: usize = 0,
    
    const Self = @This();
    
    /// VTable for tracer interface
    const VTABLE = tracer.TracerVTable{
        .on_step_before = on_step_before_impl,
        .on_step_after = on_step_after_impl,
        .on_step_transition = on_step_transition_impl,
        .on_message_before = on_message_before_impl,
        .on_message_after = on_message_after_impl,
        .on_message_transition = MemoryTracer.onMessageTransition_impl,
        .on_execution_end = on_execution_end_impl,
    };
    
    /// Initialize a new shadow tracer
    pub fn init(
        allocator: std.mem.Allocator,
        evm: *Evm,
        mode: DebugShadow.ShadowMode,
        config: DebugShadow.ShadowConfig,
    ) !Self {
        return Self{
            .base = try MemoryTracer.init(allocator),
            .evm = evm,
            .mode = mode,
            .config = config,
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
    
    /// Get the tracer handle for use with EVM
    pub fn handle(self: *Self) tracer.TracerHandle {
        return tracer.TracerHandle{
            .ptr = @ptrCast(self),
            .vtable = &VTABLE,
        };
    }
    
    /// Check if any mismatches were found
    pub fn has_mismatches(self: *const Self) bool {
        return self.mismatches.items.len > 0;
    }
    
    /// Get a report of all mismatches
    pub fn get_mismatch_report(self: *const Self, allocator: std.mem.Allocator) ![]u8 {
        var buffer = std.ArrayList(u8).init(allocator);
        errdefer buffer.deinit();
        
        const writer = buffer.writer();
        try writer.print("Shadow Execution Report\n", .{});
        try writer.print("========================\n", .{});
        try writer.print("Mode: {s}\n", .{@tagName(self.mode)});
        try writer.print("Blocks compared: {}\n", .{self.blocks_compared});
        try writer.print("Mismatches found: {}\n\n", .{self.mismatches_found});
        
        if (self.mismatches.items.len > 0) {
            try writer.print("Mismatches:\n", .{});
            for (self.mismatches.items, 0..) |mismatch, i| {
                try writer.print("  {}. PC {}: {s}\n", .{ i + 1, mismatch.op_pc, @tagName(mismatch.field) });
                try writer.print("     Main: {s}\n", .{mismatch.lhs_summary});
                try writer.print("     Mini: {s}\n", .{mismatch.rhs_summary});
            }
        } else {
            try writer.print("✓ All comparisons passed\n", .{});
        }
        
        return buffer.toOwnedSlice();
    }
    
    fn on_step_before_impl(ptr: *anyopaque, step_info: tracer.StepInfo) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        
        // Let base tracer capture state
        MemoryTracer.on_step_before_impl(&self.base, step_info);
        
        // We don't need to do anything here for shadow comparison
        // The comparison happens after the step completes
    }
    
    fn on_step_after_impl(ptr: *anyopaque, step_result: tracer.StepResult) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        
        // Let base tracer capture state
        MemoryTracer.on_step_after_impl(&self.base, step_result);
        
        // For per-block mode, trigger comparison after block execution
        // This would be called from the main interpreter when a block completes
        if (self.mode == .per_block) {
            // The actual comparison is triggered by the interpreter
            // calling shadow_compare_block directly
            self.blocks_compared += 1;
        }
    }
    
    fn on_step_transition_impl(ptr: *anyopaque, step_info: tracer.StepInfo, 
                               step_result: tracer.StepResult) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        MemoryTracer.on_step_transition_impl(&self.base, step_info, step_result);
    }
    
    fn on_message_before_impl(ptr: *anyopaque, message: tracer.Message) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        MemoryTracer.onMessageBefore_impl(&self.base, message);
        
        // For per-call mode, we'll compare at message end
        if (self.mode == .per_call) {
            // Enable shadow mode in EVM
            self.evm.set_shadow_mode(.per_call);
        }
    }
    
    fn on_message_after_impl(ptr: *anyopaque, message: tracer.Message, result: tracer.MessageResult) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        MemoryTracer.onMessageAfter_impl(&self.base, message, result);
        
        // For per-call mode, check for mismatches
        if (self.mode == .per_call) {
            if (self.evm.take_last_shadow_mismatch()) |mismatch| {
                self.mismatches.append(mismatch) catch {
                    var mutable = mismatch;
                    mutable.deinit(self.base.allocator);
                };
                self.mismatches_found += 1;
            }
        }
    }
    
    fn on_execution_end_impl(ptr: *anyopaque, result: tracer.ExecutionResult) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        MemoryTracer.on_execution_end_impl(&self.base, result);
        
        // Report any mismatches
        if (self.mismatches.items.len > 0) {
            Log.err("Shadow execution found {} mismatches", .{self.mismatches.items.len});
            for (self.mismatches.items) |mismatch| {
                Log.err("  PC {}: {} - main: {s}, mini: {s}", .{
                    mismatch.op_pc,
                    mismatch.field,
                    mismatch.lhs_summary,
                    mismatch.rhs_summary,
                });
            }
        } else {
            Log.debug("Shadow execution completed with no mismatches", .{});
        }
    }
};
```

### 7. Update: `src/evm/evm/interpret.zig`

Add hooks for per-block comparison in the main interpreter:

```zig
// Add this import at the top
const shadow_compare_block = if (@hasDecl(build_options, "enable_shadow_compare") and 
                                build_options.enable_shadow_compare)
    @import("shadow_compare_block.zig")
else
    struct {};

// In the interpret function, after executing an instruction block
// (around line 323 after exec_fn and line 379 after dynamic_gas exec_fn):

// After executing the instruction
try params.exec_fn(frame);

// Add shadow comparison for blocks if enabled
if (comptime (@hasDecl(build_options, "enable_shadow_compare") and 
              build_options.enable_shadow_compare)) {
    // Only compare if we're in per_block mode (set by tracer)
    if (self.shadow_mode == .per_block) {
        shadow_compare_block.shadow_compare_block(self, frame, instruction, analysis);
    }
}

// Continue with normal execution...
```

---

## Testing Strategy

### Test Structure

Create comprehensive tests in `test/shadow/` directory:

```zig
// test/shadow/comprehensive_test.zig
const std = @import("std");
const testing = std.testing;
const Evm = @import("evm").Evm;
const MemoryDatabase = @import("evm").MemoryDatabase;
const ShadowTracer = @import("evm").tracing.ShadowTracer;
const DebugShadow = @import("evm").shadow;
const Address = @import("Address");

test "shadow execution - per-call mode basic arithmetic" {
    const allocator = testing.allocator;
    
    // Create EVM
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var evm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, 0, false, null);
    defer evm.deinit();
    
    // Enable per-call shadow mode
    evm.set_shadow_mode(.per_call);
    
    // Test code: 5 + 10 = 15
    const code = [_]u8{
        0x60, 0x05, // PUSH1 5
        0x60, 0x0a, // PUSH1 10
        0x01,       // ADD
        0x60, 0x00, // PUSH1 0
        0x55,       // SSTORE (store result)
        0x00,       // STOP
    };
    
    // Deploy contract
    _ = try evm.state.set_code(Address.from(1), &code);
    
    // Execute
    const result = try evm.call(.{
        .call = .{
            .caller = Address.ZERO,
            .to = Address.from(1),
            .value = 0,
            .input = &.{},
            .gas = 100000,
        },
    });
    
    // Check for mismatches
    const mismatch = evm.take_last_shadow_mismatch();
    defer if (mismatch) |m| {
        var mutable = m;
        mutable.deinit(allocator);
    };
    
    try testing.expect(mismatch == null);
    try testing.expect(result.success);
}

test "shadow execution - per-block mode with tracer" {
    const allocator = testing.allocator;
    
    // Create EVM
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var evm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, 0, false, null);
    defer evm.deinit();
    
    // Create shadow tracer with per-block mode
    var shadow_tracer = try ShadowTracer.init(
        allocator,
        &evm,
        .per_block,
        .{ .compare_memory = true },
    );
    defer shadow_tracer.deinit();
    
    // Attach tracer
    evm.set_tracer(shadow_tracer.handle());
    evm.set_shadow_mode(.per_block);
    
    // Test code with multiple blocks
    const code = [_]u8{
        0x60, 0x05, // PUSH1 5
        0x60, 0x0a, // PUSH1 10
        0x01,       // ADD
        0x60, 0x02, // PUSH1 2
        0x02,       // MUL
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x00,       // STOP
    };
    
    // Deploy contract
    _ = try evm.state.set_code(Address.from(1), &code);
    
    // Execute
    const result = try evm.call(.{
        .call = .{
            .caller = Address.ZERO,
            .to = Address.from(1),
            .value = 0,
            .input = &.{},
            .gas = 100000,
        },
    });
    
    // Check results
    try testing.expect(result.success);
    try testing.expect(!shadow_tracer.has_mismatches());
    
    // Get report
    const report = try shadow_tracer.get_mismatch_report(allocator);
    defer allocator.free(report);
    
    std.log.info("Shadow tracer report:\n{s}", .{report});
}

test "shadow execution - control flow with jumps" {
    const allocator = testing.allocator;
    
    // Create EVM
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var evm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, 0, false, null);
    defer evm.deinit();
    
    // Enable shadow mode
    evm.set_shadow_mode(.per_call);
    
    // Test code with conditional jump
    const code = [_]u8{
        0x60, 0x01, // PUSH1 1 (condition)
        0x60, 0x08, // PUSH1 8 (jump dest)
        0x57,       // JUMPI
        0x60, 0xff, // PUSH1 255 (shouldn't execute)
        0x00,       // STOP (shouldn't execute)
        0x5b,       // JUMPDEST (offset 8)
        0x60, 0xaa, // PUSH1 170 (should execute)
        0x00,       // STOP
    };
    
    // Deploy contract
    _ = try evm.state.set_code(Address.from(1), &code);
    
    // Execute
    const result = try evm.call(.{
        .call = .{
            .caller = Address.ZERO,
            .to = Address.from(1),
            .value = 0,
            .input = &.{},
            .gas = 100000,
        },
    });
    
    // Check for mismatches
    const mismatch = evm.take_last_shadow_mismatch();
    defer if (mismatch) |m| {
        var mutable = m;
        mutable.deinit(allocator);
    };
    
    try testing.expect(mismatch == null);
    try testing.expect(result.success);
}

test "shadow execution - memory operations" {
    const allocator = testing.allocator;
    
    // Create EVM with shadow tracer
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var evm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, 0, false, null);
    defer evm.deinit();
    
    // Create tracer with memory comparison enabled
    var shadow_tracer = try ShadowTracer.init(
        allocator,
        &evm,
        .per_block,
        .{ 
            .compare_memory = true,
            .compare_memory_content = true,
        },
    );
    defer shadow_tracer.deinit();
    
    evm.set_tracer(shadow_tracer.handle());
    evm.set_shadow_mode(.per_block);
    
    // Test memory operations
    const code = [_]u8{
        0x60, 0x42, // PUSH1 0x42 (value)
        0x60, 0x20, // PUSH1 0x20 (offset)
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 0x20 (offset)
        0x51,       // MLOAD
        0x00,       // STOP
    };
    
    // Deploy and execute
    _ = try evm.state.set_code(Address.from(1), &code);
    
    const result = try evm.call(.{
        .call = .{
            .caller = Address.ZERO,
            .to = Address.from(1),
            .value = 0,
            .input = &.{},
            .gas = 100000,
        },
    });
    
    try testing.expect(result.success);
    try testing.expect(!shadow_tracer.has_mismatches());
}

test "shadow execution - nested calls" {
    const allocator = testing.allocator;
    
    // This test would require setting up multiple contracts
    // and testing CALL, DELEGATECALL, etc.
    // The shadow comparison happens automatically in system.zig
    
    // ... implementation ...
}
```

### Running Tests

```bash
# Build with shadow comparison enabled
zig build -Denable-shadow-compare=true

# Run shadow-specific tests
zig build test --test-filter "shadow execution" -Denable-shadow-compare=true

# Run all tests with shadow validation
zig build test -Denable-shadow-compare=true

# Run benchmarks with shadow validation (will be slower)
zig build bench -Denable-shadow-compare=true
```

---

## API Design

### User-Facing API

```zig
// For normal users running tests
var evm = try Evm.init(...);

// Simple per-call validation
evm.set_shadow_mode(.per_call);

// Execute normally - shadow comparison happens automatically
const result = try evm.call(...);

// Check if there was a mismatch
if (evm.take_last_shadow_mismatch()) |mismatch| {
    defer mismatch.deinit(allocator);
    std.log.err("Shadow mismatch: {}", .{mismatch});
}
```

### Advanced API for Debugging

```zig
// Create shadow tracer for detailed analysis
var shadow_tracer = try ShadowTracer.init(
    allocator,
    &evm,
    .per_block,  // Compare after each block
    .{
        .compare_memory = true,
        .compare_memory_content = true,
        .compare_storage = false,  // Too expensive
    },
);
defer shadow_tracer.deinit();

// Attach to EVM
evm.set_tracer(shadow_tracer.handle());
evm.set_shadow_mode(.per_block);

// Execute
const result = try evm.call(...);

// Get detailed report
const report = try shadow_tracer.get_mismatch_report(allocator);
defer allocator.free(report);
std.log.info("{s}", .{report});

// Check specific mismatches
for (shadow_tracer.mismatches.items) |mismatch| {
    // Analyze each mismatch
}
```

### Configuration Options

```zig
pub const ShadowConfig = struct {
    /// Compare memory size
    compare_memory: bool = true,
    
    /// Compare memory content (expensive)
    compare_memory_content: bool = false,
    
    /// Compare storage (very expensive)
    compare_storage: bool = false,
    
    /// Maximum memory bytes to compare
    max_memory_compare: usize = 256,
    
    /// Stop on first mismatch
    fail_fast: bool = true,
};
```

---

## Migration Checklist

### Phase 1: Clean Up (30 minutes)
- [ ] Delete `src/evm/evm/execute_mini_step.zig`
- [ ] Delete `src/evm/evm/shadow_compare_step.zig`
- [ ] Remove references to `per_step` mode from `shadow.zig`
- [ ] Update `ShadowMode` enum to have `off`, `per_call`, `per_block`
- [ ] Remove any per-step references from `interpret.zig`
- [ ] Update tests that reference deleted files

### Phase 2: Implement Block Execution (2 hours)
- [ ] Create `src/evm/evm/execute_mini_block.zig`
- [ ] Implement `execute_mini_block` function
- [ ] Test block execution with various opcode sequences
- [ ] Handle all control flow opcodes correctly

### Phase 3: Implement Block Comparison (1 hour)
- [ ] Create `src/evm/evm/shadow_compare_block.zig`
- [ ] Implement `get_block_info` function
- [ ] Implement `shadow_compare_block` function
- [ ] Add `compare_block` to `shadow.zig`

### Phase 4: Create Shadow Tracer (2 hours)
- [ ] Create `src/evm/tracing/shadow_tracer.zig`
- [ ] Implement tracer with per-block comparison
- [ ] Add statistics tracking
- [ ] Implement mismatch reporting

### Phase 5: Integration (1 hour)
- [ ] Add hooks in `interpret.zig` for block comparison
- [ ] Update `evm.zig` if needed
- [ ] Ensure build options work correctly

### Phase 6: Testing (2 hours)
- [ ] Create comprehensive test suite
- [ ] Test arithmetic operations
- [ ] Test control flow (JUMP, JUMPI)
- [ ] Test memory operations
- [ ] Test nested calls
- [ ] Test error conditions

### Phase 7: Documentation (30 minutes)
- [ ] Update code comments
- [ ] Update README if needed
- [ ] Document shadow modes in API

---

## Best Practices for Implementation

### Zig-Specific Guidelines

1. **Memory Management**
   ```zig
   // Always use defer for cleanup
   var thing = try allocator.create(Thing);
   defer allocator.destroy(thing);
   
   // Use errdefer for error paths
   var thing = try allocator.create(Thing);
   errdefer allocator.destroy(thing);
   ```

2. **Error Handling**
   ```zig
   // Return errors explicitly
   return error.InvalidJump;
   
   // Use catch for recovery
   const value = frame.stack.pop() catch |err| {
       return BlockResult{ .@"error" = err, ... };
   };
   ```

3. **Comptime Optimization**
   ```zig
   // Eliminate code at compile time
   if (!comptime (@hasDecl(build_options, "enable_shadow_compare") and
                  build_options.enable_shadow_compare)) return;
   ```

4. **Testing**
   ```zig
   // Use defer for test cleanup
   var db = MemoryDatabase.init(allocator);
   defer db.deinit();
   
   // Check both success and error cases
   try testing.expect(result.success);
   try testing.expectError(error.OutOfGas, failing_call());
   ```

### Performance Considerations

1. **Zero Overhead When Disabled**
   - All shadow code should be eliminated at compile time
   - Use `comptime` checks before any shadow logic

2. **Minimal Overhead When Enabled**
   - Per-call: ~2x overhead (acceptable for testing)
   - Per-block: ~2.5x overhead (acceptable for debugging)

3. **Memory Efficiency**
   - Reuse frames where possible
   - Clean up mismatches immediately
   - Limit memory comparison to reasonable sizes

### Common Pitfalls to Avoid

1. **Don't Compare at Wrong Granularity**
   - Never compare after single opcodes between EVMs
   - Always complete full blocks

2. **Don't Forget Memory Management**
   - Always free allocated memory
   - Use defer patterns consistently

3. **Don't Break Existing Tests**
   - Ensure all existing tests pass
   - Shadow mode should be opt-in

4. **Don't Ignore Edge Cases**
   - Handle empty blocks
   - Handle blocks that end with jumps
   - Handle error conditions properly

---

## Success Criteria

The refactoring is complete when:

1. ✅ All per-step code is removed
2. ✅ Per-block execution works correctly
3. ✅ Shadow tracer provides useful debugging output
4. ✅ All tests pass with shadow comparison enabled
5. ✅ Zero overhead when disabled
6. ✅ Clear API for users
7. ✅ No memory leaks
8. ✅ Documentation is complete

---

## Questions and Answers

**Q: Why can't we compare after each opcode?**
A: The Main EVM executes instruction blocks (multiple opcodes) while Mini EVM executes single opcodes. They don't step in sync.

**Q: What's the smallest unit we can compare?**
A: After both EVMs have executed the same sequence of opcodes - which is a complete instruction block.

**Q: When should I use per-call vs per-block?**
A: Use per-call for normal testing (fast). Use per-block with tracer for debugging specific issues (slower but more detailed).

**Q: How do I know if shadow comparison is working?**
A: Run tests with `-Denable-shadow-compare=true`. If they pass, shadow validation is working.

**Q: What if I find a mismatch?**
A: This indicates a bug in either the Main EVM optimization or Mini EVM implementation. The mismatch report will show exactly where they diverge.

---

## Conclusion

This refactoring transforms a fundamentally flawed per-step comparison into a correct per-block system. The key insight is matching execution granularity: both EVMs must complete the same work before comparison is meaningful.

The new architecture provides:
- **Correctness**: Compares at the right granularity
- **Performance**: Zero overhead when disabled
- **Debugging**: Detailed tracing when needed
- **Simplicity**: Clean API for users

Follow this guide step-by-step, test thoroughly, and you'll have a robust shadow execution system for validating EVM correctness.