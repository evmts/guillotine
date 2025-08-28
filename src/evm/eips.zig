const primitives = @import("primitives");
const AccessList = @import("access_list.zig").AccessList;
const Hardfork = @import("hardfork.zig").Hardfork;

// EIPs is a comptime known configuration of Eip and hardfork specific behavior
pub const Eips = struct {
    const Self = @This();

    hardfork: Hardfork,

    // TODO this can throw an allocator error. But I don't think we should be allocating here. Instead we should store in preallocated memory
    /// EIP-3651: Warm COINBASE address at the start of transaction
    /// Shanghai hardfork introduced this optimization
    inline fn eip_3651_warm_coinbase_address(self: Self, access_list: AccessList, coinbase: primitives.Address) void {
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
