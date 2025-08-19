const std = @import("std");
const Evm = @import("evm");
const Address = @import("primitives").Address;
const revm = @import("revm");

const OpcodeTest = struct {
    name: []const u8,
    bytecode: []const u8,
    description: []const u8,
};

// All opcode test cases
const OPCODE_TESTS = [_]OpcodeTest{
    // Arithmetic opcodes
    .{ .name = "ADD simple", .bytecode = &[_]u8{0x60, 0x01, 0x60, 0x02, 0x01, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3}, .description = "1 + 2 = 3" },
    .{ .name = "ADD overflow", .bytecode = &[_]u8{0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x60, 0x01, 0x01, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3}, .description = "MAX + 1 (overflow)" },
    .{ .name = "MUL simple", .bytecode = &[_]u8{0x60, 0x05, 0x60, 0x04, 0x02, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3}, .description = "5 * 4 = 20" },
    .{ .name = "MUL overflow", .bytecode = &[_]u8{0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x60, 0x02, 0x02, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3}, .description = "MAX * 2 (overflow)" },
    .{ .name = "SUB simple", .bytecode = &[_]u8{0x60, 0x0a, 0x60, 0x05, 0x03, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3}, .description = "10 - 5 = 5" },
    .{ .name = "SUB underflow", .bytecode = &[_]u8{0x60, 0x05, 0x60, 0x0a, 0x03, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3}, .description = "5 - 10 (underflow)" },
    .{ .name = "DIV simple", .bytecode = &[_]u8{0x60, 0x0a, 0x60, 0x02, 0x04, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3}, .description = "10 / 2 = 5" },
    .{ .name = "DIV by zero", .bytecode = &[_]u8{0x60, 0x0a, 0x60, 0x00, 0x04, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3}, .description = "10 / 0 = 0" },
    .{ .name = "SDIV simple", .bytecode = &[_]u8{0x60, 0x0a, 0x60, 0x02, 0x05, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3}, .description = "10 / 2 = 5 (signed)" },
    .{ .name = "MOD simple", .bytecode = &[_]u8{0x60, 0x0a, 0x60, 0x03, 0x06, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3}, .description = "10 % 3 = 1" },
    .{ .name = "SMOD simple", .bytecode = &[_]u8{0x60, 0x0a, 0x60, 0x03, 0x07, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3}, .description = "10 % 3 = 1 (signed)" },
    .{ .name = "ADDMOD simple", .bytecode = &[_]u8{0x60, 0x05, 0x60, 0x04, 0x60, 0x08, 0x08, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3}, .description = "(5 + 4) % 8 = 1" },
    .{ .name = "ADDMOD MAX+MAX%MAX", .bytecode = &[_]u8{0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x08, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3}, .description = "(MAX + MAX) % MAX" },
    .{ .name = "MULMOD simple", .bytecode = &[_]u8{0x60, 0x0a, 0x60, 0x0a, 0x60, 0x08, 0x09, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3}, .description = "(10 * 10) % 8 = 4" },
    .{ .name = "MULMOD MAX*2%3", .bytecode = &[_]u8{0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x60, 0x02, 0x60, 0x03, 0x09, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3}, .description = "(MAX * 2) % 3" },
    .{ .name = "EXP simple", .bytecode = &[_]u8{0x60, 0x02, 0x60, 0x03, 0x0a, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3}, .description = "2 ** 3 = 8" },
    .{ .name = "EXP 0^0", .bytecode = &[_]u8{0x60, 0x00, 0x60, 0x00, 0x0a, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3}, .description = "0 ** 0 = 1" },
    .{ .name = "SIGNEXTEND simple", .bytecode = &[_]u8{0x60, 0x01, 0x60, 0xff, 0x0b, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3}, .description = "Sign extend 0xff with size 1" },
    
    // Comparison opcodes
    .{ .name = "LT true", .bytecode = &[_]u8{0x60, 0x05, 0x60, 0x0a, 0x10, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3}, .description = "5 < 10 = 1" },
    .{ .name = "LT false", .bytecode = &[_]u8{0x60, 0x0a, 0x60, 0x05, 0x10, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3}, .description = "10 < 5 = 0" },
    .{ .name = "GT true", .bytecode = &[_]u8{0x60, 0x0a, 0x60, 0x05, 0x11, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3}, .description = "10 > 5 = 1" },
    .{ .name = "GT false", .bytecode = &[_]u8{0x60, 0x05, 0x60, 0x0a, 0x11, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3}, .description = "5 > 10 = 0" },
    .{ .name = "SLT true", .bytecode = &[_]u8{0x60, 0x05, 0x60, 0x0a, 0x12, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3}, .description = "5 < 10 = 1 (signed)" },
    .{ .name = "SGT true", .bytecode = &[_]u8{0x60, 0x0a, 0x60, 0x05, 0x13, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3}, .description = "10 > 5 = 1 (signed)" },
    .{ .name = "EQ true", .bytecode = &[_]u8{0x60, 0x05, 0x60, 0x05, 0x14, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3}, .description = "5 == 5 = 1" },
    .{ .name = "EQ false", .bytecode = &[_]u8{0x60, 0x05, 0x60, 0x0a, 0x14, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3}, .description = "5 == 10 = 0" },
    .{ .name = "ISZERO true", .bytecode = &[_]u8{0x60, 0x00, 0x15, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3}, .description = "0 == 0 = 1" },
    .{ .name = "ISZERO false", .bytecode = &[_]u8{0x60, 0x05, 0x15, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3}, .description = "5 == 0 = 0" },
    
    // Bitwise opcodes
    .{ .name = "AND", .bytecode = &[_]u8{0x60, 0x0f, 0x60, 0xf0, 0x16, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3}, .description = "0x0f & 0xf0 = 0x00" },
    .{ .name = "OR", .bytecode = &[_]u8{0x60, 0x0f, 0x60, 0xf0, 0x17, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3}, .description = "0x0f | 0xf0 = 0xff" },
    .{ .name = "XOR", .bytecode = &[_]u8{0x60, 0xff, 0x60, 0x0f, 0x18, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3}, .description = "0xff ^ 0x0f = 0xf0" },
    .{ .name = "NOT", .bytecode = &[_]u8{0x60, 0x00, 0x19, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3}, .description = "~0 = MAX" },
    .{ .name = "BYTE", .bytecode = &[_]u8{0x60, 0x1f, 0x60, 0xff, 0x1a, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3}, .description = "Get byte 31 of 0xff = 0xff" },
    .{ .name = "SHL", .bytecode = &[_]u8{0x60, 0x01, 0x60, 0x01, 0x1b, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3}, .description = "1 << 1 = 2" },
    .{ .name = "SHR", .bytecode = &[_]u8{0x60, 0x01, 0x60, 0x02, 0x1c, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3}, .description = "2 >> 1 = 1" },
    .{ .name = "SAR", .bytecode = &[_]u8{0x60, 0x01, 0x60, 0x02, 0x1d, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3}, .description = "2 >> 1 = 1 (arithmetic)" },
};

fn runZigEvm(allocator: std.mem.Allocator, bytecode: []const u8) !struct { output: []u8, gas_used: u64 } {
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var builder = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
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
    
    var output: []u8 = &[_]u8{};
    if (result.output) |out| {
        output = try allocator.alloc(u8, out.len);
        @memcpy(output, out);
        
    } else {
        output = try allocator.alloc(u8, 0);
    }
    
    return .{
        .output = output,
        .gas_used = 1_000_000 - result.gas_left,
    };
}

fn runRevmEvm(allocator: std.mem.Allocator, bytecode: []const u8) !struct { output: []u8, gas_used: u64 } {
    const caller = Address.from_u256(0x1100000000000000000000000000000000000000);
    const contract = Address.from_u256(0x3300000000000000000000000000000000000000);
    
    // Initialize REVM with default settings
    var vm = try revm.Revm.init(allocator, .{});
    defer vm.deinit();
    
    // Set up the account with balance
    try vm.setBalance(caller, std.math.maxInt(u256));
    
    // Deploy the contract code
    try vm.setCode(contract, bytecode);
    
    // Execute the contract
    var result = try vm.execute(
        caller,
        contract,
        0,  // value
        &[_]u8{}, // input data
        1_000_000 // gas limit
    );
    defer result.deinit();
    
    // Debug logging
    if (result.output.len > 0) {
        for (result.output) |_| {
        }
    }
    
    // Copy the output
    const output = try allocator.alloc(u8, result.output.len);
    @memcpy(output, result.output);
    
    return .{
        .output = output,
        .gas_used = result.gas_used,
    };
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var results = std.ArrayList(u8).init(allocator);
    defer results.deinit();
    
    try results.appendSlice("# Opcode Implementation Status\\n\\n");
    try results.appendSlice("This document shows the implementation status of each EVM opcode in the Guillotine EVM compared with REVM.\\n\\n");
    try results.appendSlice("## Test Results\\n\\n");
    try results.appendSlice("| Opcode Test | Description | REVM Output | Zig Output | Match | Status |\\n");
    try results.appendSlice("|-------------|-------------|-------------|------------|-------|--------|\\n");
    
    var passing: usize = 0;
    var failing: usize = 0;
    var failing_opcodes = std.ArrayList([]const u8).init(allocator);
    defer failing_opcodes.deinit();
    
    for (OPCODE_TESTS) |test_case| {
        
        // Run with REVM
        const revm_result = runRevmEvm(allocator, test_case.bytecode) catch |err| {
            try results.writer().print("| {s} | {s} | ERROR: {} | - | - | ❌ |\\n", .{
                test_case.name,
                test_case.description,
                err
            });
            failing += 1;
            try failing_opcodes.append(test_case.name);
            continue;
        };
        defer allocator.free(revm_result.output);
        
        // Run with Zig EVM
        const zig_result = runZigEvm(allocator, test_case.bytecode) catch |err| {
            const revm_output_value = if (revm_result.output.len == 32)
                std.mem.readInt(u256, revm_result.output[0..32], .big)
            else
                0;
            try results.writer().print("| {s} | {s} | {} | ERROR: {} | ❌ | ❌ |\\n", .{
                test_case.name,
                test_case.description,
                revm_output_value,
                err
            });
            failing += 1;
            try failing_opcodes.append(test_case.name);
            continue;
        };
        defer allocator.free(zig_result.output);
        
        // Compare outputs
        const revm_output_value = if (revm_result.output.len == 32)
            std.mem.readInt(u256, revm_result.output[0..32], .big)
        else
            0;
            
        const zig_output_value = if (zig_result.output.len == 32)
            std.mem.readInt(u256, zig_result.output[0..32], .big)
        else
            0;
        
        const outputs_match = std.mem.eql(u8, revm_result.output, zig_result.output);
        
        if (outputs_match) {
            passing += 1;
            try results.writer().print("| {s} | {s} | {} | {} | ✅ | ✅ |\\n", .{
                test_case.name,
                test_case.description,
                revm_output_value,
                zig_output_value
            });
        } else {
            failing += 1;
            try failing_opcodes.append(test_case.name);
            try results.writer().print("| {s} | {s} | {} | {} | ❌ | ❌ |\\n", .{
                test_case.name,
                test_case.description,
                revm_output_value,
                zig_output_value
            });
        }
        
    }
    
    const total = passing + failing;
    const pass_rate = if (total > 0) @as(f64, @floatFromInt(passing)) / @as(f64, @floatFromInt(total)) * 100.0 else 0.0;
    
    try results.writer().print("\\n## Summary\\n\\n", .{});
    try results.writer().print("- **Total tests**: {}\\n", .{total});
    try results.writer().print("- **Passing**: {} ({d:.1}%)\\n", .{passing, pass_rate});
    try results.writer().print("- **Failing**: {}\\n\\n", .{failing});
    
    if (failing_opcodes.items.len > 0) {
        try results.writer().print("### Failing Opcodes\\n\\n", .{});
        for (failing_opcodes.items) |opcode| {
            try results.writer().print("- {s}\\n", .{opcode});
        }
    }
    
    try results.writer().print("\\n## Notes\\n\\n", .{});
    try results.writer().print("- This test compares opcode implementations between REVM and Guillotine EVM\\n", .{});
    try results.writer().print("- Both EVMs execute the same bytecode with identical initial state\\n", .{});
    try results.writer().print("- Match column shows if outputs are identical\\n", .{});
    try results.writer().print("- Generated at: {}\\n", .{std.time.timestamp()});
    
    // Write to file
    const file = try std.fs.cwd().createFile("opcode_implementation_status.md", .{});
    defer file.close();
    try file.writeAll(results.items);
    
}