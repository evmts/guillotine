// Minimal differential test to isolate EXP bug
const std = @import("std");
const testing = std.testing;
const DifferentialTestor = @import("test/differential/differential_testor.zig").DifferentialTestor;

test "differential: minimal EXP test - 2^3 should be 8" {
    const allocator = testing.allocator;
    
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    
    // Minimal EXP test: just 2^3 = 8
    const bytecode = [_]u8{
        0x60, 0x02, // PUSH1 2 (base)
        0x60, 0x03, // PUSH1 3 (exponent)  
        0x0a,       // EXP (2^3 = 8)
        0x60, 0x00, // PUSH1 0 (memory offset)
        0x52,       // MSTORE (store result in memory)
        0x60, 0x20, // PUSH1 32 (return size)  
        0x60, 0x00, // PUSH1 0 (return offset)
        0xf3,       // RETURN
    };
    
    std.debug.print("\n=== Testing minimal EXP: 2^3 ===\n", .{});
    std.debug.print("Expected result: 8\n", .{});
    std.debug.print("Bytecode length: {}\n", .{bytecode.len});
    
    try testor.test_bytecode(&bytecode);
}