const std = @import("std");
const root = @import("root.zig");
const Evm = root.Evm;
const primitives = root.primitives;
const Allocator = std.mem.Allocator;

/// Benchmark block execution vs single-opcode execution for arithmetic-heavy code
pub fn zbench_block_arithmetic(allocator: Allocator) void {
    // Generate bytecode with long arithmetic sequences
    const bytecode = generateArithmeticBytecode(allocator) catch return;
    defer allocator.free(bytecode);
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null) catch return;
    defer vm.deinit();
    
    var contract = Evm.Contract.init(
        primitives.Address.ZERO,
        primitives.Address.ZERO,
        0,
        1000000,
        bytecode,
        [_]u8{0} ** 32,
        &.{},
        false
    );
    defer contract.deinit(allocator, null);
    
    const result = vm.interpret(&contract, &.{}, false) catch return;
    defer if (result.output) |output| allocator.free(output);
}

/// Benchmark block execution without analysis (forces single-opcode path)
pub fn zbench_single_opcode_arithmetic(allocator: Allocator) void {
    const bytecode = generateArithmeticBytecode(allocator) catch return;
    defer allocator.free(bytecode);
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null) catch return;
    defer vm.deinit();
    
    var contract = Evm.Contract.init(
        primitives.Address.ZERO,
        primitives.Address.ZERO,
        0,
        1000000,
        bytecode,
        [_]u8{0} ** 32,
        &.{},
        false
    );
    defer contract.deinit(allocator, null);
    
    // Force disable block execution
    contract.analysis = null;
    
    const result = vm.interpret(&contract, &.{}, false) catch return;
    defer if (result.output) |output| allocator.free(output);
}

/// Benchmark static jump validation optimization
pub fn zbench_static_jumps(allocator: Allocator) void {
    const bytecode = generateStaticJumpBytecode(allocator) catch return;
    defer allocator.free(bytecode);
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null) catch return;
    defer vm.deinit();
    
    var contract = Evm.Contract.init(
        primitives.Address.ZERO,
        primitives.Address.ZERO,
        0,
        1000000,
        bytecode,
        [_]u8{0} ** 32,
        &.{},
        false
    );
    defer contract.deinit(allocator, null);
    
    const result = vm.interpret(&contract, &.{}, false) catch return;
    defer if (result.output) |output| allocator.free(output);
}

/// Benchmark dynamic jump validation (no optimization possible)
pub fn zbench_dynamic_jumps(allocator: Allocator) void {
    const bytecode = generateDynamicJumpBytecode(allocator) catch return;
    defer allocator.free(bytecode);
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null) catch return;
    defer vm.deinit();
    
    var contract = Evm.Contract.init(
        primitives.Address.ZERO,
        primitives.Address.ZERO,
        0,
        1000000,
        bytecode,
        [_]u8{0} ** 32,
        &.{},
        false
    );
    defer contract.deinit(allocator, null);
    
    const result = vm.interpret(&contract, &.{}, false) catch return;
    defer if (result.output) |output| allocator.free(output);
}

/// Benchmark unsafe opcode execution within blocks
pub fn zbench_unsafe_opcodes(allocator: Allocator) void {
    // Generate bytecode with opcodes covered by unsafe execution
    const bytecode = generateUnsafeOpcodeBytecode(allocator) catch return;
    defer allocator.free(bytecode);
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null) catch return;
    defer vm.deinit();
    
    var contract = Evm.Contract.init(
        primitives.Address.ZERO,
        primitives.Address.ZERO,
        0,
        1000000,
        bytecode,
        [_]u8{0} ** 32,
        &.{},
        false
    );
    defer contract.deinit(allocator, null);
    
    const result = vm.interpret(&contract, &.{}, false) catch return;
    defer if (result.output) |output| allocator.free(output);
}

/// Benchmark memory-intensive operations with block execution
pub fn zbench_block_memory_ops(allocator: Allocator) void {
    const bytecode = generateMemoryOpsBytecode(allocator) catch return;
    defer allocator.free(bytecode);
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null) catch return;
    defer vm.deinit();
    
    var contract = Evm.Contract.init(
        primitives.Address.ZERO,
        primitives.Address.ZERO,
        0,
        1000000,
        bytecode,
        [_]u8{0} ** 32,
        &.{},
        false
    );
    defer contract.deinit(allocator, null);
    
    const result = vm.interpret(&contract, &.{}, false) catch return;
    defer if (result.output) |output| allocator.free(output);
}

/// Benchmark stack-heavy operations with unsafe execution
pub fn zbench_stack_operations(allocator: Allocator) void {
    const bytecode = generateStackOpsBytecode(allocator) catch return;
    defer allocator.free(bytecode);
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null) catch return;
    defer vm.deinit();
    
    var contract = Evm.Contract.init(
        primitives.Address.ZERO,
        primitives.Address.ZERO,
        0,
        1000000,
        bytecode,
        [_]u8{0} ** 32,
        &.{},
        false
    );
    defer contract.deinit(allocator, null);
    
    const result = vm.interpret(&contract, &.{}, false) catch return;
    defer if (result.output) |output| allocator.free(output);
}

/// Benchmark block boundary overhead
pub fn zbench_block_boundaries(allocator: Allocator) void {
    // Generate bytecode with many small blocks (lots of jumps)
    const bytecode = generateManyBlocksBytecode(allocator) catch return;
    defer allocator.free(bytecode);
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null) catch return;
    defer vm.deinit();
    
    var contract = Evm.Contract.init(
        primitives.Address.ZERO,
        primitives.Address.ZERO,
        0,
        1000000,
        bytecode,
        [_]u8{0} ** 32,
        &.{},
        false
    );
    defer contract.deinit(allocator, null);
    
    const result = vm.interpret(&contract, &.{}, false) catch return;
    defer if (result.output) |output| allocator.free(output);
}

/// Benchmark pre-validated gas calculation
pub fn zbench_block_gas_validation(allocator: Allocator) void {
    // Generate bytecode with high gas consumption patterns
    const bytecode = generateGasIntensiveBytecode(allocator) catch return;
    defer allocator.free(bytecode);
    
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null) catch return;
    defer vm.deinit();
    
    var contract = Evm.Contract.init(
        primitives.Address.ZERO,
        primitives.Address.ZERO,
        0,
        10000000, // High gas limit
        bytecode,
        [_]u8{0} ** 32,
        &.{},
        false
    );
    defer contract.deinit(allocator, null);
    
    const result = vm.interpret(&contract, &.{}, false) catch return;
    defer if (result.output) |output| allocator.free(output);
}

// Helper functions to generate different bytecode patterns

fn generateArithmeticBytecode(allocator: Allocator) ![]u8 {
    var bytecode = std.ArrayList(u8).init(allocator);
    defer bytecode.deinit();
    
    // Generate a long sequence of arithmetic operations
    // This creates large basic blocks ideal for block execution
    for (0..50) |_| {
        try bytecode.appendSlice(&[_]u8{ 0x60, 0x10 }); // PUSH1 16
        try bytecode.appendSlice(&[_]u8{ 0x60, 0x20 }); // PUSH1 32
        try bytecode.append(0x01); // ADD
        try bytecode.appendSlice(&[_]u8{ 0x60, 0x05 }); // PUSH1 5
        try bytecode.append(0x02); // MUL
        try bytecode.appendSlice(&[_]u8{ 0x60, 0x03 }); // PUSH1 3
        try bytecode.append(0x04); // DIV
        try bytecode.appendSlice(&[_]u8{ 0x60, 0x02 }); // PUSH1 2
        try bytecode.append(0x06); // MOD
        try bytecode.append(0x50); // POP
    }
    
    try bytecode.append(0x00); // STOP
    
    return allocator.dupe(u8, bytecode.items);
}

fn generateStaticJumpBytecode(allocator: Allocator) ![]u8 {
    var bytecode = std.ArrayList(u8).init(allocator);
    defer bytecode.deinit();
    
    // Generate bytecode with many static jumps
    var jump_positions = std.ArrayList(usize).init(allocator);
    defer jump_positions.deinit();
    
    // Create jump targets first
    for (0..20) |i| {
        const pos = bytecode.items.len;
        try jump_positions.append(pos);
        
        // JUMPDEST followed by some operations
        try bytecode.append(0x5b); // JUMPDEST
        try bytecode.appendSlice(&[_]u8{ 0x60, @intCast(i) }); // PUSH1 i
        try bytecode.append(0x50); // POP
    }
    
    // Now add jumps to these destinations
    for (jump_positions.items) |dest| {
        try bytecode.appendSlice(&[_]u8{ 0x61 }); // PUSH2
        try bytecode.append(@intCast(dest >> 8));
        try bytecode.append(@intCast(dest & 0xFF));
        try bytecode.append(0x56); // JUMP
    }
    
    try bytecode.append(0x00); // STOP
    
    return allocator.dupe(u8, bytecode.items);
}

fn generateDynamicJumpBytecode(allocator: Allocator) ![]u8 {
    var bytecode = std.ArrayList(u8).init(allocator);
    defer bytecode.deinit();
    
    // Generate bytecode with dynamic jumps (computed destinations)
    
    // Add some jump destinations
    for (0..10) |_| {
        try bytecode.append(0x5b); // JUMPDEST
        try bytecode.appendSlice(&[_]u8{ 0x60, 0xFF }); // PUSH1 255
        try bytecode.append(0x50); // POP
    }
    
    // Dynamic jump pattern: load destination from calldata
    try bytecode.appendSlice(&[_]u8{ 0x60, 0x00 }); // PUSH1 0
    try bytecode.append(0x35); // CALLDATALOAD
    try bytecode.append(0x56); // JUMP
    
    try bytecode.append(0x00); // STOP
    
    return allocator.dupe(u8, bytecode.items);
}

fn generateUnsafeOpcodeBytecode(allocator: Allocator) ![]u8 {
    var bytecode = std.ArrayList(u8).init(allocator);
    defer bytecode.deinit();
    
    // Generate bytecode using opcodes covered by unsafe execution
    
    // Arithmetic operations
    try bytecode.appendSlice(&[_]u8{ 0x60, 0x10, 0x60, 0x20 }); // PUSH1 16, PUSH1 32
    try bytecode.append(0x01); // ADD
    try bytecode.append(0x02); // MUL
    try bytecode.append(0x03); // SUB
    try bytecode.append(0x04); // DIV
    try bytecode.append(0x05); // SDIV
    try bytecode.append(0x06); // MOD
    try bytecode.append(0x07); // SMOD
    
    // Comparison operations
    try bytecode.appendSlice(&[_]u8{ 0x60, 0x10, 0x60, 0x20 }); // PUSH1 16, PUSH1 32
    try bytecode.append(0x10); // LT
    try bytecode.append(0x11); // GT
    try bytecode.append(0x12); // SLT
    try bytecode.append(0x13); // SGT
    try bytecode.append(0x14); // EQ
    try bytecode.append(0x15); // ISZERO
    
    // Bitwise operations
    try bytecode.appendSlice(&[_]u8{ 0x60, 0xFF, 0x60, 0x0F }); // PUSH1 255, PUSH1 15
    try bytecode.append(0x16); // AND
    try bytecode.append(0x17); // OR
    try bytecode.append(0x18); // XOR
    try bytecode.appendSlice(&[_]u8{ 0x60, 0xFF }); // PUSH1 255
    try bytecode.append(0x19); // NOT
    
    // Stack operations
    try bytecode.appendSlice(&[_]u8{ 0x60, 0x01 }); // PUSH1 1
    try bytecode.append(0x80); // DUP1
    try bytecode.append(0x90); // SWAP1
    try bytecode.append(0x50); // POP
    
    try bytecode.append(0x00); // STOP
    
    return allocator.dupe(u8, bytecode.items);
}

fn generateMemoryOpsBytecode(allocator: Allocator) ![]u8 {
    var bytecode = std.ArrayList(u8).init(allocator);
    defer bytecode.deinit();
    
    // Generate memory-intensive operations
    for (0..20) |i| {
        // Store values
        try bytecode.appendSlice(&[_]u8{ 0x60, @intCast(i * 0x11) }); // PUSH1 value
        try bytecode.appendSlice(&[_]u8{ 0x60, @intCast(i * 0x20) }); // PUSH1 offset
        try bytecode.append(0x52); // MSTORE
        
        // Load values
        try bytecode.appendSlice(&[_]u8{ 0x60, @intCast(i * 0x20) }); // PUSH1 offset
        try bytecode.append(0x51); // MLOAD
        try bytecode.append(0x50); // POP
    }
    
    try bytecode.append(0x00); // STOP
    
    return allocator.dupe(u8, bytecode.items);
}

fn generateStackOpsBytecode(allocator: Allocator) ![]u8 {
    var bytecode = std.ArrayList(u8).init(allocator);
    defer bytecode.deinit();
    
    // Push many values
    for (0..16) |i| {
        try bytecode.appendSlice(&[_]u8{ 0x60, @intCast(i) }); // PUSH1 i
    }
    
    // DUP operations
    try bytecode.append(0x80); // DUP1
    try bytecode.append(0x81); // DUP2
    try bytecode.append(0x8F); // DUP16
    
    // SWAP operations
    try bytecode.append(0x90); // SWAP1
    try bytecode.append(0x91); // SWAP2
    try bytecode.append(0x9F); // SWAP16
    
    // Pop everything
    for (0..20) |_| {
        try bytecode.append(0x50); // POP
    }
    
    try bytecode.append(0x00); // STOP
    
    return allocator.dupe(u8, bytecode.items);
}

fn generateManyBlocksBytecode(allocator: Allocator) ![]u8 {
    var bytecode = std.ArrayList(u8).init(allocator);
    defer bytecode.deinit();
    
    // Generate many small blocks with jumps between them
    var destinations = std.ArrayList(usize).init(allocator);
    defer destinations.deinit();
    
    // First pass: create jump destinations
    for (0..50) |i| {
        try destinations.append(bytecode.items.len);
        try bytecode.append(0x5b); // JUMPDEST
        try bytecode.appendSlice(&[_]u8{ 0x60, @intCast(i) }); // PUSH1 i
        try bytecode.append(0x50); // POP
    }
    
    // Second pass: add jumps between blocks
    for (destinations.items, 0..) |_, i| {
        if (i + 1 < destinations.items.len) {
            try bytecode.appendSlice(&[_]u8{ 0x61 }); // PUSH2
            try bytecode.append(@intCast(destinations.items[i + 1] >> 8));
            try bytecode.append(@intCast(destinations.items[i + 1] & 0xFF));
            try bytecode.append(0x56); // JUMP
        }
    }
    
    try bytecode.append(0x00); // STOP
    
    return allocator.dupe(u8, bytecode.items);
}

fn generateGasIntensiveBytecode(allocator: Allocator) ![]u8 {
    var bytecode = std.ArrayList(u8).init(allocator);
    defer bytecode.deinit();
    
    // Mix of operations with different gas costs
    for (0..10) |_| {
        // Expensive operations
        try bytecode.appendSlice(&[_]u8{ 0x60, 0x02, 0x60, 0x10 }); // PUSH1 2, PUSH1 16
        try bytecode.append(0x0a); // EXP (expensive)
        
        // Memory expansion
        try bytecode.appendSlice(&[_]u8{ 0x60, 0x00, 0x61, 0x10, 0x00 }); // PUSH1 0, PUSH2 4096
        try bytecode.append(0x52); // MSTORE (causes memory expansion)
        
        // Keccak256
        try bytecode.appendSlice(&[_]u8{ 0x60, 0x20, 0x60, 0x00 }); // PUSH1 32, PUSH1 0
        try bytecode.append(0x20); // KECCAK256
        
        try bytecode.append(0x50); // POP
    }
    
    try bytecode.append(0x00); // STOP
    
    return allocator.dupe(u8, bytecode.items);
}