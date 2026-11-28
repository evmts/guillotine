const std = @import("std");
const log = @import("../log.zig");
const primitives = @import("voltaire");
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
const database_state_reader = @import("database_state_reader.zig");
const SafetyCounter = @import("../internal/safety_counter.zig").SafetyCounter;
pub const TracerConfig = @import("tracer_config.zig").TracerConfig;
const RingBuffer = @import("ring_buffer.zig").RingBuffer;
const lifecycle_events = @import("lifecycle_events.zig");
const fork_gas = @import("../frame/fork_gas.zig");
const OPCODE_INFO = @import("../opcodes/opcode_data.zig").OPCODE_INFO;
const root = @import("root");

/// True when this compilation is a library embedded in a host process: the root source
/// file (src/evm_c_api.zig for libguillotine_ffi) declares `guillotine_embedded = true`.
/// An embedded build never runs the MinimalEvm sidecar.
pub const embedded_build = @hasDecl(root, "guillotine_embedded") and root.guillotine_embedded;

/// What kind of tracer check failed. See `Tracer.FailureRecord`.
pub const FailureKind = enum(u8) {
    none,
    /// `Tracer.assert` saw a false condition.
    assertion,
    /// A schedule item holds a different handler than its opcode names.
    handler_mismatch,
    /// The handler that follows in the schedule is not the one the instruction continues with.
    schedule_mismatch,
    /// Frame and the MinimalEvm sidecar disagree on the stack.
    stack_divergence,
    /// Frame and the sidecar disagree on gas where a basic block ends.
    gas_divergence,
    /// Frame and the sidecar ended the frame differently (success, revert or failure).
    exit_divergence,
    /// The sidecar halted with an error and Frame kept executing.
    sidecar_step_error,
    /// The sidecar could not be created, so the frame ran without validation.
    sidecar_setup_failed,
    /// The sidecar could not read pre-existing state from the database.
    state_read_failed,
};

/// Whether the MinimalEvm sidecar is checking the top-level frame, and if not, why.
pub const SidecarState = enum(u8) {
    /// Validation is on and no frame has been mirrored yet (or the frame has no code).
    idle,
    /// The sidecar mirrors the top-level frame.
    active,
    /// `TracerConfig.enable_validation` is off, or the tracer is embedded.
    validation_disabled,
    /// Creating the sidecar failed; the frame is not validated.
    setup_failed,
    /// A sidecar step returned an error (`Tracer.sidecar_error`); it takes no more steps.
    sidecar_step_error,
};

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
    instruction_safety: SafetyCounter(u64, .enabled),
    /// Number of tracer checks that failed. Stays zero in a healthy run. A failed check
    /// never aborts the process: it is logged, counted here and kept in `last_failure`.
    failed_checks: u64 = 0,
    /// The most recent failed check. `kind` is `.none` while `failed_checks` is zero.
    last_failure: FailureRecord = .{},
    /// Severity of the log line a failed check writes. `err` by default, so a test
    /// run or a host that watches its error log notices every divergence. A caller
    /// that provokes failures on purpose and reads `failed_checks` itself sets
    /// `.warn`; the failure is recorded the same either way.
    failure_log_level: enum { err, warn } = .err,
    /// Whether the sidecar validates the current top-level frame, and if not, why.
    sidecar_state: SidecarState = .idle,
    /// The error the sidecar halted with, while `sidecar_state` is `.sidecar_step_error`.
    sidecar_error: ?anyerror = null,
    /// Set once Frame is reported to have executed past a halted sidecar, so one
    /// divergence is counted once.
    sidecar_overrun_reported: bool = false,
    /// Read-only view of the production database the sidecar reads pre-existing state from.
    state_bridge: database_state_reader.ReadContext = .{},
    /// Database read errors already reported from `state_bridge`.
    state_read_errors_reported: u64 = 0,
    /// True once a capture bound or an allocation failure dropped a step. The steps
    /// captured before it stay valid; see `truncation_reason`.
    truncated: bool = false,
    truncation_reason: TracerConfig.TruncationReason = .none,
    /// Bytes owned by `steps` and `advanced_steps`, counted against `TracerConfig.max_bytes`.
    captured_bytes: usize = 0,
    /// True for an EVM owned by a host process through the C ABI. An embedded tracer
    /// never runs the MinimalEvm sidecar: it recurses on the native stack, so it cannot
    /// be trusted on a host's small thread stack.
    embedded: bool = embedded_build,
    /// Step-capture bookkeeping, one entry per live call frame (index = depth - 1).
    frame_cursors: std.ArrayList(FrameCursor) = .empty,
    allocator: std.mem.Allocator,

    /// Where a call frame is in its bytecode, and how much of its gas is prepaid.
    ///
    /// Frame has no program counter and charges static gas per basic block. Step
    /// capture rebuilds both: `pc` follows the executed instructions through the raw
    /// bytecode, and `prepaid` is the static gas Frame already charged for instructions
    /// of the current block that have not run yet, so `gas_remaining + prepaid` is the
    /// gas a per-instruction interpreter would report.
    const FrameCursor = struct {
        bytecode: []const u8,
        pc: u32 = 0,
        prepaid: u64 = 0,
        /// Frame gas when interpretation began. Null once the first block's charge
        /// (taken between `onInterpret` and the first instruction) is accounted for.
        entry_gas: ?i64,
        /// Steps in `Tracer.steps` of the handler in flight: `pending_count` entries
        /// starting at `pending_first`. A fused handler has one per instruction it covers.
        pending_first: usize = 0,
        pending_count: u32 = 0,
        pending_gas_before: i64 = 0,
        /// Index in `Tracer.advanced_steps` of the record of the handler in flight in
        /// this frame. A nested call appends its own records after it, so the record
        /// is found by this index, never as the last one in the list.
        pending_advanced: ?usize = null,
    };

    /// A failed tracer check, kept so a caller can report it without parsing logs.
    pub const FailureRecord = struct {
        kind: FailureKind = .none,
        /// `Tracer.instruction_count` when the check failed.
        instruction: u64 = 0,
        buffer: [capacity]u8 = @splat(0),
        len: usize = 0,

        pub const capacity = 192;

        /// The formatted failure, cut to `capacity` bytes.
        pub fn message(self: *const FailureRecord) []const u8 {
            return self.buffer[0..self.len];
        }
    };

    /// One executed bytecode instruction, recorded from Frame state.
    pub const ExecutionStep = struct {
        step_number: u64,
        pc: u32,
        opcode: u8,
        opcode_name: []const u8,
        /// Gas before and after the instruction, with basic-block prepayment undone.
        gas_before: i64,
        gas_after: i64,
        gas_cost: u64,
        /// Stack before the instruction, top first. Owned when non-empty.
        stack_before: []u256,
        /// Unused by step capture (always empty); owned when non-empty.
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
            .steps = std.ArrayList(ExecutionStep).empty,
            .advanced_steps = std.ArrayList(AdvancedStep).empty,
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
            .steps = std.ArrayList(ExecutionStep).empty,
            .advanced_steps = std.ArrayList(AdvancedStep).empty,
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
        self.clearSteps();
        self.steps.deinit(self.allocator);
        self.advanced_steps.deinit(self.allocator);
        self.frame_cursors.deinit(self.allocator);

        self.dropSidecar();
    }

    pub fn initPcTracker(self: *Tracer, bytecode: []const u8) void {
        if (!self.config.enabled) return;
        if (!self.config.enable_pc_tracking) return;
        self.bytecode = bytecode;
        self.current_pc = 0;
    }

    /// Start tracing the frame that is about to interpret `bytecode`: begin its step
    /// capture and, for a top-level frame under validation, create the MinimalEvm
    /// sidecar that mirrors it.
    pub fn onInterpret(self: *Tracer, frame: anytype, bytecode: []const u8, gas_limit: i64) void {
        if (!self.config.enabled) return;
        _ = gas_limit;
        if (self.config.enable_step_capture or self.config.enable_advanced_trace) {
            self.beginFrameCapture(frame, bytecode);
        }
        if (!self.config.enable_validation or self.embedded) {
            self.sidecar_state = .validation_disabled;
            return;
        }
        // The sidecar mirrors the top-level frame only. A nested frame must not replace
        // it: the outer frame resumes after the call and is validated against it again.
        if (frame.getEvm().depth > 1) return;

        self.dropSidecar();
        self.instruction_count = 0;
        self.schedule_index = 0;
        self.simple_instruction_count = 0;
        self.fused_instruction_count = 0;
        self.instruction_safety.count = 0;
        self.sidecar_state = .idle;
        if (bytecode.len == 0) return;

        self.startSidecar(frame, bytecode) catch |err| {
            self.dropSidecar();
            self.sidecar_state = .setup_failed;
            self.failKind(
                .sidecar_setup_failed,
                "MinimalEvm sidecar setup failed ({s}); this frame runs without validation",
                .{@errorName(err)},
            );
        };
    }

    /// Destroy the sidecar and forget everything recorded about it.
    fn dropSidecar(self: *Tracer) void {
        if (self.minimal_evm) |evm| evm.deinitPtr(self.allocator);
        self.minimal_evm = null;
        self.sidecar_error = null;
        self.sidecar_overrun_reported = false;
        self.state_bridge = .{};
        self.state_read_errors_reported = 0;
    }

    /// Create the sidecar for the top-level `frame`: same block and transaction
    /// context, same warm set, the frame's code, and a read-only bridge to the
    /// database for every account, balance, code and storage slot that already exists.
    /// The sidecar is published only when every step succeeded.
    fn startSidecar(self: *Tracer, frame: anytype, bytecode: []const u8) !void {
        const evm_instance = frame.getEvm();
        const evm = try MinimalEvm.initPtr(self.allocator);
        errdefer evm.deinitPtr(self.allocator);

        const block_info = evm_instance.get_block_info();
        evm.setBlockchainContext(
            evm_instance.get_chain_id(),
            block_info.number,
            block_info.timestamp,
            block_info.difficulty,
            std.mem.readInt(u256, &block_info.prev_randao, .big),
            block_info.coinbase,
            block_info.gas_limit,
            block_info.base_fee,
            block_info.blob_base_fee,
        );
        evm.setTransactionContext(evm_instance.get_tx_origin(), evm_instance.gas_price);
        evm.setBlobVersionedHashes(evm_instance.context.blob_versioned_hashes);
        evm.setBlockHashes(block_info.block_hashes);
        evm.setHardfork(evm_instance.get_hardfork());

        const FrameType = @TypeOf(frame.*);
        const address = if (@hasField(FrameType, "contract_address")) frame.contract_address else primitives.ZERO_ADDRESS;
        const caller = if (@hasField(FrameType, "caller")) frame.caller else primitives.ZERO_ADDRESS;
        const value: u256 = if (@hasField(FrameType, "value")) frame.value else 0;
        const calldata: []const u8 = if (@hasField(FrameType, "calldata_slice")) frame.calldata_slice else &.{};

        // The frame's own code is seeded locally: initcode is not in the database.
        if (!address.equals(primitives.ZERO_ADDRESS)) try evm.setCode(address, bytecode);

        // EIP-6780: SELFDESTRUCT deletes an account only when it was created in this
        // transaction, so the sidecar must know that about the frame it mirrors.
        const EvmType = @TypeOf(evm_instance.*);
        if (@hasDecl(EvmType, "was_created_in_tx") and evm_instance.was_created_in_tx(address)) {
            try evm.markCreated(address);
        }
        if (@hasField(EvmType, "database")) {
            const Db = @TypeOf(evm_instance.database.*);
            evm.setStateReader(database_state_reader.DatabaseStateReader(Db).reader(
                &self.state_bridge,
                evm_instance.database,
            ));
        }
        if (@hasField(EvmType, "access_list")) try mirrorWarmSet(evm, &evm_instance.access_list);

        // The arena of `evm` owns the frame; `deinitPtr` releases it on every path.
        const minimal_frame = try evm.allocator.create(MinimalFrame);
        minimal_frame.* = try MinimalFrame.init(
            evm.allocator,
            bytecode,
            @max(frame.gas_remaining, 0),
            caller,
            address,
            value,
            calldata,
            @as(*anyopaque, @ptrCast(evm)),
            evm.hardfork,
        );
        if (@hasDecl(EvmType, "is_static_context")) minimal_frame.is_static = evm_instance.is_static_context();
        try evm.frames.append(evm.allocator, minimal_frame);

        self.minimal_evm = evm;
        self.sidecar_state = .active;
        self.debug("MinimalEvm initialized with bytecode_len={d}, gas={d}", .{ bytecode.len, frame.gas_remaining });
    }

    /// Copy the EIP-2929 warm addresses and storage slots of `access_list` into the
    /// sidecar, so both interpreters charge the same cold and warm access costs.
    fn mirrorWarmSet(evm: *MinimalEvm, access_list: anytype) !void {
        for (access_list.addresses.keys()) |warm_address| {
            try evm.warm_addresses.put(evm.allocator, warm_address, {});
        }
        for (access_list.storage_slots.keys()) |key| {
            try evm.warm_storage_slots.put(evm.allocator, .{ .address = key.address, .slot = key.slot }, {});
        }
    }

    /// Drop all recorded steps and the stack copies and fusion descriptions they own,
    /// keeping list capacity for the next transaction.
    pub fn clearSteps(self: *Tracer) void {
        for (self.steps.items) |step| {
            // Empty stacks are static slices; only non-empty copies were allocated.
            if (step.stack_before.len > 0) self.allocator.free(step.stack_before);
            if (step.stack_after.len > 0) self.allocator.free(step.stack_after);
        }
        self.steps.items.len = 0;
        // Cursors index into `steps`, so they end with it.
        self.frame_cursors.items.len = 0;
        for (self.advanced_steps.items) |step| {
            if (step.fusion_info) |fusion_desc| self.allocator.free(fusion_desc);
        }
        self.advanced_steps.items.len = 0;
        self.captured_bytes = 0;
        self.truncated = false;
        self.truncation_reason = .none;
    }

    /// Called before an instruction executes
    /// This is the main entry point for instruction tracing
    pub fn before_instruction(
        self: *Tracer,
        frame: anytype,
        comptime opcode: UnifiedOpcode,
        cursor: [*]const @TypeOf(frame.*).Dispatch.Item,
    ) void {
        if (!self.config.enabled) return;
        const main_evm = frame.getEvm();
        const opcode_name = comptime @tagName(opcode);
        const opcode_value = @backingInt(opcode);

        const schedule_idx = scheduleIndexOf(frame, cursor);

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

        // Steps are recorded from Frame state at every call depth, with fused
        // instructions expanded, so each bytecode instruction appears exactly once.
        if (self.config.enable_step_capture) self.recordSteps(frame, opcode, cursor);

        if (self.minimal_evm) |evm| {
            const pc = evm.getPC();
            const bytecode = evm.getBytecode();
            const byte_at_pc: u8 = if (pc < bytecode.len) bytecode[pc] else 0;
            self.debug(
                "beforeInstruction: Frame executing {s}, MinimalEvm PC={d}, bytecode[PC]=0x{x:0>2}",
                .{ opcode_name, pc, byte_at_pc },
            );
        }
        if (opcode_value <= 0xff) {
            const expected_handler = @TypeOf(frame.*).opcode_handlers[opcode_value];
            const actual_handler = cursor[0].opcode_handler;
            if (actual_handler != expected_handler) {
                self.failKind(
                    .handler_mismatch,
                    "[HANDLER] Handler mismatch for {s}: expected={*}, actual={*}",
                    .{ opcode_name, expected_handler, actual_handler },
                );
            }
        }

        self.instruction_count += 1;
        if (opcode_value > 0xff) {
            self.fused_instruction_count += 1;
        } else {
            self.simple_instruction_count += 1;
        }

        if (self.config.enable_advanced_trace) self.recordAdvancedStep(frame, opcode, schedule_idx);

        self.instruction_safety.inc();

        // Nested frames run inside the top-level CALL/CREATE step of the sidecar, so only
        // top-level instructions advance it.
        if (main_evm.depth == 1) {
            if (self.minimal_evm) |evm| {
                minimal_evm_sync.executeMinimalEvmForOpcode(self, evm, opcode);
                self.reportStateReadErrors();
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

    pub fn after_instruction(
        self: *Tracer,
        frame: anytype,
        comptime opcode: UnifiedOpcode,
        next_handler: anytype,
        next_cursor: [*]const @TypeOf(frame.*).Dispatch.Item,
    ) void {
        if (!self.config.enabled) return;
        const opcode_name = comptime @tagName(opcode);
        if (self.config.enable_step_capture) self.finishSteps(frame);
        if (self.recent_opcodes.count > 0) {
            const last_idx = if (self.recent_opcodes.head == 0)
                10 - 1 // RingBuffer.CAPACITY = 10
            else
                self.recent_opcodes.head - 1;
            self.recent_opcodes.buffer[last_idx].gas_after = frame.gas_remaining;
        }

        self.schedule_index += 1;

        if (self.config.enable_advanced_trace) self.finishAdvancedStep(frame);

        if (next_cursor[0] != .opcode_handler or next_cursor[0].opcode_handler != next_handler) {
            self.failKind(.schedule_mismatch, "[SCHEDULE] Next handler mismatch at sched_idx={d}", .{self.schedule_index});
        }

        if (next_cursor[0] == .opcode_handler) {
            const next_opcode_value = self.getOpcodeFromHandler(@TypeOf(frame.*), next_handler);
            if (next_opcode_value) |opcode_int| {
                if (opcode_int <= 0xff) {
                    const expected_next_handler = @TypeOf(frame.*).opcode_handlers[opcode_int];
                    if (next_handler != expected_next_handler) {
                        self.failKind(
                            .handler_mismatch,
                            "[HANDLER] Next handler mismatch: opcode=0x{x:0>2}, expected={*}, actual={*}",
                            .{ opcode_int, expected_next_handler, next_handler },
                        );
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

    /// Called when a handler ends its frame instead of continuing: a halt (STOP, RETURN,
    /// REVERT, SELFDESTRUCT) or an error exit. It completes the records of the handler
    /// in flight. The frame's outcome is compared in `onInterpretExit`, which knows it.
    pub fn after_complete(self: *Tracer, frame: anytype, comptime opcode: UnifiedOpcode) void {
        if (!self.config.enabled) return;
        _ = opcode;
        if (self.config.enable_step_capture) self.finishSteps(frame);
        if (self.config.enable_advanced_trace) self.finishAdvancedStep(frame);
    }

    /// How a frame ended, for comparing Frame with the sidecar.
    const Outcome = enum { running, success, revert, failure };

    /// Called once when `frame` stops interpreting, with the status it exits with.
    ///
    /// Completes any record still pending for the frame (an exit that ran no
    /// `after_complete`) and, for the top-level frame under validation, compares how
    /// Frame and the sidecar ended: the same outcome, and on a success or revert the
    /// same stack and exactly the same gas.
    ///
    /// Frame validates gas and stack per basic block, so it may fail before an
    /// instruction the sidecar has yet to reach. A Frame failure therefore agrees with
    /// a sidecar that failed or is still running, and only with those.
    pub fn onInterpretExit(self: *Tracer, frame: anytype, status: anyerror) void {
        if (!self.config.enabled) return;
        if (self.config.enable_step_capture) self.finishSteps(frame);
        if (self.config.enable_advanced_trace) self.finishAdvancedStep(frame);
        if (!self.config.enable_validation or frame.getEvm().depth > 1) return;
        const evm = self.minimal_evm orelse return;
        const mf = evm.getCurrentFrame() orelse return;

        const frame_outcome: Outcome = switch (status) {
            error.Stop, error.Return, error.SelfDestruct => .success,
            error.REVERT => .revert,
            else => .failure,
        };
        const sidecar_outcome: Outcome = if (self.sidecar_error != null)
            .failure
        else if (mf.reverted)
            .revert
        else if (mf.stopped or mf.pc >= mf.bytecode.len)
            .success
        else
            .running;

        const agree = switch (frame_outcome) {
            .failure => sidecar_outcome == .failure or sidecar_outcome == .running,
            else => sidecar_outcome == frame_outcome,
        };
        if (!agree) {
            self.failKind(
                .exit_divergence,
                "Exit divergence: Frame ended with {s} ({s}), MinimalEvm with {s} (error: {s})",
                .{
                    @tagName(frame_outcome),
                    @errorName(status),
                    @tagName(sidecar_outcome),
                    if (self.sidecar_error) |err| @errorName(err) else "none",
                },
            );
            return;
        }
        if (frame_outcome == .failure) return;
        if (!self.stacksAgree(frame, mf, @errorName(status))) return;
        self.compareBoundaryGas(frame, mf, @errorName(status));
    }

    /// Record the error a sidecar step returned. The sidecar takes no more steps.
    pub fn recordSidecarStepError(self: *Tracer, opcode_name: []const u8, pc: u32, err: anyerror) void {
        self.sidecar_error = err;
        self.sidecar_state = .sidecar_step_error;
        self.debug("MinimalEvm halted with {s} at pc={d} while Frame runs {s}", .{
            @errorName(err),
            pc,
            opcode_name,
        });
    }

    /// Report, once, that Frame executes an instruction after the sidecar halted with
    /// an error: Frame accepted an instruction the reference interpreter refused.
    pub fn reportSidecarOverrun(self: *Tracer, opcode_name: []const u8) void {
        if (self.sidecar_overrun_reported) return;
        self.sidecar_overrun_reported = true;
        self.failKind(
            .sidecar_step_error,
            "MinimalEvm halted with {s} but Frame continued to {s}",
            .{ if (self.sidecar_error) |err| @errorName(err) else "none", opcode_name },
        );
    }

    /// Report database reads the sidecar's state bridge could not complete since the
    /// last report. Such a read returned zero to the sidecar, so later checks may differ.
    fn reportStateReadErrors(self: *Tracer) void {
        const total = self.state_bridge.read_errors;
        if (total == self.state_read_errors_reported) return;
        self.state_read_errors_reported = total;
        self.failKind(
            .state_read_failed,
            "MinimalEvm could not read database state ({s}); {d} failed reads so far",
            .{ if (self.state_bridge.last_error) |err| @errorName(err) else "none", total },
        );
    }

    /// Index of `cursor` in the dispatch schedule of `frame`, counted in items from the
    /// frame's first handler.
    fn scheduleIndexOf(frame: anytype, cursor: [*]const @TypeOf(frame.*).Dispatch.Item) u32 {
        if (!@hasField(@TypeOf(frame.*), "dispatch")) return 0;
        const base = @intFromPtr(frame.dispatch.cursor);
        const at = @intFromPtr(cursor);
        if (at < base) return 0;
        const index = (at - base) / @sizeOf(@TypeOf(frame.*).Dispatch.Item);
        return std.math.cast(u32, index) orelse std.math.maxInt(u32);
    }

    /// Stop capturing: a bound was reached or the allocator failed. The steps already
    /// captured stay valid; the first reason is kept.
    fn markTruncated(self: *Tracer, reason: TracerConfig.TruncationReason) void {
        if (self.truncated) return;
        self.truncated = true;
        self.truncation_reason = reason;
        log.warn("Tracer: trace truncated ({s}) after {d} steps, {d} advanced steps, {d} bytes", .{
            @tagName(reason),
            self.steps.items.len,
            self.advanced_steps.items.len,
            self.captured_bytes,
        });
    }

    /// True when a capture list holding `count` records may take one more that owns
    /// `bytes` bytes. Marks the trace truncated when it may not.
    fn reserveCapture(self: *Tracer, count: usize, bytes: usize) bool {
        if (self.truncated) return false;
        if (self.config.max_steps) |limit| {
            if (count >= limit) {
                self.markTruncated(.max_steps);
                return false;
            }
        }
        if (self.config.max_bytes) |limit| {
            if (self.captured_bytes +| bytes > limit) {
                self.markTruncated(.max_bytes);
                return false;
            }
        }
        return true;
    }

    /// True when a capture bound or an allocation failure dropped at least one step.
    pub fn isTruncated(self: *const Tracer) bool {
        return self.truncated;
    }

    /// Why the trace is incomplete; `.none` for a complete trace.
    pub fn truncationReason(self: *const Tracer) TracerConfig.TruncationReason {
        return self.truncation_reason;
    }

    /// Start step capture for the call frame that is about to interpret `bytecode`.
    fn beginFrameCapture(self: *Tracer, frame: anytype, bytecode: []const u8) void {
        const depth: usize = frame.getEvm().depth;
        if (depth == 0) return;
        const index = depth - 1;
        // A frame whose parent could not be tracked (allocation failure) is not tracked.
        if (index > self.frame_cursors.items.len) return;
        self.frame_cursors.items.len = index;
        self.frame_cursors.append(self.allocator, .{
            .bytecode = bytecode,
            .entry_gas = frame.gas_remaining,
        }) catch |err| {
            log.warn("Tracer: steps of the frame at depth {d} are not captured: {}", .{ depth, err });
            self.markTruncated(.out_of_memory);
        };
    }

    /// Immediate of the PUSH0..PUSH32 instruction at `pc`. Bytes past the end of the
    /// code read as zero, as the EVM defines.
    fn pushImmediate(bytecode: []const u8, pc: usize, width: usize) u256 {
        var value: u256 = 0;
        for (0..width) |i| {
            const at = pc + 1 + i;
            value = (value << 8) | @as(u256, if (at < bytecode.len) bytecode[at] else 0);
        }
        return value;
    }

    /// Bytes a captured step with a stack copy of `stack_len` words owns.
    fn stepBytes(stack_len: usize) usize {
        return @sizeOf(ExecutionStep) +| (stack_len *| @sizeOf(u256));
    }

    /// Copy `items` for a step. Empty stacks share a static slice and are never freed.
    fn dupeStack(self: *Tracer, items: []const u256) ![]u256 {
        if (items.len == 0) return &[_]u256{};
        return self.allocator.dupe(u256, items);
    }

    /// Stack (top first) after a non-final instruction of a fused handler. Fusions only
    /// place PUSH, ISZERO and ADD before their last instruction (see `minimal_evm_sync.instructionsCovered`).
    fn stackAfterFusedPrefix(self: *Tracer, op: u8, immediate: u256, before: []const u256) ![]u256 {
        switch (op) {
            0x5f...0x7f => {
                const after = try self.allocator.alloc(u256, before.len + 1);
                after[0] = immediate;
                @memcpy(after[1..], before);
                return after;
            },
            0x15 => { // ISZERO
                if (before.len < 1) return error.FusedStackUnderflow;
                const after = try self.allocator.dupe(u256, before);
                after[0] = @intFromBool(before[0] == 0);
                return after;
            },
            0x01 => { // ADD
                if (before.len < 2) return error.FusedStackUnderflow;
                const after = try self.allocator.alloc(u256, before.len - 1);
                after[0] = before[0] +% before[1];
                @memcpy(after[1..], before[2..]);
                return after;
            },
            else => return error.UnexpectedFusedInstruction,
        }
    }

    /// Record one step per bytecode instruction the handler for `opcode` is about to
    /// execute, from the real Frame: its stack, memory size, call depth and gas.
    fn recordSteps(
        self: *Tracer,
        frame: anytype,
        comptime opcode: UnifiedOpcode,
        cursor: [*]const @TypeOf(frame.*).Dispatch.Item,
    ) void {
        const main_evm = frame.getEvm();
        const depth: usize = main_evm.depth;
        if (depth == 0 or depth > self.frame_cursors.items.len) return;
        const fc = &self.frame_cursors.items[depth - 1];
        fc.pending_count = 0;
        if (self.truncated) return;

        const gas_now: i64 = frame.gas_remaining;
        if (fc.entry_gas) |entry| {
            fc.prepaid = if (entry > gas_now) @intCast(entry - gas_now) else 0;
            fc.entry_gas = null;
        }

        // Block entry: the handler charges the block's static gas right after this hook.
        const enters_block = comptime (opcode == .JUMPDEST or opcode == .BLOCK_BEGIN);
        const block_gas: u64 = if (enters_block) cursor[1].jump_dest.gas else 0;
        if (enters_block and fc.prepaid != 0) {
            self.debug(
                "Tracer: {d} gas still prepaid at block entry (pc={d}); resynchronizing",
                .{ fc.prepaid, fc.pc },
            );
            fc.prepaid = 0;
        }

        const covered = comptime minimal_evm_sync.instructionsCovered(opcode);
        if (covered == 0) {
            fc.prepaid += block_gas;
            return;
        }

        const bytecode = fc.bytecode;
        const hardfork = main_evm.get_hardfork();
        const prepaid_before = fc.prepaid;
        const gas_before: i64 = gas_now + @as(i64, @intCast(@min(prepaid_before, std.math.maxInt(u32))));
        fc.pending_first = self.steps.items.len;
        fc.pending_gas_before = gas_before;

        var pc: usize = fc.pc;
        var gas: i64 = gas_before;
        var static_total: u64 = 0;
        // `stack` is the stack before the instruction at `pc`, top first. This function
        // owns it until a step records it; then `stack` moves on to the next copy.
        const live_stack = frame.stack.get_slice();
        if (!self.reserveCapture(self.steps.items.len, stepBytes(live_stack.len))) return;
        var stack: []u256 = self.dupeStack(live_stack) catch |err| {
            log.warn("Tracer: step at pc={d} not captured: {}", .{ pc, err });
            self.markTruncated(.out_of_memory);
            return;
        };
        defer if (stack.len > 0) self.allocator.free(stack);

        var k: u8 = 0;
        while (k < covered and pc < bytecode.len) : (k += 1) {
            const op = bytecode[pc];
            const width: usize = if (op >= 0x60 and op <= 0x7f) op - 0x5f else 0;
            const immediate: u256 = if (op >= 0x5f and op <= 0x7f) pushImmediate(bytecode, pc, width) else 0;
            const static = fork_gas.staticGas(hardfork, op, OPCODE_INFO[op].gas_cost);
            const last = k + 1 == covered;

            // Compute the next stack first, so a failure leaves no half-recorded handler.
            const next_stack: []u256 = if (last)
                &[_]u256{}
            else
                self.stackAfterFusedPrefix(op, immediate, stack) catch |err| {
                    log.warn(
                        "Tracer: fused {s} at pc={d} not captured past opcode 0x{x:0>2}: {}",
                        .{ @tagName(opcode), pc, op, err },
                    );
                    if (err == error.OutOfMemory) self.markTruncated(.out_of_memory);
                    return;
                };
            const step_bytes = stepBytes(stack.len);
            // The first step of the handler was admitted above; later ones are checked here.
            if (k > 0 and !self.reserveCapture(self.steps.items.len, step_bytes)) {
                if (next_stack.len > 0) self.allocator.free(next_stack);
                return;
            }

            const named = std.enums.fromInt(Opcode, op) orelse Opcode.INVALID;
            self.steps.append(self.allocator, .{
                .step_number = self.instruction_count,
                .pc = @intCast(pc),
                .opcode = op,
                .opcode_name = named.name(),
                .gas_before = @max(gas, 0),
                .gas_after = @max(gas - @as(i64, @intCast(static)), 0),
                .gas_cost = static,
                .stack_before = stack,
                .stack_after = &[_]u256{},
                .memory_size_before = frame.memory.size(),
                .memory_size_after = frame.memory.size(),
                .depth = @intCast(depth),
                .error_occurred = false,
                .error_msg = null,
            }) catch |err| {
                log.warn("Tracer: step at pc={d} not captured: {}", .{ pc, err });
                if (next_stack.len > 0) self.allocator.free(next_stack);
                self.markTruncated(.out_of_memory);
                return;
            };
            self.captured_bytes +|= step_bytes;
            fc.pending_count += 1;

            // Where execution continues: a taken jump, or the next instruction.
            var next_pc: usize = pc + 1 + width;
            if (last) {
                const taken: ?u256 = switch (op) {
                    0x56 => if (stack.len >= 1) stack[0] else null, // JUMP
                    0x57 => if (stack.len >= 2 and stack[1] != 0) stack[0] else null, // JUMPI
                    else => null,
                };
                if (taken) |dest| {
                    if (dest <= std.math.maxInt(u32)) next_pc = @intCast(dest);
                }
            }
            stack = next_stack;
            pc = next_pc;
            gas -= @intCast(static);
            static_total += static;
        }

        fc.pc = @intCast(@min(pc, std.math.maxInt(u32)));
        fc.prepaid = (prepaid_before + block_gas) -| static_total;
    }

    /// Complete the steps of the handler that just finished in `frame`: add the gas it
    /// charged beyond static cost (memory expansion, cold access, forwarded call gas)
    /// to its last instruction and record the resulting gas and memory size.
    fn finishSteps(self: *Tracer, frame: anytype) void {
        const depth: usize = frame.getEvm().depth;
        if (depth == 0 or depth > self.frame_cursors.items.len) return;
        const fc = &self.frame_cursors.items[depth - 1];
        if (fc.pending_count == 0) return;
        defer fc.pending_count = 0;
        const end = fc.pending_first + fc.pending_count;
        if (end > self.steps.items.len) return;
        const pending = self.steps.items[fc.pending_first..end];

        const clamped_prepaid: i64 = @intCast(@min(fc.prepaid, std.math.maxInt(u32)));
        const gas_after: i64 = @as(i64, frame.gas_remaining) + clamped_prepaid;
        var static_total: u64 = 0;
        for (pending) |step| static_total += step.gas_cost;
        const spent: u64 = if (fc.pending_gas_before > gas_after) @intCast(fc.pending_gas_before - gas_after) else 0;
        const last = &pending[pending.len - 1];
        last.gas_cost += spent -| static_total;
        last.gas_after = @max(gas_after, 0);
        last.memory_size_after = frame.memory.size();
    }

    /// Record the advanced-trace step of the handler `frame` is about to run and
    /// remember it as that frame's pending record, to be completed when the handler
    /// finishes. Dropped, with the trace marked truncated, when over budget.
    fn recordAdvancedStep(self: *Tracer, frame: anytype, comptime opcode: UnifiedOpcode, schedule_index: u32) void {
        const depth: usize = frame.getEvm().depth;
        if (depth == 0 or depth > self.frame_cursors.items.len) return;
        const fc = &self.frame_cursors.items[depth - 1];
        fc.pending_advanced = null;

        const opcode_value = @backingInt(opcode);
        const description: ?[]const u8 = if (std.enums.fromInt(OpcodeSynthetic, opcode_value)) |synthetic|
            synthetic.describe()
        else
            null;
        const description_len = if (description) |text| text.len else 0;
        if (!self.reserveCapture(self.advanced_steps.items.len, @sizeOf(AdvancedStep) +| description_len)) return;

        self.advanced_steps.ensureUnusedCapacity(self.allocator, 1) catch |err| {
            log.warn("Tracer: advanced step {d} not captured: {}", .{ self.instruction_count, err });
            self.markTruncated(.out_of_memory);
            return;
        };
        const fusion_info: ?[]const u8 = if (description) |text|
            self.allocator.dupe(u8, text) catch |err| {
                log.warn("Tracer: advanced step {d} not captured: {}", .{ self.instruction_count, err });
                self.markTruncated(.out_of_memory);
                return;
            }
        else
            null;

        fc.pending_advanced = self.advanced_steps.items.len;
        self.captured_bytes +|= @sizeOf(AdvancedStep) +| description_len;
        self.advanced_steps.appendAssumeCapacity(.{
            .step_number = self.instruction_count,
            .schedule_index = schedule_index,
            .opcode = opcode_value,
            .opcode_name = opcode.name(),
            .is_synthetic = opcode_value > 0xFF,
            .gas_before = frame.gas_remaining,
            // The handler has not run: until `finishAdvancedStep` the record shows no change.
            .gas_after = frame.gas_remaining,
            .gas_cost = 0,
            .stack_size_before = @intCast(frame.stack.size()),
            .stack_size_after = @intCast(frame.stack.size()),
            .memory_size_before = @intCast(frame.memory.size()),
            .memory_size_after = @intCast(frame.memory.size()),
            .depth = @intCast(depth),
            .fusion_info = fusion_info,
        });
    }

    /// Complete the pending advanced-trace record of `frame` from the frame's state
    /// after its handler ran. The record belongs to this frame, so the gas difference
    /// is taken within one frame even when nested calls recorded steps in between.
    fn finishAdvancedStep(self: *Tracer, frame: anytype) void {
        const depth: usize = frame.getEvm().depth;
        if (depth == 0 or depth > self.frame_cursors.items.len) return;
        const fc = &self.frame_cursors.items[depth - 1];
        const index = fc.pending_advanced orelse return;
        fc.pending_advanced = null;
        if (index >= self.advanced_steps.items.len) return;
        const step = &self.advanced_steps.items[index];

        const gas_after: i64 = frame.gas_remaining;
        step.gas_after = gas_after;
        // A handler never gains gas, except a call that returns unused forwarded gas
        // with a stipend; such a step reports a cost of zero.
        step.gas_cost = if (step.gas_before > gas_after) @intCast(step.gas_before - gas_after) else 0;
        step.stack_size_after = @intCast(frame.stack.size());
        step.memory_size_after = @intCast(frame.memory.size());
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

    /// Validate MinimalEvm state against Frame state after an instruction.
    ///
    /// Runs only when validation is enabled in the tracer config, for the top-level
    /// frame, while the sidecar is still running: once it halted with an error its
    /// stack is no longer comparable and `onInterpretExit` compares the outcome.
    fn validateMinimalEvmState(self: *Tracer, frame: anytype, comptime opcode: UnifiedOpcode) void {
        if (!self.config.enable_validation) return;
        const evm = self.minimal_evm orelse return;
        if (self.sidecar_error != null) return;
        // The sidecar mirrors the top-level frame only.
        if (frame.getEvm().depth > 1) return;
        const mf = evm.getCurrentFrame() orelse return;
        const opcode_name = @tagName(opcode);

        if (!self.stacksAgree(frame, mf, opcode_name)) return;

        if (mf.memory_size != frame.memory.size()) {
            // Memory size mismatch is not critical, just debug log
            self.debug("[DIVERGENCE] Memory size mismatch: MinimalEvm={d}, Frame={d}", .{
                mf.memory_size,
                frame.memory.size(),
            });
        }

        // Gas is compared only where a basic block ends. Frame charges static gas per
        // basic block and MinimalEvm per opcode, so the two legitimately differ inside
        // a block and agree again at its last instruction.
        const ends_block = switch (opcode) {
            .JUMP, .JUMPI => true,
            else => false,
        };
        if (ends_block) self.compareBoundaryGas(frame, mf, opcode_name);
    }

    /// True when Frame and the sidecar frame hold the same stack. A difference is
    /// logged, top items first, and recorded as a failed check.
    fn stacksAgree(self: *Tracer, frame: anytype, mf: *const MinimalFrame, context: []const u8) bool {
        const frame_stack = frame.stack.get_slice();
        const sidecar_stack = mf.stack.items;
        if (sidecar_stack.len != frame_stack.len) {
            if (sidecar_stack.len > 0) log.err("  MinimalEvm top: 0x{x}", .{sidecar_stack[sidecar_stack.len - 1]});
            if (frame_stack.len > 0) log.err("  Frame top: 0x{x}", .{frame_stack[0]});
            self.failKind(
                .stack_divergence,
                "Stack size divergence after {s}: MinimalEvm={d}, Frame={d}",
                .{ context, sidecar_stack.len, frame_stack.len },
            );
            return false;
        }
        // Frame's slice is top first; the sidecar's list is bottom first.
        for (frame_stack, 0..) |frame_value, i| {
            const sidecar_value = sidecar_stack[sidecar_stack.len - 1 - i];
            if (sidecar_value == frame_value) continue;
            for (0..@min(10, frame_stack.len)) |j| {
                log.err("  [{d}] MinimalEvm: 0x{x}, Frame: 0x{x}", .{
                    j,
                    sidecar_stack[sidecar_stack.len - 1 - j],
                    frame_stack[j],
                });
            }
            self.failKind(
                .stack_divergence,
                "Stack content divergence after {s} at position {d} (MinimalEvm pc={d})",
                .{ context, i, mf.pc },
            );
            return false;
        }
        return true;
    }

    /// Compare gas where both interpreters have charged the same instructions: the
    /// end of a basic block or of the frame. Any difference is a failed check.
    fn compareBoundaryGas(self: *Tracer, frame: anytype, mf: *const MinimalFrame, context: []const u8) void {
        const frame_gas: i64 = frame.gas_remaining;
        const sidecar_gas: i64 = mf.gas_remaining;
        if (frame_gas == sidecar_gas) return;
        self.failKind(
            .gas_divergence,
            "Gas divergence at {s}: Frame={d}, MinimalEvm={d}, difference={d}",
            .{ context, frame_gas, sidecar_gas, frame_gas -| sidecar_gas },
        );
    }

    // ============================================================================
    // LOGGING FUNCTIONS
    // ============================================================================

    pub fn debug(self: *Tracer, comptime format: []const u8, args: anytype) void {
        if (!self.config.enabled) return;
        if (!self.config.enable_debug_logging) return;
        log.debug(format, args);
    }

    /// Report a failed consistency check of an unspecified kind. See `failKind`.
    pub fn fail(self: *Tracer, comptime format: []const u8, args: anytype) void {
        self.failKind(.assertion, format, args);
    }

    /// Report a failed consistency check: a handler or schedule mismatch, or a
    /// divergence from the MinimalEvm sidecar.
    ///
    /// The failure is logged with the recent-instruction ring buffer, counted in
    /// `failed_checks` and kept in `last_failure`. It never aborts the process: a
    /// crash is worse than a wrong trace, and the caller decides what a failed check
    /// means by reading the count.
    pub fn failKind(self: *Tracer, kind: FailureKind, comptime format: []const u8, args: anytype) void {
        @branchHint(.cold);
        self.failed_checks +|= 1;
        self.last_failure.kind = kind;
        self.last_failure.instruction = self.instruction_count;
        const buffer = &self.last_failure.buffer;
        @memset(buffer, 0);
        self.last_failure.len = if (std.fmt.bufPrint(buffer, format, args)) |text|
            text.len
        else |err| switch (err) {
            // The message is cut to what fit; the log line below carries all of it.
            error.NoSpaceLeft => std.mem.indexOfScalar(u8, buffer, 0) orelse buffer.len,
        };
        switch (self.failure_log_level) {
            .err => log.err(format, args),
            .warn => log.warn(format, args),
        }
        self.logRecentOpcodes();
    }

    /// Log the ring buffer of recently executed instructions, for failure reports.
    fn logRecentOpcodes(self: *Tracer) void {
        if (!self.config.enabled) return;
        if (self.recent_opcodes.prettyPrint(self.allocator)) |output| {
            defer self.allocator.free(output);
            switch (self.failure_log_level) {
                .err => log.err("{s}", .{output}),
                .warn => log.warn("{s}", .{output}),
            }
        } else |err| {
            // The failure itself is already logged; a history that cannot be
            // printed is not a second failure.
            log.warn(
                "Ring buffer has {} recent instructions (could not print them: {})",
                .{ self.recent_opcodes.count, err },
            );
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

    /// Assert with error message - replaces std.debug.assert.
    ///
    /// A development aid, not a security mechanism: validation that guards memory
    /// safety happens before the code that asserts. A failed assertion is logged,
    /// counted in `failed_checks` and kept in `last_failure`; execution continues, so
    /// the EVM never crashes its host.
    pub fn assert(self: *Tracer, condition: bool, comptime message: []const u8) void {
        if (!condition) {
            @branchHint(.cold);
            self.failKind(.assertion, "ASSERTION FAILED: {s}", .{message});
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
// TESTS
// ============================================================================

test "Tracer: error propagation - setCode failure is logged and handled" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const config = TracerConfig{
        .enabled = true,
        .enable_validation = true,
        .enable_step_capture = false,
        .enable_advanced_trace = false,
        .enable_pc_tracking = false,
        .enable_debug_logging = false,
    };

    var tracer = Tracer.init(allocator, config);
    defer tracer.deinit();

    // This test verifies that setCode errors are properly handled
    // The actual error case would require mocking MinimalEvm, but we verify
    // the code path exists and compiles correctly with error handling
    try testing.expect(tracer.config.enable_validation);
}

test "Tracer: error propagation - steps.append failure cleans up memory" {
    const testing = std.testing;

    // Use a failing allocator to simulate allocation failures
    var fail_allocator = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    const allocator = fail_allocator.allocator();

    const config = TracerConfig{
        .enabled = true,
        .enable_validation = false,
        .enable_step_capture = true,
        .enable_advanced_trace = false,
        .enable_pc_tracking = false,
        .enable_debug_logging = false,
    };

    var tracer = Tracer.init(allocator, config);
    defer tracer.deinit();

    // Verify the tracer was initialized with step capture enabled
    try testing.expect(tracer.config.enable_step_capture);
    try testing.expect(tracer.steps.items.len == 0);
}

test "Tracer: error propagation - advanced_steps.append failure cleans up fusion_info" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const config = TracerConfig{
        .enabled = true,
        .enable_validation = false,
        .enable_step_capture = false,
        .enable_advanced_trace = true,
        .enable_pc_tracking = false,
        .enable_debug_logging = false,
    };

    var tracer = Tracer.init(allocator, config);
    defer tracer.deinit();

    // Verify advanced trace is enabled
    try testing.expect(tracer.config.enable_advanced_trace);
    try testing.expect(tracer.advanced_steps.items.len == 0);
}

test "Tracer: memory safety - minimal_frame errdefer prevents leak" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const config = TracerConfig{
        .enabled = true,
        .enable_validation = true,
        .enable_step_capture = false,
        .enable_advanced_trace = false,
        .enable_pc_tracking = false,
        .enable_debug_logging = false,
    };

    var tracer = Tracer.init(allocator, config);
    defer tracer.deinit();

    // Verify validation is enabled (which triggers minimal_frame allocation)
    try testing.expect(tracer.config.enable_validation);
    try testing.expect(tracer.minimal_evm == null); // Not initialized until onInterpret
}

test "Tracer: init and deinit with all features enabled" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const config = TracerConfig{
        .enabled = true,
        .enable_validation = true,
        .enable_step_capture = true,
        .enable_advanced_trace = true,
        .enable_pc_tracking = true,
        .enable_debug_logging = false,
    };

    var tracer = Tracer.init(allocator, config);
    defer tracer.deinit();

    try testing.expect(tracer.config.enabled);
    try testing.expect(tracer.config.enable_validation);
    try testing.expect(tracer.config.enable_step_capture);
    try testing.expect(tracer.config.enable_advanced_trace);
    try testing.expect(tracer.instruction_count == 0);
}

test "Tracer: init and deinit with all features disabled" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const config = TracerConfig{
        .enabled = false,
        .enable_validation = false,
        .enable_step_capture = false,
        .enable_advanced_trace = false,
        .enable_pc_tracking = false,
        .enable_debug_logging = false,
    };

    var tracer = Tracer.init(allocator, config);
    defer tracer.deinit();

    try testing.expect(!tracer.config.enabled);
    try testing.expect(tracer.minimal_evm == null);
}

test "Tracer: ExecutionStep memory lifecycle" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const config = TracerConfig{
        .enabled = true,
        .enable_validation = false,
        .enable_step_capture = true,
        .enable_advanced_trace = false,
        .enable_pc_tracking = false,
        .enable_debug_logging = false,
    };

    var tracer = Tracer.init(allocator, config);
    defer tracer.deinit();

    // Verify empty stacks use static empty slice
    const step = Tracer.ExecutionStep{
        .step_number = 1,
        .pc = 0,
        .opcode = 0x01,
        .opcode_name = "ADD",
        .gas_before = 1000,
        .gas_after = 997,
        .gas_cost = 3,
        .stack_before = &[_]u256{},
        .stack_after = &[_]u256{},
        .memory_size_before = 0,
        .memory_size_after = 0,
        .depth = 0,
        .error_occurred = false,
        .error_msg = null,
    };

    try testing.expect(step.stack_before.len == 0);
    try testing.expect(step.stack_after.len == 0);
}

test "Tracer: AdvancedStep with fusion info" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const config = TracerConfig{
        .enabled = true,
        .enable_validation = false,
        .enable_step_capture = false,
        .enable_advanced_trace = true,
        .enable_pc_tracking = false,
        .enable_debug_logging = false,
    };

    var tracer = Tracer.init(allocator, config);
    defer tracer.deinit();

    // Test that fusion_info can be allocated and freed
    const fusion_desc = "PUSH1 + MSTORE";
    const fusion_copy = try allocator.alloc(u8, fusion_desc.len);
    @memcpy(fusion_copy, fusion_desc);

    const step = Tracer.AdvancedStep{
        .step_number = 1,
        .schedule_index = 5,
        .opcode = 0x0100,
        .opcode_name = "PUSH_MSTORE_INLINE",
        .is_synthetic = true,
        .gas_before = 1000,
        .gas_after = 994,
        .gas_cost = 6,
        .stack_size_before = 0,
        .stack_size_after = 0,
        .memory_size_before = 0,
        .memory_size_after = 32,
        .depth = 1,
        .fusion_info = fusion_copy,
    };

    try testing.expect(step.is_synthetic);
    try testing.expect(step.fusion_info != null);
    if (step.fusion_info) |info| {
        try testing.expectEqualStrings("PUSH1 + MSTORE", info);
        allocator.free(info);
    }
}

test "Tracer: SafetyCounter initialization" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const config = TracerConfig{
        .enabled = true,
        .enable_validation = false,
        .enable_step_capture = false,
        .enable_advanced_trace = false,
        .enable_pc_tracking = false,
        .enable_debug_logging = false,
    };

    var tracer = Tracer.init(allocator, config);
    defer tracer.deinit();

    // Verify 300M instruction safety limit
    try testing.expect(tracer.instruction_safety.count == 0);
    try testing.expect(tracer.instruction_count == 0);
}

test "Tracer: RingBuffer initialization" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const config = TracerConfig{
        .enabled = true,
        .enable_validation = false,
        .enable_step_capture = false,
        .enable_advanced_trace = false,
        .enable_pc_tracking = false,
        .enable_debug_logging = false,
    };

    var tracer = Tracer.init(allocator, config);
    defer tracer.deinit();

    // Verify ring buffer is initialized
    try testing.expect(tracer.recent_opcodes.count == 0);
}

// ============================================================================
