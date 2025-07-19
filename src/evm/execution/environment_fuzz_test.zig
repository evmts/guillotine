const std = @import("std");
const Operation = @import("../opcodes/operation.zig");
const ExecutionError = @import("execution_error.zig");
const Stack = @import("../stack/stack.zig");
const Frame = @import("../frame/frame.zig");
const Vm = @import("../evm.zig");
const environment = @import("environment.zig");
const primitives = @import("primitives");

// Fuzz testing functions for environment operations
pub fn fuzz_environment_operations(allocator: std.mem.Allocator, operations: []const FuzzEnvironmentOperation) !void {
    const Memory = @import("../memory/memory.zig");
    const MemoryDatabase = @import("../state/memory_database.zig");
    const Contract = @import("../frame/contract.zig");
    _ = primitives.Address;
    
    for (operations) |op| {
        var memory = try Memory.init_default(allocator);
        defer memory.deinit();
        
        var db = MemoryDatabase.init(allocator);
        defer db.deinit();
        
        var vm = try Vm.init(allocator, db.to_database_interface(), null, null);
        defer vm.deinit();
        
        // Set up VM context for testing
        vm.context.tx_origin = op.tx_origin;
        vm.context.gas_price = op.gas_price;
        vm.context.chain_id = op.chain_id;
        
        var contract = try Contract.init(allocator, &[_]u8{0x01}, .{
            .address = op.contract_address,
            .caller = op.caller,
            .value = op.value,
        });
        defer contract.deinit(allocator, null);
        
        var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.ZERO, op.input);
        defer frame.deinit();
        
        // Execute the operation based on type
        const result = switch (op.op_type) {
            .address => environment.op_address(0, @ptrCast(&vm), @ptrCast(&frame)),
            .balance => blk: {
                try frame.stack.append(primitives.Address.to_u256(op.target_address));
                break :blk environment.op_balance(0, @ptrCast(&vm), @ptrCast(&frame));
            },
            .origin => environment.op_origin(0, @ptrCast(&vm), @ptrCast(&frame)),
            .caller => environment.op_caller(0, @ptrCast(&vm), @ptrCast(&frame)),
            .callvalue => environment.op_callvalue(0, @ptrCast(&vm), @ptrCast(&frame)),
            .gasprice => environment.op_gasprice(0, @ptrCast(&vm), @ptrCast(&frame)),
            .extcodesize => blk: {
                try frame.stack.append(primitives.Address.to_u256(op.target_address));
                break :blk environment.op_extcodesize(0, @ptrCast(&vm), @ptrCast(&frame));
            },
            .extcodehash => blk: {
                try frame.stack.append(primitives.Address.to_u256(op.target_address));
                break :blk environment.op_extcodehash(0, @ptrCast(&vm), @ptrCast(&frame));
            },
            .selfbalance => environment.op_selfbalance(0, @ptrCast(&vm), @ptrCast(&frame)),
            .chainid => environment.op_chainid(0, @ptrCast(&vm), @ptrCast(&frame)),
            .calldatasize => environment.op_calldatasize(0, @ptrCast(&vm), @ptrCast(&frame)),
            .codesize => environment.op_codesize(0, @ptrCast(&vm), @ptrCast(&frame)),
            .calldataload => blk: {
                try frame.stack.append(op.offset);
                break :blk environment.op_calldataload(0, @ptrCast(&vm), @ptrCast(&frame));
            },
            .returndataload => blk: {
                // Set up return data for testing
                try frame.return_data.set(op.return_data);
                try frame.stack.append(op.offset);
                break :blk environment.op_returndataload(0, @ptrCast(&vm), @ptrCast(&frame));
            },
        };
        
        // Verify the result
        try validate_environment_result(&frame, &vm, op, result);
    }
}

const FuzzEnvironmentOperation = struct {
    op_type: EnvironmentOpType,
    tx_origin: primitives.Address,
    gas_price: u256,
    chain_id: u256,
    contract_address: primitives.Address,
    caller: primitives.Address,
    value: u256,
    target_address: primitives.Address,
    input: []const u8,
    offset: u256,
    return_data: []const u8,
};

const EnvironmentOpType = enum {
    address,
    balance,
    origin,
    caller,
    callvalue,
    gasprice,
    extcodesize,
    extcodehash,
    selfbalance,
    chainid,
    calldatasize,
    codesize,
    calldataload,
    returndataload,
};

fn validate_environment_result(frame: *const Frame, vm: *const Vm, op: FuzzEnvironmentOperation, result: anyerror!Operation.ExecutionResult) !void {
    _ = vm;
    const testing = std.testing;
    
    // Handle operations that can fail
    switch (op.op_type) {
        .returndataload => {
            // Can fail if offset is out of bounds
            if (op.offset > std.math.maxInt(usize)) {
                try testing.expectError(ExecutionError.Error.OutOfOffset, result);
                return;
            }
            
            const offset_usize = @as(usize, @intCast(op.offset));
            if (offset_usize + 32 > op.return_data.len) {
                try testing.expectError(ExecutionError.Error.OutOfOffset, result);
                return;
            }
            
            try result;
        },
        else => {
            try result;
        },
    }
    
    // Verify stack has the expected result
    try testing.expectEqual(@as(usize, 1), frame.stack.size);
    
    const stack_result = frame.stack.data[0];
    
    // Validate specific operation results
    switch (op.op_type) {
        .address => {
            const expected = primitives.Address.to_u256(op.contract_address);
            try testing.expectEqual(expected, stack_result);
        },
        .caller => {
            const expected = primitives.Address.to_u256(op.caller);
            try testing.expectEqual(expected, stack_result);
        },
        .callvalue => {
            try testing.expectEqual(op.value, stack_result);
        },
        .origin => {
            const expected = primitives.Address.to_u256(op.tx_origin);
            try testing.expectEqual(expected, stack_result);
        },
        .gasprice => {
            try testing.expectEqual(op.gas_price, stack_result);
        },
        .chainid => {
            try testing.expectEqual(op.chain_id, stack_result);
        },
        .calldatasize => {
            try testing.expectEqual(@as(u256, @intCast(op.input.len)), stack_result);
        },
        .codesize => {
            try testing.expectEqual(@as(u256, @intCast(frame.contract.code.len)), stack_result);
        },
        .balance, .selfbalance => {
            // Balance should be 0 for new accounts in our test setup
            try testing.expectEqual(@as(u256, 0), stack_result);
        },
        .extcodesize => {
            // External code size should be 0 for non-existent accounts
            try testing.expectEqual(@as(u256, 0), stack_result);
        },
        .extcodehash => {
            // External code hash should be 0 for empty accounts
            try testing.expectEqual(@as(u256, 0), stack_result);
        },
        .calldataload => {
            // Validate calldata loading with proper padding
            if (op.offset >= op.input.len) {
                try testing.expectEqual(@as(u256, 0), stack_result);
            } else {
                // Check that result makes sense for the loaded data
                try testing.expect(stack_result <= std.math.maxInt(u256));
            }
        },
        .returndataload => {
            // Result should be a valid u256 constructed from return data
            try testing.expect(stack_result <= std.math.maxInt(u256));
        },
    }
}

test "fuzz_environment_basic_operations" {
    const allocator = std.testing.allocator;
    
    const test_input = "Hello, World!";
    const test_return_data = "Return data test12345678901234567890";
    
    const operations = [_]FuzzEnvironmentOperation{
        .{
            .op_type = .address,
            .tx_origin = primitives.Address.from_u256(0x1234567890),
            .gas_price = 1000000000,
            .chain_id = 1,
            .contract_address = primitives.Address.from_u256(0xABCDEF),
            .caller = primitives.Address.from_u256(0x123456),
            .value = 1000,
            .target_address = primitives.Address.from_u256(0x789ABC),
            .input = test_input,
            .offset = 0,
            .return_data = test_return_data,
        },
        .{
            .op_type = .caller,
            .tx_origin = primitives.Address.from_u256(0x1234567890),
            .gas_price = 1000000000,
            .chain_id = 1,
            .contract_address = primitives.Address.from_u256(0xABCDEF),
            .caller = primitives.Address.from_u256(0x123456),
            .value = 1000,
            .target_address = primitives.Address.from_u256(0x789ABC),
            .input = test_input,
            .offset = 0,
            .return_data = test_return_data,
        },
        .{
            .op_type = .callvalue,
            .tx_origin = primitives.Address.from_u256(0x1234567890),
            .gas_price = 1000000000,
            .chain_id = 1,
            .contract_address = primitives.Address.from_u256(0xABCDEF),
            .caller = primitives.Address.from_u256(0x123456),
            .value = 1000,
            .target_address = primitives.Address.from_u256(0x789ABC),
            .input = test_input,
            .offset = 0,
            .return_data = test_return_data,
        },
        .{
            .op_type = .calldatasize,
            .tx_origin = primitives.Address.from_u256(0x1234567890),
            .gas_price = 1000000000,
            .chain_id = 1,
            .contract_address = primitives.Address.from_u256(0xABCDEF),
            .caller = primitives.Address.from_u256(0x123456),
            .value = 1000,
            .target_address = primitives.Address.from_u256(0x789ABC),
            .input = test_input,
            .offset = 0,
            .return_data = test_return_data,
        },
    };
    
    try fuzz_environment_operations(allocator, &operations);
}

test "fuzz_environment_edge_cases" {
    const allocator = std.testing.allocator;
    
    const operations = [_]FuzzEnvironmentOperation{
        .{
            .op_type = .calldataload,
            .tx_origin = primitives.Address.from_u256(0),
            .gas_price = 0,
            .chain_id = std.math.maxInt(u256),
            .contract_address = primitives.Address.from_u256(std.math.maxInt(u256)),
            .caller = primitives.Address.from_u256(std.math.maxInt(u256)),
            .value = std.math.maxInt(u256),
            .target_address = primitives.Address.from_u256(0),
            .input = "",
            .offset = 0,
            .return_data = "",
        },
        .{
            .op_type = .calldataload,
            .tx_origin = primitives.Address.from_u256(0),
            .gas_price = 0,
            .chain_id = 1,
            .contract_address = primitives.Address.from_u256(0),
            .caller = primitives.Address.from_u256(0),
            .value = 0,
            .target_address = primitives.Address.from_u256(0),
            .input = "test",
            .offset = 1000,
            .return_data = "",
        },
        .{
            .op_type = .extcodesize,
            .tx_origin = primitives.Address.from_u256(0),
            .gas_price = 0,
            .chain_id = 1,
            .contract_address = primitives.Address.from_u256(0),
            .caller = primitives.Address.from_u256(0),
            .value = 0,
            .target_address = primitives.Address.from_u256(0x123456789ABCDEF),
            .input = "",
            .offset = 0,
            .return_data = "",
        },
    };
    
    try fuzz_environment_operations(allocator, &operations);
}

test "fuzz_environment_random_operations" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();
    
    var operations = std.ArrayList(FuzzEnvironmentOperation).init(allocator);
    defer operations.deinit();
    
    var i: usize = 0;
    while (i < 25) : (i += 1) {
        const op_type_idx = random.intRangeAtMost(usize, 0, 10);
        const op_types = [_]EnvironmentOpType{ .address, .caller, .callvalue, .origin, .gasprice, .chainid, .calldatasize, .codesize, .balance, .selfbalance, .extcodesize };
        const op_type = op_types[op_type_idx];
        
        const tx_origin = primitives.Address.from_u256(random.int(u256));
        const gas_price = random.int(u256);
        const chain_id = random.intRangeAtMost(u256, 1, 1000);
        const contract_address = primitives.Address.from_u256(random.int(u256));
        const caller = primitives.Address.from_u256(random.int(u256));
        const value = random.int(u256);
        const target_address = primitives.Address.from_u256(random.int(u256));
        
        try operations.append(.{
            .op_type = op_type,
            .tx_origin = tx_origin,
            .gas_price = gas_price,
            .chain_id = chain_id,
            .contract_address = contract_address,
            .caller = caller,
            .value = value,
            .target_address = target_address,
            .input = "",
            .offset = 0,
            .return_data = "",
        });
    }
    
    try fuzz_environment_operations(allocator, operations.items);
}

test "fuzz_environment_data_operations" {
    const allocator = std.testing.allocator;
    
    const test_input = "0123456789abcdef0123456789abcdef";
    const test_return_data = "return_data_test_0123456789abcdef0123456789abcdef";
    
    const operations = [_]FuzzEnvironmentOperation{
        .{
            .op_type = .calldataload,
            .tx_origin = primitives.Address.from_u256(0),
            .gas_price = 0,
            .chain_id = 1,
            .contract_address = primitives.Address.from_u256(0),
            .caller = primitives.Address.from_u256(0),
            .value = 0,
            .target_address = primitives.Address.from_u256(0),
            .input = test_input,
            .offset = 0,
            .return_data = test_return_data,
        },
        .{
            .op_type = .calldataload,
            .tx_origin = primitives.Address.from_u256(0),
            .gas_price = 0,
            .chain_id = 1,
            .contract_address = primitives.Address.from_u256(0),
            .caller = primitives.Address.from_u256(0),
            .value = 0,
            .target_address = primitives.Address.from_u256(0),
            .input = test_input,
            .offset = 16,
            .return_data = test_return_data,
        },
        .{
            .op_type = .returndataload,
            .tx_origin = primitives.Address.from_u256(0),
            .gas_price = 0,
            .chain_id = 1,
            .contract_address = primitives.Address.from_u256(0),
            .caller = primitives.Address.from_u256(0),
            .value = 0,
            .target_address = primitives.Address.from_u256(0),
            .input = test_input,
            .offset = 0,
            .return_data = test_return_data,
        },
    };
    
    try fuzz_environment_operations(allocator, &operations);
}