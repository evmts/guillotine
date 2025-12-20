const std = @import("std");
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

        /// Check if this call operation transfers value
        pub fn hasValue(self: @This()) bool {
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

