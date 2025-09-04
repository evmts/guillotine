//! Optimism L1Block Precompile
//!
//! The L1Block precompile provides access to L1 (Ethereum mainnet) block information
//! for Layer 2 networks like Optimism. It's accessible at the special address:
//! 0x4200000000000000000000000000000000000015
//!
//! ## Storage Layout
//! The L1Block precompile stores L1 block information in specific storage slots:
//! - Slot 0: L1 block number (uint64)
//! - Slot 1: L1 block timestamp (uint64)  
//! - Slot 2: L1 base fee (uint256)
//! - Slot 3: L1 block hash (bytes32)
//! - Slot 4: L2 sequence number (uint64)
//! - Slot 5: L1 batcher hash (bytes32)
//! - Slot 6: L1 fee overhead (uint64)
//! - Slot 7: L1 fee scalar (uint64)
//!
//! ## Interface
//! The precompile acts as a view-only contract that returns L1 block information
//! when called. It takes no input parameters and returns all L1 data concatenated.

const std = @import("std");
const testing = std.testing;
const primitives = @import("primitives");
const Address = primitives.Address;

/// L1Block precompile address: 0x4200000000000000000000000000000000000015
pub const L1_BLOCK_ADDRESS = Address.from_hex("0x4200000000000000000000000000000000000015") catch unreachable;

/// L1Block precompile output structure
pub const PrecompileOutput = struct {
    output: []u8,
    gas_used: u64,
    success: bool,
};

/// L1 block information structure
pub const L1BlockInfo = struct {
    number: u64,
    timestamp: u64,
    base_fee: u256,
    hash: [32]u8,
    sequence_number: u64,
    batcher_hash: [32]u8,
    l1_fee_overhead: u64,
    l1_fee_scalar: u64,
};

/// L1Block precompile error types
pub const L1BlockError = error{
    OutOfGas,
    OutOfMemory,
    InvalidInput,
};

/// Gas cost for L1Block precompile call
pub const L1_BLOCK_GAS_COST: u64 = 1000;

/// Check if an address is the L1Block precompile
pub fn is_l1_block_precompile(address: Address) bool {
    return std.mem.eql(u8, &address.bytes, &L1_BLOCK_ADDRESS.bytes);
}

/// Check if an address is an Optimism precompile
pub fn is_optimism_precompile(address: Address) bool {
    // Optimism precompiles start with 0x4200000000000000000000000000000000000000
    const optimism_prefix = [_]u8{0x42} ++ [_]u8{0x00} ** 18;
    return std.mem.eql(u8, address.bytes[0..19], &optimism_prefix);
}

/// Execute L1Block precompile
/// Returns concatenated L1 block information (256 bytes total)
pub fn execute_l1_block_precompile(
    allocator: std.mem.Allocator,
    input: []const u8,
    gas_limit: u64,
    l1_info: L1BlockInfo,
) L1BlockError!PrecompileOutput {
    // L1Block takes no input
    _ = input;
    
    if (gas_limit < L1_BLOCK_GAS_COST) {
        return PrecompileOutput{
            .output = &.{},
            .gas_used = gas_limit,
            .success = false,
        };
    }

    // Allocate output buffer (8 fields * 32 bytes each = 256 bytes)
    var output = try allocator.alloc(u8, 256);
    
    // Encode L1 block information into output buffer
    // Each field is padded to 32 bytes (256 bits)
    
    // Slot 0: L1 block number
    std.mem.writeInt(u256, output[0..32], l1_info.number, .big);
    
    // Slot 1: L1 block timestamp  
    std.mem.writeInt(u256, output[32..64], l1_info.timestamp, .big);
    
    // Slot 2: L1 base fee
    std.mem.writeInt(u256, output[64..96], l1_info.base_fee, .big);
    
    // Slot 3: L1 block hash
    @memcpy(output[96..128], &l1_info.hash);
    
    // Slot 4: L2 sequence number
    std.mem.writeInt(u256, output[128..160], l1_info.sequence_number, .big);
    
    // Slot 5: L1 batcher hash
    @memcpy(output[160..192], &l1_info.batcher_hash);
    
    // Slot 6: L1 fee overhead
    std.mem.writeInt(u256, output[192..224], l1_info.l1_fee_overhead, .big);
    
    // Slot 7: L1 fee scalar
    std.mem.writeInt(u256, output[224..256], l1_info.l1_fee_scalar, .big);

    return PrecompileOutput{
        .output = output,
        .gas_used = L1_BLOCK_GAS_COST,
        .success = true,
    };
}

/// Decode L1 block information from storage slots
pub fn decode_l1_block_from_storage(storage_data: [256]u8) L1BlockInfo {
    return L1BlockInfo{
        .number = @truncate(std.mem.readInt(u256, storage_data[0..32], .big)),
        .timestamp = @truncate(std.mem.readInt(u256, storage_data[32..64], .big)),
        .base_fee = std.mem.readInt(u256, storage_data[64..96], .big),
        .hash = storage_data[96..128].*,
        .sequence_number = @truncate(std.mem.readInt(u256, storage_data[128..160], .big)),
        .batcher_hash = storage_data[160..192].*,
        .l1_fee_overhead = @truncate(std.mem.readInt(u256, storage_data[192..224], .big)),
        .l1_fee_scalar = @truncate(std.mem.readInt(u256, storage_data[224..256], .big)),
    };
}

// Tests following TDD approach

test "l1block precompile address detection" {
    const l1_block_addr = L1_BLOCK_ADDRESS;
    const regular_addr = Address.from_hex("0x0123456789012345678901234567890123456789") catch unreachable;
    
    try testing.expect(is_l1_block_precompile(l1_block_addr));
    try testing.expect(!is_l1_block_precompile(regular_addr));
}

test "optimism precompile detection" {
    const l1_block_addr = L1_BLOCK_ADDRESS;
    const ethereum_precompile = Address.from_u256(1); // ecRecover
    const regular_addr = Address.from_hex("0x0123456789012345678901234567890123456789") catch unreachable;
    
    try testing.expect(is_optimism_precompile(l1_block_addr));
    try testing.expect(!is_optimism_precompile(ethereum_precompile));
    try testing.expect(!is_optimism_precompile(regular_addr));
}

test "l1block precompile execution success" {
    const allocator = testing.allocator;
    const input = &[_]u8{}; // L1Block takes no input
    
    const l1_info = L1BlockInfo{
        .number = 12345,
        .timestamp = 1625097600,
        .base_fee = 1000000000, // 1 gwei
        .hash = [_]u8{0xab} ** 32,
        .sequence_number = 1,
        .batcher_hash = [_]u8{0xcd} ** 32,
        .l1_fee_overhead = 188,
        .l1_fee_scalar = 684000,
    };
    
    const result = try execute_l1_block_precompile(allocator, input, 100000, l1_info);
    defer allocator.free(result.output);
    
    try testing.expect(result.success);
    try testing.expectEqual(@as(u64, L1_BLOCK_GAS_COST), result.gas_used);
    try testing.expectEqual(@as(usize, 256), result.output.len);
    
    // Verify first field (L1 block number)
    const decoded_number = @as(u64, @truncate(std.mem.readInt(u256, result.output[0..32], .big)));
    try testing.expectEqual(@as(u64, 12345), decoded_number);
    
    // Verify second field (L1 timestamp)
    const decoded_timestamp = @as(u64, @truncate(std.mem.readInt(u256, result.output[32..64], .big)));
    try testing.expectEqual(@as(u64, 1625097600), decoded_timestamp);
    
    // Verify third field (L1 base fee)
    const decoded_base_fee = std.mem.readInt(u256, result.output[64..96], .big);
    try testing.expectEqual(@as(u256, 1000000000), decoded_base_fee);
}

test "l1block precompile out of gas" {
    const allocator = testing.allocator;
    const input = &[_]u8{};
    
    const l1_info = L1BlockInfo{
        .number = 1,
        .timestamp = 1,
        .base_fee = 1,
        .hash = [_]u8{0x01} ** 32,
        .sequence_number = 1,
        .batcher_hash = [_]u8{0x02} ** 32,
        .l1_fee_overhead = 1,
        .l1_fee_scalar = 1,
    };
    
    const result = try execute_l1_block_precompile(allocator, input, 100, l1_info); // Less than L1_BLOCK_GAS_COST
    
    try testing.expect(!result.success);
    try testing.expectEqual(@as(u64, 100), result.gas_used);
    try testing.expectEqual(@as(usize, 0), result.output.len);
}

test "l1block info encoding decoding" {
    const original_info = L1BlockInfo{
        .number = 98765,
        .timestamp = 1650000000,
        .base_fee = 2500000000, // 2.5 gwei
        .hash = [_]u8{0x12} ** 32,
        .sequence_number = 42,
        .batcher_hash = [_]u8{0x34} ** 32,
        .l1_fee_overhead = 200,
        .l1_fee_scalar = 700000,
    };
    
    // Manually encode to storage format
    var storage_data: [256]u8 = [_]u8{0} ** 256;
    
    std.mem.writeInt(u256, storage_data[0..32], original_info.number, .big);
    std.mem.writeInt(u256, storage_data[32..64], original_info.timestamp, .big);
    std.mem.writeInt(u256, storage_data[64..96], original_info.base_fee, .big);
    @memcpy(storage_data[96..128], &original_info.hash);
    std.mem.writeInt(u256, storage_data[128..160], original_info.sequence_number, .big);
    @memcpy(storage_data[160..192], &original_info.batcher_hash);
    std.mem.writeInt(u256, storage_data[192..224], original_info.l1_fee_overhead, .big);
    std.mem.writeInt(u256, storage_data[224..256], original_info.l1_fee_scalar, .big);
    
    // Decode and verify
    const decoded_info = decode_l1_block_from_storage(storage_data);
    
    try testing.expectEqual(original_info.number, decoded_info.number);
    try testing.expectEqual(original_info.timestamp, decoded_info.timestamp);
    try testing.expectEqual(original_info.base_fee, decoded_info.base_fee);
    try testing.expectEqual(original_info.hash, decoded_info.hash);
    try testing.expectEqual(original_info.sequence_number, decoded_info.sequence_number);
    try testing.expectEqual(original_info.batcher_hash, decoded_info.batcher_hash);
    try testing.expectEqual(original_info.l1_fee_overhead, decoded_info.l1_fee_overhead);
    try testing.expectEqual(original_info.l1_fee_scalar, decoded_info.l1_fee_scalar);
}