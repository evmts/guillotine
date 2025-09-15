// Root test file that imports all tests in the test directory
// This allows build.zig to run all tests with a single test target

const std = @import("std");

// Enable debug logging for tests
pub const std_options = std.Options{
    .log_level = .debug,
};

test {
    // Test snailtracer first
    _ = @import("evm/snailtracer_test.zig");
    
    // Differential tests - gradually re-enabling
    // These tests work without hanging:
    _ = @import("differential/stop_opcode_test.zig");
    _ = @import("differential/debug_math_only.zig");
    _ = @import("differential/math_operations_test.zig");
    _ = @import("differential/stack_operations_test.zig");
    // _ = @import("differential/bitwise_extended_test.zig"); // CAUSES CRASH
    _ = @import("differential/memory_operations_test.zig");
    _ = @import("differential/storage_operations_test.zig");
    _ = @import("differential/jump_handlers_test.zig");
    _ = @import("differential/context_operations_test.zig");
    _ = @import("differential/env_operations_test.zig");
    // Testing which test causes hanging - adding one by one
    _ = @import("differential/keccak_logs_test.zig");
    _ = @import("differential/log_operations_test.zig");
    _ = @import("differential/push_comprehensive_test.zig");
    _ = @import("differential/stack_edge_cases_test.zig");
    _ = @import("differential/memory_edge_cases_test.zig");
    // _ = @import("differential/gas_edge_cases_test.zig"); // CAUSES INFINITE LOOP/HANG
    
    // Comprehensive contract differential tests
    // (removed temporarily due to API changes)
    
    // Re-enabling most tests except the problematic ones
    _ = @import("differential/comparison_opcodes_test.zig");
    _ = @import("differential/call_stack_edge_cases_test.zig");
    _ = @import("differential/create_failure_test.zig");
    _ = @import("differential/environmental_extended_test.zig");
    _ = @import("differential/memory_missing_operations_test.zig");
    _ = @import("differential/revert_scenarios_test.zig");
    _ = @import("differential/synthetic_toggle_test.zig");
    _ = @import("differential/system_extended_test.zig");
    _ = @import("differential/system_handlers_test.zig");
    _ = @import("differential/system_operations_test.zig");
    
    // These tests are known to be problematic or very slow:
    // _ = @import("differential/all_tests.zig");
    // _ = @import("differential/comprehensive_contract_tests.zig");
    // _ = @import("differential/differential_testor.zig");
    // _ = @import("differential/fixture_comprehensive_test.zig");
    // _ = @import("differential/fixtures_comprehensive_differential_test.zig");
    // _ = @import("differential/fixtures_contract_test.zig");
    // _ = @import("differential/fixtures_test.zig");
    // _ = @import("differential/popular_contracts_test.zig");
    // _ = @import("differential/precompile_comprehensive_test.zig");
    // _ = @import("differential/specific_fixtures_test.zig");
    // _ = @import("differential/usdc_proxy_test.zig");
    
    // EVM tests - commented out tests with broken imports
    // Many of these tests rely on outdated APIs and need to be rewritten
    // _ = @import("evm/test_traced_handlers.zig"); // File not present after rebase
    // _ = @import("evm/eip7702_test.zig");
    // _ = @import("evm/eip_3651_test.zig");
    // _ = @import("evm/eip_4788_test.zig");
    // _ = @import("evm/eip_4844_test.zig");
    // _ = @import("evm/eip_integration_test.zig");
    // _ = @import("evm/eip_test.zig");
    // _ = @import("evm/eip_tests.zig");
    // _ = @import("evm/evm_added_tests.zig");
    // _ = @import("evm/evm_test_msg_propagation.zig");
    // _ = @import("evm/frame_integration_test.zig");
    _ = @import("evm/transfer_test.zig");
    
    // ERC20 deployment differential test
    _ = @import("evm/erc20_deployment_issue.zig");
    
    // Ten thousand hashes differential test
    _ = @import("differential/ten_thousand_hashes_test.zig");
    // _ = @import("evm/frame_interpreter_create_edge_tests.zig");
    // _ = @import("evm/frame_interpreter_host_test.zig");
    // _ = @import("evm/frame_interpreter_integration_test.zig");
    // _ = @import("evm/frame_opcode_integration_test.zig");
    // _ = @import("evm/frame_system_opcodes_test.zig");
    // _ = @import("evm/gas_edge_case_tests.zig");
    // _ = @import("evm/journal_snapshot_test.zig");
    // _ = @import("evm/log_static_context_tests.zig");
    // _ = @import("evm/newevm_test.zig");
    // _ = @import("evm/precompiles_regression_test.zig");
    // _ = @import("evm/precompiles_test.zig");
    // _ = @import("evm/snapshot_propagation_tests.zig");
    // C API tests removed - these APIs are not exported from evm module
    // _ = @import("evm/warm_cold_access_tests.zig");
    _ = @import("evm/selfdestruct_records_test.zig");
    _ = @import("evm/allocation_failure_snapshot_test.zig");
    
    // Opcode differential tests
    _ = @import("evm/opcodes/all_opcodes.zig");

    // Benchmarks
    // _ = @import("benchmark/baseline_benchmark.zig");
}
