const std = @import("std");
const DifferentialTestor = @import("differential_testor.zig").DifferentialTestor;

const testing = std.testing;

// Build a program that collects env values into memory and returns a block
test "differential: environmental opcodes coverage" {
    const allocator = testing.allocator;
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();

    var bc = std.ArrayList(u8){};
    defer bc.deinit(allocator);

    // small helper
    const push1 = struct { fn f(list: *std.ArrayList(u8), alloc: std.mem.Allocator, v: u8) !void { try list.append(alloc, 0x60); try list.append(alloc, v); } }.f;

    // ADDRESS -> mstore 0x00
    try bc.append(allocator, 0x30);
    try push1(&bc, allocator, 0x00);
    try bc.append(allocator, 0x52);

    // ORIGIN -> mstore 0x20
    try bc.append(allocator, 0x32);
    try push1(&bc, allocator, 0x20);
    try bc.append(allocator, 0x52);

    // CALLER -> mstore 0x40
    try bc.append(allocator, 0x33);
    try push1(&bc, allocator, 0x40);
    try bc.append(allocator, 0x52);

    // CALLVALUE -> mstore 0x60
    try bc.append(allocator, 0x34);
    try push1(&bc, allocator, 0x60);
    try bc.append(allocator, 0x52);

    // CHAINID -> mstore 0x80
    try bc.append(allocator, 0x46);
    try push1(&bc, allocator, 0x80);
    try bc.append(allocator, 0x52);

    // BASEFEE -> mstore 0xA0
    try bc.append(allocator, 0x48);
    try push1(&bc, allocator, 0xA0);
    try bc.append(allocator, 0x52);

    // GASLIMIT -> mstore 0xC0
    try bc.append(allocator, 0x45);
    try push1(&bc, allocator, 0xC0);
    try bc.append(allocator, 0x52);

    // NUMBER -> mstore 0xE0
    try bc.append(allocator, 0x43);
    try push1(&bc, allocator, 0xE0);
    try bc.append(allocator, 0x52);

    // TIMESTAMP -> mstore 0x100
    try bc.append(allocator, 0x42);
    // PUSH2 0x0100
    try bc.append(allocator, 0x61);
    try bc.append(allocator, 0x01);
    try bc.append(allocator, 0x00);
    try bc.append(allocator, 0x52);

    // PREVRANDAO -> mstore 0x120
    try bc.append(allocator, 0x44);
    try bc.append(allocator, 0x61);
    try bc.append(allocator, 0x01);
    try bc.append(allocator, 0x20);
    try bc.append(allocator, 0x52);

    // BLOBBASEFEE -> mstore 0x140
    try bc.append(allocator, 0x4a);
    try bc.append(allocator, 0x61);
    try bc.append(allocator, 0x01);
    try bc.append(allocator, 0x40);
    try bc.append(allocator, 0x52);

    // BLOBHASH(0) -> mstore 0x160
    try push1(&bc, allocator, 0x00);
    try bc.append(allocator, 0x49); // BLOBHASH
    try bc.append(allocator, 0x61);
    try bc.append(allocator, 0x01);
    try bc.append(allocator, 0x60);
    try bc.append(allocator, 0x52);

    // EXTCODEHASH(self) -> mstore 0x180
    try bc.append(allocator, 0x30); // ADDRESS
    try bc.append(allocator, 0x3f); // EXTCODEHASH
    try bc.append(allocator, 0x61);
    try bc.append(allocator, 0x01);
    try bc.append(allocator, 0x80);
    try bc.append(allocator, 0x52);

    // RETURN 0x200 bytes from 0x00
    try bc.append(allocator, 0x61);
    try bc.append(allocator, 0x02);
    try bc.append(allocator, 0x00);
    try push1(&bc, allocator, 0x00);
    try bc.append(allocator, 0xf3);

    try testor.test_bytecode(bc.items);
}
