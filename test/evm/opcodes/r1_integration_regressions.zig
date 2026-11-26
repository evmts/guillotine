//! Regression tests for the Round 1 cross-lane integration fixes.

const std = @import("std");
const evm = @import("evm");
const primitives = @import("voltaire");

const Vm = evm.Evm(.{});
const Address = primitives.Address;

// The call arena reports growth to `Evm.tracer` through a raw pointer. `init`
// returns the Evm by value, so the pointer may only live while a call runs at a
// fixed address. After the call it must be cleared, or a moved Evm would make
// the arena write through a pointer into the old location.
test "R1 integration: call_arena tracer pointer does not outlive the call" {
    const allocator = std.testing.allocator;
    var db = evm.Database.init(allocator);
    defer db.deinit();

    const origin = Address{ .bytes = @as([20]u8, @splat(0xA1)) };
    const target = Address{ .bytes = @as([20]u8, @splat(0xB1)) };
    const code = [_]u8{0x00}; // STOP
    const code_hash = try db.set_code(&code);
    var account = evm.Account.zero();
    account.code_hash = code_hash;
    try db.set_account(target.bytes, account);

    var vm = try Vm.init(
        allocator,
        &db,
        evm.BlockInfo.init(),
        .{ .gas_limit = 1_000_000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 },
        0,
        origin,
    );
    defer vm.deinit();
    try std.testing.expect(vm.call_arena.tracer == null);

    var result = vm.call(.{ .call = .{
        .caller = origin,
        .to = target,
        .value = 0,
        .input = &.{},
        .gas = 100_000,
    } });
    defer result.deinit(allocator);
    try std.testing.expect(result.success);
    try std.testing.expect(vm.call_arena.tracer == null);
}
