# CLAUDE.md - Storage Module

## MISSION CRITICAL: State Consistency and Fund Safety
**Storage bugs = consensus failures, double-spending, fund loss.** State consistency is paramount.

## EVM Storage Specs (IMMUTABLE)
- **Account State**: Balance, nonce, storage root, code hash
- **Storage Layout**: 256-bit key-value pairs per contract
- **Access Patterns**: Cold/warm gas pricing (EIP-2929)
- **State Root**: Merkle Patricia Trie commitment
- **Checkpointing**: Reversible state changes

## Core Files
- `database.zig` - World state database interface
- `journal.zig` - Transaction-level state change tracking
- `access_list.zig` - EIP-2929 cold/warm storage tracking
- `memory_database.zig` - In-memory state for testing
- `self_destruct.zig` - Contract destruction handling

## Journal System (CRITICAL)
```zig
pub const JournalEntry = union(enum) {
    AccountTouched: Address,
    AccountLoaded: struct { address: Address, info: AccountInfo },
    StorageChanged: struct { address: Address, key: u256, value: u256 },
    BalanceTransfer: struct { from: Address, to: Address, amount: u256 },
    SelfDestruct: Address,
    ContractCreated: struct { address: Address, code: []u8 },
};

// Checkpoint management
pub fn create_checkpoint(self: *Self) u32 {
    return @intCast(self.journal.entries.items.len);
}

pub fn rollback_to_checkpoint(self: *Self, checkpoint: u32) !void {
    while (self.journal.entries.items.len > checkpoint) {
        const entry = self.journal.entries.pop();
        try self.revert_journal_entry(entry);
    }
}
```

## Access List (EIP-2929)
```zig
// Gas costs
pub const COLD_ACCOUNT_ACCESS = 2600;
pub const WARM_ACCOUNT_ACCESS = 100;
pub const COLD_SLOAD = 2100;
pub const WARM_SLOAD = 100;

pub fn access_account(self: *Self, address: Address) u64 {
    if (self.access_list.contains_address(address)) {
        return WARM_ACCOUNT_ACCESS;
    } else {
        self.access_list.add_address(address);
        return COLD_ACCOUNT_ACCESS;
    }
}
```

## Storage Operations

**SLOAD**:
```zig
pub fn sload(self: *Self, address: Address, key: u256) !struct { value: u256, gas: u64 } {
    const gas_cost = if (self.access_list.contains_storage(address, key))
        WARM_SLOAD else COLD_SLOAD;
    if (!self.access_list.contains_storage(address, key)) {
        self.access_list.add_storage(address, key);
    }
    const value = try self.database.get_storage(address, key);
    try self.journal.record_storage_access(address, key, value);
    return .{ .value = value, .gas = gas_cost };
}
```

**SSTORE**:
```zig
pub fn sstore(self: *Self, address: Address, key: u256, value: u256) !u64 {
    const original = try self.database.get_original_storage(address, key);
    const current = try self.database.get_storage(address, key);
    const gas_cost = calculate_sstore_gas(original, current, value); // EIP-2200
    try self.journal.record_storage_change(address, key, current, value);
    try self.database.set_storage(address, key, value);
    return gas_cost;
}
```

## Account Management (FUND SAFETY CRITICAL)

**Balance Transfer**:
```zig
pub fn transfer_balance(self: *Self, from: Address, to: Address, amount: u256) !void {
    const from_info = try self.get_account_info(from);
    if (from_info.balance < amount) return error.InsufficientBalance;

    try self.journal.record_balance_transfer(from, to, amount);
    from_info.balance -= amount;
    const to_info = try self.get_account_info(to);
    to_info.balance += amount;
    try self.set_account_info(from, from_info);
    try self.set_account_info(to, to_info);
}
```

**Contract Creation**:
```zig
pub fn create_contract(self: *Self, address: Address, code: []const u8, balance: u256) !void {
    const existing = try self.get_account_info(address);
    if (existing.nonce != 0 or existing.code_hash != EMPTY_CODE_HASH) {
        return error.AddressCollision;
    }
    try self.journal.record_contract_creation(address, code);
    const account_info = AccountInfo{
        .balance = balance,
        .nonce = 1, // Contracts start with nonce 1
        .code_hash = crypto.keccak256(code),
    };
    try self.set_account_info(address, account_info);
    try self.database.set_code(address, code);
}
```

## Self-Destruct (EIP-6780)
```zig
pub fn self_destruct(self: *Self, address: Address, beneficiary: Address) !void {
    // Only contracts created in same transaction can be destructed
    if (!self.created_contracts.contains(address)) {
        const info = try self.get_account_info(address);
        try self.transfer_balance(address, beneficiary, info.balance);
        return;
    }
    try self.journal.record_self_destruct(address);
    const info = try self.get_account_info(address);
    try self.transfer_balance(address, beneficiary, info.balance);
    try self.self_destruct_list.add(address);
}
```

## Critical Error Handling

**State Corruption Prevention**: Never allow inconsistent state
**Rollback Safety**: Must be able to rollback any state change
**Performance**: Cache accounts, batch operations, minimize DB round trips

## Testing & Emergency
- **Tests**: Balance transfers, storage gas costs, journal rollback, address collisions
- **Emergency**: Halt modifications, consistency checks, journal analysis, rollback strategy

**State consistency is non-negotiable. Bugs permanently corrupt blockchain state.**