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

### MinimalEvm Storage Implementation

MinimalEvm keeps all storage in hash maps on the `MinimalEvm` struct and
delegates to a host interface when one is attached.

```zig
// src/tracer/minimal_evm.zig
storage: std.AutoHashMap(StorageSlotKey, u256),
transient_storage: std.AutoHashMap(StorageSlotKey, u256),
original_storage: std.AutoHashMap(StorageSlotKey, u256),

pub fn get_storage(self: *Self, address: Address, slot: u256) u256 {
    if (self.host) |host| {
        return host.getStorage(address, slot);
    }
    const key = StorageSlotKey{ .address = address, .slot = slot };
    return self.storage.get(key) orelse 0;
}

pub fn set_storage(self: *Self, address: Address, slot: u256, value: u256) Error!void {
    if (self.host) |host| {
        host.setStorage(address, slot, value) catch {
            return Error.StorageError;
        };
        return;
    }
    const key = StorageSlotKey{ .address = address, .slot = slot };

    // Track original value on first write in transaction
    if (!self.original_storage.contains(key)) {
        const current = self.storage.get(key) orelse 0;
        self.original_storage.put(key, current) catch {
            return Error.StorageError;
        };
    }

    self.storage.put(key, value) catch {
        return Error.StorageError;
    };
}
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

### MinimalEvm Implementation

```zig
// src/tracer/minimal_evm.zig
pub fn access_address(self: *Self, address: Address) !u64 {
    if (self.hardfork.isBefore(.BERLIN)) {
        @branchHint(.cold);
        return GasConstants.CallCodeCost;
    }

    const entry = try self.warm_addresses.getOrPut(self.allocator, address);
    return if (entry.found_existing)
        GasConstants.WarmStorageReadCost   // 100
    else
        GasConstants.ColdAccountAccessCost; // 2600
}

pub fn access_storage_slot(self: *Self, contract_address: Address, slot: u256) !u64 {
    if (self.hardfork.isBefore(.BERLIN)) {
        @branchHint(.cold);
        return GasConstants.SloadGas;
    }

    const key = StorageSlotKey{ .address = contract_address, .slot = slot };
    const entry = try self.warm_storage_slots.getOrPut(self.allocator, key);
    return if (entry.found_existing)
        GasConstants.WarmStorageReadCost // 100
    else
        GasConstants.ColdSloadCost;      // 2100
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
// src/tracer/minimal_evm.zig
pub fn get_transient_storage(self: *Self, address: Address, slot: u256) u256 {
    const key = StorageSlotKey{ .address = address, .slot = slot };
    return self.transient_storage.get(key) orelse 0;
}

pub fn set_transient_storage(self: *Self, address: Address, slot: u256, value: u256) Error!void {
    const key = StorageSlotKey{ .address = address, .slot = slot };
    self.transient_storage.put(key, value) catch {
        return Error.StorageError;
    };
}
```

### Handler

```zig
// src/tracer/minimal_frame.zig (MinimalFrame.executeOpcode)
// TLOAD
0x5c => {
    // EIP-1153: TLOAD was introduced in Cancun hardfork
    if (evm.hardfork.isBefore(.CANCUN)) return error.InvalidOpcode;

    try self.consumeGas(GasConstants.WarmStorageReadCost);
    const key = try self.popStack();
    const value = evm.get_transient_storage(self.address, key);
    try self.pushStack(value);
    self.pc += 1;
},

// TSTORE
0x5d => {
    // EIP-1153: TSTORE was introduced in Cancun hardfork
    if (evm.hardfork.isBefore(.CANCUN)) return error.InvalidOpcode;

    try self.consumeGas(GasConstants.WarmStorageReadCost);
    const key = try self.popStack();
    const value = try self.popStack();
    try evm.set_transient_storage(self.address, key, value);
    self.pc += 1;
},
```

## SSTORE Gas Calculation (EIP-2200)

Complex gas calculation based on original, current, and new values:

```zig
// src/tracer/minimal_frame.zig (MinimalFrame.executeOpcode)
// SSTORE
0x55 => {
    const key = try self.popStack();
    const value = try self.popStack();

    // EIP-2200 (Istanbul+): fail when gas left is at or below the stipend.
    if (fork_gas.sstoreHasSentry(self.hardfork) and self.gas_remaining <= @as(i64, @intCast(fork_gas.sstore_sentry_gas))) {
        self.gas_remaining = 0;
        return error.OutOfGas;
    }

    // Get current and original values for gas calculation
    const current_value = evm.get_storage(self.address, key);
    const original_value = evm.get_original_storage(self.address, key);

    // EIP-2929: Check if storage slot is cold and warm it
    const access_cost = try evm.access_storage_slot(self.address, key);
    const is_cold = fork_gas.hasAccessLists(self.hardfork) and access_cost == GasConstants.ColdSloadCost;

    // Same fork-aware metering as the Frame handler.
    const cost = fork_gas.sstoreCost(self.hardfork, original_value, current_value, value, is_cold);
    try self.consumeGas(cost.gas);

    if (cost.refund > 0) {
        evm.add_refund(@intCast(cost.refund));
    } else if (cost.refund < 0) {
        // Takes back a refund granted earlier in this transaction.
        const taken_back: u64 = @intCast(-cost.refund);
        if (taken_back > evm.gas_refund) return error.InvalidOpcode;
        evm.gas_refund -= taken_back;
    }

    try evm.set_storage(self.address, key, value);
    self.pc += 1;
},
```

`fork_gas.sstoreCost` in `src/frame/fork_gas.zig` holds the EIP-2200, EIP-2929
and EIP-3529 cost and refund rules; MinimalFrame and the performance Frame
share it.

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

### MinimalEvm: Standard Allocator

```zig
allocator: std.mem.Allocator,

// Direct HashMap allocation (src/tracer/minimal_evm.zig)
storage: std.AutoHashMap(StorageSlotKey, u256),
```

### Performance: Arena Allocator

```zig
// Transaction-scoped arena - freed all at once
call_arena: GrowingArenaAllocator,

// All state allocated from arena
// No individual frees during transaction
// Entire arena freed when transaction completes
```
