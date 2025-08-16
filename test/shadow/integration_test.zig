const std = @import("std");
const testing = std.testing;
const Evm = @import("evm").Evm;
const MemoryDatabase = @import("evm").MemoryDatabase;
const primitives = @import("primitives");
const DebugShadow = @import("evm").shadow;
const ShadowTracer = @import("evm").tracing.ShadowTracer;
const CallParams = @import("evm").CallParams;
const ExecutionError = @import("evm").ExecutionError;
const opcode_mod = @import("evm").opcodes.opcode;

test "shadow execution basic arithmetic operations" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();
    
    // Enable per-call shadow mode (comparison happens at end of call)
    evm.set_shadow_mode(.per_call);
    
    // Simple arithmetic: 5 + 10 = 15
    const code = [_]u8{
        0x60, 0x05, // PUSH1 5
        0x60, 0x0a, // PUSH1 10
        0x01,       // ADD
        0x00,       // STOP
    };
    
    // Set code for address
    const contract_addr = primitives.Address.from_hex("0x1234567890abcdef1234567890abcdef12345678") catch unreachable;
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
    
    // Check success
    try testing.expect(result.success);
    
    // Check for mismatches
    if (evm.take_last_shadow_mismatch()) |m| {
        var mismatch = m;
        defer mismatch.deinit(allocator);
        std.log.err("Unexpected shadow mismatch: field={s}, main={s}, mini={s}", .{
            @tagName(mismatch.field),
            mismatch.lhs_summary,
            mismatch.rhs_summary,
        });
        return error.UnexpectedShadowMismatch;
    }
}

test "shadow execution with jumps" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();
    
    // Enable per-call shadow mode (comparison happens at end of call)
    evm.set_shadow_mode(.per_call);
    
    // Code with unconditional jump
    const code = [_]u8{
        0x60, 0x05, // PUSH1 5 (destination)
        0x56,       // JUMP
        0x00,       // STOP (unreachable)
        0x00,       // STOP (unreachable)
        0x5b,       // JUMPDEST (at position 5)
        0x60, 0x42, // PUSH1 0x42
        0x00,       // STOP
    };
    
    const contract_addr = primitives.Address.from_hex("0x2234567890abcdef1234567890abcdef12345678") catch unreachable;
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
    
    // Check for mismatches
    if (evm.take_last_shadow_mismatch()) |m| {
        var mismatch = m;
        defer mismatch.deinit(allocator);
        std.log.err("Unexpected shadow mismatch: field={s}, main={s}, mini={s}", .{
            @tagName(mismatch.field),
            mismatch.lhs_summary,
            mismatch.rhs_summary,
        });
        return error.UnexpectedShadowMismatch;
    }
}

test "shadow execution with conditional jump" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();
    
    // Enable per-call shadow mode (comparison happens at end of call)
    evm.set_shadow_mode(.per_call);
    
    // Code with conditional jump (JUMPI)
    const code = [_]u8{
        0x60, 0x01, // PUSH1 1 (condition: true)
        0x60, 0x07, // PUSH1 7 (destination)
        0x57,       // JUMPI
        0x60, 0xff, // PUSH1 0xff (unreachable)
        0x00,       // STOP (unreachable)
        0x5b,       // JUMPDEST (at position 7)
        0x60, 0x42, // PUSH1 0x42
        0x00,       // STOP
    };
    
    const contract_addr = primitives.Address.from_hex("0x3234567890abcdef1234567890abcdef12345678") catch unreachable;
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
    
    // Check for mismatches
    if (evm.take_last_shadow_mismatch()) |m| {
        var mismatch = m;
        defer mismatch.deinit(allocator);
        std.log.err("Unexpected shadow mismatch: field={s}, main={s}, mini={s}", .{
            @tagName(mismatch.field),
            mismatch.lhs_summary,
            mismatch.rhs_summary,
        });
        return error.UnexpectedShadowMismatch;
    }
}

test "shadow execution with memory operations" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();
    
    // Enable per-call shadow mode (comparison happens at end of call)
    evm.set_shadow_mode(.per_call);
    
    // Code with memory operations
    const code = [_]u8{
        0x60, 0x42, // PUSH1 0x42 (value)
        0x60, 0x00, // PUSH1 0x00 (offset)
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 0x20 (size)
        0x60, 0x00, // PUSH1 0x00 (offset)
        0xf3,       // RETURN
    };
    
    const contract_addr = primitives.Address.from_hex("0x4234567890abcdef1234567890abcdef12345678") catch unreachable;
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
    
    // Check output
    try testing.expect(result.output != null);
    if (result.output) |output| {
        try testing.expect(output.len == 32);
        try testing.expectEqual(@as(u8, 0x42), output[31]);
    }
    
    // Check for mismatches
    if (evm.take_last_shadow_mismatch()) |m| {
        var mismatch = m;
        defer mismatch.deinit(allocator);
        std.log.err("Unexpected shadow mismatch: field={s}, main={s}, mini={s}", .{
            @tagName(mismatch.field),
            mismatch.lhs_summary,
            mismatch.rhs_summary,
        });
        return error.UnexpectedShadowMismatch;
    }
}

test "shadow execution with stack operations" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();
    
    // Enable per-call shadow mode (comparison happens at end of call)
    evm.set_shadow_mode(.per_call);
    
    // Code with various stack operations
    const code = [_]u8{
        0x60, 0x01, // PUSH1 1
        0x60, 0x02, // PUSH1 2
        0x60, 0x03, // PUSH1 3
        0x80,       // DUP1 (duplicate top)
        0x81,       // DUP2 (duplicate 2nd from top)
        0x90,       // SWAP1 (swap top two)
        0x01,       // ADD
        0x01,       // ADD
        0x01,       // ADD
        0x00,       // STOP
    };
    
    const contract_addr = primitives.Address.from_hex("0x5234567890abcdef1234567890abcdef12345678") catch unreachable;
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
    
    // Check for mismatches
    if (evm.take_last_shadow_mismatch()) |m| {
        var mismatch = m;
        defer mismatch.deinit(allocator);
        std.log.err("Unexpected shadow mismatch: field={s}, main={s}, mini={s}", .{
            @tagName(mismatch.field),
            mismatch.lhs_summary,
            mismatch.rhs_summary,
        });
        return error.UnexpectedShadowMismatch;
    }
}

test "shadow execution with tracer - per-block mode" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();
    
    // Create shadow tracer with per-block mode for detailed comparison
    var shadow_tracer = try ShadowTracer.init(
        allocator, 
        &evm, 
        .per_block,
        .{ .compare_memory = true }
    );
    defer shadow_tracer.deinit();
    
    // Attach tracer and enable per-block shadow mode
    evm.set_tracer(shadow_tracer.handle());
    evm.set_shadow_mode(.per_block);
    
    // Code with multiple instruction blocks
    const code = [_]u8{
        0x60, 0x05, // PUSH1 5        - Block 1
        0x60, 0x0a, // PUSH1 10       - Block 2
        0x01,       // ADD            - Block 3
        0x60, 0x00, // PUSH1 0        - Block 4
        0x52,       // MSTORE         - Block 5
        0x60, 0x20, // PUSH1 32       - Block 6
        0x60, 0x00, // PUSH1 0        - Block 7
        0xf3,       // RETURN         - Block 8
    };
    
    const contract_addr = primitives.Address.from_hex("0x6234567890abcdef1234567890abcdef12345678") catch unreachable;
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
    
    // Check that blocks were compared and no mismatches found
    try testing.expect(shadow_tracer.blocks_compared > 0);
    try testing.expectEqual(@as(usize, 0), shadow_tracer.mismatches.items.len);
    
    // Verify return data
    if (result.output) |output| {
        try testing.expectEqual(@as(usize, 32), output.len);
        try testing.expectEqual(@as(u8, 15), output[31]); // 5 + 10 = 15
    }
}

test "shadow execution with per-call mode" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();
    
    // Enable per-call shadow mode
    evm.set_shadow_mode(.per_call);
    
    // Simple code
    const code = [_]u8{
        0x60, 0x42, // PUSH1 0x42
        0x60, 0x00, // PUSH1 0x00
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 0x20
        0x60, 0x00, // PUSH1 0x00
        0xf3,       // RETURN
    };
    
    const contract_addr = primitives.Address.from_hex("0x7234567890abcdef1234567890abcdef12345678") catch unreachable;
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
    
    // Check for mismatches
    if (evm.take_last_shadow_mismatch()) |m| {
        var mismatch = m;
        defer mismatch.deinit(allocator);
        std.log.err("Unexpected shadow mismatch: field={s}, main={s}, mini={s}", .{
            @tagName(mismatch.field),
            mismatch.lhs_summary,
            mismatch.rhs_summary,
        });
        return error.UnexpectedShadowMismatch;
    }
}

test "shadow execution with PUSH operations" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();
    
    // Enable per-call shadow mode (comparison happens at end of call)
    evm.set_shadow_mode(.per_call);
    
    // Code with various PUSH operations
    const code = [_]u8{
        0x5f,       // PUSH0
        0x60, 0x01, // PUSH1 1
        0x61, 0x01, 0x02, // PUSH2 0x0102
        0x62, 0x01, 0x02, 0x03, // PUSH3 0x010203
        0x01,       // ADD
        0x01,       // ADD
        0x01,       // ADD
        0x00,       // STOP
    };
    
    const contract_addr = primitives.Address.from_hex("0x8234567890abcdef1234567890abcdef12345678") catch unreachable;
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
    
    // Check for mismatches
    if (evm.take_last_shadow_mismatch()) |m| {
        var mismatch = m;
        defer mismatch.deinit(allocator);
        std.log.err("Unexpected shadow mismatch: field={s}, main={s}, mini={s}", .{
            @tagName(mismatch.field),
            mismatch.lhs_summary,
            mismatch.rhs_summary,
        });
        return error.UnexpectedShadowMismatch;
    }
}

test "shadow execution with comparison operations" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();
    
    // Enable per-call shadow mode (comparison happens at end of call)
    evm.set_shadow_mode(.per_call);
    
    // Code with comparison operations
    const code = [_]u8{
        0x60, 0x05, // PUSH1 5
        0x60, 0x0a, // PUSH1 10
        0x10,       // LT (less than)
        0x60, 0x05, // PUSH1 5
        0x60, 0x05, // PUSH1 5
        0x14,       // EQ (equal)
        0x01,       // ADD
        0x00,       // STOP
    };
    
    const contract_addr = primitives.Address.from_hex("0x9234567890abcdef1234567890abcdef12345678") catch unreachable;
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
    
    // Check for mismatches
    if (evm.take_last_shadow_mismatch()) |m| {
        var mismatch = m;
        defer mismatch.deinit(allocator);
        std.log.err("Unexpected shadow mismatch: field={s}, main={s}, mini={s}", .{
            @tagName(mismatch.field),
            mismatch.lhs_summary,
            mismatch.rhs_summary,
        });
        return error.UnexpectedShadowMismatch;
    }
}

test "shadow execution with bitwise operations" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer evm.deinit();
    
    // Enable per-call shadow mode (comparison happens at end of call)
    evm.set_shadow_mode(.per_call);
    
    // Code with bitwise operations
    const code = [_]u8{
        0x60, 0x0f, // PUSH1 0x0f
        0x60, 0xf0, // PUSH1 0xf0
        0x16,       // AND
        0x60, 0x0f, // PUSH1 0x0f
        0x60, 0xf0, // PUSH1 0xf0
        0x17,       // OR
        0x18,       // XOR
        0x19,       // NOT
        0x00,       // STOP
    };
    
    const contract_addr = primitives.Address.from_hex("0xa234567890abcdef1234567890abcdef12345678") catch unreachable;
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
    
    // Check for mismatches
    if (evm.take_last_shadow_mismatch()) |m| {
        var mismatch = m;
        defer mismatch.deinit(allocator);
        std.log.err("Unexpected shadow mismatch: field={s}, main={s}, mini={s}", .{
            @tagName(mismatch.field),
            mismatch.lhs_summary,
            mismatch.rhs_summary,
        });
        return error.UnexpectedShadowMismatch;
    }
}