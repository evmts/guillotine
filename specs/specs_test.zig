const std = @import("std");
const evm = @import("evm");
const primitives = @import("voltaire");
const crypto = @import("crypto");

const testing = std.testing;

// Test file structure
const TestFile = struct {
    filepath: []const u8,
    content: []const u8,
};

// Import the auto-generated list of all test files
const all_files = @import("all_test_files.zig");
const test_file_paths = all_files.all_test_file_paths;

// Comptime generate test files array
const test_files = blk: {
    @setEvalBranchQuota(100000000); // Increased for 2233 files
    
    var files: [test_file_paths.len]TestFile = undefined;
    
    for (test_file_paths, 0..) |filepath, i| {
        files[i] = TestFile{
            .filepath = filepath,
            .content = @embedFile(filepath),
        };
    }
    
    break :blk files;
};

// Simple test to verify we have the expected number of files
test "verify test files loaded" {
    std.log.info("Number of test files embedded: {}", .{test_files.len});
    try testing.expect(test_files.len == test_file_paths.len);
    
    // Verify each file has content
    for (test_files) |test_file| {
        std.log.info("Test file: {s}, content size: {} bytes", .{test_file.filepath, test_file.content.len});
        try testing.expect(test_file.content.len > 0);
    }
}