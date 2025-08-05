const std = @import("std");
const Allocator = std.mem.Allocator;
const evm_benchmark = @import("evm_benchmark.zig");
// const blob_benchmark = @import("blob_benchmark.zig");
// const access_list_benchmark = @import("access_list_benchmark.zig");
// const transaction_benchmark = @import("transaction_benchmark.zig");
const stack_benchmark = @import("stack_benchmark.zig");
const state_benchmarks = @import("state_benchmarks.zig");
const gas_calculations_benchmark = @import("gas_calculations_benchmark.zig");
const simple_eip4844_benchmark = @import("simple_eip4844_benchmark.zig");
const memory_benchmark = @import("memory_benchmark.zig");
const hardfork_benchmark = @import("hardfork_benchmark.zig");
const uint_benchmark = @import("uint_benchmark.zig");
const jump_table_benchmarks = @import("jump_table_benchmarks.zig");
const inline_hot_ops_benchmarks = @import("inline_hot_ops_zbench.zig");

pub fn run_benchmarks(allocator: Allocator, zbench: anytype) !void {
    var benchmark = zbench.Benchmark.init(allocator, .{});
    defer benchmark.deinit();

    // Real EVM benchmarks (actual bytecode execution)
    try benchmark.add("EVM Arithmetic", evm_benchmark.evm_arithmetic_benchmark, .{});
    try benchmark.add("EVM Memory Ops", evm_benchmark.evm_memory_benchmark, .{});
    try benchmark.add("EVM Storage Ops", evm_benchmark.evm_storage_benchmark, .{});
    try benchmark.add("EVM Snail Shell", evm_benchmark.evm_snail_shell_benchmark, .{});
    // EIP-4844 Blob Transaction Benchmarks (disabled due to KZG dependency issues)
    // try benchmark.add("Blob KZG Verification", blob_benchmark.kzg_verification_benchmark, .{});
    // try benchmark.add("Blob Gas Market", blob_benchmark.blob_gas_market_benchmark, .{});
    // try benchmark.add("Versioned Hash Validation", blob_benchmark.versioned_hash_benchmark, .{});
    // try benchmark.add("Blob Data Handling", blob_benchmark.blob_data_handling_benchmark, .{});
    // try benchmark.add("Blob Transaction Throughput", blob_benchmark.blob_transaction_throughput_benchmark, .{});

    // Access List Benchmarks (EIP-2929 & EIP-2930) (disabled due to missing access_list module)
    // try benchmark.add("Address Warming/Cooling", access_list_benchmark.address_warming_cooling_benchmark, .{});
    // try benchmark.add("Storage Slot Tracking", access_list_benchmark.storage_slot_tracking_benchmark, .{});
    // try benchmark.add("Access List Initialization", access_list_benchmark.access_list_initialization_benchmark, .{});
    // try benchmark.add("Gas Cost Calculations", access_list_benchmark.gas_cost_calculations_benchmark, .{});
    // try benchmark.add("Memory Usage (Large Lists)", access_list_benchmark.memory_usage_benchmark, .{});
    // try benchmark.add("Call Cost Calculations", access_list_benchmark.call_cost_benchmark, .{});

    // Transaction Processing Benchmarks (disabled due to timing module issues)
    // try benchmark.add("Transaction Type Detection", transaction_benchmark.transaction_type_detection_benchmark, .{});
    // try benchmark.add("Blob Transaction Parsing", transaction_benchmark.blob_transaction_parsing_benchmark, .{});
    // try benchmark.add("Transaction Validation", transaction_benchmark.transaction_validation_benchmark, .{});
    // try benchmark.add("Block Validation", transaction_benchmark.block_validation_benchmark, .{});
    // try benchmark.add("Gas Price Calculations", transaction_benchmark.gas_price_calculations_benchmark, .{});

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

    // EIP-4844 Simple Benchmarks (using only basic functionality)
    try benchmark.add("EIP-4844: Transaction Type Detection", simple_eip4844_benchmark.transaction_type_benchmark, .{});
    try benchmark.add("EIP-4844: Address Creation", simple_eip4844_benchmark.address_creation_benchmark, .{});
    try benchmark.add("EIP-4844: Gas Calculations", simple_eip4844_benchmark.gas_calculation_eip4844_benchmark, .{});
    try benchmark.add("EIP-4844: Data Structures", simple_eip4844_benchmark.data_structure_benchmark, .{});
    try benchmark.add("EIP-4844: Hash Operations", simple_eip4844_benchmark.hash_operations_benchmark, .{});
    try benchmark.add("EIP-4844: Constants Access", simple_eip4844_benchmark.constants_access_benchmark, .{});

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

    // Memory benchmarks - Initialization
    try benchmark.add("Memory init (small capacity)", memory_benchmark.bench_init_small_capacity, .{});
    try benchmark.add("Memory init (medium capacity)", memory_benchmark.bench_init_medium_capacity, .{});
    try benchmark.add("Memory init (large capacity)", memory_benchmark.bench_init_large_capacity, .{});

    // Memory benchmarks - Expansion patterns
    try benchmark.add("Memory expansion (incremental)", memory_benchmark.bench_memory_expansion_incremental, .{});
    try benchmark.add("Memory expansion (doubling)", memory_benchmark.bench_memory_expansion_doubling, .{});
    try benchmark.add("Memory expansion (large jump)", memory_benchmark.bench_memory_expansion_large_jump, .{});

    // Memory benchmarks - Read operations
    try benchmark.add("Memory get_u256 (sequential)", memory_benchmark.bench_get_u256_sequential, .{});
    try benchmark.add("Memory get_u256 (random)", memory_benchmark.bench_get_u256_random, .{});
    try benchmark.add("Memory get_slice (small)", memory_benchmark.bench_get_slice_small, .{});
    try benchmark.add("Memory get_slice (medium)", memory_benchmark.bench_get_slice_medium, .{});
    try benchmark.add("Memory get_slice (large)", memory_benchmark.bench_get_slice_large, .{});
    try benchmark.add("Memory get_byte (sequential)", memory_benchmark.bench_get_byte_sequential, .{});

    // Memory benchmarks - Write operations
    try benchmark.add("Memory set_data (small)", memory_benchmark.bench_set_data_small, .{});
    try benchmark.add("Memory set_data (medium)", memory_benchmark.bench_set_data_medium, .{});
    try benchmark.add("Memory set_data (large)", memory_benchmark.bench_set_data_large, .{});
    try benchmark.add("Memory set_u256 (sequential)", memory_benchmark.bench_set_u256_sequential, .{});
    try benchmark.add("Memory set_u256 (random)", memory_benchmark.bench_set_u256_random, .{});

    // Memory benchmarks - Bounded write operations
    try benchmark.add("Memory set_data_bounded (full copy)", memory_benchmark.bench_set_data_bounded_full_copy, .{});
    try benchmark.add("Memory set_data_bounded (partial)", memory_benchmark.bench_set_data_bounded_partial_copy, .{});
    try benchmark.add("Memory set_data_bounded (zero fill)", memory_benchmark.bench_set_data_bounded_zero_fill, .{});

    // Memory benchmarks - Shared buffer architecture
    try benchmark.add("Memory child creation", memory_benchmark.bench_child_memory_creation, .{});
    try benchmark.add("Memory multiple contexts", memory_benchmark.bench_multiple_contexts_shared_buffer, .{});

    // Memory benchmarks - EVM patterns
    try benchmark.add("Memory CODECOPY pattern", memory_benchmark.bench_codecopy_pattern, .{});
    try benchmark.add("Memory MLOAD/MSTORE pattern", memory_benchmark.bench_mload_mstore_pattern, .{});
    try benchmark.add("Memory Keccak256 large data", memory_benchmark.bench_keccak256_large_data, .{});

    // Memory benchmarks - Edge cases
    try benchmark.add("Memory near limit", memory_benchmark.bench_near_memory_limit, .{});
    try benchmark.add("Memory zero length ops", memory_benchmark.bench_zero_length_operations, .{});

    // Memory benchmarks - Alignment
    try benchmark.add("Memory aligned access", memory_benchmark.bench_aligned_access, .{});
    try benchmark.add("Memory unaligned access", memory_benchmark.bench_unaligned_access, .{});

    // Memory benchmarks - Bulk operations
    try benchmark.add("Memory RETURNDATACOPY pattern", memory_benchmark.bench_returndatacopy_pattern, .{});
    try benchmark.add("Memory MCOPY pattern", memory_benchmark.bench_mcopy_pattern, .{});

    // Memory benchmarks - Expansion cost curve
    try benchmark.add("Memory expansion cost curve", memory_benchmark.bench_expansion_cost_curve, .{});

    // Hardfork logic benchmarks (Issue #71)
    try benchmark.add("Hardfork Flag Checks", hardfork_benchmark.zbench_hardfork_flag_checks, .{});
    try benchmark.add("Chain Rules Init", hardfork_benchmark.zbench_chain_rules_initialization, .{});
    try benchmark.add("Feature Availability", hardfork_benchmark.zbench_feature_availability_lookup, .{});
    try benchmark.add("Opcode Availability", hardfork_benchmark.zbench_opcode_availability, .{});
    try benchmark.add("Gas Cost Variations", hardfork_benchmark.zbench_gas_cost_variations, .{});
    try benchmark.add("Rule Application", hardfork_benchmark.zbench_rule_application, .{});
    try benchmark.add("Validation Differences", hardfork_benchmark.zbench_validation_differences, .{});
    try benchmark.add("Compile vs Runtime", hardfork_benchmark.zbench_compile_vs_runtime, .{});
    try benchmark.add("Hardfork Detection", hardfork_benchmark.zbench_hardfork_detection, .{});

    // Uint Library vs Native u256 Benchmarks
    try benchmark.add("Custom Addition", uint_benchmark.zbench_custom_addition, .{});
    try benchmark.add("Native Addition", uint_benchmark.zbench_native_addition, .{});
    try benchmark.add("Custom Multiplication", uint_benchmark.zbench_custom_multiplication, .{});
    try benchmark.add("Native Multiplication", uint_benchmark.zbench_native_multiplication, .{});
    try benchmark.add("Custom Division", uint_benchmark.zbench_custom_division, .{});
    try benchmark.add("Native Division", uint_benchmark.zbench_native_division, .{});
    try benchmark.add("Custom Shift Left", uint_benchmark.zbench_custom_shift_left, .{});
    try benchmark.add("Native Shift Left", uint_benchmark.zbench_native_shift_left, .{});
    try benchmark.add("Custom Bitwise AND", uint_benchmark.zbench_custom_bitwise_and, .{});
    try benchmark.add("Native Bitwise AND", uint_benchmark.zbench_native_bitwise_and, .{});
    try benchmark.add("Custom Comparison", uint_benchmark.zbench_custom_comparison, .{});
    try benchmark.add("Native Comparison", uint_benchmark.zbench_native_comparison, .{});

    // Jump Table Benchmarks - AoS vs SoA Performance Comparison
    try benchmark.add("Jump Table AoS Full", jump_table_benchmarks.zbench_aos_full_access, .{});
    try benchmark.add("Jump Table SoA Hot Fields", jump_table_benchmarks.zbench_soa_hot_fields, .{});
    try benchmark.add("Jump Table SoA Full", jump_table_benchmarks.zbench_soa_full_access, .{});
    try benchmark.add("Jump Table AoS Sequential", jump_table_benchmarks.zbench_aos_sequential, .{});
    try benchmark.add("Jump Table SoA Sequential", jump_table_benchmarks.zbench_soa_sequential, .{});
    try benchmark.add("Jump Table AoS Random", jump_table_benchmarks.zbench_aos_random, .{});
    try benchmark.add("Jump Table SoA Random", jump_table_benchmarks.zbench_soa_random, .{});

    // Inline Hot Operations Benchmarks - Compare dispatch methods
    try benchmark.add("Hot Ops Regular Dispatch", inline_hot_ops_benchmarks.zbench_regular_dispatch, .{});
    try benchmark.add("Hot Ops Inline Dispatch", inline_hot_ops_benchmarks.zbench_inline_hot_ops, .{});
    try benchmark.add("Hot Opcode Workload", inline_hot_ops_benchmarks.zbench_hot_opcode_workload, .{});
    try benchmark.add("Cold Opcode Workload", inline_hot_ops_benchmarks.zbench_cold_opcode_workload, .{});

    // Run all benchmarks
    const stdout = std.io.getStdOut().writer();
    try benchmark.run(stdout);
}
