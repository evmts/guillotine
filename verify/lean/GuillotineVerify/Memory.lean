import Std.Tactic.BVDecide

namespace GuillotineVerify.Memory

def checkMemoryBoundsRef (offset : BitVec 256) (size limit : BitVec 64) : Bool :=
  decide (offset.toNat < 2^64 ∧ offset.toNat + size.toNat < 2^64 ∧
    ((offset.setWidth 64) + size).toNat ≤ limit.toNat)

def checkMemoryBoundsFast (offset : BitVec 256) (size limit : BitVec 64) : Bool :=
  decide (size.toNat ≤ limit.toNat ∧ offset.toNat ≤ (limit - size).toNat)

theorem checkMemoryBoundsFast_eq_ref (offset : BitVec 256) (size limit : BitVec 64) :
    checkMemoryBoundsFast offset size limit = checkMemoryBoundsRef offset size limit := by
  have hl := limit.isLt
  unfold checkMemoryBoundsFast checkMemoryBoundsRef
  congr 1
  apply propext
  constructor
  · rintro ⟨hs, ho⟩
    rw [BitVec.toNat_sub_of_le (show size ≤ limit from hs)] at ho
    have hOff : offset.toNat < 2^64 := by omega
    have hSum : offset.toNat + size.toNat < 2^64 := by omega
    refine ⟨hOff, hSum, ?_⟩
    simp only [BitVec.toNat_add, BitVec.toNat_setWidth, Nat.mod_eq_of_lt hOff,
      Nat.mod_eq_of_lt hSum]
    omega
  · rintro ⟨ho, hsum, hl⟩
    simp only [BitVec.toNat_add, BitVec.toNat_setWidth, Nat.mod_eq_of_lt ho,
      Nat.mod_eq_of_lt hsum] at hl
    have hs : size ≤ limit := show size.toNat ≤ limit.toNat by omega
    rw [BitVec.toNat_sub_of_le hs]
    exact ⟨hs, by omega⟩

theorem checkMemoryBoundsFast_eq_ref_32 (offset : BitVec 256) (limit : BitVec 64) :
    checkMemoryBoundsFast offset 32 limit = checkMemoryBoundsRef offset 32 limit :=
  checkMemoryBoundsFast_eq_ref offset 32 limit

theorem checkMemoryBoundsFast_eq_ref_1 (offset : BitVec 256) (limit : BitVec 64) :
    checkMemoryBoundsFast offset 1 limit = checkMemoryBoundsRef offset 1 limit :=
  checkMemoryBoundsFast_eq_ref offset 1 limit

def alignUp32 (n : BitVec 32) : BitVec 32 := (n + 31) &&& ~~~(31 : BitVec 32)

def ceilWords (n : Nat) : Nat := if n = 0 then 0 else (n - 1) / 32 + 1

private theorem ceilWords_eq (n : Nat) : ceilWords n = (n + 31) / 32 := by
  unfold ceilWords
  split <;> omega

theorem alignUp32_no_overflow (n : BitVec 32) (hn : n.toNat ≤ 0xFFFFFF) :
    n.toNat + 31 < 2^32 := by omega

private theorem clearLowFive (x : BitVec 32) :
    x &&& ~~~(31 : BitVec 32) = (x >>> 5) <<< 5 := by bv_decide

theorem alignUp32_eq_ceil_mult32 (n : BitVec 32) (hn : n.toNat ≤ 0xFFFFFF) :
    (alignUp32 n).toNat = ceilWords n.toNat * 32 := by
  rw [alignUp32, clearLowFive, ceilWords_eq, BitVec.toNat_shiftLeft,
    BitVec.toNat_ushiftRight, BitVec.toNat_add_of_lt (alignUp32_no_overflow n hn)]
  rw [Nat.shiftLeft_eq, Nat.shiftRight_eq_div_pow]
  change ((n.toNat + 31) / 32 * 32) % 2^32 = _
  exact Nat.mod_eq_of_lt (by omega)

def memoryWordCountFast (n : BitVec 32) : BitVec 64 := (n.zeroExtend 64 + 31) >>> 5
def memoryWordCountRef (n : BitVec 32) : BitVec 64 := BitVec.ofNat 64 (ceilWords n.toNat)

theorem memoryWordCountFast_eq_ref (n : BitVec 32) :
    memoryWordCountFast n = memoryWordCountRef n := by
  have hn := n.isLt
  apply BitVec.eq_of_toNat_eq
  simp only [memoryWordCountFast, memoryWordCountRef, BitVec.toNat_ushiftRight,
    BitVec.toNat_add, BitVec.zeroExtend, BitVec.toNat_setWidth, BitVec.toNat_ofNat,
    Nat.shiftRight_eq_div_pow, ceilWords_eq]
  change ((n.toNat % 2^64 + 31) % 2^64) / 32 = ((n.toNat + 31) / 32) % 2^64
  rw [Nat.mod_eq_of_lt (show n.toNat < 2^64 by omega),
    Nat.mod_eq_of_lt (show n.toNat + 31 < 2^64 by omega),
    Nat.mod_eq_of_lt (show (n.toNat + 31) / 32 < 2^64 by omega)]

def memoryGasCost (w : Nat) : Nat := w * 3 + (w * w) / 512

theorem memoryGasCost_mono (w1 w2 : Nat) (h : w1 ≤ w2) :
    memoryGasCost w1 ≤ memoryGasCost w2 :=
  Nat.add_le_add (Nat.mul_le_mul_right 3 h) (Nat.div_le_div_right (Nat.mul_le_mul h h))

theorem memoryGasCost_no_overflow (w : Nat) (h : w ≤ 524288) :
    memoryGasCost w < 2^63 :=
  Nat.lt_of_le_of_lt (memoryGasCost_mono w 524288 h) (by decide)

def memoryGasCostU64 (w : BitVec 64) : BitVec 64 := (w * 3) + ((w * w) >>> 9)

theorem memoryGasCostU64_eq (w : BitVec 64) (h : w.toNat ≤ 524288) :
    (memoryGasCostU64 w).toNat = memoryGasCost w.toNat := by
  have linear : w.toNat * 3 < 2^64 := by omega
  have square : w.toNat * w.toNat < 2^64 :=
    Nat.lt_of_le_of_lt (Nat.mul_le_mul h h) (by decide)
  have total := memoryGasCost_no_overflow w.toNat h
  simp only [memoryGasCostU64, BitVec.toNat_add, BitVec.toNat_mul, BitVec.toNat_ushiftRight,
    Nat.shiftRight_eq_div_pow, Nat.mod_eq_of_lt square]
  rw [show (3 : BitVec 64).toNat = 3 by decide, Nat.mod_eq_of_lt linear]
  change memoryGasCost w.toNat % 2^64 = _
  exact Nat.mod_eq_of_lt (by omega)

end GuillotineVerify.Memory
