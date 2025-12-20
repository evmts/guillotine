const std = @import("std");
const primitives = @import("voltaire");
const Address = primitives.Address.Address;

/// Storage slot read
pub const StorageRead = struct {
    address: Address,
    slot: u256,
    value: u256,
    was_warm: bool,
};

/// Storage slot write
pub const StorageWrite = struct {
    address: Address,
    slot: u256,
    old_value: u256,
    new_value: u256,
    was_warm: bool,
};

/// Storage cold access (first access)
pub const StorageColdAccess = struct {
    address: Address,
    slot: u256,
    value: u256,
    gas_cost: u64,
};

/// Transient storage read (TLOAD)
pub const TransientStorageRead = struct {
    address: Address,
    slot: u256,
    value: u256,
    depth: u16,
};

/// Transient storage write (TSTORE)
pub const TransientStorageWrite = struct {
    address: Address,
    slot: u256,
    old_value: u256,
    new_value: u256,
    depth: u16,
};

/// Account balance change
pub const BalanceChange = struct {
    address: Address,
    old_balance: u256,
    new_balance: u256,
    reason: BalanceChangeReason,
};

/// Account nonce change
pub const NonceChange = struct {
    address: Address,
    old_nonce: u64,
    new_nonce: u64,
};

/// Contract code change
pub const CodeChange = struct {
    address: Address,
    old_code: []const u8,
    new_code: []const u8,
    old_code_hash: [32]u8,
    new_code_hash: [32]u8,
};

/// Account creation
pub const AccountCreated = struct {
    address: Address,
    creator: Address,
    initial_balance: u256,
    initial_nonce: u64,
    code: []const u8,
};

/// Account deletion (empty account)
pub const AccountDeleted = struct {
    address: Address,
    final_balance: u256,
    final_nonce: u64,
};

/// State changes committed to database
pub const StateCommitted = struct {
    accounts_modified: u32,
    storage_slots_modified: u32,
    accounts_created: u32,
    accounts_deleted: u32,
    total_gas_used: u64,
    state_root: ?[32]u8,
    commit_type: CommitType,
    depth: u16,
    success: bool,
};

/// Account access (EIP-2929)
pub const AccountAccessed = struct {
    address: Address,
    was_warm: bool,
    access_type: AccessType,
};

/// Storage access (EIP-2929)
pub const StorageAccessed = struct {
    address: Address,
    slot: u256,
    was_warm: bool,
    access_type: AccessType,
};

/// Account warming (EIP-2929)
pub const AccountWarmed = struct {
    address: Address,
};

/// Storage warming (EIP-2929)
pub const StorageWarmed = struct {
    address: Address,
    slot: u256,
};

// Supporting types
pub const BalanceChangeReason = enum {
    transfer,
    gas_payment,
    gas_refund,
    reward,
    selfdestruct,
    creation,
};

pub const CommitType = enum {
    transaction,
    block,
    checkpoint,
    journal_revert,
    call_frame,
    create_frame,
};

pub const AccessType = enum {
    balance,
    code,
    code_hash,
    storage,
    call,
    selfdestruct,
};