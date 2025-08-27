const std = @import("std");
const Evm = @import("evm");
const debug_state = @import("debug_state.zig");

const DevtoolEvm = @This();

// Compile-time frame config with DebuggingTracer enabled
const FRAME_CFG = Evm.FrameConfig{
    .TracerType = Evm.DebuggingTracer,
    .has_database = false,
};

const Interpreter = Evm.createFrameInterpreter(FRAME_CFG);

allocator: std.mem.Allocator,
host: Evm.Host,
bytecode: []u8,
interpreter: ?*Interpreter,
is_initialized: bool,
is_completed: bool,
tx_started: bool = false,
tx_ended: bool = false,
available_breakpoints: []u32 = &.{},

pub const DebugStepResult = struct {
    gas_before: u64,
    gas_after: u64,
    completed: bool,
    error_occurred: bool,
};

pub const RunResult = enum { paused, completed };

pub fn init(allocator: std.mem.Allocator) !DevtoolEvm {
    _ = allocator; // use C allocator to avoid strict alignment issues in devtool
    return .{
        .allocator = std.heap.c_allocator,
        .host = Evm.HostMock.init(),
        .bytecode = &.{},
        .interpreter = null,
        .is_initialized = false,
        .is_completed = false,
    };
}

pub fn deinit(self: *DevtoolEvm) void {
    if (self.interpreter) |interp| {
        interp.deinit(self.allocator);
        self.allocator.destroy(interp);
    }
    if (self.bytecode.len != 0) self.allocator.free(self.bytecode);
    if (self.available_breakpoints.len != 0) self.allocator.free(self.available_breakpoints);
}

pub fn setBytecode(self: *DevtoolEvm, bytecode: []const u8) !void {
    if (self.bytecode.len != 0) self.allocator.free(self.bytecode);
    self.bytecode = try self.allocator.alloc(u8, bytecode.len);
    @memcpy(self.bytecode, bytecode);
    try self.aggregateAvailableBreakpoints();
}

pub fn loadBytecodeHex(self: *DevtoolEvm, hex_string: []const u8) !void {
    if (hex_string.len == 0) return error.EmptyBytecode;
    const hex_data = if (std.mem.startsWith(u8, hex_string, "0x")) hex_string[2..] else hex_string;
    if (hex_data.len == 0) return error.EmptyBytecode;
    if (hex_data.len % 2 != 0) return error.InvalidHexLength;
    for (hex_data) |c| if (!std.ascii.isHex(c)) return error.InvalidHexCharacter;
    const n = hex_data.len / 2;
    const tmp = try self.allocator.alloc(u8, n);
    defer self.allocator.free(tmp);
    _ = try std.fmt.hexToBytes(tmp, hex_data);
    try self.setBytecode(tmp);
    try self.resetExecution();
}

fn pushDataLen(op: u8) u8 {
    // PUSH0 (0x5f) has 0 bytes; PUSH1..PUSH32 (0x60..0x7f) have 1..32 bytes
    if (op == 0x5f) return 0;
    if (op >= 0x60 and op <= 0x7f) return @as(u8, op - 0x60 + 1);
    return 0;
}

fn aggregateAvailableBreakpoints(self: *DevtoolEvm) !void {
    // Free previous cached list
    if (self.available_breakpoints.len != 0) {
        self.allocator.free(self.available_breakpoints);
        self.available_breakpoints = &.{};
    }
    const code = self.bytecode;
    if (code.len == 0) {
        self.available_breakpoints = &.{};
        return;
    }
    // First pass: count instructions
    var count: usize = 0;
    var i: usize = 0;
    while (i < code.len) {
        count += 1;
        const op = code[i];
        const plen = pushDataLen(op);
        const after = i + 1;
        const rem = if (after <= code.len) (code.len - after) else 0;
        const data_len: usize = if (plen == 0) 0 else @min(rem, plen);
        i = after + data_len;
    }
    // Second pass: fill PCs
    var pcs = try self.allocator.alloc(u32, count);
    var idx: usize = 0;
    i = 0;
    while (i < code.len) : ({
        const op2 = code[i];
        const plen2 = pushDataLen(op2);
        const after2 = i + 1;
        const rem2 = if (after2 <= code.len) (code.len - after2) else 0;
        const data_len2: usize = if (plen2 == 0) 0 else @min(rem2, plen2);
        i = after2 + data_len2;
    }) {
        pcs[idx] = @intCast(i);
        idx += 1;
    }
    self.available_breakpoints = pcs;
}

pub fn resetExecution(self: *DevtoolEvm) !void {
    if (self.interpreter) |interp| {
        interp.deinit(self.allocator);
        self.allocator.destroy(interp);
        self.interpreter = null;
    }
    self.is_completed = false;
    if (self.bytecode.len == 0) {
        self.is_initialized = false;
        return;
    }
    var interp_val = try Interpreter.init(self.allocator, self.bytecode, 1_000_000, {}, self.host);
    // ensure tracer is clean and enable prestate tracing
    interp_val.frame.tracer.reset();
    // Enable prestate tracing in diff mode; do not include empty accounts
    interp_val.frame.tracer.enable_prestate_tracing(true, false, false, false) catch {};
    const ptr = try self.allocator.create(Interpreter);
    ptr.* = interp_val;
    self.interpreter = ptr;
    self.is_initialized = true;
    self.tx_started = true;
    self.tx_ended = false;
    // begin tx lifecycle for prestate when enabled
    self.interpreter.?.frame.tracer.onTransactionStart();
}

pub fn singleStep(self: *DevtoolEvm) !DebugStepResult {
    if (!self.is_initialized or self.interpreter == null) return error.NotInitialized;
    if (self.is_completed) {
        const f = &self.interpreter.?.frame;
        return .{ .gas_before = @as(u64, @intCast(@max(f.gas_remaining, 0))), .gas_after = @as(u64, @intCast(@max(f.gas_remaining, 0))), .completed = true, .error_occurred = false };
    }
    const f = &self.interpreter.?.frame;
    const gas_before: u64 = @intCast(@max(f.gas_remaining, 0));
    const res = try f.tracer.stepSingle(Interpreter, self.interpreter.?);
    if (res == .Completed) {
        self.is_completed = true;
        if (!self.tx_ended) {
            self.interpreter.?.frame.tracer.onTransactionEnd();
            self.tx_ended = true;
        }
    }
    const recent = f.tracer.getRecentSteps(1);
    const had_error = if (recent.len == 1) recent[0].error_occurred else false;
    return .{
        .gas_before = gas_before,
        .gas_after = @as(u64, @intCast(@max(f.gas_remaining, 0))),
        .completed = self.is_completed,
        .error_occurred = had_error,
    };
}

pub fn runUntilHalt(self: *DevtoolEvm) !RunResult {
    if (!self.is_initialized or self.interpreter == null) return error.NotInitialized;
    // Ensure we are not in step mode and not paused before running
    const f = &self.interpreter.?.frame;
    f.tracer.setStepMode(false);
    f.tracer.resumeExecution();
    const r = try f.tracer.runUntilPauseOrStop(Interpreter, self.interpreter.?);
    if (r == .Completed) {
        self.is_completed = true;
        if (!self.tx_ended) {
            f.tracer.onTransactionEnd();
            self.tx_ended = true;
        }
        return .completed;
    }
    return .paused;
}

// singleStep defined above

/// Execute until the end of the current basic block (as determined by preanalysis)
/// or until a breakpoint/STOP is reached. Stops before executing the first
/// instruction of the next block.
pub fn runUntilNextBlock(self: *DevtoolEvm) !RunResult {
    if (!self.is_initialized or self.interpreter == null) return error.NotInitialized;
    if (self.is_completed) return .completed;

    const interp = self.interpreter.?;
    const f = &interp.frame;

    // Collect preanalyzed blocks and locate the current block by instruction index
    const blocks = try debug_state.collect_blocks_for_interpreter(Interpreter, self.allocator, interp);
    defer {
        // Free blocks and their instruction arrays
        for (blocks) |blk| {
            for (blk.instructions) |ins| {
                self.allocator.free(ins.opcode);
                self.allocator.free(ins.hex);
                self.allocator.free(ins.data);
            }
            self.allocator.free(blk.instructions);
        }
        self.allocator.free(blocks);
    }

    const cur_idx_usize: usize = interp.instruction_idx;
    var current_block_instrs: []const debug_state.InstructionJson = &.{};
    var found_block = false;
    var i: usize = 0;
    var current_block_start_idx: usize = 0;
    while (i < blocks.len) : (i += 1) {
        const blk = blocks[i];
        const bi = blk.firstInstructionIndex;
        if (bi <= cur_idx_usize and (!found_block or bi >= current_block_start_idx)) {
            current_block_start_idx = bi;
            current_block_instrs = blk.instructions;
            found_block = true;
        }
    }

    // Helper to check if a PC belongs to the current block
    const pc_in_current_block = struct {
        fn contains(instrs: []const debug_state.InstructionJson, pc: u32) bool {
            var j: usize = 0;
            while (j < instrs.len) : (j += 1) {
                if (instrs[j].pc == pc) return true;
            }
            return false;
        }
    };

    // Step through instructions until we leave the current block, hit a breakpoint, or complete
    while (true) {
        const res = try f.tracer.stepSingle(Interpreter, self.interpreter.?);
        if (res == .Completed) {
            self.is_completed = true;
            if (!self.tx_ended) {
                f.tracer.onTransactionEnd();
                self.tx_ended = true;
            }
            return .completed;
        }
        // Next PC to execute
        const next_pc_opt = interp.getCurrentPc();
        if (next_pc_opt == null) return .paused;
        const next_pc: u32 = @intCast(next_pc_opt.?);

        // Stop if next instruction is a breakpoint
        if (f.tracer.hasBreakpoint(next_pc)) return .paused;

        // If the next PC is not in the current block, we've reached the next block
        if (!pc_in_current_block.contains(current_block_instrs, next_pc)) {
            return .paused;
        }
        // Otherwise continue stepping within the current block
    }
}

pub fn addBreakpoint(self: *DevtoolEvm, pc: u32) !void {
    if (!self.is_initialized or self.interpreter == null) return error.NotInitialized;
    try self.interpreter.?.frame.tracer.addBreakpoint(pc);
}

pub fn removeBreakpoint(self: *DevtoolEvm, pc: u32) !bool {
    if (!self.is_initialized or self.interpreter == null) return false;
    return self.interpreter.?.frame.tracer.removeBreakpoint(pc);
}

pub fn clearBreakpoints(self: *DevtoolEvm) void {
    if (self.interpreter) |i| i.frame.tracer.clearBreakpoints();
}
/// Return a newly allocated slice of PCs for all current breakpoints.
pub fn getBreakpoints(self: *DevtoolEvm, allocator: std.mem.Allocator) ![]u32 {
    if (self.interpreter == null) return allocator.alloc(u32, 0);
    var list = std.ArrayList(u32){};
    defer list.deinit(allocator);
    var it = self.interpreter.?.frame.tracer.breakpoints.iterator();
    while (it.next()) |e| {
        try list.append(allocator, e.key_ptr.*);
    }
    // Note: order is arbitrary due to hash map iteration
    return try list.toOwnedSlice(allocator);
}

/// Return a newly allocated slice of all instruction PCs in the current bytecode.
pub fn getAvailableBreakpoints(self: *DevtoolEvm, allocator: std.mem.Allocator) ![]u32 {
    const src = self.available_breakpoints;
    const out = try allocator.alloc(u32, src.len);
    if (src.len != 0) @memcpy(out, src);
    return out;
}

pub fn serializeEvmState(self: *DevtoolEvm) ![]u8 {
    if (!self.is_initialized or self.interpreter == null) {
        // Minimal empty payload for UI boot
        const st = debug_state.DebuggerStateJson{
            .gasLeft = 0,
            .depth = 0,
            .stack = &.{},
            .memory = try self.allocator.dupe(u8, "0x"),
            .storage = &.{},
            .logs = &.{},
            .returnData = try self.allocator.dupe(u8, "0x"),
            .completed = false,
            .currentInstructionIndex = 0,
            .pc = 0,
            .steps = &.{},
            .state = .{ .pre = &.{}, .post = &.{} },
        };
        defer debug_state.free_debugger_state_json(self.allocator, st);
        const printed = try std.fmt.allocPrint(self.allocator, "{f}", .{std.json.fmt(st, .{})});
        return printed;
    }

    const interp = self.interpreter.?;
    const f = &interp.frame;

    // Stack formatting: Frame stack slice is top-first at index 0
    const stack_slice = f.stack.get_slice();
    const stack_hex = try debug_state.format_stack_hex(self.allocator, stack_slice);

    // Memory formatting: dump full memory into hex (can optimize to prefix later)
    const mem_size = f.memory.size();
    const mem_bytes = if (mem_size == 0) &.{} else f.memory.get_slice(0, mem_size) catch &.{};
    const mem_hex = try debug_state.format_bytes_hex(self.allocator, mem_bytes);

    // Return data
    const ret_hex = blk: {
        if (f.output_data.items.len == 0) break :blk try self.allocator.dupe(u8, "0x");
        break :blk try debug_state.format_bytes_hex(self.allocator, f.output_data.items);
    };

    // Recent tracer steps
    const recent = f.tracer.getRecentSteps(64);
    var steps = try self.allocator.alloc(debug_state.StepJson, recent.len);
    var idx: usize = 0;
    while (idx < recent.len) : (idx += 1) {
        const s = recent[idx];
        const sb = try debug_state.format_stack_hex(self.allocator, s.stack_before);
        const sa = try debug_state.format_stack_hex(self.allocator, s.stack_after);
        const op_name = try self.allocator.dupe(u8, s.opcode_name);
        var err_dup_raw: ?[]u8 = null;
        if (s.error_occurred) {
            if (s.error_msg) |m| {
                err_dup_raw = try self.allocator.dupe(u8, m);
            }
        }
        const err_dup: ?[]const u8 = if (err_dup_raw) |e| e else null;
        steps[idx] = .{
            .step = s.step_number,
            .pc = s.pc,
            .op = op_name,
            .gasBefore = s.gas_before,
            .gasAfter = s.gas_after,
            .gasCost = s.gas_cost,
            .stackBefore = sb,
            .stackAfter = sa,
            .memSizeBefore = s.memory_size_before,
            .memSizeAfter = s.memory_size_after,
            .depth = s.depth,
            .err = err_dup,
        };
    }

    const pc_opt = interp.getCurrentPc();
    // pre/post states and cumulative changes
    var cumulative_state: debug_state.StateJson = .{ .pre = &.{}, .post = &.{} };
    if (f.tracer.prestate_tracer) |pt| {
        const last_step = if (recent.len > 0) recent[recent.len - 1].step_number else 0;
        cumulative_state = try debug_state.build_state_until(self.allocator, pt, last_step);
    }

    // Minimal preanalyzed blocks via planner/plan helper
    const preanalyzed_blocks = try debug_state.collect_blocks_for_interpreter(Interpreter, self.allocator, interp);
    const cur_idx_usize: usize = interp.instruction_idx;
    var current_block_start_idx: usize = 0;
    // Choose the largest block.firstInstructionIndex <= current instruction index
    for (preanalyzed_blocks) |blk| {
        const bi: usize = blk.firstInstructionIndex;
        if (bi <= cur_idx_usize and bi >= current_block_start_idx) current_block_start_idx = bi;
    }

    // Normalize the "currentInstructionIndex" for the UI to count EVM opcodes,
    // not raw instruction-stream elements (which include trace hooks and metadata).
    // We compute: block_begin_idx + 1 + offset_within_block_of_next_opcode
    var ui_current_instr_idx: usize = 0;
    // Find the current block by start index
    var cur_block_instrs: []const debug_state.InstructionJson = &.{};
    for (preanalyzed_blocks) |blk| {
        if (blk.firstInstructionIndex == current_block_start_idx) {
            cur_block_instrs = blk.instructions;
            break;
        }
    }
    const next_pc_opt = interp.getCurrentPc();
    if (self.is_completed) {
        // Completed: point just past the last instruction in the current block
        ui_current_instr_idx = current_block_start_idx + 1 + cur_block_instrs.len;
    } else if (next_pc_opt) |next_pc_val| {
        // Locate next opcode within the current block by PC
        var offset: usize = 0;
        var found = false;
        var i: usize = 0;
        while (i < cur_block_instrs.len) : (i += 1) {
            if (cur_block_instrs[i].pc == @as(u32, next_pc_val)) {
                offset = i;
                found = true;
                break;
            }
        }
        if (!found) {
            // Fallback: if PC is beyond this block, clamp to end; otherwise 0
            if (cur_block_instrs.len != 0 and @as(usize, next_pc_val) > @as(usize, cur_block_instrs[cur_block_instrs.len - 1].pc)) {
                offset = cur_block_instrs.len;
            } else {
                offset = 0;
            }
        }
        ui_current_instr_idx = current_block_start_idx + 1 + offset;
    } else {
        // No PC available yet (e.g. just initialized): point to first opcode
        ui_current_instr_idx = current_block_start_idx + 1;
    }

    const st = debug_state.DebuggerStateJson{
        .gasLeft = @intCast(@max(f.gas_remaining, 0)),
        .depth = f.host.get_depth(),
        .stack = stack_hex,
        .memory = mem_hex,
        .storage = &.{},
        .logs = &.{},
        .returnData = ret_hex,
        .completed = self.is_completed,
        .currentInstructionIndex = ui_current_instr_idx,
        .pc = @intCast(pc_opt orelse 0),
        .steps = steps,
        .state = cumulative_state,
        .preanalyzedBlocks = preanalyzed_blocks,
        .currentPreanalyzedBlockStartIndex = current_block_start_idx,
    };
    defer debug_state.free_debugger_state_json(self.allocator, st);
    const printed = try std.fmt.allocPrint(self.allocator, "{f}", .{std.json.fmt(st, .{})});
    return printed;
}

test "DevtoolEvm init + hex load + single step" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const a = gpa.allocator();
    var dv = try DevtoolEvm.init(a);
    defer dv.deinit();
    try dv.loadBytecodeHex("0x6001600201"); // PUSH1 1 PUSH1 2 ADD
    try std.testing.expect(dv.is_initialized);
    const s1 = try dv.singleStep();
    try std.testing.expect(!s1.completed);
    const json = try dv.serializeEvmState();
    defer a.free(json);
    try std.testing.expect(json.len > 0);
}
