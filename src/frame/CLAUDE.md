# CLAUDE.md - Frame Module

## Mission critical: execution context integrity

A frame bug is a consensus failure. After every change run
`zig build && zig build test-opcodes`.

## What a Frame is

`Frame(config, EvmType)` in `frame.zig` is the execution context of one call. It
executes a preprocessed **dispatch schedule**, not bytecode, and it has no program
counter: `cursor` points into the schedule.

| Field | Use |
| --- | --- |
| `stack` | Downward-growing word stack; `stack_ptr` is stale while handlers run |
| `gas_remaining` | Signed gas counter; stale while handlers run |
| `memory` | Call memory, lazily expanded in words |
| `evm_ptr`, `database` | The owning EVM (`getEvm()`) and its database |
| `contract_address`, `caller`, `value`, `calldata_slice` | Call context |
| `code` | Raw bytecode, for `CODESIZE`/`CODECOPY` only |
| `jump_table` | Sorted JUMPDEST table for dynamic `JUMP`/`JUMPI` |
| `dispatch` | Cursor into the schedule |
| `output_data` | `RETURN`/`REVERT` payload |

The frame does not own call depth, static-call state, access lists, the journal or
return data. Those live on the EVM (`src/evm.zig`).

## Files

- `frame.zig` - `Frame`, `interpret`, gas and tracer hooks, `pretty_print`
- `frame_handlers.zig` - the 256-entry opcode handler table and synthetic handlers
- `frame_config.zig` - stack size, word type, gas type, limits
- `fork_gas.zig` - per-fork opcode availability and static gas
- `call_params.zig`, `call_result.zig` - call inputs and results
- `block_info_config.zig` - block field types

## Lifecycle

The EVM creates one frame per call in `Evm.inner_call` and the create paths:

```zig
var frame = try Frame.init(frame_allocator, gas, caller, value, input, @ptrCast(evm));
defer frame.deinit(frame_allocator);
try frame.interpret(&schedule, &jump_table, code);
```

`interpret`:

1. Notifies the tracer (`onInterpret`), which starts the reference interpreter in
   validating builds.
2. Charges the first basic block's gas and validates its stack bounds, when the
   schedule starts with `first_block_gas` metadata. Schedule index 0 is therefore
   not always the handler of PC 0.
3. Enters the handler chain with `handler_abi.enter`. Handlers tail-call each other
   until one returns an `ExitCode`.
4. Maps the exit code back to `Frame.Error` with `handler_abi.errorFromExit`.

Every exit is an error value, successes included: `Stop`, `Return` and
`SelfDestruct` end a frame successfully, `REVERT` reverts it, anything else is an
exceptional halt that consumes all gas. `evm.zig` turns the value into a
`CallResult`.

## Handler ABI

```zig
pub const OpcodeHandler = *const fn (frame: *Self, cursor: [*]const Dispatch.Item, sp: [*]WordType,
    gas: GasType, t0: u64, t1: u64, t2: u64, t3: u64) callconv(handler_abi.handler_cc) handler_abi.ExitCode;
```

`handler_cc` is `preserve_none` on LLVM x86_64 and aarch64. `sp` and `gas` are the
live stack pointer and gas counter and `t0..t3` are the top stack item as 64-bit
limbs. See `src/preprocessor/handler_abi.zig` and `src/instructions/CLAUDE.md`.

## Tracer hooks

Handlers call three frame hooks, which compile to nothing when hooks are disabled
(`handler_abi.hooksEnabled`):

- `beforeInstruction(opcode, cursor)` - steps the reference interpreter
- `afterInstruction(opcode, next_handler, next_cursor)` - compares state
- `afterComplete(opcode)` - on every terminating path, error exits included

A handler that skips a hook desynchronizes the tracer.

## Gas

- Static gas is charged per basic block: at frame entry for the first block and at
  each `JUMPDEST` for the following ones.
- Dynamic gas is charged by the handler with checked arithmetic
  (`consumeGasChecked`); a charge that does not fit is `OutOfGas`.
- Call gas forwarding follows EIP-150: at most `available - available / 64`.

## Rules

- Never crash. Validate and return a typed `Frame.Error`.
- Assertions are `tracer.assert(condition, "message")`; logging goes through
  `log.zig`.
- `pretty_print` returns every failure to the caller (`error.OutOfMemory`,
  `error.WriteFailed`, `error.OutOfBounds`); it never substitutes empty output.
- Do not add an analysis-configured `Bytecode` alias to `Frame`. The EVM owns the
  bytecode configuration, including whether fusion is enabled.
- Keep hot fields in the first cache lines; do not add per-instruction work to
  untraced builds.
