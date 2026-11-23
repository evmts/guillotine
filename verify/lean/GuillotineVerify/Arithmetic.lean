import Std.Tactic.BVDecide

namespace GuillotineVerify.Arithmetic

abbrev Word := BitVec 256

/-- The reference's repeated shift, using natural division by 256 for each shift. -/
def expByteLoop (x : Nat) : Nat :=
  if x = 0 then 0 else 1 + expByteLoop (x / 256)
termination_by x
decreasing_by exact Nat.div_lt_self (Nat.pos_of_ne_zero ‹x ≠ 0›) (by decide)

private theorem expByteLoop_le_iff (x n : Nat) : expByteLoop x ≤ n ↔ x < 256^n := by
  induction n generalizing x with
  | zero =>
    rw [expByteLoop]
    split <;> simp_all <;> omega
  | succ n ih =>
    rw [expByteLoop]
    split
    · subst x
      simp [Nat.pow_pos]
    · rw [show 1 + expByteLoop (x / 256) ≤ n + 1 ↔ expByteLoop (x / 256) ≤ n by omega,
          ih, Nat.div_lt_iff_lt_mul (by decide), Nat.pow_succ]

def expGasByteLenRef (x : Word) : BitVec 32 := BitVec.ofNat 32 (expByteLoop x.toNat)
def expGasByteLenFast (x : Word) : BitVec 32 :=
  ((263 : BitVec 32) - x.clz.setWidth 32) >>> 3

theorem expGasByteLenFast_eq_ref (x : Word) :
    expGasByteLenFast x = expGasByteLenRef x := by
  have hc : x.clz.toNat ≤ 256 := BitVec.clz_le (x := x)
  have castClz : (x.clz.setWidth 32).toNat = x.clz.toNat := by
    rw [BitVec.toNat_setWidth, Nat.mod_eq_of_lt (by omega)]
  let n := (263 - x.clz.toNat) / 8
  have nBound : n ≤ 32 := by dsimp [n]; omega
  have bytePower (k : Nat) : (256 : Nat)^k = 2^(8*k) := (Nat.pow_mul 2 8 k).symm
  have upper : x.toNat < 256^n := by
    rw [bytePower]
    exact Nat.lt_of_lt_of_le BitVec.toNat_lt_two_pow_sub_clz
      (Nat.pow_le_pow_right (by decide) (by dsimp [n]; omega))
  have exactLen : expByteLoop x.toNat = n := by
    have le := (expByteLoop_le_iff _ _).2 upper
    by_cases hz : x = 0
    · subst x
      have z : (0 : Word).clz.toNat = 256 :=
        congrArg BitVec.toNat (BitVec.clz_eq_iff_eq_zero.mpr rfl)
      have : n = 0 := by change (263 - (0 : Word).clz.toNat) / 8 = 0; rw [z]
      omega
    · have lower := BitVec.two_pow_sub_clz_le_toNat_of_ne_zero (by decide : 0 < 256) hz
      have np : n ≤ expByteLoop x.toNat := by
        apply Nat.le_of_not_gt
        intro short
        have tooSmall := (expByteLoop_le_iff x.toNat (n - 1)).1 (by omega)
        rw [bytePower] at tooSmall
        have bound : 2^(8 * (n - 1)) ≤ 2^(255 - x.clz.toNat) :=
          Nat.pow_le_pow_right (by decide) (by dsimp [n]; omega)
        exact (Nat.not_lt_of_ge (Nat.le_trans bound lower)) tooSmall
      omega
  apply BitVec.eq_of_toNat_eq
  unfold expGasByteLenFast expGasByteLenRef
  have valid : x.clz.setWidth 32 ≤ (263 : BitVec 32) := by
    change (x.clz.setWidth 32).toNat ≤ 263
    rw [castClz]
    omega
  rw [BitVec.toNat_ushiftRight, BitVec.toNat_sub_of_le valid, castClz,
    Nat.shiftRight_eq_div_pow, BitVec.toNat_ofNat, exactLen]
  change n = n % 2^32
  exact (Nat.mod_eq_of_lt (by omega)).symm

def signextendRef (ext value : Word) : Word :=
  if ext.toNat ≥ 31 then value
  else
    let bit := (ext.toNat * 8 + 7)
    let sign := (1 : Word) <<< bit
    let mask := sign - 1
    if value &&& sign ≠ 0 then value ||| ~~~mask else value &&& mask

def signextendFast (ext value : Word) : Word :=
  if ext.toNat ≥ 31 then value
  else
    let shift := (248 : BitVec 8) - (ext.setWidth 8 <<< 3)
    (value <<< shift.toNat).sshiftRight shift.toNat

private theorem signextendShift (value : Word) (b : Nat) (hb : b < 256) :
    (value <<< (255 - b)).sshiftRight (255 - b) =
      let sign := (1 : Word) <<< b
      let mask := sign - 1
      if value &&& sign ≠ 0 then value ||| ~~~mask else value &&& mask := by
  have signNat : ((1 : Word) <<< b).toNat = 2^b := by
    rw [BitVec.toNat_shiftLeft, Nat.shiftLeft_eq]
    change (1 * 2^b) % 2^256 = 2^b
    rw [Nat.one_mul, Nat.mod_eq_of_lt (Nat.pow_lt_pow_right (by decide) hb)]
  have maskNat : (((1 : Word) <<< b) - 1).toNat = 2^b - 1 := by
    rw [BitVec.toNat_sub_of_le, signNat]
    · rfl
    · change 1 ≤ ((1 : Word) <<< b).toNat
      rw [signNat]
      exact Nat.two_pow_pos b
  have signBit (i : Nat) : ((1 : Word) <<< b).getLsbD i = decide (b = i) := by
    rw [← BitVec.testBit_toNat, signNat, Nat.testBit_two_pow]
  have maskBit (i : Nat) : (((1 : Word) <<< b) - 1).getLsbD i = decide (i < b) := by
    rw [← BitVec.testBit_toNat, maskNat, Nat.testBit_two_pow_sub_one]
  have signTest : (value &&& ((1 : Word) <<< b) ≠ 0) ↔ value.getLsbD b = true := by
    constructor
    · intro hn
      cases hs : value.getLsbD b with
      | true => rfl
      | false =>
        exfalso
        apply hn
        apply BitVec.eq_of_getLsbD_eq
        intro i _
        change (value &&& ((1 : Word) <<< b)).getLsbD i = (0#256).getLsbD i
        by_cases hi : b = i
        · subst i
          simp only [BitVec.getLsbD_and, signBit, hs, Bool.false_and, BitVec.getLsbD_zero]
        · simp only [BitVec.getLsbD_and, signBit, hi, decide_false, Bool.and_false, BitVec.getLsbD_zero]
    · intro hs hz
      have atBit := congrArg (fun w : Word => w.getLsbD b) hz
      change (value &&& ((1 : Word) <<< b)).getLsbD b = (0#256).getLsbD b at atBit
      simp only [BitVec.getLsbD_and, signBit, decide_true, Bool.and_true, hs,
        BitVec.getLsbD_zero, Bool.true_eq_false] at atBit
  have shiftedSign : (value <<< (255 - b)).msb = value.getLsbD b := by
    rw [BitVec.msb_eq_getLsbD_last, BitVec.getLsbD_shiftLeft]
    change (decide (255 < 256) && !decide (255 < 255 - b) &&
      value.getLsbD (255 - (255 - b))) = _
    simp only [show ¬ 255 < 255 - b by omega, decide_false, Bool.not_false,
      show 255 - (255 - b) = b by omega]
    rfl
  simp only [signTest]
  apply BitVec.eq_of_getLsbD_eq
  intro i hi
  have out : ¬ 256 ≤ i := by omega
  rw [BitVec.getLsbD_sshiftRight, shiftedSign]
  simp only [out, decide_false, Bool.not_false, Bool.true_and]
  have shifted (low : i ≤ b) :
      (value <<< (255 - b)).getLsbD (255 - b + i) = value.getLsbD i := by
    rw [BitVec.getLsbD_shiftLeft]
    simp only [show 255 - b + i < 256 by omega, show ¬ 255 - b + i < 255 - b by omega,
      decide_true, decide_false, Bool.not_false, Bool.true_and, Nat.add_sub_cancel_left]
  by_cases low : i ≤ b
  · rw [if_pos (show 255 - b + i < 256 by omega), shifted low]
    by_cases eq : i = b
    · subst i
      cases value.getLsbD b <;>
        simp only [Bool.false_eq_true, if_false, if_true, BitVec.getLsbD_and,
          BitVec.getLsbD_or, BitVec.getLsbD_not, maskBit, Nat.lt_irrefl, hi,
          decide_true, decide_false, Bool.and_false, Bool.not_false, Bool.true_and, Bool.or_true]
    · cases value.getLsbD b <;>
        simp only [Bool.false_eq_true, if_false, if_true, BitVec.getLsbD_and,
          BitVec.getLsbD_or, BitVec.getLsbD_not, maskBit, show i < b by omega, hi,
          decide_true, Bool.not_true, Bool.and_true, Bool.and_false, Bool.or_false]
  · rw [if_neg (show ¬ 255 - b + i < 256 by omega)]
    cases value.getLsbD b <;>
      simp only [Bool.false_eq_true, if_false, if_true, BitVec.getLsbD_and,
        BitVec.getLsbD_or, BitVec.getLsbD_not, maskBit, hi, show ¬ i < b by omega,
        decide_true, decide_false, Bool.not_false, Bool.and_true, Bool.and_false, Bool.or_true]

theorem signextendFast_eq_ref (ext value : Word) : signextendFast ext value = signextendRef ext value := by
  unfold signextendFast signextendRef
  split
  · rfl
  · rename_i h
    have width : (ext.setWidth 8).toNat = ext.toNat := by
      rw [BitVec.toNat_setWidth, Nat.mod_eq_of_lt (by omega)]
    have times : (ext.setWidth 8 <<< 3).toNat = ext.toNat * 8 := by
      rw [BitVec.toNat_shiftLeft, Nat.shiftLeft_eq, width]
      exact Nat.mod_eq_of_lt (by omega)
    have shift : ((248 : BitVec 8) - (ext.setWidth 8 <<< 3)).toNat =
        255 - (ext.toNat * 8 + 7) := by
      rw [BitVec.toNat_sub_of_le, times]
      · change 248 - ext.toNat * 8 = _
        omega
      · exact show (ext.setWidth 8 <<< 3).toNat ≤ (248 : BitVec 8).toNat by change (ext.setWidth 8 <<< 3).toNat ≤ 248; rw [times]; omega
    dsimp only
    rw [shift]
    exact signextendShift value _ (by omega)

def sarRef (shift value : Word) : Word :=
  if shift.toNat ≥ 256 then if value.msb then BitVec.allOnes 256 else 0
  else value.sshiftRight shift.toNat

def sarFast (shift value : Word) : Word :=
  value.sshiftRight ((if shift.toNat ≥ 255 then 255 else shift.setWidth 8 : BitVec 8).toNat)

private theorem sar_at_sign (v : Word) :
    v.sshiftRight 255 = if v.msb then BitVec.allOnes 256 else 0#256 := by
  apply BitVec.eq_of_getLsbD_eq
  intro i hi
  rw [BitVec.getLsbD_sshiftRight]
  have inside : ¬ 256 ≤ i := by omega
  have fromSign : (if 255 + i < 256 then v.getLsbD (255 + i) else v.msb) = v.msb := by
    split
    · rw [show 255 + i = 255 by omega]
      exact (BitVec.msb_eq_getLsbD_last v).symm
    · rfl
  rw [fromSign]
  cases v.msb <;> simp only [inside, decide_false, Bool.not_false, Bool.true_and,
    Bool.false_eq_true, if_false, if_true, BitVec.getLsbD_allOnes, BitVec.getLsbD_zero, hi,
    decide_true]

theorem sarFast_eq_ref (shift value : Word) : sarFast shift value = sarRef shift value := by
  unfold sarFast sarRef
  by_cases big : 256 ≤ shift.toNat
  · rw [if_pos big, if_pos (show 255 ≤ shift.toNat by omega)]
    exact sar_at_sign value
  · rw [if_neg big]
    by_cases last : 255 ≤ shift.toNat
    · rw [if_pos last, show shift.toNat = 255 by omega]
      rfl
    · rw [if_neg last, BitVec.toNat_setWidth, Nat.mod_eq_of_lt (by omega)]

def byteRef (index value : Word) : Word :=
  if index.toNat ≥ 32 then 0 else (value >>> ((31 - index.toNat) * 8)) &&& 0xFF

def byteFast (index value : Word) : Word :=
  if index.toNat ≥ 32 then 0
  else (value >>> (((31 : BitVec 8) - index.setWidth 8) <<< 3).toNat) &&& 0xFF

theorem byteFast_eq_ref (index value : Word) : byteFast index value = byteRef index value := by
  unfold byteFast byteRef
  split
  · rfl
  · rename_i h
    have width : (index.setWidth 8).toNat = index.toNat := by
      rw [BitVec.toNat_setWidth, Nat.mod_eq_of_lt (by omega)]
    have shift : ((((31 : BitVec 8) - index.setWidth 8) <<< 3)).toNat =
        (31 - index.toNat) * 8 := by
      rw [BitVec.toNat_shiftLeft, Nat.shiftLeft_eq, BitVec.toNat_sub_of_le, width]
      · exact Nat.mod_eq_of_lt (by change (31 - index.toNat) * 8 < 256; omega)
      · exact show (index.setWidth 8).toNat ≤ (31 : BitVec 8).toNat by change (index.setWidth 8).toNat ≤ 31; rw [width]; omega
    rw [shift]

def clzRef (value : Word) : Word := if value = 0 then 256 else value.clz
def clzFast (value : Word) : Word := value.clz

theorem clzFast_eq_ref (value : Word) : clzFast value = clzRef value := by
  unfold clzFast clzRef
  split
  · rename_i h
    exact BitVec.clz_eq_iff_eq_zero.mpr h
  · rfl

def absTwoComp (x : Word) : Word :=
  let mask := 0 - (x >>> 255)
  (x ^^^ mask) - mask

def signedAbs (x : Word) : Word := if x.msb then -x else x

private theorem signWord (x : Word) :
    x >>> 255 = if x.msb then 1 else 0 := by
  change x >>> (255 : BitVec 8).toNat = _
  apply BitVec.eq_of_getLsbD_eq
  intro i hi
  rw [BitVec.getLsbD_ushiftRight]
  change x.getLsbD (255 + i) = _
  by_cases zero : i = 0
  · subst i
    rw [show x.getLsbD (255 + 0) = x.msb from (BitVec.msb_eq_getLsbD_last x).symm]
    cases x.msb <;> decide
  · rw [BitVec.getLsbD_of_ge (x := x) (i := 255 + i) (by omega)]
    cases x.msb
    · exact (BitVec.getLsbD_zero (w := 256) (i := i)).symm
    · simp only [if_true]
      change false = (2^0 : Nat).testBit i
      rw [Nat.testBit_two_pow_of_ne (n := 0) (by omega)]

private theorem applyNegativeMask (x : Word) :
    (x ^^^ BitVec.allOnes 256) - BitVec.allOnes 256 = -x := by
  rw [BitVec.xor_allOnes, BitVec.sub_eq_add_neg, ← BitVec.neg_one_eq_allOnes, BitVec.neg_neg]
  exact (BitVec.neg_eq_not_add x).symm

theorem absTwoComp_eq_abs (x : Word) : absTwoComp x = signedAbs x := by
  unfold absTwoComp signedAbs
  rw [signWord]
  cases x.msb
  · simp
  · exact applyNegativeMask x

theorem absTwoComp_toNat_eq_natAbs (x : Word) : (absTwoComp x).toNat = x.toInt.natAbs := by
  rw [absTwoComp_eq_abs]
  unfold signedAbs
  cases h : x.msb
  · rw [BitVec.toInt_eq_toNat_of_msb h]
    rfl
  · rw [BitVec.toInt_eq_neg_toNat_neg_of_msb_true h]
    change (-x).toNat = (-(Int.ofNat (-x).toNat)).natAbs
    rw [Int.natAbs_neg]
    rfl

def sdivFromUnsignedQuotient (top second q : Word) : Word :=
  let mask := 0 - ((top >>> 255) ^^^ (second >>> 255))
  (q ^^^ mask) - mask

def smodFromUnsignedRem (top r : Word) : Word :=
  let mask := 0 - (top >>> 255)
  (r ^^^ mask) - mask

/-- Zig's unsigned wrapping remainder uses zero for a zero divisor. -/
def wrappingRem (x y : Word) : Word := if y = 0 then 0 else x % y

def sdivFast (top second : Word) : Word :=
  sdivFromUnsignedQuotient top second (absTwoComp top / absTwoComp second)

def smodFast (top second : Word) : Word :=
  smodFromUnsignedRem top (wrappingRem (absTwoComp top) (absTwoComp second))

def smodRef (top second : Word) : Word := if second = 0 then 0 else top.srem second

theorem sdivFast_eq_ref (top second : Word) : sdivFast top second = top.sdiv second := by
  rw [sdivFast, sdivFromUnsignedQuotient, signWord top, signWord second,
    absTwoComp_eq_abs, absTwoComp_eq_abs, BitVec.sdiv_eq]
  unfold signedAbs
  cases top.msb <;> cases second.msb <;> first | rfl | apply applyNegativeMask | simp

theorem smodFast_zero (top : Word) : smodFast top 0 = 0 := by
  rw [smodFast, smodFromUnsignedRem, signWord]
  have zeroAbs : absTwoComp (0 : Word) = 0 := by decide
  rw [zeroAbs]
  cases top.msb <;> simp [wrappingRem]

theorem smodFast_eq_ref (top second : Word) : smodFast top second = smodRef top second := by
  by_cases hz : second = 0
  · subst second
    simpa [smodRef] using smodFast_zero top
  · have absNonzero : absTwoComp second ≠ 0 := by
      rw [absTwoComp_eq_abs]
      unfold signedAbs
      cases second.msb
      · exact hz
      · exact fun hn => hz (BitVec.neg_eq_zero_iff.mp hn)
    rw [smodFast, smodFromUnsignedRem, wrappingRem, if_neg absNonzero, signWord,
      absTwoComp_eq_abs, absTwoComp_eq_abs, smodRef, if_neg hz, BitVec.srem_eq]
    unfold signedAbs
    cases top.msb <;> cases second.msb <;> first | rfl | apply applyNegativeMask | simp

theorem sdivFast_zero (top : Word) : sdivFast top 0 = 0 := by
  exact (sdivFast_eq_ref top 0).trans BitVec.sdiv_zero

theorem sdivFast_min_neg_one : sdivFast (BitVec.intMin 256) (-1) = BitVec.intMin 256 := by
  decide

theorem smodFast_min_neg_one : smodFast (BitVec.intMin 256) (-1) = 0 := by
  decide

end GuillotineVerify.Arithmetic
