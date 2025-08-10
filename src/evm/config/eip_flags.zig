const std = @import("std");
const Hardfork = @import("../hardforks/hardfork.zig").Hardfork;

/// EIP (Ethereum Improvement Proposal) feature flags
///
/// This struct contains boolean flags for each EIP that affects EVM behavior.
/// Flags are derived from the hardfork configuration with optional overrides
/// for L2s, custom chains, and testing scenarios.
pub const EipFlags = struct {
    // Core protocol changes
    eip150_gas_costs: bool = false, // Tangerine Whistle gas cost changes
    eip155_chain_id: bool = false, // Spurious Dragon replay attack protection
    eip161_state_clear: bool = false, // Spurious Dragon state trie clearing
    eip170_code_size_limit: bool = false, // Spurious Dragon 24KB contract size limit

    // New opcodes - Byzantium
    eip211_returndatasize: bool = false, // RETURNDATASIZE opcode
    eip211_returndatacopy: bool = false, // RETURNDATACOPY opcode
    eip214_staticcall: bool = false, // STATICCALL opcode

    // New opcodes - Constantinople
    eip1014_create2: bool = false, // CREATE2 opcode
    eip1052_extcodehash: bool = false, // EXTCODEHASH opcode

    // Storage and gas changes
    eip1283_sstore_gas: bool = false, // Net SSTORE gas metering (removed in Petersburg)
    eip2200_sstore_gas: bool = false, // Istanbul - Rebalanced SSTORE
    eip2929_gas_costs: bool = false, // Berlin - Cold/warm access costs
    eip3529_selfdestruct: bool = false, // London - SELFDESTRUCT changes

    // Istanbul opcodes
    eip1344_chainid: bool = false, // CHAINID opcode

    // Berlin features
    eip2930_access_lists: bool = false, // Access list transactions

    // London features
    eip1559_base_fee: bool = false, // Dynamic fee transactions
    eip3198_basefee: bool = false, // BASEFEE opcode

    // Shanghai features
    eip3855_push0: bool = false, // PUSH0 opcode

    // Cancun features
    eip1153_transient_storage: bool = false, // TLOAD/TSTORE opcodes
    eip4844_blob_tx: bool = false, // Blob transactions
    eip5656_mcopy: bool = false, // MCOPY opcode
    eip6780_selfdestruct_only_same_tx: bool = false, // SELFDESTRUCT limitation
    eip7516_blobbasefee: bool = false, // BLOBBASEFEE opcode

    // Additional protocol features
    eip2315_simple_subroutines: bool = false, // Subroutines (never activated)
    eip3540_eof: bool = false, // EVM Object Format (future)
    eip3651_warm_coinbase: bool = false, // Shanghai - Warm COINBASE
    eip3860_initcode_limit: bool = false, // Shanghai - Limit initcode size
    eip4895_beacon_withdrawals: bool = false, // Shanghai - Beacon chain withdrawals
    eip4788_beacon_root: bool = false, // Cancun - Beacon block root
    eip4844_shard_blob_tx: bool = false, // Cancun - Shard blob transactions
    eip7702_eoa_delegation: bool = false, // Prague - EOA delegation

    /// Check if a specific EIP is enabled
    pub fn isEnabled(self: EipFlags, eip_number: u16) bool {
        return switch (eip_number) {
            150 => self.eip150_gas_costs,
            155 => self.eip155_chain_id,
            161 => self.eip161_state_clear,
            170 => self.eip170_code_size_limit,
            211 => self.eip211_returndatasize and self.eip211_returndatacopy,
            214 => self.eip214_staticcall,
            1014 => self.eip1014_create2,
            1052 => self.eip1052_extcodehash,
            1153 => self.eip1153_transient_storage,
            1283 => self.eip1283_sstore_gas,
            1344 => self.eip1344_chainid,
            1559 => self.eip1559_base_fee,
            2200 => self.eip2200_sstore_gas,
            2315 => self.eip2315_simple_subroutines,
            2929 => self.eip2929_gas_costs,
            2930 => self.eip2930_access_lists,
            3198 => self.eip3198_basefee,
            3529 => self.eip3529_selfdestruct,
            3540 => self.eip3540_eof,
            3651 => self.eip3651_warm_coinbase,
            3855 => self.eip3855_push0,
            3860 => self.eip3860_initcode_limit,
            4788 => self.eip4788_beacon_root,
            4844 => self.eip4844_blob_tx,
            4895 => self.eip4895_beacon_withdrawals,
            5656 => self.eip5656_mcopy,
            6780 => self.eip6780_selfdestruct_only_same_tx,
            7516 => self.eip7516_blobbasefee,
            7702 => self.eip7702_eoa_delegation,
            else => false,
        };
    }

    /// Create a debug string showing all enabled EIPs
    pub fn debugString(self: EipFlags, allocator: std.mem.Allocator) ![]u8 {
        var buf = std.ArrayList(u8).init(allocator);
        errdefer buf.deinit();

        try buf.appendSlice("Enabled EIPs: ");

        var first = true;
        inline for (@typeInfo(EipFlags).Struct.fields) |field| {
            if (@field(self, field.name) and field.type == bool) {
                if (!first) try buf.appendSlice(", ");
                first = false;

                // Extract EIP number from field name
                const eip_start = std.mem.indexOf(u8, field.name, "eip") orelse continue;
                const num_start = eip_start + 3;
                const num_end = std.mem.indexOfScalar(u8, field.name[num_start..], '_') orelse field.name.len - num_start;
                try buf.appendSlice(field.name[num_start .. num_start + num_end]);
            }
        }

        return buf.toOwnedSlice();
    }
};

/// Derive EIP flags from hardfork progression
pub fn deriveEipFlagsFromHardfork(hardfork: Hardfork) EipFlags {
    var flags = EipFlags{};

    const hardfork_num = @intFromEnum(hardfork);

    // Homestead
    if (hardfork_num >= @intFromEnum(Hardfork.HOMESTEAD)) {
        // DELEGATECALL was added but doesn't have an EIP number
    }

    // Tangerine Whistle (EIP-150)
    if (hardfork_num >= @intFromEnum(Hardfork.TANGERINE_WHISTLE)) {
        flags.eip150_gas_costs = true;
    }

    // Spurious Dragon (EIP-155, 161, 170)
    if (hardfork_num >= @intFromEnum(Hardfork.SPURIOUS_DRAGON)) {
        flags.eip155_chain_id = true;
        flags.eip161_state_clear = true;
        flags.eip170_code_size_limit = true;
    }

    // Byzantium (EIP-211, 214)
    if (hardfork_num >= @intFromEnum(Hardfork.BYZANTIUM)) {
        flags.eip211_returndatasize = true;
        flags.eip211_returndatacopy = true;
        flags.eip214_staticcall = true;
    }

    // Constantinople (EIP-1014, 1052, 1283)
    if (hardfork_num >= @intFromEnum(Hardfork.CONSTANTINOPLE)) {
        flags.eip1014_create2 = true;
        flags.eip1052_extcodehash = true;
        flags.eip1283_sstore_gas = true; // Will be removed in Petersburg
    }

    // Petersburg (removes EIP-1283)
    if (hardfork_num >= @intFromEnum(Hardfork.PETERSBURG)) {
        flags.eip1283_sstore_gas = false; // Removed due to reentrancy issues
    }

    // Istanbul (EIP-1344, 2200)
    if (hardfork_num >= @intFromEnum(Hardfork.ISTANBUL)) {
        flags.eip1344_chainid = true;
        flags.eip2200_sstore_gas = true; // Replacement for EIP-1283
    }

    // Berlin (EIP-2929, 2930)
    if (hardfork_num >= @intFromEnum(Hardfork.BERLIN)) {
        flags.eip2929_gas_costs = true;
        flags.eip2930_access_lists = true;
    }

    // London (EIP-1559, 3198, 3529)
    if (hardfork_num >= @intFromEnum(Hardfork.LONDON)) {
        flags.eip1559_base_fee = true;
        flags.eip3198_basefee = true;
        flags.eip3529_selfdestruct = true;
    }

    // Shanghai (EIP-3651, 3855, 3860, 4895)
    if (hardfork_num >= @intFromEnum(Hardfork.SHANGHAI)) {
        flags.eip3651_warm_coinbase = true;
        flags.eip3855_push0 = true;
        flags.eip3860_initcode_limit = true;
        flags.eip4895_beacon_withdrawals = true;
    }

    // Cancun (EIP-1153, 4788, 4844, 5656, 6780, 7516)
    if (hardfork_num >= @intFromEnum(Hardfork.CANCUN)) {
        flags.eip1153_transient_storage = true;
        flags.eip4788_beacon_root = true;
        flags.eip4844_blob_tx = true;
        flags.eip4844_shard_blob_tx = true;
        flags.eip5656_mcopy = true;
        flags.eip6780_selfdestruct_only_same_tx = true;
        flags.eip7516_blobbasefee = true;
    }

    // Prague (future)
    if (hardfork_num >= @intFromEnum(Hardfork.PRAGUE)) {
        flags.eip7702_eoa_delegation = true;
    }

    return flags;
}

test "EIP flag derivation" {
    const testing = std.testing;

    // Test Frontier - no EIPs
    {
        const flags = deriveEipFlagsFromHardfork(.FRONTIER);
        try testing.expect(!flags.eip150_gas_costs);
        try testing.expect(!flags.eip155_chain_id);
        try testing.expect(!flags.eip1559_base_fee);
    }

    // Test Tangerine Whistle
    {
        const flags = deriveEipFlagsFromHardfork(.TANGERINE_WHISTLE);
        try testing.expect(flags.eip150_gas_costs);
        try testing.expect(!flags.eip155_chain_id);
    }

    // Test Constantinople vs Petersburg (EIP-1283)
    {
        const const_flags = deriveEipFlagsFromHardfork(.CONSTANTINOPLE);
        try testing.expect(const_flags.eip1283_sstore_gas);

        const peter_flags = deriveEipFlagsFromHardfork(.PETERSBURG);
        try testing.expect(!peter_flags.eip1283_sstore_gas);
        try testing.expect(!peter_flags.eip2200_sstore_gas); // Not yet
    }

    // Test Istanbul
    {
        const flags = deriveEipFlagsFromHardfork(.ISTANBUL);
        try testing.expect(flags.eip1344_chainid);
        try testing.expect(flags.eip2200_sstore_gas);
        try testing.expect(!flags.eip1283_sstore_gas); // Still removed
    }

    // Test Cancun - latest features
    {
        const flags = deriveEipFlagsFromHardfork(.CANCUN);
        try testing.expect(flags.eip150_gas_costs);
        try testing.expect(flags.eip155_chain_id);
        try testing.expect(flags.eip1559_base_fee);
        try testing.expect(flags.eip3855_push0);
        try testing.expect(flags.eip4844_blob_tx);
        try testing.expect(flags.eip5656_mcopy);
        try testing.expect(flags.eip6780_selfdestruct_only_same_tx);
    }
}

test "EIP isEnabled method" {
    const testing = std.testing;

    const flags = deriveEipFlagsFromHardfork(.CANCUN);

    try testing.expect(flags.isEnabled(150)); // Tangerine Whistle
    try testing.expect(flags.isEnabled(155)); // Spurious Dragon
    try testing.expect(flags.isEnabled(1559)); // London
    try testing.expect(flags.isEnabled(3855)); // Shanghai
    try testing.expect(flags.isEnabled(5656)); // Cancun

    try testing.expect(!flags.isEnabled(9999)); // Unknown EIP
}

test "EIP debug string" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const flags = deriveEipFlagsFromHardfork(.LONDON);
    const debug_str = try flags.debugString(allocator);
    defer allocator.free(debug_str);

    // Should contain at least some EIPs
    try testing.expect(debug_str.len > 20);
    try testing.expect(std.mem.indexOf(u8, debug_str, "150") != null);
    try testing.expect(std.mem.indexOf(u8, debug_str, "1559") != null);
}
