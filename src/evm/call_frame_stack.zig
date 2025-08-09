const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const AutoHashMap = std.AutoHashMap;
const Address = @import("primitives").Address.Address;
const primitives = @import("../primitives/primitives.zig");

/// Access list for EIP-2929 warm/cold address and storage tracking
pub const AccessList = struct {
    /// Gas costs for EIP-2929
    pub const WARM_ACCOUNT_ACCESS_COST = 100;
    pub const COLD_ACCOUNT_ACCESS_COST = 2600;
    pub const WARM_STORAGE_ACCESS_COST = 100;
    pub const COLD_STORAGE_ACCESS_COST = 2100;

    /// Warm addresses accessed this transaction
    warm_addresses: AutoHashMap(Address, void),
    /// Warm storage slots accessed this transaction
    warm_storage: AutoHashMap(Address, AutoHashMap(u256, void)),

    allocator: Allocator,

    pub fn init(allocator: Allocator) !AccessList {
        return AccessList{
            .warm_addresses = AutoHashMap(Address, void).init(allocator),
            .warm_storage = AutoHashMap(Address, AutoHashMap(u256, void)).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *AccessList) void {
        self.warm_addresses.deinit();

        var storage_iter = self.warm_storage.iterator();
        while (storage_iter.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.warm_storage.deinit();
    }

    /// Mark address as accessed, return gas cost
    pub fn access_address(self: *AccessList, addr: Address) !u64 {
        if (self.warm_addresses.contains(addr)) {
            return WARM_ACCOUNT_ACCESS_COST;
        } else {
            try self.warm_addresses.put(addr, {});
            return COLD_ACCOUNT_ACCESS_COST;
        }
    }

    /// Mark storage slot as accessed, return gas cost
    pub fn access_storage(self: *AccessList, addr: Address, key: u256) u64 {
        const storage = self.warm_storage.getOrPut(addr) catch {
            return COLD_STORAGE_ACCESS_COST;
        };

        if (!storage.found_existing) {
            storage.value_ptr.* = AutoHashMap(u256, void).init(self.allocator);
        }

        if (storage.value_ptr.contains(key)) {
            return WARM_STORAGE_ACCESS_COST;
        } else {
            storage.value_ptr.put(key, {}) catch {};
            return COLD_STORAGE_ACCESS_COST;
        }
    }

    /// Mark storage slot as accessed, return whether it was cold (true) or warm (false)
    pub fn access_storage_key(self: *AccessList, addr: Address, key: u256) !bool {
        const storage = try self.warm_storage.getOrPut(addr);

        if (!storage.found_existing) {
            storage.value_ptr.* = AutoHashMap(u256, void).init(self.allocator);
        }

        const was_cold = !storage.value_ptr.contains(key);
        if (was_cold) {
            try storage.value_ptr.put(key, {});
        }

        return was_cold;
    }
};

/// Journal entry types for revertible operations
pub const JournalEntry = union(enum) {
    selfdestruct: struct {
        snapshot_id: u32,
        contract: Address,
        recipient: Address,
    },
    storage_change: struct {
        snapshot_id: u32,
        address: Address,
        key: u256,
        original_value: u256,
    },
    balance_change: struct {
        snapshot_id: u32,
        address: Address,
        original_balance: u256,
    },
    nonce_change: struct {
        snapshot_id: u32,
        address: Address,
        original_nonce: u64,
    },
    log_entry: struct {
        snapshot_id: u32,
        // Log entries are just marked for removal on revert
    },
};

/// Journaling system for revertible operations
pub const CallJournal = struct {
    /// Journal entries for revertible operations
    entries: ArrayList(JournalEntry),
    /// Current snapshot ID counter
    next_snapshot_id: u32,

    /// Original storage values recorded per (address, key) on first write in the transaction
    original_storage: AutoHashMap(Address, AutoHashMap(u256, u256)),

    pub fn init(allocator: Allocator) CallJournal {
        return CallJournal{
            .entries = ArrayList(JournalEntry).init(allocator),
            .next_snapshot_id = 0,
            .original_storage = AutoHashMap(Address, AutoHashMap(u256, u256)).init(allocator),
        };
    }

    pub fn deinit(self: *CallJournal) void {
        self.entries.deinit();
        var it = self.original_storage.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.original_storage.deinit();
    }

    /// Create a snapshot point for revertible operations
    pub fn create_snapshot(self: *CallJournal) u32 {
        const id = self.next_snapshot_id;
        self.next_snapshot_id += 1;
        return id;
    }

    /// Revert all changes back to snapshot
    pub fn revert_to_snapshot(self: *CallJournal, snapshot_id: u32) void {
        var i: usize = self.entries.items.len;
        while (i > 0) {
            i -= 1;
            const entry = self.entries.items[i];

            const entry_snapshot = switch (entry) {
                .selfdestruct => |sd| sd.snapshot_id,
                .storage_change => |sc| sc.snapshot_id,
                .balance_change => |bc| bc.snapshot_id,
                .nonce_change => |nc| nc.snapshot_id,
                .log_entry => |le| le.snapshot_id,
            };

            if (entry_snapshot >= snapshot_id) {
                _ = self.entries.swapRemove(i);
            }
        }
    }

    /// Record a self-destruct operation
    pub fn record_selfdestruct(self: *CallJournal, snapshot_id: u32, contract: Address, recipient: Address) !void {
        try self.entries.append(.{
            .selfdestruct = .{
                .snapshot_id = snapshot_id,
                .contract = contract,
                .recipient = recipient,
            },
        });
    }

    /// Record a storage change
    pub fn record_storage_change(self: *CallJournal, snapshot_id: u32, address: Address, key: u256, original_value: u256) !void {
        // Persist the original value on first write within this transaction
        var outer = try self.original_storage.getOrPut(address);
        if (!outer.found_existing) {
            outer.value_ptr.* = AutoHashMap(u256, u256).init(self.entries.allocator);
        }
        if (!outer.value_ptr.contains(key)) {
            try outer.value_ptr.put(key, original_value);
        }
        try self.entries.append(.{
            .storage_change = .{
                .snapshot_id = snapshot_id,
                .address = address,
                .key = key,
                .original_value = original_value,
            },
        });
    }

    /// Record a balance change
    pub fn record_balance_change(self: *CallJournal, snapshot_id: u32, address: Address, original_balance: u256) !void {
        try self.entries.append(.{
            .balance_change = .{
                .snapshot_id = snapshot_id,
                .address = address,
                .original_balance = original_balance,
            },
        });
    }

    /// Record a nonce change
    pub fn record_nonce_change(self: *CallJournal, snapshot_id: u32, address: Address, original_nonce: u64) !void {
        try self.entries.append(.{
            .nonce_change = .{
                .snapshot_id = snapshot_id,
                .address = address,
                .original_nonce = original_nonce,
            },
        });
    }

    /// Record a log entry (for revert purposes)
    pub fn record_log_entry(self: *CallJournal, snapshot_id: u32) !void {
        try self.entries.append(.{
            .log_entry = .{
                .snapshot_id = snapshot_id,
            },
        });
    }

    /// Get the original storage value recorded for (address, key), if any
    pub fn get_original_storage(self: *const CallJournal, address: Address, key: u256) ?u256 {
        if (self.original_storage.get(address)) |inner| {
            if (inner.get(key)) |val| return val;
        }
        return null;
    }
};
