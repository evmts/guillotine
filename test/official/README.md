# Official Execution Spec Fixtures

This folder wires the Ethereum execution-spec-tests (v4.5.0) into Guillotine.

Contents:
- `fixtures/` — the two JSON files the smoke tests read by default, taken from
  `fixtures_stable.tar.gz` published at v4.5.0. The rest of that archive is no
  longer committed; the full official state-test suite comes from the pinned
  release fetched by `scripts/fetch-eest-fixtures.sh` (`zig build state-tests`).
- `state_smoke_test.zig` — a minimal, self-contained state-test runner

Usage:
- Run another case by setting `OFFICIAL_JSON=<path>`. To get the old archive:
  - `curl -L -o test/official/fixtures_stable.tar.gz https://github.com/ethereum/execution-spec-tests/releases/download/v4.5.0/fixtures_stable.tar.gz`
  - `tar -xzf test/official/fixtures_stable.tar.gz -C test/official`
- Run the smoke test (non-strict — executes but does not enforce full post-state):
  - `zig build test-official`
- Run the smoke test in strict mode (enforces post-state; may fail until parity improves):
  - `zig build test-official-strict`

Notes:
- This harness focuses on `state_tests` and is intentionally lightweight.
- It currently targets a single representative JSON to keep CI time reasonable and the integration simple.
- Extend by duplicating the `test` block in `state_smoke_test.zig` with additional JSON paths, or by iterating a small curated set.

