const std = @import("std");
const frame_interpreter_mod = @import("evm");
const primitives = @import("voltaire");
const Address = primitives.Address.Address;
const address_utils = primitives.Address;
const opcode_data = @import("opcode_data.zig");
const Opcode = @import("opcode.zig").Opcode;
const Host = @import("evm").Host;
const CallParams = @import("call_params.zig").CallParams;
const CallResult = @import("call_result.zig").CallResult;
const Log = @import("logs.zig").Log;
const BlockInfo = @import("evm").BlockInfo;
const ZERO_ADDRESS = @import("voltaire").ZERO_ADDRESS;
const Hardfork = @import("evm").Hardfork;

// Mock host implementation for testing
const MockHost = struct {
    balance_calls: u32 = 0,
    origin_calls: u32 = 0,
    caller_calls: u32 = 0,
    callvalue_calls: u32 = 0,
    inner_call_calls: u32 = 0,
    
    test_balance: u256 = 1000,
    test_origin: Address = [_]u8{0} ** 19 ++ [_]u8{0xde},
    test_caller: Address = [_]u8{0} ** 19 ++ [_]u8{0xca},
    test_callvalue: u256 = 42,
    
    pub fn get_balance(self: *MockHost, address: Address) u256 {
        _ = address;
        self.balance_calls += 1;
        return self.test_balance;
    }
    
    pub fn get_tx_origin(self: *MockHost) Address {
        self.origin_calls += 1;
        return self.test_origin;
    }
    
    pub fn get_caller(self: *MockHost) Address {
        self.caller_calls += 1;
        return self.test_caller;
    }
    
    pub fn get_call_value(self: *MockHost) u256 {
        self.callvalue_calls += 1;
        return self.test_callvalue;
    }
    
    pub fn inner_call(self: *MockHost, params: CallParams) !CallResult {
        _ = params;
        self.inner_call_calls += 1;
        return CallResult.success_empty(1000); // Return success with gas left
    }
    
    // Stub implementations for other required host methods
    pub fn account_exists(self: *MockHost, address: Address) bool {
        _ = self;
        _ = address;
        return true;
    }
    
    pub fn get_code(self: *MockHost, address: Address) []const u8 {
        _ = self;
        _ = address;
        return &.{};
    }
    
    pub fn get_block_info(self: *MockHost) BlockInfo {
        _ = self;
        return BlockInfo.init();
    }
    
    pub fn emit_log(self: *MockHost, contract_address: Address, topics: []const u256, data: []const u8) void {
        _ = self;
        _ = contract_address;
        _ = topics;
        _ = data;
    }
    
    pub fn register_created_contract(self: *MockHost, address: Address) !void {
        _ = self;
        _ = address;
    }
    
    pub fn was_created_in_tx(self: *MockHost, address: Address) bool {
        _ = self;
        _ = address;
        return false;
    }
    
    pub fn create_snapshot(self: *MockHost) u32 {
        _ = self;
        return 0;
    }
    
    pub fn revert_to_snapshot(self: *MockHost, snapshot_id: u32) void {
        _ = self;
        _ = snapshot_id;
    }
    
    pub fn get_storage(self: *MockHost, address: Address, slot: u256) u256 {
        _ = self;
        _ = address;
        _ = slot;
        return 0;
    }
    
    pub fn set_storage(self: *MockHost, address: Address, slot: u256, value: u256) !void {
        _ = self;
        _ = address;
        _ = slot;
        _ = value;
    }
    
    pub fn record_storage_change(self: *MockHost, address: Address, slot: u256, original_value: u256) !void {
        _ = self;
        _ = address;
        _ = slot;
        _ = original_value;
    }
    
    pub fn get_original_storage(self: *MockHost, address: Address, slot: u256) ?u256 {
        _ = self;
        _ = address;
        _ = slot;
        return null;
    }
    
    pub fn access_address(self: *MockHost, address: Address) !u64 {
        _ = self;
        _ = address;
        return 0;
    }
    
    pub fn access_storage_slot(self: *MockHost, contract_address: Address, slot: u256) !u64 {
        _ = self;
        _ = contract_address;
        _ = slot;
        return 0;
    }
    
    pub fn mark_for_destruction(self: *MockHost, contract_address: Address, recipient: Address) !void {
        _ = self;
        _ = contract_address;
        _ = recipient;
    }
    
    pub fn get_input(self: *MockHost) []const u8 {
        _ = self;
        return &.{};
    }
    
    pub fn is_hardfork_at_least(self: *MockHost, target: Hardfork) bool {
        _ = self;
        _ = target;
        return true;
    }
    
    pub fn get_hardfork(self: *MockHost) Hardfork {
        _ = self;
        return .DEFAULT;
    }
    
    pub fn get_is_static(self: *MockHost) bool {
        _ = self;
        return false;
    }
    
    pub fn get_depth(self: *MockHost) u11 {
        _ = self;
        return 0;
    }
    
    pub fn get_gas_price(self: *MockHost) u256 {
        _ = self;
        return 1;
    }
    
    pub fn get_return_data(self: *MockHost) []const u8 {
        _ = self;
        return &.{};
    }
    
    pub fn get_chain_id(self: *MockHost) u16 {
        _ = self;
        return 1;
    }
    
    pub fn get_block_hash(self: *MockHost, block_number: u64) ?[32]u8 {
        _ = self;
        _ = block_number;
        return null;
    }
    
    pub fn get_blob_hash(self: *MockHost, index: u256) ?[32]u8 {
        _ = self;
        _ = index;
        return null;
    }
    
    pub fn get_blob_base_fee(self: *MockHost) u256 {
        _ = self;
        return 0;
    }
};

test "BALANCE opcode with host - successful execution" {
    const allocator = std.testing.allocator;
    
    // Bytecode: PUSH20 address, BALANCE
    const test_address = [_]u8{0} ** 12 ++ [_]u8{0x12, 0x34, 0x56, 0x78, 0x90, 0xab, 0xcd, 0xef};
    var bytecode = std.array_list.AlignedManaged(u8, null).init(allocator);
    defer bytecode.deinit();
    
    try bytecode.append(0x73); // PUSH20
    try bytecode.appendSlice(&test_address);
    try bytecode.append(0x31); // BALANCE
    try bytecode.append(0x00); // STOP
    
    var mock_host = MockHost{};
    const host = Host.init(&mock_host);
    
    const FrameInterpreterType = frame_interpreter_mod.FrameInterpreter(.{
        .has_database = false,
    });
    
    var interpreter = try FrameInterpreterType.init(
        allocator,
        bytecode.items,
        1000000,
        {},
        host
    );
    defer interpreter.deinit(allocator);
    
    // Execute should succeed (interpret() returns success on STOP)
    try interpreter.interpret();
    
    // Verify host was called
    try std.testing.expectEqual(@as(u32, 1), mock_host.balance_calls);
    
    // Verify balance is on stack
    try std.testing.expectEqual(@as(usize, 1), interpreter.frame.stack.size());
    const balance = try interpreter.frame.stack.pop();
    try std.testing.expectEqual(mock_host.test_balance, balance);
}

test "BALANCE opcode without host - test skipped" {
    // Host is now required, so frames cannot be created without a host
    // This makes the test invalid since we can't test the null host case
    return error.SkipZigTest;
}

test "ORIGIN opcode with host - successful execution" {
    const allocator = std.testing.allocator;
    
    const bytecode = &[_]u8{
        0x32, // ORIGIN
        0x00, // STOP
    };
    
    var mock_host = MockHost{};
    const host = Host.init(&mock_host);
    
    const FrameInterpreterType = frame_interpreter_mod.FrameInterpreter(.{
        .has_database = false,
    });
    
    var interpreter = try FrameInterpreterType.init(
        allocator,
        bytecode,
        1000000,
        {},
        host
    );
    defer interpreter.deinit(allocator);
    
    // Execute should succeed (interpret() returns success on STOP)
    try interpreter.interpret();
    
    // Verify host was called
    try std.testing.expectEqual(@as(u32, 1), mock_host.origin_calls);
    
    // Verify origin is on stack
    try std.testing.expectEqual(@as(usize, 1), interpreter.frame.stack.size());
    const origin = try interpreter.frame.stack.pop();
    try std.testing.expectEqual(address_utils.to_u256(mock_host.test_origin), origin);
}

test "ORIGIN opcode without host - test skipped" {
    // Host is now required, so frames cannot be created without a host
    // This makes the test invalid since we can't test the null host case
    return error.SkipZigTest;
}

test "CALLER opcode with host - successful execution" {
    const allocator = std.testing.allocator;
    
    const bytecode = &[_]u8{
        0x33, // CALLER
        0x00, // STOP
    };
    
    var mock_host = MockHost{};
    const host = Host.init(&mock_host);
    
    const FrameInterpreterType = frame_interpreter_mod.FrameInterpreter(.{
        .has_database = false,
    });
    
    var interpreter = try FrameInterpreterType.init(
        allocator,
        bytecode,
        1000000,
        {},
        host
    );
    defer interpreter.deinit(allocator);
    
    // Execute should succeed (interpret() returns success on STOP)
    try interpreter.interpret();
    
    // Verify host was called
    try std.testing.expectEqual(@as(u32, 1), mock_host.caller_calls);
    
    // Verify caller is on stack
    try std.testing.expectEqual(@as(usize, 1), interpreter.frame.stack.size());
    const caller = try interpreter.frame.stack.pop();
    try std.testing.expectEqual(address_utils.to_u256(mock_host.test_caller), caller);
}

test "CALLVALUE opcode with host - successful execution" {
    const allocator = std.testing.allocator;
    
    const bytecode = &[_]u8{
        0x34, // CALLVALUE
        0x00, // STOP
    };
    
    var mock_host = MockHost{};
    const host = Host.init(&mock_host);
    
    const FrameInterpreterType = frame_interpreter_mod.FrameInterpreter(.{
        .has_database = false,
    });
    
    var interpreter = try FrameInterpreterType.init(
        allocator,
        bytecode,
        1000000,
        {},
        host
    );
    defer interpreter.deinit(allocator);
    
    // Execute should succeed (interpret() returns success on STOP)
    try interpreter.interpret();
    
    // Verify host was called
    try std.testing.expectEqual(@as(u32, 1), mock_host.callvalue_calls);
    
    // Verify callvalue is on stack
    try std.testing.expectEqual(@as(usize, 1), interpreter.frame.stack.size());
    const callvalue = try interpreter.frame.stack.pop();
    try std.testing.expectEqual(mock_host.test_callvalue, callvalue);
}

test "CREATE opcode with host - successful execution" {
    const allocator = std.testing.allocator;
    
    const bytecode = &[_]u8{
        0x60, 0x00, // PUSH1 0 (offset)
        0x60, 0x00, // PUSH1 0 (size)
        0x60, 0x00, // PUSH1 0 (value)
        0xf0,       // CREATE
        0x00,       // STOP
    };
    
    var mock_host = MockHost{};
    const host = Host.init(&mock_host);
    
    const FrameInterpreterType = frame_interpreter_mod.FrameInterpreter(.{
        .has_database = false,
    });
    
    var interpreter = try FrameInterpreterType.init(
        allocator,
        bytecode,
        1000000,
        {},
        host
    );
    defer interpreter.deinit(allocator);
    
    // Execute should succeed (interpret() returns success on STOP)
    try interpreter.interpret();
    
    // Verify host was called
    try std.testing.expectEqual(@as(u32, 1), mock_host.inner_call_calls);
    
    // Verify result is on stack (0 for our mock)
    try std.testing.expectEqual(@as(usize, 1), interpreter.frame.stack.size());
}

test "CREATE opcode without host - test skipped" {
    // Host is now required, so frames cannot be created without a host
    // This makes the test invalid since we can't test the null host case
    return error.SkipZigTest;
}

test "Host operations don't modify state before null check - test skipped" {
    // Host is now required, so frames cannot be created without a host
    // This makes the test invalid since we can't test the null host case
    return error.SkipZigTest;
}

test "Multiple host operations in sequence" {
    const allocator = std.testing.allocator;
    
    const bytecode = &[_]u8{
        0x32,       // ORIGIN
        0x33,       // CALLER
        0x34,       // CALLVALUE
        0x60, 0x00, // PUSH1 0
        0x31,       // BALANCE
        0x00,       // STOP
    };
    
    var mock_host = MockHost{};
    const host = Host.init(&mock_host);
    
    const FrameInterpreterType = frame_interpreter_mod.FrameInterpreter(.{
        .has_database = false,
    });
    
    var interpreter = try FrameInterpreterType.init(
        allocator,
        bytecode,
        1000000,
        {},
        host
    );
    defer interpreter.deinit(allocator);
    
    // Execute should succeed (interpret() returns success on STOP)
    try interpreter.interpret();
    
    // Verify all host methods were called
    try std.testing.expectEqual(@as(u32, 1), mock_host.origin_calls);
    try std.testing.expectEqual(@as(u32, 1), mock_host.caller_calls);
    try std.testing.expectEqual(@as(u32, 1), mock_host.callvalue_calls);
    try std.testing.expectEqual(@as(u32, 1), mock_host.balance_calls);
    
    // Stack should have 4 values
    try std.testing.expectEqual(@as(usize, 4), interpreter.frame.stack.size());
}
