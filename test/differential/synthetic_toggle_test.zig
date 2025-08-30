const std = @import("std");
const DifferentialTestor = @import("differential_testor.zig").DifferentialTestor;

const testing = std.testing;

fn small_add_program(allocator: std.mem.Allocator) ![]u8 {
    var bc = std.ArrayList(u8){};
    errdefer bc.deinit(allocator);
    // PUSH1 2; DUP1; PUSH1 3; SWAP1; ADD; MSTORE 0; RETURN 32
    // The DUP+SWAP sequence breaks PUSH+ADD fusion, exercising non-synthetic handlers
    try bc.appendSlice(allocator, &[_]u8{ 0x60, 0x02, 0x80, 0x60, 0x03, 0x90, 0x01, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3 });
    return bc.toOwnedSlice(allocator);
}

test "differential: add operation non-fuseable pattern" {
    const allocator = testing.allocator;
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();

    const bc = try small_add_program(allocator);
    defer allocator.free(bc);

    try testor.test_bytecode(bc);
}
