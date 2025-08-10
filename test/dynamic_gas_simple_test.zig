const std = @import("std");
const evm = @import("evm");
const primitives = @import("primitives");
const dynamic_gas = @import("../src/evm/gas/dynamic_gas.zig");

test "dynamic gas functions are attached correctly" {
    const allocator = std.testing.allocator;

    // Test bytecode with dynamic gas opcodes
    const bytecode = [_]u8{
        0x5A, // GAS
        0xF1, // CALL
        0xF2, // CALLCODE
        0xF4, // DELEGATECALL
        0xFA, // STATICCALL
        0xF0, // CREATE
        0xF5, // CREATE2
        0x55, // SSTORE
        0x00, // STOP
    };

    // Create analysis
    var analysis = try evm.CodeAnalysis.from_code(allocator, &bytecode, &evm.JumpTable.DEFAULT);
    defer analysis.deinit();

    // Check that dynamic gas opcodes have the dynamic_gas arg set
    const instructions = analysis.instructions;

    var found_gas = false;
    var found_call = false;
    var found_sstore = false;

    for (instructions) |inst| {
        switch (inst.arg) {
            .dynamic_gas => |dyn| {
                // GAS, CALL, etc should have dynamic gas set
                if (dyn.gas_fn) |gas_fn| {
                    // Check that it's one of our functions
                    if (gas_fn == dynamic_gas.gas_dynamic_gas) {
                        found_gas = true;
                    } else if (gas_fn == dynamic_gas.call_dynamic_gas) {
                        found_call = true;
                    } else if (gas_fn == dynamic_gas.sstore_dynamic_gas) {
                        found_sstore = true;
                    }
                }
            },
            else => {},
        }
    }

    try std.testing.expect(found_gas);
    try std.testing.expect(found_call);
    try std.testing.expect(found_sstore);
}

test "CALL dynamic gas calculates memory expansion" {
    const allocator = std.testing.allocator;

    // Create a minimal frame to test the dynamic gas function
    var memory = try evm.Memory.init_default(allocator);
    defer memory.deinit();

    var stack = try evm.Stack.init(allocator);
    defer stack.deinit();

    // Push values onto stack for CALL
    // Stack layout: gas, to, value, args_offset, args_size, ret_offset, ret_size
    try stack.append(0); // ret_size
    try stack.append(0); // ret_offset
    try stack.append(32); // args_size (32 bytes)
    try stack.append(0); // args_offset
    try stack.append(0); // value
    try stack.append(0); // to
    try stack.append(10000); // gas

    // Create a mock frame
    var frame = struct {
        stack: evm.Stack,
        memory: *evm.Memory,

        const Self = @This();
        pub fn to_frame(self: *Self) *evm.Frame {
            return @ptrCast(self);
        }
    }{
        .stack = stack,
        .memory = &memory,
    };

    // Call the dynamic gas function
    const additional_gas = try dynamic_gas.call_dynamic_gas(@ptrCast(&frame));

    // For 32 bytes (1 word) of memory expansion:
    // Gas = 3 * 1 + (1 * 1) / 512 = 3
    try std.testing.expectEqual(@as(u64, 3), additional_gas);
}

test "CREATE2 dynamic gas includes hashing cost" {
    const allocator = std.testing.allocator;

    var memory = try evm.Memory.init_default(allocator);
    defer memory.deinit();

    var stack = try evm.Stack.init(allocator);
    defer stack.deinit();

    // Stack layout for CREATE2: value, offset, size, salt
    try stack.append(0); // salt
    try stack.append(64); // size (64 bytes = 2 words)
    try stack.append(0); // offset
    try stack.append(0); // value

    var frame = struct {
        stack: evm.Stack,
        memory: *evm.Memory,
    }{
        .stack = stack,
        .memory = &memory,
    };

    const additional_gas = try dynamic_gas.create2_dynamic_gas(@ptrCast(&frame));

    // Memory expansion for 64 bytes (2 words): 3 * 2 + (2 * 2) / 512 = 6
    // Hash cost for 2 words: 6 * 2 = 12
    // Total: 6 + 12 = 18
    try std.testing.expectEqual(@as(u64, 18), additional_gas);
}

test "DELEGATECALL uses correct stack positions" {
    const allocator = std.testing.allocator;

    var memory = try evm.Memory.init_default(allocator);
    defer memory.deinit();

    var stack = try evm.Stack.init(allocator);
    defer stack.deinit();

    // DELEGATECALL has no value, so positions are different
    // Stack: gas, to, args_offset, args_size, ret_offset, ret_size
    try stack.append(32); // ret_size
    try stack.append(256); // ret_offset (256 bytes)
    try stack.append(64); // args_size
    try stack.append(0); // args_offset
    try stack.append(0); // to
    try stack.append(10000); // gas

    var frame = struct {
        stack: evm.Stack,
        memory: *evm.Memory,
    }{
        .stack = stack,
        .memory = &memory,
    };

    const additional_gas = try dynamic_gas.delegatecall_dynamic_gas(@ptrCast(&frame));

    // Need memory for max(64 bytes for args, 288 bytes for ret)
    // 288 bytes = 9 words
    // Gas = 3 * 9 + (9 * 9) / 512 = 27 + 0 = 27
    try std.testing.expectEqual(@as(u64, 27), additional_gas);
}
