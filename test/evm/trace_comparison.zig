const std = @import("std");
const evm = @import("evm");
const primitives = @import("primitives");
const revm = @import("revm");

const Address = primitives.Address;
const Evm = evm.Evm;
const MemoryDatabase = evm.MemoryDatabase;
const Revm = revm.Revm;

/// Compare execution traces between Zig EVM and REVM
pub fn compareTraces(allocator: std.mem.Allocator, bytecode: []const u8, gas_limit: u64) !void {
    // Run with Zig EVM and capture trace
    var zig_trace = std.ArrayList(u8).init(allocator);
    defer zig_trace.deinit();
    
    {
        var memory_db = MemoryDatabase.init(allocator);
        defer memory_db.deinit();
        
        const db_interface = memory_db.to_database_interface();
        const config = evm.EvmConfig.init(.CANCUN);
        const EvmType = evm.Evm(config);
        var vm = try EvmType.init(allocator, db_interface, null, 0, false, zig_trace.writer().any());
        defer vm.deinit();
        
        const caller = Address.from_u256(0x1000000000000000000000000000000000000001);
        try vm.state.set_balance(caller, std.math.maxInt(u256));
        
        const result = try vm.create_contract(caller, 0, bytecode, gas_limit);
        defer if (result.output) |output| allocator.free(output);
        
        std.debug.print("\nZig EVM result: success={}, gas_used={}\n", .{result.success, result.gas_used});
    }
    
    // Run with REVM and capture trace
    var revm_trace = std.ArrayList(u8).init(allocator);
    defer revm_trace.deinit();
    
    {
        var vm = try Revm.init(allocator, .{ .tracing = true });
        defer vm.deinit();
        
        const caller = Address.from_u256(0x1000000000000000000000000000000000000001);
        const contract_addr = Address.from_u256(0x2000000000000000000000000000000000000002);
        
        try vm.setBalance(caller, std.math.maxInt(u256));
        try vm.setCode(contract_addr, bytecode);
        
        var result = try vm.call(caller, contract_addr, 0, &.{}, gas_limit);
        defer result.deinit();
        
        // Get trace from REVM (this would need to be implemented in the wrapper)
        const trace_json = try vm.getTrace();
        defer allocator.free(trace_json);
        try revm_trace.appendSlice(trace_json);
        
        std.debug.print("REVM result: success={}, gas_used={}\n", .{result.success, result.gas_used});
    }
    
    // Compare traces line by line
    var zig_lines = std.mem.tokenizeScalar(u8, zig_trace.items, '\n');
    var revm_lines = std.mem.tokenizeScalar(u8, revm_trace.items, '\n');
    
    var line_num: usize = 0;
    while (true) {
        const zig_line = zig_lines.next();
        const revm_line = revm_lines.next();
        
        if (zig_line == null and revm_line == null) break;
        
        line_num += 1;
        
        if (zig_line == null) {
            std.debug.print("\n❌ DIVERGENCE at line {}: Zig trace ended early\n", .{line_num});
            break;
        }
        
        if (revm_line == null) {
            std.debug.print("\n❌ DIVERGENCE at line {}: REVM trace ended early\n", .{line_num});
            break;
        }
        
        // Parse both lines
        const zig_entry = try parseTraceLine(allocator, zig_line.?);
        defer zig_entry.deinit();
        const revm_entry = try parseTraceLine(allocator, revm_line.?);
        defer revm_entry.deinit();
        
        // Compare key fields
        if (!compareTraceEntries(zig_entry.value, revm_entry.value)) {
            std.debug.print("\n❌ DIVERGENCE at line {} (pc={}):\n", .{line_num, zig_entry.value.pc});
            std.debug.print("  Zig:  {s}\n", .{zig_line.?});
            std.debug.print("  REVM: {s}\n", .{revm_line.?});
            
            // Show context (previous 5 lines)
            std.debug.print("\nContext (previous 5 operations):\n", .{});
            // This would need to track previous lines
            
            break;
        }
    }
    
    if (zig_lines.next() == null and revm_lines.next() == null) {
        std.debug.print("\n✅ Traces match completely!\n", .{});
    }
}

const TraceEntry = struct {
    pc: usize,
    op: u8,
    gas: ?[]const u8 = null,
    gasCost: ?[]const u8 = null,
    stack: []const []const u8,
    depth: ?u32 = null,
    returnData: ?[]const u8 = null,
    refund: ?[]const u8 = null,
    memSize: ?usize = null,
    opName: ?[]const u8 = null,
};

fn parseTraceLine(allocator: std.mem.Allocator, line: []const u8) !std.json.Parsed(TraceEntry) {
    return try std.json.parseFromSlice(TraceEntry, allocator, line, .{});
}

fn compareTraceEntries(a: TraceEntry, b: TraceEntry) bool {
    // Compare PC
    if (a.pc != b.pc) {
        std.debug.print("  PC mismatch: {} vs {}\n", .{a.pc, b.pc});
        return false;
    }
    
    // Compare opcode
    if (a.op != b.op) {
        std.debug.print("  Opcode mismatch: 0x{x} ({s}) vs 0x{x} ({s})\n", .{
            a.op, a.opName orelse "?",
            b.op, b.opName orelse "?"
        });
        return false;
    }
    
    // Compare stack
    if (a.stack.len != b.stack.len) {
        std.debug.print("  Stack size mismatch: {} vs {}\n", .{a.stack.len, b.stack.len});
        return false;
    }
    
    for (a.stack, b.stack, 0..) |a_val, b_val, i| {
        if (!std.mem.eql(u8, a_val, b_val)) {
            std.debug.print("  Stack[{}] mismatch: {s} vs {s}\n", .{i, a_val, b_val});
            return false;
        }
    }
    
    return true;
}

test "compare ERC20 traces" {
    const allocator = std.testing.allocator;
    
    // ERC20 bytecode (simplified version that triggers the bug)
    const bytecode = @embedFile("erc20_bytecode.hex");
    
    try compareTraces(allocator, bytecode, 1_000_000_000);
}