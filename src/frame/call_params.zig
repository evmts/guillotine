const primitives = @import("primitives");
const Address = primitives.Address;

pub fn CallParams(config: anytype) type {
    // We can add config-specific customizations here in the future
    _ = config; // Currently unused but reserved for future enhancements

    return union(enum) {
        /// Regular CALL operation
        call: struct {
            caller: Address,
            to: Address,
            value: u256,
            input: []const u8,
            gas: u64,
        },
        /// CALLCODE operation: execute external code with current storage/context
        /// Executes code at `to`, but uses caller's storage and address context
        callcode: struct {
            caller: Address,
            to: Address,
            value: u256,
            input: []const u8,
            gas: u64,
        },
        /// DELEGATECALL operation (preserves caller context)
        delegatecall: struct {
            caller: Address, // Original caller, not current contract
            to: Address,
            input: []const u8,
            gas: u64,
        },
        /// STATICCALL operation (read-only)
        staticcall: struct {
            caller: Address,
            to: Address,
            input: []const u8,
            gas: u64,
        },
        /// CREATE operation
        create: struct {
            caller: Address,
            value: u256,
            init_code: []const u8,
            gas: u64,
        },
        /// CREATE2 operation
        create2: struct {
            caller: Address,
            value: u256,
            init_code: []const u8,
            salt: u256,
            gas: u64,
        },

        pub const ValidationError = error{
            GasZeroError,
            InvalidInputSize,
            InvalidInitCodeSize,
            InvalidCreateValue,
            InvalidStaticCallValue,
        };

        /// Validate call parameters to ensure they meet EVM requirements.
        /// Checks gas limits and other critical constraints.
        pub fn validate(self: @This()) ValidationError!void {
            // BUG: we should be checking if gas checks are disabled or not
            // Gas must be non-zero to execute any operation
            if (self.getGas() == 0) return ValidationError.GasZeroError;

            // EIP-3860: Limit init code size to 49152 bytes (2 * max contract size)
            const MAX_INITCODE_SIZE = 49152;
            const MAX_INPUT_SIZE = 1024 * 1024 * 4; // 4MB practical limit for input data

            switch (self) {
                .call => |params| {
                    // Validate input data size
                    if (params.input.len > MAX_INPUT_SIZE) return ValidationError.InvalidInputSize;
                },
                .callcode => |params| {
                    // Validate input data size
                    if (params.input.len > MAX_INPUT_SIZE) return ValidationError.InvalidInputSize;
                },
                .delegatecall => |params| {
                    // Validate input data size
                    if (params.input.len > MAX_INPUT_SIZE) return ValidationError.InvalidInputSize;
                    // DELEGATECALL doesn't transfer value, validation happens at protocol level
                },
                .staticcall => |params| {
                    // Validate input data size
                    if (params.input.len > MAX_INPUT_SIZE) return ValidationError.InvalidInputSize;
                    // STATICCALL cannot have value (enforced by not having value field)
                },
                .create => |params| {
                    // Validate init code size (EIP-3860)
                    if (params.init_code.len > MAX_INITCODE_SIZE) return ValidationError.InvalidInitCodeSize;
                    // CREATE can have any value, no special validation needed
                },
                .create2 => |params| {
                    // Validate init code size (EIP-3860)
                    if (params.init_code.len > MAX_INITCODE_SIZE) return ValidationError.InvalidInitCodeSize;
                    // CREATE2 can have any value, no special validation needed
                },
            }
        }

        /// Get the gas limit for this call operation
        pub fn getGas(self: @This()) u64 {
            return switch (self) {
                .call => |params| params.gas,
                .callcode => |params| params.gas,
                .delegatecall => |params| params.gas,
                .staticcall => |params| params.gas,
                .create => |params| params.gas,
                .create2 => |params| params.gas,
            };
        }

        /// Set the gas limit for this call operation
        pub fn setGas(self: *@This(), gas: u64) void {
            switch (self.*) {
                .call => |*params| params.gas = gas,
                .callcode => |*params| params.gas = gas,
                .delegatecall => |*params| params.gas = gas,
                .staticcall => |*params| params.gas = gas,
                .create => |*params| params.gas = gas,
                .create2 => |*params| params.gas = gas,
            }
        }

        /// Get the caller address for this call operation
        pub fn getCaller(self: @This()) Address {
            return switch (self) {
                .call => |params| params.caller,
                .callcode => |params| params.caller,
                .delegatecall => |params| params.caller,
                .staticcall => |params| params.caller,
                .create => |params| params.caller,
                .create2 => |params| params.caller,
            };
        }

        /// Get the input data for this call operation (empty for CREATE operations)
        pub fn getInput(self: @This()) []const u8 {
            return switch (self) {
                .call => |params| params.input,
                .callcode => |params| params.input,
                .delegatecall => |params| params.input,
                .staticcall => |params| params.input,
                .create => |params| params.init_code,
                .create2 => |params| params.init_code,
            };
        }

        /// Get the value for this call operation
        pub fn getValue(self: @This()) u256 {
            return switch (self) {
                .call => |params| params.value,
                .callcode => |params| params.value,
                .delegatecall => 0, // DELEGATECALL preserves value from parent context
                .staticcall => 0, // STATICCALL cannot transfer value
                .create => |params| params.value,
                .create2 => |params| params.value,
            };
        }

        /// Check if this is a read-only operation
        pub fn isReadOnly(self: @This()) bool {
            return switch (self) {
                .staticcall => true,
                else => false,
            };
        }

        /// Check if this is a contract creation operation
        pub fn isCreate(self: @This()) bool {
            return switch (self) {
                .create, .create2 => true,
                else => false,
            };
        }

        /// Creates a deep copy of the CallParams
        /// Allocates new memory for all dynamic data (input/init_code)
        pub fn clone(self: @This(), allocator: std.mem.Allocator) !@This() {
            return switch (self) {
                .call => |params| blk: {
                    const cloned_input = try allocator.dupe(u8, params.input);
                    break :blk @This(){ .call = .{
                        .caller = params.caller,
                        .to = params.to,
                        .value = params.value,
                        .input = cloned_input,
                        .gas = params.gas,
                    } };
                },
                .callcode => |params| blk: {
                    const cloned_input = try allocator.dupe(u8, params.input);
                    break :blk @This(){ .callcode = .{
                        .caller = params.caller,
                        .to = params.to,
                        .value = params.value,
                        .input = cloned_input,
                        .gas = params.gas,
                    } };
                },
                .delegatecall => |params| blk: {
                    const cloned_input = try allocator.dupe(u8, params.input);
                    break :blk @This(){ .delegatecall = .{
                        .caller = params.caller,
                        .to = params.to,
                        .input = cloned_input,
                        .gas = params.gas,
                    } };
                },
                .staticcall => |params| blk: {
                    const cloned_input = try allocator.dupe(u8, params.input);
                    break :blk @This(){ .staticcall = .{
                        .caller = params.caller,
                        .to = params.to,
                        .input = cloned_input,
                        .gas = params.gas,
                    } };
                },
                .create => |params| blk: {
                    const cloned_init_code = try allocator.dupe(u8, params.init_code);
                    break :blk @This(){ .create = .{
                        .caller = params.caller,
                        .value = params.value,
                        .init_code = cloned_init_code,
                        .gas = params.gas,
                    } };
                },
                .create2 => |params| blk: {
                    const cloned_init_code = try allocator.dupe(u8, params.init_code);
                    break :blk @This(){ .create2 = .{
                        .caller = params.caller,
                        .value = params.value,
                        .init_code = cloned_init_code,
                        .salt = params.salt,
                        .gas = params.gas,
                    } };
                },
            };
        }

        /// Frees memory allocated by clone()
        /// Must be called when the cloned CallParams is no longer needed
        pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
            switch (self) {
                .call => |params| allocator.free(params.input),
                .callcode => |params| allocator.free(params.input),
                .delegatecall => |params| allocator.free(params.input),
                .staticcall => |params| allocator.free(params.input),
                .create => |params| allocator.free(params.init_code),
                .create2 => |params| allocator.free(params.init_code),
            }
        }

        /// Get the target address for the call (returns null for CREATE operations)
        pub fn get_to(self: @This()) ?primitives.Address {
            return switch (self) {
                .call => |p| p.to,
                .callcode => |p| p.to,
                .delegatecall => |p| p.to,
                .staticcall => |p| p.to,
                .create, .create2 => null,
            };
        }
    };
}

const std = @import("std");

// Default configuration for backward compatibility and tests
const default_config = struct {};
const DefaultCallParams = CallParams(default_config);

test "call params gas access" {
    const caller = primitives.ZERO_ADDRESS;
    const to: Address = .{ .bytes = [_]u8{1} ++ [_]u8{0} ** 19 };
    const input = &[_]u8{0x42};

    const call_op = DefaultCallParams{ .call = .{
        .caller = caller,
        .to = to,
        .value = 100,
        .input = input,
        .gas = 21000,
    } };
    try std.testing.expectEqual(@as(u64, 21000), call_op.getGas());

    const delegatecall_op = DefaultCallParams{ .delegatecall = .{
        .caller = caller,
        .to = to,
        .input = input,
        .gas = 15000,
    } };
    try std.testing.expectEqual(@as(u64, 15000), delegatecall_op.getGas());
}

test "call params caller access" {
    const caller: Address = .{ .bytes = [_]u8{0xaa} ++ [_]u8{0} ** 19 };
    const to: Address = .{ .bytes = [_]u8{1} ++ [_]u8{0} ** 19 };

    const call_op = DefaultCallParams{ .call = .{
        .caller = caller,
        .to = to,
        .value = 0,
        .input = &.{},
        .gas = 21000,
    } };
    try std.testing.expectEqual(caller, call_op.getCaller());

    const create_op = DefaultCallParams{ .create = .{
        .caller = caller,
        .value = 50,
        .init_code = &[_]u8{ 0x60, 0x00, 0x60, 0x00, 0xf3 },
        .gas = 53000,
    } };
    try std.testing.expectEqual(caller, create_op.getCaller());
}

test "call params input access" {
    const caller = primitives.ZERO_ADDRESS;
    const to: Address = .{ .bytes = [_]u8{1} ++ [_]u8{0} ** 19 };
    const input_data = &[_]u8{ 0xa9, 0x05, 0x9c, 0xbb }; // transfer(address,uint256) selector

    const call_op = DefaultCallParams{ .call = .{
        .caller = caller,
        .to = to,
        .value = 0,
        .input = input_data,
        .gas = 21000,
    } };
    try std.testing.expectEqualSlices(u8, input_data, call_op.getInput());

    const init_code = &[_]u8{ 0x60, 0x80, 0x60, 0x40, 0x52 };
    const create_op = DefaultCallParams{ .create = .{
        .caller = caller,
        .value = 0,
        .init_code = init_code,
        .gas = 53000,
    } };
    try std.testing.expectEqualSlices(u8, init_code, create_op.getInput());
}

test "call params getValue checks" {
    const caller = primitives.ZERO_ADDRESS;
    const to: Address = .{ .bytes = [_]u8{1} ++ [_]u8{0} ** 19 };
    const input = &[_]u8{};

    // CALL with value
    const call_with_value = DefaultCallParams{ .call = .{
        .caller = caller,
        .to = to,
        .value = 1000,
        .input = input,
        .gas = 21000,
    } };
    try std.testing.expect(call_with_value.getValue() == 1000);

    // CALL without value
    const call_no_value = DefaultCallParams{ .call = .{
        .caller = caller,
        .to = to,
        .value = 0,
        .input = input,
        .gas = 21000,
    } };
    try std.testing.expect(call_no_value.getValue() == 0);

    // DELEGATECALL never has value
    const delegatecall_op = DefaultCallParams{ .delegatecall = .{
        .caller = caller,
        .to = to,
        .input = input,
        .gas = 21000,
    } };
    try std.testing.expect(delegatecall_op.getValue() == 0);

    // STATICCALL never has value
    const staticcall_op = DefaultCallParams{ .staticcall = .{
        .caller = caller,
        .to = to,
        .input = input,
        .gas = 21000,
    } };
    try std.testing.expect(staticcall_op.getValue() == 0);

    // CREATE with value
    const create_with_value = DefaultCallParams{ .create = .{
        .caller = caller,
        .value = 500,
        .init_code = &[_]u8{0x00},
        .gas = 53000,
    } };
    try std.testing.expect(create_with_value.getValue() == 500);
}

test "call params read only checks" {
    const caller = primitives.ZERO_ADDRESS;
    const to: Address = .{ .bytes = [_]u8{1} ++ [_]u8{0} ** 19 };
    const input = &[_]u8{};

    // Only STATICCALL is read-only
    const staticcall_op = DefaultCallParams{ .staticcall = .{
        .caller = caller,
        .to = to,
        .input = input,
        .gas = 21000,
    } };
    try std.testing.expect(staticcall_op.isReadOnly());

    // Regular CALL is not read-only
    const call_op = DefaultCallParams{ .call = .{
        .caller = caller,
        .to = to,
        .value = 0,
        .input = input,
        .gas = 21000,
    } };
    try std.testing.expect(!call_op.isReadOnly());

    // DELEGATECALL is not read-only
    const delegatecall_op = DefaultCallParams{ .delegatecall = .{
        .caller = caller,
        .to = to,
        .input = input,
        .gas = 21000,
    } };
    try std.testing.expect(!delegatecall_op.isReadOnly());
}

test "call params create checks" {
    const caller = primitives.ZERO_ADDRESS;
    const to: Address = .{ .bytes = [_]u8{1} ++ [_]u8{0} ** 19 };
    const init_code = &[_]u8{ 0x60, 0x00, 0x60, 0x00, 0xf3 };

    // CREATE operations
    const create_op = DefaultCallParams{ .create = .{
        .caller = caller,
        .value = 0,
        .init_code = init_code,
        .gas = 53000,
    } };
    try std.testing.expect(create_op.isCreate());

    const create2_op = DefaultCallParams{ .create2 = .{
        .caller = caller,
        .value = 0,
        .init_code = init_code,
        .salt = 0x123456789abcdef,
        .gas = 53000,
    } };
    try std.testing.expect(create2_op.isCreate());

    // Non-CREATE operations
    const call_op = DefaultCallParams{ .call = .{
        .caller = caller,
        .to = to,
        .value = 0,
        .input = &[_]u8{},
        .gas = 21000,
    } };
    try std.testing.expect(!call_op.isCreate());
}

test "call params edge cases" {
    const caller: Address = .{ .bytes = [_]u8{0xff} ** 20 }; // Maximum address
    const to: Address = .{ .bytes = [_]u8{1} ++ [_]u8{0} ** 19 };

    // Maximum gas
    const max_gas_call = DefaultCallParams{ .call = .{
        .caller = caller,
        .to = to,
        .value = std.math.maxInt(u256),
        .input = &[_]u8{},
        .gas = std.math.maxInt(u64),
    } };
    try std.testing.expectEqual(std.math.maxInt(u64), max_gas_call.getGas());
    try std.testing.expect(max_gas_call.getValue() == std.math.maxInt(u256));

    // CREATE2 with maximum salt
    const create2_max_salt = DefaultCallParams{ .create2 = .{
        .caller = caller,
        .value = 0,
        .init_code = &[_]u8{0x00},
        .salt = std.math.maxInt(u256),
        .gas = 100000,
    } };
    try std.testing.expect(create2_max_salt.isCreate());
    try std.testing.expect(create2_max_salt.getValue() == 0);

    // Empty input data
    const call_empty_input = DefaultCallParams{
        .call = .{
            .caller = caller,
            .to = to,
            .value = 0,
            .input = &[_]u8{}, // Empty slice
            .gas = 21000,
        },
    };
    try std.testing.expectEqual(@as(usize, 0), call_empty_input.getInput().len);
}

test "call params validation - zero gas error" {
    const caller = primitives.ZERO_ADDRESS;
    const to: Address = .{ .bytes = [_]u8{1} ++ [_]u8{0} ** 19 };

    // CALL with zero gas should fail validation
    const call_zero_gas = DefaultCallParams{ .call = .{
        .caller = caller,
        .to = to,
        .value = 100,
        .input = &[_]u8{},
        .gas = 0,
    } };
    try std.testing.expectError(DefaultCallParams.ValidationError.GasZeroError, call_zero_gas.validate());

    // DELEGATECALL with zero gas should fail validation
    const delegatecall_zero_gas = DefaultCallParams{ .delegatecall = .{
        .caller = caller,
        .to = to,
        .input = &[_]u8{},
        .gas = 0,
    } };
    try std.testing.expectError(DefaultCallParams.ValidationError.GasZeroError, delegatecall_zero_gas.validate());

    // CREATE with zero gas should fail validation
    const create_zero_gas = DefaultCallParams{ .create = .{
        .caller = caller,
        .value = 0,
        .init_code = &[_]u8{0x00},
        .gas = 0,
    } };
    try std.testing.expectError(DefaultCallParams.ValidationError.GasZeroError, create_zero_gas.validate());

    // CREATE2 with zero gas should fail validation
    const create2_zero_gas = DefaultCallParams{ .create2 = .{
        .caller = caller,
        .value = 0,
        .init_code = &[_]u8{0x00},
        .salt = 0x123,
        .gas = 0,
    } };
    try std.testing.expectError(DefaultCallParams.ValidationError.GasZeroError, create2_zero_gas.validate());
}

test "call params validation - non-zero gas success" {
    const caller = primitives.ZERO_ADDRESS;
    const to: Address = .{ .bytes = [_]u8{1} ++ [_]u8{0} ** 19 };

    // All operations with non-zero gas should pass validation
    const operations = [_]DefaultCallParams{
        DefaultCallParams{ .call = .{
            .caller = caller,
            .to = to,
            .value = 100,
            .input = &[_]u8{},
            .gas = 1,
        } },
        DefaultCallParams{ .callcode = .{
            .caller = caller,
            .to = to,
            .value = 100,
            .input = &[_]u8{},
            .gas = 1,
        } },
        DefaultCallParams{ .delegatecall = .{
            .caller = caller,
            .to = to,
            .input = &[_]u8{},
            .gas = 1,
        } },
        DefaultCallParams{ .staticcall = .{
            .caller = caller,
            .to = to,
            .input = &[_]u8{},
            .gas = 1,
        } },
        DefaultCallParams{ .create = .{
            .caller = caller,
            .value = 0,
            .init_code = &[_]u8{0x00},
            .gas = 1,
        } },
        DefaultCallParams{ .create2 = .{
            .caller = caller,
            .value = 0,
            .init_code = &[_]u8{0x00},
            .salt = 0x123,
            .gas = 1,
        } },
    };

    for (operations) |op| {
        try op.validate();
    }
}

test "call params callcode operation" {
    const caller: Address = .{ .bytes = [_]u8{0xaa} ++ [_]u8{0} ** 19 };
    const to: Address = .{ .bytes = [_]u8{0xbb} ++ [_]u8{0} ** 19 };
    const input_data = &[_]u8{ 0x12, 0x34, 0x56, 0x78 };

    const callcode_op = DefaultCallParams{ .callcode = .{
        .caller = caller,
        .to = to,
        .value = 1000,
        .input = input_data,
        .gas = 25000,
    } };

    try std.testing.expectEqual(@as(u64, 25000), callcode_op.getGas());
    try std.testing.expectEqual(caller, callcode_op.getCaller());
    try std.testing.expectEqualSlices(u8, input_data, callcode_op.getInput());
    try std.testing.expect(callcode_op.getValue() == 1000);
    try std.testing.expect(!callcode_op.isReadOnly());
    try std.testing.expect(!callcode_op.isCreate());
}

test "call params create2 salt handling" {
    const caller = primitives.ZERO_ADDRESS;
    const init_code = &[_]u8{ 0x60, 0x80, 0x60, 0x40, 0x52, 0x60, 0x04, 0x36, 0x10 };

    // Test various salt values
    const salt_values = [_]u256{
        0,
        1,
        0x123456789abcdef0,
        0xdeadbeefcafebabe,
        std.math.maxInt(u64),
        std.math.maxInt(u128),
        std.math.maxInt(u256),
    };

    for (salt_values) |salt| {
        const create2_op = DefaultCallParams{ .create2 = .{
            .caller = caller,
            .value = 0,
            .init_code = init_code,
            .salt = salt,
            .gas = 32000,
        } };

        try std.testing.expectEqual(@as(u64, 32000), create2_op.getGas());
        try std.testing.expectEqual(caller, create2_op.getCaller());
        try std.testing.expectEqualSlices(u8, init_code, create2_op.getInput());
        try std.testing.expect(create2_op.getValue() == 0);
        try std.testing.expect(!create2_op.isReadOnly());
        try std.testing.expect(create2_op.isCreate());
    }
}

test "call params large input data" {
    const caller = primitives.ZERO_ADDRESS;
    const to: Address = .{ .bytes = [_]u8{1} ++ [_]u8{0} ** 19 };

    // Test with large input data
    var large_input: [1024]u8 = undefined;
    for (0..1024) |i| {
        large_input[i] = @intCast(i % 256);
    }

    const call_large_input = DefaultCallParams{ .call = .{
        .caller = caller,
        .to = to,
        .value = 0,
        .input = &large_input,
        .gas = 100000,
    } };

    try std.testing.expectEqualSlices(u8, &large_input, call_large_input.getInput());
    try std.testing.expectEqual(@as(usize, 1024), call_large_input.getInput().len);
}

test "call params address boundary values" {
    const zero_address = primitives.ZERO_ADDRESS;
    const max_address: Address = .{ .bytes = [_]u8{0xFF} ** 20 };

    // Test with zero address as caller and target
    const zero_call = DefaultCallParams{ .call = .{
        .caller = zero_address,
        .to = zero_address,
        .value = 0,
        .input = &[_]u8{},
        .gas = 21000,
    } };
    try std.testing.expectEqual(zero_address, zero_call.getCaller());

    // Test with max address as caller and target
    const max_call = DefaultCallParams{ .call = .{
        .caller = max_address,
        .to = max_address,
        .value = 0,
        .input = &[_]u8{},
        .gas = 21000,
    } };
    try std.testing.expectEqual(max_address, max_call.getCaller());
}

test "call params value edge cases" {
    const caller = primitives.ZERO_ADDRESS;
    const to: Address = .{ .bytes = [_]u8{1} ++ [_]u8{0} ** 19 };
    const init_code = &[_]u8{0x00};

    // Test minimum positive value
    const call_min_value = DefaultCallParams{ .call = .{
        .caller = caller,
        .to = to,
        .value = 1,
        .input = &[_]u8{},
        .gas = 21000,
    } };
    try std.testing.expect(call_min_value.getValue() == 1);

    // Test maximum value
    const call_max_value = DefaultCallParams{ .call = .{
        .caller = caller,
        .to = to,
        .value = std.math.maxInt(u256),
        .input = &[_]u8{},
        .gas = 21000,
    } };
    try std.testing.expect(call_max_value.getValue() == std.math.maxInt(u256));

    // Test CREATE with max value
    const create_max_value = DefaultCallParams{ .create = .{
        .caller = caller,
        .value = std.math.maxInt(u256),
        .init_code = init_code,
        .gas = 53000,
    } };
    try std.testing.expect(create_max_value.getValue() == std.math.maxInt(u256));
    try std.testing.expect(create_max_value.isCreate());

    // Test CREATE2 with max value
    const create2_max_value = DefaultCallParams{ .create2 = .{
        .caller = caller,
        .value = std.math.maxInt(u256),
        .init_code = init_code,
        .salt = 0x123,
        .gas = 53000,
    } };
    try std.testing.expect(create2_max_value.getValue() == std.math.maxInt(u256));
    try std.testing.expect(create2_max_value.isCreate());
}

test "call params gas limit edge cases" {
    const caller = primitives.ZERO_ADDRESS;
    const to: Address = .{ .bytes = [_]u8{1} ++ [_]u8{0} ** 19 };
    const init_code = &[_]u8{0x00};

    // Test minimum gas (1)
    const call_min_gas = DefaultCallParams{ .call = .{
        .caller = caller,
        .to = to,
        .value = 0,
        .input = &[_]u8{},
        .gas = 1,
    } };
    try std.testing.expectEqual(@as(u64, 1), call_min_gas.getGas());

    // Test typical gas values
    const typical_gas_values = [_]u64{ 21000, 100000, 1000000, 10000000 };

    for (typical_gas_values) |gas_val| {
        const ops = [_]DefaultCallParams{
            DefaultCallParams{ .call = .{
                .caller = caller,
                .to = to,
                .value = 0,
                .input = &[_]u8{},
                .gas = gas_val,
            } },
            DefaultCallParams{ .delegatecall = .{
                .caller = caller,
                .to = to,
                .input = &[_]u8{},
                .gas = gas_val,
            } },
            DefaultCallParams{ .staticcall = .{
                .caller = caller,
                .to = to,
                .input = &[_]u8{},
                .gas = gas_val,
            } },
            DefaultCallParams{ .create = .{
                .caller = caller,
                .value = 0,
                .init_code = init_code,
                .gas = gas_val,
            } },
        };

        for (ops) |op| {
            try std.testing.expectEqual(gas_val, op.getGas());
        }
    }
}

test "call params validation - input size limits" {
    const caller = primitives.ZERO_ADDRESS;
    const to: Address = .{ .bytes = [_]u8{1} ++ [_]u8{0} ** 19 };
    const MAX_INPUT_SIZE = 1024 * 1024 * 4; // 4MB

    // Test with maximum allowed input size
    const max_input = try std.testing.allocator.alloc(u8, MAX_INPUT_SIZE);
    defer std.testing.allocator.free(max_input);
    @memset(max_input, 0xAA);

    const call_max = DefaultCallParams{ .call = .{
        .caller = caller,
        .to = to,
        .value = 0,
        .input = max_input,
        .gas = 1000000,
    } };
    try call_max.validate(); // Should pass

    // Test with oversized input
    const oversized_input = try std.testing.allocator.alloc(u8, MAX_INPUT_SIZE + 1);
    defer std.testing.allocator.free(oversized_input);
    @memset(oversized_input, 0xBB);

    const call_oversized = DefaultCallParams{ .call = .{
        .caller = caller,
        .to = to,
        .value = 0,
        .input = oversized_input,
        .gas = 1000000,
    } };
    try std.testing.expectError(DefaultCallParams.ValidationError.InvalidInputSize, call_oversized.validate());

    // Test DELEGATECALL with oversized input
    const delegatecall_oversized = DefaultCallParams{ .delegatecall = .{
        .caller = caller,
        .to = to,
        .input = oversized_input,
        .gas = 1000000,
    } };
    try std.testing.expectError(DefaultCallParams.ValidationError.InvalidInputSize, delegatecall_oversized.validate());

    // Test STATICCALL with oversized input
    const staticcall_oversized = DefaultCallParams{ .staticcall = .{
        .caller = caller,
        .to = to,
        .input = oversized_input,
        .gas = 1000000,
    } };
    try std.testing.expectError(DefaultCallParams.ValidationError.InvalidInputSize, staticcall_oversized.validate());

    // Test CALLCODE with oversized input
    const callcode_oversized = DefaultCallParams{ .callcode = .{
        .caller = caller,
        .to = to,
        .value = 0,
        .input = oversized_input,
        .gas = 1000000,
    } };
    try std.testing.expectError(DefaultCallParams.ValidationError.InvalidInputSize, callcode_oversized.validate());
}

test "call params validation - init code size limits" {
    const caller = primitives.ZERO_ADDRESS;
    const MAX_INITCODE_SIZE = 49152; // EIP-3860 limit

    // Test with maximum allowed init code size
    const max_init_code = try std.testing.allocator.alloc(u8, MAX_INITCODE_SIZE);
    defer std.testing.allocator.free(max_init_code);
    @memset(max_init_code, 0x60); // PUSH1

    const create_max = DefaultCallParams{ .create = .{
        .caller = caller,
        .value = 0,
        .init_code = max_init_code,
        .gas = 1000000,
    } };
    try create_max.validate(); // Should pass

    const create2_max = DefaultCallParams{ .create2 = .{
        .caller = caller,
        .value = 0,
        .init_code = max_init_code,
        .salt = 0x123456,
        .gas = 1000000,
    } };
    try create2_max.validate(); // Should pass

    // Test with oversized init code
    const oversized_init_code = try std.testing.allocator.alloc(u8, MAX_INITCODE_SIZE + 1);
    defer std.testing.allocator.free(oversized_init_code);
    @memset(oversized_init_code, 0x60);

    const create_oversized = DefaultCallParams{ .create = .{
        .caller = caller,
        .value = 0,
        .init_code = oversized_init_code,
        .gas = 1000000,
    } };
    try std.testing.expectError(DefaultCallParams.ValidationError.InvalidInitCodeSize, create_oversized.validate());

    const create2_oversized = DefaultCallParams{ .create2 = .{
        .caller = caller,
        .value = 0,
        .init_code = oversized_init_code,
        .salt = 0x789ABC,
        .gas = 1000000,
    } };
    try std.testing.expectError(DefaultCallParams.ValidationError.InvalidInitCodeSize, create2_oversized.validate());
}

test "call params all operation types coverage" {
    const caller: Address = .{ .bytes = [_]u8{0xaa} ++ [_]u8{0} ** 19 };
    const to: Address = .{ .bytes = [_]u8{0xbb} ++ [_]u8{0} ** 19 };
    const input_data = &[_]u8{ 0x42, 0x24 };
    const init_code = &[_]u8{ 0x60, 0x00, 0xf3 };

    // Test all operation types exist and work
    const operations = [_]DefaultCallParams{
        // CALL
        DefaultCallParams{ .call = .{
            .caller = caller,
            .to = to,
            .value = 100,
            .input = input_data,
            .gas = 25000,
        } },
        // CALLCODE
        DefaultCallParams{ .callcode = .{
            .caller = caller,
            .to = to,
            .value = 200,
            .input = input_data,
            .gas = 30000,
        } },
        // DELEGATECALL
        DefaultCallParams{ .delegatecall = .{
            .caller = caller,
            .to = to,
            .input = input_data,
            .gas = 35000,
        } },
        // STATICCALL
        DefaultCallParams{ .staticcall = .{
            .caller = caller,
            .to = to,
            .input = input_data,
            .gas = 40000,
        } },
        // CREATE
        DefaultCallParams{ .create = .{
            .caller = caller,
            .value = 500,
            .init_code = init_code,
            .gas = 53000,
        } },
        // CREATE2
        DefaultCallParams{ .create2 = .{
            .caller = caller,
            .value = 600,
            .init_code = init_code,
            .salt = 0xdeadbeef,
            .gas = 55000,
        } },
    };

    // Verify all operations can be validated and accessed
    for (operations) |op| {
        try op.validate();
        _ = op.getGas();
        _ = op.getCaller();
        _ = op.getInput();
        _ = op.getValue();
        _ = op.isReadOnly();
        _ = op.isCreate();
    }
}

test "call params method consistency" {
    const caller: Address = .{ .bytes = [_]u8{0xaa} ++ [_]u8{0} ** 19 };
    const to: Address = .{ .bytes = [_]u8{0xbb} ++ [_]u8{0} ** 19 };
    const input_data = &[_]u8{0x12};

    // Test that delegatecall correctly reports no value transfer
    const delegatecall_op = DefaultCallParams{ .delegatecall = .{
        .caller = caller,
        .to = to,
        .input = input_data,
        .gas = 25000,
    } };

    try std.testing.expect(delegatecall_op.getValue() == 0);
    try std.testing.expect(!delegatecall_op.isReadOnly());
    try std.testing.expect(!delegatecall_op.isCreate());

    // Test that staticcall correctly reports read-only
    const staticcall_op = DefaultCallParams{ .staticcall = .{
        .caller = caller,
        .to = to,
        .input = input_data,
        .gas = 25000,
    } };

    try std.testing.expect(staticcall_op.getValue() == 0);
    try std.testing.expect(staticcall_op.isReadOnly());
    try std.testing.expect(!staticcall_op.isCreate());
}

test "call params input vs init code consistency" {
    const caller = primitives.ZERO_ADDRESS;
    const to: Address = .{ .bytes = [_]u8{1} ++ [_]u8{0} ** 19 };
    const call_input = &[_]u8{ 0xa9, 0x05, 0x9c, 0xbb };
    const init_code = &[_]u8{ 0x60, 0x80, 0x60, 0x40, 0x52 };

    // Regular calls use input field
    const call_op = DefaultCallParams{ .call = .{
        .caller = caller,
        .to = to,
        .value = 0,
        .input = call_input,
        .gas = 21000,
    } };
    try std.testing.expectEqualSlices(u8, call_input, call_op.getInput());

    // Create operations use init_code field but return it via getInput()
    const create_op = DefaultCallParams{ .create = .{
        .caller = caller,
        .value = 0,
        .init_code = init_code,
        .gas = 53000,
    } };
    try std.testing.expectEqualSlices(u8, init_code, create_op.getInput());
}

test "call params clone and deinit" {
    const testing_allocator = std.testing.allocator;
    const caller: Address = .{ .bytes = [_]u8{0xaa} ++ [_]u8{0} ** 19 };
    const to: Address = .{ .bytes = [_]u8{0xbb} ++ [_]u8{0} ** 19 };
    const input_data = &[_]u8{ 0x12, 0x34, 0x56, 0x78 };
    const init_code = &[_]u8{ 0x60, 0x00, 0x60, 0x00, 0xf3 };

    // Test CALL clone
    {
        const original = DefaultCallParams{ .call = .{
            .caller = caller,
            .to = to,
            .value = 100,
            .input = input_data,
            .gas = 25000,
        } };

        const cloned = try original.clone(testing_allocator);
        defer cloned.deinit(testing_allocator);

        try std.testing.expectEqual(original.getGas(), cloned.getGas());
        try std.testing.expectEqual(original.getCaller(), cloned.getCaller());
        try std.testing.expectEqualSlices(u8, original.getInput(), cloned.getInput());

        // Verify it's a deep copy (different memory addresses)
        try std.testing.expect(original.call.input.ptr != cloned.call.input.ptr);
    }

    // Test DELEGATECALL clone
    {
        const original = DefaultCallParams{ .delegatecall = .{
            .caller = caller,
            .to = to,
            .input = input_data,
            .gas = 30000,
        } };

        const cloned = try original.clone(testing_allocator);
        defer cloned.deinit(testing_allocator);

        try std.testing.expectEqual(original.getGas(), cloned.getGas());
        try std.testing.expectEqual(original.getCaller(), cloned.getCaller());
        try std.testing.expectEqualSlices(u8, original.getInput(), cloned.getInput());
        try std.testing.expect(original.delegatecall.input.ptr != cloned.delegatecall.input.ptr);
    }

    // Test STATICCALL clone
    {
        const original = DefaultCallParams{ .staticcall = .{
            .caller = caller,
            .to = to,
            .input = input_data,
            .gas = 35000,
        } };

        const cloned = try original.clone(testing_allocator);
        defer cloned.deinit(testing_allocator);

        try std.testing.expectEqual(original.getGas(), cloned.getGas());
        try std.testing.expectEqual(original.getCaller(), cloned.getCaller());
        try std.testing.expectEqualSlices(u8, original.getInput(), cloned.getInput());
        try std.testing.expect(original.staticcall.input.ptr != cloned.staticcall.input.ptr);
    }

    // Test CREATE clone
    {
        const original = DefaultCallParams{ .create = .{
            .caller = caller,
            .value = 500,
            .init_code = init_code,
            .gas = 53000,
        } };

        const cloned = try original.clone(testing_allocator);
        defer cloned.deinit(testing_allocator);

        try std.testing.expectEqual(original.getGas(), cloned.getGas());
        try std.testing.expectEqual(original.getCaller(), cloned.getCaller());
        try std.testing.expectEqualSlices(u8, original.getInput(), cloned.getInput());
        try std.testing.expect(original.create.init_code.ptr != cloned.create.init_code.ptr);
    }

    // Test CREATE2 clone
    {
        const original = DefaultCallParams{ .create2 = .{
            .caller = caller,
            .value = 600,
            .init_code = init_code,
            .salt = 0xdeadbeef,
            .gas = 55000,
        } };

        const cloned = try original.clone(testing_allocator);
        defer cloned.deinit(testing_allocator);

        try std.testing.expectEqual(original.getGas(), cloned.getGas());
        try std.testing.expectEqual(original.getCaller(), cloned.getCaller());
        try std.testing.expectEqualSlices(u8, original.getInput(), cloned.getInput());
        try std.testing.expectEqual(original.create2.salt, cloned.create2.salt);
        try std.testing.expect(original.create2.init_code.ptr != cloned.create2.init_code.ptr);
    }

    // Test CALLCODE clone
    {
        const original = DefaultCallParams{ .callcode = .{
            .caller = caller,
            .to = to,
            .value = 200,
            .input = input_data,
            .gas = 40000,
        } };

        const cloned = try original.clone(testing_allocator);
        defer cloned.deinit(testing_allocator);

        try std.testing.expectEqual(original.getGas(), cloned.getGas());
        try std.testing.expectEqual(original.getCaller(), cloned.getCaller());
        try std.testing.expectEqualSlices(u8, original.getInput(), cloned.getInput());
        try std.testing.expect(original.callcode.input.ptr != cloned.callcode.input.ptr);
    }
}

test "call params clone empty input" {
    const testing_allocator = std.testing.allocator;
    const caller = primitives.ZERO_ADDRESS;
    const to: Address = .{ .bytes = [_]u8{1} ++ [_]u8{0} ** 19 };

    // Test with empty input slice
    const original = DefaultCallParams{ .call = .{
        .caller = caller,
        .to = to,
        .value = 0,
        .input = &[_]u8{},
        .gas = 21000,
    } };

    const cloned = try original.clone(testing_allocator);
    defer cloned.deinit(testing_allocator);

    try std.testing.expectEqual(@as(usize, 0), cloned.getInput().len);
    try std.testing.expectEqual(original.getGas(), cloned.getGas());
    try std.testing.expectEqual(original.getCaller(), cloned.getCaller());
}

test "call params clone large input" {
    const testing_allocator = std.testing.allocator;
    const caller = primitives.ZERO_ADDRESS;
    const to: Address = .{ .bytes = [_]u8{1} ++ [_]u8{0} ** 19 };

    // Create large input data
    var large_input: [1024]u8 = undefined;
    for (0..1024) |i| {
        large_input[i] = @intCast(i % 256);
    }

    const original = DefaultCallParams{ .call = .{
        .caller = caller,
        .to = to,
        .value = 0,
        .input = &large_input,
        .gas = 100000,
    } };

    const cloned = try original.clone(testing_allocator);
    defer cloned.deinit(testing_allocator);

    try std.testing.expectEqualSlices(u8, &large_input, cloned.getInput());
    try std.testing.expect(original.call.input.ptr != cloned.call.input.ptr);
}

test "call params setGas" {
    const caller = primitives.ZERO_ADDRESS;
    const to: Address = .{ .bytes = [_]u8{1} ++ [_]u8{0} ** 19 };
    const input = &[_]u8{0x42};
    const init_code = &[_]u8{ 0x60, 0x00, 0xf3 };

    // Test CALL setGas
    {
        var call_op = DefaultCallParams{ .call = .{
            .caller = caller,
            .to = to,
            .value = 100,
            .input = input,
            .gas = 21000,
        } };

        try std.testing.expectEqual(@as(u64, 21000), call_op.getGas());
        call_op.setGas(50000);
        try std.testing.expectEqual(@as(u64, 50000), call_op.getGas());
    }

    // Test DELEGATECALL setGas
    {
        var delegatecall_op = DefaultCallParams{ .delegatecall = .{
            .caller = caller,
            .to = to,
            .input = input,
            .gas = 15000,
        } };

        try std.testing.expectEqual(@as(u64, 15000), delegatecall_op.getGas());
        delegatecall_op.setGas(30000);
        try std.testing.expectEqual(@as(u64, 30000), delegatecall_op.getGas());
    }

    // Test STATICCALL setGas
    {
        var staticcall_op = DefaultCallParams{ .staticcall = .{
            .caller = caller,
            .to = to,
            .input = input,
            .gas = 20000,
        } };

        try std.testing.expectEqual(@as(u64, 20000), staticcall_op.getGas());
        staticcall_op.setGas(40000);
        try std.testing.expectEqual(@as(u64, 40000), staticcall_op.getGas());
    }

    // Test CALLCODE setGas
    {
        var callcode_op = DefaultCallParams{ .callcode = .{
            .caller = caller,
            .to = to,
            .value = 200,
            .input = input,
            .gas = 25000,
        } };

        try std.testing.expectEqual(@as(u64, 25000), callcode_op.getGas());
        callcode_op.setGas(60000);
        try std.testing.expectEqual(@as(u64, 60000), callcode_op.getGas());
    }

    // Test CREATE setGas
    {
        var create_op = DefaultCallParams{ .create = .{
            .caller = caller,
            .value = 500,
            .init_code = init_code,
            .gas = 53000,
        } };

        try std.testing.expectEqual(@as(u64, 53000), create_op.getGas());
        create_op.setGas(70000);
        try std.testing.expectEqual(@as(u64, 70000), create_op.getGas());
    }

    // Test CREATE2 setGas
    {
        var create2_op = DefaultCallParams{ .create2 = .{
            .caller = caller,
            .value = 600,
            .init_code = init_code,
            .salt = 0xdeadbeef,
            .gas = 55000,
        } };

        try std.testing.expectEqual(@as(u64, 55000), create2_op.getGas());
        create2_op.setGas(80000);
        try std.testing.expectEqual(@as(u64, 80000), create2_op.getGas());
    }
}

test "call params validation - comprehensive" {
    const caller = primitives.ZERO_ADDRESS;
    const to: Address = .{ .bytes = [_]u8{1} ++ [_]u8{0} ** 19 };

    // Small valid input - should pass
    const small_input = &[_]u8{ 0x12, 0x34, 0x56, 0x78 };
    const call_small = DefaultCallParams{ .call = .{
        .caller = caller,
        .to = to,
        .value = 100,
        .input = small_input,
        .gas = 21000,
    } };
    try call_small.validate();

    // Small valid init code - should pass
    const small_init = &[_]u8{ 0x60, 0x00, 0x60, 0x00, 0xf3 };
    const create_small = DefaultCallParams{ .create = .{
        .caller = caller,
        .value = 0,
        .init_code = small_init,
        .gas = 53000,
    } };
    try create_small.validate();

    // Test all call types with valid parameters
    const valid_ops = [_]DefaultCallParams{
        DefaultCallParams{ .call = .{
            .caller = caller,
            .to = to,
            .value = 100,
            .input = small_input,
            .gas = 21000,
        } },
        DefaultCallParams{ .callcode = .{
            .caller = caller,
            .to = to,
            .value = 100,
            .input = small_input,
            .gas = 21000,
        } },
        DefaultCallParams{ .delegatecall = .{
            .caller = caller,
            .to = to,
            .input = small_input,
            .gas = 21000,
        } },
        DefaultCallParams{ .staticcall = .{
            .caller = caller,
            .to = to,
            .input = small_input,
            .gas = 21000,
        } },
        DefaultCallParams{ .create = .{
            .caller = caller,
            .value = 100,
            .init_code = small_init,
            .gas = 53000,
        } },
        DefaultCallParams{ .create2 = .{
            .caller = caller,
            .value = 100,
            .init_code = small_init,
            .salt = 0x123456,
            .gas = 53000,
        } },
    };

    for (valid_ops) |op| {
        try op.validate();
    }
}

test "call params setGas edge cases" {
    const caller = primitives.ZERO_ADDRESS;
    const to: Address = .{ .bytes = [_]u8{1} ++ [_]u8{0} ** 19 };

    // Test setting gas to 0 (should fail validation after)
    {
        var call_op = DefaultCallParams{ .call = .{
            .caller = caller,
            .to = to,
            .value = 0,
            .input = &[_]u8{},
            .gas = 1000,
        } };

        call_op.setGas(0);
        try std.testing.expectEqual(@as(u64, 0), call_op.getGas());
        try std.testing.expectError(DefaultCallParams.ValidationError.GasZeroError, call_op.validate());
    }

    // Test setting gas to max value
    {
        var call_op = DefaultCallParams{ .call = .{
            .caller = caller,
            .to = to,
            .value = 0,
            .input = &[_]u8{},
            .gas = 1000,
        } };

        const max_gas = std.math.maxInt(u64);
        call_op.setGas(max_gas);
        try std.testing.expectEqual(max_gas, call_op.getGas());
    }

    // Test multiple gas updates
    {
        var call_op = DefaultCallParams{ .call = .{
            .caller = caller,
            .to = to,
            .value = 0,
            .input = &[_]u8{},
            .gas = 1000,
        } };

        call_op.setGas(2000);
        try std.testing.expectEqual(@as(u64, 2000), call_op.getGas());

        call_op.setGas(3000);
        try std.testing.expectEqual(@as(u64, 3000), call_op.getGas());

        call_op.setGas(1500);
        try std.testing.expectEqual(@as(u64, 1500), call_op.getGas());
    }
}
