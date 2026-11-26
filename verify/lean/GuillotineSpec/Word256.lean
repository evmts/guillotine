/-
  GuillotineSpec.Word256

  Executable reference semantics of every 256-bit EVM word operation
  (Yellow Paper Appendix H.1, EIP-145 shifts, EIP-7939 CLZ).

  A word is a natural number below `2^256`. Every operation takes canonical
  words and returns a canonical word; arithmetic is done on unbounded naturals
  and reduced, so the definitions read exactly like the Yellow Paper.

  Zig counterparts: `src/instructions/handlers_{arithmetic,bitwise,comparison}.zig`
  and `src/core/verified_ops.zig`.
-/

namespace GuillotineSpec
namespace Word256

/-- `2^256`. -/
def size : Nat := 2 ^ 256

/-- `2^256 - 1`. -/
def maxU : Nat := size - 1

/-- `2^255`, the two's-complement sign bit. -/
def signBit : Nat := 2 ^ 255

/-- Reduce a natural number to a word. -/
@[inline] def norm (x : Nat) : Nat := x % size

@[inline] def ofBool (b : Bool) : Nat := if b then 1 else 0

/-- True when the word is negative as a two's-complement integer. -/
@[inline] def isNeg (x : Nat) : Bool := decide (x ≥ signBit)

/-- Two's-complement negation. -/
def neg (x : Nat) : Nat := norm (size - norm x)

/-- Two's-complement absolute value (`abs (-2^255) = 2^255`). -/
def abs (x : Nat) : Nat := if isNeg x then neg x else x

/-- Signed interpretation of a word. -/
def toInt (x : Nat) : Int := if isNeg x then (x : Int) - (size : Int) else (x : Int)

/-! ### Arithmetic -/

def add (a b : Nat) : Nat := norm (a + b)
def mul (a b : Nat) : Nat := norm (a * b)
def sub (a b : Nat) : Nat := norm (a + (size - norm b))
def div (a b : Nat) : Nat := if b = 0 then 0 else a / b
def mod (a b : Nat) : Nat := if b = 0 then 0 else a % b

/-- SDIV: truncated signed division; `x / 0 = 0`, `-2^255 / -1 = -2^255`. -/
def sdiv (a b : Nat) : Nat :=
  if b = 0 then 0
  else
    let q := abs a / abs b
    if isNeg a != isNeg b then neg q else norm q

/-- SMOD: signed remainder taking the sign of the dividend; `x % 0 = 0`. -/
def smod (a b : Nat) : Nat :=
  if b = 0 then 0
  else
    let r := abs a % abs b
    if isNeg a then neg r else r

/-- ADDMOD over unbounded naturals; modulus `0` yields `0`. -/
def addmod (a b n : Nat) : Nat := if n = 0 then 0 else (a + b) % n

/-- MULMOD over unbounded naturals; modulus `0` yields `0`. -/
def mulmod (a b n : Nat) : Nat := if n = 0 then 0 else (a * b) % n

private def expLoop : Nat → Nat → Nat → Nat → Nat
  | 0, _, _, acc => acc
  | fuel + 1, base, e, acc =>
    if e = 0 then acc
    else
      let acc' := if e % 2 = 1 then norm (acc * base) else acc
      expLoop fuel (norm (base * base)) (e / 2) acc'

/-- EXP: `a ^ e mod 2^256` by square-and-multiply (256 rounds cover every exponent). -/
def exp (a e : Nat) : Nat := expLoop 256 a e 1

/-- SIGNEXTEND: extend the sign of the low `b + 1` bytes of `x`. -/
def signextend (b x : Nat) : Nat :=
  if b ≥ 31 then x
  else
    let bit := 8 * b + 7
    let mask := 2 ^ bit - 1
    if x.testBit bit then x ||| (maxU - mask) else x &&& mask

/-! ### Comparison -/

def lt (a b : Nat) : Nat := ofBool (decide (a < b))
def gt (a b : Nat) : Nat := ofBool (decide (a > b))
def slt (a b : Nat) : Nat := ofBool (decide (toInt a < toInt b))
def sgt (a b : Nat) : Nat := ofBool (decide (toInt a > toInt b))
def eq (a b : Nat) : Nat := ofBool (a == b)
def iszero (a : Nat) : Nat := ofBool (a == 0)

/-! ### Bitwise -/

def and (a b : Nat) : Nat := a &&& b
def or (a b : Nat) : Nat := a ||| b
def xor (a b : Nat) : Nat := a ^^^ b
def not (a : Nat) : Nat := maxU - norm a

/-- BYTE: the `i`-th byte of `x`, counting from the most significant. -/
def byte (i x : Nat) : Nat := if i ≥ 32 then 0 else (x >>> (8 * (31 - i))) % 256

/-- SHL: logical left shift. -/
def shl (s x : Nat) : Nat := if s ≥ 256 then 0 else norm (x <<< s)

/-- SHR: logical right shift. -/
def shr (s x : Nat) : Nat := if s ≥ 256 then 0 else x >>> s

/-- SAR: arithmetic right shift. -/
def sar (s x : Nat) : Nat :=
  if s ≥ 256 then (if isNeg x then maxU else 0)
  else if isNeg x then (x >>> s) ||| (maxU - (2 ^ (256 - s) - 1))
  else x >>> s

/-- CLZ (EIP-7939): number of leading zero bits; `clz 0 = 256`. -/
def clz (x : Nat) : Nat := if x = 0 then 256 else 255 - Nat.log2 x

/-- Number of bytes needed to represent the EXP exponent (EIP-160 dynamic gas). -/
def expGasByteLen (e : Nat) : Nat := if e = 0 then 0 else Nat.log2 e / 8 + 1

/-! ### Opcode dispatch (shared by the straight-line evaluator and the interpreter) -/

/-- Semantics of a one-operand word opcode. -/
def unary? (op : Nat) : Option (Nat → Nat) :=
  match op with
  | 0x15 => some iszero
  | 0x19 => some not
  | 0x1e => some clz
  | _ => none

/-- Semantics of a two-operand word opcode; the first argument is the top of the stack. -/
def binary? (op : Nat) : Option (Nat → Nat → Nat) :=
  match op with
  | 0x01 => some add
  | 0x02 => some mul
  | 0x03 => some sub
  | 0x04 => some div
  | 0x05 => some sdiv
  | 0x06 => some mod
  | 0x07 => some smod
  | 0x0a => some exp
  | 0x0b => some signextend
  | 0x10 => some lt
  | 0x11 => some gt
  | 0x12 => some slt
  | 0x13 => some sgt
  | 0x14 => some eq
  | 0x16 => some and
  | 0x17 => some or
  | 0x18 => some xor
  | 0x1a => some byte
  | 0x1b => some shl
  | 0x1c => some shr
  | 0x1d => some sar
  | _ => none

/-- Semantics of a three-operand word opcode; the first argument is the top of the stack. -/
def ternary? (op : Nat) : Option (Nat → Nat → Nat → Nat) :=
  match op with
  | 0x08 => some addmod
  | 0x09 => some mulmod
  | _ => none

/-! ### Machine-checked sanity vectors (evaluated by the kernel at build time) -/

example : add maxU 1 = 0 := by decide
example : sub 0 1 = maxU := by decide
example : sdiv signBit maxU = signBit := by decide
example : smod (neg 7) 3 = neg 1 := by decide
example : signextend 0 0xff = maxU := by decide
example : signextend 0 0x7f = 0x7f := by decide
example : sar 1 maxU = maxU := by decide
example : sar 255 signBit = maxU := by decide
example : shl 255 1 = signBit := by decide
example : byte 31 0xab = 0xab := by decide
example : clz 1 = 255 := by decide
example : clz 0 = 256 := by decide
example : expGasByteLen 256 = 2 := by decide
example : slt maxU 0 = 1 := by decide

end Word256
end GuillotineSpec
