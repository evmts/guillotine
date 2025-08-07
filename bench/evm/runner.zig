const std = @import("std");

fn print(comptime format: []const u8, args: anytype) !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print(format, args);
}
const testing = std.testing;
const primitives = @import("Address");
const Address = primitives.Address.Address;
const Evm = @import("evm");
const CallParams = @import("evm").CallParams;

// Command-line arguments structure
const Args = struct {
    contract_code_path: []const u8,
    calldata: []const u8,
    num_runs: u8,
};

const CALLER_ADDRESS_U256: u256 = 0x1000000000000000000000000000000000000001;

// Override log level to suppress debug output for clean benchmark results
pub const std_options: std.Options = .{
    .log_level = .err, // Only show errors
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse command line arguments
    const args = try parseArgs(allocator);
    defer allocator.free(args.contract_code_path);
    defer allocator.free(args.calldata);

    // Create caller address from u256 constant
    const caller_address = primitives.Address.from_u256(CALLER_ADDRESS_U256);

    // Read and decode contract code
    const contract_code_hex = try std.fs.cwd().readFileAlloc(allocator, args.contract_code_path, 1024 * 1024);
    defer allocator.free(contract_code_hex);
    
    const contract_code = try hexDecode(allocator, std.mem.trim(u8, contract_code_hex, " \n\r\t"));
    defer allocator.free(contract_code);

    // Decode calldata
    const calldata = try hexDecode(allocator, args.calldata);
    defer allocator.free(calldata);

    // Create EVM state once - outside the loop
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.Evm.init(
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

    // Set up caller account with large balance
    const caller_balance = std.math.maxInt(u256);
    try vm.state.set_balance(caller_address, caller_balance);

    // Deploy the contract once
    const contract_address = try deployContract(&vm, allocator, caller_address, contract_code);

    // Pre-allocate call result to avoid allocations in loop
    var call_result: Evm.CallResult = undefined;

    // Run the benchmark num_runs times
    var i: u8 = 0;
    while (i < args.num_runs) : (i += 1) {
        const timer = std.time.nanoTimestamp();
        
        // Execute the contract call directly without error handling
        const call_params = CallParams{ .call = .{
            .caller = caller_address,
            .to = contract_address,
            .value = 0,
            .input = calldata,
            .gas = 1_000_000_000,
        }};
        call_result = vm.call(call_params) catch |err| {
            std.debug.print("Contract execution failed: {}\n", .{err});
            std.process.exit(1);
        };
        
        const duration_ns = std.time.nanoTimestamp() - timer;
        const duration_ms = @as(f64, @floatFromInt(duration_ns)) / 1_000_000.0;
        
        // Validate successful execution
        if (!call_result.success) {
            std.debug.print("Contract execution failed\n", .{});
            std.process.exit(1);
        }
        
        // Free output if allocated
        if (call_result.output.len > 0) {
            allocator.free(call_result.output);
        }
        
        // Output timing
        const duration_ms_rounded = @as(u64, @intFromFloat(@round(duration_ms)));
        if (duration_ms_rounded == 0) {
            try print("1\n", .{});
        } else {
            try print("{d}\n", .{duration_ms_rounded});
        }
    }
}

fn parseArgs(allocator: std.mem.Allocator) !Args {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var contract_code_path: ?[]const u8 = null;
    var calldata: ?[]const u8 = null;
    var num_runs: u8 = 1;

    var i: usize = 1;
    while (i < args.len) {
        const arg = args[i];
        
        if (std.mem.eql(u8, arg, "--contract-code-path")) {
            i += 1;
            contract_code_path = try allocator.dupe(u8, args[i]);
        } else if (std.mem.eql(u8, arg, "--calldata")) {
            i += 1;
            calldata = try allocator.dupe(u8, args[i]);
        } else if (std.mem.eql(u8, arg, "--num-runs") or std.mem.eql(u8, arg, "-n")) {
            i += 1;
            num_runs = try std.fmt.parseInt(u8, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try print("Zig EVM runner interface\n\n", .{});
            try print("Usage: runner [OPTIONS]\n\n", .{});
            try print("Options:\n", .{});
            try print("  --contract-code-path <PATH>  Path to the hex contract code to deploy and run\n", .{});
            try print("  --calldata <HEX>            Hex of calldata to use when calling the contract\n", .{});
            try print("  -n, --num-runs <N>          Number of times to run the benchmark [default: 1]\n", .{});
            try print("  -h, --help                  Print help information\n", .{});
            std.process.exit(0);
        }
        i += 1;
    }

    return Args{
        .contract_code_path = contract_code_path.?,
        .calldata = calldata.?,
        .num_runs = num_runs,
    };
}

fn hexDecode(allocator: std.mem.Allocator, hex_str: []const u8) ![]u8 {
    // Remove 0x prefix if present
    const clean_hex = if (std.mem.startsWith(u8, hex_str, "0x"))
        hex_str[2..]
    else
        hex_str;

    const result = try allocator.alloc(u8, clean_hex.len / 2);
    _ = try std.fmt.hexToBytes(result, clean_hex);
    return result;
}

fn deployContract(vm: *Evm.Evm, allocator: std.mem.Allocator, caller: Address, bytecode: []const u8) !Address {
    const create_result = try vm.create_contract(
        caller,
        0,
        bytecode,
        10_000_000
    );
    defer if (create_result.output) |output| allocator.free(output);

    return create_result.address;
}