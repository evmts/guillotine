const std = @import("std");
const log = @import("../log.zig");
const FrameConfig = @import("../frame/frame_config.zig").FrameConfig;
const primitives = @import("voltaire");
const Address = primitives.Address;
// Access to call params through the call params module
const call_params_mod = @import("../frame/call_params.zig");
const Opcode = @import("../opcodes/opcode_data.zig").Opcode;
// u256 is now a built-in type in Zig 0.14+

/// System opcode handlers for the EVM stack frame.
/// These handle calls, contract creation, and execution control.
pub fn Handlers(FrameType: type) type {
    return struct {
        pub const Error = FrameType.Error;
        pub const Dispatch = FrameType.Dispatch;
        pub const WordType = FrameType.WordType;
        const config = FrameType.frame_config;

        // Use default configuration for CallParams - this maintains backward compatibility
        const CallParams = call_params_mod.CallParams(.{});
        const address_utils = @import("address_utils.zig");

        const dispatch_next = @import("dispatch_next.zig");
        const fork_gas = @import("../frame/fork_gas.zig");
        const GasConstants = primitives.GasConstants;
        const hardfork = FrameType.config.hardfork;

        const CallKind = enum { call, callcode, delegatecall, staticcall };

        /// End (exclusive) of the memory range `[offset, offset + size)`, or 0 for an empty
        /// range, whatever its offset. Null when the range lies beyond the memory limit:
        /// no gas limit can pay for such an expansion, so callers halt with OutOfGas.
        fn memoryEnd(offset: WordType, size: WordType) ?u32 {
            if (size == 0) return 0;
            const limit: u32 = std.math.maxInt(u24);
            if (offset > limit or size > limit) return null;
            const end: u32 = @as(u32, @intCast(offset)) + @as(u32, @intCast(size));
            if (end > limit) return null;
            return end;
        }

        /// Deduct `amount` from the gas left. False when the frame cannot pay.
        fn chargeGas(self: *FrameType, amount: u64) bool {
            const charge = std.math.cast(FrameType.GasType, amount) orelse return false;
            if (charge > self.gas_remaining) return false;
            self.gas_remaining -= charge;
            return true;
        }

        /// True when `addr` does not exist or is empty (EIP-161 "dead").
        fn isDeadAccount(self: *FrameType, addr: Address) Error!bool {
            const account = self.getEvm().database.get_account(addr.bytes) catch return Error.AllocationError;
            if (account) |existing| return existing.is_empty();
            return true;
        }

        /// CALL, CALLCODE, DELEGATECALL and STATICCALL (execution-specs
        /// `vm/instructions/system.py`). The flat price of the opcode (40, 700 or the
        /// warm access cost, by fork) is static gas already charged with the basic
        /// block; this charges memory expansion, the cold surcharge, the value-transfer
        /// and new-account costs and the gas forwarded to the callee.
        fn callFamily(self: *FrameType, cursor: [*]const Dispatch.Item, comptime kind: CallKind) Error!noreturn {
            const opcode: Dispatch.UnifiedOpcode = comptime switch (kind) {
                .call => .CALL,
                .callcode => .CALLCODE,
                .delegatecall => .DELEGATECALL,
                .staticcall => .STATICCALL,
            };
            const has_value_argument = comptime (kind == .call or kind == .callcode);

            self.beforeInstruction(opcode, cursor);
            (&self.getEvm().tracer).assert(self.stack.size() >= (if (has_value_argument) 7 else 6), "CALL-family opcode requires its stack arguments");

            const gas_param = self.stack.pop_unsafe();
            const address_word = self.stack.pop_unsafe();
            const value: WordType = if (has_value_argument) self.stack.pop_unsafe() else 0;
            const input_offset = self.stack.pop_unsafe();
            const input_size = self.stack.pop_unsafe();
            const output_offset = self.stack.pop_unsafe();
            const output_size = self.stack.pop_unsafe();

            const addr = address_utils.fromWord(WordType, address_word);
            const evm = self.getEvm();

            // Memory expansion covers the input and the output range. A range that no gas
            // limit can pay for is an out-of-gas halt, never a failed call.
            const input_end = memoryEnd(input_offset, input_size) orelse {
                self.afterComplete(opcode);
                return Error.OutOfGas;
            };
            const output_end = memoryEnd(output_offset, output_size) orelse {
                self.afterComplete(opcode);
                return Error.OutOfGas;
            };
            const memory_end = @max(input_end, output_end);
            const memory_cost: u64 = if (memory_end > 0) self.memory.get_expansion_cost(memory_end) else 0;

            // EIP-2929 (Berlin+): cold surcharge on top of the warm cost charged statically.
            // Earlier forks report the warm cost for every access, so the surcharge is 0.
            const access_cost = evm.access_address(addr) catch {
                self.afterComplete(opcode);
                return Error.AllocationError;
            };
            var extra_gas: u64 = access_cost -| fork_gas.warm_access_cost;

            if (value != 0) extra_gas += GasConstants.CallValueTransferGas;

            if (comptime kind == .call) {
                // New-account surcharge. Spurious Dragon+ (EIP-161): only when value goes to
                // a dead account. Earlier forks: whenever the target does not exist.
                const charge_new_account = if (comptime fork_gas.newAccountNeedsValue(hardfork))
                    value != 0 and try isDeadAccount(self, addr)
                else
                    !evm.database.account_exists(addr.bytes);
                if (charge_new_account) extra_gas += fork_gas.new_account_gas;
            }

            if (!chargeGas(self, memory_cost + extra_gas)) {
                self.afterComplete(opcode);
                return Error.OutOfGas;
            }

            // EIP-214: sending value from a static context is an exceptional halt.
            if (comptime kind == .call) {
                if (value != 0 and evm.is_static_context()) {
                    self.afterComplete(opcode);
                    return Error.WriteProtection;
                }
            }

            if (memory_end > 0) {
                self.memory.ensure_capacity(evm.getCallArenaAllocator(), memory_end) catch {
                    self.afterComplete(opcode);
                    return Error.AllocationError;
                };
            }

            // Gas forwarded to the callee, taken from what is left after the costs above.
            // EIP-150 (Tangerine Whistle+): at most all but one 64th. Earlier forks forward
            // exactly the requested amount and halt when it is not available.
            const available: u64 = @intCast(self.gas_remaining);
            const forwarded: u64 = if (comptime fork_gas.hasAllButOne64th(hardfork)) blk: {
                const requested: u64 = if (gas_param > std.math.maxInt(u64)) std.math.maxInt(u64) else @intCast(gas_param);
                break :blk @min(requested, available - available / 64);
            } else blk: {
                if (gas_param > available) {
                    self.afterComplete(opcode);
                    return Error.OutOfGas;
                }
                break :blk @intCast(gas_param);
            };
            self.gas_remaining -= @intCast(forwarded);

            // A value transfer adds the 2300 stipend to the callee's gas at no cost to
            // the caller; what the callee does not use comes back with its leftover gas.
            const stipend: u64 = if (value != 0) GasConstants.CallStipend else 0;

            const input: []const u8 = if (input_size != 0)
                self.memory.get_slice(@intCast(input_offset), @intCast(input_size)) catch {
                    self.afterComplete(opcode);
                    return Error.OutOfBounds;
                }
            else
                &.{};

            const params: CallParams = switch (kind) {
                .call => .{ .call = .{
                    .caller = self.contract_address,
                    .to = addr,
                    .value = value,
                    .input = input,
                    .gas = forwarded + stipend,
                } },
                .callcode => .{ .callcode = .{
                    .caller = self.contract_address,
                    .to = addr,
                    .value = value,
                    .input = input,
                    .gas = forwarded + stipend,
                } },
                // DELEGATECALL keeps this frame's sender and runs with this contract's
                // address and storage.
                .delegatecall => .{ .delegatecall = .{
                    .caller = self.caller,
                    .to = addr,
                    .input = input,
                    .gas = forwarded,
                    .context_address = self.contract_address,
                } },
                .staticcall => .{ .staticcall = .{
                    .caller = self.contract_address,
                    .to = addr,
                    .input = input,
                    .gas = forwarded,
                } },
            };

            // The result's output lives in the call arena; only the trace owns memory.
            var result = evm.inner_call(params);
            defer if (result.trace) |*trace| trace.deinit();

            // Unused callee gas (including unused stipend, and all of it when the call
            // was refused for depth or balance) returns to this frame.
            const returned = std.math.cast(FrameType.GasType, result.gas_left) orelse {
                self.afterComplete(opcode);
                return Error.GasOverflow;
            };
            self.gas_remaining += returned;

            // RETURN data and REVERT data are both copied to the output range.
            const copy_len: usize = @min(@as(usize, @intCast(output_size)), result.output.len);
            if (copy_len > 0) {
                self.memory.set_data(evm.getCallArenaAllocator(), @intCast(output_offset), result.output[0..copy_len]) catch {
                    self.afterComplete(opcode);
                    return Error.AllocationError;
                };
            }

            (&evm.tracer).assert(self.stack.size() < @TypeOf(self.stack).stack_capacity, "Stack must have space for push");
            self.stack.push_unsafe(if (result.success) 1 else 0);
            return dispatch_next.nextInstruction(FrameType, self, cursor, opcode);
        }

        /// CALL opcode (0xf1) - Message-call into an account.
        /// Stack: [gas, address, value, input_offset, input_size, output_offset, output_size] → [success]
        pub fn call(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            return callFamily(self, cursor, .call);
        }

        /// CALLCODE opcode (0xf2) - Message-call with alternative account's code but current context.
        /// Stack: [gas, address, value, input_offset, input_size, output_offset, output_size] → [success]
        pub fn callcode(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            return callFamily(self, cursor, .callcode);
        }

        /// DELEGATECALL opcode (0xf4) - Message-call with alternative account's code, keeping sender and value.
        /// Stack: [gas, address, input_offset, input_size, output_offset, output_size] → [success]
        pub fn delegatecall(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            return callFamily(self, cursor, .delegatecall);
        }

        /// STATICCALL opcode (0xfa) - Static message-call into an account.
        /// Stack: [gas, address, input_offset, input_size, output_offset, output_size] → [success]
        pub fn staticcall(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            return callFamily(self, cursor, .staticcall);
        }

        /// CREATE and CREATE2 (execution-specs `vm/instructions/system.py`).
        ///
        /// The opcode's whole charge is dynamic: memory expansion, CreateGas, the
        /// EIP-3860 init code word cost (Shanghai+) and, for CREATE2, the hash cost. A
        /// frame that cannot pay it, that runs in a static context, or whose init code
        /// exceeds the EIP-3860 limit halts exceptionally. It does not push 0 and go on.
        fn createFamily(self: *FrameType, cursor: [*]const Dispatch.Item, comptime is_create2: bool) Error!noreturn {
            const opcode: Dispatch.UnifiedOpcode = comptime if (is_create2) .CREATE2 else .CREATE;

            self.beforeInstruction(opcode, cursor);
            (&self.getEvm().tracer).assert(self.stack.size() >= (if (is_create2) 4 else 3), "CREATE-family opcode requires its stack arguments");

            const value = self.stack.pop_unsafe();
            const offset = self.stack.pop_unsafe();
            const size = self.stack.pop_unsafe();
            const salt: WordType = if (is_create2) self.stack.pop_unsafe() else 0;

            const evm = self.getEvm();

            // Memory for the init code is charged like any other memory access. A
            // zero-size init code touches no memory, whatever the offset.
            const memory_end = memoryEnd(offset, size) orelse {
                self.afterComplete(opcode);
                return Error.OutOfGas;
            };
            const memory_cost: u64 = if (memory_end > 0) self.memory.get_expansion_cost(memory_end) else 0;
            if (!chargeGas(self, memory_cost)) {
                self.afterComplete(opcode);
                return Error.OutOfGas;
            }

            // EIP-3860 (Shanghai+): init code longer than 49152 bytes is an out-of-gas halt
            // of the creating frame.
            const init_code_len: u64 = @intCast(size);
            if (comptime hardfork.isAtLeast(.SHANGHAI)) {
                if (init_code_len > GasConstants.MaxInitcodeSize) {
                    self.afterComplete(opcode);
                    return Error.OutOfGas;
                }
            }

            // CreateGas, the init code word cost and the CREATE2 hash cost are deducted by
            // Evm.executeCreate / executeCreate2 from the gas passed in. The frame must be
            // able to pay them, otherwise it halts out of gas here.
            const words: u64 = (init_code_len + 31) / 32;
            var overhead: u64 = GasConstants.CreateGas;
            if (comptime hardfork.isAtLeast(.SHANGHAI)) overhead += words * GasConstants.InitcodeWordGas;
            if (is_create2) overhead += words * GasConstants.Keccak256WordGas;
            const available: u64 = @intCast(self.gas_remaining);
            if (available < overhead) {
                self.afterComplete(opcode);
                return Error.OutOfGas;
            }

            // EIP-214: creation in a static context is an exceptional halt.
            if (evm.is_static_context()) {
                self.afterComplete(opcode);
                return Error.WriteProtection;
            }

            var init_code: []const u8 = &.{};
            if (memory_end > 0) {
                self.memory.ensure_capacity(evm.getCallArenaAllocator(), memory_end) catch {
                    self.afterComplete(opcode);
                    return Error.AllocationError;
                };
                init_code = self.memory.get_slice(@intCast(offset), @intCast(size)) catch {
                    self.afterComplete(opcode);
                    return Error.OutOfBounds;
                };
            }

            const params: CallParams = if (is_create2) .{ .create2 = .{
                .caller = self.contract_address,
                .value = value,
                .init_code = init_code,
                .salt = salt,
                .gas = available,
            } } else .{ .create = .{
                .caller = self.contract_address,
                .value = value,
                .init_code = init_code,
                .gas = available,
            } };

            // The result's output lives in the call arena; only the trace owns memory.
            // Evm.inner_call maintains the EIP-211 return data buffer.
            var result = evm.inner_call(params);
            defer if (result.trace) |*trace| trace.deinit();

            self.gas_remaining = std.math.cast(FrameType.GasType, result.gas_left) orelse {
                self.afterComplete(opcode);
                return Error.GasOverflow;
            };

            // Push created contract address or 0 on failure
            (&evm.tracer).assert(self.stack.size() < @TypeOf(self.stack).stack_capacity, "Stack must have space for push");
            if (result.success and result.created_address != null) {
                self.stack.push_unsafe(address_utils.toWord(WordType, result.created_address.?));
            } else {
                self.stack.push_unsafe(0);
            }
            return dispatch_next.nextInstruction(FrameType, self, cursor, opcode);
        }

        /// CREATE opcode (0xf0) - Create a new account with associated code.
        /// Stack: [value, offset, size] → [address]
        pub fn create(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            return createFamily(self, cursor, false);
        }

        /// CREATE2 opcode (0xf5) - Create a new account with deterministic address.
        /// Stack: [value, offset, size, salt] → [address]
        pub fn create2(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            return createFamily(self, cursor, true);
        }

        /// RETURN opcode (0xf3) - Halt execution returning output data.
        /// Stack: [offset, size] → []
        pub fn @"return"(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            self.beforeInstruction(.RETURN, cursor);
            const dispatch = Dispatch{ .cursor = cursor };
            _ = dispatch;

            if (self.stack.size() < 2) {
                return Error.StackUnderflow;
            }
            {
                (&self.getEvm().tracer).assert(self.stack.size() >= 2, "RETURN requires 2 stack items");
            }
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
            // Check if values fit in u24 (memory limit)
            if (offset_usize > std.math.maxInt(u24) or size_usize > std.math.maxInt(u24) or memory_end > std.math.maxInt(u24)) {
                return Error.OutOfBounds;
            }
            const memory_expansion_cost = self.memory.get_expansion_cost(@as(u32, @intCast(memory_end)));
            // Use negative gas pattern for single-branch out-of-gas detection
            self.gas_remaining -= @intCast(memory_expansion_cost);
            if (self.gas_remaining < 0) {
                return Error.OutOfGas;
            }

            // Ensure memory capacity (memory_end is guaranteed to fit in u24 from check above)
            self.memory.ensure_capacity(self.getEvm().getCallArenaAllocator(), @as(u32, @intCast(memory_end))) catch return Error.OutOfBounds;

            // Extract return data from memory and store it in thread-local storage
            if (size_usize > 0) {
                const return_data = self.memory.get_slice(@as(u32, @intCast(offset_usize)), @as(u32, @intCast(size_usize))) catch {
                    return Error.OutOfBounds;
                };
                // Allocate and copy output to thread-local storage
                const new_output = self.getEvm().getCallArenaAllocator().alloc(u8, return_data.len) catch {
                    return Error.AllocationError;
                };
                @memcpy(new_output, return_data);
                self.output_data = new_output;
            } else {
                // Empty return data
                self.output_data = &.{};
            }

            // Return indicates successful execution
            self.afterComplete(.RETURN);
            return Error.Return;
        }

        /// REVERT opcode (0xfd) - Halt execution reverting state changes.
        /// Stack: [offset, size] → []
        pub fn revert(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            self.beforeInstruction(.REVERT, cursor);
            const dispatch = Dispatch{ .cursor = cursor };
            _ = dispatch;
            {
                (&self.getEvm().tracer).assert(self.stack.size() >= 2, "REVERT requires 2 stack items");
            }
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
            // Check if values fit in u24 (memory limit)
            if (offset_usize > std.math.maxInt(u24) or size_usize > std.math.maxInt(u24) or memory_end > std.math.maxInt(u24)) {
                return Error.OutOfBounds;
            }
            const memory_expansion_cost = self.memory.get_expansion_cost(@as(u32, @intCast(memory_end)));
            // Use negative gas pattern for single-branch out-of-gas detection
            self.gas_remaining -= @intCast(memory_expansion_cost);
            if (self.gas_remaining < 0) {
                return Error.OutOfGas;
            }

            // Ensure memory capacity (memory_end is guaranteed to fit in u24 from check above)
            self.memory.ensure_capacity(self.getEvm().getCallArenaAllocator(), @as(u32, @intCast(memory_end))) catch return Error.OutOfBounds;

            // Extract revert data from memory and store it in thread-local storage
            if (size_usize > 0) {
                const revert_data = self.memory.get_slice(@as(u32, @intCast(offset_usize)), @as(u32, @intCast(size_usize))) catch {
                    return Error.OutOfBounds;
                };
                // Allocate and copy output to thread-local storage
                const revert_output = self.getEvm().getCallArenaAllocator().alloc(u8, revert_data.len) catch {
                    return Error.AllocationError;
                };
                @memcpy(revert_output, revert_data);
                self.output_data = revert_output;
            } else {
                // Empty revert data
                self.output_data = &[_]u8{};
            }

            // Reduce log noise: no verbose REVERT logging

            // Always return REVERT error for proper handling
            self.afterComplete(.REVERT);
            return Error.REVERT;
        }

        /// SELFDESTRUCT opcode (0xff) - Halt execution and mark account for later deletion.
        /// Stack: [recipient] → []
        /// EIP-214: STATICCALL prevents SELFDESTRUCT via null self_destruct and static host
        pub fn selfdestruct(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            self.beforeInstruction(.SELFDESTRUCT, cursor);
            {
                (&self.getEvm().tracer).assert(self.stack.size() >= 1, "SELFDESTRUCT requires 1 stack item");
            }
            const recipient_u256 = self.stack.pop_unsafe();
            const recipient = address_utils.fromWord(WordType, recipient_u256);
            const evm = self.getEvm();

            // The flat price (0 before Tangerine Whistle, 5000 after) is static gas. The
            // dynamic part follows execution-specs `selfdestruct`.
            var extra_gas: u64 = 0;

            // EIP-2929 (Berlin+): a cold beneficiary costs the full cold access price.
            // SELFDESTRUCT has no warm access charge.
            const access_cost = evm.access_address(recipient) catch {
                self.afterComplete(.SELFDESTRUCT);
                return Error.AllocationError;
            };
            if (comptime fork_gas.hasAccessLists(hardfork)) {
                if (access_cost > fork_gas.warm_access_cost) extra_gas += fork_gas.cold_account_access_cost;
            }

            // New-account surcharge (EIP-150), restricted by EIP-161 to a dead beneficiary
            // that actually receives a balance.
            if (comptime hardfork.isAtLeast(.TANGERINE_WHISTLE)) {
                const charge_new_account = if (comptime fork_gas.newAccountNeedsValue(hardfork)) blk: {
                    const balance = evm.database.get_balance(self.contract_address.bytes) catch {
                        self.afterComplete(.SELFDESTRUCT);
                        return Error.AllocationError;
                    };
                    break :blk balance != 0 and try isDeadAccount(self, recipient);
                } else !evm.database.account_exists(recipient.bytes);
                if (charge_new_account) extra_gas += fork_gas.new_account_gas;
            }

            if (!chargeGas(self, extra_gas)) {
                self.afterComplete(.SELFDESTRUCT);
                return Error.OutOfGas;
            }

            // Refund (removed by EIP-3529 in London): once per destroyed contract.
            const refund = comptime fork_gas.selfdestructRefund(hardfork);
            const first_destruction = !evm.self_destruct.is_marked_for_destruction(self.contract_address);

            evm.mark_for_destruction(self.contract_address, recipient) catch |err| switch (err) {
                error.StaticCallViolation => {
                    self.afterComplete(.SELFDESTRUCT);
                    return Error.WriteProtection;
                },
                else => {
                    @branchHint(.unlikely);
                    log.debug("SELFDESTRUCT failed with error: {}", .{err});
                    self.afterComplete(.SELFDESTRUCT);
                    return Error.AllocationError;
                },
            };
            if (refund > 0 and first_destruction) evm.add_gas_refund(refund);

            // According to EIP-6780 (Cancun hardfork), SELFDESTRUCT only actually destroys
            // the contract if it was created in the same transaction. This is handled by the host.
            // SELFDESTRUCT always stops execution
            self.afterComplete(.SELFDESTRUCT);
            return Error.SelfDestruct;
        }

        /// STOP opcode (0x00) - Halt execution.
        /// Stack: [] → []
        pub fn stop(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            self.beforeInstruction(.STOP, cursor);

            // EIP-3529 gas refund is applied at the transaction level in evm.zig,
            // not within individual frames. The frame just stops execution.

            self.afterComplete(.STOP);
            return Error.Stop;
        }

        /// AUTH opcode (0xf6) - EIP-3074: Authorize a trusted invoker
        /// Stack: [authority, commitment, sig_v, sig_r, sig_s] → [success]
        pub fn auth(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            self.beforeInstruction(.AUTH, cursor);
            const dispatch = Dispatch{ .cursor = cursor };

            // Pop authorization parameters from stack
            {
                (&self.getEvm().tracer).assert(self.stack.size() >= 5, "AUTH requires 5 stack items");
            }
            const sig_s = self.stack.pop_unsafe();
            const sig_r = self.stack.pop_unsafe();
            const sig_v = self.stack.pop_unsafe();
            const commitment = self.stack.pop_unsafe();
            const authority_u256 = self.stack.pop_unsafe();

            // Convert authority to address
            const authority = address_utils.fromWord(WordType,authority_u256);

            // Validate signature components
            if (sig_v > 28 or sig_r == 0 or sig_s == 0) {
                // Invalid signature, push failure
                self.stack.push_unsafe(0);
                const op_data = dispatch.getOpData(.AUTH);
                self.afterInstruction(.AUTH, op_data.next_handler, op_data.next_cursor.cursor);
                return @call(FrameType.Dispatch.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
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
                self.afterInstruction(.AUTH, op_data.next_handler, op_data.next_cursor.cursor);
                return @call(FrameType.Dispatch.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
            } orelse {
                self.stack.push_unsafe(0);
                const op_data = dispatch.getOpData(.AUTH);
                self.afterInstruction(.AUTH, op_data.next_handler, op_data.next_cursor.cursor);
                return @call(FrameType.Dispatch.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
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

            const recovered = crypto.secp256k1.unauditedRecoverAddress(&message_hash, recovery_id, sig_r, sig_s) catch {
                self.stack.push_unsafe(0);
                const op_data = dispatch.getOpData(.AUTH);
                self.afterInstruction(.AUTH, op_data.next_handler, op_data.next_cursor.cursor);
                return @call(FrameType.Dispatch.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
            };

            // Check if recovered address matches authority
            if (!std.mem.eql(u8, &recovered.bytes, &authority.bytes)) {
                self.stack.push_unsafe(0);
                const op_data = dispatch.getOpData(.AUTH);
                self.afterInstruction(.AUTH, op_data.next_handler, op_data.next_cursor.cursor);
                return @call(FrameType.Dispatch.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
            }

            // Store authorized context in frame
            self.authorized_address = authority;

            // Push success
            {
                (&self.getEvm().tracer).assert(self.stack.size() < @TypeOf(self.stack).stack_capacity, "Stack must have space for push");
            }
            self.stack.push_unsafe(1);
            const op_data = dispatch.getOpData(.AUTH);
            self.afterInstruction(.AUTH, op_data.next_handler, op_data.next_cursor.cursor);
            return @call(FrameType.Dispatch.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
        }

        /// AUTHCALL opcode (0xf7) - EIP-3074: Make a call as an authorized address
        /// Stack: [gas, to, value, input_offset, input_size, output_offset, output_size, auth] → [success]
        pub fn authcall(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            self.beforeInstruction(.AUTHCALL, cursor);
            const dispatch = Dispatch{ .cursor = cursor };

            // Pop call parameters from stack
            {
                (&self.getEvm().tracer).assert(self.stack.size() >= 8, "AUTHCALL requires 8 stack items");
            }
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
                self.afterInstruction(.AUTHCALL, op_data.next_handler, op_data.next_cursor.cursor);
                return @call(FrameType.Dispatch.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
            }

            // Convert to address
            const to_addr = address_utils.fromWord(WordType,to_address);

            // Bounds checking for gas parameter
            if (gas_param > std.math.maxInt(u64)) {
                self.stack.push_unsafe(0);
                const op_data = dispatch.getOpData(.AUTHCALL);
                self.afterInstruction(.AUTHCALL, op_data.next_handler, op_data.next_cursor.cursor);
                return @call(FrameType.Dispatch.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
            }
            // Apply 63/64 gas forwarding rule (EIP-150)
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
                self.stack.push_unsafe(0);
                const op_data = dispatch.getOpData(.AUTHCALL);
                self.afterInstruction(.AUTHCALL, op_data.next_handler, op_data.next_cursor.cursor);
                return @call(FrameType.Dispatch.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
            }

            const input_offset_usize = @as(usize, @intCast(input_offset));
            const input_size_usize = @as(usize, @intCast(input_size));
            const output_offset_usize = @as(usize, @intCast(output_offset));
            const output_size_usize = @as(usize, @intCast(output_size));

            // Calculate memory bounds with overflow checking
            var input_mem_end: usize = 0;
            var output_mem_end: usize = 0;

            if (input_size_usize > 0) {
                const overflow = @addWithOverflow(input_offset_usize, input_size_usize);
                if (overflow[1] != 0) {
                    // Overflow occurred - return failure
                    self.stack.push_unsafe(0);
                    const op_data = dispatch.getOpData(.AUTHCALL);
                    self.afterInstruction(.AUTHCALL, op_data.next_handler, op_data.next_cursor.cursor);
                    return @call(FrameType.Dispatch.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
                }
                input_mem_end = overflow[0];
            }

            if (output_size_usize > 0) {
                const overflow = @addWithOverflow(output_offset_usize, output_size_usize);
                if (overflow[1] != 0) {
                    // Overflow occurred - return failure
                    self.stack.push_unsafe(0);
                    const op_data = dispatch.getOpData(.AUTHCALL);
                    self.afterInstruction(.AUTHCALL, op_data.next_handler, op_data.next_cursor.cursor);
                    return @call(FrameType.Dispatch.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
                }
                output_mem_end = overflow[0];
            }

            const max_mem_end = @max(input_mem_end, output_mem_end);

            // Check if memory expansion exceeds u24 limit (16MB)
            if (max_mem_end > std.math.maxInt(u24)) {
                // Memory expansion exceeds limit - return failure
                self.stack.push_unsafe(0);
                const op_data = dispatch.getOpData(.AUTHCALL);
                self.afterInstruction(.AUTHCALL, op_data.next_handler, op_data.next_cursor.cursor);
                return @call(FrameType.Dispatch.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
            }

            // Calculate and charge memory expansion gas
            if (max_mem_end > 0) {
                const expansion_cost = self.memory.get_expansion_cost(@as(u32, @intCast(max_mem_end)));
                const expansion_cost_i64 = @as(FrameType.GasType, @intCast(expansion_cost));
                self.gas_remaining -= expansion_cost_i64;
                if (self.gas_remaining < 0) {
                    self.afterComplete(.AUTHCALL);
                    return Error.OutOfGas;
                }
            }

            // Ensure memory capacity for input
            if (input_size_usize > 0) {
                const input_end = input_offset_usize + input_size_usize;
                self.memory.ensure_capacity(self.getEvm().getCallArenaAllocator(), @as(u32, @intCast(input_end))) catch {
                    self.stack.push_unsafe(0);
                    const op_data = dispatch.getOpData(.AUTHCALL);
                    self.afterInstruction(.AUTHCALL, op_data.next_handler, op_data.next_cursor.cursor);
                    return @call(FrameType.Dispatch.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
                };
            }

            // Ensure memory capacity for output
            if (output_size_usize > 0) {
                const output_end = output_offset_usize + output_size_usize;
                self.memory.ensure_capacity(self.getEvm().getCallArenaAllocator(), @as(u32, @intCast(output_end))) catch {
                    self.stack.push_unsafe(0);
                    const op_data = dispatch.getOpData(.AUTHCALL);
                    self.afterInstruction(.AUTHCALL, op_data.next_handler, op_data.next_cursor.cursor);
                    return @call(FrameType.Dispatch.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
                };
            }

            // Extract input data
            var input_data: []const u8 = &.{};
            if (input_size_usize > 0) {
                input_data = self.memory.get_slice(@as(u32, @intCast(input_offset_usize)), @as(u32, @intCast(input_size_usize))) catch {
                    self.stack.push_unsafe(0);
                    const op_data = dispatch.getOpData(.AUTHCALL);
                    self.afterInstruction(.AUTHCALL, op_data.next_handler, op_data.next_cursor.cursor);
                    return @call(FrameType.Dispatch.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
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

            // The result's output lives in the call arena; only the trace owns memory.
            var result = self.getEvm().inner_call(params);
            defer if (result.trace) |*trace| trace.deinit();

            // Write return data to memory if successful and output size > 0
            if (result.success and output_size_usize > 0 and result.output.len > 0) {
                const copy_size = @min(output_size_usize, result.output.len);
                self.memory.set_data(self.getEvm().getCallArenaAllocator(), @as(u32, @intCast(output_offset_usize)), result.output[0..copy_size]) catch {
                    self.stack.push_unsafe(0);
                    const op_data = dispatch.getOpData(.AUTHCALL);
                    self.afterInstruction(.AUTHCALL, op_data.next_handler, op_data.next_cursor.cursor);
                    return @call(FrameType.Dispatch.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
                };
            }

            // Return data is now managed by EVM's return_data field
            // which is automatically updated after inner_call

            // Update gas remaining using proper accounting (same as CALL)
            const provided_gas_authcall: u64 = gas_u64;
            const used_gas_authcall: u64 = if (result.gas_left > provided_gas_authcall) 0 else (provided_gas_authcall - result.gas_left);
            const caller_gas_authcall: u64 = @as(u64, @intCast(@max(self.gas_remaining, 0)));
            const new_gas_authcall: u64 = if (used_gas_authcall > caller_gas_authcall) 0 else caller_gas_authcall - used_gas_authcall;
            self.gas_remaining = @as(FrameType.GasType, @intCast(new_gas_authcall));

            // Push success status
            {
                (&self.getEvm().tracer).assert(self.stack.size() < @TypeOf(self.stack).stack_capacity, "Stack must have space for push");
            }
            self.stack.push_unsafe(if (result.success) 1 else 0);
            const op_data = dispatch.getOpData(.AUTHCALL);
            // Use op_data.next_handler and op_data.next_cursor directly
            return @call(FrameType.Dispatch.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
        }
    };
}

// ====== TESTS ======

const testing = std.testing;
const Frame = @import("../frame/frame.zig").Frame;
const dispatch_mod = @import("../preprocessor/dispatch.zig");
const DefaultTracer = @import("../tracer/tracer.zig").DefaultTracer;
const test_address_utils = @import("address_utils.zig");

// Test configuration
const test_config = FrameConfig{
    .stack_size = 1024,
    .WordType = u256,
    .max_bytecode_size = 1024,
    .block_gas_limit = 30_000_000,
    .DatabaseType = @import("../storage/memory_database.zig").MemoryDatabase,
    .memory_initial_capacity = 4096,
    .memory_limit = 0xFFFFFF,
};

const TestFrame = Frame(test_config);

// Mock host for testing
const MockEvm = struct {
    allocator: std.mem.Allocator,
    is_static: bool = false,
    call_result: struct {
        success: bool,
        gas_left: u64,
        output: []const u8,
    },
    create_result: struct {
        success: bool,
        gas_left: u64,
        output: []const u8,
        created_address: ?Address,
    },

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
                .output = &.{},
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
};

fn createTestFrame(allocator: std.mem.Allocator, evm: ?*MockEvm) !TestFrame {
    const database = @import("../storage/memory_database.zig").MemoryDatabase.init(allocator);
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
    var expected = @as([32]u8, @splat(0));
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
    try frame.memory.set_data(testing.allocator, @as(u32, @intCast(offset)), &test_data);

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
    const self_addr = test_address_utils.toWord(u256, frame.contract_address);
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
    const zero = test_address_utils.fromWord(u256, 0);
    try testing.expectEqual(primitives.ZERO_ADDRESS, zero);

    // Test max u160 (max valid address)
    const max_u160 = std.math.maxInt(u160);
    const max_addr = test_address_utils.fromWord(u256, max_u160);
    const expected_max = Address.fromBytes(@as([20]u8, @splat(0xFF))) catch unreachable;
    try testing.expectEqual(expected_max, max_addr);

    // Test truncation from u256
    const large_value: u256 = std.math.shl(u256, 1, 200) | 0x1234567890ABCDEF1234567890ABCDEF12345678;
    const truncated = test_address_utils.fromWord(u256, large_value);
    // Should only keep lower 160 bits
    const expected_bytes = [_]u8{ 0x12, 0x34, 0x56, 0x78, 0x90, 0xAB, 0xCD, 0xEF, 0x12, 0x34, 0x56, 0x78, 0x90, 0xAB, 0xCD, 0xEF, 0x12, 0x34, 0x56, 0x78 };
    const expected = Address.fromBytes(expected_bytes) catch unreachable;
    try testing.expectEqual(expected, truncated);
}

test "Address conversion - to_u256 edge cases" {
    // Test zero
    const zero_addr = primitives.ZERO_ADDRESS;
    const zero_u256 = test_address_utils.toWord(u256, zero_addr);
    try testing.expectEqual(@as(u256, 0), zero_u256);

    // Test max address
    const max_bytes = @as([20]u8, @splat(0xFF));
    const max_addr = Address.fromBytes(max_bytes) catch unreachable;
    const max_u256 = test_address_utils.toWord(u256, max_addr);
    try testing.expectEqual(@as(u256, std.math.maxInt(u160)), max_u256);

    // Test specific pattern
    const pattern_bytes = [_]u8{ 0x12, 0x34, 0x56, 0x78, 0x90, 0xAB, 0xCD, 0xEF, 0x12, 0x34, 0x56, 0x78, 0x90, 0xAB, 0xCD, 0xEF, 0x12, 0x34, 0x56, 0x78 };
    const pattern_addr = Address.fromBytes(pattern_bytes) catch unreachable;
    const pattern_u256 = test_address_utils.toWord(u256, pattern_addr);
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
    evm.create_result.created_address = Address.fromBytes(@as([20]u8, @splat(0x42))) catch unreachable;
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
    evm.create_result.created_address = Address.fromBytes(@as([20]u8, @splat(0x11))) catch unreachable;
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
    evm.create_result.created_address = Address.fromBytes(@as([20]u8, @splat(0x22))) catch unreachable;
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
        evm.create_result.created_address = Address.fromBytes(@as([20]u8, @splat(@truncate(salt)))) catch unreachable;

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

test "AUTH handler - uses correct opcode tag" {
    // Test that AUTH handler uses .AUTH opcode tag, not .AUTHCALL
    var evm = MockEvm.init(testing.allocator);
    var frame = try createTestFrame(testing.allocator, &evm);
    defer frame.deinit(testing.allocator);

    // Push AUTH parameters (commitment, nonce, invoker address, yParity, r, s, authority)
    try frame.stack.push(0xdead); // authority address
    try frame.stack.push(0); // s
    try frame.stack.push(0); // r
    try frame.stack.push(27); // yParity (v)
    try frame.stack.push(0); // invoker address
    try frame.stack.push(0); // nonce
    try frame.stack.push(0); // commitment

    const dispatch = createMockDispatch();

    // AUTH should fail signature verification and push 0, but shouldn't crash
    // The key test is that it runs without error using .AUTH opcode
    const result = TestFrame.SystemHandlers.auth(frame, dispatch);
    try testing.expect(result == TestFrame.Success.stop);
    try testing.expectEqual(@as(u256, 0), try frame.stack.pop()); // failure
}

test "CALLCODE handler - afterComplete on error paths" {
    var evm = MockEvm.init(testing.allocator);
    var frame = try createTestFrame(testing.allocator, &evm);
    defer frame.deinit(testing.allocator);

    // Test error path: memory overflow
    try frame.stack.push(100000); // gas
    try frame.stack.push(0x1234); // address
    try frame.stack.push(0); // value
    try frame.stack.push(std.math.maxInt(usize)); // input_offset
    try frame.stack.push(std.math.maxInt(usize)); // input_size (causes overflow)
    try frame.stack.push(0); // output_offset
    try frame.stack.push(0); // output_size

    const dispatch = createMockDispatch();

    // Should return OutOfGas error after calling afterComplete
    const result = TestFrame.SystemHandlers.callcode(frame, dispatch);
    try testing.expectError(TestFrame.Error.OutOfGas, result);
}

test "CALLCODE handler - afterComplete on memory expansion error" {
    var evm = MockEvm.init(testing.allocator);
    var frame = try createTestFrame(testing.allocator, &evm);
    defer frame.deinit(testing.allocator);

    // Test error path: exceeds u24 memory limit
    try frame.stack.push(100000); // gas
    try frame.stack.push(0x1234); // address
    try frame.stack.push(0); // value
    try frame.stack.push(std.math.maxInt(u24) + 1); // input_offset (exceeds limit)
    try frame.stack.push(1); // input_size
    try frame.stack.push(0); // output_offset
    try frame.stack.push(0); // output_size

    const dispatch = createMockDispatch();

    // Should return OutOfGas error after calling afterComplete
    const result = TestFrame.SystemHandlers.callcode(frame, dispatch);
    try testing.expectError(TestFrame.Error.OutOfGas, result);
}

test "AUTHCALL handler - afterInstruction on all error paths" {
    var evm = MockEvm.init(testing.allocator);
    var frame = try createTestFrame(testing.allocator, &evm);
    defer frame.deinit(testing.allocator);

    // Test error path: no authorization
    try frame.stack.push(100000); // gas
    try frame.stack.push(0x1234); // to
    try frame.stack.push(0); // value
    try frame.stack.push(0); // input_offset
    try frame.stack.push(0); // input_size
    try frame.stack.push(0); // output_offset
    try frame.stack.push(0); // output_size
    try frame.stack.push(0); // auth_flag (0 = no auth)

    const dispatch = createMockDispatch();

    // Should complete without error, pushing 0 for failure
    const result = TestFrame.SystemHandlers.authcall(frame, dispatch);
    try testing.expect(result == TestFrame.Success.stop);
    try testing.expectEqual(@as(u256, 0), try frame.stack.pop()); // failure
}

test "AUTHCALL handler - afterInstruction on memory bounds error" {
    var evm = MockEvm.init(testing.allocator);
    var frame = try createTestFrame(testing.allocator, &evm);
    defer frame.deinit(testing.allocator);

    // Set authorized address first
    frame.authorized_address = Address.ZERO;

    // Test error path: memory bounds exceed usize
    try frame.stack.push(100000); // gas
    try frame.stack.push(0x1234); // to
    try frame.stack.push(0); // value
    try frame.stack.push(std.math.maxInt(u256)); // input_offset (exceeds usize)
    try frame.stack.push(0); // input_size
    try frame.stack.push(0); // output_offset
    try frame.stack.push(0); // output_size
    try frame.stack.push(1); // auth_flag

    const dispatch = createMockDispatch();

    // Should complete without error, pushing 0 for failure
    const result = TestFrame.SystemHandlers.authcall(frame, dispatch);
    try testing.expect(result == TestFrame.Success.stop);
    try testing.expectEqual(@as(u256, 0), try frame.stack.pop()); // failure
}

test "AUTHCALL handler - gas forwarding 63/64 rule" {
    var evm = MockEvm.init(testing.allocator);
    evm.call_result.gas_left = 50000; // Simulate gas consumption
    var frame = try createTestFrame(testing.allocator, &evm);
    defer frame.deinit(testing.allocator);

    // Set authorized address
    frame.authorized_address = Address.ZERO;

    const initial_gas = frame.gas_remaining;
    const requested_gas: u64 = 1000000; // Request more than available

    try frame.stack.push(requested_gas); // gas (will be capped)
    try frame.stack.push(0x1234); // to
    try frame.stack.push(0); // value
    try frame.stack.push(0); // input_offset
    try frame.stack.push(0); // input_size
    try frame.stack.push(0); // output_offset
    try frame.stack.push(0); // output_size
    try frame.stack.push(1); // auth_flag

    const dispatch = createMockDispatch();
    const result = try TestFrame.SystemHandlers.authcall(frame, dispatch);

    try testing.expect(result == TestFrame.Success.stop);
    try testing.expectEqual(@as(u256, 1), try frame.stack.pop()); // success

    // Verify gas was properly forwarded and accounted
    // The actual gas forwarded should be max_forwardable, not requested_gas
    try testing.expect(frame.gas_remaining < initial_gas);
}

test "AUTHCALL handler - memory expansion gas calculation" {
    var evm = MockEvm.init(testing.allocator);
    evm.call_result.gas_left = 50000;
    var frame = try createTestFrame(testing.allocator, &evm);
    defer frame.deinit(testing.allocator);

    // Set authorized address
    frame.authorized_address = Address.ZERO;

    const initial_gas = frame.gas_remaining;

    // Test with memory expansion
    try frame.stack.push(100000); // gas
    try frame.stack.push(0x1234); // to
    try frame.stack.push(0); // value
    try frame.stack.push(0); // input_offset
    try frame.stack.push(1024); // input_size (causes memory expansion)
    try frame.stack.push(0); // output_offset
    try frame.stack.push(512); // output_size (more memory expansion)
    try frame.stack.push(1); // auth_flag

    const dispatch = createMockDispatch();
    const result = try TestFrame.SystemHandlers.authcall(frame, dispatch);

    try testing.expect(result == TestFrame.Success.stop);
    try testing.expectEqual(@as(u256, 1), try frame.stack.pop()); // success

    // Verify gas was charged for memory expansion
    try testing.expect(frame.gas_remaining < initial_gas);
}

test "AUTHCALL handler - memory expansion OutOfGas" {
    var evm = MockEvm.init(testing.allocator);
    var frame = try createTestFrame(testing.allocator, &evm);
    defer frame.deinit(testing.allocator);

    // Set very low gas
    frame.gas_remaining = 10;

    // Set authorized address
    frame.authorized_address = Address.ZERO;

    // Test with large memory expansion that should cause OutOfGas
    try frame.stack.push(100000); // gas
    try frame.stack.push(0x1234); // to
    try frame.stack.push(0); // value
    try frame.stack.push(0); // input_offset
    try frame.stack.push(10000); // input_size (large expansion)
    try frame.stack.push(0); // output_offset
    try frame.stack.push(10000); // output_size
    try frame.stack.push(1); // auth_flag

    const dispatch = createMockDispatch();

    // Should return OutOfGas after calling afterComplete
    const result = TestFrame.SystemHandlers.authcall(frame, dispatch);
    try testing.expectError(TestFrame.Error.OutOfGas, result);
}

test "AUTHCALL handler - memory overflow check" {
    var evm = MockEvm.init(testing.allocator);
    var frame = try createTestFrame(testing.allocator, &evm);
    defer frame.deinit(testing.allocator);

    // Set authorized address
    frame.authorized_address = Address.ZERO;

    // Test overflow detection in memory bounds calculation
    try frame.stack.push(100000); // gas
    try frame.stack.push(0x1234); // to
    try frame.stack.push(0); // value
    try frame.stack.push(std.math.maxInt(usize) - 10); // input_offset
    try frame.stack.push(100); // input_size (causes overflow)
    try frame.stack.push(0); // output_offset
    try frame.stack.push(0); // output_size
    try frame.stack.push(1); // auth_flag

    const dispatch = createMockDispatch();

    // Should detect overflow and return failure
    const result = TestFrame.SystemHandlers.authcall(frame, dispatch);
    try testing.expect(result == TestFrame.Success.stop);
    try testing.expectEqual(@as(u256, 0), try frame.stack.pop()); // failure
}

test "AUTHCALL handler - u24 memory limit check" {
    var evm = MockEvm.init(testing.allocator);
    var frame = try createTestFrame(testing.allocator, &evm);
    defer frame.deinit(testing.allocator);

    // Set authorized address
    frame.authorized_address = Address.ZERO;

    // Test that exceeding u24 limit is properly caught
    try frame.stack.push(100000); // gas
    try frame.stack.push(0x1234); // to
    try frame.stack.push(0); // value
    try frame.stack.push(std.math.maxInt(u24) + 1); // input_offset (exceeds u24)
    try frame.stack.push(1); // input_size
    try frame.stack.push(0); // output_offset
    try frame.stack.push(0); // output_size
    try frame.stack.push(1); // auth_flag

    const dispatch = createMockDispatch();

    // Should detect limit exceeded and return failure
    const result = TestFrame.SystemHandlers.authcall(frame, dispatch);
    try testing.expect(result == TestFrame.Success.stop);
    try testing.expectEqual(@as(u256, 0), try frame.stack.pop()); // failure
}

test "AUTHCALL handler - proper gas accounting" {
    var evm = MockEvm.init(testing.allocator);
    evm.call_result.gas_left = 30000; // Gas left after call
    var frame = try createTestFrame(testing.allocator, &evm);
    defer frame.deinit(testing.allocator);

    // Set authorized address
    frame.authorized_address = Address.ZERO;

    const initial_gas = frame.gas_remaining;
    const requested_gas: u64 = 50000;

    try frame.stack.push(requested_gas); // gas
    try frame.stack.push(0x1234); // to
    try frame.stack.push(0); // value
    try frame.stack.push(0); // input_offset
    try frame.stack.push(0); // input_size
    try frame.stack.push(0); // output_offset
    try frame.stack.push(0); // output_size
    try frame.stack.push(1); // auth_flag

    const dispatch = createMockDispatch();
    const result = try TestFrame.SystemHandlers.authcall(frame, dispatch);

    try testing.expect(result == TestFrame.Success.stop);
    try testing.expectEqual(@as(u256, 1), try frame.stack.pop()); // success

    // Calculate expected gas:
    // Gas forwarded = min(requested_gas, max_forwardable) where max_forwardable = caller_gas - (caller_gas / 64)
    const caller_gas_available: u64 = @as(u64, @intCast(initial_gas));
    const max_forwardable: u64 = caller_gas_available - (caller_gas_available / 64);
    const gas_forwarded = @min(requested_gas, max_forwardable);
    const gas_used = gas_forwarded - evm.call_result.gas_left;
    const expected_remaining = @as(i64, @intCast(caller_gas_available - gas_used));

    try testing.expectEqual(expected_remaining, frame.gas_remaining);
}

test "AUTH and AUTHCALL integration - correct opcode separation" {
    // This test verifies that AUTH and AUTHCALL use their respective opcodes
    // and don't interfere with each other's dispatch handling
    var evm = MockEvm.init(testing.allocator);
    var frame = try createTestFrame(testing.allocator, &evm);
    defer frame.deinit(testing.allocator);

    // Test AUTH first
    try frame.stack.push(0xdead); // authority
    try frame.stack.push(0); // s
    try frame.stack.push(0); // r
    try frame.stack.push(27); // v
    try frame.stack.push(0); // invoker
    try frame.stack.push(0); // nonce
    try frame.stack.push(0); // commitment

    const dispatch = createMockDispatch();
    const auth_result = TestFrame.SystemHandlers.auth(frame, dispatch);
    try testing.expect(auth_result == TestFrame.Success.stop);
    try testing.expectEqual(@as(u256, 0), try frame.stack.pop()); // AUTH fails

    // Now test AUTHCALL with no authorization
    try frame.stack.push(100000); // gas
    try frame.stack.push(0x1234); // to
    try frame.stack.push(0); // value
    try frame.stack.push(0); // input_offset
    try frame.stack.push(0); // input_size
    try frame.stack.push(0); // output_offset
    try frame.stack.push(0); // output_size
    try frame.stack.push(0); // auth_flag (no auth)

    const authcall_result = TestFrame.SystemHandlers.authcall(frame, dispatch);
    try testing.expect(authcall_result == TestFrame.Success.stop);
    try testing.expectEqual(@as(u256, 0), try frame.stack.pop()); // AUTHCALL fails
}
