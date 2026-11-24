# State Management

This document covers storage, journals, access lists, and state management across both EVM implementations.

## Storage Architecture

### Three Storage Types

The EVM maintains three separate storage types:

```zig
// Both implementations track (field names from mini/src/storage.zig):

// 1. Persistent Storage (current transaction state)
// Modified by SSTORE, read by SLOAD
// Persists across transactions
storage: Map(StorageKey, u256)

// 2. Original Storage (value before the transaction's first write)
// Used for SSTORE gas refund calculations (EIP-2200)
// Never modified during transaction
original_storage: Map(StorageKey, u256)

// 3. Transient Storage (EIP-1153, Cancun+)
// Cleared at transaction boundaries
// Writes roll back when their call frame reverts
// Flat 100 gas (TLoadGas/TStoreGas), no warm/cold distinction
transient: Map(StorageKey, u256)
```

The Performance EVM splits the same data across modules: persistent and transient storage live in `Database` (`storage`, `transient_storage`), and original values live in `Journal.original_storage`.

### Mini Storage Implementation

```zig
// mini/src/storage.zig (condensed)
pub const Storage = struct {
    storage: std.AutoHashMap(StorageSlotKey, u256),
    original_storage: std.AutoHashMap(StorageSlotKey, u256),
    transient: std.AutoHashMap(StorageSlotKey, u256),
    host: ?host.HostInterface,
    storage_injector: ?*storage_injector.StorageInjector,
    async_data_request: AsyncDataRequest,
    allocator: std.mem.Allocator,

    pub fn get(self: *Storage, address: primitives.Address, slot: u256) !u256 {
        const key = StorageSlotKey{ .address = address.bytes, .slot = slot };

        // With an injector, serve from its cache or yield for an async fetch
        if (self.storage_injector) |injector| {
            if (injector.storage_cache.get(key)) |value| {
                return value;
            }
            self.async_data_request = .{ .storage = .{ .address = address, .slot = slot } };
            return errors.CallError.NeedAsyncData;
        }

        // No injector: the host wins, else the local map
        if (self.host) |h| {
            return h.getStorage(address, slot);
        }
        return self.storage.get(key) orelse 0;  // Empty slot
    }

    pub fn set(self: *Storage, address: primitives.Address, slot: u256, value: u256) !void {
        const key = StorageSlotKey{ .address = address.bytes, .slot = slot };

        // Record the original value on the first write in this transaction
        if (!self.original_storage.contains(key)) {
            const current = if (self.host) |h| h.getStorage(address, slot) else self.storage.get(key) orelse 0;
            try self.original_storage.put(key, current);
        }

        if (self.storage_injector) |injector| {
            try injector.markStorageDirty(address, slot);
        }

        if (self.host) |h| {
            h.setStorage(address, slot, value);
            return;
        }

        // Writing 0 deletes the slot
        if (value == 0) {
            _ = self.storage.remove(key);
        } else {
            try self.storage.put(key, value);
        }
    }

    /// Value before this transaction's first write (current value if unwritten)
    pub fn getOriginal(self: *Storage, address: primitives.Address, slot: u256) u256 { ... }
};
```

### Performance Storage Implementation

The Performance EVM uses a database interface with journal tracking:

```zig
// src/storage/database.zig (condensed)
pub const Database = struct {
    accounts: std.HashMap([20]u8, Account, ArrayHashContext, ...),
    storage: std.HashMap(StorageKey, u256, StorageKeyContext, ...),
    transient_storage: StorageMap,
    code_storage: std.HashMap([32]u8, []const u8, ArrayHashContext, ...),
    snapshots: std.ArrayList(Snapshot),
    undo_log: std.ArrayList(UndoEntry) = .{},
    // ... overlay_* maps for ephemeral views, tx_cache for buffered writes

    const StorageKey = struct { address: [20]u8, key: u256 };

    pub fn get_storage(self: *Database, address: [20]u8, key: u256) Error!u256 {
        const storage_key = StorageKey{ .address = address, .key = key };
        if (self.overlay_active) {
            if (self.overlay_storage.get(storage_key)) |v| return v;
        }
        if (self.tx_cache) |cache| {
            if (cache.storage.get(storage_key)) |v| return v;
        }
        return self.storage.get(storage_key) orelse 0;
    }

    pub fn set_storage(self: *Database, address: [20]u8, key: u256, value: u256) Error!void {
        const storage_key = StorageKey{ .address = address, .key = key };
        if (self.overlay_active) {
            return self.write_entry(&self.overlay_storage, storage_key, value, .ephemeral_storage);
        }
        if (self.tx_cache) |cache| {
            return self.write_entry(&cache.storage, storage_key, value, .cached_storage);
        }
        try self.write_entry(&self.storage, storage_key, value, .storage);
    }
};
```

While a snapshot is open, `write_entry` appends the previous value to `undo_log`, so `Database.revert_to_snapshot()` can roll back writes made since `Database.create_snapshot()`. `commit_snapshot()` keeps them.

## Journal System (Performance Only)

The journal tracks state changes for transaction rollback:

```zig
// src/storage/journal.zig (condensed)
pub fn Journal(comptime config: JournalConfig) type {
    return struct {
        entries: std.ArrayList(Entry),
        next_snapshot_id: SnapshotIdType,
        allocator: std.mem.Allocator,
        /// O(1) index of the oldest storage_change per (address, slot)
        original_storage: OriginalStorageMap,
        storage_ids_unordered: bool,

        pub const Error = error{SnapshotIdExhausted};

        /// Create a snapshot for potential rollback
        pub fn create_snapshot(self: *Self) Error!SnapshotIdType {
            if (self.next_snapshot_id == std.math.maxInt(SnapshotIdType)) {
                return error.SnapshotIdExhausted;
            }
            const id = self.next_snapshot_id;
            self.next_snapshot_id += 1;
            return id;
        }

        /// Remove all entries with snapshot_id >= the target and drop
        /// original_storage index entries that pointed at them
        pub fn revert_to_snapshot(self: *Self, snapshot_id: SnapshotIdType) void {
            var write_idx: usize = 0;
            for (self.entries.items) |entry| {
                if (entry.snapshot_id < snapshot_id) {
                    self.entries.items[write_idx] = entry;
                    write_idx += 1;
                    continue;
                }
                // storage_change: remove its original_storage index entry
                // if that entry came from a reverted snapshot
            }
            self.entries.shrinkRetainingCapacity(write_idx);
        }

        /// Record storage modification
        pub fn record_storage_change(
            self: *Self,
            snapshot_id: SnapshotIdType,
            address: Address,
            key: WordType,
            original_value: WordType,
        ) !void {
            // Appends the entry and indexes the first value seen for the slot
            // in original_storage (read by get_original_storage)
        }

        /// Record balance modification
        pub fn record_balance_change(
            self: *Self,
            snapshot_id: SnapshotIdType,
            address: Address,
            original_balance: WordType,
        ) !void {
            try self.entries.append(self.allocator,
                Entry.balance_change(snapshot_id, address, original_balance));
        }

        // Also: record_nonce_change, record_code_change, record_account_created,
        // record_account_destroyed, get_original_storage, get_original_balance, clear
    };
}
```

### Journal Entry Types

```zig
// src/storage/journal_entry.zig
pub fn JournalEntry(comptime config: JournalConfig) type {
    return struct {
        snapshot_id: SnapshotIdType,
        data: Data,

        pub const Data = union(enum) {
            storage_change: StorageChange,       // { address, key, original_value }
            balance_change: BalanceChange,       // { address, original_balance }
            nonce_change: NonceChange,           // { address, original_nonce }
            code_change: CodeChange,             // { address, original_code_hash: [32]u8 }
            account_created: AccountCreated,     // { address }
            account_destroyed: AccountDestroyed, // { address, beneficiary, balance }
        };
    };
}
```

## Access List (EIP-2929)

Tracks warm/cold access for gas calculation:

### Gas Costs

```zig
// Cold = first access, warm = subsequent
// lib/voltaire/src/primitives/gas_constants.zig (used by Mini)
pub const ColdAccountAccessCost: u64 = 2600;
pub const ColdSloadCost: u64 = 2100;
pub const WarmStorageReadCost: u64 = 100;  // warm account and warm slot

// src/storage/access_list_config.zig (AccessListConfig defaults, used by Performance)
cold_account_access_cost: u64 = 2600,
warm_account_access_cost: u64 = 100,
cold_sload_cost: u64 = 2100,
warm_sload_cost: u64 = 100,
```

### Mini Implementation

```zig
// mini/src/access_list_manager.zig
pub const AccessListManager = struct {
    allocator: Allocator,
    warm_addresses: std.AutoHashMap(Address, void),
    warm_storage_slots: std.ArrayHashMap(StorageKey, void, StorageKeyContext, false),

    pub fn accessAddress(self: *AccessListManager, addr: Address) !u64 {
        const entry = try self.warm_addresses.getOrPut(addr);
        return if (entry.found_existing)
            gas_constants.WarmStorageReadCost    // 100
        else
            gas_constants.ColdAccountAccessCost; // 2600
    }

    pub fn accessStorageSlot(self: *AccessListManager, addr: Address, slot: u256) !u64 {
        const key = StorageKey{ .address = addr.bytes, .slot = slot };
        const entry = try self.warm_storage_slots.getOrPut(key);
        return if (entry.found_existing)
            gas_constants.WarmStorageReadCost  // 100
        else
            gas_constants.ColdSloadCost;       // 2100
    }

    /// Pre-warm from a transaction access list (EIP-2930)
    pub fn preWarmFromAccessList(self: *AccessListManager, access_list: AccessList) !void { ... }

    // Also: preWarmAddresses, preWarmStorageSlots, snapshot, restore, clear
};
```

`Evm.accessAddress` and `Evm.accessStorageSlot` in `mini/src/evm.zig` wrap these. Before Berlin they skip the access list: `accessAddress` returns 0, and `accessStorageSlot` returns the flat SLOAD cost (800 from Istanbul, 200 before).

### Performance Implementation

```zig
// src/storage/access_list.zig
pub fn createAccessList(comptime config: AccessListConfig) type {
    return struct {
        addresses: std.array_hash_map.ArrayHashMap(Address, void, AddressContext, false),
        storage_slots: std.array_hash_map.ArrayHashMap(StorageKey, void, StorageKeyContext, false),

        pub const COLD_ACCOUNT_ACCESS_COST: u64 = config.cold_account_access_cost;
        pub const WARM_ACCOUNT_ACCESS_COST: u64 = config.warm_account_access_cost;
        pub const COLD_SLOAD_COST: u64 = config.cold_sload_cost;
        pub const WARM_SLOAD_COST: u64 = config.warm_sload_cost;

        pub fn access_address(self: *Self, address: Address) !u64 {
            const result = try self.addresses.getOrPut(address);
            if (result.found_existing) return WARM_ACCOUNT_ACCESS_COST;
            return COLD_ACCOUNT_ACCESS_COST;
        }

        pub fn access_storage_slot(self: *Self, address: Address, slot: config.SlotType) !u64 {
            const key = StorageKey{ .address = address, .slot = slot };
            const result = try self.storage_slots.getOrPut(key);
            if (result.found_existing) return WARM_SLOAD_COST;
            return COLD_SLOAD_COST;
        }

        /// Warm addresses without charging: tx.origin, the call target,
        /// coinbase (EIP-3651), and the fork's precompiles
        pub fn pre_warm_addresses(self: *Self, addresses: []const Address) !void { ... }

        /// Both maps are insertion-ordered, so a pair of sizes is a checkpoint.
        /// revertTo makes everything warmed after the checkpoint cold again.
        pub fn checkpoint(self: *const Self) Checkpoint { ... }
        pub fn revertTo(self: *Self, cp: Checkpoint) void { ... }

        // Also: is_address_warm, is_storage_slot_warm, clear, clone
    };
}

pub const AccessList = createAccessList(AccessListConfig{});
```

## Transient Storage (EIP-1153)

### Key Properties

```
1. Lifetime: Transaction-scoped (cleared at tx boundary)
2. Reverts: writes roll back when their call frame reverts, like regular storage
3. Gas: flat 100 gas, no warm/cold distinction
4. Opcodes: TLOAD (0x5C), TSTORE (0x5D)
5. Hardfork: Cancun+
```

### Implementation

```zig
// mini/src/storage.zig
pub fn getTransient(self: *Storage, address: Address, slot: u256) u256 {
    const key = StorageSlotKey{ .address = address.bytes, .slot = slot };
    return self.transient.get(key) orelse 0;
}

pub fn setTransient(self: *Storage, address: Address, slot: u256, value: u256) !void {
    const key = StorageSlotKey{ .address = address.bytes, .slot = slot };
    if (value == 0) {
        _ = self.transient.remove(key);  // Writing 0 deletes the slot
    } else {
        try self.transient.put(key, value);
    }
}

// Called by Evm at the end of each transaction
pub fn clearTransient(self: *Storage) void {
    self.transient.clearRetainingCapacity();
}
```

### Handler

```zig
// mini/src/instructions/handlers_storage.zig
pub fn tload(frame: *FrameType) FrameType.EvmError!void {
    const evm = frame.getEvm();

    // EIP-1153: TLOAD was introduced in Cancun hardfork
    if (evm.hardfork.isBefore(.CANCUN)) return error.InvalidOpcode;

    try frame.consumeGas(GasConstants.TLoadGas);  // 100
    const key = try frame.popStack();
    const value = evm.storage.getTransient(frame.address, key);
    try frame.pushStack(value);
    frame.pc += 1;
}

pub fn tstore(frame: *FrameType) FrameType.EvmError!void {
    const evm = frame.getEvm();

    if (evm.hardfork.isBefore(.CANCUN)) return error.InvalidOpcode;

    // EIP-1153: TSTORE cannot modify state in static call context
    if (frame.is_static) return error.StaticCallViolation;

    try frame.consumeGas(GasConstants.TStoreGas);  // 100
    const key = try frame.popStack();
    const value = try frame.popStack();
    try evm.storage.setTransient(frame.address, key, value);
    frame.pc += 1;
}
```

## SSTORE Gas Calculation (EIP-2200)

Gas and refunds depend on the original, current, and new values. The Mini handler, condensed to its Istanbul+ gas path and London+ refund path:

```zig
// mini/src/instructions/handlers_storage.zig
pub fn sstore(frame: *FrameType) FrameType.EvmError!void {
    const evm = frame.getEvm();

    // EIP-214: SSTORE cannot modify state in static call context
    if (frame.is_static) return error.StaticCallViolation;

    // EIP-2200 sentry: need more than 2300 gas left
    if (evm.hardfork.isAtLeast(.ISTANBUL)) {
        if (frame.gas_remaining <= GasConstants.SstoreSentryGas) return error.OutOfGas;
    }

    const key = try frame.popStack();
    const value = try frame.popStack();
    const current_value = try evm.storage.get(frame.address, key);
    const original_value = evm.storage.getOriginal(frame.address, key);

    // EIP-2929: warm the slot; cold adds ColdSloadCost (2100)
    const access_cost = try evm.accessStorageSlot(frame.address, key);
    const is_cold = access_cost == GasConstants.ColdSloadCost;

    // lib/voltaire/src/primitives/gas_constants.zig
    const gas_cost = GasConstants.sstoreGasCostWithHardfork(
        current_value, original_value, value, is_cold,
        evm.hardfork.isAtLeast(.BERLIN), evm.hardfork.isAtLeast(.ISTANBUL),
    );
    try frame.consumeGas(gas_cost);

    // EIP-3529 (London+) refunds: three independent checks, as in execution-specs
    if (current_value != value) {
        if (original_value != 0 and current_value != 0 and value == 0) {
            evm.add_refund(GasConstants.SstoreRefundGas);  // 4800: clearing the slot
        }
        if (original_value != 0 and current_value == 0) {
            // Reversing an earlier clear in this transaction
            if (evm.gas_refund >= GasConstants.SstoreRefundGas) evm.gas_refund -= GasConstants.SstoreRefundGas;
        }
        if (original_value == value) {
            if (original_value == 0) {
                evm.add_refund(GasConstants.SstoreSetGas - GasConstants.WarmStorageReadCost);  // 19900
            } else {
                evm.add_refund(GasConstants.SstoreResetGas - GasConstants.ColdSloadCost - GasConstants.WarmStorageReadCost);  // 2800
            }
        }
    }

    try evm.storage.set(frame.address, key, value);
    frame.pc += 1;
}
```

Istanbul through Berlin use the same three checks with a 15000 clear refund and 19900/4900 restore refunds. Earlier forks charge 20000 (zero to non-zero) or 5000 and refund 15000 for clearing a slot.

## Snapshot/Restore for Nested Calls

The Performance EVM takes three snapshots when a call frame starts (`executeCall`, `executeCallcode`, `executeDelegatecall`, `executeStaticcall`, `executeCreate`, and `executeCreate2` in `src/evm.zig`):

```zig
// src/evm.zig
const snapshot_id = try self.journal.create_snapshot();
const db_snapshot_id = try self.database.create_snapshot();
const checkpoint = self.frameCheckpoint();  // logs, gas_refund, access_list,
                                            // self_destruct, created_contracts

// ... execute the callee ...

if (failed) {
    // Undo state via journal + database, then logs, refunds, EIP-2929 warm sets,
    // SELFDESTRUCT marks, and EIP-6780 created contracts via the checkpoint
    try self.revertFrame(snapshot_id, db_snapshot_id, checkpoint);
} else {
    try self.database.commit_snapshot(db_snapshot_id);
}
```

The Mini EVM (`mini/src/evm.zig`) copies state instead: before a nested call it saves `gas_refund`, the transient storage map, `selfdestructed_accounts`, and `access_list_manager.snapshot()`. On failure it restores each one and removes storage slots the call added.

## State Key Encoding

```zig
// lib/voltaire/src/primitives/state.zig
// Mini aliases it: pub const StorageSlotKey = primitives.State.StorageKey;
pub const StorageKey = struct {
    address: [20]u8,
    slot: u256,

    /// Feeds any hasher with an update([]const u8) method
    pub fn hash(self: StorageKey, hasher: anytype) void {
        hasher.update(&self.address);
        var slot_bytes: [32]u8 = undefined;
        std.mem.writeInt(u256, &slot_bytes, self.slot, .big);  // big-endian for consistency
        hasher.update(&slot_bytes);
    }

    pub fn eql(a: StorageKey, b: StorageKey) bool { ... }
};
```

The Performance modules define their own keys with fold-based hash contexts: `Database.StorageKey` and `Journal.StorageKey` are `{ address: [20]u8, key }`, and the access list key is `{ address: Address, slot }`.

## Memory Management

### Mini: Arena for State Maps

```zig
// mini/src/evm.zig, Evm.init
var arena = std.heap.ArenaAllocator.init(allocator);
const arena_alloc = arena.allocator();

// storage, accounts, access_list_manager, created/selfdestructed/touched sets
.storage = Storage.init(arena_alloc, h, null),
```

### Performance: General Allocator Plus Call Arena

```zig
// src/evm.zig, Evm.init
.journal = try Journal.init(allocator),
.access_list = AccessList.init(allocator),  // database is passed in by the caller

// Per-call temporaries (log topics and data, call results)
call_arena: GrowingArenaAllocator,
```

The journal, access list, and other transaction-scoped sets use the allocator passed to `Evm.init` and are cleared with `clear()` after each top-level call. `call_arena` holds per-call temporaries and is reset with `resetRetainCapacity()` after each top-level call, keeping its grown capacity.
