/// EIP-2935: Serve historical block hashes from state
///
/// The history system contract stores the last HISTORY_SERVE_WINDOW (8191) block
/// hashes in one ring of storage slots. The deployed bytecode (HISTORY_CODE, copied
/// from the execution-specs Prague EEST `eip2935_historical_block_hashes_from_state`
/// deployment fixture) behaves as follows:
///
/// set (caller == SYSTEM_ADDRESS, run once at the start of every block):
///     sstore((block.number - 1) % 8191, calldataload(0))   // parent hash
///
/// get (any other caller):
///     revert unless calldatasize == 32
///     n = calldataload(0)
///     revert if n > block.number - 1
///     revert if block.number - n > 8191
///     return sload(n % 8191)
///
/// So `get` serves exactly [block.number - 8191, block.number - 1]. There is no
/// second "block number" slot (unlike EIP-4788). Storage values are 256-bit words;
/// a 32-byte hash is stored as the big-endian integer CALLDATALOAD produces.
const std = @import("std");
const primitives = @import("voltaire");
const Address = primitives.Address.Address;
const Database = @import("../storage/database.zig").Database;
const BlockInfo = @import("../block/block_info.zig").BlockInfo(.{});
const log = @import("../log.zig");

/// EIP-2935 historical block hashes contract address (Prague mainnet):
/// 0x0000F90827F1C53a10cb7A02335B175320002935
pub const HISTORY_CONTRACT_ADDRESS = Address{
    .bytes = .{
        0x00, 0x00, 0xf9, 0x08, 0x27, 0xf1, 0xc5, 0x3a, 0x10, 0xcb,
        0x7a, 0x02, 0x33, 0x5b, 0x17, 0x53, 0x20, 0x00, 0x29, 0x35,
    },
};

/// System address that can update block hashes
/// 0xfffffffffffffffffffffffffffffffffffffffe
pub const SYSTEM_ADDRESS = Address{
    .bytes = [_]u8{
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xfe,
    },
};

/// EIP-2935 HISTORY_SERVE_WINDOW: ring size and maximum lookback.
pub const HISTORY_SERVE_WINDOW: u64 = 8191;

/// Runtime bytecode of the canonical EIP-2935 contract, byte-for-byte as in
/// execution-specs `tests/eest/prague/eip2935_historical_block_hashes_from_state/contract_deploy_tx.json`.
pub const HISTORY_CODE = decodeHex(
    "3373fffffffffffffffffffffffffffffffffffffffe14604657602036036042575f35600143038111604257" ++
        "611fff81430311604257611fff9006545f5260205ff35b5f5ffd5b5f35611fff60014303065500",
);

fn decodeHex(comptime hex: []const u8) [hex.len / 2]u8 {
    var out: [hex.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, hex) catch |err| @compileError("invalid hex literal: " ++ @errorName(err));
    return out;
}

/// keccak256(HISTORY_CODE)
pub fn historyCodeHash() [32]u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(&HISTORY_CODE, &hash, .{});
    return hash;
}

/// Errors from the block-prologue helper `processBlockHashUpdate`.
pub const BlockHashUpdateError = error{
    /// The account at HISTORY_CONTRACT_ADDRESS has code other than HISTORY_CODE. The
    /// native helper cannot reproduce arbitrary code; execute it as a real system call.
    NonCanonicalSystemContractCode,
} || Database.Error;

/// Storage slot that holds the hash of `block_number`.
pub fn computeSlot(block_number: u64) u64 {
    return block_number % HISTORY_SERVE_WINDOW;
}

/// True when `code_hash` denotes an account without code.
fn isNoCodeHash(code_hash: [32]u8) bool {
    return std.mem.eql(u8, &code_hash, &@as([32]u8, @splat(0))) or
        std.mem.eql(u8, &code_hash, &primitives.EMPTY_CODE_HASH);
}

/// Historical block hashes contract implementation
pub const HistoricalBlockHashesContract = struct {
    /// Block prologue (EIP-2935 / execution-specs Prague `apply_body`): the unchecked
    /// system call `HISTORY_CONTRACT_ADDRESS(parent_hash)` from SYSTEM_ADDRESS, performed
    /// natively with exactly the canonical contract's `set` storage write:
    /// `sstore((number - 1) % 8191, parent_hash)`.
    ///
    /// The caller gates on the fork (Prague and later) and must fill
    /// `block_info.parent_hash`. Results:
    /// - `block_info.number == 0`: no-op (genesis has no parent and is never executed).
    /// - no account or no code at HISTORY_CONTRACT_ADDRESS: no-op, as the spec's call to
    ///   empty code changes nothing.
    /// - code == HISTORY_CODE: writes one slot.
    /// - any other code: `error.NonCanonicalSystemContractCode`, nothing written.
    /// Database errors propagate unchanged.
    pub fn processBlockHashUpdate(
        database: anytype,
        block_info: *const BlockInfo,
    ) !void {
        if (block_info.number == 0) return;
        const account = (try database.get_account(HISTORY_CONTRACT_ADDRESS.bytes)) orelse return;
        if (isNoCodeHash(account.code_hash)) return;
        if (!std.mem.eql(u8, &account.code_hash, &historyCodeHash())) {
            log.warn("HistoricalBlockHashes: non-canonical code at history contract address", .{});
            return BlockHashUpdateError.NonCanonicalSystemContractCode;
        }

        const parent_number = block_info.number - 1;
        const slot = computeSlot(parent_number);
        try database.set_storage(
            HISTORY_CONTRACT_ADDRESS.bytes,
            slot,
            std.mem.readInt(u256, &block_info.parent_hash, .big),
        );

        log.debug("HistoricalBlockHashes: stored hash of block {} at slot {}", .{ parent_number, slot });
    }

    /// The contract's `get` path executed in block `current_block`: the stored hash of
    /// `requested`, or null where the real contract reverts (requested > current - 1,
    /// or current - requested > 8191). An in-window slot that was never written reads
    /// as 32 zero bytes, as SLOAD does.
    pub fn getBlockHash(
        database: anytype,
        requested: u256,
        current_block: u64,
    ) !?[32]u8 {
        if (current_block == 0) return null;
        const current: u256 = current_block;
        if (requested > current - 1) return null;
        if (current - requested > HISTORY_SERVE_WINDOW) return null;

        const stored = try database.get_storage(HISTORY_CONTRACT_ADDRESS.bytes, requested % HISTORY_SERVE_WINDOW);
        var out: [32]u8 = undefined;
        std.mem.writeInt(u256, &out, stored, .big);
        return out;
    }
};

// Tests

test "historical block hashes window is EIP-2935 HISTORY_SERVE_WINDOW" {
    try std.testing.expectEqual(@as(u64, 8191), HISTORY_SERVE_WINDOW);
    // The bytecode embeds the window as PUSH2 0x1fff.
    try std.testing.expect(std.mem.indexOf(u8, &HISTORY_CODE, &[_]u8{ 0x61, 0x1f, 0xff }) != null);
    try std.testing.expectEqualSlices(u8, &SYSTEM_ADDRESS.bytes, HISTORY_CODE[2..22]);
    try std.testing.expectEqual(@as(usize, 83), HISTORY_CODE.len);
}

test "historical block hashes prologue writes parent hash at (number - 1) % 8191" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const Account = @import("../storage/database_interface_account.zig").Account;

    var database = Database.init(allocator);
    defer database.deinit();

    const code_hash = try database.set_code(&HISTORY_CODE);
    var account = Account.zero();
    account.nonce = 1;
    account.code_hash = code_hash;
    try database.set_account(HISTORY_CONTRACT_ADDRESS.bytes, account);

    var parent_hash: [32]u8 = @as([32]u8, @splat(0));
    parent_hash[0] = 0xAB; // most significant byte
    parent_hash[31] = 0xCD;

    var block_info = BlockInfo.init();
    block_info.number = 8192 + 5; // parent 8196 -> slot 5
    block_info.parent_hash = parent_hash;

    try HistoricalBlockHashesContract.processBlockHashUpdate(&database, &block_info);

    const stored = try database.get_storage(HISTORY_CONTRACT_ADDRESS.bytes, 5);
    try testing.expectEqual(std.mem.readInt(u256, &parent_hash, .big), stored);
    try testing.expectEqual(@as(u256, 0xCD), stored & 0xff);
    // No reverse-mapping slot exists in the real contract.
    try testing.expectEqual(@as(u256, 0), try database.get_storage(HISTORY_CONTRACT_ADDRESS.bytes, 5 + HISTORY_SERVE_WINDOW));
    try testing.expectEqual(@as(u256, 0), try database.get_storage(HISTORY_CONTRACT_ADDRESS.bytes, (8196 % 8192)));
}

test "historical block hashes prologue no-ops at genesis and without code" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const Account = @import("../storage/database_interface_account.zig").Account;

    var database = Database.init(allocator);
    defer database.deinit();

    var block_info = BlockInfo.init();
    block_info.number = 10;
    block_info.parent_hash = @as([32]u8, @splat(0x11));

    // No account at the address.
    try HistoricalBlockHashesContract.processBlockHashUpdate(&database, &block_info);
    try testing.expectEqual(@as(u256, 0), try database.get_storage(HISTORY_CONTRACT_ADDRESS.bytes, 9));

    // Account exists but has no code.
    var account = Account.zero();
    account.code_hash = primitives.EMPTY_CODE_HASH;
    try database.set_account(HISTORY_CONTRACT_ADDRESS.bytes, account);
    try HistoricalBlockHashesContract.processBlockHashUpdate(&database, &block_info);
    try testing.expectEqual(@as(u256, 0), try database.get_storage(HISTORY_CONTRACT_ADDRESS.bytes, 9));

    // Canonical code at genesis: no parent, nothing written.
    account.code_hash = try database.set_code(&HISTORY_CODE);
    try database.set_account(HISTORY_CONTRACT_ADDRESS.bytes, account);
    block_info.number = 0;
    try HistoricalBlockHashesContract.processBlockHashUpdate(&database, &block_info);
    try testing.expectEqual(@as(u256, 0), try database.get_storage(HISTORY_CONTRACT_ADDRESS.bytes, 9));
    const wrapped_slot: u256 = std.math.maxInt(u256) % @as(u256, HISTORY_SERVE_WINDOW);
    try testing.expectEqual(@as(u256, 0), try database.get_storage(HISTORY_CONTRACT_ADDRESS.bytes, wrapped_slot));
}

test "historical block hashes prologue rejects non-canonical contract code" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const Account = @import("../storage/database_interface_account.zig").Account;

    var database = Database.init(allocator);
    defer database.deinit();

    var account = Account.zero();
    account.code_hash = try database.set_code(&[_]u8{ 0x60, 0x00, 0x00 });
    try database.set_account(HISTORY_CONTRACT_ADDRESS.bytes, account);

    var block_info = BlockInfo.init();
    block_info.number = 10;
    block_info.parent_hash = @as([32]u8, @splat(0x11));

    try testing.expectError(
        BlockHashUpdateError.NonCanonicalSystemContractCode,
        HistoricalBlockHashesContract.processBlockHashUpdate(&database, &block_info),
    );
    try testing.expectEqual(@as(u256, 0), try database.get_storage(HISTORY_CONTRACT_ADDRESS.bytes, 9));
}

test "historical block hashes get serves exactly [number - 8191, number - 1]" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var database = Database.init(allocator);
    defer database.deinit();

    const current: u64 = 20000;
    const oldest: u64 = current - HISTORY_SERVE_WINDOW; // 11809
    try database.set_storage(HISTORY_CONTRACT_ADDRESS.bytes, computeSlot(oldest), 0xAA);
    try database.set_storage(HISTORY_CONTRACT_ADDRESS.bytes, computeSlot(current - 1), 0xBB);

    const at_oldest = (try HistoricalBlockHashesContract.getBlockHash(&database, oldest, current)).?;
    try testing.expectEqual(@as(u256, 0xAA), std.mem.readInt(u256, &at_oldest, .big));
    const at_parent = (try HistoricalBlockHashesContract.getBlockHash(&database, current - 1, current)).?;
    try testing.expectEqual(@as(u256, 0xBB), std.mem.readInt(u256, &at_parent, .big));

    try testing.expect((try HistoricalBlockHashesContract.getBlockHash(&database, oldest - 1, current)) == null);
    try testing.expect((try HistoricalBlockHashesContract.getBlockHash(&database, current, current)) == null);
    try testing.expect((try HistoricalBlockHashesContract.getBlockHash(&database, current + 1, current)) == null);
    try testing.expect((try HistoricalBlockHashesContract.getBlockHash(&database, std.math.maxInt(u256), current)) == null);

    // Early chain: block 0 is in range once block 1 is executing.
    try testing.expect((try HistoricalBlockHashesContract.getBlockHash(&database, 0, 1)) != null);
    try testing.expect((try HistoricalBlockHashesContract.getBlockHash(&database, 0, 0)) == null);
}

test "historical block hashes ring wrap: block n + 8191 overwrites block n" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const Account = @import("../storage/database_interface_account.zig").Account;

    var database = Database.init(allocator);
    defer database.deinit();

    var account = Account.zero();
    account.code_hash = try database.set_code(&HISTORY_CODE);
    try database.set_account(HISTORY_CONTRACT_ADDRESS.bytes, account);

    var block_info = BlockInfo.init();
    block_info.number = 1001; // writes block 1000
    block_info.parent_hash = @as([32]u8, @splat(0x11));
    try HistoricalBlockHashesContract.processBlockHashUpdate(&database, &block_info);

    block_info.number = 1001 + HISTORY_SERVE_WINDOW; // writes block 9191, same slot
    block_info.parent_hash = @as([32]u8, @splat(0x22));
    try HistoricalBlockHashesContract.processBlockHashUpdate(&database, &block_info);

    // Block 1000 is now outside the window, so get reverts.
    try testing.expect((try HistoricalBlockHashesContract.getBlockHash(&database, 1000, block_info.number)) == null);
    const newest = (try HistoricalBlockHashesContract.getBlockHash(&database, 1000 + HISTORY_SERVE_WINDOW, block_info.number)).?;
    try testing.expectEqualSlices(u8, &@as([32]u8, @splat(0x22)), &newest);
}
