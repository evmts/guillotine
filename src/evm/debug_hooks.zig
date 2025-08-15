//! Debug hooks for EVM execution tracing and control
//!
//! This module provides callback interfaces for debugging and development tools
//! to observe and control EVM execution without modifying core execution logic.
//!
//! ## Zero-Overhead Design
//!
//! - All hooks are guarded by nullable function pointer checks
//! - No memory allocations in hot paths
//! - Hooks receive borrowed references with ephemeral lifetimes
//! - Comptime optimization eliminates hook overhead when disabled
//!
//! ## Usage
//!
//! ```zig
//! const evm_mod = @import("evm");
//! 
//! fn my_step_hook(ctx: ?*anyopaque, frame: *evm_mod.Frame, pc: usize, opcode: u8) anyerror!evm_mod.StepControl {
//!     std.log.info("Executing opcode 0x{x:0>2} at PC {}", .{ opcode, pc });
//!     return .cont;
//! }
//! 
//! fn my_message_hook(ctx: ?*anyopaque, params: *const evm_mod.CallParams, phase: evm_mod.MessagePhase) anyerror!void {
//!     switch (phase) {
//!         .before => std.log.info("Starting call...", .{}),
//!         .after => std.log.info("Call completed", .{}),
//!     }
//! }
//! 
//! var hooks = evm_mod.DebugHooks{
//!     .on_step = my_step_hook,
//!     .on_message = my_message_hook,
//! };
//! evm.set_debug_hooks(hooks);
//! ```

const std = @import("std");
const Frame = @import("frame.zig").Frame;
const CallParams = @import("host.zig").CallParams;

/// Control flow decision for step hooks
pub const StepControl = enum {
    /// Continue execution normally
    cont,
    /// Pause execution and return control to caller
    /// Execution can be resumed by calling the EVM again
    pause,
    /// Abort execution immediately with DebugAbort error
    abort,
};

/// Message call lifecycle phase
pub const MessagePhase = enum {
    /// Called before host.call() is invoked
    before,
    /// Called after host.call() returns (success or failure)
    after,
};

/// Step hook function signature
/// 
/// Called before each opcode execution with current execution context.
/// 
/// **Parameters:**
/// - `user_ctx`: Optional user-provided context pointer
/// - `frame`: Current execution frame (borrowed reference - do not store!)
/// - `pc`: Program counter (bytecode offset) 
/// - `opcode`: Raw opcode byte being executed
/// 
/// **Returns:**
/// - `StepControl` indicating whether to continue, pause, or abort
/// 
/// **Error Handling:**
/// - Any error returned will be converted to `DebugAbort`
/// 
/// **Lifetime Constraints:**
/// - Frame pointer is only valid during hook execution
/// - Do not store frame or any pointers derived from it
/// - Memory contents may change after hook returns
pub const OnStepFn = *const fn (
    user_ctx: ?*anyopaque,
    frame: *Frame,
    pc: usize,
    opcode: u8,
) anyerror!StepControl;

/// Message hook function signature
/// 
/// Called before and after CALL/CREATE family operations.
/// 
/// **Parameters:**
/// - `user_ctx`: Optional user-provided context pointer  
/// - `params`: Call parameters (borrowed reference - do not store!)
/// - `phase`: Whether this is before or after the call
/// 
/// **Error Handling:**
/// - Any error returned will be converted to `DebugAbort`
/// 
/// **Lifetime Constraints:**
/// - CallParams pointer is only valid during hook execution
/// - Input/init_code slices within params are ephemeral
/// - Do not store any pointers from params beyond hook execution
pub const OnMessageFn = *const fn (
    user_ctx: ?*anyopaque,
    params: *const CallParams,
    phase: MessagePhase,
) anyerror!void;

/// Debug hooks configuration
/// 
/// Contains optional callback functions for debugging EVM execution.
/// All fields are optional - only non-null hooks will be invoked.
/// 
/// **Zero-Overhead Guarantee:**
/// - When debug_hooks is null on Evm, no performance impact
/// - When individual hooks are null, minimal branch overhead
/// - No memory allocations in hook infrastructure
/// 
/// **Thread Safety:**
/// - Hooks are called from the same thread as EVM execution
/// - User is responsible for any thread synchronization in hook implementations
/// - Do not call EVM methods from within hooks (undefined behavior)
pub const DebugHooks = struct {
    /// Optional user context passed to all hook functions
    /// Useful for maintaining state across hook invocations
    user_ctx: ?*anyopaque = null,
    
    /// Step hook - called before each opcode execution
    /// Set to null to disable step debugging
    on_step: ?OnStepFn = null,
    
    /// Message hook - called before/after CALL/CREATE operations
    /// Set to null to disable message tracing
    on_message: ?OnMessageFn = null,
    
    /// Create DebugHooks with step debugging only
    pub fn step_only(step_fn: OnStepFn, ctx: ?*anyopaque) DebugHooks {
        return DebugHooks{
            .user_ctx = ctx,
            .on_step = step_fn,
        };
    }
    
    /// Create DebugHooks with message tracing only
    pub fn message_only(msg_fn: OnMessageFn, ctx: ?*anyopaque) DebugHooks {
        return DebugHooks{
            .user_ctx = ctx,
            .on_message = msg_fn,
        };
    }
    
    /// Create DebugHooks with both step and message hooks
    pub fn full(step_fn: OnStepFn, msg_fn: OnMessageFn, ctx: ?*anyopaque) DebugHooks {
        return DebugHooks{
            .user_ctx = ctx,
            .on_step = step_fn,
            .on_message = msg_fn,
        };
    }
};

// Compile-time validation
comptime {
    // Ensure function pointers have expected size
    std.debug.assert(@sizeOf(OnStepFn) == @sizeOf(*const fn() void));
    std.debug.assert(@sizeOf(OnMessageFn) == @sizeOf(*const fn() void));
    
    // Ensure DebugHooks has reasonable size (should fit in cache line)
    std.debug.assert(@sizeOf(DebugHooks) <= 64);
}

// Tests

const testing = std.testing;
const primitives = @import("primitives");

test "StepControl enum values" {
    try testing.expectEqual(StepControl.cont, StepControl.cont);
    try testing.expectEqual(StepControl.pause, StepControl.pause);
    try testing.expectEqual(StepControl.abort, StepControl.abort);
}

test "MessagePhase enum values" {
    try testing.expectEqual(MessagePhase.before, MessagePhase.before);
    try testing.expectEqual(MessagePhase.after, MessagePhase.after);
}

test "DebugHooks default initialization" {
    const hooks = DebugHooks{};
    try testing.expect(hooks.user_ctx == null);
    try testing.expect(hooks.on_step == null);
    try testing.expect(hooks.on_message == null);
}

test "DebugHooks step_only constructor" {
    const TestContext = struct {
        calls: u32 = 0,
        
        fn step_hook(ctx: ?*anyopaque, frame: *Frame, pc: usize, opcode: u8) anyerror!StepControl {
            _ = frame;
            _ = pc;
            _ = opcode;
            const self = @as(*@This(), @ptrCast(@alignCast(ctx.?)));
            self.calls += 1;
            return .cont;
        }
    };
    
    var ctx = TestContext{};
    const hooks = DebugHooks.step_only(TestContext.step_hook, &ctx);
    
    try testing.expect(hooks.user_ctx == @as(*anyopaque, @ptrCast(&ctx)));
    try testing.expect(hooks.on_step != null);
    try testing.expect(hooks.on_message == null);
}

test "DebugHooks message_only constructor" {
    const TestContext = struct {
        calls: u32 = 0,
        
        fn message_hook(ctx: ?*anyopaque, params: *const CallParams, phase: MessagePhase) anyerror!void {
            _ = params;
            _ = phase;
            const self = @as(*@This(), @ptrCast(@alignCast(ctx.?)));
            self.calls += 1;
        }
    };
    
    var ctx = TestContext{};
    const hooks = DebugHooks.message_only(TestContext.message_hook, &ctx);
    
    try testing.expect(hooks.user_ctx == @as(*anyopaque, @ptrCast(&ctx)));
    try testing.expect(hooks.on_step == null);
    try testing.expect(hooks.on_message != null);
}

test "DebugHooks full constructor" {
    const TestContext = struct {
        step_calls: u32 = 0,
        message_calls: u32 = 0,
        
        fn step_hook(ctx: ?*anyopaque, frame: *Frame, pc: usize, opcode: u8) anyerror!StepControl {
            _ = frame;
            _ = pc;
            _ = opcode;
            const self = @as(*@This(), @ptrCast(@alignCast(ctx.?)));
            self.step_calls += 1;
            return .cont;
        }
        
        fn message_hook(ctx: ?*anyopaque, params: *const CallParams, phase: MessagePhase) anyerror!void {
            _ = params;
            _ = phase;
            const self = @as(*@This(), @ptrCast(@alignCast(ctx.?)));
            self.message_calls += 1;
        }
    };
    
    var ctx = TestContext{};
    const hooks = DebugHooks.full(TestContext.step_hook, TestContext.message_hook, &ctx);
    
    try testing.expect(hooks.user_ctx == @as(*anyopaque, @ptrCast(&ctx)));
    try testing.expect(hooks.on_step != null);
    try testing.expect(hooks.on_message != null);
}

test "OnStepFn signature and error handling" {
    const TestContext = struct {
        should_error: bool,
        should_pause: bool,
        should_abort: bool,
        
        fn step_hook(ctx: ?*anyopaque, frame: *Frame, pc: usize, opcode: u8) anyerror!StepControl {
            _ = frame;
            _ = pc;
            _ = opcode;
            const self = @as(*@This(), @ptrCast(@alignCast(ctx.?)));
            
            if (self.should_error) return error.TestError;
            if (self.should_pause) return .pause;
            if (self.should_abort) return .abort;
            return .cont;
        }
    };
    
    // Mock frame for testing (minimal required fields)
    var mock_frame = Frame{
        .memory = undefined,
        .stack = undefined,
        .analysis = undefined,
        .host = undefined,
        .state = undefined,
        .contract_address = primitives.Address.ZERO,
        .depth = 0,
        .gas_remaining = 1000,
        .is_static = false,
        .caller = primitives.Address.ZERO,
        .value = 0,
    };
    
    // Test continue
    var ctx1 = TestContext{ .should_error = false, .should_pause = false, .should_abort = false };
    const result1 = TestContext.step_hook(&ctx1, &mock_frame, 0, 0x00);
    try testing.expectEqual(StepControl.cont, try result1);
    
    // Test pause
    var ctx2 = TestContext{ .should_error = false, .should_pause = true, .should_abort = false };
    const result2 = TestContext.step_hook(&ctx2, &mock_frame, 0, 0x00);
    try testing.expectEqual(StepControl.pause, try result2);
    
    // Test abort
    var ctx3 = TestContext{ .should_error = false, .should_pause = false, .should_abort = true };
    const result3 = TestContext.step_hook(&ctx3, &mock_frame, 0, 0x00);
    try testing.expectEqual(StepControl.abort, try result3);
    
    // Test error handling
    var ctx4 = TestContext{ .should_error = true, .should_pause = false, .should_abort = false };
    const result4 = TestContext.step_hook(&ctx4, &mock_frame, 0, 0x00);
    try testing.expectError(error.TestError, result4);
}

test "OnMessageFn signature and error handling" {
    const TestContext = struct {
        should_error: bool,
        call_count: u32 = 0,
        last_phase: ?MessagePhase = null,
        
        fn message_hook(ctx: ?*anyopaque, params: *const CallParams, phase: MessagePhase) anyerror!void {
            _ = params;
            const self = @as(*@This(), @ptrCast(@alignCast(ctx.?)));
            self.call_count += 1;
            self.last_phase = phase;
            
            if (self.should_error) return error.TestError;
        }
    };
    
    // Mock call params for testing
    const mock_params = CallParams{ 
        .call = .{
            .caller = primitives.Address.ZERO,
            .to = primitives.Address.ZERO,
            .value = 0,
            .input = &.{},
            .gas = 1000,
        }
    };
    
    // Test successful before phase
    var ctx1 = TestContext{ .should_error = false };
    try TestContext.message_hook(&ctx1, &mock_params, .before);
    try testing.expectEqual(@as(u32, 1), ctx1.call_count);
    try testing.expectEqual(MessagePhase.before, ctx1.last_phase.?);
    
    // Test successful after phase  
    var ctx2 = TestContext{ .should_error = false };
    try TestContext.message_hook(&ctx2, &mock_params, .after);
    try testing.expectEqual(@as(u32, 1), ctx2.call_count);
    try testing.expectEqual(MessagePhase.after, ctx2.last_phase.?);
    
    // Test error handling
    var ctx3 = TestContext{ .should_error = true };
    const result = TestContext.message_hook(&ctx3, &mock_params, .before);
    try testing.expectError(error.TestError, result);
    try testing.expectEqual(@as(u32, 1), ctx3.call_count); // Should still be called before error
}

test "DebugHooks size constraints" {
    // Verify size assumptions for performance
    try testing.expect(@sizeOf(DebugHooks) <= 64); // Should fit in cache line
    try testing.expect(@sizeOf(?OnStepFn) == 8); // Optional function pointer
    try testing.expect(@sizeOf(?OnMessageFn) == 8); // Optional function pointer
    
    // Verify alignment
    try testing.expect(@alignOf(DebugHooks) <= 8);
}

test "DebugHooks null context handling" {
    const TestHooks = struct {
        fn step_with_null_ctx(ctx: ?*anyopaque, frame: *Frame, pc: usize, opcode: u8) anyerror!StepControl {
            _ = frame;
            _ = pc;
            _ = opcode;
            try testing.expect(ctx == null);
            return .cont;
        }
        
        fn message_with_null_ctx(ctx: ?*anyopaque, params: *const CallParams, phase: MessagePhase) anyerror!void {
            _ = params;
            _ = phase;
            try testing.expect(ctx == null);
        }
    };
    
    const hooks = DebugHooks{
        .user_ctx = null,
        .on_step = TestHooks.step_with_null_ctx,
        .on_message = TestHooks.message_with_null_ctx,
    };
    
    try testing.expect(hooks.user_ctx == null);
    try testing.expect(hooks.on_step != null);
    try testing.expect(hooks.on_message != null);
}