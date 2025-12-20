/// EVM gas cost constants for opcode execution
///
/// This module defines all gas cost constants used in EVM execution according
/// to the Ethereum Yellow Paper and various EIPs. Gas costs are critical for
/// preventing denial-of-service attacks and fairly pricing computational resources.
const std = @import("std");
const @"u256" = @import("uint.zig").Uint(256);
///
/// ## Gas Cost Categories
///
/// Operations are grouped by computational complexity:
/// - **Quick** (2 gas): Trivial operations like PC, MSIZE, GAS
/// - **Fastest** (3 gas): Simple arithmetic like ADD, SUB, NOT, LT, GT
/// - **Fast** (5 gas): More complex arithmetic like MUL, DIV, MOD
/// - **Mid** (8 gas): Advanced arithmetic like ADDMOD, MULMOD, SIGNEXTEND
/// - **Slow** (10 gas): Operations requiring more computation
/// - **Ext** (20+ gas): External operations like BALANCE, EXTCODESIZE

// ============================================================================
// Basic Opcode Costs
// ============================================================================

/// Gas cost for very cheap operations
/// Operations: ADDRESS, ORIGIN, CALLER, CALLVALUE, CALLDATASIZE, CODESIZE,
/// GASPRICE, RETURNDATASIZE, PC, MSIZE, GAS, CHAINID, SELFBALANCE
pub const GasQuickStep: u64 = 2;

/// Gas cost for simple arithmetic and logic operations
/// Operations: ADD, SUB, NOT, LT, GT, SLT, SGT, EQ, ISZERO, AND, OR, XOR,
/// CALLDATALOAD, MLOAD, MSTORE, MSTORE8, PUSH operations, DUP operations,
/// SWAP operations
pub const GasFastestStep: u64 = 3;

/// Gas cost for multiplication and division operations
/// Operations: MUL, DIV, SDIV, MOD, SMOD, EXP (per byte of exponent)
pub const GasFastStep: u64 = 5;

/// Gas cost for advanced arithmetic operations
/// Operations: ADDMOD, MULMOD, SIGNEXTEND, KECCAK256 (base cost)
pub const GasMidStep: u64 = 8;

/// Gas cost for operations requiring moderate computation
/// Operations: JUMPI
pub const GasSlowStep: u64 = 10;

/// Gas cost for operations that interact with other accounts/contracts
/// Operations: BALANCE, EXTCODESIZE, BLOCKHASH
pub const GasExtStep: u64 = 20;

// ============================================================================
// Hashing Operation Costs
// ============================================================================

/// Base gas cost for KECCAK256 (SHA3) operation
/// This is the fixed cost regardless of input size
pub const Keccak256Gas: u64 = 30;

/// Additional gas cost per 32-byte word for KECCAK256
/// Total cost = Keccak256Gas + (word_count * Keccak256WordGas)
pub const Keccak256WordGas: u64 = 6;

// ============================================================================
// Storage Operation Costs (EIP-2929 & EIP-2200)
// ============================================================================

/// Gas cost for SLOAD on a warm storage slot
/// After EIP-2929, warm access is significantly cheaper than cold
pub const SloadGas: u64 = 100;

/// Gas cost for first-time (cold) SLOAD access in a transaction
/// EIP-2929: Prevents underpriced state access attacks
pub const ColdSloadCost: u64 = 2100;

/// Gas cost for first-time (cold) account access in a transaction
/// EIP-2929: Applied to BALANCE, EXTCODESIZE, EXTCODECOPY, EXTCODEHASH, CALL family
pub const ColdAccountAccessCost: u64 = 2600;

/// Gas cost for warm storage read operations
/// EIP-2929: Subsequent accesses to the same slot/account in a transaction
pub const WarmStorageReadCost: u64 = 100;

/// Minimum gas that must remain for SSTORE to succeed
/// Prevents storage modifications when gas is nearly exhausted
pub const SstoreSentryGas: u64 = 2300;

/// Gas cost for SSTORE when setting a storage slot from zero to non-zero
/// This is the most expensive storage operation as it increases state size
pub const SstoreSetGas: u64 = 20000;

/// Gas cost for SSTORE when changing an existing non-zero value to another non-zero value
/// Cheaper than initial set since slot is already allocated
pub const SstoreResetGas: u64 = 5000;

/// Gas cost for SSTORE when clearing a storage slot (non-zero to zero)
/// Same cost as reset, but eligible for gas refund
pub const SstoreClearGas: u64 = 5000;

/// Gas refund for clearing storage slot to zero
/// EIP-3529: Reduced from 15000 to prevent gas refund abuse
pub const SstoreRefundGas: u64 = 4800;

// ============================================================================
// Control Flow Costs
// ============================================================================

/// Gas cost for JUMPDEST opcode
/// Minimal cost as it's just a marker for valid jump destinations
pub const JumpdestGas: u64 = 1;

// ============================================================================
// Logging Operation Costs
// ============================================================================

/// Base gas cost for LOG operations (LOG0-LOG4)
/// This is the fixed cost before considering data size and topics
pub const LogGas: u64 = 375;

/// Gas cost per byte of data in LOG operations
/// Incentivizes efficient event data usage
pub const LogDataGas: u64 = 8;

/// Gas cost per topic in LOG operations
/// Each additional topic (LOG1, LOG2, etc.) adds this cost
pub const LogTopicGas: u64 = 375;

// ============================================================================
// Contract Creation and Call Costs
// ============================================================================

/// Base gas cost for CREATE opcode
/// High cost reflects the expense of deploying new contracts
pub const CreateGas: u64 = 32000;

/// Base gas cost for CALL operations
/// This is the minimum cost before additional charges
pub const CallGas: u64 = 40;

/// Gas stipend provided to called contract when transferring value
/// Ensures called contract has minimum gas to execute basic operations
pub const CallStipend: u64 = 2300;

/// Additional gas cost when CALL transfers value (ETH)
/// Makes value transfers more expensive to prevent spam
pub const CallValueTransferGas: u64 = 9000;

/// Additional gas cost when CALL creates a new account
/// Reflects the cost of adding a new entry to the state trie
pub const CallNewAccountGas: u64 = 25000;

// ============================================================================
// Call Operation Specific Costs (EIP-150)
// ============================================================================

/// Gas cost for CALL operations with value transfer
/// EIP-150: IO-heavy operations cost adjustments
pub const CallValueCost: u64 = 9000;

/// Gas cost for CALLCODE operations
/// EIP-150: Same base cost as other call operations
pub const CallCodeCost: u64 = 700;

/// Gas cost for DELEGATECALL operations
/// EIP-150: Introduced in Homestead hardfork
pub const DelegateCallCost: u64 = 700;

/// Gas cost for STATICCALL operations
/// EIP-214: Introduced in Byzantium hardfork
pub const StaticCallCost: u64 = 700;

/// Cost for creating a new account during calls
/// Applied when target account doesn't exist and value > 0
pub const NewAccountCost: u64 = 25000;

/// Base gas cost for SELFDESTRUCT operation
/// EIP-150 (Tangerine Whistle): Increased from 0 to 5000 gas
pub const SelfdestructGas: u64 = 5000;

/// Gas refund for SELFDESTRUCT operation
/// Incentivizes cleaning up unused contracts
/// Note: Removed in EIP-3529 (London)
pub const SelfdestructRefundGas: u64 = 24000;

// ============================================================================
// Memory Expansion Costs
// ============================================================================

/// Linear coefficient for memory gas calculation
/// Part of the formula: gas = MemoryGas * words + words² / QuadCoeffDiv
pub const MemoryGas: u64 = 3;

/// Quadratic coefficient divisor for memory gas calculation
/// Makes memory expansion quadratically expensive to prevent DoS attacks
pub const QuadCoeffDiv: u64 = 512;

// ============================================================================
// Contract Deployment Costs
// ============================================================================

/// Gas cost per byte of contract deployment code
/// Applied to the bytecode being deployed via CREATE/CREATE2
pub const CreateDataGas: u64 = 200;

/// Gas cost per 32-byte word of initcode
/// EIP-3860: Prevents deploying excessively large contracts
pub const InitcodeWordGas: u64 = 2;

/// Maximum allowed initcode size in bytes
/// EIP-3860: Limit is 49152 bytes (2 * MAX_CODE_SIZE)
pub const MaxInitcodeSize: u64 = 49152;

// ============================================================================
// Transaction Costs
// ============================================================================

/// Base gas cost for a standard transaction
/// Minimum cost for any transaction regardless of data or computation
pub const TxGas: u64 = 21000;

/// Base gas cost for contract creation transaction
/// Higher than standard tx due to contract deployment overhead
pub const TxGasContractCreation: u64 = 53000;

/// Gas cost per zero byte in transaction data
/// Cheaper than non-zero bytes to incentivize data efficiency
pub const TxDataZeroGas: u64 = 4;

/// Gas cost per non-zero byte in transaction data
/// Higher cost reflects increased storage and bandwidth requirements
pub const TxDataNonZeroGas: u64 = 16;

/// Gas cost per word for copy operations
/// Applied to CODECOPY, EXTCODECOPY, RETURNDATACOPY, etc.
pub const CopyGas: u64 = 3;

// Alias for backwards compatibility
pub const COPY_GAS: u64 = CopyGas;

/// Maximum gas refund as a fraction of gas used
/// EIP-3529: Reduced from 1/2 to 1/5 to prevent refund abuse
pub const MaxRefundQuotient: u64 = 5;

// ============================================================================
// EIP-4844: Shard Blob Transactions
// ============================================================================

/// Gas cost for BLOBHASH opcode
/// Returns the hash of a blob associated with the transaction
pub const BlobHashGas: u64 = 3;

/// Gas cost for BLOBBASEFEE opcode
/// Returns the base fee for blob gas
pub const BlobBaseFeeGas: u64 = 2;

// ============================================================================
// EIP-1153: Transient Storage
// ============================================================================

/// Gas cost for TLOAD (transient storage load)
/// Transient storage is cleared after each transaction
pub const TLoadGas: u64 = 100;

/// Gas cost for TSTORE (transient storage store)
/// Same cost as TLOAD, much cheaper than persistent storage
pub const TStoreGas: u64 = 100;

// ============================================================================
// Precompile Operation Costs
// ============================================================================

/// Base gas cost for IDENTITY precompile (address 0x04)
/// Minimum cost regardless of input size
pub const IDENTITY_BASE_COST: u64 = 15;

/// Gas cost per 32-byte word for IDENTITY precompile
/// Total cost = IDENTITY_BASE_COST + (word_count * IDENTITY_WORD_COST)
pub const IDENTITY_WORD_COST: u64 = 3;

/// Base gas cost for SHA256 precompile (address 0x02)
/// Minimum cost regardless of input size
pub const SHA256_BASE_COST: u64 = 60;

/// Gas cost per 32-byte word for SHA256 precompile
/// Total cost = SHA256_BASE_COST + (word_count * SHA256_WORD_COST)
pub const SHA256_WORD_COST: u64 = 12;

/// Base gas cost for RIPEMD160 precompile (address 0x03)
/// Minimum cost regardless of input size
pub const RIPEMD160_BASE_COST: u64 = 600;

/// Gas cost per 32-byte word for RIPEMD160 precompile
/// Total cost = RIPEMD160_BASE_COST + (word_count * RIPEMD160_WORD_COST)
pub const RIPEMD160_WORD_COST: u64 = 120;

/// Base gas cost for ECRECOVER precompile (address 0x01)
/// Fixed cost for elliptic curve signature recovery
pub const ECRECOVER_COST: u64 = 3000;

// ============================================================================
// BN254 Elliptic Curve Precompile Costs (EIP-196, EIP-197, EIP-1108)
// ============================================================================

/// Gas cost for ECADD precompile (address 0x06) - Istanbul hardfork onwards
/// EIP-1108: Reduced from 500 gas to make zkSNARK operations more affordable
pub const ECADD_GAS_COST: u64 = 150;

/// Gas cost for ECADD precompile (address 0x06) - Byzantium to Berlin
/// Original cost before EIP-1108 optimization
pub const ECADD_GAS_COST_BYZANTIUM: u64 = 500;

/// Gas cost for ECMUL precompile (address 0x07) - Istanbul hardfork onwards
/// EIP-1108: Reduced from 40,000 gas to make zkSNARK operations more affordable
pub const ECMUL_GAS_COST: u64 = 6000;

/// Gas cost for ECMUL precompile (address 0x07) - Byzantium to Berlin
/// Original cost before EIP-1108 optimization
pub const ECMUL_GAS_COST_BYZANTIUM: u64 = 40000;

/// Base gas cost for ECPAIRING precompile (address 0x08) - Istanbul hardfork onwards
/// EIP-1108: Reduced from 100,000 gas to make zkSNARK operations more affordable
pub const ECPAIRING_BASE_GAS_COST: u64 = 45000;

/// Per-pair gas cost for ECPAIRING precompile - Istanbul hardfork onwards
/// EIP-1108: Reduced from 80,000 per pair to 34,000 per pair
pub const ECPAIRING_PER_PAIR_GAS_COST: u64 = 34000;

/// Base gas cost for ECPAIRING precompile (address 0x08) - Byzantium to Berlin
/// Original cost before EIP-1108 optimization
pub const ECPAIRING_BASE_GAS_COST_BYZANTIUM: u64 = 100000;

/// Per-pair gas cost for ECPAIRING precompile - Byzantium to Berlin
/// Original cost before EIP-1108 optimization
pub const ECPAIRING_PER_PAIR_GAS_COST_BYZANTIUM: u64 = 80000;

// ============================================================================
// MODEXP Precompile Costs (EIP-2565)
// ============================================================================

/// Minimum gas cost for MODEXP precompile (address 0x05)
/// EIP-2565: Reduced from previous higher costs to provide gas optimization
pub const MODEXP_MIN_GAS: u64 = 200;

/// Threshold for quadratic complexity in MODEXP gas calculation
/// Inputs smaller than this use simple quadratic cost formula
pub const MODEXP_QUADRATIC_THRESHOLD: usize = 64;

/// Threshold for linear complexity in MODEXP gas calculation
/// Inputs between quadratic and linear thresholds use optimized formula
pub const MODEXP_LINEAR_THRESHOLD: usize = 1024;

// ============================================================================
// Call Operation Gas Constants (EIP-150 & EIP-2929)
// ============================================================================

/// Base gas cost for CALL operations when target account is warm
/// This is the minimum cost for any call operation
pub const CALL_BASE_COST: u64 = 100;

/// Gas cost for CALL operations when target account is cold (EIP-2929)
/// Cold account access is more expensive to prevent state access attacks
pub const CALL_COLD_ACCOUNT_COST: u64 = 2600;

/// Additional gas cost when CALL transfers value (ETH)
/// Makes value transfers more expensive to prevent spam
pub const CALL_VALUE_TRANSFER_COST: u64 = 9000;

/// Additional gas cost when CALL creates a new account
/// Reflects the cost of adding a new entry to the state trie
pub const CALL_NEW_ACCOUNT_COST: u64 = 25000;

/// Gas stipend provided to called contract when transferring value
/// Ensures called contract has minimum gas to execute basic operations
/// This gas cannot be used for value calls to prevent attack vectors
pub const GAS_STIPEND_VALUE_TRANSFER: u64 = 2300;

/// Divisor for the 63/64 gas retention rule
/// Caller retains 1/64 of available gas, forwards the rest
/// Formula: retained_gas = available_gas / CALL_GAS_RETENTION_DIVISOR
pub const CALL_GAS_RETENTION_DIVISOR: u64 = 64;

/// Calculate memory expansion gas cost
///
/// Computes the gas cost for expanding EVM memory from current_size to new_size bytes.
/// Memory expansion follows a quadratic cost formula to prevent DoS attacks.
///
/// ## Parameters
/// - `current_size`: Current memory size in bytes
/// - `new_size`: Requested new memory size in bytes
///
/// ## Returns
/// - Gas cost for the expansion (0 if new_size <= current_size)
///
/// ## Formula
/// The total memory cost for n words is: 3n + n²/512
/// Where a word is 32 bytes.
pub fn memoryGasCost(current_size: u64, new_size: u64) u64 {
    if (new_size <= current_size) return 0;

    const current_words = wordCount(current_size);
    const new_words = wordCount(new_size);

    // Calculate cost for each size
    const current_cost = MemoryGas * current_words + (current_words * current_words) / QuadCoeffDiv;
    const new_cost = MemoryGas * new_words + (new_words * new_words) / QuadCoeffDiv;

    return new_cost - current_cost;
}

/// Calculate the number of 32-byte words required for a given byte size
///
/// This is a shared utility function used throughout the EVM for gas calculations
/// that depend on word counts. Many operations charge per 32-byte word.
///
/// ## Parameters
/// - `bytes`: Size in bytes
///
/// ## Returns
/// - Number of 32-byte words (rounded up)
///
/// ## Formula
/// word_count = ceil(bytes / 32) = (bytes + 31) / 32
pub inline fn wordCount(bytes: usize) usize {
    // Handle potential overflow when adding 31
    if (bytes > std.math.maxInt(usize) - 31) {
        return std.math.maxInt(usize) / 32;
    }
    return (bytes + 31) / 32;
}

// ============================================================================
// Reusable Gas Calculation Functions
// ============================================================================

/// Calculate gas cost for CALL operations with various conditions
///
/// Provides a centralized, testable function for calculating CALL gas costs
/// based on EIP-150 and EIP-2929 specifications.
///
/// ## Parameters
/// - `value_transfer`: Whether the call transfers ETH value
/// - `new_account`: Whether the target account is being created
/// - `cold_access`: Whether this is a cold (first-time) account access
///
/// ## Returns
/// - Total gas cost for the CALL operation
///
/// ## Usage
/// ```zig
/// const call_cost = callGasCost(true, false, true); // Value transfer to existing cold account
/// const simple_call = callGasCost(false, false, false); // Simple warm call
/// ```
pub inline fn callGasCost(value_transfer: bool, new_account: bool, cold_access: bool) u64 {
    var gas = CALL_BASE_COST;

    if (cold_access) {
        gas += CALL_COLD_ACCOUNT_COST;
    }

    if (value_transfer) {
        gas += CALL_VALUE_TRANSFER_COST;
    }

    if (new_account) {
        gas += CALL_NEW_ACCOUNT_COST;
    }

    return gas;
}

/// Calculate gas cost for SSTORE operations based on storage state changes
///
/// Implements the complex SSTORE gas calculation logic from EIP-2200 and EIP-3529.
/// This centralizes the storage gas logic that varies significantly across hardforks.
///
/// ## Parameters
/// - `current`: Current storage slot value
/// - `original`: Original storage slot value (start of transaction)
/// - `new`: New storage slot value being set
/// - `is_cold`: Whether this is a cold storage access (EIP-2929)
///
/// ## Returns
/// - Gas cost for the SSTORE operation
///
/// ## Usage
/// ```zig
/// const cost = sstoreGasCost(0, 0, 42, true); // Set zero to non-zero (cold)
/// const update_cost = sstoreGasCost(10, 10, 20, false); // Modify existing value (warm)
/// ```
pub inline fn sstoreGasCost(current: u256, original: u256, new: u256, is_cold: bool) u64 {
    var gas: u64 = 0;

    // Add cold access cost if applicable (EIP-2929)
    if (is_cold) {
        gas += ColdSloadCost;
    }

    // Determine storage operation type and cost
    if (original == current and current == new) {
        // No change - minimum cost
        gas += SloadGas; // Same as warm SLOAD
    } else if (original == current and current != new) {
        // First modification in this transaction
        if (original == 0) {
            // Setting zero to non-zero (most expensive)
            gas += SstoreSetGas;
        } else {
            // Modifying existing non-zero value
            gas += SstoreResetGas;
        }
    } else {
        // Subsequent modification (already modified in this transaction)
        gas += SloadGas; // Same as warm SLOAD
    }

    return gas;
}

/// Calculate gas cost for CREATE operations based on init code size
///
/// Implements EIP-3860 init code size limits and per-word charging.
///
/// ## Parameters
/// - `init_code_size`: Size of the initialization code in bytes
/// - `init_code_word_cost`: Gas cost per 32-byte word of init code (hardfork-dependent)
///
/// ## Returns
/// - Gas cost for the CREATE operation
///
/// ## Usage
/// ```zig
/// const create_cost = createGasCost(1024, InitcodeWordGas); // CREATE with 1KB init code
/// const large_create = createGasCost(32768, InitcodeWordGas); // Large contract deployment
/// ```
pub inline fn createGasCost(init_code_size: usize, init_code_word_cost: u64) u64 {
    const word_count = wordCount(init_code_size);
    return CreateGas + (word_count * init_code_word_cost);
}

/// Calculate gas cost for LOG operations with topics and data
///
/// Implements the gas calculation for LOG0-LOG4 operations based on
/// the number of topics and size of logged data.
///
/// ## Parameters
/// - `topic_count`: Number of topics (0-4 for LOG0-LOG4)
/// - `data_size`: Size of the data being logged in bytes
///
/// ## Returns
/// - Gas cost for the LOG operation
///
/// ## Usage
/// ```zig
/// const log0_cost = logGasCost(0, 256); // LOG0 with 256 bytes of data
/// const log3_cost = logGasCost(3, 128); // LOG3 with 3 topics and 128 bytes of data
/// ```
pub inline fn logGasCost(topic_count: u8, data_size: usize) u64 {
    var gas = LogGas; // Base cost
    gas += @as(u64, topic_count) * LogTopicGas; // Cost per topic
    gas += @as(u64, data_size) * LogDataGas; // Cost per byte of data
    return gas;
}

/// Calculate gas cost for copy operations (CODECOPY, RETURNDATACOPY, etc.)
///
/// Many EVM operations copy data and charge per 32-byte word copied.
/// This function provides a unified calculation for all copy operations.
///
/// ## Parameters
/// - `size`: Number of bytes being copied
///
/// ## Returns
/// - Gas cost for copying the specified amount of data
///
/// ## Usage
/// ```zig
/// const copy_cost = copyGasCost(1024); // Copy 1KB of data
/// const small_copy = copyGasCost(64); // Copy 64 bytes (2 words)
/// ```
pub inline fn copyGasCost(size: usize) u64 {
    const word_count = wordCount(size);
    return word_count * CopyGas;
}

/// Calculate gas cost for hash operations (KECCAK256)
///
/// Hash operations have a base cost plus a per-word cost for the data being hashed.
///
/// ## Parameters
/// - `data_size`: Size of data being hashed in bytes
///
/// ## Returns
/// - Gas cost for the hash operation
///
/// ## Usage
/// ```zig
/// const hash_cost = keccak256GasCost(128); // Hash 128 bytes of data
/// const large_hash = keccak256GasCost(4096); // Hash 4KB of data
/// ```
pub inline fn keccak256GasCost(data_size: usize) u64 {
    const word_count = wordCount(data_size);
    return Keccak256Gas + (word_count * Keccak256WordGas);
}

// ============================================================================
// Tests for Gas Calculation Functions
// ============================================================================

const testing = std.testing;

test "callGasCost function" {
    // Test basic call (warm, no value transfer, existing account)
    const basic_call = callGasCost(false, false, false);
    try testing.expectEqual(CALL_BASE_COST, basic_call);

    // Test cold call with no value transfer
    const cold_call = callGasCost(false, false, true);
    try testing.expectEqual(CALL_BASE_COST + CALL_COLD_ACCOUNT_COST, cold_call);

    // Test warm call with value transfer
    const value_call = callGasCost(true, false, false);
    try testing.expectEqual(CALL_BASE_COST + CALL_VALUE_TRANSFER_COST, value_call);

    // Test new account creation
    const new_account_call = callGasCost(false, true, false);
    try testing.expectEqual(CALL_BASE_COST + CALL_NEW_ACCOUNT_COST, new_account_call);

    // Test maximum cost (cold call with value transfer to new account)
    const max_cost_call = callGasCost(true, true, true);
    const expected_max = CALL_BASE_COST + CALL_COLD_ACCOUNT_COST + CALL_VALUE_TRANSFER_COST + CALL_NEW_ACCOUNT_COST;
    try testing.expectEqual(expected_max, max_cost_call);
}

test "sstoreGasCost function" {
    // Test no change (current == original == new)
    const no_change = sstoreGasCost(42, 42, 42, false);
    try testing.expectEqual(SloadGas, no_change);

    // Test setting zero to non-zero (most expensive case)
    const zero_to_nonzero = sstoreGasCost(0, 0, 42, false);
    try testing.expectEqual(SstoreSetGas, zero_to_nonzero);

    // Test cold access with zero to non-zero
    const cold_zero_to_nonzero = sstoreGasCost(0, 0, 42, true);
    try testing.expectEqual(ColdSloadCost + SstoreSetGas, cold_zero_to_nonzero);

    // Test modifying existing non-zero value
    const modify_nonzero = sstoreGasCost(10, 10, 20, false);
    try testing.expectEqual(SstoreResetGas, modify_nonzero);

    // Test subsequent modification (current != original)
    const subsequent_mod = sstoreGasCost(20, 10, 30, false);
    try testing.expectEqual(SloadGas, subsequent_mod);
}

test "createGasCost function" {
    // Test empty init code
    const empty_create = createGasCost(0, InitcodeWordGas);
    try testing.expectEqual(CreateGas, empty_create);

    // Test 32 bytes (1 word) of init code
    const one_word_create = createGasCost(32, InitcodeWordGas);
    try testing.expectEqual(CreateGas + InitcodeWordGas, one_word_create);

    // Test 64 bytes (2 words) of init code
    const two_word_create = createGasCost(64, InitcodeWordGas);
    try testing.expectEqual(CreateGas + 2 * InitcodeWordGas, two_word_create);

    // Test 33 bytes (2 words due to rounding up) of init code
    const partial_word_create = createGasCost(33, InitcodeWordGas);
    try testing.expectEqual(CreateGas + 2 * InitcodeWordGas, partial_word_create);
}

test "logGasCost function" {
    // Test LOG0 (no topics)
    const log0_cost = logGasCost(0, 0);
    try testing.expectEqual(LogGas, log0_cost);

    // Test LOG1 with no data
    const log1_no_data = logGasCost(1, 0);
    try testing.expectEqual(LogGas + LogTopicGas, log1_no_data);

    // Test LOG0 with data
    const log0_with_data = logGasCost(0, 100);
    try testing.expectEqual(LogGas + 100 * LogDataGas, log0_with_data);

    // Test LOG4 with data (maximum topics)
    const log4_with_data = logGasCost(4, 256);
    const expected = LogGas + 4 * LogTopicGas + 256 * LogDataGas;
    try testing.expectEqual(expected, log4_with_data);
}

test "copyGasCost function" {
    // Test zero size copy
    const zero_copy = copyGasCost(0);
    try testing.expectEqual(0, zero_copy);

    // Test 32 bytes (1 word)
    const one_word_copy = copyGasCost(32);
    try testing.expectEqual(CopyGas, one_word_copy);

    // Test 64 bytes (2 words)
    const two_word_copy = copyGasCost(64);
    try testing.expectEqual(2 * CopyGas, two_word_copy);

    // Test 33 bytes (2 words due to rounding up)
    const partial_word_copy = copyGasCost(33);
    try testing.expectEqual(2 * CopyGas, partial_word_copy);
}

test "keccak256GasCost function" {
    // Test zero size hash
    const zero_hash = keccak256GasCost(0);
    try testing.expectEqual(Keccak256Gas, zero_hash);

    // Test 32 bytes (1 word)
    const one_word_hash = keccak256GasCost(32);
    try testing.expectEqual(Keccak256Gas + Keccak256WordGas, one_word_hash);

    // Test 64 bytes (2 words)
    const two_word_hash = keccak256GasCost(64);
    try testing.expectEqual(Keccak256Gas + 2 * Keccak256WordGas, two_word_hash);

    // Test 33 bytes (2 words due to rounding up)
    const partial_word_hash = keccak256GasCost(33);
    try testing.expectEqual(Keccak256Gas + 2 * Keccak256WordGas, partial_word_hash);
}

test "memoryGasCost edge cases" {
    // Test same sizes (no expansion)
    try testing.expectEqual(@as(u64, 0), memoryGasCost(1000, 1000));
    try testing.expectEqual(@as(u64, 0), memoryGasCost(2048, 1000)); // new_size < current_size

    // Test zero expansion
    try testing.expectEqual(@as(u64, 0), memoryGasCost(0, 0));

    // Test small expansions (verifiable manually)
    const expand_to_32 = memoryGasCost(0, 32);
    const expected_32 = 3 * 1 + (1 * 1) / 512; // 1 word: 3 + 0 = 3
    try testing.expectEqual(expected_32, expand_to_32);

    const expand_to_64 = memoryGasCost(0, 64);
    const expected_64 = 3 * 2 + (2 * 2) / 512; // 2 words: 6 + 0 = 6
    try testing.expectEqual(expected_64, expand_to_64);
}

test "wordCount edge cases" {
    // Test zero size
    try testing.expectEqual(@as(usize, 0), wordCount(0));

    // Test exact word boundaries
    try testing.expectEqual(@as(usize, 1), wordCount(32));
    try testing.expectEqual(@as(usize, 2), wordCount(64));

    // Test partial words (should round up)
    try testing.expectEqual(@as(usize, 1), wordCount(1));
    try testing.expectEqual(@as(usize, 1), wordCount(31));
    try testing.expectEqual(@as(usize, 2), wordCount(33));

    // Test overflow protection
    const max_safe_bytes = std.math.maxInt(usize) - 31;
    const max_words = wordCount(max_safe_bytes);
    try testing.expect(max_words > 0); // Should not overflow

    const overflow_bytes = std.math.maxInt(usize);
    const overflow_words = wordCount(overflow_bytes);
    try testing.expectEqual(std.math.maxInt(usize) / 32, overflow_words);
}

// ============================================================================
// Additional Comprehensive Tests
// ============================================================================

test "memoryGasCost - quadratic growth behavior" {
    // Test quadratic growth for larger expansions
    // Formula: gas = 3n + n²/512

    // 512 bytes = 16 words
    // Cost = 3*16 + 16²/512 = 48 + 0.5 = 48
    const cost_512 = memoryGasCost(0, 512);
    try testing.expectEqual(@as(u64, 48), cost_512);

    // 1024 bytes = 32 words
    // Cost = 3*32 + 32²/512 = 96 + 2 = 98
    const cost_1024 = memoryGasCost(0, 1024);
    try testing.expectEqual(@as(u64, 98), cost_1024);

    // 2048 bytes = 64 words
    // Cost = 3*64 + 64²/512 = 192 + 8 = 200
    const cost_2048 = memoryGasCost(0, 2048);
    try testing.expectEqual(@as(u64, 200), cost_2048);
}

test "memoryGasCost - incremental expansions" {
    // Test expanding from existing memory
    const expand_1024_to_2048 = memoryGasCost(1024, 2048);
    const total_2048 = memoryGasCost(0, 2048);
    const total_1024 = memoryGasCost(0, 1024);

    // Cost should be the difference
    try testing.expectEqual(total_2048 - total_1024, expand_1024_to_2048);

    // Partial word expansions
    const expand_0_to_1 = memoryGasCost(0, 1);
    const expand_0_to_31 = memoryGasCost(0, 31);
    const expand_0_to_32 = memoryGasCost(0, 32);

    // All should cost the same (1 word)
    try testing.expectEqual(expand_0_to_1, expand_0_to_31);
    try testing.expectEqual(expand_0_to_31, expand_0_to_32);
    try testing.expectEqual(@as(u64, 3), expand_0_to_1);
}

test "callGasCost - all flag combinations" {
    // Test all 8 combinations of the 3 boolean parameters
    const scenarios = [_]struct {
        value_transfer: bool,
        new_account: bool,
        cold_access: bool,
        expected: u64,
    }{
        // Basic warm call
        .{ .value_transfer = false, .new_account = false, .cold_access = false, .expected = 100 },
        // Cold call only
        .{ .value_transfer = false, .new_account = false, .cold_access = true, .expected = 100 + 2600 },
        // Value transfer only
        .{ .value_transfer = true, .new_account = false, .cold_access = false, .expected = 100 + 9000 },
        // New account only
        .{ .value_transfer = false, .new_account = true, .cold_access = false, .expected = 100 + 25000 },
        // Cold + value
        .{ .value_transfer = true, .new_account = false, .cold_access = true, .expected = 100 + 2600 + 9000 },
        // Cold + new account
        .{ .value_transfer = false, .new_account = true, .cold_access = true, .expected = 100 + 2600 + 25000 },
        // Value + new account
        .{ .value_transfer = true, .new_account = true, .cold_access = false, .expected = 100 + 9000 + 25000 },
        // All flags (maximum cost)
        .{ .value_transfer = true, .new_account = true, .cold_access = true, .expected = 100 + 2600 + 9000 + 25000 },
    };

    for (scenarios) |scenario| {
        const cost = callGasCost(scenario.value_transfer, scenario.new_account, scenario.cold_access);
        try testing.expectEqual(scenario.expected, cost);
    }
}

test "sstoreGasCost - all state transitions" {
    // Test zero to non-zero (most expensive)
    try testing.expectEqual(@as(u64, 20000), sstoreGasCost(0, 0, 1, false));
    try testing.expectEqual(@as(u64, 22100), sstoreGasCost(0, 0, 1, true)); // cold

    // Test non-zero to different non-zero
    try testing.expectEqual(@as(u64, 5000), sstoreGasCost(1, 1, 2, false));
    try testing.expectEqual(@as(u64, 7100), sstoreGasCost(1, 1, 2, true)); // cold

    // Test non-zero to zero (clearing)
    try testing.expectEqual(@as(u64, 5000), sstoreGasCost(42, 42, 0, false));
    try testing.expectEqual(@as(u64, 7100), sstoreGasCost(42, 42, 0, true)); // cold

    // Test subsequent modifications
    try testing.expectEqual(@as(u64, 100), sstoreGasCost(2, 1, 3, false));
    try testing.expectEqual(@as(u64, 2200), sstoreGasCost(2, 1, 3, true)); // cold
}

test "createGasCost - init code size variations" {
    // Test various init code sizes
    try testing.expectEqual(@as(u64, 32000), createGasCost(0, InitcodeWordGas));
    try testing.expectEqual(@as(u64, 32002), createGasCost(1, InitcodeWordGas));
    try testing.expectEqual(@as(u64, 32002), createGasCost(32, InitcodeWordGas));
    try testing.expectEqual(@as(u64, 32004), createGasCost(33, InitcodeWordGas));
    try testing.expectEqual(@as(u64, 32064), createGasCost(1024, InitcodeWordGas));

    // Test maximum init code size (EIP-3860)
    const max_size = MaxInitcodeSize; // 49152 bytes
    const max_cost = createGasCost(max_size, InitcodeWordGas);
    const expected = 32000 + (49152 / 32) * 2; // 32000 + 1536 * 2 = 35072
    try testing.expectEqual(expected, max_cost);
}

test "logGasCost - all LOG opcodes" {
    // Test LOG0 through LOG4
    try testing.expectEqual(@as(u64, 375), logGasCost(0, 0)); // LOG0
    try testing.expectEqual(@as(u64, 750), logGasCost(1, 0)); // LOG1
    try testing.expectEqual(@as(u64, 1125), logGasCost(2, 0)); // LOG2
    try testing.expectEqual(@as(u64, 1500), logGasCost(3, 0)); // LOG3
    try testing.expectEqual(@as(u64, 1875), logGasCost(4, 0)); // LOG4

    // Test with data
    const data_size = 256;
    try testing.expectEqual(@as(u64, 375 + 256 * 8), logGasCost(0, data_size));
    try testing.expectEqual(@as(u64, 1875 + 256 * 8), logGasCost(4, data_size));
}

test "copyGasCost - alignment with CODECOPY operations" {
    // Test common copy sizes
    const sizes = [_]usize{ 0, 1, 32, 33, 64, 100, 256, 512, 1024, 4096 };

    for (sizes) |size| {
        const cost = copyGasCost(size);
        const expected_words = wordCount(size);
        try testing.expectEqual(expected_words * CopyGas, cost);
    }
}

test "keccak256GasCost - common hash scenarios" {
    // Empty input
    try testing.expectEqual(@as(u64, 30), keccak256GasCost(0));

    // Common sizes
    try testing.expectEqual(@as(u64, 36), keccak256GasCost(32)); // 1 word
    try testing.expectEqual(@as(u64, 42), keccak256GasCost(64)); // 2 words
    try testing.expectEqual(@as(u64, 78), keccak256GasCost(256)); // 8 words

    // Large hashes
    try testing.expectEqual(@as(u64, 222), keccak256GasCost(1024)); // 32 words
    try testing.expectEqual(@as(u64, 798), keccak256GasCost(4096)); // 128 words
}

test "gas calculation overflow protection" {
    // Test that calculations handle large inputs without overflow

    // Large memory expansion
    const large_memory = memoryGasCost(0, 1_000_000);
    try testing.expect(large_memory > 0);
    try testing.expect(large_memory < std.math.maxInt(u64));

    // Large copy operation
    const large_copy = copyGasCost(1_000_000);
    try testing.expect(large_copy > 0);
    try testing.expect(large_copy < std.math.maxInt(u64));

    // Large hash operation
    const large_hash = keccak256GasCost(1_000_000);
    try testing.expect(large_hash > 0);
    try testing.expect(large_hash < std.math.maxInt(u64));
}

test "gas constants match Ethereum specifications" {
    // Verify key constants match Yellow Paper and EIPs

    // Basic operations
    try testing.expectEqual(@as(u64, 3), GasFastestStep);
    try testing.expectEqual(@as(u64, 5), GasFastStep);
    try testing.expectEqual(@as(u64, 8), GasMidStep);

    // Storage operations (EIP-2929)
    try testing.expectEqual(@as(u64, 100), SloadGas);
    try testing.expectEqual(@as(u64, 2100), ColdSloadCost);
    try testing.expectEqual(@as(u64, 2600), ColdAccountAccessCost);

    // Contract creation
    try testing.expectEqual(@as(u64, 32000), CreateGas);
    try testing.expectEqual(@as(u64, 53000), TxGasContractCreation);

    // Memory and hashing
    try testing.expectEqual(@as(u64, 3), MemoryGas);
    try testing.expectEqual(@as(u64, 512), QuadCoeffDiv);
    try testing.expectEqual(@as(u64, 30), Keccak256Gas);
    try testing.expectEqual(@as(u64, 6), Keccak256WordGas);
}

// ============================================================================
// Edge Cases and Boundary Tests
// ============================================================================

test "memoryGasCost - maximum memory size" {
    // Test near maximum memory sizes
    const max_memory = 0x1FFFFFFFE0; // Maximum EVM memory size
    const near_max = max_memory - 32;

    // Expanding to maximum should work
    const expand_to_max = memoryGasCost(0, max_memory);
    try testing.expect(expand_to_max > 0);

    // Expanding from near-max to max
    const expand_near_to_max = memoryGasCost(near_max, max_memory);
    try testing.expect(expand_near_to_max > 0);
}

test "wordCount - special boundary cases" {
    // Test powers of 2 boundaries
    try testing.expectEqual(@as(usize, 16), wordCount(512)); // 2^9
    try testing.expectEqual(@as(usize, 32), wordCount(1024)); // 2^10
    try testing.expectEqual(@as(usize, 256), wordCount(8192)); // 2^13

    // Test maximum contract size
    const max_contract_size = 24576; // 24KB max contract size
    try testing.expectEqual(@as(usize, 768), wordCount(max_contract_size));
}

test "sstoreGasCost - complex state transitions" {
    // Test transition from non-zero to different non-zero back to original
    // This tests the "dirty" state tracking

    // Original = 10, Current = 20, New = 10 (reverting to original)
    try testing.expectEqual(@as(u64, 100), sstoreGasCost(20, 10, 10, false));

    // Original = 0, Current = 10, New = 0 (reverting to original zero)
    try testing.expectEqual(@as(u64, 100), sstoreGasCost(10, 0, 0, false));

    // Original = 10, Current = 0, New = 20 (was cleared, now setting different)
    try testing.expectEqual(@as(u64, 100), sstoreGasCost(0, 10, 20, false));
}

test "createGasCost - exact word boundaries" {
    // Test exact multiples of 32 bytes
    const word_sizes = [_]usize{ 32, 64, 128, 256, 512, 1024, 2048, 4096 };

    for (word_sizes) |size| {
        const cost = createGasCost(size, InitcodeWordGas);
        const expected = CreateGas + (size / 32) * InitcodeWordGas;
        try testing.expectEqual(expected, cost);
    }
}

test "logGasCost - maximum data sizes" {
    // Test with large data sizes that might be used in practice
    const large_sizes = [_]usize{ 1024, 2048, 4096, 8192, 16384 };

    for (large_sizes) |size| {
        for (0..5) |topic_count| {
            const cost = logGasCost(@intCast(topic_count), size);
            const expected = LogGas + topic_count * LogTopicGas + size * LogDataGas;
            try testing.expectEqual(expected, cost);
        }
    }
}

// ============================================================================
// Cross-Function Integration Tests
// ============================================================================

test "integration - CREATE2 full gas calculation" {
    // CREATE2 requires: base create cost + init code cost + hash cost
    const init_code_size = 1000;
    const salt_size = 32;
    const address_size = 20;
    const prefix_size = 1; // 0xff prefix

    // Calculate individual components
    const create_cost = createGasCost(init_code_size, InitcodeWordGas);
    const hash_input_size = prefix_size + address_size + salt_size + init_code_size;
    const hash_cost = keccak256GasCost(hash_input_size);

    // Total cost should be sum of components
    const total_cost = create_cost + hash_cost;
    try testing.expect(total_cost > CreateGas);
    try testing.expect(total_cost == 32000 + wordCount(init_code_size) * 2 + 30 + wordCount(hash_input_size) * 6);
}

test "integration - memory expansion with copy" {
    // Common pattern: expand memory then copy data
    const current_mem = 1000;
    const copy_offset = 2000;
    const copy_size = 500;
    const final_mem = copy_offset + copy_size; // 2500

    // Calculate costs
    const expansion_cost = memoryGasCost(current_mem, final_mem);
    const copy_cost = copyGasCost(copy_size);

    // Verify costs are reasonable
    try testing.expect(expansion_cost > 0);
    try testing.expect(copy_cost == wordCount(copy_size) * CopyGas);
}

test "integration - storage operation sequence" {
    // Simulate a sequence of storage operations in a transaction

    // First access (cold)
    const first_read = ColdSloadCost; // 2100

    // First write (cold, zero to non-zero)
    const first_write = sstoreGasCost(0, 0, 42, true); // 22100

    // Second read (warm)
    const second_read = SloadGas; // 100

    // Second write (warm, modify)
    const second_write = sstoreGasCost(42, 42, 100, false); // 5000

    // Third write (warm, already modified)
    const third_write = sstoreGasCost(100, 42, 200, false); // 100

    // Total sequence cost
    const total = first_read + first_write + second_read + second_write + third_write;
    try testing.expectEqual(@as(u64, 29400), total);
}

// ============================================================================
// Gas Refund Calculation Tests
// ============================================================================

test "storage refunds - clearing storage" {
    // Test gas refund calculations for storage clearing

    // Clear storage (non-zero to zero)
    const clear_cost = sstoreGasCost(42, 42, 0, false);
    try testing.expectEqual(SstoreResetGas, clear_cost);

    // Refund should be SstoreRefundGas
    try testing.expectEqual(@as(u64, 4800), SstoreRefundGas);

    // Maximum refund is gas_used / MaxRefundQuotient
    const gas_used = 100000;
    const max_refund = gas_used / MaxRefundQuotient;
    try testing.expectEqual(@as(u64, 20000), max_refund);
}

// ============================================================================
// Precompile Gas Cost Tests
// ============================================================================

test "precompile gas costs - identity" {
    // Identity precompile (0x04)
    const sizes = [_]usize{ 0, 32, 64, 128, 256 };

    for (sizes) |size| {
        const cost = IDENTITY_BASE_COST + wordCount(size) * IDENTITY_WORD_COST;
        try testing.expectEqual(15 + wordCount(size) * 3, cost);
    }
}

test "precompile gas costs - sha256" {
    // SHA256 precompile (0x02)
    const sizes = [_]usize{ 0, 32, 64, 128, 256 };

    for (sizes) |size| {
        const cost = SHA256_BASE_COST + wordCount(size) * SHA256_WORD_COST;
        try testing.expectEqual(60 + wordCount(size) * 12, cost);
    }
}

test "precompile gas costs - ecrecover" {
    // ECRECOVER has fixed cost regardless of input
    try testing.expectEqual(@as(u64, 3000), ECRECOVER_COST);
}

// ============================================================================
// Transaction Gas Cost Tests
// ============================================================================

test "transaction gas costs - data costs" {
    // Test transaction data gas costs
    const zero_bytes = 100;
    const non_zero_bytes = 50;

    const data_cost = zero_bytes * TxDataZeroGas + non_zero_bytes * TxDataNonZeroGas;
    try testing.expectEqual(@as(u64, 100 * 4 + 50 * 16), data_cost);

    // Total transaction cost
    const total_tx_cost = TxGas + data_cost;
    try testing.expectEqual(@as(u64, 21000 + 400 + 800), total_tx_cost);
}

// ============================================================================
// EIP-4844 Blob Transaction Tests
// ============================================================================

test "blob transaction gas costs" {
    // Test blob-related opcodes
    try testing.expectEqual(@as(u64, 3), BlobHashGas);
    try testing.expectEqual(@as(u64, 2), BlobBaseFeeGas);
}

// ============================================================================
// EIP-1153 Transient Storage Tests
// ============================================================================

test "transient storage gas costs" {
    // TLOAD and TSTORE have same cost
    try testing.expectEqual(@as(u64, 100), TLoadGas);
    try testing.expectEqual(@as(u64, 100), TStoreGas);

    // Much cheaper than persistent storage
    try testing.expect(TStoreGas < SstoreResetGas);
    try testing.expect(TLoadGas == SloadGas); // Same as warm SLOAD
}

// ============================================================================
// Hardfork-Specific Gas Cost Tests
// ============================================================================

test "hardfork - EIP-150 Tangerine Whistle gas repricing" {
    // EIP-150 increased costs for IO-heavy operations

    // CALL operations base cost
    try testing.expectEqual(@as(u64, 700), CallCodeCost);
    try testing.expectEqual(@as(u64, 40), CallGas); // Base CALL gas

    // SELFDESTRUCT was free before EIP-150, then 5000 gas
    try testing.expectEqual(@as(u64, 5000), SelfdestructGas);

    // EXT* operations cost 20 gas (previously cheaper)
    try testing.expectEqual(@as(u64, 20), GasExtStep);
}

test "hardfork - EIP-1108 Istanbul bn256 precompile repricing" {
    // Istanbul dramatically reduced bn256 precompile costs

    // ECADD: 500 → 150 gas
    try testing.expectEqual(@as(u64, 150), ECADD_GAS_COST);
    try testing.expectEqual(@as(u64, 500), ECADD_GAS_COST_BYZANTIUM);

    // ECMUL: 40,000 → 6,000 gas
    try testing.expectEqual(@as(u64, 6000), ECMUL_GAS_COST);
    try testing.expectEqual(@as(u64, 40000), ECMUL_GAS_COST_BYZANTIUM);

    // ECPAIRING base: 100,000 → 45,000 gas
    try testing.expectEqual(@as(u64, 45000), ECPAIRING_BASE_GAS_COST);
    try testing.expectEqual(@as(u64, 100000), ECPAIRING_BASE_GAS_COST_BYZANTIUM);

    // ECPAIRING per pair: 80,000 → 34,000 gas
    try testing.expectEqual(@as(u64, 34000), ECPAIRING_PER_PAIR_GAS_COST);
    try testing.expectEqual(@as(u64, 80000), ECPAIRING_PER_PAIR_GAS_COST_BYZANTIUM);
}

test "hardfork - EIP-2929 Berlin cold/warm access" {
    // Berlin introduced cold/warm access patterns

    // Cold access costs (first time in transaction)
    try testing.expectEqual(@as(u64, 2600), ColdAccountAccessCost);
    try testing.expectEqual(@as(u64, 2100), ColdSloadCost);

    // Warm access costs (subsequent accesses)
    try testing.expectEqual(@as(u64, 100), WarmStorageReadCost);
    try testing.expectEqual(@as(u64, 100), SloadGas);

    // CALL cold account cost
    try testing.expectEqual(@as(u64, 2600), CALL_COLD_ACCOUNT_COST);

    // Verify cold costs are higher than warm
    try testing.expect(ColdAccountAccessCost > WarmStorageReadCost);
    try testing.expect(ColdSloadCost > SloadGas);
}

test "hardfork - EIP-3529 London gas refund changes" {
    // London reduced refunds to prevent refund abuse

    // SSTORE refund reduced from 15,000 to 4,800
    try testing.expectEqual(@as(u64, 4800), SstoreRefundGas);

    // SELFDESTRUCT refund removed (was 24,000)
    try testing.expectEqual(@as(u64, 24000), SelfdestructRefundGas);

    // Max refund quotient changed from 2 to 5 (max 1/5 of gas used)
    try testing.expectEqual(@as(u64, 5), MaxRefundQuotient);
}

test "hardfork - EIP-3860 Shanghai initcode limit" {
    // Shanghai introduced init code size limit and per-word cost

    // Maximum init code size (2 * max contract size)
    try testing.expectEqual(@as(u64, 49152), MaxInitcodeSize);

    // Cost per 32-byte word of init code
    try testing.expectEqual(@as(u64, 2), InitcodeWordGas);

    // Verify max size is 2x contract size limit
    const max_contract_size = 24576;
    try testing.expectEqual(max_contract_size * 2, MaxInitcodeSize);
}

test "hardfork - EIP-1153 Cancun transient storage" {
    // Cancun introduced transient storage opcodes

    // TLOAD and TSTORE both cost 100 gas
    try testing.expectEqual(@as(u64, 100), TLoadGas);
    try testing.expectEqual(@as(u64, 100), TStoreGas);

    // Same as warm storage access
    try testing.expectEqual(TLoadGas, WarmStorageReadCost);
    try testing.expectEqual(TStoreGas, WarmStorageReadCost);

    // Much cheaper than persistent storage
    try testing.expect(TStoreGas < SstoreSetGas);
    try testing.expect(TStoreGas < SstoreResetGas);
}

test "hardfork - EIP-4844 Cancun blob transactions" {
    // Cancun introduced blob-carrying transactions

    // BLOBHASH opcode cost
    try testing.expectEqual(@as(u64, 3), BlobHashGas);

    // BLOBBASEFEE opcode cost
    try testing.expectEqual(@as(u64, 2), BlobBaseFeeGas);

    // Blob opcodes are cheap (similar to basic operations)
    try testing.expect(BlobHashGas == GasFastestStep);
    try testing.expect(BlobBaseFeeGas == GasQuickStep);
}

// ============================================================================
// Hardfork Gas Calculation Functions
// ============================================================================

/// Calculate CALL gas cost based on hardfork rules
pub fn callGasCostWithHardfork(
    value_transfer: bool,
    new_account: bool,
    cold_access: bool,
    is_berlin_or_later: bool,
) u64 {
    var gas = CALL_BASE_COST;

    // EIP-2929 (Berlin): Cold access costs
    if (is_berlin_or_later and cold_access) {
        gas += CALL_COLD_ACCOUNT_COST;
    }

    // Value transfer cost (all hardforks)
    if (value_transfer) {
        gas += CALL_VALUE_TRANSFER_COST;
    }

    // New account creation cost (all hardforks)
    if (new_account) {
        gas += CALL_NEW_ACCOUNT_COST;
    }

    return gas;
}

/// Calculate storage gas cost based on hardfork rules
pub fn sstoreGasCostWithHardfork(
    current: u256,
    original: u256,
    new: u256,
    is_cold: bool,
    is_berlin_or_later: bool,
    is_istanbul_or_later: bool,
) u64 {
    var gas: u64 = 0;

    // EIP-2929 (Berlin): Add cold access cost if applicable
    if (is_berlin_or_later and is_cold) {
        gas += ColdSloadCost;
    }

    // EIP-2200 (Istanbul) storage gas calculation
    if (is_istanbul_or_later) {
        // Istanbul rules
        if (original == current and current == new) {
            // No change
            gas += if (is_berlin_or_later) WarmStorageReadCost else 200;
        } else if (original == current and current != new) {
            // First modification in transaction
            if (original == 0) {
                gas += SstoreSetGas; // 20000
            } else {
                gas += SstoreResetGas; // 5000
            }
        } else {
            // Subsequent modification
            gas += if (is_berlin_or_later) WarmStorageReadCost else 200;
        }
    } else {
        // Pre-Istanbul simple rules
        if (current == 0 and new != 0) {
            gas += 20000; // Set from zero
        } else {
            gas += 5000; // Reset existing
        }
    }

    return gas;
}

/// Calculate precompile gas cost based on hardfork
pub fn ecaddGasCostWithHardfork(is_istanbul_or_later: bool) u64 {
    return if (is_istanbul_or_later) ECADD_GAS_COST else ECADD_GAS_COST_BYZANTIUM;
}

pub fn ecmulGasCostWithHardfork(is_istanbul_or_later: bool) u64 {
    return if (is_istanbul_or_later) ECMUL_GAS_COST else ECMUL_GAS_COST_BYZANTIUM;
}

pub fn ecpairingGasCostWithHardfork(pair_count: usize, is_istanbul_or_later: bool) u64 {
    if (is_istanbul_or_later) {
        return ECPAIRING_BASE_GAS_COST + @as(u64, pair_count) * ECPAIRING_PER_PAIR_GAS_COST;
    } else {
        return ECPAIRING_BASE_GAS_COST_BYZANTIUM + @as(u64, pair_count) * ECPAIRING_PER_PAIR_GAS_COST_BYZANTIUM;
    }
}

test "hardfork gas calculation functions" {
    // Test CALL gas with hardfork differences

    // Pre-Berlin: no cold access penalty
    const pre_berlin_call = callGasCostWithHardfork(true, false, true, false);
    try testing.expectEqual(@as(u64, 9100), pre_berlin_call); // 100 + 9000

    // Post-Berlin: cold access penalty
    const post_berlin_call = callGasCostWithHardfork(true, false, true, true);
    try testing.expectEqual(@as(u64, 11700), post_berlin_call); // 100 + 2600 + 9000

    // Test storage gas with hardfork differences

    // Pre-Istanbul simple rules
    const pre_istanbul_sstore = sstoreGasCostWithHardfork(0, 0, 42, false, false, false);
    try testing.expectEqual(@as(u64, 20000), pre_istanbul_sstore);

    // Post-Istanbul with warm access
    const post_istanbul_warm = sstoreGasCostWithHardfork(42, 42, 42, false, false, true);
    try testing.expectEqual(@as(u64, 200), post_istanbul_warm);

    // Post-Berlin with warm access
    const post_berlin_warm = sstoreGasCostWithHardfork(42, 42, 42, false, true, true);
    try testing.expectEqual(@as(u64, 100), post_berlin_warm);

    // Test precompile gas with hardfork differences

    // Pre-Istanbul ECADD
    try testing.expectEqual(@as(u64, 500), ecaddGasCostWithHardfork(false));

    // Post-Istanbul ECADD
    try testing.expectEqual(@as(u64, 150), ecaddGasCostWithHardfork(true));

    // ECPAIRING with 2 pairs
    const pre_istanbul_pairing = ecpairingGasCostWithHardfork(2, false);
    try testing.expectEqual(@as(u64, 260000), pre_istanbul_pairing); // 100000 + 2*80000

    const post_istanbul_pairing = ecpairingGasCostWithHardfork(2, true);
    try testing.expectEqual(@as(u64, 113000), post_istanbul_pairing); // 45000 + 2*34000
}

// ============================================================================
// CREATE2 Hardfork-Specific Tests
// ============================================================================

test "hardfork - CREATE2 gas calculation across hardforks" {
    // CREATE2 introduced in Constantinople

    // Pre-Shanghai: no init code word cost
    const init_code_size = 1000;
    const pre_shanghai_cost = createGasCost(init_code_size, 0);
    try testing.expectEqual(@as(u64, 32000), pre_shanghai_cost);

    // Post-Shanghai: init code word cost
    const post_shanghai_cost = createGasCost(init_code_size, InitcodeWordGas);
    const expected_words = wordCount(init_code_size);
    try testing.expectEqual(32000 + expected_words * 2, post_shanghai_cost);

    // Hash cost for CREATE2 (unchanged across hardforks)
    const salt_and_address_size = 85; // 1 + 20 + 32 + 32
    const hash_input_size = salt_and_address_size + init_code_size;
    const hash_cost = keccak256GasCost(hash_input_size);
    try testing.expectEqual(30 + wordCount(hash_input_size) * 6, hash_cost);
}

// ============================================================================
// Transaction Type Gas Tests
// ============================================================================

test "hardfork - transaction type gas costs" {
    // Legacy transaction (all hardforks)
    try testing.expectEqual(@as(u64, 21000), TxGas);

    // Contract creation transaction
    try testing.expectEqual(@as(u64, 53000), TxGasContractCreation);

    // Transaction data costs (unchanged across hardforks)
    try testing.expectEqual(@as(u64, 4), TxDataZeroGas);
    try testing.expectEqual(@as(u64, 16), TxDataNonZeroGas);

    // EIP-2930 (Berlin) introduced access list transactions
    // Access list costs are handled via warm/cold mechanics

    // EIP-1559 (London) introduced base fee transactions
    // Gas costs remain the same, just fee calculation changes
}

// ============================================================================
// Memory Expansion Hardfork Tests
// ============================================================================

test "hardfork - memory expansion costs unchanged" {
    // Memory expansion formula unchanged across hardforks
    // gas = 3n + n²/512

    const sizes = [_]u64{ 0, 32, 64, 128, 256, 512, 1024, 2048, 4096 };

    for (sizes) |size| {
        const cost = memoryGasCost(0, size);
        const words = wordCount(size);
        const expected = MemoryGas * words + (words * words) / QuadCoeffDiv;
        try testing.expectEqual(expected, cost);
    }

    // Verify constants unchanged
    try testing.expectEqual(@as(u64, 3), MemoryGas);
    try testing.expectEqual(@as(u64, 512), QuadCoeffDiv);
}

// ============================================================================
// EIP-2200 Istanbul SSTORE Gas Tests
// ============================================================================

test "hardfork - EIP-2200 Istanbul SSTORE gas metering" {
    // Test Istanbul's complex SSTORE gas rules

    // Scenario 1: No-op (current == original == new)
    const no_op_gas = sstoreGasCost(42, 42, 42, false);
    try testing.expectEqual(@as(u64, 100), no_op_gas); // SloadGas

    // Scenario 2: Fresh slot (original == current == 0, new != 0)
    const fresh_slot_gas = sstoreGasCost(0, 0, 42, false);
    try testing.expectEqual(@as(u64, 20000), fresh_slot_gas); // SstoreSetGas

    // Scenario 3: Clean slot (original == current != 0, new == 0)
    const clean_slot_gas = sstoreGasCost(42, 42, 0, false);
    try testing.expectEqual(@as(u64, 5000), clean_slot_gas); // SstoreClearGas

    // Scenario 4: Reset to original (original != current, new == original)
    const reset_original_gas = sstoreGasCost(100, 42, 42, false);
    try testing.expectEqual(@as(u64, 100), reset_original_gas); // SloadGas

    // Scenario 5: Dirty write (original != current, new != original)
    const dirty_write_gas = sstoreGasCost(100, 42, 200, false);
    try testing.expectEqual(@as(u64, 100), dirty_write_gas); // SloadGas
}

// ============================================================================
// MODEXP Precompile Gas Tests
// ============================================================================

test "hardfork - MODEXP precompile gas thresholds" {
    // EIP-2565 introduced new gas calculation for MODEXP

    // Minimum gas cost
    try testing.expectEqual(@as(u64, 200), MODEXP_MIN_GAS);

    // Quadratic threshold (64 bytes)
    try testing.expectEqual(@as(usize, 64), MODEXP_QUADRATIC_THRESHOLD);

    // Linear threshold (1024 bytes)
    try testing.expectEqual(@as(usize, 1024), MODEXP_LINEAR_THRESHOLD);

    // For inputs smaller than 64 bytes, use simple quadratic formula
    // For inputs between 64-1024 bytes, use optimized formula
    // For inputs larger than 1024 bytes, use linear approximation
}

// ============================================================================
// Gas Stipend and Retention Tests
// ============================================================================

test "hardfork - gas stipends and retention" {
    // Test gas stipend for value transfers
    try testing.expectEqual(@as(u64, 2300), CallStipend);
    try testing.expectEqual(@as(u64, 2300), GAS_STIPEND_VALUE_TRANSFER);

    // Test 63/64 gas retention rule
    try testing.expectEqual(@as(u64, 64), CALL_GAS_RETENTION_DIVISOR);

    // Calculate retained gas for various amounts
    const test_gas_amounts = [_]u64{ 64000, 100000, 1000000 };
    for (test_gas_amounts) |gas| {
        const retained = gas / CALL_GAS_RETENTION_DIVISOR;
        const forwarded = gas - retained;
        // Note: Integer division may cause slight differences
        // 100000 / 64 = 1562 (retained), 100000 - 1562 = 98438
        // 100000 * 63 / 64 = 98437 (due to integer division)
        const expected_forwarded = gas - (gas / 64);
        try testing.expectEqual(expected_forwarded, forwarded);
    }
}

// ============================================================================
// Comprehensive Hardfork Timeline Tests
// ============================================================================

test "hardfork - gas cost evolution timeline" {
    // Test how specific operations changed across hardforks

    // SLOAD evolution
    // Pre-Berlin: 200 gas (after EIP-1884)
    // Post-Berlin: 100 gas warm, 2100 gas cold
    try testing.expectEqual(@as(u64, 100), SloadGas); // Warm
    try testing.expectEqual(@as(u64, 2100), ColdSloadCost); // Cold

    // SELFDESTRUCT evolution
    // Pre-EIP-150: 0 gas
    // Post-EIP-150: 5000 gas
    // Post-London: No refund (was 24000)
    try testing.expectEqual(@as(u64, 5000), SelfdestructGas);
    try testing.expectEqual(@as(u64, 24000), SelfdestructRefundGas);

    // BALANCE evolution
    // Pre-EIP-1884: 20 gas
    // Post-EIP-1884: 400 gas
    // Post-Berlin: 100 gas warm, 2600 gas cold
    try testing.expectEqual(@as(u64, 100), CALL_BASE_COST); // Warm access
    try testing.expectEqual(@as(u64, 2600), ColdAccountAccessCost); // Cold
}

// ============================================================================
// Edge Case Hardfork Tests
// ============================================================================

test "hardfork - edge cases across hardforks" {
    // Test edge cases that behave differently across hardforks

    // SSTORE with same value (no-op)
    _ = 5000; // no_op_pre_istanbul: Always charged before Istanbul
    _ = 200; // no_op_istanbul: Reduced in Istanbul
    _ = 100; // no_op_berlin: Further reduced in Berlin

    // Verify current (Berlin+) behavior
    const current_no_op = sstoreGasCost(42, 42, 42, false);
    try testing.expectEqual(@as(u64, 100), current_no_op);

    // CREATE2 with empty init code
    const empty_create2_pre_shanghai = createGasCost(0, 0);
    const empty_create2_post_shanghai = createGasCost(0, InitcodeWordGas);
    try testing.expectEqual(@as(u64, 32000), empty_create2_pre_shanghai);
    try testing.expectEqual(@as(u64, 32000), empty_create2_post_shanghai); // 0 words

    // Transient storage (only exists post-Cancun)
    try testing.expectEqual(@as(u64, 100), TLoadGas);
    try testing.expectEqual(@as(u64, 100), TStoreGas);
}
