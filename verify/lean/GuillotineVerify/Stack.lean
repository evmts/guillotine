import GuillotineVerify.BasicBlock

namespace GuillotineVerify.Stack

open BasicBlock

structure PointerStack where
  limit : Int
  base : Int
  ptr : Int

def PointerStack.Valid (s : PointerStack) : Prop :=
  0 ≤ s.limit ∧ s.limit ≤ s.ptr ∧ s.ptr ≤ s.base ∧
    (s.base - s.ptr) % 32 = 0 ∧ (s.base - s.limit) % 32 = 0

def PointerStack.size (s : PointerStack) : Int := (s.base - s.ptr) / 32
def PointerStack.capacity (s : PointerStack) : Int := (s.base - s.limit) / 32
def PointerStack.replace (s : PointerStack) (inputs outputs : Nat) : PointerStack :=
  { s with ptr := s.ptr + 32 * (inputs : Int) - 32 * (outputs : Int) }

def PointerStack.push (s : PointerStack) := s.replace 0 1
def PointerStack.pop (s : PointerStack) := s.replace 1 0
def PointerStack.binary_op (s : PointerStack) := s.replace 2 1
def PointerStack.dup_n (s : PointerStack) := s.push
def PointerStack.swap_n (s : PointerStack) := s

/-- The entire 32-byte slot is inside the live stack. -/
def PointerStack.LiveSlot (s : PointerStack) (index : Nat) : Prop :=
  s.ptr ≤ s.ptr + 32 * (index : Int) ∧ s.limit ≤ s.ptr + 32 * (index : Int) ∧
    s.ptr + 32 * (index : Int) + 32 ≤ s.base ∧
    (s.base - (s.ptr + 32 * (index : Int))) % 32 = 0

theorem liveSlot_in_bounds (s : PointerStack) (valid : s.Valid) (index : Nat)
    (readable : (index : Int) < s.size) : s.LiveSlot index := by
  unfold PointerStack.Valid at valid
  unfold PointerStack.size at readable
  unfold PointerStack.LiveSlot
  omega

/-- Refines the block's input-depth and output-height checks to byte addresses. -/
theorem replace_preserves (s : PointerStack) (inputs outputs : Nat) (valid : s.Valid)
    (need : (inputs : Int) ≤ s.size)
    (room : s.size - inputs + outputs ≤ s.capacity) :
    (s.replace inputs 0).Valid ∧ (s.replace inputs outputs).Valid ∧
    (s.replace inputs outputs).size = s.size - inputs + outputs := by
  simp only [PointerStack.Valid, PointerStack.size, PointerStack.capacity, PointerStack.replace] at *
  omega

theorem push_preserves (s : PointerStack) (valid : s.Valid) (room : s.size + 1 ≤ s.capacity) :
    s.push.Valid ∧ s.push.size = s.size + 1 := by
  have nonempty : 0 ≤ s.size := by
    unfold PointerStack.Valid at valid
    unfold PointerStack.size
    omega
  simpa [PointerStack.push] using (replace_preserves s 0 1 valid nonempty (by simpa using room)).2

theorem pop_preserves (s : PointerStack) (valid : s.Valid) (need : 1 ≤ s.size) :
    s.LiveSlot 0 ∧ s.pop.Valid ∧ s.pop.size = s.size - 1 := by
  have room : s.size - 1 ≤ s.capacity := by
    unfold PointerStack.Valid at valid
    unfold PointerStack.size PointerStack.capacity
    omega
  exact ⟨liveSlot_in_bounds s valid 0 (by omega), by
    simpa [PointerStack.pop] using (replace_preserves s 1 0 valid need (by simpa using room)).2⟩

theorem binary_op_preserves (s : PointerStack) (valid : s.Valid) (need : 2 ≤ s.size) :
    s.LiveSlot 0 ∧ s.LiveSlot 1 ∧ s.binary_op.Valid ∧ s.binary_op.size = s.size - 1 := by
  have room : s.size - 2 + 1 ≤ s.capacity := by
    unfold PointerStack.Valid at valid
    unfold PointerStack.size PointerStack.capacity
    omega
  have ⟨_, ok, size⟩ := replace_preserves s 2 1 valid need room
  exact ⟨liveSlot_in_bounds s valid 0 (by omega), liveSlot_in_bounds s valid 1 (by omega),
    ok, by change (s.replace 2 1).size = _; omega⟩

theorem dup_n_preserves (s : PointerStack) (n : Nat) (valid : s.Valid)
    (nonzero : 1 ≤ n) (need : (n : Int) ≤ s.size) (room : s.size + 1 ≤ s.capacity) :
    s.LiveSlot (n - 1) ∧ s.dup_n.Valid ∧ s.dup_n.size = s.size + 1 :=
  ⟨liveSlot_in_bounds s valid (n - 1) (by omega), push_preserves s valid room⟩

theorem swap_n_preserves (s : PointerStack) (n : Nat) (valid : s.Valid)
    (need : (n : Int) + 1 ≤ s.size) :
    s.LiveSlot 0 ∧ s.LiveSlot n ∧ s.swap_n.Valid ∧ s.swap_n.size = s.size :=
  ⟨liveSlot_in_bounds s valid 0 (by omega), liveSlot_in_bounds s valid n (by omega), valid, rfl⟩

def PointerStack.step (s : PointerStack) (op : BlockOp) : PointerStack :=
  match op with
  | .regular i o _ => s.replace i o
  | .push _ => s.push
  | .dup .. => s.dup_n
  | .swap .. => s.swap_n

private theorem step_eq_replace (s : PointerStack) (op : BlockOp) :
    s.step op = s.replace op.inputs op.outputs := by
  cases op with
  | regular => rfl
  | push => rfl
  | dup n _ =>
    change { s with ptr := s.ptr + 32 * (0 : Int) - 32 * (1 : Int) } =
      { s with ptr := s.ptr + 32 * (n : Int) - 32 * ((n + 1 : Nat) : Int) }
    have eq : s.ptr + 32 * (0 : Int) - 32 * (1 : Int) =
        s.ptr + 32 * (n : Int) - 32 * ((n + 1 : Nat) : Int) := by omega
    exact congrArg (fun p => { s with ptr := p }) eq
  | swap n _ =>
    change { s with ptr := s.ptr } =
      { s with ptr := s.ptr + 32 * ((n + 1 : Nat) : Int) - 32 * ((n + 1 : Nat) : Int) }
    have eq : s.ptr = s.ptr + 32 * ((n + 1 : Nat) : Int) - 32 * ((n + 1 : Nat) : Int) := by omega
    exact congrArg (fun p => { s with ptr := p }) eq

/-- Every successive pointer is valid, and every required input slot is live. -/
inductive PointerRuns : List BlockOp → PointerStack → Prop
  | nil : s.Valid → PointerRuns [] s
  | cons : s.Valid → (∀ i, i < op.inputs → s.LiveSlot i) →
      PointerRuns ops (s.step op) → PointerRuns (op :: ops) s

private theorem pointerRuns_of_runs (s : PointerStack) (ops : List BlockOp) (height cap : Int)
    (gas : Nat) (run : Runs cap ops height gas) (valid : s.Valid)
    (hs : s.size = height) (hc : s.capacity = cap) : PointerRuns ops s := by
  induction run generalizing s with
  | nil => exact .nil valid
  | @cons h capGas rest op _ _ need room _ _ ih =>
    have ⟨_, safe, size⟩ := replace_preserves s op.inputs op.outputs valid
      (by omega) (by omega)
    apply PointerRuns.cons valid (fun i hi => liveSlot_in_bounds s valid i (by omega))
    rw [step_eq_replace]
    exact ih _ safe (by omega) hc

theorem stack_block_preserves (s : PointerStack) (ops : List BlockOp) (gas : Nat)
    (valid : s.Valid) (need : (accumulate ops).requiredMinStack ≤ s.size)
    (room : s.size + (accumulate ops).requiredMaxStack ≤ s.capacity)
    (enough : (accumulate ops).gas ≤ gas) : PointerRuns ops s :=
  pointerRuns_of_runs s ops s.size s.capacity gas
    (block_sound ops s.size s.capacity gas need room enough) valid rfl rfl

end GuillotineVerify.Stack
