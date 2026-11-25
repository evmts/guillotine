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

// ---------------------------------------------------------------------------
// Round 2 core/state review findings (lane R2-A)
// ---------------------------------------------------------------------------

/// The EIP-4844 point evaluation input whose commitment and proof are the point at
/// infinity and whose evaluation point and value are zero. The proof is valid.
fn pointEvaluationInput() [192]u8 {
    var input = @as([192]u8, @splat(0));
    input[96] = 0xc0; // commitment
    input[144] = 0xc0; // proof
    var versioned_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(input[96..144], &versioned_hash, .{});
    versioned_hash[0] = 0x01;
    @memcpy(input[0..32], &versioned_hash);
    return input;
}

// R2-01: an EVM for Cancun or later needs the KZG trusted setup for precompile
// 0x0A. `Evm.init` loads it; the host does not have to.
test "R2A R2-01: Evm.init loads the KZG trusted setup and point evaluation verifies" {
    const allocator = std.testing.allocator;
    var db = evm.Database.init(allocator);
    defer db.deinit();

    const origin = Address{ .bytes = @as([20]u8, @splat(0xC1)) };
    const point_evaluation = Address.fromU256(0x0A);

    evm.kzg_setup.deinit(allocator);
    try std.testing.expect(!evm.kzg_setup.isInitialized());

    // A fork without the precompile loads nothing.
    const Shanghai = evm.Evm(.{ .eips = .{ .hardfork = .SHANGHAI } });
    var before_cancun = try Shanghai.init(allocator, &db, evm.BlockInfo.init(), .{ .gas_limit = 200_000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 }, 0, origin);
    before_cancun.deinit();
    try std.testing.expect(!evm.kzg_setup.isInitialized());

    var vm = try Vm.init(allocator, &db, evm.BlockInfo.init(), .{ .gas_limit = 200_000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 }, 0, origin);
    defer vm.deinit();
    try std.testing.expect(evm.kzg_setup.isInitialized());

    const input = pointEvaluationInput();
    var result = vm.call(.{ .call = .{ .caller = origin, .to = point_evaluation, .value = 0, .input = &input, .gas = 200_000 } });
    defer result.deinit(allocator);

    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(?anyerror, null), vm.host_failure);
    try std.testing.expectEqual(@as(usize, 64), result.output.len);
    // FIELD_ELEMENTS_PER_BLOB = 4096
    try std.testing.expectEqual(@as(u256, 4096), std.mem.readInt(u256, result.output[0..32], .big));
}

// R2-01: without the trusted setup the precompile cannot judge a proof. That is a
// host failure that aborts the transaction, never an "invalid input" outcome that
// would consume the gas and be included.
test "R2A R2-01: point evaluation without the trusted setup is a host failure" {
    const allocator = std.testing.allocator;
    var db = evm.Database.init(allocator);
    defer db.deinit();

    const origin = Address{ .bytes = @as([20]u8, @splat(0xC2)) };
    const point_evaluation = Address.fromU256(0x0A);
    var origin_account = evm.Account.zero();
    origin_account.balance = 10_000_000;
    try db.set_account(origin.bytes, origin_account);

    var vm = try Vm.init(allocator, &db, evm.BlockInfo.init(), .{ .gas_limit = 200_000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 }, 1, origin);
    defer vm.deinit();

    // The aborted call is reported as a warning; keep it out of the output.
    const log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = log_level;

    // The host unloads the setup behind the EVM's back.
    evm.kzg_setup.deinit(allocator);
    try std.testing.expect(!evm.kzg_setup.isInitialized());

    const input = pointEvaluationInput();
    {
        var result = vm.call(.{ .call = .{ .caller = origin, .to = point_evaluation, .value = 0, .input = &input, .gas = 200_000 } });
        defer result.deinit(allocator);

        try std.testing.expect(!result.success);
        try std.testing.expectEqual(@as(?anyerror, error.TrustedSetupNotLoaded), vm.host_failure);
        try std.testing.expectEqualStrings("host failure: TrustedSetupNotLoaded", result.error_info.?);
        // Nothing of the transaction remains: no gas was charged, no nonce used.
        const after = (try db.get_account(origin.bytes)).?;
        try std.testing.expectEqual(@as(u256, 10_000_000), after.balance);
        try std.testing.expectEqual(@as(u64, 0), after.nonce);
        try std.testing.expectEqual(@as(usize, 0), db.snapshot_depth());
    }

    // With the setup back, the same EVM runs the same call.
    try evm.kzg_setup.init();
    var result = vm.call(.{ .call = .{ .caller = origin, .to = point_evaluation, .value = 0, .input = &input, .gas = 200_000 } });
    defer result.deinit(allocator);
    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(?anyerror, null), vm.host_failure);
    try std.testing.expectEqual(@as(u64, 1), (try db.get_account(origin.bytes)).?.nonce);
}

// R2-03: a frame's 32 KiB stack came from the call arena and could not be freed
// when the frame returned, so 100,000 returning calls kept 3.2 GiB until the
// transaction ended. Stacks now come from a pool that hands the same buffer to
// one frame after another.
test "R2A R2-03: 100,000 returning STATICCALLs keep the call arena below 64 MiB" {
    const allocator = std.testing.allocator;
    // 100,000 iterations run more instructions than the Debug loop quota allows.
    const Looping = evm.Evm(.{ .loop_quota = null });
    var db = evm.Database.init(allocator);
    defer db.deinit();

    const origin = Address{ .bytes = @as([20]u8, @splat(0xC3)) };
    const looper = Address{ .bytes = @as([20]u8, @splat(0xD3)) };
    const callee = Address{ .bytes = @as([20]u8, @splat(0xE3)) };

    // RETURN(0, 1)
    const callee_code = [_]u8{ 0x60, 0x01, 0x5F, 0xF3 };
    var callee_account = evm.Account.zero();
    callee_account.code_hash = try db.set_code(&callee_code);
    try db.set_account(callee.bytes, callee_account);

    // counter = 100000
    // loop: STATICCALL(gas, callee, 0, 0, 0, 0); if it failed jump to INVALID;
    //       counter -= 1; if counter != 0 goto loop
    const code = [_]u8{
        0x62, 0x01, 0x86, 0xA0, // PUSH3 100000
        0x5B, // JUMPDEST (pc 4)
        0x5F, 0x5F, 0x5F, 0x5F, // PUSH0 x4: retSize retOffset argsSize argsOffset
        0x73, // PUSH20 callee
    } ++ @as([20]u8, @splat(0xE3)) ++ [_]u8{
        0x5A, // GAS
        0xFA, // STATICCALL
        0x15, // ISZERO
        0x60, 0x2D, // PUSH1 45
        0x57, // JUMPI
        0x60, 0x01, // PUSH1 1
        0x90, // SWAP1
        0x03, // SUB
        0x80, // DUP1
        0x60, 0x04, // PUSH1 4
        0x57, // JUMPI
        0x00, // STOP
        0x5B, // JUMPDEST (pc 45)
        0xFE, // INVALID
    };
    var looper_account = evm.Account.zero();
    looper_account.code_hash = try db.set_code(&code);
    try db.set_account(looper.bytes, looper_account);

    var vm = try Looping.init(
        allocator,
        &db,
        evm.BlockInfo.init(),
        .{ .gas_limit = 16_700_000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 },
        0,
        origin,
    );
    defer vm.deinit();

    var result = vm.call(.{ .call = .{ .caller = origin, .to = looper, .value = 0, .input = &.{}, .gas = 16_700_000 } });
    defer result.deinit(allocator);

    // The loop ran to its end: every one of the 100,000 calls returned.
    try std.testing.expect(result.success);
    // The arena keeps its grown capacity (up to its 64 MiB limit) after a call,
    // so this is the most the transaction needed.
    try std.testing.expect(vm.call_arena.queryCapacity() < 64 * 1024 * 1024);
    // Two frames were ever live at once, so two stacks were ever allocated.
    try std.testing.expectEqual(@as(usize, 2), vm.frame_stacks.stacks.items.len);
    try std.testing.expectEqual(@as(usize, 0), vm.frame_stacks.in_use);
}

// R2-03: a call chain deeper than the retained stack count frees the extra
// stacks when its transaction ends.
test "R2A R2-03: the frame stack pool returns the stacks of a deep call chain" {
    const allocator = std.testing.allocator;
    var db = evm.Database.init(allocator);
    defer db.deinit();

    const origin = Address{ .bytes = @as([20]u8, @splat(0xC4)) };
    const recursive = Address{ .bytes = @as([20]u8, @splat(0xD4)) };

    // CALL(gas, self, 0, 0, 0, 0, 0); STOP. Recurses until gas runs out.
    const code = [_]u8{ 0x5F, 0x5F, 0x5F, 0x5F, 0x5F, 0x30, 0x5A, 0xF1, 0x00 };
    var account = evm.Account.zero();
    account.code_hash = try db.set_code(&code);
    try db.set_account(recursive.bytes, account);

    var vm = try Vm.init(allocator, &db, evm.BlockInfo.init(), .{ .gas_limit = 1_000_000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 }, 0, origin);
    defer vm.deinit();

    var result = vm.call(.{ .call = .{ .caller = origin, .to = recursive, .value = 0, .input = &.{}, .gas = 1_000_000 } });
    defer result.deinit(allocator);

    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(usize, 0), vm.frame_stacks.in_use);
    // The chain went deeper than 16 frames, and exactly 16 free stacks remain.
    try std.testing.expectEqual(@as(usize, 16), vm.frame_stacks.stacks.items.len);
}

// R2-04: a host that stores the raw 23-byte designator as code gets a delegated
// EOA: a call runs the delegate's code in the EOA's context.
test "R2A R2-04: raw EIP-7702 designator code set through the database delegates" {
    const allocator = std.testing.allocator;
    var db = evm.Database.init(allocator);
    defer db.deinit();

    const origin = Address{ .bytes = @as([20]u8, @splat(0xC5)) };
    const eoa = Address{ .bytes = @as([20]u8, @splat(0xD5)) };
    const delegate = Address{ .bytes = @as([20]u8, @splat(0xE5)) };

    // SSTORE(0, 7); STOP
    const delegate_code = [_]u8{ 0x60, 0x07, 0x5F, 0x55, 0x00 };
    var delegate_account = evm.Account.zero();
    delegate_account.code_hash = try db.set_code(&delegate_code);
    try db.set_account(delegate.bytes, delegate_account);

    const designator = [_]u8{ 0xef, 0x01, 0x00 } ++ delegate.bytes;
    var eoa_account = evm.Account.zero();
    eoa_account.nonce = 1;
    eoa_account.code_hash = try db.set_code(&designator);
    try db.set_account(eoa.bytes, eoa_account);

    try std.testing.expectEqualSlices(u8, &delegate.bytes, &(try db.get_account(eoa.bytes)).?.delegated_address.?.bytes);

    var vm = try Vm.init(allocator, &db, evm.BlockInfo.init(), .{ .gas_limit = 100_000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 }, 0, origin);
    defer vm.deinit();

    var result = vm.call(.{ .call = .{ .caller = origin, .to = eoa, .value = 0, .input = &.{}, .gas = 100_000 } });
    defer result.deinit(allocator);

    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(u256, 7), try db.get_storage(eoa.bytes, 0));
    try std.testing.expectEqual(@as(u256, 0), try db.get_storage(delegate.bytes, 0));
    // EXTCODE* still see the designator.
    try std.testing.expectEqualSlices(u8, &designator, try vm.get_code(eoa));
}

// R2-16: when the transaction's target is a delegated EOA, the delegate starts
// warm (EIP-7702). Its BALANCE then costs 100 gas, not 2,600.
test "R2A R2-16: the delegate of a delegated transaction target starts warm" {
    const allocator = std.testing.allocator;
    var db = evm.Database.init(allocator);
    defer db.deinit();

    const origin = Address{ .bytes = @as([20]u8, @splat(0xC6)) };
    const eoa = Address{ .bytes = @as([20]u8, @splat(0xD6)) };
    const delegate = Address{ .bytes = @as([20]u8, @splat(0xE6)) };

    // BALANCE(delegate); POP; STOP
    const delegate_code = [_]u8{0x73} ++ delegate.bytes ++ [_]u8{ 0x31, 0x50, 0x00 };
    var delegate_account = evm.Account.zero();
    delegate_account.code_hash = try db.set_code(&delegate_code);
    try db.set_account(delegate.bytes, delegate_account);
    try db.set_delegation(eoa.bytes, delegate.bytes);

    var vm = try Vm.init(allocator, &db, evm.BlockInfo.init(), .{ .gas_limit = 100_000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 }, 0, origin);
    defer vm.deinit();

    var result = vm.call(.{ .call = .{ .caller = origin, .to = eoa, .value = 0, .input = &.{}, .gas = 100_000 } });
    defer result.deinit(allocator);

    try std.testing.expect(result.success);
    // 21,000 intrinsic + PUSH20 (3) + warm BALANCE (100) + POP (2).
    try std.testing.expectEqual(@as(u64, 100_000 - 21_000 - 105), result.gas_left);
}

// R2-06: an allocation can fail at any point of a transaction. Wherever it does,
// the transaction either completes exactly as if nothing had failed, or it is
// reported as a host failure and leaves no trace: no gas charged, no nonce used,
// no storage, no created contract, no coinbase reward. In particular a child
// call or creation is never left committed when its result could not be handed
// to the caller.
test "R2A R2-06: an allocation failure anywhere aborts the whole transaction or changes nothing" {
    const origin = Address{ .bytes = @as([20]u8, @splat(0xC7)) };
    const outer = Address{ .bytes = @as([20]u8, @splat(0xD7)) };
    const inner = Address{ .bytes = @as([20]u8, @splat(0xE7)) };
    const coinbase = Address{ .bytes = @as([20]u8, @splat(0xF7)) };

    // SSTORE(0, 2); MSTORE(0, 42); RETURN(0, 32)
    const inner_code = [_]u8{ 0x60, 0x02, 0x5F, 0x55, 0x60, 0x2A, 0x5F, 0x52, 0x60, 0x20, 0x5F, 0xF3 };
    // SSTORE(0, 1)
    // MSTORE(0, initcode); CREATE(0, 24, 8); POP      initcode deploys one STOP byte
    // CALL(gas, inner, 0, 0, 0, 0, 32); POP
    // RETURN(0, 32)
    const outer_code = [_]u8{
        0x60, 0x01, 0x5F, 0x55,
        0x67, 0x60, 0x00, 0x5F, 0x53, 0x60, 0x01, 0x5F, 0xF3, // PUSH8 initcode
        0x5F, 0x52, // MSTORE(0)
        0x60, 0x08, 0x60, 0x18, 0x5F, 0xF0, 0x50, // CREATE(0, 24, 8); POP
        0x60, 0x20, 0x5F, 0x5F, 0x5F, 0x5F, 0x73, // retSize retOffset argsSize argsOffset value; PUSH20 inner
    } ++ @as([20]u8, @splat(0xE7)) ++ [_]u8{
        0x5A, 0xF1, 0x50, // GAS; CALL; POP
        0x60, 0x20, 0x5F, 0xF3, // RETURN(0, 32)
    };

    const initial_balance: u256 = 1_000_000_000;
    const gas_limit: u64 = 500_000;

    // Every injected failure is reported as a warning; keep them out of the output.
    const log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = log_level;

    // Allocations a full, undisturbed run makes. Failing each of them in turn
    // covers every point at which the transaction can run out of memory.
    var allocations: usize = std.math.maxInt(usize);
    var fail_at: usize = 0;
    var host_failures: usize = 0;
    var first_run = true;
    while (first_run or fail_at < allocations) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        const allocator = failing.allocator();
        var db = evm.Database.init(allocator);
        defer db.deinit();

        var inner_account = evm.Account.zero();
        inner_account.code_hash = try db.set_code(&inner_code);
        try db.set_account(inner.bytes, inner_account);
        var outer_account = evm.Account.zero();
        outer_account.nonce = 1;
        outer_account.code_hash = try db.set_code(&outer_code);
        try db.set_account(outer.bytes, outer_account);
        var origin_account = evm.Account.zero();
        origin_account.balance = initial_balance;
        try db.set_account(origin.bytes, origin_account);
        const accounts_before = db.accounts.count();

        var vm = try Vm.init(allocator, &db, evm.BlockInfo.init(), .{ .gas_limit = gas_limit, .coinbase = coinbase, .chain_id = 1 }, 10, origin);
        defer vm.deinit();
        vm.block_info.coinbase = coinbase;

        const before_call = failing.alloc_index;
        if (!first_run) failing.fail_index = before_call + fail_at;
        var result = vm.call(.{ .call = .{ .caller = origin, .to = outer, .value = 0, .input = &.{}, .gas = gas_limit } });
        failing.fail_index = std.math.maxInt(usize);
        defer result.deinit(allocator);

        if (first_run) {
            allocations = failing.alloc_index - before_call;
            first_run = false;
            try std.testing.expect(result.success);
            try std.testing.expect(allocations > 0);
        } else {
            fail_at += 1;
        }

        const origin_after = (try db.get_account(origin.bytes)).?;
        errdefer std.debug.print("allocation {d} of {d} failed: success={}, host_failure={?}\n", .{ fail_at, allocations, result.success, vm.host_failure });
        try std.testing.expectEqual(@as(usize, 0), db.snapshot_depth());
        if (vm.host_failure != null) {
            host_failures += 1;
            try std.testing.expect(!result.success);
            try std.testing.expectEqual(@as(u64, 0), result.gas_left);
            if (result.error_info) |info| try std.testing.expect(std.mem.startsWith(u8, info, "host failure: "));
            try std.testing.expectEqual(initial_balance, origin_after.balance);
            try std.testing.expectEqual(@as(u64, 0), origin_after.nonce);
            try std.testing.expectEqual(@as(u64, 1), (try db.get_account(outer.bytes)).?.nonce);
            try std.testing.expectEqual(@as(u256, 0), try db.get_storage(outer.bytes, 0));
            try std.testing.expectEqual(@as(u256, 0), try db.get_storage(inner.bytes, 0));
            try std.testing.expectEqual(accounts_before, db.accounts.count());
            continue;
        }
        // No host failure: the transaction is complete in every part.
        try std.testing.expect(result.success);
        try std.testing.expectEqual(@as(u256, 42), std.mem.readInt(u256, result.output[0..32], .big));
        try std.testing.expectEqual(@as(u64, 1), origin_after.nonce);
        try std.testing.expectEqual(@as(u64, 2), (try db.get_account(outer.bytes)).?.nonce);
        try std.testing.expectEqual(@as(u256, 1), try db.get_storage(outer.bytes, 0));
        try std.testing.expectEqual(@as(u256, 2), try db.get_storage(inner.bytes, 0));
        // The created contract and the coinbase are the two new accounts.
        try std.testing.expectEqual(accounts_before + 2, db.accounts.count());
        const gas_used: u256 = gas_limit - result.gas_left;
        try std.testing.expectEqual(initial_balance - gas_used * 10, origin_after.balance);
        try std.testing.expectEqual(gas_used * 10, (try db.get_account(coinbase.bytes)).?.balance);
    }
    // The sweep did hit failures the transaction could not survive.
    try std.testing.expect(host_failures > 0);
}

// R2-25: an invalid transaction is refused with a reason, and is not a host failure.
test "R2A R2-25: rejected transactions say why" {
    const allocator = std.testing.allocator;
    var db = evm.Database.init(allocator);
    defer db.deinit();

    const origin = Address{ .bytes = @as([20]u8, @splat(0xC8)) };
    const target = Address{ .bytes = @as([20]u8, @splat(0xD8)) };
    var origin_account = evm.Account.zero();
    origin_account.balance = 5;
    try db.set_account(origin.bytes, origin_account);

    var vm = try Vm.init(allocator, &db, evm.BlockInfo.init(), .{ .gas_limit = 100_000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 }, 10, origin);
    defer vm.deinit();

    {
        var result = vm.call(.{ .call = .{ .caller = origin, .to = target, .value = 0, .input = &.{}, .gas = 100_000 } });
        defer result.deinit(allocator);
        try std.testing.expect(!result.success);
        try std.testing.expectEqualStrings("invalid transaction: sender balance is below gas limit times max fee per gas plus value", result.error_info.?);
        try std.testing.expectEqual(@as(?anyerror, null), vm.host_failure);
    }
    {
        var result = vm.call(.{ .call = .{ .caller = origin, .to = target, .value = 0, .input = &.{}, .gas = 20_999 } });
        defer result.deinit(allocator);
        try std.testing.expect(!result.success);
        try std.testing.expectEqualStrings("invalid transaction: gas limit is below the intrinsic gas cost", result.error_info.?);
    }
    {
        // EIP-7825 (Osaka): TX_GAS_LIMIT_CAP is 2^24.
        var result = vm.call(.{ .call = .{ .caller = origin, .to = target, .value = 0, .input = &.{}, .gas = (1 << 24) + 1 } });
        defer result.deinit(allocator);
        try std.testing.expect(!result.success);
        try std.testing.expectEqualStrings("invalid transaction: gas limit exceeds the EIP-7825 transaction gas cap", result.error_info.?);
    }
    {
        var at_limit = evm.Account.zero();
        at_limit.balance = 10_000_000;
        at_limit.nonce = std.math.maxInt(u64);
        try db.set_account(origin.bytes, at_limit);
        var result = vm.call(.{ .call = .{ .caller = origin, .to = target, .value = 0, .input = &.{}, .gas = 100_000 } });
        defer result.deinit(allocator);
        try std.testing.expect(!result.success);
        try std.testing.expectEqualStrings("invalid transaction: sender nonce is at the EIP-2681 limit", result.error_info.?);
        try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), (try db.get_account(origin.bytes)).?.nonce);
    }
}

// R2-09: with gas checks disabled a budget below the intrinsic cost used to
// underflow when the execution gas was computed. It is refused instead.
test "R2A R2-09: a gas limit below the intrinsic cost is refused with gas checks disabled" {
    const allocator = std.testing.allocator;
    const Unchecked = evm.Evm(.{ .disable_gas_checks = true });
    var db = evm.Database.init(allocator);
    defer db.deinit();

    const origin = Address{ .bytes = @as([20]u8, @splat(0xC9)) };
    const target = Address{ .bytes = @as([20]u8, @splat(0xD9)) };

    var vm = try Unchecked.init(allocator, &db, evm.BlockInfo.init(), .{ .gas_limit = 100_000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 }, 0, origin);
    defer vm.deinit();

    var result = vm.call(.{ .call = .{ .caller = origin, .to = target, .value = 0, .input = &.{}, .gas = 20_999 } });
    defer result.deinit(allocator);

    try std.testing.expect(!result.success);
    try std.testing.expectEqualStrings("invalid transaction: gas limit is below the intrinsic gas cost", result.error_info.?);
    try std.testing.expectEqual(@as(?evm.Account, null), try db.get_account(origin.bytes));
}

// R2-14, R2-40: SELFDESTRUCT before Cancun deletes the account with all of its
// storage, in time proportional to that account's slots, and the result reports
// the destruction on every fork.
test "R2A R2-14: a pre-Cancun SELFDESTRUCT deletes the account's storage and is reported" {
    const allocator = std.testing.allocator;
    const Shanghai = evm.Evm(.{ .eips = .{ .hardfork = .SHANGHAI } });
    var db = evm.Database.init(allocator);
    defer db.deinit();

    const origin = Address{ .bytes = @as([20]u8, @splat(0xCA)) };
    const doomed = Address{ .bytes = @as([20]u8, @splat(0xDA)) };
    const neighbour = Address{ .bytes = @as([20]u8, @splat(0xEA)) };
    const beneficiary = Address{ .bytes = @as([20]u8, @splat(0xFA)) };

    // SELFDESTRUCT(beneficiary)
    const code = [_]u8{0x73} ++ beneficiary.bytes ++ [_]u8{0xFF};
    var account = evm.Account.zero();
    account.balance = 9;
    account.code_hash = try db.set_code(&code);
    try db.set_account(doomed.bytes, account);
    try db.set_storage(doomed.bytes, 1, 11);
    try db.set_storage(doomed.bytes, 2, 22);
    try db.set_storage(neighbour.bytes, 1, 33);

    var vm = try Shanghai.init(allocator, &db, evm.BlockInfo.init(), .{ .gas_limit = 100_000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 }, 0, origin);
    defer vm.deinit();

    // A simulation sees the destruction and leaves base state alone.
    {
        var simulated = vm.simulate(.{ .call = .{ .caller = origin, .to = doomed, .value = 0, .input = &.{}, .gas = 100_000 } });
        defer simulated.deinit(allocator);
        try std.testing.expect(simulated.success);
        try std.testing.expectEqual(@as(usize, 1), simulated.selfdestructs.len);
        try std.testing.expect(db.account_exists(doomed.bytes));
        try std.testing.expectEqual(@as(u256, 11), try db.get_storage(doomed.bytes, 1));
        try std.testing.expectEqual(@as(u256, 22), try db.get_storage(doomed.bytes, 2));
        try std.testing.expectEqual(@as(usize, 0), db.overlay_storage.count());
    }

    var result = vm.call(.{ .call = .{ .caller = origin, .to = doomed, .value = 0, .input = &.{}, .gas = 100_000 } });
    defer result.deinit(allocator);

    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(usize, 1), result.selfdestructs.len);
    try std.testing.expectEqualSlices(u8, &doomed.bytes, &result.selfdestructs[0].contract.bytes);
    try std.testing.expectEqualSlices(u8, &beneficiary.bytes, &result.selfdestructs[0].beneficiary.bytes);

    try std.testing.expect(!db.account_exists(doomed.bytes));
    try std.testing.expect(!(try db.has_storage(doomed.bytes)));
    try std.testing.expectEqual(@as(u256, 0), try db.get_storage(doomed.bytes, 1));
    try std.testing.expectEqual(@as(u256, 0), try db.get_storage(doomed.bytes, 2));
    try std.testing.expectEqual(@as(u256, 9), (try db.get_account(beneficiary.bytes)).?.balance);
    try std.testing.expectEqual(@as(u256, 33), try db.get_storage(neighbour.bytes, 1));
}

// R2-24: the touched sets, and so `dumpState`, cover every call made on an EVM,
// until the host resets them.
test "R2A R2-24: touched addresses accumulate across calls until resetTouched" {
    const allocator = std.testing.allocator;
    var db = evm.Database.init(allocator);
    defer db.deinit();

    const origin = Address{ .bytes = @as([20]u8, @splat(0xCB)) };
    const first = Address{ .bytes = @as([20]u8, @splat(0xDB)) };
    const second = Address{ .bytes = @as([20]u8, @splat(0xEB)) };
    var origin_account = evm.Account.zero();
    origin_account.balance = 100;
    try db.set_account(origin.bytes, origin_account);

    var vm = try Vm.init(allocator, &db, evm.BlockInfo.init(), .{ .gas_limit = 100_000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 }, 0, origin);
    defer vm.deinit();

    var first_result = vm.call(.{ .call = .{ .caller = origin, .to = first, .value = 1, .input = &.{}, .gas = 100_000 } });
    defer first_result.deinit(allocator);
    try std.testing.expect(first_result.success);
    var second_result = vm.call(.{ .call = .{ .caller = origin, .to = second, .value = 2, .input = &.{}, .gas = 100_000 } });
    defer second_result.deinit(allocator);
    try std.testing.expect(second_result.success);

    try std.testing.expect(vm.touched_addresses.contains(first));
    try std.testing.expect(vm.touched_addresses.contains(second));
    {
        var dump = try vm.dumpState(allocator);
        defer dump.deinit(allocator);
        try std.testing.expectEqual(@as(u256, 1), dump.accounts.get("0xdbdbdbdbdbdbdbdbdbdbdbdbdbdbdbdbdbdbdbdb").?.balance);
        try std.testing.expectEqual(@as(u256, 2), dump.accounts.get("0xebebebebebebebebebebebebebebebebebebebeb").?.balance);
    }

    vm.resetTouched();
    try std.testing.expectEqual(@as(usize, 0), vm.touched_addresses.count());
}

// R2-14: deleting an account deletes its storage in the layer a read sees, costs
// one write per non-zero slot of that account, and is undone by a revert.
test "R2A R2-14: Database.delete_account clears storage in base and overlay" {
    const allocator = std.testing.allocator;
    var db = evm.Database.init(allocator);
    defer db.deinit();

    const doomed = @as([20]u8, @splat(0xCC));
    const neighbour = @as([20]u8, @splat(0xDC));
    try db.set_balance(doomed, 5);
    try db.set_storage(doomed, 1, 11);
    try db.set_storage(doomed, 2, 22);
    var key: u256 = 0;
    while (key < 1000) : (key += 1) try db.set_storage(neighbour, key, key + 1);

    // In an ephemeral view the deletion hides base storage and writes none of it.
    db.begin_ephemeral_view();
    try db.set_storage(doomed, 3, 33);
    try db.delete_account(doomed);
    try std.testing.expect(!db.account_exists(doomed));
    try std.testing.expect(!(try db.has_storage(doomed)));
    try std.testing.expectEqual(@as(u256, 0), try db.get_storage(doomed, 1));
    try std.testing.expectEqual(@as(u256, 0), try db.get_storage(doomed, 3));
    db.discard_ephemeral_view();
    try std.testing.expectEqual(@as(u256, 11), try db.get_storage(doomed, 1));
    try std.testing.expectEqual(@as(u256, 22), try db.get_storage(doomed, 2));

    const snapshot = try db.create_snapshot();
    try db.delete_account(doomed);
    // Two slot writes and the account removal: the neighbour's 1000 slots cost nothing.
    try std.testing.expectEqual(@as(usize, 3), db.undo_log.items.len);
    try std.testing.expect(!db.account_exists(doomed));
    try std.testing.expect(!(try db.has_storage(doomed)));
    try std.testing.expectEqual(@as(?usize, 0), db.storage_slot_counts.get(doomed));
    try std.testing.expectEqual(@as(?usize, 1000), db.storage_slot_counts.get(neighbour));

    try db.revert_to_snapshot(snapshot);
    try std.testing.expectEqual(@as(u256, 5), try db.get_balance(doomed));
    try std.testing.expectEqual(@as(u256, 11), try db.get_storage(doomed, 1));
    try std.testing.expectEqual(@as(u256, 22), try db.get_storage(doomed, 2));
    try std.testing.expectEqual(@as(?usize, 2), db.storage_slot_counts.get(doomed));
}

// R2-04: only the exact 23-byte designator is a delegation, and setting other
// code on a delegated account ends the delegation.
test "R2A R2-04: Database.set_account normalizes designators and nothing else" {
    const allocator = std.testing.allocator;
    var db = evm.Database.init(allocator);
    defer db.deinit();

    const delegate = @as([20]u8, @splat(0xEC));
    const designator = [_]u8{ 0xef, 0x01, 0x00 } ++ delegate;
    const too_long = designator ++ [_]u8{0x00};
    const wrong_prefix = [_]u8{ 0xef, 0x01, 0x01 } ++ delegate;

    for ([_][]const u8{ designator[0..22], &too_long, &wrong_prefix }, 0..) |code, index| {
        const address = @as([20]u8, @splat(@intCast(0x10 + index)));
        var account = evm.Account.zero();
        account.code_hash = try db.set_code(code);
        try db.set_account(address, account);
        const stored = (try db.get_account(address)).?;
        try std.testing.expect(stored.delegated_address == null);
        try std.testing.expectEqualSlices(u8, code, try db.get_code(stored.code_hash));
    }

    const eoa = @as([20]u8, @splat(0xFC));
    var account = evm.Account.zero();
    account.code_hash = try db.set_code(&designator);
    try db.set_account(eoa, account);
    var stored = (try db.get_account(eoa)).?;
    try std.testing.expectEqualSlices(u8, &delegate, &stored.delegated_address.?.bytes);
    try std.testing.expect(!evm.Account.is_code_hash_present(stored.code_hash));

    stored.code_hash = try db.set_code(&[_]u8{ 0x60, 0x00 });
    try db.set_account(eoa, stored);
    const replaced = (try db.get_account(eoa)).?;
    try std.testing.expect(replaced.delegated_address == null);
    try std.testing.expect(evm.Account.is_code_hash_present(replaced.code_hash));
}

// R2-19: calldata has no size limit of its own; the gas it costs bounds it. A
// call with more than 4 MiB of input used to be refused.
test "R2A R2-19: a call accepts more than 4 MiB of input" {
    const allocator = std.testing.allocator;
    // Before Prague there is no calldata floor and no transaction gas cap, so
    // 4 MiB of zero bytes costs 4 gas each.
    const Cancun = evm.Evm(.{ .eips = .{ .hardfork = .CANCUN } });
    var db = evm.Database.init(allocator);
    defer db.deinit();

    const origin = Address{ .bytes = @as([20]u8, @splat(0xCD)) };
    const target = Address{ .bytes = @as([20]u8, @splat(0xDD)) };

    const input = try allocator.alloc(u8, 4 * 1024 * 1024 + 1);
    defer allocator.free(input);
    @memset(input, 0);

    var vm = try Cancun.init(allocator, &db, evm.BlockInfo.init(), .{ .gas_limit = 17_000_000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 }, 0, origin);
    defer vm.deinit();

    var result = vm.call(.{ .call = .{ .caller = origin, .to = target, .value = 0, .input = input, .gas = 17_000_000 } });
    defer result.deinit(allocator);

    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(u64, 17_000_000 - 21_000 - 4 * (4 * 1024 * 1024 + 1)), result.gas_left);
}
