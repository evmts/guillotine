//! EVM state management module - Tracks blockchain state during execution
//!
//! This module provides the state storage layer for the EVM, managing all
//! mutable blockchain state including account balances, storage, code, nonces,
//! transient storage, and event logs.
//!
//! ## State Components
//!
//! The EVM state consists of:
//! - **Account State**: Balances, nonces, and contract code
//! - **Persistent Storage**: Contract storage slots (SSTORE/SLOAD)
//! - **Transient Storage**: Temporary storage within transactions (TSTORE/TLOAD)
//! - **Event Logs**: Emitted events from LOG0-LOG4 opcodes
//!
//! ## Design Philosophy
//!
//! This implementation now uses a pluggable database interface for state persistence,
//! allowing different storage backends (memory, file, network) to be used without
//! changing the core EVM logic. Transient storage and logs are still managed locally
//! as they are transaction-scoped.
//!
//! ## Memory Management
//!
//! State data persistence is managed by the database interface. Local data like
//! transient storage and logs are heap-allocated using the provided allocator.
//!
//! ## Thread Safety
//!
//! This implementation is NOT thread-safe. External synchronization is required
//! for concurrent access.

const std = @import("std");
const primitives = @import("primitives");
const Address = primitives.Address.Address;
const EvmLog = @import("evm_log.zig");
const StorageKey = @import("primitives").StorageKey;
const DatabaseInterface = @import("database_interface.zig").DatabaseInterface;
const DatabaseError = @import("database_interface.zig").DatabaseError;
const Account = @import("database_interface.zig").Account;
const Log = @import("../log.zig");
const tracy = @import("../tracy_support.zig");

/// EVM state container
///
/// Manages all mutable blockchain state during EVM execution.
/// This includes account data, storage, and transaction artifacts.
const EvmState = @This();

/// Memory allocator for local allocations (transient storage, logs)
allocator: std.mem.Allocator,

/// Pluggable database interface for persistent state
/// Handles accounts, storage, and code persistence
database: DatabaseInterface,

/// Transient storage (EIP-1153: TSTORE/TLOAD)
/// Maps (address, slot) -> value
/// Cleared after each transaction, not persisted in database
transient_storage: std.AutoHashMap(StorageKey, u256),

/// Event logs emitted during execution
/// Ordered list of all LOG0-LOG4 events
/// Stored locally as they are transaction-scoped
logs: std.ArrayList(EvmLog),

/// Contracts marked for destruction (SELFDESTRUCT)
/// Maps address -> recipient address for funds transfer
/// Destruction happens at end of transaction
selfdestructs: std.AutoHashMap(Address, Address),

/// Initialize a new EVM state instance with database interface
///
/// Creates empty state with the provided allocator and database interface.
/// Only transient storage and logs are initialized locally.
///
/// ## Parameters
/// - `allocator`: Memory allocator for local allocations
/// - `database`: Database interface for persistent state storage
///
/// ## Returns
/// - Success: New initialized state instance
/// - Error: OutOfMemory if allocation fails
///
/// ## Example
/// ```zig
/// const db_interface = try database_factory.createMemoryDatabase(allocator);
/// defer database_factory.destroyDatabase(allocator, db_interface);
///
/// var state = try EvmState.init(allocator, db_interface);
/// defer state.deinit();
/// ```
pub fn init(allocator: std.mem.Allocator, database: DatabaseInterface) std.mem.Allocator.Error!EvmState {
    Log.debug("EvmState.init: Initializing EVM state with database interface", .{});

    var state = EvmState{
        .allocator = allocator,
        .database = database,
        .transient_storage = std.AutoHashMap(StorageKey, u256).init(allocator),
        .logs = std.ArrayList(EvmLog).init(allocator),
        .selfdestructs = std.AutoHashMap(Address, Address).init(allocator),
    };
    errdefer {
        state.transient_storage.deinit();
        state.logs.deinit();
        state.selfdestructs.deinit();
    }

    Log.debug("EvmState.init: EVM state initialization complete", .{});
    return state;
}

/// Clean up all allocated resources
///
/// Frees all memory used by the state, including:
/// - Transient storage hash map
/// - Log data (topics and data arrays)
///
/// ## Important
/// After calling deinit(), the state instance is invalid and
/// must not be used. The database interface is NOT cleaned up
/// as it may be owned by the caller.
pub fn deinit(self: *EvmState) void {
    Log.debug("EvmState.deinit: Cleaning up EVM state, logs_count={}", .{self.logs.items.len});

    self.transient_storage.deinit();
    self.selfdestructs.deinit();

    // Clean up logs - free allocated memory for topics and data
    for (self.logs.items) |log| {
        self.allocator.free(log.topics);
        self.allocator.free(log.data);
    }
    self.logs.deinit();

    Log.debug("EvmState.deinit: EVM state cleanup complete", .{});
}

// State access methods

/// Get a value from persistent storage
///
/// Reads a storage slot for the given address through the database interface.
/// Returns 0 for uninitialized slots (EVM default).
///
/// ## Parameters
/// - `address`: Contract address
/// - `slot`: Storage slot number
///
/// ## Returns
/// The stored value, or 0 if not set or on database error
///
/// ## Gas Cost
/// In real EVM: 100-2100 gas depending on cold/warm access
pub fn get_storage(self: *const EvmState, address: Address, slot: u256) u256 {
    const zone = tracy.zone(@src(), "state_get_storage\x00");
    defer zone.end();
    
    // Use database interface to get storage value
    const value = self.database.get_storage(address, slot) catch |err| {
        @branchHint(.cold);
        Log.debug("EvmState.get_storage: Database error {}, returning 0", .{err});
        return 0;
    };

    Log.debug("EvmState.get_storage: addr={x}, slot={}, value={}", .{ primitives.Address.to_u256(address), slot, value });
    return value;
}

/// Set a value in persistent storage
///
/// Updates a storage slot for the given address through the database interface.
/// Setting a value to 0 is different from deleting it - it still consumes storage.
///
/// ## Parameters
/// - `address`: Contract address
/// - `slot`: Storage slot number
/// - `value`: Value to store
///
/// ## Returns
/// - Success: void
/// - Error: DatabaseError if storage operation fails
///
/// ## Gas Cost
/// In real EVM: 2900-20000 gas depending on current/new value
pub fn set_storage(self: *EvmState, address: Address, slot: u256, value: u256) DatabaseError!void {
    const zone = tracy.zone(@src(), "state_set_storage\x00");
    defer zone.end();
    
    Log.debug("EvmState.set_storage: addr={x}, slot={}, value={}", .{ primitives.Address.to_u256(address), slot, value });
    try self.database.set_storage(address, slot, value);
}

/// Get account balance
///
/// Returns the balance in wei for the given address through the database interface.
/// Non-existent accounts have balance 0.
///
/// ## Parameters
/// - `address`: Account address
///
/// ## Returns
/// Balance in wei (0 for non-existent accounts or on error)
pub fn get_balance(self: *const EvmState, address: Address) u256 {
    // Get account from database
    const account = self.database.get_account(address) catch |err| {
        @branchHint(.cold);
        Log.debug("EvmState.get_balance: Database error {}, returning 0", .{err});
        return 0;
    };

    if (account) |acc| {
        @branchHint(.likely);
        Log.debug("EvmState.get_balance: addr={x}, balance={}", .{ primitives.Address.to_u256(address), acc.balance });
        return acc.balance;
    } else {
        @branchHint(.cold);
        Log.debug("EvmState.get_balance: addr={x}, balance=0 (new account)", .{primitives.Address.to_u256(address)});
        return 0;
    }
}

/// Set account balance
///
/// Updates the balance for the given address through the database interface.
/// Creates the account if it doesn't exist, preserving other account data.
///
/// ## Parameters
/// - `address`: Account address
/// - `balance`: New balance in wei
///
/// ## Returns
/// - Success: void
/// - Error: DatabaseError if account operation fails
///
/// ## Note
/// Balance can exceed total ETH supply in test scenarios
pub fn set_balance(self: *EvmState, address: Address, balance: u256) DatabaseError!void {
    Log.debug("EvmState.set_balance: addr={x}, balance={}", .{ primitives.Address.to_u256(address), balance });

    // Get existing account or create new one
    var account = self.database.get_account(address) catch Account.zero();
    if (account == null) {
        account = Account.zero();
    }

    // Update balance and save account
    account.?.balance = balance;
    try self.database.set_account(address, account.?);
}

/// Remove account balance
///
/// Internal function used during revert operations to remove
/// a balance entry entirely.
///
/// ## Parameters
/// - `address`: Account address
///
/// ## Returns
/// - Success: void
/// - Error: DatabaseError if account operation fails
pub fn remove_balance(self: *EvmState, address: Address) DatabaseError!void {
    // Set balance to 0 instead of removing - database interface handles persistence
    try self.set_balance(address, 0);
}

/// Get contract code
///
/// Returns the bytecode deployed at the given address through the database interface.
/// EOAs and non-existent accounts return empty slice.
///
/// ## Parameters
/// - `address`: Contract address
///
/// ## Returns
/// Contract bytecode (empty slice for EOAs or on error)
///
/// ## Note
/// The returned slice is owned by the database - do not free
pub fn get_code(self: *const EvmState, address: Address) []const u8 {
    const zone = tracy.zone(@src(), "state_get_code\x00");
    defer zone.end();
    
    // Get account to find code hash
    const account = self.database.get_account(address) catch |err| {
        @branchHint(.cold);
        Log.debug("EvmState.get_code: Database error {}, returning empty", .{err});
        return &[_]u8{};
    };

    if (account) |acc| {
        // Check if account has code (non-zero code hash)
        const zero_hash = [_]u8{0} ** 32;
        if (std.mem.eql(u8, &acc.code_hash, &zero_hash)) {
            @branchHint(.cold);
            Log.debug("EvmState.get_code: addr={x}, code_len=0 (EOA)", .{primitives.Address.to_u256(address)});
            return &[_]u8{};
        }

        // Get code by hash
        const code = self.database.get_code(acc.code_hash) catch |err| {
            @branchHint(.cold);
            Log.debug("EvmState.get_code: Code fetch error {}, returning empty", .{err});
            return &[_]u8{};
        };

        Log.debug("EvmState.get_code: addr={x}, code_len={}", .{ primitives.Address.to_u256(address), code.len });
        return code;
    } else {
        @branchHint(.cold);
        Log.debug("EvmState.get_code: addr={x}, code_len=0 (non-existent account)", .{primitives.Address.to_u256(address)});
        return &[_]u8{};
    }
}

/// Set contract code
///
/// Deploys bytecode to the given address through the database interface.
/// Updates the account's code hash.
///
/// ## Parameters
/// - `address`: Contract address
/// - `code`: Bytecode to deploy
///
/// ## Returns
/// - Success: void
/// - Error: DatabaseError if code storage or account update fails
///
/// ## Important
/// The database interface handles code storage and copying
pub fn set_code(self: *EvmState, address: Address, code: []const u8) DatabaseError!void {
    const zone = tracy.zone(@src(), "state_set_code\x00");
    defer zone.end();
    
    Log.debug("EvmState.set_code: addr={x}, code_len={}", .{ primitives.Address.to_u256(address), code.len });

    // Store code in database and get its hash
    const code_hash = try self.database.set_code(code);

    // Get existing account or create new one
    var account = self.database.get_account(address) catch Account.zero();
    if (account == null) {
        account = Account.zero();
    }

    // Update account with new code hash
    account.?.code_hash = code_hash;
    try self.database.set_account(address, account.?);
}

/// Remove contract code
///
/// Internal function used during revert operations to remove
/// a code entry entirely.
///
/// ## Parameters
/// - `address`: Contract address
///
/// ## Returns
/// - Success: void
/// - Error: DatabaseError if account operation fails
pub fn remove_code(self: *EvmState, address: Address) DatabaseError!void {
    // Set empty code instead of removing - database interface handles persistence
    try self.set_code(address, &[_]u8{});
}

/// Get account nonce
///
/// Returns the transaction count for the given address through the database interface.
/// Non-existent accounts have nonce 0.
///
/// ## Parameters
/// - `address`: Account address
///
/// ## Returns
/// Current nonce (0 for new accounts or on error)
///
/// ## Note
/// Nonce prevents transaction replay attacks
pub fn get_nonce(self: *const EvmState, address: Address) u64 {
    // Get account from database
    const account = self.database.get_account(address) catch |err| {
        @branchHint(.cold);
        Log.debug("EvmState.get_nonce: Database error {}, returning 0", .{err});
        return 0;
    };

    if (account) |acc| {
        @branchHint(.likely);
        Log.debug("EvmState.get_nonce: addr={x}, nonce={}", .{ primitives.Address.to_u256(address), acc.nonce });
        return acc.nonce;
    } else {
        @branchHint(.cold);
        Log.debug("EvmState.get_nonce: addr={x}, nonce=0 (new account)", .{primitives.Address.to_u256(address)});
        return 0;
    }
}

/// Set account nonce
///
/// Updates the transaction count for the given address through the database interface.
///
/// ## Parameters
/// - `address`: Account address
/// - `nonce`: New nonce value
///
/// ## Returns
/// - Success: void
/// - Error: DatabaseError if account operation fails
///
/// ## Warning
/// Setting nonce below current value can enable replay attacks
pub fn set_nonce(self: *EvmState, address: Address, nonce: u64) DatabaseError!void {
    Log.debug("EvmState.set_nonce: addr={x}, nonce={}", .{ primitives.Address.to_u256(address), nonce });

    // Get existing account or create new one
    var account = self.database.get_account(address) catch Account.zero();
    if (account == null) {
        account = Account.zero();
    }

    // Update nonce and save account
    account.?.nonce = nonce;
    try self.database.set_account(address, account.?);
}

/// Remove account nonce
///
/// Internal function used during revert operations to remove
/// a nonce entry entirely.
///
/// ## Parameters
/// - `address`: Account address
///
/// ## Returns
/// - Success: void
/// - Error: DatabaseError if account operation fails
pub fn remove_nonce(self: *EvmState, address: Address) DatabaseError!void {
    // Set nonce to 0 instead of removing - database interface handles persistence
    try self.set_nonce(address, 0);
}

/// Increment account nonce
///
/// Atomically increments the nonce and returns the previous value.
/// Used when processing transactions from an account. This function
/// uses the journaled set_nonce to ensure proper revert support.
///
/// ## Parameters
/// - `address`: Account address
///
/// ## Returns
/// - Success: Previous nonce value (before increment)
/// - Error: DatabaseError if account operation fails
///
/// ## Example
/// ```zig
/// const tx_nonce = try state.increment_nonce(sender);
/// // tx_nonce is used for the transaction
/// // account nonce is now tx_nonce + 1
/// ```
pub fn increment_nonce(self: *EvmState, address: Address) DatabaseError!u64 {
    const current_nonce = self.get_nonce(address);
    const new_nonce = current_nonce + 1;
    Log.debug("EvmState.increment_nonce: addr={x}, old_nonce={}, new_nonce={}", .{ primitives.Address.to_u256(address), current_nonce, new_nonce });
    try self.set_nonce(address, new_nonce);
    return current_nonce;
}

// Transient storage methods

/// Get a value from transient storage
///
/// Reads a transient storage slot (EIP-1153). Transient storage
/// is cleared after each transaction, making it cheaper than
/// persistent storage for temporary data.
///
/// ## Parameters
/// - `address`: Contract address
/// - `slot`: Storage slot number
///
/// ## Returns
/// The stored value, or 0 if not set
///
/// ## Gas Cost
/// TLOAD: 100 gas (always warm)
pub fn get_transient_storage(self: *const EvmState, address: Address, slot: u256) u256 {
    const key = StorageKey{ .address = address, .slot = slot };
    // Hot path: transient storage hit
    if (self.transient_storage.get(key)) |value| {
        @branchHint(.likely);
        Log.debug("EvmState.get_transient_storage: addr={x}, slot={}, value={}", .{ primitives.Address.to_u256(address), slot, value });
        return value;
    } else {
        @branchHint(.cold);
        // Cold path: uninitialized transient storage defaults to 0
        Log.debug("EvmState.get_transient_storage: addr={x}, slot={}, value=0 (uninitialized)", .{ primitives.Address.to_u256(address), slot });
        return 0;
    }
}

/// Set a value in transient storage
///
/// Updates a transient storage slot (EIP-1153). Values are
/// automatically cleared after the transaction completes.
///
/// ## Parameters
/// - `address`: Contract address
/// - `slot`: Storage slot number
/// - `value`: Value to store temporarily
///
/// ## Returns
/// - Success: void
/// - Error: OutOfMemory if map expansion fails
///
/// ## Gas Cost
/// TSTORE: 100 gas (always warm)
///
/// ## Use Cases
/// - Reentrancy locks
/// - Temporary computation results
/// - Cross-contract communication within a transaction
pub fn set_transient_storage(self: *EvmState, address: Address, slot: u256, value: u256) std.mem.Allocator.Error!void {
    Log.debug("EvmState.set_transient_storage: addr={x}, slot={}, value={}", .{ primitives.Address.to_u256(address), slot, value });

    const key = StorageKey{ .address = address, .slot = slot };
    try self.transient_storage.put(key, value);
}

// Log methods

/// Emit an event log
///
/// Records an event log from LOG0-LOG4 opcodes. The log is added
/// to the transaction's log list.
///
/// ## Parameters
/// - `address`: Contract emitting the log
/// - `topics`: Indexed topics (0-4 entries)
/// - `data`: Non-indexed log data
///
/// ## Returns
/// - Success: void
/// - Error: OutOfMemory if allocation fails
///
/// ## Memory Management
/// This function copies both topics and data to ensure they
/// persist beyond the current execution context.
///
/// ## Example
/// ```zig
/// // Emit Transfer event
/// const topics = [_]u256{
///     0x123..., // Transfer event signature
///     from_addr, // indexed from
///     to_addr,   // indexed to
/// };
/// const data = encode_u256(amount);
/// try state.emit_log(contract_addr, &topics, data);
/// ```
pub fn emit_log(self: *EvmState, address: Address, topics: []const u256, data: []const u8) std.mem.Allocator.Error!void {
    Log.debug("EvmState.emit_log: addr={x}, topics_len={}, data_len={}", .{ primitives.Address.to_u256(address), topics.len, data.len });

    // Clone the data to ensure it persists
    const data_copy = try self.allocator.alloc(u8, data.len);
    errdefer self.allocator.free(data_copy);
    @memcpy(data_copy, data);

    // Clone the topics to ensure they persist
    const topics_copy = try self.allocator.alloc(u256, topics.len);
    errdefer self.allocator.free(topics_copy);
    @memcpy(topics_copy, topics);

    const log = EvmLog{
        .address = address,
        .topics = topics_copy,
        .data = data_copy,
    };

    try self.logs.append(log);
    Log.debug("EvmState.emit_log: Log emitted, total_logs={}", .{self.logs.items.len});
}

/// Remove a log entry
///
/// Internal function used during revert operations to remove
/// a log entry that was created during execution.
///
/// ## Parameters
/// - `log_index`: Index of the log to remove
///
/// ## Returns
/// - Success: void
/// - Error: If log_index is invalid
pub fn remove_log(self: *EvmState, log_index: usize) !void {
    if (log_index >= self.logs.items.len) {
        @branchHint(.cold);
        unreachable;
    }

    // Free the memory for the log we're removing
    const log_to_remove = self.logs.items[log_index];
    self.allocator.free(log_to_remove.topics);
    self.allocator.free(log_to_remove.data);

    // Remove the log by truncating the array
    // This works because logs are always removed in reverse order during revert
    if (log_index != self.logs.items.len - 1) {
        @branchHint(.cold);
        unreachable;
    }
    _ = self.logs.pop();

    Log.debug("EvmState.remove_log: Removed log at index={}, remaining_logs={}", .{ log_index, self.logs.items.len });
}

// SELFDESTRUCT methods

/// Mark a contract for destruction
///
/// Records that a contract should be destroyed at the end of the
/// transaction. The contract's balance will be transferred to the
/// recipient address.
///
/// ## Parameters
/// - `contract_address`: Address of contract to destroy
/// - `recipient`: Address to receive the contract's balance
///
/// ## Returns
/// - Success: void
/// - Error: OutOfMemory if map expansion fails
///
/// ## Note
/// Multiple SELFDESTRUCT calls on the same contract only record
/// the latest recipient address.
pub fn mark_for_destruction(self: *EvmState, contract_address: Address, recipient: Address) std.mem.Allocator.Error!void {
    Log.debug("EvmState.mark_for_destruction: contract={x}, recipient={x}", .{ primitives.Address.to_u256(contract_address), primitives.Address.to_u256(recipient) });
    try self.selfdestructs.put(contract_address, recipient);
}

/// Check if a contract is marked for destruction
///
/// Returns whether the given address has been marked for destruction
/// by a SELFDESTRUCT opcode in this transaction.
///
/// ## Parameters
/// - `address`: Contract address to check
///
/// ## Returns
/// true if marked for destruction, false otherwise
pub fn is_marked_for_destruction(self: *const EvmState, address: Address) bool {
    return self.selfdestructs.contains(address);
}

/// Get the recipient address for a destructed contract
///
/// Returns the address that will receive the balance of a
/// contract marked for destruction.
///
/// ## Parameters
/// - `address`: Contract address
///
/// ## Returns
/// - Some(recipient): If contract is marked for destruction
/// - None: If contract is not marked for destruction
pub fn get_destruction_recipient(self: *const EvmState, address: Address) ?Address {
    return self.selfdestructs.get(address);
}

/// Clear transient storage for the next transaction
///
/// Clears all transient storage slots. Called at the end of
/// each transaction as per EIP-1153.
///
/// ## Example
/// ```zig
/// // At end of transaction
/// state.clear_transient_storage();
/// ```
pub fn clear_transient_storage(self: *EvmState) void {
    Log.debug("EvmState.clear_transient_storage: Clearing transient storage", .{});
    self.transient_storage.clearAndFree();
}

/// Clear logs for a new transaction.
///
/// Removes all logs from the current collection and frees their memory.
/// This should be called at the start of each transaction to prevent
/// memory accumulation.
///
/// ## Memory Management
/// This function properly frees the allocated memory for log topics
/// and data before clearing the list.
///
/// ## Example
/// ```zig
/// // At start of new transaction
/// state.clear_logs();
/// ```
pub fn clear_logs(self: *EvmState) void {
    Log.debug("EvmState.clear_logs: Clearing {} logs", .{self.logs.items.len});
    
    // Free allocated memory for each log
    for (self.logs.items) |log| {
        self.allocator.free(log.topics);
        self.allocator.free(log.data);
    }
    
    // Clear the list while retaining capacity for future use
    self.logs.clearRetainingCapacity();
}

/// Clear selfdestruct list for a new transaction.
///
/// Removes all entries from the selfdestruct mapping. This should be
/// called after processing selfdestructs at the end of a transaction.
///
/// ## Example
/// ```zig
/// // After processing selfdestructs
/// state.clear_selfdestructs();
/// ```
pub fn clear_selfdestructs(self: *EvmState) void {
    Log.debug("EvmState.clear_selfdestructs: Clearing {} selfdestructs", .{self.selfdestructs.count()});
    self.selfdestructs.clearRetainingCapacity();
}

/// Clear all transaction-scoped state.
///
/// Convenience function that clears transient storage, logs, and
/// selfdestructs in one call. Use this at transaction boundaries.
///
/// ## Example
/// ```zig
/// // At end of transaction
/// state.clear_transaction_state();
/// ```
pub fn clear_transaction_state(self: *EvmState) void {
    Log.debug("EvmState.clear_transaction_state: Clearing all transaction state", .{});
    self.clear_transient_storage();
    self.clear_logs();
    self.clear_selfdestructs();
}

// Tests

const testing = std.testing;
const MemoryDatabase = @import("memory_database.zig").MemoryDatabase;

// Helper function to create test addresses
fn testAddress(value: u160) Address {
    return primitives.Address.from_u256(@as(u256, value));
}

test "EvmState initialization and deinitialization" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var state = try EvmState.init(allocator, db_interface);
    defer state.deinit();

    // Verify initial state
    try testing.expectEqual(@as(usize, 0), state.logs.items.len);
    try testing.expectEqual(@as(usize, 0), state.transient_storage.count());
    try testing.expectEqual(@as(usize, 0), state.selfdestructs.count());
}

test "EvmState account creation and retrieval" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var state = try EvmState.init(allocator, db_interface);
    defer state.deinit();

    const addr = testAddress(0x1234567890123456789012345678901234567890);

    // Initially account doesn't exist
    try testing.expectEqual(@as(u256, 0), state.get_balance(addr));
    try testing.expectEqual(@as(u64, 0), state.get_nonce(addr));
    try testing.expectEqual(@as(usize, 0), state.get_code(addr).len);

    // Create account by setting balance
    try state.set_balance(addr, 1000);
    try testing.expectEqual(@as(u256, 1000), state.get_balance(addr));

    // Nonce should still be 0
    try testing.expectEqual(@as(u64, 0), state.get_nonce(addr));
}

test "EvmState balance operations" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var state = try EvmState.init(allocator, db_interface);
    defer state.deinit();

    const addr1 = testAddress(0x1111);
    const addr2 = testAddress(0x2222);

    // Test set and get balance
    try state.set_balance(addr1, 5000);
    try testing.expectEqual(@as(u256, 5000), state.get_balance(addr1));

    // Test balance update
    try state.set_balance(addr1, 10000);
    try testing.expectEqual(@as(u256, 10000), state.get_balance(addr1));

    // Test multiple accounts
    try state.set_balance(addr2, 3000);
    try testing.expectEqual(@as(u256, 10000), state.get_balance(addr1));
    try testing.expectEqual(@as(u256, 3000), state.get_balance(addr2));

    // Test balance removal
    try state.remove_balance(addr1);
    try testing.expectEqual(@as(u256, 0), state.get_balance(addr1));
    try testing.expectEqual(@as(u256, 3000), state.get_balance(addr2));

    // Test max balance
    const max_balance = std.math.maxInt(u256);
    try state.set_balance(addr1, max_balance);
    try testing.expectEqual(max_balance, state.get_balance(addr1));
}

test "EvmState storage operations" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var state = try EvmState.init(allocator, db_interface);
    defer state.deinit();

    const addr = testAddress(0x3333);

    // Test initial storage value (should be 0)
    try testing.expectEqual(@as(u256, 0), state.get_storage(addr, 0));
    try testing.expectEqual(@as(u256, 0), state.get_storage(addr, 100));

    // Test set and get storage
    try state.set_storage(addr, 0, 42);
    try testing.expectEqual(@as(u256, 42), state.get_storage(addr, 0));

    // Test multiple slots
    try state.set_storage(addr, 1, 100);
    try state.set_storage(addr, 2, 200);
    try state.set_storage(addr, 1000, 999);

    try testing.expectEqual(@as(u256, 42), state.get_storage(addr, 0));
    try testing.expectEqual(@as(u256, 100), state.get_storage(addr, 1));
    try testing.expectEqual(@as(u256, 200), state.get_storage(addr, 2));
    try testing.expectEqual(@as(u256, 999), state.get_storage(addr, 1000));

    // Test storage update
    try state.set_storage(addr, 1, 150);
    try testing.expectEqual(@as(u256, 150), state.get_storage(addr, 1));

    // Test setting storage to 0 (should not delete, just set to 0)
    try state.set_storage(addr, 2, 0);
    try testing.expectEqual(@as(u256, 0), state.get_storage(addr, 2));

    // Test max slot value
    const max_slot = std.math.maxInt(u256);
    try state.set_storage(addr, max_slot, 12345);
    try testing.expectEqual(@as(u256, 12345), state.get_storage(addr, max_slot));
}

test "EvmState code operations" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var state = try EvmState.init(allocator, db_interface);
    defer state.deinit();

    const addr = testAddress(0x4444);

    // Test initial code (should be empty)
    try testing.expectEqual(@as(usize, 0), state.get_code(addr).len);

    // Test set and get code
    const code = &[_]u8{ 0x60, 0x80, 0x60, 0x40, 0x52 };
    try state.set_code(addr, code);
    const retrieved_code = state.get_code(addr);
    try testing.expectEqualSlices(u8, code, retrieved_code);

    // Test code update
    const new_code = &[_]u8{ 0x60, 0x00, 0x60, 0x00, 0x50 };
    try state.set_code(addr, new_code);
    const updated_code = state.get_code(addr);
    try testing.expectEqualSlices(u8, new_code, updated_code);

    // Test code removal
    try state.remove_code(addr);
    try testing.expectEqual(@as(usize, 0), state.get_code(addr).len);

    // Test empty code
    try state.set_code(addr, &[_]u8{});
    try testing.expectEqual(@as(usize, 0), state.get_code(addr).len);

    // Test large code
    const large_code = try allocator.alloc(u8, 10000);
    defer allocator.free(large_code);
    for (large_code, 0..) |*byte, i| {
        byte.* = @intCast(i % 256);
    }
    try state.set_code(addr, large_code);
    const retrieved_large_code = state.get_code(addr);
    try testing.expectEqualSlices(u8, large_code, retrieved_large_code);
}

test "EvmState nonce operations" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var state = try EvmState.init(allocator, db_interface);
    defer state.deinit();

    const addr = testAddress(0x5555);

    // Test initial nonce (should be 0)
    try testing.expectEqual(@as(u64, 0), state.get_nonce(addr));

    // Test set and get nonce
    try state.set_nonce(addr, 5);
    try testing.expectEqual(@as(u64, 5), state.get_nonce(addr));

    // Test nonce update
    try state.set_nonce(addr, 10);
    try testing.expectEqual(@as(u64, 10), state.get_nonce(addr));

    // Test increment nonce
    const prev_nonce = try state.increment_nonce(addr);
    try testing.expectEqual(@as(u64, 10), prev_nonce);
    try testing.expectEqual(@as(u64, 11), state.get_nonce(addr));

    // Test multiple increments
    _ = try state.increment_nonce(addr);
    _ = try state.increment_nonce(addr);
    try testing.expectEqual(@as(u64, 13), state.get_nonce(addr));

    // Test nonce removal
    try state.remove_nonce(addr);
    try testing.expectEqual(@as(u64, 0), state.get_nonce(addr));

    // Test max nonce
    const max_nonce = std.math.maxInt(u64) - 1;
    try state.set_nonce(addr, max_nonce);
    try testing.expectEqual(max_nonce, state.get_nonce(addr));
    const prev = try state.increment_nonce(addr);
    try testing.expectEqual(max_nonce, prev);
    try testing.expectEqual(max_nonce + 1, state.get_nonce(addr));
}

test "EvmState transient storage operations" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var state = try EvmState.init(allocator, db_interface);
    defer state.deinit();

    const addr1 = testAddress(0x6666);
    const addr2 = testAddress(0x7777);

    // Test initial transient storage (should be 0)
    try testing.expectEqual(@as(u256, 0), state.get_transient_storage(addr1, 0));
    try testing.expectEqual(@as(u256, 0), state.get_transient_storage(addr1, 100));

    // Test set and get transient storage
    try state.set_transient_storage(addr1, 0, 42);
    try testing.expectEqual(@as(u256, 42), state.get_transient_storage(addr1, 0));

    // Test multiple addresses and slots
    try state.set_transient_storage(addr1, 1, 100);
    try state.set_transient_storage(addr2, 0, 200);
    try state.set_transient_storage(addr2, 1, 300);

    try testing.expectEqual(@as(u256, 42), state.get_transient_storage(addr1, 0));
    try testing.expectEqual(@as(u256, 100), state.get_transient_storage(addr1, 1));
    try testing.expectEqual(@as(u256, 200), state.get_transient_storage(addr2, 0));
    try testing.expectEqual(@as(u256, 300), state.get_transient_storage(addr2, 1));

    // Test update
    try state.set_transient_storage(addr1, 0, 99);
    try testing.expectEqual(@as(u256, 99), state.get_transient_storage(addr1, 0));

    // Test clear transient storage
    state.clear_transient_storage();
    try testing.expectEqual(@as(u256, 0), state.get_transient_storage(addr1, 0));
    try testing.expectEqual(@as(u256, 0), state.get_transient_storage(addr1, 1));
    try testing.expectEqual(@as(u256, 0), state.get_transient_storage(addr2, 0));
    try testing.expectEqual(@as(u256, 0), state.get_transient_storage(addr2, 1));
}

test "EvmState log operations" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var state = try EvmState.init(allocator, db_interface);
    defer state.deinit();

    const addr = testAddress(0x8888);

    // Test initial logs (should be empty)
    try testing.expectEqual(@as(usize, 0), state.logs.items.len);

    // Test emit log with no topics
    const data1 = &[_]u8{ 0x01, 0x02, 0x03 };
    try state.emit_log(addr, &[_]u256{}, data1);
    try testing.expectEqual(@as(usize, 1), state.logs.items.len);
    try testing.expectEqual(addr, state.logs.items[0].address);
    try testing.expectEqual(@as(usize, 0), state.logs.items[0].topics.len);
    try testing.expectEqualSlices(u8, data1, state.logs.items[0].data);

    // Test emit log with topics
    const topics = &[_]u256{ 100, 200, 300 };
    const data2 = &[_]u8{ 0x04, 0x05, 0x06, 0x07 };
    try state.emit_log(addr, topics, data2);
    try testing.expectEqual(@as(usize, 2), state.logs.items.len);
    try testing.expectEqual(@as(usize, 3), state.logs.items[1].topics.len);
    try testing.expectEqualSlices(u256, topics, state.logs.items[1].topics);
    try testing.expectEqualSlices(u8, data2, state.logs.items[1].data);

    // Test emit log with max topics (4)
    const max_topics = &[_]u256{ 1, 2, 3, 4 };
    const data3 = &[_]u8{};
    try state.emit_log(addr, max_topics, data3);
    try testing.expectEqual(@as(usize, 3), state.logs.items.len);
    try testing.expectEqual(@as(usize, 4), state.logs.items[2].topics.len);
    try testing.expectEqual(@as(usize, 0), state.logs.items[2].data.len);

    // Test remove log
    try state.remove_log(2);
    try testing.expectEqual(@as(usize, 2), state.logs.items.len);

    // Remove remaining logs in reverse order
    try state.remove_log(1);
    try state.remove_log(0);
    try testing.expectEqual(@as(usize, 0), state.logs.items.len);
}

test "EvmState selfdestruct operations" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var state = try EvmState.init(allocator, db_interface);
    defer state.deinit();

    const contract = testAddress(0x9999);
    const recipient1 = testAddress(0xAAAA);
    const recipient2 = testAddress(0xBBBB);

    // Test initial state
    try testing.expect(!state.is_marked_for_destruction(contract));
    try testing.expectEqual(@as(?Address, null), state.get_destruction_recipient(contract));

    // Test mark for destruction
    try state.mark_for_destruction(contract, recipient1);
    try testing.expect(state.is_marked_for_destruction(contract));
    try testing.expectEqual(@as(?Address, recipient1), state.get_destruction_recipient(contract));

    // Test update recipient (multiple selfdestruct calls)
    try state.mark_for_destruction(contract, recipient2);
    try testing.expect(state.is_marked_for_destruction(contract));
    try testing.expectEqual(@as(?Address, recipient2), state.get_destruction_recipient(contract));

    // Test multiple contracts
    const contract2 = testAddress(0xCCCC);
    try state.mark_for_destruction(contract2, recipient1);
    try testing.expect(state.is_marked_for_destruction(contract));
    try testing.expect(state.is_marked_for_destruction(contract2));
    try testing.expectEqual(@as(?Address, recipient2), state.get_destruction_recipient(contract));
    try testing.expectEqual(@as(?Address, recipient1), state.get_destruction_recipient(contract2));
}

test "EvmState combined operations" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var state = try EvmState.init(allocator, db_interface);
    defer state.deinit();

    const addr = testAddress(0xDDDD);

    // Create a complete account
    try state.set_balance(addr, 1000000);
    try state.set_nonce(addr, 5);
    const code = &[_]u8{ 0x60, 0x80, 0x60, 0x40 };
    try state.set_code(addr, code);
    try state.set_storage(addr, 0, 42);
    try state.set_storage(addr, 1, 100);

    // Verify all data
    try testing.expectEqual(@as(u256, 1000000), state.get_balance(addr));
    try testing.expectEqual(@as(u64, 5), state.get_nonce(addr));
    try testing.expectEqualSlices(u8, code, state.get_code(addr));
    try testing.expectEqual(@as(u256, 42), state.get_storage(addr, 0));
    try testing.expectEqual(@as(u256, 100), state.get_storage(addr, 1));

    // Add transient storage and logs
    try state.set_transient_storage(addr, 0, 999);
    const topics = &[_]u256{123};
    const data = &[_]u8{0xFF};
    try state.emit_log(addr, topics, data);

    // Verify transient data
    try testing.expectEqual(@as(u256, 999), state.get_transient_storage(addr, 0));
    try testing.expectEqual(@as(usize, 1), state.logs.items.len);

    // Clear transient storage
    state.clear_transient_storage();
    try testing.expectEqual(@as(u256, 0), state.get_transient_storage(addr, 0));

    // Persistent data should remain
    try testing.expectEqual(@as(u256, 1000000), state.get_balance(addr));
    try testing.expectEqual(@as(u256, 42), state.get_storage(addr, 0));
}

test "EvmState edge cases" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var state = try EvmState.init(allocator, db_interface);
    defer state.deinit();

    // Test zero address
    const zero_addr = primitives.Address.ZERO_ADDRESS;
    try state.set_balance(zero_addr, 1000);
    try testing.expectEqual(@as(u256, 1000), state.get_balance(zero_addr));

    // Test operations on non-existent account
    const non_existent = testAddress(0xFFFF);
    try testing.expectEqual(@as(u256, 0), state.get_balance(non_existent));
    try testing.expectEqual(@as(u64, 0), state.get_nonce(non_existent));
    try testing.expectEqual(@as(usize, 0), state.get_code(non_existent).len);
    try testing.expectEqual(@as(u256, 0), state.get_storage(non_existent, 0));
    try testing.expectEqual(@as(u256, 0), state.get_transient_storage(non_existent, 0));

    // Test empty log
    try state.emit_log(zero_addr, &[_]u256{}, &[_]u8{});
    try testing.expectEqual(@as(usize, 1), state.logs.items.len);
    try testing.expectEqual(@as(usize, 0), state.logs.items[0].topics.len);
    try testing.expectEqual(@as(usize, 0), state.logs.items[0].data.len);

    // Test large storage slot number
    const large_slot = std.math.maxInt(u256);
    try state.set_storage(zero_addr, large_slot, 12345);
    try testing.expectEqual(@as(u256, 12345), state.get_storage(zero_addr, large_slot));

    // Test large transient storage slot
    try state.set_transient_storage(zero_addr, large_slot, 67890);
    try testing.expectEqual(@as(u256, 67890), state.get_transient_storage(zero_addr, large_slot));
}

// Fuzz tests

test "EvmState fuzz: storage operations with random addresses and slots" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var state = try EvmState.init(allocator, db_interface);
    defer state.deinit();

    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();

    // Track expected values for verification
    var expected = std.AutoHashMap(StorageKey, u256).init(allocator);
    defer expected.deinit();

    // Fuzz 1000 storage operations
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        // Generate random address and slot
        const addr_value = random.int(u160);
        const addr = testAddress(addr_value);
        const slot = random.int(u256);
        const value = random.int(u256);

        // Set storage
        try state.set_storage(addr, slot, value);
        
        // Track expected value
        const key = StorageKey{ .address = addr, .slot = slot };
        try expected.put(key, value);

        // Verify storage read
        try testing.expectEqual(value, state.get_storage(addr, slot));
    }

    // Verify all stored values are correct
    var iter = expected.iterator();
    while (iter.next()) |entry| {
        const stored = state.get_storage(entry.key_ptr.address, entry.key_ptr.slot);
        try testing.expectEqual(entry.value_ptr.*, stored);
    }

    // Test edge values
    const edge_addresses = [_]u160{0, 1, std.math.maxInt(u160) - 1, std.math.maxInt(u160)};
    const edge_slots = [_]u256{0, 1, std.math.maxInt(u256) - 1, std.math.maxInt(u256)};
    const edge_values = [_]u256{0, 1, std.math.maxInt(u256) - 1, std.math.maxInt(u256)};

    for (edge_addresses) |addr_val| {
        const addr = testAddress(addr_val);
        for (edge_slots) |slot| {
            for (edge_values) |value| {
                try state.set_storage(addr, slot, value);
                try testing.expectEqual(value, state.get_storage(addr, slot));
            }
        }
    }
}

test "EvmState fuzz: transient storage lifecycle with random data" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var state = try EvmState.init(allocator, db_interface);
    defer state.deinit();

    var prng = std.Random.DefaultPrng.init(123);
    const random = prng.random();

    // First transaction - set random transient storage
    var expected_transient = std.AutoHashMap(StorageKey, u256).init(allocator);
    defer expected_transient.deinit();

    var i: usize = 0;
    while (i < 500) : (i += 1) {
        const addr = testAddress(random.int(u160));
        const slot = random.int(u256);
        const value = random.int(u256);

        try state.set_transient_storage(addr, slot, value);
        
        const key = StorageKey{ .address = addr, .slot = slot };
        try expected_transient.put(key, value);
    }

    // Verify all transient values
    var iter = expected_transient.iterator();
    while (iter.next()) |entry| {
        const stored = state.get_transient_storage(entry.key_ptr.address, entry.key_ptr.slot);
        try testing.expectEqual(entry.value_ptr.*, stored);
    }

    // Clear transient storage (simulating transaction end)
    state.clear_transient_storage();

    // Verify all transient storage is cleared
    iter = expected_transient.iterator();
    while (iter.next()) |entry| {
        const stored = state.get_transient_storage(entry.key_ptr.address, entry.key_ptr.slot);
        try testing.expectEqual(@as(u256, 0), stored);
    }

    // Test memory growth with many unique keys
    i = 0;
    while (i < 1000) : (i += 1) {
        const addr = testAddress(@intCast(i));
        const slot = @as(u256, i);
        const value = @as(u256, i * 1000);
        
        try state.set_transient_storage(addr, slot, value);
        try testing.expectEqual(value, state.get_transient_storage(addr, slot));
    }

    // Verify count
    try testing.expectEqual(@as(usize, 1000), state.transient_storage.count());

    // Clear again
    state.clear_transient_storage();
    try testing.expectEqual(@as(usize, 0), state.transient_storage.count());
}

test "EvmState fuzz: log operations with random data sizes" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var state = try EvmState.init(allocator, db_interface);
    defer state.deinit();

    var prng = std.Random.DefaultPrng.init(456);
    const random = prng.random();

    // Test various topic counts (0-4) and data sizes
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const addr = testAddress(random.int(u160));
        const num_topics = random.intRangeAtMost(usize, 0, 4);
        const data_size = random.intRangeAtMost(usize, 0, 1024);

        // Generate random topics
        var topics_buf: [4]u256 = undefined;
        var j: usize = 0;
        while (j < num_topics) : (j += 1) {
            topics_buf[j] = random.int(u256);
        }
        const topics = topics_buf[0..num_topics];

        // Generate random data
        const data = try allocator.alloc(u8, data_size);
        defer allocator.free(data);
        random.bytes(data);

        // Emit log
        const initial_log_count = state.logs.items.len;
        try state.emit_log(addr, topics, data);

        // Verify log was added
        try testing.expectEqual(initial_log_count + 1, state.logs.items.len);
        
        const log = state.logs.items[state.logs.items.len - 1];
        try testing.expectEqual(addr, log.address);
        try testing.expectEqual(num_topics, log.topics.len);
        try testing.expectEqualSlices(u256, topics, log.topics);
        try testing.expectEqual(data_size, log.data.len);
        try testing.expectEqualSlices(u8, data, log.data);
    }

    // Test log removal in reverse order
    while (state.logs.items.len > 0) {
        const last_index = state.logs.items.len - 1;
        try state.remove_log(last_index);
    }
    try testing.expectEqual(@as(usize, 0), state.logs.items.len);

    // Test large data
    const large_data = try allocator.alloc(u8, 100_000);
    defer allocator.free(large_data);
    random.bytes(large_data);
    
    try state.emit_log(testAddress(0x1234), &[_]u256{}, large_data);
    try testing.expectEqual(@as(usize, 1), state.logs.items.len);
    try testing.expectEqual(@as(usize, 100_000), state.logs.items[0].data.len);
}

test "EvmState fuzz: account state consistency with random operations" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var state = try EvmState.init(allocator, db_interface);
    defer state.deinit();

    var prng = std.Random.DefaultPrng.init(789);
    const random = prng.random();

    // Test 500 random account operations
    var i: usize = 0;
    while (i < 500) : (i += 1) {
        const addr = testAddress(random.int(u160));
        
        // Random balance operations
        if (random.boolean()) {
            const balance = random.int(u256);
            try state.set_balance(addr, balance);
            
            // Invariant: Balance should be retrievable
            try testing.expectEqual(balance, state.get_balance(addr));
        }

        // Random nonce operations
        if (random.boolean()) {
            const current_nonce = state.get_nonce(addr);
            
            if (random.boolean()) {
                // Set specific nonce
                const new_nonce = random.int(u64);
                try state.set_nonce(addr, new_nonce);
                try testing.expectEqual(new_nonce, state.get_nonce(addr));
            } else {
                // Increment nonce
                const prev_nonce = try state.increment_nonce(addr);
                try testing.expectEqual(current_nonce, prev_nonce);
                try testing.expectEqual(current_nonce + 1, state.get_nonce(addr));
                
                // Invariant: Nonce monotonically increases
                try testing.expect(state.get_nonce(addr) > prev_nonce);
            }
        }

        // Random code operations
        if (random.boolean()) {
            const code_size = random.intRangeAtMost(usize, 0, 1000);
            const code = try allocator.alloc(u8, code_size);
            defer allocator.free(code);
            random.bytes(code);
            
            try state.set_code(addr, code);
            
            // Invariant: Code should be retrievable
            const retrieved_code = state.get_code(addr);
            try testing.expectEqualSlices(u8, code, retrieved_code);
        }
    }
}

test "EvmState fuzz: selfdestruct operations with random contracts" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var state = try EvmState.init(allocator, db_interface);
    defer state.deinit();

    var prng = std.Random.DefaultPrng.init(999);
    const random = prng.random();

    // Track expected selfdestructs
    var expected_destructs = std.AutoHashMap(Address, Address).init(allocator);
    defer expected_destructs.deinit();

    // Fuzz 200 selfdestruct operations
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        const contract = testAddress(random.int(u160));
        const recipient = testAddress(random.int(u160));

        try state.mark_for_destruction(contract, recipient);
        try expected_destructs.put(contract, recipient);

        // Invariant: Contract should be marked for destruction
        try testing.expect(state.is_marked_for_destruction(contract));
        try testing.expectEqual(@as(?Address, recipient), state.get_destruction_recipient(contract));
    }

    // Verify all destructions
    var iter = expected_destructs.iterator();
    while (iter.next()) |entry| {
        try testing.expect(state.is_marked_for_destruction(entry.key_ptr.*));
        try testing.expectEqual(@as(?Address, entry.value_ptr.*), state.get_destruction_recipient(entry.key_ptr.*));
    }

    // Test multiple selfdestructs on same contract (should update recipient)
    const test_contract = testAddress(0xDEAD);
    const recipients = [_]Address{
        testAddress(0x1111),
        testAddress(0x2222),
        testAddress(0x3333),
    };

    for (recipients) |recipient| {
        try state.mark_for_destruction(test_contract, recipient);
        try testing.expectEqual(@as(?Address, recipient), state.get_destruction_recipient(test_contract));
    }
}

test "EvmState fuzz: memory pressure with many accounts" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var state = try EvmState.init(allocator, db_interface);
    defer state.deinit();

    var prng = std.Random.DefaultPrng.init(1234);
    const random = prng.random();

    // Create many accounts with random data
    const num_accounts = 1000;
    var i: usize = 0;
    while (i < num_accounts) : (i += 1) {
        const addr = testAddress(@intCast(i));
        
        // Set random balance
        const balance = random.int(u256);
        try state.set_balance(addr, balance);
        
        // Set random nonce
        const nonce = random.int(u64);
        try state.set_nonce(addr, nonce);
        
        // Set random code (10% chance)
        if (random.intRangeAtMost(u8, 0, 9) == 0) {
            const code_size = random.intRangeAtMost(usize, 1, 100);
            const code = try allocator.alloc(u8, code_size);
            defer allocator.free(code);
            random.bytes(code);
            try state.set_code(addr, code);
        }
        
        // Set random storage (5 slots per account)
        var j: usize = 0;
        while (j < 5) : (j += 1) {
            const slot = random.int(u256);
            const value = random.int(u256);
            try state.set_storage(addr, slot, value);
        }
    }

    // Add many transient storage entries
    i = 0;
    while (i < 5000) : (i += 1) {
        const addr = testAddress(random.intRangeAtMost(u160, 0, num_accounts - 1));
        const slot = random.int(u256);
        const value = random.int(u256);
        try state.set_transient_storage(addr, slot, value);
    }

    // Add many logs
    i = 0;
    while (i < 100) : (i += 1) {
        const addr = testAddress(random.intRangeAtMost(u160, 0, num_accounts - 1));
        const num_topics = random.intRangeAtMost(usize, 0, 4);
        
        var topics_buf: [4]u256 = undefined;
        var j: usize = 0;
        while (j < num_topics) : (j += 1) {
            topics_buf[j] = random.int(u256);
        }
        
        const data_size = random.intRangeAtMost(usize, 0, 1000);
        const data = try allocator.alloc(u8, data_size);
        defer allocator.free(data);
        random.bytes(data);
        
        try state.emit_log(addr, topics_buf[0..num_topics], data);
    }

    // Verify state is still functional
    try testing.expect(state.transient_storage.count() > 0);
    try testing.expect(state.logs.items.len == 100);
}

test "EvmState fuzz: state transitions with random operation sequences" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var state = try EvmState.init(allocator, db_interface);
    defer state.deinit();

    var prng = std.Random.DefaultPrng.init(5678);
    const random = prng.random();

    // Define operation types
    const OperationType = enum {
        set_balance,
        set_nonce,
        increment_nonce,
        set_code,
        set_storage,
        set_transient_storage,
        emit_log,
        mark_for_destruction,
    };

    // Execute 1000 random operations
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const op_type = random.enumValue(OperationType);
        const addr = testAddress(random.intRangeAtMost(u160, 0, 99)); // Use limited address range

        switch (op_type) {
            .set_balance => {
                const balance = random.int(u256);
                try state.set_balance(addr, balance);
                try testing.expectEqual(balance, state.get_balance(addr));
            },
            .set_nonce => {
                const nonce = random.int(u64);
                try state.set_nonce(addr, nonce);
                try testing.expectEqual(nonce, state.get_nonce(addr));
            },
            .increment_nonce => {
                const prev = state.get_nonce(addr);
                const returned = try state.increment_nonce(addr);
                try testing.expectEqual(prev, returned);
                try testing.expectEqual(prev + 1, state.get_nonce(addr));
            },
            .set_code => {
                const code_size = random.intRangeAtMost(usize, 0, 100);
                const code = try allocator.alloc(u8, code_size);
                defer allocator.free(code);
                random.bytes(code);
                try state.set_code(addr, code);
                try testing.expectEqualSlices(u8, code, state.get_code(addr));
            },
            .set_storage => {
                const slot = random.int(u256);
                const value = random.int(u256);
                try state.set_storage(addr, slot, value);
                try testing.expectEqual(value, state.get_storage(addr, slot));
            },
            .set_transient_storage => {
                const slot = random.int(u256);
                const value = random.int(u256);
                try state.set_transient_storage(addr, slot, value);
                try testing.expectEqual(value, state.get_transient_storage(addr, slot));
            },
            .emit_log => {
                const num_topics = random.intRangeAtMost(usize, 0, 4);
                var topics_buf: [4]u256 = undefined;
                var j: usize = 0;
                while (j < num_topics) : (j += 1) {
                    topics_buf[j] = random.int(u256);
                }
                const data_size = random.intRangeAtMost(usize, 0, 100);
                const data = try allocator.alloc(u8, data_size);
                defer allocator.free(data);
                random.bytes(data);
                const prev_log_count = state.logs.items.len;
                try state.emit_log(addr, topics_buf[0..num_topics], data);
                try testing.expectEqual(prev_log_count + 1, state.logs.items.len);
            },
            .mark_for_destruction => {
                const recipient = testAddress(random.int(u160));
                try state.mark_for_destruction(addr, recipient);
                try testing.expect(state.is_marked_for_destruction(addr));
                try testing.expectEqual(@as(?Address, recipient), state.get_destruction_recipient(addr));
            },
        }
    }
}

test "EvmState fuzz: invariant testing - destroyed contracts cannot be modified" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var state = try EvmState.init(allocator, db_interface);
    defer state.deinit();

    var prng = std.Random.DefaultPrng.init(9999);
    const random = prng.random();

    // Test 100 contracts
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const contract = testAddress(random.int(u160));
        const recipient = testAddress(random.int(u160));

        // Set initial state
        const initial_balance = random.int(u256);
        const initial_nonce = random.int(u64);
        const initial_code = &[_]u8{0x60, 0x00};
        
        try state.set_balance(contract, initial_balance);
        try state.set_nonce(contract, initial_nonce);
        try state.set_code(contract, initial_code);

        // Mark for destruction
        try state.mark_for_destruction(contract, recipient);

        // Invariant: Contract is marked for destruction
        try testing.expect(state.is_marked_for_destruction(contract));

        // Note: In this implementation, we can still modify destroyed contracts
        // This is because actual destruction happens at transaction end
        // The test verifies current behavior, not ideal behavior
        
        // Modifications should still work (current behavior)
        const new_balance = random.int(u256);
        try state.set_balance(contract, new_balance);
        try testing.expectEqual(new_balance, state.get_balance(contract));
    }
}

test "EvmState fuzz: edge value testing with extreme values" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var state = try EvmState.init(allocator, db_interface);
    defer state.deinit();

    // Test extreme addresses
    const extreme_addresses = [_]Address{
        primitives.Address.ZERO_ADDRESS,
        testAddress(1),
        testAddress(std.math.maxInt(u160) - 1),
        testAddress(std.math.maxInt(u160)),
    };

    for (extreme_addresses) |addr| {
        // Max balance
        try state.set_balance(addr, std.math.maxInt(u256));
        try testing.expectEqual(std.math.maxInt(u256), state.get_balance(addr));

        // Max nonce
        try state.set_nonce(addr, std.math.maxInt(u64));
        try testing.expectEqual(std.math.maxInt(u64), state.get_nonce(addr));

        // Max storage values
        try state.set_storage(addr, 0, std.math.maxInt(u256));
        try state.set_storage(addr, std.math.maxInt(u256), std.math.maxInt(u256));
        try testing.expectEqual(std.math.maxInt(u256), state.get_storage(addr, 0));
        try testing.expectEqual(std.math.maxInt(u256), state.get_storage(addr, std.math.maxInt(u256)));

        // Max transient storage
        try state.set_transient_storage(addr, std.math.maxInt(u256), std.math.maxInt(u256));
        try testing.expectEqual(std.math.maxInt(u256), state.get_transient_storage(addr, std.math.maxInt(u256)));

        // Empty and large code
        try state.set_code(addr, &[_]u8{});
        try testing.expectEqual(@as(usize, 0), state.get_code(addr).len);

        const large_code = try allocator.alloc(u8, 24576); // 24KB max contract size
        defer allocator.free(large_code);
        @memset(large_code, 0x60); // PUSH1
        try state.set_code(addr, large_code);
        try testing.expectEqual(@as(usize, 24576), state.get_code(addr).len);
    }

    // Test max topics in logs
    const max_topics = [_]u256{
        std.math.maxInt(u256),
        std.math.maxInt(u256) - 1,
        std.math.maxInt(u256) - 2,
        std.math.maxInt(u256) - 3,
    };
    const max_data = try allocator.alloc(u8, 1024);
    defer allocator.free(max_data);
    @memset(max_data, 0xFF);
    
    try state.emit_log(extreme_addresses[0], &max_topics, max_data);
    const log = state.logs.items[state.logs.items.len - 1];
    try testing.expectEqualSlices(u256, &max_topics, log.topics);
}

test "EvmState clear_logs properly frees memory" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var state = try EvmState.init(allocator, db_interface);
    defer state.deinit();

    const addr = testAddress(0x1234);

    // Emit multiple logs with varying data sizes
    for (0..10) |i| {
        const topics = [_]u256{ i, i * 2, i * 3 };
        const data_size = (i + 1) * 100;
        const data = try allocator.alloc(u8, data_size);
        defer allocator.free(data);
        @memset(data, @as(u8, @intCast(i)));

        try state.emit_log(addr, &topics, data);
    }

    try testing.expectEqual(@as(usize, 10), state.logs.items.len);

    // Clear logs should free all memory
    state.clear_logs();
    try testing.expectEqual(@as(usize, 0), state.logs.items.len);

    // Emit more logs to ensure reusability
    const topics = [_]u256{1, 2};
    const data = &[_]u8{ 0xFF, 0xEE };
    try state.emit_log(addr, &topics, data);
    try testing.expectEqual(@as(usize, 1), state.logs.items.len);
}

test "EvmState clear_selfdestructs" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var state = try EvmState.init(allocator, db_interface);
    defer state.deinit();

    // Mark multiple accounts for selfdestruct
    for (0..100) |i| {
        const addr = testAddress(@as(u160, @intCast(i)));
        const recipient = testAddress(@as(u160, @intCast(i + 1000)));
        try state.mark_for_destruction(addr, recipient);
    }

    try testing.expectEqual(@as(usize, 100), state.selfdestructs.count());

    // Clear selfdestructs
    state.clear_selfdestructs();
    try testing.expectEqual(@as(usize, 0), state.selfdestructs.count());

    // Verify we can add more
    const addr = testAddress(0x9999);
    const recipient = testAddress(0xAAAA);
    try state.mark_for_destruction(addr, recipient);
    try testing.expectEqual(@as(usize, 1), state.selfdestructs.count());
}

test "EvmState clear_transaction_state clears all transaction data" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var state = try EvmState.init(allocator, db_interface);
    defer state.deinit();

    const addr1 = testAddress(0x1111);
    const addr2 = testAddress(0x2222);

    // Add transient storage
    try state.set_transient_storage(addr1, 1, 100);
    try state.set_transient_storage(addr1, 2, 200);
    try state.set_transient_storage(addr2, 1, 300);

    // Emit logs
    const topics = [_]u256{1, 2, 3};
    const data = &[_]u8{ 0xAA, 0xBB, 0xCC };
    try state.emit_log(addr1, &topics, data);
    try state.emit_log(addr2, &topics[0..2], data);

    // Mark selfdestructs
    try state.mark_for_destruction(addr1, addr2);
    try state.mark_for_destruction(addr2, addr1);

    // Verify all data exists
    try testing.expect(state.transient_storage.count() > 0);
    try testing.expect(state.logs.items.len > 0);
    try testing.expect(state.selfdestructs.count() > 0);

    // Clear all transaction state
    state.clear_transaction_state();

    // Verify everything is cleared
    try testing.expectEqual(@as(usize, 0), state.transient_storage.count());
    try testing.expectEqual(@as(usize, 0), state.logs.items.len);
    try testing.expectEqual(@as(usize, 0), state.selfdestructs.count());

    // Verify transient storage returns zeros
    try testing.expectEqual(@as(u256, 0), state.get_transient_storage(addr1, 1));
    try testing.expectEqual(@as(u256, 0), state.get_transient_storage(addr1, 2));
    try testing.expectEqual(@as(u256, 0), state.get_transient_storage(addr2, 1));
}

test "EvmState memory leak prevention in transaction simulation" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var state = try EvmState.init(allocator, db_interface);
    defer state.deinit();

    // Simulate multiple transactions
    for (0..100) |tx_num| {
        const addr = testAddress(@as(u160, @intCast(tx_num)));

        // Each transaction does various operations
        
        // Set some transient storage
        for (0..10) |slot| {
            try state.set_transient_storage(addr, slot, tx_num * 1000 + slot);
        }

        // Emit logs with different sizes
        for (0..5) |log_num| {
            const topics_count = (log_num % 4) + 1;
            var topics_buf: [4]u256 = undefined;
            for (0..topics_count) |i| {
                topics_buf[i] = tx_num * 100 + log_num * 10 + i;
            }

            const data_size = (log_num + 1) * 50;
            const data = try allocator.alloc(u8, data_size);
            defer allocator.free(data);
            @memset(data, @as(u8, @intCast(log_num)));

            try state.emit_log(addr, topics_buf[0..topics_count], data);
        }

        // Mark some selfdestructs
        if (tx_num % 10 == 0) {
            const recipient = testAddress(@as(u160, @intCast(tx_num + 10000)));
            try state.mark_for_destruction(addr, recipient);
        }

        // Clear transaction state at the end of each transaction
        state.clear_transaction_state();
    }

    // After all transactions, only persistent state should remain
    try testing.expectEqual(@as(usize, 0), state.transient_storage.count());
    try testing.expectEqual(@as(usize, 0), state.logs.items.len);
    try testing.expectEqual(@as(usize, 0), state.selfdestructs.count());
}
