const std = @import("std");
const zbench = @import("zbench");
const evm = @import("evm");
const primitives = @import("voltaire");

const Address = primitives.Address.Address;
const GasConstants = primitives.GasConstants;
const MinimalEvm = evm.MinimalEvm;

// Fixture data structure
const Fixture = struct {
    name: []const u8,
    bytecode: []const u8,
    calldata: []const u8,
    gas_limit: u64,
};

// Helper function to decode hex strings
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

// Load fixture from JSON file
fn loadFixture(allocator: std.mem.Allocator, fixture_name: []const u8) !Fixture {
    const fixture_path = try std.fmt.allocPrint(allocator, "bench/fixtures/{s}.json", .{fixture_name});
    defer allocator.free(fixture_path);

    const file = try std.fs.cwd().openFile(fixture_path, .{});
    defer file.close();

    const json_text = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(json_text);

    const parsed = try std.json.parseFromSlice(struct {
        name: []const u8,
        contract: []const u8,
        calldata: []const u8,
        gas_limit: u64,
    }, allocator, json_text, .{});
    defer parsed.deinit();

    // Load and compile the Solidity contract bytecode
    // For now, we'll use pre-compiled bytecode from cache if available
    const cache_path = try std.fmt.allocPrint(allocator, "bench/fixtures/cache/{s}.bin", .{fixture_name});
    defer allocator.free(cache_path);

    const bytecode_hex = std.fs.cwd().readFileAlloc(allocator, cache_path, 1_000_000) catch |err| {
        if (err == error.FileNotFound) {
            // Return empty bytecode for now - in production, you'd compile the contract
            return Fixture{
                .name = try allocator.dupe(u8, parsed.value.name),
                .bytecode = try allocator.alloc(u8, 0),
                .calldata = try decodeHex(allocator, parsed.value.calldata),
                .gas_limit = parsed.value.gas_limit,
            };
        }
        return err;
    };
    defer allocator.free(bytecode_hex);

    return Fixture{
        .name = try allocator.dupe(u8, parsed.value.name),
        .bytecode = try decodeHex(allocator, std.mem.trim(u8, bytecode_hex, " \n\r\t")),
        .calldata = try decodeHex(allocator, parsed.value.calldata),
        .gas_limit = parsed.value.gas_limit,
    };
}

// Setup blockchain context
fn createBlockInfo() evm.BlockInfo {
    return .{
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
}

// Setup transaction context
fn createTxContext(gas_limit: u64) evm.TransactionContext {
    return .{
        .gas_limit = gas_limit,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
        .blob_versioned_hashes = &.{},
        .blob_base_fee = 0,
    };
}


// Benchmark wrapper for main EVM
fn createMainEvmBenchmark(fixture_name: []const u8, fixture: Fixture) fn (std.mem.Allocator) void {
    return struct {
        const fixture_data = fixture;
        const name = fixture_name;

        pub fn benchmark(allocator: std.mem.Allocator) void {
            // Setup
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

            if (fixture_data.bytecode.len > 0) {
                const code_hash = database.set_code(fixture_data.bytecode) catch unreachable;
                const contract_account = evm.Account{
                    .balance = 0,
                    .code_hash = code_hash,
                    .storage_root = [_]u8{0} ** 32,
                    .nonce = 0,
                    .delegated_address = null,
                };
                database.set_account(contract_address.bytes, contract_account) catch unreachable;
            }

            // Run benchmark
            const block_info = createBlockInfo();
            const tx_context = createTxContext(fixture_data.gas_limit);

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
                    .input = fixture_data.calldata,
                    .gas = fixture_data.gas_limit,
                },
            };

            var result = main_evm.simulate(call_params);
            defer result.deinit(allocator);
        }
    }.benchmark;
}

// Benchmark wrapper for minimal EVM
fn createMinimalEvmBenchmark(fixture_name: []const u8, fixture: Fixture) fn (std.mem.Allocator) void {
    return struct {
        const fixture_data = fixture;
        const name = fixture_name;

        pub fn benchmark(allocator: std.mem.Allocator) void {
            const sender_address = Address.fromBytes(&([_]u8{0} ** 19 ++ [_]u8{0x01})) catch unreachable;
            const contract_address = Address.fromBytes(&([_]u8{0} ** 19 ++ [_]u8{0x42})) catch unreachable;

            var min_evm = MinimalEvm.init(allocator) catch unreachable;
            defer min_evm.deinit();

            // Setup blockchain context
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

            // Set up accounts
            min_evm.setBalance(sender_address, 100_000_000_000_000_000_000) catch unreachable;
            if (fixture_data.bytecode.len > 0) {
                min_evm.setCode(contract_address, fixture_data.bytecode) catch unreachable;
            }

            // Execute
            const result = min_evm.execute(
                fixture_data.bytecode,
                @intCast(fixture_data.gas_limit),
                sender_address,
                contract_address,
                0, // value
                fixture_data.calldata,
            ) catch {
                return;
            };
            _ = result;
        }
    }.benchmark;
}

// Register benchmarks for a specific fixture
fn registerFixtureBenchmarks(
    allocator: std.mem.Allocator,
    bench: *zbench.Benchmark,
    fixture_name: []const u8,
) !void {
    const fixture = loadFixture(allocator, fixture_name) catch |err| {
        std.debug.print("Warning: Could not load fixture '{s}': {}\n", .{ fixture_name, err });
        return;
    };

    if (fixture.bytecode.len == 0) {
        std.debug.print("Warning: No bytecode for fixture '{s}', skipping\n", .{fixture_name});
        allocator.free(fixture.name);
        allocator.free(fixture.bytecode);
        allocator.free(fixture.calldata);
        return;
    }

    // Main EVM benchmark
    const main_bench_name = try std.fmt.allocPrint(allocator, "MainEvm/{s}", .{fixture_name});
    const main_benchmark = createMainEvmBenchmark(fixture_name, fixture);
    try bench.add(main_bench_name, main_benchmark, .{});

    // Minimal EVM benchmark
    const min_bench_name = try std.fmt.allocPrint(allocator, "MinimalEvm/{s}", .{fixture_name});
    const min_benchmark = createMinimalEvmBenchmark(fixture_name, fixture);
    try bench.add(min_bench_name, min_benchmark, .{});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== EVM Fixture Benchmarks ===\n\n", .{});

    // Create benchmark
    var bench = zbench.Benchmark.init(allocator, .{
        .time_budget_ns = 2_000_000_000, // 2 seconds per benchmark
    });
    defer bench.deinit();

    // List of all fixtures to benchmark (prioritized order)
    const fixtures = [_][]const u8{
        // Priority benchmarks
        "snailtracer",
        "erc20transfer",
        "erc20mint",
        "erc20approval",
        "ten-thousand-hashes",
        "bubblesort",

        // Additional benchmarks
        "arithmetic",
        "bitwise",
        "blockinfo",
        "calldata",
        "codecopy",
        "comparison",
        "context",
        "contractcalls",
        "contractcreation",
        "controlflow",
        "externalcode",
        "factorial",
        "factorial-recursive",
        "fibonacci",
        "fibonacci-recursive",
        "hashing",
        "logs",
        "manyhashes",
        "memory",
        "modulararithmetic",
        "mstore",
        "push",
        "returndata",
        "shifts",
        "signedarithmetic",
        "sstore",
        "stack",
        "storage",
    };

    // Register benchmarks for each fixture
    for (fixtures) |fixture_name| {
        try registerFixtureBenchmarks(allocator, &bench, fixture_name);
    }

    // Run benchmarks
    try bench.run(std.io.getStdOut().writer());
}