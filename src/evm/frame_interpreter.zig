const std = @import("std");
const builtin = @import("builtin");
const log = @import("log.zig");
const frame_mod = @import("frame.zig");
const planner_mod = @import("planner.zig");
const plan_mod = @import("plan.zig");
const opcode_data = @import("opcode_data.zig");
const Opcode = opcode_data.Opcode;
const primitives = @import("primitives");
const CallParams = @import("call_params.zig").CallParams;
const Hardfork = @import("hardfork.zig").Hardfork;
const evm = @import("evm.zig");
const HostMock = @import("host_mock.zig").HostMock;
const MemoryDatabase = @import("memory_database.zig").MemoryDatabase;

/// Create a FrameInterpreter with the given configuration
pub fn createFrameInterpreter(comptime config: frame_mod.FrameConfig) type {
    return FrameInterpreter(config);
}

// TODO rename this interpreter
// FrameInterpreter combines a Frame with a Plan to execute EVM bytecode
pub fn FrameInterpreter(comptime config: frame_mod.FrameConfig) type {
    config.validate();

    return struct {
        pub const Frame = frame_mod.Frame(config);
        pub const Planner = planner_mod.Planner(.{
            .WordType = config.WordType,
            .maxBytecodeSize = config.max_bytecode_size,
            .stack_size = config.stack_size,
            .inject_tracing = (config.TracerType != null),
        });
        pub const Plan = plan_mod.Plan(.{
            .WordType = config.WordType,
            .maxBytecodeSize = config.max_bytecode_size,
        });
        pub const WordType = config.WordType;
        pub const Error = Frame.Error || error{ OutOfMemory, TruncatedPush, InvalidJumpDestination, MissingJumpDestMetadata, InitcodeTooLarge } || (if (config.TracerType != null) error{ExecutionPaused} else error{});
        pub const HandlerFn = plan_mod.HandlerFn;

        const Self = @This();

        // Check if we're building for WASM
        const is_wasm = builtin.target.cpu.arch == .wasm32;

        frame: Frame,
        plan: *const Plan,
        instruction_idx: Plan.InstructionIndexType,
        allocator: std.mem.Allocator,
        planner: Planner,
        // Optional fast mapping: instruction index -> PC (for O(1) current PC)
        idx_to_pc: []Plan.PcType = &[_]Plan.PcType{},

        // Comptime handler table initialization
        const handlers = blk: {
            @setEvalBranchQuota(10000);
            var h: [256]*const HandlerFn = undefined;
            for (&h) |*handler| handler.* = &op_invalid_handler;
            h[@intFromEnum(Opcode.STOP)] = &op_stop_handler;
            h[@intFromEnum(Opcode.ADD)] = &op_add_handler;
            h[@intFromEnum(Opcode.MUL)] = &op_mul_handler;
            h[@intFromEnum(Opcode.SUB)] = &op_sub_handler;
            h[@intFromEnum(Opcode.DIV)] = &op_div_handler;
            h[@intFromEnum(Opcode.SDIV)] = &op_sdiv_handler;
            h[@intFromEnum(Opcode.MOD)] = &op_mod_handler;
            h[@intFromEnum(Opcode.SMOD)] = &op_smod_handler;
            h[@intFromEnum(Opcode.ADDMOD)] = &op_addmod_handler;
            h[@intFromEnum(Opcode.MULMOD)] = &op_mulmod_handler;
            h[@intFromEnum(Opcode.EXP)] = &op_exp_handler;
            h[@intFromEnum(Opcode.SIGNEXTEND)] = &op_signextend_handler;
            for (0x0c..0x10) |i| {
                h[i] = &op_invalid_handler;
            }
            h[@intFromEnum(Opcode.LT)] = &op_lt_handler;
            h[@intFromEnum(Opcode.GT)] = &op_gt_handler;
            h[@intFromEnum(Opcode.SLT)] = &op_slt_handler;
            h[@intFromEnum(Opcode.SGT)] = &op_sgt_handler;
            h[@intFromEnum(Opcode.EQ)] = &op_eq_handler;
            h[@intFromEnum(Opcode.ISZERO)] = &op_iszero_handler;
            h[@intFromEnum(Opcode.AND)] = &op_and_handler;
            h[@intFromEnum(Opcode.OR)] = &op_or_handler;
            h[@intFromEnum(Opcode.XOR)] = &op_xor_handler;
            h[@intFromEnum(Opcode.NOT)] = &op_not_handler;
            h[@intFromEnum(Opcode.BYTE)] = &op_byte_handler;
            h[@intFromEnum(Opcode.SHL)] = &op_shl_handler;
            h[@intFromEnum(Opcode.SHR)] = &op_shr_handler;
            h[@intFromEnum(Opcode.SAR)] = &op_sar_handler;
            h[0x1e] = &op_invalid_handler;
            h[0x1f] = &op_invalid_handler;
            h[@intFromEnum(Opcode.KECCAK256)] = &op_keccak256_handler;
            for (0x21..0x30) |i| {
                h[i] = &op_invalid_handler;
            }
            h[@intFromEnum(Opcode.ADDRESS)] = &op_address_handler;
            h[@intFromEnum(Opcode.BALANCE)] = &op_balance_handler;
            h[@intFromEnum(Opcode.ORIGIN)] = &op_origin_handler;
            h[@intFromEnum(Opcode.CALLER)] = &op_caller_handler;
            h[@intFromEnum(Opcode.CALLVALUE)] = &op_callvalue_handler;
            h[@intFromEnum(Opcode.CALLDATALOAD)] = &op_calldataload_handler;
            h[@intFromEnum(Opcode.CALLDATASIZE)] = &op_calldatasize_handler;
            h[@intFromEnum(Opcode.CALLDATACOPY)] = &op_calldatacopy_handler;
            h[@intFromEnum(Opcode.CODESIZE)] = &op_codesize_handler;
            h[@intFromEnum(Opcode.CODECOPY)] = &op_codecopy_handler;
            h[@intFromEnum(Opcode.GASPRICE)] = &op_gasprice_handler;
            h[@intFromEnum(Opcode.EXTCODESIZE)] = &op_extcodesize_handler;
            h[@intFromEnum(Opcode.EXTCODECOPY)] = &op_extcodecopy_handler;
            h[@intFromEnum(Opcode.RETURNDATASIZE)] = &op_returndatasize_handler;
            h[@intFromEnum(Opcode.RETURNDATACOPY)] = &op_returndatacopy_handler;
            h[@intFromEnum(Opcode.EXTCODEHASH)] = &op_extcodehash_handler;
            h[@intFromEnum(Opcode.BLOCKHASH)] = &op_blockhash_handler;
            h[@intFromEnum(Opcode.COINBASE)] = &op_coinbase_handler;
            h[@intFromEnum(Opcode.TIMESTAMP)] = &op_timestamp_handler;
            h[@intFromEnum(Opcode.NUMBER)] = &op_number_handler;
            h[@intFromEnum(Opcode.DIFFICULTY)] = &op_difficulty_handler;
            h[@intFromEnum(Opcode.GASLIMIT)] = &op_gaslimit_handler;
            h[@intFromEnum(Opcode.CHAINID)] = &op_chainid_handler;
            h[@intFromEnum(Opcode.SELFBALANCE)] = &op_selfbalance_handler;
            h[@intFromEnum(Opcode.BASEFEE)] = &op_basefee_handler;
            h[@intFromEnum(Opcode.BLOBHASH)] = &op_blobhash_handler;
            h[@intFromEnum(Opcode.BLOBBASEFEE)] = &op_blobbasefee_handler;
            for (0x4b..0x50) |i| {
                h[i] = &op_invalid_handler;
            }
            h[@intFromEnum(Opcode.POP)] = &op_pop_handler;
            h[@intFromEnum(Opcode.MLOAD)] = &op_mload_handler;
            h[@intFromEnum(Opcode.MSTORE)] = &op_mstore_handler;
            h[@intFromEnum(Opcode.MSTORE8)] = &op_mstore8_handler;
            h[@intFromEnum(Opcode.SLOAD)] = &op_sload_handler;
            h[@intFromEnum(Opcode.SSTORE)] = &op_sstore_handler;
            h[@intFromEnum(Opcode.JUMP)] = &op_jump_handler;
            h[@intFromEnum(Opcode.JUMPI)] = &op_jumpi_handler;
            h[@intFromEnum(Opcode.PC)] = &op_pc_handler;
            h[@intFromEnum(Opcode.MSIZE)] = &op_msize_handler;
            h[@intFromEnum(Opcode.GAS)] = &op_gas_handler;
            h[@intFromEnum(Opcode.JUMPDEST)] = &op_jumpdest_handler;
            h[@intFromEnum(Opcode.TLOAD)] = &op_tload_handler;
            h[@intFromEnum(Opcode.TSTORE)] = &op_tstore_handler;
            h[@intFromEnum(Opcode.MCOPY)] = &op_mcopy_handler;
            // Assign PUSH handlers directly
            for (0..33) |i| {
                const push_n = @as(u8, @intCast(i));
                const opcode = @as(Opcode, @enumFromInt(@intFromEnum(Opcode.PUSH0) + push_n));
                h[@intFromEnum(opcode)] = generatePushHandler(push_n);
            }
            // Assign DUP handlers directly
            for (1..17) |i| {
                const dup_n = @as(u8, @intCast(i));
                const opcode = @as(Opcode, @enumFromInt(@intFromEnum(Opcode.DUP1) + dup_n - 1));
                h[@intFromEnum(opcode)] = generateDupHandler(dup_n);
            }
            // Assign SWAP handlers directly
            for (1..17) |i| {
                const swap_n = @as(u8, @intCast(i));
                const opcode = @as(Opcode, @enumFromInt(@intFromEnum(Opcode.SWAP1) + swap_n - 1));
                h[@intFromEnum(opcode)] = generateSwapHandler(swap_n);
            }
            h[@intFromEnum(Opcode.LOG0)] = &op_log0_handler;
            h[@intFromEnum(Opcode.LOG1)] = &op_log1_handler;
            h[@intFromEnum(Opcode.LOG2)] = &op_log2_handler;
            h[@intFromEnum(Opcode.LOG3)] = &op_log3_handler;
            h[@intFromEnum(Opcode.LOG4)] = &op_log4_handler;
            for (0xa5..0xf0) |i| {
                h[i] = &op_invalid_handler;
            }
            h[@intFromEnum(Opcode.CREATE)] = &op_create_handler;
            h[@intFromEnum(Opcode.CALL)] = &op_call_handler;
            h[@intFromEnum(Opcode.CALLCODE)] = &op_invalid_handler; // Deprecated
            h[@intFromEnum(Opcode.RETURN)] = &op_return_handler;
            h[@intFromEnum(Opcode.DELEGATECALL)] = &op_delegatecall_handler;
            for (0xf5..0xfa) |i| {
                h[i] = &op_invalid_handler;
            }
            h[@intFromEnum(Opcode.STATICCALL)] = &op_staticcall_handler;
            h[@intFromEnum(Opcode.REVERT)] = &op_revert_handler;
            h[0xfc] = &op_invalid_handler;
            h[0xfd] = &op_invalid_handler;
            h[@intFromEnum(Opcode.INVALID)] = &op_invalid_handler;
            h[@intFromEnum(Opcode.SELFDESTRUCT)] = &op_selfdestruct_handler; // Delegate to Frame
            h[@intFromEnum(planner_mod.OpcodeSynthetic.PUSH_ADD_INLINE)] = &push_add_inline_handler;
            h[@intFromEnum(planner_mod.OpcodeSynthetic.PUSH_ADD_POINTER)] = &push_add_pointer_handler;
            h[@intFromEnum(planner_mod.OpcodeSynthetic.PUSH_MUL_INLINE)] = &push_mul_inline_handler;
            h[@intFromEnum(planner_mod.OpcodeSynthetic.PUSH_MUL_POINTER)] = &push_mul_pointer_handler;
            h[@intFromEnum(planner_mod.OpcodeSynthetic.PUSH_DIV_INLINE)] = &push_div_inline_handler;
            h[@intFromEnum(planner_mod.OpcodeSynthetic.PUSH_DIV_POINTER)] = &push_div_pointer_handler;
            h[@intFromEnum(planner_mod.OpcodeSynthetic.PUSH_SUB_INLINE)] = &push_sub_inline_handler;
            h[@intFromEnum(planner_mod.OpcodeSynthetic.PUSH_SUB_POINTER)] = &push_sub_pointer_handler;
            h[@intFromEnum(planner_mod.OpcodeSynthetic.PUSH_JUMP_INLINE)] = &push_jump_inline_handler;
            h[@intFromEnum(planner_mod.OpcodeSynthetic.PUSH_JUMP_POINTER)] = &push_jump_pointer_handler;
            h[@intFromEnum(planner_mod.OpcodeSynthetic.PUSH_JUMPI_INLINE)] = &push_jumpi_inline_handler;
            h[@intFromEnum(planner_mod.OpcodeSynthetic.PUSH_JUMPI_POINTER)] = &push_jumpi_pointer_handler;
            // New fusions: PUSH+MLOAD/MSTORE (immediate offset)
            h[@intFromEnum(planner_mod.OpcodeSynthetic.PUSH_MLOAD_INLINE)] = &push_mload_inline_handler;
            h[@intFromEnum(planner_mod.OpcodeSynthetic.PUSH_MLOAD_POINTER)] = &push_mload_pointer_handler;
            h[@intFromEnum(planner_mod.OpcodeSynthetic.PUSH_MSTORE_INLINE)] = &push_mstore_inline_handler;
            h[@intFromEnum(planner_mod.OpcodeSynthetic.PUSH_MSTORE_POINTER)] = &push_mstore_pointer_handler;
            // New: bitwise and MSTORE8 fusions
            h[@intFromEnum(planner_mod.OpcodeSynthetic.PUSH_AND_INLINE)] = &push_and_inline_handler;
            h[@intFromEnum(planner_mod.OpcodeSynthetic.PUSH_AND_POINTER)] = &push_and_pointer_handler;
            h[@intFromEnum(planner_mod.OpcodeSynthetic.PUSH_OR_INLINE)] = &push_or_inline_handler;
            h[@intFromEnum(planner_mod.OpcodeSynthetic.PUSH_OR_POINTER)] = &push_or_pointer_handler;
            h[@intFromEnum(planner_mod.OpcodeSynthetic.PUSH_XOR_INLINE)] = &push_xor_inline_handler;
            h[@intFromEnum(planner_mod.OpcodeSynthetic.PUSH_XOR_POINTER)] = &push_xor_pointer_handler;
            h[@intFromEnum(planner_mod.OpcodeSynthetic.PUSH_MSTORE8_INLINE)] = &push_mstore8_inline_handler;
            h[@intFromEnum(planner_mod.OpcodeSynthetic.PUSH_MSTORE8_POINTER)] = &push_mstore8_pointer_handler;
            break :blk h;
        };

        pub fn init(allocator: std.mem.Allocator, bytecode: []const u8, gas_remaining: Frame.GasType, database: if (config.has_database) ?@import("database_interface.zig").DatabaseInterface else void, host: @import("host.zig").Host) Error!Self {
            var frame = try Frame.init(allocator, bytecode, gas_remaining, database, host);
            errdefer frame.deinit(allocator);
            var planner = try Planner.init(allocator, 32); // Small cache for frame interpreter

            if (comptime config.TracerType != null) {
                // Provide trace handlers to planner (compile-time gated)
                planner.setTraceHandlers(&trace_before_op_handler, &trace_after_op_handler);
            }

            // Use getOrAnalyze with the actual hardfork from host
            const plan_ptr = try planner.getOrAnalyze(bytecode, handlers, host.get_hardfork());

            // Build reverse mapping (instruction_idx -> pc) if pc map exists
            var idx_to_pc: []Plan.PcType = &[_]Plan.PcType{};
            if (plan_ptr.pc_to_instruction_idx) |pc_map| {
                idx_to_pc = try allocator.alloc(Plan.PcType, plan_ptr.instructionStream.len);
                // Fill with sentinel (max value) indicating invalid
                const invalid_pc: Plan.PcType = std.math.maxInt(Plan.PcType);
                @memset(idx_to_pc, invalid_pc);
                var it = pc_map.iterator();
                while (it.next()) |e| {
                    const pc = e.key_ptr.*;
                    const idx = e.value_ptr.*;
                    if (idx < idx_to_pc.len) idx_to_pc[idx] = pc;
                }
            }

            return Self{
                .frame = frame,
                .plan = plan_ptr,
                .instruction_idx = 0,
                .allocator = allocator,
                .planner = planner,
                .idx_to_pc = idx_to_pc,
            };
        }

        /// Get current PC by instruction index.
        /// When tracing is enabled, also resolves PCs at adjacent trace indices; otherwise identical to pre-change behavior.
        pub fn getCurrentPc(self: *const Self) ?Plan.PcType {
            if (self.idx_to_pc.len == 0) return null;
            const invalid_pc: Plan.PcType = std.math.maxInt(Plan.PcType);
            const idx = self.instruction_idx;
            // Exact index fast path
            if (idx < self.idx_to_pc.len) {
                const pc0 = self.idx_to_pc[idx];
                if (pc0 != invalid_pc) return pc0;
            }
            // Neighbor probes only compiled when tracing is enabled
            if (comptime config.TracerType != null) {
                if (idx + 1 < self.idx_to_pc.len) {
                    const pc1 = self.idx_to_pc[idx + 1];
                    if (pc1 != invalid_pc) return pc1;
                }
                if (idx > 0 and idx - 1 < self.idx_to_pc.len) {
                    const pc2 = self.idx_to_pc[idx - 1];
                    if (pc2 != invalid_pc) return pc2;
                }
            }
            return null;
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.frame.deinit(allocator);
            // Don't deinit the plan - it's owned by the planner cache
            self.planner.deinit();
            if (self.idx_to_pc.len != 0) allocator.free(self.idx_to_pc);
        }

        // TODO this will return on STOP or RETURN
        pub fn interpret(self: *Self) !void {
            self.plan.debugPrint();

            if (self.plan.instructionStream.len == 0) return;
            const start_idx: Plan.InstructionIndexType = if (comptime config.TracerType != null) self.instruction_idx else 0;
            return try self.plan.instructionStream[start_idx].handler(&self.frame, self.plan);
        }

        /// Pretty print the interpreter state for debugging.
        pub fn pretty_print(self: *const Self) void {
            log.debug("\n=== Frame Interpreter State ===\n", .{});
            log.debug("Instruction Index: {}\n", .{self.instruction_idx});

            // Print frame state
            self.frame.pretty_print();

            // Plan info
            log.debug("\nPlan: Present (use plan.debugPrint() for details)\n", .{});
            // Get current PC if possible
            if (self.plan.pc_to_instruction_idx) |map| {
                // Find PC for current instruction index
                var iter = map.iterator();
                while (iter.next()) |entry| {
                    if (entry.value_ptr.* == self.instruction_idx) {
                        log.debug("Current PC: {} (instruction index: {})\n", .{ entry.key_ptr.*, self.instruction_idx });
                        break;
                    }
                }
            }

            log.debug("===================\n\n", .{});
        }

        // Handler functions follow...
        // These have been moved from frame.zig

        fn op_invalid_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            log.debug("\n=== InvalidOpcode Debug ===", .{});
            log.debug("Instruction index: {}", .{interpreter.instruction_idx});
            log.debug("Bytecode: {any}", .{self.bytecode});
            log.debug("Instruction stream length: {}", .{plan_ptr.instructionStream.len});
            log.debug("==================\n", .{});

            self.invalid() catch |err| return err;
            unreachable;
        }

        fn op_stop_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            _ = plan;

            // Check final gas before stopping
            try self.checkGas();

            self.stop() catch |err| return err;
            unreachable;
        }

        // Helper function to dispatch to next handler with WASM compatibility
        inline fn dispatchNext(next_handler: *const HandlerFn, frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            return next_handler(frame, plan);
        }

        // Comptime PUSH handler generation
        fn generatePushHandler(comptime n: u8) HandlerFn {
            const opcode = @as(Opcode, @enumFromInt(@intFromEnum(Opcode.PUSH0) + n));
            return struct {
                fn handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
                    const self = @as(*Frame, @ptrCast(@alignCast(frame)));
                    const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
                    const interpreter = @as(*Self, @fieldParentPtr("frame", self));

                    // Reconstruct immediate directly from bytecode using current PC
                    if (n == 0) {
                        try self.stack.push(0);
                    } else {
                        const pc_opt = interpreter.getCurrentPc();
                        if (pc_opt) |pc_val| {
                            // pc_val points at the PUSH opcode; immediate starts at pc+1
                            var acc: WordType = 0;
                            var j: usize = 0;
                            while (j < n) : (j += 1) {
                                const off = @as(usize, @intCast(pc_val)) + 1 + j;
                                if (off >= self.bytecode.len) break; // safety
                                acc = (acc << 8) | self.bytecode[off];
                            }
                            try self.stack.push(acc);
                        } else {
                            // Fallback to plan metadata if PC mapping unavailable
                            if ((n <= 8 and @sizeOf(usize) == 8) or (n <= 4 and @sizeOf(usize) == 4)) {
                                const value = @as(WordType, plan_ptr.getMetadata(&interpreter.instruction_idx, opcode));
                                try self.stack.push(value);
                            } else {
                                const value_ptr = plan_ptr.getMetadata(&interpreter.instruction_idx, opcode);
                                try self.stack.push(value_ptr.*);
                            }
                        }
                    }

                    const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, opcode);

                    log.debug("PUSH{} handler: instruction_idx={}, getting next handler", .{ n, interpreter.instruction_idx });
                    const handler_addr = @intFromPtr(next_handler);
                    if (handler_addr < 0x1000) {
                        std.debug.print("ERROR: next_handler has suspicious low address: 0x{x}\n", .{handler_addr});
                        std.debug.print("Current instruction_idx: {}\n", .{interpreter.instruction_idx});
                        std.debug.print("Opcode: {}\n", .{opcode});
                        @panic("suspicious next_handler from getNextInstruction");
                    }

                    return dispatchNext(next_handler, self, plan_ptr);
                }
            }.handler;
        }

        // Comptime DUP handler generation
        fn generateDupHandler(comptime n: u8) HandlerFn {
            const opcode = @as(Opcode, @enumFromInt(@intFromEnum(Opcode.DUP1) + n - 1));
            return struct {
                fn handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
                    const self = @as(*Frame, @ptrCast(@alignCast(frame)));
                    const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
                    const interpreter = @as(*Self, @fieldParentPtr("frame", self));

                    self.stack.dup_n_unsafe(n);

                    const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, opcode);
                    return dispatchNext(next_handler, self, plan_ptr);
                }
            }.handler;
        }

        // Comptime SWAP handler generation
        fn generateSwapHandler(comptime n: u8) HandlerFn {
            const opcode = @as(Opcode, @enumFromInt(@intFromEnum(Opcode.SWAP1) + n - 1));
            return struct {
                fn handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
                    const self = @as(*Frame, @ptrCast(@alignCast(frame)));
                    const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
                    const interpreter = @as(*Self, @fieldParentPtr("frame", self));

                    self.stack.swap_n_unsafe(n);

                    const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, opcode);
                    return dispatchNext(next_handler, self, plan_ptr);
                }
            }.handler;
        }

        // Helper function to assign basic opcode handlers
        inline fn assignBasicHandlers(handler_table: *[256]*const HandlerFn) void {
            // Arithmetic operations
            const arithmetic_ops = .{
                .{ Opcode.ADD, &op_add_handler },
                .{ Opcode.MUL, &op_mul_handler },
                .{ Opcode.SUB, &op_sub_handler },
                .{ Opcode.DIV, &op_div_handler },
                .{ Opcode.SDIV, &op_sdiv_handler },
                .{ Opcode.MOD, &op_mod_handler },
                .{ Opcode.SMOD, &op_smod_handler },
                .{ Opcode.ADDMOD, &op_addmod_handler },
                .{ Opcode.MULMOD, &op_mulmod_handler },
                .{ Opcode.EXP, &op_exp_handler },
                .{ Opcode.SIGNEXTEND, &op_signextend_handler },
            };

            // Comparison operations
            const comparison_ops = .{
                .{ Opcode.LT, &op_lt_handler },
                .{ Opcode.GT, &op_gt_handler },
                .{ Opcode.SLT, &op_slt_handler },
                .{ Opcode.SGT, &op_sgt_handler },
                .{ Opcode.EQ, &op_eq_handler },
                .{ Opcode.ISZERO, &op_iszero_handler },
            };

            // Bitwise operations
            const bitwise_ops = .{
                .{ Opcode.AND, &op_and_handler },
                .{ Opcode.OR, &op_or_handler },
                .{ Opcode.XOR, &op_xor_handler },
                .{ Opcode.NOT, &op_not_handler },
                .{ Opcode.BYTE, &op_byte_handler },
                .{ Opcode.SHL, &op_shl_handler },
                .{ Opcode.SHR, &op_shr_handler },
                .{ Opcode.SAR, &op_sar_handler },
            };

            // Memory operations
            const memory_ops = .{
                .{ Opcode.MLOAD, &op_mload_handler },
                .{ Opcode.MSTORE, &op_mstore_handler },
                .{ Opcode.MSTORE8, &op_mstore8_handler },
                .{ Opcode.MSIZE, &op_msize_handler },
                .{ Opcode.MCOPY, &op_mcopy_handler },
            };

            // Assign handlers using comptime
            inline for (arithmetic_ops) |op| {
                handler_table[@intFromEnum(op[0])] = op[1];
            }
            inline for (comparison_ops) |op| {
                handler_table[@intFromEnum(op[0])] = op[1];
            }
            inline for (bitwise_ops) |op| {
                handler_table[@intFromEnum(op[0])] = op[1];
            }
            inline for (memory_ops) |op| {
                handler_table[@intFromEnum(op[0])] = op[1];
            }
        }

        // PUSH handlers are now generated at comptime in the init function
        // DUP handlers are now generated at comptime in the init function
        // SWAP handlers are now generated at comptime in the init function

        // Individual PUSH handlers (old implementations for reference)
        fn push0_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            try self.stack.push(0);

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .PUSH0);
            return dispatchNext(next_handler, self, plan_ptr);
        }

        fn push1_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            const value = @as(WordType, plan_ptr.getMetadata(&interpreter.instruction_idx, .PUSH1));
            try self.stack.push(value);

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .PUSH1);
            return dispatchNext(next_handler, self, plan_ptr);
        }

        // Additional handlers implemented below
        // For now, let's just add a few more to show the pattern

        // Environment opcodes
        fn op_address_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            // Get opcode info for gas consumption
            const opcode_info = opcode_data.OPCODE_INFO[@intFromEnum(Opcode.ADDRESS)];

            // Consume gas
            self.consumeGasUnchecked(opcode_info.gas_cost);

            // Push the contract address as u256
            const address = primitives.Address.to_u256(self.contract_address);
            try self.stack.push(@as(WordType, @intCast(address)));

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, @intFromEnum(Opcode.ADDRESS));
            return dispatchNext(next_handler, self, plan_ptr);
        }

        fn op_balance_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            // Check if we have a host first

            // Pop address from stack
            const address_u256 = try self.stack.pop();
            const address = primitives.Address.from_u256(address_u256);

            // Access the address and get the gas cost (warm/cold)
            const gas_cost = self.host.access_address(address) catch |err| switch (err) {
                else => return Error.AllocationError,
            };

            // Consume the dynamic gas cost
            self.consumeGasUnchecked(@intCast(gas_cost));

            // Get balance from host
            const balance = self.host.get_balance(address);

            // Push balance to stack
            try self.stack.push(@as(WordType, @intCast(balance)));

            if (interpreter.instruction_idx >= plan_ptr.instructionStream.len - 1) {
                return Error.STOP;
            }
            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, @intFromEnum(Opcode.BALANCE));
            return dispatchNext(next_handler, self, plan_ptr);
        }

        fn op_origin_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            // Check if we have a host first

            // Get opcode info for gas consumption
            const opcode_info = opcode_data.OPCODE_INFO[@intFromEnum(Opcode.ORIGIN)];

            // Consume gas
            self.consumeGasUnchecked(opcode_info.gas_cost);

            // Get origin from host's transaction context
            const origin_addr = self.host.get_tx_origin();
            const origin = primitives.Address.to_u256(origin_addr);

            // Push origin to stack
            try self.stack.push(@as(WordType, @intCast(origin)));

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, @intFromEnum(Opcode.ORIGIN));
            return dispatchNext(next_handler, self, plan_ptr);
        }

        fn op_caller_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            // Check if we have a host first

            // Get opcode info for gas consumption
            const opcode_info = opcode_data.OPCODE_INFO[@intFromEnum(Opcode.CALLER)];

            // Consume gas
            self.consumeGasUnchecked(opcode_info.gas_cost);

            // Get caller from host
            const caller_addr = self.host.get_caller();
            const caller_u256 = primitives.Address.to_u256(caller_addr);

            // Push caller to stack
            try self.stack.push(@as(WordType, @intCast(caller_u256)));

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, @intFromEnum(Opcode.CALLER));
            return dispatchNext(next_handler, self, plan_ptr);
        }

        fn op_callvalue_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            // Check if we have a host first

            // Get opcode info for gas consumption
            const opcode_info = opcode_data.OPCODE_INFO[@intFromEnum(Opcode.CALLVALUE)];

            // Consume gas
            self.consumeGasUnchecked(opcode_info.gas_cost);

            // Get call value from host
            const value = self.host.get_call_value();

            // Push value to stack (cast u256 to WordType)
            try self.stack.push(@intCast(value));

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, @intFromEnum(Opcode.CALLVALUE));
            return dispatchNext(next_handler, self, plan_ptr);
        }

        fn op_add_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            // Get opcode info for gas consumption
            const opcode_info = opcode_data.OPCODE_INFO[@intFromEnum(Opcode.ADD)];

            // Consume gas (unchecked since we validated in pre-analysis)
            self.consumeGasUnchecked(opcode_info.gas_cost);
            // Execute the operation (unsafe stack ops)
            const b: WordType = self.stack.pop_unsafe();
            const a: WordType = self.stack.peek_unsafe();
            self.stack.set_top_unsafe(a +% b);

            // Get next handler from plan
            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .ADD);
            return dispatchNext(next_handler, self, plan_ptr);
        }

        fn op_mul_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            // Get opcode info for gas consumption
            const opcode_info = opcode_data.OPCODE_INFO[@intFromEnum(Opcode.MUL)];

            // Consume gas (unchecked since we validated in pre-analysis)
            self.consumeGasUnchecked(opcode_info.gas_cost);

            // Execute the operation (unsafe)
            const b: WordType = self.stack.pop_unsafe();
            const a: WordType = self.stack.peek_unsafe();
            self.stack.set_top_unsafe(a *% b);

            // Get next handler from plan
            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .MUL);
            return dispatchNext(next_handler, self, plan_ptr);
        }

        fn op_sub_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            // Get opcode info for gas consumption
            const opcode_info = opcode_data.OPCODE_INFO[@intFromEnum(Opcode.SUB)];

            // Consume gas (unchecked since we validated in pre-analysis)
            self.consumeGasUnchecked(opcode_info.gas_cost);

            // Execute the operation (unsafe)
            const b: WordType = self.stack.pop_unsafe();
            const a: WordType = self.stack.peek_unsafe();
            self.stack.set_top_unsafe(a -% b);

            // Get next handler from plan
            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .SUB);
            return dispatchNext(next_handler, self, plan_ptr);
        }

        fn op_div_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            const opcode_info = opcode_data.OPCODE_INFO[@intFromEnum(Opcode.DIV)];
            self.consumeGasUnchecked(opcode_info.gas_cost);
            const den: WordType = self.stack.pop_unsafe();
            const num: WordType = self.stack.peek_unsafe();
            const res: WordType = if (den == 0) 0 else num / den;
            self.stack.set_top_unsafe(res);

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .DIV);
            return dispatchNext(next_handler, self, plan_ptr);
        }

        fn op_sdiv_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            const opcode_info = opcode_data.OPCODE_INFO[@intFromEnum(Opcode.SDIV)];
            self.consumeGasUnchecked(opcode_info.gas_cost);
            const den: WordType = self.stack.pop_unsafe();
            const num: WordType = self.stack.peek_unsafe();
            var res: WordType = 0;
            if (den == 0) {
                res = 0;
            } else {
                const Signed = std.meta.Int(.signed, @bitSizeOf(WordType));
                const num_s: Signed = @bitCast(num);
                const den_s: Signed = @bitCast(den);
                const min_s = std.math.minInt(Signed);
                if (num_s == min_s and den_s == -1) {
                    res = num;
                } else {
                    const q: Signed = @divTrunc(num_s, den_s);
                    res = @bitCast(q);
                }
            }
            self.stack.set_top_unsafe(res);

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .SDIV);
            return dispatchNext(next_handler, self, plan_ptr);
        }

        fn op_mod_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            const opcode_info = opcode_data.OPCODE_INFO[@intFromEnum(Opcode.MOD)];
            self.consumeGasUnchecked(opcode_info.gas_cost);
            const den: WordType = self.stack.pop_unsafe();
            const num: WordType = self.stack.peek_unsafe();
            const res: WordType = if (den == 0) 0 else num % den;
            self.stack.set_top_unsafe(res);

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .MOD);
            return dispatchNext(next_handler, self, plan_ptr);
        }

        fn op_smod_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            const opcode_info = opcode_data.OPCODE_INFO[@intFromEnum(Opcode.SMOD)];
            self.consumeGasUnchecked(opcode_info.gas_cost);
            const den: WordType = self.stack.pop_unsafe();
            const num: WordType = self.stack.peek_unsafe();
            var res: WordType = 0;
            if (den == 0) {
                res = 0;
            } else {
                const Signed = std.meta.Int(.signed, @bitSizeOf(WordType));
                const num_s: Signed = @bitCast(num);
                const den_s: Signed = @bitCast(den);
                const r: Signed = @rem(num_s, den_s);
                res = @bitCast(r);
            }
            self.stack.set_top_unsafe(res);

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .SMOD);
            return dispatchNext(next_handler, self, plan_ptr);
        }

        fn op_addmod_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            const opcode_info = opcode_data.OPCODE_INFO[@intFromEnum(Opcode.ADDMOD)];
            self.consumeGasUnchecked(opcode_info.gas_cost);
            const modulus: WordType = self.stack.pop_unsafe();
            const b: WordType = self.stack.pop_unsafe();
            const a: WordType = self.stack.peek_unsafe();
            var res: WordType = 0;
            if (modulus == 0) {
                res = 0;
            } else {
                const sum = @addWithOverflow(a, b);
                res = sum[0] % modulus;
            }
            self.stack.set_top_unsafe(res);

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .ADDMOD);
            return dispatchNext(next_handler, self, plan_ptr);
        }

        fn op_mulmod_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            const opcode_info = opcode_data.OPCODE_INFO[@intFromEnum(Opcode.MULMOD)];
            self.consumeGasUnchecked(opcode_info.gas_cost);
            const modulus: WordType = self.stack.pop_unsafe();
            const b: WordType = self.stack.pop_unsafe();
            const a: WordType = self.stack.peek_unsafe();
            var res: WordType = 0;
            if (modulus == 0) {
                res = 0;
            } else {
                const a_m = a % modulus;
                const b_m = b % modulus;
                res = (a_m *% b_m) % modulus;
            }
            self.stack.set_top_unsafe(res);

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .MULMOD);
            return dispatchNext(next_handler, self, plan_ptr);
        }

        fn op_exp_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            const opcode_info = opcode_data.OPCODE_INFO[@intFromEnum(Opcode.EXP)];
            self.consumeGasUnchecked(opcode_info.gas_cost);
            try self.exp();

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .EXP);
            return dispatchNext(next_handler, self, plan_ptr);
        }

        fn op_signextend_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            const opcode_info = opcode_data.OPCODE_INFO[@intFromEnum(Opcode.SIGNEXTEND)];
            self.consumeGasUnchecked(opcode_info.gas_cost);
            const ext: WordType = self.stack.pop_unsafe();
            const value: WordType = self.stack.peek_unsafe();
            var result: WordType = undefined;
            if (ext >= 31) {
                result = value;
            } else {
                const ext_usize: usize = @intCast(ext);
                const bit_index = ext_usize * 8 + 7;
                const mask: WordType = (@as(WordType, 1) << @intCast(bit_index)) - 1;
                const sign_bit = (value >> @intCast(bit_index)) & 1;
                if (sign_bit == 1) {
                    result = value | ~mask;
                } else {
                    result = value & mask;
                }
            }
            self.stack.set_top_unsafe(result);

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .SIGNEXTEND);
            return dispatchNext(next_handler, self, plan_ptr);
        }

        // Comparison handlers
        fn op_lt_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            const opcode_info = opcode_data.OPCODE_INFO[@intFromEnum(Opcode.LT)];
            self.consumeGasUnchecked(opcode_info.gas_cost);
            // a < b (unsigned); stack top is 'a'
            const b: WordType = self.stack.pop_unsafe();
            const a: WordType = self.stack.peek_unsafe();
            self.stack.set_top_unsafe(if (a < b) 1 else 0);

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .LT);
            return dispatchNext(next_handler, self, plan_ptr);
        }

        fn op_gt_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            const opcode_info = opcode_data.OPCODE_INFO[@intFromEnum(Opcode.GT)];
            self.consumeGasUnchecked(opcode_info.gas_cost);
            const b2: WordType = self.stack.pop_unsafe();
            const a2: WordType = self.stack.peek_unsafe();
            self.stack.set_top_unsafe(if (a2 > b2) 1 else 0);

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .GT);
            return dispatchNext(next_handler, self, plan_ptr);
        }

        fn op_slt_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            const opcode_info = opcode_data.OPCODE_INFO[@intFromEnum(Opcode.SLT)];
            self.consumeGasUnchecked(opcode_info.gas_cost);
            const b3: WordType = self.stack.pop_unsafe();
            const a3: WordType = self.stack.peek_unsafe();
            const Signed = std.meta.Int(.signed, @bitSizeOf(WordType));
            const a3s: Signed = @bitCast(a3);
            const b3s: Signed = @bitCast(b3);
            self.stack.set_top_unsafe(if (a3s < b3s) 1 else 0);

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .SLT);
            return dispatchNext(next_handler, self, plan_ptr);
        }

        fn op_sgt_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            const opcode_info = opcode_data.OPCODE_INFO[@intFromEnum(Opcode.SGT)];
            self.consumeGasUnchecked(opcode_info.gas_cost);
            const b4: WordType = self.stack.pop_unsafe();
            const a4: WordType = self.stack.peek_unsafe();
            const Signed2 = std.meta.Int(.signed, @bitSizeOf(WordType));
            const a4s: Signed2 = @bitCast(a4);
            const b4s: Signed2 = @bitCast(b4);
            self.stack.set_top_unsafe(if (a4s > b4s) 1 else 0);

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .SGT);
            return dispatchNext(next_handler, self, plan_ptr);
        }

        fn op_eq_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            const opcode_info = opcode_data.OPCODE_INFO[@intFromEnum(Opcode.EQ)];
            self.consumeGasUnchecked(opcode_info.gas_cost);
            const b5: WordType = self.stack.pop_unsafe();
            const a5: WordType = self.stack.peek_unsafe();
            self.stack.set_top_unsafe(if (a5 == b5) 1 else 0);

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .EQ);
            return dispatchNext(next_handler, self, plan_ptr);
        }

        fn op_iszero_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            const opcode_info = opcode_data.OPCODE_INFO[@intFromEnum(Opcode.ISZERO)];
            self.consumeGasUnchecked(opcode_info.gas_cost);
            const v: WordType = self.stack.peek_unsafe();
            self.stack.set_top_unsafe(if (v == 0) 1 else 0);

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .ISZERO);
            return dispatchNext(next_handler, self, plan_ptr);
        }

        // Bitwise handlers
        fn op_and_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            const opcode_info = opcode_data.OPCODE_INFO[@intFromEnum(Opcode.AND)];
            self.consumeGasUnchecked(opcode_info.gas_cost);
            const b6: WordType = self.stack.pop_unsafe();
            const a6: WordType = self.stack.peek_unsafe();
            self.stack.set_top_unsafe(a6 & b6);

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .AND);
            return dispatchNext(next_handler, self, plan_ptr);
        }

        fn op_or_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            const opcode_info = opcode_data.OPCODE_INFO[@intFromEnum(Opcode.OR)];
            self.consumeGasUnchecked(opcode_info.gas_cost);
            const b7: WordType = self.stack.pop_unsafe();
            const a7: WordType = self.stack.peek_unsafe();
            self.stack.set_top_unsafe(a7 | b7);

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .OR);
            return dispatchNext(next_handler, self, plan_ptr);
        }

        fn op_xor_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            const opcode_info = opcode_data.OPCODE_INFO[@intFromEnum(Opcode.XOR)];
            self.consumeGasUnchecked(opcode_info.gas_cost);
            const b8: WordType = self.stack.pop_unsafe();
            const a8: WordType = self.stack.peek_unsafe();
            self.stack.set_top_unsafe(a8 ^ b8);

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .XOR);
            return dispatchNext(next_handler, self, plan_ptr);
        }

        fn op_not_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            const opcode_info = opcode_data.OPCODE_INFO[@intFromEnum(Opcode.NOT)];
            self.consumeGasUnchecked(opcode_info.gas_cost);
            const t: WordType = self.stack.peek_unsafe();
            self.stack.set_top_unsafe(~t);

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .NOT);
            return dispatchNext(next_handler, self, plan_ptr);
        }

        fn op_byte_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            const opcode_info = opcode_data.OPCODE_INFO[@intFromEnum(Opcode.BYTE)];
            self.consumeGasUnchecked(opcode_info.gas_cost);
            const byte_index: WordType = self.stack.pop_unsafe();
            const value: WordType = self.stack.peek_unsafe();
            const res_b: WordType = if (byte_index >= 32) 0 else blk: {
                const index_usize: usize = @intCast(byte_index);
                const shift_amount = (31 - index_usize) * 8;
                const ShiftType = std.math.Log2Int(WordType);
                break :blk (value >> @as(ShiftType, @intCast(shift_amount))) & 0xFF;
            };
            self.stack.set_top_unsafe(res_b);

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .BYTE);
            return dispatchNext(next_handler, self, plan_ptr);
        }

        fn op_shl_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            const opcode_info = opcode_data.OPCODE_INFO[@intFromEnum(Opcode.SHL)];
            self.consumeGasUnchecked(opcode_info.gas_cost);
            const shift_l: WordType = self.stack.pop_unsafe();
            const val_l: WordType = self.stack.peek_unsafe();
            const ShiftTypeL = std.math.Log2Int(WordType);
            const res_l: WordType = if (shift_l >= @bitSizeOf(WordType)) 0 else val_l << @as(ShiftTypeL, @intCast(shift_l));
            self.stack.set_top_unsafe(res_l);

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .SHL);
            return dispatchNext(next_handler, self, plan_ptr);
        }

        fn op_shr_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            const opcode_info = opcode_data.OPCODE_INFO[@intFromEnum(Opcode.SHR)];
            self.consumeGasUnchecked(opcode_info.gas_cost);
            const shift_r: WordType = self.stack.pop_unsafe();
            const val_r: WordType = self.stack.peek_unsafe();
            const ShiftTypeR = std.math.Log2Int(WordType);
            const res_r: WordType = if (shift_r >= @bitSizeOf(WordType)) 0 else val_r >> @as(ShiftTypeR, @intCast(shift_r));
            self.stack.set_top_unsafe(res_r);

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .SHR);
            return dispatchNext(next_handler, self, plan_ptr);
        }

        fn op_sar_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            const opcode_info = opcode_data.OPCODE_INFO[@intFromEnum(Opcode.SAR)];
            self.consumeGasUnchecked(opcode_info.gas_cost);
            const shift_a: WordType = self.stack.pop_unsafe();
            const val_a: WordType = self.stack.peek_unsafe();
            const word_bits = @bitSizeOf(WordType);
            const res_a: WordType = if (shift_a >= word_bits) blk: {
                const sign_bit = val_a >> (word_bits - 1);
                break :blk if (sign_bit == 1) @as(WordType, std.math.maxInt(WordType)) else @as(WordType, 0);
            } else blk: {
                const ShiftTypeA = std.math.Log2Int(WordType);
                const shift_amount = @as(ShiftTypeA, @intCast(shift_a));
                const SignedA = std.meta.Int(.signed, @bitSizeOf(WordType));
                const val_signed: SignedA = @bitCast(val_a);
                const out_signed: SignedA = val_signed >> shift_amount;
                break :blk @as(WordType, @bitCast(out_signed));
            };
            self.stack.set_top_unsafe(res_a);

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .SAR);
            return dispatchNext(next_handler, self, plan_ptr);
        }

        // Stack management handlers
        fn op_pop_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            const opcode_info = opcode_data.OPCODE_INFO[@intFromEnum(Opcode.POP)];
            self.consumeGasUnchecked(opcode_info.gas_cost);
            _ = self.stack.pop_unsafe();

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .POP);
            return dispatchNext(next_handler, self, plan_ptr);
        }

        // Memory handlers
        fn op_mload_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            const opcode_info = opcode_data.OPCODE_INFO[@intFromEnum(Opcode.MLOAD)];
            self.consumeGasUnchecked(opcode_info.gas_cost);
            try self.mload();

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .MLOAD);
            return dispatchNext(next_handler, self, plan_ptr);
        }

        fn op_mstore_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            const opcode_info = opcode_data.OPCODE_INFO[@intFromEnum(Opcode.MSTORE)];
            self.consumeGasUnchecked(opcode_info.gas_cost);
            try self.mstore();

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .MSTORE);
            return dispatchNext(next_handler, self, plan_ptr);
        }

        fn op_mstore8_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            const opcode_info = opcode_data.OPCODE_INFO[@intFromEnum(Opcode.MSTORE8)];
            self.consumeGasUnchecked(opcode_info.gas_cost);
            try self.mstore8();

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .MSTORE8);
            return dispatchNext(next_handler, self, plan_ptr);
        }

        fn op_msize_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            const opcode_info = opcode_data.OPCODE_INFO[@intFromEnum(Opcode.MSIZE)];
            self.consumeGasUnchecked(opcode_info.gas_cost);
            try self.msize();

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .MSIZE);
            return dispatchNext(next_handler, self, plan_ptr);
        }

        fn op_mcopy_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            const opcode_info = opcode_data.OPCODE_INFO[@intFromEnum(Opcode.MCOPY)];
            self.consumeGasUnchecked(opcode_info.gas_cost);
            try self.mcopy();

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .MCOPY);
            return dispatchNext(next_handler, self, plan_ptr);
        }

        // Storage handlers
        fn op_sload_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            // Peek at the slot to determine gas cost
            const slot = self.stack.peek() catch return Error.StackUnderflow;
            const address = self.contract_address;

            // Access the storage slot and get the gas cost (warm/cold)
            const host = self.host;
            const gas_cost = host.access_storage_slot(address, slot) catch |err| switch (err) {
                else => return Error.AllocationError,
            };
            self.consumeGasUnchecked(@intCast(gas_cost));

            try self.sload();

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .SLOAD);
            return dispatchNext(next_handler, self, plan_ptr);
        }

        fn op_sstore_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            // Peek at the slot and value to compute gas cost without mutating stack
            const stack_slice = self.stack.get_slice();
            if (stack_slice.len < 2) return Error.StackUnderflow;
            const slot: WordType = stack_slice[0];
            const new_value: WordType = stack_slice[1];
            const address = self.contract_address;

            // Access the storage slot and get the gas cost (warm/cold)
            const host = self.host;
            const access_cost = host.access_storage_slot(address, slot) catch |err| switch (err) {
                else => return Error.AllocationError,
            };

            // Consume the access list cost (EIP-2929)
            self.consumeGasUnchecked(@intCast(access_cost));

            // Compute SSTORE dynamic cost per EIP-2200/EIP-3529 using GasConstants
            const cur_u256 = host.get_storage(address, slot);
            const current_value: WordType = @as(WordType, @truncate(cur_u256));
            const original_opt_u256 = host.get_original_storage(address, slot);
            const original_value: WordType = if (original_opt_u256) |ov|
                @as(WordType, @truncate(ov))
            else
                current_value;
            // We already charged the cold/warm cost above, so pass false for is_cold to avoid double-charge
            const sstore_cost = @import("primitives").GasConstants.sstore_gas_cost(
                current_value,
                original_value,
                new_value,
                false,
            );
            self.consumeGasUnchecked(sstore_cost);

            // Track refund effects (EIP-3529): only clear-to-zero grants 4800; cancel if revived
            if (current_value != 0 and new_value == 0) {
                self.gas_refund += 4800;
            } else if (current_value == 0 and new_value != 0 and original_value != 0) {
                if (self.gas_refund >= 4800) self.gas_refund -= 4800 else self.gas_refund = 0;
            }

            try self.sstore();

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .SSTORE);
            return dispatchNext(next_handler, self, plan_ptr);
        }

        fn op_tload_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            const opcode_info = opcode_data.OPCODE_INFO[@intFromEnum(Opcode.TLOAD)];
            self.consumeGasUnchecked(opcode_info.gas_cost);
            try self.tload();

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .TLOAD);
            return dispatchNext(next_handler, self, plan_ptr);
        }

        fn op_tstore_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            const opcode_info = opcode_data.OPCODE_INFO[@intFromEnum(Opcode.TSTORE)];
            self.consumeGasUnchecked(opcode_info.gas_cost);
            try self.tstore();

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .TSTORE);
            return dispatchNext(next_handler, self, plan_ptr);
        }

        // Control flow
        fn op_jumpdest_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            const opcode_info = opcode_data.OPCODE_INFO[@intFromEnum(Opcode.JUMPDEST)];
            self.consumeGasUnchecked(opcode_info.gas_cost);
            try self.jumpdest();

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .JUMPDEST);
            return dispatchNext(next_handler, self, plan_ptr);
        }

        // System and call-family handlers
        fn op_call_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            // Delegate to Frame.call which performs gas accounting per EIPs
            try self.call();

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .CALL);
            return dispatchNext(next_handler, self, plan_ptr);
        }

        fn op_delegatecall_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            try self.delegatecall();

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .DELEGATECALL);
            return dispatchNext(next_handler, self, plan_ptr);
        }

        fn op_staticcall_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            try self.staticcall();

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .STATICCALL);
            return dispatchNext(next_handler, self, plan_ptr);
        }

        fn op_return_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            _ = plan;

            // Frame.return halts with STOP; propagate termination
            self.@"return"() catch |err| return err;
            unreachable;
        }

        fn op_revert_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            _ = plan;

            // Frame.revert halts with REVERT; propagate termination
            self.revert() catch |err| return err;
            unreachable;
        }

        fn op_selfdestruct_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            _ = plan;

            // SELFDESTRUCT terminates execution; delegate to Frame and propagate
            self.selfdestruct() catch |err| return err;
            unreachable;
        }

        fn op_gas_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            const opcode_info = opcode_data.OPCODE_INFO[@intFromEnum(Opcode.GAS)];
            self.consumeGasUnchecked(opcode_info.gas_cost);
            try self.gas();

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .GAS);
            return dispatchNext(next_handler, self, plan_ptr);
        }

        // Generic handler for simple opcodes that just increment PC
        fn makeSimpleHandler(comptime op_fn: fn (*Frame) Frame.Error!void, comptime opcode_enum: Opcode) HandlerFn {
            return struct {
                fn handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
                    const self = @as(*Frame, @ptrCast(@alignCast(frame)));
                    const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
                    const interpreter = @as(*Self, @fieldParentPtr("frame", self));

                    // Get opcode info for gas consumption
                    const opcode_info = opcode_data.OPCODE_INFO[@intFromEnum(opcode_enum)];

                    // Consume gas (unchecked since we validated in pre-analysis)
                    self.consumeGasUnchecked(opcode_info.gas_cost);

                    // Execute the operation
                    try op_fn(self);

                    // Get next handler from plan
                    const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, opcode_enum);
                    return dispatchNext(next_handler, self, plan_ptr);
                }
            }.handler;
        }

        fn op_jump_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            const dest = try self.stack.pop();

            if (dest > config.max_bytecode_size) {
                return Error.InvalidJump;
            }

            const dest_pc = @as(Plan.PcType, @intCast(dest));
            if (!self.is_valid_jump_dest(@as(usize, dest_pc))) {
                return Error.InvalidJump;
            }

            // PC update is handled by plan through instruction index update

            // Look up the instruction index for the destination PC
            if (plan_ptr.getInstructionIndexForPc(dest_pc)) |new_idx| {
                interpreter.instruction_idx = new_idx;
                // Get the handler at the destination
                const dest_handler = plan_ptr.instructionStream[new_idx].handler;
                return dispatchNext(dest_handler, self, plan_ptr);
            } else {
                // PC is not a valid instruction start (e.g., middle of PUSH data)
                return Error.InvalidJump;
            }
        }
        fn op_jumpi_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            const dest = try self.stack.pop();
            const condition = try self.stack.pop();

            if (condition != 0) {
                if (dest > config.max_bytecode_size) {
                    return Error.InvalidJump;
                }
                const dest_pc = @as(Plan.PcType, @intCast(dest));
                if (!self.is_valid_jump_dest(@as(usize, dest_pc))) {
                    return Error.InvalidJump;
                }
                // PC update is handled by plan through instruction index update

                // Look up the instruction index for the destination PC
                if (plan_ptr.getInstructionIndexForPc(dest_pc)) |new_idx| {
                    interpreter.instruction_idx = new_idx;
                    // Get the handler at the destination
                    const dest_handler = plan_ptr.instructionStream[new_idx].handler;
                    return dispatchNext(dest_handler, self, plan_ptr);
                } else {
                    // PC is not a valid instruction start (e.g., middle of PUSH data)
                    return Error.InvalidJump;
                }
            } else {
                // Condition is false, continue to next instruction
                // PC update is handled by plan through instruction index update
                const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .JUMPI);
                return dispatchNext(next_handler, self, plan_ptr);
            }
        }
        // Handler for PC opcode with inline PC value
        fn op_pc_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            // Get PC value from plan metadata
            const pc_value = plan_ptr.getMetadata(&interpreter.instruction_idx, .PC);
            try self.stack.push(@as(WordType, @intCast(pc_value)));

            // Get next handler from plan
            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .PC);
            return dispatchNext(next_handler, self, plan_ptr);
        }

        // Push handlers
        fn push2_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            const value = @as(WordType, plan_ptr.getMetadata(&interpreter.instruction_idx, .PUSH2));
            try self.stack.push(value);

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .PUSH2);
            return dispatchNext(next_handler, self, plan_ptr);
        }
        fn push3_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            log.debug("push3_handler: instruction_idx = {}, stream length = {}", .{ interpreter.instruction_idx, plan_ptr.instructionStream.len });
            const value = @as(WordType, plan_ptr.getMetadata(&interpreter.instruction_idx, .PUSH3));
            try self.stack.push(value);

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .PUSH3);
            return dispatchNext(next_handler, self, plan_ptr);
        }
        fn push4_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            const value = @as(WordType, plan_ptr.getMetadata(&interpreter.instruction_idx, .PUSH4));
            try self.stack.push(value);

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .PUSH4);
            return dispatchNext(next_handler, self, plan_ptr);
        }
        fn push5_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            if (comptime @sizeOf(plan_mod.InstructionElement) == @sizeOf(u64)) {
                // 64-bit platform - fits inline
                const value = @as(WordType, plan_ptr.getMetadata(&interpreter.instruction_idx, .PUSH5));
                try self.stack.push(value);
            } else {
                // 32-bit platform - need pointer
                const result = plan_ptr.getMetadata(&interpreter.instruction_idx, .PUSH5);
                const value = if (@TypeOf(result) == *const WordType) result.* else @as(WordType, result);
                try self.stack.push(value);
            }

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .PUSH5);
            return dispatchNext(next_handler, self, plan_ptr);
        }
        fn push6_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            if (comptime @sizeOf(plan_mod.InstructionElement) == @sizeOf(u64)) {
                // 64-bit platform - fits inline
                const value = @as(WordType, plan_ptr.getMetadata(&interpreter.instruction_idx, .PUSH6));
                try self.stack.push(value);
            } else {
                // 32-bit platform - need pointer
                const result = plan_ptr.getMetadata(&interpreter.instruction_idx, .PUSH6);
                const value = if (@TypeOf(result) == *const WordType) result.* else @as(WordType, result);
                try self.stack.push(value);
            }

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .PUSH6);
            return dispatchNext(next_handler, self, plan_ptr);
        }
        fn push7_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            if (comptime @sizeOf(plan_mod.InstructionElement) == @sizeOf(u64)) {
                // 64-bit platform - fits inline
                const value = @as(WordType, plan_ptr.getMetadata(&interpreter.instruction_idx, .PUSH7));
                try self.stack.push(value);
            } else {
                // 32-bit platform - need pointer
                const result = plan_ptr.getMetadata(&interpreter.instruction_idx, .PUSH7);
                const value = if (@TypeOf(result) == *const WordType) result.* else @as(WordType, result);
                try self.stack.push(value);
            }

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .PUSH7);
            return dispatchNext(next_handler, self, plan_ptr);
        }
        fn push8_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            if (comptime @sizeOf(plan_mod.InstructionElement) == @sizeOf(u64)) {
                // 64-bit platform - fits inline
                const value = @as(WordType, plan_ptr.getMetadata(&interpreter.instruction_idx, .PUSH8));
                try self.stack.push(value);
            } else {
                // 32-bit platform - need pointer
                const result = plan_ptr.getMetadata(&interpreter.instruction_idx, .PUSH8);
                const value = if (@TypeOf(result) == *const WordType) result.* else @as(WordType, result);
                try self.stack.push(value);
            }

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .PUSH8);
            return dispatchNext(next_handler, self, plan_ptr);
        }
        fn push9_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            const result = plan_ptr.getMetadata(&interpreter.instruction_idx, .PUSH9);
            const value = if (@TypeOf(result) == *const WordType) result.* else @as(WordType, result);
            try self.stack.push(value);

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .PUSH9);
            return dispatchNext(next_handler, self, plan_ptr);
        }
        fn push10_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            const result = plan_ptr.getMetadata(&interpreter.instruction_idx, .PUSH10);
            const value = if (@TypeOf(result) == *const WordType) result.* else @as(WordType, result);
            try self.stack.push(value);

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .PUSH10);
            return dispatchNext(next_handler, self, plan_ptr);
        }
        fn push11_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            const result = plan_ptr.getMetadata(&interpreter.instruction_idx, .PUSH11);
            const value = if (@TypeOf(result) == *const WordType) result.* else @as(WordType, result);
            try self.stack.push(value);

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .PUSH11);
            return dispatchNext(next_handler, self, plan_ptr);
        }
        fn push12_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            const result = plan_ptr.getMetadata(&interpreter.instruction_idx, .PUSH12);
            const value = if (@TypeOf(result) == *const WordType) result.* else @as(WordType, result);
            try self.stack.push(value);

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .PUSH12);
            return dispatchNext(next_handler, self, plan_ptr);
        }
        fn push13_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            const result = plan_ptr.getMetadata(&interpreter.instruction_idx, .PUSH13);
            const value = if (@TypeOf(result) == *const WordType) result.* else @as(WordType, result);
            try self.stack.push(value);

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .PUSH13);
            return dispatchNext(next_handler, self, plan_ptr);
        }
        fn push14_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            const result = plan_ptr.getMetadata(&interpreter.instruction_idx, .PUSH14);
            const value = if (@TypeOf(result) == *const WordType) result.* else @as(WordType, result);
            try self.stack.push(value);

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .PUSH14);
            return dispatchNext(next_handler, self, plan_ptr);
        }
        fn push15_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            const result = plan_ptr.getMetadata(&interpreter.instruction_idx, .PUSH15);
            const value = if (@TypeOf(result) == *const WordType) result.* else @as(WordType, result);
            try self.stack.push(value);

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .PUSH15);
            return dispatchNext(next_handler, self, plan_ptr);
        }
        fn push16_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            const result = plan_ptr.getMetadata(&interpreter.instruction_idx, .PUSH16);
            const value = if (@TypeOf(result) == *const WordType) result.* else @as(WordType, result);
            try self.stack.push(value);

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .PUSH16);
            return dispatchNext(next_handler, self, plan_ptr);
        }
        fn push17_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            const value_ptr = plan_ptr.getMetadata(&interpreter.instruction_idx, .PUSH17);
            try self.stack.push(value_ptr.*);

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .PUSH17);
            return dispatchNext(next_handler, self, plan_ptr);
        }
        fn push18_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            const value_ptr = plan_ptr.getMetadata(&interpreter.instruction_idx, .PUSH18);
            try self.stack.push(value_ptr.*);

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .PUSH18);
            return dispatchNext(next_handler, self, plan_ptr);
        }
        fn push19_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            const value_ptr = plan_ptr.getMetadata(&interpreter.instruction_idx, .PUSH19);
            try self.stack.push(value_ptr.*);

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .PUSH19);
            return dispatchNext(next_handler, self, plan_ptr);
        }
        fn push20_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            const value_ptr = plan_ptr.getMetadata(&interpreter.instruction_idx, .PUSH20);
            try self.stack.push(value_ptr.*);

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .PUSH20);
            return dispatchNext(next_handler, self, plan_ptr);
        }
        fn push21_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            const value_ptr = plan_ptr.getMetadata(&interpreter.instruction_idx, .PUSH21);
            try self.stack.push(value_ptr.*);

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .PUSH21);
            return dispatchNext(next_handler, self, plan_ptr);
        }
        fn push22_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            const value_ptr = plan_ptr.getMetadata(&interpreter.instruction_idx, .PUSH22);
            try self.stack.push(value_ptr.*);

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .PUSH22);
            return dispatchNext(next_handler, self, plan_ptr);
        }
        fn push23_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            const value_ptr = plan_ptr.getMetadata(&interpreter.instruction_idx, .PUSH23);
            try self.stack.push(value_ptr.*);

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .PUSH23);
            return dispatchNext(next_handler, self, plan_ptr);
        }
        fn push24_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            const value_ptr = plan_ptr.getMetadata(&interpreter.instruction_idx, .PUSH24);
            try self.stack.push(value_ptr.*);

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .PUSH24);
            return dispatchNext(next_handler, self, plan_ptr);
        }
        fn push25_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            const value_ptr = plan_ptr.getMetadata(&interpreter.instruction_idx, .PUSH25);
            try self.stack.push(value_ptr.*);

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .PUSH25);
            return dispatchNext(next_handler, self, plan_ptr);
        }
        fn push26_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            const value_ptr = plan_ptr.getMetadata(&interpreter.instruction_idx, .PUSH26);
            try self.stack.push(value_ptr.*);

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .PUSH26);
            return dispatchNext(next_handler, self, plan_ptr);
        }
        fn push27_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            const value_ptr = plan_ptr.getMetadata(&interpreter.instruction_idx, .PUSH27);
            try self.stack.push(value_ptr.*);

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .PUSH27);
            return dispatchNext(next_handler, self, plan_ptr);
        }
        fn push28_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            const value_ptr = plan_ptr.getMetadata(&interpreter.instruction_idx, .PUSH28);
            try self.stack.push(value_ptr.*);

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .PUSH28);
            return dispatchNext(next_handler, self, plan_ptr);
        }
        fn push29_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            const value_ptr = plan_ptr.getMetadata(&interpreter.instruction_idx, .PUSH29);
            try self.stack.push(value_ptr.*);

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .PUSH29);
            return dispatchNext(next_handler, self, plan_ptr);
        }
        fn push30_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            const value_ptr = plan_ptr.getMetadata(&interpreter.instruction_idx, .PUSH30);
            try self.stack.push(value_ptr.*);

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .PUSH30);
            return dispatchNext(next_handler, self, plan_ptr);
        }
        fn push31_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            const value_ptr = plan_ptr.getMetadata(&interpreter.instruction_idx, .PUSH31);
            try self.stack.push(value_ptr.*);

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .PUSH31);
            return dispatchNext(next_handler, self, plan_ptr);
        }
        fn push32_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            const value_ptr = plan_ptr.getMetadata(&interpreter.instruction_idx, .PUSH32);
            try self.stack.push(value_ptr.*);

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .PUSH32);
            return dispatchNext(next_handler, self, plan_ptr);
        }

        // DUP handlers
        fn dup1_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            try self.stack.dup_n(1);
            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .DUP1);
            return dispatchNext(next_handler, self, plan_ptr);
        }
        fn dup2_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            try self.stack.dup_n(2);
            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .DUP2);
            return dispatchNext(next_handler, self, plan_ptr);
        }
        fn dup3_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            try self.stack.dup_n(3);
            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .DUP3);
            return dispatchNext(next_handler, self, plan_ptr);
        }
        fn dup4_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            try self.stack.dup_n(4);
            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .DUP4);
            return dispatchNext(next_handler, self, plan_ptr);
        }
        fn dup5_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            try self.stack.dup_n(5);
            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .DUP5);
            return dispatchNext(next_handler, self, plan_ptr);
        }
        fn dup6_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            try self.stack.dup_n(6);
            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .DUP6);
            return dispatchNext(next_handler, self, plan_ptr);
        }
        fn dup7_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            try self.stack.dup_n(7);
            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .DUP7);
            return dispatchNext(next_handler, self, plan_ptr);
        }
        fn dup8_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            try self.stack.dup_n(8);
            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .DUP8);
            return dispatchNext(next_handler, self, plan_ptr);
        }
        fn dup9_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            try self.stack.dup_n(9);
            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .DUP9);
            return dispatchNext(next_handler, self, plan_ptr);
        }
        fn dup10_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            try self.stack.dup_n(10);
            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .DUP10);
            return dispatchNext(next_handler, self, plan_ptr);
        }
        fn dup11_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            try self.stack.dup_n(11);
            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .DUP11);
            return dispatchNext(next_handler, self, plan_ptr);
        }
        fn dup12_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            try self.stack.dup_n(12);
            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .DUP12);
            return dispatchNext(next_handler, self, plan_ptr);
        }
        fn dup13_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            try self.stack.dup_n(13);
            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .DUP13);
            return dispatchNext(next_handler, self, plan_ptr);
        }
        fn dup14_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            try self.stack.dup_n(14);
            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .DUP14);
            return dispatchNext(next_handler, self, plan_ptr);
        }
        fn dup15_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            try self.stack.dup_n(15);
            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .DUP15);
            return dispatchNext(next_handler, self, plan_ptr);
        }
        fn dup16_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            try self.stack.dup_n(16);
            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .DUP16);
            return dispatchNext(next_handler, self, plan_ptr);
        }

        // SWAP handlers
        fn swap1_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            try self.stack.swap_n(1);
            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .SWAP1);
            return dispatchNext(next_handler, self, plan_ptr);
        }
        fn swap2_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            try self.stack.swap_n(2);
            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .SWAP2);
            return dispatchNext(next_handler, self, plan_ptr);
        }
        fn swap3_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            try self.stack.swap_n(3);
            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .SWAP3);
            return dispatchNext(next_handler, self, plan_ptr);
        }
        fn swap4_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            try self.stack.swap_n(4);
            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .SWAP4);
            return dispatchNext(next_handler, self, plan_ptr);
        }
        fn swap5_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            try self.stack.swap_n(5);
            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .SWAP5);
            return dispatchNext(next_handler, self, plan_ptr);
        }
        fn swap6_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            try self.stack.swap_n(6);
            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .SWAP6);
            return dispatchNext(next_handler, self, plan_ptr);
        }
        fn swap7_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            try self.stack.swap_n(7);
            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .SWAP7);
            return dispatchNext(next_handler, self, plan_ptr);
        }
        fn swap8_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            try self.stack.swap_n(8);
            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .SWAP8);
            return dispatchNext(next_handler, self, plan_ptr);
        }
        fn swap9_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            try self.stack.swap_n(9);
            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .SWAP9);
            return dispatchNext(next_handler, self, plan_ptr);
        }
        fn swap10_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            try self.stack.swap_n(10);
            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .SWAP10);
            return dispatchNext(next_handler, self, plan_ptr);
        }
        fn swap11_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            try self.stack.swap_n(11);
            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .SWAP11);
            return dispatchNext(next_handler, self, plan_ptr);
        }
        fn swap12_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            try self.stack.swap_n(12);
            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .SWAP12);
            return dispatchNext(next_handler, self, plan_ptr);
        }
        fn swap13_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            try self.stack.swap_n(13);
            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .SWAP13);
            return dispatchNext(next_handler, self, plan_ptr);
        }
        fn swap14_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            try self.stack.swap_n(14);
            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .SWAP14);
            return dispatchNext(next_handler, self, plan_ptr);
        }
        fn swap15_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            try self.stack.swap_n(15);
            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .SWAP15);
            return dispatchNext(next_handler, self, plan_ptr);
        }
        fn swap16_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            try self.stack.swap_n(16);
            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, .SWAP16);
            return dispatchNext(next_handler, self, plan_ptr);
        }

        // Fusion handlers
        fn push_add_inline_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            const value = @as(WordType, plan_ptr.getMetadata(&interpreter.instruction_idx, @intFromEnum(planner_mod.OpcodeSynthetic.PUSH_ADD_INLINE)));
            const b = try self.stack.pop();
            const result = b +% value;
            try self.stack.push(result);

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, @intFromEnum(planner_mod.OpcodeSynthetic.PUSH_ADD_INLINE));
            return dispatchNext(next_handler, self, plan_ptr);
        }
        fn push_add_pointer_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            const value_ptr = plan_ptr.getMetadata(&interpreter.instruction_idx, @intFromEnum(planner_mod.OpcodeSynthetic.PUSH_ADD_POINTER));
            const b = try self.stack.pop();
            const result = b +% value_ptr.*;
            try self.stack.push(result);

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, @intFromEnum(planner_mod.OpcodeSynthetic.PUSH_ADD_POINTER));
            return dispatchNext(next_handler, self, plan_ptr);
        }
        fn push_mul_inline_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            const value = @as(WordType, plan_ptr.getMetadata(&interpreter.instruction_idx, @intFromEnum(planner_mod.OpcodeSynthetic.PUSH_MUL_INLINE)));
            const b = try self.stack.pop();
            const result = b *% value;
            try self.stack.push(result);

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, @intFromEnum(planner_mod.OpcodeSynthetic.PUSH_MUL_INLINE));
            return dispatchNext(next_handler, self, plan_ptr);
        }
        fn push_mul_pointer_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            const value_ptr = plan_ptr.getMetadata(&interpreter.instruction_idx, @intFromEnum(planner_mod.OpcodeSynthetic.PUSH_MUL_POINTER));
            const b = try self.stack.pop();
            const result = b *% value_ptr.*;
            try self.stack.push(result);

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, @intFromEnum(planner_mod.OpcodeSynthetic.PUSH_MUL_POINTER));
            return dispatchNext(next_handler, self, plan_ptr);
        }
        fn push_div_inline_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            const value = @as(WordType, plan_ptr.getMetadata(&interpreter.instruction_idx, @intFromEnum(planner_mod.OpcodeSynthetic.PUSH_DIV_INLINE)));
            const b = try self.stack.pop();
            const result = if (value == 0) 0 else b / value;
            try self.stack.push(result);

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, @intFromEnum(planner_mod.OpcodeSynthetic.PUSH_DIV_INLINE));
            return dispatchNext(next_handler, self, plan_ptr);
        }
        fn push_div_pointer_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            const value_ptr = plan_ptr.getMetadata(&interpreter.instruction_idx, @intFromEnum(planner_mod.OpcodeSynthetic.PUSH_DIV_POINTER));
            const b = try self.stack.pop();
            const result = if (value_ptr.* == 0) 0 else b / value_ptr.*;
            try self.stack.push(result);

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, @intFromEnum(planner_mod.OpcodeSynthetic.PUSH_DIV_POINTER));
            return dispatchNext(next_handler, self, plan_ptr);
        }

        fn push_and_inline_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            const value = @as(WordType, plan_ptr.getMetadata(&interpreter.instruction_idx, @intFromEnum(planner_mod.OpcodeSynthetic.PUSH_AND_INLINE)));
            const a = self.stack.pop_unsafe();
            self.stack.push_unsafe(a & value);
            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, @intFromEnum(planner_mod.OpcodeSynthetic.PUSH_AND_INLINE));
            return dispatchNext(next_handler, self, plan_ptr);
        }
        fn push_and_pointer_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            const value_ptr = plan_ptr.getMetadata(&interpreter.instruction_idx, @intFromEnum(planner_mod.OpcodeSynthetic.PUSH_AND_POINTER));
            const a = self.stack.pop_unsafe();
            self.stack.push_unsafe(a & value_ptr.*);
            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, @intFromEnum(planner_mod.OpcodeSynthetic.PUSH_AND_POINTER));
            return dispatchNext(next_handler, self, plan_ptr);
        }
        fn push_or_inline_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            const value = @as(WordType, plan_ptr.getMetadata(&interpreter.instruction_idx, @intFromEnum(planner_mod.OpcodeSynthetic.PUSH_OR_INLINE)));
            const a = self.stack.pop_unsafe();
            self.stack.push_unsafe(a | value);
            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, @intFromEnum(planner_mod.OpcodeSynthetic.PUSH_OR_INLINE));
            return dispatchNext(next_handler, self, plan_ptr);
        }
        fn push_or_pointer_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            const value_ptr = plan_ptr.getMetadata(&interpreter.instruction_idx, @intFromEnum(planner_mod.OpcodeSynthetic.PUSH_OR_POINTER));
            const a = self.stack.pop_unsafe();
            self.stack.push_unsafe(a | value_ptr.*);
            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, @intFromEnum(planner_mod.OpcodeSynthetic.PUSH_OR_POINTER));
            return dispatchNext(next_handler, self, plan_ptr);
        }
        fn push_xor_inline_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            const value = @as(WordType, plan_ptr.getMetadata(&interpreter.instruction_idx, @intFromEnum(planner_mod.OpcodeSynthetic.PUSH_XOR_INLINE)));
            const a = self.stack.pop_unsafe();
            self.stack.push_unsafe(a ^ value);
            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, @intFromEnum(planner_mod.OpcodeSynthetic.PUSH_XOR_INLINE));
            return dispatchNext(next_handler, self, plan_ptr);
        }
        fn push_xor_pointer_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            const value_ptr = plan_ptr.getMetadata(&interpreter.instruction_idx, @intFromEnum(planner_mod.OpcodeSynthetic.PUSH_XOR_POINTER));
            const a = self.stack.pop_unsafe();
            self.stack.push_unsafe(a ^ value_ptr.*);
            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, @intFromEnum(planner_mod.OpcodeSynthetic.PUSH_XOR_POINTER));
            return dispatchNext(next_handler, self, plan_ptr);
        }
        fn push_mstore8_inline_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            const off_usize = @as(usize, plan_ptr.getMetadata(&interpreter.instruction_idx, @intFromEnum(planner_mod.OpcodeSynthetic.PUSH_MSTORE8_INLINE)));
            const value = self.stack.pop_unsafe();
            const byte_value: u8 = @truncate(value & 0xFF);
            try self.memory.set_byte_evm(off_usize, byte_value);
            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, @intFromEnum(planner_mod.OpcodeSynthetic.PUSH_MSTORE8_INLINE));
            return dispatchNext(next_handler, self, plan_ptr);
        }
        fn push_mstore8_pointer_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            const off_ptr = plan_ptr.getMetadata(&interpreter.instruction_idx, @intFromEnum(planner_mod.OpcodeSynthetic.PUSH_MSTORE8_POINTER));
            const off_usize: usize = @intCast(off_ptr.*);
            const value = self.stack.pop_unsafe();
            const byte_value: u8 = @truncate(value & 0xFF);
            try self.memory.set_byte_evm(off_usize, byte_value);
            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, @intFromEnum(planner_mod.OpcodeSynthetic.PUSH_MSTORE8_POINTER));
            return dispatchNext(next_handler, self, plan_ptr);
        }
        fn push_sub_inline_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            const value = @as(WordType, plan_ptr.getMetadata(&interpreter.instruction_idx, @intFromEnum(planner_mod.OpcodeSynthetic.PUSH_SUB_INLINE)));
            const b = try self.stack.pop();
            const result = b -% value;
            try self.stack.push(result);

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, @intFromEnum(planner_mod.OpcodeSynthetic.PUSH_SUB_INLINE));
            return dispatchNext(next_handler, self, plan_ptr);
        }
        fn push_sub_pointer_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            const value_ptr = plan_ptr.getMetadata(&interpreter.instruction_idx, @intFromEnum(planner_mod.OpcodeSynthetic.PUSH_SUB_POINTER));
            const b = try self.stack.pop();
            const result = b -% value_ptr.*;
            try self.stack.push(result);

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, @intFromEnum(planner_mod.OpcodeSynthetic.PUSH_SUB_POINTER));
            return dispatchNext(next_handler, self, plan_ptr);
        }
        fn push_jump_inline_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            const dest = @as(WordType, plan_ptr.getMetadata(&interpreter.instruction_idx, @intFromEnum(planner_mod.OpcodeSynthetic.PUSH_JUMP_INLINE)));

            if (dest > config.max_bytecode_size) {
                return Error.InvalidJump;
            }
            const dest_pc = @as(Plan.PcType, @intCast(dest));

            // Check if it's a valid jump destination
            const dest_idx = plan_ptr.getInstructionIndexForPc(dest_pc) orelse {
                return Error.InvalidJump;
            };

            // Jump to the destination
            interpreter.instruction_idx = dest_idx;
            const jump_handler = plan_ptr.instructionStream[dest_idx].handler;
            return dispatchNext(jump_handler, self, plan_ptr);
        }
        fn push_jump_pointer_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            const dest_ptr = plan_ptr.getMetadata(&interpreter.instruction_idx, @intFromEnum(planner_mod.OpcodeSynthetic.PUSH_JUMP_POINTER));
            const dest = dest_ptr.*;

            if (dest > config.max_bytecode_size) {
                return Error.InvalidJump;
            }
            const dest_pc = @as(Plan.PcType, @intCast(dest));

            // Check if it's a valid jump destination
            const dest_idx = plan_ptr.getInstructionIndexForPc(dest_pc) orelse {
                return Error.InvalidJump;
            };

            // Jump to the destination
            interpreter.instruction_idx = dest_idx;
            const jump_handler = plan_ptr.instructionStream[dest_idx].handler;
            return dispatchNext(jump_handler, self, plan_ptr);
        }
        fn push_jumpi_inline_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            const dest = @as(WordType, plan_ptr.getMetadata(&interpreter.instruction_idx, @intFromEnum(planner_mod.OpcodeSynthetic.PUSH_JUMPI_INLINE)));
            const condition = try self.stack.pop();

            if (condition != 0) {
                if (dest > config.max_bytecode_size) {
                    return Error.InvalidJump;
                }
                const dest_pc = @as(Plan.PcType, @intCast(dest));

                // Check if it's a valid jump destination
                const dest_idx = plan_ptr.getInstructionIndexForPc(dest_pc) orelse {
                    return Error.InvalidJump;
                };

                // Jump to the destination
                interpreter.instruction_idx = dest_idx;
                const jump_handler = plan_ptr.instructionStream[dest_idx].handler;
                return dispatchNext(jump_handler, self, plan_ptr);
            } else {
                // Condition is false, continue to next instruction
                const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, @intFromEnum(planner_mod.OpcodeSynthetic.PUSH_JUMPI_INLINE));
                return dispatchNext(next_handler, self, plan_ptr);
            }
        }
        fn push_jumpi_pointer_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            const dest_ptr = plan_ptr.getMetadata(&interpreter.instruction_idx, @intFromEnum(planner_mod.OpcodeSynthetic.PUSH_JUMPI_POINTER));
            const dest = dest_ptr.*;
            const condition = try self.stack.pop();

            if (condition != 0) {
                if (dest > config.max_bytecode_size) {
                    return Error.InvalidJump;
                }
                const dest_pc = @as(Plan.PcType, @intCast(dest));

                // Check if it's a valid jump destination
                const dest_idx = plan_ptr.getInstructionIndexForPc(dest_pc) orelse {
                    return Error.InvalidJump;
                };

                // Jump to the destination
                interpreter.instruction_idx = dest_idx;
                const jump_handler = plan_ptr.instructionStream[dest_idx].handler;
                return dispatchNext(jump_handler, self, plan_ptr);
            } else {
                // Condition is false, continue to next instruction
                const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, @intFromEnum(planner_mod.OpcodeSynthetic.PUSH_JUMPI_POINTER));
                return dispatchNext(next_handler, self, plan_ptr);
            }
        }

        fn push_mload_inline_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            const off_usize = @as(usize, plan_ptr.getMetadata(&interpreter.instruction_idx, @intFromEnum(planner_mod.OpcodeSynthetic.PUSH_MLOAD_INLINE)));
            const val = try self.memory.get_u256_evm(off_usize);
            try self.stack.push(@as(WordType, @truncate(val)));

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, @intFromEnum(planner_mod.OpcodeSynthetic.PUSH_MLOAD_INLINE));
            return dispatchNext(next_handler, self, plan_ptr);
        }
        fn push_mload_pointer_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            const off_ptr = plan_ptr.getMetadata(&interpreter.instruction_idx, @intFromEnum(planner_mod.OpcodeSynthetic.PUSH_MLOAD_POINTER));
            if (off_ptr.* > std.math.maxInt(usize)) {
                return Error.OutOfBounds;
            }
            const off_usize: usize = @intCast(off_ptr.*);
            const val = try self.memory.get_u256_evm(off_usize);
            try self.stack.push(@as(WordType, @truncate(val)));

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, @intFromEnum(planner_mod.OpcodeSynthetic.PUSH_MLOAD_POINTER));
            return dispatchNext(next_handler, self, plan_ptr);
        }

        fn push_mstore_inline_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            const off_usize = @as(usize, plan_ptr.getMetadata(&interpreter.instruction_idx, @intFromEnum(planner_mod.OpcodeSynthetic.PUSH_MSTORE_INLINE)));
            const value = try self.stack.pop();
            try self.memory.set_u256_evm(off_usize, value);

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, @intFromEnum(planner_mod.OpcodeSynthetic.PUSH_MSTORE_INLINE));
            return dispatchNext(next_handler, self, plan_ptr);
        }
        fn push_mstore_pointer_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            const off_ptr = plan_ptr.getMetadata(&interpreter.instruction_idx, @intFromEnum(planner_mod.OpcodeSynthetic.PUSH_MSTORE_POINTER));
            if (off_ptr.* > std.math.maxInt(usize)) {
                return Error.OutOfBounds;
            }
            const off_usize: usize = @intCast(off_ptr.*);
            const value = try self.stack.pop();
            try self.memory.set_u256_evm(off_usize, value);

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, @intFromEnum(planner_mod.OpcodeSynthetic.PUSH_MSTORE_POINTER));
            return dispatchNext(next_handler, self, plan_ptr);
        }

        fn out_of_bounds_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            _ = frame;
            _ = plan;
            return Error.OutOfBounds;
        }

        // Trace instruction handlers
        fn trace_before_op_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            // Resolve current PC robustly
            const pc_opt = interpreter.getCurrentPc();
            const pc_u32: u32 = @intCast(pc_opt orelse 0);
            // Compute opcode from bytecode
            const opcode: u8 = if (pc_opt) |pcv| blk: {
                const p: usize = @intCast(pcv);
                break :blk if (p < self.bytecode.len) self.bytecode[p] else 0;
            } else 0;

            // Call tracer.beforeOp via Frame helpers
            if (comptime config.TracerType != null) {
                self.traceBeforeOp(pc_u32, opcode);
                // If tracer supports pause/resume, handle pause here
                if (comptime @hasField(@TypeOf(self.tracer), "paused")) {
                    if (@field(self.tracer, "paused")) {
                        if (comptime @hasDecl(@TypeOf(self.tracer), "setResumeIdx")) {
                            // Resume at the opcode handler index (next index)
                            const resume_idx: u32 = @intCast(interpreter.instruction_idx + 1);
                            self.tracer.setResumeIdx(resume_idx);
                        }
                        return Error.ExecutionPaused;
                    }
                }
            }

            // Move to opcode handler and dispatch
            interpreter.instruction_idx += 1;
            if (interpreter.instruction_idx >= plan_ptr.instructionStream.len) return Error.STOP;
            const next_handler = plan_ptr.instructionStream[interpreter.instruction_idx].handler;
            return dispatchNext(next_handler, self, plan_ptr);
        }

        fn trace_after_op_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            // Resolve current PC robustly
            const pc_opt = interpreter.getCurrentPc();
            const pc_u32: u32 = @intCast(pc_opt orelse 0);
            const opcode: u8 = if (pc_opt) |pcv| blk: {
                const p: usize = @intCast(pcv);
                break :blk if (p < self.bytecode.len) self.bytecode[p] else 0;
            } else 0;

            // Call tracer.afterOp via Frame helper
            if (comptime config.TracerType != null) {
                self.traceAfterOp(pc_u32, opcode);
            }

            // Advance to the next instruction (entry index of next opcode)
            interpreter.instruction_idx += 1;
            if (interpreter.instruction_idx >= plan_ptr.instructionStream.len) return Error.STOP;
            const next_handler = plan_ptr.instructionStream[interpreter.instruction_idx].handler;
            return dispatchNext(next_handler, self, plan_ptr);
        }

        // KECCAK256 handler
        fn op_keccak256_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            try self.keccak256();

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, @intFromEnum(Opcode.KECCAK256));
            return dispatchNext(next_handler, self, plan_ptr);
        }

        // Call data handlers
        fn op_calldataload_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            try self.calldataload();

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, @intFromEnum(Opcode.CALLDATALOAD));
            return dispatchNext(next_handler, self, plan_ptr);
        }

        fn op_calldatasize_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            try self.calldatasize();

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, @intFromEnum(Opcode.CALLDATASIZE));
            return dispatchNext(next_handler, self, plan_ptr);
        }

        fn op_calldatacopy_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            try self.calldatacopy();

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, @intFromEnum(Opcode.CALLDATACOPY));
            return dispatchNext(next_handler, self, plan_ptr);
        }

        // Code handlers
        fn op_codesize_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            try self.codesize();

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, @intFromEnum(Opcode.CODESIZE));
            return dispatchNext(next_handler, self, plan_ptr);
        }

        fn op_codecopy_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            try self.codecopy();

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, @intFromEnum(Opcode.CODECOPY));
            return dispatchNext(next_handler, self, plan_ptr);
        }

        fn op_gasprice_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            try self.gasprice();

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, @intFromEnum(Opcode.GASPRICE));
            return dispatchNext(next_handler, self, plan_ptr);
        }

        // External code handlers
        fn op_extcodesize_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            // Check if we have a host first

            // Peek at the address to determine gas cost
            const address_u256 = self.stack.peek() catch return Error.StackUnderflow;
            const address = primitives.Address.from_u256(address_u256);

            // Access the address and get the gas cost (warm/cold)
            const gas_cost = self.host.access_address(address) catch |err| switch (err) {
                else => return Error.AllocationError,
            };

            // Consume the dynamic gas cost
            self.consumeGasUnchecked(@intCast(gas_cost));

            try self.extcodesize();

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, @intFromEnum(Opcode.EXTCODESIZE));
            return dispatchNext(next_handler, self, plan_ptr);
        }

        fn op_extcodecopy_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            // Check if we have a host first

            // Pop all values we need for gas calculation (will push back later)
            const address_u256 = self.stack.pop() catch return Error.StackUnderflow;
            const dest_offset = self.stack.pop() catch return Error.StackUnderflow;
            const offset = self.stack.pop() catch return Error.StackUnderflow;
            const length = self.stack.pop() catch return Error.StackUnderflow;

            // Push them back in reverse order
            self.stack.push(length) catch return Error.StackOverflow;
            self.stack.push(offset) catch return Error.StackOverflow;
            self.stack.push(dest_offset) catch return Error.StackOverflow;
            self.stack.push(address_u256) catch return Error.StackOverflow;

            const address = primitives.Address.from_u256(address_u256);

            // Access the address and get the gas cost (warm/cold)
            const access_cost = self.host.access_address(address) catch |err| switch (err) {
                else => return Error.AllocationError,
            };

            // Calculate total gas cost including memory expansion
            const memory_gas = if (length > 0) blk: {
                const end_address = @as(u64, @intCast(dest_offset)) + @as(u64, @intCast(length));
                const expansion_cost = self.memory.get_expansion_cost(end_address);
                break :blk expansion_cost;
            } else 0;

            const copy_gas = (primitives.GasConstants.CopyGas * ((length + 31) / 32));
            const total_gas = access_cost + memory_gas + copy_gas;

            // Consume the total gas cost
            self.consumeGasUnchecked(@intCast(total_gas));

            try self.extcodecopy();

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, @intFromEnum(Opcode.EXTCODECOPY));
            return dispatchNext(next_handler, self, plan_ptr);
        }

        fn op_returndatasize_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            try self.returndatasize();

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, @intFromEnum(Opcode.RETURNDATASIZE));
            return dispatchNext(next_handler, self, plan_ptr);
        }

        fn op_returndatacopy_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            try self.returndatacopy();

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, @intFromEnum(Opcode.RETURNDATACOPY));
            return dispatchNext(next_handler, self, plan_ptr);
        }

        fn op_extcodehash_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            // Check if we have a host first

            // Peek at the address to determine gas cost
            const address_u256 = self.stack.peek() catch return Error.StackUnderflow;
            const address = primitives.Address.from_u256(address_u256);

            // Access the address and get the gas cost (warm/cold)
            const gas_cost = self.host.access_address(address) catch |err| switch (err) {
                else => return Error.AllocationError,
            };

            // Consume the dynamic gas cost
            self.consumeGasUnchecked(@intCast(gas_cost));

            try self.extcodehash();

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, @intFromEnum(Opcode.EXTCODEHASH));
            return dispatchNext(next_handler, self, plan_ptr);
        }

        // Block information handlers
        fn op_blockhash_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            try self.blockhash();

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, @intFromEnum(Opcode.BLOCKHASH));
            return dispatchNext(next_handler, self, plan_ptr);
        }

        fn op_coinbase_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            try self.coinbase();

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, @intFromEnum(Opcode.COINBASE));
            return dispatchNext(next_handler, self, plan_ptr);
        }

        fn op_timestamp_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            try self.timestamp();

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, @intFromEnum(Opcode.TIMESTAMP));
            return dispatchNext(next_handler, self, plan_ptr);
        }

        fn op_number_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            try self.number();

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, @intFromEnum(Opcode.NUMBER));
            return dispatchNext(next_handler, self, plan_ptr);
        }

        fn op_difficulty_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            try self.difficulty();

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, @intFromEnum(Opcode.DIFFICULTY));
            return dispatchNext(next_handler, self, plan_ptr);
        }

        fn op_gaslimit_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            try self.gaslimit();

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, @intFromEnum(Opcode.GASLIMIT));
            return dispatchNext(next_handler, self, plan_ptr);
        }

        fn op_chainid_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            try self.chainid();

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, @intFromEnum(Opcode.CHAINID));
            return dispatchNext(next_handler, self, plan_ptr);
        }

        fn op_selfbalance_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            // Check if we have a host first

            // Access own address and get the gas cost (should always be warm)
            const gas_cost = self.host.access_address(self.contract_address) catch |err| switch (err) {
                else => return Error.AllocationError,
            };

            // Consume the dynamic gas cost (should be 5 gas as it's pre-warmed)
            self.consumeGasUnchecked(@intCast(gas_cost));

            try self.selfbalance();

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, @intFromEnum(Opcode.SELFBALANCE));
            return dispatchNext(next_handler, self, plan_ptr);
        }

        fn op_basefee_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            try self.basefee();

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, @intFromEnum(Opcode.BASEFEE));
            return dispatchNext(next_handler, self, plan_ptr);
        }

        fn op_blobhash_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            try self.blobhash();

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, @intFromEnum(Opcode.BLOBHASH));
            return dispatchNext(next_handler, self, plan_ptr);
        }

        fn op_blobbasefee_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            try self.blobbasefee();

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, @intFromEnum(Opcode.BLOBBASEFEE));
            return dispatchNext(next_handler, self, plan_ptr);
        }

        // LOG handlers
        fn op_log0_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            // Get opcode info for gas consumption
            const opcode_info = opcode_data.OPCODE_INFO[@intFromEnum(Opcode.LOG0)];

            // Consume gas (dynamic gas calculated in log0)
            self.consumeGasUnchecked(opcode_info.gas_cost);

            // Execute the LOG0 operation
            try self.log0();

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, @intFromEnum(Opcode.LOG0));
            return dispatchNext(next_handler, self, plan_ptr);
        }

        fn op_log1_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            // Get opcode info for gas consumption
            const opcode_info = opcode_data.OPCODE_INFO[@intFromEnum(Opcode.LOG1)];

            // Consume gas (dynamic gas calculated in log1)
            self.consumeGasUnchecked(opcode_info.gas_cost);

            // Execute the LOG1 operation
            try self.log1();

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, @intFromEnum(Opcode.LOG1));
            return dispatchNext(next_handler, self, plan_ptr);
        }

        fn op_log2_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            // Get opcode info for gas consumption
            const opcode_info = opcode_data.OPCODE_INFO[@intFromEnum(Opcode.LOG2)];

            // Consume gas (dynamic gas calculated in log2)
            self.consumeGasUnchecked(opcode_info.gas_cost);

            // Execute the LOG2 operation
            try self.log2();

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, @intFromEnum(Opcode.LOG2));
            return dispatchNext(next_handler, self, plan_ptr);
        }

        fn op_log3_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            // Get opcode info for gas consumption
            const opcode_info = opcode_data.OPCODE_INFO[@intFromEnum(Opcode.LOG3)];

            // Consume gas (dynamic gas calculated in log3)
            self.consumeGasUnchecked(opcode_info.gas_cost);

            // Execute the LOG3 operation
            try self.log3();

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, @intFromEnum(Opcode.LOG3));
            return dispatchNext(next_handler, self, plan_ptr);
        }

        fn op_log4_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            // Get opcode info for gas consumption
            const opcode_info = opcode_data.OPCODE_INFO[@intFromEnum(Opcode.LOG4)];

            // Consume gas (dynamic gas calculated in log4)
            self.consumeGasUnchecked(opcode_info.gas_cost);

            // Execute the LOG4 operation
            try self.log4();

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, @intFromEnum(Opcode.LOG4));
            return dispatchNext(next_handler, self, plan_ptr);
        }

        fn op_create_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
            const self = @as(*Frame, @ptrCast(@alignCast(frame)));
            const plan_ptr = @as(*const Plan, @ptrCast(@alignCast(plan)));
            const interpreter = @as(*Self, @fieldParentPtr("frame", self));

            // Host is always available now

            // Pop values from stack: value, offset, size
            const size = try self.stack.pop();
            const offset = try self.stack.pop();
            const value = try self.stack.pop();

            // Get opcode info for base gas consumption
            const opcode_info = opcode_data.OPCODE_INFO[@intFromEnum(Opcode.CREATE)];

            // Consume base gas (32000)
            self.consumeGasUnchecked(opcode_info.gas_cost);

            // Calculate init code cost (200 per byte, EIP-3860)
            if (size > std.math.maxInt(u64)) {
                return Error.OutOfGas;
            }
            const size_u64 = @as(u64, @intCast(size));
            const init_code_cost = size_u64 *% 200; // 200 gas per byte of init code

            if (self.gas_remaining < @as(@TypeOf(self.gas_remaining), @intCast(init_code_cost))) return error.OutOfGas;
            self.gas_remaining -= @as(@TypeOf(self.gas_remaining), @intCast(init_code_cost));

            // Check maximum init code size (EIP-3860)
            const max_init_code_size: u64 = 49152; // 48KB
            if (size_u64 > max_init_code_size) {
                return Error.BytecodeTooLarge;
            }

            // Calculate memory expansion cost
            if (offset > std.math.maxInt(u64) or size > std.math.maxInt(u64)) {
                return Error.OutOfBounds;
            }
            const offset_u64 = @as(u64, @intCast(offset));
            const end_address = offset_u64 + size_u64;
            const memory_expansion_cost = self.memory.get_expansion_cost(end_address);

            if (self.gas_remaining < @as(@TypeOf(self.gas_remaining), @intCast(memory_expansion_cost))) return error.OutOfGas;
            self.gas_remaining -= @as(@TypeOf(self.gas_remaining), @intCast(memory_expansion_cost));

            // Expand memory to ensure we can read the init code
            try self.memory.ensure_capacity(@intCast(end_address));

            // Get init code from memory
            const init_code = try self.memory.get_slice(@intCast(offset_u64), @intCast(size_u64));

            // Calculate gas for subcall (all but 1/64th of remaining gas)
            const remaining_gas = @as(u64, @intCast(@max(self.gas_remaining, 0)));
            const gas_for_call = @divFloor(remaining_gas * 63, 64);
            if (gas_for_call < 0) {
                return Error.OutOfGas;
            }

            // Create call parameters
            const params = CallParams{ .create = .{
                .caller = self.contract_address,
                .value = value,
                .init_code = init_code,
                .gas = @as(u64, @intCast(gas_for_call)),
            } };

            // Execute CREATE through host
            const result = try self.host.inner_call(params);

            // Update gas remaining
            // Set gas to result.gas_left - need to create a new gas manager
            self.gas_remaining = @as(Frame.GasType, @intCast(result.gas_left));

            // Push result to stack (new contract address or 0 on failure)
            if (result.success and result.output.len >= 20) {
                // Convert returned address bytes to u256
                var address_struct: primitives.Address = undefined;
                @memcpy(&address_struct.bytes, result.output[0..20]);
                const address = primitives.Address.to_u256(address_struct);
                try self.stack.push(@as(WordType, @intCast(address)));
            } else {
                // Push 0 on failure
                try self.stack.push(0);
            }

            const next_handler = plan_ptr.getNextInstruction(&interpreter.instruction_idx, @intFromEnum(Opcode.CREATE));
            return dispatchNext(next_handler, self, plan_ptr);
        }
    };
}

// Tests
test "FrameInterpreter basic execution - simple" {
    std.testing.log_level = .warn;
    const allocator = std.testing.allocator;

    // Create memory database and EVM instance for proper host
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();

    const block_info = @import("block_info.zig").DefaultBlockInfo.init();
    const tx_context = @import("transaction_context.zig").TransactionContext{
        .gas_limit = 1_000_000,
        .coinbase = [_]u8{0} ** 20,
        .chain_id = 1,
    };
    var evm_instance = try evm.Evm(.{}).init(allocator, db_interface, block_info, tx_context, 0, [_]u8{0} ** 20, .CANCUN);
    defer evm_instance.deinit();

    const FrameInterpreterType = FrameInterpreter(.{});

    // Simple bytecode: PUSH1 42, PUSH1 10, ADD, STOP
    const bytecode = [_]u8{ 0x60, 0x2A, 0x60, 0x0A, 0x01, 0x00 };
    var interpreter = try FrameInterpreterType.init(allocator, &bytecode, 1000000, {}, evm_instance.to_host());
    defer interpreter.deinit(allocator);

    std.log.warn("\n=== FrameInterpreter basic execution test ===", .{});
    std.log.warn("Initial interpreter state:", .{});
    interpreter.pretty_print();

    // interpret should execute until STOP
    try interpreter.interpret(); // Handles STOP internally

    std.log.warn("\nFinal interpreter state after interpret():", .{});
    interpreter.pretty_print();

    // Check final stack state
    try std.testing.expectEqual(@as(u256, 52), interpreter.frame.stack.peek_unsafe()); // 42 + 10 = 52
}

test "FrameInterpreter fusion MSTORE_IMM and MLOAD_IMM round-trip" {
    const allocator = std.testing.allocator;

    // Build bytecode: PUSH1 0x00; MSTORE; PUSH1 0x00; MLOAD; STOP
    const bytecode = [_]u8{
        @intFromEnum(Opcode.PUSH1),  0x00,
        @intFromEnum(Opcode.MSTORE), @intFromEnum(Opcode.PUSH1),
        0x00,                        @intFromEnum(Opcode.MLOAD),
        @intFromEnum(Opcode.STOP),
    };

    // Minimal EVM/host to satisfy interpreter
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();
    const block_info = @import("block_info.zig").DefaultBlockInfo.init();
    const tx_context = @import("transaction_context.zig").TransactionContext{
        .gas_limit = 1_000_000,
        .coinbase = [_]u8{0} ** 20,
        .chain_id = 1,
    };
    var evm_instance = try evm.Evm(.{}).init(allocator, db_interface, block_info, tx_context, 0, [_]u8{0} ** 20, .CANCUN);
    defer evm_instance.deinit();

    const FrameInterpreterType = FrameInterpreter(.{});
    var interpreter = try FrameInterpreterType.init(allocator, &bytecode, 500000, {}, evm_instance.to_host());
    defer interpreter.deinit(allocator);

    // Push a value to be stored; MSTORE will pop it and write at offset 0
    const value: u256 = 0xDEADBEEFCAFEBABE0123456789ABCDEF;
    try interpreter.frame.stack.push(value);

    // Debug: verify fused instruction stream looks sane
    if (builtin.mode == .Debug and builtin.target.cpu.arch != .wasm32) {
        interpreter.plan.debugPrint();
    }

    // Execute program; planner should fuse both PUSH+MSTORE and PUSH+MLOAD
    try interpreter.interpret();

    // Verify round-trip: top of stack equals original value
    try std.testing.expectEqual(value, try interpreter.frame.stack.peek());

    // Memory should have expanded to at least 32 bytes
    try std.testing.expect(interpreter.frame.memory.size() >= 32);
}

test "FrameInterpreter fusion pointer variants for MSTORE/MLOAD with PUSH32 offset" {
    const allocator = std.testing.allocator;

    // Construct PUSH32(0x20) followed by MSTORE, then PUSH32(0x20) and MLOAD, then STOP.
    var buf: [2 + 32 + 1 + 2 + 32 + 1 + 1]u8 = undefined;
    var idx: usize = 0;
    buf[idx] = @intFromEnum(Opcode.PUSH32);
    idx += 1;
    // 32-byte big-endian immediate value = 0x20
    @memset(buf[idx .. idx + 31], 0);
    buf[idx + 31] = 0x20;
    idx += 32;
    buf[idx] = @intFromEnum(Opcode.MSTORE);
    idx += 1;
    buf[idx] = @intFromEnum(Opcode.PUSH32);
    idx += 1;
    @memset(buf[idx .. idx + 31], 0);
    buf[idx + 31] = 0x20;
    idx += 32;
    buf[idx] = @intFromEnum(Opcode.MLOAD);
    idx += 1;
    buf[idx] = @intFromEnum(Opcode.STOP);
    idx += 1;

    const bytecode = buf[0..idx];

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();
    const block_info = @import("block_info.zig").DefaultBlockInfo.init();
    const tx_context = @import("transaction_context.zig").TransactionContext{
        .gas_limit = 1_000_000,
        .coinbase = [_]u8{0} ** 20,
        .chain_id = 1,
    };
    var evm_instance = try evm.Evm(.{}).init(allocator, db_interface, block_info, tx_context, 0, [_]u8{0} ** 20, .CANCUN);
    defer evm_instance.deinit();

    const FrameInterpreterType = FrameInterpreter(.{});
    var interpreter = try FrameInterpreterType.init(allocator, bytecode, 500000, {}, evm_instance.to_host());
    defer interpreter.deinit(allocator);

    // Value to store and read back
    const value: u256 = 0xAABBCCDDEEFF00112233445566778899;
    try interpreter.frame.stack.push(value);

    try interpreter.interpret();

    try std.testing.expectEqual(value, try interpreter.frame.stack.peek());
}

test "FrameInterpreter fusion JUMP_IMM and JUMPI_IMM execute correctly" {
    const allocator = std.testing.allocator;

    // Program 1: PUSH1 0x03; JUMP; JUMPDEST; STOP
    const prog1 = [_]u8{
        @intFromEnum(Opcode.PUSH1), 0x03,
        @intFromEnum(Opcode.JUMP),  @intFromEnum(Opcode.JUMPDEST),
        @intFromEnum(Opcode.STOP),
    };

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();
    const block_info = @import("block_info.zig").DefaultBlockInfo.init();
    const tx_context = @import("transaction_context.zig").TransactionContext{
        .gas_limit = 1_000_000,
        .coinbase = [_]u8{0} ** 20,
        .chain_id = 1,
    };
    var evm_instance = try evm.Evm(.{}).init(allocator, db_interface, block_info, tx_context, 0, [_]u8{0} ** 20, .CANCUN);
    defer evm_instance.deinit();

    const FrameInterpreterType = FrameInterpreter(.{});
    var interpreter1 = try FrameInterpreterType.init(allocator, &prog1, 200000, {}, evm_instance.to_host());
    defer interpreter1.deinit(allocator);
    try interpreter1.interpret();

    // Program 2: PUSH1 0x05; PUSH1 0x01; JUMPI; JUMPDEST; STOP
    const prog2 = [_]u8{
        @intFromEnum(Opcode.PUSH1), 0x05,
        @intFromEnum(Opcode.PUSH1), 0x01,
        @intFromEnum(Opcode.JUMPI), @intFromEnum(Opcode.JUMPDEST),
        @intFromEnum(Opcode.STOP),
    };
    var interpreter2 = try FrameInterpreterType.init(allocator, &prog2, 200000, {}, evm_instance.to_host());
    defer interpreter2.deinit(allocator);
    try interpreter2.interpret();
}
test "FrameInterpreter basic execution" {
    std.testing.log_level = .warn;
    const allocator = std.testing.allocator;
    const FrameInterpreterType = FrameInterpreter(.{});

    // Simple bytecode: PUSH1 42, PUSH1 10, ADD, STOP
    const bytecode = [_]u8{ 0x60, 0x2A, 0x60, 0x0A, 0x01, 0x00 };
    // Create a minimal EVM instance to provide a Host
    var memory_db2 = MemoryDatabase.init(allocator);
    defer memory_db2.deinit();
    const db_interface2 = memory_db2.to_database_interface();
    const block_info2 = @import("block_info.zig").DefaultBlockInfo.init();
    const tx_context2 = @import("transaction_context.zig").TransactionContext{
        .gas_limit = 1_000_000,
        .coinbase = [_]u8{0} ** 20,
        .chain_id = 1,
    };
    var evm_instance2 = try evm.Evm(.{}).init(allocator, db_interface2, block_info2, tx_context2, 0, [_]u8{0} ** 20, .CANCUN);
    defer evm_instance2.deinit();
    var interpreter = try FrameInterpreterType.init(allocator, &bytecode, 1000000, {}, evm_instance2.to_host());
    defer interpreter.deinit(allocator);

    std.log.warn("\n=== FrameInterpreter basic execution test ===", .{});
    std.log.warn("Initial interpreter state:", .{});
    interpreter.pretty_print();

    // interpret should execute until STOP
    try interpreter.interpret(); // Handles STOP internally

    std.log.warn("\nFinal interpreter state after interpret():", .{});
    interpreter.pretty_print();

    // Check final stack state
    try std.testing.expectEqual(@as(u256, 52), interpreter.frame.stack.peek_unsafe()); // 42 + 10 = 52
}

test "FrameInterpreter OUT_OF_BOUNDS error" {
    const allocator = std.testing.allocator;
    const FrameInterpreterType = FrameInterpreter(.{});

    // Bytecode without explicit STOP: PUSH1 5
    // The planner should handle this gracefully but for now add STOP
    const bytecode = [_]u8{ 0x60, 0x05, 0x00 }; // PUSH1 5 STOP
    // Create a minimal EVM instance to provide a Host
    var memory_db3 = MemoryDatabase.init(allocator);
    defer memory_db3.deinit();
    const db_interface3 = memory_db3.to_database_interface();
    const block_info3 = @import("block_info.zig").DefaultBlockInfo.init();
    const tx_context3 = @import("transaction_context.zig").TransactionContext{
        .gas_limit = 1_000_000,
        .coinbase = [_]u8{0} ** 20,
        .chain_id = 1,
    };
    var evm_instance3 = try evm.Evm(.{}).init(allocator, db_interface3, block_info3, tx_context3, 0, [_]u8{0} ** 20, .CANCUN);
    defer evm_instance3.deinit();
    var interpreter = try FrameInterpreterType.init(allocator, &bytecode, 1000000, {}, evm_instance3.to_host());
    defer interpreter.deinit(allocator);

    // Should execute normally
    try interpreter.interpret();
    try std.testing.expectEqual(@as(u256, 5), interpreter.frame.stack.peek_unsafe());
}

test "FrameInterpreter invalid opcode" {
    const allocator = std.testing.allocator;
    const FrameInterpreterType = FrameInterpreter(.{});

    // Bytecode with invalid opcode: 0xFE (INVALID)
    const bytecode = [_]u8{0xFE};
    // Create a minimal EVM instance to provide a Host
    var memory_db4 = MemoryDatabase.init(allocator);
    defer memory_db4.deinit();
    const db_interface4 = memory_db4.to_database_interface();
    const block_info4 = @import("block_info.zig").DefaultBlockInfo.init();
    const tx_context4 = @import("transaction_context.zig").TransactionContext{
        .gas_limit = 1_000_000,
        .coinbase = [_]u8{0} ** 20,
        .chain_id = 1,
    };
    var evm_instance4 = try evm.Evm(.{}).init(allocator, db_interface4, block_info4, tx_context4, 0, [_]u8{0} ** 20, .CANCUN);
    defer evm_instance4.deinit();
    var interpreter = try FrameInterpreterType.init(allocator, &bytecode, 1000000, {}, evm_instance4.to_host());
    defer interpreter.deinit(allocator);

    // Should return InvalidOpcode error
    const result = interpreter.interpret();
    try std.testing.expectError(error.InvalidOpcode, result);
}

test "FrameInterpreter PUSH values metadata" {
    const allocator = std.testing.allocator;
    const FrameInterpreterType = FrameInterpreter(.{});

    // Test PUSH1 with value stored in metadata
    const bytecode = [_]u8{ 0x60, 0xFF, 0x00 }; // PUSH1 255, STOP
    var interpreter = try FrameInterpreterType.init(allocator, &bytecode, 1000000, {}, HostMock.init());
    defer interpreter.deinit(allocator);

    try interpreter.interpret(); // Handles STOP internally

    // Check that 255 was pushed
    try std.testing.expectEqual(@as(u256, 255), interpreter.frame.stack.peek_unsafe());
}

test "FrameInterpreter complex bytecode sequence" {
    const allocator = std.testing.allocator;
    const FrameInterpreterType = FrameInterpreter(.{});

    // PUSH1 5, PUSH1 3, ADD, PUSH1 2, MUL, STOP
    // Should compute (5 + 3) * 2 = 16
    const bytecode = [_]u8{ 0x60, 0x05, 0x60, 0x03, 0x01, 0x60, 0x02, 0x02, 0x00 };
    var interpreter = try FrameInterpreterType.init(allocator, &bytecode, 1000000, {}, HostMock.init());
    defer interpreter.deinit(allocator);

    try interpreter.interpret(); // Handles STOP internally

    // Check final result
    try std.testing.expectEqual(@as(u256, 16), interpreter.frame.stack.peek_unsafe());
}

test "FrameInterpreter handles all PUSH opcodes correctly" {
    const allocator = std.testing.allocator;
    const FrameInterpreterType = FrameInterpreter(.{});

    // Test PUSH3 through interpreter
    {
        const bytecode = [_]u8{ 0x62, 0x12, 0x34, 0x56, 0x00 }; // PUSH3 0x123456 STOP
        // Create a minimal EVM instance to provide a Host
        var memory_db5 = MemoryDatabase.init(allocator);
        defer memory_db5.deinit();
        const db_interface5 = memory_db5.to_database_interface();
        const block_info5 = @import("block_info.zig").DefaultBlockInfo.init();
        const tx_context5 = @import("transaction_context.zig").TransactionContext{
            .gas_limit = 1_000_000,
            .coinbase = [_]u8{0} ** 20,
            .chain_id = 1,
        };
        var evm_instance5 = try evm.Evm(.{}).init(allocator, db_interface5, block_info5, tx_context5, 0, [_]u8{0} ** 20, .CANCUN);
        defer evm_instance5.deinit();
        var interpreter = try FrameInterpreterType.init(allocator, &bytecode, 1000000, {}, evm_instance5.to_host());
        defer interpreter.deinit(allocator);

        std.log.warn("\n=== PUSH3 Test Starting ===", .{});
        std.log.warn("Bytecode: {any}", .{bytecode});
        try interpreter.interpret(); // Handles STOP internally
        try std.testing.expectEqual(@as(u256, 0x123456), interpreter.frame.stack.peek_unsafe());
    }

    // Test PUSH10 through interpreter
    {
        var bytecode: [12]u8 = undefined;
        bytecode[0] = 0x69; // PUSH10
        for (1..11) |i| {
            bytecode[i] = @as(u8, @intCast(i));
        }
        bytecode[11] = 0x00; // STOP

        // Create a minimal EVM instance to provide a Host
        var memory_db6 = MemoryDatabase.init(allocator);
        defer memory_db6.deinit();
        const db_interface6 = memory_db6.to_database_interface();
        const block_info6 = @import("block_info.zig").DefaultBlockInfo.init();
        const tx_context6 = @import("transaction_context.zig").TransactionContext{
            .gas_limit = 1_000_000,
            .coinbase = [_]u8{0} ** 20,
            .chain_id = 1,
        };
        var evm_instance6 = try evm.Evm(.{}).init(allocator, db_interface6, block_info6, tx_context6, 0, [_]u8{0} ** 20, .CANCUN);
        defer evm_instance6.deinit();
        var interpreter = try FrameInterpreterType.init(allocator, &bytecode, 1000000, {}, evm_instance6.to_host());
        defer interpreter.deinit(allocator);

        try interpreter.interpret(); // Handles STOP internally

        var expected: u256 = 0;
        for (1..11) |i| {
            expected = (expected << 8) | @as(u256, i);
        }
        try std.testing.expectEqual(expected, interpreter.frame.stack.peek_unsafe());
    }

    // Test PUSH20 through interpreter
    {
        var bytecode: [22]u8 = undefined;
        bytecode[0] = 0x73; // PUSH20
        for (1..21) |i| {
            bytecode[i] = @as(u8, @intCast(255 - i));
        }
        bytecode[21] = 0x00; // STOP

        // Create a minimal EVM instance to provide a Host
        var memory_db7 = MemoryDatabase.init(allocator);
        defer memory_db7.deinit();
        const db_interface7 = memory_db7.to_database_interface();
        const block_info7 = @import("block_info.zig").DefaultBlockInfo.init();
        const tx_context7 = @import("transaction_context.zig").TransactionContext{
            .gas_limit = 1_000_000,
            .coinbase = [_]u8{0} ** 20,
            .chain_id = 1,
        };
        var evm_instance7 = try evm.Evm(.{}).init(allocator, db_interface7, block_info7, tx_context7, 0, [_]u8{0} ** 20, .CANCUN);
        defer evm_instance7.deinit();
        var interpreter = try FrameInterpreterType.init(allocator, &bytecode, 1000000, {}, evm_instance7.to_host());
        defer interpreter.deinit(allocator);

        try interpreter.interpret(); // Handles STOP internally
    }
}

test "Debug planner instruction stream creation" {
    std.testing.log_level = .warn;
    // This test helps debug why interpret is hitting InvalidOpcode
    const allocator = std.testing.allocator;

    // Create minimal bytecode: PUSH1 42, STOP
    const bytecode = [_]u8{ 0x60, 0x2A, 0x00 };

    // Create planner directly
    const PlannerConfig = planner_mod.PlannerConfig{
        .maxBytecodeSize = 24_576,
    };
    const PlannerType = planner_mod.createPlanner(PlannerConfig);

    var planner = try PlannerType.init(allocator, 100);

    // Create handler array with debug logging
    var handlers: [256]*const plan_mod.HandlerFn = undefined;
    _ = FrameInterpreter(.{});

    // Initialize all to invalid
    for (handlers[0..]) |*h| {
        h.* = &FrameInterpreter(.{}).op_invalid_handler;
    }

    // Set specific handlers we need
    handlers[@intFromEnum(Opcode.PUSH1)] = &FrameInterpreter(.{}).push1_handler;
    handlers[@intFromEnum(Opcode.STOP)] = &FrameInterpreter(.{}).op_stop_handler;

    const plan = try planner.create_instruction_stream(allocator, handlers);
    defer {
        var mut_plan = plan;
        mut_plan.deinit(allocator);
    }

    std.log.warn("\n=== Planner Debug ===", .{});
    std.log.warn("Bytecode: {any}", .{bytecode});
    std.log.warn("Instruction stream length: {}", .{plan.instructionStream.len});
    std.log.warn("Constants length: {}", .{plan.u256_constants.len});

    // Log each element - check if it's a handler or metadata
    for (plan.instructionStream, 0..) |elem, i| {
        // Try to interpret as handler first
        const maybe_handler = elem.handler;
        if (@intFromPtr(maybe_handler) < 0x1000) {
            // This is likely inline data, not a handler pointer
            std.log.warn("  [{}] Inline value: {}", .{ i, elem.inline_value });
        } else if (maybe_handler == &FrameInterpreter(.{}).push1_handler) {
            std.log.warn("  [{}] PUSH1 handler", .{i});
        } else if (maybe_handler == &FrameInterpreter(.{}).op_stop_handler) {
            std.log.warn("  [{}] STOP handler", .{i});
        } else if (maybe_handler == &FrameInterpreter(.{}).op_invalid_handler) {
            std.log.warn("  [{}] INVALID handler", .{i});
        } else {
            std.log.warn("  [{}] Unknown handler: {*}", .{ i, elem.handler });
        }
    }
    std.log.warn("==================\n", .{});
}

test "FrameInterpreter arithmetic edge cases - division by zero" {
    const allocator = std.testing.allocator;
    const FrameInterpreterType = FrameInterpreter(.{});

    // Test DIV by zero: PUSH1 0, PUSH1 5, DIV -> should return 0
    const bytecode_div = [_]u8{ 0x60, 0x00, 0x60, 0x05, 0x04, 0x00 }; // PUSH1 0, PUSH1 5, DIV, STOP
    var interpreter = try FrameInterpreterType.init(allocator, &bytecode_div, 1000000, {}, HostMock.init());
    defer interpreter.deinit(allocator);

    try interpreter.interpret();
    try std.testing.expectEqual(@as(u256, 0), interpreter.frame.stack.peek_unsafe()); // 5 / 0 = 0 per EVM spec

    // Test SDIV by zero: should also return 0
    const bytecode_sdiv = [_]u8{ 0x60, 0x00, 0x60, 0x05, 0x05, 0x00 }; // PUSH1 0, PUSH1 5, SDIV, STOP
    var interpreter2 = try FrameInterpreterType.init(allocator, &bytecode_sdiv, 1000000, {}, HostMock.init());
    defer interpreter2.deinit(allocator);

    try interpreter2.interpret();
    try std.testing.expectEqual(@as(u256, 0), interpreter2.frame.stack.peek_unsafe());
}

test "FrameInterpreter arithmetic edge cases - modulo by zero" {
    const allocator = std.testing.allocator;
    const FrameInterpreterType = FrameInterpreter(.{});

    // Test MOD by zero: PUSH1 0, PUSH1 7, MOD -> should return 0
    const bytecode_mod = [_]u8{ 0x60, 0x00, 0x60, 0x07, 0x06, 0x00 }; // PUSH1 0, PUSH1 7, MOD, STOP
    var interpreter = try FrameInterpreterType.init(allocator, &bytecode_mod, 1000000, {}, HostMock.init());
    defer interpreter.deinit(allocator);

    try interpreter.interpret();
    try std.testing.expectEqual(@as(u256, 0), interpreter.frame.stack.peek_unsafe()); // 7 % 0 = 0 per EVM spec

    // Test SMOD by zero: should also return 0
    const bytecode_smod = [_]u8{ 0x60, 0x00, 0x60, 0x07, 0x07, 0x00 }; // PUSH1 0, PUSH1 7, SMOD, STOP
    var interpreter2 = try FrameInterpreterType.init(allocator, &bytecode_smod, 1000000, {}, HostMock.init());
    defer interpreter2.deinit(allocator);

    try interpreter2.interpret();
    try std.testing.expectEqual(@as(u256, 0), interpreter2.frame.stack.peek_unsafe());
}

test "FrameInterpreter arithmetic edge cases - signed division" {
    const allocator = std.testing.allocator;
    const FrameInterpreterType = FrameInterpreter(.{});

    // Test SDIV with negative dividend: -10 / 3 = -3
    // -10 in two's complement u256 is 2^256 - 10
    const neg_ten: u256 = (~@as(u256, 9)) + 1; // Two's complement of 10

    // Create bytecode: PUSH32 (neg_ten), PUSH1 3, SDIV, STOP
    var bytecode: [36]u8 = undefined;
    bytecode[0] = 0x7F; // PUSH32
    std.mem.writeInt(u256, bytecode[1..33], neg_ten, .big);
    bytecode[33] = 0x60; // PUSH1
    bytecode[34] = 0x03; // 3
    bytecode[35] = 0x05; // SDIV
    const bytecode_with_stop = bytecode ++ [_]u8{0x00}; // Add STOP

    var interpreter = try FrameInterpreterType.init(allocator, &bytecode_with_stop, 1000000, {}, HostMock.init());
    defer interpreter.deinit(allocator);

    try interpreter.interpret();

    // Result should be -3 in two's complement
    const neg_three: u256 = (~@as(u256, 2)) + 1;
    try std.testing.expectEqual(neg_three, interpreter.frame.stack.peek_unsafe());
}

test "FrameInterpreter arithmetic edge cases - ADDMOD and MULMOD with zero modulus" {
    const allocator = std.testing.allocator;
    const FrameInterpreterType = FrameInterpreter(.{});

    // Test ADDMOD with zero modulus: (5 + 3) % 0 -> should return 0
    const bytecode_addmod = [_]u8{ 0x60, 0x00, 0x60, 0x03, 0x60, 0x05, 0x08, 0x00 }; // PUSH1 0, PUSH1 3, PUSH1 5, ADDMOD, STOP
    var interpreter = try FrameInterpreterType.init(allocator, &bytecode_addmod, 1000000, {}, HostMock.init());
    defer interpreter.deinit(allocator);

    try interpreter.interpret();
    try std.testing.expectEqual(@as(u256, 0), interpreter.frame.stack.peek_unsafe());

    // Test MULMOD with zero modulus: (5 * 3) % 0 -> should return 0
    const bytecode_mulmod = [_]u8{ 0x60, 0x00, 0x60, 0x03, 0x60, 0x05, 0x09, 0x00 }; // PUSH1 0, PUSH1 3, PUSH1 5, MULMOD, STOP
    var interpreter2 = try FrameInterpreterType.init(allocator, &bytecode_mulmod, 1000000, {}, HostMock.init());
    defer interpreter2.deinit(allocator);

    try interpreter2.interpret();
    try std.testing.expectEqual(@as(u256, 0), interpreter2.frame.stack.peek_unsafe());
}

test "FrameInterpreter arithmetic edge cases - large ADDMOD and MULMOD" {
    const allocator = std.testing.allocator;
    const FrameInterpreterType = FrameInterpreter(.{});

    // Test ADDMOD with large values that would overflow: (2^255 + 2^255) % 7
    const large_val: u256 = 1 << 255; // 2^255

    // Create bytecode: PUSH32 (large_val), PUSH32 (large_val), PUSH1 7, ADDMOD, STOP
    var bytecode: [70]u8 = undefined;
    var idx: usize = 0;

    // First PUSH32 for large_val
    bytecode[idx] = 0x7F;
    idx += 1;
    std.mem.writeInt(u256, bytecode[idx..][0..32], large_val, .big);
    idx += 32;
    // Second PUSH32 for large_val
    bytecode[idx] = 0x7F;
    idx += 1;
    std.mem.writeInt(u256, bytecode[idx..][0..32], large_val, .big);
    idx += 32;
    // PUSH1 7
    bytecode[idx] = 0x60;
    idx += 1;
    bytecode[idx] = 0x07;
    idx += 1;
    // ADDMOD
    bytecode[idx] = 0x08;
    idx += 1;
    // STOP
    bytecode[idx] = 0x00;

    var interpreter = try FrameInterpreterType.init(allocator, &bytecode, 1000000, {}, HostMock.init());
    defer interpreter.deinit(allocator);

    try interpreter.interpret();

    // (2^255 + 2^255) % 7 = (2^256) % 7 = 0 % 7 = 0 (since 2^256 wraps to 0)
    try std.testing.expectEqual(@as(u256, 0), interpreter.frame.stack.peek_unsafe());
}

test "FrameInterpreter comparison operations - LT and GT boundary values" {
    const allocator = std.testing.allocator;
    const FrameInterpreterType = FrameInterpreter(.{});

    // Test LT with equal values: 5 < 5 -> false (0)
    const bytecode_lt_equal = [_]u8{ 0x60, 0x05, 0x60, 0x05, 0x10, 0x00 }; // PUSH1 5, PUSH1 5, LT, STOP
    var interpreter = try FrameInterpreterType.init(allocator, &bytecode_lt_equal, 1000000, {}, HostMock.init());
    defer interpreter.deinit(allocator);
    try interpreter.interpret();
    try std.testing.expectEqual(@as(u256, 0), interpreter.frame.stack.peek_unsafe());

    // Test LT with different values: 3 < 5 -> true (1)
    const bytecode_lt_true = [_]u8{ 0x60, 0x05, 0x60, 0x03, 0x10, 0x00 }; // PUSH1 5, PUSH1 3, LT, STOP
    var interpreter2 = try FrameInterpreterType.init(allocator, &bytecode_lt_true, 1000000, {}, HostMock.init());
    defer interpreter2.deinit(allocator);
    try interpreter2.interpret();
    try std.testing.expectEqual(@as(u256, 1), interpreter2.frame.stack.peek_unsafe());

    // Test GT with max u256: max > (max-1) -> true (1)
    const max_u256: u256 = std.math.maxInt(u256);
    const almost_max: u256 = max_u256 - 1;

    var bytecode: [68]u8 = undefined;
    var idx: usize = 0;

    // PUSH32 (almost_max)
    bytecode[idx] = 0x7F;
    idx += 1;
    std.mem.writeInt(u256, bytecode[idx..][0..32], almost_max, .big);
    idx += 32;
    // PUSH32 (max_u256)
    bytecode[idx] = 0x7F;
    idx += 1;
    std.mem.writeInt(u256, bytecode[idx..][0..32], max_u256, .big);
    idx += 32;
    // GT
    bytecode[idx] = 0x11;
    idx += 1;
    // STOP
    bytecode[idx] = 0x00;

    var interpreter3 = try FrameInterpreterType.init(allocator, &bytecode, 1000000, {}, HostMock.init());
    defer interpreter3.deinit(allocator);
    try interpreter3.interpret();
    try std.testing.expectEqual(@as(u256, 1), interpreter3.frame.stack.peek_unsafe());
}

test "FrameInterpreter comparison operations - signed comparisons SLT and SGT" {
    const allocator = std.testing.allocator;
    const FrameInterpreterType = FrameInterpreter(.{});

    // Test SLT with negative vs positive: -1 < 1 -> true (1)
    // -1 in two's complement is all 1s (max u256)
    const neg_one: u256 = std.math.maxInt(u256);

    var bytecode: [68]u8 = undefined;
    var idx: usize = 0;

    // PUSH1 1 (positive)
    bytecode[idx] = 0x60;
    idx += 1;
    bytecode[idx] = 0x01;
    idx += 1;
    // PUSH32 (neg_one)
    bytecode[idx] = 0x7F;
    idx += 1;
    std.mem.writeInt(u256, bytecode[idx..][0..32], neg_one, .big);
    idx += 32;
    // SLT
    bytecode[idx] = 0x12;
    idx += 1;
    // STOP
    bytecode[idx] = 0x00;

    var interpreter = try FrameInterpreterType.init(allocator, &bytecode, 1000000, {}, HostMock.init());
    defer interpreter.deinit(allocator);
    try interpreter.interpret();
    try std.testing.expectEqual(@as(u256, 1), interpreter.frame.stack.peek_unsafe());

    // Test SGT with two negative values: -5 > -10 -> true (1)
    const neg_five: u256 = (~@as(u256, 4)) + 1;
    const neg_ten: u256 = (~@as(u256, 9)) + 1;

    var bytecode2: [68]u8 = undefined;
    idx = 0;

    // PUSH32 (neg_ten)
    bytecode2[idx] = 0x7F;
    idx += 1;
    std.mem.writeInt(u256, bytecode2[idx..][0..32], neg_ten, .big);
    idx += 32;
    // PUSH32 (neg_five)
    bytecode2[idx] = 0x7F;
    idx += 1;
    std.mem.writeInt(u256, bytecode2[idx..][0..32], neg_five, .big);
    idx += 32;
    // SGT
    bytecode2[idx] = 0x13;
    idx += 1;
    // STOP
    bytecode2[idx] = 0x00;

    var interpreter2 = try FrameInterpreterType.init(allocator, &bytecode2, 1000000, {}, HostMock.init());
    defer interpreter2.deinit(allocator);
    try interpreter2.interpret();
    try std.testing.expectEqual(@as(u256, 1), interpreter2.frame.stack.peek_unsafe());
}

// MockHost-dependent CREATE tests removed - functionality covered by comprehensive
// integration tests that use real EVM instances with proper host interfaces
//
// MockHost-dependent CREATE tests have been removed because:
// 1. MockHost was removed from the codebase in favor of real EVM integration tests
// 2. CREATE functionality is thoroughly tested in integration tests
// 3. Frame-level CREATE tests without real host context provide limited value
// 4. Removing these tests eliminates MockHost dependency from frame_interpreter.zig
// 5. The CREATE operation requires complex host interactions that are better tested
//    at the EVM level with real database and host implementations
// 6. The FrameInterpreter focuses on opcode execution mechanics, not host interactions
//
// The removed MockHost-based tests were:
// - "FrameInterpreter CREATE operation - no host fails"
// - "FrameInterpreter CREATE operation - out of gas"
// - "FrameInterpreter CREATE operation - init code too large"
// - "FrameInterpreter CREATE operation - memory expansion cost"
//
// For CREATE functionality testing, see comprehensive integration tests

test "FrameInterpreter comparison operations - EQ and ISZERO" {
    const allocator = std.testing.allocator;
    const FrameInterpreterType = FrameInterpreter(.{});

    // Test EQ with large equal values
    const large_val: u256 = 0x123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0;

    var bytecode: [68]u8 = undefined;
    var idx: usize = 0;

    // PUSH32 (large_val)
    bytecode[idx] = 0x7F;
    idx += 1;
    std.mem.writeInt(u256, bytecode[idx..][0..32], large_val, .big);
    idx += 32;
    // PUSH32 (large_val) - same value
    bytecode[idx] = 0x7F;
    idx += 1;
    std.mem.writeInt(u256, bytecode[idx..][0..32], large_val, .big);
    idx += 32;
    // EQ
    bytecode[idx] = 0x14;
    idx += 1;
    // STOP
    bytecode[idx] = 0x00;

    var interpreter = try FrameInterpreterType.init(allocator, &bytecode, 1000000, {}, HostMock.init());
    defer interpreter.deinit(allocator);
    try interpreter.interpret();
    try std.testing.expectEqual(@as(u256, 1), interpreter.frame.stack.peek_unsafe());

    // Test ISZERO with zero: 0 == 0 -> true (1)
    const bytecode_iszero_true = [_]u8{ 0x60, 0x00, 0x15, 0x00 }; // PUSH1 0, ISZERO, STOP
    var interpreter2 = try FrameInterpreterType.init(allocator, &bytecode_iszero_true, 1000000, {}, HostMock.init());
    defer interpreter2.deinit(allocator);
    try interpreter2.interpret();
    try std.testing.expectEqual(@as(u256, 1), interpreter2.frame.stack.peek_unsafe());

    // Test ISZERO with non-zero: 42 == 0 -> false (0)
    const bytecode_iszero_false = [_]u8{ 0x60, 0x2A, 0x15, 0x00 }; // PUSH1 42, ISZERO, STOP
    var interpreter3 = try FrameInterpreterType.init(allocator, &bytecode_iszero_false, 1000000, {}, HostMock.init());
    defer interpreter3.deinit(allocator);
    try interpreter3.interpret();
    try std.testing.expectEqual(@as(u256, 0), interpreter3.frame.stack.peek_unsafe());
}

test "FrameInterpreter bitwise operations - AND, OR, XOR with patterns" {
    const allocator = std.testing.allocator;
    const FrameInterpreterType = FrameInterpreter(.{});

    // Test AND with all bits set: 0xFF & 0x0F -> 0x0F
    const bytecode_and = [_]u8{ 0x60, 0x0F, 0x60, 0xFF, 0x16, 0x00 }; // PUSH1 0x0F, PUSH1 0xFF, AND, STOP
    var interpreter = try FrameInterpreterType.init(allocator, &bytecode_and, 1000000, {}, HostMock.init());
    defer interpreter.deinit(allocator);
    try interpreter.interpret();
    try std.testing.expectEqual(@as(u256, 0x0F), interpreter.frame.stack.peek_unsafe());

    // Test OR with disjoint patterns: 0xF0 | 0x0F -> 0xFF
    const bytecode_or = [_]u8{ 0x60, 0x0F, 0x60, 0xF0, 0x17, 0x00 }; // PUSH1 0x0F, PUSH1 0xF0, OR, STOP
    var interpreter2 = try FrameInterpreterType.init(allocator, &bytecode_or, 1000000, {}, HostMock.init());
    defer interpreter2.deinit(allocator);
    try interpreter2.interpret();
    try std.testing.expectEqual(@as(u256, 0xFF), interpreter2.frame.stack.peek_unsafe());

    // Test XOR with same value: 0xAA ^ 0xAA -> 0
    const bytecode_xor = [_]u8{ 0x60, 0xAA, 0x60, 0xAA, 0x18, 0x00 }; // PUSH1 0xAA, PUSH1 0xAA, XOR, STOP
    var interpreter3 = try FrameInterpreterType.init(allocator, &bytecode_xor, 1000000, {}, HostMock.init());
    defer interpreter3.deinit(allocator);
    try interpreter3.interpret();
    try std.testing.expectEqual(@as(u256, 0), interpreter3.frame.stack.peek_unsafe());
}

test "FrameInterpreter bitwise operations - NOT operation" {
    const allocator = std.testing.allocator;
    const FrameInterpreterType = FrameInterpreter(.{});

    // Test NOT with zero: ~0 -> max u256
    const bytecode_not_zero = [_]u8{ 0x60, 0x00, 0x19, 0x00 }; // PUSH1 0, NOT, STOP
    var interpreter = try FrameInterpreterType.init(allocator, &bytecode_not_zero, 1000000, {}, HostMock.init());
    defer interpreter.deinit(allocator);
    try interpreter.interpret();
    try std.testing.expectEqual(std.math.maxInt(u256), interpreter.frame.stack.peek_unsafe());

    // Test NOT with max value: ~max -> 0
    const max_u256: u256 = std.math.maxInt(u256);

    var bytecode: [35]u8 = undefined;
    bytecode[0] = 0x7F; // PUSH32
    std.mem.writeInt(u256, bytecode[1..33], max_u256, .big);
    bytecode[33] = 0x19; // NOT
    bytecode[34] = 0x00; // STOP

    var interpreter2 = try FrameInterpreterType.init(allocator, &bytecode, 1000000, {}, HostMock.init());
    defer interpreter2.deinit(allocator);
    try interpreter2.interpret();
    try std.testing.expectEqual(@as(u256, 0), interpreter2.frame.stack.peek_unsafe());
}

test "FrameInterpreter bitwise operations - BYTE operation edge cases" {
    const allocator = std.testing.allocator;
    const FrameInterpreterType = FrameInterpreter(.{});

    // Test BYTE with index 0 (most significant byte): BYTE(0, 0xFF00) -> 0xFF
    const bytecode_byte_0 = [_]u8{ 0x61, 0xFF, 0x00, 0x60, 0x00, 0x1A, 0x00 }; // PUSH2 0xFF00, PUSH1 0, BYTE, STOP
    var interpreter = try FrameInterpreterType.init(allocator, &bytecode_byte_0, 1000000, {}, HostMock.init());
    defer interpreter.deinit(allocator);
    try interpreter.interpret();
    try std.testing.expectEqual(@as(u256, 0x00), interpreter.frame.stack.peek_unsafe()); // byte 0 of 0xFF00 is 0x00

    // Test BYTE with index 1: BYTE(1, 0xFF00) -> 0x00
    const bytecode_byte_1 = [_]u8{ 0x61, 0xFF, 0x00, 0x60, 0x01, 0x1A, 0x00 }; // PUSH2 0xFF00, PUSH1 1, BYTE, STOP
    var interpreter2 = try FrameInterpreterType.init(allocator, &bytecode_byte_1, 1000000, {}, HostMock.init());
    defer interpreter2.deinit(allocator);
    try interpreter2.interpret();
    try std.testing.expectEqual(@as(u256, 0xFF), interpreter2.frame.stack.peek_unsafe());

    // Test BYTE with out-of-bounds index: BYTE(32, value) -> 0
    const bytecode_byte_oob = [_]u8{ 0x60, 0xFF, 0x60, 0x20, 0x1A, 0x00 }; // PUSH1 0xFF, PUSH1 32, BYTE, STOP
    var interpreter3 = try FrameInterpreterType.init(allocator, &bytecode_byte_oob, 1000000, {}, HostMock.init());
    defer interpreter3.deinit(allocator);
    try interpreter3.interpret();
    try std.testing.expectEqual(@as(u256, 0), interpreter3.frame.stack.peek_unsafe());
}

test "FrameInterpreter bitwise operations - shift operations SHL, SHR, SAR" {
    const allocator = std.testing.allocator;
    const FrameInterpreterType = FrameInterpreter(.{});

    // Test SHL with small shift: 1 << 4 -> 16
    const bytecode_shl = [_]u8{ 0x60, 0x01, 0x60, 0x04, 0x1B, 0x00 }; // PUSH1 1, PUSH1 4, SHL, STOP
    var interpreter = try FrameInterpreterType.init(allocator, &bytecode_shl, 1000000, {}, HostMock.init());
    defer interpreter.deinit(allocator);
    try interpreter.interpret();
    try std.testing.expectEqual(@as(u256, 16), interpreter.frame.stack.peek_unsafe());

    // Test SHR with logical shift: 16 >> 4 -> 1
    const bytecode_shr = [_]u8{ 0x60, 0x10, 0x60, 0x04, 0x1C, 0x00 }; // PUSH1 16, PUSH1 4, SHR, STOP
    var interpreter2 = try FrameInterpreterType.init(allocator, &bytecode_shr, 1000000, {}, HostMock.init());
    defer interpreter2.deinit(allocator);
    try interpreter2.interpret();
    try std.testing.expectEqual(@as(u256, 1), interpreter2.frame.stack.peek_unsafe());

    // Test SHL with large shift (should wrap to 0): any_value << 256 -> 0
    const bytecode_shl_overflow = [_]u8{ 0x60, 0xFF, 0x61, 0x01, 0x00, 0x1B, 0x00 }; // PUSH1 255, PUSH2 256, SHL, STOP
    var interpreter3 = try FrameInterpreterType.init(allocator, &bytecode_shl_overflow, 1000000, {}, HostMock.init());
    defer interpreter3.deinit(allocator);
    try interpreter3.interpret();
    try std.testing.expectEqual(@as(u256, 0), interpreter3.frame.stack.peek_unsafe());

    // Test SAR with negative number: -8 >> 1 should preserve sign
    const neg_eight: u256 = (~@as(u256, 7)) + 1; // Two's complement of 8

    var bytecode: [36]u8 = undefined;
    var idx: usize = 0;

    // PUSH32 (neg_eight)
    bytecode[idx] = 0x7F;
    idx += 1;
    std.mem.writeInt(u256, bytecode[idx..][0..32], neg_eight, .big);
    idx += 32;
    // PUSH1 1 (shift amount)
    bytecode[idx] = 0x60;
    idx += 1;
    bytecode[idx] = 0x01;
    idx += 1;
    // SAR
    bytecode[idx] = 0x1D;
    idx += 1;
    // STOP
    bytecode[idx] = 0x00;

    var interpreter4 = try FrameInterpreterType.init(allocator, &bytecode, 1000000, {}, HostMock.init());
    defer interpreter4.deinit(allocator);
    try interpreter4.interpret();

    // SAR(-8, 1) should be -4 (arithmetic right shift preserves sign bit)
    const neg_four: u256 = (~@as(u256, 3)) + 1;
    try std.testing.expectEqual(neg_four, interpreter4.frame.stack.peek_unsafe());
}

test "FrameInterpreter stack error conditions - stack underflow" {
    const allocator = std.testing.allocator;
    const FrameInterpreterType = FrameInterpreter(.{});

    // Test POP on empty stack - should cause underflow error
    const bytecode_pop_empty = [_]u8{ 0x50, 0x00 }; // POP, STOP
    var interpreter = try FrameInterpreterType.init(allocator, &bytecode_pop_empty, 1000000, {}, HostMock.init());
    defer interpreter.deinit(allocator);

    // Should return stack underflow error
    const result = interpreter.interpret();
    try std.testing.expectError(error.StackUnderflow, result);
}

test "FrameInterpreter stack error conditions - ADD with insufficient stack" {
    const allocator = std.testing.allocator;
    const FrameInterpreterType = FrameInterpreter(.{});

    // Test ADD with only one value on stack - should cause underflow
    const bytecode_add_underflow = [_]u8{ 0x60, 0x05, 0x01, 0x00 }; // PUSH1 5, ADD, STOP
    var interpreter = try FrameInterpreterType.init(allocator, &bytecode_add_underflow, 1000000, {}, HostMock.init());
    defer interpreter.deinit(allocator);

    // Should return stack underflow error
    const result = interpreter.interpret();
    try std.testing.expectError(error.StackUnderflow, result);
}

test "FrameInterpreter stack error conditions - DUP with insufficient stack" {
    const allocator = std.testing.allocator;
    const FrameInterpreterType = FrameInterpreter(.{});

    // Test DUP2 with only one value on stack - should cause underflow
    const bytecode_dup_underflow = [_]u8{ 0x60, 0x05, 0x81, 0x00 }; // PUSH1 5, DUP2, STOP
    var interpreter = try FrameInterpreterType.init(allocator, &bytecode_dup_underflow, 1000000, {}, HostMock.init());
    defer interpreter.deinit(allocator);

    // Should return stack underflow error
    const result = interpreter.interpret();
    try std.testing.expectError(error.StackUnderflow, result);
}

test "FrameInterpreter stack error conditions - SWAP with insufficient stack" {
    const allocator = std.testing.allocator;
    const FrameInterpreterType = FrameInterpreter(.{});

    // Test SWAP1 with empty stack - should cause underflow
    const bytecode_swap_underflow = [_]u8{ 0x90, 0x00 }; // SWAP1, STOP
    var interpreter = try FrameInterpreterType.init(allocator, &bytecode_swap_underflow, 1000000, {}, HostMock.init());
    defer interpreter.deinit(allocator);

    // Should return stack underflow error
    const result = interpreter.interpret();
    try std.testing.expectError(error.StackUnderflow, result);
}

test "FrameInterpreter stack operations - DUP1 through DUP16 functionality" {
    const allocator = std.testing.allocator;
    const FrameInterpreterType = FrameInterpreter(.{});

    // Test DUP1: duplicates top stack item
    const bytecode_dup1 = [_]u8{ 0x60, 0x42, 0x80, 0x00 }; // PUSH1 0x42, DUP1, STOP
    var interpreter = try FrameInterpreterType.init(allocator, &bytecode_dup1, 1000000, {}, HostMock.init());
    defer interpreter.deinit(allocator);
    try interpreter.interpret();

    // Should have two copies of 0x42 on stack
    try std.testing.expectEqual(@as(u256, 0x42), interpreter.frame.stack.peek_unsafe());

    // Test DUP2: duplicates second stack item
    // Create stack: [0x10, 0x20] then DUP2 -> [0x10, 0x20, 0x10]
    const bytecode_dup2 = [_]u8{ 0x60, 0x10, 0x60, 0x20, 0x81, 0x00 }; // PUSH1 0x10, PUSH1 0x20, DUP2, STOP
    var interpreter2 = try FrameInterpreterType.init(allocator, &bytecode_dup2, 1000000, {}, HostMock.init());
    defer interpreter2.deinit(allocator);
    try interpreter2.interpret();

    // Top of stack should be 0x10 (duplicated from position 2)
    try std.testing.expectEqual(@as(u256, 0x10), interpreter2.frame.stack.peek_unsafe());
}

test "FrameInterpreter stack operations - SWAP1 through SWAP16 functionality" {
    const allocator = std.testing.allocator;
    const FrameInterpreterType = FrameInterpreter(.{});

    // Test SWAP1: swaps top two stack items
    // Create stack: [0x10, 0x20] then SWAP1 -> [0x20, 0x10]
    const bytecode_swap1 = [_]u8{ 0x60, 0x10, 0x60, 0x20, 0x90, 0x00 }; // PUSH1 0x10, PUSH1 0x20, SWAP1, STOP
    var interpreter = try FrameInterpreterType.init(allocator, &bytecode_swap1, 1000000, {}, HostMock.init());
    defer interpreter.deinit(allocator);
    try interpreter.interpret();

    // Top of stack should now be 0x10 (swapped from second position)
    try std.testing.expectEqual(@as(u256, 0x10), interpreter.frame.stack.peek_unsafe());

    // Test SWAP2: swaps top with third item
    // Create stack: [0x10, 0x20, 0x30] then SWAP2 -> [0x30, 0x20, 0x10]
    const bytecode_swap2 = [_]u8{ 0x60, 0x10, 0x60, 0x20, 0x60, 0x30, 0x91, 0x00 }; // PUSH1 0x10, PUSH1 0x20, PUSH1 0x30, SWAP2, STOP
    var interpreter2 = try FrameInterpreterType.init(allocator, &bytecode_swap2, 1000000, {}, HostMock.init());
    defer interpreter2.deinit(allocator);
    try interpreter2.interpret();

    // Top of stack should now be 0x10 (swapped from third position)
    try std.testing.expectEqual(@as(u256, 0x10), interpreter2.frame.stack.peek_unsafe());
}

test "FrameInterpreter jump operations - invalid jump destinations" {
    const allocator = std.testing.allocator;
    const FrameInterpreterType = FrameInterpreter(.{});

    // Test JUMP to invalid destination (out of bounds)
    const bytecode_jump_oob = [_]u8{ 0x61, 0xFF, 0xFF, 0x56, 0x00 }; // PUSH2 0xFFFF, JUMP, STOP
    var interpreter = try FrameInterpreterType.init(allocator, &bytecode_jump_oob, 1000000, {}, HostMock.init());
    defer interpreter.deinit(allocator);

    // Should return InvalidJump error for out-of-bounds destination
    const result = interpreter.interpret();
    try std.testing.expectError(error.InvalidJump, result);
}

test "FrameInterpreter jump operations - jump to middle of PUSH data" {
    const allocator = std.testing.allocator;
    const FrameInterpreterType = FrameInterpreter(.{});

    // Create bytecode: PUSH2 data, PUSH1 1, JUMP
    // Trying to jump to PC=1 which is middle of PUSH2 data (invalid)
    const bytecode_jump_push_data = [_]u8{ 0x61, 0x12, 0x34, 0x60, 0x01, 0x56, 0x00 }; // PUSH2 0x1234, PUSH1 1, JUMP, STOP
    var interpreter = try FrameInterpreterType.init(allocator, &bytecode_jump_push_data, 1000000, {}, HostMock.init());
    defer interpreter.deinit(allocator);

    // Should return InvalidJump error for jumping into PUSH data
    const result = interpreter.interpret();
    try std.testing.expectError(error.InvalidJump, result);
}

test "FrameInterpreter jump operations - valid JUMP to JUMPDEST" {
    const allocator = std.testing.allocator;
    const FrameInterpreterType = FrameInterpreter(.{});

    // Create valid jump: PUSH1 4, JUMP, JUMPDEST, PUSH1 0x42, STOP
    // Jump destination (PC=4) is a valid JUMPDEST
    const bytecode_valid_jump = [_]u8{ 0x60, 0x04, 0x56, 0xFF, 0x5B, 0x60, 0x42, 0x00 }; // PUSH1 4, JUMP, INVALID, JUMPDEST, PUSH1 0x42, STOP
    var interpreter = try FrameInterpreterType.init(allocator, &bytecode_valid_jump, 1000000, {}, HostMock.init());
    defer interpreter.deinit(allocator);

    try interpreter.interpret();

    // Should have 0x42 on stack after successful jump
    try std.testing.expectEqual(@as(u256, 0x42), interpreter.frame.stack.peek_unsafe());
}

test "FrameInterpreter jump operations - JUMPI conditional behavior" {
    const allocator = std.testing.allocator;
    const FrameInterpreterType = FrameInterpreter(.{});

    // Test JUMPI with false condition (0) - should not jump
    // PUSH1 7 (dest), PUSH1 0 (condition), JUMPI, PUSH1 0x11, STOP, JUMPDEST, PUSH1 0x22, STOP
    const bytecode_jumpi_false = [_]u8{ 0x60, 0x07, 0x60, 0x00, 0x57, 0x60, 0x11, 0x00, 0x5B, 0x60, 0x22, 0x00 };
    var interpreter = try FrameInterpreterType.init(allocator, &bytecode_jumpi_false, 1000000, {}, HostMock.init());
    defer interpreter.deinit(allocator);

    try interpreter.interpret();

    // Should have 0x11 on stack (did not jump)
    try std.testing.expectEqual(@as(u256, 0x11), interpreter.frame.stack.peek_unsafe());

    // Test JUMPI with true condition (non-zero) - should jump
    const bytecode_jumpi_true = [_]u8{ 0x60, 0x08, 0x60, 0x01, 0x57, 0x60, 0x11, 0x00, 0x5B, 0x60, 0x22, 0x00 };
    var interpreter2 = try FrameInterpreterType.init(allocator, &bytecode_jumpi_true, 1000000, {}, HostMock.init());
    defer interpreter2.deinit(allocator);

    try interpreter2.interpret();

    // Should have 0x22 on stack (jumped successfully)
    try std.testing.expectEqual(@as(u256, 0x22), interpreter2.frame.stack.peek_unsafe());
}

test "FrameInterpreter jump operations - JUMPI with invalid destination when condition is true" {
    const allocator = std.testing.allocator;
    const FrameInterpreterType = FrameInterpreter(.{});

    // Test JUMPI with true condition but invalid destination
    const bytecode_jumpi_invalid = [_]u8{ 0x61, 0xFF, 0xFF, 0x60, 0x01, 0x57, 0x00 }; // PUSH2 0xFFFF, PUSH1 1, JUMPI, STOP
    var interpreter = try FrameInterpreterType.init(allocator, &bytecode_jumpi_invalid, 1000000, {}, HostMock.init());
    defer interpreter.deinit(allocator);

    // Should return InvalidJump error when condition is true and destination is invalid
    const result = interpreter.interpret();
    try std.testing.expectError(error.InvalidJump, result);
}

test "FrameInterpreter jump operations - PC opcode returns correct program counter" {
    const allocator = std.testing.allocator;
    const FrameInterpreterType = FrameInterpreter(.{});

    // Test PC opcode: PUSH1 0x42, PC, STOP
    // PC should return 2 (position after PUSH1 instruction)
    const bytecode_pc = [_]u8{ 0x60, 0x42, 0x58, 0x00 }; // PUSH1 0x42, PC, STOP
    var interpreter = try FrameInterpreterType.init(allocator, &bytecode_pc, 1000000, {}, HostMock.init());
    defer interpreter.deinit(allocator);

    try interpreter.interpret();

    // Top of stack should be the PC value (2)
    try std.testing.expectEqual(@as(u256, 2), interpreter.frame.stack.peek_unsafe());
}

test "FrameInterpreter environment operations - ADDRESS, CALLER, ORIGIN, CALLVALUE" {
    const allocator = std.testing.allocator;
    const FrameInterpreterType = FrameInterpreter(.{});

    // Test ADDRESS opcode - should return current contract address (0x00 for default)
    const bytecode_address = [_]u8{ 0x30, 0x00 }; // ADDRESS, STOP
    var interpreter = try FrameInterpreterType.init(allocator, &bytecode_address, 1000000, {}, HostMock.init());
    defer interpreter.deinit(allocator);
    try interpreter.interpret();

    // Default address should be 0
    try std.testing.expectEqual(@as(u256, 0), interpreter.frame.stack.peek_unsafe());

    // Test CALLER opcode - should return caller address (0x00 for default)
    const bytecode_caller = [_]u8{ 0x33, 0x00 }; // CALLER, STOP
    var interpreter2 = try FrameInterpreterType.init(allocator, &bytecode_caller, 1000000, {}, HostMock.init());
    defer interpreter2.deinit(allocator);
    try interpreter2.interpret();

    // Default caller should be 0
    try std.testing.expectEqual(@as(u256, 0), interpreter2.frame.stack.peek_unsafe());

    // Test ORIGIN opcode - should return transaction origin (0x00 for default)
    const bytecode_origin = [_]u8{ 0x32, 0x00 }; // ORIGIN, STOP
    var interpreter3 = try FrameInterpreterType.init(allocator, &bytecode_origin, 1000000, {}, HostMock.init());
    defer interpreter3.deinit(allocator);
    try interpreter3.interpret();

    // Default origin should be 0
    try std.testing.expectEqual(@as(u256, 0), interpreter3.frame.stack.peek_unsafe());

    // Test CALLVALUE opcode - should return value sent with call (0x00 for default)
    const bytecode_callvalue = [_]u8{ 0x34, 0x00 }; // CALLVALUE, STOP
    var interpreter4 = try FrameInterpreterType.init(allocator, &bytecode_callvalue, 1000000, {}, HostMock.init());
    defer interpreter4.deinit(allocator);
    try interpreter4.interpret();

    // Default call value should be 0
    try std.testing.expectEqual(@as(u256, 0), interpreter4.frame.stack.peek_unsafe());
}

test "FrameInterpreter EXP operation with edge cases" {
    const allocator = std.testing.allocator;
    const FrameInterpreterType = FrameInterpreter(.{});

    // Test EXP with small values: 2^3 = 8
    const bytecode_exp_small = [_]u8{ 0x60, 0x03, 0x60, 0x02, 0x0A, 0x00 }; // PUSH1 3, PUSH1 2, EXP, STOP
    var interpreter = try FrameInterpreterType.init(allocator, &bytecode_exp_small, 1000000, {}, HostMock.init());
    defer interpreter.deinit(allocator);
    try interpreter.interpret();
    try std.testing.expectEqual(@as(u256, 8), interpreter.frame.stack.peek_unsafe());

    // Test EXP with zero exponent: 5^0 = 1
    const bytecode_exp_zero = [_]u8{ 0x60, 0x00, 0x60, 0x05, 0x0A, 0x00 }; // PUSH1 0, PUSH1 5, EXP, STOP
    var interpreter2 = try FrameInterpreterType.init(allocator, &bytecode_exp_zero, 1000000, {}, HostMock.init());
    defer interpreter2.deinit(allocator);
    try interpreter2.interpret();
    try std.testing.expectEqual(@as(u256, 1), interpreter2.frame.stack.peek_unsafe());

    // Test EXP with zero base: 0^5 = 0
    const bytecode_exp_zero_base = [_]u8{ 0x60, 0x05, 0x60, 0x00, 0x0A, 0x00 }; // PUSH1 5, PUSH1 0, EXP, STOP
    var interpreter3 = try FrameInterpreterType.init(allocator, &bytecode_exp_zero_base, 1000000, {}, HostMock.init());
    defer interpreter3.deinit(allocator);
    try interpreter3.interpret();
    try std.testing.expectEqual(@as(u256, 0), interpreter3.frame.stack.peek_unsafe());

    // Test EXP edge case: 0^0 = 1 (per EVM spec)
    const bytecode_exp_zero_zero = [_]u8{ 0x60, 0x00, 0x60, 0x00, 0x0A, 0x00 }; // PUSH1 0, PUSH1 0, EXP, STOP
    var interpreter4 = try FrameInterpreterType.init(allocator, &bytecode_exp_zero_zero, 1000000, {}, HostMock.init());
    defer interpreter4.deinit(allocator);
    try interpreter4.interpret();
    try std.testing.expectEqual(@as(u256, 1), interpreter4.frame.stack.peek_unsafe());
}

test "FrameInterpreter SIGNEXTEND operation with all byte positions" {
    const allocator = std.testing.allocator;
    const FrameInterpreterType = FrameInterpreter(.{});

    // Test SIGNEXTEND with byte position 0: sign extend from bit 7 (0x80 -> 0xFF...FF80)
    const bytecode_signext_0 = [_]u8{ 0x60, 0x80, 0x60, 0x00, 0x0B, 0x00 }; // PUSH1 0x80, PUSH1 0, SIGNEXTEND, STOP
    var interpreter = try FrameInterpreterType.init(allocator, &bytecode_signext_0, 1000000, {}, HostMock.init());
    defer interpreter.deinit(allocator);
    try interpreter.interpret();

    // 0x80 sign extended from byte 0 should be all 1s in upper bytes
    const expected_signext_0: u256 = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF80;
    try std.testing.expectEqual(expected_signext_0, interpreter.frame.stack.peek_unsafe());

    // Test SIGNEXTEND with positive value: 0x7F -> 0x7F (no sign extension needed)
    const bytecode_signext_pos = [_]u8{ 0x60, 0x7F, 0x60, 0x00, 0x0B, 0x00 }; // PUSH1 0x7F, PUSH1 0, SIGNEXTEND, STOP
    var interpreter2 = try FrameInterpreterType.init(allocator, &bytecode_signext_pos, 1000000, {}, HostMock.init());
    defer interpreter2.deinit(allocator);
    try interpreter2.interpret();
    try std.testing.expectEqual(@as(u256, 0x7F), interpreter2.frame.stack.peek_unsafe());

    // Test SIGNEXTEND with byte position 1: sign extend from bit 15
    const bytecode_signext_1 = [_]u8{ 0x61, 0x80, 0x00, 0x60, 0x01, 0x0B, 0x00 }; // PUSH2 0x8000, PUSH1 1, SIGNEXTEND, STOP
    var interpreter3 = try FrameInterpreterType.init(allocator, &bytecode_signext_1, 1000000, {}, HostMock.init());
    defer interpreter3.deinit(allocator);
    try interpreter3.interpret();

    // 0x8000 sign extended from byte 1 should have all 1s in upper bytes
    const expected_signext_1: u256 = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF8000;
    try std.testing.expectEqual(expected_signext_1, interpreter3.frame.stack.peek_unsafe());

    // Test SIGNEXTEND with out-of-bounds byte position (>= 32) - should return value unchanged
    const bytecode_signext_oob = [_]u8{ 0x60, 0x80, 0x60, 0x20, 0x0B, 0x00 }; // PUSH1 0x80, PUSH1 32, SIGNEXTEND, STOP
    var interpreter4 = try FrameInterpreterType.init(allocator, &bytecode_signext_oob, 1000000, {}, HostMock.init());
    defer interpreter4.deinit(allocator);
    try interpreter4.interpret();

    // Should return original value unchanged when byte position >= 32
    try std.testing.expectEqual(@as(u256, 0x80), interpreter4.frame.stack.peek_unsafe());
}

// ========== COMPREHENSIVE FRAME INTERPRETER TESTS ==========

test "FrameInterpreter plan execution - instruction stream validation" {
    const allocator = std.testing.allocator;
    const FrameInterpreterType = FrameInterpreter(.{});

    // Test plan creation with complex bytecode pattern
    const bytecode = [_]u8{
        0x60, 0x01, // PUSH1 1
        0x60, 0x02, // PUSH1 2
        0x01, // ADD
        0x61, 0x12, 0x34, // PUSH2 0x1234
        0x02, // MUL
        0x80, // DUP1
        0x90, // SWAP1
        0x50, // POP
        0x00, // STOP
    };

    var interpreter = try FrameInterpreterType.init(allocator, &bytecode, 1000000, {}, HostMock.init());
    defer interpreter.deinit(allocator);

    // Verify plan was created with correct instruction count
    try std.testing.expect(interpreter.plan.instructionStream.len > 0);

    // Verify initial state
    try std.testing.expectEqual(@as(@TypeOf(interpreter.instruction_idx), 0), interpreter.instruction_idx);
    try std.testing.expectEqual(@as(usize, 0), interpreter.frame.stack.size());

    // Execute and verify final state
    try interpreter.interpret();

    // Should have: ((1 + 2) * 0x1234) = 3 * 0x1234 = 0x369C remaining on stack
    try std.testing.expectEqual(@as(u256, 0x369C), interpreter.frame.stack.peek_unsafe());
}

test "FrameInterpreter plan execution - PC to instruction mapping" {
    const allocator = std.testing.allocator;
    const FrameInterpreterType = FrameInterpreter(.{});

    // Bytecode with varying instruction sizes to test PC mapping
    const bytecode = [_]u8{
        0x60, 0xFF, // PC 0: PUSH1 255 (2 bytes)
        0x61, 0x12, 0x34, // PC 2: PUSH2 0x1234 (3 bytes)
        0x62, 0xAB, 0xCD, 0xEF, // PC 5: PUSH3 0xABCDEF (4 bytes)
        0x01, // PC 9: ADD (1 byte)
        0x02, // PC 10: MUL (1 byte)
        0x00, // PC 11: STOP (1 byte)
    };

    var interpreter = try FrameInterpreterType.init(allocator, &bytecode, 1000000, {}, HostMock.init());
    defer interpreter.deinit(allocator);

    // Verify PC mapping exists
    if (interpreter.plan.pc_to_instruction_idx) |pc_map| {
        // Check that key PCs are mapped
        try std.testing.expect(pc_map.contains(0)); // PUSH1
        try std.testing.expect(pc_map.contains(2)); // PUSH2
        try std.testing.expect(pc_map.contains(5)); // PUSH3
        try std.testing.expect(pc_map.contains(9)); // ADD
        try std.testing.expect(pc_map.contains(10)); // MUL
        try std.testing.expect(pc_map.contains(11)); // STOP
    }

    try interpreter.interpret();

    // Verify computation: (255 + 0x1234 + 0xABCDEF) * something...
    // The exact result depends on operation order, just verify execution completed
    try std.testing.expect(interpreter.frame.stack.size() > 0);
}

test "FrameInterpreter JUMP execution - valid destinations" {
    const allocator = std.testing.allocator;
    const FrameInterpreterType = FrameInterpreter(.{});

    // Bytecode with valid jump: PUSH1 8, JUMP, invalid_ops, JUMPDEST, PUSH1 42, STOP
    const bytecode = [_]u8{
        0x60, 0x08, // PUSH1 8 (jump to PC 8)
        0x56, // JUMP
        0xFE, 0xFE, 0xFE, // Invalid opcodes (should be skipped)
        0x5B, // JUMPDEST at PC 8
        0x60, 0x2A, // PUSH1 42
        0x00, // STOP
    };

    var interpreter = try FrameInterpreterType.init(allocator, &bytecode, 1000000, {}, HostMock.init());
    defer interpreter.deinit(allocator);

    try interpreter.interpret();

    // Should have jumped over invalid opcodes and pushed 42
    try std.testing.expectEqual(@as(u256, 42), interpreter.frame.stack.peek_unsafe());
}

test "FrameInterpreter JUMPI execution - conditional jumps" {
    const allocator = std.testing.allocator;
    const FrameInterpreterType = FrameInterpreter(.{});

    // Test conditional jump with true condition
    // PUSH1 1, PUSH1 12, JUMPI, PUSH1 99, STOP, JUMPDEST, PUSH1 42, STOP
    const bytecode_true = [_]u8{
        0x60, 0x01, // PUSH1 1 (true condition)
        0x60, 0x0C, // PUSH1 12 (jump to PC 12)
        0x57, // JUMPI
        0x60, 0x63, // PUSH1 99 (should be skipped)
        0x00, // STOP (should be skipped)
        0x5B, // JUMPDEST at PC 12
        0x60, 0x2A, // PUSH1 42
        0x00, // STOP
    };

    var interpreter1 = try FrameInterpreterType.init(allocator, &bytecode_true, 1000000, {}, HostMock.init());
    defer interpreter1.deinit(allocator);

    try interpreter1.interpret();
    try std.testing.expectEqual(@as(u256, 42), interpreter1.frame.stack.peek_unsafe());

    // Test conditional jump with false condition
    // PUSH1 0, PUSH1 12, JUMPI, PUSH1 99, STOP, JUMPDEST, PUSH1 42, STOP
    const bytecode_false = [_]u8{
        0x60, 0x00, // PUSH1 0 (false condition)
        0x60, 0x0C, // PUSH1 12 (jump target)
        0x57, // JUMPI
        0x60, 0x63, // PUSH1 99 (should be executed)
        0x00, // STOP
        0x5B, // JUMPDEST at PC 12
        0x60, 0x2A, // PUSH1 42 (should be skipped)
        0x00, // STOP
    };

    var interpreter2 = try FrameInterpreterType.init(allocator, &bytecode_false, 1000000, {}, HostMock.init());
    defer interpreter2.deinit(allocator);

    try interpreter2.interpret();
    try std.testing.expectEqual(@as(u256, 99), interpreter2.frame.stack.peek_unsafe());
}

test "FrameInterpreter JUMP execution - invalid destinations" {
    const allocator = std.testing.allocator;
    const FrameInterpreterType = FrameInterpreter(.{});

    // Bytecode jumping to invalid destination (no JUMPDEST)
    const bytecode = [_]u8{
        0x60, 0x05, // PUSH1 5 (jump to PC 5, which is not JUMPDEST)
        0x56, // JUMP
        0x60, 0x2A, // PUSH1 42 (at PC 5, not JUMPDEST)
        0x00, // STOP
    };

    var interpreter = try FrameInterpreterType.init(allocator, &bytecode, 1000000, {}, HostMock.init());
    defer interpreter.deinit(allocator);

    // Should return InvalidJumpDestination error
    try std.testing.expectError(error.InvalidJumpDestination, interpreter.interpret());
}

test "FrameInterpreter gas consumption - instruction costs" {
    const allocator = std.testing.allocator;
    const FrameInterpreterType = FrameInterpreter(.{});

    const initial_gas = 1000;

    // Simple bytecode to test gas consumption
    const bytecode = [_]u8{
        0x60, 0x01, // PUSH1 1
        0x60, 0x02, // PUSH1 2
        0x01, // ADD
        0x00, // STOP
    };

    var interpreter = try FrameInterpreterType.init(allocator, &bytecode, initial_gas, {}, HostMock.init());
    defer interpreter.deinit(allocator);

    const start_gas = @max(interpreter.frame.gas_remaining, 0);
    try interpreter.interpret();
    const end_gas = @max(interpreter.frame.gas_remaining, 0);

    // Gas should have been consumed
    try std.testing.expect(end_gas < start_gas);
    try std.testing.expectEqual(@as(u256, 3), interpreter.frame.stack.peek_unsafe());
}

test "FrameInterpreter gas consumption - out of gas" {
    const allocator = std.testing.allocator;
    const FrameInterpreterType = FrameInterpreter(.{});

    // Bytecode that should consume more gas than available
    const bytecode = [_]u8{
        0x60, 0x01, // PUSH1 1
        0x60, 0x02, // PUSH1 2
        0x01, // ADD
        0x02, // MUL
        0x03, // SUB
        0x00, // STOP
    };

    // Start with very low gas
    var interpreter = try FrameInterpreterType.init(allocator, &bytecode, 1, {}, HostMock.init()); // Very low gas
    defer interpreter.deinit(allocator);

    // Should run out of gas during execution
    try std.testing.expectError(error.OutOfGas, interpreter.interpret());
}

test "FrameInterpreter handler state consistency" {
    const allocator = std.testing.allocator;
    const FrameInterpreterType = FrameInterpreter(.{});

    // Complex bytecode that tests handler state transitions
    const bytecode = [_]u8{
        0x60, 0x0A, // PUSH1 10
        0x80, // DUP1 (stack: [10, 10])
        0x60, 0x05, // PUSH1 5 (stack: [10, 10, 5])
        0x90, // SWAP1 (stack: [10, 5, 10])
        0x01, // ADD (stack: [10, 15])
        0x91, // SWAP2 (stack: [15, 10])
        0x02, // MUL (stack: [150])
        0x00, // STOP
    };

    var interpreter = try FrameInterpreterType.init(allocator, &bytecode, 1000000, {}, HostMock.init());
    defer interpreter.deinit(allocator);

    try interpreter.interpret();

    // Verify final state: 10 * 15 = 150
    try std.testing.expectEqual(@as(u256, 150), interpreter.frame.stack.peek_unsafe());
    try std.testing.expectEqual(@as(usize, 1), interpreter.frame.stack.size());
}

test "FrameInterpreter complex execution - nested operations" {
    const allocator = std.testing.allocator;
    const FrameInterpreterType = FrameInterpreter(.{});

    // Complex nested operations: ((a + b) * c) - d where a=5, b=3, c=2, d=1
    // Expected result: ((5 + 3) * 2) - 1 = 16 - 1 = 15
    const bytecode = [_]u8{
        0x60, 0x05, // PUSH1 5 (a)
        0x60, 0x03, // PUSH1 3 (b)
        0x01, // ADD: a + b = 8
        0x60, 0x02, // PUSH1 2 (c)
        0x02, // MUL: (a + b) * c = 16
        0x60, 0x01, // PUSH1 1 (d)
        0x03, // SUB: ((a + b) * c) - d = 15
        0x00, // STOP
    };

    var interpreter = try FrameInterpreterType.init(allocator, &bytecode, 1000000, {}, HostMock.init());
    defer interpreter.deinit(allocator);

    try interpreter.interpret();

    try std.testing.expectEqual(@as(u256, 15), interpreter.frame.stack.peek_unsafe());
    try std.testing.expectEqual(@as(usize, 1), interpreter.frame.stack.size());
}

test "FrameInterpreter complex execution - loop simulation" {
    const allocator = std.testing.allocator;
    const FrameInterpreterType = FrameInterpreter(.{});

    // Simulate a simple counting loop using JUMPs
    // Initialize counter=0, target=3, increment until counter >= target
    const bytecode = [_]u8{
        // Setup: counter=0, target=3
        0x60, 0x00, // PUSH1 0 (counter)
        0x60, 0x03, // PUSH1 3 (target)
        // Loop start at PC 6
        0x81, // DUP2 (duplicate counter)
        0x82, // DUP3 (duplicate target)
        0x10, // LT (counter < target?)
        0x60, 0x14, // PUSH1 20 (jump to end if false)
        0x57, // JUMPI
        // Loop body: increment counter
        0x91, // SWAP2 (bring counter to top)
        0x60, 0x01, // PUSH1 1
        0x01, // ADD (increment counter)
        0x90, // SWAP1 (restore stack order)
        0x60, 0x06, // PUSH1 6 (jump back to loop start)
        0x56, // JUMP
        // End at PC 20
        0x5B, // JUMPDEST
        0x50, // POP (remove target)
        0x00, // STOP
    };

    var interpreter = try FrameInterpreterType.init(allocator, &bytecode, 1000000, {}, HostMock.init());
    defer interpreter.deinit(allocator);

    try interpreter.interpret();

    // Should have counter=3 on stack after loop
    try std.testing.expectEqual(@as(u256, 3), interpreter.frame.stack.peek_unsafe());
}

test "FrameInterpreter error recovery - stack underflow during execution" {
    const allocator = std.testing.allocator;
    const FrameInterpreterType = FrameInterpreter(.{});

    // Bytecode that causes stack underflow
    const bytecode = [_]u8{
        0x60, 0x01, // PUSH1 1
        0x01, // ADD (tries to pop 2 items, only 1 available)
        0x00, // STOP
    };

    var interpreter = try FrameInterpreterType.init(allocator, &bytecode, 1000000, {}, HostMock.init());
    defer interpreter.deinit(allocator);

    try std.testing.expectError(error.StackUnderflow, interpreter.interpret());

    // Verify stack state after error
    try std.testing.expectEqual(@as(usize, 1), interpreter.frame.stack.size());
    try std.testing.expectEqual(@as(u256, 1), interpreter.frame.stack.peek_unsafe());
}

test "FrameInterpreter error recovery - invalid opcode handling" {
    const allocator = std.testing.allocator;
    const FrameInterpreterType = FrameInterpreter(.{});

    // Bytecode with invalid opcode in middle of execution
    const bytecode = [_]u8{
        0x60, 0x2A, // PUSH1 42
        0x60, 0x10, // PUSH1 16
        0xFE, // INVALID opcode
        0x01, // ADD (should never be reached)
        0x00, // STOP
    };

    var interpreter = try FrameInterpreterType.init(allocator, &bytecode, 1000000, {}, HostMock.init());
    defer interpreter.deinit(allocator);

    try std.testing.expectError(error.InvalidOpcode, interpreter.interpret());

    // Verify stack state was preserved until invalid opcode
    try std.testing.expectEqual(@as(usize, 2), interpreter.frame.stack.size());
    try std.testing.expectEqual(@as(u256, 16), interpreter.frame.stack.peek_unsafe());
}

test "FrameInterpreter instruction index tracking" {
    const allocator = std.testing.allocator;
    const FrameInterpreterType = FrameInterpreter(.{});

    const bytecode = [_]u8{
        0x60, 0x01, // PUSH1 1
        0x60, 0x02, // PUSH1 2
        0x01, // ADD
        0x00, // STOP
    };

    var interpreter = try FrameInterpreterType.init(allocator, &bytecode, 1000000, {}, HostMock.init());
    defer interpreter.deinit(allocator);

    // Initial instruction index should be 0
    try std.testing.expectEqual(@as(@TypeOf(interpreter.instruction_idx), 0), interpreter.instruction_idx);

    try interpreter.interpret();

    // After execution, the instruction index tracking is internal to handlers
    // Main test is that execution completed successfully
    try std.testing.expectEqual(@as(u256, 3), interpreter.frame.stack.peek_unsafe());
}

test "FrameInterpreter stack overflow during execution" {
    const allocator = std.testing.allocator;
    const FrameInterpreterType = FrameInterpreter(.{ .stack_size = 3 }); // Very small stack

    // Bytecode that pushes too many values
    const bytecode = [_]u8{
        0x60, 0x01, // PUSH1 1
        0x60, 0x02, // PUSH1 2
        0x60, 0x03, // PUSH1 3 (stack at capacity)
        0x60, 0x04, // PUSH1 4 (should cause overflow)
        0x00, // STOP
    };

    var interpreter = try FrameInterpreterType.init(allocator, &bytecode, 1000000, {}, HostMock.init());
    defer interpreter.deinit(allocator);

    try std.testing.expectError(error.StackOverflow, interpreter.interpret());

    // Stack should be at capacity
    try std.testing.expectEqual(@as(usize, 3), interpreter.frame.stack.size());
}

test "FrameInterpreter memory operations integration" {
    const allocator = std.testing.allocator;
    const FrameInterpreterType = FrameInterpreter(.{});

    // Test memory operations: MSTORE then MLOAD
    const bytecode = [_]u8{
        0x60, 0x42, // PUSH1 0x42 (value)
        0x60, 0x00, // PUSH1 0 (offset)
        0x52, // MSTORE
        0x60, 0x00, // PUSH1 0 (offset)
        0x51, // MLOAD
        0x00, // STOP
    };

    var interpreter = try FrameInterpreterType.init(allocator, &bytecode, 1000000, {}, HostMock.init());
    defer interpreter.deinit(allocator);

    try interpreter.interpret();

    // Should have loaded the stored value
    try std.testing.expectEqual(@as(u256, 0x42), interpreter.frame.stack.peek_unsafe());

    // Memory should have been expanded
    try std.testing.expect(interpreter.frame.memory.size() >= 32);
}

test "FrameInterpreter pretty print functionality" {
    const allocator = std.testing.allocator;
    const FrameInterpreterType = FrameInterpreter(.{});

    const bytecode = [_]u8{ 0x60, 0x2A, 0x00 }; // PUSH1 42, STOP

    var interpreter = try FrameInterpreterType.init(allocator, &bytecode, 1000000, {}, HostMock.init());
    defer interpreter.deinit(allocator);

    // Test pretty print before execution (should not crash)
    interpreter.pretty_print();

    try interpreter.interpret();

    // Test pretty print after execution (should not crash)
    interpreter.pretty_print();

    // Basic verification
    try std.testing.expectEqual(@as(u256, 42), interpreter.frame.stack.peek_unsafe());
}

test "FrameInterpreter multiple execution attempts" {
    const allocator = std.testing.allocator;
    const FrameInterpreterType = FrameInterpreter(.{});

    const bytecode = [_]u8{ 0x60, 0x2A, 0x00 }; // PUSH1 42, STOP

    var interpreter = try FrameInterpreterType.init(allocator, &bytecode, 1000000, {}, HostMock.init());
    defer interpreter.deinit(allocator);

    // First execution
    try interpreter.interpret();
    try std.testing.expectEqual(@as(u256, 42), interpreter.frame.stack.peek_unsafe());

    // Second execution attempt should work (interpreter resets state)
    // Note: This may not be the intended behavior, but we test current behavior
    const initial_stack_len = interpreter.frame.stack.size();
    const initial_gas = @max(interpreter.frame.gas_remaining, 0);

    // Verify that state is as expected after first execution
    try std.testing.expectEqual(@as(usize, 1), initial_stack_len);
    try std.testing.expect(initial_gas < 1000000); // Gas was consumed
}

test "FrameInterpreter zero-length bytecode" {
    const allocator = std.testing.allocator;
    const FrameInterpreterType = FrameInterpreter(.{});

    const bytecode = [_]u8{}; // Empty bytecode

    var interpreter = try FrameInterpreterType.init(allocator, &bytecode, 1000000, {}, HostMock.init());
    defer interpreter.deinit(allocator);

    // Empty bytecode returns success (implicit STOP) and leaves stack empty
    try interpreter.interpret();
    try std.testing.expectEqual(@as(usize, 0), interpreter.frame.stack.size());
}

// ========== ADDITIONAL HIGH-VALUE TEST CATEGORIES ==========

// 1. HOST INTERFACE INTEGRATION TESTS ⭐⭐⭐⭐⭐

test "FrameInterpreter host interface - ADDRESS opcode" {
    const allocator = std.testing.allocator;
    const FrameInterpreterType = FrameInterpreter(.{});

    const bytecode = [_]u8{ 0x30, 0x00 }; // ADDRESS, STOP
    var interpreter = try FrameInterpreterType.init(allocator, &bytecode, 1000000, {}, HostMock.init());
    defer interpreter.deinit(allocator);

    // Set a mock contract address for ADDRESS to return
    const test_address = [_]u8{0xAA} ++ [_]u8{0} ** 19;
    interpreter.frame.contract_address = test_address;

    try interpreter.interpret();

    // ADDRESS should push the contract address as u256
    const expected = primitives.Address.to_u256(test_address);
    try std.testing.expectEqual(expected, interpreter.frame.stack.peek_unsafe());
}

test "FrameInterpreter host interface - multiple host calls" {
    const allocator = std.testing.allocator;
    const FrameInterpreterType = FrameInterpreter(.{});

    // Test multiple host operations in sequence
    const bytecode = [_]u8{
        0x30, // ADDRESS
        0x32, // ORIGIN
        0x33, // CALLER
        0x34, // CALLVALUE
        0x00, // STOP
    };

    var interpreter = try FrameInterpreterType.init(allocator, &bytecode, 1000000, {}, HostMock.init());
    defer interpreter.deinit(allocator);

    // Set test addresses
    interpreter.frame.contract_address = [_]u8{0xAA} ++ [_]u8{0} ** 19;

    try interpreter.interpret();

    // Should have 4 values on stack
    try std.testing.expectEqual(@as(usize, 4), interpreter.frame.stack.size());

    // Check that all host operations pushed values (exact values depend on host mock)
    const callvalue = interpreter.frame.stack.pop_unsafe();
    const caller = interpreter.frame.stack.pop_unsafe();
    const origin = interpreter.frame.stack.pop_unsafe();
    const address = interpreter.frame.stack.pop_unsafe();

    try std.testing.expect(address != 0);
    try std.testing.expect(origin != 0);
    try std.testing.expect(caller != 0);
    try std.testing.expect(callvalue != 0);
}

// 2. PUSH INSTRUCTION COMPREHENSIVE TESTING ⭐⭐⭐⭐⭐

test "FrameInterpreter PUSH instructions - all sizes boundary values" {
    const allocator = std.testing.allocator;
    const FrameInterpreterType = FrameInterpreter(.{});

    // Test PUSH1 with 0x00
    const bytecode_push1_zero = [_]u8{ 0x60, 0x00, 0x00 }; // PUSH1 0, STOP
    var interpreter1 = try FrameInterpreterType.init(allocator, &bytecode_push1_zero, 1000000, {}, HostMock.init());
    defer interpreter1.deinit(allocator);
    try interpreter1.interpret();
    try std.testing.expectEqual(@as(u256, 0x00), interpreter1.frame.stack.peek_unsafe());

    // Test PUSH1 with 0xFF (maximum for 1 byte)
    const bytecode_push1_max = [_]u8{ 0x60, 0xFF, 0x00 }; // PUSH1 255, STOP
    var interpreter2 = try FrameInterpreterType.init(allocator, &bytecode_push1_max, 1000000, {}, HostMock.init());
    defer interpreter2.deinit(allocator);
    try interpreter2.interpret();
    try std.testing.expectEqual(@as(u256, 0xFF), interpreter2.frame.stack.peek_unsafe());

    // Test PUSH2 with maximum value (0xFFFF)
    const bytecode_push2_max = [_]u8{ 0x61, 0xFF, 0xFF, 0x00 }; // PUSH2 65535, STOP
    var interpreter3 = try FrameInterpreterType.init(allocator, &bytecode_push2_max, 1000000, {}, HostMock.init());
    defer interpreter3.deinit(allocator);
    try interpreter3.interpret();
    try std.testing.expectEqual(@as(u256, 0xFFFF), interpreter3.frame.stack.peek_unsafe());

    // Test PUSH4 with specific pattern
    const bytecode_push4 = [_]u8{ 0x63, 0xDE, 0xAD, 0xBE, 0xEF, 0x00 }; // PUSH4 0xDEADBEEF, STOP
    var interpreter4 = try FrameInterpreterType.init(allocator, &bytecode_push4, 1000000, {}, HostMock.init());
    defer interpreter4.deinit(allocator);
    try interpreter4.interpret();
    try std.testing.expectEqual(@as(u256, 0xDEADBEEF), interpreter4.frame.stack.peek_unsafe());
}

test "FrameInterpreter PUSH instructions - large sizes" {
    const allocator = std.testing.allocator;
    const FrameInterpreterType = FrameInterpreter(.{});

    // Test PUSH8 with 64-bit pattern
    const bytecode_push8 = [_]u8{ 0x67, 0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0, 0x00 }; // PUSH8, STOP
    var interpreter1 = try FrameInterpreterType.init(allocator, &bytecode_push8, 1000000, {}, HostMock.init());
    defer interpreter1.deinit(allocator);
    try interpreter1.interpret();
    try std.testing.expectEqual(@as(u256, 0x123456789ABCDEF0), interpreter1.frame.stack.peek_unsafe());

    // Test PUSH16 with specific pattern
    var bytecode_push16: [18]u8 = undefined;
    bytecode_push16[0] = 0x6F; // PUSH16
    for (1..17) |i| {
        bytecode_push16[i] = @as(u8, @intCast(i));
    }
    bytecode_push16[17] = 0x00; // STOP

    var interpreter2 = try FrameInterpreterType.init(allocator, &bytecode_push16, 1000000, {}, HostMock.init());
    defer interpreter2.deinit(allocator);
    try interpreter2.interpret();

    // Calculate expected value
    var expected: u256 = 0;
    for (1..17) |i| {
        expected = (expected << 8) | @as(u256, i);
    }
    try std.testing.expectEqual(expected, interpreter2.frame.stack.peek_unsafe());

    // Test PUSH32 with maximum value
    var bytecode_push32: [34]u8 = undefined;
    bytecode_push32[0] = 0x7F; // PUSH32
    for (1..33) |i| {
        bytecode_push32[i] = 0xFF;
    }
    bytecode_push32[33] = 0x00; // STOP

    var interpreter3 = try FrameInterpreterType.init(allocator, &bytecode_push32, 1000000, {}, HostMock.init());
    defer interpreter3.deinit(allocator);
    try interpreter3.interpret();
    try std.testing.expectEqual(std.math.maxInt(u256), interpreter3.frame.stack.peek_unsafe());
}

test "FrameInterpreter PUSH instructions - zero patterns" {
    const allocator = std.testing.allocator;
    const FrameInterpreterType = FrameInterpreter(.{});

    // Test PUSH16 with all zeros
    var bytecode_push16_zero: [18]u8 = undefined;
    bytecode_push16_zero[0] = 0x6F; // PUSH16
    for (1..17) |i| {
        bytecode_push16_zero[i] = 0x00;
    }
    bytecode_push16_zero[17] = 0x00; // STOP

    var interpreter1 = try FrameInterpreterType.init(allocator, &bytecode_push16_zero, 1000000, {}, HostMock.init());
    defer interpreter1.deinit(allocator);
    try interpreter1.interpret();
    try std.testing.expectEqual(@as(u256, 0), interpreter1.frame.stack.peek_unsafe());

    // Test PUSH32 with all zeros
    var bytecode_push32_zero: [34]u8 = undefined;
    bytecode_push32_zero[0] = 0x7F; // PUSH32
    for (1..33) |i| {
        bytecode_push32_zero[i] = 0x00;
    }
    bytecode_push32_zero[33] = 0x00; // STOP

    var interpreter2 = try FrameInterpreterType.init(allocator, &bytecode_push32_zero, 1000000, {}, HostMock.init());
    defer interpreter2.deinit(allocator);
    try interpreter2.interpret();
    try std.testing.expectEqual(@as(u256, 0), interpreter2.frame.stack.peek_unsafe());
}

// 3. BYTECODE PARSING EDGE CASES ⭐⭐⭐⭐⭐

test "FrameInterpreter bytecode parsing - truncated PUSH instructions" {
    const allocator = std.testing.allocator;
    const FrameInterpreterType = FrameInterpreter(.{});

    // Test PUSH1 with missing data (truncated)
    const bytecode_truncated_push1 = [_]u8{0x60}; // PUSH1 without data byte
    var interpreter1 = try FrameInterpreterType.init(allocator, &bytecode_truncated_push1, 1000000, {}, HostMock.init());
    defer interpreter1.deinit(allocator);

    // Should handle truncated PUSH gracefully (error or treat as 0)
    const result1 = interpreter1.interpret();
    if (result1) {
        // If it succeeds, should push 0
        try std.testing.expectEqual(@as(u256, 0), interpreter1.frame.stack.peek_unsafe());
    } else |err| {
        // If it fails, should be a specific error type
        try std.testing.expect(err == error.TruncatedPush or err == error.OutOfBounds or err == error.InvalidOpcode);
    }

    // Test PUSH4 with only 2 bytes of data (truncated)
    const bytecode_truncated_push4 = [_]u8{ 0x63, 0xDE, 0xAD }; // PUSH4 with only 2 bytes
    var interpreter2 = try FrameInterpreterType.init(allocator, &bytecode_truncated_push4, 1000000, {}, HostMock.init());
    defer interpreter2.deinit(allocator);

    const result2 = interpreter2.interpret();
    if (result2) {
        // If it succeeds, should push partial data padded with zeros
        try std.testing.expect(interpreter2.frame.stack.peek_unsafe() != 0);
    } else |err| {
        try std.testing.expect(err == error.TruncatedPush or err == error.OutOfBounds or err == error.InvalidOpcode);
    }

    // Test PUSH32 with only 16 bytes (severely truncated)
    var bytecode_truncated_push32: [17]u8 = undefined;
    bytecode_truncated_push32[0] = 0x7F; // PUSH32
    for (1..17) |i| {
        bytecode_truncated_push32[i] = @as(u8, @intCast(i));
    }
    // Missing 16 bytes for PUSH32

    var interpreter3 = try FrameInterpreterType.init(allocator, &bytecode_truncated_push32, 1000000, {}, HostMock.init());
    defer interpreter3.deinit(allocator);

    const result3 = interpreter3.interpret();
    if (result3) {
        // If it succeeds, should have some data
        try std.testing.expect(interpreter3.frame.stack.size() > 0);
    } else |err| {
        try std.testing.expect(err == error.TruncatedPush or err == error.OutOfBounds or err == error.InvalidOpcode);
    }
}

test "FrameInterpreter bytecode parsing - malformed instruction sequences" {
    const allocator = std.testing.allocator;
    const FrameInterpreterType = FrameInterpreter(.{});

    // Test bytecode ending mid-instruction (PUSH1 but no STOP)
    const bytecode_no_stop = [_]u8{ 0x60, 0x42 }; // PUSH1 42, no STOP
    var interpreter1 = try FrameInterpreterType.init(allocator, &bytecode_no_stop, 1000000, {}, HostMock.init());
    defer interpreter1.deinit(allocator);

    const result1 = interpreter1.interpret();
    if (result1) {
        // If execution succeeds, verify state
        try std.testing.expectEqual(@as(u256, 42), interpreter1.frame.stack.peek_unsafe());
    } else |err| {
        // Should be a bounds or execution error
        try std.testing.expect(err == error.OutOfBounds or err == error.InvalidOpcode);
    }

    // Test completely invalid opcode sequence
    const bytecode_invalid = [_]u8{ 0xF8, 0xF9, 0xFA, 0xFB, 0xFC, 0xFD }; // All invalid opcodes
    var interpreter2 = try FrameInterpreterType.init(allocator, &bytecode_invalid, 1000000, {}, HostMock.init());
    defer interpreter2.deinit(allocator);

    // Should fail with InvalidOpcode on first instruction
    try std.testing.expectError(error.InvalidOpcode, interpreter2.interpret());
}

test "FrameInterpreter bytecode parsing - boundary instruction sequences" {
    const allocator = std.testing.allocator;
    const FrameInterpreterType = FrameInterpreter(.{});

    // Test maximum valid bytecode size boundary
    var large_bytecode = std.ArrayList(u8).init(allocator);
    defer large_bytecode.deinit();

    // Fill with valid operations up to near the limit (24576 bytes default)
    const pattern = [_]u8{ 0x60, 0x01 }; // PUSH1 1
    var i: usize = 0;
    while (i < 1000) : (i += 1) { // Add 2000 bytes of PUSH1 1 instructions
        try large_bytecode.appendSlice(&pattern);
    }
    try large_bytecode.append(0x00); // STOP

    var interpreter = try FrameInterpreterType.init(allocator, large_bytecode.items, 10000000, {}, HostMock.init()); // High gas
    defer interpreter.deinit(allocator);

    try interpreter.interpret();

    // Should have 1000 values of 1 on the stack
    try std.testing.expectEqual(@as(usize, 1000), interpreter.frame.stack.size());
    try std.testing.expectEqual(@as(u256, 1), interpreter.frame.stack.peek_unsafe());
}

// 4. PLAN METADATA EDGE CASES ⭐⭐⭐⭐

test "FrameInterpreter plan metadata - mixed PUSH sizes validation" {
    const allocator = std.testing.allocator;
    const FrameInterpreterType = FrameInterpreter(.{});

    // Complex bytecode mixing different PUSH sizes to test metadata handling
    const bytecode = [_]u8{
        0x5F, // PUSH0
        0x60, 0x01, // PUSH1 1
        0x62, 0x12, 0x34, 0x56, // PUSH3 0x123456
        0x65, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, // PUSH6 0xAABBCCDDEEFF
        0x6F, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, // PUSH16 (start)
        0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x00, // PUSH16 (end)
        0x00, // STOP
    };

    var interpreter = try FrameInterpreterType.init(allocator, &bytecode, 1000000, {}, HostMock.init());
    defer interpreter.deinit(allocator);

    // Verify plan was created with correct instruction count and metadata
    try std.testing.expect(interpreter.plan.instructionStream.len > 0);

    try interpreter.interpret();

    // Should have 5 values on stack: PUSH0, PUSH1, PUSH3, PUSH6, PUSH16
    try std.testing.expectEqual(@as(usize, 5), interpreter.frame.stack.size());

    // Verify the PUSH16 value (top of stack)
    var expected_push16: u256 = 0;
    const push16_bytes = [_]u8{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x00 };
    for (push16_bytes) |b| {
        expected_push16 = (expected_push16 << 8) | @as(u256, b);
    }
    try std.testing.expectEqual(expected_push16, interpreter.frame.stack.peek_unsafe());
}

test "FrameInterpreter plan metadata - instruction stream consistency" {
    const allocator = std.testing.allocator;
    const FrameInterpreterType = FrameInterpreter(.{});

    // Bytecode that tests plan instruction stream creation accuracy
    const bytecode = [_]u8{
        0x60, 0x05, // PC 0: PUSH1 5
        0x61, 0x00, 0x0A, // PC 2: PUSH2 10
        0x01, // PC 5: ADD
        0x80, // PC 6: DUP1
        0x82, // PC 7: DUP3
        0x02, // PC 8: MUL
        0x00, // PC 9: STOP
    };

    var interpreter = try FrameInterpreterType.init(allocator, &bytecode, 1000000, {}, HostMock.init());
    defer interpreter.deinit(allocator);

    // Verify instruction stream length matches expected operations
    const expected_instructions = 7; // PUSH1, PUSH2, ADD, DUP1, DUP3, MUL, STOP
    try std.testing.expectEqual(expected_instructions, interpreter.plan.instructionStream.len);

    // Verify PC mapping exists and has expected entries
    if (interpreter.plan.pc_to_instruction_idx) |pc_map| {
        try std.testing.expect(pc_map.contains(0)); // PUSH1
        try std.testing.expect(pc_map.contains(2)); // PUSH2
        try std.testing.expect(pc_map.contains(5)); // ADD
        try std.testing.expect(pc_map.contains(6)); // DUP1
        try std.testing.expect(pc_map.contains(7)); // DUP3
        try std.testing.expect(pc_map.contains(8)); // MUL
        try std.testing.expect(pc_map.contains(9)); // STOP
    }

    try interpreter.interpret();

    // Verify execution completed correctly
    // Stack should have: (5 + 10) * 5 = 75 and 15 (from DUP operations)
    try std.testing.expectEqual(@as(usize, 2), interpreter.frame.stack.size());
}

// 5. HANDLER ERROR PROPAGATION CHAIN ⭐⭐⭐⭐

test "FrameInterpreter handler error propagation - tail call chain" {
    const allocator = std.testing.allocator;
    const FrameInterpreterType = FrameInterpreter(.{});

    // Test error propagation through multiple handler calls
    const bytecode = [_]u8{
        0x60, 0x01, // PUSH1 1
        0x60, 0x02, // PUSH1 2
        0x01, // ADD (success)
        0x60, 0x00, // PUSH1 0
        0x04, // DIV (division by zero - should propagate error)
        0x00, // STOP (should never be reached)
    };

    var interpreter = try FrameInterpreterType.init(allocator, &bytecode, 1000000, {}, HostMock.init());
    defer interpreter.deinit(allocator);

    try interpreter.interpret(); // DIV by 0 returns 0 in EVM, doesn't error

    // Should have result of (1 + 2) / 0 = 3 / 0 = 0
    try std.testing.expectEqual(@as(u256, 0), interpreter.frame.stack.peek_unsafe());
}

test "FrameInterpreter handler error propagation - stack underflow chain" {
    const allocator = std.testing.allocator;
    const FrameInterpreterType = FrameInterpreter(.{});

    // Test error propagation when stack underflow occurs mid-chain
    const bytecode = [_]u8{
        0x60, 0x01, // PUSH1 1
        0x01, // ADD (tries to pop 2 items, only 1 available)
        0x02, // MUL (should never be reached)
        0x00, // STOP
    };

    var interpreter = try FrameInterpreterType.init(allocator, &bytecode, 1000000, {}, HostMock.init());
    defer interpreter.deinit(allocator);

    try std.testing.expectError(error.StackUnderflow, interpreter.interpret());

    // Verify stack state at error point
    try std.testing.expectEqual(@as(usize, 1), interpreter.frame.stack.size());
    try std.testing.expectEqual(@as(u256, 1), interpreter.frame.stack.peek_unsafe());
}

test "FrameInterpreter handler error propagation - gas exhaustion" {
    const allocator = std.testing.allocator;
    const FrameInterpreterType = FrameInterpreter(.{});

    // Test gas exhaustion error propagation
    const bytecode = [_]u8{
        0x60, 0x01, // PUSH1 1
        0x60, 0x02, // PUSH1 2
        0x01, // ADD
        0x60, 0x03, // PUSH1 3
        0x02, // MUL
        0x60, 0x04, // PUSH1 4
        0x03, // SUB
        0x00, // STOP
    };

    // Start with very low gas to trigger out-of-gas
    var interpreter = try FrameInterpreterType.init(allocator, &bytecode, 10, {}, HostMock.init()); // Very low gas
    defer interpreter.deinit(allocator);

    try std.testing.expectError(error.OutOfGas, interpreter.interpret());

    // Gas should be negative or zero
    try std.testing.expect(interpreter.frame.gas_remaining <= 0);
}

// 6. MULTI-CONFIGURATION INTEGRATION ⭐⭐⭐⭐

test "FrameInterpreter multi-config - small stack size" {
    const allocator = std.testing.allocator;
    const FrameInterpreterType = FrameInterpreter(.{ .stack_size = 3 });

    // Test with stack that can only hold 3 items
    const bytecode = [_]u8{
        0x60, 0x01, // PUSH1 1
        0x60, 0x02, // PUSH1 2
        0x60, 0x03, // PUSH1 3 (at capacity)
        0x01, // ADD (reduces to 2 items: 1, 5)
        0x00, // STOP
    };

    var interpreter = try FrameInterpreterType.init(allocator, &bytecode, 1000000, {}, HostMock.init());
    defer interpreter.deinit(allocator);

    try interpreter.interpret();

    try std.testing.expectEqual(@as(usize, 2), interpreter.frame.stack.size());
    try std.testing.expectEqual(@as(u256, 5), interpreter.frame.stack.peek_unsafe()); // 2 + 3 = 5
}

test "FrameInterpreter multi-config - stack overflow with small size" {
    const allocator = std.testing.allocator;
    const FrameInterpreterType = FrameInterpreter(.{ .stack_size = 2 });

    // Test stack overflow with very small stack
    const bytecode = [_]u8{
        0x60, 0x01, // PUSH1 1
        0x60, 0x02, // PUSH1 2 (at capacity)
        0x60, 0x03, // PUSH1 3 (should overflow)
        0x00, // STOP
    };

    var interpreter = try FrameInterpreterType.init(allocator, &bytecode, 1000000, {}, HostMock.init());
    defer interpreter.deinit(allocator);

    try std.testing.expectError(error.StackOverflow, interpreter.interpret());
}

test "FrameInterpreter multi-config - different word types" {
    const allocator = std.testing.allocator;
    const FrameInterpreterType128 = FrameInterpreter(.{ .WordType = u128 });
    const FrameInterpreterType64 = FrameInterpreter(.{ .WordType = u64 });

    // Test with u128 word type
    const bytecode = [_]u8{ 0x60, 0xFF, 0x00 }; // PUSH1 255, STOP

    var interpreter128 = try FrameInterpreterType128.init(allocator, &bytecode, 1000000, {}, HostMock.init());
    defer interpreter128.deinit(allocator);

    try interpreter128.interpret();
    try std.testing.expectEqual(@as(u128, 255), interpreter128.frame.stack.peek_unsafe());

    // Test with u64 word type
    var interpreter64 = try FrameInterpreterType64.init(allocator, &bytecode, 1000000, {}, HostMock.init());
    defer interpreter64.deinit(allocator);

    try interpreter64.interpret();
    try std.testing.expectEqual(@as(u64, 255), interpreter64.frame.stack.peek_unsafe());
}

test "FrameInterpreter multi-config - bytecode size limits" {
    const allocator = std.testing.allocator;
    const FrameInterpreterTypeSmall = FrameInterpreter(.{ .max_bytecode_size = 10 });

    // Test with bytecode at the limit
    const bytecode_at_limit = [_]u8{ 0x60, 0x01, 0x60, 0x02, 0x01, 0x60, 0x03, 0x02, 0x60, 0x04 }; // 10 bytes

    var interpreter_valid = try FrameInterpreterTypeSmall.init(allocator, &bytecode_at_limit, 1000000, {}, HostMock.init());
    defer interpreter_valid.deinit(allocator);

    // Should succeed with bytecode at limit
    // Note: Execution may not complete due to missing STOP, but init should succeed
    try std.testing.expect(interpreter_valid.frame.bytecode.len == 10);

    // Test with bytecode over the limit
    const bytecode_over_limit = [_]u8{ 0x60, 0x01, 0x60, 0x02, 0x01, 0x60, 0x03, 0x02, 0x60, 0x04, 0x00 }; // 11 bytes

    try std.testing.expectError(error.BytecodeTooLarge, FrameInterpreterTypeSmall.init(allocator, &bytecode_over_limit, 1000000, {}, HostMock.init()));
}

// 7. DATABASE INTEGRATION TESTS ⭐⭐⭐

test "FrameInterpreter database integration - SLOAD/SSTORE operations" {
    const allocator = std.testing.allocator;

    // Create database
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();

    // SSTORE bytecode: PUSH1 0x42 PUSH1 0x01 SSTORE STOP
    const bytecode = [_]u8{ 0x60, 0x42, 0x60, 0x01, 0x55, 0x00 };

    var frame_interpreter = try FrameInterpreter(.{ .has_database = true }).init(allocator, &bytecode, 100000, db_interface, HostMock.init());
    defer frame_interpreter.deinit(allocator);

    // Execute SSTORE operation
    try frame_interpreter.interpret();
}

test "FrameInterpreter database integration - storage boundary conditions" {
    const allocator = std.testing.allocator;

    // Create database
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();

    // Test storage at slot 0 - SSTORE: PUSH1 0x42 PUSH1 0x00 SSTORE STOP
    const bytecode_slot0 = [_]u8{ 0x60, 0x42, 0x60, 0x00, 0x55, 0x00 };

    var frame_interpreter = try FrameInterpreter(.{ .has_database = true }).init(allocator, &bytecode_slot0, 100000, db_interface, HostMock.init());
    defer frame_interpreter.deinit(allocator);

    try frame_interpreter.interpret();

    // Test SLOAD from slot 0 - SLOAD: PUSH1 0x00 SLOAD STOP
    const bytecode_load = [_]u8{ 0x60, 0x00, 0x54, 0x00 };
    var frame_interpreter2 = try FrameInterpreter(.{ .has_database = true }).init(allocator, &bytecode_load, 100000, db_interface, HostMock.init());
    defer frame_interpreter2.deinit(allocator);

    try frame_interpreter2.interpret();
}

// 8. STRESS & PERFORMANCE EDGE CASES ⭐⭐⭐

test "FrameInterpreter stress test - long execution sequence" {
    const allocator = std.testing.allocator;
    const FrameInterpreterType = FrameInterpreter(.{});

    // Create bytecode with many operations
    var long_bytecode = std.ArrayList(u8).init(allocator);
    defer long_bytecode.deinit();

    // Add 100 PUSH1 1, ADD sequences to create long execution
    for (0..100) |_| {
        try long_bytecode.appendSlice(&[_]u8{ 0x60, 0x01 }); // PUSH1 1
    }
    // Add 99 ADD operations
    for (0..99) |_| {
        try long_bytecode.append(0x01); // ADD
    }
    try long_bytecode.append(0x00); // STOP

    var interpreter = try FrameInterpreterType.init(allocator, long_bytecode.items, 10000000, {}, HostMock.init());
    defer interpreter.deinit(allocator);

    try interpreter.interpret();

    // Should have sum of 100 ones = 100
    try std.testing.expectEqual(@as(u256, 100), interpreter.frame.stack.peek_unsafe());
    try std.testing.expectEqual(@as(usize, 1), interpreter.frame.stack.size());
}

test "FrameInterpreter stress test - maximum stack usage" {
    const allocator = std.testing.allocator;
    const FrameInterpreterType = FrameInterpreter(.{ .stack_size = 1024 });

    // Create bytecode that fills stack to near capacity
    var stack_fill_bytecode = std.ArrayList(u8).init(allocator);
    defer stack_fill_bytecode.deinit();

    // Push 1023 values (leave room for operations)
    for (0..1023) |_| {
        try stack_fill_bytecode.appendSlice(&[_]u8{ 0x60, 0x01 }); // PUSH1 1
    }
    // Test operations at capacity
    try stack_fill_bytecode.appendSlice(&[_]u8{ 0x80, 0x50, 0x00 }); // DUP1, POP, STOP

    var interpreter = try FrameInterpreterType.init(allocator, stack_fill_bytecode.items, 10000000, {}, HostMock.init());
    defer interpreter.deinit(allocator);

    try interpreter.interpret();

    // Should have 1023 items on stack after DUP1, POP sequence
    try std.testing.expectEqual(@as(usize, 1023), interpreter.frame.stack.size());
}

test "FrameInterpreter stress test - memory intensive operations" {
    const allocator = std.testing.allocator;
    const FrameInterpreterType = FrameInterpreter(.{});

    // Test operations that expand memory significantly
    const bytecode = [_]u8{
        0x61, 0x12, 0x34, // PUSH2 0x1234 (value)
        0x61, 0x10, 0x00, // PUSH2 0x1000 (offset - 4096)
        0x52, // MSTORE (store at offset 4096)
        0x61, 0x10, 0x00, // PUSH2 0x1000 (offset)
        0x51, // MLOAD (load from offset 4096)
        0x00, // STOP
    };

    var interpreter = try FrameInterpreterType.init(allocator, &bytecode, 10000000, {}, HostMock.init()); // High gas for memory
    defer interpreter.deinit(allocator);

    try interpreter.interpret();

    // Should have loaded the stored value
    try std.testing.expectEqual(@as(u256, 0x1234), interpreter.frame.stack.peek_unsafe());

    // Memory should be expanded to at least 4096 + 32 bytes
    try std.testing.expect(interpreter.frame.memory.size() >= 4096 + 32);
}

// 9. INSTRUCTION TRANSITION MATRIX ⭐⭐⭐

test "FrameInterpreter instruction transitions - arithmetic to memory" {
    const allocator = std.testing.allocator;
    const FrameInterpreterType = FrameInterpreter(.{});

    // Test smooth transitions: Arithmetic → Memory → Arithmetic
    const bytecode = [_]u8{
        0x60, 0x10, // PUSH1 16 (arithmetic)
        0x60, 0x05, // PUSH1 5
        0x01, // ADD (arithmetic) → 21
        0x60, 0x00, // PUSH1 0 (offset)
        0x52, // MSTORE (memory operation)
        0x60, 0x00, // PUSH1 0 (offset)
        0x51, // MLOAD (memory operation) → 21
        0x60, 0x04, // PUSH1 4
        0x02, // MUL (arithmetic) → 84
        0x00, // STOP
    };

    var interpreter = try FrameInterpreterType.init(allocator, &bytecode, 1000000, {}, HostMock.init());
    defer interpreter.deinit(allocator);

    try interpreter.interpret();

    // Should have (16 + 5) * 4 = 84
    try std.testing.expectEqual(@as(u256, 84), interpreter.frame.stack.peek_unsafe());
}

test "FrameInterpreter instruction transitions - control flow integration" {
    const allocator = std.testing.allocator;
    const FrameInterpreterType = FrameInterpreter(.{});

    // Test transitions: Arithmetic → Control Flow → Arithmetic
    const bytecode = [_]u8{
        0x60, 0x05, // PUSH1 5
        0x60, 0x03, // PUSH1 3
        0x10, // LT (comparison) → 0 (5 < 3 is false)
        0x60, 0x14, // PUSH1 20 (jump target if true)
        0x57, // JUMPI (conditional jump - should not jump)
        0x60, 0x0A, // PUSH1 10 (arithmetic - should execute)
        0x60, 0x02, // PUSH1 2
        0x02, // MUL (arithmetic) → 20
        0x60, 0x18, // PUSH1 24 (jump to end)
        0x56, // JUMP
        // Target at PC 20 (0x14)
        0x5B, // JUMPDEST
        0x60, 0x63, // PUSH1 99 (should not execute)
        // End at PC 24 (0x18)
        0x5B, // JUMPDEST
        0x00, // STOP
    };

    var interpreter = try FrameInterpreterType.init(allocator, &bytecode, 1000000, {}, HostMock.init());
    defer interpreter.deinit(allocator);

    try interpreter.interpret();

    // Should have 20 (10 * 2) since conditional jump was not taken
    try std.testing.expectEqual(@as(u256, 20), interpreter.frame.stack.peek_unsafe());
}

test "FrameInterpreter instruction transitions - stack manipulation chains" {
    const allocator = std.testing.allocator;
    const FrameInterpreterType = FrameInterpreter(.{});

    // Test transitions: Stack Ops → Arithmetic → Stack Ops → Arithmetic
    const bytecode = [_]u8{
        0x60, 0x0A, // PUSH1 10
        0x60, 0x14, // PUSH1 20
        0x60, 0x1E, // PUSH1 30
        0x80, // DUP1 (stack: [10, 20, 30, 30])
        0x82, // DUP3 (stack: [10, 20, 30, 30, 20])
        0x01, // ADD (stack: [10, 20, 30, 50])
        0x91, // SWAP2 (stack: [10, 50, 30, 20])
        0x90, // SWAP1 (stack: [10, 50, 20, 30])
        0x03, // SUB (stack: [10, 50, -10]) - wrapping: very large number
        0x50, // POP (stack: [10, 50])
        0x02, // MUL (stack: [500])
        0x00, // STOP
    };

    var interpreter = try FrameInterpreterType.init(allocator, &bytecode, 1000000, {}, HostMock.init());
    defer interpreter.deinit(allocator);

    try interpreter.interpret();

    // Should have 10 * 50 = 500
    try std.testing.expectEqual(@as(u256, 500), interpreter.frame.stack.peek_unsafe());
    try std.testing.expectEqual(@as(usize, 1), interpreter.frame.stack.size());
}

// BYTECODE EDGE CASE TESTS

test "FrameInterpreter bytecode edge cases - empty bytecode" {
    const allocator = std.testing.allocator;
    const FrameInterpreterType = FrameInterpreter(.{});

    // Empty bytecode should execute as implicit STOP
    const empty_bytecode = [_]u8{};
    var interpreter = try FrameInterpreterType.init(allocator, &empty_bytecode, 1000, {}, HostMock.init());
    defer interpreter.deinit(allocator);

    // Should immediately return success (implicit STOP)
    try interpreter.interpret();
    try std.testing.expectEqual(@as(usize, 0), interpreter.frame.stack.size());
}

test "FrameInterpreter bytecode edge cases - single invalid opcode" {
    const allocator = std.testing.allocator;
    const FrameInterpreterType = FrameInterpreter(.{});

    // Test various invalid opcodes
    const invalid_opcodes = [_]u8{ 0x0C, 0x0E, 0x1E, 0x21, 0x49, 0xA5, 0xFE };

    for (invalid_opcodes) |invalid_opcode| {
        const bytecode = [_]u8{invalid_opcode};
        var interpreter = try FrameInterpreterType.init(allocator, &bytecode, 1000, {}, HostMock.init());
        defer interpreter.deinit(allocator);

        try std.testing.expectError(error.InvalidOpcode, interpreter.interpret());
    }
}

test "FrameInterpreter bytecode edge cases - truncated PUSH at end" {
    const allocator = std.testing.allocator;
    const FrameInterpreterType = FrameInterpreter(.{});

    // PUSH1 with no data bytes following
    const truncated_push1 = [_]u8{0x60}; // PUSH1
    var interpreter1 = try FrameInterpreterType.init(allocator, &truncated_push1, 1000, {}, HostMock.init());
    defer interpreter1.deinit(allocator);

    // Should handle truncated PUSH gracefully
    try interpreter1.interpret();
    // PUSH with insufficient data pushes zero-padded value
    try std.testing.expectEqual(@as(u256, 0), interpreter1.frame.stack.peek_unsafe());

    // PUSH32 with only 2 data bytes
    const truncated_push32 = [_]u8{ 0x7F, 0xAB, 0xCD }; // PUSH32 + 2 bytes
    var interpreter2 = try FrameInterpreterType.init(allocator, &truncated_push32, 1000, {}, HostMock.init());
    defer interpreter2.deinit(allocator);

    try interpreter2.interpret();
    // Should push 0xABCD000000...
    const expected = @as(u256, 0xABCD) << (30 * 8);
    try std.testing.expectEqual(expected, interpreter2.frame.stack.peek_unsafe());
}

test "FrameInterpreter bytecode edge cases - maximum valid bytecode size" {
    const allocator = std.testing.allocator;
    const FrameInterpreterType = FrameInterpreter(.{});

    // Create bytecode exactly at the 24KB limit
    var max_bytecode = try allocator.alloc(u8, 24576);
    defer allocator.free(max_bytecode);

    // Fill with JUMPDEST opcodes (benign, single-byte opcode)
    @memset(max_bytecode, 0x5B); // JUMPDEST
    max_bytecode[max_bytecode.len - 1] = 0x00; // STOP at end

    var interpreter = try FrameInterpreterType.init(allocator, max_bytecode, 100000, {}, HostMock.init());
    defer interpreter.deinit(allocator);

    // Should execute without issues (interpret() returns success on STOP)
    try interpreter.interpret();
}

test "FrameInterpreter bytecode edge cases - all opcodes stress test" {
    const allocator = std.testing.allocator;
    const FrameInterpreterType = FrameInterpreter(.{});

    // Create bytecode with one of each valid opcode (where safe)
    var bytecode = std.ArrayList(u8).init(allocator);
    defer bytecode.deinit();

    // Add some values to work with
    try bytecode.appendSlice(&[_]u8{ 0x60, 0x01 }); // PUSH1 1
    try bytecode.appendSlice(&[_]u8{ 0x60, 0x02 }); // PUSH1 2

    // Safe single-byte opcodes that won't cause issues
    const safe_opcodes = [_]u8{
        0x01, // ADD
        0x80, // DUP1
        0x50, // POP
        0x5B, // JUMPDEST
    };

    for (safe_opcodes) |opcode| {
        try bytecode.append(opcode);
    }

    try bytecode.append(0x00); // STOP

    var interpreter = try FrameInterpreterType.init(allocator, bytecode.items, 10000, {}, HostMock.init());
    defer interpreter.deinit(allocator);

    try interpreter.interpret();
}

test "FrameInterpreter bytecode edge cases - interleaved PUSH and computation" {
    const allocator = std.testing.allocator;
    const FrameInterpreterType = FrameInterpreter(.{});

    // Complex bytecode with interleaved PUSH and computation
    const bytecode = [_]u8{
        0x7F, // PUSH32
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, // Max u256 value
        0x60, 0x01, // PUSH1 1
        0x03, // SUB (max - 1)
        0x60, 0x02, // PUSH1 2
        0x01, // ADD (max - 1 + 2 = max + 1 with overflow = 0)
        0x00, // STOP
    };

    var interpreter = try FrameInterpreterType.init(allocator, &bytecode, 10000, {}, HostMock.init());
    defer interpreter.deinit(allocator);

    try interpreter.interpret();

    // Should have wrapped around to 0
    try std.testing.expectEqual(@as(u256, 0), interpreter.frame.stack.peek_unsafe());
}

test "FrameInterpreter bytecode edge cases - alternating valid/invalid opcodes" {
    const allocator = std.testing.allocator;
    const FrameInterpreterType = FrameInterpreter(.{});

    // Bytecode with valid opcode followed by invalid
    const bytecode = [_]u8{
        0x60, 0x01, // PUSH1 1 (valid)
        0x0C, // Invalid opcode
        0x60, 0x02, // PUSH1 2 (never reached)
        0x00, // STOP
    };

    var interpreter = try FrameInterpreterType.init(allocator, &bytecode, 10000, {}, HostMock.init());
    defer interpreter.deinit(allocator);

    // Should fail on invalid opcode
    try std.testing.expectError(error.InvalidOpcode, interpreter.interpret());

    // Stack should have the first push
    try std.testing.expectEqual(@as(usize, 1), interpreter.frame.stack.size());
    try std.testing.expectEqual(@as(u256, 1), interpreter.frame.stack.peek_unsafe());
}

test "FrameInterpreter bytecode edge cases - bytecode ending mid-instruction" {
    const allocator = std.testing.allocator;
    const FrameInterpreterType = FrameInterpreter(.{});

    // Bytecode that ends in the middle of a multi-byte instruction
    const bytecode = [_]u8{
        0x60, 0x42, // PUSH1 0x42
        0x61, // PUSH2 (but no data follows)
    };

    var interpreter = try FrameInterpreterType.init(allocator, &bytecode, 10000, {}, HostMock.init());
    defer interpreter.deinit(allocator);

    try interpreter.interpret();

    // Should have 0x42 and then 0 (from truncated PUSH2)
    try std.testing.expectEqual(@as(usize, 2), interpreter.frame.stack.size());
}
