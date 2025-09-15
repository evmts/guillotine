const primitives = @import("primitives");
const AccessList = @import("../storage/access_list.zig").AccessList;
const Hardfork = @import("hardfork.zig").Hardfork;

// EIPs is a comptime known configuration of Eip and hardfork specific behavior
// This struct consolidates all EIP-specific logic for the EVM
pub const Eips = struct {
    const Self = @This();

    hardfork: Hardfork,
    
    /// EIP-7702: Set EOA account code (Prague)
    /// Allows EOAs to temporarily execute smart contract code for one transaction
    pub fn eip_7702_eoa_code_enabled(self: Self) bool {
        return self.hardfork.isAtLeast(.PRAGUE);
    }
    
    /// EIP-2537: BLS12-381 precompile operations (Prague)
    /// Adds precompiled contracts for BLS12-381 curve operations
    pub fn eip_2537_bls_precompiles_enabled(self: Self) bool {
        return self.hardfork.isAtLeast(.PRAGUE);
    }
    
    /// EIP-2935: Serve historical block hashes from state (Prague)
    /// Stores historical block hashes in the state for easier access
    pub fn eip_2935_historical_block_hashes_enabled(self: Self) bool {
        return self.hardfork.isAtLeast(.PRAGUE);
    }
    
    /// EIP-6110: Supply validator deposits on chain (Prague)
    /// Validator deposits handled directly on execution layer
    pub fn eip_6110_validator_deposits_enabled(self: Self) bool {
        return self.hardfork.isAtLeast(.PRAGUE);
    }
    
    /// EIP-7002: Execution layer triggerable exits (Prague)
    /// Allows triggering validator exits from execution layer
    pub fn eip_7002_validator_exits_enabled(self: Self) bool {
        return self.hardfork.isAtLeast(.PRAGUE);
    }

    /// EIP-2929 & EIP-3651: Pre-warm addresses for top-level calls
    /// Warms tx.origin, target address, and coinbase (EIP-3651 for Shanghai+)
    pub fn pre_warm_transaction_addresses(
        self: Self,
        access_list: *AccessList,
        origin: primitives.Address,
        target: ?primitives.Address,
        coinbase: primitives.Address,
    ) !void {
        // Build array of addresses to warm
        var warm_addresses: [3]primitives.Address = undefined;
        var warm_count: usize = 0;
        
        // Always warm origin
        warm_addresses[warm_count] = origin;
        warm_count += 1;
        
        // Warm target if provided (not a create operation)
        if (target) |t| {
            warm_addresses[warm_count] = t;
            warm_count += 1;
        }
        
        // EIP-3651: Warm coinbase for Shanghai+
        if (self.hardfork.isAtLeast(.SHANGHAI)) {
            warm_addresses[warm_count] = coinbase;
            warm_count += 1;
        }
        
        // Pre-warm all addresses
        if (warm_count > 0) {
            try access_list.pre_warm_addresses(warm_addresses[0..warm_count]);
        }
    }

    /// EIP-3651: Warm COINBASE address at the start of transaction
    /// Shanghai hardfork introduced this optimization
    pub fn eip_3651_warm_coinbase_address(self: Self, access_list: *AccessList, coinbase: primitives.Address.Address) !void {
        if (!self.hardfork.isAtLeast(.SHANGHAI)) return;
        try access_list.pre_warm_addresses(&[_]primitives.Address{ coinbase });
    }

    /// EIP-3529: Reduction in refunds & gas refunds for SELFDESTRUCT
    /// London hardfork changed gas refund behavior
    /// - Sets refund counter to gas_used / 5
    /// - No longer fully refunds SELFDESTRUCT
    /// Returns the refund amount to be applied
    pub fn eip_3529_gas_refund_cap(self: Self, gas_used: u64, refund_counter: u64) u64 {
        if (!self.hardfork.isAtLeast(.LONDON)) {
            // Pre-London: refund up to half of gas used
            return @min(refund_counter, gas_used / 2);
        }
        
        // Post-London: refund up to one fifth of gas used
        return @min(refund_counter, gas_used / 5);
    }

    /// EIP-2929: Gas cost increases for state access opcodes
    /// Berlin hardfork introduced access lists and changed gas costs
    pub fn eip_2929_cold_sload_cost(self: Self) u64 {
        if (!self.hardfork.isAtLeast(.BERLIN)) {
            return 200; // Pre-Berlin: SLOAD costs 200 gas
        }
        return 2100; // Post-Berlin: cold SLOAD costs 2100 gas
    }
    
    /// EIP-2929: Warm storage access cost
    pub fn eip_2929_warm_storage_read_cost(self: Self) u64 {
        if (!self.hardfork.isAtLeast(.BERLIN)) {
            return 200; // Pre-Berlin: all reads cost 200
        }
        return 100; // Post-Berlin: warm reads cost 100 gas
    }

    /// EIP-2929: Cold account access cost
    pub fn eip_2929_cold_account_access_cost(self: Self) u64 {
        if (!self.hardfork.isAtLeast(.BERLIN)) {
            return 700; // Pre-Berlin: account access costs 700
        }
        return 2600; // Post-Berlin: cold account access costs 2600 gas
    }

    /// EIP-2929: Warm account access cost
    pub fn eip_2929_warm_account_access_cost(self: Self) u64 {
        if (!self.hardfork.isAtLeast(.BERLIN)) {
            return 700; // Pre-Berlin: all access costs 700
        }
        return 100; // Post-Berlin: warm access costs 100 gas
    }

    /// EIP-1559: Fee market change for ETH 1.0 chain
    /// London hardfork introduced base fee per gas
    pub fn eip_1559_is_enabled(self: Self) bool {
        return self.hardfork.isAtLeast(.LONDON);
    }

    /// EIP-3198: BASEFEE opcode
    /// London hardfork added BASEFEE opcode
    pub fn eip_3198_basefee_opcode_enabled(self: Self) bool {
        return self.hardfork.isAtLeast(.LONDON);
    }

    /// EIP-1153: Transient storage opcodes (TLOAD/TSTORE)
    /// Cancun hardfork added transient storage
    pub fn eip_1153_transient_storage_enabled(self: Self) bool {
        return self.hardfork.isAtLeast(.CANCUN);
    }

    /// EIP-4844: Shard Blob Transactions
    /// Cancun hardfork introduced blob transactions
    pub fn eip_4844_blob_transactions_enabled(self: Self) bool {
        return self.hardfork.isAtLeast(.CANCUN);
    }

    /// EIP-6780: SELFDESTRUCT only in same transaction
    /// Cancun hardfork restricted SELFDESTRUCT behavior
    pub fn eip_6780_selfdestruct_same_transaction_only(self: Self) bool {
        return self.hardfork.isAtLeast(.CANCUN);
    }

    /// EIP-3855: PUSH0 instruction
    /// Shanghai hardfork added PUSH0 instruction
    pub fn eip_3855_push0_enabled(self: Self) bool {
        return self.hardfork.isAtLeast(.SHANGHAI);
    }

    /// EIP-3860: Limit and meter initcode
    /// Shanghai hardfork added initcode size limit and gas metering
    pub fn eip_3860_initcode_size_limit(self: Self) u64 {
        if (!self.hardfork.isAtLeast(.SHANGHAI)) {
            return 0x6000; // Pre-Shanghai: 24KB limit (EIP-170)
        }
        return 0xC000; // Post-Shanghai: 48KB limit
    }

    /// EIP-3860: Initcode gas cost per word
    pub fn eip_3860_initcode_word_cost(self: Self) u64 {
        if (!self.hardfork.isAtLeast(.SHANGHAI)) {
            return 0; // Pre-Shanghai: no additional cost
        }
        return 2; // Post-Shanghai: 2 gas per word
    }

    /// EIP-7702: Base gas cost per authorization
    /// Prague hardfork introduced authorization lists
    pub fn eip_7702_per_auth_base_cost(self: Self) i64 {
        _ = self; // EIP-7702 gas costs are constant regardless of hardfork
        return 12500;
    }

    /// EIP-7702: Additional gas cost for empty account
    /// Prague hardfork introduced authorization lists
    pub fn eip_7702_per_empty_account_cost(self: Self) i64 {
        _ = self; // EIP-7702 gas costs are constant regardless of hardfork
        return 25000;
    }

    /// Get all active EIPs for the current hardfork
    pub fn get_active_eips(self: Self) []const u16 {
        return switch (self.hardfork) {
            .FRONTIER => &[_]u16{},
            .HOMESTEAD => &[_]u16{2,7,8},
            .DAO => &[_]u16{2,7,8}, // DAO fork had no EVM changes
            .TANGERINE_WHISTLE => &[_]u16{2,7,8,150},
            .SPURIOUS_DRAGON => &[_]u16{2,7,8,150,155,160,161},
            .BYZANTIUM => &[_]u16{2,7,8,150,155,160,161,100,140,196,197,198,211,214,649,658},
            .CONSTANTINOPLE => &[_]u16{2,7,8,150,155,160,161,100,140,196,197,198,211,214,649,658,145,1014,1052,1283},
            .PETERSBURG => &[_]u16{2,7,8,150,155,160,161,100,140,196,197,198,211,214,649,658,145,1014,1052,1283},
            .ISTANBUL => &[_]u16{2,7,8,150,155,160,161,100,140,196,197,198,211,214,649,658,145,1014,1052,1283,152,1108,1344,1884,2028,2200},
            .MUIR_GLACIER => &[_]u16{2,7,8,150,155,160,161,100,140,196,197,198,211,214,649,658,145,1014,1052,1283,152,1108,1344,1884,2028,2200},
            .BERLIN => &[_]u16{2,7,8,150,155,160,161,100,140,196,197,198,211,214,649,658,145,1014,1052,1283,152,1108,1344,1884,2028,2200,2565,2718,2929,2930},
            .LONDON => &[_]u16{2,7,8,150,155,160,161,100,140,196,197,198,211,214,649,658,145,1014,1052,1283,152,1108,1344,1884,2028,2200,2565,2718,2929,2930,1559,3198,3529,3541},
            .ARROW_GLACIER => &[_]u16{2,7,8,150,155,160,161,100,140,196,197,198,211,214,649,658,145,1014,1052,1283,152,1108,1344,1884,2028,2200,2565,2718,2929,2930,1559,3198,3529,3541,4345},
            .GRAY_GLACIER => &[_]u16{2,7,8,150,155,160,161,100,140,196,197,198,211,214,649,658,145,1014,1052,1283,152,1108,1344,1884,2028,2200,2565,2718,2929,2930,1559,3198,3529,3541,4345,5133},
            .MERGE => &[_]u16{2,7,8,150,155,160,161,100,140,196,197,198,211,214,649,658,145,1014,1052,1283,152,1108,1344,1884,2028,2200,2565,2718,2929,2930,1559,3198,3529,3541,4345,5133,3675,4399},
            .SHANGHAI => &[_]u16{2,7,8,150,155,160,161,100,140,196,197,198,211,214,649,658,145,1014,1052,1283,152,1108,1344,1884,2028,2200,2565,2718,2929,2930,1559,3198,3529,3541,4345,5133,3675,4399,3651,3855,3860,4895},
            .CANCUN => &[_]u16{2,7,8,150,155,160,161,100,140,196,197,198,211,214,649,658,145,1014,1052,1283,152,1108,1344,1884,2028,2200,2565,2718,2929,2930,1559,3198,3529,3541,4345,5133,3675,4399,3651,3855,3860,4895,1153,4788,4844,5656,6780,7516},
            .PRAGUE => &[_]u16{2,7,8,150,155,160,161,100,140,196,197,198,211,214,649,658,145,1014,1052,1283,152,1108,1344,1884,2028,2200,2565,2718,2929,2930,1559,3198,3529,3541,4345,5133,3675,4399,3651,3855,3860,4895,1153,4788,4844,5656,6780,7516,2537,2935,6110,7002,7702},
        };
    }

    /// Check if a specific EIP is active
    pub fn is_eip_active(self: Self, eip: u16) bool {
        const active_eips = self.get_active_eips();
        for (active_eips) |active_eip| {
            if (active_eip == eip) return true;
        }
        return false;
    }
    
    /// Get configuration for EVM features based on hardfork
    pub fn get_evm_config(self: Self) EvmConfig {
        return EvmConfig{
            .eip_214_enabled = self.hardfork.isAtLeast(.BYZANTIUM),
            .eip_2929_enabled = self.hardfork.isAtLeast(.BERLIN),
            .eip_3541_enabled = self.hardfork.isAtLeast(.LONDON),
            .eip_3855_enabled = self.hardfork.isAtLeast(.SHANGHAI),
            .eip_3860_enabled = self.hardfork.isAtLeast(.SHANGHAI),
            .eip_4788_enabled = self.hardfork.isAtLeast(.CANCUN),
            .eip_2935_enabled = self.hardfork.isAtLeast(.PRAGUE),
            .eip_4844_enabled = self.hardfork.isAtLeast(.CANCUN),
            .eip_5656_enabled = self.hardfork.isAtLeast(.CANCUN),
            .eip_6780_enabled = self.hardfork.isAtLeast(.CANCUN),
            .eip_7702_enabled = self.hardfork.isAtLeast(.PRAGUE),
        };
    }
    
    /// Configuration struct for EVM features
    pub const EvmConfig = struct {
        eip_214_enabled: bool,  // Static call restrictions
        eip_2929_enabled: bool, // Access list
        eip_3541_enabled: bool, // 0xEF prefix rejection
        eip_3855_enabled: bool, // PUSH0 opcode
        eip_3860_enabled: bool, // Initcode size limit
        eip_4788_enabled: bool, // Beacon roots contract
        eip_2935_enabled: bool, // Historical block hashes
        eip_4844_enabled: bool, // Blob transactions
        eip_5656_enabled: bool, // MCOPY opcode
        eip_6780_enabled: bool, // SELFDESTRUCT restrictions
        eip_7702_enabled: bool, // EOA code execution
    };
    
    /// Get maximum contract code size based on hardfork
    pub fn max_code_size(self: Self) u32 {
        // EIP-170: Contract code size limit (Spurious Dragon)
        if (!self.hardfork.isAtLeast(.SPURIOUS_DRAGON)) {
            return 0xFFFFFF; // No limit before Spurious Dragon
        }
        return 0x6000; // 24KB limit
    }
    
    /// Check if bytecode starting with 0xEF should be rejected
    pub fn should_reject_ef_bytecode(self: Self) bool {
        return self.hardfork.isAtLeast(.LONDON); // EIP-3541
    }
    
    /// Get gas cost for EXP opcode exponent byte
    pub fn exp_byte_gas_cost(self: Self) u64 {
        if (!self.hardfork.isAtLeast(.SPURIOUS_DRAGON)) {
            return 10; // Pre-EIP-160
        }
        return 50; // Post-EIP-160
    }
    
    /// Get CREATE opcode gas cost  
    pub fn create_gas_cost(_: Self) u64 {
        return 32000;
    }
    
    /// Check if PREVRANDAO should be used instead of DIFFICULTY
    pub fn use_prevrandao(self: Self) bool {
        return self.hardfork.isAtLeast(.MERGE); // EIP-4399
    }
    
    /// Get calldata gas costs
    pub fn calldata_gas_cost(self: Self, is_zero: bool) u64 {
        if (is_zero) return 4;
        
        // EIP-2028: Reduced non-zero byte cost
        if (!self.hardfork.isAtLeast(.ISTANBUL)) {
            return 68; // Pre-Istanbul
        }
        return 16; // Post-Istanbul
    }
    
    /// Check if transient storage is available
    pub fn has_transient_storage(self: Self) bool {
        return self.hardfork.isAtLeast(.CANCUN); // EIP-1153
    }
    
    /// Check if PUSH0 opcode is available
    pub fn has_push0(self: Self) bool {
        return self.hardfork.isAtLeast(.SHANGHAI); // EIP-3855
    }
    
    /// Check if BASEFEE opcode is available
    pub fn has_basefee(self: Self) bool {
        return self.hardfork.isAtLeast(.LONDON); // EIP-3198
    }
    
    /// Check if MCOPY opcode is available
    pub fn has_mcopy(self: Self) bool {
        return self.hardfork.isAtLeast(.CANCUN); // EIP-5656
    }
    
    /// Check if blob transactions are supported
    pub fn has_blob_transactions(self: Self) bool {
        return self.hardfork.isAtLeast(.CANCUN); // EIP-4844
    }
    
    /// Get SSTORE gas costs based on hardfork and state
    pub fn sstore_gas_cost(self: Self, current: u256, new: u256, original: u256) SstoreGasCost {
        _ = original; // Will be used for EIP-2200
        
        // Pre-Constantinople: Simple model
        if (self.hardfork.isBefore(.CONSTANTINOPLE)) {
            if (current == 0 and new != 0) {
                return .{ .gas = 20000, .refund = 0 };
            }
            if (current != 0 and new == 0) {
                return .{ .gas = 5000, .refund = 15000 };
            }
            return .{ .gas = 5000, .refund = 0 };
        }
        
        // TODO: Implement EIP-1283, EIP-2200, EIP-2929, EIP-3529 logic
        // For now, use simplified model
        if (current == 0 and new != 0) {
            return .{ .gas = 20000, .refund = 0 };
        }
        if (current != 0 and new == 0) {
            const refund: u64 = if (self.hardfork.isAtLeast(.LONDON)) @as(u64, 4800) else @as(u64, 15000); // EIP-3529
            return .{ .gas = 5000, .refund = refund };
        }
        return .{ .gas = 5000, .refund = 0 };
    }
    
    pub const SstoreGasCost = struct {
        gas: u64,
        refund: u64,
    };
    
    /// EIP-4788: Check if address is the beacon roots contract
    pub fn is_beacon_roots_address(self: Self, address: primitives.Address) bool {
        _ = self;
        const beacon_roots = @import("beacon_roots.zig");
        return std.mem.eql(u8, &address.bytes, &beacon_roots.BEACON_ROOTS_ADDRESS.bytes);
    }
    
    /// EIP-2935: Check if address is the historical block hashes contract
    pub fn is_historical_block_hashes_address(self: Self, address: primitives.Address) bool {
        _ = self;
        const historical_block_hashes = @import("historical_block_hashes.zig");
        return std.mem.eql(u8, &address.bytes, &historical_block_hashes.HISTORY_CONTRACT_ADDRESS.bytes);
    }
    
    /// EIP-7702: Get effective code address handling delegation
    pub fn get_effective_code_address(self: Self, account: ?@import("../storage/database_interface_account.zig").Account, address: primitives.Address) primitives.Address {
        _ = self;
        if (account) |acc| {
            if (acc.get_effective_code_address()) |delegated| {
                return delegated;
            }
        }
        return address;
    }
    
    /// EIP-3541: Should reject bytecode starting with 0xEF
    pub fn should_reject_create_with_ef_bytecode(self: Self, bytecode: []const u8) bool {
        if (!self.hardfork.isAtLeast(.LONDON)) return false;
        return bytecode.len > 0 and bytecode[0] == 0xEF;
    }
    
    /// EIP-2929: Warm contract address for execution
    pub fn warm_contract_for_execution(self: Self, access_list: anytype, address: primitives.Address) !void {
        if (!self.hardfork.isAtLeast(.BERLIN)) return;
        _ = try access_list.access_address(address);
    }
    
    /// EIP-214: Check if log emission is allowed (not in static context)
    pub fn is_log_emission_allowed(is_static: bool) bool {
        return !is_static;
    }
    
    /// EIP-6780: Handle SELFDESTRUCT based on creation in same transaction
    pub fn handle_selfdestruct(
        self: Self,
        created_in_tx: bool,
        contract_address: primitives.Address,
        recipient: primitives.Address,
        self_destruct: anytype,
        database: anytype,
        journal: anytype,
        snapshot_id: anytype,
    ) !void {
        if (!self.hardfork.isAtLeast(.CANCUN)) {
            // Pre-Cancun: always mark for full destruction
            try self_destruct.mark_for_destruction(contract_address, recipient);
            return;
        }
        
        // EIP-6780: Only destroy if created in same transaction
        if (created_in_tx) {
            // Full destruction: transfer balance and mark for deletion
            try self_destruct.mark_for_destruction(contract_address, recipient);
        } else {
            // Only transfer balance, don't destroy the contract
            const contract_account = try database.get_account(contract_address.bytes);
            if (contract_account) |account| {
                if (account.balance > 0) {
                    // Transfer balance to recipient
                    try journal.record_balance_change(snapshot_id, contract_address, account.balance);
                    try journal.record_balance_change(snapshot_id, recipient, 0);
                    
                    // Update balances
                    var sender_account = account;
                    sender_account.balance = 0;
                    try database.set_account(contract_address.bytes, sender_account);
                    
                    const Account = @import("../storage/database_interface_account.zig").Account;
                    var recipient_account = (try database.get_account(recipient.bytes)) orelse Account.zero();
                    recipient_account.balance +%= account.balance;
                    try database.set_account(recipient.bytes, recipient_account);
                }
            }
        }
    }
    
    /// Apply EIP-3529 gas refund after transaction
    pub fn apply_gas_refund(self: Self, initial_gas: u64, gas_left: u64, gas_refund_counter: u64) u64 {
        const gas_used = initial_gas - gas_left;
        const capped_refund = self.eip_3529_gas_refund_cap(gas_used, gas_refund_counter);
        
        // Apply the refund, ensuring we don't exceed the gas used
        return @min(initial_gas, gas_left + capped_refund);
    }
};

const std = @import("std");

test "eip_3529_gas_refund_cap pre-London" {
    const eips = Eips{ .hardfork = Hardfork.ISTANBUL };
    
    // Pre-London: refund up to half of gas used
    try std.testing.expectEqual(@as(u64, 50), eips.eip_3529_gas_refund_cap(100, 100)); // min(100, 100/2)
    try std.testing.expectEqual(@as(u64, 50), eips.eip_3529_gas_refund_cap(100, 60)); // min(60, 100/2)
    try std.testing.expectEqual(@as(u64, 25), eips.eip_3529_gas_refund_cap(100, 25)); // min(25, 100/2)
}

test "eip_3529_gas_refund_cap post-London" {
    const eips = Eips{ .hardfork = Hardfork.LONDON };
    
    // Post-London: refund up to one fifth of gas used
    try std.testing.expectEqual(@as(u64, 20), eips.eip_3529_gas_refund_cap(100, 100)); // min(100, 100/5)
    try std.testing.expectEqual(@as(u64, 20), eips.eip_3529_gas_refund_cap(100, 60)); // min(60, 100/5)
    try std.testing.expectEqual(@as(u64, 10), eips.eip_3529_gas_refund_cap(100, 10)); // min(10, 100/5)
}

test "eip_3529_gas_refund_cap edge cases" {
    const pre_london = Eips{ .hardfork = Hardfork.ISTANBUL };
    const post_london = Eips{ .hardfork = Hardfork.LONDON };
    
    // Zero gas used
    try std.testing.expectEqual(@as(u64, 0), pre_london.eip_3529_gas_refund_cap(0, 100));
    try std.testing.expectEqual(@as(u64, 0), post_london.eip_3529_gas_refund_cap(0, 100));
    
    // Zero refund counter
    try std.testing.expectEqual(@as(u64, 0), pre_london.eip_3529_gas_refund_cap(1000, 0));
    try std.testing.expectEqual(@as(u64, 0), post_london.eip_3529_gas_refund_cap(1000, 0));
    
    // Large gas amounts
    const large_gas = 1_000_000_000;
    try std.testing.expectEqual(@as(u64, large_gas / 2), pre_london.eip_3529_gas_refund_cap(large_gas, large_gas));
    try std.testing.expectEqual(@as(u64, large_gas / 5), post_london.eip_3529_gas_refund_cap(large_gas, large_gas));
    
    // Odd numbers (test division)
    try std.testing.expectEqual(@as(u64, 75), pre_london.eip_3529_gas_refund_cap(151, 100)); // min(100, 151/2=75)
    try std.testing.expectEqual(@as(u64, 30), post_london.eip_3529_gas_refund_cap(151, 100)); // min(100, 151/5=30)
}

test "eip_3651_warm_coinbase_address" {
    const pre_shanghai = Eips{ .hardfork = Hardfork.LONDON };
    const post_shanghai = Eips{ .hardfork = Hardfork.SHANGHAI };
    
    const allocator = std.testing.allocator;
    var access_list = AccessList.init(allocator);
    defer access_list.deinit();
    
    const coinbase = primitives.Address.from_hex("0x1234567890123456789012345678901234567890") catch unreachable;
    
    // Pre-Shanghai: should not warm coinbase (no-op)
    try pre_shanghai.eip_3651_warm_coinbase_address(&access_list, coinbase);
    try std.testing.expect(!access_list.is_address_warm(coinbase));
    
    // Post-Shanghai: should warm coinbase
    try post_shanghai.eip_3651_warm_coinbase_address(&access_list, coinbase);
    try std.testing.expect(access_list.is_address_warm(coinbase));
}

test "eip_2929_storage_costs pre-Berlin" {
    const eips = Eips{ .hardfork = Hardfork.ISTANBUL };
    
    try std.testing.expectEqual(@as(u64, 200), eips.eip_2929_cold_sload_cost());
    try std.testing.expectEqual(@as(u64, 200), eips.eip_2929_warm_storage_read_cost());
    try std.testing.expectEqual(@as(u64, 700), eips.eip_2929_cold_account_access_cost());
    try std.testing.expectEqual(@as(u64, 700), eips.eip_2929_warm_account_access_cost());
}

test "eip_2929_storage_costs post-Berlin" {
    const eips = Eips{ .hardfork = Hardfork.BERLIN };
    
    try std.testing.expectEqual(@as(u64, 2100), eips.eip_2929_cold_sload_cost());
    try std.testing.expectEqual(@as(u64, 100), eips.eip_2929_warm_storage_read_cost());
    try std.testing.expectEqual(@as(u64, 2600), eips.eip_2929_cold_account_access_cost());
    try std.testing.expectEqual(@as(u64, 100), eips.eip_2929_warm_account_access_cost());
}

test "eip_1559_fee_market" {
    const pre_london = Eips{ .hardfork = Hardfork.BERLIN };
    const post_london = Eips{ .hardfork = Hardfork.LONDON };
    
    try std.testing.expect(!pre_london.eip_1559_is_enabled());
    try std.testing.expect(post_london.eip_1559_is_enabled());
}

test "eip_3198_basefee_opcode" {
    const pre_london = Eips{ .hardfork = Hardfork.BERLIN };
    const post_london = Eips{ .hardfork = Hardfork.LONDON };
    
    try std.testing.expect(!pre_london.eip_3198_basefee_opcode_enabled());
    try std.testing.expect(post_london.eip_3198_basefee_opcode_enabled());
}

test "eip_1153_transient_storage" {
    const pre_cancun = Eips{ .hardfork = Hardfork.SHANGHAI };
    const post_cancun = Eips{ .hardfork = Hardfork.CANCUN };
    
    try std.testing.expect(!pre_cancun.eip_1153_transient_storage_enabled());
    try std.testing.expect(post_cancun.eip_1153_transient_storage_enabled());
}

test "eip_4844_blob_transactions" {
    const pre_cancun = Eips{ .hardfork = Hardfork.SHANGHAI };
    const post_cancun = Eips{ .hardfork = Hardfork.CANCUN };
    
    try std.testing.expect(!pre_cancun.eip_4844_blob_transactions_enabled());
    try std.testing.expect(post_cancun.eip_4844_blob_transactions_enabled());
}

test "eip_6780_selfdestruct_restriction" {
    const pre_cancun = Eips{ .hardfork = Hardfork.SHANGHAI };
    const post_cancun = Eips{ .hardfork = Hardfork.CANCUN };
    
    try std.testing.expect(!pre_cancun.eip_6780_selfdestruct_same_transaction_only());
    try std.testing.expect(post_cancun.eip_6780_selfdestruct_same_transaction_only());
}

test "eip_3855_push0_instruction" {
    const pre_shanghai = Eips{ .hardfork = Hardfork.LONDON };
    const post_shanghai = Eips{ .hardfork = Hardfork.SHANGHAI };
    
    try std.testing.expect(!pre_shanghai.eip_3855_push0_enabled());
    try std.testing.expect(post_shanghai.eip_3855_push0_enabled());
}

test "eip_3860_initcode_limits" {
    const pre_shanghai = Eips{ .hardfork = Hardfork.LONDON };
    const post_shanghai = Eips{ .hardfork = Hardfork.SHANGHAI };
    
    // Size limits
    try std.testing.expectEqual(@as(u64, 0x6000), pre_shanghai.eip_3860_initcode_size_limit()); // 24KB
    try std.testing.expectEqual(@as(u64, 0xC000), post_shanghai.eip_3860_initcode_size_limit()); // 48KB
    
    // Gas costs
    try std.testing.expectEqual(@as(u64, 0), pre_shanghai.eip_3860_initcode_word_cost());
    try std.testing.expectEqual(@as(u64, 2), post_shanghai.eip_3860_initcode_word_cost());
}

test "get_active_eips frontier" {
    const eips = Eips{ .hardfork = Hardfork.FRONTIER };
    const active = eips.get_active_eips();
    try std.testing.expectEqual(@as(usize, 0), active.len);
}

test "get_active_eips homestead" {
    const eips = Eips{ .hardfork = Hardfork.HOMESTEAD };
    const active = eips.get_active_eips();
    try std.testing.expectEqual(@as(usize, 3), active.len);
    
    // Should contain EIPs 2, 7, 8
    try std.testing.expect(eips.is_eip_active(2));
    try std.testing.expect(eips.is_eip_active(7));
    try std.testing.expect(eips.is_eip_active(8));
    try std.testing.expect(!eips.is_eip_active(150)); // Not in Homestead
}

test "get_active_eips berlin" {
    const eips = Eips{ .hardfork = Hardfork.BERLIN };
    
    // Berlin should include EIP-2929 and EIP-2930
    try std.testing.expect(eips.is_eip_active(2929));
    try std.testing.expect(eips.is_eip_active(2930));
    try std.testing.expect(!eips.is_eip_active(1559)); // Not yet in Berlin
}

test "get_active_eips london" {
    const eips = Eips{ .hardfork = Hardfork.LONDON };
    
    // London should include EIP-1559, EIP-3198, EIP-3529
    try std.testing.expect(eips.is_eip_active(1559));
    try std.testing.expect(eips.is_eip_active(3198));
    try std.testing.expect(eips.is_eip_active(3529));
    try std.testing.expect(!eips.is_eip_active(3651)); // Not yet in London
}

test "get_active_eips shanghai" {
    const eips = Eips{ .hardfork = Hardfork.SHANGHAI };
    
    // Shanghai should include EIP-3651, EIP-3855, EIP-3860
    try std.testing.expect(eips.is_eip_active(3651));
    try std.testing.expect(eips.is_eip_active(3855));
    try std.testing.expect(eips.is_eip_active(3860));
    try std.testing.expect(!eips.is_eip_active(1153)); // Not yet in Shanghai
}

test "get_active_eips cancun" {
    const eips = Eips{ .hardfork = Hardfork.CANCUN };
    
    // Cancun should include EIP-1153, EIP-4844, EIP-6780
    try std.testing.expect(eips.is_eip_active(1153));
    try std.testing.expect(eips.is_eip_active(4844));
    try std.testing.expect(eips.is_eip_active(6780));
    try std.testing.expect(eips.is_eip_active(7516)); // BLOBBASEFEE
    
    // Should also include all previous EIPs
    try std.testing.expect(eips.is_eip_active(2)); // From Homestead
    try std.testing.expect(eips.is_eip_active(1559)); // From London
    try std.testing.expect(eips.is_eip_active(3855)); // From Shanghai
}

test "get_active_eips prague" {
    const eips = Eips{ .hardfork = Hardfork.PRAGUE };
    
    // Prague should include new EIPs
    try std.testing.expect(eips.is_eip_active(2537)); // BLS precompiles
    try std.testing.expect(eips.is_eip_active(7702)); // EOA code execution
    try std.testing.expect(eips.is_eip_active(7002)); // Validator exits
    
    // Should also include all Cancun EIPs
    try std.testing.expect(eips.is_eip_active(1153));
    try std.testing.expect(eips.is_eip_active(4844));
    try std.testing.expect(eips.is_eip_active(6780));
}

test "is_eip_active non-existent EIP" {
    const eips = Eips{ .hardfork = Hardfork.CANCUN };
    const prague = Eips{ .hardfork = Hardfork.PRAGUE };
    
    // Test non-existent EIP numbers
    try std.testing.expect(!eips.is_eip_active(9999));
    try std.testing.expect(!eips.is_eip_active(0));
    try std.testing.expect(!eips.is_eip_active(1));
    try std.testing.expect(!prague.is_eip_active(9999));
}

test "prague eip features" {
    const pre_prague = Eips{ .hardfork = Hardfork.CANCUN };
    const prague = Eips{ .hardfork = Hardfork.PRAGUE };
    
    // Test Prague-specific EIP features
    try std.testing.expect(!pre_prague.eip_7702_eoa_code_enabled());
    try std.testing.expect(prague.eip_7702_eoa_code_enabled());
    
    try std.testing.expect(!pre_prague.eip_2537_bls_precompiles_enabled());
    try std.testing.expect(prague.eip_2537_bls_precompiles_enabled());
    
    try std.testing.expect(!pre_prague.eip_7002_validator_exits_enabled());
    try std.testing.expect(prague.eip_7002_validator_exits_enabled());
}

test "hardfork progression" {
    // Test that later hardforks include features from earlier ones
    const istanbul = Eips{ .hardfork = Hardfork.ISTANBUL };
    const berlin = Eips{ .hardfork = Hardfork.BERLIN };
    const london = Eips{ .hardfork = Hardfork.LONDON };
    const shanghai = Eips{ .hardfork = Hardfork.SHANGHAI };
    const cancun = Eips{ .hardfork = Hardfork.CANCUN };
    const prague = Eips{ .hardfork = Hardfork.PRAGUE };
    
    // EIP-2929 should be active from Berlin onwards
    try std.testing.expect(!istanbul.is_eip_active(2929));
    try std.testing.expect(berlin.is_eip_active(2929));
    try std.testing.expect(london.is_eip_active(2929));
    try std.testing.expect(shanghai.is_eip_active(2929));
    try std.testing.expect(cancun.is_eip_active(2929));
    try std.testing.expect(prague.is_eip_active(2929));
    
    // EIP-1559 should be active from London onwards
    try std.testing.expect(!berlin.is_eip_active(1559));
    try std.testing.expect(london.is_eip_active(1559));
    try std.testing.expect(shanghai.is_eip_active(1559));
    try std.testing.expect(cancun.is_eip_active(1559));
    try std.testing.expect(prague.is_eip_active(1559));
    
    // EIP-7702 should only be active from Prague onwards
    try std.testing.expect(!cancun.is_eip_active(7702));
    try std.testing.expect(prague.is_eip_active(7702));
}

test "gas_cost_consistency" {
    // Test that gas costs are consistent across different EIPs
    const pre_berlin = Eips{ .hardfork = Hardfork.ISTANBUL };
    const post_berlin = Eips{ .hardfork = Hardfork.BERLIN };
    
    // Before Berlin, cold and warm costs should be the same
    try std.testing.expectEqual(
        pre_berlin.eip_2929_cold_account_access_cost(),
        pre_berlin.eip_2929_warm_account_access_cost()
    );
    
    // After Berlin, cold costs should be higher than warm costs
    try std.testing.expect(
        post_berlin.eip_2929_cold_account_access_cost() > 
        post_berlin.eip_2929_warm_account_access_cost()
    );
    
    try std.testing.expect(
        post_berlin.eip_2929_cold_sload_cost() > 
        post_berlin.eip_2929_warm_storage_read_cost()
    );
}

test "edge_case_hardforks" {
    // Test edge case hardforks like PETERSBURG (reverts Constantinople features)
    const constantinople = Eips{ .hardfork = Hardfork.CONSTANTINOPLE };
    const petersburg = Eips{ .hardfork = Hardfork.PETERSBURG };
    
    // Both should have the same active EIPs (Petersburg == Constantinople without CREATE2)
    const const_eips = constantinople.get_active_eips();
    const petersburg_eips = petersburg.get_active_eips();
    try std.testing.expectEqualSlices(u16, const_eips, petersburg_eips);
    
    // Test glacier hardforks (only difficulty bomb delays)
    const arrow_glacier = Eips{ .hardfork = Hardfork.ARROW_GLACIER };
    const gray_glacier = Eips{ .hardfork = Hardfork.GRAY_GLACIER };
    
    // Should include difficulty bomb delay EIPs
    try std.testing.expect(arrow_glacier.is_eip_active(4345));
    try std.testing.expect(gray_glacier.is_eip_active(5133));
}

test "comprehensive_eip_coverage" {
    const cancun = Eips{ .hardfork = Hardfork.CANCUN };
    const prague = Eips{ .hardfork = Hardfork.PRAGUE };
    
    // Test a comprehensive set of important EIPs are active in Cancun
    const cancun_eips = [_]u16{
        2,    // Homestead
        150,  // Tangerine Whistle 
        155,  // Spurious Dragon
        658,  // Byzantium
        1014, // Constantinople
        2929, // Berlin
        1559, // London
        3651, // Shanghai
        1153, // Cancun
        4844, // Cancun
        6780, // Cancun
    };
    
    for (cancun_eips) |eip| {
        try std.testing.expect(cancun.is_eip_active(eip));
    }
    
    // Test Prague includes Cancun EIPs plus new ones
    for (cancun_eips) |eip| {
        try std.testing.expect(prague.is_eip_active(eip));
    }
    try std.testing.expect(prague.is_eip_active(7702)); // Prague-specific
}

test "initcode_size_boundaries" {
    const pre_shanghai = Eips{ .hardfork = Hardfork.LONDON };
    const post_shanghai = Eips{ .hardfork = Hardfork.SHANGHAI };
    
    // Test exact boundary values
    try std.testing.expectEqual(@as(u64, 24576), pre_shanghai.eip_3860_initcode_size_limit());  // 0x6000
    try std.testing.expectEqual(@as(u64, 49152), post_shanghai.eip_3860_initcode_size_limit()); // 0xC000
    
    // Test that the limit doubled
    try std.testing.expectEqual(
        pre_shanghai.eip_3860_initcode_size_limit() * 2,
        post_shanghai.eip_3860_initcode_size_limit()
    );
}

test "evm config generation" {
    const frontier = Eips{ .hardfork = Hardfork.FRONTIER };
    const berlin = Eips{ .hardfork = Hardfork.BERLIN };
    const london = Eips{ .hardfork = Hardfork.LONDON };
    const shanghai = Eips{ .hardfork = Hardfork.SHANGHAI };
    const cancun = Eips{ .hardfork = Hardfork.CANCUN };
    const prague = Eips{ .hardfork = Hardfork.PRAGUE };
    
    // Test Frontier has no EIPs enabled
    const frontier_config = frontier.get_evm_config();
    try std.testing.expect(!frontier_config.eip_2929_enabled);
    try std.testing.expect(!frontier_config.eip_3541_enabled);
    try std.testing.expect(!frontier_config.eip_3855_enabled);
    
    // Test Berlin enables EIP-2929
    const berlin_config = berlin.get_evm_config();
    try std.testing.expect(berlin_config.eip_2929_enabled);
    try std.testing.expect(!berlin_config.eip_3541_enabled);
    
    // Test London adds EIP-3541
    const london_config = london.get_evm_config();
    try std.testing.expect(london_config.eip_2929_enabled);
    try std.testing.expect(london_config.eip_3541_enabled);
    try std.testing.expect(!london_config.eip_3855_enabled);
    
    // Test Shanghai adds PUSH0
    const shanghai_config = shanghai.get_evm_config();
    try std.testing.expect(shanghai_config.eip_3855_enabled);
    try std.testing.expect(shanghai_config.eip_3860_enabled);
    
    // Test Cancun adds multiple features
    const cancun_config = cancun.get_evm_config();
    try std.testing.expect(cancun_config.eip_4844_enabled);
    try std.testing.expect(cancun_config.eip_5656_enabled);
    try std.testing.expect(cancun_config.eip_6780_enabled);
    try std.testing.expect(!cancun_config.eip_7702_enabled);
    
    // Test Prague adds EIP-7702
    const prague_config = prague.get_evm_config();
    try std.testing.expect(prague_config.eip_7702_enabled);
    try std.testing.expect(prague_config.eip_4844_enabled); // Includes all Cancun features
}

test "specific eip helper functions" {
    const frontier = Eips{ .hardfork = Hardfork.FRONTIER };
    const spurious = Eips{ .hardfork = Hardfork.SPURIOUS_DRAGON };
    const london = Eips{ .hardfork = Hardfork.LONDON };
    const shanghai = Eips{ .hardfork = Hardfork.SHANGHAI };
    const cancun = Eips{ .hardfork = Hardfork.CANCUN };
    const merge = Eips{ .hardfork = Hardfork.MERGE };
    
    // Test max code size
    try std.testing.expectEqual(@as(u32, 0xFFFFFF), frontier.max_code_size());
    try std.testing.expectEqual(@as(u32, 0x6000), spurious.max_code_size());
    
    // Test 0xEF bytecode rejection
    try std.testing.expect(!frontier.should_reject_ef_bytecode());
    try std.testing.expect(london.should_reject_ef_bytecode());
    
    // Test EXP gas cost
    try std.testing.expectEqual(@as(u64, 10), frontier.exp_byte_gas_cost());
    try std.testing.expectEqual(@as(u64, 50), spurious.exp_byte_gas_cost());
    
    // Test PREVRANDAO vs DIFFICULTY
    try std.testing.expect(!london.use_prevrandao());
    try std.testing.expect(merge.use_prevrandao());
    
    // Test opcode availability
    try std.testing.expect(!london.has_push0());
    try std.testing.expect(shanghai.has_push0());
    
    try std.testing.expect(!shanghai.has_mcopy());
    try std.testing.expect(cancun.has_mcopy());
    
    try std.testing.expect(!frontier.has_basefee());
    try std.testing.expect(london.has_basefee());
    
    try std.testing.expect(!shanghai.has_transient_storage());
    try std.testing.expect(cancun.has_transient_storage());
    
    try std.testing.expect(!shanghai.has_blob_transactions());
    try std.testing.expect(cancun.has_blob_transactions());
}

test "calldata gas costs" {
    const homestead = Eips{ .hardfork = Hardfork.HOMESTEAD };
    const istanbul = Eips{ .hardfork = Hardfork.ISTANBUL };
    
    // Zero bytes always cost 4 gas
    try std.testing.expectEqual(@as(u64, 4), homestead.calldata_gas_cost(true));
    try std.testing.expectEqual(@as(u64, 4), istanbul.calldata_gas_cost(true));
    
    // Non-zero bytes: 68 pre-Istanbul, 16 post-Istanbul
    try std.testing.expectEqual(@as(u64, 68), homestead.calldata_gas_cost(false));
    try std.testing.expectEqual(@as(u64, 16), istanbul.calldata_gas_cost(false));
}

test "sstore gas costs" {
    const frontier = Eips{ .hardfork = Hardfork.FRONTIER };
    const london = Eips{ .hardfork = Hardfork.LONDON };
    
    // Set from zero to non-zero
    var cost = frontier.sstore_gas_cost(0, 1, 0);
    try std.testing.expectEqual(@as(u64, 20000), cost.gas);
    try std.testing.expectEqual(@as(u64, 0), cost.refund);
    
    // Clear from non-zero to zero (refund differs by hardfork)
    cost = frontier.sstore_gas_cost(1, 0, 1);
    try std.testing.expectEqual(@as(u64, 5000), cost.gas);
    try std.testing.expectEqual(@as(u64, 15000), cost.refund);
    
    // London reduces refund (EIP-3529)
    cost = london.sstore_gas_cost(1, 0, 1);
    try std.testing.expectEqual(@as(u64, 5000), cost.gas);
    try std.testing.expectEqual(@as(u64, 4800), cost.refund);
    
    // No-op (same value)
    cost = frontier.sstore_gas_cost(1, 1, 1);
    try std.testing.expectEqual(@as(u64, 5000), cost.gas);
    try std.testing.expectEqual(@as(u64, 0), cost.refund);
}
