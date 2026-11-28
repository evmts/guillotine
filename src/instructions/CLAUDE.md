# CLAUDE.md - Instructions Module

## Mission critical: the execution engine

A wrong handler loses funds. After every change run `zig build && zig build test-opcodes`.

## Handler ABI

Every opcode handler has the register-passing tail-call signature defined in
`src/preprocessor/handler_abi.zig`:

```zig
fn (frame, cursor, sp, gas, t0, t1, t2, t3) callconv(handler_abi.handler_cc) handler_abi.ExitCode
```

| Argument | Meaning |
| --- | --- |
| `frame` | The executing `Frame` |
| `cursor` | Pointer into the dispatch schedule (not a bytecode PC) |
| `sp` | Live stack pointer; `sp[0]` is the top item's spill slot and is stale |
| `gas` | Live gas counter |
| `t0..t3` | Top stack item as 64-bit limbs, least significant first |

On LLVM x86_64 and aarch64 `handler_cc` is `preserve_none`. That convention cannot
return an error union or take a `u256` by value, so a handler returns an `ExitCode`
and the frame maps it back with `handler_abi.errorFromExit`. Other targets use the C
ABI with ordinary calls.

`frame.stack.stack_ptr`, the stack memory at `sp[0]` and `frame.gas_remaining` are
stale while handlers run. `N.flush` writes them back; `N.before`, `N.next`, `N.jump`
and `N.exit` flush when they must.

## Two ways to write a handler

### Native handler (hot opcodes)

```zig
const N = handler_abi.Native(FrameType);

pub fn add(self: *FrameType, cursor: [*]const Dispatch.Item, sp: [*]WordType, gas: FrameType.GasType, t0: u64, t1: u64, t2: u64, t3: u64) callconv(handler_abi.handler_cc) handler_abi.ExitCode {
    var s = N.StackView.init(sp, t0, t1, t2, t3);
    N.before(self, .ADD, cursor, s, gas);
    s.binary_op_unsafe(struct {
        fn op(top: WordType, second: WordType) WordType {
            return top +% second;
        }
    }.op);
    return N.next(self, .ADD, cursor, s, gas);
}
```

- `N.before` runs `frame.beforeInstruction` (tracer synchronization). It compiles to
  nothing in untraced ReleaseFast builds. Every handler must call it.
- `N.next` runs `frame.afterInstruction` and tail-calls the next handler.
- `N.jump` continues at a resolved jump target.
- `N.exit` flushes, runs `frame.afterComplete` and returns an `ExitCode`. Use it for
  every terminating path, error exits included.

### Step function (host-bound opcodes)

Handlers dominated by host work (storage, calls, logs, copies) are step functions
adapted by `handler_abi.wrap`:

```zig
pub fn calldatacopy(self: *FrameType, cursor: [*]const Dispatch.Item) Error![*]const Dispatch.Item {
    self.beforeInstruction(.CALLDATACOPY, cursor);
    // ... work on self.stack and self.gas_remaining ...
    // On an error exit: self.afterComplete(.CALLDATACOPY); return Error.OutOfGas;
    return dispatch_next.nextInstruction(FrameType, self, cursor, .CALLDATACOPY);
}
```

A step function works on `frame.stack` and `frame.gas_remaining` directly and returns
the cursor of the next handler. It must call `beforeInstruction` first,
`afterInstruction` (through `dispatch_next.nextInstruction`) on the continuing path,
and `afterComplete` on every exit path.

## Files

- Core: `handlers_arithmetic`, `handlers_bitwise`, `handlers_comparison`,
  `handlers_stack`, `handlers_memory`, `handlers_storage`, `handlers_jump`,
  `handlers_system`, `handlers_context`, `handlers_keccak`, `handlers_log`
- Fused (synthetic) opcodes: `handlers_arithmetic_synthetic`,
  `handlers_bitwise_synthetic`, `handlers_memory_synthetic`,
  `handlers_jump_synthetic`, `handlers_advanced_synthetic`
- Shared: `dispatch_next.zig` (step-function continuation), `address_utils.zig`

`src/frame/frame_handlers.zig` builds the 256-entry handler table. Undefined bytes,
opcodes a fork has not activated, and the withdrawn `0xF6`/`0xF7` map to the invalid
handler. `getSyntheticHandlerForByte` returns the invalid handler for a byte that is
not a synthetic opcode.

## Rules

- **Stack**: bytecode analysis validates each basic block's stack bounds before the
  block runs, so handlers use the `_unsafe` operations. Do not add bounds checks to
  them. Checks inside handlers are `tracer.assert(condition, "message")`, a
  development aid that is a no-op without a tracer.
- **Gas**: static gas is charged per basic block at block entry. A handler charges
  only its dynamic gas (memory expansion, cold access, copy cost) with checked
  arithmetic and exits with `OutOfGas` when the charge does not fit.
- **Memory**: expansion cost is quadratic and word-aligned; offsets and lengths are
  `u256` values that must be range-checked before any cast to `usize`.
- **Static context**: `SSTORE`, `TSTORE`, `LOG0..LOG4`, `CREATE`, `CREATE2`,
  `SELFDESTRUCT` and value-bearing `CALL` exit with `WriteProtection`.
- **Errors**: never crash and never swallow an error. Return a typed error or exit
  code. No `@panic`, `unreachable`, empty `catch`, or stub.
- **Logging**: `log.zig` only.

## Synthetic opcodes

Dispatch fuses common sequences (PUSH+op, PUSH+JUMP, ISZERO+JUMPI and others) into
one handler. Small operands are stored inline in the schedule; wider ones go to the
constant pool. A synthetic handler passes its synthetic opcode to `N.before`, and the
tracer steps the reference interpreter once per fused bytecode instruction.

`-Devm-enable-fusion=false` builds without fusion; both modes must pass
`zig build test-opcodes`, `zig build test-fusions` and `zig build state-tests`.
