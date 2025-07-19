const std = @import("std");
const Allocator = std.mem.Allocator;
const evm_benchmark = @import("evm_benchmark.zig");
const stack_benchmark = @import("stack_benchmark.zig");
const gas_calculations_benchmark = @import("gas_calculations_benchmark.zig");

pub fn run_benchmarks(allocator: Allocator, zbench: anytype) !void {
    var benchmark = zbench.Benchmark.init(allocator, .{});
    defer benchmark.deinit();
    
    // Real EVM benchmarks (actual bytecode execution)
    try benchmark.add("EVM Arithmetic", evm_benchmark.evm_arithmetic_benchmark, .{});
    try benchmark.add("EVM Memory Ops", evm_benchmark.evm_memory_benchmark, .{});
    try benchmark.add("EVM Storage Ops", evm_benchmark.evm_storage_benchmark, .{});
    try benchmark.add("EVM Snail Shell", evm_benchmark.evm_snail_shell_benchmark, .{});
    
    // Stack benchmarks - Basic operations
    try benchmark.add("Stack append (safe)", stack_benchmark.bench_append_safe, .{});
    try benchmark.add("Stack append (unsafe)", stack_benchmark.bench_append_unsafe, .{});
    try benchmark.add("Stack pop (safe)", stack_benchmark.bench_pop_safe, .{});
    try benchmark.add("Stack pop (unsafe)", stack_benchmark.bench_pop_unsafe, .{});
    
    // Stack benchmarks - Peek operations
    try benchmark.add("Stack peek (shallow)", stack_benchmark.bench_peek_shallow, .{});
    try benchmark.add("Stack peek (deep)", stack_benchmark.bench_peek_deep, .{});
    
    // Stack benchmarks - DUP operations
    try benchmark.add("Stack DUP1", stack_benchmark.bench_dup1, .{});
    try benchmark.add("Stack DUP16", stack_benchmark.bench_dup16, .{});
    
    // Stack benchmarks - SWAP operations
    try benchmark.add("Stack SWAP1", stack_benchmark.bench_swap1, .{});
    try benchmark.add("Stack SWAP16", stack_benchmark.bench_swap16, .{});
    
    // Stack benchmarks - Growth patterns
    try benchmark.add("Stack growth (linear)", stack_benchmark.bench_stack_growth_linear, .{});
    try benchmark.add("Stack growth (burst)", stack_benchmark.bench_stack_growth_burst, .{});
    
    // Stack benchmarks - Memory access patterns
    try benchmark.add("Stack sequential access", stack_benchmark.bench_sequential_access, .{});
    try benchmark.add("Stack random access", stack_benchmark.bench_random_access, .{});
    
    // Stack benchmarks - Edge cases
    try benchmark.add("Stack near full", stack_benchmark.bench_near_full_stack, .{});
    try benchmark.add("Stack empty checks", stack_benchmark.bench_empty_stack_checks, .{});
    
    // Stack benchmarks - Multi-pop operations
    try benchmark.add("Stack pop2", stack_benchmark.bench_pop2, .{});
    try benchmark.add("Stack pop3", stack_benchmark.bench_pop3, .{});
    
    // Stack benchmarks - Clear operations
    try benchmark.add("Stack clear (empty)", stack_benchmark.bench_clear_empty, .{});
    try benchmark.add("Stack clear (full)", stack_benchmark.bench_clear_full, .{});
    
    // Stack benchmarks - Realistic patterns
    try benchmark.add("Stack fibonacci pattern", stack_benchmark.bench_fibonacci_pattern, .{});
    try benchmark.add("Stack DeFi calculation", stack_benchmark.bench_defi_calculation_pattern, .{});
    try benchmark.add("Stack crypto pattern", stack_benchmark.bench_cryptographic_pattern, .{});
    
    // Stack benchmarks - Other operations
    try benchmark.add("Stack set_top", stack_benchmark.bench_set_top, .{});
    try benchmark.add("Stack predictable pattern", stack_benchmark.bench_predictable_pattern, .{});
    try benchmark.add("Stack unpredictable pattern", stack_benchmark.bench_unpredictable_pattern, .{});
    
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