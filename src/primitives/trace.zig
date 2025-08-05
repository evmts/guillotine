//! EVM Execution Trace - Debug trace data structures
//!
//! Represents detailed execution traces from debug_traceTransaction RPC calls.
//! These structures capture step-by-step EVM execution including opcode execution,
//! gas consumption, and state changes.
//!
//! ## Debug Tracing Overview
//! Debug tracing provides detailed insight into EVM execution:
//! - Each opcode execution is recorded as a StructLog
//! - Gas consumption is tracked at each step
//! - Stack, memory, and storage state is captured
//! - Call depth tracks nested contract calls
//!
//! ## Memory Management
//! ExecutionTrace and StructLog own their data and are responsible for cleanup.
//! Always call deinit() to prevent memory leaks.
//!
//! ## Usage Example
//! ```zig
//! var trace = ExecutionTrace{
//!     .return_value = try allocator.dupe(u8, return_data),
//!     .struct_logs = try allocator.alloc(StructLog, log_count),
//!     // ... other fields
//! };
//! defer trace.deinit(allocator);
//! ```

const std = @import("std");
const testing = std.testing;
const crypto_pkg = @import("crypto");
const Hash = crypto_pkg.Hash;
const Allocator = std.mem.Allocator;

pub const ExecutionTrace = struct {
    gas_used: u64,
    failed: bool,
    return_value: []u8, // Owned data
    struct_logs: []StructLog, // Owned array
    
    /// Clean up allocated memory for trace data
    pub fn deinit(self: *const ExecutionTrace, allocator: Allocator) void {
        allocator.free(self.return_value);
        for (self.struct_logs) |*log| {
            log.deinit(allocator);
        }
        allocator.free(self.struct_logs);
    }
    
    /// Get the number of execution steps
    pub fn getStepCount(self: *const ExecutionTrace) usize {
        return self.struct_logs.len;
    }
    
    /// Check if execution was successful
    pub fn isSuccess(self: *const ExecutionTrace) bool {
        return !self.failed;
    }
    
    /// Check if execution failed
    pub fn isFailure(self: *const ExecutionTrace) bool {
        return self.failed;
    }
    
    /// Get execution step by index
    pub fn getStep(self: *const ExecutionTrace, index: usize) ?*const StructLog {
        if (index >= self.struct_logs.len) return null;
        return &self.struct_logs[index];
    }
    
    /// Get the final execution step
    pub fn getFinalStep(self: *const ExecutionTrace) ?*const StructLog {
        if (self.struct_logs.len == 0) return null;
        return &self.struct_logs[self.struct_logs.len - 1];
    }
    
    /// Check if trace is empty (no steps)
    pub fn isEmpty(self: *const ExecutionTrace) bool {
        return self.struct_logs.len == 0;
    }
};

pub const StructLog = struct {
    // Execution context
    pc: u64,
    op: []const u8, // Owned string (e.g., "PUSH1", "SSTORE")
    gas: u64,
    gas_cost: u64,
    depth: u32,
    
    // EVM state
    stack: []u256, // Owned array
    memory: []u8, // Owned array
    storage: std.hash_map.HashMap(Hash, Hash, std.hash_map.AutoContext(Hash), 80), // Owned map
    
    /// Clean up allocated memory for struct log data
    pub fn deinit(self: *const StructLog, allocator: Allocator) void {
        allocator.free(self.op);
        allocator.free(self.stack);
        allocator.free(self.memory);
        // Note: HashMap.deinit() handles its own cleanup
        var mutable_storage = self.storage;
        mutable_storage.deinit();
    }
    
    /// Get stack depth (number of items on stack)
    pub fn getStackDepth(self: *const StructLog) usize {
        return self.stack.len;
    }
    
    /// Get memory size in bytes
    pub fn getMemorySize(self: *const StructLog) usize {
        return self.memory.len;
    }
    
    /// Get number of storage changes
    pub fn getStorageChangeCount(self: *const StructLog) usize {
        return self.storage.count();
    }
    
    /// Get stack item by index (0 = top of stack)
    pub fn getStackItem(self: *const StructLog, index: usize) ?u256 {
        if (index >= self.stack.len) return null;
        return self.stack[index];
    }
    
    /// Get top of stack
    pub fn getStackTop(self: *const StructLog) ?u256 {
        if (self.stack.len == 0) return null;
        return self.stack[0];
    }
    
    /// Check if this is a main execution step (depth 0)
    pub fn isMainExecution(self: *const StructLog) bool {
        return self.depth == 0;
    }
    
    /// Check if this is a sub-call step (depth > 0)
    pub fn isSubCall(self: *const StructLog) bool {
        return self.depth > 0;
    }
    
    /// Get storage value for a key
    pub fn getStorageValue(self: *const StructLog, key: Hash) ?Hash {
        return self.storage.get(key);
    }
    
    /// Check if storage was modified
    pub fn hasStorageChanges(self: *const StructLog) bool {
        return self.storage.count() > 0;
    }
};

/// Helper function to create an empty ExecutionTrace
pub fn createEmptyTrace(allocator: Allocator) !ExecutionTrace {
    return ExecutionTrace{
        .gas_used = 0,
        .failed = false,
        .return_value = try allocator.alloc(u8, 0),
        .struct_logs = try allocator.alloc(StructLog, 0),
    };
}

/// Helper function to create an empty StructLog
pub fn createEmptyStructLog(allocator: Allocator, pc: u64, op: []const u8) !StructLog {
    return StructLog{
        .pc = pc,
        .op = try allocator.dupe(u8, op),
        .gas = 0,
        .gas_cost = 0,
        .depth = 0,
        .stack = try allocator.alloc(u256, 0),
        .memory = try allocator.alloc(u8, 0),
        .storage = std.hash_map.HashMap(Hash, Hash, std.hash_map.AutoContext(Hash), 80).init(allocator),
    };
}

test "ExecutionTrace basic construction and cleanup" {
    const allocator = testing.allocator;
    
    // Create empty trace
    var trace = try createEmptyTrace(allocator);
    defer trace.deinit(allocator);
    
    try testing.expectEqual(@as(u64, 0), trace.gas_used);
    try testing.expect(trace.isSuccess());
    try testing.expect(!trace.isFailure());
    try testing.expect(trace.isEmpty());
    try testing.expectEqual(@as(usize, 0), trace.getStepCount());
}

test "ExecutionTrace failed execution" {
    const allocator = testing.allocator;
    
    const return_data = try allocator.dupe(u8, "revert reason");
    const struct_logs = try allocator.alloc(StructLog, 0);
    
    const trace = ExecutionTrace{
        .gas_used = 50000,
        .failed = true,
        .return_value = return_data,
        .struct_logs = struct_logs,
    };
    defer trace.deinit(allocator);
    
    try testing.expect(trace.isFailure());
    try testing.expect(!trace.isSuccess());
    try testing.expectEqual(@as(u64, 50000), trace.gas_used);
    try testing.expectEqualStrings("revert reason", trace.return_value);
}

test "StructLog basic construction and cleanup" {
    const allocator = testing.allocator;
    
    var log = try createEmptyStructLog(allocator, 0, "PUSH1");
    defer log.deinit(allocator);
    
    try testing.expectEqual(@as(u64, 0), log.pc);
    try testing.expectEqualStrings("PUSH1", log.op);
    try testing.expect(log.isMainExecution());
    try testing.expect(!log.isSubCall());
    try testing.expectEqual(@as(usize, 0), log.getStackDepth());
    try testing.expectEqual(@as(usize, 0), log.getMemorySize());
    try testing.expect(!log.hasStorageChanges());
}

test "StructLog with stack data" {
    const allocator = testing.allocator;
    
    // Create stack with some values
    const stack = try allocator.alloc(u256, 3);
    stack[0] = 0x42; // Top of stack
    stack[1] = 0x1337;
    stack[2] = 0xDEADBEEF;
    
    var log = StructLog{
        .pc = 10,
        .op = try allocator.dupe(u8, "ADD"),
        .gas = 1000,
        .gas_cost = 3,
        .depth = 0,
        .stack = stack,
        .memory = try allocator.alloc(u8, 0),
        .storage = std.hash_map.HashMap(Hash, Hash, std.hash_map.AutoContext(Hash), 80).init(allocator),
    };
    defer log.deinit(allocator);
    
    try testing.expectEqual(@as(usize, 3), log.getStackDepth());
    try testing.expectEqual(@as(u256, 0x42), log.getStackTop().?);
    try testing.expectEqual(@as(u256, 0x42), log.getStackItem(0).?);
    try testing.expectEqual(@as(u256, 0x1337), log.getStackItem(1).?);
    try testing.expectEqual(@as(u256, 0xDEADBEEF), log.getStackItem(2).?);
    
    // Test out of bounds
    try testing.expect(log.getStackItem(3) == null);
}

test "StructLog with memory data" {
    const allocator = testing.allocator;
    
    // Create memory with some data
    const memory = try allocator.alloc(u8, 64);
    @memset(memory, 0);
    memory[0] = 0xFF;
    memory[31] = 0xAA;
    memory[32] = 0xBB;
    memory[63] = 0xCC;
    
    var log = StructLog{
        .pc = 20,
        .op = try allocator.dupe(u8, "MSTORE"),
        .gas = 2000,
        .gas_cost = 6,
        .depth = 1, // Sub-call
        .stack = try allocator.alloc(u256, 0),
        .memory = memory,
        .storage = std.hash_map.HashMap(Hash, Hash, std.hash_map.AutoContext(Hash), 80).init(allocator),
    };
    defer log.deinit(allocator);
    
    try testing.expectEqual(@as(usize, 64), log.getMemorySize());
    try testing.expect(log.isSubCall());
    try testing.expect(!log.isMainExecution());
    try testing.expectEqual(@as(u8, 0xFF), log.memory[0]);
    try testing.expectEqual(@as(u8, 0xAA), log.memory[31]);
    try testing.expectEqual(@as(u8, 0xBB), log.memory[32]);
    try testing.expectEqual(@as(u8, 0xCC), log.memory[63]);
}

test "StructLog with storage changes" {
    const allocator = testing.allocator;
    
    var storage = std.hash_map.HashMap(Hash, Hash, std.hash_map.AutoContext(Hash), 80).init(allocator);
    
    // Add some storage changes
    const key1 = Hash{ .bytes = [_]u8{1} ** 32 };
    const value1 = Hash{ .bytes = [_]u8{2} ** 32 };
    const key2 = Hash{ .bytes = [_]u8{3} ** 32 };
    const value2 = Hash{ .bytes = [_]u8{4} ** 32 };
    
    try storage.put(key1, value1);
    try storage.put(key2, value2);
    
    var log = StructLog{
        .pc = 30,
        .op = try allocator.dupe(u8, "SSTORE"),
        .gas = 5000,
        .gas_cost = 20000,
        .depth = 0,
        .stack = try allocator.alloc(u256, 0),
        .memory = try allocator.alloc(u8, 0),
        .storage = storage,
    };
    defer log.deinit(allocator);
    
    try testing.expect(log.hasStorageChanges());
    try testing.expectEqual(@as(usize, 2), log.getStorageChangeCount());
    
    // Test storage retrieval
    const retrieved1 = log.getStorageValue(key1);
    try testing.expect(retrieved1 != null);
    try testing.expectEqualSlices(u8, &value1.bytes, &retrieved1.?.bytes);
    
    const retrieved2 = log.getStorageValue(key2);
    try testing.expect(retrieved2 != null);
    try testing.expectEqualSlices(u8, &value2.bytes, &retrieved2.?.bytes);
    
    // Test non-existent key
    const key3 = Hash{ .bytes = [_]u8{5} ** 32 };
    const retrieved3 = log.getStorageValue(key3);
    try testing.expect(retrieved3 == null);
}

test "ExecutionTrace with multiple steps" {
    const allocator = testing.allocator;
    
    // Create multiple struct logs
    const struct_logs = try allocator.alloc(StructLog, 3);
    
    struct_logs[0] = try createEmptyStructLog(allocator, 0, "PUSH1");
    struct_logs[0].gas = 1000;
    struct_logs[0].gas_cost = 3;
    
    struct_logs[1] = try createEmptyStructLog(allocator, 2, "PUSH1");
    struct_logs[1].gas = 997;
    struct_logs[1].gas_cost = 3;
    
    struct_logs[2] = try createEmptyStructLog(allocator, 4, "ADD");
    struct_logs[2].gas = 994;
    struct_logs[2].gas_cost = 3;
    
    const return_data = try allocator.dupe(u8, &[_]u8{0x42});
    
    const trace = ExecutionTrace{
        .gas_used = 9,
        .failed = false,
        .return_value = return_data,
        .struct_logs = struct_logs,
    };
    defer trace.deinit(allocator);
    
    try testing.expectEqual(@as(usize, 3), trace.getStepCount());
    try testing.expect(!trace.isEmpty());
    
    // Test step access
    const step0 = trace.getStep(0);
    try testing.expect(step0 != null);
    try testing.expectEqualStrings("PUSH1", step0.?.op);
    try testing.expectEqual(@as(u64, 0), step0.?.pc);
    
    const step1 = trace.getStep(1);
    try testing.expect(step1 != null);
    try testing.expectEqualStrings("PUSH1", step1.?.op);
    try testing.expectEqual(@as(u64, 2), step1.?.pc);
    
    const step2 = trace.getStep(2);
    try testing.expect(step2 != null);
    try testing.expectEqualStrings("ADD", step2.?.op);
    try testing.expectEqual(@as(u64, 4), step2.?.pc);
    
    // Test final step
    const final_step = trace.getFinalStep();
    try testing.expect(final_step != null);
    try testing.expectEqualStrings("ADD", final_step.?.op);
    
    // Test out of bounds
    const invalid_step = trace.getStep(3);
    try testing.expect(invalid_step == null);
}

test "ExecutionTrace memory management with complex data" {
    const allocator = testing.allocator;
    
    // Create a complex trace with nested data
    const struct_logs = try allocator.alloc(StructLog, 1);
    
    // Create complex struct log with all data types
    const stack = try allocator.alloc(u256, 2);
    stack[0] = 0x123456789ABCDEF0;
    stack[1] = 0xFEDCBA9876543210;
    
    const memory = try allocator.alloc(u8, 32);
    @memset(memory, 0xAB);
    
    var storage = std.hash_map.HashMap(Hash, Hash, std.hash_map.AutoContext(Hash), 80).init(allocator);
    const key = Hash{ .bytes = [_]u8{0xFF} ** 32 };
    const value = Hash{ .bytes = [_]u8{0x00} ** 32 };
    try storage.put(key, value);
    
    struct_logs[0] = StructLog{
        .pc = 100,
        .op = try allocator.dupe(u8, "COMPLEX_OP"),
        .gas = 10000,
        .gas_cost = 1000,
        .depth = 2,
        .stack = stack,
        .memory = memory,
        .storage = storage,
    };
    
    const return_data = try allocator.dupe(u8, "complex return data");
    
    const trace = ExecutionTrace{
        .gas_used = 1000,
        .failed = false,
        .return_value = return_data,
        .struct_logs = struct_logs,
    };
    defer trace.deinit(allocator);
    
    // Verify all data is accessible
    const step = trace.getStep(0).?;
    try testing.expectEqual(@as(usize, 2), step.getStackDepth());
    try testing.expectEqual(@as(usize, 32), step.getMemorySize());
    try testing.expectEqual(@as(usize, 1), step.getStorageChangeCount());
    try testing.expectEqualStrings("COMPLEX_OP", step.op);
    try testing.expectEqualStrings("complex return data", trace.return_value);
}

test "ExecutionTrace edge cases - empty trace" {
    const allocator = testing.allocator;
    
    var empty_trace = try createEmptyTrace(allocator);
    defer empty_trace.deinit(allocator);
    
    try testing.expect(empty_trace.isEmpty());
    try testing.expectEqual(@as(usize, 0), empty_trace.getStepCount());
    try testing.expect(empty_trace.getFinalStep() == null);
    try testing.expect(empty_trace.getStep(0) == null);
}

test "StructLog edge cases - large data" {
    const allocator = testing.allocator;
    
    // Create very large memory
    const large_memory = try allocator.alloc(u8, 1024 * 1024); // 1MB
    @memset(large_memory, 0x55);
    
    // Create large stack
    const large_stack = try allocator.alloc(u256, 1024);
    for (large_stack, 0..) |*item, i| {
        item.* = @intCast(i);
    }
    
    // Create many storage entries
    var large_storage = std.hash_map.HashMap(Hash, Hash, std.hash_map.AutoContext(Hash), 80).init(allocator);
    var i: u8 = 0;
    while (i < 100) : (i += 1) {
        const key = Hash{ .bytes = [_]u8{i} ** 32 };
        const value = Hash{ .bytes = [_]u8{i +% 1} ** 32 };
        try large_storage.put(key, value);
    }
    
    var log = StructLog{
        .pc = 999999,
        .op = try allocator.dupe(u8, "VERY_COMPLEX_OPERATION_WITH_LONG_NAME"),
        .gas = 30000000,
        .gas_cost = 1000000,
        .depth = 16, // Deep call stack
        .stack = large_stack,
        .memory = large_memory,
        .storage = large_storage,
    };
    defer log.deinit(allocator);
    
    try testing.expectEqual(@as(usize, 1024 * 1024), log.getMemorySize());
    try testing.expectEqual(@as(usize, 1024), log.getStackDepth());
    try testing.expectEqual(@as(usize, 100), log.getStorageChangeCount());
    try testing.expect(log.isSubCall());
    try testing.expectEqual(@as(u256, 0), log.getStackTop().?);
    try testing.expectEqual(@as(u256, 1023), log.getStackItem(1023).?);
}

test "ExecutionTrace with deep call stack" {
    const allocator = testing.allocator;
    
    // Create trace simulating deep nested calls
    const struct_logs = try allocator.alloc(StructLog, 5);
    
    const depths = [_]u32{ 0, 1, 2, 3, 4 };
    const ops = [_][]const u8{ "CALL", "CALL", "CALL", "SSTORE", "RETURN" };
    
    for (struct_logs, 0..) |*log, idx| {
        log.* = try createEmptyStructLog(allocator, @intCast(idx * 10), ops[idx]);
        log.depth = depths[idx];
        log.gas = 1000000 - @as(u64, @intCast(idx * 100000));
        log.gas_cost = 100;
    }
    
    const return_data = try allocator.alloc(u8, 0);
    
    const trace = ExecutionTrace{
        .gas_used = 500,
        .failed = false,
        .return_value = return_data,
        .struct_logs = struct_logs,
    };
    defer trace.deinit(allocator);
    
    // Verify depth tracking
    for (0..5) |idx| {
        const step = trace.getStep(idx).?;
        try testing.expectEqual(depths[idx], step.depth);
        if (idx == 0) {
            try testing.expect(step.isMainExecution());
        } else {
            try testing.expect(step.isSubCall());
        }
    }
}