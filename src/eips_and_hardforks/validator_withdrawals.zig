/// EIP-7002: Execution layer triggerable withdrawals
///
/// Withdrawal requests live in the predeploy at WITHDRAWAL_REQUEST_ADDRESS, which is
/// ordinary deployed bytecode: user calls run it from state like any contract. The
/// only protocol action is at the END of a block (execution-specs Prague
/// `process_general_purpose_requests`): a checked system call from SYSTEM_ADDRESS
/// with empty calldata and SYSTEM_CALL_GAS_LIMIT gas. The block is invalid if the
/// predeploy has no code or the call fails. Non-empty return data (concatenated
/// WITHDRAWAL_REQUEST_LENGTH-byte records) prefixed with WITHDRAWAL_REQUEST_TYPE is
/// the block's withdrawal request. That call must execute the real bytecode, which
/// also dequeues requests and updates the excess/count slots.
const std = @import("std");
const primitives = @import("voltaire");
const Address = primitives.Address.Address;
const Database = @import("../storage/database.zig").Database;
const BlockInfo = @import("../block/block_info.zig").BlockInfo(.{});

/// EIP-7002 withdrawal request predeploy (WITHDRAWAL_REQUEST_PREDEPLOY_ADDRESS)
/// 0x00000961Ef480Eb55e80D19ad83579A64c007002, per https://eips.ethereum.org/EIPS/eip-7002
pub const WITHDRAWAL_REQUEST_ADDRESS = Address{
    .bytes = [_]u8{
        0x00, 0x00, 0x09, 0x61, 0xEf, 0x48, 0x0E, 0xb5,
        0x5e, 0x80, 0xD1, 0x9a, 0xd8, 0x35, 0x79, 0xA6,
        0x4c, 0x00, 0x70, 0x02,
    },
};

/// System address used as caller of the end-of-block system call
/// 0xfffffffffffffffffffffffffffffffffffffffe
pub const SYSTEM_ADDRESS = Address{
    .bytes = [_]u8{
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xfe,
    },
};

/// execution-specs SYSTEM_TRANSACTION_GAS
pub const SYSTEM_CALL_GAS_LIMIT: u64 = 30_000_000;

/// EIP-7685 request type byte for withdrawal requests
pub const WITHDRAWAL_REQUEST_TYPE: u8 = 0x01;

/// One record in the system call's return data:
/// source_address(20) || validator_pubkey(48) || amount(8, big-endian gwei)
pub const WITHDRAWAL_REQUEST_LENGTH: usize = 76;

/// EIP-7002 MAX_WITHDRAWAL_REQUESTS_PER_BLOCK (enforced by the predeploy's dequeue)
pub const MAX_WITHDRAWAL_REQUESTS_PER_BLOCK: usize = 16;

/// Validator withdrawals contract implementation
pub const ValidatorWithdrawalsContract = struct {
    /// Block prologue for EIP-7002: none. Prague `apply_body` makes the withdrawal
    /// system call after all transactions, and it must run the predeploy's bytecode.
    /// Always succeeds and touches no state. Callers should drop this call from
    /// block-start processing and add the end-of-block system call instead.
    pub fn processBlockWithdrawals(
        database: *Database,
        block_info: *const BlockInfo,
    ) error{}!void {
        _ = database;
        _ = block_info;
    }
};

// Tests

test "withdrawal predeploy constants match EIP-7002" {
    const testing = std.testing;
    const expected = try Address.fromHex("0x00000961Ef480Eb55e80D19ad83579A64c007002");
    try testing.expectEqual(expected, WITHDRAWAL_REQUEST_ADDRESS);
    try testing.expectEqual(@as(usize, 20 + 48 + 8), WITHDRAWAL_REQUEST_LENGTH);
    try testing.expectEqual(@as(u8, 0x01), WITHDRAWAL_REQUEST_TYPE);
}

test "processBlockWithdrawals touches no state" {
    const testing = std.testing;
    var database = Database.init(testing.allocator);
    defer database.deinit();

    // Slot 0 of the real predeploy is the excess counter, which starts at
    // 2**256 - 1 (EXCESS_INHIBITOR). The old helper read it as a request count
    // and failed the block with TooManyWithdrawals.
    try database.set_storage(WITHDRAWAL_REQUEST_ADDRESS.bytes, 0, std.math.maxInt(u256));

    var block_info = BlockInfo.init();
    block_info.number = 1000;
    try ValidatorWithdrawalsContract.processBlockWithdrawals(&database, &block_info);
    try testing.expectEqual(@as(u256, std.math.maxInt(u256)), try database.get_storage(WITHDRAWAL_REQUEST_ADDRESS.bytes, 0));
}
