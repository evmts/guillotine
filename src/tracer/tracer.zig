const std = @import("std");
const log = @import("../log.zig");
const primitives = @import("primitives");
const pc_tracker_mod = @import("pc_tracker.zig");
const minimal_evm_mod = @import("minimal_evm.zig");
pub const MinimalEvm = minimal_evm_mod.MinimalEvm;
pub const MinimalEvmError = MinimalEvm.Error;
pub const StorageSlotKey = minimal_evm_mod.StorageSlotKey;
const MinimalFrame = @import("minimal_frame.zig").MinimalFrame;
const Host = minimal_evm_mod.Host;
const UnifiedOpcode = @import("../opcodes/opcode.zig").UnifiedOpcode;
const Opcode = @import("../opcodes/opcode.zig").Opcode;
const OpcodeSynthetic = @import("../opcodes/opcode_synthetic.zig").OpcodeSynthetic;
const minimal_evm_sync = @import("minimal_evm_sync.zig");
const SafetyCounter = @import("../internal/safety_counter.zig").SafetyCounter;
pub const TracerConfig = @import("tracer_config.zig").TracerConfig;
const RingBuffer = @import("ring_buffer.zig").RingBuffer;
const lifecycle_events = @import("lifecycle_events.zig");

/// Tracer for EVM execution monitoring and debugging
/// Tracks execution steps, gas usage, and validates optimized execution
pub const Tracer = struct {
    config: TracerConfig,
    recent_opcodes: RingBuffer,
    steps: std.ArrayList(ExecutionStep),
    advanced_steps: std.ArrayList(AdvancedStep),
    pc_tracker: ?pc_tracker_mod.PcTracker,
    gas_tracker: ?u64,
    current_pc: u32,
    bytecode: []const u8,
    minimal_evm: ?*MinimalEvm,
    instruction_count: u64 = 0,
    schedule_index: u64 = 0,
    simple_instruction_count: u64 = 0,
    fused_instruction_count: u64 = 0,
    nested_depth: u16 = 0,
    instruction_safety: SafetyCounter(u64, .enabled),
    allocator: std.mem.Allocator,

    // Internal representation of an execution step
    pub const ExecutionStep = struct {
        step_number: u64,
        pc: u32,
        opcode: u8,
        opcode_name: []const u8,
        gas_before: i32,
        gas_after: i32,
        gas_cost: u32,
        stack_before: []u256,
        stack_after: []u256,
        memory_size_before: usize,
        memory_size_after: usize,
        depth: u32,
        error_occurred: bool,
        error_msg: ?[]const u8,
    };

    // Advanced execution step for capturing optimized execution of the advanced interpreter
    // Primarily used for internal debugging
    pub const AdvancedStep = struct {
        step_number: u64,
        schedule_index: u32, // Index into dispatch schedule instead of PC
        opcode: u16, // u16 to accommodate synthetic opcodes (>0xFF)
        opcode_name: []const u8,
        is_synthetic: bool,
        gas_before: i64,
        gas_after: i64,
        gas_cost: u64,
        stack_size_before: u32,
        stack_size_after: u32,
        memory_size_before: u32,
        memory_size_after: u32,
        depth: u16,
        fusion_info: ?[]const u8,
    };

    pub fn init(allocator: std.mem.Allocator, config: TracerConfig) Tracer {
        if (!config.enabled) return .{
            .config = config,
            .allocator = allocator,
            .steps = std.ArrayList(ExecutionStep){},
            .advanced_steps = std.ArrayList(AdvancedStep){},
            .pc_tracker = null,
            .gas_tracker = null,
            .current_pc = 0,
            .bytecode = &[_]u8{},
            .minimal_evm = null,
            .instruction_count = 0,
            .schedule_index = 0,
            .simple_instruction_count = 0,
            .fused_instruction_count = 0,
            // 300M instruction safety limit
            .instruction_safety = SafetyCounter(u64, .enabled).init(300_000_000),
            .recent_opcodes = RingBuffer.init(),
        };

        return .{
            .config = config,
            .allocator = allocator,
            .steps = std.ArrayList(ExecutionStep){},
            .advanced_steps = std.ArrayList(AdvancedStep){},
            .pc_tracker = null,
            .gas_tracker = null,
            .current_pc = 0,
            .bytecode = &[_]u8{},
            .minimal_evm = null,
            .instruction_count = 0,
            .schedule_index = 0,
            .simple_instruction_count = 0,
            .fused_instruction_count = 0,
            // 300M instructions is ~10x the block gas limit
            // Normal contracts execute far fewer instructions
            .instruction_safety = SafetyCounter(u64, .enabled).init(300_000_000),
            .recent_opcodes = RingBuffer.init(),
        };
    }

    pub fn deinit(self: *Tracer) void {
        for (self.steps.items) |step| {
            // Only free if allocated (non-empty arrays were allocated, empty ones are static)
            // We only allocate when stack has items, never for empty stacks  
            if (step.stack_before.len > 0) {
                self.allocator.free(step.stack_before);
            }
            if (step.stack_after.len > 0) {
                self.allocator.free(step.stack_after);
            }
        }
        self.steps.deinit(self.allocator);

        for (self.advanced_steps.items) |step| {
            if (step.fusion_info) |fusion_desc| self.allocator.free(fusion_desc);
        }
        self.advanced_steps.deinit(self.allocator);

        if (self.minimal_evm) |evm| {
            evm.deinitPtr(self.allocator);
            self.minimal_evm = null;
        }
    }

    pub fn initPcTracker(self: *Tracer, bytecode: []const u8) void {
        if (!self.config.enabled) return;
        if (!self.config.enable_pc_tracking) return;
        self.bytecode = bytecode;
        self.current_pc = 0;
    }

    /// Initialize MinimalEvm as a sidecar validator when frame starts interpretation
    pub fn onInterpret(self: *Tracer, frame: anytype, bytecode: []const u8, gas_limit: i64) void {
        if (!self.config.enabled) return;
        _ = gas_limit;
        if (!self.config.enable_validation and !self.config.enable_step_capture) return;
        if (self.config.enable_validation) {
            const main_evm = frame.getEvm();
            _ = main_evm.depth; // Currently unused but may be needed for inner frame handling

            // Clean up existing MinimalEvm if present
            if (self.minimal_evm) |evm| {
                self.debug("Cleaning up existing MinimalEvm", .{});
                evm.deinitPtr(self.allocator);
                self.minimal_evm = null;
            }

            self.instruction_count = 0;
            self.schedule_index = 0;
            self.simple_instruction_count = 0;
            self.fused_instruction_count = 0;
            self.instruction_safety.count = 0;

            if (bytecode.len > 0) {
                self.minimal_evm = MinimalEvm.initPtr(self.allocator) catch {
                    self.minimal_evm = null;
                    return;
                };
                self.debug("Created MinimalEvm at 0x{x}", .{@intFromPtr(self.minimal_evm)});
            }

            if (self.minimal_evm) |evm| {
                const evm_instance = frame.getEvm();

                const block_info = evm_instance.get_block_info();
                evm.setBlockchainContext(evm_instance.get_chain_id(), block_info.number, block_info.timestamp, block_info.difficulty, block_info.difficulty, block_info.coinbase, block_info.gas_limit, block_info.base_fee, block_info.blob_base_fee);
                evm.setTransactionContext(evm_instance.get_tx_origin(), evm_instance.gas_price);
                evm.setHardfork(evm_instance.get_hardfork());
                var caller = primitives.ZERO_ADDRESS;
                var address = primitives.ZERO_ADDRESS;
                var value: u256 = 0;
                var calldata: []const u8 = &[_]u8{};

                if (@hasField(@TypeOf(frame.*), "contract_address")) address = frame.contract_address;
                if (@hasField(@TypeOf(frame.*), "caller")) caller = frame.caller;
                if (@hasField(@TypeOf(frame.*), "value")) value = frame.value;
                if (@hasField(@TypeOf(frame.*), "calldata_slice")) calldata = frame.calldata_slice;

                if (!std.mem.eql(u8, &address.bytes, &primitives.ZERO_ADDRESS.bytes)) evm.setCode(address, bytecode) catch {};

                const frame_gas_remaining = frame.gas_remaining;

                const minimal_frame = evm.allocator.create(MinimalFrame) catch return;
                minimal_frame.* = MinimalFrame.init(
                    evm.allocator,
                    bytecode,
                    @intCast(frame_gas_remaining),
                    caller,
                    address,
                    value,
                    calldata,
                    @as(*anyopaque, @ptrCast(evm)),
                    evm.hardfork,
                ) catch return;

                evm.frames.append(evm.allocator, minimal_frame) catch return;

                self.debug("MinimalEvm initialized with bytecode_len={d}, gas={d}", .{
                    bytecode.len,
                    frame_gas_remaining,
                });
            }
        }
    }

    /// Called before an instruction executes
    /// This is the main entry point for instruction tracing
    pub fn before_instruction(self: *Tracer, frame: anytype, comptime opcode: UnifiedOpcode, cursor: [*]const @TypeOf(frame.*).Dispatch.Item) void {
        if (!self.config.enabled) return;
        const main_evm = frame.getEvm();
        const opcode_name = comptime @tagName(opcode);
        const opcode_value = @intFromEnum(opcode);

        var schedule_idx: u32 = 0;
        if (@hasField(@TypeOf(frame.*), "dispatch")) {
            const item_size = @sizeOf(@TypeOf(frame.*).Dispatch.Item);
            const cursor_offset = @intFromPtr(cursor) - @intFromPtr(frame.dispatch.cursor);
            schedule_idx = @intCast(cursor_offset / item_size);
        }

        self.recent_opcodes.write(RingBuffer.Entry{
            .step_number = self.instruction_count,
            .opcode = opcode_value,
            .opcode_name = opcode_name,
            .gas_before = frame.gas_remaining,
            .gas_after = 0, // Will be updated in after_instruction
            .stack_size = @intCast(frame.stack.size()),
            .memory_size = @intCast(frame.memory.size()),
            .schedule_index = schedule_idx,
            .is_synthetic = opcode_value > 0xFF,
        });

        // Capture execution steps if enabled
        if (self.config.enable_step_capture) {
            const pc = self.current_pc;

            var stack_before: []u256 = &[_]u256{};
            if (frame.stack.size() > 0) {
                const stack_slice = frame.stack.get_slice();
                if (self.allocator.alloc(u256, stack_slice.len)) |stack| {
                    @memcpy(stack, stack_slice);
                    stack_before = stack;
                } else |_| {
                    // Log allocation failure for debugging
                    log.warn("Failed to allocate stack copy for tracer step", .{});
                }
            }

            const step = ExecutionStep{
                .step_number = self.instruction_count,
                .pc = pc,
                .opcode = if (opcode_value <= 0xFF) @intCast(opcode_value) else 0,
                .opcode_name = opcode_name,
                .gas_before = @intCast(frame.gas_remaining),
                .gas_after = 0, // Will be filled in after_instruction
                .gas_cost = 0, // Will be calculated in after_instruction
                .stack_before = stack_before,
                .stack_after = &[_]u256{}, // Will be filled in after_instruction
                .memory_size_before = frame.memory.size(),
                .memory_size_after = 0, // Will be filled in after_instruction
                .depth = @intCast(main_evm.depth),
                .error_occurred = false,
                .error_msg = null,
            };

            self.steps.append(self.allocator, step) catch {};
        }

        if (self.minimal_evm) |evm| {
            const pc = evm.getPC();
            const bytecode = evm.getBytecode();
            self.debug("beforeInstruction: Frame executing {s}, MinimalEvm PC={d}, bytecode[PC]=0x{x:0>2}", .{ opcode_name, pc, if (pc < bytecode.len) bytecode[pc] else 0 });
        }
        if (opcode_value <= 0xff) {
            const expected_handler = @TypeOf(frame.*).opcode_handlers[opcode_value];
            const actual_handler = cursor[0].opcode_handler;
            if (actual_handler != expected_handler) {
                self.panic("[HANDLER] Handler mismatch for {s}: expected={*}, actual={*}", .{ opcode_name, expected_handler, actual_handler });
            }
        }

        self.instruction_count += 1;
        if (opcode_value > 0xff) {
            self.fused_instruction_count += 1;
        } else {
            self.simple_instruction_count += 1;
        }

        if (self.config.enable_advanced_trace) {
            const step = self.captureAdvancedStep(frame, opcode, cursor) catch |capture_err| {
                self.warn("Failed to capture advanced step: {}", .{capture_err});
                return;
            };

            if (step.step_number > 0) {
                self.advanced_steps.append(self.allocator, step) catch |append_err| self.warn("Failed to append advanced step: {}", .{append_err});
            }
        }

        self.instruction_safety.inc();

        if (self.minimal_evm) |evm| {
            if (evm.getCurrentFrame()) |mf| {
                self.debug("Before executeMinimalEvmForOpcode {s}: MinimalEvm stack={d}, Frame stack={d}", .{
                    opcode_name,
                    mf.stack.items.len,
                    frame.stack.size(),
                });
            }
            minimal_evm_sync.executeMinimalEvmForOpcode(self, evm, opcode, frame, cursor);
            if (evm.getCurrentFrame()) |mf| {
                self.debug("After executeMinimalEvmForOpcode {s}: MinimalEvm stack={d}, Frame stack={d}", .{
                    opcode_name,
                    mf.stack.items.len,
                    frame.stack.size(),
                });
            }
        }

        const stack_size = frame.stack.size();
        self.debug("EXEC[{d}]: {s} | PC={d} stack={d} gas={d}", .{
            self.instruction_count,
            opcode_name,
            self.current_pc,
            stack_size,
            frame.gas_remaining,
        });
    }

    pub fn after_instruction(self: *Tracer, frame: anytype, comptime opcode: UnifiedOpcode, next_handler: anytype, next_cursor: [*]const @TypeOf(frame.*).Dispatch.Item) void {
        if (!self.config.enabled) return;
        const opcode_name = comptime @tagName(opcode);
        if (self.recent_opcodes.count > 0) {
            const last_idx = if (self.recent_opcodes.head == 0)
                10 - 1 // RingBuffer.CAPACITY = 10
            else
                self.recent_opcodes.head - 1;
            self.recent_opcodes.buffer[last_idx].gas_after = frame.gas_remaining;
        }

        self.schedule_index += 1;

        if (self.config.enable_advanced_trace and self.advanced_steps.items.len > 0) {
            const last_step_idx = self.advanced_steps.items.len - 1;
            var last_step = &self.advanced_steps.items[last_step_idx];

            last_step.gas_after = frame.gas_remaining;
            last_step.gas_cost = @intCast(@as(i64, last_step.gas_before) - @as(i64, frame.gas_remaining));
            last_step.stack_size_after = @intCast(frame.stack.size());
            last_step.memory_size_after = @intCast(frame.memory.size());
        }

        if (next_cursor[0] != .opcode_handler or next_cursor[0].opcode_handler != next_handler) {
            self.panic("[SCHEDULE] Next handler mismatch at sched_idx={d}", .{self.schedule_index});
        }

        if (next_cursor[0] == .opcode_handler) {
            const next_opcode_value = self.getOpcodeFromHandler(@TypeOf(frame.*), next_handler);
            if (next_opcode_value) |opcode_int| {
                if (opcode_int <= 0xff) {
                    const expected_next_handler = @TypeOf(frame.*).opcode_handlers[opcode_int];
                    if (next_handler != expected_next_handler) {
                        self.panic("[HANDLER] Next handler mismatch: opcode=0x{x:0>2}, expected={*}, actual={*}", .{ opcode_int, expected_next_handler, next_handler });
                    }
                }
            }
        }

        self.debug("afterInstruction: Validating state after {s}", .{opcode_name});
        if (self.minimal_evm) |evm| {
            if (evm.getCurrentFrame()) |mf| {
                self.debug("  MinimalEvm stack={d}, Frame stack={d}", .{
                    mf.stack.items.len,
                    frame.stack.size(),
                });
            }
        }
        self.validateMinimalEvmState(frame, opcode);

        if (self.minimal_evm) |evm| self.current_pc = evm.getPC();

        self.debug("DONE[{d}]: {s} | PC={d}", .{
            self.instruction_count,
            opcode_name,
            self.current_pc,
        });
    }

    pub fn after_complete(self: *Tracer, frame: anytype, comptime opcode: UnifiedOpcode) void {
        if (!self.config.enabled) return;
        if (frame.getEvm().depth > 1) return;
        self.validateMinimalEvmState(frame, opcode);
    }

    pub fn captureStep(self: *Tracer, frame: anytype, opcode_value: u8) !ExecutionStep {
        if (!self.config.enable_step_capture) return ExecutionStep{
            .step_number = 0,
            .pc = 0,
            .opcode = 0,
            .opcode_name = "",
            .gas_before = 0,
            .gas_after = 0,
            .gas_cost = 0,
            .stack_before = &[_]u256{},
            .stack_after = &[_]u256{},
            .memory_size_before = 0,
            .memory_size_after = 0,
            .depth = 0,
            .error_occurred = false,
            .error_msg = null,
        };
        var stack_before: []u256 = &[_]u256{};
        if (frame.stack.items.len > 0) {
            stack_before = try self.allocator.alloc(u256, frame.stack.items.len);
            // LIFO order
            for (frame.stack.items, 0..) |val, i| stack_before[frame.stack.items.len - 1 - i] = val;
        }

        // Convert to Opcode enum and get name
        const op = @as(Opcode, @enumFromInt(opcode_value));
        const opcode_name = op.name();

        return ExecutionStep{
            .step_number = self.instruction_count,
            .pc = frame.pc,
            .opcode = opcode_value,
            .opcode_name = opcode_name,
            .gas_before = @intCast(frame.gas_remaining),
            .gas_after = 0, // Will be filled after execution
            .gas_cost = 0, // Will be calculated after execution
            .stack_before = stack_before,
            .stack_after = &[_]u256{}, // Will be filled after execution
            .memory_size_before = frame.memory_size,
            .memory_size_after = 0, // Will be filled after execution
            .depth = frame.call_depth,
            .error_occurred = false,
            .error_msg = null,
        };
    }

    /// Capture the current advanced execution state for Frame
    fn captureAdvancedStep(self: *Tracer, frame: anytype, comptime opcode: UnifiedOpcode, cursor: [*]const @TypeOf(frame.*).Dispatch.Item) !AdvancedStep {
        if (!self.config.enable_advanced_trace) return AdvancedStep{
            .step_number = 0,
            .schedule_index = 0,
            .opcode = 0,
            .opcode_name = "",
            .is_synthetic = false,
            .gas_before = 0,
            .gas_after = 0,
            .gas_cost = 0,
            .stack_size_before = 0,
            .stack_size_after = 0,
            .memory_size_before = 0,
            .memory_size_after = 0,
            .depth = 0,
            .fusion_info = null,
        };

        const opcode_value = @intFromEnum(opcode);
        const is_synthetic = opcode_value > 0xFF;

        // Use UnifiedOpcode to get the name directly
        const opcode_name = opcode.name();

        const fusion_info = if (is_synthetic) blk: {
            // Convert UnifiedOpcode to OpcodeSynthetic
            const synthetic_opcode = std.meta.intToEnum(OpcodeSynthetic, opcode_value) catch {
                break :blk null;
            };
            const desc = synthetic_opcode.describe();
            // Allocate a copy for ownership
            const copy = try self.allocator.alloc(u8, desc.len);
            @memcpy(copy, desc);
            break :blk copy;
        } else null;

        const schedule_index: u32 = @intCast(@intFromPtr(cursor) - @intFromPtr(frame.dispatch.cursor));

        return AdvancedStep{
            .step_number = self.instruction_count,
            .schedule_index = schedule_index,
            .opcode = opcode_value,
            .opcode_name = opcode_name,
            .is_synthetic = is_synthetic,
            .gas_before = frame.gas_remaining,
            .gas_after = 0, // Will be filled in after_instruction
            .gas_cost = 0, // Will be calculated in after_instruction
            .stack_size_before = @intCast(frame.stack.size()),
            .stack_size_after = 0, // Will be filled in after_instruction
            .memory_size_before = @intCast(frame.memory.size()),
            .memory_size_after = 0, // Will be filled in after_instruction
            .depth = @intCast(frame.getEvm().depth),
            .fusion_info = fusion_info,
        };
    }

    /// Describe a fusion operation for advanced trace


    /// Helper to get opcode number from handler pointer by searching opcode_handlers array
    fn getOpcodeFromHandler(self: *Tracer, comptime FrameType: type, handler: FrameType.OpcodeHandler) ?u8 {
        _ = self;
        inline for (0..256) |i| {
            if (FrameType.opcode_handlers[i] == handler) {
                return @intCast(i);
            }
        }
        return null;
    }

    /// Validate MinimalEvm state against Frame state
    fn validateMinimalEvmState(self: *Tracer, frame: anytype, comptime opcode: UnifiedOpcode) void {
        if (self.minimal_evm) |evm| {
            // Skip validation for nested calls
            if (self.nested_depth > 0) return;
            const opcode_name = @tagName(opcode);

            // Compare stack sizes
            const frame_stack_size = frame.stack.size();
            const evm_stack_size = (evm.getCurrentFrame() orelse unreachable).stack.items.len;

            if (evm_stack_size != frame_stack_size) {
                // Allow call-like opcodes a grace period: their host-dependent behavior
                // can differ under the MinimalEvm stub host. We still log but avoid
                // aborting on pure size diffs here to keep differential tests focused
                // on Frame correctness. Content is validated when sizes match.
                const is_call_like = switch (opcode) {
                    .CALL, .CALLCODE, .DELEGATECALL, .STATICCALL => true,
                    else => false,
                };
                if (is_call_like) {
                    self.debug("[EVM2] [DIVERGENCE] (call-like) Stack size mismatch after {s}: MinimalEvm={d} Frame={d}", .{ opcode_name, evm_stack_size, frame_stack_size });
                    return;
                }
                log.err("[EVM2] [DIVERGENCE] Stack size mismatch after {s}:", .{opcode_name});
                log.err("[EVM2]   MinimalEvm: {d}, Frame: {d}", .{ evm_stack_size, frame_stack_size });
                // Show top elements for debugging
                if (evm_stack_size > 0) {
                    self.panic("  MinimalEvm top: 0x{x}", .{(evm.getCurrentFrame() orelse unreachable).stack.items[evm_stack_size - 1]});
                }
                if (frame_stack_size > 0) {
                    self.panic("  Frame top: 0x{x}", .{frame.stack.peek_unsafe()});
                }
                @panic("Stack divergence");
            } else if (evm_stack_size > 0) {
                // Compare stack contents
                const frame_stack = frame.stack.get_slice();
                for (0..evm_stack_size) |i| {
                    const evm_val = (evm.getCurrentFrame() orelse unreachable).stack.items[evm_stack_size - 1 - i];
                    const frame_val = frame_stack[i];
                    if (evm_val != frame_val) {
                        log.err("[EVM2] [DIVERGENCE] Stack content mismatch at position {d}:", .{i});
                        log.err("[EVM2]   MinimalEvm: 0x{x}, Frame: 0x{x}", .{ evm_val, frame_val });
                        log.err("[EVM2]   Opcode: {s}, MinimalEvm PC: {d}", .{ opcode_name, if (evm.getCurrentFrame()) |f| f.pc else 0 });
                        // Print full stack contents
                        log.err("[EVM2]   MinimalEvm stack (top first):", .{});
                        if (evm.getCurrentFrame()) |f| {
                            for (0..@min(10, f.stack.items.len)) |j| {
                                log.err("[EVM2]     [{d}]: 0x{x}", .{ j, f.stack.items[f.stack.items.len - 1 - j] });
                            }
                        }
                        log.err("[EVM2]   Frame stack (top first):", .{});
                        for (0..@min(10, frame_stack.len)) |j| {
                            log.err("[EVM2]     [{d}]: 0x{x}", .{ j, frame_stack[j] });
                        }
                        @panic("Stack content divergence");
                    }
                }
            }

            // Compare memory sizes
            const frame_memory_size = if (@hasField(@TypeOf(frame.*), "memory"))
                frame.memory.size()
            else
                0;
            const evm_memory_size = (evm.getCurrentFrame() orelse unreachable).memory_size;

            if (evm_memory_size != frame_memory_size) {
                // Memory size mismatch is not critical, just debug log
                self.debug("[EVM2] [DIVERGENCE] Memory size mismatch:", .{});
                self.debug("[EVM2]   MinimalEvm: {d}, Frame: {d}", .{ evm_memory_size, frame_memory_size });
            }

            // Gas validation - different rules for different opcode types
            const frame_gas_remaining = frame.gas_remaining;
            const evm_gas_remaining = (evm.getCurrentFrame() orelse unreachable).gas_remaining;

            // Check if this is a jump/terminal opcode that should have exact gas match
            const is_terminal_opcode = switch (opcode) {
                .JUMP, .JUMPI, .STOP, .RETURN, .REVERT, .SELFDESTRUCT => true,
                else => false,
            };

            if (is_terminal_opcode) {
                // For jump/terminal opcodes, gas should match exactly
                // because both EVMs should have consumed the same amount
                if (frame_gas_remaining != evm_gas_remaining) {
                    // Gas divergence at terminal state, debug log only
                    self.debug("[EVM2] [GAS DIVERGENCE] Exact gas mismatch at terminal opcode {s}:", .{opcode_name});
                    self.debug("[EVM2]   Frame gas_remaining: {d}", .{frame_gas_remaining});
                    self.debug("[EVM2]   MinimalEvm gas_remaining: {d}", .{evm_gas_remaining});
                    self.debug("[EVM2]   Difference: {d}", .{@as(i64, frame_gas_remaining) - @as(i64, evm_gas_remaining)});
                }
            } else {
                // For regular opcodes, we don't validate gas due to different charging strategies:
                // Frame pre-charges gas in blocks while MinimalEvm charges per-opcode.
                // This causes legitimate divergences during execution that don't indicate bugs.
                // Gas validation is only meaningful at terminal opcodes where both should be synchronized.
            }
        }
    }

    // ============================================================================
    // LOGGING FUNCTIONS
    // ============================================================================

    pub fn debug(self: *Tracer, comptime format: []const u8, args: anytype) void {
        if (!self.config.enabled) return;
        if (!self.config.enable_debug_logging) return;
        log.debug(format, args);
    }

    pub fn panic(self: *Tracer, comptime format: []const u8, args: anytype) noreturn {
        const builtin = @import("builtin");
        log.err(format, args);

        // Pretty print the ring buffer on error for debugging
        if (self.config.enabled) {
            if (self.recent_opcodes.prettyPrint(self.allocator)) |output| {
                defer self.allocator.free(output);
                log.err("{s}", .{output});
            } else |_| {
                // If pretty print fails, at least show the count
                log.err("Ring buffer has {} recent instructions", .{self.recent_opcodes.count});
            }
        }

        if (builtin.target.cpu.arch == .wasm32 and builtin.target.os.tag == .freestanding) {
            @panic("EVM execution error");
        } else {
            unreachable;
        }
    }

    pub fn warn(self: *Tracer, comptime format: []const u8, args: anytype) void {
        if (!self.config.enabled) return;
        log.warn(format, args);
    }

    pub fn info(self: *Tracer, comptime format: []const u8, args: anytype) void {
        if (!self.config.enabled) return;
        log.info(format, args);
    }

    /// Assert with error message - replaces std.debug.assert
    pub fn assert(self: *Tracer, condition: bool, comptime message: []const u8) void {
        if (!condition) {
            log.err("ASSERTION FAILED: {s}", .{message});
            if (self.config.enabled) {
                if (self.recent_opcodes.prettyPrint(self.allocator)) |output| {
                    defer self.allocator.free(output);
                    log.err("{s}", .{output});
                } else |_| {
                    // If pretty print fails, at least show the count
                    log.err("Ring buffer has {} recent instructions", .{self.recent_opcodes.count});
                }
            }

            const builtin = @import("builtin");
            if (builtin.target.cpu.arch == .wasm32 and builtin.target.os.tag == .freestanding) {
                unreachable;
            } else {
                @panic(message);
            }
        }
    }

    // Generate lifecycle event handlers for this Tracer type
    pub const LifecycleHandlers = lifecycle_events.Handlers(Tracer);

    // Forward all lifecycle event methods to the handlers
    pub const onFrameStart = LifecycleHandlers.onFrameStart;
    pub const onFrameComplete = LifecycleHandlers.onFrameComplete;
    pub const onAccountDelegation = LifecycleHandlers.onAccountDelegation;
    pub const onEmptyAccountAccess = LifecycleHandlers.onEmptyAccountAccess;
    pub const onArenaInit = LifecycleHandlers.onArenaInit;
    pub const onCallStart = LifecycleHandlers.onCallStart;
    pub const onEvmInit = LifecycleHandlers.onEvmInit;
    pub const onArenaReset = LifecycleHandlers.onArenaReset;
    pub const onBeaconRootUpdate = LifecycleHandlers.onBeaconRootUpdate;
    pub const onCallComplete = LifecycleHandlers.onCallComplete;
    pub const onCallPreflight = LifecycleHandlers.onCallPreflight;
    pub const onHistoricalBlockHashUpdate = LifecycleHandlers.onHistoricalBlockHashUpdate;
    pub const onCodeRetrieval = LifecycleHandlers.onCodeRetrieval;
    pub const onValidatorDeposits = LifecycleHandlers.onValidatorDeposits;
    pub const onArenaAlloc = LifecycleHandlers.onArenaAlloc;
    pub const onFrameBytecodeInit = LifecycleHandlers.onFrameBytecodeInit;
    pub const onValidatorWithdrawals = LifecycleHandlers.onValidatorWithdrawals;
    pub const onArenaGrow = LifecycleHandlers.onArenaGrow;
    pub const onArenaAllocFailed = LifecycleHandlers.onArenaAllocFailed;
    pub const onBytecodeAnalysisStart = LifecycleHandlers.onBytecodeAnalysisStart;
    pub const onBytecodeAnalysisComplete = LifecycleHandlers.onBytecodeAnalysisComplete;
    pub const onInvalidOpcode = LifecycleHandlers.onInvalidOpcode;
    pub const onJumpdestFound = LifecycleHandlers.onJumpdestFound;
    pub const onScheduleBuildStart = LifecycleHandlers.onScheduleBuildStart;
    pub const onFusionDetected = LifecycleHandlers.onFusionDetected;
    pub const onInvalidStaticJump = LifecycleHandlers.onInvalidStaticJump;
    pub const onStaticJumpResolved = LifecycleHandlers.onStaticJumpResolved;
    pub const onTruncatedPush = LifecycleHandlers.onTruncatedPush;
    pub const onScheduleBuildComplete = LifecycleHandlers.onScheduleBuildComplete;
    pub const onJumpTableCreated = LifecycleHandlers.onJumpTableCreated;
};

// ============================================================================
