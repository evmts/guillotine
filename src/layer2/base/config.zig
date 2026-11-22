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
