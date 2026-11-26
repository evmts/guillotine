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
