pub fn CallResult(config: anytype) type {
    // We can add config-specific customizations here in the future
    _ = config; // Currently unused but reserved for future enhancements

    return struct {
        const Self = @This();

        success: bool,
        gas_left: u64,
        output: []const u8,
        refund_counter: u64 = 0,
        logs: []const Log = &.{},
        selfdestructs: []const SelfDestructRecord = &.{},
        accessed_addresses: []const Address = &.{},
        accessed_storage: []const StorageAccess = &.{},
        trace: ?ExecutionTrace = null,
        error_info: ?[]const u8 = null,
        created_address: ?Address = null,

        pub fn success_with_output(allocator: std.mem.Allocator, gas_left: u64, output: []const u8) !Self {
            return Self{
                .success = true,
                .gas_left = gas_left,
                .output = if (output.len > 0) try allocator.dupe(u8, output) else &.{},
                .logs = &.{},
                .selfdestructs = &.{},
                .accessed_addresses = &.{},
                .accessed_storage = &.{},
            };
        }

        pub fn success_empty(allocator: std.mem.Allocator, gas_left: u64) !Self {
            _ = allocator; // Unused when using compile-time empty slices
            return Self{
                .success = true,
                .gas_left = gas_left,
                .output = &.{},
                .logs = &.{},
                .selfdestructs = &.{},
                .accessed_addresses = &.{},
                .accessed_storage = &.{},
            };
        }

        pub fn failure(allocator: std.mem.Allocator, gas_left: u64) !Self {
            _ = allocator; // Unused when using compile-time empty slices
            return Self{
                .success = false,
                .gas_left = gas_left,
                .output = &.{},
                .logs = &.{},
                .selfdestructs = &.{},
                .accessed_addresses = &.{},
                .accessed_storage = &.{},
            };
        }

        /// Create a failed call result with error info
        pub fn failure_with_error(allocator: std.mem.Allocator, gas_left: u64, error_info: []const u8) !Self {
            return Self{
                .success = false,
                .gas_left = gas_left,
                .output = try allocator.alloc(u8, 0),
                .logs = try allocator.alloc(Log, 0),
                .selfdestructs = try allocator.alloc(SelfDestructRecord, 0),
                .accessed_addresses = try allocator.alloc(Address, 0),
                .accessed_storage = try allocator.alloc(StorageAccess, 0),
                .error_info = try allocator.dupe(u8, error_info),
            };
        }

        /// Create a reverted call result with revert data
        pub fn revert_with_data(allocator: std.mem.Allocator, gas_left: u64, revert_data: []const u8) !Self {
            return Self{
                .success = false,
                .gas_left = gas_left,
                .output = if (revert_data.len > 0) try allocator.dupe(u8, revert_data) else &.{},
                .logs = &.{},
                .selfdestructs = &.{},
                .accessed_addresses = &.{},
                .accessed_storage = &.{},
                .error_info = null,
            };
        }

        /// Create a successful call result with output and logs
        pub fn success_with_logs(allocator: std.mem.Allocator, gas_left: u64, output: []const u8, logs: []const Log) !Self {
            // Deep copy logs
            const logs_copy = try allocator.alloc(Log, logs.len);
            for (logs, 0..) |log, i| {
                logs_copy[i] = .{
                    .address = log.address,
                    .topics = try allocator.dupe(u256, log.topics),
                    .data = try allocator.dupe(u8, log.data),
                };
            }

            return Self{
                .success = true,
                .gas_left = gas_left,
                .output = try allocator.dupe(u8, output),
                .logs = logs_copy,
                .selfdestructs = try allocator.alloc(SelfDestructRecord, 0),
                .accessed_addresses = try allocator.alloc(Address, 0),
                .accessed_storage = try allocator.alloc(StorageAccess, 0),
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
        /// This assumes the CallResult was created via toOwnedResult() and owns all its data
        /// UNCONDITIONALLY frees all memory
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            // Free output unconditionally
            allocator.free(self.output);

            // Free logs and their contents unconditionally
            for (self.logs) |log| {
                allocator.free(log.topics);
                allocator.free(log.data);
            }
            allocator.free(self.logs);

            // Free selfdestructs unconditionally
            allocator.free(self.selfdestructs);

            // Free accessed_addresses unconditionally
            allocator.free(self.accessed_addresses);

            // Free accessed_storage unconditionally
            allocator.free(self.accessed_storage);

            // Free trace if present
            if (self.trace) |*trace| {
                trace.deinit();
            }

            // Free error_info unconditionally
            if (self.error_info) |info| {
                allocator.free(info);
            }

            // Reset all fields
            self.* = undefined;
        }

        /// Create an owned copy of this CallResult
        /// All dynamically allocated data (output, logs, etc.) is duplicated
        /// The caller owns the returned result and must call deinit() when done
        pub fn toOwnedResult(self: Self, allocator: std.mem.Allocator) !Self {
            // Always allocate and copy output data (even if empty)
            // Handle compile-time empty slices that may have invalid pointers
            const output_copy = if (self.output.len == 0)
                try allocator.alloc(u8, 0)
            else
                try allocator.dupe(u8, self.output);
            errdefer allocator.free(output_copy);

            // Always allocate and copy logs
            const logs_copy = try allocator.alloc(Log, self.logs.len);
            errdefer {
                for (logs_copy) |log| {
                    allocator.free(log.topics);
                    allocator.free(log.data);
                }
                allocator.free(logs_copy);
            }

            for (self.logs, 0..) |log, i| {
                logs_copy[i] = .{
                    .address = log.address,
                    .topics = if (log.topics.len == 0) try allocator.alloc(u256, 0) else try allocator.dupe(u256, log.topics),
                    .data = if (log.data.len == 0) try allocator.alloc(u8, 0) else try allocator.dupe(u8, log.data),
                };
            }

            // Always allocate and copy selfdestructs
            const selfdestructs_copy = if (self.selfdestructs.len == 0)
                try allocator.alloc(SelfDestructRecord, 0)
            else
                try allocator.dupe(SelfDestructRecord, self.selfdestructs);
            errdefer allocator.free(selfdestructs_copy);

            // Always allocate and copy accessed addresses
            const accessed_addresses_copy = if (self.accessed_addresses.len == 0)
                try allocator.alloc(Address, 0)
            else
                try allocator.dupe(Address, self.accessed_addresses);
            errdefer allocator.free(accessed_addresses_copy);

            // Always allocate and copy accessed storage
            const accessed_storage_copy = if (self.accessed_storage.len == 0)
                try allocator.alloc(StorageAccess, 0)
            else
                try allocator.dupe(StorageAccess, self.accessed_storage);
            errdefer allocator.free(accessed_storage_copy);

            // Copy error info if present
            const error_info_copy: ?[]const u8 = if (self.error_info) |info| blk: {
                break :blk if (info.len == 0)
                    try allocator.alloc(u8, 0)
                else
                    try allocator.dupe(u8, info);
            } else null;
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
            };
        }
    };
}

const std = @import("std");
const primitives = @import("primitives");
const Address = primitives.Address;
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
