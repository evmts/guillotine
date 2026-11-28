/// EIP-4788: Beacon block root in the EVM
///
/// The beacon roots system contract stores parent beacon block roots in two ring
/// buffers of HISTORY_BUFFER_LENGTH (8191) slots each. The deployed bytecode
/// (BEACON_ROOTS_CODE, copied from the EEST Cancun fixtures) behaves as follows:
///
/// set (caller == SYSTEM_ADDRESS, run once at the start of every block):
///     timestamp_idx = block.timestamp % 8191
///     root_idx      = timestamp_idx + 8191
///     sstore(timestamp_idx, block.timestamp)
///     sstore(root_idx, calldataload(0))          // parent beacon block root
///
/// get (any other caller):
///     revert unless calldatasize == 32
///     timestamp = calldataload(0)
///     revert if timestamp == 0
///     revert unless sload(timestamp % 8191) == timestamp
///     return sload(timestamp % 8191 + 8191)
///
/// Storage values are 256-bit words. A 32-byte root is stored as the big-endian
/// integer CALLDATALOAD produces, so `std.mem.readInt(u256, &root, .big)`.
const std = @import("std");
const primitives = @import("voltaire");
const Address = primitives.Address.Address;
const Database = @import("../storage/database.zig").Database;
const BlockInfo = @import("../block/block_info.zig").BlockInfo(.{});
const log = @import("../log.zig");

/// EIP-4788 beacon roots contract address
/// Deployed at 0x000F3df6D732807Ef1319fB7B8bB8522d0Beac02
pub const BEACON_ROOTS_ADDRESS = Address{
    .bytes = [_]u8{
        0x00, 0x0F, 0x3d, 0xf6, 0xD7, 0x32, 0x80, 0x7E,
        0xf1, 0x31, 0x9f, 0xB7, 0xB8, 0xbB, 0x85, 0x22,
        0xd0, 0xBe, 0xac, 0x02,
    },
};

/// System address that can update beacon roots
/// 0xfffffffffffffffffffffffffffffffffffffffe
pub const SYSTEM_ADDRESS = Address{
    .bytes = [_]u8{
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xfe,
    },
};

/// Length of each beacon roots ring buffer (EIP-4788 HISTORY_BUFFER_LENGTH)
pub const HISTORY_BUFFER_LENGTH: u64 = 8191;

/// Runtime bytecode of the canonical EIP-4788 contract, byte-for-byte as deployed on
/// mainnet and as found in `pre` of the EEST `cancun/eip4788_beacon_root` fixtures.
pub const BEACON_ROOTS_CODE = decodeHex(
    "3373fffffffffffffffffffffffffffffffffffffffe14604d57602036146024575f5ffd5b5f358015604957" ++
        "62001fff810690815414603c575f5ffd5b62001fff01545f5260205ff35b5f5ffd5b62001fff42064281555f359062001fff015500",
);

fn decodeHex(comptime hex: []const u8) [hex.len / 2]u8 {
    var out: [hex.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, hex) catch |err| @compileError("invalid hex literal: " ++ @errorName(err));
    return out;
}

/// keccak256(BEACON_ROOTS_CODE)
pub fn beaconRootsCodeHash() [32]u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(&BEACON_ROOTS_CODE, &hash, .{});
    return hash;
}

/// Errors from the block-prologue helper `processBeaconRootUpdate`.
pub const BeaconRootUpdateError = error{
    /// The account at BEACON_ROOTS_ADDRESS has code other than BEACON_ROOTS_CODE. The
    /// native helper cannot reproduce arbitrary code; execute it as a real system call.
    NonCanonicalSystemContractCode,
} || Database.Error;

/// Compute storage slots for a given timestamp
/// Returns: { timestamp_slot, root_slot }
/// timestamp_slot holds the timestamp itself; root_slot holds the beacon root.
pub fn computeSlots(timestamp: u64) struct { timestamp_slot: u64, root_slot: u64 } {
    const timestamp_slot = timestamp % HISTORY_BUFFER_LENGTH;
    const root_slot = timestamp_slot + HISTORY_BUFFER_LENGTH;
    return .{ .timestamp_slot = timestamp_slot, .root_slot = root_slot };
}

/// True when `code_hash` denotes an account without code.
fn isNoCodeHash(code_hash: [32]u8) bool {
    return std.mem.eql(u8, &code_hash, &@as([32]u8, @splat(0))) or
        std.mem.eql(u8, &code_hash, &primitives.EMPTY_CODE_HASH);
}

/// Beacon roots contract implementation
pub const BeaconRootsContract = struct {
    /// The contract's `get` path: the beacon root stored for `timestamp`, or null
    /// where the real contract reverts (timestamp 0, or the ring slot holds a
    /// different timestamp).
    pub fn getBeaconRoot(database: anytype, timestamp: u256) !?[32]u8 {
        if (timestamp == 0) return null;
        const timestamp_slot: u256 = timestamp % HISTORY_BUFFER_LENGTH;
        const stored_timestamp = try database.get_storage(BEACON_ROOTS_ADDRESS.bytes, timestamp_slot);
        if (stored_timestamp != timestamp) return null;
        const root = try database.get_storage(BEACON_ROOTS_ADDRESS.bytes, timestamp_slot + HISTORY_BUFFER_LENGTH);
        var out: [32]u8 = undefined;
        std.mem.writeInt(u256, &out, root, .big);
        return out;
    }

    /// Block prologue (EIP-4788 / execution-specs `apply_body`): the unchecked system
    /// call `BEACON_ROOTS_ADDRESS(parent_beacon_block_root)` from SYSTEM_ADDRESS,
    /// performed natively with exactly the canonical contract's `set` storage writes.
    ///
    /// The caller gates on the fork (Cancun and later). Results:
    /// - `block_info.beacon_root == null`: no-op (no parent beacon root supplied).
    /// - no account or no code at BEACON_ROOTS_ADDRESS: no-op, as the spec's call to
    ///   empty code changes nothing.
    /// - code == BEACON_ROOTS_CODE: writes `timestamp` and the root.
    /// - any other code: `error.NonCanonicalSystemContractCode`, nothing written.
    /// Database errors propagate unchanged, and the update is all or nothing: an
    /// error leaves both slots as they were.
    pub fn processBeaconRootUpdate(
        database: anytype,
        block_info: *const BlockInfo,
    ) !void {
        const beacon_root = block_info.beacon_root orelse return;
        const account = (try database.get_account(BEACON_ROOTS_ADDRESS.bytes)) orelse return;
        if (isNoCodeHash(account.code_hash)) return;
        if (!std.mem.eql(u8, &account.code_hash, &beaconRootsCodeHash())) {
            log.warn("BeaconRoots: non-canonical code at beacon roots address", .{});
            return BeaconRootUpdateError.NonCanonicalSystemContractCode;
        }

        const timestamp = block_info.timestamp;
        const slots = computeSlots(timestamp);
        // The timestamp and the root are one update: a failed second write takes
        // the first one back. Reverting never allocates and cannot fail.
        const depth = database.snapshot_depth();
        _ = try database.create_snapshot();
        errdefer database.revert_to_depth(depth);
        try database.set_storage(BEACON_ROOTS_ADDRESS.bytes, slots.timestamp_slot, timestamp);
        try database.set_storage(
            BEACON_ROOTS_ADDRESS.bytes,
            slots.root_slot,
            std.mem.readInt(u256, &beacon_root, .big),
        );
        database.commit_to_depth(depth);

        log.debug("BeaconRoots: stored root for timestamp {} at slot {}", .{ timestamp, slots.timestamp_slot });
    }
};

// Tests

test "beacon roots code constant matches deployed bytecode" {
    const testing = std.testing;
    try testing.expectEqual(@as(usize, 97), BEACON_ROOTS_CODE.len);
    try testing.expectEqual(@as(u8, 0x33), BEACON_ROOTS_CODE[0]); // CALLER
    try testing.expectEqual(@as(u8, 0x00), BEACON_ROOTS_CODE[BEACON_ROOTS_CODE.len - 1]); // STOP
    try testing.expectEqualSlices(u8, &SYSTEM_ADDRESS.bytes, BEACON_ROOTS_CODE[2..22]);
}

test "beacon roots prologue matches EEST cancun beacon_root_contract_calls post-state" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const Account = @import("../storage/database_interface_account.zig").Account;

    var database = Database.init(allocator);
    defer database.deinit();

    const code_hash = try database.set_code(&BEACON_ROOTS_CODE);
    var account = Account.zero();
    account.nonce = 1;
    account.code_hash = code_hash;
    try database.set_account(BEACON_ROOTS_ADDRESS.bytes, account);

    // Values from tests/cancun/eip4788_beacon_root/test_beacon_root_contract.py fixture:
    // timestamp 0x0c, post storage {0x0c: 0x0c, 0x200b: root}.
    var root: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&root, "6c31fc15422ebad28aaf9089c306702f67540b53c7eea8b7d2941044b027100f");

    var block_info = BlockInfo.init();
    block_info.number = 1;
    block_info.timestamp = 0x0c;
    block_info.beacon_root = root;

    try BeaconRootsContract.processBeaconRootUpdate(&database, &block_info);

    try testing.expectEqual(@as(u256, 0x0c), try database.get_storage(BEACON_ROOTS_ADDRESS.bytes, 0x0c));
    try testing.expectEqual(
        @as(u256, 0x6c31fc15422ebad28aaf9089c306702f67540b53c7eea8b7d2941044b027100f),
        try database.get_storage(BEACON_ROOTS_ADDRESS.bytes, 0x200b),
    );
}

test "beacon roots prologue is a no-op without a parent beacon root" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const Account = @import("../storage/database_interface_account.zig").Account;

    var database = Database.init(allocator);
    defer database.deinit();

    const code_hash = try database.set_code(&BEACON_ROOTS_CODE);
    var account = Account.zero();
    account.code_hash = code_hash;
    try database.set_account(BEACON_ROOTS_ADDRESS.bytes, account);

    var block_info = BlockInfo.init();
    block_info.timestamp = 1000;
    block_info.beacon_root = null;

    try BeaconRootsContract.processBeaconRootUpdate(&database, &block_info);
    try testing.expectEqual(@as(u256, 0), try database.get_storage(BEACON_ROOTS_ADDRESS.bytes, 1000));
    try testing.expectEqual(@as(u256, 0), try database.get_storage(BEACON_ROOTS_ADDRESS.bytes, 1000 + HISTORY_BUFFER_LENGTH));
}

test "beacon roots prologue writes nothing when the contract has no code" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var database = Database.init(allocator);
    defer database.deinit();

    var block_info = BlockInfo.init();
    block_info.timestamp = 1000;
    block_info.beacon_root = @as([32]u8, @splat(0xAB));

    try BeaconRootsContract.processBeaconRootUpdate(&database, &block_info);
    try testing.expectEqual(@as(u256, 0), try database.get_storage(BEACON_ROOTS_ADDRESS.bytes, 1000));
    try testing.expectEqual(@as(u256, 0), try database.get_storage(BEACON_ROOTS_ADDRESS.bytes, 1000 + HISTORY_BUFFER_LENGTH));
}

test "beacon roots prologue rejects non-canonical contract code" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const Account = @import("../storage/database_interface_account.zig").Account;

    var database = Database.init(allocator);
    defer database.deinit();

    const code_hash = try database.set_code(&[_]u8{ 0x60, 0x00, 0x00 });
    var account = Account.zero();
    account.code_hash = code_hash;
    try database.set_account(BEACON_ROOTS_ADDRESS.bytes, account);

    var block_info = BlockInfo.init();
    block_info.timestamp = 1000;
    block_info.beacon_root = @as([32]u8, @splat(0xAB));

    try testing.expectError(
        BeaconRootUpdateError.NonCanonicalSystemContractCode,
        BeaconRootsContract.processBeaconRootUpdate(&database, &block_info),
    );
    try testing.expectEqual(@as(u256, 0), try database.get_storage(BEACON_ROOTS_ADDRESS.bytes, 1000));
}

test "beacon roots slot order: timestamp slot holds timestamp, root slot holds root" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const Account = @import("../storage/database_interface_account.zig").Account;

    var database = Database.init(allocator);
    defer database.deinit();

    const code_hash = try database.set_code(&BEACON_ROOTS_CODE);
    var account = Account.zero();
    account.code_hash = code_hash;
    try database.set_account(BEACON_ROOTS_ADDRESS.bytes, account);

    const timestamp: u64 = 1710338135;
    var root: [32]u8 = @as([32]u8, @splat(0));
    root[0] = 0x12; // most significant byte
    root[31] = 0x34; // least significant byte

    var block_info = BlockInfo.init();
    block_info.timestamp = timestamp;
    block_info.beacon_root = root;
    try BeaconRootsContract.processBeaconRootUpdate(&database, &block_info);

    const timestamp_slot = timestamp % HISTORY_BUFFER_LENGTH;
    try testing.expectEqual(@as(u256, timestamp), try database.get_storage(BEACON_ROOTS_ADDRESS.bytes, timestamp_slot));
    const stored_root = try database.get_storage(BEACON_ROOTS_ADDRESS.bytes, timestamp_slot + HISTORY_BUFFER_LENGTH);
    try testing.expectEqual(std.mem.readInt(u256, &root, .big), stored_root);
    try testing.expectEqual(@as(u256, 0x34), stored_root & 0xff);
}

test "beacon roots get returns the root written by the prologue" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const Account = @import("../storage/database_interface_account.zig").Account;

    var database = Database.init(allocator);
    defer database.deinit();

    const code_hash = try database.set_code(&BEACON_ROOTS_CODE);
    var account = Account.zero();
    account.code_hash = code_hash;
    try database.set_account(BEACON_ROOTS_ADDRESS.bytes, account);

    var root: [32]u8 = undefined;
    for (&root, 0..) |*byte, i| byte.* = @intCast(i + 1);

    var block_info = BlockInfo.init();
    block_info.timestamp = 1710338135;
    block_info.beacon_root = root;
    try BeaconRootsContract.processBeaconRootUpdate(&database, &block_info);

    const direct = (try BeaconRootsContract.getBeaconRoot(&database, block_info.timestamp)).?;
    try testing.expectEqualSlices(u8, &root, &direct);
}

test "beacon roots get reverts on zero, unknown, and above-u64 timestamps" {
    const testing = std.testing;
    var database = Database.init(testing.allocator);
    defer database.deinit();

    try testing.expect((try BeaconRootsContract.getBeaconRoot(&database, 0)) == null);
    try testing.expect((try BeaconRootsContract.getBeaconRoot(&database, 999999)) == null);
    // A timestamp above u64 can never match a stored timestamp: revert, not overflow.
    try testing.expect((try BeaconRootsContract.getBeaconRoot(&database, @as(u256, std.math.maxInt(u64)) + 1)) == null);
    try testing.expect((try BeaconRootsContract.getBeaconRoot(&database, std.math.maxInt(u256))) == null);
}

test "beacon roots get on a zero-timestamp write still reverts" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const Account = @import("../storage/database_interface_account.zig").Account;

    var database = Database.init(allocator);
    defer database.deinit();

    const code_hash = try database.set_code(&BEACON_ROOTS_CODE);
    var account = Account.zero();
    account.code_hash = code_hash;
    try database.set_account(BEACON_ROOTS_ADDRESS.bytes, account);

    var block_info = BlockInfo.init();
    block_info.timestamp = 0;
    block_info.beacon_root = @as([32]u8, @splat(0xAA));
    try BeaconRootsContract.processBeaconRootUpdate(&database, &block_info);

    try testing.expect((try BeaconRootsContract.getBeaconRoot(&database, 0)) == null);
}

test "beacon roots ring buffer wrap around evicts the older timestamp" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const Account = @import("../storage/database_interface_account.zig").Account;

    var database = Database.init(allocator);
    defer database.deinit();

    const code_hash = try database.set_code(&BEACON_ROOTS_CODE);
    var account = Account.zero();
    account.code_hash = code_hash;
    try database.set_account(BEACON_ROOTS_ADDRESS.bytes, account);

    const timestamp1: u64 = 1000;
    const timestamp2: u64 = timestamp1 + HISTORY_BUFFER_LENGTH;

    var block_info = BlockInfo.init();
    block_info.timestamp = timestamp1;
    block_info.beacon_root = @as([32]u8, @splat(0x11));
    try BeaconRootsContract.processBeaconRootUpdate(&database, &block_info);

    block_info.timestamp = timestamp2;
    block_info.beacon_root = @as([32]u8, @splat(0x22));
    try BeaconRootsContract.processBeaconRootUpdate(&database, &block_info);

    try testing.expect((try BeaconRootsContract.getBeaconRoot(&database, timestamp1)) == null);
    const root2 = (try BeaconRootsContract.getBeaconRoot(&database, timestamp2)).?;
    try testing.expectEqualSlices(u8, &@as([32]u8, @splat(0x22)), &root2);
}

test "beacon roots slot computation" {
    const testing = std.testing;
    const slots = computeSlots(8192000);
    try testing.expectEqual(@as(u64, 8192000 % 8191), slots.timestamp_slot);
    try testing.expectEqual(slots.timestamp_slot + HISTORY_BUFFER_LENGTH, slots.root_slot);
    try testing.expect(slots.timestamp_slot < HISTORY_BUFFER_LENGTH);
}
