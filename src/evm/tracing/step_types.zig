//! Core types and enums for the stepping API
//! 
//! This module defines only the minimal additional data structures needed for manual EVM stepping.
//! It reuses existing types from trace_types.zig to avoid duplication.

const std = @import("std");
const tracer = @import("trace_types.zig");
const ExecutionError = @import("../execution/execution_error.zig");

// Re-export existing types from trace_types.zig for convenience
pub const StepInfo = tracer.StepInfo;
pub const StepResult = tracer.StepResult;
pub const StorageChange = tracer.StorageChange;
pub const LogEntry = tracer.LogEntry;
pub const ExecutionErrorInfo = tracer.ExecutionErrorInfo;
pub const Address = tracer.Address;

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

/// Result of a stepping operation (extended from tracer.StepResult)
pub const SteppingResult = struct {
    /// Current execution status
    status: StepStatus,
    /// Combined step info and result from tracer
    step_info: ?StepInfo = null,
    step_result: ?StepResult = null,
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

/// Complete step transition with before/after state (combines StepInfo + StepResult)
pub const StepTransition = struct {
    // Pre-execution state (from StepInfo)
    pc: usize,
    opcode: u8,
    op_name: []const u8,
    gas_before: u64,
    stack_size_before: usize,
    memory_size_before: usize,
    depth: u16,
    address: Address,

    // Post-execution state (from StepResult)
    gas_after: u64,
    gas_cost: u64,
    stack_size_after: usize,
    memory_size_after: usize,

    // State changes (reusing existing types)
    stack_snapshot: ?[]const u256 = null,
    memory_snapshot: ?[]const u8 = null,
    storage_changes: []const StorageChange = &.{},
    logs_emitted: []const LogEntry = &.{},
    error_info: ?ExecutionErrorInfo = null,
    
    /// Get the net stack change from this instruction
    pub fn get_stack_delta(self: StepTransition) i32 {
        return @as(i32, @intCast(self.stack_size_after)) - @as(i32, @intCast(self.stack_size_before));
    }
    
    /// Check if this instruction modified memory
    pub fn modified_memory(self: StepTransition) bool {
        return self.memory_size_after != self.memory_size_before;
    }
    
    /// Create from separate StepInfo and StepResult
    pub fn from_step_data(step_info: StepInfo, step_result: StepResult) StepTransition {
        return StepTransition{
            .pc = step_info.pc,
            .opcode = step_info.opcode,
            .op_name = step_info.op_name,
            .gas_before = step_info.gas_remaining,
            .stack_size_before = step_info.stack_size,
            .memory_size_before = step_info.memory_size,
            .depth = step_info.depth,
            .address = step_info.address,
            .gas_after = step_result.gas_after,
            .gas_cost = step_result.gas_cost,
            .stack_size_after = step_info.stack_size + @as(usize, @intCast(step_result.stack_changes.net_change)),
            .memory_size_after = step_result.memory_changes.getCurrentSize(),
            .stack_snapshot = step_result.stack_snapshot,
            .memory_snapshot = step_result.memory_snapshot,
            .storage_changes = step_result.storage_changes,
            .logs_emitted = step_result.logs_emitted,
            .error_info = step_result.error_info,
        };
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