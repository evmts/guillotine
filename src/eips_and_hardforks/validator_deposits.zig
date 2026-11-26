/// EIP-6110: Supply validator deposits on chain
///
/// EIP-6110 adds no system contract and no state transition. At the end of a block
/// (execution-specs Prague `process_general_purpose_requests` / `parse_deposit_requests`),
/// every receipt log emitted by DEPOSIT_CONTRACT_ADDRESS whose first topic is
/// DEPOSIT_EVENT_SIGNATURE_HASH is decoded with `extractDepositData`; the concatenated
/// 192-byte records, prefixed with DEPOSIT_REQUEST_TYPE, form the block's deposit
/// request (when non-empty). The deposit contract itself is ordinary deployed bytecode
/// and executes from state like any other contract.
///
/// Scope of this module: the constants, `isDepositLog` and `extractDepositData`. It
/// does not walk a block's receipts or build the request; a host that assembles
/// blocks does that with these helpers. The EVM has no block-start step for
/// deposits, so `Evm.beginBlock` does nothing for EIP-6110.
const std = @import("std");
const primitives = @import("voltaire");
const Address = primitives.Address.Address;

/// Mainnet deposit contract, 0x00000000219ab540356cBB839Cbe05303d7705Fa
pub const DEPOSIT_CONTRACT_ADDRESS = Address{
    .bytes = [_]u8{
        0x00, 0x00, 0x00, 0x00, 0x21, 0x9a, 0xb5, 0x40,
        0x35, 0x6c, 0xBB, 0x83, 0x9C, 0xbe, 0x05, 0x30,
        0x3d, 0x77, 0x05, 0xFa,
    },
};

/// keccak256("DepositEvent(bytes,bytes,bytes,bytes,bytes)")
pub const DEPOSIT_EVENT_SIGNATURE_HASH = [32]u8{
    0x64, 0x9b, 0xbc, 0x62, 0xd0, 0xe3, 0x13, 0x42, 0xaf, 0xea, 0x4e, 0x5c, 0xd8, 0x2d, 0x40, 0x49,
    0xe7, 0xe1, 0xee, 0x91, 0x2f, 0xc0, 0x88, 0x9a, 0xa7, 0x90, 0x80, 0x3b, 0xe3, 0x90, 0x38, 0xc5,
};

/// EIP-7685 request type byte for deposits
pub const DEPOSIT_REQUEST_TYPE: u8 = 0x00;

/// ABI-encoded DepositEvent data length
pub const DEPOSIT_EVENT_LENGTH: usize = 576;

/// One decoded deposit request: pubkey(48) || withdrawal_credentials(32) ||
/// amount(8, little-endian gwei as logged) || signature(96) || index(8, little-endian).
pub const DEPOSIT_REQUEST_LENGTH: usize = 192;

const PUBKEY_OFFSET: u256 = 160;
const WITHDRAWAL_CREDENTIALS_OFFSET: u256 = 256;
const AMOUNT_OFFSET: u256 = 320;
const SIGNATURE_OFFSET: u256 = 384;
const INDEX_OFFSET: u256 = 512;

const PUBKEY_SIZE: u256 = 48;
const WITHDRAWAL_CREDENTIALS_SIZE: u256 = 32;
const AMOUNT_SIZE: u256 = 8;
const SIGNATURE_SIZE: u256 = 96;
const INDEX_SIZE: u256 = 8;

/// A deposit log that does not have the exact DepositEvent layout. execution-specs
/// raises InvalidBlock for each of these.
pub const DepositLogError = error{
    InvalidDepositEventLength,
    InvalidPubkeyOffset,
    InvalidWithdrawalCredentialsOffset,
    InvalidAmountOffset,
    InvalidSignatureOffset,
    InvalidIndexOffset,
    InvalidPubkeySize,
    InvalidWithdrawalCredentialsSize,
    InvalidAmountSize,
    InvalidSignatureSize,
    InvalidIndexSize,
};

/// True when a log is a deposit event that `parse_deposit_requests` decodes.
pub fn isDepositLog(address: Address, topics: []const u256) bool {
    if (!std.mem.eql(u8, &address.bytes, &DEPOSIT_CONTRACT_ADDRESS.bytes)) return false;
    if (topics.len == 0) return false;
    return topics[0] == std.mem.readInt(u256, &DEPOSIT_EVENT_SIGNATURE_HASH, .big);
}

fn word(data: []const u8, offset: usize) u256 {
    return std.mem.readInt(u256, data[offset..][0..32], .big);
}

/// execution-specs Prague `extract_deposit_data`: validates the ABI layout of a
/// DepositEvent's data and returns the 192-byte request record.
pub fn extractDepositData(data: []const u8) DepositLogError![DEPOSIT_REQUEST_LENGTH]u8 {
    if (data.len != DEPOSIT_EVENT_LENGTH) return DepositLogError.InvalidDepositEventLength;

    if (word(data, 0) != PUBKEY_OFFSET) return DepositLogError.InvalidPubkeyOffset;
    if (word(data, 32) != WITHDRAWAL_CREDENTIALS_OFFSET) return DepositLogError.InvalidWithdrawalCredentialsOffset;
    if (word(data, 64) != AMOUNT_OFFSET) return DepositLogError.InvalidAmountOffset;
    if (word(data, 96) != SIGNATURE_OFFSET) return DepositLogError.InvalidSignatureOffset;
    if (word(data, 128) != INDEX_OFFSET) return DepositLogError.InvalidIndexOffset;

    if (word(data, 160) != PUBKEY_SIZE) return DepositLogError.InvalidPubkeySize;
    if (word(data, 256) != WITHDRAWAL_CREDENTIALS_SIZE) return DepositLogError.InvalidWithdrawalCredentialsSize;
    if (word(data, 320) != AMOUNT_SIZE) return DepositLogError.InvalidAmountSize;
    if (word(data, 384) != SIGNATURE_SIZE) return DepositLogError.InvalidSignatureSize;
    if (word(data, 512) != INDEX_SIZE) return DepositLogError.InvalidIndexSize;

    var out: [DEPOSIT_REQUEST_LENGTH]u8 = undefined;
    @memcpy(out[0..48], data[192..240]);
    @memcpy(out[48..80], data[288..320]);
    @memcpy(out[80..88], data[352..360]);
    @memcpy(out[88..184], data[416..512]);
    @memcpy(out[184..192], data[544..552]);
    return out;
}

// Tests

test "deposit event signature hash is keccak of the event signature" {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash("DepositEvent(bytes,bytes,bytes,bytes,bytes)", &hash, .{});
    try std.testing.expectEqualSlices(u8, &hash, &DEPOSIT_EVENT_SIGNATURE_HASH);
}

test "extractDepositData returns pubkey, credentials, amount, signature, index" {
    const testing = std.testing;
    var data: [DEPOSIT_EVENT_LENGTH]u8 = @as([DEPOSIT_EVENT_LENGTH]u8, @splat(0));
    std.mem.writeInt(u256, data[0..32], 160, .big);
    std.mem.writeInt(u256, data[32..64], 256, .big);
    std.mem.writeInt(u256, data[64..96], 320, .big);
    std.mem.writeInt(u256, data[96..128], 384, .big);
    std.mem.writeInt(u256, data[128..160], 512, .big);
    std.mem.writeInt(u256, data[160..192], 48, .big);
    @memset(data[192..240], 0xAA);
    std.mem.writeInt(u256, data[256..288], 32, .big);
    @memset(data[288..320], 0xBB);
    std.mem.writeInt(u256, data[320..352], 8, .big);
    std.mem.writeInt(u64, data[352..360], 32_000_000_000, .little);
    std.mem.writeInt(u256, data[384..416], 96, .big);
    @memset(data[416..512], 0xCC);
    std.mem.writeInt(u256, data[512..544], 8, .big);
    std.mem.writeInt(u64, data[544..552], 7, .little);
    const request = try extractDepositData(&data);

    try testing.expectEqualSlices(u8, &@as([48]u8, @splat(0xAA)), request[0..48]);
    try testing.expectEqualSlices(u8, &@as([32]u8, @splat(0xBB)), request[48..80]);
    try testing.expectEqual(@as(u64, 32_000_000_000), std.mem.readInt(u64, request[80..88], .little));
    try testing.expectEqualSlices(u8, &@as([96]u8, @splat(0xCC)), request[88..184]);
    try testing.expectEqual(@as(u64, 7), std.mem.readInt(u64, request[184..192], .little));
}

test "extractDepositData rejects every layout deviation" {
    const testing = std.testing;

    const short = @as([DEPOSIT_EVENT_LENGTH - 1]u8, @splat(0));
    try testing.expectError(DepositLogError.InvalidDepositEventLength, extractDepositData(&short));

    const cases = [_]struct { offset: usize, err: DepositLogError }{
        .{ .offset = 0, .err = DepositLogError.InvalidPubkeyOffset },
        .{ .offset = 32, .err = DepositLogError.InvalidWithdrawalCredentialsOffset },
        .{ .offset = 64, .err = DepositLogError.InvalidAmountOffset },
        .{ .offset = 96, .err = DepositLogError.InvalidSignatureOffset },
        .{ .offset = 128, .err = DepositLogError.InvalidIndexOffset },
        .{ .offset = 160, .err = DepositLogError.InvalidPubkeySize },
        .{ .offset = 256, .err = DepositLogError.InvalidWithdrawalCredentialsSize },
        .{ .offset = 320, .err = DepositLogError.InvalidAmountSize },
        .{ .offset = 384, .err = DepositLogError.InvalidSignatureSize },
        .{ .offset = 512, .err = DepositLogError.InvalidIndexSize },
    };
    for (cases) |case| {
        var data: [DEPOSIT_EVENT_LENGTH]u8 = @as([DEPOSIT_EVENT_LENGTH]u8, @splat(0));
        std.mem.writeInt(u256, data[0..32], 160, .big);
        std.mem.writeInt(u256, data[32..64], 256, .big);
        std.mem.writeInt(u256, data[64..96], 320, .big);
        std.mem.writeInt(u256, data[96..128], 384, .big);
        std.mem.writeInt(u256, data[128..160], 512, .big);
        std.mem.writeInt(u256, data[160..192], 48, .big);
        @memset(data[192..240], 0xAA);
        std.mem.writeInt(u256, data[256..288], 32, .big);
        @memset(data[288..320], 0xBB);
        std.mem.writeInt(u256, data[320..352], 8, .big);
        std.mem.writeInt(u64, data[352..360], 32_000_000_000, .little);
        std.mem.writeInt(u256, data[384..416], 96, .big);
        @memset(data[416..512], 0xCC);
        std.mem.writeInt(u256, data[512..544], 8, .big);
        std.mem.writeInt(u64, data[544..552], 7, .little);
        data[case.offset] = 0x01; // corrupt the high byte of the word
        try testing.expectError(case.err, extractDepositData(&data));
    }
}

test "isDepositLog matches address and first topic only" {
    const testing = std.testing;
    const topic = std.mem.readInt(u256, &DEPOSIT_EVENT_SIGNATURE_HASH, .big);
    try testing.expect(isDepositLog(DEPOSIT_CONTRACT_ADDRESS, &[_]u256{topic}));
    try testing.expect(isDepositLog(DEPOSIT_CONTRACT_ADDRESS, &[_]u256{ topic, 1 }));
    try testing.expect(!isDepositLog(DEPOSIT_CONTRACT_ADDRESS, &[_]u256{}));
    try testing.expect(!isDepositLog(DEPOSIT_CONTRACT_ADDRESS, &[_]u256{ 1, topic }));
    try testing.expect(!isDepositLog(Address{ .bytes = @as([20]u8, @splat(0x11)) }, &[_]u256{topic}));
}
