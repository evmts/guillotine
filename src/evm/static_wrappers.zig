//! Static call wrappers that encode EIP-214 (STATICCALL) constraints in the type system.
//!
//! These wrappers implement data-oriented design by encoding static call restrictions
//! directly in the dependencies rather than using runtime boolean checks. This eliminates
//! branching and provides better performance while ensuring EIP-214 compliance.
//!
//! EIP-214: STATICCALL opcode - read-only execution context that prevents:
//! - State modifications (SSTORE)
//! - Log emissions (LOG0-LOG4)
//! - Contract creation (CREATE/CREATE2)
//! - Self-destruction (SELFDESTRUCT)
//! - Sending value in nested calls

const std = @import("std");
const primitives = @import("primitives");
const Address = primitives.Address.Address;
const Database = @import("database.zig").Database;
const Account = @import("database.zig").Account;
const logs = @import("logs.zig");
const Log = logs.Log;
const CallParams = @import("call_params.zig").CallParams;
const CallResult = @import("call_result.zig").CallResult;
const Hardfork = @import("hardfork.zig").Hardfork;

/// Static database wrapper that throws PermissionDenied errors for state modifications.
/// Implements EIP-214 constraint: STATICCALL cannot modify blockchain state.
pub const StaticDatabase = struct {
    /// Underlying database for read operations
    inner: Database,

    /// Initialize static database wrapper
    pub fn init(inner: Database) StaticDatabase {
        return StaticDatabase{ .inner = inner };
    }

    /// Convert to Database - read operations are forwarded, writes throw errors
    /// Since we now use concrete Database type, return self as the static implementation
    pub fn to_database_interface(self: *StaticDatabase) *StaticDatabase {
        return self;
    }

    // Read operations - forwarded to underlying database
    pub fn get_account(self: *StaticDatabase, address: [20]u8) Database.Error!?Account {
        return self.inner.get_account(address);
    }

    pub fn get_storage(self: *StaticDatabase, address: [20]u8, key: u256) Database.Error!u256 {
        return self.inner.get_storage(address, key);
    }

    pub fn get_code(self: *StaticDatabase, code_hash: [32]u8) Database.Error![]const u8 {
        return self.inner.get_code(code_hash);
    }

    pub fn get_code_by_address(self: *StaticDatabase, address: [20]u8) Database.Error![]const u8 {
        return self.inner.get_code_by_address(address);
    }

    pub fn account_exists(self: *StaticDatabase, address: [20]u8) bool {
        return self.inner.account_exists(address);
    }

    pub fn get_balance(self: *StaticDatabase, address: [20]u8) Database.Error!u256 {
        return self.inner.get_balance(address);
    }

    pub fn get_nonce(self: *StaticDatabase, address: [20]u8) Database.Error!u64 {
        return self.inner.get_nonce(address);
    }

    pub fn is_empty(self: *StaticDatabase, address: [20]u8) Database.Error!bool {
        return self.inner.is_empty(address);
    }

    pub fn get_code_hash(self: *StaticDatabase, address: [20]u8) Database.Error![32]u8 {
        return self.inner.get_code_hash(address);
    }

    // Write operations - all throw PermissionDenied errors per EIP-214
    pub fn set_account(self: *StaticDatabase, address: [20]u8, account: Account) Database.Error!void {
        _ = self;
        _ = address;
        _ = account;
        return Database.Error.PermissionDenied;
    }

    pub fn set_storage(self: *StaticDatabase, address: [20]u8, key: u256, value: u256) Database.Error!void {
        _ = self;
        _ = address;
        _ = key;
        _ = value;
        return Database.Error.PermissionDenied;
    }

    pub fn set_code(self: *StaticDatabase, code: []const u8) Database.Error![32]u8 {
        _ = self;
        _ = code;
        return Database.Error.PermissionDenied;
    }

    pub fn set_balance(self: *StaticDatabase, address: [20]u8, balance: u256) Database.Error!void {
        _ = self;
        _ = address;
        _ = balance;
        return Database.Error.PermissionDenied;
    }

    pub fn set_nonce(self: *StaticDatabase, address: [20]u8, nonce: u64) Database.Error!void {
        _ = self;
        _ = address;
        _ = nonce;
        return Database.Error.PermissionDenied;
    }

    pub fn delete_account(self: *StaticDatabase, address: [20]u8) Database.Error!void {
        _ = self;
        _ = address;
        return Database.Error.PermissionDenied;
    }

    // Transient storage operations - also throw PermissionDenied for writes
    pub fn get_transient_storage(self: *StaticDatabase, address: [20]u8, key: u256) Database.Error!u256 {
        return self.inner.get_transient_storage(address, key);
    }

    pub fn set_transient_storage(self: *StaticDatabase, address: [20]u8, key: u256, value: u256) Database.Error!void {
        _ = self;
        _ = address;
        _ = key;
        _ = value;
        return Database.Error.PermissionDenied;
    }

    // Read operations - forward to underlying database
    pub fn get_state_root(self: *StaticDatabase) Database.Error![32]u8 {
        return self.inner.get_state_root();
    }

    // Write operations - throw PermissionDenied
    pub fn commit_changes(self: *StaticDatabase) Database.Error![32]u8 {
        _ = self;
        return Database.Error.PermissionDenied;
    }

    pub fn create_snapshot(self: *StaticDatabase) Database.Error!u64 {
        return self.inner.create_snapshot();
    }

    pub fn revert_to_snapshot(self: *StaticDatabase, snapshot_id: u64) Database.Error!void {
        return self.inner.revert_to_snapshot(snapshot_id);
    }

    pub fn commit_snapshot(self: *StaticDatabase, snapshot_id: u64) Database.Error!void {
        _ = self;
        _ = snapshot_id;
        return Database.Error.PermissionDenied;
    }

    pub fn begin_batch(self: *StaticDatabase) Database.Error!void {
        return self.inner.begin_batch();
    }

    pub fn commit_batch(self: *StaticDatabase) Database.Error!void {
        _ = self;
        return Database.Error.PermissionDenied;
    }

    pub fn rollback_batch(self: *StaticDatabase) Database.Error!void {
        return self.inner.rollback_batch();
    }

    // Transaction tracking - not relevant but required by interface
    pub fn begin_transaction(self: *StaticDatabase) Database.Error!u32 {
        return self.inner.begin_transaction();
    }

    pub fn commit_transaction(self: *StaticDatabase, id: u32) Database.Error!void {
        return self.inner.commit_transaction(id);
    }

    pub fn rollback_transaction(self: *StaticDatabase, id: u32) Database.Error!void {
        return self.inner.rollback_transaction(id);
    }

    pub fn deinit(self: *StaticDatabase) void {
        _ = self;
        // Nothing to do - inner database is owned by caller
    }
};

/// Static host implementation that blocks state modifications.
/// Implements EIP-214 constraint: STATICCALL cannot emit logs or modify state.
pub fn StaticHost(comptime HostType: type) type {
    return struct {
        const Self = @This();

        /// Underlying host for read operations
        inner: HostType,

        /// Initialize static host wrapper
        pub fn init(inner: HostType) Self {
            return Self{ .inner = inner };
        }

        // Read operations - forwarded to underlying host
        pub fn get_balance(self: *Self, address: Address) u256 {
            return self.inner.get_balance(address);
        }

        pub fn account_exists(self: *Self, address: Address) bool {
            return self.inner.account_exists(address);
        }

        pub fn get_code(self: *Self, address: Address) []const u8 {
            return self.inner.get_code(address);
        }

        pub fn get_block_info(self: *Self) @TypeOf(self.inner.get_block_info()) {
            return self.inner.get_block_info();
        }

        pub fn get_storage(self: *Self, address: Address, slot: u256) u256 {
            return self.inner.get_storage(address, slot);
        }

        pub fn get_is_static(self: *Self) bool {
            _ = self;
            return true; // Static hosts are always in static context
        }

        pub fn get_depth(self: *Self) u11 {
            return self.inner.get_depth();
        }

        pub fn get_gas_price(self: *Self) u256 {
            return self.inner.get_gas_price();
        }

        pub fn get_return_data(self: *Self) []const u8 {
            return self.inner.get_return_data();
        }

        pub fn get_chain_id(self: *Self) u16 {
            return self.inner.get_chain_id();
        }

        pub fn get_block_hash(self: *Self, block_number: u64) ?[32]u8 {
            return self.inner.get_block_hash(block_number);
        }

        pub fn get_blob_hash(self: *Self, index: u256) ?[32]u8 {
            return self.inner.get_blob_hash(index);
        }

        pub fn get_blob_base_fee(self: *Self) u256 {
            return self.inner.get_blob_base_fee();
        }

        pub fn get_tx_origin(self: *Self) Address {
            return self.inner.get_tx_origin();
        }

        pub fn get_caller(self: *Self) Address {
            return self.inner.get_caller();
        }

        pub fn get_call_value(self: *Self) u256 {
            return self.inner.get_call_value();
        }

        pub fn get_input(self: *Self) []const u8 {
            return self.inner.get_input();
        }

        pub fn is_hardfork_at_least(self: *Self, target: Hardfork) bool {
            return self.inner.is_hardfork_at_least(target);
        }

        pub fn get_hardfork(self: *Self) Hardfork {
            return self.inner.get_hardfork();
        }

        pub fn create_snapshot(self: *Self) u32 {
            return self.inner.create_snapshot();
        }

        pub fn revert_to_snapshot(self: *Self, snapshot_id: u32) void {
            return self.inner.revert_to_snapshot(snapshot_id);
        }

        pub fn record_storage_change(self: *Self, address: Address, slot: u256, original_value: u256) anyerror!void {
            return self.inner.record_storage_change(address, slot, original_value);
        }

        pub fn get_original_storage(self: *Self, address: Address, slot: u256) ?u256 {
            return self.inner.get_original_storage(address, slot);
        }

        pub fn access_address(self: *Self, address: Address) anyerror!u64 {
            return self.inner.access_address(address);
        }

        pub fn access_storage_slot(self: *Self, contract_address: Address, slot: u256) anyerror!u64 {
            return self.inner.access_storage_slot(contract_address, slot);
        }

        pub fn register_created_contract(self: *Self, address: Address) anyerror!void {
            return self.inner.register_created_contract(address);
        }

        pub fn was_created_in_tx(self: *Self, address: Address) bool {
            return self.inner.was_created_in_tx(address);
        }

        pub fn get_transient_storage(self: *Self, address: Address, slot: u256) anyerror!u256 {
            return self.inner.get_transient_storage(address, slot);
        }

        // Write operations - all throw WriteProtection errors per EIP-214

        /// EIP-214: STATICCALL cannot emit logs
        pub fn emit_log(self: *Self, contract_address: Address, topics: []const u256, data: []const u8) void {
            _ = self;
            _ = contract_address;
            _ = topics;
            _ = data;
            // Note: This should ideally return an error, but Host interface defines emit_log as void
            // The LOG handlers check get_is_static() before calling emit_log, so this is a backup
            @panic("WriteProtection: STATICCALL cannot emit logs (EIP-214)");
        }

        /// EIP-214: STATICCALL cannot modify storage
        pub fn set_storage(self: *Self, address: Address, slot: u256, value: u256) anyerror!void {
            _ = self;
            _ = address;
            _ = slot;
            _ = value;
            return error.WriteProtection;
        }

        /// EIP-214: STATICCALL cannot modify storage
        pub fn set_transient_storage(self: *Self, address: Address, slot: u256, value: u256) anyerror!void {
            _ = self;
            _ = address;
            _ = slot;
            _ = value;
            return error.WriteProtection;
        }

        /// EIP-214: STATICCALL cannot mark contracts for destruction
        pub fn mark_for_destruction(self: *Self, contract_address: Address, recipient: Address) anyerror!void {
            _ = self;
            _ = contract_address;
            _ = recipient;
            return error.WriteProtection;
        }

        /// EIP-214: STATICCALL cannot make state-modifying calls (only STATICCALL allowed)
        pub fn inner_call(self: *Self, params: CallParams) anyerror!CallResult {
            // Only allow STATICCALL - other call types would allow state modification
            switch (params) {
                .staticcall => return self.inner.inner_call(params),
                else => return error.WriteProtection,
            }
        }
    };
}

test "StaticDatabase blocks write operations" {
    var db = Database.init(std.testing.allocator);
    defer db.deinit();

    var static_db = StaticDatabase.init(db);
    const static_interface = static_db.to_database_interface();

    // Read operations should work
    const balance = try static_interface.get_balance(Address.ZERO_ADDRESS.bytes);
    try std.testing.expectEqual(@as(u256, 0), balance);

    // Write operations should throw PermissionDenied error
    try std.testing.expectError(Database.Error.PermissionDenied, static_interface.set_balance(Address.ZERO_ADDRESS.bytes, 100));

    try std.testing.expectError(Database.Error.PermissionDenied, static_interface.set_storage(Address.ZERO_ADDRESS.bytes, 0, 42));
}
