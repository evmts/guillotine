//! Standard EVMC ABI v12 shared library implementation for Guillotine.
//!
//! Exports `evmc_create_guillotine()`, allowing any EVMC-compatible Ethereum client
//! or test runner (Erigon, Nethermind, Silkworm, Besu, evmc-vmtester) to load
//! `libguillotine_evmc` dynamically and execute EVM bytecode through Guillotine's
//! `preserve_none` tailcall dispatch engine.

const std = @import("std");
const evm = @import("evm");
const primitives = @import("voltaire");
const types = @import("evmc_types.zig");

pub const guillotine_embedded = true;

pub const EVMC_ABI_VERSION = types.EVMC_ABI_VERSION;
pub const EVMC_CAPABILITY_EVM1 = types.EVMC_CAPABILITY_EVM1;
pub const EVMC_STATIC = types.EVMC_STATIC;
pub const EvmcBytes32 = types.EvmcBytes32;
pub const EvmcAddress = types.EvmcAddress;
pub const EvmcCallKind = types.EvmcCallKind;
pub const EvmcStatusCode = types.EvmcStatusCode;
pub const EvmcRevision = types.EvmcRevision;
pub const EvmcSetOptionResult = types.EvmcSetOptionResult;
pub const EvmcStorageStatus = types.EvmcStorageStatus;
pub const EvmcAccessStatus = types.EvmcAccessStatus;
pub const EvmcMessage = types.EvmcMessage;
pub const EvmcTxContext = types.EvmcTxContext;
pub const EvmcHostContext = types.EvmcHostContext;
pub const EvmcReleaseResultFn = types.EvmcReleaseResultFn;
pub const EvmcResult = types.EvmcResult;
pub const EvmcHostInterface = types.EvmcHostInterface;
pub const EvmcVm = types.EvmcVm;

const GuillotineEvmcInstance = struct {
    vm: EvmcVm,
    enable_fusion: bool = true,
};

const host_db = @import("evmc_host_db.zig");
pub const EvmcHostDb = host_db.EvmcHostDb;
const bytes32ToU256 = host_db.bytes32ToU256;
const u256ToBytes32 = host_db.u256ToBytes32;

const c_alloc = std.heap.c_allocator;

fn releaseOutput(res: *const EvmcResult) callconv(.c) void {
    if (res.output_data) |ptr| {
        if (res.output_size > 0) c_alloc.free(ptr[0..res.output_size]);
    }
}

fn emptyResult(status: EvmcStatusCode, gas_left: i64) EvmcResult {
    return .{
        .status_code = status,
        .gas_left = gas_left,
        .gas_refund = 0,
        .output_data = null,
        .output_size = 0,
        .release = null,
        .create_address = .{ .bytes = @splat(0) },
    };
}

fn buildBlockAndTx(host: ?*const EvmcHostInterface, ctx: ?*EvmcHostContext, msg: *const EvmcMessage) struct {
    block: evm.BlockInfo,
    tx: evm.TransactionContext,
    gas_price: u256,
    origin: primitives.Address,
} {
    var block = evm.BlockInfo.init();
    var origin = primitives.Address{ .bytes = msg.sender.bytes };
    var gas_price: u256 = 0;
    if (host) |h| {
        const tc = h.get_tx_context(ctx);
        gas_price = bytes32ToU256(tc.tx_gas_price);
        origin = .{ .bytes = tc.tx_origin.bytes };
        block.coinbase = .{ .bytes = tc.block_coinbase.bytes };
        block.number = if (tc.block_number > 0) @intCast(tc.block_number) else 0;
        block.timestamp = if (tc.block_timestamp > 0) @intCast(tc.block_timestamp) else 0;
        block.gas_limit = if (tc.block_gas_limit > 0) @intCast(tc.block_gas_limit) else 30_000_000;
        block.prev_randao = tc.block_prev_randao.bytes;
        block.chain_id = @truncate(bytes32ToU256(tc.chain_id));
        block.base_fee = @truncate(bytes32ToU256(tc.block_base_fee));
        block.blob_base_fee = @truncate(bytes32ToU256(tc.blob_base_fee));
    }
    const tx = evm.TransactionContext{
        .gas_limit = if (msg.gas > 0) @intCast(msg.gas) else 0,
        .coinbase = block.coinbase,
        .chain_id = block.chain_id,
        .blob_base_fee = block.blob_base_fee,
    };
    return .{ .block = block, .tx = tx, .gas_price = gas_price, .origin = origin };
}

fn buildEvmcCallParams(
    comptime EvmType: type,
    msg: *const EvmcMessage,
    input_slice: []const u8,
    code_slice: []const u8,
) ?EvmType.CallParams {
    const gas_u64: u64 = @intCast(msg.gas);
    const val = bytes32ToU256(msg.value);
    const caller = primitives.Address{ .bytes = msg.sender.bytes };
    const recipient = primitives.Address{ .bytes = msg.recipient.bytes };
    const code_addr = primitives.Address{ .bytes = msg.code_address.bytes };
    const is_static = (msg.flags & EVMC_STATIC) != 0;

    return switch (msg.kind) {
        .call => if (is_static)
            .{ .staticcall = .{ .caller = caller, .to = recipient, .input = input_slice, .gas = gas_u64 } }
        else
            .{ .call = .{
                .caller = caller,
                .to = recipient,
                .value = val,
                .input = input_slice,
                .gas = gas_u64,
            } },
        .delegatecall => .{ .delegatecall = .{
            .caller = caller,
            .to = code_addr,
            .input = input_slice,
            .gas = gas_u64,
            .context_address = recipient,
        } },
        .callcode => .{ .callcode = .{
            .caller = caller,
            .to = code_addr,
            .value = val,
            .input = input_slice,
            .gas = gas_u64,
        } },
        .create => .{ .create = .{ .caller = caller, .value = val, .init_code = code_slice, .gas = gas_u64 } },
        .create2 => .{ .create2 = .{
            .caller = caller,
            .value = val,
            .init_code = code_slice,
            .salt = bytes32ToU256(msg.create2_salt),
            .gas = gas_u64,
        } },
        .eofcreate => null,
    };
}

fn packEvmcResult(call_res: anytype, gas_refund: u64) EvmcResult {
    var out_ptr: ?[*]const u8 = null;
    if (call_res.output.len > 0) {
        const dup = c_alloc.dupe(u8, call_res.output) catch return emptyResult(.out_of_memory, 0);
        out_ptr = dup.ptr;
    }
    const status: EvmcStatusCode = if (call_res.success)
        .success
    else if (call_res.gas_left > 0 or call_res.output.len > 0)
        .revert
    else
        .failure;
    return EvmcResult{
        .status_code = status,
        .gas_left = @intCast(call_res.gas_left),
        .gas_refund = if (call_res.success) @intCast(gas_refund) else 0,
        .output_data = out_ptr,
        .output_size = call_res.output.len,
        .release = if (out_ptr != null) releaseOutput else null,
        .create_address = if (call_res.created_address) |ca| .{ .bytes = ca.bytes } else .{ .bytes = @splat(0) },
    };
}

fn executeForFork(
    comptime hardfork: evm.Hardfork,
    comptime enable_fusion: bool,
    host: ?*const EvmcHostInterface,
    ctx: ?*EvmcHostContext,
    msg: *const EvmcMessage,
    code_ptr: ?[*]const u8,
    code_size: usize,
) EvmcResult {
    if (msg.gas < 0) return emptyResult(.out_of_gas, 0);
    if (msg.kind == .eofcreate) return emptyResult(.rejected, msg.gas);

    const EvmType = evm.Evm(.{
        .eips = .{ .hardfork = hardfork },
        .enable_fusion = enable_fusion,
        .DatabaseType = EvmcHostDb,
        .enable_beacon_roots = false,
        .enable_historical_block_hashes = false,
    });

    var db = EvmcHostDb.init(c_alloc, host, ctx);
    defer db.deinit();

    const code_slice: []const u8 = if (code_ptr) |p| p[0..code_size] else &.{};
    const input_slice: []const u8 = if (msg.input_data) |p| p[0..msg.input_size] else &.{};
    const target_addr = if (msg.kind == .delegatecall or msg.kind == .callcode) msg.code_address else msg.recipient;

    if (code_slice.len > 0 and msg.kind != .create and msg.kind != .create2) {
        const hash = db.set_code(code_slice) catch return emptyResult(.out_of_memory, 0);
        const existing = db.get_account(target_addr.bytes) catch return emptyResult(.out_of_memory, 0);
        var acc = existing orelse evm.Account.zero();
        acc.code_hash = hash;
        db.set_account(target_addr.bytes, acc) catch return emptyResult(.out_of_memory, 0);
    }

    const env = buildBlockAndTx(host, ctx, msg);
    var vm = EvmType.init(c_alloc, &db, env.block, env.tx, env.gas_price, env.origin) catch {
        return emptyResult(.internal_error, 0);
    };
    defer vm.deinit();

    const params = buildEvmcCallParams(EvmType, msg, input_slice, code_slice) orelse {
        return emptyResult(.rejected, msg.gas);
    };
    const call_res = vm.inner_call(params);
    if (vm.host_failure != null) return emptyResult(.internal_error, 0);

    if (call_res.success) {
        db.flushToHost();
        forwardHostSideEffects(host, ctx, vm.logs.items, &vm.self_destruct);
    }
    return packEvmcResult(call_res, vm.gas_refund_counter);
}

fn forwardHostSideEffects(
    host: ?*const EvmcHostInterface,
    ctx: ?*EvmcHostContext,
    logs: anytype,
    self_destruct: *evm.SelfDestruct,
) void {
    const h = host orelse return;
    for (logs) |entry| {
        const c_addr = EvmcAddress{ .bytes = entry.address.bytes };
        var topics_buf: [4]EvmcBytes32 = undefined;
        const n = @min(entry.topics.len, 4);
        for (entry.topics[0..n], 0..) |t, i| topics_buf[i] = u256ToBytes32(t);
        const data_ptr: ?[*]const u8 = if (entry.data.len > 0) entry.data.ptr else null;
        const topics_ptr: ?[*]const EvmcBytes32 = if (n > 0) &topics_buf else null;
        h.emit_log(ctx, &c_addr, data_ptr, entry.data.len, topics_ptr, n);
    }
    var it = self_destruct.iterator();
    while (it.next()) |sd| {
        const contract = EvmcAddress{ .bytes = sd.key_ptr.bytes };
        const beneficiary = EvmcAddress{ .bytes = sd.value_ptr.bytes };
        _ = h.selfdestruct(ctx, &contract, &beneficiary);
    }
}

fn dispatchRevision(
    comptime enable_fusion: bool,
    host: ?*const EvmcHostInterface,
    ctx: ?*EvmcHostContext,
    rev: EvmcRevision,
    msg: *const EvmcMessage,
    code: ?[*]const u8,
    code_size: usize,
) EvmcResult {
    return switch (rev) {
        .frontier => executeForFork(.FRONTIER, enable_fusion, host, ctx, msg, code, code_size),
        .homestead => executeForFork(.HOMESTEAD, enable_fusion, host, ctx, msg, code, code_size),
        .tangerine_whistle => executeForFork(.TANGERINE_WHISTLE, enable_fusion, host, ctx, msg, code, code_size),
        .spurious_dragon => executeForFork(.SPURIOUS_DRAGON, enable_fusion, host, ctx, msg, code, code_size),
        .byzantium => executeForFork(.BYZANTIUM, enable_fusion, host, ctx, msg, code, code_size),
        .constantinople, .petersburg => executeForFork(.CONSTANTINOPLE, enable_fusion, host, ctx, msg, code, code_size),
        .istanbul => executeForFork(.ISTANBUL, enable_fusion, host, ctx, msg, code, code_size),
        .berlin => executeForFork(.BERLIN, enable_fusion, host, ctx, msg, code, code_size),
        .london => executeForFork(.LONDON, enable_fusion, host, ctx, msg, code, code_size),
        .paris => executeForFork(.MERGE, enable_fusion, host, ctx, msg, code, code_size),
        .shanghai => executeForFork(.SHANGHAI, enable_fusion, host, ctx, msg, code, code_size),
        .cancun => executeForFork(.CANCUN, enable_fusion, host, ctx, msg, code, code_size),
        .prague => executeForFork(.PRAGUE, enable_fusion, host, ctx, msg, code, code_size),
        .osaka => executeForFork(.OSAKA, enable_fusion, host, ctx, msg, code, code_size),
    };
}

fn evmcDestroy(vm_ptr: *EvmcVm) callconv(.c) void {
    const inst: *GuillotineEvmcInstance = @fieldParentPtr("vm", vm_ptr);
    c_alloc.destroy(inst);
}

fn evmcGetCapabilities(_: *EvmcVm) callconv(.c) u32 {
    return EVMC_CAPABILITY_EVM1;
}

fn evmcSetOption(vm_ptr: *EvmcVm, name_z: [*:0]const u8, value_z: [*:0]const u8) callconv(.c) EvmcSetOptionResult {
    const inst: *GuillotineEvmcInstance = @fieldParentPtr("vm", vm_ptr);
    const name = std.mem.span(name_z);
    const value = std.mem.span(value_z);
    if (std.mem.eql(u8, name, "fusion")) {
        if (std.mem.eql(u8, value, "1") or std.mem.eql(u8, value, "true")) {
            inst.enable_fusion = true;
            return .success;
        }
        if (std.mem.eql(u8, value, "0") or std.mem.eql(u8, value, "false")) {
            inst.enable_fusion = false;
            return .success;
        }
        return .invalid_value;
    }
    return .invalid_name;
}

fn evmcExecute(
    vm_ptr: *EvmcVm,
    host: ?*const EvmcHostInterface,
    ctx: ?*EvmcHostContext,
    rev: EvmcRevision,
    msg: *const EvmcMessage,
    code: ?[*]const u8,
    code_size: usize,
) callconv(.c) EvmcResult {
    const inst: *GuillotineEvmcInstance = @fieldParentPtr("vm", vm_ptr);
    if (inst.enable_fusion) {
        return dispatchRevision(true, host, ctx, rev, msg, code, code_size);
    }
    return dispatchRevision(false, host, ctx, rev, msg, code, code_size);
}

/// Official EVMC factory entry point (`evmc_create_guillotine`).
pub export fn evmc_create_guillotine() callconv(.c) ?*EvmcVm {
    const inst = c_alloc.create(GuillotineEvmcInstance) catch return null;
    inst.* = .{
        .vm = .{
            .abi_version = EVMC_ABI_VERSION,
            .name = "guillotine",
            .version = "0.1.0",
            .destroy = evmcDestroy,
            .execute = evmcExecute,
            .get_capabilities = evmcGetCapabilities,
            .set_option = evmcSetOption,
        },
        .enable_fusion = true,
    };
    return &inst.vm;
}

test "evmc_c_api bytes32 u256 roundtrip" {
    const val: u256 = 0x1234_5678_9abc_def0;
    try std.testing.expectEqual(val, bytes32ToU256(u256ToBytes32(val)));
}
