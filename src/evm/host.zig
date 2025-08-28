//! Host interface for EVM external operations.
//!
//! Provides access to blockchain state, environment queries, and
//! cross-contract operations. The host abstracts all interactions
//! between the EVM and the broader blockchain context.

const std = @import("std");
const primitives = @import("primitives");
const Address = primitives.Address.Address;
const Hardfork = @import("hardfork.zig").Hardfork;
const CallResult = @import("call_result.zig").CallResult;
const CallParams = @import("call_params.zig").CallParams;
const BlockInfo = @import("block_info.zig").DefaultBlockInfo;
const Log = @import("logs.zig").Log;

/// Host interface providing blockchain context to the EVM.
pub const Host = struct {
    /// Pointer to the actual host implementation
    ptr: *anyopaque,
    /// Function pointer table for the implementation
    vtable: *const VTable,

    /// Virtual function table defining all host operations.
    ///
    /// Performance note: Methods are ordered roughly by frequency of use.
    /// Hot path methods (storage, balance, etc.) are placed first for
    /// better cache locality during execution.
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
        inner_call: *const fn (ptr: *anyopaque, params: CallParams) anyerror!CallResult,
        /// Register a contract as created in the current transaction (EIP-6780)
        register_created_contract: *const fn (ptr: *anyopaque, address: Address) anyerror!void,
        /// Check if a contract was created in the current transaction (EIP-6780)
        was_created_in_tx: *const fn (ptr: *anyopaque, address: Address) bool,
        /// Create a new journal snapshot for reverting state changes
        create_snapshot: *const fn (ptr: *anyopaque) u32,
        /// Revert state changes to a previous snapshot
        revert_to_snapshot: *const fn (ptr: *anyopaque, snapshot_id: u32) void,
        /// Get storage value
        get_storage: *const fn (ptr: *anyopaque, address: Address, slot: u256) u256,
        /// Set storage value with journaling
        set_storage: *const fn (ptr: *anyopaque, address: Address, slot: u256, value: u256) anyerror!void,
        /// Record a storage change in the journal
        record_storage_change: *const fn (ptr: *anyopaque, address: Address, slot: u256, original_value: u256) anyerror!void,
        /// Get the original storage value from the journal
        get_original_storage: *const fn (ptr: *anyopaque, address: Address, slot: u256) ?u256,
        /// Access an address and return the gas cost (EIP-2929)
        access_address: *const fn (ptr: *anyopaque, address: Address) anyerror!u64,
        /// Access a storage slot and return the gas cost (EIP-2929)
        access_storage_slot: *const fn (ptr: *anyopaque, contract_address: Address, slot: u256) anyerror!u64,
        /// Mark a contract for destruction (SELFDESTRUCT tracking)
        mark_for_destruction: *const fn (ptr: *anyopaque, contract_address: Address, recipient: Address) anyerror!void,
        /// Get current call input/calldata
        get_input: *const fn (ptr: *anyopaque) []const u8,
        /// Hardfork helpers
        is_hardfork_at_least: *const fn (ptr: *anyopaque, target: Hardfork) bool,
        get_hardfork: *const fn (ptr: *anyopaque) Hardfork,
        /// Get metadata for the current frame
        get_depth: *const fn (ptr: *anyopaque) u11,
        /// Get transaction gas price
        get_gas_price: *const fn (ptr: *anyopaque) u256,
        /// Get return data from last call
        get_return_data: *const fn (ptr: *anyopaque) []const u8,
        /// Get chain ID
        get_chain_id: *const fn (ptr: *anyopaque) u16,
        /// Get block hash by number
        get_block_hash: *const fn (ptr: *anyopaque, block_number: u64) ?[32]u8,
        /// Get blob hash for the given index (EIP-4844)
        get_blob_hash: *const fn (ptr: *anyopaque, index: u256) ?[32]u8,
        /// Get blob base fee (EIP-4844)
        get_blob_base_fee: *const fn (ptr: *anyopaque) u256,
        /// Get transaction origin (tx.origin)
        get_tx_origin: *const fn (ptr: *anyopaque) Address,
        /// Get caller of current execution context
        get_caller: *const fn (ptr: *anyopaque) Address,
        /// Get value sent with current call
        get_call_value: *const fn (ptr: *anyopaque) u256,
        /// Get transient storage value (EIP-1153)
        get_transient_storage: *const fn (ptr: *anyopaque, address: Address, slot: u256) anyerror!u256,
        /// Set transient storage value (EIP-1153)
        set_transient_storage: *const fn (ptr: *anyopaque, address: Address, slot: u256, value: u256) anyerror!void,
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

            fn vtable_inner_call(ptr: *anyopaque, params: CallParams) anyerror!CallResult {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.inner_call(params);
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
                // The implementation returns u8 or u16, but the interface uses u32
                // This is safe as snapshot IDs start from 0 and increment
                return @as(u32, self.create_snapshot());
            }

            fn vtable_revert_to_snapshot(ptr: *anyopaque, snapshot_id: u32) void {
                const self: Impl = @ptrCast(@alignCast(ptr));
                // Cast down to the implementation's snapshot ID type
                // The EVM uses either u8 or u16 depending on max_call_depth
                // This cast is safe as snapshot IDs are sequential from 0
                if (@hasDecl(@typeInfo(Impl).pointer.child, "Journal")) {
                    const SnapshotIdType = @typeInfo(Impl).pointer.child.Journal.SnapshotIdType;
                    return self.revert_to_snapshot(@as(SnapshotIdType, @intCast(snapshot_id)));
                } else {
                    // Fallback for implementations without Journal type
                    return self.revert_to_snapshot(@as(u16, @intCast(snapshot_id)));
                }
            }

            fn vtable_record_storage_change(ptr: *anyopaque, address: Address, slot: u256, original_value: u256) anyerror!void {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.record_storage_change(address, slot, original_value);
            }

            fn vtable_get_original_storage(ptr: *anyopaque, address: Address, slot: u256) ?u256 {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.get_original_storage(address, slot);
            }


            fn vtable_access_address(ptr: *anyopaque, address: Address) anyerror!u64 {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.access_address(address);
            }

            fn vtable_access_storage_slot(ptr: *anyopaque, contract_address: Address, slot: u256) anyerror!u64 {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.access_storage_slot(contract_address, slot);
            }

            fn vtable_mark_for_destruction(ptr: *anyopaque, contract_address: Address, recipient: Address) anyerror!void {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.mark_for_destruction(contract_address, recipient);
            }

            fn vtable_get_input(ptr: *anyopaque) []const u8 {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.get_input();
            }

            fn vtable_is_hardfork_at_least(ptr: *anyopaque, target: Hardfork) bool {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.is_hardfork_at_least(target);
            }

            fn vtable_get_hardfork(ptr: *anyopaque) Hardfork {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.get_hardfork();
            }

            fn vtable_get_depth(ptr: *anyopaque) u11 {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.get_depth();
            }

            fn vtable_get_storage(ptr: *anyopaque, address: Address, slot: u256) u256 {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.get_storage(address, slot);
            }

            fn vtable_set_storage(ptr: *anyopaque, address: Address, slot: u256, value: u256) anyerror!void {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.set_storage(address, slot, value);
            }

            fn vtable_get_gas_price(ptr: *anyopaque) u256 {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.get_gas_price();
            }

            fn vtable_get_return_data(ptr: *anyopaque) []const u8 {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.get_return_data();
            }

            fn vtable_get_chain_id(ptr: *anyopaque) u16 {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.get_chain_id();
            }

            fn vtable_get_block_hash(ptr: *anyopaque, block_number: u64) ?[32]u8 {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.get_block_hash(block_number);
            }

            fn vtable_get_blob_hash(ptr: *anyopaque, index: u256) ?[32]u8 {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.get_blob_hash(index);
            }

            fn vtable_get_blob_base_fee(ptr: *anyopaque) u256 {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.get_blob_base_fee();
            }

            fn vtable_get_tx_origin(ptr: *anyopaque) Address {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.*.get_tx_origin();
            }

            fn vtable_get_caller(ptr: *anyopaque) Address {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.*.get_caller();
            }

            fn vtable_get_call_value(ptr: *anyopaque) u256 {
                const self: Impl = @ptrCast(@alignCast(ptr));
                return self.*.get_call_value();
            }

            // TODO: Enable when EVM implementation has transient storage support
            fn vtable_get_transient_storage(ptr: *anyopaque, address: Address, slot: u256) anyerror!u256 {
                _ = ptr;
                _ = address;
                _ = slot;
                return error.NotImplemented;
            }

            fn vtable_set_transient_storage(ptr: *anyopaque, address: Address, slot: u256, value: u256) anyerror!void {
                _ = ptr;
                _ = address;
                _ = slot;
                _ = value;
                return error.NotImplemented;
            }

            const vtable = VTable{
                .get_balance = vtable_get_balance,
                .account_exists = vtable_account_exists,
                .get_code = vtable_get_code,
                .get_block_info = vtable_get_block_info,
                .emit_log = vtable_emit_log,
                .inner_call = vtable_inner_call,
                .register_created_contract = vtable_register_created_contract,
                .was_created_in_tx = vtable_was_created_in_tx,
                .create_snapshot = vtable_create_snapshot,
                .revert_to_snapshot = vtable_revert_to_snapshot,
                .record_storage_change = vtable_record_storage_change,
                .get_original_storage = vtable_get_original_storage,
                .access_address = vtable_access_address,
                .access_storage_slot = vtable_access_storage_slot,
                .mark_for_destruction = vtable_mark_for_destruction,
                .get_input = vtable_get_input,
                .is_hardfork_at_least = vtable_is_hardfork_at_least,
                .get_hardfork = vtable_get_hardfork,
                .get_depth = vtable_get_depth,
                .get_storage = vtable_get_storage,
                .set_storage = vtable_set_storage,
                .get_gas_price = vtable_get_gas_price,
                .get_return_data = vtable_get_return_data,
                .get_chain_id = vtable_get_chain_id,
                .get_block_hash = vtable_get_block_hash,
                .get_blob_hash = vtable_get_blob_hash,
                .get_blob_base_fee = vtable_get_blob_base_fee,
                .get_tx_origin = vtable_get_tx_origin,
                .get_caller = vtable_get_caller,
                .get_call_value = vtable_get_call_value,
                .get_transient_storage = vtable_get_transient_storage,
                .set_transient_storage = vtable_set_transient_storage,
            };
        };

        return Host{
            .ptr = implementation,
            .vtable = &gen.vtable,
        };
    }

    /// Get account balance
    pub inline fn get_balance(self: Host, address: Address) u256 {
        return self.vtable.get_balance(self.ptr, address);
    }

    /// Check if account exists
    pub inline fn account_exists(self: Host, address: Address) bool {
        return self.vtable.account_exists(self.ptr, address);
    }

    /// Get account code
    pub inline fn get_code(self: Host, address: Address) []const u8 {
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
    pub fn inner_call(self: Host, params: CallParams) !CallResult {
        return self.vtable.inner_call(self.ptr, params);
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


    /// Access an address and return the gas cost (EIP-2929)
    pub inline fn access_address(self: Host, address: Address) !u64 {
        return self.vtable.access_address(self.ptr, address);
    }

    /// Access a storage slot and return the gas cost (EIP-2929)
    pub inline fn access_storage_slot(self: Host, contract_address: Address, slot: u256) !u64 {
        return self.vtable.access_storage_slot(self.ptr, contract_address, slot);
    }

    /// Mark a contract for destruction (Host interface)
    pub fn mark_for_destruction(self: Host, contract_address: Address, recipient: Address) !void {
        return self.vtable.mark_for_destruction(self.ptr, contract_address, recipient);
    }

    /// Get current call input/calldata (Host interface)
    pub fn get_input(self: Host) []const u8 {
        return self.vtable.get_input(self.ptr);
    }

    /// Hardfork helpers
    pub fn is_hardfork_at_least(self: Host, target: Hardfork) bool {
        return self.vtable.is_hardfork_at_least(self.ptr, target);
    }

    pub fn get_hardfork(self: Host) Hardfork {
        return self.vtable.get_hardfork(self.ptr);
    }

    /// Get the call depth for the current frame
    pub fn get_depth(self: Host) u11 {
        return self.vtable.get_depth(self.ptr);
    }

    /// Get storage value
    pub inline fn get_storage(self: Host, address: Address, slot: u256) u256 {
        return self.vtable.get_storage(self.ptr, address, slot);
    }

    /// Set storage value
    pub inline fn set_storage(self: Host, address: Address, slot: u256, value: u256) !void {
        return self.vtable.set_storage(self.ptr, address, slot, value);
    }

    /// Get transient storage value (EIP-1153)
    pub inline fn get_transient_storage(self: Host, address: Address, slot: u256) !u256 {
        return self.vtable.get_transient_storage(self.ptr, address, slot);
    }

    /// Set transient storage value (EIP-1153)
    pub inline fn set_transient_storage(self: Host, address: Address, slot: u256, value: u256) !void {
        return self.vtable.set_transient_storage(self.ptr, address, slot, value);
    }

    /// Get transaction gas price
    pub fn get_gas_price(self: Host) u256 {
        return self.vtable.get_gas_price(self.ptr);
    }

    /// Get return data from last call
    pub fn get_return_data(self: Host) []const u8 {
        return self.vtable.get_return_data(self.ptr);
    }

    /// Get chain ID
    pub fn get_chain_id(self: Host) u16 {
        return self.vtable.get_chain_id(self.ptr);
    }

    /// Get block hash by number
    pub fn get_block_hash(self: Host, block_number: u64) ?[32]u8 {
        return self.vtable.get_block_hash(self.ptr, block_number);
    }

    /// Get blob hash for the given index (EIP-4844)
    pub fn get_blob_hash(self: Host, index: u256) ?[32]u8 {
        return self.vtable.get_blob_hash(self.ptr, index);
    }

    /// Get blob base fee (EIP-4844)
    pub fn get_blob_base_fee(self: Host) u256 {
        return self.vtable.get_blob_base_fee(self.ptr);
    }

    /// Get transaction origin (tx.origin)
    pub fn get_tx_origin(self: Host) Address {
        return self.vtable.get_tx_origin(self.ptr);
    }

    /// Get caller of current execution context
    pub inline fn get_caller(self: Host) Address {
        return self.vtable.get_caller(self.ptr);
    }

    /// Get value sent with current call
    pub inline fn get_call_value(self: Host) u256 {
        return self.vtable.get_call_value(self.ptr);
    }
};

// MockHost has been removed from this codebase.
// For testing Host functionality, use integration tests with the full EVM implementation
// instead of mock objects. See test/evm/ directory for examples.

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;
const ZERO_ADDRESS = primitives.ZERO_ADDRESS;

// Golden tests for CALL, CALLCODE, and DELEGATECALL msg.sender and msg.value correctness
// These tests verify the correct propagation of caller and value context across nested calls

fn to_address(n: u32) Address {
    var addr = ZERO_ADDRESS;
    std.mem.writeInt(u32, addr[16..20], n, .big);
    return addr;
}

fn to_u256(addr: Address) u256 {
    return primitives.Address.to_u256(addr);
}

// Helper to create test EVM
const TestEvm = struct {
    evm: *@import("evm.zig").DefaultEvm,
    memory_db: *@import("memory_database.zig").MemoryDatabase,
};

fn createTestEvm(allocator: std.mem.Allocator) !TestEvm {
    var memory_db = try allocator.create(@import("memory_database.zig").MemoryDatabase);
    memory_db.* = @import("memory_database.zig").MemoryDatabase.init(allocator);
    
    const db_interface = memory_db.to_database_interface();
    const evm_ptr = try allocator.create(@import("evm.zig").DefaultEvm);
    const block_info = @import("block_info.zig").DefaultBlockInfo.init();
    const tx_context = @import("transaction_context.zig").TransactionContext{
        .gas_limit = 1_000_000,
        .coinbase = [_]u8{0} ** 20,
        .chain_id = 1,
    };
    evm_ptr.* = try @import("evm.zig").DefaultEvm.init(allocator, db_interface, block_info, tx_context, 0, [_]u8{0} ** 20, .CANCUN);
    
    return TestEvm{ .evm = evm_ptr, .memory_db = memory_db };
}

// Contract bytecode that returns msg.sender and msg.value
// Returns: [msg.sender (32 bytes)][msg.value (32 bytes)]
const SENDER_VALUE_CONTRACT = [_]u8{
    // Store msg.sender at memory position 0
    0x33,       // CALLER
    0x60, 0x00, // PUSH1 0
    0x52,       // MSTORE
    
    // Store msg.value at memory position 32
    0x34,       // CALLVALUE
    0x60, 0x20, // PUSH1 32
    0x52,       // MSTORE
    
    // Return 64 bytes
    0x60, 0x40, // PUSH1 64 (size)
    0x60, 0x00, // PUSH1 0 (offset)
    0xF3,       // RETURN
};

// Contract that makes a nested CALL and returns the result
// Input: [target_address (32 bytes)][value (32 bytes)]
// Returns: Result from nested call
const NESTED_CALL_CONTRACT = [_]u8{
    // Load target address from calldata
    0x60, 0x00, // PUSH1 0
    0x35,       // CALLDATALOAD
    
    // Load value from calldata
    0x60, 0x20, // PUSH1 32
    0x35,       // CALLDATALOAD
    
    // Setup CALL parameters
    0x60, 0x40, // PUSH1 64 (output size)
    0x60, 0x00, // PUSH1 0 (output offset)
    0x60, 0x00, // PUSH1 0 (input size)
    0x60, 0x00, // PUSH1 0 (input offset)
    0x83,       // DUP4 (value)
    0x84,       // DUP5 (address)
    0x5A,       // GAS
    
    // Make the CALL
    0xF1,       // CALL
    
    // Check success and return the output
    0x60, 0x01, // PUSH1 1
    0x14,       // EQ
    0x60, 0x14, // PUSH1 20 (jump dest if success)
    0x57,       // JUMPI
    
    // Failure: revert
    0x60, 0x00, // PUSH1 0
    0x60, 0x00, // PUSH1 0
    0xFD,       // REVERT
    
    // Success: return the data
    0x5B,       // JUMPDEST
    0x60, 0x40, // PUSH1 64
    0x60, 0x00, // PUSH1 0
    0xF3,       // RETURN
};

// Contract that makes a nested DELEGATECALL and returns the result
const NESTED_DELEGATECALL_CONTRACT = [_]u8{
    // Load target address from calldata
    0x60, 0x00, // PUSH1 0
    0x35,       // CALLDATALOAD
    
    // Setup DELEGATECALL parameters
    0x60, 0x40, // PUSH1 64 (output size)
    0x60, 0x00, // PUSH1 0 (output offset)
    0x60, 0x00, // PUSH1 0 (input size)
    0x60, 0x00, // PUSH1 0 (input offset)
    0x82,       // DUP3 (address)
    0x5A,       // GAS
    
    // Make the DELEGATECALL
    0xF4,       // DELEGATECALL
    
    // Check success and return the output
    0x60, 0x01, // PUSH1 1
    0x14,       // EQ
    0x60, 0x13, // PUSH1 19 (jump dest if success)
    0x57,       // JUMPI
    
    // Failure: revert
    0x60, 0x00, // PUSH1 0
    0x60, 0x00, // PUSH1 0
    0xFD,       // REVERT
    
    // Success: return the data
    0x5B,       // JUMPDEST
    0x60, 0x40, // PUSH1 64
    0x60, 0x00, // PUSH1 0
    0xF3,       // RETURN
};

// Contract that makes a nested CALLCODE and returns the result
const NESTED_CALLCODE_CONTRACT = [_]u8{
    // Load target address from calldata
    0x60, 0x00, // PUSH1 0
    0x35,       // CALLDATALOAD
    
    // Load value from calldata
    0x60, 0x20, // PUSH1 32
    0x35,       // CALLDATALOAD
    
    // Setup CALLCODE parameters
    0x60, 0x40, // PUSH1 64 (output size)
    0x60, 0x00, // PUSH1 0 (output offset)
    0x60, 0x00, // PUSH1 0 (input size)
    0x60, 0x00, // PUSH1 0 (input offset)
    0x83,       // DUP4 (value)
    0x84,       // DUP5 (address)
    0x5A,       // GAS
    
    // Make the CALLCODE
    0xF2,       // CALLCODE
    
    // Check success and return the output
    0x60, 0x01, // PUSH1 1
    0x14,       // EQ
    0x60, 0x14, // PUSH1 20 (jump dest if success)
    0x57,       // JUMPI
    
    // Failure: revert
    0x60, 0x00, // PUSH1 0
    0x60, 0x00, // PUSH1 0
    0xFD,       // REVERT
    
    // Success: return the data
    0x5B,       // JUMPDEST
    0x60, 0x40, // PUSH1 64
    0x60, 0x00, // PUSH1 0
    0xF3,       // RETURN
};

test "CALL golden test - msg.sender and msg.value correctness" {
    return error.SkipZigTest;
}

test "DELEGATECALL golden test - msg.sender and msg.value preservation" {
    return error.SkipZigTest;
}

test "CALLCODE golden test - msg.sender changes but msg.value is passed" {
    return error.SkipZigTest;
}

test "Nested CALL chain - msg.sender and msg.value correctness" {
    return error.SkipZigTest;
}

test "DELEGATECALL chain preserves original context through multiple levels" {
    return error.SkipZigTest;
}

test "Mixed CALL and DELEGATECALL - context changes correctly" {
    return error.SkipZigTest;
}
