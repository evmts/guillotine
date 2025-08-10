const std = @import("std");
const testing = std.testing;
const evm = @import("evm");
const primitives = @import("primitives");

const Address = primitives.Address;
const Evm = evm.Evm;
const MemoryDatabase = evm.MemoryDatabase;

test "GT opcode comparison bug" {
    // This test reproduces the GT opcode bug that causes JUMPI to fail
    const allocator = testing.allocator;

    // This bytecode reproduces the exact sequence that fails in ERC20:
    // It pushes two values and compares them with GT, then uses JUMPI
    const bytecode = &[_]u8{
        // Push the values that cause the issue
        0x7f, // PUSH32
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01, // 0xffffff...ff01
        0x7f, // PUSH32
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, // 0xffffff...ffff

        // Now do the comparison
        0x11, // GT - should return 1 (true) since top > second (0xff...ffff > 0xff...ff01)
        0x15, // ISZERO - should return 0 (false) since GT returned 1

        // Test with JUMPI
        0x60, 0x4A, // PUSH1 0x4A (jump destination at PC 74)
        0x57, // JUMPI - should NOT jump since condition is 0

        // If we don't jump (expected behavior), we hit this
        0x60, 0x00, // PUSH1 0x00
        0x00, // STOP

        // Jump destination at PC 74 (0x4A)
        0x5b, // JUMPDEST
        0x60, 0x01, // PUSH1 0x01
        0x00, // STOP
    };

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();

    // Run with trace enabled
    var trace_buffer = std.ArrayList(u8).init(allocator);
    defer trace_buffer.deinit();

    const config = evm.EvmConfig.init(.CANCUN);
    const EvmType = evm.Evm(config);
    var vm = try EvmType.init(allocator, db_interface, trace_buffer.writer().any(), 0, false, null);
    defer vm.deinit();

    const caller = Address.from_u256(0x1000000000000000000000000000000000000001);
    const contract_addr = Address.from_u256(0x2000000000000000000000000000000000000002);

    try vm.state.set_balance(caller, std.math.maxInt(u256));
    try vm.state.set_code(contract_addr, bytecode);

    // Create contract to execute
    var contract = evm.Contract.init(
        caller, // caller
        contract_addr, // address
        0, // value
        1_000_000, // gas
        bytecode, // code
        [_]u8{0} ** 32, // code_hash
        &.{}, // input
        false, // is_static
    );

    const result = try vm.interpret(&contract, &.{}, false);
    defer if (result.output) |output| allocator.free(output);

    // Print the trace
    std.debug.print("\nExecution trace:\n{s}\n", .{trace_buffer.items});

    // Check if we jumped correctly
    // If the bug is present, we'll have STOP at PC 72 instead of PC 77
    var lines = std.mem.tokenizeScalar(u8, trace_buffer.items, '\n');
    var last_pc: usize = 0;
    while (lines.next()) |line| {
        const parsed = try std.json.parseFromSlice(TraceEntry, allocator, line, .{});
        defer parsed.deinit();
        last_pc = parsed.value.pc;
    }

    // The last PC should be 73 (STOP after PUSH1 0x00, no jump taken)
    try testing.expectEqual(@as(usize, 73), last_pc);
}

const TraceEntry = struct {
    pc: usize,
    op: u8,
    gas: ?[]const u8 = null,
    gasCost: ?[]const u8 = null,
    stack: []const []const u8,
    depth: ?u32 = null,
    returnData: ?[]const u8 = null,
    refund: ?[]const u8 = null,
    memSize: ?usize = null,
    opName: ?[]const u8 = null,
};

test "GT opcode manual check" {
    // Manual test to check GT opcode behavior

    // Create two u256 values that reproduce the issue
    const a: u256 = 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff01;
    const b: u256 = 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;

    // When we push a then b, the stack has: [a, b] with b at top
    // GT computes: b > a (top > second)
    // So we're checking: 0xff...ff > 0xff...01 = true
    const gt_result = if (b > a) @as(u256, 1) else 0;
    const iszero_result = if (gt_result == 0) @as(u256, 1) else 0;

    std.debug.print("\nManual GT check:\n", .{});
    std.debug.print("  a = 0x{x}\n", .{a});
    std.debug.print("  b = 0x{x}\n", .{b});
    std.debug.print("  b > a = {} (0xff...ff > 0xff...01 = true)\n", .{gt_result});
    std.debug.print("  iszero(b > a) = {} (iszero(1) = 0)\n", .{iszero_result});

    // GT returns 1 because b > a
    try testing.expectEqual(@as(u256, 1), gt_result);
    try testing.expectEqual(@as(u256, 0), iszero_result);
}
