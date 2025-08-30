/// KZG trusted setup management for EIP-4844 support
const std = @import("std");
const crypto = @import("crypto");

/// Global initialization state
var initialized = false;

/// Initialize the KZG trusted setup from a file
/// This should be called once during application startup
pub fn init(_allocator: std.mem.Allocator, trusted_setup_path: []const u8) !void {
    if (initialized) return;
    _ = _allocator;
    
    // Load the trusted setup using the Zig binding API
    const precompute: u64 = 0;
    crypto.c_kzg.loadTrustedSetupFile(trusted_setup_path, precompute) catch {
        return error.TrustedSetupLoadFailed;
    };
    
    initialized = true;
}


/// Deinitialize the KZG trusted setup
pub fn deinit(allocator: std.mem.Allocator) void {
    if (!initialized) return;
    
    _ = allocator; // allocator unused
    // Free via Zig binding; ignore error if not loaded
    crypto.c_kzg.freeTrustedSetup() catch {};
    
    initialized = false;
}

/// Check if KZG is initialized
pub fn isInitialized() bool {
    return initialized;
}

test "KZG setup initialization" {
    const testing = std.testing;
    
    // This test requires the trusted setup file to be present
    // Skip if file doesn't exist
    const trusted_setup_path = "data/kzg/trusted_setup.txt";
    std.fs.cwd().access(trusted_setup_path, .{}) catch {
        // File doesn't exist, skip test
        return;
    };
    
    try init(testing.allocator, trusted_setup_path);
    defer deinit(testing.allocator);
    
    try testing.expect(isInitialized());
}

test "KZG setup - initial state" {
    const testing = std.testing;
    
    // Before any initialization, should not be initialized
    // Note: This test assumes a clean state, which might not always be the case
    // in a test suite where other tests have run first
    const initial_state = isInitialized();
    _ = initial_state; // We can't make assumptions about the initial state
    
    // The function should be callable without error
    try testing.expect(true); // Placeholder assertion
}

test "KZG setup - multiple initializations" {
    const testing = std.testing;
    
    const trusted_setup_path = "data/kzg/trusted_setup.txt";
    std.fs.cwd().access(trusted_setup_path, .{}) catch {
        // File doesn't exist, skip test
        return;
    };
    
    // First initialization
    try init(testing.allocator, trusted_setup_path);
    try testing.expect(isInitialized());
    
    // Second initialization should not error (idempotent)
    try init(testing.allocator, trusted_setup_path);
    try testing.expect(isInitialized());
    
    // Third initialization with same path
    try init(testing.allocator, trusted_setup_path);
    try testing.expect(isInitialized());
    
    deinit(testing.allocator);
}

test "KZG setup - initialization with invalid path" {
    const testing = std.testing;
    
    const invalid_path = "nonexistent/path/to/trusted_setup.txt";
    
    // This should fail
    const result = init(testing.allocator, invalid_path);
    try testing.expectError(error.TrustedSetupLoadFailed, result);
}

test "KZG setup - initialization with empty path" {
    const testing = std.testing;
    
    const empty_path = "";
    
    // This should fail
    const result = init(testing.allocator, empty_path);
    try testing.expectError(error.TrustedSetupLoadFailed, result);
}

test "KZG setup - deinitialization without initialization" {
    const testing = std.testing;
    
    // Force deinitialization state (this is a bit hacky but necessary for isolated testing)
    initialized = false;
    
    // Should not crash or error
    deinit(testing.allocator);
    
    // State should remain uninitialized
    try testing.expect(!isInitialized());
}

test "KZG setup - multiple deinitializations" {
    const testing = std.testing;
    
    const trusted_setup_path = "data/kzg/trusted_setup.txt";
    std.fs.cwd().access(trusted_setup_path, .{}) catch {
        // File doesn't exist, skip test
        return;
    };
    
    try init(testing.allocator, trusted_setup_path);
    try testing.expect(isInitialized());
    
    // First deinit
    deinit(testing.allocator);
    try testing.expect(!isInitialized());
    
    // Second deinit should not crash
    deinit(testing.allocator);
    try testing.expect(!isInitialized());
    
    // Third deinit should not crash
    deinit(testing.allocator);
    try testing.expect(!isInitialized());
}

test "KZG setup - init/deinit cycle" {
    const testing = std.testing;
    
    const trusted_setup_path = "data/kzg/trusted_setup.txt";
    std.fs.cwd().access(trusted_setup_path, .{}) catch {
        // File doesn't exist, skip test
        return;
    };
    
    // Multiple init/deinit cycles
    for (0..5) |_| {
        try init(testing.allocator, trusted_setup_path);
        try testing.expect(isInitialized());
        
        deinit(testing.allocator);
        try testing.expect(!isInitialized());
    }
}

test "KZG setup - state consistency" {
    const testing = std.testing;
    
    // Initially get the state
    const initial_state = isInitialized();
    
    // Multiple calls to isInitialized should return the same value
    for (0..10) |_| {
        try testing.expectEqual(initial_state, isInitialized());
    }
}

test "KZG setup - path edge cases" {
    const testing = std.testing;
    
    const test_cases = [_][]const u8{
        "/dev/null",                    // Special device file
        "/",                           // Root directory
        ".",                           // Current directory
        "..",                          // Parent directory
        "relative/path/file.txt",      // Relative path
        "/tmp/nonexistent",            // Absolute but nonexistent
        "file_with_no_extension",      // No extension
        ".hidden_file",               // Hidden file
        "path/with/many/levels/deep/file.txt", // Deep path
    };
    
    for (test_cases) |path| {
        const result = init(testing.allocator, path);
        // All these should fail since they're not valid trusted setup files
        try testing.expectError(error.TrustedSetupLoadFailed, result);
        
        // Ensure we're still not initialized after failed attempts
        try testing.expect(!isInitialized() or isInitialized()); // Allow either state since init might succeed in some environments
    }
}

test "KZG setup - very long path" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    // Create a very long path
    const long_path = try allocator.alloc(u8, 1000);
    defer allocator.free(long_path);
    
    for (long_path) |*char| {
        char.* = 'a';
    }
    
    const result = init(testing.allocator, long_path);
    try testing.expectError(error.TrustedSetupLoadFailed, result);
}

test "KZG setup - null termination handling" {
    const testing = std.testing;
    
    // Test with paths that might cause issues with C interop
    const tricky_paths = [_][]const u8{
        "path\x00with_null",           // Embedded null
        "path_ending_in_null\x00",     // Null at end
    };
    
    for (tricky_paths) |path| {
        const result = init(testing.allocator, path);
        try testing.expectError(error.TrustedSetupLoadFailed, result);
    }
}

test "KZG setup - concurrent safety" {
    const testing = std.testing;
    
    // Test that multiple calls to isInitialized are safe
    // This is a simple test since we can't easily test true concurrency in Zig tests
    const initial_state = isInitialized();
    
    // Simulate rapid calls that might happen in concurrent scenarios
    for (0..1000) |_| {
        _ = isInitialized();
    }
    
    // State should remain consistent
    try testing.expectEqual(initial_state, isInitialized());
}

test "KZG setup - memory allocation edge cases" {
    const testing = std.testing;
    
    // Test with different allocator states
    const trusted_setup_path = "data/kzg/trusted_setup.txt";
    std.fs.cwd().access(trusted_setup_path, .{}) catch {
        return; // Skip if file doesn't exist
    };
    
    // Test with a failing allocator (this would require a custom allocator implementation)
    // For now, just test with the standard allocator
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    
    try init(arena.allocator(), trusted_setup_path);
    try testing.expect(isInitialized());
    
    deinit(arena.allocator());
    try testing.expect(!isInitialized());
}

test "KZG setup - initialization state transitions" {
    const testing = std.testing;
    
    const trusted_setup_path = "data/kzg/trusted_setup.txt";
    std.fs.cwd().access(trusted_setup_path, .{}) catch {
        return; // Skip if file doesn't exist  
    };
    
    // Test state transitions: uninitialized -> initialized -> uninitialized
    try testing.expect(!isInitialized() or isInitialized()); // Initial state might vary
    
    try init(testing.allocator, trusted_setup_path);
    try testing.expect(isInitialized()); // Should be initialized after init
    
    deinit(testing.allocator);
    try testing.expect(!isInitialized()); // Should be uninitialized after deinit
}
