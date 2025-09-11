use revm::{
    Database,
    db::{CacheDB, EmptyDB},
    primitives::{
        Address, Bytecode, Bytes, ExecutionResult as RevmExecutionResult, U256, SpecId, Log,
    },
    Evm,
};
use keccak_asm::Digest;
use std::ffi::{c_char, CStr, CString};
use std::ptr;
use std::time::Instant;

#[cfg(test)]
mod trace_test;

/// Error codes for C interop
#[repr(C)]
pub enum RevmErrorCode {
    Success = 0,
    InvalidInput = 1,
    ExecutionError = 2,
    StateError = 3,
    MemoryError = 4,
    Unknown = 99,
}

/// Error structure for C interop
#[repr(C)]
pub struct RevmError {
    pub message: *mut c_char,
    pub code: i32,
}

impl RevmError {
    fn new(code: RevmErrorCode, message: String) -> *mut Self {
        let error = Box::new(RevmError {
            message: CString::new(message).unwrap().into_raw(),
            code: code as i32,
        });
        Box::into_raw(error)
    }
}

/// Settings for the REVM execution
#[repr(C)]
#[derive(Copy, Clone)]
pub struct RevmSettings {
    pub gas_limit: u64,
    pub chain_id: u64,
    pub block_number: u64,
    pub block_timestamp: u64,
    pub block_gas_limit: u64,
    pub block_difficulty: u64,
    pub block_basefee: u64,
    pub coinbase: [u8; 20],
}

impl Default for RevmSettings {
    fn default() -> Self {
        RevmSettings {
            gas_limit: 30_000_000,
            chain_id: 1,
            block_number: 0,
            block_timestamp: 0,
            block_gas_limit: 30_000_000,
            block_difficulty: 0,
            block_basefee: 0,
            coinbase: [0; 20],
        }
    }
}

/// Log entry for FFI
#[repr(C)]
pub struct FfiLog {
    pub address: [u8; 20],
    pub topics: *mut [u8; 32],
    pub topics_count: usize,
    pub data: *mut u8,
    pub data_len: usize,
}

/// Execution result from REVM
#[repr(C)]
pub struct ExecutionResult {
    pub success: bool,
    pub gas_used: u64,
    pub gas_refunded: u64,
    pub output_data: *mut u8,
    pub output_len: usize,
    pub logs: *mut FfiLog,
    pub logs_count: usize,
    pub revert_reason: *mut c_char,
}

/// Main REVM wrapper struct
pub struct RevmVm {
    db: CacheDB<EmptyDB>,
    settings: RevmSettings,
}

/// Create a new REVM instance
#[no_mangle]
pub unsafe extern "C" fn revm_new(
    settings: *const RevmSettings,
    out_error: *mut *mut RevmError,
) -> *mut RevmVm {
    *out_error = ptr::null_mut();

    if settings.is_null() {
        *out_error = RevmError::new(
            RevmErrorCode::InvalidInput,
            "Settings cannot be null".to_string(),
        );
        return ptr::null_mut();
    }

    let settings = *settings;
    let db = CacheDB::new(EmptyDB::default());

    let vm = Box::new(RevmVm { db, settings });

    Box::into_raw(vm)
}

/// Free a REVM instance
#[no_mangle]
pub unsafe extern "C" fn revm_free(vm: *mut RevmVm) {
    if !vm.is_null() {
        let _ = Box::from_raw(vm);
    }
}

/// Set account balance
#[no_mangle]
pub unsafe extern "C" fn revm_set_balance(
    vm: *mut RevmVm,
    address: *const u8,
    balance_hex: *const c_char,
    out_error: *mut *mut RevmError,
) -> i32 {
    *out_error = ptr::null_mut();

    if vm.is_null() || address.is_null() || balance_hex.is_null() {
        *out_error = RevmError::new(
            RevmErrorCode::InvalidInput,
            "Invalid input parameters".to_string(),
        );
        return 0;
    }

    let vm = &mut *vm;
    let addr_bytes = std::slice::from_raw_parts(address, 20);
    let addr = Address::from_slice(addr_bytes);

    let balance_str = match CStr::from_ptr(balance_hex).to_str() {
        Ok(s) => s,
        Err(_) => {
            *out_error = RevmError::new(
                RevmErrorCode::InvalidInput,
                "Invalid balance string encoding".to_string(),
            );
            return 0;
        }
    };

    let balance_str = balance_str.trim_start_matches("0x");
    let balance = match U256::from_str_radix(balance_str, 16) {
        Ok(b) => b,
        Err(_) => {
            *out_error = RevmError::new(
                RevmErrorCode::InvalidInput,
                "Invalid balance value".to_string(),
            );
            return 0;
        }
    };

    let account_info = revm::primitives::AccountInfo {
        balance,
        nonce: 0,
        code_hash: revm::primitives::KECCAK_EMPTY,
        code: None,
    };
    vm.db.insert_account_info(addr, account_info);

    1
}

/// Set account code
#[no_mangle]
pub unsafe extern "C" fn revm_set_code(
    vm: *mut RevmVm,
    address: *const u8,
    code_hex: *const c_char,
    out_error: *mut *mut RevmError,
) -> i32 {
    *out_error = ptr::null_mut();

    if vm.is_null() || address.is_null() || code_hex.is_null() {
        *out_error = RevmError::new(
            RevmErrorCode::InvalidInput,
            "Invalid input parameters".to_string(),
        );
        return 0;
    }

    let vm = &mut *vm;
    let addr_bytes = std::slice::from_raw_parts(address, 20);
    let addr = Address::from_slice(addr_bytes);

    let code_str = match CStr::from_ptr(code_hex).to_str() {
        Ok(s) => s,
        Err(_) => {
            *out_error = RevmError::new(
                RevmErrorCode::InvalidInput,
                "Invalid code string encoding".to_string(),
            );
            return 0;
        }
    };

    // eprintln!("REVM FFI: revm_set_code called with code_str: {}", code_str);
    
    let code_str = code_str.trim_start_matches("0x");
    let code_bytes = match hex::decode(code_str) {
        Ok(bytes) => bytes,
        Err(e) => {
            // eprintln!("REVM FFI: Failed to decode hex: {:?}", e);
            *out_error = RevmError::new(
                RevmErrorCode::InvalidInput,
                format!("Invalid hex code: {:?}", e),
            );
            return 0;
        }
    };

    let bytecode = Bytecode::new_raw(Bytes::from(code_bytes.clone()));
    let code_hash = revm::primitives::keccak256(&code_bytes);
    
    // Create account info with code
    let account_info = revm::primitives::AccountInfo {
        balance: U256::ZERO,
        nonce: 0,
        code_hash,
        code: Some(bytecode),
    };
    
    // Insert the account with code
    vm.db.insert_account_info(addr, account_info);
    
    // eprintln!("REVM FFI: Set code for {:?}, code_len: {}, code_hash: {:?}", addr, code_bytes.len(), code_hash);
    
    // Verify the code was set by checking the contracts map
    if !vm.db.contracts.contains_key(&code_hash) {
        panic!("REVM FFI: PANIC - Code not found in contracts map after setCode!");
    }

    1
}

/// Set storage value
#[no_mangle]
pub unsafe extern "C" fn revm_set_storage(
    vm: *mut RevmVm,
    address: *const u8,
    slot_hex: *const c_char,
    value_hex: *const c_char,
    out_error: *mut *mut RevmError,
) -> i32 {
    *out_error = ptr::null_mut();

    if vm.is_null() || address.is_null() || slot_hex.is_null() || value_hex.is_null() {
        *out_error = RevmError::new(
            RevmErrorCode::InvalidInput,
            "Invalid input parameters".to_string(),
        );
        return 0;
    }

    let vm = &mut *vm;
    let addr_bytes = std::slice::from_raw_parts(address, 20);
    let addr = Address::from_slice(addr_bytes);

    let slot_str = match CStr::from_ptr(slot_hex).to_str() {
        Ok(s) => s.trim_start_matches("0x"),
        Err(_) => {
            *out_error = RevmError::new(
                RevmErrorCode::InvalidInput,
                "Invalid slot string encoding".to_string(),
            );
            return 0;
        }
    };

    let value_str = match CStr::from_ptr(value_hex).to_str() {
        Ok(s) => s.trim_start_matches("0x"),
        Err(_) => {
            *out_error = RevmError::new(
                RevmErrorCode::InvalidInput,
                "Invalid value string encoding".to_string(),
            );
            return 0;
        }
    };

    let slot = match U256::from_str_radix(slot_str, 16) {
        Ok(s) => s,
        Err(_) => {
            *out_error = RevmError::new(
                RevmErrorCode::InvalidInput,
                "Invalid storage slot".to_string(),
            );
            return 0;
        }
    };

    let value = match U256::from_str_radix(value_str, 16) {
        Ok(v) => v,
        Err(_) => {
            *out_error = RevmError::new(
                RevmErrorCode::InvalidInput,
                "Invalid storage value".to_string(),
            );
            return 0;
        }
    };

    let _ = vm.db.insert_account_storage(addr, slot, value);

    1
}

/// Execute a transaction
#[no_mangle]
pub unsafe extern "C" fn revm_execute(
    vm: *mut RevmVm,
    from: *const u8,
    to: *const u8,
    value_hex: *const c_char,
    input_data: *const u8,
    input_len: usize,
    gas_limit: u64,
    out_result: *mut *mut ExecutionResult,
    out_error: *mut *mut RevmError,
) -> i32 {
    *out_error = ptr::null_mut();
    *out_result = ptr::null_mut();

    if vm.is_null() || from.is_null() {
        *out_error = RevmError::new(
            RevmErrorCode::InvalidInput,
            "Invalid input parameters".to_string(),
        );
        return 0;
    }

    let vm = &mut *vm;
    let from_bytes = std::slice::from_raw_parts(from, 20);
    let from_addr = Address::from_slice(from_bytes);

    let to_addr = if to.is_null() {
        None
    } else {
        let to_bytes = std::slice::from_raw_parts(to, 20);
        Some(Address::from_slice(to_bytes))
    };

    let value = if value_hex.is_null() {
        U256::ZERO
    } else {
        let value_str = match CStr::from_ptr(value_hex).to_str() {
            Ok(s) => s.trim_start_matches("0x"),
            Err(_) => {
                *out_error = RevmError::new(
                    RevmErrorCode::InvalidInput,
                    "Invalid value string encoding".to_string(),
                );
                return 0;
            }
        };

        match U256::from_str_radix(value_str, 16) {
            Ok(v) => v,
            Err(_) => {
                *out_error = RevmError::new(
                    RevmErrorCode::InvalidInput,
                    "Invalid value".to_string(),
                );
                return 0;
            }
        }
    };

    let input = if input_data.is_null() || input_len == 0 {
        Bytes::new()
    } else {
        let data = std::slice::from_raw_parts(input_data, input_len);
        Bytes::from(data.to_vec())
    };

    // Check if 'to' address has code
    // if let Some(to) = to_addr {
    //     let account = vm.db.basic(to).unwrap_or_default();
    //     eprintln!("REVM FFI: Account at {:?} has code: {}, code_hash: {:?}", 
    //         to, 
    //         account.as_ref().map(|a| a.code.is_some()).unwrap_or(false),
    //         account.as_ref().map(|a| a.code_hash).unwrap_or_default()
    //     );
    //     
    //     if let Some(acc_info) = account {
    //         if let Some(code) = &acc_info.code {
    //             eprintln!("REVM FFI: Code bytes len: {}", code.original_bytes().len());
    //         }
    //     }
    // }
    
    // Build and execute EVM
    let mut evm = Evm::builder()
        .with_db(&mut vm.db)
        .modify_block_env(|block| {
            block.number = U256::from(vm.settings.block_number);
            block.timestamp = U256::from(vm.settings.block_timestamp);
            block.gas_limit = U256::from(vm.settings.block_gas_limit);
            block.difficulty = U256::from(vm.settings.block_difficulty);
            block.basefee = U256::from(vm.settings.block_basefee);
            block.coinbase = Address::from_slice(&vm.settings.coinbase);
        })
        .modify_cfg_env(|cfg| {
            cfg.chain_id = vm.settings.chain_id;
            // spec_id is now set via with_spec_id method instead
        })
        .with_spec_id(SpecId::LATEST)
        .modify_tx_env(|tx| {
            tx.caller = from_addr;
            tx.transact_to = if let Some(to) = to_addr {
                revm::primitives::TxKind::Call(to)
            } else {
                revm::primitives::TxKind::Create
            };
            tx.value = value;
            tx.data = input.clone();
            tx.gas_limit = gas_limit;
            // Set gas price to at least base fee to avoid GasPriceLessThanBasefee error
            let base_fee = U256::from(vm.settings.block_basefee);
            tx.gas_price = if base_fee.is_zero() {
                // If no base fee, use 1 wei for contract creation, 0 for calls
                if to_addr.is_some() { 
                    U256::ZERO 
                } else { 
                    U256::from(1u64)
                }
            } else {
                // Use at least the base fee
                base_fee
            };
        })
        .build();

    // eprintln!("REVM FFI: About to execute transaction - from: {:?}, to: {:?}, value: {:?}, input_len: {}, gas_limit: {}", 
    //     from_addr, to_addr, value, input.len(), gas_limit);
    
    let result = match evm.transact_commit() {
        Ok(res) => res,
        Err(e) => {
            // eprintln!("REVM FFI: Transaction failed: {:?}", e);
            *out_error = RevmError::new(
                RevmErrorCode::ExecutionError,
                format!("Execution failed: {:?}", e),
            );
            return 0;
        }
    };
    
    // TODO: Extract actual logs from REVM 
    // For now, use empty logs to verify the pipeline works
    let logs: Vec<Log> = Vec::new();
    
    // eprintln!("REVM FFI: Transaction succeeded");
    // eprintln!("REVM FFI: Result type: {:?}", result);

    // Convert result
    let (success, gas_used, gas_refunded, output, revert_reason) = match result {
        RevmExecutionResult::Success {
            gas_used,
            gas_refunded,
            output,
            ..
        } => {
            let output_bytes = match output {
                revm::primitives::Output::Call(bytes) => {
                    // eprintln!("REVM FFI: Call output length: {}, bytes: {:?}", bytes.len(), bytes);
                    bytes
                },
                revm::primitives::Output::Create(bytes, _) => bytes,
            };
            (true, gas_used, gas_refunded, output_bytes, None)
        }
        RevmExecutionResult::Revert { gas_used, output } => {
            let reason = if output.len() > 4 {
                // Try to decode revert reason
                String::from_utf8_lossy(&output[4..]).to_string()
            } else {
                "Execution reverted".to_string()
            };
            (false, gas_used, 0, output, Some(reason))
        }
        RevmExecutionResult::Halt { reason, gas_used } => {
            let reason = format!("Execution halted: {:?}", reason);
            (false, gas_used, 0, Bytes::new(), Some(reason))
        }
    };

    // Convert logs to FFI format
    let (logs_ptr, logs_count) = if !logs.is_empty() {
        let mut ffi_logs = Vec::with_capacity(logs.len());
        for log in logs.iter() {
            // Allocate and convert topics
            let topics_ptr = if !log.topics().is_empty() {
                let mut topics = Vec::with_capacity(log.topics().len());
                for topic in log.topics() {
                    topics.push(topic.0);
                }
                let ptr = topics.as_mut_ptr();
                std::mem::forget(topics);
                ptr
            } else {
                ptr::null_mut()
            };
            
            // Allocate and convert data
            let data_vec = log.data.data.to_vec();
            let data_ptr = if !data_vec.is_empty() {
                let mut data = data_vec;
                let ptr = data.as_mut_ptr();
                std::mem::forget(data);
                ptr
            } else {
                ptr::null_mut()
            };
            
            ffi_logs.push(FfiLog {
                address: log.address.0.into(),
                topics: topics_ptr,
                topics_count: log.topics().len(),
                data: data_ptr,
                data_len: log.data.data.len(),
            });
        }
        let ptr = ffi_logs.as_mut_ptr();
        let len = ffi_logs.len();
        std::mem::forget(ffi_logs);
        (ptr, len)
    } else {
        (ptr::null_mut(), 0)
    };

    // Create result
    // eprintln!("REVM FFI: Creating result with output length: {}", output.len());
    let mut output_vec = output.to_vec();
    let output_ptr = if output_vec.is_empty() {
        ptr::null_mut()
    } else {
        let ptr = output_vec.as_mut_ptr();
        std::mem::forget(output_vec);
        ptr
    };

    let revert_ptr = revert_reason
        .and_then(|r| CString::new(r).ok())
        .map(|cstr| cstr.into_raw())
        .unwrap_or(ptr::null_mut());

    let exec_result = Box::new(ExecutionResult {
        success,
        gas_used,
        gas_refunded,
        output_data: output_ptr,
        output_len: output.len(),
        logs: logs_ptr,
        logs_count,
        revert_reason: revert_ptr,
    });

    *out_result = Box::into_raw(exec_result);
    1
}

/// Execute a transaction with tracing
#[no_mangle]
pub unsafe extern "C" fn revm_execute_with_trace(
    vm: *mut RevmVm,
    from: *const u8,
    to: *const u8,
    value_hex: *const c_char,
    input_data: *const u8,
    input_len: usize,
    gas_limit: u64,
    trace_path: *const c_char,
    out_result: *mut *mut ExecutionResult,
    out_error: *mut *mut RevmError,
) -> i32 {
    use revm::{inspector_handle_register, inspectors::TracerEip3155};
    use std::fs::File;
    use std::io::Write;
    
    *out_error = ptr::null_mut();
    *out_result = ptr::null_mut();

    if vm.is_null() || from.is_null() || trace_path.is_null() {
        *out_error = RevmError::new(
            RevmErrorCode::InvalidInput,
            "Invalid input parameters".to_string(),
        );
        return 0;
    }

    // Get trace file path
    let trace_path_str = match CStr::from_ptr(trace_path).to_str() {
        Ok(s) => s,
        Err(_) => {
            *out_error = RevmError::new(
                RevmErrorCode::InvalidInput,
                "Invalid trace path encoding".to_string(),
            );
            return 0;
        }
    };

    // Create trace file
    let mut trace_file = match File::create(trace_path_str) {
        Ok(f) => f,
        Err(e) => {
            *out_error = RevmError::new(
                RevmErrorCode::StateError,
                format!("Failed to create trace file: {}", e),
            );
            return 0;
        }
    };

    let vm = &mut *vm;
    let from_bytes = std::slice::from_raw_parts(from, 20);
    let from_addr = Address::from_slice(from_bytes);

    let to_addr = if to.is_null() {
        None
    } else {
        let to_bytes = std::slice::from_raw_parts(to, 20);
        Some(Address::from_slice(to_bytes))
    };

    let value = if value_hex.is_null() {
        U256::ZERO
    } else {
        let value_str = match CStr::from_ptr(value_hex).to_str() {
            Ok(s) => s.trim_start_matches("0x"),
            Err(_) => {
                *out_error = RevmError::new(
                    RevmErrorCode::InvalidInput,
                    "Invalid value string encoding".to_string(),
                );
                return 0;
            }
        };

        match U256::from_str_radix(value_str, 16) {
            Ok(v) => v,
            Err(_) => {
                *out_error = RevmError::new(
                    RevmErrorCode::InvalidInput,
                    "Invalid value".to_string(),
                );
                return 0;
            }
        }
    };

    let input = if input_data.is_null() || input_len == 0 {
        Bytes::new()
    } else {
        let data = std::slice::from_raw_parts(input_data, input_len);
        Bytes::from(data.to_vec())
    };
    
    // Create tracer
    let mut tracer = TracerEip3155::new(Box::new(trace_file.try_clone().unwrap()));
    
    // Build and execute EVM with tracer
    let mut evm = Evm::builder()
        .with_db(&mut vm.db)
        .with_external_context(&mut tracer)
        .append_handler_register(inspector_handle_register)
        .modify_block_env(|block| {
            block.number = U256::from(vm.settings.block_number);
            block.timestamp = U256::from(vm.settings.block_timestamp);
            block.gas_limit = U256::from(vm.settings.block_gas_limit);
            block.difficulty = U256::from(vm.settings.block_difficulty);
            block.basefee = U256::from(vm.settings.block_basefee);
            block.coinbase = Address::from_slice(&vm.settings.coinbase);
        })
        .modify_cfg_env(|cfg| {
            cfg.chain_id = vm.settings.chain_id;
            // spec_id is now set via with_spec_id method instead
        })
        .with_spec_id(SpecId::LATEST)
        .modify_tx_env(|tx| {
            tx.caller = from_addr;
            tx.transact_to = if let Some(to) = to_addr {
                revm::primitives::TxKind::Call(to)
            } else {
                revm::primitives::TxKind::Create
            };
            tx.value = value;
            tx.data = input.clone();
            tx.gas_limit = gas_limit;
            // Set gas price to at least base fee to avoid GasPriceLessThanBasefee error
            let base_fee = U256::from(vm.settings.block_basefee);
            tx.gas_price = if base_fee.is_zero() {
                // If no base fee, use 1 wei for contract creation, 0 for calls
                if to_addr.is_some() { 
                    U256::ZERO 
                } else { 
                    U256::from(1u64)
                }
            } else {
                // Use at least the base fee
                base_fee
            };
        })
        .build();
    
    let result = match evm.transact_commit() {
        Ok(res) => res,
        Err(e) => {
            // Write error to trace file
            let _ = writeln!(trace_file, "# Execution failed: {:?}", e);
            *out_error = RevmError::new(
                RevmErrorCode::ExecutionError,
                format!("Execution failed: {:?}", e),
            );
            return 0;
        }
    };
    
    // TODO: Extract actual logs from REVM
    // For now, use empty logs to verify the pipeline works  
    let logs: Vec<Log> = Vec::new();

    // Ensure trace is flushed
    let _ = trace_file.flush();

    // Convert result (same as regular execute)
    let (success, gas_used, gas_refunded, output, revert_reason) = match result {
        RevmExecutionResult::Success {
            gas_used,
            gas_refunded,
            output,
            ..
        } => {
            let output_bytes = match output {
                revm::primitives::Output::Call(bytes) => bytes,
                revm::primitives::Output::Create(bytes, _) => bytes,
            };
            (true, gas_used, gas_refunded, output_bytes, None)
        }
        RevmExecutionResult::Revert { gas_used, output } => {
            let reason = if output.len() > 4 {
                String::from_utf8_lossy(&output[4..]).to_string()
            } else {
                "Execution reverted".to_string()
            };
            (false, gas_used, 0, output, Some(reason))
        }
        RevmExecutionResult::Halt { reason, gas_used } => {
            let reason = format!("Execution halted: {:?}", reason);
            (false, gas_used, 0, Bytes::new(), Some(reason))
        }
    };

    // Convert logs to FFI format
    let (logs_ptr, logs_count) = if !logs.is_empty() {
        let mut ffi_logs = Vec::with_capacity(logs.len());
        for log in logs.iter() {
            // Allocate and convert topics
            let topics_ptr = if !log.topics().is_empty() {
                let mut topics = Vec::with_capacity(log.topics().len());
                for topic in log.topics() {
                    topics.push(topic.0);
                }
                let ptr = topics.as_mut_ptr();
                std::mem::forget(topics);
                ptr
            } else {
                ptr::null_mut()
            };
            
            // Allocate and convert data
            let data_vec = log.data.data.to_vec();
            let data_ptr = if !data_vec.is_empty() {
                let mut data = data_vec;
                let ptr = data.as_mut_ptr();
                std::mem::forget(data);
                ptr
            } else {
                ptr::null_mut()
            };
            
            ffi_logs.push(FfiLog {
                address: log.address.0.into(),
                topics: topics_ptr,
                topics_count: log.topics().len(),
                data: data_ptr,
                data_len: log.data.data.len(),
            });
        }
        let ptr = ffi_logs.as_mut_ptr();
        let len = ffi_logs.len();
        std::mem::forget(ffi_logs);
        (ptr, len)
    } else {
        (ptr::null_mut(), 0)
    };

    // Create result
    let mut output_vec = output.to_vec();
    let output_ptr = if output_vec.is_empty() {
        ptr::null_mut()
    } else {
        let ptr = output_vec.as_mut_ptr();
        std::mem::forget(output_vec);
        ptr
    };

    let revert_ptr = revert_reason
        .and_then(|r| CString::new(r).ok())
        .map(|cstr| cstr.into_raw())
        .unwrap_or(ptr::null_mut());

    let exec_result = Box::new(ExecutionResult {
        success,
        gas_used,
        gas_refunded,
        output_data: output_ptr,
        output_len: output.len(),
        logs: logs_ptr,
        logs_count,
        revert_reason: revert_ptr,
    });

    *out_result = Box::into_raw(exec_result);
    1
}

/// Get error message
#[no_mangle]
pub unsafe extern "C" fn revm_get_error_message(error: *const RevmError) -> *const c_char {
    if error.is_null() {
        return ptr::null();
    }
    (*error).message
}

/// Free an error
#[no_mangle]
pub unsafe extern "C" fn revm_free_error(error: *mut RevmError) {
    if !error.is_null() {
        let error = Box::from_raw(error);
        if !error.message.is_null() {
            let _ = CString::from_raw(error.message);
        }
    }
}

/// Free an execution result
#[no_mangle]
pub unsafe extern "C" fn revm_free_result(result: *mut ExecutionResult) {
    if !result.is_null() {
        let result = Box::from_raw(result);
        if !result.output_data.is_null() {
            let _ = Vec::from_raw_parts(result.output_data, result.output_len, result.output_len);
        }
        if !result.revert_reason.is_null() {
            let _ = CString::from_raw(result.revert_reason);
        }
    }
}

/// Get storage value
#[no_mangle]
pub unsafe extern "C" fn revm_get_storage(
    vm: *mut RevmVm,
    address: *const u8,
    slot_hex: *const c_char,
    out_value: *mut c_char,
    out_value_len: usize,
    out_error: *mut *mut RevmError,
) -> i32 {
    *out_error = ptr::null_mut();

    if vm.is_null() || address.is_null() || slot_hex.is_null() || out_value.is_null() {
        *out_error = RevmError::new(
            RevmErrorCode::InvalidInput,
            "Invalid input parameters".to_string(),
        );
        return 0;
    }

    let vm = &mut *vm;
    let addr_bytes = std::slice::from_raw_parts(address, 20);
    let addr = Address::from_slice(addr_bytes);

    let slot_str = match CStr::from_ptr(slot_hex).to_str() {
        Ok(s) => s.trim_start_matches("0x"),
        Err(_) => {
            *out_error = RevmError::new(
                RevmErrorCode::InvalidInput,
                "Invalid slot string encoding".to_string(),
            );
            return 0;
        }
    };

    let slot = match U256::from_str_radix(slot_str, 16) {
        Ok(s) => s,
        Err(_) => {
            *out_error = RevmError::new(
                RevmErrorCode::InvalidInput,
                "Invalid storage slot".to_string(),
            );
            return 0;
        }
    };

    let db = &mut vm.db;
    let value = db.storage(addr, slot).unwrap_or_default();
    let value_hex = format!("0x{:064x}", value);

    if value_hex.len() + 1 > out_value_len {
        *out_error = RevmError::new(
            RevmErrorCode::MemoryError,
            "Output buffer too small".to_string(),
        );
        return 0;
    }

    let c_value = CString::new(value_hex).unwrap();
    let bytes = c_value.as_bytes_with_nul();
    std::ptr::copy_nonoverlapping(bytes.as_ptr() as *const c_char, out_value, bytes.len());

    1
}

/// Get account balance
#[no_mangle]
pub unsafe extern "C" fn revm_get_balance(
    vm: *mut RevmVm,
    address: *const u8,
    out_balance: *mut c_char,
    out_balance_len: usize,
    out_error: *mut *mut RevmError,
) -> i32 {
    *out_error = ptr::null_mut();

    if vm.is_null() || address.is_null() || out_balance.is_null() {
        *out_error = RevmError::new(
            RevmErrorCode::InvalidInput,
            "Invalid input parameters".to_string(),
        );
        return 0;
    }

    let vm = &mut *vm;
    let addr_bytes = std::slice::from_raw_parts(address, 20);
    let addr = Address::from_slice(addr_bytes);

    let db = &mut vm.db;
    let account_info = db.basic(addr).unwrap_or_default().unwrap_or_default();
    let balance_hex = format!("0x{:064x}", account_info.balance);

    if balance_hex.len() + 1 > out_balance_len {
        *out_error = RevmError::new(
            RevmErrorCode::MemoryError,
            "Output buffer too small".to_string(),
        );
        return 0;
    }

    let c_balance = CString::new(balance_hex).unwrap();
    let bytes = c_balance.as_bytes_with_nul();
    std::ptr::copy_nonoverlapping(bytes.as_ptr() as *const c_char, out_balance, bytes.len());

    1
}

/// Benchmark result containing execution time and success status
pub struct BenchmarkResult {
    pub success: bool,
    pub execution_time_micros: f64,
    pub gas_used: u64,
    pub output: Bytes,
    pub error_message: Option<String>,
}

/// Run a benchmark on contract bytecode with calldata
/// 
/// This function creates a contract, deploys it, and then calls it with the provided calldata.
/// It returns timing information and execution results.
pub fn benchmark_contract_execution(
    contract_code: &[u8],
    calldata: &[u8],
    num_runs: u8,
) -> Vec<BenchmarkResult> {
    let mut results = Vec::with_capacity(num_runs as usize);
    
    let caller_address = Address::from_slice(&[0x10; 20]); // Fixed caller address
    let mut db = CacheDB::new(EmptyDB::default());
    
    // Set up caller with balance
    let caller_info = revm::primitives::AccountInfo {
        balance: U256::from(1_000_000_000_000_000_000u64), // 1 ETH
        nonce: 0,
        code_hash: revm::primitives::KECCAK_EMPTY,
        code: None,
    };
    db.insert_account_info(caller_address, caller_info);
    
    // Deploy the contract first
    let contract_address = match deploy_contract(&mut db, caller_address, contract_code) {
        Ok(addr) => addr,
        Err(e) => {
            // Return error results for all runs
            for _ in 0..num_runs {
                results.push(BenchmarkResult {
                    success: false,
                    execution_time_micros: 0.0,
                    gas_used: 0,
                    output: Bytes::new(),
                    error_message: Some(e.clone()),
                });
            }
            return results;
        }
    };
    
    // Run the benchmark num_runs times
    for _ in 0..num_runs {
        let timer = Instant::now();
        
        let mut evm = Evm::builder()
            .with_db(&mut db)
            .modify_tx_env(|tx| {
                tx.caller = caller_address;
                tx.transact_to = revm::primitives::TxKind::Call(contract_address);
                tx.value = U256::ZERO;
                tx.data = Bytes::from(calldata.to_vec());
                tx.gas_limit = 1_000_000;
                tx.gas_price = U256::from(0u64);
            })
            .build();
            
        let exec_result = evm.transact_commit();
        let execution_time = timer.elapsed().as_micros() as f64 / 1e3; // Convert to milliseconds
        
        match exec_result {
            Ok(RevmExecutionResult::Success {
                gas_used,
                output,
                ..
            }) => {
                let output_bytes = match output {
                    revm::primitives::Output::Call(bytes) => bytes,
                    revm::primitives::Output::Create(bytes, _) => bytes,
                };
                
                results.push(BenchmarkResult {
                    success: true,
                    execution_time_micros: execution_time,
                    gas_used,
                    output: output_bytes,
                    error_message: None,
                });
            }
            Ok(RevmExecutionResult::Revert { gas_used, output }) => {
                let reason = if output.len() > 4 {
                    String::from_utf8_lossy(&output[4..]).to_string()
                } else {
                    "Execution reverted".to_string()
                };
                
                results.push(BenchmarkResult {
                    success: false,
                    execution_time_micros: execution_time,
                    gas_used,
                    output,
                    error_message: Some(reason),
                });
            }
            Ok(RevmExecutionResult::Halt { reason, gas_used }) => {
                results.push(BenchmarkResult {
                    success: false,
                    execution_time_micros: execution_time,
                    gas_used,
                    output: Bytes::new(),
                    error_message: Some(format!("Execution halted: {:?}", reason)),
                });
            }
            Err(e) => {
                results.push(BenchmarkResult {
                    success: false,
                    execution_time_micros: execution_time,
                    gas_used: 0,
                    output: Bytes::new(),
                    error_message: Some(format!("Execution failed: {:?}", e)),
                });
            }
        }
    }
    
    results
}

/// Deploy a contract and return its address
fn deploy_contract(
    db: &mut CacheDB<EmptyDB>,
    caller: Address,
    bytecode: &[u8],
) -> Result<Address, String> {
    let mut evm = Evm::builder()
        .with_db(db)
        .modify_tx_env(|tx| {
            tx.caller = caller;
            tx.transact_to = revm::primitives::TxKind::Create;
            tx.value = U256::ZERO;
            tx.data = Bytes::from(bytecode.to_vec());
            tx.gas_limit = u64::MAX;
            tx.gas_price = U256::from(1u64);
        })
        .build();
        
    match evm.transact_commit() {
        Ok(RevmExecutionResult::Success { output, .. }) => {
            match output {
                revm::primitives::Output::Create(_, Some(address)) => Ok(address),
                _ => Err("Contract creation failed - no address returned".to_string()),
            }
        }
        Ok(RevmExecutionResult::Revert { output, .. }) => {
            let reason = if output.len() > 4 {
                String::from_utf8_lossy(&output[4..]).to_string()
            } else {
                "Contract creation reverted".to_string()
            };
            Err(reason)
        }
        Ok(RevmExecutionResult::Halt { reason, .. }) => {
            Err(format!("Contract creation halted: {:?}", reason))
        }
        Err(e) => Err(format!("Contract creation failed: {:?}", e)),
    }
}

/// KECCAK256 hash using assembly-optimized implementation
/// 
/// This function provides a high-performance KECCAK256 hash using the assembly-optimized
/// keccak-asm crate, which is significantly faster than the standard library implementation.
#[no_mangle]
pub unsafe extern "C" fn keccak256_asm(
    data_ptr: *const u8,
    data_len: usize,
    out_hash: *mut u8, // Must be exactly 32 bytes
    out_error: *mut *mut RevmError,
) -> i32 {
    *out_error = ptr::null_mut();

    if data_ptr.is_null() && data_len > 0 {
        *out_error = RevmError::new(
            RevmErrorCode::InvalidInput,
            "Data pointer cannot be null with non-zero length".to_string(),
        );
        return 0;
    }

    if out_hash.is_null() {
        *out_error = RevmError::new(
            RevmErrorCode::InvalidInput,
            "Output hash pointer cannot be null".to_string(),
        );
        return 0;
    }

    let data = if data_len == 0 {
        &[]
    } else {
        std::slice::from_raw_parts(data_ptr, data_len)
    };

    let hash = keccak_asm::Keccak256::digest(data);
    
    // Copy hash to output buffer
    std::ptr::copy_nonoverlapping(hash.as_ptr(), out_hash, 32);

    1
}

/// Batch KECCAK256 hash multiple inputs using assembly optimization
/// 
/// This function hashes multiple inputs in a single call, which can be more efficient
/// than calling keccak256_asm multiple times due to reduced FFI overhead.
#[no_mangle]
pub unsafe extern "C" fn keccak256_asm_batch(
    inputs_ptr: *const *const u8,      // Array of data pointers
    inputs_len: *const usize,          // Array of data lengths
    num_inputs: usize,
    out_hashes: *mut u8,               // Buffer for output hashes (32 * num_inputs bytes)
    out_error: *mut *mut RevmError,
) -> i32 {
    *out_error = ptr::null_mut();

    if inputs_ptr.is_null() || inputs_len.is_null() || out_hashes.is_null() {
        *out_error = RevmError::new(
            RevmErrorCode::InvalidInput,
            "Input arrays and output buffer cannot be null".to_string(),
        );
        return 0;
    }

    if num_inputs == 0 {
        return 1; // Success, no work to do
    }

    let input_ptrs = std::slice::from_raw_parts(inputs_ptr, num_inputs);
    let input_lens = std::slice::from_raw_parts(inputs_len, num_inputs);
    
    for i in 0..num_inputs {
        let data = if input_lens[i] == 0 {
            &[]
        } else {
            if input_ptrs[i].is_null() {
                *out_error = RevmError::new(
                    RevmErrorCode::InvalidInput,
                    format!("Input {} pointer cannot be null with non-zero length", i),
                );
                return 0;
            }
            std::slice::from_raw_parts(input_ptrs[i], input_lens[i])
        };

        let hash = keccak_asm::Keccak256::digest(data);
        
        // Copy hash to output buffer at correct offset
        let output_offset = i * 32;
        std::ptr::copy_nonoverlapping(
            hash.as_ptr(),
            out_hashes.add(output_offset),
            32
        );
    }

    1
}

/// Convenience function to hash a hex string and return the result as hex
/// 
/// This is useful for testing and situations where you have hex-encoded data.
#[no_mangle]
pub unsafe extern "C" fn keccak256_hex(
    hex_input: *const c_char,
    out_hex_hash: *mut c_char,
    out_hex_len: usize,                // Must be at least 67 bytes (0x + 64 chars + null)
    out_error: *mut *mut RevmError,
) -> i32 {
    *out_error = ptr::null_mut();

    if hex_input.is_null() || out_hex_hash.is_null() {
        *out_error = RevmError::new(
            RevmErrorCode::InvalidInput,
            "Input and output cannot be null".to_string(),
        );
        return 0;
    }

    if out_hex_len < 67 {
        *out_error = RevmError::new(
            RevmErrorCode::InvalidInput,
            "Output buffer must be at least 67 bytes".to_string(),
        );
        return 0;
    }

    let hex_str = match CStr::from_ptr(hex_input).to_str() {
        Ok(s) => s,
        Err(_) => {
            *out_error = RevmError::new(
                RevmErrorCode::InvalidInput,
                "Invalid hex string encoding".to_string(),
            );
            return 0;
        }
    };

    let hex_str = hex_str.trim_start_matches("0x");
    let data = match hex::decode(hex_str) {
        Ok(bytes) => bytes,
        Err(e) => {
            *out_error = RevmError::new(
                RevmErrorCode::InvalidInput,
                format!("Invalid hex data: {:?}", e),
            );
            return 0;
        }
    };

    let hash = keccak_asm::Keccak256::digest(&data);
    let hash_hex = format!("0x{}", hex::encode(hash));

    if hash_hex.len() + 1 > out_hex_len {
        *out_error = RevmError::new(
            RevmErrorCode::MemoryError,
            "Output buffer too small".to_string(),
        );
        return 0;
    }

    let c_hash = CString::new(hash_hex).unwrap();
    let bytes = c_hash.as_bytes_with_nul();
    std::ptr::copy_nonoverlapping(bytes.as_ptr() as *const c_char, out_hex_hash, bytes.len());

    1
}

/// Free logs from execution result
#[no_mangle]
pub unsafe extern "C" fn revm_free_logs(logs: *mut FfiLog, count: usize) {
    if logs.is_null() || count == 0 {
        return;
    }
    
    for i in 0..count {
        let log = &*logs.add(i);
        if !log.topics.is_null() && log.topics_count > 0 {
            Vec::from_raw_parts(log.topics, log.topics_count, log.topics_count);
        }
        if !log.data.is_null() && log.data_len > 0 {
            Vec::from_raw_parts(log.data, log.data_len, log.data_len);
        }
    }
    Vec::from_raw_parts(logs, count, count);
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CString;
    
    #[test] 
    fn test_set_code() {
        unsafe {
            // Create a new VM
            let settings = RevmSettings::default();
            let mut error_ptr: *mut RevmError = ptr::null_mut();
            let vm_ptr = revm_new(&settings, &mut error_ptr);
            assert!(!vm_ptr.is_null());
            assert!(error_ptr.is_null());
            
            // Set up test data
            let address = [0x33u8; 20];
            let code_hex = CString::new("0x604260005260206000f3").unwrap();
            
            // Call revm_set_code
            let result = revm_set_code(
                vm_ptr,
                address.as_ptr(),
                code_hex.as_ptr(),
                &mut error_ptr
            );
            
            // Should succeed
            assert_eq!(result, 1);
            assert!(error_ptr.is_null());
            
            // Now check if we can retrieve the code
            let vm = &mut *vm_ptr;
            let addr = Address::from_slice(&address);
            let account = vm.db.basic(addr).unwrap();
            
            println!("Account after setCode: {:?}", account);
            assert!(account.is_some(), "Account should exist after setCode");
            
            let account = account.unwrap();
            assert!(account.code.is_some(), "Account should have code");
            assert_ne!(account.code_hash, revm::primitives::KECCAK_EMPTY, "Code hash should not be empty");
            
            // Clean up
            revm_free(vm_ptr);
        }
    }

    #[test]
    fn test_revm_creation() {
        unsafe {
            let settings = RevmSettings::default();
            let mut error: *mut RevmError = ptr::null_mut();

            let vm = revm_new(&settings, &mut error);
            assert!(!vm.is_null());
            assert!(error.is_null());

            revm_free(vm);
        }
    }

    #[test]
    fn test_set_and_get_balance() {
        unsafe {
            let settings = RevmSettings::default();
            let mut error: *mut RevmError = ptr::null_mut();

            let vm = revm_new(&settings, &mut error);
            assert!(!vm.is_null());

            let address = [1u8; 20];
            let balance = CString::new("0x1234567890abcdef").unwrap();

            let success = revm_set_balance(vm, address.as_ptr(), balance.as_ptr(), &mut error);
            assert_eq!(success, 1);
            assert!(error.is_null());

            let mut out_balance = [0u8; 100];
            let success = revm_get_balance(
                vm,
                address.as_ptr(),
                out_balance.as_mut_ptr() as *mut c_char,
                out_balance.len(),
                &mut error,
            );
            assert_eq!(success, 1);
            assert!(error.is_null());

            let result = CStr::from_ptr(out_balance.as_ptr() as *const c_char)
                .to_str()
                .unwrap();
            assert_eq!(
                result,
                "0x0000000000000000000000000000000000000000000000001234567890abcdef"
            );

            revm_free(vm);
        }
    }

    #[test]
    fn test_benchmark_contract_execution() {
        // Simple contract that just returns 0x42
        // PUSH1 0x42, PUSH1 0x00, MSTORE, PUSH1 0x20, PUSH1 0x00, RETURN
        let contract_code = hex::decode("604260005260206000f3").unwrap();
        let calldata = hex::decode("").unwrap(); // Empty calldata
        
        let results = benchmark_contract_execution(&contract_code, &calldata, 3);
        
        assert_eq!(results.len(), 3);
        for result in results {
            assert!(result.success, "Benchmark should succeed: {:?}", result.error_message);
            assert!(result.execution_time_micros >= 0.0, "Execution time should be non-negative");
            assert!(result.gas_used > 0, "Gas should be consumed");
        }
    }

    #[test]
    fn test_keccak256_asm() {
        unsafe {
            // Test empty string hash
            let empty_data: &[u8] = &[];
            let mut hash_out = [0u8; 32];
            let mut error_ptr: *mut RevmError = ptr::null_mut();
            
            let result = keccak256_asm(
                empty_data.as_ptr(),
                empty_data.len(),
                hash_out.as_mut_ptr(),
                &mut error_ptr
            );
            
            assert_eq!(result, 1);
            assert!(error_ptr.is_null());
            
            // Expected hash for empty string
            let expected = hex::decode("c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470").unwrap();
            assert_eq!(hash_out.to_vec(), expected);
            
            // Test "Hello" string hash
            let hello_data = b"Hello";
            let result = keccak256_asm(
                hello_data.as_ptr(),
                hello_data.len(),
                hash_out.as_mut_ptr(),
                &mut error_ptr
            );
            
            assert_eq!(result, 1);
            assert!(error_ptr.is_null());
            
            // Expected hash for "Hello"
            let expected_hello = hex::decode("06b3dfaec148fb1bb2b066f10ec285e7c9bf402ab32aa78a5d38e34566810cd2").unwrap();
            assert_eq!(hash_out.to_vec(), expected_hello);
        }
    }

    #[test]
    fn test_keccak256_hex() {
        unsafe {
            let input = CString::new("48656c6c6f").unwrap(); // "Hello" in hex
            let mut output = [0u8; 67];
            let mut error_ptr: *mut RevmError = ptr::null_mut();
            
            let result = keccak256_hex(
                input.as_ptr(),
                output.as_mut_ptr() as *mut c_char,
                output.len(),
                &mut error_ptr
            );
            
            assert_eq!(result, 1);
            assert!(error_ptr.is_null());
            
            let result_str = CStr::from_ptr(output.as_ptr() as *const c_char).to_str().unwrap();
            assert_eq!(result_str, "0x06b3dfaec148fb1bb2b066f10ec285e7c9bf402ab32aa78a5d38e34566810cd2");
        }
    }

    #[test]
    fn test_keccak256_asm_batch() {
        unsafe {
            // Test data
            let data1 = b"Hello";
            let data2 = b"World";
            let data3: &[u8] = &[];
            
            // Set up input arrays
            let input_ptrs = [data1.as_ptr(), data2.as_ptr(), data3.as_ptr()];
            let input_lens = [data1.len(), data2.len(), data3.len()];
            let mut output_hashes = [0u8; 96]; // 3 * 32 bytes
            let mut error_ptr: *mut RevmError = ptr::null_mut();
            
            let result = keccak256_asm_batch(
                input_ptrs.as_ptr(),
                input_lens.as_ptr(),
                3,
                output_hashes.as_mut_ptr(),
                &mut error_ptr
            );
            
            assert_eq!(result, 1);
            assert!(error_ptr.is_null());
            
            // Verify individual hashes by computing them individually first
            let mut expected_hello = [0u8; 32];
            let mut expected_world = [0u8; 32];
            let mut expected_empty = [0u8; 32];
            let mut error_ptr: *mut RevmError = ptr::null_mut();
            
            // Get expected hash for "Hello"
            let result1 = keccak256_asm(data1.as_ptr(), data1.len(), expected_hello.as_mut_ptr(), &mut error_ptr);
            assert_eq!(result1, 1);
            assert!(error_ptr.is_null());
            
            // Get expected hash for "World"
            let result2 = keccak256_asm(data2.as_ptr(), data2.len(), expected_world.as_mut_ptr(), &mut error_ptr);
            assert_eq!(result2, 1);
            assert!(error_ptr.is_null());
            
            // Get expected hash for empty
            let result3 = keccak256_asm(data3.as_ptr(), data3.len(), expected_empty.as_mut_ptr(), &mut error_ptr);
            assert_eq!(result3, 1);
            assert!(error_ptr.is_null());
            
            assert_eq!(&output_hashes[0..32], expected_hello.as_slice());
            assert_eq!(&output_hashes[32..64], expected_world.as_slice());
            assert_eq!(&output_hashes[64..96], expected_empty.as_slice());
        }
    }
}