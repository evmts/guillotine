/// Comprehensive tests for the ShadowTracer implementation
/// Tests shadow execution tracer that compares Main EVM with Mini EVM in per-block mode
/// Based on the testing strategy from 03b-shadow-execution-refactor-guide.md

const std = @import("std");
const testing = std.testing;
const builtin = @import("builtin");
const build_options = @import("build_options");

// Import EVM and related modules
const Evm = @import("evm").Evm;
const MemoryDatabase = @import("evm").MemoryDatabase;
const ShadowTracer = @import("evm").tracing.ShadowTracer;
const DebugShadow = @import("evm").shadow;
const CallParams = @import("evm").CallParams;
const primitives = @import("primitives");
const Address = primitives.Address.Address;

test "shadow tracer: basic arithmetic with per-block comparison" {
    if (!comptime (@hasDecl(build_options, "enable_shadow_compare") and build_options.enable_shadow_compare)) {
        return;
    }
    
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var evm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, 0, false, null);
    defer evm.deinit();
    
    // Create shadow tracer with per-block mode
    var shadow_tracer = try ShadowTracer.init(
        allocator,
        &evm,
        .per_block,
        .{ .compare_memory = true },
    );
    defer shadow_tracer.deinit();
    
    // Attach tracer and enable per-block shadow mode
    evm.set_tracer(shadow_tracer.handle());
    evm.set_shadow_mode(.per_block);
    
    // Test code: arithmetic operations
    const code = [_]u8{
        0x60, 0x05, // PUSH1 5
        0x60, 0x0a, // PUSH1 10
        0x01,       // ADD
        0x60, 0x02, // PUSH1 2
        0x02,       // MUL
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    // Deploy contract
    const contract_addr = try primitives.Address.from_hex("0x1234567890abcdef1234567890abcdef12345678");
    const code_hash = try memory_db.set_code(&code);
    try memory_db.set_account(contract_addr, .{
        .balance = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
        .nonce = 0,
    });
    
    // Execute
    const result = try evm.call(.{
        .call = .{
            .caller = primitives.Address.ZERO,
            .to = contract_addr,
            .value = 0,
            .input = &.{},
            .gas = 100000,
        },
    });
    
    // Verify execution succeeded
    try testing.expect(result.success);
    
    // Verify shadow tracer captured blocks and found no mismatches
    try testing.expect(shadow_tracer.blocks_compared > 0);
    try testing.expect(!shadow_tracer.has_mismatches());
    
    // Verify result is correct (5 + 10) * 2 = 30
    if (result.output) |output| {
        try testing.expectEqual(@as(usize, 32), output.len);
        try testing.expectEqual(@as(u8, 30), output[31]);
    }
    
    // Get and verify report
    const report = try shadow_tracer.get_mismatch_report(allocator);
    defer allocator.free(report);
    
    try testing.expect(std.mem.indexOf(u8, report, "✓ All comparisons passed") != null);
}

test "shadow tracer: control flow with jumps" {
    if (!comptime (@hasDecl(build_options, "enable_shadow_compare") and build_options.enable_shadow_compare)) {
        return;
    }
    
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var evm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, 0, false, null);
    defer evm.deinit();
    
    // Create shadow tracer
    var shadow_tracer = try ShadowTracer.init(
        allocator,
        &evm,
        .per_block,
        .{ .compare_memory = true },
    );
    defer shadow_tracer.deinit();
    
    evm.set_tracer(shadow_tracer.handle());
    evm.set_shadow_mode(.per_block);
    
    // Test code with conditional jump
    const code = [_]u8{
        0x60, 0x01, // PUSH1 1 (condition true)
        0x60, 0x0C, // PUSH1 12 (jump destination)
        0x57,       // JUMPI
        0x60, 0xFF, // PUSH1 255 (should not execute)
        0x60, 0x00, // PUSH1 0 (should not execute)
        0x52,       // MSTORE (should not execute)
        0x5b,       // JUMPDEST (at position 12)
        0x60, 0x42, // PUSH1 0x42 (should execute)
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    const contract_addr = try primitives.Address.from_hex("0x2234567890abcdef1234567890abcdef12345678");
    const code_hash = try memory_db.set_code(&code);
    try memory_db.set_account(contract_addr, .{
        .balance = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
        .nonce = 0,
    });
    
    const result = try evm.call(.{
        .call = .{
            .caller = primitives.Address.ZERO,
            .to = contract_addr,
            .value = 0,
            .input = &.{},
            .gas = 100000,
        },
    });
    
    try testing.expect(result.success);
    try testing.expect(!shadow_tracer.has_mismatches());
    
    // Verify correct execution path (0x42, not 0xFF)
    if (result.output) |output| {
        try testing.expectEqual(@as(u8, 0x42), output[31]);
    }
}

test "shadow tracer: memory operations with comparison" {
    if (!comptime (@hasDecl(build_options, "enable_shadow_compare") and build_options.enable_shadow_compare)) {
        return;
    }
    
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var evm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, 0, false, null);
    defer evm.deinit();
    
    // Enable memory content comparison for detailed verification
    var shadow_tracer = try ShadowTracer.init(
        allocator,
        &evm,
        .per_block,
        .{ 
            .compare_memory = true,
            .compare_memory_content = true,
        },
    );
    defer shadow_tracer.deinit();
    
    evm.set_tracer(shadow_tracer.handle());
    evm.set_shadow_mode(.per_block);
    
    // Test memory operations
    const code = [_]u8{
        0x60, 0x42, // PUSH1 0x42 (value)
        0x60, 0x20, // PUSH1 0x20 (offset 32)
        0x52,       // MSTORE
        0x60, 0xAA, // PUSH1 0xAA (another value)
        0x60, 0x40, // PUSH1 0x40 (offset 64)
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32 (offset to load from)
        0x51,       // MLOAD
        0x60, 0x00, // PUSH1 0 (offset to store result)
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32 (return size)
        0x60, 0x00, // PUSH1 0 (return offset)
        0xf3,       // RETURN
    };
    
    const contract_addr = try primitives.Address.from_hex("0x3234567890abcdef1234567890abcdef12345678");
    const code_hash = try memory_db.set_code(&code);
    try memory_db.set_account(contract_addr, .{
        .balance = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
        .nonce = 0,
    });
    
    const result = try evm.call(.{
        .call = .{
            .caller = primitives.Address.ZERO,
            .to = contract_addr,
            .value = 0,
            .input = &.{},
            .gas = 100000,
        },
    });
    
    try testing.expect(result.success);
    try testing.expect(!shadow_tracer.has_mismatches());
    
    // Verify loaded value (0x42) is returned
    if (result.output) |output| {
        try testing.expectEqual(@as(u8, 0x42), output[31]);
    }
}

test "shadow tracer: per-call mode comparison" {
    if (!comptime (@hasDecl(build_options, "enable_shadow_compare") and build_options.enable_shadow_compare)) {
        return;
    }
    
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var evm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, 0, false, null);
    defer evm.deinit();
    
    // Create shadow tracer with per-call mode (faster, less detailed)
    var shadow_tracer = try ShadowTracer.init(
        allocator,
        &evm,
        .per_call,
        .{ .compare_memory = false }, // No need for detailed memory comparison
    );
    defer shadow_tracer.deinit();
    
    evm.set_tracer(shadow_tracer.handle());
    evm.set_shadow_mode(.per_call);
    
    // Simple test code
    const code = [_]u8{
        0x60, 0x07, // PUSH1 7
        0x60, 0x08, // PUSH1 8
        0x01,       // ADD
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    const contract_addr = try primitives.Address.from_hex("0x4234567890abcdef1234567890abcdef12345678");
    const code_hash = try memory_db.set_code(&code);
    try memory_db.set_account(contract_addr, .{
        .balance = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
        .nonce = 0,
    });
    
    const result = try evm.call(.{
        .call = .{
            .caller = primitives.Address.ZERO,
            .to = contract_addr,
            .value = 0,
            .input = &.{},
            .gas = 100000,
        },
    });
    
    try testing.expect(result.success);
    try testing.expect(!shadow_tracer.has_mismatches());
    
    // Verify result (7 + 8 = 15)
    if (result.output) |output| {
        try testing.expectEqual(@as(u8, 15), output[31]);
    }
    
    // Per-call mode should have fewer blocks compared but no mismatches
    const report = try shadow_tracer.get_mismatch_report(allocator);
    defer allocator.free(report);
    
    try testing.expect(std.mem.indexOf(u8, report, "Mode: per_call") != null);
}

test "shadow tracer: stack operations with deep comparison" {
    if (!comptime (@hasDecl(build_options, "enable_shadow_compare") and build_options.enable_shadow_compare)) {
        return;
    }
    
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var evm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, 0, false, null);
    defer evm.deinit();
    
    var shadow_tracer = try ShadowTracer.init(
        allocator,
        &evm,
        .per_block,
        .{ .compare_memory = true },
    );
    defer shadow_tracer.deinit();
    
    evm.set_tracer(shadow_tracer.handle());
    evm.set_shadow_mode(.per_block);
    
    // Complex stack operations
    const code = [_]u8{
        0x60, 0x01, // PUSH1 1
        0x60, 0x02, // PUSH1 2
        0x60, 0x03, // PUSH1 3
        0x60, 0x04, // PUSH1 4
        0x80,       // DUP1 (duplicate top: 4)
        0x82,       // DUP3 (duplicate 3rd from top: 2)
        0x91,       // SWAP2 (swap top with 3rd)
        0x01,       // ADD
        0x01,       // ADD
        0x01,       // ADD
        0x01,       // ADD
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    const contract_addr = try primitives.Address.from_hex("0x5234567890abcdef1234567890abcdef12345678");
    const code_hash = try memory_db.set_code(&code);
    try memory_db.set_account(contract_addr, .{
        .balance = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
        .nonce = 0,
    });
    
    const result = try evm.call(.{
        .call = .{
            .caller = primitives.Address.ZERO,
            .to = contract_addr,
            .value = 0,
            .input = &.{},
            .gas = 100000,
        },
    });
    
    try testing.expect(result.success);
    try testing.expect(!shadow_tracer.has_mismatches());
    try testing.expect(shadow_tracer.blocks_compared > 5); // Multiple blocks executed
}

test "shadow tracer: error handling with consistent failures" {
    if (!comptime (@hasDecl(build_options, "enable_shadow_compare") and build_options.enable_shadow_compare)) {
        return;
    }
    
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var evm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, 0, false, null);
    defer evm.deinit();
    
    var shadow_tracer = try ShadowTracer.init(
        allocator,
        &evm,
        .per_block,
        .{ .compare_memory = true },
    );
    defer shadow_tracer.deinit();
    
    evm.set_tracer(shadow_tracer.handle());
    evm.set_shadow_mode(.per_block);
    
    // Code with stack underflow error
    const code = [_]u8{
        0x01, // ADD (but no values on stack - should fail)
    };
    
    const contract_addr = try primitives.Address.from_hex("0x6234567890abcdef1234567890abcdef12345678");
    const code_hash = try memory_db.set_code(&code);
    try memory_db.set_account(contract_addr, .{
        .balance = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
        .nonce = 0,
    });
    
    const result = try evm.call(.{
        .call = .{
            .caller = primitives.Address.ZERO,
            .to = contract_addr,
            .value = 0,
            .input = &.{},
            .gas = 100000,
        },
    });
    
    // Both EVMs should fail consistently
    try testing.expect(!result.success);
    
    // No mismatch should be detected since both failed the same way
    try testing.expect(!shadow_tracer.has_mismatches());
}

test "shadow tracer: gas consumption verification" {
    if (!comptime (@hasDecl(build_options, "enable_shadow_compare") and build_options.enable_shadow_compare)) {
        return;
    }
    
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var evm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, 0, false, null);
    defer evm.deinit();
    
    var shadow_tracer = try ShadowTracer.init(
        allocator,
        &evm,
        .per_block,
        .{ .compare_memory = true },
    );
    defer shadow_tracer.deinit();
    
    evm.set_tracer(shadow_tracer.handle());
    evm.set_shadow_mode(.per_block);
    
    const initial_gas: u64 = 50000;
    
    // Gas-consuming operations
    const code = [_]u8{
        0x60, 0x01, // PUSH1 1 (3 gas)
        0x60, 0x02, // PUSH1 2 (3 gas)
        0x02,       // MUL (5 gas)
        0x60, 0x00, // PUSH1 0 (3 gas)
        0x52,       // MSTORE (6 gas + memory expansion)
        0x59,       // MSIZE (2 gas)
        0x60, 0x00, // PUSH1 0 (3 gas)
        0x51,       // MLOAD (3 gas)
        0x00,       // STOP (0 gas)
    };
    
    const contract_addr = try primitives.Address.from_hex("0x7234567890abcdef1234567890abcdef12345678");
    const code_hash = try memory_db.set_code(&code);
    try memory_db.set_account(contract_addr, .{
        .balance = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
        .nonce = 0,
    });
    
    const result = try evm.call(.{
        .call = .{
            .caller = primitives.Address.ZERO,
            .to = contract_addr,
            .value = 0,
            .input = &.{},
            .gas = initial_gas,
        },
    });
    
    try testing.expect(result.success);
    try testing.expect(!shadow_tracer.has_mismatches());
    
    // Verify gas was consumed consistently
    try testing.expect(result.gas_left < initial_gas);
    try testing.expect(result.gas_left > 0); // Should not run out of gas
}

test "shadow tracer: complex scenario with multiple features" {
    if (!comptime (@hasDecl(build_options, "enable_shadow_compare") and build_options.enable_shadow_compare)) {
        return;
    }
    
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var evm = try Evm.init(allocator, memory_db.to_database_interface(), null, null, null, 0, false, null);
    defer evm.deinit();
    
    var shadow_tracer = try ShadowTracer.init(
        allocator,
        &evm,
        .per_block,
        .{ 
            .compare_memory = true,
            .compare_memory_content = true,
        },
    );
    defer shadow_tracer.deinit();
    
    evm.set_tracer(shadow_tracer.handle());
    evm.set_shadow_mode(.per_block);
    
    // Complex scenario: arithmetic, memory, control flow, stack operations
    const code = [_]u8{
        // Calculate fibonacci(5) iteratively
        0x60, 0x00, // PUSH1 0 (a = 0)
        0x60, 0x01, // PUSH1 1 (b = 1)
        0x60, 0x05, // PUSH1 5 (n = 5)
        
        // Loop: while n > 0
        0x5b,       // JUMPDEST (loop start at position 8)
        0x80,       // DUP1 (duplicate n)
        0x15,       // ISZERO (check if n == 0)
        0x60, 0x20, // PUSH1 32 (exit address)
        0x57,       // JUMPI (jump if n == 0)
        
        // Fibonacci step: temp = a + b; a = b; b = temp; n--
        0x82,       // DUP3 (get a)
        0x81,       // DUP2 (get b)
        0x01,       // ADD (temp = a + b)
        0x83,       // DUP4 (get a copy for later)
        0x91,       // SWAP2 (move b to position of a)
        0x50,       // POP (remove old a)
        0x90,       // SWAP1 (move temp to position of b)
        0x60, 0x01, // PUSH1 1
        0x03,       // SUB (n--)
        0x60, 0x08, // PUSH1 8 (loop start)
        0x56,       // JUMP
        
        // Exit: store result and return
        0x5b,       // JUMPDEST (exit at position 32)
        0x50,       // POP (remove n)
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE (store b at offset 0)
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    const contract_addr = try primitives.Address.from_hex("0x8234567890abcdef1234567890abcdef12345678");
    const code_hash = try memory_db.set_code(&code);
    try memory_db.set_account(contract_addr, .{
        .balance = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
        .nonce = 0,
    });
    
    const result = try evm.call(.{
        .call = .{
            .caller = primitives.Address.ZERO,
            .to = contract_addr,
            .value = 0,
            .input = &.{},
            .gas = 1000000, // Generous gas for complex computation
        },
    });
    
    try testing.expect(result.success);
    try testing.expect(!shadow_tracer.has_mismatches());
    
    // Verify fibonacci(5) = 5
    if (result.output) |output| {
        try testing.expectEqual(@as(u8, 5), output[31]);
    }
    
    // Verify significant number of blocks were compared
    try testing.expect(shadow_tracer.blocks_compared > 10);
    
    // Get comprehensive report
    const report = try shadow_tracer.get_mismatch_report(allocator);
    defer allocator.free(report);
    
    // Report should indicate success
    try testing.expect(std.mem.indexOf(u8, report, "✓ All comparisons passed") != null);
    try testing.expect(std.mem.indexOf(u8, report, "per_block") != null);
}