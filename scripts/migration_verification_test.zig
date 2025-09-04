const std = @import("std");
const testing = std.testing;
const migration_tool = @import("migration_tool.zig");

// GREEN: Updated tests to use implemented migration tooling

test "migration tool can count tests in a file" {
    const test_count = try migration_tool.countTestsInFile("src/evm/evm.zig");
    try testing.expect(test_count == 83); // Known count from issue analysis
}

test "migration tool can identify files with inline tests" {
    const allocator = testing.allocator;
    const files_with_tests = try migration_tool.findFilesWithInlineTests(allocator, "src/evm/");
    defer {
        for (files_with_tests) |file| {
            file.deinit(allocator);
        }
        allocator.free(files_with_tests);
    }
    
    // Should find evm.zig among others
    var found_evm = false;
    for (files_with_tests) |file| {
        if (std.mem.eql(u8, file.name, "evm.zig")) {
            found_evm = true;
            try testing.expectEqual(@as(u32, 83), file.test_count);
        }
    }
    try testing.expect(found_evm);
}

test "migration preserves exact test count" {
    const allocator = testing.allocator;
    
    const original_count = try migration_tool.countTestsInFile("src/evm/stack.zig");
    try testing.expect(original_count > 0);
    
    // Test the migration functionality
    const migrated = try migration_tool.migrateTestsToSeparateFile(allocator, "src/evm/stack.zig");
    defer migrated.deinit(allocator);
    try testing.expectEqual(original_count, migrated.test_count);
}