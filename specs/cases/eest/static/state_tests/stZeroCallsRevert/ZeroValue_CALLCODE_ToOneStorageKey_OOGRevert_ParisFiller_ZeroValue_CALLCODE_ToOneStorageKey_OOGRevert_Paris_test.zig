const std = @import("std");
const testing = std.testing;
const runner = @import("runner");

test "ZeroValue_CALLCODE_ToOneStorageKey_OOGRevert_Paris" {
    const allocator = testing.allocator;
    
    // Read and parse the JSON test file
    const json_path = "specs/execution-specs/tests/eest/static/state_tests/stZeroCallsRevert/ZeroValue_CALLCODE_ToOneStorageKey_OOGRevert_ParisFiller.json";
    const json_content = try std.Io.Dir.cwd().readFileAlloc(testing.io, json_path, allocator, .limited(100 * 1024 * 1024));
    defer allocator.free(json_content);
    
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{});
    defer parsed.deinit();
    
    // Get the specific test case
    const test_case = parsed.value.object.get("ZeroValue_CALLCODE_ToOneStorageKey_OOGRevert_Paris").?;
    
    // Run the test
    try runner.runJsonTest(allocator, test_case);
}
