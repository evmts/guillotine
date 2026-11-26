/-
  GuillotineSpec.Main: `lake exe guillotine-lean-ref`

  Line-oriented streaming oracle over stdin/stdout. One request line yields
  exactly one response line, flushed immediately, so a differential fuzzer can
  keep a single process alive for an entire campaign.

  Tokens are separated by single spaces. Numbers are unprefixed lower-case hex,
  byte strings are hex with `-` for the empty string, optional values use `n`
  for "absent", booleans are `0`/`1`. A malformed request answers `ERR bad-request`.

  Requests (first token selects the subsystem):

    W  a b c                      all 26 word opcodes + EXP byte length
    G  <KIND> ...                 gas and refund rules (see `cmdGas`)
    B  fork code                  JUMPDEST bitmap, basic blocks, PUSH immediates
    BF fork code                  straight-line evaluation (fusion equivalence)
    E  fork static gas value calldata codeA codeB balA balB n {a|b slot value}*
                                  full transaction execution
    L  <KIND> ...                 OP Stack / Base rules (see `cmdLayer2`)
    R  <KIND> ...                 RLP (see `cmdRlp`)
    PING                          liveness check, answers `PONG`
-/
import GuillotineSpec.Hex
import GuillotineSpec.Word256
import GuillotineSpec.Gas
import GuillotineSpec.Keccak
import GuillotineSpec.Bytecode
import GuillotineSpec.Evm
import GuillotineSpec.Layer2
import GuillotineSpec.Rlp

namespace GuillotineSpec
namespace Oracle

/-! ### Token helpers -/

def hx (n : Nat) : String := Hex.ofNat n
def nat? (s : String) : Option Nat := Hex.parseNat s
def bytes? (s : String) : Option Bytes := Hex.parseBytes s
def bit (b : Bool) : String := if b then "1" else "0"
def join (xs : List String) : String := " ".intercalate xs

def bool? (s : String) : Option Bool :=
  if s == "1" then some true else if s == "0" then some false else none

def optNat? (s : String) : Option (Option Nat) :=
  if s == "n" then some none else (Hex.parseNat s).map some

def hxOpt : Option Nat → String
  | some v => hx v
  | none => "n"

/-- A word operand: a natural number below `2^256`. -/
def word? (s : String) : Option Nat := do
  let v ← nat? s
  if v < Word256.size then some v else none

/-! ### W: 256-bit word operations -/

def cmdWord : List String → Option String
  | [sa, sb, sc] => do
    let a ← word? sa
    let b ← word? sb
    let c ← word? sc
    pure (join ([Word256.add a b, Word256.mul a b, Word256.sub a b, Word256.div a b, Word256.sdiv a b,
      Word256.mod a b, Word256.smod a b, Word256.addmod a b c, Word256.mulmod a b c, Word256.exp a b,
      Word256.signextend a b, Word256.lt a b, Word256.gt a b, Word256.slt a b, Word256.sgt a b,
      Word256.eq a b, Word256.iszero a, Word256.and a b, Word256.or a b, Word256.xor a b, Word256.not a,
      Word256.byte a b, Word256.shl a b, Word256.shr a b, Word256.sar a b, Word256.clz a,
      Word256.expGasByteLen a].map hx))
  | _ => none

/-! ### G: gas -/

def accessOp? (s : String) : Option Gas.AccessOp :=
  if s == "balance" then some .balance
  else if s == "extcodesize" then some .extcodesize
  else if s == "extcodecopy" then some .extcodecopy
  else if s == "extcodehash" then some .extcodehash
  else if s == "call" then some .call
  else none

def cmdGas : List String → Option String
  | ["SSTORE", fk, o, c, n, cold] => do
    let f ← Fork.ofName fk
    let (gas, refund) := Gas.sstoreCost f (← word? o) (← word? c) (← word? n) (← bool? cold)
    pure s!"{hx gas} {refund} {bit (Gas.sstoreHasSentry f)}"
  | ["SLOAD", fk, cold] => do
    pure (hx (Gas.sloadCost (← Fork.ofName fk) (← bool? cold)))
  | ["ACCESS", fk, op, cold] => do
    pure (hx (Gas.accountAccessCost (← Fork.ofName fk) (← accessOp? op) (← bool? cold)))
  | ["MEM", cur, new] => do
    pure (hx (Gas.memoryExpansionGas (← nat? cur) (← nat? new)))
  | ["MEMW", w] => do
    pure (hx (Gas.memoryCost (← nat? w)))
  | ["CALLX", fk, isCall, cold, hasValue, ex, dead] => do
    pure (hx (Gas.callExtraGas (← Fork.ofName fk) (← bool? isCall) (← bool? cold) (← bool? hasValue)
      (← bool? ex) (← bool? dead)))
  | ["CALLFWD", fk, avail, req] => do
    match Gas.callForwardedGas (← Fork.ofName fk) (← nat? avail) (← nat? req) with
    | some v => pure (hx v)
    | none => pure "OOG"
  | ["CREATE", fk, len] => do
    let f ← Fork.ofName fk
    let n ← nat? len
    pure s!"{hx (Gas.createGas f n)} {hx (Gas.initcodeWordCost f n)} {hx (Gas.initcodeSizeLimit f)}"
  | ["SD", fk, cold, hasBal, ex, dead] => do
    let f ← Fork.ofName fk
    pure s!"{hx (Gas.selfdestructGas f (← bool? cold) (← bool? hasBal) (← bool? ex) (← bool? dead))} {hx (Gas.selfdestructRefund f)}"
  | ["TX", fk, data] => do
    let f ← Fork.ofName fk
    let d ← bytes? data
    let tokens := Gas.calldataTokens f d
    pure s!"{hx tokens} {hx (Gas.intrinsicGas f d false)} {hx (Gas.intrinsicGas f d true)} {hx (Gas.calldataFloorGas f tokens)}"
  | ["REFUND", fk, limit, left, counter] => do
    let f ← Fork.ofName fk
    let limit ← nat? limit
    let left ← nat? left
    let counter ← nat? counter
    if left > limit then none
    else pure s!"{hx (Gas.refundCap f (limit - left) counter)} {hx (Gas.applyRefund f limit left counter)}"
  | ["BLOB", fk, excess] => do
    pure (hx (Gas.blobBaseFee (← Fork.ofName fk) (← nat? excess)))
  | ["EXCESS", fk, parentExcess, used, baseFee] => do
    pure (hx (Gas.excessBlobGas (← Fork.ofName fk) (← nat? parentExcess) (← nat? used) (← nat? baseFee)))
  | ["MODEXP", fk, bl, el, ml, head] => do
    match Gas.modexpGas (← Fork.ofName fk) (← nat? bl) (← nat? el) (← nat? ml) (← nat? head) with
    | some g => pure (hx g)
    | none => pure "INVALID"
  | ["EXP", fk, e] => do
    pure (hx (Gas.expGas (← Fork.ofName fk) (← word? e)))
  | ["COPY", len] => do
    let n ← nat? len
    pure s!"{hx (Gas.copyGas n)} {hx (Gas.keccakGas n)}"
  | ["LOG", topics, len] => do
    pure (hx (Gas.logGas (← nat? topics) (← nat? len)))
  | ["STATIC", fk, op] => do
    pure (hx (Bytecode.staticGas (← Fork.ofName fk) (← nat? op)))
  | _ => none

/-! ### B / BF: bytecode analysis -/

/-- Pack booleans into bytes, least significant bit first. -/
def packBits (bits : Array Bool) : Bytes := Id.run do
  let mut out := ByteArray.emptyWithCapacity ((bits.size + 7) / 8)
  for i in [0:(bits.size + 7) / 8] do
    let mut b : Nat := 0
    for k in [0:8] do
      if bits.getD (i * 8 + k) false then b := b + 2 ^ k
    out := out.push (UInt8.ofNat b)
  return out

def cmdBytecode : List String → Option String
  | [fk, codeHex] => do
    let f ← Fork.ofName fk
    let code ← bytes? codeHex
    let dests := Bytecode.jumpdests code
    let blocks := Bytecode.blocks f code
    let starts := Bytecode.instructionStarts code
    let pushes := starts.toList.filter (fun pc => Bytecode.pushSize (Bytes.getZ code pc) > 0)
    let blockToks := blocks.toList.flatMap (fun (pc, info) => [hx pc, hx info.gas, hx info.minStack, hx info.maxStack])
    let pushToks := pushes.flatMap (fun pc => [hx pc, hx (Bytecode.pushValue code pc)])
    pure (join ([Hex.ofBytes (packBits dests), hx starts.size, hx blocks.size] ++ blockToks ++ [hx pushes.length] ++ pushToks))
  | _ => none

def cmdFold : List String → Option String
  | [fk, codeHex] => do
    let f ← Fork.ofName fk
    let code ← bytes? codeHex
    match Bytecode.evalStraightLine f code with
    | some stack => pure s!"OK {hx stack.length} {hx (stack.headD 0)}"
    | none => pure "FAULT"
  | _ => none

/-! ### E: transaction execution -/

/-- Fixed world shared with `test/fuzz/lean_differential_fuzz.zig`. -/
def originAddr : Nat := 0xaaaa01
def contractA : Nat := 0xc0de0a
def contractB : Nat := 0xc0de0b
def eoaAddr : Nat := 0xe0a001
def deadAddr : Nat := 0xdead01
def coinbaseAddr : Nat := 0xc01b01
def originBalance : Nat := 1000000000000000000000000
def eoaBalance : Nat := 12345

/-- Storage slots reported in the post-state. -/
def probeSlots : List Nat :=
  [0, 1, 2, 3, 4, 5, 6, 7, 2 ^ 256 - 1, 2 ^ 255, 0xdeadbeef, 2 ^ 160]

def reportAddrs : List Nat := [originAddr, contractA, contractB, eoaAddr, deadAddr, coinbaseAddr]

def baseCtx (f : Fork) (storage0 : Evm.SlotMap) : Evm.Ctx :=
  { fork := f
    origin := originAddr
    gasPrice := 0
    coinbase := coinbaseAddr
    timestamp := 1700000000
    number := 20000000
    difficulty := 0x20000
    prevRandao := 0x1122334455667788990011223344556677889900112233445566778899001122
    gasLimit := 30000000
    chainId := 1
    baseFee := 7
    blobBaseFee := 3
    storage0 := storage0 }

private def parseSlots : Nat → List String → Evm.SlotMap → Option Evm.SlotMap
  | 0, [], acc => some acc
  | n + 1, who :: slot :: val :: rest, acc => do
    let addr ← if who == "a" then some contractA else if who == "b" then some contractB else none
    let s ← word? slot
    let v ← word? val
    parseSlots n rest (((addr, s), v) :: acc.filter (fun e => !(e.1 == (addr, s))))
  | _, _, _ => none

def statusLetter : Evm.Status → String
  | .success => "S"
  | .revert => "R"
  | .failure => "F"
  | .unsupported => "U"
  | .outOfFuel => "X"

def showLog (l : Evm.Log) : List String :=
  [hx l.address, hx l.topics.length] ++ l.topics.map hx ++ [Hex.ofBytes l.data]

def cmdExec : List String → Option String
  | fk :: static :: gas :: value :: calldata :: codeA :: codeB :: balA :: balB :: n :: slots => do
    let f ← Fork.ofName fk
    let isStatic ← bool? static
    let gasLimit ← nat? gas
    let value ← word? value
    let calldata ← bytes? calldata
    let codeA ← bytes? codeA
    let codeB ← bytes? codeB
    let balA ← word? balA
    let balB ← word? balB
    let count ← nat? n
    let storage0 ← parseSlots count slots []
    let pre : Evm.State :=
      { accounts :=
          [ (originAddr, { balance := originBalance, nonce := 1 })
          , (contractA, { balance := balA, nonce := 1, code := codeA })
          , (contractB, { balance := balB, nonce := 1, code := codeB })
          , (eoaAddr, { balance := eoaBalance }) ]
        storage := storage0 }
    let r := Evm.runTx (baseCtx f storage0) isStatic contractA gasLimit value calldata pre
    match r.status with
    | .unsupported => pure s!"U {r.reason.replace " " "_"}"
    | .outOfFuel => pure "X"
    | _ =>
      let logs := r.logs.toList.flatMap showLog
      let balances := reportAddrs.map (fun a => hx (r.state.balance a))
      let slotsOf (a : Nat) := probeSlots.map (fun s => hx (r.state.sload a s))
      pure (join ([statusLetter r.status, hx r.gasLeft, Hex.ofBytes r.output, hx r.logs.size] ++ logs
        ++ ["B"] ++ balances ++ ["SA"] ++ slotsOf contractA ++ ["SB"] ++ slotsOf contractB))
  | _ => none

/-! ### L: OP Stack and Base -/

def showFee (r : Except Layer2.FeeError Nat) : String :=
  match r with
  | .ok v => hx v
  | .error e => s!"ERR {e.name}"

/-- `l1BaseFee overhead baseFeeScalar blobBaseFee blobScalar operatorScalar operatorConstant emptyEcotone` -/
def parseInfo : List String → Option Layer2.L1BlockInfo
  | [baseFee, overhead, scalar, blobFee, blobScalar, opScalar, opConst, emptyEcotone] => do
    pure
      { l1BaseFee := (← word? baseFee)
        l1FeeOverhead := (← optNat? overhead)
        l1BaseFeeScalar := (← word? scalar)
        l1BlobBaseFee := (← optNat? blobFee)
        l1BlobBaseFeeScalar := (← optNat? blobScalar)
        operatorFeeScalar := (← optNat? opScalar)
        operatorFeeConstant := (← optNat? opConst)
        emptyEcotoneScalars := (← bool? emptyEcotone) }
  | _ => none

def chain? (s : String) : Option Layer2.BaseChain :=
  if s == "mainnet" then some .mainnet else if s == "sepolia" then some .sepolia else none

def outcome? (s : String) : Option Layer2.DepositOutcome :=
  if s == "success" then some .success
  else if s == "revert" then some .revert
  else if s == "halt" then some .halt
  else none

def cmdLayer2 : List String → Option String
  | ["FLZ", tx] => do
    let b ← bytes? tx
    pure s!"{hx (Layer2.FastLz.compressLen b)} {hx (Layer2.estimatedSizeFjord b)}"
  | ["DATAGAS", spec, tx] => do
    pure (hx (Layer2.dataGas (← bytes? tx) (← Layer2.OpSpec.ofName spec)))
  | "L1COST" :: spec :: tx :: info => do
    pure (hx (Layer2.l1Cost (← parseInfo info) (← bytes? tx) (← Layer2.OpSpec.ofName spec)))
  | "OPFEE" :: spec :: tx :: gas :: info => do
    pure (showFee (Layer2.operatorFee (← parseInfo info) (← bytes? tx) (← nat? gas) (← Layer2.OpSpec.ofName spec)))
  | "OPREFUND" :: spec :: gasLimit :: gasUsed :: info => do
    pure (showFee (Layer2.operatorFeeRefund (← parseInfo info) (← nat? gasLimit) (← nat? gasUsed) (← Layer2.OpSpec.ofName spec)))
  | "UPFRONT" :: spec :: tx :: gasLimit :: gasPrice :: value :: info => do
    pure (showFee (Layer2.upfrontCost (← parseInfo info) (← Layer2.OpSpec.ofName spec) (← bytes? tx) (← nat? gasLimit)
      (← word? gasPrice) (← word? value)))
  | "SETTLE" :: spec :: tx :: gasLimit :: gasUsed :: baseFee :: gasPrice :: info => do
    match Layer2.settle (← parseInfo info) (← Layer2.OpSpec.ofName spec) (← bytes? tx) (← nat? gasLimit) (← nat? gasUsed)
        (← word? baseFee) (← word? gasPrice) with
    | .ok s => pure (join [hx s.sequencerFeeVault, hx s.baseFeeVault, hx s.l1FeeVault, hx s.operatorFeeVault, hx s.callerRefund])
    | .error e => pure s!"ERR {e.name}"
  | ["DA", tx, scalar] => do
    pure (hx (Layer2.txDaFootprint (← bytes? tx) (← nat? scalar)))
  | ["DEPOSIT", spec, mint, isSystem, outcome, gasLimit, gasUsed, balance, nonce, isCall] => do
    let spec ← Layer2.OpSpec.ofName spec
    let parts : Layer2.DepositParts := { mint := (← optNat? mint), isSystemTransaction := (← bool? isSystem) }
    let caller : Layer2.CallerState := { balance := (← word? balance), nonce := (← nat? nonce) }
    let gasLimit ← nat? gasLimit
    let pre := Layer2.depositPreExecution caller parts (← bool? isCall)
    let failed := Layer2.failedDeposit caller parts
    let (finGas, finFailed) := Layer2.depositFinalize spec parts (← outcome? outcome) gasLimit (← nat? gasUsed)
    pure (join [bit (Layer2.depositValid spec parts), hx pre.balance, hx pre.nonce, hx failed.balance, hx failed.nonce,
      hx (Layer2.failedDepositGasUsed spec parts gasLimit), bit (Layer2.depositRefundsEnabled spec), hx finGas, bit finFailed])
  | ["SPECAT", chain, ts] => do
    let c ← chain? chain
    let t ← nat? ts
    match c.schedule.specAt t with
    | .ok spec =>
      pure (join [spec.name, hxOpt (Layer2.bn254PairingMaxInput spec), bit (Layer2.hasP256Verify spec), spec.ethHardforkName])
    | .error e => pure s!"ERR {e.name}"
  | ["LIMITS", spec] => do
    let s ← Layer2.OpSpec.ofName spec
    pure (join [hxOpt (Layer2.bn254PairingMaxInput s), hxOpt (Layer2.bls12G1MsmMaxInput s), hxOpt (Layer2.bls12G2MsmMaxInput s),
      hxOpt (Layer2.bls12PairingMaxInput s), bit (Layer2.hasP256Verify s), s.ethHardforkName])
  | ["BN254", spec, len] => do
    pure (bit (Layer2.withinLimit (Layer2.bn254PairingMaxInput (← Layer2.OpSpec.ofName spec)) (← nat? len)))
  | ["CHAIN", chain] => do
    let c ← chain? chain
    let s := c.schedule
    pure (join ([hx c.chainId, hx c.l1ChainId, hx c.eip1559Elasticity, hx c.eip1559Denominator, hx c.eip1559DenominatorCanyon,
      hx s.delta, hx s.azul] ++ Layer2.OpSpec.all.map (fun spec => hx (s.activation spec))))
  | _ => none

/-! ### R: RLP -/

mutual
  def showItem : Rlp.Item → List String
    | .str b => [s!"s{Hex.ofBytes b}"]
    | .list xs => s!"l{xs.length}" :: showItems xs

  def showItems : List Rlp.Item → List String
    | [] => []
    | x :: xs => showItem x ++ showItems xs
end

mutual
  def parseItem : Nat → List String → Option (Rlp.Item × List String)
    | 0, _ => none
    | _, [] => none
    | fuel + 1, tok :: rest =>
      match tok.toList with
      | 's' :: cs => (Hex.parseBytes (String.ofList cs)).map (fun b => (.str b, rest))
      | 'l' :: cs => do
        let n ← Hex.parseDec (String.ofList cs)
        let (xs, rest') ← parseItems fuel n rest []
        pure (.list xs, rest')
      | _ => none

  def parseItems : Nat → Nat → List String → List Rlp.Item → Option (List Rlp.Item × List String)
    | 0, _, _, _ => none
    | _, 0, toks, acc => some (acc.reverse, toks)
    | fuel + 1, n + 1, toks, acc => do
      let (x, rest) ← parseItem fuel toks
      parseItems fuel n rest (x :: acc)
end

def cmdRlp : List String → Option String
  | "ENC" :: toks => do
    let (item, rest) ← parseItem (2 * toks.length + 4) toks
    if rest.isEmpty then pure (Hex.ofBytes (Rlp.encode item)) else none
  | ["DEC", input, stream] => do
    match Rlp.decode (← bytes? input) (← bool? stream) with
    | .ok (item, remainder) => pure (join (["OK"] ++ showItem item ++ [Hex.ofBytes remainder]))
    | .error e => pure s!"ERR {e.name}"
  | ["NAT", n] => do
    pure (Hex.ofBytes (Rlp.encodeNat (← nat? n)))
  | _ => none

/-! ### Dispatch -/

def handle (line : String) : String :=
  let toks := line.splitOn " "
  let answer : Option String :=
    match toks with
    | ["PING"] => some "PONG"
    | "W" :: rest => cmdWord rest
    | "G" :: rest => cmdGas rest
    | "B" :: rest => cmdBytecode rest
    | "BF" :: rest => cmdFold rest
    | "E" :: rest => cmdExec rest
    | "L" :: rest => cmdLayer2 rest
    | "R" :: rest => cmdRlp rest
    | _ => none
  answer.getD "ERR bad-request"

end Oracle
end GuillotineSpec

/-- Serve requests until end of input. The bound only makes the loop total; at one
    request per nanosecond it would take three centuries to reach. -/
def main : IO Unit := do
  let stdin ← IO.getStdin
  let stdout ← IO.getStdout
  for _ in [0:10000000000000000000] do
    let raw ← stdin.getLine
    if raw.isEmpty then break
    let line := String.ofList (raw.toList.filter (fun c => c != '\n' && c != '\r'))
    stdout.putStrLn (GuillotineSpec.Oracle.handle line)
    stdout.flush
