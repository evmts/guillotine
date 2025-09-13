/// Creates a CallResult type specialized for the given EVM configuration.
/// This allows the CallResult structure to be adapted based on configuration
/// while maintaining backward compatibility with existing code.
pub fn CallResult(comptime config: anytype) type {
    // We can add config-specific customizations here in the future
    _ = config; // Currently unused but reserved for future enhancements
    
    return struct {
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
    /// Address of created contract (for CREATE/CREATE2 operations)
    created_address: ?Address = null,

    /// Create a successful call result
    pub fn success_with_output(gas_left: u64, output: []const u8) @This() {
        return @This(){
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
    pub fn success_empty(gas_left: u64) @This() {
        return @This(){
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
    pub fn failure(gas_left: u64) @This() {
        return @This(){
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
    pub fn failure_with_error(gas_left: u64, error_info: []const u8) @This() {
        return @This(){
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
    pub fn revert_with_data(gas_left: u64, revert_data: []const u8) @This() {
        return @This(){
            .success = false,
            .gas_left = gas_left,
            .output = revert_data,
            .logs = &.{},
            .selfdestructs = &.{},
            .accessed_addresses = &.{},
            .accessed_storage = &.{},
            .error_info = "execution reverted",
        };
    }

    /// Create a successful call result with output and logs
    pub fn success_with_logs(gas_left: u64, output: []const u8, logs: []const Log) @This() {
        return @This(){
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
    pub fn isSuccess(self: @This()) bool {
        return self.success;
    }

    /// Check if the call failed
    pub fn isFailure(self: @This()) bool {
        return !self.success;
    }

    /// Check if the call has output data
    pub fn hasOutput(self: @This()) bool {
        return self.output.len > 0;
    }

    /// Get the amount of gas consumed (assuming original_gas was provided)
    pub fn gasConsumed(self: @This(), original_gas: u64) u64 {
        if (self.gas_left > original_gas) return 0; // Sanity check
        return original_gas - self.gas_left;
    }

    /// Clean up all memory associated with logs
    /// Must be called when CallResult contains owned log data
    pub fn deinitLogs(self: *@This(), allocator: std.mem.Allocator) void {
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

    /// Clean up all allocated memory in the CallResult
    /// Call this when the CallResult contains owned data that needs to be freed
    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        // Free output buffer if it's allocated
        if (self.output.len > 0) {
            allocator.free(self.output);
        }
        
        // Free logs - always free if we have logs since they're allocated
        if (self.logs.len > 0) {
            for (self.logs) |log| {
                if (log.topics.len > 0) {
                    allocator.free(log.topics);
                }
                if (log.data.len > 0) {
                    allocator.free(log.data);
                }
            }
            allocator.free(self.logs);
        }
        
        // Free selfdestructs if allocated
        if (self.selfdestructs.len > 0) {
            allocator.free(self.selfdestructs);
        }
        
        // Free accessed_addresses if allocated
        if (self.accessed_addresses.len > 0) {
            allocator.free(self.accessed_addresses);
        }
        
        // Free accessed_storage if allocated
        if (self.accessed_storage.len > 0) {
            allocator.free(self.accessed_storage);
        }
        
        // Free trace if present
        if (self.trace) |*trace| {
            trace.deinit();
        }
        
        // Free error_info if present
        if (self.error_info) |info| {
            allocator.free(info);
        }
        
        // Reset all fields to empty slices
        self.output = &.{};
        self.logs = &.{};
        self.selfdestructs = &.{};
        self.accessed_addresses = &.{};
        self.accessed_storage = &.{};
        self.trace = null;
        self.error_info = null;
    }

    /// Create an owned copy of this CallResult
    /// All dynamically allocated data (output, logs, etc.) is duplicated
    /// The caller owns the returned result and must call deinit() when done
    pub fn toOwnedResult(self: @This(), allocator: std.mem.Allocator) !@This() {
        // Copy output data
        const output_copy = if (self.output.len > 0) 
            try allocator.dupe(u8, self.output) 
        else 
            &.{};
        errdefer if (output_copy.len > 0) allocator.free(output_copy);

        // Copy logs
        const logs_copy = if (self.logs.len > 0) blk: {
            const logs = try allocator.alloc(Log, self.logs.len);
            errdefer allocator.free(logs);
            
            var copied_count: usize = 0;
            errdefer {
                for (logs[0..copied_count]) |log| {
                    if (log.topics.len > 0) allocator.free(log.topics);
                    if (log.data.len > 0) allocator.free(log.data);
                }
            }
            
            for (self.logs, 0..) |log, i| {
                logs[i] = .{
                    .address = log.address,
                    .topics = if (log.topics.len > 0) 
                        try allocator.dupe(u256, log.topics) 
                    else 
                        &.{},
                    .data = if (log.data.len > 0) 
                        try allocator.dupe(u8, log.data) 
                    else 
                        &.{},
                };
                copied_count += 1;
            }
            break :blk logs;
        } else &.{};
        errdefer if (logs_copy.len > 0) {
            for (logs_copy) |log| {
                if (log.topics.len > 0) allocator.free(log.topics);
                if (log.data.len > 0) allocator.free(log.data);
            }
            allocator.free(logs_copy);
        };

        // Copy selfdestructs
        const selfdestructs_copy = if (self.selfdestructs.len > 0)
            try allocator.dupe(SelfDestructRecord, self.selfdestructs)
        else
            &.{};
        errdefer if (selfdestructs_copy.len > 0) allocator.free(selfdestructs_copy);

        // Copy accessed addresses
        const accessed_addresses_copy = if (self.accessed_addresses.len > 0)
            try allocator.dupe(Address, self.accessed_addresses)
        else
            &.{};
        errdefer if (accessed_addresses_copy.len > 0) allocator.free(accessed_addresses_copy);

        // Copy accessed storage
        const accessed_storage_copy = if (self.accessed_storage.len > 0)
            try allocator.dupe(StorageAccess, self.accessed_storage)
        else
            &.{};
        errdefer if (accessed_storage_copy.len > 0) allocator.free(accessed_storage_copy);

        // Copy error info
        const error_info_copy = if (self.error_info) |info|
            try allocator.dupe(u8, info)
        else
            null;
        errdefer if (error_info_copy) |info| allocator.free(info);

        // Copy trace if present
        const trace_copy = if (self.trace) |trace| blk: {
            const steps_copy = try allocator.alloc(TraceStep, trace.steps.len);
            errdefer allocator.free(steps_copy);
            
            var copied_steps: usize = 0;
            errdefer {
                for (steps_copy[0..copied_steps]) |*step| {
                    step.deinit(allocator);
                }
            }
            
            for (trace.steps, 0..) |step, i| {
                steps_copy[i] = .{
                    .pc = step.pc,
                    .opcode = step.opcode,
                    .opcode_name = try allocator.dupe(u8, step.opcode_name),
                    .gas = step.gas,
                    .depth = step.depth,
                    .mem_size = step.mem_size,
                    .gas_cost = step.gas_cost,
                    .stack = try allocator.dupe(u256, step.stack),
                    .memory = try allocator.dupe(u8, step.memory),
                    .storage_reads = try allocator.dupe(TraceStep.StorageRead, step.storage_reads),
                    .storage_writes = try allocator.dupe(TraceStep.StorageWrite, step.storage_writes),
                };
                copied_steps += 1;
            }
            
            break :blk ExecutionTrace{
                .steps = steps_copy,
                .allocator = allocator,
            };
        } else null;

        return @This(){
            .success = self.success,
            .gas_left = self.gas_left,
            .output = output_copy,
            .logs = logs_copy,
            .selfdestructs = selfdestructs_copy,
            .accessed_addresses = accessed_addresses_copy,
            .accessed_storage = accessed_storage_copy,
            .trace = trace_copy,
            .error_info = error_info_copy,
            .created_address = self.created_address,
        };
    }
    };
}

const std = @import("std");
const primitives = @import("primitives");
const Address = primitives.Address;
const ZERO_ADDRESS = primitives.ZERO_ADDRESS;

// Default configuration for backward compatibility and tests
const default_config = struct {};
const DefaultCallResult = CallResult(default_config);

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
    /// Depth of the call at this step (JSON-RPC compatibility)
    depth: u32 = 0,
    stack: []const u256,
    memory: []const u8,
    /// Memory size at this step (JSON-RPC compatibility)
    mem_size: u32 = 0,
    /// Gas cost of this step (JSON-RPC compatibility)
    gas_cost: u64 = 0,
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
    const result = DefaultCallResult.success_with_output(15000, output_data);

    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(u64, 15000), result.gas_left);
    try std.testing.expectEqualSlices(u8, output_data, result.output);
    try std.testing.expect(result.isSuccess());
    try std.testing.expect(!result.isFailure());
    try std.testing.expect(result.hasOutput());
}

test "call result success empty" {
    const result = DefaultCallResult.success_empty(8000);

    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(u64, 8000), result.gas_left);
    try std.testing.expectEqual(@as(usize, 0), result.output.len);
    try std.testing.expect(result.isSuccess());
    try std.testing.expect(!result.isFailure());
    try std.testing.expect(!result.hasOutput());
}

test "call result failure" {
    const result = DefaultCallResult.failure(500);

    try std.testing.expect(!result.success);
    try std.testing.expectEqual(@as(u64, 500), result.gas_left);
    try std.testing.expectEqual(@as(usize, 0), result.output.len);
    try std.testing.expect(!result.isSuccess());
    try std.testing.expect(result.isFailure());
    try std.testing.expect(!result.hasOutput());
}

test "call result revert with data" {
    const revert_data = "Error: insufficient balance";
    const result = DefaultCallResult.revert_with_data(3000, revert_data);

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
    const success_result = DefaultCallResult.success_empty(18500);
    try std.testing.expectEqual(@as(u64, 2500), success_result.gasConsumed(original_gas));

    // Failed call that consumed most gas
    const failed_result = DefaultCallResult.failure(100);
    try std.testing.expectEqual(@as(u64, 20900), failed_result.gasConsumed(original_gas));

    // Edge case: gas_left equals original_gas (no consumption)
    const no_consumption = DefaultCallResult.success_empty(original_gas);
    try std.testing.expectEqual(@as(u64, 0), no_consumption.gasConsumed(original_gas));

    // Edge case: gas_left > original_gas (invalid state)
    const invalid_result = DefaultCallResult.success_empty(25000);
    try std.testing.expectEqual(@as(u64, 0), invalid_result.gasConsumed(original_gas));
}

test "call result state checks" {
    // Success cases
    const success1 = DefaultCallResult.success_empty(1000);
    try std.testing.expect(success1.isSuccess());
    try std.testing.expect(!success1.isFailure());

    const success2 = DefaultCallResult.success_with_output(2000, &[_]u8{0xff});
    try std.testing.expect(success2.isSuccess());
    try std.testing.expect(!success2.isFailure());

    // Failure cases
    const failure1 = DefaultCallResult.failure(500);
    try std.testing.expect(!failure1.isSuccess());
    try std.testing.expect(failure1.isFailure());

    const failure2 = DefaultCallResult.revert_with_data(300, "revert reason");
    try std.testing.expect(!failure2.isSuccess());
    try std.testing.expect(failure2.isFailure());
}

test "call result output checks" {
    // No output cases
    const empty1 = DefaultCallResult.success_empty(1000);
    try std.testing.expect(!empty1.hasOutput());

    const empty2 = DefaultCallResult.failure(500);
    try std.testing.expect(!empty2.hasOutput());

    // With output cases
    const with_output1 = DefaultCallResult.success_with_output(2000, &[_]u8{0x42});
    try std.testing.expect(with_output1.hasOutput());

    const with_output2 = DefaultCallResult.revert_with_data(300, "error message");
    try std.testing.expect(with_output2.hasOutput());
}

test "call result edge cases" {
    // Zero gas left
    const zero_gas = DefaultCallResult.success_empty(0);
    try std.testing.expect(zero_gas.isSuccess());
    try std.testing.expectEqual(@as(u64, 0), zero_gas.gas_left);
    try std.testing.expectEqual(@as(u64, 21000), zero_gas.gasConsumed(21000));

    // Maximum gas left
    const max_gas = DefaultCallResult.success_empty(std.math.maxInt(u64));
    try std.testing.expectEqual(std.math.maxInt(u64), max_gas.gas_left);
    try std.testing.expectEqual(@as(u64, 0), max_gas.gasConsumed(std.math.maxInt(u64)));

    // Large output data
    const large_output = &[_]u8{0xaa} ** 10000;
    const large_result = DefaultCallResult.success_with_output(5000, large_output);
    try std.testing.expect(large_result.hasOutput());
    try std.testing.expectEqual(@as(usize, 10000), large_result.output.len);

    // Empty revert data (still counts as having output)
    const empty_revert = DefaultCallResult.revert_with_data(1000, &[_]u8{});
    try std.testing.expect(!empty_revert.hasOutput());
    try std.testing.expect(empty_revert.isFailure());
}

test "DefaultCallResult log memory management - proper cleanup" {
    const testing = std.testing;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) {
            const log = @import("../log.zig");
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
    var call_result = DefaultCallResult.success_with_logs(50000, &[_]u8{}, logs);

    // This should properly clean up all allocated memory
    call_result.deinitLogs(allocator);
}

test "DefaultCallResult deinitLogsSlice - memory management for takeLogs result" {
    const testing = std.testing;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) {
            const log = @import("../log.zig");
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
    DefaultCallResult.deinitLogsSlice(logs, allocator);
}

test "call result failure with error info" {
    const error_message = "Contract execution reverted";
    const result = DefaultCallResult.failure_with_error(1500, error_message);

    try std.testing.expect(!result.success);
    try std.testing.expectEqual(@as(u64, 1500), result.gas_left);
    try std.testing.expect(result.isFailure());
    try std.testing.expect(!result.isSuccess());
    try std.testing.expect(!result.hasOutput());
    try std.testing.expectEqualSlices(u8, error_message, result.error_info.?);
}

test "call result success with logs" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const topics = try allocator.dupe(u256, &[_]u256{ 0x1234567890ABCDEF, 0xFEDCBA0987654321 });
    defer allocator.free(topics);
    const data = try allocator.dupe(u8, "test event data");
    defer allocator.free(data);

    const logs = try allocator.alloc(Log, 1);
    defer allocator.free(logs);
    logs[0] = Log{
        .address = .{ .bytes = [_]u8{0x42} ++ [_]u8{0} ** 19 },
        .topics = topics,
        .data = data,
    };

    const output_data = &[_]u8{ 0xAA, 0xBB, 0xCC };
    const result = DefaultCallResult.success_with_logs(12000, output_data, logs);

    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(u64, 12000), result.gas_left);
    try std.testing.expectEqualSlices(u8, output_data, result.output);
    try std.testing.expectEqual(@as(usize, 1), result.logs.len);
    try std.testing.expectEqual(Address{ .bytes = [_]u8{0x42} ++ [_]u8{0} ** 19 }, result.logs[0].address);
    try std.testing.expectEqual(@as(usize, 2), result.logs[0].topics.len);
    try std.testing.expectEqual(@as(u256, 0x1234567890ABCDEF), result.logs[0].topics[0]);
    try std.testing.expectEqual(@as(u256, 0xFEDCBA0987654321), result.logs[0].topics[1]);
    try std.testing.expectEqualSlices(u8, "test event data", result.logs[0].data);
}

test "call result struct field defaults" {
    // Test that default fields are correctly initialized
    const result = DefaultCallResult.success_empty(5000);

    try std.testing.expectEqual(@as(usize, 0), result.logs.len);
    try std.testing.expectEqual(@as(usize, 0), result.selfdestructs.len);
    try std.testing.expectEqual(@as(usize, 0), result.accessed_addresses.len);
    try std.testing.expectEqual(@as(usize, 0), result.accessed_storage.len);
    try std.testing.expectEqual(@as(?ExecutionTrace, null), result.trace);
    try std.testing.expectEqual(@as(?[]const u8, null), result.error_info);
}

test "call result with self destructs" {
    var selfdestructs = [_]SelfDestructRecord{
        SelfDestructRecord{
            .contract = .{ .bytes = [_]u8{0x11} ++ [_]u8{0} ** 19 },
            .beneficiary = .{ .bytes = [_]u8{0x22} ++ [_]u8{0} ** 19 },
        },
        SelfDestructRecord{
            .contract = .{ .bytes = [_]u8{0x33} ++ [_]u8{0} ** 19 },
            .beneficiary = .{ .bytes = [_]u8{0x44} ++ [_]u8{0} ** 19 },
        },
    };

    var result = DefaultCallResult.success_empty(8000);
    result.selfdestructs = &selfdestructs;

    try std.testing.expectEqual(@as(usize, 2), result.selfdestructs.len);
    try std.testing.expectEqual(Address{ .bytes = [_]u8{0x11} ++ [_]u8{0} ** 19 }, result.selfdestructs[0].contract);
    try std.testing.expectEqual(Address{ .bytes = [_]u8{0x22} ++ [_]u8{0} ** 19 }, result.selfdestructs[0].beneficiary);
    try std.testing.expectEqual(Address{ .bytes = [_]u8{0x33} ++ [_]u8{0} ** 19 }, result.selfdestructs[1].contract);
    try std.testing.expectEqual(Address{ .bytes = [_]u8{0x44} ++ [_]u8{0} ** 19 }, result.selfdestructs[1].beneficiary);
}

test "call result with accessed addresses" {
    var accessed_addresses = [_]Address{
        .{ .bytes = [_]u8{0xAA} ++ [_]u8{0} ** 19 },
        .{ .bytes = [_]u8{0xBB} ++ [_]u8{0} ** 19 },
        .{ .bytes = [_]u8{0xCC} ++ [_]u8{0} ** 19 },
    };

    var result = DefaultCallResult.failure(200);
    result.accessed_addresses = &accessed_addresses;

    try std.testing.expectEqual(@as(usize, 3), result.accessed_addresses.len);
    try std.testing.expectEqual(Address{ .bytes = [_]u8{0xAA} ++ [_]u8{0} ** 19 }, result.accessed_addresses[0]);
    try std.testing.expectEqual(Address{ .bytes = [_]u8{0xBB} ++ [_]u8{0} ** 19 }, result.accessed_addresses[1]);
    try std.testing.expectEqual(Address{ .bytes = [_]u8{0xCC} ++ [_]u8{0} ** 19 }, result.accessed_addresses[2]);
}

test "call result with accessed storage" {
    var accessed_storage = [_]StorageAccess{
        StorageAccess{
            .address = .{ .bytes = [_]u8{0x11} ++ [_]u8{0} ** 19 },
            .slot = 0x1234,
        },
        StorageAccess{
            .address = .{ .bytes = [_]u8{0x22} ++ [_]u8{0} ** 19 },
            .slot = 0xABCDEF,
        },
    };

    var result = DefaultCallResult.success_empty(9500);
    result.accessed_storage = &accessed_storage;

    try std.testing.expectEqual(@as(usize, 2), result.accessed_storage.len);
    try std.testing.expectEqual(Address{ .bytes = [_]u8{0x11} ++ [_]u8{0} ** 19 }, result.accessed_storage[0].address);
    try std.testing.expectEqual(@as(u256, 0x1234), result.accessed_storage[0].slot);
    try std.testing.expectEqual(Address{ .bytes = [_]u8{0x22} ++ [_]u8{0} ** 19 }, result.accessed_storage[1].address);
    try std.testing.expectEqual(@as(u256, 0xABCDEF), result.accessed_storage[1].slot);
}

test "execution trace basic functionality" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var trace = ExecutionTrace.init(allocator);
    defer trace.deinit();

    try std.testing.expectEqual(@as(usize, 0), trace.steps.len);

    // Test empty trace
    var empty_trace = ExecutionTrace.empty(allocator);
    defer empty_trace.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty_trace.steps.len);
}

test "trace step memory management" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var step = TraceStep{
        .pc = 42,
        .opcode = 0x60,
        .opcode_name = try allocator.dupe(u8, "PUSH1"),
        .gas = 21000,
        .stack = try allocator.dupe(u256, &[_]u256{ 0x123, 0x456 }),
        .memory = try allocator.dupe(u8, &[_]u8{ 0xAA, 0xBB, 0xCC }),
        .storage_reads = &.{},
        .storage_writes = &.{},
    };
    var reads = try allocator.alloc(TraceStep.StorageRead, 1);
    reads[0] = TraceStep.StorageRead{ .address = ZERO_ADDRESS, .slot = 0x100, .value = 0x200 };
    var writes = try allocator.alloc(TraceStep.StorageWrite, 1);
    writes[0] = TraceStep.StorageWrite{ .address = .{ .bytes = [_]u8{0x11} ++ [_]u8{0} ** 19 }, .slot = 0x300, .old_value = 0x400, .new_value = 0x500 };
    step.storage_reads = reads;
    step.storage_writes = writes;

    // Verify step contents
    try std.testing.expectEqual(@as(u32, 42), step.pc);
    try std.testing.expectEqual(@as(u8, 0x60), step.opcode);
    try std.testing.expectEqualSlices(u8, "PUSH1", step.opcode_name);
    try std.testing.expectEqual(@as(u64, 21000), step.gas);
    try std.testing.expectEqual(@as(usize, 2), step.stack.len);
    try std.testing.expectEqual(@as(u256, 0x123), step.stack[0]);
    try std.testing.expectEqual(@as(u256, 0x456), step.stack[1]);
    try std.testing.expectEqual(@as(usize, 3), step.memory.len);
    try std.testing.expectEqual(@as(u8, 0xAA), step.memory[0]);

    // Test storage operations
    try std.testing.expectEqual(@as(usize, 1), step.storage_reads.len);
    try std.testing.expectEqual(ZERO_ADDRESS, step.storage_reads[0].address);
    try std.testing.expectEqual(@as(u256, 0x100), step.storage_reads[0].slot);
    try std.testing.expectEqual(@as(u256, 0x200), step.storage_reads[0].value);

    try std.testing.expectEqual(@as(usize, 1), step.storage_writes.len);
    try std.testing.expectEqual(Address{ .bytes = [_]u8{0x11} ++ [_]u8{0} ** 19 }, step.storage_writes[0].address);
    try std.testing.expectEqual(@as(u256, 0x300), step.storage_writes[0].slot);
    try std.testing.expectEqual(@as(u256, 0x400), step.storage_writes[0].old_value);
    try std.testing.expectEqual(@as(u256, 0x500), step.storage_writes[0].new_value);

    // This should properly clean up all memory
    step.deinit(allocator);
}

test "call result gas consumption edge cases" {
    // Test integer overflow protection
    const result1 = DefaultCallResult.success_empty(std.math.maxInt(u64));
    try std.testing.expectEqual(@as(u64, 0), result1.gasConsumed(1000));

    // Test maximum possible consumption
    const result2 = DefaultCallResult.success_empty(0);
    try std.testing.expectEqual(std.math.maxInt(u64), result2.gasConsumed(std.math.maxInt(u64)));

    // Test exact consumption
    const result3 = DefaultCallResult.failure(12345);
    try std.testing.expectEqual(@as(u64, 8655), result3.gasConsumed(21000));
}

test "call result comprehensive constructor coverage" {
    // Test all constructor methods
    const constructors = [_]DefaultCallResult{
        DefaultCallResult.success_with_output(1000, &[_]u8{0x01}),
        DefaultCallResult.success_empty(2000),
        DefaultCallResult.failure(3000),
        DefaultCallResult.failure_with_error(4000, "test error"),
        DefaultCallResult.revert_with_data(5000, "revert reason"),
        DefaultCallResult.success_with_logs(6000, &[_]u8{0x02}, &[_]Log{}),
    };

    // Verify all constructors work properly
    for (constructors) |result| {
        _ = result.isSuccess();
        _ = result.isFailure();
        _ = result.hasOutput();
        _ = result.gasConsumed(10000);
    }
}

test "call result empty logs slice cleanup" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Test cleanup of empty logs slice
    const empty_logs = try allocator.alloc(Log, 0);
    DefaultCallResult.deinitLogsSlice(empty_logs, allocator);

    // Should not crash or leak
}

test "log struct comprehensive" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Test log with maximum topics (typically 4 in EVM)
    const topics = try allocator.dupe(u256, &[_]u256{ 
        0x1111111111111111,
        0x2222222222222222, 
        0x3333333333333333,
        0x4444444444444444
    });
    defer allocator.free(topics);

    const data = try allocator.dupe(u8, "This is a comprehensive test of log data with various characters: !@#$%^&*()");
    defer allocator.free(data);

    const log = Log{
        .address = Address{ .bytes = [_]u8{0xDE, 0xAD, 0xBE, 0xEF} ++ [_]u8{0xCA, 0xFE, 0xBA, 0xBE} ++ [_]u8{0x12, 0x34, 0x56, 0x78} ++ [_]u8{0x9A, 0xBC, 0xDE, 0xF0} ++ [_]u8{0x11, 0x22, 0x33, 0x44} },
        .topics = topics,
        .data = data,
    };

    try std.testing.expectEqual(@as(usize, 4), log.topics.len);
    try std.testing.expectEqual(@as(u256, 0x1111111111111111), log.topics[0]);
    try std.testing.expect(std.mem.startsWith(u8, log.data, "This is a comprehensive test"));
}

test "storage access and self destruct comprehensive" {
    // Test boundary values for StorageAccess
    const storage1 = StorageAccess{
        .address = ZERO_ADDRESS,
        .slot = 0,
    };
    const storage2 = StorageAccess{
        .address = .{ .bytes = [_]u8{0xFF} ** 20 },
        .slot = std.math.maxInt(u256),
    };

    try std.testing.expectEqual(ZERO_ADDRESS, storage1.address);
    try std.testing.expectEqual(@as(u256, 0), storage1.slot);
    try std.testing.expectEqual(Address{ .bytes = [_]u8{0xFF} ** 20 }, storage2.address);
    try std.testing.expectEqual(std.math.maxInt(u256), storage2.slot);

    // Test boundary values for SelfDestructRecord
    const selfdestruct1 = SelfDestructRecord{
        .contract = ZERO_ADDRESS,
        .beneficiary = ZERO_ADDRESS,
    };
    const selfdestruct2 = SelfDestructRecord{
        .contract = Address{ .bytes = [_]u8{0xFF} ** 20 },
        .beneficiary = Address{ .bytes = [_]u8{0xAA} ** 20 },
    };

    try std.testing.expectEqual(ZERO_ADDRESS, selfdestruct1.contract);
    try std.testing.expectEqual(ZERO_ADDRESS, selfdestruct1.beneficiary);
    try std.testing.expectEqual(Address{ .bytes = [_]u8{0xFF} ** 20 }, selfdestruct2.contract);
    try std.testing.expectEqual(Address{ .bytes = [_]u8{0xAA} ** 20 }, selfdestruct2.beneficiary);
}

test "call result toOwnedResult basic" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test with simple success result
    const original = DefaultCallResult.success_with_output(5000, "test output");
    const owned = try original.toOwnedResult(allocator);
    defer {
        var mutable_owned = owned;
        mutable_owned.deinit(allocator);
    }

    try testing.expect(owned.success);
    try testing.expectEqual(@as(u64, 5000), owned.gas_left);
    try testing.expectEqualSlices(u8, "test output", owned.output);
    
    // Verify it's a copy (different memory address)
    if (original.output.len > 0) {
        try testing.expect(original.output.ptr != owned.output.ptr);
    }
}

test "call result toOwnedResult with logs" {
    const testing = std.testing;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create logs
    const topics = try allocator.dupe(u256, &[_]u256{ 0x1234, 0x5678 });
    defer allocator.free(topics);
    const data = try allocator.dupe(u8, "log data");
    defer allocator.free(data);

    const logs = try allocator.alloc(Log, 1);
    defer allocator.free(logs);
    logs[0] = Log{
        .address = .{ .bytes = [_]u8{0x42} ++ [_]u8{0} ** 19 },
        .topics = topics,
        .data = data,
    };

    const original = DefaultCallResult.success_with_logs(3000, "output", logs);
    const owned = try original.toOwnedResult(allocator);
    defer {
        var mutable_owned = owned;
        mutable_owned.deinit(allocator);
    }

    try testing.expectEqual(@as(usize, 1), owned.logs.len);
    try testing.expectEqual(@as(usize, 2), owned.logs[0].topics.len);
    try testing.expectEqualSlices(u8, "log data", owned.logs[0].data);
    
    // Verify deep copy
    try testing.expect(original.logs.ptr != owned.logs.ptr);
    if (original.logs.len > 0) {
        try testing.expect(original.logs[0].topics.ptr != owned.logs[0].topics.ptr);
        try testing.expect(original.logs[0].data.ptr != owned.logs[0].data.ptr);
    }
}

test "call result toOwnedResult empty result" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const original = DefaultCallResult.success_empty(1000);
    const owned = try original.toOwnedResult(allocator);
    defer {
        var mutable_owned = owned;
        mutable_owned.deinit(allocator);
    }

    try testing.expect(owned.success);
    try testing.expectEqual(@as(u64, 1000), owned.gas_left);
    try testing.expectEqual(@as(usize, 0), owned.output.len);
    try testing.expectEqual(@as(usize, 0), owned.logs.len);
}

test "call result toOwnedResult with error info" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const original = DefaultCallResult.failure_with_error(500, "error message");
    const owned = try original.toOwnedResult(allocator);
    defer {
        var mutable_owned = owned;
        mutable_owned.deinit(allocator);
    }

    try testing.expect(!owned.success);
    try testing.expectEqual(@as(u64, 500), owned.gas_left);
    try testing.expectEqualSlices(u8, "error message", owned.error_info.?);
    
    // Verify it's a copy
    if (original.error_info) |info| {
        try testing.expect(info.ptr != owned.error_info.?.ptr);
    }
}

test "call result toOwnedResult with all fields" {
    const testing = std.testing;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create a result with all fields populated
    var result = DefaultCallResult.success_with_output(2500, "test output");
    
    // Add logs
    const topics = try allocator.dupe(u256, &[_]u256{0xABCD});
    defer allocator.free(topics);
    const log_data = try allocator.dupe(u8, "event");
    defer allocator.free(log_data);
    const logs = try allocator.alloc(Log, 1);
    defer allocator.free(logs);
    logs[0] = Log{
        .address = .{ .bytes = [_]u8{0x11} ++ [_]u8{0} ** 19 },
        .topics = topics,
        .data = log_data,
    };
    result.logs = logs;
    
    // Add selfdestructs
    const selfdestructs = try allocator.alloc(SelfDestructRecord, 1);
    defer allocator.free(selfdestructs);
    selfdestructs[0] = .{
        .contract = .{ .bytes = [_]u8{0x22} ++ [_]u8{0} ** 19 },
        .beneficiary = .{ .bytes = [_]u8{0x33} ++ [_]u8{0} ** 19 },
    };
    result.selfdestructs = selfdestructs;
    
    // Add accessed addresses
    const addresses = try allocator.alloc(Address, 2);
    defer allocator.free(addresses);
    addresses[0] = .{ .bytes = [_]u8{0x44} ++ [_]u8{0} ** 19 };
    addresses[1] = .{ .bytes = [_]u8{0x55} ++ [_]u8{0} ** 19 };
    result.accessed_addresses = addresses;
    
    // Add accessed storage
    const storage = try allocator.alloc(StorageAccess, 1);
    defer allocator.free(storage);
    storage[0] = .{
        .address = .{ .bytes = [_]u8{0x66} ++ [_]u8{0} ** 19 },
        .slot = 0x100,
    };
    result.accessed_storage = storage;
    
    // Add created address
    result.created_address = .{ .bytes = [_]u8{0x77} ++ [_]u8{0} ** 19 };
    
    // Create owned copy
    const owned = try result.toOwnedResult(allocator);
    defer {
        var mutable_owned = owned;
        mutable_owned.deinit(allocator);
    }
    
    // Verify all fields were copied
    try testing.expectEqualSlices(u8, "test output", owned.output);
    try testing.expectEqual(@as(usize, 1), owned.logs.len);
    try testing.expectEqual(@as(usize, 1), owned.selfdestructs.len);
    try testing.expectEqual(@as(usize, 2), owned.accessed_addresses.len);
    try testing.expectEqual(@as(usize, 1), owned.accessed_storage.len);
    try testing.expectEqual(Address{ .bytes = [_]u8{0x77} ++ [_]u8{0} ** 19 }, owned.created_address.?);
    
    // Verify deep copies
    try testing.expect(result.output.ptr != owned.output.ptr);
    try testing.expect(result.logs.ptr != owned.logs.ptr);
    try testing.expect(result.selfdestructs.ptr != owned.selfdestructs.ptr);
    try testing.expect(result.accessed_addresses.ptr != owned.accessed_addresses.ptr);
    try testing.expect(result.accessed_storage.ptr != owned.accessed_storage.ptr);
}
