pub fn CallResult(config: anytype) type {
    // We can add config-specific customizations here in the future
    _ = config; // Currently unused but reserved for future enhancements

    return struct {
        const Self = @This();

        success: bool,
        gas_left: u64,
        output: []const u8,
        logs: []const Log = &.{},
        selfdestructs: []const SelfDestructRecord = &.{},
        accessed_addresses: []const Address = &.{},
        accessed_storage: []const StorageAccess = &.{},
        trace: ?ExecutionTrace = null,
        error_info: ?[]const u8 = null,
        created_address: ?Address = null,
        /// True when the frame ended with REVERT. A failed result that is not
        /// reverted is an exceptional halt (out of gas, invalid opcode, ...) or was
        /// never executed. Gas left does not tell the two apart: `REVERT(0, 0)` can
        /// end with no gas left, and a refused call can hand all of its gas back.
        reverted: bool = false,

        pub fn success_with_output(allocator: std.mem.Allocator, gas_left: u64, output: []const u8) !Self {
            return Self{
                .success = true,
                .gas_left = gas_left,
                .output = if (output.len > 0) try allocator.dupe(u8, output) else &.{},
            };
        }

        /// Successful result that takes `output` as it is, without copying it.
        ///
        /// For the interpreter: RETURN has already copied its output range into
        /// the call arena, and every nested result lives there until the
        /// transaction ends, so a second arena copy buys nothing. The result does
        /// not own `output`; it must not be passed to `deinit`. A result handed to
        /// a host goes through `toOwnedResult`, which makes the host's own copy.
        pub fn success_adopting(gas_left: u64, output: []const u8) Self {
            return Self{ .success = true, .gas_left = gas_left, .output = output };
        }

        /// Reverted result that takes `revert_data` as it is, without copying it.
        /// Ownership is as for `success_adopting`.
        pub fn revert_adopting(gas_left: u64, revert_data: []const u8) Self {
            return Self{ .success = false, .gas_left = gas_left, .output = revert_data, .reverted = true };
        }

        /// Failed result with no output. Allocates nothing, so it cannot fail.
        pub fn failed(gas_left: u64) Self {
            return Self{ .success = false, .gas_left = gas_left, .output = &.{} };
        }

        /// Successful result with no output. Allocates nothing, so it cannot fail.
        pub fn succeeded_empty(gas_left: u64) Self {
            return Self{ .success = true, .gas_left = gas_left, .output = &.{} };
        }

        pub fn success_empty(allocator: std.mem.Allocator, gas_left: u64) !Self {
            _ = allocator; // Nothing is allocated for an empty result
            return succeeded_empty(gas_left);
        }

        pub fn failure(allocator: std.mem.Allocator, gas_left: u64) !Self {
            _ = allocator; // Nothing is allocated for an empty result
            return failed(gas_left);
        }

        /// Create a failed call result with error info. On error nothing is left
        /// allocated.
        pub fn failure_with_error(allocator: std.mem.Allocator, gas_left: u64, error_info: []const u8) !Self {
            var result = failed(gas_left);
            result.error_info = try allocator.dupe(u8, error_info);
            return result;
        }

        /// Create a reverted call result with revert data
        pub fn revert_with_data(allocator: std.mem.Allocator, gas_left: u64, revert_data: []const u8) !Self {
            return Self{
                .success = false,
                .gas_left = gas_left,
                .output = if (revert_data.len > 0) try allocator.dupe(u8, revert_data) else &.{},
                .reverted = true,
            };
        }

        /// Create a successful call result that owns deep copies of `output` and
        /// `logs`. On error nothing is left allocated.
        pub fn success_with_logs(
            allocator: std.mem.Allocator,
            gas_left: u64,
            output: []const u8,
            logs: []const Log,
        ) !Self {
            const output_copy = try allocator.dupe(u8, output);
            errdefer allocator.free(output_copy);
            const logs_copy = try cloneLogs(allocator, logs);
            return Self{
                .success = true,
                .gas_left = gas_left,
                .output = output_copy,
                .logs = logs_copy,
            };
        }

        /// Check if the call succeeded
        pub fn isSuccess(self: Self) bool {
            return self.success;
        }

        /// Check if the call failed
        pub fn isFailure(self: Self) bool {
            return !self.success;
        }

        /// Check if the call ended with REVERT (as opposed to an exceptional halt)
        pub fn isRevert(self: Self) bool {
            return !self.success and self.reverted;
        }

        /// Check if the call has output data
        pub fn hasOutput(self: Self) bool {
            return self.output.len > 0;
        }

        /// Get the amount of gas consumed (assuming original_gas was provided)
        pub fn gasConsumed(self: Self, original_gas: u64) u64 {
            if (self.gas_left > original_gas) return 0; // Sanity check
            return original_gas - self.gas_left;
        }

        /// Clean up all memory associated with logs
        /// Must be called when CallResult contains owned log data
        pub fn deinitLogs(self: *Self, allocator: std.mem.Allocator) void {
            freeLogs(allocator, self.logs);
            self.logs = &.{};
        }

        /// Clean up memory for a logs slice returned by takeLogs()
        /// Use this when you have logs from takeLogs() instead of a full CallResult
        pub fn deinitLogsSlice(logs: []const Log, allocator: std.mem.Allocator) void {
            freeLogs(allocator, logs);
        }

        /// Clean up all allocated memory in the CallResult.
        /// The result must own all of its data, allocated with `allocator`
        /// (a result of `toOwnedResult` does). Empty slices own nothing and are
        /// safe to free.
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            allocator.free(self.output);
            freeLogs(allocator, self.logs);
            allocator.free(self.selfdestructs);
            allocator.free(self.accessed_addresses);
            allocator.free(self.accessed_storage);
            if (self.trace) |*trace| trace.deinit();
            if (self.error_info) |info| allocator.free(info);
            self.* = undefined;
        }

        /// Create an owned copy of this CallResult
        /// All dynamically allocated data (output, logs, etc.) is duplicated
        /// The caller owns the returned result and must call deinit() when done.
        /// On error nothing is left allocated: every copy made so far is freed.
        pub fn toOwnedResult(self: Self, allocator: std.mem.Allocator) !Self {
            const output_copy = try allocator.dupe(u8, self.output);
            errdefer allocator.free(output_copy);

            const logs_copy = try cloneLogs(allocator, self.logs);
            errdefer freeLogs(allocator, logs_copy);

            const selfdestructs_copy = try allocator.dupe(SelfDestructRecord, self.selfdestructs);
            errdefer allocator.free(selfdestructs_copy);

            const accessed_addresses_copy = try allocator.dupe(Address, self.accessed_addresses);
            errdefer allocator.free(accessed_addresses_copy);

            const accessed_storage_copy = try allocator.dupe(StorageAccess, self.accessed_storage);
            errdefer allocator.free(accessed_storage_copy);

            const error_info_copy: ?[]const u8 = if (self.error_info) |info| try allocator.dupe(u8, info) else null;
            errdefer if (error_info_copy) |info| allocator.free(info);

            // Last allocation: nothing after it can fail, so it needs no cleanup here.
            const trace_copy: ?ExecutionTrace = if (self.trace) |trace| try trace.clone(allocator) else null;

            return Self{
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
                .reverted = self.reverted,
            };
        }
    };
}

const std = @import("std");
const primitives = @import("voltaire");
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

/// Deep copy of one log. On error nothing is left allocated.
pub fn cloneLog(allocator: std.mem.Allocator, log: Log) std.mem.Allocator.Error!Log {
    const topics = try allocator.dupe(u256, log.topics);
    errdefer allocator.free(topics);
    const data = try allocator.dupe(u8, log.data);
    return .{ .address = log.address, .topics = topics, .data = data };
}

/// Deep copy of `logs`. Only the logs copied so far are ever freed on error: the
/// rest of the new slice is uninitialized and is never read.
pub fn cloneLogs(allocator: std.mem.Allocator, logs: []const Log) std.mem.Allocator.Error![]Log {
    const copies = try allocator.alloc(Log, logs.len);
    var copied_logs: usize = 0;
    errdefer {
        for (copies[0..copied_logs]) |copy| {
            allocator.free(copy.topics);
            allocator.free(copy.data);
        }
        allocator.free(copies);
    }
    for (logs) |log| {
        copies[copied_logs] = try cloneLog(allocator, log);
        copied_logs += 1;
    }
    return copies;
}

/// Free logs made by `cloneLogs`, with the allocator that made them.
pub fn freeLogs(allocator: std.mem.Allocator, logs: []const Log) void {
    for (logs) |log| {
        allocator.free(log.topics);
        allocator.free(log.data);
    }
    allocator.free(logs);
}

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

    /// Deep copy of the step. On error nothing is left allocated: each field is
    /// released if a later one cannot be copied.
    pub fn clone(self: TraceStep, allocator: std.mem.Allocator) std.mem.Allocator.Error!TraceStep {
        const opcode_name = try allocator.dupe(u8, self.opcode_name);
        errdefer allocator.free(opcode_name);
        const stack = try allocator.dupe(u256, self.stack);
        errdefer allocator.free(stack);
        const memory = try allocator.dupe(u8, self.memory);
        errdefer allocator.free(memory);
        const storage_reads = try allocator.dupe(StorageRead, self.storage_reads);
        errdefer allocator.free(storage_reads);
        const storage_writes = try allocator.dupe(StorageWrite, self.storage_writes);
        return .{
            .pc = self.pc,
            .opcode = self.opcode,
            .opcode_name = opcode_name,
            .gas = self.gas,
            .depth = self.depth,
            .stack = stack,
            .memory = memory,
            .mem_size = self.mem_size,
            .gas_cost = self.gas_cost,
            .storage_reads = storage_reads,
            .storage_writes = storage_writes,
        };
    }

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

    /// Deep copy of the trace, owned by `allocator`. Only the steps copied so far
    /// are freed on error.
    pub fn clone(self: ExecutionTrace, allocator: std.mem.Allocator) std.mem.Allocator.Error!ExecutionTrace {
        const steps = try allocator.alloc(TraceStep, self.steps.len);
        var copied_steps: usize = 0;
        errdefer {
            for (steps[0..copied_steps]) |*step| step.deinit(allocator);
            allocator.free(steps);
        }
        for (self.steps) |step| {
            steps[copied_steps] = try step.clone(allocator);
            copied_steps += 1;
        }
        return .{ .steps = steps, .allocator = allocator };
    }

    /// A trace with no steps.
    pub fn empty(allocator: std.mem.Allocator) ExecutionTrace {
        return ExecutionTrace{
            .steps = &.{},
            .allocator = allocator,
        };
    }
};

test "call result success creation" {
    const output_data = &[_]u8{ 0x01, 0x02, 0x03, 0x04 };
    var result = try DefaultCallResult.success_with_output(std.testing.allocator, 15000, output_data);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(u64, 15000), result.gas_left);
    try std.testing.expectEqualSlices(u8, output_data, result.output);
    try std.testing.expect(result.isSuccess());
    try std.testing.expect(!result.isFailure());
    try std.testing.expect(result.hasOutput());
}

test "call result success empty" {
    const result = try DefaultCallResult.success_empty(std.testing.allocator, 8000);

    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(u64, 8000), result.gas_left);
    try std.testing.expectEqual(@as(usize, 0), result.output.len);
    try std.testing.expect(result.isSuccess());
    try std.testing.expect(!result.isFailure());
    try std.testing.expect(!result.hasOutput());
}

test "call result failure" {
    const result = try DefaultCallResult.failure(std.testing.allocator, 500);

    try std.testing.expect(!result.success);
    try std.testing.expectEqual(@as(u64, 500), result.gas_left);
    try std.testing.expectEqual(@as(usize, 0), result.output.len);
    try std.testing.expect(!result.isSuccess());
    try std.testing.expect(result.isFailure());
    try std.testing.expect(!result.hasOutput());
}

test "call result revert with data" {
    const revert_data = "Error: insufficient balance";
    var result = try DefaultCallResult.revert_with_data(std.testing.allocator, 3000, revert_data);
    defer result.deinit(std.testing.allocator);

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
    const success_result = try DefaultCallResult.success_empty(std.testing.allocator, 18500);
    try std.testing.expectEqual(@as(u64, 2500), success_result.gasConsumed(original_gas));

    // Failed call that consumed most gas
    const failed_result = try DefaultCallResult.failure(std.testing.allocator, 100);
    try std.testing.expectEqual(@as(u64, 20900), failed_result.gasConsumed(original_gas));

    // Edge case: gas_left equals original_gas (no consumption)
    const no_consumption = try DefaultCallResult.success_empty(std.testing.allocator, original_gas);
    try std.testing.expectEqual(@as(u64, 0), no_consumption.gasConsumed(original_gas));

    // Edge case: gas_left > original_gas (invalid state)
    const invalid_result = try DefaultCallResult.success_empty(std.testing.allocator, 25000);
    try std.testing.expectEqual(@as(u64, 0), invalid_result.gasConsumed(original_gas));
}

test "call result state checks" {
    // Success cases
    const success1 = try DefaultCallResult.success_empty(std.testing.allocator, 1000);
    try std.testing.expect(success1.isSuccess());
    try std.testing.expect(!success1.isFailure());

    var success2 = try DefaultCallResult.success_with_output(std.testing.allocator, 2000, &[_]u8{0xff});
    defer success2.deinit(std.testing.allocator);
    try std.testing.expect(success2.isSuccess());
    try std.testing.expect(!success2.isFailure());

    // Failure cases
    const failure1 = try DefaultCallResult.failure(std.testing.allocator, 500);
    try std.testing.expect(!failure1.isSuccess());
    try std.testing.expect(failure1.isFailure());

    var failure2 = try DefaultCallResult.revert_with_data(std.testing.allocator, 300, "revert reason");
    defer failure2.deinit(std.testing.allocator);
    try std.testing.expect(!failure2.isSuccess());
    try std.testing.expect(failure2.isFailure());
}

test "call result output checks" {
    // No output cases
    const empty1 = try DefaultCallResult.success_empty(std.testing.allocator, 1000);
    try std.testing.expect(!empty1.hasOutput());

    const empty2 = try DefaultCallResult.failure(std.testing.allocator, 500);
    try std.testing.expect(!empty2.hasOutput());

    // With output cases
    var with_output1 = try DefaultCallResult.success_with_output(std.testing.allocator, 2000, &[_]u8{0x42});
    defer with_output1.deinit(std.testing.allocator);
    try std.testing.expect(with_output1.hasOutput());

    var with_output2 = try DefaultCallResult.revert_with_data(std.testing.allocator, 300, "error message");
    defer with_output2.deinit(std.testing.allocator);
    try std.testing.expect(with_output2.hasOutput());
}

test "call result edge cases" {
    // Zero gas left
    const zero_gas = try DefaultCallResult.success_empty(std.testing.allocator, 0);
    try std.testing.expect(zero_gas.isSuccess());
    try std.testing.expectEqual(@as(u64, 0), zero_gas.gas_left);
    try std.testing.expectEqual(@as(u64, 21000), zero_gas.gasConsumed(21000));

    // Maximum gas left
    const max_gas = try DefaultCallResult.success_empty(std.testing.allocator, std.math.maxInt(u64));
    try std.testing.expectEqual(std.math.maxInt(u64), max_gas.gas_left);
    try std.testing.expectEqual(@as(u64, 0), max_gas.gasConsumed(std.math.maxInt(u64)));

    // Large output data
    const large_output = &@as([10000]u8, @splat(0xaa));
    var large_result = try DefaultCallResult.success_with_output(std.testing.allocator, 5000, large_output);
    defer large_result.deinit(std.testing.allocator);
    try std.testing.expect(large_result.hasOutput());
    try std.testing.expectEqual(@as(usize, 10000), large_result.output.len);

    // Empty revert data (still counts as having output)
    var empty_revert = try DefaultCallResult.revert_with_data(std.testing.allocator, 1000, &[_]u8{});
    defer empty_revert.deinit(std.testing.allocator);
    try std.testing.expect(!empty_revert.hasOutput());
    try std.testing.expect(empty_revert.isFailure());
}

test "DefaultCallResult log memory management - proper cleanup" {
    const allocator = std.testing.allocator;

    // Source logs are owned by this test and freed by it.
    const source = [_]Log{
        .{ .address = ZERO_ADDRESS, .topics = &[_]u256{ 0x1234, 0x5678 }, .data = "test log data" },
        .{ .address = ZERO_ADDRESS, .topics = &[_]u256{0xABCD}, .data = "second log" },
    };

    // The result owns deep copies made with `allocator`; deinitLogs frees exactly
    // those with the same allocator. std.testing.allocator fails the test on a leak
    // or an invalid free.
    var call_result = try DefaultCallResult.success_with_logs(allocator, 50000, &[_]u8{}, &source);
    defer allocator.free(call_result.output);

    try std.testing.expectEqual(@as(usize, 2), call_result.logs.len);
    try std.testing.expect(call_result.logs[0].topics.ptr != source[0].topics.ptr);
    try std.testing.expectEqualSlices(u8, "second log", call_result.logs[1].data);

    call_result.deinitLogs(allocator);
    try std.testing.expectEqual(@as(usize, 0), call_result.logs.len);
}

test "DefaultCallResult deinitLogsSlice - memory management for takeLogs result" {
    const allocator = std.testing.allocator;

    // Simulate a takeLogs() result: a slice whose logs each own their topics and data.
    const source = [_]Log{
        .{ .address = ZERO_ADDRESS, .topics = &[_]u256{ 0xDEAD, 0xBEEF }, .data = "takeLogs test" },
        .{ .address = ZERO_ADDRESS, .topics = &[_]u256{0xCAFE}, .data = "slice cleanup" },
    };
    const logs = try cloneLogs(allocator, &source);

    // Frees every topic and data buffer and the slice itself; a leak fails the test.
    DefaultCallResult.deinitLogsSlice(logs, allocator);
}

test "call result failure with error info" {
    const error_message = "Contract execution reverted";
    var result = try DefaultCallResult.failure_with_error(std.testing.allocator, 1500, error_message);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.success);
    try std.testing.expectEqual(@as(u64, 1500), result.gas_left);
    try std.testing.expect(result.isFailure());
    try std.testing.expect(!result.isSuccess());
    try std.testing.expect(!result.hasOutput());
    try std.testing.expectEqualSlices(u8, error_message, result.error_info.?);
}

test "call result success with logs" {
    const allocator = std.testing.allocator;

    const logs = [_]Log{.{
        .address = .{ .bytes = [_]u8{0x42} ++ @as([19]u8, @splat(0)) },
        .topics = &[_]u256{ 0x1234567890ABCDEF, 0xFEDCBA0987654321 },
        .data = "test event data",
    }};

    const output_data = &[_]u8{ 0xAA, 0xBB, 0xCC };
    var result = try DefaultCallResult.success_with_logs(allocator, 12000, output_data, &logs);
    defer result.deinit(allocator);

    try std.testing.expect(result.success);
    try std.testing.expect(!result.reverted);
    try std.testing.expectEqual(@as(u64, 12000), result.gas_left);
    try std.testing.expectEqualSlices(u8, output_data, result.output);
    try std.testing.expectEqual(@as(usize, 1), result.logs.len);
    try std.testing.expectEqual(Address{ .bytes = [_]u8{0x42} ++ @as([19]u8, @splat(0)) }, result.logs[0].address);
    try std.testing.expectEqual(@as(usize, 2), result.logs[0].topics.len);
    try std.testing.expectEqual(@as(u256, 0x1234567890ABCDEF), result.logs[0].topics[0]);
    try std.testing.expectEqual(@as(u256, 0xFEDCBA0987654321), result.logs[0].topics[1]);
    try std.testing.expectEqualSlices(u8, "test event data", result.logs[0].data);
    try std.testing.expect(result.logs[0].data.ptr != logs[0].data.ptr);
}

test "call result struct field defaults" {
    // Test that default fields are correctly initialized
    const result = try DefaultCallResult.success_empty(std.testing.allocator, 5000);

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
            .contract = .{ .bytes = [_]u8{0x11} ++ @as([19]u8, @splat(0)) },
            .beneficiary = .{ .bytes = [_]u8{0x22} ++ @as([19]u8, @splat(0)) },
        },
        SelfDestructRecord{
            .contract = .{ .bytes = [_]u8{0x33} ++ @as([19]u8, @splat(0)) },
            .beneficiary = .{ .bytes = [_]u8{0x44} ++ @as([19]u8, @splat(0)) },
        },
    };

    var result = try DefaultCallResult.success_empty(std.testing.allocator, 8000);
    result.selfdestructs = &selfdestructs;

    try std.testing.expectEqual(@as(usize, 2), result.selfdestructs.len);
    try std.testing.expectEqual(Address{ .bytes = [_]u8{0x11} ++ @as([19]u8, @splat(0)) }, result.selfdestructs[0].contract);
    try std.testing.expectEqual(Address{ .bytes = [_]u8{0x22} ++ @as([19]u8, @splat(0)) }, result.selfdestructs[0].beneficiary);
    try std.testing.expectEqual(Address{ .bytes = [_]u8{0x33} ++ @as([19]u8, @splat(0)) }, result.selfdestructs[1].contract);
    try std.testing.expectEqual(Address{ .bytes = [_]u8{0x44} ++ @as([19]u8, @splat(0)) }, result.selfdestructs[1].beneficiary);
}

test "call result with accessed addresses" {
    var accessed_addresses = [_]Address{
        .{ .bytes = [_]u8{0xAA} ++ @as([19]u8, @splat(0)) },
        .{ .bytes = [_]u8{0xBB} ++ @as([19]u8, @splat(0)) },
        .{ .bytes = [_]u8{0xCC} ++ @as([19]u8, @splat(0)) },
    };

    var result = try DefaultCallResult.failure(std.testing.allocator, 200);
    result.accessed_addresses = &accessed_addresses;

    try std.testing.expectEqual(@as(usize, 3), result.accessed_addresses.len);
    try std.testing.expectEqual(Address{ .bytes = [_]u8{0xAA} ++ @as([19]u8, @splat(0)) }, result.accessed_addresses[0]);
    try std.testing.expectEqual(Address{ .bytes = [_]u8{0xBB} ++ @as([19]u8, @splat(0)) }, result.accessed_addresses[1]);
    try std.testing.expectEqual(Address{ .bytes = [_]u8{0xCC} ++ @as([19]u8, @splat(0)) }, result.accessed_addresses[2]);
}

test "call result with accessed storage" {
    var accessed_storage = [_]StorageAccess{
        StorageAccess{
            .address = .{ .bytes = [_]u8{0x11} ++ @as([19]u8, @splat(0)) },
            .slot = 0x1234,
        },
        StorageAccess{
            .address = .{ .bytes = [_]u8{0x22} ++ @as([19]u8, @splat(0)) },
            .slot = 0xABCDEF,
        },
    };

    var result = try DefaultCallResult.success_empty(std.testing.allocator, 9500);
    result.accessed_storage = &accessed_storage;

    try std.testing.expectEqual(@as(usize, 2), result.accessed_storage.len);
    try std.testing.expectEqual(Address{ .bytes = [_]u8{0x11} ++ @as([19]u8, @splat(0)) }, result.accessed_storage[0].address);
    try std.testing.expectEqual(@as(u256, 0x1234), result.accessed_storage[0].slot);
    try std.testing.expectEqual(Address{ .bytes = [_]u8{0x22} ++ @as([19]u8, @splat(0)) }, result.accessed_storage[1].address);
    try std.testing.expectEqual(@as(u256, 0xABCDEF), result.accessed_storage[1].slot);
}

test "execution trace basic functionality" {
    const allocator = std.testing.allocator;

    var trace = ExecutionTrace.init(allocator);
    defer trace.deinit();

    try std.testing.expectEqual(@as(usize, 0), trace.steps.len);

    // Test empty trace
    var empty_trace = ExecutionTrace.empty(allocator);
    defer empty_trace.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty_trace.steps.len);
}

test "trace step memory management" {
    const allocator = std.testing.allocator;

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
    writes[0] = TraceStep.StorageWrite{ .address = .{ .bytes = [_]u8{0x11} ++ @as([19]u8, @splat(0)) }, .slot = 0x300, .old_value = 0x400, .new_value = 0x500 };
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
    try std.testing.expectEqual(Address{ .bytes = [_]u8{0x11} ++ @as([19]u8, @splat(0)) }, step.storage_writes[0].address);
    try std.testing.expectEqual(@as(u256, 0x300), step.storage_writes[0].slot);
    try std.testing.expectEqual(@as(u256, 0x400), step.storage_writes[0].old_value);
    try std.testing.expectEqual(@as(u256, 0x500), step.storage_writes[0].new_value);

    // This should properly clean up all memory
    step.deinit(allocator);
}

test "call result gas consumption edge cases" {
    // Test integer overflow protection
    const result1 = try DefaultCallResult.success_empty(std.testing.allocator, std.math.maxInt(u64));
    try std.testing.expectEqual(@as(u64, 0), result1.gasConsumed(1000));

    // Test maximum possible consumption
    const result2 = try DefaultCallResult.success_empty(std.testing.allocator, 0);
    try std.testing.expectEqual(std.math.maxInt(u64), result2.gasConsumed(std.math.maxInt(u64)));

    // Test exact consumption
    const result3 = try DefaultCallResult.failure(std.testing.allocator, 12345);
    try std.testing.expectEqual(@as(u64, 8655), result3.gasConsumed(21000));
}

test "call result comprehensive constructor coverage" {
    const allocator = std.testing.allocator;
    var constructors = [_]DefaultCallResult{
        try DefaultCallResult.success_with_output(allocator, 1000, &[_]u8{0x01}),
        try DefaultCallResult.success_empty(allocator, 2000),
        try DefaultCallResult.failure(allocator, 3000),
        try DefaultCallResult.failure_with_error(allocator, 4000, "test error"),
        try DefaultCallResult.revert_with_data(allocator, 5000, "revert reason"),
        try DefaultCallResult.success_with_logs(allocator, 6000, &[_]u8{0x02}, &[_]Log{}),
    };
    defer for (&constructors) |*result| result.deinit(allocator);

    for (constructors, 0..) |result, index| {
        try std.testing.expectEqual(!result.isSuccess(), result.isFailure());
        try std.testing.expectEqual(index == 0 or index == 4 or index == 5, result.hasOutput());
        // Only revert_with_data builds a reverted result.
        try std.testing.expectEqual(index == 4, result.reverted);
        try std.testing.expectEqual(index == 4, result.isRevert());
        try std.testing.expectEqual(@as(u64, 10000 - 1000 * (index + 1)), result.gasConsumed(10000));
    }
}

test "call result empty logs slice cleanup" {
    const allocator = std.testing.allocator;

    // Test cleanup of empty logs slice
    const empty_logs = try allocator.alloc(Log, 0);
    DefaultCallResult.deinitLogsSlice(empty_logs, allocator);

    // Should not crash or leak
}

test "log struct comprehensive" {
    const allocator = std.testing.allocator;

    // Test log with maximum topics (typically 4 in EVM)
    const topics = try allocator.dupe(u256, &[_]u256{ 0x1111111111111111, 0x2222222222222222, 0x3333333333333333, 0x4444444444444444 });
    defer allocator.free(topics);

    const data = try allocator.dupe(u8, "This is a comprehensive test of log data with various characters: !@#$%^&*()");
    defer allocator.free(data);

    const log = Log{
        .address = Address{ .bytes = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF } ++ [_]u8{ 0xCA, 0xFE, 0xBA, 0xBE } ++ [_]u8{ 0x12, 0x34, 0x56, 0x78 } ++ [_]u8{ 0x9A, 0xBC, 0xDE, 0xF0 } ++ [_]u8{ 0x11, 0x22, 0x33, 0x44 } },
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
        .address = .{ .bytes = @as([20]u8, @splat(0xFF)) },
        .slot = std.math.maxInt(u256),
    };

    try std.testing.expectEqual(ZERO_ADDRESS, storage1.address);
    try std.testing.expectEqual(@as(u256, 0), storage1.slot);
    try std.testing.expectEqual(Address{ .bytes = @as([20]u8, @splat(0xFF)) }, storage2.address);
    try std.testing.expectEqual(std.math.maxInt(u256), storage2.slot);

    // Test boundary values for SelfDestructRecord
    const selfdestruct1 = SelfDestructRecord{
        .contract = ZERO_ADDRESS,
        .beneficiary = ZERO_ADDRESS,
    };
    const selfdestruct2 = SelfDestructRecord{
        .contract = Address{ .bytes = @as([20]u8, @splat(0xFF)) },
        .beneficiary = Address{ .bytes = @as([20]u8, @splat(0xAA)) },
    };

    try std.testing.expectEqual(ZERO_ADDRESS, selfdestruct1.contract);
    try std.testing.expectEqual(ZERO_ADDRESS, selfdestruct1.beneficiary);
    try std.testing.expectEqual(Address{ .bytes = @as([20]u8, @splat(0xFF)) }, selfdestruct2.contract);
    try std.testing.expectEqual(Address{ .bytes = @as([20]u8, @splat(0xAA)) }, selfdestruct2.beneficiary);
}

test "call result toOwnedResult basic" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test with simple success result
    var original = try DefaultCallResult.success_with_output(std.testing.allocator, 5000, "test output");
    defer original.deinit(std.testing.allocator);
    var owned = try original.toOwnedResult(allocator);
    defer owned.deinit(allocator);

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
    const allocator = testing.allocator;

    const logs = [_]Log{.{
        .address = .{ .bytes = [_]u8{0x42} ++ @as([19]u8, @splat(0)) },
        .topics = &[_]u256{ 0x1234, 0x5678 },
        .data = "log data",
    }};

    var original = try DefaultCallResult.success_with_logs(allocator, 3000, "output", &logs);
    defer original.deinit(allocator);
    var owned = try original.toOwnedResult(allocator);
    defer owned.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), owned.logs.len);
    try testing.expectEqual(@as(usize, 2), owned.logs[0].topics.len);
    try testing.expectEqualSlices(u8, "log data", owned.logs[0].data);

    // Verify deep copy
    try testing.expect(original.logs.ptr != owned.logs.ptr);
    try testing.expect(original.logs[0].topics.ptr != owned.logs[0].topics.ptr);
    try testing.expect(original.logs[0].data.ptr != owned.logs[0].data.ptr);
}

test "call result toOwnedResult empty result" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const original = try DefaultCallResult.success_empty(std.testing.allocator, 1000);
    var owned = try original.toOwnedResult(allocator);
    defer owned.deinit(allocator);

    try testing.expect(owned.success);
    try testing.expectEqual(@as(u64, 1000), owned.gas_left);
    try testing.expectEqual(@as(usize, 0), owned.output.len);
    try testing.expectEqual(@as(usize, 0), owned.logs.len);
}

test "call result toOwnedResult with error info" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var original = try DefaultCallResult.failure_with_error(std.testing.allocator, 500, "error message");
    defer original.deinit(std.testing.allocator);
    var owned = try original.toOwnedResult(allocator);
    defer owned.deinit(allocator);

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
    const allocator = testing.allocator;

    // Every field of the source borrows static data: the source owns nothing, so
    // only the owned copy is freed.
    const logs = [_]Log{.{
        .address = .{ .bytes = [_]u8{0x11} ++ @as([19]u8, @splat(0)) },
        .topics = &[_]u256{0xABCD},
        .data = "event",
    }};
    const selfdestructs = [_]SelfDestructRecord{.{
        .contract = .{ .bytes = [_]u8{0x22} ++ @as([19]u8, @splat(0)) },
        .beneficiary = .{ .bytes = [_]u8{0x33} ++ @as([19]u8, @splat(0)) },
    }};
    const addresses = [_]Address{
        .{ .bytes = [_]u8{0x44} ++ @as([19]u8, @splat(0)) },
        .{ .bytes = [_]u8{0x55} ++ @as([19]u8, @splat(0)) },
    };
    const storage = [_]StorageAccess{.{
        .address = .{ .bytes = [_]u8{0x66} ++ @as([19]u8, @splat(0)) },
        .slot = 0x100,
    }};
    const result = DefaultCallResult{
        .success = false,
        .gas_left = 2500,
        .output = "test output",
        .logs = &logs,
        .selfdestructs = &selfdestructs,
        .accessed_addresses = &addresses,
        .accessed_storage = &storage,
        .error_info = "why",
        .created_address = .{ .bytes = [_]u8{0x77} ++ @as([19]u8, @splat(0)) },
        .reverted = true,
    };

    var owned = try result.toOwnedResult(allocator);
    defer owned.deinit(allocator);

    // Verify all fields were copied
    try testing.expect(!owned.success);
    try testing.expect(owned.reverted);
    try testing.expectEqual(@as(u64, 2500), owned.gas_left);
    try testing.expectEqualSlices(u8, "test output", owned.output);
    try testing.expectEqual(@as(usize, 1), owned.logs.len);
    try testing.expectEqual(@as(usize, 1), owned.selfdestructs.len);
    try testing.expectEqual(@as(usize, 2), owned.accessed_addresses.len);
    try testing.expectEqual(@as(usize, 1), owned.accessed_storage.len);
    try testing.expectEqualSlices(u8, "why", owned.error_info.?);
    try testing.expectEqual(Address{ .bytes = [_]u8{0x77} ++ @as([19]u8, @splat(0)) }, owned.created_address.?);

    // Verify deep copies
    try testing.expect(result.output.ptr != owned.output.ptr);
    try testing.expect(result.logs.ptr != owned.logs.ptr);
    try testing.expect(result.selfdestructs.ptr != owned.selfdestructs.ptr);
    try testing.expect(result.accessed_addresses.ptr != owned.accessed_addresses.ptr);
    try testing.expect(result.accessed_storage.ptr != owned.accessed_storage.ptr);
}

// ---------------------------------------------------------------------------
// Allocation-failure sweeps. Each test fails the n-th allocation for n = 0, 1,
// 2, ... until the operation succeeds. `std.testing.allocator` backs the
// failing allocator, so a leak, a double free or a free of memory it never
// handed out (an uninitialized slice) fails the test.
// ---------------------------------------------------------------------------

/// A result with two logs, one of them without topics or data, every auxiliary
/// list and a two-step trace. Everything borrows static data except the trace,
/// which `trace_allocator` owns.
fn sweepFixture(trace_allocator: std.mem.Allocator) !DefaultCallResult {
    const Static = struct {
        const logs = [_]Log{
            .{ .address = ZERO_ADDRESS, .topics = &[_]u256{ 1, 2, 3 }, .data = "first" },
            .{ .address = ZERO_ADDRESS, .topics = &.{}, .data = &.{} },
            .{ .address = ZERO_ADDRESS, .topics = &[_]u256{4}, .data = "third" },
        };
        const selfdestructs = [_]SelfDestructRecord{.{ .contract = ZERO_ADDRESS, .beneficiary = ZERO_ADDRESS }};
        const addresses = [_]Address{ZERO_ADDRESS};
        const storage = [_]StorageAccess{.{ .address = ZERO_ADDRESS, .slot = 7 }};
        const steps = [_]TraceStep{
            .{
                .pc = 0,
                .opcode = 0x60,
                .opcode_name = "PUSH1",
                .gas = 100,
                .stack = &[_]u256{ 1, 2 },
                .memory = "mem",
                .storage_reads = &[_]TraceStep.StorageRead{.{ .address = ZERO_ADDRESS, .slot = 1, .value = 2 }},
                .storage_writes = &[_]TraceStep.StorageWrite{.{ .address = ZERO_ADDRESS, .slot = 1, .old_value = 2, .new_value = 3 }},
            },
            .{
                .pc = 2,
                .opcode = 0x55,
                .opcode_name = "SSTORE",
                .gas = 97,
                .stack = &[_]u256{9},
                .memory = "more memory",
                .storage_reads = &.{},
                .storage_writes = &[_]TraceStep.StorageWrite{.{ .address = ZERO_ADDRESS, .slot = 4, .old_value = 0, .new_value = 1 }},
            },
        };
    };
    const borrowed_trace = ExecutionTrace{ .steps = @constCast(&Static.steps), .allocator = trace_allocator };
    return .{
        .success = false,
        .gas_left = 77,
        .output = "output bytes",
        .logs = &Static.logs,
        .selfdestructs = &Static.selfdestructs,
        .accessed_addresses = &Static.addresses,
        .accessed_storage = &Static.storage,
        .trace = try borrowed_trace.clone(trace_allocator),
        .error_info = "error text",
        .created_address = ZERO_ADDRESS,
        .reverted = true,
    };
}

test "toOwnedResult frees every partial copy at each failing allocation" {
    const testing = std.testing;
    var source = try sweepFixture(testing.allocator);
    defer if (source.trace) |*trace| trace.deinit();

    var fail_index: usize = 0;
    var failures: usize = 0;
    while (true) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        var owned = source.toOwnedResult(failing.allocator()) catch |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            // Everything allocated before the failure was freed again.
            try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
            try testing.expectEqual(failing.allocations, failing.deallocations);
            failures += 1;
            continue;
        };
        defer owned.deinit(failing.allocator());
        try testing.expect(!failing.has_induced_failure);

        try testing.expect(owned.reverted);
        try testing.expectEqual(@as(usize, 3), owned.logs.len);
        try testing.expectEqualSlices(u256, &[_]u256{ 1, 2, 3 }, owned.logs[0].topics);
        try testing.expectEqual(@as(usize, 0), owned.logs[1].data.len);
        try testing.expectEqualSlices(u8, "third", owned.logs[2].data);
        try testing.expectEqual(@as(usize, 2), owned.trace.?.steps.len);
        try testing.expectEqualSlices(u8, "SSTORE", owned.trace.?.steps[1].opcode_name);
        try testing.expectEqualSlices(u8, "error text", owned.error_info.?);
        break;
    }
    // output, logs slice, 2 x (topics, data), 3 lists, error info, steps slice and
    // the fields of two steps: every one of them was made to fail once.
    try testing.expect(failures >= 20);
}

test "success_with_logs frees every partial copy at each failing allocation" {
    const testing = std.testing;
    const logs = [_]Log{
        .{ .address = ZERO_ADDRESS, .topics = &[_]u256{ 1, 2 }, .data = "one" },
        .{ .address = ZERO_ADDRESS, .topics = &[_]u256{3}, .data = "two" },
    };
    var fail_index: usize = 0;
    var failures: usize = 0;
    while (true) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        var result = DefaultCallResult.success_with_logs(failing.allocator(), 1, "out", &logs) catch |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
            failures += 1;
            continue;
        };
        defer result.deinit(failing.allocator());
        try testing.expectEqual(@as(usize, 2), result.logs.len);
        try testing.expectEqualSlices(u8, "two", result.logs[1].data);
        break;
    }
    // output, logs slice and two logs of two buffers each.
    try testing.expectEqual(@as(usize, 6), failures);
}

test "failure_with_error and the other constructors leave nothing behind on a failed allocation" {
    const testing = std.testing;
    var fail_index: usize = 0;
    var failures: usize = 0;
    while (true) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        const allocator = failing.allocator();
        var with_error = DefaultCallResult.failure_with_error(allocator, 1, "reason") catch |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
            failures += 1;
            continue;
        };
        defer with_error.deinit(allocator);
        var reverted = DefaultCallResult.revert_with_data(allocator, 1, "data") catch |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            failures += 1;
            continue;
        };
        defer reverted.deinit(allocator);
        var with_output = DefaultCallResult.success_with_output(allocator, 1, "data") catch |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            failures += 1;
            continue;
        };
        defer with_output.deinit(allocator);
        try testing.expectEqualSlices(u8, "reason", with_error.error_info.?);
        try testing.expect(reverted.reverted);
        try testing.expect(!with_error.reverted);
        break;
    }
    try testing.expectEqual(@as(usize, 3), failures);
}

test "cloneLogs and ExecutionTrace.clone survive a failure at every allocation" {
    const testing = std.testing;
    var source = try sweepFixture(testing.allocator);
    defer if (source.trace) |*trace| trace.deinit();

    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        const logs = cloneLogs(failing.allocator(), source.logs) catch {
            try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
            continue;
        };
        freeLogs(failing.allocator(), logs);
        break;
    }
    fail_index = 0;
    while (true) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        var trace = source.trace.?.clone(failing.allocator()) catch {
            try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
            continue;
        };
        trace.deinit();
        break;
    }
}

test "revert_with_data marks the result reverted and toOwnedResult keeps the mark" {
    const allocator = std.testing.allocator;
    // REVERT(0, 0) with no gas left: nothing but the flag says it was a revert.
    var empty_revert = try DefaultCallResult.revert_with_data(allocator, 0, &.{});
    defer empty_revert.deinit(allocator);
    try std.testing.expect(empty_revert.reverted);
    try std.testing.expect(empty_revert.isRevert());
    try std.testing.expectEqual(@as(u64, 0), empty_revert.gas_left);

    var owned = try empty_revert.toOwnedResult(allocator);
    defer owned.deinit(allocator);
    try std.testing.expect(owned.reverted);

    // An exceptional halt, even one that keeps gas, is not a revert.
    const halted = DefaultCallResult.failed(5000);
    try std.testing.expect(!halted.reverted);
    try std.testing.expect(!halted.isRevert());
    var owned_halt = try halted.toOwnedResult(allocator);
    defer owned_halt.deinit(allocator);
    try std.testing.expect(!owned_halt.reverted);
    try std.testing.expect(!DefaultCallResult.succeeded_empty(1).isRevert());
}
