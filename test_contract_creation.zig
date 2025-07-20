const std = @import("std");

test "test contract creation components" {
    std.testing.log_level = .debug;
    
    std.log.debug("Testing std.crypto.hash.sha3.Keccak256...", .{});
    
    const test_data = "hello world";
    var hash: [32]u8 = undefined;
    
    // This is what Contract.init_at_address() calls internally
    var hasher = std.crypto.hash.sha3.Keccak256.init(.{});
    hasher.update(test_data);
    hasher.final(&hash);
    
    std.log.debug("Keccak256 hash computed successfully", .{});
    std.log.debug("Hash: {x}", .{std.fmt.fmtSliceHexLower(&hash)});
}