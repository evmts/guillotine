//! EIP-7702 Authorization Processing
//!
//! This module handles the processing of authorization lists for EIP-7702
//! delegated EOA transactions. It validates authorizations, updates account
//! delegations, and manages gas costs.

const std = @import("std");
const primitives = @import("primitives");
const Address = primitives.Address.Address;
const Authorization = primitives.Authorization.Authorization;
const Database = @import("database.zig").Database;
const Account = @import("database_interface_account.zig").Account;
const log = @import("log.zig");

pub const AuthorizationError = error{
    InvalidChainId,
    NonceMismatch,
    NotEOA,
    InvalidSignature,
    AccountNotFound,
    DatabaseError,
    OutOfGas,
};

/// Authorization processor for EIP-7702
pub const AuthorizationProcessor = struct {
    /// Database for state access
    db: *Database,
    /// Current chain ID
    chain_id: u64,
    /// Gas tracking
    gas_remaining: *i64,
    
    /// Process a single authorization
    pub fn processAuthorization(
        self: *AuthorizationProcessor,
        auth: Authorization,
        authority: Address,
    ) AuthorizationError!void {
        // Validate chain ID
        if (auth.chain_id != self.chain_id) {
            log.debug("Authorization chain ID mismatch: expected {}, got {}", .{ self.chain_id, auth.chain_id });
            return AuthorizationError.InvalidChainId;
        }
        
        // Get authority account
        const account_opt = self.db.get_account(authority.bytes) catch |err| {
            log.err("Failed to get authority account: {}", .{err});
            return AuthorizationError.DatabaseError;
        };
        
        const account = account_opt orelse {
            log.debug("Authority account not found: {x}", .{authority.bytes});
            return AuthorizationError.AccountNotFound;
        };
        
        // Check if it's an EOA (no code)
        if (!std.mem.eql(u8, &account.code_hash, &[_]u8{0} ** 32)) {
            log.debug("Authority is not an EOA (has code)", .{});
            return AuthorizationError.NotEOA;
        }
        
        // Special case: revocation with max nonce
        if (auth.nonce == std.math.maxInt(u64)) {
            // Revoke delegation
            var updated_account = account;
            updated_account.clear_delegation();
            self.db.set_account(authority.bytes, updated_account) catch |err| {
                log.err("Failed to update account for revocation: {}", .{err});
                return AuthorizationError.DatabaseError;
            };
            log.debug("Revoked delegation for EOA {x}", .{authority.bytes});
            return;
        }
        
        // Check nonce matches
        if (auth.nonce != account.nonce) {
            log.debug("Authorization nonce mismatch: expected {}, got {}", .{ account.nonce, auth.nonce });
            return AuthorizationError.NonceMismatch;
        }
        
        // Update account with delegation
        var updated_account = account;
        updated_account.set_delegation(auth.address);
        updated_account.nonce += 1; // Increment nonce after successful authorization
        
        self.db.set_account(authority.bytes, updated_account) catch |err| {
            log.err("Failed to update account: {}", .{err});
            return AuthorizationError.DatabaseError;
        };
        
        log.debug("Set delegation for EOA {x} to {x}", .{ authority.bytes, auth.address.bytes });
    }
    
    /// Process an authorization list
    pub fn processAuthorizationList(
        self: *AuthorizationProcessor,
        auth_list: []const Authorization,
    ) AuthorizationError!void {
        // Gas costs per EIP-7702
        const PER_AUTH_BASE_COST = 12500;
        const PER_EMPTY_ACCOUNT_COST = 25000;
        
        for (auth_list) |auth| {
            // Validate authorization
            auth.validate() catch |err| {
                log.debug("Authorization validation failed: {}", .{err});
                continue; // Skip invalid authorizations
            };
            
            // Recover authority (signer)
            const authority = auth.authority() catch |err| {
                log.debug("Failed to recover authority: {}", .{err});
                continue;
            };
            
            // Check if account is empty (for gas calculation)
            const account_opt = self.db.get_account(authority.bytes) catch {
                continue;
            };
            
            // Calculate gas cost
            var gas_cost: i64 = PER_AUTH_BASE_COST;
            if (account_opt == null or account_opt.?.is_empty()) {
                gas_cost += PER_EMPTY_ACCOUNT_COST;
            }
            
            // Check gas
            if (self.gas_remaining.* < gas_cost) {
                return AuthorizationError.OutOfGas;
            }
            self.gas_remaining.* -= gas_cost;
            
            // Process the authorization
            self.processAuthorization(auth, authority) catch |err| {
                log.debug("Failed to process authorization: {}", .{err});
                // Continue processing other authorizations
            };
        }
    }
    
    /// Create delegation designator (0xef0100 || address)
    pub fn createDelegationDesignator(
        allocator: std.mem.Allocator,
        address: Address,
    ) ![]u8 {
        var designator = try allocator.alloc(u8, 23);
        designator[0] = 0xef;
        designator[1] = 0x01;
        designator[2] = 0x00;
        @memcpy(designator[3..23], &address.bytes);
        return designator;
    }
    
    /// Parse delegation designator
    pub fn parseDelegationDesignator(designator: []const u8) AuthorizationError!Address {
        if (designator.len != 23) return AuthorizationError.InvalidSignature;
        if (designator[0] != 0xef or designator[1] != 0x01 or designator[2] != 0x00) {
            return AuthorizationError.InvalidSignature;
        }
        return Address{ .bytes = designator[3..23].* };
    }
};

test "Authorization processor - basic delegation" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const MemoryDatabase = @import("memory_database.zig");
    
    // Create database
    var db = MemoryDatabase.init(allocator);
    defer db.deinit();
    
    // Create EOA account
    const eoa_address = try Address.from_hex("0x1111111111111111111111111111111111111111");
    var eoa_account = Account.zero();
    eoa_account.balance = 1_000_000_000_000_000_000;
    eoa_account.nonce = 5;
    try db.set_account(eoa_address.bytes, eoa_account);
    
    // Create authorization
    const auth = Authorization{
        .chain_id = 1,
        .address = try Address.from_hex("0x2222222222222222222222222222222222222222"),
        .nonce = 5, // Matches EOA nonce
        .v = 27,
        .r = [_]u8{0x12} ** 32,
        .s = [_]u8{0x34} ** 32,
    };
    
    // Process authorization
    var gas_remaining: i64 = 100_000;
    var processor = AuthorizationProcessor{
        .db = &db,
        .chain_id = 1,
        .gas_remaining = &gas_remaining,
    };
    
    // Mock authority for testing (normally recovered from signature)
    try processor.processAuthorization(auth, eoa_address);
    
    // Verify delegation was set
    const updated_account = try db.get_account(eoa_address.bytes);
    try testing.expect(updated_account.?.has_delegation());
    try testing.expectEqual(auth.address, updated_account.?.get_effective_code_address().?);
    try testing.expectEqual(@as(u64, 6), updated_account.?.nonce); // Nonce incremented
}

test "Authorization processor - wrong nonce rejected" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const MemoryDatabase = @import("memory_database.zig");
    
    var db = MemoryDatabase.init(allocator);
    defer db.deinit();
    
    const eoa_address = try Address.from_hex("0x1111111111111111111111111111111111111111");
    var eoa_account = Account.zero();
    eoa_account.nonce = 5;
    try db.set_account(eoa_address.bytes, eoa_account);
    
    const auth = Authorization{
        .chain_id = 1,
        .address = try Address.from_hex("0x2222222222222222222222222222222222222222"),
        .nonce = 10, // Wrong nonce
        .v = 27,
        .r = [_]u8{0x12} ** 32,
        .s = [_]u8{0x34} ** 32,
    };
    
    var gas_remaining: i64 = 100_000;
    var processor = AuthorizationProcessor{
        .db = &db,
        .chain_id = 1,
        .gas_remaining = &gas_remaining,
    };
    
    try testing.expectError(AuthorizationError.NonceMismatch, processor.processAuthorization(auth, eoa_address));
}

test "Authorization processor - delegation designator format" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    const delegate_address = try Address.from_hex("0x1234567890123456789012345678901234567890");
    
    // Create delegation designator
    const designator = try AuthorizationProcessor.createDelegationDesignator(allocator, delegate_address);
    defer allocator.free(designator);
    
    // Verify format: 0xef0100 (3 bytes) + address (20 bytes) = 23 bytes total
    try testing.expectEqual(@as(usize, 23), designator.len);
    try testing.expectEqual(@as(u8, 0xef), designator[0]);
    try testing.expectEqual(@as(u8, 0x01), designator[1]);
    try testing.expectEqual(@as(u8, 0x00), designator[2]);
    try testing.expectEqualSlices(u8, &delegate_address.bytes, designator[3..23]);
    
    // Parse it back
    const parsed_address = try AuthorizationProcessor.parseDelegationDesignator(designator);
    try testing.expectEqual(delegate_address, parsed_address);
}