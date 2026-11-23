# CLAUDE.md: @tevm/guillotine TypeScript SDK

## Architecture

`src/native/library.ts` loads `libguillotine_ffi` (built by `zig build shared` from `src/evm_c_api.zig`) with `bun:ffi` and calls `guillotine_init` once. `src/evm/evm.ts` wraps the handle API in `GuillotineEvm`. The ABI contract is `sdks/c/include/guillotine.h`; ownership, threading, and handle rules are in `docs/building-custom-sdks.md`. Read that before changing the binding.

Rules the binding depends on:

- Struct offsets in `evm.ts` are the LP64 layouts checked by `sdks/c/tests/simple_test.c`. Change both together.
- Copy every native buffer (`copyNative`) before `guillotine_free_result` / `guillotine_free_code`. Never keep a view of native memory.
- Zero-length inputs pass a 1-byte sentinel; Zig pointer parameters are non-optional.
- Tracing handles accept only `_tracing` setters, `call_tracing`, and `destroy_tracing`. Never pass them to mainnet functions; throw `UnsupportedOperation`.
- Validate u64 fields and `chainId` <= 65535 before native calls.
- Read `guillotine_get_last_error()` only right after a reported failure.
- Release handles explicitly (`dispose`, `close`, `using`); no finalizers.

## Commands

```bash
zig build shared            # from the repository root
bun install
bun run build && bun run typecheck && bun test && bun run lint:package
```

`test/setup.ts` (bunfig preload) points `GUILLOTINE_LIB_PATH` at `../../zig-out/lib` when unset.

## Tests

Tests run real bytecode against the native library. Assert Ethereum semantics (Yellow Paper, EIPs), not current behavior. A test that fails because of an EVM bug stays red; never `it.todo`, `it.skip`, or weaken it. Derive bytecode opcode by opcode and check stack order (first pop = top).
