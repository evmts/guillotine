const std = @import("std");
const evm = @import("evm");
const primitives = @import("primitives");

// Enable debug logging
test {
    std.testing.log_level = .warn;
}

fn hexDecode(allocator: std.mem.Allocator, hex_str: []const u8) ![]u8 {
    const clean_hex = if (std.mem.startsWith(u8, hex_str, "0x")) hex_str[2..] else hex_str;
    const result = try allocator.alloc(u8, clean_hex.len / 2);
    _ = try std.fmt.hexToBytes(result, clean_hex);
    return result;
}

fn readCaseFile(allocator: std.mem.Allocator, comptime case_name: []const u8, comptime file_name: []const u8) ![]u8 {
    const path = "/Users/williamcory/Guillotine/bench/official/cases/" ++ case_name ++ "/" ++ file_name;
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    const content = try file.readToEndAlloc(allocator, 16 * 1024 * 1024);
    const trimmed = std.mem.trim(u8, content, " \t\n\r");
    if (trimmed.ptr == content.ptr and trimmed.len == content.len) {
        return content;
    }
    defer allocator.free(content);
    const result = try allocator.alloc(u8, trimmed.len);
    @memcpy(result, trimmed);
    return result;
}

test "debug ten-thousand-hashes execution" {
    const allocator = std.testing.allocator;

    std.debug.print("\n=== DEBUGGING 10K HASHES TEST ===\n", .{});

    // Load bytecode and calldata from official case
    const bytecode_hex = try readCaseFile(allocator, "ten-thousand-hashes", "bytecode.txt");
    defer allocator.free(bytecode_hex);
    const calldata_hex = try readCaseFile(allocator, "ten-thousand-hashes", "calldata.txt");
    defer allocator.free(calldata_hex);

    std.debug.print("Bytecode hex length: {}\n", .{bytecode_hex.len});
    std.debug.print("Calldata hex: {s}\n", .{calldata_hex});

    const bytecode = try hexDecode(allocator, bytecode_hex);
    defer allocator.free(bytecode);
    const calldata = try hexDecode(allocator, calldata_hex);
    defer allocator.free(calldata);

    std.debug.print("Bytecode length: {} bytes\n", .{bytecode.len});
    std.debug.print("Calldata length: {} bytes\n", .{calldata.len});
    std.debug.print("First 32 bytes of bytecode: ", .{});
    for (bytecode[0..@min(32, bytecode.len)]) |b| {
        std.debug.print("{x:0>2} ", .{b});
    }
    std.debug.print("\n", .{});

    // Set up VM with tracing
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();

    // Create a tracer that outputs to stderr
    const stderr = std.io.getStdErr().writer();
    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, stderr.any());
    defer vm.deinit();

    // Caller and funding
    const caller = primitives.Address.from_u256(0x1000000000000000000000000000000000000001);
    try vm.state.set_balance(caller, std.math.maxInt(u256));

    // First, let's try to deploy the contract using CREATE
    std.debug.print("\n--- Attempting contract deployment ---\n", .{});
    const initial_deploy_gas: u64 = 10_000_000;

    const create_result = try vm.create_contract(caller, 0, bytecode, initial_deploy_gas);

    std.debug.print("Deployment result: success={}, gas_left={}, address={x}\n", .{
        create_result.success,
        create_result.gas_left,
        primitives.Address.to_u256(create_result.address),
    });

    if (create_result.output) |output| {
        std.debug.print("Deployment output length: {} bytes\n", .{output.len});
        if (output.len > 0) {
            std.debug.print("First 32 bytes of deployed code: ", .{});
            for (output[0..@min(32, output.len)]) |b| {
                std.debug.print("{x:0>2} ", .{b});
            }
            std.debug.print("\n", .{});
        }
    } else {
        std.debug.print("No deployment output\n", .{});
    }

    if (!create_result.success) {
        std.debug.print("Deployment failed!\n", .{});
        return error.DeploymentFailed;
    }

    const contract_address = create_result.address;

    // Check what code was actually deployed
    const deployed_code = vm.state.get_code(contract_address);
    std.debug.print("\nDeployed code at contract address: {} bytes\n", .{deployed_code.len});

    // Now call the contract
    std.debug.print("\n--- Calling contract with selector 0x{x} ---\n", .{
        if (calldata.len >= 4) std.mem.readInt(u32, calldata[0..4], .big) else 0,
    });

    const initial_gas: u64 = 10_000_000;
    const params = evm.CallParams{ .call = .{
        .caller = caller,
        .to = contract_address,
        .value = 0,
        .input = calldata,
        .gas = initial_gas,
    } };

    const call_result = try vm.call(params);

    std.debug.print("\nCall result: success={}, gas_left={}\n", .{
        call_result.success,
        call_result.gas_left,
    });

    if (call_result.output) |output| {
        std.debug.print("Output length: {} bytes\n", .{output.len});
        if (output.len > 0) {
            std.debug.print("Output: ", .{});
            for (output) |b| {
                std.debug.print("{x:0>2} ", .{b});
            }
            std.debug.print("\n", .{});
        }
    }

    const gas_used = initial_gas - call_result.gas_left;
    std.debug.print("\nGas used: {}\n", .{gas_used});
    std.debug.print("Expected: > 100,000\n", .{});

    try std.testing.expect(call_result.success);
    try std.testing.expect(gas_used > 100_000);
}
