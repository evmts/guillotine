//! OP Stack constants: predeploy addresses, L1Block storage layout, and fee parameters.
//!
//! Sources:
//! - op-revm constants.rs and transaction/mod.rs
//!   https://github.com/ethereum-optimism/optimism/blob/develop/rust/op-revm/src/constants.rs
//! - OP Stack predeploys: https://specs.optimism.io/protocol/predeploys.html
//! - Jovian exec engine: https://specs.optimism.io/protocol/jovian/exec-engine.html

const std = @import("std");
const primitives = @import("voltaire");
const Address = primitives.Address;

// ---------------------------------------------------------------------------
// Predeploy addresses
// ---------------------------------------------------------------------------

/// L2CrossDomainMessenger predeploy.
pub const L2_CROSS_DOMAIN_MESSENGER_ADDRESS: Address = Address.fromU256(0x4200000000000000000000000000000000000007);
/// GasPriceOracle predeploy.
pub const GAS_PRICE_ORACLE_ADDRESS: Address = Address.fromU256(0x420000000000000000000000000000000000000F);
/// SequencerFeeVault predeploy: receives priority fees (block coinbase).
pub const SEQUENCER_FEE_VAULT_ADDRESS: Address = Address.fromU256(0x4200000000000000000000000000000000000011);
/// L1Block predeploy: stores L1 attributes read by the L1 fee formulas.
pub const L1_BLOCK_ADDRESS: Address = Address.fromU256(0x4200000000000000000000000000000000000015);
/// BaseFeeVault predeploy: receives the L2 base fee.
pub const BASE_FEE_VAULT_ADDRESS: Address = Address.fromU256(0x4200000000000000000000000000000000000019);
/// L1FeeVault predeploy: receives the L1 data fee.
pub const L1_FEE_VAULT_ADDRESS: Address = Address.fromU256(0x420000000000000000000000000000000000001A);
/// OperatorFeeVault predeploy (Isthmus+): receives the operator fee.
pub const OPERATOR_FEE_VAULT_ADDRESS: Address = Address.fromU256(0x420000000000000000000000000000000000001B);

/// op-revm names for the fee vaults.
pub const L1_FEE_RECIPIENT = L1_FEE_VAULT_ADDRESS;
pub const BASE_FEE_RECIPIENT = BASE_FEE_VAULT_ADDRESS;
pub const OPERATOR_FEE_RECIPIENT = OPERATOR_FEE_VAULT_ADDRESS;

// ---------------------------------------------------------------------------
// L1Block storage layout
// ---------------------------------------------------------------------------

pub const L1_BASE_FEE_SLOT: u256 = 1;
/// Ecotone+: packs baseFeeScalar (u32) and blobBaseFeeScalar (u32).
pub const ECOTONE_L1_FEE_SCALARS_SLOT: u256 = 3;
/// Bedrock/Regolith fee overhead. Also read in Ecotone when the scalars are empty.
pub const L1_OVERHEAD_SLOT: u256 = 5;
/// Bedrock/Regolith fee scalar.
pub const L1_SCALAR_SLOT: u256 = 6;
/// Ecotone+: L1 blob base fee.
pub const ECOTONE_L1_BLOB_BASE_FEE_SLOT: u256 = 7;
/// Isthmus+: packs operatorFeeScalar (u32) and operatorFeeConstant (u64).
/// Jovian+: also packs daFootprintGasScalar (u16).
pub const OPERATOR_FEE_SCALARS_SLOT: u256 = 8;
pub const DA_FOOTPRINT_GAS_SCALAR_SLOT: u256 = 8;

/// Big-endian byte offsets within the 32-byte slot value (op-revm convention).
pub const BASE_FEE_SCALAR_OFFSET: usize = 16; // 4 bytes
pub const BLOB_BASE_FEE_SCALAR_OFFSET: usize = 20; // 4 bytes
pub const OPERATOR_FEE_SCALAR_OFFSET: usize = 20; // 4 bytes
pub const OPERATOR_FEE_CONSTANT_OFFSET: usize = 24; // 8 bytes
pub const DA_FOOTPRINT_GAS_SCALAR_OFFSET: usize = 18; // 2 bytes

// ---------------------------------------------------------------------------
// Fee parameters
// ---------------------------------------------------------------------------

pub const NON_ZERO_BYTE_GAS: u64 = 16;
pub const ZERO_BYTE_GAS: u64 = 4;
/// Pre-Regolith L1 data gas overhead for the missing signature: 68 non-zero bytes.
pub const PRE_REGOLITH_SIGNATURE_OVERHEAD_GAS: u64 = 68 * NON_ZERO_BYTE_GAS;

/// Isthmus operator fee scalar precision: gas * scalar / 1e6.
pub const OPERATOR_FEE_SCALAR_DECIMAL: u64 = 1_000_000;
/// Jovian operator fee multiplier: gas * scalar * 100.
pub const OPERATOR_FEE_JOVIAN_MULTIPLIER: u64 = 100;

/// Fjord FastLZ size model (all scaled by 1e6):
/// estimatedSize = max(minTransactionSize * 1e6, intercept + fastlzCoef * fastlzSize)
/// with intercept = -42_585_600 and fastlzCoef = 836_500 (op-geth rollup_cost.go).
pub const FJORD_FASTLZ_COEF: u64 = 836_500;
/// Absolute value of the negative Fjord intercept; subtracted with saturation.
pub const FJORD_INTERCEPT: u64 = 42_585_600;
/// minTransactionSize (100 bytes) scaled by 1e6.
pub const FJORD_MIN_TX_SIZE_SCALED: u64 = 100 * 1_000_000;

/// Jovian: SystemConfig value 0 is replaced by this default in the L1 attributes
/// transaction, so the L1Block slot already holds the effective scalar.
pub const DA_FOOTPRINT_GAS_SCALAR_DEFAULT: u16 = 400;

/// EIP-2718 type of OP Stack deposit transactions.
pub const DEPOSIT_TRANSACTION_TYPE: u8 = 0x7E;

test "predeploy addresses" {
    try std.testing.expectEqual(@as(u256, 0x4200000000000000000000000000000000000007), L2_CROSS_DOMAIN_MESSENGER_ADDRESS.toU256());
    try std.testing.expectEqual(@as(u256, 0x420000000000000000000000000000000000000F), GAS_PRICE_ORACLE_ADDRESS.toU256());
    try std.testing.expectEqual(@as(u256, 0x4200000000000000000000000000000000000011), SEQUENCER_FEE_VAULT_ADDRESS.toU256());
    try std.testing.expectEqual(@as(u256, 0x4200000000000000000000000000000000000015), L1_BLOCK_ADDRESS.toU256());
    try std.testing.expectEqual(@as(u256, 0x4200000000000000000000000000000000000019), BASE_FEE_VAULT_ADDRESS.toU256());
    try std.testing.expectEqual(@as(u256, 0x420000000000000000000000000000000000001A), L1_FEE_VAULT_ADDRESS.toU256());
    try std.testing.expectEqual(@as(u256, 0x420000000000000000000000000000000000001B), OPERATOR_FEE_VAULT_ADDRESS.toU256());
}

test "storage slots match op-revm" {
    try std.testing.expectEqual(@as(u256, 1), L1_BASE_FEE_SLOT);
    try std.testing.expectEqual(@as(u256, 3), ECOTONE_L1_FEE_SCALARS_SLOT);
    try std.testing.expectEqual(@as(u256, 5), L1_OVERHEAD_SLOT);
    try std.testing.expectEqual(@as(u256, 6), L1_SCALAR_SLOT);
    try std.testing.expectEqual(@as(u256, 7), ECOTONE_L1_BLOB_BASE_FEE_SLOT);
    try std.testing.expectEqual(@as(u256, 8), OPERATOR_FEE_SCALARS_SLOT);
    try std.testing.expectEqual(@as(u256, 8), DA_FOOTPRINT_GAS_SCALAR_SLOT);
}

test "packed field offsets do not overlap" {
    // Slot 3: [16..20) base fee scalar, [20..24) blob base fee scalar.
    try std.testing.expectEqual(BASE_FEE_SCALAR_OFFSET + 4, BLOB_BASE_FEE_SCALAR_OFFSET);
    // Slot 8: [18..20) DA footprint scalar, [20..24) operator scalar, [24..32) operator constant.
    try std.testing.expectEqual(DA_FOOTPRINT_GAS_SCALAR_OFFSET + 2, OPERATOR_FEE_SCALAR_OFFSET);
    try std.testing.expectEqual(OPERATOR_FEE_SCALAR_OFFSET + 4, OPERATOR_FEE_CONSTANT_OFFSET);
    try std.testing.expectEqual(@as(usize, 32), OPERATOR_FEE_CONSTANT_OFFSET + 8);
}

test "fee parameters" {
    try std.testing.expectEqual(@as(u64, 1088), PRE_REGOLITH_SIGNATURE_OVERHEAD_GAS);
    try std.testing.expectEqual(@as(u64, 1_000_000), OPERATOR_FEE_SCALAR_DECIMAL);
    try std.testing.expectEqual(@as(u64, 100), OPERATOR_FEE_JOVIAN_MULTIPLIER);
    try std.testing.expectEqual(@as(u64, 836_500), FJORD_FASTLZ_COEF);
    try std.testing.expectEqual(@as(u64, 42_585_600), FJORD_INTERCEPT);
    try std.testing.expectEqual(@as(u64, 100_000_000), FJORD_MIN_TX_SIZE_SCALED);
    try std.testing.expectEqual(@as(u16, 400), DA_FOOTPRINT_GAS_SCALAR_DEFAULT);
    try std.testing.expectEqual(@as(u8, 0x7E), DEPOSIT_TRANSACTION_TYPE);
}
