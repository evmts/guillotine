const std = @import("std");
const frame = @import("frame.zig");

// Configuration for tracing behavior
pub const MemoryCaptureMode = enum { none, prefix, full };

pub const TracerConfig = struct {
    capture_memory: MemoryCaptureMode = .none,
    memory_prefix: usize = 0,                  // bytes to capture when mode is .prefix
    compute_gas_cost: bool = false,            // compute per-step gas deltas
};

pub const DetailedStructLog = struct {
    pc: u64,
    op: []const u8,
    gas: u64,
    gasCost: u64,
    depth: u32,
    stack: []const u256,
    memory: ?[]const u8,
    memSize: u32,
    // storage: ?std.hash_map.HashMap(u256, u256), // Not implemented yet
    // returnData: ?[]const u8, // Not implemented yet
    refund: u64,
    @"error": ?[]const u8,
};

// Generic tracer that can work with any writer
pub fn Tracer(comptime Writer: type) type {
    return struct {
        allocator: std.mem.Allocator,
        writer: Writer,
        cfg: TracerConfig = .{},
        prev_gas: ?u64 = null,
        
        const Self = @This();
        
        pub fn init(allocator: std.mem.Allocator, writer: Writer) Self {
            return .{
                .allocator = allocator,
                .writer = writer,
                .cfg = .{},
            };
        }
        
        pub fn initWithConfig(allocator: std.mem.Allocator, writer: Writer, cfg: TracerConfig) Self {
            return .{
                .allocator = allocator,
                .writer = writer,
                .cfg = cfg,
            };
        }
        
        pub fn snapshot(self: *Self, comptime FrameType: type, frame_instance: *const FrameType) !DetailedStructLog {
            // Capture stack
            const stack_size = frame_instance.next_stack_index;
            const stack_copy = try self.allocator.alloc(u256, stack_size);
            @memcpy(stack_copy, frame_instance.stack[0..stack_size]);
            
            // Get current opcode
            const opcode = if (frame_instance.pc < frame_instance.bytecode.len)
                frame_instance.bytecode[frame_instance.pc]
            else
                0x00;
            
            const op_name = getOpcodeName(opcode);
            
            // Gas calculation
            const gas_now: u64 = if (frame_instance.gas_remaining < 0) 0 else @intCast(frame_instance.gas_remaining);
            var gas_cost: u64 = 0;
            if (self.cfg.compute_gas_cost) {
                if (self.prev_gas) |prev| {
                    gas_cost = if (prev > gas_now) (prev - gas_now) else 0;
                }
                self.prev_gas = gas_now;
            }
            
            // Depth (if frame provides it)
            const depth_val: u32 = blk: {
                if (comptime @hasField(FrameType, "depth")) {
                    break :blk @intCast(frame_instance.depth);
                } else if (comptime @hasField(FrameType, "call_depth")) {
                    break :blk @intCast(frame_instance.call_depth);
                }
                break :blk 1;
            };
            
            // Refund (if frame provides it)
            const refund_val: u64 = blk: {
                if (comptime @hasField(FrameType, "gas_refund")) {
                    break :blk @intCast(frame_instance.gas_refund);
                }
                break :blk 0;
            };
            
            // Memory capture
            var mem_size: u32 = 0;
            const mem_copy = try self.captureMemory(FrameType, frame_instance, &mem_size);
            
            // Error capture
            const err_str = getFrameError(FrameType, frame_instance);
            
            return DetailedStructLog{
                .pc = frame_instance.pc,
                .op = op_name,
                .gas = gas_now,
                .gasCost = gas_cost,
                .depth = depth_val,
                .stack = stack_copy,
                .memory = mem_copy,
                .memSize = mem_size,
                .refund = refund_val,
                .@"error" = err_str,
            };
        }
        
        pub fn writeSnapshot(self: *Self, comptime FrameType: type, frame_instance: *const FrameType) !void {
            const log = try self.snapshot(FrameType, frame_instance);
            defer self.allocator.free(log.stack);
            defer if (log.memory) |m| self.allocator.free(m);
            
            try self.writeJson(&log);
        }
        
        pub fn writeJson(self: *Self, log: *const DetailedStructLog) !void {
            try self.writer.print(
                "{{\"pc\":{},\"op\":\"{s}\",\"gas\":{},\"gasCost\":{},\"depth\":{},\"stack\":[",
                .{ log.pc, log.op, log.gas, log.gasCost, log.depth },
            );
            
            // Write stack array
            for (log.stack, 0..) |val, i| {
                if (i > 0) try self.writer.writeAll(",");
                try self.writer.print("\"0x{x}\"", .{val});
            }
            
            try self.writer.print("],\"memSize\":{},\"refund\":{}", .{ log.memSize, log.refund });
            
            // Write memory if captured
            if (log.memory) |mem| {
                try self.writer.writeAll(",\"memory\":\"0x");
                for (mem) |byte| {
                    try self.writer.print("{x:0>2}", .{byte});
                }
                try self.writer.writeByte('"');
            }
            
            // Write error if present
            if (log.@"error") |err| {
                try self.writer.print(",\"error\":\"{s}\"", .{err});
            }
            
            try self.writer.writeAll("}}\n");
        }
        
        fn captureMemory(
            self: *Self,
            comptime FrameType: type,
            frame_instance: *const FrameType,
            mem_size: *u32,
        ) !?[]const u8 {
            _ = frame_instance;
            
            // For now, we don't have memory in the frame
            mem_size.* = 0;
            
            if (self.cfg.capture_memory == .none) return null;
            
            // When memory is added to frame, implement this:
            // if (comptime @hasField(FrameType, "memory")) {
            //     const mem_len = frame_instance.memory.len;
            //     mem_size.* = @intCast(mem_len);
            //     
            //     const to_copy = switch (self.cfg.capture_memory) {
            //         .full => mem_len,
            //         .prefix => @min(mem_len, self.cfg.memory_prefix),
            //         .none => 0,
            //     };
            //     
            //     if (to_copy == 0) return null;
            //     return try self.allocator.dupe(u8, frame_instance.memory[0..to_copy]);
            // }
            
            return null;
        }
    };
}

// Logging tracer that writes to stdout
pub const LoggingTracer = struct {
    base: Tracer(std.fs.File.Writer),
    
    pub fn init(allocator: std.mem.Allocator) LoggingTracer {
        const stdout = std.io.getStdOut().writer();
        return .{
            .base = Tracer(std.fs.File.Writer).init(allocator, stdout),
        };
    }
    
    pub fn initWithConfig(allocator: std.mem.Allocator, cfg: TracerConfig) LoggingTracer {
        const stdout = std.io.getStdOut().writer();
        return .{
            .base = Tracer(std.fs.File.Writer).initWithConfig(allocator, stdout, cfg),
        };
    }
    
    pub fn snapshot(self: *LoggingTracer, comptime FrameType: type, frame_instance: *const FrameType) !DetailedStructLog {
        return self.base.snapshot(FrameType, frame_instance);
    }
    
    pub fn writeSnapshot(self: *LoggingTracer, comptime FrameType: type, frame_instance: *const FrameType) !void {
        return self.base.writeSnapshot(FrameType, frame_instance);
    }
};

// File tracer that writes to a file
pub const FileTracer = struct {
    base: Tracer(std.fs.File.Writer),
    file: std.fs.File,
    
    pub fn init(allocator: std.mem.Allocator, path: []const u8) !FileTracer {
        const file = try std.fs.cwd().createFile(path, .{});
        return .{
            .base = Tracer(std.fs.File.Writer).init(allocator, file.writer()),
            .file = file,
        };
    }
    
    pub fn initWithConfig(allocator: std.mem.Allocator, path: []const u8, cfg: TracerConfig) !FileTracer {
        const file = try std.fs.cwd().createFile(path, .{});
        return .{
            .base = Tracer(std.fs.File.Writer).initWithConfig(allocator, file.writer(), cfg),
            .file = file,
        };
    }
    
    pub fn deinit(self: *FileTracer) void {
        self.file.close();
    }
    
    pub fn snapshot(self: *FileTracer, comptime FrameType: type, frame_instance: *const FrameType) !DetailedStructLog {
        return self.base.snapshot(FrameType, frame_instance);
    }
    
    pub fn writeSnapshot(self: *FileTracer, comptime FrameType: type, frame_instance: *const FrameType) !void {
        return self.base.writeSnapshot(FrameType, frame_instance);
    }
};

fn getFrameError(comptime FrameType: type, frame_instance: *const FrameType) ?[]const u8 {
    _ = frame_instance;
    
    // TODO: When frame has error fields, access them like:
    // if (comptime @hasField(FrameType, "last_error_str")) {
    //     return frame_instance.last_error_str;
    // }
    
    return null;
}

fn getOpcodeName(opcode: u8) []const u8 {
    return switch (opcode) {
        0x00 => "STOP",
        0x01 => "ADD",
        0x02 => "MUL",
        0x03 => "SUB",
        0x04 => "DIV",
        0x05 => "SDIV",
        0x06 => "MOD",
        0x07 => "SMOD",
        0x08 => "ADDMOD",
        0x09 => "MULMOD",
        0x0a => "EXP",
        0x0b => "SIGNEXTEND",
        0x10 => "LT",
        0x11 => "GT",
        0x12 => "SLT",
        0x13 => "SGT",
        0x14 => "EQ",
        0x15 => "ISZERO",
        0x16 => "AND",
        0x17 => "OR",
        0x18 => "XOR",
        0x19 => "NOT",
        0x1a => "BYTE",
        0x1b => "SHL",
        0x1c => "SHR",
        0x1d => "SAR",
        0x20 => "KECCAK256",
        0x50 => "POP",
        0x51 => "MLOAD",
        0x52 => "MSTORE",
        0x53 => "MSTORE8",
        0x56 => "JUMP",
        0x57 => "JUMPI",
        0x58 => "PC",
        0x59 => "MSIZE",
        0x5a => "GAS",
        0x5b => "JUMPDEST",
        0x5f => "PUSH0",
        0x60 => "PUSH1",
        0x61 => "PUSH2",
        0x62 => "PUSH3",
        0x63 => "PUSH4",
        0x64 => "PUSH5",
        0x65 => "PUSH6",
        0x66 => "PUSH7",
        0x67 => "PUSH8",
        0x68 => "PUSH9",
        0x69 => "PUSH10",
        0x6a => "PUSH11",
        0x6b => "PUSH12",
        0x6c => "PUSH13",
        0x6d => "PUSH14",
        0x6e => "PUSH15",
        0x6f => "PUSH16",
        0x70 => "PUSH17",
        0x71 => "PUSH18",
        0x72 => "PUSH19",
        0x73 => "PUSH20",
        0x74 => "PUSH21",
        0x75 => "PUSH22",
        0x76 => "PUSH23",
        0x77 => "PUSH24",
        0x78 => "PUSH25",
        0x79 => "PUSH26",
        0x7a => "PUSH27",
        0x7b => "PUSH28",
        0x7c => "PUSH29",
        0x7d => "PUSH30",
        0x7e => "PUSH31",
        0x7f => "PUSH32",
        0x80 => "DUP1",
        0x81 => "DUP2",
        0x82 => "DUP3",
        0x83 => "DUP4",
        0x84 => "DUP5",
        0x85 => "DUP6",
        0x86 => "DUP7",
        0x87 => "DUP8",
        0x88 => "DUP9",
        0x89 => "DUP10",
        0x8a => "DUP11",
        0x8b => "DUP12",
        0x8c => "DUP13",
        0x8d => "DUP14",
        0x8e => "DUP15",
        0x8f => "DUP16",
        0x90 => "SWAP1",
        0x91 => "SWAP2",
        0x92 => "SWAP3",
        0x93 => "SWAP4",
        0x94 => "SWAP5",
        0x95 => "SWAP6",
        0x96 => "SWAP7",
        0x97 => "SWAP8",
        0x98 => "SWAP9",
        0x99 => "SWAP10",
        0x9a => "SWAP11",
        0x9b => "SWAP12",
        0x9c => "SWAP13",
        0x9d => "SWAP14",
        0x9e => "SWAP15",
        0x9f => "SWAP16",
        0xfe => "INVALID",
        else => "UNKNOWN",
    };
}

// Tests
test "tracer captures basic frame state with writer" {
    const allocator = std.testing.allocator;
    
    // Create a frame with some state
    const Frame = frame.createColdFrame(.{
        .stack_size = 10,
        .block_gas_limit = 1000,
    });
    
    var test_frame = try Frame.init(allocator, &[_]u8{ 0x60, 0x05, 0x60, 0x03, 0x01 }, 1000);
    defer test_frame.deinit(allocator);
    
    // Push some values onto the stack
    try test_frame.push(3);
    try test_frame.push(5);
    test_frame.pc = 4; // At ADD opcode
    test_frame.gas_remaining = 950;
    
    // Create tracer with array list writer
    var output = std.ArrayList(u8).init(allocator);
    defer output.deinit();
    
    var tracer = Tracer(std.ArrayList(u8).Writer).init(allocator, output.writer());
    const log = try tracer.snapshot(Frame, &test_frame);
    defer allocator.free(log.stack);
    
    // Verify snapshot
    try std.testing.expectEqual(@as(u64, 4), log.pc);
    try std.testing.expectEqualStrings("ADD", log.op);
    try std.testing.expectEqual(@as(u64, 950), log.gas);
    try std.testing.expectEqual(@as(u32, 1), log.depth);
    try std.testing.expectEqual(@as(usize, 2), log.stack.len);
    try std.testing.expectEqual(@as(u256, 3), log.stack[0]);
    try std.testing.expectEqual(@as(u256, 5), log.stack[1]);
}

test "tracer writes JSON to writer" {
    const allocator = std.testing.allocator;
    
    const Frame = frame.createColdFrame(.{});
    var test_frame = try Frame.init(allocator, &[_]u8{ 0x60, 0x05, 0x60, 0x03, 0x01 }, 1000);
    defer test_frame.deinit(allocator);
    
    try test_frame.push(3);
    try test_frame.push(5);
    test_frame.pc = 4;
    test_frame.gas_remaining = 950;
    
    // Create tracer with array list writer
    var output = std.ArrayList(u8).init(allocator);
    defer output.deinit();
    
    var tracer = Tracer(std.ArrayList(u8).Writer).init(allocator, output.writer());
    try tracer.writeSnapshot(Frame, &test_frame);
    
    const json = output.items;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"pc\":4") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"op\":\"ADD\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"gas\":950") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"stack\":[\"0x3\",\"0x5\"]") != null);
}

test "logging tracer writes to stdout" {
    const allocator = std.testing.allocator;
    
    const Frame = frame.createColdFrame(.{});
    var test_frame = try Frame.init(allocator, &[_]u8{0x00}, 1000);
    defer test_frame.deinit(allocator);
    
    var tracer = LoggingTracer.init(allocator);
    const log = try tracer.snapshot(Frame, &test_frame);
    defer allocator.free(log.stack);
    
    try std.testing.expectEqual(@as(u64, 0), log.pc);
    try std.testing.expectEqualStrings("STOP", log.op);
}

test "file tracer writes to file" {
    const allocator = std.testing.allocator;
    
    // Create temp dir and file
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    
    // Create file in the temp directory
    const file = try tmp_dir.dir.createFile("trace.json", .{});
    file.close();
    
    // Get the full path
    const file_path = try tmp_dir.dir.realpathAlloc(allocator, "trace.json");
    defer allocator.free(file_path);
    
    // Create frame
    const Frame = frame.createColdFrame(.{});
    var test_frame = try Frame.init(allocator, &[_]u8{ 0x60, 0x42 }, 1000);
    defer test_frame.deinit(allocator);
    
    test_frame.pc = 0;
    test_frame.gas_remaining = 997;
    
    // Create file tracer and write
    var tracer = try FileTracer.init(allocator, file_path);
    defer tracer.deinit();
    
    try tracer.writeSnapshot(Frame, &test_frame);
    
    // Read file and verify
    const contents = try tmp_dir.dir.readFileAlloc(allocator, "trace.json", 1024);
    defer allocator.free(contents);
    
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"pc\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"op\":\"PUSH1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"gas\":997") != null);
}

test "tracer with gas cost computation" {
    const allocator = std.testing.allocator;
    
    const Frame = frame.createColdFrame(.{});
    var test_frame = try Frame.init(allocator, &[_]u8{ 0x60, 0x05, 0x01 }, 1000);
    defer test_frame.deinit(allocator);
    
    var output = std.ArrayList(u8).init(allocator);
    defer output.deinit();
    
    var tracer = Tracer(std.ArrayList(u8).Writer).initWithConfig(
        allocator,
        output.writer(),
        .{ .compute_gas_cost = true },
    );
    
    // First snapshot - no previous gas, so cost should be 0
    test_frame.gas_remaining = 1000;
    const log1 = try tracer.snapshot(Frame, &test_frame);
    defer allocator.free(log1.stack);
    try std.testing.expectEqual(@as(u64, 0), log1.gasCost);
    
    // Second snapshot - gas decreased by 3
    test_frame.gas_remaining = 997;
    const log2 = try tracer.snapshot(Frame, &test_frame);
    defer allocator.free(log2.stack);
    try std.testing.expectEqual(@as(u64, 3), log2.gasCost);
    
    // Third snapshot - gas decreased by 21
    test_frame.gas_remaining = 976;
    const log3 = try tracer.snapshot(Frame, &test_frame);
    defer allocator.free(log3.stack);
    try std.testing.expectEqual(@as(u64, 21), log3.gasCost);
}

test "tracer handles empty stack with JSON output" {
    const allocator = std.testing.allocator;
    
    const Frame = frame.createColdFrame(.{});
    var test_frame = try Frame.init(allocator, &[_]u8{0x00}, 1000);
    defer test_frame.deinit(allocator);
    
    var output = std.ArrayList(u8).init(allocator);
    defer output.deinit();
    
    var tracer = Tracer(std.ArrayList(u8).Writer).init(allocator, output.writer());
    try tracer.writeSnapshot(Frame, &test_frame);
    
    const json = output.items;
    try std.testing.expect(std.mem.indexOf(u8, json, "\"stack\":[]") != null);
}

test "tracer handles large stack values in JSON" {
    const allocator = std.testing.allocator;
    
    const Frame = frame.createColdFrame(.{});
    var test_frame = try Frame.init(allocator, &[_]u8{0x00}, 1000);
    defer test_frame.deinit(allocator);
    
    try test_frame.push(std.math.maxInt(u256));
    try test_frame.push(0xdeadbeef);
    
    var output = std.ArrayList(u8).init(allocator);
    defer output.deinit();
    
    var tracer = Tracer(std.ArrayList(u8).Writer).init(allocator, output.writer());
    try tracer.writeSnapshot(Frame, &test_frame);
    
    const json = output.items;
    try std.testing.expect(std.mem.indexOf(u8, json, "0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "0xdeadbeef") != null);
}