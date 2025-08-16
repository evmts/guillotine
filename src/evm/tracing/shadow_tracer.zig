const std = @import("std");
const tracer = @import("trace_types.zig");
const MemoryTracer = @import("memory_tracer.zig").MemoryTracer;
const DebugShadow = @import("../shadow/shadow.zig");
const Evm = @import("../evm.zig");
const Frame = @import("../frame.zig").Frame;
const execute_mini_block = @import("../evm/execute_mini_block.zig");
const shadow_compare_block = @import("../shadow/shadow_compare_block.zig");
const step_types = @import("step_types.zig");
const ExecutionError = @import("../execution/execution_error.zig");
const Log = @import("../log.zig");

/// Shadow tracer that compares Primary EVM with Shadow EVM execution
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
    
    /// Current execution tracking for primary EVM
    current_primary_step: usize = 0,
    current_primary_block: usize = 0,
    
    /// Current execution tracking for shadow EVM
    current_shadow_step: usize = 0,
    current_shadow_block: usize = 0,
    
    /// Last transition captured for stepping
    last_transition: ?step_types.StepTransition = null,
    
    /// Current analysis for block boundary detection in callbacks
    current_analysis: ?*const @import("../analysis.zig").CodeAnalysis = null,
    
    const Self = @This();
    
    /// VTable for tracer interface
    const VTABLE = tracer.TracerVTable{
        .on_step_before = on_step_before_impl,
        .on_step_after = on_step_after_impl,
        .on_step_transition = on_step_transition_impl,
        .on_message_before = on_message_before_impl,
        .on_message_after = on_message_after_impl,
        .on_message_transition = on_message_transition_impl,
        .get_step_control = get_step_control_impl,
        .finalize = finalize_impl,
        .get_trace = get_trace_impl,
        .deinit = deinit_impl,
    };
    
    /// Initialize a new shadow tracer
    pub fn init(
        allocator: std.mem.Allocator,
        evm_ptr: *Evm,
        mode: DebugShadow.ShadowMode,
        config: DebugShadow.ShadowConfig,
    ) !Self {
        return Self{
            .base = try MemoryTracer.init(allocator, .{}),
            .evm = evm_ptr,
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
    
    /// Get current step position for primary EVM
    pub fn get_primary_step(self: *const Self) usize {
        return self.current_primary_step;
    }
    
    /// Get current block position for primary EVM
    pub fn get_primary_block(self: *const Self) usize {
        return self.current_primary_block;
    }
    
    /// Get current step position for shadow EVM
    pub fn get_shadow_step(self: *const Self) usize {
        return self.current_shadow_step;
    }
    
    /// Get current block position for shadow EVM
    pub fn get_shadow_block(self: *const Self) usize {
        return self.current_shadow_block;
    }
    
    /// Reset execution tracking
    pub fn reset_execution_tracking(self: *Self) void {
        self.current_primary_step = 0;
        self.current_primary_block = 0;
        self.current_shadow_step = 0;
        self.current_shadow_block = 0;
        self.last_transition = null;
        self.current_analysis = null;
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
                try writer.print("     Primary: {s}\n", .{mismatch.lhs_summary});
                try writer.print("     Shadow: {s}\n", .{mismatch.rhs_summary});
            }
        } else {
            try writer.print("✓ All comparisons passed\n", .{});
        }
        
        return buffer.toOwnedSlice();
    }
    
    /// Execute single step with shadow comparison
    /// In step-based mode, shadow EVM catches up every time we finish a block
    pub fn execute_single_step(self: *Self, evm: *Evm, frame: *Frame) !?step_types.StepTransition {
        // Store analysis for use in callbacks that don't have frame access
        self.current_analysis = frame.analysis;
        
        // Set step mode on base tracer
        self.base.set_step_mode(.single_step);
        
        // Track primary EVM step
        const previous_primary_step = self.current_primary_step;
        self.current_primary_step += 1;
        
        // Execute step on primary EVM
        const result = evm.interpret(frame);
        
        // Handle the execution result
        switch (result) {
            ExecutionError.Error.DebugPaused => {
                // Get transition from base tracer using its method
                self.last_transition = self.base.convert_last_transition();
                
                if (self.last_transition) |trans| {
                    // Check if we completed a block and need shadow EVM catch-up
                    // Use MemoryTracer's authoritative block boundary detection from analysis
                    if (MemoryTracer.is_block_boundary(trans.pc, frame.analysis)) {
                        self.current_primary_block += 1;
                        try self.catch_up_shadow_evm_to_block(evm, frame);
                    }
                }
                
                return self.last_transition;
            },
            ExecutionError.Error.STOP => {
                // Execution completed
                self.current_primary_block += 1;
                try self.catch_up_shadow_evm_to_block(evm, frame);
                return self.last_transition;
            },
            else => |err| {
                // Execution failed, rollback step count
                self.current_primary_step = previous_primary_step;
                return err;
            },
        }
    }
    
    /// Execute single block with shadow comparison
    /// In block-based mode, shadow EVM catches up after every block
    pub fn execute_single_block(self: *Self, evm: *Evm, frame: *Frame) !?step_types.StepTransition {
        // Store analysis for use in callbacks that don't have frame access
        self.current_analysis = frame.analysis;
        
        // Set block step mode on base tracer
        self.base.set_step_mode(.block_step);
        
        // Track primary EVM block
        const previous_primary_block = self.current_primary_block;
        self.current_primary_block += 1;
        
        // Execute block on primary EVM
        const result = evm.interpret(frame);
        
        // Handle the execution result
        switch (result) {
            ExecutionError.Error.DebugPaused => {
                // Get transition from base tracer using its method
                self.last_transition = self.base.convert_last_transition();
                
                // Block completed, catch up shadow EVM
                try self.catch_up_shadow_evm_to_block(evm, frame);
                
                return self.last_transition;
            },
            ExecutionError.Error.STOP => {
                // Execution completed
                try self.catch_up_shadow_evm_to_block(evm, frame);
                return self.last_transition;
            },
            else => |err| {
                // Execution failed, rollback block count
                self.current_primary_block = previous_primary_block;
                return err;
            },
        }
    }
    
    /// Execute until breakpoint with shadow comparison
    pub fn execute_until_breakpoint(self: *Self, evm: *Evm, frame: *Frame) !?step_types.StepTransition {
        // Store analysis for use in callbacks that don't have frame access
        self.current_analysis = frame.analysis;
        
        // Set breakpoint mode on base tracer
        self.base.set_step_mode(.breakpoint);
        
        const result = evm.interpret(frame);
        
        switch (result) {
            ExecutionError.Error.DebugPaused => {
                // Get transition from base tracer using its method
                self.last_transition = self.base.convert_last_transition();
                
                // Catch up shadow EVM
                try self.catch_up_shadow_evm_to_current(evm, frame);
                
                return self.last_transition;
            },
            ExecutionError.Error.STOP => {
                try self.catch_up_shadow_evm_to_current(evm, frame);
                return self.last_transition;
            },
            else => |err| return err,
        }
    }
    
    /// Add breakpoint at specific PC
    pub fn add_breakpoint(self: *Self, pc: usize) !void {
        try self.base.add_breakpoint(pc);
    }
    
    /// Remove breakpoint at specific PC
    pub fn remove_breakpoint(self: *Self, pc: usize) bool {
        return self.base.remove_breakpoint(pc);
    }
    
    /// Clear all breakpoints
    pub fn clear_breakpoints(self: *Self) void {
        self.base.clear_breakpoints();
    }
    
    /// Get current step mode
    pub fn get_step_mode(self: *Self) @TypeOf(self.base.step_mode) {
        return self.base.get_step_mode();
    }
    
    /// Set step mode
    pub fn set_step_mode(self: *Self, mode: @TypeOf(self.base.step_mode)) void {
        self.base.set_step_mode(mode);
    }
    
    /// Reset step mode to passive
    pub fn reset_step_mode(self: *Self) void {
        self.base.reset_step_mode();
    }
    
    // === Private Implementation ===
    
    /// Catch up shadow EVM to the current block position
    fn catch_up_shadow_evm_to_block(self: *Self, evm: *Evm, frame: *Frame) !void {
        _ = frame; // Unused for now, but may be needed for future frame-specific comparison
        
        // In both step-based and block-based stepping, shadow EVM catches up
        // when we finish a block and compares state
        if (self.mode == .per_block) {
            // Trigger block-level comparison
            if (evm.take_last_shadow_mismatch()) |mismatch| {
                self.mismatches.append(mismatch) catch {
                    Log.err("Failed to store shadow mismatch due to memory allocation failure", .{});
                    var mutable = mismatch;
                    mutable.deinit(self.base.allocator);
                    return;
                };
                self.mismatches_found += 1;
            }
            
            self.blocks_compared += 1;
            self.current_shadow_block = self.current_primary_block;
        }
    }
    
    /// Catch up shadow EVM to current execution position
    fn catch_up_shadow_evm_to_current(self: *Self, evm: *Evm, frame: *Frame) !void {
        _ = frame;
        // For step-based mode, we may need to catch up shadow EVM step by step
        if (self.mode == .per_call) {
            if (evm.take_last_shadow_mismatch()) |mismatch| {
                self.mismatches.append(mismatch) catch {
                    Log.err("Failed to store shadow mismatch due to memory allocation failure", .{});
                    var mutable = mismatch;
                    mutable.deinit(self.base.allocator);
                    return;
                };
                self.mismatches_found += 1;
            }
            
            self.current_shadow_step = self.current_primary_step;
        }
    }
    
    fn on_step_before_impl(ptr: *anyopaque, step_info: tracer.StepInfo) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        
        // Let base tracer capture state by calling its vtable function
        if (self.base.handle().vtable.on_step_before) |func| {
            func(@ptrCast(&self.base), step_info);
        }
        
        // We don't need to do anything here for shadow comparison
        // The comparison happens after the step completes
    }
    
    fn on_step_after_impl(ptr: *anyopaque, step_result: tracer.StepResult) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        
        // Let base tracer capture state by calling its vtable function
        if (self.base.handle().vtable.on_step_after) |func| {
            func(@ptrCast(&self.base), step_result);
        }
        
        // Track step completion
        self.current_primary_step += 1;
        
        // Block boundary detection happens in on_step_transition where we have the PC
        // or in the stepping methods where we have frame access
    }
    
    fn on_step_transition_impl(ptr: *anyopaque, step_info: tracer.StepInfo, 
                               step_result: tracer.StepResult) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        // Let base tracer handle transition
        if (self.base.handle().vtable.on_step_transition) |func| {
            func(@ptrCast(&self.base), step_info, step_result);
        }
        
        // For per-block mode, check if we're at a block boundary
        // We need the analysis to check, which we should have stored
        if (self.mode == .per_block) {
            if (self.current_analysis) |analysis| {
                // Check if this PC is a block boundary using the authoritative analysis
                if (MemoryTracer.is_block_boundary(step_info.pc, analysis)) {
                    self.current_primary_block += 1;
                    self.blocks_compared += 1;
                    // Note: Shadow EVM catch-up happens in the stepping methods
                    // which have access to the full EVM and frame context
                }
            }
        }
    }
    
    fn on_message_before_impl(ptr: *anyopaque, event: tracer.MessageEvent) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        // Let base tracer handle message before
        if (self.base.handle().vtable.on_message_before) |func| {
            func(@ptrCast(&self.base), event);
        }
        
        // For per-call mode, we'll compare at message end
        if (self.mode == .per_call) {
            // Enable shadow mode in EVM
            self.evm.set_shadow_mode(.per_call);
        }
    }
    
    fn on_message_after_impl(ptr: *anyopaque, event: tracer.MessageEvent) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        // Let base tracer handle message after
        if (self.base.handle().vtable.on_message_after) |func| {
            func(@ptrCast(&self.base), event);
        }
        
        // For per-call mode, check for mismatches
        if (self.mode == .per_call) {
            if (self.evm.take_last_shadow_mismatch()) |mismatch| {
                self.mismatches.append(mismatch) catch {
                    // If we can't store the mismatch due to memory issues,
                    // at least clean it up and log the error
                    Log.err("Failed to store shadow mismatch due to memory allocation failure", .{});
                    var mutable = mismatch;
                    mutable.deinit(self.base.allocator);
                    return; // Exit early to avoid incrementing counter
                };
                self.mismatches_found += 1;
            }
        }
    }
    
    fn on_message_transition_impl(ptr: *anyopaque, before_event: tracer.MessageEvent,
                                after_event: tracer.MessageEvent) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        // Let base tracer handle message transition
        if (self.base.handle().vtable.on_message_transition) |func| {
            func(@ptrCast(&self.base), before_event, after_event);
        }
    }
    
    fn get_step_control_impl(ptr: *anyopaque) tracer.StepControl {
        const self: *Self = @ptrCast(@alignCast(ptr));
        // Let base tracer handle step control, default to continue
        if (self.base.handle().vtable.get_step_control) |func| {
            return func(@ptrCast(&self.base));
        }
        return .cont;
    }
    
    fn finalize_impl(ptr: *anyopaque, final_result: tracer.FinalResult) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        // Let base tracer handle finalization
        self.base.handle().vtable.finalize(@ptrCast(&self.base), final_result);
        
        // Report any mismatches
        if (self.mismatches.items.len > 0) {
            Log.err("Shadow execution found {} mismatches", .{self.mismatches.items.len});
            for (self.mismatches.items) |mismatch| {
                Log.err("  PC {}: {} - primary: {s}, shadow: {s}", .{
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
    
    fn get_trace_impl(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!tracer.ExecutionTrace {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return try self.base.handle().vtable.get_trace(@ptrCast(&self.base), allocator);
    }
    
    fn deinit_impl(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        _ = allocator;
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.deinit();
    }
};