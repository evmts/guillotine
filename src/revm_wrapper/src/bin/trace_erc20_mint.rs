use revm::{
    primitives::{
        hex, Address, ExecutionResult, Output, TxKind, B256, U256,
    },
    InMemoryDB, Evm,
};
use revm::inspectors::TracerEip3155;
use std::fs;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    // Read ERC20 bytecode
    let bytecode_hex = fs::read_to_string("test/evm/erc20_mint.hex")?;
    let bytecode = hex::decode(bytecode_hex.trim())?;
    
    let caller = Address::from(hex!("1000000000000000000000000000000000000001"));
    
    let mut db = InMemoryDB::default();
    
    // Set caller balance
    let caller_info = revm::primitives::AccountInfo {
        balance: U256::MAX,
        nonce: 0,
        code_hash: B256::ZERO,
        code: None,
    };
    db.insert_account_info(caller, caller_info);
    
    // Deploy contract
    println!("\n=== Deploying ERC20 Contract ===");
    let deploy_result = {
        let mut evm = Evm::builder()
            .with_db(&mut db)
            .with_external_context(TracerEip3155::new(Box::new(std::io::stdout())))
            .modify_tx_env(|tx| {
                tx.caller = caller;
                tx.transact_to = TxKind::Create;
                tx.data = bytecode.clone().into();
                tx.gas_limit = 1_000_000_000;
                tx.gas_price = U256::ZERO;
                tx.value = U256::ZERO;
            })
            .build();
        
        evm.transact()?
    };
    
    let contract_address = match &deploy_result.result {
        ExecutionResult::Success { output, gas_used, .. } => {
            match output {
                Output::Create(_, Some(addr)) => {
                    println!("Deployment successful - gas_used: {}, address: {:?}", gas_used, addr);
                    *addr
                }
                _ => {
                    println!("Deployment failed - no contract address returned");
                    return Ok(());
                }
            }
        }
        ExecutionResult::Revert { output, gas_used } => {
            println!("Deployment reverted - gas_used: {}", gas_used);
            println!("Revert data: 0x{}", hex::encode(output));
            return Ok(());
        }
        ExecutionResult::Halt { reason, gas_used } => {
            println!("Deployment halted - gas_used: {}, reason: {:?}", gas_used, reason);
            return Ok(());
        }
    };
    
    // Now call the mint function
    let calldata = hex::decode("30627b7c")?;
    
    // Create tracer for the call
    let trace_file = fs::File::create("revm_erc20_mint_trace.json")?;
    let tracer = TracerEip3155::new(Box::new(trace_file));
    
    let mut evm = Evm::builder()
        .with_db(&mut db)
        .with_external_context(tracer)
        .modify_tx_env(|tx| {
            tx.caller = caller;
            tx.transact_to = TxKind::Call(contract_address);
            tx.data = calldata.into();
            tx.gas_limit = 1_000_000_000;
            tx.gas_price = U256::ZERO;
            tx.value = U256::ZERO;
        })
        .build();
    
    println!("\n=== Calling mint function ===");
    let call_result = evm.transact()?;
    
    match &call_result.result {
        ExecutionResult::Success { output, gas_used, .. } => {
            println!("Call successful - gas_used: {}", gas_used);
            match output {
                Output::Call(data) => {
                    println!("Output length: {}", data.len());
                    if !data.is_empty() {
                        println!("Output (hex): 0x{}", hex::encode(data));
                    }
                }
                _ => {}
            }
        }
        ExecutionResult::Revert { output, gas_used } => {
            println!("Call reverted - gas_used: {}", gas_used);
            println!("Revert data: 0x{}", hex::encode(output));
        }
        ExecutionResult::Halt { reason, gas_used } => {
            println!("Call halted - gas_used: {}, reason: {:?}", gas_used, reason);
        }
    }
    
    println!("\nTrace written to revm_erc20_mint_trace.json");
    
    Ok(())
}