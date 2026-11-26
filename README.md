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

Reproduce locally:

```console
$ zig build bench
```

## Verification

| Suite | Result | Command |
| --- | --- | --- |
| Official EEST state tests (`tests@v21.0.3`, fusions ON) | `66,652 / 66,652` (`100.00%`) | `zig build state-tests -Doptimize=ReleaseFast` |
| Official EEST state tests (`tests@v21.0.3`, fusions OFF) | `66,652 / 66,652` (`100.00%`) | `zig build state-tests -Doptimize=ReleaseFast -Devm-enable-fusion=false` |
| Zig↔Lean `4.32.0` differential fuzzer | `116,384 / 116,384` (`0` mismatches) | `FUZZ_ITERS=2000 zig build test-lean-diff -Doptimize=ReleaseSafe` |
| SMT bitvector proofs (Bitwuzla + Z3) | `32 / 32` theorems proved (`unsat`) | `python3 verify/smt/run_smt_suite.py` |
| Base / OP Stack Layer 2 suite | `154 / 154` passing | `zig build test-layer2` |
| TypeScript SDK (`@tevm/guillotine`) | `340 / 340` (`30,290` assertions) | `cd sdks/typescript && bun test` |

16,907 Amsterdam EEST cases are skipped because Amsterdam is not yet finalized/implemented. Fetch the pinned fixtures first with `./scripts/fetch-eest-fixtures.sh`.

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
