const std = @import("std");
const Allocator = std.mem.Allocator;
const evm_benchmark = @import("evm_benchmark.zig");
const blob_benchmark = @import("blob_benchmark.zig");
const access_list_benchmark = @import("access_list_benchmark.zig");
const transaction_benchmark = @import("transaction_benchmark.zig");
const stack_benchmark = @import("stack_benchmark.zig");
const state_benchmarks = @import("state_benchmarks.zig");
const gas_calculations_benchmark = @import("gas_calculations_benchmark.zig");
const eip4844_simple_benchmark = @import("eip4844_simple_benchmark.zig");

pub fn run_benchmarks(allocator: Allocator, zbench: anytype) !void {
    var benchmark = zbench.Benchmark.init(allocator, .{});
    defer benchmark.deinit();
    
    // Real EVM benchmarks (actual bytecode execution)
    try benchmark.add("EVM Arithmetic", evm_benchmark.evm_arithmetic_benchmark, .{});
    try benchmark.add("EVM Memory Ops", evm_benchmark.evm_memory_benchmark, .{});
    try benchmark.add("EVM Storage Ops", evm_benchmark.evm_storage_benchmark, .{});
    try benchmark.add("EVM Snail Shell", evm_benchmark.evm_snail_shell_benchmark, .{});
    
    // EIP-4844 Blob Transaction Benchmarks
    try benchmark.add("Blob KZG Verification", struct {
        fn run(alloc: Allocator) void {
            blob_benchmark.kzg_verification_benchmark(alloc) catch |err| {
                std.log.err("Blob KZG benchmark failed: {}", .{err});
            };
        }
    }.run, .{});
    
    try benchmark.add("Blob Gas Market", struct {
        fn run(alloc: Allocator) void {
            blob_benchmark.blob_gas_market_benchmark(alloc) catch |err| {
                std.log.err("Blob gas market benchmark failed: {}", .{err});
            };
        }
    }.run, .{});
    
    try benchmark.add("Versioned Hash Validation", struct {
        fn run(alloc: Allocator) void {
            blob_benchmark.versioned_hash_benchmark(alloc) catch |err| {
                std.log.err("Versioned hash benchmark failed: {}", .{err});
            };
        }
    }.run, .{});
    
    try benchmark.add("Blob Data Handling", struct {
        fn run(alloc: Allocator) void {
            blob_benchmark.blob_data_handling_benchmark(alloc) catch |err| {
                std.log.err("Blob data handling benchmark failed: {}", .{err});
            };
        }
    }.run, .{});
    
    try benchmark.add("Blob Transaction Throughput", struct {
        fn run(alloc: Allocator) void {
            blob_benchmark.blob_transaction_throughput_benchmark(alloc) catch |err| {
                std.log.err("Blob throughput benchmark failed: {}", .{err});
            };
        }
    }.run, .{});
    
    // Issue #72: Simple EIP-4844 Performance Benchmarks
    try benchmark.add("BLOBHASH Opcode Performance", struct {
        fn run(alloc: Allocator) void {
            eip4844_simple_benchmark.benchmark_blobhash_opcode_performance(alloc) catch |err| {
                std.log.err("BLOBHASH benchmark failed: {}", .{err});
            };
        }
    }.run, .{});
    
    try benchmark.add("BLOBBASEFEE Opcode Performance", struct {
        fn run(alloc: Allocator) void {
            eip4844_simple_benchmark.benchmark_blobbasefee_opcode_performance(alloc) catch |err| {
                std.log.err("BLOBBASEFEE benchmark failed: {}", .{err});
            };
        }
    }.run, .{});
    
    try benchmark.add("Simple Access List Gas Calculations", struct {
        fn run(alloc: Allocator) void {
            eip4844_simple_benchmark.benchmark_access_list_gas_calculations(alloc) catch |err| {
                std.log.err("Access list benchmark failed: {}", .{err});
            };
        }
    }.run, .{});
    
    try benchmark.add("Blob vs Regular TX Performance", struct {
        fn run(alloc: Allocator) void {
            eip4844_simple_benchmark.benchmark_blob_vs_regular_transaction_performance(alloc) catch |err| {
                std.log.err("Blob vs regular TX benchmark failed: {}", .{err});
            };
        }
    }.run, .{});
    
    // Access List Benchmarks (EIP-2929 & EIP-2930)
    try benchmark.add("Address Warming/Cooling", struct {
        fn run(alloc: Allocator) void {
            access_list_benchmark.address_warming_cooling_benchmark(alloc) catch |err| {
                std.log.err("Address warming/cooling benchmark failed: {}", .{err});
            };
        }
    }.run, .{});
    
    try benchmark.add("Storage Slot Tracking", struct {
        fn run(alloc: Allocator) void {
            access_list_benchmark.storage_slot_tracking_benchmark(alloc) catch |err| {
                std.log.err("Storage slot tracking benchmark failed: {}", .{err});
            };
        }
    }.run, .{});
    
    try benchmark.add("Access List Initialization", struct {
        fn run(alloc: Allocator) void {
            access_list_benchmark.access_list_initialization_benchmark(alloc) catch |err| {
                std.log.err("Access list initialization benchmark failed: {}", .{err});
            };
        }
    }.run, .{});
    
    try benchmark.add("Gas Cost Calculations", struct {
        fn run(alloc: Allocator) void {
            access_list_benchmark.gas_cost_calculations_benchmark(alloc) catch |err| {
                std.log.err("Gas cost calculations benchmark failed: {}", .{err});
            };
        }
    }.run, .{});
    
    try benchmark.add("Memory Usage (Large Lists)", struct {
        fn run(alloc: Allocator) void {
            access_list_benchmark.memory_usage_benchmark(alloc) catch |err| {
                std.log.err("Memory usage benchmark failed: {}", .{err});
            };
        }
    }.run, .{});
    
    try benchmark.add("Call Cost Calculations", struct {
        fn run(alloc: Allocator) void {
            access_list_benchmark.call_cost_benchmark(alloc) catch |err| {
                std.log.err("Call cost benchmark failed: {}", .{err});
            };
        }
    }.run, .{});
    
    // Transaction Processing Benchmarks
    try benchmark.add("Transaction Type Detection", struct {
        fn run(alloc: Allocator) void {
            transaction_benchmark.transaction_type_detection_benchmark(alloc) catch |err| {
                std.log.err("Transaction type detection benchmark failed: {}", .{err});
            };
        }
    }.run, .{});
    
    try benchmark.add("Blob Transaction Parsing", struct {
        fn run(alloc: Allocator) void {
            transaction_benchmark.blob_transaction_parsing_benchmark(alloc) catch |err| {
                std.log.err("Blob transaction parsing benchmark failed: {}", .{err});
            };
        }
    }.run, .{});
    
    try benchmark.add("Transaction Validation", struct {
        fn run(alloc: Allocator) void {
            transaction_benchmark.transaction_validation_benchmark(alloc) catch |err| {
                std.log.err("Transaction validation benchmark failed: {}", .{err});
            };
        }
    }.run, .{});
    
    try benchmark.add("Block Validation", struct {
        fn run(alloc: Allocator) void {
            transaction_benchmark.block_validation_benchmark(alloc) catch |err| {
                std.log.err("Block validation benchmark failed: {}", .{err});
            };
        }
    }.run, .{});
    
    try benchmark.add("Gas Price Calculations", struct {
        fn run(alloc: Allocator) void {
            transaction_benchmark.gas_price_calculations_benchmark(alloc) catch |err| {
                std.log.err("Gas price calculations benchmark failed: {}", .{err});
            };
        }
    }.run, .{});
    
    // State management benchmarks (Issue #61)
    try benchmark.add("State Account Read", state_benchmarks.zbench_account_read, .{});
    try benchmark.add("State Account Write", state_benchmarks.zbench_account_write, .{});
    try benchmark.add("State Storage Ops", state_benchmarks.zbench_storage_ops, .{});
    try benchmark.add("State Root Calc", state_benchmarks.zbench_state_root, .{});
    try benchmark.add("State Journal Ops", state_benchmarks.zbench_journal_ops, .{});
    try benchmark.add("State Full EVM", state_benchmarks.zbench_evm_state_full, .{});
    // Gas calculation benchmarks
    try benchmark.add("Memory Linear Gas", gas_calculations_benchmark.memory_linear_gas_benchmark, .{});
    try benchmark.add("Memory Quadratic Gas", gas_calculations_benchmark.memory_quadratic_gas_benchmark, .{});
    try benchmark.add("Memory Expansion Full", gas_calculations_benchmark.memory_expansion_full_gas_benchmark, .{});
    try benchmark.add("Memory Expansion Safe", gas_calculations_benchmark.memory_expansion_safe_gas_benchmark, .{});
    try benchmark.add("CALL Gas Calculation", gas_calculations_benchmark.call_gas_calculation_benchmark, .{});
    try benchmark.add("CREATE Gas Calculation", gas_calculations_benchmark.create_gas_calculation_benchmark, .{});
    try benchmark.add("SSTORE Gas Calculation", gas_calculations_benchmark.sstore_gas_calculation_benchmark, .{});
    try benchmark.add("LOG Gas Calculation", gas_calculations_benchmark.log_gas_calculation_benchmark, .{});
    try benchmark.add("Gas Constants Access", gas_calculations_benchmark.gas_constants_access_benchmark, .{});
    try benchmark.add("LUT vs Calculation", gas_calculations_benchmark.memory_expansion_lut_vs_calculation_benchmark, .{});
    try benchmark.add("SSTORE Refund Calc", gas_calculations_benchmark.sstore_refund_calculation_benchmark, .{});
    try benchmark.add("SELFDESTRUCT Refund", gas_calculations_benchmark.selfdestruct_refund_calculation_benchmark, .{});
    
    // Run all benchmarks
    try benchmark.run(std.io.getStdOut().writer());
}