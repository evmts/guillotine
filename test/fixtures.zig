const std = @import("std");
const evm = @import("evm");
const primitives = @import("voltaire");
const compilers = @import("compilers");

// MinimalEvm is exported from the evm module
const MinimalEvm = evm.MinimalEvm;

const Address = primitives.Address.Address;
const testing = std.testing;

test {
    // Enable debug logging for all tests
    std.testing.log_level = .debug;
}

const TestResult = struct {
    success: bool,
    gas_used: u64,
};

// Create a custom EVM type with debug tracing enabled
const DebugEvm = evm.Evm(evm.EvmConfig{
    .tracer_config = evm.TracerConfig.debug,  // Use the predefined debug config
});

// Helper to run a fixture with both EVMs and compare results
fn runFixture(fixture_name: []const u8, calldata_hex: []const u8, gas_limit: u64) !void {
    std.debug.print("\n=== Running fixture: {s} ===\n", .{fixture_name});
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    // Load fixture bytecode from precompiled files
    const fixtures_dir = "data/fixtures/out";
    
    // Map fixture names to actual file names (they use CamelCase)
    const file_name = if (std.mem.eql(u8, fixture_name, "bubblesort"))
        "BubbleSort"
    else if (std.mem.eql(u8, fixture_name, "erc20"))
        "ERC20"
    else
        fixture_name;
    
    const contract_file = try std.fmt.allocPrint(allocator, "{s}/{s}.sol/{s}.json", .{
        fixtures_dir,
        file_name,
        file_name
    });
    defer allocator.free(contract_file);
    
    const json_data = std.fs.cwd().readFileAlloc(allocator, contract_file, 1024 * 1024) catch |err| {
        std.debug.print("Failed to read fixture file: {s}\n", .{contract_file});
        return err;
    };
    defer allocator.free(json_data);
    
    // Parse JSON to get deployed bytecode
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_data, .{});
    defer parsed.deinit();
    
    const bytecode_hex = parsed.value.object.get("deployedBytecode").?.object.get("object").?.string;
    const bytecode = try hexToBytes(allocator, bytecode_hex);
    defer allocator.free(bytecode);
    
    if (bytecode.len == 0) {
        std.debug.print("Fixture '{s}' not found or failed to compile\n", .{fixture_name});
        return error.FixtureNotFound;
    }
    
    // Test bytecode parsing and create snapshot
    try testBytecodeSnapshot(allocator, fixture_name, bytecode);
    
    // Test dispatch preprocessing and create snapshot  
    try testDispatchSnapshot(allocator, fixture_name, bytecode);
    
    // Log bytecode for debugging JUMP issues
    if (std.mem.eql(u8, fixture_name, "bubblesort")) {
        const file = std.fs.cwd().createFile("bubblesort_bytecode.txt", .{}) catch |err| {
            std.debug.print("Failed to create bytecode file: {}\n", .{err});
            return err;
        };
        defer file.close();
        
        // Build the output in memory first
        var output = std.ArrayList(u8){};
        defer output.deinit(allocator);
        
        // Write hex representation
        try output.appendSlice(allocator, "Bubblesort bytecode (hex): ");
        for (bytecode) |byte| {
            try output.writer(allocator).print("{x:0>2}", .{byte});
        }
        try output.writer(allocator).print("\n\nBubblesort bytecode length: {} bytes\n", .{bytecode.len});
        
        // Write annotated version with PCs  
        try output.appendSlice(allocator, "\nAnnotated bytecode (PC: opcode):\n");
        var pc: usize = 0;
        while (pc < bytecode.len) {
            const opcode = bytecode[pc];
            try output.writer(allocator).print("0x{x:0>4}: 0x{x:0>2}", .{pc, opcode});
            
            // Add opcode names for common ones
            const opcode_name = switch (opcode) {
                0x00 => " STOP",
                0x01 => " ADD",
                0x02 => " MUL",
                0x03 => " SUB",
                0x04 => " DIV",
                0x10 => " LT",
                0x11 => " GT",
                0x14 => " EQ",
                0x15 => " ISZERO",
                0x50 => " POP",
                0x51 => " MLOAD",
                0x52 => " MSTORE",
                0x53 => " MSTORE8",
                0x54 => " SLOAD",
                0x55 => " SSTORE",
                0x56 => " JUMP",
                0x57 => " JUMPI",
                0x5b => " JUMPDEST",
                0x60...0x7f => |n| if (n >= 0x60 and n <= 0x7f) " PUSH" else "",
                0x80 => " DUP1",
                0x81 => " DUP2",
                0x82 => " DUP3",
                0x90 => " SWAP1",
                0x91 => " SWAP2",
                0xf3 => " RETURN",
                0xfd => " REVERT",
                else => "",
            };
            try output.appendSlice(allocator, opcode_name);
            
            // Handle PUSH opcodes
            if (opcode >= 0x60 and opcode <= 0x7f) {
                const push_size = opcode - 0x5f;
                try output.writer(allocator).print("{d} [", .{push_size});
                var i: usize = 1;
                while (i <= push_size and pc + i < bytecode.len) : (i += 1) {
                    try output.writer(allocator).print("{x:0>2}", .{bytecode[pc + i]});
                }
                try output.appendSlice(allocator, "]");
                pc += push_size;
            }
            
            try output.appendSlice(allocator, "\n");
            pc += 1;
        }
        
        // Write the entire output to the file
        _ = try file.write(output.items);
        
        std.debug.print("Bubblesort bytecode logged to bubblesort_bytecode.txt\n", .{});
    }
    
    // Setup common addresses
    const sender = try Address.fromBytes(&([_]u8{0} ** 19 ++ [_]u8{0x01}));
    const contract = try Address.fromBytes(&([_]u8{0} ** 19 ++ [_]u8{0x42}));
    
    // Parse calldata
    const calldata = try hexToBytes(allocator, calldata_hex);
    defer allocator.free(calldata);
    
    // Write dispatch debug log to file
    {
        var debug_file = try std.fs.cwd().createFile("dispatch_debug.log", .{ .truncate = true });
        defer debug_file.close();
        try debug_file.writeAll("=== Dispatch Debug Log for Bubblesort ===\n\n");
    }
    
    // Test with MainnetEvm
    const main_result: TestResult = blk: {
        var database = evm.Database.init(allocator);
        defer database.deinit();
        
        try database.set_account(sender.bytes, .{
            .balance = 100_000_000_000_000_000_000,
            .code_hash = [_]u8{0} ** 32,
            .storage_root = [_]u8{0} ** 32,
            .nonce = 0,
            .delegated_address = null,
        });
        
        const code_hash = try database.set_code(bytecode);
        try database.set_account(contract.bytes, .{
            .balance = 0,
            .code_hash = code_hash,
            .storage_root = [_]u8{0} ** 32,
            .nonce = 0,
            .delegated_address = null,
        });
        
        var main_evm = try DebugEvm.init(
            allocator,
            &database,
            .{ 
                .number = 1, 
                .timestamp = 1000000, 
                .gas_limit = 30_000_000, 
                .coinbase = primitives.ZERO_ADDRESS, 
                .base_fee = 1_000_000_000, 
                .chain_id = 1, 
                .difficulty = 0, 
                .prev_randao = [_]u8{0} ** 32, 
                .blob_base_fee = 0, 
                .blob_versioned_hashes = &.{} 
            },
            .{ 
                .gas_limit = gas_limit, 
                .coinbase = primitives.ZERO_ADDRESS, 
                .chain_id = 1, 
                .blob_versioned_hashes = &.{}, 
                .blob_base_fee = 0 
            },
            1_000_000_000,
            sender,
        );
        defer main_evm.deinit();
        
        var result = main_evm.simulate(.{ 
            .call = .{ 
                .caller = sender, 
                .to = contract, 
                .value = 0, 
                .input = calldata, 
                .gas = gas_limit 
            } 
        });
        defer result.deinit(allocator);
        
        break :blk .{
            .success = result.success,
            .gas_used = gas_limit - result.gas_left,
        };
    };
    
    // Test with MinimalEvm
    const minimal_result: TestResult = blk: {
        // Use initPtr to properly handle the arena allocator
        const min_evm = try MinimalEvm.initPtr(allocator);
        defer min_evm.deinitPtr(allocator);
        
        min_evm.setBlockchainContext(1, 1, 1000000, 0, 0, primitives.ZERO_ADDRESS, 30_000_000, 1_000_000_000, 0);
        min_evm.setTransactionContext(sender, 1_000_000_000);
        try min_evm.setBalance(sender, 100_000_000_000_000_000_000);
        try min_evm.setCode(contract, bytecode);
        
        const result = min_evm.execute(
            bytecode,
            @intCast(gas_limit),
            sender,
            contract,
            0,
            calldata,
        ) catch |err| {
            std.debug.print("MinimalEvm execution failed: {}\n", .{err});
            break :blk TestResult{
                .success = false,
                .gas_used = gas_limit,
            };
        };
        
        break :blk TestResult{
            .success = result.success,
            .gas_used = gas_limit - result.gas_left,
        };
    };
    
    // Both should succeed or both should fail
    try testing.expect(main_result.success == minimal_result.success);
    
    // Gas usage might differ slightly due to implementation differences
    // but should be in the same ballpark (within 10%)
    if (main_result.success and minimal_result.success) {
        const gas_diff = if (main_result.gas_used > minimal_result.gas_used)
            main_result.gas_used - minimal_result.gas_used
        else
            minimal_result.gas_used - main_result.gas_used;
        
        const max_gas = @max(main_result.gas_used, minimal_result.gas_used);
        if (max_gas > 0) {
            const diff_percent = (gas_diff * 100) / max_gas;
            if (diff_percent > 10) {
                std.debug.print("Warning: Gas usage differs by {}% for fixture '{s}'\n", .{ diff_percent, fixture_name });
                std.debug.print("  MainnetEvm: {} gas\n", .{main_result.gas_used});
                std.debug.print("  MinimalEvm: {} gas\n", .{minimal_result.gas_used});
            }
        }
    }
}

// Test bytecode parsing and create/compare snapshot
fn testBytecodeSnapshot(allocator: std.mem.Allocator, fixture_name: []const u8, bytecode_data: []const u8) !void {
    // Create bytecode object
    const BytecodeDefault = evm.Bytecode(evm.BytecodeConfig{});
    var bytecode_obj = try BytecodeDefault.init(allocator, bytecode_data);
    defer bytecode_obj.deinit();
    
    // Generate pretty print output
    const pretty_output = try bytecode_obj.pretty_print(allocator);
    defer allocator.free(pretty_output);
    
    // Create snapshots directory if it doesn't exist
    std.fs.cwd().makeDir("test/snapshots") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    
    // Construct snapshot filename
    const snapshot_filename = try std.fmt.allocPrint(allocator, "test/snapshots/{s}_bytecode.snapshot", .{fixture_name});
    defer allocator.free(snapshot_filename);
    
    // Try to read existing snapshot
    const existing_snapshot = std.fs.cwd().readFileAlloc(allocator, snapshot_filename, 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => {
            // Create new snapshot
            const file = try std.fs.cwd().createFile(snapshot_filename, .{});
            defer file.close();
            try file.writeAll(pretty_output);
            std.debug.print("Created bytecode snapshot: {s}\n", .{snapshot_filename});
            return;
        },
        else => return err,
    };
    defer allocator.free(existing_snapshot);
    
    // Compare with existing snapshot
    if (!std.mem.eql(u8, existing_snapshot, pretty_output)) {
        std.debug.print("Bytecode snapshot mismatch for {s}!\n", .{fixture_name});
        std.debug.print("Expected length: {}, got length: {}\n", .{existing_snapshot.len, pretty_output.len});
        
        // Write actual output for debugging
        const actual_filename = try std.fmt.allocPrint(allocator, "test/snapshots/{s}_bytecode.actual", .{fixture_name});
        defer allocator.free(actual_filename);
        const actual_file = try std.fs.cwd().createFile(actual_filename, .{});
        defer actual_file.close();
        try actual_file.writeAll(pretty_output);
        
        return error.SnapshotMismatch;
    }
}

// Test dispatch preprocessing and create/compare snapshot
fn testDispatchSnapshot(allocator: std.mem.Allocator, fixture_name: []const u8, bytecode_data: []const u8) !void {
    // Create bytecode object for dispatch
    const BytecodeDefault = evm.Bytecode(evm.BytecodeConfig{});
    var bytecode_obj = try BytecodeDefault.init(allocator, bytecode_data);
    defer bytecode_obj.deinit();
    
    // Create a real EVM instance to get proper configuration
    var database = evm.Database.init(allocator);
    defer database.deinit();
    
    const sender = try primitives.Address.Address.fromBytes(&([_]u8{0} ** 19 ++ [_]u8{0x01}));
    
    var test_evm = try evm.MainnetEvm.init(
        allocator,
        &database,
        .{ .number = 1, .timestamp = 1000000, .gas_limit = 30_000_000, .coinbase = primitives.ZERO_ADDRESS, .base_fee = 1_000_000_000, .chain_id = 1, .difficulty = 0, .prev_randao = [_]u8{0} ** 32, .blob_base_fee = 0, .blob_versioned_hashes = &.{} },
        .{ .gas_limit = 1000000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1, .blob_versioned_hashes = &.{}, .blob_base_fee = 0 },
        1_000_000_000,
        sender,
    );
    defer test_evm.deinit();
    
    // Use the Frame type directly from evm module with MainnetEvm's config
    const FrameType = evm.Frame(evm.FrameConfig{ .DatabaseType = evm.Database });
    const opcode_handlers = FrameType.opcode_handlers;
    
    const Dispatch = evm.dispatch.Preprocessor(FrameType);
    var schedule = try Dispatch.init(allocator, bytecode_obj, &opcode_handlers, null);
    defer schedule.deinit();
    
    // For bubblesort, analyze PC 0xa1-0xa3 bytecode and dispatch generation
    if (std.mem.eql(u8, fixture_name, "bubblesort")) {
        var debug_output = std.ArrayList(u8){};
        defer debug_output.deinit(allocator);
        
        // First, dump raw bytecode bytes around PC 0xa2
        try debug_output.writer(allocator).print("=== Raw bytecode at PC 0xa0-0xa6 ===\n", .{});
        if (bytecode_data.len > 0xa6) {
            for (0xa0..0xa7) |idx| {
                if (idx < bytecode_data.len) {
                    try debug_output.writer(allocator).print("  [0x{x:0>4}]: 0x{x:0>2}\n", .{ idx, bytecode_data[idx] });
                }
            }
        }
        
        // Check bytecode object state
        try debug_output.writer(allocator).print("\n=== Bytecode object state ===\n", .{});
        try debug_output.writer(allocator).print("  runtime_code.len: {}\n", .{bytecode_obj.runtime_code.len});
        try debug_output.writer(allocator).print("  packed_bitmap.len: {}\n", .{bytecode_obj.packed_bitmap.len});
        
        // Check if ISZERO at 0xa2 is marked as fusion candidate
        if (0xa2 < bytecode_obj.packed_bitmap.len) {
            try debug_output.writer(allocator).print("  packed_bitmap[0xa2].is_fusion_candidate: {}\n", .{bytecode_obj.packed_bitmap[0xa2].is_fusion_candidate});
        }
        
        try debug_output.writer(allocator).print("\n=== Bytecode iteration for PC 0xa0-0xa5 ===\n", .{});
        const BytecodeType = @TypeOf(bytecode_obj);
        var bytecode_iter = BytecodeType.Iterator{ .bytecode = &bytecode_obj, .pc = 0 };
        var last_pc: u32 = 0;
        while (bytecode_iter.next()) |opcode_data| {
            const pc = last_pc;
            last_pc = bytecode_iter.pc;
            if (pc >= 0xa0 and pc <= 0xa6) {
                // Also check the packed bitmap for fusion candidates
                const is_fusion = if (pc < bytecode_obj.packed_bitmap.len) 
                    bytecode_obj.packed_bitmap[pc].is_fusion_candidate
                else 
                    false;
                    
                switch (opcode_data) {
                    .regular => |r| {
                        try debug_output.writer(allocator).print("  PC 0x{x:0>4}: Regular opcode 0x{x:0>2} (fusion={}))\n", .{ pc, r.opcode, is_fusion });
                    },
                    .push => |p| {
                        try debug_output.writer(allocator).print("  PC 0x{x:0>4}: PUSH{} value=0x{x} (fusion={}))\n", .{ pc, p.size, p.value, is_fusion });
                    },
                    .push_jumpi_fusion => |pj| {
                        try debug_output.writer(allocator).print("  PC 0x{x:0>4}: PUSH+JUMPI fusion to 0x{x} (fusion={}))\n", .{ pc, pj.value, is_fusion });
                    },
                    .iszero_jumpi => |ij| {
                        try debug_output.writer(allocator).print("  PC 0x{x:0>4}: ISZERO+JUMPI fusion to 0x{x} (fusion={}))\n", .{ pc, ij.target, is_fusion });
                    },
                    else => {
                        try debug_output.writer(allocator).print("  PC 0x{x:0>4}: {s} (fusion={}))\n", .{ pc, @tagName(opcode_data), is_fusion });
                    },
                }
            }
            if (pc > 0xa6) break;
        }
        
        try debug_output.writer(allocator).print("\n=== Schedule indices 135-145 ===\n", .{});
        
        // Now log the dispatch schedule with handler names  
        // We can't import frame_handlers directly, so just print hex addresses
        
        for (135..@min(145, schedule.items.len)) |idx| {
            const item = schedule.items[idx];
            try debug_output.writer(allocator).print("[{}]: ", .{idx});
            switch (item) {
                .opcode_handler => |handler| {
                    try debug_output.writer(allocator).print("opcode_handler(@{x})\n", .{@intFromPtr(handler)});
                },
                .first_block_gas => |fbg| try debug_output.writer(allocator).print("first_block_gas(gas: {}, min_stack: {}, max_stack: {})\n", .{fbg.gas, fbg.min_stack, fbg.max_stack}),
                .jump_dest => |jd| try debug_output.writer(allocator).print("jump_dest(gas: {}, min_stack: {}, max_stack: {})\n", .{jd.gas, jd.min_stack, jd.max_stack}),
                .jump_static => |js| try debug_output.writer(allocator).print("jump_static(dispatch: @{x})\n", .{@intFromPtr(js.dispatch)}),
                .push_inline => |push| try debug_output.writer(allocator).print("push_inline(value: 0x{x})\n", .{push.value}),
                .push_pointer => |pp| try debug_output.writer(allocator).print("push_pointer(value: 0x{x})\n", .{pp.value_ptr.*}),
                .pc => |pc_meta| try debug_output.writer(allocator).print("pc(value: {})\n", .{pc_meta.value}),
            }
        }
        
        const debug_file = try std.fs.cwd().createFile("bubblesort_schedule_debug.log", .{});
        defer debug_file.close();
        try debug_file.writeAll(debug_output.items);
    }
    
    // Generate pretty print output
    const pretty_output = try Dispatch.pretty_print(allocator, schedule.items, bytecode_obj);
    defer allocator.free(pretty_output);
    
    // Create snapshots directory if it doesn't exist
    std.fs.cwd().makeDir("test/snapshots") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    
    // Construct snapshot filename
    const snapshot_filename = try std.fmt.allocPrint(allocator, "test/snapshots/{s}_dispatch.snapshot", .{fixture_name});
    defer allocator.free(snapshot_filename);
    
    // Try to read existing snapshot
    const existing_snapshot = std.fs.cwd().readFileAlloc(allocator, snapshot_filename, 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => {
            // Create new snapshot
            const file = try std.fs.cwd().createFile(snapshot_filename, .{});
            defer file.close();
            try file.writeAll(pretty_output);
            std.debug.print("Created dispatch snapshot: {s}\n", .{snapshot_filename});
            return;
        },
        else => return err,
    };
    defer allocator.free(existing_snapshot);
    
    // Compare with existing snapshot
    if (!std.mem.eql(u8, existing_snapshot, pretty_output)) {
        std.debug.print("Dispatch snapshot mismatch for {s}!\n", .{fixture_name});
        std.debug.print("Expected length: {}, got length: {}\n", .{existing_snapshot.len, pretty_output.len});
        
        // Write actual output for debugging
        const actual_filename = try std.fmt.allocPrint(allocator, "test/snapshots/{s}_dispatch.actual", .{fixture_name});
        defer allocator.free(actual_filename);
        const actual_file = try std.fs.cwd().createFile(actual_filename, .{});
        defer actual_file.close();
        try actual_file.writeAll(pretty_output);
        
        return error.SnapshotMismatch;
    }
}

fn hexToBytes(allocator: std.mem.Allocator, hex_str: []const u8) ![]u8 {
    var str = hex_str;
    if (str.len >= 2 and (std.mem.eql(u8, str[0..2], "0x") or std.mem.eql(u8, str[0..2], "0X"))) {
        str = str[2..];
    }
    
    if (str.len == 0) {
        return try allocator.alloc(u8, 0);
    }
    
    if (str.len % 2 != 0) return error.OddNumberOfDigits;
    
    const result = try allocator.alloc(u8, str.len / 2);
    for (result, 0..) |*byte, i| {
        const high = try std.fmt.charToDigit(str[i * 2], 16);
        const low = try std.fmt.charToDigit(str[i * 2 + 1], 16);
        byte.* = (high << 4) | low;
    }
    return result;
}

// Individual fixture tests

test "fixture: arithmetic" {
    try runFixture("arithmetic", "0x", 1000000);
}

test "fixture: bitwise" {
    try runFixture("bitwise", "0x", 1000000);
}

test "fixture: bubblesort" {
    try runFixture("bubblesort", "0x239b51bf0000000000000000000000000000000000000000000000000000000000000064", 30000000);
}

test "fixture: calldata" {
    try runFixture("calldata", "0x0123456789abcdef", 1000000);
}

test "fixture: codecopy" {
    try runFixture("codecopy", "0x", 1000000);
}

test "fixture: comparison" {
    try runFixture("comparison", "0x", 1000000);
}

test "fixture: contractcalls" {
    try runFixture("contractcalls", "0x", 1000000);
}

test "fixture: controlflow" {
    try runFixture("controlflow", "0x", 1000000);
}

test "fixture: externalcode" {
    try runFixture("externalcode", "0x", 1000000);
}

test "fixture: factorial" {
    try runFixture("factorial", "0x", 1000000);
}

test "fixture: fibonacci" {
    try runFixture("fibonacci", "0x", 1000000);
}

test "fixture: fibonacci_recursive" {
    try runFixture("fibonacci_recursive", "0x", 1000000);
}

test "fixture: hashing" {
    try runFixture("hashing", "0x", 1000000);
}

test "fixture: logs" {
    try runFixture("logs", "0x", 1000000);
}

test "fixture: push" {
    try runFixture("push", "0x", 1000000);
}

test "fixture: returndata" {
    try runFixture("returndata", "0x", 1000000);
}

test "fixture: shifts" {
    try runFixture("shifts", "0x", 1000000);
}

test "fixture: stack" {
    try runFixture("stack", "0x", 1000000);
}

test "fixture: storage" {
    try runFixture("storage", "0x", 1000000);
}

test "fixture: tenhashes" {
    try runFixture("tenhashes", "0x", 10000000);
}

// Test ERC20 if available
test "fixture: erc20" {
    try runFixture("erc20", "0xa9059cbb000000000000000000000000000000000000000000000000000000000000002a0000000000000000000000000000000000000000000000000000000000000064", 100000);
}

// Test SnailTracer if available
test "fixture: snailtracer" {
    try runFixture("snailtracer", "0x30627b7c", 1000000000);
}