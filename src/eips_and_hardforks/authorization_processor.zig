//! EIP-7702 Authorization Processing
//!
//! Applies a set-code transaction's authorization list exactly like execution-specs
//! Prague `set_delegation` (src/ethereum/prague/vm/eoa_delegation.py). For each tuple:
//!
//!   1. chain_id must be 0 or the current chain id
//!   2. nonce must be < 2**64 - 1
//!   3. recover the authority: y_parity in {0, 1}, 0 < r < n, 0 < s <= n / 2
//!   4. (caller) add the authority to accessed_addresses
//!   5. the authority's code must be empty or a delegation designator
//!   6. the authority's nonce must equal the tuple nonce
//!   7. refund PER_EMPTY_ACCOUNT_COST - PER_AUTH_BASE_COST if the authority exists
//!   8. set code to 0xef0100 || address, or to empty code when address is zero
//!   9. increment the authority's nonce
//!
//! A tuple failing 1, 2, 3, 5 or 6 is skipped; it never aborts the transaction.
//! Database errors and allocation failures propagate.
//!
//! Gas: every tuple costs PER_EMPTY_ACCOUNT_COST intrinsic gas whether or not it is
//! valid. The list functions charge that up front from `gas_remaining`; the refund
//! for already-existing authorities is returned separately because the spec adds it
//! to the transaction's refund counter, which is subject to the end-of-transaction
//! refund cap.
//!
//! Domain model: a delegation is stored as `Account.delegated_address` with an empty
//! code hash (see database_interface_account.zig). An authority whose stored code is
//! a raw 23-byte designator is normalized into that form when re-delegated.

const std = @import("std");
const primitives = @import("voltaire");
const Address = primitives.Address.Address;
const Authorization = primitives.Authorization.Authorization;
const EMPTY_CODE_HASH = primitives.EMPTY_CODE_HASH;
const Database = @import("../storage/database.zig").Database;
const Account = @import("../storage/database_interface_account.zig").Account;
const log = @import("../log.zig");
const Eips = @import("eips.zig").Eips;

/// secp256k1 group order n
const SECP256K1N: u256 = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

/// Reasons a tuple is invalid. EIP-7702 skips such tuples.
pub const TupleError = error{
    /// chain_id is neither 0 nor the current chain id
    InvalidChainId,
    /// nonce == 2**64 - 1
    NonceOverflow,
    /// y_parity, r or s out of range, or public key recovery failed
    InvalidSignature,
    /// the authority has code that is not a delegation designator
    NotEOA,
    /// the authority's nonce differs from the tuple nonce
    NonceMismatch,
};

/// Every error the processor can return. Database errors are propagated unchanged.
pub const AuthorizationError = TupleError || error{
    /// gas_remaining cannot cover the authorization list's intrinsic cost
    OutOfGas,
    /// The configured fork is before Prague: EIP-7702 does not exist, and a
    /// transaction that carries authorizations is invalid. Nothing was applied.
    AuthorizationsNotActive,
} || Database.Error;

/// Result of processing a single authorization
pub const AuthorizationResult = struct {
    success: bool,
    /// Why the tuple was skipped; null when applied.
    error_type: ?TupleError = null,
    /// Intrinsic gas charged for this tuple (PER_EMPTY_ACCOUNT_COST).
    gas_used: i64 = 0,
    /// Recovered authority, set whenever signature recovery succeeded (even if the
    /// tuple was later skipped). The caller must add it to accessed_addresses.
    authority: ?Address = null,
    /// Refund earned by this tuple (nonzero only if applied to an existing account).
    refund: i64 = 0,
};

/// Results of processing an authorization list
pub const AuthorizationListResult = struct {
    results: []AuthorizationResult,
    total_gas_used: i64,
    successful_count: u32,
    failed_count: u32,
    /// Sum of per-tuple refunds; add to the transaction refund counter.
    refund: i64 = 0,

    pub fn deinit(self: *AuthorizationListResult, allocator: std.mem.Allocator) void {
        allocator.free(self.results);
    }
};

/// True when `code_hash` denotes an account without code.
fn isNoCodeHash(code_hash: [32]u8) bool {
    return std.mem.eql(u8, &code_hash, &@as([32]u8, @splat(0))) or
        std.mem.eql(u8, &code_hash, &EMPTY_CODE_HASH);
}

/// True when `code` is exactly 0xef0100 || address (execution-specs `is_valid_delegation`).
pub fn isDelegationDesignator(code: []const u8) bool {
    return code.len == 23 and code[0] == 0xef and code[1] == 0x01 and code[2] == 0x00;
}

/// Steps 1-2: checks that need no state.
fn checkTupleFields(chain_id: u64, auth: Authorization) TupleError!void {
    if (auth.chain_id != 0 and auth.chain_id != chain_id) {
        log.debug("Authorization chain ID mismatch: expected {} (or 0), got {}", .{ chain_id, auth.chain_id });
        return TupleError.InvalidChainId;
    }
    if (auth.nonce == std.math.maxInt(u64)) return TupleError.NonceOverflow;
}

/// Step 3: execution-specs `recover_authority`. `auth.v` is the tuple's y_parity.
fn recoverAuthority(auth: Authorization) (TupleError || error{OutOfMemory})!Address {
    if (auth.v > 1) return TupleError.InvalidSignature;
    const r = std.mem.readInt(u256, &auth.r, .big);
    const s = std.mem.readInt(u256, &auth.s, .big);
    if (r == 0 or r >= SECP256K1N) return TupleError.InvalidSignature;
    if (s == 0 or s > SECP256K1N / 2) return TupleError.InvalidSignature;
    return auth.authority() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            log.debug("Failed to recover authority: {}", .{err});
            return TupleError.InvalidSignature;
        },
    };
}

/// Authorization processor for EIP-7702
///
/// Thread Safety: This processor is designed for single-threaded use.
/// The `gas_remaining` pointer must not be accessed concurrently from
/// multiple threads. Callers must ensure exclusive access during the
/// lifetime of any authorization processing operations.
pub const AuthorizationProcessor = AuthorizationProcessorFor(Database);

pub fn AuthorizationProcessorFor(comptime DbType: type) type {
    return struct {
        const Self = @This();
        /// Database for state access
        db: *DbType,
        /// Current chain ID
        chain_id: u64,
        /// Gas tracking (single-threaded access only)
        gas_remaining: *i64,
        /// EIP configuration for hardfork-specific behavior
        eips: Eips,

        /// EIP-7702 exists from Prague on. Before it no tuple may change state: a set-code
        /// transaction is invalid there, so applying its list would write delegations
        /// that the fork's own rules treat as ordinary code. An empty list changes
        /// nothing on any fork and is not an error.
        fn requireActive(self: *const Self, tuple_count: usize) error{AuthorizationsNotActive}!void {
            if (tuple_count == 0) return;
            if (!self.eips.is_eip_active(7702)) return error.AuthorizationsNotActive;
        }

        /// Apply one tuple whose authority is already known (steps 1-2 and 5-9).
        /// Returns a TupleError when the spec would skip the tuple; state is then unchanged.
        pub fn processAuthorization(
            self: *Self,
            auth: Authorization,
            authority: Address,
        ) AuthorizationError!void {
            try self.requireActive(1);
            try checkTupleFields(self.chain_id, auth);
            _ = try self.applyAuthorization(auth, authority);
        }

        /// Steps 5-9. Returns whether the authority account existed before.
        ///
        /// "Existed" is EIP-7702's "authority exists in the trie", which decides the
        /// refund. It agrees with EIP-161 because the transaction processor deletes
        /// every touched empty account when a transaction ends: an account that is
        /// still in the database was either never emptied or never touched, and the
        /// trie holds it. An authority left without nonce, balance or code is not
        /// possible here: applying a tuple always raises the nonce.
        fn applyAuthorization(
            self: *Self,
            auth: Authorization,
            authority: Address,
        ) (error{ NotEOA, NonceMismatch, NonceOverflow } || Database.Error)!bool {
            const existing = try self.db.get_account(authority.bytes);
            // A missing authority is an empty account (nonce 0, no code) and is created.
            var account = existing orelse Account.zero();

            if (!isNoCodeHash(account.code_hash)) {
                const code = try self.db.get_code(account.code_hash);
                if (!isDelegationDesignator(code)) {
                    log.debug("Authority {x} has non-delegation code", .{authority.bytes});
                    return error.NotEOA;
                }
                // Normalize a raw designator into the delegated_address representation.
                account.code_hash = EMPTY_CODE_HASH;
            }

            if (account.nonce != auth.nonce) {
                log.debug("Authorization nonce mismatch: expected {}, got {}", .{ account.nonce, auth.nonce });
                return error.NonceMismatch;
            }
            const next_nonce = std.math.add(u64, account.nonce, 1) catch return error.NonceOverflow;

            account.delegated_address = if (auth.address.isZero()) null else auth.address;
            account.nonce = next_nonce;
            try self.db.set_account(authority.bytes, account);

            log.debug("Set delegation for {x} to {x}", .{ authority.bytes, auth.address.bytes });
            return existing != null;
        }
        /// Steps 1-9 for one tuple, including signature recovery.
        fn processTuple(
            self: *Self,
            auth: Authorization,
            per_tuple_cost: i64,
            refund_per_existing: i64,
        ) AuthorizationError!AuthorizationResult {
            var result = AuthorizationResult{ .success = false, .gas_used = per_tuple_cost };
            checkTupleFields(self.chain_id, auth) catch |err| {
                result.error_type = err;
                return result;
            };
            const authority = recoverAuthority(auth) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => |tuple_err| {
                    result.error_type = tuple_err;
                    return result;
                },
            };
            result.authority = authority;
            const existed = self.applyAuthorization(auth, authority) catch |err| switch (err) {
                error.NotEOA, error.NonceMismatch, error.NonceOverflow => |tuple_err| {
                    result.error_type = tuple_err;
                    return result;
                },
                else => |db_err| return db_err,
            };
            result.success = true;
            if (existed) result.refund = refund_per_existing;
            return result;
        }

        /// Intrinsic cost of `n` tuples, or OutOfGas if it cannot be represented.
        fn listCost(self: *Self, n: usize) AuthorizationError!i64 {
            const count = std.math.cast(i64, n) orelse return error.OutOfGas;
            return std.math.mul(i64, self.eips.eip_7702_per_empty_account_cost(), count) catch return error.OutOfGas;
        }

        /// Process an authorization list with per-tuple results.
        /// Charges len * PER_EMPTY_ACCOUNT_COST from gas_remaining after all tuples were
        /// processed. Returns OutOfGas, with no state or gas change, when gas_remaining
        /// cannot cover that cost. The caller owns the returned results.
        pub fn processAuthorizationListWithResults(
            self: *Self,
            allocator: std.mem.Allocator,
            auth_list: []const Authorization,
        ) AuthorizationError!AuthorizationListResult {
            try self.requireActive(auth_list.len);
            const total_cost = try self.listCost(auth_list.len);
            if (self.gas_remaining.* < total_cost) return error.OutOfGas;
            const per_tuple = self.eips.eip_7702_per_empty_account_cost();
            const refund_per = per_tuple - self.eips.eip_7702_per_auth_base_cost();

            const results = try allocator.alloc(AuthorizationResult, auth_list.len);
            errdefer allocator.free(results);

            var successful_count: u32 = 0;
            var failed_count: u32 = 0;
            var refund: i64 = 0;
            for (auth_list, results) |auth, *slot| {
                slot.* = try self.processTuple(auth, per_tuple, refund_per);
                if (slot.success) {
                    successful_count += 1;
                    refund += slot.refund;
                } else {
                    failed_count += 1;
                }
            }

            self.gas_remaining.* -= total_cost;
            return AuthorizationListResult{
                .results = results,
                .total_gas_used = total_cost,
                .successful_count = successful_count,
                .failed_count = failed_count,
                .refund = refund,
            };
        }

        /// Process an authorization list. Same semantics as
        /// processAuthorizationListWithResults; returns the total refund.
        pub fn processAuthorizationList(
            self: *Self,
            auth_list: []const Authorization,
        ) AuthorizationError!i64 {
            try self.requireActive(auth_list.len);
            const total_cost = try self.listCost(auth_list.len);
            if (self.gas_remaining.* < total_cost) return error.OutOfGas;
            const per_tuple = self.eips.eip_7702_per_empty_account_cost();
            const refund_per = per_tuple - self.eips.eip_7702_per_auth_base_cost();

            var refund: i64 = 0;
            for (auth_list) |auth| {
                const result = try self.processTuple(auth, per_tuple, refund_per);
                refund += result.refund;
            }
            self.gas_remaining.* -= total_cost;
            return refund;
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
            if (!isDelegationDesignator(designator)) return AuthorizationError.InvalidSignature;
            return Address{ .bytes = designator[3..23].* };
        }
    };
}

test "Authorization processor - basic delegation" {
    const testing = std.testing;
    var db = Database.init(testing.allocator);
    defer db.deinit();

    const eoa_address = try Address.fromHex("0x1111111111111111111111111111111111111111");
    var eoa_account = Account.zero();
    eoa_account.balance = 1_000_000_000_000_000_000;
    eoa_account.nonce = 5;
    try db.set_account(eoa_address.bytes, eoa_account);

    const auth = Authorization{
        .chain_id = 1,
        .address = try Address.fromHex("0x2222222222222222222222222222222222222222"),
        .nonce = 5,
        .v = 0,
        .r = @as([32]u8, @splat(0x12)),
        .s = @as([32]u8, @splat(0x34)),
    };

    var gas_remaining: i64 = 100_000;
    var processor = AuthorizationProcessor{ .db = &db, .chain_id = 1, .gas_remaining = &gas_remaining, .eips = Eips{ .hardfork = .PRAGUE } };
    try processor.processAuthorization(auth, eoa_address);

    const updated = (try db.get_account(eoa_address.bytes)).?;
    try testing.expect(updated.has_delegation());
    try testing.expectEqual(auth.address, updated.get_effective_code_address().?);
    try testing.expectEqual(@as(u64, 6), updated.nonce);
}

test "Authorization processor - EMPTY_CODE_HASH authority is accepted" {
    const testing = std.testing;
    var db = Database.init(testing.allocator);
    defer db.deinit();

    const eoa_address = try Address.fromHex("0x1111111111111111111111111111111111111111");
    var eoa_account = Account.zero();
    eoa_account.code_hash = EMPTY_CODE_HASH;
    eoa_account.nonce = 3;
    try db.set_account(eoa_address.bytes, eoa_account);

    const auth = Authorization{ .chain_id = 0, .address = try Address.fromHex("0x2222222222222222222222222222222222222222"), .nonce = 3, .v = 0, .r = @as([32]u8, @splat(0x12)), .s = @as([32]u8, @splat(0x34)) };

    var gas_remaining: i64 = 100_000;
    var processor = AuthorizationProcessor{ .db = &db, .chain_id = 1, .gas_remaining = &gas_remaining, .eips = Eips{ .hardfork = .PRAGUE } };
    try processor.processAuthorization(auth, eoa_address);

    const updated = (try db.get_account(eoa_address.bytes)).?;
    try testing.expectEqual(auth.address, updated.get_effective_code_address().?);
    try testing.expectEqual(@as(u64, 4), updated.nonce);
}

test "Authorization processor - missing authority is materialized with nonce 1" {
    const testing = std.testing;
    var db = Database.init(testing.allocator);
    defer db.deinit();

    const missing = try Address.fromHex("0x1111111111111111111111111111111111111111");
    const auth = Authorization{ .chain_id = 1, .address = try Address.fromHex("0x2222222222222222222222222222222222222222"), .nonce = 0, .v = 0, .r = @as([32]u8, @splat(0x12)), .s = @as([32]u8, @splat(0x34)) };

    var gas_remaining: i64 = 100_000;
    var processor = AuthorizationProcessor{ .db = &db, .chain_id = 1, .gas_remaining = &gas_remaining, .eips = Eips{ .hardfork = .PRAGUE } };
    try processor.processAuthorization(auth, missing);

    const created = (try db.get_account(missing.bytes)).?;
    try testing.expectEqual(@as(u64, 1), created.nonce);
    try testing.expectEqual(@as(u256, 0), created.balance);
    try testing.expectEqual(auth.address, created.get_effective_code_address().?);
}

test "Authorization processor - missing authority with nonzero tuple nonce is skipped" {
    const testing = std.testing;
    var db = Database.init(testing.allocator);
    defer db.deinit();

    const missing = try Address.fromHex("0x1111111111111111111111111111111111111111");
    const auth = Authorization{ .chain_id = 1, .address = try Address.fromHex("0x2222222222222222222222222222222222222222"), .nonce = 5, .v = 0, .r = @as([32]u8, @splat(0x12)), .s = @as([32]u8, @splat(0x34)) };

    var gas_remaining: i64 = 100_000;
    var processor = AuthorizationProcessor{ .db = &db, .chain_id = 1, .gas_remaining = &gas_remaining, .eips = Eips{ .hardfork = .PRAGUE } };
    try testing.expectError(AuthorizationError.NonceMismatch, processor.processAuthorization(auth, missing));
    try testing.expect((try db.get_account(missing.bytes)) == null);
}

test "Authorization processor - wrong nonce rejected" {
    const testing = std.testing;
    var db = Database.init(testing.allocator);
    defer db.deinit();

    const eoa_address = try Address.fromHex("0x1111111111111111111111111111111111111111");
    var eoa_account = Account.zero();
    eoa_account.nonce = 5;
    try db.set_account(eoa_address.bytes, eoa_account);

    const auth = Authorization{ .chain_id = 1, .address = try Address.fromHex("0x2222222222222222222222222222222222222222"), .nonce = 10, .v = 0, .r = @as([32]u8, @splat(0x12)), .s = @as([32]u8, @splat(0x34)) };

    var gas_remaining: i64 = 100_000;
    var processor = AuthorizationProcessor{ .db = &db, .chain_id = 1, .gas_remaining = &gas_remaining, .eips = Eips{ .hardfork = .PRAGUE } };
    try testing.expectError(AuthorizationError.NonceMismatch, processor.processAuthorization(auth, eoa_address));
    try testing.expectEqual(@as(u64, 5), (try db.get_account(eoa_address.bytes)).?.nonce);
}

test "Authorization processor - max nonce tuple is skipped without overflow" {
    const testing = std.testing;
    var db = Database.init(testing.allocator);
    defer db.deinit();

    const eoa_address = try Address.fromHex("0x1111111111111111111111111111111111111111");
    var eoa_account = Account.zero();
    eoa_account.nonce = std.math.maxInt(u64);
    const delegate_addr = try Address.fromHex("0x2222222222222222222222222222222222222222");
    eoa_account.set_delegation(delegate_addr);
    try db.set_account(eoa_address.bytes, eoa_account);

    const auth = Authorization{ .chain_id = 1, .address = try Address.fromHex("0x3333333333333333333333333333333333333333"), .nonce = std.math.maxInt(u64), .v = 0, .r = @as([32]u8, @splat(0x12)), .s = @as([32]u8, @splat(0x34)) };

    var gas_remaining: i64 = 100_000;
    var processor = AuthorizationProcessor{ .db = &db, .chain_id = 1, .gas_remaining = &gas_remaining, .eips = Eips{ .hardfork = .PRAGUE } };
    try testing.expectError(AuthorizationError.NonceOverflow, processor.processAuthorization(auth, eoa_address));

    const after = (try db.get_account(eoa_address.bytes)).?;
    try testing.expectEqual(delegate_addr, after.get_effective_code_address().?);
    try testing.expectEqual(@as(u64, std.math.maxInt(u64)), after.nonce);
}

test "Authorization processor - zero address clears delegation and increments nonce" {
    const testing = std.testing;
    var db = Database.init(testing.allocator);
    defer db.deinit();

    const eoa_address = try Address.fromHex("0x1111111111111111111111111111111111111111");
    var eoa_account = Account.zero();
    eoa_account.nonce = 5;
    eoa_account.set_delegation(try Address.fromHex("0x2222222222222222222222222222222222222222"));
    try db.set_account(eoa_address.bytes, eoa_account);

    const auth = Authorization{ .chain_id = 1, .address = Address.ZERO, .nonce = 5, .v = 0, .r = @as([32]u8, @splat(0x12)), .s = @as([32]u8, @splat(0x34)) };

    var gas_remaining: i64 = 100_000;
    var processor = AuthorizationProcessor{ .db = &db, .chain_id = 1, .gas_remaining = &gas_remaining, .eips = Eips{ .hardfork = .PRAGUE } };
    try processor.processAuthorization(auth, eoa_address);

    const after = (try db.get_account(eoa_address.bytes)).?;
    try testing.expect(!after.has_delegation());
    try testing.expect(after.get_effective_code_address() == null);
    try testing.expectEqual(@as(u64, 6), after.nonce);
    try testing.expectEqualSlices(u8, &[_]u8{}, try db.get_code_by_address(eoa_address.bytes));
}

test "Authorization processor - delegation designator format" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const delegate_address = try Address.fromHex("0x1234567890123456789012345678901234567890");
    const designator = try AuthorizationProcessor.createDelegationDesignator(allocator, delegate_address);
    defer allocator.free(designator);

    try testing.expectEqual(@as(usize, 23), designator.len);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xef, 0x01, 0x00 }, designator[0..3]);
    try testing.expectEqualSlices(u8, &delegate_address.bytes, designator[3..23]);
    try testing.expectEqual(delegate_address, try AuthorizationProcessor.parseDelegationDesignator(designator));

    const short = [_]u8{ 0xef, 0x01, 0x00, 0x12, 0x34 };
    try testing.expectError(AuthorizationError.InvalidSignature, AuthorizationProcessor.parseDelegationDesignator(&short));
    const bad_prefix = [_]u8{ 0xff, 0x01, 0x00 } ++ @as([20]u8, @splat(0x12));
    try testing.expectError(AuthorizationError.InvalidSignature, AuthorizationProcessor.parseDelegationDesignator(&bad_prefix));
}

test "Authorization processor - wrong chain ID rejected, zero chain ID accepted" {
    const testing = std.testing;
    var db = Database.init(testing.allocator);
    defer db.deinit();

    const eoa_address = try Address.fromHex("0x1111111111111111111111111111111111111111");
    var eoa_account = Account.zero();
    eoa_account.nonce = 5;
    try db.set_account(eoa_address.bytes, eoa_account);

    var gas_remaining: i64 = 100_000;
    var processor = AuthorizationProcessor{ .db = &db, .chain_id = 1, .gas_remaining = &gas_remaining, .eips = Eips{ .hardfork = .PRAGUE } };

    const wrong = Authorization{ .chain_id = 999, .address = try Address.fromHex("0x2222222222222222222222222222222222222222"), .nonce = 5, .v = 0, .r = @as([32]u8, @splat(0x12)), .s = @as([32]u8, @splat(0x34)) };
    try testing.expectError(AuthorizationError.InvalidChainId, processor.processAuthorization(wrong, eoa_address));

    var any_chain = wrong;
    any_chain.chain_id = 0;
    try processor.processAuthorization(any_chain, eoa_address);
    try testing.expectEqual(@as(u64, 6), (try db.get_account(eoa_address.bytes)).?.nonce);
}

test "Authorization processor - contract account rejected" {
    const testing = std.testing;
    var db = Database.init(testing.allocator);
    defer db.deinit();

    const contract_address = try Address.fromHex("0x1111111111111111111111111111111111111111");
    var contract_account = Account.zero();
    contract_account.nonce = 5;
    contract_account.code_hash = try db.set_code(&[_]u8{ 0x60, 0x00, 0x00 });
    try db.set_account(contract_address.bytes, contract_account);

    const auth = Authorization{ .chain_id = 1, .address = try Address.fromHex("0x2222222222222222222222222222222222222222"), .nonce = 5, .v = 0, .r = @as([32]u8, @splat(0x12)), .s = @as([32]u8, @splat(0x34)) };

    var gas_remaining: i64 = 100_000;
    var processor = AuthorizationProcessor{ .db = &db, .chain_id = 1, .gas_remaining = &gas_remaining, .eips = Eips{ .hardfork = .PRAGUE } };
    try testing.expectError(AuthorizationError.NotEOA, processor.processAuthorization(auth, contract_address));
    try testing.expectEqual(@as(u64, 5), (try db.get_account(contract_address.bytes)).?.nonce);
}

test "Authorization processor - raw designator code is accepted and normalized" {
    const testing = std.testing;
    var db = Database.init(testing.allocator);
    defer db.deinit();

    const eoa_address = try Address.fromHex("0x1111111111111111111111111111111111111111");
    const old_target = try Address.fromHex("0x2222222222222222222222222222222222222222");
    const designator = [_]u8{ 0xef, 0x01, 0x00 } ++ old_target.bytes;
    var eoa_account = Account.zero();
    eoa_account.nonce = 2;
    eoa_account.code_hash = try db.set_code(&designator);
    try db.set_account(eoa_address.bytes, eoa_account);

    const new_target = try Address.fromHex("0x3333333333333333333333333333333333333333");
    const auth = Authorization{ .chain_id = 1, .address = new_target, .nonce = 2, .v = 0, .r = @as([32]u8, @splat(0x12)), .s = @as([32]u8, @splat(0x34)) };

    var gas_remaining: i64 = 100_000;
    var processor = AuthorizationProcessor{ .db = &db, .chain_id = 1, .gas_remaining = &gas_remaining, .eips = Eips{ .hardfork = .PRAGUE } };
    try processor.processAuthorization(auth, eoa_address);

    const after = (try db.get_account(eoa_address.bytes)).?;
    try testing.expectEqualSlices(u8, &EMPTY_CODE_HASH, &after.code_hash);
    try testing.expectEqual(new_target, after.get_effective_code_address().?);
    try testing.expectEqual(@as(u64, 3), after.nonce);
}

test "Authorization processor - missing code for a code hash propagates" {
    const testing = std.testing;
    var db = Database.init(testing.allocator);
    defer db.deinit();

    const eoa_address = try Address.fromHex("0x1111111111111111111111111111111111111111");
    var eoa_account = Account.zero();
    eoa_account.code_hash = @as([32]u8, @splat(0x42)); // no code stored under this hash
    try db.set_account(eoa_address.bytes, eoa_account);

    const auth = Authorization{ .chain_id = 1, .address = try Address.fromHex("0x2222222222222222222222222222222222222222"), .nonce = 0, .v = 0, .r = @as([32]u8, @splat(0x12)), .s = @as([32]u8, @splat(0x34)) };

    var gas_remaining: i64 = 100_000;
    var processor = AuthorizationProcessor{ .db = &db, .chain_id = 1, .gas_remaining = &gas_remaining, .eips = Eips{ .hardfork = .PRAGUE } };
    try testing.expectError(AuthorizationError.CodeNotFound, processor.processAuthorization(auth, eoa_address));
}

test "Authorization processor - list applies signed tuples, skips invalid ones, refunds existing" {
    const testing = std.testing;
    const crypto = @import("crypto").Crypto;
    var db = Database.init(testing.allocator);
    defer db.deinit();

    const key_existing: crypto.PrivateKey = @as([32]u8, @splat(0x42));
    const key_new: crypto.PrivateKey = @as([32]u8, @splat(0x43));
    const authority_existing = (try crypto.unaudited_getPublicKey(key_existing)).toAddress();
    const authority_new = (try crypto.unaudited_getPublicKey(key_new)).toAddress();

    var existing_account = Account.zero();
    existing_account.nonce = 7;
    try db.set_account(authority_existing.bytes, existing_account);

    const target = try Address.fromHex("0x2222222222222222222222222222222222222222");
    var auth_existing = try primitives.Authorization.createAuthorization(testing.allocator, 1, target, 7, key_existing);
    auth_existing.v -= 27; // voltaire signs with v = 27 + y_parity; the tuple carries y_parity
    var auth_new = try primitives.Authorization.createAuthorization(testing.allocator, 0, target, 0, key_new);
    auth_new.v -= 27;
    var auth_bad_parity = auth_new;
    auth_bad_parity.v = 27;
    var auth_wrong_chain = auth_existing;
    auth_wrong_chain.chain_id = 999;

    const list = [_]Authorization{ auth_existing, auth_bad_parity, auth_wrong_chain, auth_new };

    var gas_remaining: i64 = 1_000_000;
    const eips = Eips{ .hardfork = .PRAGUE };
    var processor = AuthorizationProcessor{ .db = &db, .chain_id = 1, .gas_remaining = &gas_remaining, .eips = eips };
    var result = try processor.processAuthorizationListWithResults(testing.allocator, &list);
    defer result.deinit(testing.allocator);

    const per_tuple = eips.eip_7702_per_empty_account_cost();
    try testing.expectEqual(@as(u32, 2), result.successful_count);
    try testing.expectEqual(@as(u32, 2), result.failed_count);
    try testing.expectEqual(per_tuple * 4, result.total_gas_used);
    try testing.expectEqual(1_000_000 - per_tuple * 4, gas_remaining);
    try testing.expectEqual(per_tuple - eips.eip_7702_per_auth_base_cost(), result.refund);

    try testing.expect(result.results[0].success);
    try testing.expectEqual(authority_existing, result.results[0].authority.?);
    try testing.expectEqual(TupleError.InvalidSignature, result.results[1].error_type.?);
    try testing.expect(result.results[1].authority == null);
    try testing.expectEqual(TupleError.InvalidChainId, result.results[2].error_type.?);
    try testing.expect(result.results[3].success);
    try testing.expectEqual(@as(i64, 0), result.results[3].refund);

    const updated_existing = (try db.get_account(authority_existing.bytes)).?;
    try testing.expectEqual(@as(u64, 8), updated_existing.nonce);
    try testing.expectEqual(target, updated_existing.get_effective_code_address().?);
    const created = (try db.get_account(authority_new.bytes)).?;
    try testing.expectEqual(@as(u64, 1), created.nonce);
    try testing.expectEqual(target, created.get_effective_code_address().?);
}

test "Authorization processor - signature range checks" {
    const testing = std.testing;
    const crypto = @import("crypto").Crypto;
    var db = Database.init(testing.allocator);
    defer db.deinit();

    const key: crypto.PrivateKey = @as([32]u8, @splat(0x42));
    const target = try Address.fromHex("0x2222222222222222222222222222222222222222");
    var good = try primitives.Authorization.createAuthorization(testing.allocator, 1, target, 0, key);
    good.v -= 27;

    var zero_r = good;
    zero_r.r = @as([32]u8, @splat(0));
    var high_s = good;
    std.mem.writeInt(u256, &high_s.s, SECP256K1N / 2 + 1, .big);
    var r_at_n = good;
    std.mem.writeInt(u256, &r_at_n.r, SECP256K1N, .big);

    const list = [_]Authorization{ zero_r, high_s, r_at_n };
    var gas_remaining: i64 = 1_000_000;
    var processor = AuthorizationProcessor{ .db = &db, .chain_id = 1, .gas_remaining = &gas_remaining, .eips = Eips{ .hardfork = .PRAGUE } };
    var result = try processor.processAuthorizationListWithResults(testing.allocator, &list);
    defer result.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 3), result.failed_count);
    for (result.results) |entry| {
        try testing.expectEqual(TupleError.InvalidSignature, entry.error_type.?);
    }
}

test "Authorization processor - insufficient intrinsic gas changes nothing" {
    const testing = std.testing;
    const crypto = @import("crypto").Crypto;
    var db = Database.init(testing.allocator);
    defer db.deinit();

    const key: crypto.PrivateKey = @as([32]u8, @splat(0x42));
    const authority = (try crypto.unaudited_getPublicKey(key)).toAddress();
    var auth = try primitives.Authorization.createAuthorization(testing.allocator, 1, try Address.fromHex("0x2222222222222222222222222222222222222222"), 0, key);
    auth.v -= 27;
    const list = [_]Authorization{auth};

    const eips = Eips{ .hardfork = .PRAGUE };
    var gas_remaining: i64 = eips.eip_7702_per_empty_account_cost() - 1;
    var processor = AuthorizationProcessor{ .db = &db, .chain_id = 1, .gas_remaining = &gas_remaining, .eips = eips };

    try testing.expectError(AuthorizationError.OutOfGas, processor.processAuthorizationListWithResults(testing.allocator, &list));
    try testing.expectError(AuthorizationError.OutOfGas, processor.processAuthorizationList(&list));
    try testing.expectEqual(eips.eip_7702_per_empty_account_cost() - 1, gas_remaining);
    try testing.expect((try db.get_account(authority.bytes)) == null);
}

test "Authorization processor - processAuthorizationList returns refund and sequential nonces" {
    const testing = std.testing;
    const crypto = @import("crypto").Crypto;
    var db = Database.init(testing.allocator);
    defer db.deinit();

    const key: crypto.PrivateKey = @as([32]u8, @splat(0x42));
    const authority = (try crypto.unaudited_getPublicKey(key)).toAddress();
    const first_target = try Address.fromHex("0x2222222222222222222222222222222222222222");
    const second_target = try Address.fromHex("0x3333333333333333333333333333333333333333");
    var first = try primitives.Authorization.createAuthorization(testing.allocator, 1, first_target, 0, key);
    first.v -= 27;
    var second = try primitives.Authorization.createAuthorization(testing.allocator, 1, second_target, 1, key);
    second.v -= 27;
    const list = [_]Authorization{ first, second };

    const eips = Eips{ .hardfork = .PRAGUE };
    var gas_remaining: i64 = 1_000_000;
    var processor = AuthorizationProcessor{ .db = &db, .chain_id = 1, .gas_remaining = &gas_remaining, .eips = eips };
    const refund = try processor.processAuthorizationList(&list);

    // First tuple creates the account (no refund); second finds it existing (refund).
    try testing.expectEqual(eips.eip_7702_per_empty_account_cost() - eips.eip_7702_per_auth_base_cost(), refund);
    const after = (try db.get_account(authority.bytes)).?;
    try testing.expectEqual(@as(u64, 2), after.nonce);
    try testing.expectEqual(second_target, after.get_effective_code_address().?);
}

test "Authorization processor - no leak on any allocation failure" {
    const testing = std.testing;
    const crypto = @import("crypto").Crypto;

    const key: crypto.PrivateKey = @as([32]u8, @splat(0x42));
    var auth = try primitives.Authorization.createAuthorization(testing.allocator, 1, try Address.fromHex("0x2222222222222222222222222222222222222222"), 0, key);
    auth.v -= 27;
    const list = [_]Authorization{ auth, auth };

    var fail_index: usize = 0;
    var saw_success = false;
    while (fail_index < 64) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        const allocator = failing.allocator();
        var db = Database.init(allocator);
        defer db.deinit();

        var gas_remaining: i64 = 1_000_000;
        var processor = AuthorizationProcessor{ .db = &db, .chain_id = 1, .gas_remaining = &gas_remaining, .eips = Eips{ .hardfork = .PRAGUE } };
        if (processor.processAuthorizationListWithResults(allocator, &list)) |result_value| {
            var result = result_value;
            result.deinit(allocator);
            saw_success = true;
            break;
        } else |err| {
            try testing.expectEqual(AuthorizationError.OutOfMemory, err);
            try testing.expectEqual(@as(i64, 1_000_000), gas_remaining);
        }
    }
    try testing.expect(saw_success);
    try testing.expect(fail_index > 0);
}
