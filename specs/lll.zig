//! Minimal LLL compiler for state-test fillers whose contract code uses LLL
//! definitions and control flow (`def`, `for`, `while`, `if`, `when`, `unless`)
//! that the legacy assembler in assembler.zig rejects.
//!
//! Syntax: `(op args...)`, `{ ... }` = seq, `[x] e` = MSTORE, `[[x]] e` = SSTORE,
//! `@x` = MLOAD, `@@x` = SLOAD, `'name` = symbol, numbers in decimal or 0x hex.
//! As in LLL, `seq` pops every value but the last one, and control-flow bodies
//! leave nothing on the stack. Jump targets are PUSH2 immediates.
const std = @import("std");

const Node = union(enum) {
    atom: []const u8,
    quote: []const u8,
    list: []Node,
};

const Parser = struct {
    arena: std.mem.Allocator,
    text: []const u8,
    pos: usize = 0,

    fn skipSpace(self: *Parser) void {
        while (self.pos < self.text.len) {
            const c = self.text[self.pos];
            if (std.ascii.isWhitespace(c)) {
                self.pos += 1;
            } else if (c == ';') {
                while (self.pos < self.text.len and self.text[self.pos] != '\n') self.pos += 1;
            } else return;
        }
    }

    fn peek(self: *Parser) ?u8 {
        self.skipSpace();
        return if (self.pos < self.text.len) self.text[self.pos] else null;
    }

    fn list(self: *Parser, head: []const Node, items: []const Node) ![]Node {
        const out = try self.arena.alloc(Node, head.len + items.len);
        @memcpy(out[0..head.len], head);
        @memcpy(out[head.len..], items);
        return out;
    }

    /// Parse nodes until the closing character `close`, which is consumed.
    fn until(self: *Parser, close: u8) ![]Node {
        var items = std.ArrayList(Node){};
        while (true) {
            const c = self.peek() orelse return error.InvalidFormat;
            if (c == close) {
                self.pos += 1;
                return items.toOwnedSlice(self.arena);
            }
            try items.append(self.arena, try self.node());
        }
    }

    fn node(self: *Parser) error{ InvalidFormat, OutOfMemory }!Node {
        const c = self.peek() orelse return error.InvalidFormat;
        switch (c) {
            '(' => {
                self.pos += 1;
                return .{ .list = try self.until(')') };
            },
            '{' => {
                self.pos += 1;
                return .{ .list = try self.list(&.{.{ .atom = "seq" }}, try self.until('}')) };
            },
            '[' => {
                self.pos += 1;
                const storage = self.pos < self.text.len and self.text[self.pos] == '[';
                if (storage) self.pos += 1;
                const key = try self.until(']');
                if (key.len != 1) return error.InvalidFormat;
                if (storage) {
                    if (self.pos >= self.text.len or self.text[self.pos] != ']') return error.InvalidFormat;
                    self.pos += 1;
                }
                const value = try self.node();
                const op: []const u8 = if (storage) "SSTORE" else "MSTORE";
                return .{ .list = try self.list(&.{ .{ .atom = op }, key[0], value }, &.{}) };
            },
            '@' => {
                self.pos += 1;
                const storage = self.pos < self.text.len and self.text[self.pos] == '@';
                if (storage) self.pos += 1;
                const op: []const u8 = if (storage) "SLOAD" else "MLOAD";
                return .{ .list = try self.list(&.{ .{ .atom = op }, try self.node() }, &.{}) };
            },
            '\'' => {
                self.pos += 1;
                return .{ .quote = self.word() orelse return error.InvalidFormat };
            },
            ')', '}', ']' => return error.InvalidFormat,
            else => return .{ .atom = self.word() orelse return error.InvalidFormat },
        }
    }

    fn word(self: *Parser) ?[]const u8 {
        const start = self.pos;
        while (self.pos < self.text.len) : (self.pos += 1) {
            const c = self.text[self.pos];
            if (std.ascii.isWhitespace(c) or std.mem.indexOfScalar(u8, "()[]{}@';", c) != null) break;
        }
        return if (self.pos > start) self.text[start..self.pos] else null;
    }
};

const JUMPDEST = 0x5b;
const JUMP = 0x56;
const JUMPI = 0x57;
const ISZERO = 0x15;
const POP = 0x50;
const PUSH2 = 0x61;

fn Compiler(comptime opcodeOf: fn ([]const u8) anyerror!u8) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        code: std.ArrayList(u8) = .{},
        defs: std.StringHashMap(Node),

        fn emit(self: *Self, byte: u8) !void {
            try self.code.append(self.allocator, byte);
        }

        fn label(self: *Self) !u16 {
            const at = std.math.cast(u16, self.code.items.len) orelse return error.InvalidFormat;
            try self.emit(JUMPDEST);
            return at;
        }

        /// Emit PUSH2 with a placeholder target and return the immediate's offset.
        fn pushTarget(self: *Self) !usize {
            try self.emit(PUSH2);
            const at = self.code.items.len;
            try self.code.appendSlice(self.allocator, &.{ 0, 0 });
            return at;
        }

        fn patch(self: *Self, at: usize, target: u16) void {
            std.mem.writeInt(u16, self.code.items[at..][0..2], target, .big);
        }

        fn pushValue(self: *Self, word: u256) !void {
            var bytes: [32]u8 = undefined;
            std.mem.writeInt(u256, &bytes, word, .big);
            const skip: u8 = @intCast(@min(@as(u16, @clz(word)) / 8, 31));
            try self.emit(0x60 + (31 - skip));
            try self.code.appendSlice(self.allocator, bytes[skip..]);
        }

        /// Compile and drop any value left on the stack.
        fn statement(self: *Self, node: Node) anyerror!void {
            if (try self.expr(node) == 1) try self.emit(POP);
        }

        /// Compile an expression that must leave exactly one value.
        fn value(self: *Self, node: Node) anyerror!void {
            if (try self.expr(node) != 1) return error.InvalidFormat;
        }

        /// Compile `node` and return how many values it leaves on the stack (0 or 1).
        fn expr(self: *Self, node: Node) anyerror!u1 {
            switch (node) {
                .quote => return error.InvalidFormat,
                .atom => |text| {
                    if (number(text)) |n| {
                        try self.pushValue(n);
                        return 1;
                    }
                    if (self.defs.get(text)) |definition| return self.expr(definition);
                    return self.opcode(text, &.{});
                },
                .list => |items| {
                    if (items.len == 0 or items[0] != .atom) return error.InvalidFormat;
                    const head = items[0].atom;
                    const args = items[1..];
                    if (std.mem.eql(u8, head, "seq")) {
                        for (args, 0..) |arg, i| {
                            if (i + 1 == args.len) return self.expr(arg);
                            try self.statement(arg);
                        }
                        return 0;
                    }
                    if (std.mem.eql(u8, head, "def")) {
                        if (args.len != 2 or args[0] != .quote) return error.InvalidFormat;
                        try self.defs.put(args[0].quote, args[1]);
                        return 0;
                    }
                    if (std.mem.eql(u8, head, "for")) {
                        if (args.len != 4) return error.InvalidFormat;
                        try self.statement(args[0]);
                        try self.loop(args[1], args[3], args[2]);
                        return 0;
                    }
                    if (std.mem.eql(u8, head, "while")) {
                        if (args.len != 2) return error.InvalidFormat;
                        try self.loop(args[0], args[1], null);
                        return 0;
                    }
                    if (std.mem.eql(u8, head, "when") or std.mem.eql(u8, head, "unless")) {
                        if (args.len != 2) return error.InvalidFormat;
                        try self.value(args[0]);
                        if (head[0] == 'w') try self.emit(ISZERO);
                        const end = try self.pushTarget();
                        try self.emit(JUMPI);
                        try self.statement(args[1]);
                        self.patch(end, try self.label());
                        return 0;
                    }
                    if (std.mem.eql(u8, head, "if")) {
                        if (args.len != 3) return error.InvalidFormat;
                        try self.value(args[0]);
                        try self.emit(ISZERO);
                        const otherwise = try self.pushTarget();
                        try self.emit(JUMPI);
                        const then_depth = try self.expr(args[1]);
                        const end = try self.pushTarget();
                        try self.emit(JUMP);
                        self.patch(otherwise, try self.label());
                        if (try self.expr(args[2]) != then_depth) return error.InvalidFormat;
                        self.patch(end, try self.label());
                        return then_depth;
                    }
                    return self.opcode(alias(head), args);
                },
            }
        }

        fn loop(self: *Self, condition: Node, body: Node, step: ?Node) !void {
            const top = try self.label();
            try self.value(condition);
            try self.emit(ISZERO);
            const end = try self.pushTarget();
            try self.emit(JUMPI);
            try self.statement(body);
            if (step) |s| try self.statement(s);
            try self.emit(PUSH2);
            try self.code.appendSlice(self.allocator, &.{ @intCast(top >> 8), @truncate(top) });
            try self.emit(JUMP);
            self.patch(end, try self.label());
        }

        fn opcode(self: *Self, name: []const u8, args: []const Node) !u1 {
            var upper: [32]u8 = undefined;
            if (name.len > upper.len) return error.UnknownOpcode;
            const op = try opcodeOf(std.ascii.upperString(upper[0..name.len], name));
            var i = args.len;
            while (i > 0) {
                i -= 1;
                try self.value(args[i]);
            }
            try self.emit(op);
            return outputs(op);
        }
    };
}

fn alias(name: []const u8) []const u8 {
    const table = [_][2][]const u8{
        .{ "<", "LT" },  .{ ">", "GT" },  .{ "+", "ADD" }, .{ "-", "SUB" },
        .{ "*", "MUL" }, .{ "/", "DIV" }, .{ "%", "MOD" }, .{ "=", "EQ" },
        .{ "!", "ISZERO" }, .{ "&", "AND" }, .{ "|", "OR" }, .{ "^", "XOR" },
    };
    for (table) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return entry[1];
    }
    return name;
}

/// Values an opcode leaves on the stack in LLL's usage (0 or 1).
fn outputs(op: u8) u1 {
    return switch (op) {
        0x00, 0x37, 0x39, 0x3c, 0x3e, 0x50, 0x52, 0x53, 0x55, 0x56, 0x57, 0x5b, 0x5d, 0x5e, 0xa0...0xa4, 0xf3, 0xfd, 0xfe, 0xff => 0,
        else => 1,
    };
}

fn number(text: []const u8) ?u256 {
    if (std.mem.startsWith(u8, text, "0x") or std.mem.startsWith(u8, text, "0X")) {
        return std.fmt.parseInt(u256, text[2..], 16) catch null;
    }
    return std.fmt.parseInt(u256, text, 10) catch null;
}

/// Compile the body of a `{ ... }` LLL program (the text inside the braces).
pub fn compileProgram(
    allocator: std.mem.Allocator,
    body: []const u8,
    comptime opcodeOf: fn ([]const u8) anyerror!u8,
) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var parser = Parser{ .arena = arena.allocator(), .text = body };
    var items = std.ArrayList(Node){};
    while (parser.peek() != null) try items.append(arena.allocator(), try parser.node());

    var compiler = Compiler(opcodeOf){ .allocator = allocator, .defs = std.StringHashMap(Node).init(arena.allocator()) };
    errdefer compiler.code.deinit(allocator);
    for (items.items) |item| try compiler.statement(item);
    return compiler.code.toOwnedSlice(allocator);
}

fn testOpcode(name: []const u8) anyerror!u8 {
    const table = [_]struct { []const u8, u8 }{
        .{ "LT", 0x10 },     .{ "ADD", 0x01 },         .{ "MLOAD", 0x51 },  .{ "MSTORE", 0x52 },
        .{ "SSTORE", 0x55 }, .{ "EXTCODESIZE", 0x3b }, .{ "SLOAD", 0x54 },  .{ "CALL", 0xf1 },
    };
    for (table) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return entry[1];
    }
    return error.UnknownOpcode;
}

test "lll: def, for, @x and [x] compile to a counted loop" {
    const code = try compileProgram(std.testing.allocator, "(def 'i 0x80) (for {} (< @i 3) [i](+ @i 1) (EXTCODESIZE 1))", testOpcode);
    defer std.testing.allocator.free(code);
    // top: JUMPDEST
    // cond (< @i 3): PUSH1 3, PUSH1 0x80, MLOAD, LT; ISZERO; PUSH2 end; JUMPI
    // body: PUSH1 1, EXTCODESIZE, POP
    // step [i](+ @i 1): PUSH1 1, PUSH1 0x80, MLOAD, ADD, PUSH1 0x80, MSTORE
    // PUSH2 top; JUMP; end: JUMPDEST
    const want = [_]u8{
        0x5b,
        0x60, 0x03, 0x60, 0x80, 0x51, 0x10, 0x15, 0x61, 0x00, 0x1d, 0x57,
        0x60, 0x01, 0x3b, 0x50,
        0x60, 0x01, 0x60, 0x80, 0x51, 0x01, 0x60, 0x80, 0x52,
        0x61, 0x00, 0x00, 0x56,
        0x5b,
    };
    try std.testing.expectEqualSlices(u8, &want, code);
}

test "lll: seq pops all but the last value, [[x]] stores, while loops" {
    const code = try compileProgram(std.testing.allocator, "(seq (CALL 1 2 0 0 0 0 0) (while 1 (SSTORE 0 1)))", testOpcode);
    defer std.testing.allocator.free(code);
    const want = [_]u8{
        0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x02, 0x60, 0x01, 0xf1, 0x50,
        0x5b, 0x60, 0x01, 0x15, 0x61, 0x00, 0x21, 0x57, // top at 16, end at 33
        0x60, 0x01, 0x60, 0x00, 0x55,
        0x61, 0x00, 0x10, 0x56,
        0x5b,
    };
    try std.testing.expectEqualSlices(u8, &want, code);
}

test "lll: unknown opcodes are rejected" {
    try std.testing.expectError(error.UnknownOpcode, compileProgram(std.testing.allocator, "(FROB 1)", testOpcode));
}
