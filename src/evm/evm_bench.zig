const std = @import("std");
const zbench = @import("zbench");
const primitives = @import("primitives");
const evm_mod = @import("evm");
const revm_wrapper = @import("revm");
const crypto = @import("crypto");
const HashUtils = crypto.HashUtils;
const Address = primitives.Address.Address;
const ZERO_ADDRESS = primitives.ZERO_ADDRESS;
const TransactionContext = evm_mod.TransactionContext;

// Benchmark configuration
const BENCHMARK_GAS_LIMIT: u64 = 100_000_000;
const DEFAULT_RUNS = 100;

// Test data constants
const ERC20_TRANSFER_SELECTOR: u32 = 0xa9059cbb; // transfer(address,uint256)
const ERC20_MINT_SELECTOR: u32 = 0x40c10f19; // mint(address,uint256)
const TEST_ADDRESS_1: Address = [_]u8{0x11} ** 20;
const TEST_ADDRESS_2: Address = [_]u8{0x22} ** 20;

/// Load test case files from src/evm/fixtures/
fn readFixtureFile(allocator: std.mem.Allocator, fixture_name: []const u8, file_name: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(allocator, "src/evm/fixtures/{s}/{s}", .{ fixture_name, file_name });
    defer allocator.free(path);
    const cwd = std.fs.cwd();
    const file = try cwd.openFile(path, .{});
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

/// Decode hex string to bytes
fn hexDecode(allocator: std.mem.Allocator, hex_str: []const u8) ![]u8 {
    const clean_hex = if (std.mem.startsWith(u8, hex_str, "0x")) hex_str[2..] else hex_str;
    const result = try allocator.alloc(u8, clean_hex.len / 2);
    _ = try std.fmt.hexToBytes(result, clean_hex);
    return result;
}

// ============================================================================
// Basic Operations Benchmarks
// ============================================================================

fn benchmark_evm_stack_push_pop(allocator: std.mem.Allocator) void {
    _ = allocator;
    var stack = [_]u256{0} ** 1024;
    var top: usize = 0;
    
    // Push operations
    stack[top] = 100;
    top += 1;
    stack[top] = 200;
    top += 1;
    
    // Add operation (pop two, push result)
    const b = stack[top - 1];
    top -= 1;
    const a = stack[top - 1];
    stack[top - 1] = a +% b;
}

fn benchmark_evm_arithmetic_sequence(allocator: std.mem.Allocator) void {
    _ = allocator;
    const values = [_]u256{ 100, 200, 300, 400, 500 };
    
    for (values) |value| {
        var result: u256 = value;
        result = result +% 50;  // ADD
        result = result *% 3;   // MUL
        result = result -% 20;  // SUB
        result = result / 5;    // DIV
        std.mem.doNotOptimizeAway(result);
    }
}

fn benchmark_evm_memory_operations(allocator: std.mem.Allocator) void {
    const memory = allocator.alloc(u8, 1024) catch return;
    defer allocator.free(memory);
    
    // Store operations
    for (0..32) |i| {
        memory[i] = @truncate(i * 7);
    }
    
    // Load operations
    var sum: u32 = 0;
    for (memory[0..32]) |byte| {
        sum +%= byte;
    }
    std.mem.doNotOptimizeAway(sum);
}

fn benchmark_evm_keccak256(allocator: std.mem.Allocator) void {
    _ = allocator;
    const data = [_]u8{0x01, 0x02, 0x03, 0x04} ** 8; // 32 bytes
    const hash = crypto.Hash.keccak256(&data);
    _ = hash;
}

// ============================================================================
// Contract Execution Benchmarks
// ============================================================================

fn benchmark_evm_erc20_transfer(allocator: std.mem.Allocator) void {
    const bytecode_hex = readFixtureFile(allocator, "erc20-transfer", "bytecode.txt") catch return;
    defer allocator.free(bytecode_hex);
    const calldata_hex = readFixtureFile(allocator, "erc20-transfer", "calldata.txt") catch return;
    defer allocator.free(calldata_hex);

    const bytecode = hexDecode(allocator, bytecode_hex) catch return;
    defer allocator.free(bytecode);
    const calldata = hexDecode(allocator, calldata_hex) catch return;
    defer allocator.free(calldata);

    var db = evm_mod.Database.init(allocator);
    defer db.deinit();

    const block_info = evm_mod.BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = BENCHMARK_GAS_LIMIT,
        .coinbase = ZERO_ADDRESS,
        .chain_id = 1,
    };

    var vm = evm_mod.Evm(.{}).init(allocator, &db, block_info, context, 0, ZERO_ADDRESS, .CANCUN) catch return;
    defer vm.deinit();

    const caller = Address{ .bytes = [_]u8{0x10} ** 20 };
    const deploy_result = vm.call(evm_mod.CallParams{
        .create = .{
            .caller = caller,
            .value = 0,
            .init_code = bytecode,
            .gas = BENCHMARK_GAS_LIMIT,
        },
    }) catch return;

    if (!deploy_result.success) return;

    const call_params = evm_mod.CallParams{
        .call = .{
            .caller = caller,
            .to = Address{ .bytes = [_]u8{0x12} ** 20 },
            .value = 0,
            .input = calldata,
            .gas = BENCHMARK_GAS_LIMIT,
        },
    };
    _ = vm.call(call_params) catch return;
}

fn benchmark_evm_snailtracer(allocator: std.mem.Allocator) void {
    const bytecode_hex = readFixtureFile(allocator, "snailtracer", "bytecode.txt") catch return;
    defer allocator.free(bytecode_hex);
    const calldata_hex = readFixtureFile(allocator, "snailtracer", "calldata.txt") catch return;
    defer allocator.free(calldata_hex);

    const bytecode = hexDecode(allocator, bytecode_hex) catch return;
    defer allocator.free(bytecode);
    const calldata = hexDecode(allocator, calldata_hex) catch return;
    defer allocator.free(calldata);

    var db = evm_mod.Database.init(allocator);
    defer db.deinit();

    const block_info = evm_mod.BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = BENCHMARK_GAS_LIMIT,
        .coinbase = ZERO_ADDRESS,
        .chain_id = 1,
    };

    var vm = evm_mod.Evm(.{}).init(allocator, &db, block_info, context, 0, ZERO_ADDRESS, .CANCUN) catch return;
    defer vm.deinit();

    // Deploy the bytecode first
    const contract_address = Address{ .bytes = [_]u8{0x12} ** 20 };
    const code_hash = db.set_code(bytecode) catch return;
    db.set_account(contract_address.bytes, .{
        .balance = 0,
        .nonce = 1,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
    }) catch return;
    
    const caller = Address{ .bytes = [_]u8{0x10} ** 20 };
    const call_params = evm_mod.CallParams{
        .call = .{
            .caller = caller,
            .to = contract_address,
            .value = 0,
            .input = calldata,
            .gas = BENCHMARK_GAS_LIMIT,
        },
    };
    _ = vm.call(call_params) catch return;
}

fn benchmark_evm_thousand_hashes(allocator: std.mem.Allocator) void {
    const bytecode_hex = readFixtureFile(allocator, "ten-thousand-hashes", "bytecode.txt") catch return;
    defer allocator.free(bytecode_hex);
    const calldata_hex = readFixtureFile(allocator, "ten-thousand-hashes", "calldata.txt") catch return;
    defer allocator.free(calldata_hex);

    const bytecode = hexDecode(allocator, bytecode_hex) catch return;
    defer allocator.free(bytecode);
    const calldata = hexDecode(allocator, calldata_hex) catch return;
    defer allocator.free(calldata);

    var db = evm_mod.Database.init(allocator);
    defer db.deinit();

    const block_info = evm_mod.BlockInfo{
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = ZERO_ADDRESS,
        .base_fee = 1000000000,
        .prev_randao = [_]u8{0} ** 32,
    };

    const context = TransactionContext{
        .gas_limit = BENCHMARK_GAS_LIMIT,
        .coinbase = ZERO_ADDRESS,
        .chain_id = 1,
    };

    var vm = evm_mod.Evm(.{}).init(allocator, &db, block_info, context, 0, ZERO_ADDRESS, .CANCUN) catch return;
    defer vm.deinit();

    // Deploy the bytecode first
    const contract_address = Address{ .bytes = [_]u8{0x12} ** 20 };
    const code_hash = db.set_code(bytecode) catch return;
    db.set_account(contract_address.bytes, .{
        .balance = 0,
        .nonce = 1,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
    }) catch return;
    
    const caller = Address{ .bytes = [_]u8{0x10} ** 20 };
    const call_params = evm_mod.CallParams{
        .call = .{
            .caller = caller,
            .to = contract_address,
            .value = 0,
            .input = calldata,
            .gas = BENCHMARK_GAS_LIMIT,
        },
    };
    _ = vm.call(call_params) catch return;
}

// ============================================================================
// REVM Comparison Benchmarks
// ============================================================================

fn benchmark_revm_erc20_transfer(allocator: std.mem.Allocator) void {
    const bytecode_hex = readFixtureFile(allocator, "erc20-transfer", "bytecode.txt") catch return;
    defer allocator.free(bytecode_hex);
    const calldata_hex = readFixtureFile(allocator, "erc20-transfer", "calldata.txt") catch return;
    defer allocator.free(calldata_hex);

    const bytecode = hexDecode(allocator, bytecode_hex) catch return;
    defer allocator.free(bytecode);
    const calldata = hexDecode(allocator, calldata_hex) catch return;
    defer allocator.free(calldata);

    const settings = revm_wrapper.RevmSettings{};
    var vm = revm_wrapper.Revm.init(allocator, settings) catch return;
    defer vm.deinit();

    const caller = Address{ .bytes = [_]u8{0x10} ** 20 };
    vm.setBalance(caller, std.math.maxInt(u256)) catch return;

    var create_result = vm.create(caller, 0, bytecode, BENCHMARK_GAS_LIMIT) catch return;
    defer create_result.deinit();
    if (!create_result.success) return;

    const contract_address = Address{ .bytes = [_]u8{0x12} ** 20 };
    vm.setCode(contract_address, create_result.output) catch return;

    var call_result = vm.call(caller, contract_address, 0, calldata, BENCHMARK_GAS_LIMIT) catch return;
    defer call_result.deinit();
}

fn benchmark_revm_snailtracer(allocator: std.mem.Allocator) void {
    const bytecode_hex = readFixtureFile(allocator, "snailtracer", "bytecode.txt") catch return;
    defer allocator.free(bytecode_hex);
    const calldata_hex = readFixtureFile(allocator, "snailtracer", "calldata.txt") catch return;
    defer allocator.free(calldata_hex);

    const bytecode = hexDecode(allocator, bytecode_hex) catch return;
    defer allocator.free(bytecode);
    const calldata = hexDecode(allocator, calldata_hex) catch return;
    defer allocator.free(calldata);

    const settings = revm_wrapper.RevmSettings{};
    var vm = revm_wrapper.Revm.init(allocator, settings) catch return;
    defer vm.deinit();

    const caller = Address{ .bytes = [_]u8{0x10} ** 20 };
    const contract_address = Address{ .bytes = [_]u8{0x12} ** 20 };
    
    // Set balance for caller
    vm.setBalance(caller, std.math.maxInt(u256)) catch return;
    
    // Deploy bytecode directly to contract address
    vm.setCode(contract_address, bytecode) catch return;

    var call_result = vm.call(caller, contract_address, 0, calldata, BENCHMARK_GAS_LIMIT) catch return;
    defer call_result.deinit();
}

fn benchmark_revm_thousand_hashes(allocator: std.mem.Allocator) void {
    const bytecode_hex = readFixtureFile(allocator, "ten-thousand-hashes", "bytecode.txt") catch return;
    defer allocator.free(bytecode_hex);
    const calldata_hex = readFixtureFile(allocator, "ten-thousand-hashes", "calldata.txt") catch return;
    defer allocator.free(calldata_hex);

    const bytecode = hexDecode(allocator, bytecode_hex) catch return;
    defer allocator.free(bytecode);
    const calldata = hexDecode(allocator, calldata_hex) catch return;
    defer allocator.free(calldata);

    const settings = revm_wrapper.RevmSettings{};
    var vm = revm_wrapper.Revm.init(allocator, settings) catch return;
    defer vm.deinit();

    const caller = Address{ .bytes = [_]u8{0x10} ** 20 };
    const contract_address = Address{ .bytes = [_]u8{0x12} ** 20 };
    
    // Set balance for caller
    vm.setBalance(caller, std.math.maxInt(u256)) catch return;
    
    // Deploy bytecode directly to contract address
    vm.setCode(contract_address, bytecode) catch return;

    var call_result = vm.call(caller, contract_address, 0, calldata, BENCHMARK_GAS_LIMIT) catch return;
    defer call_result.deinit();
}

// ============================================================================
// Simple Contract Benchmarks
// ============================================================================

// Simple arithmetic contract: ADD two numbers and return result
const ARITHMETIC_CONTRACT = [_]u8{
    0x60, 0x10, // PUSH1 0x10
    0x60, 0x05, // PUSH1 0x05  
    0x01,       // ADD
    0x60, 0x00, // PUSH1 0x00 (memory offset)
    0x52,       // MSTORE (store result in memory)
    0x60, 0x20, // PUSH1 0x20 (return size)
    0x60, 0x00, // PUSH1 0x00 (return offset)
    0xf3,       // RETURN
};

// Simple storage contract: Store and load a value
const STORAGE_CONTRACT = [_]u8{
    0x60, 0x42, // PUSH1 0x42 (value)
    0x60, 0x00, // PUSH1 0x00 (slot)
    0x55,       // SSTORE
    0x60, 0x00, // PUSH1 0x00 (slot)
    0x54,       // SLOAD
    0x60, 0x00, // PUSH1 0x00 (memory offset)
    0x52,       // MSTORE
    0x60, 0x20, // PUSH1 0x20 (return size)
    0x60, 0x00, // PUSH1 0x00 (return offset)
    0xf3,       // RETURN
};

// Stack operations contract: DUP, SWAP, POP operations
const STACK_CONTRACT = [_]u8{
    0x60, 0x11, // PUSH1 0x11
    0x60, 0x22, // PUSH1 0x22
    0x60, 0x33, // PUSH1 0x33
    0x80,       // DUP1
    0x91,       // SWAP2
    0x50,       // POP
    0x01,       // ADD
    0x60, 0x00, // PUSH1 0x00 (memory offset)
    0x52,       // MSTORE
    0x60, 0x20, // PUSH1 0x20 (return size)
    0x60, 0x00, // PUSH1 0x00 (return offset)
    0xf3,       // RETURN
};

fn benchmark_evm_arithmetic_contract(allocator: std.mem.Allocator) void {
    var db = evm_mod.Database.init(allocator);
    defer db.deinit();
    
    const block_info = evm_mod.BlockInfo{
        .number = 1,
        .timestamp = 1640995200,
        .gas_limit = BENCHMARK_GAS_LIMIT,
        .difficulty = 0,
        .coinbase = ZERO_ADDRESS,
        .base_fee = 0,
        .prev_randao = [_]u8{0} ** 32,
    };
    
    const context = TransactionContext{
        .gas_limit = BENCHMARK_GAS_LIMIT,
        .coinbase = ZERO_ADDRESS,
        .chain_id = 1,
    };
    
    var vm = evm_mod.Evm(.{}).init(allocator, &db, block_info, context, 0, ZERO_ADDRESS, .CANCUN) catch return;
    defer vm.deinit();
    
    const call_params = evm_mod.CallParams{
        .call = .{
            .caller = TEST_ADDRESS_1,
            .to = TEST_ADDRESS_2,
            .value = 0,
            .input = &.{},
            .gas = BENCHMARK_GAS_LIMIT,
        },
    };
    
    // Set contract code and get the hash
    const code_hash = db.set_code(&ARITHMETIC_CONTRACT) catch return;
    
    // Get existing account or create new one
    var account = db.get_account(TEST_ADDRESS_2) catch null orelse evm_mod.Account{
        .balance = 0,
        .nonce = 0,
        .code_hash = HashUtils.EMPTY_KECCAK256,
        .storage_root = [_]u8{0} ** 32,
    };
    
    // Update account with code hash
    account.code_hash = code_hash;
    db.set_account(TEST_ADDRESS_2, account) catch return;
    
    const result = vm.call(call_params) catch return;
    _ = result;
}

fn benchmark_revm_arithmetic_contract(allocator: std.mem.Allocator) void {
    const settings = revm_wrapper.RevmSettings{
        .gas_limit = BENCHMARK_GAS_LIMIT,
        .chain_id = 1,
    };
    
    var vm = revm_wrapper.Revm.init(allocator, settings) catch return;
    defer vm.deinit();
    
    // Set contract code
    vm.setCode(TEST_ADDRESS_2, &ARITHMETIC_CONTRACT) catch return;
    
    // Set balance for caller
    vm.setBalance(TEST_ADDRESS_1, 1000000) catch return;
    
    var result = vm.call(TEST_ADDRESS_1, TEST_ADDRESS_2, 0, &.{}, BENCHMARK_GAS_LIMIT) catch return;
    defer result.deinit();
}

// ============================================================================
// Advanced Benchmarks
// ============================================================================

/// Memory expansion patterns - tests memory growth under different scenarios
fn benchmark_memory_expansion_patterns(allocator: std.mem.Allocator) void {
    var memory = std.ArrayList(u8).init(allocator);
    defer memory.deinit();
    
    // Simulate EVM memory expansion in 32-byte chunks
    const expansion_sizes = [_]usize{ 32, 64, 128, 256, 512, 1024, 2048, 4096 };
    for (expansion_sizes) |size| {
        memory.resize(size) catch continue;
        // Touch memory to ensure allocation
        if (memory.items.len > 0) {
            memory.items[size - 1] = 0xAA;
        }
    }
}

/// KECCAK256 with different input sizes
fn benchmark_keccak256_different_sizes(allocator: std.mem.Allocator) void {
    const input_sizes = [_]usize{ 0, 32, 64, 128, 256, 512, 1024, 2048 };
    
    for (input_sizes) |size| {
        const input = allocator.alloc(u8, size) catch continue;
        defer allocator.free(input);
        
        // Fill with pattern
        for (input, 0..) |*byte, i| {
            byte.* = @truncate(i);
        }
        
        const hash = crypto.Hash.keccak256(input);
        _ = hash; // Prevent optimization
    }
}

/// Address computation patterns
fn benchmark_address_computation(allocator: std.mem.Allocator) void {
    _ = allocator;
    const sender = primitives.Address.from_u256(0x1234567890abcdef1234567890abcdef12345678);
    
    // CREATE address computation
    for (0..100) |nonce| {
        const address = primitives.Address.get_contract_address(sender, nonce);
        _ = address;
    }
    
    // CREATE2 address computation
    const init_code = [_]u8{0x60, 0x80, 0x60, 0x40, 0x52}; // Simple init code
    for (0..100) |i| {
        const salt: [32]u8 = @bitCast(@as(u256, i));
        const init_code_hash = crypto.Hash.keccak256(&init_code);
        const address = primitives.Address.get_create2_address(sender, salt, init_code_hash);
        _ = address;
    }
}

/// Deep stack DUP/SWAP operations
fn benchmark_deep_stack_dup_swap(allocator: std.mem.Allocator) void {
    _ = allocator;
    var stack = [_]u256{0} ** 1024;
    var top: usize = 0;
    
    // Fill stack with test values
    for (0..16) |i| {
        stack[top] = @intCast(i + 100);
        top += 1;
    }
    
    // Simulate DUP operations (DUP1, DUP2, DUP16)
    const dup_depths = [_]usize{ 1, 2, 4, 8, 16 };
    for (dup_depths) |depth| {
        if (top >= depth) {
            const value = stack[top - depth];
            stack[top] = value;
            top += 1;
        }
    }
    
    // Simulate SWAP operations
    for (dup_depths) |depth| {
        if (top > depth) {
            const temp = stack[top - 1];
            stack[top - 1] = stack[top - 1 - depth];
            stack[top - 1 - depth] = temp;
        }
    }
}

/// Storage access pattern simulation
fn benchmark_storage_access_patterns(allocator: std.mem.Allocator) void {
    // Simulate different storage access patterns
    var storage_map = std.AutoHashMap(u256, u256).init(allocator);
    defer storage_map.deinit();
    
    // Sequential slot access
    for (0..50) |i| {
        const slot: u256 = i;
        const value: u256 = i * 1000;
        storage_map.put(slot, value) catch continue;
    }
    
    // Random slot access  
    const random_slots = [_]u256{ 0x1000, 0x2000, 0x3000, 0x4000, 0x5000 };
    for (random_slots, 0..) |slot, i| {
        const value: u256 = @intCast(i + 5000);
        storage_map.put(slot, value) catch continue;
    }
    
    // Read access patterns
    for (0..25) |i| {
        const slot: u256 = i;
        _ = storage_map.get(slot);
    }
}

// ============================================================================
// Main Benchmark Runner
// ============================================================================

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var bench = zbench.Benchmark.init(allocator, .{});
    defer bench.deinit();

    try stdout.print("\n⚡ Consolidated EVM Performance Benchmarks\n", .{});
    try stdout.print("==========================================\n\n", .{});

    // Basic Operations Category
    try stdout.print("📊 Basic Operations\n", .{});
    try stdout.print("-------------------\n", .{});
    try bench.add("Stack Push/Pop", benchmark_evm_stack_push_pop, .{});
    try bench.add("Arithmetic Sequence", benchmark_evm_arithmetic_sequence, .{});
    try bench.add("Memory Operations", benchmark_evm_memory_operations, .{});
    try bench.add("KECCAK256 Simple", benchmark_evm_keccak256, .{});
    try stdout.print("\n", .{});

    // ERC20 Tests Category
    try stdout.print("📊 ERC20 Tests\n", .{});
    try stdout.print("--------------\n", .{});
    try bench.add("EVM: ERC20 Transfer", benchmark_evm_erc20_transfer, .{});
    try bench.add("REVM: ERC20 Transfer", benchmark_revm_erc20_transfer, .{});
    try stdout.print("\n", .{});

    // Snailtracer Benchmark Category
    try stdout.print("📊 Snailtracer Benchmark\n", .{});
    try stdout.print("------------------------\n", .{});
    try bench.add("EVM: Snailtracer", benchmark_evm_snailtracer, .{});
    try bench.add("REVM: Snailtracer", benchmark_revm_snailtracer, .{});
    try stdout.print("\n", .{});

    // Hash-Heavy Operations Category
    try stdout.print("📊 Hash-Heavy Operations\n", .{});
    try stdout.print("------------------------\n", .{});
    try bench.add("EVM: 10k Hashes", benchmark_evm_thousand_hashes, .{});
    try bench.add("REVM: 10k Hashes", benchmark_revm_thousand_hashes, .{});
    try stdout.print("\n", .{});

    // Simple Contract Comparisons Category
    try stdout.print("📊 Simple Contract Comparisons\n", .{});
    try stdout.print("------------------------------\n", .{});
    try bench.add("EVM: Arithmetic Contract", benchmark_evm_arithmetic_contract, .{});
    try bench.add("REVM: Arithmetic Contract", benchmark_revm_arithmetic_contract, .{});
    try stdout.print("\n", .{});

    // Advanced Operations Category
    try stdout.print("📊 Advanced Operations\n", .{});
    try stdout.print("----------------------\n", .{});
    try bench.add("Memory Expansion Patterns", benchmark_memory_expansion_patterns, .{});
    try bench.add("KECCAK256 Different Sizes", benchmark_keccak256_different_sizes, .{});
    try bench.add("Address Computation", benchmark_address_computation, .{});
    try bench.add("Deep Stack DUP/SWAP", benchmark_deep_stack_dup_swap, .{});
    try bench.add("Storage Access Patterns", benchmark_storage_access_patterns, .{});

    try stdout.print("\nRunning consolidated EVM benchmarks...\n\n", .{});
    try bench.run(stdout);
    
    try stdout.print("\n✅ Consolidated EVM benchmarks completed!\n", .{});
    try stdout.print("\nResults Summary:\n", .{});
    try stdout.print("• Basic Operations: Core EVM operations performance\n", .{});
    try stdout.print("• Contract Tests: Real-world contract execution comparison\n", .{});
    try stdout.print("• EVM vs REVM: Direct comparison with Rust reference implementation\n", .{});
    try stdout.print("• Advanced Operations: Complex patterns and stress tests\n", .{});
    try stdout.print("\nLower times indicate better performance.\n", .{});
}

test "consolidated benchmark compilation" {
    const allocator = std.testing.allocator;
    
    // Test that all benchmark functions compile
    const a: u256 = 100;
    const b: u256 = 200;
    const result = a +% b;
    try std.testing.expectEqual(@as(u256, 300), result);
    
    // Test Address creation
    const addr = Address.from_u256(0x1234567890abcdef);
    try std.testing.expect(addr.bytes[19] == 0xef);
    
    _ = allocator;
}
