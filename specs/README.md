# Ethereum Execution Specs

This directory contains the Ethereum execution specification tests for Guillotine EVM.

## Official EEST state tests (`eest_runner.zig`)

`specs/eest_runner.zig` runs the official **pre-filled** Ethereum Execution Spec
Tests `state_tests/**/*.json` fixtures. A case passes only when the post-state
Merkle Patricia Trie root equals `post[fork][i].hash` and the RLP logs hash
equals `post[fork][i].logs`. It does not read the legacy `:asm` / `:yul`
fillers that the sections below describe.

### Fetch the fixtures

```bash
scripts/fetch-eest-fixtures.sh             # latest ethereum/execution-specs "tests@v*" release
EEST_RELEASE_TAG='tests@v21.0.3' scripts/fetch-eest-fixtures.sh
EEST_CACHE_DIR=/shared/cache scripts/fetch-eest-fixtures.sh --print-dir
```

The script downloads `fixtures.tar.gz`, checks it against the SHA-256 digest
that GitHub publishes for the asset, and extracts only `fixtures/state_tests`.
A `STAMP` file records the tag and digest, so a second run for the same release
downloads nothing. The cache directory ignores itself in version control.

```
.cache/eest-fixtures/
├── current -> tests_v21.0.3
└── tests_v21.0.3/
    ├── STAMP                                  tag, asset, sha256
    └── fixtures/state_tests/
        ├── for_frontier/ … for_osaka/         one tree per fork the tests were filled for
        │   └── <fork>/<eip or suite>/…/*.json
        └── for_amsterdam/                     skipped: fork not implemented
```

### Run

The runner is a standalone executable that imports the `evm` and `crypto`
modules. Every option is an environment variable with an equivalent flag; the
flag wins.

| Variable | Flag | Meaning |
| --- | --- | --- |
| `EEST_FIXTURES_DIR` | `--fixtures=<dir>` | Fixture root. Default `.cache/eest-fixtures/current/fixtures/state_tests`. |
| `EEST_FORK` | `--fork=<a,b>` | Run only these forks. Unset runs Frontier through Osaka. |
| `EEST_FILTER` | `--filter=<text>` | Substring of `<file>::<test name>`. |
| `EEST_REPORT_JSON` | `--report=<path>` | Write the JSON summary. |
| `EEST_JOBS` | `--jobs=<n>` | Worker processes. Default: CPU count. `0` runs in-process. |
| `EEST_TIMEOUT_SECS` | `--timeout=<secs>` | Per-case limit for worker processes. Default 600. |
| `EEST_VERBOSE` | `--verbose` | Print every failure and keep worker stderr. |

```bash
eest-runner --fork=Cancun,Prague --report=eest.json
eest-runner --filter='eip3855_push0' --verbose
eest-runner --filter='push0_contracts.json::test_push0_contracts[fork_Shanghai-state_test-key_sstore]' --jobs=0 --verbose
```

Exit code `0` means every case passed, `1` means at least one failure, `2`
means a usage error (missing fixtures, unknown fork, nothing matched).

Fork names follow the fixtures: `Frontier`, `Homestead`, `TangerineWhistle`
(`EIP150`), `SpuriousDragon` (`EIP158`), `Byzantium`, `Constantinople`,
`ConstantinopleFix` (`Petersburg`), `Istanbul`, `Berlin`, `London`, `Paris`
(`Merge`), `Shanghai`, `Cancun`, `Prague`, `Osaka`. Posts for any other fork
(`Amsterdam`, `BPO*`) are counted under `skipped_forks`.

### Build wiring

`build.zig` belongs to another lane. Contract 3 maps onto the runner as follows:

```zig
const eest_mod = b.createModule(.{
    .root_source_file = b.path("specs/eest_runner.zig"),
    .target = target,
    .optimize = optimize,
});
eest_mod.addImport("evm", modules.evm_mod);
eest_mod.addImport("crypto", modules.crypto_mod);
const eest_exe = b.addExecutable(.{ .name = "eest-runner", .root_module = eest_mod, .use_llvm = true });
if (bn254_lib) |bn254| eest_exe.linkLibrary(bn254);
eest_exe.linkLibC();

const run_eest = b.addRunArtifact(eest_exe);
if (b.option([]const u8, "spec-fork", "EEST fork(s)")) |fork| run_eest.addArg(b.fmt("--fork={s}", .{fork}));
if (test_filter) |filter| run_eest.addArg(b.fmt("--filter={s}", .{filter}));
if (b.option([]const u8, "spec-report", "EEST JSON report path")) |path| run_eest.addArg(b.fmt("--report={s}", .{path}));
b.step("state-tests", "Run official EEST state tests").dependOn(&run_eest.step);
```

`b.addTest` on the same module runs the runner's unit tests (RLP, trie, hex,
intrinsic gas, blob fee, signature decoding).

### What one case does

```
post[fork][i]
   │
   ├─ load `pre` into a fresh Database (balance, nonce, code, storage;
   │  a Prague 0xef0100 designator becomes Account.delegated_address)
   ├─ select data / gasLimit / value / access list by `indexes`
   ├─ validate the transaction ──► TransactionException or valid
   │     type gating, intrinsic gas, EIP-7623 floor, nonce, initcode size,
   │     EIP-7825 gas cap, block gas limit, blob count and fees, signature
   │     ranges and chain id (from `txbytes`), EIP-1559 fees, balance, EIP-3607
   │
   ├─ expectException set?  the raised exception must be one of the listed
   │                        alternatives, and the untouched pre-state must
   │                        hash to `hash`
   └─ valid transaction:
        buy gas, bump nonce ─► warm sender / target / precompiles / coinbase /
        access list ─► EIP-7702 authorizations ─► Evm(fork).inner_call ─►
        refund cap (1/2, 1/5 from London) ─► EIP-7623 floor ─► sender refund ─►
        coinbase tip (EIP-1559 burn) ─► apply SELFDESTRUCT records ─►
        EIP-161 empty-account deletion
   ▼
stateRoot = MPT(keccak(address) → rlp[nonce, balance, storageRoot, codeHash])
logsHash  = keccak(rlp([[address, [topics], data], …]))
```

The runner computes both hashes itself: `Database.get_state_root` trusts the
stored `storage_root` field instead of the storage slots, and `src/trie` is not
exported by the `evm` module.

The runner owns the transaction layer because `Evm.call` does not implement it
(it charges a flat 21000 or 53000, ignores calldata, access lists, blobs,
authorizations, the upfront balance check, selfdestruct and EIP-161). Three
choices follow from the EVM's current interface:

- A message call that spends exactly its intrinsic gas and targets an account
  with no code is applied by the runner, because `Evm.inner_call` rejects a
  call that carries zero gas.
- A create transaction passes `gas + 32000` because `inner_call` charges the
  CREATE gas itself.
- EIP-161 uses `Evm.touched_addresses`, which also records read-only accesses
  (`BALANCE`, `EXTCODE*`). An empty pre-state account that a transaction only
  reads is therefore deleted.

### Failure reasons

Each failing case gets one reason, the first that applies:

| Reason | Meaning |
| --- | --- |
| `expected_exception_not_raised` | Fixture expects an invalid transaction; the runner accepted it. |
| `wrong_exception` | Rejected, but with an exception the fixture does not list. |
| `unexpected_tx_rejection` | A valid transaction was rejected. |
| `status_mismatch` | Receipt status differs from the EVM result. |
| `gas_used_mismatch` | Receipt `cumulativeGasUsed` differs. |
| `account_missing`, `unexpected_account` | Account set differs from `post.state`. |
| `nonce_mismatch`, `code_mismatch`, `storage_mismatch`, `balance_mismatch` | First differing field against `post.state`. |
| `state_root_mismatch_unexplained` | Accounts equal `post.state` but the root differs. A non-zero count is a runner bug. |
| `logs_hash_mismatch` | State root matches, logs hash differs. |
| `crash`, `timeout` | The worker process died or exceeded the limit on this case. |
| `runner_error`, `fixture_error` | An error inside the runner, or a fixture the strict parser rejects. |

### Process model

```
parent ──spawn──► worker 0 ──┐   each worker owns files where index % jobs == shard
        ──spawn──► worker 1 ──┤   and streams one line per case on stdout:
        ──spawn──► worker N ──┘   F file · S case start · P pass · X fail · K skip · D file done · E end

worker dies or exceeds the limit on case k  ─►  parent records `crash` / `timeout` for k
                                             ─►  restarts the worker at case k + 1
```

A crash or a hang in the EVM costs one case, never the run. Workers run on a
1 GiB stack because the EVM recurses once per call depth. Debug builds use
`std.heap.DebugAllocator` and report `leak_check` (`clean` or `leaked`).

### Baseline (2026-11-22)

`tests@v21.0.3` (sha256 `46bd48fb…04fd24`), 10,693 files, ReleaseFast, 66,652
cases in 470 s on a MacBook Pro. All 4,370 invalid-transaction cases agree with
the fixtures, and no root mismatch is unexplained, so the remaining failures
are EVM behavior, not runner bookkeeping.

| Fork | Passed | Failed | Total | Pass % |
| --- | ---: | ---: | ---: | ---: |
| Frontier | 194 | 619 | 813 | 23.86 |
| Homestead | 198 | 685 | 883 | 22.42 |
| TangerineWhistle | 197 | 684 | 881 | 22.36 |
| SpuriousDragon | 234 | 727 | 961 | 24.35 |
| Byzantium | 251 | 2,081 | 2,332 | 10.76 |
| ConstantinopleFix | 262 | 2,263 | 2,525 | 10.38 |
| Istanbul | 264 | 2,388 | 2,652 | 9.95 |
| Berlin | 558 | 3,035 | 3,593 | 15.53 |
| London | 830 | 3,044 | 3,874 | 21.42 |
| Paris | 830 | 3,059 | 3,889 | 21.34 |
| Shanghai | 864 | 3,224 | 4,088 | 21.14 |
| Cancun | 2,202 | 9,376 | 11,578 | 19.02 |
| Prague | 2,808 | 11,111 | 13,919 | 20.17 |
| Osaka | 2,808 | 11,856 | 14,664 | 19.15 |
| **Total** | **12,500** | **54,152** | **66,652** | **18.75** |

| Reason | Cases | First example |
| --- | ---: | --- |
| `gas_used_mismatch` | 40,684 | `60015f55` (cold `SSTORE` 0→1) uses 43,205 gas, fixture 43,105 |
| `status_mismatch` | 13,046 | valid `CALL` contract fails with `StackUnderflow`; `ecpairing` |
| `crash` | 266 | worker `SIGSEGV`, for example `frontier/opcodes/log/gas.json` |
| `nonce_mismatch` | 125 | Frontier contract created with nonce 1, fixture 0 |
| `storage_mismatch` | 29 | `ripemd` precompile result, initcode gas |
| `balance_mismatch` | 2 | `stRandom2/random_statetest642` |

16,907 Amsterdam posts are skipped.

### JSON report

```json
{
  "schema": "guillotine-eest-report/v1",
  "release": "tests@v21.0.3",
  "totals": { "files": 0, "cases": 0, "passed": 0, "failed": 0, "skipped": 0 },
  "forks": {
    "Cancun": {
      "passed": 0, "failed": 0,
      "failure_reasons": { "gas_used_mismatch": 0 },
      "suites": { "cancun/eip4844_blobs": { "passed": 0, "failed": 0 } }
    }
  },
  "skipped_forks": { "Amsterdam": 0 },
  "failure_reasons": {
    "gas_used_mismatch": {
      "count": 0,
      "examples": [ { "fork": "", "file": "", "test": "", "index": 0, "detail": "" } ]
    }
  },
  "leak_check": "clean"
}
```

The report also carries `fixtures_dir`, `fork_filter`, `test_filter`,
`optimize`, `jobs` and `duration_ms`. Each reason keeps its first five examples.

## Legacy filler specs

## Test Results

Current status: **2124 pass / 1043 fail** (3167 expect() calls total)

## Running the Specs

### Quick Start

```bash
# Run all specs (default: first 100 files)
zig build specs

# Run with more files
zig build specs -- -Dspec-max-files=500

# Run all available spec files
zig build specs -- -Dspec-max-files=10000

# Run specs matching a specific pattern
zig build specs -- -Dspec-pattern='add*.json'

# Run in isolated mode (each test in separate process)
zig build specs -- -Dspec-isolated=true
```

### Build Options

- `-Dspec-max-files=N` - Limit the number of spec files to run (default: 100)
- `-Dspec-pattern='*.json'` - Pattern to match test files (default: '*.json')
- `-Dspec-isolated=true` - Run each test in an isolated process (safer but slower)
- `-Dspec-args` - Additional arguments to pass to the test runner

### Test Modes

1. **Normal Mode** (`ethereum-specs.test.ts`) - Default mode, runs tests in the same process
2. **Isolated Mode** (`ethereum-specs-safe.test.ts`) - Each test runs in a separate worker process to prevent crashes from affecting other tests

### Directory Structure

```
specs/
├── README.md                     # This file
├── CLAUDE.md                     # AI assistant instructions
├── test_report.md                # Detailed test results
├── execution-specs/              # Git submodule with official Ethereum tests
│   └── tests/                    # Test JSON files organized by category
└── bun-runner/                   # Bun test runner implementation
    ├── ethereum-specs.test.ts    # Main test runner
    ├── ethereum-specs-safe.test.ts # Isolated test runner
    ├── test-worker.js            # Worker script for isolated mode
    ├── generate-specs.ts         # (unused) Test generator
    └── package.json              # Bun dependencies
```

## Implementation Details

The test runner:
1. Recursively finds all JSON test files in `execution-specs/tests/`
2. Groups tests by category (directory name)
3. For each test case:
   - Sets up the blockchain environment (block info)
   - Initializes pre-state (accounts, balances, code)
   - Executes transaction(s)
   - Validates the result didn't crash
   - (Post-state validation not yet implemented)

## Known Limitations

- Assembly code tests are skipped (not supported)
- Post-state validation not yet implemented
- Some edge cases may cause crashes in normal mode (use isolated mode for safety)