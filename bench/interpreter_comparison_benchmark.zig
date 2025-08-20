const std = @import("std");
const testing = std.testing;
const evm = @import("evm");
const primitives = @import("primitives");
const Address = primitives.Address;
const revm_wrapper = @import("revm");

// Helper to decode hex strings
fn hex_decode(allocator: std.mem.Allocator, hex_str: []const u8) ![]u8 {
    const clean_hex = if (std.mem.startsWith(u8, hex_str, "0x")) hex_str[2..] else hex_str;
    const result = try allocator.alloc(u8, clean_hex.len / 2);
    _ = try std.fmt.hexToBytes(result, clean_hex);
    return result;
}

// Helper to read benchmark case files
fn read_case_file(allocator: std.mem.Allocator, comptime case_name: []const u8, comptime file_name: []const u8) ![]u8 {
    const path = "/Users/williamcory/Guillotine/bench/official/cases/" ++ case_name ++ "/" ++ file_name;
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    const content = try file.readToEndAlloc(allocator, 16 * 1024 * 1024);
    const trimmed = std.mem.trim(u8, content, " \t\n\r");
    if (trimmed.ptr == content.ptr and trimmed.len == content.len) {
        return content;
    }
    defer allocator.free(content);
    const result = try allocator.alloc(u8, trimmed.len);
    @memcpy(result, trimmed);
    return result;
}

// Struct to hold benchmark setup
const BenchmarkSetup = struct {
    init_code: []u8,
    calldata: []u8,
    fixed_addr: Address,
    deployer: Address,
    allocator: std.mem.Allocator,

    fn deinit(self: *BenchmarkSetup) void {
        self.allocator.free(self.init_code);
        self.allocator.free(self.calldata);
    }
};

// Setup function for each benchmark case
fn setup_benchmark(allocator: std.mem.Allocator, comptime case_name: []const u8) !BenchmarkSetup {
    const bytecode_hex = try read_case_file(allocator, case_name, "bytecode.txt");
    defer allocator.free(bytecode_hex);
    
    const init_code = try hex_decode(allocator, bytecode_hex);
    
    // Read calldata if it exists
    var calldata: []u8 = &.{};
    const calldata_path = "/Users/williamcory/Guillotine/bench/official/cases/" ++ case_name ++ "/calldata.txt";
    if (std.fs.openFileAbsolute(calldata_path, .{})) |file| {
        defer file.close();
        const content = try file.readToEndAlloc(allocator, 1024);
        defer allocator.free(content);
        const trimmed = std.mem.trim(u8, content, " \t\n\r");
        calldata = try hex_decode(allocator, trimmed);
    } else |_| {
        calldata = try allocator.alloc(u8, 0);
    }
    
    return BenchmarkSetup{
        .init_code = init_code,
        .calldata = calldata,
        .fixed_addr = try Address.from_hex("0xc0de000000000000000000000000000000000000"),
        .deployer = try Address.from_hex("0x1111111111111111111111111111111111111111"),
        .allocator = allocator,
    };
}

// Benchmark interpret.zig (standard interpreter with analysis)
pub fn zbench_interpret(allocator: std.mem.Allocator, timer: anytype) !u64 {
    var setup = try setup_benchmark(allocator, "ten-thousand-hashes");
    defer setup.deinit();
    
    // Setup VM
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    var vm = try evm.Evm.init(allocator, memory_db.to_database_interface(), null, null, null, null);
    defer vm.deinit();
    
    // Deploy contract
    try vm.state.set_balance(setup.deployer, std.math.maxInt(u256));
    const create_result = try vm.create_contract(setup.deployer, 0, setup.init_code, 10_000_000);
    const contract_addr = create_result.address;
    
    timer.reset();
    // Execute call
    const result = try vm.call(setup.deployer, contract_addr, 0, setup.calldata, 5_000_000);
    _ = result;
    
    return timer.read();
}

// Benchmark call_mini.zig (simplified interpreter without analysis)
pub fn zbench_call_mini(allocator: std.mem.Allocator, timer: anytype) !u64 {
    var setup = try setup_benchmark(allocator, "ten-thousand-hashes");
    defer setup.deinit();
    
    // Setup VM
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    var vm = try evm.Evm.init(allocator, memory_db.to_database_interface(), null, null, null, null);
    defer vm.deinit();
    
    // Deploy contract
    try vm.state.set_balance(setup.deployer, std.math.maxInt(u256));
    const create_result = try vm.create_contract(setup.deployer, 0, setup.init_code, 10_000_000);
    const contract_addr = create_result.address;
    
    timer.reset();
    // Execute call with call_mini
    const params = evm.CallParams{
        .call = .{
            .caller = setup.deployer,
            .to = contract_addr,
            .value = 0,
            .input = setup.calldata,
            .gas = 5_000_000,
        },
    };
    const result = try vm.call_mini(params);
    _ = result;
    
    return timer.read();
}

// Benchmark interpret2.zig (new tailcall interpreter)
pub fn zbench_interpret2(allocator: std.mem.Allocator, timer: anytype) !u64 {
    var setup = try setup_benchmark(allocator, "ten-thousand-hashes");
    defer setup.deinit();
    
    // Setup VM
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    var vm = try evm.Evm.init(allocator, memory_db.to_database_interface(), null, null, null, null);
    defer vm.deinit();
    
    // Deploy contract
    try vm.state.set_balance(setup.deployer, std.math.maxInt(u256));
    const create_result = try vm.create_contract(setup.deployer, 0, setup.init_code, 10_000_000);
    const contract_addr = create_result.address;
    
    timer.reset();
    // Use the regular call which will use interpret2 if enabled
    const result = try vm.call(setup.deployer, contract_addr, 0, setup.calldata, 5_000_000);
    _ = result;
    
    return timer.read();
}

// Benchmark REVM (Rust implementation)
pub fn zbench_revm(allocator: std.mem.Allocator, timer: anytype) !u64 {
    var setup = try setup_benchmark(allocator, "ten-thousand-hashes");
    defer setup.deinit();
    
    // Setup REVM
    var vm = try revm_wrapper.Revm.init(allocator, .{});
    defer vm.deinit();
    
    // Deploy contract
    try vm.setBalance(setup.deployer, std.math.maxInt(u256));
    var create_result = try vm.create(setup.deployer, 0, setup.init_code, 10_000_000);
    defer create_result.deinit();
    
    // For REVM, we need to get the contract address differently
    // Use a fixed address for consistency
    const contract_addr = setup.fixed_addr;
    try vm.setCode(contract_addr, create_result.output);
    
    timer.reset();
    // Execute call
    var result = try vm.call(setup.deployer, contract_addr, 0, setup.calldata, 5_000_000);
    defer result.deinit();
    
    return timer.read();
}

// ERC20 benchmarks
pub fn zbench_erc20_interpret(allocator: std.mem.Allocator, timer: anytype) !u64 {
    var setup = try setup_benchmark(allocator, "erc20-transfer");
    defer setup.deinit();
    
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    var vm = try evm.Evm.init(allocator, memory_db.to_database_interface(), null, null, null, null);
    defer vm.deinit();
    
    try vm.state.set_balance(setup.deployer, std.math.maxInt(u256));
    const create_result = try vm.create_contract(setup.deployer, 0, setup.init_code, 10_000_000);
    const contract_addr = create_result.address;
    
    timer.reset();
    const result = try vm.call(setup.deployer, contract_addr, 0, setup.calldata, 1_000_000);
    _ = result;
    
    return timer.read();
}

pub fn zbench_erc20_call_mini(allocator: std.mem.Allocator, timer: anytype) !u64 {
    var setup = try setup_benchmark(allocator, "erc20-transfer");
    defer setup.deinit();
    
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    var vm = try evm.Evm.init(allocator, memory_db.to_database_interface(), null, null, null, null);
    defer vm.deinit();
    
    try vm.state.set_balance(setup.deployer, std.math.maxInt(u256));
    const create_result = try vm.create_contract(setup.deployer, 0, setup.init_code, 10_000_000);
    const contract_addr = create_result.address;
    
    timer.reset();
    const params = evm.CallParams{
        .call = .{
            .caller = setup.deployer,
            .to = contract_addr,
            .value = 0,
            .input = setup.calldata,
            .gas = 1_000_000,
        },
    };
    const result = try vm.call_mini(params);
    _ = result;
    
    return timer.read();
}

pub fn zbench_erc20_revm(allocator: std.mem.Allocator, timer: anytype) !u64 {
    var setup = try setup_benchmark(allocator, "erc20-transfer");
    defer setup.deinit();
    
    var vm = try revm_wrapper.Revm.init(allocator, .{});
    defer vm.deinit();
    
    try vm.setBalance(setup.deployer, std.math.maxInt(u256));
    var create_result = try vm.create(setup.deployer, 0, setup.init_code, 10_000_000);
    defer create_result.deinit();
    
    const contract_addr = setup.fixed_addr;
    try vm.setCode(contract_addr, create_result.output);
    
    timer.reset();
    var result = try vm.call(setup.deployer, contract_addr, 0, setup.calldata, 1_000_000);
    defer result.deinit();
    
    return timer.read();
}

// Snailtracer benchmarks (may fail)
pub fn zbench_snailtracer_interpret(allocator: std.mem.Allocator, timer: anytype) !u64 {
    var setup = try setup_benchmark(allocator, "snailtracer");
    defer setup.deinit();
    
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    var vm = try evm.Evm.init(allocator, memory_db.to_database_interface(), null, null, null, null);
    defer vm.deinit();
    
    try vm.state.set_balance(setup.deployer, std.math.maxInt(u256));
    const create_result = try vm.create_contract(setup.deployer, 0, setup.init_code, 50_000_000);
    const contract_addr = create_result.address;
    
    timer.reset();
    const result = vm.call(setup.deployer, contract_addr, 0, setup.calldata, 10_000_000) catch |err| {
        // Snailtracer might fail, just return a marker time
        _ = err;
        return 999_999_999;
    };
    _ = result;
    
    return timer.read();
}

pub fn zbench_snailtracer_revm(allocator: std.mem.Allocator, timer: anytype) !u64 {
    var setup = try setup_benchmark(allocator, "snailtracer");
    defer setup.deinit();
    
    var vm = try revm_wrapper.Revm.init(allocator, .{});
    defer vm.deinit();
    
    try vm.setBalance(setup.deployer, std.math.maxInt(u256));
    var create_result = try vm.create(setup.deployer, 0, setup.init_code, 50_000_000);
    defer create_result.deinit();
    
    const contract_addr = setup.fixed_addr;
    try vm.setCode(contract_addr, create_result.output);
    
    timer.reset();
    var result = vm.call(setup.deployer, contract_addr, 0, setup.calldata, 10_000_000) catch |err| {
        _ = err;
        return 999_999_999;
    };
    defer result.deinit();
    
    return timer.read();
}