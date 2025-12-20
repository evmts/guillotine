const std = @import("std");
const primitives = @import("voltaire");
const Address = primitives.Address.Address;

/// Beacon chain deposit (32 ETH staking)
pub const BeaconDeposit = struct {
    pubkey: [48]u8,
    withdrawal_credentials: [32]u8,
    amount: u256,
    signature: [96]u8,
    index: u64,
    from: Address,
    block_number: u64,
};

/// Validator withdrawal from beacon chain
pub const ValidatorWithdrawal = struct {
    index: u64,
    validator_index: u64,
    address: Address,
    amount: u256,
    withdrawal_type: WithdrawalType,
    block_number: u64,
};

/// Withdrawal request submitted
pub const WithdrawalRequest = struct {
    validator_index: u64,
    amount: u256,
    recipient: Address,
    request_epoch: u64,
    processed: bool,
};

/// Partial withdrawal (rewards only)
pub const PartialWithdrawal = struct {
    validator_index: u64,
    recipient: Address,
    amount: u256,
    effective_balance: u256,
    epoch: u64,
};

/// Full withdrawal (exit + rewards)
pub const FullWithdrawal = struct {
    validator_index: u64,
    recipient: Address,
    amount: u256,
    exit_epoch: u64,
    withdrawable_epoch: u64,
};

/// Slashing event for validator misbehavior
pub const SlashingEvent = struct {
    validator_index: u64,
    slasher_index: ?u64,
    slashed_amount: u256,
    whistleblower_reward: u256,
    proposer_reward: u256,
    epoch: u64,
    reason: SlashingReason,
};

/// Sync committee update
pub const SyncCommitteeUpdate = struct {
    period: u64,
    committee_indices: []const u64,
    aggregate_pubkey: [48]u8,
};

/// Bridge deposit to L2
pub const BridgeDeposit = struct {
    bridge: Address,
    from: Address,
    to: Address,
    token: Address,
    amount: u256,
    destination_chain_id: u256,
    nonce: u64,
    message: []const u8,
};

/// Bridge withdrawal from L2
pub const BridgeWithdrawal = struct {
    bridge: Address,
    from: Address,
    to: Address,
    token: Address,
    amount: u256,
    source_chain_id: u256,
    withdrawal_hash: [32]u8,
    proven: bool,
    finalized: bool,
};

/// Cross-chain bridge message
pub const BridgeMessage = struct {
    bridge: Address,
    sender: Address,
    target: Address,
    value: u256,
    message: []const u8,
    nonce: u64,
    gas_limit: u64,
};

/// Rollup batch submission
pub const RollupBatch = struct {
    sequencer: Address,
    batch_index: u64,
    batch_root: [32]u8,
    batch_size: u32,
    prev_total_elements: u64,
    extra_data: []const u8,
    timestamp: u64,
    l1_block_number: u64,
};

/// State root published to L1
pub const StateRootPublished = struct {
    rollup: Address,
    state_root: [32]u8,
    batch_index: u64,
    l2_block_number: u64,
    l1_block_number: u64,
    proposer: Address,
};

// Supporting types
pub const WithdrawalType = enum {
    partial,
    full,
    forced,
    sweep,
};

pub const SlashingReason = enum {
    double_vote,
    surround_vote,
    double_proposal,
    attester_slashing,
    proposer_slashing,
};