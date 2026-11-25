//! OP Stack precompile changes by spec.
//!
//! Port of op-revm precompiles.rs:
//! https://github.com/ethereum-optimism/optimism/blob/develop/rust/op-revm/src/precompiles.rs
//!
//! | Spec      | Change                                                                  |
//! |-----------|-------------------------------------------------------------------------|
//! | Fjord     | add P256VERIFY at 0x100 (RIP-7212, 3450 gas)                            |
//! | Granite   | BN254 pairing (0x08) input <= 112,687 bytes                             |
//! | Isthmus   | Prague BLS12-381 set; G1 MSM <= 513,760, G2 MSM <= 488,448,             |
//! |           | pairing <= 235,008 bytes                                                |
//! | Jovian    | BN254 pairing <= 81,984; G1 MSM <= 288,960; G2 MSM <= 278,784;          |
//! |           | BLS pairing <= 156,672 bytes                                            |
//!
//! An input above a limit halts the call (op-revm `PrecompileHalt`): all gas is consumed.
//! Here that is `error.InvalidInput` from the raw functions, and `success = false` with
//! `gas_used = gas_limit` from the `overrides` adapters.

const std = @import("std");
const primitives = @import("voltaire");
const Address = primitives.Address;
const precompiles = @import("precompiles");
const p256verify = precompiles.p256verify;
const spec_mod = @import("spec.zig");
const OpSpecId = spec_mod.OpSpecId;

const PrecompileError = precompiles.PrecompileError;
const PrecompileResult = precompiles.PrecompileResult;

pub const P256_VERIFY_ADDRESS: Address = p256verify.P256VERIFY_ADDRESS;
pub const BN254_PAIRING_ADDRESS: Address = Address.fromU256(0x08);
pub const BLS12_G1_MSM_ADDRESS: Address = Address.fromU256(0x0C);
pub const BLS12_G2_MSM_ADDRESS: Address = Address.fromU256(0x0E);
pub const BLS12_PAIRING_ADDRESS: Address = Address.fromU256(0x0F);

/// RIP-7212 gas on OP Stack Fjord through Jovian.
pub const P256_VERIFY_GAS: u64 = p256verify.GAS_COST_RIP7212;

pub const BN254_PAIRING_MAX_INPUT_GRANITE: usize = 112_687;
pub const BN254_PAIRING_MAX_INPUT_JOVIAN: usize = 81_984;
pub const BLS12_G1_MSM_MAX_INPUT_ISTHMUS: usize = 513_760;
pub const BLS12_G1_MSM_MAX_INPUT_JOVIAN: usize = 288_960;
pub const BLS12_G2_MSM_MAX_INPUT_ISTHMUS: usize = 488_448;
pub const BLS12_G2_MSM_MAX_INPUT_JOVIAN: usize = 278_784;
pub const BLS12_PAIRING_MAX_INPUT_ISTHMUS: usize = 235_008;
pub const BLS12_PAIRING_MAX_INPUT_JOVIAN: usize = 156_672;

/// Raw precompile signature shared by voltaire precompiles.
pub const RawFn = fn (std.mem.Allocator, []const u8, u64) PrecompileError!PrecompileResult;

/// P256VERIFY at RIP-7212 gas.
pub fn p256Verify(allocator: std.mem.Allocator, input: []const u8, gas_limit: u64) PrecompileError!PrecompileResult {
    return p256verify.execute(allocator, input, gas_limit, P256_VERIFY_GAS);
}

fn limited(comptime max_input: usize, comptime inner: RawFn) RawFn {
    return struct {
        fn run(allocator: std.mem.Allocator, input: []const u8, gas_limit: u64) PrecompileError!PrecompileResult {
            if (input.len > max_input) return error.InvalidInput;
            return inner(allocator, input, gas_limit);
        }
    }.run;
}

pub const bn254PairingGranite = limited(BN254_PAIRING_MAX_INPUT_GRANITE, precompiles.bn254_pairing.execute);
pub const bn254PairingJovian = limited(BN254_PAIRING_MAX_INPUT_JOVIAN, precompiles.bn254_pairing.execute);
pub const bls12G1MsmIsthmus = limited(BLS12_G1_MSM_MAX_INPUT_ISTHMUS, precompiles.bls12_g1_msm.execute);
pub const bls12G1MsmJovian = limited(BLS12_G1_MSM_MAX_INPUT_JOVIAN, precompiles.bls12_g1_msm.execute);
pub const bls12G2MsmIsthmus = limited(BLS12_G2_MSM_MAX_INPUT_ISTHMUS, precompiles.bls12_g2_msm.execute);
pub const bls12G2MsmJovian = limited(BLS12_G2_MSM_MAX_INPUT_JOVIAN, precompiles.bls12_g2_msm.execute);
pub const bls12PairingIsthmus = limited(BLS12_PAIRING_MAX_INPUT_ISTHMUS, precompiles.bls12_pairing.execute);
pub const bls12PairingJovian = limited(BLS12_PAIRING_MAX_INPUT_JOVIAN, precompiles.bls12_pairing.execute);

/// One OP-specific precompile entry for a spec.
pub const Entry = struct {
    address: Address,
    execute: *const RawFn,
};

/// OP-specific precompile entries for `spec`. Each entry adds or replaces the
/// mainnet precompile at its address for the underlying Ethereum hardfork
/// (`spec.toEthHardfork()`).
pub fn entries(comptime spec: OpSpecId) []const Entry {
    const table = comptime blk: {
        var list: []const Entry = &.{};
        if (spec.isAtLeast(.FJORD)) {
            list = list ++ [_]Entry{.{ .address = P256_VERIFY_ADDRESS, .execute = &p256Verify }};
        }
        if (spec.isAtLeast(.JOVIAN)) {
            list = list ++ [_]Entry{.{ .address = BN254_PAIRING_ADDRESS, .execute = &bn254PairingJovian }};
        } else if (spec.isAtLeast(.GRANITE)) {
            list = list ++ [_]Entry{.{ .address = BN254_PAIRING_ADDRESS, .execute = &bn254PairingGranite }};
        }
        if (spec.isAtLeast(.JOVIAN)) {
            list = list ++ [_]Entry{
                .{ .address = BLS12_G1_MSM_ADDRESS, .execute = &bls12G1MsmJovian },
                .{ .address = BLS12_G2_MSM_ADDRESS, .execute = &bls12G2MsmJovian },
                .{ .address = BLS12_PAIRING_ADDRESS, .execute = &bls12PairingJovian },
            };
        } else if (spec.isAtLeast(.ISTHMUS)) {
            list = list ++ [_]Entry{
                .{ .address = BLS12_G1_MSM_ADDRESS, .execute = &bls12G1MsmIsthmus },
                .{ .address = BLS12_G2_MSM_ADDRESS, .execute = &bls12G2MsmIsthmus },
                .{ .address = BLS12_PAIRING_ADDRESS, .execute = &bls12PairingIsthmus },
            };
        }
        break :blk list[0..list.len].*;
    };
    return &table;
}

/// True if `address` is P256VERIFY under `spec` (the only OP-added address).
pub fn isOpPrecompile(address: Address, spec: OpSpecId) bool {
    return spec.isAtLeast(.FJORD) and address.toU256() == P256_VERIFY_ADDRESS.toU256();
}

/// Build EVM precompile overrides for `spec`.
///
/// `Override` must have fields `address: Address` and
/// `execute: *const fn (std.mem.Allocator, []const u8, u64) anyerror!Output`, where `Output`
/// has fields `output: []const u8`, `gas_used: u64`, `success: bool`
/// (this matches `PrecompileOverride` in src/evm_config.zig). Taking the type as a
/// parameter keeps this module free of an import cycle with the EVM.
///
/// Adapter semantics:
/// - success: `output` is allocated by the allocator passed in; the caller frees it.
/// - precompile failure (out of gas, input limit, invalid input/point/pairing):
///   `success = false`, `gas_used = gas_limit`, empty output.
/// - any other error (OutOfMemory, an unavailable or internally failing
///   implementation) propagates instead of being reported as a halt.
pub fn overrides(comptime Override: type, comptime spec: OpSpecId) []const Override {
    const table = comptime blk: {
        const list = entries(spec);
        var out: [list.len]Override = undefined;
        for (list, 0..) |entry, i| {
            out[i] = .{ .address = entry.address, .execute = &adapt(Override, entry.execute.*) };
        }
        break :blk out;
    };
    return &table;
}

fn OutputOf(comptime Override: type) type {
    const exec_ptr = @typeInfo(@FieldType(Override, "execute")).pointer.child;
    const ret = @typeInfo(exec_ptr).@"fn".return_type.?;
    return @typeInfo(ret).error_union.payload;
}

fn adapt(comptime Override: type, comptime raw: RawFn) fn (std.mem.Allocator, []const u8, u64) anyerror!OutputOf(Override) {
    const Output = OutputOf(Override);
    return struct {
        fn run(allocator: std.mem.Allocator, input: []const u8, gas_limit: u64) anyerror!Output {
            // op-revm: an input/point/signature/gas failure is a precompile halt that
            // consumes all gas. Anything else (allocation failure, an unavailable or
            // internally failing implementation) is not a consensus outcome and
            // propagates, like op-revm `PrecompileError::Fatal`.
            const result = raw(allocator, input, gas_limit) catch |err| switch (err) {
                error.InvalidInput,
                error.InvalidSignature,
                error.InvalidPoint,
                error.InvalidPairing,
                error.OutOfGas,
                => return Output{ .output = &.{}, .gas_used = gas_limit, .success = false },
                else => |fatal| return fatal,
            };
            return Output{ .output = result.output, .gas_used = result.gas_used, .success = true };
        }
    }.run;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

/// Mirror of src/evm_config.zig PrecompileOverride/PrecompileOutput.
const TestOutput = struct {
    output: []const u8,
    gas_used: u64,
    success: bool,
};
const TestOverride = struct {
    address: Address,
    execute: *const fn (allocator: std.mem.Allocator, input: []const u8, gas_limit: u64) anyerror!TestOutput,
};

fn hexToBytes(comptime hex: []const u8) [hex.len / 2]u8 {
    var out: [hex.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, hex) catch |err| @compileError(@errorName(err));
    return out;
}

const rip7212_reference = hexToBytes(
    "4cee90eb86eaa050036147a12d49004b6b9c72bd725d39d4785011fe190f0b4d" ++
        "a73bd4903f0ce3b639bbbf6e8e80d16931ff4bcf5993d58468e8fb19086e8cac" ++
        "36dbcd03009df8c59286b162af3bd7fcc0450c9aa81be5d10d312af6c66b1d60" ++
        "4aebd3099c618202fcfe16ae7770b0c49ab5eadf74b754204a3bb6060e44eff3" ++
        "7618b065f9832de4ca6ca971a7a1adc826d0f7c00181a5fb2ddf79ae00b4e10e",
);

test "constants" {
    try testing.expectEqual(@as(u256, 0x100), P256_VERIFY_ADDRESS.toU256());
    try testing.expectEqual(@as(u64, 3450), P256_VERIFY_GAS);
    try testing.expectEqual(@as(u256, 0x08), BN254_PAIRING_ADDRESS.toU256());
    try testing.expectEqual(@as(usize, 112_687), BN254_PAIRING_MAX_INPUT_GRANITE);
    try testing.expectEqual(@as(usize, 81_984), BN254_PAIRING_MAX_INPUT_JOVIAN);
    // Jovian limits are whole pairs/points: 427*192, 1806*160, 968*288, 408*384 bytes.
    try testing.expectEqual(@as(usize, 427 * 192), BN254_PAIRING_MAX_INPUT_JOVIAN);
    try testing.expectEqual(@as(usize, 1806 * 160), BLS12_G1_MSM_MAX_INPUT_JOVIAN);
    try testing.expectEqual(@as(usize, 968 * 288), BLS12_G2_MSM_MAX_INPUT_JOVIAN);
    try testing.expectEqual(@as(usize, 408 * 384), BLS12_PAIRING_MAX_INPUT_JOVIAN);
}

test "p256Verify verifies the RIP-7212 reference vector at 3450 gas" {
    const result = try p256Verify(testing.allocator, &rip7212_reference, 3450);
    defer result.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, 3450), result.gas_used);
    try testing.expectEqual(@as(usize, 32), result.output.len);
    try testing.expectEqual(@as(u8, 1), result.output[31]);
    try testing.expectError(error.OutOfGas, p256Verify(testing.allocator, &rip7212_reference, 3449));
}

test "p256Verify matches all go-ethereum / Wycheproof vectors at RIP-7212 gas" {
    const data = @embedFile("testdata/p256verify_vectors.txt");
    var lines = std.mem.tokenizeScalar(u8, data, '\n');
    var count: usize = 0;
    var valid: usize = 0;
    while (lines.next()) |line| {
        if (line[0] == '#') continue;
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        const expected = fields.next().?;
        _ = fields.next().?; // EIP-7951 gas (6900); RIP-7212 charges 3450 for the same result.
        const hex = fields.next().?;
        var input: [160]u8 = undefined;
        try testing.expectEqual(@as(usize, 320), hex.len);
        _ = try std.fmt.hexToBytes(&input, hex);

        const result = try p256Verify(testing.allocator, &input, P256_VERIFY_GAS);
        defer result.deinit(testing.allocator);
        try testing.expectEqual(P256_VERIFY_GAS, result.gas_used);
        if (expected[0] == '1') {
            try testing.expectEqual(@as(usize, 32), result.output.len);
            try testing.expectEqualSlices(u8, &(@as([31]u8, @splat(0)) ++ [_]u8{1}), result.output);
            valid += 1;
        } else {
            try testing.expectEqual(@as(usize, 0), result.output.len);
        }
        count += 1;
    }
    try testing.expectEqual(@as(usize, 782), count);
    try testing.expectEqual(@as(usize, 567), valid);
}

test "Granite BN254 pairing limit: 112,687 bytes allowed size, above rejected" {
    // 112,687 is not a multiple of 192, so the largest well-formed input is 586 pairs.
    var buf: [BN254_PAIRING_MAX_INPUT_GRANITE + 1]u8 = undefined;
    @memset(&buf, 0);
    try testing.expectError(error.InvalidInput, bn254PairingGranite(testing.allocator, &buf, std.math.maxInt(u64)));
    // Inside the limit the call reaches the BN254 implementation (infinity pairs succeed).
    const pairs = 586 * 192;
    try testing.expect(pairs <= BN254_PAIRING_MAX_INPUT_GRANITE);
    const ok = try bn254PairingGranite(testing.allocator, buf[0..pairs], std.math.maxInt(u64));
    defer ok.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, 45_000 + 34_000 * 586), ok.gas_used);
}

test "Jovian BN254 pairing limit: 427 pairs allowed, 428 rejected" {
    var buf: [428 * 192]u8 = undefined;
    @memset(&buf, 0);
    try testing.expectError(error.InvalidInput, bn254PairingJovian(testing.allocator, &buf, std.math.maxInt(u64)));
    const ok = try bn254PairingJovian(testing.allocator, buf[0 .. 427 * 192], std.math.maxInt(u64));
    defer ok.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, 45_000 + 34_000 * 427), ok.gas_used);
}

test "entries per spec" {
    try testing.expectEqual(@as(usize, 0), entries(.ECOTONE).len);
    try testing.expectEqual(@as(usize, 1), entries(.FJORD).len);
    try testing.expectEqual(@as(usize, 2), entries(.GRANITE).len);
    try testing.expectEqual(@as(usize, 2), entries(.HOLOCENE).len);
    try testing.expectEqual(@as(usize, 5), entries(.ISTHMUS).len);
    try testing.expectEqual(@as(usize, 5), entries(.JOVIAN).len);
    try testing.expect(entries(.GRANITE)[1].execute == &bn254PairingGranite);
    try testing.expect(entries(.JOVIAN)[1].execute == &bn254PairingJovian);
    try testing.expect(entries(.ISTHMUS)[2].execute == &bls12G1MsmIsthmus);
    try testing.expect(entries(.JOVIAN)[2].execute == &bls12G1MsmJovian);
}

test "isOpPrecompile gates 0x100 on Fjord" {
    try testing.expect(!isOpPrecompile(P256_VERIFY_ADDRESS, .ECOTONE));
    try testing.expect(isOpPrecompile(P256_VERIFY_ADDRESS, .FJORD));
    try testing.expect(isOpPrecompile(P256_VERIFY_ADDRESS, .JOVIAN));
    try testing.expect(!isOpPrecompile(BN254_PAIRING_ADDRESS, .JOVIAN));
}

test "overrides adapter: P256 success, out of gas, and limit failure" {
    const list = overrides(TestOverride, .JOVIAN);
    try testing.expectEqual(@as(usize, 5), list.len);
    try testing.expectEqual(P256_VERIFY_ADDRESS.toU256(), list[0].address.toU256());

    const ok = try list[0].execute(testing.allocator, &rip7212_reference, 10_000);
    defer testing.allocator.free(ok.output);
    try testing.expect(ok.success);
    try testing.expectEqual(@as(u64, 3450), ok.gas_used);
    try testing.expectEqual(@as(u8, 1), ok.output[31]);

    const oog = try list[0].execute(testing.allocator, &rip7212_reference, 100);
    try testing.expect(!oog.success);
    try testing.expectEqual(@as(u64, 100), oog.gas_used);

    var big: [BN254_PAIRING_MAX_INPUT_JOVIAN + 192]u8 = undefined;
    @memset(&big, 0);
    const too_big = try list[1].execute(testing.allocator, &big, 5_000_000);
    try testing.expect(!too_big.success);
    try testing.expectEqual(@as(u64, 5_000_000), too_big.gas_used);
}

test "overrides adapter: invalid P256 signature succeeds with empty output" {
    var input = rip7212_reference;
    input[0] ^= 1;
    const list = overrides(TestOverride, .FJORD);
    const result = try list[0].execute(testing.allocator, &input, 10_000);
    defer testing.allocator.free(result.output);
    try testing.expect(result.success);
    try testing.expectEqual(@as(usize, 0), result.output.len);
    try testing.expectEqual(@as(u64, 3450), result.gas_used);
}

fn unknownFailurePrecompile(_: std.mem.Allocator, _: []const u8, _: u64) PrecompileError!PrecompileResult {
    return error.Unknown;
}

fn failingPrecompile(_: std.mem.Allocator, _: []const u8, _: u64) PrecompileError!PrecompileResult {
    return error.ExecutionError;
}

test "overrides adapter propagates non-consensus precompile errors instead of halting" {
    const unknown = adapt(TestOverride, unknownFailurePrecompile);
    try testing.expectError(error.Unknown, unknown(testing.allocator, &.{}, 1_000));
    const failing = adapt(TestOverride, failingPrecompile);
    try testing.expectError(error.ExecutionError, failing(testing.allocator, &.{}, 1_000));
}

test "overrides pre-Fjord is empty" {
    try testing.expectEqual(@as(usize, 0), overrides(TestOverride, .BEDROCK).len);
    try testing.expectEqual(@as(usize, 0), overrides(TestOverride, .ECOTONE).len);
}
