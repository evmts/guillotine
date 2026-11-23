# CLAUDE.md - OP Stack module

Every formula here is consensus-critical. The reference is op-revm:
https://github.com/ethereum-optimism/optimism/tree/develop/rust/op-revm/src
When in doubt, read that code; do not trust prose (including this file) over it.

## Files

| File | Contents |
| --- | --- |
| `spec.zig` | `OpSpecId` BEDROCK=100 … JOVIAN=108, `toEthHardfork` |
| `constants.zig` | Predeploy addresses, L1Block slots/offsets, fee constants |
| `l1_block_info.zig` | `L1BlockInfo.tryFetch`, L1 data fee, operator fee and refund |
| `fast_lz.zig` | FastLZ compressed-length estimate (Fjord) |
| `da_footprint.zig` | Jovian DA footprint block limit |
| `transaction.zig` | Deposit (0x7E) transaction data types |
| `deposit.zig` | Deposit execution rules (mint, nonce, gas, failed deposits) |
| `precompiles.zig` | P256VERIFY, BN254/BLS input limits, `overrides(Override, spec)` |
| `testdata/p256verify_vectors.txt` | 782 go-ethereum/Wycheproof P256 vectors |

## Specs

| Spec | Eth fork | EVM-visible change |
| --- | --- | --- |
| BEDROCK | MERGE | L1 fee with overhead; +1088 data gas; system deposits allowed |
| REGOLITH | MERGE | no +1088; system deposits rejected; deposit gas = actual |
| CANYON | SHANGHAI | Shanghai |
| ECOTONE | CANCUN | blob-aware L1 fee |
| FJORD | CANCUN | FastLZ L1 fee; P256VERIFY at 0x100 (3450 gas) |
| GRANITE | CANCUN | BN254 pairing input ≤ 112,687 bytes |
| HOLOCENE | CANCUN | none (consensus layer only) |
| ISTHMUS | PRAGUE | operator fee; BLS12-381 MSM/pairing input limits |
| JOVIAN | PRAGUE | operator fee ×100; DA footprint limit; tighter BN254/BLS limits |

Karst and Lagoon (op-revm) are not modeled.

## L1Block storage (0x4200…0015)

Offsets are big-endian byte indexes into the 32-byte slot value.

| Slot | Field | Bytes |
| --- | --- | --- |
| 1 | l1BaseFee | whole slot |
| 3 | baseFeeScalar / blobBaseFeeScalar | [16..20) / [20..24) |
| 5 | overhead (Bedrock; Ecotone only when scalars are empty) | whole slot |
| 6 | l1FeeScalar (Bedrock) | whole slot |
| 7 | blobBaseFee | whole slot |
| 8 | daFootprintGasScalar u16 / operatorFeeScalar u32 / operatorFeeConstant u64 | [18..20) / [20..24) / [24..32) |

## Formulas

```
dataGas (pre-Fjord) = 4*zeroBytes + 16*nonZeroBytes (+1088 before Regolith)
estimatedSize       = max(100e6, fastlzSize*836_500 - 42_585_600)   // saturating
dataGas (Fjord+)    = estimatedSize * 16 / 1e6
l1FeeScaled         = l1BaseFee*16*baseFeeScalar + blobBaseFee*blobBaseFeeScalar

Bedrock  = (dataGas + overhead) * l1BaseFee * l1Scalar / 1e6
Ecotone  = dataGas * l1FeeScaled / 16e6            (empty scalars → Bedrock formula)
Fjord+   = estimatedSize * l1FeeScaled / 1e12

operator (Isthmus) = gas * scalar / 1e6 + constant
operator (Jovian)  = gas * scalar * 100 + constant
```

The operator fee is charged on `gas_limit` up front and `fee(gas_limit) - fee(gas_used)`
is refunded. Deposits and empty input pay no L1 fee and no operator fee.

Tests pin real OP mainnet values: Ecotone block 118024092 (7,306,020,222,001 wei) and
Fjord block 124665056 (0x5bf1ab43d wei).

## Deposits (type 0x7E)

See the rule table at the top of `deposit.zig`. Key points: mint is credited even when
execution fails; a failed deposit bumps the nonce and keeps the mint; Regolith+ rejects
`is_system_transaction`; deposits never pay fees or credit fee vaults.

## Precompiles

`precompiles.zig` imports the voltaire `precompiles` module and needs
`precompiles.p256verify` (contract: exported from `lib/voltaire/src/precompiles/root.zig`).
`overrides(Override, spec)` takes the EVM's override type as a parameter so this module
does not import `src/evm_config.zig`. A failing precompile maps to
`success = false, gas_used = gas_limit`; `error.OutOfMemory` propagates.

BLS12-381 addresses follow final EIP-2537: G1 MSM 0x0c, G2 MSM 0x0e, pairing 0x0f.
