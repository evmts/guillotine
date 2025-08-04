const std = @import("std");
const builtin = @import("builtin");
const CodeAnalysis = @import("code_analysis.zig");

/// LRU cache for bytecode analysis results
/// 
/// Implements a Least Recently Used cache to avoid re-analyzing the same contract
/// bytecode repeatedly. Uses a doubly-linked list to track access order and a
/// hash map for O(1) lookups.
pub const AnalysisLRUCache = struct {
    const Self = @This();
    
    /// Cache entry containing analysis data and linked list pointers
    const CacheEntry = struct {
        /// Code hash (key)
        code_hash: [32]u8,
        /// Analysis result
        analysis: *CodeAnalysis,
        /// Previous entry in LRU order (null for head)
        prev: ?*CacheEntry,
        /// Next entry in LRU order (null for tail)
        next: ?*CacheEntry,
    };
    
    /// Hash map for O(1) lookup by code hash
    entries: std.AutoHashMap([32]u8, *CacheEntry),
    /// Head of LRU list (most recently used)
    head: ?*CacheEntry,
    /// Tail of LRU list (least recently used)
    tail: ?*CacheEntry,
    /// Current number of entries
    size: usize,
    /// Maximum number of entries
    max_size: usize,
    /// Allocator for memory management
    allocator: std.mem.Allocator,
    
    /// Cache size configurations for different use cases
    pub const CacheSize = enum {
        /// For embedded systems: 100 entries
        embedded,
        /// For light clients: 1,000 entries  
        light_client,
        /// For full nodes: 10,000 entries
        full_node,
        /// Custom size
        custom,
        
        pub fn getMaxSize(self: CacheSize, custom_size: ?usize) usize {
            return switch (self) {
                .embedded => 100,
                .light_client => 1000,
                .full_node => 10000,
                .custom => custom_size orelse 1000,
            };
        }
    };
    
    /// Initialize LRU cache with specified size configuration
    pub fn init(allocator: std.mem.Allocator, cache_size: CacheSize, custom_size: ?usize) Self {
        return Self{
            .entries = std.AutoHashMap([32]u8, *CacheEntry).init(allocator),
            .head = null,
            .tail = null,
            .size = 0,
            .max_size = cache_size.getMaxSize(custom_size),
            .allocator = allocator,
        };
    }
    
    /// Clean up all cache resources
    pub fn deinit(self: *Self) void {
        self.clear();
        self.entries.deinit();
    }
    
    /// Clear all entries from cache
    pub fn clear(self: *Self) void {
        var current = self.head;
        while (current) |entry| {
            const next = entry.next;
            entry.analysis.deinit(self.allocator);
            self.allocator.destroy(entry.analysis);
            self.allocator.destroy(entry);
            current = next;
        }
        self.entries.clearRetainingCapacity();
        self.head = null;
        self.tail = null;
        self.size = 0;
    }
    
    /// Get analysis from cache, updating LRU order
    pub fn get(self: *Self, code_hash: [32]u8) ?*const CodeAnalysis {
        if (self.entries.get(code_hash)) |entry| {
            // Move to front (most recently used)
            self.moveToFront(entry);
            return entry.analysis;
        }
        return null;
    }
    
    /// Put analysis into cache, evicting LRU entry if necessary
    pub fn put(self: *Self, code_hash: [32]u8, analysis: *CodeAnalysis) !void {
        // Check if entry already exists
        if (self.entries.get(code_hash)) |existing_entry| {
            // Update existing entry and move to front
            existing_entry.analysis.deinit(self.allocator);
            self.allocator.destroy(existing_entry.analysis);
            existing_entry.analysis = analysis;
            self.moveToFront(existing_entry);
            return;
        }
        
        // Create new entry
        const entry = try self.allocator.create(CacheEntry);
        errdefer self.allocator.destroy(entry);
        
        entry.* = CacheEntry{
            .code_hash = code_hash,
            .analysis = analysis,
            .prev = null,
            .next = self.head,
        };
        
        // Add to hash map
        try self.entries.put(code_hash, entry);
        errdefer _ = self.entries.remove(code_hash);
        
        // Add to front of list
        if (self.head) |old_head| {
            old_head.prev = entry;
        }
        self.head = entry;
        
        if (self.tail == null) {
            self.tail = entry;
        }
        
        self.size += 1;
        
        // Evict LRU entry if over capacity
        if (self.size > self.max_size) {
            try self.evictLRU();
        }
    }
    
    /// Move entry to front of LRU list (mark as most recently used)
    fn moveToFront(self: *Self, entry: *CacheEntry) void {
        // Already at front
        if (self.head == entry) return;
        
        // Remove from current position
        if (entry.prev) |prev| {
            prev.next = entry.next;
        }
        if (entry.next) |next| {
            next.prev = entry.prev;
        }
        
        // Update tail if this was the tail
        if (self.tail == entry) {
            self.tail = entry.prev;
        }
        
        // Move to front
        entry.prev = null;
        entry.next = self.head;
        if (self.head) |old_head| {
            old_head.prev = entry;
        }
        self.head = entry;
        
        // Update tail if this was the only entry
        if (self.tail == null) {
            self.tail = entry;
        }
    }
    
    /// Evict the least recently used entry
    fn evictLRU(self: *Self) !void {
        if (self.tail) |lru_entry| {
            // Remove from hash map
            _ = self.entries.remove(lru_entry.code_hash);
            
            // Remove from linked list
            if (lru_entry.prev) |prev| {
                prev.next = null;
                self.tail = prev;
            } else {
                // This was the only entry
                self.head = null;
                self.tail = null;
            }
            
            // Clean up memory
            lru_entry.analysis.deinit(self.allocator);
            self.allocator.destroy(lru_entry.analysis);
            self.allocator.destroy(lru_entry);
            
            self.size -= 1;
        }
    }
    
    /// Get current cache statistics
    pub fn getStats(self: *const Self) CacheStats {
        return CacheStats{
            .size = self.size,
            .max_size = self.max_size,
            .capacity = self.entries.capacity(),
        };
    }
    
    /// Cache statistics for monitoring and debugging
    pub const CacheStats = struct {
        size: usize,
        max_size: usize,
        capacity: usize,
        
        pub fn utilizationPercent(self: CacheStats) f64 {
            if (self.max_size == 0) return 0.0;
            return @as(f64, @floatFromInt(self.size)) / @as(f64, @floatFromInt(self.max_size)) * 100.0;
        }
    };
};

// Compile-time configuration for cache inclusion
pub const AnalysisCacheConfig = struct {
    /// Whether to include the LRU cache (disabled when optimizing for size)
    pub const ENABLE_CACHE = builtin.mode != .ReleaseSmall;
        
    /// Default cache size based on build mode
    pub const DEFAULT_CACHE_SIZE = switch (builtin.mode) {
        .Debug => AnalysisLRUCache.CacheSize.light_client,
        .ReleaseSafe => AnalysisLRUCache.CacheSize.light_client,
        .ReleaseFast => AnalysisLRUCache.CacheSize.full_node,
        .ReleaseSmall => AnalysisLRUCache.CacheSize.embedded, // Smallest cache for size optimization
    };
};

test "AnalysisLRUCache basic functionality" {
    const allocator = std.testing.allocator;
    
    var cache = AnalysisLRUCache.init(allocator, .embedded, null);
    defer cache.deinit();
    
    // Test empty cache
    const hash1 = [_]u8{1} ** 32;
    try std.testing.expectEqual(@as(?*const CodeAnalysis, null), cache.get(hash1));
    
    // Create mock analysis
    const analysis1 = try allocator.create(CodeAnalysis);
    analysis1.* = CodeAnalysis{
        .code_segments = try @import("bitvec.zig").BitVec64.init(allocator, 0),
        .jumpdest_bitmap = try @import("bitvec.zig").BitVec64.init(allocator, 0),
        .block_gas_costs = null,
        .max_stack_depth = 10,
        .has_dynamic_jumps = false,
        .has_static_jumps = true,
        .has_selfdestruct = false,
        .has_create = false,
    };
    
    // Test put and get
    try cache.put(hash1, analysis1);
    try std.testing.expectEqual(@as(usize, 1), cache.size);
    
    const retrieved = cache.get(hash1);
    try std.testing.expect(retrieved != null);
    try std.testing.expectEqual(@as(u16, 10), retrieved.?.max_stack_depth);
}

test "AnalysisLRUCache LRU eviction" {
    const allocator = std.testing.allocator;
    
    var cache = AnalysisLRUCache.init(allocator, .custom, 2);
    defer cache.deinit();
    
    // Create mock analyses
    const analysis1 = try allocator.create(CodeAnalysis);
    analysis1.* = CodeAnalysis{
        .code_segments = try @import("bitvec.zig").BitVec64.init(allocator, 0),
        .jumpdest_bitmap = try @import("bitvec.zig").BitVec64.init(allocator, 0),
        .block_gas_costs = null,
        .max_stack_depth = 1,
        .has_dynamic_jumps = false,
        .has_static_jumps = false,
        .has_selfdestruct = false,
        .has_create = false,
    };
    
    const analysis2 = try allocator.create(CodeAnalysis);
    analysis2.* = CodeAnalysis{
        .code_segments = try @import("bitvec.zig").BitVec64.init(allocator, 0),
        .jumpdest_bitmap = try @import("bitvec.zig").BitVec64.init(allocator, 0),
        .block_gas_costs = null,
        .max_stack_depth = 2,
        .has_dynamic_jumps = false,
        .has_static_jumps = false,
        .has_selfdestruct = false,
        .has_create = false,
    };
    
    const analysis3 = try allocator.create(CodeAnalysis);
    analysis3.* = CodeAnalysis{
        .code_segments = try @import("bitvec.zig").BitVec64.init(allocator, 0),
        .jumpdest_bitmap = try @import("bitvec.zig").BitVec64.init(allocator, 0),
        .block_gas_costs = null,
        .max_stack_depth = 3,
        .has_dynamic_jumps = false,
        .has_static_jumps = false,
        .has_selfdestruct = false,
        .has_create = false,
    };
    
    const hash1 = [_]u8{1} ** 32;
    const hash2 = [_]u8{2} ** 32;
    const hash3 = [_]u8{3} ** 32;
    
    // Fill cache to capacity
    try cache.put(hash1, analysis1);
    try cache.put(hash2, analysis2);
    try std.testing.expectEqual(@as(usize, 2), cache.size);
    
    // Access first entry to make it MRU
    _ = cache.get(hash1);
    
    // Add third entry, should evict hash2 (LRU)
    try cache.put(hash3, analysis3);
    try std.testing.expectEqual(@as(usize, 2), cache.size);
    
    // hash1 and hash3 should be present, hash2 should be evicted
    try std.testing.expect(cache.get(hash1) != null);
    try std.testing.expect(cache.get(hash3) != null);
    try std.testing.expect(cache.get(hash2) == null);
}

test "AnalysisLRUCache statistics" {
    const allocator = std.testing.allocator;
    
    var cache = AnalysisLRUCache.init(allocator, .light_client, null);
    defer cache.deinit();
    
    const stats = cache.getStats();
    try std.testing.expectEqual(@as(usize, 0), stats.size);
    try std.testing.expectEqual(@as(usize, 1000), stats.max_size);
    try std.testing.expectEqual(0.0, stats.utilizationPercent());
}