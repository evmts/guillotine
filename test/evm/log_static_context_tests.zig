//! Tests for LOG operations in static context
//! These tests verify that LOG operations properly fail in static context

const std = @import("std");
const frame_mod = @import("evm");
const Frame = frame_mod.Frame;
const evm_mod = @import("evm");
const Evm = evm_mod.Evm;
const primitives = @import("voltaire");
const Address = primitives.Address.Address;
const Host = @import("evm").Host;
const CallParams = @import("call_params.zig").CallParams;
const CallResult = @import("call_result.zig").CallResult;
const Log = @import("logs.zig").Log;
const BlockInfo = @import("evm").BlockInfo;
const ZERO_ADDRESS = @import("voltaire").ZERO_ADDRESS;
const Hardfork = @import("evm").Hardfork;

// Enhanced MockHost that can simulate static context
const MockHostWithStaticContext = struct {
    is_static: bool = false,
    emitted_logs: std.ArrayList(Log),
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) MockHostWithStaticContext {
        return MockHostWithStaticContext{
            .is_static = false,
            .emitted_logs = .empty,
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *MockHostWithStaticContext) void {
        // Free emitted logs
        for (self.emitted_logs.items) |*log| {
            self.allocator.free(log.topics);
            self.allocator.free(log.data);
        }
        self.emitted_logs.deinit();
    }
    
    pub fn set_static(self: *MockHostWithStaticContext, static: bool) void {
        self.is_static = static;
    }
    
    pub fn get_balance(self: *MockHostWithStaticContext, address: Address) u256 {
        _ = self;
        _ = address;
        return 1000;
    }
    
    pub fn get_tx_origin(self: *MockHostWithStaticContext) Address {
        _ = self;
        return [_]u8{0} ** 19 ++ [_]u8{0xde};
    }
    
    pub fn get_caller(self: *MockHostWithStaticContext) Address {
        _ = self;
        return [_]u8{0} ** 19 ++ [_]u8{0xca};
    }
    
    pub fn get_call_value(self: *MockHostWithStaticContext) u256 {
        _ = self;
        return 42;
    }
    
    pub fn inner_call(self: *MockHostWithStaticContext, params: CallParams) !CallResult {
        _ = self;
        _ = params;
        return CallResult.success_empty(1000);
    }
    
    pub fn account_exists(self: *MockHostWithStaticContext, address: Address) bool {
        _ = self;
        _ = address;
        return true;
    }
    
    pub fn get_code(self: *MockHostWithStaticContext, address: Address) []const u8 {
        _ = self;
        _ = address;
        return &.{};
    }
    
    pub fn get_block_info(self: *MockHostWithStaticContext) BlockInfo {
        _ = self;
        return BlockInfo.init();
    }
    
    pub fn emit_log(self: *MockHostWithStaticContext, contract_address: Address, topics: []const u256, data: []const u8) void {
        // Store the log for verification
        const topics_copy = self.allocator.alloc(u256, topics.len) catch return;
        const data_copy = self.allocator.alloc(u8, data.len) catch return;
        
        @memcpy(topics_copy, topics);
        @memcpy(data_copy, data);
        
        const log = Log{
            .address = contract_address,
            .topics = topics_copy,
            .data = data_copy,
        };
        
        self.emitted_logs.append(log) catch return;
    }
    
    pub fn register_created_contract(self: *MockHostWithStaticContext, address: Address) !void {
        _ = self;
        _ = address;
    }
    
    pub fn was_created_in_tx(self: *MockHostWithStaticContext, address: Address) bool {
        _ = self;
        _ = address;
        return false;
    }
    
    pub fn create_snapshot(self: *MockHostWithStaticContext) u32 {
        _ = self;
        return 0;
    }
    
    pub fn revert_to_snapshot(self: *MockHostWithStaticContext, snapshot_id: u32) void {
        _ = self;
        _ = snapshot_id;
    }
    
    pub fn get_storage(self: *MockHostWithStaticContext, address: Address, slot: u256) u256 {
        _ = self;
        _ = address;
        _ = slot;
        return 0;
    }
    
    pub fn set_storage(self: *MockHostWithStaticContext, address: Address, slot: u256, value: u256) !void {
        _ = self;
        _ = address;
        _ = slot;
        _ = value;
    }
    
    pub fn record_storage_change(self: *MockHostWithStaticContext, address: Address, slot: u256, original_value: u256) !void {
        _ = self;
        _ = address;
        _ = slot;
        _ = original_value;
    }
    
    pub fn get_original_storage(self: *MockHostWithStaticContext, address: Address, slot: u256) ?u256 {
        _ = self;
        _ = address;
        _ = slot;
        return null;
    }
    
    pub fn access_address(self: *MockHostWithStaticContext, address: Address) !u64 {
        _ = self;
        _ = address;
        return 0;
    }
    
    pub fn access_storage_slot(self: *MockHostWithStaticContext, contract_address: Address, slot: u256) !u64 {
        _ = self;
        _ = contract_address;
        _ = slot;
        return 0;
    }
    
    pub fn mark_for_destruction(self: *MockHostWithStaticContext, contract_address: Address, recipient: Address) !void {
        _ = self;
        _ = contract_address;
        _ = recipient;
    }
    
    pub fn get_input(self: *MockHostWithStaticContext) []const u8 {
        _ = self;
        return &.{};
    }
    
    pub fn is_hardfork_at_least(self: *MockHostWithStaticContext, target: Hardfork) bool {
        _ = self;
        _ = target;
        return true;
    }
    
    pub fn get_hardfork(self: *MockHostWithStaticContext) Hardfork {
        _ = self;
        return .DEFAULT;
    }
    
    pub fn get_is_static(self: *MockHostWithStaticContext) bool {
        return self.is_static;
    }
    
    pub fn get_depth(self: *MockHostWithStaticContext) u11 {
        _ = self;
        return 0;
    }
    
    pub fn get_gas_price(self: *MockHostWithStaticContext) u256 {
        _ = self;
        return 1;
    }
    
    pub fn get_return_data(self: *MockHostWithStaticContext) []const u8 {
        _ = self;
        return &.{};
    }
    
    pub fn get_chain_id(self: *MockHostWithStaticContext) u16 {
        _ = self;
        return 1;
    }
    
    pub fn get_block_hash(self: *MockHostWithStaticContext, block_number: u64) ?[32]u8 {
        _ = self;
        _ = block_number;
        return null;
    }
    
    pub fn get_blob_hash(self: *MockHostWithStaticContext, index: u256) ?[32]u8 {
        _ = self;
        _ = index;
        return null;
    }
    
    pub fn get_blob_base_fee(self: *MockHostWithStaticContext) u256 {
        _ = self;
        return 0;
    }
};

test "LOG0 in static context fails with WriteProtection" {
    const allocator = std.testing.allocator;
    
    var mock_host = MockHostWithStaticContext.init(allocator);
    defer mock_host.deinit();
    
    // Set static context
    mock_host.set_static(true);
    
    const host = Host.init(&mock_host);
    const F = Frame(.{});
    const bytecode = [_]u8{ 0x00 }; // STOP
    
    var frame = try F.init(allocator, &bytecode, 1000000, void{}, host);
    defer frame.deinit(allocator);
    
    // Setup stack for LOG0: offset, size
    try frame.stack.push(0); // offset
    try frame.stack.push(0); // size
    
    // LOG0 should fail in static context
    try std.testing.expectError(Frame(.{}).Error.WriteProtection, frame.log0());
}

test "LOG1 in static context fails with WriteProtection" {
    const allocator = std.testing.allocator;
    
    var mock_host = MockHostWithStaticContext.init(allocator);
    defer mock_host.deinit();
    
    // Set static context
    mock_host.set_static(true);
    
    const host = Host.init(&mock_host);
    const F = Frame(.{});
    const bytecode = [_]u8{ 0x00 }; // STOP
    
    var frame = try F.init(allocator, &bytecode, 1000000, void{}, host);
    defer frame.deinit(allocator);
    
    // Setup stack for LOG1: topic, offset, size
    try frame.stack.push(0x123); // topic
    try frame.stack.push(0);     // offset
    try frame.stack.push(0);     // size
    
    // LOG1 should fail in static context
    try std.testing.expectError(Frame(.{}).Error.WriteProtection, frame.log1());
}

test "LOG2 in static context fails with WriteProtection" {
    const allocator = std.testing.allocator;
    
    var mock_host = MockHostWithStaticContext.init(allocator);
    defer mock_host.deinit();
    
    // Set static context
    mock_host.set_static(true);
    
    const host = Host.init(&mock_host);
    const F = Frame(.{});
    const bytecode = [_]u8{ 0x00 }; // STOP
    
    var frame = try F.init(allocator, &bytecode, 1000000, void{}, host);
    defer frame.deinit(allocator);
    
    // Setup stack for LOG2: topic2, topic1, offset, size
    try frame.stack.push(0x456); // topic2
    try frame.stack.push(0x123); // topic1
    try frame.stack.push(0);     // offset
    try frame.stack.push(0);     // size
    
    // LOG2 should fail in static context
    try std.testing.expectError(Frame(.{}).Error.WriteProtection, frame.log2());
}

test "LOG3 in static context fails with WriteProtection" {
    const allocator = std.testing.allocator;
    
    var mock_host = MockHostWithStaticContext.init(allocator);
    defer mock_host.deinit();
    
    // Set static context
    mock_host.set_static(true);
    
    const host = Host.init(&mock_host);
    const F = Frame(.{});
    const bytecode = [_]u8{ 0x00 }; // STOP
    
    var frame = try F.init(allocator, &bytecode, 1000000, void{}, host);
    defer frame.deinit(allocator);
    
    // Setup stack for LOG3: topic3, topic2, topic1, offset, size
    try frame.stack.push(0x789); // topic3
    try frame.stack.push(0x456); // topic2
    try frame.stack.push(0x123); // topic1
    try frame.stack.push(0);     // offset
    try frame.stack.push(0);     // size
    
    // LOG3 should fail in static context
    try std.testing.expectError(Frame(.{}).Error.WriteProtection, frame.log3());
}

test "LOG4 in static context fails with WriteProtection" {
    const allocator = std.testing.allocator;
    
    var mock_host = MockHostWithStaticContext.init(allocator);
    defer mock_host.deinit();
    
    // Set static context
    mock_host.set_static(true);
    
    const host = Host.init(&mock_host);
    const F = Frame(.{});
    const bytecode = [_]u8{ 0x00 }; // STOP
    
    var frame = try F.init(allocator, &bytecode, 1000000, void{}, host);
    defer frame.deinit(allocator);
    
    // Setup stack for LOG4: topic4, topic3, topic2, topic1, offset, size
    try frame.stack.push(0xABC); // topic4
    try frame.stack.push(0x789); // topic3
    try frame.stack.push(0x456); // topic2
    try frame.stack.push(0x123); // topic1
    try frame.stack.push(0);     // offset
    try frame.stack.push(0);     // size
    
    // LOG4 should fail in static context
    try std.testing.expectError(Frame(.{}).Error.WriteProtection, frame.log4());
}

test "LOG operations succeed in non-static context" {
    const allocator = std.testing.allocator;
    
    var mock_host = MockHostWithStaticContext.init(allocator);
    defer mock_host.deinit();
    
    // Ensure non-static context
    mock_host.set_static(false);
    
    const host = Host.init(&mock_host);
    const F = Frame(.{});
    const bytecode = [_]u8{ 0x00 }; // STOP
    
    var frame = try F.init(allocator, &bytecode, 1000000, void{}, host);
    defer frame.deinit(allocator);
    
    const contract_address = [_]u8{0x12} ++ [_]u8{0} ** 19;
    frame.contract_address = contract_address;
    
    // Test LOG0 succeeds
    try frame.stack.push(0); // offset
    try frame.stack.push(0); // size
    try frame.log0();
    
    // Test LOG1 succeeds
    try frame.stack.push(0x123); // topic
    try frame.stack.push(0);     // offset
    try frame.stack.push(0);     // size
    try frame.log1();
    
    // Verify logs were emitted
    try std.testing.expectEqual(@as(usize, 2), mock_host.emitted_logs.items.len);
    
    // Verify first log (LOG0)
    const log0 = mock_host.emitted_logs.items[0];
    try std.testing.expectEqualSlices(u8, &contract_address, &log0.address);
    try std.testing.expectEqual(@as(usize, 0), log0.topics.len);
    try std.testing.expectEqual(@as(usize, 0), log0.data.len);
    
    // Verify second log (LOG1)
    const log1 = mock_host.emitted_logs.items[1];
    try std.testing.expectEqualSlices(u8, &contract_address, &log1.address);
    try std.testing.expectEqual(@as(usize, 1), log1.topics.len);
    try std.testing.expectEqual(@as(u256, 0x123), log1.topics[0]);
    try std.testing.expectEqual(@as(usize, 0), log1.data.len);
}

test "LOG operations with data in static context fail" {
    const allocator = std.testing.allocator;
    
    var mock_host = MockHostWithStaticContext.init(allocator);
    defer mock_host.deinit();
    
    // Set static context
    mock_host.set_static(true);
    
    const host = Host.init(&mock_host);
    const F = Frame(.{});
    const bytecode = [_]u8{ 0x00 }; // STOP
    
    var frame = try F.init(allocator, &bytecode, 1000000, void{}, host);
    defer frame.deinit(allocator);
    
    // Store some data in memory
    try frame.memory.set_byte_evm(0, 0xAA);
    try frame.memory.set_byte_evm(1, 0xBB);
    try frame.memory.set_byte_evm(2, 0xCC);
    
    // Setup stack for LOG0 with data: offset=0, size=3
    try frame.stack.push(0); // offset
    try frame.stack.push(3); // size
    
    // LOG0 with data should fail in static context
    try std.testing.expectError(Frame(.{}).Error.WriteProtection, frame.log0());
}

test "LOG operations with maximum topics in static context fail" {
    const allocator = std.testing.allocator;
    
    var mock_host = MockHostWithStaticContext.init(allocator);
    defer mock_host.deinit();
    
    // Set static context
    mock_host.set_static(true);
    
    const host = Host.init(&mock_host);
    const F = Frame(.{});
    const bytecode = [_]u8{ 0x00 }; // STOP
    
    var frame = try F.init(allocator, &bytecode, 1000000, void{}, host);
    defer frame.deinit(allocator);
    
    // Store some data in memory
    try frame.memory.set_u256_evm(0, 0xDEADBEEF);
    
    // Setup stack for LOG4 with maximum topics and data
    try frame.stack.push(0x4444); // topic4
    try frame.stack.push(0x3333); // topic3
    try frame.stack.push(0x2222); // topic2
    try frame.stack.push(0x1111); // topic1
    try frame.stack.push(0);      // offset
    try frame.stack.push(32);     // size (32 bytes)
    
    // LOG4 with data and maximum topics should fail in static context
    try std.testing.expectError(Frame(.{}).Error.WriteProtection, frame.log4());
}
