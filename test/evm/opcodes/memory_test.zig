const std = @import("std");
const testing = std.testing;
const Evm = @import("evm");
const primitives = @import("primitives");
const Address = primitives.Address;
const Contract = Evm.Contract;
const Frame = Evm.Frame;
const MemoryDatabase = Evm.MemoryDatabase;
const ExecutionError = Evm.ExecutionError;
// Updated to new API - migration in progress, tests not run yet

// Test MLOAD operation
test "MLOAD: load 32 bytes from memory" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);

    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(1000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Write 32 bytes to memory
    var data: [32]u8 = undefined;
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        data[i] = @intCast(i);
    }
    try frame.memory.set_data(0, &data);

    // Push offset 0
    try frame.stack.append(0);

    // Execute MLOAD
    _ = try evm.table.execute(0, interpreter, state, 0x51);

    // Should load 32 bytes as u256 (big-endian)
    const result = try frame.stack.pop();
    // First byte (0) should be in the most significant position
    try testing.expect((result >> 248) == 0);
    try testing.expect(((result >> 240) & 0xFF) == 1);
}

test "MLOAD: load with offset" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);

    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(1000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Write pattern to memory
    var data: [64]u8 = undefined;
    var i: usize = 0;
    while (i < 64) : (i += 1) {
        data[i] = @intCast(i + 0x10);
    }
    try frame.memory.set_data(0, &data);

    // Push offset 16
    try frame.stack.append(16);

    // Execute MLOAD
    _ = try evm.table.execute(0, interpreter, state, 0x51);

    // Should load 32 bytes starting at offset 16
    const result = try frame.stack.pop();
    // First byte should be 0x20 (16 + 0x10)
    try testing.expect((result >> 248) == 0x20);
}

test "MLOAD: load from uninitialized memory returns zeros" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);

    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(1000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Push offset to uninitialized area
    try frame.stack.append(1000);

    // Execute MLOAD
    _ = try evm.table.execute(0, interpreter, state, 0x51);

    // Should return all zeros
    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

// Test MSTORE operation
test "MSTORE: store 32 bytes to memory" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);

    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(1000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Push value and offset (stack is LIFO)
    const value: u256 = 0x0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20;
    try frame.stack.append(value);
    try frame.stack.append(0);

    // Execute MSTORE
    _ = try evm.table.execute(0, interpreter, state, 0x52);

    // Check memory contents
    const mem = try frame.memory.get_slice(0, 32);
    try testing.expectEqual(@as(u8, 0x01), mem[0]);
    try testing.expectEqual(@as(u8, 0x02), mem[1]);
    try testing.expectEqual(@as(u8, 0x20), mem[31]);
}

test "MSTORE: store with offset" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);

    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(1000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Push value and offset (stack is LIFO)
    const value: u256 = 0xFFEEDDCCBBAA99887766554433221100;
    try frame.stack.append(value);
    try frame.stack.append(64);

    // Execute MSTORE
    _ = try evm.table.execute(0, interpreter, state, 0x52);

    // Check memory contents at offset
    const mem = try frame.memory.get_slice(64, 32);
    // The value 0xFFEEDDCCBBAA99887766554433221100 is stored big-endian
    // Most significant bytes first: 00 00 ... 00 FF EE DD CC BB AA ...
    try testing.expectEqual(@as(u8, 0x00), mem[15]); // Byte 15 at offset 64+15=79
    try testing.expectEqual(@as(u8, 0xFF), mem[16]); // Byte 16 at offset 64+16=80 is 0xFF
}

// Test MSTORE8 operation
test "MSTORE8: store single byte to memory" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);

    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(1000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Push value and offset (stack is LIFO)
    try frame.stack.append(0x1234);
    try frame.stack.append(10);

    // Execute MSTORE8
    _ = try evm.table.execute(0, interpreter, state, 0x53);

    // Check memory contents
    const mem = try frame.memory.get_slice(10, 1);
    try testing.expectEqual(@as(u8, 0x34), mem[0]);
    // Adjacent bytes should be unaffected (zero)
    const mem_before = try frame.memory.get_slice(9, 1);
    const mem_after = try frame.memory.get_slice(11, 1);
    try testing.expectEqual(@as(u8, 0), mem_before[0]);
    try testing.expectEqual(@as(u8, 0), mem_after[0]);
}

test "MSTORE8: store only lowest byte" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);

    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(1000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Push value with all bytes set (stack is LIFO)
    try frame.stack.append(0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFAB);
    try frame.stack.append(0);

    // Execute MSTORE8
    _ = try evm.table.execute(0, interpreter, state, 0x53);

    // Check that only lowest byte was stored
    const mem = try frame.memory.get_slice(0, 1);
    try testing.expectEqual(@as(u8, 0xAB), mem[0]);
}

// Test MSIZE operation
test "MSIZE: get memory size" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);

    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(1000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Initially memory size should be 0
    _ = try evm.table.execute(0, interpreter, state, 0x59);
    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());

    // Write to memory at offset 31 (should expand to 32 bytes)
    try frame.memory.set_data(31, &[_]u8{0xFF});

    // Check size again
    _ = try evm.table.execute(0, interpreter, state, 0x59);
    try testing.expectEqual(@as(u256, 32), try frame.stack.pop());

    // Write to memory at offset 32 (should expand to 64 bytes - word aligned)
    try frame.memory.set_data(32, &[_]u8{0xFF});

    // Check size again
    _ = try evm.table.execute(0, interpreter, state, 0x59);
    try testing.expectEqual(@as(u256, 64), try frame.stack.pop());
}

// Test MCOPY operation (EIP-5656)
test "MCOPY: copy memory to memory" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);

    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(1000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Write source data
    const src_data = [_]u8{ 0xAA, 0xBB, 0xCC, 0xDD, 0xEE };
    try frame.memory.set_data(10, &src_data);

    // Push parameters in order for stack
    // MCOPY pops: dest (first), src (second), length (third)
    // So push: length, src, dest (dest on top)
    try frame.stack.append(5);
    try frame.stack.append(10);
    try frame.stack.append(50);

    // Execute MCOPY
    _ = try evm.table.execute(0, interpreter, state, 0x5E);

    // Check that data was copied
    const dest_data = try frame.memory.get_slice(50, 5);
    var i: usize = 0;
    while (i < src_data.len) : (i += 1) {
        try testing.expectEqual(src_data[i], dest_data[i]);
    }

    // Original data should still be there
    const orig_data = try frame.memory.get_slice(10, 5);
    i = 0;
    while (i < src_data.len) : (i += 1) {
        try testing.expectEqual(src_data[i], orig_data[i]);
    }
}

test "MCOPY: overlapping copy forward" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);

    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(1000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Write source data
    const src_data = [_]u8{ 0x11, 0x22, 0x33, 0x44, 0x55 };
    try frame.memory.set_data(10, &src_data);

    // Copy with overlap (forward)
    // MCOPY pops: dest, src, length
    try frame.stack.append(5);
    try frame.stack.append(10);
    try frame.stack.append(12);

    // Execute MCOPY
    _ = try evm.table.execute(0, interpreter, state, 0x5E);

    // Check result - should handle overlap correctly
    const result = try frame.memory.get_slice(12, 5);
    try testing.expectEqual(@as(u8, 0x11), result[0]);
    try testing.expectEqual(@as(u8, 0x22), result[1]);
    try testing.expectEqual(@as(u8, 0x33), result[2]);
    try testing.expectEqual(@as(u8, 0x44), result[3]);
    try testing.expectEqual(@as(u8, 0x55), result[4]);
}

test "MCOPY: overlapping copy backward" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);

    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(1000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Write source data
    const src_data = [_]u8{ 0xAA, 0xBB, 0xCC, 0xDD, 0xEE };
    try frame.memory.set_data(10, &src_data);

    // Copy with overlap (backward)
    // MCOPY pops: dest, src, length
    try frame.stack.append(5);
    try frame.stack.append(10);
    try frame.stack.append(8);

    // Execute MCOPY
    _ = try evm.table.execute(0, interpreter, state, 0x5E);

    // Check result
    const result = try frame.memory.get_slice(8, 5);
    try testing.expectEqual(@as(u8, 0xAA), result[0]);
    try testing.expectEqual(@as(u8, 0xBB), result[1]);
    try testing.expectEqual(@as(u8, 0xCC), result[2]);
    try testing.expectEqual(@as(u8, 0xDD), result[3]);
    try testing.expectEqual(@as(u8, 0xEE), result[4]);
}

test "MCOPY: zero length copy" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);

    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(1000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Push length 0
    // MCOPY pops: size, src, dest
    try frame.stack.append(200);
    try frame.stack.append(100);
    try frame.stack.append(0);

    // Execute MCOPY
    _ = try evm.table.execute(0, interpreter, state, 0x5E);

    // Should succeed without doing anything
    try testing.expectEqual(@as(usize, 0), frame.stack.size);
}

// Test gas consumption
test "MLOAD: memory expansion gas" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);

    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(1000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Push offset that requires memory expansion
    try frame.stack.append(256); // offset (requires 288 bytes = 9 words)

    const gas_before = frame.gas_remaining;

    // Execute MLOAD
    _ = try evm.table.execute(0, interpreter, state, 0x51);

    // Should consume gas for memory expansion
    const gas_used = gas_before - frame.gas_remaining;
    try testing.expect(gas_used > 0); // Memory expansion should cost gas
}

test "MSTORE: memory expansion gas" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);

    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(1000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Push value and offset that requires expansion (stack is LIFO)
    try frame.stack.append(0x123456);
    try frame.stack.append(512);

    const gas_before = frame.gas_remaining;

    // Execute MSTORE
    _ = try evm.table.execute(0, interpreter, state, 0x52);

    // Should consume gas for memory expansion
    const gas_used = gas_before - frame.gas_remaining;
    try testing.expect(gas_used > 0);
}

test "MCOPY: gas consumption" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);

    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(1000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Push parameters for 32 byte copy
    // MCOPY pops: size, src, dest
    try frame.stack.append(100);
    try frame.stack.append(0);
    try frame.stack.append(32);

    const gas_before = frame.gas_remaining;

    // Execute MCOPY
    _ = try evm.table.execute(0, interpreter, state, 0x5E);

    // MCOPY costs 3 gas per word
    // 32 bytes = 1 word = 3 gas
    // Plus memory expansion for destination
    const gas_used = gas_before - frame.gas_remaining;
    try testing.expect(gas_used >= 3);
}

// Test stack errors
test "MLOAD: stack underflow" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);

    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(1000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Empty stack

    // Execute MLOAD - should fail
    const result = evm.table.execute(0, interpreter, state, 0x51);
    try testing.expectError(ExecutionError.Error.StackUnderflow, result);
}

test "MSTORE: stack underflow" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);

    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(1000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Push only one value (need two)
    try frame.stack.append(0);

    // Execute MSTORE - should fail
    const result = evm.table.execute(0, interpreter, state, 0x52);
    try testing.expectError(ExecutionError.Error.StackUnderflow, result);
}

test "MCOPY: stack underflow" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);

    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(1000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Push only two values (need three)
    // MCOPY needs: dest, src, size on stack
    try frame.stack.append(0);
    try frame.stack.append(10);

    // Execute MCOPY - should fail
    const result = evm.table.execute(0, interpreter, state, 0x5E);
    try testing.expectError(ExecutionError.Error.StackUnderflow, result);
}

// Test out of offset
test "MLOAD: offset overflow" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);

    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(1000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Push offset that would overflow when adding 32
    try frame.stack.append(std.math.maxInt(u256) - 10);

    // Execute MLOAD - should fail
    const result = evm.table.execute(0, interpreter, state, 0x51);
    try testing.expectError(ExecutionError.Error.OutOfOffset, result);
}

test "MCOPY: source offset overflow" {
    const allocator = testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, null);

    defer evm.deinit();

    const caller: Address.Address = [_]u8{0x11} ** 20;
    const contract_addr: Address.Address = [_]u8{0x33} ** 20;
    var contract = Contract.init(
        caller,
        contract_addr,
        0,
        1000,
        &[_]u8{},
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&evm)
        .withContract(&contract)
        .withGas(1000)
        .build();
    defer frame.deinit();

    const interpreter: Evm.Operation.Interpreter = &evm;
    const state: Evm.Operation.State = &frame;

    // Push parameters that would overflow
    // MCOPY pops: dest, src, length
    try frame.stack.append(100);
    try frame.stack.append(std.math.maxInt(u256));
    try frame.stack.append(0);

    // Execute MCOPY - should fail
    const result = evm.table.execute(0, interpreter, state, 0x5E);
    try testing.expectError(ExecutionError.Error.OutOfOffset, result);
}
