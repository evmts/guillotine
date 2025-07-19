const std = @import("std");
const Allocator = std.mem.Allocator;
const evm_benchmark = @import("evm_benchmark.zig");
const evm_core_benchmarks = @import("evm_core_benchmarks.zig");

pub fn run_benchmarks(allocator: Allocator, zbench: anytype) !void {
    var benchmark = zbench.Benchmark.init(allocator, .{});
    defer benchmark.deinit();
    
    // Real EVM benchmarks (actual bytecode execution)
    try benchmark.add("EVM Arithmetic", evm_benchmark.evm_arithmetic_benchmark, .{});
    try benchmark.add("EVM Memory Ops", evm_benchmark.evm_memory_benchmark, .{});
    try benchmark.add("EVM Storage Ops", evm_benchmark.evm_storage_benchmark, .{});
    try benchmark.add("EVM Snail Shell", evm_benchmark.evm_snail_shell_benchmark, .{});
    
    // Comprehensive core EVM benchmarks
    try benchmark.add("VM Init Default", evm_core_benchmarks.benchmark_vm_init_default, .{});
    try benchmark.add("VM Init London", evm_core_benchmarks.benchmark_vm_init_london, .{});
    try benchmark.add("VM Init Cancun", evm_core_benchmarks.benchmark_vm_init_cancun, .{});
    try benchmark.add("Interpret Simple", evm_core_benchmarks.benchmark_interpret_simple_opcodes, .{});
    try benchmark.add("Interpret Complex", evm_core_benchmarks.benchmark_interpret_complex_opcodes, .{});
    try benchmark.add("Cold Storage", evm_core_benchmarks.benchmark_cold_storage_access, .{});
    try benchmark.add("Warm Storage", evm_core_benchmarks.benchmark_warm_storage_access, .{});
    try benchmark.add("Balance Ops", evm_core_benchmarks.benchmark_balance_operations, .{});
    try benchmark.add("Code Ops", evm_core_benchmarks.benchmark_code_operations, .{});
    try benchmark.add("Gas Metering", evm_core_benchmarks.benchmark_gas_metering_overhead, .{});
    try benchmark.add("Deep Call Stack", evm_core_benchmarks.benchmark_deep_call_stack, .{});
    try benchmark.add("Large Contract", evm_core_benchmarks.benchmark_large_contract_deployment, .{});
    
    // Run all benchmarks
    try benchmark.run(std.io.getStdOut().writer());
}