const std = @import("std");
const Evm = @import("evm");
const primitives = @import("primitives");
const Address = primitives.Address;

test "L1BlockInfo loading pre-Ecotone" {
    const op_rules = Evm.optimism.OptimismRules{ .hardfork = .BEDROCK };
    
    // Mock storage reader
    const storage_reader = struct {
        fn read(address: Address.Address, slot: u256) u256 {
            _ = address;
            return switch (slot) {
                Evm.optimism.L1BlockSlots.NUMBER => 12345678,
                Evm.optimism.L1BlockSlots.TIMESTAMP => 1700000000,
                Evm.optimism.L1BlockSlots.BASE_FEE => 30_000_000_000, // 30 gwei
                Evm.optimism.L1BlockSlots.HASH => 0xdeadbeef,
                Evm.optimism.L1BlockSlots.L1_FEE_OVERHEAD => 2100,
                Evm.optimism.L1BlockSlots.L1_FEE_SCALAR => 1_000_000,
                else => 0,
            };
        }
    }.read;
    
    const info = Evm.optimism.loadL1BlockInfo(storage_reader, op_rules);
    
    // Verify pre-Ecotone values
    try std.testing.expectEqual(@as(u64, 12345678), info.l1_block_number);
    try std.testing.expectEqual(@as(u64, 1700000000), info.l1_block_timestamp);
    try std.testing.expectEqual(@as(u256, 30_000_000_000), info.l1_base_fee);
    try std.testing.expectEqual(@as(u256, 2100), info.l1_fee_overhead);
    try std.testing.expectEqual(@as(u256, 1_000_000), info.l1_fee_scalar);
    try std.testing.expect(info.l1_blob_base_fee == null);
}

test "L1BlockInfo loading Ecotone" {
    const op_rules = Evm.optimism.OptimismRules{ .hardfork = .ECOTONE };
    
    // Mock storage reader
    const storage_reader = struct {
        fn read(address: Address.Address, slot: u256) u256 {
            _ = address;
            return switch (slot) {
                Evm.optimism.L1BlockSlots.NUMBER => 12345678,
                Evm.optimism.L1BlockSlots.TIMESTAMP => 1700000000,
                Evm.optimism.L1BlockSlots.BASE_FEE => 30_000_000_000,
                // Packed scalars in slot 3
                Evm.optimism.L1BlockSlots.HASH => Evm.optimism.L1BlockInfo.encodeEcotoneFeeScalars(1000, 2000),
                Evm.optimism.L1BlockSlots.BLOB_BASE_FEE => 1_000_000_000, // 1 gwei
                else => 0,
            };
        }
    }.read;
    
    const info = Evm.optimism.loadL1BlockInfo(storage_reader, op_rules);
    
    // Verify Ecotone values
    try std.testing.expectEqual(@as(u32, 1000), info.l1_base_fee_scalar);
    try std.testing.expectEqual(@as(u32, 2000), info.l1_blob_base_fee_scalar);
    try std.testing.expectEqual(@as(u256, 1_000_000_000), info.l1_blob_base_fee.?);
    // Pre-Ecotone fields should be zero
    try std.testing.expectEqual(@as(u256, 0), info.l1_fee_overhead);
    try std.testing.expectEqual(@as(u256, 0), info.l1_fee_scalar);
}

test "L1BlockInfo loading Isthmus" {
    const op_rules = Evm.optimism.OptimismRules{ .hardfork = .ISTHMUS };
    
    // Mock storage reader
    const storage_reader = struct {
        fn read(address: Address.Address, slot: u256) u256 {
            _ = address;
            return switch (slot) {
                Evm.optimism.L1BlockSlots.NUMBER => 12345678,
                Evm.optimism.L1BlockSlots.TIMESTAMP => 1700000000,
                Evm.optimism.L1BlockSlots.BASE_FEE => 30_000_000_000,
                Evm.optimism.L1BlockSlots.HASH => Evm.optimism.L1BlockInfo.encodeEcotoneFeeScalars(1000, 2000),
                Evm.optimism.L1BlockSlots.BLOB_BASE_FEE => 1_000_000_000,
                // Operator fee params in slot 8
                Evm.optimism.L1BlockSlots.OPERATOR_FEE_PARAMS => Evm.optimism.L1BlockInfo.encodeOperatorFeeParams(500, 100000),
                else => 0,
            };
        }
    }.read;
    
    const info = Evm.optimism.loadL1BlockInfo(storage_reader, op_rules);
    
    // Verify Isthmus values
    try std.testing.expectEqual(@as(u32, 500), info.l1_operator_fee_scalar.?);
    try std.testing.expectEqual(@as(u64, 100000), info.l1_operator_fee_constant.?);
}

test "L1BlockInfoCache" {
    var cache = Evm.optimism.L1BlockInfoCache.init();
    const op_rules = Evm.optimism.OptimismRules{ .hardfork = .BEDROCK };
    
    var call_count: u32 = 0;
    const storage_reader = struct {
        fn read(count: *u32) fn (Address.Address, u256) u256 {
            return struct {
                fn inner(address: Address.Address, slot: u256) u256 {
                    _ = address;
                    _ = slot;
                    count.* += 1;
                    return 42;
                }
            }.inner;
        }
    }.read(&call_count);
    
    // First call loads from storage
    const info1 = cache.get(1000, storage_reader, op_rules);
    try std.testing.expectEqual(@as(u64, 42), info1.l1_block_number);
    try std.testing.expectEqual(@as(u32, 9), call_count); // Multiple slots read
    
    // Same block returns cached value
    const initial_count = call_count;
    const info2 = cache.get(1000, storage_reader, op_rules);
    try std.testing.expectEqual(@as(u64, 42), info2.l1_block_number);
    try std.testing.expectEqual(initial_count, call_count); // No additional reads
    
    // Different block reloads
    const info3 = cache.get(1001, storage_reader, op_rules);
    try std.testing.expectEqual(@as(u64, 42), info3.l1_block_number);
    try std.testing.expect(call_count > initial_count); // Additional reads
}

test "fee scalar encoding and decoding" {
    // Test Ecotone fee scalar encoding/decoding
    const base_scalar: u32 = 1234;
    const blob_scalar: u32 = 5678;
    
    const encoded = Evm.optimism.L1BlockInfo.encodeEcotoneFeeScalars(base_scalar, blob_scalar);
    const decoded = Evm.optimism.L1BlockInfo.decodeEcotoneFeeScalars(encoded);
    
    try std.testing.expectEqual(base_scalar, decoded.base_fee_scalar);
    try std.testing.expectEqual(blob_scalar, decoded.blob_base_fee_scalar);
}

test "operator fee params encoding and decoding" {
    // Test Isthmus operator fee params encoding/decoding
    const scalar: u32 = 9876;
    const constant: u64 = 123456789;
    
    const encoded = Evm.optimism.L1BlockInfo.encodeOperatorFeeParams(scalar, constant);
    const decoded = Evm.optimism.L1BlockInfo.decodeOperatorFeeParams(encoded);
    
    try std.testing.expectEqual(scalar, decoded.scalar);
    try std.testing.expectEqual(constant, decoded.constant);
}