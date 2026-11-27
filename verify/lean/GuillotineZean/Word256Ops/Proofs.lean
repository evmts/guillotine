/-
  GuillotineZean.Word256Ops.Proofs

  Direct Zig 0.17.1 AIR -> Lean 4 formal proofs for Guillotine's 10 core
  256-bit EVM word kernels in `src/core/verified_ops.zig`, captured directly
  via Zean (`zean --check`) using Zean's native `u256` memory layout:
    1. `checkMemoryBoundsFast`        (general `u256` offset + `u64` size vs 16 MiB cap)
    2. `checkMemoryBoundsWord32Fast`  (MLOAD/MSTORE 32-byte fast path)
    3. `checkMemoryBoundsByte1Fast`   (MSTORE8 1-byte fast path)
    4. `denseJumpBoundsFast`          (branchless `u256` jump-table bounds check)
    5. `denseJumpBoundsU16Ref`        (16-bit dense jump-table reference guard)
    6. `denseJumpBoundsU32Ref`        (32-bit dense jump-table reference guard)
    7. `absTwoComp`                   (branchless 256-bit two's-complement |x|)
    8. `sdivSignApply`                (branchless 256-bit SDIV sign restoration)
    9. `smodSignApply`                (branchless 256-bit SMOD sign restoration)
   10. `byteRef`                      (Yellow Paper BYTE(index, word) extractor)

  Every theorem proves universal correctness across all `2^256` inputs directly
  on the Zean-captured Zig AIR and links to `GuillotineVerify` reference specs.
-/
import GuillotineZean.Word256Ops.Generated
import GuillotineZean.MemoryHelpers
import GuillotineVerify.Memory
import GuillotineVerify.JumpTable
import GuillotineVerify.Arithmetic

namespace GuillotineZean.Word256Ops
open Compiler.ZigAir Compiler.ZigAir.Memory Compiler.ZigAir.MemoryAir
open GuillotineZean.MemoryHelpers

private abbrev memLimit : BitVec 64 := BitVec.ofNat 64 16777215

/-- Direct Zig AIR proof: `verified_ops.checkMemoryBoundsFast` matches
    `GuillotineVerify.Memory.checkMemoryBoundsRef` (and `checkMemoryBoundsFast`)
    for ALL `u256` offsets and `u64` sizes with 16 MiB (`0xFFFFFF`) memory cap,
    preserving the heap untouched. -/
theorem check_memory_bounds_fast_correct (state : State) (offPtr : Value)
    (offset : BitVec 256) (size : BitVec 64)
    (hvalid : state.valid = true)
    (ht_off : offPtr.hasType (.pointer false false u256Ty) = true)
    (hload : Memory.load state offPtr = .ok (u256Val offset)) :
    Generated.fn_check_memory_bounds_fast.run [offPtr, .scalar (.int false 64 size.toNat)] state =
      (.ok (.scalar (.bool (GuillotineVerify.Memory.checkMemoryBoundsRef offset size memLimit))), state) := by
  rw [← GuillotineVerify.Memory.checkMemoryBoundsFast_eq_ref]
  have hv_offp : offPtr.valid = true := ptr_valid_of_hasType ht_off
  have hv_sz_s : (Scalar.Value.int false 64 size.toNat).valid = true := scalar_valid_of_nat size.isLt
  have ht_sz : (Memory.Value.scalar (.int false 64 size.toNat)).hasType (.scalar (.int false 64)) = true :=
    mem_scalar_hasType (scalar_hasType_of_valid hv_sz_s)
  have hv_lim_s : (Scalar.Value.int false 64 16777215).valid = true := Scalar.unsigned_nat_valid 16777215 64 (by omega)
  have hacc : Generated.fn_check_memory_bounds_fast.accepts [offPtr, .scalar (.int false 64 size.toNat)] state = true := by
    simp [Program.accepts, Generated.fn_check_memory_bounds_fast, hvalid, ht_off, ht_sz]
  suffices hrun : Generated.fn_check_memory_bounds_fast.run [offPtr, .scalar (.int false 64 size.toNat)] state =
      (.ok (.scalar (.bool (GuillotineVerify.Memory.checkMemoryBoundsFast offset size memLimit))), Memory.cleanup state.nextId state) by
    rwa [cleanup_same_nextId state hvalid] at hrun
  refine program_run_ok hacc ?_ (bool_val_hasType _)
  unfold Generated.fn_check_memory_bounds_fast GuillotineVerify.Memory.checkMemoryBoundsFast
  dsimp only
  have hlim_val : memLimit.toNat = 16777215 := rfl
  rw [hlim_val]
  rw [eval_bind_ok (prim_arg_eval rfl) ht_off]
  rw [eval_bind_ok (prim_arg_eval rfl) ht_sz]
  rw [eval_bind_ok (prim_load_eval (ref_local_eval (by rw [env_set_ne _ _ _ _ (by decide), env_set_self]) hv_offp) hload) (u256_val_hasType offset)]
  let args := [offPtr, Memory.Value.scalar (.int false 64 size.toNat)]
  let env0 : Env := Control.Env.set (Control.Env.set (Control.Env.set (fun _ => none) 0 offPtr) 1 (.scalar (.int false 64 size.toNat))) 2 (u256Val offset)
  change Control.Code.eval MemoryAir.semantics _ args env0 state = _
  have he0_1 : env0 1 = some (.scalar (.int false 64 size.toNat)) := by
    simp only [env0]; rw [env_set_ne _ _ _ _ (by decide), env_set_self]
  have he0_2 : env0 2 = some (u256Val offset) := by
    simp only [env0]; rw [env_set_self]
  by_cases hgt : size.toNat > 16777215
  · have hres : decide (size.toNat ≤ 16777215 ∧ offset.toNat ≤ (memLimit - size).toNat) = false := by
      simp only [decide_eq_false_iff_not]; omega
    rw [hres]
    have hb4 : Control.Code.eval MemoryAir.semantics
        (.bind 5 (.scalar .bool) (.scalar (.comparison .gt (.local 1) (.constant (.int false 64 16777215))))
        (.branch (.local 5) (.jump 3 (.constant (.scalar (.bool false)))) (.jump 4 (.constant (.scalar .unit)))))
        args env0 state = .jumped 3 (.scalar (.bool false)) (Control.Env.set env0 5 (.scalar (.bool true))) state := by
      rw [eval_bind_ok (prim_scalar_eval (scalar_cmp_eval
        (scalar_ref_local_eval (scalarEnv_of_env he0_1) hv_sz_s)
        (scalar_ref_const_eval hv_lim_s)
        (show Scalar.Comparison.gt.eval size.toNat 16777215 = true by simp [Scalar.Comparison.eval]; omega))) (bool_val_hasType true)]
      rw [eval_branch_true (ref_local_eval (env_set_self ..) (bool_val_valid true))]
      exact eval_jump_ok (ref_const_eval (bool_val_valid false))
    rw [eval_block_jump_hit (eval_block_jump_miss hb4 (by decide)) (bool_val_hasType false)]
    exact eval_ret_ok (ref_local_eval (env_set_self ..) (bool_val_valid false))
  · have hle : size.toNat ≤ 16777215 := by omega
    have hsub_bv : (memLimit - size).toNat = 16777215 - size.toNat := by
      rw [BitVec.toNat_sub_of_le (show size ≤ memLimit from by change size.toNat ≤ memLimit.toNat; omega), hlim_val]
    rw [hsub_bv]
    have hv_rem64 : (Scalar.Value.int false 64 ↑(16777215 - size.toNat)).valid = true := Scalar.unsigned_nat_valid (16777215 - size.toNat) 64 (by omega)
    have hv_rem256 : (Scalar.Value.int false 256 ↑(16777215 - size.toNat)).valid = true := Scalar.unsigned_nat_valid (16777215 - size.toNat) 256 (by omega)
    have hi_rem64 : Scalar.integer false 64 (Scalar.Arithmetic.sub.eval 16777215 size.toNat) .unchecked =
        .ok (.int false 64 ↑(16777215 - size.toNat)) := by
      change Scalar.integer false 64 (16777215 - (size.toNat : Int)) .unchecked = _
      rw [show (16777215 : Int) - size.toNat = ↑(16777215 - size.toNat) by omega]
      exact integer_unchecked_of_valid hv_rem64
    have hb4 : Control.Code.eval MemoryAir.semantics
        (.bind 5 (.scalar .bool) (.scalar (.comparison .gt (.local 1) (.constant (.int false 64 16777215))))
        (.branch (.local 5) (.jump 3 (.constant (.scalar (.bool false)))) (.jump 4 (.constant (.scalar .unit)))))
        args env0 state = .jumped 4 (.scalar .unit) (Control.Env.set env0 5 (.scalar (.bool false))) state := by
      rw [eval_bind_ok (prim_scalar_eval (scalar_cmp_eval
        (scalar_ref_local_eval (scalarEnv_of_env he0_1) hv_sz_s)
        (scalar_ref_const_eval hv_lim_s)
        (show Scalar.Comparison.gt.eval size.toNat 16777215 = false by simp [Scalar.Comparison.eval]; omega))) (bool_val_hasType false)]
      rw [eval_branch_false (ref_local_eval (env_set_self ..) (bool_val_valid false))]
      exact eval_jump_ok (ref_const_eval unit_val_valid)
    let b := decide (offset.toNat ≤ 16777215 - size.toNat)
    have hb_eq : decide (size.toNat ≤ 16777215 ∧ offset.toNat ≤ 16777215 - size.toNat) = b := by
      simp [b, hle]
    rw [hb_eq]
    rw [eval_block_jump_hit (by
      rw [eval_block_jump_hit hb4 unit_val_hasType]
      rw [eval_bind_ok (prim_scalar_eval (scalar_arith_eval
        (scalar_ref_const_eval hv_lim_s)
        (scalar_ref_local_eval (scalarEnv_of_env (by rw [env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), he0_1])) hv_sz_s)
        hi_rem64)) (mem_scalar_hasType (scalar_hasType_of_valid hv_rem64))]
      rw [eval_bind_ok (prim_scalar_eval (scalar_cast_unchecked_eval
        (scalar_ref_local_eval (scalarEnv_of_env (env_set_self ..)) hv_rem64)
        (integer_unchecked_of_valid hv_rem256))) (mem_scalar_hasType (scalar_hasType_of_valid hv_rem256))]
      rw [eval_bind_ok (prim_scalar_eval (scalar_cmp_eval
        (scalar_ref_local_eval (scalarEnv_of_env (by rw [env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), he0_2])) (u256_scalar_valid offset))
        (scalar_ref_local_eval (scalarEnv_of_env (env_set_self ..)) hv_rem256)
        (show Scalar.Comparison.le.eval offset.toNat ↑(16777215 - size.toNat) = b by
          simp [Scalar.Comparison.eval, b]))) (bool_val_hasType b)]
      exact eval_jump_ok (ref_local_eval (env_set_self ..) (bool_val_valid b))) (bool_val_hasType b)]
    exact eval_ret_ok (ref_local_eval (env_set_self ..) (bool_val_valid b))

/-- Direct Zig AIR proof: `verified_ops.checkMemoryBoundsWord32Fast` matches
    `GuillotineVerify.Memory.checkMemoryBoundsRef offset 32 0xFFFFFF` for ALL `u256` offsets. -/
theorem check_memory_bounds_word32_fast_correct (state : State) (offPtr : Value)
    (offset : BitVec 256)
    (hvalid : state.valid = true)
    (ht_off : offPtr.hasType (.pointer false false u256Ty) = true)
    (hload : Memory.load state offPtr = .ok (u256Val offset)) :
    Generated.fn_check_memory_bounds_word32_fast.run [offPtr] state =
      (.ok (.scalar (.bool (GuillotineVerify.Memory.checkMemoryBoundsRef offset 32 memLimit))), state) := by
  rw [← GuillotineVerify.Memory.checkMemoryBoundsFast_eq_ref_32]
  have hv_offp : offPtr.valid = true := ptr_valid_of_hasType ht_off
  have hv_c : (Scalar.Value.int false 256 16777183).valid = true := Scalar.unsigned_nat_valid 16777183 256 (by omega)
  have hacc : Generated.fn_check_memory_bounds_word32_fast.accepts [offPtr] state = true := by
    simp [Program.accepts, Generated.fn_check_memory_bounds_word32_fast, hvalid, ht_off]
  suffices hrun : Generated.fn_check_memory_bounds_word32_fast.run [offPtr] state =
      (.ok (.scalar (.bool (GuillotineVerify.Memory.checkMemoryBoundsFast offset 32 memLimit))), Memory.cleanup state.nextId state) by
    rwa [cleanup_same_nextId state hvalid] at hrun
  refine program_run_ok hacc ?_ (bool_val_hasType _)
  unfold Generated.fn_check_memory_bounds_word32_fast GuillotineVerify.Memory.checkMemoryBoundsFast
  dsimp only
  have hsub : (memLimit - 32).toNat = 16777183 := rfl
  have h32 : (32 : BitVec 64).toNat = 32 := rfl
  have hlim : memLimit.toNat = 16777215 := rfl
  rw [hsub, h32, hlim]
  let b := decide (32 ≤ 16777215 ∧ offset.toNat ≤ 16777183)
  rw [eval_bind_ok (prim_arg_eval rfl) ht_off]
  rw [eval_bind_ok (prim_load_eval (ref_local_eval (env_set_self ..) hv_offp) hload) (u256_val_hasType offset)]
  rw [eval_bind_ok (prim_scalar_eval (scalar_cmp_eval
    (scalar_ref_local_eval (scalarEnv_of_env (env_set_self ..)) (u256_scalar_valid offset))
    (scalar_ref_const_eval hv_c)
    (show Scalar.Comparison.le.eval offset.toNat 16777183 = b by
      simp only [Scalar.Comparison.eval, b]; congr 1; apply propext; omega))) (bool_val_hasType b)]
  exact eval_ret_ok (ref_local_eval (env_set_self ..) (bool_val_valid b))

/-- Direct Zig AIR proof: `verified_ops.checkMemoryBoundsByte1Fast` matches
    `GuillotineVerify.Memory.checkMemoryBoundsRef offset 1 0xFFFFFF` for ALL `u256` offsets. -/
theorem check_memory_bounds_byte1_fast_correct (state : State) (offPtr : Value)
    (offset : BitVec 256)
    (hvalid : state.valid = true)
    (ht_off : offPtr.hasType (.pointer false false u256Ty) = true)
    (hload : Memory.load state offPtr = .ok (u256Val offset)) :
    Generated.fn_check_memory_bounds_byte1_fast.run [offPtr] state =
      (.ok (.scalar (.bool (GuillotineVerify.Memory.checkMemoryBoundsRef offset 1 memLimit))), state) := by
  rw [← GuillotineVerify.Memory.checkMemoryBoundsFast_eq_ref_1]
  have hv_offp : offPtr.valid = true := ptr_valid_of_hasType ht_off
  have hv_c : (Scalar.Value.int false 256 16777214).valid = true := Scalar.unsigned_nat_valid 16777214 256 (by omega)
  have hacc : Generated.fn_check_memory_bounds_byte1_fast.accepts [offPtr] state = true := by
    simp [Program.accepts, Generated.fn_check_memory_bounds_byte1_fast, hvalid, ht_off]
  suffices hrun : Generated.fn_check_memory_bounds_byte1_fast.run [offPtr] state =
      (.ok (.scalar (.bool (GuillotineVerify.Memory.checkMemoryBoundsFast offset 1 memLimit))), Memory.cleanup state.nextId state) by
    rwa [cleanup_same_nextId state hvalid] at hrun
  refine program_run_ok hacc ?_ (bool_val_hasType _)
  unfold Generated.fn_check_memory_bounds_byte1_fast GuillotineVerify.Memory.checkMemoryBoundsFast
  dsimp only
  have hsub : (memLimit - 1).toNat = 16777214 := rfl
  have h1 : (1 : BitVec 64).toNat = 1 := rfl
  have hlim : memLimit.toNat = 16777215 := rfl
  rw [hsub, h1, hlim]
  let b := decide (1 ≤ 16777215 ∧ offset.toNat ≤ 16777214)
  rw [eval_bind_ok (prim_arg_eval rfl) ht_off]
  rw [eval_bind_ok (prim_load_eval (ref_local_eval (env_set_self ..) hv_offp) hload) (u256_val_hasType offset)]
  rw [eval_bind_ok (prim_scalar_eval (scalar_cmp_eval
    (scalar_ref_local_eval (scalarEnv_of_env (env_set_self ..)) (u256_scalar_valid offset))
    (scalar_ref_const_eval hv_c)
    (show Scalar.Comparison.le.eval offset.toNat 16777214 = b by
      simp only [Scalar.Comparison.eval, b]; congr 1; apply propext; omega))) (bool_val_hasType b)]
  exact eval_ret_ok (ref_local_eval (env_set_self ..) (bool_val_valid b))

/-- Direct Zig AIR proof: `verified_ops.denseJumpBoundsFast` matches
    `GuillotineVerify.JumpTable.denseJumpInBoundsFast` for ALL `u256` dests and `u32` lengths. -/
theorem dense_jump_bounds_fast_correct (state : State) (destPtr : Value)
    (dest : BitVec 256) (tableLen : BitVec 32)
    (hvalid : state.valid = true)
    (ht_dest : destPtr.hasType (.pointer false false u256Ty) = true)
    (hload : Memory.load state destPtr = .ok (u256Val dest)) :
    Generated.fn_dense_jump_bounds_fast.run [destPtr, .scalar (.int false 32 tableLen.toNat)] state =
      (.ok (.scalar (.bool (GuillotineVerify.JumpTable.denseJumpInBoundsFast dest tableLen))), state) := by
  have hv_dp : destPtr.valid = true := ptr_valid_of_hasType ht_dest
  have hv_len32 : (Scalar.Value.int false 32 tableLen.toNat).valid = true := scalar_valid_of_nat tableLen.isLt
  have ht_len32 : (Memory.Value.scalar (.int false 32 tableLen.toNat)).hasType (.scalar (.int false 32)) = true :=
    mem_scalar_hasType (scalar_hasType_of_valid hv_len32)
  have hv_len256 : (Scalar.Value.int false 256 tableLen.toNat).valid = true := Scalar.unsigned_nat_valid tableLen.toNat 256 (by have := tableLen.isLt; omega)
  have hacc : Generated.fn_dense_jump_bounds_fast.accepts [destPtr, .scalar (.int false 32 tableLen.toNat)] state = true := by
    simp [Program.accepts, Generated.fn_dense_jump_bounds_fast, hvalid, ht_dest, ht_len32]
  suffices hrun : Generated.fn_dense_jump_bounds_fast.run [destPtr, .scalar (.int false 32 tableLen.toNat)] state =
      (.ok (.scalar (.bool (GuillotineVerify.JumpTable.denseJumpInBoundsFast dest tableLen))), Memory.cleanup state.nextId state) by
    rwa [cleanup_same_nextId state hvalid] at hrun
  refine program_run_ok hacc ?_ (bool_val_hasType _)
  unfold Generated.fn_dense_jump_bounds_fast GuillotineVerify.JumpTable.denseJumpInBoundsFast
  dsimp only
  let b := decide (dest.toNat < tableLen.toNat)
  rw [eval_bind_ok (prim_arg_eval rfl) ht_dest]
  rw [eval_bind_ok (prim_arg_eval rfl) ht_len32]
  rw [eval_bind_ok (prim_load_eval (ref_local_eval (by rw [env_set_ne _ _ _ _ (by decide), env_set_self]) hv_dp) hload) (u256_val_hasType dest)]
  rw [eval_bind_ok (prim_scalar_eval (scalar_cast_unchecked_eval
    (scalar_ref_local_eval (scalarEnv_of_env (by rw [env_set_ne _ _ _ _ (by decide), env_set_self])) hv_len32)
    (integer_unchecked_of_valid hv_len256))) (mem_scalar_hasType (scalar_hasType_of_valid hv_len256))]
  rw [eval_bind_ok (prim_scalar_eval (scalar_cmp_eval
    (scalar_ref_local_eval (scalarEnv_of_env (by rw [env_set_ne _ _ _ _ (by decide), env_set_self])) (u256_scalar_valid dest))
    (scalar_ref_local_eval (scalarEnv_of_env (env_set_self ..)) hv_len256)
    (show Scalar.Comparison.lt.eval dest.toNat tableLen.toNat = b by simp [Scalar.Comparison.eval, b]))) (bool_val_hasType b)]
  exact eval_ret_ok (ref_local_eval (env_set_self ..) (bool_val_valid b))

/-- Direct Zig AIR proof: `verified_ops.denseJumpBoundsU16Ref` matches
    `GuillotineVerify.JumpTable.denseJumpInBoundsRef dest tableLen 16` for all `tableLen ≤ 65536`. -/
theorem dense_jump_bounds_u16_ref_correct (state : State) (destPtr : Value)
    (dest : BitVec 256) (tableLen : BitVec 32) (hlen : tableLen.toNat ≤ 65536)
    (hvalid : state.valid = true)
    (ht_dest : destPtr.hasType (.pointer false false u256Ty) = true)
    (hload : Memory.load state destPtr = .ok (u256Val dest)) :
    Generated.fn_dense_jump_bounds_u16_ref.run [destPtr, .scalar (.int false 32 tableLen.toNat)] state =
      (.ok (.scalar (.bool (GuillotineVerify.JumpTable.denseJumpInBoundsRef dest tableLen 16))), state) := by
  have hv_dp : destPtr.valid = true := ptr_valid_of_hasType ht_dest
  have hv_len32 : (Scalar.Value.int false 32 tableLen.toNat).valid = true := scalar_valid_of_nat tableLen.isLt
  have ht_len32 : (Memory.Value.scalar (.int false 32 tableLen.toNat)).hasType (.scalar (.int false 32)) = true :=
    mem_scalar_hasType (scalar_hasType_of_valid hv_len32)
  have hv_65536 : (Scalar.Value.int false 32 65536).valid = true := Scalar.unsigned_nat_valid 65536 32 (by omega)
  have hv_len17 : (Scalar.Value.int false 17 tableLen.toNat).valid = true := Scalar.unsigned_nat_valid tableLen.toNat 17 (by omega)
  have hv_65535 : (Scalar.Value.int false 256 65535).valid = true := Scalar.unsigned_nat_valid 65535 256 (by omega)
  have hmin : min (65536 : Int) (tableLen.toNat : Int) = tableLen.toNat := by omega
  have hacc : Generated.fn_dense_jump_bounds_u16_ref.accepts [destPtr, .scalar (.int false 32 tableLen.toNat)] state = true := by
    simp [Program.accepts, Generated.fn_dense_jump_bounds_u16_ref, hvalid, ht_dest, ht_len32]
  suffices hrun : Generated.fn_dense_jump_bounds_u16_ref.run [destPtr, .scalar (.int false 32 tableLen.toNat)] state =
      (.ok (.scalar (.bool (GuillotineVerify.JumpTable.denseJumpInBoundsRef dest tableLen 16))), Memory.cleanup state.nextId state) by
    rwa [cleanup_same_nextId state hvalid] at hrun
  refine program_run_ok hacc ?_ (bool_val_hasType _)
  unfold Generated.fn_dense_jump_bounds_u16_ref GuillotineVerify.JumpTable.denseJumpInBoundsRef
  dsimp only
  rw [eval_bind_ok (prim_arg_eval rfl) ht_dest]
  rw [eval_bind_ok (prim_arg_eval rfl) ht_len32]
  have hext := scalar_extremum_eval (maximum := false) (left := .constant (.int false 32 65536)) (right := .local 1)
    (args := []) (env := scalarEnv (Control.Env.set (Control.Env.set (fun _ => none) 0 destPtr) 1 (.scalar (.int false 32 tableLen.toNat))))
    (scalar_ref_const_eval hv_65536)
    (scalar_ref_local_eval (scalarEnv_of_env (env_set_self ..)) hv_len32)
  simp only [Bool.false_eq_true, ↓reduceIte, hmin] at hext
  rw [eval_bind_ok (prim_scalar_eval hext) ht_len32]
  rw [eval_bind_ok (prim_scalar_eval (scalar_cast_unchecked_eval
    (scalar_ref_local_eval (scalarEnv_of_env (env_set_self ..)) hv_len32)
    (integer_unchecked_of_valid hv_len17))) (mem_scalar_hasType (scalar_hasType_of_valid hv_len17))]
  rw [eval_bind_ok (prim_scalar_eval (scalar_cast_unchecked_eval
    (scalar_ref_local_eval (scalarEnv_of_env (env_set_self ..)) hv_len17)
    (integer_unchecked_of_valid hv_len32))) ht_len32]
  rw [eval_bind_ok (prim_load_eval (ref_local_eval
    (by rw [env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_self]) hv_dp) hload) (u256_val_hasType dest)]
  let args := [destPtr, Memory.Value.scalar (.int false 32 tableLen.toNat)]
  let env0 : Env := Control.Env.set (Control.Env.set (Control.Env.set (Control.Env.set (Control.Env.set (Control.Env.set (fun _ => none) 0 destPtr) 1 (.scalar (.int false 32 tableLen.toNat))) 2 (.scalar (.int false 32 tableLen.toNat))) 3 (.scalar (.int false 17 tableLen.toNat))) 4 (.scalar (.int false 32 tableLen.toNat))) 5 (u256Val dest)
  change Control.Code.eval MemoryAir.semantics _ args env0 state = _
  have he0_4 : env0 4 = some (.scalar (.int false 32 tableLen.toNat)) := by
    simp only [env0]; rw [env_set_ne _ _ _ _ (by decide), env_set_self]
  have he0_5 : env0 5 = some (u256Val dest) := by
    simp only [env0]; rw [env_set_self]
  by_cases hgt : dest.toNat > 65535
  · have hnotle : ¬ (dest.toNat ≤ 2 ^ 16 - 1) := by omega
    simp only [hnotle, ↓reduceIte]
    have hb7 : Control.Code.eval MemoryAir.semantics
        (.bind 9 (.scalar .bool) (.scalar (.comparison .gt (.local 5) (.constant (.int false 256 65535))))
        (.branch (.local 9) (.jump 6 (.constant (.scalar (.bool false)))) (.jump 7 (.constant (.scalar .unit)))))
        args env0 state = .jumped 6 (.scalar (.bool false)) (Control.Env.set env0 9 (.scalar (.bool true))) state := by
      rw [eval_bind_ok (prim_scalar_eval (scalar_cmp_eval
        (scalar_ref_local_eval (scalarEnv_of_env he0_5) (u256_scalar_valid dest))
        (scalar_ref_const_eval hv_65535)
        (show Scalar.Comparison.gt.eval dest.toNat 65535 = true by simp [Scalar.Comparison.eval]; omega))) (bool_val_hasType true)]
      rw [eval_branch_true (ref_local_eval (env_set_self ..) (bool_val_valid true))]
      exact eval_jump_ok (ref_const_eval (bool_val_valid false))
    rw [eval_block_jump_hit (eval_block_jump_miss hb7 (by decide)) (bool_val_hasType false)]
    exact eval_ret_ok (ref_local_eval (env_set_self ..) (bool_val_valid false))
  · have hle : dest.toNat ≤ 2 ^ 16 - 1 := by omega
    simp only [hle, ↓reduceIte]
    have hsw : (dest.setWidth 32).toNat = dest.toNat := by
      rw [BitVec.toNat_setWidth, Nat.mod_eq_of_lt (by omega)]
    rw [hsw]
    have hv_d32 : (Scalar.Value.int false 32 dest.toNat).valid = true := Scalar.unsigned_nat_valid dest.toNat 32 (by omega)
    have hb7 : Control.Code.eval MemoryAir.semantics
        (.bind 9 (.scalar .bool) (.scalar (.comparison .gt (.local 5) (.constant (.int false 256 65535))))
        (.branch (.local 9) (.jump 6 (.constant (.scalar (.bool false)))) (.jump 7 (.constant (.scalar .unit)))))
        args env0 state = .jumped 7 (.scalar .unit) (Control.Env.set env0 9 (.scalar (.bool false))) state := by
      rw [eval_bind_ok (prim_scalar_eval (scalar_cmp_eval
        (scalar_ref_local_eval (scalarEnv_of_env he0_5) (u256_scalar_valid dest))
        (scalar_ref_const_eval hv_65535)
        (show Scalar.Comparison.gt.eval dest.toNat 65535 = false by simp [Scalar.Comparison.eval]; omega))) (bool_val_hasType false)]
      rw [eval_branch_false (ref_local_eval (env_set_self ..) (bool_val_valid false))]
      exact eval_jump_ok (ref_const_eval unit_val_valid)
    let b := decide (dest.toNat < tableLen.toNat)
    rw [eval_block_jump_hit (by
      rw [eval_block_jump_hit hb7 unit_val_hasType]
      rw [eval_bind_ok (prim_scalar_eval (scalar_cast_unchecked_eval
        (scalar_ref_local_eval (scalarEnv_of_env (by rw [env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), he0_5])) (u256_scalar_valid dest))
        (integer_unchecked_of_valid hv_d32))) (mem_scalar_hasType (scalar_hasType_of_valid hv_d32))]
      rw [eval_bind_ok (prim_scalar_eval (scalar_cmp_eval
        (scalar_ref_local_eval (scalarEnv_of_env (env_set_self ..)) hv_d32)
        (scalar_ref_local_eval (scalarEnv_of_env (by rw [env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), he0_4])) hv_len32)
        (show Scalar.Comparison.lt.eval dest.toNat tableLen.toNat = b by simp [Scalar.Comparison.eval, b]))) (bool_val_hasType b)]
      exact eval_jump_ok (ref_local_eval (env_set_self ..) (bool_val_valid b))) (bool_val_hasType b)]
    exact eval_ret_ok (ref_local_eval (env_set_self ..) (bool_val_valid b))

/-- Direct Zig AIR equivalence: for `tableLen ≤ 65536`, the captured Zig AIR of
    `denseJumpBoundsFast` agrees identically with `denseJumpBoundsU16Ref`! -/
theorem dense_jump_bounds_fast_eq_u16_ref (state : State) (destPtr : Value)
    (dest : BitVec 256) (tableLen : BitVec 32) (hlen : tableLen.toNat ≤ 65536)
    (hvalid : state.valid = true)
    (ht_dest : destPtr.hasType (.pointer false false u256Ty) = true)
    (hload : Memory.load state destPtr = .ok (u256Val dest)) :
    Generated.fn_dense_jump_bounds_fast.run [destPtr, .scalar (.int false 32 tableLen.toNat)] state =
      Generated.fn_dense_jump_bounds_u16_ref.run [destPtr, .scalar (.int false 32 tableLen.toNat)] state := by
  rw [dense_jump_bounds_fast_correct state destPtr dest tableLen hvalid ht_dest hload,
      dense_jump_bounds_u16_ref_correct state destPtr dest tableLen hlen hvalid ht_dest hload,
      GuillotineVerify.JumpTable.denseJumpInBoundsFast_eq_ref dest tableLen 16 (by omega) hlen]

/-- Direct Zig AIR proof: `verified_ops.denseJumpBoundsU32Ref` matches
    `GuillotineVerify.JumpTable.denseJumpInBoundsRef dest tableLen 32` for ALL inputs. -/
theorem dense_jump_bounds_u32_ref_correct (state : State) (destPtr : Value)
    (dest : BitVec 256) (tableLen : BitVec 32)
    (hvalid : state.valid = true)
    (ht_dest : destPtr.hasType (.pointer false false u256Ty) = true)
    (hload : Memory.load state destPtr = .ok (u256Val dest)) :
    Generated.fn_dense_jump_bounds_u32_ref.run [destPtr, .scalar (.int false 32 tableLen.toNat)] state =
      (.ok (.scalar (.bool (GuillotineVerify.JumpTable.denseJumpInBoundsRef dest tableLen 32))), state) := by
  have hv_dp : destPtr.valid = true := ptr_valid_of_hasType ht_dest
  have hv_len32 : (Scalar.Value.int false 32 tableLen.toNat).valid = true := scalar_valid_of_nat tableLen.isLt
  have ht_len32 : (Memory.Value.scalar (.int false 32 tableLen.toNat)).hasType (.scalar (.int false 32)) = true :=
    mem_scalar_hasType (scalar_hasType_of_valid hv_len32)
  have hv_max32 : (Scalar.Value.int false 256 4294967295).valid = true := Scalar.unsigned_nat_valid 4294967295 256 (by omega)
  have hacc : Generated.fn_dense_jump_bounds_u32_ref.accepts [destPtr, .scalar (.int false 32 tableLen.toNat)] state = true := by
    simp [Program.accepts, Generated.fn_dense_jump_bounds_u32_ref, hvalid, ht_dest, ht_len32]
  suffices hrun : Generated.fn_dense_jump_bounds_u32_ref.run [destPtr, .scalar (.int false 32 tableLen.toNat)] state =
      (.ok (.scalar (.bool (GuillotineVerify.JumpTable.denseJumpInBoundsRef dest tableLen 32))), Memory.cleanup state.nextId state) by
    rwa [cleanup_same_nextId state hvalid] at hrun
  refine program_run_ok hacc ?_ (bool_val_hasType _)
  unfold Generated.fn_dense_jump_bounds_u32_ref GuillotineVerify.JumpTable.denseJumpInBoundsRef
  dsimp only
  rw [eval_bind_ok (prim_arg_eval rfl) ht_dest]
  rw [eval_bind_ok (prim_arg_eval rfl) ht_len32]
  rw [eval_bind_ok (prim_load_eval (ref_local_eval (by rw [env_set_ne _ _ _ _ (by decide), env_set_self]) hv_dp) hload) (u256_val_hasType dest)]
  let args := [destPtr, Memory.Value.scalar (.int false 32 tableLen.toNat)]
  let env0 : Env := Control.Env.set (Control.Env.set (Control.Env.set (fun _ => none) 0 destPtr) 1 (.scalar (.int false 32 tableLen.toNat))) 2 (u256Val dest)
  change Control.Code.eval MemoryAir.semantics _ args env0 state = _
  have he0_1 : env0 1 = some (.scalar (.int false 32 tableLen.toNat)) := by
    simp only [env0]; rw [env_set_ne _ _ _ _ (by decide), env_set_self]
  have he0_2 : env0 2 = some (u256Val dest) := by
    simp only [env0]; rw [env_set_self]
  by_cases hgt : dest.toNat > 4294967295
  · have hnotle : ¬ (dest.toNat ≤ 2 ^ 32 - 1) := by omega
    simp only [hnotle, ↓reduceIte]
    have hb4 : Control.Code.eval MemoryAir.semantics
        (.bind 6 (.scalar .bool) (.scalar (.comparison .gt (.local 2) (.constant (.int false 256 4294967295))))
        (.branch (.local 6) (.jump 3 (.constant (.scalar (.bool false)))) (.jump 4 (.constant (.scalar .unit)))))
        args env0 state = .jumped 3 (.scalar (.bool false)) (Control.Env.set env0 6 (.scalar (.bool true))) state := by
      rw [eval_bind_ok (prim_scalar_eval (scalar_cmp_eval
        (scalar_ref_local_eval (scalarEnv_of_env he0_2) (u256_scalar_valid dest))
        (scalar_ref_const_eval hv_max32)
        (show Scalar.Comparison.gt.eval dest.toNat 4294967295 = true by simp [Scalar.Comparison.eval]; omega))) (bool_val_hasType true)]
      rw [eval_branch_true (ref_local_eval (env_set_self ..) (bool_val_valid true))]
      exact eval_jump_ok (ref_const_eval (bool_val_valid false))
    rw [eval_block_jump_hit (eval_block_jump_miss hb4 (by decide)) (bool_val_hasType false)]
    exact eval_ret_ok (ref_local_eval (env_set_self ..) (bool_val_valid false))
  · have hle : dest.toNat ≤ 2 ^ 32 - 1 := by omega
    simp only [hle, ↓reduceIte]
    have hsw : (dest.setWidth 32).toNat = dest.toNat := by
      rw [BitVec.toNat_setWidth, Nat.mod_eq_of_lt (by omega)]
    rw [hsw]
    have hv_d32 : (Scalar.Value.int false 32 dest.toNat).valid = true := Scalar.unsigned_nat_valid dest.toNat 32 (by omega)
    have hb4 : Control.Code.eval MemoryAir.semantics
        (.bind 6 (.scalar .bool) (.scalar (.comparison .gt (.local 2) (.constant (.int false 256 4294967295))))
        (.branch (.local 6) (.jump 3 (.constant (.scalar (.bool false)))) (.jump 4 (.constant (.scalar .unit)))))
        args env0 state = .jumped 4 (.scalar .unit) (Control.Env.set env0 6 (.scalar (.bool false))) state := by
      rw [eval_bind_ok (prim_scalar_eval (scalar_cmp_eval
        (scalar_ref_local_eval (scalarEnv_of_env he0_2) (u256_scalar_valid dest))
        (scalar_ref_const_eval hv_max32)
        (show Scalar.Comparison.gt.eval dest.toNat 4294967295 = false by simp [Scalar.Comparison.eval]; omega))) (bool_val_hasType false)]
      rw [eval_branch_false (ref_local_eval (env_set_self ..) (bool_val_valid false))]
      exact eval_jump_ok (ref_const_eval unit_val_valid)
    let b := decide (dest.toNat < tableLen.toNat)
    rw [eval_block_jump_hit (by
      rw [eval_block_jump_hit hb4 unit_val_hasType]
      rw [eval_bind_ok (prim_scalar_eval (scalar_cast_unchecked_eval
        (scalar_ref_local_eval (scalarEnv_of_env (by rw [env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), he0_2])) (u256_scalar_valid dest))
        (integer_unchecked_of_valid hv_d32))) (mem_scalar_hasType (scalar_hasType_of_valid hv_d32))]
      rw [eval_bind_ok (prim_scalar_eval (scalar_cmp_eval
        (scalar_ref_local_eval (scalarEnv_of_env (env_set_self ..)) hv_d32)
        (scalar_ref_local_eval (scalarEnv_of_env (by rw [env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), he0_1])) hv_len32)
        (show Scalar.Comparison.lt.eval dest.toNat tableLen.toNat = b by simp [Scalar.Comparison.eval, b]))) (bool_val_hasType b)]
      exact eval_jump_ok (ref_local_eval (env_set_self ..) (bool_val_valid b))) (bool_val_hasType b)]
    exact eval_ret_ok (ref_local_eval (env_set_self ..) (bool_val_valid b))

/-- Direct Zig AIR equivalence: for ALL `u256` dests and `u32` lengths, the captured Zig AIR
    of `denseJumpBoundsFast` agrees identically with `denseJumpBoundsU32Ref`! -/
theorem dense_jump_bounds_fast_eq_u32_ref (state : State) (destPtr : Value)
    (dest : BitVec 256) (tableLen : BitVec 32)
    (hvalid : state.valid = true)
    (ht_dest : destPtr.hasType (.pointer false false u256Ty) = true)
    (hload : Memory.load state destPtr = .ok (u256Val dest)) :
    Generated.fn_dense_jump_bounds_fast.run [destPtr, .scalar (.int false 32 tableLen.toNat)] state =
      Generated.fn_dense_jump_bounds_u32_ref.run [destPtr, .scalar (.int false 32 tableLen.toNat)] state := by
  rw [dense_jump_bounds_fast_correct state destPtr dest tableLen hvalid ht_dest hload,
      dense_jump_bounds_u32_ref_correct state destPtr dest tableLen hvalid ht_dest hload,
      GuillotineVerify.JumpTable.denseJumpInBoundsFast_eq_ref dest tableLen 32 (by omega) (Nat.le_of_lt tableLen.isLt)]

/-- Direct Zig AIR proof: `verified_ops.absTwoComp` computes exact 256-bit signed
    absolute value (`GuillotineVerify.Arithmetic.signedAbs x`) for ALL `2^256` inputs! -/
theorem abs_two_comp_correct (state after : State) (xPtr outPtr : Value) (x : BitVec 256)
    (hvalid : state.valid = true)
    (ht_x : xPtr.hasType (.pointer false false u256Ty) = true)
    (ht_out : outPtr.hasType (.pointer true false u256Ty) = true)
    (hload : Memory.load state xPtr = .ok (u256Val x))
    (hstore : Memory.store state outPtr (u256Val (GuillotineVerify.Arithmetic.signedAbs x)) = .ok after) :
    Generated.fn_abs_two_comp.run [xPtr, outPtr] state = (.ok (.scalar .unit), after) ∧
    after.valid = true ∧
    Memory.load after outPtr = .ok (u256Val (GuillotineVerify.Arithmetic.signedAbs x)) := by
  rw [← GuillotineVerify.Arithmetic.absTwoComp_eq_abs] at hstore ⊢
  have hv_xp : xPtr.valid = true := ptr_valid_of_hasType ht_x
  have hv_op : outPtr.valid = true := ptr_valid_of_hasType ht_out
  have hv_255 : (Scalar.Value.int false 8 255).valid = true := Scalar.unsigned_nat_valid 255 8 (by omega)
  have hv_0 : (Scalar.Value.int false 256 0).valid = true := Scalar.unsigned_nat_valid 0 256 (by omega)
  let s : BitVec 256 := x >>> 255
  let mask : BitVec 256 := 0 - s
  let xr : BitVec 256 := x ^^^ mask
  let res : BitVec 256 := xr - mask
  have hres_eq : GuillotineVerify.Arithmetic.absTwoComp x = res := rfl
  rw [hres_eq] at hstore ⊢
  have hacc : Generated.fn_abs_two_comp.accepts [xPtr, outPtr] state = true := by
    simp [Program.accepts, Generated.fn_abs_two_comp, hvalid, ht_x, ht_out]
  have hrun : Generated.fn_abs_two_comp.run [xPtr, outPtr] state =
      (.ok (.scalar .unit), Memory.cleanup state.nextId after) := by
    refine program_run_ok hacc ?_ unit_val_hasType
    unfold Generated.fn_abs_two_comp; dsimp only
    rw [eval_bind_ok (prim_arg_eval rfl) ht_x]
    rw [eval_bind_ok (prim_arg_eval rfl) ht_out]
    rw [eval_bind_ok (prim_load_eval (ref_local_eval (by rw [env_set_ne _ _ _ _ (by decide), env_set_self]) hv_xp) hload) (u256_val_hasType x)]
    rw [eval_bind_ok (prim_scalar_eval (scalar_shiftRight256_255_eval
      (scalar_ref_local_eval (scalarEnv_of_env (env_set_self ..)) (u256_scalar_valid x)))) (u256_val_hasType s)]
    rw [eval_bind_ok (prim_scalar_eval (scalar_arith_eval
      (scalar_ref_const_eval hv_0)
      (scalar_ref_local_eval (scalarEnv_of_env (env_set_self ..)) (u256_scalar_valid s))
      (by change Scalar.integer false 256 ((0 : BitVec 256).toNat - (s.toNat : Int)) .wrapping = _; rw [integer_wrapping_uint, bv256_sub_int_mod]))) (u256_val_hasType mask)]
    rw [eval_bind_ok (prim_scalar_eval (scalar_bitXor256_eval
      (scalar_ref_local_eval (scalarEnv_of_env (by rw [env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_self])) (u256_scalar_valid x))
      (scalar_ref_local_eval (scalarEnv_of_env (env_set_self ..)) (u256_scalar_valid mask)))) (u256_val_hasType xr)]
    rw [eval_bind_ok (prim_scalar_eval (scalar_arith_eval
      (scalar_ref_local_eval (scalarEnv_of_env (env_set_self ..)) (u256_scalar_valid xr))
      (scalar_ref_local_eval (scalarEnv_of_env (by rw [env_set_ne _ _ _ _ (by decide), env_set_self])) (u256_scalar_valid mask))
      (by change Scalar.integer false 256 ((xr.toNat : Int) - mask.toNat) .wrapping = _; rw [integer_wrapping_uint, bv256_sub_int_mod]))) (u256_val_hasType res)]
    rw [eval_bind_ok (prim_store_eval
      (ref_local_eval (by rw [env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_self]) hv_op)
      (ref_local_eval (env_set_self ..) (u256_val_valid res))
      hstore) unit_val_hasType]
    exact eval_ret_ok (ref_const_eval unit_val_valid)
  rw [cleanup_after_store state after outPtr (u256Val res) hvalid hstore] at hrun
  exact ⟨hrun, Memory.store_preserves_valid state outPtr (u256Val res) after hvalid hstore,
    Memory.load_after_store state outPtr (u256Val res) after hstore⟩

/-- Direct Zig AIR proof: `verified_ops.sdivSignApply` computes exact
    `GuillotineVerify.Arithmetic.sdivFromUnsignedQuotient a b q` for ALL `2^256` inputs! -/
theorem sdiv_sign_apply_correct (state after : State) (aPtr bPtr qPtr outPtr : Value)
    (a b q : BitVec 256)
    (hvalid : state.valid = true)
    (ht_a : aPtr.hasType (.pointer false false u256Ty) = true)
    (ht_b : bPtr.hasType (.pointer false false u256Ty) = true)
    (ht_q : qPtr.hasType (.pointer false false u256Ty) = true)
    (ht_out : outPtr.hasType (.pointer true false u256Ty) = true)
    (hload_a : Memory.load state aPtr = .ok (u256Val a))
    (hload_b : Memory.load state bPtr = .ok (u256Val b))
    (hload_q : Memory.load state qPtr = .ok (u256Val q))
    (hstore : Memory.store state outPtr (u256Val (GuillotineVerify.Arithmetic.sdivFromUnsignedQuotient a b q)) = .ok after) :
    Generated.fn_sdiv_sign_apply.run [aPtr, bPtr, qPtr, outPtr] state = (.ok (.scalar .unit), after) ∧
    after.valid = true ∧
    Memory.load after outPtr = .ok (u256Val (GuillotineVerify.Arithmetic.sdivFromUnsignedQuotient a b q)) := by
  have hv_ap : aPtr.valid = true := ptr_valid_of_hasType ht_a
  have hv_bp : bPtr.valid = true := ptr_valid_of_hasType ht_b
  have hv_qp : qPtr.valid = true := ptr_valid_of_hasType ht_q
  have hv_op : outPtr.valid = true := ptr_valid_of_hasType ht_out
  have hv_255 : (Scalar.Value.int false 8 255).valid = true := Scalar.unsigned_nat_valid 255 8 (by omega)
  have hv_0 : (Scalar.Value.int false 256 0).valid = true := Scalar.unsigned_nat_valid 0 256 (by omega)
  let sa : BitVec 256 := a >>> 255
  let sb : BitVec 256 := b >>> 255
  let sgn : BitVec 256 := sa ^^^ sb
  let mask : BitVec 256 := 0 - sgn
  let qm : BitVec 256 := q ^^^ mask
  let res : BitVec 256 := qm - mask
  have hres_eq : GuillotineVerify.Arithmetic.sdivFromUnsignedQuotient a b q = res := rfl
  rw [hres_eq] at hstore ⊢
  have hacc : Generated.fn_sdiv_sign_apply.accepts [aPtr, bPtr, qPtr, outPtr] state = true := by
    simp [Program.accepts, Generated.fn_sdiv_sign_apply, hvalid, ht_a, ht_b, ht_q, ht_out]
  have hrun : Generated.fn_sdiv_sign_apply.run [aPtr, bPtr, qPtr, outPtr] state =
      (.ok (.scalar .unit), Memory.cleanup state.nextId after) := by
    refine program_run_ok hacc ?_ unit_val_hasType
    unfold Generated.fn_sdiv_sign_apply; dsimp only
    rw [eval_bind_ok (prim_arg_eval rfl) ht_a]
    rw [eval_bind_ok (prim_arg_eval rfl) ht_b]
    rw [eval_bind_ok (prim_arg_eval rfl) ht_q]
    rw [eval_bind_ok (prim_arg_eval rfl) ht_out]
    rw [eval_bind_ok (prim_load_eval (ref_local_eval
      (by rw [env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_self]) hv_ap) hload_a) (u256_val_hasType a)]
    rw [eval_bind_ok (prim_load_eval (ref_local_eval
      (by rw [env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_self]) hv_bp) hload_b) (u256_val_hasType b)]
    rw [eval_bind_ok (prim_load_eval (ref_local_eval
      (by rw [env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_self]) hv_qp) hload_q) (u256_val_hasType q)]
    rw [eval_bind_ok (prim_scalar_eval (scalar_shiftRight256_255_eval
      (scalar_ref_local_eval (scalarEnv_of_env (by rw [env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_self])) (u256_scalar_valid a)))) (u256_val_hasType sa)]
    rw [eval_bind_ok (prim_scalar_eval (scalar_shiftRight256_255_eval
      (scalar_ref_local_eval (scalarEnv_of_env (by rw [env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_self])) (u256_scalar_valid b)))) (u256_val_hasType sb)]
    rw [eval_bind_ok (prim_scalar_eval (scalar_bitXor256_eval
      (scalar_ref_local_eval (scalarEnv_of_env (by rw [env_set_ne _ _ _ _ (by decide), env_set_self])) (u256_scalar_valid sa))
      (scalar_ref_local_eval (scalarEnv_of_env (env_set_self ..)) (u256_scalar_valid sb)))) (u256_val_hasType sgn)]
    rw [eval_bind_ok (prim_scalar_eval (scalar_arith_eval
      (scalar_ref_const_eval hv_0)
      (scalar_ref_local_eval (scalarEnv_of_env (env_set_self ..)) (u256_scalar_valid sgn))
      (by change Scalar.integer false 256 ((0 : BitVec 256).toNat - (sgn.toNat : Int)) .wrapping = _; rw [integer_wrapping_uint, bv256_sub_int_mod]))) (u256_val_hasType mask)]
    rw [eval_bind_ok (prim_scalar_eval (scalar_bitXor256_eval
      (scalar_ref_local_eval (scalarEnv_of_env (by rw [env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_self])) (u256_scalar_valid q))
      (scalar_ref_local_eval (scalarEnv_of_env (env_set_self ..)) (u256_scalar_valid mask)))) (u256_val_hasType qm)]
    rw [eval_bind_ok (prim_scalar_eval (scalar_arith_eval
      (scalar_ref_local_eval (scalarEnv_of_env (env_set_self ..)) (u256_scalar_valid qm))
      (scalar_ref_local_eval (scalarEnv_of_env (by rw [env_set_ne _ _ _ _ (by decide), env_set_self])) (u256_scalar_valid mask))
      (by change Scalar.integer false 256 ((qm.toNat : Int) - mask.toNat) .wrapping = _; rw [integer_wrapping_uint, bv256_sub_int_mod]))) (u256_val_hasType res)]
    rw [eval_bind_ok (prim_store_eval
      (ref_local_eval (by rw [env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide),
                              env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide),
                              env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_self]) hv_op)
      (ref_local_eval (env_set_self ..) (u256_val_valid res))
      hstore) unit_val_hasType]
    exact eval_ret_ok (ref_const_eval unit_val_valid)
  rw [cleanup_after_store state after outPtr (u256Val res) hvalid hstore] at hrun
  exact ⟨hrun, Memory.store_preserves_valid state outPtr (u256Val res) after hvalid hstore,
    Memory.load_after_store state outPtr (u256Val res) after hstore⟩

/-- Direct Zig AIR proof: `verified_ops.smodSignApply` computes exact
    `GuillotineVerify.Arithmetic.smodFromUnsignedRem a r` for ALL `2^256` inputs! -/
theorem smod_sign_apply_correct (state after : State) (aPtr rPtr outPtr : Value)
    (a r : BitVec 256)
    (hvalid : state.valid = true)
    (ht_a : aPtr.hasType (.pointer false false u256Ty) = true)
    (ht_r : rPtr.hasType (.pointer false false u256Ty) = true)
    (ht_out : outPtr.hasType (.pointer true false u256Ty) = true)
    (hload_a : Memory.load state aPtr = .ok (u256Val a))
    (hload_r : Memory.load state rPtr = .ok (u256Val r))
    (hstore : Memory.store state outPtr (u256Val (GuillotineVerify.Arithmetic.smodFromUnsignedRem a r)) = .ok after) :
    Generated.fn_smod_sign_apply.run [aPtr, rPtr, outPtr] state = (.ok (.scalar .unit), after) ∧
    after.valid = true ∧
    Memory.load after outPtr = .ok (u256Val (GuillotineVerify.Arithmetic.smodFromUnsignedRem a r)) := by
  have hv_ap : aPtr.valid = true := ptr_valid_of_hasType ht_a
  have hv_rp : rPtr.valid = true := ptr_valid_of_hasType ht_r
  have hv_op : outPtr.valid = true := ptr_valid_of_hasType ht_out
  have hv_255 : (Scalar.Value.int false 8 255).valid = true := Scalar.unsigned_nat_valid 255 8 (by omega)
  have hv_0 : (Scalar.Value.int false 256 0).valid = true := Scalar.unsigned_nat_valid 0 256 (by omega)
  let sa : BitVec 256 := a >>> 255
  let mask : BitVec 256 := 0 - sa
  let rm : BitVec 256 := r ^^^ mask
  let res : BitVec 256 := rm - mask
  have hres_eq : GuillotineVerify.Arithmetic.smodFromUnsignedRem a r = res := rfl
  rw [hres_eq] at hstore ⊢
  have hacc : Generated.fn_smod_sign_apply.accepts [aPtr, rPtr, outPtr] state = true := by
    simp [Program.accepts, Generated.fn_smod_sign_apply, hvalid, ht_a, ht_r, ht_out]
  have hrun : Generated.fn_smod_sign_apply.run [aPtr, rPtr, outPtr] state =
      (.ok (.scalar .unit), Memory.cleanup state.nextId after) := by
    refine program_run_ok hacc ?_ unit_val_hasType
    unfold Generated.fn_smod_sign_apply; dsimp only
    rw [eval_bind_ok (prim_arg_eval rfl) ht_a]
    rw [eval_bind_ok (prim_arg_eval rfl) ht_r]
    rw [eval_bind_ok (prim_arg_eval rfl) ht_out]
    rw [eval_bind_ok (prim_load_eval (ref_local_eval
      (by rw [env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_self]) hv_ap) hload_a) (u256_val_hasType a)]
    rw [eval_bind_ok (prim_load_eval (ref_local_eval
      (by rw [env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_self]) hv_rp) hload_r) (u256_val_hasType r)]
    rw [eval_bind_ok (prim_scalar_eval (scalar_shiftRight256_255_eval
      (scalar_ref_local_eval (scalarEnv_of_env (by rw [env_set_ne _ _ _ _ (by decide), env_set_self])) (u256_scalar_valid a)))) (u256_val_hasType sa)]
    rw [eval_bind_ok (prim_scalar_eval (scalar_arith_eval
      (scalar_ref_const_eval hv_0)
      (scalar_ref_local_eval (scalarEnv_of_env (env_set_self ..)) (u256_scalar_valid sa))
      (by change Scalar.integer false 256 ((0 : BitVec 256).toNat - (sa.toNat : Int)) .wrapping = _; rw [integer_wrapping_uint, bv256_sub_int_mod]))) (u256_val_hasType mask)]
    rw [eval_bind_ok (prim_scalar_eval (scalar_bitXor256_eval
      (scalar_ref_local_eval (scalarEnv_of_env (by rw [env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_self])) (u256_scalar_valid r))
      (scalar_ref_local_eval (scalarEnv_of_env (env_set_self ..)) (u256_scalar_valid mask)))) (u256_val_hasType rm)]
    rw [eval_bind_ok (prim_scalar_eval (scalar_arith_eval
      (scalar_ref_local_eval (scalarEnv_of_env (env_set_self ..)) (u256_scalar_valid rm))
      (scalar_ref_local_eval (scalarEnv_of_env (by rw [env_set_ne _ _ _ _ (by decide), env_set_self])) (u256_scalar_valid mask))
      (by change Scalar.integer false 256 ((rm.toNat : Int) - mask.toNat) .wrapping = _; rw [integer_wrapping_uint, bv256_sub_int_mod]))) (u256_val_hasType res)]
    rw [eval_bind_ok (prim_store_eval
      (ref_local_eval (by rw [env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide),
                              env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_self]) hv_op)
      (ref_local_eval (env_set_self ..) (u256_val_valid res))
      hstore) unit_val_hasType]
    exact eval_ret_ok (ref_const_eval unit_val_valid)
  rw [cleanup_after_store state after outPtr (u256Val res) hvalid hstore] at hrun
  exact ⟨hrun, Memory.store_preserves_valid state outPtr (u256Val res) after hvalid hstore,
    Memory.load_after_store state outPtr (u256Val res) after hstore⟩

/-- Direct Zig AIR proof: `verified_ops.byteRef` computes the exact Yellow Paper
    EVM `BYTE(index, word)` opcode (`GuillotineVerify.Arithmetic.byteRef`) for ALL `2^256 × 2^256` inputs! -/
theorem byte_ref_correct (state after : State) (idxPtr valPtr outPtr : Value)
    (index val : BitVec 256)
    (hvalid : state.valid = true)
    (ht_idx : idxPtr.hasType (.pointer false false u256Ty) = true)
    (ht_val : valPtr.hasType (.pointer false false u256Ty) = true)
    (ht_out : outPtr.hasType (.pointer true false u256Ty) = true)
    (hload_idx : Memory.load state idxPtr = .ok (u256Val index))
    (hload_val : Memory.load state valPtr = .ok (u256Val val))
    (hstore : Memory.store state outPtr (u256Val (GuillotineVerify.Arithmetic.byteRef index val)) = .ok after) :
    Generated.fn_byte_ref.run [idxPtr, valPtr, outPtr] state = (.ok (.scalar .unit), after) ∧
    after.valid = true ∧
    Memory.load after outPtr = .ok (u256Val (GuillotineVerify.Arithmetic.byteRef index val)) := by
  have hv_ip : idxPtr.valid = true := ptr_valid_of_hasType ht_idx
  have hv_vp : valPtr.valid = true := ptr_valid_of_hasType ht_val
  have hv_op : outPtr.valid = true := ptr_valid_of_hasType ht_out
  have hv_32 : (Scalar.Value.int false 256 32).valid = true := Scalar.unsigned_nat_valid 32 256 (by omega)
  have hv_0 : (Scalar.Value.int false 256 0).valid = true := Scalar.unsigned_nat_valid 0 256 (by omega)
  have hv_31 : (Scalar.Value.int false 8 31).valid = true := Scalar.unsigned_nat_valid 31 8 (by omega)
  have hv_8 : (Scalar.Value.int false 8 8).valid = true := Scalar.unsigned_nat_valid 8 8 (by omega)
  have hv_255 : (Scalar.Value.int false 256 255).valid = true := Scalar.unsigned_nat_valid 255 256 (by omega)
  let res : BitVec 256 := GuillotineVerify.Arithmetic.byteRef index val
  change Memory.store state outPtr (u256Val res) = .ok after at hstore
  have hacc : Generated.fn_byte_ref.accepts [idxPtr, valPtr, outPtr] state = true := by
    simp [Program.accepts, Generated.fn_byte_ref, hvalid, ht_idx, ht_val, ht_out]
  have hrun : Generated.fn_byte_ref.run [idxPtr, valPtr, outPtr] state =
      (.ok (.scalar .unit), Memory.cleanup state.nextId after) := by
    refine program_run_ok hacc ?_ unit_val_hasType
    unfold Generated.fn_byte_ref; dsimp only
    rw [eval_bind_ok (prim_arg_eval rfl) ht_idx]
    rw [eval_bind_ok (prim_arg_eval rfl) ht_val]
    rw [eval_bind_ok (prim_arg_eval rfl) ht_out]
    rw [eval_bind_ok (prim_load_eval (ref_local_eval
      (by rw [env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_self]) hv_ip) hload_idx) (u256_val_hasType index)]
    rw [eval_bind_ok (prim_load_eval (ref_local_eval
      (by rw [env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_self]) hv_vp) hload_val) (u256_val_hasType val)]
    let args := [idxPtr, valPtr, outPtr]
    let env0 : Env := Control.Env.set (Control.Env.set (Control.Env.set (Control.Env.set (Control.Env.set (fun _ => none) 0 idxPtr) 1 valPtr) 2 outPtr) 3 (u256Val index)) 4 (u256Val val)
    change Control.Code.eval MemoryAir.semantics _ args env0 state = _
    have he0_2 : env0 2 = some outPtr := by
      simp only [env0]; rw [env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_self]
    have he0_3 : env0 3 = some (u256Val index) := by
      simp only [env0]; rw [env_set_ne _ _ _ _ (by decide), env_set_self]
    have he0_4 : env0 4 = some (u256Val val) := by
      simp only [env0]; rw [env_set_self]
    by_cases hge : index.toNat ≥ 32
    · have hres0 : res = 0 := by simp [res, GuillotineVerify.Arithmetic.byteRef, hge]
      rw [hres0] at hstore
      have hb6 : Control.Code.eval MemoryAir.semantics
          (.bind 7 (.scalar .bool) (.scalar (.comparison .ge (.local 3) (.constant (.int false 256 32))))
          (.branch (.local 7) (.jump 5 (.constant (.scalar (.int false 256 0)))) (.jump 6 (.constant (.scalar .unit)))))
          args env0 state = .jumped 5 (u256Val 0) (Control.Env.set env0 7 (.scalar (.bool true))) state := by
        rw [eval_bind_ok (prim_scalar_eval (scalar_cmp_eval
          (scalar_ref_local_eval (scalarEnv_of_env he0_3) (u256_scalar_valid index))
          (scalar_ref_const_eval hv_32)
          (show Scalar.Comparison.ge.eval index.toNat 32 = true by simp [Scalar.Comparison.eval]; omega))) (bool_val_hasType true)]
        rw [eval_branch_true (ref_local_eval (env_set_self ..) (bool_val_valid true))]
        exact eval_jump_ok (ref_const_eval (u256_val_valid 0))
      rw [eval_block_jump_hit (eval_block_jump_miss hb6 (by decide)) (u256_val_hasType 0)]
      rw [eval_bind_ok (prim_store_eval
        (ref_local_eval (by rw [env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), he0_2]) hv_op)
        (ref_local_eval (env_set_self ..) (u256_val_valid 0))
        hstore) unit_val_hasType]
      exact eval_ret_ok (ref_const_eval unit_val_valid)
    · have hlt32 : index.toNat < 32 := by omega
      have hres_lt : res = (val >>> ((31 - index.toNat) * 8)) &&& 0xFF := by
        simp [res, GuillotineVerify.Arithmetic.byteRef, hge]
      rw [hres_lt] at hstore
      have hv_i8 : (Scalar.Value.int false 8 index.toNat).valid = true := Scalar.unsigned_nat_valid index.toNat 8 (by omega)
      have hv_d8 : (Scalar.Value.int false 8 ↑(31 - index.toNat)).valid = true := Scalar.unsigned_nat_valid (31 - index.toNat) 8 (by omega)
      have hv_sh8 : (Scalar.Value.int false 8 ↑((31 - index.toNat) * 8)).valid = true := scalar_valid_of_nat (w := 8) (by omega)
      have hi_d8 : Scalar.integer false 8 (Scalar.Arithmetic.sub.eval 31 index.toNat) .unchecked =
          .ok (.int false 8 ↑(31 - index.toNat)) := by
        change Scalar.integer false 8 (31 - (index.toNat : Int)) .unchecked = _
        rw [show (31 : Int) - index.toNat = ↑(31 - index.toNat) by omega]
        exact integer_unchecked_of_valid hv_d8
      have hi_sh8 : Scalar.integer false 8 (Scalar.Arithmetic.mul.eval ↑(31 - index.toNat) 8) .unchecked =
          .ok (.int false 8 ↑((31 - index.toNat) * 8)) := by
        change Scalar.integer false 8 ((↑(31 - index.toNat) : Int) * 8) .unchecked = _
        rw [show (↑(31 - index.toNat) : Int) * 8 = ↑((31 - index.toNat) * 8) by omega]
        exact integer_unchecked_of_valid hv_sh8
      let shifted : BitVec 256 := val >>> ((31 - index.toNat) * 8)
      let masked : BitVec 256 := shifted &&& 0xFF
      have hb6 : Control.Code.eval MemoryAir.semantics
          (.bind 7 (.scalar .bool) (.scalar (.comparison .ge (.local 3) (.constant (.int false 256 32))))
          (.branch (.local 7) (.jump 5 (.constant (.scalar (.int false 256 0)))) (.jump 6 (.constant (.scalar .unit)))))
          args env0 state = .jumped 6 (.scalar .unit) (Control.Env.set env0 7 (.scalar (.bool false))) state := by
        rw [eval_bind_ok (prim_scalar_eval (scalar_cmp_eval
          (scalar_ref_local_eval (scalarEnv_of_env he0_3) (u256_scalar_valid index))
          (scalar_ref_const_eval hv_32)
          (show Scalar.Comparison.ge.eval index.toNat 32 = false by simp [Scalar.Comparison.eval]; omega))) (bool_val_hasType false)]
        rw [eval_branch_false (ref_local_eval (env_set_self ..) (bool_val_valid false))]
        exact eval_jump_ok (ref_const_eval unit_val_valid)
      rw [eval_block_jump_hit (by
        rw [eval_block_jump_hit hb6 unit_val_hasType]
        rw [eval_bind_ok (prim_scalar_eval (scalar_cast_unchecked_eval
          (scalar_ref_local_eval (scalarEnv_of_env (by rw [env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), he0_3])) (u256_scalar_valid index))
          (integer_unchecked_of_valid hv_i8))) (mem_scalar_hasType (scalar_hasType_of_valid hv_i8))]
        rw [eval_bind_ok (prim_scalar_eval (scalar_arith_eval
          (scalar_ref_const_eval hv_31)
          (scalar_ref_local_eval (scalarEnv_of_env (env_set_self ..)) hv_i8)
          hi_d8)) (mem_scalar_hasType (scalar_hasType_of_valid hv_d8))]
        rw [eval_bind_ok (prim_scalar_eval (scalar_arith_eval
          (scalar_ref_local_eval (scalarEnv_of_env (env_set_self ..)) hv_d8)
          (scalar_ref_const_eval hv_8)
          hi_sh8)) (mem_scalar_hasType (scalar_hasType_of_valid hv_sh8))]
        rw [eval_bind_ok (prim_scalar_eval (scalar_shiftRight256_eval ((31 - index.toNat) * 8)
          (scalar_ref_local_eval (scalarEnv_of_env (by rw [env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), he0_4])) (u256_scalar_valid val))
          (scalar_ref_local_eval (scalarEnv_of_env (env_set_self ..)) hv_sh8) (by omega))) (u256_val_hasType shifted)]
        rw [eval_bind_ok (prim_scalar_eval (scalar_bitAnd256_255_eval
          (scalar_ref_local_eval (scalarEnv_of_env (env_set_self ..)) (u256_scalar_valid shifted)))) (u256_val_hasType masked)]
        exact eval_jump_ok (ref_local_eval (env_set_self ..) (u256_val_valid masked))) (u256_val_hasType masked)]
      rw [eval_bind_ok (prim_store_eval
        (ref_local_eval (by rw [env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide),
                                env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide),
                                env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), he0_2]) hv_op)
        (ref_local_eval (env_set_self ..) (u256_val_valid masked))
        hstore) unit_val_hasType]
      exact eval_ret_ok (ref_const_eval unit_val_valid)
  rw [cleanup_after_store state after outPtr (u256Val res) hvalid hstore] at hrun
  exact ⟨hrun, Memory.store_preserves_valid state outPtr (u256Val res) after hvalid hstore,
    Memory.load_after_store state outPtr (u256Val res) after hstore⟩

end GuillotineZean.Word256Ops
