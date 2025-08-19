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

test "trace ERC20 full deployment and call" {
    const allocator = testing.allocator;

    // Read the ERC20 bytecode
    const file_content = try std.fs.cwd().readFileAlloc(allocator, "test/evm/erc20_mint.hex", 1024 * 1024);
    defer allocator.free(file_content);

    const bytecode = try hexDecode(allocator, std.mem.trim(u8, file_content, " \n\r\t"));
    defer allocator.free(bytecode);

    const calldata = try hexDecode(allocator, "30627b7c");
    defer allocator.free(calldata);

    // Setup EVM with tracer
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();

    // Create trace output for deployment
    var deploy_trace_buffer = std.ArrayList(u8).init(allocator);
    defer deploy_trace_buffer.deinit();

    var builder = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    _ = builder.withTracer(deploy_trace_buffer.writer().any());

    var vm = try builder.build();
    defer vm.deinit();

    const caller = Address.from_u256(0x1000000000000000000000000000000000000001);
    const caller_balance = std.math.maxInt(u256);
    try vm.state.set_balance(caller, caller_balance);

    // Deploy contract
    const create_result = try vm.create_contract(caller, 0, bytecode, 1_000_000_000 // 1B gas for deployment
    );

    // Write deployment trace
    const deploy_trace_file = try std.fs.cwd().createFile("zig_erc20_deploy_trace_full.json", .{});
    defer deploy_trace_file.close();
    try deploy_trace_file.writeAll(deploy_trace_buffer.items);

    if (!create_result.success) {
        return;
    }

    const contract_address = create_result.address;

    // Now rebuild VM with fresh tracer for the call
    vm.deinit();

    // Create new trace buffer for call
    var call_trace_buffer = std.ArrayList(u8).init(allocator);
    defer call_trace_buffer.deinit();

    var builder2 = Evm.EvmBuilder.init(allocator, db_interface);
    _ = builder2.withTracer(call_trace_buffer.writer().any());

    var vm2 = try builder2.build();
    defer vm2.deinit();

    // Call the mint function
    const call_result = try vm2.call_contract(caller, contract_address, 0, calldata, 1_000_000_000, false);

    if (!call_result.success) {

        // Find the last few operations before failure
        var lines = std.mem.tokenizeScalar(u8, call_trace_buffer.items, '\n');
        var last_lines = [_][]const u8{&.{}} ** 10;
        var line_idx: usize = 0;

        while (lines.next()) |line| {
            last_lines[line_idx % 10] = line;
            line_idx += 1;
        }

        const start_idx = if (line_idx > 10) (line_idx - 10) else 0;
        for (0..@min(10, line_idx)) |_| {
            const idx = (start_idx + i) % 10;
        }
    }

    // Write call trace
    const call_trace_file = try std.fs.cwd().createFile("zig_erc20_call_trace_full.json", .{});
    defer call_trace_file.close();
    try call_trace_file.writeAll(call_trace_buffer.items);

}
