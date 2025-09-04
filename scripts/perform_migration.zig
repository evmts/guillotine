const std = @import("std");
const migration_tool = @import("migration_tool.zig");
const fs = std.fs;
const print = std.debug.print;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    
    if (args.len < 2) {
        print("Usage: {s} <source_file_path>\n", .{args[0]});
        return;
    }
    
    const source_path = args[1];
    print("Migrating tests from: {s}\n", .{source_path});
    
    // Get just the filename without extension for test file naming
    const source_name = blk: {
        const last_slash = std.mem.lastIndexOf(u8, source_path, "/") orelse 0;
        const filename = if (last_slash > 0) source_path[last_slash + 1 ..] else source_path;
        const dot_index = std.mem.lastIndexOf(u8, filename, ".") orelse filename.len;
        break :blk filename[0..dot_index];
    };
    
    const dir_path = blk: {
        const last_slash = std.mem.lastIndexOf(u8, source_path, "/") orelse 0;
        break :blk if (last_slash > 0) source_path[0..last_slash] else ".";
    };
    
    const test_path = try std.fmt.allocPrint(allocator, "{s}/{s}_test.zig", .{ dir_path, source_name });
    defer allocator.free(test_path);
    
    // Count original tests
    const original_count = try migration_tool.countTestsInFile(source_path);
    print("Found {d} tests in source file\n", .{original_count});
    
    if (original_count == 0) {
        print("No tests found in source file. Nothing to migrate.\n");
        return;
    }
    
    // Perform migration
    const migrated = try migration_tool.migrateTestsToSeparateFile(allocator, source_path);
    defer migrated.deinit(allocator);
    
    print("Migration completed. Migrated {d} tests.\n", .{migrated.test_count});
    
    // Write the updated source file (without tests)
    try fs.cwd().writeFile(.{ .sub_path = source_path, .data = migrated.source_file_content });
    print("Updated source file: {s}\n", .{source_path});
    
    // Write the new test file
    try fs.cwd().writeFile(.{ .sub_path = test_path, .data = migrated.test_file_content });
    print("Created test file: {s}\n", .{test_path});
    
    // Verify test count matches
    const final_source_count = try migration_tool.countTestsInFile(source_path);
    const final_test_count = try migration_tool.countTestsInFile(test_path);
    
    print("Verification:\n");
    print("  Original tests: {d}\n", .{original_count});
    print("  Tests in source after migration: {d}\n", .{final_source_count});
    print("  Tests in new test file: {d}\n", .{final_test_count});
    print("  Total after migration: {d}\n", .{final_source_count + final_test_count});
    
    if (original_count == final_source_count + final_test_count) {
        print("✅ Test count verification passed!\n");
    } else {
        print("❌ Test count verification failed!\n");
        return error.TestCountMismatch;
    }
}