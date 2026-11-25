import Std

namespace GuillotineVerify.Fusions

abbrev Word := BitVec 256

inductive Bin where
  | add | sub | mul | and | or | xor

def Bin.eval (op : Bin) (top second : Word) : Word :=
  match op with
  | .add => top + second
  | .sub => top - second
  | .mul => top * second
  | .and => top &&& second
  | .or => top ||| second
  | .xor => top ^^^ second

/-- The stack head is the EVM top. Control records a taken jump or fallthrough.
    Static gas is checked by the block model before fusion execution. -/
structure State where
  stack : List Word
  capacity : Nat := 1024
  validJump : Word → Bool
  jumpTarget : Option Word := none

inductive Fault where
  | StackUnderflow | StackOverflow | InvalidJump

inductive Op where
  | push (value : Word)
  | bin (op : Bin)
  | iszero | jumpi | dup1 | dup2 | swap1

def push (s : State) (v : Word) : Except Fault State :=
  if s.capacity ≤ s.stack.length then .error .StackOverflow
  else .ok { s with stack := v :: s.stack }

def jump (s : State) (target : Word) (taken : Bool) : Except Fault State :=
  if taken then
    if s.validJump target then .ok { s with jumpTarget := some target }
    else .error .InvalidJump
  else .ok { s with jumpTarget := none }

def step (op : Op) (s : State) : Except Fault State :=
  match op, s.stack with
  | .push v, _ => push s v
  | .bin op, a :: b :: tail => .ok { s with stack := op.eval a b :: tail }
  | .iszero, a :: tail => .ok { s with stack := (if a = 0 then 1 else 0) :: tail }
  | .jumpi, dest :: cond :: tail => jump { s with stack := tail } dest (cond != 0)
  | .dup1, a :: _ => push s a
  | .dup2, _ :: b :: _ => push s b
  | .swap1, a :: b :: tail => .ok { s with stack := b :: a :: tail }
  | _, _ => .error .StackUnderflow

def execSeq : List Op → State → Except Fault State
  | [], s => .ok s
  | op :: ops, s => match step op s with
    | .error e => .error e
    | .ok next => execSeq ops next

inductive Fusion where
  | pushBin (v : Word) (op : Bin)
  | iszeroPushJumpi (target : Word)
  | pushAddDup1 (v : Word)
  | swap1Dup2Add
  | constFold (a b : BitVec 8) (op : Bin)

def Fusion.ops : Fusion → List Op
  | .pushBin v op => [.push v, .bin op]
  | .iszeroPushJumpi target => [.iszero, .push target, .jumpi]
  | .pushAddDup1 v => [.push v, .bin .add, .dup1]
  | .swap1Dup2Add => [.swap1, .dup2, .bin .add]
  | .constFold a b op => [.push (a.zeroExtend 256), .push (b.zeroExtend 256), .bin op]

/-- Checked macro-steps. The guards preserve the original sequence's first stack
    fault, including peak stack heights that the optimized data path elides. -/
def execFused (fusion : Fusion) (s : State) : Except Fault State :=
  match fusion, s.stack with
  | .pushBin v op, stack =>
    if s.capacity ≤ stack.length then .error .StackOverflow
    else match stack with
      | [] => .error .StackUnderflow
      | a :: tail => .ok { s with stack := op.eval v a :: tail }
  | .iszeroPushJumpi dest, a :: tail =>
    if s.capacity ≤ s.stack.length then .error .StackOverflow
    else jump { s with stack := tail } dest (a == 0)
  | .pushAddDup1 v, stack =>
    if s.capacity ≤ stack.length then .error .StackOverflow
    else match stack with
      | [] => .error .StackUnderflow
      | a :: tail =>
        let r := v + a
        .ok { s with stack := r :: r :: tail }
  | .swap1Dup2Add, a :: b :: tail =>
    if s.capacity ≤ s.stack.length then .error .StackOverflow
    else .ok { s with stack := (a + b) :: a :: tail }
  | .constFold a b op, stack =>
    if s.capacity ≤ stack.length + 1 then .error .StackOverflow
    else .ok { s with stack := op.eval (b.zeroExtend 256) (a.zeroExtend 256) :: stack }
  | _, _ => .error .StackUnderflow

theorem execFused_eq_execSeq (f : Fusion) (s : State) :
    execFused f s = execSeq f.ops s := by
  obtain ⟨stack, cap, valid, target⟩ := s
  cases f with
  | pushBin v op =>
    cases stack <;> simp [Fusion.ops, execFused, execSeq, step, push] <;> split <;> rfl
  | iszeroPushJumpi dest =>
    cases stack with
    | nil => rfl
    | cons a tail =>
      by_cases full : cap ≤ tail.length + 1
      · simp [Fusion.ops, execFused, execSeq, step, push, full]
      · by_cases z : a = 0#256 <;> by_cases ok : valid dest = true <;>
          simp [Fusion.ops, execFused, execSeq, step, push, jump, full, z, ok]
  | pushAddDup1 v =>
    cases stack with
    | nil =>
      by_cases full : cap ≤ 0 <;> simp [Fusion.ops, execFused, execSeq, step, push, full]
    | cons a tail =>
      by_cases full : cap ≤ tail.length + 1 <;>
        simp [Fusion.ops, execFused, execSeq, step, push, full, Bin.eval]
  | swap1Dup2Add =>
    cases stack with
    | nil => rfl
    | cons a tail =>
      cases tail with
      | nil => rfl
      | cons b tail =>
        simp [Fusion.ops, execFused, execSeq, step, push]
        split <;> rfl
  | constFold a b op =>
    by_cases first : cap ≤ stack.length
    · have second : cap ≤ stack.length + 1 := by omega
      simp [Fusion.ops, execFused, execSeq, step, push, first, second]
    · by_cases second : cap ≤ stack.length + 1 <;>
        simp [Fusion.ops, execFused, execSeq, step, push, first, second]

theorem push_add_sound (v : Word) (s : State) :
    execFused (.pushBin v .add) s = execSeq [.push v, .bin .add] s :=
  execFused_eq_execSeq _ _
theorem push_sub_sound (v : Word) (s : State) :
    execFused (.pushBin v .sub) s = execSeq [.push v, .bin .sub] s :=
  execFused_eq_execSeq _ _
theorem push_mul_sound (v : Word) (s : State) :
    execFused (.pushBin v .mul) s = execSeq [.push v, .bin .mul] s :=
  execFused_eq_execSeq _ _
theorem push_and_sound (v : Word) (s : State) :
    execFused (.pushBin v .and) s = execSeq [.push v, .bin .and] s :=
  execFused_eq_execSeq _ _
theorem push_or_sound (v : Word) (s : State) :
    execFused (.pushBin v .or) s = execSeq [.push v, .bin .or] s :=
  execFused_eq_execSeq _ _
theorem push_xor_sound (v : Word) (s : State) :
    execFused (.pushBin v .xor) s = execSeq [.push v, .bin .xor] s :=
  execFused_eq_execSeq _ _
theorem iszero_push_jumpi_sound (dest : Word) (s : State) :
    execFused (.iszeroPushJumpi dest) s = execSeq [.iszero, .push dest, .jumpi] s :=
  execFused_eq_execSeq _ _
theorem push_add_dup1_sound (v : Word) (s : State) :
    execFused (.pushAddDup1 v) s = execSeq [.push v, .bin .add, .dup1] s :=
  execFused_eq_execSeq _ _
theorem swap1_dup2_add_sound (s : State) :
    execFused .swap1Dup2Add s = execSeq [.swap1, .dup2, .bin .add] s :=
  execFused_eq_execSeq _ _

theorem const_fold_add_sound (a b : BitVec 8) (s : State) :
    execFused (.constFold a b .add) s =
      execSeq [.push (a.zeroExtend 256), .push (b.zeroExtend 256), .bin .add] s :=
  execFused_eq_execSeq _ _
theorem const_fold_sub_sound (a b : BitVec 8) (s : State) :
    execFused (.constFold a b .sub) s =
      execSeq [.push (a.zeroExtend 256), .push (b.zeroExtend 256), .bin .sub] s :=
  execFused_eq_execSeq _ _
theorem const_fold_mul_sound (a b : BitVec 8) (s : State) :
    execFused (.constFold a b .mul) s =
      execSeq [.push (a.zeroExtend 256), .push (b.zeroExtend 256), .bin .mul] s :=
  execFused_eq_execSeq _ _

theorem const_fold_sub_order (a b : BitVec 8) (s : State) (room : s.stack.length + 1 < s.capacity) :
    execFused (.constFold a b .sub) s =
      .ok { s with stack := (b.zeroExtend 256 - a.zeroExtend 256) :: s.stack } := by
  cases s
  simp [execFused, Nat.not_le.mpr room, Bin.eval]

end GuillotineVerify.Fusions
