const std = @import("std");

// Label tracking for [[n]] syntax
const LabelInfo = struct {
    position: usize,
    references: std.ArrayList(usize),
};

// Replace <contract:...> and <eoa:...> placeholders with hex addresses
fn replacePlaceholders(allocator: std.mem.Allocator, code: []const u8) ![]u8 {
    var result = std.ArrayList(u8){};
    defer result.deinit(allocator);

    var i: usize = 0;
    while (i < code.len) {
        if (code[i] == '<') {
            // Look for closing >
            if (std.mem.indexOfPos(u8, code, i, ">")) |end_idx| {
                const placeholder = code[i .. end_idx + 1];
                // Check if it's a contract or eoa placeholder
                if (std.mem.indexOf(u8, placeholder, "contract:") != null or
                    std.mem.indexOf(u8, placeholder, "eoa:") != null)
                {
                    // Extract the hex address (last occurrence of 0x)
                    if (std.mem.lastIndexOf(u8, placeholder, "0x")) |addr_start| {
                        const addr = placeholder[addr_start .. placeholder.len - 1]; // Remove trailing >
                        // Write "0x" + address
                        try result.appendSlice(allocator, addr);
                        i = end_idx + 1;
                        continue;
                    }
                }
            }
        }
        try result.append(allocator, code[i]);
        i += 1;
    }

    return result.toOwnedSlice(allocator);
}

// Simple assembler to compile basic assembly code for tests
pub fn compileAssembly(allocator: std.mem.Allocator, asm_code: []const u8) ![]u8 {
    // First, replace any <contract:...> or <eoa:...> placeholders
    const code_with_addresses = try replacePlaceholders(allocator, asm_code);
    defer allocator.free(code_with_addresses);

    var code: []const u8 = code_with_addresses;

    // Handle :asm prefix - simple assembly format
    if (std.mem.startsWith(u8, code, ":asm ")) {
        code = code[5..]; // Remove ":asm " prefix
        // :asm format is typically simple space-separated opcodes
        return compileSingleExpression(allocator, code);
    }

    // Handle :yul prefix - Yul assembly language
    // For now, we'll return an error since Yul is too complex to parse here
    // In the future, we could integrate a proper Yul compiler
    if (std.mem.startsWith(u8, code, ":yul ")) {
        // Yul has complex syntax with functions, if statements, etc.
        // Example: ":yul berlin { mstore8(0x1f, 0x42) calldatacopy(0x1f, 0, 0x0103) ... }"
        // This would require a full Yul parser/compiler
        return error.YulNotSupported;
    }

    // Handle { ... } format (may contain multiple expressions)
    if (std.mem.startsWith(u8, code, "{") and std.mem.endsWith(u8, code, "}")) {
        code = std.mem.trim(u8, code[1 .. code.len - 1], " \t\n\r");
        return compileComplexExpression(allocator, code);
    }

    // Remove (asm ... ) wrapper if present
    if (std.mem.startsWith(u8, code, "(asm ")) {
        code = code[5..];
        if (std.mem.endsWith(u8, code, ")")) {
            code = code[0 .. code.len - 1];
        }
    }

    return compileSingleExpression(allocator, code);
}

// LLL Expression - represents a parsed LLL s-expression
const LllExpr = union(enum) {
    opcode: []const u8,
    number: u256,
    list: []LllExpr,
    mload: u256, // Memory load @x

    fn deinit(self: *LllExpr, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .list => |items| {
                for (items) |*item| {
                    item.deinit(allocator);
                }
                allocator.free(items);
            },
            else => {},
        }
    }
};

// Parse LLL s-expression into structured form
fn parseLllExpression(allocator: std.mem.Allocator, code: []const u8) !LllExpr {
    var pos: usize = 0;

    // Skip whitespace
    while (pos < code.len and std.ascii.isWhitespace(code[pos])) : (pos += 1) {}
    if (pos >= code.len) return error.InvalidFormat;

    // Check if this is a list (starts with '(')
    if (code[pos] == '(') {
        pos += 1; // Skip '('
        var items = std.ArrayList(LllExpr){};
        errdefer {
            for (items.items) |*item| {
                item.deinit(allocator);
            }
            items.deinit(allocator);
        }

        while (pos < code.len) {
            // Skip whitespace
            while (pos < code.len and std.ascii.isWhitespace(code[pos])) : (pos += 1) {}
            if (pos >= code.len) return error.InvalidFormat;

            // Check for closing paren
            if (code[pos] == ')') {
                pos += 1;
                break;
            }

            // Parse nested expression
            const result = try parseLllExpressionAt(allocator, code, &pos);
            try items.append(allocator, result);
        }

        return LllExpr{ .list = try items.toOwnedSlice(allocator) };
    }

    // Otherwise parse atom (opcode or number)
    return parseLllAtom(code, &pos);
}

fn parseLllExpressionAt(allocator: std.mem.Allocator, code: []const u8, pos: *usize) !LllExpr {
    // Skip whitespace
    while (pos.* < code.len and std.ascii.isWhitespace(code[pos.*])) : (pos.* += 1) {}
    if (pos.* >= code.len) return error.InvalidFormat;

    // Check if this is a list
    if (code[pos.*] == '(') {
        pos.* += 1; // Skip '('
        var items = std.ArrayList(LllExpr){};
        errdefer {
            for (items.items) |*item| {
                item.deinit(allocator);
            }
            items.deinit(allocator);
        }

        while (pos.* < code.len) {
            // Skip whitespace
            while (pos.* < code.len and std.ascii.isWhitespace(code[pos.*])) : (pos.* += 1) {}
            if (pos.* >= code.len) return error.InvalidFormat;

            // Check for closing paren
            if (code[pos.*] == ')') {
                pos.* += 1;
                break;
            }

            // Parse nested expression
            const result = try parseLllExpressionAt(allocator, code, pos);
            try items.append(allocator, result);
        }

        return LllExpr{ .list = try items.toOwnedSlice(allocator) };
    }

    // Otherwise parse atom
    return parseLllAtom(code, pos);
}

fn parseLllAtom(code: []const u8, pos: *usize) !LllExpr {
    // Skip whitespace
    while (pos.* < code.len and std.ascii.isWhitespace(code[pos.*])) : (pos.* += 1) {}
    if (pos.* >= code.len) return error.InvalidFormat;

    // Check for memory reference @x
    if (code[pos.*] == '@') {
        pos.* += 1;
        const start = pos.*;

        // Find end of number/atom
        while (pos.* < code.len and
            !std.ascii.isWhitespace(code[pos.*]) and
            code[pos.*] != '(' and
            code[pos.*] != ')') : (pos.* += 1) {}

        const atom = code[start..pos.*];
        if (atom.len == 0) return error.InvalidFormat;

        // Parse the number/identifier
        const index = if (isNumber(atom)) try parseNumber(atom) else return error.InvalidFormat;

        // Return as mload variant
        return LllExpr{ .mload = index };
    }

    const start = pos.*;

    // Find end of atom (whitespace or paren)
    while (pos.* < code.len and
        !std.ascii.isWhitespace(code[pos.*]) and
        code[pos.*] != '(' and
        code[pos.*] != ')') : (pos.* += 1) {}

    const atom = code[start..pos.*];
    if (atom.len == 0) return error.InvalidFormat;

    // Try to parse as number
    if (isNumber(atom)) {
        const value = try parseNumber(atom);
        return LllExpr{ .number = value };
    }

    // Otherwise it's an opcode
    return LllExpr{ .opcode = atom };
}

// Compile LLL expression to bytecode (prefix -> postfix)
fn compileLllExpr(allocator: std.mem.Allocator, expr: LllExpr, labels: *std.StringHashMap(LabelInfo), current_pos: usize) ![]u8 {
    _ = labels;
    _ = current_pos;
    switch (expr) {
        .opcode => |name| {
            // Single opcode
            var bytecode = std.ArrayList(u8){};
            defer bytecode.deinit(allocator);
            const opcode = try getOpcode(name);
            try bytecode.append(allocator, opcode);
            return bytecode.toOwnedSlice(allocator);
        },
        .number => |value| {
            // Push the number
            return compilePushValue(allocator, value);
        },
        .mload => |index| {
            // @x compiles to: PUSH index, MLOAD
            var bytecode = std.ArrayList(u8){};
            defer bytecode.deinit(allocator);
            const push_bytes = try compilePushValue(allocator, index);
            defer allocator.free(push_bytes);
            try bytecode.appendSlice(allocator,push_bytes);
            try bytecode.append(allocator,0x51); // MLOAD
            return bytecode.toOwnedSlice(allocator);
        },
        .list => |items| {
            if (items.len == 0) return error.InvalidFormat;

            // Check for special forms
            const first = items[0];
            if (first == .opcode) {
                const op_name = first.opcode;

                // Handle (seq ...) - sequential execution
                if (std.mem.eql(u8, op_name, "seq")) {
                    var bytecode = std.ArrayList(u8){};
                    defer bytecode.deinit(allocator);

                    // Compile each expression in sequence
                    for (items[1..]) |item| {
                        var labels_map = std.StringHashMap(LabelInfo).init(allocator);
                        defer {
                            var it = labels_map.iterator();
                            while (it.next()) |entry| {
                                entry.value_ptr.references.deinit(allocator);
                            }
                            labels_map.deinit();
                        }
                        const item_bytecode = try compileLllExpr(allocator, item, &labels_map, bytecode.items.len);
                        defer allocator.free(item_bytecode);
                        try bytecode.appendSlice(allocator, item_bytecode);
                    }

                    return bytecode.toOwnedSlice(allocator);
                }

                // Handle (lll ...) - meta-compilation
                if (std.mem.eql(u8, op_name, "lll")) {
                    if (items.len != 3) return error.InvalidFormat;

                    // Compile the inner expression
                    var labels_map = std.StringHashMap(LabelInfo).init(allocator);
                    defer {
                        var it = labels_map.iterator();
                        while (it.next()) |entry| {
                            entry.value_ptr.references.deinit(allocator);
                        }
                        labels_map.deinit();
                    }
                    const inner_bytecode = try compileLllExpr(allocator, items[1], &labels_map, 0);
                    defer allocator.free(inner_bytecode);

                    var bytecode = std.ArrayList(u8){};
                    defer bytecode.deinit(allocator);

                    // Push the bytecode length
                    const len_bytes = try compilePushValue(allocator, inner_bytecode.len);
                    defer allocator.free(len_bytes);
                    try bytecode.appendSlice(allocator,len_bytes);

                    // DUP1 - duplicate length for later
                    try bytecode.append(allocator, 0x80); // DUP1

                    // Push the offset (second argument)
                    var labels_map2 = std.StringHashMap(LabelInfo).init(allocator);
                    defer {
                        var it = labels_map2.iterator();
                        while (it.next()) |entry| {
                            entry.value_ptr.references.deinit(allocator);
                        }
                        labels_map2.deinit();
                    }
                    const offset_bytecode = try compileLllExpr(allocator, items[2], &labels_map2, bytecode.items.len);
                    defer allocator.free(offset_bytecode);
                    try bytecode.appendSlice(allocator,offset_bytecode);

                    // CODECOPY to copy the init code into memory
                    // Stack: [length, length, offset]
                    // We need: [destOffset, offset, length] for CODECOPY
                    // But we want to return [offset, length] for CREATE2

                    // For now, just push the compiled bytecode as data
                    // This is a simplified version - full LLL would embed the code
                    try bytecode.appendSlice(allocator,inner_bytecode);

                    return bytecode.toOwnedSlice(allocator);
                }

                // Regular opcode with arguments - compile in REVERSE order
                var bytecode = std.ArrayList(u8){};
                defer bytecode.deinit(allocator);

                // Push arguments in reverse order (prefix -> postfix)
                var i = items.len;
                while (i > 1) {
                    i -= 1;
                    var labels_map = std.StringHashMap(LabelInfo).init(allocator);
                    defer {
                        var it = labels_map.iterator();
                        while (it.next()) |entry| {
                            entry.value_ptr.references.deinit(allocator);
                        }
                        labels_map.deinit();
                    }
                    const arg_bytecode = try compileLllExpr(allocator, items[i], &labels_map, bytecode.items.len);
                    defer allocator.free(arg_bytecode);
                    try bytecode.appendSlice(allocator,arg_bytecode);
                }

                // Then execute the opcode
                const opcode = try getOpcode(op_name);
                try bytecode.append(allocator, opcode);

                return bytecode.toOwnedSlice(allocator);
            }

            return error.InvalidFormat;
        },
    }
}

// Helper to compile a PUSH for a value
fn compilePushValue(allocator: std.mem.Allocator, value: u256) ![]u8 {
    var bytecode = std.ArrayList(u8){};
    defer bytecode.deinit(allocator);

    // For addresses (20 bytes), use PUSH20
    if (value > 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF and
        value <= 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
    {
        try bytecode.append(allocator,0x73); // PUSH20
        var j: u8 = 19;
        while (true) : (j -%= 1) {
            try bytecode.append(allocator,@intCast((value >> @intCast(j * 8)) & 0xFF));
            if (j == 0) break;
        }
    } else if (value == 0) {
        try bytecode.append(allocator,0x60); // PUSH1
        try bytecode.append(allocator,0);
    } else if (value <= 0xFF) {
        try bytecode.append(allocator,0x60); // PUSH1
        try bytecode.append(allocator,@intCast(value));
    } else if (value <= 0xFFFF) {
        try bytecode.append(allocator,0x61); // PUSH2
        try bytecode.append(allocator,@intCast(value >> 8));
        try bytecode.append(allocator,@intCast(value & 0xFF));
    } else if (value <= 0xFFFFFF) {
        try bytecode.append(allocator,0x62); // PUSH3
        try bytecode.append(allocator,@intCast(value >> 16));
        try bytecode.append(allocator,@intCast((value >> 8) & 0xFF));
        try bytecode.append(allocator,@intCast(value & 0xFF));
    } else if (value <= 0xFFFFFFFF) {
        try bytecode.append(allocator,0x63); // PUSH4
        try bytecode.append(allocator,@intCast(value >> 24));
        try bytecode.append(allocator,@intCast((value >> 16) & 0xFF));
        try bytecode.append(allocator,@intCast((value >> 8) & 0xFF));
        try bytecode.append(allocator,@intCast(value & 0xFF));
    } else {
        // For larger values, use PUSH32
        try bytecode.append(allocator,0x7f); // PUSH32
        var j: u8 = 31;
        while (true) : (j -%= 1) {
            try bytecode.append(allocator,@intCast((value >> @intCast(j * 8)) & 0xFF));
            if (j == 0) break;
        }
    }

    return bytecode.toOwnedSlice(allocator);
}

// Compile complex expressions with labels and multiple parts
fn compileComplexExpression(allocator: std.mem.Allocator, code: []const u8) ![]u8 {
    var trimmed_code = code;

    // Check for (asm ...) wrapper - this is NOT an LLL expression
    // It's a simple format with space-separated opcodes
    if (std.mem.startsWith(u8, trimmed_code, "(asm ")) {
        trimmed_code = trimmed_code[5..]; // Remove "(asm "
        if (std.mem.endsWith(u8, trimmed_code, ")")) {
            trimmed_code = trimmed_code[0 .. trimmed_code.len - 1]; // Remove ")"
        }
        trimmed_code = std.mem.trim(u8, trimmed_code, " \t\n\r");
        return compileSingleExpression(allocator, trimmed_code);
    }

    var bytecode = std.ArrayList(u8){};
    defer bytecode.deinit(allocator);

    var labels = std.StringHashMap(LabelInfo).init(allocator);
    defer {
        var it = labels.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.references.deinit(allocator);
        }
        labels.deinit();
    }

    var pos: usize = 0;
    while (pos < trimmed_code.len) {
        // Skip whitespace
        while (pos < trimmed_code.len and std.ascii.isWhitespace(trimmed_code[pos])) {
            pos += 1;
        }
        if (pos >= trimmed_code.len) break;

        // Check for storage store [[x]]expr or memory store [x]expr
        if (trimmed_code[pos] == '[') {
            const is_storage = pos + 1 < trimmed_code.len and trimmed_code[pos + 1] == '[';
            const start_bracket = if (is_storage) pos + 2 else pos + 1;

            // Find closing bracket(s)
            var end = start_bracket;
            while (end < trimmed_code.len and trimmed_code[end] != ']') {
                end += 1;
            }
            if (end >= trimmed_code.len) return error.InvalidFormat;

            // Check for second bracket if storage
            if (is_storage) {
                if (end + 1 >= trimmed_code.len or trimmed_code[end + 1] != ']') {
                    // This might be a label, not storage store
                    // Labels are just [[n]] with no following expression
                    // Check if there's a following expression
                    var check_pos = end + 2;
                    while (check_pos < trimmed_code.len and std.ascii.isWhitespace(trimmed_code[check_pos])) {
                        check_pos += 1;
                    }

                    // If no following expression or following is another [[ or end of code, it's a label
                    if (check_pos >= trimmed_code.len or
                        (trimmed_code[check_pos] == '[' and check_pos + 1 < trimmed_code.len and trimmed_code[check_pos + 1] == '['))
                    {
                        // This is a label
                        const label_str = std.mem.trim(u8, trimmed_code[start_bracket..end], " \t");
                        const gop = try labels.getOrPut(label_str);
                        if (!gop.found_existing) {
                            gop.value_ptr.* = LabelInfo{
                                .position = bytecode.items.len,
                                .references = std.ArrayList(usize){},
                            };
                        } else {
                            gop.value_ptr.position = bytecode.items.len;
                        }
                        try bytecode.append(allocator, 0x5b); // JUMPDEST
                        pos = end + 1;
                        continue;
                    }
                    return error.InvalidFormat;
                }
            }

            // Extract index
            const index_str = std.mem.trim(u8, trimmed_code[start_bracket..end], " \t");
            const index = try parseNumber(index_str);

            // Move past closing bracket(s)
            pos = if (is_storage) end + 2 else end + 1;

            // Skip whitespace
            while (pos < trimmed_code.len and std.ascii.isWhitespace(trimmed_code[pos])) {
                pos += 1;
            }

            // Parse the value expression
            if (pos >= trimmed_code.len) return error.InvalidFormat;

            var value_expr: LllExpr = undefined;
            if (trimmed_code[pos] == '(') {
                // Find matching closing paren
                var depth: usize = 1;
                var expr_end = pos + 1;
                while (expr_end < trimmed_code.len and depth > 0) {
                    if (trimmed_code[expr_end] == '(') depth += 1;
                    if (trimmed_code[expr_end] == ')') depth -= 1;
                    expr_end += 1;
                }
                const expr_str = trimmed_code[pos..expr_end];
                value_expr = try parseLllExpression(allocator, expr_str);
                pos = expr_end;
            } else {
                // Parse a simple token (number or hex value)
                const token_start = pos;
                while (pos < trimmed_code.len and
                    !std.ascii.isWhitespace(trimmed_code[pos]) and
                    trimmed_code[pos] != '[' and
                    trimmed_code[pos] != ']' and
                    trimmed_code[pos] != '(' and
                    trimmed_code[pos] != ')' and
                    trimmed_code[pos] != '}')
                {
                    pos += 1;
                }
                const token = trimmed_code[token_start..pos];
                if (token.len == 0) return error.InvalidFormat;

                // Parse as number
                const value = if (isNumber(token))
                    try parseNumber(token)
                else
                    return error.InvalidFormat;

                value_expr = LllExpr{ .number = value };
            }
            defer value_expr.deinit(allocator);

            // Compile: value_expr, push index, MSTORE/SSTORE
            const value_bytecode = try compileLllExpr(allocator, value_expr, &labels, bytecode.items.len);
            defer allocator.free(value_bytecode);
            try bytecode.appendSlice(allocator,value_bytecode);

            // Push index
            const index_bytecode = try compilePushValue(allocator, index);
            defer allocator.free(index_bytecode);
            try bytecode.appendSlice(allocator,index_bytecode);

            // MSTORE or SSTORE
            if (is_storage) {
                try bytecode.append(allocator,0x55); // SSTORE
            } else {
                try bytecode.append(allocator,0x52); // MSTORE
            }
        }
        // Check for LLL expression ( ... )
        else if (trimmed_code[pos] == '(') {
            // Find matching closing paren
            var depth: usize = 1;
            var end = pos + 1;
            while (end < trimmed_code.len and depth > 0) {
                if (trimmed_code[end] == '(') depth += 1;
                if (trimmed_code[end] == ')') depth -= 1;
                end += 1;
            }

            // Parse as LLL expression
            const expr_str = trimmed_code[pos..end];
            var lll_expr = try parseLllExpression(allocator, expr_str);
            defer lll_expr.deinit(allocator);

            // Compile the LLL expression
            const expr_bytecode = try compileLllExpr(allocator, lll_expr, &labels, bytecode.items.len);
            defer allocator.free(expr_bytecode);
            try bytecode.appendSlice(allocator,expr_bytecode);

            pos = end;
        }
        // Check for simple token (number or opcode)
        else {
            // Find end of token
            const start = pos;
            while (pos < trimmed_code.len and !std.ascii.isWhitespace(trimmed_code[pos]) and
                trimmed_code[pos] != '(' and trimmed_code[pos] != ')' and
                trimmed_code[pos] != '[')
            {
                pos += 1;
            }

            if (pos == start) {
                return error.InvalidFormat;
            }

            const token = trimmed_code[start..pos];

            // Compile the token (number or opcode)
            if (isNumber(token)) {
                const value = try parseNumber(token);
                const push_bytes = try compilePushValue(allocator, value);
                defer allocator.free(push_bytes);
                try bytecode.appendSlice(allocator, push_bytes);
            } else {
                // It's an opcode
                const opcode = try getOpcode(token);
                try bytecode.append(allocator, opcode);
            }
        }
    }

    // Resolve label references (update PUSH values for jumps to labels)
    var it = labels.iterator();
    while (it.next()) |entry| {
        for (entry.value_ptr.references.items) |ref_pos| {
            // Update the PUSH2 value with actual label position
            const label_pos = entry.value_ptr.position;
            bytecode.items[ref_pos] = @intCast((label_pos >> 8) & 0xFF);
            bytecode.items[ref_pos + 1] = @intCast(label_pos & 0xFF);
        }
    }

    // LLL sequences {...} end with implicit STOP
    if (bytecode.items.len == 0 or bytecode.items[bytecode.items.len - 1] != 0x00) {
        try bytecode.append(allocator, 0x00); // STOP
    }

    return bytecode.toOwnedSlice(allocator);
}

// Compile a single expression (no wrapper)
fn compileSingleExpression(allocator: std.mem.Allocator, code: []const u8) ![]u8 {
    // Tokenize the assembly code
    var tokens = std.ArrayList([]const u8){};
    defer tokens.deinit(allocator);

    var it = std.mem.tokenizeAny(u8, code, " \t\n\r()");
    while (it.next()) |token| {
        try tokens.append(allocator, token);
    }

    // Compile tokens to bytecode
    var bytecode = std.ArrayList(u8){};
    defer bytecode.deinit(allocator);

    var i: usize = 0;
    while (i < tokens.items.len) : (i += 1) {
        const token = tokens.items[i];

        // Check for PUSH opcodes that need immediate values
        if (std.mem.startsWith(u8, token, "PUSH")) {
            const opcode = try getOpcode(token);
            try bytecode.append(allocator, opcode);

            // If it's a PUSH opcode (not PUSH0), get the immediate value
            if (opcode >= 0x60 and opcode <= 0x7f and i + 1 < tokens.items.len) {
                const push_size = opcode - 0x5f;
                i += 1;
                const value_token = tokens.items[i];
                const value = try parseNumber(value_token);

                // Write the value bytes in big-endian order
                var bytes_written: u8 = 0;
                while (bytes_written < push_size) : (bytes_written += 1) {
                    const shift: u8 = @intCast((push_size - 1 - bytes_written) * 8);
                    try bytecode.append(allocator, @intCast((value >> shift) & 0xFF));
                }
            }
        } else if (isNumber(token)) {
            // It's a standalone number (auto-select PUSH size)
            const value = try parseNumber(token);
            if (value <= 0xFF) {
                try bytecode.append(allocator,0x60); // PUSH1
                try bytecode.append(allocator,@intCast(value));
            } else if (value <= 0xFFFF) {
                try bytecode.append(allocator,0x61); // PUSH2
                try bytecode.append(allocator,@intCast(value >> 8));
                try bytecode.append(allocator,@intCast(value & 0xFF));
            } else if (value <= 0xFFFFFF) {
                try bytecode.append(allocator,0x62); // PUSH3
                try bytecode.append(allocator,@intCast(value >> 16));
                try bytecode.append(allocator,@intCast((value >> 8) & 0xFF));
                try bytecode.append(allocator,@intCast(value & 0xFF));
            } else if (value <= 0xFFFFFFFF) {
                try bytecode.append(allocator,0x63); // PUSH4
                try bytecode.append(allocator,@intCast(value >> 24));
                try bytecode.append(allocator,@intCast((value >> 16) & 0xFF));
                try bytecode.append(allocator,@intCast((value >> 8) & 0xFF));
                try bytecode.append(allocator,@intCast(value & 0xFF));
            } else {
                // For larger values, use PUSH32
                try bytecode.append(allocator,0x7f); // PUSH32
                var j: u8 = 31;
                while (true) : (j -%= 1) {
                    try bytecode.append(allocator, @intCast((value >> @intCast(j * 8)) & 0xFF));
                    if (j == 0) break;
                }
            }
        } else {
            // It's a regular opcode
            const opcode = try getOpcode(token);
            try bytecode.append(allocator, opcode);
        }
    }

    return bytecode.toOwnedSlice(allocator);
}

fn isNumber(token: []const u8) bool {
    if (token.len == 0) return false;

    // Check for hex prefix
    if (std.mem.startsWith(u8, token, "0x") or std.mem.startsWith(u8, token, "0X")) {
        if (token.len <= 2) return false;
        for (token[2..]) |c| {
            if (!std.ascii.isHex(c)) return false;
        }
        return true;
    }

    // Check decimal
    for (token) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

fn parseNumber(token: []const u8) !u256 {
    if (std.mem.startsWith(u8, token, "0x") or std.mem.startsWith(u8, token, "0X")) {
        return try std.fmt.parseInt(u256, token[2..], 16);
    }
    return try std.fmt.parseInt(u256, token, 10);
}

fn getOpcode(name: []const u8) !u8 {
    // Stack operations
    if (std.mem.eql(u8, name, "STOP")) return 0x00;
    if (std.mem.eql(u8, name, "ADD")) return 0x01;
    if (std.mem.eql(u8, name, "MUL")) return 0x02;
    if (std.mem.eql(u8, name, "SUB")) return 0x03;
    if (std.mem.eql(u8, name, "DIV")) return 0x04;
    if (std.mem.eql(u8, name, "SDIV")) return 0x05;
    if (std.mem.eql(u8, name, "MOD")) return 0x06;
    if (std.mem.eql(u8, name, "SMOD")) return 0x07;
    if (std.mem.eql(u8, name, "ADDMOD")) return 0x08;
    if (std.mem.eql(u8, name, "MULMOD")) return 0x09;
    if (std.mem.eql(u8, name, "EXP")) return 0x0a;
    if (std.mem.eql(u8, name, "SIGNEXTEND")) return 0x0b;

    // Comparison
    if (std.mem.eql(u8, name, "LT")) return 0x10;
    if (std.mem.eql(u8, name, "GT")) return 0x11;
    if (std.mem.eql(u8, name, "SLT")) return 0x12;
    if (std.mem.eql(u8, name, "SGT")) return 0x13;
    if (std.mem.eql(u8, name, "EQ")) return 0x14;
    if (std.mem.eql(u8, name, "ISZERO")) return 0x15;

    // Bitwise
    if (std.mem.eql(u8, name, "AND")) return 0x16;
    if (std.mem.eql(u8, name, "OR")) return 0x17;
    if (std.mem.eql(u8, name, "XOR")) return 0x18;
    if (std.mem.eql(u8, name, "NOT")) return 0x19;
    if (std.mem.eql(u8, name, "BYTE")) return 0x1a;
    if (std.mem.eql(u8, name, "SHL")) return 0x1b;
    if (std.mem.eql(u8, name, "SHR")) return 0x1c;
    if (std.mem.eql(u8, name, "SAR")) return 0x1d;

    // SHA3
    if (std.mem.eql(u8, name, "SHA3") or std.mem.eql(u8, name, "KECCAK256")) return 0x20;

    // Environment
    if (std.mem.eql(u8, name, "ADDRESS")) return 0x30;
    if (std.mem.eql(u8, name, "BALANCE")) return 0x31;
    if (std.mem.eql(u8, name, "ORIGIN")) return 0x32;
    if (std.mem.eql(u8, name, "CALLER")) return 0x33;
    if (std.mem.eql(u8, name, "CALLVALUE")) return 0x34;
    if (std.mem.eql(u8, name, "CALLDATALOAD")) return 0x35;
    if (std.mem.eql(u8, name, "CALLDATASIZE")) return 0x36;
    if (std.mem.eql(u8, name, "CALLDATACOPY")) return 0x37;
    if (std.mem.eql(u8, name, "CODESIZE")) return 0x38;
    if (std.mem.eql(u8, name, "CODECOPY")) return 0x39;
    if (std.mem.eql(u8, name, "GASPRICE")) return 0x3a;
    if (std.mem.eql(u8, name, "EXTCODESIZE")) return 0x3b;
    if (std.mem.eql(u8, name, "EXTCODECOPY")) return 0x3c;
    if (std.mem.eql(u8, name, "RETURNDATASIZE")) return 0x3d;
    if (std.mem.eql(u8, name, "RETURNDATACOPY")) return 0x3e;
    if (std.mem.eql(u8, name, "EXTCODEHASH")) return 0x3f;

    // Block
    if (std.mem.eql(u8, name, "BLOCKHASH")) return 0x40;
    if (std.mem.eql(u8, name, "COINBASE")) return 0x41;
    if (std.mem.eql(u8, name, "TIMESTAMP")) return 0x42;
    if (std.mem.eql(u8, name, "NUMBER")) return 0x43;
    if (std.mem.eql(u8, name, "DIFFICULTY") or std.mem.eql(u8, name, "PREVRANDAO")) return 0x44;
    if (std.mem.eql(u8, name, "GASLIMIT")) return 0x45;
    if (std.mem.eql(u8, name, "CHAINID")) return 0x46;
    if (std.mem.eql(u8, name, "SELFBALANCE")) return 0x47;
    if (std.mem.eql(u8, name, "BASEFEE")) return 0x48;

    // Memory
    if (std.mem.eql(u8, name, "POP")) return 0x50;
    if (std.mem.eql(u8, name, "MLOAD")) return 0x51;
    if (std.mem.eql(u8, name, "MSTORE")) return 0x52;
    if (std.mem.eql(u8, name, "MSTORE8")) return 0x53;
    if (std.mem.eql(u8, name, "SLOAD")) return 0x54;
    if (std.mem.eql(u8, name, "SSTORE")) return 0x55;
    if (std.mem.eql(u8, name, "JUMP")) return 0x56;
    if (std.mem.eql(u8, name, "JUMPI")) return 0x57;
    if (std.mem.eql(u8, name, "PC")) return 0x58;
    if (std.mem.eql(u8, name, "MSIZE")) return 0x59;
    if (std.mem.eql(u8, name, "GAS")) return 0x5a;
    if (std.mem.eql(u8, name, "JUMPDEST")) return 0x5b;

    // Push operations
    if (std.mem.eql(u8, name, "PUSH0")) return 0x5f;
    if (std.mem.eql(u8, name, "PUSH1")) return 0x60;
    if (std.mem.eql(u8, name, "PUSH2")) return 0x61;
    if (std.mem.eql(u8, name, "PUSH3")) return 0x62;
    if (std.mem.eql(u8, name, "PUSH4")) return 0x63;
    if (std.mem.eql(u8, name, "PUSH5")) return 0x64;
    if (std.mem.eql(u8, name, "PUSH6")) return 0x65;
    if (std.mem.eql(u8, name, "PUSH7")) return 0x66;
    if (std.mem.eql(u8, name, "PUSH8")) return 0x67;
    if (std.mem.eql(u8, name, "PUSH9")) return 0x68;
    if (std.mem.eql(u8, name, "PUSH10")) return 0x69;
    if (std.mem.eql(u8, name, "PUSH11")) return 0x6a;
    if (std.mem.eql(u8, name, "PUSH12")) return 0x6b;
    if (std.mem.eql(u8, name, "PUSH13")) return 0x6c;
    if (std.mem.eql(u8, name, "PUSH14")) return 0x6d;
    if (std.mem.eql(u8, name, "PUSH15")) return 0x6e;
    if (std.mem.eql(u8, name, "PUSH16")) return 0x6f;
    if (std.mem.eql(u8, name, "PUSH17")) return 0x70;
    if (std.mem.eql(u8, name, "PUSH18")) return 0x71;
    if (std.mem.eql(u8, name, "PUSH19")) return 0x72;
    if (std.mem.eql(u8, name, "PUSH20")) return 0x73;
    if (std.mem.eql(u8, name, "PUSH21")) return 0x74;
    if (std.mem.eql(u8, name, "PUSH22")) return 0x75;
    if (std.mem.eql(u8, name, "PUSH23")) return 0x76;
    if (std.mem.eql(u8, name, "PUSH24")) return 0x77;
    if (std.mem.eql(u8, name, "PUSH25")) return 0x78;
    if (std.mem.eql(u8, name, "PUSH26")) return 0x79;
    if (std.mem.eql(u8, name, "PUSH27")) return 0x7a;
    if (std.mem.eql(u8, name, "PUSH28")) return 0x7b;
    if (std.mem.eql(u8, name, "PUSH29")) return 0x7c;
    if (std.mem.eql(u8, name, "PUSH30")) return 0x7d;
    if (std.mem.eql(u8, name, "PUSH31")) return 0x7e;
    if (std.mem.eql(u8, name, "PUSH32")) return 0x7f;

    // Dup operations
    if (std.mem.eql(u8, name, "DUP1")) return 0x80;
    if (std.mem.eql(u8, name, "DUP2")) return 0x81;
    if (std.mem.eql(u8, name, "DUP3")) return 0x82;
    if (std.mem.eql(u8, name, "DUP4")) return 0x83;
    if (std.mem.eql(u8, name, "DUP5")) return 0x84;
    if (std.mem.eql(u8, name, "DUP6")) return 0x85;
    if (std.mem.eql(u8, name, "DUP7")) return 0x86;
    if (std.mem.eql(u8, name, "DUP8")) return 0x87;
    if (std.mem.eql(u8, name, "DUP9")) return 0x88;
    if (std.mem.eql(u8, name, "DUP10")) return 0x89;
    if (std.mem.eql(u8, name, "DUP11")) return 0x8a;
    if (std.mem.eql(u8, name, "DUP12")) return 0x8b;
    if (std.mem.eql(u8, name, "DUP13")) return 0x8c;
    if (std.mem.eql(u8, name, "DUP14")) return 0x8d;
    if (std.mem.eql(u8, name, "DUP15")) return 0x8e;
    if (std.mem.eql(u8, name, "DUP16")) return 0x8f;

    // Swap operations
    if (std.mem.eql(u8, name, "SWAP1")) return 0x90;
    if (std.mem.eql(u8, name, "SWAP2")) return 0x91;
    if (std.mem.eql(u8, name, "SWAP3")) return 0x92;
    if (std.mem.eql(u8, name, "SWAP4")) return 0x93;
    if (std.mem.eql(u8, name, "SWAP5")) return 0x94;
    if (std.mem.eql(u8, name, "SWAP6")) return 0x95;
    if (std.mem.eql(u8, name, "SWAP7")) return 0x96;
    if (std.mem.eql(u8, name, "SWAP8")) return 0x97;
    if (std.mem.eql(u8, name, "SWAP9")) return 0x98;
    if (std.mem.eql(u8, name, "SWAP10")) return 0x99;
    if (std.mem.eql(u8, name, "SWAP11")) return 0x9a;
    if (std.mem.eql(u8, name, "SWAP12")) return 0x9b;
    if (std.mem.eql(u8, name, "SWAP13")) return 0x9c;
    if (std.mem.eql(u8, name, "SWAP14")) return 0x9d;
    if (std.mem.eql(u8, name, "SWAP15")) return 0x9e;
    if (std.mem.eql(u8, name, "SWAP16")) return 0x9f;

    // Log operations
    if (std.mem.eql(u8, name, "LOG0")) return 0xa0;
    if (std.mem.eql(u8, name, "LOG1")) return 0xa1;
    if (std.mem.eql(u8, name, "LOG2")) return 0xa2;
    if (std.mem.eql(u8, name, "LOG3")) return 0xa3;
    if (std.mem.eql(u8, name, "LOG4")) return 0xa4;

    // System operations
    if (std.mem.eql(u8, name, "CREATE")) return 0xf0;
    if (std.mem.eql(u8, name, "CALL")) return 0xf1;
    if (std.mem.eql(u8, name, "CALLCODE")) return 0xf2;
    if (std.mem.eql(u8, name, "RETURN")) return 0xf3;
    if (std.mem.eql(u8, name, "DELEGATECALL")) return 0xf4;
    if (std.mem.eql(u8, name, "CREATE2")) return 0xf5;
    if (std.mem.eql(u8, name, "STATICCALL")) return 0xfa;
    if (std.mem.eql(u8, name, "REVERT")) return 0xfd;
    if (std.mem.eql(u8, name, "INVALID")) return 0xfe;
    if (std.mem.eql(u8, name, "SELFDESTRUCT")) return 0xff;

    return error.UnknownOpcode;
}

test "compile simple assembly" {
    const allocator = std.testing.allocator;

    // Test SLOAD gas cost assembly
    const asm1 = "(asm GAS DUP1 SLOAD GAS SWAP1 POP SWAP1 SUB 5 SWAP1 SUB 0x01 SSTORE)";
    const bytecode1 = try compileAssembly(allocator, asm1);
    defer allocator.free(bytecode1);

    // Expected: GAS(5a) DUP1(80) SLOAD(54) GAS(5a) SWAP1(90) POP(50) SWAP1(90) SUB(03) PUSH1(60) 05 SWAP1(90) SUB(03) PUSH1(60) 01 SSTORE(55)
    const expected1 = [_]u8{ 0x5a, 0x80, 0x54, 0x5a, 0x90, 0x50, 0x90, 0x03, 0x60, 0x05, 0x90, 0x03, 0x60, 0x01, 0x55 };
    try std.testing.expectEqualSlices(u8, &expected1, bytecode1);

    // Test SELFBALANCE gas cost assembly
    const asm2 = "(asm GAS SELFBALANCE GAS SWAP1 POP SWAP1 SUB 2 SWAP1 SUB 0x01 SSTORE)";
    const bytecode2 = try compileAssembly(allocator, asm2);
    defer allocator.free(bytecode2);

    // Expected: GAS(5a) SELFBALANCE(47) GAS(5a) SWAP1(90) POP(50) SWAP1(90) SUB(03) PUSH1(60) 02 SWAP1(90) SUB(03) PUSH1(60) 01 SSTORE(55)
    const expected2 = [_]u8{ 0x5a, 0x47, 0x5a, 0x90, 0x50, 0x90, 0x03, 0x60, 0x02, 0x90, 0x03, 0x60, 0x01, 0x55 };
    try std.testing.expectEqualSlices(u8, &expected2, bytecode2);
}

test "compile { } format assembly" {
    const allocator = std.testing.allocator;

    // Test simple { } format
    const asm1 = "{ (PUSH1 0x01) (PUSH1 0x02) (ADD) }";
    const bytecode1 = try compileAssembly(allocator, asm1);
    defer allocator.free(bytecode1);

    // Expected: PUSH1 0x01=0x60 0x01, PUSH1 0x02=0x60 0x02, ADD=0x01
    const expected1 = [_]u8{ 0x60, 0x01, 0x60, 0x02, 0x01 };
    try std.testing.expectEqualSlices(u8, &expected1, bytecode1);
}
