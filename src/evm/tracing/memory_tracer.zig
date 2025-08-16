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
//! ## Usage Patterns
//!
//! ### Basic Tracing
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
//!
//! ### Manual Stepping with Fine-Grained Control
//! ```zig
//! var tracer = try MemoryTracer.init(allocator, config);
//! defer tracer.deinit();
//! 
//! // Single instruction stepping
//! while (true) {
//!     const step = try tracer.execute_single_step(&evm, &frame);
//!     if (step == null) break; // Execution completed
//!     
//!     // Inspect state between each instruction
//!     std.log.info("PC: {}, Stack size: {}, Gas: {}", .{
//!         step.?.pc, step.?.stack_size_after, step.?.gas_after
//!     });
//! }
//! ```
//!
//! ### Breakpoint-Based Debugging
//! ```zig
//! var tracer = try MemoryTracer.init(allocator, config);
//! defer tracer.deinit();
//!
//! // Set breakpoints at specific PCs
//! try tracer.add_breakpoint(42);  // Stop at PC 42
//! try tracer.add_breakpoint(100); // Stop at PC 100
//!
//! // Run until breakpoint
//! const result = try tracer.execute_until_breakpoint(&evm, &frame);
//! if (result) |step| {
//!     std.log.info("Hit breakpoint at PC: {}", .{step.pc});
//!     
//!     // Inspect or modify state here
//!     // ...
//!     
//!     // Continue execution
//!     tracer.continue_execution();
//!     _ = try tracer.execute_until_breakpoint(&evm, &frame);
//! }
//! ```
//!
//! ### Block-Level Stepping
//! ```zig
//! var tracer = try MemoryTracer.init(allocator, config);
//! defer tracer.deinit();
//!
//! // Execute one analysis block at a time
//! while (true) {
//!     const block_step = try tracer.execute_single_block(&evm, &frame);
//!     if (block_step == null) break; // Execution completed
//!     
//!     // Check if we're at a block boundary
//!     if (MemoryTracer.is_block_boundary(frame.pc, frame.contract.analysis)) {
//!         const block_info = MemoryTracer.get_block_info(frame.pc, frame.contract.analysis);
//!         if (block_info) |info| {
//!             std.log.info("Block: PC {} to {}, {} instructions, {} gas", .{
//!                 info.start_pc, info.end_pc, info.instruction_count, info.total_gas_cost
//!             });
//!         }
//!     }
//! }
//! ```
//!
//! ### Advanced State Inspection and Control
//! ```zig
//! var tracer = try MemoryTracer.init(allocator, config);
//! defer tracer.deinit();
//!
//! // Set up custom step hooks for detailed monitoring
//! tracer.on_step_transition = custom_step_hook;
//! 
//! // Conditional breakpoints
//! tracer.on_step_transition = struct {
//!     fn hook(self: *MemoryTracer, transition: StepTransition) !tracer.StepControl {
//!         // Pause when stack depth exceeds threshold
//!         if (transition.stack_size_after > 10) {
//!             std.log.warn("Stack overflow risk at PC {}", .{transition.pc});
//!             return .pause;
//!         }
//!         return .cont;
//!     }
//! }.hook;
//!
//! // Dynamic mode switching
//! tracer.set_step_mode(.single_step);
//! _ = try tracer.execute_single_step(&evm, &frame);
//! 
//! // Switch to breakpoint mode after first instruction
//! tracer.set_step_mode(.breakpoint);
//! try tracer.add_breakpoint(frame.pc + 10);
//! _ = try tracer.execute_until_breakpoint(&evm, &frame);
//! ```

const std = @import("std");
const builtin = @import("builtin");
const tracer = @import("trace_types.zig");
const step_types = @import("step_types.zig");
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
        block_step, // Pause after each analysis block
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
        
        // Clear transitions
        for (self.transitions.items) |*trans| {
            if (trans.stack_snapshot) |stack| {
                self.allocator.free(stack);
            }
            if (trans.memory_snapshot) |memory| {
                self.allocator.free(memory);
            }
            // Note: storage_changes and logs_emitted point to static slices, don't free
        }
        self.transitions.clearAndFree();
        self.message_transitions.clearAndFree();

        // Reset state
        self.gas_used = 0;
        self.failed = false;
        self.current_step_info = null;
        self.last_transition = null;
        self.last_journal_size = 0;
        self.last_log_count = 0;
        self.pending_control = tracer.StepControl.cont;
        // Note: Don't reset step_mode or breakpoints - user may want to preserve them
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
            .block_step => blk: {
                // For block stepping, we need analysis context to determine boundaries
                // Since we can't access analysis here, we pause on every step and let 
                // the higher-level stepping context handle block boundary detection
                break :blk tracer.StepControl.pause;
            },
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
        // Make a lightweight copy without expensive snapshots to avoid memory leaks
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
            // The full data is available in the complete StructLog if needed
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

    /// Set execution mode with validation
    pub fn set_step_mode(self: *MemoryTracer, mode: @TypeOf(self.step_mode)) void {
        const old_mode = self.step_mode;
        self.step_mode = mode;
        
        // Log mode changes in debug builds for debugging
        if (comptime builtin.mode == .Debug) {
            if (old_mode != mode) {
                std.log.debug("MemoryTracer step mode changed: {} -> {}", .{old_mode, mode});
            }
        }
    }

    /// Add a breakpoint at PC with validation
    pub fn add_breakpoint(self: *MemoryTracer, pc: usize) !void {
        try self.breakpoints.put(pc, {});
    }
    
    /// Check if PC has a breakpoint
    pub fn has_breakpoint(self: *MemoryTracer, pc: usize) bool {
        return self.breakpoints.contains(pc);
    }

    /// Remove a breakpoint, returns true if it existed
    pub fn remove_breakpoint(self: *MemoryTracer, pc: usize) bool {
        return self.breakpoints.remove(pc);
    }

    /// Clear all breakpoints
    pub fn clear_breakpoints(self: *MemoryTracer) void {
        self.breakpoints.clearAndFree();
    }
    
    /// Get all active breakpoints as a slice (for inspection)
    pub fn get_breakpoints(self: *MemoryTracer, allocator: std.mem.Allocator) ![]usize {
        var breakpoint_list = try std.ArrayList(usize).initCapacity(allocator, self.breakpoints.count());
        var iterator = self.breakpoints.iterator();
        while (iterator.next()) |entry| {
            breakpoint_list.appendAssumeCapacity(entry.key_ptr.*);
        }
        return breakpoint_list.toOwnedSlice();
    }

    /// Execute one instruction step with proper type safety
    /// Returns the step transition if execution paused, null if completed
    pub fn execute_single_step(self: *MemoryTracer, evm: *@import("../evm.zig"), frame: *@import("../frame.zig").Frame) !?step_types.StepTransition {
        // Set single-step mode
        const previous_mode = self.step_mode;
        self.set_step_mode(.single_step);
        errdefer self.set_step_mode(previous_mode);
        
        // Execute until pause
        evm.interpret(frame) catch |err| switch (err) {
            @import("../execution/execution_error.zig").Error.DebugPaused => return self.convert_last_transition(),
            @import("../execution/execution_error.zig").Error.STOP => return null, // Execution completed
            else => return err,
        };
        
        // If we reach here, execution completed without error
        return null;
    }

    /// Execute until the next analysis block boundary with proper error handling
    /// Returns the step transition if execution paused, null if completed
    pub fn execute_single_block(self: *MemoryTracer, evm: *@import("../evm.zig"), frame: *@import("../frame.zig").Frame) !?step_types.StepTransition {
        const previous_mode = self.step_mode;
        self.set_step_mode(.block_step);
        errdefer self.set_step_mode(previous_mode);
        
        evm.interpret(frame) catch |err| switch (err) {
            @import("../execution/execution_error.zig").Error.DebugPaused => return self.convert_last_transition(),
            @import("../execution/execution_error.zig").Error.STOP => return null, // Execution completed
            else => return err,
        };
        
        // If we reach here, execution completed without error
        return null;
    }

    /// Continue execution until breakpoint or completion with proper error handling
    /// Returns the step transition if hit breakpoint, null if completed
    pub fn execute_until_breakpoint(self: *MemoryTracer, evm: *@import("../evm.zig"), frame: *@import("../frame.zig").Frame) !?step_types.StepTransition {
        const previous_mode = self.step_mode;
        self.set_step_mode(.breakpoint);
        errdefer self.set_step_mode(previous_mode);
        
        evm.interpret(frame) catch |err| switch (err) {
            @import("../execution/execution_error.zig").Error.DebugPaused => return self.convert_last_transition(),
            @import("../execution/execution_error.zig").Error.STOP => return null, // Execution completed
            else => return err,
        };
        
        // If we reach here, execution completed without error
        return null;
    }

    /// Convert internal tracer transition to public API type with validation
    pub fn convert_last_transition(self: *MemoryTracer) ?step_types.StepTransition {
        const trans = self.last_transition orelse {
            std.log.warn("convert_last_transition called but no transition available", .{});
            return null;
        };
        
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

    /// Check if the given PC is at a block boundary using analysis data
    /// This is the authoritative way to detect block boundaries - no heuristics needed
    pub fn is_block_boundary(
        pc: usize, 
        analysis: *const @import("../code_analysis.zig").CodeAnalysis
    ) bool {
        // Bounds check
        if (pc >= analysis.pc_to_block_start.len) return false;
        
        const block_start_index = analysis.pc_to_block_start[pc];
        if (block_start_index == std.math.maxInt(u16)) return false;
        
        // Verify the instruction exists and is a block boundary
        if (block_start_index >= analysis.instructions.len) return false;
        
        const instruction = &analysis.instructions[block_start_index];
        return instruction.tag == .block_info;
    }

    /// Get information about the analysis block containing the given PC
    /// Uses analysis data directly - no complex logic needed
    pub fn get_block_info(
        pc: usize, 
        analysis: *const @import("../code_analysis.zig").CodeAnalysis
    ) ?step_types.BlockInfo {
        // Bounds check
        if (pc >= analysis.pc_to_block_start.len) return null;
        
        const block_start_index = analysis.pc_to_block_start[pc];
        if (block_start_index == std.math.maxInt(u16)) return null;
        if (block_start_index >= analysis.instructions.len) return null;
        
        const instruction = &analysis.instructions[block_start_index];
        if (instruction.tag != .block_info) return null;
        
        // Get block parameters directly from analysis - this is the source of truth
        const params = analysis.getInstructionParams(.block_info, instruction.id);
        
        // The analysis already computed the block boundaries - use them directly
        const start_pc = if (block_start_index < analysis.inst_to_pc.len) 
            analysis.inst_to_pc[block_start_index] 
        else 
            pc; // Fallback to input PC
            
        // Find next block boundary for end_pc
        var end_pc = analysis.code_len; // Default to end of code
        var instruction_count: usize = 0;
        
        // Count instructions until next block_info
        var current_index = block_start_index + 1;
        while (current_index < analysis.instructions.len) {
            const current_inst = &analysis.instructions[current_index];
            if (current_inst.tag == .block_info) {
                // Found next block
                if (current_index < analysis.inst_to_pc.len) {
                    end_pc = analysis.inst_to_pc[current_index];
                }
                break;
            }
            instruction_count += 1;
            current_index += 1;
        }
        
        return step_types.BlockInfo{
            .start_pc = start_pc,
            .end_pc = end_pc,
            .instruction_count = instruction_count,
            .total_gas_cost = params.gas_cost,
            .stack_requirements = params.stack_req,
            .stack_max_growth = params.stack_max_growth,
        };
    }

    /// Continue execution until breakpoint (convenience method)
    pub fn continue_execution(self: *MemoryTracer) void {
        self.set_step_mode(.breakpoint);
    }
    
    /// Get current step mode
    pub fn get_step_mode(self: *MemoryTracer) @TypeOf(self.step_mode) {
        return self.step_mode;
    }
    
    /// Reset to passive tracing mode
    pub fn reset_step_mode(self: *MemoryTracer) void {
        self.set_step_mode(.passive);
    }
};
