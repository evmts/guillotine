const std = @import("std");
const ArrayList = std.ArrayListAligned;
const Opcode = @import("../opcodes/opcode.zig").Opcode;
const BytecodeConfig = @import("bytecode_config.zig").BytecodeConfig;

// Pattern key types for different sequence lengths
const PatternKey2 = struct { a: u8, b: u8 };
const PatternKey3 = struct { a: u8, b: u8, c: u8 };
const PatternKey4 = struct { a: u8, b: u8, c: u8, d: u8 };
const PatternKey5 = struct { a: u8, b: u8, c: u8, d: u8, e: u8 };
const PatternKey6 = struct { a: u8, b: u8, c: u8, d: u8, e: u8, f: u8 };
const PatternKey7 = struct { a: u8, b: u8, c: u8, d: u8, e: u8, f: u8, g: u8 };
const PatternKey8 = struct { a: u8, b: u8, c: u8, d: u8, e: u8, f: u8, g: u8, h: u8 };

/// User owned struct used for introspection and debugging
pub const BytecodeStats = struct {
    pub const Fusion = struct {
        pc: usize,
        second_opcode: Opcode,
    };
    
    pub const Jump = struct {
        pc: usize,
        target: u256,
    };
    
    pub const PushValue = struct {
        pc: usize,
        value: u256,
    };
    
    pub const Pattern = struct {
        opcodes: []const u8,
        count: u32,
        
        pub fn format(self: Pattern, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
            _ = fmt;
            _ = options;
            try writer.writeAll("[");
            for (self.opcodes, 0..) |op, i| {
                if (i > 0) try writer.writeAll(", ");
                const opcode_enum = std.meta.intToEnum(Opcode, op) catch {
                    try writer.print("0x{x:0>2}", .{op});
                    continue;
                };
                try writer.writeAll(@tagName(opcode_enum));
            }
            try writer.writeAll("]");
        }
    };
    
    opcode_counts: [256]u32,
    push_values: []const PushValue,
    potential_fusions: []const Fusion,
    jumpdests: []const usize,
    jumps: []const Jump,
    backwards_jumps: usize,
    is_create_code: bool,
    // Pattern tracking - top 3 patterns for each length
    patterns_2: []const Pattern,
    patterns_3: []const Pattern,
    patterns_4: []const Pattern,
    patterns_5: []const Pattern,
    patterns_6: []const Pattern,
    patterns_7: []const Pattern,
    patterns_8: []const Pattern,
    
    /// Analyze bytecode and return statistics
    pub fn analyze(allocator: std.mem.Allocator, bytecode: []const u8) !BytecodeStats {
        var opcode_counts = [_]u32{0} ** 256;
        var push_values = try std.ArrayList(PushValue).initCapacity(allocator, 0);
        errdefer push_values.deinit(allocator);
        var potential_fusions = try std.ArrayList(Fusion).initCapacity(allocator, 0);
        errdefer potential_fusions.deinit(allocator);
        var jumpdests = try std.ArrayList(usize).initCapacity(allocator, 0);
        errdefer jumpdests.deinit(allocator);
        var jumps = try std.ArrayList(Jump).initCapacity(allocator, 0);
        errdefer jumps.deinit(allocator);
        var backwards_jumps: usize = 0;
        
        // Pattern tracking maps
        var pattern_map_2 = std.AutoHashMap(PatternKey2, u32).init(allocator);
        defer pattern_map_2.deinit();
        var pattern_map_3 = std.AutoHashMap(PatternKey3, u32).init(allocator);
        defer pattern_map_3.deinit();
        var pattern_map_4 = std.AutoHashMap(PatternKey4, u32).init(allocator);
        defer pattern_map_4.deinit();
        var pattern_map_5 = std.AutoHashMap(PatternKey5, u32).init(allocator);
        defer pattern_map_5.deinit();
        var pattern_map_6 = std.AutoHashMap(PatternKey6, u32).init(allocator);
        defer pattern_map_6.deinit();
        var pattern_map_7 = std.AutoHashMap(PatternKey7, u32).init(allocator);
        defer pattern_map_7.deinit();
        var pattern_map_8 = std.AutoHashMap(PatternKey8, u32).init(allocator);
        defer pattern_map_8.deinit();
        
        // Store the actual opcodes for pattern analysis (excluding push data)
        var opcodes = try std.ArrayList(u8).initCapacity(allocator, bytecode.len);
        defer opcodes.deinit(allocator);
        
        var pc: usize = 0;
        while (pc < bytecode.len) {
            const opcode_byte = bytecode[pc];
            opcode_counts[opcode_byte] += 1;
            
            // Add to opcodes list for pattern tracking (only actual opcodes, not push data)
            try opcodes.append(allocator, opcode_byte);
            
            const opcode = std.meta.intToEnum(Opcode, opcode_byte) catch {
                // Invalid opcode
                pc += 1;
                continue;
            };
            
            // Track JUMPDEST locations
            if (opcode == .JUMPDEST) {
                try jumpdests.append(allocator, pc);
            }
            
            // Check for PUSH opcodes
            if (@intFromEnum(opcode) >= @intFromEnum(Opcode.PUSH1) and 
                @intFromEnum(opcode) <= @intFromEnum(Opcode.PUSH32)) {
                const push_size = @intFromEnum(opcode) - @intFromEnum(Opcode.PUSH1) + 1;
                
                if (pc + push_size < bytecode.len) {
                    // Extract push value
                    var value: u256 = 0;
                    for (1..push_size + 1) |i| {
                        if (pc + i < bytecode.len) {
                            value = (value << 8) | bytecode[pc + i];
                        }
                    }
                    try push_values.append(allocator, .{ .pc = pc, .value = value });
                    
                    // Check for potential fusion with next opcode
                    const next_pc = pc + 1 + push_size;
                    if (next_pc < bytecode.len) {
                        const next_opcode = std.meta.intToEnum(Opcode, bytecode[next_pc]) catch {
                            pc += 1 + push_size;
                            continue;
                        };
                        
                        // Common fusion patterns
                        switch (next_opcode) {
                            .ADD, .MUL, .SUB, .DIV, .JUMP, .JUMPI, .GT, .LT, .EQ => {
                                try potential_fusions.append(allocator, .{ .pc = pc, .second_opcode = next_opcode });
                            },
                            else => {},
                        }
                    }
                }
                
                pc += 1 + push_size;
            } else if (opcode == .JUMP or opcode == .JUMPI) {
                // For static analysis, we can only track JUMP after PUSH
                if (pc > 0) {
                    // Check if previous instruction was a PUSH
                    var push_pc = pc - 1;
                    var found_push = false;
                    var jump_target: u256 = 0;
                    
                    // Scan backwards for PUSH instruction
                    while (push_pc > 0 and pc - push_pc < 33) : (push_pc -= 1) {
                        const prev_opcode = std.meta.intToEnum(Opcode, bytecode[push_pc]) catch continue;
                        if (@intFromEnum(prev_opcode) >= @intFromEnum(Opcode.PUSH1) and 
                            @intFromEnum(prev_opcode) <= @intFromEnum(Opcode.PUSH32)) {
                            const push_size = @intFromEnum(prev_opcode) - @intFromEnum(Opcode.PUSH1) + 1;
                            if (push_pc + 1 + push_size == pc) {
                                // This PUSH feeds into our JUMP
                                jump_target = 0;
                                for (1..push_size + 1) |i| {
                                    if (push_pc + i < bytecode.len) {
                                        jump_target = (jump_target << 8) | bytecode[push_pc + i];
                                    }
                                }
                                found_push = true;
                                break;
                            }
                        }
                    }
                    
                    if (found_push) {
                        try jumps.append(allocator, .{ .pc = pc, .target = jump_target });
                        if (jump_target < pc) {
                            backwards_jumps += 1;
                        }
                    }
                }
                pc += 1;
            } else {
                pc += 1;
            }
        }
        
        // Now analyze patterns from the collected opcodes
        const opcode_list = opcodes.items;
        
        // Track 2-opcode patterns
        if (opcode_list.len >= 2) {
            var i: usize = 0;
            while (i < opcode_list.len - 1) : (i += 1) {
                const key = PatternKey2{ .a = opcode_list[i], .b = opcode_list[i + 1] };
                const entry = try pattern_map_2.getOrPut(key);
                if (!entry.found_existing) {
                    entry.value_ptr.* = 0;
                }
                entry.value_ptr.* += 1;
            }
        }
        
        // Track 3-opcode patterns
        if (opcode_list.len >= 3) {
            var i: usize = 0;
            while (i < opcode_list.len - 2) : (i += 1) {
                const key = PatternKey3{ .a = opcode_list[i], .b = opcode_list[i + 1], .c = opcode_list[i + 2] };
                const entry = try pattern_map_3.getOrPut(key);
                if (!entry.found_existing) {
                    entry.value_ptr.* = 0;
                }
                entry.value_ptr.* += 1;
            }
        }
        
        // Track 4-opcode patterns
        if (opcode_list.len >= 4) {
            var i: usize = 0;
            while (i < opcode_list.len - 3) : (i += 1) {
                const key = PatternKey4{ .a = opcode_list[i], .b = opcode_list[i + 1], .c = opcode_list[i + 2], .d = opcode_list[i + 3] };
                const entry = try pattern_map_4.getOrPut(key);
                if (!entry.found_existing) {
                    entry.value_ptr.* = 0;
                }
                entry.value_ptr.* += 1;
            }
        }
        
        // Track 5-opcode patterns
        if (opcode_list.len >= 5) {
            var i: usize = 0;
            while (i < opcode_list.len - 4) : (i += 1) {
                const key = PatternKey5{ .a = opcode_list[i], .b = opcode_list[i + 1], .c = opcode_list[i + 2], .d = opcode_list[i + 3], .e = opcode_list[i + 4] };
                const entry = try pattern_map_5.getOrPut(key);
                if (!entry.found_existing) {
                    entry.value_ptr.* = 0;
                }
                entry.value_ptr.* += 1;
            }
        }
        
        // Track 6-opcode patterns
        if (opcode_list.len >= 6) {
            var i: usize = 0;
            while (i < opcode_list.len - 5) : (i += 1) {
                const key = PatternKey6{ .a = opcode_list[i], .b = opcode_list[i + 1], .c = opcode_list[i + 2], .d = opcode_list[i + 3], .e = opcode_list[i + 4], .f = opcode_list[i + 5] };
                const entry = try pattern_map_6.getOrPut(key);
                if (!entry.found_existing) {
                    entry.value_ptr.* = 0;
                }
                entry.value_ptr.* += 1;
            }
        }
        
        // Track 7-opcode patterns
        if (opcode_list.len >= 7) {
            var i: usize = 0;
            while (i < opcode_list.len - 6) : (i += 1) {
                const key = PatternKey7{ .a = opcode_list[i], .b = opcode_list[i + 1], .c = opcode_list[i + 2], .d = opcode_list[i + 3], .e = opcode_list[i + 4], .f = opcode_list[i + 5], .g = opcode_list[i + 6] };
                const entry = try pattern_map_7.getOrPut(key);
                if (!entry.found_existing) {
                    entry.value_ptr.* = 0;
                }
                entry.value_ptr.* += 1;
            }
        }
        
        // Track 8-opcode patterns
        if (opcode_list.len >= 8) {
            var i: usize = 0;
            while (i < opcode_list.len - 7) : (i += 1) {
                const key = PatternKey8{ .a = opcode_list[i], .b = opcode_list[i + 1], .c = opcode_list[i + 2], .d = opcode_list[i + 3], .e = opcode_list[i + 4], .f = opcode_list[i + 5], .g = opcode_list[i + 6], .h = opcode_list[i + 7] };
                const entry = try pattern_map_8.getOrPut(key);
                if (!entry.found_existing) {
                    entry.value_ptr.* = 0;
                }
                entry.value_ptr.* += 1;
            }
        }
        
        // Extract top 3 patterns for each length
        const patterns_2 = try extractTopPatterns2(allocator, pattern_map_2);
        const patterns_3 = try extractTopPatterns3(allocator, pattern_map_3);
        const patterns_4 = try extractTopPatterns4(allocator, pattern_map_4);
        const patterns_5 = try extractTopPatterns5(allocator, pattern_map_5);
        const patterns_6 = try extractTopPatterns6(allocator, pattern_map_6);
        const patterns_7 = try extractTopPatterns7(allocator, pattern_map_7);
        const patterns_8 = try extractTopPatterns8(allocator, pattern_map_8);
        
        return BytecodeStats{
            .opcode_counts = opcode_counts,
            .push_values = try push_values.toOwnedSlice(allocator),
            .potential_fusions = try potential_fusions.toOwnedSlice(allocator),
            .jumpdests = try jumpdests.toOwnedSlice(allocator),
            .jumps = try jumps.toOwnedSlice(allocator),
            .backwards_jumps = backwards_jumps,
            .is_create_code = false, // CREATE code pattern detection not implemented
            .patterns_2 = patterns_2,
            .patterns_3 = patterns_3,
            .patterns_4 = patterns_4,
            .patterns_5 = patterns_5,
            .patterns_6 = patterns_6,
            .patterns_7 = patterns_7,
            .patterns_8 = patterns_8,
        };
    }
    
    fn extractTopPatterns2(allocator: std.mem.Allocator, map: std.AutoHashMap(PatternKey2, u32)) ![]const Pattern {
        var patterns = try std.ArrayList(Pattern).initCapacity(allocator, map.count());
        defer patterns.deinit(allocator);
        
        var iter = map.iterator();
        while (iter.next()) |entry| {
            const opcodes = try allocator.alloc(u8, 2);
            opcodes[0] = entry.key_ptr.a;
            opcodes[1] = entry.key_ptr.b;
            try patterns.append(allocator, .{ .opcodes = opcodes, .count = entry.value_ptr.* });
        }
        
        // Sort by count descending
        std.mem.sort(Pattern, patterns.items, {}, struct {
            fn lessThan(_: void, a: Pattern, b: Pattern) bool {
                return a.count > b.count;
            }
        }.lessThan);
        
        // Return top 3 and clean up the rest
        const top_count = @min(3, patterns.items.len);
        const result = try allocator.alloc(Pattern, top_count);
        for (0..top_count) |i| {
            result[i] = patterns.items[i];
        }
        // Free the opcodes that we're not keeping
        for (patterns.items[top_count..]) |pattern| {
            allocator.free(pattern.opcodes);
        }
        return result;
    }
    
    fn extractTopPatterns3(allocator: std.mem.Allocator, map: std.AutoHashMap(PatternKey3, u32)) ![]const Pattern {
        var patterns = try std.ArrayList(Pattern).initCapacity(allocator, map.count());
        defer patterns.deinit(allocator);
        
        var iter = map.iterator();
        while (iter.next()) |entry| {
            const opcodes = try allocator.alloc(u8, 3);
            opcodes[0] = entry.key_ptr.a;
            opcodes[1] = entry.key_ptr.b;
            opcodes[2] = entry.key_ptr.c;
            try patterns.append(allocator, .{ .opcodes = opcodes, .count = entry.value_ptr.* });
        }
        
        std.mem.sort(Pattern, patterns.items, {}, struct {
            fn lessThan(_: void, a: Pattern, b: Pattern) bool {
                return a.count > b.count;
            }
        }.lessThan);
        
        const top_count = @min(3, patterns.items.len);
        const result = try allocator.alloc(Pattern, top_count);
        for (0..top_count) |i| {
            result[i] = patterns.items[i];
        }
        // Free the opcodes that we're not keeping
        for (patterns.items[top_count..]) |pattern| {
            allocator.free(pattern.opcodes);
        }
        return result;
    }
    
    fn extractTopPatterns4(allocator: std.mem.Allocator, map: std.AutoHashMap(PatternKey4, u32)) ![]const Pattern {
        var patterns = try std.ArrayList(Pattern).initCapacity(allocator, map.count());
        defer patterns.deinit(allocator);
        
        var iter = map.iterator();
        while (iter.next()) |entry| {
            const opcodes = try allocator.alloc(u8, 4);
            opcodes[0] = entry.key_ptr.a;
            opcodes[1] = entry.key_ptr.b;
            opcodes[2] = entry.key_ptr.c;
            opcodes[3] = entry.key_ptr.d;
            try patterns.append(allocator, .{ .opcodes = opcodes, .count = entry.value_ptr.* });
        }
        
        std.mem.sort(Pattern, patterns.items, {}, struct {
            fn lessThan(_: void, a: Pattern, b: Pattern) bool {
                return a.count > b.count;
            }
        }.lessThan);
        
        const top_count = @min(3, patterns.items.len);
        const result = try allocator.alloc(Pattern, top_count);
        for (0..top_count) |i| {
            result[i] = patterns.items[i];
        }
        // Free the opcodes that we're not keeping
        for (patterns.items[top_count..]) |pattern| {
            allocator.free(pattern.opcodes);
        }
        return result;
    }
    
    fn extractTopPatterns5(allocator: std.mem.Allocator, map: std.AutoHashMap(PatternKey5, u32)) ![]const Pattern {
        var patterns = try std.ArrayList(Pattern).initCapacity(allocator, map.count());
        defer patterns.deinit(allocator);
        
        var iter = map.iterator();
        while (iter.next()) |entry| {
            const opcodes = try allocator.alloc(u8, 5);
            opcodes[0] = entry.key_ptr.a;
            opcodes[1] = entry.key_ptr.b;
            opcodes[2] = entry.key_ptr.c;
            opcodes[3] = entry.key_ptr.d;
            opcodes[4] = entry.key_ptr.e;
            try patterns.append(allocator, .{ .opcodes = opcodes, .count = entry.value_ptr.* });
        }
        
        std.mem.sort(Pattern, patterns.items, {}, struct {
            fn lessThan(_: void, a: Pattern, b: Pattern) bool {
                return a.count > b.count;
            }
        }.lessThan);
        
        const top_count = @min(3, patterns.items.len);
        const result = try allocator.alloc(Pattern, top_count);
        for (0..top_count) |i| {
            result[i] = patterns.items[i];
        }
        // Free the opcodes that we're not keeping
        for (patterns.items[top_count..]) |pattern| {
            allocator.free(pattern.opcodes);
        }
        return result;
    }
    
    fn extractTopPatterns6(allocator: std.mem.Allocator, map: std.AutoHashMap(PatternKey6, u32)) ![]const Pattern {
        var patterns = try std.ArrayList(Pattern).initCapacity(allocator, map.count());
        defer patterns.deinit(allocator);
        
        var iter = map.iterator();
        while (iter.next()) |entry| {
            const opcodes = try allocator.alloc(u8, 6);
            opcodes[0] = entry.key_ptr.a;
            opcodes[1] = entry.key_ptr.b;
            opcodes[2] = entry.key_ptr.c;
            opcodes[3] = entry.key_ptr.d;
            opcodes[4] = entry.key_ptr.e;
            opcodes[5] = entry.key_ptr.f;
            try patterns.append(allocator, .{ .opcodes = opcodes, .count = entry.value_ptr.* });
        }
        
        std.mem.sort(Pattern, patterns.items, {}, struct {
            fn lessThan(_: void, a: Pattern, b: Pattern) bool {
                return a.count > b.count;
            }
        }.lessThan);
        
        const top_count = @min(3, patterns.items.len);
        const result = try allocator.alloc(Pattern, top_count);
        for (0..top_count) |i| {
            result[i] = patterns.items[i];
        }
        // Free the opcodes that we're not keeping
        for (patterns.items[top_count..]) |pattern| {
            allocator.free(pattern.opcodes);
        }
        return result;
    }
    
    fn extractTopPatterns7(allocator: std.mem.Allocator, map: std.AutoHashMap(PatternKey7, u32)) ![]const Pattern {
        var patterns = try std.ArrayList(Pattern).initCapacity(allocator, map.count());
        defer patterns.deinit(allocator);
        
        var iter = map.iterator();
        while (iter.next()) |entry| {
            const opcodes = try allocator.alloc(u8, 7);
            opcodes[0] = entry.key_ptr.a;
            opcodes[1] = entry.key_ptr.b;
            opcodes[2] = entry.key_ptr.c;
            opcodes[3] = entry.key_ptr.d;
            opcodes[4] = entry.key_ptr.e;
            opcodes[5] = entry.key_ptr.f;
            opcodes[6] = entry.key_ptr.g;
            try patterns.append(allocator, .{ .opcodes = opcodes, .count = entry.value_ptr.* });
        }
        
        std.mem.sort(Pattern, patterns.items, {}, struct {
            fn lessThan(_: void, a: Pattern, b: Pattern) bool {
                return a.count > b.count;
            }
        }.lessThan);
        
        const top_count = @min(3, patterns.items.len);
        const result = try allocator.alloc(Pattern, top_count);
        for (0..top_count) |i| {
            result[i] = patterns.items[i];
        }
        // Free the opcodes that we're not keeping
        for (patterns.items[top_count..]) |pattern| {
            allocator.free(pattern.opcodes);
        }
        return result;
    }
    
    fn extractTopPatterns8(allocator: std.mem.Allocator, map: std.AutoHashMap(PatternKey8, u32)) ![]const Pattern {
        var patterns = try std.ArrayList(Pattern).initCapacity(allocator, map.count());
        defer patterns.deinit(allocator);
        
        var iter = map.iterator();
        while (iter.next()) |entry| {
            const opcodes = try allocator.alloc(u8, 8);
            opcodes[0] = entry.key_ptr.a;
            opcodes[1] = entry.key_ptr.b;
            opcodes[2] = entry.key_ptr.c;
            opcodes[3] = entry.key_ptr.d;
            opcodes[4] = entry.key_ptr.e;
            opcodes[5] = entry.key_ptr.f;
            opcodes[6] = entry.key_ptr.g;
            opcodes[7] = entry.key_ptr.h;
            try patterns.append(allocator, .{ .opcodes = opcodes, .count = entry.value_ptr.* });
        }
        
        std.mem.sort(Pattern, patterns.items, {}, struct {
            fn lessThan(_: void, a: Pattern, b: Pattern) bool {
                return a.count > b.count;
            }
        }.lessThan);
        
        const top_count = @min(3, patterns.items.len);
        const result = try allocator.alloc(Pattern, top_count);
        for (0..top_count) |i| {
            result[i] = patterns.items[i];
        }
        // Free the opcodes that we're not keeping
        for (patterns.items[top_count..]) |pattern| {
            allocator.free(pattern.opcodes);
        }
        return result;
    }
    
    /// Deallocate statistics data
    pub fn deinit(self: *BytecodeStats, allocator: std.mem.Allocator) void {
        allocator.free(self.push_values);
        allocator.free(self.potential_fusions);
        allocator.free(self.jumpdests);
        allocator.free(self.jumps);
        // Free pattern data
        for (self.patterns_2) |pattern| {
            allocator.free(pattern.opcodes);
        }
        allocator.free(self.patterns_2);
        for (self.patterns_3) |pattern| {
            allocator.free(pattern.opcodes);
        }
        allocator.free(self.patterns_3);
        for (self.patterns_4) |pattern| {
            allocator.free(pattern.opcodes);
        }
        allocator.free(self.patterns_4);
        for (self.patterns_5) |pattern| {
            allocator.free(pattern.opcodes);
        }
        allocator.free(self.patterns_5);
        for (self.patterns_6) |pattern| {
            allocator.free(pattern.opcodes);
        }
        allocator.free(self.patterns_6);
        for (self.patterns_7) |pattern| {
            allocator.free(pattern.opcodes);
        }
        allocator.free(self.patterns_7);
        for (self.patterns_8) |pattern| {
            allocator.free(pattern.opcodes);
        }
        allocator.free(self.patterns_8);
    }
    
    pub fn formatStats(self: BytecodeStats, allocator: std.mem.Allocator) ![]const u8 {
        // https://ziglang.org/documentation/master/std/#std.array_list.Aligned
        var list = try std.ArrayList(u8).initCapacity(allocator, 0);
        defer list.deinit(allocator);
        const writer = list.writer(allocator);
        
        try writer.writeAll("\n=== Bytecode Statistics ===\n");
        try writer.writeAll("Opcode counts:\n");
        var total_opcodes: u32 = 0;
        for (self.opcode_counts, 0..) |count, op| {
            if (count > 0) {
                // https://ziglang.org/documentation/master/std/#std.meta.intToEnum
                // Converts an integer to an enum value, returns error if invalid
                const opcode_enum = std.meta.intToEnum(Opcode, op) catch {
                    try writer.print("  UNKNOWN(0x{x:0>2}): {}\n", .{ op, count });
                    continue;
                };
                // https://ziglang.org/documentation/master/#tagName
                // @tagName returns the string representation of an enum value
                try writer.print("  {s}: {}\n", .{ @tagName(opcode_enum), count });
                total_opcodes += count;
            }
        }
        try writer.print("Total opcodes: {}\n\n", .{total_opcodes});
        if (self.push_values.len > 0) {
            try writer.print("Push values ({} total):\n", .{self.push_values.len});
            for (self.push_values) |pv| {
                try writer.print("  PC {}: 0x{x}\n", .{ pv.pc, pv.value });
            }
            try writer.writeAll("\n");
        }
        if (self.potential_fusions.len > 0) {
            try writer.print("Potential fusions ({} total):\n", .{self.potential_fusions.len});
            for (self.potential_fusions) |fusion| {
                try writer.print("  PC {}: PUSH + {s}\n", .{ fusion.pc, @tagName(fusion.second_opcode) });
            }
            try writer.writeAll("\n");
        }
        if (self.jumpdests.len > 0) {
            try writer.print("Jump destinations ({} total):\n", .{self.jumpdests.len});
            for (self.jumpdests) |dest| {
                try writer.print("  PC {}\n", .{dest});
            }
            try writer.writeAll("\n");
        }
        if (self.jumps.len > 0) {
            try writer.print("Jumps ({} total, {} backwards):\n", .{ self.jumps.len, self.backwards_jumps });
            for (self.jumps) |jump| {
                const direction = if (jump.target < jump.pc) "↑" else "↓";
                try writer.print("  PC {} {s} target 0x{x}\n", .{ jump.pc, direction, jump.target });
            }
            try writer.writeAll("\n");
        }
        
        // Display pattern statistics
        try writer.writeAll("Pattern Analysis:\n");
        
        if (self.patterns_2.len > 0) {
            try writer.writeAll("\nTop 2-opcode patterns:\n");
            for (self.patterns_2) |pattern| {
                try writer.print("  {} × {}\n", .{ pattern.count, pattern });
            }
        }
        
        if (self.patterns_3.len > 0) {
            try writer.writeAll("\nTop 3-opcode patterns:\n");
            for (self.patterns_3) |pattern| {
                try writer.print("  {} × {}\n", .{ pattern.count, pattern });
            }
        }
        
        if (self.patterns_4.len > 0) {
            try writer.writeAll("\nTop 4-opcode patterns:\n");
            for (self.patterns_4) |pattern| {
                try writer.print("  {} × {}\n", .{ pattern.count, pattern });
            }
        }
        
        if (self.patterns_5_plus.len > 0) {
            try writer.writeAll("\nTop 5-opcode patterns:\n");
            for (self.patterns_5_plus) |pattern| {
                try writer.print("  {} × {}\n", .{ pattern.count, pattern });
            }
        }
        
        try writer.print("\nContract type: {s}\n", .{if (self.is_create_code) "Create/Deploy code" else "Runtime code"});
        try writer.writeAll("======================\n");
        
        return try list.toOwnedSlice(allocator);
    }
};

test "BytecodeStats formatStats basic functionality" {
    const allocator = std.testing.allocator;
    
    // Create mock statistics data
    var opcode_counts = [_]u32{0} ** 256;
    opcode_counts[@intFromEnum(Opcode.PUSH1)] = 3;
    opcode_counts[@intFromEnum(Opcode.ADD)] = 2;
    opcode_counts[@intFromEnum(Opcode.STOP)] = 1;
    
    const push_values = [_]BytecodeStats.PushValue{
        .{ .pc = 0, .value = 0x42 },
        .{ .pc = 5, .value = 0x1337 },
    };
    
    const fusions = [_]BytecodeStats.Fusion{
        .{ .pc = 0, .second_opcode = Opcode.ADD },
        .{ .pc = 5, .second_opcode = Opcode.JUMP },
    };
    
    const jumpdests = [_]usize{ 10, 20, 30 };
    
    const jumps = [_]BytecodeStats.Jump{
        .{ .pc = 2, .target = 10 },
        .{ .pc = 7, .target = 20 },
    };
    
    const stats = BytecodeStats{
        .opcode_counts = opcode_counts,
        .push_values = &push_values,
        .potential_fusions = &fusions,
        .jumpdests = &jumpdests,
        .jumps = &jumps,
        .backwards_jumps = 0,
        .is_create_code = false,
    };
    
    const output = try stats.formatStats(allocator);
    defer allocator.free(output);
    
    // Verify key sections are present
    try std.testing.expect(std.mem.indexOf(u8, output, "=== Bytecode Statistics ===") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Opcode counts:") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "PUSH1: 3") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "ADD: 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "STOP: 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Total opcodes: 6") != null);
    
    // Verify push values section
    try std.testing.expect(std.mem.indexOf(u8, output, "Push values (2 total):") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "PC 0: 0x42") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "PC 5: 0x1337") != null);
    
    // Verify fusion section
    try std.testing.expect(std.mem.indexOf(u8, output, "Potential fusions (2 total):") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "PC 0: PUSH + ADD") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "PC 5: PUSH + JUMP") != null);
    
    // Verify jumpdests section
    try std.testing.expect(std.mem.indexOf(u8, output, "Jump destinations (3 total):") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "PC 10") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "PC 20") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "PC 30") != null);
    
    // Verify jumps section
    try std.testing.expect(std.mem.indexOf(u8, output, "Jumps (2 total, 0 backwards):") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "PC 2 ↓ target 0xa") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "PC 7 ↓ target 0x14") != null);
    
    // Verify contract type
    try std.testing.expect(std.mem.indexOf(u8, output, "Contract type: Runtime code") != null);
}

test "BytecodeStats formatStats empty statistics" {
    const allocator = std.testing.allocator;
    
    const opcode_counts = [_]u32{0} ** 256;
    const stats = BytecodeStats{
        .opcode_counts = opcode_counts,
        .push_values = &.{},
        .potential_fusions = &.{},
        .jumpdests = &.{},
        .jumps = &.{},
        .backwards_jumps = 0,
        .is_create_code = false,
    };
    
    const output = try stats.formatStats(allocator);
    defer allocator.free(output);
    
    // Should still have basic structure
    try std.testing.expect(std.mem.indexOf(u8, output, "=== Bytecode Statistics ===") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Total opcodes: 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Contract type: Runtime code") != null);
    
    // Should not have sections for empty data
    try std.testing.expect(std.mem.indexOf(u8, output, "Push values") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Potential fusions") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Jump destinations") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Jumps") == null);
}

test "BytecodeStats formatStats create code detection" {
    const allocator = std.testing.allocator;
    
    var opcode_counts = [_]u32{0} ** 256;
    opcode_counts[@intFromEnum(Opcode.CODECOPY)] = 1;
    
    const stats = BytecodeStats{
        .opcode_counts = opcode_counts,
        .push_values = &.{},
        .potential_fusions = &.{},
        .jumpdests = &.{},
        .jumps = &.{},
        .backwards_jumps = 0,
        .is_create_code = true,
    };
    
    const output = try stats.formatStats(allocator);
    defer allocator.free(output);
    
    try std.testing.expect(std.mem.indexOf(u8, output, "Contract type: Create/Deploy code") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "CODECOPY: 1") != null);
}

test "BytecodeStats formatStats backwards jumps" {
    const allocator = std.testing.allocator;
    
    const opcode_counts = [_]u32{0} ** 256;
    const jumps = [_]BytecodeStats.Jump{
        .{ .pc = 10, .target = 5 },  // Backwards jump
        .{ .pc = 15, .target = 20 }, // Forward jump
        .{ .pc = 25, .target = 8 },  // Backwards jump
    };
    
    const stats = BytecodeStats{
        .opcode_counts = opcode_counts,
        .push_values = &.{},
        .potential_fusions = &.{},
        .jumpdests = &.{},
        .jumps = &jumps,
        .backwards_jumps = 2,
        .is_create_code = false,
    };
    
    const output = try stats.formatStats(allocator);
    defer allocator.free(output);
    
    // Verify backwards jump detection
    try std.testing.expect(std.mem.indexOf(u8, output, "Jumps (3 total, 2 backwards):") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "PC 10 ↑ target 0x5") != null);  // Backwards (↑)
    try std.testing.expect(std.mem.indexOf(u8, output, "PC 15 ↓ target 0x14") != null); // Forward (↓)
    try std.testing.expect(std.mem.indexOf(u8, output, "PC 25 ↑ target 0x8") != null);  // Backwards (↑)
}

test "BytecodeStats formatStats large values" {
    const allocator = std.testing.allocator;
    
    var opcode_counts = [_]u32{0} ** 256;
    opcode_counts[@intFromEnum(Opcode.PUSH32)] = 999999;
    
    const push_values = [_]BytecodeStats.PushValue{
        .{ .pc = 0, .value = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF }, // Max u256
    };
    
    const jumps = [_]BytecodeStats.Jump{
        .{ .pc = 100000, .target = 0xDEADBEEFCAFEBABE },
    };
    
    const stats = BytecodeStats{
        .opcode_counts = opcode_counts,
        .push_values = &push_values,
        .potential_fusions = &.{},
        .jumpdests = &.{},
        .jumps = &jumps,
        .backwards_jumps = 0,
        .is_create_code = false,
    };
    
    const output = try stats.formatStats(allocator);
    defer allocator.free(output);
    
    // Verify large numbers are formatted correctly
    try std.testing.expect(std.mem.indexOf(u8, output, "PUSH32: 999999") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Total opcodes: 999999") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "PC 0: 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "PC 100000 ↓ target 0xdeadbeefcafebabe") != null);
}

test "BytecodeStats formatStats all fusion types" {
    const allocator = std.testing.allocator;
    
    const opcode_counts = [_]u32{0} ** 256;
    const fusions = [_]BytecodeStats.Fusion{
        .{ .pc = 0, .second_opcode = Opcode.ADD },
        .{ .pc = 3, .second_opcode = Opcode.SUB },
        .{ .pc = 6, .second_opcode = Opcode.MUL },
        .{ .pc = 9, .second_opcode = Opcode.DIV },
        .{ .pc = 12, .second_opcode = Opcode.JUMP },
        .{ .pc = 15, .second_opcode = Opcode.JUMPI },
    };
    
    const stats = BytecodeStats{
        .opcode_counts = opcode_counts,
        .push_values = &.{},
        .potential_fusions = &fusions,
        .jumpdests = &.{},
        .jumps = &.{},
        .backwards_jumps = 0,
        .is_create_code = false,
    };
    
    const output = try stats.formatStats(allocator);
    defer allocator.free(output);
    
    // Verify all fusion types are present
    try std.testing.expect(std.mem.indexOf(u8, output, "Potential fusions (6 total):") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "PC 0: PUSH + ADD") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "PC 3: PUSH + SUB") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "PC 6: PUSH + MUL") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "PC 9: PUSH + DIV") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "PC 12: PUSH + JUMP") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "PC 15: PUSH + JUMPI") != null);
}

test "BytecodeStats formatStats invalid opcode handling" {
    const allocator = std.testing.allocator;
    
    var opcode_counts = [_]u32{0} ** 256;
    opcode_counts[0xFE] = 1; // Invalid opcode
    opcode_counts[0xFF] = 2; // Invalid opcode
    
    const stats = BytecodeStats{
        .opcode_counts = opcode_counts,
        .push_values = &.{},
        .potential_fusions = &.{},
        .jumpdests = &.{},
        .jumps = &.{},
        .backwards_jumps = 0,
        .is_create_code = false,
    };
    
    const output = try stats.formatStats(allocator);
    defer allocator.free(output);
    
    // Verify invalid opcodes are shown with hex notation
    try std.testing.expect(std.mem.indexOf(u8, output, "UNKNOWN(0xfe): 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "UNKNOWN(0xff): 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Total opcodes: 3") != null);
}

test "BytecodeStats analyze - basic functionality" {
    const allocator = std.testing.allocator;
    const bytecode = [_]u8{
        @intFromEnum(Opcode.PUSH1), 0x10, // pc=0, value=0x10
        @intFromEnum(Opcode.ADD),         // pc=2
        @intFromEnum(Opcode.PUSH2), 0x12, 0x34, // pc=3, value=0x1234  
        @intFromEnum(Opcode.MUL),         // pc=6
        @intFromEnum(Opcode.JUMPDEST),    // pc=7
        @intFromEnum(Opcode.STOP),        // pc=8
    };
    
    var stats = try BytecodeStats.analyze(allocator, &bytecode);
    defer stats.deinit(allocator);
    
    // Test opcode counts
    try std.testing.expectEqual(@as(u32, 2), stats.opcode_counts[@intFromEnum(Opcode.PUSH1)]);
    try std.testing.expectEqual(@as(u32, 1), stats.opcode_counts[@intFromEnum(Opcode.ADD)]);
    try std.testing.expectEqual(@as(u32, 1), stats.opcode_counts[@intFromEnum(Opcode.PUSH2)]);
    try std.testing.expectEqual(@as(u32, 1), stats.opcode_counts[@intFromEnum(Opcode.MUL)]);
    try std.testing.expectEqual(@as(u32, 1), stats.opcode_counts[@intFromEnum(Opcode.JUMPDEST)]);
    try std.testing.expectEqual(@as(u32, 1), stats.opcode_counts[@intFromEnum(Opcode.STOP)]);
    
    // Test push values
    try std.testing.expectEqual(@as(usize, 2), stats.push_values.len);
    try std.testing.expectEqual(@as(usize, 0), stats.push_values[0].pc);
    try std.testing.expectEqual(@as(u256, 0x10), stats.push_values[0].value);
    try std.testing.expectEqual(@as(usize, 3), stats.push_values[1].pc);
    try std.testing.expectEqual(@as(u256, 0x1234), stats.push_values[1].value);
    
    // Test potential fusions
    try std.testing.expectEqual(@as(usize, 2), stats.potential_fusions.len);
    try std.testing.expectEqual(@as(usize, 0), stats.potential_fusions[0].pc);
    try std.testing.expectEqual(Opcode.ADD, stats.potential_fusions[0].second_opcode);
    try std.testing.expectEqual(@as(usize, 3), stats.potential_fusions[1].pc);
    try std.testing.expectEqual(Opcode.MUL, stats.potential_fusions[1].second_opcode);
    
    // Test JUMPDEST detection
    try std.testing.expectEqual(@as(usize, 1), stats.jumpdests.len);
    try std.testing.expectEqual(@as(usize, 7), stats.jumpdests[0]);
}

test "BytecodeStats analyze - empty bytecode" {
    const allocator = std.testing.allocator;
    const bytecode: []const u8 = &.{};
    
    var stats = try BytecodeStats.analyze(allocator, bytecode);
    defer stats.deinit(allocator);
    
    // All arrays should be empty
    try std.testing.expectEqual(@as(usize, 0), stats.push_values.len);
    try std.testing.expectEqual(@as(usize, 0), stats.potential_fusions.len);
    try std.testing.expectEqual(@as(usize, 0), stats.jumpdests.len);
    try std.testing.expectEqual(@as(usize, 0), stats.jumps.len);
    try std.testing.expectEqual(@as(usize, 0), stats.backwards_jumps);
    
    // All opcode counts should be zero
    for (stats.opcode_counts) |count| {
        try std.testing.expectEqual(@as(u32, 0), count);
    }
}

test "BytecodeStats analyze - push value extraction" {
    const allocator = std.testing.allocator;
    const bytecode = [_]u8{
        @intFromEnum(Opcode.PUSH1), 0xFF,         // 1-byte push
        @intFromEnum(Opcode.PUSH2), 0x12, 0x34,   // 2-byte push
        @intFromEnum(Opcode.PUSH4), 0xDE, 0xAD, 0xBE, 0xEF, // 4-byte push
        @intFromEnum(Opcode.PUSH8), 0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF, // 8-byte push
    };
    
    var stats = try BytecodeStats.analyze(allocator, &bytecode);
    defer stats.deinit(allocator);
    
    try std.testing.expectEqual(@as(usize, 4), stats.push_values.len);
    
    // Test PUSH1
    try std.testing.expectEqual(@as(usize, 0), stats.push_values[0].pc);
    try std.testing.expectEqual(@as(u256, 0xFF), stats.push_values[0].value);
    
    // Test PUSH2 
    try std.testing.expectEqual(@as(usize, 2), stats.push_values[1].pc);
    try std.testing.expectEqual(@as(u256, 0x1234), stats.push_values[1].value);
    
    // Test PUSH4
    try std.testing.expectEqual(@as(usize, 5), stats.push_values[2].pc);
    try std.testing.expectEqual(@as(u256, 0xDEADBEEF), stats.push_values[2].value);
    
    // Test PUSH8
    try std.testing.expectEqual(@as(usize, 10), stats.push_values[3].pc);
    try std.testing.expectEqual(@as(u256, 0x0123456789ABCDEF), stats.push_values[3].value);
}

test "BytecodeStats analyze - jump detection and backwards jumps" {
    const allocator = std.testing.allocator;
    const bytecode = [_]u8{
        @intFromEnum(Opcode.JUMPDEST),    // pc=0
        @intFromEnum(Opcode.PUSH1), 0x08, // pc=1, target=8
        @intFromEnum(Opcode.JUMP),        // pc=3, forward jump
        @intFromEnum(Opcode.PUSH1), 0x00, // pc=4, target=0  
        @intFromEnum(Opcode.JUMP),        // pc=6, backward jump
        @intFromEnum(Opcode.JUMPDEST),    // pc=7
        @intFromEnum(Opcode.JUMPDEST),    // pc=8
        @intFromEnum(Opcode.STOP),        // pc=9
    };
    
    var stats = try BytecodeStats.analyze(allocator, &bytecode);
    defer stats.deinit(allocator);
    
    // Test JUMPDEST detection
    try std.testing.expectEqual(@as(usize, 3), stats.jumpdests.len);
    try std.testing.expectEqual(@as(usize, 0), stats.jumpdests[0]);
    try std.testing.expectEqual(@as(usize, 7), stats.jumpdests[1]);
    try std.testing.expectEqual(@as(usize, 8), stats.jumpdests[2]);
    
    // Test jump detection
    try std.testing.expectEqual(@as(usize, 2), stats.jumps.len);
    
    // First jump: forward (pc=3, target=8)
    try std.testing.expectEqual(@as(usize, 3), stats.jumps[0].pc);
    try std.testing.expectEqual(@as(u256, 8), stats.jumps[0].target);
    
    // Second jump: backward (pc=6, target=0)
    try std.testing.expectEqual(@as(usize, 6), stats.jumps[1].pc);
    try std.testing.expectEqual(@as(u256, 0), stats.jumps[1].target);
    
    // Test backwards jump counting
    try std.testing.expectEqual(@as(usize, 1), stats.backwards_jumps);
}

test "BytecodeStats analyze - jumpi detection" {
    const allocator = std.testing.allocator;
    const bytecode = [_]u8{
        @intFromEnum(Opcode.PUSH1), 0x05, // pc=0, target=5
        @intFromEnum(Opcode.JUMPI),       // pc=2
        @intFromEnum(Opcode.STOP),        // pc=3
        @intFromEnum(Opcode.JUMPDEST),    // pc=4
        @intFromEnum(Opcode.JUMPDEST),    // pc=5
    };
    
    var stats = try BytecodeStats.analyze(allocator, &bytecode);
    defer stats.deinit(allocator);
    
    // Test JUMPI detection
    try std.testing.expectEqual(@as(usize, 1), stats.jumps.len);
    try std.testing.expectEqual(@as(usize, 2), stats.jumps[0].pc);
    try std.testing.expectEqual(@as(u256, 5), stats.jumps[0].target);
}

test "BytecodeStats analyze - fusion pattern detection" {
    const allocator = std.testing.allocator;
    const bytecode = [_]u8{
        // Test all fusion patterns
        @intFromEnum(Opcode.PUSH1), 0x10, @intFromEnum(Opcode.ADD),  // ADD fusion
        @intFromEnum(Opcode.PUSH1), 0x20, @intFromEnum(Opcode.MUL),  // MUL fusion
        @intFromEnum(Opcode.PUSH1), 0x30, @intFromEnum(Opcode.SUB),  // SUB fusion
        @intFromEnum(Opcode.PUSH1), 0x40, @intFromEnum(Opcode.DIV),  // DIV fusion
        @intFromEnum(Opcode.PUSH1), 0x50, @intFromEnum(Opcode.JUMP), // JUMP fusion
        @intFromEnum(Opcode.PUSH1), 0x60, @intFromEnum(Opcode.JUMPI), // JUMPI fusion
        @intFromEnum(Opcode.PUSH1), 0x70, @intFromEnum(Opcode.GT),   // GT fusion
        @intFromEnum(Opcode.PUSH1), 0x80, @intFromEnum(Opcode.LT),   // LT fusion
        @intFromEnum(Opcode.PUSH1), 0x90, @intFromEnum(Opcode.EQ),   // EQ fusion
        // Non-fusion pattern
        @intFromEnum(Opcode.PUSH1), 0xA0, @intFromEnum(Opcode.POP),  // Should not fuse
    };
    
    var stats = try BytecodeStats.analyze(allocator, &bytecode);
    defer stats.deinit(allocator);
    
    // Should detect 9 fusion patterns (all except the last POP)
    try std.testing.expectEqual(@as(usize, 9), stats.potential_fusions.len);
    
    const expected_opcodes = [_]Opcode{
        Opcode.ADD, Opcode.MUL, Opcode.SUB, Opcode.DIV, Opcode.JUMP,
        Opcode.JUMPI, Opcode.GT, Opcode.LT, Opcode.EQ
    };
    
    for (stats.potential_fusions, expected_opcodes, 0..) |fusion, expected_opcode, i| {
        try std.testing.expectEqual(@as(usize, i * 3), fusion.pc); // Each pattern is 3 bytes
        try std.testing.expectEqual(expected_opcode, fusion.second_opcode);
    }
}

test "BytecodeStats analyze - invalid opcodes handling" {
    const allocator = std.testing.allocator;
    const bytecode = [_]u8{
        @intFromEnum(Opcode.PUSH1), 0x42,
        0xFE, // Invalid opcode
        0xFF, // Invalid opcode  
        @intFromEnum(Opcode.STOP),
    };
    
    var stats = try BytecodeStats.analyze(allocator, &bytecode);
    defer stats.deinit(allocator);
    
    // Valid opcodes should be counted
    try std.testing.expectEqual(@as(u32, 1), stats.opcode_counts[@intFromEnum(Opcode.PUSH1)]);
    try std.testing.expectEqual(@as(u32, 1), stats.opcode_counts[@intFromEnum(Opcode.STOP)]);
    
    // Invalid opcodes should also be counted
    try std.testing.expectEqual(@as(u32, 1), stats.opcode_counts[0xFE]);
    try std.testing.expectEqual(@as(u32, 1), stats.opcode_counts[0xFF]);
    
    // Push value should still be detected
    try std.testing.expectEqual(@as(usize, 1), stats.push_values.len);
    try std.testing.expectEqual(@as(u256, 0x42), stats.push_values[0].value);
}

test "BytecodeStats analyze - truncated push instructions" {
    const allocator = std.testing.allocator;
    const bytecode = [_]u8{
        @intFromEnum(Opcode.PUSH2), 0x12, // Missing second byte
        @intFromEnum(Opcode.PUSH4), 0x01, 0x02, // Missing two bytes
    };
    
    var stats = try BytecodeStats.analyze(allocator, &bytecode);
    defer stats.deinit(allocator);
    
    // Should still count the PUSH opcodes
    try std.testing.expectEqual(@as(u32, 1), stats.opcode_counts[@intFromEnum(Opcode.PUSH2)]);
    try std.testing.expectEqual(@as(u32, 1), stats.opcode_counts[@intFromEnum(Opcode.PUSH4)]);
    
    // Should extract partial values
    try std.testing.expectEqual(@as(usize, 2), stats.push_values.len);
    try std.testing.expectEqual(@as(u256, 0x12), stats.push_values[0].value); // Only got one byte
    try std.testing.expectEqual(@as(u256, 0x0102), stats.push_values[1].value); // Only got two bytes
}

test "BytecodeStats analyze - push32 maximum value" {
    const allocator = std.testing.allocator;
    var bytecode: [33]u8 = undefined;
    bytecode[0] = @intFromEnum(Opcode.PUSH32);
    for (1..33) |i| {
        bytecode[i] = 0xFF; // Maximum value
    }
    
    var stats = try BytecodeStats.analyze(allocator, &bytecode);
    defer stats.deinit(allocator);
    
    try std.testing.expectEqual(@as(usize, 1), stats.push_values.len);
    try std.testing.expectEqual(@as(u256, std.math.maxInt(u256)), stats.push_values[0].value);
}

test "BytecodeStats analyze - complex jump pattern" {
    const allocator = std.testing.allocator;
    const bytecode = [_]u8{
        @intFromEnum(Opcode.PUSH2), 0x00, 0x10, // Target 0x0010 = 16
        @intFromEnum(Opcode.JUMP),              // pc=3
        @intFromEnum(Opcode.PUSH1), 0x00,       // Target 0x00 = 0
        @intFromEnum(Opcode.PUSH1), 0x20,       // Target 0x20 = 32  
        @intFromEnum(Opcode.JUMPI),             // pc=7
        @intFromEnum(Opcode.JUMPDEST),          // pc=8 (not targeted)
        @intFromEnum(Opcode.PUSH1), 0x08,       // Target 0x08 = 8
        @intFromEnum(Opcode.JUMP),              // pc=11 (backwards to 8)
        @intFromEnum(Opcode.JUMPDEST),          // pc=12
        @intFromEnum(Opcode.JUMPDEST),          // pc=13
        @intFromEnum(Opcode.JUMPDEST),          // pc=14
        @intFromEnum(Opcode.JUMPDEST),          // pc=15
        @intFromEnum(Opcode.JUMPDEST),          // pc=16
    };
    
    var stats = try BytecodeStats.analyze(allocator, &bytecode);
    defer stats.deinit(allocator);
    
    // Should detect 3 jumps
    try std.testing.expectEqual(@as(usize, 3), stats.jumps.len);
    
    // First jump: forward to 16
    try std.testing.expectEqual(@as(usize, 3), stats.jumps[0].pc);
    try std.testing.expectEqual(@as(u256, 16), stats.jumps[0].target);
    
    // Second jump: forward to 32 (JUMPI)
    try std.testing.expectEqual(@as(usize, 7), stats.jumps[1].pc);
    try std.testing.expectEqual(@as(u256, 32), stats.jumps[1].target);
    
    // Third jump: backward to 8
    try std.testing.expectEqual(@as(usize, 11), stats.jumps[2].pc);
    try std.testing.expectEqual(@as(u256, 8), stats.jumps[2].target);
    
    // One backwards jump
    try std.testing.expectEqual(@as(usize, 1), stats.backwards_jumps);
}

test "BytecodeStats analyze - no jump target found" {
    const allocator = std.testing.allocator;
    const bytecode = [_]u8{
        @intFromEnum(Opcode.ADD),  // No PUSH before
        @intFromEnum(Opcode.JUMP), // Should not be detected
        @intFromEnum(Opcode.MUL),
        @intFromEnum(Opcode.JUMPI), // Should not be detected
    };
    
    var stats = try BytecodeStats.analyze(allocator, &bytecode);
    defer stats.deinit(allocator);
    
    // No jumps should be detected
    try std.testing.expectEqual(@as(usize, 0), stats.jumps.len);
    try std.testing.expectEqual(@as(usize, 0), stats.backwards_jumps);
}

test "BytecodeStats analyze - distant push target" {
    const allocator = std.testing.allocator;
    var bytecode: [50]u8 = undefined;
    
    // Fill with NOPs to create distance
    for (0..40) |i| {
        bytecode[i] = @intFromEnum(Opcode.STOP); // Use STOP as filler
    }
    
    // Add a distant PUSH followed by JUMP  
    bytecode[40] = @intFromEnum(Opcode.PUSH1);
    bytecode[41] = 0x30; // Target 48
    bytecode[42] = @intFromEnum(Opcode.JUMP);
    
    // Add more filler
    bytecode[43] = @intFromEnum(Opcode.STOP);
    bytecode[44] = @intFromEnum(Opcode.STOP);
    bytecode[45] = @intFromEnum(Opcode.STOP);
    bytecode[46] = @intFromEnum(Opcode.STOP);
    bytecode[47] = @intFromEnum(Opcode.STOP);
    bytecode[48] = @intFromEnum(Opcode.JUMPDEST);
    bytecode[49] = @intFromEnum(Opcode.STOP);
    
    var stats = try BytecodeStats.analyze(allocator, &bytecode);
    defer stats.deinit(allocator);
    
    // Should detect the jump
    try std.testing.expectEqual(@as(usize, 1), stats.jumps.len);
    try std.testing.expectEqual(@as(usize, 42), stats.jumps[0].pc);
    try std.testing.expectEqual(@as(u256, 48), stats.jumps[0].target);
}

test "BytecodeStats analyze - pattern tracking" {
    const allocator = std.testing.allocator;
    const bytecode = [_]u8{
        // Pattern: PUSH1, DUP1, PUSH1, DUP1 (repeated pattern)
        @intFromEnum(Opcode.PUSH1), 0x01,
        @intFromEnum(Opcode.DUP1),
        @intFromEnum(Opcode.PUSH1), 0x02,
        @intFromEnum(Opcode.DUP1),
        @intFromEnum(Opcode.PUSH1), 0x03,
        @intFromEnum(Opcode.DUP1),
        // Add some other opcodes
        @intFromEnum(Opcode.ADD),
        @intFromEnum(Opcode.MUL),
        @intFromEnum(Opcode.SUB),
        @intFromEnum(Opcode.ADD),
        @intFromEnum(Opcode.MUL),
        @intFromEnum(Opcode.SUB),
    };
    
    var stats = try BytecodeStats.analyze(allocator, &bytecode);
    defer stats.deinit(allocator);
    
    // Check 2-opcode patterns
    try std.testing.expect(stats.patterns_2.len > 0);
    // Most common 2-pattern should be PUSH1, DUP1
    try std.testing.expectEqual(@intFromEnum(Opcode.PUSH1), stats.patterns_2[0].opcodes[0]);
    try std.testing.expectEqual(@intFromEnum(Opcode.DUP1), stats.patterns_2[0].opcodes[1]);
    try std.testing.expectEqual(@as(u32, 3), stats.patterns_2[0].count);
    
    // Check 3-opcode patterns
    try std.testing.expect(stats.patterns_3.len > 0);
    // Most common 3-pattern should be DUP1, PUSH1, DUP1
    try std.testing.expectEqual(@intFromEnum(Opcode.DUP1), stats.patterns_3[0].opcodes[0]);
    try std.testing.expectEqual(@intFromEnum(Opcode.PUSH1), stats.patterns_3[0].opcodes[1]);
    try std.testing.expectEqual(@intFromEnum(Opcode.DUP1), stats.patterns_3[0].opcodes[2]);
    try std.testing.expectEqual(@as(u32, 2), stats.patterns_3[0].count);
}

test "BytecodeStats deinit memory management" {
    const allocator = std.testing.allocator;
    const bytecode = [_]u8{
        @intFromEnum(Opcode.PUSH1), 0x42,
        @intFromEnum(Opcode.ADD),
        @intFromEnum(Opcode.JUMPDEST),
        @intFromEnum(Opcode.PUSH1), 0x03,
        @intFromEnum(Opcode.JUMP),
    };
    
    var stats = try BytecodeStats.analyze(allocator, &bytecode);
    
    // Verify we have some data to cleanup
    try std.testing.expect(stats.push_values.len > 0);
    try std.testing.expect(stats.potential_fusions.len > 0);
    try std.testing.expect(stats.jumpdests.len > 0);
    try std.testing.expect(stats.jumps.len > 0);
    
    // This should not leak memory
    stats.deinit(allocator);
}

