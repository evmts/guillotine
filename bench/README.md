# Guillotine benchmarks

Native, self-contained benchmark runner for the public `src/root.zig` EVM.
No `evmts/evm-benchmarks` checkout, runtime compiler, zbench, or RPC is needed.
Run all commands from the repository root with Zig 0.15.1:

```sh
zig build --build-file bench/build.zig test-bench
zig build --build-file bench/build.zig bench -- --filter opcode/ADD --iterations 1000 --warmup 100
zig build --build-file bench/build.zig bench -- --json bench/results/latest.json
zig build --build-file bench/build.zig bench -- --compare --filter opcode
```

`bench-build` installs `bench/zig-out/bin/guillotine-bench`. The standalone
build defaults to ReleaseFast, including the EVM and its Zig dependencies.
The runner refuses timing runs in other optimization modes. `--help` is
available in any mode. Runtime errors go to stderr; stdout is a Markdown table. Routine core warnings
are disabled during timing (`std_options.log_level = .err`).

`--filter` is a case-insensitive substring. Iterations must be 1–1,000,000;
warmup may be 0–1,000,000. Unknown flags, missing values, invalid counts, and
filters matching nothing produce a nonzero exit code.

The baseline checkout recognizes precompiles through Prague but not Osaka.
Use `-Dbench-hardfork=PRAGUE` to explicitly benchmark supported precompiles;
the chosen fork is recorded in JSON. `-Dbench-gas-limit=<N>` overrides the
execution budget; Osaka+ budgets above 16,777,216 are rejected. Historical
fixture runs use a large off-chain execution budget, not a block replay. There is no automatic fork substitution.
CLZ/P256 require Osaka and remain unavailable on Prague.

## Root build integration

After the other lane's build changes merge, these three lines inside `build`
register `bench`, `bench-build`, and `test-bench`:

```zig
const benches = @import("bench/bench_step.zig");
const bench_steps = benches.addBenchSteps(b, .{ .target = target, .evm = modules.evm_mod });
_ = bench_steps;
```

The helper copies the EVM import graph into ReleaseFast modules without changing
modules shared with tests or bindings. It retains existing native library link
objects. It also owns the native crypto archive producer and replaces Voltaire's
unproduced archive in its private graph, so these three lines work independently
of the root build's missing-archive issue. A caller may pass `.native_archive`
to reuse an already-produced, target-specific archive.

For a verified loop-dispatch build, also pass `.loop_evm = loop_modules.evm_mod`,
where that module's `build_options.disable_tailcall_dispatch` is `true` and its
implementation honors the option. `--compare` then runs three configurations:
tailcall+fusions, tailcall-no-fusions, and loop without fusions. Otherwise loop
rows explicitly say `unavailable`, contain no timing values, and cause a
nonzero exit code. The current base revision unconditionally uses tail calls;
setting its unused build option cannot produce a real loop comparison.

## Workloads and validation

- Arithmetic: ADD, MUL, DIV, SDIV, MOD, EXP; AND, OR, XOR, SHL, SHR, SAR, CLZ.
- Memory/crypto: MLOAD, MSTORE, 32-byte MCOPY and KECCAK256.
- Storage: SLOAD and SSTORE, each with cold distinct keys or a warm repeated key.
  An untimed database seed gives each slot value 7. Each EVM invocation starts
  with a fresh access list. Warm cases prime the key within the timed bytecode;
  that priming overhead is included, with 128 measured target operations.
- Control/system: bounded JUMP/JUMPI loop, CALL and STATICCALL to a deployed
  child returning 42. Every nested call's success contributes to the checked sum.
- Existing repository fixtures: Snailtracer, ERC20 mint, ERC20 transfer, and
  ten-thousand-hashes. These files contain **initcode**. The runner executes
  CREATE during setup, verifies deployed code exists, and loads `calldata.txt`
  for the benchmark entry point. Constructor storage is preserved. Untimed constructors always run with fusion
  disabled, so all measured modes start from the same setup. This also avoids
  the baseline core's fused-constructor failure without retrying or changing
  fixture bytecode.
- Local EVM workloads generated in `workloads.zig`: 16-element BubbleSort with
  conditional swaps and an all-element checksum; Fibonacci(32); Factorial(20);
  256 dependent Keccak hashes; 64 constant-product AMM quotes including the
  0.3% swap fee. These cover workloads absent from the repository fixtures;
  the AMM case measures quote arithmetic, not a mainnet Uniswap replay.
- Precompiles: a nonzero ECRECOVER signature, SHA256 over 1 KiB, 256-bit MODEXP,
  non-infinity BN254 add/mul/pairing, BLS12-381 map-to-G1, and a valid generated
  deterministic P256 verification vector. BLS map-to-curve avoids infinity
  shortcuts. Signature generation and all input preparation happen before timing.

All cases default to Osaka (override with `-Dbench-hardfork=PRAGUE`), enabled gas accounting, disabled tracing, an EIP-7825 compliant 16,777,216 gas
budget on Osaka+ (1B for an explicit historical Prague build), and a 300M
instruction SafetyCounter. CLZ and P256 are capability
checked; absent implementations are explicitly unavailable. No stub substitutes
for an absent instruction, precompile, fixture, or dispatch implementation.

Setup/deployment, an initial successful validation call, and warmups precede
measurement. Each sample times `simulate()`: the ephemeral state overlay,
dispatch analysis/construction, execution, and owned result copying are included. Result
cleanup and validation are excluded. All samples start from identical state.
Every sample must succeed and match preflight gas/output; generated workloads
also check known results. Curve outputs must have the correct size and cannot
silently return infinity or empty bytes. A failed case records its stage,
sample index when applicable, remaining gas and output length when validation
fails, and exits nonzero after publishing the report. No failed/unavailable
case receives synthetic timing values.

## Results

JSON defaults to `bench/results/latest.json`; `--json` overrides it. Files are
replaced atomically after the full run. Schema version 1 contains compiler,
CPU/architecture/OS, optimization, fork, gas/tracing/safety settings, sample and
warmup counts, and per-case dispatch/fusion flags and status.

`statistics.median_ns`, `mean_ns`, and nearest-rank `p95_ns` describe one full
EVM call. `operations_per_call` is 128 for opcode batches and 1 for contract or
precompile invocations. `ns_per_op = median_ns / operations_per_call`;
`ops_per_sec = operations_per_call * 1e9 / mean_ns`;
`mgas_per_sec = gas_used * 1e3 / mean_ns`. Gas is `gas_limit - CallResult.gas_left`, including the intrinsic gas charged
by the public EVM API and its applied refunds. Median averages the two central
observations for even sample counts. Samples use a monotonic clock.

Warmup affects allocator/dispatch/CPU caches, not EIP-2929 storage warmth across
transactions. Small microbenchmarks include invocation and scaffolding costs;
compare the same workload/configuration on the same machine. CPU scheduling,
thermal state, and native dependency optimization also affect measurements.

## Standalone native dependencies

The existing root Cargo workspace omits `lib/voltaire`, and the vendored Zig
modules expose a crypto archive path without a producer dependency. The
standalone runner uses `bench/native/Cargo.toml` plus its lockfile to compile
**the existing vendored Rust source** into the Zig build cache, then substitutes
that generated archive in its private import graph. It does not edit the root
manifest, copy implementations, or modify any core source. Cargo, a native C
toolchain, and the usual vendored submodules are needed at build time. Normal
first-time Cargo dependency fetching still applies. Source and lockfile inputs
participate in the build cache key. Cross compilation is explicitly rejected
by the standalone entry point.

The former `evm_benchmarks*.zig` and `evm_fixture_benchmarks.zig` entry points
forward to the new runner. The dead external-repository build paths are removed.

## Subsystem microbenchmarks & incremental Smithers workflows

In addition to the full-EVM `guillotine-bench` runner (`opcode/`, `contract/`, `precompile/`),
every major Guillotine subsystem has a standalone ReleaseFast microbenchmark binary built
on the zero-dependency harness in `bench/micro.zig` and wired into per-subsystem Smithers
`PACKAGE.ts` targets:

| Subsystem | Smithers Target | Zig Step | Suite Source |
|:--|:--|:--|:--|
| Stack | `//src/stack:bench` | `zig build bench-stack` | `bench/suites/stack_bench.zig` |
| Memory | `//src/memory:bench` | `zig build bench-memory` | `bench/suites/memory_bench.zig` |
| Bytecode analysis | `//src/bytecode:bench` | `zig build bench-bytecode` | `bench/suites/bytecode_bench.zig` |
| Layer2 (OP Stack / Base FastLZ) | `//src/layer2:bench` | `zig build bench-layer2` | `bench/suites/layer2_bench.zig` |
| Provider / JSON-RPC validation | `//src/provider:bench` | `zig build bench-provider` | `bench/suites/provider_bench.zig` |
| Storage (Database, Journal, AccessList, LRU) | `//src/storage:bench` | `zig build bench-storage` | `bench/suites/storage_bench.zig` |
| Merkle Patricia Trie & NodeCache | `//src/trie:bench` | `zig build bench-trie` | `bench/suites/trie_bench.zig` |
| EIPs & Hardforks (EIP-7623, EIP-4844, EIP-1559) | `//src/eips_and_hardforks:bench` | `zig build bench-eips` | `bench/suites/eips_bench.zig` |
| Tracer RingBuffer | `//src/tracer:bench` | `zig build bench-tracer` | `bench/suites/tracer_bench.zig` |
| MinimalEvm reference interpreter | `//src/tracer:bench-minimal-evm` | `zig build bench-minimal-evm` | `bench/suites/minimal_evm_bench.zig` |
| Preprocessor (Dispatch & JumpTable) | `//src/preprocessor:bench` | `zig build bench-preprocessor` | `bench/suites/preprocessor_bench.zig` |
| Crypto primitives (Keccak, SHA256, ModExp, Secp256k1) | `//bench:bench-crypto` | `zig build bench-crypto` | `bench/suites/crypto_bench.zig` |
| C ABI / FFI lifecycle & simulation | `//bench:bench-ffi` | `zig build bench-ffi` | `bench/suites/ffi_bench.zig` |
| EVM Opcodes (40 opcodes, Osaka) | `//bench:bench-opcodes` | `zig build bench -- --filter opcode/` | `bench/workloads.zig` |
| EVM Contracts (9 contracts incl. Snailtracer, Prague) | `//bench:bench-contracts` | `zig build bench -Dbench-hardfork=PRAGUE -- --filter contract/` | `bench/workloads.zig` |
| EVM Precompiles (7 active + P256VERIFY check) | `//bench:bench-precompiles` | `zig build bench -- --filter precompile/ --allow-unavailable` | `bench/workloads.zig` |

Each subsystem binary links only its minimal dependency closure (via `src/pure_exports.zig`
and `src/voltaire_exports.zig`), compiles into its own prefix (`zig-out/bench-<suite>`), and
caches its JSON report (`bench/results/<suite>.json`) in Smithers.

```sh
# Run ONLY benchmarks whose declared inputs changed in your diff:
smthrs affected test //src/... //bench/... --include-exclusive

# Run the unified report across all 16 suites (replays cached results for unchanged suites):
smthrs test //bench:report --jobs 3

# Run a single subsystem benchmark directly via Smithers or Zig:
smthrs test //src/bytecode:bench
zig build bench-bytecode -- --iterations 40 --warmup 8

# Update the committed baseline after landing verified speedups:
node bench/summary.mjs --results-dir bench/results --write-baseline --baseline bench/baseline.json

# Run microbenchmark harness and EVM benchmark unit tests:
zig build test-bench test-micro-bench
```

`//bench:report` invokes `bench/summary.mjs` to aggregate all `bench/results/*.json` files,
compute `% faster / % slower` deltas against `bench/baseline.json`, and emit
`bench/results/summary.md` and `bench/results/all.json`.

## Known limitations of the base revision

The runner reports these conditions explicitly rather than producing misleading
performance numbers:

- `src/preprocessor/dispatch.zig` ignores `disable_tailcall_dispatch`; supply a
  verified loop module after that core work lands.
- `P256VERIFY` is absent from the base checkout's precompile dispatch table and
  is reported as `unavailable` until wired (pass `--allow-unavailable` to exit 0
  while still failing on any broken benchmark).
- Fused CREATE setup fails on the checked-in contract fixtures. The suite's
  constructor phase always uses the unfused EVM, separately from measured
  execution, so this does not silently alter a measured dispatch mode.
- Root `zig build` / `zig build test-opcodes` expect
  `lib/voltaire/target/release/libcrypto_wrappers.a` (`cargo build --release --manifest-path lib/voltaire/Cargo.toml`).
  The bench-owned build compiles its own generated archive automatically.
