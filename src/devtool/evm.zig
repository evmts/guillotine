const std = @import("std");
const Evm = @import("evm");
const primitives = @import("primitives");
const MemoryDatabase = Evm.MemoryDatabase;
const DatabaseInterface = Evm.DatabaseInterface;
const OpcodeMetadata = Evm.OpcodeMetadata;
const Host = Evm.Host;
// Use primitives.Address module directly
const Bytes32 = primitives.Bytes32;
const StorageKey = primitives.StorageKey;
const testing = std.testing;
const debug_state = @import("debug_state.zig");

// Default EVM configuration for devtool (currently unused)
const config = Evm.EvmConfig.init(.CANCUN);
const EvmType = Evm.Evm;

const DevtoolEvm = @This();

allocator: std.mem.Allocator,
database: MemoryDatabase,
evm: EvmType,
host: Host,
bytecode: []u8,

// Debug-specific fields
current_frame: ?*Evm.Frame,
current_contract: ?*Evm.Contract,
analysis: ?*Evm.CodeAnalysis,
instr_index: usize,
is_paused: bool,
is_initialized: bool,
is_completed: bool,

// Storage tracking for debugging
storage_changes: std.AutoHashMap(StorageKey, u256),

/// Result of a single step execution
pub const DebugStepResult = struct {
    gas_before: u64,
    gas_after: u64,
    completed: bool,
    error_occurred: bool,
    execution_error: ?anyerror,
};

pub fn init(allocator: std.mem.Allocator) !DevtoolEvm {
    var database = MemoryDatabase.init(allocator);
    errdefer database.deinit();

    const db_interface = database.to_database_interface();
    var evm = try EvmType.init(allocator, db_interface, null, null, null, 0, false, null);
    errdefer evm.deinit();

    // Host must outlive frames; store on struct
    const host = Host.init(&evm);

    var storage_changes = std.AutoHashMap(StorageKey, u256).init(allocator);
    errdefer storage_changes.deinit();

    return DevtoolEvm{
        .allocator = allocator,
        .database = database,
        .evm = evm,
        .host = host,
        .bytecode = &[_]u8{},
        .current_frame = null,
        .current_contract = null,
        .analysis = null,
        .instr_index = 0,
        .is_paused = false,
        .is_initialized = false,
        .is_completed = false,
        .storage_changes = storage_changes,
    };
}

pub fn deinit(self: *DevtoolEvm) void {
    // Clean up current execution state
    if (self.current_contract) |contract| {
        contract.deinit(self.allocator, null);
        self.allocator.destroy(contract);
    }
    if (self.current_frame) |frame| {
        frame.deinit();
        self.allocator.destroy(frame);
    }
    if (self.analysis) |a| {
        a.deinit();
        self.allocator.destroy(a);
    }
    if (self.bytecode.len > 0) {
        self.allocator.free(self.bytecode);
    }
    self.storage_changes.deinit();
    self.evm.deinit();
    self.database.deinit();
}

pub fn setBytecode(self: *DevtoolEvm, bytecode: []const u8) !void {
    // Free existing bytecode if any
    if (self.bytecode.len > 0) {
        self.allocator.free(self.bytecode);
    }

    // Allocate and copy new bytecode
    self.bytecode = try self.allocator.alloc(u8, bytecode.len);
    @memcpy(self.bytecode, bytecode);
}

/// Load bytecode from hex string and initialize execution
pub fn loadBytecodeHex(self: *DevtoolEvm, hex_string: []const u8) !void {
    // Validate input
    if (hex_string.len == 0) {
        return error.EmptyBytecode;
    }

    // Remove 0x prefix if present
    const hex_data = if (std.mem.startsWith(u8, hex_string, "0x"))
        hex_string[2..]
    else
        hex_string;

    // Validate hex string
    if (hex_data.len == 0) {
        return error.EmptyBytecode;
    }

    if (hex_data.len % 2 != 0) {
        return error.InvalidHexLength;
    }

    // Validate all characters are hex
    for (hex_data) |char| {
        if (!std.ascii.isHex(char)) {
            return error.InvalidHexCharacter;
        }
    }

    // Convert hex string to bytes
    const bytecode_len = hex_data.len / 2;
    const bytecode = try self.allocator.alloc(u8, bytecode_len);
    defer self.allocator.free(bytecode);

    _ = try std.fmt.hexToBytes(bytecode, hex_data);

    // Set the bytecode
    try self.setBytecode(bytecode);

    // Reset execution state
    try self.resetExecution();
}

/// Initialize execution with current bytecode
pub fn resetExecution(self: *DevtoolEvm) !void {
    // Clean up existing execution state
    if (self.current_contract) |contract| {
        contract.deinit(self.allocator, null);
        self.allocator.destroy(contract);
        self.current_contract = null;
    }
    if (self.current_frame) |frame| {
        frame.deinit();
        self.allocator.destroy(frame);
        self.current_frame = null;
    }
    // Clear any previous host output to avoid dangling slices to freed frame memory
    // This prevents serializeEvmState formatting an invalid slice after resets
    self.host.set_output(&.{}) catch {};
    // Clean up previous analysis if present before creating a new one
    if (self.analysis) |a| {
        a.deinit();
        self.allocator.destroy(a);
        self.analysis = null;
    }

    // Clear storage tracking
    self.storage_changes.clearRetainingCapacity();

    if (self.bytecode.len == 0) {
        self.is_initialized = false;
        return;
    }

    // Create contract from bytecode
    const contract = try self.allocator.create(Evm.Contract);
    errdefer self.allocator.destroy(contract);

    contract.* = Evm.Contract.init_at_address(primitives.Address.ZERO, // caller
        primitives.Address.ZERO, // address
        0, // value
        1000000, // gas
        self.bytecode, &[_]u8{}, // input
        false // is_static
    );

    self.current_contract = contract;

    // Build code analysis for the current bytecode using default opcode metadata
    const table = OpcodeMetadata.DEFAULT;
    const analysis = try Evm.CodeAnalysis.from_code(self.allocator, self.bytecode, &table);
    // Own the analysis in the devtool for frame lifetime
    const analysis_ptr = try self.allocator.create(Evm.CodeAnalysis);
    analysis_ptr.* = analysis;
    self.analysis = analysis_ptr;

    // Prepare frame dependencies from the VM
    const frame_val = try Evm.Frame.init(
        1_000_000, // gas_remaining
        false, // static_call
        0, // call_depth
        contract.address, // contract_address
        contract.caller, // caller
        0, // value
        analysis_ptr, // analysis
        self.host, // host
        self.evm.state.database, // state
        self.evm.chain_rules, // chain_rules
        &self.evm.self_destruct, // self_destruct
        &[_]u8{}, // input
        self.allocator, // allocator
    );
    const frame_ptr = try self.allocator.create(Evm.Frame);
    frame_ptr.* = frame_val;
    // Ensure opcodes that reference code (e.g., CODECOPY, CODESIZE) have access
    // to the actual contract bytecode
    frame_ptr.code = self.bytecode;
    // Start at first instruction to mirror interpreter
    frame_ptr.instruction = &analysis_ptr.instructions[0];
    self.current_frame = frame_ptr;

    self.is_initialized = true;
    self.is_paused = false;
    // Always start at the first instruction (BEGINBLOCK). The step loop will
    // process the BEGINBLOCK meta (charge gas/validate) and then advance to the
    // first visible opcode in the same call.
    self.instr_index = 0;
    // analysis-driven stepping does not expose opcode byte/name in UI
    self.is_completed = false;
    // No PC tracking for UI
}

/// Get current EVM state as JSON string
pub fn serializeEvmState(self: *DevtoolEvm) ![]u8 {
    if (!self.is_initialized or self.current_frame == null) {
        const empty_state = try debug_state.createEmptyEvmStateJson(self.allocator);
        defer debug_state.freeEvmStateJson(self.allocator, empty_state);
        return try std.json.stringifyAlloc(self.allocator, empty_state, .{});
    }

    const frame = self.current_frame.?;
    // Serialize storage changes
    var storage_entries = std.ArrayList(debug_state.StorageEntry).init(self.allocator);
    defer storage_entries.deinit();

    var storage_iter = self.storage_changes.iterator();
    while (storage_iter.next()) |entry| {
        const key_hex = try debug_state.formatU256Hex(self.allocator, entry.key_ptr.slot);
        const value_hex = try debug_state.formatU256Hex(self.allocator, entry.value_ptr.*);
        try storage_entries.append(.{
            .key = key_hex,
            .value = value_hex,
        });
    }

    // Build block list from analysis
    var blocks = std.ArrayList(debug_state.BlockJson).init(self.allocator);
    defer {
        // moved later into state
    }
    var current_block_start_index: usize = 0;
    if (self.analysis) |a| {
        const instrs = a.instructions;
        // derive current index from frame instruction pointer when available
        var derived_idx: usize = if (self.instr_index < instrs.len) self.instr_index else 0;
        if (self.current_frame) |f| {
            const base: [*]const @TypeOf(instrs[0]) = instrs.ptr;
            derived_idx = (@intFromPtr(f.instruction) - @intFromPtr(base)) / @sizeOf(@TypeOf(instrs[0]));
            self.instr_index = derived_idx;
        }
        // find current block start
        var search: usize = if (derived_idx < instrs.len) derived_idx else 0;
        while (search > 0 and instrs[search].arg != .block_info) : (search -= 1) {}
        current_block_start_index = search;

        // enumerate all blocks
        var i: usize = 0;
        while (i < instrs.len) : (i += 1) {
            if (instrs[i].arg == .block_info) {
                // Collect a 1:1 list of analysis-visible instructions within this block.
                // We intentionally avoid expanding to raw PCs; rows align strictly with
                // instruction indices to make stepping foolproof.
                var pcs = std.ArrayList(u32).init(self.allocator);
                var opcodes = std.ArrayList([]const u8).init(self.allocator);
                var hexes = std.ArrayList([]const u8).init(self.allocator);
                var datas = std.ArrayList([]const u8).init(self.allocator);
                var dbg_inst_indices = std.ArrayList(u32).init(self.allocator);
                var dbg_inst_mapped_pcs = std.ArrayList(u32).init(self.allocator);
                defer pcs.deinit();
                defer opcodes.deinit();
                defer hexes.deinit();
                defer datas.deinit();
                defer dbg_inst_indices.deinit();
                defer dbg_inst_mapped_pcs.deinit();

                // Find the first PC that maps to this block as a fallback origin
                var block_start_pc: ?usize = null;
                var scan_pc: usize = 0;
                while (scan_pc < a.code_len) : (scan_pc += 1) {
                    if (a.pc_to_block_start[scan_pc] == i) {
                        block_start_pc = scan_pc;
                        break;
                    }
                }

                var j: usize = i + 1;
                var last_pc_opt: ?usize = block_start_pc;
                while (j < instrs.len and instrs[j].arg != .block_info) : (j += 1) {
                    // Prefer direct mapping from instruction to PC when available
                    const mapped_u16: u16 = if (j < a.inst_to_pc.len) a.inst_to_pc[j] else std.math.maxInt(u16);
                    var pc: usize = 0;
                    if (mapped_u16 != std.math.maxInt(u16)) {
                        pc = mapped_u16;
                        last_pc_opt = pc;
                    } else if (last_pc_opt) |prev_pc| {
                        // Derive a best-effort PC by advancing from the previous PC
                        const prev_op: u8 = if (prev_pc < a.code_len) a.code[prev_pc] else 0;
                        const imm_len: usize = if (prev_op == 0x5f) 0 else if (prev_op >= 0x60 and prev_op <= 0x7f) @intCast(prev_op - 0x5f) else 0;
                        pc = prev_pc + 1 + imm_len;
                        last_pc_opt = pc;
                    } else {
                        // Fallback to 0 when no mapping exists; UI highlight uses index, not PC
                        pc = 0;
                    }

                    // Debugging aids
                    dbg_inst_indices.append(@intCast(j)) catch {};
                    dbg_inst_mapped_pcs.append(@intCast(mapped_u16)) catch {};

                    // Populate display fields from original code at derived PC (best-effort)
                    const op_byte: u8 = if (pc < a.code_len) a.code[pc] else 0;
                    const hex_str = try std.fmt.allocPrint(self.allocator, "0x{x:0>2}", .{op_byte});
                    const name = try self.allocator.dupe(u8, debug_state.opcodeToString(op_byte));
                    var data_str: []const u8 = &[_]u8{};
                    if (op_byte >= 0x60 and op_byte <= 0x7f and pc + 1 <= a.code_len) {
                        const imm_len2: usize = op_byte - 0x5f;
                        if (pc + 1 + imm_len2 <= a.code_len) {
                            const slice = a.code[pc + 1 .. pc + 1 + imm_len2];
                            data_str = try debug_state.formatBytesHex(self.allocator, slice);
                        } else {
                            data_str = try self.allocator.dupe(u8, "0x");
                        }
                    } else {
                        data_str = try self.allocator.dupe(u8, "");
                    }

                    pcs.append(@intCast(pc)) catch {};
                    opcodes.append(name) catch {};
                    hexes.append(hex_str) catch {};
                    datas.append(data_str) catch {};
                }

                blocks.append(.{
                    .beginIndex = i,
                    .gasCost = instrs[i].arg.block_info.gas_cost,
                    .stackReq = instrs[i].arg.block_info.stack_req,
                    .stackMaxGrowth = instrs[i].arg.block_info.stack_max_growth,
                    .pcs = try pcs.toOwnedSlice(),
                    .opcodes = try opcodes.toOwnedSlice(),
                    .hex = try hexes.toOwnedSlice(),
                    .data = try datas.toOwnedSlice(),
                    .instIndices = try dbg_inst_indices.toOwnedSlice(),
                    .instMappedPcs = try dbg_inst_mapped_pcs.toOwnedSlice(),
                }) catch {};
            }
        }
    }

    const state = debug_state.EvmStateJson{
        .gasLeft = frame.gas_remaining,
        .depth = frame.depth,
        .stack = try debug_state.serializeStack(self.allocator, &frame.stack),
        .memory = try debug_state.serializeMemory(self.allocator, &frame.memory),
        .storage = try storage_entries.toOwnedSlice(),
        .logs = try self.allocator.alloc([]const u8, 0),
        .returnData = blk: {
            const out = self.host.get_output();
            if (out.len == 0) break :blk try self.allocator.dupe(u8, "0x");
            const formatted = debug_state.formatBytesHex(self.allocator, out) catch
                break :blk try self.allocator.dupe(u8, "0x");
            break :blk formatted;
        },
        .completed = self.is_completed,
        .currentInstructionIndex = self.instr_index,
        .currentBlockStartIndex = current_block_start_index,
        .blocks = try blocks.toOwnedSlice(),
    };

    // Serialize to JSON and clean up
    const json = try std.json.stringifyAlloc(self.allocator, state, .{});
    debug_state.freeEvmStateJson(self.allocator, state);
    return json;
}

/// Execute a single instruction and return debug information
pub fn stepExecute(self: *DevtoolEvm) !DebugStepResult {
    if (!self.is_initialized or self.current_frame == null) {
        return error.NotInitialized;
    }

    if (self.is_completed) {
        const frame_done = self.current_frame.?;
        return DebugStepResult{
            .gas_before = frame_done.gas_remaining,
            .gas_after = frame_done.gas_remaining,
            .completed = true,
            .error_occurred = false,
            .execution_error = null,
        };
    }

    const frame = self.current_frame.?;

    const analysis = self.analysis.?;
    const instructions = analysis.instructions;

    // Already finished?
    if (self.is_completed or self.instr_index >= instructions.len) {
        return DebugStepResult{
            .gas_before = frame.gas_remaining,
            .gas_after = frame.gas_remaining,
            .completed = true,
            .error_occurred = false,
            .execution_error = null,
        };
    }

    // Analysis-first stepping
    const gas_before = frame.gas_remaining;

    var exec_err: ?Evm.ExecutionError.Error = null;

    // Execute exactly one visible instruction per step.
    // 1) BeginBlock charge/validation (only once when entering a block)
    {
        const ip0 = frame.instruction;
        if (ip0.arg == .block_info) {
            const block = ip0.arg.block_info;
            if (frame.gas_remaining < block.gas_cost) {
                frame.gas_remaining = 0;
                exec_err = Evm.ExecutionError.Error.OutOfGas;
                self.is_completed = true;
            } else {
                frame.gas_remaining -= block.gas_cost;
                const current_stack_size: u16 = @intCast(frame.stack.size());
                if (current_stack_size < block.stack_req) {
                    exec_err = Evm.ExecutionError.Error.StackUnderflow;
                    self.is_completed = true;
                } else if (current_stack_size + block.stack_max_growth > 1024) {
                    exec_err = Evm.ExecutionError.Error.StackOverflow;
                    self.is_completed = true;
                } else {
                    frame.instruction = ip0.next_instruction;
                }
            }
        }
    }

    if (!self.is_completed and exec_err == null) {
        var executed_visible = false;
        while (!executed_visible) {
            const ip = frame.instruction;
            if (ip.arg == .block_info) break; // reached next block; end step

            const next_ip = ip.next_instruction;
            const op_fn = ip.opcode_fn;
            switch (ip.arg) {
                .block_info => break,
                .conditional_jump => |true_target| {
                    const cond = frame.stack.pop_unsafe();
                    if (cond != 0) {
                        frame.instruction = true_target;
                    } else {
                        frame.instruction = next_ip;
                    }
                    break; // end step after updating ip
                },
                .word => |value| {
                    frame.stack.append(value) catch {
                        exec_err = Evm.ExecutionError.Error.StackOverflow;
                        self.is_completed = true;
                    };
                    frame.instruction = next_ip;
                    executed_visible = true;
                },
                .keccak => |params| {
                    if (frame.gas_remaining < params.gas_cost) {
                        frame.gas_remaining = 0;
                        exec_err = Evm.ExecutionError.Error.OutOfGas;
                        self.is_completed = true;
                        executed_visible = true;
                        break;
                    }
                    frame.gas_remaining -= params.gas_cost;
                    const size: u256 = if (params.size) |imm| @as(u256, @intCast(imm)) else frame.stack.pop_unsafe();
                    const offset = frame.stack.pop_unsafe();
                    if (offset > std.math.maxInt(usize) or size > std.math.maxInt(usize)) {
                        exec_err = Evm.ExecutionError.Error.OutOfOffset;
                        self.is_completed = true;
                        executed_visible = true;
                        break;
                    }
                    const offset_usize: usize = @intCast(offset);
                    const size_usize: usize = @intCast(size);
                    if (size == 0) {
                        const empty_hash: u256 = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;
                        frame.stack.append_unsafe(empty_hash);
                    } else {
                        const data = frame.memory.get_slice(offset_usize, size_usize) catch |err| {
                            exec_err = err;
                            self.is_completed = true;
                            executed_visible = true;
                            break;
                        };
                        var hash: [32]u8 = undefined;
                        std.crypto.hash.sha3.Keccak256.hash(data, &hash, .{});
                        const result = std.mem.readInt(u256, &hash, .big);
                        frame.stack.append_unsafe(result);
                    }
                    frame.instruction = next_ip;
                    executed_visible = true;
                },
                .none => {
                    // Treat JUMPDEST as non-visible: skip and continue without ending the step
                    const base2: [*]const @TypeOf(instructions[0]) = instructions.ptr;
                    const cur_idx: usize = (@intFromPtr(ip) - @intFromPtr(base2)) / @sizeOf(@TypeOf(instructions[0]));
                    var is_jumpdest = false;
                    if (cur_idx < analysis.inst_to_pc.len) {
                        const pc_u16 = analysis.inst_to_pc[cur_idx];
                        if (pc_u16 != std.math.maxInt(u16)) {
                            const pc_usize: usize = pc_u16;
                            if (pc_usize < analysis.code_len and analysis.code[pc_usize] == 0x5b) {
                                is_jumpdest = true;
                            }
                        }
                    }
                    if (is_jumpdest) {
                        frame.instruction = next_ip;
                        continue;
                    }
                    op_fn(@ptrCast(frame)) catch |err| {
                        if (err == Evm.ExecutionError.Error.InvalidOpcode) {
                            frame.gas_remaining = 0;
                        }
                        exec_err = err;
                        self.is_completed = true;
                    };
                    frame.instruction = next_ip;
                    executed_visible = true;
                },
                .gas_cost => |cost| {
                    if (frame.gas_remaining < cost) {
                        frame.gas_remaining = 0;
                        exec_err = Evm.ExecutionError.Error.OutOfGas;
                        self.is_completed = true;
                        executed_visible = true;
                        break;
                    }
                    frame.gas_remaining -= cost;
                    op_fn(@ptrCast(frame)) catch |err| {
                        if (err == Evm.ExecutionError.Error.InvalidOpcode) {
                            frame.gas_remaining = 0;
                        }
                        exec_err = err;
                        self.is_completed = true;
                    };
                    frame.instruction = next_ip;
                    executed_visible = true;
                },
                .dynamic_gas => |dyn_gas| {
                    if (frame.gas_remaining < dyn_gas.static_cost) {
                        frame.gas_remaining = 0;
                        exec_err = Evm.ExecutionError.Error.OutOfGas;
                        self.is_completed = true;
                        executed_visible = true;
                        break;
                    }
                    frame.gas_remaining -= dyn_gas.static_cost;
                    if (dyn_gas.gas_fn) |gas_fn| {
                        const additional = gas_fn(frame) catch |err| {
                            if (err == Evm.ExecutionError.Error.OutOfOffset) {
                                exec_err = err;
                                self.is_completed = true;
                                executed_visible = true;
                                break;
                            }
                            frame.gas_remaining = 0;
                            exec_err = Evm.ExecutionError.Error.OutOfGas;
                            self.is_completed = true;
                            executed_visible = true;
                            break;
                        };
                        if (frame.gas_remaining < additional) {
                            frame.gas_remaining = 0;
                            exec_err = Evm.ExecutionError.Error.OutOfGas;
                            self.is_completed = true;
                            executed_visible = true;
                            break;
                        }
                        frame.gas_remaining -= additional;
                    }
                    op_fn(@ptrCast(frame)) catch |err| {
                        if (err == Evm.ExecutionError.Error.InvalidOpcode) {
                            frame.gas_remaining = 0;
                        }
                        exec_err = err;
                        self.is_completed = true;
                    };
                    frame.instruction = next_ip;
                    executed_visible = true;
                },
            }
            if (exec_err) |e| {
                if (e == Evm.ExecutionError.Error.STOP or e == Evm.ExecutionError.Error.REVERT) {
                    self.is_completed = true;
                }
                break;
            }
        }
    }

    // sync UI index from pointer
    const base_ptr: [*]const @TypeOf(instructions[0]) = instructions.ptr;
    self.instr_index = (@intFromPtr(frame.instruction) - @intFromPtr(base_ptr)) / @sizeOf(@TypeOf(instructions[0]));

    const had_error = exec_err != null and exec_err.? != Evm.ExecutionError.Error.STOP;
    const completed = self.is_completed;

    return DebugStepResult{
        .gas_before = gas_before,
        .gas_after = frame.gas_remaining,
        .completed = completed,
        .error_occurred = had_error,
        .execution_error = if (had_error) exec_err else null,
    };
}

// Map an instruction index in analysis.instructions to the corresponding bytecode PC.
// Returns null if the mapping cannot be determined (e.g., out of bounds or meta instruction without a following opcode).
// PC mapping helpers are no longer needed in analysis-first UI; intentionally removed.

test "DevtoolEvm.init creates EVM instance" {
    const allocator = testing.allocator;

    var devtool_evm = try DevtoolEvm.init(allocator);
    defer devtool_evm.deinit();

    try testing.expect(devtool_evm.allocator.ptr == allocator.ptr);
    try testing.expectEqual(@as(usize, 0), devtool_evm.bytecode.len);
    try testing.expectEqual(@as(u16, 0), devtool_evm.evm.depth);
    try testing.expectEqual(false, devtool_evm.evm.read_only);
    try testing.expectEqual(false, devtool_evm.is_initialized);
    try testing.expectEqual(false, devtool_evm.is_paused);
    try testing.expect(devtool_evm.current_frame == null);
    try testing.expect(devtool_evm.current_contract == null);
}

test "DevtoolEvm.setBytecode stores bytecode" {
    const allocator = testing.allocator;

    var devtool_evm = try DevtoolEvm.init(allocator);
    defer devtool_evm.deinit();

    // Test with simple bytecode
    const test_bytecode = &[_]u8{ 0x60, 0x01, 0x60, 0x02, 0x01 }; // PUSH1 1 PUSH1 2 ADD
    try devtool_evm.setBytecode(test_bytecode);

    try testing.expectEqual(test_bytecode.len, devtool_evm.bytecode.len);
    try testing.expectEqualSlices(u8, test_bytecode, devtool_evm.bytecode);

    // Test replacing bytecode
    const new_bytecode = &[_]u8{ 0x60, 0x10, 0x60, 0x20, 0x01, 0x00 }; // PUSH1 16 PUSH1 32 ADD STOP
    try devtool_evm.setBytecode(new_bytecode);

    try testing.expectEqual(new_bytecode.len, devtool_evm.bytecode.len);
    try testing.expectEqualSlices(u8, new_bytecode, devtool_evm.bytecode);
}

test "DevtoolEvm.setBytecode handles empty bytecode" {
    const allocator = testing.allocator;

    var devtool_evm = try DevtoolEvm.init(allocator);
    defer devtool_evm.deinit();

    // Test with empty bytecode
    const empty_bytecode = &[_]u8{};
    try devtool_evm.setBytecode(empty_bytecode);

    try testing.expectEqual(@as(usize, 0), devtool_evm.bytecode.len);
}

test "DevtoolEvm.loadBytecodeHex parses hex correctly" {
    const allocator = testing.allocator;

    var devtool_evm = try DevtoolEvm.init(allocator);
    defer devtool_evm.deinit();

    // Test with 0x prefix
    try devtool_evm.loadBytecodeHex("0x6001600201");
    try testing.expectEqual(@as(usize, 5), devtool_evm.bytecode.len);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x60, 0x01, 0x60, 0x02, 0x01 }, devtool_evm.bytecode);
    try testing.expectEqual(true, devtool_evm.is_initialized);
    try testing.expect(devtool_evm.current_frame != null);
    try testing.expect(devtool_evm.current_contract != null);

    // Test without 0x prefix
    try devtool_evm.loadBytecodeHex("6010602001");
    try testing.expectEqual(@as(usize, 5), devtool_evm.bytecode.len);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x60, 0x10, 0x60, 0x20, 0x01 }, devtool_evm.bytecode);
}

test "DevtoolEvm.serializeEvmState returns valid JSON" {
    const allocator = testing.allocator;

    var devtool_evm = try DevtoolEvm.init(allocator);
    defer devtool_evm.deinit();

    // Test empty state
    const empty_json = try devtool_evm.serializeEvmState();
    defer allocator.free(empty_json);
    try testing.expect(empty_json.len > 0);

    // Test with loaded bytecode
    try devtool_evm.loadBytecodeHex("0x6001600201");
    const state_json = try devtool_evm.serializeEvmState();
    defer allocator.free(state_json);
    try testing.expect(state_json.len > 0);

    // Should contain expected fields (basic check)
    try testing.expect(std.mem.indexOf(u8, state_json, "gasLeft") != null);
    try testing.expect(std.mem.indexOf(u8, state_json, "blocks") != null);
    try testing.expect(std.mem.indexOf(u8, state_json, "currentInstructionIndex") != null);
    try testing.expect(std.mem.indexOf(u8, state_json, "currentBlockStartIndex") != null);
}

test "DevtoolEvm.stepExecute executes single visible instruction per step" {
    const allocator = testing.allocator;

    var devtool_evm = try DevtoolEvm.init(allocator);
    defer devtool_evm.deinit();

    // Test error when not initialized
    try testing.expectError(error.NotInitialized, devtool_evm.stepExecute());

    // Load simple bytecode: PUSH1 1, PUSH1 2, ADD, STOP
    try devtool_evm.loadBytecodeHex("0x6001600201");

    // One visible-instruction step should NOT complete the program
    const step1 = try devtool_evm.stepExecute();
    try testing.expectEqual(false, step1.completed);
    try testing.expectEqual(false, step1.error_occurred);
}

test "DevtoolEvm step execution modifies stack correctly" {
    const allocator = testing.allocator;

    var devtool_evm = try DevtoolEvm.init(allocator);
    defer devtool_evm.deinit();

    // Load bytecode: PUSH1 42, PUSH1 100
    try devtool_evm.loadBytecodeHex("0x602a6064");

    const frame = devtool_evm.current_frame.?;

    // Initially stack should be empty
    try testing.expectEqual(@as(usize, 0), frame.stack.size());

    // Step
    const step1 = try devtool_evm.stepExecute();
    try testing.expectEqual(false, step1.completed);
    try testing.expectEqual(@as(usize, 1), frame.stack.size());
    const value1 = try frame.stack.peek();
    try testing.expectEqual(@as(u256, 42), value1);

    // Step
    const step2 = try devtool_evm.stepExecute();
    try testing.expectEqual(false, step2.completed);
    try testing.expectEqual(@as(usize, 2), frame.stack.size());
    const value2 = try frame.stack.peek(); // Top of stack
    try testing.expectEqual(@as(u256, 100), value2);
    const value3 = try frame.stack.peek_n(1); // Second from top
    try testing.expectEqual(@as(u256, 42), value3);
}

test "DevtoolEvm complete execution flow PUSH1 5 PUSH1 10 ADD" {
    const allocator = testing.allocator;

    var devtool_evm = try DevtoolEvm.init(allocator);
    defer devtool_evm.deinit();

    // Load bytecode: PUSH1 5, PUSH1 10, ADD (0x6005600a01)
    const test_bytecode = "0x6005600a01";
    try devtool_evm.loadBytecodeHex(test_bytecode);

    // Get initial state
    const initial_state = try devtool_evm.serializeEvmState();
    defer allocator.free(initial_state);
    try testing.expect(initial_state.len > 0);

    // Step through execution
    var step_count: u32 = 0;
    var final_step: DebugStepResult = undefined;

    while (step_count < 10) { // Safety limit
        step_count += 1;

        const step_result = devtool_evm.stepExecute() catch |err| {
            try testing.expect(false); // Should not error in this test
            return err;
        };

        // Verify step information is valid
        // opcode name removed in analysis-first UI
        try testing.expect(step_result.gas_after <= step_result.gas_before);

        final_step = step_result;

        if (step_result.completed) {
            break;
        }

        if (step_result.error_occurred) {
            try testing.expect(false); // Should not error in this test
            break;
        }
    }

    // Verify execution completed
    try testing.expect(final_step.completed);
    try testing.expect(!final_step.error_occurred);

    // Get final state
    const final_state = try devtool_evm.serializeEvmState();
    defer allocator.free(final_state);
    try testing.expect(final_state.len > 0);

    // Verify stack has result (should be 15 = 5 + 10)
    if (devtool_evm.current_frame) |frame| {
        try testing.expect(frame.stack.size() > 0);
        const stack_top = try frame.stack.peek();
        try testing.expectEqual(@as(u256, 15), stack_top);
    } else {
        try testing.expect(false); // Frame should exist
    }
}

test "DevtoolEvm JSON serialization integration test" {
    const allocator = testing.allocator;

    var devtool_evm = try DevtoolEvm.init(allocator);
    defer devtool_evm.deinit();

    // Load simple bytecode: PUSH1 42
    try devtool_evm.loadBytecodeHex("0x602a");

    // Get initial state and parse JSON
    const json_state = try devtool_evm.serializeEvmState();
    defer allocator.free(json_state);

    // Parse JSON to verify structure
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_state, .{}) catch |err| {
        std.log.err("Failed to parse JSON: {}", .{err});
        try testing.expect(false);
        return;
    };
    defer parsed.deinit();

    const obj = parsed.value.object;

    // Verify required fields exist (analysis-first)
    try testing.expect(obj.contains("gasLeft"));
    try testing.expect(obj.contains("depth"));
    try testing.expect(obj.contains("stack"));
    try testing.expect(obj.contains("memory"));
    try testing.expect(obj.contains("storage"));
    try testing.expect(obj.contains("logs"));
    try testing.expect(obj.contains("returnData"));
    try testing.expect(obj.contains("blocks"));
    try testing.expect(obj.contains("currentInstructionIndex"));
    try testing.expect(obj.contains("currentBlockStartIndex"));

    // Basic sanity: there should be at least one block
    try testing.expect(obj.get("blocks") != null);

    // Execute one step and verify state changes
    _ = try devtool_evm.stepExecute();

    const json_after_step = try devtool_evm.serializeEvmState();
    defer allocator.free(json_after_step);

    const parsed_after = std.json.parseFromSlice(std.json.Value, allocator, json_after_step, .{}) catch unreachable;
    defer parsed_after.deinit();

    const obj_after = parsed_after.value.object;

    // After one block step the program may have completed; just ensure JSON parses
    try testing.expect(obj_after.contains("blocks"));
}

test "DevtoolEvm fused patterns step-by-step across blocks" {
    const allocator = testing.allocator;

    var devtool_evm = try DevtoolEvm.init(allocator);
    defer devtool_evm.deinit();

    // Bytecode layout (blocks separated by JUMPDEST to force block-per-step):
    // Block 1: PUSH1 0x05, PUSH1 0x03, ADD        => precomputed to single PUSH 0x08
    // Block 2: JUMPDEST, PUSH1 0x02, PUSH1 0x03, MUL => precomputed to single PUSH 0x06
    // Block 3: JUMPDEST, DUP1, PUSH0, EQ          => converted to ISZERO (non-zero -> 0)
    // Terminator: STOP
    // Hex: 60 05 60 03 01 5b 60 02 60 03 02 5b 80 5f 14 00
    try devtool_evm.loadBytecodeHex("0x60056003015b60026003025b805f1400");

    const frame = devtool_evm.current_frame.?;

    // Step 1: executes Block 1, stack: [0x08]
    const s1 = try devtool_evm.stepExecute();
    try testing.expectEqual(false, s1.completed);
    try testing.expectEqual(@as(usize, 1), frame.stack.size());
    const v1 = try frame.stack.peek();
    try testing.expectEqual(@as(u256, 8), v1);

    // Step 2: executes Block 2, stack: [0x08, 0x06]
    const s2 = try devtool_evm.stepExecute();
    try testing.expectEqual(false, s2.completed);
    try testing.expectEqual(@as(usize, 2), frame.stack.size());
    const v2_top = try frame.stack.peek();
    try testing.expectEqual(@as(u256, 6), v2_top);
    const v2_second = try frame.stack.peek_n(1);
    try testing.expectEqual(@as(u256, 8), v2_second);

    // Step 3: executes Block 3 first visible instruction (ISZERO on top=6 -> 0)
    // After ISZERO: stack becomes [0x08, 0x00]; not completed yet
    const s3 = try devtool_evm.stepExecute();
    try testing.expectEqual(false, s3.completed);
    try testing.expectEqual(@as(usize, 2), frame.stack.size());
    const v3_top = try frame.stack.peek();
    try testing.expectEqual(@as(u256, 0), v3_top);
    const v3_second = try frame.stack.peek_n(1);
    try testing.expectEqual(@as(u256, 8), v3_second);

    // Step 4: executes STOP in the same block; now completed
    const s4 = try devtool_evm.stepExecute();
    try testing.expectEqual(true, s4.completed);
}
