const std = @import("std");
const log = @import("../log.zig");
const FrameConfig = @import("../frame/frame_config.zig").FrameConfig;
const primitives = @import("primitives");
const Address = primitives.Address;
// Access to call params through the call params module
const call_params_mod = @import("../frame/call_params.zig");
const Opcode = @import("../opcodes/opcode_data.zig").Opcode;
// u256 is now a built-in type in Zig 0.14+

/// System opcode handlers for the EVM stack frame.
/// These handle calls, contract creation, and execution control.
pub fn Handlers(comptime FrameType: type) type {
    return struct {
        pub const Error = FrameType.Error;
        pub const Dispatch = FrameType.Dispatch;
        pub const WordType = FrameType.WordType;

        // Use default configuration for CallParams - this maintains backward compatibility
        const CallParams = call_params_mod.CallParams(.{});

        /// Helper to convert WordType to Address
        fn from_u256(value: WordType) Address {
            // If WordType is smaller than u256, just zero-extend
            const value_u256: u256 = if (@bitSizeOf(WordType) < 256) @as(u256, value) else value;
            // Take the lower 160 bits (20 bytes)
            const addr_value = @as(u160, @truncate(value_u256));
            var addr_bytes: [20]u8 = undefined;
            std.mem.writeInt(u160, &addr_bytes, addr_value, .big);
            return Address{ .bytes = addr_bytes };
        }

        /// Helper to convert Address to WordType
        fn to_u256(addr: Address) WordType {
            const bytes = addr.bytes;
            var value: u256 = 0;
            for (bytes) |byte| {
                value = std.math.shl(u256, value, 8) | @as(u256, byte);
            }
            return @as(WordType, @truncate(value));
        }

        /// CALL opcode (0xf1) - Message-call into an account.
        /// Stack: [gas, address, value, input_offset, input_size, output_offset, output_size] → [success]
        pub fn call(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            const dispatch = Dispatch{ .cursor = cursor };
            // Check static context - CALL with non-zero value is not allowed in static context
            // Stack (top first): [gas, address, value, input_offset, input_size, output_offset, output_size]
            std.debug.assert(self.stack.size() >= 7); // CALL requires 7 stack items
            const gas_param = self.stack.pop_unsafe();
            const address_u256 = self.stack.pop_unsafe();
            const value = self.stack.pop_unsafe();
            const input_offset = self.stack.pop_unsafe();
            const input_size = self.stack.pop_unsafe();
            const output_offset = self.stack.pop_unsafe();
            const output_size = self.stack.pop_unsafe();

            // EIP-214: Static calls with value > 0 will fail in host.inner_call()
            // Data-oriented design: constraint is encoded in host implementation

            // Convert address from u256
            const addr = from_u256(address_u256);

            // Bounds checking for gas parameter
            if (gas_param > std.math.maxInt(u64)) {
                std.debug.assert(self.stack.size() < @TypeOf(self.stack).stack_capacity); // Ensure space for push
                self.stack.push_unsafe(0);
                const op_data = dispatch.getOpData(.CALL);
                // Use op_data.next_handler and op_data.next_cursor directly
                return @call(FrameType.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
            }
            const gas_u64_raw = @as(u64, @intCast(gas_param));
            const caller_gas_available: u64 = @as(u64, @intCast(@max(self.gas_remaining, 0)));
            const max_forwardable: u64 = caller_gas_available - (caller_gas_available / 64);
            const gas_u64 = if (gas_u64_raw < max_forwardable) gas_u64_raw else max_forwardable;

            // Bounds checking for memory offsets and sizes
            if (input_offset > std.math.maxInt(usize) or
                input_size > std.math.maxInt(usize) or
                output_offset > std.math.maxInt(usize) or
                output_size > std.math.maxInt(usize))
            {
                std.debug.assert(self.stack.size() < @TypeOf(self.stack).stack_capacity); // Ensure space for push
                self.stack.push_unsafe(0);
                const op_data = dispatch.getOpData(.CALL);
                // Use op_data.next_handler and op_data.next_cursor directly
                return @call(FrameType.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
            }

            const input_offset_usize = @as(usize, @intCast(input_offset));
            const input_size_usize = @as(usize, @intCast(input_size));
            const output_offset_usize = @as(usize, @intCast(output_offset));
            const output_size_usize = @as(usize, @intCast(output_size));

            // Ensure memory capacity for input
            if (input_size_usize > 0) {
                const input_end = input_offset_usize + input_size_usize;
                self.memory.ensure_capacity(self.getAllocator(), @as(u24, @intCast(input_end))) catch {
                    self.stack.push_unsafe(0);
                    const op_data = dispatch.getOpData(.CALL);
                    // Use op_data.next_handler and op_data.next_cursor directly
                    return @call(FrameType.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
                };
            }

            // Ensure memory capacity for output
            if (output_size_usize > 0) {
                const output_end = output_offset_usize + output_size_usize;
                self.memory.ensure_capacity(self.getAllocator(), @as(u24, @intCast(output_end))) catch {
                    self.stack.push_unsafe(0);
                    const op_data = dispatch.getOpData(.CALL);
                    // Use op_data.next_handler and op_data.next_cursor directly
                    return @call(FrameType.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
                };
            }

            // Extract input data
            var input_data: []const u8 = &.{};
            if (input_size_usize > 0) {
                input_data = self.memory.get_slice(@as(u24, @intCast(input_offset_usize)), @as(u24, @intCast(input_size_usize))) catch {
                    self.stack.push_unsafe(0);
                    const op_data = dispatch.getOpData(.CALL);
                    // Use op_data.next_handler and op_data.next_cursor directly
                    return @call(FrameType.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
                };
            }

            // Perform the call through the host interface
            const params = CallParams{
                .call = .{
                    .caller = self.contract_address,
                    .to = addr,
                    .value = value,
                    .input = input_data,
                    .gas = gas_u64,
                },
            };

            var result = self.getEvm().inner_call(params);
            defer result.deinit(self.getAllocator());

            // Write return data to memory if successful and output size > 0
            if (result.success and output_size_usize > 0 and result.output.len > 0) {
                const copy_size = @min(output_size_usize, result.output.len);
                self.memory.set_data(self.getAllocator(), @as(u24, @intCast(output_offset_usize)), result.output[0..copy_size]) catch {
                    self.stack.push_unsafe(0);
                    const op_data = dispatch.getOpData(.CALL);
                    // Use op_data.next_handler and op_data.next_cursor directly
                    return @call(FrameType.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
                };
            }

            // Store return data for future RETURNDATASIZE/RETURNDATACOPY
            // Free previous output if any
            // No need to free when using arena allocator - it's reset after each call
            // Allocate new output
            self.output = self.getAllocator().alloc(u8, result.output.len) catch {
                return Error.AllocationError;
            };
            @memcpy(self.output, result.output);

            // Update caller gas: subtract only gas actually used by callee
            const provided_gas_call: u64 = gas_u64;
            const used_gas_call: u64 = if (result.gas_left > provided_gas_call) 0 else (provided_gas_call - result.gas_left);
            const caller_gas_call: u64 = @as(u64, @intCast(@max(self.gas_remaining, 0)));
            const new_gas_call: u64 = if (used_gas_call > caller_gas_call) 0 else caller_gas_call - used_gas_call;
            self.gas_remaining = @as(FrameType.GasType, @intCast(new_gas_call));

            // Push success status (1 for success, 0 for failure)
            // log.debug("CALL result.success={}, gas_left={}, output_len={}", .{ result.success, result.gas_left, result.output.len });
            std.debug.assert(self.stack.size() < @TypeOf(self.stack).stack_capacity); // Ensure space for push
            self.stack.push_unsafe(if (result.success) 1 else 0);

            const op_data = dispatch.getOpData(.CALL);
            // Use op_data.next_handler and op_data.next_cursor directly
            return @call(FrameType.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
        }

        /// CALLCODE opcode (0xf2) - Message-call with alternative account's code but current context.
        /// Stack: [gas, address, value, input_offset, input_size, output_offset, output_size] → [success]
        pub fn callcode(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            const dispatch = Dispatch{ .cursor = cursor };
            // Stack (top first): [gas, address, value, input_offset, input_size, output_offset, output_size]
            std.debug.assert(self.stack.size() >= 7); // CALLCODE requires 7 stack items
            const gas_param = self.stack.pop_unsafe();
            const address_u256 = self.stack.pop_unsafe();
            const value = self.stack.pop_unsafe();
            const input_offset = self.stack.pop_unsafe();
            const input_size = self.stack.pop_unsafe();
            const output_offset = self.stack.pop_unsafe();
            const output_size = self.stack.pop_unsafe();

            // Convert address from u256
            const addr = from_u256(address_u256);

            // Bounds checking for gas parameter
            if (gas_param > std.math.maxInt(u64)) {
                std.debug.assert(self.stack.size() < @TypeOf(self.stack).stack_capacity); // Ensure space for push
                self.stack.push_unsafe(0);
                const op_data = dispatch.getOpData(.CALLCODE);
                // Use op_data.next_handler and op_data.next_cursor directly
                return @call(FrameType.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
            }
            const gas_u64_raw = @as(u64, @intCast(gas_param));
            const caller_gas_available_cc: u64 = @as(u64, @intCast(@max(self.gas_remaining, 0)));
            const max_forwardable_cc: u64 = caller_gas_available_cc - (caller_gas_available_cc / 64);
            const gas_u64 = if (gas_u64_raw < max_forwardable_cc) gas_u64_raw else max_forwardable_cc;

            // Bounds checking for memory offsets and sizes
            if (input_offset > std.math.maxInt(usize) or
                input_size > std.math.maxInt(usize) or
                output_offset > std.math.maxInt(usize) or
                output_size > std.math.maxInt(usize))
            {
                self.stack.push_unsafe(0);
                const op_data = dispatch.getOpData(.CALLCODE);
                // Use op_data.next_handler and op_data.next_cursor directly
                return @call(FrameType.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
            }

            const input_offset_usize = @as(usize, @intCast(input_offset));
            const input_size_usize = @as(usize, @intCast(input_size));
            const output_offset_usize = @as(usize, @intCast(output_offset));
            const output_size_usize = @as(usize, @intCast(output_size));

            // Ensure memory capacity for input
            if (input_size_usize > 0) {
                const input_end = input_offset_usize + input_size_usize;
                self.memory.ensure_capacity(self.getAllocator(), @as(u24, @intCast(input_end))) catch {
                    self.stack.push_unsafe(0);
                    const op_data = dispatch.getOpData(.CALLCODE);
                    // Use op_data.next_handler and op_data.next_cursor directly
                    return @call(FrameType.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
                };
            }

            // Ensure memory capacity for output
            if (output_size_usize > 0) {
                const output_end = output_offset_usize + output_size_usize;
                self.memory.ensure_capacity(self.getAllocator(), @as(u24, @intCast(output_end))) catch {
                    self.stack.push_unsafe(0);
                    const op_data = dispatch.getOpData(.CALLCODE);
                    // Use op_data.next_handler and op_data.next_cursor directly
                    return @call(FrameType.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
                };
            }

            // Extract input data
            var input_data: []const u8 = &.{};
            if (input_size_usize > 0) {
                input_data = self.memory.get_slice(@as(u24, @intCast(input_offset_usize)), @as(u24, @intCast(input_size_usize))) catch {
                    self.stack.push_unsafe(0);
                    const op_data = dispatch.getOpData(.CALLCODE);
                    // Use op_data.next_handler and op_data.next_cursor directly
                    return @call(FrameType.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
                };
            }

            // CALLCODE: Execute code from `addr` but in current contract's context
            // This means using current contract's address, storage, and balance
            const call_params = CallParams{
                .callcode = .{
                    .caller = self.contract_address,
                    .to = addr, // Code to execute from this address
                    .value = value, // Value to appear to be sent
                    .input = input_data,
                    .gas = gas_u64,
                },
            };

            var result = self.getEvm().inner_call(call_params);
            defer result.deinit(self.getAllocator());

            // Write return data to memory if successful and output size > 0
            if (result.success and output_size_usize > 0 and result.output.len > 0) {
                const copy_size = @min(output_size_usize, result.output.len);
                self.memory.set_data(self.getAllocator(), @as(u24, @intCast(output_offset_usize)), result.output[0..copy_size]) catch {};
            }

            // Update caller gas: subtract only gas actually used by callee
            const provided_gas_callcode: u64 = gas_u64;
            const used_gas_callcode: u64 = if (result.gas_left > provided_gas_callcode) 0 else (provided_gas_callcode - result.gas_left);
            const caller_gas_callcode: u64 = @as(u64, @intCast(@max(self.gas_remaining, 0)));
            const new_gas_callcode: u64 = if (used_gas_callcode > caller_gas_callcode) 0 else caller_gas_callcode - used_gas_callcode;
            self.gas_remaining = @as(FrameType.GasType, @intCast(new_gas_callcode));

            // Push success (1) or failure (0) onto stack
            // log.debug("CALLCODE result.success={}, gas_left={}, output_len={}", .{ result.success, result.gas_left, result.output.len });
            std.debug.assert(self.stack.size() < @TypeOf(self.stack).stack_capacity); // Ensure space for push
            self.stack.push_unsafe(if (result.success) 1 else 0);

            const op_data = dispatch.getOpData(.CALLCODE);
            // Use op_data.next_handler and op_data.next_cursor directly
            return @call(FrameType.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
        }

        /// DELEGATECALL opcode (0xf4) - Message-call with alternative account's code but current values.
        /// Stack: [gas, address, input_offset, input_size, output_offset, output_size] → [success]
        pub fn delegatecall(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            const dispatch = Dispatch{ .cursor = cursor };
            // Stack (top first): [gas, address, input_offset, input_size, output_offset, output_size]
            std.debug.assert(self.stack.size() >= 6); // DELEGATECALL requires 6 stack items
            const gas_param = self.stack.pop_unsafe();
            const address_u256 = self.stack.pop_unsafe();
            const input_offset = self.stack.pop_unsafe();
            const input_size = self.stack.pop_unsafe();
            const output_offset = self.stack.pop_unsafe();
            const output_size = self.stack.pop_unsafe();

            // Convert address from u256
            const addr = from_u256(address_u256);

            // Bounds checking for gas parameter
            if (gas_param > std.math.maxInt(u64)) {
                self.stack.push_unsafe(0);
                const op_data = dispatch.getOpData(.DELEGATECALL);
                // Use op_data.next_handler and op_data.next_cursor directly
                return @call(FrameType.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
            }
            const gas_u64_raw = @as(u64, @intCast(gas_param));
            const caller_gas_available_dc: u64 = @as(u64, @intCast(@max(self.gas_remaining, 0)));
            const max_forwardable_dc: u64 = caller_gas_available_dc - (caller_gas_available_dc / 64);
            const gas_u64 = if (gas_u64_raw < max_forwardable_dc) gas_u64_raw else max_forwardable_dc;

            // Bounds checking for memory offsets and sizes
            if (input_offset > std.math.maxInt(usize) or
                input_size > std.math.maxInt(usize) or
                output_offset > std.math.maxInt(usize) or
                output_size > std.math.maxInt(usize))
            {
                self.stack.push_unsafe(0);
                const op_data = dispatch.getOpData(.DELEGATECALL);
                // Use op_data.next_handler and op_data.next_cursor directly
                return @call(FrameType.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
            }

            const input_offset_usize = @as(usize, @intCast(input_offset));
            const input_size_usize = @as(usize, @intCast(input_size));
            const output_offset_usize = @as(usize, @intCast(output_offset));
            const output_size_usize = @as(usize, @intCast(output_size));

            // Ensure memory capacity for input
            if (input_size_usize > 0) {
                const input_end = input_offset_usize + input_size_usize;
                self.memory.ensure_capacity(self.getAllocator(), @as(u24, @intCast(input_end))) catch {
                    self.stack.push_unsafe(0);
                    const op_data = dispatch.getOpData(.DELEGATECALL);
                    // Use op_data.next_handler and op_data.next_cursor directly
                    return @call(FrameType.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
                };
            }

            // Ensure memory capacity for output
            if (output_size_usize > 0) {
                const output_end = output_offset_usize + output_size_usize;
                self.memory.ensure_capacity(self.getAllocator(), @as(u24, @intCast(output_end))) catch {
                    self.stack.push_unsafe(0);
                    const op_data = dispatch.getOpData(.DELEGATECALL);
                    // Use op_data.next_handler and op_data.next_cursor directly
                    return @call(FrameType.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
                };
            }

            // Extract input data
            var input_data: []const u8 = &.{};
            if (input_size_usize > 0) {
                input_data = self.memory.get_slice(@as(u24, @intCast(input_offset_usize)), @as(u24, @intCast(input_size_usize))) catch {
                    self.stack.push_unsafe(0);
                    const op_data = dispatch.getOpData(.DELEGATECALL);
                    // Use op_data.next_handler and op_data.next_cursor directly
                    return @call(FrameType.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
                };
            }

            // Perform the delegatecall through the host interface
            // DELEGATECALL preserves caller and value from current context
            const params = CallParams{
                .delegatecall = .{
                    .caller = self.caller, // Preserve original caller, not contract address!
                    .to = addr,
                    .input = input_data,
                    .gas = gas_u64,
                },
            };
            var result = self.getEvm().inner_call(params);
            defer result.deinit(self.getAllocator());

            // Write return data to memory if successful and output size > 0
            if (result.success and output_size_usize > 0 and result.output.len > 0) {
                const copy_size = @min(output_size_usize, result.output.len);
                self.memory.set_data(self.getAllocator(), @as(u24, @intCast(output_offset_usize)), result.output[0..copy_size]) catch {
                    self.stack.push_unsafe(0);
                    const op_data = dispatch.getOpData(.DELEGATECALL);
                    // Use op_data.next_handler and op_data.next_cursor directly
                    return @call(FrameType.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
                };
            }

            // Store return data for future RETURNDATASIZE/RETURNDATACOPY
            // Free previous output if any
            // No need to free when using arena allocator - it's reset after each call
            // Allocate new output
            self.output = self.getAllocator().alloc(u8, result.output.len) catch {
                return Error.AllocationError;
            };
            @memcpy(self.output, result.output);

            // Update caller gas: subtract only gas actually used by callee
            const provided_gas_delegate: u64 = gas_u64;
            const used_gas_delegate: u64 = if (result.gas_left > provided_gas_delegate) 0 else (provided_gas_delegate - result.gas_left);
            const caller_gas_delegate: u64 = @as(u64, @intCast(@max(self.gas_remaining, 0)));
            const new_gas_delegate: u64 = if (used_gas_delegate > caller_gas_delegate) 0 else caller_gas_delegate - used_gas_delegate;
            self.gas_remaining = @as(FrameType.GasType, @intCast(new_gas_delegate));

            // Push success status (1 for success, 0 for failure)
            // log.debug("DELEGATECALL result.success={}, gas_left={}, output_len={}", .{ result.success, result.gas_left, result.output.len });
            std.debug.assert(self.stack.size() < @TypeOf(self.stack).stack_capacity); // Ensure space for push
            self.stack.push_unsafe(if (result.success) 1 else 0);

            const op_data = dispatch.getOpData(.DELEGATECALL);
            // Use op_data.next_handler and op_data.next_cursor directly
            return @call(FrameType.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
        }

        /// STATICCALL opcode (0xfa) - Static message-call (no state changes allowed).
        /// Stack: [gas, address, input_offset, input_size, output_offset, output_size] → [success]
        pub fn staticcall(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            const dispatch = Dispatch{ .cursor = cursor };
            // Stack (top first): [gas, address, input_offset, input_size, output_offset, output_size]
            std.debug.assert(self.stack.size() >= 6); // STATICCALL requires 6 stack items
            const gas_param = self.stack.pop_unsafe();
            const address_u256 = self.stack.pop_unsafe();
            const input_offset = self.stack.pop_unsafe();
            const input_size = self.stack.pop_unsafe();
            const output_offset = self.stack.pop_unsafe();
            const output_size = self.stack.pop_unsafe();

            // Convert address from u256
            const addr = from_u256(address_u256);

            // Bounds checking for gas parameter
            if (gas_param > std.math.maxInt(u64)) {
                self.stack.push_unsafe(0);
                const op_data = dispatch.getOpData(.STATICCALL);
                // Use op_data.next_handler and op_data.next_cursor directly
                return @call(FrameType.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
            }
            const gas_u64_raw = @as(u64, @intCast(gas_param));
            const caller_gas_available_sc: u64 = @as(u64, @intCast(@max(self.gas_remaining, 0)));
            const max_forwardable_sc: u64 = caller_gas_available_sc - (caller_gas_available_sc / 64);
            const gas_u64 = if (gas_u64_raw < max_forwardable_sc) gas_u64_raw else max_forwardable_sc;

            // Bounds checking for memory offsets and sizes
            if (input_offset > std.math.maxInt(usize) or
                input_size > std.math.maxInt(usize) or
                output_offset > std.math.maxInt(usize) or
                output_size > std.math.maxInt(usize))
            {
                self.stack.push_unsafe(0);
                const op_data = dispatch.getOpData(.STATICCALL);
                // Use op_data.next_handler and op_data.next_cursor directly
                return @call(FrameType.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
            }

            const input_offset_usize = @as(usize, @intCast(input_offset));
            const input_size_usize = @as(usize, @intCast(input_size));
            const output_offset_usize = @as(usize, @intCast(output_offset));
            const output_size_usize = @as(usize, @intCast(output_size));

            // Ensure memory capacity for input
            if (input_size_usize > 0) {
                const input_end = input_offset_usize + input_size_usize;
                self.memory.ensure_capacity(self.getAllocator(), @as(u24, @intCast(input_end))) catch {
                    self.stack.push_unsafe(0);
                    const op_data = dispatch.getOpData(.STATICCALL);
                    // Use op_data.next_handler and op_data.next_cursor directly
                    return @call(FrameType.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
                };
            }

            // Ensure memory capacity for output
            if (output_size_usize > 0) {
                const output_end = output_offset_usize + output_size_usize;
                self.memory.ensure_capacity(self.getAllocator(), @as(u24, @intCast(output_end))) catch {
                    self.stack.push_unsafe(0);
                    const op_data = dispatch.getOpData(.STATICCALL);
                    // Use op_data.next_handler and op_data.next_cursor directly
                    return @call(FrameType.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
                };
            }

            // Extract input data
            var input_data: []const u8 = &.{};
            if (input_size_usize > 0) {
                input_data = self.memory.get_slice(@as(u24, @intCast(input_offset_usize)), @as(u24, @intCast(input_size_usize))) catch {
                    self.stack.push_unsafe(0);
                    const op_data = dispatch.getOpData(.STATICCALL);
                    // Use op_data.next_handler and op_data.next_cursor directly
                    return @call(FrameType.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
                };
            }

            // Perform the static call through the host interface
            const params = CallParams{
                .staticcall = .{
                    .caller = self.contract_address,
                    .to = addr,
                    .input = input_data,
                    .gas = gas_u64,
                },
            };
            var result = self.getEvm().inner_call(params);
            defer result.deinit(self.getAllocator());

            // Write return data to memory if successful and output size > 0
            if (result.success and output_size_usize > 0 and result.output.len > 0) {
                const copy_size = @min(output_size_usize, result.output.len);
                self.memory.set_data(self.getAllocator(), @as(u24, @intCast(output_offset_usize)), result.output[0..copy_size]) catch {
                    self.stack.push_unsafe(0);
                    const op_data = dispatch.getOpData(.STATICCALL);
                    // Use op_data.next_handler and op_data.next_cursor directly
                    return @call(FrameType.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
                };
            }

            // Store return data for future RETURNDATASIZE/RETURNDATACOPY
            // Free previous output if any
            // No need to free when using arena allocator - it's reset after each call
            // Allocate new output
            self.output = self.getAllocator().alloc(u8, result.output.len) catch {
                return Error.AllocationError;
            };
            @memcpy(self.output, result.output);

            // Update caller gas: subtract only gas actually used by callee
            const provided_gas_sc: u64 = gas_u64;
            const used_gas_sc: u64 = if (result.gas_left > provided_gas_sc) 0 else (provided_gas_sc - result.gas_left);
            const caller_gas_sc: u64 = @as(u64, @intCast(@max(self.gas_remaining, 0)));
            const new_gas_sc: u64 = if (used_gas_sc > caller_gas_sc) 0 else caller_gas_sc - used_gas_sc;
            self.gas_remaining = @as(FrameType.GasType, @intCast(new_gas_sc));

            // Push success status (1 for success, 0 for failure)
            std.debug.assert(self.stack.size() < @TypeOf(self.stack).stack_capacity); // Ensure space for push
            self.stack.push_unsafe(if (result.success) 1 else 0);

            const op_data = dispatch.getOpData(.STATICCALL);
            // Use op_data.next_handler and op_data.next_cursor directly
            return @call(FrameType.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
        }

        /// CREATE opcode (0xf0) - Create a new account with associated code.
        /// Stack: [value, offset, size] → [address]
        /// EIP-214: CREATE not allowed in static context - handled by host implementation
        pub fn create(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            const dispatch = Dispatch{ .cursor = cursor };
            // EIP-214: Static constraint encoded in host - will throw WriteProtection

            std.debug.assert(self.stack.size() >= 3); // CREATE requires 3 stack items
            const value = self.stack.pop_unsafe();
            const offset = self.stack.pop_unsafe();
            const size = self.stack.pop_unsafe();

            // Bounds checking for memory offset and size
            if (offset > std.math.maxInt(usize) or size > std.math.maxInt(usize)) {
                self.stack.push_unsafe(0);
                const op_data = dispatch.getOpData(.CREATE);
                // Use op_data.next_handler and op_data.next_cursor directly
                return @call(FrameType.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
            }

            const offset_usize = @as(usize, @intCast(offset));
            const size_usize = @as(usize, @intCast(size));

            // Ensure memory capacity
            const memory_end = offset_usize + size_usize;
            self.memory.ensure_capacity(self.getAllocator(), @as(u24, @intCast(memory_end))) catch {
                self.stack.push_unsafe(0);
                const op_data = dispatch.getOpData(.CREATE);
                // Use op_data.next_handler and op_data.next_cursor directly
                return @call(FrameType.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
            };

            // Extract initialization code
            var init_code: []const u8 = &.{};
            if (size_usize > 0) {
                init_code = self.memory.get_slice(@as(u24, @intCast(offset_usize)), @as(u24, @intCast(size_usize))) catch {
                    self.stack.push_unsafe(0);
                    const op_data = dispatch.getOpData(.CREATE);
                    // Use op_data.next_handler and op_data.next_cursor directly
                    return @call(FrameType.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
                };
            }

            // Perform the create through the host interface
            const params = CallParams{
                .create = .{
                    .caller = self.contract_address,
                    .value = value,
                    .init_code = init_code,
                    .gas = @as(u64, @intCast(self.gas_remaining)),
                },
            };
            var result = self.getEvm().inner_call(params);
            defer result.deinit(self.getAllocator());

            // Update gas remaining
            self.gas_remaining = @intCast(result.gas_left);

            // Push created contract address or 0 on failure
            if (result.success and result.created_address != null) {
                std.debug.assert(self.stack.size() < @TypeOf(self.stack).stack_capacity); // Ensure space for push
                self.stack.push_unsafe(to_u256(result.created_address.?));
            } else {
                std.debug.assert(self.stack.size() < @TypeOf(self.stack).stack_capacity); // Ensure space for push
                self.stack.push_unsafe(0);
            }

            const op_data = dispatch.getOpData(.CREATE);
            // Use op_data.next_handler and op_data.next_cursor directly
            return @call(FrameType.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
        }

        /// CREATE2 opcode (0xf5) - Create a new account with deterministic address.
        /// Stack: [value, offset, size, salt] → [address]
        /// EIP-214: CREATE2 not allowed in static context - handled by host implementation
        pub fn create2(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            const dispatch = Dispatch{ .cursor = cursor };
            // EIP-214: Static constraint encoded in host - will throw WriteProtection

            // EVM pop order: value, offset, size, salt (top first)
            std.debug.assert(self.stack.size() >= 4); // CREATE2 requires 4 stack items
            const value = self.stack.pop_unsafe();
            const offset = self.stack.pop_unsafe();
            const size = self.stack.pop_unsafe();
            const salt = self.stack.pop_unsafe();

            // Bounds checking for memory offset and size
            if (offset > std.math.maxInt(usize) or size > std.math.maxInt(usize)) {
                self.stack.push_unsafe(0);
                const op_data = dispatch.getOpData(.CREATE2);
                // Use op_data.next_handler and op_data.next_cursor directly
                return @call(FrameType.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
            }

            const offset_usize = @as(usize, @intCast(offset));
            const size_usize = @as(usize, @intCast(size));

            // Ensure memory capacity
            const memory_end = offset_usize + size_usize;
            self.memory.ensure_capacity(self.getAllocator(), @as(u24, @intCast(memory_end))) catch {
                self.stack.push_unsafe(0);
                const op_data = dispatch.getOpData(.CREATE2);
                // Use op_data.next_handler and op_data.next_cursor directly
                return @call(FrameType.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
            };

            // Extract initialization code
            var init_code: []const u8 = &.{};
            if (size_usize > 0) {
                init_code = self.memory.get_slice(@as(u24, @intCast(offset_usize)), @as(u24, @intCast(size_usize))) catch {
                    self.stack.push_unsafe(0);
                    const op_data = dispatch.getOpData(.CREATE2);
                    // Use op_data.next_handler and op_data.next_cursor directly
                    return @call(FrameType.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
                };
            }

            // Convert salt to u256 if needed
            const salt_u256: u256 = if (@bitSizeOf(WordType) < 256) @as(u256, salt) else salt;

            // Perform the create2 through the host interface
            const params = CallParams{
                .create2 = .{
                    .caller = self.contract_address,
                    .value = value,
                    .init_code = init_code,
                    .salt = salt_u256,
                    .gas = @as(u64, @intCast(self.gas_remaining)),
                },
            };
            var result = self.getEvm().inner_call(params);
            defer result.deinit(self.getAllocator());

            // Update gas remaining
            self.gas_remaining = @intCast(result.gas_left);

            // Push created contract address or 0 on failure
            if (result.success and result.created_address != null) {
                std.debug.assert(self.stack.size() < @TypeOf(self.stack).stack_capacity); // Ensure space for push
                self.stack.push_unsafe(to_u256(result.created_address.?));
            } else {
                std.debug.assert(self.stack.size() < @TypeOf(self.stack).stack_capacity); // Ensure space for push
                self.stack.push_unsafe(0);
            }

            const op_data = dispatch.getOpData(.CREATE2);
            // Use op_data.next_handler and op_data.next_cursor directly
            return @call(FrameType.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
        }

        /// RETURN opcode (0xf3) - Halt execution returning output data.
        /// Stack: [offset, size] → []
        pub fn @"return"(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            const dispatch = Dispatch{ .cursor = cursor };
            _ = dispatch;

            if (self.stack.size() < 2) {
                return Error.StackUnderflow;
            }
            std.debug.assert(self.stack.size() >= 2); // RETURN requires 2 stack items
            const offset = self.stack.pop_unsafe(); // Top of stack
            const size = self.stack.pop_unsafe(); // Second from top

            // Bounds checking for memory offset and size
            if (offset > std.math.maxInt(usize) or size > std.math.maxInt(usize)) {
                return Error.OutOfBounds;
            }

            const offset_usize = @as(usize, @intCast(offset));
            const size_usize = @as(usize, @intCast(size));

            // Calculate gas cost for memory expansion
            const memory_end = offset_usize + size_usize;
            const memory_expansion_cost = self.memory.get_expansion_cost(@as(u24, @intCast(memory_end)));
            // Use negative gas pattern for single-branch out-of-gas detection
            self.gas_remaining -= @intCast(memory_expansion_cost);
            if (self.gas_remaining < 0) {
                return Error.OutOfGas;
            }

            // Ensure memory capacity
            self.memory.ensure_capacity(self.getAllocator(), @as(u24, @intCast(memory_end))) catch return Error.OutOfBounds;

            // Extract return data from memory and store it
            if (size_usize > 0) {
                const return_data = self.memory.get_slice(@as(u24, @intCast(offset_usize)), @as(u24, @intCast(size_usize))) catch {
                    return Error.OutOfBounds;
                };
                // Inline setOutput logic: free existing output if any
                // No need to free when using arena allocator - it's reset after each call
                // Set new output
                const new_output = self.getAllocator().alloc(u8, return_data.len) catch {
                    return Error.AllocationError;
                };
                @memcpy(new_output, return_data);
                self.output = new_output;
            } else {
                // Empty return data - inline setOutput logic
                // No need to free when using arena allocator - it's reset after each call
                self.output = &.{};
            }

            // Return indicates successful execution
            return Error.Return;
        }

        /// REVERT opcode (0xfd) - Halt execution reverting state changes.
        /// Stack: [offset, size] → []
        pub fn revert(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            const dispatch = Dispatch{ .cursor = cursor };
            _ = dispatch;
            std.debug.assert(self.stack.size() >= 2); // REVERT requires 2 stack items
            const size = self.stack.pop_unsafe(); // Top of stack
            const offset = self.stack.pop_unsafe(); // Second from top

            // Bounds checking for memory offset and size
            if (offset > std.math.maxInt(usize) or size > std.math.maxInt(usize)) {
                return Error.OutOfBounds;
            }

            const offset_usize = @as(usize, @intCast(offset));
            const size_usize = @as(usize, @intCast(size));

            // Calculate gas cost for memory expansion
            const memory_end = offset_usize + size_usize;
            const memory_expansion_cost = self.memory.get_expansion_cost(@as(u24, @intCast(memory_end)));
            // Use negative gas pattern for single-branch out-of-gas detection
            self.gas_remaining -= @intCast(memory_expansion_cost);
            if (self.gas_remaining < 0) {
                return Error.OutOfGas;
            }

            // Ensure memory capacity
            self.memory.ensure_capacity(self.getAllocator(), @as(u24, @intCast(memory_end))) catch return Error.OutOfBounds;

            // Extract revert data from memory and store it
            if (size_usize > 0) {
                const revert_data = self.memory.get_slice(@as(u24, @intCast(offset_usize)), @as(u24, @intCast(size_usize))) catch {
                    return Error.OutOfBounds;
                };
                // Free previous output if any
                // No need to free when using arena allocator - it's reset after each call
                // Store the revert data
                self.output = self.getAllocator().alloc(u8, revert_data.len) catch {
                    return Error.AllocationError;
                };
                @memcpy(self.output, revert_data);
            } else {
                // Empty revert data
                // No need to free when using arena allocator - it's reset after each call
                self.output = &[_]u8{};
            }

            // Reduce log noise: no verbose REVERT logging

            // Always return REVERT error for proper handling
            return Error.REVERT;
        }

        /// SELFDESTRUCT opcode (0xff) - Halt execution and mark account for later deletion.
        /// Stack: [recipient] → []
        /// EIP-214: STATICCALL prevents SELFDESTRUCT via null self_destruct and static host
        pub fn selfdestruct(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            _ = cursor;
            std.debug.assert(self.stack.size() >= 1); // SELFDESTRUCT requires 1 stack item
            const recipient_u256 = self.stack.pop_unsafe();
            const recipient = from_u256(recipient_u256);
            self.getEvm().mark_for_destruction(self.contract_address, recipient) catch |err| switch (err) {
                error.StaticCallViolation => return Error.WriteProtection,
                else => {
                    @branchHint(.unlikely);
                    log.debug("SELFDESTRUCT failed with error: {}", .{err});
                    return Error.OutOfGas;
                },
            };
            // According to EIP-6780 (Cancun hardfork), SELFDESTRUCT only actually destroys
            // the contract if it was created in the same transaction. This is handled by the host.
            // SELFDESTRUCT always stops execution
            return Error.SelfDestruct;
        }

        /// STOP opcode (0x00) - Halt execution.
        /// Stack: [] → []
        pub fn stop(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            _ = self;
            _ = cursor;

            // EIP-3529 gas refund is applied at the transaction level in evm.zig,
            // not within individual frames. The frame just stops execution.

            return Error.Stop;
        }

        /// AUTH opcode (0xf6) - EIP-3074: Authorize a trusted invoker
        /// Stack: [authority, commitment, sig_v, sig_r, sig_s] → [success]
        pub fn auth(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            const dispatch = Dispatch{ .cursor = cursor };

            // Pop authorization parameters from stack
            std.debug.assert(self.stack.size() >= 5); // AUTH requires 5 stack items
            const sig_s = self.stack.pop_unsafe();
            const sig_r = self.stack.pop_unsafe();
            const sig_v = self.stack.pop_unsafe();
            const commitment = self.stack.pop_unsafe();
            const authority_u256 = self.stack.pop_unsafe();

            // Convert authority to address
            const authority = from_u256(authority_u256);

            // Validate signature components
            if (sig_v > 28 or sig_r == 0 or sig_s == 0) {
                // Invalid signature, push failure
                self.stack.push_unsafe(0);
                const op_data = dispatch.getOpData(.AUTH);
                // Use op_data.next_handler and op_data.next_cursor directly
                return @call(FrameType.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
            }

            // Create authorization message
            // Format: keccak256(0x04 || chainId || nonce || invokerAddress || commitment)
            var message: [1 + 32 + 32 + 20 + 32]u8 = undefined;
            message[0] = 0x04; // AUTH magic byte

            // Get chain ID and nonce from context
            const evm = self.getEvm();
            const chain_id = evm.get_chain_id();
            const nonce = evm.database.get_account(authority.bytes) catch {
                self.stack.push_unsafe(0);
                const op_data = dispatch.getOpData(.AUTH);
                // Use op_data.next_handler and op_data.next_cursor directly
                return @call(FrameType.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
            } orelse {
                self.stack.push_unsafe(0);
                const op_data = dispatch.getOpData(.AUTH);
                // Use op_data.next_handler and op_data.next_cursor directly
                return @call(FrameType.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
            };

            // Encode chain ID (32 bytes, big-endian)
            std.mem.writeInt(u256, message[1..33], chain_id, .big);
            // Encode nonce (32 bytes, big-endian)
            std.mem.writeInt(u256, message[33..65], nonce.nonce, .big);
            // Encode invoker address (20 bytes)
            @memcpy(message[65..85], &self.contract_address.bytes);
            // Encode commitment (32 bytes)
            if (@bitSizeOf(WordType) < 256) {
                std.mem.writeInt(u256, message[85..117], @as(u256, commitment), .big);
            } else {
                std.mem.writeInt(u256, message[85..117], commitment, .big);
            }

            // Compute message hash
            const crypto = @import("crypto");
            const message_hash = crypto.Hash.keccak256(&message);

            // Verify signature
            const recovery_id = @as(u8, @intCast(sig_v - 27));

            const recovered = crypto.secp256k1.unaudited_recover_address(&message_hash, recovery_id, sig_r, sig_s) catch {
                self.stack.push_unsafe(0);
                const op_data = dispatch.getOpData(.AUTHCALL);
                // Use op_data.next_handler and op_data.next_cursor directly
                return @call(FrameType.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
            };

            // Check if recovered address matches authority
            if (!std.mem.eql(u8, &recovered.bytes, &authority.bytes)) {
                self.stack.push_unsafe(0);
                const op_data = dispatch.getOpData(.AUTHCALL);
                // Use op_data.next_handler and op_data.next_cursor directly
                return @call(FrameType.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
            }

            // Store authorized context in frame
            self.authorized_address = authority;

            // Push success
            std.debug.assert(self.stack.size() < @TypeOf(self.stack).stack_capacity); // Ensure space for push
            self.stack.push_unsafe(1);
            const op_data = dispatch.getOpData(.AUTHCALL);
            // Use op_data.next_handler and op_data.next_cursor directly
            return @call(FrameType.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
        }

        /// AUTHCALL opcode (0xf7) - EIP-3074: Make a call as an authorized address
        /// Stack: [gas, to, value, input_offset, input_size, output_offset, output_size, auth] → [success]
        pub fn authcall(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            const dispatch = Dispatch{ .cursor = cursor };

            // Pop call parameters from stack
            std.debug.assert(self.stack.size() >= 8); // AUTHCALL requires 8 stack items
            const auth_flag = self.stack.pop_unsafe();
            const output_size = self.stack.pop_unsafe();
            const output_offset = self.stack.pop_unsafe();
            const input_size = self.stack.pop_unsafe();
            const input_offset = self.stack.pop_unsafe();
            const value = self.stack.pop_unsafe();
            const to_address = self.stack.pop_unsafe();
            const gas_param = self.stack.pop_unsafe();

            // Check if we have an authorized context (auth_flag must be 1)
            if (auth_flag != 1 or self.authorized_address == null) {
                // No authorization, push failure
                self.stack.push_unsafe(0);
                const op_data = dispatch.getOpData(.AUTHCALL);
                // Use op_data.next_handler and op_data.next_cursor directly
                return @call(FrameType.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
            }

            // Convert to address
            const to_addr = from_u256(to_address);

            // Bounds checking for gas parameter
            if (gas_param > std.math.maxInt(u64)) {
                self.stack.push_unsafe(0);
                const op_data = dispatch.getOpData(.AUTHCALL);
                // Use op_data.next_handler and op_data.next_cursor directly
                return @call(FrameType.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
            }
            const gas_u64 = @as(u64, @intCast(gas_param));

            // Bounds checking for memory offsets and sizes
            if (input_offset > std.math.maxInt(usize) or
                input_size > std.math.maxInt(usize) or
                output_offset > std.math.maxInt(usize) or
                output_size > std.math.maxInt(usize))
            {
                self.stack.push_unsafe(0);
                const op_data = dispatch.getOpData(.AUTHCALL);
                // Use op_data.next_handler and op_data.next_cursor directly
                return @call(FrameType.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
            }

            const input_offset_usize = @as(usize, @intCast(input_offset));
            const input_size_usize = @as(usize, @intCast(input_size));
            const output_offset_usize = @as(usize, @intCast(output_offset));
            const output_size_usize = @as(usize, @intCast(output_size));

            // Ensure memory capacity for input
            if (input_size_usize > 0) {
                const input_end = input_offset_usize + input_size_usize;
                self.memory.ensure_capacity(self.getAllocator(), @as(u24, @intCast(input_end))) catch {
                    self.stack.push_unsafe(0);
                    const op_data = dispatch.getOpData(.AUTHCALL);
                    // Use op_data.next_handler and op_data.next_cursor directly
                    return @call(FrameType.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
                };
            }

            // Ensure memory capacity for output
            if (output_size_usize > 0) {
                const output_end = output_offset_usize + output_size_usize;
                self.memory.ensure_capacity(self.getAllocator(), @as(u24, @intCast(output_end))) catch {
                    self.stack.push_unsafe(0);
                    const op_data = dispatch.getOpData(.AUTHCALL);
                    // Use op_data.next_handler and op_data.next_cursor directly
                    return @call(FrameType.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
                };
            }

            // Extract input data
            var input_data: []const u8 = &.{};
            if (input_size_usize > 0) {
                input_data = self.memory.get_slice(@as(u24, @intCast(input_offset_usize)), @as(u24, @intCast(input_size_usize))) catch {
                    self.stack.push_unsafe(0);
                    const op_data = dispatch.getOpData(.AUTHCALL);
                    // Use op_data.next_handler and op_data.next_cursor directly
                    return @call(FrameType.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
                };
            }

            // Perform the authorized call through the host interface
            // The call is made with the authorized address as the caller
            const params = CallParams{
                .call = .{
                    .caller = self.authorized_address.?,
                    .to = to_addr,
                    .value = value,
                    .input = input_data,
                    .gas = gas_u64,
                },
            };

            var result = self.getEvm().inner_call(params);
            defer result.deinit(self.getAllocator());

            // Write return data to memory if successful and output size > 0
            if (result.success and output_size_usize > 0 and result.output.len > 0) {
                const copy_size = @min(output_size_usize, result.output.len);
                self.memory.set_data(self.getAllocator(), @as(u24, @intCast(output_offset_usize)), result.output[0..copy_size]) catch {
                    self.stack.push_unsafe(0);
                    const op_data = dispatch.getOpData(.AUTHCALL);
                    // Use op_data.next_handler and op_data.next_cursor directly
                    return @call(FrameType.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
                };
            }

            // Store return data for future RETURNDATASIZE/RETURNDATACOPY
            // No need to free when using arena allocator - it's reset after each call
            self.output = self.getAllocator().alloc(u8, result.output.len) catch {
                return Error.AllocationError;
            };
            @memcpy(self.output, result.output);

            // Update gas remaining
            self.gas_remaining = @as(@TypeOf(self.gas_remaining), @intCast(result.gas_left));

            // Push success status
            std.debug.assert(self.stack.size() < @TypeOf(self.stack).stack_capacity); // Ensure space for push
            self.stack.push_unsafe(if (result.success) 1 else 0);
            const op_data = dispatch.getOpData(.AUTHCALL);
            // Use op_data.next_handler and op_data.next_cursor directly
            return @call(FrameType.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
        }
    };
}

// ====== TESTS ======

const testing = std.testing;
const Frame = @import("../frame/frame.zig").Frame;
const dispatch_mod = @import("../preprocessor/dispatch.zig");
const NoOpTracer = @import("../tracer/tracer.zig").NoOpTracer;
// const host_mod = @import("host.zig");

// Test configuration
const test_config = FrameConfig{
    .stack_size = 1024,
    .WordType = u256,
    .max_bytecode_size = 1024,
    .block_gas_limit = 30_000_000,
    .DatabaseType = @import("../storage/memory_database.zig").MemoryDatabase,
    .TracerType = NoOpTracer,
    .memory_initial_capacity = 4096,
    .memory_limit = 0xFFFFFF,
};

const TestFrame = Frame(test_config);

// Mock host for testing
const MockEvm = struct {
    allocator: std.mem.Allocator,
    is_static: bool = false,
    call_result: call_params_mod.CallResult,
    create_result: call_params_mod.CreateResult,

    pub fn init(allocator: std.mem.Allocator) MockEvm {
        return .{
            .allocator = allocator,
            .call_result = .{
                .success = true,
                .gas_left = 100_000,
                .output = &.{},
            },
            .create_result = .{
                .success = true,
                .gas_left = 100_000,
                .created_address = primitives.ZERO_ADDRESS,
            },
        };
    }

    pub fn get_is_static(self: *const MockEvm) bool {
        return self.is_static;
    }

    pub fn inner_call(self: *MockEvm, params: call_params_mod.CallParams) !call_params_mod.CallResult {
        _ = params;
        return self.call_result;
    }

    pub fn mark_for_destruction(self: *MockEvm, _: Address, _: Address) !void {
        _ = self;
    }

    // TODO: Update to work without Host
    // pub fn to_host(self: *MockEvm) host_mod.Host {
    //     return .{
    //         .ptr = self,
    //         .vtable = &.{
    //             .get_is_static = @ptrCast(&get_is_static),
    //             .call = @ptrCast(&call),
    //             .delegatecall = @ptrCast(&delegatecall),
    //             .create = @ptrCast(&create),
    //             .mark_for_destruction = @ptrCast(&mark_for_destruction),
    //             // Add other required vtable entries...
    //         },
    //     };
    // }
};

fn createTestFrame(allocator: std.mem.Allocator, evm: ?*MockEvm) !TestFrame {
    const database = try @import("../storage/memory_database.zig").MemoryDatabase.init(allocator);
    const value = try allocator.create(u256);
    value.* = 0;
    const evm_ptr = if (evm) |e| @as(*anyopaque, @ptrCast(e)) else @as(*anyopaque, @ptrFromInt(0x1000)); // Use a dummy pointer for tests without EVM
    var frame = try TestFrame.init(allocator, 1_000_000, database, Address.ZERO_ADDRESS, value, &[_]u8{}, evm_ptr);
    frame.code = &[_]u8{};
    return frame;
}

// Mock dispatch that simulates successful execution flow
fn createMockDispatch() TestFrame.Dispatch {
    const mock_handler = struct {
        fn handler(frame: TestFrame, dispatch: TestFrame.Dispatch) TestFrame.Error!TestFrame.Success {
            _ = frame;
            _ = dispatch;
            return TestFrame.Success.stop;
        }
    }.handler;

    var cursor: [1]dispatch_mod.ScheduleElement(TestFrame) = undefined;
    cursor[0] = .{ .opcode_handler = &mock_handler };

    return TestFrame.Dispatch{
        .cursor = &cursor,
        .bytecode_length = 0,
    };
}

test "STOP opcode" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    const dispatch = createMockDispatch();
    const result = try TestFrame.SystemHandlers.stop(frame, dispatch);
    try testing.expectEqual(TestFrame.Success.Stop, result);
}

test "RETURN opcode - empty return" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: return with offset=0, size=0
    try frame.stack.push(0); // offset
    try frame.stack.push(0); // size

    const dispatch = createMockDispatch();
    const result = try TestFrame.SystemHandlers.@"return"(frame, dispatch);

    try testing.expectEqual(TestFrame.Success.Return, result);
    try testing.expectEqual(@as(usize, 0), frame.output.len);
}

test "RETURN opcode - with data" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Write some data to memory
    const test_data = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
    try frame.memory.set_data(frame.allocator, 0, &test_data);

    // Test: return 4 bytes from offset 0
    try frame.stack.push(0); // offset
    try frame.stack.push(4); // size

    const dispatch = createMockDispatch();
    const result = try TestFrame.SystemHandlers.@"return"(&frame, dispatch);

    try testing.expectEqual(TestFrame.Success.Return, result);
    try testing.expectEqualSlices(u8, &test_data, frame.output);
}

test "RETURN opcode - 32 bytes with 0x42" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Store 0x42 at offset 0 (as a u256)
    const value: u256 = 0x42;
    frame.memory.set_u256_evm(frame.allocator, 0, value) catch |err| {
        return err;
    };

    // Read back the value to verify it was stored
    _ = frame.memory.get_u256_evm(frame.allocator, 0) catch |err| {
        return err;
    };

    // Test: return 32 bytes from offset 0
    try frame.stack.push(0); // offset
    try frame.stack.push(32); // size

    const dispatch = createMockDispatch();
    const result = try TestFrame.SystemHandlers.@"return"(&frame, dispatch);

    try testing.expectEqual(TestFrame.Success.Return, result);
    try testing.expectEqual(@as(usize, 32), frame.output.len);

    // Expected: 32 bytes with 0x42 in the last position (big-endian)
    var expected = [_]u8{0} ** 32;
    expected[31] = 0x42;
    try testing.expectEqualSlices(u8, &expected, frame.output);
}

test "REVERT opcode - empty revert" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test: revert with offset=0, size=0
    try frame.stack.push(0); // offset
    try frame.stack.push(0); // size

    const dispatch = createMockDispatch();
    const result = try TestFrame.SystemHandlers.revert(frame, dispatch);

    try testing.expectEqual(TestFrame.Success.Revert, result);
    try testing.expectEqual(@as(usize, 0), frame.output.len);
}

test "REVERT opcode - with error data" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Write error message to memory
    const error_msg = "Error: Insufficient balance";
    try frame.memory.set_data(frame.allocator, 0, error_msg);

    // Test: revert with error message
    try frame.stack.push(0); // offset
    try frame.stack.push(error_msg.len); // size

    const dispatch = createMockDispatch();
    const result = try TestFrame.SystemHandlers.revert(frame, dispatch);

    try testing.expectEqual(TestFrame.Success.Revert, result);
    try testing.expectEqualSlices(u8, error_msg, frame.output);
}

test "SELFDESTRUCT opcode - normal execution" {
    var evm = MockEvm.init(testing.allocator);
    var frame = try createTestFrame(testing.allocator, &evm);
    defer frame.deinit(testing.allocator);

    // Test: selfdestruct sending balance to address 0x1234...
    const recipient = @as(u256, 0x1234);
    try frame.stack.push(recipient);

    const dispatch = createMockDispatch();
    const result = try TestFrame.SystemHandlers.selfdestruct(frame, dispatch);

    try testing.expectEqual(TestFrame.Success.SelfDestruct, result);
}

test "SELFDESTRUCT opcode - static context error" {
    var evm = MockEvm.init(testing.allocator);
    evm.is_static = true;
    var frame = try createTestFrame(testing.allocator, &evm);
    defer frame.deinit(testing.allocator);

    // Test: selfdestruct in static context should fail
    const recipient = @as(u256, 0x1234);
    try frame.stack.push(recipient);

    const dispatch = createMockDispatch();
    const result = TestFrame.SystemHandlers.selfdestruct(frame, dispatch);

    try testing.expectError(TestFrame.Error.WriteProtection, result);
}

// Note: Full tests for CALL, DELEGATECALL, STATICCALL, CREATE, and CREATE2
// would require more complete host mocking. The structure is provided
// for basic validation.

test "CALL opcode - basic structure" {
    var evm = MockEvm.init(testing.allocator);
    var frame = try createTestFrame(testing.allocator, &evm);
    defer frame.deinit(testing.allocator);

    // Stack: [gas, address, value, input_offset, input_size, output_offset, output_size]
    try frame.stack.push(100000); // gas
    try frame.stack.push(0x1234); // address
    try frame.stack.push(0); // value
    try frame.stack.push(0); // input_offset
    try frame.stack.push(0); // input_size
    try frame.stack.push(0); // output_offset
    try frame.stack.push(0); // output_size

    const dispatch = createMockDispatch();
    const result = try TestFrame.SystemHandlers.call(frame, dispatch);

    try testing.expect(result == TestFrame.Success.stop);
    try testing.expectEqual(@as(u256, 1), try frame.stack.pop()); // success = 1
}

test "CREATE opcode - static context error" {
    var evm = MockEvm.init(testing.allocator);
    evm.is_static = true;
    var frame = try createTestFrame(testing.allocator, &evm);
    defer frame.deinit(testing.allocator);

    // Stack: [value, offset, size]
    try frame.stack.push(0); // value
    try frame.stack.push(0); // offset
    try frame.stack.push(0); // size

    const dispatch = createMockDispatch();
    const result = TestFrame.SystemHandlers.create(frame, dispatch);

    try testing.expectError(TestFrame.Error.WriteProtection, result);
}

// ====== COMPREHENSIVE TESTS ======

// RETURN opcode tests
test "RETURN opcode - large data" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Write 1KB of data
    const data_size = 1024;
    const test_data = try testing.allocator.alloc(u8, data_size);
    defer testing.allocator.free(test_data);
    for (test_data, 0..) |*byte, i| {
        byte.* = @truncate(i);
    }
    try frame.memory.set_data(frame.allocator, 0, test_data);

    try frame.stack.push(0); // offset
    try frame.stack.push(data_size); // size

    const dispatch = createMockDispatch();
    const result = try TestFrame.SystemHandlers.@"return"(frame, dispatch);

    try testing.expectEqual(TestFrame.Success.Return, result);
    try testing.expectEqualSlices(u8, test_data, frame.output);
}

test "RETURN opcode - offset at memory boundary" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Write data at different offsets
    const test_data = [_]u8{ 0xAA, 0xBB, 0xCC, 0xDD };
    const offset = 100;
    try frame.memory.set_data(testing.allocator, @as(u24, @intCast(offset)), &test_data);

    try frame.stack.push(offset); // offset
    try frame.stack.push(test_data.len); // size

    const dispatch = createMockDispatch();
    const result = try TestFrame.SystemHandlers.@"return"(frame, dispatch);

    try testing.expectEqual(TestFrame.Success.Return, result);
    try testing.expectEqualSlices(u8, &test_data, frame.output);
}

test "RETURN opcode - out of bounds offset" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Try to return from way out of bounds
    try frame.stack.push(std.math.maxInt(u256)); // huge offset
    try frame.stack.push(32); // size

    const dispatch = createMockDispatch();
    const result = TestFrame.SystemHandlers.@"return"(frame, dispatch);

    try testing.expectError(TestFrame.Error.OutOfBounds, result);
}

test "RETURN opcode - out of bounds size" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    try frame.stack.push(0); // offset
    try frame.stack.push(std.math.maxInt(u256)); // huge size

    const dispatch = createMockDispatch();
    const result = TestFrame.SystemHandlers.@"return"(frame, dispatch);

    try testing.expectError(TestFrame.Error.OutOfBounds, result);
}

test "RETURN opcode - memory expansion" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Return from uninitialized memory (should expand and return zeros)
    const offset = 10000;
    const size = 32;

    try frame.stack.push(offset); // offset
    try frame.stack.push(size); // size

    const dispatch = createMockDispatch();
    const result = try TestFrame.SystemHandlers.@"return"(frame, dispatch);

    try testing.expectEqual(TestFrame.Success.Return, result);
    try testing.expectEqual(@as(usize, size), frame.output.len);
    // Should be all zeros
    for (frame.output) |byte| {
        try testing.expectEqual(@as(u8, 0), byte);
    }
}

// REVERT opcode tests
test "REVERT opcode - patterns" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Test common error patterns
    const patterns = [_][]const u8{
        "Error",
        "Panic(uint256)",
        "InsufficientBalance()",
        &[_]u8{ 0x08, 0xc3, 0x79, 0xa0 }, // Solidity error selector
    };

    for (patterns) |pattern| {
        if (frame.output.len > 0) {
            frame.allocator.free(frame.output);
        }
        frame.output = &[_]u8{};
        try frame.memory.set_data(frame.allocator, 0, pattern);

        try frame.stack.push(0); // offset
        try frame.stack.push(pattern.len); // size

        const dispatch = createMockDispatch();
        const result = try TestFrame.SystemHandlers.revert(frame, dispatch);

        try testing.expectEqual(TestFrame.Success.Revert, result);
        try testing.expectEqualSlices(u8, pattern, frame.output);
    }
}

test "REVERT opcode - max size revert data" {
    var frame = try createTestFrame(testing.allocator);
    defer frame.deinit(testing.allocator);

    // Create max reasonable revert data (e.g., 10KB)
    const max_size = 10240;
    const revert_data = try testing.allocator.alloc(u8, max_size);
    defer testing.allocator.free(revert_data);
    @memset(revert_data, 0xFF);

    try frame.memory.set_data(frame.allocator, 0, revert_data);

    try frame.stack.push(0); // offset
    try frame.stack.push(max_size); // size

    const dispatch = createMockDispatch();
    const result = try TestFrame.SystemHandlers.revert(frame, dispatch);

    try testing.expectEqual(TestFrame.Success.Revert, result);
    try testing.expectEqualSlices(u8, revert_data, frame.output);
}

// SELFDESTRUCT opcode tests
test "SELFDESTRUCT opcode - to self" {
    var evm = MockEvm.init(testing.allocator);
    var frame = try createTestFrame(testing.allocator, &evm);
    defer frame.deinit(testing.allocator);

    // Self-destruct to self (edge case)
    const self_addr = TestFrame.SystemHandlers.to_u256(frame.contract_address);
    try frame.stack.push(self_addr);

    const dispatch = createMockDispatch();
    const result = try TestFrame.SystemHandlers.selfdestruct(frame, dispatch);

    try testing.expectEqual(TestFrame.Success.SelfDestruct, result);
}

test "SELFDESTRUCT opcode - to max address" {
    var evm = MockEvm.init(testing.allocator);
    var frame = try createTestFrame(testing.allocator, &evm);
    defer frame.deinit(testing.allocator);

    // Self-destruct to max address
    const max_addr = std.math.maxInt(u160); // Max valid address
    try frame.stack.push(max_addr);

    const dispatch = createMockDispatch();
    const result = try TestFrame.SystemHandlers.selfdestruct(frame, dispatch);

    try testing.expectEqual(TestFrame.Success.SelfDestruct, result);
}

// Address conversion tests
test "Address conversion - from_u256 edge cases" {
    // Test zero
    const zero = TestFrame.SystemHandlers.from_u256(0);
    try testing.expectEqual(primitives.ZERO_ADDRESS, zero);

    // Test max u160 (max valid address)
    const max_u160 = std.math.maxInt(u160);
    const max_addr = TestFrame.SystemHandlers.from_u256(max_u160);
    const expected_max = Address.fromBytes([_]u8{0xFF} ** 20) catch unreachable;
    try testing.expectEqual(expected_max, max_addr);

    // Test truncation from u256
    const large_value: u256 = std.math.shl(u256, 1, 200) | 0x1234567890ABCDEF1234567890ABCDEF12345678;
    const truncated = TestFrame.SystemHandlers.from_u256(large_value);
    // Should only keep lower 160 bits
    const expected_bytes = [_]u8{ 0x12, 0x34, 0x56, 0x78, 0x90, 0xAB, 0xCD, 0xEF, 0x12, 0x34, 0x56, 0x78, 0x90, 0xAB, 0xCD, 0xEF, 0x12, 0x34, 0x56, 0x78 };
    const expected = Address.fromBytes(expected_bytes) catch unreachable;
    try testing.expectEqual(expected, truncated);
}

test "Address conversion - to_u256 edge cases" {
    // Test zero
    const zero_addr = primitives.ZERO_ADDRESS;
    const zero_u256 = TestFrame.SystemHandlers.to_u256(zero_addr);
    try testing.expectEqual(@as(u256, 0), zero_u256);

    // Test max address
    const max_bytes = [_]u8{0xFF} ** 20;
    const max_addr = Address.fromBytes(max_bytes) catch unreachable;
    const max_u256 = TestFrame.SystemHandlers.to_u256(max_addr);
    try testing.expectEqual(@as(u256, std.math.maxInt(u160)), max_u256);

    // Test specific pattern
    const pattern_bytes = [_]u8{ 0x12, 0x34, 0x56, 0x78, 0x90, 0xAB, 0xCD, 0xEF, 0x12, 0x34, 0x56, 0x78, 0x90, 0xAB, 0xCD, 0xEF, 0x12, 0x34, 0x56, 0x78 };
    const pattern_addr = Address.fromBytes(pattern_bytes) catch unreachable;
    const pattern_u256 = TestFrame.SystemHandlers.to_u256(pattern_addr);
    const expected: u256 = 0x1234567890ABCDEF1234567890ABCDEF12345678;
    try testing.expectEqual(expected, pattern_u256);
}

// CALL opcode comprehensive tests
test "CALL opcode - with value in static context" {
    var evm = MockEvm.init(testing.allocator);
    evm.is_static = true;
    var frame = try createTestFrame(testing.allocator, &evm);
    defer frame.deinit(testing.allocator);

    // Try CALL with value in static context (should fail)
    try frame.stack.push(100000); // gas
    try frame.stack.push(0x1234); // address
    try frame.stack.push(1); // value > 0
    try frame.stack.push(0); // input_offset
    try frame.stack.push(0); // input_size
    try frame.stack.push(0); // output_offset
    try frame.stack.push(0); // output_size

    const dispatch = createMockDispatch();
    const result = TestFrame.SystemHandlers.call(frame, dispatch);

    try testing.expectError(TestFrame.Error.WriteProtection, result);
}

test "CALL opcode - zero value in static context" {
    var evm = MockEvm.init(testing.allocator);
    evm.is_static = true;
    var frame = try createTestFrame(testing.allocator, &evm);
    defer frame.deinit(testing.allocator);

    // CALL with zero value in static context should work
    try frame.stack.push(100000); // gas
    try frame.stack.push(0x1234); // address
    try frame.stack.push(0); // value = 0
    try frame.stack.push(0); // input_offset
    try frame.stack.push(0); // input_size
    try frame.stack.push(0); // output_offset
    try frame.stack.push(0); // output_size

    const dispatch = createMockDispatch();
    const result = try TestFrame.SystemHandlers.call(frame, dispatch);

    try testing.expect(result == TestFrame.Success.stop);
    try testing.expectEqual(@as(u256, 1), try frame.stack.pop()); // success
}

test "CALL opcode - max gas" {
    var evm = MockEvm.init(testing.allocator);
    var frame = try createTestFrame(testing.allocator, &evm);
    defer frame.deinit(testing.allocator);

    // Test with max u64 gas
    try frame.stack.push(std.math.maxInt(u64)); // max gas
    try frame.stack.push(0x1234); // address
    try frame.stack.push(0); // value
    try frame.stack.push(0); // input_offset
    try frame.stack.push(0); // input_size
    try frame.stack.push(0); // output_offset
    try frame.stack.push(0); // output_size

    const dispatch = createMockDispatch();
    const result = try TestFrame.SystemHandlers.call(frame, dispatch);

    try testing.expect(result == TestFrame.Success.stop);
    try testing.expectEqual(@as(u256, 1), try frame.stack.pop());
}

test "CALL opcode - gas overflow" {
    var evm = MockEvm.init(testing.allocator);
    var frame = try createTestFrame(testing.allocator, &evm);
    defer frame.deinit(testing.allocator);

    // Test with gas > max u64 (should fail gracefully)
    const overflow_gas: u256 = std.math.maxInt(u64) + 1;
    try frame.stack.push(overflow_gas); // gas > max u64
    try frame.stack.push(0x1234); // address
    try frame.stack.push(0); // value
    try frame.stack.push(0); // input_offset
    try frame.stack.push(0); // input_size
    try frame.stack.push(0); // output_offset
    try frame.stack.push(0); // output_size

    const dispatch = createMockDispatch();
    const result = try TestFrame.SystemHandlers.call(frame, dispatch);

    try testing.expect(result == TestFrame.Success.stop);
    try testing.expectEqual(@as(u256, 0), try frame.stack.pop()); // failure
}

test "CALL opcode - with input and output data" {
    var evm = MockEvm.init(testing.allocator);
    evm.call_result.output = "Hello World!";
    var frame = try createTestFrame(testing.allocator, &evm);
    defer frame.deinit(testing.allocator);

    // Prepare input data
    const input_data = "test input";
    try frame.memory.set_data(frame.allocator, 0, input_data);

    try frame.stack.push(100000); // gas
    try frame.stack.push(0x1234); // address
    try frame.stack.push(0); // value
    try frame.stack.push(0); // input_offset
    try frame.stack.push(input_data.len); // input_size
    try frame.stack.push(100); // output_offset
    try frame.stack.push(32); // output_size

    const dispatch = createMockDispatch();
    const result = try TestFrame.SystemHandlers.call(frame, dispatch);

    try testing.expect(result == TestFrame.Success.stop);
    try testing.expectEqual(@as(u256, 1), try frame.stack.pop());

    // Check return data was stored
    try testing.expectEqualSlices(u8, "Hello World!", frame.output);

    // Check output was written to memory
    const output = frame.memory.get_slice(100, "Hello World!".len) catch unreachable;
    try testing.expectEqualSlices(u8, "Hello World!", output);
}

test "CALL opcode - output size limiting" {
    var evm = MockEvm.init(testing.allocator);
    evm.call_result.output = "Very long output data that exceeds requested size";
    var frame = try createTestFrame(testing.allocator, &evm);
    defer frame.deinit(testing.allocator);

    try frame.stack.push(100000); // gas
    try frame.stack.push(0x1234); // address
    try frame.stack.push(0); // value
    try frame.stack.push(0); // input_offset
    try frame.stack.push(0); // input_size
    try frame.stack.push(0); // output_offset
    try frame.stack.push(10); // output_size (smaller than actual output)

    const dispatch = createMockDispatch();
    const result = try TestFrame.SystemHandlers.call(frame, dispatch);

    try testing.expect(result == TestFrame.Success.stop);
    try testing.expectEqual(@as(u256, 1), try frame.stack.pop());

    // Full return data should be stored
    try testing.expectEqualSlices(u8, evm.call_result.output, frame.output);

    // But only requested size written to memory
    const output = frame.memory.get_slice(0, 10) catch unreachable;
    try testing.expectEqualSlices(u8, "Very long ", output);
}

test "CALL opcode - failed call" {
    var evm = MockEvm.init(testing.allocator);
    evm.call_result.success = false;
    evm.call_result.output = "Revert reason";
    var frame = try createTestFrame(testing.allocator, &evm);
    defer frame.deinit(testing.allocator);

    try frame.stack.push(100000); // gas
    try frame.stack.push(0x1234); // address
    try frame.stack.push(0); // value
    try frame.stack.push(0); // input_offset
    try frame.stack.push(0); // input_size
    try frame.stack.push(0); // output_offset
    try frame.stack.push(32); // output_size

    const dispatch = createMockDispatch();
    const result = try TestFrame.SystemHandlers.call(frame, dispatch);

    try testing.expect(result == TestFrame.Success.stop);
    try testing.expectEqual(@as(u256, 0), try frame.stack.pop()); // failure

    // Return data should still be stored
    try testing.expectEqualSlices(u8, "Revert reason", frame.output);
}

// DELEGATECALL tests
test "DELEGATECALL opcode - basic" {
    var evm = MockEvm.init(testing.allocator);
    var frame = try createTestFrame(testing.allocator, &evm);
    defer frame.deinit(testing.allocator);

    try frame.stack.push(100000); // gas
    try frame.stack.push(0x5678); // address
    try frame.stack.push(0); // input_offset
    try frame.stack.push(0); // input_size
    try frame.stack.push(0); // output_offset
    try frame.stack.push(0); // output_size

    const dispatch = createMockDispatch();
    const result = try TestFrame.SystemHandlers.delegatecall(frame, dispatch);

    try testing.expect(result == TestFrame.Success.stop);
    try testing.expectEqual(@as(u256, 1), try frame.stack.pop());
}

test "DELEGATECALL opcode - preserves context" {
    var evm = MockEvm.init(testing.allocator);
    evm.call_result.output = "delegated output";
    var frame = try createTestFrame(testing.allocator, &evm);
    defer frame.deinit(testing.allocator);

    const input = "delegate input";
    try frame.memory.set_data(testing.allocator, 0, input);

    try frame.stack.push(50000); // gas
    try frame.stack.push(0xDEADBEEF); // address
    try frame.stack.push(0); // input_offset
    try frame.stack.push(input.len); // input_size
    try frame.stack.push(100); // output_offset
    try frame.stack.push(32); // output_size

    const dispatch = createMockDispatch();
    const result = try TestFrame.SystemHandlers.delegatecall(frame, dispatch);

    try testing.expect(result == TestFrame.Success.stop);
    try testing.expectEqual(@as(u256, 1), try frame.stack.pop());

    // Verify output
    const output = frame.memory.get_slice(100, "delegated output".len) catch unreachable;
    try testing.expectEqualSlices(u8, "delegated output", output);
}

// STATICCALL tests
test "STATICCALL opcode - basic" {
    var evm = MockEvm.init(testing.allocator);
    var frame = try createTestFrame(testing.allocator, &evm);
    defer frame.deinit(testing.allocator);

    try frame.stack.push(100000); // gas
    try frame.stack.push(0x9999); // address
    try frame.stack.push(0); // input_offset
    try frame.stack.push(0); // input_size
    try frame.stack.push(0); // output_offset
    try frame.stack.push(0); // output_size

    const dispatch = createMockDispatch();
    const result = try TestFrame.SystemHandlers.staticcall(frame, dispatch);

    try testing.expect(result == TestFrame.Success.stop);
    try testing.expectEqual(@as(u256, 1), try frame.stack.pop());
}

test "STATICCALL opcode - enforces no value" {
    var evm = MockEvm.init(testing.allocator);
    evm.call_result.output = "static result";
    var frame = try createTestFrame(testing.allocator, &evm);
    defer frame.deinit(testing.allocator);

    try frame.stack.push(75000); // gas
    try frame.stack.push(0xABCD); // address
    try frame.stack.push(0); // input_offset
    try frame.stack.push(0); // input_size
    try frame.stack.push(50); // output_offset
    try frame.stack.push(20); // output_size

    const dispatch = createMockDispatch();
    const result = try TestFrame.SystemHandlers.staticcall(frame, dispatch);

    try testing.expect(result == TestFrame.Success.stop);
    try testing.expectEqual(@as(u256, 1), try frame.stack.pop());

    const output = frame.memory.get_slice(50, "static result".len) catch unreachable;
    try testing.expectEqualSlices(u8, "static result", output);
}

// CREATE tests
test "CREATE opcode - empty init code" {
    var evm = MockEvm.init(testing.allocator);
    evm.create_result.created_address = Address.fromBytes([_]u8{0x42} ** 20) catch unreachable;
    var frame = try createTestFrame(testing.allocator, &evm);
    defer frame.deinit(testing.allocator);

    try frame.stack.push(0); // value
    try frame.stack.push(0); // offset
    try frame.stack.push(0); // size (empty init code)

    const dispatch = createMockDispatch();
    const result = try TestFrame.SystemHandlers.create(frame, dispatch);

    try testing.expect(result == TestFrame.Success.stop);
    const created_addr = try frame.stack.pop();
    try testing.expect(created_addr != 0); // Should have address
}

test "CREATE opcode - with init code" {
    var evm = MockEvm.init(testing.allocator);
    evm.create_result.created_address = Address.fromBytes([_]u8{0x11} ** 20) catch unreachable;
    var frame = try createTestFrame(testing.allocator, &evm);
    defer frame.deinit(testing.allocator);

    // Simple init code
    const init_code = [_]u8{ 0x60, 0x00, 0x60, 0x00, 0xF3 }; // PUSH1 0 PUSH1 0 RETURN
    try frame.memory.set_data(frame.allocator, 0, &init_code);

    try frame.stack.push(1000); // value
    try frame.stack.push(0); // offset
    try frame.stack.push(init_code.len); // size

    const dispatch = createMockDispatch();
    const result = try TestFrame.SystemHandlers.create(frame, dispatch);

    try testing.expect(result == TestFrame.Success.stop);
    const created_addr = try frame.stack.pop();
    try testing.expect(created_addr != 0);
}

test "CREATE opcode - failed creation" {
    var evm = MockEvm.init(testing.allocator);
    evm.create_result.success = false;
    var frame = try createTestFrame(testing.allocator, &evm);
    defer frame.deinit(testing.allocator);

    try frame.stack.push(0); // value
    try frame.stack.push(0); // offset
    try frame.stack.push(0); // size

    const dispatch = createMockDispatch();
    const result = try TestFrame.SystemHandlers.create(frame, dispatch);

    try testing.expect(result == TestFrame.Success.stop);
    try testing.expectEqual(@as(u256, 0), try frame.stack.pop()); // failure
}

test "CREATE opcode - out of bounds" {
    var evm = MockEvm.init(testing.allocator);
    var frame = try createTestFrame(testing.allocator, &evm);
    defer frame.deinit(testing.allocator);

    try frame.stack.push(0); // value
    try frame.stack.push(std.math.maxInt(u256)); // huge offset
    try frame.stack.push(32); // size

    const dispatch = createMockDispatch();
    const result = try TestFrame.SystemHandlers.create(frame, dispatch);

    try testing.expect(result == TestFrame.Success.stop);
    try testing.expectEqual(@as(u256, 0), try frame.stack.pop()); // failure
}

// CREATE2 tests
test "CREATE2 opcode - deterministic address" {
    var evm = MockEvm.init(testing.allocator);
    evm.create_result.created_address = Address.fromBytes([_]u8{0x22} ** 20) catch unreachable;
    var frame = try createTestFrame(testing.allocator, &evm);
    defer frame.deinit(testing.allocator);

    try frame.stack.push(0); // value
    try frame.stack.push(0); // offset
    try frame.stack.push(0); // size
    try frame.stack.push(0xDEADBEEF); // salt

    const dispatch = createMockDispatch();
    const result = try TestFrame.SystemHandlers.create2(frame, dispatch);

    try testing.expect(result == TestFrame.Success.stop);
    const created_addr = try frame.stack.pop();
    try testing.expect(created_addr != 0);
}

test "CREATE2 opcode - different salts" {
    var evm = MockEvm.init(testing.allocator);
    var frame = try createTestFrame(testing.allocator, &evm);
    defer frame.deinit(testing.allocator);

    // Test with multiple different salts
    const salts = [_]u256{ 0, 1, std.math.maxInt(u256), 0x123456789ABCDEF };

    for (salts) |salt| {
        evm.create_result.created_address = Address.fromBytes([_]u8{@truncate(salt)} ** 20) catch unreachable;

        try frame.stack.push(0); // value
        try frame.stack.push(0); // offset
        try frame.stack.push(0); // size
        try frame.stack.push(salt); // salt

        const dispatch = createMockDispatch();
        const result = try TestFrame.SystemHandlers.create2(frame, dispatch);

        try testing.expect(result == TestFrame.Success.stop);
        _ = try frame.stack.pop(); // created address
    }
}

test "CREATE2 opcode - static context" {
    var evm = MockEvm.init(testing.allocator);
    evm.is_static = true;
    var frame = try createTestFrame(testing.allocator, &evm);
    defer frame.deinit(testing.allocator);

    try frame.stack.push(0); // value
    try frame.stack.push(0); // offset
    try frame.stack.push(0); // size
    try frame.stack.push(0); // salt

    const dispatch = createMockDispatch();
    const result = TestFrame.SystemHandlers.create2(frame, dispatch);

    try testing.expectError(TestFrame.Error.WriteProtection, result);
}

test "DELEGATECALL - comprehensive tests" {
    var evm = MockEvm.init(testing.allocator);
    var frame = try createTestFrame(testing.allocator, &evm);
    defer frame.deinit(testing.allocator);

    // Test successful delegatecall
    {
        evm.call_result.success = true;
        evm.call_result.gas_left = 50000;
        evm.call_result.output = "delegated result";

        const input_data = "test input";
        try frame.memory.set_data(frame.allocator, 0, input_data);

        try frame.stack.push(75000); // gas
        try frame.stack.push(0x5678); // address
        try frame.stack.push(0); // input_offset
        try frame.stack.push(input_data.len); // input_size
        try frame.stack.push(100); // output_offset
        try frame.stack.push(32); // output_size

        const dispatch = createMockDispatch();
        const result = try TestFrame.SystemHandlers.delegatecall(frame, dispatch);

        try testing.expect(result == TestFrame.Success.stop);
        try testing.expectEqual(@as(u256, 1), try frame.stack.pop());

        // Check return data was stored
        try testing.expectEqualSlices(u8, "delegated result", frame.output);

        // Check gas was updated
        try testing.expectEqual(@as(i64, 50000), frame.gas_remaining);
    }

    // Test failed delegatecall
    {
        evm.call_result.success = false;
        evm.call_result.gas_left = 0;
        evm.call_result.output = "failure reason";

        // Reset stack
        while (frame.stack.len() > 0) {
            _ = try frame.stack.pop();
        }

        try frame.stack.push(50000); // gas
        try frame.stack.push(0xDEAD); // address
        try frame.stack.push(0); // input_offset
        try frame.stack.push(0); // input_size
        try frame.stack.push(0); // output_offset
        try frame.stack.push(0); // output_size

        const dispatch = createMockDispatch();
        const result = try TestFrame.SystemHandlers.delegatecall(frame, dispatch);

        try testing.expect(result == TestFrame.Success.stop);
        try testing.expectEqual(@as(u256, 0), try frame.stack.pop()); // failure

        // Return data should still be stored even on failure
        try testing.expectEqualSlices(u8, "failure reason", frame.output);
    }
}

test "STATICCALL - comprehensive tests" {
    var evm = MockEvm.init(testing.allocator);
    var frame = try createTestFrame(testing.allocator, &evm);
    defer frame.deinit(testing.allocator);

    // Test successful staticcall
    {
        evm.call_result.success = true;
        evm.call_result.gas_left = 40000;
        evm.call_result.output = "static result";

        const input_data = "query data";
        try frame.memory.set_data(frame.allocator, 0, input_data);

        try frame.stack.push(60000); // gas
        try frame.stack.push(0xABCD); // address
        try frame.stack.push(0); // input_offset
        try frame.stack.push(input_data.len); // input_size
        try frame.stack.push(50); // output_offset
        try frame.stack.push(20); // output_size

        const dispatch = createMockDispatch();
        const result = try TestFrame.SystemHandlers.staticcall(frame, dispatch);

        try testing.expect(result == TestFrame.Success.stop);
        try testing.expectEqual(@as(u256, 1), try frame.stack.pop());

        // Check return data was stored
        try testing.expectEqualSlices(u8, "static result", frame.output);

        // Check gas was updated
        try testing.expectEqual(@as(i64, 40000), frame.gas_remaining);

        // Check output was written to memory (limited to output_size)
        const mem_result = try frame.memory.get_slice(50, "static result".len);
        try testing.expectEqualSlices(u8, "static result", mem_result);
    }

    // Test staticcall with no input/output
    {
        evm.call_result.success = true;
        evm.call_result.gas_left = 30000;
        evm.call_result.output = &.{};

        // Reset stack
        while (frame.stack.len() > 0) {
            _ = try frame.stack.pop();
        }

        try frame.stack.push(50000); // gas
        try frame.stack.push(0x1234); // address
        try frame.stack.push(0); // input_offset
        try frame.stack.push(0); // input_size (no input)
        try frame.stack.push(0); // output_offset
        try frame.stack.push(0); // output_size (no output)

        const dispatch = createMockDispatch();
        const result = try TestFrame.SystemHandlers.staticcall(frame, dispatch);

        try testing.expect(result == TestFrame.Success.stop);
        try testing.expectEqual(@as(u256, 1), try frame.stack.pop());

        // Check empty return data
        try testing.expectEqual(@as(usize, 0), frame.output.len);
    }
}

// Edge case tests
test "System opcodes - stack underflow" {
    var evm = MockEvm.init(testing.allocator);
    var frame = try createTestFrame(testing.allocator, &evm);
    defer frame.deinit(testing.allocator);

    // Test each opcode with insufficient stack items
    const dispatch = createMockDispatch();

    // CALL needs 7 items
    const call_result = TestFrame.SystemHandlers.call(frame, dispatch);
    try testing.expectError(TestFrame.Error.StackUnderflow, call_result);

    // DELEGATECALL needs 6 items
    const delegatecall_result = TestFrame.SystemHandlers.delegatecall(frame, dispatch);
    try testing.expectError(TestFrame.Error.StackUnderflow, delegatecall_result);

    // CREATE needs 3 items
    const create_result = TestFrame.SystemHandlers.create(frame, dispatch);
    try testing.expectError(TestFrame.Error.WriteProtection, create_result); // Static context error comes first

    // RETURN needs 2 items
    const return_result = TestFrame.SystemHandlers.@"return"(frame, dispatch);
    try testing.expectError(TestFrame.Error.StackUnderflow, return_result);

    // SELFDESTRUCT needs 1 item
    const selfdestruct_result = TestFrame.SystemHandlers.selfdestruct(frame, dispatch);
    try testing.expectError(TestFrame.Error.StackUnderflow, selfdestruct_result);
}

test "System opcodes - gas consumption" {
    var evm = MockEvm.init(testing.allocator);
    evm.call_result.gas_left = 50000; // Simulate gas consumption
    var frame = try createTestFrame(testing.allocator, &evm);
    defer frame.deinit(testing.allocator);

    const initial_gas_value = frame.gas_remaining;

    try frame.stack.push(100000); // gas
    try frame.stack.push(0x1234); // address
    try frame.stack.push(0); // value
    try frame.stack.push(0); // input_offset
    try frame.stack.push(0); // input_size
    try frame.stack.push(0); // output_offset
    try frame.stack.push(0); // output_size

    const dispatch = createMockDispatch();
    const result = try TestFrame.SystemHandlers.call(frame, dispatch);

    try testing.expect(result == TestFrame.Success.stop);
    try testing.expectEqual(@as(u256, 1), try frame.stack.pop());

    // Gas should have been consumed
    try testing.expect(frame.gas_remaining < initial_gas_value);
    try testing.expectEqual(@as(i64, 50000), frame.gas_remaining);
}

test "System opcodes - memory boundary checks" {
    var evm = MockEvm.init(testing.allocator);
    var frame = try createTestFrame(testing.allocator, &evm);
    defer frame.deinit(testing.allocator);

    // Test memory operations at various boundaries
    const test_cases = [_]struct { offset: u256, size: u256 }{
        .{ .offset = 0, .size = 0 },
        .{ .offset = 0, .size = 32 },
        .{ .offset = 32, .size = 32 },
        .{ .offset = 0x1000, .size = 0x100 },
        .{ .offset = std.math.maxInt(u32), .size = 1 },
    };

    for (test_cases) |tc| {
        // Clear stack
        while (frame.stack.len() > 0) {
            _ = try frame.stack.pop();
        }

        // Test with CALL
        try frame.stack.push(100000); // gas
        try frame.stack.push(0x1234); // address
        try frame.stack.push(0); // value
        try frame.stack.push(tc.offset); // input_offset
        try frame.stack.push(tc.size); // input_size
        try frame.stack.push(tc.offset); // output_offset
        try frame.stack.push(tc.size); // output_size

        const dispatch = createMockDispatch();
        const result = try TestFrame.SystemHandlers.call(frame, dispatch);

        try testing.expect(result == TestFrame.Success.stop);
        _ = try frame.stack.pop();
    }
}
