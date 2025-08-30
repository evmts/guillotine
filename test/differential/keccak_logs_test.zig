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

test "differential: LOG0 emits without topics" {
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

    // Push offset(0), length(4) for LOG0 (no topics)
    try bc.appendSlice(allocator, &[_]u8{ 0x60, 0x00, 0x60, 0x04, 0xa0 });

    // Stop (no output). Both REVM and Guillotine should consume same gas on LOG0.
    try bc.append(allocator, 0x00);

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

test "differential: LOG2 emits with two topics" {
    const allocator = testing.allocator;
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();

    var bc = std.ArrayList(u8){};
    defer bc.deinit(allocator);

    // Write 8 bytes at memory[0]
    try bc.appendSlice(allocator, &[_]u8{ 0x60, 0x11, 0x60, 0x00, 0x53 });
    try bc.appendSlice(allocator, &[_]u8{ 0x60, 0x22, 0x60, 0x01, 0x53 });
    try bc.appendSlice(allocator, &[_]u8{ 0x60, 0x33, 0x60, 0x02, 0x53 });
    try bc.appendSlice(allocator, &[_]u8{ 0x60, 0x44, 0x60, 0x03, 0x53 });
    try bc.appendSlice(allocator, &[_]u8{ 0x60, 0x55, 0x60, 0x04, 0x53 });
    try bc.appendSlice(allocator, &[_]u8{ 0x60, 0x66, 0x60, 0x05, 0x53 });
    try bc.appendSlice(allocator, &[_]u8{ 0x60, 0x77, 0x60, 0x06, 0x53 });
    try bc.appendSlice(allocator, &[_]u8{ 0x60, 0x88, 0x60, 0x07, 0x53 });

    // Push offset(0), length(8), topic1(0x01), topic2(0x02) for LOG2
    try bc.appendSlice(allocator, &[_]u8{ 0x60, 0x00, 0x60, 0x08, 0x60, 0x01, 0x60, 0x02, 0xa2 });

    // Stop (no output)
    try bc.append(allocator, 0x00);

    try testor.test_bytecode(bc.items);
}

test "differential: LOG3 emits with three topics" {
    const allocator = testing.allocator;
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();

    var bc = std.ArrayList(u8){};
    defer bc.deinit(allocator);

    // Write 12 bytes at memory[0]
    for (0..12) |i| {
        try bc.appendSlice(allocator, &[_]u8{ 0x60, @intCast(0x10 + i), 0x60, @intCast(i), 0x53 });
    }

    // Push offset(0), length(12), topic1(0x01), topic2(0x02), topic3(0x03) for LOG3
    try bc.appendSlice(allocator, &[_]u8{ 0x60, 0x00, 0x60, 0x0C, 0x60, 0x01, 0x60, 0x02, 0x60, 0x03, 0xa3 });

    // Stop (no output)
    try bc.append(allocator, 0x00);

    try testor.test_bytecode(bc.items);
}

test "differential: LOG4 emits with four topics" {
    const allocator = testing.allocator;
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();

    var bc = std.ArrayList(u8){};
    defer bc.deinit(allocator);

    // Write 16 bytes at memory[0]
    for (0..16) |i| {
        try bc.appendSlice(allocator, &[_]u8{ 0x60, @intCast(0x20 + i), 0x60, @intCast(i), 0x53 });
    }

    // Push offset(0), length(16), topic1(0x01), topic2(0x02), topic3(0x03), topic4(0x04) for LOG4
    try bc.appendSlice(allocator, &[_]u8{ 0x60, 0x00, 0x60, 0x10, 0x60, 0x01, 0x60, 0x02, 0x60, 0x03, 0x60, 0x04, 0xa4 });

    // Stop (no output)
    try bc.append(allocator, 0x00);

    try testor.test_bytecode(bc.items);
}

test "differential: LOG opcodes with zero-length data" {
    const allocator = testing.allocator;
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();

    var bc = std.ArrayList(u8){};
    defer bc.deinit(allocator);

    // LOG0 with zero-length data
    try bc.appendSlice(allocator, &[_]u8{ 0x60, 0x00, 0x60, 0x00, 0xa0 }); // LOG0(offset=0, length=0)

    // LOG1 with zero-length data but one topic
    try bc.appendSlice(allocator, &[_]u8{ 0x60, 0x00, 0x60, 0x00, 0x60, 0x42, 0xa1 }); // LOG1(offset=0, length=0, topic=0x42)

    // LOG4 with zero-length data but four topics
    try bc.appendSlice(allocator, &[_]u8{ 
        0x60, 0x00, 0x60, 0x00, // offset=0, length=0
        0x60, 0x01, 0x60, 0x02, 0x60, 0x03, 0x60, 0x04, // topics
        0xa4 // LOG4
    });

    // Stop
    try bc.append(allocator, 0x00);

    try testor.test_bytecode(bc.items);
}

test "differential: LOG opcodes with large data" {
    const allocator = testing.allocator;
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();

    var bc = std.ArrayList(u8){};
    defer bc.deinit(allocator);

    // Write 64 bytes of data to memory
    for (0..64) |i| {
        try bc.appendSlice(allocator, &[_]u8{ 0x60, @intCast(i), 0x60, @intCast(i), 0x53 });
    }

    // LOG2 with 64 bytes of data and topics
    try bc.appendSlice(allocator, &[_]u8{ 
        0x60, 0x00, 0x60, 0x40, // offset=0, length=64
        0x7f, 0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // PUSH32 topic1
        0x7f, 0xCA, 0xFE, 0xBA, 0xBE, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // PUSH32 topic2
        0xa2 // LOG2
    });

    // Stop
    try bc.append(allocator, 0x00);

    try testor.test_bytecode(bc.items);
}
