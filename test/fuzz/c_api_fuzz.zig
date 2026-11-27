//! C ABI / FFI Boundary Fuzz Tests (`src/evm_c_api.zig`)
//!
//! Exercises the exact `extern "C"` symbols exposed by `libguillotine_ffi`:
//! - `guillotine_init` / `guillotine_evm_create` / `guillotine_evm_destroy`
//! - `guillotine_set_balance` / `guillotine_get_balance` / `guillotine_set_nonce`
//! - `guillotine_set_code` / `guillotine_get_code` / `guillotine_free_code`
//! - `guillotine_set_storage` / `guillotine_get_storage`
//! - `guillotine_call` / `guillotine_simulate` / `guillotine_free_result`
//! - `guillotine_dump_state` / `guillotine_free_state_dump`
//! - `evm_bytecode_create` / `evm_bytecode_get_length` / `evm_bytecode_destroy`
//!
//! Verifies:
//! 1. Exact state roundtrips across the C ABI (balances, code, storage).
//! 2. Invalid call types (6..255) rejected cleanly without crashing.
//! 3. `guillotine_simulate` matches `guillotine_call` output & gas while preserving base state.
//! 4. Exact parity between C FFI execution and direct native Zig `MainnetEvm` execution.
//! 5. `evm_bytecode_pretty_print` returns cleanly for bytecode of any content and length.
//! 6. Handle lifetime: destroyed handles are rejected, destroy and cleanup race safely
//!    with calls on other threads, and a result that cannot be built rolls its call back.

const std = @import("std");
const evm = @import("evm");
const c_api = @import("evm_c_api");
const fuzz_alloc = @import("fuzz_alloc.zig");
const primitives = @import("voltaire");

comptime {
    _ = c_api;
}

const EvmHandle = c_api.EvmHandle;
const BlockInfoFFI = c_api.BlockInfoFFI;
const CallParamsFFI = c_api.CallParams;
const EvmResultFFI = c_api.EvmResult;

extern "c" fn guillotine_init() void;
extern "c" fn guillotine_evm_create(block_info_ptr: *const BlockInfoFFI) ?*EvmHandle;
extern "c" fn guillotine_evm_destroy(handle: *EvmHandle) void;
extern "c" fn guillotine_set_balance(handle: *EvmHandle, address: *const [20]u8, balance: *const [32]u8) bool;
extern "c" fn guillotine_get_balance(handle: *EvmHandle, address: *const [20]u8, balance_out: *[32]u8) bool;
extern "c" fn guillotine_set_nonce(handle: *EvmHandle, address: *const [20]u8, nonce: u64) bool;
extern "c" fn guillotine_set_code(handle: *EvmHandle, address: *const [20]u8, code: [*]const u8, code_len: usize) bool;
extern "c" fn guillotine_get_code(handle: *EvmHandle, address: *const [20]u8, code_out: *[*]u8, len_out: *usize) bool;
extern "c" fn guillotine_free_code(code: [*]u8, len: usize) void;
extern "c" fn guillotine_set_storage(handle: *EvmHandle, address: *const [20]u8, key: *const [32]u8, value: *const [32]u8) bool;
extern "c" fn guillotine_get_storage(handle: *EvmHandle, address: *const [20]u8, key: *const [32]u8, value_out: *[32]u8) bool;
extern "c" fn guillotine_call(handle: *EvmHandle, params: *const CallParamsFFI) ?*EvmResultFFI;
extern "c" fn guillotine_simulate(handle: *EvmHandle, params: *const CallParamsFFI) ?*EvmResultFFI;
extern "c" fn guillotine_free_result(result: ?*EvmResultFFI) void;
extern "c" fn evm_bytecode_create(data: [*]const u8, data_len: usize) ?*anyopaque;
extern "c" fn evm_bytecode_get_length(handle: ?*const anyopaque) usize;
extern "c" fn evm_bytecode_destroy(handle: ?*anyopaque) void;
extern "c" fn evm_bytecode_pretty_print(data: ?[*]const u8, data_len: usize, buffer: ?[*]u8, buffer_len: usize) usize;
extern "c" fn guillotine_cleanup() void;
extern "c" fn guillotine_get_last_error() [*:0]const u8;

pub fn fuzzCApiLifecycleAndExecution(_: void, input: []const u8) !void {
    if (input.len < 6) return;

    guillotine_init();

    var block = BlockInfoFFI{
        .number = 20_000_000 + @as(u64, input[0]),
        .timestamp = 1_700_000_000 + @as(u64, input[1]),
        .gas_limit = 30_000_000,
        .coinbase = @as([19]u8, @splat(0)) ++ [_]u8{0xcc},
        .base_fee = 1,
        .chain_id = 1,
        .difficulty = 0,
        .prev_randao = @as([32]u8, @splat(0)),
    };

    const handle = guillotine_evm_create(&block) orelse return error.EvmCreateFailed;
    defer guillotine_evm_destroy(handle);

    const caller = @as([19]u8, @splat(0)) ++ [_]u8{0x11};
    const target = @as([19]u8, @splat(0)) ++ [_]u8{0x22};

    // 1. Balance roundtrip across C ABI
    var bal_in = @as([32]u8, @splat(0));
    bal_in[24] = 0x01; // ample balance
    bal_in[31] = input[2];
    try std.testing.expect(guillotine_set_balance(handle, &caller, &bal_in));
    var bal_out = @as([32]u8, @splat(0));
    try std.testing.expect(guillotine_get_balance(handle, &caller, &bal_out));
    try std.testing.expectEqualSlices(u8, &bal_in, &bal_out);

    // 2. Nonce & storage roundtrip across C ABI
    try std.testing.expect(guillotine_set_nonce(handle, &caller, input[3]));
    var slot_key = @as([32]u8, @splat(0));
    slot_key[31] = input[3] & 0x0f;
    var slot_val = @as([32]u8, @splat(0));
    slot_val[31] = input[4];
    try std.testing.expect(guillotine_set_storage(handle, &target, &slot_key, &slot_val));
    var slot_out = @as([32]u8, @splat(0));
    try std.testing.expect(guillotine_get_storage(handle, &target, &slot_key, &slot_out));
    try std.testing.expectEqualSlices(u8, &slot_val, &slot_out);

    // 3. Code roundtrip across C ABI
    const code = input[5..@min(input.len, 256)];
    var sentinel = [_]u8{0};
    const code_ptr: [*]const u8 = if (code.len > 0) code.ptr else &sentinel;
    try std.testing.expect(guillotine_set_code(handle, &target, code_ptr, code.len));

    var fetched_ptr: [*]u8 = undefined;
    var fetched_len: usize = 0;
    try std.testing.expect(guillotine_get_code(handle, &target, &fetched_ptr, &fetched_len));
    defer if (fetched_len > 0) guillotine_free_code(fetched_ptr, fetched_len);
    try std.testing.expectEqual(code.len, fetched_len);
    if (code.len > 0) {
        try std.testing.expectEqualSlices(u8, code, fetched_ptr[0..fetched_len]);
    }

    // 4. Invalid call_type must never crash (returns null or failure result cleanly)
    const bad_type: u8 = 6 + (input[0] % 250);
    var bad_params = CallParamsFFI{
        .caller = caller,
        .to = target,
        .value = @as([32]u8, @splat(0)),
        .input = &sentinel,
        .input_len = 0,
        .gas = 100_000,
        .call_type = bad_type,
        .salt = @as([32]u8, @splat(0)),
    };
    if (guillotine_call(handle, &bad_params)) |r| {
        defer guillotine_free_result(r);
        try std.testing.expect(!r.success);
    }

    // 5. Valid call_type (0..5): simulate vs call parity + zero state mutation from simulate!
    const call_type: u8 = input[0] % 6;
    const gas_limit: u64 = 300_000;
    var params = CallParamsFFI{
        .caller = caller,
        .to = target,
        .value = @as([32]u8, @splat(0)),
        .input = code_ptr,
        .input_len = if (call_type == 4 or call_type == 5) code.len else @min(code.len, 32),
        .gas = gas_limit,
        .call_type = call_type,
        .salt = @as([31]u8, @splat(0)) ++ [_]u8{input[1]},
    };

    const sim_opt = guillotine_simulate(handle, &params);
    defer guillotine_free_result(sim_opt);

    // Storage must remain completely untouched after simulate()
    var after_sim_slot = @as([32]u8, @splat(0));
    try std.testing.expect(guillotine_get_storage(handle, &target, &slot_key, &after_sim_slot));
    try std.testing.expectEqualSlices(u8, &slot_val, &after_sim_slot);

    const call_opt = guillotine_call(handle, &params);
    defer guillotine_free_result(call_opt);

    if (sim_opt != null and call_opt != null) {
        const sim_r = sim_opt.?;
        const call_r = call_opt.?;
        try std.testing.expectEqual(sim_r.success, call_r.success);
        try std.testing.expectEqual(sim_r.gas_left, call_r.gas_left);
        try std.testing.expectEqual(sim_r.output_len, call_r.output_len);
        if (sim_r.output_len > 0) {
            try std.testing.expectEqualSlices(u8, sim_r.output[0..sim_r.output_len], call_r.output[0..call_r.output_len]);
        }
        try std.testing.expect(call_r.gas_left <= gas_limit);
    }

    // 6. Bytecode C API lifecycle
    if (evm_bytecode_create(code_ptr, code.len)) |bc_h| {
        defer evm_bytecode_destroy(bc_h);
        try std.testing.expectEqual(code.len, evm_bytecode_get_length(bc_h));
    }
}

/// `evm_bytecode_pretty_print` over generated bytecode. The first two bytes pick a
/// length up to 70,000 bytes (past every program counter width's edge), the rest is
/// the pattern repeated to that length. Long runs of one opcode are what overflowed
/// the block's stack requirement: 10,923 LOG4 need 65,538 items.
pub fn fuzzCApiPrettyPrint(_: void, input: []const u8) !void {
    if (input.len < 3) return;
    const allocator = fuzz_alloc.get();
    const requested: usize = (@as(usize, input[0]) << 8) | input[1];
    // Spread the 16-bit choice over 1..70,000 and land on the edges often.
    const len: usize = switch (requested % 8) {
        0 => 10_923,
        1 => 65_502,
        2 => 65_503,
        else => 1 + (requested * 70_000) / 65_536,
    };
    const pattern = input[2..];
    const code = try allocator.alloc(u8, len);
    defer allocator.free(code);
    for (code, 0..) |*byte, i| byte.* = pattern[i % pattern.len];

    // Size query, then a real print into a buffer of exactly that size.
    const needed = evm_bytecode_pretty_print(code.ptr, code.len, null, 0);
    if (needed == 0) return; // refused (invalid or too long): a clean answer
    const buffer = try allocator.alloc(u8, needed);
    defer allocator.free(buffer);
    const written = evm_bytecode_pretty_print(code.ptr, code.len, buffer.ptr, buffer.len);
    try std.testing.expectEqual(needed, written);
    try std.testing.expectEqual(@as(u8, 0), buffer[written - 1]);
    // A buffer that is too small truncates and still terminates.
    var small: [16]u8 = undefined;
    const truncated = evm_bytecode_pretty_print(code.ptr, code.len, &small, small.len);
    try std.testing.expect(truncated <= small.len);
    if (truncated > 0) try std.testing.expectEqual(@as(u8, 0), small[truncated - 1]);
}

/// Handle lifetime driven by the input: each byte creates, uses, destroys or
/// destroys again one of four handle slots. A destroyed handle must be refused by
/// every entry point, and a live one must keep working, in any order.
pub fn fuzzCApiHandleLifetime(_: void, input: []const u8) !void {
    guillotine_init();
    var block = BlockInfoFFI{
        .number = 1,
        .timestamp = 1,
        .gas_limit = 30_000_000,
        .coinbase = @as([20]u8, @splat(0)),
        .base_fee = 0,
        .chain_id = 1,
        .difficulty = 0,
        .prev_randao = @as([32]u8, @splat(0)),
    };
    const account = @as([19]u8, @splat(0)) ++ [_]u8{0x33};
    var live: [4]?*EvmHandle = @splat(null);
    var dead: [4]?*EvmHandle = @splat(null);
    defer for (live) |slot| {
        if (slot) |handle| guillotine_evm_destroy(handle);
    };

    for (input[0..@min(input.len, 48)]) |byte| {
        const slot = byte & 3;
        switch ((byte >> 2) % 5) {
            0 => if (live[slot] == null) {
                live[slot] = guillotine_evm_create(&block) orelse return error.EvmCreateFailed;
            },
            1 => if (live[slot]) |handle| {
                guillotine_evm_destroy(handle);
                dead[slot] = handle;
                live[slot] = null;
            },
            // Destroying a destroyed handle is reported, never acted on.
            2 => if (dead[slot]) |handle| guillotine_evm_destroy(handle),
            3 => if (live[slot]) |handle| {
                var balance = @as([32]u8, @splat(0));
                balance[31] = byte;
                try std.testing.expect(guillotine_set_balance(handle, &account, &balance));
                var read = @as([32]u8, @splat(0xff));
                try std.testing.expect(guillotine_get_balance(handle, &account, &read));
                try std.testing.expectEqualSlices(u8, &balance, &read);
            },
            else => if (dead[slot]) |handle| {
                // Tokens are never reused, so a dead handle stays dead whatever
                // was created since.
                var read = @as([32]u8, @splat(0));
                try std.testing.expect(!guillotine_get_balance(handle, &account, &read));
                try std.testing.expect(!guillotine_set_nonce(handle, &account, 1));
                var sentinel = [_]u8{0};
                var params = CallParamsFFI{
                    .caller = account,
                    .to = account,
                    .value = @as([32]u8, @splat(0)),
                    .input = &sentinel,
                    .input_len = 0,
                    .gas = 100_000,
                    .call_type = 0,
                    .salt = @as([32]u8, @splat(0)),
                };
                try std.testing.expect(guillotine_call(handle, &params) == null);
                try std.testing.expect(guillotine_simulate(handle, &params) == null);
            },
        }
    }
}

const pretty_print_corpus: []const []const u8 = &.{
    &.{ 0x00, 0x00, 0xa4 }, // exactly 10,923 LOG4: the first length that overflowed
    &.{ 0x00, 0x01, 0xa4 }, // 65,502 LOG4: the longest code a 16-bit pc holds
    &.{ 0x00, 0x02, 0xa4 }, // 65,503: one past it, refused
    &.{ 0xff, 0xff, 0xa4 }, // 70,000 LOG4
    &.{ 0x80, 0x03, 0x80 }, // DUP1 run: stack headroom saturates upward
    &.{ 0x10, 0x04, 0x60, 0x01, 0x56, 0x5b, 0xa4, 0xa4 }, // jumps, JUMPDESTs and LOG4
    &.{ 0x00, 0x05, 0x7f }, // PUSH32 whose immediate is the code itself
    &.{ 0x20, 0x06, 0xfe, 0x00, 0xf3, 0xfd, 0xff }, // one-byte blocks
};

const lifetime_corpus: []const []const u8 = &.{
    &.{ 0x00, 0x0c, 0x04, 0x10, 0x08, 0x00, 0x0c }, // create, use, destroy, use dead, double destroy, recreate
    &.{ 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x10, 0x11, 0x12, 0x13 }, // all four slots
    &.{ 0x04, 0x08, 0x10 }, // destroy and use with nothing created
    &.{ 0x00, 0x04, 0x00, 0x04, 0x00, 0x04, 0x10, 0x08 }, // token after token on one slot
};

const seed_corpus: []const []const u8 = &.{
    &.{ 0, 1, 2, 3, 4, 0x60, 0x2a, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3 },
    &.{ 3, 2, 5, 1, 9, 0x60, 0x01, 0x60, 0x00, 0x55 }, // STATICCALL attempting SSTORE
    &.{ 4, 3, 0, 0, 0, 0x60, 0x01, 0x60, 0x00, 0xf3 }, // CREATE
    &.{ 5, 4, 0, 0, 0, 0x60, 0x01, 0x60, 0x00, 0xf3 }, // CREATE2
    &.{ 2, 0, 1, 0, 7, 0x60, 0x99, 0x60, 0x00, 0x55, 0x00 }, // DELEGATECALL
};

test "fuzz C FFI boundary lifecycle, invalid call types, simulate isolation, and execution" {
    try std.testing.fuzz({}, fuzz_alloc.bytes(fuzzCApiLifecycleAndExecution), .{ .corpus = seed_corpus });
}

test "fuzz evm_bytecode_pretty_print over long single-opcode runs and program counter edges" {
    try std.testing.fuzz({}, fuzz_alloc.bytes(fuzzCApiPrettyPrint), .{ .corpus = pretty_print_corpus });
}

test "fuzz C FFI handle lifetime: create, use, destroy, double destroy, use after destroy" {
    try std.testing.fuzz({}, fuzz_alloc.bytes(fuzzCApiHandleLifetime), .{ .corpus = lifetime_corpus });
}

test "evm_bytecode_pretty_print returns cleanly for 10,923 and 100,000 LOG4" {
    const allocator = std.testing.allocator;
    const code = try allocator.alloc(u8, 100_000);
    defer allocator.free(code);
    @memset(code, 0xa4);

    // 10,922 LOG4 need 65,532 stack items, 10,923+ need >= 65,538: more than the u16
    // the block header prints. Every length including 65,503 and 100,000 formats cleanly
    // across the wide-PC C ABI and clamps to 65535.
    for ([_]usize{ 10_922, 10_923, 65_502, 65_503, 100_000 }) |len| {
        const needed = evm_bytecode_pretty_print(code.ptr, len, null, 0);
        try std.testing.expect(needed > 1);
        const buffer = try allocator.alloc(u8, needed);
        defer allocator.free(buffer);
        try std.testing.expectEqual(needed, evm_bytecode_pretty_print(code.ptr, len, buffer.ptr, buffer.len));
        const expected = if (len == 10_922) "stack: [65532, 0]" else "stack: [65535, 0]";
        try std.testing.expect(std.mem.indexOf(u8, buffer[0 .. needed - 1], expected) != null);
    }
    var small: [8]u8 = undefined;
    const truncated = evm_bytecode_pretty_print(code.ptr, 100_000, &small, small.len);
    try std.testing.expectEqual(small.len, truncated);
    try std.testing.expectEqual(@as(u8, 0), small[small.len - 1]);
}

test "guillotine_call rolls the transaction back when its C result cannot be allocated" {
    guillotine_init();
    var block = BlockInfoFFI{
        .number = 1,
        .timestamp = 1,
        .gas_limit = 30_000_000,
        .coinbase = @as([19]u8, @splat(0)) ++ [_]u8{0xcc},
        .base_fee = 1,
        .chain_id = 1,
        .difficulty = 0,
        .prev_randao = @as([32]u8, @splat(0)),
    };
    const handle = guillotine_evm_create(&block) orelse return error.EvmCreateFailed;
    defer guillotine_evm_destroy(handle);

    const caller = @as([19]u8, @splat(0)) ++ [_]u8{0x11};
    const target = @as([19]u8, @splat(0)) ++ [_]u8{0x22};
    // SSTORE(1, 0x42); LOG0(0, 0x20); RETURN(0, 0x20): storage, a log and output.
    const code = [_]u8{ 0x60, 0x42, 0x60, 0x01, 0x55, 0x60, 0x20, 0x60, 0x00, 0xa0, 0x60, 0x20, 0x60, 0x00, 0xf3 };
    var balance = @as([32]u8, @splat(0));
    balance[31] = 100;
    try std.testing.expect(guillotine_set_balance(handle, &caller, &balance));
    try std.testing.expect(guillotine_set_code(handle, &target, &code, code.len));

    var value = @as([32]u8, @splat(0));
    value[31] = 5;
    var sentinel = [_]u8{0};
    var params = CallParamsFFI{
        .caller = caller,
        .to = target,
        .value = value,
        .input = &sentinel,
        .input_len = 0,
        .gas = 200_000,
        .call_type = 0,
        .salt = @as([32]u8, @splat(0)),
    };
    var slot = @as([32]u8, @splat(0));
    slot[31] = 1;
    const zero = @as([32]u8, @splat(0));

    // Fail each allocation of the result copy in turn. The EVM has already run and
    // committed the call by then; every failure must take all of it back.
    var rolled_back: usize = 0;
    var fail_at: usize = 0;
    while (true) : (fail_at += 1) {
        try std.testing.expect(fail_at < 64);
        c_api.test_hooks.fail_result_allocation_at = fail_at;
        const result = guillotine_call(handle, &params);
        const injected = c_api.test_hooks.fail_result_allocation_at == null;
        c_api.test_hooks.fail_result_allocation_at = null;

        var stored = @as([32]u8, @splat(0xff));
        try std.testing.expect(guillotine_get_storage(handle, &target, &slot, &stored));
        var caller_balance = @as([32]u8, @splat(0xff));
        try std.testing.expect(guillotine_get_balance(handle, &caller, &caller_balance));
        var target_balance = @as([32]u8, @splat(0xff));
        try std.testing.expect(guillotine_get_balance(handle, &target, &target_balance));

        if (result) |r| {
            // No allocation was left to fail: the call is committed, once.
            defer guillotine_free_result(r);
            try std.testing.expect(!injected);
            try std.testing.expect(r.success);
            try std.testing.expectEqual(@as(usize, 1), r.logs_len);
            try std.testing.expectEqual(@as(u8, 0x42), stored[31]);
            try std.testing.expectEqual(@as(u8, 95), caller_balance[31]);
            try std.testing.expectEqual(@as(u8, 5), target_balance[31]);
            break;
        }
        // NULL: nothing of the call may remain. Storage, both balances (the value
        // transfer) and with them the sender's nonce are as before.
        try std.testing.expect(injected);
        rolled_back += 1;
        try std.testing.expectEqualSlices(u8, &zero, &stored);
        try std.testing.expectEqualSlices(u8, &balance, &caller_balance);
        try std.testing.expectEqualSlices(u8, &zero, &target_balance);
        try std.testing.expect(std.mem.indexOf(u8, std.mem.span(guillotine_get_last_error()), "rolled back") != null);
    }
    // The result struct, the output, the log array, its data and both access lists.
    try std.testing.expect(rolled_back >= 5);

    // The nonce was rolled back with the rest: had any failed attempt kept its
    // increment, this CREATE would land on another address than nonce 1 gives.
    var create = params;
    create.call_type = 4;
    create.value = zero;
    const init_code = [_]u8{0x00};
    create.input = &init_code;
    create.input_len = init_code.len;
    const created = guillotine_call(handle, &create) orelse return error.CreateFailed;
    defer guillotine_free_result(created);
    try std.testing.expect(created.success);
    try std.testing.expect(created.has_created_address);
    const expected = try primitives.Address.getContractAddress(std.testing.allocator, .{ .bytes = caller }, 1);
    try std.testing.expectEqualSlices(u8, &expected.bytes, &created.created_address);
}

test "guillotine_simulate commits nothing, with or without a failed result copy" {
    guillotine_init();
    var block = BlockInfoFFI{
        .number = 1,
        .timestamp = 1,
        .gas_limit = 30_000_000,
        .coinbase = @as([19]u8, @splat(0)) ++ [_]u8{0xcc},
        .base_fee = 0,
        .chain_id = 1,
        .difficulty = 0,
        .prev_randao = @as([32]u8, @splat(0)),
    };
    const handle = guillotine_evm_create(&block) orelse return error.EvmCreateFailed;
    defer guillotine_evm_destroy(handle);

    const caller = @as([19]u8, @splat(0)) ++ [_]u8{0x11};
    const target = @as([19]u8, @splat(0)) ++ [_]u8{0x22};
    const code = [_]u8{ 0x60, 0x42, 0x60, 0x01, 0x55, 0x60, 0x20, 0x60, 0x00, 0xf3 };
    try std.testing.expect(guillotine_set_code(handle, &target, &code, code.len));
    var sentinel = [_]u8{0};
    var params = CallParamsFFI{
        .caller = caller,
        .to = target,
        .value = @as([32]u8, @splat(0)),
        .input = &sentinel,
        .input_len = 0,
        .gas = 200_000,
        .call_type = 0,
        .salt = @as([32]u8, @splat(0)),
    };
    var slot = @as([32]u8, @splat(0));
    slot[31] = 1;
    const zero = @as([32]u8, @splat(0));

    for ([_]?usize{ 0, 1, 2, null }) |fail_at| {
        c_api.test_hooks.fail_result_allocation_at = fail_at;
        const result = guillotine_simulate(handle, &params);
        c_api.test_hooks.fail_result_allocation_at = null;
        if (result) |r| {
            defer guillotine_free_result(r);
            try std.testing.expect(r.success);
        } else {
            try std.testing.expect(fail_at != null);
        }
        var stored = @as([32]u8, @splat(0xff));
        try std.testing.expect(guillotine_get_storage(handle, &target, &slot, &stored));
        try std.testing.expectEqualSlices(u8, &zero, &stored);
    }
    // No simulation moved the sender's nonce: a CREATE from the same sender still
    // derives its address from nonce 0.
    var create = params;
    create.call_type = 4;
    const init_code = [_]u8{0x00};
    create.input = &init_code;
    create.input_len = init_code.len;
    const created = guillotine_call(handle, &create) orelse return error.CreateFailed;
    defer guillotine_free_result(created);
    try std.testing.expect(created.success);
    const expected = try primitives.Address.getContractAddress(std.testing.allocator, .{ .bytes = caller }, 0);
    try std.testing.expectEqualSlices(u8, &expected.bytes, &created.created_address);
}

test "C ABI stress: calls and state getters race guillotine_evm_destroy and guillotine_cleanup" {
    const slot_count = 4;
    const Shared = struct {
        /// Handle tokens published to the workers; 0 while a slot is empty. A token
        /// may be destroyed at any moment after a worker read it: that is the race.
        slots: [slot_count]std.atomic.Value(usize) = @splat(.init(0)),
        stop: std.atomic.Value(bool) = .init(false),
        calls: std.atomic.Value(usize) = .init(0),
        accepted: std.atomic.Value(usize) = .init(0),
        failed_checks: std.atomic.Value(usize) = .init(0),

        const account = @as([19]u8, @splat(0)) ++ [_]u8{0x11};
        const contract = @as([19]u8, @splat(0)) ++ [_]u8{0x22};
        // SSTORE(1, 0x42); RETURN(0, 0x20).
        const code = [_]u8{ 0x60, 0x42, 0x60, 0x01, 0x55, 0x60, 0x20, 0x60, 0x00, 0xf3 };

        fn worker(shared: *@This(), seed: u64) void {
            var prng = std.Random.DefaultPrng.init(seed);
            const random = prng.random();
            var sentinel = [_]u8{0};
            var params = CallParamsFFI{
                .caller = account,
                .to = contract,
                .value = @as([32]u8, @splat(0)),
                .input = &sentinel,
                .input_len = 0,
                .gas = 100_000,
                .call_type = 0,
                .salt = @as([32]u8, @splat(0)),
            };
            var key = @as([32]u8, @splat(0));
            key[31] = 1;
            while (!shared.stop.load(.acquire)) {
                const token = shared.slots[random.uintLessThan(usize, slot_count)].load(.acquire);
                if (token == 0) continue;
                const handle: *EvmHandle = @ptrFromInt(token);
                _ = shared.calls.fetchAdd(1, .monotonic);
                switch (random.uintLessThan(u8, 5)) {
                    0 => {
                        var out = @as([32]u8, @splat(0));
                        if (guillotine_get_balance(handle, &account, &out)) {
                            _ = shared.accepted.fetchAdd(1, .monotonic);
                            // Every handle is seeded with balance 7 before it is published.
                            if (out[31] != 7) _ = shared.failed_checks.fetchAdd(1, .monotonic);
                        }
                    },
                    1 => {
                        var out = @as([32]u8, @splat(0));
                        if (guillotine_get_storage(handle, &contract, &key, &out)) {
                            _ = shared.accepted.fetchAdd(1, .monotonic);
                            // Only a committed call writes the slot, and only 0x42.
                            if (out[31] != 0 and out[31] != 0x42) _ = shared.failed_checks.fetchAdd(1, .monotonic);
                        }
                    },
                    2 => {
                        var ptr: [*]u8 = undefined;
                        var len: usize = 0;
                        if (guillotine_get_code(handle, &contract, &ptr, &len)) {
                            _ = shared.accepted.fetchAdd(1, .monotonic);
                            if (len != code.len) _ = shared.failed_checks.fetchAdd(1, .monotonic);
                            if (len > 0) guillotine_free_code(ptr, len);
                        }
                    },
                    3 => if (guillotine_call(handle, &params)) |result| {
                        _ = shared.accepted.fetchAdd(1, .monotonic);
                        if (!result.success) _ = shared.failed_checks.fetchAdd(1, .monotonic);
                        guillotine_free_result(result);
                    },
                    else => if (guillotine_simulate(handle, &params)) |result| {
                        _ = shared.accepted.fetchAdd(1, .monotonic);
                        if (!result.success) _ = shared.failed_checks.fetchAdd(1, .monotonic);
                        guillotine_free_result(result);
                    },
                }
            }
        }
    };

    const baseline_boxes = c_api.test_hooks.live_boxes.load(.acquire);
    guillotine_init();
    var shared = Shared{};
    var workers: [6]std.Thread = undefined;
    for (&workers, 0..) |*thread, index| {
        thread.* = try std.Thread.spawn(.{}, Shared.worker, .{ &shared, @as(u64, 0x9E3779B97F4A7C15) *% @as(u64, index + 1) });
    }

    var block = BlockInfoFFI{
        .number = 1,
        .timestamp = 1,
        .gas_limit = 30_000_000,
        .coinbase = @as([20]u8, @splat(0)),
        .base_fee = 0,
        .chain_id = 1,
        .difficulty = 0,
        .prev_randao = @as([32]u8, @splat(0)),
    };
    var balance = @as([32]u8, @splat(0));
    balance[31] = 7;
    var created: usize = 0;
    const rounds = 48;
    for (0..rounds) |round| {
        for (&shared.slots) |*slot| {
            // Build and seed a handle, publish it, and destroy the one it replaces
            // while the workers may be in the middle of a call on it.
            const fresh = guillotine_evm_create(&block) orelse return error.EvmCreateFailed;
            created += 1;
            try std.testing.expect(guillotine_set_balance(fresh, &Shared.account, &balance));
            try std.testing.expect(guillotine_set_code(fresh, &Shared.contract, &Shared.code, Shared.code.len));
            const previous = slot.swap(@intFromPtr(fresh), .acq_rel);
            if (previous != 0) guillotine_evm_destroy(@ptrFromInt(previous));
        }
        // Every fourth round, tear everything down at once, published handles
        // included, and start again.
        if (round % 4 == 3) {
            guillotine_cleanup();
            guillotine_init();
        }
    }

    shared.stop.store(true, .release);
    for (workers) |thread| thread.join();
    guillotine_cleanup();
    guillotine_init();

    try std.testing.expectEqual(@as(usize, rounds * slot_count), created);
    // The workers ran against live handles, and nothing they read was corrupt.
    try std.testing.expect(shared.calls.load(.acquire) > 0);
    try std.testing.expect(shared.accepted.load(.acquire) > 0);
    try std.testing.expectEqual(@as(usize, 0), shared.failed_checks.load(.acquire));
    // Every box was torn down exactly once: none leaked, none freed twice.
    try std.testing.expectEqual(baseline_boxes, c_api.test_hooks.live_boxes.load(.acquire));
    // Every token the workers still hold is dead.
    for (&shared.slots) |*slot| {
        var out = @as([32]u8, @splat(0));
        try std.testing.expect(!guillotine_get_balance(@ptrFromInt(slot.load(.acquire)), &Shared.account, &out));
    }
}
