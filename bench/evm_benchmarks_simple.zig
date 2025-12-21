const std = @import("std");
const zbench = @import("zbench");
const evm = @import("evm");
const primitives = @import("voltaire");

const Address = primitives.Address.Address;
const MinimalEvm = evm.MinimalEvm;

const stdout = std.io.getStdOut().writer();

// Fixture structure
const Fixture = struct {
    name: []const u8,
    bytecode: []const u8,
    calldata: []const u8,
    gas_limit: u64,
};

var fixtures: std.ArrayList(Fixture) = undefined;
var allocator_g: std.mem.Allocator = undefined;

fn decodeHex(allocator: std.mem.Allocator, hex_str: []const u8) ![]u8 {
    var str = hex_str;
    if (str.len >= 2 and (std.mem.eql(u8, str[0..2], "0x") or std.mem.eql(u8, str[0..2], "0X"))) {
        str = str[2..];
    }
    if (str.len % 2 != 0) return error.OddNumberOfDigits;

    const result = try allocator.alloc(u8, str.len / 2);
    for (result, 0..) |*byte, i| {
        const high = try std.fmt.charToDigit(str[i * 2], 16);
        const low = try std.fmt.charToDigit(str[i * 2 + 1], 16);
        byte.* = (high << 4) | low;
    }
    return result;
}

fn loadBytecode(allocator: std.mem.Allocator, fixture_name: []const u8) ![]u8 {
    const cache_path = try std.fmt.allocPrint(allocator, "bench/fixtures/cache/{s}.bin", .{fixture_name});
    defer allocator.free(cache_path);

    const bytecode_hex = std.fs.cwd().readFileAlloc(allocator, cache_path, 1_000_000) catch |err| {
        stdout.print("Warning: Could not load bytecode for {s}: {}\n", .{ fixture_name, err }) catch {};
        return try allocator.alloc(u8, 0);
    };
    defer allocator.free(bytecode_hex);

    return try decodeHex(allocator, std.mem.trim(u8, bytecode_hex, " \n\r\t"));
}


fn loadFixtures(allocator: std.mem.Allocator) !void {
    fixtures = std.ArrayList(Fixture){};

    // List of fixtures to load with their configurations
    const fixture_configs = [_]struct {
        name: []const u8,
        calldata: []const u8,
        gas_limit: u64,
    }{
        .{ .name = "snailtracer", .calldata = "30627b7c", .gas_limit = 1000000000 },
        .{ .name = "bubblesort", .calldata = "239b51bf0000000000000000000000000000000000000000000000000000000000000064", .gas_limit = 30000000 },
        .{ .name = "erc20transfer", .calldata = "a9059cbb000000000000000000000000000000000000000000000000000000000000002a0000000000000000000000000000000000000000000000000000000000000064", .gas_limit = 100000 },
        .{ .name = "erc20mint", .calldata = "a0712d680000000000000000000000000000000000000000000000000000000000000064", .gas_limit = 100000 },
        .{ .name = "erc20approval", .calldata = "095ea7b3000000000000000000000000000000000000000000000000000000000000002a0000000000000000000000000000000000000000000000000000000000000064", .gas_limit = 100000 },
        .{ .name = "ten-thousand-hashes", .calldata = "e05f0872", .gas_limit = 30000000 },
        .{ .name = "arithmetic", .calldata = "", .gas_limit = 100000 },
        .{ .name = "bitwise", .calldata = "", .gas_limit = 100000 },
        .{ .name = "comparison", .calldata = "", .gas_limit = 100000 },
        .{ .name = "hashing", .calldata = "", .gas_limit = 100000 },
        .{ .name = "memory", .calldata = "", .gas_limit = 100000 },
        .{ .name = "storage", .calldata = "", .gas_limit = 100000 },
    };

    for (fixture_configs) |config| {
        const bytecode = loadBytecode(allocator, config.name) catch |err| {
            stdout.print("Warning: Could not load {s}: {}\n", .{ config.name, err }) catch {};
            continue;
        };

        if (bytecode.len == 0) {
            stdout.print("Warning: Empty bytecode for {s}\n", .{config.name}) catch {};
            allocator.free(bytecode);
            continue;
        }

        const calldata = if (config.calldata.len > 0)
            decodeHex(allocator, config.calldata) catch try allocator.alloc(u8, 0)
        else
            try allocator.alloc(u8, 0);

        try fixtures.append(allocator, .{
            .name = config.name,
            .bytecode = bytecode,
            .calldata = calldata,
            .gas_limit = config.gas_limit,
        });

        stdout.print("Loaded {s}: {} bytes\n", .{ config.name, bytecode.len }) catch {};
    }
}

fn createMainEvmBenchmark(fixture: Fixture) fn (std.mem.Allocator) void {
    return struct {
        const f = fixture;

        pub fn benchmark(allocator: std.mem.Allocator) void {
            var database = evm.Database.init(allocator);
            defer database.deinit();

            const sender_address = Address.fromBytes(&([_]u8{0} ** 19 ++ [_]u8{0x01})) catch unreachable;
            const contract_address = Address.fromBytes(&([_]u8{0} ** 19 ++ [_]u8{0x42})) catch unreachable;

            // Setup accounts
            const balance: u256 = 100_000_000_000_000_000_000;
            const sender_account = evm.Account{
                .balance = balance,
                .code_hash = [_]u8{0} ** 32,
                .storage_root = [_]u8{0} ** 32,
                .nonce = 0,
                .delegated_address = null,
            };
            database.set_account(sender_address.bytes, sender_account) catch unreachable;

            if (f.bytecode.len > 0) {
                const code_hash = database.set_code(f.bytecode) catch unreachable;
                const contract_account = evm.Account{
                    .balance = 0,
                    .code_hash = code_hash,
                    .storage_root = [_]u8{0} ** 32,
                    .nonce = 0,
                    .delegated_address = null,
                };
                database.set_account(contract_address.bytes, contract_account) catch unreachable;
            }

            const block_info = evm.BlockInfo{
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
            };

            const tx_context = evm.TransactionContext{
                .gas_limit = f.gas_limit,
                .coinbase = primitives.ZERO_ADDRESS,
                .chain_id = 1,
                .blob_versioned_hashes = &.{},
                .blob_base_fee = 0,
            };

            var main_evm = evm.MainnetEvm.init(
                allocator,
                &database,
                block_info,
                tx_context,
                1_000_000_000,
                sender_address,
            ) catch unreachable;
            defer main_evm.deinit();

            const call_params = evm.MainnetEvm.CallParams{
                .call = .{
                    .caller = sender_address,
                    .to = contract_address,
                    .value = 0,
                    .input = f.calldata,
                    .gas = f.gas_limit,
                },
            };

            var result = main_evm.simulate(call_params);
            defer result.deinit(allocator);
        }
    }.benchmark;
}

fn createMinimalEvmBenchmark(fixture: Fixture) fn (std.mem.Allocator) void {
    return struct {
        const f = fixture;

        pub fn benchmark(allocator: std.mem.Allocator) void {
            const sender_address = Address.fromBytes(&([_]u8{0} ** 19 ++ [_]u8{0x01})) catch unreachable;
            const contract_address = Address.fromBytes(&([_]u8{0} ** 19 ++ [_]u8{0x42})) catch unreachable;

            var min_evm = MinimalEvm.init(allocator) catch unreachable;
            defer min_evm.deinit();

            min_evm.setBlockchainContext(
                1, // chain_id
                1, // block_number
                1000000, // timestamp
                0, // difficulty
                0, // prevrandao
                primitives.ZERO_ADDRESS,
                30_000_000, // gas_limit
                1_000_000_000, // base_fee
                0, // blob_base_fee
            );

            min_evm.setTransactionContext(sender_address, 1_000_000_000);

            min_evm.setBalance(sender_address, 100_000_000_000_000_000_000) catch unreachable;
            if (f.bytecode.len > 0) {
                min_evm.setCode(contract_address, f.bytecode) catch unreachable;
            }

            const result = min_evm.execute(
                f.bytecode,
                @intCast(f.gas_limit),
                sender_address,
                contract_address,
                0, // value
                f.calldata,
            ) catch {
                return;
            };
            _ = result;
        }
    }.benchmark;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    allocator_g = allocator;

    try stdout.print("\n=== EVM Fixture Benchmarks ===\n\n", .{});
    try stdout.print("Loading bytecode fixtures...\n", .{});

    // Load all fixtures
    try loadFixtures(allocator);
    defer {
        for (fixtures.items) |f| {
            allocator.free(f.bytecode);
            allocator.free(f.calldata);
        }
        fixtures.deinit(allocator);
    }

    try stdout.print("\nLoaded {} fixtures successfully\n\n", .{fixtures.items.len});

    // Create and run benchmarks
    var bench = zbench.Benchmark.init(allocator, .{
        .time_budget_ns = 1_000_000_000, // 1 second per benchmark
    });
    defer bench.deinit();

    // Add benchmarks for each loaded fixture
    for (fixtures.items) |fixture| {
        const main_name = try std.fmt.allocPrint(allocator, "MainEvm/{s}", .{fixture.name});
        const min_name = try std.fmt.allocPrint(allocator, "MinimalEvm/{s}", .{fixture.name});

        try bench.add(main_name, createMainEvmBenchmark(fixture), .{});
        try bench.add(min_name, createMinimalEvmBenchmark(fixture), .{});
    }

    // Run benchmarks
    var buf: [4096]u8 = undefined;
    var writer = std.fs.File.stdout().writer(&buf);
    try bench.run(&writer.interface);
}