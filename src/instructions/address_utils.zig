const std = @import("std");
const Address = @import("voltaire").Address;

/// Convert Address to WordType (zero-extended to word size)
pub fn toWord(comptime WordType: type, addr: Address) WordType {
    const bytes = addr.bytes;
    var value: u256 = 0;
    for (bytes) |byte| {
        value = (value << 8) | @as(u256, byte);
    }
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
