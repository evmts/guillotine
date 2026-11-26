import Std

namespace GuillotineVerify.JumpTable

abbrev Entry (α : Type) := Nat × α

/-- Binary search on the half-open interval [lo, hi). The initial interval may
    be narrowed by a sorted-table pivot before this loop. -/
def bsearchRange (entries : List (Entry α)) (pc lo hi : Nat) (bound : hi ≤ entries.length) :
    Option (Entry α) :=
  if active : lo < hi then
    let mid := lo + (hi - lo) / 2
    let e := entries[mid]'(by dsimp [mid]; omega)
    if e.1 = pc then some e
    else if e.1 < pc then bsearchRange entries pc (mid + 1) hi bound
    else bsearchRange entries pc lo mid (by dsimp [mid]; omega)
  else none
termination_by hi - lo
decreasing_by all_goals (first | omega | (dsimp [mid]; omega))

private theorem bsearchRange_spec (entries : List (Entry α)) (pc lo hi : Nat)
    (bound : hi ≤ entries.length) (sorted : entries.Pairwise (fun a b => a.1 < b.1)) :
    (bsearchRange entries pc lo hi bound = none ↔
      ∀ (i : Nat) (il : i < entries.length), lo ≤ i → i < hi → (entries[i]'il).1 ≠ pc) ∧
    (∀ e, bsearchRange entries pc lo hi bound = some e →
      ∃ (i : Nat) (il : i < entries.length), lo ≤ i ∧ i < hi ∧ entries[i]'il = e ∧ e.1 = pc) := by
  have ordered : ∀ (i j : Nat) (il : i < entries.length) (jl : j < entries.length), i < j →
      (entries[i]'il).1 < (entries[j]'jl).1 := fun i j il jl lt =>
    List.pairwise_iff_getElem.mp sorted i j il jl lt
  rw [bsearchRange]
  split
  · rename_i active
    dsimp only
    have ml : lo ≤ lo + (hi - lo) / 2 := by omega
    have mh : lo + (hi - lo) / 2 < hi := by omega
    have mb : lo + (hi - lo) / 2 < entries.length := by omega
    by_cases eq : (entries[lo + (hi - lo) / 2]'mb).1 = pc
    · rw [if_pos eq]
      refine ⟨⟨fun h => (by cases h), fun h => absurd eq (h _ mb ml mh)⟩, ?_⟩
      intro found he
      cases he
      exact ⟨_, mb, ml, mh, rfl, eq⟩
    · rw [if_neg eq]
      by_cases left : (entries[lo + (hi - lo) / 2]'mb).1 < pc
      · rw [if_pos left]
        have smaller := bsearchRange_spec entries pc (lo + (hi - lo) / 2 + 1) hi bound sorted
        constructor
        · rw [smaller.1]
          constructor
          · intro no i il low high hp
            by_cases right : lo + (hi - lo) / 2 < i
            · exact no i il (by omega) high hp
            · have le : (entries[i]'il).1 ≤ (entries[lo + (hi - lo) / 2]'mb).1 := by
                by_cases same : i = lo + (hi - lo) / 2
                · subst same; exact Nat.le_refl _
                · exact Nat.le_of_lt (ordered i _ il mb (by omega))
              omega
          · intro no i il low high
            exact no i il (by omega) high
        · intro found he
          obtain ⟨i, il, low, high, hv, hp⟩ := smaller.2 found he
          exact ⟨i, il, by omega, high, hv, hp⟩
      · rw [if_neg left]
        have smaller := bsearchRange_spec entries pc lo (lo + (hi - lo) / 2) (by omega) sorted
        constructor
        · rw [smaller.1]
          constructor
          · intro no i il low high hp
            by_cases first : i < lo + (hi - lo) / 2
            · exact no i il low first hp
            · have le : (entries[lo + (hi - lo) / 2]'mb).1 ≤ (entries[i]'il).1 := by
                by_cases same : i = lo + (hi - lo) / 2
                · subst same; exact Nat.le_refl _
                · exact Nat.le_of_lt (ordered _ i mb il (by omega))
              omega
          · intro no i il low high
            exact no i il low (by omega)
        · intro found he
          obtain ⟨i, il, low, high, hv, hp⟩ := smaller.2 found he
          exact ⟨i, il, low, by omega, hv, hp⟩
  · rename_i inactive
    refine ⟨⟨fun _ i _ low high => (by omega), fun _ => rfl⟩, fun found he => (by cases he)⟩
termination_by hi - lo
decreasing_by all_goals omega

def bsearch (entries : List (Entry α)) (pc : Nat) : Option (Entry α) :=
  bsearchRange entries pc 0 entries.length (Nat.le_refl _)

/-- Direct-address table indexed by bytecode PC, with empty slots for non-destinations. -/
def buildDense (entries : List (Entry α)) (len : Nat) : Array (Option (Entry α)) :=
  Array.ofFn (n := len) fun pc => entries.find? fun e => e.1 == pc.val

def denseLookup (table : Array (Option (Entry α))) (pc : Nat) : Option (Entry α) :=
  table[pc]?.join

theorem denseLookup_eq_bsearch (entries : List (Entry α)) (len pc : Nat)
    (sorted : entries.Pairwise (fun a b => a.1 < b.1))
    (fits : ∀ i (il : i < entries.length), (entries[i]'il).1 < len) :
    denseLookup (buildDense entries len) pc = bsearch entries pc := by
  have spec := bsearchRange_spec entries pc 0 entries.length (Nat.le_refl _) sorted
  have unique {i j : Nat} (il : i < entries.length) (jl : j < entries.length)
      (same : (entries[i]'il).1 = (entries[j]'jl).1) : i = j := by
    have ord := List.pairwise_iff_getElem.mp sorted
    by_cases left : i < j
    · have := ord i j il jl left
      omega
    · by_cases right : j < i
      · have := ord j i jl il right
        omega
      · omega
  unfold denseLookup buildDense bsearch
  by_cases inTable : pc < len
  · simp only [Array.getElem?_ofFn, inTable, dite_true, Option.join_some]
    cases hb : bsearchRange entries pc 0 entries.length (Nat.le_refl _) with
    | none =>
      apply List.find?_eq_none.mpr
      intro e he heq
      obtain ⟨i, il, hi⟩ := List.getElem_of_mem he
      have := spec.1.mp hb i il (Nat.zero_le _) il
      apply this
      simpa [hi] using heq
    | some e =>
      obtain ⟨i, il, _, _, ei, ep⟩ := spec.2 e hb
      cases hf : entries.find? (fun p => p.1 == pc) with
      | none =>
        have he := List.find?_eq_none.mp hf e (ei ▸ List.getElem_mem il)
        simp [ep] at he
      | some f =>
        have hp := List.find?_some hf
        obtain ⟨j, jl, ej⟩ := List.getElem_of_mem (List.mem_of_find?_eq_some hf)
        have ij := unique il jl (by simpa [ei, ej, ep] using (eq_of_beq hp).symm)
        subst j
        rw [← ej, ei]
  · simp only [Array.getElem?_ofFn, inTable, dite_false, Option.join_none]
    symm
    apply spec.1.mpr
    intro i il _ _ same
    have := fits i il
    omega

def denseJumpInBoundsRef (dest : BitVec 256) (len : BitVec 32) (pcWidth : Nat) : Bool :=
  if dest.toNat ≤ 2^pcWidth - 1 then decide ((dest.setWidth 32).toNat < len.toNat) else false

def denseJumpInBoundsFast (dest : BitVec 256) (len : BitVec 32) : Bool :=
  decide (dest.toNat < len.toNat)

theorem denseJumpInBoundsFast_eq_ref (dest : BitVec 256) (len : BitVec 32) (pcWidth : Nat)
    (pcFits : pcWidth ≤ 32) (lenFits : len.toNat ≤ 2^pcWidth) :
    denseJumpInBoundsFast dest len = denseJumpInBoundsRef dest len pcWidth := by
  have powBound : 2^pcWidth ≤ (2:Nat)^32 := Nat.pow_le_pow_right (by decide) pcFits
  have positive := Nat.two_pow_pos pcWidth
  unfold denseJumpInBoundsFast denseJumpInBoundsRef
  split
  · rename_i representable
    rw [BitVec.toNat_setWidth, Nat.mod_eq_of_lt (by omega)]
  · rename_i unrepresentable
    simp [show ¬ dest.toNat < len.toNat by omega]

end GuillotineVerify.JumpTable
