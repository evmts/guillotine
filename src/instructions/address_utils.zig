const std = @import("std");
const Address = @import("voltaire").Address;

/// Convert Address to WordType (zero-extended to word size)
pub fn toWord(comptime WordType: type, addr: Address) WordType {
    // Three big-endian limb loads (4 + 8 + 8 bytes) instead of a 20-step shift chain:
    // LLVM lowers these to byte-swapped loads, where the u256 loop becomes byte shuffling.
    const bytes = &addr.bytes;
    const high: u256 = std.mem.readInt(u32, bytes[0..4], .big);
    const middle: u256 = std.mem.readInt(u64, bytes[4..12], .big);
    const low: u256 = std.mem.readInt(u64, bytes[12..20], .big);
    const value = (high << 128) | (middle << 64) | low;
    return @as(WordType, @truncate(value));
}

/// Convert WordType to Address (lower 160 bits)
pub fn fromWord(comptime WordType: type, value: WordType) Address {
    // If WordType is smaller than u256, just zero-extend
    const value_u256: u256 = if (@bitSizeOf(WordType) < 256) @as(u256, value) else value;
    // Take the lower 160 bits (20 bytes)
    const addr_value = @as(u160, @truncate(value_u256));
    var addr_bytes: [20]u8 = undefined;
    std.mem.writeInt(u160, &addr_bytes, addr_value, .big);
    return Address{ .bytes = addr_bytes };
}
