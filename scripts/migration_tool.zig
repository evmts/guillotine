const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const print = std.debug.print;

// GREEN: Implementing the migration utilities to pass our tests

pub const FileWithTests = struct {
    name: []const u8,
    test_count: u32,
    
    const Self = @This();
    
    pub fn deinit(self: Self, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
    }
};

pub const MigrationResult = struct {
    source_file_content: []const u8,
    test_file_content: []const u8,
    test_count: u32,
    
    const Self = @This();
    
    pub fn deinit(self: Self, allocator: std.mem.Allocator) void {
        allocator.free(self.source_file_content);
        allocator.free(self.test_file_content);
    }
};

pub fn countTestsInFile(file_path: []const u8) !u32 {
    const file = fs.cwd().openFile(file_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => return err,
    };
    defer file.close();
    
    const content = try file.readToEndAlloc(std.heap.page_allocator, 1024 * 1024);
    defer std.heap.page_allocator.free(content);
    
    var count: u32 = 0;
    var lines = mem.split(u8, content, "\n");
    while (lines.next()) |line| {
        if (mem.startsWith(u8, mem.trim(u8, line, " \t"), "test \"")) {
            count += 1;
        }
    }
    
    return count;
}

pub fn findFilesWithInlineTests(allocator: std.mem.Allocator, dir_path: []const u8) ![]FileWithTests {
    var dir = fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return &[_]FileWithTests{},
        else => return err,
    };
    defer dir.close();
    
    var results = std.ArrayList(FileWithTests).init(allocator);
    defer results.deinit();
    
    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind == .file and mem.endsWith(u8, entry.name, ".zig")) {
            // Skip already separated test files
            if (mem.endsWith(u8, entry.name, "_test.zig") or 
                mem.endsWith(u8, entry.name, "_tests.zig") or
                mem.endsWith(u8, entry.name, "_bench.zig")) {
                continue;
            }
            
            var file_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.name });
            defer allocator.free(file_path);
            
            const test_count = countTestsInFile(file_path) catch 0;
            if (test_count > 0) {
                const name_copy = try allocator.dupe(u8, entry.name);
                try results.append(.{
                    .name = name_copy,
                    .test_count = test_count,
                });
            }
        }
    }
    
    return results.toOwnedSlice();
}

pub fn extractTestBlocks(allocator: std.mem.Allocator, content: []const u8) ![][]const u8 {
    var test_blocks = std.ArrayList([]const u8).init(allocator);
    defer test_blocks.deinit();
    
    var lines = mem.split(u8, content, "\n");
    var line_index: usize = 0;
    var current_test_start: ?usize = null;
    var brace_count: i32 = 0;
    var in_test = false;
    
    // Convert lines iterator to ArrayList for indexed access
    var all_lines = std.ArrayList([]const u8).init(allocator);
    defer all_lines.deinit();
    while (lines.next()) |line| {
        try all_lines.append(line);
    }
    
    for (all_lines.items, 0..) |line, i| {
        const trimmed = mem.trim(u8, line, " \t");
        
        if (mem.startsWith(u8, trimmed, "test \"")) {
            current_test_start = i;
            in_test = true;
            brace_count = 0;
        }
        
        if (in_test) {
            // Count braces to find end of test block
            for (line) |char| {
                switch (char) {
                    '{' => brace_count += 1,
                    '}' => {
                        brace_count -= 1;
                        if (brace_count == 0 and current_test_start != null) {
                            // Found end of test block
                            var test_block = std.ArrayList(u8).init(allocator);
                            defer test_block.deinit();
                            
                            var j = current_test_start.?;
                            while (j <= i) : (j += 1) {
                                try test_block.appendSlice(all_lines.items[j]);
                                if (j < i) try test_block.append('\n');
                            }
                            
                            try test_blocks.append(try test_block.toOwnedSlice());
                            in_test = false;
                            current_test_start = null;
                            break;
                        }
                    },
                    else => {},
                }
            }
        }
    }
    
    return test_blocks.toOwnedSlice();
}

pub fn removeTestsFromContent(allocator: std.mem.Allocator, content: []const u8) ![]const u8 {
    var lines = mem.split(u8, content, "\n");
    var result = std.ArrayList(u8).init(allocator);
    defer result.deinit();
    
    var all_lines = std.ArrayList([]const u8).init(allocator);
    defer all_lines.deinit();
    while (lines.next()) |line| {
        try all_lines.append(line);
    }
    
    var i: usize = 0;
    while (i < all_lines.items.len) {
        const line = all_lines.items[i];
        const trimmed = mem.trim(u8, line, " \t");
        
        if (mem.startsWith(u8, trimmed, "test \"")) {
            // Skip test block
            var brace_count: i32 = 0;
            var in_test = true;
            
            while (in_test and i < all_lines.items.len) {
                const test_line = all_lines.items[i];
                
                for (test_line) |char| {
                    switch (char) {
                        '{' => brace_count += 1,
                        '}' => {
                            brace_count -= 1;
                            if (brace_count == 0) {
                                in_test = false;
                                break;
                            }
                        },
                        else => {},
                    }
                }
                i += 1;
            }
            
            // Skip empty lines after test
            while (i < all_lines.items.len and mem.trim(u8, all_lines.items[i], " \t\n").len == 0) {
                i += 1;
            }
        } else {
            // Keep non-test lines
            try result.appendSlice(line);
            if (i < all_lines.items.len - 1) try result.append('\n');
            i += 1;
        }
    }
    
    return result.toOwnedSlice();
}

pub fn createTestFileContent(allocator: std.mem.Allocator, source_file_name: []const u8, test_blocks: [][]const u8) ![]const u8 {
    var result = std.ArrayList(u8).init(allocator);
    defer result.deinit();
    
    // Add standard imports
    try result.appendSlice("const std = @import(\"std\");\n");
    try result.appendSlice("const testing = std.testing;\n");
    
    // Import the source module
    const module_name = blk: {
        const dot_index = mem.lastIndexOf(u8, source_file_name, ".") orelse source_file_name.len;
        break :blk source_file_name[0..dot_index];
    };
    
    try result.writer().print("const {s} = @import(\"{s}\");\n", .{ module_name, source_file_name });
    try result.appendSlice("\n");
    
    // Add all test blocks
    for (test_blocks) |test_block| {
        try result.appendSlice(test_block);
        try result.appendSlice("\n\n");
    }
    
    return result.toOwnedSlice();
}

pub fn migrateTestsToSeparateFile(allocator: std.mem.Allocator, file_path: []const u8) !MigrationResult {
    const file = try fs.cwd().openFile(file_path, .{});
    defer file.close();
    
    const original_content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(original_content);
    
    // Extract test blocks
    const test_blocks = try extractTestBlocks(allocator, original_content);
    defer {
        for (test_blocks) |block| {
            allocator.free(block);
        }
        allocator.free(test_blocks);
    }
    
    // Create new source content without tests
    const source_content = try removeTestsFromContent(allocator, original_content);
    
    // Get just the filename from path
    const file_name = blk: {
        const last_slash = mem.lastIndexOf(u8, file_path, "/") orelse 0;
        break :blk if (last_slash > 0) file_path[last_slash + 1 ..] else file_path;
    };
    
    // Create test file content
    const test_content = try createTestFileContent(allocator, file_name, test_blocks);
    
    return MigrationResult{
        .source_file_content = source_content,
        .test_file_content = test_content,
        .test_count = @intCast(test_blocks.len),
    };
}