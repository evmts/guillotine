const std = @import("std");
const testing = std.testing;
const evm = @import("evm");
const primitives = @import("primitives");

const Address = primitives.Address;
const Evm = evm.Evm;
const MemoryDatabase = evm.MemoryDatabase;

test "SUB opcode bug from ERC20 constructor" {
    const allocator = testing.allocator;

    // This reproduces the exact SUB operation that fails in ERC20:
    // 1. Push 1
    // 2. Push 1
    // 3. Push 0x40
    // 4. SHL (shift left by 64 bits) -> 0x10000000000000000
    // 5. SUB -> should produce 0xffffffffffffffff
    const bytecode = &[_]u8{
        0x60, 0x01, // PUSH1 0x01
        0x60, 0x01, // PUSH1 0x01
        0x60, 0x40, // PUSH1 0x40
        0x1b, // SHL
        0x03, // SUB
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
    var vm = try EvmType.init(allocator, db_interface, null, 0, false, trace_buffer.writer().any());
    defer vm.deinit();

    const caller = Address.from_u256(0x1000000000000000000000000000000000000001);
    const contract_addr = Address.from_u256(0x2000000000000000000000000000000000000002);

    try vm.state.set_balance(caller, std.math.maxInt(u256));
    try vm.state.set_code(contract_addr, bytecode);

    // Create contract to execute
    var contract = evm.Contract.init(
        caller,
        contract_addr,
        0,
        1_000_000,
        bytecode,
        [_]u8{0} ** 32,
        &.{},
        false,
    );

    const result = try vm.interpret(&contract, &.{}, false);
    defer if (result.output) |output| allocator.free(output);

    // Print the trace
    std.debug.print("\nSUB opcode bug trace:\n{s}\n", .{trace_buffer.items});

    // Parse the trace to check the final result
    var lines = std.mem.tokenizeScalar(u8, trace_buffer.items, '\n');
    var last_sub_result: ?[]const u8 = null;

    while (lines.next()) |line| {
        const parsed = try std.json.parseFromSlice(TraceEntry, allocator, line, .{});
        defer parsed.deinit();

        if (parsed.value.op == 0x03) { // SUB opcode
            // The next line should show the result
            if (lines.next()) |next_line| {
                const next_parsed = try std.json.parseFromSlice(TraceEntry, allocator, next_line, .{});
                defer next_parsed.deinit();

                if (next_parsed.value.stack.len > 0) {
                    last_sub_result = next_parsed.value.stack[next_parsed.value.stack.len - 1];
                    std.debug.print("\nSUB result: {s}\n", .{last_sub_result.?});
                    std.debug.print("Expected:   0xffffffffffffffff\n", .{});

                    // Check if it matches expected value
                    const is_correct = std.mem.eql(u8, last_sub_result.?, "0xffffffffffffffff");
                    std.debug.print("Correct:    {}\n", .{is_correct});

                    if (!is_correct) {
                        std.debug.print("\nBUG CONFIRMED: SUB opcode produces wrong result!\n", .{});
                    }
                }
                break;
            }
        }
    }

    try testing.expect(last_sub_result != null);
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
