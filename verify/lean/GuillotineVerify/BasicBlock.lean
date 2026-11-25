import Std

namespace GuillotineVerify.BasicBlock

inductive BlockOp where
  | regular (inputs outputs gas : Nat)
  | dup (n gas : Nat)
  | swap (n gas : Nat)
  | push (gas : Nat)

def BlockOp.inputs : BlockOp → Nat
  | .regular i _ _ => i
  | .dup n _ => n
  | .swap n _ => n + 1
  | .push _ => 0

def BlockOp.outputs : BlockOp → Nat
  | .regular _ o _ => o
  | .dup n _ => n + 1
  | .swap n _ => n + 1
  | .push _ => 1

def BlockOp.gas : BlockOp → Nat
  | .regular _ _ g | .dup _ g | .swap _ g | .push g => g

/-- Exact accumulator. Fixed-width gas and metadata are projections of these quantities.
    Signed stack arithmetic models Zig whenever its intermediate i32 operations fit. -/
structure BlockAccumulator where
  gas : Nat := 0
  stackEffect : Int := 0
  minStack : Int := 0
  maxStack : Int := 0

def BlockAccumulator.step (a : BlockAccumulator) (op : BlockOp) : BlockAccumulator :=
  let low := a.stackEffect - op.inputs
  let high := low + op.outputs
  match op with
  | .push _ => ⟨a.gas + op.gas, high, a.minStack, max a.maxStack high⟩
  | .swap .. => ⟨a.gas + op.gas, a.stackEffect, min a.minStack low, a.maxStack⟩
  | _ => ⟨a.gas + op.gas, high, min a.minStack low, max a.maxStack high⟩

def BlockAccumulator.scan (a : BlockAccumulator) (ops : List BlockOp) :=
  ops.foldl BlockAccumulator.step a

def accumulate (ops : List BlockOp) := ({} : BlockAccumulator).scan ops

def BlockAccumulator.requiredMinStack (a : BlockAccumulator) := max 0 (-a.minStack)
def BlockAccumulator.requiredMaxStack (a : BlockAccumulator) := max 0 a.maxStack
def BlockAccumulator.gasU64 (a : BlockAccumulator) := min a.gas (2^64 - 1)

theorem gasU64_step (a : BlockAccumulator) (op : BlockOp) :
    (a.step op).gasU64 = min (a.gasU64 + op.gas) (2^64 - 1) := by
  cases op <;> simp [BlockAccumulator.step, BlockAccumulator.gasU64] <;> omega

/-- Witnesses every opcode boundary and each opcode's pop/read, push and gas checks. -/
inductive Runs (cap : Int) : List BlockOp → Int → Nat → Prop where
  | nil : 0 ≤ h → h ≤ cap → Runs cap [] h gas
  | cons : 0 ≤ h → h ≤ cap → (op.inputs : Int) ≤ h →
      h - op.inputs + op.outputs ≤ cap → op.gas ≤ gas →
      Runs cap ops (h - op.inputs + op.outputs) (gas - op.gas) →
      Runs cap (op :: ops) h gas

private theorem step_monotone (a : BlockAccumulator) (op : BlockOp) :
    (a.step op).minStack ≤ a.minStack ∧ a.maxStack ≤ (a.step op).maxStack ∧
    a.gas ≤ (a.step op).gas := by
  cases op <;> simp [BlockAccumulator.step] <;> omega

private theorem scan_monotone (ops : List BlockOp) (a : BlockAccumulator) :
    (a.scan ops).minStack ≤ a.minStack ∧ a.maxStack ≤ (a.scan ops).maxStack ∧
    a.gas ≤ (a.scan ops).gas := by
  induction ops generalizing a with
  | nil => simp [BlockAccumulator.scan]
  | cons op ops ih =>
    have ⟨hm, hx, hg⟩ := step_monotone a op
    have ⟨sm, sx, sg⟩ := ih (a.step op)
    exact ⟨Int.le_trans sm hm, Int.le_trans hx sx, Nat.le_trans hg sg⟩

private theorem scan_sound (ops : List BlockOp) (a : BlockAccumulator) (h cap : Int)
    (gas : Nat) (lo : 0 ≤ h + a.stackEffect) (hi : h + a.stackEffect ≤ cap)
    (hm : 0 ≤ h + (a.scan ops).minStack)
    (hx : h + (a.scan ops).maxStack ≤ cap)
    (hg : (a.scan ops).gas ≤ gas) :
    Runs cap ops (h + a.stackEffect) (gas - a.gas) := by
  induction ops generalizing a with
  | nil => exact .nil lo hi
  | cons op ops ih =>
    change 0 ≤ h + ((a.step op).scan ops).minStack at hm
    change h + ((a.step op).scan ops).maxStack ≤ cap at hx
    change ((a.step op).scan ops).gas ≤ gas at hg
    have ⟨sm, sx, sg⟩ := scan_monotone ops (a.step op)
    have lowerStep : 0 ≤ h + (a.step op).minStack := by omega
    have upperStep : h + (a.step op).maxStack ≤ cap := by omega
    have need : (op.inputs : Int) ≤ h + a.stackEffect := by
      cases op <;> simp [BlockAccumulator.step, BlockOp.inputs] at lowerStep ⊢ <;> omega
    have effect : (a.step op).stackEffect = a.stackEffect - op.inputs + op.outputs := by
      cases op <;> simp [BlockAccumulator.step, BlockOp.inputs, BlockOp.outputs] <;> omega
    have upper : h + (a.step op).stackEffect ≤ cap := by
      cases op <;> simp [BlockAccumulator.step] at upperStep ⊢ <;> omega
    have cost : (a.step op).gas = a.gas + op.gas := by
      cases op <;> rfl
    have tail := ih (a.step op) (by rw [effect]; omega) upper hm hx hg
    rw [effect, cost] at tail
    exact .cons lo hi need (by rw [effect] at upper; omega) (by omega)
      (by rw [show h + a.stackEffect - op.inputs + op.outputs =
        h + (a.stackEffect - op.inputs + op.outputs) by omega, Nat.sub_sub]; exact tail)

theorem block_sound (ops : List BlockOp) (h cap : Int) (entryGas : Nat)
    (hm : (accumulate ops).requiredMinStack ≤ h)
    (hx : h + (accumulate ops).requiredMaxStack ≤ cap)
    (hg : (accumulate ops).gas ≤ entryGas) :
    Runs cap ops h entryGas := by
  have result := scan_sound ops {} h cap entryGas (by simp; unfold BlockAccumulator.requiredMinStack at hm; omega)
    (by simp; unfold BlockAccumulator.requiredMaxStack at hx; omega)
    (by unfold BlockAccumulator.requiredMinStack at hm; change 0 ≤ h + (accumulate ops).minStack; omega)
    (by unfold BlockAccumulator.requiredMaxStack at hx; change h + (accumulate ops).maxStack ≤ cap; omega) hg
  simpa using result

theorem block_sound_of_unsaturated_gas (ops : List BlockOp) (h cap : Int) (entryGas : Nat)
    (hm : (accumulate ops).requiredMinStack ≤ h)
    (hx : h + (accumulate ops).requiredMaxStack ≤ cap)
    (hg : (accumulate ops).gasU64 ≤ entryGas)
    (exactGas : (accumulate ops).gas ≤ 2^64 - 1 ∨ entryGas < 2^64 - 1) :
    Runs cap ops h entryGas := by
  apply block_sound ops h cap entryGas hm hx
  unfold BlockAccumulator.gasU64 at hg
  omega

/-- Saturated metadata alone cannot guarantee enough gas for an arbitrary list. -/
theorem saturated_gas_counterexample :
    let ops := [BlockOp.regular 0 0 (2^64 - 1), BlockOp.regular 0 0 1]
    (accumulate ops).gasU64 = 2^64 - 1 ∧ ¬ Runs 0 ops 0 (2^64 - 1) := by
  dsimp
  constructor
  · decide
  · intro run
    cases run with
    | cons _ _ _ _ _ tail =>
      cases tail with
      | cons _ _ _ _ gas _ => simp [BlockOp.gas] at gas

inductive StackGuard where
  | ok | underflow | overflow
  deriving DecidableEq

def blockStackGuardRef (size : BitVec 32) (mn mx : BitVec 16) (cap : BitVec 32) : StackGuard :=
  if size.toNat < mn.toNat then .underflow
  else if size.toNat + mx.toNat > cap.toNat then .overflow
  else .ok

def blockStackGuardFast (size : BitVec 32) (mn mx : BitVec 16) (cap : BitVec 32) : StackGuard :=
  let needed := mn.toNat + mx.toNat
  if needed ≤ cap.toNat ∧ (size - mn.zeroExtend 32).toNat ≤ cap.toNat - needed then .ok
  else if size.toNat < mn.toNat then .underflow else .overflow

theorem blockStackGuardFast_eq_ref (size : BitVec 32) (mn mx : BitVec 16) (cap : BitVec 32) :
    blockStackGuardFast size mn mx cap = blockStackGuardRef size mn mx cap := by
  have hs := size.isLt
  have hc := cap.isLt
  have hm := mn.isLt
  unfold blockStackGuardFast blockStackGuardRef
  simp only [BitVec.toNat_sub, BitVec.zeroExtend, BitVec.toNat_setWidth, Nat.mod_eq_of_lt (show mn.toNat < 2^32 by omega)]
  have hw : (2^32 - mn.toNat + size.toNat) % 2^32 =
      if mn.toNat ≤ size.toNat then size.toNat - mn.toNat else 2^32 - mn.toNat + size.toNat := by
    split
    · rw [show 2^32 - mn.toNat + size.toNat = (size.toNat - mn.toNat) + 2^32 by omega,
        Nat.add_mod_right, Nat.mod_eq_of_lt (by omega)]
    · exact Nat.mod_eq_of_lt (by omega)
  rw [hw]
  repeat' split
  all_goals first | rfl | omega

/-- Either signed or unsigned metadata clamp safely rejects an impossible bound,
    provided the representation can hold at least one more than the capacity. -/
theorem clampedMinMax_sound (a : BlockAccumulator) (h cap bound : Int)
    (physical : 0 ≤ h ∧ h ≤ cap) (_width : bound = 65535 ∨ bound = 32767)
    (fits : cap + 1 ≤ bound) :
    (cap + 1 ≤ a.requiredMinStack →
      h < min a.requiredMinStack bound) ∧
    (cap + 1 ≤ a.requiredMaxStack →
      cap < h + min a.requiredMaxStack bound) := by omega

end GuillotineVerify.BasicBlock
