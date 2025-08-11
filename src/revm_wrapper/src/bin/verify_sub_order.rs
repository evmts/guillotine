use revm::{
    db::{CacheDB, EmptyDB},
    primitives::{
        Address, Bytes, ExecutionResult, U256, B256,
        Output, TxKind, SpecId,
    },
    Evm,
};

fn test_sub(a: u64, b: u64, expected_name: &str) -> U256 {
    let mut db = CacheDB::new(EmptyDB::default());
    let caller = Address::from([0x11; 20]);
    let contract_address = Address::from([0x33; 20]);
    
    // Create bytecode that pushes a, then b, then SUB
    let mut bytecode = vec![];
    
    // PUSH a
    bytecode.push(0x60);
    bytecode.push(a as u8);
    
    // PUSH b  
    bytecode.push(0x60);
    bytecode.push(b as u8);
    
    // SUB
    bytecode.push(0x03);
    
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
                    println!("PUSH {} then PUSH {}, SUB = {} (expecting {})", a, b, 
                        if value > U256::from(1) << 255 {
                            format!("-{}", U256::MAX - value + U256::from(1))
                        } else {
                            format!("{}", value)
                        },
                        expected_name
                    );
                    value
                }
                _ => panic!("Unexpected output"),
            }
        }
        _ => panic!("Execution failed"),
    }
}

fn main() {
    println!("=== Verifying REVM SUB Stack Order ===\n");
    println!("Testing what REVM actually computes for SUB operation:\n");
    
    // Test 1: 100 - 58 = 42 (if second - top) OR 58 - 100 = -42 (if top - second)
    let result1 = test_sub(100, 58, "100 - 58 = 42");
    
    // Test 2: 50 - 30 = 20 (if second - top) OR 30 - 50 = -20 (if top - second)  
    test_sub(50, 30, "50 - 30 = 20");
    
    // Test 3: 10 - 20 (to see underflow behavior)
    test_sub(10, 20, "10 - 20 = -10");
    
    println!("\nConclusion:");
    if result1 == U256::from(42) {
        println!("REVM computes: second_from_top - top (CORRECT per Yellow Paper)");
    } else if result1 == U256::MAX - U256::from(41) {
        println!("REVM computes: top - second_from_top (INCORRECT per Yellow Paper)");
    }
}