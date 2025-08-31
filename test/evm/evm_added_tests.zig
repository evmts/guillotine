const std = @import("std");
const evm_mod = @import("evm.zig");
const primitives = @import("primitives");
const ZERO_ADDRESS = primitives.ZERO_ADDRESS;
const Address = primitives.Address.Address;
const DatabaseInterface = @import("database_interface.zig").DatabaseInterface;
const Account = @import("database_interface_account.zig").Account;
const MemoryDatabase = @import("memory_database.zig").MemoryDatabase;
const BlockInfo = @import("block_info.zig").DefaultBlockInfo;
const TransactionContext = @import("transaction_context.zig").TransactionContext;
const Precompiles = @import("precompiles.zig");

const DefaultEvm = evm_mod.DefaultEvm;

fn setup_evm(allocator: std.mem.Allocator) !struct {
    evm: DefaultEvm,
    db: *MemoryDatabase,
} {
    var memory_db = MemoryDatabase.init(allocator);
    errdefer memory_db.deinit();
    const db_interface = DatabaseInterface.init(&memory_db);

    const block_info = BlockInfo{
        .chain_id = 1,
        .number = 1,
        .timestamp = 1000,
        .difficulty = 0,
        .gas_limit = 30_000_000,
        .coinbase = ZERO_ADDRESS,
        .base_fee = 0,
        .prev_randao = [_]u8{0} ** 32,
    };
    const tx_context = TransactionContext{
        .gas_limit = 1_000_000,
        .coinbase = ZERO_ADDRESS,
        .chain_id = 1,
    };
    var instance = try DefaultEvm.init(allocator, db_interface, block_info, tx_context, 0, ZERO_ADDRESS, .CANCUN);

    return .{ .evm = instance, .db = &memory_db };
}

fn teardown_evm(ctx: *struct { evm: DefaultEvm, db: *MemoryDatabase }) void {
    ctx.evm.deinit();
    ctx.db.deinit();
}

test "CALL to precompile with value transfers balance" {
    const allocator = std.testing.allocator;
    var ctx = try setup_evm(allocator);
    defer teardown_evm(&ctx);

    const caller: Address = [_]u8{0xAA} ++ [_]u8{0} ** 19;
    const precompile_addr = Precompiles.IDENTITY_ADDRESS; // 0x04

    // Fund caller account
    try ctx.db.set_account(caller, Account{
        .balance = 10_000,
        .nonce = 0,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
    });

    const params = DefaultEvm.CallParams{ .call = .{
        .caller = caller,
        .to = precompile_addr,
        .value = 1234,
        .input = &.{},
        .gas = 100_000,
    } };

    const snapshot_id = ctx.evm.create_snapshot();
    const result = try ctx.evm.inner_call(params);
    try std.testing.expect(result.success);

    // Balances should be moved from caller to precompile address
    const caller_acc = (try ctx.db.get_account(caller)).?;
    const pc_acc = (try ctx.db.get_account(precompile_addr)) orelse Account{
        .balance = 0,
        .nonce = 0,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
    };
    try std.testing.expectEqual(@as(u256, 10_000 - 1234), caller_acc.balance);
    try std.testing.expectEqual(@as(u256, 1234), pc_acc.balance);

    // Revert snapshot to ensure journaling can roll back balance changes
    ctx.evm.revert_to_snapshot(snapshot_id);
    const caller_after = (try ctx.db.get_account(caller)).?;
    const pc_after = try ctx.db.get_account(precompile_addr);
    try std.testing.expectEqual(@as(u256, 10_000), caller_after.balance);
    try std.testing.expect(pc_after == null or pc_after.?.balance == 0);
}

test "CALL to precompile failure reverts value transfer" {
    const allocator = std.testing.allocator;
    var ctx = try setup_evm(allocator);
    defer teardown_evm(&ctx);

    const caller: Address = [_]u8{0xBB} ++ [_]u8{0} ** 19;
    const blake2f_addr = Precompiles.BLAKE2F_ADDRESS; // 0x09

    try ctx.db.set_account(caller, Account{
        .balance = 5_000,
        .nonce = 0,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
    });

    // Invalid length input for blake2f (must be 213 bytes)
    var bad_input: [10]u8 = [_]u8{0} ** 10;

    const params = DefaultEvm.CallParams{ .call = .{
        .caller = caller,
        .to = blake2f_addr,
        .value = 777,
        .input = &bad_input,
        .gas = 100_000,
    } };

    const snapshot_id = ctx.evm.create_snapshot();
    const result = try ctx.evm.inner_call(params);
    try std.testing.expect(!result.success);

    // Value transfer should be reverted due to failure
    const caller_acc = (try ctx.db.get_account(caller)).?;
    try std.testing.expectEqual(@as(u256, 5_000), caller_acc.balance);
    const pc = try ctx.db.get_account(blake2f_addr);
    try std.testing.expect(pc == null);

    // Also reverting snapshot should keep original state
    ctx.evm.revert_to_snapshot(snapshot_id);
    const caller_after = (try ctx.db.get_account(caller)).?;
    try std.testing.expectEqual(@as(u256, 5_000), caller_after.balance);
}

test "CALL to empty code transfers value and succeeds" {
    const allocator = std.testing.allocator;
    var ctx = try setup_evm(allocator);
    defer teardown_evm(&ctx);

    const caller: Address = [_]u8{0xCC} ++ [_]u8{0} ** 19;
    const target: Address = [_]u8{0xDD} ++ [_]u8{0} ** 19;

    try ctx.db.set_account(caller, Account{
        .balance = 42_000,
        .nonce = 0,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
    });

    const params = DefaultEvm.CallParams{ .call = .{
        .caller = caller,
        .to = target,
        .value = 3000,
        .input = &.{},
        .gas = 50_000,
    } };

    const res = try ctx.evm.inner_call(params);
    try std.testing.expect(res.success);
    const caller_acc = (try ctx.db.get_account(caller)).?;
    const target_acc = (try ctx.db.get_account(target)).?;
    try std.testing.expectEqual(@as(u256, 42_000 - 3000), caller_acc.balance);
    try std.testing.expectEqual(@as(u256, 3000), target_acc.balance);
}

test "staticcall to precompile updates return_data" {
    const allocator = std.testing.allocator;
    var ctx = try setup_evm(allocator);
    defer teardown_evm(&ctx);

    const caller: Address = [_]u8{0xEE} ++ [_]u8{0} ** 19;
    const identity_addr = Precompiles.IDENTITY_ADDRESS; // 0x04

    // No need to precreate accounts for staticcall
    const input = "hello";
    const params = DefaultEvm.CallParams{ .staticcall = .{
        .caller = caller,
        .to = identity_addr,
        .input = input,
        .gas = 100_000,
    } };

    const result = try ctx.evm.inner_call(params);
    try std.testing.expect(result.success);
    try std.testing.expectEqualSlices(u8, input, result.output);
    // Return data buffer should reflect the output due to inner_call propagation
    try std.testing.expectEqualSlices(u8, input, ctx.evm.get_return_data());
}

test "transfer_value journaling reverts correctly" {
    const allocator = std.testing.allocator;
    var ctx = try setup_evm(allocator);
    defer teardown_evm(&ctx);

    const a: Address = [_]u8{0x01} ++ [_]u8{0} ** 19;
    const b: Address = [_]u8{0x02} ++ [_]u8{0} ** 19;
    try ctx.db.set_account(a, Account{ .balance = 1000, .nonce = 0, .code_hash = [_]u8{0} ** 32, .storage_root = [_]u8{0} ** 32 });
    try ctx.db.set_account(b, Account{ .balance = 50, .nonce = 0, .code_hash = [_]u8{0} ** 32, .storage_root = [_]u8{0} ** 32 });

    // Create a snapshot and bind it to EVM
    const snap = ctx.evm.create_snapshot();
    ctx.evm.current_snapshot_id = snap;

    try ctx.evm.transfer_value(a, b, 200);
    var a_acc = (try ctx.db.get_account(a)).?;
    var b_acc = (try ctx.db.get_account(b)).?;
    try std.testing.expectEqual(@as(u256, 800), a_acc.balance);
    try std.testing.expectEqual(@as(u256, 250), b_acc.balance);

    // Now revert and verify previous balances restored
    ctx.evm.revert_to_snapshot(snap);
    a_acc = (try ctx.db.get_account(a)).?;
    b_acc = (try ctx.db.get_account(b)).?;
    try std.testing.expectEqual(@as(u256, 1000), a_acc.balance);
    try std.testing.expectEqual(@as(u256, 50), b_acc.balance);
}

