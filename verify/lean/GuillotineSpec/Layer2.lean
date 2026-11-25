/-
  GuillotineSpec.Layer2

  Reference specification of the OP Stack execution rules Base runs, Bedrock
  through Jovian, for Base Mainnet (chain 8453) and Base Sepolia (chain 84532).

  * L1 data-availability fee: Bedrock/Regolith, Ecotone, Fjord (FastLZ size estimate).
  * Operator fee: Isthmus and Jovian formulas, and the refund of the unused part.
  * Fee settlement to the sequencer, base-fee, L1-fee and operator-fee vaults.
  * Deposit transactions (type `0x7E`): validation, mint, nonce, gas accounting.
  * Jovian DA footprint.
  * Precompile input-size limits (Granite/Jovian BN254 pairing, Isthmus/Jovian BLS12-381).
  * Hardfork schedules and the spec active at a timestamp.

  Arithmetic is saturating at `2^256 - 1` (or `2^64 - 1` where the reference
  uses 64-bit values), as in op-revm.

  Sources: OP Stack specs (specs.optimism.io: exec-engine, deposits, fjord,
  isthmus, jovian), op-revm `l1block.rs`, `fast_lz.rs`, `handler.rs`,
  `precompiles.rs`, and base/base chain configs.

  Zig counterparts: `src/layer2/optimism/*.zig`, `src/layer2/base/*.zig`.
-/
import GuillotineSpec.Hex
import GuillotineSpec.Word256

namespace GuillotineSpec
namespace Layer2

/-! ### Specs -/

/-- OP Stack execution specs. Delta (span batches) is consensus-only and has no spec id. -/
inductive OpSpec where
  | bedrock | regolith | canyon | ecotone | fjord | granite | holocene | isthmus | jovian
  deriving Repr, BEq, DecidableEq, Inhabited

namespace OpSpec

def toNat : OpSpec → Nat
  | bedrock => 100 | regolith => 101 | canyon => 102 | ecotone => 103 | fjord => 104
  | granite => 105 | holocene => 106 | isthmus => 107 | jovian => 108

def all : List OpSpec := [bedrock, regolith, canyon, ecotone, fjord, granite, holocene, isthmus, jovian]

@[inline] def atLeast (s t : OpSpec) : Bool := decide (s.toNat ≥ t.toNat)

def name : OpSpec → String
  | bedrock => "bedrock" | regolith => "regolith" | canyon => "canyon" | ecotone => "ecotone"
  | fjord => "fjord" | granite => "granite" | holocene => "holocene" | isthmus => "isthmus"
  | jovian => "jovian"

def ofName (s : String) : Option OpSpec := all.find? (fun x => x.name == s)

/-- Ethereum hardfork whose EVM rules the spec runs. -/
def ethHardforkName : OpSpec → String
  | bedrock | regolith => "MERGE"
  | canyon => "SHANGHAI"
  | ecotone | fjord | granite | holocene => "CANCUN"
  | isthmus | jovian => "PRAGUE"

end OpSpec

/-! ### Saturating arithmetic -/

def u256Max : Nat := Word256.maxU
def u64Max : Nat := 2 ^ 64 - 1

@[inline] def satAdd (a b : Nat) : Nat := min (a + b) u256Max
@[inline] def satMul (a b : Nat) : Nat := min (a * b) u256Max
@[inline] def satAdd64 (a b : Nat) : Nat := min (a + b) u64Max
@[inline] def satMul64 (a b : Nat) : Nat := min (a * b) u64Max

/-! ### Constants -/

def depositTxType : Nat := 0x7E
def nonZeroByteGas : Nat := 16
def zeroByteGas : Nat := 4
def preRegolithSignatureOverheadGas : Nat := 68 * 16
def operatorFeeScalarDecimal : Nat := 1000000
def operatorFeeJovianMultiplier : Nat := 100
def fjordFastlzCoef : Nat := 836500
def fjordIntercept : Nat := 42585600
def fjordMinTxSizeScaled : Nat := 100 * 1000000
def daFootprintGasScalarDefault : Nat := 400

def bn254PairingMaxInputGranite : Nat := 112687
def bn254PairingMaxInputJovian : Nat := 81984
def bls12G1MsmMaxInputIsthmus : Nat := 513760
def bls12G1MsmMaxInputJovian : Nat := 288960
def bls12G2MsmMaxInputIsthmus : Nat := 488448
def bls12G2MsmMaxInputJovian : Nat := 278784
def bls12PairingMaxInputIsthmus : Nat := 235008
def bls12PairingMaxInputJovian : Nat := 156672
def p256VerifyAddress : Nat := 0x100
def p256VerifyGas : Nat := 3450

/-- A transaction envelope is a deposit when its first byte is `0x7E`. -/
def isDeposit (tx : Bytes) : Bool := tx.size > 0 && Bytes.getZ tx 0 == depositTxType

/-! ### FastLZ compressed-size estimate (Fjord) -/

namespace FastLz

@[inline] def read24 (inp : Bytes) (i : Nat) : Nat :=
  Bytes.getZ inp i + (Bytes.getZ inp (i + 1) <<< 8) + (Bytes.getZ inp (i + 2) <<< 16)

@[inline] def hash (v : Nat) : Nat := (((v * 2654435769) % 2 ^ 64) >>> 19) &&& 0x1fff

def literals (r size : Nat) : Nat :=
  let s := size + 0x21 * (r / 0x20)
  let rem := r % 0x20
  if rem ≠ 0 then s + rem + 1 else s

def matchSize (l size : Nat) : Nat :=
  let adjusted := l - 1
  let s := size + 3 * (adjusted / 262)
  if adjusted % 262 ≥ 6 then s + 3 else s + 2

private def cmpLoop (inp : Bytes) (p q : Nat) : Nat → Nat → Nat
  | 0, l => l
  | fuel + 1, l => if Bytes.getZ inp (p + l) ≠ Bytes.getZ inp (q + l) then l + 1 else cmpLoop inp p q fuel (l + 1)

/-- Length of the match between positions `p` and `q`, bounded by `r - q`; a mismatch
    is counted (the returned length is one past the first differing byte). -/
def cmp (inp : Bytes) (p q r : Nat) : Nat := cmpLoop inp p q (r - q) 0

/-- Scan forward for a position whose 3-byte sequence was seen within the last 8192
    bytes. Returns `(idx, matchPosition, hashTable)`. -/
private def scan (inp : Bytes) (idxLimit : Nat) : Nat → Nat → Array Nat → Nat × Nat × Array Nat
  | 0, idx, htab => (idx, 0, htab)
  | fuel + 1, idx, htab =>
    let seq := read24 inp idx
    let h := hash seq
    let r := htab.getD h 0
    let htab' := htab.set! h idx
    if idx ≥ idxLimit then (idx, r, htab')
    else if idx - r < 8192 ∧ seq = read24 inp r then (idx + 1, r, htab')
    else scan inp idxLimit fuel (idx + 1) htab'

private def compress (inp : Bytes) (idxLimit : Nat) : Nat → Nat → Nat → Nat → Array Nat → Nat × Nat
  | 0, _, anchor, size, _ => (anchor, size)
  | fuel + 1, idx, anchor, size, htab =>
    if idx ≥ idxLimit then (anchor, size)
    else
      let (idx1, r, htab1) := scan inp idxLimit (inp.size + 1) idx htab
      if idx1 ≥ idxLimit then (anchor, size)
      else
        let idx2 := idx1 - 1
        let size1 := if idx2 > anchor then literals (idx2 - anchor) size else size
        let len := cmp inp (r + 3) (idx2 + 3) (idxLimit + 9)
        let size2 := matchSize len size1
        let i3 := idx2 + len
        let htab2 := htab1.set! (hash (read24 inp i3)) i3
        let i4 := i3 + 1
        let htab3 := htab2.set! (hash (read24 inp i4)) i4
        compress inp idxLimit fuel (i4 + 1) (i4 + 1) size2 htab3

/-- Size in bytes of the FastLZ (level 1) compression of `inp`, without producing it. -/
def compressLen (inp : Bytes) : Nat :=
  if inp.size < 13 then literals inp.size 0
  else
    let (anchor, size) := compress inp (inp.size - 13) (inp.size + 1) 2 0 0 (Array.replicate 8192 0)
    literals (inp.size - anchor) size

end FastLz

/-! ### L1 data fee -/

/-- L1 block attributes read from the L1Block predeploy. -/
structure L1BlockInfo where
  l1BaseFee : Nat := 0
  l1FeeOverhead : Option Nat := none
  l1BaseFeeScalar : Nat := 0
  l1BlobBaseFee : Option Nat := none
  l1BlobBaseFeeScalar : Option Nat := none
  operatorFeeScalar : Option Nat := none
  operatorFeeConstant : Option Nat := none
  daFootprintGasScalar : Option Nat := none
  /-- Ecotone activation block: both scalars are still zero, so the Bedrock formula applies. -/
  emptyEcotoneScalars : Bool := false

/-- Fjord: `max(100e6, fastlzSize * 836_500 - 42_585_600)`, scaled by `1e6`. -/
def estimatedSizeFjord (tx : Bytes) : Nat :=
  max fjordMinTxSizeScaled (satMul64 (FastLz.compressLen tx) fjordFastlzCoef - fjordIntercept)

/-- Calldata gas of the envelope as charged for L1 data availability. -/
def dataGas (tx : Bytes) (spec : OpSpec) : Nat :=
  if spec.atLeast .fjord then estimatedSizeFjord tx * nonZeroByteGas / 1000000
  else
    let bytes := tx.foldl (fun acc b => acc + (if b == 0 then zeroByteGas else nonZeroByteGas)) 0
    if spec.atLeast .regolith then bytes else bytes + preRegolithSignatureOverheadGas

def l1FeeScaled (info : L1BlockInfo) : Nat :=
  satAdd (satMul (satMul info.l1BaseFee nonZeroByteGas) info.l1BaseFeeScalar)
    (satMul (info.l1BlobBaseFee.getD 0) (info.l1BlobBaseFeeScalar.getD 0))

/-- Bedrock/Regolith: `(dataGas + overhead) * l1BaseFee * l1Scalar / 1e6`. -/
def l1CostBedrock (info : L1BlockInfo) (tx : Bytes) (spec : OpSpec) : Nat :=
  satMul (satMul (satAdd (dataGas tx spec) (info.l1FeeOverhead.getD 0)) info.l1BaseFee) info.l1BaseFeeScalar / 1000000

/-- Ecotone: `dataGas * (16 * l1BaseFee * baseFeeScalar + blobBaseFee * blobScalar) / 16e6`. -/
def l1CostEcotone (info : L1BlockInfo) (tx : Bytes) (spec : OpSpec) : Nat :=
  if info.emptyEcotoneScalars then l1CostBedrock info tx spec
  else satMul (l1FeeScaled info) (dataGas tx spec) / (1000000 * nonZeroByteGas)

/-- Fjord: `estimatedSize * (16 * l1BaseFee * baseFeeScalar + blobBaseFee * blobScalar) / 1e12`. -/
def l1CostFjord (info : L1BlockInfo) (tx : Bytes) : Nat :=
  let scaled := l1FeeScaled info
  if scaled = 0 then 0 else satMul (estimatedSizeFjord tx) scaled / 1000000000000

/-- L1 data fee of a transaction envelope. Deposits and empty envelopes pay nothing. -/
def l1Cost (info : L1BlockInfo) (tx : Bytes) (spec : OpSpec) : Nat :=
  if tx.size = 0 ∨ isDeposit tx then 0
  else if spec.atLeast .fjord then l1CostFjord info tx
  else if spec.atLeast .ecotone then l1CostEcotone info tx spec
  else l1CostBedrock info tx spec

/-! ### Operator fee (Isthmus, Jovian) -/

inductive FeeError where
  | missingOperatorFeeParams
  | gasUsedExceedsGasLimit
  | gasPriceBelowBaseFee
  deriving Repr, BEq, DecidableEq

def FeeError.name : FeeError → String
  | .missingOperatorFeeParams => "MissingOperatorFeeParams"
  | .gasUsedExceedsGasLimit => "GasUsedExceedsGasLimit"
  | .gasPriceBelowBaseFee => "GasPriceBelowBaseFee"

/-- Isthmus: `gas * scalar / 1e6 + constant`. Jovian: `gas * scalar * 100 + constant`. -/
def operatorFeeInner (info : L1BlockInfo) (gas : Nat) (spec : OpSpec) : Except FeeError Nat :=
  match info.operatorFeeScalar, info.operatorFeeConstant with
  | some scalar, some constant =>
    let product :=
      if spec.atLeast .jovian then satMul (satMul gas scalar) operatorFeeJovianMultiplier
      else satMul gas scalar / operatorFeeScalarDecimal
    .ok (satAdd product constant)
  | _, _ => .error .missingOperatorFeeParams

/-- Operator fee charged for `gas`; zero before Isthmus, for deposits and empty envelopes. -/
def operatorFee (info : L1BlockInfo) (tx : Bytes) (gas : Nat) (spec : OpSpec) : Except FeeError Nat :=
  if !spec.atLeast .isthmus then .ok 0
  else if tx.size = 0 ∨ isDeposit tx then .ok 0
  else operatorFeeInner info gas spec

/-- Operator fee returned for the unused gas. -/
def operatorFeeRefund (info : L1BlockInfo) (gasLimit gasUsed : Nat) (spec : OpSpec) : Except FeeError Nat :=
  if !spec.atLeast .isthmus then .ok 0
  else do
    let charged ← operatorFeeInner info gasLimit spec
    let used ← operatorFeeInner info gasUsed spec
    pure (charged - used)

/-- L1 data fee plus the operator fee on the gas limit. -/
def txCost (info : L1BlockInfo) (tx : Bytes) (gasLimit : Nat) (spec : OpSpec) : Except FeeError Nat := do
  let operator ← operatorFee info tx gasLimit spec
  pure (satAdd (l1Cost info tx spec) operator)

/-! ### Fee charging and settlement -/

/-- Balance debited from the caller before execution. Deposits pay nothing. -/
def upfrontCost (info : L1BlockInfo) (spec : OpSpec) (tx : Bytes) (gasLimit gasPrice value : Nat) : Except FeeError Nat :=
  if isDeposit tx then .ok 0
  else do
    let extra ← txCost info tx gasLimit spec
    pure (satAdd (satAdd (satMul gasLimit gasPrice) value) extra)

structure Settlement where
  sequencerFeeVault : Nat
  baseFeeVault : Nat
  l1FeeVault : Nat
  operatorFeeVault : Nat
  callerRefund : Nat
  deriving Repr, BEq, DecidableEq

/-- Amounts credited after a transaction executes with `gasUsed` (after refunds). -/
def settle (info : L1BlockInfo) (spec : OpSpec) (tx : Bytes) (gasLimit gasUsed baseFee gasPrice : Nat) : Except FeeError Settlement :=
  if isDeposit tx then .ok ⟨0, 0, 0, 0, 0⟩
  else if gasUsed > gasLimit then .error .gasUsedExceedsGasLimit
  else if gasPrice < baseFee then .error .gasPriceBelowBaseFee
  else do
    let operator ← operatorFee info tx gasUsed spec
    let refund ← operatorFeeRefund info gasLimit gasUsed spec
    pure
      { sequencerFeeVault := satMul gasUsed (gasPrice - baseFee)
        baseFeeVault := satMul gasUsed baseFee
        l1FeeVault := l1Cost info tx spec
        operatorFeeVault := operator
        callerRefund := satAdd (satMul (gasLimit - gasUsed) gasPrice) refund }

/-! ### Jovian DA footprint -/

/-- DA footprint of one transaction: `estimatedSize / 1e6 * daFootprintGasScalar`; zero for deposits. -/
def txDaFootprint (tx : Bytes) (scalar : Nat) : Nat :=
  if isDeposit tx then 0 else satMul64 (estimatedSizeFjord tx / 1000000) scalar

/-- Gas metered for the base-fee update from Jovian: `max(gasUsed, blobGasUsed)`. -/
def gasMetered (gasUsed blobGasUsed : Nat) : Nat := max gasUsed blobGasUsed

/-! ### Deposit transactions (type 0x7E) -/

structure DepositParts where
  mint : Option Nat
  isSystemTransaction : Bool

structure CallerState where
  balance : Nat
  nonce : Nat
  deriving Repr, BEq, DecidableEq

inductive DepositOutcome where
  | success | revert | halt
  deriving Repr, BEq, DecidableEq

/-- Regolith rejects system deposit transactions. -/
def depositValid (spec : OpSpec) (parts : DepositParts) : Bool :=
  !(parts.isSystemTransaction && spec.atLeast .regolith)

/-- Caller state before the frame runs: mint credited, nonce bumped for a CALL. -/
def depositPreExecution (caller : CallerState) (parts : DepositParts) (isCall : Bool) : CallerState :=
  { balance := satAdd caller.balance (parts.mint.getD 0)
    nonce := if isCall then satAdd64 caller.nonce 1 else caller.nonce }

/-- Caller state persisted when a deposit fails: nonce bumped and mint credited. -/
def failedDeposit (callerBefore : CallerState) (parts : DepositParts) : CallerState :=
  { balance := satAdd callerBefore.balance (parts.mint.getD 0), nonce := satAdd64 callerBefore.nonce 1 }

/-- Gas reported for a failed deposit: the gas limit, except Bedrock system transactions (0). -/
def failedDepositGasUsed (spec : OpSpec) (parts : DepositParts) (gasLimit : Nat) : Nat :=
  if spec.atLeast .regolith || !parts.isSystemTransaction then gasLimit else 0

/-- Gas refunds apply to deposits from Regolith. -/
def depositRefundsEnabled (spec : OpSpec) : Bool := spec.atLeast .regolith

/-- Gas used and failure flag of a deposit given the frame outcome. -/
def depositFinalize (spec : OpSpec) (parts : DepositParts) (outcome : DepositOutcome)
    (gasLimit gasUsedAfterRefund : Nat) : Nat × Bool :=
  if spec.atLeast .regolith then
    if outcome == .halt then (failedDepositGasUsed spec parts gasLimit, true)
    else (gasUsedAfterRefund, false)
  else if parts.isSystemTransaction && outcome == .success then (0, false)
  else (gasLimit, false)

/-! ### Precompile limits -/

/-- BN254 pairing input-size limit in bytes; `none` before Granite. -/
def bn254PairingMaxInput (spec : OpSpec) : Option Nat :=
  if spec.atLeast .jovian then some bn254PairingMaxInputJovian
  else if spec.atLeast .granite then some bn254PairingMaxInputGranite
  else none

def bls12G1MsmMaxInput (spec : OpSpec) : Option Nat :=
  if spec.atLeast .jovian then some bls12G1MsmMaxInputJovian
  else if spec.atLeast .isthmus then some bls12G1MsmMaxInputIsthmus
  else none

def bls12G2MsmMaxInput (spec : OpSpec) : Option Nat :=
  if spec.atLeast .jovian then some bls12G2MsmMaxInputJovian
  else if spec.atLeast .isthmus then some bls12G2MsmMaxInputIsthmus
  else none

def bls12PairingMaxInput (spec : OpSpec) : Option Nat :=
  if spec.atLeast .jovian then some bls12PairingMaxInputJovian
  else if spec.atLeast .isthmus then some bls12PairingMaxInputIsthmus
  else none

/-- True when an input of `len` bytes is within the limit (no limit accepts every size). -/
def withinLimit (limit : Option Nat) (len : Nat) : Bool :=
  match limit with
  | some m => decide (len ≤ m)
  | none => true

/-- P256VERIFY (RIP-7212) at `0x100` is available from Fjord. -/
def hasP256Verify (spec : OpSpec) : Bool := spec.atLeast .fjord

/-! ### Base chains and hardfork schedules -/

inductive BaseChain where
  | mainnet | sepolia
  deriving Repr, BEq, DecidableEq

structure Schedule where
  genesis : Nat
  regolith : Nat
  canyon : Nat
  delta : Nat
  ecotone : Nat
  fjord : Nat
  granite : Nat
  holocene : Nat
  isthmus : Nat
  jovian : Nat
  /-- First Base-specific upgrade (Azul); blocks from here on are not modelled. -/
  azul : Nat

def mainnetSchedule : Schedule :=
  { genesis := 1686789347, regolith := 1686789347, canyon := 1704992401, delta := 1708560000
    ecotone := 1710374401, fjord := 1720627201, granite := 1726070401, holocene := 1736445601
    isthmus := 1746806401, jovian := 1764691201, azul := 1779991200 }

def sepoliaSchedule : Schedule :=
  { genesis := 1695768288, regolith := 1695768288, canyon := 1699981200, delta := 1703203200
    ecotone := 1708534800, fjord := 1716998400, granite := 1723478400, holocene := 1732633200
    isthmus := 1744905600, jovian := 1763568001, azul := 1776708000 }

namespace BaseChain

def chainId : BaseChain → Nat
  | mainnet => 8453
  | sepolia => 84532

def l1ChainId : BaseChain → Nat
  | mainnet => 1
  | sepolia => 11155111

def schedule : BaseChain → Schedule
  | mainnet => mainnetSchedule
  | sepolia => sepoliaSchedule

def eip1559Elasticity : BaseChain → Nat
  | mainnet => 6
  | sepolia => 10

def eip1559Denominator (_ : BaseChain) : Nat := 50
def eip1559DenominatorCanyon (_ : BaseChain) : Nat := 250

def ofChainId (id : Nat) : Option BaseChain :=
  if id = 8453 then some mainnet else if id = 84532 then some sepolia else none

end BaseChain

inductive ScheduleError where
  | beforeGenesis
  | unmodeledBaseUpgrade
  deriving Repr, BEq, DecidableEq

def ScheduleError.name : ScheduleError → String
  | .beforeGenesis => "BeforeGenesis"
  | .unmodeledBaseUpgrade => "UnmodeledBaseUpgrade"

/-- Activation timestamp of a spec. -/
def Schedule.activation (s : Schedule) : OpSpec → Nat
  | .bedrock => s.genesis
  | .regolith => s.regolith
  | .canyon => s.canyon
  | .ecotone => s.ecotone
  | .fjord => s.fjord
  | .granite => s.granite
  | .holocene => s.holocene
  | .isthmus => s.isthmus
  | .jovian => s.jovian

/-- Spec active at `timestamp`: the latest spec whose activation time has passed. -/
def Schedule.specAt (s : Schedule) (timestamp : Nat) : Except ScheduleError OpSpec :=
  if timestamp < s.genesis then .error .beforeGenesis
  else if timestamp ≥ s.azul then .error .unmodeledBaseUpgrade
  else
    .ok ((OpSpec.all.reverse.find? (fun spec => decide (timestamp ≥ s.activation spec))).getD .bedrock)

/-! ### Machine-checked reference vectors -/

example : (mainnetSchedule.specAt 1720627201).toOption = some .fjord := by decide
example : (mainnetSchedule.specAt 1686789347).toOption = some .regolith := by decide
example : (mainnetSchedule.specAt 1764691201).toOption = some .jovian := by decide
example : (sepoliaSchedule.specAt 0).toOption = none := by decide
example : (mainnetSchedule.specAt 1779991200).toOption = none := by decide
example : bn254PairingMaxInput .granite = some 112687 := by decide
example : bn254PairingMaxInput .jovian = some 81984 := by decide
example : FastLz.literals 5 0 = 6 := by decide
example : depositFinalize .bedrock ⟨none, true⟩ .success 1000 21 = (0, false) := by decide
example : depositFinalize .regolith ⟨none, false⟩ .halt 1000 21 = (1000, true) := by decide

end Layer2
end GuillotineSpec
