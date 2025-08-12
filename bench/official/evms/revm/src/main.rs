use std::{env, fs, str::FromStr};

use revm::{
    db::{CacheDB, EmptyDB},
    primitives::{specification::LATEST_SPEC_ID, Address, Bytes, TxKind, U256},
    Evm,
};

const CALLER_ADDRESS: &str = "0x1000000000000000000000000000000000000001";

fn main() {
    let args: Vec<String> = env::args().collect();
    
    // Fast argument parsing without validation
    let mut contract_code_path = String::new();
    let mut calldata_hex = String::new();
    let mut num_runs: u8 = 1;
    
    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--contract-code-path" => {
                contract_code_path = args[i + 1].clone();
                i += 2;
            }
            "--calldata" => {
                calldata_hex = args[i + 1].clone();
                i += 2;
            }
            "--num-runs" => {
                num_runs = args[i + 1].parse().unwrap();
                i += 2;
            }
            _ => i += 1,
        }
    }
    
    let caller_address = Address::from_str(CALLER_ADDRESS).unwrap();
    
    // Read and decode without error handling for performance
    let contract_code_hex = fs::read_to_string(&contract_code_path).unwrap().trim().to_string();
    let contract_code: Bytes = hex::decode(contract_code_hex.trim_start_matches("0x")).unwrap().into();
    let calldata: Bytes = hex::decode(calldata_hex.trim_start_matches("0x")).unwrap().into();
    
    let mut db = CacheDB::new(EmptyDB::default());
    
    // Set up caller with large balance
    let caller_info = revm::primitives::AccountInfo {
        balance: U256::MAX,
        nonce: 0,
        code_hash: revm::primitives::KECCAK_EMPTY,
        code: None,
    };
    db.insert_account_info(caller_address, caller_info);
    
    // Directly set runtime code at a deterministic address
    let contract_address = Address::from_str("0x5FbDB2315678afecb367f032d93F642f64180aa3").unwrap();
    db.insert_account_code(contract_address, contract_code.clone().into());
    
    // Create EVM instance once - outside the loop (like Zig does)
    let mut evm = Evm::builder()
        .with_db(&mut db)
        .with_spec_id(LATEST_SPEC_ID)
        .modify_tx_env(|tx| {
            tx.caller = caller_address;
            tx.transact_to = TxKind::Call(contract_address);
            tx.value = U256::ZERO;
            tx.data = calldata;
            tx.gas_limit = 1_000_000_000; // 1B gas
            tx.gas_price = U256::from(1u64);
        })
        .modify_block_env(|block| {
            block.basefee = U256::from(7u64);
        })
        .build();
    
    // Run the benchmark num_runs times
    for _ in 0..num_runs {
        let _result = evm.transact().unwrap();
    }
}

