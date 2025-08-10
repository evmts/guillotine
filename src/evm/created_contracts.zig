/// Tracks contracts created within the current transaction for EIP-6780 compliance
/// EIP-6780 restricts SELFDESTRUCT to only work on contracts created in the same transaction
const std = @import("std");
const primitives = @import("primitives");
const Address = primitives.Address.Address;

/// Error type for CreatedContracts operations
pub const StateError = error{OutOfMemory};

/// CreatedContracts tracks contracts created within the current transaction
/// Used for EIP-6780 compliance where SELFDESTRUCT only works on same-tx contracts
pub const CreatedContracts = struct {
    /// Set of addresses created in current transaction
    contracts: std.HashMap(Address, void, AddressContext, std.hash_map.default_max_load_percentage),
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

    /// Initialize new CreatedContracts tracker
    pub fn init(allocator: std.mem.Allocator) CreatedContracts {
        return CreatedContracts{
            .contracts = std.HashMap(Address, void, AddressContext, std.hash_map.default_max_load_percentage).init(allocator),
            .allocator = allocator,
        };
    }

    /// Clean up resources
    pub fn deinit(self: *CreatedContracts) void {
        self.contracts.deinit();
    }

    /// Mark a contract as created in this transaction
    pub fn mark_created(self: *CreatedContracts, contract_addr: Address) StateError!void {
        try self.contracts.put(contract_addr, {});
    }

    /// Check if a contract was created in this transaction
    pub fn was_created_in_tx(self: *const CreatedContracts, contract_addr: Address) bool {
        return self.contracts.contains(contract_addr);
    }

    /// Get count of contracts created in this transaction
    pub fn count(self: *const CreatedContracts) u32 {
        return @intCast(self.contracts.count());
    }

    /// Clear all tracked contracts (used for new transaction)
    pub fn clear(self: *CreatedContracts) void {
        self.contracts.clearRetainingCapacity();
    }
};

test "CreatedContracts - basic tracking" {
    const allocator = std.testing.allocator;
    var created = CreatedContracts.init(allocator);
    defer created.deinit();

    const contract_addr = primitives.Address.ZERO_ADDRESS;

    // Initially not created
    try std.testing.expect(!created.was_created_in_tx(contract_addr));
    try std.testing.expectEqual(@as(u32, 0), created.count());

    // Mark as created
    try created.mark_created(contract_addr);

    // Should now be tracked
    try std.testing.expect(created.was_created_in_tx(contract_addr));
    try std.testing.expectEqual(@as(u32, 1), created.count());
}

test "CreatedContracts - multiple contracts" {
    const allocator = std.testing.allocator;
    var created = CreatedContracts.init(allocator);
    defer created.deinit();

    const contract1 = primitives.Address.ZERO_ADDRESS;
    const contract2 = [_]u8{0x02} ++ [_]u8{0} ** 19;
    const contract3 = [_]u8{0x03} ++ [_]u8{0} ** 19;

    // Mark multiple contracts
    try created.mark_created(contract1);
    try created.mark_created(contract2);

    // Check tracking
    try std.testing.expect(created.was_created_in_tx(contract1));
    try std.testing.expect(created.was_created_in_tx(contract2));
    try std.testing.expect(!created.was_created_in_tx(contract3));

    try std.testing.expectEqual(@as(u32, 2), created.count());
}

test "CreatedContracts - clear functionality" {
    const allocator = std.testing.allocator;
    var created = CreatedContracts.init(allocator);
    defer created.deinit();

    const contract_addr = primitives.Address.ZERO_ADDRESS;

    // Mark and verify
    try created.mark_created(contract_addr);
    try std.testing.expectEqual(@as(u32, 1), created.count());
    try std.testing.expect(created.was_created_in_tx(contract_addr));

    // Clear and verify
    created.clear();
    try std.testing.expectEqual(@as(u32, 0), created.count());
    try std.testing.expect(!created.was_created_in_tx(contract_addr));
}
