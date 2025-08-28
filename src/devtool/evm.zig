const std = @import("std");
const Evm = @import("evm");
const debug_state = @import("debug_state.zig");
const OpcodeData = Evm.OpcodeData;

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
/// Tracer configuration applied on interpreter (re)initialization
tracer_cfg: Evm.DebuggingTracer.Config = .{
    .throw_on_error = false,
    .step_mode = false,
    .max_history = 10000,
    .enable_prestate = true,
    .prestate_diff_mode = true,
    .prestate_disable_storage = false,
    .prestate_disable_code = false,
    .prestate_include_empty = false,
    .preflight_checks = true,  // Enable preflight checks to catch issues before they crash
},

pub const DebugStepResult = struct {
    gas_before: u64,
    gas_after: u64,
    completed: bool,
    @"error": ?debug_state.ErrorInfo = null,
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
        // Ensure tracer resources are freed (including composed prestate tracer)
        interp.frame.tracer.deinit();
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
    // Validate hex input
    if (hex_string.len == 0) {
        return error.EmptyBytecode;
    }
    
    const hex_data = if (std.mem.startsWith(u8, hex_string, "0x")) hex_string[2..] else hex_string;
    if (hex_data.len == 0) {
        return error.EmptyBytecode;
    }
    
    if (hex_data.len % 2 != 0) {
        return error.InvalidHexLength;
    }
    
    for (hex_data) |c| {
        if (!std.ascii.isHex(c)) {
            return error.InvalidHexCharacter;
        }
    }
    
    const n = hex_data.len / 2;
    const tmp = try self.allocator.alloc(u8, n);
    defer self.allocator.free(tmp);
    _ = try std.fmt.hexToBytes(tmp, hex_data);
    
    // Try to set bytecode and catch any errors
    self.setBytecode(tmp) catch |err| {
        return err;
    };
    
    // Try to reset execution and catch any errors (e.g., invalid jump destination)
    self.resetExecution() catch |err| {
        // Don't initialize if bytecode is invalid
        self.is_initialized = false;
        return err;
    };
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
    // Preserve the existing tracer instance (to keep breakpoints/config),
    // then recreate the interpreter and attach it back. This lets us reset
    // EVM execution while keeping tracer state we care about.
    var preserved_tracer: ?Evm.DebuggingTracer = null;
    if (self.interpreter) |interp| {
        preserved_tracer = interp.frame.tracer;
        // Do NOT deinit the tracer here; we're reusing it.
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
    // If we preserved a tracer, attach it and reset its runtime state
    if (preserved_tracer) |t| {
        // Clean up the default-initialized tracer in the new interpreter
        // before replacing it to avoid potential resource leaks.
        interp_val.frame.tracer.deinit();
        // Move the preserved tracer into the new interpreter
        interp_val.frame.tracer = t;
        // Reset runtime state while keeping things like breakpoints intact
        interp_val.frame.tracer.reset();
    } else {
        // First init: configure tracer (includes enabling prestate tracer)
        interp_val.frame.tracer.configure(self.tracer_cfg);
    }
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
        return .{ .gas_before = @as(u64, @intCast(@max(f.gas_remaining, 0))), .gas_after = @as(u64, @intCast(@max(f.gas_remaining, 0))), .completed = true, .@"error" = null };
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
    const error_info: ?debug_state.ErrorInfo = if (recent.len == 1 and recent[0].@"error" != null) 
        .{ 
            .kind = if (recent[0].@"error".?.kind == .Panic) "Panic" else "ExecutionError",
            .message = recent[0].@"error".?.message,
        } 
    else 
        null;
    return .{
        .gas_before = gas_before,
        .gas_after = @as(u64, @intCast(@max(f.gas_remaining, 0))),
        .completed = self.is_completed,
        .@"error" = error_info,
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
        const st = debug_state.DebuggerStateJson{
            .gasLeft = 0,
            .depth = 0,
            .stack = &.{},
            .memory = try self.allocator.dupe(u8, "0x"),
            .bytecode = if (self.bytecode.len > 0) try debug_state.format_bytes_hex(self.allocator, self.bytecode) else try self.allocator.dupe(u8, "0x"),
            .logs = &.{},
            .returnData = try self.allocator.dupe(u8, "0x"),
            .@"error" = null,
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

    // Loaded bytecode hex
    const code_hex = try debug_state.format_bytes_hex(self.allocator, self.bytecode);

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
        if (s.@"error") |e| {
            err_dup_raw = try self.allocator.dupe(u8, e.message);
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
    // Fill dynamic gas per instruction from tracer steps
    {
        // Build a temporary PC -> (block_idx, instr_idx) map for quick lookup
        var pc_map = std.AutoHashMap(u32, struct { b: usize, i: usize }).init(self.allocator);
        defer pc_map.deinit();
        var bi2: usize = 0;
        while (bi2 < preanalyzed_blocks.len) : (bi2 += 1) {
            const blk = preanalyzed_blocks[bi2];
            var ii2: usize = 0;
            while (ii2 < blk.instructions.len) : (ii2 += 1) {
                const pc_u32 = blk.instructions[ii2].pc;
                // ignore put errors silently for duplicates
                _ = pc_map.put(pc_u32, .{ .b = bi2, .i = ii2 }) catch {};
            }
        }
        // Walk over recorded steps and attribute dynamic gas
        const trace_steps = interp.frame.tracer.steps.items;
        var si: usize = 0;
        while (si < trace_steps.len) : (si += 1) {
            const stp = trace_steps[si];
            const pc: u32 = stp.pc;
            if (pc_map.get(pc)) |pos| {
                const base: u32 = OpcodeData.OPCODE_INFO[stp.opcode].gas_cost;
                const total: u32 = @intCast(@max(0, stp.gas_before - stp.gas_after));
                const dyn: u32 = if (total > base) total - base else 0;
                // Set dynGasCost at the matched instruction
                preanalyzed_blocks[pos.b].instructions[pos.i].dynGasCost = dyn;
            }
        }
    }
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

    // Get the most recent error information
    const recent_steps = f.tracer.getRecentSteps(1);
    var error_info: ?debug_state.ErrorInfo = null;
    if (recent_steps.len > 0) {
        const st = recent_steps[0];
        if (st.@"error") |e| {
            error_info = .{
                .kind = try self.allocator.dupe(u8, if (e.kind == .Panic) "Panic" else "ExecutionError"),
                .message = try self.allocator.dupe(u8, e.message),
            };
        }
    }

    const st = debug_state.DebuggerStateJson{
        .gasLeft = @intCast(@max(f.gas_remaining, 0)),
        .depth = f.host.get_depth(),
        .stack = stack_hex,
        .memory = mem_hex,
        .bytecode = code_hex,
        .logs = &.{},
        .returnData = ret_hex,
        .@"error" = error_info,
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
    try std.testing.expect(s1.@"error" == null);
    const json = try dv.serializeEvmState();
    // serializeEvmState allocates with dv.allocator (c_allocator); free accordingly
    defer dv.allocator.free(json);
    try std.testing.expect(json.len > 0);
    // Verify that error field is included in JSON
    const json_contains_error_field = std.mem.indexOf(u8, json, "\"error\"") != null;
    try std.testing.expect(json_contains_error_field);
}

test "DevtoolEvm no error case - fields properly set" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const a = gpa.allocator();
    var dv = try DevtoolEvm.init(a);
    defer dv.deinit();
    
    // Valid bytecode: PUSH1 5 PUSH1 10 ADD
    try dv.loadBytecodeHex("0x6005600a01");
    
    // Execute all steps
    _ = try dv.singleStep(); // PUSH1 5
    _ = try dv.singleStep(); // PUSH1 10
    const add_step = try dv.singleStep(); // ADD
    
    // No error should have occurred
    try std.testing.expect(add_step.@"error" == null);
    
    // Verify in JSON
    const json = try dv.serializeEvmState();
    defer dv.allocator.free(json);
    // Should have null error when no error occurred
    try std.testing.expect(std.mem.indexOf(u8, json, "\"error\":null") != null or
                          std.mem.indexOf(u8, json, "\"error\": null") != null);
}

test "DevtoolEvm error tracking - out of bounds memory" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const a = gpa.allocator();
    var dv = try DevtoolEvm.init(a);
    defer dv.deinit();
    
    // Bytecode that will cause OutOfBounds via KECCAK256 with enormous size/offset
    // PUSH32 <offset=0xffff..>
    // PUSH32 <size=0xffff..>
    // KECCAK256
    const big = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff";
    const code = try std.fmt.allocPrint(a, "0x7f{s}7f{s}20", .{ big, big });
    defer a.free(code);
    try dv.loadBytecodeHex(code);
    try std.testing.expect(dv.is_initialized);
    
    // Run until pause or error (throw_on_error=false pauses on error)
    const r = try dv.runUntilHalt();
    try std.testing.expect(r == .paused);
    
    // Verify error is included in serialized state
    const json = try dv.serializeEvmState();
    defer dv.allocator.free(json);
    
    // Check that error is present in JSON with correct structure
    try std.testing.expect(std.mem.indexOf(u8, json, "\"error\":{") != null);
    // Check that error mentions bounds
    try std.testing.expect(std.mem.indexOf(u8, json, "OutOfBounds") != null or
                          std.mem.indexOf(u8, json, "bounds") != null);
    // Should be ExecutionError kind
    try std.testing.expect(std.mem.indexOf(u8, json, "\"kind\":\"ExecutionError\"") != null);
}

test "DevtoolEvm error tracking - invalid opcode" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const a = gpa.allocator();
    var dv = try DevtoolEvm.init(a);
    defer dv.deinit();

    // 0xfe (INVALID) should trigger InvalidOpcode
    try dv.loadBytecodeHex("0xfe");
    try std.testing.expect(dv.is_initialized);

    const r = try dv.runUntilHalt();
    try std.testing.expect(r == .paused);
    const json = try dv.serializeEvmState();
    defer dv.allocator.free(json);
    // Check that error is present in JSON
    try std.testing.expect(std.mem.indexOf(u8, json, "\"error\":{") != null);
    // Message should mention invalid/INVALID
    try std.testing.expect(std.mem.indexOf(u8, json, "Invalid") != null or
                          std.mem.indexOf(u8, json, "invalid") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"kind\":\"ExecutionError\"") != null);
}

test "DevtoolEvm error tracking - invalid jump destination and revert" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const a = gpa.allocator();

    // Case 1: Invalid jump destination
    {
        var dv = try DevtoolEvm.init(a);
        defer dv.deinit();
        // PUSH1 0x03; JUMP; STOP (no JUMPDEST at 0x03)
        // Invalid jump destination is detected during planning/analysis
        try std.testing.expectError(error.InvalidJumpDestination, dv.loadBytecodeHex("0x60035600"));
        // Devtool should remain uninitialized after failed load
        try std.testing.expect(!dv.is_initialized);
    }

    // Case 2: REVERT
    {
        var dv2 = try DevtoolEvm.init(a);
        defer dv2.deinit();
        // PUSH1 0; PUSH1 0; REVERT
        try dv2.loadBytecodeHex("0x60006000fd");
        _ = try dv2.singleStep(); // PUSH1 0
        _ = try dv2.singleStep(); // PUSH1 0
        const rr = try dv2.runUntilHalt();
        try std.testing.expect(rr == .paused);
        const json2 = try dv2.serializeEvmState();
        defer dv2.allocator.free(json2);
        try std.testing.expect(std.mem.indexOf(u8, json2, "REVERT") != null or
                              std.mem.indexOf(u8, json2, "Revert") != null);
        try std.testing.expect(std.mem.indexOf(u8, json2, "\"kind\":\"ExecutionError\"") != null);
    }
}

test "DevtoolEvm preflight panic stack underflow" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const a = gpa.allocator();
    var dv = try DevtoolEvm.init(a);
    defer dv.deinit();

    // This would cause a stack underflow if executed; preflight should catch and pause.
    try dv.loadBytecodeHex("0x01"); // ADD with empty stack
    try std.testing.expect(dv.is_initialized);

    const r = try dv.runUntilHalt();
    try std.testing.expect(r == .paused);

    const json = try dv.serializeEvmState();
    defer dv.allocator.free(json);
    // Check for Panic error kind and StackUnderflow message
    try std.testing.expect(std.mem.indexOf(u8, json, "\"kind\":\"Panic\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "StackUnderflow") != null);
}

test "DevtoolEvm available breakpoints extraction" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const a = gpa.allocator();

    var dv = try DevtoolEvm.init(a);
    defer dv.deinit();

    // Program: PUSH1 1 (pc=0), PUSH1 2 (pc=2), ADD (pc=4)
    try dv.loadBytecodeHex("0x6001600201");

    const avail = try dv.getAvailableBreakpoints(a);
    defer a.free(avail);

    try std.testing.expectEqual(@as(usize, 3), avail.len);
    // Should contain 0, 2, 4 in some order (we will sort a copy for comparison)
    const sorted = try a.dupe(u32, avail);
    defer a.free(sorted);
    std.sort.block(u32, sorted, {}, comptime std.sort.asc(u32));
    try std.testing.expectEqual(@as(u32, 0), sorted[0]);
    try std.testing.expectEqual(@as(u32, 2), sorted[1]);
    try std.testing.expectEqual(@as(u32, 4), sorted[2]);
}

test "DevtoolEvm add/remove/clear breakpoints and pause on hit" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const a = gpa.allocator();

    var dv = try DevtoolEvm.init(a);
    defer dv.deinit();

    // Program: PUSH1 1 (pc=0), PUSH1 2 (pc=2), ADD (pc=4), STOP (pc=5)
    // Note: STOP isn't explicitly present here, execution will end after ADD in our tracer.
    try dv.loadBytecodeHex("0x6001600201");

    // Add a breakpoint at pc=2 and verify it is reported
    try dv.addBreakpoint(2);
    const bps = try dv.getBreakpoints(a);
    defer a.free(bps);
    try std.testing.expect(bps.len == 1);
    // order is arbitrary, so check membership
    var found = false;
    for (bps) |pc| {
        if (pc == 2) found = true;
    }
    try std.testing.expect(found);

    // Run until pause and ensure we paused before executing pc=2
    const res1 = try dv.runUntilHalt();
    try std.testing.expect(res1 == .paused);
    const pc1_opt = dv.interpreter.?.getCurrentPc();
    try std.testing.expect(pc1_opt != null);
    try std.testing.expectEqual(@as(usize, 2), pc1_opt.?);

    // Remove that breakpoint
    const removed = try dv.removeBreakpoint(2);
    try std.testing.expect(removed);
    // Clear breakpoints to ensure cleanup APIs work
    dv.clearBreakpoints();
    const bps2 = try dv.getBreakpoints(a);
    defer a.free(bps2);
    try std.testing.expectEqual(@as(usize, 0), bps2.len);
}
