/// Configurable execution tracing system for EVM debugging and analysis
///
/// Provides multiple tracer implementations with compile-time selection:
/// - `NoOpTracer`: Zero runtime overhead (default for production)
/// - `DebuggingTracer`: Step-by-step debugging with breakpoints
/// - `LoggingTracer`: Structured logging to stdout
/// - `FileTracer`: High-performance file output
/// - Custom tracers can be implemented by following the interface
///
/// Tracers are selected at compile time for zero-cost abstractions.
/// Enable tracing by configuring the Frame with a specific TracerType.
const std = @import("std");
const frame_mod = @import("stack_frame.zig");
const primitives = @import("primitives");
const Address = primitives.Address.Address;
const ZERO_ADDRESS = primitives.ZERO_ADDRESS;
const Host = @import("host.zig").Host;
const block_info_mod = @import("block_info.zig");
const call_params_mod = @import("call_params.zig");
const call_result_mod = @import("call_result.zig");
const hardfork_mod = @import("hardfork.zig");
const PrestateTracer = @import("prestate_tracer.zig").PrestateTracer;

// ============================================================================
// NO-OP TRACER
// ============================================================================

// No-op tracer that does nothing - zero runtime cost
pub const NoOpTracer = struct {
    pub fn init() NoOpTracer {
        return .{};
    }

    pub fn beforeOp(self: *NoOpTracer, pc: u32, opcode: u8, comptime FrameType: type, frame: *const FrameType) void {
        _ = self;
        _ = pc;
        _ = opcode;
        _ = frame;
        // FrameType is used in the function signature, no need to discard
    }

    pub fn afterOp(self: *NoOpTracer, pc: u32, opcode: u8, comptime FrameType: type, frame: *const FrameType) void {
        _ = self;
        _ = pc;
        _ = opcode;
        _ = frame;
        // FrameType is used in the function signature, no need to discard
    }

    pub fn onError(self: *NoOpTracer, pc: u32, err: anyerror, comptime FrameType: type, frame: *const FrameType) void {
        _ = self;
        _ = pc;
        _ = frame;
        std.debug.assert(err != error.OutOfMemory); // Suppress error set discard warning
        // FrameType is comptime, no need to discard
    }

    // Prestate-style hooks for compatibility (no-ops)
    pub fn onTransactionStart(self: *NoOpTracer) void {
        _ = self;
    }
    pub fn onTransactionEnd(self: *NoOpTracer) void {
        _ = self;
    }
    pub fn onStorageRead(self: *NoOpTracer, address: Address, slot: u256, value: u256, is_warm: bool) void {
        _ = self;
        _ = address;
        _ = slot;
        _ = value;
        _ = is_warm;
    }
    pub fn onStorageWrite(self: *NoOpTracer, address: Address, slot: u256, old_value: u256, new_value: u256, is_warm: bool) void {
        _ = self;
        _ = address;
        _ = slot;
        _ = old_value;
        _ = new_value;
        _ = is_warm;
    }
    pub fn onBalanceRead(self: *NoOpTracer, address: Address, balance: u256) void {
        _ = self;
        _ = address;
        _ = balance;
    }
    pub fn onBalanceChange(self: *NoOpTracer, address: Address, old_balance: u256, new_balance: u256) void {
        _ = self;
        _ = address;
        _ = old_balance;
        _ = new_balance;
    }
    pub fn onNonceRead(self: *NoOpTracer, address: Address, nonce: u64) void {
        _ = self;
        _ = address;
        _ = nonce;
    }
    pub fn onNonceChange(self: *NoOpTracer, address: Address, old_nonce: u64, new_nonce: u64) void {
        _ = self;
        _ = address;
        _ = old_nonce;
        _ = new_nonce;
    }
    pub fn onCodeRead(self: *NoOpTracer, address: Address, code: []const u8) void {
        _ = self;
        _ = address;
        _ = code;
    }
    pub fn onCodeChange(self: *NoOpTracer, address: Address, old_code: []const u8, new_code: []const u8) void {
        _ = self;
        _ = address;
        _ = old_code;
        _ = new_code;
    }
    pub fn onAccountCreated(self: *NoOpTracer, address: Address, initial_balance: u256, initial_nonce: u64, code: []const u8) void {
        _ = self;
        _ = address;
        _ = initial_balance;
        _ = initial_nonce;
        _ = code;
    }
    pub fn onAccountDestroyed(self: *NoOpTracer, address: Address, beneficiary: Address, balance_transferred: u256, had_code: bool, storage_cleared: bool) void {
        _ = self;
        _ = address;
        _ = beneficiary;
        _ = balance_transferred;
        _ = had_code;
        _ = storage_cleared;
    }
};

// ============================================================================
// DEBUGGING TRACER
// ============================================================================

/// DebuggingTracer provides comprehensive debugging capabilities for the Go CLI debugger
/// Features:
/// - Step-by-step execution control
/// - Breakpoint support
/// - State capture at each instruction
/// - Memory/stack/gas tracking
/// - Error reporting
pub const DebuggingTracer = struct {
    const Self = @This();

    allocator: std.mem.Allocator,

    // Control state
    step_mode: bool = false, // true = step through each instruction
    throw_on_error: bool = true,
    paused: bool = false, // true = execution is paused
    breakpoints: std.AutoHashMap(u32, void), // Set of PC values to break on
    resume_dispatch: ?*const anyopaque = null, // Opaque dispatch pointer for resume

    // Execution history
    steps: std.ArrayList(ExecutionStep),
    max_history: usize = 10000, // Limit history to prevent memory issues

    // State snapshots for debugging
    state_snapshots: std.ArrayList(StateSnapshot),

    // Statistics
    total_instructions: u64 = 0,
    total_gas_used: u64 = 0,
    step_count: u64 = 0,

    // Last error tracking
    last_error: ?StepError = null,
    
    // Optional composed prestate tracer
    prestate_tracer: ?*PrestateTracer = null,
    prestate_enabled: bool = false,

    pub const ExecutionResult = enum { Completed, Paused };
    
    pub const Config = struct {
        throw_on_error: bool = true,
        step_mode: bool = false,
        max_history: usize = 10000,
        // Prestate tracer composition
        enable_prestate: bool = false,
        prestate_diff_mode: bool = false,
        prestate_disable_storage: bool = false,
        prestate_disable_code: bool = false,
        prestate_include_empty: bool = false,
    };

    pub const ExecutionStep = struct {
        step_number: u64,
        pc: u32,
        opcode: u8,
        opcode_name: []const u8,
        gas_before: i32,
        gas_after: i32,
        gas_cost: u32,
        stack_before: []u256, // Owned slice
        stack_after: []u256, // Owned slice
        memory_size_before: usize,
        memory_size_after: usize,
        depth: u32,
        error_occurred: bool,
        error_msg: ?[]const u8,
    };

    pub const StateSnapshot = struct {
        pc: u32,
        gas_remaining: u64,
        stack: []u256, // Owned slice
        memory_size: usize,
        depth: u32,
        timestamp: i64,
    };

    pub fn init() Self {
        // Use a global allocator for debugging tracer
        // This is acceptable for debugging scenarios
        const allocator = std.heap.c_allocator;
        return .{
            .allocator = allocator,
            .breakpoints = std.AutoHashMap(u32, void).init(allocator),
            .steps = std.ArrayList(ExecutionStep){},
            .state_snapshots = std.ArrayList(StateSnapshot){},
        };
    }

    /// Configure tracer behavior. Safe to call at any time.
    pub fn configure(self: *Self, cfg: Config) void {
        self.throw_on_error = cfg.throw_on_error;
        self.step_mode = cfg.step_mode;
        if (cfg.max_history != self.max_history) {
            self.max_history = cfg.max_history;
            self.prune_to_max_history();
        }

        // Manage prestate tracer composition dynamically
        if (cfg.enable_prestate) {
            if (self.prestate_tracer == null) {
                const pt = self.allocator.create(PrestateTracer) catch return;
                pt.* = PrestateTracer.init(self.allocator);
                self.prestate_tracer = pt;
                self.prestate_enabled = true;
            }
            if (self.prestate_tracer) |ptc| {
                ptc.configure(.{
                    .diff_mode = cfg.prestate_diff_mode,
                    .disable_storage = cfg.prestate_disable_storage,
                    .disable_code = cfg.prestate_disable_code,
                    .include_empty = cfg.prestate_include_empty,
                });
            }
        } else if (self.prestate_tracer) |pt| {
            pt.deinit();
            self.allocator.destroy(pt);
            self.prestate_tracer = null;
            self.prestate_enabled = false;
        }
    }

    pub fn deinit(self: *Self) void {
        // Free execution step memory
        for (self.steps.items) |*step| {
            self.allocator.free(step.stack_before);
            self.allocator.free(step.stack_after);
            if (step.error_msg) |msg| {
                self.allocator.free(msg);
            }
        }
        self.steps.deinit(self.allocator);

        // Free state snapshots
        for (self.state_snapshots.items) |*snapshot| {
            self.allocator.free(snapshot.stack);
        }
        self.state_snapshots.deinit(self.allocator);

        self.breakpoints.deinit();

        if (self.prestate_tracer) |pt| {
            pt.deinit();
            self.allocator.destroy(pt);
            self.prestate_tracer = null;
            self.prestate_enabled = false;
        }
    }

    /// Enable or disable step-by-step execution mode
    pub fn setStepMode(self: *Self, enabled: bool) void {
        self.step_mode = enabled;
    }

    /// Check if execution should pause (breakpoint or step mode)
    pub fn shouldPause(self: *Self, pc: u32) bool {
        return self.step_mode or self.hasBreakpoint(pc);
    }

    /// Pause execution
    pub fn pause(self: *Self) void {
        self.paused = true;
    }

    /// Resume execution
    pub fn resumeExecution(self: *Self) void {
        self.paused = false;
    }

    /// Add a breakpoint at the given PC
    pub fn addBreakpoint(self: *Self, pc: u32) !void {
        try self.breakpoints.put(pc, {});
    }

    /// Remove a breakpoint at the given PC
    pub fn removeBreakpoint(self: *Self, pc: u32) bool {
        return self.breakpoints.remove(pc);
    }

    /// Check if there's a breakpoint at the given PC
    pub fn hasBreakpoint(self: *Self, pc: u32) bool {
        return self.breakpoints.contains(pc);
    }

    /// Clear all breakpoints
    pub fn clearBreakpoints(self: *Self) void {
        self.breakpoints.clearRetainingCapacity();
    }

    /// Main execution control - runs interpreter until pause or completion
    pub fn runUntilPauseOrStop(self: *Self, comptime InterpreterType: type, interpreter: *InterpreterType) !ExecutionResult {
        // Clear paused state
        self.resumeExecution();

        // Execute either from saved dispatch point or from start
        const DispatchType = @TypeOf(interpreter.frame).Dispatch;
        const handler = if (self.takeResumeDispatch(DispatchType)) |dispatch|
            // Resume from saved dispatch point
            dispatch.schedule[0].opcode_handler(&interpreter.frame, dispatch)
        else
            // Normal execution
            interpreter.interpret();

        handler catch |err| switch (err) {
            error.ExecutionPaused => return .Paused,
            error.STOP => return .Completed,
            else => {
                // Call error hook
                const pc_opt = interpreter.getCurrentPc();
                const pc_u32: u32 = @intCast(pc_opt orelse 0);
                self.onError(pc_u32, err, InterpreterType.Frame, &interpreter.frame);
                if (self.throw_on_error) {
                    return err;
                } else {
                    return .Paused;
                }
            },
        };

        return .Completed;
    }
    
    /// Execute exactly one instruction (step)
    pub fn stepSingle(self: *Self, comptime InterpreterType: type, interpreter: *InterpreterType) !ExecutionResult {
        // Enable step mode and clear paused flag
        self.step_mode = true;
        defer self.step_mode = false;
        return try self.runUntilPauseOrStop(InterpreterType, interpreter);
    }
    
    /// Set resume dispatch pointer when paused
    pub fn setResumeDispatch(self: *Self, dispatch: anytype) void {
        self.resume_dispatch = @ptrCast(dispatch);
        self.pause();
    }

    /// Take and clear the resume dispatch pointer
    fn takeResumeDispatch(self: *Self, comptime DispatchType: type) ?DispatchType {
        if (self.resume_dispatch) |dispatch_ptr| {
            defer self.resume_dispatch = null;
            return @ptrCast(dispatch_ptr);
        }
        return null;
    }

    /// Get the current execution step count
    pub fn getStepCount(self: *Self) u64 {
        return self.total_instructions;
    }

    /// Get the most recent execution steps
    pub fn getRecentSteps(self: *Self, count: usize) []const ExecutionStep {
        const start = if (self.steps.items.len > count) self.steps.items.len - count else 0;
        return self.steps.items[start..];
    }

    /// Get a specific execution step by index
    pub fn getStep(self: *Self, index: usize) ?*const ExecutionStep {
        if (index >= self.steps.items.len) return null;
        return &self.steps.items[index];
    }

    /// Helper function to copy stack contents - handles both Stack struct and array types
    fn copyFrameStack(self: *Self, comptime FrameType: type, frame: *const FrameType) ![]u256 {
        // Get current stack contents - handle both Stack struct and array types
        const stack_size, const stack_slice = blk: {
            const StackType = @TypeOf(frame.stack);
            const type_info = @typeInfo(StackType);
            if (type_info == .array) {
                // Array type - find occupied elements by scanning backwards from end
                var occupied: usize = 0;
                for (0..frame.stack.len) |i| {
                    if (frame.stack[frame.stack.len - 1 - i] != 0) {
                        occupied = frame.stack.len - i;
                        break;
                    }
                }
                break :blk .{ occupied, frame.stack[0..occupied] };
            } else {
                // Stack struct with methods
                break :blk .{ frame.stack.size(), frame.stack.get_slice() };
            }
        };
        const stack_copy = try self.allocator.alloc(u256, stack_size);
        @memcpy(stack_copy, stack_slice);
        return stack_copy;
    }

    /// Create a snapshot of the current state
    pub fn captureState(self: *Self, pc: u32, comptime FrameType: type, frame: *const FrameType) !void {
        const stack_copy = try self.copyFrameStack(FrameType, frame);

        const snapshot = StateSnapshot{
            .pc = pc,
            .gas_remaining = @max(frame.gas_remaining, 0),
            .stack = stack_copy,
            .memory_size = if (@hasField(FrameType, "memory")) frame.memory.size() else 0,
            .depth = if (@hasField(FrameType, "depth")) frame.depth else 0,
            .timestamp = std.time.milliTimestamp(),
        };

        try self.state_snapshots.append(self.allocator, snapshot);

        // Limit snapshots to prevent memory growth
        if (self.state_snapshots.items.len > self.max_history) {
            const old = self.state_snapshots.orderedRemove(0);
            self.allocator.free(old.stack);
        }
    }

    /// Required tracer interface: called before each operation
    pub fn beforeOp(self: *Self, pc: u32, opcode: u8, comptime FrameType: type, frame: *const FrameType) void {
        // Check if we should pause execution
        if (self.shouldPause(pc)) {
            self.pause();
        }

        // While paused, we would need to implement a mechanism to wait
        // In the C API, this could be handled by returning a "paused" status
        // and requiring explicit resume calls

        // Capture state before operation for step recording
        self.captureStateForStep(pc, opcode, FrameType, frame, true) catch |err| {
            std.log.warn("Failed to capture before state: {}", .{err});
        };
        if (self.prestate_tracer) |pt| {
            pt.beforeOp(pc, opcode, FrameType, frame);
        }
    }

    /// Required tracer interface: called after each operation
    pub fn afterOp(self: *Self, pc: u32, opcode: u8, comptime FrameType: type, frame: *const FrameType) void {
        // Update statistics
        self.total_instructions += 1;
        self.step_count += 1;

        // Capture state after operation to complete the step record
        self.captureStateForStep(pc, opcode, FrameType, frame, false) catch |err| {
            std.log.warn("Failed to capture after state: {}", .{err});
        };

        // Create state snapshot if configured
        self.captureState(pc, FrameType, frame) catch |err| {
            std.log.warn("Failed to capture state snapshot: {}", .{err});
        };

        if (self.prestate_tracer) |pt| {
            pt.afterOp(pc, opcode, FrameType, frame);
        }
    }

    /// Required tracer interface: called when an error occurs
    pub fn onError(self: *Self, pc: u32, err: anyerror, comptime FrameType: type, frame: *const FrameType) void {
        _ = pc;
        _ = frame;
        
        // Always record the last error at tracer level
        const error_name = @errorName(err);
        const kind: ErrorType = if (err == error.REVERT) .Revert else .ExecutionError;
        
        // Free previous error if it exists
        if (self.last_error) |e| {
            self.allocator.free(e.message);
        }

        // Always pause on error for debugging
        self.paused = true;

        std.log.debug("DebuggingTracer: Error occurred in frame type {s}: {}", .{ @typeName(FrameType), err });
    }

    /// Helper function to capture state for step recording
    fn captureStateForStep(self: *Self, pc: u32, opcode: u8, comptime FrameType: type, frame: *const FrameType, is_before: bool) !void {
        const gas = @max(frame.gas_remaining, 0);
        const stack_copy = try self.copyFrameStack(FrameType, frame);

        if (is_before) {
            // Start a new execution step
            const step = ExecutionStep{
                .step_number = self.total_instructions,
                .pc = pc,
                .opcode = opcode,
                .opcode_name = getOpcodeName(opcode),
                .gas_before = @as(i32, @intCast(@min(gas, std.math.maxInt(i32)))),
                .gas_after = @as(i32, @intCast(@min(gas, std.math.maxInt(i32)))), // Will be updated in afterOp
                .gas_cost = 0, // Will be calculated in afterOp
                .stack_before = stack_copy,
                .stack_after = &[_]u256{}, // Will be updated in afterOp
                .memory_size_before = if (@hasField(FrameType, "memory")) frame.memory.size() else 0,
                .memory_size_after = 0, // Will be updated in afterOp
                .depth = if (@hasField(FrameType, "depth")) frame.depth else 0,
                .error_occurred = false,
                .error_msg = null,
            };

            try self.steps.append(self.allocator, step);

            // Limit history size
            if (self.steps.items.len > self.max_history) {
                const old = self.steps.orderedRemove(0);
                self.allocator.free(old.stack_before);
                self.allocator.free(old.stack_after);
                if (old.error_msg) |msg| {
                    self.allocator.free(msg);
                }
            }
        } else {
            // Update the current step with after state
            if (self.steps.items.len > 0) {
                const current_step = &self.steps.items[self.steps.items.len - 1];
                current_step.gas_after = @as(i32, @intCast(@min(gas, std.math.maxInt(i32))));
                current_step.gas_cost = @intCast(@max(0, current_step.gas_before - @as(i32, @intCast(@min(gas, std.math.maxInt(i32))))));
                current_step.stack_after = stack_copy;
                current_step.memory_size_after = if (@hasField(FrameType, "memory")) frame.memory.size() else 0;
            } else {
                // No current step, free the stack copy
                self.allocator.free(stack_copy);
            }
        }
    }

    /// Private helper to prune history to max size
    fn pruneToMaxHistory(self: *Self) void {
        // Steps
        while (self.steps.items.len > self.max_history) {
            const old = self.steps.orderedRemove(0);
            self.allocator.free(old.stack_before);
            self.allocator.free(old.stack_after);
            if (old.@"error") |e| self.allocator.free(e.message);
        }
        // Snapshots
        while (self.state_snapshots.items.len > self.max_history) {
            const old = self.state_snapshots.orderedRemove(0);
            self.allocator.free(old.stack);
        }
    }

    /// Reset all debugging state
    pub fn reset(self: *Self) void {
        // Clear execution history
        for (self.steps.items) |*step| {
            self.allocator.free(step.stack_before);
            self.allocator.free(step.stack_after);
            if (step.error_msg) |msg| {
                self.allocator.free(msg);
            }
        }
        self.steps.clearRetainingCapacity();

        // Clear state snapshots
        for (self.state_snapshots.items) |*snapshot| {
            self.allocator.free(snapshot.stack);
        }
        self.state_snapshots.clearRetainingCapacity();

        // Reset statistics
        self.total_instructions = 0;
        self.total_gas_used = 0;

        // Keep breakpoints but reset execution state
        self.resumeExecution();
        self.step_mode = false;
        self.resume_dispatch = null;

        // Reset composed prestate tracer if present
        if (self.prestate_tracer) |pt| {
            pt.reset();
        }
    }

    /// Get debugging statistics
    pub fn getStats(self: *Self) struct {
        total_instructions: u64,
        total_gas_used: u64,
        breakpoint_count: usize,
        history_size: usize,
        snapshot_count: usize,
    } {
        return .{
            .total_instructions = self.total_instructions,
            .total_gas_used = self.total_gas_used,
            .breakpoint_count = self.breakpoints.count(),
            .history_size = self.steps.items.len,
            .snapshot_count = self.state_snapshots.items.len,
        };
    }
    
    pub fn getPrestateTracer(self: *Self) ?*PrestateTracer {
        return self.prestate_tracer;
    }

    // Delegate prestate hooks if enabled (safe to call via @hasDecl)
    pub fn onTransactionStart(self: *Self) void {
        if (self.prestate_tracer) |pt| pt.onTransactionStart();
    }
    pub fn onTransactionEnd(self: *Self) void {
        if (self.prestate_tracer) |pt| pt.onTransactionEnd();
    }
    pub fn onStorageRead(self: *Self, address: Address, slot: u256, value: u256, is_warm: bool) void {
        if (self.prestate_tracer) |pt| pt.onStorageRead(address, slot, value, is_warm);
    }
    pub fn onStorageWrite(self: *Self, address: Address, slot: u256, old_value: u256, new_value: u256, is_warm: bool) void {
        if (self.prestate_tracer) |pt| pt.onStorageWrite(address, slot, old_value, new_value, is_warm);
    }
    pub fn onBalanceRead(self: *Self, address: Address, balance: u256) void {
        if (self.prestate_tracer) |pt| pt.onBalanceRead(address, balance);
    }
    pub fn onBalanceChange(self: *Self, address: Address, old_balance: u256, new_balance: u256) void {
        if (self.prestate_tracer) |pt| pt.onBalanceChange(address, old_balance, new_balance);
    }
    pub fn onNonceRead(self: *Self, address: Address, nonce: u64) void {
        if (self.prestate_tracer) |pt| pt.onNonceRead(address, nonce);
    }
    pub fn onNonceChange(self: *Self, address: Address, old_nonce: u64, new_nonce: u64) void {
        if (self.prestate_tracer) |pt| pt.onNonceChange(address, old_nonce, new_nonce);
    }
    pub fn onCodeRead(self: *Self, address: Address, code: []const u8) void {
        if (self.prestate_tracer) |pt| pt.onCodeRead(address, code);
    }
    pub fn onCodeChange(self: *Self, address: Address, old_code: []const u8, new_code: []const u8) void {
        if (self.prestate_tracer) |pt| pt.onCodeChange(address, old_code, new_code);
    }
    pub fn onAccountCreated(self: *Self, address: Address, initial_balance: u256, initial_nonce: u64, code: []const u8) void {
        if (self.prestate_tracer) |pt| pt.onAccountCreated(address, initial_balance, initial_nonce, code);
    }
    pub fn onAccountDestroyed(self: *Self, address: Address, beneficiary: Address, balance_transferred: u256, had_code: bool, storage_cleared: bool) void {
        if (self.prestate_tracer) |pt| pt.onAccountDestroyed(address, beneficiary, balance_transferred, had_code, storage_cleared);
    }
};

// ============================================================================
// WRITER-BASED TRACERS
// ============================================================================

// Configuration for tracing behavior
pub const MemoryCaptureMode = enum { none, prefix, full };

pub const TracerConfig = struct {
    capture_memory: MemoryCaptureMode = .none,
    memory_prefix: usize = 0, // bytes to capture when mode is .prefix
    compute_gas_cost: bool = false, // compute per-step gas deltas
    capture_each_op: bool = false, // capture snapshot after each operation
};

pub const DetailedStructLog = struct {
    pc: u64,
    op: []const u8,
    gas: u64,
    gasCost: u64,
    depth: u32,
    stack: []const u256,
    memory: ?[]const u8,
    memSize: u32,
    // storage: ?std.hash_map.HashMap(u256, u256), // Not implemented yet
    // returnData: ?[]const u8, // Not implemented yet
    refund: u64,
    @"error": ?[]const u8,
};

// Generic tracer that can work with any writer
pub fn Tracer(comptime Writer: type) type {
    return struct {
        allocator: std.mem.Allocator,
        writer: Writer,
        cfg: TracerConfig = .{},
        prev_gas: ?u64 = null,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, writer: Writer) Self {
            return .{
                .allocator = allocator,
                .writer = writer,
                .cfg = .{},
            };
        }

        pub fn initWithConfig(allocator: std.mem.Allocator, writer: Writer, cfg: TracerConfig) Self {
            return .{
                .allocator = allocator,
                .writer = writer,
                .cfg = cfg,
            };
        }

        pub fn snapshot(self: *Self, pc: u32, opcode: u8, comptime FrameType: type, frame_instance: *const FrameType) !DetailedStructLog {
            // Capture stack
            const stack_size = frame_instance.stack.size();
            const stack_copy = try self.allocator.alloc(u256, stack_size);
            const stack_slice = frame_instance.stack.get_slice();
            @memcpy(stack_copy, stack_slice);

            const op_name = getOpcodeName(opcode);

            // Gas calculation
            const gas_now: u64 = @max(frame_instance.gas_remaining, 0);
            var gas_cost: u64 = 0;
            if (self.cfg.compute_gas_cost) {
                if (self.prev_gas) |prev| {
                    gas_cost = if (prev > gas_now) (prev - gas_now) else 0;
                }
                self.prev_gas = gas_now;
            }

            // Depth (if frame provides it)
            const depth_val: u32 = blk: {
                if (comptime @hasField(FrameType, "depth")) {
                    break :blk @intCast(frame_instance.depth);
                } else if (comptime @hasField(FrameType, "call_depth")) {
                    break :blk @intCast(frame_instance.call_depth);
                }
                break :blk 1;
            };

            // Refund (if frame provides it)
            const refund_val: u64 = blk: {
                if (comptime @hasField(FrameType, "gas_refund")) {
                    break :blk @intCast(frame_instance.gas_refund);
                }
                break :blk 0;
            };

            // Memory capture
            var mem_size: u32 = 0;
            const mem_copy = try self.captureMemory(FrameType, frame_instance, &mem_size);

            // Error capture
            const err_str = getFrameError(FrameType, frame_instance);

            return DetailedStructLog{
                .pc = @as(u64, pc),
                .op = op_name,
                .gas = gas_now,
                .gasCost = gas_cost,
                .depth = depth_val,
                .stack = stack_copy,
                .memory = mem_copy,
                .memSize = mem_size,
                .refund = refund_val,
                .@"error" = err_str,
            };
        }

        pub fn writeSnapshot(self: *Self, pc: u32, opcode: u8, comptime FrameType: type, frame_instance: *const FrameType) !void {
            const log = try self.snapshot(pc, opcode, FrameType, frame_instance);
            defer self.allocator.free(log.stack);
            defer if (log.memory) |m| self.allocator.free(m);

            try self.writeJson(&log);
        }

        pub fn beforeOp(self: *Self, pc: u32, opcode: u8, comptime FrameType: type, frame: *const FrameType) void {
            _ = self;
            _ = pc;
            _ = opcode;
            _ = frame;
            // Generic tracer doesn't do anything on beforeOp by default
        }

        pub fn afterOp(self: *Self, pc: u32, opcode: u8, comptime FrameType: type, frame: *const FrameType) void {
            // Optionally capture snapshot after each operation
            if (self.cfg.capture_each_op) {
                self.writeSnapshot(pc, opcode, FrameType, frame) catch |err| {
                    std.log.warn("Failed to write snapshot: {}", .{err});
                };
            }
        }

        pub fn onError(self: *Self, pc: u32, err: anyerror, comptime FrameType: type, frame: *const FrameType) void {
            _ = self;
            _ = pc;
            _ = err;
            _ = frame;
            // Generic tracer doesn't do anything on error by default
        }

        pub fn writeJson(self: *Self, log: *const DetailedStructLog) !void {
            var buf: [1024]u8 = undefined;
            const str = try std.fmt.bufPrint(&buf, 
                "{{\"pc\":{},\"op\":\"{s}\",\"gas\":{},\"gasCost\":{},\"depth\":{},\"stack\":[",
                .{ log.pc, log.op, log.gas, log.gasCost, log.depth },
            );
            try self.writer.writeAll(str);

            // Write stack array
            for (log.stack, 0..) |val, i| {
                if (i > 0) try self.writer.writeAll(",");
                var val_buf: [100]u8 = undefined;
                const val_str = try std.fmt.bufPrint(&val_buf, "\"0x{x}\"", .{val});
                try self.writer.writeAll(val_str);
            }

            var mem_buf: [256]u8 = undefined;
            const mem_str = try std.fmt.bufPrint(&mem_buf, "],\"memSize\":{},\"refund\":{}", .{ log.memSize, log.refund });
            try self.writer.writeAll(mem_str);

            // Write memory if captured
            if (log.memory) |mem| {
                try self.writer.writeAll(",\"memory\":\"0x");
                for (mem) |byte| {
                    var byte_buf: [8]u8 = undefined;
                    const byte_str = try std.fmt.bufPrint(&byte_buf, "{x:0>2}", .{byte});
                    try self.writer.writeAll(byte_str);
                }
                try self.writer.writeByte('"');
            }

            // Write error if present
            if (log.@"error") |err| {
                var err_buf: [256]u8 = undefined;
                const err_str = try std.fmt.bufPrint(&err_buf, ",\"error\":\"{s}\"", .{err});
                try self.writer.writeAll(err_str);
            }

            try self.writer.writeAll("}}\n");
        }

        fn captureMemory(
            self: *Self,
            comptime FrameType: type,
            frame_instance: *const FrameType,
            mem_size: *u32,
        ) !?[]const u8 {
            _ = frame_instance;

            // For now, we don't have memory in the frame
            mem_size.* = 0;

            if (self.cfg.capture_memory == .none) return null;

            // When memory is added to frame, implement this:
            // if (comptime @hasField(FrameType, "memory")) {
            //     const mem_len = frame_instance.memory.len;
            //     mem_size.* = @intCast(mem_len);
            //
            //     const to_copy = switch (self.cfg.capture_memory) {
            //         .full => mem_len,
            //         .prefix => @min(mem_len, self.cfg.memory_prefix),
            //         .none => 0,
            //     };
            //
            //     if (to_copy == 0) return null;
            //     return try self.allocator.dupe(u8, frame_instance.memory[0..to_copy]);
            // }

            return null;
        }
    };
}

// Logging tracer that writes to stdout
pub const LoggingTracer = struct {
    base: Tracer(std.io.Writer),
    stdout_buffer: [4096]u8,

    pub fn init(allocator: std.mem.Allocator) LoggingTracer {
        var tracer = LoggingTracer{ 
            .base = undefined,
            .stdout_buffer = undefined,
        };
        var stdout_writer = std.fs.File.stdout().writer(&tracer.stdout_buffer);
        const stdout_interface = &stdout_writer.interface;
        tracer.base = Tracer(std.io.Writer).init(allocator, stdout_interface.*);
        return tracer;
    }

    pub fn initWithConfig(allocator: std.mem.Allocator, cfg: TracerConfig) LoggingTracer {
        var tracer = LoggingTracer{
            .base = undefined,
            .stdout_buffer = undefined,
        };
        var stdout_writer = std.fs.File.stdout().writer(&tracer.stdout_buffer);
        const stdout_interface = &stdout_writer.interface;
        tracer.base = Tracer(std.io.Writer).initWithConfig(allocator, stdout_interface.*, cfg);
        return tracer;
    }

    pub fn snapshot(self: *LoggingTracer, pc: u32, opcode: u8, comptime FrameType: type, frame_instance: *const FrameType) !DetailedStructLog {
        return self.base.snapshot(pc, opcode, FrameType, frame_instance);
    }

    pub fn writeSnapshot(self: *LoggingTracer, pc: u32, opcode: u8, comptime FrameType: type, frame_instance: *const FrameType) !void {
        return self.base.writeSnapshot(pc, opcode, FrameType, frame_instance);
    }

    pub fn beforeOp(self: *LoggingTracer, pc: u32, opcode: u8, comptime FrameType: type, frame: *const FrameType) void {
        self.base.beforeOp(pc, opcode, FrameType, frame);
    }

    pub fn afterOp(self: *LoggingTracer, pc: u32, opcode: u8, comptime FrameType: type, frame: *const FrameType) void {
        self.base.afterOp(pc, opcode, FrameType, frame);
    }

    pub fn onError(self: *LoggingTracer, pc: u32, err: anyerror, comptime FrameType: type, frame: *const FrameType) void {
        self.base.onError(pc, err, FrameType, frame);
    }
};

// File tracer that writes to a file
pub const FileTracer = struct {
    base: Tracer(std.io.Writer),
    file: std.fs.File,
    file_buffer: [4096]u8,

    pub fn init(allocator: std.mem.Allocator, path: []const u8) !FileTracer {
        const file = try std.fs.cwd().createFile(path, .{});
        var tracer = FileTracer{
            .base = undefined,
            .file = file,
            .file_buffer = undefined,
        };
        var file_writer = file.writer(&tracer.file_buffer);
        const file_interface = &file_writer.interface;
        tracer.base = Tracer(std.io.Writer).init(allocator, file_interface.*);
        return tracer;
    }

    pub fn initWithConfig(allocator: std.mem.Allocator, path: []const u8, cfg: TracerConfig) !FileTracer {
        const file = try std.fs.cwd().createFile(path, .{});
        var tracer = FileTracer{
            .base = undefined,
            .file = file,
            .file_buffer = undefined,
        };
        var file_writer = file.writer(&tracer.file_buffer);
        const file_interface = &file_writer.interface;
        tracer.base = Tracer(std.io.Writer).initWithConfig(allocator, file_interface.*, cfg);
        return tracer;
    }

    pub fn deinit(self: *FileTracer) void {
        self.file.close();
    }

    pub fn snapshot(self: *FileTracer, pc: u32, opcode: u8, comptime FrameType: type, frame_instance: *const FrameType) !DetailedStructLog {
        return self.base.snapshot(pc, opcode, FrameType, frame_instance);
    }

    pub fn writeSnapshot(self: *FileTracer, pc: u32, opcode: u8, comptime FrameType: type, frame_instance: *const FrameType) !void {
        return self.base.writeSnapshot(pc, opcode, FrameType, frame_instance);
    }

    pub fn beforeOp(self: *FileTracer, pc: u32, opcode: u8, comptime FrameType: type, frame: *const FrameType) void {
        self.base.beforeOp(pc, opcode, FrameType, frame);
    }

    pub fn afterOp(self: *FileTracer, pc: u32, opcode: u8, comptime FrameType: type, frame: *const FrameType) void {
        self.base.afterOp(pc, opcode, FrameType, frame);
    }

    pub fn onError(self: *FileTracer, pc: u32, err: anyerror, comptime FrameType: type, frame: *const FrameType) void {
        self.base.onError(pc, err, FrameType, frame);
    }
};

fn getFrameError(comptime FrameType: type, frame_instance: *const FrameType) ?[]const u8 {
    _ = frame_instance;

    // TODO: When frame has error fields, access them like:
    // if (comptime @hasField(FrameType, "last_error_str")) {
    //     return frame_instance.last_error_str;
    // }

    return null;
}

pub fn getOpcodeName(opcode: u8) []const u8 {
    return switch (opcode) {
        0x00 => "STOP",
        0x01 => "ADD",
        0x02 => "MUL",
        0x03 => "SUB",
        0x04 => "DIV",
        0x05 => "SDIV",
        0x06 => "MOD",
        0x07 => "SMOD",
        0x08 => "ADDMOD",
        0x09 => "MULMOD",
        0x0a => "EXP",
        0x0b => "SIGNEXTEND",
        0x10 => "LT",
        0x11 => "GT",
        0x12 => "SLT",
        0x13 => "SGT",
        0x14 => "EQ",
        0x15 => "ISZERO",
        0x16 => "AND",
        0x17 => "OR",
        0x18 => "XOR",
        0x19 => "NOT",
        0x1a => "BYTE",
        0x1b => "SHL",
        0x1c => "SHR",
        0x1d => "SAR",
        0x20 => "KECCAK256",
        0x50 => "POP",
        0x51 => "MLOAD",
        0x52 => "MSTORE",
        0x53 => "MSTORE8",
        0x56 => "JUMP",
        0x57 => "JUMPI",
        0x58 => "PC",
        0x59 => "MSIZE",
        0x5a => "GAS",
        0x5b => "JUMPDEST",
        0x5f => "PUSH0",
        0x60 => "PUSH1",
        0x61 => "PUSH2",
        0x62 => "PUSH3",
        0x63 => "PUSH4",
        0x64 => "PUSH5",
        0x65 => "PUSH6",
        0x66 => "PUSH7",
        0x67 => "PUSH8",
        0x68 => "PUSH9",
        0x69 => "PUSH10",
        0x6a => "PUSH11",
        0x6b => "PUSH12",
        0x6c => "PUSH13",
        0x6d => "PUSH14",
        0x6e => "PUSH15",
        0x6f => "PUSH16",
        0x70 => "PUSH17",
        0x71 => "PUSH18",
        0x72 => "PUSH19",
        0x73 => "PUSH20",
        0x74 => "PUSH21",
        0x75 => "PUSH22",
        0x76 => "PUSH23",
        0x77 => "PUSH24",
        0x78 => "PUSH25",
        0x79 => "PUSH26",
        0x7a => "PUSH27",
        0x7b => "PUSH28",
        0x7c => "PUSH29",
        0x7d => "PUSH30",
        0x7e => "PUSH31",
        0x7f => "PUSH32",
        0x80 => "DUP1",
        0x81 => "DUP2",
        0x82 => "DUP3",
        0x83 => "DUP4",
        0x84 => "DUP5",
        0x85 => "DUP6",
        0x86 => "DUP7",
        0x87 => "DUP8",
        0x88 => "DUP9",
        0x89 => "DUP10",
        0x8a => "DUP11",
        0x8b => "DUP12",
        0x8c => "DUP13",
        0x8d => "DUP14",
        0x8e => "DUP15",
        0x8f => "DUP16",
        0x90 => "SWAP1",
        0x91 => "SWAP2",
        0x92 => "SWAP3",
        0x93 => "SWAP4",
        0x94 => "SWAP5",
        0x95 => "SWAP6",
        0x96 => "SWAP7",
        0x97 => "SWAP8",
        0x98 => "SWAP9",
        0x99 => "SWAP10",
        0x9a => "SWAP11",
        0x9b => "SWAP12",
        0x9c => "SWAP13",
        0x9d => "SWAP14",
        0x9e => "SWAP15",
        0x9f => "SWAP16",
        0xfe => "INVALID",
        else => "UNKNOWN",
    };
}
