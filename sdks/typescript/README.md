# @tevm/guillotine

TypeScript bindings for the [Guillotine](https://github.com/evmts/guillotine) EVM. The package calls the native `libguillotine_ffi` library through [Bun FFI](https://bun.sh/docs/api/ffi); the ABI is `sdks/c/include/guillotine.h`.

| Runtime | Status |
| --- | --- |
| Bun ≥ 1.1 | Supported |
| Node.js, browsers | Not supported. The WASM backend was removed because it ran a stale binary with a different ABI. |

## Install

```bash
bun add @tevm/guillotine
```

The package loads the native library from, in order:

1. `GuillotineEvm.create(block, { libraryPath })`
2. the `GUILLOTINE_LIB_PATH` environment variable
3. `prebuilds/<platform>-<arch>/libguillotine_ffi.<dylib|so|dll>` inside the package

## Use

```ts
import { Address, Bytes, GuillotineEvm, U256 } from '@tevm/guillotine';

using evm = await GuillotineEvm.create({ chainId: 1n });

const caller = Address.fromHex('0x00000000000000000000000000000000000000a1');
const contract = Address.fromHex('0x00000000000000000000000000000000000000c0');

// PUSH1 2 PUSH1 3 ADD PUSH1 0 MSTORE PUSH1 32 PUSH1 0 RETURN
await evm.setCode(contract, Bytes.fromHex('0x600260030160005260206000f3'));

const gas = 1_000_000n;
const result = await evm.call({ caller, to: contract, value: U256.zero(), input: Bytes.empty(), gas });

result.success; // true
U256.fromBytes(result.output.toBytes()).toBigInt(); // 5n
result.getGasUsed(gas); // includes the 21000 intrinsic gas
```

`using` releases the native handle at scope exit. Without it, call `evm.dispose()` (or `close()`); both are idempotent. Handles are not released by garbage collection.

## API

| Method | Mainnet EVM | Tracing EVM |
| --- | --- | --- |
| `call(params)` | ✓ | ✓, returns `traceJson` |
| `simulate(params)` (CALL only, no state commit) | ✓ | throws `UnsupportedOperation` |
| `setBalance`, `setNonce`, `setCode` | ✓ | ✓ |
| `setStorage`, `getStorage`, `getBalance`, `getCode` | ✓ | throws `UnsupportedOperation` |

Create a tracing EVM with `GuillotineEvm.create(block, { tracing: true })`. The native library has no state readers for tracing handles, so the SDK refuses those calls instead of passing an incompatible handle.

`ExecutionResult` holds `success`, `gasLeft`, `output` (return or revert data), `logs`, `selfdestructs`, `accessedAddresses`, `accessedStorage`, `createdAddress`, and `traceJson`. A reverted call returns `success: false` with its revert data; it does not throw. `errorMessage` is `null` unless the native library reports a reason.

Errors are `GuillotineError` instances with a `type`:

| `type` | Cause |
| --- | --- |
| `InvalidValue` | Input outside its native range: u64 fields, `chainId` > 65535, `prevRandao` not 32 bytes, unknown call type |
| `UnsupportedOperation` | Operation not available on this handle type |
| `VMNotInitialized` | Handle already disposed |
| `VMCreationFailed`, `ExecutionFailed`, `StateError` | Native failure; the message includes `guillotine_get_last_error()` |
| `InitializationFailed` | Native library missing or not loadable |

## Develop

From the repository root, build the native library, then work in `sdks/typescript`:

```bash
zig build shared
cd sdks/typescript
bun install
bun run build       # dist/ via tsup
bun run typecheck
bun test            # loads ../../zig-out/lib unless GUILLOTINE_LIB_PATH is set
bun run lint:package  # publint + are-the-types-wrong on the packed tarball
```

`bun run build:native` builds a ReleaseFast library and copies it into `prebuilds/<platform>-<arch>/`. `prepublishOnly` runs it, so a publish ships only the host platform's prebuild. Publishing for more platforms requires building each one into `prebuilds/` before `npm publish`.

## License

MIT
