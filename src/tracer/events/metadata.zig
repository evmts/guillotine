const std = @import("std");
const primitives = @import("voltaire");

// Event metadata
pub const EventMetadata = struct {
    timestamp: u64,
    block_number: u64,
    tx_hash: [32]u8,
    tx_index: u32,
    event_index: u32,
};

// Event serialization hints
pub const SerializationFormat = enum {
    json,
    binary,
    cbor,
    protobuf,
    debug,
};

// Event severity for observability
pub const EventSeverity = enum {
    trace,
    debug,
    info,
    warn,
    err,
    fatal,
};

// Event categories for filtering and routing
pub const EventCategory = enum {
    transaction,
    execution,
    call_frame,
    state_change,
    contract,
    precompile,
    @"error",
    access_list,
    gas,
    function_abi,
    external_code,
    jump_analysis,
    eip1559,
    eip4844,
    mev_defi,
    coinbase,
    token,
    proxy,
    ens,
    defi_protocol,
    beacon_chain,
    layer2,
};

// Event filtering
pub const EventFilter = struct {
    include_vm_steps: bool = true,
    include_storage: bool = true,
    include_memory: bool = true,
    include_stack: bool = true,
    include_access_list: bool = true,
    min_depth: ?u16 = null,
    max_depth: ?u16 = null,
    addresses: ?[]const primitives.Address.Address = null,
    opcodes: ?[]const @import("../../opcodes/opcode.zig").UnifiedOpcode = null,
};