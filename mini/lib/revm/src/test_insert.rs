use revm::{
    db::{CacheDB, EmptyDB},
    primitives::{Address, AccountInfo, Bytecode, Bytes, U256},
};

fn main() {
    // Test if insert_account_info works
    let mut db = CacheDB::new(EmptyDB::default());
    
    let addr = Address::from([0x33; 20]);
    let code = vec![0x60, 0x42, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3];
    let bytecode = Bytecode::new_raw(Bytes::from(code.clone()));
    let code_hash = revm::primitives::keccak256(&code);
    
    println!("Before insert:");
    let before = db.basic(addr).unwrap_or_default();
    println!("  Account exists: {}", before.is_some());
    
    // Insert account info
    let account_info = AccountInfo {
        balance: U256::from(1000),
        nonce: 1,
        code_hash,
        code: Some(bytecode),
    };
    
    db.insert_account_info(addr, account_info.clone());
    
    println!("\nAfter insert:");
    let after = db.basic(addr).unwrap_or_default();
    println!("  Account exists: {}", after.is_some());
    if let Some(acc) = after {
        println!("  Balance: {}", acc.balance);
        println!("  Nonce: {}", acc.nonce);
        println!("  Code hash: {:?}", acc.code_hash);
        println!("  Has code: {}", acc.code.is_some());
    }
    
    // Try another approach - using load_account
    println!("\nTrying load_account approach:");
    let loaded = db.load_account(addr).unwrap();
    println!("  Account loaded, is_empty: {}", loaded.is_empty());
    println!("  Info: {:?}", loaded.info);
    
    // Modify the loaded account
    loaded.info.code = Some(bytecode.clone());
    loaded.info.code_hash = code_hash;
    
    println!("\nAfter modifying loaded account:");
    let final_check = db.basic(addr).unwrap_or_default();
    println!("  Account exists: {}", final_check.is_some());
    if let Some(acc) = final_check {
        println!("  Has code: {}", acc.code.is_some());
    }
}