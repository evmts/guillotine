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

        // Changes (optional detailed tracking)
        stack_snapshot: ?[]const u256,
        memory_snapshot: ?[]const u8,
        storage_changes: []const tracer.StorageChange,
        logs_emitted: []const tracer.LogEntry,
        error_info: ?tracer.ExecutionErrorInfo,
    };

    /// Complete message transition with before/after state for CALL/CREATE operations
    pub const MessageTransition = struct {
        before: tracer.MessageEvent,
        after: tracer.MessageEvent,
        gas_used: u64,
        success: bool,
        depth_delta: i16, // How depth changed (positive for deeper calls, negative for returns)
    };

    // === Callback Function Types ===
    pub const OnStepTransitionFn = *const fn (
        self: *MemoryTracer,
        transition: StepTransition,
    ) anyerror!tracer.StepControl;

    pub const OnBeforeStepFn = *const fn (
        self: *MemoryTracer,
        info: tracer.StepInfo,
    ) anyerror!void;

    pub const OnAfterStepFn = *const fn (
        self: *MemoryTracer,
        result: tracer.StepResult,
    ) anyerror!void;

    pub const OnMessageFn = *const fn (
        self: *MemoryTracer,
        event: tracer.MessageEvent,
    ) anyerror!void;

    pub const OnMessageTransitionFn = *const fn (
        self: *MemoryTracer,
        before_event: tracer.MessageEvent,
        after_event: tracer.MessageEvent,
    ) anyerror!void;

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

    // === Execution Control ===
    step_mode: enum {
        passive, // Normal tracing (default)
        single_step, // Pause after each instruction
        breakpoint, // Pause at specific PCs
    } = .passive,

    breakpoints: std.AutoHashMap(usize, void),

    // === New Callbacks ===
    on_step_transition: ?OnStepTransitionFn = null,
    on_before_step_hook: ?OnBeforeStepFn = null,
    on_after_step_hook: ?OnAfterStepFn = null,
    on_message_hook: ?OnMessageFn = null,
    on_message_transition_hook: ?OnMessageTransitionFn = null,

    // === Transition Storage ===
    transitions: std.ArrayList(StepTransition),
    last_transition: ?StepTransition = null,
    message_transitions: std.ArrayList(MessageTransition),

    // === Control State ===
    pending_control: tracer.StepControl = tracer.StepControl.cont,

    // VTable with all tracer methods - MemoryTracer implements all optional hooks
    const VTABLE = tracer.TracerVTable{
        .on_step_before = on_step_before_impl,
        .on_step_after = on_step_after_impl,
        .on_step_transition = on_step_transition_impl,
        .on_message_before = onMessageBefore_impl,
        .on_message_after = onMessageAfter_impl,
        .on_message_transition = onMessageTransition_impl,
        .get_step_control = get_step_control_impl,
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

            // ADD THESE INITIALIZATIONS:
            .step_mode = .passive,
            .breakpoints = std.AutoHashMap(usize, void).init(allocator),
            .on_step_transition = null,
            .on_before_step_hook = null,
            .on_after_step_hook = null,
            .on_message_hook = null,
            .on_message_transition_hook = null,
            .transitions = std.ArrayList(StepTransition).init(allocator),
            .last_transition = null,
            .message_transitions = std.ArrayList(MessageTransition).init(allocator),
            .pending_control = tracer.StepControl.cont,
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

        // ADD THIS CLEANUP:
        self.breakpoints.deinit();

        // Clean up transitions
        for (self.transitions.items) |*trans| {
            if (trans.stack_snapshot) |stack| {
                self.allocator.free(stack);
            }
            if (trans.memory_snapshot) |memory| {
                self.allocator.free(memory);
            }
            self.allocator.free(trans.storage_changes);
            self.allocator.free(trans.logs_emitted);
        }
        self.transitions.deinit();

        // Clean up message transitions
        self.message_transitions.deinit();
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
    fn on_step_before_impl(ptr: *anyopaque, step_info: tracer.StepInfo) void {
        const self: *MemoryTracer = @ptrCast(@alignCast(ptr));

        // Call optional before hook first
        if (self.on_before_step_hook) |hook| {
            hook(self, step_info) catch |err| {
                std.log.warn("on_before_step_hook error: {}", .{err});
            };
        }

        // Store step info for later combination with post-step results
        self.current_step_info = step_info;
    }

    fn on_step_after_impl(ptr: *anyopaque, step_result: tracer.StepResult) void {
        const self: *MemoryTracer = @ptrCast(@alignCast(ptr));

        // Call optional after hook first
        if (self.on_after_step_hook) |hook| {
            hook(self, step_result) catch |err| {
                std.log.warn("on_after_step_hook error: {}", .{err});
            };
        }

        // Build complete StructLog entry combining pre/post step data
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

        if (stack_changes_ptr) |stack_ptr| {
            stack_ptr.* = step_result.stack_changes;
        }

        const memory_changes_ptr = if (step_result.memory_changes.data.len > 0)
            self.allocator.create(tracer.MemoryChanges) catch null
        else
            null;

        if (memory_changes_ptr) |memory_ptr| {
            memory_ptr.* = step_result.memory_changes;
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

    /// Get current control decision
    fn get_step_control_impl(ptr: *anyopaque) tracer.StepControl {
        const self: *MemoryTracer = @ptrCast(@alignCast(ptr));

        // Check step mode
        const control = switch (self.step_mode) {
            .passive => tracer.StepControl.cont,
            .single_step => tracer.StepControl.pause,
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

    /// Handle step transition events (complete before→after state)
    fn on_step_transition_impl(ptr: *anyopaque, step_info: tracer.StepInfo, step_result: tracer.StepResult) void {
        const self: *MemoryTracer = @ptrCast(@alignCast(ptr));

        // Build transition with temporary references for hook call
        const transition = self.build_transition(step_info, step_result);

        // Store transition in transitions list for analysis
        // Make a copy with allocated data that will persist
        const stored_transition = StepTransition{
            // Pre-state from info
            .pc = transition.pc,
            .opcode = transition.opcode,
            .op_name = transition.op_name,
            .gas_before = transition.gas_before,
            .stack_size_before = transition.stack_size_before,
            .memory_size_before = transition.memory_size_before,
            .depth = transition.depth,
            .address = transition.address,

            // Post-state from result
            .gas_after = transition.gas_after,
            .gas_cost = transition.gas_cost,
            .stack_size_after = transition.stack_size_after,
            .memory_size_after = transition.memory_size_after,

            // Store null for expensive data to avoid memory leaks in stored transitions
            .stack_snapshot = null,
            .memory_snapshot = null,
            .storage_changes = &[_]tracer.StorageChange{}, // Empty slice
            .logs_emitted = &[_]tracer.LogEntry{}, // Empty slice
            .error_info = transition.error_info,
        };

        self.transitions.append(stored_transition) catch |err| {
            std.log.warn("Failed to store step transition: {}", .{err});
        };

        // Store reference for last_transition (used by breakpoint logic)
        self.last_transition = stored_transition;

        // Call optional step transition hook if set
        if (self.on_step_transition) |hook| {
            const control = hook(self, transition) catch |err| {
                std.log.warn("on_step_transition error: {}", .{err});
                return;
            };
            self.pending_control = control;
        }
    }

    /// Handle message before events (CALL/CREATE operations before execution)
    fn onMessageBefore_impl(ptr: *anyopaque, event: tracer.MessageEvent) void {
        const self: *MemoryTracer = @ptrCast(@alignCast(ptr));

        // Store before event for potential transition hook
        // For now, just call user hook if set
        if (self.on_message_hook) |hook| {
            hook(self, event) catch |err| {
                std.log.warn("onMessageBefore hook error: {}", .{err});
            };
        }
    }

    /// Handle message after events (CALL/CREATE operations after execution)
    fn onMessageAfter_impl(ptr: *anyopaque, event: tracer.MessageEvent) void {
        const self: *MemoryTracer = @ptrCast(@alignCast(ptr));

        // Call user hook if set
        if (self.on_message_hook) |hook| {
            hook(self, event) catch |err| {
                std.log.warn("onMessageAfter hook error: {}", .{err});
            };
        }
    }

    /// Handle complete message transition (before→after CALL/CREATE)
    fn onMessageTransition_impl(ptr: *anyopaque, before_event: tracer.MessageEvent, after_event: tracer.MessageEvent) void {
        const self: *MemoryTracer = @ptrCast(@alignCast(ptr));

        // Track message transitions - useful for analyzing call patterns, gas usage, and nested execution
        // This provides complete before→after state for CALL/CREATE operations

        // Store transition for analysis
        const gas_after = after_event.gas_after orelse before_event.gas_before;
        const gas_used = if (before_event.gas_before >= gas_after)
            before_event.gas_before - gas_after
        else
            0; // Protect against underflow if gas somehow increased

        const transition = MessageTransition{
            .before = before_event,
            .after = after_event,
            .gas_used = gas_used,
            .success = if (after_event.result) |result| result.success else false,
            .depth_delta = @as(i16, @intCast(after_event.depth)) - @as(i16, @intCast(before_event.depth)),
        };

        // Store in message transitions list
        self.message_transitions.append(transition) catch |err| {
            std.log.warn("Failed to store message transition: {}", .{err});
        };

        // Call user hook if set
        if (self.on_message_transition_hook) |hook| {
            hook(self, before_event, after_event) catch |err| {
                std.log.warn("onMessageTransition hook error: {}", .{err});
            };
        }
    }

    // Implementation methods

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

    /// Build complete transition from pre and post state
    fn build_transition(
        self: *MemoryTracer,
        info: tracer.StepInfo,
        result: tracer.StepResult,
    ) StepTransition {
        // For temporary transitions, reference original data within bounds - no allocation
        const stack_ref = if (result.stack_snapshot) |stack|
            if (stack.len <= self.config.stack_max_items) stack else null
        else
            null;

        const memory_ref = if (result.memory_snapshot) |memory|
            if (memory.len <= self.config.memory_max_bytes) memory else null
        else
            null;

        return StepTransition{
            // Pre-state from info
            .pc = info.pc,
            .opcode = info.opcode,
            .op_name = info.op_name,
            .gas_before = info.gas_before,
            .stack_size_before = info.stack_size,
            .memory_size_before = info.memory_size,
            .depth = info.depth,
            .address = info.address,

            // Post-state from result
            .gas_after = result.gas_after,
            .gas_cost = result.gas_cost,
            .stack_size_after = info.stack_size +
                result.stack_changes.getPushCount() -
                result.stack_changes.getPopCount(),
            .memory_size_after = info.memory_size +
                (if (result.memory_changes.wasModified())
                    result.memory_changes.getModificationSize()
                else
                    0),

            // Reference original data for temporary hook calls - no allocation
            .stack_snapshot = stack_ref,
            .memory_snapshot = memory_ref,
            // Reference original data for temporary transition - no duplication needed
            .storage_changes = result.storage_changes,
            .logs_emitted = result.logs_emitted,
            .error_info = result.error_info,
        };
    }

    // === NEW CONTROL METHODS ===

    /// Set execution mode
    pub fn set_step_mode(self: *MemoryTracer, mode: @TypeOf(self.step_mode)) void {
        self.step_mode = mode;
    }

    /// Add a breakpoint at PC
    pub fn add_breakpoint(self: *MemoryTracer, pc: usize) !void {
        try self.breakpoints.put(pc, {});
    }

    /// Remove a breakpoint
    pub fn remove_breakpoint(self: *MemoryTracer, pc: usize) bool {
        return self.breakpoints.remove(pc);
    }

    /// Clear all breakpoints
    pub fn clear_breakpoints(self: *MemoryTracer) void {
        self.breakpoints.clearAndFree();
    }

    /// Execute one step (requires EVM support - see Phase 3)
    pub fn step_once(self: *MemoryTracer) !?StepTransition {
        self.set_step_mode(.single_step);
        // After Phase 3, this will cause execution to pause after one instruction
        return self.last_transition;
    }

    /// Continue execution until breakpoint
    pub fn continue_execution(self: *MemoryTracer) void {
        self.set_step_mode(.breakpoint);
    }
};
