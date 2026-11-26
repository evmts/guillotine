use revm::{
    ExecuteEvm, MainBuilder, MainContext,
    context::{BlockEnv, CfgEnv, Context, TxEnv},
    context_interface::result::ExecutionResult,
    database::{CacheDB, InMemoryDB},
    primitives::{Address, B256, Bytes, TxKind, U256, hardfork::SpecId, map::B256Map},
    state::{AccountInfo, Bytecode},
};
use revmc::{EvmCompiler, OptimizationLevel};
use revmc_builtins as _;
use revmc_context::{JitEvm, RawEvmCompilerFn};
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
        engine: "revmc".into(),
        mode: "jit".into(),
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
fn parse_u128(s: &str) -> u128 {
    let h = trim_hex(s);
    if h.is_empty() { 0 } else { u128::from_str_radix(h, 16).unwrap() }
}
fn parse_u256(s: &str) -> U256 {
    let h = trim_hex(s);
    if h.is_empty() { U256::ZERO } else { U256::from_str_radix(h, 16).unwrap() }
}
fn parse_addr(s: &str) -> Address { s.parse().unwrap() }
fn parse_b256(s: &str) -> B256 { s.parse().unwrap() }
fn parse_bytes(s: &str) -> Bytes {
    let h = trim_hex(s);
    if h.is_empty() { Bytes::new() } else { Bytes::from(hex::decode(h).unwrap()) }
}
fn parse_spec(s: &str) -> SpecId {
    match s {
        "OSAKA" => SpecId::OSAKA,
        "PRAGUE" => SpecId::PRAGUE,
        "CANCUN" => SpecId::CANCUN,
        other => panic!("unsupported hardfork: {other}"),
    }
}

fn emit_failure(opts: &Opts, w: &JsonWorkload, gas_used: u64, reason: &str) {
    println!(
        "{{\"engine\":\"{}\",\"workload\":\"{}\",\"mode\":\"{}\",\"status\":\"failed\",\"hardfork\":\"{}\",\"success\":false,\"gas_used\":{},\"reason\":\"{}\"}}",
        opts.engine, w.name, opts.mode, w.hardfork, gas_used, reason
    );
}

fn emit_success(
    opts: &Opts,
    w: &JsonWorkload,
    gas_used: u64,
    output: &[u8],
    warmup_runs: usize,
    samples: &[u64],
    compile_ns: Option<u64>,
    jit_compiled: bool,
) {
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
    let compile_json = match compile_ns { Some(v) => v.to_string(), None => "null".to_string() };
    let samples_str: Vec<String> = samples.iter().map(|v| v.to_string()).collect();
    println!(
        "{{\"engine\":\"{}\",\"workload\":\"{}\",\"mode\":\"{}\",\"status\":\"ok\",\"hardfork\":\"{}\",\"success\":true,\"gas_used\":{},\"output_hex\":\"0x{}\",\"jit_compiled\":{},\"compile_ns\":{},\"warmup_runs\":{},\"sample_count\":{},\"median_ns\":{:.2},\"mean_ns\":{:.2},\"min_ns\":{:.2},\"max_ns\":{:.2},\"p25_ns\":{:.2},\"p75_ns\":{:.2},\"iqr_ns\":{:.2},\"p95_ns\":{:.2},\"mgas_per_sec\":{:.2},\"samples_ns\":[{}]}}",
        opts.engine, w.name, opts.mode, w.hardfork, gas_used, hex::encode(output), jit_compiled, compile_json,
        warmup_runs, n, median_ns, mean_ns, min_ns, max_ns, p25_ns, p75_ns, iqr_ns, p95_ns, mgas_per_sec, samples_str.join(",")
    );
}

fn main() {
    let opts = parse_args();
    let content = fs::read_to_string(&opts.workload).expect("read workload json");
    let w: JsonWorkload = serde_json::from_str(&content).expect("parse workload json");
    let spec = parse_spec(&w.hardfork);

    let mut db = InMemoryDB::default();
    let mut compiler = EvmCompiler::new_llvm(false).expect("revmc LLVM init");
    compiler.set_opt_level(OptimizationLevel::Default);
    let mut functions: B256Map<RawEvmCompilerFn> = B256Map::default();

    let t_compile = Instant::now();
    for acc in &w.accounts {
        let addr = parse_addr(&acc.address);
        let code = parse_bytes(&acc.code);
        let bytecode = if code.is_empty() { Bytecode::default() } else { Bytecode::new_legacy(code.clone()) };
        let hash = bytecode.hash_slow();
        if !code.is_empty() && !functions.contains_key(&hash) {
            let name = format!("revmc_{hash:x}_{spec:?}");
            let f = unsafe { compiler.jit(&name, code.as_ref(), spec).expect("revmc jit compile") };
            compiler.clear_ir().expect("clear ir");
            functions.insert(hash, f.into_inner());
        }
        let info = AccountInfo::new(parse_u256(&acc.balance), acc.nonce, hash, bytecode);
        db.insert_account_info(addr, info);
        for [k, v] in &acc.storage {
            db.insert_account_storage(addr, parse_u256(k), parse_u256(v)).unwrap();
        }
    }
    let jit_compiled = !functions.is_empty();
    let compile_ns = if jit_compiled { Some(t_compile.elapsed().as_nanos() as u64) } else { None };
    let base_db = Arc::new(db);

    let mut cfg = CfgEnv::new();
    cfg.set_spec_and_mainnet_gas_params(spec);
    cfg = cfg.disable_tx_chain_id_check();
    cfg.chain_id = parse_u64(&w.block.chain_id);

    let block = BlockEnv {
        number: U256::from(parse_u64(&w.block.number)),
        beneficiary: parse_addr(&w.block.coinbase),
        timestamp: U256::from(parse_u64(&w.block.timestamp)),
        gas_limit: parse_u64(&w.block.gas_limit),
        basefee: parse_u64(&w.block.basefee),
        difficulty: U256::ZERO,
        prevrandao: Some(parse_b256(&w.block.prevrandao)),
        ..BlockEnv::default()
    };

    let tx = TxEnv::builder()
        .caller(parse_addr(&w.tx.caller))
        .gas_limit(parse_u64(&w.tx.gas_limit))
        .gas_price(parse_u128(&w.tx.gas_price))
        .kind(TxKind::Call(parse_addr(&w.tx.to)))
        .value(parse_u256(&w.tx.value))
        .data(parse_bytes(&w.tx.input))
        .nonce(w.tx.nonce)
        .build()
        .expect("build tx");

    let run_once = || -> Result<(bool, u64, Vec<u8>, u64), String> {
        let inner = Context::mainnet()
            .with_db(CacheDB::new(Arc::clone(&base_db)))
            .with_cfg(cfg.clone())
            .with_block(block.clone())
            .build_mainnet();
        let mut evm = JitEvm::new(inner, functions.clone());
        let t0 = Instant::now();
        let out = black_box(evm.transact(tx.clone())).map_err(|e| format!("{e:?}"))?;
        let dt = t0.elapsed().as_nanos() as u64;
        match out.result {
            ExecutionResult::Success { gas, output, .. } => Ok((true, gas.tx_gas_used(), output.into_data().to_vec(), dt)),
            ExecutionResult::Revert { gas, output, .. } => Ok((false, gas.tx_gas_used(), output.to_vec(), dt)),
            ExecutionResult::Halt { gas, .. } => Ok((false, gas.tx_gas_used(), Vec::new(), dt)),
        }
    };

    let (ok, ref_gas, ref_out, preflight_ns) = match run_once() {
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
        let (ok, gas, out, _) = run_once().expect("warmup");
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
        let (ok, gas, out, dt) = run_once().expect("sample");
        if !ok || gas != ref_gas || out != ref_out {
            emit_failure(&opts, &w, gas, "sample non-determinism");
            return;
        }
        samples.push(dt);
        elapsed_ns += dt;
    }

    emit_success(&opts, &w, ref_gas, &ref_out, budget_warmup, &samples, compile_ns, jit_compiled);
    drop(compiler);
}
