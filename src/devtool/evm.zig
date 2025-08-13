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
last_opcode: u8,
current_pc: usize,
is_paused: bool,
is_initialized: bool,
is_completed: bool,

// Storage tracking for debugging
storage_changes: std.AutoHashMap(StorageKey, u256),

/// Result of a single step execution
pub const DebugStepResult = struct {
    opcode: u8,
    opcode_name: []const u8,
    pc_before: usize,
    pc_after: usize,
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
        .last_opcode = 0,
        .is_paused = false,
        .is_initialized = false,
        .is_completed = false,
        .current_pc = 0,
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
    self.current_frame = frame_ptr;

    self.is_initialized = true;
    self.is_paused = false;
    // Always start at the first instruction (BEGINBLOCK). The step loop will
    // process the BEGINBLOCK meta (charge gas/validate) and then advance to the
    // first visible opcode in the same call.
    self.instr_index = 0;
    self.last_opcode = if (self.bytecode.len > 0) blk: {
        // Prefer the first visible instruction's opcode
        const pc0 = self.instructionIndexToPc(self.instr_index) orelse 0;
        break :blk self.bytecode[pc0];
    } else 0;
    self.is_completed = false;
    // Initialize current_pc to the first visible instruction's pc
    const init_pc = blk: {
        if (self.analysis) |a| {
            // Skip any initial BEGINBLOCKs
            const instructions = a.instructions;
            var idx: usize = self.instr_index;
            while (idx < instructions.len and instructions[idx].arg == .block_info) : (idx += 1) {}
            if (self.findPcForInstructionIndex(idx)) |pc_val| break :blk pc_val;
        }
        break :blk 0;
    };
    self.current_pc = init_pc;
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

    // Display the next-instruction PC/opcode tracked by the stepper.
    const pc_now: usize = if (self.is_completed) 0 else self.current_pc;
    const shown_opcode: []const u8 = if (self.is_completed)
        "COMPLETE"
    else blk: {
        const op_byte: u8 = if (pc_now < self.bytecode.len) self.bytecode[pc_now] else 0;
        break :blk debug_state.opcodeToString(op_byte);
    };
    const state = debug_state.EvmStateJson{
        .pc = if (self.is_completed) 0 else pc_now,
        .opcode = try self.allocator.dupe(u8, shown_opcode),
        .gasLeft = frame.gas_remaining,
        .depth = frame.depth,
        .stack = try debug_state.serializeStack(self.allocator, &frame.stack),
        .memory = try debug_state.serializeMemory(self.allocator, &frame.memory),
        .storage = try storage_entries.toOwnedSlice(),
        .logs = try self.allocator.alloc([]const u8, 0),
        .returnData = try debug_state.formatBytesHex(self.allocator, self.host.get_output()),
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
            .opcode = 0,
            .opcode_name = "COMPLETE",
            .pc_before = 0,
            .pc_after = 0,
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
            .opcode = 0,
            .opcode_name = "COMPLETE",
            .pc_before = 0,
            .pc_after = 0,
            .gas_before = frame.gas_remaining,
            .gas_after = frame.gas_remaining,
            .completed = true,
            .error_occurred = false,
            .execution_error = null,
        };
    }

    // Determine pc_before/opcode from the bytecode program counter we track
    const pc_before: usize = if (self.is_completed) 0 else self.current_pc;
    if (pc_before < self.bytecode.len) self.last_opcode = self.bytecode[pc_before] else self.last_opcode = 0;
    const gas_before = frame.gas_remaining;

    var exec_err: ?Evm.ExecutionError.Error = null;

    // Execute exactly one visible instruction; handle block and jump meta inline
    var made_visible_progress = false;
    var new_pc: usize = pc_before; // compute next-instruction PC using bytecode semantics
    while (!made_visible_progress) {
        if (self.instr_index >= instructions.len) break;

        const inst = instructions[self.instr_index];
        switch (inst.arg) {
            .block_info => |block| {
                // Validate gas for whole block
                if (frame.gas_remaining < block.gas_cost) {
                    frame.gas_remaining = 0;
                    exec_err = Evm.ExecutionError.Error.OutOfGas;
                    self.is_completed = true;
                    break;
                }
                frame.gas_remaining -= block.gas_cost;

                // Validate stack bounds for block
                const current_stack_size: u16 = @intCast(frame.stack.size());
                if (current_stack_size < block.stack_req) {
                    exec_err = Evm.ExecutionError.Error.StackUnderflow;
                    self.is_completed = true;
                    break;
                }
                if (current_stack_size + block.stack_max_growth > 1024) {
                    exec_err = Evm.ExecutionError.Error.StackOverflow;
                    self.is_completed = true;
                    break;
                }
                // Advance past BEGINBLOCK and continue loop to reach a visible opcode
                self.instr_index += 1;
                continue;
            },
            .conditional_jump => |true_target| {
                // Optimized JUMPI: destination resolved at analysis time
                const cond = frame.stack.pop_unsafe();
                if (cond != 0) {
                    const base: [*]const @TypeOf(inst) = instructions.ptr;
                    const idx = (@intFromPtr(true_target) - @intFromPtr(base)) / @sizeOf(@TypeOf(inst));
                    self.instr_index = idx;
                    // Map instruction index to PC for debugger view
                    if (self.findPcForInstructionIndex(idx)) |pc_val| {
                        new_pc = pc_val;
                    }
                } else {
                    self.instr_index += 1;
                    if (pc_before < self.bytecode.len) new_pc = pc_before + 1;
                }
                made_visible_progress = true;
                continue;
            },
            .word => |value| {
                // PUSH value onto stack (visible)
                self.instr_index += 1;
                frame.stack.append(value) catch |err| {
                    exec_err = err;
                };
                // advance PC by PUSH opcode size (opcode + immediate length)
                if (pc_before < self.bytecode.len) {
                    const op = self.bytecode[pc_before];
                    const imm_len: usize = if (op == 0x5f) 0 else if (op >= 0x60 and op <= 0x7f) @intCast(op - 0x5f) else 0;
                    new_pc = pc_before + 1 + imm_len;
                }
                made_visible_progress = true;
            },
            .keccak => |params| {
                // Charge static gas
                if (frame.gas_remaining < params.gas_cost) {
                    frame.gas_remaining = 0;
                    exec_err = Evm.ExecutionError.Error.OutOfGas;
                    self.is_completed = true;
                    break;
                }
                frame.gas_remaining -= params.gas_cost;
                // Resolve size: immediate if present, else from stack
                const size: u256 = if (params.size) |imm| @as(u256, @intCast(imm)) else frame.stack.pop_unsafe();
                const offset = frame.stack.pop_unsafe();
                if (offset > std.math.maxInt(usize) or size > std.math.maxInt(usize)) {
                    exec_err = Evm.ExecutionError.Error.OutOfOffset;
                    self.is_completed = true;
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
                        break;
                    };
                    var hash: [32]u8 = undefined;
                    std.crypto.hash.sha3.Keccak256.hash(data, &hash, .{});
                    const result = std.mem.readInt(u256, &hash, .big);
                    frame.stack.append_unsafe(result);
                }
                // Advance one opcode byte
                self.instr_index += 1;
                if (pc_before < self.bytecode.len) new_pc = pc_before + 1;
                made_visible_progress = true;
            },
            .none => {
                // Dynamic jump handling if needed
                const jt = analysis.inst_jump_type[self.instr_index];
                switch (jt) {
                    .jump => {
                        const dest = frame.stack.pop_unsafe();
                        if (!frame.valid_jumpdest(dest)) {
                            exec_err = Evm.ExecutionError.Error.InvalidJump;
                            self.is_completed = true;
                            break;
                        }
                        const dest_usize: usize = @intCast(dest);
                        const idx = analysis.pc_to_block_start[dest_usize];
                        if (idx == std.math.maxInt(u16) or idx >= instructions.len) {
                            exec_err = Evm.ExecutionError.Error.InvalidJump;
                            self.is_completed = true;
                            break;
                        }
                        self.instr_index = idx;
                        new_pc = dest_usize;
                        made_visible_progress = true; // JUMP is a visible opcode
                        continue;
                    },
                    .jumpi => {
                        const pops = frame.stack.pop2_unsafe();
                        const dest = pops.a;
                        const cond = pops.b;
                        if (cond != 0) {
                            if (!frame.valid_jumpdest(dest)) {
                                exec_err = Evm.ExecutionError.Error.InvalidJump;
                                self.is_completed = true;
                                break;
                            }
                            const dest_usize: usize = @intCast(dest);
                            const idx = analysis.pc_to_block_start[dest_usize];
                            if (idx == std.math.maxInt(u16) or idx >= instructions.len) {
                                exec_err = Evm.ExecutionError.Error.InvalidJump;
                                self.is_completed = true;
                                break;
                            }
                            self.instr_index = idx;
                            new_pc = dest_usize;
                        } else {
                            self.instr_index += 1;
                            // fall through to next byte after JUMPI opcode
                            if (pc_before < self.bytecode.len) new_pc = pc_before + 1;
                        }
                        made_visible_progress = true; // JUMPI is visible
                        continue;
                    },
                    .other => {
                        // Execute opcode function
                        self.instr_index += 1;
                        made_visible_progress = true;
                        inst.opcode_fn(@ptrCast(frame)) catch |err| {
                            if (err == Evm.ExecutionError.Error.InvalidOpcode) {
                                frame.gas_remaining = 0;
                            }
                            exec_err = err;
                        };
                        // Most non-push non-jump opcodes are 1 byte
                        if (pc_before < self.bytecode.len) new_pc = pc_before + 1;
                    },
                }
            },
            .gas_cost => |cost| {
                // Legacy path
                if (frame.gas_remaining < cost) {
                    frame.gas_remaining = 0;
                    exec_err = Evm.ExecutionError.Error.OutOfGas;
                    self.is_completed = true;
                    break;
                }
                frame.gas_remaining -= cost;
                self.instr_index += 1;
                made_visible_progress = true;
                inst.opcode_fn(@ptrCast(frame)) catch |err| {
                    if (err == Evm.ExecutionError.Error.InvalidOpcode) {
                        frame.gas_remaining = 0;
                    }
                    exec_err = err;
                };
                if (pc_before < self.bytecode.len) new_pc = pc_before + 1;
            },
            .dynamic_gas => |dyn_gas| {
                // Charge static
                if (frame.gas_remaining < dyn_gas.static_cost) {
                    frame.gas_remaining = 0;
                    exec_err = Evm.ExecutionError.Error.OutOfGas;
                    self.is_completed = true;
                    break;
                }
                frame.gas_remaining -= dyn_gas.static_cost;
                // Charge dynamic if any
                if (dyn_gas.gas_fn) |gas_fn| {
                    const additional = gas_fn(frame) catch |err| {
                        if (err == Evm.ExecutionError.Error.OutOfOffset) {
                            exec_err = err;
                            self.is_completed = true;
                            break;
                        }
                        frame.gas_remaining = 0;
                        exec_err = Evm.ExecutionError.Error.OutOfGas;
                        self.is_completed = true;
                        break;
                    };
                    if (exec_err != null) break;
                    if (frame.gas_remaining < additional) {
                        frame.gas_remaining = 0;
                        exec_err = Evm.ExecutionError.Error.OutOfGas;
                        self.is_completed = true;
                        break;
                    }
                    frame.gas_remaining -= additional;
                }
                self.instr_index += 1;
                made_visible_progress = true;
                inst.opcode_fn(@ptrCast(frame)) catch |err| {
                    if (err == Evm.ExecutionError.Error.InvalidOpcode) {
                        frame.gas_remaining = 0;
                    }
                    exec_err = err;
                };
                if (pc_before < self.bytecode.len) new_pc = pc_before + 1;
            },
        }

        if (exec_err) |e| {
            if (e == Evm.ExecutionError.Error.STOP or e == Evm.ExecutionError.Error.REVERT) {
                self.is_completed = true;
                break;
            }
            // Other errors also end execution for devtool purposes
            self.is_completed = true;
            break;
        }
    }

    // Update program counter for UI to the next instruction using bytecode semantics
    if (!self.is_completed) {
        self.current_pc = if (new_pc < self.bytecode.len) new_pc else new_pc;
        if (self.current_pc < self.bytecode.len) self.last_opcode = self.bytecode[self.current_pc] else self.last_opcode = 0;
    } else {
        self.current_pc = 0;
        self.last_opcode = 0;
    }

    const had_error = exec_err != null and exec_err.? != Evm.ExecutionError.Error.STOP;
    const completed = self.is_completed;

    // Resolve current opcode name for result (based on pc_before)
    const opcode_byte_before: u8 = if (completed and exec_err == null)
        0
    else if (pc_before < self.bytecode.len)
        self.bytecode[pc_before]
    else
        0;
    const opcode_name_before = if (completed and exec_err == null)
        "COMPLETE"
    else
        debug_state.opcodeToString(opcode_byte_before);

    const pc_after_val = self.current_pc;
    return DebugStepResult{
        .opcode = opcode_byte_before,
        .opcode_name = opcode_name_before,
        .pc_before = pc_before,
        .pc_after = pc_after_val,
        .gas_before = gas_before,
        .gas_after = frame.gas_remaining,
        .completed = completed,
        .error_occurred = had_error,
        .execution_error = if (had_error) exec_err else null,
    };
}

// Map an instruction index in analysis.instructions to the corresponding bytecode PC.
// Returns null if the mapping cannot be determined (e.g., out of bounds or meta instruction without a following opcode).
fn instructionIndexToPc(self: *const DevtoolEvm, instr_idx: usize) ?usize {
    if (self.analysis == null) return null;
    const analysis = self.analysis.?;
    if (analysis.instructions.len == 0 or analysis.code_len == 0) return null;
    if (instr_idx >= analysis.instructions.len) return null;

    // Find BEGINBLOCK index for this instruction
    var block_start: usize = 0;
    var i: usize = instr_idx;
    while (true) {
        if (analysis.instructions[i].arg == .block_info) {
            block_start = i;
            break;
        }
        if (i == 0) break;
        i -= 1;
    }

    // Determine position within block counting only visible opcodes
    var visible_index_in_block: usize = 0;
    var j: usize = block_start + 1;
    while (j < analysis.instructions.len and j < instr_idx) : (j += 1) {
        if (analysis.instructions[j].arg != .block_info) {
            visible_index_in_block += 1;
        }
    }

    // Iterate PCs mapped to this block and pick the nth visible
    var count: usize = 0;
    var pc: usize = 0;
    while (pc < analysis.code_len) : (pc += 1) {
        if (analysis.pc_to_block_start[pc] == block_start) {
            if (count == visible_index_in_block) return pc;
            count += 1;
        }
    }
    return null;
}

// More robust PC lookup that uses CodeAnalysis.pc_to_instruction when available,
// and falls back to instructionIndexToPc otherwise.
fn findPcForInstructionIndex(self: *const DevtoolEvm, instr_idx: usize) ?usize {
    if (self.analysis == null) return null;
    const analysis = self.analysis.?;
    if (instr_idx >= analysis.instructions.len) return null;
    // Try a direct scan using the block mapping to find the first PC whose
    // mapped instruction index equals the requested index by comparing through
    // instructionIndexToPc for each candidate.
    var pc: usize = 0;
    while (pc < analysis.code_len) : (pc += 1) {
        if (self.instructionIndexToPc(instr_idx)) |candidate_pc| {
            if (candidate_pc == pc) return pc;
        } else break;
    }
    // Fallback to block-based mapping
    return self.instructionIndexToPc(instr_idx);
}

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
    try testing.expect(std.mem.indexOf(u8, state_json, "pc") != null);
    try testing.expect(std.mem.indexOf(u8, state_json, "opcode") != null);
    try testing.expect(std.mem.indexOf(u8, state_json, "gasLeft") != null);
}

test "DevtoolEvm.stepExecute executes single instructions" {
    const allocator = testing.allocator;

    var devtool_evm = try DevtoolEvm.init(allocator);
    defer devtool_evm.deinit();

    // Test error when not initialized
    try testing.expectError(error.NotInitialized, devtool_evm.stepExecute());

    // Load simple bytecode: PUSH1 1, PUSH1 2, ADD, STOP
    try devtool_evm.loadBytecodeHex("0x6001600201");

    // Step 1: PUSH1 1 (0x60 0x01)
    const step1 = try devtool_evm.stepExecute();
    try testing.expectEqual(@as(u8, 0x60), step1.opcode);
    try testing.expectEqualStrings("PUSH1", step1.opcode_name);
    try testing.expectEqual(@as(usize, 0), step1.pc_before);
    try testing.expectEqual(@as(usize, 2), step1.pc_after); // PUSH1 consumes 2 bytes
    try testing.expectEqual(false, step1.completed);
    try testing.expectEqual(false, step1.error_occurred);
    try testing.expect(step1.gas_after < step1.gas_before); // Gas was consumed

    // Step 2: PUSH1 2 (0x60 0x02)
    const step2 = try devtool_evm.stepExecute();
    try testing.expectEqual(@as(u8, 0x60), step2.opcode);
    try testing.expectEqualStrings("PUSH1", step2.opcode_name);
    try testing.expectEqual(@as(usize, 2), step2.pc_before);
    try testing.expectEqual(@as(usize, 4), step2.pc_after);
    try testing.expectEqual(false, step2.completed);

    // Step 3: ADD (0x01)
    const step3 = try devtool_evm.stepExecute();
    try testing.expectEqual(@as(u8, 0x01), step3.opcode);
    try testing.expectEqualStrings("ADD", step3.opcode_name);
    try testing.expectEqual(@as(usize, 4), step3.pc_before);
    try testing.expectEqual(@as(usize, 5), step3.pc_after);
    try testing.expectEqual(true, step3.completed); // Reached end of bytecode
    try testing.expectEqual(false, step3.error_occurred);

    // Step 4: Should indicate completion
    const step4 = try devtool_evm.stepExecute();
    try testing.expectEqualStrings("COMPLETE", step4.opcode_name);
    try testing.expectEqual(true, step4.completed);
}

test "DevtoolEvm step execution modifies stack correctly" {
    const allocator = testing.allocator;

    var devtool_evm = try DevtoolEvm.init(allocator);
    defer devtool_evm.deinit();

    // Load bytecode: PUSH1 42, PUSH1 100
    try devtool_evm.loadBytecodeHex("0x602a6064");

    const frame = devtool_evm.current_frame.?;

    // Initially stack should be empty
    try testing.expectEqual(@as(usize, 0), frame.stack.size);

    // Execute PUSH1 42
    const step1 = try devtool_evm.stepExecute();
    try testing.expectEqualStrings("PUSH1", step1.opcode_name);
    try testing.expectEqual(@as(usize, 1), frame.stack.size);
    const value1 = try frame.stack.peek();
    try testing.expectEqual(@as(u256, 42), value1);

    // Execute PUSH1 100
    const step2 = try devtool_evm.stepExecute();
    try testing.expectEqualStrings("PUSH1", step2.opcode_name);
    try testing.expectEqual(@as(usize, 2), frame.stack.size);
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
        try testing.expect(step_result.opcode_name.len > 0);
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
        try testing.expect(frame.stack.size > 0);
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

    // Verify required fields exist
    try testing.expect(obj.contains("pc"));
    try testing.expect(obj.contains("opcode"));
    try testing.expect(obj.contains("gasLeft"));
    try testing.expect(obj.contains("depth"));
    try testing.expect(obj.contains("stack"));
    try testing.expect(obj.contains("memory"));
    try testing.expect(obj.contains("storage"));
    try testing.expect(obj.contains("logs"));
    try testing.expect(obj.contains("returnData"));

    // Verify initial state values
    try testing.expectEqual(@as(i64, 0), obj.get("pc").?.integer);
    try testing.expectEqualStrings("PUSH1", obj.get("opcode").?.string);

    // Execute one step and verify state changes
    _ = try devtool_evm.stepExecute();

    const json_after_step = try devtool_evm.serializeEvmState();
    defer allocator.free(json_after_step);

    const parsed_after = std.json.parseFromSlice(std.json.Value, allocator, json_after_step, .{}) catch unreachable;
    defer parsed_after.deinit();

    const obj_after = parsed_after.value.object;

    // PC should have advanced
    try testing.expectEqual(@as(i64, 2), obj_after.get("pc").?.integer);

    // Stack should have one item
    const stack_array = obj_after.get("stack").?.array;
    try testing.expectEqual(@as(usize, 1), stack_array.items.len);
    try testing.expectEqualStrings("0x2a", stack_array.items[0].string); // 42 in hex
}
