/// Optimism L1 Cost Calculation
/// Calculates the L1 data availability cost for L2 transactions
/// This is a critical component of L2 fee calculation, accounting for the cost
/// of posting transaction data to L1 for data availability.

const std = @import("std");

/// L1 cost calculation parameters that vary by hardfork
pub const L1CostParams = struct {
    /// Pre-Ecotone parameters (Bedrock, Regolith, Canyon)
    l1_base_fee: ?u64 = null,
    l1_fee_overhead: ?u64 = null,
    l1_fee_scalar: ?u64 = null,
    
    /// Ecotone+ parameters (Ecotone, Fjord, Granite, Holocene, Isthmus)
    l1_blob_base_fee: ?u64 = null,
    l1_base_fee_scalar: ?u32 = null,
    l1_blob_base_fee_scalar: ?u32 = null,
    
    /// Isthmus+ parameters (operator fee support)
    operator_fee_scalar: ?u32 = null,
    operator_fee_constant: ?u64 = null,
};

/// Optimism hardfork versions for L1 cost calculation
pub const OpHardfork = enum {
    bedrock,
    regolith,
    canyon,
    ecotone,
    fjord,
    granite,
    holocene,
    isthmus,
    
    /// Check if this hardfork uses the new Ecotone+ fee calculation
    pub fn uses_ecotone_l1_cost_formula(self: OpHardfork) bool {
        return switch (self) {
            .bedrock, .regolith, .canyon => false,
            .ecotone, .fjord, .granite, .holocene, .isthmus => true,
        };
    }
    
    /// Check if this hardfork supports operator fees
    pub fn supports_operator_fees(self: OpHardfork) bool {
        return switch (self) {
            .bedrock, .regolith, .canyon, .ecotone, .fjord, .granite, .holocene => false,
            .isthmus => true,
        };
    }
};

/// L1 cost calculator for different Optimism hardforks
pub const L1CostCalculator = struct {
    hardfork: OpHardfork,
    
    pub fn init(hardfork: OpHardfork) L1CostCalculator {
        return L1CostCalculator{ .hardfork = hardfork };
    }
    
    /// Calculate L1 cost for transaction data
    pub fn calculate_l1_cost(
        self: L1CostCalculator,
        tx_data: []const u8,
        params: L1CostParams,
    ) L1CostError!u64 {
        if (self.hardfork.uses_ecotone_l1_cost_formula()) {
            return self.calculate_ecotone_l1_cost(tx_data, params);
        } else {
            return self.calculate_bedrock_l1_cost(tx_data, params);
        }
    }
    
    /// Pre-Ecotone L1 cost calculation (Bedrock, Regolith, Canyon)
    /// Formula: (tx_data_gas + fixed_overhead) * l1_base_fee * l1_fee_scalar / (10^6)
    fn calculate_bedrock_l1_cost(
        _: L1CostCalculator,
        tx_data: []const u8,
        params: L1CostParams,
    ) L1CostError!u64 {
        const l1_base_fee = params.l1_base_fee orelse return L1CostError.MissingL1BaseFee;
        const l1_fee_overhead = params.l1_fee_overhead orelse return L1CostError.MissingL1FeeOverhead;
        const l1_fee_scalar = params.l1_fee_scalar orelse return L1CostError.MissingL1FeeScalar;
        
        // Calculate gas cost for tx data (4 gas per zero byte, 16 gas per non-zero byte)
        const tx_data_gas = calculate_calldata_gas(tx_data);
        
        // Apply overhead and scaling
        const total_gas = tx_data_gas + l1_fee_overhead;
        const scaled_cost = total_gas * l1_base_fee * l1_fee_scalar;
        
        // Scale down by 10^6 (as per Optimism spec)
        return @intCast(scaled_cost / 1_000_000);
    }
    
    /// Ecotone+ L1 cost calculation (Ecotone, Fjord, Granite, Holocene, Isthmus)
    /// Uses both base fee and blob base fee with separate scalars
    fn calculate_ecotone_l1_cost(
        _: L1CostCalculator,
        tx_data: []const u8,
        params: L1CostParams,
    ) L1CostError!u64 {
        const l1_base_fee = params.l1_base_fee orelse return L1CostError.MissingL1BaseFee;
        const l1_blob_base_fee = params.l1_blob_base_fee orelse return L1CostError.MissingL1BlobBaseFee;
        const l1_base_fee_scalar = params.l1_base_fee_scalar orelse return L1CostError.MissingL1BaseFeeScalar;
        const l1_blob_base_fee_scalar = params.l1_blob_base_fee_scalar orelse return L1CostError.MissingL1BlobBaseFeeScalar;
        
        // Calculate gas cost for tx data
        const calldata_gas = calculate_calldata_gas(tx_data);
        
        // Calculate both components
        const base_fee_component = calldata_gas * l1_base_fee * @as(u64, l1_base_fee_scalar);
        const blob_fee_component = calldata_gas * l1_blob_base_fee * @as(u64, l1_blob_base_fee_scalar);
        
        // Scale down by 16 * 10^6 (as per Ecotone spec)  
        const total_cost = (base_fee_component + blob_fee_component) / 16_000_000;
        
        return @intCast(total_cost);
    }
    
    /// Calculate total cost including operator fees (Isthmus+)
    pub fn calculate_total_cost(
        self: L1CostCalculator,
        base_l1_cost: u64,
        params: L1CostParams,
    ) L1CostError!u64 {
        if (!self.hardfork.supports_operator_fees()) {
            return base_l1_cost;
        }
        
        const operator_fee_scalar = params.operator_fee_scalar orelse return L1CostError.MissingOperatorFeeScalar;
        const operator_fee_constant = params.operator_fee_constant orelse return L1CostError.MissingOperatorFeeConstant;
        
        // Apply operator fee: cost = base_cost + (base_cost * scalar + constant) / 10^6
        const operator_fee = (base_l1_cost * @as(u64, operator_fee_scalar) + operator_fee_constant) / 1_000_000;
        return base_l1_cost + operator_fee;
    }
};

/// Calculate gas cost for calldata (EIP-2028 style)
fn calculate_calldata_gas(data: []const u8) u64 {
    var gas: u64 = 0;
    for (data) |byte| {
        if (byte == 0) {
            gas += 4;  // 4 gas per zero byte
        } else {
            gas += 16; // 16 gas per non-zero byte
        }
    }
    return gas;
}

/// Encode fee scalars into a single u256 value (Ecotone+ format)
pub fn encode_fee_scalars(base_fee_scalar: u32, blob_base_fee_scalar: u32) u256 {
    return (@as(u256, base_fee_scalar) << 32) | @as(u256, blob_base_fee_scalar);
}

/// Decode fee scalars from a u256 value (Ecotone+ format)
pub fn decode_fee_scalars(encoded: u256) struct { base_fee_scalar: u32, blob_base_fee_scalar: u32 } {
    const base_fee_scalar = @intCast((encoded >> 32) & 0xFFFFFFFF);
    const blob_base_fee_scalar = @intCast(encoded & 0xFFFFFFFF);
    return .{
        .base_fee_scalar = base_fee_scalar,
        .blob_base_fee_scalar = blob_base_fee_scalar,
    };
}

/// Errors that can occur during L1 cost calculation
pub const L1CostError = error{
    MissingL1BaseFee,
    MissingL1FeeOverhead,
    MissingL1FeeScalar,
    MissingL1BlobBaseFee,
    MissingL1BaseFeeScalar,
    MissingL1BlobBaseFeeScalar,
    MissingOperatorFeeScalar,
    MissingOperatorFeeConstant,
    CostOverflow,
};

// Tests for L1 cost calculation
const testing = std.testing;

test "bedrock l1 cost calculation" {
    const calculator = L1CostCalculator.init(.bedrock);
    const tx_data = [_]u8{ 0x00, 0x12, 0x34 }; // 1 zero byte, 2 non-zero bytes
    
    const params = L1CostParams{
        .l1_base_fee = 1000000000, // 1 gwei
        .l1_fee_overhead = 188,
        .l1_fee_scalar = 684000,
    };
    
    const cost = try calculator.calculate_l1_cost(tx_data, params);
    try testing.expect(cost > 0);
    
    // Expected calculation: (4 + 16 + 16 + 188) * 1000000000 * 684000 / 1000000
    const expected_gas = 4 + 16 + 16 + 188; // 244
    const expected_cost = expected_gas * 1000000000 * 684000 / 1000000;
    try testing.expectEqual(expected_cost, cost);
}

test "ecotone l1 cost calculation" {
    const calculator = L1CostCalculator.init(.ecotone);
    const tx_data = [_]u8{ 0x00, 0x12, 0x34 }; // 1 zero byte, 2 non-zero bytes
    
    const params = L1CostParams{
        .l1_base_fee = 1000000000, // 1 gwei
        .l1_blob_base_fee = 1,
        .l1_base_fee_scalar = 1368,
        .l1_blob_base_fee_scalar = 801949,
    };
    
    const cost = try calculator.calculate_l1_cost(tx_data, params);
    try testing.expect(cost > 0);
}

test "fee scalar encoding and decoding" {
    const base_scalar: u32 = 1368;
    const blob_scalar: u32 = 801949;
    
    const encoded = encode_fee_scalars(base_scalar, blob_scalar);
    const decoded = decode_fee_scalars(encoded);
    
    try testing.expectEqual(base_scalar, decoded.base_fee_scalar);
    try testing.expectEqual(blob_scalar, decoded.blob_base_fee_scalar);
}

test "operator fee calculation" {
    const calculator = L1CostCalculator.init(.isthmus);
    const base_cost: u64 = 1000;
    
    const params = L1CostParams{
        .operator_fee_scalar = 50000, // 5%
        .operator_fee_constant = 100,
    };
    
    const total_cost = try calculator.calculate_total_cost(base_cost, params);
    
    // Expected: 1000 + (1000 * 50000 + 100) / 1000000 = 1000 + 50.0001 ≈ 1050
    try testing.expectEqual(@as(u64, 1050), total_cost);
}

test "hardfork feature detection" {
    try testing.expect(!OpHardfork.bedrock.uses_ecotone_l1_cost_formula());
    try testing.expect(!OpHardfork.canyon.uses_ecotone_l1_cost_formula());
    try testing.expect(OpHardfork.ecotone.uses_ecotone_l1_cost_formula());
    try testing.expect(OpHardfork.isthmus.uses_ecotone_l1_cost_formula());
    
    try testing.expect(!OpHardfork.holocene.supports_operator_fees());
    try testing.expect(OpHardfork.isthmus.supports_operator_fees());
}

test "calldata gas calculation" {
    // Test empty data
    try testing.expectEqual(@as(u64, 0), calculate_calldata_gas(&[_]u8{}));
    
    // Test all zero bytes
    try testing.expectEqual(@as(u64, 12), calculate_calldata_gas(&[_]u8{ 0, 0, 0 })); // 3 * 4
    
    // Test all non-zero bytes
    try testing.expectEqual(@as(u64, 32), calculate_calldata_gas(&[_]u8{ 1, 2 })); // 2 * 16
    
    // Test mixed
    try testing.expectEqual(@as(u64, 20), calculate_calldata_gas(&[_]u8{ 0, 1 })); // 4 + 16
}