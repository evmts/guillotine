const std = @import("std");
const Allocator = std.mem.Allocator;
const evm_benchmark = @import("evm_benchmark.zig");
const stack_benchmark = @import("stack_benchmark.zig");
const gas_calculations_benchmark = @import("gas_calculations_benchmark.zig");
const frame_benchmark = @import("frame_benchmark.zig");

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

    // Frame benchmarks - Frame lifecycle
    try benchmark.add("Frame init (minimal)", frame_benchmark.bench_frame_init_minimal, .{});
    try benchmark.add("Frame init (typical)", frame_benchmark.bench_frame_init_typical, .{});
    try benchmark.add("Frame init (child)", frame_benchmark.bench_frame_init_child, .{});
    try benchmark.add("Frame deinit (simple)", frame_benchmark.bench_frame_deinit_simple, .{});
    try benchmark.add("Frame deinit (with memory)", frame_benchmark.bench_frame_deinit_with_memory, .{});
    
    // Frame benchmarks - Gas consumption
    try benchmark.add("Frame consume gas (success)", frame_benchmark.bench_consume_gas_success, .{});
    try benchmark.add("Frame consume gas (failure)", frame_benchmark.bench_consume_gas_failure, .{});
    
    // Frame benchmarks - Contract management
    try benchmark.add("Contract init (small)", frame_benchmark.bench_contract_init_small, .{});
    try benchmark.add("Contract init (typical)", frame_benchmark.bench_contract_init_typical, .{});
    try benchmark.add("Contract init (large)", frame_benchmark.bench_contract_init_large, .{});
    try benchmark.add("Contract init (deployment)", frame_benchmark.bench_contract_init_deployment, .{});
    try benchmark.add("Contract init (CREATE2)", frame_benchmark.bench_contract_init_deployment_create2, .{});
    try benchmark.add("Contract deinit (with storage)", frame_benchmark.bench_contract_deinit_with_storage, .{});
    
    // Frame benchmarks - Code analysis
    try benchmark.add("JUMPDEST validation (no jumps)", frame_benchmark.bench_valid_jumpdest_no_jumps, .{});
    try benchmark.add("JUMPDEST validation (many)", frame_benchmark.bench_valid_jumpdest_many, .{});
    try benchmark.add("Code analysis (typical)", frame_benchmark.bench_analyze_code_typical, .{});
    try benchmark.add("Code analysis (cached)", frame_benchmark.bench_analyze_code_cached, .{});
    
    // Frame benchmarks - Storage operations
    try benchmark.add("Storage cold access", frame_benchmark.bench_storage_cold_access, .{});
    try benchmark.add("Storage warm access", frame_benchmark.bench_storage_warm_access, .{});
    try benchmark.add("Storage with pool", frame_benchmark.bench_storage_with_pool, .{});
    try benchmark.add("Storage batch warm", frame_benchmark.bench_storage_batch_warm, .{});
    
    // Frame benchmarks - Call stack management
    try benchmark.add("Call stack (shallow)", frame_benchmark.bench_call_stack_shallow, .{});
    try benchmark.add("Call stack (deep)", frame_benchmark.bench_call_stack_deep, .{});
    try benchmark.add("Recursive frame pattern", frame_benchmark.bench_recursive_frame_pattern, .{});
    
    // Frame benchmarks - Gas accounting
    try benchmark.add("Gas tracking (simple)", frame_benchmark.bench_gas_tracking_simple, .{});
    try benchmark.add("Gas refund tracking", frame_benchmark.bench_gas_refund_tracking, .{});
    try benchmark.add("Dynamic gas patterns", frame_benchmark.bench_dynamic_gas_patterns, .{});
    
    // Frame benchmarks - Real-world scenarios
    try benchmark.add("Simple ETH transfer", frame_benchmark.bench_scenario_simple_transfer, .{});
    try benchmark.add("DeFi swap transaction", frame_benchmark.bench_scenario_defi_swap, .{});
    try benchmark.add("Contract deployment", frame_benchmark.bench_scenario_contract_deployment, .{});
    try benchmark.add("Deep DeFi calls", frame_benchmark.bench_scenario_deep_defi_calls, .{});
    
    // Run all benchmarks
    try benchmark.run(std.io.getStdOut().writer());
}