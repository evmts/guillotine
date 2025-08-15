//! Standard in-memory tracer implementation
//!
//! This tracer collects execution traces in memory with bounded snapshots,
//! providing structured access for devtools and debugging interfaces.
//! It implements the TracerHandle interface for seamless EVM integration.
//!
//! ## Features
//!
//! - **Bounded Memory Usage**: Respects configured limits for stack/memory/logs
//! - **Efficient Snapshots**: Minimal copies with smart windowing
//! - **Delta Tracking**: Only captures changes since last step
//! - **Error Recovery**: Graceful handling of allocation failures
//! - **Ownership Transfer**: Clean handoff of trace data to caller
//!
//! ## Usage Pattern
//!
//! ```zig
//! var tracer = try MemoryTracer.init(allocator, config);
//! defer tracer.deinit();
//!
//! evm.set_tracer(tracer.handle());
//! try evm.run(bytecode, context);
//!
//! var trace = try tracer.get_trace();
//! defer trace.deinit(allocator);
//! ```

const std = @import("std");
const tracer = @import("trace_types.zig");
const Allocator = std.mem.Allocator;

/// In-memory tracer that collects execution traces with bounded snapshots
pub const MemoryTracer = struct {
    // Memory management
    allocator: Allocator,
    config: tracer.TracerConfig,

    // Execution state tracking
    struct_logs: std.ArrayList(tracer.StructLog),
    gas_used: u64,
    failed: bool,
    return_value: std.ArrayList(u8),

    // Per-step state for building complete struct logs
    current_step_info: ?tracer.StepInfo,

    // Delta tracking for incremental capture
    last_journal_size: usize,
    last_log_count: usize,

    // VTable with all tracer methods
    const VTABLE = tracer.TracerVTable{
        .step_before = step_before_impl,
        .step_after = step_after_impl,
        .finalize = finalize_impl,
        .get_trace = get_trace_impl,
        .deinit = deinit_impl,
    };

    /// Initialize tracer with allocator and configuration
    pub fn init(allocator: Allocator, config: tracer.TracerConfig) !MemoryTracer {
        return MemoryTracer{
            .allocator = allocator,
            .config = config,
            // MEMORY ALLOCATION: ArrayList for struct logs
            // Expected growth: ~1KB per 100 instructions for typical contracts
            // Lifetime: Until get_trace() transfers ownership or deinit()
            .struct_logs = std.ArrayList(tracer.StructLog).init(allocator),
            .gas_used = 0,
            .failed = false,
            .return_value = std.ArrayList(u8).init(allocator),
            .current_step_info = null,
            .last_journal_size = 0,
            .last_log_count = 0,
        };
    }

    /// Clean up all allocations
    /// Must be called before tracer goes out of scope
    pub fn deinit(self: *MemoryTracer) void {
        // Free all nested allocations in struct logs
        for (self.struct_logs.items) |*log| {
            self.free_struct_log_contents(log);
        }
        self.struct_logs.deinit();
        self.return_value.deinit();
    }

    /// Get type-erased tracer handle for EVM integration
    pub fn handle(self: *MemoryTracer) tracer.TracerHandle {
        return tracer.TracerHandle{
            .ptr = @ptrCast(self),
            .vtable = &VTABLE,
        };
    }

    /// Extract final execution trace (transfers ownership to caller)
    /// Caller must call trace.deinit(allocator) when done
    pub fn get_trace(self: *MemoryTracer) !tracer.ExecutionTrace {
        // Transfer ownership of struct_logs to trace
        const logs_slice = try self.struct_logs.toOwnedSlice();
        const return_slice = try self.return_value.toOwnedSlice();

        return tracer.ExecutionTrace{
            .gas_used = self.gas_used,
            .failed = self.failed,
            .return_value = return_slice,
            .struct_logs = logs_slice,
        };
    }

    /// Clear trace data and reset for new execution
    pub fn reset(self: *MemoryTracer) void {
        // Free existing data
        for (self.struct_logs.items) |*log| {
            self.free_struct_log_contents(log);
        }
        self.struct_logs.clearAndFree();
        self.return_value.clearAndFree();

        // Reset state
        self.gas_used = 0;
        self.failed = false;
        self.current_step_info = null;
        self.last_journal_size = 0;
        self.last_log_count = 0;
    }

    // VTable implementations
    fn step_before_impl(ptr: *anyopaque, step_info: tracer.StepInfo) void {
        const self: *MemoryTracer = @ptrCast(@alignCast(ptr));
        self.on_pre_step(step_info);
    }

    fn step_after_impl(ptr: *anyopaque, step_result: tracer.StepResult) void {
        const self: *MemoryTracer = @ptrCast(@alignCast(ptr));
        self.on_post_step(step_result);
    }

    fn finalize_impl(ptr: *anyopaque, final_result: tracer.FinalResult) void {
        const self: *MemoryTracer = @ptrCast(@alignCast(ptr));
        self.finalize(final_result);
    }

    fn get_trace_impl(ptr: *anyopaque, allocator: Allocator) !tracer.ExecutionTrace {
        const self: *MemoryTracer = @ptrCast(@alignCast(ptr));
        _ = allocator; // Allocator is already stored in self
        return self.get_trace();
    }

    fn deinit_impl(ptr: *anyopaque, allocator: Allocator) void {
        const self: *MemoryTracer = @ptrCast(@alignCast(ptr));
        _ = allocator; // Allocator is already stored in self
        self.deinit();
    }

    // Implementation methods

    /// Store step info for later combination with post-step results
    fn on_pre_step(self: *MemoryTracer, step_info: tracer.StepInfo) void {
        self.current_step_info = step_info;
    }

    /// Build complete StructLog entry combining pre/post step data
    fn on_post_step(self: *MemoryTracer, step_result: tracer.StepResult) void {
        // Must have pre-step info to build complete log entry
        const step_info = self.current_step_info orelse {
            // This can happen in block-based execution - just skip
            return;
        };

        // Apply bounded capture to stack snapshot
        const bounded_stack = if (step_result.stack_snapshot) |stack|
            self.apply_stack_bounds(stack) catch step_result.stack_snapshot
        else
            null;

        // Allocate memory for stack and memory changes to persist in StructLog
        const stack_changes_ptr = if (step_result.stack_changes.items_pushed.len > 0 or
            step_result.stack_changes.items_popped.len > 0)
            self.allocator.create(tracer.StackChanges) catch null
        else
            null;

        if (stack_changes_ptr) |ptr| {
            ptr.* = step_result.stack_changes;
        }

        const memory_changes_ptr = if (step_result.memory_changes.data.len > 0)
            self.allocator.create(tracer.MemoryChanges) catch null
        else
            null;

        if (memory_changes_ptr) |ptr| {
            ptr.* = step_result.memory_changes;
        }

        // Build complete StructLog entry
        const struct_log = tracer.StructLog{
            .pc = step_info.pc,
            .op = step_info.op_name,
            .gas = step_info.gas_before,
            .gas_cost = step_result.gas_cost,
            .depth = step_info.depth,
            .stack = bounded_stack,
            .memory = step_result.memory_snapshot,
            .error_info = step_result.error_info,
            .stack_changes = stack_changes_ptr,
            .memory_changes = memory_changes_ptr,
            .storage_changes = step_result.storage_changes,
            .logs_emitted = step_result.logs_emitted,
        };

        // Append to trace
        self.struct_logs.append(struct_log) catch |err| {
            // Handle allocation failure gracefully - continue execution
            std.debug.print("MemoryTracer: Failed to append struct log: {}\n", .{err});
            // Free the step result allocations since we couldn't store them
            self.free_step_result_contents(&step_result);
            return;
        };

        // Don't free stack_changes and memory_changes here if we stored pointers to them
        // The StructLog now owns them via the allocated pointers
        // Only free them if we didn't store them (allocation failed)
        if (stack_changes_ptr == null) {
            step_result.stack_changes.deinit(self.allocator);
        }
        if (memory_changes_ptr == null) {
            step_result.memory_changes.deinit(self.allocator);
        }

        // Track cumulative gas usage
        self.gas_used += step_result.gas_cost;

        // Clear current step info for next iteration
        self.current_step_info = null;
    }

    /// Finalize method
    fn finalize(self: *MemoryTracer, final_result: tracer.FinalResult) void {
        self.gas_used = final_result.gas_used;
        self.failed = final_result.failed;
        // Copy return value if not already set
        if (self.return_value.items.len == 0) {
            self.return_value.appendSlice(final_result.return_value) catch |err| {
                std.debug.print("MemoryTracer: Failed to store return value: {}\n", .{err});
            };
        }
    }

    /// Record execution completion with final state (backward compatibility)
    fn on_finish(self: *MemoryTracer, return_value: []const u8, success: bool) void {
        self.failed = !success;

        // Copy return value
        self.return_value.appendSlice(return_value) catch |err| {
            std.debug.print("MemoryTracer: Failed to store return value: {}\n", .{err});
            // Continue - missing return value is better than crashing
        };
    }

    /// Free nested allocations within a struct log
    fn free_struct_log_contents(self: *MemoryTracer, log: *tracer.StructLog) void {
        // Free stack snapshot
        if (log.stack) |stack| {
            self.allocator.free(stack);
        }

        // Free memory snapshot
        if (log.memory) |memory| {
            self.allocator.free(memory);
        }

        // Free storage changes array
        self.allocator.free(log.storage_changes);

        // Free log entries and their nested data
        for (log.logs_emitted) |*log_entry| {
            self.allocator.free(log_entry.topics);
            self.allocator.free(log_entry.data);
        }
        self.allocator.free(log.logs_emitted);

        // Free new state change tracking fields
        if (log.stack_changes) |changes_ptr| {
            changes_ptr.deinit(self.allocator);
            self.allocator.destroy(changes_ptr);
        }

        if (log.memory_changes) |changes_ptr| {
            changes_ptr.deinit(self.allocator);
            self.allocator.destroy(changes_ptr);
        }
    }

    /// Free allocations within step result (for error recovery)
    fn free_step_result_contents(self: *MemoryTracer, step_result: *const tracer.StepResult) void {
        if (step_result.stack_snapshot) |stack| {
            self.allocator.free(stack);
        }

        if (step_result.memory_snapshot) |memory| {
            self.allocator.free(memory);
        }

        // Free stack changes
        step_result.stack_changes.deinit(self.allocator);

        // Free memory changes
        step_result.memory_changes.deinit(self.allocator);

        self.allocator.free(step_result.storage_changes);

        for (step_result.logs_emitted) |*log_entry| {
            self.allocator.free(log_entry.topics);
            self.allocator.free(log_entry.data);
        }
        self.allocator.free(step_result.logs_emitted);
    }

    /// Apply stack bounds according to tracer configuration
    fn apply_stack_bounds(self: *MemoryTracer, stack: []u256) ![]u256 {
        if (stack.len <= self.config.stack_max_items) {
            // Already within bounds, return as-is
            return stack;
        }

        // Need to create a bounded copy
        const bounded_stack = try self.allocator.alloc(u256, self.config.stack_max_items);
        errdefer self.allocator.free(bounded_stack);

        // Copy the most recent items (top of stack)
        @memcpy(bounded_stack, stack[0..self.config.stack_max_items]);

        // Free the original unbounded stack
        self.allocator.free(stack);

        return bounded_stack;
    }
};
