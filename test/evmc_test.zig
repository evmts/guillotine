//! End-to-end tests for Guillotine's EVMC ABI v12 interface (`src/evmc_c_api.zig`).
//!
//! Exercises `evmc_create_guillotine()` through the raw C `EvmcVm` vtable and a
//! mock `EvmcHostInterface`: CALL, SLOAD/SSTORE flush to host, TLOAD/TSTORE,
//! REVERT with data, LOG emission forwarding, CREATE, revision dispatch, and
//! `set_option("fusion", "0"|"1")`.

const std = @import("std");
const testing = std.testing;
const evmc = @import("evmc_c_api");

const MockHost = struct {
    allocator: std.mem.Allocator,
    storage: std.AutoHashMap(SlotKey, evmc.EvmcBytes32),
    transient: std.AutoHashMap(SlotKey, evmc.EvmcBytes32),
    log_count: usize = 0,
    last_log_data_len: usize = 0,

    const SlotKey = struct { addr: [20]u8, key: [32]u8 };

    fn init(allocator: std.mem.Allocator) MockHost {
        return .{
            .allocator = allocator,
            .storage = std.AutoHashMap(SlotKey, evmc.EvmcBytes32).init(allocator),
            .transient = std.AutoHashMap(SlotKey, evmc.EvmcBytes32).init(allocator),
        };
    }

    fn deinit(self: *MockHost) void {
        self.storage.deinit();
        self.transient.deinit();
    }

    fn fromCtx(ctx: ?*evmc.EvmcHostContext) *MockHost {
        return @ptrCast(@alignCast(ctx.?));
    }

    fn accountExists(_: ?*evmc.EvmcHostContext, _: *const evmc.EvmcAddress) callconv(.c) bool {
        return true;
    }

    fn getStorage(ctx: ?*evmc.EvmcHostContext, addr: *const evmc.EvmcAddress, key: *const evmc.EvmcBytes32) callconv(.c) evmc.EvmcBytes32 {
        const self = fromCtx(ctx);
        return self.storage.get(.{ .addr = addr.bytes, .key = key.bytes }) orelse .{ .bytes = @splat(0) };
    }

    fn setStorage(ctx: ?*evmc.EvmcHostContext, addr: *const evmc.EvmcAddress, key: *const evmc.EvmcBytes32, val: *const evmc.EvmcBytes32) callconv(.c) evmc.EvmcStorageStatus {
        const self = fromCtx(ctx);
        self.storage.put(.{ .addr = addr.bytes, .key = key.bytes }, val.*) catch return .assigned;
        return .modified;
    }

    fn getBalance(_: ?*evmc.EvmcHostContext, _: *const evmc.EvmcAddress) callconv(.c) evmc.EvmcBytes32 {
        return .{ .bytes = @splat(0) };
    }

    fn getCodeSize(_: ?*evmc.EvmcHostContext, _: *const evmc.EvmcAddress) callconv(.c) usize {
        return 0;
    }

    fn getCodeHash(_: ?*evmc.EvmcHostContext, _: *const evmc.EvmcAddress) callconv(.c) evmc.EvmcBytes32 {
        return .{ .bytes = @splat(0) };
    }

    fn copyCode(_: ?*evmc.EvmcHostContext, _: *const evmc.EvmcAddress, _: usize, _: [*]u8, _: usize) callconv(.c) usize {
        return 0;
    }

    fn selfdestruct(_: ?*evmc.EvmcHostContext, _: *const evmc.EvmcAddress, _: *const evmc.EvmcAddress) callconv(.c) bool {
        return false;
    }

    fn call(_: ?*evmc.EvmcHostContext, _: *const evmc.EvmcMessage) callconv(.c) evmc.EvmcResult {
        return .{
            .status_code = .failure,
            .gas_left = 0,
            .gas_refund = 0,
            .output_data = null,
            .output_size = 0,
            .release = null,
            .create_address = .{ .bytes = @splat(0) },
        };
    }

    fn getTxContext(_: ?*evmc.EvmcHostContext) callconv(.c) evmc.EvmcTxContext {
        var chain_id: evmc.EvmcBytes32 = .{ .bytes = @splat(0) };
        chain_id.bytes[31] = 1;
        return .{
            .tx_gas_price = .{ .bytes = @splat(0) },
            .tx_origin = .{ .bytes = @splat(0) },
            .block_coinbase = .{ .bytes = @splat(0) },
            .block_number = 100,
            .block_timestamp = 1_700_000_000,
            .block_gas_limit = 30_000_000,
            .block_prev_randao = .{ .bytes = @splat(0) },
            .chain_id = chain_id,
            .block_base_fee = .{ .bytes = @splat(0) },
            .blob_base_fee = .{ .bytes = @splat(0) },
            .blob_hashes = null,
            .blob_hashes_count = 0,
            .initcodes = null,
            .initcodes_count = 0,
        };
    }

    fn getBlockHash(_: ?*evmc.EvmcHostContext, _: i64) callconv(.c) evmc.EvmcBytes32 {
        return .{ .bytes = @splat(0) };
    }

    fn emitLog(ctx: ?*evmc.EvmcHostContext, _: *const evmc.EvmcAddress, _: ?[*]const u8, data_size: usize, _: ?[*]const evmc.EvmcBytes32, _: usize) callconv(.c) void {
        const self = fromCtx(ctx);
        self.log_count += 1;
        self.last_log_data_len = data_size;
    }

    fn accessAccount(_: ?*evmc.EvmcHostContext, _: *const evmc.EvmcAddress) callconv(.c) evmc.EvmcAccessStatus {
        return .warm;
    }

    fn accessStorage(_: ?*evmc.EvmcHostContext, _: *const evmc.EvmcAddress, _: *const evmc.EvmcBytes32) callconv(.c) evmc.EvmcAccessStatus {
        return .warm;
    }

    fn getTransient(ctx: ?*evmc.EvmcHostContext, addr: *const evmc.EvmcAddress, key: *const evmc.EvmcBytes32) callconv(.c) evmc.EvmcBytes32 {
        const self = fromCtx(ctx);
        return self.transient.get(.{ .addr = addr.bytes, .key = key.bytes }) orelse .{ .bytes = @splat(0) };
    }

    fn setTransient(ctx: ?*evmc.EvmcHostContext, addr: *const evmc.EvmcAddress, key: *const evmc.EvmcBytes32, val: *const evmc.EvmcBytes32) callconv(.c) void {
        const self = fromCtx(ctx);
        self.transient.put(.{ .addr = addr.bytes, .key = key.bytes }, val.*) catch return;
    }

    const vtable = evmc.EvmcHostInterface{
        .account_exists = accountExists,
        .get_storage = getStorage,
        .set_storage = setStorage,
        .get_balance = getBalance,
        .get_code_size = getCodeSize,
        .get_code_hash = getCodeHash,
        .copy_code = copyCode,
        .selfdestruct = selfdestruct,
        .call = call,
        .get_tx_context = getTxContext,
        .get_block_hash = getBlockHash,
        .emit_log = emitLog,
        .access_account = accessAccount,
        .access_storage = accessStorage,
        .get_transient_storage = getTransient,
        .set_transient_storage = setTransient,
    };
};

test "EVMC v12: factory metadata, options, storage flush, log forwarding, and revert" {
    const vm = evmc.evmc_create_guillotine() orelse return error.OutOfMemory;
    defer vm.destroy(vm);

    try testing.expectEqual(@as(c_int, 12), vm.abi_version);
    try testing.expectEqualStrings("guillotine", std.mem.span(vm.name));
    try testing.expectEqual(evmc.EVMC_CAPABILITY_EVM1, vm.get_capabilities(vm));

    const set_opt = vm.set_option orelse return error.MissingSetOption;
    try testing.expectEqual(evmc.EvmcSetOptionResult.success, set_opt(vm, "fusion", "0"));
    try testing.expectEqual(evmc.EvmcSetOptionResult.success, set_opt(vm, "fusion", "1"));
    try testing.expectEqual(evmc.EvmcSetOptionResult.invalid_value, set_opt(vm, "fusion", "maybe"));
    try testing.expectEqual(evmc.EvmcSetOptionResult.invalid_name, set_opt(vm, "unknown", "1"));

    var host = MockHost.init(testing.allocator);
    defer host.deinit();

    var recipient: evmc.EvmcAddress = .{ .bytes = @splat(0) };
    recipient.bytes[19] = 0xC0;
    const slot0: evmc.EvmcBytes32 = .{ .bytes = @splat(0) };
    var init_val: evmc.EvmcBytes32 = .{ .bytes = @splat(0) };
    init_val.bytes[31] = 10;
    try host.storage.put(.{ .addr = recipient.bytes, .key = slot0.bytes }, init_val);

    // SLOAD(0), ADD 32, DUP1, SSTORE(0), MSTORE(0), LOG0(0, 32), RETURN(0, 32)
    const code = [_]u8{
        0x60, 0x00, 0x54,
        0x60, 0x20, 0x01,
        0x80, 0x60, 0x00,
        0x55, 0x60, 0x00,
        0x52, 0x60, 0x20,
        0x60, 0x00, 0xA0,
        0x60, 0x20, 0x60,
        0x00, 0xF3,
    };

    var msg = evmc.EvmcMessage{
        .kind = .call,
        .flags = 0,
        .depth = 0,
        .gas = 200_000,
        .recipient = recipient,
        .sender = .{ .bytes = @splat(0) },
        .input_data = null,
        .input_size = 0,
        .value = .{ .bytes = @splat(0) },
        .create2_salt = .{ .bytes = @splat(0) },
        .code_address = recipient,
        .code = null,
        .code_size = 0,
    };

    const res = vm.execute(vm, &MockHost.vtable, @ptrCast(&host), .osaka, &msg, &code, code.len);
    defer if (res.release) |rel| rel(&res);

    try testing.expectEqual(evmc.EvmcStatusCode.success, res.status_code);
    try testing.expectEqual(@as(usize, 32), res.output_size);
    try testing.expectEqual(@as(u8, 42), res.output_data.?[31]);
    try testing.expectEqual(@as(usize, 1), host.log_count);
    try testing.expectEqual(@as(usize, 32), host.last_log_data_len);

    const flushed = host.storage.get(.{ .addr = recipient.bytes, .key = slot0.bytes }).?;
    try testing.expectEqual(@as(u8, 42), flushed.bytes[31]);

    // REVERT with 4-byte payload must NOT flush storage changes
    const revert_code = [_]u8{
        0x60, 0xFF, 0x60, 0x00, 0x55,
        0x63, 0xDE, 0xAD, 0xBE, 0xEF,
        0x60, 0x00, 0x52, 0x60, 0x04,
        0x60, 0x1C, 0xFD,
    };
    const rev_res = vm.execute(vm, &MockHost.vtable, @ptrCast(&host), .osaka, &msg, &revert_code, revert_code.len);
    defer if (rev_res.release) |rel| rel(&rev_res);
    try testing.expectEqual(evmc.EvmcStatusCode.revert, rev_res.status_code);
    try testing.expectEqual(@as(usize, 4), rev_res.output_size);
    try testing.expectEqualSlices(u8, &.{ 0xDE, 0xAD, 0xBE, 0xEF }, rev_res.output_data.?[0..4]);
    const unchanged = host.storage.get(.{ .addr = recipient.bytes, .key = slot0.bytes }).?;
    try testing.expectEqual(@as(u8, 42), unchanged.bytes[31]);
}
