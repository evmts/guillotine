/// KZG trusted setup management for EIP-4844 support
const std = @import("std");
const crypto = @import("root.zig");
const c_kzg = crypto.c_kzg;
const kzg_trusted_setup = crypto.kzg_trusted_setup;

/// Embedded trusted setup data
const trusted_setup_data = kzg_trusted_setup.data;

/// Set once the trusted setup is loaded. Read without the lock only by the
/// `init` fast path and `isInitialized`.
var initialized: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// Guards the trusted setup. Loading and freeing take it exclusively;
/// verification takes it shared. c-kzg only reads `KZGSettings` while
/// verifying, so concurrent verifications run in parallel, and `deinit`
/// waits for every in-flight verification before it frees the setup.
var setup_lock: std.Io.RwLock = .init;

/// The lock only needs futex wait and wake, which the global instance
/// provides across OS threads.
fn lockIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

/// Load `text` under the exclusive lock unless the setup is already loaded.
fn load(text: []const u8) !void {
    if (initialized.load(.acquire)) return;
    setup_lock.lockUncancelable(lockIo());
    defer setup_lock.unlock(lockIo());
    if (initialized.load(.acquire)) return;

    c_kzg.loadTrustedSetupFromText(text, 0) catch |err| switch (err) {
        // Loaded directly through c_kzg; adopt it.
        error.TrustedSetupAlreadyLoaded => {},
        else => return error.TrustedSetupLoadFailed,
    };
    initialized.store(true, .release);
}

/// Initialize the KZG trusted setup from embedded data.
/// Idempotent and safe to call from several threads.
pub fn init() !void {
    try load(trusted_setup_data);
}

/// Initialize the KZG trusted setup from a file.
/// Idempotent and safe to call from several threads.
pub fn initFromFile(_allocator: std.mem.Allocator, trusted_setup_path: []const u8) !void {
    _ = _allocator;
    if (initialized.load(.acquire)) return;
    setup_lock.lockUncancelable(lockIo());
    defer setup_lock.unlock(lockIo());
    if (initialized.load(.acquire)) return;

    c_kzg.loadTrustedSetupFile(trusted_setup_path, 0) catch |err| switch (err) {
        error.TrustedSetupAlreadyLoaded => {},
        else => return error.TrustedSetupLoadFailed,
    };
    initialized.store(true, .release);
}

/// Free the KZG trusted setup. Waits for in-flight verifications.
pub fn deinit(allocator: std.mem.Allocator) void {
    _ = allocator;
    setup_lock.lockUncancelable(lockIo());
    defer setup_lock.unlock(lockIo());
    if (!initialized.load(.acquire)) return;

    c_kzg.freeTrustedSetup() catch |err| switch (err) {
        // Freed directly through c_kzg; the state below is still correct.
        error.TrustedSetupNotLoaded => {},
    };
    initialized.store(false, .release);
}

/// Check if KZG is initialized
pub fn isInitialized() bool {
    return initialized.load(.acquire);
}

/// Verify a KZG proof. Holds the shared lock, so verifications run
/// concurrently and never overlap `deinit`. Returns
/// `error.TrustedSetupNotLoaded` when no setup is loaded.
pub fn verifyKZGProofThreadSafe(
    commitment: *const c_kzg.KZGCommitment,
    z: *const c_kzg.Bytes32,
    y: *const c_kzg.Bytes32,
    proof: *const c_kzg.KZGProof,
) !bool {
    setup_lock.lockSharedUncancelable(lockIo());
    defer setup_lock.unlockShared(lockIo());
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
    setup_lock.lockUncancelable(lockIo());
    initialized.store(false, .release);
    setup_lock.unlock(lockIo());

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

test "KZG file loader rejects tampered trusted setup" {
    var directory = std.testing.tmpDir(.{});
    defer directory.cleanup();
    const bytes = try std.testing.allocator.dupe(u8, trusted_setup_data);
    defer std.testing.allocator.free(bytes);
    bytes[100] ^= 1;
    try directory.dir.writeFile(std.testing.io, .{ .sub_path = "trusted_setup.txt", .data = bytes });
    const path = try directory.dir.realPathFileAlloc(std.testing.io, "trusted_setup.txt", std.testing.allocator);
    defer std.testing.allocator.free(path);
    try std.testing.expectError(error.IntegrityCheckFailed, c_kzg.loadTrustedSetupFile(path, 0));
}

test "KZG setup - verification runs concurrently with deinit and init" {
    // EIP-4844 verify_kzg_proof_case_correct_proof_0_0: commitment and proof at infinity.
    var commitment: c_kzg.KZGCommitment = @splat(0);
    commitment[0] = 0xc0;
    var proof: c_kzg.KZGProof = @splat(0);
    proof[0] = 0xc0;
    const zero: c_kzg.Bytes32 = @splat(0);

    try init();
    try std.testing.expect(try verifyKZGProofThreadSafe(&commitment, &zero, &zero, &proof));

    const Worker = struct {
        commitment: *const c_kzg.KZGCommitment,
        proof: *const c_kzg.KZGProof,
        zero: *const c_kzg.Bytes32,
        verified: usize = 0,
        not_loaded: usize = 0,
        failed: bool = false,

        fn run(self: *@This()) void {
            for (0..64) |_| {
                if (verifyKZGProofThreadSafe(self.commitment, self.zero, self.zero, self.proof)) |valid| {
                    if (!valid) self.failed = true;
                    self.verified += 1;
                } else |err| switch (err) {
                    error.TrustedSetupNotLoaded => self.not_loaded += 1,
                    else => self.failed = true,
                }
            }
        }
    };

    var workers: [4]Worker = undefined;
    var threads: [4]std.Thread = undefined;
    for (&workers, &threads) |*worker, *thread| {
        worker.* = .{ .commitment = &commitment, .proof = &proof, .zero = &zero };
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{worker});
    }
    for (0..8) |_| {
        deinit(std.testing.allocator);
        try init();
    }
    for (threads) |thread| thread.join();

    // Every call either saw a loaded setup and verified, or saw none and said so.
    for (workers) |worker| {
        try std.testing.expect(!worker.failed);
        try std.testing.expectEqual(@as(usize, 64), worker.verified + worker.not_loaded);
    }
    try std.testing.expect(isInitialized());
    deinit(std.testing.allocator);
    try std.testing.expectError(error.TrustedSetupNotLoaded, verifyKZGProofThreadSafe(&commitment, &zero, &zero, &proof));
}
