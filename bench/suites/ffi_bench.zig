const std = @import("std");
const micro = @import("micro");
const c_api = @import("evm_c_api");

comptime {
    _ = c_api;
}

extern fn guillotine_init() void;
extern fn guillotine_evm_create(block_info_ptr: *const c_api.BlockInfoFFI) ?*c_api.EvmHandle;
extern fn guillotine_evm_destroy(handle: *c_api.EvmHandle) void;
extern fn guillotine_set_code(handle: *c_api.EvmHandle, address: *const [20]u8, code: [*]const u8, code_len: usize) bool;
extern fn guillotine_simulate(handle: *c_api.EvmHandle, params: *const c_api.CallParams) ?*c_api.EvmResult;
extern fn guillotine_free_result(result: ?*c_api.EvmResult) void;

fn makeAddCode() [14]u8 {
    // PUSH1 7, PUSH1 3, ADD, PUSH1 0, MSTORE, PUSH1 32, PUSH1 0, RETURN
    return .{ 0x60, 7, 0x60, 3, 0x01, 0x60, 0, 0x52, 0x60, 32, 0x60, 0, 0xf3, 0x00 };
}

fn benchFfiCreateDestroy(_: std.mem.Allocator) !u64 {
    guillotine_init();
    var block = c_api.BlockInfoFFI{
        .number = 24_000_000,
        .timestamp = 1_800_000_000,
        .gas_limit = 30_000_000,
        .coinbase = [_]u8{0} ** 20,
        .base_fee = 1_000_000_000,
        .chain_id = 1,
        .difficulty = 0,
        .prev_randao = [_]u8{0} ** 32,
    };
    var ok: u64 = 0;
    for (0..32) |_| {
        const handle = guillotine_evm_create(&block) orelse return error.CreateFailed;
        guillotine_evm_destroy(handle);
        ok += 1;
    }
    return ok;
}

fn benchFfiSimulateCall(_: std.mem.Allocator) !u64 {
    guillotine_init();
    var block = c_api.BlockInfoFFI{
        .number = 24_000_000,
        .timestamp = 1_800_000_000,
        .gas_limit = 30_000_000,
        .coinbase = [_]u8{0} ** 20,
        .base_fee = 1_000_000_000,
        .chain_id = 1,
        .difficulty = 0,
        .prev_randao = [_]u8{0} ** 32,
    };
    const handle = guillotine_evm_create(&block) orelse return error.CreateFailed;
    defer guillotine_evm_destroy(handle);

    var caller = [_]u8{0} ** 20;
    caller[19] = 0x10;
    var contract = [_]u8{0} ** 20;
    contract[19] = 0x20;
    const code = makeAddCode();
    if (!guillotine_set_code(handle, &contract, &code, code.len)) return error.SetCodeFailed;

    var empty = [_]u8{};
    const params = c_api.CallParams{
        .caller = caller,
        .to = contract,
        .value = [_]u8{0} ** 32,
        .input = &empty,
        .input_len = 0,
        .gas = 1_000_000,
        .call_type = 0,
        .salt = [_]u8{0} ** 32,
    };

    var acc: u64 = 0;
    for (0..32) |_| {
        const res = guillotine_simulate(handle, &params) orelse return error.CallFailed;
        defer guillotine_free_result(res);
        if (!res.success or res.output_len != 32) return error.UnexpectedResult;
        acc +%= res.output[31];
    }
    return acc;
}

pub fn main() void {
    micro.runSuite("ffi", &.{
        .{ .name = "ffi/evm-create-destroy-32", .operations = 32, .run = benchFfiCreateDestroy },
        .{ .name = "ffi/simulate-call-32", .operations = 32, .run = benchFfiSimulateCall },
    });
}
