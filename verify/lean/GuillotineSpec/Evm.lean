/-
  GuillotineSpec.Evm

  Executable small-step reference interpreter for the EVM, Frontier through Osaka.

  The machine is the Yellow Paper machine: a 1024-word stack, word-addressed
  lazily grown memory, persistent and transient (EIP-1153) storage, an EIP-2929
  access list, an explicit journal with checkpoints that is rolled back on
  revert and on every exceptional halt, logs, EIP-214 static-call write
  protection and message calls (CALL, CALLCODE, DELEGATECALL, STATICCALL).

  It is total. `run` recurses structurally on a fuel argument; every
  non-halting instruction costs at least one gas, so `gasLimit + 1040` fuel can
  never run out (running out is reported as `Status.outOfFuel`, never hidden).

  Out of scope, reported as `Status.unsupported` instead of being guessed:
  CREATE, CREATE2, BLOCKHASH, and calls into precompiles or system contracts.

  Zig counterparts: `src/evm.zig`, `src/frame/frame.zig`, `src/instructions/handlers_*.zig`.
-/
import GuillotineSpec.Hex
import GuillotineSpec.Word256
import GuillotineSpec.Gas
import GuillotineSpec.Bytecode
import GuillotineSpec.Keccak

namespace GuillotineSpec
namespace Evm

/-! ### World state -/

structure Account where
  balance : Nat := 0
  nonce : Nat := 0
  code : Bytes := ByteArray.empty

/-- EIP-161 emptiness: no balance, no nonce, no code. -/
def Account.isEmpty (a : Account) : Bool := a.balance == 0 && a.nonce == 0 && a.code.size == 0

structure Log where
  address : Nat
  topics : List Nat
  data : Bytes

/-- One reversible state change. The journal is the list of entries, newest first. -/
inductive JournalEntry where
  | storage (addr slot prev : Nat)
  | transient (addr slot prev : Nat)
  | account (addr : Nat) (prev : Option Account)
  | warmAddr (addr : Nat)
  | warmSlot (addr slot : Nat)
  | log
  | refund (prev : Int)
  | destruct (addr : Nat)

abbrev SlotMap := List ((Nat × Nat) × Nat)

structure State where
  accounts : List (Nat × Account) := []
  storage : SlotMap := []
  transient : SlotMap := []
  warmAddrs : List Nat := []
  warmSlots : List (Nat × Nat) := []
  logs : Array Log := #[]
  refund : Int := 0
  destructed : List Nat := []
  journal : List JournalEntry := []
  journalLen : Nat := 0

namespace State

private def setKey {κ ν : Type} [BEq κ] (l : List (κ × ν)) (k : κ) (v : ν) : List (κ × ν) :=
  (k, v) :: l.filter (fun e => !(e.1 == k))

private def eraseKey {κ ν : Type} [BEq κ] (l : List (κ × ν)) (k : κ) : List (κ × ν) :=
  l.filter (fun e => !(e.1 == k))

@[inline] private def record (st : State) (e : JournalEntry) : State :=
  { st with journal := e :: st.journal, journalLen := st.journalLen + 1 }

def account? (st : State) (a : Nat) : Option Account := st.accounts.lookup a
def balance (st : State) (a : Nat) : Nat := ((st.account? a).map (·.balance)).getD 0
def code (st : State) (a : Nat) : Bytes := ((st.account? a).map (·.code)).getD ByteArray.empty
def sload (st : State) (a s : Nat) : Nat := (st.storage.lookup (a, s)).getD 0
def tload (st : State) (a s : Nat) : Nat := (st.transient.lookup (a, s)).getD 0

def setAccount (st : State) (a : Nat) (acc : Option Account) : State :=
  let st' := st.record (.account a (st.account? a))
  match acc with
  | some v => { st' with accounts := setKey st'.accounts a v }
  | none => { st' with accounts := eraseKey st'.accounts a }

def setBalance (st : State) (a b : Nat) : State :=
  st.setAccount a (some { ((st.account? a).getD {}) with balance := b })

def sstore (st : State) (a s v : Nat) : State :=
  let st' := st.record (.storage a s (st.sload a s))
  { st' with storage := setKey st'.storage (a, s) v }

def tstore (st : State) (a s v : Nat) : State :=
  let st' := st.record (.transient a s (st.tload a s))
  { st' with transient := setKey st'.transient (a, s) v }

/-- Warm an address (EIP-2929). Precompiles are warm from the start of the transaction. -/
def isWarmAddr (st : State) (f : Fork) (a : Nat) : Bool := st.warmAddrs.contains a || Gas.isPrecompile f a

def warmAddr (st : State) (a : Nat) : State :=
  if st.warmAddrs.contains a then st
  else { st.record (.warmAddr a) with warmAddrs := a :: st.warmAddrs }

def isWarmSlot (st : State) (a s : Nat) : Bool := st.warmSlots.contains (a, s)

def warmSlot (st : State) (a s : Nat) : State :=
  if st.warmSlots.contains (a, s) then st
  else { st.record (.warmSlot a s) with warmSlots := (a, s) :: st.warmSlots }

def addLog (st : State) (l : Log) : State := { st.record .log with logs := st.logs.push l }

def setRefund (st : State) (r : Int) : State := { st.record (.refund st.refund) with refund := r }

def addDestruct (st : State) (a : Nat) : State :=
  if st.destructed.contains a then st
  else { st.record (.destruct a) with destructed := a :: st.destructed }

/-- Checkpoint: the journal length to roll back to. -/
@[inline] def checkpoint (st : State) : Nat := st.journalLen

private def undo (st : State) : JournalEntry → State
  | .storage a s prev => { st with storage := setKey st.storage (a, s) prev }
  | .transient a s prev => { st with transient := setKey st.transient (a, s) prev }
  | .account a (some prev) => { st with accounts := setKey st.accounts a prev }
  | .account a none => { st with accounts := eraseKey st.accounts a }
  | .warmAddr a => { st with warmAddrs := st.warmAddrs.erase a }
  | .warmSlot a s => { st with warmSlots := st.warmSlots.erase (a, s) }
  | .log => { st with logs := st.logs.pop }
  | .refund prev => { st with refund := prev }
  | .destruct a => { st with destructed := st.destructed.erase a }

private def rollbackLoop : Nat → State → Nat → State
  | 0, st, _ => st
  | fuel + 1, st, cp =>
    if st.journalLen ≤ cp then st
    else
      match st.journal with
      | [] => st
      | e :: rest => rollbackLoop fuel (undo { st with journal := rest, journalLen := st.journalLen - 1 } e) cp

/-- Undo every change made since checkpoint `cp`. -/
def rollback (st : State) (cp : Nat) : State := rollbackLoop st.journalLen st cp

end State

/-! ### Execution context -/

/-- Block and transaction constants. `storage0` is storage at transaction start
    (the "original" value of EIP-1283/2200 net metering). -/
structure Ctx where
  fork : Fork
  origin : Nat
  gasPrice : Nat
  coinbase : Nat
  timestamp : Nat
  number : Nat
  difficulty : Nat
  prevRandao : Nat
  gasLimit : Nat
  chainId : Nat
  baseFee : Nat
  blobBaseFee : Nat
  storage0 : SlotMap

structure Frame where
  code : Bytes
  dests : Array Bool
  pc : Nat := 0
  gas : Nat
  /-- Stack, top first. -/
  stack : List Nat := []
  /-- Number of stack items (at most 1024). -/
  sp : Nat := 0
  /-- Memory; its size is always a multiple of 32. -/
  memory : ByteArray := ByteArray.empty
  /-- Account whose storage and balance the frame acts on. -/
  address : Nat
  caller : Nat
  value : Nat
  calldata : Bytes
  isStatic : Bool
  returnData : Bytes := ByteArray.empty
  depth : Nat := 0

inductive Status where
  | success | revert | failure | unsupported | outOfFuel
  deriving Repr, BEq, DecidableEq

structure Outcome where
  status : Status
  gasLeft : Nat
  output : Bytes
  reason : String := ""

inductive Step where
  | next (fr : Frame) (st : State)
  | halt (o : Outcome) (st : State)
  | call (child : Frame) (cp : Nat) (parent : Frame) (outOff outLen : Nat) (st : State)

def stackLimit : Nat := 1024
def callDepthLimit : Nat := 1024
def addressMask : Nat := 2 ^ 160

/-- EIP-4788 beacon roots and EIP-2935 history contracts, executed natively by Guillotine. -/
def isSystemAddress (a : Nat) : Bool :=
  a == 0x000F3df6D732807Ef1319fB7B8bB8522d0Beac02 || a == 0x0000F90827F1C53a10cb7A02335B175320002935

/-! ### Memory -/

@[inline] def rangeEnd (off len : Nat) : Nat := if len = 0 then 0 else off + len

/-- Gas to make `[off, off + len)` addressable; a zero-length range never expands memory. -/
def rangeCost (mem : ByteArray) (off len : Nat) : Nat := Gas.memoryExpansionGas mem.size (rangeEnd off len)

/-- Grow memory to the 32-byte word boundary covering `endB`. -/
def memExtend (mem : ByteArray) (endB : Nat) : ByteArray :=
  let target := Gas.words endB * 32
  if target ≤ mem.size then mem else mem ++ Bytes.zeros (target - mem.size)

def memRead (mem : ByteArray) (off len : Nat) : ByteArray :=
  if len = 0 then ByteArray.empty else mem.extract off (off + len)

def memWrite (mem : ByteArray) (off : Nat) (data : ByteArray) : ByteArray :=
  if data.size = 0 then mem else data.copySlice 0 mem off data.size

/-! ### Step helpers -/

@[inline] def failWith (st : State) (why : String) : Step :=
  .halt { status := .failure, gasLeft := 0, output := ByteArray.empty, reason := why } st

@[inline] def unsupported (st : State) (what : String) : Step :=
  .halt { status := .unsupported, gasLeft := 0, output := ByteArray.empty, reason := what } st

/-- Charge `cost`, replace the stack by `v :: rest` (after popping `popped` items) and advance. -/
@[inline] def pushResult (fr : Frame) (st : State) (cost popped : Nat) (rest : List Nat) (v : Nat) : Step :=
  if fr.gas < cost then failWith st "out of gas"
  else if fr.sp - popped ≥ stackLimit then failWith st "stack overflow"
  else .next { fr with gas := fr.gas - cost, stack := v :: rest, sp := fr.sp - popped + 1, pc := fr.pc + 1 } st

/-- Push a context value: no operands. -/
@[inline] def pushConst (fr : Frame) (st : State) (cost v : Nat) : Step := pushResult fr st cost 0 fr.stack v

/-- Finish a message call in the caller: return gas, copy output, push the success flag. -/
def resume (parent : Frame) (o : Outcome) (outOff outLen : Nat) : Frame :=
  let out := if o.status == .failure then ByteArray.empty else o.output
  let n := min outLen out.size
  let mem := if n = 0 then parent.memory else memWrite parent.memory outOff (out.extract 0 n)
  { parent with
    gas := parent.gas + o.gasLeft
    memory := mem
    returnData := out
    stack := (if o.status == .success then 1 else 0) :: parent.stack
    sp := parent.sp + 1 }

inductive CallKind where
  | call | callcode | delegatecall | staticcall
  deriving Repr, BEq, DecidableEq

/-- Move `value` from `src` to `dst`, creating `dst` when it does not exist. -/
def transfer (st : State) (src dst value : Nat) : State :=
  if value = 0 ∨ src = dst then st
  else
    let st1 := st.setBalance src (st.balance src - value)
    st1.setBalance dst (st1.balance dst + value)

/-- CALL, CALLCODE, DELEGATECALL, STATICCALL. -/
def stepCall (ctx : Ctx) (fr : Frame) (st : State) (kind : CallKind) : Step :=
  let f := ctx.fork
  let hasValueArg := kind == .call || kind == .callcode
  let args : Option (Nat × Nat × Nat × Nat × Nat × Nat × Nat × List Nat) :=
    match hasValueArg, fr.stack with
    | true, g :: a :: v :: io :: il :: oo :: ol :: rest => some (g, a, v, io, il, oo, ol, rest)
    | false, g :: a :: io :: il :: oo :: ol :: rest => some (g, a, 0, io, il, oo, ol, rest)
    | _, _ => none
  match args with
  | none => failWith st "stack underflow"
  | some (gasReq, addrWord, value, inOff, inLen, outOff, outLen, rest) =>
    let target := addrWord % addressMask
    let popped := if hasValueArg then 7 else 6
    let memEnd := max (rangeEnd inOff inLen) (rangeEnd outOff outLen)
    let memCost := Gas.memoryExpansionGas fr.memory.size memEnd
    let cold := Gas.hasAccessLists f && !st.isWarmAddr f target
    let st1 := if Gas.hasAccessLists f then st.warmAddr target else st
    let tAcc := st1.account? target
    let dead := match tAcc with
      | some a => a.isEmpty
      | none => true
    let extra := Gas.callExtraGas f (kind == .call) cold (value != 0) tAcc.isSome dead
    if fr.gas < memCost + extra then failWith st "out of gas"
    else if kind == .call && value != 0 && fr.isStatic then failWith st "write protection"
    else
      let gas1 := fr.gas - (memCost + extra)
      match Gas.callForwardedGas f gas1 gasReq with
      | none => failWith st "out of gas"
      | some fwd =>
        let childGas := fwd + Gas.callStipendFor (value != 0)
        let mem := memExtend fr.memory memEnd
        let input := memRead mem inOff inLen
        let parent : Frame :=
          { fr with gas := gas1 - fwd, memory := mem, stack := rest, sp := fr.sp - popped, pc := fr.pc + 1 }
        if fr.depth + 1 > callDepthLimit || (hasValueArg && value > st1.balance fr.address) then
          .next (resume parent { status := .failure, gasLeft := childGas, output := ByteArray.empty } outOff outLen) st1
        else if Gas.isPrecompile f target || isSystemAddress target then
          unsupported st1 "call to precompile or system contract"
        else
          let cp := st1.checkpoint
          let st2 :=
            if kind == .call then
              let moved := transfer st1 fr.address target value
              -- Before EIP-161 a CALL brings a non-existent target into existence.
              if !f.atLeast .spuriousDragon && (moved.account? target).isNone then moved.setAccount target (some {})
              else moved
            else st1
          let code := (tAcc.map (·.code)).getD ByteArray.empty
          if code.size == 0 then
            .next (resume parent { status := .success, gasLeft := childGas, output := ByteArray.empty } outOff outLen) st2
          else
            let child : Frame :=
              { code := code
                dests := Bytecode.jumpdests code
                gas := childGas
                address := if kind == .call || kind == .staticcall then target else fr.address
                caller := if kind == .delegatecall then fr.caller else fr.address
                value := if kind == .delegatecall then fr.value else value
                calldata := input
                isStatic := fr.isStatic || kind == .staticcall
                depth := fr.depth + 1 }
            .call child cp parent outOff outLen st2

/-- SELFDESTRUCT. -/
def stepSelfdestruct (ctx : Ctx) (fr : Frame) (st : State) : Step :=
  let f := ctx.fork
  match fr.stack with
  | [] => failWith st "stack underflow"
  | w :: _ =>
    if fr.isStatic then failWith st "write protection"
    else
      let ben := w % addressMask
      let cold := Gas.hasAccessLists f && !st.isWarmAddr f ben
      let st1 := if Gas.hasAccessLists f then st.warmAddr ben else st
      let bal := st1.balance fr.address
      let bAcc := st1.account? ben
      let dead := match bAcc with
        | some a => a.isEmpty
        | none => true
      let cost := Gas.selfdestructGas f cold (bal != 0) bAcc.isSome dead
      if fr.gas < cost then failWith st "out of gas"
      else
        let st2 :=
          if Gas.selfdestructRefund f != 0 && !st1.destructed.contains fr.address then
            st1.setRefund (st1.refund + (Gas.selfdestructRefund f : Nat))
          else st1
        let st3 :=
          if f.atLeast .cancun then
            -- EIP-6780: an account not created in this transaction only sends its balance.
            transfer st2 fr.address ben bal
          else
            let moved :=
              if ben = fr.address then st2.setBalance fr.address 0
              else (st2.setBalance ben (st2.balance ben + bal)).setBalance fr.address 0
            moved.addDestruct fr.address
        .halt { status := .success, gasLeft := fr.gas - cost, output := ByteArray.empty } st3

/-- Instructions other than the pure word operations. -/
def stepOther (ctx : Ctx) (fr : Frame) (st : State) (op : Nat) : Step :=
  let f := ctx.fork
  let self := fr.address
  if op = 0x00 then .halt { status := .success, gasLeft := fr.gas, output := ByteArray.empty } st
  else if op = 0x20 then
    match fr.stack with
    | off :: len :: rest =>
      let cost := Gas.keccakGas len + rangeCost fr.memory off len
      if fr.gas < cost then failWith st "out of gas"
      else
        let mem := memExtend fr.memory (rangeEnd off len)
        pushResult { fr with memory := mem } st cost 2 rest (Keccak.hashWord (memRead mem off len))
    | _ => failWith st "stack underflow"
  else if op = 0x30 then pushConst fr st 2 self
  else if op = 0x31 then
    match fr.stack with
    | w :: rest =>
      let a := w % addressMask
      let cold := Gas.hasAccessLists f && !st.isWarmAddr f a
      let st1 := if Gas.hasAccessLists f then st.warmAddr a else st
      pushResult fr st1 (Gas.accountAccessCost f .balance cold) 1 rest (st1.balance a)
    | _ => failWith st "stack underflow"
  else if op = 0x32 then pushConst fr st 2 ctx.origin
  else if op = 0x33 then pushConst fr st 2 fr.caller
  else if op = 0x34 then pushConst fr st 2 fr.value
  else if op = 0x35 then
    match fr.stack with
    | off :: rest => pushResult fr st 3 1 rest (Bytes.toNat (Bytes.sliceZ fr.calldata off 32))
    | _ => failWith st "stack underflow"
  else if op = 0x36 then pushConst fr st 2 fr.calldata.size
  else if op = 0x37 ∨ op = 0x39 then
    match fr.stack with
    | dst :: off :: len :: rest =>
      let cost := 3 + Gas.copyGas len + rangeCost fr.memory dst len
      if fr.gas < cost then failWith st "out of gas"
      else
        let src := if op = 0x37 then fr.calldata else fr.code
        let mem := memWrite (memExtend fr.memory (rangeEnd dst len)) dst (Bytes.sliceZ src off len)
        .next { fr with gas := fr.gas - cost, memory := mem, stack := rest, sp := fr.sp - 3, pc := fr.pc + 1 } st
    | _ => failWith st "stack underflow"
  else if op = 0x38 then pushConst fr st 2 fr.code.size
  else if op = 0x3a then pushConst fr st 2 ctx.gasPrice
  else if op = 0x3b then
    match fr.stack with
    | w :: rest =>
      let a := w % addressMask
      let cold := Gas.hasAccessLists f && !st.isWarmAddr f a
      let st1 := if Gas.hasAccessLists f then st.warmAddr a else st
      pushResult fr st1 (Gas.accountAccessCost f .extcodesize cold) 1 rest (st1.code a).size
    | _ => failWith st "stack underflow"
  else if op = 0x3c then
    match fr.stack with
    | w :: dst :: off :: len :: rest =>
      let a := w % addressMask
      let cold := Gas.hasAccessLists f && !st.isWarmAddr f a
      let st1 := if Gas.hasAccessLists f then st.warmAddr a else st
      let cost := Gas.accountAccessCost f .extcodecopy cold + Gas.copyGas len + rangeCost fr.memory dst len
      if fr.gas < cost then failWith st "out of gas"
      else
        let mem := memWrite (memExtend fr.memory (rangeEnd dst len)) dst (Bytes.sliceZ (st1.code a) off len)
        .next { fr with gas := fr.gas - cost, memory := mem, stack := rest, sp := fr.sp - 4, pc := fr.pc + 1 } st1
    | _ => failWith st "stack underflow"
  else if op = 0x3d then pushConst fr st 2 fr.returnData.size
  else if op = 0x3e then
    match fr.stack with
    | dst :: off :: len :: rest =>
      if off + len > fr.returnData.size then failWith st "return data out of bounds"
      else
        let cost := 3 + Gas.copyGas len + rangeCost fr.memory dst len
        if fr.gas < cost then failWith st "out of gas"
        else
          let mem := memWrite (memExtend fr.memory (rangeEnd dst len)) dst (Bytes.sliceZ fr.returnData off len)
          .next { fr with gas := fr.gas - cost, memory := mem, stack := rest, sp := fr.sp - 3, pc := fr.pc + 1 } st
    | _ => failWith st "stack underflow"
  else if op = 0x3f then
    match fr.stack with
    | w :: rest =>
      let a := w % addressMask
      let cold := Gas.hasAccessLists f && !st.isWarmAddr f a
      let st1 := if Gas.hasAccessLists f then st.warmAddr a else st
      let h := match st1.account? a with
        | some acc => if acc.isEmpty then 0 else Keccak.hashWord acc.code
        | none => 0
      pushResult fr st1 (Gas.accountAccessCost f .extcodehash cold) 1 rest h
    | _ => failWith st "stack underflow"
  else if op = 0x41 then pushConst fr st 2 ctx.coinbase
  else if op = 0x42 then pushConst fr st 2 ctx.timestamp
  else if op = 0x43 then pushConst fr st 2 ctx.number
  else if op = 0x44 then pushConst fr st 2 (if f.atLeast .merge then ctx.prevRandao else ctx.difficulty)
  else if op = 0x45 then pushConst fr st 2 ctx.gasLimit
  else if op = 0x46 then pushConst fr st 2 ctx.chainId
  else if op = 0x47 then pushConst fr st 5 (st.balance self)
  else if op = 0x48 then pushConst fr st 2 ctx.baseFee
  else if op = 0x49 then
    -- No blob hashes are attached to the transaction: every index is out of range.
    match fr.stack with
    | _ :: rest => pushResult fr st 3 1 rest 0
    | _ => failWith st "stack underflow"
  else if op = 0x4a then pushConst fr st 2 ctx.blobBaseFee
  else if op = 0x50 then
    match fr.stack with
    | _ :: rest =>
      if fr.gas < 2 then failWith st "out of gas"
      else .next { fr with gas := fr.gas - 2, stack := rest, sp := fr.sp - 1, pc := fr.pc + 1 } st
    | _ => failWith st "stack underflow"
  else if op = 0x51 then
    match fr.stack with
    | off :: rest =>
      let cost := 3 + rangeCost fr.memory off 32
      if fr.gas < cost then failWith st "out of gas"
      else
        let mem := memExtend fr.memory (off + 32)
        pushResult { fr with memory := mem } st cost 1 rest (Bytes.toNat (memRead mem off 32))
    | _ => failWith st "stack underflow"
  else if op = 0x52 ∨ op = 0x53 then
    match fr.stack with
    | off :: v :: rest =>
      let len := if op = 0x52 then 32 else 1
      let cost := 3 + rangeCost fr.memory off len
      if fr.gas < cost then failWith st "out of gas"
      else
        let data := if op = 0x52 then Bytes.ofNatBE v 32 else Bytes.ofNatBE (v % 256) 1
        let mem := memWrite (memExtend fr.memory (off + len)) off data
        .next { fr with gas := fr.gas - cost, memory := mem, stack := rest, sp := fr.sp - 2, pc := fr.pc + 1 } st
    | _ => failWith st "stack underflow"
  else if op = 0x54 then
    match fr.stack with
    | slot :: rest =>
      let cold := Gas.hasAccessLists f && !st.isWarmSlot self slot
      let st1 := if Gas.hasAccessLists f then st.warmSlot self slot else st
      pushResult fr st1 (Gas.sloadCost f cold) 1 rest (st1.sload self slot)
    | _ => failWith st "stack underflow"
  else if op = 0x55 then
    match fr.stack with
    | slot :: v :: rest =>
      if fr.isStatic then failWith st "write protection"
      else if Gas.sstoreHasSentry f && fr.gas ≤ Gas.sstoreSentryGas then failWith st "out of gas"
      else
        let cold := Gas.hasAccessLists f && !st.isWarmSlot self slot
        let st1 := if Gas.hasAccessLists f then st.warmSlot self slot else st
        let current := st1.sload self slot
        let original := (ctx.storage0.lookup (self, slot)).getD 0
        let (cost, refundDelta) := Gas.sstoreCost f original current v cold
        if fr.gas < cost then failWith st "out of gas"
        else
          let st2 := st1.sstore self slot v
          let st3 := if refundDelta = 0 then st2 else st2.setRefund (st2.refund + refundDelta)
          .next { fr with gas := fr.gas - cost, stack := rest, sp := fr.sp - 2, pc := fr.pc + 1 } st3
    | _ => failWith st "stack underflow"
  else if op = 0x56 then
    match fr.stack with
    | dest :: rest =>
      if fr.gas < 8 then failWith st "out of gas"
      else if !Bytecode.isValidJumpDest fr.dests dest then failWith st "invalid jump"
      else .next { fr with gas := fr.gas - 8, stack := rest, sp := fr.sp - 1, pc := dest } st
    | _ => failWith st "stack underflow"
  else if op = 0x57 then
    match fr.stack with
    | dest :: cond :: rest =>
      if fr.gas < 10 then failWith st "out of gas"
      else if cond = 0 then .next { fr with gas := fr.gas - 10, stack := rest, sp := fr.sp - 2, pc := fr.pc + 1 } st
      else if !Bytecode.isValidJumpDest fr.dests dest then failWith st "invalid jump"
      else .next { fr with gas := fr.gas - 10, stack := rest, sp := fr.sp - 2, pc := dest } st
    | _ => failWith st "stack underflow"
  else if op = 0x58 then pushConst fr st 2 fr.pc
  else if op = 0x59 then pushConst fr st 2 fr.memory.size
  else if op = 0x5a then pushConst fr st 2 (fr.gas - 2)
  else if op = 0x5b then
    if fr.gas < 1 then failWith st "out of gas" else .next { fr with gas := fr.gas - 1, pc := fr.pc + 1 } st
  else if op = 0x5c then
    match fr.stack with
    | slot :: rest => pushResult fr st 100 1 rest (st.tload self slot)
    | _ => failWith st "stack underflow"
  else if op = 0x5d then
    match fr.stack with
    | slot :: v :: rest =>
      if fr.isStatic then failWith st "write protection"
      else if fr.gas < 100 then failWith st "out of gas"
      else .next { fr with gas := fr.gas - 100, stack := rest, sp := fr.sp - 2, pc := fr.pc + 1 } (st.tstore self slot v)
    | _ => failWith st "stack underflow"
  else if op = 0x5e then
    match fr.stack with
    | dst :: src :: len :: rest =>
      let cost := 3 + Gas.copyGas len + rangeCost fr.memory (max dst src) len
      if fr.gas < cost then failWith st "out of gas"
      else
        let mem0 := memExtend fr.memory (rangeEnd (max dst src) len)
        let mem := memWrite mem0 dst (memRead mem0 src len)
        .next { fr with gas := fr.gas - cost, memory := mem, stack := rest, sp := fr.sp - 3, pc := fr.pc + 1 } st
    | _ => failWith st "stack underflow"
  else if op = 0x5f then pushConst fr st 2 0
  else if 0x60 ≤ op ∧ op ≤ 0x7f then
    if fr.gas < 3 then failWith st "out of gas"
    else if fr.sp ≥ stackLimit then failWith st "stack overflow"
    else
      .next { fr with gas := fr.gas - 3, stack := Bytecode.pushValue fr.code fr.pc :: fr.stack, sp := fr.sp + 1,
                      pc := fr.pc + 1 + Bytecode.pushSize op } st
  else if 0x80 ≤ op ∧ op ≤ 0x8f then
    match fr.stack[op - 0x80]? with
    | some v => pushConst fr st 3 v
    | none => failWith st "stack underflow"
  else if 0x90 ≤ op ∧ op ≤ 0x9f then
    let n := op - 0x90 + 1
    match fr.stack, fr.stack[n]? with
    | top :: rest, some deep =>
      if fr.gas < 3 then failWith st "out of gas"
      else .next { fr with gas := fr.gas - 3, stack := deep :: rest.set (n - 1) top, pc := fr.pc + 1 } st
    | _, _ => failWith st "stack underflow"
  else if 0xa0 ≤ op ∧ op ≤ 0xa4 then
    let n := op - 0xa0
    match fr.stack with
    | off :: len :: rest =>
      if rest.length < n then failWith st "stack underflow"
      else if fr.isStatic then failWith st "write protection"
      else
        let cost := Gas.logGas n len + rangeCost fr.memory off len
        if fr.gas < cost then failWith st "out of gas"
        else
          let mem := memExtend fr.memory (rangeEnd off len)
          let entry : Log := { address := self, topics := rest.take n, data := memRead mem off len }
          .next { fr with gas := fr.gas - cost, memory := mem, stack := rest.drop n, sp := fr.sp - (2 + n), pc := fr.pc + 1 }
            (st.addLog entry)
    | _ => failWith st "stack underflow"
  else if op = 0xf1 then stepCall ctx fr st .call
  else if op = 0xf2 then stepCall ctx fr st .callcode
  else if op = 0xf4 then stepCall ctx fr st .delegatecall
  else if op = 0xfa then stepCall ctx fr st .staticcall
  else if op = 0xf3 ∨ op = 0xfd then
    match fr.stack with
    | off :: len :: _ =>
      let cost := rangeCost fr.memory off len
      if fr.gas < cost then failWith st "out of gas"
      else
        let out := memRead (memExtend fr.memory (rangeEnd off len)) off len
        .halt { status := if op = 0xf3 then .success else .revert, gasLeft := fr.gas - cost, output := out } st
    | _ => failWith st "stack underflow"
  else if op = 0xff then stepSelfdestruct ctx fr st
  else unsupported st s!"opcode {op}"

/-- One small step of the machine. -/
def step (ctx : Ctx) (fr : Frame) (st : State) : Step :=
  if fr.pc ≥ fr.code.size then
    -- Running off the end of the code is STOP.
    .halt { status := .success, gasLeft := fr.gas, output := ByteArray.empty } st
  else
    let op := Bytes.getZ fr.code fr.pc
    let f := ctx.fork
    if !Bytecode.isDefined f op then failWith st "invalid opcode"
    else
      match Word256.unary? op, Word256.binary? op, Word256.ternary? op, fr.stack with
      | some g, _, _, a :: rest => pushResult fr st (Bytecode.staticGas f op) 1 rest (g a)
      | some _, _, _, _ => failWith st "stack underflow"
      | none, some g, _, a :: b :: rest =>
        let cost := if op = 0x0a then Gas.expGas f b else Bytecode.staticGas f op
        pushResult fr st cost 2 rest (g a b)
      | none, some _, _, _ => failWith st "stack underflow"
      | none, none, some g, a :: b :: c :: rest => pushResult fr st (Bytecode.staticGas f op) 3 rest (g a b c)
      | none, none, some _, _ => failWith st "stack underflow"
      | none, none, none, _ => stepOther ctx fr st op

/-- Run a frame to completion. Returns the outcome and the state; the caller rolls the
    state back when the outcome is not a success. -/
def run (ctx : Ctx) : Nat → Frame → State → Outcome × State
  | 0, _, st => ({ status := .outOfFuel, gasLeft := 0, output := ByteArray.empty, reason := "fuel exhausted" }, st)
  | fuel + 1, fr, st =>
    match step ctx fr st with
    | .next fr' st' => run ctx fuel fr' st'
    | .halt o st' => (o, st')
    | .call child cp parent outOff outLen st' =>
      let (o, st2) := run ctx fuel child st'
      if o.status == .unsupported || o.status == .outOfFuel then (o, st2)
      else
        let st3 := if o.status == .success then st2 else st2.rollback cp
        run ctx fuel (resume parent o outOff outLen) st3

/-! ### Transactions -/

structure TxResult where
  status : Status
  gasLeft : Nat
  output : Bytes
  reason : String
  logs : Array Log
  state : State

/-- Execute one transaction: a message call from `ctx.origin` to `to` (a top-level
    STATICCALL when `isStatic`), with intrinsic gas, EIP-2929 pre-warming, the capped
    refund (EIP-3529) and the calldata floor (EIP-7623). The gas price is `ctx.gasPrice`;
    fee payment is not modelled, so callers use a zero gas price. -/
def runTx (ctx : Ctx) (isStatic : Bool) (to gasLimit value : Nat) (calldata : Bytes) (pre : State) : TxResult :=
  let f := ctx.fork
  let invalid (why : String) : TxResult :=
    { status := .failure, gasLeft := 0, output := ByteArray.empty, reason := why, logs := #[], state := pre }
  let tokens := Gas.calldataTokens f calldata
  let intrinsic := Gas.intrinsicGas f calldata false
  let floor := Gas.calldataFloorGas f tokens
  if gasLimit = 0 ∨ gasLimit < intrinsic ∨ gasLimit < floor then invalid "intrinsic gas"
  else if f.atLeast .osaka ∧ gasLimit > 2 ^ 24 then invalid "gas limit above EIP-7825 cap"
  else if pre.balance ctx.origin < gasLimit * ctx.gasPrice + value then invalid "insufficient balance"
  else
    let originAcc := (pre.account? ctx.origin).getD {}
    let st0 := pre.setAccount ctx.origin (some { originAcc with nonce := originAcc.nonce + 1 })
    let st1 := (st0.warmAddr ctx.origin).warmAddr to
    let st2 := if f.atLeast .shanghai then st1.warmAddr ctx.coinbase else st1
    let execGas := gasLimit - intrinsic
    let cp := st2.checkpoint
    let st3 := if isStatic then st2 else transfer st2 ctx.origin to value
    let finish (o : Outcome) (stEnd : State) : TxResult :=
      let ok := o.status == .success
      let stR := if ok then stEnd else stEnd.rollback cp
      let refunded :=
        if ok then Gas.applyRefund f gasLimit o.gasLeft stR.refund.toNat else o.gasLeft
      let gasLeft := if gasLimit - refunded < floor then gasLimit - floor else refunded
      -- Before EIP-6780 a self-destructed account is deleted at the end of the transaction.
      let stD :=
        if ok && !f.atLeast .cancun then
          stR.destructed.foldl
            (fun s a => { (s.setAccount a none) with storage := s.storage.filter (fun e => e.1.1 != a) }) stR
        else stR
      { status := o.status, gasLeft := gasLeft, output := if o.status == .failure then ByteArray.empty else o.output,
        reason := o.reason, logs := stD.logs, state := stD }
    if Gas.isPrecompile f to || isSystemAddress to then
      { status := .unsupported, gasLeft := 0, output := ByteArray.empty,
        reason := "transaction to precompile or system contract", logs := #[], state := pre }
    else
      let code := st3.code to
      if code.size == 0 then finish { status := .success, gasLeft := execGas, output := ByteArray.empty } st3
      else
        let frame : Frame :=
          { code := code
            dests := Bytecode.jumpdests code
            gas := execGas
            address := to
            caller := ctx.origin
            value := if isStatic then 0 else value
            calldata := calldata
            isStatic := isStatic }
        let (o, stEnd) := run ctx (gasLimit + 1040) frame st3
        if o.status == .unsupported || o.status == .outOfFuel then
          { status := o.status, gasLeft := 0, output := ByteArray.empty, reason := o.reason, logs := #[], state := pre }
        else finish o stEnd

end Evm
end GuillotineSpec
