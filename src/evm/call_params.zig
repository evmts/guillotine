const primitives = @import("primitives");
const Address = primitives.Address;

// TODO: Currently used in host which is unused
/// Call operation parameters for different call types - generic version
pub fn CallParams(comptime config: anytype) type {
    const WordType = config.WordType;
    const AddressType = config.AddressType;
    const GasType = config.frame_config().GasType();
    
    return union(enum) {
        /// Regular CALL operation
        call: struct {
            caller: AddressType,
            to: AddressType,
            value: WordType,
            input: []const u8,
            gas: GasType,
        },
        /// CALLCODE operation: execute external code with current storage/context
        /// Executes code at `to`, but uses caller's storage and address context
        callcode: struct {
            caller: AddressType,
            to: AddressType,
            value: WordType,
            input: []const u8,
            gas: GasType,
        },
        /// DELEGATECALL operation (preserves caller context)
        delegatecall: struct {
            caller: AddressType, // Original caller, not current contract
            to: AddressType,
            input: []const u8,
            gas: GasType,
        },
        /// STATICCALL operation (read-only)
        staticcall: struct {
            caller: AddressType,
            to: AddressType,
            input: []const u8,
            gas: GasType,
        },
        /// CREATE operation
        create: struct {
            caller: AddressType,
            value: WordType,
            init_code: []const u8,
            gas: GasType,
        },
        /// CREATE2 operation
        create2: struct {
            caller: AddressType,
            value: WordType,
            init_code: []const u8,
            salt: WordType,
            gas: GasType,
        },

        const Self = @This();

        pub const ValidationError = error{
            GasZeroError,
        };

        /// TODO we need to validate input!
        pub fn validate(self: Self) ValidationError!void {
            if (self.getGas() == 0) return ValidationError.GasZeroError;
        }

        /// Get the gas limit for this call operation
        pub fn getGas(self: Self) GasType {
            return switch (self) {
                .call => |params| params.gas,
                .callcode => |params| params.gas,
                .delegatecall => |params| params.gas,
                .staticcall => |params| params.gas,
                .create => |params| params.gas,
                .create2 => |params| params.gas,
            };
        }

        /// Get the caller address for this call operation
        pub fn getCaller(self: Self) AddressType {
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
        pub fn getInput(self: Self) []const u8 {
            return switch (self) {
                .call => |params| params.input,
                .callcode => |params| params.input,
                .delegatecall => |params| params.input,
                .staticcall => |params| params.input,
                .create => |params| params.init_code,
                .create2 => |params| params.init_code,
            };
        }

        /// Check if this call operation transfers value
        pub fn hasValue(self: Self) bool {
            return switch (self) {
                .call => |params| params.value > 0,
                .callcode => |params| params.value > 0,
                .delegatecall => false, // DELEGATECALL preserves value from parent context
                .staticcall => false, // STATICCALL cannot transfer value
                .create => |params| params.value > 0,
                .create2 => |params| params.value > 0,
            };
        }

        /// Check if this is a read-only operation
        pub fn isReadOnly(self: Self) bool {
            return switch (self) {
                .staticcall => true,
                else => false,
            };
        }

        /// Check if this is a contract creation operation
        pub fn isCreate(self: Self) bool {
            return switch (self) {
                .create, .create2 => true,
                else => false,
            };
        }
    };
}

const std = @import("std");

test "CallParams - generic function with default config" {
    const EvmConfig = @import("evm_config.zig").EvmConfig;
    const default_config = EvmConfig{};
    const CallParamsType = CallParams(default_config);
    const GasType = default_config.frame_config().GasType();
    
    const caller = primitives.ZERO_ADDRESS;
    const to: [20]u8 = [_]u8{1} ++ [_]u8{0} ** 19;
    
    const call_op = CallParamsType{ .call = .{
        .caller = caller,
        .to = to,
        .value = 100, // Should use WordType (u256)
        .input = &[_]u8{0x42},
        .gas = @as(GasType, 21000),
    } };
    
    try std.testing.expectEqual(@as(u256, 100), call_op.call.value);
    try std.testing.expectEqual(@as(GasType, 21000), call_op.getGas());
}

test "CallParams - all operation types with custom config" {
    const EvmConfig = @import("evm_config.zig").EvmConfig;
    const custom_config = EvmConfig{
        .WordType = u128,
        .AddressType = [16]u8,
        .block_gas_limit = 1000000, // Forces i32 gas type
    };
    comptime custom_config.validate();
    const CallParamsType = CallParams(custom_config);
    const GasType = custom_config.frame_config().GasType(); // i32
    
    const caller: [16]u8 = [_]u8{0xAA} ++ [_]u8{0} ** 15;
    const to: [16]u8 = [_]u8{0xBB} ++ [_]u8{0} ** 15;
    
    // Test CALL with u128 value and i32 gas
    const call_op = CallParamsType{ .call = .{
        .caller = caller,
        .to = to,
        .value = @as(u128, 1000),
        .input = &[_]u8{0x42},
        .gas = @as(i32, 21000),
    } };
    
    // Test CREATE2 with u128 value and u128 salt
    const create2_op = CallParamsType{ .create2 = .{
        .caller = caller,
        .value = @as(u128, 500),
        .init_code = &[_]u8{0x60, 0x80},
        .salt = @as(u128, 0x123456),
        .gas = @as(i32, 53000),
    } };
    
    try std.testing.expectEqual(@as(u128, 1000), call_op.call.value);
    try std.testing.expectEqual(@as(i32, 21000), call_op.call.gas);
    try std.testing.expectEqual(@as(u128, 0x123456), create2_op.create2.salt);
}

test "CallParams - validation with generic gas types" {
    const EvmConfig = @import("evm_config.zig").EvmConfig;
    const i32_config = EvmConfig{ .block_gas_limit = 1000000 };
    const i64_config = EvmConfig{ .block_gas_limit = 3000000000 };
    
    const CallParamsI32 = CallParams(i32_config);
    const CallParamsI64 = CallParams(i64_config);
    
    // Test zero gas validation with i32
    const zero_gas_i32 = CallParamsI32{ .call = .{
        .caller = primitives.ZERO_ADDRESS,
        .to = [_]u8{1} ++ [_]u8{0} ** 19,
        .value = 0,
        .input = &[_]u8{},
        .gas = 0,
    } };
    try std.testing.expectError(CallParamsI32.ValidationError.GasZeroError, zero_gas_i32.validate());
    
    // Test zero gas validation with i64
    const zero_gas_i64 = CallParamsI64{ .call = .{
        .caller = primitives.ZERO_ADDRESS,
        .to = [_]u8{1} ++ [_]u8{0} ** 19,
        .value = 0,
        .input = &[_]u8{},
        .gas = 0,
    } };
    try std.testing.expectError(CallParamsI64.ValidationError.GasZeroError, zero_gas_i64.validate());
}

test "call params gas access" {
    const EvmConfig = @import("evm_config.zig").EvmConfig;
    const default_config = EvmConfig{};
    const CallParamsType = CallParams(default_config);
    const GasType = default_config.frame_config().GasType();
    
    const caller = primitives.ZERO_ADDRESS;
    const to: [20]u8 = [_]u8{1} ++ [_]u8{0} ** 19;
    const input = &[_]u8{0x42};

    const call_op = CallParamsType{ .call = .{
        .caller = caller,
        .to = to,
        .value = 100,
        .input = input,
        .gas = @as(GasType, 21000),
    } };
    try std.testing.expectEqual(@as(GasType, 21000), call_op.getGas());

    const delegatecall_op = CallParamsType{ .delegatecall = .{
        .caller = caller,
        .to = to,
        .input = input,
        .gas = @as(GasType, 15000),
    } };
    try std.testing.expectEqual(@as(GasType, 15000), delegatecall_op.getGas());
}

test "call params caller access" {
    const EvmConfig = @import("evm_config.zig").EvmConfig;
    const default_config = EvmConfig{};
    const CallParamsType = CallParams(default_config);
    const GasType = default_config.frame_config().GasType();
    
    const caller: [20]u8 = [_]u8{0xaa} ++ [_]u8{0} ** 19;
    const to: [20]u8 = [_]u8{1} ++ [_]u8{0} ** 19;

    const call_op = CallParamsType{ .call = .{
        .caller = caller,
        .to = to,
        .value = 0,
        .input = &.{},
        .gas = @as(GasType, 21000),
    } };
    try std.testing.expectEqual(caller, call_op.getCaller());

    const create_op = CallParamsType{ .create = .{
        .caller = caller,
        .value = 50,
        .init_code = &[_]u8{ 0x60, 0x00, 0x60, 0x00, 0xf3 },
        .gas = @as(GasType, 53000),
    } };
    try std.testing.expectEqual(caller, create_op.getCaller());
}

test "call params input access" {
    const EvmConfig = @import("evm_config.zig").EvmConfig;
    const default_config = EvmConfig{};
    const CallParamsType = CallParams(default_config);
    const GasType = default_config.frame_config().GasType();
    
    const caller = primitives.ZERO_ADDRESS;
    const to: [20]u8 = [_]u8{1} ++ [_]u8{0} ** 19;
    const input_data = &[_]u8{ 0xa9, 0x05, 0x9c, 0xbb }; // transfer(address,uint256) selector

    const call_op = CallParamsType{ .call = .{
        .caller = caller,
        .to = to,
        .value = 0,
        .input = input_data,
        .gas = @as(GasType, 21000),
    } };
    try std.testing.expectEqualSlices(u8, input_data, call_op.getInput());

    const init_code = &[_]u8{ 0x60, 0x80, 0x60, 0x40, 0x52 };
    const create_op = CallParamsType{ .create = .{
        .caller = caller,
        .value = 0,
        .init_code = init_code,
        .gas = @as(GasType, 53000),
    } };
    try std.testing.expectEqualSlices(u8, init_code, create_op.getInput());
}

test "call params has value checks" {
    const caller = primitives.ZERO_ADDRESS;
    const to: Address = [_]u8{1} ++ [_]u8{0} ** 19;
    const input = &[_]u8{};

    // CALL with value
    const call_with_value = CallParams{ .call = .{
        .caller = caller,
        .to = to,
        .value = 1000,
        .input = input,
        .gas = 21000,
    } };
    try std.testing.expect(call_with_value.hasValue());

    // CALL without value
    const call_no_value = CallParams{ .call = .{
        .caller = caller,
        .to = to,
        .value = 0,
        .input = input,
        .gas = 21000,
    } };
    try std.testing.expect(!call_no_value.hasValue());

    // DELEGATECALL never has value
    const delegatecall_op = CallParams{ .delegatecall = .{
        .caller = caller,
        .to = to,
        .input = input,
        .gas = 21000,
    } };
    try std.testing.expect(!delegatecall_op.hasValue());

    // STATICCALL never has value
    const staticcall_op = CallParams{ .staticcall = .{
        .caller = caller,
        .to = to,
        .input = input,
        .gas = 21000,
    } };
    try std.testing.expect(!staticcall_op.hasValue());

    // CREATE with value
    const create_with_value = CallParams{ .create = .{
        .caller = caller,
        .value = 500,
        .init_code = &[_]u8{0x00},
        .gas = 53000,
    } };
    try std.testing.expect(create_with_value.hasValue());
}

test "call params read only checks" {
    const caller = primitives.ZERO_ADDRESS;
    const to: Address = [_]u8{1} ++ [_]u8{0} ** 19;
    const input = &[_]u8{};

    // Only STATICCALL is read-only
    const staticcall_op = CallParams{ .staticcall = .{
        .caller = caller,
        .to = to,
        .input = input,
        .gas = 21000,
    } };
    try std.testing.expect(staticcall_op.isReadOnly());

    // Regular CALL is not read-only
    const call_op = CallParams{ .call = .{
        .caller = caller,
        .to = to,
        .value = 0,
        .input = input,
        .gas = 21000,
    } };
    try std.testing.expect(!call_op.isReadOnly());

    // DELEGATECALL is not read-only
    const delegatecall_op = CallParams{ .delegatecall = .{
        .caller = caller,
        .to = to,
        .input = input,
        .gas = 21000,
    } };
    try std.testing.expect(!delegatecall_op.isReadOnly());
}

test "call params create checks" {
    const caller = primitives.ZERO_ADDRESS;
    const to: Address = [_]u8{1} ++ [_]u8{0} ** 19;
    const init_code = &[_]u8{ 0x60, 0x00, 0x60, 0x00, 0xf3 };

    // CREATE operations
    const create_op = CallParams{ .create = .{
        .caller = caller,
        .value = 0,
        .init_code = init_code,
        .gas = 53000,
    } };
    try std.testing.expect(create_op.isCreate());

    const create2_op = CallParams{ .create2 = .{
        .caller = caller,
        .value = 0,
        .init_code = init_code,
        .salt = 0x123456789abcdef,
        .gas = 53000,
    } };
    try std.testing.expect(create2_op.isCreate());

    // Non-CREATE operations
    const call_op = CallParams{ .call = .{
        .caller = caller,
        .to = to,
        .value = 0,
        .input = &[_]u8{},
        .gas = 21000,
    } };
    try std.testing.expect(!call_op.isCreate());
}

test "call params edge cases" {
    const caller: Address = [_]u8{0xff} ** 20; // Maximum address
    const to: Address = [_]u8{1} ++ [_]u8{0} ** 19;

    // Maximum gas
    const max_gas_call = CallParams{ .call = .{
        .caller = caller,
        .to = to,
        .value = std.math.maxInt(u256),
        .input = &[_]u8{},
        .gas = std.math.maxInt(u64),
    } };
    try std.testing.expectEqual(std.math.maxInt(u64), max_gas_call.getGas());
    try std.testing.expect(max_gas_call.hasValue());

    // CREATE2 with maximum salt
    const create2_max_salt = CallParams{ .create2 = .{
        .caller = caller,
        .value = 0,
        .init_code = &[_]u8{0x00},
        .salt = std.math.maxInt(u256),
        .gas = 100000,
    } };
    try std.testing.expect(create2_max_salt.isCreate());
    try std.testing.expect(!create2_max_salt.hasValue());

    // Empty input data
    const call_empty_input = CallParams{
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
    const to: Address = [_]u8{1} ++ [_]u8{0} ** 19;

    // CALL with zero gas should fail validation
    const call_zero_gas = CallParams{ .call = .{
        .caller = caller,
        .to = to,
        .value = 100,
        .input = &[_]u8{},
        .gas = 0,
    } };
    try std.testing.expectError(CallParams.ValidationError.GasZeroError, call_zero_gas.validate());

    // DELEGATECALL with zero gas should fail validation
    const delegatecall_zero_gas = CallParams{ .delegatecall = .{
        .caller = caller,
        .to = to,
        .input = &[_]u8{},
        .gas = 0,
    } };
    try std.testing.expectError(CallParams.ValidationError.GasZeroError, delegatecall_zero_gas.validate());

    // CREATE with zero gas should fail validation
    const create_zero_gas = CallParams{ .create = .{
        .caller = caller,
        .value = 0,
        .init_code = &[_]u8{0x00},
        .gas = 0,
    } };
    try std.testing.expectError(CallParams.ValidationError.GasZeroError, create_zero_gas.validate());

    // CREATE2 with zero gas should fail validation
    const create2_zero_gas = CallParams{ .create2 = .{
        .caller = caller,
        .value = 0,
        .init_code = &[_]u8{0x00},
        .salt = 0x123,
        .gas = 0,
    } };
    try std.testing.expectError(CallParams.ValidationError.GasZeroError, create2_zero_gas.validate());
}

test "call params validation - non-zero gas success" {
    const caller = primitives.ZERO_ADDRESS;
    const to: Address = [_]u8{1} ++ [_]u8{0} ** 19;

    // All operations with non-zero gas should pass validation
    const operations = [_]CallParams{
        CallParams{ .call = .{
            .caller = caller,
            .to = to,
            .value = 100,
            .input = &[_]u8{},
            .gas = 1,
        } },
        CallParams{ .callcode = .{
            .caller = caller,
            .to = to,
            .value = 100,
            .input = &[_]u8{},
            .gas = 1,
        } },
        CallParams{ .delegatecall = .{
            .caller = caller,
            .to = to,
            .input = &[_]u8{},
            .gas = 1,
        } },
        CallParams{ .staticcall = .{
            .caller = caller,
            .to = to,
            .input = &[_]u8{},
            .gas = 1,
        } },
        CallParams{ .create = .{
            .caller = caller,
            .value = 0,
            .init_code = &[_]u8{0x00},
            .gas = 1,
        } },
        CallParams{ .create2 = .{
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
    const caller: Address = [_]u8{0xaa} ++ [_]u8{0} ** 19;
    const to: Address = [_]u8{0xbb} ++ [_]u8{0} ** 19;
    const input_data = &[_]u8{ 0x12, 0x34, 0x56, 0x78 };

    const callcode_op = CallParams{ .callcode = .{
        .caller = caller,
        .to = to,
        .value = 1000,
        .input = input_data,
        .gas = 25000,
    } };

    try std.testing.expectEqual(@as(u64, 25000), callcode_op.getGas());
    try std.testing.expectEqual(caller, callcode_op.getCaller());
    try std.testing.expectEqualSlices(u8, input_data, callcode_op.getInput());
    try std.testing.expect(callcode_op.hasValue());
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
        const create2_op = CallParams{ .create2 = .{
            .caller = caller,
            .value = 0,
            .init_code = init_code,
            .salt = salt,
            .gas = 32000,
        } };

        try std.testing.expectEqual(@as(u64, 32000), create2_op.getGas());
        try std.testing.expectEqual(caller, create2_op.getCaller());
        try std.testing.expectEqualSlices(u8, init_code, create2_op.getInput());
        try std.testing.expect(!create2_op.hasValue());
        try std.testing.expect(!create2_op.isReadOnly());
        try std.testing.expect(create2_op.isCreate());
    }
}

test "call params large input data" {
    const caller = primitives.ZERO_ADDRESS;
    const to: Address = [_]u8{1} ++ [_]u8{0} ** 19;

    // Test with large input data
    var large_input: [1024]u8 = undefined;
    for (0..1024) |i| {
        large_input[i] = @intCast(i % 256);
    }

    const call_large_input = CallParams{ .call = .{
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
    const max_address: Address = [_]u8{0xFF} ** 20;

    // Test with zero address as caller and target
    const zero_call = CallParams{ .call = .{
        .caller = zero_address,
        .to = zero_address,
        .value = 0,
        .input = &[_]u8{},
        .gas = 21000,
    } };
    try std.testing.expectEqual(zero_address, zero_call.getCaller());

    // Test with max address as caller and target
    const max_call = CallParams{ .call = .{
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
    const to: Address = [_]u8{1} ++ [_]u8{0} ** 19;
    const init_code = &[_]u8{0x00};

    // Test minimum positive value
    const call_min_value = CallParams{ .call = .{
        .caller = caller,
        .to = to,
        .value = 1,
        .input = &[_]u8{},
        .gas = 21000,
    } };
    try std.testing.expect(call_min_value.hasValue());

    // Test maximum value
    const call_max_value = CallParams{ .call = .{
        .caller = caller,
        .to = to,
        .value = std.math.maxInt(u256),
        .input = &[_]u8{},
        .gas = 21000,
    } };
    try std.testing.expect(call_max_value.hasValue());

    // Test CREATE with max value
    const create_max_value = CallParams{ .create = .{
        .caller = caller,
        .value = std.math.maxInt(u256),
        .init_code = init_code,
        .gas = 53000,
    } };
    try std.testing.expect(create_max_value.hasValue());
    try std.testing.expect(create_max_value.isCreate());

    // Test CREATE2 with max value
    const create2_max_value = CallParams{ .create2 = .{
        .caller = caller,
        .value = std.math.maxInt(u256),
        .init_code = init_code,
        .salt = 0x123,
        .gas = 53000,
    } };
    try std.testing.expect(create2_max_value.hasValue());
    try std.testing.expect(create2_max_value.isCreate());
}

test "call params gas limit edge cases" {
    const caller = primitives.ZERO_ADDRESS;
    const to: Address = [_]u8{1} ++ [_]u8{0} ** 19;
    const init_code = &[_]u8{0x00};

    // Test minimum gas (1)
    const call_min_gas = CallParams{ .call = .{
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
        const ops = [_]CallParams{
            CallParams{ .call = .{
                .caller = caller,
                .to = to,
                .value = 0,
                .input = &[_]u8{},
                .gas = gas_val,
            } },
            CallParams{ .delegatecall = .{
                .caller = caller,
                .to = to,
                .input = &[_]u8{},
                .gas = gas_val,
            } },
            CallParams{ .staticcall = .{
                .caller = caller,
                .to = to,
                .input = &[_]u8{},
                .gas = gas_val,
            } },
            CallParams{ .create = .{
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

test "call params all operation types coverage" {
    const caller: Address = [_]u8{0xaa} ++ [_]u8{0} ** 19;
    const to: Address = [_]u8{0xbb} ++ [_]u8{0} ** 19;
    const input_data = &[_]u8{ 0x42, 0x24 };
    const init_code = &[_]u8{ 0x60, 0x00, 0xf3 };

    // Test all operation types exist and work
    const operations = [_]CallParams{
        // CALL
        CallParams{ .call = .{
            .caller = caller,
            .to = to,
            .value = 100,
            .input = input_data,
            .gas = 25000,
        } },
        // CALLCODE
        CallParams{ .callcode = .{
            .caller = caller,
            .to = to,
            .value = 200,
            .input = input_data,
            .gas = 30000,
        } },
        // DELEGATECALL
        CallParams{ .delegatecall = .{
            .caller = caller,
            .to = to,
            .input = input_data,
            .gas = 35000,
        } },
        // STATICCALL
        CallParams{ .staticcall = .{
            .caller = caller,
            .to = to,
            .input = input_data,
            .gas = 40000,
        } },
        // CREATE
        CallParams{ .create = .{
            .caller = caller,
            .value = 500,
            .init_code = init_code,
            .gas = 53000,
        } },
        // CREATE2
        CallParams{ .create2 = .{
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
        _ = op.hasValue();
        _ = op.isReadOnly();
        _ = op.isCreate();
    }
}

test "call params method consistency" {
    const caller: Address = [_]u8{0xaa} ++ [_]u8{0} ** 19;
    const to: Address = [_]u8{0xbb} ++ [_]u8{0} ** 19;
    const input_data = &[_]u8{0x12};

    // Test that delegatecall correctly reports no value transfer
    const delegatecall_op = CallParams{ .delegatecall = .{
        .caller = caller,
        .to = to,
        .input = input_data,
        .gas = 25000,
    } };

    try std.testing.expect(!delegatecall_op.hasValue());
    try std.testing.expect(!delegatecall_op.isReadOnly());
    try std.testing.expect(!delegatecall_op.isCreate());

    // Test that staticcall correctly reports read-only
    const staticcall_op = CallParams{ .staticcall = .{
        .caller = caller,
        .to = to,
        .input = input_data,
        .gas = 25000,
    } };

    try std.testing.expect(!staticcall_op.hasValue());
    try std.testing.expect(staticcall_op.isReadOnly());
    try std.testing.expect(!staticcall_op.isCreate());
}

test "call params input vs init code consistency" {
    const caller = primitives.ZERO_ADDRESS;
    const to: Address = [_]u8{1} ++ [_]u8{0} ** 19;
    const call_input = &[_]u8{ 0xa9, 0x05, 0x9c, 0xbb };
    const init_code = &[_]u8{ 0x60, 0x80, 0x60, 0x40, 0x52 };

    // Regular calls use input field
    const call_op = CallParams{ .call = .{
        .caller = caller,
        .to = to,
        .value = 0,
        .input = call_input,
        .gas = 21000,
    } };
    try std.testing.expectEqualSlices(u8, call_input, call_op.getInput());

    // Create operations use init_code field but return it via getInput()
    const create_op = CallParams{ .create = .{
        .caller = caller,
        .value = 0,
        .init_code = init_code,
        .gas = 53000,
    } };
    try std.testing.expectEqualSlices(u8, init_code, create_op.getInput());
}
