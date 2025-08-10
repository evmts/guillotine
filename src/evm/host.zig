const std = @import("std");
const Address = @import("primitives").Address.Address;
const CallResult = @import("evm/call_result.zig").CallResult;
const Frame = @import("frame.zig").Frame;

/// Call operation parameters for different call types
pub const CallParams = union(enum) {
    /// Regular CALL operation
    call: struct {
        caller: Address,
        to: Address,
        value: u256,
        input: []const u8,
        gas: u64,
    },
    /// CALLCODE operation: execute external code with current storage/context
    /// Executes code at `to`, but uses caller's storage and address context
    callcode: struct {
        caller: Address,
        to: Address,
        value: u256,
        input: []const u8,
        gas: u64,
    },
    /// DELEGATECALL operation (preserves caller context)
    delegatecall: struct {
        caller: Address, // Original caller, not current contract
        to: Address,
        input: []const u8,
        gas: u64,
    },
    /// STATICCALL operation (read-only)
    staticcall: struct {
        caller: Address,
        to: Address,
        input: []const u8,
        gas: u64,
    },
    /// CREATE operation
    create: struct {
        caller: Address,
        value: u256,
        init_code: []const u8,
        gas: u64,
    },
    /// CREATE2 operation
    create2: struct {
        caller: Address,
        value: u256,
        init_code: []const u8,
        salt: u256,
        gas: u64,
    },
};

/// Block information structure for Host interface
pub const BlockInfo = struct {
    /// Block number
    number: u64,
    /// Block timestamp
    timestamp: u64,
    /// Block difficulty
    difficulty: u256,
    /// Block gas limit
    gas_limit: u64,
    /// Coinbase (miner) address
    coinbase: Address,
    /// Base fee per gas (EIP-1559)
    base_fee: u256,
    /// Block hash of previous block
    prev_randao: [32]u8,
};

/// Host interface for external operations
/// This provides the EVM with access to blockchain state and external services
pub const Host = struct {
    /// Pointer to the actual host implementation
    ptr: *anyopaque,
    /// Function pointer table for the implementation
    vtable: *const VTable,

    /// Virtual function table defining all host operations
    pub const VTable = struct {
        /// Get account balance
        get_balance: *const fn (ptr: *anyopaque, address: Address) u256,
        /// Check if account exists
        account_exists: *const fn (ptr: *anyopaque, address: Address) bool,
        /// Get account code
        get_code: *const fn (ptr: *anyopaque, address: Address) []const u8,
        /// Get block information
        get_block_info: *const fn (ptr: *anyopaque) BlockInfo,
        /// Emit log event (for LOG0-LOG4 opcodes)
        emit_log: *const fn (ptr: *anyopaque, contract_address: Address, topics: []const u256, data: []const u8) void,
        /// Execute EVM call (CALL, DELEGATECALL, STATICCALL, CREATE, CREATE2)
        call: *const fn (ptr: *anyopaque, params: CallParams) anyerror!CallResult,
        /// Add gas refund for transaction
        add_gas_refund: *const fn (ptr: *anyopaque, amount: u64) void,
    };

    /// Initialize a Host interface from any implementation
    pub fn init(implementation: anytype) Host {
        const Impl = @TypeOf(implementation);
        const impl_info = @typeInfo(Impl);

        if (impl_info != .pointer) {
            @compileError("Host interface requires a pointer to implementation");
        }

        const gen = struct {
            fn vtable_get_balance(ptr: *anyopaque, address: Address) u256 {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.get_balance(address);
            }

            fn vtable_account_exists(ptr: *anyopaque, address: Address) bool {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.account_exists(address);
            }

            fn vtable_get_code(ptr: *anyopaque, address: Address) []const u8 {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.get_code(address);
            }

            fn vtable_get_block_info(ptr: *anyopaque) BlockInfo {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.get_block_info();
            }

            fn vtable_emit_log(ptr: *anyopaque, contract_address: Address, topics: []const u256, data: []const u8) void {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.emit_log(contract_address, topics, data);
            }

            fn vtable_call(ptr: *anyopaque, params: CallParams) anyerror!CallResult {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.call(params);
            }

            fn vtable_add_gas_refund(ptr: *anyopaque, amount: u64) void {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.add_gas_refund(amount);
            }

            const vtable = VTable{
                .get_balance = vtable_get_balance,
                .account_exists = vtable_account_exists,
                .get_code = vtable_get_code,
                .get_block_info = vtable_get_block_info,
                .emit_log = vtable_emit_log,
                .call = vtable_call,
                .add_gas_refund = vtable_add_gas_refund,
            };
        };

        return Host{
            .ptr = implementation,
            .vtable = &gen.vtable,
        };
    }

    /// Get account balance
    pub fn get_balance(self: Host, address: Address) u256 {
        return self.vtable.get_balance(self.ptr, address);
    }

    /// Check if account exists
    pub fn account_exists(self: Host, address: Address) bool {
        return self.vtable.account_exists(self.ptr, address);
    }

    /// Get account code
    pub fn get_code(self: Host, address: Address) []const u8 {
        return self.vtable.get_code(self.ptr, address);
    }

    /// Get block information
    pub fn get_block_info(self: Host) BlockInfo {
        return self.vtable.get_block_info(self.ptr);
    }

    /// Emit log event
    pub fn emit_log(self: Host, contract_address: Address, topics: []const u256, data: []const u8) void {
        return self.vtable.emit_log(self.ptr, contract_address, topics, data);
    }

    /// Execute EVM call
    pub fn call(self: Host, params: CallParams) !CallResult {
        return self.vtable.call(self.ptr, params);
    }

    /// Add gas refund
    pub fn add_gas_refund(self: Host, amount: u64) void {
        return self.vtable.add_gas_refund(self.ptr, amount);
    }
};

/// Mock host implementation for testing
pub const MockHost = struct {
    allocator: std.mem.Allocator,
    logs: std.ArrayList(LogEntry),

    pub const LogEntry = struct {
        contract_address: Address,
        topics: []const u256,
        data: []const u8,
    };

    pub fn init(allocator: std.mem.Allocator) MockHost {
        return MockHost{
            .allocator = allocator,
            .logs = std.ArrayList(LogEntry).init(allocator),
        };
    }

    pub fn deinit(self: *MockHost) void {
        // Clean up stored log data
        for (self.logs.items) |log| {
            self.allocator.free(log.topics);
            self.allocator.free(log.data);
        }
        self.logs.deinit();
    }

    pub fn get_balance(self: *MockHost, address: Address) u256 {
        _ = self;
        _ = address;
        return 1000; // Mock balance
    }

    pub fn account_exists(self: *MockHost, address: Address) bool {
        _ = self;
        _ = address;
        return true; // Mock exists
    }

    pub fn get_code(self: *MockHost, address: Address) []const u8 {
        _ = self;
        _ = address;
        return &.{}; // Mock empty code
    }

    pub fn get_block_info(self: *MockHost) BlockInfo {
        _ = self;
        return BlockInfo{
            .number = 1,
            .timestamp = 1000,
            .difficulty = 100,
            .gas_limit = 30000000,
            .coinbase = Address.ZERO,
            .base_fee = 1000000000, // 1 gwei
            .prev_randao = [_]u8{0} ** 32,
        };
    }

    pub fn emit_log(self: *MockHost, contract_address: Address, topics: []const u256, data: []const u8) void {
        // Store a copy of the log for testing
        const topics_copy = self.allocator.dupe(u256, topics) catch return;
        const data_copy = self.allocator.dupe(u8, data) catch {
            self.allocator.free(topics_copy);
            return;
        };

        self.logs.append(LogEntry{
            .contract_address = contract_address,
            .topics = topics_copy,
            .data = data_copy,
        }) catch {
            self.allocator.free(topics_copy);
            self.allocator.free(data_copy);
        };
    }

    pub fn call(self: *MockHost, params: CallParams) CallResult {
        _ = self;
        _ = params;
        // Mock implementation - just return success with empty output
        return CallResult{
            .success = true,
            .gas_left = 0,
            .output = &.{},
        };
    }

    pub fn to_host(self: *MockHost) Host {
        return Host.init(self);
    }
};

test "Host interface with MockHost" {
    const allocator = std.testing.allocator;

    var mock_host = MockHost.init(allocator);
    defer mock_host.deinit();

    const host = mock_host.to_host();

    // Test balance
    const balance = host.get_balance(Address.ZERO);
    try std.testing.expectEqual(@as(u256, 1000), balance);

    // Test account exists
    try std.testing.expect(host.account_exists(Address.ZERO));

    // Test code
    const code = host.get_code(Address.ZERO);
    try std.testing.expectEqual(@as(usize, 0), code.len);

    // Test block info
    const block_info = host.get_block_info();
    try std.testing.expectEqual(@as(u64, 1), block_info.number);
    try std.testing.expectEqual(@as(u64, 1000), block_info.timestamp);

    // Test log emission
    const topics = [_]u256{ 0x1234, 0x5678 };
    const data = "test log data";
    host.emit_log(Address.ZERO, &topics, data);

    // Verify log was stored
    try std.testing.expectEqual(@as(usize, 1), mock_host.logs.items.len);
    const stored_log = mock_host.logs.items[0];
    try std.testing.expectEqualSlices(u8, &Address.ZERO, &stored_log.contract_address);
    try std.testing.expectEqual(@as(usize, 2), stored_log.topics.len);
    try std.testing.expectEqual(@as(u256, 0x1234), stored_log.topics[0]);
    try std.testing.expectEqual(@as(u256, 0x5678), stored_log.topics[1]);
    try std.testing.expectEqualStrings("test log data", stored_log.data);
}
