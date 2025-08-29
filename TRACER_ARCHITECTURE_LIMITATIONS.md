# Tracer Architecture Limitations

## Overview

This document describes the current architectural limitations of the tracing system in the Guillotine EVM implementation, specifically regarding transaction-level state tracking and tracer instance accessibility.

## Current Architecture Problem

### Tracer Instance Isolation

The current architecture has a fundamental issue where tracer instances are created internally by `StackFrame` and are not accessible to the EVM or user code:

```zig
// Current (problematic) flow:
const evm_config = EvmConfig{
    .frame_config = .{
        .TracerType = PrestateTracer,  // Set at compile time
    },
};

// EVM creates StackFrame, which creates its OWN tracer internally
var frame = try StackFrame.init(...);
// Tracer instance is hidden inside frame, inaccessible to EVM or user
```

### User Accessibility Issue

Users cannot:
1. Create their own tracer instance
2. Pass it to the EVM for a specific call
3. Access the tracer's accumulated state after execution

What users want to do:
```zig
// Desired usage (not currently possible):
var my_tracer = PrestateTracer.init();
const result = evm.call_with_tracer(params, &my_tracer);
const prestate = my_tracer.getPrestate();
```

## Transaction-Level State Changes Not Captured

The following state changes occur at the EVM orchestration level and are NOT captured by opcode-level handlers in `StackFrame`:

### Nonce Changes

1. **Sender Nonce Increment for CREATE/CREATE2**
   - Location: `evm.zig:543`
   - When: Before any opcodes execute
   - What: Sender's nonce is incremented when creating a contract

2. **Contract Nonce Initialization**
   - Location: `evm.zig:597, 708`
   - When: After contract creation
   - What: New contracts get nonce set to 1

3. **EOA Transaction Nonce Increment** (not implemented)
   - When: At transaction start
   - What: Externally owned account's nonce increments for each transaction

### Balance Changes

1. **Value Transfer in CALL**
   - Location: `evm.zig:339` (via `doTransfer`)
   - When: Before opcode execution begins
   - What: ETH transfer from caller to callee

2. **Value Transfer in CREATE/CREATE2**
   - Location: `evm.zig:564`
   - When: Before init code execution
   - What: ETH endowment to new contract

3. **Gas Fee Deduction** (not implemented)
   - When: Transaction start
   - What: `sender.balance -= gas_limit * gas_price`

4. **Gas Refund** (not implemented)
   - When: Transaction completion
   - What: `sender.balance += unused_gas * gas_price`

5. **Miner/Validator Fee Payment** (not implemented)
   - When: Transaction completion
   - What: `block_producer.balance += gas_used * gas_price`

6. **SELFDESTRUCT Beneficiary Transfer**
   - When: Transaction finalization (after all execution)
   - What: Contract balance transferred to beneficiary

### Critical Transaction Semantics

**On Transaction Failure:**
- Balance changes: REVERT (via journal)
- Nonce changes: DO NOT REVERT (sender nonce stays incremented)
- This asymmetry is important for preventing replay attacks

## Why This Architecture Is Problematic

### 1. Incomplete State Tracking

Transaction-level changes occur:
- **Before opcodes**: Gas fees, initial transfers, nonce increments
- **After opcodes**: Gas refunds, SELFDESTRUCT finalization
- **Outside StackFrame**: In EVM orchestration layer

These changes are invisible to the StackFrame's tracer instance.

### 2. Tracer Instance Inaccessibility

The current design where StackFrame creates its own internal tracer means:
- No way to access tracer results after execution
- No way to reuse a tracer across multiple calls
- No runtime configuration of tracer behavior
- Tracing is effectively useless for practical debugging/analysis

### 3. Temporary Tracer Anti-Pattern

The attempted fix of creating temporary tracers in EVM is fundamentally flawed:

```zig
// WRONG - Creates temporary instance that immediately dies
var temp_tracer = config.frame_config.TracerType.?.init();
temp_tracer.onBalanceChange(...);  // State lost when function returns!
```

## Architectural Requirements for Solution

A proper tracing architecture needs:

1. **Tracer Instance Persistence**: Single tracer instance that accumulates state across entire transaction
2. **User Accessibility**: Users must be able to create, configure, and access tracer instances
3. **Transaction-Level Hooks**: Tracer must capture pre/post transaction state changes
4. **Opcode-Level Hooks**: Tracer must capture individual opcode execution
5. **Unified State**: Both transaction and opcode level changes in same tracer state

## Proposed Solution Approaches

### Option 1: Pass Tracer to EVM Call
```zig
var my_tracer = PrestateTracer.init();
const result = evm.call_with_tracer(params, &my_tracer);
// EVM passes tracer to StackFrame during creation
```

### Option 2: Set Tracer on EVM Instance
```zig
var my_tracer = PrestateTracer.init();
evm.setTracer(&my_tracer);
const result = evm.call(params);
// EVM uses configured tracer for all operations
```

### Option 3: Tracer Factory Pattern
```zig
const tracer_factory = PrestateTracerFactory.init();
const result = evm.call_with_tracer_factory(params, tracer_factory);
// EVM creates tracer from factory, returns it with result
```

## Implementation Challenges

1. **Compile-Time vs Runtime**: Current TracerType is compile-time configured, needs runtime flexibility
2. **Ownership**: Who owns the tracer instance? User, EVM, or StackFrame?
3. **Thread Safety**: If tracer is shared, needs synchronization in concurrent scenarios
4. **Performance**: Must maintain zero-cost abstraction for no-tracer case
5. **Backwards Compatibility**: Changes must not break existing code

## Conclusion

The current tracer architecture has fundamental limitations that prevent comprehensive transaction tracing. The isolation of tracer instances within StackFrame and the lack of transaction-level hooks means critical state changes are invisible to tracing infrastructure. A redesign is needed to support practical debugging and analysis use cases.

## References

- `src/evm/evm.zig`: Transaction orchestration and state management
- `src/evm/stack_frame.zig`: Opcode execution and tracer integration
- `src/evm/frame_config.zig`: Compile-time tracer configuration
- `src/evm/prestate_tracer.zig`: Example tracer implementation