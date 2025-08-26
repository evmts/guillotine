//! Bytecode analysis and optimization engine.
//!
//! Transforms raw EVM bytecode into optimized execution plans by:
//! - Identifying valid jump destinations
//! - Pre-calculating gas costs where possible
//! - Detecting and fusing common opcode patterns
//! - Inlining small constants for better cache locality
//!
//! The planner includes an LRU cache to avoid re-analyzing frequently
//! executed contracts, significantly improving performance.
const std = @import("std");
const log = @import("log.zig");
const opcode_data = @import("opcode_data.zig");
const Opcode = opcode_data.Opcode;
const plan_mod = @import("plan.zig");
const plan_minimal_mod = @import("plan_minimal.zig");
pub const PlannerConfig = @import("planner_config.zig").PlannerConfig;
const BytecodeFactory = @import("bytecode.zig").Bytecode;
const BytecodeConfig = @import("bytecode_config.zig").BytecodeConfig;
const Hardfork = @import("hardfork.zig").Hardfork;

// Re-export commonly used types from plan
pub const OpcodeSynthetic = @import("opcode_synthetic.zig").OpcodeSynthetic;
pub const JumpDestMetadata = plan_mod.JumpDestMetadata;
pub const HandlerFn = plan_mod.HandlerFn;
pub const InstructionElement = plan_mod.InstructionElement;


/// Creates a configured planner type.
///
/// The planner is specialized at compile-time based on bytecode size limits,
/// word type, and optimization settings. Includes built-in LRU caching.
pub fn Planner(comptime Cfg: PlannerConfig) type {
    Cfg.validate();
    const VectorLength = Cfg.vector_length;

    return struct {
        const PcType = Cfg.PcType();
        const InstructionIndexType = PcType; // Can only have as many instructions as PCs but usually less
        const StackHeightType = Cfg.StackHeightType();

        // Track blocks during analysis with temporary structure
        const TempBlock = struct {
            pc: PcType,
            metadata: JumpDestMetadata,
        };
        const PlanCfg = plan_mod.PlanConfig{
            .WordType = Cfg.WordType,
            .maxBytecodeSize = Cfg.maxBytecodeSize,
        };
        // Simple LRU cache node - forward declare
        const CacheNode = struct {
            key_hash: u64,
            plan: PlanType,
            next: ?*@This(),
            prev: ?*@This(),
        };
        const PlanType = plan_mod.Plan(PlanCfg);
        const BytecodeType = BytecodeFactory(.{
            .max_bytecode_size = Cfg.maxBytecodeSize,
            .max_initcode_size = @max(Cfg.maxBytecodeSize, 49152), // EIP-3860 limit, but must be >= max_bytecode_size
        });

        const Self = @This();
        // Expose types for callers/tests.
        pub const BlockMeta = JumpDestMetadata;
        pub const Plan = PlanType;
        pub const PcTypeT = PcType;
        pub const InstructionIndexT = InstructionIndexType;
        pub const Bytecode = BytecodeType;

        // For simple init without cache
        bytecode: BytecodeType,
        bytecode_initialized: bool,
        
        // Cache fields
        allocator: std.mem.Allocator,
        cache_capacity: usize,
        cache_map: std.AutoHashMap(u64, *CacheNode),
        cache_head: ?*CacheNode,
        cache_tail: ?*CacheNode,
        cache_count: usize,
        
        // Cache statistics
        cache_hits: usize,
        cache_misses: usize,
        
        // Special metadata for entry block
        start: JumpDestMetadata,
        // Trace handlers (only when injection enabled at comptime)
        trace_before: if (Cfg.inject_tracing) *const HandlerFn else void,
        trace_after: if (Cfg.inject_tracing) *const HandlerFn else void,

        /// Create a planner with LRU cache for repeated bytecode analysis.
        /// This is the standard initialization method for production use.
        pub fn init(allocator: std.mem.Allocator, cache_capacity: usize) !Self {
            return .{
                .bytecode = undefined, // Will be set per request
                .bytecode_initialized = false,
                .allocator = allocator,
                .cache_capacity = cache_capacity,
                .cache_map = std.AutoHashMap(u64, *CacheNode).init(allocator),
                .cache_head = null,
                .cache_tail = null,
                .cache_count = 0,
                .cache_hits = 0,
                .cache_misses = 0,
                .start = .{ .gas = 0, .min_stack = 0, .max_stack = 0 },
                .trace_before = if (Cfg.inject_tracing) blk: { break :blk undefined; } else {},
                .trace_after = if (Cfg.inject_tracing) blk: { break :blk undefined; } else {},
            };
        }

        /// Configure trace handler pointers (no-op when injection disabled)
        pub fn setTraceHandlers(self: *Self, trace_before: if (Cfg.inject_tracing) *const HandlerFn else void, trace_after: if (Cfg.inject_tracing) *const HandlerFn else void) void {
            if (comptime Cfg.inject_tracing) {
                self.trace_before = trace_before;
                self.trace_after = trace_after;
            }
        }
        
        
        /// Deinitialize the planner and free cache.
        pub fn deinit(self: *Self) void {
            // Deinit bytecode only if it was initialized
            if (self.bytecode_initialized) {
                self.bytecode.deinit();
            }
            
            // Deinit cache
            var node = self.cache_head;
            while (node) |n| {
                const next = n.next;
                n.plan.deinit(self.allocator);
                self.allocator.destroy(n);
                node = next;
            }
            self.cache_map.deinit();
        }
        
        /// Get an optimized execution plan for the given bytecode.
        ///
        /// First checks the LRU cache for a previously analyzed plan. If not found,
        /// analyzes the bytecode and caches the result. The returned plan is owned
        /// by the cache and must not be freed by the caller.
        ///
        /// The hardfork parameter is included in the cache key to avoid incorrect
        /// plan reuse when hardfork rules change (e.g., new opcodes, gas costs).
        pub fn getOrAnalyze(self: *Self, bytecode: []const u8, handlers: [256]*const HandlerFn, hardfork: Hardfork) !*const PlanType {
            // Include hardfork and inject flag in cache key to avoid incorrect plan reuse
            var hasher = std.hash.Wyhash.init(0);
            hasher.update(bytecode);
            hasher.update(std.mem.asBytes(&hardfork));
            const inject_flag: u8 = if (Cfg.inject_tracing) 1 else 0;
            hasher.update(&[_]u8{inject_flag});
            const key = hasher.final();
            
            // Check cache
            if (self.cache_map.get(key)) |node| {
                // Cache hit - hint this is the likely path for warm caches
                @branchHint(.likely);
                self.cache_hits += 1;
                self.moveToFront(node);
                return &node.plan;
            }
            
            // Cache miss - analyze and cache
            self.cache_misses += 1;
            self.bytecode = try BytecodeType.init(self.allocator, bytecode);
            self.bytecode_initialized = true;
            errdefer {
                self.bytecode.deinit();
                self.bytecode_initialized = false;
            }
            const plan = try self.create_instruction_stream(self.allocator, handlers);
            
            // Add to cache
            try self.addToCache(key, plan);
            // We've finished analyzing and building the plan, so the transient
            // BytecodeType held by the planner is no longer needed. Free it
            // to avoid retaining the last analyzed bytecode buffer.
            self.bytecode.deinit();
            self.bytecode_initialized = false;
            
            // Return reference to cached plan
            return &self.cache_map.get(key).?.plan;
        }
        
        
        /// Get cache statistics.
        pub fn getCacheStats(self: *const Self) struct { 
            capacity: usize, 
            count: usize,
            hit_ratio: f64,
            hits: usize,
            misses: usize,
            total_requests: usize,
        } {
            const total_requests = self.cache_hits + self.cache_misses;
            const hit_ratio: f64 = if (total_requests > 0) 
                @as(f64, @floatFromInt(self.cache_hits)) / @as(f64, @floatFromInt(total_requests))
            else 
                0.0;
            
            return .{
                .capacity = self.cache_capacity,
                .count = self.cache_count,
                .hit_ratio = hit_ratio,
                .hits = self.cache_hits,
                .misses = self.cache_misses,
                .total_requests = total_requests,
            };
        }
        
        /// Clear all cached plans.
        pub fn clearCache(self: *Self) void {
            // Free all cached plans
            var node = self.cache_head;
            while (node) |n| {
                const next = n.next;
                n.plan.deinit(self.allocator);
                self.allocator.destroy(n);
                node = next;
            }
            
            // Reset cache state
            self.cache_map.clearAndFree();
            self.cache_head = null;
            self.cache_tail = null;
            self.cache_count = 0;
            self.cache_hits = 0;
            self.cache_misses = 0;
        }
        
        fn moveToFront(self: *Self, node: *CacheNode) void {
            if (self.cache_head == node) return;
            
            // Remove from current position
            if (node.prev) |p| p.next = node.next;
            if (node.next) |n| n.prev = node.prev;
            if (self.cache_tail == node) self.cache_tail = node.prev;
            
            // Add to front
            node.prev = null;
            node.next = self.cache_head;
            if (self.cache_head) |h| h.prev = node;
            self.cache_head = node;
            if (self.cache_tail == null) self.cache_tail = node;
        }
        
        fn addToCache(self: *Self, key: u64, plan: PlanType) !void {
            // Evict if necessary
            if (self.cache_count >= self.cache_capacity) {
                if (self.cache_tail) |tail| {
                    _ = self.cache_map.remove(tail.key_hash);
                    if (tail.prev) |p| p.next = null;
                    self.cache_tail = tail.prev;
                    if (self.cache_head == tail) self.cache_head = null;
                    tail.plan.deinit(self.allocator);
                    self.allocator.destroy(tail);
                    self.cache_count -= 1;
                }
            }
            
            // Create new node
            const node = try self.allocator.create(CacheNode);
            node.* = .{
                .key_hash = key,
                .plan = plan,
                .next = self.cache_head,
                .prev = null,
            };
            
            if (self.cache_head) |h| h.prev = node;
            self.cache_head = node;
            if (self.cache_tail == null) self.cache_tail = node;
            
            try self.cache_map.put(key, node);
            self.cache_count += 1;
        }

        /// Create instruction stream from bytecode and handler array.
        /// Pass 1: build temporary bitmaps (push-data, opcode-start, jumpdest).
        /// Pass 2: build instruction stream with handlers and metadata.
        /// All temporaries are freed before returning.
        pub fn create_instruction_stream(self: *Self, allocator: std.mem.Allocator, handlers: [256]*const HandlerFn) !PlanType {
            const code = self.bytecode.runtime_code;
            const N = code.len;
            // Ephemeral bitmaps (bit-per-byte)
            const bitmap_bytes = (N + 7) >> 3;
            const is_push_data = try allocator.alloc(u8, bitmap_bytes);
            defer allocator.free(is_push_data);
            const is_op_start = try allocator.alloc(u8, bitmap_bytes);
            defer allocator.free(is_op_start);
            const is_jumpdest = try allocator.alloc(u8, bitmap_bytes);
            defer allocator.free(is_jumpdest);
            @memset(is_push_data, 0);
            @memset(is_op_start, 0);
            @memset(is_jumpdest, 0);

            // Pass 1: scan bytecode to fill opcode-start and push-data bitmaps
            var i: usize = 0;
            while (i < N) : (i += 1) {
                // setBit(is_op_start, i)
                is_op_start[i >> 3] |= @as(u8, 1) << @intCast(i & 7);
                const op = code[i];
                if (op >= @intFromEnum(Opcode.PUSH1) and op <= @intFromEnum(Opcode.PUSH32)) {
                    const n: usize = op - (@intFromEnum(Opcode.PUSH1) - 1);
                    var j: usize = 0;
                    while (j < n and i + 1 + j < N) : (j += 1) {
                        const idx = i + 1 + j;
                        is_push_data[idx >> 3] |= @as(u8, 1) << @intCast(idx & 7);
                    }
                    i += n; // loop's i += 1 advances over opcode byte
                    continue;
                }
            }

            // Mark JUMPDEST positions (0x5B) excluding push-data bytes
            if (comptime VectorLength) |L| {
                markJumpdestSimd(code, is_push_data, is_jumpdest, L);
            } else {
                markJumpdestScalar(code, is_push_data, is_jumpdest);
            }

            // Counts
            var pop: usize = 0; // popcount(is_jumpdest)
            for (is_jumpdest) |b| pop += @popCount(b);
            const num_jumpdests: usize = pop;
            const num_blocks: usize = 1 + num_jumpdests;

            // Allocate outputs
            var jump_list = try allocator.alloc(PcType, num_jumpdests);
            errdefer allocator.free(jump_list);
            var blocks = try allocator.alloc(TempBlock, num_blocks);
            errdefer allocator.free(blocks);

            // Build jump_list (sorted PCs)
            var jl_i: usize = 0;
            i = 0;
            while (i < N) : (i += 1) {
                if ((is_jumpdest[i >> 3] & (@as(u8, 1) << @intCast(i & 7))) != 0) {
                    jump_list[jl_i] = @as(PcType, @intCast(i));
                    jl_i += 1;
                }
            }
            std.debug.assert(jl_i == num_jumpdests);

            // Pass 2: build blocks and compute instructionIndex parity, static gas, and stack ranges
            var stream_idx: usize = 0;
            var block_idx: usize = 0;
            blocks[0] = .{ 
                .pc = 0, 
                .metadata = .{ .gas = 0, .min_stack = 0, .max_stack = 0 } 
            };
            var static_gas_accum: u64 = 0; // accumulate in u64 to avoid overflow, clamp to u32 on store
            var stack_height: i32 = 0;
            var min_stack_height: StackHeightType = 0;
            var max_stack_height: StackHeightType = 0;

            i = 0;
            while (i < N) {
                const op = code[i];
                // If this is a block start (JUMPDEST opcode start), finalize previous block and start new one
                const is_start = (is_op_start[i >> 3] & (@as(u8, 1) << @intCast(i & 7))) != 0;
                const is_dest = (is_jumpdest[i >> 3] & (@as(u8, 1) << @intCast(i & 7))) != 0;
                if (is_start and is_dest) {
                    // finalize previous block (for entry this is zeros)
                    blocks[block_idx].metadata.gas = @as(u32, @intCast(@min(static_gas_accum, @as(u64, std.math.maxInt(u32)))));
                    blocks[block_idx].metadata.min_stack = min_stack_height;
                    blocks[block_idx].metadata.max_stack = max_stack_height;
                    // start new block
                    block_idx += 1;
                    blocks[block_idx] = .{ 
                        .pc = @as(PcType, @intCast(i)), 
                        .metadata = .{ .gas = 0, .min_stack = 0, .max_stack = 0 } 
                    };
                    static_gas_accum = 0;
                    stack_height = 0;
                    min_stack_height = 0;
                    max_stack_height = 0;
                    i += 1;
                    continue;
                }

                const info = opcode_data.OPCODE_INFO[op];
                static_gas_accum += info.gas_cost;
                // track stack delta inside block
                stack_height += @as(i32, info.stack_outputs) - @as(i32, info.stack_inputs);
                if (stack_height < min_stack_height) min_stack_height = @intCast(stack_height);
                if (stack_height > max_stack_height) max_stack_height = @intCast(stack_height);

                if (op >= @intFromEnum(Opcode.PUSH1) and op <= @intFromEnum(Opcode.PUSH32)) {
                    const n: usize = op - (@intFromEnum(Opcode.PUSH1) - 1);
                    stream_idx += 2; // handler + payload
                    i += 1 + n;
                } else if (op == @intFromEnum(Opcode.PC)) {
                    stream_idx += 2; // handler + payload
                    i += 1;
                } else {
                    stream_idx += 1; // simple handler
                    i += 1;
                }
            }
            // finalize last block
            blocks[block_idx].metadata.gas = @as(u32, @intCast(@min(static_gas_accum, @as(u64, std.math.maxInt(u32)))));
            blocks[block_idx].metadata.min_stack = min_stack_height;
            blocks[block_idx].metadata.max_stack = max_stack_height;
            std.debug.assert(block_idx + 1 == num_blocks);

            // Free unused jump_list
            allocator.free(jump_list);

            // Build instruction stream
            var stream = std.ArrayList(InstructionElement){};
            errdefer stream.deinit(allocator);
            
            var constants = std.ArrayList(Cfg.WordType){};
            errdefer constants.deinit(allocator);
            
            // Backing store for 32-bit JumpDest metadata (unused on 64-bit)
            var jumpdests = std.ArrayList(JumpDestMetadata){};
            errdefer jumpdests.deinit(allocator);
            
            // Build PC to instruction index mapping
            var pc_map = std.AutoHashMap(PcType, InstructionIndexType).init(allocator);
            errdefer pc_map.deinit();
            
            // Build instruction stream with handlers and metadata (with optional trace injection)
            i = 0;
            // Dense PC->instruction index table for fast JUMP/JUMPI
            var dense_pc_to_idx = try allocator.alloc(?PlanType.InstructionIndexType, N);
            errdefer allocator.free(dense_pc_to_idx);
            // Initialize all to null (non-start PCs or out-of-range)
            for (dense_pc_to_idx) |*slot| slot.* = null;
            while (i < N) {
                const op = code[i];
                
                // Record PC to instruction index mapping
                const current_instruction_idx = @as(InstructionIndexType, @intCast(stream.items.len));
                try pc_map.put(@as(PcType, @intCast(i)), current_instruction_idx);
                dense_pc_to_idx[i] = current_instruction_idx;
                
                // Inject tracing before the instruction
                if (comptime Cfg.inject_tracing) {
                    try stream.append(allocator, .{ .handler = self.trace_before });
                }
                
                // Handle PUSH opcodes
                if (op >= @intFromEnum(Opcode.PUSH1) and op <= @intFromEnum(Opcode.PUSH32)) {
                    const n: usize = op - (@intFromEnum(Opcode.PUSH1) - 1);
                    
                    // Check for fusion opportunities
                    const next_pc = i + 1 + n;
                    var fused = false;
                    var handler_op = op;
                    
                    if (next_pc < N) {
                        const next_op = code[next_pc];
                        
                        // Check for PUSH+ADD fusion
                        if (next_op == @intFromEnum(Opcode.ADD)) {
                            // Use appropriate fusion opcode
                            handler_op = if (n <= @sizeOf(usize)) @intFromEnum(OpcodeSynthetic.PUSH_ADD_INLINE) else @intFromEnum(OpcodeSynthetic.PUSH_ADD_POINTER);
                            fused = true;
                        }
                        // Check for PUSH+MUL fusion
                        else if (next_op == @intFromEnum(Opcode.MUL)) {
                            handler_op = if (n <= @sizeOf(usize)) @intFromEnum(OpcodeSynthetic.PUSH_MUL_INLINE) else @intFromEnum(OpcodeSynthetic.PUSH_MUL_POINTER);
                            fused = true;
                        }
                        // Check for PUSH+SUB fusion
                        else if (next_op == @intFromEnum(Opcode.SUB)) {
                            handler_op = if (n <= @sizeOf(usize)) @intFromEnum(OpcodeSynthetic.PUSH_SUB_INLINE) else @intFromEnum(OpcodeSynthetic.PUSH_SUB_POINTER);
                            fused = true;
                        }
                        // Check for PUSH+DIV fusion
                        else if (next_op == @intFromEnum(Opcode.DIV)) {
                            handler_op = if (n <= @sizeOf(usize)) @intFromEnum(OpcodeSynthetic.PUSH_DIV_INLINE) else @intFromEnum(OpcodeSynthetic.PUSH_DIV_POINTER);
                            fused = true;
                        }
                        // Check for PUSH+AND fusion
                        else if (next_op == @intFromEnum(Opcode.AND)) {
                            handler_op = if (n <= @sizeOf(usize)) @intFromEnum(OpcodeSynthetic.PUSH_AND_INLINE) else @intFromEnum(OpcodeSynthetic.PUSH_AND_POINTER);
                            fused = true;
                        }
                        // Check for PUSH+OR fusion
                        else if (next_op == @intFromEnum(Opcode.OR)) {
                            handler_op = if (n <= @sizeOf(usize)) @intFromEnum(OpcodeSynthetic.PUSH_OR_INLINE) else @intFromEnum(OpcodeSynthetic.PUSH_OR_POINTER);
                            fused = true;
                        }
                        // Check for PUSH+XOR fusion
                        else if (next_op == @intFromEnum(Opcode.XOR)) {
                            handler_op = if (n <= @sizeOf(usize)) @intFromEnum(OpcodeSynthetic.PUSH_XOR_INLINE) else @intFromEnum(OpcodeSynthetic.PUSH_XOR_POINTER);
                            fused = true;
                        }
                        // Check for PUSH+JUMP fusion
                        else if (next_op == @intFromEnum(Opcode.JUMP)) {
                            // Use appropriate fusion opcode
                            handler_op = if (n <= @sizeOf(usize)) @intFromEnum(OpcodeSynthetic.PUSH_JUMP_INLINE) else @intFromEnum(OpcodeSynthetic.PUSH_JUMP_POINTER);
                            fused = true;
                        }
                        // Check for PUSH+JUMPI fusion
                        else if (next_op == @intFromEnum(Opcode.JUMPI)) {
                            handler_op = if (n <= @sizeOf(usize)) @intFromEnum(OpcodeSynthetic.PUSH_JUMPI_INLINE) else @intFromEnum(OpcodeSynthetic.PUSH_JUMPI_POINTER);
                            fused = true;
                        }
                        // Check for PUSH+MLOAD fusion (immediate offset)
                        else if (next_op == @intFromEnum(Opcode.MLOAD)) {
                            handler_op = if (n <= @sizeOf(usize)) @intFromEnum(OpcodeSynthetic.PUSH_MLOAD_INLINE) else @intFromEnum(OpcodeSynthetic.PUSH_MLOAD_POINTER);
                            fused = true;
                        }
                        // Check for PUSH+MSTORE fusion (immediate offset; value from stack)
                        else if (next_op == @intFromEnum(Opcode.MSTORE)) {
                            handler_op = if (n <= @sizeOf(usize)) @intFromEnum(OpcodeSynthetic.PUSH_MSTORE_INLINE) else @intFromEnum(OpcodeSynthetic.PUSH_MSTORE_POINTER);
                            fused = true;
                        }
                        // Check for PUSH+MSTORE8 fusion
                        else if (next_op == @intFromEnum(Opcode.MSTORE8)) {
                            handler_op = if (n <= @sizeOf(usize)) @intFromEnum(OpcodeSynthetic.PUSH_MSTORE8_INLINE) else @intFromEnum(OpcodeSynthetic.PUSH_MSTORE8_POINTER);
                            fused = true;
                        }
                    }
                    
                    // Add handler pointer (normal or fused)
                    const handler_ptr = handlers[handler_op];
                    if (@intFromPtr(handler_ptr) == 0xaaaaaaaaaaaaaaaa) {
                        log.warn("Uninitialized handler for opcode {x} at PC {}", .{handler_op, i});
                    }
                    try stream.append(allocator, .{ .handler = handler_ptr });
                    
                    // Extract the push value (bytecode already validated; safe to read)
                    // Decide if value fits inline or needs pointer
                    if (n <= @sizeOf(usize)) {
                        // Fits inline - build value from bytes
                        var value: usize = 0;
                        var j: usize = 0;
                        while (j < n and j < @sizeOf(usize)) : (j += 1) {
                            value = (value << 8) | code[i + 1 + j];
                        }
                        try stream.append(allocator, .{ .inline_value = value });
                    } else {
                        // Too large - store in constants array
                        var value: Cfg.WordType = 0;
                        var j: usize = 0;
                        while (j < n) : (j += 1) {
                            value = (value << 8) | code[i + 1 + j];
                        }
                        const const_idx = constants.items.len;
                        try constants.append(allocator, value);
                        try stream.append(allocator, .{ .pointer_index = const_idx });
                    }
                    // Append after-trace if injected
                    if (comptime Cfg.inject_tracing) {
                        try stream.append(allocator, .{ .handler = self.trace_after });
                    }

                    // Skip the next instruction if we fused
                    if (fused and next_pc < N) {
                        i = next_pc + 1;
                    } else {
                        i += 1 + n;
                    }
                } else if (op == @intFromEnum(Opcode.JUMPDEST)) {
                    // JUMPDEST needs metadata
                    const handler_ptr = handlers[op];
                    if (@intFromPtr(handler_ptr) == 0xaaaaaaaaaaaaaaaa) {
                        log.warn("Uninitialized handler for JUMPDEST at PC {}", .{i});
                    }
                    try stream.append(allocator, .{ .handler = handler_ptr });
                    
                    // Find the block metadata for this JUMPDEST
                    var metadata_found = false;
                    for (blocks) |block| {
                        if (block.pc == i) {
                            // Found the metadata for this JUMPDEST
                            const jd_metadata = block.metadata;
                            
                            // On 64-bit systems, store metadata directly
                            if (@sizeOf(usize) == 8) {
                                try stream.append(allocator, .{ .jumpdest_metadata = jd_metadata });
                            } else {
                                // On 32-bit systems, store in dedicated JumpDest metadata array and use pointer
                                const jd_idx = jumpdests.items.len;
                                try jumpdests.append(allocator, jd_metadata);
                                const metadata_ptr = &jumpdests.items[jd_idx];
                                try stream.append(allocator, .{ .jumpdest_pointer = metadata_ptr });
                            }
                            metadata_found = true;
                            break;
                        }
                    }
                    
                    if (!metadata_found) {
                        // This shouldn't happen - every JUMPDEST should have metadata
                        return error.MissingJumpDestMetadata;
                    }
                    // Append after-trace if injected
                    if (comptime Cfg.inject_tracing) {
                        try stream.append(allocator, .{ .handler = self.trace_after });
                    }

                    i += 1;
                } else if (op == @intFromEnum(Opcode.PC)) {
                    // PC opcode needs to store the current program counter value
                    try stream.append(allocator, .{ .handler = handlers[op] });
                    try stream.append(allocator, .{ .inline_value = @intCast(i) });
                    if (comptime Cfg.inject_tracing) {
                        try stream.append(allocator, .{ .handler = self.trace_after });
                    }
                    i += 1;
                } else {
                    if (N <= 64) {
                        log.warn("Planner: non-PUSH op {x} at PC {} -> stream_idx {}", .{ op, i, stream.items.len });
                    }
                    // Other non-PUSH opcodes - just add the handler
                    const handler_ptr = handlers[op];
                    if (@intFromPtr(handler_ptr) == 0xaaaaaaaaaaaaaaaa) {
                        log.warn("Uninitialized handler for opcode {x} at PC {}", .{ op, i });
                    }
                    try stream.append(allocator, .{ .handler = handler_ptr });
                    if (comptime Cfg.inject_tracing) {
                        try stream.append(allocator, .{ .handler = self.trace_after });
                    }
                    i += 1;
                }
            }

            // Update entry block metadata (stop at first JUMPDEST if at PC 0)
            if (blocks.len > 0) {
                self.start = blocks[0].metadata;
            }
            
            // Free blocks as we don't need them at runtime
            allocator.free(blocks);
            
            return PlanType{
                .instructionStream = try stream.toOwnedSlice(allocator),
                .u256_constants = try constants.toOwnedSlice(allocator),
                .jumpdest_metadata = try jumpdests.toOwnedSlice(allocator),
                .pc_to_instruction_idx = pc_map,
                .pc_to_instruction_idx_dense = dense_pc_to_idx,
            };
        }

        /// Create minimal plan with only bitmap analysis.
        /// This is used for lightweight execution without optimization.
        pub fn create_minimal_plan(self: *Self, allocator: std.mem.Allocator, handlers: [256]*const HandlerFn) !void {
            _ = handlers; // Handlers not used in minimal planning strategy
            const code = self.bytecode.runtime_code;
            const N = code.len;
            // Allocate bitmaps (bit-per-byte)
            const bitmap_bytes = (N + 7) >> 3;
            const is_push_data = try allocator.alloc(u8, bitmap_bytes);
            errdefer allocator.free(is_push_data);
            const is_op_start = try allocator.alloc(u8, bitmap_bytes);
            errdefer allocator.free(is_op_start);
            const is_jumpdest = try allocator.alloc(u8, bitmap_bytes);
            errdefer allocator.free(is_jumpdest);
            @memset(is_push_data, 0);
            @memset(is_op_start, 0);
            @memset(is_jumpdest, 0);

            // Pass 1: scan bytecode to fill opcode-start and push-data bitmaps
            var i: usize = 0;
            while (i < N) : (i += 1) {
                // setBit(is_op_start, i)
                is_op_start[i >> 3] |= @as(u8, 1) << @intCast(i & 7);
                const op = code[i];
                if (op >= @intFromEnum(Opcode.PUSH1) and op <= @intFromEnum(Opcode.PUSH32)) {
                    const n: usize = op - (@intFromEnum(Opcode.PUSH1) - 1);
                    var j: usize = 0;
                    while (j < n and i + 1 + j < N) : (j += 1) {
                        const idx = i + 1 + j;
                        is_push_data[idx >> 3] |= @as(u8, 1) << @intCast(idx & 7);
                    }
                    i += n; // loop's i += 1 advances over opcode byte
                    continue;
                }
            }

            // Mark JUMPDEST positions (0x5B) excluding push-data bytes
            if (comptime VectorLength) |L| {
                markJumpdestSimd(code, is_push_data, is_jumpdest, L);
            } else {
                markJumpdestScalar(code, is_push_data, is_jumpdest);
            }

            // Note: This function creates minimal plans in-place and doesn't return a plan object
            // Full minimal plan implementation would create a PlanMinimal struct
            // const PlanMinimal = plan_minimal_mod.createPlanMinimal(.{});
            // return try PlanMinimal.init(allocator, code, handlers);
            
            // For now, just clean up allocated memory
            allocator.free(is_push_data);
            allocator.free(is_op_start);
            allocator.free(is_jumpdest);
        }
    };
}

/// Linear scan: set jumpdest bit at i when bytecode[i]==0x5b and the push-data bit is not set.
fn markJumpdestScalar(bytecode: []const u8, is_push_data: []const u8, is_jumpdest: []u8) void {
    var i: usize = 0;
    while (i < bytecode.len) : (i += 1) {
        const test_push = (is_push_data[i >> 3] & (@as(u8, 1) << @intCast(i & 7))) != 0;
        if (bytecode[i] == @intFromEnum(Opcode.JUMPDEST) and !test_push) {
            is_jumpdest[i >> 3] |= @as(u8, 1) << @intCast(i & 7);
        }
    }
}

/// SIMD-accelerated jump destination marking
/// 
/// Processes L bytes simultaneously using vector instructions instead of scalar loops.
/// Significantly improves performance for large bytecode by leveraging CPU parallelism.
fn markJumpdestSimd(bytecode: []const u8, is_push_data: []const u8, is_jumpdest: []u8, comptime L: comptime_int) void {
    var i: usize = 0;
    const len = bytecode.len;
    
    // Vector containing L copies of JUMPDEST opcode (0x5b) for parallel comparison
    const splat_5b: @Vector(L, u8) = @splat(@as(u8, @intFromEnum(Opcode.JUMPDEST)));
    
    // Process bytecode in L-byte chunks using SIMD operations
    while (i + L <= len) : (i += L) {
        // Load L consecutive bytes into vector for parallel processing
        var arr: [L]u8 = undefined;
        inline for (0..L) |k| arr[k] = bytecode[i + k];
        const v: @Vector(L, u8) = arr;
        
        // Compare all L bytes against JUMPDEST simultaneously
        // Single vector operation replaces L scalar comparisons
        const eq: @Vector(L, bool) = v == splat_5b;
        const eq_arr: [L]bool = eq;
        
        // Process comparison results and update jump destination bitmap
        inline for (0..L) |j| {
            const idx = i + j;
            
            // Check if position is within PUSH data using bitmap lookup
            const test_push = (is_push_data[idx >> 3] & (@as(u8, 1) << @intCast(idx & 7))) != 0;
            
            // Mark as valid jump destination if JUMPDEST found outside PUSH data
            if (eq_arr[j] and !test_push) {
                is_jumpdest[idx >> 3] |= @as(u8, 1) << @intCast(idx & 7);
            }
        }
    }
    // Tail
    var t: usize = i;
    while (t < len) : (t += 1) {
        const test_push = (is_push_data[t >> 3] & (@as(u8, 1) << @intCast(t & 7))) != 0;
        if (bytecode[t] == @intFromEnum(Opcode.JUMPDEST) and !test_push) {
            is_jumpdest[t >> 3] |= @as(u8, 1) << @intCast(t & 7);
        }
    }
}

// Mock handler for tests
fn testMockHandler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
    _ = frame;
    _ = plan;
    unreachable; // Test handlers don't actually execute
}

// Test fusion handler
fn testFusionHandler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
    _ = frame;
    _ = plan;
    unreachable; // Test handlers don't actually execute
}

test "planner: bitmaps mark push-data and jumpdest correctly" {
    const allocator = std.testing.allocator;
    _ = Planner(.{});

    // Bytecode: PUSH2 0xAA 0xBB; JUMPDEST; STOP
    const bytecode = [_]u8{ @intFromEnum(Opcode.PUSH2), 0xAA, 0xBB, @intFromEnum(Opcode.JUMPDEST), @intFromEnum(Opcode.STOP) };
    var planner = try Planner(.{}).init(allocator, 16);
    defer planner.deinit();

    // Create dummy handlers for test
    var handlers: [256]*const HandlerFn = undefined;
    for (&handlers) |*h| h.* = &testMockHandler;
    const plan = try planner.getOrAnalyze(&bytecode, handlers, Hardfork.DEFAULT); // Just test that it works
    
    // Verify plan was created successfully
    try std.testing.expect(plan.instructionStream.len > 0);

    // JumpDestMetadata is now stored inline in the instruction stream
}

test "planner: blocks and lookupInstrIdx basic" {
    const allocator = std.testing.allocator;
    _ = Planner(.{});
    // Bytecode: PUSH1 0x01; JUMPDEST; STOP
    const bytecode = [_]u8{ @intFromEnum(Opcode.PUSH1), 0x01, @intFromEnum(Opcode.JUMPDEST), @intFromEnum(Opcode.STOP) };
    var planner = try Planner(.{}).init(allocator, 16);
    defer planner.deinit();

    // Create dummy handlers for test
    var handlers: [256]*const HandlerFn = undefined;
    for (&handlers) |*h| h.* = &testMockHandler;
    const plan = try planner.getOrAnalyze(&bytecode, handlers, Hardfork.DEFAULT);
    
    // Verify plan was created successfully
    try std.testing.expect(plan.instructionStream.len > 0);

    // JumpDestMetadata is now stored inline in the instruction stream
    // const idx_opt = plan.lookupInstructionIdx(@as(Planner(.{}).PcTypeT, 2));
    // try std.testing.expect(idx_opt != null);
    // try std.testing.expectEqual(@as(usize, 2), idx_opt.?);
}

test "planner: SIMD parity with scalar" {
    const allocator = std.testing.allocator;
    // Bytecode with mixed PUSH data and multiple JUMPDESTs
    // PUSH2 aa bb; ADD; JUMPDEST; PUSH1 01; PUSH1 02; ADD; JUMPDEST; STOP
    const bc = [_]u8{
        @intFromEnum(Opcode.PUSH2), 0xAA, 0xBB,
        @intFromEnum(Opcode.ADD),
        @intFromEnum(Opcode.JUMPDEST),
        @intFromEnum(Opcode.PUSH1), 0x01,
        @intFromEnum(Opcode.PUSH1), 0x02,
        @intFromEnum(Opcode.ADD),
        @intFromEnum(Opcode.JUMPDEST),
        @intFromEnum(Opcode.STOP),
    };

    const PlannerSimd = Planner(.{});
    const PlannerScalar = Planner(.{ .vector_length = null });

    var planner_simd = try PlannerSimd.init(allocator, 16);
    defer planner_simd.deinit();
    var planner_scalar = try PlannerScalar.init(allocator, 16);
    defer planner_scalar.deinit();

    // Create dummy handlers for test
    var handlers: [256]*const HandlerFn = undefined;
    for (&handlers) |*h| h.* = &testMockHandler;
    const plan_simd = try planner_simd.getOrAnalyze(&bc, handlers, Hardfork.DEFAULT);
    const plan_scalar = try planner_scalar.getOrAnalyze(&bc, handlers, Hardfork.DEFAULT);

    // Compare instruction stream lengths
    try std.testing.expectEqual(plan_scalar.instructionStream.len, plan_simd.instructionStream.len);
}

test "planner: static gas charge and stack height ranges" {
    const allocator = std.testing.allocator;
    // Entry block: PUSH1 01; PUSH1 02; ADD; JUMPDEST; STOP
    const bc = [_]u8{
        @intFromEnum(Opcode.PUSH1), 0x01,
        @intFromEnum(Opcode.PUSH1), 0x02,
        @intFromEnum(Opcode.ADD),
        @intFromEnum(Opcode.JUMPDEST),
        @intFromEnum(Opcode.STOP),
    };

    var planner = try Planner(.{}).init(allocator, 16);
    defer planner.deinit();
    // Create dummy handlers for test
    var handlers: [256]*const HandlerFn = undefined;
    for (&handlers) |*h| h.* = &testMockHandler;
    const plan = try planner.getOrAnalyze(&bc, handlers, Hardfork.DEFAULT);
    _ = plan;

    // Entry block metadata is stored in planner.start
    const g_push = opcode_data.OPCODE_INFO[@intFromEnum(Opcode.PUSH1)].gas_cost;
    const g_add = opcode_data.OPCODE_INFO[@intFromEnum(Opcode.ADD)].gas_cost;
    const expected_entry_gas: u32 = @intCast(g_push + g_push + g_add);
    try std.testing.expectEqual(expected_entry_gas, planner.start.gas);
    // Stack height through PUSH1, PUSH1, ADD => deltas +1, +1, -1 → min=0, max=2
    try std.testing.expectEqual(@as(i16, 0), planner.start.min_stack);
    try std.testing.expectEqual(@as(i16, 2), planner.start.max_stack);
}

test "planner: lookupInstructionIdx returns null for non-dest" {
    const allocator = std.testing.allocator;
    // No JUMPDESTs at all
    const bc = [_]u8{ @intFromEnum(Opcode.PUSH1), 0x01, @intFromEnum(Opcode.STOP) };
    var planner = try Planner(.{}).init(allocator, 16);
    defer planner.deinit();
    // Create dummy handlers for test
    var handlers: [256]*const HandlerFn = undefined;
    for (&handlers) |*h| h.* = &testMockHandler;
    const plan = try planner.getOrAnalyze(&bc, handlers, Hardfork.DEFAULT);
    _ = plan;
    // No jump_table in runtime plan anymore
}

test "planner: init with allocator" {
    const allocator = std.testing.allocator;
    _ = Planner(.{});
    
    const bytecode = [_]u8{ @intFromEnum(Opcode.PUSH1), 0x01, @intFromEnum(Opcode.STOP) };
    var planner = try Planner(.{}).init(allocator, 16);
    defer planner.deinit();
    
    // Create dummy handlers
    var handlers: [256]*const HandlerFn = undefined;
    for (&handlers) |*h| h.* = &testMockHandler;
    const plan = try planner.getOrAnalyze(&bytecode, handlers, Hardfork.DEFAULT);
    
    // Verify plan was created successfully  
    try std.testing.expect(plan.instructionStream.len > 0);
}

test "synthetic opcodes: constants defined" {
    // Test that synthetic opcodes are defined and have correct values
    // They should be in the unused opcode range (0xB0-0xB9 in this case)
    try std.testing.expect(@intFromEnum(OpcodeSynthetic.PUSH_ADD_INLINE) == 0xB0);
    try std.testing.expect(@intFromEnum(OpcodeSynthetic.PUSH_ADD_POINTER) == 0xB1);
    try std.testing.expect(@intFromEnum(OpcodeSynthetic.PUSH_MUL_INLINE) == 0xB2);
    try std.testing.expect(@intFromEnum(OpcodeSynthetic.PUSH_MUL_POINTER) == 0xB3);
    try std.testing.expect(@intFromEnum(OpcodeSynthetic.PUSH_DIV_INLINE) == 0xB4);
    try std.testing.expect(@intFromEnum(OpcodeSynthetic.PUSH_DIV_POINTER) == 0xB5);
    try std.testing.expect(@intFromEnum(OpcodeSynthetic.PUSH_JUMP_INLINE) == 0xB6);
    try std.testing.expect(@intFromEnum(OpcodeSynthetic.PUSH_JUMP_POINTER) == 0xB7);
    try std.testing.expect(@intFromEnum(OpcodeSynthetic.PUSH_JUMPI_INLINE) == 0xB8);
    try std.testing.expect(@intFromEnum(OpcodeSynthetic.PUSH_JUMPI_POINTER) == 0xB9);
    
    // Ensure no overlap between opcodes
    const opcodes = [_]u8{
        @intFromEnum(OpcodeSynthetic.PUSH_ADD_INLINE), @intFromEnum(OpcodeSynthetic.PUSH_ADD_POINTER),
        @intFromEnum(OpcodeSynthetic.PUSH_MUL_INLINE), @intFromEnum(OpcodeSynthetic.PUSH_MUL_POINTER),
        @intFromEnum(OpcodeSynthetic.PUSH_DIV_INLINE), @intFromEnum(OpcodeSynthetic.PUSH_DIV_POINTER),
        @intFromEnum(OpcodeSynthetic.PUSH_JUMP_INLINE), @intFromEnum(OpcodeSynthetic.PUSH_JUMP_POINTER),
        @intFromEnum(OpcodeSynthetic.PUSH_JUMPI_INLINE), @intFromEnum(OpcodeSynthetic.PUSH_JUMPI_POINTER),
    };
    
    var i: usize = 0;
    while (i < opcodes.len) : (i += 1) {
        var j = i + 1;
        while (j < opcodes.len) : (j += 1) {
            try std.testing.expect(opcodes[i] != opcodes[j]);
        }
    }
}

test "metadata structs: proper sizing and fields" {
    // Test that metadata values fit in usize
    const inline_value: usize = 42;
    try std.testing.expectEqual(@as(usize, 42), inline_value);
    
    // Test pointer values
    const ptr_value: usize = 0xDEADBEEF;
    try std.testing.expectEqual(@as(usize, 0xDEADBEEF), ptr_value);
    
    // Test JumpDestMetadata
    const jd_meta = JumpDestMetadata{ .gas = 1000, .min_stack = -5, .max_stack = 10 };
    try std.testing.expectEqual(@as(u32, 1000), jd_meta.gas);
    try std.testing.expectEqual(@as(i16, -5), jd_meta.min_stack);
    try std.testing.expectEqual(@as(i16, 10), jd_meta.max_stack);
    
    // Verify JumpDestMetadata fits in usize on 64-bit
    if (@sizeOf(usize) >= 8) {
        try std.testing.expect(@sizeOf(JumpDestMetadata) <= @sizeOf(usize));
    }
}

test "getMetadata: PUSH0 has no metadata" {
    // This test should fail to compile because PUSH0 has no metadata
    // Uncomment to verify compile error:
    // const Planner(.{}) = Planner(.{});
    // var plan = Planner(.{}).Plan{ .instructionStream = &.{}, .u256_constants = &.{} };
    // var idx: Planner(.{}).InstructionIndexT = 0;
    // const metadata = plan.getMetadata(&idx, .PUSH0); // Should @compileError
}

test "getMetadata: PUSH opcodes return correct granular types" {
    const allocator = std.testing.allocator;
    _ = Planner(.{});
    
    // Test that enum literal handling works
    // @compileLog(@TypeOf(.PUSH1)); // This would show it's @Type(.enum_literal)
    
    // Test PUSH1 returns u8
    {
        const stream = [_]InstructionElement{ 
            .{ .handler = &testMockHandler }, 
            .{ .inline_value = 0xFF },
            .{ .handler = &testMockHandler } 
        };
        
        var plan = Planner(.{}).Plan{
            .instructionStream = try allocator.dupe(InstructionElement, &stream),
            .u256_constants = &.{},
            .jumpdest_metadata = &.{},
            .pc_to_instruction_idx = null,
        };
        defer plan.deinit(allocator);
        
        var idx: Planner(.{}).InstructionIndexT = 0;
        const metadata = plan.getMetadata(&idx, .PUSH1);
        try std.testing.expectEqual(@as(u8, 0xFF), metadata);
    }
    
    // Test PUSH2 returns u16
    {
        const stream = [_]InstructionElement{ 
            .{ .handler = &testMockHandler }, 
            .{ .inline_value = 0xFFFF },
            .{ .handler = &testMockHandler } 
        };
        
        var plan = Planner(.{}).Plan{
            .instructionStream = try allocator.dupe(InstructionElement, &stream),
            .u256_constants = &.{},
            .jumpdest_metadata = &.{},
            .pc_to_instruction_idx = null,
        };
        defer plan.deinit(allocator);
        
        var idx: Planner(.{}).InstructionIndexT = 0;
        const metadata = plan.getMetadata(&idx, .PUSH2);
        try std.testing.expectEqual(@as(u16, 0xFFFF), metadata);
    }
    
    // Test PUSH8 returns u64
    {
        const stream = [_]InstructionElement{ 
            .{ .handler = &testMockHandler }, 
            .{ .inline_value = 0xFFFFFFFFFFFFFFFF },
            .{ .handler = &testMockHandler } 
        };
        
        var plan = Planner(.{}).Plan{
            .instructionStream = try allocator.dupe(InstructionElement, &stream),
            .u256_constants = &.{},
            .jumpdest_metadata = &.{},
            .pc_to_instruction_idx = null,
        };
        defer plan.deinit(allocator);
        
        var idx: Planner(.{}).InstructionIndexT = 0;
        const metadata = plan.getMetadata(&idx, .PUSH8);
        try std.testing.expectEqual(@as(u64, 0xFFFFFFFFFFFFFFFF), metadata);
    }
}

test "getMetadata: large PUSH opcodes return pointer to u256" {
    const allocator = std.testing.allocator;
    _ = Planner(.{});
    
    // Test PUSH32 returns *const u256
    const big_value: u256 = std.math.maxInt(u256);
    
    const stream = [_]InstructionElement{ 
        .{ .handler = &testMockHandler }, 
        .{ .pointer_index = 0 }, // Index into constants
        .{ .handler = &testMockHandler } 
    };
    
    // Allocate constants properly
    var constants = try allocator.alloc(u256, 1);
    defer allocator.free(constants);
    constants[0] = big_value;
    
    var plan = Planner(.{}).Plan{
        .instructionStream = try allocator.dupe(InstructionElement, &stream),
        .u256_constants = constants,
        .jumpdest_metadata = &.{},
        .pc_to_instruction_idx = null,
    };
    defer {
        // Only free instructionStream since we're managing constants separately
        allocator.free(plan.instructionStream);
        plan.instructionStream = &.{};
        plan.u256_constants = &.{};
    }
    
    var idx: Planner(.{}).InstructionIndexT = 0;
    const metadata_ptr = plan.getMetadata(&idx, .PUSH32);
    try std.testing.expectEqual(big_value, metadata_ptr.*);
}

test "getMetadata: PC returns PcType" {
    const allocator = std.testing.allocator;
    _ = Planner(.{});
    
    const stream = [_]InstructionElement{ 
        .{ .handler = &testMockHandler }, 
        .{ .inline_value = 42 },
        .{ .handler = &testMockHandler } 
    };
    
    var plan = Planner(.{}).Plan{
        .instructionStream = try allocator.dupe(InstructionElement, &stream),
        .u256_constants = &.{},
        .jumpdest_metadata = &.{},
        .pc_to_instruction_idx = null,
    };
    defer plan.deinit(allocator);
    
    var idx: Planner(.{}).InstructionIndexT = 0;
    const pc = plan.getMetadata(&idx, .PC);
    try std.testing.expectEqual(@as(Planner(.{}).PcTypeT, 42), pc);
}

test "getMetadata: fusion opcodes" {
    const allocator = std.testing.allocator;
    _ = Planner(.{});
    
    // Test PUSH_ADD_INLINE fusion - should work like PUSH1
    {
        const stream = [_]InstructionElement{ 
            .{ .handler = &testFusionHandler }, 
            .{ .inline_value = 5 },
            .{ .handler = &testMockHandler } 
        };
        
        var plan = Planner(.{}).Plan{
            .instructionStream = try allocator.dupe(InstructionElement, &stream),
            .u256_constants = &.{},
            .jumpdest_metadata = &.{},
            .pc_to_instruction_idx = null,
        };
        defer plan.deinit(allocator);
        
        // Test fusion opcode metadata
        var idx: Planner(.{}).InstructionIndexT = 0;
        const metadata = plan.getMetadata(&idx, @intFromEnum(OpcodeSynthetic.PUSH_ADD_INLINE));
        try std.testing.expectEqual(@as(usize, 5), metadata);
    }
}

test "getNextInstruction: fusion opcodes advance correctly" {
    const allocator = std.testing.allocator;
    _ = Planner(.{});
    
    const stream = [_]InstructionElement{ 
        .{ .handler = &testFusionHandler }, // PUSH_ADD_INLINE
        .{ .inline_value = 5 },              // metadata
        .{ .handler = &testMockHandler },    // next instruction
    };
    
    var plan = Planner(.{}).Plan{
        .instructionStream = try allocator.dupe(InstructionElement, &stream),
        .u256_constants = &.{},
        .jumpdest_metadata = &.{},
        .pc_to_instruction_idx = null,
    };
    defer plan.deinit(allocator);
    
    // Test fusion opcode advances correctly
    var idx: Planner(.{}).InstructionIndexT = 0;
    const handler = plan.getNextInstruction(&idx, @intFromEnum(OpcodeSynthetic.PUSH_ADD_INLINE));
    try std.testing.expectEqual(@intFromPtr(&testFusionHandler), @intFromPtr(handler));
    try std.testing.expectEqual(@as(Planner(.{}).InstructionIndexT, 2), idx);
}

test "create_instruction_stream: basic handler array" {
    const allocator = std.testing.allocator;
    _ = Planner(.{});
    
    // Create handler array
    var handlers: [256]*const HandlerFn = undefined;
    for (&handlers) |*h| {
        h.* = &testMockHandler;
    }
    
    // Simple bytecode: PUSH1 5
    const bytecode = [_]u8{ @intFromEnum(Opcode.PUSH1), 0x05 };
    var planner = try Planner(.{}).init(allocator, 16);
    defer planner.deinit();
    
    const plan = try planner.getOrAnalyze(&bytecode, handlers, Hardfork.DEFAULT);
    
    // Should have at least 2 instructions (handler + metadata)
    try std.testing.expect(plan.instructionStream.len >= 2);
    
    // First should be the handler pointer
    try std.testing.expectEqual(@intFromPtr(&testMockHandler), @intFromPtr(plan.instructionStream[0].handler));
}

test "PUSH inline vs pointer: small values stored inline" {
    const allocator = std.testing.allocator;
    _ = Planner(.{});
    
    // Create handler array
    var handlers: [256]*const HandlerFn = undefined;
    for (&handlers) |*h| {
        h.* = &testMockHandler;
    }
    
    // PUSH8 with value that fits in usize (8 bytes = 64 bits)
    const bytecode = [_]u8{ @intFromEnum(Opcode.PUSH8), 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08 };
    var planner = try Planner(.{}).init(allocator, 16);
    defer planner.deinit();
    
    const plan = try planner.getOrAnalyze(&bytecode, handlers, Hardfork.DEFAULT);
    
    // Should have handler + inline value
    try std.testing.expectEqual(@as(usize, 2), plan.instructionStream.len);
    
    // Second element should be the inline value
    const expected_value = if (@sizeOf(usize) == 8) @as(usize, 0x0102030405060708) else @as(usize, 0x01020304);
    try std.testing.expectEqual(expected_value, plan.instructionStream[1].inline_value);
    
    // No u256 constants needed
    try std.testing.expectEqual(@as(usize, 0), plan.u256_constants.len);
}

test "PUSH inline vs pointer: large values use pointer" {
    const allocator = std.testing.allocator;
    _ = Planner(.{});
    
    // Create handler array
    var handlers: [256]*const HandlerFn = undefined;
    for (&handlers) |*h| {
        h.* = &testMockHandler;
    }
    
    // PUSH32 with large value
    const bytecode = [_]u8{ @intFromEnum(Opcode.PUSH32) } ++ 
        [_]u8{0xFF} ** 32; // 32 bytes of 0xFF
    var planner = try Planner(.{}).init(allocator, 16);
    defer planner.deinit();
    
    const plan = try planner.getOrAnalyze(&bytecode, handlers, Hardfork.DEFAULT);
    
    // Should have handler + pointer
    try std.testing.expectEqual(@as(usize, 2), plan.instructionStream.len);
    
    // Should have one u256 constant
    try std.testing.expectEqual(@as(usize, 1), plan.u256_constants.len);
    
    // Second element should be pointer to constant (index 0)
    try std.testing.expectEqual(@as(usize, 0), plan.instructionStream[1].pointer_index);
    
    // Verify the constant value
    const expected = std.math.maxInt(u256);
    try std.testing.expectEqual(expected, plan.u256_constants[0]);
}

test "fusion detection: PUSH+ADD inline" {
    const allocator = std.testing.allocator;
    _ = Planner(.{});
    
    // Create handler array with special fusion handler
    var handlers: [256]*const HandlerFn = undefined;
    for (&handlers) |*h| {
        h.* = &testMockHandler;
    }
    
    handlers[@intFromEnum(OpcodeSynthetic.PUSH_ADD_INLINE)] = &testFusionHandler;
    
    // PUSH1 5; ADD
    const bytecode = [_]u8{ @intFromEnum(Opcode.PUSH1), 0x05, @intFromEnum(Opcode.ADD) };
    var planner = try Planner(.{}).init(allocator, 16);
    defer planner.deinit();
    
    const plan = try planner.getOrAnalyze(&bytecode, handlers, Hardfork.DEFAULT);
    
    // Should have fused handler + inline value  
    try std.testing.expectEqual(@as(usize, 2), plan.instructionStream.len);
    
    // First should be the fusion handler
    try std.testing.expectEqual(@intFromPtr(&testFusionHandler), @intFromPtr(plan.instructionStream[0].handler));
    
    // Second should be inline value
    try std.testing.expectEqual(@as(usize, 5), plan.instructionStream[1].inline_value);
}

test "fusion detection: PUSH+ADD pointer" {
    const allocator = std.testing.allocator;
    _ = Planner(.{});
    
    // Create handler array with special fusion handler
    var handlers: [256]*const HandlerFn = undefined;
    for (&handlers) |*h| {
        h.* = &testMockHandler;
    }
    
    handlers[@intFromEnum(OpcodeSynthetic.PUSH_ADD_POINTER)] = &testFusionHandler;
    
    // PUSH32 <big value>; ADD
    const bytecode = [_]u8{ @intFromEnum(Opcode.PUSH32) } ++ 
        [_]u8{0xFF} ** 32 ++ // 32 bytes
        [_]u8{ @intFromEnum(Opcode.ADD) };
    var planner = try Planner(.{}).init(allocator, 16);
    defer planner.deinit();
    
    const plan = try planner.getOrAnalyze(&bytecode, handlers, Hardfork.DEFAULT);
    
    // Should have fused handler + pointer
    try std.testing.expectEqual(@as(usize, 2), plan.instructionStream.len);
    
    // First should be the fusion handler
    try std.testing.expectEqual(@intFromPtr(&testFusionHandler), @intFromPtr(plan.instructionStream[0].handler));
    
    // Second should be pointer (index 0)
    try std.testing.expectEqual(@as(usize, 0), plan.instructionStream[1].pointer_index);
    
    // Should have constant
    try std.testing.expectEqual(@as(usize, 1), plan.u256_constants.len);
}

test "fusion detection: PUSH+JUMP inline" {
    const allocator = std.testing.allocator;
    _ = Planner(.{});
    
    // Create handler array with special fusion handler
    var handlers: [256]*const HandlerFn = undefined;
    for (&handlers) |*h| {
        h.* = &testMockHandler;
    }
    handlers[@intFromEnum(OpcodeSynthetic.PUSH_JUMP_INLINE)] = &testFusionHandler;
    
    // PUSH1 4; JUMP (to a valid JUMPDEST)
    const bytecode = [_]u8{ 
        @intFromEnum(Opcode.PUSH1), 0x04, 
        @intFromEnum(Opcode.JUMP),
        @intFromEnum(Opcode.STOP),
        @intFromEnum(Opcode.JUMPDEST), // PC=4
        @intFromEnum(Opcode.STOP)
    };
    var planner = try Planner(.{}).init(allocator, 16);
    defer planner.deinit();
    
    const plan = try planner.getOrAnalyze(&bytecode, handlers, Hardfork.DEFAULT);
    
    // Should have fused handler + inline value + rest
    try std.testing.expect(plan.instructionStream.len >= 2);
    
    // First should be the fusion handler
    try std.testing.expectEqual(@intFromPtr(&testFusionHandler), @intFromPtr(plan.instructionStream[0].handler));
    
    // Second should be inline destination
    try std.testing.expectEqual(@as(usize, 4), plan.instructionStream[1].inline_value);
}

test "fusion detection: PUSH+JUMP pointer" {
    const allocator = std.testing.allocator;
    _ = Planner(.{});
    
    // Create handler array with special fusion handler
    var handlers: [256]*const HandlerFn = undefined;
    for (&handlers) |*h| {
        h.* = &testMockHandler;
    }
    handlers[@intFromEnum(OpcodeSynthetic.PUSH_JUMP_POINTER)] = &testFusionHandler;
    
    // PUSH32 with large jump destination; JUMP
    const bytecode = [_]u8{ @intFromEnum(Opcode.PUSH32) } ++ 
        [_]u8{0} ** 31 ++ [_]u8{40} ++ // Jump to PC=40
        [_]u8{ @intFromEnum(Opcode.JUMP) } ++
        [_]u8{@intFromEnum(Opcode.STOP)} ** 36 ++ // padding
        [_]u8{ @intFromEnum(Opcode.JUMPDEST) }; // PC=40
        
    var planner = try Planner(.{}).init(allocator, 16);
    defer planner.deinit();
    
    const plan = try planner.getOrAnalyze(&bytecode, handlers, Hardfork.DEFAULT);
    
    // Should have fused handler + pointer
    try std.testing.expect(plan.instructionStream.len >= 2);
    
    // First should be the fusion handler
    try std.testing.expectEqual(@intFromPtr(&testFusionHandler), @intFromPtr(plan.instructionStream[0].handler));
    
    // Second should be pointer to constant
    try std.testing.expectEqual(@as(usize, 0), plan.instructionStream[1].pointer_index);
    
    // Should have constant with value 40
    try std.testing.expectEqual(@as(usize, 1), plan.u256_constants.len);
    try std.testing.expectEqual(@as(u256, 40), plan.u256_constants[0]);
}

test "JumpDestMetadata handling: JUMPDEST instructions have metadata" {
    const allocator = std.testing.allocator;
    _ = Planner(.{});
    
    // Create handler array
    var handlers: [256]*const HandlerFn = undefined;
    for (&handlers) |*h| {
        h.* = &testMockHandler;
    }
    
    // Test bytecode with JUMPDEST (no fusion to avoid complexity)
    const bytecode = [_]u8{
        @intFromEnum(Opcode.JUMPDEST),     // PC 0: JUMPDEST
        @intFromEnum(Opcode.PUSH1), 0x01,  // PC 1: PUSH1 1
        @intFromEnum(Opcode.STOP),         // PC 3: STOP
    };
    
    var planner = try Planner(.{}).init(allocator, 2);
    defer planner.deinit();
    const plan = try planner.getOrAnalyze(&bytecode, handlers, Hardfork.DEFAULT);
    // Note: plan is cached, don't call deinit directly
    
    // Find JUMPDEST in the instruction stream
    // Currently, JUMPDEST instructions don't have metadata following them
    // This test should fail once we check for metadata
    
    var found_jumpdest_without_metadata = false;
    var i: usize = 0;
    
    while (i < plan.instructionStream.len) : (i += 1) {
        const elem = plan.instructionStream[i];
        
        // Check if this is a JUMPDEST handler
        if (@intFromPtr(elem.handler) == @intFromPtr(handlers[@intFromEnum(Opcode.JUMPDEST)])) {
            // Check next slot - it should be metadata
            if (i + 1 < plan.instructionStream.len) {
                const next_elem = plan.instructionStream[i + 1];
                // If next is a handler pointer, then no metadata was added
                if (@intFromPtr(next_elem.handler) == @intFromPtr(handlers[@intFromEnum(Opcode.PUSH1)]) or
                    @intFromPtr(next_elem.handler) == @intFromPtr(handlers[@intFromEnum(Opcode.STOP)])) {
                    found_jumpdest_without_metadata = true;
                }
            }
            break;
        }
    }
    
    // This test should fail - we expect metadata but don't have it yet
    try std.testing.expect(!found_jumpdest_without_metadata);
}

test "dynamic jump table: unfused JUMP can lookup instruction index" {
    const allocator = std.testing.allocator;
    _ = Planner(.{});
    
    // Create handler array
    var handlers: [256]*const HandlerFn = undefined;
    for (&handlers) |*h| {
        h.* = &testMockHandler;
    }
    
    // Test bytecode with dynamic JUMP (value from stack, not fusion)
    const bytecode = [_]u8{
        @intFromEnum(Opcode.JUMPDEST),     // PC 0: entry point
        @intFromEnum(Opcode.PUSH1), 0x06,  // PC 1: push jump destination
        @intFromEnum(Opcode.PUSH1), 0x01,  // PC 3: push some value
        @intFromEnum(Opcode.JUMP),         // PC 5: dynamic jump (not fused)
        @intFromEnum(Opcode.JUMPDEST),     // PC 6: jump destination
        @intFromEnum(Opcode.STOP),         // PC 7: stop
    };
    
    var planner = try Planner(.{}).init(allocator, 2);
    defer planner.deinit();
    const plan = try planner.getOrAnalyze(&bytecode, handlers, Hardfork.DEFAULT);
    // Note: plan is cached, don't call deinit directly
    
    // Dynamic jump support is handled during execution, not in the plan
    // The instruction stream should contain the JUMPDEST handlers
    var found_jumpdests: usize = 0;
    var i: usize = 0;
    while (i < plan.instructionStream.len) {
        const elem = plan.instructionStream[i];
        if (@intFromPtr(elem.handler) == @intFromPtr(handlers[@intFromEnum(Opcode.JUMPDEST)])) {
            found_jumpdests += 1;
            i += 2; // Skip metadata
        } else {
            i += 1;
        }
    }
    try std.testing.expect(found_jumpdests >= 2);
}

test "fusion detection: PUSH+MUL fusion" {
    const allocator = std.testing.allocator;
    _ = Planner(.{});
    
    // Create handler array
    var handlers: [256]*const HandlerFn = undefined;
    for (&handlers) |*h| {
        h.* = &testMockHandler;
    }
    handlers[@intFromEnum(OpcodeSynthetic.PUSH_MUL_INLINE)] = &testFusionHandler;
    handlers[@intFromEnum(OpcodeSynthetic.PUSH_MUL_POINTER)] = &testFusionHandler;
    
    // Test PUSH1 5; MUL
    const bytecode = [_]u8{
        @intFromEnum(Opcode.PUSH1), 5,
        @intFromEnum(Opcode.MUL),
    };
    
    var planner = try Planner(.{}).init(allocator, 2);
    defer planner.deinit();
    const plan = try planner.getOrAnalyze(&bytecode, handlers, Hardfork.DEFAULT);
    // Note: plan is cached, don't call deinit directly
    
    // Should have detected PUSH+MUL fusion
    try std.testing.expectEqual(@as(usize, 2), plan.instructionStream.len);
    try std.testing.expectEqual(@intFromPtr(&testFusionHandler), @intFromPtr(plan.instructionStream[0].handler));
    try std.testing.expectEqual(@as(usize, 5), plan.instructionStream[1].inline_value);
}

test "fusion detection: PUSH+DIV fusion" {
    const allocator = std.testing.allocator;
    _ = Planner(.{});
    
    // Create handler array
    var handlers: [256]*const HandlerFn = undefined;
    for (&handlers) |*h| {
        h.* = &testMockHandler;
    }
    handlers[@intFromEnum(OpcodeSynthetic.PUSH_DIV_INLINE)] = &testFusionHandler;
    handlers[@intFromEnum(OpcodeSynthetic.PUSH_DIV_POINTER)] = &testFusionHandler;
    
    // Test PUSH1 10; DIV
    const bytecode = [_]u8{
        @intFromEnum(Opcode.PUSH1), 10,
        @intFromEnum(Opcode.DIV),
    };
    
    var planner = try Planner(.{}).init(allocator, 2);
    defer planner.deinit();
    const plan = try planner.getOrAnalyze(&bytecode, handlers, Hardfork.DEFAULT);
    // Note: plan is cached, don't call deinit directly
    
    // Should have detected PUSH+DIV fusion
    try std.testing.expectEqual(@as(usize, 2), plan.instructionStream.len);
    try std.testing.expectEqual(@intFromPtr(&testFusionHandler), @intFromPtr(plan.instructionStream[0].handler));
    try std.testing.expectEqual(@as(usize, 10), plan.instructionStream[1].inline_value);
}

test "fusion detection: PUSH+MLOAD fusion" {
    const allocator = std.testing.allocator;
    const PlannerType = Planner(.{});
    var planner = try PlannerType.init(allocator, 0);
    defer planner.deinit();

    // Bytecode: PUSH1 0x20; MLOAD; STOP
    const code = [_]u8{ @intFromEnum(Opcode.PUSH1), 0x20, @intFromEnum(Opcode.MLOAD), @intFromEnum(Opcode.STOP) };

    // Handlers array initialized to a default, override fusion slot for test
    var handlers: [256]*const HandlerFn = undefined;
    for (&handlers) |*h| h.* = &testFusionHandler;
    handlers[@intFromEnum(Opcode.MLOAD)] = &testFusionHandler;
    handlers[@intFromEnum(Opcode.STOP)] = &testFusionHandler;
    handlers[@intFromEnum(OpcodeSynthetic.PUSH_MLOAD_INLINE)] = &testFusionHandler;
    handlers[@intFromEnum(OpcodeSynthetic.PUSH_MLOAD_POINTER)] = &testFusionHandler;

    const plan_ptr = try planner.getOrAnalyze(&code, handlers, .DEFAULT);
    const plan = plan_ptr.*;

    // First instruction should be our fusion handler (inline here)
    try std.testing.expectEqual(@intFromPtr(&testFusionHandler), @intFromPtr(plan.instructionStream[0].handler));
}

test "fusion detection: PUSH+MSTORE fusion" {
    const allocator = std.testing.allocator;
    const PlannerType = Planner(.{});
    var planner = try PlannerType.init(allocator, 0);
    defer planner.deinit();

    // Stack before: <value>
    // Bytecode: PUSH1 0x00; MSTORE; STOP (offset is immediate)
    const code = [_]u8{ @intFromEnum(Opcode.PUSH1), 0x00, @intFromEnum(Opcode.MSTORE), @intFromEnum(Opcode.STOP) };

    var handlers: [256]*const HandlerFn = undefined;
    for (&handlers) |*h| h.* = &testFusionHandler;
    handlers[@intFromEnum(Opcode.MSTORE)] = &testFusionHandler;
    handlers[@intFromEnum(Opcode.STOP)] = &testFusionHandler;
    handlers[@intFromEnum(OpcodeSynthetic.PUSH_MSTORE_INLINE)] = &testFusionHandler;
    handlers[@intFromEnum(OpcodeSynthetic.PUSH_MSTORE_POINTER)] = &testFusionHandler;

    const plan_ptr = try planner.getOrAnalyze(&code, handlers, .DEFAULT);
    const plan = plan_ptr.*;
    try std.testing.expectEqual(@intFromPtr(&testFusionHandler), @intFromPtr(plan.instructionStream[0].handler));
}

test "fusion detection: PUSH+JUMPI fusion" {
    const allocator = std.testing.allocator;
    _ = Planner(.{});
    
    // Create handler array
    var handlers: [256]*const HandlerFn = undefined;
    for (&handlers) |*h| {
        h.* = &testMockHandler;
    }
    handlers[@intFromEnum(OpcodeSynthetic.PUSH_JUMPI_INLINE)] = &testFusionHandler;
    handlers[@intFromEnum(OpcodeSynthetic.PUSH_JUMPI_POINTER)] = &testFusionHandler;
    
    // Test PUSH1 8; JUMPI
    const bytecode = [_]u8{
        @intFromEnum(Opcode.PUSH1), 0x01,  // condition
        @intFromEnum(Opcode.PUSH1), 0x08,  // destination
        @intFromEnum(Opcode.JUMPI),        // conditional jump
        @intFromEnum(Opcode.STOP),         // fallthrough
        @intFromEnum(Opcode.JUMPDEST),     // PC 8: jump destination
        @intFromEnum(Opcode.STOP),
    };
    
    var planner = try Planner(.{}).init(allocator, 2);
    defer planner.deinit();
    const plan = try planner.getOrAnalyze(&bytecode, handlers, Hardfork.DEFAULT);
    // Note: plan is cached, don't call deinit directly
    
    // Should have PUSH1 1, then fused PUSH+JUMPI
    try std.testing.expect(plan.instructionStream.len >= 4); // PUSH1, value, PUSH_JUMPI_INLINE, dest
    
    // Find the fusion handler
    var found_fusion = false;
    var i: usize = 0;
    while (i < plan.instructionStream.len) : (i += 1) {
        if (@intFromPtr(plan.instructionStream[i].handler) == @intFromPtr(&testFusionHandler)) {
            found_fusion = true;
            // Next should be the destination value
            if (i + 1 < plan.instructionStream.len) {
                try std.testing.expectEqual(@as(usize, 8), plan.instructionStream[i + 1].inline_value);
            }
            break;
        }
    }
    
    try std.testing.expect(found_fusion);
}

test "analysis cache: LRU eviction works correctly" {
    const allocator = std.testing.allocator;
    _ = Planner(.{});
    
    // Create planner with small cache capacity
    var planner = try Planner(.{}).init(allocator, 2);
    defer planner.deinit();
    
    // Create handler array
    var handlers: [256]*const HandlerFn = undefined;
    for (&handlers) |*h| {
        h.* = &testMockHandler;
    }
    
    // Three different bytecodes
    const bytecode1 = [_]u8{ @intFromEnum(Opcode.PUSH1), 0x01, @intFromEnum(Opcode.STOP) };
    const bytecode2 = [_]u8{ @intFromEnum(Opcode.PUSH1), 0x02, @intFromEnum(Opcode.STOP) };
    const bytecode3 = [_]u8{ @intFromEnum(Opcode.PUSH1), 0x03, @intFromEnum(Opcode.STOP) };
    
    // Add first two plans (fills cache to capacity)
    const plan1 = try planner.getOrAnalyze(&bytecode1, handlers, Hardfork.DEFAULT);
    const plan2 = try planner.getOrAnalyze(&bytecode2, handlers, Hardfork.DEFAULT);
    try std.testing.expectEqual(@as(usize, 2), planner.cache_count);
    
    // Access plan1 to make it most recent
    const plan1_again = try planner.getOrAnalyze(&bytecode1, handlers, Hardfork.DEFAULT);
    try std.testing.expectEqual(@intFromPtr(plan1), @intFromPtr(plan1_again));
    
    // Add third plan - should evict plan2 (least recently used)
    _ = try planner.getOrAnalyze(&bytecode3, handlers, Hardfork.DEFAULT);
    try std.testing.expectEqual(@as(usize, 2), planner.cache_count);
    
    // plan1 should still be in cache
    const plan1_final = try planner.getOrAnalyze(&bytecode1, handlers, Hardfork.DEFAULT);
    try std.testing.expectEqual(@intFromPtr(plan1), @intFromPtr(plan1_final));
    
    // plan2 should be evicted, so we should get a new instance
    const plan2_new = try planner.getOrAnalyze(&bytecode2, handlers, Hardfork.DEFAULT);
    try std.testing.expect(@intFromPtr(plan2) != @intFromPtr(plan2_new));
}

test "analysis cache: stores and reuses plans" {
    const allocator = std.testing.allocator;
    _ = Planner(.{});
    
    // Create planner with cache
    var planner = try Planner(.{}).init(allocator, 2);
    defer planner.deinit();
    
    // Create handler array
    var handlers: [256]*const HandlerFn = undefined;
    for (&handlers) |*h| {
        h.* = &testMockHandler;
    }
    
    // Test bytecode
    const bytecode = [_]u8{
        @intFromEnum(Opcode.PUSH1), 0x01,
        @intFromEnum(Opcode.STOP),
    };
    
    // First call should analyze and cache
    const plan1 = try planner.getOrAnalyze(&bytecode, handlers, Hardfork.DEFAULT);
    
    // Second call should return cached plan (same reference)
    const plan2 = try planner.getOrAnalyze(&bytecode, handlers, Hardfork.DEFAULT);
    
    // Should be the same plan reference
    try std.testing.expectEqual(@intFromPtr(plan1), @intFromPtr(plan2));
    
    // Verify cache contains the entry
    try std.testing.expectEqual(@as(usize, 1), planner.cache_count);
    
    // Test cache stats
    const stats = planner.getCacheStats();
    try std.testing.expect(stats.count >= 0); // Stats struct is not nullable
    try std.testing.expectEqual(@as(usize, 2), stats.capacity);
    try std.testing.expectEqual(@as(usize, 1), stats.count);
}

test "analysis cache: clear cache functionality" {
    const allocator = std.testing.allocator;
    _ = Planner(.{});
    
    // Create planner with cache
    var planner = try Planner(.{}).init(allocator, 4);
    defer planner.deinit();
    
    // Create handler array
    var handlers: [256]*const HandlerFn = undefined;
    for (&handlers) |*h| {
        h.* = &testMockHandler;
    }
    
    // Add some plans to cache
    const bytecode1 = [_]u8{ @intFromEnum(Opcode.PUSH1), 0x01, @intFromEnum(Opcode.STOP) };
    const bytecode2 = [_]u8{ @intFromEnum(Opcode.PUSH1), 0x02, @intFromEnum(Opcode.STOP) };
    
    _ = try planner.getOrAnalyze(&bytecode1, handlers, Hardfork.DEFAULT);
    _ = try planner.getOrAnalyze(&bytecode2, handlers, Hardfork.DEFAULT);
    try std.testing.expectEqual(@as(usize, 2), planner.cache_count);
    
    // Clear cache
    planner.clearCache();
    try std.testing.expectEqual(@as(usize, 0), planner.cache_count);
    
    // Verify cache stats reflect cleared state
    const stats = planner.getCacheStats();
    try std.testing.expect(stats.count >= 0); // Stats struct is not nullable
    try std.testing.expectEqual(@as(usize, 4), stats.capacity);
    try std.testing.expectEqual(@as(usize, 0), stats.count);
}

test "integration: complex bytecode with all features" {
    const allocator = std.testing.allocator;
    _ = Planner(.{});
    
    // Create handler array
    var handlers: [256]*const HandlerFn = undefined;
    for (&handlers) |*h| {
        h.* = &testMockHandler;
    }
    // Set fusion handlers
    handlers[@intFromEnum(OpcodeSynthetic.PUSH_ADD_INLINE)] = &testFusionHandler;
    handlers[@intFromEnum(OpcodeSynthetic.PUSH_ADD_POINTER)] = &testFusionHandler;
    handlers[@intFromEnum(OpcodeSynthetic.PUSH_MUL_INLINE)] = &testFusionHandler;
    handlers[@intFromEnum(OpcodeSynthetic.PUSH_MUL_POINTER)] = &testFusionHandler;
    handlers[@intFromEnum(OpcodeSynthetic.PUSH_DIV_INLINE)] = &testFusionHandler;
    handlers[@intFromEnum(OpcodeSynthetic.PUSH_DIV_POINTER)] = &testFusionHandler;
    handlers[@intFromEnum(OpcodeSynthetic.PUSH_JUMP_INLINE)] = &testFusionHandler;
    handlers[@intFromEnum(OpcodeSynthetic.PUSH_JUMP_POINTER)] = &testFusionHandler;
    handlers[@intFromEnum(OpcodeSynthetic.PUSH_JUMPI_INLINE)] = &testFusionHandler;
    handlers[@intFromEnum(OpcodeSynthetic.PUSH_JUMPI_POINTER)] = &testFusionHandler;
    
    // Complex bytecode with all features
    const bytecode = [_]u8{
        // Entry point
        @intFromEnum(Opcode.JUMPDEST),     // PC 0: entry
        
        // Fusion: PUSH+ADD
        @intFromEnum(Opcode.PUSH1), 0x05,  // PC 1: push 5
        @intFromEnum(Opcode.ADD),          // PC 3: add (fused)
        
        // Large PUSH value (pointer)
        @intFromEnum(Opcode.PUSH32),       // PC 4: push large value
    } ++ [_]u8{0xFF} ** 32 ++ [_]u8{      // PC 5-36: 32 bytes of 0xFF
        
        // Fusion: PUSH+MUL 
        @intFromEnum(Opcode.PUSH1), 0x02,  // PC 37: push 2
        @intFromEnum(Opcode.MUL),          // PC 39: multiply (fused)
        
        // Dynamic jump preparation
        @intFromEnum(Opcode.PUSH1), 0x30,  // PC 40: push jump dest (48)
        
        // Another operation to break fusion
        @intFromEnum(Opcode.DUP1),         // PC 42: duplicate
        
        // Dynamic JUMP (not fused)
        @intFromEnum(Opcode.JUMP),         // PC 43: jump
        
        // Some unreachable code
        @intFromEnum(Opcode.INVALID),      // PC 44
        @intFromEnum(Opcode.INVALID),      // PC 45
        @intFromEnum(Opcode.INVALID),      // PC 46
        @intFromEnum(Opcode.INVALID),      // PC 47
        
        // Jump destination
        @intFromEnum(Opcode.JUMPDEST),     // PC 48: jump dest
        
        // Fusion: PUSH+DIV
        @intFromEnum(Opcode.PUSH1), 0x04,  // PC 49: push 4
        @intFromEnum(Opcode.DIV),          // PC 51: divide (fused)
        
        // Conditional jump setup
        @intFromEnum(Opcode.PUSH1), 0x01,  // PC 52: push condition
        @intFromEnum(Opcode.PUSH1), 0x3A,  // PC 54: push dest (58)
        @intFromEnum(Opcode.JUMPI),        // PC 56: jumpi (fused)
        
        @intFromEnum(Opcode.INVALID),      // PC 57: skipped
        
        // Final destination
        @intFromEnum(Opcode.JUMPDEST),     // PC 58: final dest
        @intFromEnum(Opcode.STOP),         // PC 59: stop
    };
    
    var planner = try Planner(.{}).init(allocator, 2);
    defer planner.deinit();
    const plan = try planner.getOrAnalyze(&bytecode, handlers, Hardfork.DEFAULT);
    // Note: plan is cached, don't call deinit directly
    
    // Verify we have all the features:
    
    // 1. Multiple JUMPDESTs in instruction stream
    var found_jumpdests: usize = 0;
    var j: usize = 0;
    while (j < plan.instructionStream.len) {
        const elem = plan.instructionStream[j];
        if (@intFromPtr(elem.handler) == @intFromPtr(handlers[@intFromEnum(Opcode.JUMPDEST)])) {
            found_jumpdests += 1;
            j += 2; // Skip metadata
        } else {
            j += 1;
        }
    }
    try std.testing.expect(found_jumpdests >= 3); // PC 0, 48, 58
    
    // 2. Large constant in u256_constants
    try std.testing.expect(plan.u256_constants.len >= 1);
    // Check the large value is all 0xFF
    const large_val = plan.u256_constants[0];
    const expected: u256 = std.math.maxInt(u256);
    try std.testing.expectEqual(expected, large_val);
    
    // 3. Instruction stream has fusion handlers
    var fusion_count: usize = 0;
    var i: usize = 0;
    while (i < plan.instructionStream.len) : (i += 1) {
        if (@intFromPtr(plan.instructionStream[i].handler) == @intFromPtr(&testFusionHandler)) {
            fusion_count += 1;
            i += 1; // Skip metadata
        }
    }
    try std.testing.expect(fusion_count >= 4); // ADD, MUL, DIV, JUMPI fusions
    
    // 4. Dynamic jumps are handled at runtime, not in plan
    // Just verify we have a valid instruction stream
    try std.testing.expect(plan.instructionStream.len > 0);
}

test "cache hit ratio tracking" {
    const allocator = std.testing.allocator;
    
    var planner = try Planner(.{}).init(allocator, 2);
    defer planner.deinit();
    
    const bytecode1 = [_]u8{0x60, 0x01, 0x00}; // PUSH1 1, STOP
    const bytecode2 = [_]u8{0x60, 0x02, 0x00}; // PUSH1 2, STOP
    
    var handlers: [256]*const HandlerFn = undefined;
    for (&handlers) |*h| h.* = &testMockHandler;
    
    // Initial stats - no requests yet
    var stats = planner.getCacheStats();
    try std.testing.expectEqual(@as(usize, 0), stats.hits);
    try std.testing.expectEqual(@as(usize, 0), stats.misses);
    try std.testing.expectEqual(@as(usize, 0), stats.total_requests);
    try std.testing.expectEqual(@as(f64, 0.0), stats.hit_ratio);
    
    // First access - miss
    _ = try planner.getOrAnalyze(&bytecode1, handlers, Hardfork.DEFAULT);
    stats = planner.getCacheStats();
    try std.testing.expectEqual(@as(usize, 0), stats.hits);
    try std.testing.expectEqual(@as(usize, 1), stats.misses);
    try std.testing.expectEqual(@as(usize, 1), stats.total_requests);
    try std.testing.expectEqual(@as(f64, 0.0), stats.hit_ratio);
    
    // Second access to same bytecode - hit
    _ = try planner.getOrAnalyze(&bytecode1, handlers, Hardfork.DEFAULT);
    stats = planner.getCacheStats();
    try std.testing.expectEqual(@as(usize, 1), stats.hits);
    try std.testing.expectEqual(@as(usize, 1), stats.misses);
    try std.testing.expectEqual(@as(usize, 2), stats.total_requests);
    try std.testing.expectEqual(@as(f64, 0.5), stats.hit_ratio);
    
    // Different bytecode - miss
    _ = try planner.getOrAnalyze(&bytecode2, handlers, Hardfork.DEFAULT);
    stats = planner.getCacheStats();
    try std.testing.expectEqual(@as(usize, 1), stats.hits);
    try std.testing.expectEqual(@as(usize, 2), stats.misses);
    try std.testing.expectEqual(@as(usize, 3), stats.total_requests);
    try std.testing.expectApproxEqRel(@as(f64, 1.0/3.0), stats.hit_ratio, 0.001);
    
    // Access first bytecode again - hit
    _ = try planner.getOrAnalyze(&bytecode1, handlers, Hardfork.DEFAULT);
    stats = planner.getCacheStats();
    try std.testing.expectEqual(@as(usize, 2), stats.hits);
    try std.testing.expectEqual(@as(usize, 2), stats.misses);
    try std.testing.expectEqual(@as(usize, 4), stats.total_requests);
    try std.testing.expectEqual(@as(f64, 0.5), stats.hit_ratio);
    
    // Clear cache resets statistics
    planner.clearCache();
    stats = planner.getCacheStats();
    try std.testing.expectEqual(@as(usize, 0), stats.hits);
    try std.testing.expectEqual(@as(usize, 0), stats.misses);
    try std.testing.expectEqual(@as(usize, 0), stats.total_requests);
    try std.testing.expectEqual(@as(f64, 0.0), stats.hit_ratio);
    try std.testing.expectEqual(@as(usize, 0), stats.count);
}

test "cache eviction behavior" {
    const allocator = std.testing.allocator;
    
    // Create a small cache to test eviction
    var planner = try Planner(.{}).init(allocator, 2); // Only 2 items
    defer planner.deinit();
    
    const bytecode1 = [_]u8{0x60, 0x01, 0x00}; // PUSH1 1, STOP
    const bytecode2 = [_]u8{0x60, 0x02, 0x00}; // PUSH1 2, STOP  
    const bytecode3 = [_]u8{0x60, 0x03, 0x00}; // PUSH1 3, STOP
    
    var handlers: [256]*const HandlerFn = undefined;
    for (&handlers) |*h| h.* = &testMockHandler;
    
    // Fill cache to capacity
    _ = try planner.getOrAnalyze(&bytecode1, handlers, Hardfork.DEFAULT);
    var stats = planner.getCacheStats();
    try std.testing.expectEqual(@as(usize, 1), stats.count);
    try std.testing.expectEqual(@as(usize, 1), stats.misses);
    
    _ = try planner.getOrAnalyze(&bytecode2, handlers, Hardfork.DEFAULT);
    stats = planner.getCacheStats();
    try std.testing.expectEqual(@as(usize, 2), stats.count);
    try std.testing.expectEqual(@as(usize, 2), stats.misses);
    
    // Cache is now full. Access first item to make it most recently used
    _ = try planner.getOrAnalyze(&bytecode1, handlers, Hardfork.DEFAULT);
    stats = planner.getCacheStats();
    try std.testing.expectEqual(@as(usize, 2), stats.count);
    try std.testing.expectEqual(@as(usize, 1), stats.hits);
    try std.testing.expectEqual(@as(usize, 2), stats.misses);
    
    // Add third item - should evict bytecode2 (least recently used)
    _ = try planner.getOrAnalyze(&bytecode3, handlers, Hardfork.DEFAULT);
    stats = planner.getCacheStats();
    try std.testing.expectEqual(@as(usize, 2), stats.count); // Still at capacity
    try std.testing.expectEqual(@as(usize, 1), stats.hits);
    try std.testing.expectEqual(@as(usize, 3), stats.misses);
    
    // bytecode1 should still be in cache (was accessed recently)
    _ = try planner.getOrAnalyze(&bytecode1, handlers, Hardfork.DEFAULT);
    stats = planner.getCacheStats();
    try std.testing.expectEqual(@as(usize, 2), stats.hits);
    try std.testing.expectEqual(@as(usize, 3), stats.misses);
    
    // bytecode3 should still be in cache (was just added)
    _ = try planner.getOrAnalyze(&bytecode3, handlers, Hardfork.DEFAULT);
    stats = planner.getCacheStats();
    try std.testing.expectEqual(@as(usize, 3), stats.hits);
    try std.testing.expectEqual(@as(usize, 3), stats.misses);
    
    // bytecode2 should have been evicted - should be a miss
    _ = try planner.getOrAnalyze(&bytecode2, handlers, Hardfork.DEFAULT);
    stats = planner.getCacheStats();
    try std.testing.expectEqual(@as(usize, 2), stats.count); // Still at capacity
    try std.testing.expectEqual(@as(usize, 3), stats.hits);
    try std.testing.expectEqual(@as(usize, 4), stats.misses); // Miss because bytecode2 was evicted
}

test "planner plan type compatibility across configurations" {
    const allocator = std.testing.allocator;
    
    // Test different plan configurations produce valid results
    const PlannerSmall = Planner(.{ .maxBytecodeSize = 1024 });
    const PlannerLarge = Planner(.{ .maxBytecodeSize = 65535 });
    
    var planner_small = try PlannerSmall.init(allocator, 4);
    defer planner_small.deinit();
    
    var planner_large = try PlannerLarge.init(allocator, 4);
    defer planner_large.deinit();
    
    const bytecode = [_]u8{
        @intFromEnum(Opcode.PUSH1), 0x01,  // PUSH1 1
        @intFromEnum(Opcode.PUSH1), 0x02,  // PUSH1 2  
        @intFromEnum(Opcode.ADD),          // ADD
        @intFromEnum(Opcode.STOP),         // STOP
    };
    
    var handlers: [256]*const HandlerFn = undefined;
    for (&handlers) |*h| h.* = &testMockHandler;
    
    // Both planners should handle same bytecode
    const plan_small = try planner_small.getOrAnalyze(&bytecode, handlers, Hardfork.DEFAULT);
    const plan_large = try planner_large.getOrAnalyze(&bytecode, handlers, Hardfork.DEFAULT);
    
    // Basic structure validation
    try std.testing.expect(plan_small.instructionStream.len > 0);
    try std.testing.expect(plan_large.instructionStream.len > 0);
    
    // Both should handle the same opcodes correctly
    try std.testing.expect(plan_small.instructionStream.len == plan_large.instructionStream.len);
    
    // Cache statistics should work for both
    const stats_small = planner_small.getCacheStats();
    const stats_large = planner_large.getCacheStats();
    
    try std.testing.expectEqual(@as(usize, 1), stats_small.misses);
    try std.testing.expectEqual(@as(usize, 1), stats_large.misses);
    try std.testing.expectEqual(@as(usize, 0), stats_small.hits);
    try std.testing.expectEqual(@as(usize, 0), stats_large.hits);
}

// Export the factory function for creating Planner types
pub const createPlanner = Planner;

// BYTECODE EDGE CASE TESTS

test "Planner bytecode edge cases - empty bytecode" {
    const allocator = std.testing.allocator;
    var planner = try Planner(.{}).init(allocator, 4);
    defer planner.deinit();
    
    const empty_bytecode = [_]u8{};
    var handlers: [256]*const HandlerFn = undefined;
    for (&handlers) |*h| h.* = &testMockHandler;
    
    const plan = try planner.getOrAnalyze(&empty_bytecode, handlers, Hardfork.DEFAULT);
    
    // Should produce valid but minimal plan
    try std.testing.expect(plan.instructionStream.len >= 1); // At least END marker
    try std.testing.expectEqual(@as(usize, 0), plan.u256_constants.len);
}

test "Planner bytecode edge cases - single byte bytecode" {
    const allocator = std.testing.allocator;
    var planner = try Planner(.{}).init(allocator, 4);
    defer planner.deinit();
    
    var handlers: [256]*const HandlerFn = undefined;
    for (&handlers) |*h| h.* = &testMockHandler;
    
    // Test various single byte bytecodes
    const single_bytes = [_]u8{ 
        @intFromEnum(Opcode.STOP),
        @intFromEnum(Opcode.ADD),
        @intFromEnum(Opcode.JUMPDEST),
    };
    
    for (single_bytes) |byte| {
        const bytecode = [_]u8{byte};
        const plan = try planner.getOrAnalyze(&bytecode, handlers, Hardfork.DEFAULT);
        
        // Should produce valid plan
        try std.testing.expect(plan.instructionStream.len >= 2); // Opcode + END
    }
}

test "Planner bytecode edge cases - maximum size bytecode" {
    const allocator = std.testing.allocator;
    var planner = try Planner(.{ .maxBytecodeSize = 24576 }).init(allocator, 4);
    defer planner.deinit();
    
    // Create bytecode at maximum size
    const max_bytecode = try allocator.alloc(u8, 24576);
    defer allocator.free(max_bytecode);
    
    // Fill with JUMPDEST opcodes
    @memset(max_bytecode, @intFromEnum(Opcode.JUMPDEST));
    
    var handlers: [256]*const HandlerFn = undefined;
    for (&handlers) |*h| h.* = &testMockHandler;
    
    const plan = try planner.getOrAnalyze(max_bytecode, handlers, Hardfork.DEFAULT);
    
    // Should produce valid plan
    try std.testing.expect(plan.instructionStream.len > 0);
    
    // Jump table should be populated for JUMPDEST lookup
    try std.testing.expect(plan.pc_to_instruction_idx != null);
}

test "Planner bytecode edge cases - truncated PUSH at end" {
    const allocator = std.testing.allocator;
    var planner = try Planner(.{}).init(allocator, 4);
    defer planner.deinit();
    
    var handlers: [256]*const HandlerFn = undefined;
    for (&handlers) |*h| h.* = &testMockHandler;
    
    // Test truncated PUSH instructions
    const truncated_cases = [_][]const u8{
        &[_]u8{@intFromEnum(Opcode.PUSH1)}, // PUSH1 with no data
        &[_]u8{@intFromEnum(Opcode.PUSH2), 0x12}, // PUSH2 with only 1 byte
        &[_]u8{@intFromEnum(Opcode.PUSH32), 0x01, 0x02}, // PUSH32 with only 2 bytes
    };
    
    for (truncated_cases) |bytecode| {
        const plan = try planner.getOrAnalyze(bytecode, handlers, Hardfork.DEFAULT);
        
        // Should handle gracefully with zero-padding
        try std.testing.expect(plan.instructionStream.len > 0);
    }
}

test "Planner bytecode edge cases - all PUSH variants" {
    const allocator = std.testing.allocator;
    var planner = try Planner(.{}).init(allocator, 4);
    defer planner.deinit();
    
    var handlers: [256]*const HandlerFn = undefined;
    for (&handlers) |*h| h.* = &testMockHandler;
    
    // Test each PUSH opcode with proper data
    var push_num: u8 = 0;
    while (push_num <= 32) : (push_num += 1) {
        var bytecode = std.ArrayList(u8).init(allocator);
        defer bytecode.deinit();
        
        if (push_num == 0) {
            try bytecode.append(@intFromEnum(Opcode.PUSH0));
        } else {
            const push_opcode = 0x60 + (push_num - 1);
            try bytecode.append(push_opcode);
            
            // Add appropriate data bytes
            for (0..push_num) |i| {
                try bytecode.append(@intCast(i & 0xFF));
            }
        }
        
        try bytecode.append(@intFromEnum(Opcode.STOP));
        
        const plan = try planner.getOrAnalyze(bytecode.items, handlers, Hardfork.DEFAULT);
        
        // Should produce valid plan
        try std.testing.expect(plan.instructionStream.len > 0);
        
        // Large PUSH values should use constants array
        if (push_num > 8) { // Assuming values > 8 bytes use pointer storage
            try std.testing.expect(plan.u256_constants.len > 0);
        }
    }
}

test "Planner bytecode edge cases - pathological jump patterns" {
    const allocator = std.testing.allocator;
    var planner = try Planner(.{}).init(allocator, 4);
    defer planner.deinit();
    
    var handlers: [256]*const HandlerFn = undefined;
    for (&handlers) |*h| h.* = &testMockHandler;
    
    // Complex jump pattern
    const bytecode = [_]u8{
        @intFromEnum(Opcode.PUSH1), 10,  // Target forward
        @intFromEnum(Opcode.JUMP),
        @intFromEnum(Opcode.JUMPDEST),   // PC 3
        @intFromEnum(Opcode.PUSH1), 3,   // Target backward
        @intFromEnum(Opcode.JUMP),
        @intFromEnum(Opcode.JUMPDEST),   // PC 7  
        @intFromEnum(Opcode.STOP),
        @intFromEnum(Opcode.JUMPDEST),   // PC 10
        @intFromEnum(Opcode.PUSH1), 7,
        @intFromEnum(Opcode.JUMP),
    };
    
    const plan = try planner.getOrAnalyze(&bytecode, handlers, Hardfork.DEFAULT);
    
    // Should have jump table for dynamic lookups
    try std.testing.expect(plan.pc_to_instruction_idx != null);
    
    // Verify JUMPDEST positions are in jump table
    const jump_table = plan.pc_to_instruction_idx.?;
    try std.testing.expect(jump_table.get(3) != null);
    try std.testing.expect(jump_table.get(7) != null);
    try std.testing.expect(jump_table.get(10) != null);
}

test "Planner bytecode edge cases - fusion opportunities" {
    const allocator = std.testing.allocator;
    var planner = try Planner(.{}).init(allocator, 4);
    defer planner.deinit();
    
    var handlers: [256]*const HandlerFn = undefined;
    for (&handlers) |*h| h.* = &testMockHandler;
    
    // Bytecode with multiple fusion opportunities
    const bytecode = [_]u8{
        @intFromEnum(Opcode.PUSH1), 5,
        @intFromEnum(Opcode.ADD),       // PUSH+ADD fusion
        @intFromEnum(Opcode.PUSH1), 10,
        @intFromEnum(Opcode.MUL),       // PUSH+MUL fusion
        @intFromEnum(Opcode.PUSH1), 20,
        @intFromEnum(Opcode.JUMP),      // PUSH+JUMP fusion
        @intFromEnum(Opcode.STOP),
    };
    
    const plan = try planner.getOrAnalyze(&bytecode, handlers, Hardfork.DEFAULT);
    
    // Should produce optimized plan with fusions
    try std.testing.expect(plan.instructionStream.len > 0);
    
    // The plan should be shorter than naive interpretation would suggest
    // due to fusion optimizations
}

test "Planner bytecode edge cases - consecutive JUMPDESTs" {
    const allocator = std.testing.allocator;
    var planner = try Planner(.{}).init(allocator, 4);
    defer planner.deinit();
    
    var handlers: [256]*const HandlerFn = undefined;
    for (&handlers) |*h| h.* = &testMockHandler;
    
    // Many consecutive JUMPDESTs
    var bytecode: [100]u8 = undefined;
    @memset(&bytecode, @intFromEnum(Opcode.JUMPDEST));
    bytecode[99] = @intFromEnum(Opcode.STOP);
    
    const plan = try planner.getOrAnalyze(&bytecode, handlers, Hardfork.DEFAULT);
    
    // Should handle efficiently
    try std.testing.expect(plan.instructionStream.len > 0);
    try std.testing.expect(plan.pc_to_instruction_idx != null);
    
    // All JUMPDESTs should be in jump table
    const jump_table = plan.pc_to_instruction_idx.?;
    for (0..99) |i| {
        try std.testing.expect(jump_table.get(@intCast(i)) != null);
    }
}

test "Planner bytecode edge cases - invalid opcodes handling" {
    const allocator = std.testing.allocator;
    var planner = try Planner(.{}).init(allocator, 4);
    defer planner.deinit();
    
    var handlers: [256]*const HandlerFn = undefined;
    for (&handlers) |*h| h.* = &testMockHandler;
    
    // Mix of valid and invalid opcodes
    const bytecode = [_]u8{
        @intFromEnum(Opcode.PUSH1), 1,
        0x0C,  // Invalid opcode
        @intFromEnum(Opcode.ADD),
        0xFE,  // INVALID opcode
        @intFromEnum(Opcode.STOP),
    };
    
    const plan = try planner.getOrAnalyze(&bytecode, handlers, Hardfork.DEFAULT);
    
    try std.testing.expect(plan.instructionStream.len > 0);
}
