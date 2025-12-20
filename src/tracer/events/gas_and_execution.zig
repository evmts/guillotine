const std = @import("std");
const primitives = @import("voltaire");
const Address = primitives.Address.Address;
const UnifiedOpcode = @import("../../opcodes/opcode.zig").UnifiedOpcode;

/// Gas refund event
pub const GasRefund = struct {
    amount: u64,
    reason: GasRefundReason,
    depth: u16,
};

/// Gas stipend event
pub const GasStipend = struct {
    amount: u64,
    recipient: Address,
    reason: []const u8,
};

/// Intrinsic gas calculation
pub const IntrinsicGas = struct {
    base_cost: u64,
    data_cost: u64,
    access_list_cost: u64,
    total_cost: u64,
};

/// Memory expansion event
pub const MemoryExpansion = struct {
    old_size: u32,
    new_size: u32,
    gas_cost: u64,
    pc: u32,
    depth: u16,
};

/// Function selector detection
pub const FunctionSelector = struct {
    selector: [4]u8,
    address: Address,
    depth: u16,
    gas: u64,
};

/// High-level function call
pub const FunctionCall = struct {
    signature: []const u8,
    selector: [4]u8,
    parameters: []const u8,
    address: Address,
    depth: u16,
};

/// Decoded event from logs
pub const EventDecoded = struct {
    event_signature: []const u8,
    topics: []const u256,
    indexed_params: []const u8,
    data_params: []const u8,
    address: Address,
};

/// External code copy (EXTCODECOPY)
pub const ExternalCodeCopy = struct {
    address: Address,
    offset: u256,
    size: u256,
    dest_offset: u256,
    gas_cost: u64,
};

/// External code size (EXTCODESIZE)
pub const ExternalCodeSize = struct {
    address: Address,
    size: u256,
    gas_cost: u64,
};

/// External code hash (EXTCODEHASH)
pub const ExternalCodeHash = struct {
    address: Address,
    hash: [32]u8,
    gas_cost: u64,
};

/// Return data copy (RETURNDATACOPY)
pub const ReturnDataCopy = struct {
    offset: u256,
    size: u256,
    dest_offset: u256,
    actual_size: u256,
};

/// Jump destination validation
pub const JumpDestination = struct {
    pc: u32,
    target: u32,
    is_valid: bool,
    depth: u16,
};

/// Jump analysis for patterns
pub const JumpAnalysis = struct {
    from_pc: u32,
    to_pc: u32,
    jump_type: JumpType,
    condition: ?u256,
    depth: u16,
};

/// Push data extraction
pub const PushData = struct {
    pc: u32,
    push_size: u8,
    value: u256,
    depth: u16,
};

/// Base fee change (EIP-1559)
pub const BaseFeeChange = struct {
    old_base_fee: u256,
    new_base_fee: u256,
    block_number: u64,
};

/// Priority fee tracking (EIP-1559)
pub const PriorityFee = struct {
    max_fee_per_gas: u256,
    max_priority_fee_per_gas: u256,
    effective_priority_fee: u256,
    tx_hash: [32]u8,
};

/// Blob hash access (EIP-4844)
pub const BlobHashAccess = struct {
    index: u256,
    hash: [32]u8,
    gas_cost: u64,
};

/// Blob base fee (EIP-4844)
pub const BlobBaseFee = struct {
    fee: u256,
    block_number: u64,
};

/// Coinbase address interaction
pub const CoinbaseTouch = struct {
    coinbase: Address,
    interaction_type: []const u8,
    value: u256,
    depth: u16,
};

/// Coinbase payment/reward
pub const CoinbasePayment = struct {
    coinbase: Address,
    amount: u256,
    payment_type: CoinbasePaymentType,
    block_number: u64,
};

// Supporting types
pub const GasRefundReason = enum {
    sstore_clear,
    selfdestruct,
    contract_creation,
};

pub const JumpType = enum {
    unconditional,
    conditional_true,
    conditional_false,
    jumpsub,
    returnsub,
};

pub const CoinbasePaymentType = enum {
    block_reward,
    uncle_reward,
    transaction_fee,
    mev_payment,
};