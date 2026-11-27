/-
  GuillotineZean.BytecodeJumpdest.Proofs

  Direct Zig 0.17.1 AIR -> Lean 4 formal proof for Guillotine's Yellow Paper
  Section 9.4.3 JUMPDEST bytecode scanner `verified_ops.isValidJumpdestBytes`:
    - Memory safety across arbitrary EVM bytecodes of any length, including
      truncated trailing `PUSH1..PUSH32` opcodes (never reads past `len` or
      overflows `pc + step`)
    - Exact functional equivalence to the pure Yellow Paper specification
      `validJumpdestSpec code len target`
    - Read-only heap framing: caller heap is completely unchanged on both
      normal return and modeled stack exhaustion (`outOfMemory`)
    - Soundness for every finite fuel budget (`Verify.Observes`)
-/
import GuillotineZean.BytecodeJumpdest.Generated
import GuillotineZean.LoopHelpers
import Compiler.ZigAir.MemoryReadView

namespace GuillotineZean.BytecodeJumpdest
open Compiler.ZigAir Compiler.ZigAir.Memory Compiler.ZigAir.MemoryAir MemoryAir.Verify
open Control.Verification Std.WP GuillotineZean.MemoryHelpers GuillotineZean.LoopHelpers

abbrev codePtrTy : Memory.Ty := .pointer false true u8Ty
abbrev byteVal (b : BitVec 8) : Memory.Value := .scalar (.int false 8 b.toNat)
abbrev sizeVal (n : Nat) : Memory.Value := .scalar (.int false 64 n)

abbrev codeView (address : Address) (length : Nat) : ReadView :=
  ⟨u8Ty, ⟨1, 1⟩, rfl, by decide, address, length⟩

/-- Pure Yellow Paper Section 9.4.3 JUMPDEST validity specification starting from `pc`. -/
def validJumpdestFrom (code : Nat → BitVec 8) (len target pc : Nat) : Bool :=
  if h : pc < len then
    let op := (code pc).toNat
    if pc = target then op == 91
    else if 96 ≤ op ∧ op ≤ 127 then
      let step := (op - 96) + 2
      if step > len - pc then false
      else validJumpdestFrom code len target (pc + step)
    else validJumpdestFrom code len target (pc + 1)
  else false
termination_by len - pc

/-- Top-level Yellow Paper JUMPDEST specification: `target < len` and `target`
    lands on a non-PUSH-immediate `0x5B` (`91`) opcode byte. -/
def validJumpdestSpec (code : Nat → BitVec 8) (len target : Nat) : Bool :=
  if target ≥ len then false else validJumpdestFrom code len target 0

def arguments (address : Address) (len target : Nat) : List Memory.Value :=
  [(codeView address len).buffer, sizeVal len, sizeVal target]

/-- Loop invariant at loop label `17` of `fn_is_valid_jumpdest_bytes`:
    - `pc ≤ len` and `target < len`
    - `validJumpdestFrom code len target pc = validJumpdestSpec code len target`
    - Stack locals (`code` at `initial.nextId`, `pc` at `initial.nextId + 1`) remain live
    - Caller heap is completely read-only (`StackFrame initial state`) -/
def loopInvariant (initial : State) (address : Address) (len target : Nat)
    (code : Nat → BitVec 8) : Invariants :=
  fun label env state => label = 17 ∧ ∃ pc : Nat,
    pc ≤ len ∧ target < len ∧
    validJumpdestFrom code len target pc = validJumpdestSpec code len target ∧
    env 1 = some (sizeVal len) ∧
    env 2 = some (sizeVal target) ∧
    env 6 = some (.pointer (.pointer false false codePtrTy) ⟨initial.nextId, 0⟩) ∧
    env 14 = some (.pointer (.pointer true false u64Ty) ⟨initial.nextId + 1, 0⟩) ∧
    Memory.load state (.pointer (.pointer false false codePtrTy) ⟨initial.nextId, 0⟩) = .ok (codeView address len).buffer ∧
    Memory.load state (.pointer (.pointer true false u64Ty) ⟨initial.nextId + 1, 0⟩) = .ok (sizeVal pc) ∧
    Memory.RootWritable state u64Ty (initial.nextId + 1) ∧
    StackFrame initial state

def Completed (initial : State) (code : Nat → BitVec 8) (len target : Nat)
    (result : Memory.Value) (after : State) : Prop :=
  result = .scalar (.bool (validJumpdestSpec code len target)) ∧
  after.valid = true ∧ after.heap = initial.heap

def Exhausted (initial : State) (fault : Fault) (after : State) : Prop :=
  fault = .outOfMemory ∧ after.valid = true ∧ after.heap = initial.heap

private theorem spec_ge (code : Nat → BitVec 8) (len target : Nat) (hge : target ≥ len) :
    validJumpdestSpec code len target = false := by
  simp [validJumpdestSpec, hge]

private theorem spec_lt (code : Nat → BitVec 8) (len target : Nat) (hlt : target < len) :
    validJumpdestFrom code len target 0 = validJumpdestSpec code len target := by
  simp [validJumpdestSpec, show ¬ (target ≥ len) by omega]

private theorem from_end (code : Nat → BitVec 8) (len target pc : Nat) (hge : ¬ (pc < len)) :
    validJumpdestFrom code len target pc = false := by
  rw [validJumpdestFrom]; simp [hge]

private theorem from_hit (code : Nat → BitVec 8) (len target pc : Nat)
    (hlt : pc < len) (heq : pc = target) :
    validJumpdestFrom code len target pc = decide ((code pc).toNat = 91) := by
  subst heq; rw [validJumpdestFrom]; simp only [hlt, ↓reduceDIte, ↓reduceIte]
  by_cases h : (code pc).toNat = 91 <;> simp [h]

private theorem from_push_trunc (code : Nat → BitVec 8) (len target pc : Nat)
    (hlt : pc < len) (hne : pc ≠ target)
    (hlo : 96 ≤ (code pc).toNat) (hhi : (code pc).toNat ≤ 127)
    (htrunc : ((code pc).toNat - 96) + 2 > len - pc) :
    validJumpdestFrom code len target pc = false := by
  rw [validJumpdestFrom]; simp [hlt, hne, hlo, hhi, htrunc]

private theorem from_push_step (code : Nat → BitVec 8) (len target pc : Nat)
    (hlt : pc < len) (hne : pc ≠ target)
    (hlo : 96 ≤ (code pc).toNat) (hhi : (code pc).toNat ≤ 127)
    (hfit : ¬ (((code pc).toNat - 96) + 2 > len - pc)) :
    validJumpdestFrom code len target (pc + (((code pc).toNat - 96) + 2)) =
      validJumpdestFrom code len target pc := by
  symm; rw [validJumpdestFrom]; simp [hlt, hne, hlo, hhi, hfit]

private theorem from_other_step (code : Nat → BitVec 8) (len target pc : Nat)
    (hlt : pc < len) (hne : pc ≠ target)
    (hnot : ¬ (96 ≤ (code pc).toNat ∧ (code pc).toNat ≤ 127)) :
    validJumpdestFrom code len target (pc + 1) =
      validJumpdestFrom code len target pc := by
  symm; rw [validJumpdestFrom]; simp [hlt, hne, hnot]

private theorem u8_scalar_valid {n : Nat} (hn : n < 2 ^ 8) : (Scalar.Value.int false 8 n).valid = true :=
  Scalar.unsigned_nat_valid n 8 hn

private theorem u8_val_hasType {n : Nat} (hn : n < 2 ^ 8) : (Value.scalar (.int false 8 n)).hasType u8Ty = true :=
  mem_scalar_hasType (scalar_hasType_of_valid (u8_scalar_valid hn))

private theorem size_scalar_valid {n : Nat} (hn : n < 2 ^ 64) : (Scalar.Value.int false 64 n).valid = true :=
  Scalar.unsigned_nat_valid n 64 hn

private theorem size_val_valid {n : Nat} (hn : n < 2 ^ 64) : (sizeVal n).valid = true :=
  mem_scalar_valid (size_scalar_valid hn)

private theorem size_val_hasType {n : Nat} (hn : n < 2 ^ 64) : (sizeVal n).hasType u64Ty = true :=
  mem_scalar_hasType (scalar_hasType_of_valid (size_scalar_valid hn))

private theorem alloc_nextId {s s' : State} {child : Memory.Ty} {p : Memory.Value}
    (h : Memory.allocate s child = .ok (p, s')) : s'.nextId = s.nextId + 1 := by
  obtain ⟨_, _, _, _, rfl⟩ := Memory.allocate_shape s child p s' h
  rfl

/-- Direct Zig AIR WP contract for `verified_ops.isValidJumpdestBytes`:
    for any valid EVM bytecode buffer of length `len < addressLimit`, the
    captured Zig 0.17.1 AIR scanner never faults (except modeled stack OOM),
    never reads past `len`, preserves the caller heap, and returns the exact
    Yellow Paper Section 9.4.3 JUMPDEST validity boolean. -/
theorem is_valid_jumpdest_bytes_contract
    (initial : State) (address : Address) (len target : Nat)
    (code : Nat → BitVec 8)
    (valid : initial.valid = true)
    (cap : ReadView.Represents initial (codeView address len) (fun i => byteVal (code i)))
    (hlen : len < addressLimit) (htarget : target < addressLimit) :
    Triple (Verify.Invocation.mk Generated.fn_is_valid_jumpdest_bytes
      (arguments address len target)
      (loopInvariant initial address len target code))
      (fun before => before = initial)
      (Completed initial code len target)
      (Exhausted initial) := by
  have hlen64 : len < 2 ^ 64 := by unfold addressLimit at hlen; omega
  have htgt64 : target < 2 ^ 64 := by unfold addressLimit at htarget; omega
  have ht_buf : (codeView address len).buffer.hasType codePtrTy = true := rfl
  have hv_buf : (codeView address len).buffer.valid = true := rfl
  have ht_len : (sizeVal len).hasType u64Ty = true := size_val_hasType hlen64
  have ht_tgt : (sizeVal target).hasType u64Ty = true := size_val_hasType htgt64
  have hacc : Generated.fn_is_valid_jumpdest_bytes.accepts (arguments address len target) initial = true := by
    simp only [Program.accepts, Generated.fn_is_valid_jumpdest_bytes, arguments, valid, List.length_cons, List.length_nil,
      List.zip_cons_cons, List.zip_nil_right, List.all_cons, List.all_nil, Bool.and_true, decide_true, Bool.true_and]
    exact (Bool.and_eq_true _ _).mpr ⟨ht_buf, (Bool.and_eq_true _ _).mpr ⟨ht_len, ht_tgt⟩⟩
  refine triple_of_pre hacc ?_
  dsimp only [Generated.fn_is_valid_jumpdest_bytes, arguments]
  -- Bind arguments 0, 1, 2
  rw [pre_bind_eq (prim_arg_eval (i := 0) (args := [(codeView address len).buffer, sizeVal len, sizeVal target]) rfl) ht_buf]
  rw [pre_bind_eq (prim_arg_eval (i := 1) (args := [(codeView address len).buffer, sizeVal len, sizeVal target]) rfl) ht_len]
  rw [pre_bind_eq (prim_arg_eval (i := 2) (args := [(codeView address len).buffer, sizeVal len, sizeVal target]) rfl) ht_tgt]
  -- Block 3: return block
  rw [pre_block_eq]
  -- Alloc 4 (codePtr slot, id = initial.nextId), store 5, cast 6
  refine pre_bind_alloc valid (layout := ⟨8, 8⟩) rfl
    ⟨rfl, (StackFrame.refl initial valid).cleanup_valid, (StackFrame.refl initial valid).cleanup_heap⟩ ?_
  intro s4 halloc4 hvalid4 hsf4
  have hnid4 : s4.nextId = initial.nextId + 1 := alloc_nextId halloc4
  have hcap4 : Memory.RootWritable s4 codePtrTy initial.nextId := Memory.RootWritable.allocated initial s4 _ _ halloc4
  refine with_fresh_store (child := codePtrTy) (layout := ⟨8, 8⟩) rfl (by decide) hv_buf rfl halloc4 fun s5 hst5 hvalid5 hsf5 hld5 => ?_
  have hnid5 : s5.nextId = initial.nextId + 1 := (store_preserves_nextId s4 s5 _ _ hst5).trans hnid4
  have hcap5 : Memory.RootWritable s5 codePtrTy initial.nextId := hcap4.stored s4 s5 _ _ _ _ hst5
  rw [pre_bind_eq (prim_store_eval (ref_local_eval (env_set_self ..) rfl)
    (ref_local_eval (by env_here) hv_buf) hst5) unit_val_hasType]
  have hcast6 := root_cast_const_ok hvalid5 (layout := ⟨8, 8⟩) rfl (by decide) hcap5
  rw [pre_bind_eq (prim_pointerCast_eval (ref_local_eval (by env_here) rfl) hcast6) rfl]
  -- Block 7: if target >= len return false
  rw [pre_block_eq]
  rw [pre_bind_eq (prim_scalar_eval (scalar_bitcast_u64_eval htgt64
    (scalar_ref_local_eval (scalarEnv_of_env (by env_here)) (size_scalar_valid htgt64)))) ht_tgt]
  rw [pre_bind_eq (prim_scalar_eval (scalar_bitcast_u64_eval hlen64
    (scalar_ref_local_eval (scalarEnv_of_env (by env_here)) (size_scalar_valid hlen64)))) ht_len]
  by_cases hge : target ≥ len
  · -- Early exit: target ≥ len -> return false
    rw [pre_bind_eq (prim_scalar_eval (scalar_cmp_eval
      (scalar_ref_local_eval (scalarEnv_of_env (by env_here)) (size_scalar_valid htgt64))
      (scalar_ref_local_eval (scalarEnv_of_env (env_set_self ..)) (size_scalar_valid hlen64))
      (show Scalar.Comparison.ge.eval target len = true by simp [Scalar.Comparison.eval, hge]))) (bool_val_hasType true)]
    rw [pre_branch_true_eq (ref_local_eval (env_set_self ..) (bool_val_valid true))]
    rw [pre_jump_eq (ref_const_eval (bool_val_valid false))]
    refine blockPost_miss (by decide) ?_
    refine blockPost_hit (bool_val_hasType false) ?_
    rw [pre_ret_eq (ref_local_eval (env_set_self ..) (bool_val_valid false))]
    refine finishPost_ret (bool_val_hasType false) ⟨by rw [spec_ge code len target hge], hsf5.cleanup_valid, hsf5.cleanup_heap⟩
  · -- target < len: continue past block 7
    have htgt_lt : target < len := by omega
    rw [pre_bind_eq (prim_scalar_eval (scalar_cmp_eval
      (scalar_ref_local_eval (scalarEnv_of_env (by env_here)) (size_scalar_valid htgt64))
      (scalar_ref_local_eval (scalarEnv_of_env (env_set_self ..)) (size_scalar_valid hlen64))
      (show Scalar.Comparison.ge.eval target len = false by simp [Scalar.Comparison.eval, hge]))) (bool_val_hasType false)]
    rw [pre_branch_false_eq (ref_local_eval (env_set_self ..) (bool_val_valid false))]
    rw [pre_jump_eq (ref_const_eval unit_val_valid)]
    refine blockPost_hit unit_val_hasType ?_
    -- Alloc 14 (pc slot, id = initial.nextId + 1), store 15 (pc = 0)
    refine pre_bind_alloc hvalid5 (layout := ⟨8, 8⟩) rfl ⟨rfl, hsf5.cleanup_valid, hsf5.cleanup_heap⟩ ?_
    intro s14 halloc14 hvalid14 hsf14
    have hcap14_pc : Memory.RootWritable s14 u64Ty (initial.nextId + 1) := by
      have := Memory.RootWritable.allocated s5 s14 _ _ halloc14; rwa [hnid5] at this
    have hv0 : (sizeVal 0).valid = true := size_val_valid (by omega)
    refine with_fresh_store (child := u64Ty) (layout := ⟨8, 8⟩) rfl (by decide) hv0 rfl halloc14 fun s15 hst15 hvalid15 hsf15_step hld15 => ?_
    rw [hnid5] at hst15 hld15 ⊢
    have hsf15 : StackFrame initial s15 := hsf5.trans hsf15_step
    have hcap15_pc : Memory.RootWritable s15 u64Ty (initial.nextId + 1) := hcap14_pc.stored s14 s15 _ _ _ _ hst15
    have hld_code15 : Memory.load s15 (.pointer (.pointer false false codePtrTy) ⟨initial.nextId, 0⟩) = .ok (codeView address len).buffer := by
      have h1 := (Memory.load_after_allocate s5 u64Ty _ s14 false false codePtrTy ⟨initial.nextId, 0⟩ halloc14 (by dsimp; rw [hnid5]; omega)).trans (root_load_const_of_mut hld5)
      exact (Memory.load_other_after_store s14 true false u64Ty ⟨initial.nextId + 1, 0⟩ (sizeVal 0) s15 false false codePtrTy ⟨initial.nextId, 0⟩ hst15 (by dsimp; omega)).trans h1
    have hv0' : (Value.scalar (.int false 64 0)).valid = true := hv0
    have hst15' : Memory.store s14 (.pointer (.pointer true false u64Ty) ⟨initial.nextId + 1, 0⟩) (.scalar (.int false 64 0)) = .ok s15 := hst15
    rw [pre_bind_eq (prim_store_eval (ref_local_eval (env_set_self ..) rfl) (ref_const_eval hv0') hst15') unit_val_hasType]
    -- Block 16 -> Loop 17
    rw [pre_block_eq]
    rw [pre_loop_eq]
    constructor
    · -- Loop entry: pc = 0
      refine ⟨rfl, 0, Nat.zero_le len, htgt_lt, spec_lt code len target htgt_lt,
        by env_here, by env_here, by env_here, by env_here,
        hld_code15, hld15, hcap15_pc, hsf15⟩
    · -- Loop body preservation
      rintro envL stateL ⟨_, pc, hpc_le, _, hspec, he1, he2, he6, he14, hld_code, hld_pc, hcap_pc, hsfL⟩
      have hpc64 : pc < 2 ^ 64 := by omega
      have hcapL : ReadView.Represents stateL (codeView address len) (fun i => byteVal (code i)) := cap.stack hsfL
      -- Block 18 (loop iteration)
      rw [pre_block_eq]
      rw [pre_bind_eq (prim_load_eval (ref_local_eval he14 rfl) hld_pc) (size_val_hasType hpc64)]
      rw [pre_bind_eq (prim_scalar_eval (scalar_bitcast_u64_eval hpc64
        (scalar_ref_local_eval (scalarEnv_of_env (env_set_self ..)) (size_scalar_valid hpc64)))) (size_val_hasType hpc64)]
      rw [pre_bind_eq (prim_scalar_eval (scalar_bitcast_u64_eval hlen64
        (scalar_ref_local_eval (scalarEnv_of_env (by env_use he1)) (size_scalar_valid hlen64)))) ht_len]
      by_cases hlt : pc < len
      · -- pc < len: inspect bytecode[pc]
        rw [pre_bind_eq (prim_scalar_eval (scalar_cmp_eval
          (scalar_ref_local_eval (scalarEnv_of_env (by env_here)) (size_scalar_valid hpc64))
          (scalar_ref_local_eval (scalarEnv_of_env (env_set_self ..)) (size_scalar_valid hlen64))
          (show Scalar.Comparison.lt.eval pc len = true by simp [Scalar.Comparison.eval, hlt]))) (bool_val_hasType true)]
        rw [pre_branch_true_eq (ref_local_eval (env_set_self ..) (bool_val_valid true))]
        -- Load pc (24), code ptr (25), elemPtr (26), op = code[pc] (27)
        rw [pre_bind_eq (prim_load_eval (ref_local_eval (by env_use he14) rfl) hld_pc) (size_val_hasType hpc64)]
        rw [pre_bind_eq (prim_load_eval (ref_local_eval (by env_use he6) rfl) hld_code) ht_buf]
        have helem := hcapL.element pc hlt
        have hld_op := hcapL.read pc hlt
        rw [pre_bind_eq (prim_elementPointer_eval (ref_local_eval (env_set_self ..) hv_buf)
          (ref_natural_local (by env_here) hpc64) helem) rfl]
        rw [pre_bind_eq (prim_load_eval (ref_local_eval (env_set_self ..) rfl) hld_op) (u8_val_hasType (code pc).isLt)]
        -- Block 28: if pc == target return op == 0x5B (91)
        rw [pre_block_eq]
        rw [pre_bind_eq (prim_load_eval (ref_local_eval (by env_use he14) rfl) hld_pc) (size_val_hasType hpc64)]
        rw [pre_bind_eq (prim_scalar_eval (scalar_bitcast_u64_eval hpc64
          (scalar_ref_local_eval (scalarEnv_of_env (env_set_self ..)) (size_scalar_valid hpc64)))) (size_val_hasType hpc64)]
        rw [pre_bind_eq (prim_scalar_eval (scalar_bitcast_u64_eval htgt64
          (scalar_ref_local_eval (scalarEnv_of_env (by env_use he2)) (size_scalar_valid htgt64)))) ht_tgt]
        by_cases hhit : pc = target
        · -- Found target position: return (op == 91)
          rw [pre_bind_eq (prim_scalar_eval (scalar_cmp_eval
            (scalar_ref_local_eval (scalarEnv_of_env (by env_here)) (size_scalar_valid hpc64))
            (scalar_ref_local_eval (scalarEnv_of_env (env_set_self ..)) (size_scalar_valid htgt64))
            (show Scalar.Comparison.eq.eval pc target = true by simp [Scalar.Comparison.eval, hhit]))) (bool_val_hasType true)]
          rw [pre_branch_true_eq (ref_local_eval (env_set_self ..) (bool_val_valid true))]
          have hv91 : (Scalar.Value.int false 8 91).valid = true := u8_scalar_valid (n := 91) (by omega)
          have hcmp91 : Scalar.Comparison.eq.eval (code pc).toNat (91 : Int) = decide ((code pc).toNat = 91) := by
            simp only [Scalar.Comparison.eval, decide_eq_decide]; omega
          rw [pre_bind_eq (prim_scalar_eval (scalar_cmp_eval
            (scalar_ref_local_eval (scalarEnv_of_env (by env_here)) (u8_scalar_valid (code pc).isLt))
            (scalar_ref_const_eval hv91) hcmp91)) (bool_val_hasType _)]
          rw [pre_jump_eq (ref_local_eval (env_set_self ..) (bool_val_valid _))]
          refine blockPost_miss (by decide) (blockPost_miss (by decide) (loopPost_jump_miss (by decide) (blockPost_miss (by decide) ?_)))
          refine blockPost_hit (bool_val_hasType _) ?_
          rw [pre_ret_eq (ref_local_eval (env_set_self ..) (bool_val_valid _))]
          refine finishPost_ret (bool_val_hasType _) ⟨?_, hsfL.cleanup_valid, hsfL.cleanup_heap⟩
          rw [← hspec, from_hit code len target pc hlt hhit]
        · -- pc ≠ target: check if PUSH1..PUSH32 (96 ≤ op ≤ 127)
          rw [pre_bind_eq (prim_scalar_eval (scalar_cmp_eval
            (scalar_ref_local_eval (scalarEnv_of_env (by env_here)) (size_scalar_valid hpc64))
            (scalar_ref_local_eval (scalarEnv_of_env (env_set_self ..)) (size_scalar_valid htgt64))
            (show Scalar.Comparison.eq.eval pc target = false by simp [Scalar.Comparison.eval, Int.ofNat_inj, hhit]))) (bool_val_hasType false)]
          rw [pre_branch_false_eq (ref_local_eval (env_set_self ..) (bool_val_valid false))]
          rw [pre_jump_eq (ref_const_eval unit_val_valid)]
          refine blockPost_hit unit_val_hasType ?_
          -- Block 37: advance pc by PUSH step or 1
          rw [pre_block_eq]
          have hv96 : (Scalar.Value.int false 8 96).valid = true := u8_scalar_valid (n := 96) (by omega)
          have hv127 : (Scalar.Value.int false 8 127).valid = true := u8_scalar_valid (n := 127) (by omega)
          by_cases hge96 : 96 ≤ (code pc).toNat
          · -- op ≥ 96: evaluate block 39 (op ≤ 127)
            rw [pre_bind_eq (prim_scalar_eval (scalar_cmp_eval
              (scalar_ref_local_eval (scalarEnv_of_env (by env_here)) (u8_scalar_valid (code pc).isLt))
              (scalar_ref_const_eval hv96)
              (show Scalar.Comparison.ge.eval (code pc).toNat (96 : Int) = true by simp [Scalar.Comparison.eval]; omega))) (bool_val_hasType true)]
            rw [pre_block_eq]
            rw [pre_branch_true_eq (ref_local_eval (env_set_self ..) (bool_val_valid true))]
            by_cases hle127 : (code pc).toNat ≤ 127
            · -- PUSH1..PUSH32!
              rw [pre_bind_eq (prim_scalar_eval (scalar_cmp_eval
                (scalar_ref_local_eval (scalarEnv_of_env (by env_here)) (u8_scalar_valid (code pc).isLt))
                (scalar_ref_const_eval hv127)
                (show Scalar.Comparison.le.eval (code pc).toNat (127 : Int) = true by simp [Scalar.Comparison.eval]; omega))) (bool_val_hasType true)]
              rw [pre_jump_eq (ref_local_eval (env_set_self ..) (bool_val_valid true))]
              refine blockPost_hit (bool_val_hasType true) ?_
              rw [pre_branch_true_eq (ref_local_eval (env_set_self ..) (bool_val_valid true))]
              -- 44: op - 96 (u8), 45: cast u64, 46: +1, 47: +1 (= step)
              have hd8 : (code pc).toNat - 96 < 2 ^ 8 := by omega
              have hd64 : (code pc).toNat - 96 < 2 ^ 64 := by omega
              have hs1_64 : ((code pc).toNat - 96) + 1 < 2 ^ 64 := by omega
              let step := ((code pc).toNat - 96) + 2
              have hstep64 : step < 2 ^ 64 := by omega
              have hi44 : Scalar.integer false 8 (Scalar.Arithmetic.sub.eval (code pc).toNat (96 : Int)) .unchecked = .ok (.int false 8 ↑((code pc).toNat - 96)) := by
                change Scalar.integer false 8 (((code pc).toNat : Int) - 96) .unchecked = _
                rw [show (((code pc).toNat : Int) - 96) = ↑((code pc).toNat - 96) by omega]
                exact integer_unchecked_of_valid (u8_scalar_valid hd8)
              rw [pre_bind_eq (prim_scalar_eval (scalar_arith_eval
                (scalar_ref_local_eval (scalarEnv_of_env (by env_here)) (u8_scalar_valid (code pc).isLt))
                (scalar_ref_const_eval hv96) hi44)) (u8_val_hasType hd8)]
              have hi45 : Scalar.integer false 64 ↑((code pc).toNat - 96) .unchecked = .ok (.int false 64 ↑((code pc).toNat - 96)) :=
                integer_unchecked_of_valid (size_scalar_valid hd64)
              rw [pre_bind_eq (prim_scalar_eval (scalar_cast_unchecked_eval
                (scalar_ref_local_eval (scalarEnv_of_env (env_set_self ..)) (u8_scalar_valid hd8)) hi45)) (size_val_hasType hd64)]
              have hv1 : (Scalar.Value.int false 64 1).valid = true := size_scalar_valid (n := 1) (by omega)
              have hi46 : Scalar.integer false 64 (Scalar.Arithmetic.add.eval ↑((code pc).toNat - 96) (1 : Int)) .unchecked = .ok (.int false 64 ↑(((code pc).toNat - 96) + 1)) := by
                change Scalar.integer false 64 ((↑((code pc).toNat - 96) : Int) + 1) .unchecked = _
                rw [show (↑((code pc).toNat - 96) : Int) + 1 = ↑(((code pc).toNat - 96) + 1) by omega]
                exact integer_unchecked_of_valid (size_scalar_valid hs1_64)
              rw [pre_bind_eq (prim_scalar_eval (scalar_arith_eval
                (scalar_ref_local_eval (scalarEnv_of_env (env_set_self ..)) (size_scalar_valid hd64))
                (scalar_ref_const_eval hv1) hi46)) (size_val_hasType hs1_64)]
              have hi47 : Scalar.integer false 64 (Scalar.Arithmetic.add.eval ↑(((code pc).toNat - 96) + 1) (1 : Int)) .unchecked = .ok (.int false 64 ↑step) := by
                change Scalar.integer false 64 ((↑(((code pc).toNat - 96) + 1) : Int) + 1) .unchecked = _
                rw [show (↑(((code pc).toNat - 96) + 1) : Int) + 1 = ↑step by omega]
                exact integer_unchecked_of_valid (size_scalar_valid hstep64)
              rw [pre_bind_eq (prim_scalar_eval (scalar_arith_eval
                (scalar_ref_local_eval (scalarEnv_of_env (env_set_self ..)) (size_scalar_valid hs1_64))
                (scalar_ref_const_eval hv1) hi47)) (size_val_hasType hstep64)]
              -- Block 48: truncation guard `step > len - pc`
              rw [pre_block_eq]
              rw [pre_bind_eq (prim_load_eval (ref_local_eval (by env_use he14) rfl) hld_pc) (size_val_hasType hpc64)]
              have hrem64 : len - pc < 2 ^ 64 := by omega
              have hi50 : Scalar.integer false 64 (Scalar.Arithmetic.sub.eval len pc) .unchecked = .ok (.int false 64 ↑(len - pc)) := by
                change Scalar.integer false 64 ((len : Int) - pc) .unchecked = _
                rw [show (len : Int) - pc = ↑(len - pc) by omega]
                exact integer_unchecked_of_valid (size_scalar_valid hrem64)
              rw [pre_bind_eq (prim_scalar_eval (scalar_arith_eval
                (scalar_ref_local_eval (scalarEnv_of_env (by env_use he1)) (size_scalar_valid hlen64))
                (scalar_ref_local_eval (scalarEnv_of_env (env_set_self ..)) (size_scalar_valid hpc64)) hi50)) (size_val_hasType hrem64)]
              rw [pre_bind_eq (prim_scalar_eval (scalar_bitcast_u64_eval hstep64
                (scalar_ref_local_eval (scalarEnv_of_env (by env_here)) (size_scalar_valid hstep64)))) (size_val_hasType hstep64)]
              rw [pre_bind_eq (prim_scalar_eval (scalar_bitcast_u64_eval hrem64
                (scalar_ref_local_eval (scalarEnv_of_env (by env_here)) (size_scalar_valid hrem64)))) (size_val_hasType hrem64)]
              by_cases htrunc : step > len - pc
              · -- Truncated PUSH immediate -> return false
                rw [pre_bind_eq (prim_scalar_eval (scalar_cmp_eval
                  (scalar_ref_local_eval (scalarEnv_of_env (by env_here)) (size_scalar_valid hstep64))
                  (scalar_ref_local_eval (scalarEnv_of_env (env_set_self ..)) (size_scalar_valid hrem64))
                  (show Scalar.Comparison.gt.eval (step : Int) (↑(len - pc) : Int) = true by simp [Scalar.Comparison.eval]; omega))) (bool_val_hasType true)]
                rw [pre_branch_true_eq (ref_local_eval (env_set_self ..) (bool_val_valid true))]
                rw [pre_jump_eq (ref_const_eval (bool_val_valid false))]
                refine blockPost_miss (by decide) (blockPost_miss (by decide) (blockPost_miss (by decide) (loopPost_jump_miss (by decide) (blockPost_miss (by decide) ?_))))
                refine blockPost_hit (bool_val_hasType false) ?_
                rw [pre_ret_eq (ref_local_eval (env_set_self ..) (bool_val_valid false))]
                refine finishPost_ret (bool_val_hasType false) ⟨?_, hsfL.cleanup_valid, hsfL.cleanup_heap⟩
                rw [← hspec, from_push_trunc code len target pc hlt hhit hge96 hle127 htrunc]
              · -- PUSH fits: pc' = pc + step ≤ len
                rw [pre_bind_eq (prim_scalar_eval (scalar_cmp_eval
                  (scalar_ref_local_eval (scalarEnv_of_env (by env_here)) (size_scalar_valid hstep64))
                  (scalar_ref_local_eval (scalarEnv_of_env (env_set_self ..)) (size_scalar_valid hrem64))
                  (show Scalar.Comparison.gt.eval (step : Int) (↑(len - pc) : Int) = false by simp [Scalar.Comparison.eval]; omega))) (bool_val_hasType false)]
                rw [pre_branch_false_eq (ref_local_eval (env_set_self ..) (bool_val_valid false))]
                rw [pre_jump_eq (ref_const_eval unit_val_valid)]
                refine blockPost_hit unit_val_hasType ?_
                have hnext64 : pc + step < 2 ^ 64 := by omega
                rw [pre_bind_eq (prim_load_eval (ref_local_eval (by env_use he14) rfl) hld_pc) (size_val_hasType hpc64)]
                have hi58 : Scalar.integer false 64 (Scalar.Arithmetic.add.eval pc step) .unchecked = .ok (.int false 64 ↑(pc + step)) := by
                  change Scalar.integer false 64 ((pc : Int) + step) .unchecked = _
                  rw [show (pc : Int) + step = ↑(pc + step) by omega]
                  exact integer_unchecked_of_valid (size_scalar_valid hnext64)
                rw [pre_bind_eq (prim_scalar_eval (scalar_arith_eval
                  (scalar_ref_local_eval (scalarEnv_of_env (env_set_self ..)) (size_scalar_valid hpc64))
                  (scalar_ref_local_eval (scalarEnv_of_env (by env_here)) (size_scalar_valid hstep64)) hi58)) (size_val_hasType hnext64)]
                refine with_root_store hsfL.valid hcap_pc (size_val_hasType hnext64) (layout := ⟨8, 8⟩) rfl (by decide) fun stateN hstN => ?_
                rw [pre_bind_eq (prim_store_eval (ref_local_eval (by env_use he14) rfl)
                  (ref_local_eval (env_set_self ..) (size_val_valid hnext64)) hstN) unit_val_hasType]
                rw [pre_jump_eq (ref_const_eval unit_val_valid)]
                refine blockPost_hit unit_val_hasType ?_
                rw [pre_jump_eq (ref_const_eval unit_val_valid)]
                refine blockPost_hit unit_val_hasType ?_
                rw [pre_repeat_eq]
                refine loopPost_repeat_hit ?_
                refine ⟨rfl, pc + step, by omega, htgt_lt,
                  (from_push_step code len target pc hlt hhit hge96 hle127 htrunc).trans hspec,
                  by env_use he1, by env_use he2, by env_use he6, by env_use he14,
                  (Memory.load_other_after_store stateL true false u64Ty ⟨initial.nextId + 1, 0⟩ _ stateN false false codePtrTy ⟨initial.nextId, 0⟩ hstN (by dsimp; omega)).trans hld_code,
                  Memory.load_after_store stateL _ _ stateN hstN,
                  hcap_pc.stored stateL stateN _ _ _ _ hstN,
                  hsfL.store_local true false u64Ty ⟨initial.nextId + 1, 0⟩ _ stateN (by dsimp; omega) hstN⟩
            · -- op > 127: non-PUSH -> pc += 1
              rw [pre_bind_eq (prim_scalar_eval (scalar_cmp_eval
                (scalar_ref_local_eval (scalarEnv_of_env (by env_here)) (u8_scalar_valid (code pc).isLt))
                (scalar_ref_const_eval hv127)
                (show Scalar.Comparison.le.eval (code pc).toNat (127 : Int) = false by simp [Scalar.Comparison.eval]; omega))) (bool_val_hasType false)]
              rw [pre_jump_eq (ref_local_eval (env_set_self ..) (bool_val_valid false))]
              refine blockPost_hit (bool_val_hasType false) ?_
              rw [pre_branch_false_eq (ref_local_eval (env_set_self ..) (bool_val_valid false))]
              have hnext64 : pc + 1 < 2 ^ 64 := by omega
              have hv1 : (Scalar.Value.int false 64 1).valid = true := size_scalar_valid (n := 1) (by omega)
              rw [pre_bind_eq (prim_load_eval (ref_local_eval (by env_use he14) rfl) hld_pc) (size_val_hasType hpc64)]
              have hi62 : Scalar.integer false 64 (Scalar.Arithmetic.add.eval pc (1 : Int)) .unchecked = .ok (.int false 64 ↑(pc + 1)) := by
                change Scalar.integer false 64 ((pc : Int) + 1) .unchecked = _
                rw [show (pc : Int) + 1 = ↑(pc + 1) by omega]
                exact integer_unchecked_of_valid (size_scalar_valid hnext64)
              rw [pre_bind_eq (prim_scalar_eval (scalar_arith_eval
                (scalar_ref_local_eval (scalarEnv_of_env (env_set_self ..)) (size_scalar_valid hpc64))
                (scalar_ref_const_eval hv1) hi62)) (size_val_hasType hnext64)]
              refine with_root_store hsfL.valid hcap_pc (size_val_hasType hnext64) (layout := ⟨8, 8⟩) rfl (by decide) fun stateN hstN => ?_
              rw [pre_bind_eq (prim_store_eval (ref_local_eval (by env_use he14) rfl)
                (ref_local_eval (env_set_self ..) (size_val_valid hnext64)) hstN) unit_val_hasType]
              rw [pre_jump_eq (ref_const_eval unit_val_valid)]
              refine blockPost_hit unit_val_hasType ?_
              rw [pre_jump_eq (ref_const_eval unit_val_valid)]
              refine blockPost_hit unit_val_hasType ?_
              rw [pre_repeat_eq]
              refine loopPost_repeat_hit ?_
              refine ⟨rfl, pc + 1, by omega, htgt_lt,
                (from_other_step code len target pc hlt hhit (by omega)).trans hspec,
                by env_use he1, by env_use he2, by env_use he6, by env_use he14,
                (Memory.load_other_after_store stateL true false u64Ty ⟨initial.nextId + 1, 0⟩ _ stateN false false codePtrTy ⟨initial.nextId, 0⟩ hstN (by dsimp; omega)).trans hld_code,
                Memory.load_after_store stateL _ _ stateN hstN,
                hcap_pc.stored stateL stateN _ _ _ _ hstN,
                hsfL.store_local true false u64Ty ⟨initial.nextId + 1, 0⟩ _ stateN (by dsimp; omega) hstN⟩
          · -- op < 96: short-circuit false -> non-PUSH -> pc += 1
            rw [pre_bind_eq (prim_scalar_eval (scalar_cmp_eval
              (scalar_ref_local_eval (scalarEnv_of_env (by env_here)) (u8_scalar_valid (code pc).isLt))
              (scalar_ref_const_eval hv96)
              (show Scalar.Comparison.ge.eval (code pc).toNat (96 : Int) = false by simp [Scalar.Comparison.eval]; omega))) (bool_val_hasType false)]
            rw [pre_block_eq]
            rw [pre_branch_false_eq (ref_local_eval (env_set_self ..) (bool_val_valid false))]
            rw [pre_jump_eq (ref_const_eval (bool_val_valid false))]
            refine blockPost_hit (bool_val_hasType false) ?_
            rw [pre_branch_false_eq (ref_local_eval (env_set_self ..) (bool_val_valid false))]
            have hnext64 : pc + 1 < 2 ^ 64 := by omega
            have hv1 : (Scalar.Value.int false 64 1).valid = true := size_scalar_valid (n := 1) (by omega)
            rw [pre_bind_eq (prim_load_eval (ref_local_eval (by env_use he14) rfl) hld_pc) (size_val_hasType hpc64)]
            have hi62 : Scalar.integer false 64 (Scalar.Arithmetic.add.eval pc (1 : Int)) .unchecked = .ok (.int false 64 ↑(pc + 1)) := by
              change Scalar.integer false 64 ((pc : Int) + 1) .unchecked = _
              rw [show (pc : Int) + 1 = ↑(pc + 1) by omega]
              exact integer_unchecked_of_valid (size_scalar_valid hnext64)
            rw [pre_bind_eq (prim_scalar_eval (scalar_arith_eval
              (scalar_ref_local_eval (scalarEnv_of_env (env_set_self ..)) (size_scalar_valid hpc64))
              (scalar_ref_const_eval hv1) hi62)) (size_val_hasType hnext64)]
            refine with_root_store hsfL.valid hcap_pc (size_val_hasType hnext64) (layout := ⟨8, 8⟩) rfl (by decide) fun stateN hstN => ?_
            rw [pre_bind_eq (prim_store_eval (ref_local_eval (by env_use he14) rfl)
              (ref_local_eval (env_set_self ..) (size_val_valid hnext64)) hstN) unit_val_hasType]
            rw [pre_jump_eq (ref_const_eval unit_val_valid)]
            refine blockPost_hit unit_val_hasType ?_
            rw [pre_jump_eq (ref_const_eval unit_val_valid)]
            refine blockPost_hit unit_val_hasType ?_
            rw [pre_repeat_eq]
            refine loopPost_repeat_hit ?_
            refine ⟨rfl, pc + 1, by omega, htgt_lt,
              (from_other_step code len target pc hlt hhit (by omega)).trans hspec,
              by env_use he1, by env_use he2, by env_use he6, by env_use he14,
              (Memory.load_other_after_store stateL true false u64Ty ⟨initial.nextId + 1, 0⟩ _ stateN false false codePtrTy ⟨initial.nextId, 0⟩ hstN (by dsimp; omega)).trans hld_code,
              Memory.load_after_store stateL _ _ stateN hstN,
              hcap_pc.stored stateL stateN _ _ _ _ hstN,
              hsfL.store_local true false u64Ty ⟨initial.nextId + 1, 0⟩ _ stateN (by dsimp; omega) hstN⟩
      · -- Exit loop: pc ≥ len -> jump 16 -> jump 3 false -> return false
        rw [pre_bind_eq (prim_scalar_eval (scalar_cmp_eval
          (scalar_ref_local_eval (scalarEnv_of_env (by env_here)) (size_scalar_valid hpc64))
          (scalar_ref_local_eval (scalarEnv_of_env (env_set_self ..)) (size_scalar_valid hlen64))
          (show Scalar.Comparison.lt.eval pc len = false by simp [Scalar.Comparison.eval, hlt]))) (bool_val_hasType false)]
        rw [pre_branch_false_eq (ref_local_eval (env_set_self ..) (bool_val_valid false))]
        rw [pre_jump_eq (ref_const_eval unit_val_valid)]
        refine blockPost_miss (by decide) (loopPost_jump_miss (by decide) ?_)
        refine blockPost_hit unit_val_hasType ?_
        rw [pre_jump_eq (ref_const_eval (bool_val_valid false))]
        refine blockPost_hit (bool_val_hasType false) ?_
        rw [pre_ret_eq (ref_local_eval (env_set_self ..) (bool_val_valid false))]
        refine finishPost_ret (bool_val_hasType false) ⟨?_, hsfL.cleanup_valid, hsfL.cleanup_heap⟩
        rw [← hspec, from_end code len target pc hlt]

/-- Soundness corollary across every finite fuel budget for `isValidJumpdestBytes`. -/
theorem is_valid_jumpdest_bytes_safe
    (initial : State) (address : Address) (len target : Nat)
    (code : Nat → BitVec 8)
    (valid : initial.valid = true)
    (cap : ReadView.Represents initial (codeView address len) (fun i => byteVal (code i)))
    (hlen : len < addressLimit) (htarget : target < addressLimit)
    (fuel : Nat) :
    Verify.Observes (Completed initial code len target) (Exhausted initial)
      (Generated.fn_is_valid_jumpdest_bytes.runFuel fuel (arguments address len target) initial) :=
  Verify.sound _ _ _ _
    (is_valid_jumpdest_bytes_contract initial address len target code valid cap hlen htarget)
    initial rfl fuel

end GuillotineZean.BytecodeJumpdest
