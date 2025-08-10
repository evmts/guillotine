const std = @import("std");
const primitives = @import("primitives");
const GasConstants = primitives.GasConstants;

/// EVM Precompile Constants
///
/// This file contains all constants related to precompiled contracts including:
/// - Precompile addresses
/// - Gas costs for precompiled operations
/// - Input/output sizes for precompiles
/// - Cryptographic constants
/// Precompile addresses
pub const ECRECOVER = 0x0000000000000000000000000000000000000001;
pub const SHA256 = 0x0000000000000000000000000000000000000002;
pub const RIPEMD160 = 0x0000000000000000000000000000000000000003;
pub const IDENTITY = 0x0000000000000000000000000000000000000004;
pub const MODEXP = 0x0000000000000000000000000000000000000005;
pub const ECADD = 0x0000000000000000000000000000000000000006;
pub const ECMUL = 0x0000000000000000000000000000000000000007;
pub const ECPAIRING = 0x0000000000000000000000000000000000000008;
pub const BLAKE2F = 0x0000000000000000000000000000000000000009;
pub const KZG_POINT_EVALUATION = 0x000000000000000000000000000000000000000a;

/// ECRECOVER constants
pub const ECRECOVER_GAS_COST: u64 = GasConstants.ECRECOVER_COST;
pub const ECRECOVER_INPUT_SIZE: usize = 128;
pub const ECRECOVER_OUTPUT_SIZE: usize = 32;
pub const SECP256K1_ORDER: u256 = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

/// Identity precompile constants
pub const IDENTITY_BASE_COST: u64 = 15;
pub const IDENTITY_WORD_COST: u64 = 3;

/// RIPEMD160 precompile constants
pub const RIPEMD160_BASE_GAS_COST: u64 = 600;
pub const RIPEMD160_WORD_GAS_COST: u64 = 120;
pub const RIPEMD160_HASH_SIZE: usize = 20;
pub const RIPEMD160_OUTPUT_SIZE: usize = 32;

/// BLAKE2F precompile constants
pub const BLAKE2F_GAS_PER_ROUND: u64 = 1;
pub const BLAKE2F_INPUT_SIZE: usize = 213;
pub const BLAKE2F_OUTPUT_SIZE: usize = 64;

/// MODEXP precompile constants
pub const MODEXP_MIN_GAS: u64 = primitives.GasConstants.MODEXP_MIN_GAS;
pub const MODEXP_QUADRATIC_THRESHOLD: usize = primitives.GasConstants.MODEXP_QUADRATIC_THRESHOLD;
pub const MODEXP_LINEAR_THRESHOLD: usize = primitives.GasConstants.MODEXP_LINEAR_THRESHOLD;

/// KZG Point Evaluation precompile constants
pub const KZG_POINT_EVALUATION_GAS_COST: u64 = 50000;
pub const KZG_POINT_EVALUATION_INPUT_LENGTH: usize = 192;
pub const KZG_POINT_EVALUATION_OUTPUT_LENGTH: usize = 64;

/// BLS12-381 G2MSM precompile constants
pub const G2MSM_BASE_GAS_COST: u64 = 55000;
pub const G2MSM_PER_PAIR_GAS_COST: u64 = 32000;
pub const G2MSM_PAIR_SIZE: usize = 288; // 32 (scalar) + 256 (G2 point)
pub const G2MSM_OUTPUT_SIZE: usize = 256;

/// BN254 curve constants
pub const FIELD_PRIME: u256 = 0x30644e72e131a029b85045b68181585d97816a916871ca8d3c208c16d87cfd47;

/// Cryptographic constants used in precompiles
pub const HASH_OFFSET: usize = 0;
pub const HASH_SIZE: usize = 32;
pub const V_OFFSET: usize = 32;
pub const V_SIZE: usize = 32;
pub const R_OFFSET: usize = 64;
pub const R_SIZE: usize = 32;
pub const S_OFFSET: usize = 96;
pub const S_SIZE: usize = 32;
pub const ADDRESS_OFFSET_IN_OUTPUT: usize = 12;
pub const ETHEREUM_ADDRESS_SIZE: usize = 20;
