//! End-to-end tests of `Evm.call` as a transaction processor: EIP-2930 access
//! lists, EIP-7702 authorization lists, EIP-3607, transaction nonces, the
//! EIP-1559 base fee floor for legacy-priced transactions, checked EIP-4844 blob
//! fees and the fork-dependent intrinsic gas of creation transactions.
//!
//! Every test builds its own database and EVM and states the gas it expects to
//! the unit, so a change in admission or metering shows up as a number.

const std = @import("std");
const testing = std.testing;
const evm = @import("evm");
const primitives = @import("voltaire");
const Address = primitives.Address;
const crypto = @import("crypto").Crypto;

const sender = Address{ .bytes = [_]u8{0x51} ++ @as([19]u8, @splat(0)) };
const target = Address{ .bytes = [_]u8{0x7A} ++ @as([19]u8, @splat(0)) };
const coinbase = Address{ .bytes = [_]u8{0xC0} ++ @as([19]u8, @splat(0)) };
const zero_hash = @as([32]u8, @splat(0));

// PUSH1 1, SLOAD, POP, STOP: 3 + SLOAD + 2 gas.
const sload_code = [_]u8{ 0x60, 0x01, 0x54, 0x50, 0x00 };

test "EIP-2930: access list costs 2400 per address and 1900 per key and warms both" {
    const Berlin = evm.Evm(.{ .eips = .{ .hardfork = .BERLIN } });
    const block = evm.BlockInfo{ .chain_id = 1, .number = 1, .timestamp = 1, .difficulty = 1, .gas_limit = 30_000_000, .coinbase = coinbase, .base_fee = 0, .prev_randao = zero_hash };
    const keys = [_]u256{1};
    const cases = [_]struct { list: []const evm.AccessListEntry, gas_used: u64 }{
        // No list: 21000 + PUSH1 3 + cold SLOAD 2100 + POP 2.
        .{ .list = &.{}, .gas_used = 23_105 },
        // Address only: 2400 intrinsic, the slot is still cold.
        .{ .list = &.{.{ .address = target }}, .gas_used = 25_505 },
        // Address and key: 2400 + 1900 intrinsic, SLOAD is warm (100).
        .{ .list = &.{.{ .address = target, .storage_keys = &keys }}, .gas_used = 25_405 },
        // An unrelated address and two unrelated keys cost gas and warm nothing useful.
        .{ .list = &.{.{ .address = coinbase, .storage_keys = &[_]u256{ 7, 8 } }}, .gas_used = 23_105 + 2400 + 2 * 1900 },
    };
    for (cases) |case| {
        var db = evm.Database.init(testing.allocator);
        defer db.deinit();
        try db.set_account(sender.bytes, .{ .balance = 1_000_000, .nonce = 0, .code_hash = zero_hash, .storage_root = zero_hash });
        try db.set_account(target.bytes, .{ .balance = 0, .nonce = 1, .code_hash = try db.set_code(&sload_code), .storage_root = zero_hash });

        var vm = try Berlin.init(testing.allocator, &db, block, .{ .gas_limit = 100_000, .coinbase = coinbase, .chain_id = 1, .access_list = case.list }, 0, sender);
        defer vm.deinit();
        var result = vm.call(.{ .call = .{ .caller = sender, .to = target, .value = 0, .input = &.{}, .gas = 100_000 } });
        defer result.deinit(testing.allocator);

        try testing.expect(result.success);
        try testing.expectEqual(@as(?[]const u8, null), result.error_info);
        try testing.expectEqual(@as(u64, 100_000) - case.gas_used, result.gas_left);
    }
}

test "EIP-2930: the access list is part of the intrinsic gas, to the unit" {
    const Berlin = evm.Evm(.{ .eips = .{ .hardfork = .BERLIN } });
    const block = evm.BlockInfo{ .chain_id = 1, .number = 1, .timestamp = 1, .difficulty = 1, .gas_limit = 30_000_000, .coinbase = coinbase, .base_fee = 0, .prev_randao = zero_hash };
    const keys = [_]u256{1};
    const list = [_]evm.AccessListEntry{.{ .address = target, .storage_keys = &keys }};
    // 21000 + 2400 + 1900.
    const intrinsic: u64 = 25_300;
    for ([_]u64{ intrinsic - 1, intrinsic }) |gas_limit| {
        var db = evm.Database.init(testing.allocator);
        defer db.deinit();
        try db.set_account(sender.bytes, .{ .balance = 1_000_000, .nonce = 0, .code_hash = zero_hash, .storage_root = zero_hash });

        var vm = try Berlin.init(testing.allocator, &db, block, .{ .gas_limit = gas_limit, .coinbase = coinbase, .chain_id = 1, .access_list = &list }, 0, sender);
        defer vm.deinit();
        var result = vm.call(.{ .call = .{ .caller = sender, .to = target, .value = 0, .input = &.{}, .gas = gas_limit } });
        defer result.deinit(testing.allocator);

        if (gas_limit < intrinsic) {
            try testing.expect(!result.success);
            try testing.expect(std.mem.indexOf(u8, result.error_info.?, "intrinsic gas") != null);
            try testing.expectEqual(@as(u64, 0), try db.get_nonce(sender.bytes));
        } else {
            // Exactly the intrinsic gas: a call to an account without code succeeds.
            try testing.expect(result.success);
            try testing.expectEqual(@as(u64, 0), result.gas_left);
            try testing.expectEqual(@as(u64, 1), try db.get_nonce(sender.bytes));
        }
    }
}

test "EIP-2930: an access list before Berlin makes the transaction invalid" {
    const Istanbul = evm.Evm(.{ .eips = .{ .hardfork = .ISTANBUL } });
    const block = evm.BlockInfo{ .chain_id = 1, .number = 1, .timestamp = 1, .difficulty = 1, .gas_limit = 30_000_000, .coinbase = coinbase, .base_fee = 0, .prev_randao = zero_hash };
    var db = evm.Database.init(testing.allocator);
    defer db.deinit();
    try db.set_account(sender.bytes, .{ .balance = 1_000_000, .nonce = 3, .code_hash = zero_hash, .storage_root = zero_hash });
    const root_before = try db.get_state_root();

    const list = [_]evm.AccessListEntry{.{ .address = target }};
    var vm = try Istanbul.init(testing.allocator, &db, block, .{ .gas_limit = 100_000, .coinbase = coinbase, .chain_id = 1, .access_list = &list }, 0, sender);
    defer vm.deinit();
    var result = vm.call(.{ .call = .{ .caller = sender, .to = target, .value = 0, .input = &.{}, .gas = 100_000 } });
    defer result.deinit(testing.allocator);

    try testing.expect(!result.success);
    try testing.expect(std.mem.indexOf(u8, result.error_info.?, "EIP-2930") != null);
    try testing.expectEqual(@as(?anyerror, null), vm.host_failure);
    try testing.expectEqualSlices(u8, &root_before, &(try db.get_state_root()));
}

// Twenty cold SLOADs of slots 0..19: 20 * (PUSH1 3 + SLOAD 2100 + POP 2) = 42100 gas.
// Enough gas use for the EIP-3529 cap (one fifth) to pass a 12500 refund in full.
const twenty_sloads = blk: {
    var code: [20 * 4 + 1]u8 = undefined;
    for (0..20) |i| {
        code[i * 4] = 0x60;
        code[i * 4 + 1] = @intCast(i);
        code[i * 4 + 2] = 0x54;
        code[i * 4 + 3] = 0x50;
    }
    code[80] = 0x00;
    break :blk code;
};

test "EIP-7702: Evm.call applies the authorization list, charges 25000 per tuple and refunds 12500 for an existing authority" {
    const Prague = evm.Evm(.{ .eips = .{ .hardfork = .PRAGUE } });
    const block = evm.BlockInfo{ .chain_id = 1, .number = 1, .timestamp = 1, .difficulty = 0, .gas_limit = 30_000_000, .coinbase = coinbase, .base_fee = 0, .prev_randao = zero_hash };
    const delegate = Address{ .bytes = [_]u8{0xDE} ++ @as([19]u8, @splat(0)) };
    const key: crypto.PrivateKey = @as([32]u8, @splat(0x42));
    const authority = (try crypto.unaudited_getPublicKey(key)).toAddress();
    var tuple = try primitives.Authorization.createAuthorization(testing.allocator, 1, delegate, 0, key);
    tuple.v -= 27; // the tuple carries y_parity
    const list = [_]evm.Authorization{tuple};

    // 21000 + 25000 intrinsic + 42100 execution.
    const before_refund: u64 = 88_100;
    for ([_]bool{ true, false }) |authority_exists| {
        var db = evm.Database.init(testing.allocator);
        defer db.deinit();
        try db.set_account(sender.bytes, .{ .balance = 1_000_000, .nonce = 0, .code_hash = zero_hash, .storage_root = zero_hash });
        try db.set_account(target.bytes, .{ .balance = 0, .nonce = 1, .code_hash = try db.set_code(&twenty_sloads), .storage_root = zero_hash });
        if (authority_exists) try db.set_account(authority.bytes, .{ .balance = 5, .nonce = 0, .code_hash = zero_hash, .storage_root = zero_hash });

        var vm = try Prague.init(testing.allocator, &db, block, .{
            .gas_limit = 200_000,
            .coinbase = coinbase,
            .chain_id = 1,
            .authorization_list = &list,
            .is_set_code_transaction = true,
            .tx_nonce = 0,
        }, 0, sender);
        defer vm.deinit();
        var result = vm.call(.{ .call = .{ .caller = sender, .to = target, .value = 0, .input = &.{}, .gas = 200_000 } });
        defer result.deinit(testing.allocator);

        try testing.expect(result.success);
        const refund: u64 = if (authority_exists) 12_500 else 0;
        try testing.expectEqual(@as(u64, 200_000) - (before_refund - refund), result.gas_left);

        const delegated = (try db.get_account(authority.bytes)).?;
        try testing.expectEqual(@as(u64, 1), delegated.nonce);
        try testing.expectEqual(delegate, delegated.delegated_address.?);
        try testing.expectEqual(@as(u64, 1), try db.get_nonce(sender.bytes));
        // The recovered authority is warm for the rest of the transaction.
        var warm = false;
        for (result.accessed_addresses) |address| warm = warm or address.equals(authority);
        try testing.expect(warm);
    }
}

test "EIP-7702: an invalid tuple is skipped but paid for, and a reverting call keeps the delegation and the refund" {
    const Prague = evm.Evm(.{ .eips = .{ .hardfork = .PRAGUE } });
    const block = evm.BlockInfo{ .chain_id = 1, .number = 1, .timestamp = 1, .difficulty = 0, .gas_limit = 30_000_000, .coinbase = coinbase, .base_fee = 0, .prev_randao = zero_hash };
    const delegate = Address{ .bytes = [_]u8{0xDE} ++ @as([19]u8, @splat(0)) };
    const key: crypto.PrivateKey = @as([32]u8, @splat(0x42));
    const authority = (try crypto.unaudited_getPublicKey(key)).toAddress();
    var good = try primitives.Authorization.createAuthorization(testing.allocator, 1, delegate, 0, key);
    good.v -= 27;
    var wrong_chain = try primitives.Authorization.createAuthorization(testing.allocator, 999, delegate, 0, key);
    wrong_chain.v -= 27;
    var wrong_nonce = try primitives.Authorization.createAuthorization(testing.allocator, 1, delegate, 5, key);
    wrong_nonce.v -= 27;

    // PUSH1 0, PUSH1 0, REVERT: 6 gas.
    const revert_code = [_]u8{ 0x60, 0x00, 0x60, 0x00, 0xfd };
    const cases = [_]struct { list: []const evm.Authorization, applied: bool, gas_used: u64 }{
        // Wrong chain: 21000 + 25000 + 6, no refund, no delegation.
        .{ .list = &.{wrong_chain}, .applied = false, .gas_used = 46_006 },
        // Wrong nonce: the same.
        .{ .list = &.{wrong_nonce}, .applied = false, .gas_used = 46_006 },
        // Valid, the call reverts: 46006 used, refund min(12500, 46006 / 5 = 9201).
        .{ .list = &.{good}, .applied = true, .gas_used = 46_006 - 9_201 },
        // One skipped and one valid tuple: 71006 used, refund min(12500, 14201).
        .{ .list = &.{ wrong_chain, good }, .applied = true, .gas_used = 71_006 - 12_500 },
    };
    for (cases) |case| {
        var db = evm.Database.init(testing.allocator);
        defer db.deinit();
        try db.set_account(sender.bytes, .{ .balance = 1_000_000, .nonce = 0, .code_hash = zero_hash, .storage_root = zero_hash });
        try db.set_account(target.bytes, .{ .balance = 0, .nonce = 1, .code_hash = try db.set_code(&revert_code), .storage_root = zero_hash });
        try db.set_account(authority.bytes, .{ .balance = 5, .nonce = 0, .code_hash = zero_hash, .storage_root = zero_hash });

        var vm = try Prague.init(testing.allocator, &db, block, .{ .gas_limit = 200_000, .coinbase = coinbase, .chain_id = 1, .authorization_list = case.list, .is_set_code_transaction = true }, 0, sender);
        defer vm.deinit();
        var result = vm.call(.{ .call = .{ .caller = sender, .to = target, .value = 0, .input = &.{}, .gas = 200_000 } });
        defer result.deinit(testing.allocator);

        // The call reverted; the transaction is still included.
        try testing.expect(!result.success);
        try testing.expect(result.reverted);
        try testing.expectEqual(@as(?[]const u8, null), result.error_info);
        try testing.expectEqual(@as(u64, 200_000) - case.gas_used, result.gas_left);
        try testing.expectEqual(@as(u64, 1), try db.get_nonce(sender.bytes));

        const account = (try db.get_account(authority.bytes)).?;
        try testing.expectEqual(@as(u64, if (case.applied) 1 else 0), account.nonce);
        try testing.expectEqual(case.applied, account.delegated_address != null);
    }
}

test "EIP-7702: authorization lists are rejected before Prague, when empty and on creation" {
    const block = evm.BlockInfo{ .chain_id = 1, .number = 1, .timestamp = 1, .difficulty = 0, .gas_limit = 30_000_000, .coinbase = coinbase, .base_fee = 0, .prev_randao = zero_hash };
    const delegate = Address{ .bytes = [_]u8{0xDE} ++ @as([19]u8, @splat(0)) };
    const key: crypto.PrivateKey = @as([32]u8, @splat(0x42));
    const authority = (try crypto.unaudited_getPublicKey(key)).toAddress();
    var tuple = try primitives.Authorization.createAuthorization(testing.allocator, 1, delegate, 0, key);
    tuple.v -= 27;
    const list = [_]evm.Authorization{tuple};

    // Before Prague: invalid, and the authority is left alone.
    {
        const Cancun = evm.Evm(.{ .eips = .{ .hardfork = .CANCUN } });
        var db = evm.Database.init(testing.allocator);
        defer db.deinit();
        try db.set_account(sender.bytes, .{ .balance = 1_000_000, .nonce = 0, .code_hash = zero_hash, .storage_root = zero_hash });
        const root_before = try db.get_state_root();
        var vm = try Cancun.init(testing.allocator, &db, block, .{ .gas_limit = 200_000, .coinbase = coinbase, .chain_id = 1, .authorization_list = &list, .is_set_code_transaction = true }, 0, sender);
        defer vm.deinit();
        var result = vm.call(.{ .call = .{ .caller = sender, .to = target, .value = 0, .input = &.{}, .gas = 200_000 } });
        defer result.deinit(testing.allocator);
        try testing.expect(!result.success);
        try testing.expect(std.mem.indexOf(u8, result.error_info.?, "EIP-7702") != null);
        try testing.expectEqual(@as(?evm.Account, null), try db.get_account(authority.bytes));
        try testing.expectEqualSlices(u8, &root_before, &(try db.get_state_root()));
    }
    // Prague, type-4 transaction without tuples: invalid.
    {
        const Prague = evm.Evm(.{ .eips = .{ .hardfork = .PRAGUE } });
        var db = evm.Database.init(testing.allocator);
        defer db.deinit();
        try db.set_account(sender.bytes, .{ .balance = 1_000_000, .nonce = 0, .code_hash = zero_hash, .storage_root = zero_hash });
        var vm = try Prague.init(testing.allocator, &db, block, .{ .gas_limit = 200_000, .coinbase = coinbase, .chain_id = 1, .is_set_code_transaction = true }, 0, sender);
        defer vm.deinit();
        var result = vm.call(.{ .call = .{ .caller = sender, .to = target, .value = 0, .input = &.{}, .gas = 200_000 } });
        defer result.deinit(testing.allocator);
        try testing.expect(!result.success);
        try testing.expect(std.mem.indexOf(u8, result.error_info.?, "at least one authorization") != null);
        try testing.expectEqual(@as(u64, 0), try db.get_nonce(sender.bytes));
    }
    // Prague, set-code transaction that creates a contract: invalid.
    {
        const Prague = evm.Evm(.{ .eips = .{ .hardfork = .PRAGUE } });
        var db = evm.Database.init(testing.allocator);
        defer db.deinit();
        try db.set_account(sender.bytes, .{ .balance = 1_000_000, .nonce = 0, .code_hash = zero_hash, .storage_root = zero_hash });
        var vm = try Prague.init(testing.allocator, &db, block, .{ .gas_limit = 200_000, .coinbase = coinbase, .chain_id = 1, .authorization_list = &list, .is_set_code_transaction = true }, 0, sender);
        defer vm.deinit();
        var result = vm.call(.{ .create = .{ .caller = sender, .value = 0, .init_code = &[_]u8{0x00}, .gas = 200_000 } });
        defer result.deinit(testing.allocator);
        try testing.expect(!result.success);
        try testing.expect(std.mem.indexOf(u8, result.error_info.?, "cannot create a contract") != null);
        try testing.expectEqual(@as(u64, 0), try db.get_nonce(sender.bytes));
        try testing.expectEqual(@as(?evm.Account, null), try db.get_account(authority.bytes));
    }
}

test "EIP-7702: AuthorizationProcessor refuses to apply tuples before Prague" {
    var db = evm.Database.init(testing.allocator);
    defer db.deinit();
    const delegate = Address{ .bytes = [_]u8{0xDE} ++ @as([19]u8, @splat(0)) };
    const key: crypto.PrivateKey = @as([32]u8, @splat(0x42));
    const authority = (try crypto.unaudited_getPublicKey(key)).toAddress();
    var tuple = try primitives.Authorization.createAuthorization(testing.allocator, 1, delegate, 0, key);
    tuple.v -= 27;
    const list = [_]evm.Authorization{tuple};

    var gas: i64 = 1_000_000;
    var cancun = evm.AuthorizationProcessor{ .db = &db, .chain_id = 1, .gas_remaining = &gas, .eips = .{ .hardfork = .CANCUN } };
    try testing.expectError(error.AuthorizationsNotActive, cancun.processAuthorizationList(&list));
    try testing.expectError(error.AuthorizationsNotActive, cancun.processAuthorizationListWithResults(testing.allocator, &list));
    try testing.expectError(error.AuthorizationsNotActive, cancun.processAuthorization(tuple, authority));
    // Nothing was charged or written, and an empty list is not an error.
    try testing.expectEqual(@as(i64, 1_000_000), gas);
    try testing.expectEqual(@as(?evm.Account, null), try db.get_account(authority.bytes));
    try testing.expectEqual(@as(i64, 0), try cancun.processAuthorizationList(&.{}));

    var prague = evm.AuthorizationProcessor{ .db = &db, .chain_id = 1, .gas_remaining = &gas, .eips = .{ .hardfork = .PRAGUE } };
    try testing.expectEqual(@as(i64, 0), try prague.processAuthorizationList(&list));
    try testing.expectEqual(@as(i64, 1_000_000 - 25_000), gas);
    try testing.expectEqual(delegate, (try db.get_account(authority.bytes)).?.delegated_address.?);
}

test "EIP-3607: a sender with code is rejected; a delegated EOA sends from Prague on" {
    const block = evm.BlockInfo{ .chain_id = 1, .number = 1, .timestamp = 1, .difficulty = 0, .gas_limit = 30_000_000, .coinbase = coinbase, .base_fee = 0, .prev_randao = zero_hash };
    const delegate = Address{ .bytes = [_]u8{0xDE} ++ @as([19]u8, @splat(0)) };

    // A contract account cannot originate a transaction, on any fork.
    inline for (.{ evm.Hardfork.FRONTIER, evm.Hardfork.LONDON, evm.Hardfork.PRAGUE }) |hardfork| {
        const Vm = evm.Evm(.{ .eips = .{ .hardfork = hardfork } });
        var db = evm.Database.init(testing.allocator);
        defer db.deinit();
        try db.set_account(sender.bytes, .{ .balance = 1_000_000, .nonce = 2, .code_hash = try db.set_code(&[_]u8{0x00}), .storage_root = zero_hash });
        const root_before = try db.get_state_root();
        var vm = try Vm.init(testing.allocator, &db, block, .{ .gas_limit = 100_000, .coinbase = coinbase, .chain_id = 1 }, 0, sender);
        defer vm.deinit();
        var result = vm.call(.{ .call = .{ .caller = sender, .to = target, .value = 0, .input = &.{}, .gas = 100_000 } });
        defer result.deinit(testing.allocator);
        try testing.expect(!result.success);
        try testing.expect(std.mem.indexOf(u8, result.error_info.?, "EIP-3607") != null);
        try testing.expectEqualSlices(u8, &root_before, &(try db.get_state_root()));
    }

    // A delegated EOA: valid sender on Prague, ordinary code before it.
    inline for (.{ .{ evm.Hardfork.PRAGUE, true }, .{ evm.Hardfork.CANCUN, false } }) |case| {
        const Vm = evm.Evm(.{ .eips = .{ .hardfork = case[0] } });
        var db = evm.Database.init(testing.allocator);
        defer db.deinit();
        var account = evm.Account{ .balance = 1_000_000, .nonce = 2, .code_hash = zero_hash, .storage_root = zero_hash };
        account.delegated_address = delegate;
        try db.set_account(sender.bytes, account);
        var vm = try Vm.init(testing.allocator, &db, block, .{ .gas_limit = 100_000, .coinbase = coinbase, .chain_id = 1 }, 0, sender);
        defer vm.deinit();
        var result = vm.call(.{ .call = .{ .caller = sender, .to = target, .value = 0, .input = &.{}, .gas = 100_000 } });
        defer result.deinit(testing.allocator);
        try testing.expectEqual(case[1], result.success);
        try testing.expectEqual(case[1], result.error_info == null);
        try testing.expectEqual(@as(u64, if (case[1]) 3 else 2), try db.get_nonce(sender.bytes));
    }
}

test "tx_nonce: a transaction is valid only at the sender's nonce; null keeps auto-increment" {
    const London = evm.Evm(.{ .eips = .{ .hardfork = .LONDON } });
    const block = evm.BlockInfo{ .chain_id = 1, .number = 1, .timestamp = 1, .difficulty = 1, .gas_limit = 30_000_000, .coinbase = coinbase, .base_fee = 0, .prev_randao = zero_hash };
    const cases = [_]struct { tx_nonce: ?u64, reason: ?[]const u8 }{
        .{ .tx_nonce = 4, .reason = "below the sender nonce" },
        .{ .tx_nonce = 6, .reason = "above the sender nonce" },
        .{ .tx_nonce = std.math.maxInt(u64), .reason = "above the sender nonce" },
        .{ .tx_nonce = 5, .reason = null },
        .{ .tx_nonce = null, .reason = null },
    };
    for (cases) |case| {
        var db = evm.Database.init(testing.allocator);
        defer db.deinit();
        try db.set_account(sender.bytes, .{ .balance = 1_000_000, .nonce = 5, .code_hash = zero_hash, .storage_root = zero_hash });
        var vm = try London.init(testing.allocator, &db, block, .{ .gas_limit = 100_000, .coinbase = coinbase, .chain_id = 1, .tx_nonce = case.tx_nonce }, 0, sender);
        defer vm.deinit();
        var result = vm.call(.{ .call = .{ .caller = sender, .to = target, .value = 0, .input = &.{}, .gas = 100_000 } });
        defer result.deinit(testing.allocator);

        if (case.reason) |reason| {
            try testing.expect(!result.success);
            try testing.expect(std.mem.indexOf(u8, result.error_info.?, reason) != null);
            try testing.expectEqual(@as(u64, 5), try db.get_nonce(sender.bytes));
            try testing.expectEqual(@as(u256, 1_000_000), try db.get_balance(sender.bytes));
        } else {
            try testing.expect(result.success);
            try testing.expectEqual(@as(u64, 6), try db.get_nonce(sender.bytes));
        }
    }
}

test "EIP-1559: a legacy gas price below the base fee is rejected from London; equal is accepted" {
    const London = evm.Evm(.{ .eips = .{ .hardfork = .LONDON } });
    const block = evm.BlockInfo{ .chain_id = 1, .number = 1, .timestamp = 1, .difficulty = 1, .gas_limit = 30_000_000, .coinbase = coinbase, .base_fee = 10, .prev_randao = zero_hash };
    const cases = [_]struct { gas_price: u256, allow: bool, accepted: bool }{
        .{ .gas_price = 9, .allow = false, .accepted = false },
        .{ .gas_price = 0, .allow = false, .accepted = false },
        .{ .gas_price = 10, .allow = false, .accepted = true },
        .{ .gas_price = 11, .allow = false, .accepted = true },
        // The explicit simulation override, and only it, accepts a lower price.
        .{ .gas_price = 9, .allow = true, .accepted = true },
    };
    for (cases) |case| {
        var db = evm.Database.init(testing.allocator);
        defer db.deinit();
        try db.set_account(sender.bytes, .{ .balance = 10_000_000, .nonce = 0, .code_hash = zero_hash, .storage_root = zero_hash });
        var vm = try London.init(testing.allocator, &db, block, .{ .gas_limit = 100_000, .coinbase = coinbase, .chain_id = 1, .allow_gas_price_below_base_fee = case.allow }, case.gas_price, sender);
        defer vm.deinit();
        var result = vm.call(.{ .call = .{ .caller = sender, .to = target, .value = 0, .input = &.{}, .gas = 100_000 } });
        defer result.deinit(testing.allocator);

        try testing.expectEqual(case.accepted, result.success);
        if (!case.accepted) {
            try testing.expect(std.mem.indexOf(u8, result.error_info.?, "below the block base fee") != null);
            try testing.expectEqual(@as(u64, 0), try db.get_nonce(sender.bytes));
            try testing.expectEqual(@as(u256, 10_000_000), try db.get_balance(sender.bytes));
            continue;
        }
        // 21000 gas at the gas price leaves the sender; the base fee is burned and
        // only the part above it reaches the block producer.
        try testing.expectEqual(@as(u256, 10_000_000) - 21_000 * case.gas_price, try db.get_balance(sender.bytes));
        try testing.expectEqual(@as(u256, 21_000) * (case.gas_price -| 10), try db.get_balance(coinbase.bytes));
    }
}

test "EIP-1559: before London there is no base fee floor" {
    const Berlin = evm.Evm(.{ .eips = .{ .hardfork = .BERLIN } });
    const block = evm.BlockInfo{ .chain_id = 1, .number = 1, .timestamp = 1, .difficulty = 1, .gas_limit = 30_000_000, .coinbase = coinbase, .base_fee = 10, .prev_randao = zero_hash };
    var db = evm.Database.init(testing.allocator);
    defer db.deinit();
    try db.set_account(sender.bytes, .{ .balance = 10_000_000, .nonce = 0, .code_hash = zero_hash, .storage_root = zero_hash });
    var vm = try Berlin.init(testing.allocator, &db, block, .{ .gas_limit = 100_000, .coinbase = coinbase, .chain_id = 1 }, 3, sender);
    defer vm.deinit();
    var result = vm.call(.{ .call = .{ .caller = sender, .to = target, .value = 0, .input = &.{}, .gas = 100_000 } });
    defer result.deinit(testing.allocator);
    try testing.expect(result.success);
    // The whole price goes to the block producer.
    try testing.expectEqual(@as(u256, 63_000), try db.get_balance(coinbase.bytes));
}

test "EIP-4844: an overflowing blob_gas * max_fee_per_blob_gas is rejected, never clamped" {
    const Cancun = evm.Evm(.{ .eips = .{ .hardfork = .CANCUN } });
    const blob_hash = [_]u8{0x01} ++ @as([31]u8, @splat(0xAB));
    const hashes = [_][32]u8{blob_hash};
    const block = evm.BlockInfo{ .chain_id = 1, .number = 1, .timestamp = 1, .difficulty = 0, .gas_limit = 30_000_000, .coinbase = coinbase, .base_fee = 0, .prev_randao = zero_hash, .blob_base_fee = 1, .blob_versioned_hashes = &hashes };
    const max = std.math.maxInt(u256);
    const cases = [_]struct { max_fee_per_blob_gas: u256, accepted: bool }{
        // 131072 * (2^256 - 1) overflows. Clamped to 2^256 - 1 it would equal the
        // sender's balance and pass the affordability check.
        .{ .max_fee_per_blob_gas = max, .accepted = false },
        // 2^17 * 2^239 = 2^256: the smallest overflowing fee cap.
        .{ .max_fee_per_blob_gas = @as(u256, 1) << 239, .accepted = false },
        // One less fits, and the sender can afford it.
        .{ .max_fee_per_blob_gas = (@as(u256, 1) << 239) - 1, .accepted = true },
        .{ .max_fee_per_blob_gas = 1, .accepted = true },
    };
    for (cases) |case| {
        var db = evm.Database.init(testing.allocator);
        defer db.deinit();
        try db.set_account(sender.bytes, .{ .balance = max, .nonce = 0, .code_hash = zero_hash, .storage_root = zero_hash });
        var vm = try Cancun.init(testing.allocator, &db, block, .{
            .gas_limit = 100_000,
            .coinbase = coinbase,
            .chain_id = 1,
            .blob_versioned_hashes = &hashes,
            .is_blob_transaction = true,
            .max_fee_per_blob_gas = case.max_fee_per_blob_gas,
        }, 0, sender);
        defer vm.deinit();
        var result = vm.call(.{ .call = .{ .caller = sender, .to = target, .value = 0, .input = &.{}, .gas = 100_000 } });
        defer result.deinit(testing.allocator);

        try testing.expectEqual(case.accepted, result.success);
        if (case.accepted) {
            // One blob at blob base fee 1 burns 131072 wei.
            try testing.expectEqual(max - 131_072, try db.get_balance(sender.bytes));
        } else {
            try testing.expect(std.mem.indexOf(u8, result.error_info.?, "overflows (EIP-4844)") != null);
            try testing.expectEqual(max, try db.get_balance(sender.bytes));
            try testing.expectEqual(@as(u64, 0), try db.get_nonce(sender.bytes));
        }
    }
}

test "EIP-4844: blob fee helpers return null on overflow" {
    const cancun = evm.Eips{ .hardfork = .CANCUN };
    const max = std.math.maxInt(u256);
    try testing.expectEqual(@as(?u256, 131_072 * 7), cancun.blob_gas_cost(7, 1));
    try testing.expectEqual(@as(?u256, null), cancun.blob_gas_cost(max, 1));
    try testing.expectEqual(@as(?u256, null), cancun.max_blob_gas_cost(max, 2));
    try testing.expectEqual(@as(?u256, 0), cancun.max_blob_gas_cost(max, 0));
    try testing.expectEqual(@as(?u256, 6 * 131_072 * 3), cancun.max_blob_gas_cost(3, 6));
    // Before Cancun there is no blob fee at all.
    const shanghai = evm.Eips{ .hardfork = .SHANGHAI };
    try testing.expectEqual(@as(?u256, 0), shanghai.max_blob_gas_cost(max, 6));
}

test "EIP-2: a creation transaction costs 21000 on Frontier and 53000 from Homestead" {
    const frontier = evm.Eips{ .hardfork = .FRONTIER };
    const homestead = evm.Eips{ .hardfork = .HOMESTEAD };
    const osaka = evm.Eips{ .hardfork = .OSAKA };
    try testing.expectEqual(@as(u64, 21_000), frontier.intrinsic_gas_cost(true));
    try testing.expectEqual(@as(u64, 21_000), frontier.intrinsic_gas_cost(false));
    try testing.expectEqual(@as(u64, 53_000), homestead.intrinsic_gas_cost(true));
    try testing.expectEqual(@as(u64, 21_000), homestead.intrinsic_gas_cost(false));
    try testing.expectEqual(@as(u64, 53_000), osaka.intrinsic_gas_cost(true));

    // Init code `STOP`: one zero byte of calldata, 4 gas.
    const init_code = [_]u8{0x00};
    const block = evm.BlockInfo{ .chain_id = 1, .number = 1, .timestamp = 1, .difficulty = 1, .gas_limit = 30_000_000, .coinbase = coinbase, .base_fee = 0, .prev_randao = zero_hash };

    // Frontier: 25000 gas covers 21004 and the creation runs.
    {
        const Frontier = evm.Evm(.{ .eips = .{ .hardfork = .FRONTIER } });
        var db = evm.Database.init(testing.allocator);
        defer db.deinit();
        try db.set_account(sender.bytes, .{ .balance = 1_000_000, .nonce = 0, .code_hash = zero_hash, .storage_root = zero_hash });
        var vm = try Frontier.init(testing.allocator, &db, block, .{ .gas_limit = 25_000, .coinbase = coinbase, .chain_id = 1 }, 0, sender);
        defer vm.deinit();
        var result = vm.call(.{ .create = .{ .caller = sender, .value = 0, .init_code = &init_code, .gas = 25_000 } });
        defer result.deinit(testing.allocator);
        try testing.expect(result.success);
        try testing.expectEqual(@as(u64, 25_000 - 21_004), result.gas_left);
        try testing.expect(result.created_address != null);
        try testing.expectEqual(@as(u64, 1), try db.get_nonce(sender.bytes));
        // Frontier's intrinsic boundary: 21003 is not enough, 21004 is.
        try db.set_account(sender.bytes, .{ .balance = 1_000_000, .nonce = 1, .code_hash = zero_hash, .storage_root = zero_hash });
        var below = vm.call(.{ .create = .{ .caller = sender, .value = 0, .init_code = &init_code, .gas = 21_003 } });
        defer below.deinit(testing.allocator);
        try testing.expect(!below.success);
        try testing.expect(std.mem.indexOf(u8, below.error_info.?, "intrinsic gas") != null);
        var exact = vm.call(.{ .create = .{ .caller = sender, .value = 0, .init_code = &init_code, .gas = 21_004 } });
        defer exact.deinit(testing.allocator);
        try testing.expect(exact.success);
        try testing.expectEqual(@as(u64, 0), exact.gas_left);
    }
    // Homestead: the same 25000 gas is below 53004, so the transaction is invalid.
    {
        const Homestead = evm.Evm(.{ .eips = .{ .hardfork = .HOMESTEAD } });
        var db = evm.Database.init(testing.allocator);
        defer db.deinit();
        try db.set_account(sender.bytes, .{ .balance = 1_000_000, .nonce = 0, .code_hash = zero_hash, .storage_root = zero_hash });
        var vm = try Homestead.init(testing.allocator, &db, block, .{ .gas_limit = 60_000, .coinbase = coinbase, .chain_id = 1 }, 0, sender);
        defer vm.deinit();
        var rejected = vm.call(.{ .create = .{ .caller = sender, .value = 0, .init_code = &init_code, .gas = 25_000 } });
        defer rejected.deinit(testing.allocator);
        try testing.expect(!rejected.success);
        try testing.expect(std.mem.indexOf(u8, rejected.error_info.?, "intrinsic gas") != null);
        try testing.expectEqual(@as(u64, 0), try db.get_nonce(sender.bytes));

        var accepted = vm.call(.{ .create = .{ .caller = sender, .value = 0, .init_code = &init_code, .gas = 60_000 } });
        defer accepted.deinit(testing.allocator);
        try testing.expect(accepted.success);
        try testing.expectEqual(@as(u64, 60_000 - 53_004), accepted.gas_left);
    }
}
