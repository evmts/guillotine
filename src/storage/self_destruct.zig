/// SELFDESTRUCT opcode implementation for contract destruction
/// Tracks contracts marked for destruction and handles deferred execution
const std = @import("std");
const primitives = @import("voltaire");
const Address = primitives.Address;
const CreatedContracts = @import("created_contracts.zig").CreatedContracts;
const SelfDestructRecord = @import("../frame/call_result.zig").SelfDestructRecord;

/// Error type for SelfDestruct operations
pub const StateError = error{OutOfMemory};

/// SelfDestruct tracks contracts marked for destruction via SELFDESTRUCT opcode
/// Destruction is deferred until end of transaction to maintain proper state semantics
pub const SelfDestruct = struct {
    /// Contract address -> recipient of its balance, in the order the contracts
    /// were first marked. Insertion order makes a checkpoint a pair of lengths.
    destructions: Map,
    /// Recipients replaced by a repeated SELFDESTRUCT of an already marked
    /// contract, oldest first, so that `revert` can put them back.
    replaced: std.ArrayList(Replaced),
    /// Allocator for the map and the replacement log
    allocator: std.mem.Allocator,

    const Map = std.array_hash_map.Auto(Address, Address);

    const Replaced = struct {
        index: usize,
        recipient: Address,
    };

    /// A point in the destruction list to return to with `revert`. O(1) to take.
    pub const Checkpoint = struct {
        count: usize,
        replaced: usize,
    };

    /// Initialize new SelfDestruct tracker with given allocator
    pub fn init(allocator: std.mem.Allocator) SelfDestruct {
        return SelfDestruct{
            .destructions = .empty,
            .replaced = .empty,
            .allocator = allocator,
        };
    }

    /// Clean up resources
    pub fn deinit(self: *SelfDestruct) void {
        self.destructions.deinit(self.allocator);
        self.replaced.deinit(self.allocator);
    }

    /// Mark the current state of the list. Costs O(1) and allocates nothing.
    pub fn checkpoint(self: *const SelfDestruct) Checkpoint {
        return .{ .count = self.destructions.count(), .replaced = self.replaced.items.len };
    }

    /// Undo every mark made since `mark` was taken: restore replaced recipients,
    /// newest first, then drop the contracts marked after it. Never allocates.
    pub fn revert(self: *SelfDestruct, mark: Checkpoint) void {
        while (self.replaced.items.len > mark.replaced) {
            const entry = self.replaced.items[self.replaced.items.len - 1];
            self.replaced.items.len -= 1;
            if (entry.index < mark.count) self.destructions.values()[entry.index] = entry.recipient;
        }
        self.destructions.shrinkRetainingCapacity(mark.count);
    }

    /// Convert the internal HashMap to an owned slice of SelfDestructRecord for CallResult
    /// Returns an allocated slice that the caller must eventually free
    pub fn toOwnedSlice(self: *SelfDestruct, allocator: std.mem.Allocator) ![]const SelfDestructRecord {
        // Early return for empty case
        if (self.destructions.count() == 0) {
            return &.{};
        }

        // Use ArrayList for efficient single-pass collection (idiomatic Zig pattern)
        var list = std.ArrayList(SelfDestructRecord).empty;
        errdefer list.deinit(allocator); // Clean up on error
        
        // Single iteration through HashMap
        var iter = self.iterator();
        while (iter.next()) |entry| {
            try list.append(allocator, SelfDestructRecord{
                .contract = entry.key_ptr.*,
                .beneficiary = entry.value_ptr.*,
            });
        }
        
        // Transfer ownership to caller
        return try list.toOwnedSlice(allocator);
    }

    /// Mark a contract for destruction
    /// contract_addr: Address of the contract calling SELFDESTRUCT
    /// recipient: Address that will receive the contract's remaining balance
    pub fn mark_for_destruction(self: *SelfDestruct, contract_addr: Address, recipient: Address) StateError!void {
        try self.replaced.ensureUnusedCapacity(self.allocator, 1);
        const slot = try self.destructions.getOrPut(self.allocator, contract_addr);
        if (slot.found_existing) {
            self.replaced.appendAssumeCapacity(.{ .index = slot.index, .recipient = slot.value_ptr.* });
        }
        slot.value_ptr.* = recipient;
    }

    /// Check if a contract is marked for destruction
    pub fn is_marked_for_destruction(self: *SelfDestruct, contract_addr: Address) bool {
        return self.destructions.contains(contract_addr);
    }

    /// Get the recipient address for a contract marked for destruction
    /// Returns null if the contract is not marked for destruction
    pub fn get_recipient(self: *SelfDestruct, contract_addr: Address) ?Address {
        return self.destructions.get(contract_addr);
    }

    /// Get iterator over all contracts marked for destruction
    /// Returns iterator yielding (contract_address, recipient_address) pairs
    pub fn iterator(self: *SelfDestruct) Map.Iterator {
        return self.destructions.iterator();
    }

    /// Get count of contracts marked for destruction
    pub fn count(self: *SelfDestruct) u32 {
        return @intCast(self.destructions.count());
    }

    /// Remove a contract from the destruction list (used for testing/cleanup)
    /// Checkpoints taken before the call no longer describe the list.
    pub fn unmark(self: *SelfDestruct, contract_addr: Address) bool {
        self.replaced.clearRetainingCapacity();
        return self.destructions.orderedRemove(contract_addr);
    }

    /// Clear all marked contracts (used for testing/cleanup)
    pub fn clear(self: *SelfDestruct) void {
        self.destructions.clearRetainingCapacity();
        self.replaced.clearRetainingCapacity();
    }

    /// Apply all pending destructions to the given state interface
    /// This is called at the end of transaction execution
    /// 
    /// ## Parameters
    /// - `state`: The state interface supporting balance transfers and account deletion
    /// - `created_contracts`: Optional tracker of contracts created in this transaction (for EIP-6780)
    /// - `chain_rules`: Chain rules to determine if EIP-6780 is active
    ///
    /// ## EIP-6780 Behavior (Cancun+)
    /// - If contract was created in same transaction: Full destruction (balance transfer + deletion)
    /// - If contract existed before transaction: Only balance transfer, contract remains
    ///
    /// ## Pre-Cancun Behavior
    /// - Always perform full destruction for all marked contracts
    pub fn apply_destructions(
        self: *SelfDestruct,
        state: anytype,
        created_contracts: ?*const CreatedContracts,
        chain_rules: anytype,
    ) !void {
        const is_cancun = @hasField(@TypeOf(chain_rules), "is_cancun") and chain_rules.is_cancun;
        
        var iter = self.iterator();
        while (iter.next()) |entry| {
            const contract_addr = entry.key_ptr.*;
            const recipient_addr = entry.value_ptr.*;
            
            // Get the contract's balance before any operations
            const balance = try state.get_balance(contract_addr);
            
            // Transfer balance to recipient (always happens)
            if (balance > 0) {
                try state.transfer_balance(contract_addr, recipient_addr, balance);
            }
            
            // Determine if we should fully destroy the contract
            const should_destroy = if (is_cancun) blk: {
                // EIP-6780: Only destroy if created in same transaction
                if (created_contracts) |created| {
                    break :blk created.was_created_in_tx(contract_addr);
                }
                // If no tracking available, assume pre-existing (don't destroy)
                break :blk false;
            } else true; // Pre-Cancun: always destroy
            
            // Perform full destruction if applicable
            if (should_destroy) {
                // Delete contract code
                try state.set_code(contract_addr, &[_]u8{});
                
                // Delete all storage (this would typically iterate through storage keys)
                try state.clear_storage(contract_addr);
                
                // Delete the account itself if it's now empty
                // (no balance, no code, no storage, nonce = 0)
                const nonce = try state.get_nonce(contract_addr);
                if (nonce == 0) {
                    try state.delete_account(contract_addr);
                }
            }
        }
    }
};

test "SelfDestruct - basic marking and checking" {
    const allocator = std.testing.allocator;
    var self_destruct = SelfDestruct.init(allocator);
    defer self_destruct.deinit();

    const contract_addr = primitives.ZERO_ADDRESS;
    const recipient_addr_bytes = [_]u8{0x01} ++ @as([19]u8, @splat(0));
    const recipient_addr = Address{ .bytes = recipient_addr_bytes };

    // Initially not marked
    try std.testing.expect(!self_destruct.is_marked_for_destruction(contract_addr));
    try std.testing.expectEqual(@as(?Address, null), self_destruct.get_recipient(contract_addr));

    // Mark for destruction
    try self_destruct.mark_for_destruction(contract_addr, recipient_addr);

    // Should now be marked
    try std.testing.expect(self_destruct.is_marked_for_destruction(contract_addr));
    const retrieved_recipient = self_destruct.get_recipient(contract_addr);
    try std.testing.expect(retrieved_recipient != null);
    try std.testing.expectEqualSlices(u8, &recipient_addr.bytes, &retrieved_recipient.?.bytes);

    // Check count
    try std.testing.expectEqual(@as(u32, 1), self_destruct.count());
}

test "SelfDestruct - multiple contracts" {
    const allocator = std.testing.allocator;
    var self_destruct = SelfDestruct.init(allocator);
    defer self_destruct.deinit();

    const contract1 = primitives.ZERO_ADDRESS;
    const contract2_bytes = [_]u8{0x02} ++ @as([19]u8, @splat(0));
    const contract2 = Address{ .bytes = contract2_bytes };
    const recipient1_bytes = [_]u8{0x01} ++ @as([19]u8, @splat(0));
    const recipient1 = Address{ .bytes = recipient1_bytes };
    const recipient2_bytes = [_]u8{0x03} ++ @as([19]u8, @splat(0));
    const recipient2 = Address{ .bytes = recipient2_bytes };

    // Mark multiple contracts
    try self_destruct.mark_for_destruction(contract1, recipient1);
    try self_destruct.mark_for_destruction(contract2, recipient2);

    // Both should be marked
    try std.testing.expect(self_destruct.is_marked_for_destruction(contract1));
    try std.testing.expect(self_destruct.is_marked_for_destruction(contract2));

    // Check count
    try std.testing.expectEqual(@as(u32, 2), self_destruct.count());

    // Check recipients
    const recp1 = self_destruct.get_recipient(contract1);
    const recp2 = self_destruct.get_recipient(contract2);
    try std.testing.expectEqualSlices(u8, &recipient1.bytes, &recp1.?.bytes);
    try std.testing.expectEqualSlices(u8, &recipient2.bytes, &recp2.?.bytes);
}

test "SelfDestruct - iterator functionality" {
    const allocator = std.testing.allocator;
    var self_destruct = SelfDestruct.init(allocator);
    defer self_destruct.deinit();

    const contract1 = primitives.ZERO_ADDRESS;
    const contract2_bytes = [_]u8{0x02} ++ @as([19]u8, @splat(0));
    const contract2 = Address{ .bytes = contract2_bytes };
    const recipient1_bytes = [_]u8{0x01} ++ @as([19]u8, @splat(0));
    const recipient1 = Address{ .bytes = recipient1_bytes };
    const recipient2_bytes = [_]u8{0x03} ++ @as([19]u8, @splat(0));
    const recipient2 = Address{ .bytes = recipient2_bytes };

    // Mark contracts
    try self_destruct.mark_for_destruction(contract1, recipient1);
    try self_destruct.mark_for_destruction(contract2, recipient2);

    // Count via iterator
    var iter = self_destruct.iterator();
    var count: u32 = 0;
    while (iter.next()) |_| {
        count += 1;
    }
    try std.testing.expectEqual(@as(u32, 2), count);
}

test "SelfDestruct - unmark and clear" {
    const allocator = std.testing.allocator;
    var self_destruct = SelfDestruct.init(allocator);
    defer self_destruct.deinit();

    const contract_addr = primitives.ZERO_ADDRESS;
    const recipient_addr_bytes = [_]u8{0x01} ++ @as([19]u8, @splat(0));
    const recipient_addr = Address{ .bytes = recipient_addr_bytes };

    // Mark and verify
    try self_destruct.mark_for_destruction(contract_addr, recipient_addr);
    try std.testing.expectEqual(@as(u32, 1), self_destruct.count());

    // Unmark and verify
    const was_removed = self_destruct.unmark(contract_addr);
    try std.testing.expect(was_removed);
    try std.testing.expectEqual(@as(u32, 0), self_destruct.count());
    try std.testing.expect(!self_destruct.is_marked_for_destruction(contract_addr));

    // Re-mark for clear test
    try self_destruct.mark_for_destruction(contract_addr, recipient_addr);
    try std.testing.expectEqual(@as(u32, 1), self_destruct.count());

    // Clear and verify
    self_destruct.clear();
    try std.testing.expectEqual(@as(u32, 0), self_destruct.count());
    try std.testing.expect(!self_destruct.is_marked_for_destruction(contract_addr));
}
test "SelfDestruct checkpoint and revert restore the list without cloning it" {
    const testing = std.testing;
    var self_destruct = SelfDestruct.init(testing.allocator);
    defer self_destruct.deinit();

    const contract_a = Address{ .bytes = @as([20]u8, @splat(0xA)) };
    const contract_b = Address{ .bytes = @as([20]u8, @splat(0xB)) };
    const first = Address{ .bytes = @as([20]u8, @splat(0x1)) };
    const second = Address{ .bytes = @as([20]u8, @splat(0x2)) };

    try self_destruct.mark_for_destruction(contract_a, first);
    const mark = self_destruct.checkpoint();

    // A nested frame re-marks A with another recipient and marks B, then fails.
    try self_destruct.mark_for_destruction(contract_a, second);
    try self_destruct.mark_for_destruction(contract_b, second);
    try testing.expectEqual(@as(u32, 2), self_destruct.count());
    try testing.expectEqual(second, self_destruct.get_recipient(contract_a).?);

    self_destruct.revert(mark);
    try testing.expectEqual(@as(u32, 1), self_destruct.count());
    try testing.expectEqual(first, self_destruct.get_recipient(contract_a).?);
    try testing.expect(!self_destruct.is_marked_for_destruction(contract_b));

    // Reverting to the same mark again changes nothing.
    self_destruct.revert(mark);
    try testing.expectEqual(@as(u32, 1), self_destruct.count());
}
