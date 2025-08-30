const std = @import("std");
const DifferentialTestor = @import("differential_testor.zig").DifferentialTestor;

const testing = std.testing;

fn push1(builder: *std.ArrayList(u8), allocator: std.mem.Allocator, v: u8) !void {
    try builder.append(allocator, 0x60);
    try builder.append(allocator, v);
}

fn mstore_return(builder: *std.ArrayList(u8), allocator: std.mem.Allocator, offset: u8, size: u8) !void {
    // MSTORE [offset] <- top
    try push1(builder, allocator, offset);
    try builder.append(allocator, 0x52);
    // RETURN [offset, size]
    try push1(builder, allocator, size);
    try push1(builder, allocator, offset);
    try builder.append(allocator, 0xf3);
}

test "differential: stack POP, DUP, SWAP basics" {
    const allocator = testing.allocator;

    // POP: push then pop, then push 1 and return
    {
        var testor = try DifferentialTestor.init(allocator);
        defer testor.deinit();

        var bc = std.ArrayList(u8){};
        defer bc.deinit(allocator);

        try push1(&bc, allocator, 0x2a); // PUSH1 42
        try bc.append(allocator, 0x50); // POP
        try push1(&bc, allocator, 0x01); // push 1
        try mstore_return(&bc, allocator, 0x00, 0x20);

        try testor.test_bytecode(bc.items);
    }

    // DUP4 over 4-stack depth -> expect top becomes former 4th (value 1)
    {
        var testor = try DifferentialTestor.init(allocator);
        defer testor.deinit();

        var bc = std.ArrayList(u8){};
        defer bc.deinit(allocator);

        try push1(&bc, allocator, 0x01);
        try push1(&bc, allocator, 0x02);
        try push1(&bc, allocator, 0x03);
        try push1(&bc, allocator, 0x04);
        try bc.append(allocator, 0x80 + 3); // DUP4
        try mstore_return(&bc, allocator, 0x00, 0x20);

        try testor.test_bytecode(bc.items);
    }

    // SWAP3 with stack [1,2,3,4] (top=4) -> top becomes 1
    {
        var testor = try DifferentialTestor.init(allocator);
        defer testor.deinit();

        var bc = std.ArrayList(u8){};
        defer bc.deinit(allocator);

        try push1(&bc, allocator, 0x01);
        try push1(&bc, allocator, 0x02);
        try push1(&bc, allocator, 0x03);
        try push1(&bc, allocator, 0x04);
        try bc.append(allocator, 0x90 + 2); // SWAP3 (0x90 + (3-1))
        try mstore_return(&bc, allocator, 0x00, 0x20);

        try testor.test_bytecode(bc.items);
    }
}

test "differential: DUP1..DUP16 sweep" {
    const allocator = testing.allocator;
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();

    // For each DUPk, build a tiny bytecode and verify top value duplicated
    var k: u8 = 1;
    while (k <= 16) : (k += 1) {
        var bc = std.ArrayList(u8){};
        defer bc.deinit(allocator);

        // Push 1..k
        var v: u8 = 1;
        while (v <= k) : (v += 1) {
            try push1(&bc, allocator, v);
        }
        // DUPk
        try bc.append(allocator, 0x80 + (k - 1));
        // Return duplicated top-of-stack
        try mstore_return(&bc, allocator, 0x00, 0x20);

        try testor.test_bytecode(bc.items);
    }
}

test "differential: SWAP1..SWAP16 sweep" {
    const allocator = testing.allocator;
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();

    // Stack: push 1..(n+1), then SWAPn -> top becomes value at depth n+1 (which is 1)
    var n: u8 = 1;
    while (n <= 16) : (n += 1) {
        var bc = std.ArrayList(u8){};
        defer bc.deinit(allocator);

        // Push 1..(n+1)
        var v: u8 = 1;
        while (v <= (n + 1)) : (v += 1) {
            try push1(&bc, allocator, v);
        }
        // SWAPn
        try bc.append(allocator, 0x90 + (n - 1));
        // Return top-of-stack (expected 1)
        try mstore_return(&bc, allocator, 0x00, 0x20);

        try testor.test_bytecode(bc.items);
    }
}
