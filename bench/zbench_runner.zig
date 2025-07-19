const std = @import("std");
const Allocator = std.mem.Allocator;
const evm_benchmark = @import("evm_benchmark.zig");
const stack_benchmark = @import("stack_benchmark.zig");
const memory_zbench = @import("memory_zbench.zig");

pub fn run_benchmarks(allocator: Allocator, zbench: anytype) !void {
    var benchmark = zbench.Benchmark.init(allocator, .{});
    defer benchmark.deinit();
    
    // Setup memory benchmarks
    try memory_zbench.setup_benchmarks(allocator);
    defer memory_zbench.cleanup_benchmarks();
    
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
    
    // Memory benchmarks - Allocation and Expansion
    try benchmark.add("Memory init (small)", memory_zbench.bench_memory_init_small, .{});
    try benchmark.add("Memory init (large)", memory_zbench.bench_memory_init_large, .{});
    try benchmark.add("Memory expansion (small)", memory_zbench.bench_memory_expansion_small, .{});
    try benchmark.add("Memory expansion (large)", memory_zbench.bench_memory_expansion_large, .{});
    try benchmark.add("Memory expansion (incremental)", memory_zbench.bench_memory_expansion_incremental, .{});
    
    // Memory benchmarks - Read Operations
    try benchmark.add("Memory read u256 (sequential)", memory_zbench.bench_read_u256_sequential, .{});
    try benchmark.add("Memory read u256 (random)", memory_zbench.bench_read_u256_random, .{});
    try benchmark.add("Memory read slice (small)", memory_zbench.bench_read_slice_small, .{});
    try benchmark.add("Memory read slice (large)", memory_zbench.bench_read_slice_large, .{});
    try benchmark.add("Memory read byte (sequential)", memory_zbench.bench_read_byte_sequential, .{});
    
    // Memory benchmarks - Write Operations
    try benchmark.add("Memory write u256 (sequential)", memory_zbench.bench_write_u256_sequential, .{});
    try benchmark.add("Memory write u256 (random)", memory_zbench.bench_write_u256_random, .{});
    try benchmark.add("Memory write data (small)", memory_zbench.bench_write_data_small, .{});
    try benchmark.add("Memory write data (large)", memory_zbench.bench_write_data_large, .{});
    try benchmark.add("Memory write data (bounded)", memory_zbench.bench_write_data_bounded, .{});
    
    // Memory benchmarks - Shared Buffer Architecture
    try benchmark.add("Memory child context creation", memory_zbench.bench_child_context_creation, .{});
    try benchmark.add("Memory child context access", memory_zbench.bench_child_context_access, .{});
    
    // Memory benchmarks - EVM Patterns
    try benchmark.add("Memory EVM CODECOPY", memory_zbench.bench_evm_codecopy, .{});
    try benchmark.add("Memory EVM CALLDATACOPY", memory_zbench.bench_evm_calldatacopy, .{});
    try benchmark.add("Memory EVM RETURNDATACOPY", memory_zbench.bench_evm_returndatacopy, .{});
    try benchmark.add("Memory EVM MLOAD/MSTORE", memory_zbench.bench_evm_mload_mstore, .{});
    try benchmark.add("Memory EVM Keccak pattern", memory_zbench.bench_evm_keccak_pattern, .{});
    try benchmark.add("Memory EVM expansion", memory_zbench.bench_evm_memory_expansion, .{});
    
    // Memory benchmarks - Edge Cases
    try benchmark.add("Memory zero length ops", memory_zbench.bench_zero_length_ops, .{});
    try benchmark.add("Memory near limit", memory_zbench.bench_near_memory_limit, .{});
    try benchmark.add("Memory alignment patterns", memory_zbench.bench_alignment_patterns, .{});
    
    // Memory benchmarks - Copy vs Set
    try benchmark.add("Memory memcpy (small)", memory_zbench.bench_memcpy_small, .{});
    try benchmark.add("Memory memcpy (large)", memory_zbench.bench_memcpy_large, .{});
    try benchmark.add("Memory memset pattern", memory_zbench.bench_memset_pattern, .{});
    
    // Run all benchmarks
    try benchmark.run(std.io.getStdOut().writer());
}