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
///
/// Scope of this module: the constants of that system call. It does not make the
/// call; a host that assembles blocks runs it through the EVM after the block's
/// last transaction. The EVM has no block-start step for withdrawals, so
/// `Evm.beginBlock` does nothing for EIP-7002.
const std = @import("std");
const primitives = @import("voltaire");
const Address = primitives.Address.Address;

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

// Tests

test "withdrawal predeploy constants match EIP-7002" {
    const testing = std.testing;
    const expected = try Address.fromHex("0x00000961Ef480Eb55e80D19ad83579A64c007002");
    try testing.expectEqual(expected, WITHDRAWAL_REQUEST_ADDRESS);
    try testing.expectEqual(@as(usize, 20 + 48 + 8), WITHDRAWAL_REQUEST_LENGTH);
    try testing.expectEqual(@as(u8, 0x01), WITHDRAWAL_REQUEST_TYPE);
}
