# Guillotine Comprehensive Fuzz Testing Suite

Guillotine's fuzzing architecture is designed to guarantee **correctness** (not just crash-freedom) across every layer of the stack — Zig EVM core, bytecode fusion optimizer, precompiles, state/journal/MPT, EIPs/hardforks, C FFI boundary, Rust BN254/BLS12-381 FFI crate, and the TypeScript SDK.

## Architecture Overview

| Layer | Engine | Runs On | Command |
| :--- | :--- | :--- | :--- |
| **Zig Core Corpus & Leak Suite** | `std.testing.fuzz` + `std.testing.allocator` | macOS & Linux | `zig build test-fuzz` |
| **Zig LLVM Coverage-Guided Fuzzer** | `zig build test-fuzz --fuzz` (`-ffuzz`) | Ubuntu / Linux (`nyc-01` Latitude) | `./scripts/fuzz-remote-linux.sh --mode=zig-fuzz` |
| **Zig Multi-Threaded Campaign** | Structure-aware + havoc mutator (`fuzz_campaign.zig`) | macOS & Linux | `zig build fuzz-campaign -- --seconds=60 --threads=8` |
| **Rust Arkworks FFI (`lib/ark`)** | Property & adversarial FFI fuzzer | macOS & Linux | `cargo test -p bn254_wrapper` |
| **TypeScript SDK (`@tevm/guillotine`)** | Effect-Fuzz-style tape + feedback + shrinker (`engine.ts`) | macOS & Linux (Bun) | `cd sdks/typescript && bun run test:fuzz` |
| **Bare-Metal Latitude Server** | Turnkey sync + 48-core Linux fuzzing | `nyc-01` (Ubuntu 24.04) | `./scripts/fuzz-remote-linux.sh --seconds=300 --threads=32` |

## Zig Fuzz Targets (`test/fuzz/`)

1. **`bytecode_fuzz.zig`** — Independent Yellow Paper JUMPDEST reference oracle, PUSH1–PUSH32 / truncated-EOF handling, fusion bounds & no-interior-JUMPDEST invariants, iterator traversal, and OOM resilience (`std.testing.FailingAllocator`).
2. **`stack_fuzz.zig`** — Stateful model checker for 1024-slot, 32-slot (overflow boundary stress), and borrowed stacks across `push`, `pop`, `peek`, `set_top`, `dup_n(1..16)`, `swap_n(1..16)`, `reset`, and `binary_op_unsafe`.
3. **`memory_fuzz.zig`** — Stateful byte-exact model checker for `Memory` (`set_data_evm`, `set_u256_evm`, `set_byte_evm`, `get_u256_evm`, `get_slice`, overlapping `copy_within`/MCOPY, nested `init_child` checkpoints, `memory_limit` overflow) + exact Yellow Paper quadratic gas expansion oracle ($3a + \lfloor a^2/512 \rfloor$).
4. **`storage_journal_fuzz.zig`** — Stateful model checker for `Database` nested snapshots/reverts/commits, `begin_ephemeral_view`/`discard_ephemeral_view` (`simulate` isolation), `Journal` O(1) `original_storage` index vs brute-force log, transient storage, and EIP-2929 `AccessList` warm/cold gas accounting.
5. **`arithmetic_u256_fuzz.zig`** — Runs all 22 arithmetic/signed/bitwise/shift/comparison/modular opcodes (`ADD`, `MUL`, `SUB`, `DIV`, `SDIV` including `MIN_INT256 / -1`, `MOD`, `SMOD`, 512-bit `ADDMOD`/`MULMOD`, `EXP`, `SIGNEXTEND`, `BYTE`, `SHL`, `SHR`, `SAR`, `LT`/`GT`/`SLT`/`SGT`/`EQ`/`ISZERO`, `AND`/`OR`/`XOR`/`NOT`) inside Guillotine (fusion ON & OFF) and checks exact results against an independent `std.math.big.int.Managed` oracle.
6. **`differential_evm_fuzz.zig`** — Multi-oracle structure-aware EVM fuzzer covering 8 bytecode generation modes (raw, arithmetic, control-flow/loops, fusion stress, memory/MCOPY, storage/transient/logs, multi-contract `CALL`/`CALLCODE`/`DELEGATECALL`/`STATICCALL`/`CREATE`/`CREATE2`/`SELFDESTRUCT`, fork-gated opcodes) comparing `enable_fusion = true` vs `enable_fusion = false` vs `simulate()` across `FRONTIER`, `BERLIN`, `SHANGHAI`, `CANCUN`, and `PRAGUE`.
7. **`precompiles_fuzz.zig`** — All 19 Ethereum precompiles (`0x01`–`0x13`): exact oracles for `SHA256`, `IDENTITY`, `RIPEMD160`, `MODEXP` (vs BigInt across Byzantium..Osaka), `BN254` group homomorphism & commutativity axioms (`k1*G + k2*G == (k1+k2)*G`), `ECRECOVER`, `BLAKE2F` rounds/flags/gas, and all 9 EIP-2537 `BLS12-381` precompiles.
8. **`trie_fuzz.zig`** — Stateful `MerkleTrie` model checker + cryptographic permutation/order-independence of 32-byte Merkle root + canonical empty trie root.
9. **`eip_hardfork_fuzz.zig`** — EIP-4844 blob gas monotonicity & excess update, EIP-1559 effective gas price, EIP-3529 refund caps, EIP-2200/2929 SSTORE gas across all 14 hardforks, EIP-2028/3860/7623 calldata/initcode gas, and EIP-7702 `AuthorizationProcessor`.
10. **`c_api_fuzz.zig`** — Direct `extern "C"` ABI fuzzing of `libguillotine_ffi` (`guillotine_evm_create`, state roundtrips, invalid `call_type`s `6..255`, `guillotine_simulate` isolation & parity, `evm_bytecode_*`).

## Running Locally (macOS or Linux)

```bash
# 1. Run all Zig std.testing.fuzz targets over seed corpora with strict leak checking
zig build test-fuzz

# 2. Run multi-threaded structure-aware + havoc mutational fuzz campaign (macOS & Linux)
zig build fuzz-campaign -- --seconds=60 --threads=8

# 3. Filter to a specific subsystem
zig build fuzz-campaign -- --seconds=30 --threads=4 --target=differential

# 4. Run Rust BN254/BLS12-381 FFI fuzz tests
cargo test -p bn254_wrapper

# 5. Run TypeScript SDK feedback-guided mutational + shrinking fuzz tests
zig build shared -Doptimize=ReleaseFast
(cd sdks/typescript && bun run test:fuzz)
(cd sdks/typescript && bun run fuzz -- --executions=5000)
```

## Running Native LLVM Coverage-Guided `--fuzz` on Ubuntu / Latitude (`nyc-01`)

Zig 0.15.x's `--fuzz` flag requires Linux ELF debug info. Use the remote runner script to execute native coverage-guided fuzzing on our 48-core bare-metal Ubuntu Latitude server (`nyc-01`):

```bash
# Run full suite (Zig corpus + multi-threaded campaign + LLVM --fuzz + Rust + TypeScript)
./scripts/fuzz-remote-linux.sh --seconds=120 --threads=32 --mode=all

# Run LLVM coverage-guided --fuzz on a specific target
./scripts/fuzz-remote-linux.sh --mode=zig-fuzz --filter="fuzz differential EVM execution" --seconds=300
```

## Crash Artifacts & Reproducibility

- **Zig `fuzz-campaign`**: Saves reproducing raw bytes to `.fuzz-crashes/<target>_seed<S>_iter<I>.bin` and prints the hex payload and seed.
- **TypeScript SDK fuzzer**: Automatically delta-shrinks failing inputs to minimal counterexamples and prints a deterministic `gfuzz1:...` replay token.
