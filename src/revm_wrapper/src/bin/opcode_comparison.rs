use revm::{
    db::{CacheDB, EmptyDB},
    primitives::{
        Address, Bytes, ExecutionResult, U256, B256,
        Output, TxKind,
    },
    Evm,
};
use std::fs;
use std::io::Write;

fn main() {
    println!("=== Running Opcode Comparison Tests ===\n");
    
    let mut passed = 0;
    let mut failed = 0;
    
    // Arithmetic tests
    if test_add() { passed += 1; } else { failed += 1; }
    if test_sub() { passed += 1; } else { failed += 1; }
    if test_mul() { passed += 1; } else { failed += 1; }
    if test_div() { passed += 1; } else { failed += 1; }
    if test_mod() { passed += 1; } else { failed += 1; }
    if test_addmod() { passed += 1; } else { failed += 1; }
    if test_mulmod() { passed += 1; } else { failed += 1; }
    if test_exp() { passed += 1; } else { failed += 1; }
    if test_signextend() { passed += 1; } else { failed += 1; }
    
    // Comparison tests
    if test_lt() { passed += 1; } else { failed += 1; }
    if test_gt() { passed += 1; } else { failed += 1; }
    if test_slt() { passed += 1; } else { failed += 1; }
    if test_sgt() { passed += 1; } else { failed += 1; }
    if test_eq() { passed += 1; } else { failed += 1; }
    if test_iszero() { passed += 1; } else { failed += 1; }
    
    // Bitwise tests
    if test_and() { passed += 1; } else { failed += 1; }
    if test_or() { passed += 1; } else { failed += 1; }
    if test_xor() { passed += 1; } else { failed += 1; }
    if test_not() { passed += 1; } else { failed += 1; }
    if test_byte() { passed += 1; } else { failed += 1; }
    if test_shl() { passed += 1; } else { failed += 1; }
    if test_shr() { passed += 1; } else { failed += 1; }
    if test_sar() { passed += 1; } else { failed += 1; }
    
    println!("\n=== Summary ===");
    println!("Passed: {}", passed);
    println!("Failed: {}", failed);
}

fn run_bytecode_and_check_stack(bytecode: &[u8], expected_stack: &[U256]) -> bool {
    run_bytecode_and_check_stack_debug(bytecode, expected_stack, false)
}

fn run_bytecode_and_check_stack_debug(bytecode: &[u8], expected_stack: &[U256], debug: bool) -> bool {
    let mut db = CacheDB::new(EmptyDB::default());
    let caller = Address::from([0x11; 20]);
    
    db.insert_account_info(
        caller,
        revm::primitives::AccountInfo {
            balance: U256::MAX,
            nonce: 0,
            code_hash: B256::ZERO,
            code: None,
        }
    );
    
    let contract_address = Address::from([0x33; 20]);
    db.insert_account_info(
        contract_address,
        revm::primitives::AccountInfo {
            balance: U256::ZERO,
            nonce: 0,
            code_hash: B256::ZERO,
            code: Some(revm::primitives::Bytecode::LegacyRaw(Bytes::from(bytecode.to_vec()))),
        }
    );
    
    let mut evm = Evm::builder()
        .with_db(db)
        .modify_tx_env(|tx| {
            tx.caller = caller;
            tx.transact_to = TxKind::Call(contract_address);
            tx.gas_limit = 1_000_000;
            tx.data = Bytes::new();
        })
        .build();
    
    let result = evm.transact().expect("Transaction failed");
    
    match result.result {
        ExecutionResult::Success { output, gas_used, .. } => {
            if debug {
                println!("  Gas used: {}", gas_used);
            }
            // For simple opcode tests, we expect the stack result to be in the output
            match output {
                Output::Call(data) => {
                    if debug {
                        println!("  Output length: {}", data.len());
                        if !data.is_empty() {
                            println!("  Output hex: 0x{}", hex::encode(&data));
                        }
                    }
                    
                    if expected_stack.is_empty() {
                        return data.is_empty();
                    }
                    
                    // Check if the output matches expected stack top
                    if data.len() == 32 {
                        let mut bytes = [0u8; 32];
                        bytes.copy_from_slice(&data);
                        let result = U256::from_be_bytes(bytes);
                        if debug {
                            println!("  Expected: {}", expected_stack[0]);
                            println!("  Got: {}", result);
                        }
                        return result == expected_stack[0];
                    }
                    false
                }
                _ => {
                    if debug {
                        println!("  Unexpected output type");
                    }
                    false
                }
            }
        }
        ExecutionResult::Revert { output, gas_used } => {
            if debug {
                println!("  Reverted - gas used: {}", gas_used);
                println!("  Revert data: 0x{}", hex::encode(&output));
            }
            false
        }
        ExecutionResult::Halt { reason, gas_used } => {
            if debug {
                println!("  Halted - reason: {:?}, gas used: {}", reason, gas_used);
            }
            false
        }
    }
}

// Arithmetic operations
fn test_add() -> bool {
    println!("Testing ADD...");
    
    // Test 1: Simple addition (5 + 10 = 15)
    let bytecode = vec![
        0x60, 0x05, // PUSH1 5
        0x60, 0x0A, // PUSH1 10
        0x01,       // ADD
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3,       // RETURN
    ];
    
    if !run_bytecode_and_check_stack(&bytecode, &[U256::from(15)]) {
        println!("  ❌ ADD: 5 + 10 failed");
        return false;
    }
    
    // Test 2: Addition with overflow (MAX + 1 = 0)
    let bytecode_overflow = vec![
        0x7F, // PUSH32
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, // MAX_U256
        0x60, 0x01, // PUSH1 1
        0x01,       // ADD
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3,       // RETURN
    ];
    
    if !run_bytecode_and_check_stack(&bytecode_overflow, &[U256::ZERO]) {
        println!("  ❌ ADD: overflow test failed");
        return false;
    }
    
    println!("  ✅ ADD passed");
    true
}

fn test_sub() -> bool {
    println!("Testing SUB...");
    
    // Test 1: Simple subtraction (42 - 0 = 42)
    // Stack order in revm: top - second (opposite of our fix!)
    let bytecode = vec![
        0x60, 0x00, // PUSH1 0
        0x60, 0x2A, // PUSH1 42
        0x03,       // SUB
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3,       // RETURN
    ];
    
    if !run_bytecode_and_check_stack_debug(&bytecode, &[U256::from(42)], true) {
        println!("  ❌ SUB: 42 - 0 failed");
        return false;
    }
    
    // Test 2: Basic subtraction (10 - 5 = 5)
    let bytecode2 = vec![
        0x60, 0x0A, // PUSH1 10
        0x60, 0x05, // PUSH1 5
        0x03,       // SUB
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3,       // RETURN
    ];
    
    if !run_bytecode_and_check_stack(&bytecode2, &[U256::from(5)]) {
        println!("  ❌ SUB: 10 - 5 failed");
        return false;
    }
    
    // Test 3: Underflow (0 - 1 = MAX)
    let bytecode_underflow = vec![
        0x60, 0x00, // PUSH1 0
        0x60, 0x01, // PUSH1 1
        0x03,       // SUB
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3,       // RETURN
    ];
    
    if !run_bytecode_and_check_stack(&bytecode_underflow, &[U256::MAX]) {
        println!("  ❌ SUB: underflow test failed");
        return false;
    }
    
    println!("  ✅ SUB passed");
    true
}

fn test_mul() -> bool {
    println!("Testing MUL...");
    
    // Test: 6 * 7 = 42
    let bytecode = vec![
        0x60, 0x06, // PUSH1 6
        0x60, 0x07, // PUSH1 7
        0x02,       // MUL
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3,       // RETURN
    ];
    
    if !run_bytecode_and_check_stack(&bytecode, &[U256::from(42)]) {
        println!("  ❌ MUL: 6 * 7 failed");
        return false;
    }
    
    println!("  ✅ MUL passed");
    true
}

fn test_div() -> bool {
    println!("Testing DIV...");
    
    // Test 1: 84 / 2 = 42
    let bytecode = vec![
        0x60, 0x54, // PUSH1 84
        0x60, 0x02, // PUSH1 2
        0x04,       // DIV
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3,       // RETURN
    ];
    
    if !run_bytecode_and_check_stack(&bytecode, &[U256::from(42)]) {
        println!("  ❌ DIV: 84 / 2 failed");
        return false;
    }
    
    // Test 2: Division by zero (should return 0)
    let bytecode_div_zero = vec![
        0x60, 0x0A, // PUSH1 10
        0x60, 0x00, // PUSH1 0
        0x04,       // DIV
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3,       // RETURN
    ];
    
    if !run_bytecode_and_check_stack(&bytecode_div_zero, &[U256::ZERO]) {
        println!("  ❌ DIV: division by zero failed");
        return false;
    }
    
    println!("  ✅ DIV passed");
    true
}

fn test_mod() -> bool {
    println!("Testing MOD...");
    
    // Test: 17 % 5 = 2
    let bytecode = vec![
        0x60, 0x11, // PUSH1 17
        0x60, 0x05, // PUSH1 5
        0x06,       // MOD
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3,       // RETURN
    ];
    
    if !run_bytecode_and_check_stack(&bytecode, &[U256::from(2)]) {
        println!("  ❌ MOD: 17 % 5 failed");
        return false;
    }
    
    println!("  ✅ MOD passed");
    true
}

fn test_addmod() -> bool {
    println!("Testing ADDMOD...");
    
    // Test: (10 + 10) % 8 = 4
    let bytecode = vec![
        0x60, 0x0A, // PUSH1 10
        0x60, 0x0A, // PUSH1 10
        0x60, 0x08, // PUSH1 8
        0x08,       // ADDMOD
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3,       // RETURN
    ];
    
    if !run_bytecode_and_check_stack(&bytecode, &[U256::from(4)]) {
        println!("  ❌ ADDMOD: (10 + 10) % 8 failed");
        return false;
    }
    
    println!("  ✅ ADDMOD passed");
    true
}

fn test_mulmod() -> bool {
    println!("Testing MULMOD...");
    
    // Test: (10 * 10) % 8 = 4
    let bytecode = vec![
        0x60, 0x0A, // PUSH1 10
        0x60, 0x0A, // PUSH1 10
        0x60, 0x08, // PUSH1 8
        0x09,       // MULMOD
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3,       // RETURN
    ];
    
    if !run_bytecode_and_check_stack(&bytecode, &[U256::from(4)]) {
        println!("  ❌ MULMOD: (10 * 10) % 8 failed");
        return false;
    }
    
    println!("  ✅ MULMOD passed");
    true
}

fn test_exp() -> bool {
    println!("Testing EXP...");
    
    // Test: 2 ** 3 = 8
    let bytecode = vec![
        0x60, 0x02, // PUSH1 2
        0x60, 0x03, // PUSH1 3
        0x0A,       // EXP
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3,       // RETURN
    ];
    
    if !run_bytecode_and_check_stack(&bytecode, &[U256::from(8)]) {
        println!("  ❌ EXP: 2 ** 3 failed");
        return false;
    }
    
    println!("  ✅ EXP passed");
    true
}

fn test_signextend() -> bool {
    println!("Testing SIGNEXTEND...");
    
    // Test: Sign extend 0xFF from byte 0
    let bytecode = vec![
        0x60, 0xFF, // PUSH1 0xFF
        0x60, 0x00, // PUSH1 0 (extend from byte 0)
        0x0B,       // SIGNEXTEND
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3,       // RETURN
    ];
    
    // 0xFF sign extended should become 0xFFFFFFFF...
    if !run_bytecode_and_check_stack(&bytecode, &[U256::MAX]) {
        println!("  ❌ SIGNEXTEND: 0xFF from byte 0 failed");
        return false;
    }
    
    println!("  ✅ SIGNEXTEND passed");
    true
}

// Comparison operations
fn test_lt() -> bool {
    println!("Testing LT...");
    
    // Test 1: 5 < 10 = 1 (true)
    // Stack order: second < top
    let bytecode = vec![
        0x60, 0x05, // PUSH1 5
        0x60, 0x0A, // PUSH1 10
        0x10,       // LT
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3,       // RETURN
    ];
    
    if !run_bytecode_and_check_stack(&bytecode, &[U256::from(1)]) {
        println!("  ❌ LT: 5 < 10 failed");
        return false;
    }
    
    // Test 2: 10 < 5 = 0 (false)
    let bytecode2 = vec![
        0x60, 0x0A, // PUSH1 10
        0x60, 0x05, // PUSH1 5
        0x10,       // LT
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3,       // RETURN
    ];
    
    if !run_bytecode_and_check_stack(&bytecode2, &[U256::from(0)]) {
        println!("  ❌ LT: 10 < 5 failed");
        return false;
    }
    
    println!("  ✅ LT passed");
    true
}

fn test_gt() -> bool {
    println!("Testing GT...");
    
    // Test 1: 5 > 3 = 1 (true)
    // Stack order after fix: top > second
    let bytecode = vec![
        0x60, 0x03, // PUSH1 3
        0x60, 0x05, // PUSH1 5
        0x11,       // GT
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3,       // RETURN
    ];
    
    if !run_bytecode_and_check_stack(&bytecode, &[U256::from(1)]) {
        println!("  ❌ GT: 5 > 3 failed");
        return false;
    }
    
    // Test 2: 3 > 5 = 0 (false)
    let bytecode2 = vec![
        0x60, 0x05, // PUSH1 5
        0x60, 0x03, // PUSH1 3
        0x11,       // GT
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3,       // RETURN
    ];
    
    if !run_bytecode_and_check_stack(&bytecode2, &[U256::from(0)]) {
        println!("  ❌ GT: 3 > 5 failed");
        return false;
    }
    
    println!("  ✅ GT passed");
    true
}

fn test_slt() -> bool {
    println!("Testing SLT (signed less than)...");
    
    // Test: -1 < 1 = 1 (true)
    let bytecode = vec![
        0x7F, // PUSH32
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, // -1 in two's complement
        0x60, 0x01, // PUSH1 1
        0x12,       // SLT
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3,       // RETURN
    ];
    
    if !run_bytecode_and_check_stack(&bytecode, &[U256::from(1)]) {
        println!("  ❌ SLT: -1 < 1 failed");
        return false;
    }
    
    println!("  ✅ SLT passed");
    true
}

fn test_sgt() -> bool {
    println!("Testing SGT (signed greater than)...");
    
    // Test: 1 > -1 = 1 (true)
    let bytecode = vec![
        0x7F, // PUSH32
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, // -1 in two's complement
        0x60, 0x01, // PUSH1 1
        0x13,       // SGT
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3,       // RETURN
    ];
    
    if !run_bytecode_and_check_stack(&bytecode, &[U256::from(1)]) {
        println!("  ❌ SGT: 1 > -1 failed");
        return false;
    }
    
    println!("  ✅ SGT passed");
    true
}

fn test_eq() -> bool {
    println!("Testing EQ...");
    
    // Test 1: 42 == 42 = 1 (true)
    let bytecode = vec![
        0x60, 0x2A, // PUSH1 42
        0x60, 0x2A, // PUSH1 42
        0x14,       // EQ
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3,       // RETURN
    ];
    
    if !run_bytecode_and_check_stack(&bytecode, &[U256::from(1)]) {
        println!("  ❌ EQ: 42 == 42 failed");
        return false;
    }
    
    // Test 2: 42 == 43 = 0 (false)
    let bytecode2 = vec![
        0x60, 0x2A, // PUSH1 42
        0x60, 0x2B, // PUSH1 43
        0x14,       // EQ
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3,       // RETURN
    ];
    
    if !run_bytecode_and_check_stack(&bytecode2, &[U256::from(0)]) {
        println!("  ❌ EQ: 42 == 43 failed");
        return false;
    }
    
    println!("  ✅ EQ passed");
    true
}

fn test_iszero() -> bool {
    println!("Testing ISZERO...");
    
    // Test 1: ISZERO(0) = 1 (true)
    let bytecode = vec![
        0x60, 0x00, // PUSH1 0
        0x15,       // ISZERO
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3,       // RETURN
    ];
    
    if !run_bytecode_and_check_stack(&bytecode, &[U256::from(1)]) {
        println!("  ❌ ISZERO: ISZERO(0) failed");
        return false;
    }
    
    // Test 2: ISZERO(1) = 0 (false)
    let bytecode2 = vec![
        0x60, 0x01, // PUSH1 1
        0x15,       // ISZERO
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3,       // RETURN
    ];
    
    if !run_bytecode_and_check_stack(&bytecode2, &[U256::from(0)]) {
        println!("  ❌ ISZERO: ISZERO(1) failed");
        return false;
    }
    
    println!("  ✅ ISZERO passed");
    true
}

// Bitwise operations
fn test_and() -> bool {
    println!("Testing AND...");
    
    // Test: 0xFF AND 0x0F = 0x0F
    let bytecode = vec![
        0x60, 0xFF, // PUSH1 0xFF
        0x60, 0x0F, // PUSH1 0x0F
        0x16,       // AND
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3,       // RETURN
    ];
    
    if !run_bytecode_and_check_stack(&bytecode, &[U256::from(0x0F)]) {
        println!("  ❌ AND: 0xFF AND 0x0F failed");
        return false;
    }
    
    println!("  ✅ AND passed");
    true
}

fn test_or() -> bool {
    println!("Testing OR...");
    
    // Test: 0xF0 OR 0x0F = 0xFF
    let bytecode = vec![
        0x60, 0xF0, // PUSH1 0xF0
        0x60, 0x0F, // PUSH1 0x0F
        0x17,       // OR
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3,       // RETURN
    ];
    
    if !run_bytecode_and_check_stack(&bytecode, &[U256::from(0xFF)]) {
        println!("  ❌ OR: 0xF0 OR 0x0F failed");
        return false;
    }
    
    println!("  ✅ OR passed");
    true
}

fn test_xor() -> bool {
    println!("Testing XOR...");
    
    // Test: 0xFF XOR 0xF0 = 0x0F
    let bytecode = vec![
        0x60, 0xFF, // PUSH1 0xFF
        0x60, 0xF0, // PUSH1 0xF0
        0x18,       // XOR
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3,       // RETURN
    ];
    
    if !run_bytecode_and_check_stack(&bytecode, &[U256::from(0x0F)]) {
        println!("  ❌ XOR: 0xFF XOR 0xF0 failed");
        return false;
    }
    
    println!("  ✅ XOR passed");
    true
}

fn test_not() -> bool {
    println!("Testing NOT...");
    
    // Test: NOT 0 = MAX_U256
    let bytecode = vec![
        0x60, 0x00, // PUSH1 0
        0x19,       // NOT
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3,       // RETURN
    ];
    
    if !run_bytecode_and_check_stack(&bytecode, &[U256::MAX]) {
        println!("  ❌ NOT: NOT 0 failed");
        return false;
    }
    
    println!("  ✅ NOT passed");
    true
}

fn test_byte() -> bool {
    println!("Testing BYTE...");
    
    // Test: Get byte 31 (least significant) of 0xFF
    let bytecode = vec![
        0x60, 0xFF, // PUSH1 0xFF
        0x60, 0x1F, // PUSH1 31 (byte index)
        0x1A,       // BYTE
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3,       // RETURN
    ];
    
    if !run_bytecode_and_check_stack(&bytecode, &[U256::from(0xFF)]) {
        println!("  ❌ BYTE: byte 31 of 0xFF failed");
        return false;
    }
    
    println!("  ✅ BYTE passed");
    true
}

fn test_shl() -> bool {
    println!("Testing SHL...");
    
    // Test: 1 << 4 = 16
    let bytecode = vec![
        0x60, 0x01, // PUSH1 1
        0x60, 0x04, // PUSH1 4 (shift amount)
        0x1B,       // SHL
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3,       // RETURN
    ];
    
    if !run_bytecode_and_check_stack(&bytecode, &[U256::from(16)]) {
        println!("  ❌ SHL: 1 << 4 failed");
        return false;
    }
    
    println!("  ✅ SHL passed");
    true
}

fn test_shr() -> bool {
    println!("Testing SHR...");
    
    // Test: 16 >> 4 = 1
    let bytecode = vec![
        0x60, 0x10, // PUSH1 16
        0x60, 0x04, // PUSH1 4 (shift amount)
        0x1C,       // SHR
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3,       // RETURN
    ];
    
    if !run_bytecode_and_check_stack(&bytecode, &[U256::from(1)]) {
        println!("  ❌ SHR: 16 >> 4 failed");
        return false;
    }
    
    println!("  ✅ SHR passed");
    true
}

fn test_sar() -> bool {
    println!("Testing SAR (arithmetic shift right)...");
    
    // Test: -16 >> 4 = -1 (sign extended)
    let bytecode = vec![
        0x7F, // PUSH32
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xF0, // -16 in two's complement
        0x60, 0x04, // PUSH1 4 (shift amount)
        0x1D,       // SAR
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3,       // RETURN
    ];
    
    if !run_bytecode_and_check_stack(&bytecode, &[U256::MAX]) {
        println!("  ❌ SAR: -16 >> 4 failed");
        return false;
    }
    
    println!("  ✅ SAR passed");
    true
}