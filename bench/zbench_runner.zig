const std = @import("std");
const Allocator = std.mem.Allocator;
const evm_benchmark = @import("evm_benchmark.zig");
const stack_benchmark = @import("stack_benchmark.zig");
const state_benchmarks = @import("state_benchmarks.zig");

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
    
    // State management benchmarks (Issue #61)
    try benchmark.add("State Account Read", state_benchmarks.zbench_account_read, .{});
    try benchmark.add("State Account Write", state_benchmarks.zbench_account_write, .{});
    try benchmark.add("State Storage Ops", state_benchmarks.zbench_storage_ops, .{});
    try benchmark.add("State Root Calc", state_benchmarks.zbench_state_root, .{});
    try benchmark.add("State Journal Ops", state_benchmarks.zbench_journal_ops, .{});
    try benchmark.add("State Full EVM", state_benchmarks.zbench_evm_state_full, .{});
    
    // Run all benchmarks
    try benchmark.run(std.io.getStdOut().writer());
}