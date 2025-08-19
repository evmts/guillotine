const std = @import("std");
const CodeAnalysis = @import("analysis.zig").CodeAnalysis;
const keccak = std.crypto.hash.sha3.Keccak256;
const Log = @import("log.zig");
const OpcodeMetadata = @import("opcode_metadata/opcode_metadata.zig");

/// LRU cache for code analysis results to avoid redundant analysis during nested calls.
///
/// This cache stores analyzed bytecode to prevent re-analyzing the same contract
/// multiple times during execution, especially beneficial for nested calls to the
/// same contract addresses.
pub const AnalysisCache = @This();

/// Maximum number of entries in the cache (configurable)
pub const DEFAULT_CACHE_SIZE: usize = 128;

/// Cache statistics for monitoring performance
pub const CacheStats = struct {
    hits: u64 = 0,
    misses: u64 = 0,
    evictions: u64 = 0,

    pub fn hit_rate(self: *const CacheStats) f64 {
        const total = self.hits + self.misses;
        if (total == 0) return 0.0;
        return @as(f64, @floatFromInt(self.hits)) / @as(f64, @floatFromInt(total));
    }
};

/// Cache key - hash of the bytecode
pub const CacheKey = [32]u8;

/// Cache entry containing analyzed code and LRU tracking
const CacheEntry = struct {
    /// The analyzed code
    analysis: CodeAnalysis,
    /// Key for this entry (code hash)
    key: CacheKey,
    /// Reference count for safe memory management
    ref_count: u32,
    /// LRU tracking - previous entry in the list
    prev: ?*CacheEntry,
    /// LRU tracking - next entry in the list
    next: ?*CacheEntry,
};

/// LRU cache state
allocator: std.mem.Allocator,
/// Hash map for O(1) lookup
entries: std.hash_map.HashMap(CacheKey, *CacheEntry, CacheKeyContext, 80),
/// Maximum number of entries
max_size: usize,
/// Current number of entries
size: usize,
/// Most recently used entry (head of the list)
head: ?*CacheEntry,
/// Least recently used entry (tail of the list)
tail: ?*CacheEntry,
/// Cache statistics
stats: CacheStats,
/// Mutex for thread safety (if needed in future)
mutex: std.Thread.Mutex,

const CacheKeyContext = struct {
    pub fn hash(self: @This(), key: CacheKey) u64 {
        _ = self;
        // Use first 8 bytes of the hash as the hash value
        return std.mem.readInt(u64, key[0..8], .big);
    }

    pub fn eql(self: @This(), a: CacheKey, b: CacheKey) bool {
        _ = self;
        return std.mem.eql(u8, &a, &b);
    }
};

/// Initialize a new analysis cache
pub fn init(allocator: std.mem.Allocator, max_size: usize) AnalysisCache {
    return AnalysisCache{
        .allocator = allocator,
        .entries = std.hash_map.HashMap(CacheKey, *CacheEntry, CacheKeyContext, 80).init(allocator),
        .max_size = max_size,
        .size = 0,
        .head = null,
        .tail = null,
        .stats = CacheStats{},
        .mutex = std.Thread.Mutex{},
    };
}

/// Clean up the cache and all cached analyses
pub fn deinit(self: *AnalysisCache) void {
    // Clean up all entries
    var iter = self.entries.iterator();
    while (iter.next()) |entry| {
        var cache_entry = entry.value_ptr.*;
        // Deinit the analysis
        cache_entry.analysis.deinit();
        // Free the entry
        self.allocator.destroy(cache_entry);
    }
    self.entries.deinit();
}

/// Compute cache key from bytecode
fn computeKey(code: []const u8) CacheKey {
    var key: CacheKey = undefined;
    keccak.hash(code, &key, .{});
    return key;
}

/// Move entry to the head of the LRU list (most recently used)
fn moveToHead(self: *AnalysisCache, entry: *CacheEntry) void {
    // If already at head, nothing to do
    if (self.head == entry) return;

    // Remove from current position
    if (entry.prev) |prev| {
        prev.next = entry.next;
    }
    if (entry.next) |next| {
        next.prev = entry.prev;
    }
    if (self.tail == entry) {
        self.tail = entry.prev;
    }

    // Add to head
    entry.prev = null;
    entry.next = self.head;
    if (self.head) |head| {
        head.prev = entry;
    }
    self.head = entry;

    // If list was empty, set tail
    if (self.tail == null) {
        self.tail = entry;
    }
}

/// Evict the least recently used entry
fn evictLRU(self: *AnalysisCache) void {
    if (self.tail) |tail| {
        // Remove from hashmap
        _ = self.entries.remove(tail.key);

        // Remove from LRU list
        if (tail.prev) |prev| {
            prev.next = null;
            self.tail = prev;
        } else {
            // List is now empty
            self.head = null;
            self.tail = null;
        }

        // Clean up the entry
        var entry = tail;
        entry.analysis.deinit();
        self.allocator.destroy(entry);

        self.size -= 1;
        self.stats.evictions += 1;

        Log.debug("[analysis_cache] Evicted entry, cache size now: {}", .{self.size});
    }
}

/// Get or create analysis for the given bytecode
pub fn getOrAnalyze(
    self: *AnalysisCache,
    code: []const u8,
    jump_table: *const OpcodeMetadata,
) !*CodeAnalysis {
    self.mutex.lock();
    defer self.mutex.unlock();

    const key = computeKey(code);

    // Check if already in cache
    if (self.entries.get(key)) |entry| {
        // Cache hit
        self.stats.hits += 1;
        entry.ref_count += 1;
        self.moveToHead(entry);

        Log.debug("[analysis_cache] Cache hit! Hit rate: {d:.2}%", .{self.stats.hit_rate() * 100});

        return &entry.analysis;
    }

    // Cache miss - need to analyze
    self.stats.misses += 1;

    Log.debug("[analysis_cache] Cache miss. Analyzing {} bytes of code", .{code.len});

    // Perform analysis
    var analysis = try CodeAnalysis.from_code(self.allocator, code, jump_table);
    errdefer analysis.deinit();

    // Create cache entry
    var entry = try self.allocator.create(CacheEntry);
    errdefer self.allocator.destroy(entry);

    entry.* = CacheEntry{
        .analysis = analysis,
        .key = key,
        .ref_count = 1,
        .prev = null,
        .next = null,
    };

    // Check if we need to evict
    if (self.size >= self.max_size) {
        self.evictLRU();
    }

    // Add to cache
    try self.entries.put(key, entry);
    self.size += 1;

    // Add to head of LRU list
    self.moveToHead(entry);

    Log.debug("[analysis_cache] Added new entry, cache size: {}/{}", .{ self.size, self.max_size });

    return &entry.analysis;
}

/// Release a reference to an analysis (for reference counting)
pub fn release(self: *AnalysisCache, analysis: *CodeAnalysis) void {
    _ = self;
    _ = analysis;
    // For now, we don't actually remove entries on release
    // They stay in cache until evicted by LRU
    // In future, could implement reference counting for early cleanup
}

/// Clear all entries from the cache
pub fn clear(self: *AnalysisCache) void {
    self.mutex.lock();
    defer self.mutex.unlock();

    // Clean up all entries
    var iter = self.entries.iterator();
    while (iter.next()) |entry| {
        var cache_entry = entry.value_ptr.*;
        cache_entry.analysis.deinit();
        self.allocator.destroy(cache_entry);
    }

    self.entries.clearRetainingCapacity();
    self.size = 0;
    self.head = null;
    self.tail = null;

    Log.debug("[analysis_cache] Cache cleared", .{});
}

/// Get cache statistics
pub fn getStats(self: *const AnalysisCache) CacheStats {
    return self.stats;
}

/// Get current cache size
pub fn getSize(self: *const AnalysisCache) usize {
    return self.size;
}

// ============================================================================
// Tests
// ============================================================================

test "AnalysisCache - basic operations" {
    const allocator = std.testing.allocator;
    var cache = init(allocator, 3); // Small cache for testing
    defer cache.deinit();

    // Create a mock jump table
    var jump_table = OpcodeMetadata.init();

    // Test code samples
    const code1 = &[_]u8{ 0x60, 0x01, 0x60, 0x02, 0x01 }; // PUSH1 1, PUSH1 2, ADD
    const code2 = &[_]u8{ 0x60, 0x03, 0x60, 0x04, 0x01 }; // PUSH1 3, PUSH1 4, ADD
    const code3 = &[_]u8{ 0x60, 0x05, 0x60, 0x06, 0x01 }; // PUSH1 5, PUSH1 6, ADD

    // First access should be a miss
    _ = try cache.getOrAnalyze(code1, &jump_table);
    try std.testing.expectEqual(@as(u64, 0), cache.stats.hits);
    try std.testing.expectEqual(@as(u64, 1), cache.stats.misses);

    // Second access to same code should be a hit
    _ = try cache.getOrAnalyze(code1, &jump_table);
    try std.testing.expectEqual(@as(u64, 1), cache.stats.hits);
    try std.testing.expectEqual(@as(u64, 1), cache.stats.misses);

    // Different code should be a miss
    _ = try cache.getOrAnalyze(code2, &jump_table);
    try std.testing.expectEqual(@as(u64, 1), cache.stats.hits);
    try std.testing.expectEqual(@as(u64, 2), cache.stats.misses);

    // Fill cache
    _ = try cache.getOrAnalyze(code3, &jump_table);
    try std.testing.expectEqual(@as(usize, 3), cache.size);
}

test "AnalysisCache - LRU eviction" {
    const allocator = std.testing.allocator;
    var cache = init(allocator, 2); // Very small cache
    defer cache.deinit();

    var jump_table = OpcodeMetadata.init();

    const code1 = &[_]u8{ 0x60, 0x01 }; // PUSH1 1
    const code2 = &[_]u8{ 0x60, 0x02 }; // PUSH1 2
    const code3 = &[_]u8{ 0x60, 0x03 }; // PUSH1 3

    // Add two entries
    _ = try cache.getOrAnalyze(code1, &jump_table);
    _ = try cache.getOrAnalyze(code2, &jump_table);
    try std.testing.expectEqual(@as(usize, 2), cache.size);
    try std.testing.expectEqual(@as(u64, 0), cache.stats.evictions);

    // Adding third should evict the least recently used (code1)
    _ = try cache.getOrAnalyze(code3, &jump_table);
    try std.testing.expectEqual(@as(usize, 2), cache.size);
    try std.testing.expectEqual(@as(u64, 1), cache.stats.evictions);

    // code1 should now be a miss (was evicted)
    _ = try cache.getOrAnalyze(code1, &jump_table);
    try std.testing.expectEqual(@as(u64, 0), cache.stats.hits);
    try std.testing.expectEqual(@as(u64, 4), cache.stats.misses);
}

test "AnalysisCache - hit rate calculation" {
    const allocator = std.testing.allocator;
    var cache = init(allocator, 10);
    defer cache.deinit();

    var jump_table = OpcodeMetadata.init();
    const code = &[_]u8{ 0x60, 0x01 };

    // First access is a miss
    _ = try cache.getOrAnalyze(code, &jump_table);

    // Next 3 accesses are hits
    _ = try cache.getOrAnalyze(code, &jump_table);
    _ = try cache.getOrAnalyze(code, &jump_table);
    _ = try cache.getOrAnalyze(code, &jump_table);

    // Should have 3 hits, 1 miss = 75% hit rate
    const stats = cache.getStats();
    try std.testing.expectEqual(@as(u64, 3), stats.hits);
    try std.testing.expectEqual(@as(u64, 1), stats.misses);
    try std.testing.expectApproxEqAbs(@as(f64, 0.75), stats.hit_rate(), 0.001);
}

test "AnalysisCache - clear operation" {
    const allocator = std.testing.allocator;
    var cache = init(allocator, 5);
    defer cache.deinit();

    var jump_table = OpcodeMetadata.init();

    // Add some entries
    const code1 = &[_]u8{ 0x60, 0x01 };
    const code2 = &[_]u8{ 0x60, 0x02 };
    _ = try cache.getOrAnalyze(code1, &jump_table);
    _ = try cache.getOrAnalyze(code2, &jump_table);

    try std.testing.expectEqual(@as(usize, 2), cache.size);

    // Clear the cache
    cache.clear();

    try std.testing.expectEqual(@as(usize, 0), cache.size);
    try std.testing.expect(cache.head == null);
    try std.testing.expect(cache.tail == null);
}
