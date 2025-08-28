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


    const std = @import("std");

    test "hardfork enum ordering" {
        try std.testing.expect(@intFromEnum(Hardfork.FRONTIER) < @intFromEnum(Hardfork.HOMESTEAD));
        try std.testing.expect(@intFromEnum(Hardfork.HOMESTEAD) < @intFromEnum(Hardfork.BYZANTIUM));
        try std.testing.expect(@intFromEnum(Hardfork.BYZANTIUM) < @intFromEnum(Hardfork.CANCUN));
    }

    test "hardfork default is cancun" {
        try std.testing.expectEqual(Hardfork.CANCUN, Hardfork.DEFAULT);
    }

    test "hardfork toInt conversion" {
        try std.testing.expect(Hardfork.FRONTIER.toInt() == 0);
        try std.testing.expect(Hardfork.HOMESTEAD.toInt() == 1);
        try std.testing.expect(Hardfork.CANCUN.toInt() > Hardfork.FRONTIER.toInt());
    }

    test "hardfork isAtLeast comparison" {
        try std.testing.expect(Hardfork.CANCUN.isAtLeast(Hardfork.FRONTIER));
        try std.testing.expect(Hardfork.CANCUN.isAtLeast(Hardfork.CANCUN));
        try std.testing.expect(!Hardfork.FRONTIER.isAtLeast(Hardfork.CANCUN));

        try std.testing.expect(Hardfork.BERLIN.isAtLeast(Hardfork.BERLIN));
        try std.testing.expect(Hardfork.LONDON.isAtLeast(Hardfork.BERLIN));
        try std.testing.expect(!Hardfork.HOMESTEAD.isAtLeast(Hardfork.BERLIN));
    }

    test "hardfork isBefore comparison" {
        try std.testing.expect(Hardfork.FRONTIER.isBefore(Hardfork.CANCUN));
        try std.testing.expect(!Hardfork.CANCUN.isBefore(Hardfork.FRONTIER));
        try std.testing.expect(!Hardfork.CANCUN.isBefore(Hardfork.CANCUN));

        try std.testing.expect(Hardfork.HOMESTEAD.isBefore(Hardfork.BERLIN));
        try std.testing.expect(!Hardfork.BERLIN.isBefore(Hardfork.HOMESTEAD));
    }

    test "hardfork version comparisons edge cases" {
        // Test adjacent forks
        try std.testing.expect(Hardfork.BERLIN.isBefore(Hardfork.LONDON));
        try std.testing.expect(Hardfork.LONDON.isAtLeast(Hardfork.BERLIN));

        // Test same fork
        try std.testing.expect(!Hardfork.ISTANBUL.isBefore(Hardfork.ISTANBUL));
        try std.testing.expect(Hardfork.ISTANBUL.isAtLeast(Hardfork.ISTANBUL));
    }

    test "hardfork major milestone checks" {
        // Pre-Byzantium (no REVERT opcode)
        try std.testing.expect(Hardfork.HOMESTEAD.isBefore(Hardfork.BYZANTIUM));
        try std.testing.expect(Hardfork.TANGERINE_WHISTLE.isBefore(Hardfork.BYZANTIUM));

        // Post-Berlin (warm/cold access)
        try std.testing.expect(Hardfork.BERLIN.isAtLeast(Hardfork.BERLIN));
        try std.testing.expect(Hardfork.LONDON.isAtLeast(Hardfork.BERLIN));
        try std.testing.expect(Hardfork.CANCUN.isAtLeast(Hardfork.BERLIN));

        // Shanghai introduces PUSH0
        try std.testing.expect(Hardfork.SHANGHAI.isAtLeast(Hardfork.SHANGHAI));
        try std.testing.expect(Hardfork.CANCUN.isAtLeast(Hardfork.SHANGHAI));

        // Cancun introduces transient storage
        try std.testing.expect(Hardfork.CANCUN.isAtLeast(Hardfork.CANCUN));
    }
};
