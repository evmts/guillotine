const std = @import("std");
const primitives = @import("voltaire");
const Address = primitives.Address.Address;
const UnifiedOpcode = @import("../../opcodes/opcode.zig").UnifiedOpcode;

// Transaction lifecycle events

/// Transaction initialization
pub const TransactionStart = struct {
    from: Address,
    to: ?Address,
    value: u256,
    input: []const u8,
    gas_limit: u64,
    gas_price: u256,
    nonce: u64,
    tx_type: TxType,
    access_list: ?[]AccessListItem,
    chain_id: ?u64,
    max_fee_per_gas: ?u256,
    max_priority_fee_per_gas: ?u256,
};

/// Transaction completion
pub const TransactionEnd = struct {
    output: []const u8,
    gas_used: u64,
    gas_refunded: u64,
    success: bool,
    error_msg: ?[]const u8,
    logs_bloom: [256]u8,
    created_address: ?Address,
};

/// Block context information
pub const BlockContext = struct {
    block_number: u64,
    timestamp: u64,
    base_fee: ?u256,
    gas_limit: u64,
    coinbase: Address,
    difficulty: u256,
    prev_randao: ?u256,
    blob_base_fee: ?u256,
};

// Execution lifecycle events

/// Individual VM execution step
pub const VmStep = struct {
    pc: u32,
    op: UnifiedOpcode,
    gas_remaining: i64,
    gas_cost: u64,
    depth: u16,
    stack: []const u256,
    stack_size: u32,
    memory: []const u8,
    memory_size: u32,
    return_data: []const u8,
    contract_address: Address,
    caller: Address,
    value: u256,
};

/// Execution halt (STOP opcode)
pub const ExecutionHalt = struct {
    pc: u32,
    depth: u16,
    gas_left: u64,
    reason: []const u8,
};

/// Opcode frequency tracking
pub const OpcodeFrequency = struct {
    opcode: UnifiedOpcode,
    count: u64,
    total_gas: u64,
    depth: u16,
};

// Call frame lifecycle events

/// Call operation entry
pub const CallEnter = struct {
    call_type: CallType,
    from: Address,
    to: Address,
    value: u256,
    input: []const u8,
    gas: u64,
    depth: u16,
    is_static: bool,
    code_address: Address,
};

/// Call operation exit
pub const CallExit = struct {
    output: []const u8,
    gas_left: u64,
    success: bool,
    error_msg: ?[]const u8,
    depth: u16,
};

/// Create operation entry
pub const CreateEnter = struct {
    create_type: CreateType,
    from: Address,
    value: u256,
    init_code: []const u8,
    gas: u64,
    depth: u16,
    salt: ?u256,
};

/// Create operation exit
pub const CreateExit = struct {
    address: Address,
    deployed_code: []const u8,
    gas_left: u64,
    success: bool,
    error_msg: ?[]const u8,
    depth: u16,
};

// Error lifecycle events

/// Revert event
pub const Revert = struct {
    reason: []const u8,
    depth: u16,
    pc: u32,
    gas_left: u64,
};

/// Invalid opcode encountered
pub const InvalidOpcode = struct {
    opcode: u8,
    pc: u32,
    depth: u16,
    gas_left: u64,
};

/// Out of gas error
pub const OutOfGas = struct {
    required: u64,
    available: u64,
    pc: u32,
    depth: u16,
    operation: []const u8,
};

/// Stack operation error
pub const StackError = struct {
    error_type: StackErrorType,
    depth: u16,
    pc: u32,
    stack_size: u32,
    required_size: ?u32,
};

/// Memory operation error
pub const MemoryError = struct {
    error_type: MemoryErrorType,
    depth: u16,
    pc: u32,
    requested_size: u64,
    max_size: u64,
};

// Precompile lifecycle events

/// Precompile call
pub const PrecompileCall = struct {
    address: Address,
    input: []const u8,
    gas: u64,
    value: u256,
};

/// Precompile result
pub const PrecompileResult = struct {
    address: Address,
    output: []const u8,
    gas_used: u64,
    success: bool,
    error_msg: ?[]const u8,
};

// Contract lifecycle events

/// Self-destruct operation
pub const Selfdestruct = struct {
    address: Address,
    beneficiary: Address,
    balance: u256,
    depth: u16,
};

/// Log emission
pub const LogEmitted = struct {
    address: Address,
    topics: []const u256,
    data: []const u8,
    depth: u16,
    index: u32,
};

// Supporting types

pub const TxType = enum(u8) {
    legacy = 0,
    eip2930 = 1,
    eip1559 = 2,
    eip4844 = 3,
};

pub const CallType = enum {
    call,
    callcode,
    delegatecall,
    staticcall,
};

pub const CreateType = enum {
    create,
    create2,
};

pub const StackErrorType = enum {
    overflow,
    underflow,
    invalid_jump,
    invalid_jump_sub,
};

pub const MemoryErrorType = enum {
    overflow,
    out_of_gas,
    invalid_access,
};

pub const AccessListItem = struct {
    address: Address,
    storage_keys: []const u256,
};

test "lifecycle event sizes" {
    const testing = std.testing;
    
    // Ensure reasonable sizes for lifecycle events
    try testing.expect(@sizeOf(TransactionStart) <= 256);
    try testing.expect(@sizeOf(TransactionEnd) <= 384);
    try testing.expect(@sizeOf(VmStep) <= 256);
    try testing.expect(@sizeOf(CallEnter) <= 128);
    try testing.expect(@sizeOf(CallExit) <= 128);
}