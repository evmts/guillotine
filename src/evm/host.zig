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
        caller: Address,  // Original caller, not current contract
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
        /// Register a contract as created in the current transaction (EIP-6780)
        register_created_contract: *const fn (ptr: *anyopaque, address: Address) anyerror!void,
        /// Check if a contract was created in the current transaction (EIP-6780)
        was_created_in_tx: *const fn (ptr: *anyopaque, address: Address) bool,
        /// Create a new journal snapshot for reverting state changes
        create_snapshot: *const fn (ptr: *anyopaque) u32,
        /// Revert state changes to a previous snapshot
        revert_to_snapshot: *const fn (ptr: *anyopaque, snapshot_id: u32) void,
        /// Record a storage change in the journal
        record_storage_change: *const fn (ptr: *anyopaque, address: Address, slot: u256, original_value: u256) anyerror!void,
        /// Get the original storage value from the journal
        get_original_storage: *const fn (ptr: *anyopaque, address: Address, slot: u256) ?u256,
        /// Set the output buffer for the current frame
        set_output: *const fn (ptr: *anyopaque, output: []const u8) anyerror!void,
        /// Get the output buffer for the current frame
        get_output: *const fn (ptr: *anyopaque) []const u8,
        /// Access an address and return the gas cost (EIP-2929)
        access_address: *const fn (ptr: *anyopaque, address: Address) anyerror!u64,
        /// Access a storage slot and return the gas cost (EIP-2929)
        access_storage_slot: *const fn (ptr: *anyopaque, contract_address: Address, slot: u256) anyerror!u64,
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

            fn vtable_register_created_contract(ptr: *anyopaque, address: Address) anyerror!void {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.register_created_contract(address);
            }

            fn vtable_was_created_in_tx(ptr: *anyopaque, address: Address) bool {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.was_created_in_tx(address);
            }

            fn vtable_create_snapshot(ptr: *anyopaque) u32 {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.create_snapshot();
            }

            fn vtable_revert_to_snapshot(ptr: *anyopaque, snapshot_id: u32) void {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.revert_to_snapshot(snapshot_id);
            }

            fn vtable_record_storage_change(ptr: *anyopaque, address: Address, slot: u256, original_value: u256) anyerror!void {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.record_storage_change(address, slot, original_value);
            }

            fn vtable_get_original_storage(ptr: *anyopaque, address: Address, slot: u256) ?u256 {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.get_original_storage(address, slot);
            }

            fn vtable_set_output(ptr: *anyopaque, output: []const u8) anyerror!void {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.set_output(output);
            }

            fn vtable_get_output(ptr: *anyopaque) []const u8 {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.get_output();
            }

            fn vtable_access_address(ptr: *anyopaque, address: Address) anyerror!u64 {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.access_address(address);
            }

            fn vtable_access_storage_slot(ptr: *anyopaque, contract_address: Address, slot: u256) anyerror!u64 {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.access_storage_slot(contract_address, slot);
            }

            const vtable = VTable{
                .get_balance = vtable_get_balance,
                .account_exists = vtable_account_exists,
                .get_code = vtable_get_code,
                .get_block_info = vtable_get_block_info,
                .emit_log = vtable_emit_log,
                .call = vtable_call,
                .register_created_contract = vtable_register_created_contract,
                .was_created_in_tx = vtable_was_created_in_tx,
                .create_snapshot = vtable_create_snapshot,
                .revert_to_snapshot = vtable_revert_to_snapshot,
                .record_storage_change = vtable_record_storage_change,
                .get_original_storage = vtable_get_original_storage,
                .set_output = vtable_set_output,
                .get_output = vtable_get_output,
                .access_address = vtable_access_address,
                .access_storage_slot = vtable_access_storage_slot,
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

    /// Register a contract as created in the current transaction (EIP-6780)
    pub fn register_created_contract(self: Host, address: Address) !void {
        return self.vtable.register_created_contract(self.ptr, address);
    }

    /// Check if a contract was created in the current transaction (EIP-6780)
    pub fn was_created_in_tx(self: Host, address: Address) bool {
        return self.vtable.was_created_in_tx(self.ptr, address);
    }

    /// Create a new journal snapshot for reverting state changes
    pub fn create_snapshot(self: Host) u32 {
        return self.vtable.create_snapshot(self.ptr);
    }

    /// Revert state changes to a previous snapshot
    pub fn revert_to_snapshot(self: Host, snapshot_id: u32) void {
        return self.vtable.revert_to_snapshot(self.ptr, snapshot_id);
    }

    /// Record a storage change in the journal
    pub fn record_storage_change(self: Host, address: Address, slot: u256, original_value: u256) !void {
        return self.vtable.record_storage_change(self.ptr, address, slot, original_value);
    }

    /// Get the original storage value from the journal
    pub fn get_original_storage(self: Host, address: Address, slot: u256) ?u256 {
        return self.vtable.get_original_storage(self.ptr, address, slot);
    }

    /// Set the output buffer for the current frame
    pub fn set_output(self: Host, output: []const u8) !void {
        return self.vtable.set_output(self.ptr, output);
    }

    /// Get the output buffer for the current frame
    pub fn get_output(self: Host) []const u8 {
        return self.vtable.get_output(self.ptr);
    }

    /// Access an address and return the gas cost (EIP-2929)
    pub fn access_address(self: Host, address: Address) !u64 {
        return self.vtable.access_address(self.ptr, address);
    }

    /// Access a storage slot and return the gas cost (EIP-2929)
    pub fn access_storage_slot(self: Host, contract_address: Address, slot: u256) !u64 {
        return self.vtable.access_storage_slot(self.ptr, contract_address, slot);
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
    
    pub fn register_created_contract(self: *MockHost, address: Address) !void {
        _ = self;
        _ = address;
        // Mock implementation - do nothing
    }
    
    pub fn was_created_in_tx(self: *MockHost, address: Address) bool {
        _ = self;
        _ = address;
        // Mock implementation - always return false
        return false;
    }
    
    pub fn create_snapshot(self: *MockHost) u32 {
        _ = self;
        // Mock implementation - return dummy snapshot id
        return 0;
    }
    
    pub fn revert_to_snapshot(self: *MockHost, snapshot_id: u32) void {
        _ = self;
        _ = snapshot_id;
        // Mock implementation - do nothing
    }
    
    pub fn record_storage_change(self: *MockHost, address: Address, slot: u256, original_value: u256) !void {
        _ = self;
        _ = address;
        _ = slot;
        _ = original_value;
        // Mock implementation - do nothing
    }
    
    pub fn get_original_storage(self: *MockHost, address: Address, slot: u256) ?u256 {
        _ = self;
        _ = address;
        _ = slot;
        // Mock implementation - return null
        return null;
    }
    
    pub fn set_output(self: *MockHost, output: []const u8) !void {
        _ = self;
        _ = output;
        // Mock implementation - do nothing
    }
    
    pub fn get_output(self: *MockHost) []const u8 {
        _ = self;
        // Mock implementation - return empty
        return &.{};
    }
    
    pub fn access_address(self: *MockHost, address: Address) !u64 {
        _ = self;
        _ = address;
        // Mock implementation - return cold access cost
        return 2600;
    }
    
    pub fn access_storage_slot(self: *MockHost, contract_address: Address, slot: u256) !u64 {
        _ = self;
        _ = contract_address;
        _ = slot;
        // Mock implementation - return cold storage access cost
        return 2100;
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