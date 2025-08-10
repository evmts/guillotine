/// EVM gas cost constants for opcode execution
///
/// This module defines all gas cost constants used in EVM execution according
/// to the Ethereum Yellow Paper and various EIPs. Gas costs are critical for
/// preventing denial-of-service attacks and fairly pricing computational resources.
const std = @import("std");
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
pub fn memory_gas_cost(current_size: u64, new_size: u64) u64 {
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
/// const call_cost = call_gas_cost(true, false, true); // Value transfer to existing cold account
/// const simple_call = call_gas_cost(false, false, false); // Simple warm call
/// ```
pub inline fn call_gas_cost(value_transfer: bool, new_account: bool, cold_access: bool) u64 {
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
/// const cost = sstore_gas_cost(0, 0, 42, true); // Set zero to non-zero (cold)
/// const update_cost = sstore_gas_cost(10, 10, 20, false); // Modify existing value (warm)
/// ```
pub inline fn sstore_gas_cost(current: u256, original: u256, new: u256, is_cold: bool) u64 {
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
/// const create_cost = create_gas_cost(1024, InitcodeWordGas); // CREATE with 1KB init code
/// const large_create = create_gas_cost(32768, InitcodeWordGas); // Large contract deployment
/// ```
pub inline fn create_gas_cost(init_code_size: usize, init_code_word_cost: u64) u64 {
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
/// const log0_cost = log_gas_cost(0, 256); // LOG0 with 256 bytes of data
/// const log3_cost = log_gas_cost(3, 128); // LOG3 with 3 topics and 128 bytes of data
/// ```
pub inline fn log_gas_cost(topic_count: u8, data_size: usize) u64 {
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
/// const copy_cost = copy_gas_cost(1024); // Copy 1KB of data
/// const small_copy = copy_gas_cost(64); // Copy 64 bytes (2 words)
/// ```
pub inline fn copy_gas_cost(size: usize) u64 {
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
/// const hash_cost = keccak256_gas_cost(128); // Hash 128 bytes of data
/// const large_hash = keccak256_gas_cost(4096); // Hash 4KB of data
/// ```
pub inline fn keccak256_gas_cost(data_size: usize) u64 {
    const word_count = wordCount(data_size);
    return Keccak256Gas + (word_count * Keccak256WordGas);
}

// ============================================================================
// Tests for Gas Calculation Functions
// ============================================================================

const testing = std.testing;

test "call_gas_cost function" {
    // Test basic call (warm, no value transfer, existing account)
    const basic_call = call_gas_cost(false, false, false);
    try testing.expectEqual(CALL_BASE_COST, basic_call);

    // Test cold call with no value transfer
    const cold_call = call_gas_cost(false, false, true);
    try testing.expectEqual(CALL_BASE_COST + CALL_COLD_ACCOUNT_COST, cold_call);

    // Test warm call with value transfer
    const value_call = call_gas_cost(true, false, false);
    try testing.expectEqual(CALL_BASE_COST + CALL_VALUE_TRANSFER_COST, value_call);

    // Test new account creation
    const new_account_call = call_gas_cost(false, true, false);
    try testing.expectEqual(CALL_BASE_COST + CALL_NEW_ACCOUNT_COST, new_account_call);

    // Test maximum cost (cold call with value transfer to new account)
    const max_cost_call = call_gas_cost(true, true, true);
    const expected_max = CALL_BASE_COST + CALL_COLD_ACCOUNT_COST + CALL_VALUE_TRANSFER_COST + CALL_NEW_ACCOUNT_COST;
    try testing.expectEqual(expected_max, max_cost_call);
}

test "sstore_gas_cost function" {
    // Test no change (current == original == new)
    const no_change = sstore_gas_cost(42, 42, 42, false);
    try testing.expectEqual(SloadGas, no_change);

    // Test setting zero to non-zero (most expensive case)
    const zero_to_nonzero = sstore_gas_cost(0, 0, 42, false);
    try testing.expectEqual(SstoreSetGas, zero_to_nonzero);

    // Test cold access with zero to non-zero
    const cold_zero_to_nonzero = sstore_gas_cost(0, 0, 42, true);
    try testing.expectEqual(ColdSloadCost + SstoreSetGas, cold_zero_to_nonzero);

    // Test modifying existing non-zero value
    const modify_nonzero = sstore_gas_cost(10, 10, 20, false);
    try testing.expectEqual(SstoreResetGas, modify_nonzero);

    // Test subsequent modification (current != original)
    const subsequent_mod = sstore_gas_cost(20, 10, 30, false);
    try testing.expectEqual(SloadGas, subsequent_mod);
}

test "create_gas_cost function" {
    // Test empty init code
    const empty_create = create_gas_cost(0, InitcodeWordGas);
    try testing.expectEqual(CreateGas, empty_create);

    // Test 32 bytes (1 word) of init code
    const one_word_create = create_gas_cost(32, InitcodeWordGas);
    try testing.expectEqual(CreateGas + InitcodeWordGas, one_word_create);

    // Test 64 bytes (2 words) of init code
    const two_word_create = create_gas_cost(64, InitcodeWordGas);
    try testing.expectEqual(CreateGas + 2 * InitcodeWordGas, two_word_create);

    // Test 33 bytes (2 words due to rounding up) of init code
    const partial_word_create = create_gas_cost(33, InitcodeWordGas);
    try testing.expectEqual(CreateGas + 2 * InitcodeWordGas, partial_word_create);
}

test "log_gas_cost function" {
    // Test LOG0 (no topics)
    const log0_cost = log_gas_cost(0, 0);
    try testing.expectEqual(LogGas, log0_cost);

    // Test LOG1 with no data
    const log1_no_data = log_gas_cost(1, 0);
    try testing.expectEqual(LogGas + LogTopicGas, log1_no_data);

    // Test LOG0 with data
    const log0_with_data = log_gas_cost(0, 100);
    try testing.expectEqual(LogGas + 100 * LogDataGas, log0_with_data);

    // Test LOG4 with data (maximum topics)
    const log4_with_data = log_gas_cost(4, 256);
    const expected = LogGas + 4 * LogTopicGas + 256 * LogDataGas;
    try testing.expectEqual(expected, log4_with_data);
}

test "copy_gas_cost function" {
    // Test zero size copy
    const zero_copy = copy_gas_cost(0);
    try testing.expectEqual(0, zero_copy);

    // Test 32 bytes (1 word)
    const one_word_copy = copy_gas_cost(32);
    try testing.expectEqual(CopyGas, one_word_copy);

    // Test 64 bytes (2 words)
    const two_word_copy = copy_gas_cost(64);
    try testing.expectEqual(2 * CopyGas, two_word_copy);

    // Test 33 bytes (2 words due to rounding up)
    const partial_word_copy = copy_gas_cost(33);
    try testing.expectEqual(2 * CopyGas, partial_word_copy);
}

test "keccak256_gas_cost function" {
    // Test zero size hash
    const zero_hash = keccak256_gas_cost(0);
    try testing.expectEqual(Keccak256Gas, zero_hash);

    // Test 32 bytes (1 word)
    const one_word_hash = keccak256_gas_cost(32);
    try testing.expectEqual(Keccak256Gas + Keccak256WordGas, one_word_hash);

    // Test 64 bytes (2 words)
    const two_word_hash = keccak256_gas_cost(64);
    try testing.expectEqual(Keccak256Gas + 2 * Keccak256WordGas, two_word_hash);

    // Test 33 bytes (2 words due to rounding up)
    const partial_word_hash = keccak256_gas_cost(33);
    try testing.expectEqual(Keccak256Gas + 2 * Keccak256WordGas, partial_word_hash);
}

test "memory_gas_cost edge cases" {
    // Test same sizes (no expansion)
    try testing.expectEqual(@as(u64, 0), memory_gas_cost(1000, 1000));
    try testing.expectEqual(@as(u64, 0), memory_gas_cost(2048, 1000)); // new_size < current_size

    // Test zero expansion
    try testing.expectEqual(@as(u64, 0), memory_gas_cost(0, 0));

    // Test small expansions (verifiable manually)
    const expand_to_32 = memory_gas_cost(0, 32);
    const expected_32 = 3 * 1 + (1 * 1) / 512; // 1 word: 3 + 0 = 3
    try testing.expectEqual(expected_32, expand_to_32);

    const expand_to_64 = memory_gas_cost(0, 64);
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
