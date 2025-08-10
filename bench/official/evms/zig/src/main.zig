const std = @import("std");
const evm = @import("evm");
const primitives = @import("primitives");

const print = std.debug.print;
const Address = primitives.Address.Address;
const CallParams = evm.CallParams;
const CallResult = evm.CallResult;

const CALLER_ADDRESS = "0x1000000000000000000000000000000000000001";

// Updated to new API - migration in progress, tests not run yet

pub const std_options: std.Options = .{
    .log_level = .debug,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const gpa_allocator = gpa.allocator();

    // Use normal allocator (EVM will handle internal arena allocation)
    const allocator = gpa_allocator;

    // Parse command line arguments (use GPA for args, not EVM allocator)
    const args = try std.process.argsAlloc(gpa_allocator);
    defer std.process.argsFree(gpa_allocator, args);

    if (args.len < 5) {
        std.debug.print("Usage: {s} --contract-code-path <path> --calldata <hex> [--num-runs <n>] [--next]\n", .{args[0]});
        std.debug.print("Example: {s} --contract-code-path bytecode.txt --calldata 0x12345678\n", .{args[0]});
        std.debug.print("Options:\n", .{});
        std.debug.print("  --next    Use block-based execution (new optimized interpreter)\n", .{});
        std.process.exit(1);
    }

    var contract_code_path: ?[]const u8 = null;
    var calldata_hex: ?[]const u8 = null;
    var num_runs: u8 = 1;
    var use_block_execution = false;

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

    const contract_code_hex = try contract_code_file.readToEndAlloc(gpa_allocator, 10 * 1024 * 1024); // 10MB max
    defer gpa_allocator.free(contract_code_hex);

    // Trim whitespace
    const trimmed_code = std.mem.trim(u8, contract_code_hex, " \t\n\r");

    // Decode hex to bytes
    const contract_code = try hexToBytes(gpa_allocator, trimmed_code);
    defer gpa_allocator.free(contract_code);

    // Decode calldata
    const trimmed_calldata = std.mem.trim(u8, calldata_hex.?, " \t\n\r");
    const calldata = try hexToBytes(gpa_allocator, trimmed_calldata);
    defer gpa_allocator.free(calldata);

    // Parse caller address
    const caller_address = try primitives.Address.from_hex(CALLER_ADDRESS);

    // Initialize EVM database
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

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
        null, // tracer (set to stdout.any() to enable JSON tracing)
    );
    defer vm.deinit();

    // Set up caller account with max balance
    try vm.state.set_balance(caller_address, std.math.maxInt(u256));

    const contract_address = try deployContract(allocator, &vm, caller_address, contract_code);
    const deployed = vm.state.get_code(contract_address);
    std.debug.print("[zig-runner] deployed code len={} at {any}\n", .{deployed.len, contract_address});

    // Run benchmarks
    var run: u8 = 0;
    while (run < num_runs) : (run += 1) {
        // Execute contract using new call API
        const call_params = CallParams{ .call = .{
            .caller = caller_address,
            .to = contract_address,
            .value = 0,
            .input = calldata,
            .gas = 1_000_000_000,
        }};

        const result = vm.call(call_params) catch |err| {
            std.debug.print("Contract execution error: {}\n", .{err});
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

        // Note: output ownership is transferred to us, free if present
        if (result.output) |output| {
            allocator.free(output);
        }
    }
}

fn deployContract(allocator: std.mem.Allocator, vm: *evm.Evm, caller: Address, bytecode: []const u8) !Address {
    // Attempt 1: Treat input as initcode and use create_contract
    const create_result = vm.create_contract(caller, 0, bytecode, 50_000_000) catch |err| blk: {
        std.debug.print("[zig-runner] create_contract error: {}\n", .{err});
        break :blk null;
    };
    if (create_result) |res| {
        if (res.success) {
            if (res.output) |out| allocator.free(out);
            return res.address;
        }
        if (res.output) |out| {
            std.debug.print("[zig-runner] create_contract failed; revert/output hex: 0x{X}\n", .{std.fmt.fmtSliceHexLower(out)});
            allocator.free(out);
        } else {
            std.debug.print("[zig-runner] create_contract failed with no output\n", .{});
        }
    }

    // Attempt 2: Treat input as runtime bytecode and set directly
    const contract_addr = try primitives.Address.from_hex("0x5FbDB2315678afecb367f032d93F642f64180aa3");
    try vm.state.set_code(contract_addr, bytecode);
    std.debug.print("[zig-runner] Fallback: set runtime code at deterministic address {any}\n", .{contract_addr});
    return contract_addr;
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
