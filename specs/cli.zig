const std = @import("std");
const clap = @import("clap");
const guillotine = @import("guillotine");
const primitives = @import("voltaire");

// Test case structures matching the Ethereum spec format
const TestCase = struct {
    _info: ?struct {
        comment: ?[]const u8 = null,
        pytest_marks: ?[][]const u8 = null,
    } = null,
    env: ?struct {
        currentCoinbase: ?[]const u8 = null,
        currentDifficulty: ?[]const u8 = null,
        currentGasLimit: ?[]const u8 = null,
        currentNumber: ?[]const u8 = null,
        currentTimestamp: ?[]const u8 = null,
        currentRandom: ?[]const u8 = null,
        currentBaseFee: ?[]const u8 = null,
    } = null,
    pre: ?std.json.Value = null,
    transaction: ?std.json.Value = null,
    transactions: ?[]std.json.Value = null,
    expect: ?[]std.json.Value = null,
    post: ?std.json.Value = null,
};

// Helper functions for parsing
fn parseAddress(allocator: std.mem.Allocator, addr_str: []const u8) !primitives.Address {
    _ = allocator;
    var addr = addr_str;
    
    // Handle placeholder syntax like <contract:0x...> or <eoa:0x...>
    if (std.mem.indexOf(u8, addr, "<") != null and std.mem.indexOf(u8, addr, ">") != null) {
        // Extract address from placeholder
        if (std.mem.indexOf(u8, addr, "0x")) |idx| {
            const end_idx = std.mem.indexOfPos(u8, addr, idx, ">") orelse addr.len;
            addr = addr[idx..end_idx];
        }
    }
    
    // Remove 0x prefix if present
    if (addr.len >= 2 and (std.mem.eql(u8, addr[0..2], "0x") or std.mem.eql(u8, addr[0..2], "0X"))) {
        addr = addr[2..];
    }
    
    // Pad with zeros if necessary
    var hex_bytes = [_]u8{0} ** 40;
    if (addr.len <= 40) {
        @memcpy(hex_bytes[40 - addr.len..], addr);
    } else {
        @memcpy(&hex_bytes, addr[addr.len - 40..]);
    }
    
    // Convert hex string to bytes
    var bytes: [20]u8 = undefined;
    for (0..20) |i| {
        const high = try std.fmt.charToDigit(hex_bytes[i * 2], 16);
        const low = try std.fmt.charToDigit(hex_bytes[i * 2 + 1], 16);
        bytes[i] = (high << 4) | low;
    }
    
    return primitives.Address.fromBytes(&bytes) catch unreachable;
}

fn parseHexData(allocator: std.mem.Allocator, data_str: []const u8) ![]u8 {
    var data = data_str;
    
    // Handle :raw prefix
    if (std.mem.startsWith(u8, data, ":raw ")) {
        data = data[5..];
    }
    
    // Simple hex parsing - skip complex placeholder handling for now
    // TODO: Implement proper placeholder replacement
    
    // Remove 0x prefix if present
    if (data.len >= 2 and std.mem.eql(u8, data[0..2], "0x")) {
        data = data[2..];
    }
    
    // Handle empty data
    if (data.len == 0) {
        return try allocator.alloc(u8, 0);
    }
    
    // Count valid hex characters
    var hex_count: usize = 0;
    for (data) |c| {
        if (std.ascii.isHex(c)) {
            hex_count += 1;
        }
    }
    
    // Handle no valid hex
    if (hex_count == 0) {
        return try allocator.alloc(u8, 0);
    }
    
    // Ensure even number of hex digits
    const needs_padding = hex_count % 2 != 0;
    const byte_count = if (needs_padding) (hex_count + 1) / 2 else hex_count / 2;
    
    const bytes = try allocator.alloc(u8, byte_count);
    
    var byte_idx: usize = 0;
    var nibble_idx: usize = 0;
    var current_byte: u8 = 0;
    
    // Add leading zero if needed
    if (needs_padding) {
        current_byte = 0;
        nibble_idx = 1;
    }
    
    for (data) |c| {
        if (std.ascii.isHex(c)) {
            const digit = try std.fmt.charToDigit(c, 16);
            if (nibble_idx % 2 == 0) {
                current_byte = digit << 4;
            } else {
                current_byte |= digit;
                bytes[byte_idx] = current_byte;
                byte_idx += 1;
            }
            nibble_idx += 1;
        }
    }
    
    return bytes;
}

fn parseU256(str: []const u8) !u256 {
    var s = str;
    
    // Handle empty string
    if (s.len == 0) return 0;
    
    // Remove 0x prefix
    if (s.len >= 2 and std.mem.eql(u8, s[0..2], "0x")) {
        s = s[2..];
    }
    
    // Handle empty hex string
    if (s.len == 0) return 0;
    
    // Parse hex string
    var result: u256 = 0;
    for (s) |c| {
        const digit = try std.fmt.charToDigit(c, 16);
        result = result * 16 + digit;
    }
    
    return result;
}

fn executeTest(allocator: std.mem.Allocator, test_path: []const u8, verbose: bool) !void {
    // Read the test file
    const file = if (std.fs.path.isAbsolute(test_path))
        try std.fs.openFileAbsolute(test_path, .{})
    else
        try std.fs.cwd().openFile(test_path, .{});
    defer file.close();
    
    const file_size = try file.getEndPos();
    const content = try allocator.alloc(u8, file_size);
    defer allocator.free(content);
    
    _ = try file.read(content);
    
    // Parse JSON
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
    defer parsed.deinit();
    
    // Handle different JSON structures
    switch (parsed.value) {
        .array => |array| {
            // Array of test cases (like precompile tests)
            if (verbose) {
                std.debug.print("Processing array of {} test cases\n", .{array.items.len});
            }
            
            for (array.items) |test_case| {
                if (test_case != .object) continue;
                
                if (test_case.object.get("name")) |name| {
                    if (verbose) {
                        std.debug.print("  Test: {s}\n", .{name.string});
                    }
                }
                
                // These are typically precompile tests with different format
                // Skip for now as they need special handling
            }
            return;
        },
        .object => |root_obj| {
            // Standard test suite format
            var it = root_obj.iterator();
            while (it.next()) |entry| {
                const test_name = entry.key_ptr.*;
                const test_data = entry.value_ptr.*;
                
                if (test_data != .object) continue;
                
                if (verbose) {
                    std.debug.print("Running test: {s}\n", .{test_name});
                }
                
                try executeTestCase(allocator, test_name, test_data, verbose);
            }
        },
        else => {
            std.debug.print("Unexpected JSON structure\n", .{});
            return;
        }
    }
}

fn executeTestCase(allocator: std.mem.Allocator, test_name: []const u8, test_data: std.json.Value, verbose: bool) !void {
    _ = test_name;
    
    // Extract test components
    const env = test_data.object.get("env");
    const pre = test_data.object.get("pre");
    const transaction = test_data.object.get("transaction");
    const transactions = test_data.object.get("transactions");
    const expect = test_data.object.get("expect");
    const post = test_data.object.get("post");
    
    if (env == null or pre == null) {
        if (verbose) {
            std.debug.print("  Skipping: missing env or pre\n", .{});
        }
        return;
    }
    
    // Check for assembly code and skip
    var pre_check_it = pre.?.object.iterator();
    if (pre_check_it.next()) |first_account| {
        if (first_account.value_ptr.*.object.get("code")) |code| {
            if (code.string.len > 0 and code.string[0] == '{') {
                if (verbose) {
                    std.debug.print("  Skipping: assembly code not supported\n", .{});
                }
                return;
            }
        }
    }
    
    // Parse block info
    var block_number: u64 = 1;
    var block_timestamp: u64 = 1000;
    var block_gas_limit: u64 = 10_000_000;
    var block_base_fee: u256 = 0;
    var coinbase = try parseAddress(allocator, "0x0000000000000000000000000000000000000000");
    
    if (env.?.object.get("currentNumber")) |num| {
        block_number = try std.fmt.parseInt(u64, num.string, 0);
    }
    if (env.?.object.get("currentTimestamp")) |ts| {
        block_timestamp = try std.fmt.parseInt(u64, ts.string, 0);
    }
    if (env.?.object.get("currentGasLimit")) |gl| {
        block_gas_limit = try std.fmt.parseInt(u64, gl.string, 0);
    }
    if (env.?.object.get("currentBaseFee")) |bf| {
        if (bf.string.len > 0) {
            block_base_fee = try parseU256(bf.string);
        }
    }
    if (env.?.object.get("currentCoinbase")) |cb| {
        coinbase = try parseAddress(allocator, cb.string);
    }
    
    // Create block info
    const block_info = guillotine.BlockInfo{
        .number = block_number,
        .timestamp = block_timestamp,
        .gas_limit = block_gas_limit,
        .coinbase = coinbase,
        .base_fee = block_base_fee,
        .chain_id = 1,
        .difficulty = 0,
        .prev_randao = [_]u8{0} ** 32,
        .blob_base_fee = 0,
        .blob_versioned_hashes = &.{},
    };
    
    // Create database and set up pre-state
    var database = guillotine.Database.init(allocator);
    defer database.deinit();
    
    // Setup pre-state accounts
    var pre_it = pre.?.object.iterator();
    while (pre_it.next()) |pre_entry| {
        const addr_str = pre_entry.key_ptr.*;
        const account_data = pre_entry.value_ptr.*;
        
        if (account_data != .object) continue;
        
        const address = try parseAddress(allocator, addr_str);
        
        var balance: u256 = 0;
        var nonce: u64 = 0;
        var code_hash = [_]u8{0} ** 32;
        
        if (account_data.object.get("balance")) |bal| {
            if (bal.string.len > 0) {
                balance = try parseU256(bal.string);
            }
        }
        
        if (account_data.object.get("nonce")) |n| {
            if (n.string.len > 0) {
                nonce = try std.fmt.parseInt(u64, n.string, 0);
            }
        }
        
        if (account_data.object.get("code")) |code_str| {
            if (code_str.string.len > 0 and code_str.string[0] != '{') {
                // Skip assembly code
                const code = try parseHexData(allocator, code_str.string);
                defer allocator.free(code);
                
                if (code.len > 0) {
                    code_hash = try database.set_code(code);
                }
            }
        }
        
        const account = guillotine.Account{
            .balance = balance,
            .code_hash = code_hash,
            .storage_root = [_]u8{0} ** 32,
            .nonce = nonce,
            .delegated_address = null,
        };
        try database.set_account(address.bytes, account);
        
        // Set storage if present
        if (account_data.object.get("storage")) |storage| {
            if (storage == .object) {
                var storage_it = storage.object.iterator();
                while (storage_it.next()) |storage_entry| {
                    const key = try parseU256(storage_entry.key_ptr.*);
                    const value_str = if (storage_entry.value_ptr.* == .string)
                        storage_entry.value_ptr.*.string
                    else
                        "0x0";
                    const value = try parseU256(value_str);
                    
                    try database.set_storage(address.bytes, key, value);
                }
            }
        }
    }
    
    // Process transactions
    const tx_list = if (transactions != null)
        transactions.?.array.items
    else if (transaction != null)
        &[_]std.json.Value{transaction.?}
    else
        return;
    
    for (tx_list) |tx| {
        if (tx != .object) continue;
        
        // Extract transaction fields
        var gas_limit: u64 = 1_000_000;
        var gas_price: u256 = 1_000_000_000;
        var to_addr: ?primitives.Address = null;
        var value: u256 = 0;
        var data: []u8 = try allocator.alloc(u8, 0);
        defer allocator.free(data);
        
        // Gas limit
        if (tx.object.get("gasLimit")) |gl| {
            const gl_str = switch (gl) {
                .string => |s| s,
                .array => |a| if (a.items.len > 0) a.items[0].string else "1000000",
                else => "1000000",
            };
            if (gl_str.len > 0) {
                gas_limit = try std.fmt.parseInt(u64, gl_str, 0);
            }
        }
        
        // Gas price
        if (tx.object.get("gasPrice")) |gp| {
            if (gp.string.len > 0) {
                gas_price = try parseU256(gp.string);
            }
        }
        
        // To address
        if (tx.object.get("to")) |to| {
            if (to.string.len > 0) {
                to_addr = try parseAddress(allocator, to.string);
            }
        }
        
        // Value
        if (tx.object.get("value")) |v| {
            const v_str = switch (v) {
                .string => |s| s,
                .array => |a| if (a.items.len > 0) a.items[0].string else "0",
                else => "0",
            };
            if (v_str.len > 0) {
                value = try parseU256(v_str);
            }
        }
        
        // Data
        if (tx.object.get("data")) |d| {
            const d_str = switch (d) {
                .string => |s| s,
                .array => |a| if (a.items.len > 0) a.items[0].string else "0x",
                else => "0x",
            };
            allocator.free(data);
            data = try parseHexData(allocator, d_str);
        }
        
        // Determine sender
        var sender = primitives.Address.fromBytes(&([_]u8{0xa9} ** 20)) catch unreachable;
        if (tx.object.get("sender")) |s| {
            sender = try parseAddress(allocator, s.string);
        } else if (tx.object.get("secretKey")) |sk| {
            // Standard test private key
            if (std.mem.indexOf(u8, sk.string, "45a915e4d060149eb4365960e6a7a45f334393093061116b197e3240065ff2d8") != null) {
                // Standard test address for this key
                const test_addr = "0xa94f5374fce5edbc8e2a8697c15331677e6ebf0b";
                sender = try parseAddress(allocator, test_addr);
            }
        }
        
        // Create transaction context
        const tx_context = guillotine.TransactionContext{
            .gas_limit = gas_limit,
            .coinbase = coinbase,
            .chain_id = 1,
            .blob_versioned_hashes = &.{},
            .blob_base_fee = 0,
        };
        
        // Create EVM instance
        var evm = try guillotine.MainnetEvm.init(
            allocator,
            &database,
            block_info,
            tx_context,
            gas_price,
            sender,
        );
        defer evm.deinit();
        
        // Check sender balance before transaction
        if (verbose) {
            const sender_balance = evm.get_balance(sender);
            const gas_cost = gas_limit * gas_price;
            const total_cost = gas_cost + value;
            std.debug.print("  Pre-Transaction State:\n", .{});
            std.debug.print("    Sender balance: {}\n", .{sender_balance});
            std.debug.print("    Total tx cost: {} (gas: {} + value: {})\n", .{total_cost, gas_cost, value});
            if (sender_balance < total_cost) {
                std.debug.print("    WARNING: Insufficient balance for transaction!\n", .{});
            }
        }
        
        // Create call parameters
        const call_params = if (to_addr) |to| 
            guillotine.MainnetEvm.CallParams{
                .call = .{
                    .caller = sender,
                    .to = to,
                    .value = value,
                    .input = data,
                    .gas = gas_limit,
                },
            }
        else 
            guillotine.MainnetEvm.CallParams{
                .create = .{
                    .caller = sender,
                    .value = value,
                    .init_code = data,
                    .gas = gas_limit,
                },
            };
        
        // Execute the call (use call instead of simulate to keep state changes)
        var result = evm.call(call_params);
        defer result.deinit(allocator);
        
        // Report results
        if (verbose) {
            const gas_used = gas_limit - result.gas_left;
            std.debug.print("  Transaction Details:\n", .{});
            std.debug.print("    From: 0x", .{});
            for (sender.bytes) |byte| {
                std.debug.print("{x:0>2}", .{byte});
            }
            std.debug.print("\n", .{});
            if (to_addr) |to| {
                std.debug.print("    To: 0x", .{});
                for (to.bytes) |byte| {
                    std.debug.print("{x:0>2}", .{byte});
                }
                std.debug.print("\n", .{});
            } else {
                std.debug.print("    To: Contract Creation\n", .{});
            }
            std.debug.print("    Value: {}\n", .{value});
            std.debug.print("    Gas Limit: {}\n", .{gas_limit});
            std.debug.print("    Gas Price: {}\n", .{gas_price});
            std.debug.print("  Results:\n", .{});
            std.debug.print("    Gas used: {}\n", .{gas_used});
            std.debug.print("    Success: {}\n", .{result.success});
            if (result.error_info) |err_info| {
                std.debug.print("    Error: {s}\n", .{err_info});
            }
            if (result.output.len > 0) {
                std.debug.print("  Output: 0x", .{});
                for (result.output) |byte| {
                    std.debug.print("{x:0>2}", .{byte});
                }
                std.debug.print("\n", .{});
            }
        }
        
        // Post-state validation (must be done while EVM is still in scope)
        if (post != null or expect != null) {
            // Get actual post-state
            var actual_state = try evm.dumpState(allocator);
            defer actual_state.deinit(allocator);
            
            var validation_failed = false;
            var validation_errors = std.ArrayList([]const u8){};
            defer {
                for (validation_errors.items) |err| {
                    allocator.free(err);
                }
                validation_errors.deinit(allocator);
            }
            
            // Validate against 'post' field if present
            if (post != null and post.? == .object) {
            var post_it = post.?.object.iterator();
            while (post_it.next()) |expected_entry| {
                const expected_addr = expected_entry.key_ptr.*;
                const expected_account = expected_entry.value_ptr.*;
                
                if (expected_account != .object) continue;
                
                // Normalize address
                var addr_normalized: [42]u8 = undefined;
                var addr_str = expected_addr;
                if (addr_str[0] != '0' or addr_str[1] != 'x') {
                    @memcpy(addr_normalized[0..2], "0x");
                    @memcpy(addr_normalized[2..], addr_str[0..@min(addr_str.len, 40)]);
                    addr_str = addr_normalized[0..42];
                }
                
                // Find actual account
                const actual_account = actual_state.accounts.get(addr_str);
                
                // Check if account exists when it should
                if (expected_account.object.get("shouldnotexist")) |should_not| {
                    if (should_not == .string and std.mem.eql(u8, should_not.string, "1")) {
                        if (actual_account != null) {
                            const err_msg = try std.fmt.allocPrint(allocator, 
                                "Account {s} should not exist but does", .{addr_str});
                            try validation_errors.append(allocator, err_msg);
                            validation_failed = true;
                        }
                        continue;
                    }
                }
                
                if (actual_account == null) {
                    const err_msg = try std.fmt.allocPrint(allocator, 
                        "Expected account {s} not found in post-state", .{addr_str});
                    try validation_errors.append(allocator, err_msg);
                    validation_failed = true;
                    continue;
                }
                
                // Validate balance
                if (expected_account.object.get("balance")) |expected_balance| {
                    const expected_bal = try parseU256(expected_balance.string);
                    if (actual_account.?.balance != expected_bal) {
                        const err_msg = try std.fmt.allocPrint(allocator, 
                            "Account {s}: balance mismatch. Expected: {}, Actual: {}", 
                            .{addr_str, expected_bal, actual_account.?.balance});
                        try validation_errors.append(allocator, err_msg);
                        validation_failed = true;
                    }
                }
                
                // Validate nonce
                if (expected_account.object.get("nonce")) |expected_nonce| {
                    const expected_n = if (expected_nonce.string.len > 0)
                        try std.fmt.parseInt(u64, expected_nonce.string, 0)
                    else 0;
                    if (actual_account.?.nonce != expected_n) {
                        const err_msg = try std.fmt.allocPrint(allocator,
                            "Account {s}: nonce mismatch. Expected: {}, Actual: {}",
                            .{addr_str, expected_n, actual_account.?.nonce});
                        try validation_errors.append(allocator, err_msg);
                        validation_failed = true;
                    }
                }
                
                // Validate code
                if (expected_account.object.get("code")) |expected_code| {
                    if (expected_code.string.len > 0 and expected_code.string[0] != '{') {
                        const expected_bytes = try parseHexData(allocator, expected_code.string);
                        defer allocator.free(expected_bytes);
                        
                        if (!std.mem.eql(u8, actual_account.?.code, expected_bytes)) {
                            const err_msg = try std.fmt.allocPrint(allocator,
                                "Account {s}: code mismatch. Expected len: {}, Actual len: {}",
                                .{addr_str, expected_bytes.len, actual_account.?.code.len});
                            try validation_errors.append(allocator, err_msg);
                            validation_failed = true;
                        }
                    }
                }
                
                // Validate storage
                if (expected_account.object.get("storage")) |expected_storage| {
                    if (expected_storage == .object) {
                        var storage_it = expected_storage.object.iterator();
                        while (storage_it.next()) |storage_entry| {
                            const key = try parseU256(storage_entry.key_ptr.*);
                            const expected_value_str = if (storage_entry.value_ptr.* == .string)
                                storage_entry.value_ptr.*.string
                            else "0x0";
                            const expected_value = try parseU256(expected_value_str);
                            
                            const actual_value = actual_account.?.storage.get(key) orelse 0;
                            
                            if (actual_value != expected_value) {
                                const err_msg = try std.fmt.allocPrint(allocator,
                                    "Account {s}: storage[{}] mismatch. Expected: {}, Actual: {}",
                                    .{addr_str, key, expected_value, actual_value});
                                try validation_errors.append(allocator, err_msg);
                                validation_failed = true;
                            }
                        }
                    }
                }
            }
            }
            
            // Report validation results
            if (validation_failed) {
            std.debug.print("  ❌ POST-STATE VALIDATION FAILED:\n", .{});
            for (validation_errors.items) |err| {
                std.debug.print("     - {s}\n", .{err});
            }
            } else if (post != null) {
                if (verbose) {
                    std.debug.print("  ✅ Post-state validation PASSED\n", .{});
                }
            }
        }
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Define CLI parameters
    const params = comptime clap.parseParamsComptime(
        \\-h, --help            Display this help and exit
        \\-v, --verbose         Enable verbose output
        \\-f, --file <str>      Path to the JSON test fixture file
        \\-d, --dir <str>       Directory containing test fixtures
        \\-p, --pattern <str>   Pattern to match test files (default: *.json)
        \\-m, --max <usize>     Maximum number of files to process (default: 100)
        \\
    );

    // Parse arguments
    const parsers = comptime .{
        .str = clap.parsers.string,
        .usize = clap.parsers.int(usize, 10),
    };
    
    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, parsers, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| {
        try diag.reportToFile(.stderr(), err);
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        return clap.usageToFile(.stdout(), clap.Help, &params);
    }

    const verbose = res.args.verbose != 0;
    const max_files = res.args.max orelse 100;

    if (res.args.file) |file_path| {
        // Single file mode
        try executeTest(allocator, file_path, verbose);
    } else if (res.args.dir) |dir_path| {
        // Directory mode
        const pattern = res.args.pattern orelse "*.json";
        
        // Open directory (either absolute or relative)
        var dir = if (std.fs.path.isAbsolute(dir_path))
            try std.fs.openDirAbsolute(dir_path, .{ .iterate = true })
        else
            try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
        defer dir.close();
        
        var walker = try dir.walk(allocator);
        defer walker.deinit();
        
        var file_count: usize = 0;
        while (try walker.next()) |entry| {
            if (file_count >= max_files) break;
            if (entry.kind != .file) continue;
            
            // Simple pattern matching
            if (std.mem.endsWith(u8, entry.basename, ".json")) {
                if (pattern.len > 0 and !std.mem.eql(u8, pattern, "*.json")) {
                    // Extract pattern without wildcards
                    const clean_pattern = std.mem.trim(u8, pattern, "*");
                    if (clean_pattern.len > 0 and std.mem.indexOf(u8, entry.basename, clean_pattern) == null) {
                        continue;
                    }
                }
                
                const full_path = try std.fs.path.join(allocator, &.{ dir_path, entry.path });
                defer allocator.free(full_path);
                
                std.debug.print("\nTesting: {s}\n", .{entry.path});
                executeTest(allocator, full_path, verbose) catch |err| {
                    std.debug.print("  Error: {}\n", .{err});
                    continue;
                };
                
                file_count += 1;
            }
        }
        
        std.debug.print("\nProcessed {} files\n", .{file_count});
    } else {
        std.debug.print("Error: Must specify either --file or --dir\n", .{});
        return error.MissingArgument;
    }
}