const std = @import("std");
const FrameConfig = @import("../frame/frame_config.zig").FrameConfig;
const log = @import("../log.zig");
const GasConstants = @import("primitives").GasConstants;
const Address = @import("primitives").Address.Address;
const Opcode = @import("../opcodes/opcode_data.zig").Opcode;

/// Storage operation handlers for the EVM stack frame.
/// These are generic structs that return static handlers for a given FrameType.
pub fn Handlers(comptime FrameType: type) type {
    return struct {
        pub const Error = FrameType.Error;
        pub const Dispatch = FrameType.Dispatch;
        pub const WordType = FrameType.WordType;

        /// SLOAD opcode (0x54) - Load from storage.
        /// Loads value from storage slot and pushes it onto the stack.
        pub fn sload(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            const dispatch = Dispatch{ .cursor = cursor };
            // SLOAD loads a value from storage

            std.debug.assert(self.stack.size() >= 1); // SLOAD requires 1 stack item
            const slot = self.stack.pop_unsafe();

            // Use the currently executing contract's address
            const contract_addr = self.contract_address;

            // Access storage slot and get gas cost (cold vs warm)
            const evm = self.getEvm();
            const access_cost = evm.access_storage_slot(contract_addr, slot) catch |err| switch (err) {
                else => return Error.AllocationError,
            };

            // Charge gas for storage access
            // Use negative gas pattern for single-branch out-of-gas detection
            self.gas_remaining -= @intCast(access_cost);
            if (self.gas_remaining < 0) {
                return Error.OutOfGas;
            }

            // Load value from storage directly from frame's database
            const value = self.database.get_storage(contract_addr.bytes, slot) catch |err| switch (err) {
                else => return Error.AllocationError,
            };
            std.debug.assert(self.stack.size() < @TypeOf(self.stack).stack_capacity); // Ensure space for push
            self.stack.push_unsafe(value);

            const op_data = dispatch.getOpData(.SLOAD);
            // Use op_data.next_handler and op_data.next_cursor directly
            return @call(FrameType.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
        }

        /// SSTORE opcode (0x55) - Store to storage.
        /// Stores value to storage slot. Subject to gas refunds and write protection checks.
        /// EIP-214: Static calls use database that throws WriteProtection errors
        pub fn sstore(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            const dispatch = Dispatch{ .cursor = cursor };
            // SSTORE stores a value to storage

            // EIP-214: WriteProtection is handled by database interface for static calls

            // SSTORE expects stack: [..., key, value] where key is at top
            // The bytecode PUSH1 0x42, PUSH1 0x00, SSTORE means:
            // - First push 0x42 (goes to stack position 0)
            // - Then push 0x00 (goes to stack position 1, becoming the top)
            // - SSTORE pops key first (0x00), then value (0x42)
            std.debug.assert(self.stack.size() >= 2); // SSTORE requires 2 stack items
            const slot = self.stack.pop_unsafe(); // Pop key/slot first (top of stack)
            const value = self.stack.pop_unsafe(); // Pop value second

            // Use the currently executing contract's address
            const contract_addr = self.contract_address;

            // Get current value for gas calculation
            const current_value = self.database.get_storage(contract_addr.bytes, slot) catch |err| switch (err) {
                else => return Error.AllocationError,
            };

            // Access storage slot once to both warm it and get cost
            const evm = self.getEvm();
            const access_cost = evm.access_storage_slot(contract_addr, slot) catch |err| switch (err) {
                else => return Error.AllocationError,
            };
            const is_cold = access_cost == GasConstants.ColdSloadCost;

            // Determine original value at start of transaction (for EIP-2200 logic)
            const original_opt = evm.get_original_storage(contract_addr, slot);
            const original_value: WordType = original_opt orelse current_value;

            // Calculate SSTORE operation cost (includes cold access cost if applicable)
            const total_gas_cost: u64 = GasConstants.sstore_gas_cost(current_value, original_value, value, is_cold);


            log.debug(
                "SSTORE metering: slot={}, original={}, current={}, new={}, is_cold={}, total={}",
                .{ slot, original_value, current_value, value, is_cold, total_gas_cost },
            );

            // Use negative gas pattern for single-branch out-of-gas detection
            self.gas_remaining -= @intCast(total_gas_cost);
            if (self.gas_remaining < 0) {
                return Error.OutOfGas;
            }

            // Record original value for journal on first write in this transaction
            if (original_opt == null) {
                evm.record_storage_change(contract_addr, slot, original_value) catch |err| switch (err) {
                    else => return Error.AllocationError,
                };
            }

            // Store the value directly in frame's database
            self.database.set_storage(contract_addr.bytes, slot, value) catch |err| switch (err) {
                error.WriteProtection => return Error.WriteProtection,
                else => return Error.AllocationError,
            };

            // EIP-3529: Only clearing (non-zero -> zero) is eligible for refund
            if (current_value != 0 and value == 0) {
                evm.add_gas_refund(GasConstants.SstoreRefundGas);
            }

            const op_data = dispatch.getOpData(.SSTORE);
            // Use op_data.next_handler and op_data.next_cursor directly
            return @call(FrameType.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
        }

        /// TLOAD opcode (0x5c) - Load from transient storage (EIP-1153).
        /// Loads value from transient storage slot and pushes it onto the stack.
        pub fn tload(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            const dispatch = Dispatch{ .cursor = cursor };
            std.debug.assert(self.stack.size() >= 1); // TLOAD requires 1 stack item
            const slot = self.stack.pop_unsafe();

            // Use the currently executing contract's address
            const contract_addr = self.contract_address;

            // Load value from transient storage directly from frame's database
            const value = self.database.get_transient_storage(contract_addr.bytes, slot) catch |err| switch (err) {
                else => return Error.AllocationError,
            };

            std.debug.assert(self.stack.size() < @TypeOf(self.stack).stack_capacity); // Ensure space for push
            self.stack.push_unsafe(value);

            const op_data = dispatch.getOpData(.TLOAD);
            // Use op_data.next_handler and op_data.next_cursor directly
            return @call(FrameType.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
        }

        /// TSTORE opcode (0x5d) - Store to transient storage (EIP-1153).
        /// Stores value to transient storage slot (cleared after transaction).
        pub fn tstore(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            const dispatch = Dispatch{ .cursor = cursor };

            // EIP-214: WriteProtection is handled by host interface for static calls

            // TSTORE expects stack: [..., key, value] where key is at top
            std.debug.assert(self.stack.size() >= 2); // TSTORE requires 2 stack items
            const slot = self.stack.pop_unsafe(); // Pop key/slot first (top of stack)
            const value = self.stack.pop_unsafe(); // Pop value second

            // Use the currently executing contract's address
            const contract_addr = self.contract_address;

            // Transient storage has fixed gas cost
            const gas_cost = GasConstants.WarmStorageReadCost; // 100 gas
            // Use negative gas pattern for single-branch out-of-gas detection
            self.gas_remaining -= @intCast(gas_cost);
            if (self.gas_remaining < 0) {
                return Error.OutOfGas;
            }

            // Store the value in transient storage directly in frame's database
            self.database.set_transient_storage(contract_addr.bytes, slot, value) catch |err| switch (err) {
                error.WriteProtection => return Error.WriteProtection,
                else => return Error.AllocationError,
            };

            const op_data = dispatch.getOpData(.TSTORE);
            // Use op_data.next_handler and op_data.next_cursor directly
            return @call(FrameType.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
        }
    };
}

// ====== TESTS ======

const testing = std.testing;
const Frame = @import("../frame/frame.zig").Frame;
const dispatch_mod = @import("../preprocessor/dispatch.zig");
const NoOpTracer = @import("../tracer/tracer.zig").NoOpTracer;
// const Host = @import("evm.zig").Host;

// Test configuration with database enabled
const test_config = FrameConfig{
    .stack_size = 1024,
    .WordType = u256,
    .max_bytecode_size = 1024,
    .block_gas_limit = 30_000_000,
    .DatabaseType = @import("../storage/memory_database.zig").MemoryDatabase, // Always provide database type
    .memory_initial_capacity = 4096,
    .memory_limit = 0xFFFFFF,
};

const TestFrame = Frame(test_config);
const TestHandlers = Handlers(TestFrame);

// Mock EVM for testing
const MockEvm = struct {
    storage: std.AutoHashMap(StorageKey, u256),
    transient_storage: std.AutoHashMap(StorageKey, u256),
    accessed_slots: std.AutoHashMap(StorageKey, void),
    is_static: bool = false,

    const StorageKey = struct {
        address: Address,
        slot: u256,
    };

    pub fn init(allocator: std.mem.Allocator) MockEvm {
        return .{
            .storage = std.AutoHashMap(StorageKey, u256).init(allocator),
            .transient_storage = std.AutoHashMap(StorageKey, u256).init(allocator),
            .accessed_slots = std.AutoHashMap(StorageKey, void).init(allocator),
        };
    }

    pub fn deinit(self: *MockEvm) void {
        self.storage.deinit();
        self.transient_storage.deinit();
        self.accessed_slots.deinit();
    }

    pub fn access_storage_slot(self: *MockEvm, address: Address, slot: u256) !u64 {
        const key = StorageKey{ .address = address, .slot = slot };
        try self.accessed_slots.put(key, {});
        return 0; // Return 0 gas cost for testing
    }

    pub fn get_storage(self: *MockEvm, address: Address, slot: u256) u256 {
        const key = StorageKey{ .address = address, .slot = slot };
        return self.storage.get(key) orelse 0;
    }

    pub fn set_storage(self: *MockEvm, address: Address, slot: u256, value: u256) !void {
        const key = StorageKey{ .address = address, .slot = slot };
        try self.storage.put(key, value);
    }

    pub fn get_transient_storage(self: *MockEvm, address: Address, slot: u256) u256 {
        const key = StorageKey{ .address = address, .slot = slot };
        return self.transient_storage.get(key) orelse 0;
    }

    pub fn set_transient_storage(self: *MockEvm, address: Address, slot: u256, value: u256) !void {
        const key = StorageKey{ .address = address, .slot = slot };
        try self.transient_storage.put(key, value);
    }

    pub fn get_is_static(self: *const MockEvm) bool {
        return self.is_static;
    }
};

fn createTestFrame(allocator: std.mem.Allocator, evm: *MockEvm) !TestFrame {
    const database = try @import("../storage/memory_database.zig").MemoryDatabase.init(allocator);
    const value = try allocator.create(u256);
    value.* = 0;
    const evm_ptr = @as(*anyopaque, @ptrCast(evm));
    var frame = try TestFrame.init(allocator, 1_000_000, database, Address.ZERO_ADDRESS, value, &[_]u8{}, evm_ptr);
    frame.code = &[_]u8{};
    return frame;
}

// Mock dispatch that simulates successful execution flow
fn createMockDispatch() TestFrame.Dispatch {
    const mock_handler = struct {
        fn handler(frame: TestFrame, dispatch: TestFrame.Dispatch) TestFrame.Error!TestFrame.Success {
            _ = frame;
            _ = dispatch;
            return TestFrame.Success.stop;
        }
    }.handler;

    var cursor: [1]dispatch_mod.ScheduleElement(TestFrame) = undefined;
    cursor[0] = .{ .opcode_handler = &mock_handler };

    return TestFrame.Dispatch{
        .cursor = &cursor,
        .jump_table = undefined, // Mock dispatch doesn't need jump table
    };
}

test "SLOAD opcode - load from empty slot" {
    var evm = MockEvm.init(testing.allocator);
    defer evm.deinit();

    var frame = try createTestFrame(testing.allocator, &evm);
    defer frame.deinit(testing.allocator);

    // Load from slot 0 (empty, should return 0)
    try frame.stack.push(0);

    const dispatch = createMockDispatch();
    _ = try TestHandlers.sload(&frame, dispatch);

    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

test "SLOAD opcode - load existing value" {
    var evm = MockEvm.init(testing.allocator);
    defer evm.deinit();

    // Pre-store a value
    const contract_addr = Address{ .bytes = .{0} ** 20 };
    try evm.set_storage(contract_addr, 42, 0xDEADBEEF);

    var frame = try createTestFrame(testing.allocator, &evm);
    defer frame.deinit(testing.allocator);
    frame.contract_address = contract_addr;

    // Load from slot 42
    try frame.stack.push(42);

    const dispatch = createMockDispatch();
    _ = try TestHandlers.sload(&frame, dispatch);

    try testing.expectEqual(@as(u256, 0xDEADBEEF), try frame.stack.pop());
}

test "SSTORE opcode - basic store" {
    var evm = MockEvm.init(testing.allocator);
    defer evm.deinit();

    var frame = try createTestFrame(testing.allocator, &evm);
    defer frame.deinit(testing.allocator);
    evm.is_static = false; // Ensure not in static context

    // Store value 0x1234 at slot 100
    try frame.stack.push(100); // slot
    try frame.stack.push(0x1234); // value

    const dispatch = createMockDispatch();
    _ = try TestHandlers.sstore(&frame, dispatch);

    // Verify the value was stored
    const stored_value = evm.get_storage(frame.contract_address, 100);
    try testing.expectEqual(@as(u256, 0x1234), stored_value);
}

test "SSTORE opcode - write protection in static call" {
    var evm = MockEvm.init(testing.allocator);
    defer evm.deinit();

    var frame = try createTestFrame(testing.allocator, &evm);
    defer frame.deinit(testing.allocator);
    evm.is_static = true; // Set static context

    // Try to store in static context
    try frame.stack.push(0); // slot
    try frame.stack.push(42); // value

    const dispatch = createMockDispatch();
    const result = TestHandlers.sstore(&frame, dispatch);

    try testing.expectError(TestFrame.Error.WriteProtection, result);
}

test "TLOAD opcode - transient storage load" {
    var evm = MockEvm.init(testing.allocator);
    defer evm.deinit();

    // Pre-store a transient value
    const contract_addr = Address{ .bytes = .{0} ** 20 };
    try evm.set_transient_storage(contract_addr, 5, 0xABCD);

    var frame = try createTestFrame(testing.allocator, &evm);
    defer frame.deinit(testing.allocator);
    frame.contract_address = contract_addr;

    // Load from transient slot 5
    try frame.stack.push(5);

    const dispatch = createMockDispatch();
    _ = try TestHandlers.tload(&frame, dispatch);

    try testing.expectEqual(@as(u256, 0xABCD), try frame.stack.pop());
}

test "TSTORE opcode - transient storage store" {
    var evm = MockEvm.init(testing.allocator);
    defer evm.deinit();

    var frame = try createTestFrame(testing.allocator, &evm);
    defer frame.deinit(testing.allocator);
    evm.is_static = false;

    // Store value 0x5678 at transient slot 10
    try frame.stack.push(10); // slot
    try frame.stack.push(0x5678); // value

    const dispatch = createMockDispatch();
    _ = try TestHandlers.tstore(&frame, dispatch);

    // Verify the value was stored
    const stored_value = try evm.get_transient_storage(frame.contract_address, 10);
    try testing.expectEqual(@as(u256, 0x5678), stored_value);
}

test "TSTORE opcode - write protection in static call" {
    var evm = MockEvm.init(testing.allocator);
    defer evm.deinit();

    var frame = try createTestFrame(testing.allocator, &evm);
    defer frame.deinit(testing.allocator);
    evm.is_static = true; // Set static context

    // Try to store in static context
    try frame.stack.push(0); // slot
    try frame.stack.push(42); // value

    const dispatch = createMockDispatch();
    const result = TestHandlers.tstore(&frame, dispatch);

    try testing.expectError(TestFrame.Error.WriteProtection, result);
}

test "storage operations - gas consumption" {
    var evm = MockEvm.init(testing.allocator);
    defer evm.deinit();

    var frame = try createTestFrame(testing.allocator, &evm);
    defer frame.deinit(testing.allocator);
    evm.is_static = false;

    // Set initial gas
    frame.gas_remaining = 100_000;
    const initial_gas = frame.gas_remaining;

    // SSTORE to new slot (cold, expensive)
    try frame.stack.push(1000); // slot
    try frame.stack.push(42); // value

    var dispatch = createMockDispatch();
    _ = try TestHandlers.sstore(&frame, dispatch);

    // Should consume significant gas
    const gas_consumed = initial_gas - frame.gas_remaining;
    try testing.expect(gas_consumed > 0);

    // TSTORE has fixed lower cost
    const gas_before_tstore = frame.gas_remaining;
    try frame.stack.push(2000); // slot
    try frame.stack.push(99); // value

    dispatch = createMockDispatch();
    _ = try TestHandlers.tstore(&frame, dispatch);

    const tstore_gas = gas_before_tstore - frame.gas_remaining;
    try testing.expect(tstore_gas == GasConstants.GasWarmStorageRead);
}

test "SLOAD/SSTORE - multiple operations" {
    var evm = MockEvm.init(testing.allocator);
    defer evm.deinit();

    var frame = try createTestFrame(testing.allocator, &evm);
    defer frame.deinit(testing.allocator);
    evm.is_static = false;

    // Store multiple values
    const test_data = [_]struct { slot: u256, value: u256 }{
        .{ .slot = 0, .value = 111 },
        .{ .slot = 1, .value = 222 },
        .{ .slot = 100, .value = 333 },
    };

    for (test_data) |data| {
        try frame.stack.push(data.slot);
        try frame.stack.push(data.value);
        const dispatch = createMockDispatch();
        _ = try TestHandlers.sstore(&frame, dispatch);
    }

    // Read back and verify
    for (test_data) |data| {
        try frame.stack.push(data.slot);
        const dispatch = createMockDispatch();
        _ = try TestFrame.StorageHandlers.sload(frame, dispatch);
        try testing.expectEqual(data.value, try frame.stack.pop());
    }
}

// ====== COMPREHENSIVE TESTS ======

// SLOAD edge cases
test "SLOAD opcode - boundary values" {
    var evm = MockEvm.init(testing.allocator);
    defer evm.deinit();

    var frame = try createTestFrame(testing.allocator, &evm);
    defer frame.deinit(testing.allocator);

    // Test loading from various slot numbers
    const test_slots = [_]u256{
        0, // Zero slot
        1, // Small slot
        255, // Byte boundary
        256, // Word boundary
        0xFFFFFFFF, // 32-bit max
        std.math.maxInt(u256), // Max slot
        0xDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEF,
    };

    // Store unique values in each slot
    for (test_slots, 0..) |slot, i| {
        try evm.set_storage(frame.contract_address, slot, @as(u256, i + 1000));
    }

    // Load and verify each
    for (test_slots, 0..) |slot, i| {
        try frame.stack.push(slot);

        const dispatch = createMockDispatch();
        _ = try TestFrame.StorageHandlers.sload(frame, dispatch);

        const loaded = try frame.stack.pop();
        try testing.expectEqual(@as(u256, i + 1000), loaded);
    }
}

test "SLOAD opcode - access tracking" {
    var evm = MockEvm.init(testing.allocator);
    defer evm.deinit();

    var frame = try createTestFrame(testing.allocator, &evm);
    defer frame.deinit(testing.allocator);

    // Load from slot should mark it as accessed
    try frame.stack.push(42);

    const dispatch = createMockDispatch();
    _ = try TestHandlers.sload(&frame, dispatch);

    // Verify slot was marked as accessed
    const key = MockEvm.StorageKey{ .address = frame.contract_address, .slot = 42 };
    try testing.expect(evm.accessed_slots.contains(key));

    _ = try frame.stack.pop(); // Clear result
}

// SSTORE comprehensive tests
test "SSTORE opcode - overwrite patterns" {
    var evm = MockEvm.init(testing.allocator);
    defer evm.deinit();

    var frame = try createTestFrame(testing.allocator, &evm);
    defer frame.deinit(testing.allocator);
    evm.is_static = false;

    // Test various overwrite scenarios
    const slot: u256 = 100;

    // Store initial value
    try frame.stack.push(slot);
    try frame.stack.push(0xAAAA);
    var dispatch = createMockDispatch();
    _ = try TestHandlers.sstore(&frame, dispatch);

    // Overwrite with different value
    try frame.stack.push(slot);
    try frame.stack.push(0xBBBB);
    dispatch = createMockDispatch();
    _ = try TestHandlers.sstore(&frame, dispatch);

    // Overwrite with zero (clearing)
    try frame.stack.push(slot);
    try frame.stack.push(0);
    dispatch = createMockDispatch();
    _ = try TestHandlers.sstore(&frame, dispatch);

    // Verify final state
    const final_value = evm.get_storage(frame.contract_address, slot);
    try testing.expectEqual(@as(u256, 0), final_value);
}

test "SSTORE opcode - gas edge cases" {
    var evm = MockEvm.init(testing.allocator);
    defer evm.deinit();

    var frame = try createTestFrame(testing.allocator, &evm);
    defer frame.deinit(testing.allocator);
    evm.is_static = false;

    // Test different gas scenarios

    // 1. Store to new slot (most expensive)
    frame.gas_remaining = 100_000;
    var gas_before = frame.gas_remaining;
    try frame.stack.push(1);
    try frame.stack.push(100);
    var dispatch = createMockDispatch();
    _ = try TestHandlers.sstore(&frame, dispatch);
    const new_slot_gas = gas_before - frame.gas_remaining;

    // 2. Overwrite existing non-zero with non-zero
    gas_before = frame.gas_remaining;
    try frame.stack.push(1);
    try frame.stack.push(200);
    dispatch = createMockDispatch();
    _ = try TestHandlers.sstore(&frame, dispatch);
    _ = gas_before - frame.gas_remaining; // overwrite_gas (currently not used in comparisons)

    // 3. Clear storage (non-zero to zero)
    gas_before = frame.gas_remaining;
    try frame.stack.push(1);
    try frame.stack.push(0);
    dispatch = createMockDispatch();
    _ = try TestHandlers.sstore(&frame, dispatch);
    const clear_gas = gas_before - frame.gas_remaining;

    // 4. No-op (store same value)
    try frame.stack.push(2);
    try frame.stack.push(300);
    dispatch = createMockDispatch();
    _ = try TestHandlers.sstore(&frame, dispatch);

    gas_before = frame.gas_remaining;
    try frame.stack.push(2);
    try frame.stack.push(300); // Same value
    dispatch = createMockDispatch();
    _ = try TestHandlers.sstore(&frame, dispatch);
    const noop_gas = gas_before - frame.gas_remaining;

    // Verify gas relationships
    try testing.expect(new_slot_gas > 0);
    try testing.expect(clear_gas > 0);
    try testing.expect(noop_gas < new_slot_gas);
}

test "SSTORE opcode - out of gas" {
    var evm = MockEvm.init(testing.allocator);
    defer evm.deinit();

    var frame = try createTestFrame(testing.allocator, &evm);
    defer frame.deinit(testing.allocator);
    evm.is_static = false;

    // Set very low gas
    frame.gas_remaining = 1;

    try frame.stack.push(0);
    try frame.stack.push(42);

    const dispatch = createMockDispatch();
    const result = TestHandlers.sstore(&frame, dispatch);

    try testing.expectError(TestFrame.Error.OutOfGas, result);
}

// TLOAD/TSTORE comprehensive tests
test "TLOAD opcode - empty transient storage" {
    var evm = MockEvm.init(testing.allocator);
    defer evm.deinit();

    var frame = try createTestFrame(testing.allocator, &evm);
    defer frame.deinit(testing.allocator);

    // Load from empty transient slot
    try frame.stack.push(999);

    const dispatch = createMockDispatch();
    _ = try TestHandlers.tload(&frame, dispatch);

    // Should return 0
    try testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

test "TSTORE opcode - transient storage patterns" {
    var evm = MockEvm.init(testing.allocator);
    defer evm.deinit();

    var frame = try createTestFrame(testing.allocator, &evm);
    defer frame.deinit(testing.allocator);
    evm.is_static = false;

    // Store various patterns in transient storage
    const patterns = [_]struct { slot: u256, value: u256 }{
        .{ .slot = 0, .value = 0 },
        .{ .slot = 1, .value = std.math.maxInt(u256) },
        .{ .slot = 100, .value = 0xDEADBEEF },
        .{ .slot = std.math.maxInt(u128), .value = 12345 },
        .{ .slot = std.math.maxInt(u256), .value = 1 },
    };

    // Store all patterns
    for (patterns) |p| {
        try frame.stack.push(p.slot);
        try frame.stack.push(p.value);
        const dispatch = createMockDispatch();
        _ = try TestHandlers.tstore(&frame, dispatch);
    }

    // Load and verify all
    for (patterns) |p| {
        try frame.stack.push(p.slot);
        const dispatch = createMockDispatch();
        _ = try TestHandlers.tload(&frame, dispatch);
        const loaded = try frame.stack.pop();
        try testing.expectEqual(p.value, loaded);
    }
}

test "TSTORE opcode - fixed gas cost" {
    var evm = MockEvm.init(testing.allocator);
    defer evm.deinit();

    var frame = try createTestFrame(testing.allocator, &evm);
    defer frame.deinit(testing.allocator);
    evm.is_static = false;

    // TSTORE should always cost the same (100 gas)
    const test_cases = [_]struct { slot: u256, value: u256 }{
        .{ .slot = 0, .value = 0 },
        .{ .slot = 0, .value = 1 }, // Overwrite
        .{ .slot = 1000, .value = 999 }, // New slot
        .{ .slot = 1000, .value = 0 }, // Clear
        .{ .slot = 1000, .value = 0 }, // No-op
    };

    for (test_cases) |tc| {
        frame.gas_remaining = 1000;
        const gas_before = frame.gas_remaining;

        try frame.stack.push(tc.slot);
        try frame.stack.push(tc.value);
        const dispatch = createMockDispatch();
        _ = try TestHandlers.tstore(&frame, dispatch);

        const gas_used = gas_before - frame.gas_remaining;
        try testing.expectEqual(@as(i64, GasConstants.GasWarmStorageRead), gas_used);
    }
}

// Cross-contract storage tests
test "storage operations - different addresses" {
    var evm = MockEvm.init(testing.allocator);
    defer evm.deinit();

    // Create two frames with different contract addresses
    const addr1 = Address{ .bytes = [_]u8{1} ** 20 };
    const addr2 = Address{ .bytes = [_]u8{2} ** 20 };

    var frame1 = try createTestFrame(testing.allocator, &evm);
    defer frame1.deinit(testing.allocator);
    frame1.contract_address = addr1;
    evm.is_static = false;

    var frame2 = try createTestFrame(testing.allocator, &evm);
    defer frame2.deinit(testing.allocator);
    frame2.contract_address = addr2;
    // Both frames use the same evm instance, so is_static is controlled by evm

    // Store value in same slot for both contracts
    const slot: u256 = 42;

    // Contract 1 stores 111
    try frame1.stack.push(slot);
    try frame1.stack.push(111);
    var dispatch = createMockDispatch();
    _ = try TestFrame.StorageHandlers.sstore(frame1, dispatch);

    // Contract 2 stores 222
    try frame2.stack.push(slot);
    try frame2.stack.push(222);
    dispatch = createMockDispatch();
    _ = try TestFrame.StorageHandlers.sstore(frame2, dispatch);

    // Verify storage is isolated
    try frame1.stack.push(slot);
    dispatch = createMockDispatch();
    _ = try TestFrame.StorageHandlers.sload(frame1, dispatch);
    try testing.expectEqual(@as(u256, 111), try frame1.stack.pop());

    try frame2.stack.push(slot);
    dispatch = createMockDispatch();
    _ = try TestFrame.StorageHandlers.sload(frame2, dispatch);
    try testing.expectEqual(@as(u256, 222), try frame2.stack.pop());
}

// Stack underflow tests
test "storage operations - stack underflow" {
    var evm = MockEvm.init(testing.allocator);
    defer evm.deinit();

    var frame = try createTestFrame(testing.allocator, &evm);
    defer frame.deinit(testing.allocator);

    const dispatch = createMockDispatch();

    // SLOAD needs 1 item
    const sload_result = TestHandlers.sload(&frame, dispatch);
    try testing.expectError(TestFrame.Error.StackUnderflow, sload_result);

    // SSTORE needs 2 items
    const sstore_result = TestHandlers.sstore(&frame, dispatch);
    try testing.expectError(TestFrame.Error.StackUnderflow, sstore_result);

    try frame.stack.push(42); // Add one item
    const sstore_result2 = TestHandlers.sstore(&frame, dispatch);
    try testing.expectError(TestFrame.Error.StackUnderflow, sstore_result2);

    // TLOAD needs 1 item
    _ = try frame.stack.pop();
    const tload_result = TestHandlers.tload(&frame, dispatch);
    try testing.expectError(TestFrame.Error.StackUnderflow, tload_result);

    // TSTORE needs 2 items
    const tstore_result = TestHandlers.tstore(&frame, dispatch);
    try testing.expectError(TestFrame.Error.StackUnderflow, tstore_result);
}

// Transient vs persistent storage interaction
test "transient vs persistent storage" {
    var evm = MockEvm.init(testing.allocator);
    defer evm.deinit();

    var frame = try createTestFrame(testing.allocator, &evm);
    defer frame.deinit(testing.allocator);
    evm.is_static = false;

    const slot: u256 = 100;

    // Store in persistent storage
    try frame.stack.push(slot);
    try frame.stack.push(111);
    var dispatch = createMockDispatch();
    _ = try TestHandlers.sstore(&frame, dispatch);

    // Store different value in transient storage
    try frame.stack.push(slot);
    try frame.stack.push(222);
    dispatch = createMockDispatch();
    _ = try TestHandlers.tstore(&frame, dispatch);

    // Load from persistent - should be 111
    try frame.stack.push(slot);
    dispatch = createMockDispatch();
    _ = try TestFrame.StorageHandlers.sload(frame, dispatch);
    try testing.expectEqual(@as(u256, 111), try frame.stack.pop());

    // Load from transient - should be 222
    try frame.stack.push(slot);
    dispatch = createMockDispatch();
    _ = try TestHandlers.tload(&frame, dispatch);
    try testing.expectEqual(@as(u256, 222), try frame.stack.pop());
}

// Maximum value tests
test "storage operations - max values" {
    var evm = MockEvm.init(testing.allocator);
    defer evm.deinit();

    var frame = try createTestFrame(testing.allocator, &evm);
    defer frame.deinit(testing.allocator);
    evm.is_static = false;

    const max_slot = std.math.maxInt(u256);
    const max_value = std.math.maxInt(u256);

    // Store max value at max slot (persistent)
    try frame.stack.push(max_slot);
    try frame.stack.push(max_value);
    var dispatch = createMockDispatch();
    _ = try TestHandlers.sstore(&frame, dispatch);

    // Load and verify
    try frame.stack.push(max_slot);
    dispatch = createMockDispatch();
    _ = try TestFrame.StorageHandlers.sload(frame, dispatch);
    try testing.expectEqual(max_value, try frame.stack.pop());

    // Same for transient storage
    try frame.stack.push(max_slot);
    try frame.stack.push(max_value);
    dispatch = createMockDispatch();
    _ = try TestHandlers.tstore(&frame, dispatch);

    try frame.stack.push(max_slot);
    dispatch = createMockDispatch();
    _ = try TestHandlers.tload(&frame, dispatch);
    try testing.expectEqual(max_value, try frame.stack.pop());
}

// NOTE: Database is now always required - no test needed for disabled database
