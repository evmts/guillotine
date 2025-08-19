const std = @import("std");
const testing = std.testing;
const Evm = @import("evm");
const Address = @import("Address").Address;

test {
    // Enable ALL debug logging
    // std.testing.log_level = .warn;
}

// Custom log function that writes to both stdout and file
var log_file: ?std.fs.File = null;

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    // Write to stdout
    const prefix = "[" ++ @tagName(level) ++ "] " ++
        if (scope == .default) "" else "(" ++ @tagName(scope) ++ ") ";

    const stderr = std.io.getStdErr().writer();
    std.debug.lockStdErr();
    defer std.debug.unlockStdErr();
    nosuspend stderr.print(prefix ++ format ++ "\n", args) catch return;

    // Also write to file if available
    if (log_file) |file| {
        const writer = file.writer();
        nosuspend writer.print(prefix ++ format ++ "\n", args) catch return;
    }
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

test "trace ERC20 execution to file" {
    const allocator = testing.allocator;

    // Open log file
    log_file = try std.fs.cwd().createFile("erc20_full_trace.log", .{});
    defer {
        if (log_file) |file| {
            file.close();
            log_file = null;
        }
    }

    // Set custom log function
    std.log.scoped(.default).override = logFn;

    const bytecode = try readHexFile(allocator, "test/evm/erc20_mint.hex");
    defer allocator.free(bytecode);

    const calldata = try hexDecode(allocator, "30627b7c");
    defer allocator.free(calldata);

    std.log.info("=== Starting ERC20 mint test with full trace to file ===", .{});
    std.log.info("Bytecode length: {}", .{bytecode.len});
    std.log.info("Calldata: {x}", .{calldata});
    std.log.info("Full execution trace will be written to: erc20_full_trace.log", .{});

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
    std.log.info("=== DEPLOYING CONTRACT ===", .{});
    const create_result = try vm.create_contract(caller, 0, bytecode, 1_000_000_000);
    if (!create_result.success) {
        std.log.err("Deployment failed - gas_left: {}, success: {}", .{ create_result.gas_left, create_result.success });
        if (create_result.output) |_| {
            std.log.err("Revert data: {x}", .{output});
            if (output.len >= 4) {
                const selector = std.mem.readInt(u32, output[0..4], .big);
                std.log.err("Revert selector: 0x{x:0>8}", .{selector});
                if (selector == 0x4e487b71 and output.len >= 36) {
                    const panic_code = std.mem.readInt(u32, output[32..36], .big);
                    std.log.err("Solidity panic code: 0x{x}", .{panic_code});
                }
            }
        }
        std.log.info("=== TRACE COMPLETE - See erc20_full_trace.log ===", .{});
        try testing.expect(false);
    }

    const contract_address = create_result.address;
    std.log.info("Contract deployed at: {any}", .{contract_address});

    // Call contract
    std.log.info("=== CALLING CONTRACT ===", .{});
    std.log.info("Calling Benchmark() function with selector: {x}", .{calldata});

    const call_result = try vm.call_contract(caller, contract_address, 0, calldata, 1_000_000_000, false);
    std.log.info("=== CALL COMPLETE ===", .{});
    std.log.info("Call result - gas_left: {}, success: {}, gas_used: {}", .{ call_result.gas_left, call_result.success, 1_000_000_000 - call_result.gas_left });

    if (call_result.output) |_| {
        std.log.info("Output length: {}, data: {x}", .{ output.len, output });
    }

    std.log.info("=== TRACE COMPLETE - See erc20_full_trace.log ===", .{});

    try testing.expect(call_result.success);
}
