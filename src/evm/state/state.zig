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

    var transient_storage = std.AutoHashMap(StorageKey, u256).init(allocator);
    errdefer transient_storage.deinit();

    var logs = std.ArrayList(EvmLog).init(allocator);
    errdefer logs.deinit();

    var selfdestructs = std.AutoHashMap(Address, Address).init(allocator);
    errdefer selfdestructs.deinit();

    Log.debug("EvmState.init: EVM state initialization complete", .{});
    return EvmState{
        .allocator = allocator,
        .database = database,
        .transient_storage = transient_storage,
        .logs = logs,
        .selfdestructs = selfdestructs,
    };
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
    // Use database interface to get storage value
    const value = self.database.get_storage(address, slot) catch |err| {
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
        Log.debug("EvmState.get_balance: Database error {}, returning 0", .{err});
        return 0;
    };

    if (account) |acc| {
        Log.debug("EvmState.get_balance: addr={x}, balance={}", .{ primitives.Address.to_u256(address), acc.balance });
        return acc.balance;
    } else {
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
    // Get account to find code hash
    const account = self.database.get_account(address) catch |err| {
        Log.debug("EvmState.get_code: Database error {}, returning empty", .{err});
        return &[_]u8{};
    };

    if (account) |acc| {
        // Check if account has code (non-zero code hash)
        const zero_hash = [_]u8{0} ** 32;
        if (std.mem.eql(u8, &acc.code_hash, &zero_hash)) {
            Log.debug("EvmState.get_code: addr={x}, code_len=0 (EOA)", .{primitives.Address.to_u256(address)});
            return &[_]u8{};
        }

        // Get code by hash
        const code = self.database.get_code(acc.code_hash) catch |err| {
            Log.debug("EvmState.get_code: Code fetch error {}, returning empty", .{err});
            return &[_]u8{};
        };

        Log.debug("EvmState.get_code: addr={x}, code_len={}", .{ primitives.Address.to_u256(address), code.len });
        return code;
    } else {
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
        Log.debug("EvmState.get_nonce: Database error {}, returning 0", .{err});
        return 0;
    };

    if (account) |acc| {
        Log.debug("EvmState.get_nonce: addr={x}, nonce={}", .{ primitives.Address.to_u256(address), acc.nonce });
        return acc.nonce;
    } else {
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
        Log.debug("EvmState.get_transient_storage: addr={x}, slot={}, value={}", .{ primitives.Address.to_u256(address), slot, value });
        return value;
    } else {
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
        unreachable;
    }

    // Free the memory for the log we're removing
    const log_to_remove = self.logs.items[log_index];
    self.allocator.free(log_to_remove.topics);
    self.allocator.free(log_to_remove.data);

    // Remove the log by truncating the array
    // This works because logs are always removed in reverse order during revert
    if (log_index != self.logs.items.len - 1) {
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
