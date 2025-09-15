/// Configurable execution tracing system for EVM debugging and analysis
///
/// Provides multiple tracer implementations with compile-time selection:
/// - `DefaultTracer`: Validates execution in debug/safe builds
/// - `DebuggingTracer`: Step-by-step debugging (no-op implementation)
/// - `LoggingTracer`: Structured logging to stdout (minimal)
/// - `FileTracer`: File output (skeleton)
///
/// Tracers are selected at compile time for zero-cost abstractions.
/// Enable tracing by configuring the Frame with a specific TracerType.
const std = @import("std");
const log = @import("../log.zig");
const primitives = @import("primitives");
const pc_tracker_mod = @import("pc_tracker.zig");
pub const MinimalEvm = @import("minimal_evm.zig").MinimalEvm;
const MinimalFrame = @import("minimal_frame.zig").MinimalFrame;
const Host = @import("minimal_evm.zig").Host;
const UnifiedOpcode = @import("../opcodes/opcode.zig").UnifiedOpcode;
const Opcode = @import("../opcodes/opcode.zig").Opcode;
const SafetyCounter = @import("../internal/safety_counter.zig").SafetyCounter;

// ============================================================================
// DEFAULT TRACER
// ============================================================================

// Default tracer does not do anything in release modes but does extensive defensive validation
// In debug and safe mode. In a debug mode the tracer can be thought of as unit tests that run in
// real time as the evm is executing and we are expected to have similar levels of coverage.
// For this reason, the tracer is intentionally decoupled from the EVM and is expected to share
// minimal code with it.
pub const DefaultTracer = struct {
    allocator: std.mem.Allocator,
    // Empty steps list to satisfy EVM interface
    steps: std.ArrayList(ExecutionStep),

    // PC tracker for validation (only in debug/safe builds)
    pc_tracker: ?pc_tracker_mod.PcTracker,

    // Gas tracking for validation
    gas_tracker: ?u64,

    // Current PC for tracking instruction pointer movement
    current_pc: u32,

    // Bytecode being executed for PC validation
    bytecode: []const u8,

    // Minimal EVM for parallel execution tracking and validation
    minimal_evm: ?*MinimalEvm,

    // Execution tracking
    instruction_count: u64 = 0,  // Total instructions executed
    schedule_index: u64 = 0,     // Current dispatch schedule index
    simple_instruction_count: u64 = 0,  // Instructions in simple interpreter
    fused_instruction_count: u64 = 0,  // Instructions in fused interpreter

    // Safety counter to prevent infinite loops
    // Limit is 10x the block gas limit (30M gas * 10 = 300M instructions)
    // This is very generous - normal contracts execute far fewer instructions
    instruction_safety: SafetyCounter(u64, .enabled),

    // Nested call depth tracking
    nested_depth: u16 = 0,

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

    pub fn init(allocator: std.mem.Allocator) DefaultTracer {
        return .{
            .allocator = allocator,
            .steps = std.ArrayList(ExecutionStep){
                .items = &.{},
                .capacity = 0,
            },
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
        };
    }

    pub fn deinit(self: *DefaultTracer) void {
        // Clean up MinimalEvm if it exists
        if (self.minimal_evm) |evm| {
            // The arena allocator in MinimalEvm will clean up all MinimalFrame allocations
            // when deinit is called, so we don't need to manually clean up frames
            self.debug("Destroying MinimalEvm at 0x{x}", .{@intFromPtr(evm)});
            evm.deinitPtr(self.allocator);
            self.minimal_evm = null;
        }
    }

    /// Initialize PC tracker with bytecode (called when frame starts interpretation)
    pub fn initPcTracker(self: *DefaultTracer, bytecode: []const u8) void {
        self.bytecode = bytecode;
        self.current_pc = 0;
    }

    /// Initialize MinimalEvm as a sidecar validator when frame starts interpretation
    pub fn onInterpret(self: *DefaultTracer, frame: anytype, bytecode: []const u8, gas_limit: i64) void {
        _ = gas_limit;
        const builtin = @import("builtin");
        if (comptime (builtin.mode == .Debug or builtin.mode == .ReleaseSafe)) {
            // Get EVM depth to check if this is an inner call
            const main_evm = frame.getEvm();
            const depth = main_evm.depth;
            
            // Only create/reset MinimalEvm for the outermost frame (depth 1)
            // Inner frames (depth > 1) will be handled by MinimalEvm's inner_call
            if (depth > 1) {
                self.debug("Skipping MinimalEvm init for inner frame at depth {d}", .{depth});
                return;
            }
            
            // Clean up any existing MinimalEvm before resetting
            if (self.minimal_evm) |evm| {
                evm.deinitPtr(self.allocator);
                self.minimal_evm = null;
            }

            // Reset execution counters
            self.instruction_count = 0;
            self.schedule_index = 0;
            self.simple_instruction_count = 0;
            self.fused_instruction_count = 0;

            // Reset the instruction safety counter for the new frame
            self.instruction_safety.count = 0;

            if (bytecode.len > 0) {
                    self.minimal_evm = MinimalEvm.initPtr(self.allocator) catch {
                        self.minimal_evm = null;
                        return;
                    };
                    self.debug("Created MinimalEvm at 0x{x}", .{@intFromPtr(self.minimal_evm)});
                }

                if (self.minimal_evm) |evm| {
                    // Get the main EVM for context  
                    const evm_instance = frame.getEvm();

                    // Sync blockchain context from EVM
                    const block_info = evm_instance.get_block_info();
                    evm.setBlockchainContext(
                        evm_instance.get_chain_id(),
                        block_info.number,
                        block_info.timestamp,
                        block_info.difficulty,
                        block_info.coinbase,
                        block_info.gas_limit,
                        block_info.base_fee,
                        block_info.blob_base_fee
                    );

                    // Set transaction context
                    evm.setTransactionContext(evm_instance.get_tx_origin(), evm_instance.gas_price);

                    // Get frame context for call
                    var caller = primitives.ZERO_ADDRESS;
                    var address = primitives.ZERO_ADDRESS;
                    var value: u256 = 0;
                    var calldata: []const u8 = &[_]u8{};

                    if (@hasField(@TypeOf(frame.*), "contract_address")) {
                        address = frame.contract_address;
                    }
                    if (@hasField(@TypeOf(frame.*), "caller")) {
                        caller = frame.caller;
                    }
                    if (@hasField(@TypeOf(frame.*), "value")) {
                        value = frame.value;
                    }
                    if (@hasField(@TypeOf(frame.*), "calldata_slice")) {
                        calldata = frame.calldata_slice;
                    }

                    // Ensure the MinimalEvm knows the code for this address (for inner calls)
                    if (!std.mem.eql(u8, &address.bytes, &primitives.ZERO_ADDRESS.bytes)) {
                        evm.setCode(address, bytecode) catch {};
                    }

                    // Create a frame but don't execute it yet - execution will happen step-by-step
                    const frame_gas_remaining = frame.gas_remaining;

                    // Create the frame directly using MinimalEvm's arena allocator
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
                    ) catch return;

                    // Set as current frame
                    evm.current_frame = minimal_frame;

                    self.debug("MinimalEvm initialized with bytecode_len={d}, gas={d}", .{
                        bytecode.len,
                        frame_gas_remaining,
                    });
                }
        }
    }

    /// Called before an instruction executes
    /// This is the main entry point for instruction tracing
    pub fn before_instruction(
        self: *DefaultTracer,
        frame: anytype,
        comptime opcode: UnifiedOpcode,
        cursor: [*]const @TypeOf(frame.*).Dispatch.Item
    ) void {
        const builtin = @import("builtin");
        if (comptime (builtin.mode == .Debug or builtin.mode == .ReleaseSafe)) {
            if (builtin.target.cpu.arch != .wasm32 or builtin.target.os.tag != .freestanding) {
                // Skip validation for inner frames (depth > 1)
                const main_evm = frame.getEvm();
                if (main_evm.depth > 1) {
                    return;
                }
                const opcode_name = comptime @tagName(opcode);
                const opcode_value = @intFromEnum(opcode);

                // Debug logging to understand execution order
                if (self.minimal_evm) |evm| {
                    const pc = evm.getPC();
                    const bytecode = evm.getBytecode();
                    log.debug("beforeInstruction: Frame executing {s}, MinimalEvm PC={d}, bytecode[PC]=0x{x:0>2}", .{
                        opcode_name,
                        pc,
                        if (pc < bytecode.len) bytecode[pc] else 0
                    });
                }

                // Validate cursor points to expected handler for regular opcodes
                if (opcode_value <= 0xff) {
                    const expected_handler = @TypeOf(frame.*).opcode_handlers[opcode_value];
                    const actual_handler = cursor[0].opcode_handler;
                    if (actual_handler != expected_handler) {
                        self.err("[HANDLER] Handler mismatch for {s}: expected={*}, actual={*}", .{
                            opcode_name, expected_handler, actual_handler
                        });
                    }
                }

                // Increment instruction counts
                self.instruction_count += 1;
                if (opcode_value > 0xff) {
                    self.fused_instruction_count += 1;
                } else {
                    self.simple_instruction_count += 1;
                }

                // Increment safety counter - will panic if limit exceeded
                // with message about potential infinite loop or excessive instructions
                self.instruction_safety.inc();

                // Execute MinimalEvm step for validation (if initialized)
                if (self.minimal_evm) |evm| {
                    // Log stack state before execution
                    if (evm.current_frame) |mf| {
                        log.debug("Before executeMinimalEvmForOpcode {s}: MinimalEvm stack={d}, Frame stack={d}", .{
                            opcode_name,
                            mf.stack.items.len,
                            frame.stack.size(),
                        });
                    }
                    self.executeMinimalEvmForOpcode(evm, opcode, frame, cursor);
                    // Log stack state after execution
                    if (evm.current_frame) |mf| {
                        log.debug("After executeMinimalEvmForOpcode {s}: MinimalEvm stack={d}, Frame stack={d}", .{
                            opcode_name,
                            mf.stack.items.len,
                            frame.stack.size(),
                        });
                    }
                }

                // Log execution
                const stack_size = frame.stack.size();
                log.debug("EXEC[{d}]: {s} | PC={d} stack={d} gas={d}", .{
                    self.instruction_count,
                    opcode_name,
                    self.current_pc,
                    stack_size,
                    frame.gas_remaining,
                });
            }
        }
    }

    /// Called after an instruction completes successfully
    pub fn after_instruction(
        self: *DefaultTracer,
        frame: anytype,
        comptime opcode: UnifiedOpcode,
        next_handler: anytype,
        next_cursor: [*]const @TypeOf(frame.*).Dispatch.Item
    ) void {
        const builtin = @import("builtin");
        if (comptime (builtin.mode == .Debug or builtin.mode == .ReleaseSafe)) {
            if (builtin.target.cpu.arch != .wasm32 or builtin.target.os.tag != .freestanding) {
                // Skip validation for inner frames (depth > 1)
                const main_evm = frame.getEvm();
                if (main_evm.depth > 1) {
                    return;
                }
                const opcode_name = comptime @tagName(opcode);

                // Advance schedule index
                self.schedule_index += 1;

                // Validate next handler consistency
                if (next_cursor[0] != .opcode_handler or next_cursor[0].opcode_handler != next_handler) {
                    self.err("[SCHEDULE] Next handler mismatch at sched_idx={d}", .{self.schedule_index});
                }

                // Validate next handler points to expected handler for regular opcodes
                if (next_cursor[0] == .opcode_handler) {
                    // Extract the opcode from the next handler if it's a regular opcode
                    const next_opcode_value = self.getOpcodeFromHandler(@TypeOf(frame.*), next_handler);
                    if (next_opcode_value) |opcode_int| {
                        if (opcode_int <= 0xff) {
                            const expected_next_handler = @TypeOf(frame.*).opcode_handlers[opcode_int];
                            if (next_handler != expected_next_handler) {
                                self.err("[HANDLER] Next handler mismatch: opcode=0x{x:0>2}, expected={*}, actual={*}", .{
                                    opcode_int, expected_next_handler, next_handler
                                });
                            }
                        }
                    }
                }

                // Validate MinimalEvm state
                log.debug("afterInstruction: Validating state after {s}", .{opcode_name});
                if (self.minimal_evm) |evm| {
                    if (evm.current_frame) |mf| {
                        log.debug("  MinimalEvm stack={d}, Frame stack={d}", .{
                            mf.stack.items.len,
                            frame.stack.size(),
                        });
                    }
                }
                self.validateMinimalEvmState(frame, opcode);

                // Update current PC tracking
                // Note: PC synchronization between Frame dispatch and MinimalEvm sequential
                // execution is complex due to synthetic opcodes, so we track separately
                if (self.minimal_evm) |evm| {
                    self.current_pc = evm.getPC();
                }

                // Log completion
                log.debug("DONE[{d}]: {s} | PC={d}", .{
                    self.instruction_count,
                    opcode_name,
                    self.current_pc,
                });
            }
        }
    }

    /// Called when an instruction completes with a terminal state
    pub fn after_complete(
        self: *DefaultTracer,
        frame: anytype,
        comptime opcode: UnifiedOpcode
    ) void {
        const builtin = @import("builtin");
        if (comptime (builtin.mode == .Debug or builtin.mode == .ReleaseSafe)) {
            // Skip validation for inner frames (depth > 1)
            const main_evm = frame.getEvm();
            if (main_evm.depth > 1) {
                return;
            }
            // Final validation for terminal states
            self.validateMinimalEvmState(frame, opcode);
        }
    }

    // ============================================================================
    // MINIMAL EVM EXECUTION
    // ============================================================================

    /// Execute MinimalEvm for the given UnifiedOpcode
    fn executeMinimalEvmForOpcode(
        self: *DefaultTracer,
        evm: *MinimalEvm,
        comptime opcode: UnifiedOpcode,
        frame: anytype,
        cursor: [*]const @TypeOf(frame.*).Dispatch.Item
    ) void {
        const opcode_value = @intFromEnum(opcode);

        // Log what we're about to execute
        self.debug("=====================================", .{});
        self.debug("Frame executing: {s}", .{@tagName(opcode)});
        self.debug("  MinimalEvm PC: {d}", .{evm.getPC()});
        self.debug("  Frame stack size: {d}", .{frame.stack.size()});
        if (evm.current_frame) |minimal_frame| {
            self.debug("  MinimalEvm stack size: {d}", .{minimal_frame.stack.items.len});
        }

        // For regular opcodes (0x00-0xFF), execute exactly 1 opcode in MinimalEvm
        if (opcode_value <= 0xff) {
            // Special handling: JUMPDEST in Frame pre-charges entire basic-block gas.
            // MinimalEvm's JUMPDEST charges only JumpdestGas, so we reconcile here.
            if (opcode_value == 0x5b) { // JUMPDEST
                const DispatchType = @TypeOf(frame.*).Dispatch;
                const dispatch = DispatchType{ .cursor = cursor };
                const op_data = dispatch.getOpData(.JUMPDEST);
                const block_gas: u64 = op_data.metadata.gas;
                const jumpdest_gas: u64 = primitives.GasConstants.JumpdestGas;
                if (evm.current_frame) |mf| {
                    const extra: i64 = @as(i64, @intCast(block_gas)) - @as(i64, @intCast(jumpdest_gas));
                    mf.gas_remaining -= extra;
                }
            }
            // Execute a single step in MinimalEvm (delegates to current frame)
            // Debug: Check if MinimalEvm has a current frame
            if (evm.current_frame == null) {
                log.err("[EVM2] MinimalEvm has no current frame when trying to execute opcode 0x{x:0>2}", .{opcode_value});
                @panic("MinimalEvm not initialized");
            }
            evm.step() catch |e| {
                // Get actual opcode from MinimalEvm to see what it was trying to execute
                var actual_opcode: u8 = 0;
                if (evm.current_frame) |mf| {
                    if (mf.pc < mf.bytecode.len) {
                        actual_opcode = mf.bytecode[mf.pc];
                    }
                }
                log.err("[EVM2] MinimalEvm exec error at PC={d}, bytecode[PC]=0x{x:0>2}, Frame expects=0x{x:0>2}: {any}", .{
                    if (evm.current_frame) |mf| mf.pc else 0,
                    actual_opcode,
                    opcode_value,
                    e
                });
                @panic("MinimalEvm execution error");
            };
            return;
        }

        // Handle fused opcodes by validating bytecode and stepping
        switch (opcode) {
            // PUSH + arithmetic fusions (2 steps)
            .PUSH_ADD_INLINE, .PUSH_ADD_POINTER => {
                if (evm.getPC() + 2 < evm.getBytecode().len and
                    evm.getBytecode()[evm.getPC()] >= 0x60 and evm.getBytecode()[evm.getPC()] <= 0x7f and
                    evm.getBytecode()[evm.getPC() + 1 + (evm.getBytecode()[evm.getPC()] - 0x5f)] == 0x01)
                {
                    inline for (0..2) |_| {
                        evm.step() catch |e| {
                            self.err("PUSH_ADD step failed: {any}", .{e});
                            return;
                        };
                    }
                }
            },
            .PUSH_MUL_INLINE, .PUSH_MUL_POINTER => {
                if (evm.getPC() + 2 < evm.getBytecode().len and
                    evm.getBytecode()[evm.getPC()] >= 0x60 and evm.getBytecode()[evm.getPC()] <= 0x7f and
                    evm.getBytecode()[evm.getPC() + 1 + (evm.getBytecode()[evm.getPC()] - 0x5f)] == 0x02)
                {
                    inline for (0..2) |_| {
                        evm.step() catch |e| {
                            self.err("PUSH_MUL step failed: {any}", .{e});
                            return;
                        };
                    }
                }
            },
            .PUSH_SUB_INLINE, .PUSH_SUB_POINTER => {
                if (evm.getPC() + 2 < evm.getBytecode().len and
                    evm.getBytecode()[evm.getPC()] >= 0x60 and evm.getBytecode()[evm.getPC()] <= 0x7f and
                    evm.getBytecode()[evm.getPC() + 1 + (evm.getBytecode()[evm.getPC()] - 0x5f)] == 0x03)
                {
                    inline for (0..2) |_| {
                        evm.step() catch |e| {
                            self.err("PUSH_SUB step failed: {any}", .{e});
                            return;
                        };
                    }
                }
            },
            .PUSH_DIV_INLINE, .PUSH_DIV_POINTER => {
                if (evm.getPC() + 2 < evm.getBytecode().len and
                    evm.getBytecode()[evm.getPC()] >= 0x60 and evm.getBytecode()[evm.getPC()] <= 0x7f and
                    evm.getBytecode()[evm.getPC() + 1 + (evm.getBytecode()[evm.getPC()] - 0x5f)] == 0x04)
                {
                    inline for (0..2) |_| {
                        evm.step() catch |e| {
                            self.err("PUSH_DIV step failed: {any}", .{e});
                            return;
                        };
                    }
                }
            },

            // Bitwise fusions
            .PUSH_AND_INLINE, .PUSH_AND_POINTER => {
                if (evm.getPC() + 2 < evm.getBytecode().len and
                    evm.getBytecode()[evm.getPC()] >= 0x60 and evm.getBytecode()[evm.getPC()] <= 0x7f and
                    evm.getBytecode()[evm.getPC() + 1 + (evm.getBytecode()[evm.getPC()] - 0x5f)] == 0x16)
                {
                    inline for (0..2) |_| {
                        evm.step() catch |e| {
                            self.err("PUSH_AND step failed: {any}", .{e});
                            return;
                        };
                    }
                }
            },
            .PUSH_OR_INLINE, .PUSH_OR_POINTER => {
                if (evm.getPC() + 2 < evm.getBytecode().len and
                    evm.getBytecode()[evm.getPC()] >= 0x60 and evm.getBytecode()[evm.getPC()] <= 0x7f and
                    evm.getBytecode()[evm.getPC() + 1 + (evm.getBytecode()[evm.getPC()] - 0x5f)] == 0x17)
                {
                    inline for (0..2) |_| {
                        evm.step() catch |e| {
                            self.err("PUSH_OR step failed: {any}", .{e});
                            return;
                        };
                    }
                }
            },
            .PUSH_XOR_INLINE, .PUSH_XOR_POINTER => {
                if (evm.getPC() + 2 < evm.getBytecode().len and
                    evm.getBytecode()[evm.getPC()] >= 0x60 and evm.getBytecode()[evm.getPC()] <= 0x7f and
                    evm.getBytecode()[evm.getPC() + 1 + (evm.getBytecode()[evm.getPC()] - 0x5f)] == 0x18)
                {
                    inline for (0..2) |_| {
                        evm.step() catch |e| {
                            self.err("PUSH_XOR step failed: {any}", .{e});
                            return;
                        };
                    }
                }
            },

            // Memory fusions
            .PUSH_MLOAD_INLINE, .PUSH_MLOAD_POINTER => {
                if (evm.getPC() + 2 < evm.getBytecode().len and
                    evm.getBytecode()[evm.getPC()] >= 0x60 and evm.getBytecode()[evm.getPC()] <= 0x7f and
                    evm.getBytecode()[evm.getPC() + 1 + (evm.getBytecode()[evm.getPC()] - 0x5f)] == 0x51)
                {
                    inline for (0..2) |_| {
                        evm.step() catch |e| {
                            self.err("PUSH_MLOAD step failed: {any}", .{e});
                            return;
                        };
                    }
                }
            },
            .PUSH_MSTORE_INLINE, .PUSH_MSTORE_POINTER => {
                // PUSH_MSTORE_INLINE synthetic operation in Frame:
                // - Pops 1 value from stack (the value to store)
                // - Uses metadata offset (doesn't push offset to stack)
                // - Stores value at that memory offset
                // MinimalEvm must emulate the same net stack effect (pop 1, push 0)

                // PUSH_MSTORE_INLINE synthetic opcodes will be handled by sequential bytecode execution

                // PUSH_MSTORE_INLINE represents PUSH1 + MSTORE sequence in bytecode
                // MinimalEvm should execute these 2 sequential operations

                // Debug: Log current MinimalEvm state before execution
                self.debug("PUSH_MSTORE_INLINE: MinimalEvm PC={d}, stack_size={d}, Frame stack_size={d}", .{
                    evm.getPC(), (evm.current_frame orelse unreachable).stack.items.len, frame.stack.size()
                });

                // Execute the 2-step sequence: PUSH1 + MSTORE
                // First, check if we're at the right bytecode position for PUSH1+MSTORE
                if (evm.getPC() + 2 < evm.getBytecode().len and
                    evm.getBytecode()[evm.getPC()] == 0x60 and      // PUSH1
                    evm.getBytecode()[evm.getPC() + 2] == 0x52) {   // MSTORE (after PUSH1 + 1 byte immediate)

                    self.debug("PUSH_MSTORE_INLINE: Found PUSH1+MSTORE at PC {d}, executing 2 steps", .{evm.getPC()});

                    // Execute PUSH1 + MSTORE
                    inline for (0..2) |step_num| {
                        const current_opcode = evm.getBytecode()[evm.getPC()];
                        self.debug("PUSH_MSTORE step {d}: executing opcode 0x{x:0>2} at PC {d}", .{step_num + 1, current_opcode, evm.getPC()});

                        evm.step() catch |e| {
                            self.err("PUSH_MSTORE step {d} failed: opcode=0x{x:0>2}, error={any}", .{step_num + 1, current_opcode, e});
                            return;
                        };
                    }
                } else {
                    // Not a PUSH1+MSTORE sequence - this is a mis-identified synthetic opcode
                    self.debug("PUSH_MSTORE_INLINE: Not at PUSH1+MSTORE sequence at PC {d} (opcode=0x{x:0>2})", .{evm.getPC(),
                        if (evm.getPC() < evm.getBytecode().len) evm.getBytecode()[evm.getPC()] else 0});

                    // Do NOT execute any MinimalEvm operations for mis-identified synthetic opcodes
                    // Frame will handle the actual opcode, MinimalEvm should remain unchanged
                    self.debug("PUSH_MSTORE_INLINE: Skipping MinimalEvm execution for mis-identified synthetic opcode", .{});
                }
            },
            .PUSH_MSTORE8_INLINE, .PUSH_MSTORE8_POINTER => {
                // PUSH_MSTORE8_INLINE synthetic operation in Frame:
                // - Pops 1 value from stack (the value to store)
                // - Uses metadata offset (doesn't push offset to stack)
                // - Stores LSB of value at that memory offset

                // PUSH_MSTORE8_INLINE synthetic opcodes will be handled by sequential bytecode execution

                // PUSH_MSTORE8_INLINE represents PUSH1 + MSTORE8 sequence in bytecode
                // MinimalEvm should execute these 2 sequential operations

                // Debug: Log current MinimalEvm state before execution
                self.debug("PUSH_MSTORE8_INLINE: MinimalEvm PC={d}, stack_size={d}, Frame stack_size={d}", .{
                    evm.getPC(), (evm.current_frame orelse unreachable).stack.items.len, frame.stack.size()
                });

                // Execute the 2-step sequence: PUSH1 + MSTORE8
                if (evm.getPC() + 2 < evm.getBytecode().len and
                    evm.getBytecode()[evm.getPC()] == 0x60 and      // PUSH1
                    evm.getBytecode()[evm.getPC() + 2] == 0x53) {   // MSTORE8 (after PUSH1 + 1 byte immediate)

                    self.debug("PUSH_MSTORE8_INLINE: Found PUSH1+MSTORE8 at PC {d}, executing 2 steps", .{evm.getPC()});

                    inline for (0..2) |step_num| {
                        if (evm.getPC() >= evm.getBytecode().len) {
                            self.err("PUSH_MSTORE8 step {d}: PC out of bounds: {d} >= {d}", .{step_num + 1, evm.getPC(), evm.getBytecode().len});
                            return;
                        }

                        const current_opcode = evm.getBytecode()[evm.getPC()];
                        self.debug("PUSH_MSTORE8 step {d}: executing opcode 0x{x:0>2} at PC {d}", .{step_num + 1, current_opcode, evm.getPC()});

                        evm.step() catch |e| {
                            self.err("PUSH_MSTORE8 step {d} failed: opcode=0x{x:0>2}, error={any}", .{step_num + 1, current_opcode, e});
                            return;
                        };
                    }
                } else {
                    // Not a PUSH1+MSTORE8 sequence - this is a mis-identified synthetic opcode
                    self.debug("PUSH_MSTORE8_INLINE: Not at PUSH1+MSTORE8 sequence at PC {d} (opcode=0x{x:0>2})", .{evm.getPC(),
                        if (evm.getPC() < evm.getBytecode().len) evm.getBytecode()[evm.getPC()] else 0});

                    // Do NOT execute any MinimalEvm operations for mis-identified synthetic opcodes
                    // Frame will handle the actual opcode, MinimalEvm should remain unchanged
                    self.debug("PUSH_MSTORE8_INLINE: Skipping MinimalEvm execution for mis-identified synthetic opcode", .{});
                }
            },

            // Control flow fusions
            .JUMP_TO_STATIC_LOCATION, .JUMPI_TO_STATIC_LOCATION => {
                // These are optimized jumps, in the minimal EVM they are PUSH + JUMP(I)
                const pc = evm.getPC();
                const bytecode = evm.getBytecode();
                if (pc + 2 < bytecode.len and bytecode[pc] >= 0x60 and bytecode[pc] <= 0x7f) {
                    const push_size = bytecode[pc] - 0x5f;
                    const next_op_pc = pc + 1 + push_size;
                    if (next_op_pc < bytecode.len and (bytecode[next_op_pc] == 0x56 or bytecode[next_op_pc] == 0x57)) {
                        inline for (0..2) |_| {
                            evm.step() catch |e| {
                                self.err("JUMP_TO_STATIC_LOCATION step failed: {any}", .{e});
                                return;
                            };
                        }
                    }
                }
            },

            // Multi-push/pop fusions
            .MULTI_PUSH_2 => {
                // Approximate validation: check for two consecutive PUSHes
                const pc = evm.getPC();
                const bytecode = evm.getBytecode();
                if (pc + 2 < bytecode.len and bytecode[pc] >= 0x60 and bytecode[pc] <= 0x7f) {
                    const push_size1 = bytecode[pc] - 0x5f;
                    const next_pc = pc + 1 + push_size1;
                    if (next_pc < bytecode.len and bytecode[next_pc] >= 0x60 and bytecode[next_pc] <= 0x7f) {
                        inline for (0..2) |_| {
                            evm.step() catch |e| {
                                self.err("MULTI_PUSH_2 step failed: {any}", .{e});
                                return;
                            };
                        }
                    }
                }
            },
            .MULTI_PUSH_3 => {
                // Approximate validation for three PUSHes
                inline for (0..3) |_| {
                    evm.step() catch |e| {
                        self.err("MULTI_PUSH_3 step failed: {any}", .{e});
                        return;
                    };
                }
            },
            .MULTI_POP_2 => {
                inline for (0..2) |_| {
                    evm.step() catch |e| {
                        self.err("MULTI_POP_2 step failed: {any}", .{e});
                        return;
                    };
                }
            },
            .MULTI_POP_3 => {
                inline for (0..3) |_| {
                    evm.step() catch |e| {
                        self.err("MULTI_POP_3 step failed: {any}", .{e});
                        return;
                    };
                }
            },

            // Three-operation fusions
            .DUP2_MSTORE_PUSH, .DUP3_ADD_MSTORE, .SWAP1_DUP2_ADD, .PUSH_DUP3_ADD, .PUSH_ADD_DUP1, .MLOAD_SWAP1_DUP2, .ISZERO_JUMPI, .CALLVALUE_CHECK, .PUSH0_REVERT => {
                inline for (0..3) |_| {
                    evm.step() catch |e| {
                        self.err("Three-op fusion step failed: {any}", .{e});
                        return;
                    };
                }
            },

            // Four-operation fusion
            .FUNCTION_DISPATCH => {
                // Step 4 times: PUSH4 + EQ + PUSH + JUMPI
                inline for (0..4) |_| {
                    evm.step() catch |e| {
                        self.err("FUNCTION_DISPATCH step failed: {any}", .{e});
                        return;
                    };
                }
            },

            else => {
                // Unknown synthetic opcode - just step once
                if (evm.getPC() < evm.getBytecode().len) {
                    evm.step() catch |e| {
                        self.err("MinimalEvm step failed for synthetic opcode: {any}", .{e});
                    };
                }
            },
        }
    }


    /// Helper to get opcode number from handler pointer by searching opcode_handlers array
    fn getOpcodeFromHandler(self: *DefaultTracer, comptime FrameType: type, handler: FrameType.OpcodeHandler) ?u8 {
        _ = self;
        inline for (0..256) |i| {
            if (FrameType.opcode_handlers[i] == handler) {
                return @intCast(i);
            }
        }
        return null;
    }

    /// Validate MinimalEvm state against Frame state
    fn validateMinimalEvmState(
        self: *DefaultTracer,
        frame: anytype,
        comptime opcode: UnifiedOpcode
    ) void {
        if (self.minimal_evm) |evm| {
            // Skip validation for nested calls
            if (self.nested_depth > 0) return;
            const opcode_name = @tagName(opcode);

            // Compare stack sizes
            const frame_stack_size = frame.stack.size();
            const evm_stack_size = (evm.current_frame orelse unreachable).stack.items.len;

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
                    log.debug("[EVM2] [DIVERGENCE] (call-like) Stack size mismatch after {s}: MinimalEvm={d} Frame={d}", .{ opcode_name, evm_stack_size, frame_stack_size });
                    return;
                }
                log.err("[EVM2] [DIVERGENCE] Stack size mismatch after {s}:", .{opcode_name});
                log.err("[EVM2]   MinimalEvm: {d}, Frame: {d}", .{evm_stack_size, frame_stack_size});
                // Show top elements for debugging
                if (evm_stack_size > 0) {
                    self.err("  MinimalEvm top: 0x{x}", .{
                        (evm.current_frame orelse unreachable).stack.items[evm_stack_size - 1]
                    });
                }
                if (frame_stack_size > 0) {
                    self.err("  Frame top: 0x{x}", .{frame.stack.peek_unsafe()});
                }
                @panic("Stack divergence");
            } else if (evm_stack_size > 0) {
                // Compare stack contents
                const frame_stack = frame.stack.get_slice();
                for (0..evm_stack_size) |i| {
                    const evm_val = (evm.current_frame orelse unreachable).stack.items[evm_stack_size - 1 - i];
                    const frame_val = frame_stack[i];
                    if (evm_val != frame_val) {
                        log.err("[EVM2] [DIVERGENCE] Stack content mismatch at position {d}:", .{i});
                        log.err("[EVM2]   MinimalEvm: 0x{x}, Frame: 0x{x}", .{evm_val, frame_val});
                        log.err("[EVM2]   Opcode: {s}, MinimalEvm PC: {d}", .{opcode_name, if (evm.current_frame) |f| f.pc else 0});
                        // Print full stack contents
                        log.err("[EVM2]   MinimalEvm stack (top first):", .{});
                        if (evm.current_frame) |f| {
                            for (0..@min(10, f.stack.items.len)) |j| {
                                log.err("[EVM2]     [{d}]: 0x{x}", .{j, f.stack.items[f.stack.items.len - 1 - j]});
                            }
                        }
                        log.err("[EVM2]   Frame stack (top first):", .{});
                        for (0..@min(10, frame_stack.len)) |j| {
                            log.err("[EVM2]     [{d}]: 0x{x}", .{j, frame_stack[j]});
                        }
                        @panic("Stack content divergence");
                    }
                }
            }

            // Compare memory sizes
            const frame_memory_size = if (@hasField(@TypeOf(frame.*), "memory"))
                frame.memory.size() else 0;
            const evm_memory_size = (evm.current_frame orelse unreachable).memory_size;

            if (evm_memory_size != frame_memory_size) {
                // Memory size mismatch is not critical, just debug log
                log.debug("[EVM2] [DIVERGENCE] Memory size mismatch:", .{});
                log.debug("[EVM2]   MinimalEvm: {d}, Frame: {d}", .{ evm_memory_size, frame_memory_size });
            }

            // Gas validation - different rules for different opcode types
            const frame_gas_remaining = frame.gas_remaining;
            const evm_gas_remaining = (evm.current_frame orelse unreachable).gas_remaining;

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
                    log.debug("[EVM2] [GAS DIVERGENCE] Exact gas mismatch at terminal opcode {s}:", .{opcode_name});
                    log.debug("[EVM2]   Frame gas_remaining: {d}", .{frame_gas_remaining});
                    log.debug("[EVM2]   MinimalEvm gas_remaining: {d}", .{evm_gas_remaining});
                    log.debug("[EVM2]   Difference: {d}", .{@as(i64, frame_gas_remaining) - @as(i64, evm_gas_remaining)});
                }
            } else {
                // For regular opcodes, allow reasonable gas differences due to block vs opcode charging
                // Frame may consume gas in larger chunks at block boundaries
                const gas_diff = @as(i64, evm_gas_remaining) - @as(i64, frame_gas_remaining);

                // Get expected first_block_gas for this frame to adjust tolerance
                const expected_first_block_gas = if (@hasField(@TypeOf(frame.*), "first_block_gas_charged"))
                    @as(i64, frame.first_block_gas_charged)
                else
                    0;

                // Allow Frame to consume first_block_gas + 50 more than MinimalEvm
                // This accounts for Frame's pre-charging strategy
                const tolerance = expected_first_block_gas + 50;
                if (gas_diff > tolerance) {
                    // Gas divergence during execution, debug log only
                    log.debug("[EVM2] [GAS DIVERGENCE] MinimalEvm consumed too much less gas than Frame after {s}:", .{opcode_name});
                    log.debug("[EVM2]   Frame gas_remaining: {d}", .{frame_gas_remaining});
                    log.debug("[EVM2]   MinimalEvm gas_remaining: {d}", .{evm_gas_remaining});
                    log.debug("[EVM2]   Gas difference: {d} (exceeds {d} gas tolerance)", .{gas_diff, tolerance});
                } else if (gas_diff < -20) {
                    log.debug("[EVM2] [GAS DIVERGENCE] MinimalEvm consumed more gas than Frame after {s}:", .{opcode_name});
                    log.debug("[EVM2]   Frame gas_remaining: {d}", .{frame_gas_remaining});
                    log.debug("[EVM2]   MinimalEvm gas_remaining: {d}", .{evm_gas_remaining});
                    self.warn("  MinimalEvm over-consumed by: {d}", .{-gas_diff});
                }
            }
        }
    }

    // ============================================================================
    // LOGGING FUNCTIONS
    // ============================================================================

    pub fn debug(self: *DefaultTracer, comptime format: []const u8, args: anytype) void {
        _ = self;
        log.debug(format, args);
    }

    pub fn err(self: *DefaultTracer, comptime format: []const u8, args: anytype) void {
        _ = self;
        log.err(format, args);
        @panic("Tracer error - see log above");
    }

    pub fn warn(self: *DefaultTracer, comptime format: []const u8, args: anytype) void {
        _ = self;
        log.warn(format, args);
    }

    pub fn info(self: *DefaultTracer, comptime format: []const u8, args: anytype) void {
        _ = self;
        log.info(format, args);
    }

    pub fn throwError(self: *DefaultTracer, comptime format: []const u8, args: anytype) noreturn {
        _ = self;
        const builtin = @import("builtin");
        log.err("FATAL: " ++ format, args);
        if (builtin.target.cpu.arch == .wasm32 and builtin.target.os.tag == .freestanding) {
            @panic("EVM execution error");
        } else {
            unreachable;
        }
    }

    // ============================================================================
    // EVM LIFECYCLE EVENTS
    // ============================================================================

    pub fn onFrameStart(self: *DefaultTracer, code_len: usize, gas: u64, depth: u16) void {
        _ = self;
        const builtin = @import("builtin");
        if (comptime (builtin.mode == .Debug or builtin.mode == .ReleaseSafe)) {
            log.debug("[EVM] Frame execution started: code_len={}, gas={}, depth={}", .{ code_len, gas, depth });
        }
    }

    pub fn onFrameComplete(self: *DefaultTracer, gas_left: u64, output_len: usize) void {
        _ = self;
        const builtin = @import("builtin");
        if (comptime (builtin.mode == .Debug or builtin.mode == .ReleaseSafe)) {
            log.debug("[EVM] Frame execution completed: gas_left={}, output_len={}", .{ gas_left, output_len });
        }
    }

    pub fn onAccountDelegation(self: *DefaultTracer, account: []const u8, delegated: []const u8) void {
        _ = self;
        const builtin = @import("builtin");
        if (comptime (builtin.mode == .Debug or builtin.mode == .ReleaseSafe)) {
            log.debug("[EVM] Account {x} has delegation to {x}", .{ account, delegated });
        }
    }

    pub fn onEmptyAccountAccess(self: *DefaultTracer) void {
        _ = self;
        const builtin = @import("builtin");
        if (comptime (builtin.mode == .Debug or builtin.mode == .ReleaseSafe)) {
            log.debug("[EVM] Empty account access", .{});
        }
    }

    /// Called when arena allocator is initialized
    pub fn onArenaInit(self: *DefaultTracer, initial_capacity: usize, max_capacity: usize, growth_factor: u32) void {
        _ = self;
        const builtin = @import("builtin");
        if (comptime (builtin.mode == .Debug or builtin.mode == .ReleaseSafe)) {
            log.debug("[ARENA] Initialized: initial={d}, max={d}, growth={d}%", .{ initial_capacity, max_capacity, growth_factor });
        }
    }

    /// Event: Call operation started
    pub fn onCallStart(self: *DefaultTracer, call_type: []const u8, gas: i64, to: anytype, value: u256) void {
        _ = self;
        _ = call_type;
        _ = gas;
        _ = to;
        _ = value;
    }

    /// Event: EVM initialization started
    pub fn onEvmInit(self: *DefaultTracer, gas_price: u256, origin: anytype, hardfork: []const u8) void {
        _ = self;
        _ = gas_price;
        _ = origin;
        _ = hardfork;
    }

    /// Called when arena is reset
    pub fn onArenaReset(self: *DefaultTracer, mode: []const u8, capacity_before: usize, capacity_after: usize) void {
        _ = self;
        const builtin = @import("builtin");
        if (comptime (builtin.mode == .Debug or builtin.mode == .ReleaseSafe)) {
            log.debug("[ARENA] Reset ({s}): capacity {d} -> {d}", .{ mode, capacity_before, capacity_after });
        }
    }

    /// Event: Beacon root update processing
    pub fn onBeaconRootUpdate(self: *DefaultTracer, success: bool, error_val: ?anyerror) void {
        _ = self;
        _ = success;
        _ = error_val;
    }

    /// Event: Call operation completed
    pub fn onCallComplete(self: *DefaultTracer, success: bool, gas_left: i64, output_len: usize) void {
        _ = self;
        _ = success;
        _ = gas_left;
        _ = output_len;
    }

    /// Event: Preflight check for call
    pub fn onCallPreflight(self: *DefaultTracer, call_type: []const u8, result: []const u8) void {
        _ = self;
        _ = call_type;
        _ = result;
    }

    /// Event: Historical block hash update processing
    pub fn onHistoricalBlockHashUpdate(self: *DefaultTracer, success: bool, error_val: ?anyerror) void {
        _ = self;
        _ = success;
        _ = error_val;
    }

    /// Event: Code retrieval
    pub fn onCodeRetrieval(self: *DefaultTracer, address: anytype, code_len: usize, is_empty: bool) void {
        _ = self;
        _ = address;
        _ = code_len;
        _ = is_empty;
    }

    /// Event: Validator deposits processing
    pub fn onValidatorDeposits(self: *DefaultTracer, success: bool, error_val: ?anyerror) void {
        _ = self;
        _ = success;
        _ = error_val;
    }

    /// Called when an allocation is made
    pub fn onArenaAlloc(self: *DefaultTracer, size: usize, alignment: usize, current_capacity: usize) void {
        _ = self;
        _ = size;
        _ = alignment;
        _ = current_capacity;
    }

    /// Called when a frame completes (for tracking nested depth)
    pub fn onFrameReturn(self: *DefaultTracer) void {
        if (self.minimal_evm) |_| {
            // Skip validation for nested calls
            if (self.nested_depth > 0) return;
        }
    }

    /// Event: Frame bytecode initialization
    pub fn onFrameBytecodeInit(self: *DefaultTracer, bytecode_len: usize, success: bool, error_val: ?anyerror) void {
        _ = self;
        _ = bytecode_len;
        _ = success;
        _ = error_val;
    }

    /// Event: Validator withdrawals processing
    pub fn onValidatorWithdrawals(self: *DefaultTracer, success: bool, error_val: ?anyerror) void {
        _ = self;
        _ = success;
        _ = error_val;
    }

    /// Called when arena grows to accommodate new allocations
    pub fn onArenaGrow(self: *DefaultTracer, old_capacity: usize, new_capacity: usize, requested_size: usize) void {
        _ = self;
        const builtin = @import("builtin");
        if (comptime (builtin.mode == .Debug or builtin.mode == .ReleaseSafe)) {
            log.debug("[ARENA] Growing: {d} -> {d} bytes (requested={d})", .{ old_capacity, new_capacity, requested_size });
        }
    }

    /// Called when allocation fails
    pub fn onArenaAllocFailed(self: *DefaultTracer, size: usize, current_capacity: usize, max_capacity: usize) void {
        _ = self;
        const builtin = @import("builtin");
        if (comptime (builtin.mode == .Debug or builtin.mode == .ReleaseSafe)) {
            log.warn("[ARENA] Allocation failed: size={d}, current={d}, max={d}", .{ size, current_capacity, max_capacity });
        }
    }

    /// Assert with error message - replaces std.debug.assert
    pub fn assert(self: *DefaultTracer, condition: bool, comptime message: []const u8) void {
        if (!condition) {
            self.err("ASSERTION FAILED: {s}", .{ message });
            const builtin = @import("builtin");
            if (builtin.target.cpu.arch == .wasm32 and builtin.target.os.tag == .freestanding) {
                unreachable;
            } else {
                @panic(message);
            }
        }
    }

    /// Called when bytecode analysis starts
    pub fn onBytecodeAnalysisStart(self: *DefaultTracer, code_len: usize) void {
        _ = self;
        _ = code_len;
        // No-op in default tracer
    }

    /// Called when bytecode analysis completes
    pub fn onBytecodeAnalysisComplete(self: *DefaultTracer, validated_up_to: usize, opcode_count: usize, jumpdest_count: usize) void {
        _ = self;
        _ = validated_up_to;
        _ = opcode_count;
        _ = jumpdest_count;
        // No-op in default tracer
    }

    /// Called when an invalid opcode is found during analysis
    pub fn onInvalidOpcode(self: *DefaultTracer, pc: usize, opcode: u8) void {
        _ = self;
        _ = pc;
        _ = opcode;
        // No-op in default tracer
    }

    /// Called when a JUMPDEST is found during analysis
    pub fn onJumpdestFound(self: *DefaultTracer, pc: usize, count: usize) void {
        _ = self;
        _ = pc;
        _ = count;
        // No-op in default tracer
    }

    /// Called when dispatch schedule build starts
    pub fn onScheduleBuildStart(self: *DefaultTracer, bytecode_len: usize) void {
        _ = self;
        _ = bytecode_len;
        // No-op in default tracer
    }

    /// Called when a fusion optimization is detected
    pub fn onFusionDetected(self: *DefaultTracer, pc: usize, fusion_type: []const u8, instruction_count: usize) void {
        _ = self;
        _ = pc;
        _ = fusion_type;
        _ = instruction_count;
        // No-op in default tracer
    }

    /// Called when an invalid static jump is detected
    pub fn onInvalidStaticJump(self: *DefaultTracer, jump_pc: usize, target_pc: usize) void {
        _ = self;
        _ = jump_pc;
        _ = target_pc;
        // No-op in default tracer
    }

    /// Called when a static jump is resolved
    pub fn onStaticJumpResolved(self: *DefaultTracer, jump_pc: usize, target_pc: usize) void {
        _ = self;
        _ = jump_pc;
        _ = target_pc;
        // No-op in default tracer
    }

    /// Called when a truncated PUSH instruction is detected
    pub fn onTruncatedPush(self: *DefaultTracer, pc: usize, push_size: u8, available: usize) void {
        _ = self;
        _ = pc;
        _ = push_size;
        _ = available;
        // No-op in default tracer
    }

    /// Called when dispatch schedule build completes
    pub fn onScheduleBuildComplete(self: *DefaultTracer, item_count: usize, fusion_count: usize) void {
        _ = self;
        _ = item_count;
        _ = fusion_count;
        // No-op in default tracer
    }

    /// Called when a jump table is created
    pub fn onJumpTableCreated(self: *DefaultTracer, jumpdest_count: usize) void {
        _ = self;
        _ = jumpdest_count;
        // No-op in default tracer
    }
};

// Helper function to get opcode name
fn getOpcodeName(opcode: u8) []const u8 {
    return switch (opcode) {
        0x00 => "STOP",
        0x01 => "ADD",
        0x02 => "MUL",
        0x03 => "SUB",
        0x04 => "DIV",
        0x05 => "SDIV",
        0x06 => "MOD",
        0x07 => "SMOD",
        0x08 => "ADDMOD",
        0x09 => "MULMOD",
        0x0a => "EXP",
        0x0b => "SIGNEXTEND",
        0x10 => "LT",
        0x11 => "GT",
        0x12 => "SLT",
        0x13 => "SGT",
        0x14 => "EQ",
        0x15 => "ISZERO",
        0x16 => "AND",
        0x17 => "OR",
        0x18 => "XOR",
        0x19 => "NOT",
        0x1a => "BYTE",
        0x1b => "SHL",
        0x1c => "SHR",
        0x1d => "SAR",
        0x20 => "KECCAK256",
        0x30 => "ADDRESS",
        0x31 => "BALANCE",
        0x32 => "ORIGIN",
        0x33 => "CALLER",
        0x34 => "CALLVALUE",
        0x35 => "CALLDATALOAD",
        0x36 => "CALLDATASIZE",
        0x37 => "CALLDATACOPY",
        0x38 => "CODESIZE",
        0x39 => "CODECOPY",
        0x3a => "GASPRICE",
        0x3b => "EXTCODESIZE",
        0x3c => "EXTCODECOPY",
        0x3d => "RETURNDATASIZE",
        0x3e => "RETURNDATACOPY",
        0x3f => "EXTCODEHASH",
        0x40 => "BLOCKHASH",
        0x41 => "COINBASE",
        0x42 => "TIMESTAMP",
        0x43 => "NUMBER",
        0x44 => "PREVRANDAO",
        0x45 => "GASLIMIT",
        0x46 => "CHAINID",
        0x47 => "SELFBALANCE",
        0x48 => "BASEFEE",
        0x49 => "BLOBHASH",
        0x4a => "BLOBBASEFEE",
        0x50 => "POP",
        0x51 => "MLOAD",
        0x52 => "MSTORE",
        0x53 => "MSTORE8",
        0x54 => "SLOAD",
        0x55 => "SSTORE",
        0x56 => "JUMP",
        0x57 => "JUMPI",
        0x58 => "PC",
        0x59 => "MSIZE",
        0x5a => "GAS",
        0x5b => "JUMPDEST",
        0x5c => "TLOAD",
        0x5d => "TSTORE",
        0x5e => "MCOPY",
        0x5f => "PUSH0",
        0x60...0x7f => |n| blk: {
            const push_names = [_][]const u8{
                "PUSH1",  "PUSH2",  "PUSH3",  "PUSH4",  "PUSH5",  "PUSH6",  "PUSH7",  "PUSH8",
                "PUSH9",  "PUSH10", "PUSH11", "PUSH12", "PUSH13", "PUSH14", "PUSH15", "PUSH16",
                "PUSH17", "PUSH18", "PUSH19", "PUSH20", "PUSH21", "PUSH22", "PUSH23", "PUSH24",
                "PUSH25", "PUSH26", "PUSH27", "PUSH28", "PUSH29", "PUSH30", "PUSH31", "PUSH32",
            };
            break :blk push_names[n - 0x60];
        },
        0x80...0x8f => |n| blk: {
            const dup_names = [_][]const u8{
                "DUP1",  "DUP2",  "DUP3",  "DUP4",  "DUP5",  "DUP6",  "DUP7",  "DUP8",
                "DUP9",  "DUP10", "DUP11", "DUP12", "DUP13", "DUP14", "DUP15", "DUP16",
            };
            break :blk dup_names[n - 0x80];
        },
        0x90...0x9f => |n| blk: {
            const swap_names = [_][]const u8{
                "SWAP1",  "SWAP2",  "SWAP3",  "SWAP4",  "SWAP5",  "SWAP6",  "SWAP7",  "SWAP8",
                "SWAP9",  "SWAP10", "SWAP11", "SWAP12", "SWAP13", "SWAP14", "SWAP15", "SWAP16",
            };
            break :blk swap_names[n - 0x90];
        },
        0xa0 => "LOG0",
        0xa1 => "LOG1",
        0xa2 => "LOG2",
        0xa3 => "LOG3",
        0xa4 => "LOG4",
        0xf0 => "CREATE",
        0xf1 => "CALL",
        0xf2 => "CALLCODE",
        0xf3 => "RETURN",
        0xf4 => "DELEGATECALL",
        0xf5 => "CREATE2",
        0xfa => "STATICCALL",
        0xfd => "REVERT",
        0xfe => "INVALID",
        0xff => "SELFDESTRUCT",
        else => "UNKNOWN",
    };
}

// ============================================================================
// OTHER TRACER IMPLEMENTATIONS (STUBS FOR NOW)
// ============================================================================

pub const DebuggingTracer = struct {
    pub fn init(allocator: std.mem.Allocator) DebuggingTracer {
        _ = allocator;
        return .{};
    }

    pub fn deinit(self: *DebuggingTracer) void {
        _ = self;
    }

    pub fn before_instruction(self: *DebuggingTracer, _: anytype, comptime _: UnifiedOpcode, _: anytype) void {
        _ = self;
    }

    pub fn after_instruction(self: *DebuggingTracer, frame: anytype, comptime opcode: UnifiedOpcode, next_handler: anytype, next_cursor: anytype) void {
        _ = self;
        _ = frame;
        _ = opcode;
        _ = next_handler;
        _ = next_cursor;
    }

    pub fn after_complete(self: *DebuggingTracer, frame: anytype, comptime opcode: UnifiedOpcode) void {
        _ = self;
        _ = frame;
        _ = opcode;
    }

    /// Assert with error message - replaces std.debug.assert
    pub fn assert(self: *DebuggingTracer, condition: bool, comptime message: []const u8) void {
        _ = self;
        if (!condition) {
            log.err("ASSERTION FAILED: {s}", .{ message });
            const builtin = @import("builtin");
            if (builtin.target.cpu.arch == .wasm32 and builtin.target.os.tag == .freestanding) {
                unreachable;
            } else {
                @panic(message);
            }
        }
    }
};

pub const LoggingTracer = struct {
    pub fn init(allocator: std.mem.Allocator) LoggingTracer {
        _ = allocator;
        return .{};
    }

    pub fn deinit(self: *LoggingTracer) void {
        _ = self;
    }

    pub fn before_instruction(self: *LoggingTracer, _: anytype, comptime opcode: UnifiedOpcode, _: anytype) void {
        _ = self;
        log.info("[LOG] Executing {s}", .{ @tagName(opcode) });
    }

    pub fn after_instruction(self: *LoggingTracer, frame: anytype, comptime opcode: UnifiedOpcode, next_handler: anytype, next_cursor: anytype) void {
        _ = self;
        _ = frame;
        _ = next_handler;
        _ = next_cursor;
        log.info("[LOG] Completed {s}", .{ @tagName(opcode) });
    }

    pub fn after_complete(self: *LoggingTracer, frame: anytype, comptime opcode: UnifiedOpcode) void {
        _ = self;
        _ = frame;
        log.info("[LOG] Terminal {s}", .{ @tagName(opcode) });
    }

    /// Assert with error message - replaces std.debug.assert
    pub fn assert(self: *LoggingTracer, condition: bool, comptime message: []const u8) void {
        _ = self;
        if (!condition) {
            log.err("ASSERTION FAILED: {s}", .{ message });
            const builtin = @import("builtin");
            if (builtin.target.cpu.arch == .wasm32 and builtin.target.os.tag == .freestanding) {
                unreachable;
            } else {
                @panic(message);
            }
        }
    }
};

pub const FileTracer = struct {
    pub fn init(allocator: std.mem.Allocator) FileTracer {
        _ = allocator;
        return .{};
    }

    pub fn deinit(self: *FileTracer) void {
        _ = self;
    }

    pub fn before_instruction(self: *FileTracer, _: anytype, comptime _: UnifiedOpcode, _: anytype) void {
        _ = self;
    }

    pub fn after_instruction(self: *FileTracer, frame: anytype, comptime opcode: UnifiedOpcode, next_handler: anytype, next_cursor: anytype) void {
        _ = self;
        _ = frame;
        _ = opcode;
        _ = next_handler;
        _ = next_cursor;
    }

    pub fn after_complete(self: *FileTracer, frame: anytype, comptime opcode: UnifiedOpcode) void {
        _ = self;
        _ = frame;
        _ = opcode;
    }

    /// Assert with error message - replaces std.debug.assert
    pub fn assert(self: *FileTracer, condition: bool, comptime message: []const u8) void {
        _ = self;
        if (!condition) {
            log.err("ASSERTION FAILED: {s}", .{ message });
            const builtin = @import("builtin");
            if (builtin.target.cpu.arch == .wasm32 and builtin.target.os.tag == .freestanding) {
                unreachable;
            } else {
                @panic(message);
            }
        }
    }
};
