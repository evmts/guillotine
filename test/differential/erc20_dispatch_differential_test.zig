const std = @import("std");
const testing = std.testing;
const evm = @import("evm");
const primitives = @import("primitives");
const Address = primitives.Address;
const revm_wrapper = @import("revm");

fn runBoth(bytecode: []const u8, calldata: []const u8, gas: u64) !struct {
    ok_revm: bool,
    out_revm: []const u8,
    ok_zig: bool,
    out_zig: ?[]const u8,
} {
    const allocator = testing.allocator;

    // REVM side
    var revm_vm = try revm_wrapper.Revm.init(allocator, .{});
    defer revm_vm.deinit();
    const caller = try Address.from_hex("0x1111111111111111111111111111111111111111");
    const contract = try Address.from_hex("0x2222222222222222222222222222222222222222");
    try revm_vm.setBalance(caller, 10_000_000);
    try revm_vm.setCode(contract, bytecode);
    var r = try revm_vm.call(caller, contract, 0, calldata, gas);
    const r_out_copy = try allocator.dupe(u8, r.output);
    defer r.deinit();

    // Zig side
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    var vm = try evm.Evm.init(allocator, memory_db.to_database_interface(), null, null, null, null);
    defer vm.deinit();
    try vm.state.set_code(contract, bytecode);
    const params = evm.CallParams{ .call = .{ .caller = caller, .to = contract, .value = 0, .input = calldata, .gas = gas } };
    const z = try vm.call(params);
    return .{ .ok_revm = r.success, .out_revm = r_out_copy, .ok_zig = z.success, .out_zig = z.output };
}

// Minimal ERC20-like dispatcher using SHR
// If selector == 0x11223344 jump to success path that returns 32-byte true
test "erc20-dispatch (SHR): Zig matches REVM on return value and success" {
    const allocator = testing.allocator;
    const bytecode = [_]u8{
        0x60, 0x00, // PUSH1 0
        0x35, // CALLDATALOAD
        0x60, 0xe0, // PUSH1 0xe0
        0x1c, // SHR
        0x63, 0x11, 0x22, 0x33, 0x44, // PUSH4 0x11223344
        0x14, // EQ
        0x60, 0x16, // PUSH1 0x16
        0x57, // JUMPI
        0x60, 0x00, // PUSH1 0
        0x60, 0x00, // PUSH1 0
        0xfd, // REVERT
        0x5b, // JUMPDEST (0x16)
        0x60, 0x01, // PUSH1 1
        0x60, 0x1f, // PUSH1 31
        0x52, // MSTORE
        0x60, 0x00, // PUSH1 0 (offset)
        0x60, 0x20, // PUSH1 32 (size)
        0xf3, // RETURN
    };

    const calldata = [_]u8{ 0x11, 0x22, 0x33, 0x44 };
    const res = try runBoth(&bytecode, &calldata, 2_000_000);
    try testing.expectEqual(res.ok_revm, res.ok_zig);
    try testing.expect(res.ok_revm);
    try testing.expect(res.out_zig != null);
    try testing.expectEqual(@as(usize, 32), res.out_revm.len);
    try testing.expectEqual(@as(usize, 32), res.out_zig.?.len);
    const v1 = std.mem.readInt(u256, res.out_revm[0..32], .big);
    const v2 = std.mem.readInt(u256, res.out_zig.?[0..32], .big);
    try testing.expectEqual(v1, v2);
    try testing.expectEqual(@as(u256, 1), v1);
    allocator.free(res.out_revm);
    if (res.out_zig) |o| allocator.free(o);
}

// Minimal ERC20-like dispatcher using AND mask 0xffffffff
test "erc20-dispatch (AND mask): Zig matches REVM on return value and success" {
    const allocator = testing.allocator;
    const bytecode = [_]u8{
        0x60, 0x00, // PUSH1 0
        0x35, // CALLDATALOAD
        0x63, 0xff, 0xff, 0xff, 0xff, // PUSH4 0xffffffff
        0x16, // AND
        0x63, 0x30, 0x62, 0x7b, 0x7c, // PUSH4 0x30627b7c
        0x14, // EQ
        0x60, 0x16, // PUSH1 0x16
        0x57, // JUMPI
        0x60, 0x00, // PUSH1 0
        0x60, 0x00, // PUSH1 0
        0xfd, // REVERT
        0x5b, // JUMPDEST @ 0x16
        0x60, 0x01, // PUSH1 1
        0x60, 0x1f, // PUSH1 31
        0x52, // MSTORE
        0x60, 0x00, // PUSH1 0
        0x60, 0x20, // PUSH1 32
        0xf3, // RETURN
    };
    const calldata = [_]u8{ 0x30, 0x62, 0x7b, 0x7c };
    const res = try runBoth(&bytecode, &calldata, 2_000_000);
    try testing.expectEqual(res.ok_revm, res.ok_zig);
    try testing.expect(res.ok_revm);
    try testing.expect(res.out_zig != null);
    try testing.expectEqual(@as(usize, 32), res.out_revm.len);
    try testing.expectEqual(@as(usize, 32), res.out_zig.?.len);
    const v1 = std.mem.readInt(u256, res.out_revm[0..32], .big);
    const v2 = std.mem.readInt(u256, res.out_zig.?[0..32], .big);
    try testing.expectEqual(v1, v2);
    try testing.expectEqual(@as(u256, 1), v1);
    allocator.free(res.out_revm);
    if (res.out_zig) |o| allocator.free(o);
}

fn minimal_dispatcher_runtime() []const u8 {
    // Same minimal dispatcher as interpreter test:
    // selector 0x11223344 -> return 32-byte 0x01, else revert
    return &[_]u8{
        0x60, 0x00,
        0x35, 0x60,
        0xe0, 0x1c,
        0x63, 0x11,
        0x22, 0x33,
        0x44, 0x14,
        0x60, 0x16,
        0x57, 0x60,
        0x00, 0x60,
        0x00, 0xfd,
        0x5b, 0x60,
        0x01, 0x60,
        0x1f, 0x52,
        0x60, 0x20,
        0x60, 0x00,
        0xf3,
    };
}

test "differential: minimal dispatcher parity for match and no-match" {
    const allocator = testing.allocator;

    const bytecode = minimal_dispatcher_runtime();
    const selector_match = [_]u8{ 0x11, 0x22, 0x33, 0x44 };
    const selector_nomatch = [_]u8{ 0xaa, 0xbb, 0xcc, 0xdd };

    // REVM setup
    const revm_settings = revm_wrapper.RevmSettings{};
    var revm_vm = try revm_wrapper.Revm.init(allocator, revm_settings);
    defer revm_vm.deinit();
    const revm_deployer = try Address.from_hex("0x1111111111111111111111111111111111111111");
    const contract = try Address.from_hex("0x2222222222222222222222222222222222222222");
    try revm_vm.setBalance(revm_deployer, 1_000_000_000_000);
    try revm_vm.setCode(contract, bytecode);

    // Guillotine setup
    const MemoryDatabase = evm.MemoryDatabase;
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();
    var vm_instance = try evm.Evm.init(allocator, db_interface, null, null, null, null);
    defer vm_instance.deinit();
    try vm_instance.state.set_code(contract, bytecode);

    const gas: u64 = 1_000_000;

    // Case: match
    var revm_match = try revm_vm.call(revm_deployer, contract, 0, &selector_match, gas);
    defer revm_match.deinit();
    const call_match = evm.CallParams{ .call = .{ .caller = contract, .to = contract, .value = 0, .input = &selector_match, .gas = gas } };
    const guillotine_match = try vm_instance.call(call_match);
    // VM owns guillotine_match.output; do not free here

    try testing.expectEqual(revm_match.success, guillotine_match.success);
    if (revm_match.success) {
        try testing.expect(guillotine_match.output != null);
        try testing.expectEqual(@as(usize, revm_match.output.len), guillotine_match.output.?.len);
        try testing.expectEqualSlices(u8, revm_match.output, guillotine_match.output.?);
    }

    // Case: no-match
    var revm_nomatch = try revm_vm.call(revm_deployer, contract, 0, &selector_nomatch, gas);
    defer revm_nomatch.deinit();
    const call_nomatch = evm.CallParams{ .call = .{ .caller = contract, .to = contract, .value = 0, .input = &selector_nomatch, .gas = gas } };
    const guillotine_nomatch = try vm_instance.call(call_nomatch);
    // VM owns guillotine_nomatch.output; do not free here

    try testing.expectEqual(revm_nomatch.success, guillotine_nomatch.success);
    if (revm_nomatch.success) {
        try testing.expect(guillotine_nomatch.output != null);
        try testing.expectEqual(@as(usize, revm_nomatch.output.len), guillotine_nomatch.output.?.len);
        try testing.expectEqualSlices(u8, revm_nomatch.output, guillotine_nomatch.output.?);
    }
}
