//! Regression tests for the per-transaction and storage hot-path changes:
//!
//! - the call stack is no longer refilled after every transaction,
//! - the call arena keeps at most its configured capacity,
//! - SLOAD and SSTORE record state-dump touches once per transaction and hash a
//!   slot once,
//! - RETURN and REVERT hand their arena copy to the result, the return-data
//!   buffer is reused, and CALL reads its target account once,
//! - `simulate()` clears only the overlay tables a call wrote.
//!
//! Each test builds its own database and EVM and runs real bytecode through the
//! public `Evm.call` / `Evm.simulate` entry points.

const std = @import("std");
const evm = @import("evm");
const primitives = @import("voltaire");

const Vm = evm.Evm(.{});
const Address = primitives.Address;

test "call stack: a shallow call after a deep one sees its own caller and value" {
    const allocator = std.testing.allocator;
    var db = evm.Database.init(allocator);
    defer db.deinit();

    const origin = Address{ .bytes = @as([20]u8, @splat(0xA1)) };
    const recursive = Address{ .bytes = @as([20]u8, @splat(0xB1)) };

    // n = calldata word 0. n == 0: return (CALLER, CALLVALUE).
    // Otherwise call itself with n - 1 and no value, and return what that returned.
    const code = [_]u8{
        0x5F, 0x35, // PUSH0 CALLDATALOAD            [n]
        0x80, 0x15, // DUP1 ISZERO                   [n == 0, n]
        0x60, 0x20, 0x57, // PUSH1 0x20 JUMPI        [n]
        0x60, 0x01, 0x90, 0x03, // PUSH1 1 SWAP1 SUB [n - 1]
        0x5F, 0x52, // PUSH0 MSTORE                  mem[0] = n - 1
        0x60, 0x40, 0x5F, // retSize 64, retOffset 0
        0x60, 0x20, 0x5F, // argsSize 32, argsOffset 0
        0x5F, 0x30, 0x5A, 0xF1, // value 0, ADDRESS, GAS, CALL
        0x50, // POP
        0x60, 0x40, 0x5F, 0xF3, // RETURN(0, 64)
        0xFE, 0xFE, 0xFE, 0xFE, // padding up to pc 0x20
        0x5B, 0x50, // JUMPDEST POP
        0x33, 0x5F, 0x52, // CALLER PUSH0 MSTORE
        0x34, 0x60, 0x20, 0x52, // CALLVALUE PUSH1 0x20 MSTORE
        0x60, 0x40, 0x5F, 0xF3, // RETURN(0, 64)
    };
    try std.testing.expectEqual(@as(u8, 0x5B), code[0x20]);
    var account = evm.Account.zero();
    account.code_hash = try db.set_code(&code);
    try db.set_account(recursive.bytes, account);
    var sender = evm.Account.zero();
    sender.balance = 1_000_000;
    try db.set_account(origin.bytes, sender);

    var vm = try Vm.init(
        allocator,
        &db,
        evm.BlockInfo.init(),
        .{ .gas_limit = 16_000_000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 },
        0,
        origin,
    );
    defer vm.deinit();

    const depths = [_]u8{ 25, 0, 40, 1, 0, 60, 0 };
    for (depths, 0..) |depth, round| {
        var input = @as([32]u8, @splat(0));
        input[31] = depth;
        const value: u256 = 7 + round;
        var result = vm.call(.{ .call = .{
            .caller = origin,
            .to = recursive,
            .value = value,
            .input = &input,
            .gas = 10_000_000,
        } });
        defer result.deinit(allocator);

        try std.testing.expect(result.success);
        try std.testing.expectEqual(@as(usize, 64), result.output.len);
        const caller_word = std.mem.readInt(u256, result.output[0..32], .big);
        const value_word = std.mem.readInt(u256, result.output[32..64], .big);
        if (depth == 0) {
            // The entry frame is the leaf: called by the origin, with the value.
            try std.testing.expectEqual(std.mem.readInt(u160, &origin.bytes, .big), @as(u160, @truncate(caller_word)));
            try std.testing.expectEqual(value, value_word);
        } else {
            // The leaf was called by the contract itself, without value.
            try std.testing.expectEqual(std.mem.readInt(u160, &recursive.bytes, .big), @as(u160, @truncate(caller_word)));
            try std.testing.expectEqual(@as(u256, 0), value_word);
        }

        // Between transactions no frame is active: the getters answer for depth 0
        // whatever the slots above it still hold.
        try std.testing.expectEqual(@as(u11, 0), vm.depth);
        try std.testing.expect(vm.get_caller().equals(origin));
        try std.testing.expectEqual(@as(u256, 0), vm.get_call_value());
        try std.testing.expect(!vm.is_static_context());
    }
}

test "call stack: static context ends with the STATICCALL and never reaches a later frame" {
    const allocator = std.testing.allocator;
    var db = evm.Database.init(allocator);
    defer db.deinit();

    const origin = Address{ .bytes = @as([20]u8, @splat(0xA2)) };
    const outer = Address{ .bytes = @as([20]u8, @splat(0xB2)) };
    const writer = Address{ .bytes = @as([20]u8, @splat(0xC2)) };

    // writer: SSTORE(1, 1); STOP
    const writer_code = [_]u8{ 0x60, 0x01, 0x60, 0x01, 0x55, 0x00 };
    // outer: s1 = STATICCALL(writer); SSTORE(10, s1 + 1)
    //        s2 = CALL(writer);       SSTORE(11, s2 + 1)
    // The static call gets a fixed 50,000 gas: its SSTORE halts and burns all of it.
    const outer_code = [_]u8{ 0x5F, 0x5F, 0x5F, 0x5F, 0x73 } ++ writer.bytes ++ [_]u8{
        0x61, 0xC3, 0x50, 0xFA, // PUSH2 50000 STATICCALL
        0x60, 0x01, 0x01, 0x60, 0x0A, 0x55, // PUSH1 1 ADD PUSH1 10 SSTORE
        0x5F, 0x5F, 0x5F, 0x5F, 0x5F, 0x73,
    } ++ writer.bytes ++ [_]u8{
        0x5A, 0xF1, // GAS CALL
        0x60, 0x01, 0x01, 0x60, 0x0B, 0x55, // PUSH1 1 ADD PUSH1 11 SSTORE
        0x00,
    };
    var writer_account = evm.Account.zero();
    writer_account.code_hash = try db.set_code(&writer_code);
    try db.set_account(writer.bytes, writer_account);
    var outer_account = evm.Account.zero();
    outer_account.code_hash = try db.set_code(&outer_code);
    try db.set_account(outer.bytes, outer_account);

    var vm = try Vm.init(
        allocator,
        &db,
        evm.BlockInfo.init(),
        .{ .gas_limit = 16_000_000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 },
        0,
        origin,
    );
    defer vm.deinit();

    // Run it twice: the second transaction must not inherit the first one's
    // static frame at the same depth.
    for (0..2) |_| {
        var result = vm.call(.{ .call = .{ .caller = origin, .to = outer, .value = 0, .input = &.{}, .gas = 1_000_000 } });
        defer result.deinit(allocator);
        try std.testing.expect(result.success);
        // The static writer failed (s1 = 0), the plain one succeeded (s2 = 1).
        try std.testing.expectEqual(@as(u256, 1), try db.get_storage(outer.bytes, 10));
        try std.testing.expectEqual(@as(u256, 2), try db.get_storage(outer.bytes, 11));
        try std.testing.expectEqual(@as(u256, 1), try db.get_storage(writer.bytes, 1));
        try std.testing.expectEqual(@as(u11, 0), vm.depth);
        try std.testing.expect(!vm.is_static_context());
    }

    // A direct call to the writer right after: depth 1 held the static frame of
    // the first transaction's STATICCALL at depth 2, never at depth 1.
    var direct = vm.call(.{ .call = .{ .caller = origin, .to = writer, .value = 0, .input = &.{}, .gas = 1_000_000 } });
    defer direct.deinit(allocator);
    try std.testing.expect(direct.success);
}

test "call stack: a reverted nested call and a rejected transaction leave depth 0" {
    const allocator = std.testing.allocator;
    var db = evm.Database.init(allocator);
    defer db.deinit();

    const origin = Address{ .bytes = @as([20]u8, @splat(0xA3)) };
    const outer = Address{ .bytes = @as([20]u8, @splat(0xB3)) };
    const reverter = Address{ .bytes = @as([20]u8, @splat(0xC3)) };

    // reverter: SSTORE(1, 1); REVERT(0, 0)
    const reverter_code = [_]u8{ 0x60, 0x01, 0x60, 0x01, 0x55, 0x5F, 0x5F, 0xFD };
    // outer: return (CALL(reverter) success flag, CALLER after the call)
    const outer_code = [_]u8{ 0x5F, 0x5F, 0x5F, 0x5F, 0x5F, 0x73 } ++ reverter.bytes ++ [_]u8{
        0x5A, 0xF1, // GAS CALL
        0x5F, 0x52, // PUSH0 MSTORE
        0x33, 0x60, 0x20, 0x52, // CALLER PUSH1 0x20 MSTORE
        0x60, 0x40, 0x5F, 0xF3, // RETURN(0, 64)
    };
    var reverter_account = evm.Account.zero();
    reverter_account.code_hash = try db.set_code(&reverter_code);
    try db.set_account(reverter.bytes, reverter_account);
    var outer_account = evm.Account.zero();
    outer_account.code_hash = try db.set_code(&outer_code);
    try db.set_account(outer.bytes, outer_account);

    var vm = try Vm.init(
        allocator,
        &db,
        evm.BlockInfo.init(),
        .{ .gas_limit = 16_000_000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 },
        0,
        origin,
    );
    defer vm.deinit();

    var result = vm.call(.{ .call = .{ .caller = origin, .to = outer, .value = 0, .input = &.{}, .gas = 1_000_000 } });
    defer result.deinit(allocator);
    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(u256, 0), std.mem.readInt(u256, result.output[0..32], .big));
    // After the nested frame ended, CALLER is the outer frame's caller again.
    try std.testing.expectEqual(std.mem.readInt(u160, &origin.bytes, .big), @as(u160, @truncate(std.mem.readInt(u256, result.output[32..64], .big))));
    try std.testing.expectEqual(@as(u256, 0), try db.get_storage(reverter.bytes, 1));
    try std.testing.expectEqual(@as(u11, 0), vm.depth);

    // A transaction rejected before any frame runs.
    var rejected = vm.call(.{ .call = .{ .caller = origin, .to = outer, .value = 0, .input = &.{}, .gas = 0 } });
    defer rejected.deinit(allocator);
    try std.testing.expect(!rejected.success);
    try std.testing.expect(rejected.error_info != null);
    try std.testing.expectEqual(@as(u11, 0), vm.depth);
    try std.testing.expect(vm.get_caller().equals(origin));
    try std.testing.expect(!vm.is_static_context());

    // And the EVM still runs the next transaction correctly.
    var again = vm.call(.{ .call = .{ .caller = origin, .to = outer, .value = 0, .input = &.{}, .gas = 1_000_000 } });
    defer again.deinit(allocator);
    try std.testing.expect(again.success);
    try std.testing.expectEqualSlices(u8, result.output, again.output);
}

/// Backing allocator that counts the allocations at or above `threshold` bytes.
const LargeAllocationCounter = struct {
    child: std.mem.Allocator,
    threshold: usize,
    large_allocations: usize = 0,
    largest: usize = 0,

    fn allocator(self: *LargeAllocationCounter) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn note(self: *LargeAllocationCounter, len: usize) void {
        if (len < self.threshold) return;
        self.large_allocations += 1;
        self.largest = @max(self.largest, len);
    }

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
        const self: *LargeAllocationCounter = @ptrCast(@alignCast(context));
        self.note(len);
        return self.child.rawAlloc(len, alignment, return_address);
    }

    fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) bool {
        const self: *LargeAllocationCounter = @ptrCast(@alignCast(context));
        if (new_len > memory.len) self.note(new_len);
        return self.child.rawResize(memory, alignment, new_len, return_address);
    }

    fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) ?[*]u8 {
        const self: *LargeAllocationCounter = @ptrCast(@alignCast(context));
        if (new_len > memory.len) self.note(new_len);
        return self.child.rawRemap(memory, alignment, new_len, return_address);
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, return_address: usize) void {
        const self: *LargeAllocationCounter = @ptrCast(@alignCast(context));
        self.child.rawFree(memory, alignment, return_address);
    }
};

test "call arena: one oversized call, then ten small calls allocate no arena block" {
    const limit = 256 * 1024;
    const SmallArenaVm = evm.Evm(.{ .arena_capacity_limit = limit });

    var counter = LargeAllocationCounter{ .child = std.testing.allocator, .threshold = 48 * 1024 };
    const allocator = counter.allocator();
    var db = evm.Database.init(allocator);
    defer db.deinit();

    const origin = Address{ .bytes = @as([20]u8, @splat(0xA4)) };
    const big = Address{ .bytes = @as([20]u8, @splat(0xB4)) };
    const small = Address{ .bytes = @as([20]u8, @splat(0xC4)) };

    // big: RETURN(0, 0x100000). The megabyte of output is copied into the call arena.
    const big_code = [_]u8{ 0x62, 0x10, 0x00, 0x00, 0x5F, 0xF3 };
    // small: RETURN(0, 32)
    const small_code = [_]u8{ 0x60, 0x20, 0x5F, 0xF3 };
    var big_account = evm.Account.zero();
    big_account.code_hash = try db.set_code(&big_code);
    try db.set_account(big.bytes, big_account);
    var small_account = evm.Account.zero();
    small_account.code_hash = try db.set_code(&small_code);
    try db.set_account(small.bytes, small_account);

    var vm = try SmallArenaVm.init(
        allocator,
        &db,
        evm.BlockInfo.init(),
        .{ .gas_limit = 16_000_000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 },
        0,
        origin,
    );
    defer vm.deinit();

    var oversized = vm.call(.{ .call = .{ .caller = origin, .to = big, .value = 0, .input = &.{}, .gas = 10_000_000 } });
    try std.testing.expect(oversized.success);
    try std.testing.expectEqual(@as(usize, 0x100000), oversized.output.len);
    oversized.deinit(allocator);

    // The reset after that call cut the arena back to its limit.
    const retained = vm.call_arena.queryCapacity();
    try std.testing.expect(retained <= limit);
    try std.testing.expect(retained > 0);

    counter.large_allocations = 0;
    counter.largest = 0;
    for (0..10) |_| {
        var result = vm.call(.{ .call = .{ .caller = origin, .to = small, .value = 0, .input = &.{}, .gas = 1_000_000 } });
        defer result.deinit(allocator);
        try std.testing.expect(result.success);
        try std.testing.expectEqual(@as(usize, 32), result.output.len);
        // The capacity neither grows back past the limit nor changes at all.
        try std.testing.expectEqual(retained, vm.call_arena.queryCapacity());
    }
    // A small call needs no block anywhere near the arena's size. Before the fix
    // every one of them freed the arena and allocated 1.5 times the limit again.
    try std.testing.expectEqual(@as(usize, 0), counter.large_allocations);
}

test "state dump: slots are recorded in first-touch order, once, on every build path" {
    const allocator = std.testing.allocator;
    var db = evm.Database.init(allocator);
    defer db.deinit();

    const origin = Address{ .bytes = @as([20]u8, @splat(0xA5)) };
    const target = Address{ .bytes = @as([20]u8, @splat(0xB5)) };

    // SLOAD 3, 1, 2, 1, 3 (cold then warm); SSTORE(2, 9); SSTORE(4, 5); SSTORE(4, 0).
    const code = [_]u8{
        0x60, 0x03, 0x54, 0x50,
        0x60, 0x01, 0x54, 0x50,
        0x60, 0x02, 0x54, 0x50,
        0x60, 0x01, 0x54, 0x50,
        0x60, 0x03, 0x54, 0x50,
        0x60, 0x09, 0x60, 0x02,
        0x55, 0x60, 0x05, 0x60,
        0x04, 0x55, 0x5F, 0x60,
        0x04, 0x55, 0x00,
    };
    var account = evm.Account.zero();
    account.code_hash = try db.set_code(&code);
    account.balance = 1;
    try db.set_account(target.bytes, account);
    try db.set_storage(target.bytes, 1, 0x11);
    try db.set_storage(target.bytes, 3, 0x33);

    var vm = try Vm.init(
        allocator,
        &db,
        evm.BlockInfo.init(),
        .{ .gas_limit = 16_000_000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 },
        0,
        origin,
    );
    defer vm.deinit();

    var first = vm.call(.{ .call = .{ .caller = origin, .to = target, .value = 0, .input = &.{}, .gas = 1_000_000 } });
    defer first.deinit(allocator);
    try std.testing.expect(first.success);

    try std.testing.expect(vm.touched_addresses.contains(target));
    try std.testing.expectEqualSlices(u256, &.{ 3, 1, 2, 4 }, vm.touched_storage.get(target).?.keys());

    {
        var dump = try vm.dumpState(allocator);
        defer dump.deinit(allocator);
        var key: [42]u8 = undefined;
        key[0] = '0';
        key[1] = 'x';
        for (target.bytes, 0..) |byte, index| {
            key[2 + index * 2] = "0123456789abcdef"[byte >> 4];
            key[3 + index * 2] = "0123456789abcdef"[byte & 0x0F];
        }
        const dumped = dump.accounts.get(&key).?;
        try std.testing.expectEqual(@as(u256, 1), dumped.balance);
        // Slot 4 was written back to zero, so the dump holds 1, 2 and 3 only.
        try std.testing.expectEqual(@as(u32, 3), dumped.storage.count());
        try std.testing.expectEqual(@as(?u256, 0x11), dumped.storage.get(1));
        try std.testing.expectEqual(@as(?u256, 9), dumped.storage.get(2));
        try std.testing.expectEqual(@as(?u256, 0x33), dumped.storage.get(3));
    }

    // A second transaction touches the same slots: nothing is added twice.
    var second = vm.call(.{ .call = .{ .caller = origin, .to = target, .value = 0, .input = &.{}, .gas = 1_000_000 } });
    defer second.deinit(allocator);
    try std.testing.expect(second.success);
    try std.testing.expectEqualSlices(u256, &.{ 3, 1, 2, 4 }, vm.touched_storage.get(target).?.keys());

    // After a reset the next transaction records everything again.
    vm.resetTouched();
    try std.testing.expect(!vm.touched_addresses.contains(target));
    try std.testing.expectEqual(@as(u32, 0), vm.touched_storage.count());
    var third = vm.call(.{ .call = .{ .caller = origin, .to = target, .value = 0, .input = &.{}, .gas = 1_000_000 } });
    defer third.deinit(allocator);
    try std.testing.expect(third.success);
    try std.testing.expect(vm.touched_addresses.contains(target));
    try std.testing.expectEqualSlices(u256, &.{ 3, 1, 2, 4 }, vm.touched_storage.get(target).?.keys());
}

test "state dump: a slot warmed by the transaction's access list is recorded when it is read" {
    const allocator = std.testing.allocator;
    var db = evm.Database.init(allocator);
    defer db.deinit();

    const origin = Address{ .bytes = @as([20]u8, @splat(0xA6)) };
    const target = Address{ .bytes = @as([20]u8, @splat(0xB6)) };

    // SLOAD(7); POP; STOP. Slot 8 is warmed too but never read.
    const code = [_]u8{ 0x60, 0x07, 0x54, 0x50, 0x00 };
    var account = evm.Account.zero();
    account.code_hash = try db.set_code(&code);
    try db.set_account(target.bytes, account);
    try db.set_storage(target.bytes, 7, 0x77);
    try db.set_storage(target.bytes, 8, 0x88);

    const warmed = [_]evm.AccessListEntry{.{ .address = target, .storage_keys = &.{ 7, 8 } }};
    var vm = try Vm.init(
        allocator,
        &db,
        evm.BlockInfo.init(),
        .{ .gas_limit = 16_000_000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1, .access_list = &warmed },
        0,
        origin,
    );
    defer vm.deinit();

    var result = vm.call(.{ .call = .{ .caller = origin, .to = target, .value = 0, .input = &.{}, .gas = 1_000_000 } });
    defer result.deinit(allocator);
    try std.testing.expect(result.success);
    // The SLOAD was warm, yet it is the first touch: the dump must know slot 7.
    // Slot 8 was only declared, never accessed, and stays out as before.
    try std.testing.expectEqualSlices(u256, &.{7}, vm.touched_storage.get(target).?.keys());
}

test "state dump: tracking can be compiled out without changing execution" {
    const allocator = std.testing.allocator;
    const QuietVm = evm.Evm(.{ .track_state_dump = false });

    const origin = Address{ .bytes = @as([20]u8, @splat(0xA7)) };
    const target = Address{ .bytes = @as([20]u8, @splat(0xB7)) };
    // v = SLOAD(1); SSTORE(1, v + 1); SSTORE(2, v); return SLOAD(1)
    const code = [_]u8{
        0x60, 0x01, 0x54, // [v]
        0x80, 0x60, 0x01, 0x01, 0x60, 0x01, 0x55, // SSTORE(1, v + 1)
        0x60, 0x02, 0x55, // SSTORE(2, v)
        0x60, 0x01, 0x54,
        0x5F, 0x52, 0x60,
        0x20, 0x5F, 0xF3,
    };

    var tracked_db = evm.Database.init(allocator);
    defer tracked_db.deinit();
    var quiet_db = evm.Database.init(allocator);
    defer quiet_db.deinit();
    for ([_]*evm.Database{ &tracked_db, &quiet_db }) |db| {
        var account = evm.Account.zero();
        account.code_hash = try db.set_code(&code);
        try db.set_account(target.bytes, account);
        try db.set_storage(target.bytes, 1, 41);
    }

    var tracked = try Vm.init(allocator, &tracked_db, evm.BlockInfo.init(), .{ .gas_limit = 16_000_000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 }, 0, origin);
    defer tracked.deinit();
    var quiet = try QuietVm.init(allocator, &quiet_db, evm.BlockInfo.init(), .{ .gas_limit = 16_000_000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 }, 0, origin);
    defer quiet.deinit();

    for (0..3) |_| {
        var a = tracked.call(.{ .call = .{ .caller = origin, .to = target, .value = 0, .input = &.{}, .gas = 1_000_000 } });
        defer a.deinit(allocator);
        var b = quiet.call(.{ .call = .{ .caller = origin, .to = target, .value = 0, .input = &.{}, .gas = 1_000_000 } });
        defer b.deinit(allocator);
        try std.testing.expect(a.success and b.success);
        try std.testing.expectEqual(a.gas_left, b.gas_left);
        try std.testing.expectEqualSlices(u8, a.output, b.output);
    }
    try std.testing.expectEqual(@as(u256, 44), try quiet_db.get_storage(target.bytes, 1));
    try std.testing.expectEqual(@as(u32, 0), quiet.touched_addresses.count());
    try std.testing.expectEqual(@as(u32, 0), quiet.touched_storage.count());
    try std.testing.expectError(error.StateDumpDisabled, quiet.dumpState(allocator));
    var dump = try tracked.dumpState(allocator);
    defer dump.deinit(allocator);
    try std.testing.expect(dump.accounts.count() >= 1);
}

test "storage: warm and cold SLOAD and SSTORE cost the same through hashed lookups" {
    const allocator = std.testing.allocator;
    var db = evm.Database.init(allocator);
    defer db.deinit();

    const origin = Address{ .bytes = @as([20]u8, @splat(0xA8)) };
    const target = Address{ .bytes = @as([20]u8, @splat(0xB8)) };

    // SLOAD(k) twice for a key given in calldata, then SSTORE(k, 1) twice.
    const code = [_]u8{
        0x5F, 0x35, 0x54, 0x50, // SLOAD(k)   cold
        0x5F, 0x35, 0x54, 0x50, // SLOAD(k)   warm
        0x60, 0x01, 0x5F, 0x35, 0x55, // SSTORE(k, 1)   0 -> 1
        0x60, 0x01, 0x5F, 0x35, 0x55, // SSTORE(k, 1)   no-op
        0x00,
    };
    var account = evm.Account.zero();
    account.code_hash = try db.set_code(&code);
    try db.set_account(target.bytes, account);

    var vm = try Vm.init(
        allocator,
        &db,
        evm.BlockInfo.init(),
        .{ .gas_limit = 16_000_000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 },
        0,
        origin,
    );
    defer vm.deinit();

    // Keys in every limb of the 256-bit slot number. Each has exactly one non-zero
    // byte, so every transaction pays the same intrinsic gas for its calldata.
    const keys = [_]u256{ 1, 2, 0x80, 1 << 64, 1 << 128, 1 << 192, 1 << 248, 0xFF << 56, 3 << 200, 0x80 << 248 };
    var expected_gas_left: ?u64 = null;
    for (keys) |key| {
        var input: [32]u8 = undefined;
        std.mem.writeInt(u256, &input, key, .big);
        try std.testing.expectEqual(@as(usize, 31), std.mem.count(u8, &input, &.{0}));
        var result = vm.call(.{ .call = .{ .caller = origin, .to = target, .value = 0, .input = &input, .gas = 1_000_000 } });
        defer result.deinit(allocator);
        try std.testing.expect(result.success);
        try std.testing.expectEqual(@as(u256, 1), try db.get_storage(target.bytes, key));
        // Every key is cold once and takes the same path, so the gas is identical.
        if (expected_gas_left) |expected| {
            try std.testing.expectEqual(expected, result.gas_left);
        } else {
            expected_gas_left = result.gas_left;
        }
    }
    try std.testing.expectEqual(@as(usize, keys.len), db.storage.nonZeroCount(target.bytes));
}

test "storage: SELFDESTRUCT of a contract created in the transaction zeroes every slot once" {
    const allocator = std.testing.allocator;
    var db = evm.Database.init(allocator);
    defer db.deinit();

    const address = @as([20]u8, @splat(0xD9));
    const neighbour = @as([20]u8, @splat(0xDA));
    try db.set_account(address, evm.Account.zero());
    try db.set_account(neighbour, evm.Account.zero());

    var slot: u256 = 0;
    while (slot < 500) : (slot += 1) {
        // Every third slot holds zero: it is a key of the account but not counted.
        try db.set_storage(address, slot, if (slot % 3 == 0) 0 else slot);
        try db.set_storage(neighbour, slot, slot + 1);
    }
    const non_zero_before = db.storage.nonZeroCount(address);
    try std.testing.expectEqual(@as(usize, 333), non_zero_before);
    try std.testing.expect(try db.has_storage(address));

    const snapshot = try db.create_snapshot();
    try db.delete_account(address);
    try std.testing.expectEqual(@as(usize, 0), db.storage.nonZeroCount(address));
    try std.testing.expect(!try db.has_storage(address));
    try std.testing.expect(!db.account_exists(address));
    slot = 0;
    while (slot < 500) : (slot += 1) try std.testing.expectEqual(@as(u256, 0), try db.get_storage(address, slot));
    // One undo entry per non-zero slot plus the account: zero slots are skipped.
    try std.testing.expectEqual(non_zero_before + 1, db.undo_log.items.len);
    // The neighbour is untouched.
    try std.testing.expectEqual(@as(usize, 500), db.storage.nonZeroCount(neighbour));

    try db.revert_to_snapshot(snapshot);
    try std.testing.expectEqual(non_zero_before, db.storage.nonZeroCount(address));
    try std.testing.expect(db.account_exists(address));
    slot = 0;
    while (slot < 500) : (slot += 1) {
        try std.testing.expectEqual(if (slot % 3 == 0) @as(u256, 0) else slot, try db.get_storage(address, slot));
    }
    try std.testing.expectEqual(@as(usize, 500), db.storage.keysOf(address).len);
}

test "storage: an overlay shadows base slots and its counts never reach the base" {
    const allocator = std.testing.allocator;
    var db = evm.Database.init(allocator);
    defer db.deinit();

    const address = @as([20]u8, @splat(0xDB));
    try db.set_account(address, evm.Account.zero());
    try db.set_storage(address, 1, 10);
    try db.set_storage(address, 2, 20);

    try db.begin_ephemeral_view();
    try db.set_storage(address, 1, 0); // hides a base slot
    try db.set_storage(address, 3, 30); // adds a slot
    try std.testing.expectEqual(@as(u256, 0), try db.get_storage(address, 1));
    try std.testing.expectEqual(@as(u256, 20), try db.get_storage(address, 2));
    try std.testing.expectEqual(@as(u256, 30), try db.get_storage(address, 3));
    try std.testing.expect(try db.has_storage(address));
    try std.testing.expectEqual(@as(usize, 2), db.storage.nonZeroCount(address));
    try std.testing.expectEqual(@as(usize, 1), db.overlay_storage.nonZeroCount(address));

    // Clearing in the view hides slot 2 as well and leaves nothing visible.
    try db.clear_account_storage(address);
    try std.testing.expect(!try db.has_storage(address));
    try std.testing.expectEqual(@as(usize, 0), db.overlay_storage.nonZeroCount(address));
    db.discard_ephemeral_view();

    try std.testing.expectEqual(@as(u256, 10), try db.get_storage(address, 1));
    try std.testing.expectEqual(@as(u256, 20), try db.get_storage(address, 2));
    try std.testing.expectEqual(@as(u256, 0), try db.get_storage(address, 3));
    try std.testing.expectEqual(@as(usize, 2), db.storage.nonZeroCount(address));
    try std.testing.expect(db.overlayIsClean());
}

test "storage: an allocation failure inside delete_account rolls back under a snapshot" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const allocator = failing.allocator();
    var db = evm.Database.init(allocator);
    defer db.deinit();

    const address = @as([20]u8, @splat(0xDC));
    var account = evm.Account.zero();
    account.nonce = 3;
    try db.set_account(address, account);
    var slot: u256 = 1;
    while (slot <= 64) : (slot += 1) try db.set_storage(address, slot, slot * 7);

    var attempts: usize = 0;
    var failed_at_least_once = false;
    while (attempts < 64) : (attempts += 1) {
        const snapshot = try db.create_snapshot();
        failing.fail_index = failing.alloc_index + attempts;
        const outcome = db.delete_account(address);
        failing.fail_index = std.math.maxInt(usize);
        if (outcome) |_| {
            // Enough allocations succeeded for the whole deletion. Undo it and stop.
            try db.revert_to_snapshot(snapshot);
            break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            failed_at_least_once = true;
            try db.revert_to_snapshot(snapshot);
        }
        // Whatever was zeroed before the failure is back, counts included.
        try std.testing.expectEqual(@as(usize, 64), db.storage.nonZeroCount(address));
        try std.testing.expectEqual(@as(u64, 3), try db.get_nonce(address));
        slot = 1;
        while (slot <= 64) : (slot += 1) try std.testing.expectEqual(slot * 7, try db.get_storage(address, slot));
    }
    try std.testing.expect(failed_at_least_once);
    try std.testing.expectEqual(@as(usize, 64), db.storage.nonZeroCount(address));
    slot = 1;
    while (slot <= 64) : (slot += 1) try std.testing.expectEqual(slot * 7, try db.get_storage(address, slot));
}

test "return data: nested RETURN and REVERT payloads of every size arrive intact" {
    const allocator = std.testing.allocator;
    var db = evm.Database.init(allocator);
    defer db.deinit();

    const origin = Address{ .bytes = @as([20]u8, @splat(0xAA)) };
    const relay = Address{ .bytes = @as([20]u8, @splat(0xBA)) };
    const echo = Address{ .bytes = @as([20]u8, @splat(0xCA)) };
    const refuse = Address{ .bytes = @as([20]u8, @splat(0xDA)) };

    // echo:   CALLDATACOPY(0, 0, size); RETURN(0, size)
    const echo_code = [_]u8{ 0x36, 0x5F, 0x5F, 0x37, 0x36, 0x5F, 0xF3 };
    // refuse: CALLDATACOPY(0, 0, size); REVERT(0, size)
    const refuse_code = [_]u8{ 0x36, 0x5F, 0x5F, 0x37, 0x36, 0x5F, 0xFD };
    // relay: target = calldata word 0; forwards calldata[32..] to it and returns
    // (success, RETURNDATASIZE, return data).
    const relay_code = [_]u8{
        0x60, 0x20, 0x36, 0x03, // PUSH1 32 CALLDATASIZE SUB            [n]
        0x80, 0x60, 0x20, 0x5F, 0x37, // DUP1 PUSH1 32 PUSH0 CALLDATACOPY   mem[0..n] = calldata[32..]
        0x5F, 0x5F, // retSize 0, retOffset 0                            [0 0 n]
        0x82, 0x5F, // DUP3 (argsSize n), argsOffset 0                   [0 n 0 0 n]
        0x5F, 0x5F, 0x35, 0x5A, 0xF1, // value 0, target, GAS, CALL      [ok n]
        0x5F, 0x52, // MSTORE(0, ok)                                     [n]
        0x50, // POP
        0x3D, 0x60, 0x20, 0x52, // MSTORE(32, RETURNDATASIZE)
        0x3D, 0x5F, 0x60, 0x40, 0x3E, // RETURNDATACOPY(64, 0, RETURNDATASIZE)
        0x3D, 0x60, 0x40, 0x01, 0x5F, 0xF3, // RETURN(0, 64 + RETURNDATASIZE)
    };
    for ([_]struct { address: Address, code: []const u8 }{
        .{ .address = echo, .code = &echo_code },
        .{ .address = refuse, .code = &refuse_code },
        .{ .address = relay, .code = &relay_code },
    }) |contract| {
        var account = evm.Account.zero();
        account.code_hash = try db.set_code(contract.code);
        try db.set_account(contract.address.bytes, account);
    }

    var vm = try Vm.init(
        allocator,
        &db,
        evm.BlockInfo.init(),
        .{ .gas_limit = 16_000_000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 },
        0,
        origin,
    );
    defer vm.deinit();

    // Large and small payloads alternate so that a buffer kept from a larger call
    // is reused by a smaller one, and 70,000 bytes passes the retained limit.
    const sizes = [_]usize{ 1, 70_000, 3, 5_000, 0, 33, 65_536, 32, 64 * 1024 + 1, 2 };
    const payload = try allocator.alloc(u8, 32 + 70_000);
    defer allocator.free(payload);
    for (sizes, 0..) |size, round| {
        for ([_]Address{ echo, refuse }) |target| {
            @memset(payload[0..32], 0);
            @memcpy(payload[12..32], &target.bytes);
            for (payload[32..][0..size], 0..) |*byte, index| byte.* = @truncate(index * 31 + round * 7 + 1);

            var result = vm.call(.{ .call = .{ .caller = origin, .to = relay, .value = 0, .input = payload[0 .. 32 + size], .gas = 10_000_000 } });
            defer result.deinit(allocator);
            try std.testing.expect(result.success);
            try std.testing.expectEqual(64 + size, result.output.len);
            const inner_success = std.mem.readInt(u256, result.output[0..32], .big);
            try std.testing.expectEqual(@as(u256, @intFromBool(target.equals(echo))), inner_success);
            try std.testing.expectEqual(@as(u256, size), std.mem.readInt(u256, result.output[32..64], .big));
            try std.testing.expectEqualSlices(u8, payload[32..][0..size], result.output[64..]);
        }
    }
    // The buffer that carried the last payloads is kept, bounded.
    try std.testing.expect(vm.return_buffer.len <= Vm.max_retained_return_data);
}

test "return data: RETURNDATACOPY past the end halts and a successful CREATE clears the buffer" {
    const allocator = std.testing.allocator;
    var db = evm.Database.init(allocator);
    defer db.deinit();

    const origin = Address{ .bytes = @as([20]u8, @splat(0xAB)) };
    const reader = Address{ .bytes = @as([20]u8, @splat(0xBB)) };
    const creator = Address{ .bytes = @as([20]u8, @splat(0xCB)) };
    const four = Address{ .bytes = @as([20]u8, @splat(0xDB)) };

    // four: RETURN(0, 4)
    const four_code = [_]u8{ 0x60, 0x04, 0x5F, 0xF3 };
    // reader: CALL(four); RETURNDATACOPY(0, 0, calldata word 0); RETURN(0, 32)
    const reader_code = [_]u8{ 0x5F, 0x5F, 0x5F, 0x5F, 0x5F, 0x73 } ++ four.bytes ++ [_]u8{
        0x5A, 0xF1, 0x50, // GAS CALL POP
        0x5F, 0x35, 0x5F, 0x5F, 0x3E, // RETURNDATACOPY(0, 0, calldata word 0)
        0x60, 0x20, 0x5F, 0xF3,
    };
    // creator: CALL(four) leaves 4 bytes of return data; CREATE runs init code that
    // returns one byte of runtime code; then return (RETURNDATASIZE, created != 0).
    const creator_code = [_]u8{ 0x5F, 0x5F, 0x5F, 0x5F, 0x5F, 0x73 } ++ four.bytes ++ [_]u8{
        0x5A, 0xF1, 0x50, // GAS CALL POP
        0x63, 0x60, 0x01, 0x5F, 0xF3, // PUSH4 init code: PUSH1 1 PUSH0 RETURN
        0x5F, 0x52, // MSTORE(0, ...): the four bytes sit at mem[28..32]
        0x60, 0x04, 0x60, 0x1C, 0x5F, 0xF0, // CREATE(0, 28, 4)
        0x15, 0x15, 0x60, 0x20, 0x52, // MSTORE(32, created != 0)
        0x3D, 0x5F, 0x52, // MSTORE(0, RETURNDATASIZE)
        0x60, 0x40, 0x5F,
        0xF3,
    };
    for ([_]struct { address: Address, code: []const u8 }{
        .{ .address = four, .code = &four_code },
        .{ .address = reader, .code = &reader_code },
        .{ .address = creator, .code = &creator_code },
    }) |contract| {
        var account = evm.Account.zero();
        account.code_hash = try db.set_code(contract.code);
        account.nonce = 1;
        try db.set_account(contract.address.bytes, account);
    }

    var vm = try Vm.init(
        allocator,
        &db,
        evm.BlockInfo.init(),
        .{ .gas_limit = 16_000_000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 },
        0,
        origin,
    );
    defer vm.deinit();

    // Copying exactly the four bytes works; one byte more is an exceptional halt.
    inline for (.{ .{ 4, true }, .{ 5, false }, .{ 0, true }, .{ 1 << 20, false } }) |case| {
        var input = @as([32]u8, @splat(0));
        std.mem.writeInt(u256, &input, case[0], .big);
        var result = vm.call(.{ .call = .{ .caller = origin, .to = reader, .value = 0, .input = &input, .gas = 1_000_000 } });
        defer result.deinit(allocator);
        try std.testing.expectEqual(case[1], result.success);
        if (!case[1]) try std.testing.expectEqual(@as(u64, 0), result.gas_left);
    }

    var created = vm.call(.{ .call = .{ .caller = origin, .to = creator, .value = 0, .input = &.{}, .gas = 1_000_000 } });
    defer created.deinit(allocator);
    try std.testing.expect(created.success);
    // EIP-211: a successful CREATE leaves the return data buffer empty.
    try std.testing.expectEqual(@as(u256, 0), std.mem.readInt(u256, created.output[0..32], .big));
    try std.testing.expectEqual(@as(u256, 1), std.mem.readInt(u256, created.output[32..64], .big));
}

test "return data: a result the host owns survives later transactions" {
    const allocator = std.testing.allocator;
    var db = evm.Database.init(allocator);
    defer db.deinit();

    const origin = Address{ .bytes = @as([20]u8, @splat(0xAC)) };
    const echo = Address{ .bytes = @as([20]u8, @splat(0xBC)) };
    const echo_code = [_]u8{ 0x36, 0x5F, 0x5F, 0x37, 0x36, 0x5F, 0xF3 };
    var account = evm.Account.zero();
    account.code_hash = try db.set_code(&echo_code);
    try db.set_account(echo.bytes, account);

    var vm = try Vm.init(
        allocator,
        &db,
        evm.BlockInfo.init(),
        .{ .gas_limit = 16_000_000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 },
        0,
        origin,
    );
    defer vm.deinit();

    const first_input = "the first transaction's output must outlive the arena";
    var first = vm.call(.{ .call = .{ .caller = origin, .to = echo, .value = 0, .input = first_input, .gas = 1_000_000 } });
    defer first.deinit(allocator);
    try std.testing.expect(first.success);

    // Later transactions reset the arena and reuse the return-data buffer.
    for (0..8) |round| {
        var filler: [200]u8 = undefined;
        @memset(&filler, @as(u8, @truncate(0xE0 + round)));
        var later = vm.call(.{ .call = .{ .caller = origin, .to = echo, .value = 0, .input = filler[0 .. 20 + round * 20], .gas = 1_000_000 } });
        defer later.deinit(allocator);
        try std.testing.expect(later.success);
        try std.testing.expectEqualSlices(u8, filler[0 .. 20 + round * 20], later.output);
        // The first result is the host's own copy.
        try std.testing.expectEqualSlices(u8, first_input, first.output);
    }
    var simulated = vm.simulate(.{ .call = .{ .caller = origin, .to = echo, .value = 0, .input = "simulated", .gas = 1_000_000 } });
    defer simulated.deinit(allocator);
    try std.testing.expectEqualSlices(u8, "simulated", simulated.output);
    try std.testing.expectEqualSlices(u8, first_input, first.output);
}

test "call preflight: a delegated account runs its delegate, a plain account its own code" {
    const allocator = std.testing.allocator;
    var db = evm.Database.init(allocator);
    defer db.deinit();

    const origin = Address{ .bytes = @as([20]u8, @splat(0xAD)) };
    const plain = Address{ .bytes = @as([20]u8, @splat(0xBD)) };
    const delegated = Address{ .bytes = @as([20]u8, @splat(0xCD)) };
    const empty = Address{ .bytes = @as([20]u8, @splat(0xDD)) };
    const missing = Address{ .bytes = @as([20]u8, @splat(0xED)) };
    const caller_contract = Address{ .bytes = @as([20]u8, @splat(0xFD)) };

    // plain: return ADDRESS
    const plain_code = [_]u8{ 0x30, 0x5F, 0x52, 0x60, 0x20, 0x5F, 0xF3 };
    var plain_account = evm.Account.zero();
    plain_account.code_hash = try db.set_code(&plain_code);
    try db.set_account(plain.bytes, plain_account);
    // delegated: an EOA whose code is `plain`'s (EIP-7702).
    try db.set_account(delegated.bytes, evm.Account.zero());
    try db.set_delegation(delegated.bytes, plain.bytes);
    try db.set_account(empty.bytes, evm.Account.zero());

    // caller_contract: target = calldata word 0; CALL(target) with 32 bytes of
    // return space; return (success, RETURNDATASIZE, word returned).
    const caller_code = [_]u8{
        0x60, 0x20, 0x60, 0x40, // retSize 32, retOffset 64
        0x5F, 0x5F, 0x5F, // argsSize, argsOffset, value
        0x5F, 0x35, 0x5A, 0xF1, // target, GAS, CALL
        0x5F, 0x52, // MSTORE(0, success)
        0x3D, 0x60, 0x20, 0x52, // MSTORE(32, RETURNDATASIZE)
        0x60, 0x60, 0x5F, 0xF3, // RETURN(0, 96)
    };
    var caller_account = evm.Account.zero();
    caller_account.code_hash = try db.set_code(&caller_code);
    try db.set_account(caller_contract.bytes, caller_account);

    var vm = try Vm.init(
        allocator,
        &db,
        evm.BlockInfo.init(),
        .{ .gas_limit = 16_000_000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 },
        0,
        origin,
    );
    defer vm.deinit();

    const cases = [_]struct { target: Address, returned: ?Address }{
        .{ .target = plain, .returned = plain },
        // The delegate's code runs in the delegated account's own context.
        .{ .target = delegated, .returned = delegated },
        .{ .target = empty, .returned = null },
        .{ .target = missing, .returned = null },
        .{ .target = plain, .returned = plain },
    };
    for (cases) |case| {
        var input = @as([32]u8, @splat(0));
        @memcpy(input[12..32], &case.target.bytes);
        var result = vm.call(.{ .call = .{ .caller = origin, .to = caller_contract, .value = 0, .input = &input, .gas = 1_000_000 } });
        defer result.deinit(allocator);
        try std.testing.expect(result.success);
        try std.testing.expectEqual(@as(u256, 1), std.mem.readInt(u256, result.output[0..32], .big));
        const returned_size = std.mem.readInt(u256, result.output[32..64], .big);
        if (case.returned) |expected| {
            try std.testing.expectEqual(@as(u256, 32), returned_size);
            try std.testing.expectEqualSlices(u8, &expected.bytes, result.output[64 + 12 .. 96]);
        } else {
            // An account without code: the call succeeds and returns nothing.
            try std.testing.expectEqual(@as(u256, 0), returned_size);
        }
    }
}

test "simulate: large and empty simulations alternate under a live outer snapshot" {
    const allocator = std.testing.allocator;
    var db = evm.Database.init(allocator);
    defer db.deinit();

    const origin = Address{ .bytes = @as([20]u8, @splat(0xAE)) };
    const writer = Address{ .bytes = @as([20]u8, @splat(0xBE)) };
    const reader = Address{ .bytes = @as([20]u8, @splat(0xCE)) };
    const idle = Address{ .bytes = @as([20]u8, @splat(0xDE)) };

    // writer: for i in 200..1: SSTORE(i, i + 0x100); TSTORE(i, i). Then return SLOAD(1).
    const writer_code = [_]u8{
        0x60, 0xC8, // PUSH1 200                       [i]
        0x5B, // JUMPDEST (pc 2)
        0x80, 0x61, 0x01, 0x00, 0x01, // DUP1 PUSH2 0x100 ADD  [i + 0x100, i]
        0x81, 0x55, // DUP2 SSTORE                     [i]
        0x80, 0x80, 0x5D, // DUP1 DUP1 TSTORE          [i]
        0x60, 0x01, 0x90, 0x03, // PUSH1 1 SWAP1 SUB   [i - 1]
        0x80, 0x60, 0x02, 0x57, // DUP1 PUSH1 2 JUMPI
        0x50, 0x60, 0x01, 0x54,
        0x5F, 0x52, 0x60, 0x20,
        0x5F, 0xF3,
    };
    // reader: return (SLOAD(1), TLOAD(1))
    const reader_code = [_]u8{ 0x60, 0x01, 0x54, 0x5F, 0x52, 0x60, 0x01, 0x5C, 0x60, 0x20, 0x52, 0x60, 0x40, 0x5F, 0xF3 };
    const idle_code = [_]u8{0x00};
    for ([_]struct { address: Address, code: []const u8 }{
        .{ .address = writer, .code = &writer_code },
        .{ .address = reader, .code = &reader_code },
        .{ .address = idle, .code = &idle_code },
    }) |contract| {
        var account = evm.Account.zero();
        account.code_hash = try db.set_code(contract.code);
        try db.set_account(contract.address.bytes, account);
    }
    try db.set_storage(writer.bytes, 1, 0xAAAA);
    // The reader shares no storage with the writer; give it a base value of its own.
    try db.set_storage(reader.bytes, 1, 0xBBBB);

    var vm = try Vm.init(
        allocator,
        &db,
        evm.BlockInfo.init(),
        .{ .gas_limit = 16_000_000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 },
        0,
        origin,
    );
    defer vm.deinit();

    // A host snapshot stays open across every simulation, with a base write under it.
    const outer = try db.create_snapshot();
    try db.set_storage(writer.bytes, 2, 0xCCCC);
    var undo_under_snapshot = db.undo_log.items.len;

    for (0..6) |round| {
        var large = vm.simulate(.{ .call = .{ .caller = origin, .to = writer, .value = 0, .input = &.{}, .gas = 10_000_000 } });
        defer large.deinit(allocator);
        try std.testing.expect(large.success);
        // Inside the simulation the writer saw its own write to slot 1.
        try std.testing.expectEqual(@as(u256, 0x101), std.mem.readInt(u256, large.output[0..32], .big));

        // Nothing of it remains: not in the base, not in the overlay, not as undo entries.
        try std.testing.expect(db.overlayIsClean());
        try std.testing.expectEqual(@as(usize, 0), db.overlay_storage.count());
        try std.testing.expectEqual(@as(u32, 0), db.overlay_transient.count());
        try std.testing.expectEqual(@as(u256, 0xAAAA), try db.get_storage(writer.bytes, 1));
        try std.testing.expectEqual(@as(u256, 0xCCCC), try db.get_storage(writer.bytes, 2));
        try std.testing.expectEqual(@as(u256, 0), try db.get_storage(writer.bytes, 3));
        try std.testing.expectEqual(@as(u256, 0), try db.get_transient_storage(writer.bytes, 1));
        try std.testing.expectEqual(@as(usize, 1), db.snapshot_depth());
        for (db.undo_log.items[undo_under_snapshot..]) |entry| try std.testing.expect(entry == .noop);

        // Simulations that write nothing find a clean overlay and leave it clean.
        for (0..3) |_| {
            var empty = vm.simulate(.{ .call = .{ .caller = origin, .to = idle, .value = 0, .input = &.{}, .gas = 1_000_000 } });
            defer empty.deinit(allocator);
            try std.testing.expect(empty.success);
            try std.testing.expect(db.overlayIsClean());
        }

        // A read-only simulation must see base values, never the discarded overlay.
        var read = vm.simulate(.{ .call = .{ .caller = origin, .to = reader, .value = 0, .input = &.{}, .gas = 1_000_000 } });
        defer read.deinit(allocator);
        try std.testing.expect(read.success);
        try std.testing.expectEqual(@as(u256, 0xBBBB), std.mem.readInt(u256, read.output[0..32], .big));
        try std.testing.expectEqual(@as(u256, 0), std.mem.readInt(u256, read.output[32..64], .big));

        // A committed call between simulations lands in the base under the snapshot.
        if (round == 2) {
            var committed = vm.call(.{ .call = .{ .caller = origin, .to = writer, .value = 0, .input = &.{}, .gas = 10_000_000 } });
            defer committed.deinit(allocator);
            try std.testing.expect(committed.success);
            try std.testing.expectEqual(@as(u256, 0x101), try db.get_storage(writer.bytes, 1));
            // Put the test's expectations back for the remaining rounds.
            try db.set_storage(writer.bytes, 1, 0xAAAA);
            try db.set_storage(writer.bytes, 2, 0xCCCC);
            var slot: u256 = 3;
            while (slot <= 200) : (slot += 1) try db.set_storage(writer.bytes, slot, 0);
            // Those base writes are recorded for the outer snapshot; later rounds
            // check the entries after them.
            undo_under_snapshot = db.undo_log.items.len;
        }
    }

    // The outer snapshot still reverts everything written under it.
    try db.revert_to_snapshot(outer);
    try std.testing.expectEqual(@as(u256, 0xAAAA), try db.get_storage(writer.bytes, 1));
    try std.testing.expectEqual(@as(u256, 0), try db.get_storage(writer.bytes, 2));
    try std.testing.expectEqual(@as(usize, 1), db.storage.nonZeroCount(writer.bytes));
    try std.testing.expectEqual(@as(usize, 0), db.snapshot_depth());
}

test "access list: precompiles stay warm between transactions and nothing else does" {
    const allocator = std.testing.allocator;
    var db = evm.Database.init(allocator);
    defer db.deinit();

    const origin = Address{ .bytes = @as([20]u8, @splat(0xAF)) };
    const target = Address{ .bytes = @as([20]u8, @splat(0xBF)) };
    const stranger = Address{ .bytes = @as([20]u8, @splat(0xCF)) };

    // BALANCE(0x01), a precompile: warm from the start of every transaction.
    // BALANCE(0xBEEF), an ordinary address: cold in every transaction.
    const code = [_]u8{ 0x60, 0x01, 0x31, 0x50, 0x61, 0xBE, 0xEF, 0x31, 0x50, 0x00 };
    var account = evm.Account.zero();
    account.code_hash = try db.set_code(&code);
    try db.set_account(target.bytes, account);

    var vm = try Vm.init(
        allocator,
        &db,
        evm.BlockInfo.init(),
        .{ .gas_limit = 16_000_000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 },
        0,
        origin,
    );
    defer vm.deinit();

    var first_gas_left: ?u64 = null;
    var first_accessed: usize = 0;
    for (0..8) |round| {
        // A host may empty the list, or warm an address of its own, between calls.
        if (round == 3) vm.access_list.clear();
        if (round == 5) try vm.access_list.pre_warm_addresses(&.{stranger});

        var result = if (round % 2 == 0)
            vm.call(.{ .call = .{ .caller = origin, .to = target, .value = 0, .input = &.{}, .gas = 1_000_000 } })
        else
            vm.simulate(.{ .call = .{ .caller = origin, .to = target, .value = 0, .input = &.{}, .gas = 1_000_000 } });
        defer result.deinit(allocator);
        try std.testing.expect(result.success);

        // The same gas every time: 100 for the precompile, 2600 for 0xBEEF. A
        // precompile that lost its warmth would cost 2500 more; an address that
        // stayed warm would cost 2500 less.
        if (first_gas_left) |expected| {
            try std.testing.expectEqual(expected, result.gas_left);
        } else {
            first_gas_left = result.gas_left;
            first_accessed = result.accessed_addresses.len;
        }

        var saw_precompile = false;
        var saw_beef = false;
        for (result.accessed_addresses) |address| {
            saw_precompile = saw_precompile or address.equals(Address.fromU256(0x01));
            saw_beef = saw_beef or address.equals(Address.fromU256(0xBEEF));
        }
        try std.testing.expect(saw_precompile);
        try std.testing.expect(saw_beef);
        try std.testing.expectEqual(first_accessed + @intFromBool(round == 5), result.accessed_addresses.len);

        // Between transactions only the precompiles are left, all unmarked, and no
        // storage slot is.
        const kept = vm.access_list.addresses.keys();
        try std.testing.expect(kept.len > 0);
        for (kept) |address| try std.testing.expect(evm.precompiles.isPrecompile(address, .OSAKA));
        for (vm.access_list.addresses.values()) |recorded| try std.testing.expect(!recorded);
        try std.testing.expectEqual(@as(usize, 0), vm.access_list.storage_slots.count());
        try std.testing.expect(!vm.access_list.is_address_warm(Address.fromU256(0xBEEF)));
        try std.testing.expect(!vm.access_list.is_address_warm(origin));
    }
}
