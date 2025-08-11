use revm::{
    db::{CacheDB, EmptyDB},
    primitives::{
        Address, Bytes, ExecutionResult, TransactTo, U256, B256,
        Env, TxEnv, BlockEnv, CfgEnv,
    },
    Evm,
    inspector_handle_register,
    inspectors::TracerEip3155,
};
use std::fs;

fn main() {
    // Read the ERC20 bytecode
    let bytecode_hex = fs::read_to_string("test/evm/erc20_constructor_bytecode.bin")
        .expect("Failed to read bytecode file");
    let bytecode = hex::decode(bytecode_hex.trim()).expect("Failed to decode bytecode");

    // Create database
    let mut db = CacheDB::new(EmptyDB::default());
    
    // Set up caller with balance
    let caller = Address::from([0x10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]);
    db.insert_account_info(
        caller,
        revm::primitives::AccountInfo {
            balance: U256::MAX,
            nonce: 0,
            code_hash: B256::ZERO,
            code: None,
        }
    );
    
    // Create tracer that writes to stdout
    let mut tracer = TracerEip3155::new(Box::new(std::io::stdout()));
    
    // Create EVM with tracer
    let mut evm = Evm::builder()
        .with_db(db)
        .with_external_context(&mut tracer)
        .append_handler_register(inspector_handle_register)
        .build();
    
    // Set up environment
    *evm.context.evm.env = Env {
        cfg: CfgEnv::default(),
        block: BlockEnv {
            number: U256::from(1),
            timestamp: U256::from(1),
            gas_limit: U256::from(1_000_000_000),
            ..Default::default()
        },
        tx: TxEnv {
            caller,
            gas_limit: 1_000_000_000,
            data: Bytes::from(bytecode),
            transact_to: TransactTo::Create,
            ..Default::default()
        },
    };

    // Execute
    let result = evm.transact().expect("Transaction failed");
    
    eprintln!("\nExecution result: {:?}", result);
    
    // Check if it succeeded
    match result.result {
        ExecutionResult::Success { output, gas_used, .. } => {
            eprintln!("\nREVM Success! Gas used: {}", gas_used);
            if let revm::primitives::Output::Create(_, Some(address)) = output {
                eprintln!("Contract deployed at: {:?}", address);
            }
        }
        ExecutionResult::Revert { output, gas_used, .. } => {
            eprintln!("\nREVM Reverted! Gas used: {}", gas_used);
            eprintln!("Output: {}", hex::encode(&output));
            
            if output.len() >= 36 && output.starts_with(&[0x4e, 0x48, 0x7b, 0x71]) {
                let panic_code = output[35];
                eprintln!("Solidity panic code: 0x{:02x}", panic_code);
            }
        }
        ExecutionResult::Halt { reason, gas_used } => {
            eprintln!("\nREVM Halted! Reason: {:?}, Gas used: {}", reason, gas_used);
        }
    }
}