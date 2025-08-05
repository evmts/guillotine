# Phase 0: Critical System Operations Fixes

## Objective
Fix critical broken functionality in CALL operations and CREATE operations that currently prevent the EVM from executing real contracts. These must work before we can properly benchmark the advanced interpreter.

## Priority
**CRITICAL** - These operations are fundamental to EVM functionality. Without them:
- Cannot call other contracts (breaks DeFi, proxies, everything)
- Cannot deploy new contracts (breaks development workflow)
- Cannot properly benchmark real-world contracts

## Current State (From Status Report)

### CALL Family Status
- **CALL**: Precompiles work, regular contracts fail
- **CALLCODE**: Returns failure with TODO
- **DELEGATECALL**: Preserves context but doesn't execute
- **STATICCALL**: Structure exists but returns failure

### CREATE Family Status
- **CREATE**: Basic structure exists, deployment logic missing
- **CREATE2**: Basic structure exists, needs full implementation
- **SELFDESTRUCT**: Only validates, doesn't execute destruction

## Implementation Requirements

### Part A: Fix DELEGATECALL
This is the most critical as it's used by all proxy contracts.

```zig
// src/evm/execution/system.zig
pub fn op_delegatecall(frame: *Frame) !void {
    const gas = try frame.stack.pop();
    const address = try frame.stack.pop();
    const args_offset = try frame.stack.pop();
    const args_size = try frame.stack.pop();
    const ret_offset = try frame.stack.pop();
    const ret_size = try frame.stack.pop();
    
    // DELEGATECALL preserves msg.sender and msg.value from parent
    const call_frame = try Frame.init(
        frame.interpreter,
        @intCast(u64, gas),
        frame.contract,  // Use parent contract's storage
        address,         // Code from target
        frame.msg.sender, // Preserve original sender
        frame.msg.value,  // Preserve original value
        args_data,
        .DelegateCall,
    );
    
    // Execute and handle result
    try frame.interpreter.execute(call_frame);
    
    // Handle return data
    frame.return_data = call_frame.return_data;
    frame.memory.write(ret_offset, frame.return_data[0..@min(ret_size, frame.return_data.len)]);
    
    // Push success
    try frame.stack.push(if (call_frame.success) 1 else 0);
}
```

### Part B: Fix STATICCALL
Required for read-only calls (view functions).

```zig
pub fn op_staticcall(frame: *Frame) !void {
    const gas = try frame.stack.pop();
    const address = try frame.stack.pop();
    const args_offset = try frame.stack.pop();
    const args_size = try frame.stack.pop();
    const ret_offset = try frame.stack.pop();
    const ret_size = try frame.stack.pop();
    
    // Create static call frame
    const call_frame = try Frame.init(
        frame.interpreter,
        @intCast(u64, gas),
        contract,
        address,
        frame.contract.address,
        0, // No value in static calls
        args_data,
        .StaticCall,
    );
    
    // Set static flag to prevent state modifications
    call_frame.is_static = true;
    
    // Execute
    try frame.interpreter.execute(call_frame);
    
    // Handle return
    frame.return_data = call_frame.return_data;
    frame.memory.write(ret_offset, frame.return_data[0..@min(ret_size, frame.return_data.len)]);
    
    try frame.stack.push(if (call_frame.success) 1 else 0);
}
```

### Part C: Fix CREATE Operations
Enable contract deployment.

```zig
pub fn op_create(frame: *Frame) !void {
    const value = try frame.stack.pop();
    const offset = try frame.stack.pop();
    const size = try frame.stack.pop();
    
    // Check static context
    if (frame.is_static) return error.StateModificationInStatic;
    
    // Get init code
    const init_code = frame.memory.read(@intCast(usize, offset), @intCast(usize, size));
    
    // Calculate new address
    const nonce = frame.state.getNonce(frame.contract.address);
    const new_address = calculateContractAddress(frame.contract.address, nonce);
    
    // Check if address already exists
    if (frame.state.accountExists(new_address)) {
        try frame.stack.push(0);
        return;
    }
    
    // Increment nonce
    frame.state.incrementNonce(frame.contract.address);
    
    // Create new account
    frame.state.createAccount(new_address, value);
    
    // Create frame for init code execution
    const create_frame = try Frame.init(
        frame.interpreter,
        frame.gas_remaining * 63 / 64, // EIP-150
        Contract.init(init_code, new_address),
        new_address,
        frame.contract.address,
        value,
        &[_]u8{},
        .Create,
    );
    
    // Execute init code
    try frame.interpreter.execute(create_frame);
    
    if (create_frame.success) {
        // Store deployed code
        frame.state.setCode(new_address, create_frame.return_data);
        try frame.stack.push(@intCast(u256, new_address));
    } else {
        // Revert account creation
        frame.state.deleteAccount(new_address);
        try frame.stack.push(0);
    }
}

pub fn op_create2(frame: *Frame) !void {
    const value = try frame.stack.pop();
    const offset = try frame.stack.pop();
    const size = try frame.stack.pop();
    const salt = try frame.stack.pop();
    
    // Similar to CREATE but use CREATE2 address calculation
    const init_code = frame.memory.read(@intCast(usize, offset), @intCast(usize, size));
    const new_address = calculateCreate2Address(frame.contract.address, salt, init_code);
    
    // Rest similar to CREATE...
}
```

### Part D: Complete SELFDESTRUCT
```zig
pub fn op_selfdestruct(frame: *Frame) !void {
    if (frame.is_static) return error.StateModificationInStatic;
    
    const beneficiary = Address.fromU256(try frame.stack.pop());
    
    // Transfer balance to beneficiary
    const balance = frame.state.getBalance(frame.contract.address);
    frame.state.transfer(frame.contract.address, beneficiary, balance);
    
    // Mark for destruction (actual deletion happens after transaction)
    frame.state.markForDestruction(frame.contract.address);
    
    // Stop execution
    frame.status = .Stop;
}
```

## Testing Requirements

### Integration Tests
```zig
test "DELEGATECALL preserves context" {
    // Deploy caller and callee contracts
    // Caller uses DELEGATECALL to callee
    // Verify msg.sender and storage context preserved
}

test "STATICCALL prevents state changes" {
    // Call contract that attempts SSTORE
    // Verify call fails with StateModificationInStatic
}

test "CREATE deploys new contract" {
    // Deploy factory contract
    // Call factory to create child
    // Verify child contract exists and is callable
}

test "CREATE2 deterministic addressing" {
    // Deploy with same salt twice
    // Verify second deployment fails (address exists)
}
```

### Official Test Vectors
Run against ethereum/tests for:
- GeneralStateTests/stCallCodes
- GeneralStateTests/stCallDelegateCodesCallCodeHomestead  
- GeneralStateTests/stCallCreateCallCodeTest
- GeneralStateTests/stCreate2
- GeneralStateTests/stSelfBalance

## Success Criteria

- [ ] All CALL variants work with regular contracts
- [ ] Proxy patterns using DELEGATECALL function correctly
- [ ] CREATE can deploy contracts that are then callable
- [ ] CREATE2 produces deterministic addresses
- [ ] SELFDESTRUCT properly destroys contracts
- [ ] All relevant ethereum/tests pass
- [ ] Can run real DeFi protocols (Uniswap, etc.)

## Dependencies for Advanced Interpreter

These fixes are **required** before benchmarking because:
1. Real contracts use these operations extensively
2. Benchmarks won't be representative without them
3. The advanced interpreter must handle these operations

## Estimated Time

- DELEGATECALL/STATICCALL: 1 day
- CREATE/CREATE2: 1-2 days  
- SELFDESTRUCT: Few hours
- Testing: 1 day
- **Total: 3-4 days**

## References

- Check revm implementation: `revm/crates/interpreter/src/instructions/contract.rs`
- EIP-150 for gas calculations
- EIP-211 for CREATE2
- Yellow Paper sections 7 and 8