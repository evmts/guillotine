# CLAUDE.md - Layer2 module

L2 fee or rule errors cause fund loss or chain divergence. Every formula must match the
L2 client exactly: op-revm for OP Stack, base/base for Base.

## Layout

```
src/layer2/
├── layer2_config.zig   Layer2Config = none | optimism: OptimismConfig | base: BaseConfig
├── mod.zig             public exports
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

Not yet wired into the build or EVM (pending lane merge):

- `lib/voltaire/src/precompiles/root.zig` must export `p256verify`.
- `src/root.zig` must export `layer2`, and `build.zig` must register `zig build test-layer2`
  with imports `voltaire` and `precompiles`.
- `src/evm.zig` does not yet consume `EvmConfig.precompile_overrides` or `Layer2Config`.

## Testing

Until `test-layer2` exists, run the module with `zig test` and these modules:
`root=src/layer2/test_root.zig`, `voltaire`, `precompiles` (with the `p256verify` export),
`crypto`, `c_kzg`, linking blst, c-kzg, and voltaire's `libcrypto_wrappers.a`.
