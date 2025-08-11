const std = @import("std");
const evm = @import("evm");
const primitives = @import("primitives");

// Minimal dynamic JUMP reproduction: JUMP to dest, write 32-byte true, RETURN 32 bytes
// Bytecode:
//   0x00: PUSH1 0x03
//   0x02: JUMP
//   0x03: JUMPDEST
//   0x04: PUSH1 0x01
//   0x06: PUSH1 0x00
//   0x08: MSTORE            ; memory[0..31]=0, memory[31]=1
//   0x09: PUSH1 0x20
//   0x0B: PUSH1 0x00
//   0x0D: RETURN           ; return 32 bytes from memory[0]
const runtime: []const u8 = &[_]u8{
    0x60, 0x03, // PUSH1 0x03 (dest index)
    0x56, // JUMP
    0x5b, // JUMPDEST
    0x60, 0x01, // PUSH1 0x01 (value)
    0x60, 0x00, // PUSH1 0x00 (offset)
    0x52, // MSTORE
    0x60, 0x20, // PUSH1 0x20 (len)
    0x60, 0x00, // PUSH1 0x00 (offset)
    0xf3, // RETURN
};

test "dynamic jump minimal returns 32-byte true" {
    const allocator = std.testing.allocator;

    // Set up VM with in-memory DB
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();

    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    const caller = primitives.Address.from_u256(0x1000000000000000000000000000000000000001);
    const callee = primitives.Address.from_u256(0x2000000000000000000000000000000000000002);
    try vm.state.set_balance(caller, std.math.maxInt(u256));

    // Deploy runtime code directly to target address
    try vm.state.set_code(callee, runtime);

    const initial_gas: u64 = 1_000_000;
    const params = evm.CallParams{ .call = .{
        .caller = caller,
        .to = callee,
        .value = 0,
        .input = &.{},
        .gas = initial_gas,
    } };

    const call_result = try vm.call(params);
    try std.testing.expect(call_result.success);
    const gas_used = initial_gas - call_result.gas_left;
    try std.testing.expect(gas_used > 0);

    // Expect 32-byte true (last byte == 1)
    try std.testing.expect(call_result.output != null);
    const output = call_result.output.?;
    defer allocator.free(output);
    try std.testing.expect(output.len == 32);
    try std.testing.expect(output[31] == 1);
}
