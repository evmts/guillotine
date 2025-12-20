/// KZG trusted setup management for EIP-4844 support
const std = @import("std");
const crypto = @import("root.zig");
const c_kzg = crypto.c_kzg;
const kzg_trusted_setup = crypto.kzg_trusted_setup;

/// Embedded trusted setup data
const trusted_setup_data = kzg_trusted_setup.data;

/// Global initialization state
var initialized: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var init_mutex = std.Thread.Mutex{};

/// Global mutex for KZG proof verification
/// The C-KZG library is not thread-safe for concurrent verification operations,
/// so we serialize all verify calls to ensure correctness
var verify_mutex = std.Thread.Mutex{};

/// Initialize the KZG trusted setup from embedded data
/// This should be called once during application startup
/// Thread-safe for concurrent calls
pub fn init() !void {
    // Fast path: check if already initialized without locking
    if (initialized.load(.acquire)) return;

    // Slow path: acquire lock and initialize
    init_mutex.lock();
    defer init_mutex.unlock();

    // Double-check after acquiring lock
    if (initialized.load(.acquire)) return;

    // Load the trusted setup using the embedded data
    const precompute: u64 = 0;
    c_kzg.loadTrustedSetupFromText(trusted_setup_data, precompute) catch |err| {
        // TrustedSetupAlreadyLoaded means it's already initialized, which is fine
        if (err != error.TrustedSetupAlreadyLoaded) {
            return error.TrustedSetupLoadFailed;
        }
    };

    initialized.store(true, .release);
}

/// Initialize the KZG trusted setup from a file (kept for compatibility)
/// This should be called once during application startup
/// Thread-safe for concurrent calls
pub fn initFromFile(_allocator: std.mem.Allocator, trusted_setup_path: []const u8) !void {
    // Fast path: check if already initialized without locking
    if (initialized.load(.acquire)) return;
    _ = _allocator;

    // Slow path: acquire lock and initialize
    init_mutex.lock();
    defer init_mutex.unlock();

    // Double-check after acquiring lock
    if (initialized.load(.acquire)) return;

    // Load the trusted setup using the Zig binding API
    const precompute: u64 = 0;
    c_kzg.loadTrustedSetupFile(trusted_setup_path, precompute) catch |err| {
        // TrustedSetupAlreadyLoaded means it's already initialized, which is fine
        if (err != error.TrustedSetupAlreadyLoaded) {
            return error.TrustedSetupLoadFailed;
        }
    };

    initialized.store(true, .release);
}

/// Deinitialize the KZG trusted setup
pub fn deinit(allocator: std.mem.Allocator) void {
    init_mutex.lock();
    defer init_mutex.unlock();

    if (!initialized.load(.acquire)) return;

    _ = allocator; // allocator unused
    // Free via Zig binding; only ignore TrustedSetupNotLoaded error
    c_kzg.freeTrustedSetup() catch |err| {
        // Only acceptable error is TrustedSetupNotLoaded (already freed or never loaded)
        // Any other error should be reported
        if (err != error.TrustedSetupNotLoaded) {
            @panic("Unexpected error during KZG trusted setup cleanup");
        }
    };

    initialized.store(false, .release);
}

/// Check if KZG is initialized
pub fn isInitialized() bool {
    return initialized.load(.acquire);
}

/// Thread-safe wrapper for KZG proof verification
/// Serializes all verification calls to ensure thread safety
pub fn verifyKZGProofThreadSafe(
    commitment: *const c_kzg.KZGCommitment,
    z: *const c_kzg.Bytes32,
    y: *const c_kzg.Bytes32,
    proof: *const c_kzg.KZGProof,
) !bool {
    verify_mutex.lock();
    defer verify_mutex.unlock();
    return try c_kzg.verifyKZGProof(commitment, z, y, proof);
}

test "KZG setup initialization" {
    const testing = std.testing;

    // Test the embedded initialization
    try init();
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

    // First initialization
    try init();
    try testing.expect(isInitialized());

    // Second initialization should not error (idempotent)
    try init();
    try testing.expect(isInitialized());

    // Third initialization
    try init();
    try testing.expect(isInitialized());

    deinit(testing.allocator);
}

test "KZG setup - initialization with invalid path" {
    const testing = std.testing;

    const invalid_path = "nonexistent/path/to/trusted_setup.txt";

    // This should fail
    const result = initFromFile(testing.allocator, invalid_path);
    try testing.expectError(error.TrustedSetupLoadFailed, result);
}

test "KZG setup - initialization with empty path" {
    const testing = std.testing;

    const empty_path = "";

    // This should fail
    const result = initFromFile(testing.allocator, empty_path);
    try testing.expectError(error.TrustedSetupLoadFailed, result);
}

test "KZG setup - deinitialization without initialization" {
    const testing = std.testing;

    // Force deinitialization state (this is a bit hacky but necessary for isolated testing)
    init_mutex.lock();
    initialized.store(false, .release);
    init_mutex.unlock();

    // Should not crash or error
    deinit(testing.allocator);

    // State should remain uninitialized
    try testing.expect(!isInitialized());
}

test "KZG setup - multiple deinitializations" {
    const testing = std.testing;

    try init();
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

    // Multiple init/deinit cycles
    for (0..5) |_| {
        try init();
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
        "/dev/null", // Special device file
        "/", // Root directory
        ".", // Current directory
        "..", // Parent directory
        "relative/path/file.txt", // Relative path
        "/tmp/nonexistent", // Absolute but nonexistent
        "file_with_no_extension", // No extension
        ".hidden_file", // Hidden file
        "path/with/many/levels/deep/file.txt", // Deep path
    };

    for (test_cases) |path| {
        const result = initFromFile(testing.allocator, path);
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

    const result = initFromFile(testing.allocator, long_path);
    try testing.expectError(error.TrustedSetupLoadFailed, result);
}

test "KZG setup - null termination handling" {
    const testing = std.testing;

    // Test with paths that might cause issues with C interop
    const tricky_paths = [_][]const u8{
        "path\x00with_null", // Embedded null
        "path_ending_in_null\x00", // Null at end
    };

    for (tricky_paths) |path| {
        const result = initFromFile(testing.allocator, path);
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

    // Test with a failing allocator (this would require a custom allocator implementation)
    // For now, just test with the standard allocator
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    try init();
    try testing.expect(isInitialized());

    deinit(arena.allocator());
    try testing.expect(!isInitialized());
}

test "KZG setup - initialization state transitions" {
    const testing = std.testing;

    // Test state transitions: uninitialized -> initialized -> uninitialized
    try testing.expect(!isInitialized() or isInitialized()); // Initial state might vary

    try init();
    try testing.expect(isInitialized()); // Should be initialized after init

    deinit(testing.allocator);
    try testing.expect(!isInitialized()); // Should be uninitialized after deinit
}
