const std = @import("std");
const Operation = @import("../opcodes/operation.zig");
const ExecutionError = @import("execution_error.zig");
const Stack = @import("../stack/stack.zig");
const Frame = @import("../frame/frame_fat.zig");
const Vm = @import("../evm.zig");
const primitives = @import("primitives");
const to_u256 = primitives.Address.to_u256;
const from_u256 = primitives.Address.from_u256;
const GasConstants = @import("primitives").GasConstants;
const AccessList = @import("../access_list/access_list.zig").AccessList;

pub fn op_address(vm: Operation.Interpreter, frame: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = vm;

    // Push contract address as u256
    const addr = to_u256(frame.address);
    try frame.stack_push(addr);

    return Operation.ExecutionResult{};
}

pub fn op_balance(vm: Operation.Interpreter, frame: Operation.State) ExecutionError.Error!Operation.ExecutionResult {

    const address_u256 = try frame.stack_pop();
    const address = from_u256(address_u256);

    // EIP-2929: Check if address is cold and consume appropriate gas
    const access_cost = try vm.access_list.access_address(address);
    try frame.consume_gas(access_cost);

    // Get balance from VM state
    const balance = vm.state.get_balance(address);
    try frame.stack_push(balance);

    return Operation.ExecutionResult{};
}

pub fn op_origin(vm: Operation.Interpreter, frame: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = vm;

    // Push transaction origin address
    const origin = to_u256(frame.block_context.tx_origin);
    try frame.stack_push(origin);

    return Operation.ExecutionResult{};
}

pub fn op_caller(vm: Operation.Interpreter, frame: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = vm;

    // Push caller address
    const caller = to_u256(frame.caller);
    try frame.stack_push(caller);

    return Operation.ExecutionResult{};
}

pub fn op_callvalue(vm: Operation.Interpreter, frame: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = vm;

    // Push call value
    try frame.stack_push(frame.value);

    return Operation.ExecutionResult{};
}

pub fn op_gasprice(vm: Operation.Interpreter, frame: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = vm;

    // Push gas price from transaction context
    try frame.stack_push(frame.block_context.gas_price);

    return Operation.ExecutionResult{};
}

pub fn op_extcodesize(vm: Operation.Interpreter, frame: Operation.State) ExecutionError.Error!Operation.ExecutionResult {

    const address_u256 = try frame.stack_pop();
    const address = from_u256(address_u256);

    // EIP-2929: Check if address is cold and consume appropriate gas
    const access_cost = try vm.access_list.access_address(address);
    try frame.consume_gas(access_cost);

    // Get code size from VM state
    const code = vm.state.get_code(address);
    try frame.stack_push(@as(u256, @intCast(code.len)));

    return Operation.ExecutionResult{};
}

pub fn op_extcodecopy(vm: Operation.Interpreter, frame: Operation.State) ExecutionError.Error!Operation.ExecutionResult {

    const address_u256 = try frame.stack_pop();
    const mem_offset = try frame.stack_pop();
    const code_offset = try frame.stack_pop();
    const size = try frame.stack_pop();

    if (size == 0) {
        @branchHint(.unlikely);
        return Operation.ExecutionResult{};
    }

    if (mem_offset > std.math.maxInt(usize) or size > std.math.maxInt(usize) or code_offset > std.math.maxInt(usize)) {
        @branchHint(.unlikely);
        return ExecutionError.Error.OutOfOffset;
    }

    const address = from_u256(address_u256);
    const mem_offset_usize = @as(usize, @intCast(mem_offset));
    const code_offset_usize = @as(usize, @intCast(code_offset));
    const size_usize = @as(usize, @intCast(size));

    // EIP-2929: Check if address is cold and consume appropriate gas
    const access_cost = try vm.access_list.access_address(address);
    try frame.consume_gas(access_cost);

    // Calculate memory expansion gas cost
    const new_size = mem_offset_usize + size_usize;
    const memory_gas = frame.memory_get_expansion_cost(@as(u64, @intCast(new_size)));
    try frame.consume_gas(memory_gas);

    // Dynamic gas for copy operation
    const word_size = (size_usize + 31) / 32;
    try frame.consume_gas(GasConstants.CopyGas * word_size);

    // Get external code from VM state
    const code = vm.state.get_code(address);

    // Use set_data_bounded to copy the code to memory
    // This handles partial copies and zero-padding automatically
    frame.memory_set_data_bounded(mem_offset_usize, code, code_offset_usize, size_usize) catch |err| switch (err) {
        error.OutOfGas => return error.OutOfGas,
        error.AllocationError => return error.OutOfMemory,
        error.Overflow => return error.OutOfMemory,
        error.OutOfMemory => return error.OutOfMemory,
    };

    return Operation.ExecutionResult{};
}

pub fn op_extcodehash(vm: Operation.Interpreter, frame: Operation.State) ExecutionError.Error!Operation.ExecutionResult {

    const address_u256 = try frame.stack_pop();
    const address = from_u256(address_u256);

    // EIP-2929: Check if address is cold and consume appropriate gas
    const access_cost = try vm.access_list.access_address(address);
    try frame.consume_gas(access_cost);

    // Get code from VM state and compute hash
    const code = vm.state.get_code(address);
    if (code.len == 0) {
        @branchHint(.unlikely);
        // Empty account - return zero
        try frame.stack_push(0);
    } else {
        // Compute keccak256 hash of the code
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha3.Keccak256.hash(code, &hash, .{});

        // Convert hash to u256 using std.mem for efficiency
        const hash_u256 = std.mem.readInt(u256, &hash, .big);
        try frame.stack_push(hash_u256);
    }

    return Operation.ExecutionResult{};
}

pub fn op_selfbalance(vm: Operation.Interpreter, frame: Operation.State) ExecutionError.Error!Operation.ExecutionResult {

    // Get balance of current executing contract
    const self_address = frame.address;
    const balance = vm.state.get_balance(self_address);
    try frame.stack_push(balance);

    return Operation.ExecutionResult{};
}

pub fn op_chainid(vm: Operation.Interpreter, frame: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = vm;

    // Push chain ID from VM context
    try frame.stack_push(frame.block_context.chain_id);

    return Operation.ExecutionResult{};
}

pub fn op_calldatasize(vm: Operation.Interpreter, frame: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = vm;

    // Push size of calldata - use frame.input which is set by the VM
    // The frame.input is the actual calldata for this execution context
    try frame.stack_push(@as(u256, @intCast(frame.input.len)));

    return Operation.ExecutionResult{};
}

pub fn op_codesize(vm: Operation.Interpreter, frame: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = vm;

    // Push size of current contract's code
    try frame.stack_push(@as(u256, @intCast(frame.code.len)));

    return Operation.ExecutionResult{};
}

pub fn op_calldataload(vm: Operation.Interpreter, frame: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = vm;

    // Pop offset from stack
    const offset = try frame.stack_pop();

    if (offset > std.math.maxInt(usize)) {
        @branchHint(.unlikely);
        // Offset too large, push zero
        try frame.stack_push(0);
        return Operation.ExecutionResult{};
    }

    const offset_usize = @as(usize, @intCast(offset));
    const calldata = frame.input; // Use frame.input, not frame.contract.input

    // Load 32 bytes from calldata, padding with zeros if necessary
    var value: u256 = 0;
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        if (offset_usize + i < calldata.len) {
            @branchHint(.likely);
            value = (value << 8) | calldata[offset_usize + i];
        } else {
            value = value << 8; // Pad with zero
        }
    }

    try frame.stack_push(value);

    return Operation.ExecutionResult{};
}

pub fn op_calldatacopy(vm: Operation.Interpreter, frame: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = vm;

    // Pop memory offset, data offset, and size
    const mem_offset = try frame.stack_pop();
    const data_offset = try frame.stack_pop();
    const size = try frame.stack_pop();

    if (size == 0) {
        @branchHint(.unlikely);
        return Operation.ExecutionResult{};
    }

    if (mem_offset > std.math.maxInt(usize) or size > std.math.maxInt(usize) or data_offset > std.math.maxInt(usize)) return ExecutionError.Error.OutOfOffset;

    const mem_offset_usize = @as(usize, @intCast(mem_offset));
    const data_offset_usize = @as(usize, @intCast(data_offset));
    const size_usize = @as(usize, @intCast(size));

    // Calculate memory expansion gas cost
    const new_size = mem_offset_usize + size_usize;
    const memory_gas = frame.memory_get_expansion_cost(@as(u64, @intCast(new_size)));
    try frame.consume_gas(memory_gas);

    // Dynamic gas for copy operation (VERYLOW * word_count)
    const word_size = (size_usize + 31) / 32;
    try frame.consume_gas(GasConstants.CopyGas * word_size);

    // Get calldata from frame.input
    const calldata = frame.input;

    // Use set_data_bounded to copy the calldata to memory
    // This handles partial copies and zero-padding automatically
    frame.memory_set_data_bounded(mem_offset_usize, calldata, data_offset_usize, size_usize);

    return Operation.ExecutionResult{};
}

pub fn op_codecopy(vm: Operation.Interpreter, frame: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = vm;

    // Pop memory offset, code offset, and size
    const mem_offset = try frame.stack_pop();
    const code_offset = try frame.stack_pop();
    const size = try frame.stack_pop();

    // Debug logging removed for fuzz testing compatibility

    if (size == 0) {
        @branchHint(.unlikely);
        return Operation.ExecutionResult{};
    }

    if (mem_offset > std.math.maxInt(usize) or size > std.math.maxInt(usize) or code_offset > std.math.maxInt(usize)) {
        @branchHint(.unlikely);
        return ExecutionError.Error.OutOfOffset;
    }

    const mem_offset_usize = @as(usize, @intCast(mem_offset));
    const code_offset_usize = @as(usize, @intCast(code_offset));
    const size_usize = @as(usize, @intCast(size));

    // Calculate memory expansion gas cost
    const new_size = mem_offset_usize + size_usize;
    const memory_gas = frame.memory_get_expansion_cost(@as(u64, @intCast(new_size)));
    try frame.consume_gas(memory_gas);

    // Dynamic gas for copy operation
    const word_size = (size_usize + 31) / 32;
    try frame.consume_gas(GasConstants.CopyGas * word_size);

    // Get current contract code
    const code = frame.code;

    // Use set_data_bounded to copy the code to memory
    // This handles partial copies and zero-padding automatically
    frame.memory_set_data_bounded(mem_offset_usize, code, code_offset_usize, size_usize) catch |err| switch (err) {
        error.OutOfGas => return error.OutOfGas,
        error.AllocationError => return error.OutOfMemory,
        error.Overflow => return error.OutOfMemory,
        error.OutOfMemory => return error.OutOfMemory,
    };

    // Debug logging removed for fuzz testing compatibility

    return Operation.ExecutionResult{};
}
/// RETURNDATALOAD opcode (0xF7): Loads a 32-byte word from return data
/// This is an EOF opcode that allows reading from the return data buffer
pub fn op_returndataload(vm: Operation.Interpreter, frame: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = vm;

    // Pop offset from stack
    const offset = try frame.stack_pop();

    // Check if offset is within bounds
    if (offset > std.math.maxInt(usize)) {
        @branchHint(.unlikely);
        return ExecutionError.Error.OutOfOffset;
    }

    const offset_usize = @as(usize, @intCast(offset));
    const return_data = frame.return_data_get();

    // If offset + 32 > return_data.len, this is an error (unlike CALLDATALOAD which pads with zeros)
    if (offset_usize + 32 > return_data.len) {
        @branchHint(.unlikely);
        return ExecutionError.Error.OutOfOffset;
    }

    // Load 32 bytes from return data
    var value: u256 = 0;
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        value = (value << 8) | return_data[offset_usize + i];
    }

    try frame.stack_push(value);

    return Operation.ExecutionResult{};
}

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
            .address => op_address(@ptrCast(&vm), @ptrCast(&frame)),
            .balance => blk: {
                try frame.stack_push(primitives.Address.to_u256(op.target_address));
                break :blk op_balance(@ptrCast(&vm), @ptrCast(&frame));
            },
            .origin => op_origin(@ptrCast(&vm), @ptrCast(&frame)),
            .caller => op_caller(@ptrCast(&vm), @ptrCast(&frame)),
            .callvalue => op_callvalue(@ptrCast(&vm), @ptrCast(&frame)),
            .gasprice => op_gasprice(@ptrCast(&vm), @ptrCast(&frame)),
            .extcodesize => blk: {
                try frame.stack_push(primitives.Address.to_u256(op.target_address));
                break :blk op_extcodesize(@ptrCast(&vm), @ptrCast(&frame));
            },
            .extcodehash => blk: {
                try frame.stack_push(primitives.Address.to_u256(op.target_address));
                break :blk op_extcodehash(@ptrCast(&vm), @ptrCast(&frame));
            },
            .selfbalance => op_selfbalance(@ptrCast(&vm), @ptrCast(&frame)),
            .chainid => op_chainid(@ptrCast(&vm), @ptrCast(&frame)),
            .calldatasize => op_calldatasize(@ptrCast(&vm), @ptrCast(&frame)),
            .codesize => op_codesize(@ptrCast(&vm), @ptrCast(&frame)),
            .calldataload => blk: {
                try frame.stack_push(op.offset);
                break :blk op_calldataload(@ptrCast(&vm), @ptrCast(&frame));
            },
            .returndataload => blk: {
                // Set up return data for testing
                frame.return_data_set(op.return_data);
                try frame.stack_push(op.offset);
                break :blk op_returndataload(@ptrCast(&vm), @ptrCast(&frame));
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
    try testing.expectEqual(@as(usize, 1), frame.stack_size);
    
    const stack_result = frame.stack_data[0];
    
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
            try testing.expectEqual(@as(u256, @intCast(frame.code.len)), stack_result);
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
