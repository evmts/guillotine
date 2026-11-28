//! Regression tests for state that must be all-or-nothing or left untouched:
//!
//! - W3-3: `Evm.dumpState` lists EIP-7702 delegated EOAs with their designator,
//!   accepts `EMPTY_CODE_HASH` accounts, lists the credited coinbase and leaks
//!   nothing when an allocation fails.
//! - W3-4: `Evm.simulate` hands back return data and state-dump tracking
//!   unchanged, and keeps the writes of an ephemeral view opened around it.
//! - W3-5: `Evm.beginBlock` applies EIP-4788 and EIP-2935 together or not at all.
//! - W3-6: EIP-6780 creation marks are rolled back with the frame that made them.
//! - W3-9: an EIP-7702 authorization list is applied atomically.
//!
//! Every test builds its own database and EVM and runs through public entry points.

const std = @import("std");
const testing = std.testing;
const evm = @import("evm");
const primitives = @import("voltaire");
const Address = primitives.Address;
const crypto = @import("crypto").Crypto;

const Vm = evm.Evm(.{});
const zero_hash = @as([32]u8, @splat(0));

test "W3-3: dumpState keeps a zero-balance zero-nonce EIP-7702 delegated EOA with its 23-byte designator" {
    const allocator = testing.allocator;
    var db = evm.Database.init(allocator);
    defer db.deinit();

    const origin = Address{ .bytes = @as([20]u8, @splat(0xA1)) };
    const delegated = Address{ .bytes = @as([20]u8, @splat(0xD7)) };
    const delegate = Address{ .bytes = @as([20]u8, @splat(0xDE)) };

    try db.set_account(origin.bytes, .{ .balance = 1_000_000, .nonce = 0, .code_hash = zero_hash, .storage_root = zero_hash });
    try db.set_account(delegate.bytes, .{
        .balance = 0,
        .nonce = 1,
        .code_hash = try db.set_code(&[_]u8{0x00}),
        .storage_root = zero_hash,
    });
    try db.set_delegation(delegated.bytes, delegate.bytes);
    const stored = (try db.get_account(delegated.bytes)).?;
    try testing.expectEqual(@as(u256, 0), stored.balance);
    try testing.expectEqual(@as(u64, 0), stored.nonce);
    try testing.expect(!evm.Account.is_code_hash_present(stored.code_hash));

    var vm = try Vm.init(
        allocator,
        &db,
        evm.BlockInfo.init(),
        .{ .gas_limit = 16_000_000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 },
        0,
        origin,
    );
    defer vm.deinit();

    var result = vm.call(.{ .call = .{ .caller = origin, .to = delegated, .value = 0, .input = &.{}, .gas = 100_000 } });
    defer result.deinit(allocator);
    try testing.expect(result.success);

    var dump = try vm.dumpState(allocator);
    defer dump.deinit(allocator);
    const key = "0xd7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7d7";
    const entry = dump.accounts.get(key) orelse return error.DelegatedEoaMissingFromDump;
    try testing.expectEqual(@as(u256, 0), entry.balance);
    try testing.expectEqual(@as(u64, 0), entry.nonce);
    const designator = [_]u8{ 0xef, 0x01, 0x00 } ++ delegate.bytes;
    try testing.expectEqual(@as(usize, 23), entry.code.len);
    try testing.expectEqualSlices(u8, &designator, entry.code);
}

test "W3-3: dumpState accepts an EMPTY_CODE_HASH account instead of failing with CodeNotFound" {
    const allocator = testing.allocator;
    var db = evm.Database.init(allocator);
    defer db.deinit();

    const origin = Address{ .bytes = @as([20]u8, @splat(0xA1)) };
    const plain = Address{ .bytes = @as([20]u8, @splat(0xE0)) };
    try db.set_account(origin.bytes, .{ .balance = 1_000_000, .nonce = 0, .code_hash = zero_hash, .storage_root = zero_hash });
    try db.set_account(plain.bytes, .{
        .balance = 5,
        .nonce = 3,
        .code_hash = primitives.EMPTY_CODE_HASH,
        .storage_root = zero_hash,
    });

    var vm = try Vm.init(
        allocator,
        &db,
        evm.BlockInfo.init(),
        .{ .gas_limit = 16_000_000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 },
        0,
        origin,
    );
    defer vm.deinit();

    var result = vm.call(.{ .call = .{ .caller = origin, .to = plain, .value = 2, .input = &.{}, .gas = 100_000 } });
    defer result.deinit(allocator);
    try testing.expect(result.success);

    var dump = try vm.dumpState(allocator);
    defer dump.deinit(allocator);
    const entry = dump.accounts.get("0xe0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0") orelse return error.AccountMissingFromDump;
    try testing.expectEqual(@as(u256, 7), entry.balance);
    try testing.expectEqual(@as(u64, 3), entry.nonce);
    try testing.expectEqual(@as(usize, 0), entry.code.len);
}

test "W3-3: dumpState lists the coinbase that a transaction's fee credited" {
    const allocator = testing.allocator;
    var db = evm.Database.init(allocator);
    defer db.deinit();

    const origin = Address{ .bytes = @as([20]u8, @splat(0xA1)) };
    const target = Address{ .bytes = @as([20]u8, @splat(0x7A)) };
    const coinbase = Address{ .bytes = @as([20]u8, @splat(0xC0)) };
    try db.set_account(origin.bytes, .{
        .balance = 1_000_000_000_000,
        .nonce = 0,
        .code_hash = zero_hash,
        .storage_root = zero_hash,
    });
    try db.set_account(target.bytes, .{
        .balance = 0,
        .nonce = 1,
        .code_hash = try db.set_code(&[_]u8{0x00}),
        .storage_root = zero_hash,
    });

    const block = evm.BlockInfo{
        .chain_id = 1,
        .number = 1,
        .timestamp = 1,
        .difficulty = 0,
        .gas_limit = 30_000_000,
        .coinbase = coinbase,
        .base_fee = 0,
        .prev_randao = zero_hash,
    };
    var vm = try Vm.init(allocator, &db, block, .{ .gas_limit = 30_000_000, .coinbase = coinbase, .chain_id = 1 }, 10, origin);
    defer vm.deinit();

    var result = vm.call(.{ .call = .{ .caller = origin, .to = target, .value = 0, .input = &.{}, .gas = 100_000 } });
    defer result.deinit(allocator);
    try testing.expect(result.success);

    // 21000 gas at a price of 10 with no base fee goes to the coinbase in full.
    const credited = try db.get_balance(coinbase.bytes);
    try testing.expectEqual(@as(u256, 210_000), credited);

    var dump = try vm.dumpState(allocator);
    defer dump.deinit(allocator);
    const entry = dump.accounts.get("0xc0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0") orelse return error.CoinbaseMissingFromDump;
    try testing.expectEqual(credited, entry.balance);
}

test "W3-3: dumpState leaks nothing when any of its allocations fails" {
    const allocator = testing.allocator;
    var db = evm.Database.init(allocator);
    defer db.deinit();

    const origin = Address{ .bytes = @as([20]u8, @splat(0xA1)) };
    const writer = Address{ .bytes = @as([20]u8, @splat(0x5E)) };
    const delegated = Address{ .bytes = @as([20]u8, @splat(0xD7)) };
    // SSTORE(1, 1) SSTORE(2, 2), then CALL the delegated EOA so the dump holds it too.
    const code = [_]u8{ 0x60, 0x01, 0x60, 0x01, 0x55, 0x60, 0x02, 0x60, 0x02, 0x55 } ++
        [_]u8{ 0x5F, 0x5F, 0x5F, 0x5F, 0x5F, 0x73 } ++ delegated.bytes ++ [_]u8{ 0x5A, 0xF1, 0x00 };
    try db.set_account(origin.bytes, .{ .balance = 1_000_000, .nonce = 0, .code_hash = zero_hash, .storage_root = zero_hash });
    try db.set_account(writer.bytes, .{
        .balance = 0,
        .nonce = 1,
        .code_hash = try db.set_code(&code),
        .storage_root = zero_hash,
    });
    try db.set_delegation(delegated.bytes, writer.bytes);

    var vm = try Vm.init(
        allocator,
        &db,
        evm.BlockInfo.init(),
        .{ .gas_limit = 16_000_000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 },
        0,
        origin,
    );
    defer vm.deinit();
    var result = vm.call(.{ .call = .{ .caller = origin, .to = writer, .value = 0, .input = &.{}, .gas = 500_000 } });
    defer result.deinit(allocator);
    try testing.expect(result.success);

    var failures: usize = 0;
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_index });
        if (vm.dumpState(failing.allocator())) |ok| {
            var dump = ok;
            try testing.expect(dump.accounts.count() >= 3);
            const entry = dump.accounts.get("0x5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e") orelse return error.AccountMissingFromDump;
            try testing.expectEqual(@as(usize, 2), entry.storage.count());
            dump.deinit(failing.allocator());
            try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
            break;
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            // Every byte allocated before the failure was released again.
            try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
            failures += 1;
        }
    }
    // Keys, code, storage maps and the account table each allocate at least once.
    try testing.expect(failures >= 8);
}

test "W3-4: simulate leaves return data, state-dump tracking, origin and state unchanged" {
    const allocator = testing.allocator;
    var db = evm.Database.init(allocator);
    defer db.deinit();

    const origin = Address{ .bytes = @as([20]u8, @splat(0xA1)) };
    const first = Address{ .bytes = @as([20]u8, @splat(0xAA)) };
    const second = Address{ .bytes = @as([20]u8, @splat(0xBB)) };
    // SSTORE(calldata word 0, 1); return the 32-byte word 0x2a.
    const first_code = [_]u8{ 0x60, 0x01, 0x5F, 0x35, 0x55, 0x60, 0x2A, 0x5F, 0x52, 0x60, 0x20, 0x5F, 0xF3 };
    // SSTORE(7, 7); return 64 bytes.
    const second_code = [_]u8{ 0x60, 0x07, 0x60, 0x07, 0x55, 0x60, 0xBB, 0x5F, 0x52, 0x60, 0x40, 0x5F, 0xF3 };
    try db.set_account(origin.bytes, .{ .balance = 1_000_000, .nonce = 0, .code_hash = zero_hash, .storage_root = zero_hash });
    try db.set_account(first.bytes, .{
        .balance = 0,
        .nonce = 1,
        .code_hash = try db.set_code(&first_code),
        .storage_root = zero_hash,
    });
    try db.set_account(second.bytes, .{
        .balance = 0,
        .nonce = 1,
        .code_hash = try db.set_code(&second_code),
        .storage_root = zero_hash,
    });

    var vm = try Vm.init(
        allocator,
        &db,
        evm.BlockInfo.init(),
        .{ .gas_limit = 16_000_000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 },
        0,
        origin,
    );
    defer vm.deinit();

    var slot_one = @as([32]u8, @splat(0));
    slot_one[31] = 1;
    var committed = vm.call(.{ .call = .{ .caller = origin, .to = first, .value = 0, .input = &slot_one, .gas = 200_000 } });
    defer committed.deinit(allocator);
    try testing.expect(committed.success);

    const return_data_before = try allocator.dupe(u8, vm.get_return_data() orelse return error.NoReturnData);
    defer allocator.free(return_data_before);
    try testing.expectEqual(@as(usize, 32), return_data_before.len);
    const root_before = try db.get_state_root();
    const touched_before = vm.touched_addresses.count();
    const log_before = vm.transaction_touched.items.len;
    const storage_addresses_before = vm.touched_storage.count();
    var dump_before = try vm.dumpState(allocator);
    defer dump_before.deinit(allocator);

    // A new address with a new slot, then a new slot of an address already tracked.
    var simulated = vm.simulate(.{ .call = .{ .caller = origin, .to = second, .value = 0, .input = &.{}, .gas = 200_000 } });
    defer simulated.deinit(allocator);
    try testing.expect(simulated.success);
    try testing.expectEqual(@as(usize, 64), simulated.output.len);
    var slot_nine = @as([32]u8, @splat(0));
    slot_nine[31] = 9;
    var again = vm.simulate(.{ .call = .{ .caller = origin, .to = first, .value = 0, .input = &slot_nine, .gas = 200_000 } });
    defer again.deinit(allocator);
    try testing.expect(again.success);
    try testing.expectEqual(@as(u8, 0x2A), again.output[31]);

    try testing.expectEqualSlices(u8, return_data_before, vm.get_return_data() orelse return error.NoReturnData);
    try testing.expect(vm.origin.equals(origin));
    try testing.expectEqual(touched_before, vm.touched_addresses.count());
    try testing.expectEqual(log_before, vm.transaction_touched.items.len);
    try testing.expect(!vm.touched_addresses.contains(second));
    try testing.expectEqual(storage_addresses_before, vm.touched_storage.count());
    try testing.expect(vm.touched_storage.get(second) == null);
    const first_slots = vm.touched_storage.get(first) orelse return error.TrackedSlotsLost;
    try testing.expectEqual(@as(usize, 1), first_slots.count());
    try testing.expect(first_slots.contains(1));
    try testing.expect(!first_slots.contains(9));

    try testing.expectEqualSlices(u8, &root_before, &(try db.get_state_root()));
    try testing.expectEqual(@as(u256, 0), try db.get_storage(second.bytes, 7));
    try testing.expectEqual(@as(u256, 0), try db.get_storage(first.bytes, 9));
    try testing.expectEqual(@as(u64, 1), try db.get_nonce(origin.bytes));
    try testing.expectEqual(@as(usize, 0), db.ephemeral_view_depth());

    var dump_after = try vm.dumpState(allocator);
    defer dump_after.deinit(allocator);
    try testing.expectEqual(dump_before.accounts.count(), dump_after.accounts.count());
    var it = dump_before.accounts.iterator();
    while (it.next()) |before| {
        const after = dump_after.accounts.get(before.key_ptr.*) orelse return error.AccountMissingFromDump;
        try testing.expectEqual(before.value_ptr.balance, after.balance);
        try testing.expectEqual(before.value_ptr.nonce, after.nonce);
        try testing.expectEqualSlices(u8, before.value_ptr.code, after.code);
        try testing.expectEqual(before.value_ptr.storage.count(), after.storage.count());
    }

    // A real call after the simulations still records what it touches.
    var real = vm.call(.{ .call = .{ .caller = origin, .to = second, .value = 0, .input = &.{}, .gas = 200_000 } });
    defer real.deinit(allocator);
    try testing.expect(real.success);
    try testing.expect(vm.touched_addresses.contains(second));
    try testing.expect((vm.touched_storage.get(second) orelse return error.TrackedSlotsLost).contains(7));
}

test "W3-4: simulate inside an open ephemeral view keeps the caller's overlay writes" {
    const allocator = testing.allocator;
    var db = evm.Database.init(allocator);
    defer db.deinit();

    const origin = Address{ .bytes = @as([20]u8, @splat(0xA1)) };
    const target = Address{ .bytes = @as([20]u8, @splat(0xAA)) };
    const scratch = Address{ .bytes = @as([20]u8, @splat(0x5C)) };
    // SSTORE(9, 1); TSTORE(3, 4); return SLOAD(5) of this contract.
    const code = [_]u8{
        0x60, 0x01, 0x60, 0x09, 0x55,
        0x60, 0x04, 0x60, 0x03, 0x5D,
        0x60, 0x05, 0x54, 0x5F, 0x52,
        0x60, 0x20, 0x5F, 0xF3,
    };
    try db.set_account(origin.bytes, .{ .balance = 1_000_000, .nonce = 0, .code_hash = zero_hash, .storage_root = zero_hash });
    try db.set_account(target.bytes, .{
        .balance = 0,
        .nonce = 1,
        .code_hash = try db.set_code(&code),
        .storage_root = zero_hash,
    });

    var vm = try Vm.init(
        allocator,
        &db,
        evm.BlockInfo.init(),
        .{ .gas_limit = 16_000_000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 },
        0,
        origin,
    );
    defer vm.deinit();

    // The caller's own what-if state: visible to the simulation, never committed.
    try db.begin_ephemeral_view();
    try db.set_storage(target.bytes, 5, 55);
    try db.set_storage(scratch.bytes, 1, 11);
    try db.set_balance(scratch.bytes, 77);
    try db.set_transient_storage(scratch.bytes, 2, 22);

    var result = vm.simulate(.{ .call = .{ .caller = origin, .to = target, .value = 0, .input = &.{}, .gas = 200_000 } });
    defer result.deinit(allocator);
    try testing.expect(result.success);
    // The simulated call read the caller's overlay write.
    try testing.expectEqual(@as(u8, 55), result.output[31]);

    try testing.expectEqual(@as(usize, 1), db.ephemeral_view_depth());
    try testing.expectEqual(@as(u256, 55), try db.get_storage(target.bytes, 5));
    try testing.expectEqual(@as(u256, 11), try db.get_storage(scratch.bytes, 1));
    try testing.expectEqual(@as(u256, 77), try db.get_balance(scratch.bytes));
    try testing.expectEqual(@as(u256, 22), try db.get_transient_storage(scratch.bytes, 2));
    // The simulation's own writes are gone.
    try testing.expectEqual(@as(u256, 0), try db.get_storage(target.bytes, 9));
    try testing.expectEqual(@as(u256, 0), try db.get_transient_storage(target.bytes, 3));
    try testing.expectEqual(@as(u64, 0), try db.get_nonce(origin.bytes));

    db.discard_ephemeral_view();
    try testing.expectEqual(@as(u256, 0), try db.get_storage(target.bytes, 5));
    try testing.expectEqual(@as(u256, 0), try db.get_storage(scratch.bytes, 1));
    try testing.expect(!db.account_exists(scratch.bytes));
    try testing.expect(db.overlayIsClean());
}

test "W3-5: beginBlock leaves state unchanged when EIP-2935 rejects non-canonical code after the EIP-4788 writes" {
    const allocator = testing.allocator;
    var db = evm.Database.init(allocator);
    defer db.deinit();

    const beacon = evm.beacon_roots.BEACON_ROOTS_ADDRESS;
    const history = evm.historical_block_hashes.HISTORY_CONTRACT_ADDRESS;
    try db.set_account(beacon.bytes, .{
        .balance = 0,
        .nonce = 1,
        .code_hash = try db.set_code(&evm.beacon_roots.BEACON_ROOTS_CODE),
        .storage_root = zero_hash,
    });
    try db.set_account(history.bytes, .{
        .balance = 0,
        .nonce = 1,
        .code_hash = try db.set_code(&[_]u8{ 0x60, 0x00, 0x00 }),
        .storage_root = zero_hash,
    });

    var block = evm.BlockInfo.init();
    block.number = 5;
    block.timestamp = 1000;
    block.beacon_root = @as([32]u8, @splat(0xBE));
    block.parent_hash = @as([32]u8, @splat(0xAA));
    var vm = try Vm.init(
        allocator,
        &db,
        block,
        .{ .gas_limit = 16_000_000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 },
        0,
        primitives.ZERO_ADDRESS,
    );
    defer vm.deinit();

    const root_before = try db.get_state_root();
    try testing.expectError(error.NonCanonicalSystemContractCode, vm.beginBlock());
    try testing.expectEqualSlices(u8, &root_before, &(try db.get_state_root()));
    try testing.expectEqual(@as(u256, 0), try db.get_storage(beacon.bytes, 1000));
    try testing.expectEqual(@as(u256, 0), try db.get_storage(beacon.bytes, 1000 + 8191));
    try testing.expectEqual(@as(usize, 0), db.snapshot_depth());

    // With canonical code both updates land.
    var canonical = (try db.get_account(history.bytes)).?;
    canonical.code_hash = try db.set_code(&evm.historical_block_hashes.HISTORY_CODE);
    try db.set_account(history.bytes, canonical);
    try vm.beginBlock();
    try testing.expectEqual(@as(u256, 1000), try db.get_storage(beacon.bytes, 1000));
    try testing.expectEqual(
        std.mem.readInt(u256, &block.beacon_root.?, .big),
        try db.get_storage(beacon.bytes, 1000 + 8191),
    );
    try testing.expectEqual(std.mem.readInt(u256, &block.parent_hash, .big), try db.get_storage(history.bytes, 4));
    try testing.expectEqual(@as(usize, 0), db.snapshot_depth());
}

test "W3-5: a failed second EIP-4788 write takes the first one back" {
    const allocator = testing.allocator;
    var db = evm.Database.init(allocator);
    defer db.deinit();

    const beacon = evm.beacon_roots.BEACON_ROOTS_ADDRESS;
    try db.set_account(beacon.bytes, .{
        .balance = 0,
        .nonce = 1,
        .code_hash = try db.set_code(&evm.beacon_roots.BEACON_ROOTS_CODE),
        .storage_root = zero_hash,
    });
    // A slot from an earlier block shares the ring buffer and must survive.
    try db.set_storage(beacon.bytes, 1000, 999);

    // A database whose storage writes fail once `writes_left` reaches zero.
    const FailingWrites = struct {
        inner: *evm.Database,
        writes_left: usize,

        pub fn get_account(self: *@This(), address: [20]u8) evm.Database.Error!?evm.Account {
            return self.inner.get_account(address);
        }
        pub fn set_storage(self: *@This(), address: [20]u8, key: u256, value: u256) evm.Database.Error!void {
            if (self.writes_left == 0) return error.OutOfMemory;
            self.writes_left -= 1;
            return self.inner.set_storage(address, key, value);
        }
        pub fn snapshot_depth(self: *const @This()) usize {
            return self.inner.snapshot_depth();
        }
        pub fn create_snapshot(self: *@This()) evm.Database.Error!u64 {
            return self.inner.create_snapshot();
        }
        pub fn revert_to_depth(self: *@This(), depth: usize) void {
            self.inner.revert_to_depth(depth);
        }
        pub fn commit_to_depth(self: *@This(), depth: usize) void {
            self.inner.commit_to_depth(depth);
        }
    };

    var block = evm.BlockInfo.init();
    block.timestamp = 1000;
    block.beacon_root = @as([32]u8, @splat(0xBE));
    const root_before = try db.get_state_root();

    var faulty = FailingWrites{ .inner = &db, .writes_left = 1 };
    try testing.expectError(
        error.OutOfMemory,
        evm.beacon_roots.BeaconRootsContract.processBeaconRootUpdate(&faulty, &block),
    );
    try testing.expectEqual(@as(usize, 0), faulty.writes_left);
    try testing.expectEqualSlices(u8, &root_before, &(try db.get_state_root()));
    try testing.expectEqual(@as(u256, 999), try db.get_storage(beacon.bytes, 1000));
    try testing.expectEqual(@as(u256, 0), try db.get_storage(beacon.bytes, 1000 + 8191));
    try testing.expectEqual(@as(usize, 0), db.snapshot_depth());

    faulty.writes_left = 2;
    try evm.beacon_roots.BeaconRootsContract.processBeaconRootUpdate(&faulty, &block);
    try testing.expectEqual(@as(u256, 1000), try db.get_storage(beacon.bytes, 1000));
}

test "W3-5: beginBlock is all-or-nothing at every allocation failure of the database" {
    const beacon = evm.beacon_roots.BEACON_ROOTS_ADDRESS;
    const history = evm.historical_block_hashes.HISTORY_CONTRACT_ADDRESS;
    var block = evm.BlockInfo.init();
    block.number = 5;
    block.timestamp = 1000;
    block.beacon_root = @as([32]u8, @splat(0xBE));
    block.parent_hash = @as([32]u8, @splat(0xAA));

    var failures: usize = 0;
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{});
        var db = evm.Database.init(failing.allocator());
        defer db.deinit();
        try db.set_account(beacon.bytes, .{
            .balance = 0,
            .nonce = 1,
            .code_hash = try db.set_code(&evm.beacon_roots.BEACON_ROOTS_CODE),
            .storage_root = zero_hash,
        });
        try db.set_account(history.bytes, .{
            .balance = 0,
            .nonce = 1,
            .code_hash = try db.set_code(&evm.historical_block_hashes.HISTORY_CODE),
            .storage_root = zero_hash,
        });
        var vm = try Vm.init(
            testing.allocator,
            &db,
            block,
            .{ .gas_limit = 16_000_000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 },
            0,
            primitives.ZERO_ADDRESS,
        );
        defer vm.deinit();
        const root_before = try db.get_state_root();

        failing.fail_index = failing.alloc_index + fail_index;
        const outcome = vm.beginBlock();
        failing.fail_index = std.math.maxInt(usize);
        try testing.expectEqual(@as(usize, 0), db.snapshot_depth());
        if (outcome) |_| {
            try testing.expectEqual(@as(u256, 1000), try db.get_storage(beacon.bytes, 1000));
            try testing.expect(try db.get_storage(beacon.bytes, 1000 + 8191) != 0);
            try testing.expect(try db.get_storage(history.bytes, 4) != 0);
            break;
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            try testing.expectEqualSlices(u8, &root_before, &(try db.get_state_root()));
            try testing.expectEqual(@as(u256, 0), try db.get_storage(beacon.bytes, 1000));
            try testing.expectEqual(@as(u256, 0), try db.get_storage(beacon.bytes, 1000 + 8191));
            try testing.expectEqual(@as(u256, 0), try db.get_storage(history.bytes, 4));
            failures += 1;
        }
    }
    try testing.expect(failures >= 2);
}

test "W3-6: a reverted CREATE or CREATE2 is not created in the transaction" {
    const allocator = testing.allocator;
    const origin = Address{ .bytes = @as([20]u8, @splat(0xA1)) };
    const factory = Address{ .bytes = @as([20]u8, @splat(0xFA)) };
    // Init code PUSH0 PUSH0 REVERT, stored at memory[29..32].
    const store_init = [_]u8{ 0x62, 0x5F, 0x5F, 0xFD, 0x5F, 0x52 };
    // CREATE(0, 29, 3); return the created address (zero on failure).
    const create_reverting = store_init ++ [_]u8{ 0x60, 0x03, 0x60, 0x1D, 0x5F, 0xF0 } ++
        [_]u8{ 0x5F, 0x52, 0x60, 0x20, 0x5F, 0xF3 };
    // CREATE2(0, 29, 3, salt 0); return the created address.
    const create2_reverting = store_init ++ [_]u8{ 0x5F, 0x60, 0x03, 0x60, 0x1D, 0x5F, 0xF5 } ++
        [_]u8{ 0x5F, 0x52, 0x60, 0x20, 0x5F, 0xF3 };

    for ([_][]const u8{ &create_reverting, &create2_reverting }) |code| {
        var db = evm.Database.init(allocator);
        defer db.deinit();
        try db.set_account(origin.bytes, .{
            .balance = 1_000_000,
            .nonce = 0,
            .code_hash = zero_hash,
            .storage_root = zero_hash,
        });
        try db.set_account(factory.bytes, .{
            .balance = 0,
            .nonce = 1,
            .code_hash = try db.set_code(code),
            .storage_root = zero_hash,
        });
        var vm = try Vm.init(
            allocator,
            &db,
            evm.BlockInfo.init(),
            .{ .gas_limit = 16_000_000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 },
            0,
            origin,
        );
        defer vm.deinit();

        // `call` clears the created set when its transaction ends, so the frame runs
        // through `inner_call`: the set is read as the rest of the transaction sees it.
        // The result lives in the call arena and is released with the EVM.
        const result = vm.inner_call(.{ .call = .{ .caller = origin, .to = factory, .value = 0, .input = &.{}, .gas = 1_000_000 } });
        try testing.expect(result.success);
        // The creation failed: the factory saw address zero.
        try testing.expectEqualSlices(u8, &zero_hash, result.output);
        try testing.expectEqual(@as(u32, 0), vm.created_contracts.count());

        const create_address = try Address.getContractAddress(allocator, factory, 1);
        var init_hash: [32]u8 = undefined;
        std.crypto.hash.sha3.Keccak256.hash(&[_]u8{ 0x5F, 0x5F, 0xFD }, &init_hash, .{});
        const create2_address = Address.getCreate2Address(factory, zero_hash, init_hash);
        try testing.expect(!vm.was_created_in_tx(create_address));
        try testing.expect(!vm.was_created_in_tx(create2_address));
    }
}

test "W3-6: a creation transaction whose init code reverts is not created in the transaction" {
    const allocator = testing.allocator;
    var db = evm.Database.init(allocator);
    defer db.deinit();
    const origin = Address{ .bytes = @as([20]u8, @splat(0xA1)) };
    try db.set_account(origin.bytes, .{ .balance = 1_000_000, .nonce = 0, .code_hash = zero_hash, .storage_root = zero_hash });
    var vm = try Vm.init(
        allocator,
        &db,
        evm.BlockInfo.init(),
        .{ .gas_limit = 16_000_000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 },
        0,
        origin,
    );
    defer vm.deinit();

    // Read inside the transaction (`call` clears the set at its end). The CREATE frame
    // of a creation transaction takes the same checkpoint as a nested one.
    const result = vm.inner_call(.{ .create = .{ .caller = origin, .value = 0, .init_code = &[_]u8{ 0x5F, 0x5F, 0xFD }, .gas = 1_000_000 } });
    try testing.expect(!result.success);
    try testing.expectEqual(@as(u32, 0), vm.created_contracts.count());
    try testing.expect(!vm.was_created_in_tx(try Address.getContractAddress(allocator, origin, 0)));
}

test "W3-6: a reverted parent call takes its child's successful creation back" {
    const allocator = testing.allocator;
    const origin = Address{ .bytes = @as([20]u8, @splat(0xA1)) };
    const factory = Address{ .bytes = @as([20]u8, @splat(0xFA)) };
    const parent = Address{ .bytes = @as([20]u8, @splat(0xBA)) };
    // CREATE(0, 0, 1) with init code STOP (memory byte 0), then POP.
    const create_ok = [_]u8{ 0x60, 0x01, 0x5F, 0x5F, 0xF0, 0x50 };
    const factory_reverts = create_ok ++ [_]u8{ 0x5F, 0x5F, 0xFD };
    const factory_stops = create_ok ++ [_]u8{0x00};
    // CALL(gas, factory, 0, 0, 0, 0, 0), POP, STOP: the parent ignores the outcome.
    const parent_code = [_]u8{ 0x5F, 0x5F, 0x5F, 0x5F, 0x5F, 0x73 } ++ factory.bytes ++ [_]u8{ 0x5A, 0xF1, 0x50, 0x00 };

    const cases = [_]struct { factory_code: []const u8, created: u32 }{
        .{ .factory_code = &factory_reverts, .created = 0 },
        .{ .factory_code = &factory_stops, .created = 1 },
    };
    for (cases) |case| {
        var db = evm.Database.init(allocator);
        defer db.deinit();
        try db.set_account(origin.bytes, .{
            .balance = 1_000_000,
            .nonce = 0,
            .code_hash = zero_hash,
            .storage_root = zero_hash,
        });
        try db.set_account(factory.bytes, .{
            .balance = 0,
            .nonce = 1,
            .code_hash = try db.set_code(case.factory_code),
            .storage_root = zero_hash,
        });
        try db.set_account(parent.bytes, .{
            .balance = 0,
            .nonce = 1,
            .code_hash = try db.set_code(&parent_code),
            .storage_root = zero_hash,
        });
        var vm = try Vm.init(
            allocator,
            &db,
            evm.BlockInfo.init(),
            .{ .gas_limit = 16_000_000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 },
            0,
            origin,
        );
        defer vm.deinit();

        // Read inside the transaction (`call` clears the set at its end).
        const result = vm.inner_call(.{ .call = .{ .caller = origin, .to = parent, .value = 0, .input = &.{}, .gas = 1_000_000 } });
        try testing.expect(result.success);

        const child = try Address.getContractAddress(allocator, factory, 1);
        try testing.expectEqual(case.created, vm.created_contracts.count());
        try testing.expectEqual(case.created == 1, vm.was_created_in_tx(child));
        try testing.expectEqual(case.created == 1, db.account_exists(child.bytes));
    }
}

test "W3-6: SELFDESTRUCT in a constructor still sees its contract as created in the transaction" {
    const allocator = testing.allocator;
    var db = evm.Database.init(allocator);
    defer db.deinit();

    const origin = Address{ .bytes = @as([20]u8, @splat(0xA1)) };
    const factory = Address{ .bytes = @as([20]u8, @splat(0xFA)) };
    const beneficiary = Address{ .bytes = @as([20]u8, @splat(0xBE)) };
    // Init code: PUSH20 beneficiary SELFDESTRUCT (22 bytes), stored at memory[10..32].
    const init_code = [_]u8{0x73} ++ beneficiary.bytes ++ [_]u8{0xFF};
    // CREATE(5, 10, 22), POP, STOP.
    const code = [_]u8{0x75} ++ init_code ++ [_]u8{ 0x5F, 0x52, 0x60, 0x16, 0x60, 0x0A, 0x60, 0x05, 0xF0, 0x50, 0x00 };
    try db.set_account(origin.bytes, .{ .balance = 1_000_000, .nonce = 0, .code_hash = zero_hash, .storage_root = zero_hash });
    try db.set_account(factory.bytes, .{
        .balance = 5,
        .nonce = 1,
        .code_hash = try db.set_code(&code),
        .storage_root = zero_hash,
    });

    // Cancun and later: EIP-6780 deletes an account only when it was created in the
    // same transaction, which is what the constructor must observe.
    var vm = try Vm.init(
        allocator,
        &db,
        evm.BlockInfo.init(),
        .{ .gas_limit = 16_000_000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 },
        0,
        origin,
    );
    defer vm.deinit();

    const child = try Address.getContractAddress(allocator, factory, 1);
    {
        // Inside the transaction: the constructor's own successful frame keeps the
        // mark, and SELFDESTRUCT moved the endowment because it saw it.
        const result = vm.inner_call(.{ .call = .{ .caller = origin, .to = factory, .value = 0, .input = &.{}, .gas = 1_000_000 } });
        try testing.expect(result.success);
        try testing.expect(vm.was_created_in_tx(child));
        try testing.expectEqual(@as(u32, 1), vm.created_contracts.count());
        try testing.expectEqual(@as(u256, 5), try db.get_balance(beneficiary.bytes));
        try testing.expectEqual(@as(u256, 0), try db.get_balance(factory.bytes));
    }

    // The same call as a whole transaction, on fresh state: the account is deleted
    // at the end, as EIP-6780 allows only for an account created in the transaction,
    // and the set is empty for the next transaction.
    var tx_db = evm.Database.init(allocator);
    defer tx_db.deinit();
    try tx_db.set_account(origin.bytes, .{ .balance = 1_000_000, .nonce = 0, .code_hash = zero_hash, .storage_root = zero_hash });
    try tx_db.set_account(factory.bytes, .{
        .balance = 5,
        .nonce = 1,
        .code_hash = try tx_db.set_code(&code),
        .storage_root = zero_hash,
    });
    var tx_vm = try Vm.init(
        allocator,
        &tx_db,
        evm.BlockInfo.init(),
        .{ .gas_limit = 16_000_000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 },
        0,
        origin,
    );
    defer tx_vm.deinit();
    var tx_result = tx_vm.call(.{ .call = .{ .caller = origin, .to = factory, .value = 0, .input = &.{}, .gas = 1_000_000 } });
    defer tx_result.deinit(allocator);
    try testing.expect(tx_result.success);
    try testing.expectEqual(@as(u256, 5), try tx_db.get_balance(beneficiary.bytes));
    try testing.expectEqual(@as(u256, 0), try tx_db.get_balance(factory.bytes));
    try testing.expect(!tx_db.account_exists(child.bytes));
    try testing.expectEqual(@as(u32, 0), tx_vm.created_contracts.count());
}

test "W3-9: a database error at the third authorization rolls back the first two and keeps the gas" {
    const allocator = testing.allocator;
    var db = evm.Database.init(allocator);
    defer db.deinit();

    const delegate = Address{ .bytes = [_]u8{0xDE} ++ @as([19]u8, @splat(0)) };
    var list: [3]evm.Authorization = undefined;
    var authorities: [3]Address = undefined;
    for (&list, &authorities, 0..) |*tuple, *authority, i| {
        const key: crypto.PrivateKey = @as([32]u8, @splat(@intCast(0x41 + i)));
        authority.* = (try crypto.unaudited_getPublicKey(key)).toAddress();
        tuple.* = try primitives.Authorization.createAuthorization(allocator, 1, delegate, 0, key);
        tuple.v -= 27; // the tuple carries y_parity
    }
    // The first authority already exists; its balance and nonce must come back.
    try db.set_account(authorities[0].bytes, .{ .balance = 7, .nonce = 0, .code_hash = zero_hash, .storage_root = zero_hash });
    const root_before = try db.get_state_root();

    // A database whose account writes fail once `writes_left` reaches zero.
    const FailingWrites = struct {
        inner: *evm.Database,
        writes_left: usize,
        writes: usize = 0,

        pub fn get_account(self: *@This(), address: [20]u8) evm.Database.Error!?evm.Account {
            return self.inner.get_account(address);
        }
        pub fn get_code(self: *@This(), code_hash: [32]u8) evm.Database.Error![]const u8 {
            return self.inner.get_code(code_hash);
        }
        pub fn set_account(self: *@This(), address: [20]u8, account: evm.Account) evm.Database.Error!void {
            if (self.writes_left == 0) return error.OutOfMemory;
            self.writes_left -= 1;
            self.writes += 1;
            return self.inner.set_account(address, account);
        }
        pub fn snapshot_depth(self: *const @This()) usize {
            return self.inner.snapshot_depth();
        }
        pub fn create_snapshot(self: *@This()) evm.Database.Error!u64 {
            return self.inner.create_snapshot();
        }
        pub fn revert_to_depth(self: *@This(), depth: usize) void {
            self.inner.revert_to_depth(depth);
        }
        pub fn commit_to_depth(self: *@This(), depth: usize) void {
            self.inner.commit_to_depth(depth);
        }
    };
    const Processor = evm.AuthorizationProcessorFor(FailingWrites);

    for ([_]bool{ true, false }) |with_results| {
        var faulty = FailingWrites{ .inner = &db, .writes_left = 2 };
        var gas_remaining: i64 = 1_000_000;
        var processor = Processor{
            .db = &faulty,
            .chain_id = 1,
            .gas_remaining = &gas_remaining,
            .eips = evm.Eips{ .hardfork = .PRAGUE },
        };
        if (with_results) {
            try testing.expectError(error.OutOfMemory, processor.processAuthorizationListWithResults(allocator, &list));
        } else {
            try testing.expectError(error.OutOfMemory, processor.processAuthorizationList(&list));
        }
        // Two delegations were written before the third failed.
        try testing.expectEqual(@as(usize, 2), faulty.writes);
        try testing.expectEqual(@as(i64, 1_000_000), gas_remaining);
        try testing.expectEqual(@as(usize, 0), db.snapshot_depth());
        try testing.expectEqualSlices(u8, &root_before, &(try db.get_state_root()));
        const first = (try db.get_account(authorities[0].bytes)).?;
        try testing.expectEqual(@as(u64, 0), first.nonce);
        try testing.expectEqual(@as(u256, 7), first.balance);
        try testing.expect(first.delegated_address == null);
        try testing.expect(!db.account_exists(authorities[1].bytes));
        try testing.expect(!db.account_exists(authorities[2].bytes));
    }

    // Without the fault the whole list applies and the gas is charged once.
    var healthy = FailingWrites{ .inner = &db, .writes_left = 3 };
    var gas_remaining: i64 = 1_000_000;
    var processor = Processor{
        .db = &healthy,
        .chain_id = 1,
        .gas_remaining = &gas_remaining,
        .eips = evm.Eips{ .hardfork = .PRAGUE },
    };
    var applied = try processor.processAuthorizationListWithResults(allocator, &list);
    defer applied.deinit(allocator);
    try testing.expectEqual(@as(u32, 3), applied.successful_count);
    try testing.expectEqual(@as(i64, 1_000_000 - 3 * 25_000), gas_remaining);
    for (authorities) |authority| {
        const account = (try db.get_account(authority.bytes)).?;
        try testing.expectEqual(@as(u64, 1), account.nonce);
        try testing.expectEqual(@as(?Address, delegate), account.delegated_address);
    }
    try testing.expectEqual(@as(usize, 0), db.snapshot_depth());
}

test "W3-9: an authorization list is all-or-nothing at every allocation failure of the database" {
    const delegate = Address{ .bytes = [_]u8{0xDE} ++ @as([19]u8, @splat(0)) };
    var list: [12]evm.Authorization = undefined;
    var authorities: [12]Address = undefined;
    for (&list, &authorities, 0..) |*tuple, *authority, i| {
        const key: crypto.PrivateKey = @as([32]u8, @splat(@intCast(0x21 + i)));
        authority.* = (try crypto.unaudited_getPublicKey(key)).toAddress();
        tuple.* = try primitives.Authorization.createAuthorization(testing.allocator, 1, delegate, 0, key);
        tuple.v -= 27; // the tuple carries y_parity
    }

    var failures: usize = 0;
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{});
        var db = evm.Database.init(failing.allocator());
        defer db.deinit();
        var gas_remaining: i64 = 1_000_000;
        var processor = evm.AuthorizationProcessor{
            .db = &db,
            .chain_id = 1,
            .gas_remaining = &gas_remaining,
            .eips = evm.Eips{ .hardfork = .PRAGUE },
        };

        failing.fail_index = failing.alloc_index + fail_index;
        const outcome = processor.processAuthorizationList(&list);
        failing.fail_index = std.math.maxInt(usize);
        try testing.expectEqual(@as(usize, 0), db.snapshot_depth());
        if (outcome) |refund| {
            try testing.expectEqual(@as(i64, 0), refund);
            try testing.expectEqual(@as(i64, 1_000_000 - 12 * 25_000), gas_remaining);
            for (authorities) |authority| try testing.expect(db.account_exists(authority.bytes));
            break;
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            try testing.expectEqual(@as(i64, 1_000_000), gas_remaining);
            for (authorities) |authority| try testing.expect(!db.account_exists(authority.bytes));
            failures += 1;
        }
    }
    // The snapshot, the undo log and the account table each grow at least once.
    try testing.expect(failures >= 3);
}
