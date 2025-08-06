const std = @import("std");
const opcodes = @import("opcodes/opcode.zig");

/// Tracer interface for capturing EVM execution traces
pub const Tracer = struct {
    writer: std.io.AnyWriter,
    
    pub fn init(writer: std.io.AnyWriter) Tracer {
        return .{ .writer = writer };
    }
    
    /// Write a trace entry in REVM-compatible JSON format
    pub fn trace(
        self: *Tracer,
        pc: usize,
        opcode: u8,
        stack: []const u256,
        gas: u64,
        gas_cost: u64,
        memory_size: usize,
        depth: u32,
    ) !void {
        // Get opcode name
        const op_enum = std.meta.intToEnum(opcodes.Enum, opcode) catch opcodes.Enum.INVALID;
        const op_name = opcodes.get_name(op_enum);
        
        // Format gas values as hex strings to match REVM
        var gas_hex_buf: [18]u8 = undefined;
        const gas_hex = try std.fmt.bufPrint(&gas_hex_buf, "0x{x}", .{gas});
        
        var gas_cost_hex_buf: [18]u8 = undefined;
        const gas_cost_hex = try std.fmt.bufPrint(&gas_cost_hex_buf, "0x{x}", .{gas_cost});
        
        // Start JSON object
        try self.writer.writeAll("{\"pc\":");
        try std.json.stringify(pc, .{}, self.writer);
        
        try self.writer.writeAll(",\"op\":");
        try std.json.stringify(opcode, .{}, self.writer);
        
        try self.writer.writeAll(",\"gas\":\"");
        try self.writer.writeAll(gas_hex);
        try self.writer.writeAll("\"");
        
        try self.writer.writeAll(",\"gasCost\":\"");
        try self.writer.writeAll(gas_cost_hex);
        try self.writer.writeAll("\"");
        
        // Write stack as array of hex strings
        try self.writer.writeAll(",\"stack\":[");
        for (stack, 0..) |value, i| {
            if (i > 0) try self.writer.writeAll(",");
            
            if (value == 0) {
                try self.writer.writeAll("\"0x0\"");
            } else {
                // Format as minimal hex without leading zeros
                var hex_buf: [66]u8 = undefined;
                const hex_str = try std.fmt.bufPrint(&hex_buf, "0x{x}", .{value});
                try self.writer.writeAll("\"");
                try self.writer.writeAll(hex_str);
                try self.writer.writeAll("\"");
            }
        }
        try self.writer.writeAll("]");
        
        try self.writer.writeAll(",\"depth\":");
        try std.json.stringify(depth, .{}, self.writer);
        
        try self.writer.writeAll(",\"returnData\":\"0x\"");
        
        try self.writer.writeAll(",\"refund\":\"0x0\"");
        
        try self.writer.writeAll(",\"memSize\":");
        try std.json.stringify(memory_size, .{}, self.writer);
        
        try self.writer.writeAll(",\"opName\":\"");
        try self.writer.writeAll(op_name);
        try self.writer.writeAll("\"");
        
        try self.writer.writeAll("}\n");
    }
};