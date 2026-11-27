//! EIP-161 state clearing in `Evm.call`: a touched account that is empty when the
//! transaction ends is deleted from Spurious Dragon on, an untouched one is kept,
//! and a touch made by a call that failed counts for nothing. Before Spurious
//! Dragon nothing is deleted and the fee payment creates the coinbase account
//! even when it pays nothing.

const std = @import("std");
const testing = std.testing;
const evm = @import("evm");
const primitives = @import("voltaire");
const Address = primitives.Address;
const crypto = @import("crypto").Crypto;

const sender = Address{ .bytes = [_]u8{0x51} ++ @as([19]u8, @splat(0)) };
const coinbase = Address{ .bytes = [_]u8{0xC0} ++ @as([19]u8, @splat(0)) };
/// An account that exists and is empty: nonce 0, balance 0, no code.
const empty = Address{ .bytes = [_]u8{0xEE} ++ @as([19]u8, @splat(0)) };
const outer = Address{ .bytes = [_]u8{0xA1} ++ @as([19]u8, @splat(0)) };
const inner = Address{ .bytes = [_]u8{0xB2} ++ @as([19]u8, @splat(0)) };
const zero_hash = @as([32]u8, @splat(0));
const empty_account = evm.Account{ .balance = 0, .nonce = 0, .code_hash = zero_hash, .storage_root = zero_hash };

/// PUSH1 0 (x4: out size, out offset, in size, in offset), PUSH1 0 (value),
/// PUSH20 `to`, PUSH2 0xffff (gas), CALL, POP: a zero-value call to `to`.
fn zeroValueCall(to: Address) [36]u8 {
    return [_]u8{ 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x73 } ++ to.bytes ++ [_]u8{ 0x61, 0xff, 0xff, 0xf1, 0x50 };
}

test "EIP-161: an empty account touched by a zero-value CALL is deleted from Spurious Dragon, kept before" {
    const code = zeroValueCall(empty) ++ [_]u8{0x00};
    const block = evm.BlockInfo{ .chain_id = 1, .number = 1, .timestamp = 1, .difficulty = 1, .gas_limit = 30_000_000, .coinbase = coinbase, .base_fee = 0, .prev_randao = zero_hash };
    inline for (.{
        .{ evm.Hardfork.TANGERINE_WHISTLE, false },
        .{ evm.Hardfork.SPURIOUS_DRAGON, true },
        .{ evm.Hardfork.BYZANTIUM, true },
        .{ evm.Hardfork.LONDON, true },
        .{ evm.Hardfork.PRAGUE, true },
    }) |case| {
        const Vm = evm.Evm(.{ .eips = .{ .hardfork = case[0] } });
        // Run the same transaction on a state that has the empty account and on one
        // that never had it.
        var roots: [2][32]u8 = undefined;
        for ([_]bool{ true, false }, &roots) |with_empty_account, *root| {
            var db = evm.Database.init(testing.allocator);
            defer db.deinit();
            try db.set_account(sender.bytes, .{ .balance = 1_000_000, .nonce = 0, .code_hash = zero_hash, .storage_root = zero_hash });
            try db.set_account(outer.bytes, .{ .balance = 0, .nonce = 1, .code_hash = try db.set_code(&code), .storage_root = zero_hash });
            if (with_empty_account) try db.set_account(empty.bytes, empty_account);

            var vm = try Vm.init(testing.allocator, &db, block, .{ .gas_limit = 200_000, .coinbase = coinbase, .chain_id = 1 }, 0, sender);
            defer vm.deinit();
            var result = vm.call(.{ .call = .{ .caller = sender, .to = outer, .value = 0, .input = &.{}, .gas = 200_000 } });
            defer result.deinit(testing.allocator);
            try testing.expect(result.success);

            if (with_empty_account) try testing.expectEqual(!case[1], db.account_exists(empty.bytes));
            root.* = try db.get_state_root();
        }
        // With EIP-161 the touched empty account is gone and both states agree: the
        // state root does not depend on it. Before EIP-161 every message call
        // creates its target, so both states hold the account and agree as well.
        try testing.expectEqualSlices(u8, &roots[1], &roots[0]);
    }
}

test "EIP-161: state root with a pruned account equals the root of a state that never had it" {
    const London = evm.Evm(.{ .eips = .{ .hardfork = .LONDON } });
    const block = evm.BlockInfo{ .chain_id = 1, .number = 1, .timestamp = 1, .difficulty = 1, .gas_limit = 30_000_000, .coinbase = coinbase, .base_fee = 0, .prev_randao = zero_hash };
    var db = evm.Database.init(testing.allocator);
    defer db.deinit();
    try db.set_account(sender.bytes, .{ .balance = 1_000_000, .nonce = 0, .code_hash = zero_hash, .storage_root = zero_hash });
    try db.set_account(empty.bytes, empty_account);
    const root_with_empty = try db.get_state_root();

    // The transaction calls the empty account directly, with no value.
    var vm = try London.init(testing.allocator, &db, block, .{ .gas_limit = 100_000, .coinbase = coinbase, .chain_id = 1 }, 0, sender);
    defer vm.deinit();
    var result = vm.call(.{ .call = .{ .caller = sender, .to = empty, .value = 0, .input = &.{}, .gas = 100_000 } });
    defer result.deinit(testing.allocator);
    try testing.expect(result.success);
    try testing.expect(!db.account_exists(empty.bytes));

    // Expected post-state, built by hand: only the sender, with nonce 1.
    var expected = evm.Database.init(testing.allocator);
    defer expected.deinit();
    try expected.set_account(sender.bytes, .{ .balance = 1_000_000, .nonce = 1, .code_hash = zero_hash, .storage_root = zero_hash });
    const root_after = try db.get_state_root();
    try testing.expectEqualSlices(u8, &(try expected.get_state_root()), &root_after);
    try testing.expect(!std.mem.eql(u8, &root_with_empty, &root_after));
}

test "EIP-161: an empty account the transaction does not touch is kept" {
    // The transaction calls a contract that only stops.
    const block = evm.BlockInfo{ .chain_id = 1, .number = 1, .timestamp = 1, .difficulty = 1, .gas_limit = 30_000_000, .coinbase = coinbase, .base_fee = 0, .prev_randao = zero_hash };
    inline for (.{ evm.Hardfork.SPURIOUS_DRAGON, evm.Hardfork.LONDON, evm.Hardfork.PRAGUE }) |hardfork| {
        const Vm = evm.Evm(.{ .eips = .{ .hardfork = hardfork } });
        var db = evm.Database.init(testing.allocator);
        defer db.deinit();
        try db.set_account(sender.bytes, .{ .balance = 1_000_000, .nonce = 0, .code_hash = zero_hash, .storage_root = zero_hash });
        try db.set_account(outer.bytes, .{ .balance = 0, .nonce = 1, .code_hash = try db.set_code(&[_]u8{0x00}), .storage_root = zero_hash });
        try db.set_account(empty.bytes, empty_account);

        var vm = try Vm.init(testing.allocator, &db, block, .{ .gas_limit = 200_000, .coinbase = coinbase, .chain_id = 1 }, 0, sender);
        defer vm.deinit();
        var result = vm.call(.{ .call = .{ .caller = sender, .to = outer, .value = 0, .input = &.{}, .gas = 200_000 } });
        defer result.deinit(testing.allocator);
        try testing.expect(result.success);
        try testing.expect(db.account_exists(empty.bytes));
    }
}

test "EIP-161: a touch made by a call that fails is reverted and deletes nothing" {
    // `inner` touches the empty account and then halts on INVALID.
    const inner_code = zeroValueCall(empty) ++ [_]u8{0xfe};
    // `outer` calls `inner`, ignores the failure and stops.
    const outer_code = zeroValueCall(inner) ++ [_]u8{0x00};
    const block = evm.BlockInfo{ .chain_id = 1, .number = 1, .timestamp = 1, .difficulty = 1, .gas_limit = 30_000_000, .coinbase = coinbase, .base_fee = 0, .prev_randao = zero_hash };
    inline for (.{ evm.Hardfork.SPURIOUS_DRAGON, evm.Hardfork.LONDON, evm.Hardfork.PRAGUE }) |hardfork| {
        const Vm = evm.Evm(.{ .eips = .{ .hardfork = hardfork } });
        // Nested failure: the transaction succeeds, the touching frame did not.
        {
            var db = evm.Database.init(testing.allocator);
            defer db.deinit();
            try db.set_account(sender.bytes, .{ .balance = 1_000_000, .nonce = 0, .code_hash = zero_hash, .storage_root = zero_hash });
            try db.set_account(outer.bytes, .{ .balance = 0, .nonce = 1, .code_hash = try db.set_code(&outer_code), .storage_root = zero_hash });
            try db.set_account(inner.bytes, .{ .balance = 0, .nonce = 1, .code_hash = try db.set_code(&inner_code), .storage_root = zero_hash });
            try db.set_account(empty.bytes, empty_account);

            var vm = try Vm.init(testing.allocator, &db, block, .{ .gas_limit = 300_000, .coinbase = coinbase, .chain_id = 1 }, 0, sender);
            defer vm.deinit();
            var result = vm.call(.{ .call = .{ .caller = sender, .to = outer, .value = 0, .input = &.{}, .gas = 300_000 } });
            defer result.deinit(testing.allocator);
            try testing.expect(result.success);
            try testing.expect(db.account_exists(empty.bytes));
        }
        // Top-level failure: the whole transaction's touches are dropped.
        {
            var db = evm.Database.init(testing.allocator);
            defer db.deinit();
            try db.set_account(sender.bytes, .{ .balance = 1_000_000, .nonce = 0, .code_hash = zero_hash, .storage_root = zero_hash });
            try db.set_account(inner.bytes, .{ .balance = 0, .nonce = 1, .code_hash = try db.set_code(&inner_code), .storage_root = zero_hash });
            try db.set_account(empty.bytes, empty_account);

            var vm = try Vm.init(testing.allocator, &db, block, .{ .gas_limit = 300_000, .coinbase = coinbase, .chain_id = 1 }, 0, sender);
            defer vm.deinit();
            var result = vm.call(.{ .call = .{ .caller = sender, .to = inner, .value = 0, .input = &.{}, .gas = 300_000 } });
            defer result.deinit(testing.allocator);
            try testing.expect(!result.success);
            try testing.expectEqual(@as(?[]const u8, null), result.error_info);
            try testing.expect(db.account_exists(empty.bytes));
            // The failed transaction still counts: the sender's nonce moved.
            try testing.expectEqual(@as(u64, 1), try db.get_nonce(sender.bytes));
        }
    }
}

test "EIP-161: STATICCALL and SELFDESTRUCT touch their target and beneficiary" {
    // PUSH1 0 (x4), PUSH20 empty, PUSH2 0xffff, STATICCALL, POP, STOP.
    const staticcall_code = [_]u8{ 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x73 } ++ empty.bytes ++ [_]u8{ 0x61, 0xff, 0xff, 0xfa, 0x50, 0x00 };
    // PUSH20 empty, SELFDESTRUCT: the contract holds nothing, so nothing is sent.
    const selfdestruct_code = [_]u8{0x73} ++ empty.bytes ++ [_]u8{0xff};
    const London = evm.Evm(.{ .eips = .{ .hardfork = .LONDON } });
    const block = evm.BlockInfo{ .chain_id = 1, .number = 1, .timestamp = 1, .difficulty = 1, .gas_limit = 30_000_000, .coinbase = coinbase, .base_fee = 0, .prev_randao = zero_hash };
    for ([_][]const u8{ &staticcall_code, &selfdestruct_code }) |code| {
        var db = evm.Database.init(testing.allocator);
        defer db.deinit();
        try db.set_account(sender.bytes, .{ .balance = 1_000_000, .nonce = 0, .code_hash = zero_hash, .storage_root = zero_hash });
        try db.set_account(outer.bytes, .{ .balance = 0, .nonce = 1, .code_hash = try db.set_code(code), .storage_root = zero_hash });
        try db.set_account(empty.bytes, empty_account);

        var vm = try London.init(testing.allocator, &db, block, .{ .gas_limit = 300_000, .coinbase = coinbase, .chain_id = 1 }, 0, sender);
        defer vm.deinit();
        var result = vm.call(.{ .call = .{ .caller = sender, .to = outer, .value = 0, .input = &.{}, .gas = 300_000 } });
        defer result.deinit(testing.allocator);
        try testing.expect(result.success);
        try testing.expect(!db.account_exists(empty.bytes));
    }
}

test "EIP-161: a touched account that is not empty is kept" {
    const code = zeroValueCall(empty) ++ [_]u8{0x00};
    const London = evm.Evm(.{ .eips = .{ .hardfork = .LONDON } });
    const block = evm.BlockInfo{ .chain_id = 1, .number = 1, .timestamp = 1, .difficulty = 1, .gas_limit = 30_000_000, .coinbase = coinbase, .base_fee = 0, .prev_randao = zero_hash };
    const kept = [_]evm.Account{
        .{ .balance = 1, .nonce = 0, .code_hash = zero_hash, .storage_root = zero_hash },
        .{ .balance = 0, .nonce = 1, .code_hash = zero_hash, .storage_root = zero_hash },
    };
    for (kept) |account| {
        var db = evm.Database.init(testing.allocator);
        defer db.deinit();
        try db.set_account(sender.bytes, .{ .balance = 1_000_000, .nonce = 0, .code_hash = zero_hash, .storage_root = zero_hash });
        try db.set_account(outer.bytes, .{ .balance = 0, .nonce = 1, .code_hash = try db.set_code(&code), .storage_root = zero_hash });
        try db.set_account(empty.bytes, account);

        var vm = try London.init(testing.allocator, &db, block, .{ .gas_limit = 200_000, .coinbase = coinbase, .chain_id = 1 }, 0, sender);
        defer vm.deinit();
        var result = vm.call(.{ .call = .{ .caller = sender, .to = outer, .value = 0, .input = &.{}, .gas = 200_000 } });
        defer result.deinit(testing.allocator);
        try testing.expect(result.success);
        try testing.expectEqual(account, (try db.get_account(empty.bytes)).?);
    }
}

test "coinbase: a zero fee creates the account before Spurious Dragon and never after" {
    // Gas price 0: the block producer is paid nothing.
    const block = evm.BlockInfo{ .chain_id = 1, .number = 1, .timestamp = 1, .difficulty = 1, .gas_limit = 30_000_000, .coinbase = coinbase, .base_fee = 0, .prev_randao = zero_hash };
    const receiver = Address{ .bytes = [_]u8{0x7A} ++ @as([19]u8, @splat(0)) };
    inline for (.{
        .{ evm.Hardfork.FRONTIER, true },
        .{ evm.Hardfork.HOMESTEAD, true },
        .{ evm.Hardfork.TANGERINE_WHISTLE, true },
        .{ evm.Hardfork.SPURIOUS_DRAGON, false },
        .{ evm.Hardfork.BERLIN, false },
        .{ evm.Hardfork.CANCUN, false },
    }) |case| {
        const Vm = evm.Evm(.{ .eips = .{ .hardfork = case[0] } });
        // The coinbase is absent, or present and empty, before the transaction.
        for ([_]bool{ false, true }) |coinbase_exists| {
            var db = evm.Database.init(testing.allocator);
            defer db.deinit();
            try db.set_account(sender.bytes, .{ .balance = 1_000_000, .nonce = 0, .code_hash = zero_hash, .storage_root = zero_hash });
            if (coinbase_exists) try db.set_account(coinbase.bytes, empty_account);

            var vm = try Vm.init(testing.allocator, &db, block, .{ .gas_limit = 100_000, .coinbase = coinbase, .chain_id = 1 }, 0, sender);
            defer vm.deinit();
            var result = vm.call(.{ .call = .{ .caller = sender, .to = receiver, .value = 1, .input = &.{}, .gas = 100_000 } });
            defer result.deinit(testing.allocator);
            try testing.expect(result.success);

            // Frontier..Tangerine Whistle: the account exists afterwards, empty.
            // Spurious Dragon+: it is not created, and an empty one is deleted.
            try testing.expectEqual(case[1], db.account_exists(coinbase.bytes));
            if (case[1]) try testing.expect((try db.get_account(coinbase.bytes)).?.is_empty());

            // The state root agrees with the state built by hand.
            var expected = evm.Database.init(testing.allocator);
            defer expected.deinit();
            try expected.set_account(sender.bytes, .{ .balance = 999_999, .nonce = 1, .code_hash = zero_hash, .storage_root = zero_hash });
            try expected.set_account(receiver.bytes, .{ .balance = 1, .nonce = 0, .code_hash = zero_hash, .storage_root = zero_hash });
            if (case[1]) try expected.set_account(coinbase.bytes, empty_account);
            try testing.expectEqualSlices(u8, &(try expected.get_state_root()), &(try db.get_state_root()));
        }
    }
}

test "coinbase: a paid fee keeps the account on every fork" {
    const block = evm.BlockInfo{ .chain_id = 1, .number = 1, .timestamp = 1, .difficulty = 1, .gas_limit = 30_000_000, .coinbase = coinbase, .base_fee = 0, .prev_randao = zero_hash };
    inline for (.{ evm.Hardfork.FRONTIER, evm.Hardfork.SPURIOUS_DRAGON, evm.Hardfork.LONDON }) |hardfork| {
        const Vm = evm.Evm(.{ .eips = .{ .hardfork = hardfork } });
        var db = evm.Database.init(testing.allocator);
        defer db.deinit();
        try db.set_account(sender.bytes, .{ .balance = 1_000_000, .nonce = 0, .code_hash = zero_hash, .storage_root = zero_hash });
        var vm = try Vm.init(testing.allocator, &db, block, .{ .gas_limit = 100_000, .coinbase = coinbase, .chain_id = 1 }, 2, sender);
        defer vm.deinit();
        var result = vm.call(.{ .call = .{ .caller = sender, .to = sender, .value = 0, .input = &.{}, .gas = 100_000 } });
        defer result.deinit(testing.allocator);
        try testing.expect(result.success);
        try testing.expectEqual(@as(u256, 42_000), try db.get_balance(coinbase.bytes));
    }
}

test "EIP-161: the RIPEMD-160 touch survives a failed nested call, not a failed transaction" {
    const ripemd160 = Address.fromU256(3);
    // `inner` calls an ordinary empty account and the precompile, both with no
    // value, and halts on INVALID.
    const inner_code = zeroValueCall(empty) ++ zeroValueCall(ripemd160) ++ [_]u8{0xfe};
    const outer_code = zeroValueCall(inner) ++ [_]u8{0x00};
    const Byzantium = evm.Evm(.{ .eips = .{ .hardfork = .BYZANTIUM } });
    const block = evm.BlockInfo{ .chain_id = 1, .number = 1, .timestamp = 1, .difficulty = 1, .gas_limit = 30_000_000, .coinbase = coinbase, .base_fee = 0, .prev_randao = zero_hash };
    for ([_]bool{ true, false }) |nested| {
        var db = evm.Database.init(testing.allocator);
        defer db.deinit();
        try db.set_account(sender.bytes, .{ .balance = 1_000_000, .nonce = 0, .code_hash = zero_hash, .storage_root = zero_hash });
        try db.set_account(outer.bytes, .{ .balance = 0, .nonce = 1, .code_hash = try db.set_code(&outer_code), .storage_root = zero_hash });
        try db.set_account(inner.bytes, .{ .balance = 0, .nonce = 1, .code_hash = try db.set_code(&inner_code), .storage_root = zero_hash });
        try db.set_account(ripemd160.bytes, empty_account);
        try db.set_account(empty.bytes, empty_account);

        var vm = try Byzantium.init(testing.allocator, &db, block, .{ .gas_limit = 400_000, .coinbase = coinbase, .chain_id = 1 }, 0, sender);
        defer vm.deinit();
        var result = vm.call(.{ .call = .{ .caller = sender, .to = if (nested) outer else inner, .value = 0, .input = &.{}, .gas = 400_000 } });
        defer result.deinit(testing.allocator);
        try testing.expectEqual(nested, result.success);
        // Mainnet block 2,675,119: 0x03 was deleted although its toucher ran out
        // of gas. Only a nested failure passes that touch on.
        try testing.expectEqual(!nested, db.account_exists(ripemd160.bytes));
        // The ordinary account touched by the same failing frame is always kept.
        try testing.expect(db.account_exists(empty.bytes));
    }
}

test "EIP-7702: the refund for an existing authority follows EIP-161 pruning" {
    // Twenty cold SLOADs, 42100 gas: enough use for the one-fifth refund cap to
    // pass 12500 in full.
    var burn: [81]u8 = undefined;
    for (0..20) |i| {
        burn[i * 4] = 0x60;
        burn[i * 4 + 1] = @intCast(i);
        burn[i * 4 + 2] = 0x54;
        burn[i * 4 + 3] = 0x50;
    }
    burn[80] = 0x00;

    const Prague = evm.Evm(.{ .eips = .{ .hardfork = .PRAGUE } });
    const block = evm.BlockInfo{ .chain_id = 1, .number = 1, .timestamp = 1, .difficulty = 0, .gas_limit = 30_000_000, .coinbase = coinbase, .base_fee = 0, .prev_randao = zero_hash };
    const delegate = Address{ .bytes = [_]u8{0xDE} ++ @as([19]u8, @splat(0)) };
    const key: crypto.PrivateKey = @as([32]u8, @splat(0x42));
    const authority = (try crypto.unaudited_getPublicKey(key)).toAddress();
    var tuple = try primitives.Authorization.createAuthorization(testing.allocator, 1, delegate, 0, key);
    tuple.v -= 27;
    const list = [_]evm.Authorization{tuple};

    // The authority starts as an empty account that exists. In the first run a
    // transaction touches it first, so it is pruned and the later authorization
    // finds no account: no refund. In the second run nothing touches it, it still
    // exists, and the refund is due.
    for ([_]bool{ true, false }) |touched_first| {
        var db = evm.Database.init(testing.allocator);
        defer db.deinit();
        try db.set_account(sender.bytes, .{ .balance = 1_000_000, .nonce = 0, .code_hash = zero_hash, .storage_root = zero_hash });
        try db.set_account(outer.bytes, .{ .balance = 0, .nonce = 1, .code_hash = try db.set_code(&burn), .storage_root = zero_hash });
        try db.set_account(authority.bytes, empty_account);

        var vm = try Prague.init(testing.allocator, &db, block, .{ .gas_limit = 200_000, .coinbase = coinbase, .chain_id = 1 }, 0, sender);
        defer vm.deinit();
        if (touched_first) {
            var touch = vm.call(.{ .call = .{ .caller = sender, .to = authority, .value = 0, .input = &.{}, .gas = 200_000 } });
            defer touch.deinit(testing.allocator);
            try testing.expect(touch.success);
        }
        try testing.expectEqual(!touched_first, db.account_exists(authority.bytes));

        vm.context.authorization_list = &list;
        vm.context.is_set_code_transaction = true;
        var result = vm.call(.{ .call = .{ .caller = sender, .to = outer, .value = 0, .input = &.{}, .gas = 200_000 } });
        defer result.deinit(testing.allocator);
        try testing.expect(result.success);
        // 21000 + 25000 + 42100 = 88100, minus 12500 only for an authority in state.
        const gas_used: u64 = if (touched_first) 88_100 else 75_600;
        try testing.expectEqual(@as(u64, 200_000) - gas_used, result.gas_left);
        try testing.expectEqual(delegate, (try db.get_account(authority.bytes)).?.delegated_address.?);
    }
}
