const std = @import("std");

// Import primitives if available, otherwise define a minimal Address type for testing
const Address = if (@hasDecl(@import("root"), "primitives")) 
    @import("primitives").Address.Address
else struct {
    bytes: [20]u8,
    
    pub fn from_u256(value: u256) @This() {
        var addr = @This(){ .bytes = [_]u8{0} ** 20 };
        var v = value;
        var i: usize = 20;
        while (i > 0 and v > 0) {
            i -= 1;
            addr.bytes[i] = @intCast(v & 0xFF);
            v >>= 8;
        }
        return addr;
    }
};

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
            .code_hash = [_]u8{0} ** 32,
            .storage_root = [_]u8{0} ** 32,
            .nonce = 0,
            .delegated_address = null,
        };
    }

    /// Checks if account is empty (zero balance, nonce, and no code)
    pub fn is_empty(self: Account) bool {
        return self.balance == 0 and
            self.nonce == 0 and
            std.mem.eql(u8, &self.code_hash, &[_]u8{0} ** 32) and
            self.delegated_address == null;
    }

    /// EIP-7702: Check if this is an EOA with delegated code
    pub fn has_delegation(self: Account) bool {
        return self.delegated_address != null;
    }

    /// EIP-7702: Get the effective code address for this account
    /// Returns the delegated address if set, otherwise null
    pub fn get_effective_code_address(self: Account) ?Address {
        // Only EOAs can have delegations
        if (!std.mem.eql(u8, &self.code_hash, &[_]u8{0} ** 32)) {
            return null;
        }
        return self.delegated_address;
    }

    /// EIP-7702: Set delegation for this EOA
    pub fn set_delegation(self: *Account, address: Address) void {
        // Only EOAs can have delegations
        if (std.mem.eql(u8, &self.code_hash, &[_]u8{0} ** 32)) {
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
    try testing.expectEqualSlices(u8, &[_]u8{0} ** 32, &account.code_hash);
    try testing.expectEqualSlices(u8, &[_]u8{0} ** 32, &account.storage_root);
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
    non_empty_account.delegated_address = Address.from_u256(0x1234);
    try testing.expect(!non_empty_account.is_empty());
}

test "EIP-7702: Account delegation" {
    var account = Account.zero();
    
    // Initially no delegation
    try testing.expect(!account.has_delegation());
    try testing.expect(account.get_effective_code_address() == null);
    
    // Set delegation
    const delegate_address = Address.from_u256(0x1234);
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
    account.code_hash = [_]u8{0x42} ** 32;
    
    // Try to set delegation - should not work for contracts
    const delegate_address = Address.from_u256(0x1234);
    account.set_delegation(delegate_address);
    
    // Delegation should not be set
    try testing.expect(!account.has_delegation());
    try testing.expect(account.get_effective_code_address() == null);
}
