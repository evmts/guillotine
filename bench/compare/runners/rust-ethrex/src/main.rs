use bytes::Bytes;
use ethrex_common::{
    Address, H256, U256,
    types::{Account, AccountState, ChainConfig, Code, CodeMetadata, Fork, LegacyTransaction, Transaction, TxKind},
};
use ethrex_crypto::NativeCrypto;
use ethrex_levm::{
    Environment,
    db::{Database, gen_db::GeneralizedDatabase},
    environment::EVMConfig,
    errors::{DatabaseError, TxResult},
    tracing::LevmCallTracer,
    vm::{VM, VMType},
};
use rustc_hash::FxHashMap;
use serde::Deserialize;
use std::{env, fs, hint::black_box, sync::Arc, time::Instant};

#[derive(Deserialize)]
struct JsonBlock {
    number: String,
    timestamp: String,
    coinbase: String,
    basefee: String,
    prevrandao: String,
    gas_limit: String,
    chain_id: String,
}

#[derive(Deserialize)]
struct JsonAccount {
    address: String,
    balance: String,
    nonce: u64,
    code: String,
    storage: Vec<[String; 2]>,
}

#[derive(Deserialize)]
struct JsonTx {
    caller: String,
    to: String,
    value: String,
    input: String,
    gas_limit: String,
    gas_price: String,
    nonce: u64,
}

#[derive(Deserialize)]
struct JsonWorkload {
    name: String,
    hardfork: String,
    block: JsonBlock,
    accounts: Vec<JsonAccount>,
    tx: JsonTx,
}

struct Opts {
    workload: String,
    engine: String,
    mode: String,
    warmup: usize,
    min_samples: usize,
    max_samples: usize,
    target_ms: u64,
}

fn parse_args() -> Opts {
    let args: Vec<String> = env::args().collect();
    let mut opts = Opts {
        workload: String::new(),
        engine: "ethrex-levm".into(),
        mode: "warm".into(),
        warmup: 20,
        min_samples: 15,
        max_samples: 200,
        target_ms: 1500,
    };
    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--workload" => { i += 1; opts.workload = args[i].clone(); }
            "--engine" => { i += 1; opts.engine = args[i].clone(); }
            "--mode" => { i += 1; opts.mode = args[i].clone(); }
            "--warmup" => { i += 1; opts.warmup = args[i].parse().unwrap(); }
            "--min-samples" => { i += 1; opts.min_samples = args[i].parse().unwrap(); }
            "--max-samples" => { i += 1; opts.max_samples = args[i].parse().unwrap(); }
            "--target-ms" => { i += 1; opts.target_ms = args[i].parse().unwrap(); }
            other => panic!("unknown arg: {other}"),
        }
        i += 1;
    }
    assert!(!opts.workload.is_empty(), "--workload required");
    opts
}

fn trim_hex(s: &str) -> &str {
    s.trim().strip_prefix("0x").or_else(|| s.trim().strip_prefix("0X")).unwrap_or(s.trim())
}
fn parse_u64(s: &str) -> u64 {
    let h = trim_hex(s);
    if h.is_empty() { 0 } else { u64::from_str_radix(h, 16).unwrap() }
}
fn parse_u256(s: &str) -> U256 {
    let h = trim_hex(s);
    if h.is_empty() { U256::zero() } else { U256::from_str_radix(h, 16).unwrap() }
}
fn parse_addr(s: &str) -> Address {
    let bytes = hex::decode(trim_hex(s)).unwrap();
    let mut arr = [0u8; 20];
    let start = 20 - bytes.len();
    arr[start..].copy_from_slice(&bytes);
    Address::from(arr)
}
fn parse_h256(s: &str) -> H256 {
    let bytes = hex::decode(trim_hex(s)).unwrap();
    let mut arr = [0u8; 32];
    let start = 32 - bytes.len();
    arr[start..].copy_from_slice(&bytes);
    H256::from(arr)
}
fn parse_bytes(s: &str) -> Bytes {
    let h = trim_hex(s);
    if h.is_empty() { Bytes::new() } else { Bytes::from(hex::decode(h).unwrap()) }
}
fn parse_fork(s: &str) -> Fork {
    match s {
        "OSAKA" => Fork::Osaka,
        "PRAGUE" => Fork::Prague,
        "CANCUN" => Fork::Cancun,
        other => panic!("unsupported hardfork: {other}"),
    }
}

struct EmptyStore {
    chain_id: u64,
}
impl Database for EmptyStore {
    fn get_account_state(&self, _: Address) -> Result<AccountState, DatabaseError> {
        Ok(AccountState::default())
    }
    fn get_storage_value(&self, _: Address, _: H256) -> Result<U256, DatabaseError> {
        Ok(U256::zero())
    }
    fn get_block_hash(&self, _: u64) -> Result<H256, DatabaseError> {
        Ok(H256::zero())
    }
    fn get_chain_config(&self) -> Result<ChainConfig, DatabaseError> {
        Ok(ChainConfig { chain_id: self.chain_id, ..Default::default() })
    }
    fn get_account_code(&self, _: H256) -> Result<Code, DatabaseError> {
        Ok(Code::default())
    }
    fn get_code_metadata(&self, _: H256) -> Result<CodeMetadata, DatabaseError> {
        Ok(CodeMetadata { length: 0 })
    }
}

fn build_cache(w: &JsonWorkload) -> FxHashMap<Address, Account> {
    let mut cache = FxHashMap::default();
    for acc in &w.accounts {
        let addr = parse_addr(&acc.address);
        let code_bytes = parse_bytes(&acc.code);
        let code = Code::from_bytecode(code_bytes, &NativeCrypto);
        let mut storage = FxHashMap::default();
        for [k, v] in &acc.storage {
            storage.insert(parse_h256(k), parse_u256(v));
        }
        cache.insert(addr, Account::new(parse_u256(&acc.balance), code, acc.nonce, storage));
    }
    cache
}

fn emit_failure(opts: &Opts, w: &JsonWorkload, gas_used: u64, reason: &str) {
    println!(
        "{{\"engine\":\"{}\",\"workload\":\"{}\",\"mode\":\"{}\",\"status\":\"failed\",\"hardfork\":\"{}\",\"success\":false,\"gas_used\":{},\"reason\":\"{}\"}}",
        opts.engine, w.name, opts.mode, w.hardfork, gas_used, reason
    );
}

fn emit_success(opts: &Opts, w: &JsonWorkload, gas_used: u64, output: &[u8], warmup_runs: usize, samples: &[u64]) {
    let mut sorted = samples.to_vec();
    sorted.sort_unstable();
    let n = sorted.len();
    let median_ns = if n % 2 == 1 { sorted[n / 2] as f64 } else { (sorted[n / 2 - 1] as f64 + sorted[n / 2] as f64) / 2.0 };
    let sum: u128 = sorted.iter().map(|&v| v as u128).sum();
    let mean_ns = sum as f64 / n as f64;
    let min_ns = sorted[0] as f64;
    let max_ns = sorted[n - 1] as f64;
    let p25_ns = sorted[n / 4] as f64;
    let p75_ns = sorted[(n * 3) / 4] as f64;
    let iqr_ns = p75_ns - p25_ns;
    let p95_idx = ((n * 95 + 99) / 100).saturating_sub(1).min(n - 1);
    let p95_ns = sorted[p95_idx] as f64;
    let mgas_per_sec = if median_ns > 0.0 { (gas_used as f64 * 1000.0) / median_ns } else { 0.0 };
    let samples_str: Vec<String> = samples.iter().map(|v| v.to_string()).collect();
    println!(
        "{{\"engine\":\"{}\",\"workload\":\"{}\",\"mode\":\"{}\",\"status\":\"ok\",\"hardfork\":\"{}\",\"success\":true,\"gas_used\":{},\"output_hex\":\"0x{}\",\"jit_compiled\":false,\"compile_ns\":null,\"warmup_runs\":{},\"sample_count\":{},\"median_ns\":{:.2},\"mean_ns\":{:.2},\"min_ns\":{:.2},\"max_ns\":{:.2},\"p25_ns\":{:.2},\"p75_ns\":{:.2},\"iqr_ns\":{:.2},\"p95_ns\":{:.2},\"mgas_per_sec\":{:.2},\"samples_ns\":[{}]}}",
        opts.engine, w.name, opts.mode, w.hardfork, gas_used, hex::encode(output), warmup_runs, n,
        median_ns, mean_ns, min_ns, max_ns, p25_ns, p75_ns, iqr_ns, p95_ns, mgas_per_sec, samples_str.join(",")
    );
}

fn main() {
    let opts = parse_args();
    let content = fs::read_to_string(&opts.workload).expect("read workload json");
    let w: JsonWorkload = serde_json::from_str(&content).expect("parse workload json");
    let fork = parse_fork(&w.hardfork);
    let is_cold = opts.mode == "cold";

    let chain_id = parse_u64(&w.block.chain_id);
    let store: Arc<dyn Database> = Arc::new(EmptyStore { chain_id });
    let env = Environment {
        origin: parse_addr(&w.tx.caller),
        gas_limit: parse_u64(&w.tx.gas_limit),
        config: EVMConfig::new(fork, Default::default()),
        block_number: parse_u64(&w.block.number),
        coinbase: parse_addr(&w.block.coinbase),
        timestamp: parse_u64(&w.block.timestamp),
        prev_randao: Some(parse_h256(&w.block.prevrandao)),
        difficulty: U256::zero(),
        chain_id: U256::from(chain_id),
        base_fee_per_gas: parse_u256(&w.block.basefee),
        gas_price: parse_u256(&w.tx.gas_price),
        tx_nonce: w.tx.nonce,
        block_gas_limit: parse_u64(&w.block.gas_limit),
        ..Default::default()
    };
    let tx = Transaction::LegacyTransaction(LegacyTransaction {
        nonce: w.tx.nonce,
        gas_price: parse_u256(&w.tx.gas_price),
        gas: parse_u64(&w.tx.gas_limit),
        to: TxKind::Call(parse_addr(&w.tx.to)),
        value: parse_u256(&w.tx.value),
        data: parse_bytes(&w.tx.input),
        ..Default::default()
    });

    let mut warm_db = GeneralizedDatabase::new_with_account_state(Arc::clone(&store), build_cache(&w));

    let mut run_once = |cold: bool| -> Result<(bool, u64, Vec<u8>, u64), String> {
        if cold {
            let t0 = Instant::now();
            let mut db = GeneralizedDatabase::new_with_account_state(Arc::clone(&store), build_cache(&w));
            let mut vm = VM::new(env.clone(), &mut db, &tx, LevmCallTracer::disabled(), VMType::L1, &NativeCrypto, None)
                .map_err(|e| format!("{e:?}"))?;
            let report = black_box(vm.stateless_execute()).map_err(|e| format!("{e:?}"))?;
            let dt = t0.elapsed().as_nanos() as u64;
            let ok = matches!(report.result, TxResult::Success);
            Ok((ok, report.gas_used, report.output.to_vec(), dt))
        } else {
            let t0 = Instant::now();
            let mut vm = VM::new(env.clone(), &mut warm_db, &tx, LevmCallTracer::disabled(), VMType::L1, &NativeCrypto, None)
                .map_err(|e| format!("{e:?}"))?;
            let report = black_box(vm.stateless_execute()).map_err(|e| format!("{e:?}"))?;
            let dt = t0.elapsed().as_nanos() as u64;
            let ok = matches!(report.result, TxResult::Success);
            Ok((ok, report.gas_used, report.output.to_vec(), dt))
        }
    };

    let (ok, ref_gas, ref_out, preflight_ns) = match run_once(is_cold) {
        Ok(v) => v,
        Err(e) => {
            emit_failure(&opts, &w, 0, &e);
            return;
        }
    };
    if !ok {
        emit_failure(&opts, &w, ref_gas, "preflight reverted or halted");
        return;
    }

    let budget_warmup = if preflight_ns > 0 {
        opts.warmup.min((500_000_000 / preflight_ns.max(1)) as usize).max(2)
    } else {
        opts.warmup
    };
    for _ in 0..budget_warmup {
        let (ok, gas, out, _) = run_once(is_cold).expect("warmup");
        if !ok || gas != ref_gas || out != ref_out {
            emit_failure(&opts, &w, gas, "warmup non-determinism");
            return;
        }
    }

    let mut samples = Vec::with_capacity(opts.max_samples);
    let target_ns = opts.target_ms * 1_000_000;
    let mut elapsed_ns: u64 = 0;
    while samples.len() < opts.max_samples {
        if samples.len() >= opts.min_samples && elapsed_ns >= target_ns {
            break;
        }
        let (ok, gas, out, dt) = run_once(is_cold).expect("sample");
        if !ok || gas != ref_gas || out != ref_out {
            emit_failure(&opts, &w, gas, "sample non-determinism");
            return;
        }
        samples.push(dt);
        elapsed_ns += dt;
    }

    emit_success(&opts, &w, ref_gas, &ref_out, budget_warmup, &samples);
}
