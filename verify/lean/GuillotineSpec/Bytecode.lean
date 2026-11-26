/-
  GuillotineSpec.Bytecode

  Reference bytecode analysis.

  * Yellow Paper section 9.4.3 JUMPDEST validity: a `0x5b` byte is a valid jump
    destination only when it is an instruction, not PUSH immediate data.
  * PUSH immediates that run past the end of the code read as zero.
  * Guillotine's basic-block batching (`src/bytecode/bytecode.zig`
    `calculateBlockInfo`, `src/core/verified_ops.zig` `BlockAccumulator`): the
    static gas of a block and the stack depth it needs (`minStack`) and adds
    (`maxStack`) are computed once, so the dispatch loop checks them at block
    entry instead of per instruction.
  * A straight-line evaluator that defines what any constant-folded or fused
    instruction sequence must compute.
-/
import GuillotineSpec.Hex
import GuillotineSpec.Word256
import GuillotineSpec.Gas

namespace GuillotineSpec
namespace Bytecode

/-! ### Opcode metadata -/

/-- Fork that introduced an opcode; `none` for undefined opcodes (including `0xfe` INVALID). -/
def introducedIn (op : Nat) : Option Fork :=
  if op ≤ 0x0b then some .frontier
  else if 0x10 ≤ op ∧ op ≤ 0x1a then some .frontier
  else if 0x1b ≤ op ∧ op ≤ 0x1d then some .constantinople
  else if op = 0x1e then some .osaka
  else if op = 0x20 then some .frontier
  else if 0x30 ≤ op ∧ op ≤ 0x3c then some .frontier
  else if op = 0x3d ∨ op = 0x3e then some .byzantium
  else if op = 0x3f then some .constantinople
  else if 0x40 ≤ op ∧ op ≤ 0x45 then some .frontier
  else if op = 0x46 ∨ op = 0x47 then some .istanbul
  else if op = 0x48 then some .london
  else if op = 0x49 ∨ op = 0x4a then some .cancun
  else if 0x50 ≤ op ∧ op ≤ 0x5b then some .frontier
  else if 0x5c ≤ op ∧ op ≤ 0x5e then some .cancun
  else if op = 0x5f then some .shanghai
  else if 0x60 ≤ op ∧ op ≤ 0xa4 then some .frontier
  else if op = 0xf0 ∨ op = 0xf1 ∨ op = 0xf2 ∨ op = 0xf3 then some .frontier
  else if op = 0xf4 then some .homestead
  else if op = 0xf5 then some .constantinople
  else if op = 0xfa ∨ op = 0xfd then some .byzantium
  else if op = 0xff then some .frontier
  else none

/-- True when `op` is a defined instruction on fork `f`. -/
def isDefined (f : Fork) (op : Nat) : Bool :=
  match introducedIn op with
  | some g => f.atLeast g
  | none => false

/-- Number of immediate bytes following an opcode (`PUSH1`..`PUSH32`). -/
@[inline] def pushSize (op : Nat) : Nat := if 0x60 ≤ op ∧ op ≤ 0x7f then op - 0x5f else 0

/-- Static `(gas, stack inputs, stack outputs)` of the Berlin+ schedule, exactly the
    table Guillotine batches per basic block (`OPCODE_INFO`). Dynamic parts (memory,
    copy, cold access, SSTORE, CREATE, forwarded gas) are charged by the handlers.
    `0xf6`/`0xf7` carry Guillotine's EIP-3074 table entries. -/
def staticInfo (op : Nat) : Nat × Nat × Nat :=
  if op = 0x00 then (0, 0, 0)
  else if op = 0x01 ∨ op = 0x03 then (3, 2, 1)
  else if op = 0x02 ∨ (0x04 ≤ op ∧ op ≤ 0x07) ∨ op = 0x0b then (5, 2, 1)
  else if op = 0x08 ∨ op = 0x09 then (8, 3, 1)
  else if op = 0x0a then (10, 2, 1)
  else if op = 0x15 ∨ op = 0x19 then (3, 1, 1)
  else if 0x10 ≤ op ∧ op ≤ 0x1d then (3, 2, 1)
  else if op = 0x1e then (5, 1, 1)
  else if op = 0x20 then (30, 2, 1)
  else if op = 0x31 ∨ op = 0x3b ∨ op = 0x3f then (100, 1, 1)
  else if op = 0x35 then (3, 1, 1)
  else if op = 0x37 ∨ op = 0x39 ∨ op = 0x3e then (3, 3, 0)
  else if op = 0x3c then (100, 4, 0)
  else if 0x30 ≤ op ∧ op ≤ 0x3d then (2, 0, 1)
  else if op = 0x40 then (20, 1, 1)
  else if op = 0x47 then (5, 0, 1)
  else if op = 0x49 then (3, 1, 1)
  else if 0x41 ≤ op ∧ op ≤ 0x4a then (2, 0, 1)
  else if op = 0x50 then (2, 1, 0)
  else if op = 0x51 then (3, 1, 1)
  else if op = 0x52 ∨ op = 0x53 then (3, 2, 0)
  else if op = 0x54 then (100, 1, 1)
  else if op = 0x55 then (0, 2, 0)
  else if op = 0x56 then (8, 1, 0)
  else if op = 0x57 then (10, 2, 0)
  else if op = 0x58 ∨ op = 0x59 ∨ op = 0x5a then (2, 0, 1)
  else if op = 0x5b then (1, 0, 0)
  else if op = 0x5c then (100, 1, 1)
  else if op = 0x5d then (100, 2, 0)
  else if op = 0x5e then (3, 3, 0)
  else if op = 0x5f then (2, 0, 1)
  else if 0x60 ≤ op ∧ op ≤ 0x8f then (3, 0, 1)
  else if 0x90 ≤ op ∧ op ≤ 0x9f then (3, 0, 0)
  else if 0xa0 ≤ op ∧ op ≤ 0xa4 then (375 + 375 * (op - 0xa0), 2 + (op - 0xa0), 0)
  else if op = 0xf0 then (0, 3, 1)
  else if op = 0xf1 ∨ op = 0xf2 then (100, 7, 1)
  else if op = 0xf3 ∨ op = 0xfd then (0, 2, 0)
  else if op = 0xf4 ∨ op = 0xfa then (100, 6, 1)
  else if op = 0xf5 then (0, 4, 1)
  else if op = 0xf6 then (3100, 5, 1)
  else if op = 0xf7 then (100, 8, 1)
  else if op = 0xff then (5000, 1, 0)
  else (0, 0, 0)

/-- Static gas of `op` on fork `f`: before Berlin the state-access opcodes had one flat
    price that changed in Tangerine Whistle (EIP-150) and Istanbul (EIP-1884). -/
def staticGas (f : Fork) (op : Nat) : Nat :=
  let berlinCost := (staticInfo op).1
  if f.atLeast .berlin then berlinCost
  else
    let tw := f.atLeast .tangerineWhistle
    let ist := f.atLeast .istanbul
    if op = 0x54 then (if ist then 800 else if tw then 200 else 50)
    else if op = 0x31 then (if ist then 700 else if tw then 400 else 20)
    else if op = 0x3b ∨ op = 0x3c then (if tw then 700 else 20)
    else if op = 0x3f then (if ist then 700 else 400)
    else if op = 0xf1 ∨ op = 0xf2 ∨ op = 0xf4 ∨ op = 0xfa then (if tw then 700 else 40)
    else if op = 0xff then (if tw then 5000 else 0)
    else berlinCost

/-! ### JUMPDEST analysis -/

private def jumpdestLoop (code : Bytes) : Nat → Nat → Array Bool → Array Bool
  | 0, _, acc => acc
  | fuel + 1, pc, acc =>
    if pc ≥ code.size then acc
    else
      let op := Bytes.getZ code pc
      if op = 0x5b then jumpdestLoop code fuel (pc + 1) (acc.set! pc true)
      else jumpdestLoop code fuel (pc + 1 + pushSize op) acc

/-- `(jumpdests code)[pc]` is true exactly when `pc` is a valid jump destination. -/
def jumpdests (code : Bytes) : Array Bool :=
  jumpdestLoop code (code.size + 1) 0 (Array.replicate code.size false)

/-- True when `pc` is a valid jump destination of `code`. -/
def isValidJumpDest (dests : Array Bool) (pc : Nat) : Bool := dests.getD pc false

private def instructionStartsLoop (code : Bytes) : Nat → Nat → Array Nat → Array Nat
  | 0, _, acc => acc
  | fuel + 1, pc, acc =>
    if pc ≥ code.size then acc
    else instructionStartsLoop code fuel (pc + 1 + pushSize (Bytes.getZ code pc)) (acc.push pc)

/-- Program counters at which an instruction starts (PUSH data excluded). -/
def instructionStarts (code : Bytes) : Array Nat :=
  instructionStartsLoop code (code.size + 1) 0 #[]

/-- Immediate of the PUSH at `pc`, right-padded with zeros past the end of the code. -/
def pushValue (code : Bytes) (pc : Nat) : Nat :=
  Bytes.toNat (Bytes.sliceZ code (pc + 1) (pushSize (Bytes.getZ code pc)))

/-! ### Basic blocks -/

/-- Static cost and stack requirement of one basic block. -/
structure BlockInfo where
  /-- Total static gas, clamped to `u32`. -/
  gas : Nat
  /-- Stack items the block needs on entry, clamped to `i16`. -/
  minStack : Nat
  /-- Net stack growth the block can reach, clamped to `i16`. -/
  maxStack : Nat
  deriving Repr, BEq, DecidableEq

/-- Instructions after which execution may continue in a new block that no JUMPDEST
    heads: JUMPI (not taken) and the instructions that observe the exact gas left. -/
def endsBlockWithFallthrough (op : Nat) : Bool :=
  op = 0x57 ∨ op = 0x5a ∨ op = 0x55 ∨ op = 0xf0 ∨ op = 0xf1 ∨ op = 0xf2 ∨ op = 0xf4 ∨ op = 0xf5 ∨ op = 0xfa

/-- Instructions that end a block without falling through. -/
def terminatesBlock (op : Nat) : Bool :=
  op = 0x00 ∨ op = 0x56 ∨ op = 0xf3 ∨ op = 0xfd ∨ op = 0xfe ∨ op = 0xff

private structure Acc where
  gas : Nat
  effect : Int
  minS : Int
  maxS : Int

private def Acc.finish (a : Acc) : BlockInfo :=
  { gas := min a.gas (2 ^ 32 - 1)
    minStack := if a.minS ≥ 0 then 0 else min (-a.minS).toNat 32767
    maxStack := if a.maxS ≤ 0 then 0 else min a.maxS.toNat 32767 }

private def blockLoop (f : Fork) (code : Bytes) : Nat → Nat → Acc → Acc
  | 0, _, acc => acc
  | fuel + 1, pc, acc =>
    if pc ≥ code.size then acc
    else
      let op := Bytes.getZ code pc
      if op = 0x5b then acc
      else
        let cost := staticGas f op
        if 0x60 ≤ op ∧ op ≤ 0x7f then
          let e := acc.effect + 1
          blockLoop f code fuel (pc + 1 + pushSize op)
            { gas := acc.gas + cost, effect := e, minS := acc.minS, maxS := max acc.maxS e }
        else
          let acc' : Acc :=
            if 0x80 ≤ op ∧ op ≤ 0x8f then
              let n : Int := ((op - 0x80 + 1 : Nat) : Int)
              let e := acc.effect + 1
              { gas := acc.gas + cost, effect := e, minS := min acc.minS (acc.effect - n), maxS := max acc.maxS e }
            else if 0x90 ≤ op ∧ op ≤ 0x9f then
              let n : Int := ((op - 0x90 + 1 : Nat) : Int)
              { gas := acc.gas + cost, effect := acc.effect, minS := min acc.minS (acc.effect - n - 1), maxS := acc.maxS }
            else
              let info := staticInfo op
              let afterPop := acc.effect - (info.2.1 : Int)
              let e := afterPop + (info.2.2 : Int)
              { gas := acc.gas + cost, effect := e, minS := min acc.minS afterPop, maxS := max acc.maxS e }
          if endsBlockWithFallthrough op || terminatesBlock op then acc'
          else blockLoop f code fuel (pc + 1) acc'

/-- Static gas and stack bounds of the basic block whose first instruction is at
    `startPc`. `initialGas` seeds the total (1 for the JUMPDEST that heads the block). -/
def blockInfo (f : Fork) (code : Bytes) (startPc initialGas : Nat) : BlockInfo :=
  (blockLoop f code (code.size + 1) startPc { gas := initialGas, effect := 0, minS := 0, maxS := 0 }).finish

/-- Block entry guard: the stack must hold `minStack` items and have room for `maxStack` more. -/
inductive StackGuard where
  | ok | underflow | overflow
  deriving Repr, BEq, DecidableEq

def blockStackGuard (size minStack maxStack capacity : Nat) : StackGuard :=
  if size < minStack then .underflow
  else if size + maxStack > capacity then .overflow
  else .ok

/-- Every block start of `code` with its info: `pc = 0`, each valid JUMPDEST (analysed
    from the next instruction with the JUMPDEST's own gas) and each instruction that
    follows a fall-through block end. Returned as `(pc, info)` in ascending `pc` order. -/
def blocks (f : Fork) (code : Bytes) : Array (Nat × BlockInfo) := Id.run do
  let starts := instructionStarts code
  let dests := jumpdests code
  let mut out : Array (Nat × BlockInfo) := #[]
  let mut prevEnded := true
  for pc in starts do
    let op := Bytes.getZ code pc
    if isValidJumpDest dests pc then
      out := out.push (pc, blockInfo f code (pc + 1) 1)
    else if prevEnded then
      out := out.push (pc, blockInfo f code pc 0)
    prevEnded := endsBlockWithFallthrough op
  return out

/-! ### Straight-line evaluation (constant folding and fusion equivalence) -/

private def evalLoop (f : Fork) (code : Bytes) : Nat → Nat → List Nat → Option (List Nat)
  | 0, _, _ => none
  | fuel + 1, pc, stack =>
    if pc ≥ code.size then some stack
    else
      let op := Bytes.getZ code pc
      if !isDefined f op then none
      else if op = 0x5f ∨ (0x60 ≤ op ∧ op ≤ 0x7f) then
        if stack.length ≥ 1024 then none
        else evalLoop f code fuel (pc + 1 + pushSize op) (pushValue code pc :: stack)
      else if op = 0x50 then
        match stack with
        | _ :: rest => evalLoop f code fuel (pc + 1) rest
        | [] => none
      else if 0x80 ≤ op ∧ op ≤ 0x8f then
        match stack[op - 0x80]? with
        | some v => if stack.length ≥ 1024 then none else evalLoop f code fuel (pc + 1) (v :: stack)
        | none => none
      else if 0x90 ≤ op ∧ op ≤ 0x9f then
        let n := op - 0x90 + 1
        match stack, stack[n]? with
        | top :: rest, some deep => evalLoop f code fuel (pc + 1) (deep :: (rest.set (n - 1) top))
        | _, _ => none
      else
        match Word256.unary? op, Word256.binary? op, Word256.ternary? op, stack with
        | some g, _, _, a :: rest => evalLoop f code fuel (pc + 1) (g a :: rest)
        | _, some g, _, a :: b :: rest => evalLoop f code fuel (pc + 1) (g a b :: rest)
        | _, _, some g, a :: b :: c :: rest => evalLoop f code fuel (pc + 1) (g a b c :: rest)
        | _, _, _, _ => none

/-- Final stack (top first) of straight-line code made only of PUSH, POP, DUP, SWAP and
    pure word opcodes. `none` when the code contains anything else or would fault.
    Any fused or constant-folded dispatch schedule for such code must leave this stack. -/
def evalStraightLine (f : Fork) (code : Bytes) : Option (List Nat) :=
  evalLoop f code (code.size + 1) 0 []

/-! ### Machine-checked reference vectors -/

/-- `PUSH1 0x5b JUMPDEST`: the first `0x5b` is push data, the second a valid destination. -/
example : jumpdests ⟨#[0x60, 0x5b, 0x5b]⟩ = #[false, false, true] := by decide

/-- `PUSH2 0xab` truncated by the end of the code reads as `0xab00`. -/
example : pushValue ⟨#[0x61, 0xab]⟩ 0 = 0xab00 := by decide

/-- `PUSH1 1 PUSH1 2 ADD JUMP`: 3 + 3 + 3 + 8 gas, needs no input, grows the stack by 2. -/
example : blockInfo .cancun ⟨#[0x60, 0x01, 0x60, 0x02, 0x01, 0x56]⟩ 0 0 = ⟨17, 0, 2⟩ := by decide

example : evalStraightLine .cancun ⟨#[0x60, 0x02, 0x60, 0x03, 0x01]⟩ = some [5] := by decide

end Bytecode
end GuillotineSpec
