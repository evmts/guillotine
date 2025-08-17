const std = @import("std");
const CodeAnalysis = @import("../analysis.zig").CodeAnalysis;
const Instruction = @import("../instruction.zig").Instruction;
const Tag = @import("../instruction.zig").Tag;
const ExecutionError = @import("../execution/execution_error.zig");
const wrappers = @import("tailcall_wrappers.zig");

/// Function signature for tailcall dispatch
pub const TailcallFunc = *const fn (context: *anyopaque) ExecutionError.Error!void;

/// Build array of function pointers from analyzed bytecode
pub fn build(allocator: std.mem.Allocator, analysis: *const CodeAnalysis) ![]const TailcallFunc {
    // Allocate ops array matching instruction count
    const ops = try allocator.alloc(TailcallFunc, analysis.instructions.len);
    errdefer allocator.free(ops);

    // Map each instruction to its wrapper function
    for (analysis.instructions, 0..) |inst, i| {
        ops[i] = mapTagToWrapper(inst.tag);
    }

    return ops;
}

/// Map instruction tag to its tailcall wrapper function
fn mapTagToWrapper(tag: Tag) TailcallFunc {
    return switch (tag) {
        // Synthetic control flow
        .block_info => &wrappers.block_info_wrap,
        .noop => &wrappers.noop_wrap,
        .word => &wrappers.word_wrap,
        .pc => &wrappers.pc_wrap,
        .jump_pc => &wrappers.jump_pc_wrap,
        .jump_unresolved => &wrappers.jump_unresolved_wrap,
        .conditional_jump_pc => &wrappers.conditional_jump_pc_wrap,
        .conditional_jump_unresolved => &wrappers.conditional_jump_unresolved_wrap,
        .conditional_jump_invalid => &wrappers.conditional_jump_invalid_wrap,
        .conditional_jump_idx => &wrappers.conditional_jump_pc_wrap,
        
        // Halting opcodes
        .op_stop => &wrappers.op_stop_wrap,
        .op_return => &wrappers.op_return_wrap,
        .op_revert => &wrappers.op_revert_wrap,
        .op_invalid => &wrappers.op_invalid_wrap,
        
        // Arithmetic
        .op_add => &wrappers.op_add_wrap,
        .op_mul => &wrappers.op_mul_wrap,
        .op_sub => &wrappers.op_sub_wrap,
        .op_div => &wrappers.op_div_wrap,
        .op_sdiv => &wrappers.op_sdiv_wrap,
        .op_mod => &wrappers.op_mod_wrap,
        .op_smod => &wrappers.op_smod_wrap,
        .op_addmod => &wrappers.op_addmod_wrap,
        .op_mulmod => &wrappers.op_mulmod_wrap,
        .op_exp => &wrappers.op_exp_wrap,
        .op_signextend => &wrappers.op_signextend_wrap,
        
        // Comparison
        .op_lt => &wrappers.op_lt_wrap,
        .op_gt => &wrappers.op_gt_wrap,
        .op_slt => &wrappers.op_slt_wrap,
        .op_sgt => &wrappers.op_sgt_wrap,
        .op_eq => &wrappers.op_eq_wrap,
        .op_iszero => &wrappers.op_iszero_wrap,
        
        // Bitwise
        .op_and => &wrappers.op_and_wrap,
        .op_or => &wrappers.op_or_wrap,
        .op_xor => &wrappers.op_xor_wrap,
        .op_not => &wrappers.op_not_wrap,
        .op_byte => &wrappers.op_byte_wrap,
        .op_shl => &wrappers.op_shl_wrap,
        .op_shr => &wrappers.op_shr_wrap,
        .op_sar => &wrappers.op_sar_wrap,
        
        // Stack operations
        .op_pop => &wrappers.op_pop_wrap,
        .op_push0 => &wrappers.op_push0_wrap,
        .op_dup1 => &wrappers.op_dup1_wrap,
        .op_dup2 => &wrappers.op_dup2_wrap,
        .op_dup3 => &wrappers.op_dup3_wrap,
        .op_dup4 => &wrappers.op_dup4_wrap,
        .op_dup5 => &wrappers.op_dup5_wrap,
        .op_dup6 => &wrappers.op_dup6_wrap,
        .op_dup7 => &wrappers.op_dup7_wrap,
        .op_dup8 => &wrappers.op_dup8_wrap,
        .op_dup9 => &wrappers.op_dup9_wrap,
        .op_dup10 => &wrappers.op_dup10_wrap,
        .op_dup11 => &wrappers.op_dup11_wrap,
        .op_dup12 => &wrappers.op_dup12_wrap,
        .op_dup13 => &wrappers.op_dup13_wrap,
        .op_dup14 => &wrappers.op_dup14_wrap,
        .op_dup15 => &wrappers.op_dup15_wrap,
        .op_dup16 => &wrappers.op_dup16_wrap,
        .op_swap1 => &wrappers.op_swap1_wrap,
        .op_swap2 => &wrappers.op_swap2_wrap,
        .op_swap3 => &wrappers.op_swap3_wrap,
        .op_swap4 => &wrappers.op_swap4_wrap,
        .op_swap5 => &wrappers.op_swap5_wrap,
        .op_swap6 => &wrappers.op_swap6_wrap,
        .op_swap7 => &wrappers.op_swap7_wrap,
        .op_swap8 => &wrappers.op_swap8_wrap,
        .op_swap9 => &wrappers.op_swap9_wrap,
        .op_swap10 => &wrappers.op_swap10_wrap,
        .op_swap11 => &wrappers.op_swap11_wrap,
        .op_swap12 => &wrappers.op_swap12_wrap,
        .op_swap13 => &wrappers.op_swap13_wrap,
        .op_swap14 => &wrappers.op_swap14_wrap,
        .op_swap15 => &wrappers.op_swap15_wrap,
        .op_swap16 => &wrappers.op_swap16_wrap,
        
        // Memory operations
        .op_mload => &wrappers.op_mload_wrap,
        .op_mstore => &wrappers.op_mstore_wrap,
        .op_mstore8 => &wrappers.op_mstore8_wrap,
        .op_msize => &wrappers.op_msize_wrap,
        .op_mcopy => &wrappers.op_mcopy_wrap,
        
        // Control flow
        .op_jump => &wrappers.op_jump_wrap,
        .op_jumpi => &wrappers.op_jumpi_wrap,
        .op_pc => &wrappers.op_pc_wrap,
        .op_jumpdest => &wrappers.op_jumpdest_wrap,
        .op_gas => &wrappers.op_gas_wrap,
        
        // Push operations (handled via .word)
        .op_push1, .op_push2, .op_push3, .op_push4, .op_push5, .op_push6, .op_push7, .op_push8,
        .op_push9, .op_push10, .op_push11, .op_push12, .op_push13, .op_push14, .op_push15, .op_push16,
        .op_push17, .op_push18, .op_push19, .op_push20, .op_push21, .op_push22, .op_push23, .op_push24,
        .op_push25, .op_push26, .op_push27, .op_push28, .op_push29, .op_push30, .op_push31, .op_push32 => unreachable,
        
        // Environment operations
        .op_address => &wrappers.op_address_wrap,
        .op_balance => &wrappers.op_balance_wrap,
        .op_origin => &wrappers.op_origin_wrap,
        .op_caller => &wrappers.op_caller_wrap,
        .op_callvalue => &wrappers.op_callvalue_wrap,
        .op_calldataload => &wrappers.op_calldataload_wrap,
        .op_calldatasize => &wrappers.op_calldatasize_wrap,
        .op_calldatacopy => &wrappers.op_calldatacopy_wrap,
        .op_codesize => &wrappers.op_codesize_wrap,
        .op_codecopy => &wrappers.op_codecopy_wrap,
        .op_gasprice => &wrappers.op_gasprice_wrap,
        .op_extcodesize => &wrappers.op_extcodesize_wrap,
        .op_extcodecopy => &wrappers.op_extcodecopy_wrap,
        .op_returndatasize => &wrappers.op_returndatasize_wrap,
        .op_returndatacopy => &wrappers.op_returndatacopy_wrap,
        .op_extcodehash => &wrappers.op_extcodehash_wrap,
        
        // Block operations
        .op_blockhash => &wrappers.op_blockhash_wrap,
        .op_coinbase => &wrappers.op_coinbase_wrap,
        .op_timestamp => &wrappers.op_timestamp_wrap,
        .op_number => &wrappers.op_number_wrap,
        .op_difficulty => &wrappers.op_difficulty_wrap,
        .op_gaslimit => &wrappers.op_gaslimit_wrap,
        .op_chainid => &wrappers.op_chainid_wrap,
        .op_selfbalance => &wrappers.op_selfbalance_wrap,
        .op_basefee => &wrappers.op_basefee_wrap,
        .op_blobhash => &wrappers.op_blobhash_wrap,
        .op_blobbasefee => &wrappers.op_blobbasefee_wrap,
        
        // Storage operations
        .op_sload => &wrappers.op_sload_wrap,
        .op_sstore => &wrappers.op_sstore_wrap,
        .op_tload => &wrappers.op_tload_wrap,
        .op_tstore => &wrappers.op_tstore_wrap,
        
        // Crypto operations
        .op_keccak256 => &wrappers.op_keccak256_wrap,
        
        // Log operations
        .op_log0 => &wrappers.op_log0_wrap,
        .op_log1 => &wrappers.op_log1_wrap,
        .op_log2 => &wrappers.op_log2_wrap,
        .op_log3 => &wrappers.op_log3_wrap,
        .op_log4 => &wrappers.op_log4_wrap,
        
        // System operations
        .op_create => &wrappers.op_create_wrap,
        .op_call => &wrappers.op_call_wrap,
        .op_callcode => &wrappers.op_callcode_wrap,
        .op_delegatecall => &wrappers.op_delegatecall_wrap,
        .op_create2 => &wrappers.op_create2_wrap,
        .op_staticcall => &wrappers.op_staticcall_wrap,
        .op_selfdestruct => &wrappers.op_selfdestruct_wrap,
    };
}