const std = @import("std");
const Instruction = @import("instruction.zig").Instruction;
const CodeAnalysis = @import("analysis.zig").CodeAnalysis;

/// Metrics collected during block-based execution.
/// Helps with performance analysis and optimization.
pub const BlockExecutionMetrics = struct {
    /// Total instructions executed
    instructions_executed: u64 = 0,
    
    /// Number of basic blocks executed
    blocks_executed: u64 = 0,
    
    /// Number of jump operations
    jumps_taken: u64 = 0,
    
    /// Number of conditional jumps (JUMPI)
    conditional_jumps: u64 = 0,
    
    /// Number of conditional jumps that were taken
    conditional_jumps_taken: u64 = 0,
    
    /// Total gas consumed
    gas_consumed: u64 = 0,
    
    /// Maximum stack depth reached
    max_stack_depth: u16 = 0,
    
    /// Memory expansion count
    memory_expansions: u32 = 0,
    
    /// Storage operations (SLOAD/SSTORE)
    storage_operations: u32 = 0,
    
    /// Time spent in instruction translation (nanoseconds)
    translation_time_ns: u64 = 0,
    
    /// Time spent in execution (nanoseconds)
    execution_time_ns: u64 = 0,
    
    /// Number of cache hits (for repeated block execution)
    cache_hits: u64 = 0,
    
    /// Number of cache misses
    cache_misses: u64 = 0,
    
    pub fn init() BlockExecutionMetrics {
        return .{};
    }
    
    /// Record a jump operation
    pub fn record_jump(self: *BlockExecutionMetrics, is_conditional: bool, taken: bool) void {
        if (is_conditional) {
            self.conditional_jumps += 1;
            if (taken) {
                self.conditional_jumps_taken += 1;
                self.jumps_taken += 1;
            }
        } else {
            self.jumps_taken += 1;
        }
    }
    
    /// Record instruction execution
    pub fn record_instruction(self: *BlockExecutionMetrics) void {
        self.instructions_executed += 1;
    }
    
    /// Record block execution
    pub fn record_block(self: *BlockExecutionMetrics, instruction_count: u32) void {
        self.blocks_executed += 1;
        self.instructions_executed += instruction_count;
    }
    
    /// Update maximum stack depth if current is higher
    pub fn update_max_stack(self: *BlockExecutionMetrics, current_depth: u16) void {
        if (current_depth > self.max_stack_depth) {
            self.max_stack_depth = current_depth;
        }
    }
    
    /// Print metrics summary
    pub fn print_summary(self: *const BlockExecutionMetrics) void {
        std.log.info("Block Execution Metrics:", .{});
        std.log.info("  Instructions executed: {}", .{self.instructions_executed});
        std.log.info("  Blocks executed: {}", .{self.blocks_executed});
        if (self.blocks_executed > 0) {
            const avg_block_size = self.instructions_executed / self.blocks_executed;
            std.log.info("  Average block size: {}", .{avg_block_size});
        }
        std.log.info("  Jumps taken: {}", .{self.jumps_taken});
        if (self.conditional_jumps > 0) {
            const branch_taken_pct = (self.conditional_jumps_taken * 100) / self.conditional_jumps;
            std.log.info("  Conditional jumps: {} ({d:.1}% taken)", .{ 
                self.conditional_jumps, 
                @as(f64, @floatFromInt(branch_taken_pct)) 
            });
        }
        std.log.info("  Max stack depth: {}", .{self.max_stack_depth});
        std.log.info("  Gas consumed: {}", .{self.gas_consumed});
        
        if (self.translation_time_ns > 0) {
            const translation_ms = @as(f64, @floatFromInt(self.translation_time_ns)) / 1_000_000.0;
            std.log.info("  Translation time: {d:.3}ms", .{translation_ms});
        }
        
        if (self.execution_time_ns > 0) {
            const execution_ms = @as(f64, @floatFromInt(self.execution_time_ns)) / 1_000_000.0;
            std.log.info("  Execution time: {d:.3}ms", .{execution_ms});
            
            if (self.instructions_executed > 0) {
                const ns_per_instruction = self.execution_time_ns / self.instructions_executed;
                std.log.info("  Time per instruction: {}ns", .{ns_per_instruction});
            }
        }
        
        if (self.cache_hits + self.cache_misses > 0) {
            const hit_rate = (self.cache_hits * 100) / (self.cache_hits + self.cache_misses);
            std.log.info("  Cache hit rate: {}%", .{hit_rate});
        }
    }
    
    /// Compare with baseline metrics to show improvement
    pub fn compare_with(self: *const BlockExecutionMetrics, baseline: *const BlockExecutionMetrics) void {
        std.log.info("Performance Comparison:", .{});
        
        if (baseline.execution_time_ns > 0 and self.execution_time_ns > 0) {
            const speedup = @as(f64, @floatFromInt(baseline.execution_time_ns)) / 
                          @as(f64, @floatFromInt(self.execution_time_ns));
            std.log.info("  Speedup: {d:.2}x", .{speedup});
        }
        
        if (baseline.instructions_executed > 0 and self.instructions_executed > 0) {
            const instruction_reduction = if (baseline.instructions_executed > self.instructions_executed)
                baseline.instructions_executed - self.instructions_executed
            else
                0;
            
            if (instruction_reduction > 0) {
                const reduction_pct = (instruction_reduction * 100) / baseline.instructions_executed;
                std.log.info("  Instruction reduction: {} ({d:.1}%)", .{
                    instruction_reduction,
                    @as(f64, @floatFromInt(reduction_pct))
                });
            }
        }
        
        if (baseline.gas_consumed > 0 and self.gas_consumed > 0) {
            if (baseline.gas_consumed > self.gas_consumed) {
                const gas_saved = baseline.gas_consumed - self.gas_consumed;
                const gas_saved_pct = (gas_saved * 100) / baseline.gas_consumed;
                std.log.info("  Gas saved: {} ({d:.1}%)", .{
                    gas_saved,
                    @as(f64, @floatFromInt(gas_saved_pct))
                });
            }
        }
    }
};

/// Instruction-level metrics for fine-grained analysis
pub const InstructionMetrics = struct {
    /// Opcode being executed
    opcode: u8,
    
    /// Gas cost for this instruction
    gas_cost: u32,
    
    /// Stack items consumed
    stack_consumed: u8,
    
    /// Stack items produced
    stack_produced: u8,
    
    /// Memory bytes accessed
    memory_accessed: u32,
    
    /// Whether this is a jump instruction
    is_jump: bool,
    
    /// Whether this is a block terminator
    is_terminator: bool,
};

/// Cache for translated instruction blocks
pub const BlockCache = struct {
    const CacheEntry = struct {
        code_hash: [32]u8,
        instructions: []Instruction,
        metrics: CodeAnalysis.BlockMetadata,
        last_accessed: u64,
        access_count: u64,
    };
    
    allocator: std.mem.Allocator,
    entries: std.AutoHashMap([32]u8, CacheEntry),
    max_entries: usize,
    current_time: u64,
    
    pub fn init(allocator: std.mem.Allocator, max_entries: usize) BlockCache {
        return .{
            .allocator = allocator,
            .entries = std.AutoHashMap([32]u8, CacheEntry).init(allocator),
            .max_entries = max_entries,
            .current_time = 0,
        };
    }
    
    pub fn deinit(self: *BlockCache) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.instructions);
        }
        self.entries.deinit();
    }
    
    /// Get cached instructions for a code hash
    pub fn get(self: *BlockCache, code_hash: [32]u8) ?[]Instruction {
        self.current_time += 1;
        
        if (self.entries.getPtr(code_hash)) |entry| {
            entry.last_accessed = self.current_time;
            entry.access_count += 1;
            return entry.instructions;
        }
        
        return null;
    }
    
    /// Store translated instructions in cache
    pub fn put(
        self: *BlockCache,
        code_hash: [32]u8,
        instructions: []const Instruction,
        metrics: CodeAnalysis.BlockMetadata,
    ) !void {
        // If cache is full, evict least recently used
        if (self.entries.count() >= self.max_entries) {
            var lru_hash: ?[32]u8 = null;
            var lru_time: u64 = std.math.maxInt(u64);
            
            var it = self.entries.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.last_accessed < lru_time) {
                    lru_time = entry.value_ptr.last_accessed;
                    lru_hash = entry.key_ptr.*;
                }
            }
            
            if (lru_hash) |hash| {
                if (self.entries.fetchRemove(hash)) |removed| {
                    self.allocator.free(removed.value.instructions);
                }
            }
        }
        
        // Copy instructions to cache
        const cached_instructions = try self.allocator.dupe(Instruction, instructions);
        
        self.current_time += 1;
        try self.entries.put(code_hash, .{
            .code_hash = code_hash,
            .instructions = cached_instructions,
            .metrics = metrics,
            .last_accessed = self.current_time,
            .access_count = 1,
        });
    }
    
    /// Get cache statistics
    pub fn get_stats(self: *const BlockCache) CacheStats {
        var total_accesses: u64 = 0;
        var total_size: usize = 0;
        
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            total_accesses += entry.value_ptr.access_count;
            total_size += entry.value_ptr.instructions.len * @sizeOf(Instruction);
        }
        
        return .{
            .entry_count = self.entries.count(),
            .total_accesses = total_accesses,
            .memory_used = total_size,
            .hit_rate = 0, // Calculated externally
        };
    }
};

pub const CacheStats = struct {
    entry_count: usize,
    total_accesses: u64,
    memory_used: usize,
    hit_rate: f32,
};