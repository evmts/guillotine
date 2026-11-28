# CLAUDE.md - Ethereum Spec Tests

`specs/` holds the conformance runners for Guillotine. Full reference:
[README.md](README.md).

## Runners

| Command | Runner | What passes |
| --- | --- | --- |
| `zig build state-tests` | `specs/eest_runner.zig` | Official pre-filled EEST `state_tests` fixtures, Frontier through Osaka. A case passes only when the post-state trie root and the logs hash both match the fixture. |
| `zig build state-tests -Devm-enable-fusion=false` | same, via `specs/evm_fusion_off.zig` | The same fixtures with bytecode fusion off |
| `zig build specs` | `specs/cases/root.zig` + `specs/runner.zig` | Generated legacy filler cases |
| `zig build specs-bun` | `specs/bun-runner/` | The Bun/TypeScript runner over the C FFI |

`zig build test` does not run `specs` or `state-tests`: both need fetched fixtures.

## EEST state tests

```bash
scripts/fetch-eest-fixtures.sh                       # pinned release into .cache/eest-fixtures
zig build state-tests -Doptimize=ReleaseSafe         # fusion on
zig build state-tests -Doptimize=ReleaseSafe -Devm-enable-fusion=false
zig build state-tests -Dspec-fork=Cancun,Prague      # selected forks
zig build state-tests -Dtest-filter='eip3855_push0'  # substring of <file>::<test name>
zig build state-tests -Dspec-report=eest.json        # JSON summary
```

Status: every case from Frontier through Osaka passes in both dispatch modes
(`66,652 / 66,652` on `tests@v21.0.3`). Amsterdam and `BPO*` posts are counted as
skipped forks, not failures. A change that drops one case is a consensus
regression: fix it before anything else.

Exit code `0` means every case passed, `1` at least one failure, `2` a usage error
(missing fixtures, unknown fork, nothing matched).

The runner validates each transaction (type gating, intrinsic gas, the EIP-7623
floor, nonce, initcode size, the EIP-7825 gas cap, blob count and fees, signature
ranges, EIP-1559 fees, balance, EIP-3607), executes it, and compares the state root
and logs hash. For an `expectException` case the raised exception must be one of the
listed alternatives and the untouched pre-state must hash to the fixture's root.

## Legacy `specs` step

```bash
zig build specs
zig build specs -Dspec-max-files=100
zig build specs -Dspec-skip-files=50
zig build specs -Dtest-filter='add'
```

## Debugging a failing case

1. Reproduce one case in-process:
   `zig build state-tests -Dtest-filter='<file>::<test name>' -- --jobs=0 --verbose`
2. Run it with fusion off. A case that fails in one mode only points at a fused
   handler or at block gas and stack analysis.
3. Reduce it to a differential test under `test/differential/` or
   `test/evm/opcodes/`; `zig build test-opcodes` then compares the frame against
   the reference interpreter instruction by instruction.
4. Run Debug and ReleaseSafe as well as ReleaseFast: the tracer hooks and safety
   checks exist only in the first two.

## Rules

- Never skip, filter out or comment out a failing case.
- Fix a crash before the bug that triggered it: the EVM returns errors, it never
  aborts.
- Rerun both fusion modes after any change to handlers, dispatch, bytecode
  analysis, gas or state.
