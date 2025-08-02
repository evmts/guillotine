const std = @import("std");
const testing = std.testing;

test {
    std.testing.log_level = .debug;
}

const Evm = @import("evm");
const primitives = @import("primitives");

test "minimal block validation failure - CODECOPY followed by RETURN" {
    const allocator = testing.allocator;
    defer Evm.Contract.clear_analysis_cache(allocator);
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);
    var vm = try builder.build();
    defer vm.deinit();
    
    // Minimal bytecode that reproduces the issue:
    // 1. Push 3 values for CODECOPY
    // 2. CODECOPY (pops all 3, leaving empty stack)
    // 3. Push 2 values for RETURN  
    // 4. RETURN (needs 2 values on stack)
    const bytecode = &[_]u8{
        // Block 1: Push values and CODECOPY
        0x60, 0x01, // PUSH1 1 (size)
        0x60, 0x00, // PUSH1 0 (code offset) 
        0x60, 0x00, // PUSH1 0 (memory offset)
        0x39,       // CODECOPY - pops 3, stack is now empty
        
        // Block 2: RETURN expects 2 values but stack is empty
        0x60, 0x01, // PUSH1 1 (size)
        0x60, 0x00, // PUSH1 0 (offset)
        0xf3,       // RETURN - needs 2 on stack
    };
    
    var contract = Evm.Contract.init(
        [_]u8{0} ** 20,
        [_]u8{0} ** 20,
        0,
        1000000,
        bytecode,
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);
    
    const result = try vm.interpret(&contract, &[_]u8{}, false);
    defer if (result.output) |output| allocator.free(output);
    
    // This should succeed - the block analyzer should track that
    // CODECOPY leaves empty stack, so the RETURN block needs to
    // push its own values
    try testing.expect(result.status == .Success);
}

test "minimal block validation failure - insufficient stack for RETURN" {
    const allocator = testing.allocator;
    defer Evm.Contract.clear_analysis_cache(allocator);
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);
    var vm = try builder.build();
    defer vm.deinit();
    
    // Even simpler case - just RETURN with empty stack
    const bytecode = &[_]u8{
        0xf3,       // RETURN - needs 2 on stack but we have 0
    };
    
    var contract = Evm.Contract.init(
        [_]u8{0} ** 20,
        [_]u8{0} ** 20,
        0,
        1000000,
        bytecode,
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);
    
    const result = try vm.interpret(&contract, &[_]u8{}, false);
    defer if (result.output) |output| allocator.free(output);
    
    // This should fail with Invalid status because RETURN needs 2 stack items
    try testing.expect(result.status == .Invalid);
}

test "block validation with cross-block stack dependencies" {
    const allocator = testing.allocator;
    defer Evm.Contract.clear_analysis_cache(allocator);
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);
    var vm = try builder.build();
    defer vm.deinit();
    
    // Test where first block pushes values that second block consumes
    const bytecode = &[_]u8{
        // Block 1: Push values
        0x60, 0x01, // PUSH1 1
        0x60, 0x00, // PUSH1 0
        
        // This should NOT create a new block - it's all one flow
        0xf3,       // RETURN - uses the 2 values pushed above
    };
    
    var contract = Evm.Contract.init(
        [_]u8{0} ** 20,
        [_]u8{0} ** 20, 
        0,
        1000000,
        bytecode,
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);
    
    const result = try vm.interpret(&contract, &[_]u8{}, false);
    defer if (result.output) |output| allocator.free(output);
    
    // This should succeed
    try testing.expect(result.status == .Success);
}