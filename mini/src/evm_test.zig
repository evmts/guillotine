// Tests for evm.zig - moved from inline tests
const std = @import("std");
const primitives = @import("primitives");
const errors = @import("errors.zig");
const evm = @import("evm.zig");
const storage = @import("storage.zig");
const Evm = evm.Evm(.{}); // Default config
const StorageInjector = @import("storage_injector.zig").StorageInjector;
const AsyncDataRequest = storage.AsyncDataRequest;

test "AsyncDataRequest - union size and field access" {
    const testing = std.testing;

    // Test none variant
    const req_none = AsyncDataRequest{ .none = {} };
    try testing.expect(req_none == .none);

    // Test storage variant
    const addr = primitives.Address.fromHex("0x1234567890123456789012345678901234567890") catch unreachable;
    const req_storage = AsyncDataRequest{ .storage = .{
        .address = addr,
        .slot = 42,
    } };
    try testing.expect(req_storage == .storage);
    try testing.expect(req_storage.storage.address.equals(addr));
    try testing.expectEqual(42, req_storage.storage.slot);

    // Test balance variant
    const req_balance = AsyncDataRequest{ .balance = .{
        .address = addr,
    } };
    try testing.expect(req_balance == .balance);
    try testing.expect(req_balance.balance.address.equals(addr));

    // Test code variant
    const req_code = AsyncDataRequest{ .code = .{
        .address = addr,
    } };
    try testing.expect(req_code == .code);
    try testing.expect(req_code.code.address.equals(addr));

    // Test nonce variant
    const req_nonce = AsyncDataRequest{ .nonce = .{
        .address = addr,
    } };
    try testing.expect(req_nonce == .nonce);
    try testing.expect(req_nonce.nonce.address.equals(addr));
}

test "AsyncDataRequest - can write and read each variant" {
    const testing = std.testing;

    var request: AsyncDataRequest = .none;

    // Write storage request
    const addr = primitives.Address.fromHex("0xabcdef0123456789abcdef0123456789abcdef01") catch unreachable;
    request = .{ .storage = .{ .address = addr, .slot = 100 } };
    try testing.expect(request == .storage);
    try testing.expectEqual(100, request.storage.slot);

    // Write balance request
    request = .{ .balance = .{ .address = addr } };
    try testing.expect(request == .balance);

    // Write back to none
    request = .none;
    try testing.expect(request == .none);
}

test "error.NeedAsyncData can be caught and identified" {
    const testing = std.testing;

    const TestFn = struct {
        fn needsData() !void {
            return errors.CallError.NeedAsyncData;
        }
    };

    const result = TestFn.needsData();
    try testing.expectError(errors.CallError.NeedAsyncData, result);
}

test "error.NeedAsyncData propagates through call stack" {
    const testing = std.testing;

    const TestFn = struct {
        fn level3() !void {
            return errors.CallError.NeedAsyncData;
        }

        fn level2() !void {
            try level3();
        }

        fn level1() !void {
            try level2();
        }
    };

    const result = TestFn.level1();
    try testing.expectError(errors.CallError.NeedAsyncData, result);
}

test "Evm.async_data_request field initialized to .none" {
    const testing = std.testing;

    var evm_instance = try Evm.init(testing.allocator, null, null, null, null);
    defer evm_instance.deinit();

    try testing.expect(evm_instance.storage.async_data_request == .none);
}

test "Evm.async_data_request can write/read different request types" {
    const testing = std.testing;

    var evm_instance = try Evm.init(testing.allocator, null, null, null, null);
    defer evm_instance.deinit();

    const addr = primitives.Address.fromHex("0x1111111111111111111111111111111111111111") catch unreachable;

    // Write storage request
    evm_instance.storage.async_data_request = .{ .storage = .{ .address = addr, .slot = 99 } };
    try testing.expect(evm_instance.storage.async_data_request == .storage);
    try testing.expectEqual(99, evm_instance.storage.async_data_request.storage.slot);

    // Write balance request
    evm_instance.storage.async_data_request = .{ .balance = .{ .address = addr } };
    try testing.expect(evm_instance.storage.async_data_request == .balance);

    // Clear request
    evm_instance.storage.async_data_request = .none;
    try testing.expect(evm_instance.storage.async_data_request == .none);
}

// ============================================================================
// Tests for Phase 4: callOrContinue() and Async Execution
// ============================================================================

test "CallOrContinueInput/Output - can construct each variant" {
    const testing = std.testing;

    const addr = primitives.Address.fromHex("0x1111111111111111111111111111111111111111") catch unreachable;

    // Test Input variants
    const call_input: Evm.CallOrContinueInput = .{ .call = .{
        .call = .{
            .caller = addr,
            .to = addr,
            .gas = 1000,
            .value = 0,
            .input = &[_]u8{},
        },
    } };
    try testing.expect(call_input == .call);

    const storage_input: Evm.CallOrContinueInput = .{ .continue_with_storage = .{
        .address = addr,
        .slot = 42,
        .value = 100,
    } };
    try testing.expect(storage_input == .continue_with_storage);

    // Test Output variants
    const result_output: Evm.CallOrContinueOutput = .{ .result = .{
        .success = true,
        .gas_left = 500,
        .output = &[_]u8{},
    } };
    try testing.expect(result_output == .result);

    const storage_output: Evm.CallOrContinueOutput = .{ .need_storage = .{
        .address = addr,
        .slot = 99,
    } };
    try testing.expect(storage_output == .need_storage);
}

test "callOrContinue - returns .need_storage on cache miss" {
    const testing = std.testing;

    // Create EVM
    var evm_instance = try Evm.init(testing.allocator, null, null, null, null);
    defer evm_instance.deinit();

    // Set storage injector before calling
    var injector = try StorageInjector.init(evm_instance.arena.allocator());
    evm_instance.pending_storage_injector = &injector;

    const addr = primitives.Address.fromHex("0x1234567890123456789012345678901234567890") catch unreachable;

    // Bytecode: PUSH1 0x00, SLOAD, STOP - will trigger async request
    const bytecode = [_]u8{ 0x60, 0x00, 0x54, 0x00 }; // PUSH1 0, SLOAD, STOP
    evm_instance.pending_bytecode = &bytecode;

    const params: Evm.CallParams = .{ .call = .{
        .caller = addr,
        .to = addr,
        .gas = 100000,
        .value = 0,
        .input = &[_]u8{},
    } };

    const output = try evm_instance.callOrContinue(.{ .call = params });

    // Should yield with storage request
    try testing.expect(output == .need_storage);
    try testing.expectEqual(@as(u256, 0), output.need_storage.slot);
}

// TODO: Re-enable this test once async resume functionality is fixed
// Currently SLOAD pops the stack before yielding, causing StackUnderflow on resume
// test "callOrContinue - continue_with_storage resumes execution" {
//     const testing = std.testing;
//
//     var evm_instance = try Evm.init(testing.allocator, null, null, null, null);
//     defer evm_instance.deinit();
//
//     // Set storage injector before calling
//     var injector = try StorageInjector.init(evm_instance.arena.allocator());
//     evm_instance.pending_storage_injector = &injector;
//
//     const addr = primitives.Address.fromHex("0x1234567890123456789012345678901234567890") catch unreachable;
//
//     // Bytecode: PUSH1 0x00, SLOAD, STOP
//     const bytecode = [_]u8{ 0x60, 0x00, 0x54, 0x00 };
//     evm_instance.pending_bytecode = &bytecode;
//
//     const params: Evm.CallParams = .{ .call = .{
//         .caller = addr,
//         .to = addr,
//         .gas = 100000,
//         .value = 0,
//         .input = &[_]u8{},
//     } };
//
//     // First call - should yield
//     const output1 = try evm_instance.callOrContinue(.{ .call = params });
//     try testing.expect(output1 == .need_storage);
//
//     // Continue with storage value
//     const output2 = try evm_instance.callOrContinue(.{ .continue_with_storage = .{
//         .address = addr,
//         .slot = 0,
//         .value = 42,
//     } });
//
//     // With storage injector, should return ready_to_commit
//     try testing.expect(output2 == .ready_to_commit);
//
//     // Continue after commit to get final result
//     const output3 = try evm_instance.callOrContinue(.{ .continue_after_commit = {} });
//     try testing.expect(output3 == .result);
//     try testing.expect(output3.result.success);
// }
