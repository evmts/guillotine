/// Call result structure for EVM calls
pub const CallResult = struct {
    success: bool,
    gas_left: u64,
    output: []const u8,
    logs: []const Log = &.{},
    /// Accounts that self-destructed during execution (address -> beneficiary)
    selfdestructs: []const SelfDestructRecord = &.{},
    /// Addresses accessed during execution (for access list)
    accessed_addresses: []const Address = &.{},
    /// Storage slots accessed during execution
    accessed_storage: []const StorageAccess = &.{},
    /// Execution trace (for debugging and differential testing)
    trace: ?ExecutionTrace = null,
    /// Error information (for debugging and differential testing)
    error_info: ?[]const u8 = null,

    /// Create a successful call result
    pub fn success_with_output(gas_left: u64, output: []const u8) CallResult {
        return CallResult{
            .success = true,
            .gas_left = gas_left,
            .output = output,
            .logs = &.{},
            .selfdestructs = &.{},
            .accessed_addresses = &.{},
            .accessed_storage = &.{},
        };
    }

    /// Create a successful call result with empty output
    pub fn success_empty(gas_left: u64) CallResult {
        return CallResult{
            .success = true,
            .gas_left = gas_left,
            .output = &[_]u8{},
            .logs = &.{},
            .selfdestructs = &.{},
            .accessed_addresses = &.{},
            .accessed_storage = &.{},
        };
    }

    /// Create a failed call result
    pub fn failure(gas_left: u64) CallResult {
        return CallResult{
            .success = false,
            .gas_left = gas_left,
            .output = &[_]u8{},
            .logs = &.{},
            .selfdestructs = &.{},
            .accessed_addresses = &.{},
            .accessed_storage = &.{},
        };
    }
    
    /// Create a failed call result with error info
    pub fn failure_with_error(gas_left: u64, error_info: []const u8) CallResult {
        return CallResult{
            .success = false,
            .gas_left = gas_left,
            .output = &[_]u8{},
            .logs = &.{},
            .selfdestructs = &.{},
            .accessed_addresses = &.{},
            .accessed_storage = &.{},
            .error_info = error_info,
        };
    }

    /// Create a reverted call result with revert data
    pub fn revert_with_data(gas_left: u64, revert_data: []const u8) CallResult {
        return CallResult{
            .success = false,
            .gas_left = gas_left,
            .output = revert_data,
            .logs = &.{},
            .selfdestructs = &.{},
            .accessed_addresses = &.{},
            .accessed_storage = &.{},
        };
    }

    /// Create a successful call result with output and logs
    pub fn success_with_logs(gas_left: u64, output: []const u8, logs: []const Log) CallResult {
        return CallResult{
            .success = true,
            .gas_left = gas_left,
            .output = output,
            .logs = logs,
            .selfdestructs = &.{},
            .accessed_addresses = &.{},
            .accessed_storage = &.{},
        };
    }

    /// Check if the call succeeded
    pub fn isSuccess(self: CallResult) bool {
        return self.success;
    }

    /// Check if the call failed
    pub fn isFailure(self: CallResult) bool {
        return !self.success;
    }

    /// Check if the call has output data
    pub fn hasOutput(self: CallResult) bool {
        return self.output.len > 0;
    }

    /// Get the amount of gas consumed (assuming original_gas was provided)
    pub fn gasConsumed(self: CallResult, original_gas: u64) u64 {
        if (self.gas_left > original_gas) return 0; // Sanity check
        return original_gas - self.gas_left;
    }

    /// Clean up all memory associated with logs
    /// Must be called when CallResult contains owned log data
    pub fn deinitLogs(self: *CallResult, allocator: std.mem.Allocator) void {
        for (self.logs) |log| {
            allocator.free(log.topics);
            allocator.free(log.data);
        }
        allocator.free(self.logs);
        self.logs = &.{};
    }

    /// Clean up memory for a logs slice returned by takeLogs()
    /// Use this when you have logs from takeLogs() instead of a full CallResult
    pub fn deinitLogsSlice(logs: []const Log, allocator: std.mem.Allocator) void {
        for (logs) |log| {
            allocator.free(log.topics);
            allocator.free(log.data);
        }
        allocator.free(logs);
    }
};

const std = @import("std");
const primitives = @import("primitives");
const Address = primitives.Address.Address;
const ZERO_ADDRESS = primitives.ZERO_ADDRESS;

/// Log entry structure for EVM events
pub const Log = struct {
    address: Address,
    topics: []const u256,
    data: []const u8,
};

/// Record of a self-destruct operation
pub const SelfDestructRecord = struct {
    /// Address of the contract being destroyed
    contract: Address,
    /// Address receiving the remaining balance
    beneficiary: Address,
};

/// Record of a storage slot access
pub const StorageAccess = struct {
    /// Contract address
    address: Address,
    /// Storage slot key
    slot: u256,
};

/// Represents a single execution step in the trace
pub const TraceStep = struct {
    pc: u32,
    opcode: u8,
    opcode_name: []const u8,
    gas: u64,
    stack: []const u256,
    memory: []const u8,
    storage_reads: []const StorageRead,
    storage_writes: []const StorageWrite,
    
    pub const StorageRead = struct {
        address: Address,
        slot: u256,
        value: u256,
    };
    
    pub const StorageWrite = struct {
        address: Address,
        slot: u256,
        old_value: u256,
        new_value: u256,
    };
    
    pub fn deinit(self: *TraceStep, allocator: std.mem.Allocator) void {
        allocator.free(self.opcode_name);
        allocator.free(self.stack);
        allocator.free(self.memory);
        allocator.free(self.storage_reads);
        allocator.free(self.storage_writes);
    }
};

/// Complete execution trace
pub const ExecutionTrace = struct {
    steps: []TraceStep,
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) ExecutionTrace {
        return ExecutionTrace{
            .steps = &.{},
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *ExecutionTrace) void {
        for (self.steps) |*step| {
            step.deinit(self.allocator);
        }
        self.allocator.free(self.steps);
    }
    
    /// Create empty trace for now (placeholder implementation)
    pub fn empty(allocator: std.mem.Allocator) ExecutionTrace {
        return ExecutionTrace{
            .steps = &.{},
            .allocator = allocator,
        };
    }
};

test "call result success creation" {
    const output_data = &[_]u8{ 0x01, 0x02, 0x03, 0x04 };
    const result = CallResult.success_with_output(15000, output_data);

    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(u64, 15000), result.gas_left);
    try std.testing.expectEqualSlices(u8, output_data, result.output);
    try std.testing.expect(result.isSuccess());
    try std.testing.expect(!result.isFailure());
    try std.testing.expect(result.hasOutput());
}

test "call result success empty" {
    const result = CallResult.success_empty(8000);

    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(u64, 8000), result.gas_left);
    try std.testing.expectEqual(@as(usize, 0), result.output.len);
    try std.testing.expect(result.isSuccess());
    try std.testing.expect(!result.isFailure());
    try std.testing.expect(!result.hasOutput());
}

test "call result failure" {
    const result = CallResult.failure(500);

    try std.testing.expect(!result.success);
    try std.testing.expectEqual(@as(u64, 500), result.gas_left);
    try std.testing.expectEqual(@as(usize, 0), result.output.len);
    try std.testing.expect(!result.isSuccess());
    try std.testing.expect(result.isFailure());
    try std.testing.expect(!result.hasOutput());
}

test "call result revert with data" {
    const revert_data = "Error: insufficient balance";
    const result = CallResult.revert_with_data(3000, revert_data);

    try std.testing.expect(!result.success);
    try std.testing.expectEqual(@as(u64, 3000), result.gas_left);
    try std.testing.expectEqualSlices(u8, revert_data, result.output);
    try std.testing.expect(!result.isSuccess());
    try std.testing.expect(result.isFailure());
    try std.testing.expect(result.hasOutput());
}

test "call result gas consumption calculation" {
    const original_gas: u64 = 21000;

    // Successful call that consumed some gas
    const success_result = CallResult.success_empty(18500);
    try std.testing.expectEqual(@as(u64, 2500), success_result.gasConsumed(original_gas));

    // Failed call that consumed most gas
    const failed_result = CallResult.failure(100);
    try std.testing.expectEqual(@as(u64, 20900), failed_result.gasConsumed(original_gas));

    // Edge case: gas_left equals original_gas (no consumption)
    const no_consumption = CallResult.success_empty(original_gas);
    try std.testing.expectEqual(@as(u64, 0), no_consumption.gasConsumed(original_gas));

    // Edge case: gas_left > original_gas (invalid state)
    const invalid_result = CallResult.success_empty(25000);
    try std.testing.expectEqual(@as(u64, 0), invalid_result.gasConsumed(original_gas));
}

test "call result state checks" {
    // Success cases
    const success1 = CallResult.success_empty(1000);
    try std.testing.expect(success1.isSuccess());
    try std.testing.expect(!success1.isFailure());

    const success2 = CallResult.success_with_output(2000, &[_]u8{0xff});
    try std.testing.expect(success2.isSuccess());
    try std.testing.expect(!success2.isFailure());

    // Failure cases
    const failure1 = CallResult.failure(500);
    try std.testing.expect(!failure1.isSuccess());
    try std.testing.expect(failure1.isFailure());

    const failure2 = CallResult.revert_with_data(300, "revert reason");
    try std.testing.expect(!failure2.isSuccess());
    try std.testing.expect(failure2.isFailure());
}

test "call result output checks" {
    // No output cases
    const empty1 = CallResult.success_empty(1000);
    try std.testing.expect(!empty1.hasOutput());

    const empty2 = CallResult.failure(500);
    try std.testing.expect(!empty2.hasOutput());

    // With output cases
    const with_output1 = CallResult.success_with_output(2000, &[_]u8{0x42});
    try std.testing.expect(with_output1.hasOutput());

    const with_output2 = CallResult.revert_with_data(300, "error message");
    try std.testing.expect(with_output2.hasOutput());
}

test "call result edge cases" {
    // Zero gas left
    const zero_gas = CallResult.success_empty(0);
    try std.testing.expect(zero_gas.isSuccess());
    try std.testing.expectEqual(@as(u64, 0), zero_gas.gas_left);
    try std.testing.expectEqual(@as(u64, 21000), zero_gas.gasConsumed(21000));

    // Maximum gas left
    const max_gas = CallResult.success_empty(std.math.maxInt(u64));
    try std.testing.expectEqual(std.math.maxInt(u64), max_gas.gas_left);
    try std.testing.expectEqual(@as(u64, 0), max_gas.gasConsumed(std.math.maxInt(u64)));

    // Large output data
    const large_output = &[_]u8{0xaa} ** 10000;
    const large_result = CallResult.success_with_output(5000, large_output);
    try std.testing.expect(large_result.hasOutput());
    try std.testing.expectEqual(@as(usize, 10000), large_result.output.len);

    // Empty revert data (still counts as having output)
    const empty_revert = CallResult.revert_with_data(1000, &[_]u8{});
    try std.testing.expect(!empty_revert.hasOutput());
    try std.testing.expect(empty_revert.isFailure());
}

test "CallResult log memory management - proper cleanup" {
    const testing = std.testing;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) {
            const log = @import("log.zig");
            log.warn("Memory leak detected in CallResult log cleanup test!", .{});
            testing.expect(false) catch {};
        }
    }
    const allocator = gpa.allocator();

    // Create logs with allocated memory
    const topics1 = try allocator.dupe(u256, &[_]u256{ 0x1234, 0x5678 });
    const data1 = try allocator.dupe(u8, "test log data");
    const topics2 = try allocator.dupe(u256, &[_]u256{0xABCD});
    const data2 = try allocator.dupe(u8, "second log");

    const logs = try allocator.alloc(Log, 2);
    logs[0] = Log{
        .address = ZERO_ADDRESS,
        .topics = topics1,
        .data = data1,
    };
    logs[1] = Log{
        .address = ZERO_ADDRESS,
        .topics = topics2,
        .data = data2,
    };

    // Create CallResult with logs
    var call_result = CallResult.success_with_logs(50000, &[_]u8{}, logs);

    // This should properly clean up all allocated memory
    call_result.deinitLogs(allocator);
}

test "CallResult deinitLogsSlice - memory management for takeLogs result" {
    const testing = std.testing;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) {
            const log = @import("log.zig");
            log.warn("Memory leak detected in deinitLogsSlice test!", .{});
            testing.expect(false) catch {};
        }
    }
    const allocator = gpa.allocator();

    // Simulate takeLogs() result - individual logs with allocated data
    const topics1 = try allocator.dupe(u256, &[_]u256{ 0xDEAD, 0xBEEF });
    const data1 = try allocator.dupe(u8, "takeLogs test");
    const topics2 = try allocator.dupe(u256, &[_]u256{0xCAFE});
    const data2 = try allocator.dupe(u8, "slice cleanup");

    const logs = try allocator.alloc(Log, 2);
    logs[0] = Log{
        .address = ZERO_ADDRESS,
        .topics = topics1,
        .data = data1,
    };
    logs[1] = Log{
        .address = ZERO_ADDRESS,
        .topics = topics2,
        .data = data2,
    };

    // This should properly clean up all memory including individual log data
    CallResult.deinitLogsSlice(logs, allocator);
}
