const std = @import("std");
const testing = std.testing;
const Evm = @import("evm");
const Address = @import("Address").Address;

test {
    std.testing.log_level = .warn;
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

test "trace ERC20 mint execution" {
    const allocator = testing.allocator;

    // Read the ERC20 bytecode
    const file_content = try std.fs.cwd().readFileAlloc(allocator, "test/evm/erc20_mint.hex", 1024 * 1024);
    defer allocator.free(file_content);

    const bytecode = try hexDecode(allocator, std.mem.trim(u8, file_content, " \n\r\t"));
    defer allocator.free(bytecode);

    // Setup EVM with tracer
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();

    // Create trace output
    var trace_buffer = std.ArrayList(u8).init(allocator);
    defer trace_buffer.deinit();

    var builder = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    _ = builder.withTracer(trace_buffer.writer().any());

    var vm = try builder.build();
    defer vm.deinit();

    const caller = Address.from_u256(0x1000000000000000000000000000000000000001);
    const caller_balance = std.math.maxInt(u256);
    try vm.state.set_balance(caller, caller_balance);

    // Deploy contract
    std.debug.print("\n=== Deploying ERC20 Contract ===\n", .{});
    const create_result = try vm.create_contract(caller, 0, bytecode, 1_000_000_000 // 1B gas for deployment
    );
    defer if (create_result.output) |output| allocator.free(output);

    std.debug.print("Deployment result - success: {}, gas_left: {}, gas_used: {}\n", .{ create_result.success, create_result.gas_left, 1_000_000_000 - create_result.gas_left });

    if (!create_result.success) {
        std.debug.print("Deployment failed!\n", .{});

        // Write trace to file for analysis
        const trace_file = try std.fs.cwd().createFile("zig_erc20_mint_deploy_trace.json", .{});
        defer trace_file.close();
        try trace_file.writeAll(trace_buffer.items);

        std.debug.print("Deployment trace written to zig_erc20_mint_deploy_trace.json\n", .{});
        return;
    }

    const contract_address = create_result.address;
    std.debug.print("Contract deployed at: {any}\n", .{contract_address});

    // Clear trace for the mint call
    trace_buffer.clearRetainingCapacity();

    // Call the mint function (selector: 30627b7c)
    const calldata = try hexDecode(allocator, "30627b7c");
    defer allocator.free(calldata);

    std.debug.print("\n=== Calling mint function ===\n", .{});
    const call_result = try vm.call_contract(caller, contract_address, 0, calldata, 1_000_000_000, false);
    defer if (call_result.output) |output| allocator.free(output);

    std.debug.print("Call result - success: {}, gas_left: {}, gas_used: {}\n", .{ call_result.success, call_result.gas_left, 1_000_000_000 - call_result.gas_left });

    if (call_result.output) |output| {
        std.debug.print("Output length: {}\n", .{output.len});
        if (output.len > 0) {
            std.debug.print("Output (hex): ", .{});
            for (output) |byte| {
                std.debug.print("{x:0>2}", .{byte});
            }
            std.debug.print("\n", .{});
        }
    }

    // Write trace to file
    const trace_file = try std.fs.cwd().createFile("zig_erc20_mint_trace.json", .{});
    defer trace_file.close();
    try trace_file.writeAll(trace_buffer.items);

    std.debug.print("\nTrace written to zig_erc20_mint_trace.json\n", .{});
}
