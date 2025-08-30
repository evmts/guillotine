const std = @import("std");
const DifferentialTestor = @import("differential_testor.zig").DifferentialTestor;

const testing = std.testing;

test "differential: SHA3 over 32 bytes" {
    const allocator = testing.allocator;
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();

    var bc = std.ArrayList(u8){};
    defer bc.deinit(allocator);

    // Store 32-byte pattern at memory[0]
    try bc.appendSlice(allocator, &[_]u8{
        0x7f,
        0xde, 0xad, 0xbe, 0xef, 0xde, 0xad, 0xbe, 0xef,
        0xde, 0xad, 0xbe, 0xef, 0xde, 0xad, 0xbe, 0xef,
        0xde, 0xad, 0xbe, 0xef, 0xde, 0xad, 0xbe, 0xef,
        0xde, 0xad, 0xbe, 0xef, 0xde, 0xad, 0xbe, 0xef,
    });
    try bc.appendSlice(allocator, &[_]u8{ 0x60, 0x00, 0x52 }); // MSTORE at 0

    // SHA3(0, 32)
    try bc.appendSlice(allocator, &[_]u8{ 0x60, 0x20, 0x60, 0x00, 0x20 });
    // Store digest at 0 and RETURN 32 bytes
    try bc.appendSlice(allocator, &[_]u8{ 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3 });

    try testor.test_bytecode(bc.items);
}

test "differential: LOG1 emits with topic" {
    const allocator = testing.allocator;
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();

    var bc = std.ArrayList(u8){};
    defer bc.deinit(allocator);

    // Write 4 bytes at memory[0]
    try bc.appendSlice(allocator, &[_]u8{ 0x60, 0x11, 0x60, 0x00, 0x53 });
    try bc.appendSlice(allocator, &[_]u8{ 0x60, 0x22, 0x60, 0x01, 0x53 });
    try bc.appendSlice(allocator, &[_]u8{ 0x60, 0x33, 0x60, 0x02, 0x53 });
    try bc.appendSlice(allocator, &[_]u8{ 0x60, 0x44, 0x60, 0x03, 0x53 });

    // Push offset(0), length(4), topic(0x01) for LOG1
    try bc.appendSlice(allocator, &[_]u8{ 0x60, 0x00, 0x60, 0x04, 0x60, 0x01, 0xa1 });

    // Stop (no output). Both REVM and Guillotine should consume same gas on LOG1.
    try bc.append(allocator, 0x00);

    try testor.test_bytecode(bc.items);
}
