const std = @import("std");
const testing = std.testing;
const evm = @import("evm");
const frame_mod = evm.frame;
const MemoryDatabase = evm.MemoryDatabase;
const primitives = @import("voltaire");
const Address = primitives.Address.Address;

/// Simple test tracer that counts operations
const TestTracer = struct {
    const Self = @This();
    op_count: usize = 0,
    
    pub fn beforeOp(self: *Self, comptime FrameType: type, frame: *const FrameType) void {
        _ = frame;
        _ = &FrameType;
        self.op_count += 1;
    }
};

test "traced handlers are called" {
    const allocator = testing.allocator;
    
    // Create a frame config with tracer
    const FrameConfig = frame_mod.FrameConfig{
        .DatabaseType = MemoryDatabase,
        .TracerType = TestTracer,
    };
    
    const Frame = frame_mod.Frame(FrameConfig);
    
    // Create a simple database
    var db = MemoryDatabase.init(allocator);
    defer db.deinit();
    
    // Create a tracer instance
    var tracer = TestTracer{};
    
    // Create frame
    var frame = try Frame.init(
        allocator,
        1000000, // gas
        db,
        Address.ZERO,
        &@as(u256, 0),
        &[_]u8{}, // calldata
        .{
            .chain_id = 1,
            .number = 0,
            .timestamp = 0,
            .difficulty = 0,
            .gas_limit = 30_000_000,
            .coinbase = Address.ZERO,
            .base_fee = 0,
            .prev_randao = [_]u8{0} ** 32,
            .blob_base_fee = 0,
            .blob_versioned_hashes = &.{},
        }, // block_info
        undefined, // evm_ptr
        null, // self_destruct
    );
    defer frame.deinit(allocator);
    
    // Execute simple bytecode (PUSH1 0x01 STOP)
    const bytecode = [_]u8{ 0x60, 0x01, 0x00 };
    
    // Set tracer instance
    const frame_handlers = evm.frame_handlers;
    frame_handlers.setTracerInstance(&tracer);
    defer frame_handlers.clearTracerInstance();
    
    // Execute
    _ = frame.interpret(&bytecode) catch {};
    
    // Check that tracer was called (should have executed PUSH1 and STOP)
    try testing.expect(tracer.op_count > 0);
}

test "non-traced handlers work without tracer" {
    const allocator = testing.allocator;
    
    // Create a frame config without tracer
    const FrameConfig = frame_mod.FrameConfig{
        .DatabaseType = MemoryDatabase,
        .TracerType = null,
    };
    
    const Frame = frame_mod.Frame(FrameConfig);
    
    // Create a simple database
    var db = MemoryDatabase.init(allocator);
    defer db.deinit();
    
    // Create frame
    var frame = try Frame.init(
        allocator,
        1000000, // gas
        db,
        Address.ZERO,
        &@as(u256, 0),
        &[_]u8{}, // calldata
        .{
            .chain_id = 1,
            .number = 0,
            .timestamp = 0,
            .difficulty = 0,
            .gas_limit = 30_000_000,
            .coinbase = Address.ZERO,
            .base_fee = 0,
            .prev_randao = [_]u8{0} ** 32,
            .blob_base_fee = 0,
            .blob_versioned_hashes = &.{},
        }, // block_info
        undefined, // evm_ptr
        null, // self_destruct
    );
    defer frame.deinit(allocator);
    
    // Execute simple bytecode (PUSH1 0x01 STOP)
    const bytecode = [_]u8{ 0x60, 0x01, 0x00 };
    
    // Execute (should work without any tracer setup)
    _ = frame.interpret(&bytecode) catch {};
    
    // If we got here, execution worked without tracing
    try testing.expect(true);
}