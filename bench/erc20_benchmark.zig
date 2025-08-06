const std = @import("std");
const zbench = @import("zbench");
const evm = @import("evm");
const primitives = @import("primitives");

/// Load bytecode from the official benchmark files
fn loadBytecode(allocator: std.mem.Allocator, comptime test_case: []const u8) ![]u8 {
    const bytecode_path = "/Users/williamcory/Guillotine/bench/official/cases/" ++ test_case ++ "/bytecode.txt";
    const file = try std.fs.openFileAbsolute(bytecode_path, .{});
    defer file.close();
    
    const content = try file.readToEndAlloc(allocator, 10 * 1024 * 1024); // 10MB max
    defer allocator.free(content);
    
    // Trim whitespace
    const trimmed = std.mem.trim(u8, content, " \t\n\r");
    
    // Remove 0x prefix if present
    const clean_hex = if (std.mem.startsWith(u8, trimmed, "0x"))
        trimmed[2..]
    else
        trimmed;
    
    // Decode hex to bytes
    const bytes = try allocator.alloc(u8, clean_hex.len / 2);
    var i: usize = 0;
    while (i < clean_hex.len) : (i += 2) {
        const byte_str = clean_hex[i .. i + 2];
        bytes[i / 2] = try std.fmt.parseInt(u8, byte_str, 16);
    }
    
    return bytes;
}

/// Load calldata from the official benchmark files
fn loadCalldata(allocator: std.mem.Allocator, comptime test_case: []const u8) ![]u8 {
    const calldata_path = "/Users/williamcory/Guillotine/bench/official/cases/" ++ test_case ++ "/calldata.txt";
    const file = try std.fs.openFileAbsolute(calldata_path, .{});
    defer file.close();
    
    const content = try file.readToEndAlloc(allocator, 1024 * 1024); // 1MB max
    defer allocator.free(content);
    
    // Trim whitespace
    const trimmed = std.mem.trim(u8, content, " \t\n\r");
    
    // Remove 0x prefix if present
    const clean_hex = if (std.mem.startsWith(u8, trimmed, "0x"))
        trimmed[2..]
    else
        trimmed;
    
    // Decode hex to bytes
    const bytes = try allocator.alloc(u8, clean_hex.len / 2);
    var i: usize = 0;
    while (i < clean_hex.len) : (i += 2) {
        const byte_str = clean_hex[i .. i + 2];
        bytes[i / 2] = try std.fmt.parseInt(u8, byte_str, 16);
    }
    
    return bytes;
}

/// Deploy a contract and return its address
fn deployContract(allocator: std.mem.Allocator, vm: *evm.Evm, caller: primitives.Address.Address, bytecode: []const u8) !primitives.Address.Address {
    _ = allocator;
    
    const create_result = try vm.create_contract(
        caller,
        0, // value
        bytecode, // init code
        10_000_000 // gas
    );
    
    if (create_result.success) {
        return create_result.address;
    } else {
        return error.DeploymentFailed;
    }
}

/// Global state for benchmarks (initialized once)
var global_bytecode_transfer: ?[]u8 = null;
var global_calldata_transfer: ?[]u8 = null;
var global_bytecode_mint: ?[]u8 = null;
var global_calldata_mint: ?[]u8 = null;

/// Initialize global benchmark data
fn initGlobalData(allocator: std.mem.Allocator) !void {
    if (global_bytecode_transfer == null) {
        global_bytecode_transfer = try loadBytecode(allocator, "erc20-transfer");
        global_calldata_transfer = try loadCalldata(allocator, "erc20-transfer");
        global_bytecode_mint = try loadBytecode(allocator, "erc20-mint");
        global_calldata_mint = try loadCalldata(allocator, "erc20-mint");
    }
}

/// Benchmark ERC20 transfer with regular execution
fn benchErc20TransferRegular(allocator: std.mem.Allocator) void {
    const bytecode = global_bytecode_transfer.?;
    const calldata = global_calldata_transfer.?;
    
    // Initialize EVM memory allocator
    var evm_memory_allocator = evm.EvmMemoryAllocator.init(allocator) catch unreachable;
    defer evm_memory_allocator.deinit();
    const evm_allocator = evm_memory_allocator.allocator();
    
    // Initialize database
    var memory_db = evm.MemoryDatabase.init(evm_allocator);
    defer memory_db.deinit();
    
    // Create EVM instance
    const db_interface = memory_db.to_database_interface();
    var evm_builder = evm.EvmBuilder.init(evm_allocator, db_interface);
    var vm = evm_builder.build() catch unreachable;
    defer vm.deinit();
    
    // Set up caller account
    const caller_address = primitives.Address.from_hex("0x1000000000000000000000000000000000000001") catch unreachable;
    vm.state.set_balance(caller_address, std.math.maxInt(u256)) catch unreachable;
    
    // Deploy contract
    const contract_address = deployContract(allocator, &vm, caller_address, bytecode) catch unreachable;
    
    // Get contract code
    const code = vm.state.get_code(contract_address);
    const code_hash = [_]u8{0} ** 32;
    
    // Create contract
    var contract = evm.Contract.init(
        caller_address, // caller
        contract_address, // address
        0, // value
        1_000_000, // gas
        code, // code
        code_hash, // code_hash
        calldata, // input
        false // is_static
    );
    defer contract.deinit(evm_allocator, null);
    
    // Execute
    const result = vm.interpret(&contract, calldata, false) catch unreachable;
    
    if (result.output) |output| {
        evm_allocator.free(output);
    }
}

/// Benchmark ERC20 transfer with block execution
fn benchErc20TransferBlock(allocator: std.mem.Allocator) void {
    const bytecode = global_bytecode_transfer.?;
    const calldata = global_calldata_transfer.?;
    
    // Initialize EVM memory allocator
    var evm_memory_allocator = evm.EvmMemoryAllocator.init(allocator) catch unreachable;
    defer evm_memory_allocator.deinit();
    const evm_allocator = evm_memory_allocator.allocator();
    
    // Initialize database
    var memory_db = evm.MemoryDatabase.init(evm_allocator);
    defer memory_db.deinit();
    
    // Create EVM instance
    const db_interface = memory_db.to_database_interface();
    var evm_builder = evm.EvmBuilder.init(evm_allocator, db_interface);
    var vm = evm_builder.build() catch unreachable;
    defer vm.deinit();
    
    // Set up caller account
    const caller_address = primitives.Address.from_hex("0x1000000000000000000000000000000000000001") catch unreachable;
    vm.state.set_balance(caller_address, std.math.maxInt(u256)) catch unreachable;
    
    // Deploy contract
    const contract_address = deployContract(allocator, &vm, caller_address, bytecode) catch unreachable;
    
    // Get contract code
    const code = vm.state.get_code(contract_address);
    const code_hash = [_]u8{0} ** 32;
    
    // Create contract
    var contract = evm.Contract.init(
        caller_address, // caller
        contract_address, // address
        0, // value
        1_000_000, // gas
        code, // code
        code_hash, // code_hash
        calldata, // input
        false // is_static
    );
    defer contract.deinit(evm_allocator, null);
    
    // Execute with block mode
    const result = vm.interpret_block_write(&contract, calldata) catch unreachable;
    
    if (result.output) |output| {
        evm_allocator.free(output);
    }
}

/// Benchmark ERC20 mint with regular execution
fn benchErc20MintRegular(allocator: std.mem.Allocator) void {
    const bytecode = global_bytecode_mint.?;
    const calldata = global_calldata_mint.?;
    
    // Initialize EVM memory allocator
    var evm_memory_allocator = evm.EvmMemoryAllocator.init(allocator) catch unreachable;
    defer evm_memory_allocator.deinit();
    const evm_allocator = evm_memory_allocator.allocator();
    
    // Initialize database
    var memory_db = evm.MemoryDatabase.init(evm_allocator);
    defer memory_db.deinit();
    
    // Create EVM instance
    const db_interface = memory_db.to_database_interface();
    var evm_builder = evm.EvmBuilder.init(evm_allocator, db_interface);
    var vm = evm_builder.build() catch unreachable;
    defer vm.deinit();
    
    // Set up caller account
    const caller_address = primitives.Address.from_hex("0x1000000000000000000000000000000000000001") catch unreachable;
    vm.state.set_balance(caller_address, std.math.maxInt(u256)) catch unreachable;
    
    // Deploy contract
    const contract_address = deployContract(allocator, &vm, caller_address, bytecode) catch unreachable;
    
    // Get contract code
    const code = vm.state.get_code(contract_address);
    const code_hash = [_]u8{0} ** 32;
    
    // Create contract
    var contract = evm.Contract.init(
        caller_address, // caller
        contract_address, // address
        0, // value
        1_000_000, // gas
        code, // code
        code_hash, // code_hash
        calldata, // input
        false // is_static
    );
    defer contract.deinit(evm_allocator, null);
    
    // Execute
    const result = vm.interpret(&contract, calldata, false) catch unreachable;
    
    if (result.output) |output| {
        evm_allocator.free(output);
    }
}

/// Benchmark ERC20 mint with block execution
fn benchErc20MintBlock(allocator: std.mem.Allocator) void {
    const bytecode = global_bytecode_mint.?;
    const calldata = global_calldata_mint.?;
    
    // Initialize EVM memory allocator
    var evm_memory_allocator = evm.EvmMemoryAllocator.init(allocator) catch unreachable;
    defer evm_memory_allocator.deinit();
    const evm_allocator = evm_memory_allocator.allocator();
    
    // Initialize database
    var memory_db = evm.MemoryDatabase.init(evm_allocator);
    defer memory_db.deinit();
    
    // Create EVM instance
    const db_interface = memory_db.to_database_interface();
    var evm_builder = evm.EvmBuilder.init(evm_allocator, db_interface);
    var vm = evm_builder.build() catch unreachable;
    defer vm.deinit();
    
    // Set up caller account
    const caller_address = primitives.Address.from_hex("0x1000000000000000000000000000000000000001") catch unreachable;
    vm.state.set_balance(caller_address, std.math.maxInt(u256)) catch unreachable;
    
    // Deploy contract
    const contract_address = deployContract(allocator, &vm, caller_address, bytecode) catch unreachable;
    
    // Get contract code
    const code = vm.state.get_code(contract_address);
    const code_hash = [_]u8{0} ** 32;
    
    // Create contract
    var contract = evm.Contract.init(
        caller_address, // caller
        contract_address, // address
        0, // value
        1_000_000, // gas
        code, // code
        code_hash, // code_hash
        calldata, // input
        false // is_static
    );
    defer contract.deinit(evm_allocator, null);
    
    // Execute with block mode
    const result = vm.interpret_block_write(&contract, calldata) catch unreachable;
    
    if (result.output) |output| {
        evm_allocator.free(output);
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    // Initialize global data
    try initGlobalData(allocator);
    defer {
        if (global_bytecode_transfer) |b| allocator.free(b);
        if (global_calldata_transfer) |c| allocator.free(c);
        if (global_bytecode_mint) |b| allocator.free(b);
        if (global_calldata_mint) |c| allocator.free(c);
    }
    
    var bench = zbench.Benchmark.init(allocator, .{
        .iterations = 10,
        .max_iterations = 50,
        .time_budget_ns = 1_000_000_000, // 1 second
    });
    defer bench.deinit();
    
    try bench.add("ERC20 Transfer - Regular", benchErc20TransferRegular, .{});
    try bench.add("ERC20 Transfer - Block", benchErc20TransferBlock, .{});
    
    try bench.run(std.io.getStdOut().writer());
}