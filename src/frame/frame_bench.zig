/// Benchmarks for Frame performance (formerly vs REVM, now uses MinimalEvm)
const std = @import("std");
const zbench = @import("zbench");
const Frame = @import("frame.zig").Frame;
const FrameConfig = @import("frame_config.zig").FrameConfig;
const Opcode = @import("../opcodes/opcode.zig").Opcode;
const primitives = @import("primitives");
const Address = primitives.Address;
const Database = @import("../storage/database.zig").Database;
const MemoryDatabase = @import("../storage/memory_database.zig").MemoryDatabase;
const evm_mod = @import("../root.zig");
const Host = evm_mod.Host;
// MinimalEvm is now used for differential testing instead of revm
// const MinimalEvm = @import("../tracer/tracer.zig").MinimalEvm;
const block_info_mod = @import("../block/block_info.zig");
const call_params_mod = @import("call_params.zig");
const call_result_mod = @import("call_result.zig");
const hardfork_mod = @import("../eips_and_hardforks/hardfork.zig");
const ZERO_ADDRESS = primitives.Address.ZERO_ADDRESS;

/// Load bytecode from a fixture file
fn loadFixtureBytecode(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 10 * 1024 * 1024); // Max 10MB
    defer allocator.free(content);

    // Parse hex string (remove 0x prefix if present)
    const hex_start: usize = if (std.mem.startsWith(u8, content, "0x")) 2 else 0;
    const hex_content = std.mem.trim(u8, content[hex_start..], " \n\r\t");

    var bytecode = try allocator.alloc(u8, hex_content.len / 2);
    var i: usize = 0;
    while (i < hex_content.len) : (i += 2) {
        const byte = try std.fmt.parseInt(u8, hex_content[i .. i + 2], 16);
        bytecode[i / 2] = byte;
    }

    return bytecode;
}

// Test host implementation for benchmarking
const TestHost = struct {
    const Self = @This();

    pub fn get_balance(self: *Self, address: Address) u256 {
        _ = self;
        _ = address;
        return 10000000;
    }

    pub fn account_exists(self: *Self, address: Address) bool {
        _ = self;
        _ = address;
        return true;
    }

    pub fn get_code(self: *Self, address: Address) []const u8 {
        _ = self;
        _ = address;
        return &[_]u8{};
    }

    pub fn get_block_info(self: *Self) block_info_mod.DefaultBlockInfo {
        _ = self;
        return block_info_mod.DefaultBlockInfo.init();
    }

    pub fn emit_log(self: *Self, contract_address: Address, topics: []const u256, data: []const u8) void {
        _ = self;
        _ = contract_address;
        _ = topics;
        _ = data;
    }

    pub fn inner_call(self: *Self, params: call_params_mod.CallParams) !call_result_mod.CallResult {
        _ = self;
        _ = params;
        return error.NotImplemented;
    }

    pub fn register_created_contract(self: *Self, address: Address) !void {
        _ = self;
        _ = address;
    }

    pub fn was_created_in_tx(self: *Self, address: Address) bool {
        _ = self;
        _ = address;
        return false;
    }

    pub fn create_snapshot(self: *Self) u32 {
        _ = self;
        return 0;
    }

    pub fn revert_to_snapshot(self: *Self, snapshot_id: u32) void {
        _ = self;
        _ = snapshot_id;
    }

    pub fn get_storage(self: *Self, address: Address, slot: u256) u256 {
        _ = self;
        _ = address;
        _ = slot;
        return 0;
    }

    pub fn set_storage(self: *Self, address: Address, slot: u256, value: u256) !void {
        _ = self;
        _ = address;
        _ = slot;
        _ = value;
    }

    pub fn get_transient_storage(self: *Self, address: Address, slot: u256) u256 {
        _ = self;
        _ = address;
        _ = slot;
        return 0;
    }

    pub fn set_transient_storage(self: *Self, address: Address, slot: u256, value: u256) !void {
        _ = self;
        _ = address;
        _ = slot;
        _ = value;
    }

    pub fn mark_account_warm(self: *Self, address: Address) bool {
        _ = self;
        _ = address;
        return true;
    }

    pub fn mark_storage_warm(self: *Self, address: Address, slot: u256) bool {
        _ = self;
        _ = address;
        _ = slot;
        return true;
    }

    pub fn mark_account_for_selfdestruct(self: *Self, address: Address) !void {
        _ = self;
        _ = address;
    }

    pub fn unmark_account_for_selfdestruct(self: *Self, address: Address) !void {
        _ = self;
        _ = address;
    }

    pub fn get_block_hash(self: *Self, block_number: u64) ?[32]u8 {
        _ = self;
        _ = block_number;
        return null;
    }

    pub fn record_storage_change(self: *Self, address: Address, slot: u256, original_value: u256) !void {
        _ = self;
        _ = address;
        _ = slot;
        _ = original_value;
    }

    pub fn get_original_storage(self: *Self, address: Address, slot: u256) ?u256 {
        _ = self;
        _ = address;
        _ = slot;
        return null;
    }

    pub fn access_address(self: *Self, address: Address) !u64 {
        _ = self;
        _ = address;
        return 0;
    }

    pub fn access_storage_slot(self: *Self, contract_address: Address, slot: u256) !u64 {
        _ = self;
        _ = contract_address;
        _ = slot;
        return 0;
    }

    pub fn mark_for_destruction(self: *Self, contract_address: Address, recipient: Address) !void {
        _ = self;
        _ = contract_address;
        _ = recipient;
    }

    pub fn get_input(self: *Self) []const u8 {
        _ = self;
        return &[_]u8{};
    }

    pub fn is_hardfork_at_least(self: *Self, target: hardfork_mod.Hardfork) bool {
        _ = self;
        _ = target;
        return true;
    }

    pub fn get_hardfork(self: *Self) hardfork_mod.Hardfork {
        _ = self;
        return hardfork_mod.Hardfork.CANCUN;
    }

    pub fn get_is_static(self: *Self) bool {
        _ = self;
        return false;
    }

    pub fn get_depth(self: *Self) u11 {
        _ = self;
        return 0;
    }

    pub fn get_gas_price(self: *Self) u256 {
        _ = self;
        return 0;
    }

    pub fn get_return_data(self: *Self) []const u8 {
        _ = self;
        return &[_]u8{};
    }

    pub fn get_chain_id(self: *Self) u64 {
        _ = self;
        return 1;
    }

    pub fn get_blob_hash(self: *Self, index: u256) ?[32]u8 {
        _ = self;
        _ = index;
        return null;
    }

    pub fn get_blob_base_fee(self: *Self) u256 {
        _ = self;
        return 0;
    }

    pub fn get_tx_origin(self: *Self) Address {
        _ = self;
        return ZERO_ADDRESS;
    }

    pub fn get_caller(self: *Self) Address {
        _ = self;
        return ZERO_ADDRESS;
    }

    pub fn get_call_value(self: *Self) u256 {
        _ = self;
        return 0;
    }
}
*/;

/// Create a test host for benchmarking
fn createBenchHost() Host {
    const holder = struct {
        var instance: TestHost = .{};
    };
    return Host.init(&holder.instance);
}

// Benchmark state for ERC20
var erc20_bytecode: []u8 = undefined;
var snailtracer_bytecode: []u8 = undefined;
var ten_k_hashes_bytecode: []u8 = undefined;
var arithmetic_bytecode: []u8 = undefined;
var jump_bytecode: []u8 = undefined;

// Initialize bytecodes once
fn initBytecodes(allocator: std.mem.Allocator) !void {
    erc20_bytecode = try loadFixtureBytecode(allocator, "src/evm/fixtures/erc20-transfer/bytecode.txt");
    snailtracer_bytecode = try loadFixtureBytecode(allocator, "src/evm/fixtures/snailtracer/bytecode.txt");
    ten_k_hashes_bytecode = try loadFixtureBytecode(allocator, "src/evm/fixtures/ten-thousand-hashes/bytecode.txt");
    arithmetic_bytecode = try loadFixtureBytecode(allocator, "src/evm/fixtures/opcodes-arithmetic/bytecode.txt");
    jump_bytecode = try loadFixtureBytecode(allocator, "src/evm/fixtures/opcodes-jump-basic/bytecode.txt");
}

// Benchmark functions for Frame
fn benchmarkFrameERC20(allocator: std.mem.Allocator) void {
    const F = Frame(.{ .DatabaseType = @import("../storage/memory_database.zig").MemoryDatabase });

    const host = createBenchHost();
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.database();

    // Initialize frame directly from raw bytecode
    var frame = F.init(allocator, erc20_bytecode, 1000000, &db_interface, host, null) catch unreachable;
    defer frame.deinit(allocator);

    // Just initialization for now - actual execution would require planner/interpreter
}

fn benchmarkFrameSnailtracer(allocator: std.mem.Allocator) void {
    const F = Frame(.{ .DatabaseType = @import("../storage/memory_database.zig").MemoryDatabase });

    const host = createBenchHost();
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.database();

    var frame = F.init(allocator, snailtracer_bytecode, 10000000, &db_interface, host, null) catch unreachable;
    defer frame.deinit(allocator);
}

fn benchmarkFrameTenKHashes(allocator: std.mem.Allocator) void {
    const F = Frame(.{});

    const host = createBenchHost();
    var frame = F.init(allocator, 100000000, {}, host, null) catch unreachable;
    defer frame.deinit(allocator);
}

fn benchmarkFrameArithmetic(allocator: std.mem.Allocator) void {
    const F = Frame(.{});

    const host = createBenchHost();
    var frame = F.init(allocator, 100000, {}, host, null) catch unreachable;
    defer frame.deinit(allocator);
}

fn benchmarkFrameJumps(allocator: std.mem.Allocator) void {
    const F = Frame(.{});

    const host = createBenchHost();
    var frame = F.init(allocator, 100000, {}, host, null) catch unreachable;
    defer frame.deinit(allocator);
}

// Benchmark functions for MinimalEvm (revm functions commented out)
/*
fn benchmarkRevmERC20(allocator: std.mem.Allocator) void {
    var vm = Revm.init(allocator, RevmSettings{}) catch unreachable;
    defer vm.deinit();

    // Deploy contract
    const deployer = Address.ZERO_ADDRESS;
    vm.setBalance(deployer, 10000000) catch unreachable;
    vm.setCode(deployer, erc20_bytecode) catch unreachable;

    // Execute a simple call (constructor)
    var result = vm.call(deployer, deployer, 0, &.{}, 1000000) catch unreachable;
    defer result.deinit();
}
*/

/*
fn benchmarkRevmSnailtracer(allocator: std.mem.Allocator) void {
    var vm = Revm.init(allocator, RevmSettings{}) catch unreachable;
    defer vm.deinit();

    const deployer = Address.ZERO_ADDRESS;
    vm.setBalance(deployer, 10000000) catch unreachable;
    vm.setCode(deployer, snailtracer_bytecode) catch unreachable;

    var result = vm.call(deployer, deployer, 0, &.{}, 10000000) catch unreachable;
    defer result.deinit();
}
*/

/*
fn benchmarkRevmTenKHashes(allocator: std.mem.Allocator) void {
    var vm = Revm.init(allocator, RevmSettings{}) catch unreachable;
    defer vm.deinit();

    const deployer = Address.ZERO_ADDRESS;
    vm.setBalance(deployer, 10000000) catch unreachable;
    vm.setCode(deployer, ten_k_hashes_bytecode) catch unreachable;

    var result = vm.call(deployer, deployer, 0, &.{}, 100000000) catch unreachable;
    defer result.deinit();
}
*/

/*
fn benchmarkRevmArithmetic(allocator: std.mem.Allocator) void {
    var vm = Revm.init(allocator, RevmSettings{}) catch unreachable;
    defer vm.deinit();

    const deployer = Address.ZERO_ADDRESS;
    vm.setBalance(deployer, 10000000) catch unreachable;
    vm.setCode(deployer, arithmetic_bytecode) catch unreachable;

    var result = vm.call(deployer, deployer, 0, &.{}, 100000) catch unreachable;
    defer result.deinit();
}
*/

/*
fn benchmarkRevmJumps(allocator: std.mem.Allocator) void {
    var vm = Revm.init(allocator, RevmSettings{}) catch unreachable;
    defer vm.deinit();

    const deployer = Address.ZERO_ADDRESS;
    vm.setBalance(deployer, 10000000) catch unreachable;
    vm.setCode(deployer, jump_bytecode) catch unreachable;

    var result = vm.call(deployer, deployer, 0, &.{}, 100000) catch unreachable;
    defer result.deinit();
}

// Schedule generation benchmarks
fn benchmarkScheduleGenERC20(allocator: std.mem.Allocator) void {
    const F = Frame(.{});

    const host = createBenchHost();
    var frame = F.init(allocator, erc20_bytecode, 1000000, {}, host, null) catch unreachable;
    defer frame.deinit(allocator);

    const schedule = F.Schedule.init(allocator, &frame.bytecode) catch unreachable;
    defer allocator.free(schedule);
}

fn benchmarkScheduleGenSnailtracer(allocator: std.mem.Allocator) void {
    const F = Frame(.{});

    const host = createBenchHost();
    var frame = F.init(allocator, snailtracer_bytecode, 10000000, {}, host, null) catch unreachable;
    defer frame.deinit(allocator);

    const schedule = F.Schedule.init(allocator, &frame.bytecode) catch unreachable;
    defer allocator.free(schedule);
}

pub fn main() !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize bytecodes
    try stdout.print("Initializing bytecodes...\n", .{});
    try stdout.flush();
    try initBytecodes(allocator);
    try stdout.print("Bytecodes initialized\n", .{});
    try stdout.flush();
    defer {
        allocator.free(erc20_bytecode);
        allocator.free(snailtracer_bytecode);
        allocator.free(ten_k_hashes_bytecode);
        allocator.free(arithmetic_bytecode);
        allocator.free(jump_bytecode);
    }

    var bench = zbench.Benchmark.init(allocator, .{
        .iterations = 10,
    });
    defer bench.deinit();

    try stdout.print("\n🚀 Frame Benchmarks\n", .{});
    try stdout.print("==================================\n\n", .{});
    try stdout.flush();

    // Add Frame benchmarks
    try bench.add("Frame/ERC20", benchmarkFrameERC20, .{});
    try bench.add("Frame/Snailtracer", benchmarkFrameSnailtracer, .{});
    try bench.add("Frame/TenKHashes", benchmarkFrameTenKHashes, .{});
    try bench.add("Frame/Arithmetic", benchmarkFrameArithmetic, .{});
    try bench.add("Frame/Jumps", benchmarkFrameJumps, .{});

    // MinimalEvm benchmarks can be added here if needed
    // try bench.add("MinimalEvm/ERC20", benchmarkMinimalERC20, .{});
    // try bench.add("MinimalEvm/Snailtracer", benchmarkMinimalSnailtracer, .{});
    // try bench.add("MinimalEvm/TenKHashes", benchmarkMinimalTenKHashes, .{});
    // try bench.add("MinimalEvm/Arithmetic", benchmarkMinimalArithmetic, .{});
    // try bench.add("MinimalEvm/Jumps", benchmarkMinimalJumps, .{});

    // Add Schedule generation benchmarks
    // TODO: Fix ArrayList initialization for Zig 0.15
    // try bench.add("Schedule/ERC20", benchmarkScheduleGenERC20, .{});
    // try bench.add("Schedule/Snailtracer", benchmarkScheduleGenSnailtracer, .{});

    try stdout.print("Running benchmarks...\n\n", .{});
    try stdout.flush();

    try bench.run(stdout);
}

test "benchmark fixture loading" {
    const allocator = std.testing.allocator;

    // Test loading ERC20 bytecode
    const erc20 = try loadFixtureBytecode(allocator, "src/evm/fixtures/erc20-transfer/bytecode.txt");
    defer allocator.free(erc20);
    try std.testing.expect(erc20.len > 1000); // ERC20 should be substantial

    // Test loading snailtracer
    const snailtracer = try loadFixtureBytecode(allocator, "src/evm/fixtures/snailtracer/bytecode.txt");
    defer allocator.free(snailtracer);
    try std.testing.expect(snailtracer.len > 5000); // Snailtracer is large
}

test "benchmark Frame initialization" {
    const allocator = std.testing.allocator;

    const bytecode = try loadFixtureBytecode(allocator, "src/evm/fixtures/opcodes-arithmetic/bytecode.txt");
    defer allocator.free(bytecode);

    const F = Frame(.{});
    const host = createBenchHost();

    var frame = try F.init(allocator, bytecode, 100000, {}, host, null);
    defer frame.deinit(allocator);

    try std.testing.expect(frame.bytecode.len() > 0);
}

test "benchmark MinimalEvm initialization" {
    const allocator = std.testing.allocator;
    _ = allocator;
    // MinimalEvm initialization test can be added here
    // var vm = try MinimalEvm.init(allocator);
    defer vm.deinit();

    // Just verify it initializes
}
