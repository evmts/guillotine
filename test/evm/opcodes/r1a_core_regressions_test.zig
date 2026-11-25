//! Regression tests for the Round 1 core/state review findings (lane R1-A).
//!
//! Each test builds its own database and EVM and runs real bytecode through the
//! public `Evm.call` / `Evm.simulate` entry points.
//!
//! Run with `zig build test-opcodes-0xr1a`.

const std = @import("std");
const evm = @import("evm");
const primitives = @import("voltaire");

const Vm = evm.Evm(.{});
const Address = primitives.Address;

// C-01: journal snapshot IDs are u64. A transaction that makes more than 65,535
// calls used to exhaust a u16 ID and fail every later call.
test "R1A C-01: more than 65,535 calls in one transaction all succeed" {
    const allocator = std.testing.allocator;
    var db = evm.Database.init(allocator);
    defer db.deinit();

    const origin = Address{ .bytes = @as([20]u8, @splat(0xA1)) };
    const looper = Address{ .bytes = @as([20]u8, @splat(0xB1)) };

    // counter = 66000
    // loop: CALL(gas, 0x2000, 0, 0, 0, 0, 0); if it failed jump to INVALID;
    //       counter -= 1; if counter != 0 goto loop
    const code = [_]u8{
        0x62, 0x01, 0x01, 0xD0, // PUSH3 66000
        0x5B, // JUMPDEST (pc 4)
        0x5F, 0x5F, 0x5F, 0x5F, 0x5F, // PUSH0 x5: retSize retOffset argsSize argsOffset value
        0x61, 0x20, 0x00, // PUSH2 0x2000
        0x5A, // GAS
        0xF1, // CALL
        0x15, // ISZERO
        0x60, 0x1C, // PUSH1 28
        0x57, // JUMPI
        0x60, 0x01, // PUSH1 1
        0x90, // SWAP1
        0x03, // SUB
        0x80, // DUP1
        0x60, 0x04, // PUSH1 4
        0x57, // JUMPI
        0x00, // STOP
        0x5B, // JUMPDEST (pc 28)
        0xFE, // INVALID
    };
    const code_hash = try db.set_code(&code);
    var account = evm.Account.zero();
    account.code_hash = code_hash;
    try db.set_account(looper.bytes, account);

    var vm = try Vm.init(
        allocator,
        &db,
        evm.BlockInfo.init(),
        .{ .gas_limit = 16_000_000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 },
        0,
        origin,
    );
    defer vm.deinit();

    try std.testing.expectEqual(u64, Vm.Journal.SnapshotIdType);

    var result = vm.call(.{ .call = .{
        .caller = origin,
        .to = looper,
        .value = 0,
        .input = &.{},
        .gas = 16_000_000,
    } });
    defer result.deinit(allocator);

    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(usize, 0), db.snapshot_depth());
}

// C-02: during simulate(), a child frame's SSTORE and TSTORE land in the overlay
// and a REVERT rolls them back; base state is never written.
test "R1A C-02: simulate rolls back a reverted child's SSTORE and TSTORE" {
    const allocator = std.testing.allocator;
    var db = evm.Database.init(allocator);
    defer db.deinit();

    const origin = Address{ .bytes = @as([20]u8, @splat(0xA2)) };
    const parent = Address{ .bytes = @as([20]u8, @splat(0xB2)) };
    const child = Address{ .bytes = @as([18]u8, @splat(0)) ++ [_]u8{ 0x20, 0x00 } };

    // With calldata: SSTORE(5, 7); TSTORE(5, 7); REVERT.
    // Without calldata: return SLOAD(5) + TLOAD(5).
    const child_code = [_]u8{
        0x36, // CALLDATASIZE
        0x60, 0x11, // PUSH1 17
        0x57, // JUMPI
        0x60, 0x05, 0x54, // PUSH1 5, SLOAD
        0x60, 0x05, 0x5C, // PUSH1 5, TLOAD
        0x01, // ADD
        0x5F, 0x52, // PUSH0, MSTORE
        0x60, 0x20, 0x5F, 0xF3, // PUSH1 32, PUSH0, RETURN
        0x5B, // JUMPDEST (pc 17)
        0x60, 0x07, 0x60, 0x05, 0x55, // PUSH1 7, PUSH1 5, SSTORE
        0x60, 0x07, 0x60, 0x05, 0x5D, // PUSH1 7, PUSH1 5, TSTORE
        0x5F, 0x5F, 0xFD, // PUSH0, PUSH0, REVERT
    };
    // Call the child with one byte of calldata (it writes and reverts), then call it
    // without calldata and return what it read.
    const parent_code = [_]u8{
        0x5F, 0x5F, // retSize, retOffset
        0x60, 0x01, 0x5F, // argsSize = 1, argsOffset
        0x5F, // value
        0x61, 0x20, 0x00, // PUSH2 0x2000
        0x5A, 0xF1, 0x50, // GAS, CALL, POP
        0x60, 0x20, 0x5F, // retSize = 32, retOffset
        0x5F, 0x5F, // argsSize, argsOffset
        0x5F, // value
        0x61, 0x20, 0x00, // PUSH2 0x2000
        0x5A, 0xF1, 0x50, // GAS, CALL, POP
        0x60, 0x20, 0x5F, 0xF3, // PUSH1 32, PUSH0, RETURN
    };

    var child_account = evm.Account.zero();
    child_account.code_hash = try db.set_code(&child_code);
    try db.set_account(child.bytes, child_account);
    var parent_account = evm.Account.zero();
    parent_account.code_hash = try db.set_code(&parent_code);
    try db.set_account(parent.bytes, parent_account);

    var vm = try Vm.init(
        allocator,
        &db,
        evm.BlockInfo.init(),
        .{ .gas_limit = 1_000_000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 },
        0,
        origin,
    );
    defer vm.deinit();

    var simulated = vm.simulate(.{ .call = .{
        .caller = origin,
        .to = parent,
        .value = 0,
        .input = &.{},
        .gas = 1_000_000,
    } });
    defer simulated.deinit(allocator);

    try std.testing.expect(simulated.success);
    try std.testing.expectEqualSlices(u8, &(@as([32]u8, @splat(0))), simulated.output);

    // The simulation wrote nothing to base state: no storage, no transient storage,
    // no nonce increment for the sender.
    try std.testing.expectEqual(@as(u256, 0), try db.get_storage(child.bytes, 5));
    try std.testing.expectEqual(@as(u256, 0), try db.get_transient_storage(child.bytes, 5));
    try std.testing.expectEqual(@as(usize, 0), db.transient_storage.count());
    try std.testing.expectEqual(@as(?evm.Account, null), try db.get_account(origin.bytes));
    try std.testing.expectEqual(@as(usize, 0), db.snapshot_depth());

    // The same call outside a simulation rolls the child back as well.
    var executed = vm.call(.{ .call = .{
        .caller = origin,
        .to = parent,
        .value = 0,
        .input = &.{},
        .gas = 1_000_000,
    } });
    defer executed.deinit(allocator);

    try std.testing.expect(executed.success);
    try std.testing.expectEqualSlices(u8, &(@as([32]u8, @splat(0))), executed.output);
    try std.testing.expectEqual(@as(u256, 0), try db.get_storage(child.bytes, 5));
    try std.testing.expectEqual(@as(u64, 1), (try db.get_account(origin.bytes)).?.nonce);
}

// C-03: the sender buys gas before execution, so code observes the reduced
// balance; unused gas is bought back afterwards and the coinbase is paid.
test "R1A C-03: gas is bought up front and unused gas is refunded" {
    const allocator = std.testing.allocator;
    var db = evm.Database.init(allocator);
    defer db.deinit();

    const origin = Address{ .bytes = @as([20]u8, @splat(0xA3)) };
    const target = Address{ .bytes = @as([20]u8, @splat(0xB3)) };
    const coinbase = Address{ .bytes = @as([20]u8, @splat(0xC3)) };

    // return BALANCE(ORIGIN)
    const code = [_]u8{ 0x32, 0x31, 0x5F, 0x52, 0x60, 0x20, 0x5F, 0xF3 };
    var target_account = evm.Account.zero();
    target_account.code_hash = try db.set_code(&code);
    try db.set_account(target.bytes, target_account);

    const initial_balance: u256 = 1_000_000_000_000_000_000;
    var origin_account = evm.Account.zero();
    origin_account.balance = initial_balance;
    try db.set_account(origin.bytes, origin_account);

    const gas_limit: u64 = 100_000;
    const gas_price: u256 = 10;

    var block = evm.BlockInfo.init();
    block.coinbase = coinbase;
    var vm = try Vm.init(
        allocator,
        &db,
        block,
        .{ .gas_limit = gas_limit, .coinbase = coinbase, .chain_id = 1 },
        gas_price,
        origin,
    );
    defer vm.deinit();

    var result = vm.call(.{ .call = .{
        .caller = origin,
        .to = target,
        .value = 0,
        .input = &.{},
        .gas = gas_limit,
    } });
    defer result.deinit(allocator);

    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(usize, 32), result.output.len);
    const observed = std.mem.readInt(u256, result.output[0..32], .big);
    try std.testing.expectEqual(initial_balance - @as(u256, gas_limit) * gas_price, observed);

    const gas_used: u256 = gas_limit - result.gas_left;
    try std.testing.expect(gas_used >= 21_000);
    try std.testing.expectEqual(initial_balance - gas_used * gas_price, (try db.get_account(origin.bytes)).?.balance);
    try std.testing.expectEqual(gas_used * gas_price, (try db.get_account(coinbase.bytes)).?.balance);
    try std.testing.expectEqual(@as(u64, 1), (try db.get_account(origin.bytes)).?.nonce);
}

test "R1A C-03: a sender that cannot pay for gas leaves state untouched" {
    const allocator = std.testing.allocator;
    var db = evm.Database.init(allocator);
    defer db.deinit();

    const origin = Address{ .bytes = @as([20]u8, @splat(0xA4)) };
    const target = Address{ .bytes = @as([20]u8, @splat(0xB4)) };

    // SSTORE(0, 1)
    const code = [_]u8{ 0x60, 0x01, 0x5F, 0x55, 0x00 };
    var target_account = evm.Account.zero();
    target_account.code_hash = try db.set_code(&code);
    try db.set_account(target.bytes, target_account);

    var origin_account = evm.Account.zero();
    origin_account.balance = 5;
    try db.set_account(origin.bytes, origin_account);

    var vm = try Vm.init(
        allocator,
        &db,
        evm.BlockInfo.init(),
        .{ .gas_limit = 100_000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 },
        10,
        origin,
    );
    defer vm.deinit();

    var result = vm.call(.{ .call = .{
        .caller = origin,
        .to = target,
        .value = 0,
        .input = &.{},
        .gas = 100_000,
    } });
    defer result.deinit(allocator);

    try std.testing.expect(!result.success);
    const after = (try db.get_account(origin.bytes)).?;
    try std.testing.expectEqual(@as(u256, 5), after.balance);
    try std.testing.expectEqual(@as(u64, 0), after.nonce);
    try std.testing.expectEqual(@as(u256, 0), try db.get_storage(target.bytes, 0));
    try std.testing.expectEqual(@as(usize, 0), db.snapshot_depth());
}

test "R1A C-03: a gas budget above the frame capacity is refused, not truncated" {
    const allocator = std.testing.allocator;
    var db = evm.Database.init(allocator);
    defer db.deinit();

    const origin = Address{ .bytes = @as([20]u8, @splat(0xA5)) };
    const target = Address{ .bytes = @as([20]u8, @splat(0xB5)) };

    var vm = try Vm.init(
        allocator,
        &db,
        evm.BlockInfo.init(),
        .{ .gas_limit = 100_000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 },
        0,
        origin,
    );
    defer vm.deinit();

    var result = vm.call(.{ .call = .{
        .caller = origin,
        .to = target,
        .value = 0,
        .input = &.{},
        .gas = std.math.maxInt(u64),
    } });
    defer result.deinit(allocator);

    try std.testing.expect(!result.success);
    try std.testing.expectEqual(@as(?evm.Account, null), try db.get_account(origin.bytes));
}

// C-04: the EIP-4788 and EIP-2935 addresses are ordinary accounts. Without
// deployed code a call to them runs nothing and writes nothing.
test "R1A C-04: system contract addresses are not intercepted natively" {
    const allocator = std.testing.allocator;
    var db = evm.Database.init(allocator);
    defer db.deinit();

    const origin = Address{ .bytes = @as([20]u8, @splat(0xA6)) };
    // EIP-4788 beacon roots contract.
    const beacon_roots = Address{ .bytes = .{ 0x00, 0x0F, 0x3d, 0xf6, 0xD7, 0x32, 0x80, 0x7E, 0xf1, 0x31, 0x9f, 0xB7, 0xB8, 0xbB, 0x85, 0x22, 0xd0, 0xBe, 0xac, 0x02 } };
    // EIP-2935 history storage contract.
    const history = Address{ .bytes = .{ 0x00, 0x00, 0xF9, 0x08, 0x27, 0xF1, 0xC5, 0x3a, 0x10, 0xcb, 0x7A, 0x02, 0x33, 0x5B, 0x17, 0x53, 0x20, 0x00, 0x29, 0x35 } };

    var block = evm.BlockInfo.init();
    block.number = 100;
    block.timestamp = 1_700_000_000;
    var vm = try Vm.init(
        allocator,
        &db,
        block,
        .{ .gas_limit = 1_000_000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 },
        0,
        origin,
    );
    defer vm.deinit();

    // Creating the EVM writes no state.
    try std.testing.expectEqual(@as(usize, 0), db.accounts.count());
    try std.testing.expectEqual(@as(usize, 0), db.storage.count());

    var input = @as([32]u8, @splat(0));
    std.mem.writeInt(u64, input[24..32], 1_700_000_000, .big);

    var beacon_result = vm.call(.{ .call = .{ .caller = origin, .to = beacon_roots, .value = 0, .input = &input, .gas = 1_000_000 } });
    defer beacon_result.deinit(allocator);
    try std.testing.expect(beacon_result.success);
    try std.testing.expectEqual(@as(usize, 0), beacon_result.output.len);

    std.mem.writeInt(u64, input[24..32], 99, .big);
    var history_result = vm.call(.{ .call = .{ .caller = origin, .to = history, .value = 0, .input = &input, .gas = 1_000_000 } });
    defer history_result.deinit(allocator);
    try std.testing.expect(history_result.success);
    try std.testing.expectEqual(@as(usize, 0), history_result.output.len);

    try std.testing.expectEqual(@as(usize, 0), db.storage.count());
}

test "R1A C-04: a failed precompile in STATICCALL and DELEGATECALL closes its snapshots" {
    const allocator = std.testing.allocator;
    var db = evm.Database.init(allocator);
    defer db.deinit();

    const origin = Address{ .bytes = @as([20]u8, @splat(0xA7)) };
    // BN254 pairing rejects input whose length is not a multiple of 192.
    const pairing = Address{ .bytes = @as([19]u8, @splat(0)) ++ [_]u8{0x08} };

    var vm = try Vm.init(
        allocator,
        &db,
        evm.BlockInfo.init(),
        .{ .gas_limit = 1_000_000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 },
        0,
        origin,
    );
    defer vm.deinit();

    var static_result = vm.call(.{ .staticcall = .{ .caller = origin, .to = pairing, .input = &[_]u8{0x01}, .gas = 1_000_000 } });
    defer static_result.deinit(allocator);
    try std.testing.expect(!static_result.success);
    try std.testing.expectEqual(@as(usize, 0), db.snapshot_depth());

    var delegate_result = vm.call(.{ .delegatecall = .{ .caller = origin, .to = pairing, .input = &[_]u8{0x01}, .gas = 1_000_000 } });
    defer delegate_result.deinit(allocator);
    try std.testing.expect(!delegate_result.success);
    try std.testing.expectEqual(@as(usize, 0), db.snapshot_depth());
}

// C-05: EIP-7610. A creation collides with an address that holds storage, even
// when the account has no code and a zero nonce.
test "R1A C-05: CREATE onto an address with storage fails (EIP-7610)" {
    const allocator = std.testing.allocator;
    var db = evm.Database.init(allocator);
    defer db.deinit();

    const origin = Address{ .bytes = @as([20]u8, @splat(0xA8)) };
    const created = try Address.getContractAddress(allocator, origin, 0);
    try db.set_storage(created.bytes, 1, 0xBEEF);

    var vm = try Vm.init(
        allocator,
        &db,
        evm.BlockInfo.init(),
        .{ .gas_limit = 1_000_000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 },
        0,
        origin,
    );
    defer vm.deinit();

    // Init code that deploys empty code: PUSH0 PUSH0 RETURN.
    var result = vm.call(.{ .create = .{ .caller = origin, .value = 0, .init_code = &[_]u8{ 0x5F, 0x5F, 0xF3 }, .gas = 1_000_000 } });
    defer result.deinit(allocator);

    try std.testing.expect(!result.success);
    try std.testing.expectEqual(@as(?evm.Account, null), try db.get_account(created.bytes));
    try std.testing.expectEqual(@as(u256, 0xBEEF), try db.get_storage(created.bytes, 1));
    // The transaction is valid, so the sender's nonce moved.
    try std.testing.expectEqual(@as(u64, 1), (try db.get_account(origin.bytes)).?.nonce);
}

test "R1A C-05: an account with EMPTY_CODE_HASH and no storage does not collide" {
    const allocator = std.testing.allocator;
    var db = evm.Database.init(allocator);
    defer db.deinit();

    const origin = Address{ .bytes = @as([20]u8, @splat(0xA9)) };
    const created = try Address.getContractAddress(allocator, origin, 0);

    // A funded address whose account carries keccak256("") as its code hash.
    var funded = evm.Account.zero();
    funded.balance = 123;
    funded.code_hash = primitives.EMPTY_CODE_HASH;
    try db.set_account(created.bytes, funded);

    var vm = try Vm.init(
        allocator,
        &db,
        evm.BlockInfo.init(),
        .{ .gas_limit = 1_000_000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 },
        0,
        origin,
    );
    defer vm.deinit();

    // Init code that deploys the one-byte contract `00`:
    // PUSH1 0, PUSH0, MSTORE8, PUSH1 1, PUSH0, RETURN
    var result = vm.call(.{ .create = .{ .caller = origin, .value = 0, .init_code = &[_]u8{ 0x60, 0x00, 0x5F, 0x53, 0x60, 0x01, 0x5F, 0xF3 }, .gas = 1_000_000 } });
    defer result.deinit(allocator);

    try std.testing.expect(result.success);
    const deployed = (try db.get_account(created.bytes)).?;
    try std.testing.expectEqual(@as(u256, 123), deployed.balance);
    try std.testing.expectEqual(@as(u64, 1), deployed.nonce);
    try std.testing.expect(deployed.has_code());
}

// C-06: an EIP-7702 delegation to a precompile address runs that account's code
// (empty), never the precompile.
test "R1A C-06: delegation to a precompile executes empty code" {
    const allocator = std.testing.allocator;
    var db = evm.Database.init(allocator);
    defer db.deinit();

    const origin = Address{ .bytes = @as([20]u8, @splat(0xAA)) };
    const delegator = Address{ .bytes = @as([20]u8, @splat(0xBA)) };
    const sha256_precompile = Address{ .bytes = @as([19]u8, @splat(0)) ++ [_]u8{0x02} };

    var delegated = evm.Account.zero();
    delegated.nonce = 1;
    delegated.set_delegation(sha256_precompile);
    try db.set_account(delegator.bytes, delegated);

    var vm = try Vm.init(
        allocator,
        &db,
        evm.BlockInfo.init(),
        .{ .gas_limit = 1_000_000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 },
        0,
        origin,
    );
    defer vm.deinit();

    var delegated_result = vm.call(.{ .call = .{ .caller = origin, .to = delegator, .value = 0, .input = "abc", .gas = 1_000_000 } });
    defer delegated_result.deinit(allocator);
    try std.testing.expect(delegated_result.success);
    try std.testing.expectEqual(@as(usize, 0), delegated_result.output.len);

    // The precompile itself still runs when called directly.
    var direct_result = vm.call(.{ .call = .{ .caller = origin, .to = sha256_precompile, .value = 0, .input = "abc", .gas = 1_000_000 } });
    defer direct_result.deinit(allocator);
    try std.testing.expect(direct_result.success);
    try std.testing.expectEqual(@as(usize, 32), direct_result.output.len);
    try std.testing.expectEqual(@as(u8, 0xBA), direct_result.output[0]); // sha256("abc") = ba7816bf...
}

// C-06: `EvmConfig.precompile_overrides` run end to end and take precedence over
// the fork's standard precompiles.
const Override = @typeInfo(@FieldType(evm.EvmConfig, "precompile_overrides")).pointer.child;
const OverrideOutput = @typeInfo(@typeInfo(@typeInfo(@FieldType(Override, "execute")).pointer.child).@"fn".return_type.?).error_union.payload;

fn overrideExecute(allocator: std.mem.Allocator, input: []const u8, gas_limit: u64) anyerror!OverrideOutput {
    if (gas_limit < 500) return error.OutOfGas;
    const output = try allocator.alloc(u8, input.len + 1);
    output[0] = 0x7A;
    @memcpy(output[1..], input);
    return .{ .output = output, .gas_used = 500, .success = true };
}

test "R1A C-06: configured precompile overrides execute and shadow standard precompiles" {
    const allocator = std.testing.allocator;
    var db = evm.Database.init(allocator);
    defer db.deinit();

    const origin = Address{ .bytes = @as([20]u8, @splat(0xAB)) };
    const custom = Address{ .bytes = @as([18]u8, @splat(0)) ++ [_]u8{ 0x0F, 0x00 } };
    const identity = Address{ .bytes = @as([19]u8, @splat(0)) ++ [_]u8{0x04} };

    const OverrideVm = evm.Evm(.{ .precompile_overrides = &.{
        .{ .address = custom, .execute = &overrideExecute },
        .{ .address = identity, .execute = &overrideExecute },
    } });

    var vm = try OverrideVm.init(
        allocator,
        &db,
        evm.BlockInfo.init(),
        .{ .gas_limit = 1_000_000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 },
        0,
        origin,
    );
    defer vm.deinit();

    var custom_result = vm.call(.{ .call = .{ .caller = origin, .to = custom, .value = 0, .input = "hi", .gas = 100_000 } });
    defer custom_result.deinit(allocator);
    try std.testing.expect(custom_result.success);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x7A, 'h', 'i' }, custom_result.output);
    // 21,000 intrinsic + 2 non-zero calldata bytes + 500 for the precompile.
    try std.testing.expectEqual(@as(u64, 100_000 - 21_000 - 2 * 16 - 500), custom_result.gas_left);

    // Address 0x04 is the identity precompile; the override replaces it.
    var shadowed_result = vm.call(.{ .call = .{ .caller = origin, .to = identity, .value = 0, .input = "hi", .gas = 100_000 } });
    defer shadowed_result.deinit(allocator);
    try std.testing.expect(shadowed_result.success);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x7A, 'h', 'i' }, shadowed_result.output);
}

// H-01: repeated calls to the same contract analyze its code once.
test "R1A H-01: the dispatch cache serves repeated calls by code hash" {
    const allocator = std.testing.allocator;
    var db = evm.Database.init(allocator);
    defer db.deinit();

    const origin = Address{ .bytes = @as([20]u8, @splat(0xAC)) };
    const first = Address{ .bytes = @as([20]u8, @splat(0xBC)) };
    const second = Address{ .bytes = @as([20]u8, @splat(0xBD)) };

    // return 42
    const code = [_]u8{ 0x60, 0x2A, 0x5F, 0x52, 0x60, 0x20, 0x5F, 0xF3 };
    const code_hash = try db.set_code(&code);
    var account = evm.Account.zero();
    account.code_hash = code_hash;
    try db.set_account(first.bytes, account);
    // A second contract with the same code shares the cache entry.
    try db.set_account(second.bytes, account);

    var vm = try Vm.init(
        allocator,
        &db,
        evm.BlockInfo.init(),
        .{ .gas_limit = 100_000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 },
        0,
        origin,
    );
    defer vm.deinit();

    try std.testing.expect(!Vm.tracing_enabled);

    for ([_]Address{ first, first, second, first }) |to| {
        var result = vm.call(.{ .call = .{ .caller = origin, .to = to, .value = 0, .input = &.{}, .gas = 100_000 } });
        defer result.deinit(allocator);
        try std.testing.expect(result.success);
        try std.testing.expectEqual(@as(u256, 42), std.mem.readInt(u256, result.output[0..32], .big));
    }

    try std.testing.expectEqual(@as(u64, 1), vm.dispatch_cache.misses);
    try std.testing.expectEqual(@as(u64, 3), vm.dispatch_cache.hits);
    try std.testing.expectEqual(@as(usize, 1), vm.dispatch_cache.count());

    // Init code is never cached.
    var created = vm.call(.{ .create = .{ .caller = origin, .value = 0, .init_code = &[_]u8{ 0x5F, 0x5F, 0xF3 }, .gas = 100_000 } });
    defer created.deinit(allocator);
    try std.testing.expect(created.success);
    try std.testing.expectEqual(@as(usize, 1), vm.dispatch_cache.count());
    try std.testing.expectEqual(@as(u64, 1), vm.dispatch_cache.misses);
}

test "R1A H-01: the dispatch cache stays bounded and survives reverted deployments" {
    const allocator = std.testing.allocator;
    var db = evm.Database.init(allocator);
    defer db.deinit();

    const origin = Address{ .bytes = @as([20]u8, @splat(0xAD)) };

    var vm = try Vm.init(
        allocator,
        &db,
        evm.BlockInfo.init(),
        .{ .gas_limit = 100_000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 },
        0,
        origin,
    );
    defer vm.deinit();

    // More distinct contracts than the cache holds: PUSH2 <n>, PUSH0, MSTORE, PUSH1 32, PUSH0, RETURN.
    const contracts = Vm.DispatchCache.max_entries + 44;
    var index: u16 = 0;
    while (index < contracts) : (index += 1) {
        const code = [_]u8{ 0x61, @intCast(index >> 8), @intCast(index & 0xFF), 0x5F, 0x52, 0x60, 0x20, 0x5F, 0xF3 };
        var address = Address{ .bytes = @as([20]u8, @splat(0xEE)) };
        std.mem.writeInt(u16, address.bytes[18..20], index, .big);
        var account = evm.Account.zero();
        account.code_hash = try db.set_code(&code);
        try db.set_account(address.bytes, account);

        var result = vm.call(.{ .call = .{ .caller = origin, .to = address, .value = 0, .input = &.{}, .gas = 100_000 } });
        defer result.deinit(allocator);
        try std.testing.expect(result.success);
        try std.testing.expectEqual(@as(u256, index), std.mem.readInt(u256, result.output[0..32], .big));
        try std.testing.expect(vm.dispatch_cache.count() <= Vm.DispatchCache.max_entries);
    }
    try std.testing.expectEqual(@as(u64, contracts), vm.dispatch_cache.misses);

    // A cached entry owns its code: it stays valid after the database drops the
    // code with a reverted snapshot, and serves the code again once redeployed.
    const snapshot = try db.create_snapshot();
    const late_code = [_]u8{ 0x61, 0x12, 0x34, 0x5F, 0x52, 0x60, 0x20, 0x5F, 0xF3 };
    const late = Address{ .bytes = @as([20]u8, @splat(0xDD)) };
    var late_account = evm.Account.zero();
    late_account.code_hash = try db.set_code(&late_code);
    try db.set_account(late.bytes, late_account);
    {
        var result = vm.call(.{ .call = .{ .caller = origin, .to = late, .value = 0, .input = &.{}, .gas = 100_000 } });
        defer result.deinit(allocator);
        try std.testing.expect(result.success);
    }
    try db.revert_to_snapshot(snapshot);
    try std.testing.expectError(evm.Database.Error.CodeNotFound, db.get_code(late_account.code_hash));

    late_account.code_hash = try db.set_code(&late_code);
    try db.set_account(late.bytes, late_account);
    const hits_before = vm.dispatch_cache.hits;
    var again = vm.call(.{ .call = .{ .caller = origin, .to = late, .value = 0, .input = &.{}, .gas = 100_000 } });
    defer again.deinit(allocator);
    try std.testing.expect(again.success);
    try std.testing.expectEqual(@as(u256, 0x1234), std.mem.readInt(u256, again.output[0..32], .big));
    try std.testing.expectEqual(hits_before + 1, vm.dispatch_cache.hits);
}

// H-09: logs reach the caller as owned copies, and nothing leaks.
test "R1A H-09: call returns owned logs" {
    const allocator = std.testing.allocator;
    var db = evm.Database.init(allocator);
    defer db.deinit();

    const origin = Address{ .bytes = @as([20]u8, @splat(0xAE)) };
    const emitter = Address{ .bytes = @as([20]u8, @splat(0xBE)) };

    // MSTORE8(0, 0x55); LOG1(offset 0, size 1, topic 0x99); STOP
    const code = [_]u8{ 0x60, 0x55, 0x5F, 0x53, 0x60, 0x99, 0x60, 0x01, 0x5F, 0xA1, 0x00 };
    var account = evm.Account.zero();
    account.code_hash = try db.set_code(&code);
    try db.set_account(emitter.bytes, account);

    var vm = try Vm.init(
        allocator,
        &db,
        evm.BlockInfo.init(),
        .{ .gas_limit = 100_000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 },
        0,
        origin,
    );
    defer vm.deinit();

    var result = vm.call(.{ .call = .{ .caller = origin, .to = emitter, .value = 0, .input = &.{}, .gas = 100_000 } });
    defer result.deinit(allocator);

    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(usize, 1), result.logs.len);
    try std.testing.expectEqualSlices(u8, &emitter.bytes, &result.logs[0].address.bytes);
    try std.testing.expectEqualSlices(u256, &[_]u256{0x99}, result.logs[0].topics);
    try std.testing.expectEqualSlices(u8, &[_]u8{0x55}, result.logs[0].data);
}
