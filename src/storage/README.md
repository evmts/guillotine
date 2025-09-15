# Storage Module

## Overview

The Storage module provides comprehensive EVM state management including account data, contract storage, and transaction journaling. It implements a high-performance in-memory database with snapshot support, access list management, and self-destruct tracking with full EIP compliance.

This module handles all persistent state for EVM execution including account balances, nonces, contract code, persistent storage (SSTORE/SLOAD), and transient storage (EIP-1153). The implementation features EIP-7702 account delegation, EIP-2929/2930 access lists, EIP-6780 self-destruct changes, and uses optimized hash maps for efficient lookups without vtable overhead.

## EIP Support

- **EIP-1153**: Transient storage (TLOAD/TSTORE) - cleared at transaction end
- **EIP-2929**: Gas cost increases for state access opcodes (cold vs warm)
- **EIP-2930**: Optional access lists in transactions for gas optimization
- **EIP-6780**: SELFDESTRUCT only destroys contracts created in same transaction (Cancun+)
- **EIP-7702**: Account code delegation for EOAs (Externally Owned Accounts)

## Core Components

### Primary Files

- **`database.zig`** - Main database implementation with account and storage management
- **`database_interface_account.zig`** - Account data structure with EIP-7702 delegation support
- **`memory_database.zig`** - In-memory database implementation optimized for testing
- **`journal.zig`** - Configurable transaction journaling system for state changes and reverts
- **`journal_entry.zig`** - Individual journal entry definitions for different state changes
- **`journal_config.zig`** - Configuration options for journaling behavior and optimization
- **`access_list.zig`** - EIP-2929/2930 access list implementation for gas optimization
- **`access_list_config.zig`** - Access list configuration and validation
- **`created_contracts.zig`** - Tracking of contracts created during transaction execution (EIP-6780)
- **`self_destruct.zig`** - Self-destruct contract management with EIP-6780 compliance
- **`static_wrappers.zig`** - Static interface wrappers for external integration

### Benchmarking and Testing

- **`database_interface_bench.zig`** - Database operation benchmarks
- **`journal_bench.zig`** - Journal system performance benchmarks

## Key Data Structures

### Database Structure
```zig
pub const Database = struct {
    accounts: std.HashMap([20]u8, Account, ArrayHashContext, std.hash_map.default_max_load_percentage),
    storage: std.HashMap(StorageKey, u256, StorageKeyContext, std.hash_map.default_max_load_percentage),
    transient_storage: std.HashMap(StorageKey, u256, StorageKeyContext, std.hash_map.default_max_load_percentage),
    code_storage: std.HashMap([32]u8, []const u8, ArrayHashContext, std.hash_map.default_max_load_percentage),
    snapshots: std.ArrayList(Snapshot),
    next_snapshot_id: u64,
    allocator: std.mem.Allocator,
    
    // Core operations
    pub fn get_account(self: *Database, address: [20]u8) Error!?Account
    pub fn set_account(self: *Database, address: [20]u8, account: Account) Error!void
    pub fn get_storage(self: *Database, address: [20]u8, key: u256) Error!u256
    pub fn set_storage(self: *Database, address: [20]u8, key: u256, value: u256) Error!void
    pub fn get_transient_storage(self: *Database, address: [20]u8, key: u256) Error!u256
    pub fn set_transient_storage(self: *Database, address: [20]u8, key: u256, value: u256) Error!void
};
```

### Account Structure (EIP-7702 Support)
```zig
pub const Account = struct {
    balance: u256,
    code_hash: [32]u8,
    storage_root: [32]u8,
    nonce: u64,
    delegated_address: ?Address = null, // EIP-7702: Code delegation for EOAs
    
    pub fn zero() Account { /* ... */ }
    pub fn is_empty(self: Account) bool { /* ... */ }
    
    // EIP-7702: Account delegation methods
    pub fn has_delegation(self: Account) bool { /* ... */ }
    pub fn get_effective_code_address(self: Account) ?Address { /* ... */ }
    pub fn set_delegation(self: *Account, address: Address) void { /* ... */ }
    pub fn clear_delegation(self: *Account) void { /* ... */ }
};
```

### Storage Key
```zig
const StorageKey = struct {
    address: [20]u8,
    key: u256,
};
```

### Configurable Journal System
```zig
pub fn Journal(comptime config: JournalConfig) type {
    return struct {
        entries: std.ArrayList(Entry),
        next_snapshot_id: SnapshotIdType,
        allocator: std.mem.Allocator,
        
        pub fn create_snapshot(self: *Self) SnapshotIdType
        pub fn revert_to_snapshot(self: *Self, snapshot_id: SnapshotIdType) void
        pub fn record_storage_change(self: *Self, snapshot_id: SnapshotIdType, address: Address, key: WordType, original_value: WordType) !void
        pub fn record_balance_change(self: *Self, snapshot_id: SnapshotIdType, address: Address, original_balance: WordType) !void
        pub fn record_nonce_change(self: *Self, snapshot_id: SnapshotIdType, address: Address, original_nonce: NonceType) !void
        pub fn record_code_change(self: *Self, snapshot_id: SnapshotIdType, address: Address, original_code_hash: [32]u8) !void
        pub fn record_account_created(self: *Self, snapshot_id: SnapshotIdType, address: Address) !void
        pub fn record_account_destroyed(self: *Self, snapshot_id: SnapshotIdType, address: Address, beneficiary: Address, balance: WordType) !void
    };
}

pub const JournalEntry = union(enum) {
    storage_change: StorageChange,
    balance_change: BalanceChange,
    nonce_change: NonceChange,
    code_change: CodeChange,
    account_created: AccountCreated,
    account_destroyed: AccountDestroyed,
};

// Default and configurable journal types
pub const DefaultJournal = Journal(.{});
```

### Access List (EIP-2929/2930)
```zig
pub const AccessList = createAccessList(AccessListConfig{});

pub const Gas_Constants = struct {
    pub const COLD_ACCOUNT_ACCESS_COST: u64 = 2600;
    pub const WARM_ACCOUNT_ACCESS_COST: u64 = 100;
    pub const COLD_SLOAD_COST: u64 = 2100;
    pub const WARM_SLOAD_COST: u64 = 100;
};
```

### Created Contracts Tracker (EIP-6780)
```zig
pub const CreatedContracts = struct {
    created: std.AutoHashMap(Address, void),
    
    pub fn mark_created(self: *CreatedContracts, address: Address) !void
    pub fn was_created_in_tx(self: *const CreatedContracts, address: Address) bool
    pub fn clear(self: *CreatedContracts) void
};
```

### Self-Destruct Tracker (EIP-6780)
```zig
pub const SelfDestruct = struct {
    destructions: std.HashMap(Address, Address, AddressContext, std.hash_map.default_max_load_percentage),
    
    pub fn mark_for_destruction(self: *SelfDestruct, contract_addr: Address, recipient: Address) StateError!void
    pub fn is_marked_for_destruction(self: *SelfDestruct, contract_addr: Address) bool
    pub fn apply_destructions(self: *SelfDestruct, state: anytype, created_contracts: ?*const CreatedContracts, chain_rules: anytype) !void
};
```

## Performance Considerations

### Hash Map Optimization
Database uses specialized hash contexts for optimal performance:
```zig
const ArrayHashContext = struct {
    pub fn hash(self: @This(), key: anytype) u64 {
        _ = self;
        return std.hash_map.hashString(@as([]const u8, &key));
    }
    
    pub fn eql(self: @This(), a: anytype, b: anytype) bool {
        _ = self;
        return std.mem.eql(u8, &a, &b);
    }
};
```

### Storage Key Hashing
Efficient hashing for storage keys combining address and slot:
```zig
const StorageKeyContext = struct {
    pub fn hash(self: @This(), key: StorageKey) u64 {
        _ = self;
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(&key.address);
        hasher.update(std.mem.asBytes(&key.key));
        return hasher.final();
    }
};
```

### Transient Storage Optimization
Pre-allocated capacity to prevent growth-related memory leaks during TSTORE operations:
```zig
pub fn init(allocator: std.mem.Allocator) Database {
    var transient_map = std.HashMap(StorageKey, u256, StorageKeyContext, std.hash_map.default_max_load_percentage).init(allocator);
    transient_map.ensureTotalCapacity(16) catch {}; // Reserve initial capacity
    // ...
}
```

## Usage Examples

### Basic Database Operations
```zig
const Database = @import("database.zig").Database;
const Account = @import("database_interface_account.zig").Account;

var db = Database.init(allocator);
defer db.deinit();

// Create account
const address = [_]u8{1} ++ [_]u8{0} ** 19;
var account = Account{
    .balance = 1_000_000_000_000_000_000, // 1 ETH in wei
    .nonce = 0,
    .code_hash = [_]u8{0} ** 32,
    .storage_root = [_]u8{0} ** 32,
};

// Store account
try db.set_account(address, account);

// Retrieve account
const stored = (try db.get_account(address)).?;
std.debug.assert(stored.balance == 1_000_000_000_000_000_000);
```

### Storage Operations
```zig
// Set contract storage
const contract_address = [_]u8{2} ++ [_]u8{0} ** 19;
const storage_slot: u256 = 0;
const storage_value: u256 = 0xDEADBEEF;

try db.set_storage(contract_address, storage_slot, storage_value);

// Get contract storage  
const retrieved = try db.get_storage(contract_address, storage_slot);
std.debug.assert(retrieved == 0xDEADBEEF);
```

### Transient Storage (EIP-1153)
```zig
// Set transient storage (cleared at end of transaction)
try db.set_transient_storage(contract_address, storage_slot, 12345);

// Get transient storage
const transient_value = try db.get_transient_storage(contract_address, storage_slot);
std.debug.assert(transient_value == 12345);

// Note: Transient storage is automatically cleared between transactions
```

### Snapshot and Revert System
```zig
// Create snapshot before state changes
const snapshot_id = try db.create_snapshot();

// Make some changes
const original_balance = (try db.get_account(address)).?.balance;
var modified_account = (try db.get_account(address)).?;
modified_account.balance = 2_000_000_000_000_000_000; // 2 ETH
try db.set_account(address, modified_account);

// Verify change
std.debug.assert((try db.get_account(address)).?.balance == 2_000_000_000_000_000_000);

// Revert to snapshot
try db.revert_to_snapshot(snapshot_id);

// Balance restored
std.debug.assert((try db.get_account(address)).?.balance == original_balance);
```

### Configurable Journal System Usage
```zig
const Journal = @import("journal.zig").Journal;

// Use default configuration
var journal = Journal(.{}).init(allocator);
defer journal.deinit();

// Or use custom configuration
const CustomJournal = Journal(.{
    .SnapshotIdType = u16,
    .WordType = u128,
    .NonceType = u32,
    .initial_capacity = 64,
});

var custom_journal = CustomJournal.init(allocator);
defer custom_journal.deinit();

// Create snapshot
const snapshot = custom_journal.create_snapshot();

// Track state changes
const zero_addr = Address{ .bytes = [_]u8{0} ** 20 };
try custom_journal.record_balance_change(snapshot, zero_addr, 1000);
try custom_journal.record_storage_change(snapshot, zero_addr, 42, 100);

// Commit changes or revert
custom_journal.revert_to_snapshot(snapshot);
```

### Access List Management (EIP-2929/2930)
```zig
const AccessList = @import("access_list.zig").AccessList;

var access_list = AccessList.init(allocator);
defer access_list.deinit();

const warm_address = Address{ .bytes = [_]u8{3} ++ [_]u8{0} ** 19 };

// First access (cold) - returns EIP-2929 cold gas cost
const cold_cost = try access_list.access_address(warm_address);
std.debug.assert(cold_cost == AccessList.COLD_ACCOUNT_ACCESS_COST); // 2600 gas

// Second access (warm) - returns warm gas cost
const warm_cost = try access_list.access_address(warm_address);
std.debug.assert(warm_cost == AccessList.WARM_ACCOUNT_ACCESS_COST); // 100 gas

// Storage slot access with automatic gas calculation
const slot: u256 = 42;
const cold_sload = try access_list.access_storage_slot(warm_address, slot);
std.debug.assert(cold_sload == AccessList.COLD_SLOAD_COST); // 2100 gas

const warm_sload = try access_list.access_storage_slot(warm_address, slot);
std.debug.assert(warm_sload == AccessList.WARM_SLOAD_COST); // 100 gas

// Pre-warm addresses (transaction initialization)
const tx_origin = Address{ .bytes = [_]u8{1} ++ [_]u8{0} ** 19 };
const coinbase = Address{ .bytes = [_]u8{2} ++ [_]u8{0} ** 19 };
const target = Address{ .bytes = [_]u8{3} ++ [_]u8{0} ** 19 };
try access_list.pre_warm_addresses(&[_]Address{ tx_origin, coinbase, target });

// Clear access lists for new transaction
access_list.clear();
```

### EIP-7702 Account Delegation
```zig
var eoa_account = Account.zero();
const delegate_address = Address{ .bytes = [_]u8{0x42} ++ [_]u8{0} ** 19 };

// Set delegation for EOA
eoa_account.set_delegation(delegate_address);
std.debug.assert(eoa_account.has_delegation());
std.debug.assert(eoa_account.get_effective_code_address().? == delegate_address);

// Get code via delegation
const delegated_code = try db.get_code_by_address(eoa_address); // Resolves through delegation

// Clear delegation
eoa_account.clear_delegation();
std.debug.assert(!eoa_account.has_delegation());
```

### Created Contracts Tracking (EIP-6780)
```zig
const CreatedContracts = @import("created_contracts.zig").CreatedContracts;

var created = CreatedContracts.init(allocator);
defer created.deinit();

const contract_addr = Address{ .bytes = [_]u8{0x12} ++ [_]u8{0} ** 19 };

// Mark contract as created in this transaction
try created.mark_created(contract_addr);
std.debug.assert(created.was_created_in_tx(contract_addr));

// Check count
std.debug.assert(created.count() == 1);

// Clear for next transaction
created.clear();
```

### Self-Destruct Management (EIP-6780)
```zig
const SelfDestruct = @import("self_destruct.zig").SelfDestruct;

var self_destruct = SelfDestruct.init(allocator);
defer self_destruct.deinit();

const contract_addr = Address{ .bytes = [_]u8{0x34} ++ [_]u8{0} ** 19 };
const recipient_addr = Address{ .bytes = [_]u8{0x56} ++ [_]u8{0} ** 19 };

// Mark contract for destruction
try self_destruct.mark_for_destruction(contract_addr, recipient_addr);
std.debug.assert(self_destruct.is_marked_for_destruction(contract_addr));

// Apply destructions at end of transaction
// EIP-6780: Only fully destroys if created in same transaction
try self_destruct.apply_destructions(&db, &created, chain_rules);
```

## State Management

### Account Lifecycle
```zig
// Create new account
pub fn create_account(db: *Database, address: [20]u8) !void {
    const new_account = Account.zero();
    try db.set_account(address, new_account);
}

// Self-destruct account (EIP-6780 compliant)
pub fn self_destruct(db: *Database, address: [20]u8, beneficiary: [20]u8, created_contracts: *const CreatedContracts) !void {
    const account = (try db.get_account(address)) orelse return;
    
    // Transfer balance to beneficiary (always happens)
    if (account.balance > 0) {
        var beneficiary_account = (try db.get_account(beneficiary)) orelse Account.zero();
        beneficiary_account.balance += account.balance;
        try db.set_account(beneficiary, beneficiary_account);
        
        var updated_account = account;
        updated_account.balance = 0;
        try db.set_account(address, updated_account);
    }
    
    // EIP-6780: Only fully destroy if created in same transaction
    if (created_contracts.was_created_in_tx(Address{ .bytes = address })) {
        try db.delete_account(address);
    }
}
```

### Contract Code Management
```zig
// Store contract code and return its hash
pub fn set_contract_code(db: *Database, address: [20]u8, code: []const u8) !void {
    const code_hash = try db.set_code(code);
    
    // Update account code hash
    var account = (try db.get_account(address)) orelse Account.zero();
    account.code_hash = code_hash;
    try db.set_account(address, account);
}

// Retrieve contract code with EIP-7702 delegation support
pub fn get_contract_code(db: *const Database, address: [20]u8) ![]const u8 {
    return db.get_code_by_address(address); // Handles delegation automatically
}
```

## Gas Calculations

### EIP-2929 Gas Costs
```zig
// Account access costs
const COLD_ACCOUNT_ACCESS = 2600; // First access to account
const WARM_ACCOUNT_ACCESS = 100;  // Subsequent accesses

// Storage access costs  
const COLD_SLOAD = 2100; // First access to storage slot
const WARM_SLOAD = 100;  // Subsequent accesses to same slot

// Additional costs for state-changing operations
const SSTORE_SET = 20000;     // Set storage from zero to non-zero
const SSTORE_RESET = 5000;    // Change storage from non-zero to different non-zero
const SSTORE_CLEAR = 15000;   // Clear storage (non-zero to zero)
```

### EIP-1153 Transient Storage
```zig
const TLOAD_GAS = 100;  // Transient storage load
const TSTORE_GAS = 100; // Transient storage store
// Note: No cold/warm distinction for transient storage
```

## Integration Notes

### With Frame Module
Storage integrates with Frame for:
- SLOAD/SSTORE opcode implementation with EIP-2929 gas costs
- TLOAD/TSTORE transient storage operations (EIP-1153)
- Account balance and nonce queries with warm/cold tracking
- Contract code deployment and retrieval with EIP-7702 delegation
- SELFDESTRUCT operations with EIP-6780 compliance

### With EVM Module
Database provides:
- Complete state management for transaction execution
- Snapshot/revert functionality for nested calls and failed transactions
- Gas cost calculation for storage operations (EIP-2929)
- Access list warmness tracking for gas optimization (EIP-2930)
- Created contracts tracking for EIP-6780 compliance
- Journal-based state change tracking for debugging and analysis

### With Instructions Module
Storage handlers support:
- BALANCE opcode with cold/warm gas calculation
- SLOAD/SSTORE opcodes with EIP-2929 gas costs and journal tracking
- TLOAD/TSTORE opcodes for transient storage (EIP-1153)
- SELFDESTRUCT opcode with EIP-6780 behavior
- CODECOPY/CODESIZE opcodes with EIP-7702 delegation support
- Context queries for ADDRESS/CALLER opcodes

## Error Handling

Storage operations use comprehensive error types:
```zig
pub const Error = error{
    AccountNotFound,      // Access to non-existent account
    StorageNotFound,      // Access to uninitialized storage slot
    CodeNotFound,         // Reference to missing contract code
    OutOfMemory,          // Allocation failure during operation
    DatabaseCorrupted,    // Inconsistent internal state
    NetworkError,         // Network error when accessing remote database
    PermissionDenied,     // Permission denied accessing database
    InvalidSnapshot,      // Invalid snapshot identifier
    SnapshotNotFound,     // Snapshot not found
    NoBatchInProgress,    // Batch operation not in progress
    WriteProtection,      // Write protection for static calls
    InvalidAddress,       // Invalid address format (EIP-7702)
};
```

All operations maintain ACID properties with proper cleanup through defer patterns and comprehensive error propagation.

## Testing and Benchmarks

The storage module includes comprehensive tests covering:
- Basic database operations and edge cases
- EIP compliance (1153, 2929, 2930, 6780, 7702)
- Performance stress tests with large datasets
- Memory management and cleanup
- Error handling and recovery
- Integration scenarios

Benchmarks are provided for:
- Database operation performance
- Journal system overhead
- Access list lookup speed
- Hash map collision resistance