//! OP Stack EIP-1559 base fee for the next block.
//!
//! Port of op-geth consensus/misc/eip1559 (`CalcBaseFee`, `calcBaseFeeInner`,
//! `ValidateOptimismExtraData`, `DecodeOptimismExtraData`):
//! https://github.com/ethereum-optimism/op-geth/blob/optimism/consensus/misc/eip1559/eip1559.go
//! https://github.com/ethereum-optimism/op-geth/blob/optimism/consensus/misc/eip1559/eip1559_optimism.go
//! Specs: specs/protocol/holocene/exec-engine.md, specs/protocol/jovian/exec-engine.md.
//!
//! | Parent spec   | denominator, elasticity                 | gas metered                    | floor        |
//! |---------------|-----------------------------------------|--------------------------------|--------------|
//! | < Holocene    | chain constants (Canyon denominator by  | gasUsed                        | none         |
//! |               | the child timestamp)                    |                                |              |
//! | Holocene+     | parent extraData v0 (9 bytes)           | gasUsed                        | none         |
//! | Jovian+       | parent extraData v1 (17 bytes)          | max(gasUsed, blobGasUsed)      | minBaseFee   |
//!
//! extraData: u8 version | u32 BE denominator | u32 BE elasticity [| u64 BE minBaseFee].
//! From Jovian, `blobGasUsed` carries the block DA footprint.
//! Every OP Stack chain is London from genesis, so there is no InitialBaseFee case.

const std = @import("std");
const OpSpecId = @import("spec.zig").OpSpecId;

pub const HOLOCENE_EXTRA_DATA_LEN: usize = 9;
pub const JOVIAN_EXTRA_DATA_LEN: usize = 17;
pub const HOLOCENE_EXTRA_DATA_VERSION: u8 = 0;
pub const JOVIAN_EXTRA_DATA_VERSION: u8 = 1;

pub const Error = error{
    /// extraData has the wrong length for the spec.
    InvalidExtraDataLength,
    /// extraData version byte does not match the spec.
    InvalidExtraDataVersion,
    /// Holocene+ extraData must encode a non-zero denominator.
    ZeroDenominator,
    /// Holocene+ extraData must encode a non-zero elasticity.
    ZeroElasticity,
    /// Pre-Holocene extraData must be empty (except the genesis block).
    UnexpectedExtraData,
    /// gas_limit / elasticity is zero, so the formula divides by zero.
    ZeroGasTarget,
    /// Jovian+ parent header without blobGasUsed.
    MissingBlobGasUsed,
    /// The increased base fee does not fit in 256 bits.
    BaseFeeOverflow,
};

/// Chain EIP-1559 constants used before Holocene (and as the Holocene defaults).
pub const Constants = struct {
    elasticity: u64,
    denominator: u64,
    denominator_canyon: u64,

    /// Denominator for a block at `child_spec` (op-geth `BaseFeeChangeDenominator(time)`
    /// takes the child timestamp).
    pub fn denominatorFor(self: Constants, child_spec: OpSpecId) u64 {
        return if (child_spec.isAtLeast(.CANYON)) self.denominator_canyon else self.denominator;
    }
};

/// EIP-1559 parameters decoded from a Holocene+ header.
pub const Params = struct {
    denominator: u32,
    elasticity: u32,
    /// Jovian minimum base fee in wei. Null before Jovian.
    min_base_fee: ?u64 = null,
};

/// Parent header fields the base fee depends on.
pub const Parent = struct {
    gas_limit: u64,
    gas_used: u64,
    /// Jovian+: the DA footprint. Required when the parent is Jovian+.
    blob_gas_used: ?u64 = null,
    base_fee: u256,
    extra_data: []const u8 = &.{},
};

fn decodeHoloceneFields(extra: []const u8) Error!Params {
    const denominator = std.mem.readInt(u32, extra[1..5], .big);
    const elasticity = std.mem.readInt(u32, extra[5..9], .big);
    if (denominator == 0) return error.ZeroDenominator;
    if (elasticity == 0) return error.ZeroElasticity;
    return .{ .denominator = denominator, .elasticity = elasticity };
}

/// Validate and decode the extraData of a block at `spec`
/// (op-geth `ValidateOptimismExtraData` + `Decode*ExtraData`). Returns null before Holocene.
pub fn decodeExtraData(spec: OpSpecId, extra: []const u8) Error!?Params {
    if (spec.isAtLeast(.JOVIAN)) {
        if (extra.len != JOVIAN_EXTRA_DATA_LEN) return error.InvalidExtraDataLength;
        if (extra[0] != JOVIAN_EXTRA_DATA_VERSION) return error.InvalidExtraDataVersion;
        var params = try decodeHoloceneFields(extra);
        params.min_base_fee = std.mem.readInt(u64, extra[9..17], .big);
        return params;
    }
    if (spec.isAtLeast(.HOLOCENE)) {
        if (extra.len != HOLOCENE_EXTRA_DATA_LEN) return error.InvalidExtraDataLength;
        if (extra[0] != HOLOCENE_EXTRA_DATA_VERSION) return error.InvalidExtraDataVersion;
        return try decodeHoloceneFields(extra);
    }
    if (extra.len > 0) return error.UnexpectedExtraData;
    return null;
}

/// Encode Holocene (min_base_fee null) or Jovian extraData into `out`; returns the used slice.
pub fn encodeExtraData(out: *[JOVIAN_EXTRA_DATA_LEN]u8, params: Params) []const u8 {
    out[0] = if (params.min_base_fee == null) HOLOCENE_EXTRA_DATA_VERSION else JOVIAN_EXTRA_DATA_VERSION;
    std.mem.writeInt(u32, out[1..5], params.denominator, .big);
    std.mem.writeInt(u32, out[5..9], params.elasticity, .big);
    const min = params.min_base_fee orelse return out[0..HOLOCENE_EXTRA_DATA_LEN];
    std.mem.writeInt(u64, out[9..17], min, .big);
    return out[0..JOVIAN_EXTRA_DATA_LEN];
}

/// op-geth `calcBaseFeeInner`: two floor divisions, +1 minimum increase, floor at 0.
fn calcInner(parent: Parent, elasticity: u64, denominator: u64, metered: u64) Error!u256 {
    const target = parent.gas_limit / elasticity;
    if (target == 0) return error.ZeroGasTarget;
    if (metered == target) return parent.base_fee;
    if (metered > target) {
        const delta = @as(u512, metered - target) * parent.base_fee / target / denominator;
        const increase = @max(delta, 1);
        const next = @as(u512, parent.base_fee) + increase;
        return std.math.cast(u256, next) orelse error.BaseFeeOverflow;
    }
    const delta = @as(u512, target - metered) * parent.base_fee / target / denominator;
    if (delta >= parent.base_fee) return 0;
    return parent.base_fee - @as(u256, @intCast(delta));
}

/// Base fee of the block after `parent` (op-geth `CalcBaseFee`).
/// `parent_spec` is the spec at the parent timestamp, `child_spec` at the child timestamp.
pub fn nextBaseFee(constants: Constants, parent_spec: OpSpecId, child_spec: OpSpecId, parent: Parent) Error!u256 {
    var elasticity = constants.elasticity;
    var denominator = constants.denominatorFor(child_spec);
    var min_base_fee: ?u64 = null;
    // The parent's own extraData only carries parameters from Holocene; before that
    // it is not consulted (op-geth `DecodeOptimismExtraData` returns zeros).
    if (parent_spec.isAtLeast(.HOLOCENE)) {
        const params = (try decodeExtraData(parent_spec, parent.extra_data)).?;
        elasticity = params.elasticity;
        denominator = params.denominator;
        min_base_fee = params.min_base_fee;
    }
    if (elasticity == 0) return error.ZeroElasticity;
    if (denominator == 0) return error.ZeroDenominator;
    var metered = parent.gas_used;
    if (parent_spec.isAtLeast(.JOVIAN)) {
        metered = @max(metered, parent.blob_gas_used orelse return error.MissingBlobGasUsed);
    }
    const base_fee = try calcInner(parent, elasticity, denominator, metered);
    if (min_base_fee) |min| return @max(base_fee, min);
    return base_fee;
}

// ============================================================================
// Tests: vectors from op-geth consensus/misc/eip1559/eip1559_test.go and
// eip1559_optimism_test.go (opConfig: elasticity 6, denominator 50, Canyon 250).
// ============================================================================

const testing = std.testing;

const op_constants = Constants{ .elasticity = 6, .denominator = 50, .denominator_canyon = 250 };
const initial_base_fee: u256 = 1_000_000_000;

test "op-geth TestCalcBaseFeeOptimism pre-Canyon and post-Canyon vectors" {
    const cases = [_]struct { used: u64, pre: u256, post: u256 }{
        .{ .used = 5_000_000, .pre = initial_base_fee, .post = initial_base_fee },
        .{ .used = 4_000_000, .pre = 996_000_000, .post = 999_200_000 },
        .{ .used = 10_000_000, .pre = 1_020_000_000, .post = 1_004_000_000 },
    };
    for (cases) |case| {
        const parent = Parent{ .gas_limit = 30_000_000, .gas_used = case.used, .base_fee = initial_base_fee };
        try testing.expectEqual(case.pre, try nextBaseFee(op_constants, .REGOLITH, .REGOLITH, parent));
        // The Canyon denominator follows the child block's timestamp.
        try testing.expectEqual(case.post, try nextBaseFee(op_constants, .REGOLITH, .CANYON, parent));
        try testing.expectEqual(case.post, try nextBaseFee(op_constants, .GRANITE, .HOLOCENE, parent));
    }
}

test "op-geth TestCalcBaseFeeOptimismHolocene vectors" {
    const cases = [_]struct { used: u64, expected: u256, denominator: u32, elasticity: u32 }{
        .{ .used = 15_000_000, .expected = 10_000_000, .denominator = 10, .elasticity = 2 },
        .{ .used = 10_000_000, .expected = 9_666_667, .denominator = 10, .elasticity = 2 },
        .{ .used = 20_000_000, .expected = 10_333_333, .denominator = 10, .elasticity = 2 },
        .{ .used = 3_000_000, .expected = 10_000_000, .denominator = 2, .elasticity = 10 },
        .{ .used = 1_000_000, .expected = 6_666_667, .denominator = 2, .elasticity = 10 },
        .{ .used = 30_000_000, .expected = 55_000_000, .denominator = 2, .elasticity = 10 },
    };
    for (cases) |case| {
        var buf: [JOVIAN_EXTRA_DATA_LEN]u8 = undefined;
        const extra = encodeExtraData(&buf, .{ .denominator = case.denominator, .elasticity = case.elasticity });
        try testing.expectEqual(HOLOCENE_EXTRA_DATA_LEN, extra.len);
        const parent = Parent{ .gas_limit = 30_000_000, .gas_used = case.used, .base_fee = 10_000_000, .extra_data = extra };
        try testing.expectEqual(case.expected, try nextBaseFee(op_constants, .HOLOCENE, .HOLOCENE, parent));
        try testing.expectEqual(case.expected, try nextBaseFee(op_constants, .ISTHMUS, .JOVIAN, parent));
    }
}

test "op-geth TestCalcBaseFeeJovian vectors" {
    const target: u64 = 10_000_000;
    const cases = [_]struct { base: u256, used: u64, blob: u64, jovian: bool, min: u64, expected: u256 }{
        .{ .base = 1, .used = target - 1_000_000, .blob = 0, .jovian = false, .min = 1_000_000_000, .expected = 1 },
        .{ .base = 1, .used = target, .blob = 0, .jovian = true, .min = 1_000_000_000, .expected = 1_000_000_000 },
        .{ .base = 1, .used = target + 1_000_000, .blob = 0, .jovian = true, .min = 1_000_000_000, .expected = 1_000_000_000 },
        .{ .base = 2_000_000_000, .used = target + 10_000_000, .blob = 0, .jovian = true, .min = 1_000_000_000, .expected = 2_040_000_000 },
        .{ .base = 1, .used = target - 1_000_000, .blob = 0, .jovian = true, .min = 1_000_000_000, .expected = 1_000_000_000 },
        .{ .base = 2_097_152, .used = target - 1_000_000, .blob = 0, .jovian = true, .min = 2_000_000, .expected = 2_092_958 },
        .{ .base = 10_000, .used = target - 1, .blob = 0, .jovian = true, .min = 10_000, .expected = 10_000 },
        .{ .base = 10_000, .used = target + 1, .blob = 0, .jovian = true, .min = 10_000, .expected = 10_001 },
        .{ .base = 10_000, .used = target, .blob = 30_000_000, .jovian = false, .min = 1_000_000, .expected = 10_000 },
        .{ .base = 10_000, .used = target, .blob = target + 1, .jovian = true, .min = 10_000, .expected = 10_001 },
        .{ .base = 2_000_000_000, .used = target, .blob = target + 10_000_000, .jovian = true, .min = 1_000_000_000, .expected = 2_040_000_000 },
    };
    for (cases) |case| {
        var buf: [JOVIAN_EXTRA_DATA_LEN]u8 = undefined;
        // A pre-Jovian (Isthmus) parent carries Holocene extraData without a minimum.
        const extra = encodeExtraData(&buf, .{ .denominator = 50, .elasticity = 3, .min_base_fee = if (case.jovian) case.min else null });
        const parent = Parent{ .gas_limit = 30_000_000, .gas_used = case.used, .blob_gas_used = case.blob, .base_fee = case.base, .extra_data = extra };
        const parent_spec: OpSpecId = if (case.jovian) .JOVIAN else .ISTHMUS;
        try testing.expectEqual(case.expected, try nextBaseFee(op_constants, parent_spec, .JOVIAN, parent));
    }
}

test "op-geth TestValidateHoloceneExtraData cases" {
    try testing.expectError(error.InvalidExtraDataLength, decodeExtraData(.HOLOCENE, &.{ 0x00, 0x01 }));
    try testing.expectError(error.InvalidExtraDataVersion, decodeExtraData(.HOLOCENE, &.{ 1, 0, 0, 0, 1, 0, 0, 0, 1 }));
    try testing.expectError(error.ZeroDenominator, decodeExtraData(.HOLOCENE, &.{ 0, 0, 0, 0, 0, 0, 0, 0, 1 }));
    try testing.expectError(error.ZeroElasticity, decodeExtraData(.HOLOCENE, &.{ 0, 0, 0, 0, 1, 0, 0, 0, 0 }));
    try testing.expectError(error.ZeroDenominator, decodeExtraData(.HOLOCENE, &.{ 0, 0, 0, 0, 0, 0, 0, 0, 0 }));
    const ok = (try decodeExtraData(.ISTHMUS, &.{ 0, 0, 0, 0, 250, 0, 0, 0, 6 })).?;
    try testing.expectEqual(@as(u32, 250), ok.denominator);
    try testing.expectEqual(@as(u32, 6), ok.elasticity);
    try testing.expect(ok.min_base_fee == null);
}

test "Jovian extraData: version 1, 17 bytes, big-endian min base fee" {
    const extra = [_]u8{ 1, 0, 0, 0, 250, 0, 0, 0, 6, 0, 0, 0, 0, 0, 0x0f, 0x42, 0x40 };
    const params = (try decodeExtraData(.JOVIAN, &extra)).?;
    try testing.expectEqual(@as(u32, 250), params.denominator);
    try testing.expectEqual(@as(u32, 6), params.elasticity);
    try testing.expectEqual(@as(?u64, 1_000_000), params.min_base_fee);
    var buf: [JOVIAN_EXTRA_DATA_LEN]u8 = undefined;
    try testing.expectEqualSlices(u8, &extra, encodeExtraData(&buf, params));
    // A Holocene-format header is invalid once Jovian is active, and vice versa.
    try testing.expectError(error.InvalidExtraDataLength, decodeExtraData(.JOVIAN, extra[0..9]));
    try testing.expectError(error.InvalidExtraDataLength, decodeExtraData(.ISTHMUS, &extra));
    var wrong_version = extra;
    wrong_version[0] = 0;
    try testing.expectError(error.InvalidExtraDataVersion, decodeExtraData(.JOVIAN, &wrong_version));
    var zero_elasticity = extra;
    zero_elasticity[8] = 0;
    try testing.expectError(error.ZeroElasticity, decodeExtraData(.JOVIAN, &zero_elasticity));
    try testing.expectError(error.UnexpectedExtraData, decodeExtraData(.GRANITE, &extra));
    try testing.expect((try decodeExtraData(.GRANITE, &.{})) == null);
}

test "nextBaseFee fails closed on malformed parents" {
    const holocene = Parent{ .gas_limit = 30_000_000, .gas_used = 1, .base_fee = 1, .extra_data = &.{} };
    try testing.expectError(error.InvalidExtraDataLength, nextBaseFee(op_constants, .HOLOCENE, .HOLOCENE, holocene));
    const jovian = Parent{ .gas_limit = 30_000_000, .gas_used = 1, .base_fee = 1, .extra_data = &.{ 1, 0, 0, 0, 50, 0, 0, 0, 3, 0, 0, 0, 0, 0, 0, 0, 0 } };
    try testing.expectError(error.MissingBlobGasUsed, nextBaseFee(op_constants, .JOVIAN, .JOVIAN, jovian));
    const tiny = Parent{ .gas_limit = 5, .gas_used = 1, .base_fee = 1 };
    try testing.expectError(error.ZeroGasTarget, nextBaseFee(op_constants, .CANYON, .CANYON, tiny));
    const huge = Parent{ .gas_limit = 30_000_000, .gas_used = 30_000_000, .base_fee = std.math.maxInt(u256) };
    try testing.expectError(error.BaseFeeOverflow, nextBaseFee(op_constants, .CANYON, .CANYON, huge));
    // A decrease never goes below zero.
    const empty = Parent{ .gas_limit = 30_000_000, .gas_used = 0, .base_fee = 1 };
    try testing.expectEqual(@as(u256, 1), try nextBaseFee(op_constants, .CANYON, .CANYON, empty));
    const zero_constants = Constants{ .elasticity = 0, .denominator = 50, .denominator_canyon = 250 };
    try testing.expectError(error.ZeroElasticity, nextBaseFee(zero_constants, .CANYON, .CANYON, empty));
}
