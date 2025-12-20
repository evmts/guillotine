# State Management

This document covers storage, journals, access lists, and state management across both EVM implementations.

## Storage Architecture

### Three Storage Types

The EVM maintains three separate storage types:

```zig
// Both implementations track:

// 1. Persistent Storage (current transaction state)
// Modified by SSTORE, read by SLOAD
// Persists across transactions
storage: Map(StorageKey, u256)

// 2. Original Storage (snapshot at transaction start)
// Used for SSTORE gas refund calculations (EIP-2200)
// Never modified during transaction
original_storage: Map(StorageKey, u256)

// 3. Transient Storage (EIP-1153, Cancun+)
// Cleared at transaction boundaries
// NOT cleared on reverts within transaction
// Always warm (100 gas), never cold
transient: Map(StorageKey, u256)
```

### Mini Storage Implementation

```zig
// mini/src/storage.zig:19-55
pub const Storage = struct {
    storage: std.AutoHashMap(StorageSlotKey, u256),
    original_storage: std.AutoHashMap(StorageSlotKey, u256),
    transient: std.AutoHashMap(StorageSlotKey, u256),
    host: ?host.HostInterface,
    storage_injector: ?*StorageInjector,
    allocator: std.mem.Allocator,

    pub fn get(self: *Storage, address: Address, slot: u256) !u256 {
        const key = StorageSlotKey{ .address = address.bytes, .slot = slot };

        // Check injector cache first (for async fetching)
        if (self.storage_injector) |injector| {
            if (injector.storage_cache.get(key)) |value| {
                return value;
            }
            // Request async fetch
            self.async_data_request = .{ .storage = .{ .address = address, .slot = slot } };
            return error.NeedAsyncData;
        }

        // Try local storage
        if (self.storage.get(key)) |value| {
            return value;
        }

        // Try host interface
        if (self.host) |h| {
            return h.getStorage(address, slot);
        }

        return 0;  // Empty slot
    }

    pub fn set(self: *Storage, address: Address, slot: u256, value: u256) !void {
        const key = StorageSlotKey{ .address = address.bytes, .slot = slot };
        try self.storage.put(key, value);

        // Notify injector if present
        if (self.storage_injector) |injector| {
            injector.markStorageDirty(address, slot);
        }
    }
};
```

### Performance Storage Implementation

The Performance EVM uses a database interface with journal tracking:

```zig
// src/storage/database.zig
pub const Database = struct {
    accounts: HashMap(Address, Account),
    storage: HashMap(StorageKey, u256),
    code: HashMap(CodeHash, []const u8),
    // ...

    pub fn get_storage(self: *Database, address: Address, slot: u256) u256 {
        const key = StorageKey{ .address = address, .slot = slot };
        return self.storage.get(key) orelse 0;
    }

    pub fn set_storage(self: *Database, address: Address, slot: u256, value: u256) !void {
        const key = StorageKey{ .address = address, .slot = slot };
        try self.storage.put(key, value);
    }
};
```

## Journal System (Performance Only)

The journal tracks state changes for transaction rollback:

```zig
// src/storage/journal.zig:14-80
pub fn Journal(comptime config: JournalConfig) type {
    return struct {
        entries: std.ArrayList(Entry),
        next_snapshot_id: SnapshotIdType,
        allocator: std.mem.Allocator,

        /// Create a snapshot for potential rollback
        pub fn create_snapshot(self: *Self) SnapshotIdType {
            const id = self.next_snapshot_id;
            self.next_snapshot_id = @min(self.next_snapshot_id +| 1, std.math.maxInt(SnapshotIdType));
            return id;
        }

        /// Rollback all changes since snapshot
        pub fn revert_to_snapshot(self: *Self, snapshot_id: SnapshotIdType) void {
            // Remove entries with snapshot_id >= target
            var write_idx: usize = 0;
            for (self.entries.items) |entry| {
                if (entry.snapshot_id < snapshot_id) {
                    self.entries.items[write_idx] = entry;
                    write_idx += 1;
                }
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
            try self.entries.append(self.allocator,
                Entry.storage_change(snapshot_id, address, key, original_value));
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
    };
}
```

### Journal Entry Types

```zig
// src/storage/journal_entry.zig
pub fn JournalEntry(comptime config: JournalConfig) type {
    return struct {
        snapshot_id: SnapshotIdType,
        data: union(enum) {
            storage_change: struct {
                address: Address,
                key: WordType,
                original_value: WordType,
            },
            balance_change: struct {
                address: Address,
                original_balance: WordType,
            },
            nonce_change: struct {
                address: Address,
                original_nonce: NonceType,
            },
            code_change: struct {
                address: Address,
                original_code_hash: [32]u8,
            },
            account_created: Address,
            self_destruct: Address,
        },
    };
}
```

## Access List (EIP-2929)

Tracks warm/cold access for gas calculation:

### Gas Costs

```zig
// Cold = first access, warm = subsequent
pub const COLD_ACCOUNT_ACCESS = 2600;
pub const WARM_ACCOUNT_ACCESS = 100;
pub const COLD_SLOAD = 2100;
pub const WARM_SLOAD = 100;
```

### Mini Implementation

```zig
// mini/src/evm.zig
warm_addresses: std.AutoHashMap(Address, void),
warm_storage_slots: std.AutoHashMap(StorageSlotKey, void),

pub fn accessAddress(self: *Self, address: Address) u64 {
    if (self.warm_addresses.contains(address)) {
        return WARM_ACCOUNT_ACCESS;  // 100
    }
    try self.warm_addresses.put(address, {});
    return COLD_ACCOUNT_ACCESS;  // 2600
}

pub fn accessStorageSlot(self: *Self, address: Address, slot: u256) u64 {
    const key = StorageSlotKey{ .address = address.bytes, .slot = slot };
    if (self.warm_storage_slots.contains(key)) {
        return WARM_SLOAD;  // 100
    }
    try self.warm_storage_slots.put(key, {});
    return COLD_SLOAD;  // 2100
}
```

### Performance Implementation

```zig
// src/storage/access_list.zig
pub fn AccessList(comptime config: AccessListConfig) type {
    return struct {
        addresses: HashMap(Address, void),
        storage_keys: HashMap(StorageKey, void),

        pub fn access_address(self: *Self, address: Address) u64 {
            if (self.addresses.contains(address)) {
                return config.warm_account_access;
            }
            try self.addresses.put(address, {});
            return config.cold_account_access;
        }

        pub fn access_storage(self: *Self, address: Address, slot: u256) u64 {
            const key = StorageKey{ .address = address, .slot = slot };
            if (self.storage_keys.contains(key)) {
                return config.warm_sload;
            }
            try self.storage_keys.put(key, {});
            return config.cold_sload;
        }

        /// Pre-warm from transaction access list (EIP-2930)
        pub fn warm_from_tx_access_list(self: *Self, list: []const AccessListItem) !void {
            for (list) |item| {
                try self.addresses.put(item.address, {});
                for (item.storage_keys) |slot| {
                    try self.storage_keys.put(.{ .address = item.address, .slot = slot }, {});
                }
            }
        }
    };
}
```

## Transient Storage (EIP-1153)

### Key Properties

```
1. Lifetime: Transaction-scoped (cleared at tx boundary)
2. Reverts: NOT cleared on revert (unlike regular storage)
3. Gas: Always warm (100 gas), never cold
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
    try self.transient.put(key, value);
}

// Cleared at transaction start
pub fn clearTransient(self: *Storage) void {
    self.transient.clearRetainingCapacity();
}
```

### Handler

```zig
// mini/src/instructions/handlers_storage.zig
pub fn tload(frame: *FrameType) EvmError!void {
    // Always warm access (100 gas)
    try frame.consumeGas(GasConstants.WarmStorageReadCost);

    const slot = try frame.popStack();
    const evm = frame.getEvm();
    const value = evm.storage.getTransient(frame.address, slot);

    try frame.pushStack(value);
    frame.pc += 1;
}

pub fn tstore(frame: *FrameType) EvmError!void {
    // Check static context
    if (frame.is_static) {
        return error.WriteInStaticContext;
    }

    // Always warm access (100 gas)
    try frame.consumeGas(GasConstants.WarmStorageReadCost);

    const slot = try frame.popStack();
    const value = try frame.popStack();

    const evm = frame.getEvm();
    try evm.storage.setTransient(frame.address, slot, value);

    frame.pc += 1;
}
```

## SSTORE Gas Calculation (EIP-2200)

Complex gas calculation based on original, current, and new values:

```zig
// mini/src/instructions/handlers_storage.zig
pub fn sstore(frame: *FrameType) EvmError!void {
    const evm = frame.getEvm();

    // Pop key and value
    const slot = try frame.popStack();
    const new_value = try frame.popStack();

    // Get current and original values
    const current_value = try evm.storage.get(frame.address, slot);
    const original_value = evm.storage.getOriginal(frame.address, slot) orelse current_value;

    // Calculate gas (EIP-2200)
    var gas_cost: u64 = 0;

    // Cold access cost
    if (!evm.warm_storage_slots.contains(.{ .address = frame.address.bytes, .slot = slot })) {
        gas_cost += GasConstants.ColdSloadCost;  // 2100
        try evm.warm_storage_slots.put(.{ .address = frame.address.bytes, .slot = slot }, {});
    }

    // Value change costs
    if (original_value == current_value and current_value != new_value) {
        if (original_value == 0) {
            gas_cost += GasConstants.SstoreSetGas;  // 20000
        } else {
            gas_cost += GasConstants.SstoreResetGas - GasConstants.ColdSloadCost;  // 2900
        }
    } else {
        gas_cost += GasConstants.WarmStorageReadCost;  // 100
    }

    // Refund calculation
    if (new_value != current_value) {
        if (original_value != 0 and current_value != 0 and new_value == 0) {
            // Clearing slot: refund
            evm.gas_refund += GasConstants.SstoreClearRefund;  // 4800
        }
        if (original_value != 0 and current_value == 0) {
            // Re-setting cleared slot: reduce refund
            evm.gas_refund -= GasConstants.SstoreClearRefund;
        }
        if (original_value == new_value) {
            // Resetting to original: refund
            if (original_value == 0) {
                evm.gas_refund += GasConstants.SstoreSetGas - GasConstants.WarmStorageReadCost;
            } else {
                evm.gas_refund += GasConstants.SstoreResetGas - GasConstants.WarmStorageReadCost;
            }
        }
    }

    try frame.consumeGas(gas_cost);
    try evm.storage.set(frame.address, slot, new_value);
    frame.pc += 1;
}
```

## Snapshot/Restore for Nested Calls

```zig
// Before nested call
const snapshot_id = evm.journal.create_snapshot();
const storage_snapshot = evm.storage.snapshot();
const access_list_snapshot = evm.access_list.snapshot();
const gas_refund_snapshot = evm.gas_refund;

// Execute nested call
const result = try evm.inner_call(params);

if (!result.success) {
    // Revert state on failure
    evm.journal.revert_to_snapshot(snapshot_id);
    evm.storage.restore(storage_snapshot);
    evm.access_list.restore(access_list_snapshot);
    evm.gas_refund = gas_refund_snapshot;
}
```

## State Key Encoding

```zig
// StorageSlotKey used as map key
pub const StorageSlotKey = struct {
    address: [20]u8,
    slot: u256,

    pub fn hash(self: StorageSlotKey) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(&self.address);
        h.update(std.mem.asBytes(&self.slot));
        return h.final();
    }

    pub fn eql(a: StorageSlotKey, b: StorageSlotKey) bool {
        return std.mem.eql(u8, &a.address, &b.address) and a.slot == b.slot;
    }
};
```

## Memory Management

### Mini: Standard Allocator

```zig
allocator: std.mem.Allocator,

// Direct HashMap allocation
storage: std.AutoHashMap(StorageSlotKey, u256).init(allocator),
```

### Performance: Arena Allocator

```zig
// Transaction-scoped arena - freed all at once
call_arena: GrowingArenaAllocator,

// All state allocated from arena
// No individual frees during transaction
// Entire arena freed when transaction completes
```
