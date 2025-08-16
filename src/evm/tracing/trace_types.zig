//! Core tracer interface and data structures for structured execution tracing
//!
//! This module defines the fundamental data types and interface for capturing
//! EVM execution traces with bounded memory usage. The tracer system uses
//! a VTable pattern for zero-cost type erasure and compile-time optimization.
//!
//! ## Design Principles
//!
//! - **Bounded Capture**: All memory and stack snapshots are bounded
//! - **Zero-Cost Abstractions**: VTable dispatch with compile-time guards
//! - **Memory Conscious**: Explicit ownership transfer and cleanup
//! - **EVM Semantics**: Matches EVM execution model and gas accounting
//!
//! ## Core Types
//!
//! - **TracerConfig**: Configuration for capture bounds
//! - **StepInfo**: Pre-execution state (PC, opcode, gas, stack size)
//! - **StepResult**: Post-execution state (gas cost, snapshots, changes)
//! - **StructLog**: Combined step data for JSON export
//! - **ExecutionTrace**: Complete trace with all steps

const std = @import("std");
const primitives = @import("primitives");
const ExecutionError = @import("../execution/execution_error.zig");
const Address = primitives.Address.Address;

/// Configuration for tracing capture bounds
pub const TracerConfig = struct {
    /// Maximum bytes to capture from memory per step
    memory_max_bytes: usize = 1024,
    /// Maximum stack items to capture per step
    stack_max_items: usize = 32,
    /// Maximum bytes to capture from log data per log entry
    log_data_max_bytes: usize = 512,
};

/// Pre-execution step information captured before opcode execution
pub const StepInfo = struct {
    /// Program counter at this step
    pc: usize,
    /// Raw opcode byte value (0x01 for ADD, etc.)
    opcode: u8,
    /// Human-readable opcode name ("ADD", "PUSH1", etc.)
    op_name: []const u8,
    /// Gas available before executing this opcode
    gas_before: u64,
    /// Call depth (0 for top-level, 1+ for nested calls)
    depth: u16,
    /// Contract address currently being executed
    address: Address,
    /// Address that initiated this call context
    caller: Address,
    /// Whether this is a static call (no state changes allowed)
    is_static: bool,
    /// Number of items currently on stack
    stack_size: usize,
    /// Current memory size in bytes
    memory_size: usize,

    /// Check if this is main execution (depth 0)
    pub fn isMainExecution(self: *const StepInfo) bool {
        return self.depth == 0;
    }

    /// Check if this is a sub-call (depth > 0)
    pub fn isSubCall(self: *const StepInfo) bool {
        return self.depth > 0;
    }
};

/// Stack changes with enhanced tracking
pub const StackChanges = struct {
    items_pushed: []u256,
    items_popped: []u256,
    current_stack: []u256,

    pub fn deinit(self: *const StackChanges, allocator: std.mem.Allocator) void {
        allocator.free(self.items_pushed);
        allocator.free(self.items_popped);
        allocator.free(self.current_stack);
    }

    pub fn getPushCount(self: *const StackChanges) usize {
        return self.items_pushed.len;
    }

    pub fn getPopCount(self: *const StackChanges) usize {
        return self.items_popped.len;
    }

    pub fn getCurrentDepth(self: *const StackChanges) usize {
        return self.current_stack.len;
    }
};

/// Memory changes with enhanced tracking
pub const MemoryChanges = struct {
    offset: u64,
    data: []u8,
    current_memory: []u8,

    pub fn deinit(self: *const MemoryChanges, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
        allocator.free(self.current_memory);
    }

    pub fn getModificationSize(self: *const MemoryChanges) usize {
        return self.data.len;
    }

    pub fn getCurrentSize(self: *const MemoryChanges) usize {
        return self.current_memory.len;
    }

    pub fn wasModified(self: *const MemoryChanges) bool {
        return self.data.len > 0;
    }
};

/// Post-execution step results with bounded captures
pub const StepResult = struct {
    /// Gas remaining after executing this opcode
    gas_after: u64,
    /// Gas consumed by this opcode (gas_before - gas_after)
    gas_cost: u64,
    /// Bounded snapshot of stack state (null if exceeds bounds)
    stack_snapshot: ?[]u256,
    /// Bounded snapshot of memory state (null if exceeds bounds)
    memory_snapshot: ?[]u8,
    /// Enhanced stack change tracking
    stack_changes: StackChanges,
    /// Enhanced memory change tracking
    memory_changes: MemoryChanges,
    /// Storage changes made during this step
    storage_changes: []StorageChange,
    /// Log entries emitted during this step
    logs_emitted: []LogEntry,
    /// Error information if the step failed
    error_info: ?ExecutionErrorInfo,

    /// Check if operation was successful
    pub fn isSuccess(self: *const StepResult) bool {
        return self.error_info == null;
    }

    /// Check if operation failed
    pub fn isFailure(self: *const StepResult) bool {
        return self.error_info != null;
    }

    /// Clean up allocated memory for step result
    pub fn deinit(self: *const StepResult, allocator: std.mem.Allocator) void {
        self.stack_changes.deinit(allocator);
        self.memory_changes.deinit(allocator);
        allocator.free(self.storage_changes);
        for (self.logs_emitted) |*log| {
            log.deinit(allocator);
        }
        allocator.free(self.logs_emitted);
        if (self.stack_snapshot) |stack| {
            allocator.free(stack);
        }
        if (self.memory_snapshot) |memory| {
            allocator.free(memory);
        }
    }
};

/// Storage change entry capturing slot modifications
pub const StorageChange = struct {
    /// Contract address whose storage was modified
    address: Address,
    /// Storage slot key that was changed
    key: u256,
    /// New value stored in the slot
    value: u256,
    /// Original value before this transaction
    original_value: u256,

    pub fn isWrite(self: *const StorageChange) bool {
        return self.original_value != self.value;
    }

    pub fn isClear(self: *const StorageChange) bool {
        return self.value == 0;
    }
};

/// Log entry with bounded data capture
pub const LogEntry = struct {
    /// Contract address that emitted the log
    address: Address,
    /// Log topics (always include all topics, not bounded)
    topics: []const u256,
    /// Log data (bounded by config.log_data_max_bytes)
    data: []const u8,
    /// True if original data was larger than captured
    data_truncated: bool,

    pub fn deinit(self: *const LogEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.topics);
        allocator.free(self.data);
    }

    pub fn getTopicCount(self: *const LogEntry) usize {
        return self.topics.len;
    }

    pub fn getDataSize(self: *const LogEntry) usize {
        return self.data.len;
    }

    pub fn hasTopics(self: *const LogEntry) bool {
        return self.topics.len > 0;
    }

    pub fn hasData(self: *const LogEntry) bool {
        return self.data.len > 0;
    }
};

/// Execution error information
pub const ExecutionErrorInfo = struct {
    /// Error type that occurred
    error_type: ExecutionError.Error,
    /// Human-readable error description
    description: []const u8,
    /// PC where error occurred
    error_pc: ?usize = null,
};

/// Combined step entry for structured logs (JSON-compatible format)
pub const StructLog = struct {
    /// Program counter for this step
    pc: usize,
    /// Opcode name as string
    op: []const u8,
    /// Gas available before execution
    gas: u64,
    /// Gas consumed by this step
    gas_cost: u64,
    /// Call depth
    depth: u16,
    /// Stack snapshot (null if bounded out)
    stack: ?[]const u256,
    /// Memory snapshot (null if bounded out)
    memory: ?[]const u8,
    /// Error information if step failed
    error_info: ?ExecutionErrorInfo,

    /// Actual stack changes (items pushed/popped) during this step
    stack_changes: ?*const StackChanges,
    /// Actual memory changes (regions modified) during this step
    memory_changes: ?*const MemoryChanges,
    /// Storage changes during this step
    storage_changes: []const StorageChange,
    /// Log entries emitted during this step
    logs_emitted: []const LogEntry,
};

/// Complete execution trace with all captured steps
pub const ExecutionTrace = struct {
    /// Total gas consumed during execution
    gas_used: u64,
    /// Whether execution failed (reverted or threw error)
    failed: bool,
    /// Return data from execution (empty if failed)
    return_value: []const u8,
    /// Array of all captured execution steps
    struct_logs: []const StructLog,

    /// Clean up all allocations in the trace
    /// Must be called by the owner when done with the trace
    pub fn deinit(self: *ExecutionTrace, allocator: std.mem.Allocator) void {
        // Free all struct logs and their nested allocations
        for (self.struct_logs) |*log| {
            // Free stack snapshot
            if (log.stack) |stack| {
                allocator.free(stack);
            }

            // Free memory snapshot
            if (log.memory) |memory| {
                allocator.free(memory);
            }

            // Free storage changes
            for (log.storage_changes) |*change| {
                _ = change; // Storage changes are simple values, no nested allocs
            }
            allocator.free(log.storage_changes);

            // Free log entries and their nested data
            for (log.logs_emitted) |*log_entry| {
                allocator.free(log_entry.topics);
                allocator.free(log_entry.data);
            }
            allocator.free(log.logs_emitted);

            // Free new state change tracking fields
            if (log.stack_changes) |changes_ptr| {
                changes_ptr.deinit(allocator);
                allocator.destroy(changes_ptr);
            }

            if (log.memory_changes) |changes_ptr| {
                changes_ptr.deinit(allocator);
                allocator.destroy(changes_ptr);
            }
        }

        // Free top-level arrays
        allocator.free(self.struct_logs);
        allocator.free(self.return_value);
    }
};

/// Final execution result information
pub const FinalResult = struct {
    /// Total gas consumed during execution
    gas_used: u64,
    /// Whether execution failed
    failed: bool,
    /// Data returned by execution
    return_value: []const u8,
    /// Final execution status
    status: ExecutionStatus,

    /// Check if execution was successful
    pub fn isSuccess(self: *const FinalResult) bool {
        return !self.failed and self.status == .Success;
    }

    /// Check if execution was reverted
    pub fn isRevert(self: *const FinalResult) bool {
        return self.failed and self.status == .Revert;
    }
};

/// Execution status enumeration
pub const ExecutionStatus = enum {
    Success,
    Revert,
    OutOfGas,
    InvalidOpcode,
    StackUnderflow,
    StackOverflow,
    InvalidJump,

    /// Convert status to string for debugging
    pub fn toString(self: ExecutionStatus) []const u8 {
        return switch (self) {
            .Success => "Success",
            .Revert => "Revert",
            .OutOfGas => "OutOfGas",
            .InvalidOpcode => "InvalidOpcode",
            .StackUnderflow => "StackUnderflow",
            .StackOverflow => "StackOverflow",
            .InvalidJump => "InvalidJump",
        };
    }
};

/// Enhanced execution error information
pub const ExecutionErrorEnhanced = struct {
    /// Error type
    error_type: ErrorType,
    /// Human-readable error message
    message: []const u8,
    /// Program counter where error occurred
    pc: u64,
    /// Gas remaining when error occurred
    gas_remaining: u64,

    pub const ErrorType = enum {
        OutOfGas,
        InvalidOpcode,
        StackUnderflow,
        StackOverflow,
        InvalidJump,
        InvalidMemoryAccess,
        InvalidStorageAccess,
        RevertExecution,

        /// Convert error type to string
        pub fn toString(self: ErrorType) []const u8 {
            return switch (self) {
                .OutOfGas => "OutOfGas",
                .InvalidOpcode => "InvalidOpcode",
                .StackUnderflow => "StackUnderflow",
                .StackOverflow => "StackOverflow",
                .InvalidJump => "InvalidJump",
                .InvalidMemoryAccess => "InvalidMemoryAccess",
                .InvalidStorageAccess => "InvalidStorageAccess",
                .RevertExecution => "RevertExecution",
            };
        }
    };

    /// Check if error is recoverable
    pub fn isRecoverable(self: *const ExecutionErrorEnhanced) bool {
        return self.error_type == .RevertExecution;
    }

    /// Check if error is fatal
    pub fn isFatal(self: *const ExecutionErrorEnhanced) bool {
        return !self.isRecoverable();
    }
};

/// Complete tracer interface with all methods from original spec
pub const TracerVTable = struct {
    /// Called before each opcode execution
    step_before: *const fn (ptr: *anyopaque, step_info: StepInfo) void,
    /// Called after each opcode execution
    step_after: *const fn (ptr: *anyopaque, step_result: StepResult) void,
    /// Called when execution completes
    finalize: *const fn (ptr: *anyopaque, final_result: FinalResult) void,
    /// Get the complete execution trace
    get_trace: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!ExecutionTrace,
    /// Clean up tracer resources
    deinit: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) void,
};

/// Enhanced TracerHandle with complete interface
pub const TracerHandle = struct {
    ptr: *anyopaque,
    vtable: *const TracerVTable,

    pub fn stepBefore(self: TracerHandle, step_info: StepInfo) void {
        self.vtable.step_before(self.ptr, step_info);
    }

    pub fn stepAfter(self: TracerHandle, step_result: StepResult) void {
        self.vtable.step_after(self.ptr, step_result);
    }

    pub fn finalize(self: TracerHandle, final_result: FinalResult) void {
        self.vtable.finalize(self.ptr, final_result);
    }

    pub fn getTrace(self: TracerHandle, allocator: std.mem.Allocator) !ExecutionTrace {
        return self.vtable.get_trace(self.ptr, allocator);
    }

    pub fn deinit(self: TracerHandle, allocator: std.mem.Allocator) void {
        self.vtable.deinit(self.ptr, allocator);
    }

    // Backward compatibility methods
    pub fn on_pre_step(self: TracerHandle, step_info: StepInfo) void {
        self.stepBefore(step_info);
    }

    pub fn on_post_step(self: TracerHandle, step_result: StepResult) void {
        self.stepAfter(step_result);
    }

    pub fn on_finish(self: TracerHandle, return_value: []const u8, success: bool) void {
        const final_result = FinalResult{
            .gas_used = 0,
            .failed = !success,
            .return_value = return_value,
            .status = if (success) .Success else .Revert,
        };
        self.finalize(final_result);
    }
};

// Helper creation functions

/// Helper function to create empty stack changes
pub fn createEmptyStackChanges(allocator: std.mem.Allocator) !StackChanges {
    return StackChanges{
        .items_pushed = try allocator.alloc(u256, 0),
        .items_popped = try allocator.alloc(u256, 0),
        .current_stack = try allocator.alloc(u256, 0),
    };
}

/// Helper function to create empty memory changes
pub fn createEmptyMemoryChanges(allocator: std.mem.Allocator) !MemoryChanges {
    return MemoryChanges{
        .offset = 0,
        .data = try allocator.alloc(u8, 0),
        .current_memory = try allocator.alloc(u8, 0),
    };
}

/// Helper function to create empty step result
pub fn createEmptyStepResult(allocator: std.mem.Allocator) !StepResult {
    return StepResult{
        .gas_after = 0,
        .gas_cost = 0,
        .stack_snapshot = null,
        .memory_snapshot = null,
        .stack_changes = try createEmptyStackChanges(allocator),
        .memory_changes = try createEmptyMemoryChanges(allocator),
        .storage_changes = try allocator.alloc(StorageChange, 0),
        .logs_emitted = try allocator.alloc(LogEntry, 0),
        .error_info = null,
    };
}
