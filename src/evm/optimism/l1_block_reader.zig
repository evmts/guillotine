const std = @import("std");
const primitives = @import("primitives");
const Address = primitives.Address;
const B256 = @import("crypto").Hash.B256;
const L1BlockInfo = @import("l1_block_info.zig").L1BlockInfo;
const L1BlockSlots = @import("l1_block_info.zig").L1BlockSlots;
const OptimismRules = @import("hardfork.zig").OptimismRules;

/// L1Block contract address
pub const L1_BLOCK_ADDRESS = Address.from_hex("0x4200000000000000000000000000000000000015") catch unreachable;

/// Storage reader function type
pub const StorageReader = fn (address: Address, slot: u256) u256;

/// Load L1BlockInfo from storage
pub fn loadL1BlockInfo(storage_reader: StorageReader, op_rules: OptimismRules) L1BlockInfo {
    var info = L1BlockInfo{
        .l1_block_number = @truncate(storage_reader(L1_BLOCK_ADDRESS, L1BlockSlots.NUMBER)),
        .l1_block_timestamp = @truncate(storage_reader(L1_BLOCK_ADDRESS, L1BlockSlots.TIMESTAMP)),
        .l1_base_fee = storage_reader(L1_BLOCK_ADDRESS, L1BlockSlots.BASE_FEE),
        .l1_block_hash = std.mem.zeroes(B256), // Will be set below
        .l1_fee_overhead = 0,
        .l1_fee_scalar = 0,
        .l1_blob_base_fee = null,
        .l1_base_fee_scalar = 0,
        .l1_blob_base_fee_scalar = 0,
        .l1_operator_fee_scalar = null,
        .l1_operator_fee_constant = null,
    };
    
    // Read block hash or packed scalars from slot 3
    const slot3_value = storage_reader(L1_BLOCK_ADDRESS, L1BlockSlots.HASH);
    
    if (op_rules.isEcotone()) {
        // Ecotone+ uses slot 3 for packed fee scalars
        const scalars = L1BlockInfo.decodeEcotoneFeeScalars(slot3_value);
        info.l1_base_fee_scalar = scalars.base_fee_scalar;
        info.l1_blob_base_fee_scalar = scalars.blob_base_fee_scalar;
        
        // Read blob base fee
        info.l1_blob_base_fee = storage_reader(L1_BLOCK_ADDRESS, L1BlockSlots.BLOB_BASE_FEE);
        
        // Isthmus+ adds operator fee params
        if (op_rules.isIsthmus()) {
            const slot8_value = storage_reader(L1_BLOCK_ADDRESS, L1BlockSlots.OPERATOR_FEE_PARAMS);
            const operator_params = L1BlockInfo.decodeOperatorFeeParams(slot8_value);
            info.l1_operator_fee_scalar = operator_params.scalar;
            info.l1_operator_fee_constant = operator_params.constant;
        }
    } else {
        // Pre-Ecotone uses slot 3 for block hash
        std.mem.writeInt(u256, &info.l1_block_hash, slot3_value, .big);
        
        // Read overhead and scalar from slots 5 and 6
        info.l1_fee_overhead = @truncate(storage_reader(L1_BLOCK_ADDRESS, L1BlockSlots.L1_FEE_OVERHEAD));
        info.l1_fee_scalar = @truncate(storage_reader(L1_BLOCK_ADDRESS, L1BlockSlots.L1_FEE_SCALAR));
    }
    
    return info;
}

/// Cache for L1BlockInfo to avoid repeated storage reads
pub const L1BlockInfoCache = struct {
    /// Cached L1BlockInfo
    info: ?L1BlockInfo,
    /// L2 block number when cache was populated
    l2_block_number: u64,
    
    /// Initialize empty cache
    pub fn init() L1BlockInfoCache {
        return .{
            .info = null,
            .l2_block_number = 0,
        };
    }
    
    /// Get L1BlockInfo, loading from storage if needed
    pub fn get(self: *L1BlockInfoCache, l2_block_number: u64, storage_reader: StorageReader, op_rules: OptimismRules) L1BlockInfo {
        // Reload if block number changed
        if (self.info == null or self.l2_block_number != l2_block_number) {
            self.info = loadL1BlockInfo(storage_reader, op_rules);
            self.l2_block_number = l2_block_number;
        }
        return self.info.?;
    }
    
    /// Clear the cache
    pub fn clear(self: *L1BlockInfoCache) void {
        self.info = null;
        self.l2_block_number = 0;
    }
};

test "loadL1BlockInfo pre-Ecotone" {
    const op_rules = OptimismRules{ .hardfork = .BEDROCK };
    
    // Mock storage reader
    const storage_reader = struct {
        fn read(address: Address, slot: u256) u256 {
            _ = address;
            return switch (slot) {
                L1BlockSlots.NUMBER => 12345678,
                L1BlockSlots.TIMESTAMP => 1700000000,
                L1BlockSlots.BASE_FEE => 30_000_000_000, // 30 gwei
                L1BlockSlots.HASH => 0xdeadbeef,
                L1BlockSlots.L1_FEE_OVERHEAD => 2100,
                L1BlockSlots.L1_FEE_SCALAR => 1_000_000,
                else => 0,
            };
        }
    }.read;
    
    const info = loadL1BlockInfo(storage_reader, op_rules);
    
    try std.testing.expectEqual(@as(u64, 12345678), info.l1_block_number);
    try std.testing.expectEqual(@as(u64, 1700000000), info.l1_block_timestamp);
    try std.testing.expectEqual(@as(u256, 30_000_000_000), info.l1_base_fee);
    try std.testing.expectEqual(@as(u256, 2100), info.l1_fee_overhead);
    try std.testing.expectEqual(@as(u256, 1_000_000), info.l1_fee_scalar);
}

test "loadL1BlockInfo Ecotone" {
    const op_rules = OptimismRules{ .hardfork = .ECOTONE };
    
    // Mock storage reader
    const storage_reader = struct {
        fn read(address: Address, slot: u256) u256 {
            _ = address;
            return switch (slot) {
                L1BlockSlots.NUMBER => 12345678,
                L1BlockSlots.TIMESTAMP => 1700000000,
                L1BlockSlots.BASE_FEE => 30_000_000_000,
                L1BlockSlots.HASH => L1BlockInfo.encodeEcotoneFeeScalars(1000, 2000),
                L1BlockSlots.BLOB_BASE_FEE => 1_000_000_000, // 1 gwei
                else => 0,
            };
        }
    }.read;
    
    const info = loadL1BlockInfo(storage_reader, op_rules);
    
    try std.testing.expectEqual(@as(u32, 1000), info.l1_base_fee_scalar);
    try std.testing.expectEqual(@as(u32, 2000), info.l1_blob_base_fee_scalar);
    try std.testing.expectEqual(@as(u256, 1_000_000_000), info.l1_blob_base_fee.?);
}

test "L1BlockInfoCache" {
    var cache = L1BlockInfoCache.init();
    const op_rules = OptimismRules{ .hardfork = .BEDROCK };
    
    const storage_reader = struct {
        fn read(address: Address, slot: u256) u256 {
            _ = address;
            _ = slot;
            return 42;
        }
    }.read;
    
    // First call loads from storage
    const info1 = cache.get(1000, storage_reader, op_rules);
    try std.testing.expectEqual(@as(u64, 42), info1.l1_block_number);
    
    // Same block returns cached value
    const info2 = cache.get(1000, storage_reader, op_rules);
    try std.testing.expectEqual(@as(u64, 42), info2.l1_block_number);
    
    // Different block reloads
    const info3 = cache.get(1001, storage_reader, op_rules);
    try std.testing.expectEqual(@as(u64, 42), info3.l1_block_number);
}