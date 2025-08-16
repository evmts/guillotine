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