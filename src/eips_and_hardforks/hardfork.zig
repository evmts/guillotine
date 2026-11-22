//! Ethereum hardfork identifiers for the EVM.
//!
//! The single definition lives in `lib/voltaire/src/primitives/hardfork.zig`.
//! This module re-exports it so `Hardfork` here and `primitives.Hardfork`
//! (used by `eips.zig`) are the same type: same variants, order, methods and
//! constants, with no copy to drift. The tests below run in `zig build test-unit`.

const voltaire = @import("voltaire");

pub const Hardfork = voltaire.Hardfork;
pub const ForkTransition = voltaire.ForkTransition;

const Eips = @import("eips.zig").Eips;

const std = @import("std");

test "hardfork enum ordering" {
    try std.testing.expect(@intFromEnum(Hardfork.FRONTIER) < @intFromEnum(Hardfork.HOMESTEAD));
    try std.testing.expect(@intFromEnum(Hardfork.HOMESTEAD) < @intFromEnum(Hardfork.BYZANTIUM));
    try std.testing.expect(@intFromEnum(Hardfork.BYZANTIUM) < @intFromEnum(Hardfork.CANCUN));
    try std.testing.expect(@intFromEnum(Hardfork.CANCUN) < @intFromEnum(Hardfork.PRAGUE));
}

test "hardfork default is osaka" {
    try std.testing.expectEqual(Hardfork.OSAKA, Hardfork.DEFAULT);
}

test "hardfork is the voltaire primitives type" {
    try std.testing.expect(Hardfork == voltaire.Hardfork);
    try std.testing.expect(Hardfork == @import("eips.zig").Hardfork);
}

test "hardfork AMSTERDAM follows OSAKA" {
    try std.testing.expect(Hardfork.OSAKA.isBefore(Hardfork.AMSTERDAM));
    try std.testing.expectEqual(Hardfork.OSAKA.toInt() + 1, Hardfork.AMSTERDAM.toInt());
    try std.testing.expectEqual(@as(usize, Hardfork.AMSTERDAM.toInt() + 1), std.meta.fields(Hardfork).len);
    try std.testing.expectEqual(Hardfork.AMSTERDAM, Hardfork.fromString("Amsterdam").?);
}

test "hardfork toInt conversion" {
    try std.testing.expect(Hardfork.FRONTIER.toInt() == 0);
    try std.testing.expect(Hardfork.HOMESTEAD.toInt() == 1);
    try std.testing.expect(Hardfork.CANCUN.toInt() > Hardfork.FRONTIER.toInt());
    try std.testing.expect(Hardfork.PRAGUE.toInt() > Hardfork.CANCUN.toInt());
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

test "hardfork OSAKA ordering" {
    try std.testing.expect(Hardfork.PRAGUE.isBefore(Hardfork.OSAKA));
    try std.testing.expect(Hardfork.OSAKA.isAtLeast(Hardfork.PRAGUE));
    try std.testing.expect(Hardfork.OSAKA.isAtLeast(Hardfork.CANCUN));
    try std.testing.expect(@intFromEnum(Hardfork.OSAKA) > @intFromEnum(Hardfork.PRAGUE));
}

test "hardfork mainnet activation blocks" {
    try std.testing.expectEqual(@as(?u64, 0), Hardfork.FRONTIER.mainnetActivationBlock());
    try std.testing.expectEqual(@as(?u64, 1150000), Hardfork.HOMESTEAD.mainnetActivationBlock());
    try std.testing.expectEqual(@as(?u64, 1920000), Hardfork.DAO.mainnetActivationBlock());
    try std.testing.expectEqual(@as(?u64, 2463000), Hardfork.TANGERINE_WHISTLE.mainnetActivationBlock());
    try std.testing.expectEqual(@as(?u64, 2675000), Hardfork.SPURIOUS_DRAGON.mainnetActivationBlock());
    try std.testing.expectEqual(@as(?u64, 4370000), Hardfork.BYZANTIUM.mainnetActivationBlock());
    try std.testing.expectEqual(@as(?u64, 7280000), Hardfork.CONSTANTINOPLE.mainnetActivationBlock());
    try std.testing.expectEqual(@as(?u64, 7280000), Hardfork.PETERSBURG.mainnetActivationBlock());
    try std.testing.expectEqual(@as(?u64, 9069000), Hardfork.ISTANBUL.mainnetActivationBlock());
    try std.testing.expectEqual(@as(?u64, 9200000), Hardfork.MUIR_GLACIER.mainnetActivationBlock());
    try std.testing.expectEqual(@as(?u64, 12244000), Hardfork.BERLIN.mainnetActivationBlock());
    try std.testing.expectEqual(@as(?u64, 12965000), Hardfork.LONDON.mainnetActivationBlock());
    try std.testing.expectEqual(@as(?u64, 13773000), Hardfork.ARROW_GLACIER.mainnetActivationBlock());
    try std.testing.expectEqual(@as(?u64, 15050000), Hardfork.GRAY_GLACIER.mainnetActivationBlock());
    try std.testing.expectEqual(@as(?u64, 15537394), Hardfork.MERGE.mainnetActivationBlock());
    try std.testing.expectEqual(@as(?u64, 17034870), Hardfork.SHANGHAI.mainnetActivationBlock());
    try std.testing.expectEqual(@as(?u64, 19426587), Hardfork.CANCUN.mainnetActivationBlock());
    try std.testing.expectEqual(@as(?u64, 22431084), Hardfork.PRAGUE.mainnetActivationBlock());
    try std.testing.expectEqual(@as(?u64, 23935694), Hardfork.OSAKA.mainnetActivationBlock());
    try std.testing.expectEqual(@as(?u64, null), Hardfork.AMSTERDAM.mainnetActivationBlock());
}

test "hardfork mainnet activation timestamps" {
    try std.testing.expectEqual(@as(?u64, null), Hardfork.FRONTIER.mainnetActivationTimestamp());
    try std.testing.expectEqual(@as(?u64, null), Hardfork.HOMESTEAD.mainnetActivationTimestamp());
    try std.testing.expectEqual(@as(?u64, null), Hardfork.BERLIN.mainnetActivationTimestamp());
    try std.testing.expectEqual(@as(?u64, null), Hardfork.LONDON.mainnetActivationTimestamp());

    try std.testing.expectEqual(@as(?u64, 1663224162), Hardfork.MERGE.mainnetActivationTimestamp());
    try std.testing.expectEqual(@as(?u64, 1681338455), Hardfork.SHANGHAI.mainnetActivationTimestamp());
    try std.testing.expectEqual(@as(?u64, 1710338135), Hardfork.CANCUN.mainnetActivationTimestamp());
    try std.testing.expectEqual(@as(?u64, 1746612311), Hardfork.PRAGUE.mainnetActivationTimestamp());
    try std.testing.expectEqual(@as(?u64, 1764798551), Hardfork.OSAKA.mainnetActivationTimestamp());
    try std.testing.expectEqual(@as(?u64, null), Hardfork.AMSTERDAM.mainnetActivationTimestamp());
}

test "hardfork activation block ordering" {
    const frontier = Hardfork.FRONTIER.mainnetActivationBlock().?;
    const homestead = Hardfork.HOMESTEAD.mainnetActivationBlock().?;
    const berlin = Hardfork.BERLIN.mainnetActivationBlock().?;
    const london = Hardfork.LONDON.mainnetActivationBlock().?;
    const merge = Hardfork.MERGE.mainnetActivationBlock().?;
    const shanghai = Hardfork.SHANGHAI.mainnetActivationBlock().?;
    const cancun = Hardfork.CANCUN.mainnetActivationBlock().?;
    const prague = Hardfork.PRAGUE.mainnetActivationBlock().?;
    const osaka = Hardfork.OSAKA.mainnetActivationBlock().?;

    try std.testing.expect(cancun < prague);
    try std.testing.expect(prague < osaka);
    try std.testing.expect(frontier < homestead);
    try std.testing.expect(homestead < berlin);
    try std.testing.expect(berlin < london);
    try std.testing.expect(london < merge);
    try std.testing.expect(merge < shanghai);
    try std.testing.expect(shanghai < cancun);
}

test "hardfork activation timestamp ordering" {
    const merge = Hardfork.MERGE.mainnetActivationTimestamp().?;
    const shanghai = Hardfork.SHANGHAI.mainnetActivationTimestamp().?;
    const cancun = Hardfork.CANCUN.mainnetActivationTimestamp().?;
    const prague = Hardfork.PRAGUE.mainnetActivationTimestamp().?;
    const osaka = Hardfork.OSAKA.mainnetActivationTimestamp().?;

    try std.testing.expect(cancun < prague);
    try std.testing.expect(prague < osaka);
    try std.testing.expect(merge < shanghai);
    try std.testing.expect(shanghai < cancun);
}

test "hardfork EIP activation through Eips" {
    try std.testing.expect(!(Eips{ .hardfork = .FRONTIER }).is_eip_active(150));
    try std.testing.expect((Eips{ .hardfork = .TANGERINE_WHISTLE }).is_eip_active(150));

    try std.testing.expect(!(Eips{ .hardfork = .ISTANBUL }).is_eip_active(2929));
    try std.testing.expect((Eips{ .hardfork = .BERLIN }).is_eip_active(2929));

    try std.testing.expect(!(Eips{ .hardfork = .BERLIN }).is_eip_active(1559));
    try std.testing.expect((Eips{ .hardfork = .LONDON }).is_eip_active(1559));

    try std.testing.expect(!(Eips{ .hardfork = .LONDON }).is_eip_active(3855));
    try std.testing.expect((Eips{ .hardfork = .SHANGHAI }).is_eip_active(3855));

    try std.testing.expect(!(Eips{ .hardfork = .SHANGHAI }).is_eip_active(1153));
    try std.testing.expect((Eips{ .hardfork = .CANCUN }).is_eip_active(1153));
    try std.testing.expect((Eips{ .hardfork = .CANCUN }).is_eip_active(4844));
    try std.testing.expect((Eips{ .hardfork = .CANCUN }).is_eip_active(6780));

    try std.testing.expect(!(Eips{ .hardfork = .CANCUN }).is_eip_active(7702));
    try std.testing.expect((Eips{ .hardfork = .PRAGUE }).is_eip_active(7702));
    try std.testing.expect((Eips{ .hardfork = .PRAGUE }).is_eip_active(2537));
    try std.testing.expect((Eips{ .hardfork = .PRAGUE }).is_eip_active(7002));

    try std.testing.expect((Eips{ .hardfork = .OSAKA }).is_eip_active(7883));
    try std.testing.expect((Eips{ .hardfork = .OSAKA }).is_eip_active(7823));
    try std.testing.expect((Eips{ .hardfork = .OSAKA }).is_eip_active(7702));
    try std.testing.expect((Eips{ .hardfork = .AMSTERDAM }).is_eip_active(7825));
}

test "hardfork constantinople petersburg same block" {
    const constantinople_block = Hardfork.CONSTANTINOPLE.mainnetActivationBlock().?;
    const petersburg_block = Hardfork.PETERSBURG.mainnetActivationBlock().?;

    try std.testing.expectEqual(constantinople_block, petersburg_block);
}

test "hardfork complete enum coverage" {
    const all_hardforks = [_]Hardfork{
        .FRONTIER,
        .HOMESTEAD,
        .DAO,
        .TANGERINE_WHISTLE,
        .SPURIOUS_DRAGON,
        .BYZANTIUM,
        .CONSTANTINOPLE,
        .PETERSBURG,
        .ISTANBUL,
        .MUIR_GLACIER,
        .BERLIN,
        .LONDON,
        .ARROW_GLACIER,
        .GRAY_GLACIER,
        .MERGE,
        .SHANGHAI,
        .CANCUN,
        .PRAGUE,
        .OSAKA,
        .AMSTERDAM,
    };

    for (all_hardforks) |fork| {
        _ = fork.toInt();
        _ = fork.mainnetActivationBlock();
        _ = fork.mainnetActivationTimestamp();
    }
}

test "hardfork comparison all pairs" {
    try std.testing.expect(Hardfork.FRONTIER.isBefore(Hardfork.HOMESTEAD));
    try std.testing.expect(Hardfork.HOMESTEAD.isBefore(Hardfork.BYZANTIUM));
    try std.testing.expect(Hardfork.BYZANTIUM.isBefore(Hardfork.CONSTANTINOPLE));
    try std.testing.expect(Hardfork.CONSTANTINOPLE.isBefore(Hardfork.ISTANBUL));
    try std.testing.expect(Hardfork.ISTANBUL.isBefore(Hardfork.BERLIN));
    try std.testing.expect(Hardfork.BERLIN.isBefore(Hardfork.LONDON));
    try std.testing.expect(Hardfork.LONDON.isBefore(Hardfork.MERGE));
    try std.testing.expect(Hardfork.MERGE.isBefore(Hardfork.SHANGHAI));
    try std.testing.expect(Hardfork.SHANGHAI.isBefore(Hardfork.CANCUN));
    try std.testing.expect(Hardfork.CANCUN.isBefore(Hardfork.PRAGUE));
    try std.testing.expect(Hardfork.PRAGUE.isBefore(Hardfork.OSAKA));
    try std.testing.expect(Hardfork.OSAKA.isBefore(Hardfork.AMSTERDAM));
}

test "hardfork isAtLeast reflexive" {
    try std.testing.expect(Hardfork.FRONTIER.isAtLeast(Hardfork.FRONTIER));
    try std.testing.expect(Hardfork.HOMESTEAD.isAtLeast(Hardfork.HOMESTEAD));
    try std.testing.expect(Hardfork.BERLIN.isAtLeast(Hardfork.BERLIN));
    try std.testing.expect(Hardfork.LONDON.isAtLeast(Hardfork.LONDON));
    try std.testing.expect(Hardfork.SHANGHAI.isAtLeast(Hardfork.SHANGHAI));
    try std.testing.expect(Hardfork.CANCUN.isAtLeast(Hardfork.CANCUN));
    try std.testing.expect(Hardfork.PRAGUE.isAtLeast(Hardfork.PRAGUE));
    try std.testing.expect(Hardfork.OSAKA.isAtLeast(Hardfork.OSAKA));
    try std.testing.expect(Hardfork.AMSTERDAM.isAtLeast(Hardfork.AMSTERDAM));
}