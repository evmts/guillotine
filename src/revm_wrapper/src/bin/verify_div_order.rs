use revm::{
    db::{CacheDB, EmptyDB},
    primitives::{
        Address, Bytes, ExecutionResult, U256, B256,
        Output, TxKind, SpecId,
    },
    Evm,
};

fn test_div(a: U256, b: U256, expected_name: &str) -> U256 {
    let mut db = CacheDB::new(EmptyDB::default());
    let caller = Address::from([0x11; 20]);
    let contract_address = Address::from([0x33; 20]);
    
    // Create bytecode that pushes a, then b, then DIV
    let mut bytecode = vec![];
    
    // PUSH a
    bytecode.push(0x60);
    bytecode.push(a.byte(0));
    
    // PUSH b  
    bytecode.push(0x60);
    bytecode.push(b.byte(0));
    
    // DIV
    bytecode.push(0x04);
    
    // Store result
    bytecode.extend_from_slice(&[
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3,       // RETURN
    ]);
    
    db.insert_account_info(
        caller,
        revm::primitives::AccountInfo {
            balance: U256::MAX,
            nonce: 0,
            code_hash: B256::ZERO,
            code: None,
        }
    );
    
    db.insert_account_info(
        contract_address,
        revm::primitives::AccountInfo {
            balance: U256::ZERO,
            nonce: 0,
            code_hash: B256::ZERO,
            code: Some(revm::primitives::Bytecode::LegacyRaw(Bytes::from(bytecode))),
        }
    );
    
    let mut evm = Evm::builder()
        .with_db(db)
        .with_spec_id(SpecId::LATEST)
        .modify_tx_env(|tx| {
            tx.caller = caller;
            tx.transact_to = TxKind::Call(contract_address);
            tx.gas_limit = 1_000_000;
            tx.data = Bytes::new();
        })
        .build();
    
    let result = evm.transact().unwrap();
    
    match result.result {
        ExecutionResult::Success { output, .. } => {
            match output {
                Output::Call(data) => {
                    let mut bytes = [0u8; 32];
                    bytes.copy_from_slice(&data);
                    let value = U256::from_be_bytes(bytes);
                    println!("PUSH {} then PUSH {}, DIV = {} (expecting {})", a, b, value, expected_name);
                    value
                }
                _ => panic!("Unexpected output"),
            }
        }
        _ => panic!("Execution failed"),
    }
}

fn main() {
    println!("=== Verifying REVM DIV Stack Order ===\n");
    println!("Testing what REVM actually computes for DIV operation:\n");
    
    // Test 1: 10 / 5 = 2
    let result1 = test_div(U256::from(10), U256::from(5), "10 / 5 = 2 OR 5 / 10 = 0");
    
    // Test 2: 42 / 6 = 7
    let result2 = test_div(U256::from(42), U256::from(6), "42 / 6 = 7 OR 6 / 42 = 0");
    
    println!("\nConclusion:");
    if result1 == U256::from(2) {
        println!("REVM computes: second_from_top / top (a / b where stack is [a, b])");
    } else if result1 == U256::from(0) {
        println!("REVM computes: top / second_from_top (b / a where stack is [a, b])");
    }
    
    println!("Result1: {}, Result2: {}", result1, result2);
}