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
const build_options = @import("build_options");

/// High-level stepping context for EVM execution debugging
pub const SteppingContext = struct {
    evm: *Evm,
    frame: *Frame,
    tracer: MemoryTracer,
    allocator: Allocator,
    current_mode: step_types.SteppingMode,
    
    /// Initialize a new stepping context (only available when tracing enabled)
    pub fn init(evm: *Evm, frame: *Frame, allocator: Allocator) !SteppingContext {
        if (comptime !build_options.enable_tracing) {
            @compileError("SteppingContext is only available when tracing is enabled");
        }
        
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
            .memory_data = if (memory_size > 0) self.frame.memory.shared_buffer_ref.items[0..memory_size] else &.{},
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
    
    /// Get information about the analysis block at PC 0 (contract start) using bulletproof analysis data
    pub fn get_current_block_info(self: *SteppingContext) ?step_types.BlockInfo {
        return MemoryTracer.get_block_info(0, self.frame.analysis);
    }
    
    /// Check if PC 0 is at a block boundary using bulletproof analysis data
    pub fn is_at_block_boundary(self: *SteppingContext) bool {
        return MemoryTracer.is_block_boundary(0, self.frame.analysis);
    }
    
    /// Check if PC has a breakpoint
    pub fn has_breakpoint(self: *SteppingContext, pc: usize) bool {
        return self.tracer.has_breakpoint(pc);
    }
    
    /// Get current step mode
    pub fn get_step_mode(self: *SteppingContext) @TypeOf(self.tracer.step_mode) {
        return self.tracer.get_step_mode();
    }
    
    /// Reset to passive tracing mode
    pub fn reset_step_mode(self: *SteppingContext) void {
        self.tracer.reset_step_mode();
    }
    
    /// Add a breakpoint at the specified PC
    pub fn add_breakpoint(self: *SteppingContext, pc: usize) !void {
        return self.tracer.add_breakpoint(pc);
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
        _ = self; // Parameter not used in current implementation
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