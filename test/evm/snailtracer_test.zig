const std = @import("std");
const testing = std.testing;
const Evm = @import("evm");
const primitives = @import("primitives");
const Address = primitives.Address.Address;

// Test for SnailTracer contract execution issue
// Bug: Contract execution fails with REVERT when directly setting runtime bytecode
// Expected: Should execute successfully, consume 235,969,655 gas, and return RGB(99, 0, 0)

test "SnailTracer contract execution" {
    // Enable debug logging
    std.testing.log_level = .debug;
    
    const allocator = testing.allocator;

    // Initialize database
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.Evm.init(allocator, db_interface);
    defer vm.deinit();

    // Read bytecode from file
    const bytecode_hex = try std.fs.cwd().readFileAlloc(allocator, "test/snailtracer.bytecode.bin", 100_000);
    defer allocator.free(bytecode_hex);
    
    // Decode hex bytecode (trim whitespace)
    const bytecode = try decodeHex(allocator, std.mem.trim(u8, bytecode_hex, " \n\r\t"));
    defer allocator.free(bytecode);

    // Skip constructor code (first 32 bytes) to get runtime bytecode
    const runtime_code = bytecode[32..];

    // Setup addresses
    const caller = primitives.Address.from_u256(0x1001);
    const contract_addr = primitives.Address.from_u256(0x1234567890abcdef);

    // Fund caller account
    try vm.state.set_balance(caller, 1000000 * 1e18);

    // Set runtime code directly (workaround for RETURN bug #280)
    try vm.state.set_code(contract_addr, runtime_code);

    // Prepare calldata for Benchmark() function selector: 0x30627b7c
    const calldata = try decodeHex(allocator, "30627b7c");
    defer allocator.free(calldata);

    // Debug output
    std.log.debug("First 16 bytes of runtime code: {x}", .{std.fmt.fmtSliceHexLower(runtime_code[0..@min(16, runtime_code.len)])});
    std.log.debug("Runtime code size: {} bytes", .{runtime_code.len});
    std.log.debug("Calling contract at: {x} with calldata: {x}", .{ contract_addr, std.fmt.fmtSliceHexLower(calldata) });

    // Call the contract
    const result = try vm.call_contract(
        caller,
        contract_addr,
        0, // value
        calldata,
        1_000_000_000, // 1 billion gas
        false, // not static
    );
    defer if (result.output) |output| allocator.free(output);

    // Debug output for failure
    if (!result.success) {
        std.log.err("Contract call failed!", .{});
        std.log.err("Gas left: {}", .{result.gas_left});
        std.log.err("Success: {}", .{result.success});
        if (result.output) |output| {
            std.log.err("Output size: {} bytes", .{output.len});
            if (output.len > 0) {
                std.log.err("Output data: {x}", .{std.fmt.fmtSliceHexLower(output[0..@min(64, output.len)])});
            }
        } else {
            std.log.err("No output data", .{});
        }
    }

    // Verify results
    try testing.expect(result.success); // Should succeed, not revert
    
    // Calculate gas used
    const gas_used = 1_000_000_000 - result.gas_left;
    std.log.debug("Gas used: {}, Success: {}", .{ gas_used, result.success });
    
    // Expected gas usage: 235,969,655
    try testing.expectEqual(@as(u64, 235_969_655), gas_used);

    // Expected output: 3 bytes RGB(99, 0, 0) = 0x630000
    try testing.expect(result.output != null);
    if (result.output) |output| {
        // The actual output is 96 bytes, but RGB values are at offset 64
        try testing.expect(output.len >= 67); // At least 64 + 3 bytes
        
        // Check RGB values at offset 64
        const r = output[64];
        const g = output[65];
        const b = output[66];
        
        std.log.debug("RGB values: R={}, G={}, B={}", .{ r, g, b });
        
        try testing.expectEqual(@as(u8, 99), r);
        try testing.expectEqual(@as(u8, 0), g);
        try testing.expectEqual(@as(u8, 0), b);
    }
}

fn decodeHex(allocator: std.mem.Allocator, hex: []const u8) ![]u8 {
    const cleaned_hex = if (std.mem.startsWith(u8, hex, "0x")) hex[2..] else hex;
    const result = try allocator.alloc(u8, cleaned_hex.len / 2);
    _ = try std.fmt.hexToBytes(result, cleaned_hex);
    return result;
}

// Additional test to verify the bytecode structure
test "SnailTracer bytecode structure validation" {
    const allocator = testing.allocator;

    // Read bytecode from file
    const bytecode_hex = try std.fs.cwd().readFileAlloc(allocator, "test/snailtracer.bytecode.bin", 100_000);
    defer allocator.free(bytecode_hex);
    
    const bytecode = try decodeHex(allocator, std.mem.trim(u8, bytecode_hex, " \n\r\t"));
    defer allocator.free(bytecode);

    // Verify total size
    try testing.expectEqual(@as(usize, 17640), bytecode.len);

    // Verify constructor/deployment code ends at byte 32
    // The deployment code should end with 0xf3 0x00 (RETURN followed by STOP)
    try testing.expectEqual(@as(u8, 0xf3), bytecode[30]);
    try testing.expectEqual(@as(u8, 0x00), bytecode[31]);

    // Runtime bytecode starts at byte 32
    const runtime_code = bytecode[32..];
    try testing.expectEqual(@as(usize, 17608), runtime_code.len);

    // Verify runtime code starts with expected pattern
    // First 16 bytes should be: 60 80 60 40 52 60 04 36 10 61 00 61 57 63 ff ff
    const expected_start = [_]u8{ 0x60, 0x80, 0x60, 0x40, 0x52, 0x60, 0x04, 0x36, 0x10, 0x61, 0x00, 0x61, 0x57, 0x63, 0xff, 0xff };
    try testing.expectEqualSlices(u8, &expected_start, runtime_code[0..16]);
}