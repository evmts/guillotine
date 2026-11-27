# `src/layer2`

Base and OP Stack Layer 2 execution rules running on fork-configured Guillotine `Evm` instances (Bedrock through Jovian).

## Modules

- **`layer2_config.zig`** — Comptime `Layer2Config` (`none | optimism | base`) so L1-only builds compile out all L2 code at zero cost.
- **`mod.zig`** — Public module exports re-exported from `src/root.zig` as `layer2`.
- **`executor.zig`** — Transaction boundary handling deposits, L1 data fees, operator fees, nonces, and host contracts.
- **`evm_host.zig`** — Real EVM host driving `Evm.inner_call` across Bedrock through Jovian, including EIP-2930 access lists, EIP-7702 authorization lists on Isthmus/Jovian, fee-vault settlement, and EIP-7623 floors.
- **`optimism/`** — OP Stack hardfork schedule, DA footprint, L1 cost, and system rules.
- **`base/`** — Base Mainnet (`8453`) and Sepolia (`84532`) activation timestamps, fee settlement, and precompile overrides.
- **`test_root.zig`** — Aggregator for `zig build test-layer2`.

## Invariants

- Every fee and state-transition formula matches `op-revm` (OP Stack) and `base/base` (Base).
- Unmodeled future Base upgrades (`Azul`, `Beryl`, `Cobalt`, `Denim`) return `error.UnmodeledBaseUpgrade` instead of silently falling back to Jovian.
- `evm_host.zig` stays its own test artifact (never imported from `mod.zig` or `test_root.zig`). Run `zig build test-layer2` from repository root.
