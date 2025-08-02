const std = @import("std");
const evm = @import("evm");
const primitives = @import("primitives");

const print = std.debug.print;
const Address = primitives.Address.Address;

const CALLER_ADDRESS = "0x1000000000000000000000000000000000000001";

pub const std_options: std.Options = .{
    .log_level = .warn,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const backing_allocator = gpa.allocator();
    
    // Use EVMAllocator for all EVM operations
    var evm_allocator = try evm.EVMAllocator.init(backing_allocator, evm.EVMAllocator.DEFAULT_CAPACITY);
    defer evm_allocator.deinit();
    const allocator = evm_allocator.allocator();

    // Parse command line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 5) {
        std.debug.print("Usage: {s} --contract-code-path <path> --calldata <hex> [--num-runs <n>]\n", .{args[0]});
        std.debug.print("Example: {s} --contract-code-path bytecode.txt --calldata 0x12345678\n", .{args[0]});
        std.process.exit(1);
    }

    var contract_code_path: ?[]const u8 = null;
    var calldata_hex: ?[]const u8 = null;
    var num_runs: u8 = 1;

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

    // Create EVM instance using builder pattern
    const db_interface = memory_db.to_database_interface();
    var evm_builder = evm.EvmBuilder.init(allocator, db_interface);
    var vm = try evm_builder.build();
    defer vm.deinit();

    // Compute hash of contract code for deployment
    var code_hash: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(contract_code, &code_hash);

    // Set up caller account with max balance
    try vm.state.set_balance(caller_address, std.math.maxInt(u256));

    // Deploy the contract (while analysis runs in background)
    const contract_address = try deployContract(allocator, &vm, caller_address, contract_code);
    // std.debug.print("Deployed contract to address: {any}\n", .{contract_address});

    // Get deployed contract code
    const code = vm.state.get_code(contract_address);
    
    // Create contract once outside the loop - all static setup
    var contract = evm.Contract.init(
        caller_address,     // caller
        contract_address,   // address
        0,                  // value
        1_000_000_000,      // gas
        code,               // code
        code_hash,          // code_hash
        calldata,           // input
        false               // is_static
    );
    defer contract.deinit(allocator, null);

    // Run benchmarks
    var run: u8 = 0;
    while (run < num_runs) : (run += 1) {
        // Reset gas for each run
        contract.gas = 1_000_000_000;
        contract.gas_refund = 0;
        
        var timer = std.time.Timer.start() catch unreachable;
        
        // Execute the contract
        const result = vm.interpret(&contract, calldata, false) catch |err| {
            std.debug.print("Execution failed: {}\n", .{err});
            std.process.exit(1);
        };

        const elapsed = timer.read();
        const elapsed_ms = @as(f64, @floatFromInt(elapsed)) / 1_000_000.0;

        if (result.status == .Success) {
            print("{d:.3}\n", .{elapsed_ms});
        } else {
            std.debug.print("Execution failed with status: {}\n", .{result.status});
            if (result.output) |output| {
                std.debug.print("Output size: {}, data: {any}\n", .{output.len, output});
            } else {
                std.debug.print("No output data\n", .{});
            }
            std.debug.print("Gas used: {}\n", .{result.gas_used});
            std.process.exit(1);
        }
        
        if (result.output) |output| {
            allocator.free(output);
        }
    }
}

fn deployContract(allocator: std.mem.Allocator, vm: *evm.Evm, caller: Address, bytecode: []const u8) !Address {
    _ = allocator;
    
    // Use the EVM's create_contract function
    const create_result = try vm.create_contract(
        caller,
        0, // value
        bytecode, // init code
        10_000_000 // gas
    );
    
    if (create_result.success) {
        std.debug.print("Contract deployed to: {any}, gas used: {}\n", .{create_result.address, 10_000_000 - create_result.gas_left});
        return create_result.address;
    } else {
        std.debug.print("Contract creation failed, gas used: {}\n", .{10_000_000 - create_result.gas_left});
        if (create_result.output) |output| {
            std.debug.print("Revert data: {any}\n", .{output});
        }
        return error.DeploymentFailed;
    }
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
        const byte_str = clean_hex[i..i + 2];
        bytes[i / 2] = std.fmt.parseInt(u8, byte_str, 16) catch {
            return error.InvalidHexCharacter;
        };
    }

    return bytes;
}