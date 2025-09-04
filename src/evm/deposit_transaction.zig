//! Optimism Deposit Transaction Support
//!
//! Deposit transactions represent Layer 1 deposits into the Layer 2 network.
//! They are special system transactions that mint L2 ETH and execute deposit logic.
//!
//! ## Deposit Transaction Structure
//! - **source_hash**: Hash identifying the L1 source of this deposit
//! - **from**: L1 address initiating the deposit  
//! - **to**: L2 address receiving the deposit (can be null for contract creation)
//! - **mint**: Amount of L2 ETH to mint for this deposit
//! - **value**: Amount of L2 ETH to transfer to the recipient
//! - **gas_limit**: Gas limit for deposit execution
//! - **is_system_tx**: Whether this is a system transaction (no gas cost)
//! - **data**: Call data for the deposit transaction
//!
//! ## System Transaction Behavior  
//! - System transactions always succeed and consume zero gas
//! - Used for L2 system maintenance and forced L1 deposits
//! - Cannot fail or revert
//!
//! ## Key Properties
//! - Deposits mint L2 ETH from L1 ETH locked in bridge contracts
//! - Deposit transactions cannot be initiated directly on L2
//! - They are generated from L1 deposit events and included by the sequencer

const std = @import("std");
const testing = std.testing;
const primitives = @import("primitives");
const Address = primitives.Address;
const Hash = primitives.Hash;

/// Deposit transaction structure (Optimism L2 specific)
pub const DepositTransaction = struct {
    /// Hash of the L1 block and transaction that created this deposit
    source_hash: [32]u8,
    /// L1 address that initiated this deposit
    from: Address,
    /// L2 address receiving the deposit (null for contract creation)
    to: ?Address,
    /// Amount of L2 ETH to mint (in wei)
    mint: u256,
    /// Amount of L2 ETH to transfer to recipient (in wei)
    value: u256,
    /// Gas limit for deposit execution
    gas_limit: u64,
    /// Whether this is a system transaction (zero gas cost, always succeeds)
    is_system_tx: bool,
    /// Call data for the deposit transaction
    data: []const u8,

    /// Create a new deposit transaction
    pub fn init(
        source_hash: [32]u8,
        from: Address,
        to: ?Address,
        mint: u256,
        value: u256,
        gas_limit: u64,
        is_system_tx: bool,
        data: []const u8,
    ) DepositTransaction {
        return DepositTransaction{
            .source_hash = source_hash,
            .from = from,
            .to = to,
            .mint = mint,
            .value = value,
            .gas_limit = gas_limit,
            .is_system_tx = is_system_tx,
            .data = data,
        };
    }

    /// Check if this deposit transaction mints L2 ETH
    pub fn has_mint(self: DepositTransaction) bool {
        return self.mint > 0;
    }

    /// Check if this deposit transaction transfers value
    pub fn has_value(self: DepositTransaction) bool {
        return self.value > 0;
    }

    /// Check if this is a contract creation deposit
    pub fn is_creation(self: DepositTransaction) bool {
        return self.to == null;
    }

    /// Get effective gas limit (0 for system transactions)
    pub fn effective_gas_limit(self: DepositTransaction) u64 {
        if (self.is_system_tx) {
            return 0; // System transactions consume no gas
        }
        return self.gas_limit;
    }

    /// Validate deposit transaction parameters
    pub fn validate(self: DepositTransaction) DepositError!void {
        // Value cannot exceed mint amount  
        if (self.value > self.mint) {
            return DepositError.ValueExceedsMint;
        }
        
        // System transactions must have zero gas limit or will always succeed anyway
        if (self.is_system_tx and self.gas_limit == 0) {
            // This is valid - system tx with explicit zero gas
        }
        
        // Regular deposits must have non-zero gas limit
        if (!self.is_system_tx and self.gas_limit == 0) {
            return DepositError.ZeroGasLimit;
        }
    }
};

/// Deposit transaction execution result
pub const DepositResult = struct {
    /// Whether the deposit execution succeeded
    success: bool,
    /// Gas actually used during execution (always 0 for system transactions)
    gas_used: u64,
    /// Amount of ETH successfully minted
    minted: u256,
    /// Return data from deposit execution
    return_data: []const u8,
    /// Created contract address (for creation deposits)
    created_address: ?Address,
};

/// Deposit transaction error types
pub const DepositError = error{
    ValueExceedsMint,
    ZeroGasLimit,
    InvalidSourceHash,
    MintFailed,
    ExecutionFailed,
    OutOfMemory,
};

/// System addresses used in deposit transactions
pub const SYSTEM_ADDRESS = Address.from_hex("0xDeaDDEaDDeAdDeAdDEAdDEaddeAddEAdDEAdDEad") catch unreachable;
pub const DEPOSITOR_ACCOUNT = Address.from_hex("0x4200000000000000000000000000000000000007") catch unreachable;

/// Create a test deposit transaction for testing
pub fn create_test_deposit_transaction() DepositTransaction {
    return DepositTransaction.init(
        [_]u8{0x01} ** 32, // source_hash
        Address.from_hex("0x1234567890123456789012345678901234567890") catch unreachable, // from
        Address.from_hex("0x0987654321098765432109876543210987654321") catch unreachable, // to
        1000000000000000000, // mint (1 ETH)
        500000000000000000,  // value (0.5 ETH)
        21000, // gas_limit
        false, // is_system_tx
        &[_]u8{0x12, 0x34}, // data
    );
}

/// Create a system deposit transaction for testing
pub fn create_test_system_transaction() DepositTransaction {
    return DepositTransaction.init(
        [_]u8{0x02} ** 32, // source_hash
        SYSTEM_ADDRESS, // from
        DEPOSITOR_ACCOUNT, // to
        0, // mint
        0, // value
        1000000, // gas_limit (will be ignored)
        true, // is_system_tx
        &[_]u8{}, // data
    );
}

// Tests following TDD approach

test "deposit transaction creation and field access" {
    const deposit = create_test_deposit_transaction();
    
    try testing.expectEqual([_]u8{0x01} ** 32, deposit.source_hash);
    try testing.expectEqual(Address.from_hex("0x1234567890123456789012345678901234567890") catch unreachable, deposit.from);
    try testing.expectEqual(Address.from_hex("0x0987654321098765432109876543210987654321") catch unreachable, deposit.to.?);
    try testing.expectEqual(@as(u256, 1000000000000000000), deposit.mint);
    try testing.expectEqual(@as(u256, 500000000000000000), deposit.value);
    try testing.expectEqual(@as(u64, 21000), deposit.gas_limit);
    try testing.expect(!deposit.is_system_tx);
    try testing.expectEqual(@as(usize, 2), deposit.data.len);
}

test "deposit transaction property checks" {
    const deposit = create_test_deposit_transaction();
    const zero_mint_deposit = DepositTransaction.init(
        [_]u8{0x01} ** 32,
        Address.from_hex("0x1111111111111111111111111111111111111111") catch unreachable,
        Address.from_hex("0x2222222222222222222222222222222222222222") catch unreachable,
        0, // zero mint
        0, // zero value
        21000,
        false,
        &[_]u8{},
    );
    
    try testing.expect(deposit.has_mint());
    try testing.expect(deposit.has_value());
    try testing.expect(!deposit.is_creation());
    
    try testing.expect(!zero_mint_deposit.has_mint());
    try testing.expect(!zero_mint_deposit.has_value());
}

test "deposit transaction contract creation" {
    const creation_deposit = DepositTransaction.init(
        [_]u8{0x01} ** 32,
        Address.from_hex("0x1111111111111111111111111111111111111111") catch unreachable,
        null, // to = null for creation
        1000000000000000000,
        1000000000000000000,
        100000,
        false,
        &[_]u8{0x60, 0x80, 0x60, 0x40}, // constructor bytecode
    );
    
    try testing.expect(creation_deposit.is_creation());
    try testing.expectEqual(@as(?Address, null), creation_deposit.to);
    try testing.expectEqual(@as(usize, 4), creation_deposit.data.len);
}

test "system transaction behavior" {
    const system_tx = create_test_system_transaction();
    
    try testing.expect(system_tx.is_system_tx);
    try testing.expectEqual(@as(u64, 0), system_tx.effective_gas_limit());
    try testing.expectEqual(SYSTEM_ADDRESS, system_tx.from);
    try testing.expectEqual(@as(u256, 0), system_tx.mint);
    try testing.expectEqual(@as(u256, 0), system_tx.value);
}

test "deposit transaction validation" {
    // Valid deposit
    const valid_deposit = create_test_deposit_transaction();
    try valid_deposit.validate();
    
    // Invalid: value exceeds mint
    const invalid_deposit = DepositTransaction.init(
        [_]u8{0x01} ** 32,
        Address.from_hex("0x1111111111111111111111111111111111111111") catch unreachable,
        Address.from_hex("0x2222222222222222222222222222222222222222") catch unreachable,
        100, // mint
        200, // value > mint (invalid)
        21000,
        false,
        &[_]u8{},
    );
    
    try testing.expectError(DepositError.ValueExceedsMint, invalid_deposit.validate());
    
    // Invalid: non-system transaction with zero gas
    const zero_gas_deposit = DepositTransaction.init(
        [_]u8{0x01} ** 32,
        Address.from_hex("0x1111111111111111111111111111111111111111") catch unreachable,
        Address.from_hex("0x2222222222222222222222222222222222222222") catch unreachable,
        100,
        50,
        0, // zero gas limit
        false, // not system tx
        &[_]u8{},
    );
    
    try testing.expectError(DepositError.ZeroGasLimit, zero_gas_deposit.validate());
    
    // Valid: system transaction with zero gas
    const system_zero_gas = DepositTransaction.init(
        [_]u8{0x01} ** 32,
        SYSTEM_ADDRESS,
        DEPOSITOR_ACCOUNT,
        0,
        0,
        0, // zero gas limit
        true, // system tx
        &[_]u8{},
    );
    
    try system_zero_gas.validate();
}

test "deposit result structure" {
    const result = DepositResult{
        .success = true,
        .gas_used = 21000,
        .minted = 1000000000000000000,
        .return_data = &[_]u8{0x01, 0x02},
        .created_address = Address.from_hex("0x3333333333333333333333333333333333333333") catch unreachable,
    };
    
    try testing.expect(result.success);
    try testing.expectEqual(@as(u64, 21000), result.gas_used);
    try testing.expectEqual(@as(u256, 1000000000000000000), result.minted);
    try testing.expectEqual(@as(usize, 2), result.return_data.len);
    try testing.expectEqual(Address.from_hex("0x3333333333333333333333333333333333333333") catch unreachable, result.created_address.?);
}