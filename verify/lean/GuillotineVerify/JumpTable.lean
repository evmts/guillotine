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
decreasing_by all_goals dsimp [mid]; omega

private theorem bsearchRange_spec (entries : List (Entry α)) (pc lo hi : Nat)
    (bound : hi ≤ entries.length) (sorted : entries.Pairwise (fun a b => a.1 < b.1)) :
    (bsearchRange entries pc lo hi bound = none ↔
      ∀ (i : Nat) (il : i < entries.length), lo ≤ i → i < hi → (entries[i]'il).1 ≠ pc) ∧
    (∀ e, bsearchRange entries pc lo hi bound = some e →
      ∃ (i : Nat) (il : i < entries.length), lo ≤ i ∧ i < hi ∧ entries[i]'il = e ∧ e.1 = pc) := by
  have ordered := List.pairwise_iff_getElem.mp sorted
  rw [bsearchRange]
  split
  · rename_i active
    dsimp only
    let mid := lo + (hi - lo) / 2
    have ml : lo ≤ mid := by dsimp [mid]; omega
    have mh : mid < hi := by dsimp [mid]; omega
    have mb : mid < entries.length := by omega
    let e := entries[mid]'mb
    change ( (if e.1 = pc then some e else if e.1 < pc then
          bsearchRange entries pc (mid + 1) hi bound else
          bsearchRange entries pc lo mid (by omega)) = none ↔ _) ∧ _
    by_cases eq : e.1 = pc
    · simp only [if_pos eq, reduceCtorEq, false_iff, Option.some.injEq]
      constructor
      · exact fun h => h mid mb ml mh eq
      · rintro _ rfl
        exact ⟨mid, mb, ml, mh, rfl, eq⟩
    · by_cases left : e.1 < pc
      · simp only [if_neg eq, if_pos left]
        have smaller := bsearchRange_spec entries pc (mid + 1) hi bound sorted
        constructor
        · rw [smaller.1]
          constructor
          · intro no i il low high hp
            by_cases right : mid < i
            · exact no i il (by omega) high hp
            · have le : (entries[i]'il).1 ≤ e.1 := by
                by_cases same : i = mid
                · subst i; exact Nat.le_refl _
                · exact Nat.le_of_lt (ordered il mb (by omega))
              omega
          · intro no i il low high
            exact no i il (by omega) high
        · intro e found
          obtain ⟨i, il, low, high, hv, hp⟩ := smaller.2 e found
          exact ⟨i, il, by omega, high, hv, hp⟩
      · simp only [if_neg eq, if_neg left]
        have smaller := bsearchRange_spec entries pc lo mid (by omega) sorted
        constructor
        · rw [smaller.1]
          constructor
          · intro no i il low high hp
            by_cases first : i < mid
            · exact no i il low first hp
            · have le : e.1 ≤ (entries[i]'il).1 := by
                by_cases same : i = mid
                · subst i; exact Nat.le_refl _
                · exact Nat.le_of_lt (ordered mb il (by omega))
              omega
          · intro no i il low high
            exact no i il low (by omega)
        · intro e found
          obtain ⟨i, il, low, high, hv, hp⟩ := smaller.2 e found
          exact ⟨i, il, low, by omega, hv, hp⟩
  · rename_i inactive
    simp only [reduceCtorEq, true_iff, false_implies, implies_true, and_true]
    intro i _ low high
    omega
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
    · have := ord il jl left
      omega
    · by_cases right : j < i
      · have := ord jl il right
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
