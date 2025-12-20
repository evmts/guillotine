/// System opcode handlers for the EVM (CALL, CREATE, SELFDESTRUCT)
const std = @import("std");
const primitives = @import("primitives");
const GasConstants = primitives.GasConstants;
const Address = primitives.Address.Address;
const precompiles = @import("precompiles");

/// Handlers struct - provides system operation handlers for a Frame type
/// The FrameType must have methods: getEvm, consumeGas, popStack, pushStack
/// and fields appropriate for system operations
pub fn Handlers(FrameType: type) type {
    const CallParams = FrameType.EvmType.CallParams;

    return struct {
        /// Helper functions
        inline fn wordCount(bytes: u64) u64 {
            return (bytes + 31) / 32;
        }

        inline fn wordAlignedSize(bytes: u64) u32 {
            const words = wordCount(bytes);
            return @intCast(words * 32);
        }

        inline fn add_u32(a: u32, b: u32) FrameType.EvmError!u32 {
            return std.math.add(u32, a, b) catch return error.OutOfBounds;
        }

        /// CREATE opcode (0xf0) - Create a new contract
        pub fn create(frame: *FrameType) FrameType.EvmError!void {
            // EIP-214: CREATE cannot be executed in static call context
            if (frame.is_static) return error.StaticCallViolation;

            // Clear return_data at the start (per Python reference implementation)
            frame.return_data = &[_]u8{};

            const value = try frame.popStack();
            const offset = try frame.popStack();
            const length = try frame.popStack();

            const len = std.math.cast(u32, length) orelse return error.OutOfBounds;
            const gas_cost = frame.createGasCost(len);
            try frame.consumeGas(gas_cost);

            // Read init code from memory
            var init_code: []const u8 = &.{};
            if (length > 0 and length <= std.math.maxInt(u32)) {
                const off = std.math.cast(u32, offset) orelse return error.OutOfBounds;

                // Check memory bounds and charge for expansion
                const end_bytes = @as(u64, off) + @as(u64, len);
                const mem_cost = frame.memoryExpansionCost(end_bytes);
                try frame.consumeGas(mem_cost);

                // Update logical memory size
                const aligned = wordAlignedSize(end_bytes);
                if (aligned > frame.memory_size) frame.memory_size = aligned;

                const code = try frame.allocator.alloc(u8, len);
                var j: u32 = 0;
                while (j < len) : (j += 1) {
                    const addr = try add_u32(off, j);
                    code[j] = frame.readMemory(addr);
                }
                init_code = code;
            }

            const evm = frame.getEvm();

            // Calculate available gas
            const remaining_gas = @as(u64, @intCast(@max(frame.gas_remaining, 0)));
            // EIP-150: all but 1/64th (introduced in Tangerine Whistle)
            // Before EIP-150: forward all remaining gas
            const max_gas = if (evm.hardfork.isAtLeast(.TANGERINE_WHISTLE))
                remaining_gas - (remaining_gas / 64)
            else
                remaining_gas;

            // Perform CREATE
            const result = try evm.inner_create(value, init_code, max_gas, null);

            // Update gas
            const gas_used = max_gas - result.gas_left;
            // Safely cast gas_used - if it exceeds i64::MAX, clamp gas_remaining to 0
            const gas_used_i64 = std.math.cast(i64, gas_used) orelse {
                frame.gas_remaining = 0;
                return error.OutOfGas;
            };
            frame.gas_remaining -= gas_used_i64;

            // Set return_data according to CREATE semantics:
            // - On success: return_data is empty
            // - On failure: return_data is the child's output
            if (result.success) {
                frame.return_data = &[_]u8{};
            } else {
                frame.return_data = result.output;
            }

            // Push address onto stack (0 if failed)
            const addr_u256 = if (result.success) blk: {
                var val: u256 = 0;
                for (result.address.bytes) |b| {
                    val = (val << 8) | b;
                }
                break :blk val;
            } else 0;
            try frame.pushStack(addr_u256);

            frame.pc += 1;
        }

        /// CALL opcode (0xf1) - Message call into an account
        pub fn call(frame: *FrameType) FrameType.EvmError!void {
            // Pop all 7 arguments
            const gas = try frame.popStack();
            const address_u256 = try frame.popStack();
            const value_arg = try frame.popStack();
            const in_offset = try frame.popStack();
            const in_length = try frame.popStack();
            const out_offset = try frame.popStack();
            const out_length = try frame.popStack();

            // EIP-214: CALL with non-zero value cannot be executed in static call context
            if (frame.is_static and value_arg > 0) return error.StaticCallViolation;

            // Convert address
            var addr_bytes: [20]u8 = undefined;
            var i: usize = 0;
            while (i < 20) : (i += 1) {
                addr_bytes[19 - i] = @as(u8, @truncate(address_u256 >> @intCast(i * 8)));
            }
            const call_address = Address{ .bytes = addr_bytes };

            const evm = frame.getEvm();

            // Gas cost calculation based on hardfork
            var gas_cost: u64 = 0;

            // EIP-2929 (Berlin+): Use warm/cold access costs instead of flat base cost
            // EIP-150 (Tangerine Whistle): Changed base cost from 40 to 700
            // Pre-Tangerine Whistle: Use 40 gas base cost
            if (evm.hardfork.isBefore(.BERLIN)) {
                gas_cost = if (evm.hardfork.isBefore(.TANGERINE_WHISTLE)) 40 else GasConstants.CallGas;
            }

            if (value_arg > 0) {
                gas_cost += GasConstants.CallValueTransferGas;

                // Check if target is a precompile (hardfork-aware)
                // Precompiles are considered to always exist and should not incur new account cost
                const is_precompile = precompiles.isPrecompile(call_address, evm.hardfork);

                // EIP-150: Check if target account exists
                // If calling non-existent account with value, add account creation cost
                const target_exists = is_precompile or blk: {
                    if (evm.host) |h| {
                        const has_balance = h.getBalance(call_address) > 0;
                        const has_code = h.getCode(call_address).len > 0;
                        const has_nonce = h.getNonce(call_address) > 0;
                        break :blk has_balance or has_code or has_nonce;
                    } else {
                        const has_balance = (evm.balances.get(call_address) orelse 0) > 0;
                        const has_code = (evm.code.get(call_address) orelse &[_]u8{}).len > 0;
                        const has_nonce = (evm.nonces.get(call_address) orelse 0) > 0;
                        break :blk has_balance or has_code or has_nonce;
                    }
                };
                if (!target_exists) {
                    gas_cost += GasConstants.CallNewAccountGas; // +25000 for creating new account
                }
            }
            // EIP-2929 (Berlin+): access target account (warm/cold)
            // Returns 0 for pre-Berlin, 100 for warm, 2600 for cold in Berlin+
            const access_cost = try evm.accessAddress(call_address);
            gas_cost += access_cost;

            // Calculate memory expansion cost for BOTH input and output regions together
            // Per Python reference (gas.py:179-192), calculate_gas_extend_memory processes
            // all memory extensions together, updating current_size between iterations
            // This ensures we only charge for the INCREMENTAL expansion, not double-charge
            const in_end = if (in_length > 0) @as(u64, @intCast(in_offset)) + @as(u64, @intCast(in_length)) else 0;
            const out_end = if (out_length > 0) @as(u64, @intCast(out_offset)) + @as(u64, @intCast(out_length)) else 0;
            const max_end = @max(in_end, out_end);
            if (max_end > 0) {
                const mem_cost = frame.memoryExpansionCost(max_end);
                gas_cost += mem_cost;
                // Update memory_size immediately after charging (matches Python behavior)
                // Python: evm.memory += b"\x00" * extend_memory.expand_by
                const aligned_size = wordAlignedSize(max_end);
                if (aligned_size > frame.memory_size) frame.memory_size = aligned_size;
            }

            // Calculate available gas BEFORE charging (per Python execution-specs)
            // Python: gas = min(gas, max_message_call_gas(gas_left - memory_cost - extra_gas))
            // We simulate the post-charge state to calculate max forwardable gas
            const gas_limit = if (gas > std.math.maxInt(u64)) std.math.maxInt(u64) else @as(u64, @intCast(gas));
            const remaining_gas_before_charge = @as(u64, @intCast(@max(frame.gas_remaining, 0)));
            // Subtract the cost we're about to charge to get the "would-be" remaining gas
            const gas_after_charge = if (remaining_gas_before_charge >= gas_cost)
                remaining_gas_before_charge - gas_cost
            else
                0;
            // EIP-150: all but 1/64th (introduced in Tangerine Whistle)
            // Before EIP-150: forward all remaining gas
            const max_gas = if (evm.hardfork.isAtLeast(.TANGERINE_WHISTLE))
                gas_after_charge - (gas_after_charge / 64)
            else
                gas_after_charge;
            const available_gas_without_stipend = @min(gas_limit, max_gas);

            // Add gas stipend for value transfers (stipend is free, caller doesn't pay for it)
            const available_gas = if (value_arg > 0)
                available_gas_without_stipend + GasConstants.CallStipend
            else
                available_gas_without_stipend;

            // NOW charge the total cost (extra costs + forwardable gas)
            // Per Python: charge_gas(evm, message_call_gas.cost + extend_memory.cost)
            // where message_call_gas.cost = gas + extra_gas
            const total_cost = gas_cost + available_gas_without_stipend;
            try frame.consumeGas(total_cost);

            // Read input data from memory
            var input_data: []const u8 = &.{};
            if (in_length > 0 and in_length <= std.math.maxInt(u32)) {
                const in_off = std.math.cast(u32, in_offset) orelse return error.OutOfBounds;
                const in_len = std.math.cast(u32, in_length) orelse return error.OutOfBounds;

                // Check if in_off + in_len would overflow
                const end_offset = in_off +% in_len;
                if (end_offset >= in_off) {
                    const data = try frame.allocator.alloc(u8, in_len);
                    var j: u32 = 0;
                    while (j < in_len) : (j += 1) {
                        const addr = try add_u32(in_off, j);
                        data[j] = frame.readMemory(addr);
                    }
                    input_data = data;
                }
                // else: overflow occurred, use empty input data
            }
            // Note: No defer free needed - arena allocator will clean up

            // Perform the inner call (regular CALL)
            const params = CallParams{ .call = .{
                .caller = frame.address,
                .to = call_address,
                .value = value_arg,
                .input = input_data,
                .gas = available_gas,
            } };
            const result = evm.inner_call(params);

            // Write output to memory
            // Note: Memory expansion cost was already charged upfront
            if (out_length > 0 and result.output.len > 0) {
                const out_off = std.math.cast(u32, out_offset) orelse return error.OutOfBounds;
                const out_len_u32 = std.math.cast(u32, out_length) orelse return error.OutOfBounds;
                const result_len_u32 = std.math.cast(u32, result.output.len) orelse return error.OutOfBounds;
                const copy_len = @min(out_len_u32, result_len_u32);

                var k: u32 = 0;
                while (k < copy_len) : (k += 1) {
                    const addr = try add_u32(out_off, k);
                    try frame.writeMemory(addr, result.output[k]);
                }
            }

            // Store return data
            frame.return_data = result.output;

            // Push success status
            const success_val: u256 = if (result.success) 1 else 0;
            try frame.pushStack(success_val);

            // Refund unused gas (including any unused stipend)
            // Per Python: evm.gas_left += child_evm.gas_left
            // Cap refund at available_gas to prevent overflow if child somehow returns more than allocated
            const gas_to_refund = @min(result.gas_left, available_gas);
            const gas_to_refund_i64 = std.math.cast(i64, gas_to_refund) orelse std.math.maxInt(i64);
            frame.gas_remaining = @min(frame.gas_remaining + gas_to_refund_i64, std.math.maxInt(i64));

            frame.pc += 1;
        }

        /// CALLCODE opcode (0xf2) - Message call into this account with another account's code
        pub fn callcode(frame: *FrameType) FrameType.EvmError!void {
            // Similar to CALL but executes code in current context
            // Pop all 7 arguments
            const gas = try frame.popStack();
            const address_u256 = try frame.popStack();
            const value_arg = try frame.popStack();
            const in_offset = try frame.popStack();
            const in_length = try frame.popStack();
            const out_offset = try frame.popStack();
            const out_length = try frame.popStack();

            // Convert address
            var addr_bytes: [20]u8 = undefined;
            var i: usize = 0;
            while (i < 20) : (i += 1) {
                addr_bytes[19 - i] = @as(u8, @truncate(address_u256 >> @intCast(i * 8)));
            }
            const call_address = Address{ .bytes = addr_bytes };

            const evm = frame.getEvm();

            // Gas cost calculation based on hardfork
            var gas_cost: u64 = 0;

            // EIP-2929 (Berlin+): Use warm/cold access costs instead of flat base cost
            // EIP-150 (Tangerine Whistle): Changed base cost from 40 to 700
            // Pre-Tangerine Whistle: Use 40 gas base cost
            if (evm.hardfork.isBefore(.BERLIN)) {
                gas_cost = if (evm.hardfork.isBefore(.TANGERINE_WHISTLE)) 40 else GasConstants.CallGas;
            }

            if (value_arg > 0) {
                gas_cost += GasConstants.CallValueTransferGas;
            }
            // EIP-2929 (Berlin+): access target account (warm/cold)
            // Returns 0 for pre-Berlin, 100 for warm, 2600 for cold in Berlin+
            const access_cost = try evm.accessAddress(call_address);
            gas_cost += access_cost;

            // Calculate memory expansion cost for BOTH input and output regions together
            const in_end = if (in_length > 0) @as(u64, @intCast(in_offset)) + @as(u64, @intCast(in_length)) else 0;
            const out_end = if (out_length > 0) @as(u64, @intCast(out_offset)) + @as(u64, @intCast(out_length)) else 0;
            const max_end = @max(in_end, out_end);
            if (max_end > 0) {
                const mem_cost = frame.memoryExpansionCost(max_end);
                gas_cost += mem_cost;
                // Update memory_size immediately after charging (matches Python behavior)
                // Python: evm.memory += b"\x00" * extend_memory.expand_by
                const aligned_size = wordAlignedSize(max_end);
                if (aligned_size > frame.memory_size) frame.memory_size = aligned_size;
            }

            // Calculate available gas BEFORE charging (per Python execution-specs)
            const gas_limit = if (gas > std.math.maxInt(u64)) std.math.maxInt(u64) else @as(u64, @intCast(gas));
            const remaining_gas_before_charge = @as(u64, @intCast(@max(frame.gas_remaining, 0)));
            const gas_after_charge = if (remaining_gas_before_charge >= gas_cost)
                remaining_gas_before_charge - gas_cost
            else
                0;
            // EIP-150: all but 1/64th (introduced in Tangerine Whistle)
            // Before EIP-150: forward all remaining gas
            const max_gas = if (evm.hardfork.isAtLeast(.TANGERINE_WHISTLE))
                gas_after_charge - (gas_after_charge / 64)
            else
                gas_after_charge;
            const available_gas_without_stipend = @min(gas_limit, max_gas);

            // Add gas stipend for value transfers (stipend is free, caller doesn't pay for it)
            const available_gas = if (value_arg > 0)
                available_gas_without_stipend + GasConstants.CallStipend
            else
                available_gas_without_stipend;

            // NOW charge the total cost (extra costs + forwardable gas)
            // Per Python: charge_gas(evm, message_call_gas.cost + extend_memory.cost)
            // where message_call_gas.cost = gas + extra_gas
            const total_cost = gas_cost + available_gas_without_stipend;
            try frame.consumeGas(total_cost);

            // Read input data from memory
            var input_data: []const u8 = &.{};
            if (in_length > 0 and in_length <= std.math.maxInt(u32)) {
                const in_off = std.math.cast(u32, in_offset) orelse return error.OutOfBounds;
                const in_len = std.math.cast(u32, in_length) orelse return error.OutOfBounds;

                // Check if in_off + in_len would overflow
                const end_offset = in_off +% in_len;
                if (end_offset >= in_off) {
                    const data = try frame.allocator.alloc(u8, in_len);
                    var j: u32 = 0;
                    while (j < in_len) : (j += 1) {
                        const addr = try add_u32(in_off, j);
                        data[j] = frame.readMemory(addr);
                    }
                    input_data = data;
                }
                // else: overflow occurred, use empty input data
            }
            // Note: No defer free needed - arena allocator will clean up

            // Perform the inner call (CALLCODE)
            const params = CallParams{ .callcode = .{
                .caller = frame.address,
                .to = call_address,
                .value = value_arg,
                .input = input_data,
                .gas = available_gas,
            } };
            const result = evm.inner_call(params);

            // Write output to memory
            if (out_length > 0 and result.output.len > 0) {
                const out_off = std.math.cast(u32, out_offset) orelse return error.OutOfBounds;
                const out_len_u32 = std.math.cast(u32, out_length) orelse return error.OutOfBounds;
                const result_len_u32 = std.math.cast(u32, result.output.len) orelse return error.OutOfBounds;
                const copy_len = @min(out_len_u32, result_len_u32);

                var k: u32 = 0;
                while (k < copy_len) : (k += 1) {
                    const addr = try add_u32(out_off, k);
                    try frame.writeMemory(addr, result.output[k]);
                }
            }

            // Store return data
            frame.return_data = result.output;

            // Push success status
            try frame.pushStack(if (result.success) 1 else 0);

            // Refund unused gas (including any unused stipend)
            // Per Python: evm.gas_left += child_evm.gas_left
            // Cap refund at available_gas to prevent overflow if child somehow returns more than allocated
            const gas_to_refund = @min(result.gas_left, available_gas);
            const gas_to_refund_i64 = std.math.cast(i64, gas_to_refund) orelse std.math.maxInt(i64);
            frame.gas_remaining = @min(frame.gas_remaining + gas_to_refund_i64, std.math.maxInt(i64));

            frame.pc += 1;
        }

        /// DELEGATECALL opcode (0xf4) - Message call with another account's code, but keep current msg.sender and msg.value
        pub fn delegatecall(frame: *FrameType) FrameType.EvmError!void {
            const evm = frame.getEvm();

            // EIP-7: DELEGATECALL was introduced in Homestead hardfork
            if (evm.hardfork.isBefore(.HOMESTEAD)) return error.InvalidOpcode;

            // Pop all 6 arguments (no value)
            const gas = try frame.popStack();
            const address_u256 = try frame.popStack();
            const in_offset = try frame.popStack();
            const in_length = try frame.popStack();
            const out_offset = try frame.popStack();
            const out_length = try frame.popStack();

            // Convert address
            var addr_bytes: [20]u8 = undefined;
            var i: usize = 0;
            while (i < 20) : (i += 1) {
                addr_bytes[19 - i] = @as(u8, @truncate(address_u256 >> @intCast(i * 8)));
            }
            const call_address = Address{ .bytes = addr_bytes };

            // Gas cost calculation based on hardfork
            var gas_cost: u64 = 0;

            // EIP-2929 (Berlin+): Use warm/cold access costs instead of flat base cost
            // EIP-150 (Tangerine Whistle): Changed base cost from 40 to 700
            // Pre-Tangerine Whistle: Use 40 gas base cost
            if (evm.hardfork.isBefore(.BERLIN)) {
                gas_cost = if (evm.hardfork.isBefore(.TANGERINE_WHISTLE)) 40 else GasConstants.CallGas;
            }

            // EIP-2929 (Berlin+): access target account (warm/cold)
            // Returns 0 for pre-Berlin, 100 for warm, 2600 for cold in Berlin+
            const access_cost = try evm.accessAddress(call_address);
            gas_cost += access_cost;

            // Calculate memory expansion cost for BOTH input and output regions together
            const in_end = if (in_length > 0) @as(u64, @intCast(in_offset)) + @as(u64, @intCast(in_length)) else 0;
            const out_end = if (out_length > 0) @as(u64, @intCast(out_offset)) + @as(u64, @intCast(out_length)) else 0;
            const max_end = @max(in_end, out_end);
            if (max_end > 0) {
                const mem_cost = frame.memoryExpansionCost(max_end);
                gas_cost += mem_cost;
                // Update memory_size immediately after charging (matches Python behavior)
                // Python: evm.memory += b"\x00" * extend_memory.expand_by
                const aligned_size = wordAlignedSize(max_end);
                if (aligned_size > frame.memory_size) frame.memory_size = aligned_size;
            }

            // Calculate available gas BEFORE charging (per Python execution-specs)
            const gas_limit = if (gas > std.math.maxInt(u64)) std.math.maxInt(u64) else @as(u64, @intCast(gas));
            const remaining_gas_before_charge = @as(u64, @intCast(@max(frame.gas_remaining, 0)));
            const gas_after_charge = if (remaining_gas_before_charge >= gas_cost)
                remaining_gas_before_charge - gas_cost
            else
                0;
            // EIP-150: all but 1/64th (introduced in Tangerine Whistle)
            // Before EIP-150: forward all remaining gas
            const max_gas = if (evm.hardfork.isAtLeast(.TANGERINE_WHISTLE))
                gas_after_charge - (gas_after_charge / 64)
            else
                gas_after_charge;
            const available_gas = @min(gas_limit, max_gas);

            // NOW charge the total cost (base cost + forwarded gas)
            // Per Python: charge_gas(evm, message_call_gas.cost + extend_memory.cost)
            // where message_call_gas.cost = gas + extra_gas
            const total_cost = gas_cost + available_gas;
            try frame.consumeGas(total_cost);

            // Read input data from memory
            var input_data: []const u8 = &.{};
            if (in_length > 0 and in_length <= std.math.maxInt(u32)) {
                const in_off = std.math.cast(u32, in_offset) orelse return error.OutOfBounds;
                const in_len = std.math.cast(u32, in_length) orelse return error.OutOfBounds;

                // Check if in_off + in_len would overflow
                const end_offset = in_off +% in_len;
                if (end_offset >= in_off) {
                    const data = try frame.allocator.alloc(u8, in_len);
                    var j: u32 = 0;
                    while (j < in_len) : (j += 1) {
                        const addr = try add_u32(in_off, j);
                        data[j] = frame.readMemory(addr);
                    }
                    input_data = data;
                }
                // else: overflow occurred, use empty input data
            }
            // Note: No defer free needed - arena allocator will clean up

            // Perform the inner call (DELEGATECALL)
            const params = CallParams{ .delegatecall = .{
                .caller = frame.caller,
                .to = call_address,
                .input = input_data,
                .gas = available_gas,
            } };
            const result = evm.inner_call(params);

            // Write output to memory
            if (out_length > 0 and result.output.len > 0) {
                const out_off = std.math.cast(u32, out_offset) orelse return error.OutOfBounds;
                const out_len_u32 = std.math.cast(u32, out_length) orelse return error.OutOfBounds;
                const result_len_u32 = std.math.cast(u32, result.output.len) orelse return error.OutOfBounds;
                const copy_len = @min(out_len_u32, result_len_u32);

                var k: u32 = 0;
                while (k < copy_len) : (k += 1) {
                    const addr = try add_u32(out_off, k);
                    try frame.writeMemory(addr, result.output[k]);
                }
            }

            // Store return data
            frame.return_data = result.output;

            // Push success status
            try frame.pushStack(if (result.success) 1 else 0);

            // Refund unused gas
            // Per Python: evm.gas_left += child_evm.gas_left
            // Cap refund at available_gas to prevent overflow if child somehow returns more than allocated
            const gas_to_refund = @min(result.gas_left, available_gas);
            const gas_to_refund_i64 = std.math.cast(i64, gas_to_refund) orelse std.math.maxInt(i64);
            frame.gas_remaining = @min(frame.gas_remaining + gas_to_refund_i64, std.math.maxInt(i64));

            frame.pc += 1;
        }

        /// STATICCALL opcode (0xfa) - Static message call (no state modifications allowed)
        pub fn staticcall(frame: *FrameType) FrameType.EvmError!void {
            const evm = frame.getEvm();

            // EIP-214: STATICCALL was introduced in Byzantium hardfork
            if (evm.hardfork.isBefore(.BYZANTIUM)) return error.InvalidOpcode;

            // Pop all 6 arguments (no value for static call)
            const gas = try frame.popStack();
            const address_u256 = try frame.popStack();
            const in_offset = try frame.popStack();
            const in_length = try frame.popStack();
            const out_offset = try frame.popStack();
            const out_length = try frame.popStack();

            // Convert address
            var addr_bytes: [20]u8 = undefined;
            var i: usize = 0;
            while (i < 20) : (i += 1) {
                addr_bytes[19 - i] = @as(u8, @truncate(address_u256 >> @intCast(i * 8)));
            }
            const call_address = Address{ .bytes = addr_bytes };

            // Gas cost calculation based on hardfork
            var call_gas_cost: u64 = 0;

            // EIP-2929 (Berlin+): Use warm/cold access costs instead of flat base cost
            // EIP-150 (Tangerine Whistle): Changed base cost from 40 to 700
            // Pre-Tangerine Whistle: Use 40 gas base cost
            if (evm.hardfork.isBefore(.BERLIN)) {
                call_gas_cost = if (evm.hardfork.isBefore(.TANGERINE_WHISTLE)) 40 else GasConstants.CallGas;
            }

            // EIP-2929 (Berlin+): access target account (warm/cold)
            // Returns 0 for pre-Berlin, 100 for warm, 2600 for cold in Berlin+
            const access_cost = try evm.accessAddress(call_address);
            call_gas_cost += access_cost;

            // Calculate memory expansion cost for BOTH input and output regions together
            const in_end = if (in_length > 0) @as(u64, @intCast(in_offset)) + @as(u64, @intCast(in_length)) else 0;
            const out_end = if (out_length > 0) @as(u64, @intCast(out_offset)) + @as(u64, @intCast(out_length)) else 0;
            const max_end = @max(in_end, out_end);
            if (max_end > 0) {
                const mem_cost = frame.memoryExpansionCost(max_end);
                call_gas_cost += mem_cost;
                // Update memory_size immediately after charging (matches Python behavior)
                // Python: evm.memory += b"\x00" * extend_memory.expand_by
                const aligned_size = wordAlignedSize(max_end);
                if (aligned_size > frame.memory_size) frame.memory_size = aligned_size;
            }

            // Calculate available gas BEFORE charging (per Python execution-specs)
            const gas_limit = if (gas > std.math.maxInt(u64)) std.math.maxInt(u64) else @as(u64, @intCast(gas));
            const remaining_gas_before_charge = @as(u64, @intCast(@max(frame.gas_remaining, 0)));
            const gas_after_charge = if (remaining_gas_before_charge >= call_gas_cost)
                remaining_gas_before_charge - call_gas_cost
            else
                0;
            // EIP-150: all but 1/64th (introduced in Tangerine Whistle)
            // Before EIP-150: forward all remaining gas
            const max_gas = if (evm.hardfork.isAtLeast(.TANGERINE_WHISTLE))
                gas_after_charge - (gas_after_charge / 64)
            else
                gas_after_charge;
            const available_gas = @min(gas_limit, max_gas);

            // NOW charge the total cost (base cost + forwarded gas)
            // Per Python: charge_gas(evm, message_call_gas.cost + extend_memory.cost)
            // where message_call_gas.cost = gas + extra_gas
            const total_cost = call_gas_cost + available_gas;
            try frame.consumeGas(total_cost);

            // Read input data from memory
            var input_data: []const u8 = &.{};
            if (in_length > 0 and in_length <= std.math.maxInt(u32)) {
                const in_off = std.math.cast(u32, in_offset) orelse return error.OutOfBounds;
                const in_len = std.math.cast(u32, in_length) orelse return error.OutOfBounds;

                // Check if in_off + in_len would overflow
                const end_offset = in_off +% in_len;
                if (end_offset >= in_off) {
                    const data = try frame.allocator.alloc(u8, in_len);
                    var j: u32 = 0;
                    while (j < in_len) : (j += 1) {
                        const addr = try add_u32(in_off, j);
                        data[j] = frame.readMemory(addr);
                    }
                    input_data = data;
                }
                // else: overflow occurred, use empty input data
            }
            // Note: No defer free needed - arena allocator will clean up

            // Perform the inner call (STATICCALL)
            const params = CallParams{ .staticcall = .{
                .caller = frame.address,
                .to = call_address,
                .input = input_data,
                .gas = available_gas,
            } };
            const result = evm.inner_call(params);

            // Write output to memory
            if (out_length > 0 and result.output.len > 0) {
                const out_off = std.math.cast(u32, out_offset) orelse return error.OutOfBounds;
                const out_len_u32 = std.math.cast(u32, out_length) orelse return error.OutOfBounds;
                const result_len_u32 = std.math.cast(u32, result.output.len) orelse return error.OutOfBounds;
                const copy_len = @min(out_len_u32, result_len_u32);

                var k: u32 = 0;
                while (k < copy_len) : (k += 1) {
                    const addr = try add_u32(out_off, k);
                    try frame.writeMemory(addr, result.output[k]);
                }
            }

            // Store return data
            frame.return_data = result.output;

            // Push success status
            try frame.pushStack(if (result.success) 1 else 0);

            // Refund unused gas
            // Per Python: evm.gas_left += child_evm.gas_left
            // Cap refund at available_gas to prevent overflow if child somehow returns more than allocated
            const gas_to_refund = @min(result.gas_left, available_gas);
            const gas_to_refund_i64 = std.math.cast(i64, gas_to_refund) orelse std.math.maxInt(i64);
            frame.gas_remaining = @min(frame.gas_remaining + gas_to_refund_i64, std.math.maxInt(i64));

            frame.pc += 1;
        }

        /// CREATE2 opcode (0xf5) - Create a new contract with deterministic address
        pub fn create2(frame: *FrameType) FrameType.EvmError!void {
            const evm = frame.getEvm();

            // EIP-1014: CREATE2 opcode was introduced in Constantinople hardfork
            if (evm.hardfork.isBefore(.CONSTANTINOPLE)) return error.InvalidOpcode;

            // EIP-214: CREATE2 cannot be executed in static call context
            if (frame.is_static) return error.StaticCallViolation;

            // Clear return_data at the start (per Python reference implementation)
            frame.return_data = &[_]u8{};

            const value = try frame.popStack();
            const offset = try frame.popStack();
            const length = try frame.popStack();
            const salt = try frame.popStack();

            const len = std.math.cast(u32, length) orelse return error.OutOfBounds;
            const gas_cost = frame.create2GasCost(len);
            try frame.consumeGas(gas_cost);

            // Read init code from memory
            var init_code: []const u8 = &.{};
            if (length > 0 and length <= std.math.maxInt(u32)) {
                const off = std.math.cast(u32, offset) orelse return error.OutOfBounds;

                // Check memory bounds and charge for expansion
                const end_bytes = @as(u64, off) + @as(u64, len);
                const mem_cost = frame.memoryExpansionCost(end_bytes);
                try frame.consumeGas(mem_cost);

                // Update logical memory size
                const aligned = wordAlignedSize(end_bytes);
                if (aligned > frame.memory_size) frame.memory_size = aligned;

                const code = try frame.allocator.alloc(u8, len);
                var j: u32 = 0;
                while (j < len) : (j += 1) {
                    const addr = try add_u32(off, j);
                    code[j] = frame.readMemory(addr);
                }
                init_code = code;
            }

            // Calculate available gas
            const remaining_gas = @as(u64, @intCast(@max(frame.gas_remaining, 0)));
            // EIP-150: all but 1/64th (introduced in Tangerine Whistle)
            // Before EIP-150: forward all remaining gas
            const max_gas = if (evm.hardfork.isAtLeast(.TANGERINE_WHISTLE))
                remaining_gas - (remaining_gas / 64)
            else
                remaining_gas;

            // Perform CREATE2 with salt
            const result = try evm.inner_create(value, init_code, max_gas, salt);

            // Update gas
            const gas_used = max_gas - result.gas_left;
            // Safely cast gas_used - if it exceeds i64::MAX, clamp gas_remaining to 0
            const gas_used_i64 = std.math.cast(i64, gas_used) orelse {
                frame.gas_remaining = 0;
                return error.OutOfGas;
            };
            frame.gas_remaining -= gas_used_i64;

            // Set return_data according to EIP-1014:
            // - On success: return_data is empty
            // - On failure: return_data is the child's output
            if (result.success) {
                frame.return_data = &[_]u8{};
            } else {
                frame.return_data = result.output;
            }

            // Push address onto stack (0 if failed)
            const addr_u256 = if (result.success) blk: {
                var val: u256 = 0;
                for (result.address.bytes) |b| {
                    val = (val << 8) | b;
                }
                break :blk val;
            } else 0;
            try frame.pushStack(addr_u256);

            frame.pc += 1;
        }

        /// SELFDESTRUCT opcode (0xff) - Halt execution and register account for deletion
        pub fn selfdestruct(frame: *FrameType) FrameType.EvmError!void {
            const beneficiary_u256 = try frame.popStack();

            // Convert beneficiary to address
            var beneficiary_bytes: [20]u8 = undefined;
            var i: usize = 0;
            while (i < 20) : (i += 1) {
                beneficiary_bytes[19 - i] = @truncate(beneficiary_u256 >> @intCast(i * 8));
            }
            const beneficiary = Address{ .bytes = beneficiary_bytes };

            const evm_ptr = frame.getEvm();

            // Calculate gas cost (EIP-6780/Berlin)
            // Base: 5000 gas
            // +2600 if beneficiary is cold (EIP-2929/Berlin)
            // +25000 if beneficiary doesn't exist and we have balance
            var gas_cost = frame.selfdestructGasCost();

            // EIP-2929 (Berlin): Check if beneficiary is warm, add cold access cost if needed
            // Per Python reference: if beneficiary not in evm.accessed_addresses, add it and charge cold access
            // IMPORTANT: Unlike CALL which always charges an access cost (warm=100 or cold=2600),
            // SELFDESTRUCT only charges if the beneficiary is cold (not already accessed)
            if (frame.hardfork.isAtLeast(.BERLIN)) {
                const is_warm = evm_ptr.access_list_manager.isAddressWarm(beneficiary);
                if (!is_warm) {
                    // Mark as warm and charge cold access cost
                    // We must mark it warm BEFORE charging to match Python's behavior
                    // (Python: evm.accessed_addresses.add(beneficiary) then gas_cost += GAS_COLD_ACCOUNT_ACCESS)
                    _ = try evm_ptr.access_list_manager.warm_addresses.getOrPut(beneficiary);
                    gas_cost += GasConstants.ColdAccountAccessCost; // +2600
                }
                // If already warm: no additional cost (unlike CALL which charges 100 for warm access)
            }

            const self_balance = if (evm_ptr.host) |h|
                h.getBalance(frame.address)
            else
                evm_ptr.balances.get(frame.address) orelse 0;

            // Check if beneficiary is alive (has code, balance, or nonce)
            // Add new account cost if not alive and we have balance
            if (self_balance > 0) {
                const beneficiary_is_alive = blk: {
                    if (evm_ptr.host) |h| {
                        const has_balance = h.getBalance(beneficiary) > 0;
                        const has_code = h.getCode(beneficiary).len > 0;
                        const has_nonce = h.getNonce(beneficiary) > 0;
                        break :blk has_balance or has_code or has_nonce;
                    } else {
                        const has_balance = (evm_ptr.balances.get(beneficiary) orelse 0) > 0;
                        const has_code = (evm_ptr.code.get(beneficiary) orelse &[_]u8{}).len > 0;
                        const has_nonce = (evm_ptr.nonces.get(beneficiary) orelse 0) > 0;
                        break :blk has_balance or has_code or has_nonce;
                    }
                };
                if (!beneficiary_is_alive) {
                    gas_cost += GasConstants.CallNewAccountGas; // +25000 for creating new account
                }
            }

            try frame.consumeGas(gas_cost);

            // EIP-214: SELFDESTRUCT cannot be executed in static call context
            // This check must happen AFTER gas charging (Python reference line 525)
            if (frame.is_static) return error.StaticCallViolation;

            // Transfer balance from originator to beneficiary
            // Pre-Cancun vs Cancun+ have different balance transfer semantics
            if (frame.hardfork.isAtLeast(.CANCUN)) {
                // EIP-6780 (Cancun+): Use move_ether semantics
                // This follows the Python reference implementation's move_ether function:
                // 1. Reduce sender balance by amount
                // 2. Increase recipient balance by amount
                // When sender == recipient, the balance stays the same (decreased then increased)

                // Always call move_ether, even if balance is 0 (Python always calls it)
                // Step 1: Reduce originator balance
                try evm_ptr.setBalanceWithSnapshot(frame.address, 0);

                // Step 2: Increase beneficiary balance
                // IMPORTANT: Must read beneficiary balance AFTER step 1 to handle sender == recipient case
                const beneficiary_balance = if (evm_ptr.host) |h|
                    h.getBalance(beneficiary)
                else
                    evm_ptr.balances.get(beneficiary) orelse 0;
                try evm_ptr.setBalanceWithSnapshot(beneficiary, beneficiary_balance + self_balance);
            } else {
                // Pre-Cancun: Use old balance transfer logic
                // Per Python reference (Shanghai): Read beneficiary balance BEFORE modifying anything
                // This ensures correct behavior when beneficiary == originator
                const beneficiary_balance = if (evm_ptr.host) |h|
                    h.getBalance(beneficiary)
                else
                    evm_ptr.balances.get(beneficiary) orelse 0;

                // First Transfer to beneficiary (Python comment)
                try evm_ptr.setBalanceWithSnapshot(beneficiary, beneficiary_balance + self_balance);

                // Next, Zero the balance of the address being deleted (must come after
                // sending to beneficiary in case the contract named itself as the beneficiary).
                // (Python comment)
                try evm_ptr.setBalanceWithSnapshot(frame.address, 0);
            }

            // EIP-6780 (Cancun+): Only delete if created in same transaction
            // Pre-Cancun: Always delete the account
            if (frame.hardfork.isAtLeast(.CANCUN)) {
                // EIP-6780: Mark account for deletion ONLY if created in same transaction
                const was_created_this_tx = evm_ptr.created_accounts.contains(frame.address);

                if (was_created_this_tx) {
                    // Mark for deletion - actual deletion at end of transaction
                    try evm_ptr.selfdestructed_accounts.put(frame.address, {});

                    // EIP-6780: Set originator balance to 0 UNCONDITIONALLY when created in same tx
                    // This matches Python reference: set_account_balance(state, originator, U256(0))
                    // This is needed for the self-destruct-to-self case where beneficiary == originator
                    // to burn the ether (overriding move_ether's balance increase)
                    try evm_ptr.setBalanceWithSnapshot(frame.address, 0);
                }
                // If not created in same tx: balance transferred but code/storage/nonce persist
            } else {
                // Pre-Cancun behavior: Always mark for deletion
                try evm_ptr.selfdestructed_accounts.put(frame.address, {});
            }

            // Apply refund to EVM's gas_refund counter
            const refund = frame.selfdestructRefund();
            if (refund > 0) {
                evm_ptr.gas_refund += refund;
            }

            frame.stopped = true;
        }
    };
}
