//! Comprehensive test suite for tracer interface validation and helper methods
//!
//! This test file provides complete coverage of the Phase 2 tracer interface
//! integration, validating all interface methods, helper functions, and data
//! structure manipulations according to the original specification.

const std = @import("std");
const testing = std.testing;
const tracer = @import("evm").tracing;
const MemoryDatabase = @import("evm").MemoryDatabase;
const Evm = @import("evm").Evm;
const primitives = @import("primitives");

test "TracerHandle interface complete functionality" {
    const allocator = testing.allocator;
    
    // Mock tracer for testing interface
    const MockTracer = struct {
        step_before_called: bool = false,
        step_after_called: bool = false,
        finalize_called: bool = false,
        get_trace_called: bool = false,
        deinit_called: bool = false,
        
        fn step_before_impl(ptr: *anyopaque, step_info: tracer.StepInfo) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.step_before_called = true;
            _ = step_info;
        }
        
        fn step_after_impl(ptr: *anyopaque, step_result: tracer.StepResult) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.step_after_called = true;
            _ = step_result;
        }
        
        fn finalize_impl(ptr: *anyopaque, final_result: tracer.FinalResult) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.finalize_called = true;
            _ = final_result;
        }
        
        fn get_trace_impl(ptr: *anyopaque, alloc: std.mem.Allocator) !tracer.ExecutionTrace {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.get_trace_called = true;
            return tracer.ExecutionTrace{
                .gas_used = 0,
                .failed = false,
                .return_value = try alloc.alloc(u8, 0),
                .struct_logs = try alloc.alloc(tracer.StructLog, 0),
            };
        }
        
        fn deinit_impl(ptr: *anyopaque, alloc: std.mem.Allocator) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.deinit_called = true;
            _ = alloc;
        }
        
        fn toTracerHandle(self: *@This()) tracer.TracerHandle {
            return tracer.TracerHandle{
                .ptr = self,
                .vtable = &.{
                    .step_before = step_before_impl,
                    .step_after = step_after_impl, 
                    .finalize = finalize_impl,
                    .get_trace = get_trace_impl,
                    .deinit = deinit_impl,
                },
            };
        }
    };
    
    var mock_tracer = MockTracer{};
    const tracer_handle = mock_tracer.toTracerHandle();
    
    // Test all interface methods
    const step_info = tracer.StepInfo{
        .pc = 0,
        .opcode = 0x01,
        .op_name = "ADD",
        .gas_before = 1000,
        .depth = 0,
        .address = primitives.Address.ZERO_ADDRESS,
        .caller = primitives.Address.ZERO_ADDRESS,
        .is_static = false,
        .stack_size = 2,
        .memory_size = 0,
    };
    
    tracer_handle.stepBefore(step_info);
    try testing.expect(mock_tracer.step_before_called);
    
    var step_result = try tracer.createEmptyStepResult(allocator);
    defer step_result.deinit(allocator);
    
    tracer_handle.stepAfter(step_result);
    try testing.expect(mock_tracer.step_after_called);
    
    const final_result = tracer.FinalResult{
        .gas_used = 100,
        .failed = false,
        .return_value = &[_]u8{},
        .status = .Success,
    };
    
    tracer_handle.finalize(final_result);
    try testing.expect(mock_tracer.finalize_called);
    
    // Test trace retrieval
    var trace = try tracer_handle.getTrace(allocator);
    defer trace.deinit(allocator);
    try testing.expect(mock_tracer.get_trace_called);
    
    tracer_handle.deinit(allocator);
    try testing.expect(mock_tracer.deinit_called);
}

test "StepInfo helper methods" {
    const step_info_main = tracer.StepInfo{
        .pc = 100,
        .opcode = 0x60,
        .op_name = "PUSH1", 
        .gas_before = 5000,
        .depth = 0,  // Main execution
        .address = primitives.Address.ZERO_ADDRESS,
        .caller = primitives.Address.ZERO_ADDRESS,
        .is_static = false,
        .stack_size = 5,
        .memory_size = 64,
    };
    
    try testing.expect(step_info_main.isMainExecution());
    try testing.expect(!step_info_main.isSubCall());
    
    const step_info_sub = tracer.StepInfo{
        .pc = 200,
        .opcode = 0xf1,
        .op_name = "CALL",
        .gas_before = 3000,
        .depth = 1,  // Sub-call
        .address = primitives.Address.ZERO_ADDRESS,
        .caller = primitives.Address.ZERO_ADDRESS,
        .is_static = false,
        .stack_size = 10,
        .memory_size = 128,
    };
    
    try testing.expect(!step_info_sub.isMainExecution());
    try testing.expect(step_info_sub.isSubCall());
}

test "ExecutionStatus and error helpers" {
    // Test ExecutionStatus toString
    try testing.expectEqualStrings("Success", tracer.ExecutionStatus.Success.toString());
    try testing.expectEqualStrings("Revert", tracer.ExecutionStatus.Revert.toString());
    try testing.expectEqualStrings("OutOfGas", tracer.ExecutionStatus.OutOfGas.toString());
    
    // Test ExecutionErrorEnhanced helpers
    const fatal_error = tracer.ExecutionErrorEnhanced{
        .error_type = .OutOfGas,
        .message = "insufficient gas",
        .pc = 150,
        .gas_remaining = 0,
    };
    
    try testing.expect(fatal_error.isFatal());
    try testing.expect(!fatal_error.isRecoverable());
    try testing.expectEqualStrings("OutOfGas", fatal_error.error_type.toString());
    
    const revert_error = tracer.ExecutionErrorEnhanced{
        .error_type = .RevertExecution,
        .message = "execution reverted",
        .pc = 200,
        .gas_remaining = 1000,
    };
    
    try testing.expect(!revert_error.isFatal());
    try testing.expect(revert_error.isRecoverable());
}

test "Helper creation functions work correctly" {
    const allocator = testing.allocator;
    
    // Test createEmptyStackChanges
    var stack_changes = try tracer.createEmptyStackChanges(allocator);
    defer stack_changes.deinit(allocator);
    
    try testing.expectEqual(@as(usize, 0), stack_changes.getPushCount());
    try testing.expectEqual(@as(usize, 0), stack_changes.getPopCount());
    try testing.expectEqual(@as(usize, 0), stack_changes.getCurrentDepth());
    
    // Test createEmptyMemoryChanges
    var memory_changes = try tracer.createEmptyMemoryChanges(allocator);
    defer memory_changes.deinit(allocator);
    
    try testing.expectEqual(@as(usize, 0), memory_changes.getModificationSize());
    try testing.expectEqual(@as(usize, 0), memory_changes.getCurrentSize());
    try testing.expect(!memory_changes.wasModified());
    
    // Test createEmptyStepResult
    var step_result = try tracer.createEmptyStepResult(allocator);
    defer step_result.deinit(allocator);
    
    try testing.expect(step_result.isSuccess());
    try testing.expect(!step_result.isFailure());
    try testing.expectEqual(@as(u64, 0), step_result.gas_cost);
}

test "MemoryTracer interface validation" {
    const allocator = testing.allocator;
    
    const config = tracer.TracerConfig{
        .memory_max_bytes = 1024,
        .stack_max_items = 32,
        .log_data_max_bytes = 512,
    };
    
    var memory_tracer = try tracer.MemoryTracer.init(allocator, config);
    defer memory_tracer.deinit();
    
    const tracer_handle = memory_tracer.handle();
    
    // Test that all interface methods are available
    const step_info = tracer.StepInfo{
        .pc = 42,
        .opcode = 0x60,
        .op_name = "PUSH1",
        .gas_before = 1000,
        .depth = 0,
        .address = primitives.Address.ZERO_ADDRESS,
        .caller = primitives.Address.ZERO_ADDRESS,
        .is_static = false,
        .stack_size = 1,
        .memory_size = 0,
    };
    
    tracer_handle.stepBefore(step_info);
    
    var step_result = try tracer.createEmptyStepResult(allocator);
    defer step_result.deinit(allocator);
    
    tracer_handle.stepAfter(step_result);
    
    const final_result = tracer.FinalResult{
        .gas_used = 50,
        .failed = false,
        .return_value = &[_]u8{0x01},
        .status = .Success,
    };
    
    tracer_handle.finalize(final_result);
    
    // Test trace retrieval
    var trace = try tracer_handle.getTrace(allocator);
    defer trace.deinit(allocator);
    
    // Trace should contain data from the operations
    try testing.expect(!trace.failed);
    try testing.expectEqual(@as(u64, 50), trace.gas_used);
}

test "FinalResult helper methods" {
    const success_result = tracer.FinalResult{
        .gas_used = 1000,
        .failed = false,
        .return_value = &[_]u8{0x01, 0x02},
        .status = .Success,
    };
    
    try testing.expect(success_result.isSuccess());
    try testing.expect(!success_result.isRevert());
    
    const revert_result = tracer.FinalResult{
        .gas_used = 500,
        .failed = true,
        .return_value = &[_]u8{},
        .status = .Revert,
    };
    
    try testing.expect(!revert_result.isSuccess());
    try testing.expect(revert_result.isRevert());
}

test "StorageChange and LogEntry helpers" {
    const allocator = testing.allocator;
    
    // Test StorageChange helpers
    const storage_change = tracer.StorageChange{
        .address = primitives.Address.ZERO_ADDRESS,
        .key = 42,
        .value = 100,
        .original_value = 50,
    };
    
    try testing.expect(storage_change.isWrite());
    try testing.expect(!storage_change.isClear());
    
    const clear_change = tracer.StorageChange{
        .address = primitives.Address.ZERO_ADDRESS,
        .key = 42,
        .value = 0,
        .original_value = 50,
    };
    
    try testing.expect(clear_change.isWrite());
    try testing.expect(clear_change.isClear());
    
    // Test LogEntry helpers  
    const topics = try allocator.dupe(u256, &[_]u256{0x123, 0x456});
    const data = try allocator.dupe(u8, "hello world");
    
    const log_entry = tracer.LogEntry{
        .address = primitives.Address.ZERO_ADDRESS,
        .topics = topics,
        .data = data,
        .data_truncated = false,
    };
    
    try testing.expectEqual(@as(usize, 2), log_entry.getTopicCount());
    try testing.expectEqual(@as(usize, 11), log_entry.getDataSize());
    try testing.expect(log_entry.hasTopics());
    try testing.expect(log_entry.hasData());
    
    // Clean up
    log_entry.deinit(allocator);
}

test "Tracer null pointer safety with EVM integration" {
    const allocator = testing.allocator;
    
    // Test that EVM handles null tracer gracefully
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();
    
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();
    
    // Tracer should be null by default
    try testing.expect(evm.inproc_tracer == null);
    
    // Should execute without issues
    const bytecode = [_]u8{ 0x60, 0x01, 0x60, 0x02, 0x01, 0x00 }; // Simple ADD and STOP
    const test_addr = primitives.Address.from_u256(0x1234);
    const test_caller = primitives.Address.from_u256(0x5678);
    
    try evm.state.set_code(test_addr, &bytecode);
    try evm.state.set_balance(test_caller, std.math.maxInt(u256));
    
    const call_params = @import("evm").CallParams{ .call = .{
        .caller = test_caller,
        .to = test_addr,
        .value = 0,
        .input = &.{},
        .gas = 100000,
    } };
    
    const result = try evm.call(call_params);
    try testing.expect(result.success);
}

test "Memory pressure handling with restrictive bounds" {
    const allocator = testing.allocator;
    
    // Test tracer with very restrictive bounds
    const restrictive_config = tracer.TracerConfig{
        .memory_max_bytes = 8,    // Very small
        .stack_max_items = 1,     // Very small  
        .log_data_max_bytes = 4,  // Very small
    };
    
    var memory_tracer = try tracer.MemoryTracer.init(allocator, restrictive_config);
    defer memory_tracer.deinit();
    
    const tracer_handle = memory_tracer.handle();
    
    // Test with operations that would exceed bounds
    const step_info = tracer.StepInfo{
        .pc = 0,
        .opcode = 0x60,
        .op_name = "PUSH1",
        .gas_before = 1000,
        .depth = 0,
        .address = primitives.Address.ZERO_ADDRESS,
        .caller = primitives.Address.ZERO_ADDRESS,
        .is_static = false,
        .stack_size = 10,  // Exceeds stack_max_items
        .memory_size = 100,  // Exceeds memory_max_bytes
    };
    
    // Should handle gracefully without crashing
    tracer_handle.stepBefore(step_info);
    
    var step_result = try tracer.createEmptyStepResult(allocator);
    defer step_result.deinit(allocator);
    
    tracer_handle.stepAfter(step_result);
    
    const final_result = tracer.FinalResult{
        .gas_used = 100,
        .failed = false,
        .return_value = &[_]u8{0x01, 0x02, 0x03, 0x04, 0x05}, // Longer than log_data_max_bytes
        .status = .Success,
    };
    
    tracer_handle.finalize(final_result);
    
    // Tracer should still work and produce a trace
    var trace = try tracer_handle.getTrace(allocator);
    defer trace.deinit(allocator);
    try testing.expect(!trace.failed);
}

test "Backward compatibility methods" {
    const allocator = testing.allocator;
    
    const MockOldTracer = struct {
        old_pre_step_called: bool = false,
        old_post_step_called: bool = false,
        old_finish_called: bool = false,
        
        fn step_before_impl(ptr: *anyopaque, step_info: tracer.StepInfo) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.old_pre_step_called = true;
            _ = step_info;
        }
        
        fn step_after_impl(ptr: *anyopaque, step_result: tracer.StepResult) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.old_post_step_called = true;
            _ = step_result;
        }
        
        fn finalize_impl(ptr: *anyopaque, final_result: tracer.FinalResult) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.old_finish_called = true;
            _ = final_result;
        }
        
        fn get_trace_impl(ptr: *anyopaque, alloc: std.mem.Allocator) !tracer.ExecutionTrace {
            _ = ptr;
            return tracer.ExecutionTrace{
                .gas_used = 0,
                .failed = false,
                .return_value = try alloc.alloc(u8, 0),
                .struct_logs = try alloc.alloc(tracer.StructLog, 0),
            };
        }
        
        fn deinit_impl(ptr: *anyopaque, alloc: std.mem.Allocator) void {
            _ = ptr;
            _ = alloc;
        }
        
        fn toTracerHandle(self: *@This()) tracer.TracerHandle {
            return tracer.TracerHandle{
                .ptr = self,
                .vtable = &.{
                    .step_before = step_before_impl,
                    .step_after = step_after_impl, 
                    .finalize = finalize_impl,
                    .get_trace = get_trace_impl,
                    .deinit = deinit_impl,
                },
            };
        }
    };
    
    var mock_tracer = MockOldTracer{};
    const tracer_handle = mock_tracer.toTracerHandle();
    
    // Test backward compatibility methods
    const step_info = tracer.StepInfo{
        .pc = 0,
        .opcode = 0x01,
        .op_name = "ADD",
        .gas_before = 1000,
        .depth = 0,
        .address = primitives.Address.ZERO_ADDRESS,
        .caller = primitives.Address.ZERO_ADDRESS,
        .is_static = false,
        .stack_size = 2,
        .memory_size = 0,
    };
    
    tracer_handle.on_pre_step(step_info);
    try testing.expect(mock_tracer.old_pre_step_called);
    
    var step_result = try tracer.createEmptyStepResult(allocator);
    defer step_result.deinit(allocator);
    
    tracer_handle.on_post_step(step_result);
    try testing.expect(mock_tracer.old_post_step_called);
    
    tracer_handle.on_finish(&[_]u8{0x01}, true);
    try testing.expect(mock_tracer.old_finish_called);
}