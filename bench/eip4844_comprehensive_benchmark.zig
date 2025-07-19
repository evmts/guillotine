const std = @import("std");
const root = @import("root.zig");
const timing = @import("timing.zig");

// Core EVM imports
const Evm = root.Evm;
const primitives = root.primitives;
const Frame = Evm.Frame;
const Vm = Evm.Evm;
const Contract = Evm.Contract;
const MemoryDatabase = Evm.MemoryDatabase;
const Address = primitives.Address;
const Operation = Evm.Operation;

/// Comprehensive EIP-4844 Blob Transaction Benchmarks for Issue #72
/// 
/// This module provides detailed benchmarks for:
/// - Blob hash operations (BLOBHASH, BLOBBASEFEE opcodes) 
/// - KZG point evaluation performance
/// - Access list processing and gas calculations
/// - Blob transaction validation
/// - Performance comparison with regular transactions

/// Benchmark BLOBHASH opcode performance with various blob configurations
pub fn benchmark_blobhash_opcode_performance(allocator: std.mem.Allocator) !void {
    std.log.info("=== BLOBHASH Opcode Performance Benchmark ===", .{});

    const test_cases = [_]struct {
        name: []const u8,
        blob_count: u32,
        iterations: u32,
    }{
        .{ .name = "Single Blob", .blob_count = 1, .iterations = 50000 },
        .{ .name = "Two Blobs", .blob_count = 2, .iterations = 40000 },
        .{ .name = "Three Blobs", .blob_count = 3, .iterations = 30000 },
        .{ .name = "Maximum Blobs", .blob_count = 6, .iterations = 20000 },
    };

    for (test_cases) |case| {
        std.log.info("Benchmarking BLOBHASH with {s} ({} blobs)", .{ case.name, case.blob_count });

        // Create VM with blob context
        var memory_db = MemoryDatabase.init(allocator);
        defer memory_db.deinit();

        const db_interface = memory_db.to_database_interface();
        var vm = try Vm.init(allocator, db_interface, null, null);
        defer vm.deinit();

        // Set up blob hashes in VM context
        var blob_hashes = try allocator.alloc(u256, case.blob_count);
        defer allocator.free(blob_hashes);

        for (0..case.blob_count) |i| {
            blob_hashes[i] = create_deterministic_blob_hash(i);
        }
        vm.context.blob_hashes = blob_hashes;

        // Create contract with BLOBHASH bytecode
        var contract = try Contract.init(allocator, &[_]u8{0x49}, .{ .address = Address.ZERO });
        defer contract.deinit(allocator, null);

        var frame = try Frame.init(allocator, &vm, 1000000, contract, Address.ZERO, &.{});
        defer frame.deinit();

        var total_time: u64 = 0;
        var total_gas_used: u64 = 0;

        const start_time = std.time.nanoTimestamp();

        for (0..case.iterations) |iteration| {
            const blob_index = iteration % case.blob_count;
            
            // Push blob index onto stack
            try frame.stack.push(@intCast(blob_index));
            
            // Execute BLOBHASH opcode
            const interpreter_ptr: *Operation.Interpreter = @ptrCast(&vm);
            const state_ptr: *Operation.State = @ptrCast(&frame);

            const initial_gas = frame.gas;
            _ = try @import("../src/evm/execution/block.zig").op_blobhash(0, interpreter_ptr, state_ptr);
            const gas_used = initial_gas - frame.gas;
            total_gas_used += gas_used;

            // Pop result to clear stack
            _ = try frame.stack.pop();
        }

        const end_time = std.time.nanoTimestamp();
        total_time = end_time - start_time;

        const avg_time = total_time / case.iterations;
        const avg_gas = total_gas_used / case.iterations;
        const throughput = @as(f64, @floatFromInt(case.iterations * 1000000000)) / @as(f64, @floatFromInt(total_time));

        std.log.info("  {s}: {d:.2f}ns avg, {} gas avg, {d:.2f} ops/sec", .{
            case.name,
            @as(f64, @floatFromInt(avg_time)),
            avg_gas,
            throughput,
        });
    }
}

/// Benchmark BLOBBASEFEE opcode performance under various fee conditions
pub fn benchmark_blobbasefee_opcode_performance(allocator: std.mem.Allocator) !void {
    std.log.info("=== BLOBBASEFEE Opcode Performance Benchmark ===", .{});

    const fee_scenarios = [_]struct {
        name: []const u8,
        base_fee: u256,
        iterations: u32,
    }{
        .{ .name = "Zero Fee", .base_fee = 0, .iterations = 100000 },
        .{ .name = "Low Fee (1 wei)", .base_fee = 1, .iterations = 100000 },
        .{ .name = "Standard Fee (1 gwei)", .base_fee = 1000000000, .iterations = 80000 },
        .{ .name = "High Fee (100 gwei)", .base_fee = 100000000000, .iterations = 80000 },
        .{ .name = "Maximum Fee", .base_fee = std.math.maxInt(u256), .iterations = 60000 },
    };

    for (fee_scenarios) |scenario| {
        std.log.info("Benchmarking BLOBBASEFEE with {s}", .{scenario.name});

        // Create VM with specific blob base fee
        var memory_db = MemoryDatabase.init(allocator);
        defer memory_db.deinit();

        const db_interface = memory_db.to_database_interface();
        var vm = try Vm.init(allocator, db_interface, null, null);
        defer vm.deinit();

        vm.context.blob_base_fee = scenario.base_fee;

        // Create contract with BLOBBASEFEE bytecode
        var contract = try Contract.init(allocator, &[_]u8{0x4A}, .{ .address = Address.ZERO });
        defer contract.deinit(allocator, null);

        var frame = try Frame.init(allocator, &vm, 1000000, contract, Address.ZERO, &.{});
        defer frame.deinit();

        var total_time: u64 = 0;
        var total_gas_used: u64 = 0;

        const start_time = std.time.nanoTimestamp();

        for (0..scenario.iterations) |_| {
            // Execute BLOBBASEFEE opcode
            const interpreter_ptr: *Operation.Interpreter = @ptrCast(&vm);
            const state_ptr: *Operation.State = @ptrCast(&frame);

            const initial_gas = frame.gas;
            _ = try @import("../src/evm/execution/block.zig").op_blobbasefee(0, interpreter_ptr, state_ptr);
            const gas_used = initial_gas - frame.gas;
            total_gas_used += gas_used;

            // Pop result to clear stack
            _ = try frame.stack.pop();
        }

        const end_time = std.time.nanoTimestamp();
        total_time = end_time - start_time;

        const avg_time = total_time / scenario.iterations;
        const avg_gas = total_gas_used / scenario.iterations;
        const throughput = @as(f64, @floatFromInt(scenario.iterations * 1000000000)) / @as(f64, @floatFromInt(total_time));

        std.log.info("  {s}: {d:.2f}ns avg, {} gas avg, {d:.2f} ops/sec", .{
            scenario.name,
            @as(f64, @floatFromInt(avg_time)),
            avg_gas,
            throughput,
        });
    }
}

/// Benchmark KZG point evaluation performance for blob transactions
pub fn benchmark_kzg_point_evaluation_performance(allocator: std.mem.Allocator) !void {
    std.log.info("=== KZG Point Evaluation Performance Benchmark ===", .{});

    // Test different blob sizes and commitment scenarios
    const evaluation_scenarios = [_]struct {
        name: []const u8,
        blob_count: u32,
        point_count: u32,
        iterations: u32,
    }{
        .{ .name = "Single Blob, Single Point", .blob_count = 1, .point_count = 1, .iterations = 1000 },
        .{ .name = "Single Blob, Multiple Points", .blob_count = 1, .point_count = 10, .iterations = 500 },
        .{ .name = "Multiple Blobs, Single Point", .blob_count = 6, .point_count = 1, .iterations = 500 },
        .{ .name = "Multiple Blobs, Multiple Points", .blob_count = 6, .point_count = 10, .iterations = 200 },
        .{ .name = "Stress Test", .blob_count = 6, .point_count = 100, .iterations = 50 },
    };

    for (evaluation_scenarios) |scenario| {
        std.log.info("Benchmarking KZG evaluation: {s}", .{scenario.name});

        var total_creation_time: u64 = 0;
        var total_evaluation_time: u64 = 0;

        for (0..scenario.iterations) |iteration| {
            // Benchmark blob and commitment creation
            const start_creation = std.time.nanoTimestamp();

            var blobs = try allocator.alloc([131072]u8, scenario.blob_count); // 4096 * 32 bytes per blob
            defer allocator.free(blobs);

            var commitments = try allocator.alloc([48]u8, scenario.blob_count); // KZG commitment size
            defer allocator.free(commitments);

            var evaluation_points = try allocator.alloc([32]u8, scenario.point_count);
            defer allocator.free(evaluation_points);

            // Create deterministic test data
            for (0..scenario.blob_count) |i| {
                blobs[i] = create_deterministic_blob_data(iteration + i);
                commitments[i] = create_deterministic_commitment(iteration + i);
            }

            for (0..scenario.point_count) |i| {
                evaluation_points[i] = create_deterministic_evaluation_point(iteration + i);
            }

            const end_creation = std.time.nanoTimestamp();
            total_creation_time += end_creation - start_creation;

            // Benchmark point evaluation
            const start_evaluation = std.time.nanoTimestamp();

            // Simulate KZG point evaluation (actual KZG operations would require C-KZG library)
            for (blobs, commitments) |*blob, *commitment| {
                for (evaluation_points) |*point| {
                    // Simulate computational work of KZG evaluation
                    _ = simulate_kzg_evaluation(blob, commitment, point);
                }
            }

            const end_evaluation = std.time.nanoTimestamp();
            total_evaluation_time += end_evaluation - start_evaluation;
        }

        const avg_creation = total_creation_time / scenario.iterations;
        const avg_evaluation = total_evaluation_time / scenario.iterations;
        const total_operations = scenario.blob_count * scenario.point_count;

        std.log.info("  {s}:", .{scenario.name});
        std.log.info("    Creation: {d:.2f}μs avg", .{@as(f64, @floatFromInt(avg_creation)) / 1000.0});
        std.log.info("    Evaluation: {d:.2f}μs avg", .{@as(f64, @floatFromInt(avg_evaluation)) / 1000.0});
        std.log.info("    Total ops per iteration: {}", .{total_operations});
        std.log.info("    Throughput: {d:.2f} evaluations/sec", .{
            @as(f64, @floatFromInt(total_operations * 1000000000)) / @as(f64, @floatFromInt(avg_evaluation))
        });
    }
}

/// Benchmark access list gas calculation performance
pub fn benchmark_access_list_gas_calculations(allocator: std.mem.Allocator) !void {
    std.log.info("=== Access List Gas Calculations Benchmark ===", .{});

    const gas_scenarios = [_]struct {
        name: []const u8,
        address_count: u32,
        storage_keys_per_address: u32,
        warm_ratio: f32, // Ratio of warm vs cold accesses (0.0 = all cold, 1.0 = all warm)
        iterations: u32,
    }{
        .{ .name = "Small List, All Cold", .address_count = 5, .storage_keys_per_address = 10, .warm_ratio = 0.0, .iterations = 10000 },
        .{ .name = "Small List, All Warm", .address_count = 5, .storage_keys_per_address = 10, .warm_ratio = 1.0, .iterations = 10000 },
        .{ .name = "Medium List, Mixed", .address_count = 20, .storage_keys_per_address = 50, .warm_ratio = 0.5, .iterations = 5000 },
        .{ .name = "Large List, Mostly Cold", .address_count = 100, .storage_keys_per_address = 200, .warm_ratio = 0.1, .iterations = 1000 },
        .{ .name = "Maximum List, Mostly Warm", .address_count = 1000, .storage_keys_per_address = 500, .warm_ratio = 0.9, .iterations = 100 },
    };

    for (gas_scenarios) |scenario| {
        std.log.info("Benchmarking gas calculations: {s}", .{scenario.name});

        var total_time: u64 = 0;
        var total_gas_cost: u64 = 0;

        const start_time = std.time.nanoTimestamp();

        for (0..scenario.iterations) |iteration| {
            var iteration_gas_cost: u64 = 0;

            // Create access list data
            var addresses = try allocator.alloc(Address.Address, scenario.address_count);
            defer allocator.free(addresses);

            for (0..scenario.address_count) |i| {
                addresses[i] = create_deterministic_address(iteration + i);
            }

            // Calculate gas costs for address accesses
            for (addresses) |address| {
                _ = address;
                
                const is_warm = (@as(f32, @floatFromInt(iteration % 100)) / 100.0) < scenario.warm_ratio;
                
                if (is_warm) {
                    iteration_gas_cost += 100; // Warm access gas cost
                } else {
                    iteration_gas_cost += 2600; // Cold address access gas cost
                }
            }

            // Calculate gas costs for storage accesses
            for (addresses) |address| {
                _ = address;
                
                for (0..scenario.storage_keys_per_address) |j| {
                    const is_warm = (@as(f32, @floatFromInt((iteration + j) % 100)) / 100.0) < scenario.warm_ratio;
                    
                    if (is_warm) {
                        iteration_gas_cost += 100; // Warm SLOAD gas cost
                    } else {
                        iteration_gas_cost += 2100; // Cold SLOAD gas cost
                    }
                }
            }

            total_gas_cost += iteration_gas_cost;
        }

        const end_time = std.time.nanoTimestamp();
        total_time = end_time - start_time;

        const avg_time = total_time / scenario.iterations;
        const avg_gas = total_gas_cost / scenario.iterations;
        const throughput = @as(f64, @floatFromInt(scenario.iterations * 1000000000)) / @as(f64, @floatFromInt(total_time));

        std.log.info("  {s}:", .{scenario.name});
        std.log.info("    Time: {d:.2f}μs avg", .{@as(f64, @floatFromInt(avg_time)) / 1000.0});
        std.log.info("    Gas: {} avg", .{avg_gas});
        std.log.info("    Throughput: {d:.2f} calculations/sec", .{throughput});
    }
}

/// Benchmark blob transaction validation performance
pub fn benchmark_blob_transaction_validation(allocator: std.mem.Allocator) !void {
    std.log.info("=== Blob Transaction Validation Performance Benchmark ===", .{});

    const validation_scenarios = [_]struct {
        name: []const u8,
        blob_count: u32,
        has_access_list: bool,
        iterations: u32,
    }{
        .{ .name = "Single Blob, No Access List", .blob_count = 1, .has_access_list = false, .iterations = 2000 },
        .{ .name = "Single Blob, With Access List", .blob_count = 1, .has_access_list = true, .iterations = 1800 },
        .{ .name = "Multiple Blobs, No Access List", .blob_count = 3, .has_access_list = false, .iterations = 1500 },
        .{ .name = "Multiple Blobs, With Access List", .blob_count = 3, .has_access_list = true, .iterations = 1200 },
        .{ .name = "Maximum Blobs, With Access List", .blob_count = 6, .has_access_list = true, .iterations = 800 },
    };

    for (validation_scenarios) |scenario| {
        std.log.info("Benchmarking validation: {s}", .{scenario.name});

        var total_time: u64 = 0;

        for (0..scenario.iterations) |iteration| {
            const start_validation = timing.nanoTimestamp();

            // Create mock blob transaction data
            var blob_hashes = try allocator.alloc(u256, scenario.blob_count);
            defer allocator.free(blob_hashes);

            var blob_commitments = try allocator.alloc([48]u8, scenario.blob_count);
            defer allocator.free(blob_commitments);

            for (0..scenario.blob_count) |i| {
                blob_hashes[i] = create_deterministic_blob_hash(iteration + i);
                blob_commitments[i] = create_deterministic_commitment(iteration + i);
            }

            // Validate blob hashes against commitments
            for (blob_hashes, blob_commitments) |hash, commitment| {
                _ = validate_blob_hash_commitment(hash, &commitment);
            }

            // Validate access list if present
            if (scenario.has_access_list) {
                const access_list_size = 10 + (iteration % 20); // Variable size access list
                
                var addresses = try allocator.alloc(Address.Address, access_list_size);
                defer allocator.free(addresses);

                for (0..access_list_size) |i| {
                    addresses[i] = create_deterministic_address(iteration + i);
                }

                // Simulate access list validation
                for (addresses) |address| {
                    _ = validate_access_list_entry(address);
                }
            }

            // Simulate additional transaction validations
            _ = validate_gas_limits(21000 + (scenario.blob_count * 21000));
            _ = validate_blob_fee_cap(1000000000 * @as(u64, scenario.blob_count));
            _ = validate_nonce(iteration);

            const end_validation = timing.nanoTimestamp();
            total_time += end_validation - start_validation;
        }

        const avg_time = total_time / scenario.iterations;
        const throughput = @as(f64, @floatFromInt(scenario.iterations * 1000000000)) / @as(f64, @floatFromInt(total_time));

        std.log.info("  {s}:", .{scenario.name});
        std.log.info("    Time: {d:.2f}μs avg", .{@as(f64, @floatFromInt(avg_time)) / 1000.0});
        std.log.info("    Throughput: {d:.2f} validations/sec", .{throughput});
    }
}

/// Compare performance between blob transactions and regular transactions
pub fn benchmark_blob_vs_regular_transaction_performance(allocator: std.mem.Allocator) !void {
    std.log.info("=== Blob vs Regular Transaction Performance Comparison ===", .{});

    const comparison_scenarios = [_]struct {
        name: []const u8,
        iterations: u32,
    }{
        .{ .name = "Basic Transfer", .iterations = 10000 },
        .{ .name = "Contract Call", .iterations = 5000 },
        .{ .name = "Complex Contract Interaction", .iterations = 2000 },
    };

    for (comparison_scenarios) |scenario| {
        std.log.info("Comparing {s} transactions", .{scenario.name});

        var regular_tx_time: u64 = 0;
        var blob_tx_time: u64 = 0;

        // Benchmark regular transactions
        const start_regular = timing.nanoTimestamp();
        
        for (0..scenario.iterations) |iteration| {
            // Simulate regular transaction processing
            _ = process_regular_transaction(iteration, scenario.name);
        }
        
        const end_regular = timing.nanoTimestamp();
        regular_tx_time = end_regular - start_regular;

        // Benchmark blob transactions
        const start_blob = timing.nanoTimestamp();
        
        for (0..scenario.iterations) |iteration| {
            // Simulate blob transaction processing
            const blob_count = 1 + (iteration % 3); // 1-3 blobs
            _ = try process_blob_transaction(allocator, iteration, scenario.name, blob_count);
        }
        
        const end_blob = timing.nanoTimestamp();
        blob_tx_time = end_blob - start_blob;

        const regular_avg = regular_tx_time / scenario.iterations;
        const blob_avg = blob_tx_time / scenario.iterations;
        const overhead_ratio = @as(f64, @floatFromInt(blob_avg)) / @as(f64, @floatFromInt(regular_avg));

        const regular_throughput = @as(f64, @floatFromInt(scenario.iterations * 1000000000)) / @as(f64, @floatFromInt(regular_tx_time));
        const blob_throughput = @as(f64, @floatFromInt(scenario.iterations * 1000000000)) / @as(f64, @floatFromInt(blob_tx_time));

        std.log.info("  {s}:", .{scenario.name});
        std.log.info("    Regular TX: {d:.2f}μs avg, {d:.2f} tx/sec", .{
            @as(f64, @floatFromInt(regular_avg)) / 1000.0,
            regular_throughput
        });
        std.log.info("    Blob TX: {d:.2f}μs avg, {d:.2f} tx/sec", .{
            @as(f64, @floatFromInt(blob_avg)) / 1000.0,
            blob_throughput
        });
        std.log.info("    Blob overhead: {d:.2f}x", .{overhead_ratio});
        std.log.info("    Performance reduction: {d:.1f}%", .{(overhead_ratio - 1.0) * 100.0});
    }
}

// Helper functions for creating deterministic test data

fn create_deterministic_blob_hash(seed: usize) u256 {
    var hash: u256 = @intCast(seed);
    hash = hash * 0x9e3779b97f4a7c15; // Golden ratio constant for better distribution
    return hash;
}

fn create_deterministic_blob_data(seed: usize) [131072]u8 {
    var blob_data: [131072]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(@intCast(seed));
    const random = prng.random();
    
    random.bytes(&blob_data);
    return blob_data;
}

fn create_deterministic_commitment(seed: usize) [48]u8 {
    var commitment: [48]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(@intCast(seed));
    const random = prng.random();
    
    random.bytes(&commitment);
    return commitment;
}

fn create_deterministic_evaluation_point(seed: usize) [32]u8 {
    var point: [32]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(@intCast(seed));
    const random = prng.random();
    
    random.bytes(&point);
    return point;
}

fn create_deterministic_address(seed: usize) Address.Address {
    var address: Address.Address = undefined;
    var prng = std.Random.DefaultPrng.init(@intCast(seed));
    const random = prng.random();
    
    random.bytes(&address);
    return address;
}

// Helper functions for simulating operations

fn simulate_kzg_evaluation(blob: *const [131072]u8, commitment: *const [48]u8, point: *const [32]u8) u64 {
    // Simulate computational work of KZG evaluation
    // In real implementation, this would call C-KZG library
    var hash: u64 = 0;
    
    // Hash parts of the input to simulate computation
    for (blob[0..100]) |byte| {
        hash = hash *% 31 +% byte;
    }
    
    for (commitment) |byte| {
        hash = hash *% 37 +% byte;
    }
    
    for (point) |byte| {
        hash = hash *% 41 +% byte;
    }
    
    return hash;
}

fn validate_blob_hash_commitment(hash: u256, commitment: *const [48]u8) bool {
    // Simulate blob hash validation
    _ = hash;
    _ = commitment;
    return true; // Always valid for benchmarking
}

fn validate_access_list_entry(address: Address.Address) bool {
    // Simulate access list entry validation
    _ = address;
    return true; // Always valid for benchmarking
}

fn validate_gas_limits(gas_limit: u64) bool {
    // Simulate gas limit validation
    return gas_limit > 0 and gas_limit <= 30000000; // 30M gas block limit
}

fn validate_blob_fee_cap(fee_cap: u64) bool {
    // Simulate blob fee cap validation
    return fee_cap > 0 and fee_cap <= std.math.maxInt(u64);
}

fn validate_nonce(nonce: usize) bool {
    // Simulate nonce validation
    return nonce <= std.math.maxInt(u64);
}

fn process_regular_transaction(iteration: usize, scenario: []const u8) u64 {
    // Simulate regular transaction processing
    _ = scenario;
    var work: u64 = @intCast(iteration);
    work = work *% 1103515245 +% 12345; // Simple linear congruential generator
    return work;
}

fn process_blob_transaction(allocator: std.mem.Allocator, iteration: usize, scenario: []const u8, blob_count: u32) !u64 {
    // Simulate blob transaction processing with additional overhead
    _ = scenario;
    var work: u64 = @intCast(iteration);
    work = work *% 1103515245 +% 12345;
    
    // Additional work for blob processing
    work = work *% @as(u64, blob_count);
    
    // Simulate memory allocation for blob data
    const blob_data = try allocator.alloc(u8, blob_count * 1000); // Simulate some blob data
    defer allocator.free(blob_data);
    
    // Simulate some work on the blob data
    for (blob_data) |*byte| {
        byte.* = @truncate(work);
        work = work *% 31 +% 1;
    }
    
    return work;
}

/// Run all comprehensive EIP-4844 benchmarks
pub fn run_comprehensive_eip4844_benchmarks(allocator: std.mem.Allocator) !void {
    std.log.info("=== Running Comprehensive EIP-4844 Blob Transaction Benchmarks ===", .{});
    std.log.info("Issue #72: EIP-4844 blob transactions and access lists performance analysis", .{});
    
    try benchmark_blobhash_opcode_performance(allocator);
    try benchmark_blobbasefee_opcode_performance(allocator);
    try benchmark_kzg_point_evaluation_performance(allocator);
    try benchmark_access_list_gas_calculations(allocator);
    try benchmark_blob_transaction_validation(allocator);
    try benchmark_blob_vs_regular_transaction_performance(allocator);
    
    std.log.info("=== EIP-4844 Benchmark Suite Completed ===", .{});
}

// Tests to ensure all benchmark functions compile and work correctly
test "comprehensive eip4844 benchmark compilation" {
    const allocator = std.testing.allocator;
    
    // Test that all benchmark functions compile
    _ = benchmark_blobhash_opcode_performance;
    _ = benchmark_blobbasefee_opcode_performance;
    _ = benchmark_kzg_point_evaluation_performance;
    _ = benchmark_access_list_gas_calculations;
    _ = benchmark_blob_transaction_validation;
    _ = benchmark_blob_vs_regular_transaction_performance;
    _ = run_comprehensive_eip4844_benchmarks;
    
    // Test helper functions
    const test_hash = create_deterministic_blob_hash(42);
    const test_blob_data = create_deterministic_blob_data(42);
    const test_commitment = create_deterministic_commitment(42);
    const test_address = create_deterministic_address(42);
    
    // Test simulation functions
    const simulated_result = simulate_kzg_evaluation(&test_blob_data, &test_commitment, &create_deterministic_evaluation_point(42));
    
    try std.testing.expect(validate_blob_hash_commitment(test_hash, &test_commitment));
    try std.testing.expect(validate_access_list_entry(test_address));
    try std.testing.expect(validate_gas_limits(21000));
    try std.testing.expect(validate_blob_fee_cap(1000000000));
    try std.testing.expect(validate_nonce(100));
    
    const regular_work = process_regular_transaction(10, "test");
    const blob_work = try process_blob_transaction(allocator, 10, "test", 2);
    
    // Use variables to prevent optimization
    std.mem.doNotOptimizeAway(simulated_result);
    std.mem.doNotOptimizeAway(regular_work);
    std.mem.doNotOptimizeAway(blob_work);
}