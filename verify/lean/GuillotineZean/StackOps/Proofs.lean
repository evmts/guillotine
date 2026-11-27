/-
  GuillotineZean.StackOps.Proofs

  Direct Zig 0.17.1 AIR -> Lean 4 formal proofs for Guillotine's in-place
  256-bit EVM stack kernels in `src/core/verified_ops.zig`:
    - `stackPushAddTop`  (fused PUSH + ADD, wrapping mod 2^256)
    - `stackPushSubTop`  (fused PUSH + SUB, wrapping mod 2^256)
    - `stackPushMulTop`  (fused PUSH + MUL, wrapping mod 2^256)
    - `stackPushAndTop`  (fused PUSH + AND, bitwise 256-bit)
    - `stackPushXorTop`  (fused PUSH + XOR, bitwise 256-bit)
    - `stackSwap1Top`    (in-place SWAP1 permutation of top two 256-bit slots)

  Every theorem quantifies universally over ALL `2^256 × 2^256` EVM word inputs
  and arbitrary valid heaps, directly over the Zean-captured Zig 0.17.1 AIR in
  `GuillotineZean.StackOps.Generated`.
-/
import GuillotineZean.StackOps.Generated
import GuillotineZean.MemoryHelpers

namespace GuillotineZean.StackOps
open Compiler.ZigAir Compiler.ZigAir.Memory Compiler.ZigAir.MemoryAir
open GuillotineZean.MemoryHelpers

/-- Shared proof skeleton for all five in-place 2-pointer 256-bit stack kernels
    (`stackPushAddTop`, `stackPushSubTop`, `stackPushMulTop`, `stackPushAndTop`, `stackPushXorTop`). -/
private theorem binary_stack_op_kernel
    (op : Scalar.Prim) (state after : State) (topPtr immPtr : Value) (top imm result : BitVec 256)
    (hvalid : state.valid = true)
    (ht_top : topPtr.hasType (.pointer true false u256Ty) = true)
    (ht_imm : immPtr.hasType (.pointer false false u256Ty) = true)
    (hload_imm : Memory.load state immPtr = .ok (u256Val imm))
    (hload_top : Memory.load state topPtr = .ok (u256Val top))
    (hstore : Memory.store state topPtr (u256Val result) = .ok after)
    (hop : ∀ (env : Env),
      env 2 = some (u256Val imm) → env 4 = some (u256Val top) →
      op.eval [] (scalarEnv env) = .ok (.int false 256 result.toNat)) :
    let prog : Program :=
      { parameters := [.pointer true false u256Ty, .pointer false false u256Ty]
        returnType := .scalar .unit
        body :=
          .bind 0 (.pointer true false u256Ty) (.argument 0)
          (.bind 1 (.pointer false false u256Ty) (.argument 1)
          (.bind 2 u256Ty (.load (.local 1))
          (.bind 4 u256Ty (.load (.local 0))
          (.bind 5 u256Ty (.scalar op)
          (.bind 6 (.scalar .unit) (.store (.local 0) (.local 5))
          (.ret (.constant (.scalar .unit)))))))) }
    prog.run [topPtr, immPtr] state = (.ok (.scalar .unit), after) ∧
    after.valid = true ∧
    Memory.load after topPtr = .ok (u256Val result) := by
  intro prog
  have hv_top : topPtr.valid = true := ptr_valid_of_hasType ht_top
  have hv_imm : immPtr.valid = true := ptr_valid_of_hasType ht_imm
  have hacc : prog.accepts [topPtr, immPtr] state = true := by
    simp [Program.accepts, prog, hvalid, ht_top, ht_imm]
  have hrun : prog.run [topPtr, immPtr] state = (.ok (.scalar .unit), Memory.cleanup state.nextId after) := by
    refine program_run_ok hacc ?_ unit_val_hasType
    dsimp only [prog]
    rw [eval_bind_ok (prim_arg_eval rfl) ht_top]
    rw [eval_bind_ok (prim_arg_eval rfl) ht_imm]
    rw [eval_bind_ok (prim_load_eval (ref_local_eval (env_set_self ..) hv_imm) hload_imm) (u256_val_hasType imm)]
    rw [eval_bind_ok (prim_load_eval (ref_local_eval
      (by rw [env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_self]) hv_top) hload_top) (u256_val_hasType top)]
    rw [eval_bind_ok (prim_scalar_eval (hop _
      (by rw [env_set_ne _ _ _ _ (by decide), env_set_self])
      (env_set_self ..))) (u256_val_hasType result)]
    rw [eval_bind_ok (prim_store_eval
      (ref_local_eval (by rw [env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_self]) hv_top)
      (ref_local_eval (env_set_self ..) (u256_val_valid result))
      hstore) unit_val_hasType]
    exact eval_ret_ok (ref_const_eval unit_val_valid)
  rw [cleanup_after_store state after topPtr (u256Val result) hvalid hstore] at hrun
  exact ⟨hrun, Memory.store_preserves_valid state topPtr (u256Val result) after hvalid hstore,
    Memory.load_after_store state topPtr (u256Val result) after hstore⟩

/-- Direct Zig AIR proof: `verified_ops.stackPushAddTop` computes exact 256-bit
    wrapping EVM `PUSH + ADD` (`imm + top mod 2^256`) in-place on `*u256`. -/
theorem stack_push_add_top_correct (state after : State) (topPtr immPtr : Value) (top imm : BitVec 256)
    (hvalid : state.valid = true)
    (ht_top : topPtr.hasType (.pointer true false u256Ty) = true)
    (ht_imm : immPtr.hasType (.pointer false false u256Ty) = true)
    (hload_imm : Memory.load state immPtr = .ok (u256Val imm))
    (hload_top : Memory.load state topPtr = .ok (u256Val top))
    (hstore : Memory.store state topPtr (u256Val (imm + top)) = .ok after) :
    Generated.fn_stack_push_add_top.run [topPtr, immPtr] state = (.ok (.scalar .unit), after) ∧
    after.valid = true ∧
    Memory.load after topPtr = .ok (u256Val (imm + top)) := by
  exact binary_stack_op_kernel
    (.arithmetic .add .wrapping (.local 2) (.local 4))
    state after topPtr immPtr top imm (imm + top)
    hvalid ht_top ht_imm hload_imm hload_top hstore fun env h2 h4 =>
      scalar_arith_eval
        (scalar_ref_local_eval (scalarEnv_of_env h2) (u256_scalar_valid imm))
        (scalar_ref_local_eval (scalarEnv_of_env h4) (u256_scalar_valid top))
        (by
          change Scalar.integer false 256 ((imm.toNat : Int) + top.toNat) .wrapping = _
          rw [integer_wrapping_uint, bv256_add_int_mod])

/-- Direct Zig AIR proof: `verified_ops.stackPushSubTop` computes exact 256-bit
    wrapping EVM `PUSH + SUB` (`imm - top mod 2^256`) in-place on `*u256`. -/
theorem stack_push_sub_top_correct (state after : State) (topPtr immPtr : Value) (top imm : BitVec 256)
    (hvalid : state.valid = true)
    (ht_top : topPtr.hasType (.pointer true false u256Ty) = true)
    (ht_imm : immPtr.hasType (.pointer false false u256Ty) = true)
    (hload_imm : Memory.load state immPtr = .ok (u256Val imm))
    (hload_top : Memory.load state topPtr = .ok (u256Val top))
    (hstore : Memory.store state topPtr (u256Val (imm - top)) = .ok after) :
    Generated.fn_stack_push_sub_top.run [topPtr, immPtr] state = (.ok (.scalar .unit), after) ∧
    after.valid = true ∧
    Memory.load after topPtr = .ok (u256Val (imm - top)) := by
  exact binary_stack_op_kernel
    (.arithmetic .sub .wrapping (.local 2) (.local 4))
    state after topPtr immPtr top imm (imm - top)
    hvalid ht_top ht_imm hload_imm hload_top hstore fun env h2 h4 =>
      scalar_arith_eval
        (scalar_ref_local_eval (scalarEnv_of_env h2) (u256_scalar_valid imm))
        (scalar_ref_local_eval (scalarEnv_of_env h4) (u256_scalar_valid top))
        (by
          change Scalar.integer false 256 ((imm.toNat : Int) - top.toNat) .wrapping = _
          rw [integer_wrapping_uint, bv256_sub_int_mod])

/-- Direct Zig AIR proof: `verified_ops.stackPushMulTop` computes exact 256-bit
    wrapping EVM `PUSH + MUL` (`imm * top mod 2^256`) in-place on `*u256`. -/
theorem stack_push_mul_top_correct (state after : State) (topPtr immPtr : Value) (top imm : BitVec 256)
    (hvalid : state.valid = true)
    (ht_top : topPtr.hasType (.pointer true false u256Ty) = true)
    (ht_imm : immPtr.hasType (.pointer false false u256Ty) = true)
    (hload_imm : Memory.load state immPtr = .ok (u256Val imm))
    (hload_top : Memory.load state topPtr = .ok (u256Val top))
    (hstore : Memory.store state topPtr (u256Val (imm * top)) = .ok after) :
    Generated.fn_stack_push_mul_top.run [topPtr, immPtr] state = (.ok (.scalar .unit), after) ∧
    after.valid = true ∧
    Memory.load after topPtr = .ok (u256Val (imm * top)) := by
  exact binary_stack_op_kernel
    (.arithmetic .mul .wrapping (.local 2) (.local 4))
    state after topPtr immPtr top imm (imm * top)
    hvalid ht_top ht_imm hload_imm hload_top hstore fun env h2 h4 =>
      scalar_arith_eval
        (scalar_ref_local_eval (scalarEnv_of_env h2) (u256_scalar_valid imm))
        (scalar_ref_local_eval (scalarEnv_of_env h4) (u256_scalar_valid top))
        (by
          change Scalar.integer false 256 ((imm.toNat : Int) * top.toNat) .wrapping = _
          rw [integer_wrapping_uint, bv256_mul_int_mod])

/-- Direct Zig AIR proof: `verified_ops.stackPushAndTop` computes exact 256-bit
    bitwise EVM `PUSH + AND` (`imm &&& top`) in-place on `*u256`. -/
theorem stack_push_and_top_correct (state after : State) (topPtr immPtr : Value) (top imm : BitVec 256)
    (hvalid : state.valid = true)
    (ht_top : topPtr.hasType (.pointer true false u256Ty) = true)
    (ht_imm : immPtr.hasType (.pointer false false u256Ty) = true)
    (hload_imm : Memory.load state immPtr = .ok (u256Val imm))
    (hload_top : Memory.load state topPtr = .ok (u256Val top))
    (hstore : Memory.store state topPtr (u256Val (imm &&& top)) = .ok after) :
    Generated.fn_stack_push_and_top.run [topPtr, immPtr] state = (.ok (.scalar .unit), after) ∧
    after.valid = true ∧
    Memory.load after topPtr = .ok (u256Val (imm &&& top)) := by
  exact binary_stack_op_kernel
    (.bitAnd (.local 2) (.local 4))
    state after topPtr immPtr top imm (imm &&& top)
    hvalid ht_top ht_imm hload_imm hload_top hstore fun env h2 h4 => by
      have h := Scalar.bitAnd_eval (.local 2) (.local 4) [] (scalarEnv env) imm.toNat top.toNat 256
        (scalar_ref_local_eval (scalarEnv_of_env h2) (u256_scalar_valid imm))
        (scalar_ref_local_eval (scalarEnv_of_env h4) (u256_scalar_valid top))
      rw [bv256_and_nat] at h
      exact h

/-- Direct Zig AIR proof: `verified_ops.stackPushXorTop` computes exact 256-bit
    bitwise EVM `PUSH + XOR` (`imm ^^^ top`) in-place on `*u256`. -/
theorem stack_push_xor_top_correct (state after : State) (topPtr immPtr : Value) (top imm : BitVec 256)
    (hvalid : state.valid = true)
    (ht_top : topPtr.hasType (.pointer true false u256Ty) = true)
    (ht_imm : immPtr.hasType (.pointer false false u256Ty) = true)
    (hload_imm : Memory.load state immPtr = .ok (u256Val imm))
    (hload_top : Memory.load state topPtr = .ok (u256Val top))
    (hstore : Memory.store state topPtr (u256Val (imm ^^^ top)) = .ok after) :
    Generated.fn_stack_push_xor_top.run [topPtr, immPtr] state = (.ok (.scalar .unit), after) ∧
    after.valid = true ∧
    Memory.load after topPtr = .ok (u256Val (imm ^^^ top)) := by
  exact binary_stack_op_kernel
    (.bitXor (.local 2) (.local 4))
    state after topPtr immPtr top imm (imm ^^^ top)
    hvalid ht_top ht_imm hload_imm hload_top hstore fun env h2 h4 => by
      have h := scalar_bitXor_eval (left := .local 2) (right := .local 4)
        (args := []) (env := scalarEnv env) (x := imm.toNat) (y := top.toNat) (n := 256)
        (scalar_ref_local_eval (scalarEnv_of_env h2) (u256_scalar_valid imm))
        (scalar_ref_local_eval (scalarEnv_of_env h4) (u256_scalar_valid top))
      rw [bv256_xor_nat] at h
      exact h

/-- Direct Zig AIR proof: `verified_ops.stackSwap1Top` performs the exact in-place
    EVM `SWAP1` permutation `[v0, v1] ↦ [v1, v0]` on the top two 256-bit stack slots,
    preserves heap validity, and cleans up its temporary stack pointer slot. -/
theorem stack_swap1_top_correct
    (state sAlloc sSlot s1 s2 : State)
    (spPtr allocPtr castPtr slot0 slot1 : Value)
    (v0 v1 : BitVec 256)
    (hvalid : state.valid = true)
    (ht_sp : spPtr.hasType (.pointer true true u256Ty) = true)
    (ht_alloc : allocPtr.hasType (.pointer true false (.pointer true true u256Ty)) = true)
    (ht_cast : castPtr.hasType (.pointer false false (.pointer true true u256Ty)) = true)
    (ht_s0 : slot0.hasType (.pointer true false u256Ty) = true)
    (ht_s1 : slot1.hasType (.pointer true false u256Ty) = true)
    (halloc : Memory.allocate state (.pointer true true u256Ty) = .ok (allocPtr, sAlloc))
    (hstore_slot : Memory.store sAlloc allocPtr spPtr = .ok sSlot)
    (hcast : Memory.pointerCast sSlot (.pointer false false (.pointer true true u256Ty)) allocPtr = .ok castPtr)
    (hload_sp_slot : Memory.load sSlot castPtr = .ok spPtr)
    (helem0_slot : Memory.elementPointer sSlot spPtr 0 = .ok slot0)
    (hload0 : Memory.load sSlot slot0 = .ok (u256Val v0))
    (helem1_slot : Memory.elementPointer sSlot spPtr 1 = .ok slot1)
    (hload1 : Memory.load sSlot slot1 = .ok (u256Val v1))
    (hstore0 : Memory.store sSlot slot0 (u256Val v1) = .ok s1)
    (hload_sp_s1 : Memory.load s1 castPtr = .ok spPtr)
    (helem1_s1 : Memory.elementPointer s1 spPtr 1 = .ok slot1)
    (hstore1 : Memory.store s1 slot1 (u256Val v0) = .ok s2) :
    let after := Memory.cleanup state.nextId s2
    Generated.fn_stack_swap1_top.run [spPtr] state = (.ok (.scalar .unit), after) ∧
    after.valid = true := by
  intro after
  have hv_sp : spPtr.valid = true := ptr_valid_of_hasType ht_sp
  have hv_alloc : allocPtr.valid = true := ptr_valid_of_hasType ht_alloc
  have hv_cast : castPtr.valid = true := ptr_valid_of_hasType ht_cast
  have hv_s0 : slot0.valid = true := ptr_valid_of_hasType ht_s0
  have hv_s1 : slot1.valid = true := ptr_valid_of_hasType ht_s1
  have hv_0 : (Memory.Value.scalar (.int false 64 0)).valid = true :=
    mem_scalar_valid (scalar_valid_of_nat (w := 64) (x := 0) (by omega))
  have hv_1 : (Memory.Value.scalar (.int false 64 1)).valid = true :=
    mem_scalar_valid (scalar_valid_of_nat (w := 64) (x := 1) (by omega))
  have hacc : Generated.fn_stack_swap1_top.accepts [spPtr] state = true := by
    simp [Program.accepts, Generated.fn_stack_swap1_top, hvalid, ht_sp]
  have hsAlloc_valid : sAlloc.valid = true :=
    Memory.allocate_preserves_valid state (.pointer true true u256Ty) allocPtr sAlloc halloc
  have hsSlot_valid : sSlot.valid = true :=
    Memory.store_preserves_valid sAlloc allocPtr spPtr sSlot hsAlloc_valid hstore_slot
  have hs1_valid : s1.valid = true :=
    Memory.store_preserves_valid sSlot slot0 (u256Val v1) s1 hsSlot_valid hstore0
  have hs2_valid : s2.valid = true :=
    Memory.store_preserves_valid s1 slot1 (u256Val v0) s2 hs1_valid hstore1
  refine ⟨program_run_ok hacc ?_ unit_val_hasType, Memory.cleanup_preserves_valid state.nextId s2 hs2_valid⟩
  unfold Generated.fn_stack_swap1_top; dsimp only
  rw [eval_bind_ok (prim_arg_eval rfl) ht_sp]
  rw [eval_bind_ok (prim_alloc_eval halloc) ht_alloc]
  rw [eval_bind_ok (prim_store_eval (ref_local_eval (env_set_self ..) hv_alloc)
    (ref_local_eval (by rw [env_set_ne _ _ _ _ (by decide), env_set_self]) hv_sp) hstore_slot) unit_val_hasType]
  rw [eval_bind_ok (prim_pointerCast_eval
    (ref_local_eval (by rw [env_set_ne _ _ _ _ (by decide), env_set_self]) hv_alloc) hcast) ht_cast]
  -- step 5: load spPtr from castPtr
  rw [eval_bind_ok (prim_load_eval (ref_local_eval (env_set_self ..) hv_cast) hload_sp_slot) ht_sp]
  -- step 6: elementPointer spPtr 0
  rw [eval_bind_ok (prim_elementPointer_eval (ref_local_eval (env_set_self ..) hv_sp)
    ref_natural_zero helem0_slot) ht_s0]
  -- step 7: load v0 from slot0
  rw [eval_bind_ok (prim_load_eval (ref_local_eval (env_set_self ..) hv_s0) hload0) (u256_val_hasType v0)]
  -- step 8: load spPtr from castPtr
  rw [eval_bind_ok (prim_load_eval (ref_local_eval
    (by rw [env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_self]) hv_cast) hload_sp_slot) ht_sp]
  -- step 9: elementPointer spPtr 1
  rw [eval_bind_ok (prim_elementPointer_eval (ref_local_eval (env_set_self ..) hv_sp)
    ref_natural_one helem1_slot) ht_s1]
  -- step 10: load v1 from slot1
  rw [eval_bind_ok (prim_load_eval (ref_local_eval (env_set_self ..) hv_s1) hload1) (u256_val_hasType v1)]
  -- step 11: load spPtr from castPtr
  rw [eval_bind_ok (prim_load_eval (ref_local_eval
    (by rw [env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide),
            env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_self]) hv_cast) hload_sp_slot) ht_sp]
  -- step 12: elementPointer spPtr 0
  rw [eval_bind_ok (prim_elementPointer_eval (ref_local_eval (env_set_self ..) hv_sp)
    ref_natural_zero helem0_slot) ht_s0]
  -- step 13: store v1 into slot0 -> s1
  rw [eval_bind_ok (prim_store_eval
    (ref_local_eval (env_set_self ..) hv_s0)
    (ref_local_eval (by rw [env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_self]) (u256_val_valid v1))
    hstore0) unit_val_hasType]
  -- step 14: load spPtr from castPtr in s1
  rw [eval_bind_ok (prim_load_eval (ref_local_eval
    (by rw [env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide),
            env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide),
            env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_self]) hv_cast) hload_sp_s1) ht_sp]
  -- step 15: elementPointer spPtr 1 in s1
  rw [eval_bind_ok (prim_elementPointer_eval (ref_local_eval (env_set_self ..) hv_sp)
    ref_natural_one helem1_s1) ht_s1]
  -- step 16: store v0 into slot1 -> s2
  rw [eval_bind_ok (prim_store_eval
    (ref_local_eval (env_set_self ..) hv_s1)
    (ref_local_eval (by rw [env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide),
                            env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide),
                            env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_self]) (u256_val_valid v0))
    hstore1) unit_val_hasType]
  exact eval_ret_ok (ref_const_eval unit_val_valid)

end GuillotineZean.StackOps
