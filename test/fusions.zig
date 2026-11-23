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

test "fusion: ten-thousand-hashes CREATE matches unfused initcode" {
    const allocator = testing.allocator;
    const fixture = try std.fs.cwd().readFileAlloc(allocator, "fixtures/ten-thousand-hashes/bytecode.txt", 4096);
    defer allocator.free(fixture);
    const hex = std.mem.trim(u8, fixture, " \t\r\n");
    const code = try allocator.alloc(u8, hex.len / 2);
    defer allocator.free(code);
    _ = try std.fmt.hexToBytes(code, hex);
    try testing.expect(code.len > 0x1a);

    var expected_gas: u64 = 0;
    inline for (.{ false, true }) |enabled| {
        const Engine = Evm(.{
            .enable_fusion = enabled,
            .tracer_config = .{ .enabled = true },
        });
        var db = evm_mod.Database.init(allocator);
        defer db.deinit();
        var engine = try Engine.init(allocator, &db, .{
            .chain_id = 1,
            .number = 1,
            .timestamp = 1000,
            .difficulty = 100,
            .gas_limit = 30_000_000,
            .coinbase = Address.ZERO,
            .base_fee = 0,
            .blob_base_fee = 0,
            .prev_randao = @splat(0),
            .blob_versioned_hashes = &.{},
        }, .{ .gas_limit = 10_000_000, .coinbase = Address.ZERO, .chain_id = 1 }, 0, Address.ZERO);
        defer engine.deinit();

        var result = engine.call(.{ .create = .{
            .caller = Address.ZERO,
            .value = 0,
            .init_code = code,
            .gas = 1_000_000,
        } });
        defer result.deinit(allocator);
        if (!result.success) {
            log.err("CREATE with fusion={} failed: {s}; remaining gas {}", .{
                enabled, result.error_info orelse "no error returned", result.gas_left,
            });
            for (engine.tracer.recent_opcodes.read()) |entry| {
                log.err("CREATE schedule[{}] opcode={s} gas={}", .{ entry.schedule_index, entry.opcode_name, entry.gas_before });
            }
        }
        try testing.expect(result.success);
        try testing.expect(result.created_address != null);
        try testing.expectEqualSlices(u8, code[0x1a..], result.output);
        if (enabled) {
            try testing.expectEqual(expected_gas, result.gas_left);
        } else {
            expected_gas = result.gas_left;
        }
    }
}

test "fusion: ten-thousand-hashes bytecode with PUSH+JUMP fusion" {
    const allocator = testing.allocator;
    const fixture = try std.fs.cwd().readFileAlloc(allocator, "fixtures/ten-thousand-hashes/bytecode.txt", 4096);
    defer allocator.free(fixture);
    const hex = std.mem.trim(u8, fixture, " \t\r\n");
    const code = try allocator.alloc(u8, hex.len / 2);
    defer allocator.free(code);
    _ = try std.fmt.hexToBytes(code, hex);
    try testing.expect(code.len > 0x1a);

    const Bytecode = evm_mod.Bytecode(.{ .max_bytecode_size = 1024 });
    var bytecode = try Bytecode.init(allocator, code[0x1a..]);
    defer bytecode.deinit();
    var iter = bytecode.createIterator();
    var jumps: usize = 0;
    while (iter.next()) |op| {
        switch (op) {
            .push_jump_fusion, .push_jumpi_fusion => jumps += 1,
            else => {},
        }
    }
    try testing.expect(jumps > 0);

    // The 20,000-iteration fixture grows memory on every iteration.
    const gas_limit = evm_mod.eips.TX_GAS_LIMIT_CAP;
    const calldata = [_]u8{ 0x30, 0x62, 0x7b, 0x7c };
    var expected_gas: u64 = 0;
    inline for (.{ false, true }) |enabled| {
        const Engine = Evm(.{
            .enable_fusion = enabled,
            .tracer_config = .{ .enabled = true },
        });
        var db = evm_mod.Database.init(allocator);
        defer db.deinit();
        var engine = try Engine.init(allocator, &db, .{
            .chain_id = 1,
            .number = 1,
            .timestamp = 1000,
            .difficulty = 100,
            .gas_limit = 30_000_000,
            .coinbase = Address.ZERO,
            .base_fee = 0,
            .blob_base_fee = 0,
            .prev_randao = @splat(0),
            .blob_versioned_hashes = &.{},
        }, .{ .gas_limit = gas_limit, .coinbase = Address.ZERO, .chain_id = 1 }, 0, Address.ZERO);
        defer engine.deinit();

        var deployment = engine.call(.{ .create = .{
            .caller = Address.ZERO,
            .value = 0,
            .init_code = code,
            .gas = 1_000_000,
        } });
        defer deployment.deinit(allocator);
        try testing.expect(deployment.success);
        const address = deployment.created_address orelse return error.MissingContractAddress;

        var result = engine.call(.{ .call = .{
            .caller = Address.ZERO,
            .to = address,
            .value = 0,
            .input = &calldata,
            .gas = gas_limit,
        } });
        defer result.deinit(allocator);
        if (!result.success) {
            log.err("CALL with fusion={} failed: {s}; remaining gas {}", .{
                enabled, result.error_info orelse "no error returned", result.gas_left,
            });
            for (engine.tracer.recent_opcodes.read()) |entry| {
                log.err("CALL schedule[{}] opcode={s} gas={} memory={}", .{
                    entry.schedule_index, entry.opcode_name, entry.gas_before, entry.memory_size,
                });
            }
        }
        try testing.expect(result.success);
        if (enabled) {
            try testing.expectEqual(expected_gas, result.gas_left);
        } else {
            expected_gas = result.gas_left;
        }
    }
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
