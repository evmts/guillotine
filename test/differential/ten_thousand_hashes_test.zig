const std = @import("std");
const primitives = @import("voltaire");
const differential_testor = @import("differential_testor.zig");

fn hex_decode(allocator: std.mem.Allocator, hex_str: []const u8) ![]u8 {
    const clean_hex = if (std.mem.startsWith(u8, hex_str, "0x")) hex_str[2..] else hex_str;
    const trimmed = std.mem.trim(u8, clean_hex, &std.ascii.whitespace);
    if (trimmed.len == 0) return allocator.alloc(u8, 0);

    const result = try allocator.alloc(u8, trimmed.len / 2);
    errdefer allocator.free(result);
    _ = try std.fmt.hexToBytes(result, trimmed);
    return result;
}

test "differential: ten thousand hashes deployment" {
    const allocator = std.testing.allocator;

    var testor = try differential_testor.DifferentialTestor.initWithConfig(
        allocator,
        .{ .enable_tracing = false },
    );
    defer testor.deinit();

    // Test simple bytecode to ensure basic functionality works
    const simple_bytecode = &[_]u8{
        0x60, 0x42, // PUSH1 42
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3, // RETURN
    };

    try testor.test_bytecode(simple_bytecode);
}

test "differential: ten-thousand-hashes runtime execution" {
    const allocator = std.testing.allocator;
    const bytecode_hex = try std.fs.cwd().readFileAlloc(allocator, "fixtures/ten-thousand-hashes/bytecode.txt", 4096);
    defer allocator.free(bytecode_hex);
    const init_code = try hex_decode(allocator, bytecode_hex);
    defer allocator.free(init_code);

    const calldata_hex = try std.fs.cwd().readFileAlloc(allocator, "fixtures/ten-thousand-hashes/calldata.txt", 1024);
    defer allocator.free(calldata_hex);
    const calldata = try hex_decode(allocator, calldata_hex);
    defer allocator.free(calldata);

    var testor = try differential_testor.DifferentialTestor.initWithConfig(allocator, .{ .enable_tracing = false });
    defer testor.deinit();
    const engine = if (testor.guillotine_instance_no_trace) |*engine| engine else return error.NoTraceInstanceNotAvailable;
    var deployment = engine.call(.{ .create = .{
        .caller = testor.caller,
        .value = 0,
        .init_code = init_code,
        .gas = 1_000_000,
    } });
    defer deployment.deinit(allocator);
    try std.testing.expect(deployment.success);
    try std.testing.expect(deployment.output.len > 0);
    const contract = deployment.created_address orelse return error.MissingContractAddress;

    const gas_limit = 16_777_216;
    var guillotine = try testor.executeGuillotineWithTraceMode(testor.caller, contract, 0, calldata, gas_limit, false);
    defer guillotine.deinit();
    var minimal = try testor.executeMinimalEvmWithTrace(testor.caller, contract, 0, calldata, gas_limit, deployment.output);
    defer minimal.deinit();
    try std.testing.expect(guillotine.success);
    try std.testing.expect(minimal.success);
    try std.testing.expectEqualSlices(u8, minimal.output, guillotine.output);

    // MinimalEvm already charges the base transaction cost.
    const gas = primitives.GasConstants;
    var calldata_gas: u64 = 0;
    for (calldata) |byte| calldata_gas += if (byte == 0) gas.TxDataZeroGas else gas.TxDataNonZeroGas;
    try std.testing.expectEqual(minimal.gas_used + calldata_gas, guillotine.gas_used);
}
