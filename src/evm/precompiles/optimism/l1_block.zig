const std = @import("std");
const PrecompileOutput = @import("../precompile_result.zig").PrecompileOutput;
const PrecompileError = @import("../precompile_result.zig").PrecompileError;
const primitives = @import("primitives");
const Address = primitives.Address;
const L1BlockSlots = @import("../../optimism/l1_block_info.zig").L1BlockSlots;
const L1BlockInfo = @import("../../optimism/l1_block_info.zig").L1BlockInfo;
const OptimismRules = @import("../../optimism/hardfork.zig").OptimismRules;

/// L1Block precompile address
pub const L1_BLOCK_ADDRESS = Address.from_hex("0x4200000000000000000000000000000000000015") catch unreachable;

/// Context for L1Block precompile execution
pub const L1BlockContext = struct {
    /// Function to read storage from L1Block contract
    storage_reader: *const fn (address: Address, slot: u256) u256,
    /// Optimism rules for hardfork-specific behavior
    op_rules: OptimismRules,
};

/// L1Block precompile (0x4200000000000000000000000000000000000015)
/// Provides information about the L1 chain by reading from contract storage
///
/// Storage layout:
/// - Slot 0: L1 block number
/// - Slot 1: L1 block timestamp
/// - Slot 2: L1 base fee
/// - Slot 3: L1 block hash (or packed fee scalars in Ecotone+)
/// - Slot 4: Sequence number
/// - Slot 5: Batcher hash (or L1 fee overhead pre-Ecotone)
/// - Slot 6: L1 fee scalar (pre-Ecotone)
/// - Slot 7: L1 blob base fee (Ecotone+)
/// - Slot 8: Operator fee params (Isthmus+)
pub fn execute(input: []const u8, output: []u8, gas_limit: u64) PrecompileOutput {
    // TODO: This is a temporary implementation that returns mock values
    // In production, this needs access to the storage reader context
    return executeMock(input, output, gas_limit);
}

/// Execute with storage access (production implementation)
pub fn executeWithContext(input: []const u8, output: []u8, gas_limit: u64, context: L1BlockContext) PrecompileOutput {
    const base_gas_cost = 100;
    
    if (base_gas_cost > gas_limit) {
        return PrecompileOutput.failure_result(PrecompileError.OutOfGas);
    }
    
    if (input.len < 4) {
        return PrecompileOutput.failure_result(PrecompileError.InvalidInput);
    }
    
    // Get function selector (first 4 bytes)
    const selector = std.mem.readInt(u32, input[0..4], .big);
    
    // Read storage based on selector
    const result: usize = switch (selector) {
        // number() - 0x8381f58a
        0x8381f58a => blk: {
            if (output.len < 32) {
                return PrecompileOutput.failure_result(PrecompileError.ExecutionFailed);
            }
            const value = context.storage_reader(L1_BLOCK_ADDRESS, L1BlockSlots.NUMBER);
            std.mem.writeInt(u256, output[0..32], value, .big);
            break :blk 32;
        },
        // timestamp() - 0xb80777ea
        0xb80777ea => blk: {
            if (output.len < 32) {
                return PrecompileOutput.failure_result(PrecompileError.ExecutionFailed);
            }
            const value = context.storage_reader(L1_BLOCK_ADDRESS, L1BlockSlots.TIMESTAMP);
            std.mem.writeInt(u256, output[0..32], value, .big);
            break :blk 32;
        },
        // basefee() - 0x5cf24969
        0x5cf24969 => blk: {
            if (output.len < 32) {
                return PrecompileOutput.failure_result(PrecompileError.ExecutionFailed);
            }
            const value = context.storage_reader(L1_BLOCK_ADDRESS, L1BlockSlots.BASE_FEE);
            std.mem.writeInt(u256, output[0..32], value, .big);
            break :blk 32;
        },
        // hash() - 0x09bd5a60
        0x09bd5a60 => blk: {
            if (output.len < 32) {
                return PrecompileOutput.failure_result(PrecompileError.ExecutionFailed);
            }
            const value = context.storage_reader(L1_BLOCK_ADDRESS, L1BlockSlots.HASH);
            std.mem.writeInt(u256, output[0..32], value, .big);
            break :blk 32;
        },
        // blobBaseFee() - 0xf8206140 (Ecotone+)
        0xf8206140 => blk: {
            if (!context.op_rules.isEcotone()) {
                return PrecompileOutput.failure_result(PrecompileError.InvalidInput);
            }
            if (output.len < 32) {
                return PrecompileOutput.failure_result(PrecompileError.ExecutionFailed);
            }
            const value = context.storage_reader(L1_BLOCK_ADDRESS, L1BlockSlots.BLOB_BASE_FEE);
            std.mem.writeInt(u256, output[0..32], value, .big);
            break :blk 32;
        },
        else => return PrecompileOutput.failure_result(PrecompileError.InvalidInput),
    };
    
    return PrecompileOutput.success_result(base_gas_cost, result);
}

/// Temporary mock implementation until storage access is integrated
fn executeMock(input: []const u8, output: []u8, gas_limit: u64) PrecompileOutput {
    const gas_cost = 100;
    
    if (gas_cost > gas_limit) {
        return PrecompileOutput.failure_result(PrecompileError.OutOfGas);
    }
    
    if (input.len < 4) {
        return PrecompileOutput.failure_result(PrecompileError.InvalidInput);
    }
    
    const selector = std.mem.readInt(u32, input[0..4], .big);
    
    const result: usize = switch (selector) {
        0x8381f58a => blk: {
            if (output.len < 32) {
                return PrecompileOutput.failure_result(PrecompileError.ExecutionFailed);
            }
            @memset(output[0..32], 0);
            output[30] = 0x01;
            output[31] = 0x00;
            break :blk 32;
        },
        0xb80777ea => blk: {
            if (output.len < 32) {
                return PrecompileOutput.failure_result(PrecompileError.ExecutionFailed);
            }
            @memset(output[0..32], 0);
            output[28] = 0x65;
            output[29] = 0x00;
            output[30] = 0x00;
            output[31] = 0x00;
            break :blk 32;
        },
        0x5cf24969 => blk: {
            if (output.len < 32) {
                return PrecompileOutput.failure_result(PrecompileError.ExecutionFailed);
            }
            @memset(output[0..32], 0);
            output[31] = 30;
            break :blk 32;
        },
        else => return PrecompileOutput.failure_result(PrecompileError.InvalidInput),
    };
    
    return PrecompileOutput.success_result(gas_cost, result);
}

test "L1Block number" {
    // number() selector
    const input = &[_]u8{ 0x83, 0x81, 0xf5, 0x8a };
    var output: [32]u8 = undefined;
    
    const result = execute(input, &output, 1000);
    
    try std.testing.expect(result.is_success());
    try std.testing.expectEqual(@as(u64, 100), result.get_gas_used());
    try std.testing.expectEqual(@as(usize, 32), result.get_output_size());
    try std.testing.expectEqual(@as(u8, 0x01), output[30]);
    try std.testing.expectEqual(@as(u8, 0x00), output[31]);
}

test "L1Block timestamp" {
    // timestamp() selector
    const input = &[_]u8{ 0xb8, 0x07, 0x77, 0xea };
    var output: [32]u8 = undefined;
    
    const result = execute(input, &output, 1000);
    
    try std.testing.expect(result.is_success());
    try std.testing.expectEqual(@as(u64, 100), result.get_gas_used());
    try std.testing.expectEqual(@as(usize, 32), result.get_output_size());
    try std.testing.expectEqual(@as(u8, 0x65), output[28]);
}