#!/usr/bin/env node
/**
 * Fetches a pinned contiguous range of Ethereum mainnet blocks with exact
 * pre-state (via debug_traceBlockByNumber prestateTracer), full transactions,
 * receipts, withdrawals, and 256 ancestor block hashes for offline replay
 * benchmarking (`zig build bench-blocks`).
 *
 * Each pre-state account and storage slot is tagged with the (block_idx, tx_idx)
 * where it first appeared in prestateTracer so the replay runner can separate
 * true pre-start-block state from accounts/slots created mid-window.
 */
import { createHash } from 'node:crypto';
import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';

const DEFAULT_START = 26498000;
const DEFAULT_COUNT = 100;
const CONCURRENCY = 4;

function parseArgs(argv) {
  const opts = {
    start: DEFAULT_START,
    count: DEFAULT_COUNT,
    out: `.cache/mainnet-blocks/${DEFAULT_START}-${DEFAULT_START + DEFAULT_COUNT - 1}.json`,
    manifest: null,
  };
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--start') opts.start = Number(argv[++i]);
    else if (a === '--count') opts.count = Number(argv[++i]);
    else if (a === '--out') opts.out = argv[++i];
    else if (a === '--manifest') opts.manifest = argv[++i];
    else throw new Error(`Unknown argument: ${a}`);
  }
  return opts;
}

const RPC_URL = (process.env.ETHEREUM_RPC_URL || process.env.TEVM_TEST_MAINNET_URL || '').trim();
if (!RPC_URL) {
  console.error('Missing ETHEREUM_RPC_URL (or TEVM_TEST_MAINNET_URL) with debug_traceBlockByNumber + eth_getBlockReceipts support.');
  process.exit(1);
}

let nextId = 1;
async function rpc(method, params, retries = 7) {
  for (let attempt = 0; attempt <= retries; attempt++) {
    try {
      const res = await fetch(RPC_URL, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'User-Agent': 'guillotine-bench-blocks' },
        body: JSON.stringify({ jsonrpc: '2.0', id: nextId++, method, params }),
      });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const data = await res.json();
      if (data.error) throw new Error(`RPC ${method}: ${data.error.message || JSON.stringify(data.error)}`);
      return data.result;
    } catch (err) {
      if (attempt === retries) throw err;
      const delay = 600 * Math.pow(2, attempt);
      await new Promise((r) => setTimeout(r, delay));
    }
  }
}

async function rpcBatch(calls, retries = 7) {
  if (calls.length === 0) return [];
  const payload = calls.map((c) => ({ jsonrpc: '2.0', id: nextId++, method: c.method, params: c.params }));
  for (let attempt = 0; attempt <= retries; attempt++) {
    try {
      const res = await fetch(RPC_URL, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'User-Agent': 'guillotine-bench-blocks' },
        body: JSON.stringify(payload),
      });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const arr = await res.json();
      if (!Array.isArray(arr)) throw new Error('Expected batch array');
      const byId = new Map(arr.map((x) => [x.id, x]));
      return payload.map((req) => {
        const resp = byId.get(req.id);
        if (!resp || resp.error) throw new Error(`Batch ${req.method}: ${JSON.stringify(resp?.error)}`);
        return resp.result;
      });
    } catch (err) {
      if (attempt === retries) throw err;
      const delay = 600 * Math.pow(2, attempt);
      await new Promise((r) => setTimeout(r, delay));
    }
  }
}

async function mapLimit(items, limit, fn) {
  const results = new Array(items.length);
  let cursor = 0;
  async function worker() {
    while (cursor < items.length) {
      const idx = cursor++;
      results[idx] = await fn(items[idx], idx);
    }
  }
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, worker));
  return results;
}

function toHex(n) { return '0x' + n.toString(16); }
function normHex(h, fallback = '0x0') { return (!h || h === '0x') ? fallback : h.toLowerCase(); }

async function main() {
  const opts = parseArgs(process.argv);
  const start = opts.start;
  const end = start + opts.count - 1;
  const preBlockTag = toHex(start - 1);

  console.error(`Fetching ${opts.count} Ethereum mainnet blocks: ${start}..${end} (pre-state at ${start - 1})`);

  // 1. Fetch 256 ancestor block hashes (for BLOCKHASH opcode)
  const ancestorNums = [];
  for (let b = Math.max(0, start - 256); b < start; b++) ancestorNums.push(b);
  const ancestorHashes = {};
  for (let i = 0; i < ancestorNums.length; i += 32) {
    const chunk = ancestorNums.slice(i, i + 32);
    const res = await rpcBatch(chunk.map((n) => ({ method: 'eth_getBlockByNumber', params: [toHex(n), false] })));
    for (let j = 0; j < chunk.length; j++) ancestorHashes[String(chunk[j])] = res[j].hash.toLowerCase();
  }
  console.error(`Fetched ${ancestorNums.length} ancestor block hashes.`);

  // 2. Fetch all 100 blocks (block + receipts + prestateTracer)
  const blockNums = Array.from({ length: opts.count }, (_, i) => start + i);
  let done = 0;
  const fetched = await mapLimit(blockNums, CONCURRENCY, async (bnum) => {
    const tag = toHex(bnum);
    const [blk, receipts, traces] = await Promise.all([
      rpc('eth_getBlockByNumber', [tag, true]),
      rpc('eth_getBlockReceipts', [tag]),
      rpc('debug_traceBlockByNumber', [tag, { tracer: 'prestateTracer' }]),
    ]);
    done++;
    if (done % 10 === 0 || done === opts.count) {
      console.error(`  fetched ${done}/${opts.count} blocks (latest #${bnum}, ${blk.transactions.length} txs)`);
    }
    return { bnum, blk, receipts, traces };
  });

  // 3. Collect first-touch pre-state with exact (first_block, first_tx) coordinates.
  const prestate = new Map();
  const codeToId = new Map();
  const codes = ['0x'];
  codeToId.set('0x', 0);

  function internCode(hex) {
    const norm = !hex || hex === '0x' ? '0x' : hex.toLowerCase();
    let id = codeToId.get(norm);
    if (id === undefined) {
      id = codes.length;
      codeToId.set(norm, id);
      codes.push(norm);
    }
    return id;
  }

  const externalTouchAddrs = new Set([
    '0x000f3df6d732807ef1319fb7b8bb8522d0beac02', // EIP-4788 beacon roots
    '0x0000f90827f1c53a10cb7a02335b175320002935', // EIP-2935 history storage
  ]);

  for (let bi = 0; bi < fetched.length; bi++) {
    const { blk, traces } = fetched[bi];
    externalTouchAddrs.add(blk.miner.toLowerCase());
    for (const w of blk.withdrawals || []) externalTouchAddrs.add(w.address.toLowerCase());
    for (let ti = 0; ti < traces.length; ti++) {
      const res = traces[ti].result || {};
      for (const [rawAddr, st] of Object.entries(res)) {
        const addr = rawAddr.toLowerCase();
        let acc = prestate.get(addr);
        if (!acc) {
          acc = {
            balance: normHex(st.balance, '0x0'),
            nonce: typeof st.nonce === 'number' ? st.nonce : (st.nonce ? parseInt(st.nonce, 16) : 0),
            code_id: internCode(st.code),
            first_block: bi,
            first_tx: ti,
            exact_pre_start: false,
            storage: new Map(), // slot -> { val, first_block, first_tx }
          };
          prestate.set(addr, acc);
        } else if (acc.code_id === 0 && st.code && st.code !== '0x') {
          acc.code_id = internCode(st.code);
        }
        if (st.storage) {
          for (const [slot, val] of Object.entries(st.storage)) {
            const sl = slot.toLowerCase();
            if (!acc.storage.has(sl)) {
              acc.storage.set(sl, { val: val.toLowerCase(), first_block: bi, first_tx: ti });
            }
          }
        }
      }
    }
  }

  // 4. Refresh exact pre-block-(start-1) state for coinbases, withdrawal recipients, and system contracts.
  const toRefresh = Array.from(externalTouchAddrs);
  console.error(`Refreshing exact pre-state at block #${start - 1} for ${toRefresh.length} coinbase/withdrawal/system accounts...`);
  for (let i = 0; i < toRefresh.length; i += 25) {
    const chunk = toRefresh.slice(i, i + 25);
    const calls = [];
    for (const a of chunk) {
      calls.push({ method: 'eth_getBalance', params: [a, preBlockTag] });
      calls.push({ method: 'eth_getTransactionCount', params: [a, preBlockTag] });
      calls.push({ method: 'eth_getCode', params: [a, preBlockTag] });
    }
    const res = await rpcBatch(calls);
    for (let j = 0; j < chunk.length; j++) {
      const a = chunk[j];
      const bal = normHex(res[j * 3], '0x0');
      const nonce = parseInt(res[j * 3 + 1], 16);
      const code = res[j * 3 + 2];
      let acc = prestate.get(a);
      if (!acc) {
        acc = { balance: bal, nonce, code_id: internCode(code), first_block: 0, first_tx: 0, exact_pre_start: true, storage: new Map() };
        prestate.set(a, acc);
      } else {
        acc.balance = bal;
        acc.nonce = nonce;
        acc.code_id = internCode(code);
        acc.first_block = 0;
        acc.first_tx = 0;
        acc.exact_pre_start = true;
      }
    }
  }

  // 5. Serialize compact benchmark bundle
  const accountsOut = [];
  for (const [address, acc] of prestate.entries()) {
    const storage = [];
    for (const [k, info] of acc.storage.entries()) {
      storage.push([k, info.val, info.first_block, info.first_tx]);
    }
    accountsOut.push({
      address,
      balance: acc.balance,
      nonce: acc.nonce,
      code_id: acc.code_id,
      first_block: acc.first_block,
      first_tx: acc.first_tx,
      exact_pre_start: acc.exact_pre_start,
      storage,
    });
  }

  let totalTxs = 0;
  let totalGasUsed = 0n;
  const blocksOut = fetched.map(({ blk, receipts }) => {
    const rcptByHash = new Map(receipts.map((r) => [r.transactionHash.toLowerCase(), r]));
    const txs = blk.transactions.map((tx) => {
      const r = rcptByHash.get(tx.hash.toLowerCase());
      const gasUsed = r ? parseInt(r.gasUsed, 16) : 0;
      const status = r && r.status !== undefined ? parseInt(r.status, 16) === 1 : true;
      totalTxs++;
      totalGasUsed += BigInt(gasUsed);
      return {
        type: tx.type ? parseInt(tx.type, 16) : 0,
        from: tx.from.toLowerCase(),
        to: tx.to ? tx.to.toLowerCase() : '',
        nonce: parseInt(tx.nonce, 16),
        gas: parseInt(tx.gas, 16),
        gas_price: normHex(tx.gasPrice, '0x0'),
        max_fee_per_gas: tx.maxFeePerGas ? normHex(tx.maxFeePerGas, '0x0') : '',
        max_priority_fee_per_gas: tx.maxPriorityFeePerGas ? normHex(tx.maxPriorityFeePerGas, '0x0') : '',
        max_fee_per_blob_gas: tx.maxFeePerBlobGas ? normHex(tx.maxFeePerBlobGas, '0x0') : '',
        value: normHex(tx.value, '0x0'),
        input: normHex(tx.input, '0x'),
        access_list: (tx.accessList || []).map((e) => ({
          address: e.address.toLowerCase(),
          storage_keys: (e.storageKeys || []).map((k) => k.toLowerCase()),
        })),
        blob_versioned_hashes: (tx.blobVersionedHashes || []).map((h) => h.toLowerCase()),
        authorization_list: (tx.authorizationList || []).map((a) => ({
          chain_id: normHex(a.chainId, '0x0'),
          address: a.address.toLowerCase(),
          nonce: parseInt(a.nonce, 16),
          y_parity: a.yParity !== undefined ? parseInt(a.yParity, 16) : parseInt(a.v || '0x0', 16),
          r: normHex(a.r, '0x0'),
          s: normHex(a.s, '0x0'),
        })),
        expected_gas_used: gasUsed,
        expected_status: status,
      };
    });
    return {
      number: parseInt(blk.number, 16),
      hash: blk.hash.toLowerCase(),
      parent_hash: blk.parentHash.toLowerCase(),
      timestamp: parseInt(blk.timestamp, 16),
      coinbase: blk.miner.toLowerCase(),
      gas_limit: parseInt(blk.gasLimit, 16),
      gas_used: parseInt(blk.gasUsed, 16),
      base_fee: normHex(blk.baseFeePerGas, '0x0'),
      prev_randao: normHex(blk.mixHash, '0x0'),
      excess_blob_gas: blk.excessBlobGas ? parseInt(blk.excessBlobGas, 16) : 0,
      blob_gas_used: blk.blobGasUsed ? parseInt(blk.blobGasUsed, 16) : 0,
      parent_beacon_block_root: blk.parentBeaconBlockRoot ? blk.parentBeaconBlockRoot.toLowerCase() : '',
      withdrawals: (blk.withdrawals || []).map((w) => ({
        address: w.address.toLowerCase(),
        amount_gwei: parseInt(w.amount, 16),
      })),
      transactions: txs,
    };
  });

  const bundle = {
    schema: 'guillotine-mainnet-blocks-v2',
    chain_id: 1,
    hardfork: 'OSAKA',
    start_block: start,
    end_block: end,
    block_count: opts.count,
    total_transactions: totalTxs,
    total_gas_used: Number(totalGasUsed),
    ancestor_hashes: ancestorHashes,
    codes,
    accounts: accountsOut,
    blocks: blocksOut,
  };

  mkdirSync(dirname(opts.out), { recursive: true });
  const jsonText = JSON.stringify(bundle);
  writeFileSync(opts.out, jsonText);
  const sha256 = createHash('sha256').update(jsonText).digest('hex');

  console.error(`Wrote ${opts.out} (${(jsonText.length / 1024 / 1024).toFixed(2)} MiB, sha256=${sha256.slice(0, 16)}...)`);
  console.error(`Summary: blocks=${start}..${end} (${opts.count}), txs=${totalTxs}, gas=${totalGasUsed}, accounts=${accountsOut.length}, unique_codes=${codes.length - 1}`);

  if (opts.manifest) {
    mkdirSync(dirname(opts.manifest), { recursive: true });
    const manifest = {
      schema: 'guillotine-mainnet-blocks-manifest-v1',
      chain_id: 1,
      hardfork: 'OSAKA',
      start_block: start,
      end_block: end,
      block_count: opts.count,
      first_block_hash: blocksOut[0].hash,
      last_block_hash: blocksOut[blocksOut.length - 1].hash,
      first_timestamp: blocksOut[0].timestamp,
      last_timestamp: blocksOut[blocksOut.length - 1].timestamp,
      total_transactions: totalTxs,
      total_gas_used: Number(totalGasUsed),
      prestate_accounts: accountsOut.length,
      unique_contracts: codes.length - 1,
      bundle_sha256: sha256,
    };
    writeFileSync(opts.manifest, JSON.stringify(manifest, null, 2) + '\n');
  }
}

main().catch((err) => { console.error(err); process.exit(1); });
