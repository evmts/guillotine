/-
  GuillotineZean.MemoryCopy.Proofs

  Direct Zig 0.17.1 AIR -> Lean 4 formal proof for Guillotine's bounded EVM byte
  copy kernel `verified_ops.copyEvmBytes(dst, src, len)`:
    - Memory safety across all valid disjoint byte regions of length `len`
    - Exact copied-byte postcondition (`ByteArray.Represents after target contents`)
    - Source preservation (`ByteArray.Represents after source contents`)
    - Non-overlapping heap framing (`ByteArray.HeapFrame target initial after`)
    - Soundness for every finite fuel budget (`Verify.Observes`)
-/
import GuillotineZean.MemoryCopy.Generated
import GuillotineZean.LoopHelpers
import Compiler.ZigAir.MemoryByteCopyContracts

namespace GuillotineZean.MemoryCopy
open Compiler.ZigAir Compiler.ZigAir.Memory Compiler.ZigAir.MemoryAir MemoryAir.Verify
open Memory.ByteArray Control.Verification Std.WP GuillotineZean.MemoryHelpers GuillotineZean.LoopHelpers

abbrev dstPtrTy : Memory.Ty := .pointer true true u8Ty
abbrev srcPtrTy : Memory.Ty := .pointer false true u8Ty
abbrev sizeVal (n : Nat) : Memory.Value := .scalar (.int false 64 n)

def arguments (target source : View) : List Memory.Value :=
  [target.pointer true true, source.pointer false true, sizeVal source.length]

/-- Borrowed byte-region frame: `current` differs from `before` only by
    invocation-local stack allocations (`id ≥ before.nextId`, `stack = true`)
    and byte writes inside `target`. -/
structure BorrowedByteFrame (target : View) (before current : State) : Prop where
  before_valid : before.valid = true
  valid : current.valid = true
  nextId : before.nextId ≤ current.nextId
  new_stack : ∀ entry ∈ current.heap, before.nextId ≤ entry.1 → entry.2.stack = true
  cleanup_frame : HeapFrame target before (Memory.cleanup before.nextId current)

theorem BorrowedByteFrame.ofStack (target : View) (before current : State)
    (frame : StackFrame before current) : BorrowedByteFrame target before current := by
  refine ⟨frame.initial, frame.valid, frame.nextId, ?_, (HeapFrame.refl target before).heap_eq frame.cleanup_heap⟩
  intro entry hmem hnew
  obtain ⟨locals, hEq, howned⟩ := frame.extended
  rw [hEq, List.mem_append] at hmem
  rcases hmem with hloc | hold
  · exact (howned entry hloc).1
  · have := StackFrame.older before frame.initial entry hold; omega

theorem BorrowedByteFrame.cleanup (frame : BorrowedByteFrame target before current) :
    HeapFrame target before (Memory.cleanup before.nextId current) :=
  frame.cleanup_frame

private theorem heap_filter_replace_new (heap : Heap) (mark id : Nat) (cell : Allocation)
    (hnew : mark ≤ id) (hstack : cell.stack = true)
    (hall : ∀ entry ∈ heap, mark ≤ entry.1 → entry.2.stack = true) :
    (heap.replace id cell).filter (fun e => !e.2.stack || e.1 < mark) =
      heap.filter (fun e => !e.2.stack || e.1 < mark) := by
  induction heap with
  | nil => rfl
  | cons hd tl ih =>
    have htl := ih (fun e he => hall e (List.mem_cons_of_mem _ he))
    simp only [Heap.replace, List.map_cons, List.filter_cons]
    by_cases heq : hd.1 = id
    · have hhd_st : hd.2.stack = true := hall hd (List.mem_cons_self ..) (by omega)
      simp only [heq, ↓reduceIte, hstack, hhd_st, Bool.not_true, Bool.false_or,
        show ¬ (id < mark) by omega, decide_false, Bool.false_eq_true]
      exact htl
    · simp only [heq, ↓reduceIte]
      by_cases hp : (!hd.2.stack || hd.1 < mark) = true
      · simp only [hp, ↓reduceIte]; exact congrArg (List.cons hd) htl
      · simp only [hp]; exact htl

theorem BorrowedByteFrame.store_local (frame : BorrowedByteFrame target before current)
    (write many : Bool) (child : Memory.Ty) (address : Address) (value : Memory.Value)
    (fresh : before.nextId ≤ address.allocation)
    (stored : Memory.store current (.pointer (.pointer write many child) address) value = .ok after) :
    BorrowedByteFrame target before after := by
  obtain ⟨_, _, _, _, origCell, newCells, hptr, _, _, hacc, _, rfl⟩ := store_success current _ _ after stored
  cases hptr
  have hfound := (access_success_region current address _ true origCell hacc).1
  have hst_orig : origCell.stack = true :=
    frame.new_stack (address.allocation, origCell) (Heap.lookup_mem _ _ _ hfound) fresh
  refine ⟨frame.before_valid, store_preserves_valid _ _ _ _ frame.valid stored, frame.nextId, ?_, ?_⟩
  · intro entry hmem hnew
    obtain ⟨old, hold, hrep⟩ := List.mem_map.mp hmem
    by_cases hsame : old.1 = address.allocation
    · simp only [hsame, ↓reduceIte] at hrep; rw [← hrep]; exact hst_orig
    · simp only [hsame, ↓reduceIte] at hrep; rw [← hrep] at hnew ⊢; exact frame.new_stack old hold hnew
  · have hclean_eq : (Memory.cleanup before.nextId { current with heap := current.heap.replace address.allocation { origCell with cells := newCells } }).heap =
        (Memory.cleanup before.nextId current).heap :=
      heap_filter_replace_new current.heap before.nextId address.allocation _ fresh hst_orig frame.new_stack
    exact frame.cleanup_frame.heap_eq hclean_eq

theorem BorrowedByteFrame.store_byte (frame : BorrowedByteFrame target before current)
    (index : Nat) (value : BitVec 8)
    (inside : index < target.length)
    (older : target.address.allocation < before.nextId)
    (stored : Memory.store current (target.pointer true false index) (number value) = .ok after) :
    BorrowedByteFrame target before after := by
  have hva : after.valid = true := store_preserves_valid _ _ _ _ frame.valid stored
  have hnext : after.nextId = current.nextId := store_preserves_nextId current after _ _ stored
  have hnid : before.nextId ≤ after.nextId := by have := frame.nextId; omega
  have hnew_after : ∀ entry ∈ after.heap, before.nextId ≤ entry.1 → entry.2.stack = true := by
    obtain ⟨_, _, _, _, origCell, _, hptr, _, _, _, _, rfl⟩ := store_success current _ _ after stored
    cases hptr
    intro entry hmem hnew
    obtain ⟨old, hold, hrep⟩ := List.mem_map.mp hmem
    by_cases hsame : old.1 = (target.at index).allocation
    · simp only [hsame, ↓reduceIte] at hrep; rw [← hrep] at hnew; dsimp [View.at] at hnew; omega
    · simp only [hsame, ↓reduceIte] at hrep; rw [← hrep] at hnew ⊢; exact frame.new_stack old hold hnew
  refine ⟨frame.before_valid, hva, hnid, hnew_after, ?_⟩
  have hstep : HeapFrame target current after := frame_store inside stored
  refine ⟨fun id apart => ?_, fun child offset write many outside => ?_⟩
  · by_cases hold : id < before.nextId
    · calc (Memory.cleanup before.nextId after).heap.lookup id = after.heap.lookup id :=
            cleanup_lookup_older after before.nextId id hold
        _ = current.heap.lookup id := hstep.allocations id apart
        _ = (Memory.cleanup before.nextId current).heap.lookup id :=
            (cleanup_lookup_older current before.nextId id hold).symm
        _ = before.heap.lookup id := frame.cleanup_frame.allocations id apart
    · have hnone1 : (Memory.cleanup before.nextId after).heap.lookup id = none := by
        cases hlu : after.heap.lookup id with
        | none =>
          cases hcl : (Memory.cleanup before.nextId after).heap.lookup id with
          | none => rfl
          | some c =>
            have hm := List.mem_filter.mp (Heap.lookup_mem _ _ _ hcl)
            have := lookup_of_mem_valid after id c hva hm.1
            rw [hlu] at this; cases this
        | some c =>
          exact cleanup_lookup_stack after before.nextId id c hva hlu
            (hnew_after (id, c) (Heap.lookup_mem _ _ _ hlu) (by omega)) (by omega)
      have hnone2 : before.heap.lookup id = none := by
        cases hlu : before.heap.lookup id with
        | none => rfl
        | some c =>
          have := (valid_lookup before id c frame.before_valid hlu).1; omega
      rw [hnone1, hnone2]
  · calc Memory.load (Memory.cleanup before.nextId after) (.pointer (.pointer write many child) ⟨target.address.allocation, offset⟩)
        = Memory.load after (.pointer (.pointer write many child) ⟨target.address.allocation, offset⟩) :=
          load_eq_of_lookup after (Memory.cleanup before.nextId after) write many child _ (cleanup_lookup_older after before.nextId _ older)
      _ = Memory.load current (.pointer (.pointer write many child) ⟨target.address.allocation, offset⟩) :=
          hstep.outside child offset write many outside
      _ = Memory.load (Memory.cleanup before.nextId current) (.pointer (.pointer write many child) ⟨target.address.allocation, offset⟩) :=
          (load_eq_of_lookup current (Memory.cleanup before.nextId current) write many child ⟨target.address.allocation, offset⟩ (cleanup_lookup_older current before.nextId _ older)).symm
      _ = Memory.load before (.pointer (.pointer write many child) ⟨target.address.allocation, offset⟩) :=
          frame.cleanup_frame.outside child offset write many outside

/-- Loop invariant at loop label `13` of `fn_copy_evm_bytes`:
    - `0 ≤ index ≤ source.length`
    - Stack locals (`dst` at `initial.nextId`, `src` at `initial.nextId + 1`,
      `index` at `initial.nextId + 2`) remain live and initialized
    - Both `target` (writable) and `source` (readable, intact) remain valid
    - Bytes `0..index` of `target` already equal `contents[0..index)`
    - All mutations are confined to local stack frames and `target` (`BorrowedByteFrame`) -/
def loopInvariant (initial : State) (target source : View) (contents : Nat → BitVec 8) : Invariants :=
  fun label env state => label = 13 ∧ ∃ index : Nat,
    index ≤ source.length ∧
    env 2 = some (sizeVal source.length) ∧
    env 6 = some (.pointer (.pointer false false dstPtrTy) ⟨initial.nextId, 0⟩) ∧
    env 9 = some (.pointer (.pointer false false srcPtrTy) ⟨initial.nextId + 1, 0⟩) ∧
    env 10 = some (.pointer (.pointer true false u64Ty) ⟨initial.nextId + 2, 0⟩) ∧
    Memory.load state (.pointer (.pointer false false dstPtrTy) ⟨initial.nextId, 0⟩) = .ok (target.pointer true true) ∧
    Memory.load state (.pointer (.pointer false false srcPtrTy) ⟨initial.nextId + 1, 0⟩) = .ok (source.pointer false true) ∧
    Memory.load state (.pointer (.pointer true false u64Ty) ⟨initial.nextId + 2, 0⟩) = .ok (sizeVal index) ∧
    Memory.RootWritable state u64Ty (initial.nextId + 2) ∧
    state.valid = true ∧ Region state target true ∧ Region state source false ∧
    Represents state source contents ∧
    BorrowedByteFrame target initial state ∧ Prefix state target contents index

def Completed (initial : State) (target source : View) (contents : Nat → BitVec 8)
    (result : Memory.Value) (after : State) : Prop :=
  result = .scalar .unit ∧ after.valid = true ∧ Region after target true ∧
  Represents after target contents ∧ Represents after source contents ∧
  HeapFrame target initial after

def Exhausted (initial : State) (target source : View) (contents : Nat → BitVec 8)
    (fault : Fault) (after : State) : Prop :=
  fault = .outOfMemory ∧ after.valid = true ∧ Region after target true ∧
  Represents after source contents ∧ HeapFrame target initial after

private theorem prefix_zero (state : State) (target : View) (contents : Nat → BitVec 8) :
    Prefix state target contents 0 := by intro i hi; omega

private theorem prefix_store_local (copied : Prefix state target contents count)
    (write many : Bool) (child : Memory.Ty) (address : Address) (value : Memory.Value)
    (apart : target.address.allocation ≠ address.allocation)
    (stored : Memory.store state (.pointer (.pointer write many child) address) value = .ok after) :
    Prefix after target contents count := by
  intro i hi
  exact (load_other_after_store state write many child address value after false false byte
    (target.at i) stored apart).trans (copied i hi)

private theorem region_older (valid : state.valid = true) (cap : Region state view write) :
    view.address.allocation < state.nextId := by
  obtain ⟨_, cell, found, _⟩ := cap
  exact (valid_lookup state _ cell valid found).1

private theorem access_read_of_any {state : State} {addr : Address} {layout : Layout} {w : Bool} {cell : Allocation}
    (h : Memory.access state addr layout w = .ok cell) :
    Memory.access state addr layout false = .ok cell := by
  cases w
  · exact h
  · unfold Memory.access at h ⊢
    cases hlu : state.heap.lookup addr.allocation with
    | none => simp [hlu] at h
    | some c =>
      cases hlay : c.type.layout with
      | none => simp [hlu, hlay] at h
      | some reg =>
        cases hwr : c.writable <;> simp [hlu, hlay, hwr] at h ⊢
        exact h

private theorem target_element (valid : state.valid = true) (cap : Region state target true)
    (inside : index < target.length) :
    Memory.elementPointer state (target.pointer true true) index = .ok (target.pointer true false index) := by
  obtain ⟨cell0, acc0, _⟩ := cap.range valid (by omega : 0 + 0 ≤ target.length) (.inr rfl)
  obtain ⟨cell1, _, _, _, acc1⟩ := cap.access valid inside
  have f0 := (access_success_region _ _ _ _ _ acc0).1
  have f1 := (access_success_region _ _ _ _ _ acc1).1
  have same : cell1 = cell0 := Option.some.inj (f1.symm.trans f0)
  subst cell1
  have h := elementPointer_of_access state true byte target.address index ⟨1, 1⟩ cell0 rfl (by decide)
    (access_read_of_any (by simpa [View.at, Nat.add_zero] using acc0))
    (access_read_of_any (by simpa [View.at, Nat.mul_one] using acc1))
  simpa only [View.pointer, View.at, Nat.add_zero, Nat.mul_one] using h

private theorem source_element (valid : state.valid = true) (cap : Region state source false)
    (inside : index < source.length) :
    Memory.elementPointer state (source.pointer false true) index = .ok (source.pointer false false index) := by
  obtain ⟨cell0, acc0, _⟩ := cap.range valid (by omega : 0 + 0 ≤ source.length) (.inr rfl)
  obtain ⟨cell1, _, _, _, acc1⟩ := cap.access valid inside
  have f0 := (access_success_region _ _ _ _ _ acc0).1
  have f1 := (access_success_region _ _ _ _ _ acc1).1
  have same : cell1 = cell0 := Option.some.inj (f1.symm.trans f0)
  subst cell1
  have h := elementPointer_of_access state false byte source.address index ⟨1, 1⟩ cell0 rfl (by decide)
    (by simpa [View.at, Nat.add_zero] using acc0)
    (by simpa [View.at, Nat.mul_one] using acc1)
  simpa only [View.pointer, View.at, Nat.add_zero, Nat.mul_one] using h

private theorem with_target_write {P : Prop} {state : State} {target : View} {index : Nat}
    (valid : state.valid = true) (cap : Region state target true)
    (inside : index < target.length) (v : BitVec 8)
    (k : ∀ after, Memory.store state (target.pointer true false index) (number v) = .ok after → P) : P := by
  obtain ⟨after, hst⟩ := cap.write valid inside v
  exact k after hst

private theorem completed_ok (initial state : State) (target source : View)
    (contents : Nat → BitVec 8) (index : Nat)
    (cap : Region state target true) (srcRep : Represents state source contents)
    (frame : BorrowedByteFrame target initial state)
    (length : source.length = target.length)
    (olderT : target.address.allocation < initial.nextId)
    (olderS : source.address.allocation < initial.nextId)
    (copied : Prefix state target contents index) (finished : source.length ≤ index) :
    Completed initial target source contents (.scalar .unit) (cleanup initial.nextId state) := by
  have heap := frame.cleanup
  refine ⟨rfl, cleanup_preserves_valid _ _ frame.valid, ?_, ?_, ?_, heap⟩
  · obtain ⟨layout, cell, found, rest⟩ := cap
    exact ⟨layout, cell, (cleanup_lookup_older state initial.nextId _ olderT).trans found, rest⟩
  · intro i hi
    exact (copied.cleanup olderT) i (by omega)
  · intro i hi
    exact (load_eq_of_lookup state (cleanup initial.nextId state) false false byte (source.at i)
      (cleanup_lookup_older state initial.nextId _ olderS)).trans (srcRep i hi)

private theorem exhausted_ok (initial state : State) (target source : View)
    (contents : Nat → BitVec 8)
    (frame : StackFrame initial state) (cap : Region initial target true)
    (original : Represents initial source contents) :
    Exhausted initial target source contents .outOfMemory (cleanup initial.nextId state) := by
  have hheap := frame.cleanup_heap
  refine ⟨rfl, frame.cleanup_valid, ?_, ?_, (HeapFrame.refl target initial).heap_eq hheap⟩
  · obtain ⟨layout, cell, found, rest⟩ := cap
    exact ⟨layout, cell, by rw [hheap]; exact found, rest⟩
  · intro i hi
    exact (load_eq_of_lookup initial (cleanup initial.nextId state) false false byte (source.at i)
      (by rw [hheap])).trans (original i hi)

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

/-- Direct Zig AIR WP contract for `verified_ops.copyEvmBytes`:
    for any disjoint writable destination and readable initialized source byte
    regions of equal length, `copyEvmBytes` never faults (except modeled stack
    OOM), copies every byte `0..len` identically, preserves the source buffer,
    and leaves every byte outside `target` untouched. -/
theorem copy_evm_bytes_contract (initial : State) (target source : View) (contents : Nat → BitVec 8)
    (valid : initial.valid = true) (writable : Region initial target true)
    (readable : Region initial source false) (original : Represents initial source contents)
    (length : source.length = target.length) (apart : Disjoint source target) :
    Triple (Verify.Invocation.mk Generated.fn_copy_evm_bytes (arguments target source)
      (loopInvariant initial target source contents))
      (fun before => before = initial)
      (Completed initial target source contents)
      (Exhausted initial target source contents) := by
  have srcWidth := readable.width valid
  have hlen64 : source.length < 2 ^ 64 := by unfold addressLimit at srcWidth; omega
  have olderT := region_older valid writable
  have olderS := region_older valid readable
  have ht_dst : (target.pointer true true).hasType dstPtrTy = true := rfl
  have hv_dst : (target.pointer true true).valid = true := rfl
  have ht_src : (source.pointer false true).hasType srcPtrTy = true := rfl
  have hv_src : (source.pointer false true).valid = true := rfl
  have ht_len : (sizeVal source.length).hasType u64Ty = true := size_val_hasType hlen64
  have hacc : Generated.fn_copy_evm_bytes.accepts (arguments target source) initial = true := by
    simp only [Program.accepts, Generated.fn_copy_evm_bytes, arguments, valid, List.length_cons, List.length_nil,
      List.zip_cons_cons, List.zip_nil_right, List.all_cons, List.all_nil, Bool.and_true, decide_true, Bool.true_and]
    exact (Bool.and_eq_true _ _).mpr ⟨ht_dst, (Bool.and_eq_true _ _).mpr ⟨ht_src, ht_len⟩⟩
  refine triple_of_pre hacc ?_
  dsimp only [Generated.fn_copy_evm_bytes, arguments]
  -- Bind arguments 0, 1, 2
  rw [pre_bind_eq (prim_arg_eval (i := 0) (args := [target.pointer true true, source.pointer false true, sizeVal source.length]) rfl) ht_dst]
  rw [pre_bind_eq (prim_arg_eval (i := 1) (args := [target.pointer true true, source.pointer false true, sizeVal source.length]) rfl) ht_src]
  rw [pre_bind_eq (prim_arg_eval (i := 2) (args := [target.pointer true true, source.pointer false true, sizeVal source.length]) rfl) ht_len]
  -- Alloc 4 (dst slot, id = initial.nextId), store 5, cast 6
  refine pre_bind_alloc valid (layout := ⟨8, 8⟩) rfl (exhausted_ok initial initial target source contents (StackFrame.refl initial valid) writable original) ?_
  intro s4 halloc4 hvalid4 hsf4
  have hnid4 : s4.nextId = initial.nextId + 1 := alloc_nextId halloc4
  have hcap4 : Memory.RootWritable s4 dstPtrTy initial.nextId := Memory.RootWritable.allocated initial s4 _ _ halloc4
  refine with_fresh_store (child := dstPtrTy) (layout := ⟨8, 8⟩) rfl (by decide) hv_dst rfl halloc4 fun s5 hst5 hvalid5 hsf5 hld5 => ?_
  have hnid5 : s5.nextId = initial.nextId + 1 := (store_preserves_nextId s4 s5 _ _ hst5).trans hnid4
  have hcap5 : Memory.RootWritable s5 dstPtrTy initial.nextId := hcap4.stored s4 s5 _ _ _ _ hst5
  rw [pre_bind_eq (prim_store_eval (ref_local_eval (env_set_self ..) rfl)
    (ref_local_eval (by env_here) hv_dst) hst5) unit_val_hasType]
  have hcast6 := root_cast_const_ok hvalid5 (layout := ⟨8, 8⟩) rfl (by decide) hcap5
  rw [pre_bind_eq (prim_pointerCast_eval (ref_local_eval (by env_here) rfl) hcast6) rfl]
  -- Alloc 7 (src slot, id = initial.nextId + 1), store 8, cast 9
  refine pre_bind_alloc hvalid5 (layout := ⟨8, 8⟩) rfl (exhausted_ok initial s5 target source contents hsf5 writable original) ?_
  intro s7 halloc7 hvalid7 hsf7
  have hnid7 : s7.nextId = initial.nextId + 2 := by rw [alloc_nextId halloc7, hnid5]
  have hcap7 : Memory.RootWritable s7 srcPtrTy (initial.nextId + 1) := by
    have := Memory.RootWritable.allocated s5 s7 _ _ halloc7; rwa [hnid5] at this
  refine with_fresh_store (child := srcPtrTy) (layout := ⟨8, 8⟩) rfl (by decide) hv_src rfl halloc7 fun s8 hst8 hvalid8 hsf8_step hld8 => ?_
  rw [hnid5] at hst8 hld8 ⊢
  have hsf8 : StackFrame initial s8 := hsf5.trans hsf8_step
  have hnid8 : s8.nextId = initial.nextId + 2 := (store_preserves_nextId s7 s8 _ _ hst8).trans hnid7
  have hcap8 : Memory.RootWritable s8 srcPtrTy (initial.nextId + 1) := hcap7.stored s7 s8 _ _ _ _ hst8
  have hld_dst8 : Memory.load s8 (.pointer (.pointer false false dstPtrTy) ⟨initial.nextId, 0⟩) = .ok (target.pointer true true) := by
    have h1 := (Memory.load_after_allocate s5 srcPtrTy _ s7 false false dstPtrTy ⟨initial.nextId, 0⟩ halloc7 (by dsimp; rw [hnid5]; omega)).trans (root_load_const_of_mut hld5)
    exact (Memory.load_other_after_store s7 true false srcPtrTy ⟨initial.nextId + 1, 0⟩ _ s8 false false dstPtrTy ⟨initial.nextId, 0⟩ hst8 (by dsimp; omega)).trans h1
  rw [pre_bind_eq (prim_store_eval (ref_local_eval (env_set_self ..) rfl)
    (ref_local_eval (by env_here) hv_src) hst8) unit_val_hasType]
  have hcast9 := root_cast_const_ok hvalid8 (layout := ⟨8, 8⟩) rfl (by decide) hcap8
  rw [pre_bind_eq (prim_pointerCast_eval (ref_local_eval (by env_here) rfl) hcast9) rfl]
  -- Alloc 10 (index slot, id = initial.nextId + 2), store 11 (index = 0)
  refine pre_bind_alloc hvalid8 (layout := ⟨8, 8⟩) rfl (exhausted_ok initial s8 target source contents hsf8 writable original) ?_
  intro s10 halloc10 hvalid10 hsf10
  have hcap10_idx : Memory.RootWritable s10 u64Ty (initial.nextId + 2) := by
    have := Memory.RootWritable.allocated s8 s10 _ _ halloc10; rwa [hnid8] at this
  have hv0 : (sizeVal 0).valid = true := size_val_valid (by omega)
  refine with_fresh_store (child := u64Ty) (layout := ⟨8, 8⟩) rfl (by decide) hv0 rfl halloc10 fun s11 hst11 hvalid11 hsf11_step hld11 => ?_
  rw [hnid8] at hst11 hld11 ⊢
  have hsf11 : StackFrame initial s11 := hsf8.trans hsf11_step
  have hcap11_idx : Memory.RootWritable s11 u64Ty (initial.nextId + 2) := hcap10_idx.stored s10 s11 _ _ _ _ hst11
  have hld_dst11 : Memory.load s11 (.pointer (.pointer false false dstPtrTy) ⟨initial.nextId, 0⟩) = .ok (target.pointer true true) := by
    have h1 := (Memory.load_after_allocate s8 u64Ty _ s10 false false dstPtrTy ⟨initial.nextId, 0⟩ halloc10 (by dsimp; rw [hnid8]; omega)).trans hld_dst8
    exact (Memory.load_other_after_store s10 true false u64Ty ⟨initial.nextId + 2, 0⟩ _ s11 false false dstPtrTy ⟨initial.nextId, 0⟩ hst11 (by dsimp; omega)).trans h1
  have hld_src11 : Memory.load s11 (.pointer (.pointer false false srcPtrTy) ⟨initial.nextId + 1, 0⟩) = .ok (source.pointer false true) := by
    have h1 := (Memory.load_after_allocate s8 u64Ty _ s10 false false srcPtrTy ⟨initial.nextId + 1, 0⟩ halloc10 (by dsimp; rw [hnid8]; omega)).trans (root_load_const_of_mut hld8)
    exact (Memory.load_other_after_store s10 true false u64Ty ⟨initial.nextId + 2, 0⟩ _ s11 false false srcPtrTy ⟨initial.nextId + 1, 0⟩ hst11 (by dsimp; omega)).trans h1
  have hv0' : (Value.scalar (.int false 64 0)).valid = true := hv0
  have hst11' : Memory.store s10 (.pointer (.pointer true false u64Ty) ⟨initial.nextId + 2, 0⟩) (.scalar (.int false 64 0)) = .ok s11 := hst11
  rw [pre_bind_eq (prim_store_eval (ref_local_eval (env_set_self ..) rfl) (ref_const_eval hv0') hst11') unit_val_hasType]
  -- Block 12 -> Loop 13
  rw [pre_block_eq]
  rw [pre_loop_eq]
  constructor
  · -- Loop entry: index = 0
    refine ⟨rfl, 0, Nat.zero_le _, by env_here, by env_here, by env_here, by env_here,
      hld_dst11, hld_src11, hld11, hcap11_idx, hvalid11,
      writable.stack hsf11, readable.stack hsf11, original.stack hsf11,
      BorrowedByteFrame.ofStack target initial s11 hsf11, prefix_zero s11 target contents⟩
  · -- Loop body preservation
    rintro envL stateL ⟨_, idx, hidx_le, he2, he6, he9, he10, hld_dst, hld_src, hld_idx, hcap_idx, hvalidL, hregT, hregS, hrepS, hframe, hpref⟩
    have hidx64 : idx < 2 ^ 64 := by omega
    -- Block 14 (loop step)
    rw [pre_block_eq]
    rw [pre_bind_eq (prim_load_eval (ref_local_eval he10 rfl) hld_idx) (size_val_hasType hidx64)]
    rw [pre_bind_eq (prim_scalar_eval (scalar_bitcast_u64_eval hidx64
      (scalar_ref_local_eval (scalarEnv_of_env (env_set_self ..)) (size_scalar_valid hidx64)))) (size_val_hasType hidx64)]
    rw [pre_bind_eq (prim_scalar_eval (scalar_bitcast_u64_eval hlen64
      (scalar_ref_local_eval (scalarEnv_of_env (by env_use he2)) (size_scalar_valid hlen64)))) ht_len]
    by_cases hlt : idx < source.length
    · -- idx < len: dst[idx] = src[idx]; idx += 1
      have hlt_tgt : idx < target.length := by omega
      rw [pre_bind_eq (prim_scalar_eval (scalar_cmp_eval
        (scalar_ref_local_eval (scalarEnv_of_env (by env_here)) (size_scalar_valid hidx64))
        (scalar_ref_local_eval (scalarEnv_of_env (env_set_self ..)) (size_scalar_valid hlen64))
        (show Scalar.Comparison.lt.eval idx source.length = true by simp [Scalar.Comparison.eval, hlt]))) (bool_val_hasType true)]
      rw [pre_branch_true_eq (ref_local_eval (env_set_self ..) (bool_val_valid true))]
      -- 20: load idx, 21: load dst, 22: &dst[idx]
      rw [pre_bind_eq (prim_load_eval (ref_local_eval (by env_use he10) rfl) hld_idx) (size_val_hasType hidx64)]
      rw [pre_bind_eq (prim_load_eval (ref_local_eval (by env_use he6) rfl) hld_dst) ht_dst]
      have helemT := target_element hvalidL hregT hlt_tgt
      rw [pre_bind_eq (prim_elementPointer_eval (ref_local_eval (env_set_self ..) hv_dst)
        (ref_natural_local (by env_here) hidx64) helemT) rfl]
      -- 23: load idx, 24: load src, 25: &src[idx], 26: load src[idx]
      rw [pre_bind_eq (prim_load_eval (ref_local_eval (by env_use he10) rfl) hld_idx) (size_val_hasType hidx64)]
      rw [pre_bind_eq (prim_load_eval (ref_local_eval (by env_use he9) rfl) hld_src) ht_src]
      have helemS := source_element hvalidL hregS hlt
      rw [pre_bind_eq (prim_elementPointer_eval (ref_local_eval (env_set_self ..) hv_src)
        (ref_natural_local (by env_here) hidx64) helemS) rfl]
      have hld_byte : Memory.load stateL (source.pointer false false idx) = .ok (number (contents idx)) := hrepS idx hlt
      have ht_byte : (number (contents idx)).hasType u8Ty = true := number_typed (contents idx)
      have hv_byte : (number (contents idx)).valid = true := number_valid (contents idx)
      rw [pre_bind_eq (prim_load_eval (ref_local_eval (env_set_self ..) rfl) hld_byte) ht_byte]
      -- 27: store dst[idx] := contents idx
      refine with_target_write hvalidL hregT hlt_tgt (contents idx) fun state1 hst1 => ?_
      rw [pre_bind_eq (prim_store_eval (ref_local_eval (by env_here) rfl)
        (ref_local_eval (env_set_self ..) hv_byte) hst1) unit_val_hasType]
      have hvalid1 : state1.valid = true := store_preserves_valid _ _ _ _ hvalidL hst1
      have hld_dst1 : Memory.load state1 (.pointer (.pointer false false dstPtrTy) ⟨initial.nextId, 0⟩) = .ok (target.pointer true true) :=
        (load_other_after_store stateL true false byte (target.at idx) _ state1 false false dstPtrTy ⟨initial.nextId, 0⟩ hst1 (by dsimp [View.at]; omega)).trans hld_dst
      have hld_src1 : Memory.load state1 (.pointer (.pointer false false srcPtrTy) ⟨initial.nextId + 1, 0⟩) = .ok (source.pointer false true) :=
        (load_other_after_store stateL true false byte (target.at idx) _ state1 false false srcPtrTy ⟨initial.nextId + 1, 0⟩ hst1 (by dsimp [View.at]; omega)).trans hld_src
      have hld_idx1 : Memory.load state1 (.pointer (.pointer true false u64Ty) ⟨initial.nextId + 2, 0⟩) = .ok (sizeVal idx) :=
        (load_other_after_store stateL true false byte (target.at idx) _ state1 true false u64Ty ⟨initial.nextId + 2, 0⟩ hst1 (by dsimp [View.at]; omega)).trans hld_idx
      have hcap_idx1 : Memory.RootWritable state1 u64Ty (initial.nextId + 2) := hcap_idx.stored stateL state1 _ _ _ _ hst1
      have hregT1 : Region state1 target true := hregT.stored hst1
      have hregS1 : Region state1 source false := hregS.stored hst1
      have hrepS1 : Represents state1 source contents := hrepS.stored apart hlt_tgt hst1
      have hframe1 : BorrowedByteFrame target initial state1 := hframe.store_byte idx (contents idx) hlt_tgt olderT hst1
      have hpref1 : Prefix state1 target contents (idx + 1) := hpref.stored hst1
      -- 29: load idx, 30: idx + 1, 31: store idx := idx + 1
      rw [pre_bind_eq (prim_load_eval (ref_local_eval (by env_use he10) rfl) hld_idx1) (size_val_hasType hidx64)]
      have hnext64 : idx + 1 < 2 ^ 64 := by omega
      have hv1 : (Scalar.Value.int false 64 1).valid = true := size_scalar_valid (n := 1) (by omega)
      have hi30 : Scalar.integer false 64 (Scalar.Arithmetic.add.eval idx (1 : Int)) .unchecked = .ok (.int false 64 ↑(idx + 1)) := by
        change Scalar.integer false 64 ((idx : Int) + 1) .unchecked = _
        rw [show (idx : Int) + 1 = ↑(idx + 1) by omega]
        exact integer_unchecked_of_valid (size_scalar_valid hnext64)
      rw [pre_bind_eq (prim_scalar_eval (scalar_arith_eval
        (scalar_ref_local_eval (scalarEnv_of_env (env_set_self ..)) (size_scalar_valid hidx64))
        (scalar_ref_const_eval hv1) hi30)) (size_val_hasType hnext64)]
      refine with_root_store hvalid1 hcap_idx1 (size_val_hasType hnext64) (layout := ⟨8, 8⟩) rfl (by decide) fun state2 hst2 => ?_
      rw [pre_bind_eq (prim_store_eval (ref_local_eval (by env_use he10) rfl)
        (ref_local_eval (env_set_self ..) (size_val_valid hnext64)) hst2) unit_val_hasType]
      rw [pre_jump_eq (ref_const_eval unit_val_valid)]
      refine blockPost_hit unit_val_hasType ?_
      rw [pre_repeat_eq]
      refine loopPost_repeat_hit ?_
      refine ⟨rfl, idx + 1, by omega, by env_use he2, by env_use he6, by env_use he9, by env_use he10,
        (load_other_after_store state1 true false u64Ty ⟨initial.nextId + 2, 0⟩ _ state2 false false dstPtrTy ⟨initial.nextId, 0⟩ hst2 (by dsimp; omega)).trans hld_dst1,
        (load_other_after_store state1 true false u64Ty ⟨initial.nextId + 2, 0⟩ _ state2 false false srcPtrTy ⟨initial.nextId + 1, 0⟩ hst2 (by dsimp; omega)).trans hld_src1,
        load_after_store state1 _ _ state2 hst2,
        hcap_idx1.stored state1 state2 _ _ _ _ hst2,
        store_preserves_valid _ _ _ _ hvalid1 hst2,
        hregT1.stored hst2,
        hregS1.stored hst2,
        (fun i hi => (load_other_after_store state1 true false u64Ty ⟨initial.nextId + 2, 0⟩ _ state2 false false byte (source.at i) hst2 (by dsimp [View.at]; omega)).trans (hrepS1 i hi)),
        hframe1.store_local true false u64Ty ⟨initial.nextId + 2, 0⟩ _ (by dsimp; omega) hst2,
        prefix_store_local hpref1 true false u64Ty ⟨initial.nextId + 2, 0⟩ _ (by dsimp; omega) hst2⟩
    · -- Exit loop: idx ≥ source.length -> jump 12 -> ret unit
      rw [pre_bind_eq (prim_scalar_eval (scalar_cmp_eval
        (scalar_ref_local_eval (scalarEnv_of_env (by env_here)) (size_scalar_valid hidx64))
        (scalar_ref_local_eval (scalarEnv_of_env (env_set_self ..)) (size_scalar_valid hlen64))
        (show Scalar.Comparison.lt.eval idx source.length = false by simp [Scalar.Comparison.eval, hlt]))) (bool_val_hasType false)]
      rw [pre_branch_false_eq (ref_local_eval (env_set_self ..) (bool_val_valid false))]
      rw [pre_jump_eq (ref_const_eval unit_val_valid)]
      refine blockPost_miss (by decide) (loopPost_jump_miss (by decide) ?_)
      refine blockPost_hit unit_val_hasType ?_
      rw [pre_ret_eq (ref_const_eval unit_val_valid)]
      refine finishPost_ret unit_val_hasType
        (completed_ok initial stateL target source contents idx hregT hrepS hframe length olderT olderS hpref (by omega))

/-- Soundness corollary across every finite fuel budget for `copyEvmBytes`. -/
theorem copy_evm_bytes_safe (initial : State) (target source : View) (contents : Nat → BitVec 8)
    (valid : initial.valid = true) (writable : Region initial target true)
    (readable : Region initial source false) (original : Represents initial source contents)
    (length : source.length = target.length) (apart : Disjoint source target)
    (fuel : Nat) :
    Verify.Observes (Completed initial target source contents)
      (Exhausted initial target source contents)
      (Generated.fn_copy_evm_bytes.runFuel fuel (arguments target source) initial) :=
  Verify.sound _ _ _ _
    (copy_evm_bytes_contract initial target source contents valid writable readable original length apart)
    initial rfl fuel

end GuillotineZean.MemoryCopy
