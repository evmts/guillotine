const std = @import("std");
const testing = std.testing;
const evm_mod = @import("evm");
const primitives = @import("voltaire");
const log = evm_mod.log;

// Import specific types we need
const bytecode_mod = evm_mod.bytecode;
const MemoryDatabase = evm_mod.MemoryDatabase;
const Address = primitives.Address.Address;
const Evm = evm_mod.Evm;

// Test that verifies both fusion detection AND execution
test "fusion: PUSH+ADD fusion detection and execution" {
    log.info("Testing PUSH+ADD fusion detection and execution", .{});
    const allocator = testing.allocator;
    
    // Simple bytecode with PUSH+ADD that should be fused
    // This pushes 10, then PUSH1 5 + ADD should fuse, leaving 15 on stack
    const bytecode = [_]u8{
        0x60, 0x0A,  // PUSH1 10
        0x60, 0x05,  // PUSH1 5
        0x01,        // ADD (should fuse with previous PUSH1)
        0x60, 0x00,  // PUSH1 0
        0x52,        // MSTORE (store result at memory[0])
        0x60, 0x20,  // PUSH1 32
        0x60, 0x00,  // PUSH1 0
        0xF3,        // RETURN (return memory[0:32])
    };
    
    // First verify fusion detection
    const Bytecode = evm_mod.Bytecode(.{
        .max_bytecode_size = 1024,
        .fusions_enabled = true,  // Enable fusion detection
    });
    
    var bc = try Bytecode.init(allocator, &bytecode);
    defer bc.deinit();
    
    // Iterate through opcodes and check for fusion
    var iter = bc.createIterator();
    var found_fusion = false;
    
    while (iter.next()) |op_data| {
        switch (op_data) {
            .push_add_fusion => |data| {
                found_fusion = true;
                try testing.expectEqual(@as(u256, 5), data.value);
                log.info("Found PUSH_ADD fusion with value {}", .{data.value});
            },
            else => {},
        }
    }
    
    try testing.expect(found_fusion);
    log.info("Fusion detection verified, now testing execution", .{});
    
    // Now test execution with fusion enabled
    const Database = @import("evm").Database;
    const BlockInfo = @import("evm").BlockInfo;
    const TransactionContext = @import("evm").TransactionContext;
    const DefaultEvm = @import("evm").DefaultEvm;
    
    var db = Database.init(allocator);
    defer db.deinit();
    
    const block_info = BlockInfo{
        .chain_id = 1,
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 0,
        .blob_base_fee = 0,
        .prev_randao = [_]u8{0} ** 32,
        .blob_versioned_hashes = &.{},
    };
    
    const tx_context = TransactionContext{
        .gas_limit = 1000000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };
    
    var evm = try DefaultEvm.init(allocator, &db, block_info, tx_context, 0, primitives.ZERO_ADDRESS);
    defer evm.deinit();
    
    // Create contract with our bytecode
    const create_params = DefaultEvm.CallParams{
        .create = .{
            .caller = primitives.ZERO_ADDRESS,
            .value = 0,
            .init_code = &bytecode,
            .gas = 100000,
        },
    };
    
    var result = evm.call(create_params);
    defer result.deinit(allocator);
    
    // Check execution succeeded
    try testing.expect(result.success);
    
    // The output should be the deployed contract code that returns 15
    // Our bytecode stores 15 at memory[0] and returns it
    try testing.expect(result.gas_left > 0);
    log.info("Execution succeeded with gas_left: {}", .{result.gas_left});
}

test "fusion: Bytecode analysis detects PUSH+SUB fusion" {
    log.info("Testing PUSH+SUB fusion detection", .{});
    const allocator = testing.allocator;
    
    const bytecode = [_]u8{
        0x60, 0x03,  // PUSH1 3
        0x03,        // SUB
        0x00,        // STOP
    };
    
    const Bytecode = evm_mod.Bytecode(.{
        .max_bytecode_size = 1024,
        .fusions_enabled = true,
    });
    
    var bc = try Bytecode.init(allocator, &bytecode);
    defer bc.deinit();
    
    var iter = bc.createIterator();
    var found_fusion = false;
    
    while (iter.next()) |op_data| {
        switch (op_data) {
            .push_sub_fusion => |data| {
                found_fusion = true;
                try testing.expectEqual(@as(u256, 3), data.value);
                log.info("Found PUSH_SUB fusion with value {}", .{data.value});
            },
            else => {},
        }
    }
    
    try testing.expect(found_fusion);
}

test "fusion: Bytecode analysis detects PUSH+MUL fusion" {
    log.info("Testing PUSH+MUL fusion detection", .{});
    const allocator = testing.allocator;
    
    const bytecode = [_]u8{
        0x60, 0x02,  // PUSH1 2
        0x02,        // MUL
        0x00,        // STOP
    };
    
    const Bytecode = evm_mod.Bytecode(.{
        .max_bytecode_size = 1024,
        .fusions_enabled = true,
    });
    
    var bc = try Bytecode.init(allocator, &bytecode);
    defer bc.deinit();
    
    var iter = bc.createIterator();
    var found_fusion = false;
    
    while (iter.next()) |op_data| {
        switch (op_data) {
            .push_mul_fusion => |data| {
                found_fusion = true;
                try testing.expectEqual(@as(u256, 2), data.value);
                log.info("Found PUSH_MUL fusion with value {}", .{data.value});
            },
            else => {},
        }
    }
    
    try testing.expect(found_fusion);
}

test "fusion: Bytecode analysis detects PUSH+DIV fusion" {
    log.info("Testing PUSH+DIV fusion detection", .{});
    const allocator = testing.allocator;
    
    const bytecode = [_]u8{
        0x60, 0x04,  // PUSH1 4
        0x04,        // DIV
        0x00,        // STOP
    };
    
    const Bytecode = evm_mod.Bytecode(.{
        .max_bytecode_size = 1024,
        .fusions_enabled = true,
    });
    
    var bc = try Bytecode.init(allocator, &bytecode);
    defer bc.deinit();
    
    var iter = bc.createIterator();
    var found_fusion = false;
    
    while (iter.next()) |op_data| {
        switch (op_data) {
            .push_div_fusion => |data| {
                found_fusion = true;
                try testing.expectEqual(@as(u256, 4), data.value);
                log.info("Found PUSH_DIV fusion with value {}", .{data.value});
            },
            else => {},
        }
    }
    
    try testing.expect(found_fusion);
}

test "fusion: Bytecode analysis detects PUSH+AND fusion" {
    log.info("Testing PUSH+AND fusion detection", .{});
    const allocator = testing.allocator;
    
    const bytecode = [_]u8{
        0x60, 0xFF,  // PUSH1 0xFF
        0x16,        // AND
        0x00,        // STOP
    };
    
    const Bytecode = evm_mod.Bytecode(.{
        .max_bytecode_size = 1024,
        .fusions_enabled = true,
    });
    
    var bc = try Bytecode.init(allocator, &bytecode);
    defer bc.deinit();
    
    var iter = bc.createIterator();
    var found_fusion = false;
    
    while (iter.next()) |op_data| {
        switch (op_data) {
            .push_and_fusion => |data| {
                found_fusion = true;
                try testing.expectEqual(@as(u256, 0xFF), data.value);
                log.info("Found PUSH_AND fusion with value {}", .{data.value});
            },
            else => {},
        }
    }
    
    try testing.expect(found_fusion);
}

test "fusion: Bytecode analysis detects PUSH+OR fusion" {
    log.info("Testing PUSH+OR fusion detection", .{});
    const allocator = testing.allocator;
    
    const bytecode = [_]u8{
        0x60, 0x0F,  // PUSH1 0x0F
        0x17,        // OR
        0x00,        // STOP
    };
    
    const Bytecode = evm_mod.Bytecode(.{
        .max_bytecode_size = 1024,
        .fusions_enabled = true,
    });
    
    var bc = try Bytecode.init(allocator, &bytecode);
    defer bc.deinit();
    
    var iter = bc.createIterator();
    var found_fusion = false;
    
    while (iter.next()) |op_data| {
        switch (op_data) {
            .push_or_fusion => |data| {
                found_fusion = true;
                try testing.expectEqual(@as(u256, 0x0F), data.value);
                log.info("Found PUSH_OR fusion with value {}", .{data.value});
            },
            else => {},
        }
    }
    
    try testing.expect(found_fusion);
}

test "fusion: Bytecode analysis detects PUSH+XOR fusion" {
    log.info("Testing PUSH+XOR fusion detection", .{});
    const allocator = testing.allocator;
    
    const bytecode = [_]u8{
        0x60, 0xAA,  // PUSH1 0xAA
        0x18,        // XOR
        0x00,        // STOP
    };
    
    const Bytecode = evm_mod.Bytecode(.{
        .max_bytecode_size = 1024,
        .fusions_enabled = true,
    });
    
    var bc = try Bytecode.init(allocator, &bytecode);
    defer bc.deinit();
    
    var iter = bc.createIterator();
    var found_fusion = false;
    
    while (iter.next()) |op_data| {
        switch (op_data) {
            .push_xor_fusion => |data| {
                found_fusion = true;
                try testing.expectEqual(@as(u256, 0xAA), data.value);
                log.info("Found PUSH_XOR fusion with value {}", .{data.value});
            },
            else => {},
        }
    }
    
    try testing.expect(found_fusion);
}

test "fusion: Bytecode analysis detects PUSH+JUMP fusion" {
    log.info("Testing PUSH+JUMP fusion detection", .{});
    const allocator = testing.allocator;
    
    // Bytecode with PUSH+JUMP
    const bytecode = [_]u8{
        0x60, 0x05,  // PUSH1 5 (jump destination)
        0x56,        // JUMP
        0xFE,        // INVALID
        0xFE,        // INVALID
        0x5B,        // JUMPDEST at position 5
        0x00,        // STOP
    };
    
    const Bytecode = evm_mod.Bytecode(.{
        .max_bytecode_size = 1024,
        .fusions_enabled = true,
    });
    
    var bc = try Bytecode.init(allocator, &bytecode);
    defer bc.deinit();
    
    var iter = bc.createIterator();
    var found_fusion = false;
    
    while (iter.next()) |op_data| {
        switch (op_data) {
            .push_jump_fusion => |data| {
                found_fusion = true;
                try testing.expectEqual(@as(u256, 5), data.value);
                log.info("Found PUSH_JUMP fusion with value {}", .{data.value});
            },
            else => {},
        }
    }
    
    try testing.expect(found_fusion);
}

test "fusion: Bytecode analysis detects PUSH+JUMPI fusion" {
    log.info("Testing PUSH+JUMPI fusion detection", .{});
    const allocator = testing.allocator;
    
    // Bytecode with PUSH+JUMPI (note: condition is separate)
    const bytecode = [_]u8{
        0x60, 0x01,  // PUSH1 1 (condition)
        0x60, 0x07,  // PUSH1 7 (jump destination)
        0x57,        // JUMPI
        0xFE,        // INVALID
        0xFE,        // INVALID
        0x5B,        // JUMPDEST at position 7
        0x00,        // STOP
    };
    
    const Bytecode = evm_mod.Bytecode(.{
        .max_bytecode_size = 1024,
        .fusions_enabled = true,
    });
    
    var bc = try Bytecode.init(allocator, &bytecode);
    defer bc.deinit();
    
    var iter = bc.createIterator();
    var found_fusion = false;
    
    while (iter.next()) |op_data| {
        switch (op_data) {
            .push_jumpi_fusion => |data| {
                found_fusion = true;
                try testing.expectEqual(@as(u256, 7), data.value);
                log.info("Found PUSH_JUMPI fusion with value {}", .{data.value});
            },
            else => {},
        }
    }
    
    try testing.expect(found_fusion);
}

test "fusion: Large PUSH32+ADD fusion" {
    log.info("Testing large PUSH32+ADD fusion", .{});
    const allocator = testing.allocator;
    
    // Bytecode with PUSH32+ADD (tests pointer-based metadata)
    const bytecode = [_]u8{
        0x7F, // PUSH32
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0x01,  // ADD
        0x00,  // STOP
    };
    
    const Bytecode = evm_mod.Bytecode(.{
        .max_bytecode_size = 1024,
        .fusions_enabled = true,
    });
    
    var bc = try Bytecode.init(allocator, &bytecode);
    defer bc.deinit();
    
    var iter = bc.createIterator();
    var found_fusion = false;
    
    while (iter.next()) |op_data| {
        switch (op_data) {
            .push_add_fusion => |data| {
                found_fusion = true;
                const expected_value = std.math.maxInt(u256);
                try testing.expectEqual(expected_value, data.value);
                log.info("Found PUSH32_ADD fusion", .{});
            },
            else => {},
        }
    }
    
    try testing.expect(found_fusion);
}

test "fusion: Multiple fusions in sequence" {
    log.info("Testing multiple sequential fusions", .{});
    const allocator = testing.allocator;
    
    // Bytecode with multiple fusion opportunities
    const bytecode = [_]u8{
        0x60, 0x05,  // PUSH1 5
        0x01,        // ADD
        0x60, 0x03,  // PUSH1 3
        0x02,        // MUL
        0x60, 0x02,  // PUSH1 2
        0x04,        // DIV
        0x00,        // STOP
    };
    
    const Bytecode = evm_mod.Bytecode(.{
        .max_bytecode_size = 1024,
        .fusions_enabled = true,
    });
    
    var bc = try Bytecode.init(allocator, &bytecode);
    defer bc.deinit();
    
    var iter = bc.createIterator();
    var fusion_count: u32 = 0;
    
    while (iter.next()) |op_data| {
        switch (op_data) {
            .push_add_fusion => {
                fusion_count += 1;
                log.info("Found PUSH_ADD fusion", .{});
            },
            .push_mul_fusion => {
                fusion_count += 1;
                log.info("Found PUSH_MUL fusion", .{});
            },
            .push_div_fusion => {
                fusion_count += 1;
                log.info("Found PUSH_DIV fusion", .{});
            },
            .push_sub_fusion,
            .push_and_fusion,
            .push_or_fusion,
            .push_xor_fusion,
            .push_jump_fusion,
            .push_jumpi_fusion => {
                fusion_count += 1;
            },
            else => {},
        }
    }
    
    // Should detect 3 fusions
    try testing.expectEqual(@as(u32, 3), fusion_count);
    log.info("Detected {} fusions in sequence", .{fusion_count});
}

test "fusion: ten-thousand-hashes bytecode with PUSH+JUMP fusion" {
    std.testing.log_level = .err;
    log.info("Testing ten-thousand-hashes bytecode with fusion", .{});
    const allocator = testing.allocator;
    
    // The ten-thousand-hashes DEPLOYMENT bytecode from bench/official/cases/ten-thousand-hashes/bytecode.txt
    const deployment_hex = "6080604052348015600e575f5ffd5b50609780601a5f395ff3fe6080604052348015600e575f5ffd5b50600436106026575f3560e01c806330627b7c14602a575b5f5ffd5b60306032565b005b5f5b614e20811015605e5760408051602081018390520160408051601f19818403019052526001016034565b5056fea26469706673582212202c247f39d615d7f66942cd6ed505d8ea34fbfcbe16ac875ed08c4a9c229325f364736f6c634300081e0033";
    
    // Convert hex to bytes
    var deployment_buf: [512]u8 = undefined;
    const deployment_len = deployment_hex.len / 2;
    for (0..deployment_len) |i| {
        const byte_str = deployment_hex[i*2..i*2+2];
        deployment_buf[i] = std.fmt.parseInt(u8, byte_str, 16) catch unreachable;
    }
    const deployment_bytecode = deployment_buf[0..deployment_len];
    
    log.info("Deployment bytecode is {} bytes", .{deployment_bytecode.len});
    
    // Extract the runtime code (after position 0x1a)
    // The init code at 0x13 does PUSH1 0x1a (position 26) for CODECOPY
    const runtime_start = 0x1a;
    const runtime_bytecode = deployment_bytecode[runtime_start..];
    
    log.info("Runtime bytecode starts at 0x{x}, is {} bytes", .{runtime_start, runtime_bytecode.len});
    
    // Analyze the RUNTIME bytecode for fusion detection
    const Bytecode = evm_mod.Bytecode(.{
        .max_bytecode_size = 1024,
        .fusions_enabled = true,
    });
    
    var bc = try Bytecode.init(allocator, runtime_bytecode);
    defer bc.deinit();
    
    // Pretty print the runtime bytecode to verify correct PCs
    const pretty = try bc.pretty_print(allocator);
    defer allocator.free(pretty);
    log.info("Runtime bytecode analysis (first 2000 chars):\n{s}", .{pretty[0..@min(pretty.len, 2000)]});
    
    // Count fusions detected
    var iter = bc.createIterator();
    var fusion_count: u32 = 0;
    var push_jump_count: u32 = 0;
    
    while (iter.next()) |op_data| {
        switch (op_data) {
            .push_jump_fusion => |data| {
                push_jump_count += 1;
                log.info("Found PUSH_JUMP fusion with value 0x{x}", .{data.value});
            },
            .push_jumpi_fusion => |data| {
                fusion_count += 1;
                log.info("Found PUSH_JUMPI fusion with value 0x{x}", .{data.value});
            },
            .push_add_fusion, .push_sub_fusion, .push_mul_fusion, 
            .push_div_fusion, .push_and_fusion, .push_or_fusion, 
            .push_xor_fusion => {
                fusion_count += 1;
            },
            else => {},
        }
    }
    
    // We expect to find some PUSH+JUMP fusions in this bytecode
    log.info("Found {} PUSH_JUMP fusions and {} other fusions", .{push_jump_count, fusion_count});
    try testing.expect(push_jump_count > 0 or fusion_count > 0);
    
    // Now test execution with proper deployment and call flow
    const Database = evm_mod.Database;
    var db = Database.init(allocator);
    defer db.deinit();
    
    const BlockInfo = evm_mod.BlockInfo;
    const TransactionContext = evm_mod.TransactionContext;
    const DefaultEvm = evm_mod.DefaultEvm;
    
    const block_info = BlockInfo{
        .chain_id = 1,
        .number = 1,
        .timestamp = 1000,
        .difficulty = 100,
        .gas_limit = 30000000,
        .coinbase = Address.ZERO,
        .base_fee = 0,
        .blob_base_fee = 0,
        .prev_randao = [_]u8{0} ** 32,
        .blob_versioned_hashes = &.{},
    };
    
    const tx_context = TransactionContext{
        .gas_limit = 10000000,
        .coinbase = Address.ZERO,
        .chain_id = 1,
    };
    
    var evm = try DefaultEvm.init(allocator, &db, block_info, tx_context, 0, Address.ZERO);
    defer evm.deinit();
    
    // Step 1: Deploy the contract using CREATE (deployment bytecode)
    log.info("Deploying contract with deployment bytecode...", .{});
    const create_params = DefaultEvm.CallParams{
        .create = .{
            .caller = Address.ZERO,
            .value = 0,
            .init_code = deployment_bytecode,  // Use the full deployment bytecode as bytes
            .gas = 1000000,
        },
    };
    
    const deploy_result = evm.call(create_params);
    defer if (deploy_result.output.len > 0) allocator.free(deploy_result.output);
    
    // Deployment should succeed
    try testing.expect(deploy_result.success);
    
    // Prefer created_address if available; older path used output[0..20]
    const contract_address = if (deploy_result.created_address) |addr| addr else blk: {
        try testing.expect(deploy_result.output.len == 20);
        break :blk Address{ .bytes = deploy_result.output[0..20].* };
    };
    log.info("Contract deployed successfully with gas_left: {}", .{deploy_result.gas_left});
    log.info("Contract deployed successfully", .{});
    
    // Step 2: Call the deployed contract's function
    log.info("Calling contract function 0x30627b7c...", .{});
    const calldata = [_]u8{0x30, 0x62, 0x7b, 0x7c}; // Function selector as bytes
    
    const call_params = DefaultEvm.CallParams{
        .call = .{
            .caller = Address.ZERO,
            .to = contract_address,
            .value = 0,
            .input = &calldata,
            .gas = 5000000,
        },
    };
    
    const call_result = evm.call(call_params);
    
    // The function should execute successfully with fusions in the runtime code
    try testing.expect(call_result.success);
    log.info("Function executed successfully with fusions enabled! Gas left: {}", .{call_result.gas_left});
}

test "fusion: No fusion when disabled" {
    log.info("Testing that fusion doesn't occur when disabled", .{});
    const allocator = testing.allocator;
    
    const bytecode = [_]u8{
        0x60, 0x05,  // PUSH1 5
        0x01,        // ADD
        0x00,        // STOP
    };
    
    // Create bytecode analyzer with fusion DISABLED
    const Bytecode = evm_mod.Bytecode(.{
        .max_bytecode_size = 1024,
        .fusions_enabled = false,  // Disable fusion
    });
    
    var bc = try Bytecode.init(allocator, &bytecode);
    defer bc.deinit();
    
    var iter = bc.createIterator();
    var found_fusion = false;
    var found_regular_push = false;
    var found_regular_add = false;
    
    while (iter.next()) |op_data| {
        switch (op_data) {
            .push_add_fusion => {
                found_fusion = true;
            },
            .push => |data| {
                found_regular_push = true;
                try testing.expectEqual(@as(u8, 1), data.size);
                try testing.expectEqual(@as(u256, 5), data.value);
            },
            .regular => |data| {
                if (data.opcode == 0x01) { // ADD
                    found_regular_add = true;
                }
            },
            else => {},
        }
    }
    
    // Should NOT find fusion, but should find regular opcodes
    try testing.expect(!found_fusion);
    try testing.expect(found_regular_push);
    try testing.expect(found_regular_add);
    
    log.info("Confirmed: no fusion when disabled", .{});
}
