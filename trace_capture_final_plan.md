# JSONRPCTracer Enhanced Data Capture Implementation Plan

## TL;DR - What We're Capturing

Transform JSONRPCTracer to track execution comprehensively.

### Before Execution (beforeExecute)
```zig
// Capture execution context
initial_state = {
    gas_limit: 30_000_000,
    origin: 0xAlice,
    caller: 0xBob,
    contract: 0xContract,
    value: 1_000_000,
    call_depth: 2,
    is_static: false,
    block_number: 15_000_000,
    timestamp: 1_650_000_000,
}
```

### After Execution (afterExecute)
```zig
// Capture everything that happened
final_state = {
    success: true,  // or false with error_message
    error_message: null,  // or "OutOfGas", "InvalidJump", etc.
    
    gas_used: 150_000,
    gas_refund: 15_000,
    
    // Full execution artifacts
    stack: [0x1, 0x2, 0x42],
    memory: [first 4KB of memory],
    output: "0xabcdef...",  // Frame output
    return_data: "0x123456...",  // EVM return data
    current_input: "0xfeed...",  // Input data for this execution
    
    // All addresses and storage touched (for dependency tracking)
    addresses_accessed: [0xToken, 0xOracle, 0xNewContract],
    storage_accessed: [(0xToken, slot_0x5), (0xToken, slot_0x7)],
    
    // Actual state changes with before/after values
    state_changes: [
        { type: storage, address: 0xToken, slot: 0x5, original: 100, new: 150 },
        { type: balance, address: 0xAlice, original: 1000, new: 850 },
        { type: account_created, address: 0xNewContract },
        { type: account_destroyed, address: 0xOld, beneficiary: 0xAlice, balance: 50 },
    ],
    
    // Contract lifecycle tracking
    contracts_created: [0xNewContract, 0xAnotherNew],
    contracts_selfdestructed: [
        { contract: 0xOld, beneficiary: 0xAlice },
    ],
    
    // Events emitted
    logs_emitted: [
        { address: 0xToken, topics: [...], data: "..." },
    ],
}
```

### Key Insights This Enables
- **Dependency analysis**: Know all addresses and storage touched
- **State debugging**: See exact before/after values for all changes
- **Security analysis**: Track money flow, contract creation/destruction
- **Compliance**: Complete audit trail of execution

## Data Structures

### 1. Core Types (from existing code)
```zig
// From logs.zig
const Log = struct {
    address: Address,          // primitives.Address.Address ([20]u8)
    topics: []const u256,
    data: []const u8,
};

// From access_list.zig (internal structure)
const StorageKey = struct {
    address: Address,
    slot: u256,
};

// From journal_entry.zig
const JournalEntry = struct {
    snapshot_id: u8/u16,  // depends on config
    data: union(enum) {
        storage_change: { address: Address, key: u256, original_value: u256 },
        balance_change: { address: Address, original_balance: u256 },
        nonce_change: { address: Address, original_nonce: u64 },
        code_change: { address: Address, original_code_hash: [32]u8 },
        account_created: { address: Address },
        account_destroyed: { address: Address, beneficiary: Address, balance: u256 },
    },
};

// From database_interface_account.zig
const Account = struct {
    balance: u256,
    code_hash: [32]u8,
    storage_root: [32]u8,
    nonce: u64,
    delegated_address: ?Address,
};
```

### 2. Tracer Data Structures

```zig
pub const JSONRPCTracer = struct {
    allocator: std.mem.Allocator,
    trace_steps: std.ArrayList(JSONRPCStep),
    
    // Execution context and results
    initial_state: ExecutionContext,
    final_state: ExecutionResult,
    
    // Baseline counts for filtering new items
    baseline_logs_count: usize,
    baseline_journal_count: usize,
    
    pub const ExecutionContext = struct {
        // Basic execution info
        gas_limit: i64,  // Cast from Frame.GasType (i32 or i64)
        caller: Address,
        contract_address: Address,
        value: u256,
        calldata: []const u8,
        call_depth: u32,
        is_static: bool,
        
        // Transaction context
        origin: Address,
        gas_price: u256,
        
        // Block context
        block_number: u64,
        timestamp: u64,
        base_fee: u256,
    };
    
    pub const ExecutionResult = struct {
        // Execution status
        success: bool,
        error_message: ?[]const u8,  // Error reason if failed
        
        // Gas accounting
        gas_left: i64,  // Cast from Frame.GasType
        gas_used: u64,
        gas_refund: u64,
        
        // Execution artifacts
        stack: []const u256,
        memory: []const u8,         // Capped at 4KB
        output: []const u8,         // Output from frame
        return_data: []const u8,    // Return data from EVM
        current_input: []const u8,   // Input data for this execution
        
        // What was accessed (all touches, for dependency tracking)
        addresses_accessed: []const Address,
        storage_accessed: []const StorageSlot,
        
        // What changed (actual state modifications)
        state_changes: []const StateChange,
        
        // Contract lifecycle tracking
        contracts_created: []const Address,    // From evm.created_contracts
        contracts_selfdestructed: []const SelfDestructInfo,  // From evm.self_destruct
        
        // Events emitted during THIS execution
        logs_emitted: []const Log,
    };
    
    pub const SelfDestructInfo = struct {
        contract: Address,
        beneficiary: Address,
    };
    
    pub const StorageSlot = struct {
        address: Address,
        slot: u256,
    };
    
    pub const StateChange = union(enum) {
        storage: struct {
            address: Address,
            slot: u256,
            original_value: u256,
            new_value: u256,
        },
        balance: struct {
            address: Address,
            original: u256,
            new: u256,
        },
        nonce: struct {
            address: Address,
            original: u64,
            new: u64,
        },
        code: struct {
            address: Address,
            original_hash: [32]u8,
            new_hash: [32]u8,
        },
        account_created: struct {
            address: Address,
        },
        account_destroyed: struct {
            address: Address,
            beneficiary: Address,
            balance_transferred: u256,
        },
    };
};
```

## Implementation

### beforeExecute Implementation
```zig
pub fn beforeExecute(self: *JSONRPCTracer, comptime FrameType: type, frame: *const FrameType) void {
    const evm = frame.getEvm();
    
    self.initial_state = .{
        // Basic execution context
        .gas_limit = @as(i64, frame.gas_remaining),
        .caller = frame.caller,
        .contract_address = frame.contract_address,
        .value = frame.value.*,
        .calldata = self.allocator.dupe(u8, frame.calldata) catch &.{},
        .call_depth = evm.depth,
        .is_static = evm.is_static_context(),
        
        // Transaction/block context
        .origin = evm.origin,
        .gas_price = evm.gas_price,
        .block_number = frame.block_info.number,
        .timestamp = frame.block_info.timestamp,
        .base_fee = frame.block_info.base_fee,
    };
    
    // Store baseline counts for filtering new entries
    self.baseline_logs_count = evm.logs.items.len;
    self.baseline_journal_count = evm.journal.entries.items.len;
}
```

### afterExecute Implementation
```zig
pub fn afterExecute(self: *JSONRPCTracer, comptime FrameType: type, frame: *const FrameType) void {
    const evm = frame.getEvm();
    
    // 1. Collect all accessed addresses
    var addresses = std.AutoHashMap(Address, void).init(self.allocator);
    defer addresses.deinit();
    
    var addr_iter = evm.access_list.addresses.iterator();
    while (addr_iter.next()) |entry| {
        addresses.put(entry.key_ptr.*, {}) catch {};
    }
    
    // 2. Collect all accessed storage slots
    var storage = std.ArrayList(StorageSlot).init(self.allocator);
    var storage_iter = evm.access_list.storage_slots.iterator();
    while (storage_iter.next()) |entry| {
        storage.append(.{
            .address = entry.key_ptr.*.address,
            .slot = entry.key_ptr.*.slot,
        }) catch {};
    }
    
    // 3. Process journal for state changes
    var state_changes = std.ArrayList(StateChange).init(self.allocator);
    for (evm.journal.entries.items[self.baseline_journal_count..]) |entry| {
        const change = switch (entry.data) {
            .storage_change => |sc| StateChange{
                .storage = .{
                    .address = sc.address,
                    .slot = sc.key,
                    .original_value = sc.original_value,
                    .new_value = evm.database.get_storage(sc.address.bytes, sc.key) catch sc.original_value,
                },
            },
            .balance_change => |bc| blk: {
                const account = evm.database.get_account(bc.address.bytes) catch null;
                break :blk StateChange{
                    .balance = .{
                        .address = bc.address,
                        .original = bc.original_balance,
                        .new = if (account) |acc| acc.balance else 0,
                    },
                };
            },
            .nonce_change => |nc| blk: {
                const account = evm.database.get_account(nc.address.bytes) catch null;
                break :blk StateChange{
                    .nonce = .{
                        .address = nc.address,
                        .original = nc.original_nonce,
                        .new = if (account) |acc| acc.nonce else 0,
                    },
                };
            },
            .code_change => |cc| blk: {
                const account = evm.database.get_account(cc.address.bytes) catch null;
                break :blk StateChange{
                    .code = .{
                        .address = cc.address,
                        .original_hash = cc.original_code_hash,
                        .new_hash = if (account) |acc| acc.code_hash else [_]u8{0} ** 32,
                    },
                };
            },
            .account_created => |ac| StateChange{
                .account_created = .{ .address = ac.address },
            },
            .account_destroyed => |ad| StateChange{
                .account_destroyed = .{
                    .address = ad.address,
                    .beneficiary = ad.beneficiary,
                    .balance_transferred = ad.balance,
                },
            },
        };
        state_changes.append(change) catch {};
    }
    
    // 4. Collect new logs
    var new_logs = std.ArrayList(Log).init(self.allocator);
    for (evm.logs.items[self.baseline_logs_count..]) |log| {
        new_logs.append(.{
            .address = log.address,
            .topics = self.allocator.dupe(u256, log.topics) catch &.{},
            .data = self.allocator.dupe(u8, log.data) catch &.{},
        }) catch {};
    }
    
    // 5. Capture memory (capped at 4KB)
    const mem_size = @constCast(&frame.memory).size();
    const capture_size = @min(mem_size, 4096);
    const memory_copy = if (capture_size > 0) blk: {
        const mem = self.allocator.alloc(u8, capture_size) catch &.{};
        const mem_slice = @constCast(&frame.memory).get_slice(0, @intCast(capture_size)) catch &.{};
        @memcpy(mem, mem_slice);
        break :blk mem;
    } else &.{};
    
    // 6. Convert addresses hashmap to array
    var addr_array = std.ArrayList(Address).init(self.allocator);
    var final_addr_iter = addresses.iterator();
    while (final_addr_iter.next()) |entry| {
        addr_array.append(entry.key_ptr.*) catch {};
    }
    
    // 7. Collect created contracts
    var created_contracts = std.ArrayList(Address).init(self.allocator);
    var created_iter = evm.created_contracts.contracts.iterator();
    while (created_iter.next()) |entry| {
        created_contracts.append(entry.key_ptr.*) catch {};
    }
    
    // 8. Collect self-destructed contracts
    var selfdestructs = std.ArrayList(SelfDestructInfo).init(self.allocator);
    var destruct_iter = evm.self_destruct.destructions.iterator();
    while (destruct_iter.next()) |entry| {
        selfdestructs.append(.{
            .contract = entry.key_ptr.*,
            .beneficiary = entry.value_ptr.*,
        }) catch {};
    }
    
    self.final_state = .{
        // Status (frame.output.len > 0 or specific error checking could be more sophisticated)
        .success = frame.gas_remaining >= 0,  // Basic success check
        .error_message = null,  // Would need to capture from error handler
        
        // Gas
        .gas_left = @as(i64, frame.gas_remaining),
        .gas_used = @intCast(@max(0, self.initial_state.gas_limit - @as(i64, frame.gas_remaining))),
        .gas_refund = evm.gas_refund_counter,
        
        // Execution artifacts
        .stack = self.allocator.dupe(u256, @constCast(&frame.stack).get_slice()) catch &.{},
        .memory = memory_copy,
        .output = self.allocator.dupe(u8, frame.output) catch &.{},
        .return_data = self.allocator.dupe(u8, evm.return_data) catch &.{},
        .current_input = self.allocator.dupe(u8, evm.current_input) catch &.{},
        
        // Access tracking (simple lists)
        .addresses_accessed = addr_array.toOwnedSlice() catch &.{},
        .storage_accessed = storage.toOwnedSlice() catch &.{},
        
        // State modifications
        .state_changes = state_changes.toOwnedSlice() catch &.{},
        
        // Contract lifecycle
        .contracts_created = created_contracts.toOwnedSlice() catch &.{},
        .contracts_selfdestructed = selfdestructs.toOwnedSlice() catch &.{},
        
        // Events
        .logs_emitted = new_logs.toOwnedSlice() catch &.{},
    };
}

/// Capture error information when execution fails
pub fn onError(self: *JSONRPCTracer, comptime FrameType: type, frame: *const FrameType, err: anyerror) void {
    _ = frame;
    
    // Store error message if final_state exists
    if (self.final_state.error_message == null) {
        const error_str = @errorName(err);
        self.final_state.error_message = self.allocator.dupe(u8, error_str) catch null;
        self.final_state.success = false;
    }
}
```

## Memory Cleanup
```zig
pub fn deinit(self: *JSONRPCTracer) void {
    // Clean up existing trace steps
    for (self.trace_steps.items) |*step| {
        step.deinit(self.allocator);
    }
    self.trace_steps.deinit(self.allocator);
    
    // Clean up initial state
    self.allocator.free(self.initial_state.calldata);
    
    // Clean up final state
    if (self.final_state.error_message) |msg| {
        self.allocator.free(msg);
    }
    self.allocator.free(self.final_state.stack);
    self.allocator.free(self.final_state.memory);
    self.allocator.free(self.final_state.output);
    self.allocator.free(self.final_state.return_data);
    self.allocator.free(self.final_state.current_input);
    
    // Clean up logs
    for (self.final_state.logs_emitted) |log| {
        self.allocator.free(log.topics);
        self.allocator.free(log.data);
    }
    self.allocator.free(self.final_state.logs_emitted);
    
    // Clean up access lists
    self.allocator.free(self.final_state.addresses_accessed);
    self.allocator.free(self.final_state.storage_accessed);
    
    // Clean up state changes
    self.allocator.free(self.final_state.state_changes);
    
    // Clean up contract lifecycle tracking
    self.allocator.free(self.final_state.contracts_created);
    self.allocator.free(self.final_state.contracts_selfdestructed);
}
```

## Key Implementation Notes

### 1. Access Tracking
- `addresses_accessed`: Every address touched via BALANCE, EXTCODESIZE, CALL, etc.
- `storage_accessed`: Every storage slot read or written
- Simple arrays for dependency analysis

### 2. State Change Tracking
- Journal provides original values before changes
- Database queries provide current values after changes
- Combined = complete before/after diff

### 3. Memory Safety
- Cap memory capture at 4KB to avoid huge traces
- All slices duplicated with allocator
- Proper cleanup in deinit()
- `catch &.{}` provides empty slice fallback on allocation failure

### 4. Type Conversions
- Frame.gas_remaining is GasType (i32 or i64), cast to i64 for storage
- Stack access needs `@constCast(&frame.stack).get_slice()`
- Memory access needs `@constCast(&frame.memory).size()` and `.get_slice()`

## Comprehensive Test Suite

### 1. Basic Execution Tracking
```zig
test "captures simple arithmetic execution" {
    // Bytecode: PUSH1 0x05, PUSH1 0x03, ADD, STOP
    // Verify: gas usage, stack evolution, no state changes
}

test "captures memory operations" {
    // Bytecode: PUSH1 0x42, PUSH1 0x00, MSTORE, PUSH1 0x20, PUSH1 0x00, RETURN
    // Verify: memory capture (capped at 4KB), memory expansion gas
}

test "captures calldata and return data" {
    // Execute with calldata: 0xabcdef
    // Bytecode: CALLDATASIZE, PUSH1 0x00, PUSH1 0x00, CALLDATACOPY, RETURN
    // Verify: initial calldata, final output/return_data
}
```

### 2. Gas Accounting
```zig
test "tracks gas consumption accurately" {
    // Bytecode with known gas costs: ADD (3), MUL (5), SSTORE (20000)
    // Verify: gas_used = initial - final, matches expected
}

test "captures gas refunds from storage operations" {
    // Bytecode: SSTORE slot from non-zero to zero (refund case)
    // Verify: gas_refund_counter increases
}

test "handles out of gas scenario" {
    // Bytecode: expensive operations with limited gas
    // Verify: partial execution captured, gas_left = 0
}
```

### 3. Access Tracking
```zig
test "tracks all address accesses" {
    // Bytecode: BALANCE of 0xAAA, EXTCODESIZE of 0xBBB
    // Verify: both addresses in addresses_accessed
}

test "tracks all storage accesses" {
    // Bytecode: SLOAD 0x5, SSTORE 0x7
    // Verify: both slots in storage_accessed
}

test "deduplicates repeated accesses" {
    // Bytecode: SLOAD 0x5, SLOAD 0x5 again
    // Verify: only one entry for slot 0x5
}
```

### 4. State Changes via Journal
```zig
test "captures storage changes with original values" {
    // Setup: slot 0x5 = 100
    // Bytecode: PUSH1 0x96 (150), PUSH1 0x05, SSTORE
    // Verify: state_changes shows original: 100, new: 150
}

test "captures balance changes" {
    // Bytecode: CALL with value transfer
    // Verify: balance changes for sender and receiver
}

test "captures nonce changes" {
    // Bytecode: CREATE or CREATE2
    // Verify: nonce increment captured
}

test "captures account creation" {
    // Bytecode: CREATE2 to new address
    // Verify: account_created in state_changes
}

test "captures account destruction" {
    // Bytecode: SELFDESTRUCT to beneficiary
    // Verify: account_destroyed with beneficiary and balance
}
```

### 5. Logs and Events
```zig
test "captures LOG0 through LOG4" {
    // Bytecode: LOG0, LOG1, LOG2, LOG3, LOG4 with different data
    // Verify: all logs captured with correct topics and data
}

test "distinguishes new logs from existing" {
    // Pre-existing: 5 logs
    // Bytecode: emit 2 new logs
    // Verify: only 2 logs in logs_emitted
}
```

### 6. Stack Operations
```zig
test "captures final stack state" {
    // Bytecode: PUSH values, DUP1, SWAP1
    // Verify: final stack matches expected
}

test "handles empty stack" {
    // Bytecode: no stack operations
    // Verify: empty stack array
}

test "captures maximum stack depth" {
    // Bytecode: Push 1024 values
    // Verify: full stack captured
}
```

### 7. Memory Edge Cases
```zig
test "captures memory up to 4KB limit" {
    // Bytecode: MSTORE to create 5KB of memory
    // Verify: only first 4KB captured
}

test "handles zero-length memory" {
    // Bytecode: no memory operations
    // Verify: empty memory array
}
```

### 8. Static Call Context
```zig
test "tracks static context flag" {
    // Execute in STATICCALL context
    // Verify: is_static = true
}

test "prevents state changes in static context" {
    // Bytecode: SSTORE in static context (should fail)
    // Verify: error captured, no state changes
}
```

### 9. Error Scenarios
```zig
test "handles allocation failures gracefully" {
    // Simulate OOM during capture
    // Verify: partial data with empty arrays as fallback
}

test "handles invalid opcodes" {
    // Bytecode: 0xFE (INVALID)
    // Verify: execution up to invalid opcode captured
}

test "handles revert with data" {
    // Bytecode: REVERT with return data
    // Verify: return_data captured, state changes present
}
```

### 10. Integration Tests
```zig
test "captures complex DeFi swap transaction" {
    // Bytecode: token transfers, state updates, event emissions
    // Verify: all state changes, logs, gas usage correct
}

test "empty execution produces minimal trace" {
    // Bytecode: just STOP
    // Verify: minimal but complete trace
}
```

## Success Criteria

- All test cases pass
- No memory leaks in any scenario
- Performance overhead < 10% vs non-tracing execution
- Handles all EVM opcodes correctly
- Graceful degradation on errors (never panics)