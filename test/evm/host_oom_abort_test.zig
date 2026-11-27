//! A host allocation failure inside a nested call must abort the transaction.
//!
//! The callee below warms and writes a storage slot (SSTORE), copies with
//! CALLDATACOPY, CODECOPY, EXTCODECOPY, MCOPY and RETURNDATACOPY, emits a log and
//! ends with a 128 KiB RETURN or REVERT. The caller ignores the callee's result
//! and writes storage afterwards. If an out-of-memory in the callee were an
//! ordinary failed call, the caller would carry on and commit a state that no
//! other client computes. The tests fail every allocation of the transaction in
//! turn and accept exactly two outcomes: the complete, correct post-state, or a
//! host failure with the pre-state untouched (nonce, balances, storage, logs).

const std = @import("std");
const testing = std.testing;
const evm = @import("evm");
const primitives = @import("voltaire");
const Address = primitives.Address;

/// Fails allocation number `fail_at` (0-based, counted from `arm`). When `sticky`,
/// every later allocation fails too, like a host that stays out of memory.
const InjectingAllocator = struct {
    parent: std.mem.Allocator,
    fail_at: usize = std.math.maxInt(usize),
    sticky: bool = false,
    count: usize = 0,
    induced: bool = false,

    fn arm(self: *InjectingAllocator, fail_at: usize, sticky: bool) void {
        self.fail_at = fail_at;
        self.sticky = sticky;
        self.count = 0;
        self.induced = false;
    }

    fn disarm(self: *InjectingAllocator) void {
        self.fail_at = std.math.maxInt(usize);
    }

    fn allocator(self: *InjectingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = std.mem.Allocator.VTable{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
        const self: *InjectingAllocator = @ptrCast(@alignCast(context));
        const index = self.count;
        self.count += 1;
        if (index == self.fail_at or (self.sticky and index > self.fail_at)) {
            self.induced = true;
            return null;
        }
        return self.parent.rawAlloc(len, alignment, return_address);
    }

    fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) bool {
        const self: *InjectingAllocator = @ptrCast(@alignCast(context));
        return self.parent.rawResize(memory, alignment, new_len, return_address);
    }

    fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) ?[*]u8 {
        const self: *InjectingAllocator = @ptrCast(@alignCast(context));
        return self.parent.rawRemap(memory, alignment, new_len, return_address);
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, return_address: usize) void {
        const self: *InjectingAllocator = @ptrCast(@alignCast(context));
        self.parent.rawFree(memory, alignment, return_address);
    }
};

const sender = Address{ .bytes = [_]u8{0x51} ++ @as([19]u8, @splat(0)) };
const coinbase = Address{ .bytes = [_]u8{0xC0} ++ @as([19]u8, @splat(0)) };
const outer = Address{ .bytes = [_]u8{0xA1} ++ @as([19]u8, @splat(0)) };
const inner = Address{ .bytes = [_]u8{0xB2} ++ @as([19]u8, @splat(0)) };
const zero_hash = @as([32]u8, @splat(0));
const sender_balance: u256 = 1_000_000_000;
const gas_limit: u64 = 6_000_000;

// Callee, up to its final opcode.
const inner_body =
    // SSTORE(7, 0xBB): warms slot 7, journals and writes it.
    [_]u8{ 0x60, 0xBB, 0x60, 0x07, 0x55 } ++
    // CALLDATACOPY(0, 0, 0x8000): grows memory to 32 KiB.
    [_]u8{ 0x61, 0x80, 0x00, 0x60, 0x00, 0x60, 0x00, 0x37 } ++
    // CODECOPY(0x100, 0, 0x20).
    [_]u8{ 0x60, 0x20, 0x60, 0x00, 0x61, 0x01, 0x00, 0x39 } ++
    // EXTCODECOPY(outer, 0, 0, 0x20).
    [_]u8{ 0x60, 0x20, 0x60, 0x00, 0x60, 0x00, 0x73 } ++ outer.bytes ++ [_]u8{0x3c} ++
    // MCOPY(0x9000, 0, 0x4000).
    [_]u8{ 0x61, 0x40, 0x00, 0x60, 0x00, 0x61, 0x90, 0x00, 0x5e } ++
    // LOG1(0, 0x40, topic 1).
    [_]u8{ 0x60, 0x01, 0x60, 0x40, 0x60, 0x00, 0xa1 } ++
    // STATICCALL(0xffff, identity 0x04, in 0..0x40, no out), POP.
    [_]u8{ 0x60, 0x00, 0x60, 0x00, 0x60, 0x40, 0x60, 0x00, 0x60, 0x04, 0x61, 0xff, 0xff, 0xfa, 0x50 } ++
    // RETURNDATACOPY(0x200, 0, 0x40).
    [_]u8{ 0x60, 0x40, 0x60, 0x00, 0x61, 0x02, 0x00, 0x3e } ++
    // PUSH3 0x020000 (128 KiB), PUSH1 0: the operands of the final RETURN or REVERT.
    [_]u8{ 0x62, 0x02, 0x00, 0x00, 0x60, 0x00 };

// Caller: SSTORE(5, 1); CALL(0x400000, inner, 0, in 0..0, out 0..0x20); POP;
// SSTORE(6, 2); STOP. The call's result is ignored.
const outer_code =
    [_]u8{ 0x60, 0x01, 0x60, 0x05, 0x55 } ++
    [_]u8{ 0x60, 0x20, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x73 } ++ inner.bytes ++ [_]u8{ 0x62, 0x40, 0x00, 0x00, 0xf1, 0x50 } ++
    [_]u8{ 0x60, 0x02, 0x60, 0x06, 0x55, 0x00 };

test "host OOM in a nested call aborts the transaction: RETURN and REVERT callee, every allocation, transient and lasting" {
    const Cancun = evm.Evm(.{ .eips = .{ .hardfork = .CANCUN } });
    const block = evm.BlockInfo{ .chain_id = 1, .number = 1, .timestamp = 1, .difficulty = 0, .gas_limit = 30_000_000, .coinbase = coinbase, .base_fee = 0, .prev_randao = zero_hash };

    // 0xf3 RETURN, 0xfd REVERT.
    for ([_]u8{ 0xf3, 0xfd }) |final_opcode| {
        const inner_code = inner_body ++ [_]u8{final_opcode};
        const callee_commits = final_opcode == 0xf3;
        for ([_]bool{ false, true }) |sticky| {
            var aborted: usize = 0;
            var completed_despite_failure: usize = 0;
            var fail_at: usize = 0;
            while (true) : (fail_at += 1) {
                try testing.expect(fail_at < 20_000);

                var db = evm.Database.init(testing.allocator);
                defer db.deinit();
                try db.set_account(sender.bytes, .{ .balance = sender_balance, .nonce = 0, .code_hash = zero_hash, .storage_root = zero_hash });
                try db.set_account(outer.bytes, .{ .balance = 0, .nonce = 1, .code_hash = try db.set_code(&outer_code), .storage_root = zero_hash });
                try db.set_account(inner.bytes, .{ .balance = 0, .nonce = 1, .code_hash = try db.set_code(&inner_code), .storage_root = zero_hash });
                const root_before = try db.get_state_root();

                var injecting = InjectingAllocator{ .parent = testing.allocator };
                var vm = try Cancun.init(injecting.allocator(), &db, block, .{ .gas_limit = gas_limit, .coinbase = coinbase, .chain_id = 1 }, 1, sender);
                defer vm.deinit();

                injecting.arm(fail_at, sticky);
                var result = vm.call(.{ .call = .{ .caller = sender, .to = outer, .value = 0, .input = &.{}, .gas = gas_limit } });
                injecting.disarm();
                defer result.deinit(injecting.allocator());

                const nonce = try db.get_nonce(sender.bytes);
                if (vm.host_failure != null) {
                    // Aborted: not a transaction outcome, and nothing of it remains.
                    aborted += 1;
                    try testing.expect(injecting.induced);
                    try testing.expect(!result.success);
                    try testing.expectEqual(@as(u64, 0), result.gas_left);
                    try testing.expectEqual(@as(usize, 0), result.logs.len);
                    if (result.error_info) |info| try testing.expect(std.mem.startsWith(u8, info, "host failure"));
                    // A transient failure leaves the memory to say what happened.
                    if (!sticky) try testing.expect(result.error_info != null);
                    try testing.expectEqual(@as(u64, 0), nonce);
                    try testing.expectEqual(sender_balance, try db.get_balance(sender.bytes));
                    try testing.expectEqual(@as(u256, 0), try db.get_storage(outer.bytes, 5));
                    try testing.expectEqual(@as(u256, 0), try db.get_storage(outer.bytes, 6));
                    try testing.expectEqual(@as(u256, 0), try db.get_storage(inner.bytes, 7));
                    try testing.expect(!db.account_exists(coinbase.bytes));
                    try testing.expectEqualSlices(u8, &root_before, &(try db.get_state_root()));
                    continue;
                }

                // Not aborted: the transaction ran to its one correct outcome. In
                // particular the caller never kept going past a callee that the
                // host, not the EVM, had stopped.
                try testing.expect(result.success);
                try testing.expectEqual(@as(?[]const u8, null), result.error_info);
                try testing.expectEqual(@as(u64, 1), nonce);
                try testing.expectEqual(@as(u256, 1), try db.get_storage(outer.bytes, 5));
                try testing.expectEqual(@as(u256, 2), try db.get_storage(outer.bytes, 6));
                try testing.expectEqual(@as(u256, if (callee_commits) 0xBB else 0), try db.get_storage(inner.bytes, 7));
                try testing.expectEqual(@as(usize, if (callee_commits) 1 else 0), result.logs.len);
                const gas_used = gas_limit - result.gas_left;
                try testing.expectEqual(sender_balance - gas_used, try db.get_balance(sender.bytes));
                try testing.expectEqual(@as(u256, gas_used), try db.get_balance(coinbase.bytes));

                if (!injecting.induced) break;
                // An allocation failed and the EVM recovered without it (a cache it
                // could do without). The outcome above is still the correct one.
                completed_despite_failure += 1;
            }
            // The sweep reached allocations made deep inside the callee.
            try testing.expect(aborted >= 10);
            // Recoveries are the exception, never the rule.
            try testing.expect(completed_despite_failure < aborted);
        }
    }
}

test "host OOM while SSTORE warms a slot is recorded as a host failure, not as a failed call" {
    // The callee only writes storage; the caller writes after it. Every
    // allocation of the transaction is failed in turn.
    const London = evm.Evm(.{ .eips = .{ .hardfork = .LONDON } });
    const block = evm.BlockInfo{ .chain_id = 1, .number = 1, .timestamp = 1, .difficulty = 1, .gas_limit = 30_000_000, .coinbase = coinbase, .base_fee = 0, .prev_randao = zero_hash };
    // Sixteen SSTOREs to fresh slots: the access list and the journal must grow.
    var inner_code: [16 * 5 + 1]u8 = undefined;
    for (0..16) |i| {
        inner_code[i * 5] = 0x60;
        inner_code[i * 5 + 1] = 0x01;
        inner_code[i * 5 + 2] = 0x60;
        inner_code[i * 5 + 3] = @intCast(0x10 + i);
        inner_code[i * 5 + 4] = 0x55;
    }
    inner_code[80] = 0x00;

    var aborted: usize = 0;
    var fail_at: usize = 0;
    while (true) : (fail_at += 1) {
        try testing.expect(fail_at < 20_000);
        var db = evm.Database.init(testing.allocator);
        defer db.deinit();
        try db.set_account(sender.bytes, .{ .balance = sender_balance, .nonce = 0, .code_hash = zero_hash, .storage_root = zero_hash });
        try db.set_account(outer.bytes, .{ .balance = 0, .nonce = 1, .code_hash = try db.set_code(&outer_code), .storage_root = zero_hash });
        try db.set_account(inner.bytes, .{ .balance = 0, .nonce = 1, .code_hash = try db.set_code(&inner_code), .storage_root = zero_hash });
        const root_before = try db.get_state_root();

        var injecting = InjectingAllocator{ .parent = testing.allocator };
        var vm = try London.init(injecting.allocator(), &db, block, .{ .gas_limit = gas_limit, .coinbase = coinbase, .chain_id = 1 }, 0, sender);
        defer vm.deinit();
        injecting.arm(fail_at, false);
        var result = vm.call(.{ .call = .{ .caller = sender, .to = outer, .value = 0, .input = &.{}, .gas = gas_limit } });
        injecting.disarm();
        defer result.deinit(injecting.allocator());

        if (vm.host_failure) |failure| {
            aborted += 1;
            // The host ran out of memory; nothing else can have failed here.
            try testing.expect(failure == error.OutOfMemory or failure == error.AllocationError);
            try testing.expect(!result.success);
            try testing.expectEqualSlices(u8, &root_before, &(try db.get_state_root()));
            continue;
        }
        try testing.expect(result.success);
        try testing.expectEqual(@as(u256, 2), try db.get_storage(outer.bytes, 6));
        // All sixteen callee slots or none: here all, because the call succeeded.
        for (0..16) |i| try testing.expectEqual(@as(u256, 1), try db.get_storage(inner.bytes, 0x10 + i));
        if (!injecting.induced) break;
    }
    try testing.expect(aborted >= 5);
}
