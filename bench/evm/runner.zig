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
    disable_trace: bool,
};

const CALLER_ADDRESS_U256: u256 = 0x1000000000000000000000000000000000000001;

// Override log level to suppress debug output for clean benchmark results
pub const std_options: std.Options = .{
    .log_level = .debug,
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

    const contract_code_hex_trimmed = std.mem.trim(u8, contract_code_hex, " \n\r\t");
    const decoded = try hexDecode(allocator, contract_code_hex_trimmed);
    defer allocator.free(decoded);
    const contract_code = extractRuntime(decoded);

    // Decode calldata
    const calldata = try hexDecode(allocator, args.calldata);
    defer allocator.free(calldata);

    // Create EVM state once - outside the loop
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();

    // Set up tracer based on disable_trace flag
    const stdout = std.io.getStdOut().writer();
    const tracer: ?std.io.AnyWriter = if (args.disable_trace) null else stdout.any();

    var vm = try Evm.Evm.init(
        allocator,
        db_interface,
        null, // table
        null, // chain_rules
        null, // context
        0, // depth
        false, // read_only
        tracer, // tracer
    );
    defer vm.deinit();

    // Set up caller account with large balance
    const caller_balance = std.math.maxInt(u256);
    try vm.state.set_balance(caller_address, caller_balance);

    // Deploy the contract once
    const contract_address = try deployContract(&vm, allocator, caller_address, contract_code);
    // Sanity: ensure code is present
    const deployed_code = vm.state.get_code(contract_address);
    std.debug.print("[runner] deployed code len={} at {any}\n", .{ deployed_code.len, contract_address });

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
        } };
        call_result = vm.call(call_params) catch |err| {
            std.debug.print("Contract execution failed: {}\n", .{err});
            std.process.exit(1);
        };
        if (!call_result.success) {
            std.debug.print("[runner] call failed; gas_left={}, output_len={}\n", .{ call_result.gas_left, if (call_result.output) |o| o.len else 0 });
        }

        const duration_ns = std.time.nanoTimestamp() - timer;
        const duration_ms = @as(f64, @floatFromInt(duration_ns)) / 1_000_000.0;

        // Validate successful execution
        if (!call_result.success) {
            if (call_result.output) |out| {
                std.debug.print("Contract failed; revert/output hex: 0x{X}\n", .{std.fmt.fmtSliceHexLower(out)});
            } else {
                std.debug.print("Contract failed with no output data\n", .{});
            }
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
    var disable_trace: bool = false;

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
        } else if (std.mem.eql(u8, arg, "--disable-trace")) {
            disable_trace = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try print("Zig EVM runner interface\n\n", .{});
            try print("Usage: runner [OPTIONS]\n\n", .{});
            try print("Options:\n", .{});
            try print("  --contract-code-path <PATH>  Path to the hex contract code to deploy and run\n", .{});
            try print("  --calldata <HEX>            Hex of calldata to use when calling the contract\n", .{});
            try print("  -n, --num-runs <N>          Number of times to run the benchmark [default: 1]\n", .{});
            try print("  --disable-trace             Disable execution tracing output\n", .{});
            try print("  -h, --help                  Print help information\n", .{});
            std.process.exit(0);
        }
        i += 1;
    }

    return Args{
        .contract_code_path = contract_code_path.?,
        .calldata = calldata.?,
        .num_runs = num_runs,
        .disable_trace = disable_trace,
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

fn extractRuntime(bytecode: []const u8) []const u8 {
    // 1) Preferred: split on 0xFE (INVALID) if present
    var i: isize = @intCast(bytecode.len);
    while (i > 0) : (i -= 1) {
        const idx: usize = @intCast(i - 1);
        if (bytecode[idx] == 0xfe) {
            if (idx + 1 < bytecode.len) return bytecode[idx + 1 ..];
            return &[_]u8{};
        }
    }

    // 2) Heuristic: detect common initcode prologue and extract runtime
    // Pattern: PUSH2 <len> (0x61) DUP1 (0x80) PUSH2 <off> (0x61) PUSH1 0 (0x60 0x00)
    //          CODECOPY (0x39) PUSH1 0 (0x60 0x00) RETURN (0xF3) <runtime bytes>
    if (bytecode.len >= 12 and
        bytecode[0] == 0x61 and // PUSH2 <len>
        bytecode[3] == 0x80 and // DUP1
        bytecode[4] == 0x61 and // PUSH2 <off>
        bytecode[7] == 0x60 and bytecode[8] == 0x00 and // PUSH1 0
        bytecode[9] == 0x39 and // CODECOPY
        bytecode[10] == 0x60 and bytecode[11] == 0x00 // PUSH1 0
    ) {
        // RETURN is expected to follow soon after
        var ret_idx: usize = 12;
        while (ret_idx < bytecode.len and ret_idx < 32) : (ret_idx += 1) {
            if (bytecode[ret_idx] == 0xF3) break;
        }
        if (ret_idx < bytecode.len and bytecode[ret_idx] == 0xF3) {
            // Extract length from first PUSH2
            const len: usize = (@as(usize, bytecode[1]) << 8) | @as(usize, bytecode[2]);
            const start: usize = ret_idx + 1;
            if (start < bytecode.len) {
                const end = @min(bytecode.len, start + len);
                return bytecode[start..end];
            }
        }
    }

    // 3) Fallback: return original (assume already runtime)
    return bytecode;
}

fn deployContract(vm: *Evm.Evm, allocator: std.mem.Allocator, caller: Address, bytecode: []const u8) !Address {
    // Attempt 1: Treat input as initcode and use create_contract
    if (try vm.create_contract(caller, 0, bytecode, 50_000_000)) |res| {
        if (res.success) {
            if (res.output) |out| allocator.free(out);
            return res.address;
        }
        if (res.output) |out| {
            std.debug.print("[deployContract] create_contract failed; revert/output hex: 0x{X}\n", .{std.fmt.fmtSliceHexLower(out)});
            allocator.free(out);
        } else {
            std.debug.print("[deployContract] create_contract failed with no output\n", .{});
        }
    }

    // Attempt 2: Extract runtime and set directly
    const runtime = extractRuntime(bytecode);
    const address: Address = [_]u8{0x22} ** 20;
    try vm.state.set_code(address, runtime);
    std.debug.print("[deployContract] Fallback: set runtime code at deterministic address {any}, len={}\n", .{ address, runtime.len });
    return address;
}
