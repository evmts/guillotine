//! Standard EVMC ABI v12 C extern type definitions (`sdks/c/include/evmc_guillotine.h`).

const std = @import("std");

pub const EVMC_ABI_VERSION: c_int = 12;
pub const EVMC_CAPABILITY_EVM1: u32 = 1 << 0;
pub const EVMC_STATIC: u32 = 1 << 0;

pub const EvmcBytes32 = extern struct { bytes: [32]u8 };
pub const EvmcAddress = extern struct { bytes: [20]u8 };

pub const EvmcCallKind = enum(c_int) {
    call = 0,
    delegatecall = 1,
    callcode = 2,
    create = 3,
    create2 = 4,
    eofcreate = 5,
};

pub const EvmcStatusCode = enum(c_int) {
    success = 0,
    failure = 1,
    revert = 2,
    out_of_gas = 3,
    invalid_instruction = 4,
    undefined_instruction = 5,
    stack_overflow = 6,
    stack_underflow = 7,
    bad_jump_destination = 8,
    invalid_memory_access = 9,
    call_depth_exceeded = 10,
    static_mode_violation = 11,
    precompile_failure = 12,
    contract_validation_failure = 13,
    argument_out_of_range = 14,
    wasm_unreachable_instruction = 15,
    wasm_trap = 16,
    insufficient_balance = 17,
    internal_error = -1,
    rejected = -2,
    out_of_memory = -3,
};

pub const EvmcRevision = enum(c_int) {
    frontier = 0,
    homestead = 1,
    tangerine_whistle = 2,
    spurious_dragon = 3,
    byzantium = 4,
    constantinople = 5,
    petersburg = 6,
    istanbul = 7,
    berlin = 8,
    london = 9,
    paris = 10,
    shanghai = 11,
    cancun = 12,
    prague = 13,
    osaka = 14,
};

pub const EvmcSetOptionResult = enum(c_int) {
    success = 0,
    invalid_name = 1,
    invalid_value = 2,
};

pub const EvmcStorageStatus = enum(c_int) {
    assigned = 0,
    added = 1,
    deleted = 2,
    modified = 3,
    deleted_added = 4,
    modified_deleted = 5,
    deleted_restored = 6,
    added_deleted = 7,
    modified_restored = 8,
};

pub const EvmcAccessStatus = enum(c_int) {
    cold = 0,
    warm = 1,
};

pub const EvmcMessage = extern struct {
    kind: EvmcCallKind,
    flags: u32,
    depth: i32,
    gas: i64,
    recipient: EvmcAddress,
    sender: EvmcAddress,
    input_data: ?[*]const u8,
    input_size: usize,
    value: EvmcBytes32,
    create2_salt: EvmcBytes32,
    code_address: EvmcAddress,
    code: ?[*]const u8,
    code_size: usize,
};

pub const EvmcTxContext = extern struct {
    tx_gas_price: EvmcBytes32,
    tx_origin: EvmcAddress,
    block_coinbase: EvmcAddress,
    block_number: i64,
    block_timestamp: i64,
    block_gas_limit: i64,
    block_prev_randao: EvmcBytes32,
    chain_id: EvmcBytes32,
    block_base_fee: EvmcBytes32,
    blob_base_fee: EvmcBytes32,
    blob_hashes: ?[*]const EvmcBytes32,
    blob_hashes_count: usize,
    initcodes: ?[*]const EvmcBytes32,
    initcodes_count: usize,
};

pub const EvmcHostContext = opaque {};
pub const EvmcReleaseResultFn = *const fn (*const EvmcResult) callconv(.c) void;

pub const EvmcResult = extern struct {
    status_code: EvmcStatusCode,
    gas_left: i64,
    gas_refund: i64,
    output_data: ?[*]const u8,
    output_size: usize,
    release: ?EvmcReleaseResultFn,
    create_address: EvmcAddress,
    padding: [4]u8 = .{ 0, 0, 0, 0 },
};

pub const EvmcHostInterface = extern struct {
    account_exists: *const fn (?*EvmcHostContext, *const EvmcAddress) callconv(.c) bool,
    get_storage: *const fn (
        ?*EvmcHostContext,
        *const EvmcAddress,
        *const EvmcBytes32,
    ) callconv(.c) EvmcBytes32,
    set_storage: *const fn (
        ?*EvmcHostContext,
        *const EvmcAddress,
        *const EvmcBytes32,
        *const EvmcBytes32,
    ) callconv(.c) EvmcStorageStatus,
    get_balance: *const fn (?*EvmcHostContext, *const EvmcAddress) callconv(.c) EvmcBytes32,
    get_code_size: *const fn (?*EvmcHostContext, *const EvmcAddress) callconv(.c) usize,
    get_code_hash: *const fn (?*EvmcHostContext, *const EvmcAddress) callconv(.c) EvmcBytes32,
    copy_code: *const fn (?*EvmcHostContext, *const EvmcAddress, usize, [*]u8, usize) callconv(.c) usize,
    selfdestruct: *const fn (?*EvmcHostContext, *const EvmcAddress, *const EvmcAddress) callconv(.c) bool,
    call: *const fn (?*EvmcHostContext, *const EvmcMessage) callconv(.c) EvmcResult,
    get_tx_context: *const fn (?*EvmcHostContext) callconv(.c) EvmcTxContext,
    get_block_hash: *const fn (?*EvmcHostContext, i64) callconv(.c) EvmcBytes32,
    emit_log: *const fn (
        ?*EvmcHostContext,
        *const EvmcAddress,
        ?[*]const u8,
        usize,
        ?[*]const EvmcBytes32,
        usize,
    ) callconv(.c) void,
    access_account: *const fn (?*EvmcHostContext, *const EvmcAddress) callconv(.c) EvmcAccessStatus,
    access_storage: *const fn (
        ?*EvmcHostContext,
        *const EvmcAddress,
        *const EvmcBytes32,
    ) callconv(.c) EvmcAccessStatus,
    get_transient_storage: *const fn (
        ?*EvmcHostContext,
        *const EvmcAddress,
        *const EvmcBytes32,
    ) callconv(.c) EvmcBytes32,
    set_transient_storage: *const fn (
        ?*EvmcHostContext,
        *const EvmcAddress,
        *const EvmcBytes32,
        *const EvmcBytes32,
    ) callconv(.c) void,
};

pub const EvmcVm = extern struct {
    abi_version: c_int,
    name: [*:0]const u8,
    version: [*:0]const u8,
    destroy: *const fn (*EvmcVm) callconv(.c) void,
    execute: *const fn (
        *EvmcVm,
        ?*const EvmcHostInterface,
        ?*EvmcHostContext,
        EvmcRevision,
        *const EvmcMessage,
        ?[*]const u8,
        usize,
    ) callconv(.c) EvmcResult,
    get_capabilities: *const fn (*EvmcVm) callconv(.c) u32,
    set_option: ?*const fn (*EvmcVm, [*:0]const u8, [*:0]const u8) callconv(.c) EvmcSetOptionResult,
};

test "EVMC ABI v12 struct sizes match C specification" {
    try std.testing.expectEqual(@as(usize, 20), @sizeOf(EvmcAddress));
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(EvmcBytes32));
    try std.testing.expectEqual(@as(c_int, 12), EVMC_ABI_VERSION);
    try std.testing.expectEqual(@as(c_int, 14), @backingInt(EvmcRevision.osaka));
}
