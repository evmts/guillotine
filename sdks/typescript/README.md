# @tevm/guillotine

TypeScript bindings for the [Guillotine](https://github.com/evmts/guillotine) EVM. The package runs natively in **Node.js ≥ 20** (via the zero-`node-gyp` Node-API addon `guillotine.node`) and **Bun ≥ 1.1** (via either `guillotine.node` or [Bun FFI](https://bun.sh/docs/api/ffi) over `libguillotine_ffi`); the C ABI is [`sdks/c/include/guillotine.h`](../c/include/guillotine.h).

| Runtime | Status | Transport |
| --- | --- | --- |
| Node.js ≥ 20 | Supported | Zero-`node-gyp` Node-API (`guillotine.node`) |
| Bun ≥ 1.1 | Supported | Node-API (`guillotine.node`) or Bun FFI (`libguillotine_ffi`) |
| Browsers | Not supported | Use `evmts/guillotine-mini` for WASM browser execution |

## Install

```bash
npm install @tevm/guillotine
# or
bun add @tevm/guillotine
```

The package resolves the native binary in order:

1. `GuillotineEvm.create(block, { libraryPath })`
2. `GUILLOTINE_NAPI_PATH` (for `guillotine.node`)
3. `GUILLOTINE_LIB_PATH` (for `libguillotine_ffi.<dylib|so|dll>` on Bun)
4. `prebuilds/<platform>-<arch>/guillotine.node` (or `libguillotine_ffi.<dylib|so|dll>`)

## Use

```ts
import { Address, Bytes, GuillotineEvm, U256 } from '@tevm/guillotine'

using evm = await GuillotineEvm.create({ number: 1n, baseFee: 10n, chainId: 1n })

const caller = Address.fromHex('0x00000000000000000000000000000000000000a1')
const contract = Address.fromHex('0x00000000000000000000000000000000000010c0')

// PUSH1 2 PUSH1 3 ADD PUSH1 0 MSTORE PUSH1 32 PUSH1 0 RETURN
await evm.setCode(contract, Bytes.fromHex('0x600260030160005260206000f3'))

const gas = 1_000_000n
const result = await evm.call({ caller, to: contract, value: U256.zero(), input: Bytes.empty(), gas })

result.success // true
U256.fromBytes(result.output.toBytes()).toBigInt() // 5n
result.getGasUsed(gas) // includes the 21000 intrinsic gas

// Update block context in place without losing the warm dispatch cache
await evm.setBlockInfo({ number: 2n, baseFee: 10n, chainId: 1n })

// Execute a full EIP-1559 transaction (intrinsic gas, nonce, EIP-7623 floor, EIP-7825 cap)
await evm.setBalance(caller, U256.fromBigInt(1_000_000_000n))
const tx = await evm.executeTx({
	from: caller,
	to: contract,
	gasLimit: 100_000n,
	maxFeePerGas: U256.fromBigInt(20n),
	maxPriorityFeePerGas: U256.fromBigInt(5n),
})
```

`using` releases the native handle at scope exit. Without it, call `evm.dispose()` (or `close()`); both are idempotent, and a `FinalizationRegistry` acts as a GC safety net.

## API

Every state, simulation, and transaction method works across mainnet, `tracing` (`structLogs`), `callTracer` (structured Geth call trees), and `hardfork` (`'shanghai' | 'cancun' | 'prague' | 'osaka'`) handles:

| Method / Option | Behavior |
| --- | --- |
| `GuillotineEvm.create(block, { tracing: true })` | Full per-opcode `structLogs` trace JSON |
| `GuillotineEvm.create(block, { callTracer: true })` | Compact nested call-tree JSON without per-opcode overhead |
| `GuillotineEvm.create(block, { hardfork: 'cancun' })` | Select Shanghai, Cancun, Prague, or Osaka semantics |
| `call(params)` | Execute message call or CREATE/CREATE2 and commit state |
| `simulate(params)` | Execute CALL without committing state |
| `executeTx(params)` | Full Ethereum transaction lifecycle (fees, nonce, refunds, floor, caps) |
| `setBlockInfo(block)` | Update block context in place without recreating the EVM |
| `setBalance`, `getBalance`, `setNonce`, `getNonce` | Account balance and nonce access |
| `setCode`, `getCode`, `setStorage`, `getStorage` | Bytecode and storage slot access |

## Develop

From the repository root, build both native libraries, then test in both Bun and Node.js:

```bash
zig build shared napi -Doptimize=ReleaseFast -Dstrip=true
cd sdks/typescript
bun install
bun run build          # dist/ via tsup
bun run typecheck
bun test               # Bun FFI test suite (341 tests)
npm run test:node      # Node.js native Node-API E2E test suite
bun run lint:package   # publint --strict + attw
```

`bun run build:native` builds both `libguillotine_ffi` and `guillotine.node` in ReleaseFast and copies them into `prebuilds/<platform>-<arch>/`.

## License

MIT
