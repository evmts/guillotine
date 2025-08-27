const std = @import("std");
const evm = @import("evm");
const primitives = @import("primitives");
const Address = primitives.Address.Address;

// Tracer-oriented helpers and JSON types for the devtool UI.

pub const StepJson = struct {
    step: u64,
    pc: u32,
    op: []const u8,
    gasBefore: i32,
    gasAfter: i32,
    gasCost: u32,
    stackBefore: [][]const u8,
    stackAfter: [][]const u8,
    memSizeBefore: usize,
    memSizeAfter: usize,
    depth: u32,
    err: ?[]const u8,
};

pub const DebuggerStateJson = struct {
    gasLeft: u64,
    depth: u32,
    stack: [][]const u8,
    memory: []const u8,
    logs: [][]const u8,
    returnData: []const u8,
    completed: bool,
    currentInstructionIndex: usize,
    pc: u32,
    steps: []StepJson,
    // Execution-based cumulative state (pre/post for all touched accounts)
    state: StateJson,
    // Minimal preanalyzed blocks (entry + every JUMPDEST)
    preanalyzedBlocks: []PreanalyzedBlock = &.{},
    // Current block start instruction index among preanalyzed blocks
    currentPreanalyzedBlockStartIndex: usize = 0,
};

pub const AccountJson = struct {
    address: []const u8,
    balance: []const u8,
    nonce: u64,
    code: ?[]const u8 = null,
    storage: []StorageEntry,
};

pub const StateJson = struct {
    pre: []AccountJson,
    post: []AccountJson,
};

pub const StorageEntry = struct {
    key: []const u8,
    value: []const u8,
};

// Minimal block metadata available from planner/plan preanalysis
pub const InstructionJson = struct {
    pc: u32,
    opcode: []const u8,
    hex: []const u8,
    data: []const u8,
};

pub const PreanalyzedBlock = struct {
    // Explicit start/end PCs for this block (end is exclusive)
    firstPc: u32 = 0,
    lastPcExclusive: u32 = 0,
    // Instruction stream index where this block begins
    firstInstructionIndex: usize,
    // Static gas cost accumulated within the block
    gasCost: u32,
    // Stack height range within the block
    minStack: i16,
    maxStack: i16,
    // Per-block disassembly
    instructions: []InstructionJson = &.{},
};

/// Collect preanalyzed basic blocks from a concrete Interpreter instance with minimal code.
/// Returns one entry for the entry block (pc 0) and one per JUMPDEST.
/// This function is generic over the Interpreter type to avoid changing core APIs.
pub fn collect_blocks_for_interpreter(
    comptime Interpreter: type,
    allocator: std.mem.Allocator,
    interp: *const Interpreter,
) ![]PreanalyzedBlock {
    var out = std.ArrayList(PreanalyzedBlock){};
    errdefer out.deinit(allocator);

    const plan = interp.plan;
    const planner = interp.planner;
    const code = interp.frame.bytecode;
    const dense_opt = plan.pc_to_instruction_idx_dense;

    // Build block start PCs: entry (0) + all JUMPDESTs that are instruction starts
    var starts = std.ArrayList(u32){};
    defer starts.deinit(allocator);
    try starts.append(allocator, 0);
    var pc_it: usize = 1;
    while (pc_it < code.len) : (pc_it += 1) {
        if (code[pc_it] != @intFromEnum(evm.Opcode.JUMPDEST)) continue;
        const is_start = if (dense_opt) |dense|
            (pc_it < dense.len and dense[pc_it] != null)
        else
            plan.getInstructionIndexForPc(@intCast(pc_it)) != null;
        if (is_start) try starts.append(allocator, @intCast(pc_it));
    }

    // Entry begin index
    const entry_begin: usize = if (dense_opt) |dense|
        @intCast(dense[0] orelse 0)
    else
        @intCast(plan.getInstructionIndexForPc(0) orelse 0);

    // Emit blocks with metadata and intra-block instruction lists
    var bi: usize = 0;
    while (bi < starts.items.len) : (bi += 1) {
        const start_pc_u32 = starts.items[bi];
        const start_pc: usize = @intCast(start_pc_u32);
        const end_pc: usize = if (bi + 1 < starts.items.len) @intCast(starts.items[bi + 1]) else code.len;

        // Begin instruction index
        const begin_idx: usize = blk: {
            if (start_pc == 0) break :blk entry_begin;
            if (dense_opt) |dense| break :blk @intCast(dense[start_pc] orelse 0);
            break :blk @intCast(plan.getInstructionIndexForPc(@intCast(start_pc)) orelse 0);
        };

        // Metadata
        var gas_cost: u32 = 0;
        var min_stack: i16 = 0;
        var max_stack: i16 = 0;
        if (start_pc == 0) {
            gas_cost = planner.start.gas;
            min_stack = planner.start.min_stack;
            max_stack = planner.start.max_stack;
        } else {
            var idx_copy: Interpreter.Plan.InstructionIndexType = @intCast(begin_idx);
            const md = plan.getMetadata(&idx_copy, .JUMPDEST);
            const MetaT = @TypeOf(md);
            const meta: @TypeOf(planner.start) = if (comptime MetaT == @TypeOf(planner.start)) md else md.*;
            gas_cost = meta.gas;
            min_stack = meta.min_stack;
            max_stack = meta.max_stack;
        }

        // Enumerate instructions within [start_pc, end_pc)
        var instrs = std.ArrayList(InstructionJson){};
        defer instrs.deinit(allocator);
        var scan: usize = start_pc;
        while (scan < end_pc) : (scan += 1) {
            const is_start_here = if (dense_opt) |dense|
                (scan < dense.len and dense[scan] != null)
            else
                plan.getInstructionIndexForPc(@intCast(scan)) != null;
            if (is_start_here) {
                const op = code[scan];
                // opcode name
                const name_owned: []u8 = blk2: {
                    const op_enum = std.meta.intToEnum(evm.Opcode, op) catch break :blk2 try allocator.dupe(u8, "UNKNOWN");
                    const tag = @tagName(op_enum);
                    break :blk2 try allocator.dupe(u8, tag);
                };
                // opcode hex
                const hex_owned = try format_bytes_hex(allocator, &[_]u8{op});
                // push data
                var data_owned = try allocator.dupe(u8, "");
                if (op == @intFromEnum(evm.Opcode.PUSH0)) {
                    // no payload
                } else if (op >= @intFromEnum(evm.Opcode.PUSH1) and op <= @intFromEnum(evm.Opcode.PUSH32)) {
                    const n: usize = op - (@intFromEnum(evm.Opcode.PUSH1) - 1);
                    const start = scan + 1;
                    const end = @min(code.len, start + n);
                    const slice = if (start < end) code[start..end] else &.{};
                    allocator.free(data_owned);
                    data_owned = try format_bytes_hex(allocator, slice);
                }
                try instrs.append(allocator, .{
                    .pc = @intCast(scan),
                    .opcode = name_owned,
                    .hex = hex_owned,
                    .data = data_owned,
                });
            }
        }

        try out.append(allocator, .{
            .firstPc = start_pc_u32,
            .lastPcExclusive = @intCast(end_pc),
            .firstInstructionIndex = begin_idx,
            .gasCost = gas_cost,
            .minStack = min_stack,
            .maxStack = max_stack,
            .instructions = try instrs.toOwnedSlice(allocator),
        });
    }

    return try out.toOwnedSlice(allocator);
}

pub fn format_u256_hex(allocator: std.mem.Allocator, value: u256) ![]u8 {
    return try std.fmt.allocPrint(allocator, "0x{x}", .{value});
}

pub fn format_bytes_hex(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    // 0x + 2 hex chars per byte
    const out_len = 2 + (bytes.len * 2);
    var buf = try allocator.alloc(u8, out_len);
    var i: usize = 0;
    buf[0] = '0';
    buf[1] = 'x';
    while (i < bytes.len) : (i += 1) {
        const b = bytes[i];
        const hi: u8 = (b >> 4) & 0x0F;
        const lo: u8 = b & 0x0F;
        buf[2 + i * 2] = if (hi < 10) '0' + hi else 'a' + (hi - 10);
        buf[2 + i * 2 + 1] = if (lo < 10) '0' + lo else 'a' + (lo - 10);
    }
    return buf;
}

pub fn format_stack_hex(allocator: std.mem.Allocator, values_top_first: []const u256) ![][]const u8 {
    var out = std.ArrayList([]const u8){};
    defer out.deinit(allocator);
    var i: usize = 0;
    while (i < values_top_first.len) : (i += 1) {
        try out.append(allocator, try format_u256_hex(allocator, values_top_first[i]));
    }
    return try out.toOwnedSlice(allocator);
}

pub fn free_step_json(allocator: std.mem.Allocator, step: StepJson) void {
    for (step.stackBefore) |s| allocator.free(s);
    allocator.free(step.stackBefore);
    for (step.stackAfter) |s| allocator.free(s);
    allocator.free(step.stackAfter);
    if (step.err) |e| allocator.free(e);
    allocator.free(step.op);
}

pub fn free_debugger_state_json(allocator: std.mem.Allocator, state: DebuggerStateJson) void {
    for (state.stack) |s| allocator.free(s);
    allocator.free(state.stack);
    allocator.free(state.memory);
    for (state.logs) |s| allocator.free(s);
    allocator.free(state.logs);
    allocator.free(state.returnData);
    for (state.steps) |st| free_step_json(allocator, st);
    allocator.free(state.steps);
    free_state_json(allocator, state.state);
    // Free preanalyzedBlocks inner arrays and slice
    for (state.preanalyzedBlocks) |blk| {
        for (blk.instructions) |ins| {
            allocator.free(ins.opcode);
            allocator.free(ins.hex);
            allocator.free(ins.data);
        }
        allocator.free(blk.instructions);
    }
    allocator.free(state.preanalyzedBlocks);
}

pub fn free_account_json(allocator: std.mem.Allocator, acct: AccountJson) void {
    allocator.free(acct.address);
    allocator.free(acct.balance);
    if (acct.code) |c| allocator.free(c);
    for (acct.storage) |s| {
        allocator.free(s.key);
        allocator.free(s.value);
    }
    allocator.free(acct.storage);
}

pub fn free_state_json(allocator: std.mem.Allocator, st: StateJson) void {
    for (st.pre) |a| free_account_json(allocator, a);
    allocator.free(st.pre);
    for (st.post) |a| free_account_json(allocator, a);
    allocator.free(st.post);
}

fn format_address_hex(allocator: std.mem.Allocator, addr: Address) ![]u8 {
    // 0x + 40 hex chars
    var out = try allocator.alloc(u8, 2 + 40);
    out[0] = '0';
    out[1] = 'x';
    var i: usize = 0;
    while (i < addr.bytes.len) : (i += 1) {
        const b = addr.bytes[i];
        const hi: u8 = (b >> 4) & 0x0F;
        const lo: u8 = b & 0x0F;
        out[2 + i * 2] = if (hi < 10) '0' + hi else 'a' + (hi - 10);
        out[2 + i * 2 + 1] = if (lo < 10) '0' + lo else 'a' + (lo - 10);
    }
    return out;
}

pub fn build_accounts_from_map(
    allocator: std.mem.Allocator,
    map: *const std.AutoHashMap(Address, evm.PrestateTracer.AccountState),
    disable_storage: bool,
    disable_code: bool,
) ![]AccountJson {
    var list = std.ArrayList(evm.PrestateTracer.AccountState){};
    defer list.deinit(allocator);
    var addr_list = std.ArrayList(Address){};
    defer addr_list.deinit(allocator);
    var it = map.iterator();
    while (it.next()) |e| {
        try list.append(allocator, e.value_ptr.*);
        try addr_list.append(allocator, e.key_ptr.*);
    }
    var out = try allocator.alloc(AccountJson, list.items.len);
    var i: usize = 0;
    while (i < list.items.len) : (i += 1) {
        const a = list.items[i];
        const addr = addr_list.items[i];
        var storage_entries: []StorageEntry = &.{};
        if (!disable_storage and a.storage.count() > 0) {
            var se_list = std.ArrayList(StorageEntry){};
            defer se_list.deinit(allocator);
            var sit = a.storage.iterator();
            while (sit.next()) |se| {
                const key_hex = try format_u256_hex(allocator, se.key_ptr.*);
                const val_hex = try format_u256_hex(allocator, se.value_ptr.*);
                try se_list.append(allocator, .{ .key = key_hex, .value = val_hex });
            }
            storage_entries = try se_list.toOwnedSlice(allocator);
        }
        const addr_hex = try format_address_hex(allocator, addr);
        const bal_hex = try format_u256_hex(allocator, a.balance);
        const code_hex = if (!disable_code and a.code.len > 0) try format_bytes_hex(allocator, a.code) else null;
        out[i] = .{ .address = addr_hex, .balance = bal_hex, .nonce = a.nonce, .code = code_hex, .storage = storage_entries };
    }
    return out;
}


pub fn build_state_until(
    allocator: std.mem.Allocator,
    pt: *const evm.PrestateTracer,
    step_number_debug: u64,
) !StateJson {
    _ = step_number_debug;
    // For cumulative state, include the entire pre/post maps. This mirrors writePrestateJson in diff mode.
    return .{
        .pre = try build_accounts_from_map(allocator, &pt.prestate, pt.disable_storage, pt.disable_code),
        .post = try build_accounts_from_map(allocator, &pt.poststate, pt.disable_storage, pt.disable_code),
    };
}

fn fmt_u64(a: std.mem.Allocator, n: u64) ![]u8 {
    return try std.fmt.allocPrint(a, "{d}", .{n});
}

test "format helpers basic coverage" {
    const t = std.testing;
    const h1 = try format_u256_hex(t.allocator, 0);
    defer t.allocator.free(h1);
    try t.expectEqualStrings("0x0", h1);
    const h2 = try format_bytes_hex(t.allocator, &[_]u8{ 0x12, 0xab });
    defer t.allocator.free(h2);
    try t.expectEqualStrings("0x12ab", h2);
    var tmp = [_]u256{ 1, 2, 3 };
    const hs = try format_stack_hex(t.allocator, &tmp);
    defer {
        for (hs) |s| t.allocator.free(s);
        t.allocator.free(hs);
    }
    try t.expectEqual(@as(usize, 3), hs.len);
}
