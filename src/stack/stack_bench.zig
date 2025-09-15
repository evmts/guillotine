const std = @import("std");
const log = @import("../log.zig");
const zbench = @import("zbench");
const evm_mod = @import("evm");
const primitives = @import("primitives");
// MinimalEvm is now used for differential testing instead of revm
const crypto = @import("crypto");

const Stack = evm_mod.Stack;
const HashUtils = crypto.HashUtils;
const Address = primitives.Address.Address;
const ZERO_ADDRESS = primitives.ZERO_ADDRESS;
const TransactionContext = evm_mod.TransactionContext;
// u256 is a primitive type and should not be imported

// ============================================================================
// Configuration
// ============================================================================

const BENCHMARK_GAS_LIMIT: u64 = 100_000_000;
const CALLER_ADDRESS: Address = [_]u8{0x11} ** 20;
const CONTRACT_ADDRESS: Address = [_]u8{0x22} ** 20;

// ============================================================================
// Benchmark Registration
// ============================================================================

pub fn bench(b: *zbench.Benchmark) !void {
    // Basic Stack Operations
    try b.add("Stack: Push 500 values", bench_stack_push_500, .{});
    try b.add("Stack: Pop 500 values", bench_stack_pop_500, .{});
    try b.add("Stack: Unsafe Push/Pop 500 values", bench_stack_unsafe_operations, .{});
    
    // Stack Operations
    try b.add("Stack: DUP operations (100x)", bench_stack_dup, .{});
    try b.add("Stack: SWAP operations (100x)", bench_stack_swap, .{});
    try b.add("Stack: PEEK operations (1000x)", bench_stack_peek, .{});
    
    // Push/Pop Patterns
    try b.add("Stack: Direct Push/Pop 100 values", bench_direct_push_pop_100, .{});
    try b.add("Stack: Direct Push/Pop 1000 values", bench_direct_push_pop_1000, .{});
    
    // EVM Execution Benchmarks (currently disabled due to execution issues)
    // try b.add("EVM: Push/Pop 100 values", bench_evm_push_pop, .{});
    // try b.add("EVM: Large Stack (10 values)", bench_evm_large_stack, .{});
    
    // REVM Comparison Benchmarks
    // MinimalEvm benchmarks can be added here if needed
    // try b.add("MinimalEvm: Push/Pop 100 values", bench_minimal_push_pop, .{});
    // try b.add("MinimalEvm: Large Stack (10 values)", bench_minimal_large_stack, .{});
}

// ============================================================================
// Basic Stack Operations
// ============================================================================

fn bench_stack_push_500(allocator: std.mem.Allocator) void {
    var stack = Stack(.{
        .stack_size = std.math.maxInt(u12),
        .WordType = u256,
    }).init(allocator) catch |err| {
        log.err("Stack benchmark failed to init stack: {}", .{err});
        @panic("Stack benchmark failed");
    };
    defer stack.deinit(allocator);
    
    var i: u256 = 0;
    while (i < 500) : (i += 1) {
        stack.push(i) catch break;
    }
}

fn bench_stack_pop_500(allocator: std.mem.Allocator) void {
    var stack = Stack(.{
        .stack_size = std.math.maxInt(u12),
        .WordType = u256,
    }).init(allocator) catch |err| {
        log.err("Stack benchmark failed to init stack: {}", .{err});
        @panic("Stack benchmark failed");
    };
    defer stack.deinit(allocator);
    
    // Pre-fill stack
    var i: u256 = 0;
    while (i < 500) : (i += 1) {
        stack.push(i) catch break;
    }
    
    // Pop everything
    while (stack.size() > 0) {
        _ = stack.pop() catch break;
    }
}

fn bench_stack_unsafe_operations(allocator: std.mem.Allocator) void {
    var stack = Stack(.{
        .stack_size = std.math.maxInt(u12),
        .WordType = u256,
    }).init(allocator) catch |err| {
        log.err("Stack benchmark failed to init stack: {}", .{err});
        @panic("Stack benchmark failed");
    };
    defer stack.deinit(allocator);
    
    // Pre-fill stack with unsafe operations
    var i: u256 = 0;
    while (i < 500) : (i += 1) {
        stack.push_unsafe(i);
    }
    
    // Pop with unsafe operations
    while (stack.size() > 0) {
        _ = stack.pop_unsafe();
    }
}

// ============================================================================
// Stack Operations
// ============================================================================

fn bench_stack_dup(allocator: std.mem.Allocator) void {
    var stack = Stack(.{
        .stack_size = std.math.maxInt(u12),
        .WordType = u256,
    }).init(allocator) catch |err| {
        log.err("Stack benchmark failed to init stack: {}", .{err});
        @panic("Stack benchmark failed");
    };
    defer stack.deinit(allocator);
    
    // Pre-fill stack with some values
    var i: u256 = 0;
    while (i < 10) : (i += 1) {
        stack.push(i) catch break;
    }
    
    // Perform DUP operations
    i = 0;
    while (i < 100) : (i += 1) {
        stack.dup(1) catch break;
        _ = stack.pop() catch break; // Remove duplicated item
    }
}

fn bench_stack_swap(allocator: std.mem.Allocator) void {
    var stack = Stack(.{
        .stack_size = std.math.maxInt(u12),
        .WordType = u256,
    }).init(allocator) catch |err| {
        log.err("Stack benchmark failed to init stack: {}", .{err});
        @panic("Stack benchmark failed");
    };
    defer stack.deinit(allocator);
    
    // Pre-fill stack with values
    var i: u256 = 0;
    while (i < 10) : (i += 1) {
        stack.push(i) catch break;
    }
    
    // Perform SWAP operations
    i = 0;
    while (i < 100) : (i += 1) {
        stack.swap(1) catch break;
    }
}

fn bench_stack_peek(allocator: std.mem.Allocator) void {
    var stack = Stack(.{
        .stack_size = std.math.maxInt(u12),
        .WordType = u256,
    }).init(allocator) catch |err| {
        log.err("Stack benchmark failed to init stack: {}", .{err});
        @panic("Stack benchmark failed");
    };
    defer stack.deinit(allocator);
    
    // Pre-fill stack
    var i: u256 = 0;
    while (i < 100) : (i += 1) {
        stack.push(i) catch break;
    }
    
    // Perform peek operations
    i = 0;
    while (i < 1000) : (i += 1) {
        _ = stack.peek() catch break;
    }
}

// ============================================================================
// Direct Push/Pop Pattern Benchmarks
// ============================================================================

fn bench_direct_push_pop_100(allocator: std.mem.Allocator) void {
    var stack = Stack(.{
        .stack_size = std.math.maxInt(u12),
        .WordType = u256,
    }).init(allocator) catch |err| {
        log.err("Stack benchmark failed to init stack: {}", .{err});
        @panic("Stack benchmark failed");
    };
    defer stack.deinit(allocator);
    
    // Push values from 1000 to 100000 (in increments of 1000)
    var value: u256 = 1000;
    var count: u32 = 0;
    while (count < 100) : (count += 1) {
        stack.push_unsafe(value);
        value += 1000;
    }
    
    // Pop all 100 values
    count = 0;
    while (count < 100) : (count += 1) {
        _ = stack.pop_unsafe();
    }
}

fn bench_direct_push_pop_1000(allocator: std.mem.Allocator) void {
    var stack = Stack(.{
        .stack_size = std.math.maxInt(u12),
        .WordType = u256,
    }).init(allocator) catch |err| {
        log.err("Stack benchmark failed to init stack: {}", .{err});
        @panic("Stack benchmark failed");
    };
    defer stack.deinit(allocator);
    
    // Push 1000 values 
    var value: u256 = 1000;
    var count: u32 = 0;
    while (count < 1000) : (count += 1) {
        stack.push_unsafe(value);
        value += 1;
    }
    
    // Pop all 1000 values
    count = 0;
    while (count < 1000) : (count += 1) {
        _ = stack.pop_unsafe();
    }
}

// ============================================================================
// Bytecode Generation Helpers
// ============================================================================

fn generatePushPopBytecode(allocator: std.mem.Allocator) ![]u8 {
    // Create bytecode that pushes 100 values and then pops them
    const num_values = 100;
    const bytecode_size = num_values * 2 + num_values + 5; // 100 PUSH1s (2 bytes each) + 100 POPs + RETURN
    
    var bytecode = try allocator.alloc(u8, bytecode_size);
    var index: usize = 0;
    
    // Push 100 different values (1 to 100)
    var i: u8 = 1;
    while (i <= num_values) : (i += 1) {
        bytecode[index] = 0x60; // PUSH1
        index += 1;
        bytecode[index] = i; // value
        index += 1;
    }
    
    // Pop all 100 values
    i = 0;
    while (i < num_values) : (i += 1) {
        bytecode[index] = 0x50; // POP
        index += 1;
    }
    
    // Return empty result
    bytecode[index] = 0x60; // PUSH1
    index += 1;
    bytecode[index] = 0x00; // 0 (return size)
    index += 1;
    bytecode[index] = 0x60; // PUSH1
    index += 1;
    bytecode[index] = 0x00; // 0 (return offset)
    index += 1;
    bytecode[index] = 0xf3; // RETURN
    
    return bytecode;
}

fn generateLargeStackBytecode(allocator: std.mem.Allocator) ![]u8 {
    // Calculate bytecode size for 10 values
    var bytecode = try allocator.alloc(u8, 500);
    var index: usize = 0;
    
    // Push numbers from 1000 to 10000 (in increments of 1000) - only 10 values
    var value: u32 = 1000;
    while (value <= 10000) : (value += 1000) {
        // For values that fit in 2 bytes, use PUSH2
        if (value <= 0xFFFF) {
            bytecode[index] = 0x61; // PUSH2
            index += 1;
            bytecode[index] = @intCast((value >> 8) & 0xFF);
            index += 1;
            bytecode[index] = @intCast(value & 0xFF);
            index += 1;
        } else {
            // For larger values, use PUSH3
            bytecode[index] = 0x62; // PUSH3
            index += 1;
            bytecode[index] = @intCast((value >> 16) & 0xFF);
            index += 1;
            bytecode[index] = @intCast((value >> 8) & 0xFF);
            index += 1;
            bytecode[index] = @intCast(value & 0xFF);
            index += 1;
        }
    }
    
    // Now pop all 10 values
    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        bytecode[index] = 0x50; // POP
        index += 1;
    }
    
    // Return empty result
    bytecode[index] = 0x60; // PUSH1
    index += 1;
    bytecode[index] = 0x00; // 0 (return size)
    index += 1;
    bytecode[index] = 0x60; // PUSH1
    index += 1;
    bytecode[index] = 0x00; // 0 (return offset)
    index += 1;
    bytecode[index] = 0xf3; // RETURN
    index += 1;
    
    // Return only the used portion
    const result = try allocator.alloc(u8, index);
    @memcpy(result, bytecode[0..index]);
    allocator.free(bytecode);
    
    return result;
}

// ============================================================================
// EVM Execution Benchmarks
// ============================================================================

fn bench_evm_push_pop(allocator: std.mem.Allocator) void {
    // Generate bytecode
    const bytecode = generatePushPopBytecode(allocator) catch |err| {
        log.err("EVM push/pop benchmark failed to generate bytecode: {}", .{err});
        @panic("EVM push/pop benchmark failed");
    };
    defer allocator.free(bytecode);
    
    // Create memory database
    var db = evm_mod.Database.init(allocator);
    defer db.deinit();
    
    // Set up block info
    const block_info = evm_mod.BlockInfo{
        .chain_id = 1,
        .number = 1,
        .timestamp = 1640995200,
        .gas_limit = BENCHMARK_GAS_LIMIT,
        .difficulty = 0,
        .coinbase = ZERO_ADDRESS,
        .base_fee = 0,
        .prev_randao = [_]u8{0} ** 32,
    };
    
    // Set up transaction context
    const context = TransactionContext{
        .gas_limit = BENCHMARK_GAS_LIMIT,
        .coinbase = ZERO_ADDRESS,
        .chain_id = 1,
    };
    
    // Create EVM instance
    var vm = evm_mod.Evm(.{}).init(allocator, &db, block_info, context, 0, ZERO_ADDRESS, .CANCUN) catch |err| {
        log.err("EVM push/pop benchmark failed to init VM: {}", .{err});
        @panic("EVM push/pop benchmark failed");
    };
    defer vm.deinit();
    
    // Set up call parameters
    const call_params = evm_mod.CallParams{
        .call = .{
            .caller = CALLER_ADDRESS,
            .to = CONTRACT_ADDRESS,
            .value = 0,
            .input = &.{},
            .gas = BENCHMARK_GAS_LIMIT,
        },
    };
    
    // Deploy contract
    const code_hash = db.set_code(bytecode) catch |err| {
        log.err("EVM push/pop benchmark failed to set code: {}", .{err});
        @panic("EVM push/pop benchmark failed");
    };
    
    var account = db.get_account(CONTRACT_ADDRESS) catch null orelse evm_mod.Account{
        .balance = 0,
        .nonce = 0,
        .code_hash = HashUtils.EMPTY_KECCAK256,
        .storage_root = [_]u8{0} ** 32,
    };
    
    account.code_hash = code_hash;
    db.set_account(CONTRACT_ADDRESS, account) catch |err| {
        log.err("EVM push/pop benchmark failed to set account: {}", .{err});
        @panic("EVM push/pop benchmark failed");
    };
    
    // Execute the call
    const result = vm.call(call_params) catch |err| {
        log.err("EVM push/pop benchmark failed to call: {}", .{err});
        @panic("EVM push/pop benchmark failed");
    };
    _ = result;
}

fn bench_evm_large_stack(allocator: std.mem.Allocator) void {
    // Generate bytecode
    const bytecode = generateLargeStackBytecode(allocator) catch |err| {
        log.err("EVM large stack benchmark failed to generate bytecode: {}", .{err});
        @panic("EVM large stack benchmark failed");
    };
    defer allocator.free(bytecode);
    
    // Create memory database
    var db = evm_mod.Database.init(allocator);
    defer db.deinit();
    
    // Set up block info
    const block_info = evm_mod.BlockInfo{
        .chain_id = 1,
        .number = 1,
        .timestamp = 1640995200,
        .gas_limit = BENCHMARK_GAS_LIMIT,
        .difficulty = 0,
        .coinbase = ZERO_ADDRESS,
        .base_fee = 0,
        .prev_randao = [_]u8{0} ** 32,
    };
    
    // Set up transaction context
    const context = TransactionContext{
        .gas_limit = BENCHMARK_GAS_LIMIT,
        .coinbase = ZERO_ADDRESS,
        .chain_id = 1,
    };
    
    // Create EVM instance
    var vm = evm_mod.Evm(.{}).init(allocator, &db, block_info, context, 0, ZERO_ADDRESS, .CANCUN) catch |err| {
        log.err("EVM large stack benchmark failed to init VM: {}", .{err});
        @panic("EVM large stack benchmark failed");
    };
    defer vm.deinit();
    
    // Set up call parameters
    const call_params = evm_mod.CallParams{
        .call = .{
            .caller = CALLER_ADDRESS,
            .to = CONTRACT_ADDRESS,
            .value = 0,
            .input = &.{},
            .gas = BENCHMARK_GAS_LIMIT,
        },
    };
    
    // Deploy contract
    const code_hash = db.set_code(bytecode) catch |err| {
        log.err("EVM large stack benchmark failed to set code: {}", .{err});
        @panic("EVM large stack benchmark failed");
    };
    
    var account = db.get_account(CONTRACT_ADDRESS) catch null orelse evm_mod.Account{
        .balance = 0,
        .nonce = 0,
        .code_hash = HashUtils.EMPTY_KECCAK256,
        .storage_root = [_]u8{0} ** 32,
    };
    
    account.code_hash = code_hash;
    db.set_account(CONTRACT_ADDRESS, account) catch |err| {
        log.err("EVM large stack benchmark failed to set account: {}", .{err});
        @panic("EVM large stack benchmark failed");
    };
    
    // Execute the call
    const result = vm.call(call_params) catch |err| {
        log.err("EVM large stack benchmark failed to call: {}", .{err});
        @panic("EVM large stack benchmark failed");
    };
    _ = result;
}

// ============================================================================
// MinimalEvm Comparison Benchmarks (commented out - revm no longer used)
// ============================================================================

// MinimalEvm benchmarks can be added here if needed
// fn bench_minimal_push_pop(allocator: std.mem.Allocator) void {

// Original revm benchmark code (kept for reference but commented out):
/*
fn bench_revm_push_pop(allocator: std.mem.Allocator) void {
    // Generate bytecode
    const bytecode = generatePushPopBytecode(allocator) catch |err| {
        log.err("REVM push/pop benchmark failed to generate bytecode: {}", .{err});
        @panic("REVM push/pop benchmark failed");
    };
    defer allocator.free(bytecode);
    
    // Set up REVM
    const settings = revm.RevmSettings{
        .gas_limit = BENCHMARK_GAS_LIMIT,
        .chain_id = 1,
    };
    
    var vm = revm.Revm.init(allocator, settings) catch |err| {
        log.err("REVM push/pop benchmark failed to init VM: {}", .{err});
        @panic("REVM push/pop benchmark failed");
    };
    defer vm.deinit();
    
    // Deploy contract
    vm.setCode(CONTRACT_ADDRESS, bytecode) catch |err| {
        log.err("REVM push/pop benchmark failed to set code: {}", .{err});
        @panic("REVM push/pop benchmark failed");
    };
    
    // Set balance for caller
    vm.setBalance(CALLER_ADDRESS, 1000000) catch |err| {
        log.err("REVM push/pop benchmark failed to set balance: {}", .{err});
        @panic("REVM push/pop benchmark failed");
    };
    
    // Execute the call
    var result = vm.call(CALLER_ADDRESS, CONTRACT_ADDRESS, 0, &.{}, BENCHMARK_GAS_LIMIT) catch |err| {
        log.err("REVM push/pop benchmark failed to call: {}", .{err});
        @panic("REVM push/pop benchmark failed");
    };
    defer result.deinit();
}
*/

// Commented out second revm benchmark
/*
fn bench_revm_large_stack(allocator: std.mem.Allocator) void {
    // Generate bytecode
    const bytecode = generateLargeStackBytecode(allocator) catch |err| {
        log.err("REVM large stack benchmark failed to generate bytecode: {}", .{err});
        @panic("REVM large stack benchmark failed");
    };
    defer allocator.free(bytecode);
    
    // Set up REVM
    const settings = revm.RevmSettings{
        .gas_limit = BENCHMARK_GAS_LIMIT,
        .chain_id = 1,
    };
    
    var vm = revm.Revm.init(allocator, settings) catch |err| {
        log.err("REVM large stack benchmark failed to init VM: {}", .{err});
        @panic("REVM large stack benchmark failed");
    };
    defer vm.deinit();
    
    // Deploy contract
    vm.setCode(CONTRACT_ADDRESS, bytecode) catch |err| {
        log.err("REVM large stack benchmark failed to set code: {}", .{err});
        @panic("REVM large stack benchmark failed");
    };
    
    // Set balance for caller
    vm.setBalance(CALLER_ADDRESS, 1000000) catch |err| {
        log.err("REVM large stack benchmark failed to set balance: {}", .{err});
        @panic("REVM large stack benchmark failed");
    };
    
    // Execute the call
    var result = vm.call(CALLER_ADDRESS, CONTRACT_ADDRESS, 0, &.{}, BENCHMARK_GAS_LIMIT) catch |err| {
        log.err("REVM large stack benchmark failed to call: {}", .{err});
        @panic("REVM large stack benchmark failed");
    };
    defer result.deinit();
}
*/

// ============================================================================
// Tests
// ============================================================================

test "Push/pop bytecode generation" {
    const allocator = std.testing.allocator;
    
    const bytecode = try generatePushPopBytecode(allocator);
    defer allocator.free(bytecode);
    
    // Verify bytecode length: 100 PUSH1s (200 bytes) + 100 POPs (100 bytes) + 5 bytes for return = 305 bytes
    try std.testing.expectEqual(@as(usize, 305), bytecode.len);
    
    // Verify it starts with PUSH1 1 (0x60 0x01)
    try std.testing.expectEqual(@as(u8, 0x60), bytecode[0]);
    try std.testing.expectEqual(@as(u8, 0x01), bytecode[1]);
    
    // Verify it has POP after all pushes (at index 200)
    try std.testing.expectEqual(@as(u8, 0x50), bytecode[200]);
    
    // Verify it ends with RETURN (0xf3)
    try std.testing.expectEqual(@as(u8, 0xf3), bytecode[bytecode.len - 1]);
}

test "Large stack bytecode generation" {
    const allocator = std.testing.allocator;
    
    const bytecode = try generateLargeStackBytecode(allocator);
    defer allocator.free(bytecode);
    
    // Verify bytecode length
    // 10 pushes (3 bytes each) + 10 pops (1 byte each) + 5 bytes for return = 45 bytes
    try std.testing.expect(bytecode.len >= 45);
    try std.testing.expect(bytecode.len <= 50);
    
    // Verify it starts with PUSH2 1000 (0x61 0x03 0xE8)
    try std.testing.expectEqual(@as(u8, 0x61), bytecode[0]);
    try std.testing.expectEqual(@as(u8, 0x03), bytecode[1]);
    try std.testing.expectEqual(@as(u8, 0xE8), bytecode[2]);
    
    // Verify it ends with RETURN (0xf3)
    try std.testing.expectEqual(@as(u8, 0xf3), bytecode[bytecode.len - 1]);
}
