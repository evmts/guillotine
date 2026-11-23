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
decreasing_by all_goals omega

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
    let result := if e.1 = pc then some e else if e.1 < pc then
      bsearchRange entries pc (mid + 1) hi bound else
      bsearchRange entries pc lo mid (by omega)
    change (result = none ↔ _) ∧ (∀ v, result = some v → _)
    by_cases eq : e.1 = pc
    · simp only [result, if_pos eq, reduceCtorEq, false_iff, Option.some.injEq]
      constructor
      · exact fun h => h mid mb ml mh eq
      · rintro _ rfl
        exact ⟨mid, mb, ml, mh, rfl, eq⟩
    · by_cases left : e.1 < pc
      · simp only [result, if_neg eq, if_pos left]
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
                · exact Nat.le_of_lt (ordered i mid il mb (by omega))
              omega
          · intro no i il low high
            exact no i il (by omega) high
        · intro e found
          obtain ⟨i, il, low, high, hv, hp⟩ := smaller.2 e found
          exact ⟨i, il, by omega, high, hv, hp⟩
      · simp only [result, if_neg eq, if_neg left]
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
                · exact Nat.le_of_lt (ordered mid i mb il (by omega))
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

/-- Each PC slot contains the index of its jump destination in the sparse table. -/
def buildDense (entries : List (Entry α)) (len : Nat) : Array (Option Nat) :=
  Array.ofFn (n := len) fun pc => entries.findIdx? fun e => e.1 == pc.val

def denseLookup (entries : Array (Entry α)) (table : Array (Option Nat)) (pc : Nat) :
    Option (Entry α) :=
  table[pc]?.join.bind (fun i => entries[i]?)

theorem denseLookup_eq_bsearch (entries : List (Entry α)) (len pc : Nat)
    (sorted : entries.Pairwise (fun a b => a.1 < b.1))
    (fits : ∀ i (il : i < entries.length), (entries[i]'il).1 < len) :
    denseLookup entries.toArray (buildDense entries len) pc = bsearch entries pc := by
  have spec := bsearchRange_spec entries pc 0 entries.length (Nat.le_refl _) sorted
  have ordered := List.pairwise_iff_getElem.mp sorted
  unfold denseLookup buildDense bsearch
  by_cases inTable : pc < len
  · simp only [Array.getElem?_ofFn, inTable, dite_true, Option.join_some]
    cases hb : bsearchRange entries pc 0 entries.length (Nat.le_refl _) with
    | none =>
      have absent : entries.findIdx? (fun e => e.1 == pc) = none := by
        apply List.findIdx?_eq_none_iff.mpr
        intro e he
        obtain ⟨i, il, rfl⟩ := List.getElem_of_mem he
        exact beq_eq_false_iff_ne.mpr (spec.1.mp hb i il (Nat.zero_le _) il)
      rw [absent]
      rfl
    | some e =>
      obtain ⟨i, il, _, _, ei, ep⟩ := spec.2 e hb
      have epc : entries[i].1 = pc := ei ▸ ep
      have present : entries.findIdx? (fun p => p.1 == pc) = some i := by
        apply List.findIdx?_eq_some_iff_getElem.mpr
        refine ⟨il, beq_iff_eq.mpr epc, ?_⟩
        intro j ji matchPc
        have lt := ordered j i (Nat.lt_trans ji il) il ji
        have eq : entries[j].1 = pc := eq_of_beq matchPc
        omega
      simp [present, il, ei]
  · simp only [Array.getElem?_ofFn, inTable, dite_false, Option.join_none, Option.bind]
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
