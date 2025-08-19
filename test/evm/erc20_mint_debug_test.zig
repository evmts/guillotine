const std = @import("std");
const testing = std.testing;
const Evm = @import("evm");
const Address = @import("Address").Address;

test {
    // Enable ALL debug logging
    // std.testing.log_level = .warn;
}

fn hexDecode(allocator: std.mem.Allocator, hex_str: []const u8) ![]u8 {
    const clean_hex = if (std.mem.startsWith(u8, hex_str, "0x"))
        hex_str[2..]
    else
        hex_str;

    const result = try allocator.alloc(u8, clean_hex.len / 2);
    _ = try std.fmt.hexToBytes(result, clean_hex);
    return result;
}

fn readHexFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file_content = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
    defer allocator.free(file_content);

    return hexDecode(allocator, std.mem.trim(u8, file_content, " \n\r\t"));
}

test "debug: erc20.mint with full logging" {
    const allocator = testing.allocator;

    const bytecode = try readHexFile(allocator, "test/evm/erc20_mint.hex");
    defer allocator.free(bytecode);

    const calldata = try hexDecode(allocator, "30627b7c");
    defer allocator.free(calldata);

    std.log.debug("=== Starting ERC20 mint test with full debug logging ===", .{});
    std.log.debug("Bytecode length: {}", .{bytecode.len});
    std.log.debug("Calldata: {x}", .{calldata});

    // Create EVM
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    var vm = try builder.build();
    defer vm.deinit();

    const caller = Address.from_u256(0x1000000000000000000000000000000000000001);
    const caller_balance = std.math.maxInt(u256);
    try vm.state.set_balance(caller, caller_balance);

    // Deploy contract
    std.log.debug("=== DEPLOYING CONTRACT ===", .{});
    const create_result = try vm.create_contract(caller, 0, bytecode, 1_000_000_000);
    if (!create_result.success) {
        std.log.err("Deployment failed - gas_left: {}, success: {}", .{ create_result.gas_left, create_result.success });
        try testing.expect(false);
    }

    const contract_address = create_result.address;
    std.log.debug("Contract deployed at: {any}", .{contract_address});

    // Call contract
    std.log.debug("=== CALLING CONTRACT ===", .{});
    std.log.debug("Calling Benchmark() function with selector: {x}", .{calldata});

    const call_result = try vm.call_contract(caller, contract_address, 0, calldata, 1_000_000_000, false);
    std.log.debug("=== CALL COMPLETE ===", .{});
    std.log.debug("Call result - gas_left: {}, success: {}, gas_used: {}", .{ call_result.gas_left, call_result.success, 1_000_000_000 - call_result.gas_left });

    if (call_result.output) |_| {
        std.log.debug("Output length: {}, data: {x}", .{ output.len, output });
    }

    try testing.expect(call_result.success);
}
