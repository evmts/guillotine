const std = @import("std");
const tracer = @import("trace_types.zig");
const MemoryTracer = @import("memory_tracer.zig").MemoryTracer;
const DebugShadow = @import("../shadow/shadow.zig");
const Evm = @import("../evm.zig");
const Frame = @import("../frame.zig").Frame;
const execute_mini_block = @import("../evm/execute_mini_block.zig");
const shadow_compare_block = @import("../shadow/shadow_compare_block.zig");
const Log = @import("../log.zig");

/// Shadow tracer that compares Main EVM with Mini EVM execution
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
                try writer.print("     Main: {s}\n", .{mismatch.lhs_summary});
                try writer.print("     Mini: {s}\n", .{mismatch.rhs_summary});
            }
        } else {
            try writer.print("✓ All comparisons passed\n", .{});
        }
        
        return buffer.toOwnedSlice();
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
        
        // For per-block mode, trigger comparison after block execution
        // This would be called from the main interpreter when a block completes
        if (self.mode == .per_block) {
            // The actual comparison is triggered by the interpreter
            // calling shadow_compare_block directly
            self.blocks_compared += 1;
        }
    }
    
    fn on_step_transition_impl(ptr: *anyopaque, step_info: tracer.StepInfo, 
                               step_result: tracer.StepResult) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        // Let base tracer handle transition
        if (self.base.handle().vtable.on_step_transition) |func| {
            func(@ptrCast(&self.base), step_info, step_result);
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
                Log.err("  PC {}: {} - main: {s}, mini: {s}", .{
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