const std = @import("std");
const testing = std.testing;
const Evm = @import("evm");
const Address = @import("Address").Address;

test {
    std.testing.log_level = .debug;
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

test "trace ERC20 deployment only" {
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
    
    const config = Evm.EvmConfig.init(.CANCUN);
    const EvmType = Evm.Evm(config);
    var vm = try EvmType.init(allocator, db_interface, null, 0, false, trace_buffer.writer().any());
    defer vm.deinit();

    const caller = Address.from_u256(0x1000000000000000000000000000000000000001);
    const caller_balance = std.math.maxInt(u256);
    try vm.state.set_balance(caller, caller_balance);

    // Deploy contract
    std.debug.print("\n=== Deploying ERC20 Contract ===\n", .{});
    const create_result = try vm.create_contract(
        caller,
        0,
        bytecode,
        1_000_000_000 // 1B gas for deployment
    );
    defer if (create_result.output) |output| allocator.free(output);

    std.debug.print("Deployment result - success: {}, gas_left: {}, gas_used: {}\n", .{
        create_result.success,
        create_result.gas_left,
        1_000_000_000 - create_result.gas_left
    });

    // Write trace to file
    const trace_file = try std.fs.cwd().createFile("zig_erc20_deploy_trace.json", .{});
    defer trace_file.close();
    try trace_file.writeAll(trace_buffer.items);
    
    std.debug.print("Trace written to zig_erc20_deploy_trace.json\n", .{});
}