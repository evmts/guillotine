const std = @import("std");
const primitives = @import("voltaire");
const Address = primitives.Address.Address;

/// Account state data structure
///
/// ## Field Ordering Optimization
/// Fields are ordered to minimize padding and improve cache locality:
/// - Large fields (u256, [32]u8) grouped together
/// - Smaller fields (u64) grouped together
/// - Most frequently accessed fields (balance, nonce) first
pub const Account = struct {
    /// Account balance in wei (frequently accessed)
    balance: u256,

    /// Hash of the contract code (keccak256 hash)
    /// Grouped with storage_root for better cache locality
    code_hash: [32]u8,

    /// Storage root hash (merkle root of account's storage trie)
    storage_root: [32]u8,

    /// Transaction nonce (number of transactions sent from this account)
    /// Smaller field placed last to minimize padding
    nonce: u64,

    /// EIP-7702: Delegated code address
    /// When non-zero, this EOA delegates code execution to this address
    /// Only valid for EOAs (accounts with no code_hash)
    delegated_address: ?Address = null,

    /// Creates a new account with zero values
    pub fn zero() Account {
        return Account{
            .balance = 0,
            .code_hash = @as([32]u8, @splat(0)),
            .storage_root = @as([32]u8, @splat(0)),
            .nonce = 0,
            .delegated_address = null,
        };
    }

    /// True when `code_hash` names non-empty code. An account without code carries
    /// either the all-zero hash (never initialized) or `EMPTY_CODE_HASH`
    /// (keccak256 of the empty string); both mean "no code".
    pub fn is_code_hash_present(code_hash: [32]u8) bool {
        return !std.mem.eql(u8, &code_hash, &@as([32]u8, @splat(0))) and
            !std.mem.eql(u8, &code_hash, &primitives.EMPTY_CODE_HASH);
    }

    /// True when the account has code: stored contract code, or an EIP-7702
    /// delegation designator (`0xef0100 || address`), which is 23 bytes of code.
    pub fn has_code(self: Account) bool {
        return self.delegated_address != null or is_code_hash_present(self.code_hash);
    }

    /// Checks if account is empty (zero balance, nonce, and no code)
    pub fn is_empty(self: Account) bool {
        return self.balance == 0 and
            self.nonce == 0 and
            !self.has_code();
    }

    /// EIP-7702: Check if this is an EOA with delegated code
    pub fn has_delegation(self: Account) bool {
        return self.delegated_address != null;
    }

    /// EIP-7702: Get the effective code address for this account
    /// Returns the delegated address if set, otherwise null
    pub fn get_effective_code_address(self: Account) ?Address {
        // Only EOAs can have delegations
        // EOAs have either zero code_hash or EMPTY_CODE_HASH
        const is_eoa = !is_code_hash_present(self.code_hash);
        if (!is_eoa) {
            return null;
        }
        return self.delegated_address;
    }

    /// EIP-7702: Set delegation for this EOA
    pub fn set_delegation(self: *Account, address: Address) void {
        // Only EOAs can have delegations
        // EOAs have either zero code_hash or EMPTY_CODE_HASH
        const is_eoa = !is_code_hash_present(self.code_hash);
        if (is_eoa) {
            self.delegated_address = address;
        }
    }

    /// EIP-7702: Clear delegation for this EOA
    pub fn clear_delegation(self: *Account) void {
        self.delegated_address = null;
    }
};

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

test "Account.zero creates account with all zero values" {
    const account = Account.zero();
    try testing.expectEqual(@as(u256, 0), account.balance);
    try testing.expectEqual(@as(u64, 0), account.nonce);
    try testing.expectEqualSlices(u8, &@as([32]u8, @splat(0)), &account.code_hash);
    try testing.expectEqualSlices(u8, &@as([32]u8, @splat(0)), &account.storage_root);
}

test "Account.is_empty detects empty accounts" {
    const empty_account = Account.zero();
    try testing.expect(empty_account.is_empty());

    var non_empty_account = Account.zero();
    non_empty_account.balance = 100;
    try testing.expect(!non_empty_account.is_empty());

    non_empty_account = Account.zero();
    non_empty_account.nonce = 1;
    try testing.expect(!non_empty_account.is_empty());

    non_empty_account = Account.zero();
    non_empty_account.code_hash[0] = 1;
    try testing.expect(!non_empty_account.is_empty());

    non_empty_account = Account.zero();
    non_empty_account.delegated_address = Address.fromU256(0x1234);
    try testing.expect(!non_empty_account.is_empty());
}

test "EIP-7702: Account delegation" {
    var account = Account.zero();
    
    // Initially no delegation
    try testing.expect(!account.has_delegation());
    try testing.expect(account.get_effective_code_address() == null);
    
    // Set delegation
    const delegate_address = Address.fromU256(0x1234);
    account.set_delegation(delegate_address);
    try testing.expect(account.has_delegation());
    try testing.expect(account.get_effective_code_address() != null);
    try testing.expectEqual(delegate_address, account.get_effective_code_address().?);
    
    // Clear delegation
    account.clear_delegation();
    try testing.expect(!account.has_delegation());
    try testing.expect(account.get_effective_code_address() == null);
}

test "EIP-7702: Delegation only works for EOAs" {
    var account = Account.zero();

    // Set code hash (making it a contract)
    account.code_hash = @as([32]u8, @splat(0x42));

    // Try to set delegation - should not work for contracts
    const delegate_address = Address.fromU256(0x1234);
    account.set_delegation(delegate_address);

    // Delegation should not be set
    try testing.expect(!account.has_delegation());
    try testing.expect(account.get_effective_code_address() == null);
}

test "Account field accessors - balance" {
    var account = Account.zero();
    try testing.expectEqual(@as(u256, 0), account.balance);

    account.balance = 1_000_000_000_000_000_000;
    try testing.expectEqual(@as(u256, 1_000_000_000_000_000_000), account.balance);

    account.balance = std.math.maxInt(u256);
    try testing.expectEqual(std.math.maxInt(u256), account.balance);
}

test "Account field accessors - nonce" {
    var account = Account.zero();
    try testing.expectEqual(@as(u64, 0), account.nonce);

    account.nonce = 1;
    try testing.expectEqual(@as(u64, 1), account.nonce);

    account.nonce = 42;
    try testing.expectEqual(@as(u64, 42), account.nonce);

    account.nonce = std.math.maxInt(u64);
    try testing.expectEqual(std.math.maxInt(u64), account.nonce);
}

test "Account field accessors - code_hash" {
    var account = Account.zero();
    try testing.expectEqualSlices(u8, &@as([32]u8, @splat(0)), &account.code_hash);

    const test_hash = @as([32]u8, @splat(0xaa));
    account.code_hash = test_hash;
    try testing.expectEqualSlices(u8, &test_hash, &account.code_hash);

    account.code_hash = primitives.EMPTY_CODE_HASH;
    try testing.expectEqualSlices(u8, &primitives.EMPTY_CODE_HASH, &account.code_hash);
}

test "Account field accessors - storage_root" {
    var account = Account.zero();
    try testing.expectEqualSlices(u8, &@as([32]u8, @splat(0)), &account.storage_root);

    const test_root = @as([32]u8, @splat(0xbb));
    account.storage_root = test_root;
    try testing.expectEqualSlices(u8, &test_root, &account.storage_root);
}

test "Account.is_empty - balance only" {
    var account = Account.zero();
    account.balance = 1;
    try testing.expect(!account.is_empty());
}

test "Account.is_empty - nonce only" {
    var account = Account.zero();
    account.nonce = 1;
    try testing.expect(!account.is_empty());
}

test "Account.is_empty - code_hash only" {
    var account = Account.zero();
    account.code_hash[0] = 1;
    try testing.expect(!account.is_empty());
}

test "Account.is_empty - delegation only" {
    var account = Account.zero();
    account.delegated_address = Address.fromU256(0x1234);
    try testing.expect(!account.is_empty());
}

test "Account.is_empty - multiple fields non-zero" {
    var account = Account.zero();
    account.balance = 100;
    account.nonce = 5;
    account.code_hash = @as([32]u8, @splat(0xcc));
    try testing.expect(!account.is_empty());
}

test "EIP-7702: has_delegation returns false for zero account" {
    const account = Account.zero();
    try testing.expect(!account.has_delegation());
}

test "EIP-7702: has_delegation returns true when delegation is set" {
    var account = Account.zero();
    account.delegated_address = Address.fromU256(0x9999);
    try testing.expect(account.has_delegation());
}

test "EIP-7702: get_effective_code_address for EOA with EMPTY_CODE_HASH" {
    var account = Account.zero();
    account.code_hash = primitives.EMPTY_CODE_HASH;
    const delegate = Address.fromU256(0xabcd);
    account.delegated_address = delegate;

    const effective = account.get_effective_code_address();
    try testing.expect(effective != null);
    try testing.expectEqual(delegate, effective.?);
}

test "EIP-7702: set_delegation with EMPTY_CODE_HASH" {
    var account = Account.zero();
    account.code_hash = primitives.EMPTY_CODE_HASH;
    const delegate = Address.fromU256(0x5555);

    account.set_delegation(delegate);
    try testing.expect(account.has_delegation());
    try testing.expectEqual(delegate, account.delegated_address.?);
}

test "EIP-7702: clear_delegation removes delegation" {
    var account = Account.zero();
    const delegate = Address.fromU256(0x7777);
    account.set_delegation(delegate);
    try testing.expect(account.has_delegation());

    account.clear_delegation();
    try testing.expect(!account.has_delegation());
    try testing.expect(account.delegated_address == null);
}

test "EIP-7702: delegation overwrite" {
    var account = Account.zero();
    const first_delegate = Address.fromU256(0x1111);
    const second_delegate = Address.fromU256(0x2222);

    account.set_delegation(first_delegate);
    try testing.expectEqual(first_delegate, account.delegated_address.?);

    account.set_delegation(second_delegate);
    try testing.expectEqual(second_delegate, account.delegated_address.?);
}

test "EIP-7702: contract account cannot get effective code address" {
    var account = Account.zero();
    account.code_hash = @as([32]u8, @splat(0xdd));
    account.delegated_address = Address.fromU256(0x8888);

    const effective = account.get_effective_code_address();
    try testing.expect(effective == null);
}

test "Account creation with specific values" {
    const account = Account{
        .balance = 5_000_000_000_000_000_000,
        .code_hash = @as([32]u8, @splat(0xef)),
        .storage_root = @as([32]u8, @splat(0xfe)),
        .nonce = 10,
        .delegated_address = null,
    };

    try testing.expectEqual(@as(u256, 5_000_000_000_000_000_000), account.balance);
    try testing.expectEqual(@as(u64, 10), account.nonce);
    try testing.expectEqualSlices(u8, &@as([32]u8, @splat(0xef)), &account.code_hash);
    try testing.expectEqualSlices(u8, &@as([32]u8, @splat(0xfe)), &account.storage_root);
    try testing.expect(account.delegated_address == null);
}

test "Account equality comparison" {
    const account1 = Account{
        .balance = 1000,
        .code_hash = @as([32]u8, @splat(0x11)),
        .storage_root = @as([32]u8, @splat(0x22)),
        .nonce = 5,
        .delegated_address = null,
    };

    const account2 = Account{
        .balance = 1000,
        .code_hash = @as([32]u8, @splat(0x11)),
        .storage_root = @as([32]u8, @splat(0x22)),
        .nonce = 5,
        .delegated_address = null,
    };

    try testing.expectEqual(account1.balance, account2.balance);
    try testing.expectEqual(account1.nonce, account2.nonce);
    try testing.expectEqualSlices(u8, &account1.code_hash, &account2.code_hash);
    try testing.expectEqualSlices(u8, &account1.storage_root, &account2.storage_root);
}

test "Account with max values" {
    const account = Account{
        .balance = std.math.maxInt(u256),
        .code_hash = @as([32]u8, @splat(0xff)),
        .storage_root = @as([32]u8, @splat(0xff)),
        .nonce = std.math.maxInt(u64),
        .delegated_address = Address.fromU256(std.math.maxInt(u256)),
    };

    try testing.expectEqual(std.math.maxInt(u256), account.balance);
    try testing.expectEqual(std.math.maxInt(u64), account.nonce);
    try testing.expect(account.has_delegation());
}

test "Account.has_code treats the zero hash and EMPTY_CODE_HASH as no code" {
    var account = Account.zero();
    try testing.expect(!account.has_code());
    try testing.expect(account.is_empty());

    account.code_hash = primitives.EMPTY_CODE_HASH;
    try testing.expect(!account.has_code());
    try testing.expect(account.is_empty());
    try testing.expect(!Account.is_code_hash_present(account.code_hash));

    account.code_hash = @as([32]u8, @splat(0xAB));
    try testing.expect(account.has_code());
    try testing.expect(!account.is_empty());

    var delegated = Account.zero();
    delegated.code_hash = primitives.EMPTY_CODE_HASH;
    delegated.set_delegation(Address.fromU256(0x1234));
    try testing.expect(delegated.has_code());
    try testing.expectEqual(Address.fromU256(0x1234), delegated.get_effective_code_address().?);
}
