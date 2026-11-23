const std = @import("std");
const evm = @import("evm");
const primitives = @import("voltaire");

const MinimalEvm = evm.MinimalEvm;
const Address = primitives.Address.Address;
const testing = std.testing;

const TestResult = struct {
    success: bool,
    gas_used: u64,
    output: []u8,
};

fn hexToBytes(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var count: usize = 0;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        const c = raw[i];
        if (c == '0' and i + 1 < raw.len and (raw[i + 1] == 'x' or raw[i + 1] == 'X')) {
            i += 1;
            continue;
        }
        if (std.ascii.isWhitespace(c)) continue;
        count += 1;
    }
    if (count == 0) return try allocator.alloc(u8, 0);
    if (count % 2 != 0) return error.OddNumberOfDigits;

    const result = try allocator.alloc(u8, count / 2);
    errdefer allocator.free(result);

    var out_idx: usize = 0;
    var hi: ?u8 = null;
    i = 0;
    while (i < raw.len) : (i += 1) {
        const c = raw[i];
        if (c == '0' and i + 1 < raw.len and (raw[i + 1] == 'x' or raw[i + 1] == 'X')) {
            i += 1;
            continue;
        }
        if (std.ascii.isWhitespace(c)) continue;
        const digit = try std.fmt.charToDigit(c, 16);
        if (hi == null) {
            hi = digit;
        } else {
            result[out_idx] = (hi.? << 4) | digit;
            out_idx += 1;
            hi = null;
        }
    }
    return result;
}

fn loadFixtureFile(allocator: std.mem.Allocator, fixture_name: []const u8, file_name: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(allocator, "fixtures/{s}/{s}", .{ fixture_name, file_name });
    defer allocator.free(path);
    const hex_text = try std.fs.cwd().readFileAlloc(allocator, path, 4 * 1024 * 1024);
    defer allocator.free(hex_text);
    return try hexToBytes(allocator, hex_text);
}

fn verifyBytecodeAndDispatch(allocator: std.mem.Allocator, bytecode: []const u8) !void {
    const BytecodeDefault = evm.Bytecode(evm.BytecodeConfig{});
    var bytecode_obj = try BytecodeDefault.init(allocator, bytecode);
    defer bytecode_obj.deinit();

    const FrameType = evm.MainnetEvm.Frame;
    const opcode_handlers = FrameType.opcode_handlers;
    const Dispatch = evm.dispatch.Preprocessor(FrameType);
    var schedule = try Dispatch.init(allocator, bytecode_obj, &opcode_handlers, null);
    defer schedule.deinit();

    try testing.expect(schedule.items.len > 0);
}

/// Runs a runtime-bytecode fixture from `fixtures/<name>/{bytecode.txt,calldata.txt}`
/// on both `MainnetEvm` and `MinimalEvm` and checks that execution succeeds identically.
fn runRuntimeFixture(fixture_name: []const u8, gas_limit: u64) !void {
    const allocator = testing.allocator;

    const bytecode = try loadFixtureFile(allocator, fixture_name, "bytecode.txt");
    defer allocator.free(bytecode);
    try testing.expect(bytecode.len > 0);

    const calldata = try loadFixtureFile(allocator, fixture_name, "calldata.txt");
    defer allocator.free(calldata);

    try verifyBytecodeAndDispatch(allocator, bytecode);

    const sender = try Address.fromBytes(&([_]u8{0} ** 19 ++ [_]u8{0x01}));
    const contract = try Address.fromBytes(&([_]u8{0} ** 19 ++ [_]u8{0x42}));

    const main_result: TestResult = blk: {
        var database = evm.Database.init(allocator);
        defer database.deinit();

        try database.set_account(sender.bytes, .{
            .balance = 100_000_000_000_000_000_000,
            .code_hash = [_]u8{0} ** 32,
            .storage_root = [_]u8{0} ** 32,
            .nonce = 0,
            .delegated_address = null,
        });

        const code_hash = try database.set_code(bytecode);
        try database.set_account(contract.bytes, .{
            .balance = 0,
            .code_hash = code_hash,
            .storage_root = [_]u8{0} ** 32,
            .nonce = 1,
            .delegated_address = null,
        });

        var main_evm = try evm.MainnetEvm.init(
            allocator,
            &database,
            .{
                .number = 1,
                .timestamp = 1000000,
                .gas_limit = 30_000_000,
                .coinbase = primitives.ZERO_ADDRESS,
                .base_fee = 1_000_000_000,
                .chain_id = 1,
                .difficulty = 0,
                .prev_randao = [_]u8{0} ** 32,
                .blob_base_fee = 0,
                .blob_versioned_hashes = &.{},
            },
            .{
                .gas_limit = gas_limit,
                .coinbase = primitives.ZERO_ADDRESS,
                .chain_id = 1,
                .blob_versioned_hashes = &.{},
                .blob_base_fee = 0,
            },
            1_000_000_000,
            sender,
        );
        defer main_evm.deinit();

        var result = main_evm.simulate(.{
            .call = .{
                .caller = sender,
                .to = contract,
                .value = 0,
                .input = calldata,
                .gas = gas_limit,
            },
        });
        defer result.deinit(allocator);

        break :blk .{
            .success = result.success,
            .gas_used = gas_limit - result.gas_left,
            .output = try allocator.dupe(u8, result.output),
        };
    };
    defer allocator.free(main_result.output);

    const minimal_result: TestResult = blk: {
        const min_evm = try MinimalEvm.initPtr(allocator);
        defer min_evm.deinitPtr(allocator);

        min_evm.setBlockchainContext(1, 1, 1000000, 0, 0, primitives.ZERO_ADDRESS, 30_000_000, 1_000_000_000, 0);
        min_evm.setTransactionContext(sender, 1_000_000_000);
        try min_evm.setBalance(sender, 100_000_000_000_000_000_000);
        try min_evm.setCode(contract, bytecode);
        try min_evm.setNonce(contract, 1);

        const result = try min_evm.execute(
            bytecode,
            @intCast(gas_limit),
            sender,
            contract,
            0,
            calldata,
        );

        break :blk .{
            .success = result.success,
            .gas_used = gas_limit - result.gas_left,
            .output = try allocator.dupe(u8, result.output),
        };
    };
    defer allocator.free(minimal_result.output);

    try testing.expectEqual(minimal_result.success, main_result.success);
    try testing.expectEqualSlices(u8, minimal_result.output, main_result.output);
}

/// Deploys an initcode fixture via `CREATE` and invokes its benchmark entrypoint
/// with `fixtures/<name>/calldata.txt`.
fn runDeployAndCallFixture(comptime EvmType: type, fixture_name: []const u8, gas_limit: u64) !void {
    const allocator = testing.allocator;

    const initcode = try loadFixtureFile(allocator, fixture_name, "bytecode.txt");
    defer allocator.free(initcode);
    try testing.expect(initcode.len > 0);

    const calldata = try loadFixtureFile(allocator, fixture_name, "calldata.txt");
    defer allocator.free(calldata);

    try verifyBytecodeAndDispatch(allocator, initcode);

    const sender = try Address.fromBytes(&([_]u8{0} ** 19 ++ [_]u8{0x01}));

    var database = evm.Database.init(allocator);
    defer database.deinit();

    try database.set_account(sender.bytes, .{
        .balance = 100_000_000_000_000_000_000,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
        .nonce = 0,
        .delegated_address = null,
    });

    var instance = try EvmType.init(
        allocator,
        &database,
        .{
            .number = 1,
            .timestamp = 1000000,
            .gas_limit = gas_limit,
            .coinbase = primitives.ZERO_ADDRESS,
            .base_fee = 1_000_000_000,
            .chain_id = 1,
            .difficulty = 0,
            .prev_randao = [_]u8{0} ** 32,
            .blob_base_fee = 0,
            .blob_versioned_hashes = &.{},
        },
        .{
            .gas_limit = gas_limit,
            .coinbase = primitives.ZERO_ADDRESS,
            .chain_id = 1,
            .blob_versioned_hashes = &.{},
            .blob_base_fee = 0,
        },
        1_000_000_000,
        sender,
    );
    defer instance.deinit();

    var deploy_res = instance.call(.{
        .create = .{
            .caller = sender,
            .value = 0,
            .init_code = initcode,
            .gas = gas_limit,
        },
    });
    defer deploy_res.deinit(allocator);
    try testing.expect(deploy_res.success);
    const deployed_addr = deploy_res.created_address orelse return error.MissingCreatedAddress;

    var call_res = instance.call(.{
        .call = .{
            .caller = sender,
            .to = deployed_addr,
            .value = 0,
            .input = calldata,
            .gas = gas_limit,
        },
    });
    defer call_res.deinit(allocator);
    try testing.expect(call_res.success);
}

test "fixture: opcodes-arithmetic" {
    try runRuntimeFixture("opcodes-arithmetic", 1_000_000);
}

test "fixture: opcodes-arithmetic-advanced" {
    try runRuntimeFixture("opcodes-arithmetic-advanced", 1_000_000);
}

test "fixture: opcodes-bitwise" {
    try runRuntimeFixture("opcodes-bitwise", 1_000_000);
}

test "fixture: opcodes-comparison" {
    try runRuntimeFixture("opcodes-comparison", 1_000_000);
}

test "fixture: opcodes-context" {
    try runRuntimeFixture("opcodes-context", 1_000_000);
}

test "fixture: opcodes-crypto" {
    try runRuntimeFixture("opcodes-crypto", 5_000_000);
}

test "fixture: opcodes-data" {
    try runRuntimeFixture("opcodes-data", 5_000_000);
}

test "fixture: opcodes-dup" {
    try runRuntimeFixture("opcodes-dup", 1_000_000);
}

test "fixture: opcodes-jump-basic" {
    try runRuntimeFixture("opcodes-jump-basic", 1_000_000);
}

test "fixture: opcodes-log" {
    try runRuntimeFixture("opcodes-log", 1_000_000);
}

test "fixture: opcodes-memory" {
    try runRuntimeFixture("opcodes-memory", 1_000_000);
}

test "fixture: opcodes-push-pop" {
    try runRuntimeFixture("opcodes-push-pop", 1_000_000);
}

test "fixture: opcodes-storage-cold" {
    try runRuntimeFixture("opcodes-storage-cold", 1_000_000);
}

test "fixture: opcodes-storage-warm" {
    try runRuntimeFixture("opcodes-storage-warm", 1_000_000);
}

test "fixture: opcodes-swap" {
    try runRuntimeFixture("opcodes-swap", 1_000_000);
}

test "fixture: opcodes-system" {
    try runRuntimeFixture("opcodes-system", 1_000_000);
}

test "fixture: ten-thousand-hashes" {
    try runDeployAndCallFixture(evm.MainnetEvm, "ten-thousand-hashes", 10_000_000);
}

test "fixture: erc20-mint" {
    try runDeployAndCallFixture(evm.MainnetEvm, "erc20-mint", 16_000_000);
}

test "fixture: erc20-transfer" {
    try runDeployAndCallFixture(evm.MainnetEvm, "erc20-transfer", 16_000_000);
}

test "fixture: erc20-approval-transfer" {
    try runDeployAndCallFixture(evm.MainnetEvm, "erc20-approval-transfer", 16_000_000);
}
