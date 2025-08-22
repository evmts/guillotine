const std = @import("std");
const testing = std.testing;
const evm = @import("evm");
const primitives = @import("primitives");
const Address = primitives.Address;
const revm_wrapper = @import("revm");

fn hexDecode(allocator: std.mem.Allocator, hex_str: []const u8) ![]u8 {
    const clean_hex = if (std.mem.startsWith(u8, hex_str, "0x")) hex_str[2..] else hex_str;
    const result = try allocator.alloc(u8, clean_hex.len / 2);
    _ = try std.fmt.hexToBytes(result, clean_hex);
    return result;
}

fn runBothStaticcall(target_code: []const u8) !struct { revm_ok: bool, revm_out: []const u8, zig_ok: bool, zig_out: ?[]const u8 } {
    const allocator = testing.allocator;

    // REVM side
    var rvm = try revm_wrapper.Revm.init(allocator, .{});
    defer rvm.deinit();
    const caller = try Address.from_hex("0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    const target = try Address.from_hex("0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
    try rvm.setBalance(caller, 10_000_000);
    try rvm.setCode(target, target_code);

    // True STATICCALL via REVM wrapper helper
    var r = try rvm.staticcall(caller, target, &[_]u8{}, 1_000_000);
    const r_out_copy = try allocator.dupe(u8, r.output);
    defer r.deinit();

    // Guillotine side
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();
    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, null);
    defer vm.deinit();
    try vm.state.set_code(target, target_code);

    const params = evm.CallParams{ .staticcall = .{
        .caller = caller,
        .to = target,
        .input = &[_]u8{},
        .gas = 1_000_000,
    } };
    const z = try vm.call(params);

    return .{ .revm_ok = r.success, .revm_out = r_out_copy, .zig_ok = z.success, .zig_out = z.output };
}

test "STATICCALL: SSTORE under STATICCALL returns failure (0) with REVM parity" {
    const allocator = testing.allocator;
    // Contract: SSTORE(0,1); RETURN 32 bytes 0x...01 so we can see success if it executed
    // Under STATICCALL, state change is forbidden; REVM reports failure (0) and no 0x01 return
    const code = [_]u8{
        0x60, 0x01, // PUSH1 1 (value)
        0x60, 0x00, // PUSH1 0 (slot)
        0x55, // SSTORE
        0x60, 0x01, // PUSH1 1
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3, // RETURN
    };

    const res = try runBothStaticcall(&code);
    // Both should indicate failure of the call (revm_ok false, zig_ok false)
    try testing.expectEqual(res.revm_ok, res.zig_ok);
    try testing.expect(!res.revm_ok);
    // res.zig_out is VM-owned view; nothing to free
    allocator.free(res.revm_out);
}
