const std = @import("std");
const log = @import("../log.zig");
const primitives = @import("voltaire");

/// Lifecycle event handlers for the Tracer.
/// These handle all EVM lifecycle events like frame starts, call operations, arena management, etc.
pub inline fn Handlers(comptime TracerType: type) type {
    return struct {
        const builtin = @import("builtin");

        pub inline fn onFrameStart(self: *TracerType, code_len: usize, gas: u64, depth: u16) void {
            if (!self.config.enabled) return;
            if (self.config.enable_debug_logging) log.debug("[EVM] Frame execution started: code_len={}, gas={}, depth={}", .{ code_len, gas, depth });
        }

        pub inline fn onFrameComplete(self: *TracerType, gas_left: u64, output_len: usize) void {
            if (!self.config.enabled) return;
            if (self.config.enable_debug_logging) log.debug("[EVM] Frame execution completed: gas_left={}, output_len={}", .{ gas_left, output_len });
        }

        pub inline fn onAccountDelegation(self: *TracerType, account: []const u8, delegated: []const u8) void {
            if (!self.config.enabled) return;
            if (self.config.enable_debug_logging) log.debug("[EVM] Account {x} has delegation to {x}", .{ account, delegated });
        }

        pub inline fn onEmptyAccountAccess(self: *TracerType) void {
            if (!self.config.enabled) return;
            if (self.config.enable_debug_logging) log.debug("[EVM] Empty account access", .{});
        }

        /// Called when arena allocator is initialized
        pub inline fn onArenaInit(self: *TracerType, initial_capacity: usize, max_capacity: usize, growth_factor: u32) void {
            if (!self.config.enabled) return;
            if (self.config.enable_debug_logging) log.debug("[ARENA] Initialized: initial={d}, max={d}, growth={d}%", .{ initial_capacity, max_capacity, growth_factor });
        }

        /// Event: Call operation started
        pub inline fn onCallStart(self: *TracerType, call_type: []const u8, gas: i64, to: anytype, value: u256) void {
            if (!self.config.enabled) return;
            if (self.config.enable_debug_logging) log.debug("[TRACER] Call started: type={s} gas={d} value={d}", .{ call_type, gas, value });
            _ = to;
        }

        /// Event: EVM initialization started
        pub inline fn onEvmInit(self: *TracerType, gas_price: u256, origin: anytype, hardfork: []const u8) void {
            if (!self.config.enabled) return;
            if (self.config.enable_debug_logging) log.debug("[TRACER] EVM init: gas_price={d} hardfork={s}", .{ gas_price, hardfork });
            _ = origin;
        }

        /// Called when arena is reset
        pub inline fn onArenaReset(self: *TracerType, mode: []const u8, capacity_before: usize, capacity_after: usize) void {
            if (!self.config.enabled) return;
            if (self.config.enable_debug_logging) log.debug("[ARENA] Reset ({s}): capacity {d} -> {d}", .{ mode, capacity_before, capacity_after });
        }

        /// Event: Beacon root update processing
        pub inline fn onBeaconRootUpdate(self: *TracerType, success: bool, error_val: ?anyerror) void {
            if (!self.config.enabled) return;
            if (self.config.enable_debug_logging) {
                if (error_val) |e| {
                    log.debug("[TRACER] Beacon root update failed: {}", .{e});
                } else {
                    log.debug("[TRACER] Beacon root update: success={}", .{success});
                }
            }
        }

        /// Event: Call operation completed
        pub inline fn onCallComplete(self: *TracerType, success: bool, gas_left: i64, output_len: usize) void {
            if (!self.config.enabled) return;
            if (self.config.enable_debug_logging) log.debug("[TRACER] Call complete: success={} gas_left={d} output_len={d}", .{ success, gas_left, output_len });
        }

        /// Event: Preflight check for call
        pub inline fn onCallPreflight(self: *TracerType, call_type: []const u8, result: []const u8) void {
            if (!self.config.enabled) return;
            if (self.config.enable_debug_logging) log.debug("[TRACER] Call preflight: type={s} result={s}", .{ call_type, result });
        }

        /// Event: Historical block hash update processing
        pub inline fn onHistoricalBlockHashUpdate(self: *TracerType, success: bool, error_val: ?anyerror) void {
            if (!self.config.enabled) return;
            if (self.config.enable_debug_logging) {
                if (error_val) |e| {
                    log.debug("[TRACER] Historical block hash update failed: {}", .{e});
                } else {
                    log.debug("[TRACER] Historical block hash update: success={}", .{success});
                }
            }
        }

        /// Event: Code retrieval
        pub inline fn onCodeRetrieval(self: *TracerType, address: anytype, code_len: usize, is_empty: bool) void {
            if (!self.config.enabled) return;
            if (self.config.enable_debug_logging) log.debug("[TRACER] Code retrieval: len={d} empty={}", .{ code_len, is_empty });
            _ = address;
        }

        /// Event: Validator deposits processing
        pub inline fn onValidatorDeposits(self: *TracerType, success: bool, error_val: ?anyerror) void {
            if (!self.config.enabled) return;
            if (self.config.enable_debug_logging) {
                if (error_val) |e| {
                    log.debug("[TRACER] Validator deposits failed: {}", .{e});
                } else {
                    log.debug("[TRACER] Validator deposits: success={}", .{success});
                }
            }
        }

        /// Called when an allocation is made
        pub inline fn onArenaAlloc(self: *TracerType, size: usize, alignment: usize, current_capacity: usize) void {
            _ = self;
            _ = size;
            _ = alignment;
            _ = current_capacity;
            // Allocation logging disabled - too noisy
        }

        /// Event: Frame bytecode initialization
        pub inline fn onFrameBytecodeInit(self: *TracerType, bytecode_len: usize, success: bool, error_val: ?anyerror) void {
            if (!self.config.enabled) return;
            if (self.config.enable_debug_logging) {
                if (error_val) |e| {
                    log.debug("[TRACER] Frame bytecode init failed: len={d} error={}", .{ bytecode_len, e });
                } else {
                    log.debug("[TRACER] Frame bytecode init: len={d} success={}", .{ bytecode_len, success });
                }
            }
        }

        /// Event: Validator withdrawals processing
        pub inline fn onValidatorWithdrawals(self: *TracerType, success: bool, error_val: ?anyerror) void {
            if (!self.config.enabled) return;
            if (self.config.enable_debug_logging) {
                if (error_val) |e| {
                    log.debug("[TRACER] Validator withdrawals failed: {}", .{e});
                } else {
                    log.debug("[TRACER] Validator withdrawals: success={}", .{success});
                }
            }
        }

        /// Called when arena grows to accommodate new allocations
        pub inline fn onArenaGrow(self: *TracerType, old_capacity: usize, new_capacity: usize, requested_size: usize) void {
            if (!self.config.enabled) return;
            if (self.config.enable_debug_logging) {
                log.debug("[ARENA] Growing: {d} -> {d} bytes (requested={d})", .{ old_capacity, new_capacity, requested_size });
            }
        }

        /// Called when allocation fails
        pub inline fn onArenaAllocFailed(self: *TracerType, size: usize, current_capacity: usize, max_capacity: usize) void {
            if (!self.config.enabled) return;
            if (comptime (builtin.mode == .Debug or builtin.mode == .ReleaseSafe)) {
                log.warn("[ARENA] Allocation failed: size={d}, current={d}, max={d}", .{ size, current_capacity, max_capacity });
            }
        }

        pub inline fn onBytecodeAnalysisStart(self: *TracerType, code_len: usize) void {
            if (!self.config.enabled) return;
            if (self.config.enable_debug_logging) log.debug("[TRACER] Bytecode analysis start: len={d}", .{code_len});
        }

        pub inline fn onBytecodeAnalysisComplete(self: *TracerType, validated_up_to: usize, opcode_count: usize, jumpdest_count: usize) void {
            if (!self.config.enabled) return;
            if (self.config.enable_debug_logging) log.debug("[TRACER] Bytecode analysis complete: validated={d} opcodes={d} jumpdests={d}", .{ validated_up_to, opcode_count, jumpdest_count });
        }

        /// Called when an invalid opcode is found during analysis
        pub inline fn onInvalidOpcode(self: *TracerType, pc: usize, opcode: u8) void {
            if (!self.config.enabled) return;
            if (self.config.enable_debug_logging) log.debug("[TRACER] Invalid opcode: pc={d} opcode=0x{x:0>2}", .{ pc, opcode });
        }

        /// Called when a JUMPDEST is found during analysis
        pub inline fn onJumpdestFound(self: *TracerType, pc: usize, count: usize) void {
            if (!self.config.enabled) return;
            if (self.config.enable_debug_logging) log.debug("[TRACER] JUMPDEST found: pc={d} total={d}", .{ pc, count });
        }

        /// Called when dispatch schedule build starts
        pub inline fn onScheduleBuildStart(self: *TracerType, bytecode_len: usize) void {
            if (!self.config.enabled) return;
            if (self.config.enable_debug_logging) log.debug("[TRACER] Schedule build start: bytecode_len={d}", .{bytecode_len});
        }

        /// Called when a fusion optimization is detected
        pub inline fn onFusionDetected(self: *TracerType, pc: usize, fusion_type: []const u8, instruction_count: usize) void {
            if (!self.config.enabled) return;
            if (self.config.enable_debug_logging) log.debug("[TRACER] Fusion detected: pc={d} type={s} count={d}", .{ pc, fusion_type, instruction_count });
        }

        /// Called when an invalid static jump is detected
        pub inline fn onInvalidStaticJump(self: *TracerType, jump_pc: usize, target_pc: usize) void {
            if (!self.config.enabled) return;
            if (self.config.enable_debug_logging) log.debug("[TRACER] Invalid static jump: from={d} to={d}", .{ jump_pc, target_pc });
        }

        /// Called when a static jump is resolved
        pub inline fn onStaticJumpResolved(self: *TracerType, jump_pc: usize, target_pc: usize) void {
            if (!self.config.enabled) return;
            if (self.config.enable_debug_logging) log.debug("[TRACER] Static jump resolved: from={d} to={d}", .{ jump_pc, target_pc });
        }

        /// Called when a truncated PUSH instruction is detected
        pub inline fn onTruncatedPush(self: *TracerType, pc: usize, push_size: u8, available: usize) void {
            if (!self.config.enabled) return;
            if (self.config.enable_debug_logging) log.debug("[TRACER] Truncated PUSH: pc={d} size={d} available={d}", .{ pc, push_size, available });
        }

        /// Called when dispatch schedule build completes
        pub inline fn onScheduleBuildComplete(self: *TracerType, item_count: usize, fusion_count: usize) void {
            if (!self.config.enabled) return;
            if (self.config.enable_debug_logging) log.debug("[TRACER] Schedule build complete: items={d} fusions={d}", .{ item_count, fusion_count });
        }

        /// Called when a jump table is created
        pub inline fn onJumpTableCreated(self: *TracerType, jumpdest_count: usize) void {
            if (!self.config.enabled) return;
            if (self.config.enable_debug_logging) log.debug("[TRACER] Jump table created: jumpdest_count={d}", .{jumpdest_count});
        }
    };
}
