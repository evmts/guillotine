const std = @import("std");
const IR = @import("ir.zig");
const ir_builder = @import("ir_builder.zig");
const opcode = @import("opcode_data.zig");
const Opcode = opcode.Opcode;

test "IR builder handles all EVM opcodes" {
    const allocator = std.testing.allocator;
    
    // Test every single opcode
    const all_opcodes = [_]struct { op: Opcode, name: []const u8 }{
        // 0x0X - Stop and Arithmetic
        .{ .op = .STOP, .name = "STOP" },
        .{ .op = .ADD, .name = "ADD" },
        .{ .op = .MUL, .name = "MUL" },
        .{ .op = .SUB, .name = "SUB" },
        .{ .op = .DIV, .name = "DIV" },
        .{ .op = .SDIV, .name = "SDIV" },
        .{ .op = .MOD, .name = "MOD" },
        .{ .op = .SMOD, .name = "SMOD" },
        .{ .op = .ADDMOD, .name = "ADDMOD" },
        .{ .op = .MULMOD, .name = "MULMOD" },
        .{ .op = .EXP, .name = "EXP" },
        .{ .op = .SIGNEXTEND, .name = "SIGNEXTEND" },
        
        // 0x1X - Comparison & Bitwise Logic
        .{ .op = .LT, .name = "LT" },
        .{ .op = .GT, .name = "GT" },
        .{ .op = .SLT, .name = "SLT" },
        .{ .op = .SGT, .name = "SGT" },
        .{ .op = .EQ, .name = "EQ" },
        .{ .op = .ISZERO, .name = "ISZERO" },
        .{ .op = .AND, .name = "AND" },
        .{ .op = .OR, .name = "OR" },
        .{ .op = .XOR, .name = "XOR" },
        .{ .op = .NOT, .name = "NOT" },
        .{ .op = .BYTE, .name = "BYTE" },
        .{ .op = .SHL, .name = "SHL" },
        .{ .op = .SHR, .name = "SHR" },
        .{ .op = .SAR, .name = "SAR" },
        
        // 0x2X - SHA3
        .{ .op = .KECCAK256, .name = "KECCAK256" },
        
        // 0x3X - Environmental Information
        .{ .op = .ADDRESS, .name = "ADDRESS" },
        .{ .op = .BALANCE, .name = "BALANCE" },
        .{ .op = .ORIGIN, .name = "ORIGIN" },
        .{ .op = .CALLER, .name = "CALLER" },
        .{ .op = .CALLVALUE, .name = "CALLVALUE" },
        .{ .op = .CALLDATALOAD, .name = "CALLDATALOAD" },
        .{ .op = .CALLDATASIZE, .name = "CALLDATASIZE" },
        .{ .op = .CALLDATACOPY, .name = "CALLDATACOPY" },
        .{ .op = .CODESIZE, .name = "CODESIZE" },
        .{ .op = .CODECOPY, .name = "CODECOPY" },
        .{ .op = .GASPRICE, .name = "GASPRICE" },
        .{ .op = .EXTCODESIZE, .name = "EXTCODESIZE" },
        .{ .op = .EXTCODECOPY, .name = "EXTCODECOPY" },
        .{ .op = .RETURNDATASIZE, .name = "RETURNDATASIZE" },
        .{ .op = .RETURNDATACOPY, .name = "RETURNDATACOPY" },
        .{ .op = .EXTCODEHASH, .name = "EXTCODEHASH" },
        
        // 0x4X - Block Information
        .{ .op = .BLOCKHASH, .name = "BLOCKHASH" },
        .{ .op = .COINBASE, .name = "COINBASE" },
        .{ .op = .TIMESTAMP, .name = "TIMESTAMP" },
        .{ .op = .NUMBER, .name = "NUMBER" },
        .{ .op = .DIFFICULTY, .name = "DIFFICULTY" },
        .{ .op = .GASLIMIT, .name = "GASLIMIT" },
        .{ .op = .CHAINID, .name = "CHAINID" },
        .{ .op = .SELFBALANCE, .name = "SELFBALANCE" },
        .{ .op = .BASEFEE, .name = "BASEFEE" },
        
        // 0x5X - Stack, Memory, Storage and Flow
        .{ .op = .POP, .name = "POP" },
        .{ .op = .MLOAD, .name = "MLOAD" },
        .{ .op = .MSTORE, .name = "MSTORE" },
        .{ .op = .MSTORE8, .name = "MSTORE8" },
        .{ .op = .SLOAD, .name = "SLOAD" },
        .{ .op = .SSTORE, .name = "SSTORE" },
        .{ .op = .JUMP, .name = "JUMP" },
        .{ .op = .JUMPI, .name = "JUMPI" },
        .{ .op = .PC, .name = "PC" },
        .{ .op = .MSIZE, .name = "MSIZE" },
        .{ .op = .GAS, .name = "GAS" },
        .{ .op = .JUMPDEST, .name = "JUMPDEST" },
        .{ .op = .TLOAD, .name = "TLOAD" },
        .{ .op = .TSTORE, .name = "TSTORE" },
        .{ .op = .MCOPY, .name = "MCOPY" },
        .{ .op = .PUSH0, .name = "PUSH0" },
        
        // 0x6X-0x7F - Push Operations
        // We'll test PUSH1 and PUSH32 as representatives
        .{ .op = .PUSH1, .name = "PUSH1" },
        .{ .op = .PUSH32, .name = "PUSH32" },
        
        // 0x8X - Duplication Operations
        .{ .op = .DUP1, .name = "DUP1" },
        .{ .op = .DUP16, .name = "DUP16" },
        
        // 0x9X - Exchange Operations
        .{ .op = .SWAP1, .name = "SWAP1" },
        .{ .op = .SWAP16, .name = "SWAP16" },
        
        // 0xAX - Logging Operations
        .{ .op = .LOG0, .name = "LOG0" },
        .{ .op = .LOG4, .name = "LOG4" },
        
        // 0xFX - System operations
        .{ .op = .CREATE, .name = "CREATE" },
        .{ .op = .CALL, .name = "CALL" },
        .{ .op = .CALLCODE, .name = "CALLCODE" },
        .{ .op = .RETURN, .name = "RETURN" },
        .{ .op = .DELEGATECALL, .name = "DELEGATECALL" },
        .{ .op = .CREATE2, .name = "CREATE2" },
        .{ .op = .STATICCALL, .name = "STATICCALL" },
        .{ .op = .REVERT, .name = "REVERT" },
        .{ .op = .INVALID, .name = "INVALID" },
        .{ .op = .SELFDESTRUCT, .name = "SELFDESTRUCT" },
    };
    
    for (all_opcodes) |test_case| {
        // Build bytecode for each opcode
        var bytecode: [34]u8 = undefined;
        var len: usize = 0;
        
        // Special handling for PUSH opcodes
        if (test_case.op == .PUSH1) {
            bytecode[0] = @intFromEnum(test_case.op);
            bytecode[1] = 0x42; // dummy value
            len = 2;
        } else if (test_case.op == .PUSH32) {
            bytecode[0] = @intFromEnum(test_case.op);
            for (1..33) |i| {
                bytecode[i] = @intCast(i); // dummy values
            }
            len = 33;
        } else {
            bytecode[0] = @intFromEnum(test_case.op);
            len = 1;
        }
        
        // Build IR
        const program = ir_builder.build(allocator, bytecode[0..len]) catch |err| {
            std.debug.print("Failed to build IR for {s}: {}\n", .{ test_case.name, err });
            return err;
        };
        defer allocator.free(program.instructions);
        
        // Verify at least one instruction was generated
        try std.testing.expect(program.instructions.len > 0);
        
        // Verify no early termination for supported opcodes
        const critical_opcodes = [_]Opcode{
            .CODECOPY, .DUP1, .ADD, .SUB, .ISZERO, .CALLVALUE,
            .CALLDATALOAD, .CALLDATASIZE, .CALLDATACOPY,
            .CODESIZE, .JUMP, .JUMPI, .PC, .MSIZE, .GAS,
        };
        
        for (critical_opcodes) |critical| {
            if (test_case.op == critical) {
                // These should be supported, not result in STOP
                const first_op = program.instructions[0].op;
                try std.testing.expect(first_op != .stop);
                break;
            }
        }
    }
}

test "IR builder correctly handles Solidity deployment bytecode" {
    const allocator = std.testing.allocator;
    
    // Typical Solidity deployment pattern:
    // PUSH1 0x80 PUSH1 0x40 MSTORE (free memory pointer)
    // CALLVALUE ISZERO PUSH1 <jumpdest> JUMPI (payable check)
    // PUSH1 0x00 DUP1 REVERT (revert if value sent)
    // JUMPDEST
    // ... constructor code ...
    // CODECOPY and RETURN (return runtime code)
    
    const deployment_bytecode = [_]u8{
        0x60, 0x80, // PUSH1 0x80
        0x60, 0x40, // PUSH1 0x40
        0x52,       // MSTORE
        0x34,       // CALLVALUE
        0x15,       // ISZERO
        0x60, 0x0f, // PUSH1 0x0f
        0x57,       // JUMPI
        0x60, 0x00, // PUSH1 0x00
        0x80,       // DUP1
        0xfd,       // REVERT
        0x5b,       // JUMPDEST
        // Simplified - normally more constructor code here
        0x60, 0x10, // PUSH1 0x10 (size)
        0x60, 0x20, // PUSH1 0x20 (offset)
        0x60, 0x00, // PUSH1 0x00 (dest)
        0x39,       // CODECOPY
        0x60, 0x10, // PUSH1 0x10 (size)
        0x60, 0x00, // PUSH1 0x00 (offset)
        0xf3,       // RETURN
    };
    
    const program = try ir_builder.build(allocator, &deployment_bytecode);
    defer allocator.free(program.instructions);
    
    // Should handle all instructions without early termination
    try std.testing.expect(program.instructions.len > 1);
    
    // Check that critical opcodes are present
    var has_codecopy = false;
    var has_return = false;
    var has_jumpdest = false;
    
    for (program.instructions) |inst| {
        switch (inst.op) {
            .codecopy => has_codecopy = true,
            .@"return" => has_return = true,
            .jumpdest => has_jumpdest = true,
            else => {},
        }
    }
    
    try std.testing.expect(has_codecopy);
    try std.testing.expect(has_return);
    try std.testing.expect(has_jumpdest);
}

test "IR builder handles all DUP operations" {
    const allocator = std.testing.allocator;
    
    // Test all DUP1 through DUP16
    var bytecode: [16]u8 = undefined;
    var i: u8 = 0;
    while (i < 16) : (i += 1) {
        bytecode[i] = 0x80 + i; // DUP1 = 0x80, DUP2 = 0x81, etc.
    }
    
    const program = try ir_builder.build(allocator, &bytecode);
    defer allocator.free(program.instructions);
    
    // Should have 16 DUP instructions plus sentinel
    try std.testing.expect(program.instructions.len >= 16);
}

test "IR builder handles all SWAP operations" {
    const allocator = std.testing.allocator;
    
    // Test all SWAP1 through SWAP16
    var bytecode: [16]u8 = undefined;
    var i: u8 = 0;
    while (i < 16) : (i += 1) {
        bytecode[i] = 0x90 + i; // SWAP1 = 0x90, SWAP2 = 0x91, etc.
    }
    
    const program = try ir_builder.build(allocator, &bytecode);
    defer allocator.free(program.instructions);
    
    // Should have 16 SWAP instructions plus sentinel
    try std.testing.expect(program.instructions.len >= 16);
}

test "IR builder handles all LOG operations" {
    const allocator = std.testing.allocator;
    
    // Test LOG0 through LOG4
    const bytecode = [_]u8{
        0xa0, // LOG0
        0xa1, // LOG1
        0xa2, // LOG2
        0xa3, // LOG3
        0xa4, // LOG4
    };
    
    const program = try ir_builder.build(allocator, &bytecode);
    defer allocator.free(program.instructions);
    
    // Should have 5 LOG instructions plus sentinel
    try std.testing.expect(program.instructions.len >= 5);
}

test "IR builder correctly calculates stack deltas" {
    const allocator = std.testing.allocator;
    
    // Test opcodes with various stack effects
    const test_cases = [_]struct {
        bytecode: []const u8,
        expected_delta: i8,
        name: []const u8,
    }{
        .{ .bytecode = &[_]u8{0x01}, .expected_delta = -1, .name = "ADD" }, // pops 2, pushes 1
        .{ .bytecode = &[_]u8{0x50}, .expected_delta = -1, .name = "POP" }, // pops 1
        .{ .bytecode = &[_]u8{0x80}, .expected_delta = 1, .name = "DUP1" }, // duplicates top
        .{ .bytecode = &[_]u8{0x90}, .expected_delta = 0, .name = "SWAP1" }, // swaps, no net change
        .{ .bytecode = &[_]u8{0x60, 0x42}, .expected_delta = 1, .name = "PUSH1" }, // pushes 1
        .{ .bytecode = &[_]u8{0x51}, .expected_delta = 0, .name = "MLOAD" }, // pops 1, pushes 1
        .{ .bytecode = &[_]u8{0x52}, .expected_delta = -2, .name = "MSTORE" }, // pops 2
        .{ .bytecode = &[_]u8{0x39}, .expected_delta = -3, .name = "CODECOPY" }, // pops 3
    };
    
    for (test_cases) |test_case| {
        const program = try ir_builder.build(allocator, test_case.bytecode);
        defer allocator.free(program.instructions);
        
        const actual_delta = program.instructions[0].stack_delta;
        try std.testing.expectEqual(test_case.expected_delta, actual_delta);
    }
}