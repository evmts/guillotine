const std = @import("std");
const Operation = @import("../opcodes/operation.zig");
const ExecutionError = @import("execution_error.zig");
const Stack = @import("../stack/stack.zig");
const Frame = @import("../frame/frame.zig");
const Vm = @import("../evm.zig");
const storage = @import("storage.zig");
const gas_constants = @import("../constants/gas_constants.zig");
const primitives = @import("primitives");

// Fuzz testing functions for storage operations
pub fn fuzz_storage_operations(allocator: std.mem.Allocator, operations: []const FuzzStorageOperation) !void {
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
        
        // Set up VM with appropriate chain rules
        vm.chain_rules.is_berlin = op.is_berlin;
        vm.chain_rules.is_istanbul = op.is_istanbul;
        
        var contract = try Contract.init(allocator, &[_]u8{0x01}, .{
            .address = op.contract_address,
        });
        defer contract.deinit(allocator, null);
        
        var frame = try Frame.init(allocator, &vm, op.gas_limit, contract, primitives.Address.ZERO, &.{});
        defer frame.deinit();
        
        // Set static flag for testing
        frame.is_static = op.is_static;
        
        // Pre-populate storage with initial values if needed
        if (op.initial_storage_value != 0) {
            try vm.state.set_storage(op.contract_address, op.slot, op.initial_storage_value);
        }
        
        // Execute the operation based on type
        const result = switch (op.op_type) {
            .sload => blk: {
                try frame.stack.append(op.slot);
                break :blk storage.op_sload(0, @ptrCast(&vm), @ptrCast(&frame));
            },
            .sstore => blk: {
                try frame.stack.append(op.slot);
                try frame.stack.append(op.value);
                break :blk storage.op_sstore(0, @ptrCast(&vm), @ptrCast(&frame));
            },
            .tload => blk: {
                try frame.stack.append(op.slot);
                break :blk storage.op_tload(0, @ptrCast(&vm), @ptrCast(&frame));
            },
            .tstore => blk: {
                try frame.stack.append(op.slot);
                try frame.stack.append(op.value);
                break :blk storage.op_tstore(0, @ptrCast(&vm), @ptrCast(&frame));
            },
        };
        
        // Verify the result
        try validate_storage_result(&frame, &vm, op, result);
    }
}

const FuzzStorageOperation = struct {
    op_type: StorageOpType,
    contract_address: primitives.Address,
    slot: u256,
    value: u256,
    initial_storage_value: u256 = 0,
    is_static: bool = false,
    is_berlin: bool = true,
    is_istanbul: bool = true,
    gas_limit: u64 = 1000000,
};

const StorageOpType = enum {
    sload,
    sstore,
    tload,
    tstore,
};

fn validate_storage_result(frame: *const Frame, vm: *const Vm, op: FuzzStorageOperation, result: anyerror!Operation.ExecutionResult) !void {
    _ = vm;
    const testing = std.testing;
    
    // Handle operations that can fail
    switch (op.op_type) {
        .sstore => {
            // SSTORE can fail in static context or with insufficient gas
            if (op.is_static) {
                try testing.expectError(ExecutionError.Error.WriteProtection, result);
                return;
            }
            
            // Check for insufficient gas (EIP-1706)
            if (op.is_istanbul and frame.gas_remaining <= gas_constants.SstoreSentryGas) {
                try testing.expectError(ExecutionError.Error.OutOfGas, result);
                return;
            }
            
            try result;
            // SSTORE doesn't push to stack
            return;
        },
        .tstore => {
            // TSTORE can fail in static context
            if (op.is_static) {
                try testing.expectError(ExecutionError.Error.WriteProtection, result);
                return;
            }
            
            try result;
            // TSTORE doesn't push to stack
            return;
        },
        .sload, .tload => {
            try result;
        },
    }
    
    // Verify stack has the expected result for load operations
    try testing.expectEqual(@as(usize, 1), frame.stack.size);
    
    const stack_result = frame.stack.data[0];
    
    // Validate specific operation results
    switch (op.op_type) {
        .sload => {
            if (op.initial_storage_value != 0) {
                try testing.expectEqual(op.initial_storage_value, stack_result);
            } else {
                // New storage slot should be 0
                try testing.expectEqual(@as(u256, 0), stack_result);
            }
        },
        .tload => {
            // Transient storage starts empty
            try testing.expectEqual(@as(u256, 0), stack_result);
        },
        .sstore, .tstore => {
            // These operations don't push to stack
            unreachable;
        },
    }
}

test "fuzz_storage_basic_operations" {
    const allocator = std.testing.allocator;
    
    const operations = [_]FuzzStorageOperation{
        .{
            .op_type = .sload,
            .contract_address = primitives.Address.from_u256(0x123456),
            .slot = 0,
            .value = 0,
        },
        .{
            .op_type = .sstore,
            .contract_address = primitives.Address.from_u256(0x123456),
            .slot = 0,
            .value = 42,
        },
        .{
            .op_type = .sload,
            .contract_address = primitives.Address.from_u256(0x123456),
            .slot = 0,
            .value = 0,
            .initial_storage_value = 42,
        },
        .{
            .op_type = .tload,
            .contract_address = primitives.Address.from_u256(0x123456),
            .slot = 0,
            .value = 0,
        },
        .{
            .op_type = .tstore,
            .contract_address = primitives.Address.from_u256(0x123456),
            .slot = 0,
            .value = 100,
        },
    };
    
    try fuzz_storage_operations(allocator, &operations);
}

test "fuzz_storage_static_context" {
    const allocator = std.testing.allocator;
    
    const operations = [_]FuzzStorageOperation{
        .{
            .op_type = .sstore,
            .contract_address = primitives.Address.from_u256(0x123456),
            .slot = 0,
            .value = 42,
            .is_static = true,
        },
        .{
            .op_type = .tstore,
            .contract_address = primitives.Address.from_u256(0x123456),
            .slot = 0,
            .value = 100,
            .is_static = true,
        },
        .{
            .op_type = .sload,
            .contract_address = primitives.Address.from_u256(0x123456),
            .slot = 0,
            .value = 0,
            .is_static = true,
        },
        .{
            .op_type = .tload,
            .contract_address = primitives.Address.from_u256(0x123456),
            .slot = 0,
            .value = 0,
            .is_static = true,
        },
    };
    
    try fuzz_storage_operations(allocator, &operations);
}

test "fuzz_storage_edge_cases" {
    const allocator = std.testing.allocator;
    
    const operations = [_]FuzzStorageOperation{
        .{
            .op_type = .sload,
            .contract_address = primitives.Address.from_u256(0),
            .slot = 0,
            .value = 0,
        },
        .{
            .op_type = .sload,
            .contract_address = primitives.Address.from_u256(std.math.maxInt(u256)),
            .slot = std.math.maxInt(u256),
            .value = 0,
        },
        .{
            .op_type = .sstore,
            .contract_address = primitives.Address.from_u256(0x123456),
            .slot = std.math.maxInt(u256),
            .value = std.math.maxInt(u256),
        },
        .{
            .op_type = .tload,
            .contract_address = primitives.Address.from_u256(0x123456),
            .slot = std.math.maxInt(u256),
            .value = 0,
        },
        .{
            .op_type = .tstore,
            .contract_address = primitives.Address.from_u256(0x123456),
            .slot = std.math.maxInt(u256),
            .value = std.math.maxInt(u256),
        },
    };
    
    try fuzz_storage_operations(allocator, &operations);
}

test "fuzz_storage_random_operations" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();
    
    var operations = std.ArrayList(FuzzStorageOperation).init(allocator);
    defer operations.deinit();
    
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        const op_type_idx = random.intRangeAtMost(usize, 0, 3);
        const op_types = [_]StorageOpType{ .sload, .sstore, .tload, .tstore };
        const op_type = op_types[op_type_idx];
        
        const contract_address = primitives.Address.from_u256(random.int(u256));
        const slot = random.int(u256);
        const value = random.int(u256);
        const initial_storage_value = random.int(u256);
        const is_static = random.boolean();
        const is_berlin = random.boolean();
        const is_istanbul = random.boolean();
        const gas_limit = random.intRangeAtMost(u64, 1000, 100000);
        
        try operations.append(.{
            .op_type = op_type,
            .contract_address = contract_address,
            .slot = slot,
            .value = value,
            .initial_storage_value = initial_storage_value,
            .is_static = is_static,
            .is_berlin = is_berlin,
            .is_istanbul = is_istanbul,
            .gas_limit = gas_limit,
        });
    }
    
    try fuzz_storage_operations(allocator, operations.items);
}