/// SELFDESTRUCT opcode implementation for contract destruction
/// Tracks contracts marked for destruction and handles deferred execution
const std = @import("std");
const primitives = @import("primitives");
const Address = primitives.Address.Address;

/// Error type for SelfDestruct operations
pub const StateError = error{OutOfMemory};

/// SelfDestruct tracks contracts marked for destruction via SELFDESTRUCT opcode
/// Destruction is deferred until end of transaction to maintain proper state semantics
pub const SelfDestruct = struct {
    /// HashMap mapping contract address to recipient address
    /// Key: address of contract to destroy
    /// Value: address to receive remaining balance
    destructions: std.HashMap(Address, Address, AddressContext, std.hash_map.default_max_load_percentage),
    /// Allocator for HashMap operations
    allocator: std.mem.Allocator,

    /// Context for Address HashMap
    const AddressContext = struct {
        pub fn hash(self: @This(), address: Address) u64 {
            _ = self;
            var hasher = std.hash.Wyhash.init(0);
            hasher.update(&address);
            return hasher.final();
        }

        pub fn eql(self: @This(), a: Address, b: Address) bool {
            _ = self;
            return std.mem.eql(u8, &a, &b);
        }
    };

    /// Initialize new SelfDestruct tracker with given allocator
    pub fn init(allocator: std.mem.Allocator) SelfDestruct {
        return SelfDestruct{
            .destructions = std.HashMap(Address, Address, AddressContext, std.hash_map.default_max_load_percentage).init(allocator),
            .allocator = allocator,
        };
    }

    /// Clean up resources
    pub fn deinit(self: *SelfDestruct) void {
        self.destructions.deinit();
    }

    /// Transfer ownership of this SelfDestruct to the caller
    /// After calling this, the original SelfDestruct should not be used
    pub fn to_owned(self: SelfDestruct) SelfDestruct {
        return SelfDestruct{
            .destructions = self.destructions,
            .allocator = self.allocator,
        };
    }

    /// Mark a contract for destruction
    /// contract_addr: Address of the contract calling SELFDESTRUCT
    /// recipient: Address that will receive the contract's remaining balance
    pub fn mark_for_destruction(self: *SelfDestruct, contract_addr: Address, recipient: Address) StateError!void {
        try self.destructions.put(contract_addr, recipient);
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
    pub fn iterator(self: *SelfDestruct) std.HashMap(Address, Address, AddressContext, std.hash_map.default_max_load_percentage).Iterator {
        return self.destructions.iterator();
    }

    /// Get count of contracts marked for destruction
    pub fn count(self: *SelfDestruct) u32 {
        return @intCast(self.destructions.count());
    }

    /// Remove a contract from the destruction list (used for testing/cleanup)
    pub fn unmark(self: *SelfDestruct, contract_addr: Address) bool {
        return self.destructions.remove(contract_addr);
    }

    /// Clear all marked contracts (used for testing/cleanup)
    pub fn clear(self: *SelfDestruct) void {
        self.destructions.clearRetainingCapacity();
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

    const contract_addr = primitives.Address.ZERO_ADDRESS;
    const recipient_addr = [_]u8{0x01} ++ [_]u8{0} ** 19;

    // Initially not marked
    try std.testing.expect(!self_destruct.is_marked_for_destruction(contract_addr));
    try std.testing.expectEqual(@as(?Address, null), self_destruct.get_recipient(contract_addr));

    // Mark for destruction
    try self_destruct.mark_for_destruction(contract_addr, recipient_addr);

    // Should now be marked
    try std.testing.expect(self_destruct.is_marked_for_destruction(contract_addr));
    const retrieved_recipient = self_destruct.get_recipient(contract_addr);
    try std.testing.expect(retrieved_recipient != null);
    try std.testing.expectEqualSlices(u8, &recipient_addr, &retrieved_recipient.?);

    // Check count
    try std.testing.expectEqual(@as(u32, 1), self_destruct.count());
}

test "SelfDestruct - multiple contracts" {
    const allocator = std.testing.allocator;
    var self_destruct = SelfDestruct.init(allocator);
    defer self_destruct.deinit();

    const contract1 = primitives.Address.ZERO_ADDRESS;
    const contract2 = [_]u8{0x02} ++ [_]u8{0} ** 19;
    const recipient1 = [_]u8{0x01} ++ [_]u8{0} ** 19;
    const recipient2 = [_]u8{0x03} ++ [_]u8{0} ** 19;

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
    try std.testing.expectEqualSlices(u8, &recipient1, &recp1.?);
    try std.testing.expectEqualSlices(u8, &recipient2, &recp2.?);
}

test "SelfDestruct - iterator functionality" {
    const allocator = std.testing.allocator;
    var self_destruct = SelfDestruct.init(allocator);
    defer self_destruct.deinit();

    const contract1 = primitives.Address.ZERO_ADDRESS;
    const contract2 = [_]u8{0x02} ++ [_]u8{0} ** 19;
    const recipient1 = [_]u8{0x01} ++ [_]u8{0} ** 19;
    const recipient2 = [_]u8{0x03} ++ [_]u8{0} ** 19;

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

    const contract_addr = primitives.Address.ZERO_ADDRESS;
    const recipient_addr = [_]u8{0x01} ++ [_]u8{0} ** 19;

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