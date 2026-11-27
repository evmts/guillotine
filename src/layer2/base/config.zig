//! Base chain configuration.
//!
//! Base is an OP Stack chain: it runs OP Stack execution rules selected by
//! `OpSpecId`, with Base's own chain IDs, hardfork timestamps, and EIP-1559 parameters.
//! System contracts are the standard OP Stack predeploys.

const std = @import("std");
const primitives = @import("voltaire");
const Address = primitives.Address;
const OpSpecId = @import("../optimism/spec.zig").OpSpecId;
const constants = @import("../optimism/constants.zig");
const hardforks = @import("hardforks.zig");
const eip1559 = @import("../optimism/eip1559.zig");

pub const Schedule = hardforks.Schedule;
pub const ScheduleError = hardforks.ScheduleError;

/// Base network.
pub const BaseChain = enum {
    mainnet,
    sepolia,

    pub fn chainId(self: BaseChain) u64 {
        return switch (self) {
            .mainnet => 8453,
            .sepolia => 84532,
        };
    }

    pub fn l1ChainId(self: BaseChain) u64 {
        return switch (self) {
            .mainnet => 1,
            .sepolia => 11_155_111,
        };
    }

    pub fn schedule(self: BaseChain) Schedule {
        return switch (self) {
            .mainnet => hardforks.MAINNET,
            .sepolia => hardforks.SEPOLIA,
        };
    }

    /// EIP-1559 elasticity multiplier.
    pub fn eip1559Elasticity(self: BaseChain) u64 {
        return switch (self) {
            .mainnet => 6,
            .sepolia => 10,
        };
    }

    /// EIP-1559 base fee max change denominator, pre-Canyon.
    pub fn eip1559Denominator(_: BaseChain) u64 {
        return 50;
    }

    /// EIP-1559 base fee max change denominator, Canyon and later.
    pub fn eip1559DenominatorCanyon(_: BaseChain) u64 {
        return 250;
    }

    /// Pre-Holocene EIP-1559 constants (superchain-registry base.toml @ 720185c3).
    pub fn eip1559Constants(self: BaseChain) eip1559.Constants {
        return .{
            .elasticity = self.eip1559Elasticity(),
            .denominator = self.eip1559Denominator(),
            .denominator_canyon = self.eip1559DenominatorCanyon(),
        };
    }

    /// Base fee of the block at `child_timestamp` whose parent block was at
    /// `parent_timestamp` (op-geth `CalcBaseFee`; Holocene/Jovian read the parent extraData).
    pub fn nextBaseFee(self: BaseChain, parent_timestamp: u64, child_timestamp: u64, parent: eip1559.Parent) !u256 {
        if (child_timestamp <= parent_timestamp) return error.TimestampNotIncreasing;
        const schedule_ = self.schedule();
        return eip1559.nextBaseFee(
            self.eip1559Constants(),
            try schedule_.specAt(parent_timestamp),
            try schedule_.specAt(child_timestamp),
            parent,
        );
    }

    pub fn name(self: BaseChain) []const u8 {
        return switch (self) {
            .mainnet => "base",
            .sepolia => "base-sepolia",
        };
    }

    pub fn fromChainId(chain_id: u64) ?BaseChain {
        return switch (chain_id) {
            8453 => .mainnet,
            84532 => .sepolia,
            else => null,
        };
    }
};

/// Base system contract addresses (OP Stack predeploys).
pub const SystemContracts = struct {
    pub const L2_CROSS_DOMAIN_MESSENGER: Address = constants.L2_CROSS_DOMAIN_MESSENGER_ADDRESS;
    pub const GAS_PRICE_ORACLE: Address = constants.GAS_PRICE_ORACLE_ADDRESS;
    pub const SEQUENCER_FEE_VAULT: Address = constants.SEQUENCER_FEE_VAULT_ADDRESS;
    pub const L1_BLOCK: Address = constants.L1_BLOCK_ADDRESS;
    pub const BASE_FEE_VAULT: Address = constants.BASE_FEE_VAULT_ADDRESS;
    pub const L1_FEE_VAULT: Address = constants.L1_FEE_VAULT_ADDRESS;
    pub const OPERATOR_FEE_VAULT: Address = constants.OPERATOR_FEE_VAULT_ADDRESS;
};

/// Comptime-friendly Base configuration: a chain plus the OP Stack spec to execute.
pub const BaseConfig = struct {
    chain: BaseChain,
    spec: OpSpecId,

    /// Base Mainnet with the latest modeled spec.
    pub const MAINNET = BaseConfig{ .chain = .mainnet, .spec = .JOVIAN };
    /// Base Sepolia with the latest modeled spec.
    pub const SEPOLIA = BaseConfig{ .chain = .sepolia, .spec = .JOVIAN };
    pub const DEFAULT = MAINNET;

    /// Configuration for the block at `timestamp` on `chain`.
    pub fn atTimestamp(chain: BaseChain, timestamp: u64) ScheduleError!BaseConfig {
        return .{ .chain = chain, .spec = try chain.schedule().specAt(timestamp) };
    }

    pub fn chainId(self: BaseConfig) u64 {
        return self.chain.chainId();
    }
};

const testing = std.testing;

test "Base chain IDs" {
    try testing.expectEqual(@as(u64, 8453), BaseChain.mainnet.chainId());
    try testing.expectEqual(@as(u64, 84532), BaseChain.sepolia.chainId());
    try testing.expectEqual(@as(u64, 1), BaseChain.mainnet.l1ChainId());
    try testing.expectEqual(@as(u64, 11_155_111), BaseChain.sepolia.l1ChainId());
    try testing.expectEqual(BaseChain.mainnet, BaseChain.fromChainId(8453).?);
    try testing.expectEqual(BaseChain.sepolia, BaseChain.fromChainId(84532).?);
    try testing.expect(BaseChain.fromChainId(10) == null);
}

test "Base EIP-1559 parameters" {
    try testing.expectEqual(@as(u64, 6), BaseChain.mainnet.eip1559Elasticity());
    try testing.expectEqual(@as(u64, 10), BaseChain.sepolia.eip1559Elasticity());
    try testing.expectEqual(@as(u64, 50), BaseChain.mainnet.eip1559Denominator());
    try testing.expectEqual(@as(u64, 250), BaseChain.mainnet.eip1559DenominatorCanyon());
}

test "Base next base fee: Canyon constants differ between mainnet and Sepolia" {
    // 30M gas limit, 10M used, 1 gwei parent. Mainnet elasticity 6: target 5M,
    // 1e9 * 5M / 5M / 250 = 4,000,000. Sepolia elasticity 10: target 3M,
    // 1e9 * 7M / 3M = 2,333,333,333; / 250 = 9,333,333.
    const parent = eip1559.Parent{ .gas_limit = 30_000_000, .gas_used = 10_000_000, .base_fee = 1_000_000_000 };
    const mainnet = hardforks.MAINNET.ecotone;
    try testing.expectEqual(@as(u256, 1_004_000_000), try BaseChain.mainnet.nextBaseFee(mainnet, mainnet + 2, parent));
    const sepolia = hardforks.SEPOLIA.ecotone;
    try testing.expectEqual(@as(u256, 1_009_333_333), try BaseChain.sepolia.nextBaseFee(sepolia, sepolia + 2, parent));
    // Pre-Canyon child: denominator 50 (1e9 * 5M / 5M / 50 = 20,000,000).
    const regolith = hardforks.MAINNET.regolith;
    try testing.expectEqual(@as(u256, 1_020_000_000), try BaseChain.mainnet.nextBaseFee(regolith, regolith + 2, parent));
    // The first Canyon child of a Regolith parent already uses the Canyon denominator.
    try testing.expectEqual(@as(u256, 1_004_000_000), try BaseChain.mainnet.nextBaseFee(hardforks.MAINNET.canyon - 2, hardforks.MAINNET.canyon, parent));
}

test "Base next base fee: Holocene and Jovian read the parent extraData" {
    for ([_]BaseChain{ .mainnet, .sepolia }) |chain| {
        const s = chain.schedule();
        // Holocene parent: denominator 250, elasticity 2 from extraData, not the chain constants.
        const holocene_extra = [_]u8{ 0, 0, 0, 0, 250, 0, 0, 0, 2 };
        const holocene = eip1559.Parent{ .gas_limit = 30_000_000, .gas_used = 25_000_000, .base_fee = 1_000_000, .extra_data = &holocene_extra };
        // target 15M; 1e6 * 10M / 15M = 666,666; / 250 = 2,666.
        try testing.expectEqual(@as(u256, 1_002_666), try chain.nextBaseFee(s.holocene, s.holocene + 2, holocene));
        try testing.expectError(error.InvalidExtraDataLength, chain.nextBaseFee(s.jovian, s.jovian + 2, holocene));
        // Jovian parent: DA footprint (blobGasUsed) above gasUsed drives the change, then the
        // 0.05 gwei minimum base fee applies.
        const jovian_extra = [_]u8{ 1, 0, 0, 0, 250, 0, 0, 0, 2, 0, 0, 0, 0, 0x02, 0xfa, 0xf0, 0x80 };
        const jovian = eip1559.Parent{ .gas_limit = 30_000_000, .gas_used = 1_000_000, .blob_gas_used = 25_000_000, .base_fee = 1_000_000, .extra_data = &jovian_extra };
        try testing.expectEqual(@as(u256, 50_000_000), try chain.nextBaseFee(s.jovian, s.jovian + 2, jovian));
        var above_min = jovian;
        above_min.base_fee = 100_000_000;
        // 1e8 * 10M / 15M = 66,666,666; / 250 = 266,666.
        try testing.expectEqual(@as(u256, 100_266_666), try chain.nextBaseFee(s.jovian, s.jovian + 2, above_min));
        try testing.expectError(error.TimestampNotIncreasing, chain.nextBaseFee(s.jovian, s.jovian, jovian));
        try testing.expectError(error.UnmodeledBaseUpgrade, chain.nextBaseFee(s.azul.? - 2, s.azul.?, jovian));
    }
}

test "Base system contracts" {
    try testing.expectEqual(@as(u256, 0x4200000000000000000000000000000000000007), SystemContracts.L2_CROSS_DOMAIN_MESSENGER.toU256());
    try testing.expectEqual(@as(u256, 0x420000000000000000000000000000000000000F), SystemContracts.GAS_PRICE_ORACLE.toU256());
    try testing.expectEqual(@as(u256, 0x4200000000000000000000000000000000000011), SystemContracts.SEQUENCER_FEE_VAULT.toU256());
    try testing.expectEqual(@as(u256, 0x4200000000000000000000000000000000000015), SystemContracts.L1_BLOCK.toU256());
    try testing.expectEqual(@as(u256, 0x4200000000000000000000000000000000000019), SystemContracts.BASE_FEE_VAULT.toU256());
    try testing.expectEqual(@as(u256, 0x420000000000000000000000000000000000001A), SystemContracts.L1_FEE_VAULT.toU256());
    try testing.expectEqual(@as(u256, 0x420000000000000000000000000000000000001B), SystemContracts.OPERATOR_FEE_VAULT.toU256());
}

test "BaseConfig.atTimestamp resolves mainnet and sepolia specs" {
    const mainnet_fjord = try BaseConfig.atTimestamp(.mainnet, hardforks.MAINNET.fjord);
    try testing.expectEqual(OpSpecId.FJORD, mainnet_fjord.spec);
    try testing.expectEqual(@as(u64, 8453), mainnet_fjord.chainId());

    // Mainnet Fjord (10 Jul 2024) falls between Sepolia Fjord (29 May) and Sepolia Granite (12 Aug).
    const sepolia_same_time = try BaseConfig.atTimestamp(.sepolia, hardforks.MAINNET.fjord);
    try testing.expectEqual(OpSpecId.FJORD, sepolia_same_time.spec);
    const sepolia_granite = try BaseConfig.atTimestamp(.sepolia, hardforks.SEPOLIA.granite);
    try testing.expectEqual(OpSpecId.GRANITE, sepolia_granite.spec);

    try testing.expectError(error.UnmodeledBaseUpgrade, BaseConfig.atTimestamp(.mainnet, hardforks.MAINNET.azul.?));
}

test "BaseConfig defaults are comptime" {
    comptime {
        const cfg = BaseConfig.DEFAULT;
        if (cfg.chain.chainId() != 8453) @compileError("default Base chain must be mainnet");
        if (cfg.spec != .JOVIAN) @compileError("default Base spec must be JOVIAN");
    }
}
