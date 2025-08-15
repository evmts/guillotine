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
    /// Storage changes made during this step
    storage_changes: []StorageChange,
    /// Log entries emitted during this step
    logs_emitted: []LogEntry,
    /// Error information if the step failed
    error_info: ?ExecutionErrorInfo,
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
    /// Storage changes during this step
    storage: []const StorageChange,
    /// Logs emitted during this step
    logs: []const LogEntry,
    /// Error information if step failed
    error_info: ?ExecutionErrorInfo,
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
            for (log.storage) |*change| {
                _ = change; // Storage changes are simple values, no nested allocs
            }
            allocator.free(log.storage);
            
            // Free log entries and their nested data
            for (log.logs) |*log_entry| {
                allocator.free(log_entry.topics);
                allocator.free(log_entry.data);
            }
            allocator.free(log.logs);
        }
        
        // Free top-level arrays
        allocator.free(self.struct_logs);
        allocator.free(self.return_value);
    }
};

/// Zero-allocation tracer interface using function pointers
/// This allows different tracer implementations to be used without
/// runtime overhead when no tracer is configured
pub const TracerVTable = struct {
    /// Called before each opcode execution with step context
    on_pre_step: *const fn (ptr: *anyopaque, step_info: StepInfo) void,
    
    /// Called after each opcode execution with results
    on_post_step: *const fn (ptr: *anyopaque, step_result: StepResult) void,
    
    /// Called when execution completes (successfully or with error)
    on_finish: *const fn (ptr: *anyopaque, return_value: []const u8, success: bool) void,
};

/// Type-erased tracer handle for EVM integration
/// This provides a uniform interface regardless of the underlying tracer type
pub const TracerHandle = struct {
    /// Pointer to the actual tracer implementation
    ptr: *anyopaque,
    /// Virtual table for calling tracer methods
    vtable: *const TracerVTable,
    
    /// Call pre-step hook on the tracer
    pub fn on_pre_step(self: TracerHandle, step_info: StepInfo) void {
        self.vtable.on_pre_step(self.ptr, step_info);
    }
    
    /// Call post-step hook on the tracer
    pub fn on_post_step(self: TracerHandle, step_result: StepResult) void {
        self.vtable.on_post_step(self.ptr, step_result);
    }
    
    /// Call finish hook on the tracer
    pub fn on_finish(self: TracerHandle, return_value: []const u8, success: bool) void {
        self.vtable.on_finish(self.ptr, return_value, success);
    }
};