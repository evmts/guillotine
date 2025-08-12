// EVM tests module

// Sub-packages
pub const integration = @import("integration/package.zig");
pub const opcodes = @import("opcodes/package.zig");
pub const precompiles = @import("precompiles/package.zig");
pub const gas = @import("gas/package.zig");
pub const state = @import("state/package.zig");

// Individual test files
pub const block_execution_erc20_test = @import("block_execution_erc20_test.zig");
pub const block_executor_integration_test = @import("block_executor_integration_test.zig");
pub const block_integration_test = @import("block_integration_test.zig");
pub const block_metrics_test = @import("block_metrics_test.zig");
pub const constructor_bug_test = @import("constructor_bug_test.zig");
pub const constructor_revert_test = @import("constructor_revert_test.zig");
pub const contract_call_test = @import("contract_call_test.zig");
pub const e2e_data_structures_test = @import("e2e_data_structures_test.zig");
pub const e2e_error_handling_test = @import("e2e_error_handling_test.zig");
pub const e2e_inheritance_test = @import("e2e_inheritance_test.zig");
pub const e2e_simple_test = @import("e2e_simple_test.zig");
pub const erc20_constructor_debug_test = @import("erc20_constructor_debug_test.zig");
pub const erc20_deployment_test = @import("erc20_deployment_test.zig");
pub const erc20_gt_test = @import("erc20_gt_test.zig");
pub const erc20_mint_debug_test = @import("erc20_mint_debug_test.zig");
pub const error_mapping_test = @import("error_mapping_test.zig");
pub const gt_operand_test = @import("gt_operand_test.zig");
pub const inline_ops_test = @import("inline_ops_test.zig");
pub const instruction_test = @import("instruction_test.zig");
pub const jump_block_execution_test = @import("jump_block_execution_test.zig");
pub const jump_resolution_test = @import("jump_resolution_test.zig");
pub const jump_table_test = @import("jump_table_test.zig");
pub const jumpi_bug_test = @import("jumpi_bug_test.zig");
pub const memory_leak_test = @import("memory_leak_test.zig");
pub const memory_test = @import("memory_test.zig");
pub const return_opcode_bug_test = @import("return_opcode_bug_test.zig");
pub const security_validation_comprehensive_test = @import("security_validation_comprehensive_test.zig");
pub const shared_memory_test = @import("shared_memory_test.zig");
pub const solidity_constructor_test = @import("solidity_constructor_test.zig");
pub const stack_test = @import("stack_test.zig");
pub const stack_validation_test = @import("stack_validation_test.zig");
pub const static_call_protection_test = @import("static_call_protection_test.zig");
pub const string_storage_test = @import("string_storage_test.zig");
pub const sub_opcode_bug_test = @import("sub_opcode_bug_test.zig");
pub const sub_operand_order_test = @import("sub_operand_order_test.zig");
pub const sub_stack_test = @import("sub_stack_test.zig");
pub const test_return_stops_execution = @import("test_return_stops_execution.zig");
pub const trace_erc20_constructor_test = @import("trace_erc20_constructor_test.zig");
pub const tracer_test = @import("tracer_test.zig");
pub const vm_core_comprehensive_test = @import("vm_core_comprehensive_test.zig");
pub const vm_opcode_test = @import("vm_opcode_test.zig");

test {
    // Sub-packages
    _ = integration;
    _ = opcodes;
    _ = precompiles;
    _ = gas;
    _ = state;
    
    // Individual test files
    _ = block_execution_erc20_test;
    _ = block_executor_integration_test;
    _ = block_integration_test;
    _ = block_metrics_test;
    _ = constructor_bug_test;
    _ = constructor_revert_test;
    _ = contract_call_test;
    _ = e2e_data_structures_test;
    _ = e2e_error_handling_test;
    _ = e2e_inheritance_test;
    _ = e2e_simple_test;
    _ = erc20_constructor_debug_test;
    _ = erc20_deployment_test;
    _ = erc20_gt_test;
    _ = erc20_mint_debug_test;
    _ = error_mapping_test;
    _ = gt_operand_test;
    _ = inline_ops_test;
    _ = instruction_test;
    _ = jump_block_execution_test;
    _ = jump_resolution_test;
    _ = jump_table_test;
    _ = jumpi_bug_test;
    _ = memory_leak_test;
    _ = memory_test;
    _ = return_opcode_bug_test;
    _ = security_validation_comprehensive_test;
    _ = shared_memory_test;
    _ = solidity_constructor_test;
    _ = stack_test;
    _ = stack_validation_test;
    _ = static_call_protection_test;
    _ = string_storage_test;
    _ = sub_opcode_bug_test;
    _ = sub_operand_order_test;
    _ = sub_stack_test;
    _ = test_return_stops_execution;
    _ = trace_erc20_constructor_test;
    _ = tracer_test;
    _ = vm_core_comprehensive_test;
    _ = vm_opcode_test;
}