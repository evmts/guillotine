const primitives = @import("primitives");
const AccessList = @import("access_list.zig").AccessList;
const Hardfork = @import("hardfork.zig").Hardfork;

// EIPs is a comptime known configuration of Eip and hardfork specific behavior
pub const Eips = struct {
    const Self = @This();

    hardfork: Hardfork,

    /// EIP-3651: Warm COINBASE address at the start of transaction
    /// Shanghai hardfork introduced this optimization
    pub fn eip_3651_warm_coinbase_address(self: Self, access_list: *AccessList, coinbase: primitives.Address.Address) !void {
        if (!self.hardfork.isAtLeast(.SHANGHAI)) return;
        try access_list.pre_warm_addresses(.{coinbase});
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

    /// Get all active EIPs for the current hardfork
    pub fn get_active_eips(self: Self) []const u16 {
        return switch (self.hardfork) {
            .FRONTIER => &[_]u16{},
            .HOMESTEAD => &[_]u16{2,7,8},
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
            .SHANGHAI => &[_]u16{2,7,8,150,155,160,161,100,140,196,197,198,211,214,649,658,145,1014,1052,1283,152,1108,1344,1884,2028,2200,2565,2718,2929,2930,1559,3198,3529,3541,4345,5133,3675,4399,3651,3855,3860},
            .CANCUN => &[_]u16{2,7,8,150,155,160,161,100,140,196,197,198,211,214,649,658,145,1014,1052,1283,152,1108,1344,1884,2028,2200,2565,2718,2929,2930,1559,3198,3529,3541,4345,5133,3675,4399,3651,3855,3860,1153,4788,4844,5656,6780},
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
    var access_list = AccessList.init(allocator, .{});
    defer access_list.deinit();
    
    const coinbase = primitives.Address.Address.fromHex("0x1234567890123456789012345678901234567890") catch unreachable;
    
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
    
    // Should also include all previous EIPs
    try std.testing.expect(eips.is_eip_active(2)); // From Homestead
    try std.testing.expect(eips.is_eip_active(1559)); // From London
    try std.testing.expect(eips.is_eip_active(3855)); // From Shanghai
}

test "is_eip_active non-existent EIP" {
    const eips = Eips{ .hardfork = Hardfork.CANCUN };
    
    // Test non-existent EIP numbers
    try std.testing.expect(!eips.is_eip_active(9999));
    try std.testing.expect(!eips.is_eip_active(0));
    try std.testing.expect(!eips.is_eip_active(1));
}

test "hardfork progression" {
    // Test that later hardforks include features from earlier ones
    const istanbul = Eips{ .hardfork = Hardfork.ISTANBUL };
    const berlin = Eips{ .hardfork = Hardfork.BERLIN };
    const london = Eips{ .hardfork = Hardfork.LONDON };
    const shanghai = Eips{ .hardfork = Hardfork.SHANGHAI };
    const cancun = Eips{ .hardfork = Hardfork.CANCUN };
    
    // EIP-2929 should be active from Berlin onwards
    try std.testing.expect(!istanbul.is_eip_active(2929));
    try std.testing.expect(berlin.is_eip_active(2929));
    try std.testing.expect(london.is_eip_active(2929));
    try std.testing.expect(shanghai.is_eip_active(2929));
    try std.testing.expect(cancun.is_eip_active(2929));
    
    // EIP-1559 should be active from London onwards
    try std.testing.expect(!berlin.is_eip_active(1559));
    try std.testing.expect(london.is_eip_active(1559));
    try std.testing.expect(shanghai.is_eip_active(1559));
    try std.testing.expect(cancun.is_eip_active(1559));
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
    
    // Test a comprehensive set of important EIPs are active in Cancun
    const important_eips = [_]u16{
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
    
    for (important_eips) |eip| {
        try std.testing.expect(cancun.is_eip_active(eip));
    }
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
