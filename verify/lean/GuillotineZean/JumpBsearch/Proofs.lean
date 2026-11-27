/-
  GuillotineZean.JumpBsearch.Proofs

  Direct Zig 0.17.1 AIR -> Lean 4 formal proof for Guillotine's jump-table
  binary search kernel `verified_ops.bsearchJumpTableU32`:
    - Memory safety across all valid `u32` jump-table arrays and lengths
    - Overflow-free midpoint computation `lo + ((hi - lo) >> 1)` (`lo ≤ mid < hi`)
    - Exact soundness & completeness on strictly sorted jump tables:
        result = true  ↔  ∃ k < len, pcs k = target
    - Read-only heap framing: caller heap is completely unchanged on both
      normal return and modeled stack exhaustion (`outOfMemory`)
    - Soundness for every finite fuel budget (`Verify.Observes`)
-/
import GuillotineZean.JumpBsearch.Generated
import GuillotineZean.LoopHelpers
import Compiler.ZigAir.MemoryReadView

namespace GuillotineZean.JumpBsearch
open Compiler.ZigAir Compiler.ZigAir.Memory Compiler.ZigAir.MemoryAir MemoryAir.Verify
open Control.Verification Std.WP GuillotineZean.MemoryHelpers GuillotineZean.LoopHelpers

set_option maxRecDepth 4096

abbrev u32Ty : Memory.Ty := .scalar (.int false 32)
abbrev u32PtrTy : Memory.Ty := .pointer false true u32Ty
abbrev u32Val (n : BitVec 32) : Memory.Value := .scalar (.int false 32 n.toNat)
abbrev sizeVal (n : Nat) : Memory.Value := .scalar (.int false 64 n)

abbrev u32View (address : Address) (length : Nat) : ReadView :=
  ⟨u32Ty, ⟨4, 4⟩, rfl, by decide, address, length⟩

def StrictlySorted (pcs : Nat → BitVec 32) (len : Nat) : Prop :=
  ∀ i j, i < j → j < len → (pcs i).toNat < (pcs j).toNat

def InTable (pcs : Nat → BitVec 32) (len : Nat) (target : BitVec 32) : Prop :=
  ∃ k, k < len ∧ pcs k = target

def arguments (address : Address) (len : Nat) (target : BitVec 32) : List Memory.Value :=
  [(u32View address len).buffer, sizeVal len, u32Val target]

/-- Loop invariant at loop label `12` of `fn_bsearch_jump_table_u32`:
    - `0 ≤ lo ≤ hi ≤ len` (bounds safety & zero underflow/overflow on `hi - lo`, `mid + 1`)
    - Stack locals (`pcs` at `id0`, `lo` at `id1`, `hi` at `id2`) remain writable & initialized
    - Caller heap is completely read-only (`StackFrame initial state`)
    - Any matching index `k < len` with `pcs k = target` lies inside `[lo, hi)` -/
def loopInvariant (initial : State) (address : Address) (len : Nat)
    (pcs : Nat → BitVec 32) (target : BitVec 32) : Invariants :=
  fun label env state => label = 12 ∧ ∃ lo hi : Nat,
    lo ≤ hi ∧ hi ≤ len ∧
    (∀ k < len, pcs k = target → lo ≤ k ∧ k < hi) ∧
    env 2 = some (u32Val target) ∧
    env 6 = some (.pointer (.pointer false false u32PtrTy) ⟨initial.nextId, 0⟩) ∧
    env 7 = some (.pointer (.pointer true false u64Ty) ⟨initial.nextId + 1, 0⟩) ∧
    env 9 = some (.pointer (.pointer true false u64Ty) ⟨initial.nextId + 2, 0⟩) ∧
    Memory.load state (.pointer (.pointer false false u32PtrTy) ⟨initial.nextId, 0⟩) = .ok (u32View address len).buffer ∧
    Memory.load state (.pointer (.pointer true false u64Ty) ⟨initial.nextId + 1, 0⟩) = .ok (sizeVal lo) ∧
    Memory.load state (.pointer (.pointer true false u64Ty) ⟨initial.nextId + 2, 0⟩) = .ok (sizeVal hi) ∧
    Memory.RootWritable state u64Ty (initial.nextId + 1) ∧
    Memory.RootWritable state u64Ty (initial.nextId + 2) ∧
    StackFrame initial state

def Completed (initial : State) (pcs : Nat → BitVec 32) (len : Nat) (target : BitVec 32)
    (result : Memory.Value) (after : State) : Prop :=
  (∃ b : Bool, result = .scalar (.bool b) ∧ (b = true ↔ InTable pcs len target)) ∧
  after.valid = true ∧ after.heap = initial.heap

def Exhausted (initial : State) (fault : Fault) (after : State) : Prop :=
  fault = .outOfMemory ∧ after.valid = true ∧ after.heap = initial.heap

private theorem sorted_left_excl (pcs : Nat → BitVec 32) (len lo hi mid : Nat) (target : BitVec 32)
    (hsorted : StrictlySorted pcs len) (hhi : hi ≤ len) (hmid_lo : lo ≤ mid) (hmid_hi : mid < hi)
    (hinv : ∀ k < len, pcs k = target → lo ≤ k ∧ k < hi)
    (hlt : (pcs mid).toNat < target.toNat) :
    ∀ k < len, pcs k = target → mid + 1 ≤ k ∧ k < hi := by
  intro k hk heq
  have ⟨hlo_k, hk_hi⟩ := hinv k hk heq
  refine ⟨?_, hk_hi⟩
  by_cases hkm : k ≤ mid
  · rcases Nat.eq_or_lt_of_le hkm with rfl | hlt_km
    · rw [heq] at hlt; omega
    · have := hsorted k mid hlt_km (by omega)
      rw [heq] at this; omega
  · omega

private theorem sorted_right_excl (pcs : Nat → BitVec 32) (len lo hi mid : Nat) (target : BitVec 32)
    (hsorted : StrictlySorted pcs len)
    (hinv : ∀ k < len, pcs k = target → lo ≤ k ∧ k < hi)
    (hge : ¬ ((pcs mid).toNat < target.toNat)) (hne : (pcs mid).toNat ≠ target.toNat) :
    ∀ k < len, pcs k = target → lo ≤ k ∧ k < mid := by
  intro k hk heq
  have ⟨hlo_k, hk_hi⟩ := hinv k hk heq
  refine ⟨hlo_k, ?_⟩
  by_cases hmk : mid ≤ k
  · rcases Nat.eq_or_lt_of_le hmk with rfl | hlt_mk
    · rw [heq] at hne; exact absurd rfl hne
    · have := hsorted mid k hlt_mk hk
      rw [heq] at this; omega
  · omega

private theorem u32_scalar_valid (n : BitVec 32) : (Scalar.Value.int false 32 n.toNat).valid = true :=
  Scalar.unsigned_nat_valid n.toNat 32 n.isLt

private theorem u32_val_valid (n : BitVec 32) : (u32Val n).valid = true :=
  mem_scalar_valid (u32_scalar_valid n)

private theorem u32_val_hasType (n : BitVec 32) : (u32Val n).hasType u32Ty = true :=
  mem_scalar_hasType (scalar_hasType_of_valid (u32_scalar_valid n))

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

/-- Direct Zig AIR WP contract for `verified_ops.bsearchJumpTableU32`:
    for any strictly sorted `u32` jump table in valid memory, binary search
    never faults (except modeled stack OOM), preserves the caller heap, and
    returns `true` iff `target` appears in `pcs[0..len)`. -/
theorem bsearch_jump_table_u32_contract
    (initial : State) (address : Address) (len : Nat)
    (pcs : Nat → BitVec 32) (target : BitVec 32)
    (valid : initial.valid = true)
    (cap : ReadView.Represents initial (u32View address len) (fun i => u32Val (pcs i)))
    (hsorted : StrictlySorted pcs len)
    (hwidth : len < addressLimit) :
    Triple (Verify.Invocation.mk Generated.fn_bsearch_jump_table_u32
      (arguments address len target)
      (loopInvariant initial address len pcs target))
      (fun before => before = initial)
      (Completed initial pcs len target)
      (Exhausted initial) := by
  have hlen64 : len < 2 ^ 64 := by unfold addressLimit at hwidth; omega
  have ht_buf : (u32View address len).buffer.hasType u32PtrTy = true := rfl
  have hv_buf : (u32View address len).buffer.valid = true := rfl
  have ht_len : (sizeVal len).hasType u64Ty = true := size_val_hasType hlen64
  have ht_tgt : (u32Val target).hasType u32Ty = true := u32_val_hasType target
  have hacc : Generated.fn_bsearch_jump_table_u32.accepts (arguments address len target) initial = true := by
    simp only [Program.accepts, Generated.fn_bsearch_jump_table_u32, arguments, valid, List.length_cons, List.length_nil,
      List.zip_cons_cons, List.zip_nil_right, List.all_cons, List.all_nil, Bool.and_true, decide_true, Bool.true_and]
    exact (Bool.and_eq_true _ _).mpr ⟨ht_buf, (Bool.and_eq_true _ _).mpr ⟨ht_len, ht_tgt⟩⟩
  refine triple_of_pre hacc ?_
  dsimp only [Generated.fn_bsearch_jump_table_u32, arguments]
  -- Bind arguments 0, 1, 2
  rw [pre_bind_eq (prim_arg_eval (i := 0) (args := [(u32View address len).buffer, sizeVal len, u32Val target]) rfl) ht_buf]
  rw [pre_bind_eq (prim_arg_eval (i := 1) (args := [(u32View address len).buffer, sizeVal len, u32Val target]) rfl) ht_len]
  rw [pre_bind_eq (prim_arg_eval (i := 2) (args := [(u32View address len).buffer, sizeVal len, u32Val target]) rfl) ht_tgt]
  -- Block 3: return block
  rw [pre_block_eq]
  -- Alloc 4 (pcs local slot, id = initial.nextId)
  refine pre_bind_alloc valid (layout := ⟨8, 8⟩) rfl
    ⟨rfl, (StackFrame.refl initial valid).cleanup_valid, (StackFrame.refl initial valid).cleanup_heap⟩ ?_
  intro s4 halloc4 hvalid4 hsf4
  have hnid4 : s4.nextId = initial.nextId + 1 := alloc_nextId halloc4
  have hcap4_0 : Memory.RootWritable s4 u32PtrTy initial.nextId := Memory.RootWritable.allocated initial s4 _ _ halloc4
  refine with_fresh_store (child := u32PtrTy) (layout := ⟨8, 8⟩) rfl (by decide) hv_buf rfl halloc4 fun s5 hst5 hvalid5 hsf5 hld5 => ?_
  have hnid5 : s5.nextId = initial.nextId + 1 := (store_preserves_nextId s4 s5 _ _ hst5).trans hnid4
  have hcap5 : Memory.RootWritable s5 u32PtrTy initial.nextId := hcap4_0.stored s4 s5 _ _ _ _ hst5
  rw [pre_bind_eq (prim_store_eval (ref_local_eval (env_set_self ..) rfl)
    (ref_local_eval (by rw [env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_self]) hv_buf) hst5) unit_val_hasType]
  -- Cast 6: pointerCast to const pointer to u32PtrTy
  have hcast6 := root_cast_const_ok hvalid5 (layout := ⟨8, 8⟩) rfl (by decide) hcap5
  rw [pre_bind_eq (prim_pointerCast_eval (ref_local_eval (by rw [env_set_ne _ _ _ _ (by decide), env_set_self]) rfl) hcast6) rfl]
  -- Alloc 7 (lo local slot, id = initial.nextId + 1)
  refine pre_bind_alloc hvalid5 (layout := ⟨8, 8⟩) rfl ⟨rfl, hsf5.cleanup_valid, hsf5.cleanup_heap⟩ ?_
  intro s7 halloc7 hvalid7 hsf7
  have hnid7 : s7.nextId = initial.nextId + 2 := by rw [alloc_nextId halloc7, hnid5]
  have hcap7_lo : Memory.RootWritable s7 u64Ty (initial.nextId + 1) := by
    have := Memory.RootWritable.allocated s5 s7 _ _ halloc7; rwa [hnid5] at this
  have hv0 : (sizeVal 0).valid = true := size_val_valid (by omega)
  refine with_fresh_store (child := u64Ty) (layout := ⟨8, 8⟩) rfl (by decide) hv0 rfl halloc7 fun s8 hst8 hvalid8 hsf8_step hld8 => ?_
  rw [hnid5] at hst8 hld8 ⊢
  have hsf8 : StackFrame initial s8 := hsf5.trans hsf8_step
  have hnid8 : s8.nextId = initial.nextId + 2 := (store_preserves_nextId s7 s8 _ _ hst8).trans hnid7
  have hcap8_lo : Memory.RootWritable s8 u64Ty (initial.nextId + 1) := hcap7_lo.stored s7 s8 _ _ _ _ hst8
  have hld_pcs8 : Memory.load s8 (.pointer (.pointer false false u32PtrTy) ⟨initial.nextId, 0⟩) = .ok (u32View address len).buffer := by
    have h1 := (Memory.load_after_allocate s5 u64Ty _ s7 false false u32PtrTy ⟨initial.nextId, 0⟩ halloc7 (by dsimp; rw [hnid5]; omega)).trans (root_load_const_of_mut hld5)
    exact (Memory.load_other_after_store s7 true false u64Ty ⟨initial.nextId + 1, 0⟩ (sizeVal 0) s8 false false u32PtrTy ⟨initial.nextId, 0⟩ hst8 (by dsimp; omega)).trans h1
  have hv0' : (Value.scalar (.int false 64 0)).valid = true := hv0
  have hst8' : Memory.store s7 (.pointer (.pointer true false u64Ty) ⟨initial.nextId + 1, 0⟩) (.scalar (.int false 64 0)) = .ok s8 := hst8
  rw [pre_bind_eq (prim_store_eval (ref_local_eval (env_set_self ..) rfl) (ref_const_eval hv0') hst8') unit_val_hasType]
  -- Alloc 9 (hi local slot, id = initial.nextId + 2)
  refine pre_bind_alloc hvalid8 (layout := ⟨8, 8⟩) rfl ⟨rfl, hsf8.cleanup_valid, hsf8.cleanup_heap⟩ ?_
  intro s9 halloc9 hvalid9 hsf9
  have hcap9_lo : Memory.RootWritable s9 u64Ty (initial.nextId + 1) := hcap8_lo.after_allocate s8 s9 u64Ty u64Ty (initial.nextId + 1) _ hvalid8 halloc9
  have hcap9_hi : Memory.RootWritable s9 u64Ty (initial.nextId + 2) := by
    have := Memory.RootWritable.allocated s8 s9 _ _ halloc9; rwa [hnid8] at this
  refine with_fresh_store (child := u64Ty) (layout := ⟨8, 8⟩) rfl (by decide) (size_val_valid hlen64) rfl halloc9 fun s10 hst10 hvalid10 hsf10_step hld10 => ?_
  rw [hnid8] at hst10 hld10 ⊢
  have hsf10 : StackFrame initial s10 := hsf8.trans hsf10_step
  have hcap10_lo : Memory.RootWritable s10 u64Ty (initial.nextId + 1) := hcap9_lo.stored s9 s10 _ _ _ _ hst10
  have hcap10_hi : Memory.RootWritable s10 u64Ty (initial.nextId + 2) := hcap9_hi.stored s9 s10 _ _ _ _ hst10
  have hld_pcs10 : Memory.load s10 (.pointer (.pointer false false u32PtrTy) ⟨initial.nextId, 0⟩) = .ok (u32View address len).buffer := by
    have h1 := (Memory.load_after_allocate s8 u64Ty _ s9 false false u32PtrTy ⟨initial.nextId, 0⟩ halloc9 (by dsimp; rw [hnid8]; omega)).trans hld_pcs8
    exact (Memory.load_other_after_store s9 true false u64Ty ⟨initial.nextId + 2, 0⟩ (sizeVal len) s10 false false u32PtrTy ⟨initial.nextId, 0⟩ hst10 (by dsimp; omega)).trans h1
  have hld_lo10 : Memory.load s10 (.pointer (.pointer true false u64Ty) ⟨initial.nextId + 1, 0⟩) = .ok (sizeVal 0) := by
    have h1 := (Memory.load_after_allocate s8 u64Ty _ s9 true false u64Ty ⟨initial.nextId + 1, 0⟩ halloc9 (by dsimp; rw [hnid8]; omega)).trans hld8
    exact (Memory.load_other_after_store s9 true false u64Ty ⟨initial.nextId + 2, 0⟩ (sizeVal len) s10 true false u64Ty ⟨initial.nextId + 1, 0⟩ hst10 (by dsimp; omega)).trans h1
  rw [pre_bind_eq (prim_store_eval (ref_local_eval (env_set_self ..) rfl)
    (ref_local_eval (by rw [env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide),
                            env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide),
                            env_set_ne _ _ _ _ (by decide), env_set_self]) (size_val_valid hlen64)) hst10) unit_val_hasType]
  -- Block 11 -> Loop 12
  rw [pre_block_eq]
  rw [pre_loop_eq]
  constructor
  · -- Loop entry satisfies invariant with lo = 0, hi = len
    refine ⟨rfl, 0, len, Nat.zero_le len, Nat.le_refl len, fun k hk _ => ⟨Nat.zero_le k, hk⟩, ?_, ?_, ?_, ?_, hld_pcs10, hld_lo10, hld10, hcap10_lo, hcap10_hi, hsf10⟩
    · env_here
    · env_here
    · env_here
    · env_here
  · -- Loop body preservation
    rintro envL stateL ⟨_, lo, hi, hlo_hi, hhi_len, hinv, he2, he6, he7, he9, hld_pcs, hld_lo, hld_hi, hcap_lo, hcap_hi, hsfL⟩
    have hlo64 : lo < 2 ^ 64 := by omega
    have hhi64 : hi < 2 ^ 64 := by omega
    have hcapL : ReadView.Represents stateL (u32View address len) (fun i => u32Val (pcs i)) := cap.stack hsfL
    -- Block 13 (loop step body)
    rw [pre_block_eq]
    rw [pre_bind_eq (prim_load_eval (ref_local_eval he7 rfl) hld_lo) (size_val_hasType hlo64)]
    rw [pre_bind_eq (prim_load_eval (ref_local_eval (by rw [env_set_ne _ _ _ _ (by decide), he9]) rfl) hld_hi) (size_val_hasType hhi64)]
    rw [pre_bind_eq (prim_scalar_eval (scalar_bitcast_u64_eval hlo64
      (scalar_ref_local_eval (scalarEnv_of_env (by rw [env_set_ne _ _ _ _ (by decide), env_set_self])) (size_scalar_valid hlo64)))) (size_val_hasType hlo64)]
    rw [pre_bind_eq (prim_scalar_eval (scalar_bitcast_u64_eval hhi64
      (scalar_ref_local_eval (scalarEnv_of_env (by rw [env_set_ne _ _ _ _ (by decide), env_set_self])) (size_scalar_valid hhi64)))) (size_val_hasType hhi64)]
    by_cases hlt : lo < hi
    · -- Continue loop: lo < hi
      rw [pre_bind_eq (prim_scalar_eval (scalar_cmp_eval
        (scalar_ref_local_eval (scalarEnv_of_env (by rw [env_set_ne _ _ _ _ (by decide), env_set_self])) (size_scalar_valid hlo64))
        (scalar_ref_local_eval (scalarEnv_of_env (env_set_self ..)) (size_scalar_valid hhi64))
        (show Scalar.Comparison.lt.eval lo hi = true by simp [Scalar.Comparison.eval, hlt]))) (bool_val_hasType true)]
      rw [pre_branch_true_eq (ref_local_eval (env_set_self ..) (bool_val_valid true))]
      -- Reload lo, hi, lo
      rw [pre_bind_eq (prim_load_eval (ref_local_eval
        (by rw [env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), he7]) rfl) hld_lo) (size_val_hasType hlo64)]
      rw [pre_bind_eq (prim_load_eval (ref_local_eval
        (by rw [env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), he9]) rfl) hld_hi) (size_val_hasType hhi64)]
      rw [pre_bind_eq (prim_load_eval (ref_local_eval
        (by rw [env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), he7]) rfl) hld_lo) (size_val_hasType hlo64)]
      -- Compute diff = hi - lo, half = diff >> 1, mid = lo + half
      have hdiff64 : hi - lo < 2 ^ 64 := by omega
      have hhalf64 : (hi - lo) / 2 < 2 ^ 64 := by omega
      let mid := lo + (hi - lo) / 2
      have hmid_lo : lo ≤ mid := by omega
      have hmid_hi : mid < hi := by omega
      have hmid_len : mid < len := by omega
      have hmid64 : mid < 2 ^ 64 := by omega
      have hi_diff : Scalar.integer false 64 (Scalar.Arithmetic.sub.eval hi lo) .unchecked = .ok (.int false 64 ↑(hi - lo)) := by
        change Scalar.integer false 64 ((hi : Int) - lo) .unchecked = _
        rw [show (hi : Int) - lo = ↑(hi - lo) by omega]
        exact integer_unchecked_of_valid (size_scalar_valid hdiff64)
      rw [pre_bind_eq (prim_scalar_eval (scalar_arith_eval
        (scalar_ref_local_eval (scalarEnv_of_env (by rw [env_set_ne _ _ _ _ (by decide), env_set_self])) (size_scalar_valid hhi64))
        (scalar_ref_local_eval (scalarEnv_of_env (env_set_self ..)) (size_scalar_valid hlo64))
        hi_diff)) (size_val_hasType hdiff64)]
      rw [pre_bind_eq (prim_scalar_eval (scalar_shiftRight64_one_eval
        (scalar_ref_local_eval (scalarEnv_of_env (env_set_self ..)) (size_scalar_valid hdiff64)))) (size_val_hasType hhalf64)]
      have hi_mid : Scalar.integer false 64 (Scalar.Arithmetic.add.eval lo ↑((hi - lo) / 2)) .unchecked = .ok (.int false 64 mid) := by
        change Scalar.integer false 64 ((lo : Int) + ↑((hi - lo) / 2)) .unchecked = _
        rw [show (lo : Int) + ↑((hi - lo) / 2) = ↑mid by omega]
        exact integer_unchecked_of_valid (size_scalar_valid hmid64)
      rw [pre_bind_eq (prim_scalar_eval (scalar_arith_eval
        (scalar_ref_local_eval (scalarEnv_of_env (by env_here)) (size_scalar_valid hlo64))
        (scalar_ref_local_eval (scalarEnv_of_env (env_set_self ..)) (size_scalar_valid hhalf64))
        hi_mid)) (size_val_hasType hmid64)]
      -- Load pcs[mid]
      rw [pre_bind_eq (prim_load_eval (ref_local_eval
        (by rw [env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide),
                env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide),
                env_set_ne _ _ _ _ (by decide), he6]) rfl) hld_pcs) ht_buf]
      have helem := hcapL.element mid hmid_len
      have hld_mid := hcapL.read mid hmid_len
      rw [pre_bind_eq (prim_elementPointer_eval (ref_local_eval (env_set_self ..) hv_buf)
        (ref_natural_local (by rw [env_set_ne _ _ _ _ (by decide), env_set_self]) hmid64) helem) rfl]
      rw [pre_bind_eq (prim_load_eval (ref_local_eval (env_set_self ..) rfl) hld_mid) (u32_val_hasType (pcs mid))]
      -- Block 29: if pcs[mid] == target return true
      rw [pre_block_eq]
      by_cases heq : (pcs mid).toNat = target.toNat
      · rw [pre_bind_eq (prim_scalar_eval (scalar_cmp_eval
          (scalar_ref_local_eval (scalarEnv_of_env (env_set_self ..)) (u32_scalar_valid (pcs mid)))
          (scalar_ref_local_eval (scalarEnv_of_env (by
            rw [env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide),
                env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide),
                env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide),
                env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), he2])) (u32_scalar_valid target))
          (show Scalar.Comparison.eq.eval (pcs mid).toNat target.toNat = true by simp [Scalar.Comparison.eval, heq]))) (bool_val_hasType true)]
        rw [pre_branch_true_eq (ref_local_eval (env_set_self ..) (bool_val_valid true))]
        rw [pre_jump_eq (ref_const_eval (bool_val_valid true))]
        refine blockPost_miss (by decide) (blockPost_miss (by decide) (loopPost_jump_miss (by decide) (blockPost_miss (by decide) ?_)))
        refine blockPost_hit (bool_val_hasType true) ?_
        rw [pre_ret_eq (ref_local_eval (env_set_self ..) (bool_val_valid true))]
        refine finishPost_ret (bool_val_hasType true) ⟨⟨true, rfl, ⟨fun _ => ⟨mid, hmid_len, BitVec.eq_of_toNat_eq heq⟩, fun _ => rfl⟩⟩, hsfL.cleanup_valid, hsfL.cleanup_heap⟩
      · rw [pre_bind_eq (prim_scalar_eval (scalar_cmp_eval
          (scalar_ref_local_eval (scalarEnv_of_env (env_set_self ..)) (u32_scalar_valid (pcs mid)))
          (scalar_ref_local_eval (scalarEnv_of_env (by
            rw [env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide),
                env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide),
                env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide),
                env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), he2])) (u32_scalar_valid target))
          (show Scalar.Comparison.eq.eval (pcs mid).toNat target.toNat = false by simp [Scalar.Comparison.eval, Int.ofNat_inj, heq]))) (bool_val_hasType false)]
        rw [pre_branch_false_eq (ref_local_eval (env_set_self ..) (bool_val_valid false))]
        rw [pre_jump_eq (ref_const_eval unit_val_valid)]
        refine blockPost_hit unit_val_hasType ?_
        -- Block 34: if pcs[mid] < target { lo = mid + 1 } else { hi = mid }
        rw [pre_block_eq]
        by_cases hmid_lt : (pcs mid).toNat < target.toNat
        · rw [pre_bind_eq (prim_scalar_eval (scalar_cmp_eval
            (scalar_ref_local_eval (scalarEnv_of_env (by rw [env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_self])) (u32_scalar_valid (pcs mid)))
            (scalar_ref_local_eval (scalarEnv_of_env (by
              rw [env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide),
                  env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide),
                  env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide),
                  env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), he2])) (u32_scalar_valid target))
            (show Scalar.Comparison.lt.eval (pcs mid).toNat target.toNat = true by simp [Scalar.Comparison.eval, hmid_lt]))) (bool_val_hasType true)]
          rw [pre_branch_true_eq (ref_local_eval (env_set_self ..) (bool_val_valid true))]
          have hmp1_64 : mid + 1 < 2 ^ 64 := by omega
          have hv1 : (Scalar.Value.int false 64 1).valid = true := size_scalar_valid (n := 1) (by omega)
          have hi_mp1 : Scalar.integer false 64 (Scalar.Arithmetic.add.eval mid (1 : Int)) .unchecked = .ok (.int false 64 ↑(mid + 1)) := by
            change Scalar.integer false 64 ((mid : Int) + 1) .unchecked = _
            rw [show (mid : Int) + 1 = ↑(mid + 1) by omega]
            exact integer_unchecked_of_valid (size_scalar_valid hmp1_64)
          rw [pre_bind_eq (prim_scalar_eval (scalar_arith_eval
            (scalar_ref_local_eval (scalarEnv_of_env (by env_here)) (size_scalar_valid hmid64))
            (scalar_ref_const_eval hv1)
            hi_mp1)) (size_val_hasType hmp1_64)]
          refine with_root_store hsfL.valid hcap_lo (size_val_hasType hmp1_64) (layout := ⟨8, 8⟩) rfl (by decide) fun stateN hstN => ?_
          rw [pre_bind_eq (prim_store_eval
            (ref_local_eval (by env_use he7) rfl)
            (ref_local_eval (env_set_self ..) (size_val_valid hmp1_64)) hstN) unit_val_hasType]
          rw [pre_jump_eq (ref_const_eval unit_val_valid)]
          refine blockPost_hit unit_val_hasType ?_
          rw [pre_jump_eq (ref_const_eval unit_val_valid)]
          refine blockPost_hit unit_val_hasType ?_
          -- Repeat loop 12 with lo' = mid + 1, hi' = hi
          rw [pre_repeat_eq]
          refine loopPost_repeat_hit ?_
          refine ⟨rfl, mid + 1, hi, by omega, hhi_len,
            sorted_left_excl pcs len lo hi mid target hsorted hhi_len hmid_lo hmid_hi hinv hmid_lt,
            by env_use he2, by env_use he6, by env_use he7, by env_use he9,
            (Memory.load_other_after_store stateL true false u64Ty ⟨initial.nextId + 1, 0⟩ _ stateN false false u32PtrTy ⟨initial.nextId, 0⟩ hstN (by dsimp; omega)).trans hld_pcs,
            Memory.load_after_store stateL _ _ stateN hstN,
            (Memory.load_other_after_store stateL true false u64Ty ⟨initial.nextId + 1, 0⟩ _ stateN true false u64Ty ⟨initial.nextId + 2, 0⟩ hstN (by dsimp; omega)).trans hld_hi,
            hcap_lo.stored stateL stateN _ _ _ _ hstN,
            hcap_hi.stored stateL stateN _ _ _ _ hstN,
            hsfL.store_local true false u64Ty ⟨initial.nextId + 1, 0⟩ _ stateN (by dsimp; omega) hstN⟩
        · -- pcs[mid] > target -> hi = mid
          rw [pre_bind_eq (prim_scalar_eval (scalar_cmp_eval
            (scalar_ref_local_eval (scalarEnv_of_env (by rw [env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_self])) (u32_scalar_valid (pcs mid)))
            (scalar_ref_local_eval (scalarEnv_of_env (by
              rw [env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide),
                  env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide),
                  env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide),
                  env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), env_set_ne _ _ _ _ (by decide), he2])) (u32_scalar_valid target))
            (show Scalar.Comparison.lt.eval (pcs mid).toNat target.toNat = false by simp [Scalar.Comparison.eval, hmid_lt]))) (bool_val_hasType false)]
          rw [pre_branch_false_eq (ref_local_eval (env_set_self ..) (bool_val_valid false))]
          refine with_root_store hsfL.valid hcap_hi (size_val_hasType hmid64) (layout := ⟨8, 8⟩) rfl (by decide) fun stateN hstN => ?_
          rw [pre_bind_eq (prim_store_eval
            (ref_local_eval (by env_use he9) rfl)
            (ref_local_eval (by env_here) (size_val_valid hmid64)) hstN) unit_val_hasType]
          rw [pre_jump_eq (ref_const_eval unit_val_valid)]
          refine blockPost_hit unit_val_hasType ?_
          rw [pre_jump_eq (ref_const_eval unit_val_valid)]
          refine blockPost_hit unit_val_hasType ?_
          -- Repeat loop 12 with lo' = lo, hi' = mid
          rw [pre_repeat_eq]
          refine loopPost_repeat_hit ?_
          refine ⟨rfl, lo, mid, hmid_lo, by omega,
            sorted_right_excl pcs len lo hi mid target hsorted hinv hmid_lt heq,
            by env_use he2, by env_use he6, by env_use he7, by env_use he9,
            (Memory.load_other_after_store stateL true false u64Ty ⟨initial.nextId + 2, 0⟩ _ stateN false false u32PtrTy ⟨initial.nextId, 0⟩ hstN (by dsimp; omega)).trans hld_pcs,
            (Memory.load_other_after_store stateL true false u64Ty ⟨initial.nextId + 2, 0⟩ _ stateN true false u64Ty ⟨initial.nextId + 1, 0⟩ hstN (by dsimp; omega)).trans hld_lo,
            Memory.load_after_store stateL _ _ stateN hstN,
            hcap_lo.stored stateL stateN _ _ _ _ hstN,
            hcap_hi.stored stateL stateN _ _ _ _ hstN,
            hsfL.store_local true false u64Ty ⟨initial.nextId + 2, 0⟩ _ stateN (by dsimp; omega) hstN⟩
    · -- Exit loop: lo ≥ hi -> jump 11 -> jump 3 false -> return false
      rw [pre_bind_eq (prim_scalar_eval (scalar_cmp_eval
        (scalar_ref_local_eval (scalarEnv_of_env (by rw [env_set_ne _ _ _ _ (by decide), env_set_self])) (size_scalar_valid hlo64))
        (scalar_ref_local_eval (scalarEnv_of_env (env_set_self ..)) (size_scalar_valid hhi64))
        (show Scalar.Comparison.lt.eval lo hi = false by simp [Scalar.Comparison.eval, hlt]))) (bool_val_hasType false)]
      rw [pre_branch_false_eq (ref_local_eval (env_set_self ..) (bool_val_valid false))]
      rw [pre_jump_eq (ref_const_eval unit_val_valid)]
      refine blockPost_miss (by decide) (loopPost_jump_miss (by decide) ?_)
      refine blockPost_hit unit_val_hasType ?_
      rw [pre_jump_eq (ref_const_eval (bool_val_valid false))]
      refine blockPost_hit (bool_val_hasType false) ?_
      rw [pre_ret_eq (ref_local_eval (env_set_self ..) (bool_val_valid false))]
      refine finishPost_ret (bool_val_hasType false) ⟨⟨false, rfl, ⟨fun h => Bool.noConfusion h, fun ⟨k, hk, heq⟩ => by have := hinv k hk heq; omega⟩⟩, hsfL.cleanup_valid, hsfL.cleanup_heap⟩

/-- Soundness corollary across every finite fuel budget for `bsearchJumpTableU32`. -/
theorem bsearch_jump_table_u32_safe
    (initial : State) (address : Address) (len : Nat)
    (pcs : Nat → BitVec 32) (target : BitVec 32)
    (valid : initial.valid = true)
    (cap : ReadView.Represents initial (u32View address len) (fun i => u32Val (pcs i)))
    (hsorted : StrictlySorted pcs len)
    (hwidth : len < addressLimit)
    (fuel : Nat) :
    Verify.Observes (Completed initial pcs len target) (Exhausted initial)
      (Generated.fn_bsearch_jump_table_u32.runFuel fuel (arguments address len target) initial) :=
  Verify.sound _ _ _ _
    (bsearch_jump_table_u32_contract initial address len pcs target valid cap hsorted hwidth)
    initial rfl fuel

end GuillotineZean.JumpBsearch
