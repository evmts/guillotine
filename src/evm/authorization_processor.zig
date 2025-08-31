//! EIP-7702 Authorization Processing
//!
//! This module handles the processing of authorization lists for EIP-7702
//! delegated EOA transactions. It validates authorizations, updates account
//! delegations, and manages gas costs.

const std = @import("std");
const primitives = @import("primitives");
const Address = primitives.Address.Address;
const Authorization = primitives.Authorization.Authorization;
const EMPTY_CODE_HASH = primitives.EMPTY_CODE_HASH;
const Database = @import("database.zig").Database;
const Account = @import("database_interface_account.zig").Account;
const log = @import("log.zig");
const Eips = @import("eips.zig").Eips;

pub const AuthorizationError = error{
    InvalidChainId,
    NonceMismatch,
    NotEOA,
    InvalidSignature,
    AccountNotFound,
    DatabaseError,
    OutOfGas,
};

/// Result of processing a single authorization
pub const AuthorizationResult = struct {
    success: bool,
    error_type: ?AuthorizationError = null,
    gas_used: i64 = 0,
};

/// Results of processing an authorization list
pub const AuthorizationListResult = struct {
    results: []AuthorizationResult,
    total_gas_used: i64,
    successful_count: u32,
    failed_count: u32,
    
    pub fn deinit(self: *AuthorizationListResult, allocator: std.mem.Allocator) void {
        allocator.free(self.results);
    }
};

/// Authorization processor for EIP-7702
///
/// Thread Safety: This processor is designed for single-threaded use.
/// The `gas_remaining` pointer must not be accessed concurrently from
/// multiple threads. Callers must ensure exclusive access during the
/// lifetime of any authorization processing operations.
pub const AuthorizationProcessor = struct {
    /// Database for state access
    db: *Database,
    /// Current chain ID
    chain_id: u64,
    /// Gas tracking (single-threaded access only)
    gas_remaining: *i64,
    /// EIP configuration for hardfork-specific behavior
    eips: Eips,
    
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
        if (!std.mem.eql(u8, &account.code_hash, &EMPTY_CODE_HASH)) {
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
    
    /// Process an authorization list with detailed results
    pub fn processAuthorizationListWithResults(
        self: *AuthorizationProcessor,
        allocator: std.mem.Allocator,
        auth_list: []const Authorization,
    ) AuthorizationError!AuthorizationListResult {
        var results = try allocator.alloc(AuthorizationResult, auth_list.len);
        var total_gas_used: i64 = 0;
        var successful_count: u32 = 0;
        var failed_count: u32 = 0;
        
        for (auth_list, 0..) |auth, i| {
            const gas_cost = self.calculateAuthorizationGasCost(auth) catch |err| {
                results[i] = AuthorizationResult{
                    .success = false,
                    .error_type = err,
                    .gas_used = 0,
                };
                failed_count += 1;
                continue;
            };
            
            // Check gas before processing
            if (self.gas_remaining.* < gas_cost) {
                results[i] = AuthorizationResult{
                    .success = false,
                    .error_type = AuthorizationError.OutOfGas,
                    .gas_used = 0,
                };
                failed_count += 1;
                return AuthorizationError.OutOfGas;
            }
            
            // Validate authorization
            auth.validate() catch |err| {
                log.debug("Authorization validation failed: {}", .{err});
                results[i] = AuthorizationResult{
                    .success = false,
                    .error_type = AuthorizationError.InvalidSignature,
                    .gas_used = 0,
                };
                failed_count += 1;
                continue;
            };
            
            // Recover authority (signer)
            const authority = auth.authority() catch |err| {
                log.debug("Failed to recover authority: {}", .{err});
                results[i] = AuthorizationResult{
                    .success = false,
                    .error_type = AuthorizationError.InvalidSignature,
                    .gas_used = 0,
                };
                failed_count += 1;
                continue;
            };
            
            // Consume gas
            self.gas_remaining.* -= gas_cost;
            total_gas_used += gas_cost;
            
            // Process the authorization
            self.processAuthorization(auth, authority) catch |err| {
                log.debug("Failed to process authorization: {}", .{err});
                results[i] = AuthorizationResult{
                    .success = false,
                    .error_type = err,
                    .gas_used = gas_cost,
                };
                failed_count += 1;
                continue;
            };
            
            results[i] = AuthorizationResult{
                .success = true,
                .error_type = null,
                .gas_used = gas_cost,
            };
            successful_count += 1;
        }
        
        return AuthorizationListResult{
            .results = results,
            .total_gas_used = total_gas_used,
            .successful_count = successful_count,
            .failed_count = failed_count,
        };
    }
    
    /// Process an authorization list (simplified interface, maintains backward compatibility)
    pub fn processAuthorizationList(
        self: *AuthorizationProcessor,
        auth_list: []const Authorization,
    ) AuthorizationError!void {
        // Gas costs per EIP-7702 (configurable via hardfork)
        // TODO: Implement gas cost calculation once gas metering is integrated
        _ = self.eips.eip_7702_per_auth_base_cost();
        _ = self.eips.eip_7702_per_empty_account_cost();
        
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
            
            // Calculate gas cost
            const gas_cost = self.calculateAuthorizationGasCost(auth) catch {
                continue;
            };
            
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
    
    /// Calculate gas cost for a single authorization
    fn calculateAuthorizationGasCost(self: *AuthorizationProcessor, auth: Authorization) !i64 {
        // Recover authority to check account state
        const authority = try auth.authority();
        
        // Check if account is empty (for gas calculation)
        const account_opt = try self.db.get_account(authority.bytes);
        
        // Gas costs per EIP-7702 (configurable via hardfork)
        const PER_AUTH_BASE_COST = self.eips.eip_7702_per_auth_base_cost();
        const PER_EMPTY_ACCOUNT_COST = self.eips.eip_7702_per_empty_account_cost();
        
        var gas_cost: i64 = PER_AUTH_BASE_COST;
        if (account_opt == null or account_opt.?.is_empty()) {
            gas_cost += PER_EMPTY_ACCOUNT_COST;
        }
        
        return gas_cost;
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
    const eips = Eips{ .hardfork = @import("hardfork.zig").Hardfork.PRAGUE };
    var processor = AuthorizationProcessor{
        .db = &db,
        .chain_id = 1,
        .gas_remaining = &gas_remaining,
        .eips = eips,
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
    const eips = Eips{ .hardfork = @import("hardfork.zig").Hardfork.PRAGUE };
    var processor = AuthorizationProcessor{
        .db = &db,
        .chain_id = 1,
        .gas_remaining = &gas_remaining,
        .eips = eips,
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