const std = @import("std");
const Allocator = std.mem.Allocator;
const evm_benchmark = @import("evm_benchmark.zig");
const blob_benchmark = @import("blob_benchmark.zig");
const access_list_benchmark = @import("access_list_benchmark.zig");
const transaction_benchmark = @import("transaction_benchmark.zig");
const stack_benchmark = @import("stack_benchmark.zig");
const state_benchmarks = @import("state_benchmarks.zig");
const gas_calculations_benchmark = @import("gas_calculations_benchmark.zig");

pub fn run_benchmarks(allocator: Allocator, zbench: anytype) !void {
    var benchmark = zbench.Benchmark.init(allocator, .{});
    defer benchmark.deinit();
    
    // Real EVM benchmarks (actual bytecode execution)
    try benchmark.add("EVM Arithmetic", evm_benchmark.evm_arithmetic_benchmark, .{});
    try benchmark.add("EVM Memory Ops", evm_benchmark.evm_memory_benchmark, .{});
    try benchmark.add("EVM Storage Ops", evm_benchmark.evm_storage_benchmark, .{});
    try benchmark.add("EVM Snail Shell", evm_benchmark.evm_snail_shell_benchmark, .{});
    
    // EIP-4844 Blob Transaction Benchmarks
    try benchmark.add("Blob KZG Verification", blob_benchmark.kzg_verification_benchmark, .{});
    try benchmark.add("Blob Gas Market", blob_benchmark.blob_gas_market_benchmark, .{});
    try benchmark.add("Versioned Hash Validation", blob_benchmark.versioned_hash_benchmark, .{});
    try benchmark.add("Blob Data Handling", blob_benchmark.blob_data_handling_benchmark, .{});
    try benchmark.add("Blob Transaction Throughput", blob_benchmark.blob_transaction_throughput_benchmark, .{});
    
    // Access List Benchmarks (EIP-2929 & EIP-2930)
    try benchmark.add("Address Warming/Cooling", access_list_benchmark.address_warming_cooling_benchmark, .{});
    try benchmark.add("Storage Slot Tracking", access_list_benchmark.storage_slot_tracking_benchmark, .{});
    try benchmark.add("Access List Initialization", access_list_benchmark.access_list_initialization_benchmark, .{});
    try benchmark.add("Gas Cost Calculations", access_list_benchmark.gas_cost_calculations_benchmark, .{});
    try benchmark.add("Memory Usage (Large Lists)", access_list_benchmark.memory_usage_benchmark, .{});
    try benchmark.add("Call Cost Calculations", access_list_benchmark.call_cost_benchmark, .{});
    
    // Transaction Processing Benchmarks
    try benchmark.add("Transaction Type Detection", transaction_benchmark.transaction_type_detection_benchmark, .{});
    try benchmark.add("Blob Transaction Parsing", transaction_benchmark.blob_transaction_parsing_benchmark, .{});
    try benchmark.add("Transaction Validation", transaction_benchmark.transaction_validation_benchmark, .{});
    try benchmark.add("Block Validation", transaction_benchmark.block_validation_benchmark, .{});
    try benchmark.add("Gas Price Calculations", transaction_benchmark.gas_price_calculations_benchmark, .{});
    
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