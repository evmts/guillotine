# 100-Block Ethereum Mainnet Replay Benchmark

Replays 100 contiguous Ethereum mainnet blocks (pinned to `26,498,000`–`26,498,099`, Osaka / BPO2; see [manifest.json](manifest.json)) offline against cached pre-state, executing EIP-4788 and EIP-2935 pre-block system calls, all legacy / EIP-2930 / EIP-1559 / EIP-4844 / EIP-7702 transactions, EIP-7002 and EIP-7251 post-block system calls, and EIP-4895 withdrawals, and verifying per-transaction status and gas against mainnet receipts (`29,560 / 29,560` exact match, `0` gas diff across `2,973,053,521` gas).

## Reproduce

1. Fetch and cache the pinned 100-block pre-state bundle once from any Ethereum archive RPC that supports `debug_traceBlockByNumber` (`prestateTracer`) and `eth_getBlockReceipts`:

```console
$ ETHEREUM_RPC_URL=https://... node bench/blocks/fetch.mjs --start 26498000 --count 100
```

2. Run Guillotine's `ReleaseFast` replay benchmark:

```console
$ zig build bench-blocks -- --iterations 5 --warmup 1
```

3. Run the matching `revm` comparison runner against the exact same cached bundle:

```console
$ RUSTFLAGS="-C target-cpu=native" cargo build --release --locked --manifest-path bench/blocks/runners/revm/Cargo.toml
$ ./bench/blocks/runners/revm/target/release/blocks-revm --iterations 5 --warmup 1
```
