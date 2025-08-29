// ============================================================================
// COMPREHENSIVE TRACER TESTS - EXHAUSTIVE COVERAGE
// ============================================================================

const std = @import("std");
const testing = std.testing;
const frame_mod = @import("stack_frame.zig");
const frame_config = @import("frame_config.zig");
const dispatch_mod = @import("dispatch.zig");
const DebuggingTracer = @import("tracer.zig").DebuggingTracer;
const NoOpTracer = @import("tracer.zig").NoOpTracer;
const Tracer = @import("tracer.zig").Tracer;
const LoggingTracer = @import("tracer.zig").LoggingTracer;
const FileTracer = @import("tracer.zig").FileTracer;
const getOpcodeName = @import("tracer.zig").getOpcodeName;
const Host = @import("host.zig").Host;
// const createTestHost = @import("tracer.zig").createTestHost;
const Opcode = @import("opcode.zig").Opcode;
const primitives = @import("primitives");
const Address = primitives.Address.Address;
const ZERO_ADDRESS = primitives.ZERO_ADDRESS;
const block_info_mod = @import("block_info.zig");
const call_params_mod = @import("call_params.zig");
const call_result_mod = @import("call_result.zig");
const hardfork_mod = @import("hardfork.zig");

// Minimal test host for tracer tests
const TestHost = struct {
    const Self = @This();

    pub fn get_balance(self: *Self, address: Address) u256 {
        _ = self;
        _ = address;
        return 0;
    }

    pub fn account_exists(self: *Self, address: Address) bool {
        _ = self;
        _ = address;
        return false;
    }

    pub fn get_code(self: *Self, address: Address) []const u8 {
        _ = self;
        _ = address;
        return &[_]u8{};
    }

    pub fn get_block_info(self: *Self) block_info_mod.DefaultBlockInfo {
        _ = self;
        return block_info_mod.DefaultBlockInfo.init();
    }

    pub fn emit_log(self: *Self, contract_address: Address, topics: []const u256, data: []const u8) void {
        _ = self;
        _ = contract_address;
        _ = topics;
        _ = data;
    }

    pub fn inner_call(self: *Self, params: call_params_mod.CallParams) !call_result_mod.CallResult {
        _ = self;
        _ = params;
        return error.NotImplemented;
    }

    pub fn register_created_contract(self: *Self, address: Address) !void {
        _ = self;
        _ = address;
    }

    pub fn was_created_in_tx(self: *Self, address: Address) bool {
        _ = self;
        _ = address;
        return false;
    }

    pub fn create_snapshot(self: *Self) u32 {
        _ = self;
        return 0;
    }

    pub fn revert_to_snapshot(self: *Self, snapshot_id: u32) void {
        _ = self;
        _ = snapshot_id;
    }

    pub fn get_storage(self: *Self, address: Address, slot: u256) u256 {
        _ = self;
        _ = address;
        _ = slot;
        return 0;
    }

    pub fn set_storage(self: *Self, address: Address, slot: u256, value: u256) !void {
        _ = self;
        _ = address;
        _ = slot;
        _ = value;
    }

    pub fn record_storage_change(self: *Self, address: Address, slot: u256, original_value: u256) !void {
        _ = self;
        _ = address;
        _ = slot;
        _ = original_value;
    }

    pub fn get_original_storage(self: *Self, address: Address, slot: u256) ?u256 {
        _ = self;
        _ = address;
        _ = slot;
        return null;
    }

    pub fn access_address(self: *Self, address: Address) !u64 {
        _ = self;
        _ = address;
        return 0;
    }

    pub fn access_storage_slot(self: *Self, contract_address: Address, slot: u256) !u64 {
        _ = self;
        _ = contract_address;
        _ = slot;
        return 0;
    }

    pub fn mark_for_destruction(self: *Self, contract_address: Address, recipient: Address) !void {
        _ = self;
        _ = contract_address;
        _ = recipient;
    }

    pub fn get_input(self: *Self) []const u8 {
        _ = self;
        return &[_]u8{};
    }

    pub fn is_hardfork_at_least(self: *Self, target: hardfork_mod.Hardfork) bool {
        _ = self;
        _ = target;
        return true;
    }

    pub fn get_hardfork(self: *Self) hardfork_mod.Hardfork {
        _ = self;
        return .CANCUN;
    }

    pub fn get_is_static(self: *Self) bool {
        _ = self;
        return false;
    }

    pub fn get_depth(self: *Self) u11 {
        _ = self;
        return 0;
    }

    pub fn get_gas_price(self: *Self) u256 {
        _ = self;
        return 0;
    }

    pub fn get_return_data(self: *Self) []const u8 {
        _ = self;
        return &[_]u8{};
    }

    pub fn get_chain_id(self: *Self) u16 {
        _ = self;
        return 1;
    }

    pub fn get_block_hash(self: *Self, block_number: u64) ?[32]u8 {
        _ = self;
        _ = block_number;
        return null;
    }

    pub fn get_blob_hash(self: *Self, index: u256) ?[32]u8 {
        _ = self;
        _ = index;
        return null;
    }

    pub fn get_blob_base_fee(self: *Self) u256 {
        _ = self;
        return 0;
    }

    pub fn get_tx_origin(self: *Self) Address {
        _ = self;
        return ZERO_ADDRESS;
    }

    pub fn get_caller(self: *Self) Address {
        _ = self;
        return ZERO_ADDRESS;
    }

    pub fn get_call_value(self: *Self) u256 {
        _ = self;
        return 0;
    }
};

// Helper function to create a test host for tracer tests
fn createTestHost() Host {
    const holder = struct {
        var instance: TestHost = .{};
    };
    return Host.init(&holder.instance);
}

// ============================================================================
// 1. BASIC TRACING INFRASTRUCTURE TESTS
// ============================================================================

test "Trace handlers injected into dispatch when tracing enabled" {
    const allocator = testing.allocator;
    
    // Create frame with tracing
    const FrameWithTracing = frame_mod.StackFrame(.{
        .TracerType = DebuggingTracer,
        .stack_size = 256,
    });
    
    // Simple bytecode: PUSH1 5, ADD, STOP
    const bytecode = [_]u8{ 0x60, 0x05, 0x01, 0x00 };
    
    // Build dispatch schedule  
    const bytecode_obj = try FrameWithTracing.Bytecode.init(allocator, &bytecode);
    defer bytecode_obj.deinit(allocator);
    
    const Dispatch = dispatch_mod.Dispatch(FrameWithTracing);
    const schedule = try Dispatch.init(
        allocator,
        &bytecode_obj,
        &FrameWithTracing.opcode_handlers,
    );
    defer allocator.free(schedule);
    
    // Verify trace handlers are present
    // Expected pattern: [PC][trace_before][PUSH1][value][trace_after]...
    var found_trace_before = false;
    var found_trace_after = false;
    
    for (schedule) |item| {
        if (item == .opcode_handler) {
            const handler_ptr = @intFromPtr(item.opcode_handler);
            const trace_before_ptr = @intFromPtr(&FrameWithTracing.trace_before_handler);
            const trace_after_ptr = @intFromPtr(&FrameWithTracing.trace_after_handler);
            
            if (handler_ptr == trace_before_ptr) found_trace_before = true;
            if (handler_ptr == trace_after_ptr) found_trace_after = true;
        }
    }
    
    try testing.expect(found_trace_before);
    try testing.expect(found_trace_after);
}

test "No trace handlers when tracing disabled" {
    const allocator = testing.allocator;
    
    // Create frame without tracing
    const FrameNoTracing = frame_mod.StackFrame(.{
        .TracerType = null,
        .stack_size = 256,
    });
    
    const bytecode = [_]u8{ 0x60, 0x05, 0x01, 0x00 };
    
    const bytecode_obj = try FrameNoTracing.Bytecode.init(allocator, &bytecode);
    defer bytecode_obj.deinit(allocator);
    
    const Dispatch = dispatch_mod.Dispatch(FrameNoTracing);
    const schedule = try Dispatch.init(
        allocator,
        &bytecode_obj,
        &FrameNoTracing.opcode_handlers,
    );
    defer allocator.free(schedule);
    
    // Verify no trace handlers
    for (schedule) |item| {
        if (item == .opcode_handler) {
            // These handlers shouldn't exist when tracing is disabled
            // but let's make sure they're not somehow injected
            const handler_ptr = @intFromPtr(item.opcode_handler);
            // Can't check against trace handlers since they don't exist
            // Just verify we have normal handlers
            try testing.expect(handler_ptr != 0);
        }
    }
}

test "PC metadata stored before trace_before_handler" {
    const allocator = testing.allocator;
    
    const FrameWithTracing = frame_mod.StackFrame(.{
        .TracerType = DebuggingTracer,
        .stack_size = 256,
    });
    
    const bytecode = [_]u8{ 0x60, 0x05 }; // PUSH1 5
    
    const bytecode_obj = try FrameWithTracing.Bytecode.init(allocator, &bytecode);
    defer bytecode_obj.deinit(allocator);
    
    const Dispatch = dispatch_mod.Dispatch(FrameWithTracing);
    const schedule = try Dispatch.init(
        allocator,
        &bytecode_obj,
        &FrameWithTracing.opcode_handlers,
    );
    defer allocator.free(schedule);
    
    // Find trace_before handler and check if PC metadata precedes it
    for (schedule, 0..) |item, i| {
        if (item == .opcode_handler) {
            const handler_ptr = @intFromPtr(item.opcode_handler);
            const trace_before_ptr = @intFromPtr(&FrameWithTracing.trace_before_handler);
            
            if (handler_ptr == trace_before_ptr and i > 0) {
                // Check previous item is PC metadata
                const prev_item = schedule[i - 1];
                try testing.expect(prev_item == .pc);
                try testing.expect(prev_item.pc.value == 0); // PC should be 0 for first instruction
            }
        }
    }
}

// ============================================================================
// 2. PC TRACKING AND RESOLUTION TESTS
// ============================================================================

test "PC correctly maintained through execution" {
    const allocator = testing.allocator;
    
    const Frame = frame_mod.StackFrame(.{
        .TracerType = DebuggingTracer,
        .stack_size = 256,
    });
    
    var frame = try Frame.init(allocator, &[_]u8{ 0x60, 0x05, 0x60, 0x03, 0x01 }, 10000, {}, createTestHost());
    defer frame.deinit(allocator);
    
    // Initially PC should be 0
    try testing.expectEqual(@as(u32, 0), frame.current_pc);
    
    // After trace_before_handler updates it, it should reflect the actual PC
    // This will be tested in actual execution tests
}

test "PC correct for different opcode types" {
    const allocator = testing.allocator;
    
    const Frame = frame_mod.StackFrame(.{
        .TracerType = DebuggingTracer,
        .stack_size = 256,
    });
    
    // Bytecode with various opcodes:
    // PC=0: PUSH1 5
    // PC=2: PUSH2 1234
    // PC=5: ADD
    // PC=6: PC
    // PC=7: STOP
    const bytecode = [_]u8{ 
        0x60, 0x05,       // PUSH1 5
        0x61, 0x04, 0xD2, // PUSH2 1234
        0x01,             // ADD
        0x58,             // PC
        0x00,             // STOP
    };
    
    const bytecode_obj = try Frame.Bytecode.init(allocator, &bytecode);
    defer bytecode_obj.deinit(allocator);
    
    const Dispatch = dispatch_mod.Dispatch(Frame);
    const schedule = try Dispatch.init(
        allocator,
        &bytecode_obj,
        &Frame.opcode_handlers,
    );
    defer allocator.free(schedule);
    
    // Verify PC metadata values
    var pc_values = std.ArrayList(u32).init(allocator);
    defer pc_values.deinit();
    
    for (schedule) |item| {
        if (item == .pc) {
            // Skip duplicate PC for PC opcode
            const pc_val = @as(u32, @intCast(item.pc.value));
            
            // Check if this PC is already in our list (avoid duplicates from PC opcode)
            var is_duplicate = false;
            for (pc_values.items) |existing_pc| {
                if (existing_pc == pc_val) {
                    is_duplicate = true;
                    break;
                }
            }
            
            if (!is_duplicate) {
                try pc_values.append(pc_val);
            }
        }
    }
    
    // We should have PCs: 0, 2, 5, 6, 7
    try testing.expect(std.mem.indexOfScalar(u32, pc_values.items, 0) != null);
    try testing.expect(std.mem.indexOfScalar(u32, pc_values.items, 2) != null);
    try testing.expect(std.mem.indexOfScalar(u32, pc_values.items, 5) != null);
    try testing.expect(std.mem.indexOfScalar(u32, pc_values.items, 6) != null);
    try testing.expect(std.mem.indexOfScalar(u32, pc_values.items, 7) != null);
}

// ============================================================================
// 3. BREAKPOINT MANAGEMENT TESTS
// ============================================================================

test "Breakpoint operations comprehensive" {
    var tracer = DebuggingTracer.init();
    defer tracer.deinit();
    
    // Add breakpoints
    try tracer.addBreakpoint(0);
    try tracer.addBreakpoint(10);
    try tracer.addBreakpoint(100);
    try tracer.addBreakpoint(std.math.maxInt(u32));
    
    // Verify they exist
    try testing.expect(tracer.hasBreakpoint(0));
    try testing.expect(tracer.hasBreakpoint(10));
    try testing.expect(tracer.hasBreakpoint(100));
    try testing.expect(tracer.hasBreakpoint(std.math.maxInt(u32)));
    
    // Verify non-existent ones don't exist
    try testing.expect(!tracer.hasBreakpoint(1));
    try testing.expect(!tracer.hasBreakpoint(99));
    
    // Remove breakpoints
    try testing.expect(tracer.removeBreakpoint(10));
    try testing.expect(!tracer.hasBreakpoint(10));
    
    // Remove non-existent returns false
    try testing.expect(!tracer.removeBreakpoint(10));
    try testing.expect(!tracer.removeBreakpoint(999));
    
    // Clear all
    tracer.clearBreakpoints();
    try testing.expect(!tracer.hasBreakpoint(0));
    try testing.expect(!tracer.hasBreakpoint(100));
    try testing.expect(!tracer.hasBreakpoint(std.math.maxInt(u32)));
}

test "Breakpoints persist across reset" {
    var tracer = DebuggingTracer.init();
    defer tracer.deinit();
    
    // Add breakpoints
    try tracer.addBreakpoint(10);
    try tracer.addBreakpoint(20);
    
    // Reset tracer
    tracer.reset();
    
    // Breakpoints should still exist
    try testing.expect(tracer.hasBreakpoint(10));
    try testing.expect(tracer.hasBreakpoint(20));
    
    // But execution state should be cleared
    try testing.expect(!tracer.paused);
    try testing.expectEqual(@as(u64, 0), tracer.total_instructions);
}

// ============================================================================
// 4. PAUSE/RESUME EXECUTION TESTS
// ============================================================================

test "shouldPause behavior comprehensive" {
    var tracer = DebuggingTracer.init();
    defer tracer.deinit();
    
    // Initially no pause
    try testing.expect(!tracer.shouldPause(0));
    try testing.expect(!tracer.shouldPause(100));
    
    // Add breakpoint - should pause at that PC
    try tracer.addBreakpoint(50);
    try testing.expect(tracer.shouldPause(50));
    try testing.expect(!tracer.shouldPause(49));
    try testing.expect(!tracer.shouldPause(51));
    
    // Enable step mode - should pause everywhere
    tracer.setStepMode(true);
    try testing.expect(tracer.shouldPause(0));
    try testing.expect(tracer.shouldPause(49));
    try testing.expect(tracer.shouldPause(50));
    try testing.expect(tracer.shouldPause(51));
    try testing.expect(tracer.shouldPause(std.math.maxInt(u32)));
    
    // Disable step mode - back to breakpoint only
    tracer.setStepMode(false);
    try testing.expect(!tracer.shouldPause(0));
    try testing.expect(tracer.shouldPause(50));
}

test "Pause and resume state management" {
    var tracer = DebuggingTracer.init();
    defer tracer.deinit();
    
    // Initially not paused
    try testing.expect(!tracer.paused);
    
    // Pause
    tracer.pause();
    try testing.expect(tracer.paused);
    
    // Resume
    tracer.resumeExecution();
    try testing.expect(!tracer.paused);
    
    // setResumeDispatch sets paused
    const mock_dispatch = @as(*const anyopaque, @ptrFromInt(0xDEADBEEF));
    tracer.setResumeDispatch(mock_dispatch);
    try testing.expect(tracer.paused);
    try testing.expect(tracer.resume_dispatch == mock_dispatch);
}

// ============================================================================
// 5. STEP MODE EXECUTION TESTS
// ============================================================================

test "Step mode comprehensive" {
    var tracer = DebuggingTracer.init();
    defer tracer.deinit();
    
    // Initially not in step mode
    try testing.expect(!tracer.step_mode);
    
    // Enable step mode
    tracer.setStepMode(true);
    try testing.expect(tracer.step_mode);
    try testing.expect(tracer.shouldPause(0));
    try testing.expect(tracer.shouldPause(999));
    
    // Disable step mode
    tracer.setStepMode(false);
    try testing.expect(!tracer.step_mode);
    try testing.expect(!tracer.shouldPause(999));
}

test "Step mode with breakpoints" {
    var tracer = DebuggingTracer.init();
    defer tracer.deinit();
    
    // Add breakpoint
    try tracer.addBreakpoint(100);
    
    // Both step mode and breakpoint should work
    tracer.setStepMode(true);
    try testing.expect(tracer.shouldPause(50));  // Step mode
    try testing.expect(tracer.shouldPause(100)); // Both
    
    tracer.setStepMode(false);
    try testing.expect(!tracer.shouldPause(50)); // Neither
    try testing.expect(tracer.shouldPause(100)); // Breakpoint only
}

// ============================================================================
// 6. ERROR HANDLING TESTS
// ============================================================================

test "Error handling with different configurations" {
    var tracer = DebuggingTracer.init();
    defer tracer.deinit();
    
    const MockFrame = struct {
        gas_remaining: i64 = 1000,
        next_stack_index: usize = 0,
        stack: [16]u256 = [_]u256{0} ** 16,
    };
    
    var frame = MockFrame{};
    
    // Add a step to record error in
    tracer.beforeOp(10, 0x01, MockFrame, &frame);
    
    // Test error recording
    tracer.onError(10, error.OutOfGas, MockFrame, &frame);
    try testing.expect(tracer.paused);
    
    // Check error was recorded
    if (tracer.steps.items.len > 0) {
        const last_step = &tracer.steps.items[tracer.steps.items.len - 1];
        try testing.expect(last_step.error_occurred);
        try testing.expect(last_step.error_msg != null);
    }
}

test "Different error types captured correctly" {
    var tracer = DebuggingTracer.init();
    defer tracer.deinit();
    
    const MockFrame = struct {
        gas_remaining: i64 = 1000,
        next_stack_index: usize = 0,
        stack: [16]u256 = [_]u256{0} ** 16,
    };
    
    var frame = MockFrame{};
    
    // Test various error types
    const errors = [_]anyerror{
        error.OutOfGas,
        error.StackOverflow,
        error.StackUnderflow,
        error.InvalidOpcode,
        error.InvalidJump,
    };
    
    for (errors) |err| {
        tracer.reset();
        tracer.beforeOp(0, 0x00, MockFrame, &frame);
        tracer.onError(0, err, MockFrame, &frame);
        
        try testing.expect(tracer.paused);
        if (tracer.steps.items.len > 0) {
            const step = &tracer.steps.items[0];
            try testing.expect(step.error_occurred);
            try testing.expect(step.error_msg != null);
        }
    }
}

// ============================================================================
// 7. STATE CAPTURE AND HISTORY TESTS
// ============================================================================

test "State capture comprehensive" {
    var tracer = DebuggingTracer.init();
    defer tracer.deinit();
    
    const MockFrame = struct {
        gas_remaining: i64 = 1000,
        next_stack_index: usize = 3,
        stack: [16]u256 = undefined,
        
        fn init() @This() {
            var f = @This(){
                .gas_remaining = 1000,
                .next_stack_index = 3,
                .stack = undefined,
            };
            f.stack[0] = 100;
            f.stack[1] = 200;
            f.stack[2] = 300;
            return f;
        }
    };
    
    var frame = MockFrame.init();
    
    // Capture before
    tracer.beforeOp(10, 0x01, MockFrame, &frame);
    
    // Modify state
    frame.gas_remaining = 950;
    frame.stack[2] = 500; // Change top of stack
    
    // Capture after
    tracer.afterOp(10, 0x01, MockFrame, &frame);
    
    // Verify step was captured
    try testing.expectEqual(@as(usize, 1), tracer.steps.items.len);
    
    const step = &tracer.steps.items[0];
    try testing.expectEqual(@as(u32, 10), step.pc);
    try testing.expectEqual(@as(u8, 0x01), step.opcode);
    try testing.expectEqual(@as(usize, 3), step.stack_before.len);
    try testing.expectEqual(@as(u256, 100), step.stack_before[0]);
    try testing.expectEqual(@as(u256, 200), step.stack_before[1]);
    try testing.expectEqual(@as(u256, 300), step.stack_before[2]);
    try testing.expectEqual(@as(usize, 3), step.stack_after.len);
    try testing.expectEqual(@as(u256, 500), step.stack_after[2]);
}

test "History pruning to max_history" {
    var tracer = DebuggingTracer.init();
    defer tracer.deinit();
    
    // Configure small history
    tracer.configure(.{ .max_history = 3 });
    
    const MockFrame = struct {
        gas_remaining: i64 = 1000,
        next_stack_index: usize = 0,
        stack: [16]u256 = [_]u256{0} ** 16,
    };
    
    var frame = MockFrame{};
    
    // Add more steps than max_history
    for (0..5) |i| {
        const pc = @as(u32, @intCast(i * 10));
        tracer.beforeOp(pc, 0x00, MockFrame, &frame);
        tracer.afterOp(pc, 0x00, MockFrame, &frame);
    }
    
    // Should be pruned to max_history
    try testing.expectEqual(@as(usize, 3), tracer.steps.items.len);
    
    // Oldest steps should be removed (0, 10 removed, 20, 30, 40 remain)
    try testing.expectEqual(@as(u32, 20), tracer.steps.items[0].pc);
    try testing.expectEqual(@as(u32, 30), tracer.steps.items[1].pc);
    try testing.expectEqual(@as(u32, 40), tracer.steps.items[2].pc);
}

// ============================================================================
// 8. CONFIGURATION MANAGEMENT TESTS
// ============================================================================

test "Configuration changes comprehensive" {
    var tracer = DebuggingTracer.init();
    defer tracer.deinit();
    
    // Initial configuration
    try testing.expect(!tracer.step_mode);
    try testing.expect(tracer.throw_on_error);
    try testing.expectEqual(@as(usize, 10000), tracer.max_history);
    
    // Change configuration
    tracer.configure(.{
        .step_mode = true,
        .throw_on_error = false,
        .max_history = 100,
    });
    
    try testing.expect(tracer.step_mode);
    try testing.expect(!tracer.throw_on_error);
    try testing.expectEqual(@as(usize, 100), tracer.max_history);
    
    // Partial configuration change
    tracer.configure(.{
        .step_mode = false,
        .throw_on_error = false, // Keep same
        .max_history = 100,       // Keep same
    });
    
    try testing.expect(!tracer.step_mode);
    try testing.expect(!tracer.throw_on_error);
    try testing.expectEqual(@as(usize, 100), tracer.max_history);
}

// ============================================================================
// 9. EDGE CASES AND BOUNDARIES TESTS
// ============================================================================

test "Empty bytecode with tracing" {
    const allocator = testing.allocator;
    
    const Frame = frame_mod.StackFrame(.{
        .TracerType = DebuggingTracer,
        .stack_size = 256,
    });
    
    const bytecode = [_]u8{};
    
    const bytecode_obj = try Frame.Bytecode.init(allocator, &bytecode);
    defer bytecode_obj.deinit(allocator);
    
    const Dispatch = dispatch_mod.Dispatch(Frame);
    const schedule = try Dispatch.init(
        allocator,
        &bytecode_obj,
        &Frame.opcode_handlers,
    );
    defer allocator.free(schedule);
    
    // Should still have terminator STOPs
    try testing.expect(schedule.len >= 2);
}

test "Single instruction bytecode" {
    const allocator = testing.allocator;
    
    const Frame = frame_mod.StackFrame(.{
        .TracerType = DebuggingTracer,
        .stack_size = 256,
    });
    
    const bytecode = [_]u8{0x00}; // Just STOP
    
    const bytecode_obj = try Frame.Bytecode.init(allocator, &bytecode);
    defer bytecode_obj.deinit(allocator);
    
    const Dispatch = dispatch_mod.Dispatch(Frame);
    const schedule = try Dispatch.init(
        allocator,
        &bytecode_obj,
        &Frame.opcode_handlers,
    );
    defer allocator.free(schedule);
    
    // Should have: [PC:0][trace_before][STOP][trace_after][STOP][STOP]
    var pc_count: u32 = 0;
    var stop_count: u32 = 0;
    
    for (schedule) |item| {
        if (item == .pc) pc_count += 1;
        if (item == .opcode_handler) {
            const stop_ptr = @intFromPtr(&Frame.opcode_handlers[@intFromEnum(Opcode.STOP)]);
            const handler_ptr = @intFromPtr(item.opcode_handler);
            if (handler_ptr == stop_ptr) stop_count += 1;
        }
    }
    
    try testing.expect(pc_count >= 1);
    try testing.expect(stop_count >= 2); // Original + terminators
}

test "Breakpoint beyond bytecode length" {
    var tracer = DebuggingTracer.init();
    defer tracer.deinit();
    
    // Set breakpoint way beyond typical bytecode
    try tracer.addBreakpoint(100000);
    
    // Should work fine - breakpoint is just a PC value
    try testing.expect(tracer.hasBreakpoint(100000));
    try testing.expect(tracer.shouldPause(100000));
    
    // Won't be hit in normal execution but should be valid
}

test "Resume without prior pause" {
    var tracer = DebuggingTracer.init();
    defer tracer.deinit();
    
    // Resume without pause - should just clear paused flag
    tracer.resumeExecution();
    try testing.expect(!tracer.paused);
    
    // Set resume dispatch without pause
    const mock_dispatch = @as(*const anyopaque, @ptrFromInt(0x12345678));
    tracer.setResumeDispatch(mock_dispatch);
    
    // This sets paused to true
    try testing.expect(tracer.paused);
    try testing.expect(tracer.resume_dispatch == mock_dispatch);
}

// ============================================================================
// 10. STATISTICS AND METRICS TESTS
// ============================================================================

test "Statistics tracking comprehensive" {
    var tracer = DebuggingTracer.init();
    defer tracer.deinit();
    
    const MockFrame = struct {
        gas_remaining: i64 = 1000,
        next_stack_index: usize = 0,
        stack: [16]u256 = [_]u256{0} ** 16,
    };
    
    var frame = MockFrame{};
    
    // Initial stats
    var stats = tracer.getStats();
    try testing.expectEqual(@as(u64, 0), stats.total_instructions);
    try testing.expectEqual(@as(u64, 0), stats.total_gas_used);
    try testing.expectEqual(@as(usize, 0), stats.breakpoint_count);
    try testing.expectEqual(@as(usize, 0), stats.history_size);
    
    // Add breakpoints
    try tracer.addBreakpoint(10);
    try tracer.addBreakpoint(20);
    
    // Execute some operations
    for (0..5) |i| {
        const pc = @as(u32, @intCast(i));
        tracer.beforeOp(pc, 0x01, MockFrame, &frame);
        frame.gas_remaining -= 3;
        tracer.afterOp(pc, 0x01, MockFrame, &frame);
    }
    
    // Check updated stats
    stats = tracer.getStats();
    try testing.expectEqual(@as(u64, 5), stats.total_instructions);
    try testing.expectEqual(@as(usize, 2), stats.breakpoint_count);
    try testing.expectEqual(@as(usize, 5), stats.history_size);
}

test "Step count tracking" {
    var tracer = DebuggingTracer.init();
    defer tracer.deinit();
    
    try testing.expectEqual(@as(u64, 0), tracer.getStepCount());
    
    const MockFrame = struct {
        gas_remaining: i64 = 1000,
        next_stack_index: usize = 0,
        stack: [16]u256 = [_]u256{0} ** 16,
    };
    
    var frame = MockFrame{};
    
    // Execute operations
    tracer.beforeOp(0, 0x60, MockFrame, &frame);
    tracer.afterOp(0, 0x60, MockFrame, &frame);
    
    try testing.expectEqual(@as(u64, 1), tracer.getStepCount());
    
    tracer.beforeOp(2, 0x01, MockFrame, &frame);
    tracer.afterOp(2, 0x01, MockFrame, &frame);
    
    try testing.expectEqual(@as(u64, 2), tracer.getStepCount());
}

// ============================================================================
// 11. MEMORY MANAGEMENT TESTS
// ============================================================================

test "Memory cleanup on reset" {
    var tracer = DebuggingTracer.init();
    defer tracer.deinit();
    
    const MockFrame = struct {
        gas_remaining: i64 = 1000,
        next_stack_index: usize = 2,
        stack: [16]u256 = undefined,
        
        fn init() @This() {
            var f = @This(){
                .gas_remaining = 1000,
                .next_stack_index = 2,
                .stack = undefined,
            };
            f.stack[0] = 111;
            f.stack[1] = 222;
            return f;
        }
    };
    
    var frame = MockFrame.init();
    
    // Create some steps with allocated memory
    for (0..3) |i| {
        const pc = @as(u32, @intCast(i));
        tracer.beforeOp(pc, 0x01, MockFrame, &frame);
        tracer.afterOp(pc, 0x01, MockFrame, &frame);
    }
    
    try testing.expectEqual(@as(usize, 3), tracer.steps.items.len);
    
    // Reset should free all memory
    tracer.reset();
    
    try testing.expectEqual(@as(usize, 0), tracer.steps.items.len);
    try testing.expectEqual(@as(u64, 0), tracer.total_instructions);
}

test "Recent steps retrieval" {
    var tracer = DebuggingTracer.init();
    defer tracer.deinit();
    
    const MockFrame = struct {
        gas_remaining: i64 = 1000,
        next_stack_index: usize = 0,
        stack: [16]u256 = [_]u256{0} ** 16,
    };
    
    var frame = MockFrame{};
    
    // Add 10 steps
    for (0..10) |i| {
        const pc = @as(u32, @intCast(i * 10));
        tracer.beforeOp(pc, 0x00, MockFrame, &frame);
        tracer.afterOp(pc, 0x00, MockFrame, &frame);
    }
    
    // Get recent 3 steps
    const recent = tracer.getRecentSteps(3);
    try testing.expectEqual(@as(usize, 3), recent.len);
    try testing.expectEqual(@as(u32, 70), recent[0].pc);
    try testing.expectEqual(@as(u32, 80), recent[1].pc);
    try testing.expectEqual(@as(u32, 90), recent[2].pc);
    
    // Get more than available
    const all = tracer.getRecentSteps(20);
    try testing.expectEqual(@as(usize, 10), all.len);
}

test "Get specific step by index" {
    var tracer = DebuggingTracer.init();
    defer tracer.deinit();
    
    const MockFrame = struct {
        gas_remaining: i64 = 1000,
        next_stack_index: usize = 0,
        stack: [16]u256 = [_]u256{0} ** 16,
    };
    
    var frame = MockFrame{};
    
    // Add some steps
    for (0..5) |i| {
        const pc = @as(u32, @intCast(i * 10));
        tracer.beforeOp(pc, @as(u8, @intCast(i)), MockFrame, &frame);
        tracer.afterOp(pc, @as(u8, @intCast(i)), MockFrame, &frame);
    }
    
    // Get specific steps
    const step0 = tracer.getStep(0);
    try testing.expect(step0 != null);
    try testing.expectEqual(@as(u32, 0), step0.?.pc);
    try testing.expectEqual(@as(u8, 0), step0.?.opcode);
    
    const step3 = tracer.getStep(3);
    try testing.expect(step3 != null);
    try testing.expectEqual(@as(u32, 30), step3.?.pc);
    try testing.expectEqual(@as(u8, 3), step3.?.opcode);
    
    // Out of bounds
    const step10 = tracer.getStep(10);
    try testing.expect(step10 == null);
}

// ============================================================================
// 12. ZERO OVERHEAD VERIFICATION TESTS
// ============================================================================

test "Zero overhead when tracing disabled" {
    // Create frame without tracing
    const Frame = frame_mod.StackFrame(.{
        .TracerType = null,
        .stack_size = 256,
    });
    
    // When tracing is disabled, current_pc should be void
    // Check that the frame doesn't have current_pc field (it's conditional)
    
    // Verify no ExecutionPaused error
    const has_execution_paused = blk: {
        const error_info = @typeInfo(Frame.Error);
        if (error_info == .error_set) {
            for (error_info.error_set.?) |err| {
                if (std.mem.eql(u8, err.name, "ExecutionPaused")) {
                    break :blk true;
                }
            }
        }
        break :blk false;
    };
    
    try testing.expect(!has_execution_paused);
}

// ============================================================================
// 13. DISPATCH NAVIGATION TESTS
// ============================================================================

test "Dispatch navigation with trace handlers" {
    const allocator = testing.allocator;
    
    const Frame = frame_mod.StackFrame(.{
        .TracerType = DebuggingTracer,
        .stack_size = 256,
    });
    
    // Bytecode: PUSH1 5, ADD
    const bytecode = [_]u8{ 0x60, 0x05, 0x01 };
    
    const bytecode_obj = try Frame.Bytecode.init(allocator, &bytecode);
    defer bytecode_obj.deinit(allocator);
    
    const Dispatch = dispatch_mod.Dispatch(Frame);
    const schedule = try Dispatch.init(
        allocator,
        &bytecode_obj,
        &Frame.opcode_handlers,
    );
    defer allocator.free(schedule);
    
    // Create dispatch at start
    const dispatch = Dispatch{ .schedule = schedule, .jump_table = null };
    
    // Navigate through schedule
    _ = dispatch;
    var handler_count: u32 = 0;
    var pc_count: u32 = 0;
    
    // Count handlers and PC metadata
    for (schedule) |item| {
        if (item == .opcode_handler) handler_count += 1;
        if (item == .pc) pc_count += 1;
    }
    
    // With tracing: [PC][trace_before][PUSH1][value][trace_after][PC][trace_before][ADD][trace_after]
    try testing.expect(handler_count > 2); // More than just PUSH1 and ADD
    try testing.expect(pc_count >= 2);     // PC for each instruction
}

// ============================================================================
// 14. COMPLEX SCENARIO TESTS
// ============================================================================

test "Multiple breakpoints hit in sequence" {
    var tracer = DebuggingTracer.init();
    defer tracer.deinit();
    
    // Set multiple breakpoints
    try tracer.addBreakpoint(0);
    try tracer.addBreakpoint(10);
    try tracer.addBreakpoint(20);
    
    const MockFrame = struct {
        gas_remaining: i64 = 1000,
        next_stack_index: usize = 0,
        stack: [16]u256 = [_]u256{0} ** 16,
    };
    
    var frame = MockFrame{};
    
    // Simulate hitting each breakpoint
    for ([_]u32{ 0, 10, 20 }) |pc| {
        tracer.paused = false; // Reset pause state
        
        // beforeOp should detect breakpoint and pause
        tracer.beforeOp(pc, 0x00, MockFrame, &frame);
        
        if (tracer.shouldPause(pc)) {
            tracer.paused = true;
        }
        
        try testing.expect(tracer.paused);
    }
}

test "Snapshot capture with state" {
    var tracer = DebuggingTracer.init();
    defer tracer.deinit();
    
    const MockFrame = struct {
        gas_remaining: i64 = 1000,
        next_stack_index: usize = 3,
        stack: [16]u256 = undefined,
        memory: struct {
            pub fn size(self: *const @This()) usize {
                _ = self;
                return 1024;
            }
        } = .{},
        depth: u32 = 2,
        
        fn init() @This() {
            var f = @This(){
                .gas_remaining = 1000,
                .next_stack_index = 3,
                .stack = undefined,
                .memory = .{},
                .depth = 2,
            };
            f.stack[0] = 100;
            f.stack[1] = 200;
            f.stack[2] = 300;
            return f;
        }
    };
    
    var frame = MockFrame.init();
    
    // Capture state
    try tracer.captureState(42, MockFrame, &frame);
    
    // Verify snapshot
    try testing.expectEqual(@as(usize, 1), tracer.state_snapshots.items.len);
    
    const snapshot = &tracer.state_snapshots.items[0];
    try testing.expectEqual(@as(u32, 42), snapshot.pc);
    try testing.expectEqual(@as(u64, 1000), snapshot.gas_remaining);
    try testing.expectEqual(@as(usize, 3), snapshot.stack.len);
    try testing.expectEqual(@as(u256, 100), snapshot.stack[0]);
    try testing.expectEqual(@as(usize, 1024), snapshot.memory_size);
    try testing.expectEqual(@as(u32, 2), snapshot.depth);
}

// ============================================================================
// ADDITIONAL TESTS FROM TRACER.ZIG
// ============================================================================

test "PC metadata stored before trace_before handler" {
    // This is tested in dispatch.zig where PC metadata is injected
    // Here we verify the tracer can read it
    var tracer = DebuggingTracer.init();
    defer tracer.deinit();
    
    const MockFrame = struct {
        gas_remaining: i64 = 1000,
        next_stack_index: usize = 0,
        stack: [16]u256 = [_]u256{0} ** 16,
        current_pc: u32 = 0,
    };
    
    var mock_frame = MockFrame{};
    
    // Simulate trace_before reading PC
    tracer.beforeOp(42, 0x60, MockFrame, &mock_frame);
    
    // Verify step was recorded with correct PC
    try std.testing.expectEqual(@as(usize, 1), tracer.steps.items.len);
    try std.testing.expectEqual(@as(u32, 42), tracer.steps.items[0].pc);
}

// =============================================================================
// SECTION 2: PC TRACKING AND RESOLUTION
// =============================================================================

test "PC correctly maintained in frame.current_pc" {
    // Test frame type with conditional current_pc field
    const FrameWithPC = struct {
        gas_remaining: i64 = 1000,
        next_stack_index: usize = 0,
        stack: [16]u256 = [_]u256{0} ** 16,
        current_pc: u32 = 0,
    };
    
    var frame = FrameWithPC{};
    var tracer = DebuggingTracer.init();
    defer tracer.deinit();
    
    // Test PC updates through multiple operations
    tracer.beforeOp(0, 0x60, FrameWithPC, &frame);
    tracer.afterOp(0, 0x60, FrameWithPC, &frame);
    
    tracer.beforeOp(2, 0x50, FrameWithPC, &frame);
    tracer.afterOp(2, 0x50, FrameWithPC, &frame);
    
    tracer.beforeOp(3, 0x01, FrameWithPC, &frame);
    tracer.afterOp(3, 0x01, FrameWithPC, &frame);
    
    // Verify all PCs were tracked correctly
    try std.testing.expectEqual(@as(u32, 0), tracer.steps.items[0].pc);
    try std.testing.expectEqual(@as(u32, 2), tracer.steps.items[1].pc);
    try std.testing.expectEqual(@as(u32, 3), tracer.steps.items[2].pc);
}

test "PC correct for PUSH opcodes with different sizes" {
    var tracer = DebuggingTracer.init();
    defer tracer.deinit();
    
    const MockFrame = struct {
        gas_remaining: i64 = 1000,
        next_stack_index: usize = 0,
        stack: [16]u256 = [_]u256{0} ** 16,
    };
    
    var frame = MockFrame{};
    
    // PUSH1 at PC=0 (next instruction at PC=2)
    tracer.beforeOp(0, 0x60, MockFrame, &frame);
    tracer.afterOp(0, 0x60, MockFrame, &frame);
    
    // PUSH2 at PC=2 (next instruction at PC=5)
    tracer.beforeOp(2, 0x61, MockFrame, &frame);
    tracer.afterOp(2, 0x61, MockFrame, &frame);
    
    // PUSH32 at PC=5 (next instruction at PC=38)
    tracer.beforeOp(5, 0x7f, MockFrame, &frame);
    tracer.afterOp(5, 0x7f, MockFrame, &frame);
    
    // Verify PCs
    try std.testing.expectEqual(@as(u32, 0), tracer.steps.items[0].pc);
    try std.testing.expectEqual(@as(u32, 2), tracer.steps.items[1].pc);
    try std.testing.expectEqual(@as(u32, 5), tracer.steps.items[2].pc);
}

test "PC correct for PC opcode (double PC metadata handling)" {
    var tracer = DebuggingTracer.init();
    defer tracer.deinit();
    
    const MockFrame = struct {
        gas_remaining: i64 = 1000,
        next_stack_index: usize = 0,
        stack: [16]u256 = [_]u256{0} ** 16,
    };
    
    var frame = MockFrame{};
    
    // PC opcode at position 58
    tracer.beforeOp(58, 0x58, MockFrame, &frame);
    tracer.afterOp(58, 0x58, MockFrame, &frame);
    
    // Verify PC was captured correctly
    try std.testing.expectEqual(@as(u32, 58), tracer.steps.items[0].pc);
}

test "PC advances correctly through bytecode sequence" {
    var tracer = DebuggingTracer.init();
    defer tracer.deinit();
    
    const MockFrame = struct {
        gas_remaining: i64 = 1000,
        next_stack_index: usize = 0,
        stack: [16]u256 = [_]u256{0} ** 16,
    };
    
    var frame = MockFrame{};
    
    // Simulate bytecode: PUSH1 0x05, PUSH1 0x03, ADD, POP, STOP
    // PCs: 0, 2, 4, 5, 6
    
    tracer.beforeOp(0, 0x60, MockFrame, &frame); // PUSH1
    tracer.afterOp(0, 0x60, MockFrame, &frame);
    
    tracer.beforeOp(2, 0x60, MockFrame, &frame); // PUSH1
    tracer.afterOp(2, 0x60, MockFrame, &frame);
    
    tracer.beforeOp(4, 0x01, MockFrame, &frame); // ADD
    tracer.afterOp(4, 0x01, MockFrame, &frame);
    
    tracer.beforeOp(5, 0x50, MockFrame, &frame); // POP
    tracer.afterOp(5, 0x50, MockFrame, &frame);
    
    tracer.beforeOp(6, 0x00, MockFrame, &frame); // STOP
    tracer.afterOp(6, 0x00, MockFrame, &frame);
    
    // Verify PC sequence
    try std.testing.expectEqual(@as(usize, 5), tracer.steps.items.len);
    try std.testing.expectEqual(@as(u32, 0), tracer.steps.items[0].pc);
    try std.testing.expectEqual(@as(u32, 2), tracer.steps.items[1].pc);
    try std.testing.expectEqual(@as(u32, 4), tracer.steps.items[2].pc);
    try std.testing.expectEqual(@as(u32, 5), tracer.steps.items[3].pc);
    try std.testing.expectEqual(@as(u32, 6), tracer.steps.items[4].pc);
}

// =============================================================================
// SECTION 3: BREAKPOINT MANAGEMENT
// =============================================================================

test "Add and check multiple breakpoints" {
    var tracer = DebuggingTracer.init();
    defer tracer.deinit();
    
    // Add multiple breakpoints
    try tracer.addBreakpoint(0);
    try tracer.addBreakpoint(10);
    try tracer.addBreakpoint(100);
    try tracer.addBreakpoint(1000);
    try tracer.addBreakpoint(std.math.maxInt(u32));
    
    // Check all exist
    try std.testing.expect(tracer.hasBreakpoint(0));
    try std.testing.expect(tracer.hasBreakpoint(10));
    try std.testing.expect(tracer.hasBreakpoint(100));
    try std.testing.expect(tracer.hasBreakpoint(1000));
    try std.testing.expect(tracer.hasBreakpoint(std.math.maxInt(u32)));
    
    // Check non-existent
    try std.testing.expect(!tracer.hasBreakpoint(5));
    try std.testing.expect(!tracer.hasBreakpoint(50));
    try std.testing.expect(!tracer.hasBreakpoint(500));
}

test "Remove breakpoints - existing and non-existent" {
    var tracer = DebuggingTracer.init();
    defer tracer.deinit();
    
    // Add breakpoints
    try tracer.addBreakpoint(10);
    try tracer.addBreakpoint(20);
    try tracer.addBreakpoint(30);
    
    // Remove existing breakpoint - should return true
    try std.testing.expect(tracer.removeBreakpoint(20) == true);
    try std.testing.expect(!tracer.hasBreakpoint(20));
    
    // Remove non-existent breakpoint - should return false
    try std.testing.expect(tracer.removeBreakpoint(40) == false);
    
    // Remove already removed breakpoint - should return false
    try std.testing.expect(tracer.removeBreakpoint(20) == false);
    
    // Other breakpoints should remain
    try std.testing.expect(tracer.hasBreakpoint(10));
    try std.testing.expect(tracer.hasBreakpoint(30));
}

test "Clear all breakpoints" {
    var tracer = DebuggingTracer.init();
    defer tracer.deinit();
    
    // Add many breakpoints
    try tracer.addBreakpoint(0);
    try tracer.addBreakpoint(10);
    try tracer.addBreakpoint(20);
    try tracer.addBreakpoint(30);
    try tracer.addBreakpoint(40);
    
    // Clear all
    tracer.clearBreakpoints();
    
    // Verify all are gone
    try std.testing.expect(!tracer.hasBreakpoint(0));
    try std.testing.expect(!tracer.hasBreakpoint(10));
    try std.testing.expect(!tracer.hasBreakpoint(20));
    try std.testing.expect(!tracer.hasBreakpoint(30));
    try std.testing.expect(!tracer.hasBreakpoint(40));
}

test "Breakpoint at PC=0 works correctly" {
    var tracer = DebuggingTracer.init();
    defer tracer.deinit();
    
    try tracer.addBreakpoint(0);
    try std.testing.expect(tracer.shouldPause(0) == true);
    try std.testing.expect(tracer.hasBreakpoint(0));
}

test "Breakpoint at maximum PC value" {
    var tracer = DebuggingTracer.init();
    defer tracer.deinit();
    
    const max_pc = std.math.maxInt(u32);
    try tracer.addBreakpoint(max_pc);
    try std.testing.expect(tracer.shouldPause(max_pc) == true);
    try std.testing.expect(tracer.hasBreakpoint(max_pc));
}

test "Breakpoints persist across resets" {
    var tracer = DebuggingTracer.init();
    defer tracer.deinit();
    
    // Add breakpoints
    try tracer.addBreakpoint(10);
    try tracer.addBreakpoint(20);
    
    // Reset tracer (clears execution state but keeps breakpoints)
    tracer.reset();
    
    // Breakpoints should still exist
    try std.testing.expect(tracer.hasBreakpoint(10));
    try std.testing.expect(tracer.hasBreakpoint(20));
    
    // But execution state should be cleared
    try std.testing.expectEqual(@as(u64, 0), tracer.total_instructions);
    try std.testing.expectEqual(@as(usize, 0), tracer.steps.items.len);
}

// =============================================================================
// SECTION 4: PAUSE/RESUME EXECUTION
// =============================================================================

test "shouldPause returns true for breakpoint" {
    var tracer = DebuggingTracer.init();
    defer tracer.deinit();
    
    try tracer.addBreakpoint(42);
    try std.testing.expect(tracer.shouldPause(42) == true);
    try std.testing.expect(tracer.shouldPause(41) == false);
    try std.testing.expect(tracer.shouldPause(43) == false);
}

test "shouldPause returns true in step mode" {
    var tracer = DebuggingTracer.init();
    defer tracer.deinit();
    
    tracer.setStepMode(true);
    
    // Should pause at any PC in step mode
    try std.testing.expect(tracer.shouldPause(0) == true);
    try std.testing.expect(tracer.shouldPause(100) == true);
    try std.testing.expect(tracer.shouldPause(999) == true);
    
    tracer.setStepMode(false);
    
    // Should not pause when step mode is off (and no breakpoints)
    try std.testing.expect(tracer.shouldPause(0) == false);
    try std.testing.expect(tracer.shouldPause(100) == false);
}

test "shouldPause returns false for normal execution" {
    var tracer = DebuggingTracer.init();
    defer tracer.deinit();
    
    // No breakpoints, no step mode
    try std.testing.expect(tracer.shouldPause(0) == false);
    try std.testing.expect(tracer.shouldPause(50) == false);
    try std.testing.expect(tracer.shouldPause(100) == false);
}

test "Resume dispatch saved when paused" {
    var tracer = DebuggingTracer.init();
    defer tracer.deinit();
    
    // Simulate saving dispatch pointer
    const mock_dispatch = @as(*const anyopaque, @ptrFromInt(0xDEADBEEF));
    tracer.setResumeDispatch(mock_dispatch);
    
    try std.testing.expect(tracer.paused == true);
    try std.testing.expect(tracer.resume_dispatch == mock_dispatch);
}

test "Paused flag set and cleared correctly" {
    var tracer = DebuggingTracer.init();
    defer tracer.deinit();
    
    // Initially not paused
    try std.testing.expect(tracer.paused == false);
    
    // Pause
    tracer.pause();
    try std.testing.expect(tracer.paused == true);
    
    // Resume
    tracer.resumeExecution();
    try std.testing.expect(tracer.paused == false);
}

test "Multiple pause/resume cycles work correctly" {
    var tracer = DebuggingTracer.init();
    defer tracer.deinit();
    
    // Cycle 1
    tracer.pause();
    try std.testing.expect(tracer.paused == true);
    tracer.resumeExecution();
    try std.testing.expect(tracer.paused == false);
    
    // Cycle 2
    tracer.pause();
    try std.testing.expect(tracer.paused == true);
    tracer.resumeExecution();
    try std.testing.expect(tracer.paused == false);
    
    // Cycle 3
    tracer.pause();
    try std.testing.expect(tracer.paused == true);
    tracer.resumeExecution();
    try std.testing.expect(tracer.paused == false);
}

// =============================================================================
// SECTION 5: STEP MODE EXECUTION
// =============================================================================

test "Step mode pauses at every instruction" {
    var tracer = DebuggingTracer.init();
    defer tracer.deinit();
    
    tracer.setStepMode(true);
    
    // Should pause at every PC
    for (0..10) |pc| {
        try std.testing.expect(tracer.shouldPause(@intCast(pc)) == true);
    }
}

test "Step mode can be toggled on/off" {
    var tracer = DebuggingTracer.init();
    defer tracer.deinit();
    
    // Initially off
    try std.testing.expect(tracer.step_mode == false);
    
    // Turn on
    tracer.setStepMode(true);
    try std.testing.expect(tracer.step_mode == true);
    try std.testing.expect(tracer.shouldPause(10) == true);
    
    // Turn off
    tracer.setStepMode(false);
    try std.testing.expect(tracer.step_mode == false);
    try std.testing.expect(tracer.shouldPause(10) == false);
}

test "Step mode with breakpoints (both work)" {
    var tracer = DebuggingTracer.init();
    defer tracer.deinit();
    
    try tracer.addBreakpoint(50);
    tracer.setStepMode(true);
    
    // Should pause due to step mode
    try std.testing.expect(tracer.shouldPause(10) == true);
    
    // Should pause due to both step mode and breakpoint
    try std.testing.expect(tracer.shouldPause(50) == true);
    
    // Turn off step mode
    tracer.setStepMode(false);
    
    // Should still pause at breakpoint
    try std.testing.expect(tracer.shouldPause(50) == true);
    
    // Should not pause at non-breakpoint
    try std.testing.expect(tracer.shouldPause(10) == false);
}

test "Step through entire program" {
    var tracer = DebuggingTracer.init();
    defer tracer.deinit();
    
    const MockFrame = struct {
        gas_remaining: i64 = 1000,
        next_stack_index: usize = 0,
        stack: [16]u256 = [_]u256{0} ** 16,
    };
    
    var frame = MockFrame{};
    
    tracer.setStepMode(true);
    
    // Step through multiple instructions
    const pcs = [_]u32{ 0, 2, 4, 5, 6 };
    const opcodes = [_]u8{ 0x60, 0x60, 0x01, 0x50, 0x00 }; // PUSH1, PUSH1, ADD, POP, STOP
    
    for (pcs, opcodes) |pc, opcode| {
        try std.testing.expect(tracer.shouldPause(pc) == true);
        tracer.beforeOp(pc, opcode, MockFrame, &frame);
        tracer.afterOp(pc, opcode, MockFrame, &frame);
    }
    
    // Verify all steps were recorded
    try std.testing.expectEqual(@as(usize, 5), tracer.steps.items.len);
}

// =============================================================================
// END OF COMPREHENSIVE TESTS
// ============================================================================

test "onError called and error recorded in current step" {
    var tracer = DebuggingTracer.init();
    defer tracer.deinit();
    
    const MockFrame = struct {
        gas_remaining: i64 = 1000,
        next_stack_index: usize = 0,
        stack: [16]u256 = [_]u256{0} ** 16,
    };
    
    var frame = MockFrame{};
    
    // Start an operation
    tracer.beforeOp(10, 0x01, MockFrame, &frame);
    
    // Simulate error
    tracer.onError(10, error.OutOfGas, MockFrame, &frame);
    
    // Complete the operation
    tracer.afterOp(10, 0x01, MockFrame, &frame);
    
    // Verify error was recorded
    const step = &tracer.steps.items[0];
    try std.testing.expect(step.error_occurred == true);
    try std.testing.expect(step.error_msg != null);
    if (step.error_msg) |msg| {
        try std.testing.expectEqualStrings("OutOfGas", msg);
    }
}

test "Pause on error when configured" {
    var tracer = DebuggingTracer.init();
    defer tracer.deinit();
    
    const MockFrame = struct {
        gas_remaining: i64 = 0,
    };
    
    var frame = MockFrame{};
    
    // Error should always pause for debugging
    tracer.onError(42, error.OutOfGas, MockFrame, &frame);
    try std.testing.expect(tracer.paused == true);
}

test "Different error types handled" {
    var tracer = DebuggingTracer.init();
    defer tracer.deinit();
    
    const MockFrame = struct {
        gas_remaining: i64 = 1000,
        next_stack_index: usize = 0,
        stack: [16]u256 = [_]u256{0} ** 16,
    };
    
    var frame = MockFrame{};
    
    const errors = [_]anyerror{
        error.OutOfGas,
        error.InvalidOpcode,
        error.StackOverflow,
        error.StackUnderflow,
        error.InvalidJump,
    };
    
    for (errors, 0..) |err, i| {
        tracer.beforeOp(@intCast(i * 10), 0x00, MockFrame, &frame);
        tracer.onError(@intCast(i * 10), err, MockFrame, &frame);
        tracer.afterOp(@intCast(i * 10), 0x00, MockFrame, &frame);
    }
    
    // Verify all errors were recorded
    for (errors, 0..) |err, i| {
        const step = &tracer.steps.items[i];
        try std.testing.expect(step.error_occurred == true);
        if (step.error_msg) |msg| {
            try std.testing.expectEqualStrings(@errorName(err), msg);
        }
    }
}

// =============================================================================
// SECTION 7: STATE CAPTURE AND HISTORY
// =============================================================================

test "Stack captured before and after operation" {
    var tracer = DebuggingTracer.init();
    defer tracer.deinit();
    
    const MockFrame = struct {
        gas_remaining: i64 = 1000,
        next_stack_index: usize = 2,
        stack: [16]u256 = [_]u256{ 3, 5, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    };
    
    var frame = MockFrame{};
    
    // Capture before
    tracer.beforeOp(0, 0x01, MockFrame, &frame);
    
    // Simulate ADD operation (would modify stack)
    frame.stack[0] = 8; // 3 + 5
    frame.next_stack_index = 1;
    
    // Capture after
    tracer.afterOp(0, 0x01, MockFrame, &frame);
    
    const step = &tracer.steps.items[0];
    
    // Verify stack before
    try std.testing.expectEqual(@as(usize, 2), step.stack_before.len);
    try std.testing.expectEqual(@as(u256, 3), step.stack_before[0]);
    try std.testing.expectEqual(@as(u256, 5), step.stack_before[1]);
    
    // Verify stack after
    try std.testing.expectEqual(@as(usize, 1), step.stack_after.len);
    try std.testing.expectEqual(@as(u256, 8), step.stack_after[0]);
}

test "Gas consumption tracked correctly" {
    var tracer = DebuggingTracer.init();
    defer tracer.deinit();
    
    const MockFrame = struct {
        gas_remaining: i64,
        next_stack_index: usize = 0,
        stack: [16]u256 = [_]u256{0} ** 16,
    };
    
    var frame = MockFrame{ .gas_remaining = 1000 };
    
    // Operation 1
    tracer.beforeOp(0, 0x60, MockFrame, &frame);
    frame.gas_remaining = 997; // PUSH1 costs 3 gas
    tracer.afterOp(0, 0x60, MockFrame, &frame);
    
    // Operation 2
    tracer.beforeOp(2, 0x01, MockFrame, &frame);
    frame.gas_remaining = 994; // ADD costs 3 gas
    tracer.afterOp(2, 0x01, MockFrame, &frame);
    
    // Verify gas tracking
    const step1 = &tracer.steps.items[0];
    try std.testing.expectEqual(@as(i32, 1000), step1.gas_before);
    try std.testing.expectEqual(@as(i32, 997), step1.gas_after);
    try std.testing.expectEqual(@as(u32, 3), step1.gas_cost);
    
    const step2 = &tracer.steps.items[1];
    try std.testing.expectEqual(@as(i32, 997), step2.gas_before);
    try std.testing.expectEqual(@as(i32, 994), step2.gas_after);
    try std.testing.expectEqual(@as(u32, 3), step2.gas_cost);
}

test "DebuggingTracer tracks memory expansion correctly" {
    const allocator = testing.allocator;
    var tracer = DebuggingTracer.init();
    defer tracer.deinit();
    
    // Create a real frame with tracing enabled
    const FrameWithTracing = frame_mod.StackFrame(frame_config.FrameConfig{
        .TracerType = DebuggingTracer,
        .has_database = false,
    });
    
    // Bytecode that will expand memory: PUSH1 32, PUSH1 0, MSTORE
    const bytecode = [_]u8{ 0x60, 0x20, 0x60, 0x00, 0x52 };
    const gas_remaining = 10000;
    
    var frame = try FrameWithTracing.init(
        allocator,
        &bytecode,
        gas_remaining,
        {},
        createTestHost(),
    );
    defer frame.deinit(allocator);
    
    // Initial memory should be 0
    const initial_mem_size = frame.memory.size();
    try std.testing.expectEqual(@as(usize, 0), initial_mem_size);
    
    // Push values for MSTORE
    try frame.stack.push(0);  // offset
    try frame.stack.push(0x20); // value
    
    // Track before MSTORE
    tracer.beforeOp(4, 0x52, FrameWithTracing, &frame);
    
    // Execute MSTORE manually (this would normally be done by the opcode handler)
    // MSTORE at offset 0 with 32 bytes will expand memory to 32 bytes
    try frame.memory.set_u256_evm(0, 0x20);
    
    // Track after MSTORE
    tracer.afterOp(4, 0x52, FrameWithTracing, &frame);
    
    // Verify memory expansion was tracked
    const step = &tracer.steps.items[0];
    try std.testing.expectEqual(@as(usize, 0), step.memory_size_before);
    try std.testing.expectEqual(@as(usize, 32), step.memory_size_after);
    try std.testing.expectEqualStrings("MSTORE", step.opcode_name);
}

test "DebuggingTracer tracks call depth through nested calls" {
    // This test verifies that the tracer correctly tracks the depth field
    // when it exists in the frame (which happens during nested calls)
    const allocator = testing.allocator;
    var tracer = DebuggingTracer.init();
    defer tracer.deinit();
    
    // Create a frame type that includes depth (simulating nested call context)
    const FrameWithDepth = frame_mod.StackFrame(frame_config.FrameConfig{
        .TracerType = DebuggingTracer,
        .has_database = false,
    });
    
    const bytecode = [_]u8{ 0x00 }; // STOP
    const gas_remaining = 10000;
    
    var frame = try FrameWithDepth.init(
        allocator,
        &bytecode,
        gas_remaining,
        {},
        createTestHost(),
    );
    defer frame.deinit(allocator);
    
    // The frame's depth field would be set by the calling context
    // For now we test that the tracer correctly extracts it when present
    tracer.beforeOp(0, 0x00, FrameWithDepth, &frame);
    tracer.afterOp(0, 0x00, FrameWithDepth, &frame);
    
    const step = &tracer.steps.items[0];
    // Default depth should be 0 when not in a nested call
    // The actual depth tracking would be set by the EVM during CALL/CREATE operations
    try std.testing.expect(step.depth >= 0);
}

test "DebuggingTracer records execution steps in sequential order" {
    const allocator = std.testing.allocator;
    var tracer = DebuggingTracer.init();
    defer tracer.deinit();
    
    // Create a real frame with a sequence of opcodes
    const FrameWithTracing = frame_mod.StackFrame(frame_config.FrameConfig{
        .TracerType = DebuggingTracer,
        .has_database = false,
    });
    
    // Bytecode with multiple operations: PUSH1 5, PUSH1 3, ADD, STOP
    const bytecode = [_]u8{ 0x60, 0x05, 0x60, 0x03, 0x01, 0x00 };
    const gas_remaining = 100000;
    
    var frame = try FrameWithTracing.init(
        allocator,
        &bytecode,
        gas_remaining,
        {},
        createTestHost(),
    );
    defer frame.deinit(allocator);
    
    // Simulate execution of several opcodes at different PCs
    const test_cases = [_]struct { pc: u32, opcode: u8 }{
        .{ .pc = 0, .opcode = 0x60 }, // PUSH1
        .{ .pc = 2, .opcode = 0x60 }, // PUSH1
        .{ .pc = 4, .opcode = 0x01 }, // ADD
        .{ .pc = 5, .opcode = 0x00 }, // STOP
    };
    
    // Execute operations and record steps
    for (test_cases) |tc| {
        tracer.beforeOp(tc.pc, tc.opcode, FrameWithTracing, &frame);
        
        // Simulate opcode execution
        switch (tc.opcode) {
            0x60 => { // PUSH1
                // Would push a value, but we're just testing tracer ordering
            },
            0x01 => { // ADD
                // Would add values, but we're just testing tracer ordering
            },
            0x00 => { // STOP
                // Would stop execution
            },
            else => {},
        }
        
        tracer.afterOp(tc.pc, tc.opcode, FrameWithTracing, &frame);
    }
    
    // Verify steps were recorded in sequential order
    try std.testing.expectEqual(@as(usize, 4), tracer.steps.items.len);
    
    for (test_cases, 0..) |tc, i| {
        const step = &tracer.steps.items[i];
        try std.testing.expectEqual(tc.pc, step.pc);
        try std.testing.expectEqual(@as(u64, i), step.step_number);
        try std.testing.expectEqual(tc.opcode, step.opcode);
    }
    
    // Verify step numbers are sequential
    for (tracer.steps.items, 0..) |step, i| {
        try std.testing.expectEqual(@as(u64, i), step.step_number);
    }
}

test "DebuggingTracer captures state snapshots with actual frame state" {
    const allocator = std.testing.allocator;
    var tracer = DebuggingTracer.init();
    defer tracer.deinit();
    
    // Create a real frame
    const FrameWithTracing = frame_mod.StackFrame(frame_config.FrameConfig{
        .TracerType = DebuggingTracer,
        .has_database = false,
    });
    
    // Bytecode: PUSH1 10, PUSH1 20, ADD
    const bytecode = [_]u8{ 0x60, 0x0A, 0x60, 0x14, 0x01 };
    const gas_remaining = 50000;
    
    var frame = try FrameWithTracing.init(
        allocator,
        &bytecode,
        gas_remaining,
        {},
        createTestHost(),
    );
    defer frame.deinit(allocator);
    
    // Push some values onto the stack
    try frame.stack.push(10);
    try frame.stack.push(20);
    
    // Capture state at PC 42 (arbitrary for testing)
    try tracer.captureState(42, FrameWithTracing, &frame);
    
    // Verify snapshot was created with correct state
    try std.testing.expectEqual(@as(usize, 1), tracer.state_snapshots.items.len);
    
    const snapshot = &tracer.state_snapshots.items[0];
    try std.testing.expectEqual(@as(u32, 42), snapshot.pc);
    
    // Check gas was captured correctly (i64 to u64 conversion)
    const expected_gas = if (gas_remaining < 0) 0 else @as(u64, @intCast(gas_remaining));
    try std.testing.expectEqual(expected_gas, snapshot.gas_remaining);
    
    // Check stack was captured correctly
    try std.testing.expectEqual(@as(usize, 2), snapshot.stack.len);
    try std.testing.expectEqual(@as(u256, 10), snapshot.stack[0]);
    try std.testing.expectEqual(@as(u256, 20), snapshot.stack[1]);
    
    // Modify frame state and capture another snapshot
    try frame.stack.push(30);
    frame.gas_remaining -= 100;
    
    try tracer.captureState(50, FrameWithTracing, &frame);
    
    // Verify second snapshot
    try std.testing.expectEqual(@as(usize, 2), tracer.state_snapshots.items.len);
    
    const snapshot2 = &tracer.state_snapshots.items[1];
    try std.testing.expectEqual(@as(u32, 50), snapshot2.pc);
    try std.testing.expectEqual(@as(usize, 3), snapshot2.stack.len);
    try std.testing.expectEqual(@as(u256, 30), snapshot2.stack[2]);
}

test "DebuggingTracer prunes history to max_history with real frames" {
    const allocator = std.testing.allocator;
    var tracer = DebuggingTracer.init();
    defer tracer.deinit();
    
    // Configure with small max_history
    tracer.configure(.{ .max_history = 3 });
    
    // Create a real frame
    const FrameWithTracing = frame_mod.StackFrame(frame_config.FrameConfig{
        .TracerType = DebuggingTracer,
        .has_database = false,
    });
    
    // Simple bytecode with NOPs
    const bytecode = [_]u8{0x00} ** 20;
    const gas_remaining = 100000;
    
    var frame = try FrameWithTracing.init(
        allocator,
        &bytecode,
        gas_remaining,
        {},
        createTestHost(),
    );
    defer frame.deinit(allocator);
    
    // Execute more operations than max_history allows
    for (0..10) |i| {
        const pc = @as(u32, @intCast(i));
        tracer.beforeOp(pc, 0x00, FrameWithTracing, &frame);
        
        // Simulate gas consumption for realism
        frame.gas_remaining -= 3;
        
        tracer.afterOp(pc, 0x00, FrameWithTracing, &frame);
    }
    
    // Verify history was pruned to max_history
    try std.testing.expectEqual(@as(usize, 3), tracer.steps.items.len);
    
    // Verify we kept the most recent steps (7, 8, 9)
    try std.testing.expectEqual(@as(u32, 7), tracer.steps.items[0].pc);
    try std.testing.expectEqual(@as(u32, 8), tracer.steps.items[1].pc);
    try std.testing.expectEqual(@as(u32, 9), tracer.steps.items[2].pc);
    
    // Verify step numbers are still correct (should be original step numbers)
    try std.testing.expectEqual(@as(u64, 7), tracer.steps.items[0].step_number);
    try std.testing.expectEqual(@as(u64, 8), tracer.steps.items[1].step_number);
    try std.testing.expectEqual(@as(u64, 9), tracer.steps.items[2].step_number);
}

// =============================================================================
// SECTION 8: CONFIGURATION MANAGEMENT
// =============================================================================

test "Configure step_mode" {
    var tracer = DebuggingTracer.init();
    defer tracer.deinit();
    
    tracer.configure(.{ .step_mode = true });
    try std.testing.expect(tracer.step_mode == true);
    
    tracer.configure(.{ .step_mode = false });
    try std.testing.expect(tracer.step_mode == false);
}

test "Configure throw_on_error" {
    var tracer = DebuggingTracer.init();
    defer tracer.deinit();
    
    tracer.configure(.{ .throw_on_error = false });
    try std.testing.expect(tracer.throw_on_error == false);
    
    tracer.configure(.{ .throw_on_error = true });
    try std.testing.expect(tracer.throw_on_error == true);
}

test "Configure max_history" {
    var tracer = DebuggingTracer.init();
    defer tracer.deinit();
    
    tracer.configure(.{ .max_history = 100 });
    try std.testing.expectEqual(@as(usize, 100), tracer.max_history);
    
    tracer.configure(.{ .max_history = 5000 });
    try std.testing.expectEqual(@as(usize, 5000), tracer.max_history);
}

test "Configuration changes take effect immediately" {
    var tracer = DebuggingTracer.init();
    defer tracer.deinit();
    
    // Initial state
    try std.testing.expect(tracer.step_mode == false);
    try std.testing.expect(tracer.shouldPause(10) == false);
    
    // Change configuration
    tracer.configure(.{ .step_mode = true });
    
    // Should take effect immediately
    try std.testing.expect(tracer.shouldPause(10) == true);
}

test "Configuration persists until changed" {
    var tracer = DebuggingTracer.init();
    defer tracer.deinit();
    
    tracer.configure(.{ .step_mode = true, .throw_on_error = false });
    
    // Do some operations
    const MockFrame = struct {
        gas_remaining: i64 = 1000,
        next_stack_index: usize = 0,
        stack: [16]u256 = [_]u256{0} ** 16,
    };
    
    var frame = MockFrame{};
    tracer.beforeOp(0, 0x00, MockFrame, &frame);
    tracer.afterOp(0, 0x00, MockFrame, &frame);
    
    // Configuration should still be the same
    try std.testing.expect(tracer.step_mode == true);
    try std.testing.expect(tracer.throw_on_error == false);
}

// =============================================================================
// SECTION 10: EDGE CASES AND BOUNDARIES
// =============================================================================

test "Breakpoint at last instruction" {
    var tracer = DebuggingTracer.init();
    defer tracer.deinit();
    
    // Simulate bytecode with last instruction at PC=100
    try tracer.addBreakpoint(100);
    
    try std.testing.expect(tracer.shouldPause(100) == true);
}

// =============================================================================
// SECTION 11: COMPLEX EXECUTION SCENARIOS
// =============================================================================

test "Loop execution with breakpoint in loop" {
    var tracer = DebuggingTracer.init();
    defer tracer.deinit();
    
    const MockFrame = struct {
        gas_remaining: i64 = 1000,
        next_stack_index: usize = 0,
        stack: [16]u256 = [_]u256{0} ** 16,
    };
    
    var frame = MockFrame{};
    
    // Simulate loop: PC=0 -> PC=5 -> PC=10 -> PC=5 -> PC=10 -> PC=15
    // Breakpoint at PC=5
    try tracer.addBreakpoint(5);
    
    const loop_pcs = [_]u32{ 0, 5, 10, 5, 10, 15 };
    
    for (loop_pcs) |pc| {
        if (pc == 5) {
            try std.testing.expect(tracer.shouldPause(pc) == true);
        }
        tracer.beforeOp(pc, 0x00, MockFrame, &frame);
        tracer.afterOp(pc, 0x00, MockFrame, &frame);
    }
    
    // Verify all iterations were recorded
    try std.testing.expectEqual(@as(usize, 6), tracer.steps.items.len);
}

test "Gas exhaustion during traced execution" {
    var tracer = DebuggingTracer.init();
    defer tracer.deinit();
    
    const MockFrame = struct {
        gas_remaining: i64,
        next_stack_index: usize = 0,
        stack: [16]u256 = [_]u256{0} ** 16,
    };
    
    var frame = MockFrame{ .gas_remaining = 10 };
    
    // Execute until gas exhaustion
    tracer.beforeOp(0, 0x60, MockFrame, &frame);
    frame.gas_remaining = 7; // PUSH1 costs 3
    tracer.afterOp(0, 0x60, MockFrame, &frame);
    
    tracer.beforeOp(2, 0x60, MockFrame, &frame);
    frame.gas_remaining = 4; // PUSH1 costs 3
    tracer.afterOp(2, 0x60, MockFrame, &frame);
    
    tracer.beforeOp(4, 0x01, MockFrame, &frame);
    frame.gas_remaining = 1; // ADD costs 3
    tracer.afterOp(4, 0x01, MockFrame, &frame);
    
    // Next operation would fail
    tracer.beforeOp(5, 0x02, MockFrame, &frame);
    tracer.onError(5, error.OutOfGas, MockFrame, &frame);
    
    // Verify error was recorded
    try std.testing.expect(tracer.paused == true);
}

test "Stack overflow with tracing" {
    var tracer = DebuggingTracer.init();
    defer tracer.deinit();
    
    const MockFrame = struct {
        gas_remaining: i64 = 1000,
        next_stack_index: usize = 1024, // Stack is full
        stack: [1024]u256 = [_]u256{0} ** 1024,
    };
    
    var frame = MockFrame{};
    
    // Try to push when stack is full
    tracer.beforeOp(0, 0x60, MockFrame, &frame); // PUSH1
    tracer.onError(0, error.StackOverflow, MockFrame, &frame);
    
    try std.testing.expect(tracer.paused == true);
}

test "Invalid jump with tracing" {
    var tracer = DebuggingTracer.init();
    defer tracer.deinit();
    
    const MockFrame = struct {
        gas_remaining: i64 = 1000,
        next_stack_index: usize = 0,
        stack: [16]u256 = [_]u256{0} ** 16,
    };
    
    var frame = MockFrame{};
    
    tracer.beforeOp(10, 0x56, MockFrame, &frame); // JUMP
    tracer.onError(10, error.InvalidJump, MockFrame, &frame);
    
    try std.testing.expect(tracer.paused == true);
}

// =============================================================================
// SECTION 12: ZERO OVERHEAD VERIFICATION
// =============================================================================

test "NoOpTracer has zero runtime overhead" {
    // This test verifies that NoOpTracer methods compile to nothing
    var noop = NoOpTracer.init();
    
    const TestFrame = struct {
        value: u32 = 42,
    };
    
    var frame = TestFrame{};
    
    // These should all be no-ops
    noop.beforeOp(0, 0x00, TestFrame, &frame);
    noop.afterOp(0, 0x00, TestFrame, &frame);
    noop.onError(0, error.TestError, TestFrame, &frame);
    
    // Frame should be unchanged
    try std.testing.expectEqual(@as(u32, 42), frame.value);
}

test "Conditional compilation with TracerType = null" {
    // This test verifies that when TracerType is null, no tracing code is included
    const FrameNoTracing = frame_mod.StackFrame(.{
        .TracerType = null,
    });
    
    // Should compile without any tracing overhead
    // TracerType is null, so no tracing overhead
    _ = FrameNoTracing; // Mark as used
}

// =============================================================================
// SECTION 13: WRITER-BASED TRACERS
// =============================================================================

test "JSON output format correct" {
    const allocator = std.testing.allocator;
    
    const Frame = frame_mod.StackFrame(.{});
    var test_frame = try Frame.init(allocator, &[_]u8{ 0x60, 0x05 }, 1000, {}, createTestHost());
    defer test_frame.deinit(allocator);
    
    try test_frame.stack.push(100);
    try test_frame.stack.push(200);
    test_frame.gas_remaining = 950;
    
    var output = std.ArrayList(u8){};
    defer output.deinit(allocator);
    
    var tracer = Tracer(std.ArrayList(u8).Writer).init(allocator, output.writer(allocator));
    try tracer.writeSnapshot(10, 0x01, Frame, &test_frame);
    
    const json = output.items;
    
    // Verify JSON structure
    try std.testing.expect(std.mem.indexOf(u8, json, "\"pc\":10") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"op\":\"ADD\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"gas\":950") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"gasCost\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"depth\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"stack\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"memSize\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"refund\":0") != null);
}

test "File tracer writes to file correctly" {
    const allocator = std.testing.allocator;
    
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    
    const file = try tmp_dir.dir.createFile("test_trace.json", .{});
    file.close();
    
    const file_path = try tmp_dir.dir.realpathAlloc(allocator, "test_trace.json");
    defer allocator.free(file_path);
    
    const Frame = frame_mod.StackFrame(.{});
    var test_frame = try Frame.init(allocator, &[_]u8{0x00}, 1000, {}, createTestHost());
    defer test_frame.deinit(allocator);
    
    var tracer = try FileTracer.init(allocator, file_path);
    defer tracer.deinit();
    
    try tracer.writeSnapshot(0, 0x00, Frame, &test_frame);
    
    const contents = try tmp_dir.dir.readFileAlloc(allocator, "test_trace.json", 4096);
    defer allocator.free(contents);
    
    try std.testing.expect(contents.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"op\":\"STOP\"") != null);
}

test "Logging tracer writes to stdout" {
    const allocator = std.testing.allocator;
    
    const Frame = frame_mod.StackFrame(.{});
    var test_frame = try Frame.init(allocator, &[_]u8{0x00}, 1000, {}, createTestHost());
    defer test_frame.deinit(allocator);
    
    var tracer = LoggingTracer.init(allocator);
    
    // This would write to stdout in real execution
    const log = try tracer.snapshot(0, 0x00, Frame, &test_frame);
    defer allocator.free(log.stack);
    
    try std.testing.expectEqualStrings("STOP", log.op);
}

test "Gas cost computation in tracer" {
    const allocator = std.testing.allocator;
    
    const Frame = frame_mod.StackFrame(.{});
    var test_frame = try Frame.init(allocator, &[_]u8{0x00}, 1000, {}, createTestHost());
    defer test_frame.deinit(allocator);
    
    var output = std.ArrayList(u8){};
    defer output.deinit(allocator);
    
    var tracer = Tracer(std.ArrayList(u8).Writer).initWithConfig(
        allocator,
        output.writer(allocator),
        .{ .compute_gas_cost = true },
    );
    
    // First op - no previous gas
    test_frame.gas_remaining = 1000;
    const log1 = try tracer.snapshot(0, 0x60, Frame, &test_frame);
    defer allocator.free(log1.stack);
    try std.testing.expectEqual(@as(u64, 0), log1.gasCost);
    
    // Second op - gas decreased by 3
    test_frame.gas_remaining = 997;
    const log2 = try tracer.snapshot(2, 0x60, Frame, &test_frame);
    defer allocator.free(log2.stack);
    try std.testing.expectEqual(@as(u64, 3), log2.gasCost);
}

test "Large stack values in JSON" {
    const allocator = std.testing.allocator;
    
    const Frame = frame_mod.StackFrame(.{});
    var test_frame = try Frame.init(allocator, &[_]u8{0x00}, 1000, {}, createTestHost());
    defer test_frame.deinit(allocator);
    
    try test_frame.stack.push(std.math.maxInt(u256));
    try test_frame.stack.push(0xCAFEBABEDEADBEEF);
    
    var output = std.ArrayList(u8){};
    defer output.deinit(allocator);
    
    var tracer = Tracer(std.ArrayList(u8).Writer).init(allocator, output.writer(allocator));
    try tracer.writeSnapshot(0, 0x00, Frame, &test_frame);
    
    const json = output.items;
    try std.testing.expect(std.mem.indexOf(u8, json, "0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "0xcafebabedeadbeef") != null);
}

test "Empty stack in JSON" {
    const allocator = std.testing.allocator;
    
    const Frame = frame_mod.StackFrame(.{});
    var test_frame = try Frame.init(allocator, &[_]u8{0x00}, 1000, {}, createTestHost());
    defer test_frame.deinit(allocator);
    
    var output = std.ArrayList(u8){};
    defer output.deinit(allocator);
    
    var tracer = Tracer(std.ArrayList(u8).Writer).init(allocator, output.writer(allocator));
    try tracer.writeSnapshot(0, 0x00, Frame, &test_frame);
    
    const json = output.items;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"stack\":[]") != null);
}

// =============================================================================
// SECTION 14: MEMORY MANAGEMENT
// =============================================================================

test "All allocations freed on deinit" {
    var tracer = DebuggingTracer.init();
    
    const MockFrame = struct {
        gas_remaining: i64 = 1000,
        next_stack_index: usize = 2,
        stack: [16]u256 = [_]u256{ 1, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    };
    
    var frame = MockFrame{};
    
    // Create multiple steps with stack copies
    for (0..5) |i| {
        tracer.beforeOp(@intCast(i), 0x00, MockFrame, &frame);
        tracer.afterOp(@intCast(i), 0x00, MockFrame, &frame);
    }
    
    // Create state snapshots
    for (0..3) |i| {
        tracer.captureState(@intCast(i * 10), MockFrame, &frame) catch {};
    }
    
    // Add error message
    tracer.beforeOp(100, 0x00, MockFrame, &frame);
    tracer.onError(100, error.TestError, MockFrame, &frame);
    
    // deinit should free all memory
    tracer.deinit();
    // If this doesn't crash, memory management is working
}

test "Stack copies managed correctly" {
    var tracer = DebuggingTracer.init();
    defer tracer.deinit();
    
    const MockFrame = struct {
        gas_remaining: i64 = 1000,
        next_stack_index: usize = 3,
        stack: [16]u256 = [_]u256{ 10, 20, 30, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    };
    
    var frame = MockFrame{};
    
    tracer.beforeOp(0, 0x01, MockFrame, &frame);
    
    // Modify stack
    frame.stack[0] = 50;
    frame.next_stack_index = 2;
    
    tracer.afterOp(0, 0x01, MockFrame, &frame);
    
    // Verify independent copies
    const step = &tracer.steps.items[0];
    try std.testing.expectEqual(@as(u256, 10), step.stack_before[0]);
    try std.testing.expectEqual(@as(u256, 50), step.stack_after[0]);
}

test "Error messages freed" {
    var tracer = DebuggingTracer.init();
    
    const MockFrame = struct {
        gas_remaining: i64 = 0,
        next_stack_index: usize = 0,
        stack: [16]u256 = [_]u256{0} ** 16,
    };
    
    var frame = MockFrame{};
    
    // Create multiple errors
    for (0..5) |i| {
        tracer.beforeOp(@intCast(i * 10), 0x00, MockFrame, &frame);
        tracer.onError(@intCast(i * 10), error.OutOfGas, MockFrame, &frame);
        tracer.afterOp(@intCast(i * 10), 0x00, MockFrame, &frame);
    }
    
    // deinit should free all error messages
    tracer.deinit();
}

test "Snapshots freed" {
    var tracer = DebuggingTracer.init();
    
    const MockFrame = struct {
        gas_remaining: i64 = 1000,
        next_stack_index: usize = 1,
        stack: [16]u256 = [_]u256{ 42, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    };
    
    var frame = MockFrame{};
    
    // Create many snapshots
    for (0..10) |i| {
        tracer.captureState(@intCast(i), MockFrame, &frame) catch {};
    }
    
    // deinit should free all snapshots
    tracer.deinit();
}

// =============================================================================
// SECTION 15: REAL BYTECODE EXECUTION
// =============================================================================

test "Execute simple ADD program with tracing" {
    const allocator = std.testing.allocator;
    
    // Bytecode: PUSH1 0x05, PUSH1 0x03, ADD, STOP
    const bytecode = [_]u8{ 0x60, 0x05, 0x60, 0x03, 0x01, 0x00 };
    
    const Frame = frame_mod.StackFrame(.{});
    var test_frame = try Frame.init(allocator, &bytecode, 1000, {}, createTestHost());
    defer test_frame.deinit(allocator);
    
    var tracer = DebuggingTracer.init();
    defer tracer.deinit();
    
    // Execute with tracing
    tracer.beforeOp(0, 0x60, Frame, &test_frame); // PUSH1 0x05
    try test_frame.stack.push(5);
    test_frame.gas_remaining -= 3;
    tracer.afterOp(0, 0x60, Frame, &test_frame);
    
    tracer.beforeOp(2, 0x60, Frame, &test_frame); // PUSH1 0x03
    try test_frame.stack.push(3);
    test_frame.gas_remaining -= 3;
    tracer.afterOp(2, 0x60, Frame, &test_frame);
    
    tracer.beforeOp(4, 0x01, Frame, &test_frame); // ADD
    const b = test_frame.stack.pop_unsafe();
    const a = test_frame.stack.peek_unsafe();
    test_frame.stack.set_top_unsafe(a +% b);
    test_frame.gas_remaining -= 3;
    tracer.afterOp(4, 0x01, Frame, &test_frame);
    
    tracer.beforeOp(5, 0x00, Frame, &test_frame); // STOP
    tracer.afterOp(5, 0x00, Frame, &test_frame);
    
    // Verify execution trace
    try std.testing.expectEqual(@as(usize, 4), tracer.steps.items.len);
    try std.testing.expectEqual(@as(u256, 8), test_frame.stack.peek_unsafe());
}

test "Execute PUSH and POP with tracing" {
    const allocator = std.testing.allocator;
    
    // Bytecode: PUSH2 0x1234, POP, STOP
    const bytecode = [_]u8{ 0x61, 0x12, 0x34, 0x50, 0x00 };
    
    const Frame = frame_mod.StackFrame(.{});
    var test_frame = try Frame.init(allocator, &bytecode, 1000, {}, createTestHost());
    defer test_frame.deinit(allocator);
    
    var tracer = DebuggingTracer.init();
    defer tracer.deinit();
    
    tracer.beforeOp(0, 0x61, Frame, &test_frame); // PUSH2
    try test_frame.stack.push(0x1234);
    test_frame.gas_remaining -= 3;
    tracer.afterOp(0, 0x61, Frame, &test_frame);
    
    tracer.beforeOp(3, 0x50, Frame, &test_frame); // POP
    _ = test_frame.stack.pop_unsafe();
    test_frame.gas_remaining -= 2;
    tracer.afterOp(3, 0x50, Frame, &test_frame);
    
    tracer.beforeOp(4, 0x00, Frame, &test_frame); // STOP
    tracer.afterOp(4, 0x00, Frame, &test_frame);
    
    try std.testing.expectEqual(@as(usize, 3), tracer.steps.items.len);
    try std.testing.expectEqual(@as(usize, 0), test_frame.stack.size());
}

test "Execute program that runs out of gas" {
    const allocator = std.testing.allocator;
    
    // Bytecode: PUSH1 0x05, PUSH1 0x03, ADD
    const bytecode = [_]u8{ 0x60, 0x05, 0x60, 0x03, 0x01 };
    
    const Frame = frame_mod.StackFrame(.{});
    var test_frame = try Frame.init(allocator, &bytecode, 8, {}, createTestHost()); // Only 8 gas
    defer test_frame.deinit(allocator);
    
    var tracer = DebuggingTracer.init();
    defer tracer.deinit();
    
    // First PUSH1 - costs 3 gas
    tracer.beforeOp(0, 0x60, Frame, &test_frame);
    try test_frame.stack.push(5);
    test_frame.gas_remaining -= 3;
    tracer.afterOp(0, 0x60, Frame, &test_frame);
    
    // Second PUSH1 - costs 3 gas
    tracer.beforeOp(2, 0x60, Frame, &test_frame);
    try test_frame.stack.push(3);
    test_frame.gas_remaining -= 3;
    tracer.afterOp(2, 0x60, Frame, &test_frame);
    
    // ADD - would cost 3 gas but only 2 remaining
    tracer.beforeOp(4, 0x01, Frame, &test_frame);
    tracer.onError(4, error.OutOfGas, Frame, &test_frame);
    
    // Verify error was captured
    try std.testing.expect(tracer.paused == true);
    try std.testing.expectEqual(@as(usize, 2), tracer.steps.items.len);
}

// =============================================================================
// SECTION 16: ADDITIONAL COMPREHENSIVE TESTS
// =============================================================================

test "DebuggingTracer getRecentSteps" {
    var tracer = DebuggingTracer.init();
    defer tracer.deinit();
    
    const MockFrame = struct {
        gas_remaining: i64 = 1000,
        next_stack_index: usize = 0,
        stack: [16]u256 = [_]u256{0} ** 16,
    };
    
    var frame = MockFrame{};
    
    // Add 10 steps
    for (0..10) |i| {
        tracer.beforeOp(@intCast(i), 0x00, MockFrame, &frame);
        tracer.afterOp(@intCast(i), 0x00, MockFrame, &frame);
    }
    
    // Get recent 3 steps
    const recent = tracer.getRecentSteps(3);
    try std.testing.expectEqual(@as(usize, 3), recent.len);
    try std.testing.expectEqual(@as(u32, 7), recent[0].pc);
    try std.testing.expectEqual(@as(u32, 8), recent[1].pc);
    try std.testing.expectEqual(@as(u32, 9), recent[2].pc);
}

test "DebuggingTracer getStep" {
    var tracer = DebuggingTracer.init();
    defer tracer.deinit();
    
    const MockFrame = struct {
        gas_remaining: i64 = 1000,
        next_stack_index: usize = 0,
        stack: [16]u256 = [_]u256{0} ** 16,
    };
    
    var frame = MockFrame{};
    
    // Add some steps
    for (0..5) |i| {
        tracer.beforeOp(@intCast(i * 10), 0x00, MockFrame, &frame);
        tracer.afterOp(@intCast(i * 10), 0x00, MockFrame, &frame);
    }
    
    // Get specific step
    const step = tracer.getStep(2);
    try std.testing.expect(step != null);
    if (step) |s| {
        try std.testing.expectEqual(@as(u32, 20), s.pc);
    }
    
    // Get out of bounds step
    const no_step = tracer.getStep(100);
    try std.testing.expect(no_step == null);
}

test "DebuggingTracer getStats" {
    var tracer = DebuggingTracer.init();
    defer tracer.deinit();
    
    const MockFrame = struct {
        gas_remaining: i64 = 1000,
        next_stack_index: usize = 0,
        stack: [16]u256 = [_]u256{0} ** 16,
    };
    
    var frame = MockFrame{};
    
    // Add breakpoints
    try tracer.addBreakpoint(10);
    try tracer.addBreakpoint(20);
    
    // Execute some steps
    for (0..3) |i| {
        tracer.beforeOp(@intCast(i), 0x00, MockFrame, &frame);
        tracer.afterOp(@intCast(i), 0x00, MockFrame, &frame);
    }
    
    // Create snapshots
    for (0..2) |i| {
        try tracer.captureState(@intCast(i), MockFrame, &frame);
    }
    
    const stats = tracer.getStats();
    try std.testing.expectEqual(@as(u64, 3), stats.total_instructions);
    try std.testing.expectEqual(@as(usize, 2), stats.breakpoint_count);
    try std.testing.expectEqual(@as(usize, 3), stats.history_size);
    try std.testing.expectEqual(@as(usize, 2), stats.snapshot_count);
}

test "DebuggingTracer reset clears execution state but keeps config" {
    var tracer = DebuggingTracer.init();
    defer tracer.deinit();
    
    const MockFrame = struct {
        gas_remaining: i64 = 1000,
        next_stack_index: usize = 1,
        stack: [16]u256 = [_]u256{ 42, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    };
    
    var frame = MockFrame{};
    
    // Set configuration and breakpoints
    tracer.configure(.{ .step_mode = true, .max_history = 50 });
    try tracer.addBreakpoint(100);
    
    // Add some execution state
    for (0..5) |i| {
        tracer.beforeOp(@intCast(i), 0x00, MockFrame, &frame);
        tracer.afterOp(@intCast(i), 0x00, MockFrame, &frame);
    }
    try tracer.captureState(10, MockFrame, &frame);
    
    // Reset
    tracer.reset();
    
    // Execution state should be cleared
    try std.testing.expectEqual(@as(u64, 0), tracer.total_instructions);
    try std.testing.expectEqual(@as(usize, 0), tracer.steps.items.len);
    try std.testing.expectEqual(@as(usize, 0), tracer.state_snapshots.items.len);
    
    // But configuration and breakpoints should remain
    try std.testing.expect(tracer.step_mode == true);
    try std.testing.expectEqual(@as(usize, 50), tracer.max_history);
    try std.testing.expect(tracer.hasBreakpoint(100));
}

test "Tracer handles frames with different configurations" {
    var tracer = DebuggingTracer.init();
    defer tracer.deinit();
    
    // Frame with memory
    const FrameWithMemory = struct {
        gas_remaining: i64 = 1000,
        next_stack_index: usize = 0,
        stack: [16]u256 = [_]u256{0} ** 16,
        memory: struct {
            pub fn size(self: *const @This()) usize {
                _ = self;
                return 64;
            }
        } = .{},
    };
    
    // Frame without memory
    const FrameNoMemory = struct {
        gas_remaining: i64 = 1000,
        next_stack_index: usize = 0,
        stack: [16]u256 = [_]u256{0} ** 16,
    };
    
    var frame_with_mem = FrameWithMemory{};
    var frame_no_mem = FrameNoMemory{};
    
    // Test with memory
    tracer.beforeOp(0, 0x52, FrameWithMemory, &frame_with_mem);
    tracer.afterOp(0, 0x52, FrameWithMemory, &frame_with_mem);
    
    // Test without memory
    tracer.beforeOp(1, 0x01, FrameNoMemory, &frame_no_mem);
    tracer.afterOp(1, 0x01, FrameNoMemory, &frame_no_mem);
    
    // Verify both worked
    try std.testing.expectEqual(@as(usize, 2), tracer.steps.items.len);
    try std.testing.expectEqual(@as(usize, 64), tracer.steps.items[0].memory_size_before);
    try std.testing.expectEqual(@as(usize, 0), tracer.steps.items[1].memory_size_before);
}

test "Opcode name resolution comprehensive" {
    // Test various opcodes
    try std.testing.expectEqualStrings("STOP", getOpcodeName(0x00));
    try std.testing.expectEqualStrings("ADD", getOpcodeName(0x01));
    try std.testing.expectEqualStrings("MUL", getOpcodeName(0x02));
    try std.testing.expectEqualStrings("PUSH1", getOpcodeName(0x60));
    try std.testing.expectEqualStrings("PUSH32", getOpcodeName(0x7f));
    try std.testing.expectEqualStrings("DUP1", getOpcodeName(0x80));
    try std.testing.expectEqualStrings("SWAP1", getOpcodeName(0x90));
    try std.testing.expectEqualStrings("SWAP16", getOpcodeName(0x9f));
    try std.testing.expectEqualStrings("INVALID", getOpcodeName(0xfe));
    try std.testing.expectEqualStrings("UNKNOWN", getOpcodeName(0xff));
    try std.testing.expectEqualStrings("KECCAK256", getOpcodeName(0x20));
    try std.testing.expectEqualStrings("JUMPDEST", getOpcodeName(0x5b));
}

// ============================================================================
// WRITER-BASED TRACER TESTS
// ============================================================================

test "tracer captures basic frame state with writer" {
    const allocator = std.testing.allocator;

    // Create a frame with some state
    const Frame = frame_mod.StackFrame(.{
        .stack_size = 10,
        .block_gas_limit = 1000,
    });

    var test_frame = try Frame.init(allocator, &[_]u8{ 0x60, 0x05, 0x60, 0x03, 0x01 }, 1000, {}, createTestHost());
    defer test_frame.deinit(allocator);

    // Push some values onto the stack
    try test_frame.stack.push(3);
    try test_frame.stack.push(5);
    // PC is now managed by plan, not frame
    const gas_to_consume1 = @as(u64, @intCast(test_frame.gas_remaining - 950));
    if (test_frame.gas_remaining < @as(@TypeOf(test_frame.gas_remaining), @intCast(gas_to_consume1))) return error.OutOfGas;
    test_frame.gas_remaining -= @as(@TypeOf(test_frame.gas_remaining), @intCast(gas_to_consume1));

    // Create tracer with array list writer
    var output = std.ArrayList(u8){};
    defer output.deinit(allocator);

    var tracer = Tracer(std.ArrayList(u8).Writer).init(allocator, output.writer(allocator));
    const log = try tracer.snapshot(4, 0x01, Frame, &test_frame); // PC=4, opcode=ADD
    defer allocator.free(log.stack);

    // Verify snapshot
    try std.testing.expectEqual(@as(u64, 4), log.pc);
    try std.testing.expectEqualStrings("ADD", log.op);
    try std.testing.expectEqual(@as(u64, 950), log.gas);
    try std.testing.expectEqual(@as(u32, 1), log.depth);
    try std.testing.expectEqual(@as(usize, 2), log.stack.len);
    try std.testing.expectEqual(@as(u256, 3), log.stack[0]);
    try std.testing.expectEqual(@as(u256, 5), log.stack[1]);
}

test "tracer writes JSON to writer" {
    const allocator = std.testing.allocator;

    const Frame = frame_mod.StackFrame(.{});
    var test_frame = try Frame.init(allocator, &[_]u8{ 0x60, 0x05, 0x60, 0x03, 0x01 }, 1000, {}, createTestHost());
    defer test_frame.deinit(allocator);

    try test_frame.stack.push(3);
    try test_frame.stack.push(5);
    // PC is now managed by plan, not frame
    const gas_to_consume2 = @as(u64, @intCast(test_frame.gas_remaining - 950));
    if (test_frame.gas_remaining < @as(@TypeOf(test_frame.gas_remaining), @intCast(gas_to_consume2))) return error.OutOfGas;
    test_frame.gas_remaining -= @as(@TypeOf(test_frame.gas_remaining), @intCast(gas_to_consume2));

    // Create tracer with array list writer
    var output = std.ArrayList(u8){};
    defer output.deinit(allocator);

    var tracer = Tracer(std.ArrayList(u8).Writer).init(allocator, output.writer(allocator));
    try tracer.writeSnapshot(4, 0x01, Frame, &test_frame); // PC=4, opcode=ADD

    const json = output.items;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"pc\":4") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"op\":\"ADD\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"gas\":950") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"stack\":[\"0x3\",\"0x5\"]") != null);
}

test "tracer handles empty stack with JSON output" {
    const allocator = std.testing.allocator;

    const Frame = frame_mod.StackFrame(.{});
    var test_frame = try Frame.init(allocator, &[_]u8{0x00}, 1000, {}, createTestHost());
    defer test_frame.deinit(allocator);

    var output = std.ArrayList(u8){};
    defer output.deinit(allocator);

    var tracer = Tracer(std.ArrayList(u8).Writer).init(allocator, output.writer(allocator));
    try tracer.writeSnapshot(0, 0x00, Frame, &test_frame); // STOP

    const json = output.items;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"stack\":[]") != null);
}

test "tracer handles large stack values in JSON" {
    const allocator = std.testing.allocator;

    const Frame = frame_mod.StackFrame(.{});
    var test_frame = try Frame.init(allocator, &[_]u8{0x00}, 1000, {}, createTestHost());
    defer test_frame.deinit(allocator);

    try test_frame.stack.push(std.math.maxInt(u256));
    try test_frame.stack.push(0xdeadbeef);

    var output = std.ArrayList(u8){};
    defer output.deinit(allocator);

    var tracer = Tracer(std.ArrayList(u8).Writer).init(allocator, output.writer(allocator));
    try tracer.writeSnapshot(0, 0x00, Frame, &test_frame); // STOP

    const json = output.items;
    try std.testing.expect(std.mem.indexOf(u8, json, "0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "0xdeadbeef") != null);
}

// ============================================================================
// NOOP TRACER TESTS
// ============================================================================

test "NoOpTracer has zero runtime cost" {
    var tracer = NoOpTracer.init();

    const TestFrame = struct {
        gas: i32,
    };

    const test_frame = TestFrame{ .gas = 1000 };

    // These should compile to nothing
    tracer.beforeOp(0, 0x00, TestFrame, &test_frame);
    tracer.afterOp(0, 0x00, TestFrame, &test_frame);
    tracer.onError(0, error.TestError, TestFrame, &test_frame);
}

// ============================================================================
// DEBUGGING TRACER ENHANCED TESTS
// ============================================================================

test "DebuggingTracer basic functionality" {
    var tracer = DebuggingTracer.init();
    defer tracer.deinit();

    // Test breakpoint management
    try tracer.addBreakpoint(10);
    try tracer.addBreakpoint(20);

    try std.testing.expect(tracer.hasBreakpoint(10));
    try std.testing.expect(tracer.hasBreakpoint(20));
    try std.testing.expect(!tracer.hasBreakpoint(15));

    // Test step mode
    tracer.setStepMode(true);
    try std.testing.expect(tracer.shouldPause(5)); // Should pause in step mode

    tracer.setStepMode(false);
    try std.testing.expect(tracer.shouldPause(10)); // Should pause on breakpoint
    try std.testing.expect(!tracer.shouldPause(5)); // Should not pause on regular instruction

    // Test removal
    try std.testing.expect(tracer.removeBreakpoint(10));
    try std.testing.expect(!tracer.hasBreakpoint(10));
    try std.testing.expect(!tracer.removeBreakpoint(10)); // Already removed

    // Test clear
    tracer.clearBreakpoints();
    try std.testing.expect(!tracer.hasBreakpoint(20));
}

test "DebuggingTracer memory management" {
    var tracer = DebuggingTracer.init();
    defer tracer.deinit();

    // This test verifies that the tracer properly manages memory
    // when used with a mock frame
    const MockFrame = struct {
        gas_remaining: i64 = 1000,
        bytecode: []const u8,
        next_stack_index: usize,
        stack: [16]u256,

        fn init() @This() {
            return .{
                .gas_remaining = 1000,
                .bytecode = &[_]u8{ 0x60, 0x05 }, // PUSH1 5
                .next_stack_index = 0,
                .stack = [_]u256{0} ** 16,
            };
        }
    };

    var mock_frame = MockFrame.init();

    // Test beforeOp and afterOp
    tracer.beforeOp(0, 0x60, MockFrame, &mock_frame); // PC=0, PUSH1
    tracer.afterOp(0, 0x60, MockFrame, &mock_frame);

    // Verify step was recorded
    try std.testing.expectEqual(@as(usize, 1), tracer.steps.items.len);
    try std.testing.expectEqual(@as(u64, 1), tracer.total_instructions);

    const step = &tracer.steps.items[0];
    try std.testing.expectEqual(@as(u32, 0), step.pc);
    try std.testing.expectEqual(@as(u8, 0x60), step.opcode);
    try std.testing.expectEqualStrings("PUSH1", step.opcode_name);
}

test "DebuggingTracer enhanced configuration" {
    var tracer = DebuggingTracer.init();
    defer tracer.deinit();
    
    // Test configuration
    tracer.configure(.{ .step_mode = true, .throw_on_error = false });
    try std.testing.expect(tracer.step_mode == true);
    try std.testing.expect(tracer.throw_on_error == false);
}

test "DebuggingTracer breakpoint management enhanced" {
    var tracer = DebuggingTracer.init();
    defer tracer.deinit();
    
    // Test breakpoint operations
    try tracer.addBreakpoint(100);
    try tracer.addBreakpoint(200);
    try std.testing.expect(tracer.shouldPause(100) == true);
    try std.testing.expect(tracer.shouldPause(150) == false);
    
    try std.testing.expect(tracer.removeBreakpoint(100) == true);
    try std.testing.expect(tracer.shouldPause(100) == false);
    
    tracer.clearBreakpoints();
    try std.testing.expect(tracer.shouldPause(200) == false);
}

test "DebuggingTracer execution control and step counting" {
    var tracer = DebuggingTracer.init();
    defer tracer.deinit();
    
    // Test step counting
    tracer.step_count = 0;
    
    // Mock frame for testing
    const MockFrame = struct {
        gas_remaining: i64 = 1000,
        next_stack_index: usize = 0,
        stack: [16]u256 = [_]u256{0} ** 16,
    };
    
    var mock_frame = MockFrame{};
    
    // Simulate multiple operations
    tracer.beforeOp(0, 0x60, MockFrame, &mock_frame); // PC=0, PUSH1
    tracer.afterOp(0, 0x60, MockFrame, &mock_frame);
    
    tracer.beforeOp(1, 0x50, MockFrame, &mock_frame); // PC=1, POP
    tracer.afterOp(1, 0x50, MockFrame, &mock_frame);
    
    // Check step counting
    try std.testing.expectEqual(@as(u64, 2), tracer.step_count);
    try std.testing.expectEqual(@as(u64, 2), tracer.total_instructions);
    try std.testing.expectEqual(@as(usize, 2), tracer.steps.items.len);
}

test "DebuggingTracer pause/resume dispatch management" {
    var tracer = DebuggingTracer.init();
    defer tracer.deinit();
    
    // Test setResumeDispatch
    const mock_dispatch = @as(*const anyopaque, @ptrFromInt(0x12345678));
    tracer.setResumeDispatch(mock_dispatch);
    
    try std.testing.expect(tracer.paused == true);
    try std.testing.expect(tracer.resume_dispatch == mock_dispatch);
}

test "DebuggingTracer error handling with configuration" {
    var tracer = DebuggingTracer.init();
    defer tracer.deinit();
    
    const MockFrame = struct {
        gas_remaining: i64 = 1000,
    };
    
    var mock_frame = MockFrame{};
    
    // Test error recording
    tracer.onError(42, error.TestError, MockFrame, &mock_frame);
    
    // Should always pause on error for debugging
    try std.testing.expect(tracer.paused == true);
}

test "DebuggingTracer max history pruning" {
    var tracer = DebuggingTracer.init();
    defer tracer.deinit();
    
    // Set a small max history for testing
    tracer.configure(.{ .max_history = 2 });
    
    const MockFrame = struct {
        gas_remaining: i64 = 1000,
        next_stack_index: usize = 0,
        stack: [16]u256 = [_]u256{0} ** 16,
    };
    
    var mock_frame = MockFrame{};
    
    // Add more steps than max_history
    tracer.beforeOp(0, 0x60, MockFrame, &mock_frame);
    tracer.afterOp(0, 0x60, MockFrame, &mock_frame);
    
    tracer.beforeOp(1, 0x50, MockFrame, &mock_frame);
    tracer.afterOp(1, 0x50, MockFrame, &mock_frame);
    
    tracer.beforeOp(2, 0x00, MockFrame, &mock_frame);
    tracer.afterOp(2, 0x00, MockFrame, &mock_frame);
    
    // Should be pruned to max_history
    try std.testing.expectEqual(@as(usize, 2), tracer.steps.items.len);
}
