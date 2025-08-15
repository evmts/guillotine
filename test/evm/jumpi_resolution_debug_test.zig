const std = @import("std");
const evm = @import("evm");
const primitives = @import("primitives");
const Log = @import("evm").Log;

test {
    std.testing.log_level = .debug;
}

test "debug JUMPI resolution in ERC20 pattern" {
    const allocator = std.testing.allocator;

    // Analyze the exact bytecode pattern from ERC20
    const bytecode = [_]u8{
        0x60, 0x80, // PUSH1 0x80
        0x60, 0x40, // PUSH1 0x40  
        0x52,       // MSTORE (position 4)
        0x34,       // CALLVALUE (position 5)
        0x80,       // DUP1 (position 6)
        0x15,       // ISZERO (position 7)
        0x61, 0x00, 0x0f, // PUSH2 0x000f (position 8-10)
        0x57,       // JUMPI (position 11)
        0x5f,       // PUSH0 (position 12)
        0x5f,       // PUSH0 (position 13)
        0xfd,       // REVERT (position 14)
        0x5b,       // JUMPDEST (position 15)
        0x50,       // POP (position 16)
        0x00,       // STOP (position 17)
    };

    // Create analysis
    const OpcodeMetadata = @import("evm").OpcodeMetadata;
    var analysis = try @import("evm").CodeAnalysis.from_code(allocator, &bytecode, &OpcodeMetadata.DEFAULT);
    defer analysis.deinit();

    // Print instruction stream
    std.debug.print("\n=== Instruction Stream ===\n", .{});
    for (analysis.instructions, 0..) |inst, i| {
        std.debug.print("Inst[{}]: tag={s}, id={}\n", .{ i, @tagName(inst.tag), inst.id });
        
        // If it's a word instruction, print the bytes
        if (inst.tag == .word) {
            const word_params = analysis.getInstructionParams(.word, inst.id);
            std.debug.print("  Word bytes: {x} (len={})\n", .{ word_params.word_bytes, word_params.word_bytes.len });
        }
        
        // If it's a conditional_jump_pc, print the target
        if (inst.tag == .conditional_jump_pc) {
            const cjp_params = analysis.getInstructionParams(.conditional_jump_pc, inst.id);
            std.debug.print("  Jump target: {*}\n", .{cjp_params.jump_target});
        }
    }

    // Check jumpdest bitmap
    std.debug.print("\n=== Jumpdest Bitmap ===\n", .{});
    for (0..bytecode.len) |pc| {
        if (analysis.jumpdest_array.is_valid_jumpdest(pc)) {
            std.debug.print("PC {} is a valid jumpdest (opcode=0x{x})\n", .{ pc, bytecode[pc] });
        }
    }

    // Now test execution
    std.debug.print("\n=== Testing Execution ===\n", .{});
    
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();

    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    const caller = primitives.Address.from_u256(0x1);
    try vm.state.set_balance(caller, 1000000);
    
    const create_result = vm.create_contract(caller, 0, &bytecode, 10_000_000) catch |err| {
        std.debug.print("create_contract failed: {}\n", .{err});
        return err;
    };
    
    try std.testing.expect(create_result.success);
}