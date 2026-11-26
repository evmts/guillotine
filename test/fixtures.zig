//! Differential tests over the checked-in `fixtures/` corpus.
//!
//! Each fixture directory holds `bytecode.txt` (deployment or runtime code,
//! hex) and `calldata.txt` (hex). `DifferentialTestor` deploys deployment
//! code, then runs the call on Guillotine (traced and untraced) and on
//! MinimalEvm, and fails on any success, gas, output or trace mismatch.
//!
//! Not listed, because they are not valid inputs for a differential run:
//! - `opcodes-block-1`, `opcodes-control`, `opcodes-environmental-2`: 80,001 to
//!   100,001 bytes of runtime code. That exceeds the 16-bit program counter
//!   (65,535 bytes) of the default `BytecodeConfig`; EIP-170 caps deployed code
//!   at 24,576 bytes, so Guillotine fails these by design while MinimalEvm has
//!   no limit.
//! - `opcodes-context`, `precompile-pointevaluation`, `usdc-proxy`: their
//!   `bytecode.txt` or `calldata.txt` contains non-hex characters.

const std = @import("std");
const DifferentialTestor = @import("differential/differential_testor.zig").DifferentialTestor;

const max_fixture_bytes = 4 * 1024 * 1024;

fn readHex(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(max_fixture_bytes));
    defer allocator.free(text);
    var hex = std.mem.trim(u8, text, " \t\r\n");
    if (std.mem.startsWith(u8, hex, "0x") or std.mem.startsWith(u8, hex, "0X")) hex = hex[2..];
    if (hex.len % 2 != 0) return error.OddNumberOfDigits;
    const bytes = try allocator.alloc(u8, hex.len / 2);
    errdefer allocator.free(bytes);
    _ = try std.fmt.hexToBytes(bytes, hex);
    return bytes;
}

fn runFixture(comptime name: []const u8) !void {
    const allocator = std.testing.allocator;
    const bytecode = try readHex(allocator, "fixtures/" ++ name ++ "/bytecode.txt");
    defer allocator.free(bytecode);
    const calldata = try readHex(allocator, "fixtures/" ++ name ++ "/calldata.txt");
    defer allocator.free(calldata);

    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    try testor.test_bytecode_with_calldata(bytecode, calldata);
}

test "fixture: aave-v3-pool" {
    try runFixture("aave-v3-pool");
}

test "fixture: compound-cusdc" {
    try runFixture("compound-cusdc");
}

test "fixture: erc20-approval-transfer" {
    try runFixture("erc20-approval-transfer");
}

test "fixture: erc20-mint" {
    try runFixture("erc20-mint");
}

test "fixture: erc20-transfer" {
    try runFixture("erc20-transfer");
}

test "fixture: opcodes-arithmetic" {
    try runFixture("opcodes-arithmetic");
}

test "fixture: opcodes-arithmetic-advanced" {
    try runFixture("opcodes-arithmetic-advanced");
}

test "fixture: opcodes-bitwise" {
    try runFixture("opcodes-bitwise");
}

test "fixture: opcodes-block-2" {
    try runFixture("opcodes-block-2");
}

test "fixture: opcodes-comparison" {
    try runFixture("opcodes-comparison");
}

test "fixture: opcodes-crypto" {
    try runFixture("opcodes-crypto");
}

test "fixture: opcodes-data" {
    try runFixture("opcodes-data");
}

test "fixture: opcodes-dup" {
    try runFixture("opcodes-dup");
}

test "fixture: opcodes-environmental-1" {
    try runFixture("opcodes-environmental-1");
}

test "fixture: opcodes-jump-basic" {
    try runFixture("opcodes-jump-basic");
}

test "fixture: opcodes-log" {
    try runFixture("opcodes-log");
}

test "fixture: opcodes-memory" {
    try runFixture("opcodes-memory");
}

test "fixture: opcodes-push-pop" {
    try runFixture("opcodes-push-pop");
}

test "fixture: opcodes-storage-cold" {
    try runFixture("opcodes-storage-cold");
}

test "fixture: opcodes-storage-warm" {
    try runFixture("opcodes-storage-warm");
}

test "fixture: opcodes-swap" {
    try runFixture("opcodes-swap");
}

test "fixture: opcodes-system" {
    try runFixture("opcodes-system");
}

test "fixture: precompile-blake2f" {
    try runFixture("precompile-blake2f");
}

test "fixture: precompile-bn256add" {
    try runFixture("precompile-bn256add");
}

test "fixture: precompile-bn256mul" {
    try runFixture("precompile-bn256mul");
}

test "fixture: precompile-bn256pairing" {
    try runFixture("precompile-bn256pairing");
}

test "fixture: precompile-ecrecover" {
    try runFixture("precompile-ecrecover");
}

test "fixture: precompile-identity" {
    try runFixture("precompile-identity");
}

test "fixture: precompile-modexp" {
    try runFixture("precompile-modexp");
}

test "fixture: precompile-ripemd160" {
    try runFixture("precompile-ripemd160");
}

test "fixture: precompile-sha256" {
    try runFixture("precompile-sha256");
}

test "fixture: snailtracer" {
    try runFixture("snailtracer");
}

test "fixture: ten-thousand-hashes" {
    try runFixture("ten-thousand-hashes");
}

test "fixture: uniswap-v2-router" {
    try runFixture("uniswap-v2-router");
}

test "fixture: uniswap-v3-pool-eth-usdc" {
    try runFixture("uniswap-v3-pool-eth-usdc");
}

test "fixture: weth-mainnet" {
    try runFixture("weth-mainnet");
}
