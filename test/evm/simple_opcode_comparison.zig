const std = @import("std");
const Evm = @import("evm");
const Address = @import("primitives").Address;

const OpcodeTestCase = struct {
    name: []const u8,
    bytecode: []const u8,
    expected_output: ?u256,
};

const OPCODE_TESTS = [_]OpcodeTestCase{
    // Arithmetic opcodes
    .{ .name = "ADD 5 + 10", .bytecode = &[_]u8{0x60, 0x05, 0x60, 0x0a, 0x01, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3}, .expected_output = 15 },
    .{ .name = "SUB 100 - 58", .bytecode = &[_]u8{0x60, 0x64, 0x60, 0x3a, 0x03, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3}, .expected_output = 42 },
    .{ .name = "MUL 7 * 6", .bytecode = &[_]u8{0x60, 0x07, 0x60, 0x06, 0x02, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3}, .expected_output = 42 },
    .{ .name = "DIV 84 / 2", .bytecode = &[_]u8{0x60, 0x54, 0x60, 0x02, 0x04, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3}, .expected_output = 42 },
    .{ .name = "MOD 17 % 5", .bytecode = &[_]u8{0x60, 0x11, 0x60, 0x05, 0x06, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3}, .expected_output = 2 },
    
    // Comparison opcodes
    .{ .name = "LT 5 < 10", .bytecode = &[_]u8{0x60, 0x05, 0x60, 0x0a, 0x10, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3}, .expected_output = 1 },
    .{ .name = "GT 10 > 5", .bytecode = &[_]u8{0x60, 0x0a, 0x60, 0x05, 0x11, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3}, .expected_output = 1 },
    .{ .name = "EQ 42 == 42", .bytecode = &[_]u8{0x60, 0x2a, 0x60, 0x2a, 0x14, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3}, .expected_output = 1 },
    .{ .name = "ISZERO 0", .bytecode = &[_]u8{0x60, 0x00, 0x15, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3}, .expected_output = 1 },
    
    // Bitwise opcodes
    .{ .name = "AND 0xFF & 0x0F", .bytecode = &[_]u8{0x60, 0xff, 0x60, 0x0f, 0x16, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3}, .expected_output = 0x0f },
    .{ .name = "OR 0x0F | 0xF0", .bytecode = &[_]u8{0x60, 0x0f, 0x60, 0xf0, 0x17, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3}, .expected_output = 0xff },
    .{ .name = "XOR 0xFF ^ 0x0F", .bytecode = &[_]u8{0x60, 0xff, 0x60, 0x0f, 0x18, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3}, .expected_output = 0xf0 },
    
    // Shift opcodes
    .{ .name = "SHL 1 << 1", .bytecode = &[_]u8{0x60, 0x01, 0x60, 0x01, 0x1b, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3}, .expected_output = 2 },
    .{ .name = "SHR 2 >> 1", .bytecode = &[_]u8{0x60, 0x01, 0x60, 0x02, 0x1c, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3}, .expected_output = 1 },
};

fn runOurEvm(allocator: std.mem.Allocator, bytecode: []const u8) !struct { success: bool, output: ?u256, gas_used: u64 } {
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);
    var vm = try builder.build();
    defer vm.deinit();
    
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    try vm.state.set_code(contract, bytecode);
    try vm.state.set_balance(caller, std.math.maxInt(u256));
    
    const result = try vm.call_contract(
        caller,
        contract,
        0,
        &[_]u8{},
        1_000_000,
        false
    );
    defer if (result.output) |out| allocator.free(out);
    
    var output_value: ?u256 = null;
    if (result.output) |out| {
        if (out.len == 32) {
            var bytes: [32]u8 = undefined;
            @memcpy(&bytes, out[0..32]);
            output_value = std.mem.readInt(u256, &bytes, .big);
        }
    }
    
    return .{
        .success = result.success,
        .output = output_value,
        .gas_used = 1_000_000 - result.gas_left,
    };
}

fn runRevmEvm(allocator: std.mem.Allocator, bytecode: []const u8) !struct { success: bool, output: ?u256, gas_used: u64 } {
    _ = allocator;
    
    // We'll use our evm_test_runner executable to run REVM tests
    var child = std.process.Child.init(
        &.{ "cargo", "run", "--manifest-path", "src/revm_wrapper/Cargo.toml", "--bin", "test_revm_direct", "--", hex_encode(bytecode) },
        allocator,
    );
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    
    try child.spawn();
    
    const stdout = try child.stdout.?.readToEndAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(stdout);
    
    const term = try child.wait();
    if (term != .Exited or term.Exited != 0) {
        return .{ .success = false, .output = null, .gas_used = 0 };
    }
    
    // Parse output
    var lines = std.mem.tokenize(u8, stdout, "\n");
    var success = false;
    var output: ?u256 = null;
    var gas_used: u64 = 0;
    
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "Success: ")) {
            success = std.mem.eql(u8, line["Success: ".len..], "true");
        } else if (std.mem.startsWith(u8, line, "Output: 0x")) {
            const hex = line["Output: 0x".len..];
            if (hex.len == 64) {
                var bytes: [32]u8 = undefined;
                _ = try std.fmt.hexToBytes(&bytes, hex);
                output = std.mem.readInt(u256, &bytes, .big);
            }
        } else if (std.mem.startsWith(u8, line, "Gas used: ")) {
            gas_used = try std.fmt.parseInt(u64, line["Gas used: ".len..], 10);
        }
    }
    
    return .{ .success = success, .output = output, .gas_used = gas_used };
}

fn hex_encode(bytes: []const u8) []const u8 {
    const hex_chars = "0123456789abcdef";
    var result: [512]u8 = undefined; // Should be enough for our test cases
    var i: usize = 0;
    
    result[0] = '0';
    result[1] = 'x';
    i = 2;
    
    for (bytes) |byte| {
        result[i] = hex_chars[byte >> 4];
        result[i + 1] = hex_chars[byte & 0x0f];
        i += 2;
    }
    
    return result[0..i];
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    
    std.debug.print("=== EVM Opcode Comparison Test ===\n\n", .{});
    std.debug.print("Running {} test cases...\n\n", .{OPCODE_TESTS.len});
    
    var passed: usize = 0;
    var failed: usize = 0;
    
    for (OPCODE_TESTS) |test_case| {
        std.debug.print("Test: {s}\n", .{test_case.name});
        std.debug.print("  Bytecode: 0x", .{});
        for (test_case.bytecode) |byte| {
            std.debug.print("{x:0>2}", .{byte});
        }
        std.debug.print("\n", .{});
        
        // Run our EVM
        const our_result = runOurEvm(allocator, test_case.bytecode) catch |err| {
            std.debug.print("  Our EVM: ERROR - {}\n", .{err});
            failed += 1;
            continue;
        };
        
        std.debug.print("  Our EVM: success={}, output=", .{our_result.success});
        if (our_result.output) |out| {
            std.debug.print("0x{x}", .{out});
        } else {
            std.debug.print("null", .{});
        }
        std.debug.print(", gas_used={}\n", .{our_result.gas_used});
        
        // Check against expected
        if (test_case.expected_output) |expected| {
            if (our_result.output) |actual| {
                if (actual == expected) {
                    std.debug.print("  Result: ✓ PASS\n", .{});
                    passed += 1;
                } else {
                    std.debug.print("  Result: ✗ FAIL (expected 0x{x})\n", .{expected});
                    failed += 1;
                }
            } else {
                std.debug.print("  Result: ✗ FAIL (no output)\n", .{});
                failed += 1;
            }
        } else {
            std.debug.print("  Result: SKIP (no expected value)\n", .{});
        }
        
        std.debug.print("\n", .{});
    }
    
    std.debug.print("=== Summary ===\n", .{});
    std.debug.print("Passed: {}/{}\n", .{ passed, passed + failed });
    std.debug.print("Failed: {}/{}\n", .{ failed, passed + failed });
    
    if (failed > 0) {
        std.process.exit(1);
    }
}