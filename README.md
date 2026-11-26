<p align="center">
  <img height="220" alt="Guillotine" src="https://github.com/user-attachments/assets/1effa677-d931-4453-8e98-2a70372efd91" />
</p>

# Guillotine

An Ethereum Virtual Machine written in Zig, built around a register-passing tailcall dispatch engine.

**Status**: `v0.1.0`. Passes 100% of official Ethereum Execution Spec Tests (`66,652 / 66,652`, Frontier through Osaka, fusions on and off), `116,384 / 116,384` Zig↔Lean 4 differential fuzz vectors, and `32 / 32` SMT proofs. Ready for embedding, benchmarking, and experimentation; not yet independently security-audited for mainnet custody.

## How does it work?

Instead of a bytecode `while` + `switch` loop, Guillotine analyzes contract bytecode once into a flat schedule of 8-byte untagged dispatch items (`Dispatch.Item`). Basic blocks batch static gas and stack bounds checks up front, jump targets resolve through an O(1) dense bitmap table, and common opcode sequences (`PUSH+ADD`, `ISZERO+PUSH+JUMPI`, `DUP+MSTORE`, inline multi-limb `PUSH9`–`PUSH32`) fuse into single handlers.

Each opcode handler is a `preserve_none` tailcall (`@call(.always_tail, ...)`, native in stock Zig `0.17.1`) that keeps the hot interpreter state — frame pointer, schedule cursor, stack pointer, and remaining gas — live in callee registers with zero prologue/epilogue spills. Execution state uses O(1) undo-log database snapshots and pooled per-depth stack and memory buffers so nested calls avoid allocation churn.

### Features

- **Full mainnet hardfork coverage**: Frontier through Prague/Pectra and Osaka/Fusaka (EIP-7702, EIP-7623, EIP-4844, EIP-2537 BLS12-381, EIP-2935, EIP-7951 P256VERIFY, EIP-7610, Osaka CLZ & ModExp).
- **Base & OP Stack L2 execution**: Bedrock through Jovian (`src/layer2/`) running on fork-configured Guillotine `Evm` instances, including EIP-2930 access lists, EIP-7702 authorization lists on Isthmus/Jovian, L1 data fees, operator fees, and deposit transactions.
- **Fast native precompiles**: Pure-Zig secp256k1 `ECRECOVER` (`0.171 ms`), adaptive Montgomery `MODEXP`, BN254 GLV/multi-Miller loop, BLS12-381 via `blst`, KZG 4844 via `c-kzg-4844`, and SIMD calldata token counting.
- **Formal verification**: Executable Lean `4.32.0` reference spec (`verify/lean/`), 116,384-vector Zig↔Lean differential fuzzer, and 32 fail-closed SMT theorems (`verify/smt/`).
- **Three supported surfaces**: Native Zig package (`dep.module("evm")`), C ABI (`libguillotine_ffi` + `sdks/c/include/guillotine.h`), and TypeScript Bun FFI SDK (`@tevm/guillotine`).
- **(Experimental) ARM64 direct JIT**: Opt-in zero-dependency ARM64 compiler (`src/jit/`, gated by `EvmConfig.enable_native_jit`).

## Benchmarks

### Cross-EVM apples-to-apples suite (`bench/compare/`)

Reproducible, **in-process** comparison (zero CLI spawn overhead, 0-tolerance gas + byte-for-byte output differential gate across all 25 workloads and 12 engine configs; 21 fixtures verbatim from `alloy-rs/evm2` + 4 hot loops) on Apple M3 Max (macOS arm64, Zig `0.17.1` `preserve_none` + fusions, Rust `1.100.0`, Apple Clang `17.0.0`, Go `1.26.0`):

| Warm Interpreter | Lang | Overall vs `revm` | Classic (7) vs `revm` | `snailtracer` | `burntpix` | `uniswap_v3_pool` | `fibonacci` |
| :--- | :--- | ---: | ---: | ---: | ---: | ---: | ---: |
| **evm2** | Rust | **1.12×** | 1.10× | 64.75 ms | 53.65 ms | 16.71 µs | 51.04 µs |
| **Guillotine** | Zig | **1.00×** | **1.43×** | **55.53 ms** | **35.42 ms** | **11.40 µs** | **17.71 µs** |
| **revm** | Rust | 1.00× | 1.00× | 81.67 ms | 65.83 ms | 19.38 µs | 58.71 µs |
| **gevm** | Go | 0.99× | 0.98× | 92.29 ms | 77.51 ms | 22.83 µs | 60.38 µs |
| **ethrex (LEVM)** | Rust | 0.77× | 0.84× | 80.80 ms | 68.33 ms | 21.73 µs | 58.58 µs |
| **evmone (Baseline)** | C++ | 0.76× | 0.94× | 70.53 ms | 63.54 ms | 33.46 µs | 55.67 µs |
| **evmone (Advanced)** | C++ | 0.51× | 0.82× | 100.13 ms | 78.59 ms | 92.42 µs | 54.50 µs |
| **geth** | Go | 0.31× | 0.41× | 137.01 ms | 121.02 ms | 69.63 µs | 89.88 µs |

Full warm, cold first-run, Tier 2 JIT (`evm2-jit` LLVM 23, `revmc` LLVM 22), and differential audit tables: [bench/compare/RESULTS.md](bench/compare/RESULTS.md) · [bench/compare/report.html](bench/compare/report.html) · [bench/compare/README.md](bench/compare/README.md).

### In-repo ReleaseFast runner (`zig build bench`)

Measured with `zig build bench -- --iterations 5 --warmup 1` in `ReleaseFast` on x86_64 Linux (Zig `0.17.1`, `preserve_none` tailcall + fusions):

| Workload | Fork | Median | Throughput | Notes |
| --- | --- | ---: | ---: | --- |
| `contract/snailtracer` | Prague | `37.86 ms` | `6.21 GGas/s` | `1.25x` faster than `revm` (`47.21 ms`) on same host |
| `contract/Factorial` | Osaka | `2.27 µs` | `9.28 GGas/s` | Tight arithmetic loop |
| `contract/Fibonacci` | Osaka | `2.58 µs` | `8.23 GGas/s` | Stack + control flow |
| `contract/Uniswap-like-swap` | Osaka | `4.11 µs` | `5.60 GGas/s` | Storage + arithmetic mix |
| `contract/BubbleSort` | Osaka | `4.69 µs` | `5.60 GGas/s` | Memory-heavy loop |
| `precompile/SHA256-1KiB` | Osaka | `2.62 µs` | `23.66 GGas/s` | Native SHA-256 |
| `precompile/MODEXP-256` | Osaka | `2.82 µs` | `8.83 GGas/s` | Adaptive Montgomery |
| `precompile/BN254-mul` | Osaka | `8.16 µs` | `3.35 GGas/s` | GLV scalar multiplication |
| `precompile/ECRECOVER` | Osaka | `0.171 ms` | `146.99 MGas/s` | Pure-Zig secp256k1 Jacobian + Shamir |

### 100-Block Mainnet Replay (`26,498,000`–`26,498,099`)

Single-threaded offline replay of 100 contiguous recent Ethereum mainnet blocks (Osaka / BPO2, `29,560` transactions, `2.973B` gas, `5,026` unique contracts, pinned in [`bench/blocks/manifest.json`](bench/blocks/manifest.json)) on x86_64 Linux (`ReleaseFast`, node-sized 8,192-entry `DispatchCache`), including EIP-4788/EIP-2935 system calls, EIP-2930/4844/7702 transactions, and EIP-4895 withdrawals:

| Mode | Total (100 blocks) | Per block | Throughput | Tx rate | Receipt parity |
| --- | ---: | ---: | ---: | ---: | ---: |
| Cold bytecode cache | `5.35 s` | `53.54 ms` | `555.3 MGas/s` | `5,521 tx/s` | `99.92%` exact gas+status (`99.98%` status) |
| Warm bytecode cache (median, 5 runs) | `3.81 s` | `38.10 ms` | `780.2 MGas/s` | `7,758 tx/s` | `99.92%` exact gas+status (`99.98%` status) |

Reproduce locally:

```console
$ zig build bench                                # in-repo ReleaseFast suite
$ ./bench/compare/build-all.sh && node bench/compare/run.mjs  # cross-EVM suite
$ ETHEREUM_RPC_URL=https://... node bench/blocks/fetch.mjs --start 26498000 --count 100
$ zig build bench-blocks -- --iterations 5 --warmup 1         # 100-block mainnet replay
```

## Verification & Testing

| Layer | Result | Command |
| --- | --- | --- |
| Official EEST state tests (`tests@v21.0.3`, fusions ON) | `66,652 / 66,652` (`100.00%`) | `zig build state-tests -Doptimize=ReleaseSafe` |
| Official EEST state tests (`tests@v21.0.3`, fusions OFF) | `66,652 / 66,652` (`100.00%`) | `zig build state-tests -Doptimize=ReleaseSafe -Devm-enable-fusion=false` |
| Zig↔Lean `4.32.0` differential fuzzer | `116,384 / 116,384` (`0` mismatches) | `FUZZ_ITERS=2000 zig build test-lean-diff -Doptimize=ReleaseSafe` |
| SMT bitvector proofs (Bitwuzla + Z3) | `32 / 32` theorems proved (`unsat`) | `zig build verify-smt` |
| LLVM IR equivalence & poison/UB + Lean 4 proofs | All exported pairs & 5 proof modules | `zig build verify` (`verify-ir`, `verify-smt`, `verify-lean`) |
| Core Zig suites (unit, opcodes, fusions, precompiles, L2, fuzz, JIT) | 100% passing (L2 `154 / 154`) | `zig build test` |
| Multi-threaded havoc fuzz campaign | 0 open crashes (`.fuzz-crashes/`) | `zig build fuzz-campaign -Doptimize=ReleaseSafe -- --seconds=60 --threads=8` |
| C SDK & Rust workspace E2E | 100% passing | `make -f sdks/c/Makefile -o build-core test && cargo test --locked` |
| TypeScript SDK (`@tevm/guillotine`) E2E & fuzzer | `340 / 340` (`30,290` assertions) | `cd sdks/typescript && bun test && bun run test:fuzz` |

16,907 Amsterdam EEST cases are skipped because Amsterdam is not yet finalized/implemented. Fetch the pinned fixtures first with `./scripts/fetch-eest-fixtures.sh`. Full methodology and CI coverage are documented in [Testing and verification](docs/src/pages/guides/testing-and-verification.mdx) and [Benchmarks and native JIT](docs/src/pages/guides/benchmarks-and-jit.mdx).

## Usage

### Zig

Add Guillotine to your `build.zig.zon`:

```console
$ zig fetch --save=guillotine https://github.com/evmts/guillotine/archive/refs/tags/v0.1.0.tar.gz
```

Wire the `evm` module in your `build.zig`:

```zig
const guillotine = b.dependency("guillotine", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("evm", guillotine.module("evm"));
exe.root_module.addImport("voltaire", guillotine.module("voltaire"));
```

Execute bytecode:

```zig
const std = @import("std");
const evm = @import("evm");
const voltaire = @import("voltaire");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var db = evm.Database.init(allocator);
    defer db.deinit();

    var vm = try evm.MainnetEvm.init(
        allocator,
        &db,
        .{
            .chain_id = 1,
            .number = 1,
            .timestamp = 1700000000,
            .difficulty = 0,
            .gas_limit = 30_000_000,
            .coinbase = voltaire.ZERO_ADDRESS,
            .base_fee = 0,
            .prev_randao = @splat(0),
        },
        .{ .gas_limit = 1_000_000, .coinbase = voltaire.ZERO_ADDRESS, .chain_id = 1 },
        0,
        voltaire.ZERO_ADDRESS,
    );
    defer vm.deinit();

    const target = voltaire.Address.fromU256(0xc0);
    // PUSH1 2, PUSH1 3, ADD, PUSH1 0, MSTORE, PUSH1 32, PUSH1 0, RETURN
    const code = [_]u8{ 0x60, 0x02, 0x60, 0x03, 0x01, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3 };
    const code_hash = try db.set_code(&code);
    var acct = evm.Account.zero();
    acct.code_hash = code_hash;
    try db.set_account(target.bytes, acct);

    var res = vm.call(.{ .call = .{
        .caller = voltaire.Address.fromU256(0xa1),
        .to = target,
        .value = 0,
        .input = &.{},
        .gas = 100_000,
    } });
    defer res.deinit(allocator);
}
```

### TypeScript (Bun FFI)

```ts
import { Address, Bytes, GuillotineEvm, U256 } from '@tevm/guillotine'

using evm = await GuillotineEvm.create()

const alice = Address.fromHex('0x00000000000000000000000000000000000000a1')
const contract = Address.fromHex('0x00000000000000000000000000000000000000c0')

// PUSH1 2, PUSH1 3, ADD, PUSH1 0, MSTORE, PUSH1 32, PUSH1 0, RETURN
await evm.setCode(contract, Bytes.fromHex('0x600260030160005260206000f3'))

const result = await evm.call({
  caller: alice,
  to: contract,
  value: U256.zero(),
  input: Bytes.empty(),
  gas: 100_000n,
})

console.log(result.success, U256.fromBytes(result.output.toBytes()).toBigInt()) // true 5n
```

### C FFI

Build the shared library with `zig build shared -Doptimize=ReleaseFast -Dstrip=true` (or grab a prebuilt binary from [Releases](https://github.com/evmts/guillotine/releases)), include [`sdks/c/include/guillotine.h`](sdks/c/include/guillotine.h), and link `-lguillotine_ffi`:

```c
#include <string.h>
#include "guillotine.h"

int main(void) {
    guillotine_init();

    BlockInfoFFI block = {
        .number = 1, .timestamp = 1700000000,
        .gas_limit = 30000000, .chain_id = 1, .base_fee = 1,
    };
    EvmHandle *evm = guillotine_evm_create(&block);

    uint8_t addr[20] = {0};
    addr[19] = 0xc0;
    uint8_t code[] = {0x60, 0x02, 0x60, 0x03, 0x01, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3};
    guillotine_set_code(evm, addr, code, sizeof(code));

    CallParams params = {0};
    memcpy(params.to, addr, 20);
    params.gas = 100000;
    params.call_type = GUILLOTINE_CALL;

    EvmResult *res = guillotine_call(evm, &params);
    guillotine_free_result(res);
    guillotine_evm_destroy(evm);
    guillotine_cleanup();
    return 0;
}
```

### Other languages

Rather than maintaining stale wrapper packages for every language, Guillotine ships a stable C ABI plus a guide and agent skill for generating native bindings (Python, Go, Rust, Swift, Kotlin):

- Guide: [docs/building-custom-sdks.md](docs/building-custom-sdks.md)
- Agent skill: [.agents/skills/guillotine-sdk-builder/SKILL.md](.agents/skills/guillotine-sdk-builder/SKILL.md)

## Compiling / Developing

Prerequisites:

- **Zig `0.17.1`** (stock toolchain; `preserve_none` tailcalls are built in, no compiler fork needed)
- **Rust stable** (builds the BN254/BLS12-381 static crypto wrappers automatically via `build.zig`)
- **Bun** (optional, for `sdks/typescript`)
- **Lean `4.32.0`** and **Bitwuzla / Z3** (optional, for `verify/lean` and `verify/smt`)

Common commands (run from repository root):

```console
$ zig build                       # build libraries and tools
$ zig build test                  # unit, opcode, integration, L2, precompile, fusion, modexp, fuzz
$ zig build shared -Doptimize=ReleaseFast -Dstrip=true
$ zig build state-tests -Doptimize=ReleaseFast
$ zig build bench
$ zig build fuzz-campaign -Doptimize=ReleaseSafe -- --seconds=30
```

Incremental subsystem builds and benchmarks are also wired as Smithers targets (`PACKAGE.ts`, `smthrs test //bench:report`).

## Documentation

- Site: [guillotine.tevm.sh](https://guillotine.tevm.sh)
- Architecture & internals: [docs/dev/ARCHITECTURE.md](docs/dev/ARCHITECTURE.md)
- Changelog: [CHANGELOG.md](CHANGELOG.md)
- Contributor rules & engineering standards: [AGENTS.md](AGENTS.md)

## License

[MIT](LICENSE)
