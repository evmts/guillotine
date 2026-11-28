//! `Frame.pretty_print` reports every failure to its caller.
//!
//! The printer used to replace an unreadable memory range with an empty slice
//! and print a frame that looked valid. It now returns the error, and an
//! allocation failure at any point surfaces as an error and leaks nothing.

const std = @import("std");
const testing = std.testing;
const evm = @import("evm");
const primitives = @import("voltaire");
const Address = primitives.Address;

const Vm = evm.Evm(.{});

test "W3-16: Frame.pretty_print prints memory and calldata" {
    const allocator = testing.allocator;
    var db = evm.Database.init(allocator);
    defer db.deinit();

    const caller = Address{ .bytes = @as([20]u8, @splat(0xC1)) };
    var vm = try Vm.init(
        allocator,
        &db,
        evm.BlockInfo.init(),
        .{ .gas_limit = 16_000_000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 },
        0,
        caller,
    );
    defer vm.deinit();

    const calldata = [_]u8{ 0xde, 0xad, 0xbe, 0xef };
    var frame = try Vm.Frame.init(allocator, 100_000, caller, 7, &calldata, @ptrCast(&vm));
    defer frame.deinit(allocator);
    try frame.memory.set_data_evm(vm.getCallArenaAllocator(), 0, "guillotine");

    const printed = try frame.pretty_print(allocator);
    defer allocator.free(printed);
    try testing.expect(std.mem.indexOf(u8, printed, "FRAME STATE") != null);
    try testing.expect(std.mem.indexOf(u8, printed, "Memory [32 bytes]") != null);
    try testing.expect(std.mem.indexOf(u8, printed, "Calldata [4 bytes]") != null);
    try testing.expect(std.mem.indexOf(u8, printed, "deadbeef") != null);
    try testing.expect(std.mem.indexOf(u8, printed, "c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1") != null);
}

test "W3-16: Frame.pretty_print returns the allocation failure instead of partial output" {
    const allocator = testing.allocator;
    var db = evm.Database.init(allocator);
    defer db.deinit();

    const caller = Address{ .bytes = @as([20]u8, @splat(0xC2)) };
    var vm = try Vm.init(
        allocator,
        &db,
        evm.BlockInfo.init(),
        .{ .gas_limit = 16_000_000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 },
        0,
        caller,
    );
    defer vm.deinit();

    // Calldata and memory are both longer than the printer's previews.
    const calldata = @as([4096]u8, @splat(0xAB));
    var frame = try Vm.Frame.init(allocator, 100_000, caller, 0, &calldata, @ptrCast(&vm));
    defer frame.deinit(allocator);
    try frame.memory.set_data_evm(vm.getCallArenaAllocator(), 0, &@as([8192]u8, @splat(0x5A)));

    var failures: usize = 0;
    var fail_index: usize = 0;
    while (fail_index < 64) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_index });
        const printed = frame.pretty_print(failing.allocator()) catch |err| {
            try testing.expect(err == error.OutOfMemory or err == error.WriteFailed);
            try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
            failures += 1;
            continue;
        };
        defer failing.allocator().free(printed);
        try testing.expect(std.mem.indexOf(u8, printed, "Memory [8192 bytes]") != null);
        try testing.expect(std.mem.indexOf(u8, printed, "more bytes") != null);
        break;
    }
    try testing.expect(failures > 0);
    try testing.expect(fail_index < 64);
}
