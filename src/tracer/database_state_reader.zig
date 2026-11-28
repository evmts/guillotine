//! Read-only bridge from the MinimalEvm sidecar to the production database.
//!
//! The tracer's sidecar keeps every write in its own maps. For state that existed
//! before the frame it mirrors (balances, nonces, code, storage) it reads through this
//! bridge, so both interpreters start from the same accounts. The bridge only calls
//! the database's read functions and never changes it.
//!
//! A read the database cannot complete returns zero (or empty code) to the sidecar
//! and is counted in `ReadContext`, where the tracer reports it as a failed check.
const std = @import("std");
const primitives = @import("voltaire");
const Address = primitives.Address.Address;
const Account = @import("../storage/database_interface_account.zig").Account;
const minimal_host = @import("minimal_host.zig");
pub const StateReader = minimal_host.StateReader;

/// Length of EIP-7702 designator code: `0xef0100 || address`.
pub const designator_len = 23;

/// State of one bridge. It must stay at a fixed address while a `StateReader`
/// created from it is in use.
pub const ReadContext = struct {
    /// The database read from, type-erased. Null until `DatabaseStateReader.reader`.
    database: ?*anyopaque = null,
    /// Number of database reads that returned an error.
    read_errors: u64 = 0,
    /// The error of the most recent failed read.
    last_error: ?anyerror = null,
    /// Backing bytes of the code last returned for an EIP-7702 delegated account.
    designator: [designator_len]u8 = @splat(0),

    fn recordError(self: *ReadContext, err: anyerror) void {
        self.read_errors +|= 1;
        self.last_error = err;
    }
};

/// `StateReader` implementation over a database of type `Db`, which provides
/// `get_account`, `get_code` and `get_storage` as `storage/database.zig` does.
pub fn DatabaseStateReader(comptime Db: type) type {
    return struct {
        const vtable = StateReader.VTable{
            .get_balance = getBalance,
            .get_nonce = getNonce,
            .get_code = getCode,
            .get_storage = getStorage,
            .account_exists = accountExists,
        };

        /// A reader of `database` that records failed reads in `context`.
        pub fn reader(context: *ReadContext, database: *Db) StateReader {
            context.database = database;
            return .{ .ptr = context, .vtable = &vtable };
        }

        fn contextOf(ptr: *anyopaque) *ReadContext {
            return @ptrCast(@alignCast(ptr));
        }

        fn databaseOf(context: *ReadContext) ?*Db {
            const erased = context.database orelse return null;
            return @ptrCast(@alignCast(erased));
        }

        /// The account at `address`, or null when it does not exist or cannot be read.
        fn accountOf(context: *ReadContext, address: Address) ?Account {
            const database = databaseOf(context) orelse return null;
            return database.get_account(address.bytes) catch |err| {
                context.recordError(err);
                return null;
            };
        }

        fn getBalance(ptr: *anyopaque, address: Address) u256 {
            const account = accountOf(contextOf(ptr), address) orelse return 0;
            return account.balance;
        }

        fn getNonce(ptr: *anyopaque, address: Address) u64 {
            const account = accountOf(contextOf(ptr), address) orelse return 0;
            return account.nonce;
        }

        /// The account's own code. A delegated account (EIP-7702) has the 23-byte
        /// designator `0xef0100 || delegate`, which is what EXTCODESIZE, EXTCODECOPY
        /// and EXTCODEHASH observe.
        fn getCode(ptr: *anyopaque, address: Address) []const u8 {
            const context = contextOf(ptr);
            const account = accountOf(context, address) orelse return &.{};
            if (account.delegated_address) |delegate| {
                context.designator[0..3].* = .{ 0xef, 0x01, 0x00 };
                context.designator[3..].* = delegate.bytes;
                return &context.designator;
            }
            if (!Account.is_code_hash_present(account.code_hash)) return &.{};
            const database = databaseOf(context) orelse return &.{};
            return database.get_code(account.code_hash) catch |err| {
                context.recordError(err);
                return &.{};
            };
        }

        fn getStorage(ptr: *anyopaque, address: Address, slot: u256) u256 {
            const context = contextOf(ptr);
            const database = databaseOf(context) orelse return 0;
            return database.get_storage(address.bytes, slot) catch |err| {
                context.recordError(err);
                return 0;
            };
        }

        fn accountExists(ptr: *anyopaque, address: Address) bool {
            return accountOf(contextOf(ptr), address) != null;
        }
    };
}

test "W3-1: DatabaseStateReader reads balance, nonce, code and storage without writing" {
    const Database = @import("../storage/database.zig").Database;
    var db = Database.init(std.testing.allocator);
    defer db.deinit();

    const address = Address{ .bytes = @as([20]u8, @splat(0x11)) };
    const code = [_]u8{ 0x60, 0x01, 0x00 };
    var account = Account.zero();
    account.balance = 1234;
    account.nonce = 7;
    account.code_hash = try db.set_code(&code);
    try db.set_account(address.bytes, account);
    try db.set_storage(address.bytes, 5, 99);
    const root_before = try db.get_state_root();

    var context = ReadContext{};
    const reader = DatabaseStateReader(Database).reader(&context, &db);
    try std.testing.expectEqual(@as(u256, 1234), reader.getBalance(address));
    try std.testing.expectEqual(@as(u64, 7), reader.getNonce(address));
    try std.testing.expectEqualSlices(u8, &code, reader.getCode(address));
    try std.testing.expectEqual(@as(u256, 99), reader.getStorage(address, 5));
    try std.testing.expectEqual(@as(u256, 0), reader.getStorage(address, 6));
    try std.testing.expect(reader.accountExists(address));

    const missing = Address{ .bytes = @as([20]u8, @splat(0x22)) };
    try std.testing.expectEqual(@as(u256, 0), reader.getBalance(missing));
    try std.testing.expectEqual(@as(usize, 0), reader.getCode(missing).len);
    try std.testing.expect(!reader.accountExists(missing));

    try std.testing.expectEqual(@as(u64, 0), context.read_errors);
    try std.testing.expect(!db.account_exists(missing.bytes));
    try std.testing.expectEqualSlices(u8, &root_before, &(try db.get_state_root()));
}

test "W3-1: DatabaseStateReader shows a delegated account's 23-byte designator" {
    const Database = @import("../storage/database.zig").Database;
    var db = Database.init(std.testing.allocator);
    defer db.deinit();

    const eoa = Address{ .bytes = @as([20]u8, @splat(0x33)) };
    const delegate = Address{ .bytes = @as([20]u8, @splat(0x44)) };
    try db.set_account(eoa.bytes, Account.zero());
    try db.set_delegation(eoa.bytes, delegate.bytes);

    var context = ReadContext{};
    const reader = DatabaseStateReader(Database).reader(&context, &db);
    const code = reader.getCode(eoa);
    try std.testing.expectEqual(@as(usize, designator_len), code.len);
    try std.testing.expectEqualSlices(u8, &.{ 0xef, 0x01, 0x00 }, code[0..3]);
    try std.testing.expectEqualSlices(u8, &delegate.bytes, code[3..]);
    try std.testing.expectEqual(@as(u64, 0), context.read_errors);
}

test "W3-1: DatabaseStateReader counts a failed read instead of hiding it" {
    const FailingDb = struct {
        pub fn get_account(_: *@This(), _: [20]u8) error{DatabaseCorrupted}!?Account {
            return error.DatabaseCorrupted;
        }
        pub fn get_code(_: *@This(), _: [32]u8) error{DatabaseCorrupted}![]const u8 {
            return error.DatabaseCorrupted;
        }
        pub fn get_storage(_: *@This(), _: [20]u8, _: u256) error{DatabaseCorrupted}!u256 {
            return error.DatabaseCorrupted;
        }
    };
    var db = FailingDb{};
    var context = ReadContext{};
    const reader = DatabaseStateReader(FailingDb).reader(&context, &db);
    const address = Address{ .bytes = @as([20]u8, @splat(0x55)) };

    try std.testing.expectEqual(@as(u256, 0), reader.getBalance(address));
    try std.testing.expectEqual(@as(u256, 0), reader.getStorage(address, 1));
    try std.testing.expectEqual(@as(u64, 2), context.read_errors);
    try std.testing.expectEqual(@as(?anyerror, error.DatabaseCorrupted), context.last_error);
}
