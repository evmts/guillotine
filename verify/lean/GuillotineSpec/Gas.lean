/-
  GuillotineSpec.Gas

  Fork-aware gas and refund reference specification, Frontier through Osaka.

  Sources: Yellow Paper Appendix G/H, execution-specs `vm/gas.py` per fork, and
  EIP-150, EIP-160, EIP-161, EIP-198, EIP-1283, EIP-1884, EIP-2028, EIP-2200,
  EIP-2565, EIP-2929, EIP-3529, EIP-3651, EIP-3860, EIP-4844, EIP-7623,
  EIP-7883, EIP-7918.

  Zig counterparts: `src/frame/fork_gas.zig`, `src/eips_and_hardforks/eips.zig`,
  `src/instructions/handlers_system.zig`, `lib/voltaire` gas constants, blob
  fee and MODEXP pricing.
-/
import GuillotineSpec.Hex
import GuillotineSpec.Word256

namespace GuillotineSpec

/-- The 15 mainnet execution-layer hardforks that change EVM rules. -/
inductive Fork where
  | frontier | homestead | tangerineWhistle | spuriousDragon | byzantium
  | constantinople | petersburg | istanbul | berlin | london | merge
  | shanghai | cancun | prague | osaka
  deriving Repr, BEq, DecidableEq, Inhabited

namespace Fork

def toNat : Fork → Nat
  | frontier => 0 | homestead => 1 | tangerineWhistle => 2 | spuriousDragon => 3
  | byzantium => 4 | constantinople => 5 | petersburg => 6 | istanbul => 7
  | berlin => 8 | london => 9 | merge => 10 | shanghai => 11 | cancun => 12
  | prague => 13 | osaka => 14

def all : List Fork :=
  [frontier, homestead, tangerineWhistle, spuriousDragon, byzantium, constantinople,
   petersburg, istanbul, berlin, london, merge, shanghai, cancun, prague, osaka]

/-- `f.atLeast g`: fork `f` is `g` or a successor of `g`. -/
@[inline] def atLeast (f g : Fork) : Bool := decide (f.toNat ≥ g.toNat)

def name : Fork → String
  | frontier => "FRONTIER" | homestead => "HOMESTEAD"
  | tangerineWhistle => "TANGERINE_WHISTLE" | spuriousDragon => "SPURIOUS_DRAGON"
  | byzantium => "BYZANTIUM" | constantinople => "CONSTANTINOPLE"
  | petersburg => "PETERSBURG" | istanbul => "ISTANBUL" | berlin => "BERLIN"
  | london => "LONDON" | merge => "MERGE" | shanghai => "SHANGHAI"
  | cancun => "CANCUN" | prague => "PRAGUE" | osaka => "OSAKA"

def ofName (s : String) : Option Fork := all.find? (fun f => f.name == s)

end Fork

namespace Gas

/-! ### Constants -/

def sstoreSetGas : Nat := 20000
def sstoreResetGas : Nat := 5000
def sstoreSentryGas : Nat := 2300
def coldSloadCost : Nat := 2100
def coldAccountAccessCost : Nat := 2600
def warmAccessCost : Nat := 100
def selfdestructRefundGas : Nat := 24000
def newAccountGas : Nat := 25000
def callValueTransferGas : Nat := 9000
def callStipend : Nat := 2300
def txGas : Nat := 21000
def txGasContractCreation : Nat := 53000
def createGasBase : Nat := 32000
def initcodeWordGas : Nat := 2
def txDataZeroGas : Nat := 4
def txDataFloorTokenGas : Nat := 10
def gasPerBlob : Nat := 131072
def blobBaseCost : Nat := 8192
def u64Max : Nat := 2 ^ 64 - 1

/-- Number of 32-byte words covering `n` bytes. -/
@[inline] def words (n : Nat) : Nat := (n + 31) / 32

/-! ### SSTORE (legacy, EIP-1283, EIP-2200, EIP-2929, EIP-3529) -/

/-- Net gas metering applies in Constantinople (EIP-1283) and from Istanbul on (EIP-2200).
    Petersburg removed EIP-1283 again. -/
def sstoreNetMetered (f : Fork) : Bool :=
  f.atLeast .istanbul || f == .constantinople

/-- EIP-2200: SSTORE fails when the gas left is at or below the call stipend. -/
def sstoreHasSentry (f : Fork) : Bool := f.atLeast .istanbul

/-- Gas of an SSTORE that leaves the slot unchanged or touches an already dirty slot. -/
def sstoreNoopGas (f : Fork) : Nat :=
  if f.atLeast .berlin then warmAccessCost else if f.atLeast .istanbul then 800 else 200

/-- Refund for clearing a slot; EIP-3529 lowered it in London. -/
def sstoreClearRefund (f : Fork) : Nat := if f.atLeast .london then 4800 else 15000

/-- Gas charged by one SSTORE (cold surcharge included) and the change it makes to the
    transaction refund counter. `original` is the value at transaction start, `current`
    the value before this SSTORE, `new` the value written. -/
def sstoreCost (f : Fork) (original current new : Nat) (isCold : Bool) : Nat × Int :=
  if !sstoreNetMetered f then
    let gas := if current = 0 ∧ new ≠ 0 then sstoreSetGas else sstoreResetGas
    let refund : Int := if current ≠ 0 ∧ new = 0 then 15000 else 0
    (gas, refund)
  else
    let berlin := f.atLeast .berlin
    let noop := sstoreNoopGas f
    let reset := if berlin then sstoreResetGas - coldSloadCost else sstoreResetGas
    let clear : Int := (sstoreClearRefund f : Nat)
    let cold := if berlin && isCold then coldSloadCost else 0
    if current = new then (cold + noop, 0)
    else if original = current then
      if original = 0 then (cold + sstoreSetGas, 0)
      else (cold + reset, if new = 0 then clear else 0)
    else
      let r1 : Int :=
        if original ≠ 0 then
          (if current = 0 then -clear else if new = 0 then clear else 0)
        else 0
      let r2 : Int :=
        if original = new then
          (if original = 0 then ((sstoreSetGas - noop : Nat) : Int) else ((reset - noop : Nat) : Int))
        else 0
      (cold + noop, r1 + r2)

/-! ### State access (EIP-150, EIP-1884, EIP-2929) -/

/-- Total gas of one SLOAD. -/
def sloadCost (f : Fork) (isCold : Bool) : Nat :=
  if f.atLeast .berlin then (if isCold then coldSloadCost else warmAccessCost)
  else if f.atLeast .istanbul then 800
  else if f.atLeast .tangerineWhistle then 200
  else 50

/-- State-access opcodes that pay the account access price. -/
inductive AccessOp where
  | balance | extcodesize | extcodecopy | extcodehash | call
  deriving Repr, BEq, DecidableEq

/-- Total static gas of an account-accessing opcode (before any dynamic part). -/
def accountAccessCost (f : Fork) (op : AccessOp) (isCold : Bool) : Nat :=
  if f.atLeast .berlin then (if isCold then coldAccountAccessCost else warmAccessCost)
  else
    let tw := f.atLeast .tangerineWhistle
    let ist := f.atLeast .istanbul
    match op with
    | .balance => if ist then 700 else if tw then 400 else 20
    | .extcodesize | .extcodecopy => if tw then 700 else 20
    | .extcodehash => if ist then 700 else 400
    | .call => if tw then 700 else 40

/-- True when the fork distinguishes cold from warm state access. -/
def hasAccessLists (f : Fork) : Bool := f.atLeast .berlin

/-! ### Memory -/

/-- Total cost of a memory of `w` words. -/
def memoryCost (w : Nat) : Nat := 3 * w + w * w / 512

/-- Gas to grow memory from `curBytes` to cover `newBytes`. -/
def memoryExpansionGas (curBytes newBytes : Nat) : Nat :=
  if newBytes ≤ curBytes then 0 else memoryCost (words newBytes) - memoryCost (words curBytes)

/-! ### Simple dynamic costs -/

/-- EXP: 10 gas plus 10 (50 from Spurious Dragon, EIP-160) per exponent byte. -/
def expGas (f : Fork) (exponent : Nat) : Nat :=
  10 + (if f.atLeast .spuriousDragon then 50 else 10) * Word256.expGasByteLen exponent

def copyGas (len : Nat) : Nat := 3 * words len
def keccakGas (len : Nat) : Nat := 30 + 6 * words len
def logGas (topics len : Nat) : Nat := 375 + 375 * topics + 8 * len

/-! ### CALL family (EIP-150, EIP-161, EIP-2929) -/

def hasAllButOne64th (f : Fork) : Bool := f.atLeast .tangerineWhistle

/-- EIP-161: the new-account surcharge needs value sent to a dead account. Earlier forks
    charge it whenever the target does not exist. -/
def newAccountNeedsValue (f : Fork) : Bool := f.atLeast .spuriousDragon

/-- Gas charged by a CALL-family opcode on top of memory expansion and the gas forwarded. -/
def callExtraGas (f : Fork) (isCall isCold hasValue targetExists targetDead : Bool) : Nat :=
  let access := accountAccessCost f .call isCold
  let value := if hasValue then callValueTransferGas else 0
  let newAcct :=
    if isCall then
      (if newAccountNeedsValue f then (if hasValue && targetDead then newAccountGas else 0)
       else (if !targetExists then newAccountGas else 0))
    else 0
  access + value + newAcct

/-- Gas forwarded to the callee given the gas left after all other call charges.
    `none` is an out-of-gas failure (pre-EIP-150 forks forward exactly the request). -/
def callForwardedGas (f : Fork) (available requested : Nat) : Option Nat :=
  if hasAllButOne64th f then some (min requested (available - available / 64))
  else if requested > available then none else some requested

/-- Extra gas handed to the callee when value is transferred. -/
def callStipendFor (hasValue : Bool) : Nat := if hasValue then callStipend else 0

/-! ### CREATE (EIP-3860) and SELFDESTRUCT (EIP-150, EIP-161, EIP-2929, EIP-3529) -/

/-- EIP-3860 (Shanghai): 2 gas per initcode word. -/
def initcodeWordCost (f : Fork) (initLen : Nat) : Nat :=
  if f.atLeast .shanghai then initcodeWordGas * words initLen else 0

/-- Gas of the CREATE opcode before memory expansion and the forwarded gas. -/
def createGas (f : Fork) (initLen : Nat) : Nat := createGasBase + initcodeWordCost f initLen

/-- EIP-3860 initcode size limit, EIP-170 code size limit before Shanghai. -/
def initcodeSizeLimit (f : Fork) : Nat := if f.atLeast .shanghai then 0xC000 else 0x6000

/-- Total gas of SELFDESTRUCT. -/
def selfdestructGas (f : Fork) (isCold hasBalance targetExists targetDead : Bool) : Nat :=
  let base := if f.atLeast .tangerineWhistle then 5000 else 0
  let cold := if f.atLeast .berlin && isCold then coldAccountAccessCost else 0
  let newAcct :=
    if f.atLeast .spuriousDragon then (if hasBalance && targetDead then newAccountGas else 0)
    else if f.atLeast .tangerineWhistle then (if !targetExists then newAccountGas else 0)
    else 0
  base + cold + newAcct

/-- SELFDESTRUCT refund, removed by EIP-3529 in London. -/
def selfdestructRefund (f : Fork) : Nat := if f.atLeast .london then 0 else selfdestructRefundGas

/-! ### Transaction level (EIP-2028, EIP-3529, EIP-7623) -/

/-- Calldata tokens: zero bytes count 1, non-zero bytes 4 (17 before EIP-2028). -/
def calldataTokens (f : Fork) (data : Bytes) : Nat :=
  let mult := if f.atLeast .istanbul then 4 else 17
  data.foldl (fun acc b => acc + (if b == 0 then 1 else mult)) 0

/-- Intrinsic gas of a transaction with no access list. -/
def intrinsicGas (f : Fork) (data : Bytes) (isCreate : Bool) : Nat :=
  (if isCreate then txGasContractCreation else txGas)
    + calldataTokens f data * txDataZeroGas
    + (if isCreate then initcodeWordCost f data.size else 0)

/-- EIP-7623 (Prague): minimum gas a transaction must pay for its calldata. -/
def calldataFloorGas (f : Fork) (tokens : Nat) : Nat :=
  if f.atLeast .prague then txGas + tokens * txDataFloorTokenGas else 0

/-- Refund actually granted: capped at a half (a fifth from London) of the gas used. -/
def refundCap (f : Fork) (gasUsed refundCounter : Nat) : Nat :=
  min refundCounter (gasUsed / (if f.atLeast .london then 5 else 2))

/-- Gas left after applying the capped refund. -/
def applyRefund (f : Fork) (gasLimit gasLeft refundCounter : Nat) : Nat :=
  min gasLimit (gasLeft + refundCap f (gasLimit - gasLeft) refundCounter)

/-! ### Blob gas (EIP-4844, EIP-7691, EIP-7918) -/

/-- Blob schedule `(target blobs, max blobs, base fee update fraction)`. -/
def blobSchedule (f : Fork) : Option (Nat × Nat × Nat) :=
  if f.atLeast .prague then some (6, 9, 5007716)
  else if f.atLeast .cancun then some (3, 6, 3338477)
  else none

private def fakeExpLoop (numerator denominator bound : Nat) : Nat → Nat → Nat → Nat → Option Nat
  | 0, _, _, _ => none
  | fuel + 1, i, accum, output =>
    if accum = 0 then some (output / denominator)
    else
      let output' := output + accum
      if output' ≥ bound then none
      else fakeExpLoop numerator denominator bound fuel (i + 1) (accum * numerator / (denominator * i)) output'

/-- EIP-4844 `fake_exponential(factor, numerator, denominator)` over unbounded naturals.
    `none` means the exact result is at least `2^256`. -/
def fakeExponential (factor numerator denominator : Nat) : Option Nat :=
  if denominator = 0 then none
  else fakeExpLoop numerator denominator (Word256.size * denominator) 100000 1 (factor * denominator) 0

/-- Blob base fee as stored in a `u64` header-width field: saturates at `2^64 - 1`;
    `0` before Cancun. -/
def blobBaseFee (f : Fork) (excessBlobGas : Nat) : Nat :=
  match blobSchedule f with
  | none => 0
  | some (_, _, fraction) =>
    match fakeExponential 1 excessBlobGas fraction with
    | some v => min v u64Max
    | none => u64Max

/-- `calc_excess_blob_gas` of the next block from its parent header, with the EIP-7918
    reserve price from Osaka. Saturates at `2^64 - 1`, the header field width. -/
def excessBlobGas (f : Fork) (parentExcess parentBlobGasUsed parentBaseFee : Nat) : Nat :=
  match blobSchedule f with
  | none => 0
  | some (target, max, fraction) =>
    let targetGas := target * gasPerBlob
    let total := parentExcess + parentBlobGasUsed
    if total < targetGas then 0
    else
      let reserveActive :=
        f.atLeast .osaka &&
          (match fakeExponential 1 parentExcess fraction with
           | some price => decide (blobBaseCost * parentBaseFee > gasPerBlob * price)
           | none => false)
      if reserveActive then min (parentExcess + parentBlobGasUsed * (max - target) / max) u64Max
      else min (total - targetGas) u64Max

/-! ### MODEXP (EIP-198, EIP-2565, EIP-7883) -/

/-- Bit length of a natural number (`0` has length `0`). -/
def bitLen (n : Nat) : Nat := if n = 0 then 0 else Nat.log2 n + 1

/-- Iteration count from the exponent length and its first (up to 32) bytes. -/
def modexpIterations (f : Fork) (expLen expHead : Nat) : Nat :=
  let headBits := bitLen expHead
  let adjusted :=
    if expLen ≤ 32 then headBits - 1
    else (if f.atLeast .osaka then 16 else 8) * (expLen - 32) + (headBits - 1)
  max adjusted 1

private def eip198Complexity (x : Nat) : Nat :=
  if x ≤ 64 then x * x
  else if x ≤ 1024 then x * x / 4 + 96 * x - 3072
  else x * x / 16 + 480 * x - 199680

/-- MODEXP gas for declared lengths and the exponent head. Osaka additionally rejects any
    length above 1024 bytes (EIP-7823) before pricing; that is `none`. -/
def modexpGas (f : Fork) (baseLen expLen modLen expHead : Nat) : Option Nat :=
  let maxLen := max baseLen modLen
  let iter := modexpIterations f expLen expHead
  if f.atLeast .osaka then
    if baseLen > 1024 ∨ expLen > 1024 ∨ modLen > 1024 then none
    else
      let w := (maxLen + 7) / 8
      let complexity := if maxLen ≤ 32 then 16 else 2 * w * w
      some (max 500 (complexity * iter))
  else if f.atLeast .berlin then
    let w := (maxLen + 7) / 8
    some (max 200 (w * w * iter / 3))
  else
    some (eip198Complexity maxLen * iter / 20)

/-! ### Precompile address ranges (which addresses start warm from Berlin) -/

/-- Highest contiguous precompile address active in the fork. -/
def lastContiguousPrecompile (f : Fork) : Nat :=
  if f.atLeast .prague then 0x11
  else if f.atLeast .cancun then 0x0a
  else if f.atLeast .istanbul then 0x09
  else if f.atLeast .byzantium then 0x08
  else 0x04

def isPrecompile (f : Fork) (addr : Nat) : Bool :=
  (decide (1 ≤ addr) && decide (addr ≤ lastContiguousPrecompile f)) || (f.atLeast .osaka && addr == 0x100)

/-! ### Machine-checked reference vectors (fork_gas.zig unit-test table) -/

example : sstoreCost .frontier 1 1 0 false = (5000, 15000) := by decide
example : sstoreCost .petersburg 0 1 0 false = (5000, 15000) := by decide
example : sstoreCost .constantinople 0 1 0 false = (200, 19800) := by decide
example : sstoreCost .istanbul 1 0 1 false = (800, -15000 + 4200) := by decide
example : sstoreCost .berlin 1 1 0 true = (5000, 15000) := by decide
example : sstoreCost .london 1 0 1 false = (100, -4800 + 2800) := by decide
example : sstoreCost .osaka 0 0 1 true = (22100, 0) := by decide
example : sloadCost .istanbul true = 800 := by decide
example : accountAccessCost .tangerineWhistle .balance true = 400 := by decide
example : memoryExpansionGas 0 32 = 3 := by decide
example : calldataFloorGas .prague 10 = 21100 := by decide
example : blobBaseFee .cancun 0 = 1 := by decide

end Gas
end GuillotineSpec
