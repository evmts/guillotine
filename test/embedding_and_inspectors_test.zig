//! End-to-end integration tests for Guillotine's embedding seams:
//! - Custom `EvmConfig.DatabaseType` (zero-patch downstream integration for ZEVM & custom hosts)
//! - Runtime per-instance `RuntimePrecompileOverride` with opaque context pointer
//! - `tx_runner.executeTx` (EIP-1559 fees, EIP-7623 floor, EIP-7825 cap)
//! - Zero-cost comptime `CallTracer` inspector

const std = @import("std");
const testing = std.testing;
const evm = @import("evm");
const voltaire = @import("voltaire");

const Address = voltaire.Address;
const Account = evm.Account;

/// Minimal custom DatabaseType wrapper proving `EvmConfig.DatabaseType` works
/// natively without string-patching `src/evm.zig` or `src/frame/frame.zig`.
const CustomTrackingDb = struct {
    inner: evm.Database,
    storage_reads: usize = 0,

    pub const Error = evm.Database.Error;

    pub fn init(allocator: std.mem.Allocator) CustomTrackingDb {
        return .{ .inner = evm.Database.init(allocator) };
    }

    pub fn deinit(self: *CustomTrackingDb) void {
        self.inner.deinit();
    }

    pub fn get_account(self: *CustomTrackingDb, address: [20]u8) Error!?Account {
        return self.inner.get_account(address);
    }

    pub fn set_account(self: *CustomTrackingDb, address: [20]u8, account: Account) Error!void {
        return self.inner.set_account(address, account);
    }

    pub fn delete_account(self: *CustomTrackingDb, address: [20]u8) Error!void {
        return self.inner.delete_account(address);
    }

    pub fn account_exists(self: *CustomTrackingDb, address: [20]u8) bool {
        return self.inner.account_exists(address);
    }

    pub fn get_balance(self: *CustomTrackingDb, address: [20]u8) Error!u256 {
        return self.inner.get_balance(address);
    }

    pub fn set_balance(self: *CustomTrackingDb, address: [20]u8, balance: u256) Error!void {
        return self.inner.set_balance(address, balance);
    }

    pub fn get_storage(self: *CustomTrackingDb, address: [20]u8, key: u256) Error!u256 {
        self.storage_reads += 1;
        return self.inner.get_storage(address, key);
    }

    pub fn set_storage(self: *CustomTrackingDb, address: [20]u8, key: u256, value: u256) Error!void {
        return self.inner.set_storage(address, key, value);
    }

    pub fn has_storage(self: *CustomTrackingDb, address: [20]u8) Error!bool {
        return self.inner.has_storage(address);
    }

    pub fn clear_account_storage(self: *CustomTrackingDb, address: [20]u8) Error!void {
        return self.inner.clear_account_storage(address);
    }

    pub fn get_transient_storage(self: *CustomTrackingDb, address: [20]u8, key: u256) Error!u256 {
        return self.inner.get_transient_storage(address, key);
    }

    pub fn set_transient_storage(self: *CustomTrackingDb, address: [20]u8, key: u256, value: u256) Error!void {
        return self.inner.set_transient_storage(address, key, value);
    }

    pub fn clear_transient_storage(self: *CustomTrackingDb) void {
        self.inner.clear_transient_storage();
    }

    pub fn get_code(self: *CustomTrackingDb, code_hash: [32]u8) Error![]const u8 {
        return self.inner.get_code(code_hash);
    }

    pub fn set_code(self: *CustomTrackingDb, code: []const u8) Error![32]u8 {
        return self.inner.set_code(code);
    }

    pub fn create_snapshot(self: *CustomTrackingDb) Error!u64 {
        return self.inner.create_snapshot();
    }

    pub fn revert_to_snapshot(self: *CustomTrackingDb, id: u64) Error!void {
        return self.inner.revert_to_snapshot(id);
    }

    pub fn commit_snapshot(self: *CustomTrackingDb, id: u64) Error!void {
        return self.inner.commit_snapshot(id);
    }

    pub fn snapshot_depth(self: *const CustomTrackingDb) usize {
        return self.inner.snapshot_depth();
    }

    pub fn commit_to_depth(self: *CustomTrackingDb, depth: usize) void {
        self.inner.commit_to_depth(depth);
    }

    pub fn revert_to_depth(self: *CustomTrackingDb, depth: usize) void {
        self.inner.revert_to_depth(depth);
    }
};

test "embedding: custom EvmConfig.DatabaseType works natively including simulate" {
    const allocator = testing.allocator;
    const CustomEvm = evm.Evm(.{ .DatabaseType = CustomTrackingDb });

    var db = CustomTrackingDb.init(allocator);
    defer db.deinit();

    const caller = Address.fromU256(0xA1);
    const target = Address.fromU256(0xC0);
    // PUSH1 0, SLOAD, PUSH1 1, ADD, DUP1, PUSH1 0, SSTORE, PUSH1 0, MSTORE, PUSH1 32, PUSH1 0, RETURN
    const code = [_]u8{
        0x60, 0x00, 0x54, 0x60, 0x01, 0x01, 0x80, 0x60, 0x00, 0x55,
        0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xF3,
    };
    const code_hash = try db.set_code(&code);
    try db.set_account(target.bytes, .{
        .balance = 0,
        .nonce = 1,
        .code_hash = code_hash,
        .storage_root = @splat(0),
    });
    try db.set_storage(target.bytes, 0, 41);

    const blk = evm.BlockInfo{
        .chain_id = 1,
        .number = 1,
        .timestamp = 1_700_000_000,
        .difficulty = 0,
        .gas_limit = 30_000_000,
        .coinbase = voltaire.ZERO_ADDRESS,
        .base_fee = 0,
        .prev_randao = @splat(0),
    };
    const ctx = evm.TransactionContext{ .gas_limit = 200_000, .coinbase = voltaire.ZERO_ADDRESS, .chain_id = 1 };
    var vm = try CustomEvm.init(allocator, &db, blk, ctx, 0, caller);
    defer vm.deinit();

    // simulate() must revert state changes on a custom DatabaseType without ephemeral views.
    var sim = vm.simulate(.{ .call = .{
        .caller = caller,
        .to = target,
        .value = 0,
        .input = &.{},
        .gas = 200_000,
    } });
    defer sim.deinit(allocator);
    try testing.expect(sim.success);
    try testing.expectEqual(@as(u256, 42), std.mem.readInt(u256, sim.output[0..32], .big));
    try testing.expectEqual(@as(u256, 41), try db.inner.get_storage(target.bytes, 0));
    try testing.expect(db.storage_reads > 0);
}

test "embedding: runtime precompile override with context pointer" {
    const allocator = testing.allocator;
    const EvmType = evm.MainnetEvm;
    var db = evm.Database.init(allocator);
    defer db.deinit();

    const Sink = struct {
        seen_len: usize = 0,
        fn exec(ctx_ptr: ?*anyopaque, alloc: std.mem.Allocator, input: []const u8, gas_limit: u64) anyerror!evm.PrecompileOutput {
            if (gas_limit < 100) return .{ .output = &.{}, .gas_used = gas_limit, .success = false };
            const sink: *@This() = @ptrCast(@alignCast(ctx_ptr.?));
            sink.seen_len = input.len;
            const out = try alloc.alloc(u8, 32);
            @memset(out, 0);
            out[31] = @intCast(input.len);
            return .{ .output = out, .gas_used = 100, .success = true };
        }
    };

    var sink = Sink{};
    const custom_addr = Address.fromU256(0x9999);
    const caller = Address.fromU256(0xA1);
    const overrides = [_]evm.RuntimePrecompileOverride{.{
        .address = custom_addr,
        .context = &sink,
        .execute = Sink.exec,
    }};

    const blk = evm.BlockInfo{
        .chain_id = 1,
        .number = 1,
        .timestamp = 1_700_000_000,
        .difficulty = 0,
        .gas_limit = 30_000_000,
        .coinbase = voltaire.ZERO_ADDRESS,
        .base_fee = 0,
        .prev_randao = @splat(0),
    };
    const ctx = evm.TransactionContext{ .gas_limit = 100_000, .coinbase = voltaire.ZERO_ADDRESS, .chain_id = 1 };
    var vm = try EvmType.init(allocator, &db, blk, ctx, 0, caller);
    defer vm.deinit();
    vm.setPrecompileOverrides(&overrides);

    var res = vm.call(.{ .call = .{
        .caller = caller,
        .to = custom_addr,
        .value = 0,
        .input = "hello",
        .gas = 100_000,
    } });
    defer res.deinit(allocator);

    try testing.expect(res.success);
    try testing.expectEqual(@as(usize, 5), sink.seen_len);
    try testing.expectEqual(@as(u8, 5), res.output[31]);
}

test "embedding: tx_runner executes EIP-1559 call and enforces EIP-7825 and EIP-7623" {
    const allocator = testing.allocator;
    const EvmType = evm.MainnetEvm;
    var db = evm.Database.init(allocator);
    defer db.deinit();

    const sender = Address.fromU256(0xA1);
    const target = Address.fromU256(0xC0);
    const coinbase = Address.fromU256(0xCB);

    try db.set_account(sender.bytes, .{
        .balance = 10_000_000_000,
        .nonce = 0,
        .code_hash = @splat(0),
        .storage_root = @splat(0),
    });
    const code = [_]u8{ 0x60, 0x07, 0x60, 0x05, 0x01, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xF3 };
    const code_hash = try db.set_code(&code);
    try db.set_account(target.bytes, .{
        .balance = 0,
        .nonce = 1,
        .code_hash = code_hash,
        .storage_root = @splat(0),
    });

    const blk = evm.BlockInfo{
        .chain_id = 1,
        .number = 100,
        .timestamp = 1_700_000_000,
        .difficulty = 0,
        .gas_limit = 30_000_000,
        .coinbase = coinbase,
        .base_fee = 10,
        .prev_randao = @splat(0),
    };
    const ctx = evm.TransactionContext{ .gas_limit = 100_000, .coinbase = coinbase, .chain_id = 1 };
    var vm = try EvmType.init(allocator, &db, blk, ctx, 15, sender);
    defer vm.deinit();

    var res = try evm.tx_runner.executeTx(EvmType, allocator, &vm, .{
        .tx_type = 2,
        .from = sender,
        .to = target,
        .nonce = 0,
        .gas_limit = 100_000,
        .max_fee_per_gas = 20,
        .max_priority_fee_per_gas = 5,
    });
    defer res.deinit(allocator);

    try testing.expect(res.success);
    try testing.expectEqual(@as(u256, 15), res.effective_gas_price);
    try testing.expectEqual(@as(u256, 12), std.mem.readInt(u256, res.output[0..32], .big));
    try testing.expectEqual(@as(u256, res.gas_used) * 5, (try db.get_account(coinbase.bytes)).?.balance);
    try testing.expectEqual(@as(u64, 1), (try db.get_account(sender.bytes)).?.nonce);

    // EIP-7825 Osaka gas limit cap
    try testing.expectError(error.GasLimitExceedsCap, evm.tx_runner.executeTx(EvmType, allocator, &vm, .{
        .from = sender,
        .to = target,
        .gas_limit = 20_000_000,
        .gas_price = 10,
    }));

    // EIP-7623 calldata floor (100 nonzero bytes => 400 tokens => 25,000 floor)
    const data: [100]u8 = @splat(0xAB);
    var floor_res = try evm.tx_runner.executeTx(EvmType, allocator, &vm, .{
        .from = sender,
        .to = Address.fromU256(0xE0),
        .nonce = 1,
        .gas_limit = 100_000,
        .gas_price = 10,
        .input = &data,
    });
    defer floor_res.deinit(allocator);
    try testing.expect(floor_res.success);
    try testing.expectEqual(@as(u64, 25_000), floor_res.gas_used);
}

test "embedding: CallTracer inspector captures nested STATICCALL tree" {
    const allocator = testing.allocator;
    const InspectedEvm = evm.Evm(.{ .InspectorType = evm.CallTracer });
    var db = evm.Database.init(allocator);
    defer db.deinit();

    const caller = Address.fromU256(0xA1);
    const parent = Address.fromU256(0xC1);
    const child = Address.fromU256(0xC2);

    const child_code = [_]u8{ 0x60, 0x2A, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xF3 };
    const child_hash = try db.set_code(&child_code);
    try db.set_account(child.bytes, .{ .balance = 0, .nonce = 1, .code_hash = child_hash, .storage_root = @splat(0) });

    const parent_code = [_]u8{
        0x60, 0x20, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00,
        0x60, 0xC2, 0x61, 0xC3, 0x50, 0xFA, 0x50, 0x60,
        0x20, 0x60, 0x00, 0xF3,
    };
    const parent_hash = try db.set_code(&parent_code);
    try db.set_account(parent.bytes, .{ .balance = 0, .nonce = 1, .code_hash = parent_hash, .storage_root = @splat(0) });

    const blk = evm.BlockInfo{
        .chain_id = 1,
        .number = 1,
        .timestamp = 1_700_000_000,
        .difficulty = 0,
        .gas_limit = 30_000_000,
        .coinbase = voltaire.ZERO_ADDRESS,
        .base_fee = 0,
        .prev_randao = @splat(0),
    };
    const ctx = evm.TransactionContext{ .gas_limit = 200_000, .coinbase = voltaire.ZERO_ADDRESS, .chain_id = 1 };
    var vm = try InspectedEvm.init(allocator, &db, blk, ctx, 0, caller);
    defer vm.deinit();

    var tracer = evm.CallTracer.init(allocator);
    defer tracer.deinit();
    vm.setInspector(&tracer);

    var res = vm.call(.{ .call = .{
        .caller = caller,
        .to = parent,
        .value = 0,
        .input = &.{},
        .gas = 200_000,
    } });
    defer res.deinit(allocator);

    try testing.expect(res.success);
    try testing.expectEqual(@as(usize, 2), tracer.calls.items.len);
    try testing.expectEqual(evm.inspectors.CallKind.CALL, tracer.calls.items[0].kind);
    try testing.expectEqual(evm.inspectors.CallKind.STATICCALL, tracer.calls.items[1].kind);
    try testing.expectEqual(@as(?usize, 0), tracer.calls.items[1].parent_index);

    const json = try tracer.toJson(allocator);
    defer allocator.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "\"type\":\"STATICCALL\"") != null);
}
