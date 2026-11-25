# CLAUDE.md - Layer2 module

L2 fee or rule errors cause fund loss or chain divergence. Every formula must match the
L2 client exactly: op-revm for OP Stack, base/base for Base.

## Layout

```
src/layer2/
├── layer2_config.zig   Layer2Config = none | optimism: OptimismConfig | base: BaseConfig
├── mod.zig             public exports (the `evm` module exports it as `layer2`)
├── executor.zig        transaction boundary: deposits, fees, nonce, host contract
├── evm_host.zig        host backed by the real EVM; own test artifact, imports `evm` only
├── test_root.zig       test aggregator
├── optimism/           OP Stack rules (see optimism/CLAUDE.md)
└── base/
    ├── config.zig      BaseChain (8453, 84532), BaseConfig, SystemContracts
    ├── hardforks.zig   Base Mainnet / Sepolia activation timestamps, specAt
    ├── fees.zig        upfront cost and fee-vault settlement
    └── precompiles.zig P256VERIFY / BN254 limits resolved by chain + timestamp
```

## Zero-cost selection

`Layer2Config` is comptime. Branch with `if (comptime cfg.isOpStack())` so `.none` builds
contain no L2 code. `opSpec()` returns the `OpSpecId` for `.optimism` and `.base`.

## Base

- Chain IDs: mainnet 8453, Sepolia 84532.
- Timestamps come from base/base `crates/common/chains/src/config.rs`, cross-checked with
  the last superchain-registry revision that listed Base (720185c3).
- Regolith activates at genesis, so Base never runs Bedrock rules.
- Azul, Beryl, Cobalt, Denim are Base-only upgrades with EVM changes (Azul maps to Osaka
  and reprices P256VERIFY). They are recorded but not modeled; `specAt` returns
  `error.UnmodeledBaseUpgrade` at or after Azul. Do not silently fall back to Jovian.

## Wiring status

- `src/root.zig` exports `layer2`; `zig build test-layer2` runs `layer2-tests`
  (test_root.zig) and `layer2-evm-host-tests` (evm_host.zig).
- `evm_host.zig` must not be imported from mod.zig or test_root.zig: the `evm` module
  owns those files, and a file may belong to one module only.
- `src/evm.zig` ignores `EvmConfig.precompile_overrides` and selects precompiles by its
  comptime hardfork. `evm_host.Host.configure` therefore refuses Fjord+ (P256VERIFY,
  BN254/BLS input limits) and Bedrock. Lift this only after the EVM applies overrides in
  nested calls.

## Testing

`zig build test-layer2` from the repository root. New tests in evm_host.zig must use the
host through `executor.execute`/`executeBase`, not the EVM directly.
