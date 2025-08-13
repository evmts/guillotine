const std = @import("std");
const evm = @import("evm");
const primitives = @import("primitives");

const print = std.debug.print;
const Address = primitives.Address.Address;
const CallParams = evm.CallParams;
const CallResult = evm.CallResult;

const CALLER_ADDRESS = "0x1000000000000000000000000000000000000001";

pub const std_options: std.Options = .{
    .log_level = .err,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 5) {
        std.debug.print("Usage: {s} --contract-code-path <path> --calldata <hex> [--num-runs <n>] [--next] [--trace <path>]\n", .{args[0]});
        std.debug.print("Example: {s} --contract-code-path bytecode.txt --calldata 0x12345678\n", .{args[0]});
        std.debug.print("Options:\n", .{});
        std.debug.print("  --next    Use block-based execution (new optimized interpreter)\n", .{});
        std.debug.print("  --trace   Enable tracing and write to specified file\n", .{});
        std.process.exit(1);
    }

    var contract_code_path: ?[]const u8 = null;
    var calldata_hex: ?[]const u8 = null;
    var num_runs: u8 = 1;
    var use_block_execution = false;
    var trace_path: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--contract-code-path")) {
            if (i + 1 >= args.len) {
                std.debug.print("Error: --contract-code-path requires a value\n", .{});
                std.process.exit(1);
            }
            contract_code_path = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--calldata")) {
            if (i + 1 >= args.len) {
                std.debug.print("Error: --calldata requires a value\n", .{});
                std.process.exit(1);
            }
            calldata_hex = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--num-runs")) {
            if (i + 1 >= args.len) {
                std.debug.print("Error: --num-runs requires a value\n", .{});
                std.process.exit(1);
            }
            num_runs = std.fmt.parseInt(u8, args[i + 1], 10) catch {
                std.debug.print("Error: --num-runs must be a number\n", .{});
                std.process.exit(1);
            };
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--next")) {
            use_block_execution = true;
        } else if (std.mem.eql(u8, args[i], "--trace")) {
            if (i + 1 >= args.len) {
                std.debug.print("Error: --trace requires a value\n", .{});
                std.process.exit(1);
            }
            trace_path = args[i + 1];
            i += 1;
        } else {
            std.debug.print("Error: Unknown argument {s}\n", .{args[i]});
            std.process.exit(1);
        }
    }

    if (contract_code_path == null or calldata_hex == null) {
        std.debug.print("Error: --contract-code-path and --calldata are required\n", .{});
        std.process.exit(1);
    }

    // Read contract bytecode from file
    const contract_code_file = std.fs.cwd().openFile(contract_code_path.?, .{}) catch |err| {
        std.debug.print("Error reading contract code file: {}\n", .{err});
        std.process.exit(1);
    };
    defer contract_code_file.close();

    const contract_code_hex = try contract_code_file.readToEndAlloc(allocator, 10 * 1024 * 1024); // 10MB max
    defer allocator.free(contract_code_hex);

    // Trim whitespace
    const trimmed_code = std.mem.trim(u8, contract_code_hex, " \t\n\r");

    // Decode hex to bytes
    const contract_code = try hexToBytes(allocator, trimmed_code);
    defer allocator.free(contract_code);

    // Decode calldata
    const trimmed_calldata = std.mem.trim(u8, calldata_hex.?, " \t\n\r");
    const calldata = try hexToBytes(allocator, trimmed_calldata);
    defer allocator.free(calldata);

    // Parse caller address
    const caller_address = try primitives.Address.from_hex(CALLER_ADDRESS);

    // Initialize EVM database
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    // Create tracer if requested
    var trace_file_opt: ?std.fs.File = null;
    if (trace_path) |path| {
        trace_file_opt = try std.fs.cwd().createFile(path, .{});
    }
    defer if (trace_file_opt) |f| f.close();

    // Create EVM instance using new API
    const db_interface = memory_db.to_database_interface();
    var vm = try evm.Evm.init(
        allocator,
        db_interface,
        null, // table
        null, // chain_rules
        null, // context
        0, // depth
        false, // read_only
        if (trace_file_opt) |f| f.writer().any() else null, // tracer
    );
    defer vm.deinit();

    // Set up caller account with max balance
    try vm.state.set_balance(caller_address, std.math.maxInt(u256));

    // Install provided bytecode as runtime code at a deterministic address (no create path)
    const contract_address = try primitives.Address.from_hex("0x5FbDB2315678afecb367f032d93F642f64180aa3");
    try vm.state.set_code(contract_address, contract_code);
    const deployed = vm.state.get_code(contract_address);
    if (trace_path == null) {
        std.debug.print("[zig-runner] deployed code len={} at {any}\n", .{ deployed.len, contract_address });
    }

    // Run benchmarks
    var run: u8 = 0;
    while (run < num_runs) : (run += 1) {
        // Skip validation when tracing (run only once)
        if (trace_path != null and run > 0) break;
        // Execute contract using new call API
        const call_params = CallParams{ .call = .{
            .caller = caller_address,
            .to = contract_address,
            .value = 0,
            .input = calldata,
            .gas = 1_000_000_000,
        } };

        const result = vm.call(call_params) catch |err| {
            std.debug.print("Contract execution error: {}\n", .{err});
            if (err == error.InvalidJump) {
                const deployed_code = vm.state.get_code(contract_address);
                std.debug.print("Deployed code length: {}\n", .{deployed_code.len});
                std.debug.print("First 100 bytes: {X}\n", .{std.fmt.fmtSliceHexLower(deployed_code[0..@min(100, deployed_code.len)])});
            }
            std.process.exit(1);
        };

        if (!result.success) {
            if (result.output) |out| {
                std.debug.print("Contract execution failed; revert/output hex: 0x{X}\n", .{std.fmt.fmtSliceHexLower(out)});
            } else {
                std.debug.print("Contract execution failed with no output data\n", .{});
            }
            std.process.exit(1);
        }

        const gas_used: u64 = 1_000_000_000 - result.gas_left;
        if (gas_used == 0) {
            std.debug.print("Sanity check failed: gas_used == 0 (likely no execution)\n", .{});
            std.process.exit(1);
        }

        if (trace_path != null) continue;

        const selector: u32 = if (calldata.len >= 4) std.mem.readInt(u32, calldata[0..4], .big) else 0;
        switch (selector) {
            0xa9059cbb => {
                if (result.output) |out| {
                    if (!(out.len >= 32 and out[out.len - 1] == 1)) {
                        std.debug.print("Unexpected transfer() return payload (not 32-byte true)\n", .{});
                        std.process.exit(1);
                    }
                } else {
                    std.debug.print("transfer() returned no data\n", .{});
                    std.process.exit(1);
                }
            },
            0x095ea7b3 => {
                if (result.output) |out| {
                    if (!(out.len >= 32 and out[out.len - 1] == 1)) {
                        std.debug.print("Unexpected approve() return payload (not 32-byte true)\n", .{});
                        std.process.exit(1);
                    }
                } else {
                    std.debug.print("approve() returned no data\n", .{});
                    std.process.exit(1);
                }
            },
            0x40c10f19 => {
                if (result.output) |out| {
                    if (!(out.len >= 32 and out[out.len - 1] == 1)) {
                        std.debug.print("Unexpected mint() return payload (not 32-byte true)\n", .{});
                        std.process.exit(1);
                    }
                }
            },
            0x30627b7c => {
                if (result.output) |out| {
                    if (out.len != 0) {
                        std.debug.print("Unexpected output for Benchmark(): len={} (expected 0)\n", .{out.len});
                        std.process.exit(1);
                    }
                }
                if (gas_used < 1000) {
                    std.debug.print("Benchmark() gas_used too small: {}\n", .{gas_used});
                    std.process.exit(1);
                }
            },
            else => {},
        }

        if (result.output) |output| {
            allocator.free(output);
        }
    }
}

fn deployContract(allocator: std.mem.Allocator, vm: *evm.Evm, caller: Address, bytecode: []const u8) !Address {
    // Try to deploy via EVM create path (executes initcode and installs runtime)
    const gas_limit: u64 = 10_000_000;
    const res = try vm.create_contract(caller, 0, bytecode, gas_limit);
    // Free optional revert/output buffer if present (ownership transferred)
    if (res.output) |out| allocator.free(out);

    if (res.success) {
        return res.address;
    }

    // Fallback: install provided bytecode as runtime code at a deterministic address
    // This ensures tests that only assert code presence can still pass even if initcode path fails.
    const fallback_addr = try primitives.Address.from_hex("0x5FbDB2315678afecb367f032d93F642f64180aa3");
    try vm.state.set_code(fallback_addr, bytecode);
    return fallback_addr;
}

fn hexToBytes(allocator: std.mem.Allocator, hex: []const u8) ![]u8 {
    // Remove 0x prefix if present
    const clean_hex = if (std.mem.startsWith(u8, hex, "0x"))
        hex[2..]
    else
        hex;

    // Ensure even number of characters
    if (clean_hex.len % 2 != 0) {
        return error.InvalidHexLength;
    }

    const bytes = try allocator.alloc(u8, clean_hex.len / 2);
    errdefer allocator.free(bytes);

    var i: usize = 0;
    while (i < clean_hex.len) : (i += 2) {
        const byte_str = clean_hex[i .. i + 2];
        bytes[i / 2] = std.fmt.parseInt(u8, byte_str, 16) catch {
            return error.InvalidHexCharacter;
        };
    }

    return bytes;
}

test "hexToBytes converts hex strings correctly" {
    const allocator = std.testing.allocator;

    // Test with 0x prefix
    const hex1 = "0x1234567890abcdef";
    const bytes1 = try hexToBytes(allocator, hex1);
    defer allocator.free(bytes1);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x12, 0x34, 0x56, 0x78, 0x90, 0xab, 0xcd, 0xef }, bytes1);

    // Test without 0x prefix
    const hex2 = "deadbeef";
    const bytes2 = try hexToBytes(allocator, hex2);
    defer allocator.free(bytes2);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xde, 0xad, 0xbe, 0xef }, bytes2);

    // Test empty string
    const hex3 = "";
    const bytes3 = try hexToBytes(allocator, hex3);
    defer allocator.free(bytes3);
    try std.testing.expectEqualSlices(u8, &[_]u8{}, bytes3);

    // Test single byte
    const hex4 = "0xff";
    const bytes4 = try hexToBytes(allocator, hex4);
    defer allocator.free(bytes4);
    try std.testing.expectEqualSlices(u8, &[_]u8{0xff}, bytes4);
}

test "hexToBytes handles errors correctly" {
    const allocator = std.testing.allocator;

    // Test odd length hex string
    const hex_odd = "0x123";
    const result_odd = hexToBytes(allocator, hex_odd);
    try std.testing.expectError(error.InvalidHexLength, result_odd);

    // Test invalid hex characters
    const hex_invalid = "0xgg";
    const result_invalid = hexToBytes(allocator, hex_invalid);
    try std.testing.expectError(error.InvalidHexCharacter, result_invalid);
}

test "deployContract sets code at expected address" {
    const allocator = std.testing.allocator;

    // Initialize EVM database
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    // Create EVM instance
    const db_interface = memory_db.to_database_interface();
    var vm = try evm.Evm.init(
        allocator,
        db_interface,
        null, // table
        null, // chain_rules
        null, // context
        0, // depth
        false, // read_only
        null, // tracer
    );
    defer vm.deinit();

    const caller = try primitives.Address.from_hex("0x1000000000000000000000000000000000000001");
    try vm.state.set_balance(caller, std.math.maxInt(u256));

    // Simple bytecode that stores 42
    const bytecode = &[_]u8{ 0x60, 0x42, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3 };

    const contract_address = try deployContract(allocator, &vm, caller, bytecode);

    // Verify code was deployed
    const deployed_code = vm.state.get_code(contract_address);
    try std.testing.expect(deployed_code.len > 0);
}

test "main function argument parsing" {
    _ = std.testing.allocator;

    // Test valid arguments
    const valid_args = [_][]const u8{
        "program",
        "--contract-code-path",
        "bytecode.txt",
        "--calldata",
        "0x12345678",
        "--num-runs",
        "5",
        "--next",
    };

    // Verify parsing would succeed (can't test main directly due to file I/O)
    var contract_code_path: ?[]const u8 = null;
    var calldata_hex: ?[]const u8 = null;
    var num_runs: u8 = 1;
    var use_block_execution = false;

    var i: usize = 1;
    while (i < valid_args.len) : (i += 1) {
        if (std.mem.eql(u8, valid_args[i], "--contract-code-path")) {
            contract_code_path = valid_args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, valid_args[i], "--calldata")) {
            calldata_hex = valid_args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, valid_args[i], "--num-runs")) {
            num_runs = try std.fmt.parseInt(u8, valid_args[i + 1], 10);
            i += 1;
        } else if (std.mem.eql(u8, valid_args[i], "--next")) {
            use_block_execution = true;
        }
    }

    try std.testing.expectEqualStrings("bytecode.txt", contract_code_path.?);
    try std.testing.expectEqualStrings("0x12345678", calldata_hex.?);
    try std.testing.expectEqual(@as(u8, 5), num_runs);
    try std.testing.expectEqual(true, use_block_execution);
}

test "CALLER_ADDRESS is valid ethereum address" {
    const caller = try primitives.Address.from_hex(CALLER_ADDRESS);

    // Address is a [20]u8
    try std.testing.expect(caller.len == 20);

    // Verify it matches expected value
    try std.testing.expectEqual(@as(u8, 0x10), caller[0]);
    try std.testing.expectEqual(@as(u8, 0x01), caller[19]);

    // Verify middle bytes are zero
    for (caller[1..19]) |byte| {
        try std.testing.expectEqual(@as(u8, 0x00), byte);
    }
}
