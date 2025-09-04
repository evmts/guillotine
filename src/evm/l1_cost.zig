//! Optimism L1 Cost Calculation
//!
//! This module implements L1 data availability cost calculation for Optimism Layer 2.
//! The cost calculation differs between pre-Ecotone and Ecotone+ hardforks.
//!
//! ## Pre-Ecotone Formula (Bedrock through Regolith)
//! ```
//! l1_cost = (tx_data_gas + l1_fee_overhead) * l1_fee_scalar / 1_000_000
//! ```
//!
//! ## Ecotone+ Formula (Ecotone through Isthmus)
//! ```
//! l1_cost = tx_data_gas * l1_base_fee_scalar + tx_data_gas * l1_blob_base_fee_scalar
//! ```
//!
//! ## Data Gas Calculation
//! - Zero bytes cost 4 gas each
//! - Non-zero bytes cost 16 gas each
//!
//! ## Fee Scalar Encoding (Ecotone+)
//! Fee scalars are packed into a single u256:
//! - Bits [0:32)  = blob_base_fee_scalar
//! - Bits [32:64) = base_fee_scalar

const std = @import("std");
const testing = std.testing;

/// Optimism hardforks affecting L1 cost calculation
pub const OpHardfork = enum {
    bedrock,
    regolith, 
    canyon,
    ecotone,
    fjord,
    granite,
    isthmus,

    /// Check if this hardfork supports L1 cost calculation
    pub fn supports_l1_cost_calculation(self: OpHardfork) bool {
        return switch (self) {
            .bedrock, .regolith, .canyon, .ecotone, .fjord, .granite, .isthmus => true,
        };
    }

    /// Check if this hardfork uses Ecotone+ formula
    pub fn uses_ecotone_formula(self: OpHardfork) bool {
        return switch (self) {
            .bedrock, .regolith, .canyon => false,
            .ecotone, .fjord, .granite, .isthmus => true,
        };
    }

    /// Check if this hardfork supports operator fees (Isthmus)
    pub fn supports_operator_fee(self: OpHardfork) bool {
        return self == .isthmus;
    }
};

/// L1 fee parameters for pre-Ecotone calculation
pub const PreEcotoneL1FeeParams = struct {
    l1_base_fee: u64,
    l1_fee_overhead: u64,
    l1_fee_scalar: u64,
};

/// L1 fee parameters for Ecotone+ calculation
pub const EcotoneL1FeeParams = struct {
    l1_base_fee: u64,
    l1_blob_base_fee: u64,
    l1_base_fee_scalar: u32,
    l1_blob_base_fee_scalar: u32,
};

/// Operator fee parameters (Isthmus)
pub const OperatorFeeParams = struct {
    operator_fee_constant: u64,
    operator_fee_scalar: u32,
};

/// L1 cost calculation engine
pub const L1CostCalculator = struct {
    hardfork: OpHardfork,

    pub fn init(hardfork: OpHardfork) L1CostCalculator {
        return L1CostCalculator{ .hardfork = hardfork };
    }

    /// Calculate L1 cost for transaction data
    pub fn calculate_l1_cost_pre_ecotone(
        self: L1CostCalculator, 
        tx_data: []const u8, 
        params: PreEcotoneL1FeeParams
    ) !u64 {
        if (self.hardfork.uses_ecotone_formula()) {
            return error.WrongFormulaForHardfork;
        }

        const tx_data_gas = calculate_tx_data_gas(tx_data);
        const l1_cost = (tx_data_gas + params.l1_fee_overhead) * params.l1_fee_scalar / 1_000_000;
        
        return l1_cost * params.l1_base_fee;
    }

    /// Calculate L1 cost for Ecotone+ hardforks
    pub fn calculate_l1_cost_ecotone(
        self: L1CostCalculator, 
        tx_data: []const u8, 
        params: EcotoneL1FeeParams
    ) !u64 {
        if (!self.hardfork.uses_ecotone_formula()) {
            return error.WrongFormulaForHardfork;
        }

        const tx_data_gas = calculate_tx_data_gas(tx_data);
        
        const base_cost = (tx_data_gas * @as(u64, params.l1_base_fee_scalar)) / 1_000_000 * params.l1_base_fee;
        const blob_cost = (tx_data_gas * @as(u64, params.l1_blob_base_fee_scalar)) / 1_000_000 * params.l1_blob_base_fee;
        
        return base_cost + blob_cost;
    }

    /// Calculate total cost including operator fee (Isthmus)
    pub fn calculate_total_cost_with_operator_fee(
        self: L1CostCalculator,
        base_l1_cost: u64,
        operator_params: OperatorFeeParams
    ) !u64 {
        if (!self.hardfork.supports_operator_fee()) {
            return error.OperatorFeeNotSupported;
        }

        const operator_fee = operator_params.operator_fee_constant + 
            (base_l1_cost * @as(u64, operator_params.operator_fee_scalar)) / 1_000_000;
        
        return base_l1_cost + operator_fee;
    }
};

/// Calculate gas cost for transaction data
/// Zero bytes = 4 gas, non-zero bytes = 16 gas
pub fn calculate_tx_data_gas(data: []const u8) u64 {
    var gas: u64 = 0;
    for (data) |byte| {
        if (byte == 0) {
            gas += 4;
        } else {
            gas += 16;
        }
    }
    return gas;
}

/// Encode fee scalars into packed u256 (Ecotone+)
pub fn encode_fee_scalars(base_fee_scalar: u32, blob_base_fee_scalar: u32) u256 {
    return @as(u256, base_fee_scalar) | (@as(u256, blob_base_fee_scalar) << 32);
}

/// Decode fee scalars from packed u256 (Ecotone+)
pub fn decode_fee_scalars(encoded: u256) struct { base_fee_scalar: u32, blob_base_fee_scalar: u32 } {
    const base_fee_scalar = @truncate(encoded & 0xFFFFFFFF);
    const blob_base_fee_scalar = @truncate((encoded >> 32) & 0xFFFFFFFF);
    return .{ .base_fee_scalar = base_fee_scalar, .blob_base_fee_scalar = blob_base_fee_scalar };
}

// Tests following TDD approach

test "optimism hardfork feature detection" {
    const bedrock = OpHardfork.bedrock;
    const ecotone = OpHardfork.ecotone;
    const isthmus = OpHardfork.isthmus;
    
    // All hardforks should support L1 cost calculation
    try testing.expect(bedrock.supports_l1_cost_calculation());
    try testing.expect(ecotone.supports_l1_cost_calculation());
    try testing.expect(isthmus.supports_l1_cost_calculation());
    
    // Only Ecotone+ should use new formula
    try testing.expect(!bedrock.uses_ecotone_formula());
    try testing.expect(ecotone.uses_ecotone_formula());
    try testing.expect(isthmus.uses_ecotone_formula());
    
    // Only Isthmus supports operator fees
    try testing.expect(!bedrock.supports_operator_fee());
    try testing.expect(!ecotone.supports_operator_fee());
    try testing.expect(isthmus.supports_operator_fee());
}

test "tx data gas calculation" {
    // Empty data
    try testing.expectEqual(@as(u64, 0), calculate_tx_data_gas(&[_]u8{}));
    
    // Only zero bytes (4 gas each)
    try testing.expectEqual(@as(u64, 12), calculate_tx_data_gas(&[_]u8{0x00, 0x00, 0x00}));
    
    // Only non-zero bytes (16 gas each)
    try testing.expectEqual(@as(u64, 48), calculate_tx_data_gas(&[_]u8{0x01, 0x02, 0x03}));
    
    // Mixed bytes
    try testing.expectEqual(@as(u64, 24), calculate_tx_data_gas(&[_]u8{0x00, 0x12, 0x00})); // 4 + 16 + 4 = 24
}

test "l1 cost calculation pre ecotone" {
    const calculator = L1CostCalculator.init(.bedrock);
    const tx_data = [_]u8{0x00, 0x12, 0x34}; // 4 + 16 + 16 = 36 gas
    
    const params = PreEcotoneL1FeeParams{
        .l1_base_fee = 1000000000, // 1 gwei
        .l1_fee_overhead = 188,
        .l1_fee_scalar = 684000,
    };
    
    const cost = try calculator.calculate_l1_cost_pre_ecotone(tx_data, params);
    
    // Formula: (36 + 188) * 684000 / 1_000_000 * 1000000000 = 224 * 0.684 * 1 gwei = 153.216 gwei = 153216000000
    const expected_cost = (36 + 188) * 684000 / 1_000_000 * 1000000000;
    try testing.expectEqual(expected_cost, cost);
}

test "l1 cost calculation ecotone plus" {
    const calculator = L1CostCalculator.init(.ecotone);
    const tx_data = [_]u8{0x00, 0x12, 0x34}; // 4 + 16 + 16 = 36 gas
    
    const params = EcotoneL1FeeParams{
        .l1_base_fee = 1000000000, // 1 gwei
        .l1_blob_base_fee = 1,
        .l1_base_fee_scalar = 1368,
        .l1_blob_base_fee_scalar = 801949,
    };
    
    const cost = try calculator.calculate_l1_cost_ecotone(tx_data, params);
    
    // Formula: 
    // base_cost = (36 * 1368) / 1_000_000 * 1000000000 = 49.248 gwei = 49248000000
    // blob_cost = (36 * 801949) / 1_000_000 * 1 = 28.87 wei = 28
    // total = 49248000028
    const expected_base = (36 * @as(u64, 1368)) / 1_000_000 * 1000000000;
    const expected_blob = (36 * @as(u64, 801949)) / 1_000_000 * 1;
    const expected_total = expected_base + expected_blob;
    
    try testing.expectEqual(expected_total, cost);
}

test "fee scalar encoding decoding" {
    const base_scalar: u32 = 1368;
    const blob_scalar: u32 = 801949;
    
    const encoded = encode_fee_scalars(base_scalar, blob_scalar);
    const decoded = decode_fee_scalars(encoded);
    
    try testing.expectEqual(base_scalar, decoded.base_fee_scalar);
    try testing.expectEqual(blob_scalar, decoded.blob_base_fee_scalar);
}

test "operator fee calculation isthmus" {
    const calculator = L1CostCalculator.init(.isthmus);
    const base_cost: u64 = 100000000000; // 100 gwei
    
    const operator_params = OperatorFeeParams{
        .operator_fee_constant = 1000000000, // 1 gwei constant
        .operator_fee_scalar = 5000, // 0.5% scalar
    };
    
    const total_cost = try calculator.calculate_total_cost_with_operator_fee(base_cost, operator_params);
    
    // operator_fee = 1 gwei + (100 gwei * 5000 / 1_000_000) = 1 + 0.5 = 1.5 gwei
    // total = 100 + 1.5 = 101.5 gwei
    const expected_operator_fee = 1000000000 + (base_cost * 5000) / 1_000_000;
    const expected_total = base_cost + expected_operator_fee;
    
    try testing.expectEqual(expected_total, total_cost);
}

test "wrong formula for hardfork errors" {
    const bedrock_calc = L1CostCalculator.init(.bedrock);
    const ecotone_calc = L1CostCalculator.init(.ecotone);
    const data = [_]u8{0x12};
    
    const pre_ecotone_params = PreEcotoneL1FeeParams{ .l1_base_fee = 1, .l1_fee_overhead = 1, .l1_fee_scalar = 1 };
    const ecotone_params = EcotoneL1FeeParams{ .l1_base_fee = 1, .l1_blob_base_fee = 1, .l1_base_fee_scalar = 1, .l1_blob_base_fee_scalar = 1 };
    
    // Wrong formula for hardfork should error
    try testing.expectError(error.WrongFormulaForHardfork, ecotone_calc.calculate_l1_cost_pre_ecotone(data, pre_ecotone_params));
    try testing.expectError(error.WrongFormulaForHardfork, bedrock_calc.calculate_l1_cost_ecotone(data, ecotone_params));
}