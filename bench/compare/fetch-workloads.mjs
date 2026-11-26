#!/usr/bin/env node
/**
 * Fetches pinned public Ethereum StateTest fixtures from alloy-rs/evm2
 * and generates targeted EVM hot-loop workloads into bench/compare/workloads/.
 *
 * All workloads are normalized into a single flat canonical JSON schema so
 * every EVM runner (Zig, Rust, C++, Go) parses the exact same inputs.
 */

import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";

const ROOT = path.resolve(import.meta.dirname);
const WORKLOADS_DIR = path.join(ROOT, "workloads");
const CACHE_DIR = path.join(ROOT, ".cache", "evm2-data");
const EVM2_REV = "e80df9c46a82";

fs.mkdirSync(WORKLOADS_DIR, { recursive: true });
fs.mkdirSync(CACHE_DIR, { recursive: true });

function fetchEvm2Fixture(filename) {
  const cached = path.join(CACHE_DIR, filename);
  if (fs.existsSync(cached)) {
    return JSON.parse(fs.readFileSync(cached, "utf8"));
  }
  const url = `https://raw.githubusercontent.com/alloy-rs/evm2/${EVM2_REV}/data/${filename}`;
  const content = execFileSync("curl", ["-fsSL", url], {
    encoding: "utf8",
    maxBuffer: 64 * 1024 * 1024,
  });
  fs.writeFileSync(cached, content);
  return JSON.parse(content);
}

function normHex(v, fallback = "0x0") {
  if (v === undefined || v === null || v === "") return fallback;
  const s = String(v).trim();
  if (s === "0x" || s === "0X") return "0x";
  return s.startsWith("0x") || s.startsWith("0X") ? "0x" + s.slice(2).toLowerCase() : "0x" + BigInt(s).toString(16);
}

function normHexQuantity(v, fallback = "0x0") {
  const h = normHex(v, fallback);
  if (h === "0x") return "0x0";
  return "0x" + BigInt(h).toString(16);
}

function normAddress(v) {
  const h = normHex(v, "0x0").slice(2);
  return "0x" + h.padStart(40, "0");
}

function normBytes32(v) {
  const h = normHex(v, "0x0").slice(2);
  return "0x" + h.padStart(64, "0");
}

function normBytes(v) {
  if (!v || v === "0x" || v === "0X") return "0x";
  let h = String(v).trim();
  if (h.startsWith("0x") || h.startsWith("0X")) h = h.slice(2);
  if (h.length % 2 !== 0) h = "0" + h;
  return "0x" + h.toLowerCase();
}

function normalizeStateTest({ name, category, description, filename, caseKey, hardforkOverride, jitEligible = true }) {
  const raw = fetchEvm2Fixture(filename);
  const keys = Object.keys(raw);
  const selectedKey = caseKey && raw[caseKey] ? caseKey : keys[0];
  const unit = raw[selectedKey];
  if (!unit) throw new Error(`Missing case ${selectedKey} in ${filename}`);

  const postKeys = Object.keys(unit.post || {});
  const specName = hardforkOverride || (postKeys[0] ? postKeys[0].toUpperCase() : "OSAKA");
  const postEntry = unit.post?.[postKeys[0]]?.[0];
  const indexes = postEntry?.indexes || { data: 0, gas: 0, value: 0 };

  const env = unit.env || {};
  const tx = unit.transaction || {};
  const dataList = Array.isArray(tx.data) ? tx.data : [tx.data ?? "0x"];
  const gasList = Array.isArray(tx.gasLimit) ? tx.gasLimit : [tx.gasLimit ?? "0x1000000"];
  const valueList = Array.isArray(tx.value) ? tx.value : [tx.value ?? "0x0"];

  const txGasLimitBig = BigInt(normHexQuantity(gasList[indexes.gas] ?? gasList[0]));
  // Cap absurd i64::MAX gas limits to 1_000_000_000 (1B) on pre-Osaka forks if needed
  // while preserving exact gas limit for Osaka (<= 16,777,216).
  const maxGas = specName === "OSAKA" ? 16_777_216n : 1_000_000_000n;
  const effectiveGasLimit = txGasLimitBig > maxGas ? maxGas : txGasLimitBig;

  const accounts = Object.entries(unit.pre || {})
    .sort(([a], [b]) => normAddress(a).localeCompare(normAddress(b)))
    .map(([addr, acc]) => ({
      address: normAddress(addr),
      balance: normHexQuantity(acc.balance, "0x0"),
      nonce: Number(BigInt(normHexQuantity(acc.nonce, "0x0"))),
      code: normBytes(acc.code),
      storage: Object.entries(acc.storage || {})
        .sort(([a], [b]) => normBytes32(a).localeCompare(normBytes32(b)))
        .map(([k, v]) => [normBytes32(k), normBytes32(v)]),
    }));

  // Access list support (if present in transaction.accessLists)
  const accessListRaw = Array.isArray(tx.accessLists) ? tx.accessLists[indexes.data] || [] : [];
  const access_list = (accessListRaw || []).map((entry) => ({
    address: normAddress(entry.address),
    storage_keys: (entry.storageKeys || []).map(normBytes32),
  }));

  return {
    name,
    category,
    source: `alloy-rs/evm2@${EVM2_REV}:data/${filename}#${selectedKey}`,
    description,
    hardfork: specName,
    jit_eligible: jitEligible,
    block: {
      number: normHexQuantity(env.currentNumber, "0x1"),
      timestamp: normHexQuantity(env.currentTimestamp, "0x1"),
      coinbase: normAddress(env.currentCoinbase || "0x0"),
      basefee: normHexQuantity(env.currentBaseFee, "0x0"),
      prevrandao: normBytes32(env.currentRandom || env.currentDifficulty || "0x0"),
      gas_limit: normHexQuantity(env.currentGasLimit, "0x7fffffffffffffff"),
      chain_id: normHexQuantity(env.currentChainId, "0x1"),
    },
    accounts,
    tx: {
      caller: normAddress(tx.sender),
      to: normAddress(tx.to),
      value: normHexQuantity(valueList[indexes.value] ?? valueList[0], "0x0"),
      input: normBytes(dataList[indexes.data] ?? dataList[0]),
      gas_limit: "0x" + effectiveGasLimit.toString(16),
      gas_price: normHexQuantity(tx.gasPrice || tx.maxFeePerGas, "0x0"),
      nonce: Number(BigInt(normHexQuantity(tx.nonce, "0x0"))),
      access_list,
    },
  };
}

// --- Tiny deterministic EVM assembler for targeted hot-loop workloads ---
class Asm {
  constructor() {
    this.bytes = [];
  }
  op(b) {
    this.bytes.push(b & 0xff);
  }
  raw(arr) {
    for (const b of arr) this.bytes.push(b & 0xff);
  }
  push(val) {
    let v = BigInt(val);
    if (v === 0n) {
      this.op(0x5f); // PUSH0 (Shanghai+)
      return;
    }
    const hex = v.toString(16);
    const padded = hex.length % 2 === 0 ? hex : "0" + hex;
    const n = padded.length / 2;
    this.op(0x5f + n);
    for (let i = 0; i < n; i++) {
      this.bytes.push(parseInt(padded.slice(i * 2, i * 2 + 2), 16));
    }
  }
  label() {
    const pc = this.bytes.length;
    this.op(0x5b); // JUMPDEST
    return pc;
  }
  toHex() {
    return "0x" + Buffer.from(this.bytes).toString("hex");
  }
}

function makeLoopWorkload({ name, description, codeHex, extraAccounts = [], storage = [], jitEligible = false }) {
  const caller = "0x1111111111111111111111111111111111111111";
  const target = "0xcccccccccccccccccccccccccccccccccccccccc";
  return {
    name,
    category: "opcode",
    source: "guillotine/bench/compare (synthetic hot-loop)",
    description,
    hardfork: "OSAKA",
    jit_eligible: jitEligible,
    block: {
      number: "0x1",
      timestamp: "0x1",
      coinbase: "0x0000000000000000000000000000000000000000",
      basefee: "0x0",
      prevrandao: "0x0000000000000000000000000000000000000000000000000000000000000000",
      gas_limit: "0x7fffffffffffffff",
      chain_id: "0x1",
    },
    accounts: [
      {
        address: caller,
        balance: "0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
        nonce: 0,
        code: "0x",
        storage: [],
      },
      {
        address: target,
        balance: "0x0",
        nonce: 1,
        code: codeHex,
        storage,
      },
      ...extraAccounts,
    ],
    tx: {
      caller,
      to: target,
      value: "0x0",
      input: "0x",
      gas_limit: "0x1000000",
      gas_price: "0x0",
      nonce: 0,
      access_list: [],
    },
  };
}

function buildArithmeticLoop() {
  // 2048 iterations of ADD + MUL + DIV + MOD + XOR (pure compute, JIT-eligible)
  const a = new Asm();
  a.push(0x123456789abcdef0123456789abcdef0n); // acc
  a.push(2048); // i
  const loop = a.label();
  // stack: [acc, i]
  a.op(0x81); // DUP2 (acc)
  a.push(0x9e3779b97f4a7c15n);
  a.op(0x02); // MUL
  a.push(0x10000000000000001n);
  a.op(0x01); // ADD
  a.op(0x80); // DUP1
  a.push(97);
  a.op(0x90); // SWAP1
  a.op(0x04); // DIV (acc / 97)
  a.op(0x18); // XOR
  a.op(0x91); // SWAP2 -> [new_acc, i, old_acc]
  a.op(0x50); // POP old_acc -> [new_acc, i]
  a.push(1);
  a.op(0x90); // SWAP1 -> [new_acc, 1, i]
  a.op(0x03); // SUB -> [new_acc, i-1]
  a.op(0x80); // DUP1
  a.push(loop);
  a.op(0x57); // JUMPI
  a.op(0x50); // POP 0
  a.push(0);
  a.op(0x52); // MSTORE
  a.push(32);
  a.push(0);
  a.op(0xf3); // RETURN
  return makeLoopWorkload({
    name: "loop_arithmetic",
    description: "2,048-iteration tight arithmetic loop (MUL, ADD, DIV, XOR, JUMPI)",
    codeHex: a.toHex(),
    jitEligible: true,
  });
}

function buildMemoryLoop() {
  // 2048 iterations of MSTORE, MLOAD, MCOPY across 1 KiB working set (JIT-eligible)
  const a = new Asm();
  a.push(0xdeadbeefcafebabe1234567890abcdef0123456789abcdef0123456789abcdefn);
  a.push(0);
  a.op(0x52); // MSTORE(0, seed)
  a.push(2048); // i
  const loop = a.label();
  // MCOPY 64 bytes from 0 -> 64, then MLOAD 64, XOR with i, MSTORE 0
  a.push(64); // size
  a.push(0); // src
  a.push(64); // dst
  a.op(0x5e); // MCOPY
  a.push(64);
  a.op(0x51); // MLOAD(64)
  a.op(0x81); // DUP2 (i)
  a.op(0x18); // XOR
  a.push(0);
  a.op(0x52); // MSTORE(0, val)
  a.push(1);
  a.op(0x90);
  a.op(0x03); // i - 1
  a.op(0x80);
  a.push(loop);
  a.op(0x57);
  a.op(0x50);
  a.push(32);
  a.push(0);
  a.op(0xf3);
  return makeLoopWorkload({
    name: "loop_memory",
    description: "2,048-iteration memory hot loop (MCOPY, MLOAD, MSTORE)",
    codeHex: a.toHex(),
    jitEligible: true,
  });
}

function buildStorageLoop() {
  // 128 cold SLOADs + 512 warm SLOAD/SSTORE cycles (tests state DB & EIP-2929 access list)
  const a = new Asm();
  a.push(0); // acc
  a.push(128); // i = 128..1
  const coldLoop = a.label();
  a.op(0x80); // DUP1 (i)
  a.op(0x54); // SLOAD(i)
  a.op(0x91); // SWAP2 -> [val, i, acc]
  a.op(0x01); // ADD? wait: [val, i, acc] -> SWAP1 -> [val, acc, i] -> wait
  // Let's keep stack super clean: [acc, i]
  const clean = new Asm();
  clean.push(0); // acc
  clean.push(128); // i
  const l1 = clean.label();
  // [acc, i]
  clean.op(0x80); // [acc, i, i]
  clean.op(0x54); // [acc, i, val]
  clean.op(0x90); // [acc, val, i]
  clean.op(0x91); // [i, val, acc]
  clean.op(0x01); // [i, acc']
  clean.op(0x90); // [acc', i]
  clean.push(1);
  clean.op(0x90);
  clean.op(0x03); // [acc', i-1]
  clean.op(0x80);
  clean.push(l1);
  clean.op(0x57);
  clean.op(0x50); // [acc']
  // Now 512 warm SLOAD + SSTORE on slot 1
  clean.push(512);
  const l2 = clean.label();
  // [acc, j]
  clean.push(1);
  clean.op(0x54); // [acc, j, s1]
  clean.push(1);
  clean.op(0x01); // [acc, j, s1+1]
  clean.op(0x80); // [acc, j, s1+1, s1+1]
  clean.push(1);
  clean.op(0x55); // SSTORE(1, s1+1) -> [acc, j, s1+1]
  clean.op(0x90); // [acc, s1+1, j]
  clean.op(0x91); // [j, s1+1, acc]
  clean.op(0x01); // [j, acc']
  clean.op(0x90); // [acc', j]
  clean.push(1);
  clean.op(0x90);
  clean.op(0x03);
  clean.op(0x80);
  clean.push(l2);
  clean.op(0x57);
  clean.op(0x50); // [acc']
  clean.push(0);
  clean.op(0x52);
  clean.push(32);
  clean.push(0);
  clean.op(0xf3);

  const storage = [];
  for (let i = 1; i <= 128; i++) {
    storage.push([normBytes32("0x" + i.toString(16)), normBytes32("0x" + (i * 7).toString(16))]);
  }
  return makeLoopWorkload({
    name: "loop_storage",
    description: "128 cold SLOADs + 512 warm SLOAD/SSTORE mutations",
    codeHex: clean.toHex(),
    storage,
    jitEligible: false,
  });
}

function buildStaticcallLoop() {
  // 256 nested STATICCALLs to a child contract returning 42
  const childAddr = "0x2222222222222222222222222222222222222222";
  // Child: PUSH1 42, PUSH0, MSTORE, PUSH1 32, PUSH0, RETURN
  const child = new Asm();
  child.push(42);
  child.push(0);
  child.op(0x52);
  child.push(32);
  child.push(0);
  child.op(0xf3);

  const a = new Asm();
  a.push(0); // acc
  a.push(256); // i
  const loop = a.label();
  // [acc, i]
  // STATICCALL(gas=50000, addr=childAddr, argsOffset=0, argsSize=0, retOffset=0, retSize=32)
  a.push(32);
  a.push(0);
  a.push(0);
  a.push(0);
  a.push(BigInt(childAddr));
  a.push(50000);
  a.op(0xfa); // STATICCALL -> [acc, i, ok]
  a.op(0x50); // POP ok
  a.push(0);
  a.op(0x51); // MLOAD(0) -> 42
  a.op(0x90); // [acc, 42, i]
  a.op(0x91); // [i, 42, acc]
  a.op(0x01); // [i, acc+42]
  a.op(0x90); // [acc+42, i]
  a.push(1);
  a.op(0x90);
  a.op(0x03); // i - 1
  a.op(0x80);
  a.push(loop);
  a.op(0x57);
  a.op(0x50);
  a.push(0);
  a.op(0x52);
  a.push(32);
  a.push(0);
  a.op(0xf3);

  return makeLoopWorkload({
    name: "loop_staticcall",
    description: "256 nested STATICCALL frames to child contract returning 42",
    codeHex: a.toHex(),
    extraAccounts: [
      {
        address: childAddr,
        balance: "0x0",
        nonce: 1,
        code: child.toHex(),
        storage: [],
      },
    ],
    jitEligible: false,
  });
}

const SPECS = [
  // Category 1: Classic Compute & Token Benchmarks (from alloy-rs/evm2)
  { name: "snailtracer", category: "classic", filename: "snailtracer.json", description: "Snailtracer ray-tracing compute benchmark (~235M gas, Cancun)", hardforkOverride: "CANCUN", jitEligible: true },
  { name: "erc20_transfer", category: "classic", filename: "erc20_transfer.json", description: "5,000 sequential ERC20 transfers (storage + logs)", hardforkOverride: "OSAKA", jitEligible: false },
  { name: "hash_10k", category: "classic", filename: "hash_10k.json", description: "10,000 sequential Keccak256 hashes", hardforkOverride: "OSAKA", jitEligible: true },
  { name: "fibonacci", category: "classic", filename: "fibonacci-calldata.json", description: "Fibonacci computation via calldata", hardforkOverride: "OSAKA", jitEligible: true },
  { name: "factorial", category: "classic", filename: "factorial.json", description: "Iterative factorial loop", hardforkOverride: "OSAKA", jitEligible: true },
  { name: "bswap64", category: "classic", filename: "bswap64.json", description: "64-bit byte-swap bitwise stress test", hardforkOverride: "OSAKA", jitEligible: true },
  { name: "counter", category: "classic", filename: "counter.json", description: "Minimal counter increment (measures baseline per-tx overhead)", hardforkOverride: "OSAKA", jitEligible: false },

  // Category 2: Real Mainnet DeFi & Production Contracts (from alloy-rs/evm2)
  { name: "weth", category: "mainnet", filename: "weth.json", description: "Mainnet WETH9 contract call", hardforkOverride: "OSAKA", jitEligible: false },
  { name: "usdc_proxy", category: "mainnet", filename: "usdc_proxy.json", description: "Mainnet USDC proxy (DELEGATECALL + storage)", hardforkOverride: "OSAKA", jitEligible: false },
  { name: "fiat_token", category: "mainnet", filename: "fiat_token.json", description: "Mainnet USDC FiatTokenV2 execution", hardforkOverride: "OSAKA", jitEligible: false },
  { name: "uniswap_v2_pair", category: "mainnet", filename: "uniswap_v2_pair.json", description: "Mainnet Uniswap V2 pair execution", hardforkOverride: "OSAKA", jitEligible: false },
  { name: "uniswap_v3_pool", category: "mainnet", filename: "uniswap_v3_pool.json", description: "Mainnet Uniswap V3 pool execution", hardforkOverride: "OSAKA", jitEligible: false },
  { name: "seaport", category: "mainnet", filename: "seaport.json", description: "Mainnet OpenSea Seaport large-bytecode call (cold vs warm test)", hardforkOverride: "OSAKA", jitEligible: false },
  { name: "curve_stableswap", category: "mainnet", filename: "curve-stableswap-2pool.json", description: "Curve StableSwap 2pool math (Cancun)", hardforkOverride: "CANCUN", jitEligible: false },
  { name: "burntpix", category: "mainnet", filename: "burntpix.json", description: "BurntPix heavy on-chain pixel/SVG generation (Cancun)", hardforkOverride: "CANCUN", jitEligible: true },
  { name: "push0_proxy", category: "mainnet", filename: "push0_proxy.json", description: "Minimal PUSH0 proxy delegatecall", hardforkOverride: "OSAKA", jitEligible: false },

  // Category 3: Precompiles (from alloy-rs/evm2)
  { name: "precompile_ecrecover", category: "precompile", filename: "precompile-ecrecover.json", caseKey: "precompile/ecrecover", description: "ECRECOVER (0x01) secp256k1 signature recovery", hardforkOverride: "OSAKA", jitEligible: false },
  { name: "precompile_sha256", category: "precompile", filename: "precompile-sha256.json", caseKey: "precompile/sha256/size_1024", description: "SHA256 (0x02) 1 KiB cryptographic hash precompile", hardforkOverride: "OSAKA", jitEligible: false },
  { name: "precompile_modexp", category: "precompile", filename: "precompile-modexp.json", caseKey: "precompile/modexp/mod_odd_256b_exp_1024", description: "MODEXP (0x05) 256-byte odd modulus, 1024-bit exponent", hardforkOverride: "OSAKA", jitEligible: false },
  { name: "precompile_bn254_pairing", category: "precompile", filename: "precompile-bn254.json", caseKey: "precompile/bn254/pairing", description: "BN254 (0x08) elliptic curve pairing check", hardforkOverride: "OSAKA", jitEligible: false },
  { name: "precompile_bls12_381", category: "precompile", filename: "precompile-bls12-381.json", caseKey: "precompile/bls12_381/g1_add", description: "BLS12-381 (0x0b) G1 point addition (EIP-2537)", hardforkOverride: "OSAKA", jitEligible: false },
];

const manifest = {
  schema_version: 1,
  evm2_fixture_rev: EVM2_REV,
  workloads: [],
};

for (const spec of SPECS) {
  const w = normalizeStateTest(spec);
  const outPath = path.join(WORKLOADS_DIR, `${w.name}.json`);
  fs.writeFileSync(outPath, JSON.stringify(w, null, 2) + "\n");
  manifest.workloads.push({
    name: w.name,
    category: w.category,
    hardfork: w.hardfork,
    jit_eligible: w.jit_eligible,
    source: w.source,
    description: w.description,
    file: `${w.name}.json`,
  });
  console.log(`  [ok] ${w.category.padEnd(10)} ${w.name.padEnd(22)} (${w.hardfork}, ${w.accounts.length} accts, gas=${BigInt(w.tx.gas_limit)})`);
}

for (const w of [buildArithmeticLoop(), buildMemoryLoop(), buildStorageLoop(), buildStaticcallLoop()]) {
  const outPath = path.join(WORKLOADS_DIR, `${w.name}.json`);
  fs.writeFileSync(outPath, JSON.stringify(w, null, 2) + "\n");
  manifest.workloads.push({
    name: w.name,
    category: w.category,
    hardfork: w.hardfork,
    jit_eligible: w.jit_eligible,
    source: w.source,
    description: w.description,
    file: `${w.name}.json`,
  });
  console.log(`  [ok] ${w.category.padEnd(10)} ${w.name.padEnd(22)} (${w.hardfork}, ${w.accounts.length} accts, gas=${BigInt(w.tx.gas_limit)})`);
}

fs.writeFileSync(path.join(WORKLOADS_DIR, "manifest.json"), JSON.stringify(manifest, null, 2) + "\n");
console.log(`\nWrote ${manifest.workloads.length} canonical workloads to ${WORKLOADS_DIR}`);
