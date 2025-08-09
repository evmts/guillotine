const std = @import("std");
const testing = std.testing;
const primitives = @import("primitives");
const Address = primitives.Address.Address;
const SelfDestruct = @import("../../../src/evm/self_destruct.zig").SelfDestruct;
const CreatedContracts = @import("../../../src/evm/created_contracts.zig").CreatedContracts;
const ChainRules = @import("../../../src/evm/hardforks/chain_rules.zig").ChainRules;

// Context for Address HashMap
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

test "EIP-6780: SELFDESTRUCT only destroys contracts created in same transaction (Cancun)" {
    const allocator = std.testing.allocator;
    
    // Create a mock state that tracks operations
    const MockState = struct {
        balances: std.HashMap(Address, primitives.u256, AddressContext, std.hash_map.default_max_load_percentage),
        codes: std.HashMap(Address, []const u8, AddressContext, std.hash_map.default_max_load_percentage),
        nonces: std.HashMap(Address, u64, AddressContext, std.hash_map.default_max_load_percentage),
        deleted: std.ArrayList(Address),
        
        const Self = @This();
        
        pub fn init(alloc: std.mem.Allocator) Self {
            return .{
                .balances = std.HashMap(Address, primitives.u256, AddressContext, std.hash_map.default_max_load_percentage).init(alloc),
                .codes = std.HashMap(Address, []const u8, AddressContext, std.hash_map.default_max_load_percentage).init(alloc),
                .nonces = std.HashMap(Address, u64, AddressContext, std.hash_map.default_max_load_percentage).init(alloc),
                .deleted = std.ArrayList(Address).init(alloc),
            };
        }
        
        pub fn deinit(self: *Self) void {
            self.balances.deinit();
            self.codes.deinit();
            self.nonces.deinit();
            self.deleted.deinit();
        }
        
        pub fn get_balance(self: *Self, addr: Address) !primitives.u256 {
            return self.balances.get(addr) orelse 0;
        }
        
        pub fn transfer_balance(self: *Self, from: Address, to: Address, amount: primitives.u256) !void {
            const from_balance = try self.get_balance(from);
            if (from_balance < amount) return error.InsufficientBalance;
            
            try self.balances.put(from, from_balance - amount);
            const to_balance = try self.get_balance(to);
            try self.balances.put(to, to_balance + amount);
        }
        
        pub fn set_code(self: *Self, addr: Address, code: []const u8) !void {
            try self.codes.put(addr, code);
        }
        
        pub fn clear_storage(self: *Self, addr: Address) !void {
            _ = addr;
            // Mock implementation - in real EVM this would clear all storage slots
        }
        
        pub fn get_nonce(self: *Self, addr: Address) !u64 {
            return self.nonces.get(addr) orelse 0;
        }
        
        pub fn delete_account(self: *Self, addr: Address) !void {
            try self.deleted.append(addr);
            _ = self.balances.remove(addr);
            _ = self.codes.remove(addr);
            _ = self.nonces.remove(addr);
        }
    };
    
    // Test 1: Pre-existing contract with Cancun rules - should NOT be destroyed
    {
        var self_destruct = SelfDestruct.init(allocator);
        defer self_destruct.deinit();
        
        var created_contracts = CreatedContracts.init(allocator);
        defer created_contracts.deinit();
        
        var state = MockState.init(allocator);
        defer state.deinit();
        
        const contract_addr = try primitives.Address.from_hex("0x1234567890123456789012345678901234567890");
        const recipient_addr = try primitives.Address.from_hex("0xabcdefabcdefabcdefabcdefabcdefabcdefabcd");
        
        // Set up pre-existing contract with balance and code
        try state.balances.put(contract_addr, 1000);
        try state.codes.put(contract_addr, &[_]u8{0x60, 0x00}); // PUSH1 0
        
        // Mark for destruction
        try self_destruct.mark_for_destruction(contract_addr, recipient_addr);
        
        // Apply destructions with Cancun rules
        const cancun_rules = ChainRules.for_hardfork(.CANCUN);
        try self_destruct.apply_destructions(&state, &created_contracts, cancun_rules);
        
        // Balance should be transferred
        try testing.expectEqual(@as(primitives.u256, 0), try state.get_balance(contract_addr));
        try testing.expectEqual(@as(primitives.u256, 1000), try state.get_balance(recipient_addr));
        
        // Contract should NOT be deleted (EIP-6780)
        try testing.expectEqual(@as(usize, 0), state.deleted.items.len);
        try testing.expect(state.codes.contains(contract_addr)); // Code still exists
    }
    
    // Test 2: Contract created in same transaction with Cancun rules - SHOULD be destroyed
    {
        var self_destruct = SelfDestruct.init(allocator);
        defer self_destruct.deinit();
        
        var created_contracts = CreatedContracts.init(allocator);
        defer created_contracts.deinit();
        
        var state = MockState.init(allocator);
        defer state.deinit();
        
        const contract_addr = try primitives.Address.from_hex("0x2234567890123456789012345678901234567890");
        const recipient_addr = try primitives.Address.from_hex("0xbbcdefabcdefabcdefabcdefabcdefabcdefabcd");
        
        // Mark contract as created in this transaction
        try created_contracts.mark_created(contract_addr);
        
        // Set up contract with balance and code
        try state.balances.put(contract_addr, 2000);
        try state.codes.put(contract_addr, &[_]u8{0x60, 0x00}); // PUSH1 0
        try state.nonces.put(contract_addr, 0); // Nonce 0 for deletion
        
        // Mark for destruction
        try self_destruct.mark_for_destruction(contract_addr, recipient_addr);
        
        // Apply destructions with Cancun rules
        const cancun_rules = ChainRules.for_hardfork(.CANCUN);
        try self_destruct.apply_destructions(&state, &created_contracts, cancun_rules);
        
        // Balance should be transferred
        try testing.expectEqual(@as(primitives.u256, 0), try state.get_balance(contract_addr));
        try testing.expectEqual(@as(primitives.u256, 2000), try state.get_balance(recipient_addr));
        
        // Contract SHOULD be deleted (created in same tx)
        try testing.expectEqual(@as(usize, 1), state.deleted.items.len);
        try testing.expectEqualSlices(u8, &contract_addr, &state.deleted.items[0]);
        try testing.expect(!state.codes.contains(contract_addr)); // Code deleted
    }
    
    // Test 3: Pre-Cancun rules - all contracts should be destroyed
    {
        var self_destruct = SelfDestruct.init(allocator);
        defer self_destruct.deinit();
        
        var created_contracts = CreatedContracts.init(allocator);
        defer created_contracts.deinit();
        
        var state = MockState.init(allocator);
        defer state.deinit();
        
        const contract_addr = try primitives.Address.from_hex("0x3234567890123456789012345678901234567890");
        const recipient_addr = try primitives.Address.from_hex("0xcbcdefabcdefabcdefabcdefabcdefabcdefabcd");
        
        // Set up pre-existing contract (NOT created in this tx)
        try state.balances.put(contract_addr, 3000);
        try state.codes.put(contract_addr, &[_]u8{0x60, 0x00}); // PUSH1 0
        try state.nonces.put(contract_addr, 0); // Nonce 0 for deletion
        
        // Mark for destruction
        try self_destruct.mark_for_destruction(contract_addr, recipient_addr);
        
        // Apply destructions with London rules (pre-Cancun)
        const london_rules = ChainRules.for_hardfork(.LONDON);
        try self_destruct.apply_destructions(&state, &created_contracts, london_rules);
        
        // Balance should be transferred
        try testing.expectEqual(@as(primitives.u256, 0), try state.get_balance(contract_addr));
        try testing.expectEqual(@as(primitives.u256, 3000), try state.get_balance(recipient_addr));
        
        // Contract SHOULD be deleted (pre-Cancun behavior)
        try testing.expectEqual(@as(usize, 1), state.deleted.items.len);
        try testing.expectEqualSlices(u8, &contract_addr, &state.deleted.items[0]);
        try testing.expect(!state.codes.contains(contract_addr)); // Code deleted
    }
}

test "EIP-6780: Multiple SELFDESTRUCTs with mixed creation status" {
    const allocator = std.testing.allocator;
    
    var self_destruct = SelfDestruct.init(allocator);
    defer self_destruct.deinit();
    
    var created_contracts = CreatedContracts.init(allocator);
    defer created_contracts.deinit();
    
    const MockState = struct {
        destroyed_count: u32 = 0,
        balance_transfers: std.ArrayList(struct { from: Address, to: Address, amount: primitives.u256 }),
        
        const Self = @This();
        
        pub fn init(alloc: std.mem.Allocator) Self {
            return .{
                .balance_transfers = std.ArrayList(struct { from: Address, to: Address, amount: primitives.u256 }).init(alloc),
            };
        }
        
        pub fn deinit(self: *Self) void {
            self.balance_transfers.deinit();
        }
        
        pub fn get_balance(self: *Self, addr: Address) !primitives.u256 {
            _ = self;
            _ = addr;
            return 1000; // All contracts have 1000 balance
        }
        
        pub fn transfer_balance(self: *Self, from: Address, to: Address, amount: primitives.u256) !void {
            try self.balance_transfers.append(.{ .from = from, .to = to, .amount = amount });
        }
        
        pub fn set_code(self: *Self, addr: Address, code: []const u8) !void {
            _ = self;
            _ = addr;
            _ = code;
        }
        
        pub fn clear_storage(self: *Self, addr: Address) !void {
            _ = self;
            _ = addr;
        }
        
        pub fn get_nonce(self: *Self, addr: Address) !u64 {
            _ = self;
            _ = addr;
            return 0;
        }
        
        pub fn delete_account(self: *Self, addr: Address) !void {
            _ = addr;
            self.destroyed_count += 1;
        }
    };
    
    var state = MockState.init(allocator);
    defer state.deinit();
    
    // Set up multiple contracts
    const contract1 = try primitives.Address.from_hex("0x1111111111111111111111111111111111111111");
    const contract2 = try primitives.Address.from_hex("0x2222222222222222222222222222222222222222");
    const contract3 = try primitives.Address.from_hex("0x3333333333333333333333333333333333333333");
    const recipient = try primitives.Address.from_hex("0xffffffffffffffffffffffffffffffffffffffff");
    
    // Only contract2 was created in this transaction
    try created_contracts.mark_created(contract2);
    
    // All three contracts self-destruct
    try self_destruct.mark_for_destruction(contract1, recipient);
    try self_destruct.mark_for_destruction(contract2, recipient);
    try self_destruct.mark_for_destruction(contract3, recipient);
    
    // Apply with Cancun rules
    const cancun_rules = ChainRules.for_hardfork(.CANCUN);
    try self_destruct.apply_destructions(&state, &created_contracts, cancun_rules);
    
    // All balances should be transferred
    try testing.expectEqual(@as(usize, 3), state.balance_transfers.items.len);
    
    // Only contract2 should be destroyed (created in same tx)
    try testing.expectEqual(@as(u32, 1), state.destroyed_count);
}