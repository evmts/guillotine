const std = @import("std");
const Evm = @import("evm");
const primitives = @import("primitives");
const MemoryDatabase = Evm.MemoryDatabase;
const DatabaseInterface = Evm.DatabaseInterface;
// Use primitives.Address module directly
const Bytes32 = primitives.Bytes32;
const StorageKey = primitives.StorageKey;
const testing = std.testing;
const debug_state = @import("debug_state.zig");

const DevtoolEvm = @This();

allocator: std.mem.Allocator,
database: MemoryDatabase,
evm: Evm.Evm,
bytecode: []u8,

// Debug-specific fields
current_frame: ?*Evm.Frame,
current_contract: ?*Evm.Contract,
is_paused: bool,
is_initialized: bool,

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
    var evm = try Evm.Evm.init(
        allocator,
        db_interface,
        null, // table
        null, // chain_rules
        null, // context
        0, // depth
        false, // read_only
        null, // tracer
    );
    errdefer evm.deinit();
    
    var storage_changes = std.AutoHashMap(StorageKey, u256).init(allocator);
    errdefer storage_changes.deinit();
    
    return DevtoolEvm{
        .allocator = allocator,
        .database = database,
        .evm = evm,
        .bytecode = &[_]u8{},
        .current_frame = null,
        .current_contract = null,
        .is_paused = false,
        .is_initialized = false,
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
    
    // Clear storage tracking
    self.storage_changes.clearRetainingCapacity();
    
    if (self.bytecode.len == 0) {
        self.is_initialized = false;
        return;
    }
    
    // Create contract from bytecode
    const contract = try self.allocator.create(Evm.Contract);
    errdefer self.allocator.destroy(contract);
    
    contract.* = Evm.Contract.init_at_address(
        primitives.Address.ZERO, // caller
        primitives.Address.ZERO, // address  
        0, // value
        1000000, // gas
        self.bytecode,
        &[_]u8{}, // input
        false // is_static
    );
    
    self.current_contract = contract;
    
    // Create execution frame
    const frame = try self.allocator.create(Evm.Frame);
    errdefer self.allocator.destroy(frame);
    
    // Frame.init now requires vm parameter
    var dummy_vm: Evm.Evm = undefined;
    frame.* = try Evm.Frame.init(self.allocator, &dummy_vm, contract);
    frame.gas_remaining = 1000000; // Set gas after init
    
    self.current_frame = frame;
    
    self.is_initialized = true;
    self.is_paused = false;
}

/// Get current EVM state as JSON string
pub fn serializeEvmState(self: *DevtoolEvm) ![]u8 {
    if (!self.is_initialized or self.current_frame == null) {
        const empty_state = try debug_state.createEmptyEvmStateJson(self.allocator);
        defer debug_state.freeEvmStateJson(self.allocator, empty_state);
        return try std.json.stringifyAlloc(self.allocator, empty_state, .{});
    }
    
    const frame = self.current_frame.?;
    const opcode = if (frame.pc < self.bytecode.len) self.bytecode[frame.pc] else 0;
    
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
    
    const state = debug_state.EvmStateJson{
        .pc = frame.pc,
        .opcode = try self.allocator.dupe(u8, debug_state.opcodeToString(opcode)),
        .gasLeft = frame.gas_remaining,
        .depth = frame.depth,
        .stack = try debug_state.serializeStack(self.allocator, &frame.stack),
        .memory = try debug_state.serializeMemory(self.allocator, &frame.memory),
        .storage = try storage_entries.toOwnedSlice(),
        .logs = try self.allocator.alloc([]const u8, 0), // TODO: Implement logs serialization
        .returnData = try debug_state.formatBytesHex(self.allocator, frame.output),
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
    
    const frame = self.current_frame.?;
    
    // Check if execution is complete
    if (frame.pc >= self.bytecode.len or frame.stop or frame.err != null) {
        return DebugStepResult{
            .opcode = 0,
            .opcode_name = "COMPLETE",
            .pc_before = frame.pc,
            .pc_after = frame.pc,
            .gas_before = frame.gas_remaining,
            .gas_after = frame.gas_remaining,
            .completed = true,
            .error_occurred = frame.err != null,
            .execution_error = frame.err,
        };
    }
    
    // Capture pre-execution state
    const pc_before = frame.pc;
    const gas_before = frame.gas_remaining;
    const opcode = self.bytecode[pc_before];
    
    // Check if this is SSTORE to track storage changes
    if (opcode == 0x55 and frame.stack.size >= 2) {
        // Get the key and value from stack (without popping)
        const key = try frame.stack.peek_n(0);
        const value = try frame.stack.peek_n(1);
        
        // Create storage key for tracking
        const storage_key = StorageKey{
            .address = self.current_contract.?.address,
            .slot = key,
        };
        
        // Track the storage change
        try self.storage_changes.put(storage_key, value);
    }
    
    // Execute single instruction using existing EVM table
    const interpreter_ptr: *Evm.Evm = &self.evm;
    const state_ptr: *Evm.Frame = frame;
    const result = self.evm.table.execute(pc_before, interpreter_ptr, state_ptr, opcode) catch |err| {
        return DebugStepResult{
            .opcode = opcode,
            .opcode_name = debug_state.opcodeToString(opcode),
            .pc_before = pc_before,
            .pc_after = frame.pc,
            .gas_before = gas_before,
            .gas_after = frame.gas_remaining,
            .completed = true,
            .error_occurred = true,
            .execution_error = err,
        };
    };
    
    // Update PC if it wasn't changed by the instruction (e.g., JUMP didn't occur)
    if (frame.pc == pc_before) {
        frame.pc += result.bytes_consumed;
    }
    
    // Capture post-execution state
    const pc_after = frame.pc;
    const gas_after = frame.gas_remaining;
    const execution_complete = frame.stop or pc_after >= self.bytecode.len or frame.err != null;
    
    return DebugStepResult{
        .opcode = opcode,
        .opcode_name = debug_state.opcodeToString(opcode),
        .pc_before = pc_before,
        .pc_after = pc_after,
        .gas_before = gas_before,
        .gas_after = gas_after,
        .completed = execution_complete,
        .error_occurred = frame.err != null,
        .execution_error = frame.err,
    };
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
    try testing.expectEqualSlices(u8, &[_]u8{0x60, 0x01, 0x60, 0x02, 0x01}, devtool_evm.bytecode);
    try testing.expectEqual(true, devtool_evm.is_initialized);
    try testing.expect(devtool_evm.current_frame != null);
    try testing.expect(devtool_evm.current_contract != null);
    
    // Test without 0x prefix
    try devtool_evm.loadBytecodeHex("6010602001");
    try testing.expectEqual(@as(usize, 5), devtool_evm.bytecode.len);
    try testing.expectEqualSlices(u8, &[_]u8{0x60, 0x10, 0x60, 0x20, 0x01}, devtool_evm.bytecode);
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
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        json_state,
        .{}
    ) catch |err| {
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
    
    const parsed_after = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        json_after_step,
        .{}
    ) catch unreachable;
    defer parsed_after.deinit();
    
    const obj_after = parsed_after.value.object;
    
    // PC should have advanced
    try testing.expectEqual(@as(i64, 2), obj_after.get("pc").?.integer);
    
    // Stack should have one item
    const stack_array = obj_after.get("stack").?.array;
    try testing.expectEqual(@as(usize, 1), stack_array.items.len);
    try testing.expectEqualStrings("0x2a", stack_array.items[0].string); // 42 in hex
}