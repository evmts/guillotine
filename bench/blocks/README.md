# 100-Block Ethereum Mainnet Replay Benchmark

Replays 100 contiguous Ethereum mainnet blocks (pinned to `26,498,000`–`26,498,099`, Osaka / BPO2; see [manifest.json](manifest.json)) offline against pre-fetched pre-state, executing EIP-4788 and EIP-2935 system calls, all legacy / EIP-2930 / EIP-1559 / EIP-4844 / EIP-7702 transactions, and EIP-4895 withdrawals, and verifying per-transaction status and gas against mainnet receipts.

## Reproduce

1. Fetch the pinned range once from any Ethereum archive RPC that supports `debug_traceBlockByNumber` (`prestateTracer`) and `eth_getBlockReceipts`:

```console
$ ETHEREUM_RPC_URL=https://... node bench/blocks/fetch.mjs --start 26498000 --count 100
```

2. Run the `ReleaseFast` replay benchmark:

```console
$ zig build bench-blocks -- --iterations 5 --warmup 1
```
