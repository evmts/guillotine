/-
  GuillotineZean

  Root aggregator and compile-time axiom audit for Guillotine's direct
  Zig 0.17.1 AIR -> Lean 4.35.0 formal verification suite powered by Zean
  (`okcontract/zean`).

  Every captured Zig function from `src/core/verified_ops.zig` is checked via:
    1. A kernel-checked `Captured.decode` / `CapturedScalar.decode` correspondence
       certificate linking the raw compiler-captured Zig AIR JSON to the Lean AST.
    2. Direct functional correctness, fast-vs-reference equivalence, memory safety,
       and heap-framing proofs over the captured Zig AIR semantics.
    3. `#audit_proof` verification confirming every theorem exists in its declared
       module and depends ONLY on Lean's standard logical axioms (`propext`,
       `Classical.choice`, `Quot.sound`) — zero `sorryAx`, zero custom axioms.
-/
import Compiler.ZigAir.ProofAudit
import GuillotineZean.ScalarOps.Generated
import GuillotineZean.ScalarOps.Proofs
import GuillotineZean.Word256Ops.Generated
import GuillotineZean.Word256Ops.Proofs
import GuillotineZean.StackOps.Generated
import GuillotineZean.StackOps.Proofs
import GuillotineZean.JumpBsearch.Generated
import GuillotineZean.JumpBsearch.Proofs
import GuillotineZean.BytecodeJumpdest.Generated
import GuillotineZean.BytecodeJumpdest.Proofs
import GuillotineZean.MemoryCopy.Generated
import GuillotineZean.MemoryCopy.Proofs

-- 1. ScalarOps: 5 captured Zig AIR correspondence certificates + 7 proofs
#audit_proof "GuillotineZean.ScalarOps.Generated.fn_align_up_32_correspondence" from ["GuillotineZean.ScalarOps.Generated"]
#audit_proof "GuillotineZean.ScalarOps.Generated.fn_memory_word_count_fast_correspondence" from ["GuillotineZean.ScalarOps.Generated"]
#audit_proof "GuillotineZean.ScalarOps.Generated.fn_memory_gas_cost_correspondence" from ["GuillotineZean.ScalarOps.Generated"]
#audit_proof "GuillotineZean.ScalarOps.Generated.fn_block_stack_guard_fast_correspondence" from ["GuillotineZean.ScalarOps.Generated"]
#audit_proof "GuillotineZean.ScalarOps.Generated.fn_block_stack_guard_ref_correspondence" from ["GuillotineZean.ScalarOps.Generated"]

#audit_proof "GuillotineZean.ScalarOps.align_up_32_correct" from ["GuillotineZean.ScalarOps.Proofs"]
#audit_proof "GuillotineZean.ScalarOps.memory_word_count_fast_correct" from ["GuillotineZean.ScalarOps.Proofs"]
#audit_proof "GuillotineZean.ScalarOps.memory_gas_cost_correct" from ["GuillotineZean.ScalarOps.Proofs"]
#audit_proof "GuillotineZean.ScalarOps.memory_gas_cost_monotone" from ["GuillotineZean.ScalarOps.Proofs"]
#audit_proof "GuillotineZean.ScalarOps.block_stack_guard_ref_correct" from ["GuillotineZean.ScalarOps.Proofs"]
#audit_proof "GuillotineZean.ScalarOps.block_stack_guard_fast_correct" from ["GuillotineZean.ScalarOps.Proofs"]
#audit_proof "GuillotineZean.ScalarOps.block_stack_guard_fast_eq_ref" from ["GuillotineZean.ScalarOps.Proofs"]

-- 2. Word256Ops: 10 captured Zig AIR correspondence certificates + 12 proofs
#audit_proof "GuillotineZean.Word256Ops.Generated.fn_check_memory_bounds_fast_correspondence" from ["GuillotineZean.Word256Ops.Generated"]
#audit_proof "GuillotineZean.Word256Ops.Generated.fn_check_memory_bounds_word32_fast_correspondence" from ["GuillotineZean.Word256Ops.Generated"]
#audit_proof "GuillotineZean.Word256Ops.Generated.fn_check_memory_bounds_byte1_fast_correspondence" from ["GuillotineZean.Word256Ops.Generated"]
#audit_proof "GuillotineZean.Word256Ops.Generated.fn_dense_jump_bounds_fast_correspondence" from ["GuillotineZean.Word256Ops.Generated"]
#audit_proof "GuillotineZean.Word256Ops.Generated.fn_dense_jump_bounds_u16_ref_correspondence" from ["GuillotineZean.Word256Ops.Generated"]
#audit_proof "GuillotineZean.Word256Ops.Generated.fn_dense_jump_bounds_u32_ref_correspondence" from ["GuillotineZean.Word256Ops.Generated"]
#audit_proof "GuillotineZean.Word256Ops.Generated.fn_abs_two_comp_correspondence" from ["GuillotineZean.Word256Ops.Generated"]
#audit_proof "GuillotineZean.Word256Ops.Generated.fn_sdiv_sign_apply_correspondence" from ["GuillotineZean.Word256Ops.Generated"]
#audit_proof "GuillotineZean.Word256Ops.Generated.fn_smod_sign_apply_correspondence" from ["GuillotineZean.Word256Ops.Generated"]
#audit_proof "GuillotineZean.Word256Ops.Generated.fn_byte_ref_correspondence" from ["GuillotineZean.Word256Ops.Generated"]

#audit_proof "GuillotineZean.Word256Ops.check_memory_bounds_fast_correct" from ["GuillotineZean.Word256Ops.Proofs"]
#audit_proof "GuillotineZean.Word256Ops.check_memory_bounds_word32_fast_correct" from ["GuillotineZean.Word256Ops.Proofs"]
#audit_proof "GuillotineZean.Word256Ops.check_memory_bounds_byte1_fast_correct" from ["GuillotineZean.Word256Ops.Proofs"]
#audit_proof "GuillotineZean.Word256Ops.dense_jump_bounds_fast_correct" from ["GuillotineZean.Word256Ops.Proofs"]
#audit_proof "GuillotineZean.Word256Ops.dense_jump_bounds_u16_ref_correct" from ["GuillotineZean.Word256Ops.Proofs"]
#audit_proof "GuillotineZean.Word256Ops.dense_jump_bounds_fast_eq_u16_ref" from ["GuillotineZean.Word256Ops.Proofs"]
#audit_proof "GuillotineZean.Word256Ops.dense_jump_bounds_u32_ref_correct" from ["GuillotineZean.Word256Ops.Proofs"]
#audit_proof "GuillotineZean.Word256Ops.dense_jump_bounds_fast_eq_u32_ref" from ["GuillotineZean.Word256Ops.Proofs"]
#audit_proof "GuillotineZean.Word256Ops.abs_two_comp_correct" from ["GuillotineZean.Word256Ops.Proofs"]
#audit_proof "GuillotineZean.Word256Ops.sdiv_sign_apply_correct" from ["GuillotineZean.Word256Ops.Proofs"]
#audit_proof "GuillotineZean.Word256Ops.smod_sign_apply_correct" from ["GuillotineZean.Word256Ops.Proofs"]
#audit_proof "GuillotineZean.Word256Ops.byte_ref_correct" from ["GuillotineZean.Word256Ops.Proofs"]

-- 3. StackOps: 6 captured Zig AIR correspondence certificates + 6 proofs
#audit_proof "GuillotineZean.StackOps.Generated.fn_stack_push_add_top_correspondence" from ["GuillotineZean.StackOps.Generated"]
#audit_proof "GuillotineZean.StackOps.Generated.fn_stack_push_sub_top_correspondence" from ["GuillotineZean.StackOps.Generated"]
#audit_proof "GuillotineZean.StackOps.Generated.fn_stack_push_mul_top_correspondence" from ["GuillotineZean.StackOps.Generated"]
#audit_proof "GuillotineZean.StackOps.Generated.fn_stack_push_and_top_correspondence" from ["GuillotineZean.StackOps.Generated"]
#audit_proof "GuillotineZean.StackOps.Generated.fn_stack_push_xor_top_correspondence" from ["GuillotineZean.StackOps.Generated"]
#audit_proof "GuillotineZean.StackOps.Generated.fn_stack_swap1_top_correspondence" from ["GuillotineZean.StackOps.Generated"]

#audit_proof "GuillotineZean.StackOps.stack_push_add_top_correct" from ["GuillotineZean.StackOps.Proofs"]
#audit_proof "GuillotineZean.StackOps.stack_push_sub_top_correct" from ["GuillotineZean.StackOps.Proofs"]
#audit_proof "GuillotineZean.StackOps.stack_push_mul_top_correct" from ["GuillotineZean.StackOps.Proofs"]
#audit_proof "GuillotineZean.StackOps.stack_push_and_top_correct" from ["GuillotineZean.StackOps.Proofs"]
#audit_proof "GuillotineZean.StackOps.stack_push_xor_top_correct" from ["GuillotineZean.StackOps.Proofs"]
#audit_proof "GuillotineZean.StackOps.stack_swap1_top_correct" from ["GuillotineZean.StackOps.Proofs"]

-- 4. JumpBsearch: 1 captured Zig AIR correspondence certificate + 2 loop proofs
#audit_proof "GuillotineZean.JumpBsearch.Generated.fn_bsearch_jump_table_u32_correspondence" from ["GuillotineZean.JumpBsearch.Generated"]
#audit_proof "GuillotineZean.JumpBsearch.bsearch_jump_table_u32_contract" from ["GuillotineZean.JumpBsearch.Proofs"]
#audit_proof "GuillotineZean.JumpBsearch.bsearch_jump_table_u32_safe" from ["GuillotineZean.JumpBsearch.Proofs"]

-- 5. BytecodeJumpdest: 1 captured Zig AIR correspondence certificate + 2 loop proofs
#audit_proof "GuillotineZean.BytecodeJumpdest.Generated.fn_is_valid_jumpdest_bytes_correspondence" from ["GuillotineZean.BytecodeJumpdest.Generated"]
#audit_proof "GuillotineZean.BytecodeJumpdest.is_valid_jumpdest_bytes_contract" from ["GuillotineZean.BytecodeJumpdest.Proofs"]
#audit_proof "GuillotineZean.BytecodeJumpdest.is_valid_jumpdest_bytes_safe" from ["GuillotineZean.BytecodeJumpdest.Proofs"]

-- 6. MemoryCopy: 1 captured Zig AIR correspondence certificate + 2 loop proofs
#audit_proof "GuillotineZean.MemoryCopy.Generated.fn_copy_evm_bytes_correspondence" from ["GuillotineZean.MemoryCopy.Generated"]
#audit_proof "GuillotineZean.MemoryCopy.copy_evm_bytes_contract" from ["GuillotineZean.MemoryCopy.Proofs"]
#audit_proof "GuillotineZean.MemoryCopy.copy_evm_bytes_safe" from ["GuillotineZean.MemoryCopy.Proofs"]
