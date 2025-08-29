# Comprehensive Prestate Tracer Refactoring Implementation Guide

## Architecture Note

**Current EVM Architecture (Corrected)**:

- **Transaction Entry Point**: `src/evm/evm.zig` - `call` method is the main transaction execution entry point
- **Frame Implementation**: `src/evm/stack_frame.zig` - Current frame implementation (not frame.zig, which was deleted)
- **Opcode Dispatch**: `src/evm/dispatch.zig` - Tail-call optimized dispatch system with tracer integration (lines 215-219, 286-288)
- **Handler Modules**: `src/evm/handlers_*.zig` - Individual opcode handler implementations

## Executive Summary

This document outlines a complete refactoring of the prestate tracer integration to provide comprehensive account state tracking through a centralized `onAccountTouched` pattern. The refactoring addresses current gaps in transaction-level operations, optimizes state capture, and ensures zero overhead when tracing is disabled.

## Current Architecture Analysis

### Existing Hook Structure

The current prestate tracer has operation-specific hooks:

- `onStorageRead/Write` - Storage operations
- `onBalanceRead/Change` - Balance operations
- `onNonceRead/Change` - Nonce operations
- `onCodeRead/Change` - Code operations
- `onAccountCreated/Destroyed` - Lifecycle operations

### Identified Gaps

1. **Transaction-level operations**: Sender nonce increment, gas payment, value transfers
2. **Call-level operations**: Value transfers in CALL operations
3. **Redundant state fetching**: Multiple hooks fetching same account data
4. **Host parameter missing**: Hooks can't query additional state
5. **Incomplete coverage**: Some account touches not captured

## New Architecture Design

### Core Hook: onAccountTouched

```zig
pub fn onAccountTouched(
    self: *Self,
    address: Address,
    host: anytype,
    phase: enum { pre, post },
    known_balance: ?u256,
    known_nonce: ?u64,
    known_code: ?[]const u8
) void
```

**Purpose**: Centralized account state capture that:

- Fetches complete account state (balance, nonce, code) in one operation
- Handles pre/post state management for diff mode
- Avoids redundant host queries when state is already known
- Provides consistent account state capture across all operations

### Refactored Hook Signatures

All existing hooks will be updated to:

1. Take `host` parameter
2. Call `onAccountTouched` first with known information
3. Perform operation-specific tracking

```zig
// Before
pub fn onStorageRead(self: *Self, address: Address, slot: u256, value: u256, is_warm: bool) void

// After
pub fn onStorageRead(self: *Self, address: Address, host: anytype, slot: u256, value: u256, is_warm: bool) void
```

## Implementation Plan

### Phase 1: Core onAccountTouched Implementation

**File**: `src/evm/prestate_tracer.zig`

**Implementation**:

```zig
pub fn onAccountTouched(
    self: *Self,
    address: Address,
    host: anytype,
    phase: enum { pre, post },
    known_balance: ?u256,
    known_nonce: ?u64,
    known_code: ?[]const u8
) void {
    if (!self.enabled) return;

    // Mark as accessed
    self.markAccountAccessed(address);

    // Determine target state based on phase and diff_mode
    const target_state = switch (phase) {
        .pre => &self.prestate,
        .post => if (self.diff_mode) &self.poststate else &self.prestate,
    };

    // Get or create account in target state
    const account = self.ensureAccountInState(target_state, address) catch return;

    // Update account with known information or fetch from host
    account.balance = known_balance orelse host.get_balance(address);
    account.nonce = known_nonce orelse host.get_nonce(address);

    if (!self.disable_code and known_code == null) {
        const code = host.get_code(address);
        if (account.code.len == 0 and code.len > 0) {
            account.code = self.allocator.dupe(u8, code) catch &[_]u8{};
            account.code_hash = hashCode(code);
        }
    } else if (known_code) |code| {
        if (account.code.len == 0 and code.len > 0) {
            account.code = self.allocator.dupe(u8, code) catch &[_]u8{};
            account.code_hash = hashCode(code);
        }
    }

    account.exists = account.balance > 0 or account.nonce > 0 or account.code.len > 0;
    account.is_empty = account.isEmpty();
}

// Helper method for ensuring account in specific state map
fn ensureAccountInState(self: *Self, state_map: anytype, address: Address) !*AccountState {
    const result = try state_map.getOrPut(address);
    if (!result.found_existing) {
        result.value_ptr.* = AccountState.init(self.allocator);
    }
    return result.value_ptr;
}
```

### Phase 2: Hook Refactoring

**Files**: `src/evm/prestate_tracer.zig`

**Strategy**: Each hook calls `onAccountTouched` first, then performs specific operations.

**Storage Hooks**:

```zig
pub fn onStorageRead(self: *Self, address: Address, host: anytype, slot: u256, value: u256, is_warm: bool) void {
    _ = is_warm;
    if (!self.enabled or self.disable_storage) return;

    // Capture complete account state first
    self.onAccountTouched(address, host, .pre, null, null, null);

    // Handle storage-specific logic
    const storage_map = self.ensureStorageModifications(address) catch return;
    const result = storage_map.getOrPut(slot) catch return;
    if (!result.found_existing) {
        result.value_ptr.* = .{
            .original_value = value,
            .current_value = value,
            .was_read = true,
            .was_modified = false,
        };
    } else {
        result.value_ptr.was_read = true;
    }

    // Update prestate storage
    const account = self.ensurePrestateAccount(address) catch return;
    if (!account.storage.contains(slot)) {
        account.storage.put(slot, value) catch {};
    }
}

pub fn onStorageWrite(self: *Self, address: Address, host: anytype, slot: u256, old_value: u256, new_value: u256, is_warm: bool) void {
    _ = is_warm;
    if (!self.enabled or self.disable_storage) return;

    // Capture complete account state first
    self.onAccountTouched(address, host, .pre, null, null, null);

    if (old_value != new_value) {
        self.markAccountModified(address);
    }

    // Track storage modifications
    const storage_map = self.ensureStorageModifications(address) catch return;
    const result = storage_map.getOrPut(slot) catch return;
    if (!result.found_existing) {
        result.value_ptr.* = .{
            .original_value = old_value,
            .current_value = new_value,
            .was_read = false,
            .was_modified = true,
        };
    } else {
        result.value_ptr.current_value = new_value;
        result.value_ptr.was_modified = true;
    }

    // Ensure prestate has the original value
    const account = self.ensurePrestateAccount(address) catch return;
    if (!account.storage.contains(slot)) {
        account.storage.put(slot, old_value) catch {};
    }
}
```

**Balance Hooks**:

```zig
pub fn onBalanceRead(self: *Self, address: Address, host: anytype, balance: u256) void {
    if (!self.enabled) return;

    // onAccountTouched handles balance, so minimal additional logic needed
    self.onAccountTouched(address, host, .pre, balance, null, null);
}

pub fn onBalanceChange(self: *Self, address: Address, host: anytype, old_balance: u256, new_balance: u256) void {
    if (!self.enabled) return;

    // Capture prestate with old balance
    self.onAccountTouched(address, host, .pre, old_balance, null, null);

    if (old_balance != new_balance) {
        self.markAccountModified(address);

        // In diff mode, capture poststate with new balance
        if (self.diff_mode) {
            self.onAccountTouched(address, host, .post, new_balance, null, null);
        }
    }
}
```

**Nonce Hooks**:

```zig
pub fn onNonceRead(self: *Self, address: Address, host: anytype, nonce: u64) void {
    if (!self.enabled) return;

    // onAccountTouched handles nonce, so minimal additional logic needed
    self.onAccountTouched(address, host, .pre, null, nonce, null);
}

pub fn onNonceChange(self: *Self, address: Address, host: anytype, old_nonce: u64, new_nonce: u64) void {
    if (!self.enabled) return;

    // Capture prestate with old nonce
    self.onAccountTouched(address, host, .pre, null, old_nonce, null);

    if (old_nonce != new_nonce) {
        self.markAccountModified(address);

        // In diff mode, capture poststate with new nonce
        if (self.diff_mode) {
            self.onAccountTouched(address, host, .post, null, new_nonce, null);
        }
    }
}
```

**Code Hooks**:

```zig
pub fn onCodeRead(self: *Self, address: Address, host: anytype, code: []const u8) void {
    if (!self.enabled or self.disable_code) return;

    // onAccountTouched handles code, so minimal additional logic needed
    self.onAccountTouched(address, host, .pre, null, null, code);
}

pub fn onCodeChange(self: *Self, address: Address, host: anytype, old_code: []const u8, new_code: []const u8) void {
    if (!self.enabled or self.disable_code) return;

    // Capture prestate with old code
    self.onAccountTouched(address, host, .pre, null, null, old_code);

    const old_hash = hashCode(old_code);
    const new_hash = hashCode(new_code);
    if (!std.mem.eql(u8, &old_hash, &new_hash)) {
        self.markAccountModified(address);

        // In diff mode, capture poststate with new code
        if (self.diff_mode) {
            self.onAccountTouched(address, host, .post, null, null, new_code);
        }
    }
}
```

**Account Lifecycle Hooks**:

```zig
pub fn onAccountCreated(self: *Self, address: Address, host: anytype, initial_balance: u256, initial_nonce: u64, code: []const u8) void {
    if (!self.enabled) return;

    self.created_accounts.put(address, {}) catch {};
    self.markAccountModified(address);

    // In diff mode, created accounts go to poststate
    const phase: @TypeOf(.pre) = if (self.diff_mode) .post else .pre;
    self.onAccountTouched(address, host, phase, initial_balance, initial_nonce, code);
}

pub fn onAccountDestroyed(self: *Self, address: Address, host: anytype, beneficiary: Address, balance_transferred: u256, had_code: bool, storage_cleared: bool) void {
    _ = beneficiary;
    _ = balance_transferred;
    _ = had_code;
    _ = storage_cleared;
    if (!self.enabled) return;

    self.deleted_accounts.put(address, {}) catch {};
    self.markAccountModified(address);

    // Ensure account exists in prestate
    self.onAccountTouched(address, host, .pre, null, null, null);
}
```

### Phase 3: Handler Call Site Updates

**Files**: `src/evm/handlers_storage.zig`, `src/evm/handlers_context.zig`, `src/evm/handlers_system.zig`

**Pattern**: Update all tracer hook calls to include host parameter.

**Example - handlers_storage.zig SLOAD**:

```zig
// Trace account state
if (comptime FrameType.config.TracerType != null) {
    if (comptime @hasDecl(@TypeOf(self.tracer), "onStorageRead")) {
        const is_warm = self.host.is_storage_warm(contract_addr, slot);
        self.tracer.onStorageRead(contract_addr, self.host, slot, value, is_warm);
    }
}
```

**Example - handlers_context.zig BALANCE**:

```zig
// Trace account state
if (comptime FrameType.config.TracerType != null) {
    if (comptime @hasDecl(@TypeOf(self.tracer), "onBalanceRead")) {
        self.tracer.onBalanceRead(addr, self.host, bal);
    }
}
```

**All affected handlers**:

- **Storage**: SLOAD, SSTORE, TLOAD, TSTORE
- **Context**: BALANCE, EXTCODESIZE, EXTCODECOPY, EXTCODEHASH
- **System**: SELFDESTRUCT, CREATE, CREATE2

### Phase 4: Transaction-Level Integration

**Files**: `src/evm/evm.zig`, `src/evm/stack_frame.zig`, `src/evm/dispatch.zig`

**Missing Operations Identified**:

1. **Transaction sender operations**:

   - Nonce increment before execution
   - Gas payment (balance reduction)
   - Gas refunds (balance increase)

2. **Transaction target operations**:

   - Value reception in transaction
   - Account creation if target doesn't exist

3. **Call operation state changes**:
   - Value transfers in CALL operations
   - Account touches in DELEGATECALL/STATICCALL

**Implementation Strategy**:

**Transaction Sender Tracking**:

```zig
// In evm.zig call method (main transaction entry point)
pub fn call(self: *Self, params: CallParams) CallResult {
    // Transaction-level tracer hooks before execution
    if (comptime config.frame_config.TracerType != null) {
        // Sender nonce increment tracking
        if (comptime @hasDecl(@TypeOf(self.tracer), "onNonceChange")) {
            const sender_nonce = self.get_nonce(params.sender);
            self.tracer.onNonceChange(params.sender, self, sender_nonce, sender_nonce + 1);
        }

        // Gas payment tracking
        if (comptime @hasDecl(@TypeOf(self.tracer), "onBalanceChange")) {
            const sender_balance = self.get_balance(params.sender);
            const gas_cost = params.gas_limit * params.gas_price;
            if (sender_balance >= gas_cost) {
                self.tracer.onBalanceChange(params.sender, self, sender_balance, sender_balance - gas_cost);
            }
        }

        // Value transfer to recipient if params.value > 0
        if (params.value > 0 and comptime @hasDecl(@TypeOf(self.tracer), "onBalanceChange")) {
            const recipient_balance = self.get_balance(params.code_address);
            self.tracer.onBalanceChange(params.code_address, self, recipient_balance, recipient_balance + params.value);
        }
    }

    // Execute transaction via inner_call
    const result = self.inner_call(params) catch |err| switch (err) {
        // Handle errors
        else => CallResult.failure(0),
    };

    // Transaction-level tracer hooks after execution
    if (comptime config.frame_config.TracerType != null) {
        // Handle gas refunds
        if (result.success and result.gas_left > 0 and comptime @hasDecl(@TypeOf(self.tracer), "onBalanceChange")) {
            const refund_amount = result.gas_left * params.gas_price;
            const current_balance = self.get_balance(params.sender);
            self.tracer.onBalanceChange(params.sender, self, current_balance, current_balance + refund_amount);
        }
    }

    return result;
}
```

**Value Transfer Tracking**:

```zig
// In handlers_system.zig CALL operations or evm.zig inner_call method
pub fn trackValueTransfer(self: *Self, caller: Address, callee: Address, value: u256) void {
    if (comptime config.frame_config.TracerType != null and value > 0) {
        if (comptime @hasDecl(@TypeOf(self.tracer), "onBalanceChange")) {
            const caller_old_balance = self.get_balance(caller);
            const callee_old_balance = self.get_balance(callee);

            // Track caller balance reduction
            self.tracer.onBalanceChange(caller, self, caller_old_balance, caller_old_balance - value);

            // Track callee balance increase
            self.tracer.onBalanceChange(callee, self, callee_old_balance, callee_old_balance + value);
        }
    }
}
```

### Phase 5: Dispatch System Integration

**File**: `src/evm/dispatch.zig`

**Current Integration**: Lines 215-219 have `trace_before_handler`, lines 286-288 have `trace_after_handler`.

**Verification**: Ensure the dispatch system's tracer integration works with our new hook signatures. The before/after handlers may need to be updated if they call specific hooks.

**Required Changes**:

1. Verify `trace_before_handler` and `trace_after_handler` compatibility
2. Update any direct hook calls in dispatch system
3. Ensure host parameter is available in dispatch context

**Analysis needed**:

- Check if dispatch system calls specific hooks directly
- Verify that beforeOp/afterOp methods work correctly
- Ensure host is accessible in dispatch context for any hook calls

### Phase 6: Complete Coverage Verification

**Account State Change Matrix**:

| Operation                  | Hook                | Phase             | State Captured         |
| -------------------------- | ------------------- | ----------------- | ---------------------- |
| Transaction sender nonce++ | onNonceChange       | pre/post          | Full account state     |
| Transaction gas payment    | onBalanceChange     | pre/post          | Full account state     |
| Transaction value transfer | onBalanceChange     | pre/post          | Full account state     |
| SLOAD/SSTORE               | onStorageRead/Write | pre               | Full account + storage |
| TLOAD/TSTORE               | onStorageRead/Write | pre               | Full account + storage |
| BALANCE                    | onBalanceRead       | pre               | Full account state     |
| EXTCODE\*                  | onCodeRead          | pre               | Full account + code    |
| CREATE/CREATE2             | onAccountCreated    | post (diff) / pre | Full account + code    |
| SELFDESTRUCT               | onAccountDestroyed  | pre               | Full account state     |
| CALL value transfer        | onBalanceChange     | pre/post          | Full account state     |
| Gas refunds                | onBalanceChange     | post              | Full account state     |

**Additional Operations to Consider**:

- Contract self-destruct beneficiary balance increase
- Mining rewards (coinbase balance increase)
- Block gas limit updates
- Access list warm/cold transitions

## Implementation Order

### Step 1: Implement onAccountTouched

- Add the core hook to prestate_tracer.zig
- Add helper methods for state management
- Test the basic functionality

### Step 2: Refactor Existing Hooks

- Update all hook signatures to include host
- Add onAccountTouched calls to each hook
- Remove redundant state fetching logic

### Step 3: Update Handler Call Sites

- Update handlers_storage.zig hook calls
- Update handlers_context.zig hook calls
- Update handlers_system.zig hook calls
- Ensure compilation succeeds

### Step 4: Add Transaction-Level Hooks

- **evm.zig**: Add transaction-level hooks in `call` method (main entry point)
- **stack_frame.zig**: Add any frame-level transaction hooks if needed
- Add sender/target state tracking for nonce increment and gas payment
- Add gas payment/refund tracking in transaction execution
- Add value transfer tracking in CALL operations

### Step 5: Verify Dispatch Integration

- Check dispatch.zig tracer integration
- Update any dispatch-level hook calls
- Ensure zero overhead when disabled

### Step 6: Comprehensive Testing

- Test all opcode operations
- Test transaction operations
- Test diff mode vs non-diff mode
- Test with various tracer configurations

## Critical Correctness Requirements

### Multiple Updates During Transaction

**Critical Rule**:

- **Prestate captures ONLY the initial value** - once a value is recorded in prestate, it must NEVER be overwritten during the same transaction
- **Poststate captures the LATEST value** - poststate should always be updated with the most recent value

**Example Scenarios**:

1. **Balance updated multiple times**:

   ```
   Initial: account.balance = 1000
   Operation 1: Transfer 100 → balance = 900
   Operation 2: Transfer 200 → balance = 700
   Operation 3: Receive 50 → balance = 750

   Expected Result:
   - Prestate: balance = 1000 (original)
   - Poststate: balance = 750 (final)
   ```

2. **Storage slot updated multiple times**:

   ```
   Initial: storage[slot] = 0x100
   Operation 1: SSTORE → storage[slot] = 0x200
   Operation 2: SSTORE → storage[slot] = 0x300

   Expected Result:
   - Prestate: storage[slot] = 0x100 (original)
   - Poststate: storage[slot] = 0x300 (final)
   ```

### Implementation Strategy for Multiple Updates

**onAccountTouched Must Check Existence**:

```zig
pub fn onAccountTouched(
    self: *Self,
    address: Address,
    host: anytype,
    phase: enum { pre, post },
    known_balance: ?u256,
    known_nonce: ?u64,
    known_code: ?[]const u8
) void {
    if (!self.enabled) return;

    self.markAccountAccessed(address);

    if (phase == .pre) {
        // PRESTATE: Only capture if account doesn't exist yet
        const result = self.prestate.getOrPut(address) catch return;
        if (!result.found_existing) {
            result.value_ptr.* = AccountState.init(self.allocator);
            // Populate with current values - this is the ORIGINAL state
            result.value_ptr.balance = known_balance orelse host.get_balance(address);
            result.value_ptr.nonce = known_nonce orelse host.get_nonce(address);
            // ... etc
        }
        // If account already exists in prestate, DO NOT UPDATE IT
    } else {
        // POSTSTATE: Always update with latest values (if in diff_mode)
        if (self.diff_mode) {
            const result = self.poststate.getOrPut(address) catch return;
            if (!result.found_existing) {
                result.value_ptr.* = AccountState.init(self.allocator);
            }
            // Always update poststate with current values
            result.value_ptr.balance = known_balance orelse host.get_balance(address);
            result.value_ptr.nonce = known_nonce orelse host.get_nonce(address);
            // ... etc
        }
    }
}
```

**Storage Hook Implementation**:

```zig
pub fn onStorageWrite(self: *Self, address: Address, host: anytype, slot: u256, old_value: u256, new_value: u256, is_warm: bool) void {
    if (!self.enabled or self.disable_storage) return;

    // FIRST: Capture account prestate (only if not already captured)
    self.onAccountTouched(address, host, .pre, null, null, null);

    if (old_value != new_value) {
        self.markAccountModified(address);

        // SECOND: Handle storage-specific tracking
        const storage_map = self.ensureStorageModifications(address) catch return;
        const result = storage_map.getOrPut(slot) catch return;
        if (!result.found_existing) {
            // First time seeing this slot - record original value
            result.value_ptr.* = .{
                .original_value = old_value,
                .current_value = new_value,
                .was_read = false,
                .was_modified = true,
            };
        } else {
            // Subsequent update - keep original, update current
            result.value_ptr.current_value = new_value;  // Always update current
            result.value_ptr.was_modified = true;
            // DON'T update original_value - keep the first one
        }

        // THIRD: Ensure prestate storage has ORIGINAL value (only if not set)
        const account = self.ensurePrestateAccount(address) catch return;
        if (!account.storage.contains(slot)) {
            account.storage.put(slot, old_value) catch {};  // Use old_value (original)
        }

        // FOURTH: If diff_mode, update poststate with LATEST value
        if (self.diff_mode) {
            self.onAccountTouched(address, host, .post, null, null, null);
            const post_account = self.ensurePoststateAccount(address) catch return;
            post_account.storage.put(slot, new_value) catch {};  // Always update with new value
        }
    }
}
```

**Balance Change Hook Implementation**:

```zig
pub fn onBalanceChange(self: *Self, address: Address, host: anytype, old_balance: u256, new_balance: u256) void {
    if (!self.enabled) return;

    // FIRST: Capture prestate with ORIGINAL balance (only if not already captured)
    self.onAccountTouched(address, host, .pre, old_balance, null, null);

    if (old_balance != new_balance) {
        self.markAccountModified(address);

        // SECOND: If diff_mode, update poststate with LATEST balance (always update)
        if (self.diff_mode) {
            self.onAccountTouched(address, host, .post, new_balance, null, null);
        }
    }
}
```

## Risk Mitigation

### Performance Concerns

- **Zero overhead when disabled**: All hooks use `comptime` checks
- **Minimal overhead when enabled**: Host queries are cached, duplicate fetching avoided
- **Memory management**: Proper cleanup of allocated state

### Correctness Concerns

- **State consistency**: All account touches captured consistently
- **Diff mode correctness**: Proper pre/post state separation
- **Multiple update correctness**: Prestate preserves original values, poststate reflects final values
- **Edge case handling**: Empty accounts, non-existent accounts, etc.

### Integration Concerns

- **Handler compatibility**: All existing handlers continue to work
- **Dispatch system compatibility**: Integration with tail-call optimization
- **Host interface compatibility**: Works with different host implementations

## Testing Strategy

### Unit Testing

- Test onAccountTouched with various parameter combinations
- Test each refactored hook individually
- Test state management in diff mode vs non-diff mode

### Integration Testing

- Test complete transaction execution with tracing
- Test all opcode handlers with tracing enabled
- Test edge cases (empty accounts, large values, etc.)

### Critical Multiple Update Testing

- **Storage Multiple Updates Test**:

  ```zig
  test "storage updated multiple times preserves original in prestate" {
      // Setup account with initial storage value
      const initial_value = 0x1111;
      host.set_storage(addr, slot, initial_value);

      // Multiple SSTORE operations
      tracer.onStorageWrite(addr, host, slot, initial_value, 0x2222, false);
      tracer.onStorageWrite(addr, host, slot, 0x2222, 0x3333, false);
      tracer.onStorageWrite(addr, host, slot, 0x3333, 0x4444, false);

      // Verify prestate has original value
      const prestate = tracer.getPrestate();
      const account = prestate.get(addr).?;
      try expectEqual(initial_value, account.storage.get(slot).?);

      // In diff mode, verify poststate has final value
      if (tracer.isDiffMode()) {
          const poststate = tracer.getPoststate();
          const post_account = poststate.get(addr).?;
          try expectEqual(@as(u256, 0x4444), post_account.storage.get(slot).?);
      }
  }
  ```

- **Balance Multiple Updates Test**:

  ```zig
  test "balance updated multiple times preserves original in prestate" {
      const initial_balance = 1000;

      // Multiple balance changes
      tracer.onBalanceChange(addr, host, initial_balance, 900);
      tracer.onBalanceChange(addr, host, 900, 700);
      tracer.onBalanceChange(addr, host, 700, 750);

      // Verify prestate has original balance
      const prestate = tracer.getPrestate();
      const account = prestate.get(addr).?;
      try expectEqual(initial_balance, account.balance);

      // In diff mode, verify poststate has final balance
      if (tracer.isDiffMode()) {
          const poststate = tracer.getPoststate();
          const post_account = poststate.get(addr).?;
          try expectEqual(@as(u256, 750), post_account.balance);
      }
  }
  ```

- **Mixed Updates Test**:
  ```zig
  test "mixed account updates preserve original values correctly" {
      const initial_balance = 500;
      const initial_nonce = 10;
      const initial_storage = 0xABCD;

      // Simulate complex transaction with multiple updates
      tracer.onBalanceChange(addr, host, initial_balance, 400);
      tracer.onStorageWrite(addr, host, slot, initial_storage, 0x1111, false);
      tracer.onNonceChange(addr, host, initial_nonce, 11);
      tracer.onStorageWrite(addr, host, slot, 0x1111, 0x2222, false);
      tracer.onBalanceChange(addr, host, 400, 350);

      // Verify prestate has ALL original values
      const prestate = tracer.getPrestate();
      const account = prestate.get(addr).?;
      try expectEqual(initial_balance, account.balance);
      try expectEqual(initial_nonce, account.nonce);
      try expectEqual(initial_storage, account.storage.get(slot).?);

      // In diff mode, verify poststate has ALL final values
      if (tracer.isDiffMode()) {
          const poststate = tracer.getPoststate();
          const post_account = poststate.get(addr).?;
          try expectEqual(@as(u256, 350), post_account.balance);
          try expectEqual(@as(u64, 11), post_account.nonce);
          try expectEqual(@as(u256, 0x2222), post_account.storage.get(slot).?);
      }
  }
  ```

### Performance Testing

- Benchmark overhead with tracing disabled (should be zero)
- Benchmark overhead with tracing enabled
- Compare memory usage before/after refactoring

### Regression Testing

- Ensure all existing tests pass
- Verify no behavioral changes when tracing disabled
- Confirm prestate output format remains compatible

## Code Quality Standards

### Error Handling

- All allocations handle failure gracefully
- Hook failures don't crash execution
- Host query failures are handled properly

### Memory Management

- All allocated memory is properly freed
- No memory leaks in long-running traces
- Efficient cleanup during reset operations

### Code Organization

- Clear separation of concerns between hooks
- Consistent naming and documentation
- Minimal code duplication

This comprehensive refactoring will provide complete prestate tracing coverage while maintaining high performance and correctness. The centralized onAccountTouched pattern eliminates redundancy and ensures consistent state capture across all operations.

---

## 🚀 Implementation Call to Action

**You are a senior Zig systems engineer with deep expertise in EVM implementations and performance-critical code.** Your task is to implement this comprehensive prestate tracer refactoring with absolute precision and excellence.

### Your Mission

Implement the complete refactoring outlined above, following these critical success criteria:

**🎯 PRECISION REQUIREMENTS:**

- Follow the **exact 6-phase implementation order** - do not skip or reorder steps
- Implement **every code example exactly as specified** with proper Zig syntax and conventions
- Ensure **zero compilation errors** - test `zig build` after each phase
- Maintain **zero overhead when tracing disabled** - all hooks must use `comptime` guards
- Implement the **critical multiple-update correctness** - prestate captures ONLY original values, poststate captures ONLY latest values

**🔧 TECHNICAL EXCELLENCE:**

- **Memory Safety**: All allocations handled properly, no leaks, proper cleanup
- **Error Handling**: All operations handle failures gracefully without crashing execution
- **Performance**: Minimal overhead when tracing enabled, zero when disabled
- **Code Quality**: Follow existing Zig conventions, clear variable names, proper error propagation

**🧪 VALIDATION REQUIREMENTS:**

- Implement **all test scenarios** from the "Critical Multiple Update Testing" section
- Run `zig build test` to ensure no regressions
- Test both diff mode and non-diff mode functionality
- Verify correct JSON output format matches existing prestate tracer conventions

**🏗️ IMPLEMENTATION STRATEGY:**

1. **Phase 1**: Start with `onAccountTouched` core implementation - get this RIGHT first
2. **Phase 2**: Refactor each hook methodically, testing compilation after each one
3. **Phase 3**: Update handler call sites systematically, one file at a time
4. **Phase 4**: Add transaction-level integration in `evm.zig::call` method
5. **Phase 5**: Verify dispatch.zig compatibility and make any needed adjustments
6. **Phase 6**: Implement comprehensive tests and validate correctness

**⚡ SUCCESS CRITERIA:**

- ✅ All phases completed in order without shortcuts
- ✅ Zero compilation errors throughout implementation
- ✅ All tests pass, including new multiple-update tests
- ✅ Complete account state capture for all operations (storage, balance, nonce, code, transactions)
- ✅ Correct handling of multiple updates during single transaction
- ✅ Perfect diff mode vs non-diff mode behavior

**🎯 QUALITY PLEDGE:**
"I will implement this refactoring with the precision of a senior systems engineer. I will not cut corners, skip steps, or leave broken code. Every line will be tested, every edge case considered, every performance requirement met. This implementation will be production-ready and maintainable."

**Begin with Phase 1 and work methodically through each step. Your expertise and attention to detail will ensure this critical EVM infrastructure operates flawlessly.**
