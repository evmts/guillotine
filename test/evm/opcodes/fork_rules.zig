//! Fork rules and edge cases found by the official EEST state tests (tests@v21.0.3),
//! checked through the public `evm` module:
//! - RETURN/REVERT with size 0 ignore the offset (no memory expansion charge).
//! - EXP byte gas is 10 before Spurious Dragon (EIP-160) and 50 from it.
//! - Before Spurious Dragon a message call creates its missing target account,
//!   precompiles included, and a failed call reverts the creation.
//! - Opcodes introduced by a later fork are undefined, also inside fusions.
//! - BLOCKHASH serves `BlockInfo.block_hashes` for the 256 previous blocks only.
//! - Gas above the configured frame gas type is refused, not truncated.
//! - Step capture records each bytecode instruction exactly once.
const std = @import("std");
const evm = @import("evm");
const primitives = @import("voltaire");

const regression_block_info = evm.BlockInfo{
    .number = 1,
    .timestamp = 1000,
    .difficulty = 100,
    .gas_limit = 30000000,
    .coinbase = primitives.ZERO_ADDRESS,
    .base_fee = 0,
    .prev_randao = @as([32]u8, @splat(0)),
};
const regression_context = evm.TransactionContext{
    .gas_limit = 1000000,
    .coinbase = primitives.ZERO_ADDRESS,
    .chain_id = 1,
    .allow_gas_price_below_base_fee = true,
};
const regression_contract: primitives.Address = .{ .bytes = @as([19]u8, @splat(0)) ++ [_]u8{0x43} };
const regression_sender: primitives.Address = .{ .bytes = @as([19]u8, @splat(0)) ++ [_]u8{0x10} };

test "RETURN and REVERT with size 0 ignore the offset and charge no memory expansion" {
    // PUSH1 0 (size), PUSH32 2^256-1 (offset), RETURN / REVERT: 3 + 3 gas only.
    inline for (.{ @as(u8, 0xf3), @as(u8, 0xfd) }) |halt| {
        var db = evm.Database.init(std.testing.allocator);
        defer db.deinit();
        var vm = try evm.Evm(.{}).init(std.testing.allocator, &db, regression_block_info, regression_context, 0, regression_sender);
        defer vm.deinit();

        const code = [_]u8{ 0x60, 0x00, 0x7f } ++ @as([32]u8, @splat(0xff)) ++ [_]u8{halt};
        const code_hash = try db.set_code(&code);
        try db.set_account(regression_contract.bytes, evm.Account{ .balance = 0, .nonce = 0, .code_hash = code_hash, .storage_root = @as([32]u8, @splat(0)) });

        const result = vm.inner_call(.{ .call = .{ .caller = regression_sender, .to = regression_contract, .value = 0, .input = &.{}, .gas = 100000 } });
        try std.testing.expectEqual(halt == 0xf3, result.success);
        try std.testing.expectEqual(@as(u64, 100000 - 6), result.gas_left);
        try std.testing.expectEqual(@as(usize, 0), result.output.len);
    }
}

test "EXP byte gas is 10 before Spurious Dragon (EIP-160) and 50 from it" {
    // PUSH1 0xff (exponent, 1 byte), PUSH1 2 (base), EXP: 3 + 3 + 10 + byte gas.
    const Case = struct { hardfork: evm.Hardfork, gas: u64 };
    inline for ([_]Case{
        .{ .hardfork = .FRONTIER, .gas = 3 + 3 + 10 + 10 },
        .{ .hardfork = .TANGERINE_WHISTLE, .gas = 3 + 3 + 10 + 10 },
        .{ .hardfork = .SPURIOUS_DRAGON, .gas = 3 + 3 + 10 + 50 },
        .{ .hardfork = .CANCUN, .gas = 3 + 3 + 10 + 50 },
    }) |case| {
        var db = evm.Database.init(std.testing.allocator);
        defer db.deinit();
        var vm = try evm.Evm(.{ .eips = .{ .hardfork = case.hardfork } }).init(std.testing.allocator, &db, regression_block_info, regression_context, 0, regression_sender);
        defer vm.deinit();

        const code = [_]u8{ 0x60, 0xff, 0x60, 0x02, 0x0a };
        const code_hash = try db.set_code(&code);
        try db.set_account(regression_contract.bytes, evm.Account{ .balance = 0, .nonce = 0, .code_hash = code_hash, .storage_root = @as([32]u8, @splat(0)) });

        const result = vm.inner_call(.{ .call = .{ .caller = regression_sender, .to = regression_contract, .value = 0, .input = &.{}, .gas = 100000 } });
        try std.testing.expect(result.success);
        try std.testing.expectEqual(case.gas, 100000 - result.gas_left);
    }
}

test "Before Spurious Dragon a call creates its missing target, precompiles included, unless it fails" {
    const ripemd: primitives.Address = .{ .bytes = @as([19]u8, @splat(0)) ++ [_]u8{0x03} };
    const absent: primitives.Address = .{ .bytes = @as([19]u8, @splat(0)) ++ [_]u8{0x99} };
    const Case = struct { hardfork: evm.Hardfork, to: primitives.Address, gas: u64, success: bool, created: bool };
    inline for ([_]Case{
        // RIPEMD-160 of empty input costs 600 gas.
        .{ .hardfork = .FRONTIER, .to = ripemd, .gas = 1000, .success = true, .created = true },
        .{ .hardfork = .TANGERINE_WHISTLE, .to = ripemd, .gas = 1000, .success = true, .created = true },
        // An out-of-gas precompile call reverts the creation.
        .{ .hardfork = .FRONTIER, .to = ripemd, .gas = 10, .success = false, .created = false },
        .{ .hardfork = .FRONTIER, .to = absent, .gas = 1000, .success = true, .created = true },
        // EIP-161: zero-value calls no longer create accounts.
        .{ .hardfork = .SPURIOUS_DRAGON, .to = ripemd, .gas = 1000, .success = true, .created = false },
        .{ .hardfork = .SPURIOUS_DRAGON, .to = absent, .gas = 1000, .success = true, .created = false },
    }) |case| {
        var db = evm.Database.init(std.testing.allocator);
        defer db.deinit();
        var vm = try evm.Evm(.{ .eips = .{ .hardfork = case.hardfork } }).init(std.testing.allocator, &db, regression_block_info, regression_context, 0, regression_sender);
        defer vm.deinit();

        const result = vm.inner_call(.{ .call = .{ .caller = regression_sender, .to = case.to, .value = 0, .input = &.{}, .gas = case.gas } });
        try std.testing.expectEqual(case.success, result.success);
        try std.testing.expectEqual(case.created, (try db.get_account(case.to.bytes)) != null);
    }
}

test "Each fork-introduced opcode is undefined one fork earlier and defined from its fork" {
    // Seven zero words feed any opcode's inputs, so a defined opcode halts normally
    // (or reverts) and keeps gas, while an undefined one consumes all of it.
    const Case = struct { opcode: u8, before: evm.Hardfork, from: evm.Hardfork };
    inline for ([_]Case{
        .{ .opcode = 0xf4, .before = .FRONTIER, .from = .HOMESTEAD }, // DELEGATECALL
        .{ .opcode = 0x3d, .before = .SPURIOUS_DRAGON, .from = .BYZANTIUM }, // RETURNDATASIZE
        .{ .opcode = 0x3e, .before = .SPURIOUS_DRAGON, .from = .BYZANTIUM }, // RETURNDATACOPY
        .{ .opcode = 0xfa, .before = .SPURIOUS_DRAGON, .from = .BYZANTIUM }, // STATICCALL
        .{ .opcode = 0xfd, .before = .SPURIOUS_DRAGON, .from = .BYZANTIUM }, // REVERT
        .{ .opcode = 0x1b, .before = .BYZANTIUM, .from = .CONSTANTINOPLE }, // SHL
        .{ .opcode = 0x1c, .before = .BYZANTIUM, .from = .CONSTANTINOPLE }, // SHR
        .{ .opcode = 0x1d, .before = .BYZANTIUM, .from = .CONSTANTINOPLE }, // SAR
        .{ .opcode = 0x3f, .before = .BYZANTIUM, .from = .CONSTANTINOPLE }, // EXTCODEHASH
        .{ .opcode = 0xf5, .before = .BYZANTIUM, .from = .CONSTANTINOPLE }, // CREATE2
        .{ .opcode = 0x46, .before = .PETERSBURG, .from = .ISTANBUL }, // CHAINID
        .{ .opcode = 0x47, .before = .PETERSBURG, .from = .ISTANBUL }, // SELFBALANCE
        .{ .opcode = 0x48, .before = .BERLIN, .from = .LONDON }, // BASEFEE
        .{ .opcode = 0x5f, .before = .MERGE, .from = .SHANGHAI }, // PUSH0
        .{ .opcode = 0x49, .before = .SHANGHAI, .from = .CANCUN }, // BLOBHASH
        .{ .opcode = 0x4a, .before = .SHANGHAI, .from = .CANCUN }, // BLOBBASEFEE
        .{ .opcode = 0x5c, .before = .SHANGHAI, .from = .CANCUN }, // TLOAD
        .{ .opcode = 0x5d, .before = .SHANGHAI, .from = .CANCUN }, // TSTORE
        .{ .opcode = 0x5e, .before = .SHANGHAI, .from = .CANCUN }, // MCOPY
        .{ .opcode = 0x1e, .before = .PRAGUE, .from = .OSAKA }, // CLZ
    }) |case| {
        inline for (.{ case.before, case.from }) |fork| {
            const defined = fork == case.from;
            var db = evm.Database.init(std.testing.allocator);
            defer db.deinit();
            var vm = try evm.Evm(.{ .eips = .{ .hardfork = fork } }).init(std.testing.allocator, &db, regression_block_info, regression_context, 0, regression_sender);
            defer vm.deinit();

            const code = [_]u8{ 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, case.opcode, 0x00 };
            const code_hash = try db.set_code(&code);
            try db.set_account(regression_contract.bytes, evm.Account{ .balance = 0, .nonce = 0, .code_hash = code_hash, .storage_root = @as([32]u8, @splat(0)) });

            const result = vm.inner_call(.{ .call = .{ .caller = regression_sender, .to = regression_contract, .value = 0, .input = &.{}, .gas = 100000 } });
            if (defined) {
                std.testing.expect(result.gas_left > 0) catch |err| {
                    std.log.err("opcode 0x{x:0>2} should be defined on {s}", .{ case.opcode, @tagName(fork) });
                    return err;
                };
            } else {
                std.testing.expect(!result.success and result.gas_left == 0) catch |err| {
                    std.log.err("opcode 0x{x:0>2} should be undefined on {s}", .{ case.opcode, @tagName(fork) });
                    return err;
                };
            }
        }
    }
}

test "A fusion containing an undefined opcode is not fused (PUSH0 PUSH0 REVERT before Shanghai)" {
    const Case = struct { hardfork: evm.Hardfork, defined: bool };
    inline for ([_]Case{ .{ .hardfork = .MERGE, .defined = false }, .{ .hardfork = .SHANGHAI, .defined = true } }) |case| {
        var db = evm.Database.init(std.testing.allocator);
        defer db.deinit();
        var vm = try evm.Evm(.{ .eips = .{ .hardfork = case.hardfork } }).init(std.testing.allocator, &db, regression_block_info, regression_context, 0, regression_sender);
        defer vm.deinit();

        const code = [_]u8{ 0x5f, 0x5f, 0xfd };
        const code_hash = try db.set_code(&code);
        try db.set_account(regression_contract.bytes, evm.Account{ .balance = 0, .nonce = 0, .code_hash = code_hash, .storage_root = @as([32]u8, @splat(0)) });

        const result = vm.inner_call(.{ .call = .{ .caller = regression_sender, .to = regression_contract, .value = 0, .input = &.{}, .gas = 100000 } });
        try std.testing.expect(!result.success);
        try std.testing.expectEqual(@as(u64, if (case.defined) 100000 - 4 else 0), result.gas_left);
    }
}

test "BLOCKHASH reads BlockInfo.block_hashes within the 256-block window only" {
    var hashes: [256][32]u8 = undefined;
    for (&hashes, 0..) |*hash, i| hash.* = @splat(@as(u8, @truncate(i + 1)));
    var block_info = regression_block_info;
    block_info.number = 300;
    block_info.block_hashes = &hashes;

    const Case = struct { push: []const u8, expected: ?[32]u8 };
    const cases = [_]Case{
        .{ .push = &.{ 0x61, 0x01, 0x2b }, .expected = hashes[0] }, // 299: newest
        .{ .push = &.{ 0x60, 0x2c }, .expected = hashes[255] }, // 44: oldest in window
        .{ .push = &.{ 0x60, 0x2b }, .expected = null }, // 43: outside window
        .{ .push = &.{ 0x61, 0x01, 0x2c }, .expected = null }, // 300: current block
        .{ .push = &.{ 0x68, 0x01, 0, 0, 0, 0, 0, 0, 0x01, 0x2b }, .expected = null }, // 2^64 + 299
    };
    for (cases) |case| {
        var db = evm.Database.init(std.testing.allocator);
        defer db.deinit();
        var vm = try evm.Evm(.{}).init(std.testing.allocator, &db, block_info, regression_context, 0, regression_sender);
        defer vm.deinit();

        // <push n> BLOCKHASH PUSH1 0 MSTORE PUSH1 32 PUSH1 0 RETURN
        var code_buf: [32]u8 = undefined;
        @memcpy(code_buf[0..case.push.len], case.push);
        const tail = [_]u8{ 0x40, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3 };
        @memcpy(code_buf[case.push.len..][0..tail.len], &tail);
        const code_hash = try db.set_code(code_buf[0 .. case.push.len + tail.len]);
        try db.set_account(regression_contract.bytes, evm.Account{ .balance = 0, .nonce = 0, .code_hash = code_hash, .storage_root = @as([32]u8, @splat(0)) });

        const result = vm.inner_call(.{ .call = .{ .caller = regression_sender, .to = regression_contract, .value = 0, .input = &.{}, .gas = 100000 } });
        try std.testing.expect(result.success);
        const expected: [32]u8 = case.expected orelse @splat(0);
        try std.testing.expectEqualSlices(u8, &expected, result.output);
    }
}

test "A call whose gas exceeds the frame gas type is refused, not truncated" {
    // On 64-bit targets the frame gas type is i64 whatever the block_gas_limit.
    var db = evm.Database.init(std.testing.allocator);
    defer db.deinit();
    var vm = try evm.Evm(.{}).init(std.testing.allocator, &db, regression_block_info, regression_context, 0, regression_sender);
    defer vm.deinit();

    const code = [_]u8{ 0x60, 0x01, 0x60, 0x02, 0x01, 0x00 };
    const code_hash = try db.set_code(&code);
    try db.set_account(regression_contract.bytes, evm.Account{ .balance = 0, .nonce = 0, .code_hash = code_hash, .storage_root = @as([32]u8, @splat(0)) });

    const too_much: u64 = @as(u64, std.math.maxInt(i64)) + 1;
    const refused_inner = vm.inner_call(.{ .call = .{ .caller = regression_sender, .to = regression_contract, .value = 0, .input = &.{}, .gas = too_much } });
    try std.testing.expect(!refused_inner.success);
    var refused_call = vm.call(.{ .call = .{ .caller = regression_sender, .to = regression_contract, .value = 0, .input = &.{}, .gas = too_much } });
    defer refused_call.deinit(std.testing.allocator);
    try std.testing.expect(!refused_call.success);

    const fits: u64 = std.math.maxInt(i32);
    const ran = vm.inner_call(.{ .call = .{ .caller = regression_sender, .to = regression_contract, .value = 0, .input = &.{}, .gas = fits } });
    try std.testing.expect(ran.success);
    try std.testing.expectEqual(fits - 9, ran.gas_left);
}

test "A configured block_gas_limit above i32 runs budgets above 2^31 exactly" {
    var db = evm.Database.init(std.testing.allocator);
    defer db.deinit();
    var vm = try evm.Evm(.{ .block_gas_limit = 3_000_000_000 }).init(std.testing.allocator, &db, regression_block_info, regression_context, 0, regression_sender);
    defer vm.deinit();

    const code = [_]u8{ 0x60, 0x01, 0x60, 0x02, 0x01, 0x00 };
    const code_hash = try db.set_code(&code);
    try db.set_account(regression_contract.bytes, evm.Account{ .balance = 0, .nonce = 0, .code_hash = code_hash, .storage_root = @as([32]u8, @splat(0)) });

    const result = vm.inner_call(.{ .call = .{ .caller = regression_sender, .to = regression_contract, .value = 0, .input = &.{}, .gas = 3_000_000_000 } });
    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(u64, 3_000_000_000 - 9), result.gas_left);
}

test "Step capture records each bytecode instruction once, fused or not" {
    const TracingEvm = evm.Evm(.{ .tracer_config = .{
        .enabled = true,
        .enable_validation = true,
        .enable_step_capture = true,
        .enable_pc_tracking = true,
        .enable_gas_tracking = true,
        .enable_debug_logging = false,
        .enable_advanced_trace = false,
    } });
    // PUSH1 2, PUSH1 3, ADD, STOP. Fusion turns PUSH1 3 + ADD into one synthetic handler.
    const code = [_]u8{ 0x60, 0x02, 0x60, 0x03, 0x01, 0x00 };
    var db = evm.Database.init(std.testing.allocator);
    defer db.deinit();
    var vm = try TracingEvm.init(std.testing.allocator, &db, regression_block_info, regression_context, 0, regression_sender);
    defer vm.deinit();
    const code_hash = try db.set_code(&code);
    try db.set_account(regression_contract.bytes, evm.Account{ .balance = 0, .nonce = 0, .code_hash = code_hash, .storage_root = @as([32]u8, @splat(0)) });

    var result = vm.call(.{ .call = .{ .caller = regression_sender, .to = regression_contract, .value = 0, .input = &.{}, .gas = 100000 } });
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.success);
    const steps = result.trace.?.steps;
    const expected = [_][]const u8{ "PUSH1", "PUSH1", "ADD", "STOP" };
    try std.testing.expectEqual(expected.len, steps.len);
    for (expected, steps, [_]u64{ 0, 2, 4, 5 }) |name, step, pc| {
        try std.testing.expectEqualStrings(name, step.opcode_name);
        try std.testing.expectEqual(pc, step.pc);
    }
    try std.testing.expectEqual(@as(u64, 3), steps[2].gas_cost);
}
