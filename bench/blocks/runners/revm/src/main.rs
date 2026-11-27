use revm::{
    ExecuteCommitEvm, MainBuilder, MainContext, SystemCallCommitEvm,
    context::{BlockEnv, CfgEnv, Context, ContextTr, TxEnv},
    context_interface::{
        block::BlobExcessGasAndPrice,
        result::ExecutionResult,
        transaction::{AccessList, AccessListItem, Authorization, SignedAuthorization},
    },
    database::InMemoryDB,
    primitives::{Address, B256, Bytes, TxKind, U256, address, hardfork::SpecId},
    state::{AccountInfo, Bytecode},
};
use serde::Deserialize;
use std::{
    collections::HashMap,
    env, fs,
    hint::black_box,
    time::Instant,
};

const BEACON_ROOTS_ADDRESS: Address = address!("000f3df6d732807ef1319fb7b8bb8522d0beac02");
const HISTORY_STORAGE_ADDRESS: Address = address!("0000f90827f1c53a10cb7a02335b175320002935");
const WITHDRAWAL_REQUEST_ADDRESS: Address = address!("00000961ef480eb55e80d19ad83579a64c007002");
const CONSOLIDATION_REQUEST_ADDRESS: Address = address!("0000bbddc7ce488642fb579f8b00f3a590007251");

#[derive(Deserialize)]
struct JsonAccessListEntry {
    address: String,
    #[serde(default)]
    storage_keys: Vec<String>,
}

#[derive(Deserialize)]
struct JsonAuthorization {
    chain_id: String,
    address: String,
    nonce: u64,
    y_parity: u8,
    r: String,
    s: String,
}

#[derive(Deserialize)]
struct JsonTx {
    #[serde(default)]
    r#type: u8,
    from: String,
    #[serde(default)]
    to: String,
    nonce: u64,
    gas: u64,
    #[serde(default)]
    gas_price: String,
    #[serde(default)]
    max_fee_per_gas: String,
    #[serde(default)]
    max_priority_fee_per_gas: String,
    #[serde(default)]
    max_fee_per_blob_gas: String,
    #[serde(default)]
    value: String,
    #[serde(default)]
    input: String,
    #[serde(default)]
    access_list: Vec<JsonAccessListEntry>,
    #[serde(default)]
    blob_versioned_hashes: Vec<String>,
    #[serde(default)]
    authorization_list: Vec<JsonAuthorization>,
    expected_gas_used: u64,
    expected_status: bool,
}

#[derive(Deserialize)]
struct JsonWithdrawal {
    address: String,
    amount_gwei: u64,
}

#[derive(Deserialize)]
struct JsonBlock {
    number: u64,
    hash: String,
    parent_hash: String,
    timestamp: u64,
    coinbase: String,
    gas_limit: u64,
    #[allow(dead_code)]
    gas_used: u64,
    base_fee: String,
    prev_randao: String,
    #[serde(default)]
    excess_blob_gas: u64,
    #[serde(default)]
    parent_beacon_block_root: String,
    #[serde(default)]
    withdrawals: Vec<JsonWithdrawal>,
    #[serde(default)]
    transactions: Vec<JsonTx>,
}

#[derive(Deserialize)]
struct JsonAccount {
    address: String,
    balance: String,
    nonce: u64,
    #[serde(default)]
    code_id: usize,
    #[serde(default)]
    first_block: u32,
    #[serde(default)]
    first_tx: u32,
    #[serde(default)]
    exact_pre_start: bool,
    #[serde(default)]
    storage: Vec<serde_json::Value>,
}

#[derive(Deserialize)]
struct JsonBundle {
    chain_id: u64,
    start_block: u64,
    end_block: u64,
    ancestor_hashes: HashMap<String, String>,
    codes: Vec<String>,
    accounts: Vec<JsonAccount>,
    blocks: Vec<JsonBlock>,
}

struct PreAccount {
    address: Address,
    balance: U256,
    nonce: u64,
    code_id: usize,
    first_block: u32,
    first_tx: u32,
    exact_pre_start: bool,
}

struct StorageSlot {
    addr: Address,
    slot: U256,
    val: U256,
    first_block: u32,
    first_tx: u32,
}

struct ParsedTx {
    tx_type: u8,
    tx_env: TxEnv,
    expected_gas_used: u64,
    expected_status: bool,
}

struct ParsedWithdrawal {
    address: Address,
    amount_wei: U256,
}

struct ParsedBlock {
    number: u64,
    hash: B256,
    parent_hash: B256,
    block_env: BlockEnv,
    beacon_root: Option<B256>,
    withdrawals: Vec<ParsedWithdrawal>,
    txs: Vec<ParsedTx>,
}

struct Bundle {
    chain_id: u64,
    start_block: u64,
    end_block: u64,
    ancestor_hashes: Vec<(u64, B256)>,
    raw_codes: Vec<Bytes>,
    accounts: Vec<PreAccount>,
    slots: Vec<StorageSlot>,
    blocks: Vec<ParsedBlock>,
}

struct TruePrestate {
    accounts: Vec<usize>,
    slots: Vec<usize>,
}

struct CliOpts {
    bundle_path: String,
    iterations: usize,
    warmup: usize,
    blob_update_fraction: u64,
    json_out: Option<String>,
    verbose_mismatches: usize,
}

fn parse_args() -> CliOpts {
    let args: Vec<String> = env::args().collect();
    let mut opts = CliOpts {
        bundle_path: ".cache/mainnet-blocks/26498000-26498099.json".into(),
        iterations: 5,
        warmup: 1,
        blob_update_fraction: 11684671,
        json_out: None,
        verbose_mismatches: 15,
    };
    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--bundle" => { i += 1; opts.bundle_path = args[i].clone(); }
            "--iterations" => { i += 1; opts.iterations = args[i].parse().unwrap(); }
            "--warmup" => { i += 1; opts.warmup = args[i].parse().unwrap(); }
            "--blob-fraction" => { i += 1; opts.blob_update_fraction = args[i].parse().unwrap(); }
            "--json" => { i += 1; opts.json_out = Some(args[i].clone()); }
            "--verbose-mismatches" => { i += 1; opts.verbose_mismatches = args[i].parse().unwrap(); }
            other => panic!("unknown argument: {other}"),
        }
        i += 1;
    }
    opts
}

fn trim_hex(s: &str) -> &str {
    let t = s.trim();
    t.strip_prefix("0x").or_else(|| t.strip_prefix("0X")).unwrap_or(t)
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

fn parse_addr(s: &str) -> Address {
    let h = trim_hex(s);
    let padded = format!("0x{:0>40}", h);
    padded.parse().unwrap()
}

fn parse_b256(s: &str) -> B256 {
    let h = trim_hex(s);
    let padded = format!("0x{:0>64}", h);
    padded.parse().unwrap()
}

fn parse_bytes(s: &str) -> Bytes {
    let h = trim_hex(s);
    if h.is_empty() {
        return Bytes::new();
    }
    if h.len() % 2 == 1 {
        let padded = format!("0{h}");
        Bytes::from(hex::decode(padded).unwrap())
    } else {
        Bytes::from(hex::decode(h).unwrap())
    }
}

fn load_bundle(opts: &CliOpts) -> Bundle {
    let raw = fs::read_to_string(&opts.bundle_path).expect("read bundle");
    let jb: JsonBundle = serde_json::from_str(&raw).expect("parse bundle json");

    let mut ancestor_hashes = Vec::with_capacity(jb.ancestor_hashes.len());
    for (k, v) in &jb.ancestor_hashes {
        ancestor_hashes.push((k.parse::<u64>().unwrap(), parse_b256(v)));
    }

    let raw_codes: Vec<Bytes> = jb.codes.iter().map(|c| parse_bytes(c)).collect();

    let mut accounts = Vec::with_capacity(jb.accounts.len());
    let mut slots = Vec::new();
    for ja in &jb.accounts {
        let addr = parse_addr(&ja.address);
        accounts.push(PreAccount {
            address: addr,
            balance: parse_u256(&ja.balance),
            nonce: ja.nonce,
            code_id: ja.code_id,
            first_block: ja.first_block,
            first_tx: ja.first_tx,
            exact_pre_start: ja.exact_pre_start,
        });
        for sv in &ja.storage {
            if let Some(arr) = sv.as_array() {
                if arr.len() >= 2 {
                    let slot = parse_u256(arr[0].as_str().unwrap());
                    let val = parse_u256(arr[1].as_str().unwrap());
                    let fb = arr.get(2).and_then(|x| x.as_u64()).unwrap_or(ja.first_block as u64) as u32;
                    let ft = arr.get(3).and_then(|x| x.as_u64()).unwrap_or(ja.first_tx as u64) as u32;
                    slots.push(StorageSlot { addr, slot, val, first_block: fb, first_tx: ft });
                }
            }
        }
    }

    let mut blocks = Vec::with_capacity(jb.blocks.len());
    for jblk in &jb.blocks {
        let base_fee = parse_u64(&jblk.base_fee);
        let blob = BlobExcessGasAndPrice::new(jblk.excess_blob_gas, opts.blob_update_fraction);
        let block_env = BlockEnv {
            number: U256::from(jblk.number),
            beneficiary: parse_addr(&jblk.coinbase),
            timestamp: U256::from(jblk.timestamp),
            gas_limit: jblk.gas_limit,
            basefee: base_fee,
            difficulty: U256::ZERO,
            prevrandao: Some(parse_b256(&jblk.prev_randao)),
            blob_excess_gas_and_price: Some(blob),
            ..BlockEnv::default()
        };

        let withdrawals = jblk
            .withdrawals
            .iter()
            .map(|w| ParsedWithdrawal {
                address: parse_addr(&w.address),
                amount_wei: U256::from(w.amount_gwei) * U256::from(1_000_000_000u64),
            })
            .collect();

        let mut txs = Vec::with_capacity(jblk.transactions.len());
        for jtx in &jblk.transactions {
            let kind = if jtx.to.is_empty() {
                TxKind::Create
            } else {
                TxKind::Call(parse_addr(&jtx.to))
            };
            let is_1559_like = jtx.r#type >= 2;
            let gas_price = if is_1559_like && !jtx.max_fee_per_gas.is_empty() {
                parse_u128(&jtx.max_fee_per_gas)
            } else {
                parse_u128(&jtx.gas_price)
            };
            let gas_priority_fee = if is_1559_like {
                Some(parse_u128(&jtx.max_priority_fee_per_gas))
            } else {
                None
            };
            let access_list = AccessList(
                jtx.access_list
                    .iter()
                    .map(|e| AccessListItem {
                        address: parse_addr(&e.address),
                        storage_keys: e.storage_keys.iter().map(|k| parse_b256(k)).collect(),
                    })
                    .collect(),
            );
            let blob_hashes: Vec<B256> = jtx.blob_versioned_hashes.iter().map(|h| parse_b256(h)).collect();
            let max_fee_per_blob_gas = if !jtx.max_fee_per_blob_gas.is_empty() {
                parse_u128(&jtx.max_fee_per_blob_gas)
            } else {
                0
            };
            let auths: Vec<_> = jtx
                .authorization_list
                .iter()
                .map(|a| {
                    let inner = Authorization {
                        chain_id: parse_u256(&a.chain_id),
                        address: parse_addr(&a.address),
                        nonce: a.nonce,
                    };
                    revm::context_interface::either::Either::Left(SignedAuthorization::new_unchecked(
                        inner,
                        a.y_parity,
                        parse_u256(&a.r),
                        parse_u256(&a.s),
                    ))
                })
                .collect();

            let tx_env = TxEnv {
                tx_type: jtx.r#type,
                caller: parse_addr(&jtx.from),
                gas_limit: jtx.gas,
                gas_price,
                kind,
                value: parse_u256(&jtx.value),
                data: parse_bytes(&jtx.input),
                nonce: jtx.nonce,
                chain_id: Some(jb.chain_id),
                access_list,
                gas_priority_fee,
                blob_hashes,
                max_fee_per_blob_gas,
                authorization_list: auths,
            };
            txs.push(ParsedTx {
                tx_type: jtx.r#type,
                tx_env,
                expected_gas_used: jtx.expected_gas_used,
                expected_status: jtx.expected_status,
            });
        }

        blocks.push(ParsedBlock {
            number: jblk.number,
            hash: parse_b256(&jblk.hash),
            parent_hash: parse_b256(&jblk.parent_hash),
            block_env,
            beacon_root: if jblk.parent_beacon_block_root.is_empty() {
                None
            } else {
                Some(parse_b256(&jblk.parent_beacon_block_root))
            },
            withdrawals,
            txs,
        });
    }

    Bundle {
        chain_id: jb.chain_id,
        start_block: jb.start_block,
        end_block: jb.end_block,
        ancestor_hashes,
        raw_codes,
        accounts,
        slots,
        blocks,
    }
}

fn make_bytecodes(raw_codes: &[Bytes]) -> Vec<(B256, Bytecode)> {
    raw_codes
        .iter()
        .map(|raw| {
            let bc = if raw.is_empty() {
                Bytecode::default()
            } else {
                Bytecode::new_raw(raw.clone())
            };
            let hash = bc.hash_slow();
            (hash, bc)
        })
        .collect()
}

fn insert_pre_account(db: &mut InMemoryDB, codes: &[(B256, Bytecode)], acc: &PreAccount) {
    if acc.balance.is_zero() && acc.nonce == 0 && acc.code_id == 0 {
        return;
    }
    let (code_hash, code) = if acc.code_id > 0 {
        let (h, c) = &codes[acc.code_id];
        (*h, Some(c.clone()))
    } else {
        (revm::primitives::KECCAK_EMPTY, None)
    };
    let info = AccountInfo {
        balance: acc.balance,
        nonce: acc.nonce,
        code_hash,
        code,
        account_id: None,
    };
    db.insert_account_info(acc.address, info);
}

fn make_cfg(chain_id: u64) -> CfgEnv {
    let mut cfg = CfgEnv::new();
    cfg.set_spec_and_mainnet_gas_params(SpecId::OSAKA);
    cfg.chain_id = chain_id;
    cfg.tx_chain_id_check = false;
    cfg
}

fn discover_true_prestate(bundle: &Bundle) -> TruePrestate {
    let codes = make_bytecodes(&bundle.raw_codes);
    let mut db = InMemoryDB::default();
    for &(bnum, bhash) in &bundle.ancestor_hashes {
        db.cache.block_hashes.insert(U256::from(bnum), bhash);
    }

    let mut acc_by_tx: HashMap<u64, Vec<usize>> = HashMap::new();
    let mut slot_by_tx: HashMap<u64, Vec<usize>> = HashMap::new();
    let mut true_accounts = Vec::new();
    let mut true_slots = Vec::new();

    for (idx, acc) in bundle.accounts.iter().enumerate() {
        if acc.exact_pre_start || (acc.first_block == 0 && acc.first_tx == 0) {
            if !acc.balance.is_zero() || acc.nonce != 0 || acc.code_id != 0 {
                insert_pre_account(&mut db, &codes, acc);
                true_accounts.push(idx);
            }
        } else {
            let key = ((acc.first_block as u64) << 32) | (acc.first_tx as u64);
            acc_by_tx.entry(key).or_default().push(idx);
        }
    }

    for (idx, sl) in bundle.slots.iter().enumerate() {
        if sl.first_block == 0 && sl.first_tx == 0 {
            if !sl.val.is_zero() {
                db.insert_account_storage(sl.addr, sl.slot, sl.val).unwrap();
                true_slots.push(idx);
            }
        } else {
            let key = ((sl.first_block as u64) << 32) | (sl.first_tx as u64);
            slot_by_tx.entry(key).or_default().push(idx);
        }
    }

    let mut evm = Context::mainnet()
        .with_db(db)
        .with_cfg(make_cfg(bundle.chain_id))
        .with_block(bundle.blocks[0].block_env.clone())
        .build_mainnet();

    for (bi, blk) in bundle.blocks.iter().enumerate() {
        evm.ctx.db_mut().cache.block_hashes.insert(U256::from(blk.number - 1), blk.parent_hash);
        evm.ctx.block = blk.block_env.clone();

        if let Some(root) = blk.beacon_root {
            let _ = evm.system_call_commit(BEACON_ROOTS_ADDRESS, Bytes::copy_from_slice(root.as_slice()));
        }
        let _ = evm.system_call_commit(HISTORY_STORAGE_ADDRESS, Bytes::copy_from_slice(blk.parent_hash.as_slice()));

        for (ti, tx) in blk.txs.iter().enumerate() {
            let key = ((bi as u64) << 32) | (ti as u64);
            if let Some(idxs) = acc_by_tx.get(&key) {
                for &acc_idx in idxs {
                    let acc = &bundle.accounts[acc_idx];
                    let exists = evm.ctx.db_ref().cache.accounts.contains_key(&acc.address);
                    if !exists && (!acc.balance.is_zero() || acc.nonce != 0 || acc.code_id != 0) {
                        insert_pre_account(evm.ctx.db_mut(), &codes, acc);
                        true_accounts.push(acc_idx);
                    }
                }
            }
            if let Some(idxs) = slot_by_tx.get(&key) {
                for &sl_idx in idxs {
                    let sl = &bundle.slots[sl_idx];
                    if !sl.val.is_zero() {
                        let cur = evm
                            .ctx
                            .db_ref()
                            .cache
                            .accounts
                            .get(&sl.addr)
                            .and_then(|a| a.storage.get(&sl.slot))
                            .copied()
                            .unwrap_or(U256::ZERO);
                        if cur.is_zero() {
                            evm.ctx.db_mut().insert_account_storage(sl.addr, sl.slot, sl.val).unwrap();
                            true_slots.push(sl_idx);
                        }
                    }
                }
            }
            let _ = evm.transact_commit(tx.tx_env.clone());
        }

        let _ = evm.system_call_commit(WITHDRAWAL_REQUEST_ADDRESS, Bytes::new());
        let _ = evm.system_call_commit(CONSOLIDATION_REQUEST_ADDRESS, Bytes::new());

        for w in &blk.withdrawals {
            if w.amount_wei.is_zero() {
                continue;
            }
            let acc = evm.ctx.db_mut().load_account(w.address).unwrap();
            acc.info.balance = acc.info.balance.saturating_add(w.amount_wei);
        }
        evm.ctx.db_mut().cache.block_hashes.insert(U256::from(blk.number), blk.hash);
    }

    TruePrestate {
        accounts: true_accounts,
        slots: true_slots,
    }
}

fn populate_db(bundle: &Bundle, pre: &TruePrestate, codes: &[(B256, Bytecode)]) -> InMemoryDB {
    let mut db = InMemoryDB::default();
    for &(bnum, bhash) in &bundle.ancestor_hashes {
        db.cache.block_hashes.insert(U256::from(bnum), bhash);
    }
    for &idx in &pre.accounts {
        insert_pre_account(&mut db, codes, &bundle.accounts[idx]);
    }
    for &idx in &pre.slots {
        let sl = &bundle.slots[idx];
        if !sl.val.is_zero() {
            db.insert_account_storage(sl.addr, sl.slot, sl.val).unwrap();
        }
    }
    db
}

struct ReplayStats {
    elapsed_ns: u64,
    tx_count: usize,
    status_matches: usize,
    gas_matches: usize,
    exact_matches: usize,
    actual_gas_total: u64,
    expected_gas_total: u64,
}

fn replay_all_blocks(
    bundle: &Bundle,
    db: InMemoryDB,
    log_mismatches: usize,
) -> ReplayStats {
    let mut evm = Context::mainnet()
        .with_db(db)
        .with_cfg(make_cfg(bundle.chain_id))
        .with_block(bundle.blocks[0].block_env.clone())
        .build_mainnet();

    let mut status_matches = 0usize;
    let mut gas_matches = 0usize;
    let mut exact_matches = 0usize;
    let mut tx_count = 0usize;
    let mut actual_gas_total = 0u64;
    let mut expected_gas_total = 0u64;
    let mut logged = 0usize;

    let t0 = Instant::now();

    for blk in &bundle.blocks {
        evm.ctx.db_mut().cache.block_hashes.insert(U256::from(blk.number - 1), blk.parent_hash);
        evm.ctx.block = blk.block_env.clone();

        if let Some(root) = blk.beacon_root {
            let _ = evm.system_call_commit(BEACON_ROOTS_ADDRESS, Bytes::copy_from_slice(root.as_slice()));
        }
        let _ = evm.system_call_commit(HISTORY_STORAGE_ADDRESS, Bytes::copy_from_slice(blk.parent_hash.as_slice()));

        for (ti, tx) in blk.txs.iter().enumerate() {
            let res = black_box(evm.transact_commit(tx.tx_env.clone())).expect("revm tx");
            let (success, gas_used) = match res {
                ExecutionResult::Success { gas, .. } => (true, gas.tx_gas_used()),
                ExecutionResult::Revert { gas, .. } => (false, gas.tx_gas_used()),
                ExecutionResult::Halt { gas, .. } => (false, gas.tx_gas_used()),
            };

            tx_count += 1;
            actual_gas_total += gas_used;
            expected_gas_total += tx.expected_gas_used;
            let s_ok = success == tx.expected_status;
            let g_ok = gas_used == tx.expected_gas_used;
            if s_ok { status_matches += 1; }
            if g_ok { gas_matches += 1; }
            if s_ok && g_ok {
                exact_matches += 1;
            } else if logged < log_mismatches {
                logged += 1;
                eprintln!(
                    "  mismatch block={} tx={} type={} status={}/{} gas={}/{} diff={}",
                    blk.number,
                    ti,
                    tx.tx_type,
                    success,
                    tx.expected_status,
                    gas_used,
                    tx.expected_gas_used,
                    gas_used as i64 - tx.expected_gas_used as i64
                );
            }
        }

        let _ = evm.system_call_commit(WITHDRAWAL_REQUEST_ADDRESS, Bytes::new());
        let _ = evm.system_call_commit(CONSOLIDATION_REQUEST_ADDRESS, Bytes::new());

        for w in &blk.withdrawals {
            if w.amount_wei.is_zero() {
                continue;
            }
            let acc = evm.ctx.db_mut().load_account(w.address).unwrap();
            acc.info.balance = acc.info.balance.saturating_add(w.amount_wei);
        }
        evm.ctx.db_mut().cache.block_hashes.insert(U256::from(blk.number), blk.hash);
    }

    let elapsed_ns = t0.elapsed().as_nanos() as u64;
    ReplayStats {
        elapsed_ns,
        tx_count,
        status_matches,
        gas_matches,
        exact_matches,
        actual_gas_total,
        expected_gas_total,
    }
}

fn main() {
    let opts = parse_args();
    let bundle = load_bundle(&opts);
    let true_pre = discover_true_prestate(&bundle);

    // Fresh Bytecode wrappers (empty OnceLock jump tables) so first run measures genuine cold analysis.
    let shared_codes = make_bytecodes(&bundle.raw_codes);

    let mut cold_stats: Option<ReplayStats> = None;
    for w in 0..opts.warmup {
        let db = populate_db(&bundle, &true_pre, &shared_codes);
        let st = replay_all_blocks(&bundle, db, if w == 0 { opts.verbose_mismatches } else { 0 });
        if w == 0 {
            cold_stats = Some(st);
        }
    }

    let mut times_ns = Vec::with_capacity(opts.iterations);
    let mut last_stats: Option<ReplayStats> = None;
    for iter in 0..opts.iterations {
        let db = populate_db(&bundle, &true_pre, &shared_codes);
        let log_n = if cold_stats.is_none() && iter == 0 { opts.verbose_mismatches } else { 0 };
        let st = replay_all_blocks(&bundle, db, log_n);
        times_ns.push(st.elapsed_ns);
        last_stats = Some(st);
    }

    let last = last_stats.unwrap();
    times_ns.sort_unstable();
    let median_ns = times_ns[times_ns.len() / 2];
    let sum_ns: u128 = times_ns.iter().map(|&t| t as u128).sum();
    let mean_ns = sum_ns as f64 / times_ns.len() as f64;
    let median_ms = median_ns as f64 / 1_000_000.0;
    let mean_ms = mean_ns / 1_000_000.0;
    let min_ms = times_ns[0] as f64 / 1_000_000.0;
    let cold_ns = cold_stats.as_ref().map(|c| c.elapsed_ns).unwrap_or(median_ns);
    let cold_ms = cold_ns as f64 / 1_000_000.0;
    let ms_per_block = median_ms / bundle.blocks.len() as f64;
    let mgas_per_sec = (last.actual_gas_total as f64 * 1_000.0) / median_ns as f64;
    let cold_mgas_per_sec = (last.actual_gas_total as f64 * 1_000.0) / cold_ns as f64;
    let txs_per_sec = (last.tx_count as f64 * 1_000_000_000.0) / median_ns as f64;

    println!("=== revm 100-Block Ethereum Mainnet Replay ===");
    println!("Range:        {}..{} ({} blocks, Osaka)", bundle.start_block, bundle.end_block, bundle.blocks.len());
    println!(
        "Pre-state:    {} true pre-start accounts (filtered from {}), {} slots, {} contracts",
        true_pre.accounts.len(),
        bundle.accounts.len(),
        true_pre.slots.len(),
        bundle.raw_codes.len() - 1
    );
    println!(
        "Transactions: {} (exact status+gas match: {}/{}, status: {}/{}, gas: {}/{})",
        last.tx_count,
        last.exact_matches,
        last.tx_count,
        last.status_matches,
        last.tx_count,
        last.gas_matches,
        last.tx_count
    );
    println!("Total gas:    {} (expected mainnet: {})", last.actual_gas_total, last.expected_gas_total);
    println!("Cold run:     {:.2} ms ({:.2} MGas/s)", cold_ms, cold_mgas_per_sec);
    println!(
        "Warm median:  {:.2} ms ({:.2} ms/block, {:.2} MGas/s, {:.0} tx/s)",
        median_ms, ms_per_block, mgas_per_sec, txs_per_sec
    );
    println!(
        "Warm mean:    {:.2} ms (min: {:.2} ms, iters={}, warmup={})",
        mean_ms, min_ms, opts.iterations, opts.warmup
    );

    if let Some(path) = opts.json_out {
        let json = format!(
            "{{\"engine\":\"revm\",\"start_block\":{},\"end_block\":{},\"blocks\":{},\"transactions\":{},\"exact_matches\":{},\"status_matches\":{},\"gas_matches\":{},\"actual_gas_total\":{},\"expected_gas_total\":{},\"cold_ms\":{:.2},\"warm_median_ms\":{:.2},\"warm_mean_ms\":{:.2},\"warm_min_ms\":{:.2},\"ms_per_block\":{:.2},\"mgas_per_sec\":{:.2},\"txs_per_sec\":{:.1}}}\n",
            bundle.start_block,
            bundle.end_block,
            bundle.blocks.len(),
            last.tx_count,
            last.exact_matches,
            last.status_matches,
            last.gas_matches,
            last.actual_gas_total,
            last.expected_gas_total,
            cold_ms,
            median_ms,
            mean_ms,
            min_ms,
            ms_per_block,
            mgas_per_sec,
            txs_per_sec
        );
        fs::write(path, json).expect("write json");
    }
}
