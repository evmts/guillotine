# Phase 4: Jump Analysis Optimization

## Objective
Replace the current BitVec64-based jump destination validation with sorted arrays and binary search, matching evmone's approach for O(log n) jump resolution.

## Background
Current implementation uses BitVec64 for O(1) jump validation but requires bit manipulation. EVMone uses sorted arrays with binary search because:
1. Better cache locality (sequential access)
2. Smaller memory footprint for sparse jumpdests
3. Works naturally with instruction stream model
4. No bit manipulation overhead

## Dependencies
- Phase 2: Block metadata analysis (part of same analysis pass)
- Existing: BitVec64 implementation for reference

## Current State Analysis

### Current Implementation (BitVec64)
```zig
// From src/evm/frame/bitvec.zig
pub const BitVec64 = struct {
    bits: []u64,
    
    pub fn isSet(self: *const BitVec64, index: usize) bool {
        const word_index = index / 64;
        const bit_index = @intCast(u6, index % 64);
        return (self.bits[word_index] >> bit_index) & 1 == 1;
    }
};

// Usage in JUMP
pub fn op_jump(frame: *Frame) !void {
    const dest = try frame.stack.pop();
    if (dest > MAX_CODE_SIZE) return error.InvalidJump;
    
    // O(1) lookup but requires bit manipulation
    if (!frame.jumpdest_map.isSet(@intCast(usize, dest))) {
        return error.InvalidJump;
    }
    frame.pc = @intCast(usize, dest);
}
```

### Target Implementation (Sorted Arrays)
```zig
pub const JumpAnalysis = struct {
    jumpdest_offsets: []const u32,  // Sorted PC values (original code)
    jumpdest_targets: []const u32,  // Instruction indices (for advanced mode)
    
    pub fn isValidJump(self: *const JumpAnalysis, pc: u32) bool {
        // Binary search in sorted array
        return std.sort.binarySearch(u32, pc, self.jumpdest_offsets, {}, comptime std.sort.asc(u32)) != null;
    }
    
    pub fn getJumpTarget(self: *const JumpAnalysis, pc: u32) ?u32 {
        const index = std.sort.binarySearch(u32, pc, self.jumpdest_offsets, {}, comptime std.sort.asc(u32));
        return if (index) |i| self.jumpdest_targets[i] else null;
    }
};
```

## Implementation Steps

### Step 1: Collect Jump Destinations During Analysis
```zig
pub fn analyzeJumpDestinations(allocator: Allocator, code: []const u8) !JumpAnalysis {
    var jumpdests = ArrayList(u32).init(allocator);
    var targets = ArrayList(u32).init(allocator);
    defer jumpdests.deinit();
    defer targets.deinit();
    
    var pc: usize = 0;
    var instr_index: u32 = 0;
    
    while (pc < code.len) {
        const opcode = code[pc];
        
        if (opcode == 0x5B) { // JUMPDEST
            try jumpdests.append(@intCast(u32, pc));
            try targets.append(instr_index);
        }
        
        pc += 1;
        instr_index += 1;
        
        // Skip push data
        if (opcode >= 0x60 and opcode <= 0x7F) {
            const push_size = opcode - 0x5F;
            pc += push_size;
        }
    }
    
    // Already sorted by construction since we scan linearly
    return JumpAnalysis{
        .jumpdest_offsets = try jumpdests.toOwnedSlice(),
        .jumpdest_targets = try targets.toOwnedSlice(),
    };
}
```

### Step 2: Optimize Binary Search for EVM Patterns
```zig
pub const OptimizedJumpAnalysis = struct {
    jumpdest_offsets: []const u32,
    jumpdest_targets: []const u32,
    
    // Cache for recent jumps (EVM often jumps to same destinations)
    recent_jumps: [4]struct { pc: u32, target: u32 },
    recent_index: u8,
    
    pub fn findJumpTarget(self: *OptimizedJumpAnalysis, pc: u32) ?u32 {
        // Check cache first (common case: loops)
        for (self.recent_jumps) |recent| {
            if (recent.pc == pc) {
                return recent.target;
            }
        }
        
        // Binary search with hints
        const result = self.binarySearchWithHints(pc);
        
        // Update cache
        if (result) |target| {
            self.recent_jumps[self.recent_index] = .{ .pc = pc, .target = target };
            self.recent_index = (self.recent_index + 1) % 4;
        }
        
        return result;
    }
    
    fn binarySearchWithHints(self: *const OptimizedJumpAnalysis, pc: u32) ?u32 {
        const offsets = self.jumpdest_offsets;
        
        // Common patterns in EVM:
        // 1. Jump backwards (loops) - search from end
        // 2. Jump forwards (conditionals) - search from start
        
        // Quick bounds check
        if (offsets.len == 0) return null;
        if (pc < offsets[0] or pc > offsets[offsets.len - 1]) return null;
        
        // Standard binary search
        var left: usize = 0;
        var right: usize = offsets.len;
        
        while (left < right) {
            const mid = left + (right - left) / 2;
            const mid_val = offsets[mid];
            
            if (mid_val == pc) {
                return self.jumpdest_targets[mid];
            } else if (mid_val < pc) {
                left = mid + 1;
            } else {
                right = mid;
            }
        }
        
        return null;
    }
};
```

### Step 3: Static vs Dynamic Jump Classification
```zig
pub const JumpType = enum {
    Static,   // PUSH + JUMP (destination known at analysis)
    Dynamic,  // Expression + JUMP (destination computed at runtime)
};

pub fn classifyJumps(code: []const u8) !HashMap(usize, JumpType) {
    var jumps = HashMap(usize, JumpType).init(allocator);
    var pc: usize = 0;
    var last_push_value: ?u32 = null;
    
    while (pc < code.len) {
        const opcode = code[pc];
        
        switch (opcode) {
            0x60...0x7F => { // PUSH
                const push_size = opcode - 0x5F;
                var value: u32 = 0;
                
                // Read push value (up to 4 bytes for jump destinations)
                var i: usize = 0;
                while (i < push_size and i < 4 and pc + 1 + i < code.len) : (i += 1) {
                    value = (value << 8) | code[pc + 1 + i];
                }
                
                last_push_value = value;
                pc += push_size + 1;
            },
            0x56 => { // JUMP
                const jump_type = if (last_push_value != null)
                    JumpType.Static
                else
                    JumpType.Dynamic;
                    
                try jumps.put(pc, jump_type);
                last_push_value = null;
                pc += 1;
            },
            0x57 => { // JUMPI
                const jump_type = if (last_push_value != null)
                    JumpType.Static
                else
                    JumpType.Dynamic;
                    
                try jumps.put(pc, jump_type);
                last_push_value = null;
                pc += 1;
            },
            else => {
                // Any other opcode invalidates static jump pattern
                if (opcode < 0x80 or opcode > 0x8F) { // Not DUP
                    last_push_value = null;
                }
                pc += 1;
            },
        }
    }
    
    return jumps;
}
```

### Step 4: Optimized Jump Operations
```zig
// For interpreter mode
pub fn op_jump_optimized(frame: *Frame) !void {
    const dest = try frame.stack.pop();
    
    // Fast path: check if within code bounds
    if (dest >= frame.contract.code.len) {
        return error.InvalidJump;
    }
    
    const pc = @intCast(u32, dest);
    
    // Use optimized binary search
    if (!frame.jump_analysis.isValidJump(pc)) {
        return error.InvalidJump;
    }
    
    frame.pc = @intCast(usize, pc);
}

// For advanced mode
pub fn op_jump_advanced(frame: *Frame) !*const Instruction {
    const dest = frame.stack.pop_unsafe();
    
    if (dest > std.math.maxInt(u32)) {
        return frame.exit(error.InvalidJump);
    }
    
    const pc = @intCast(u32, dest);
    const target = frame.jump_analysis.getJumpTarget(pc) orelse {
        return frame.exit(error.InvalidJump);
    };
    
    // Return pointer to target instruction
    return &frame.instructions[target];
}
```

### Step 5: Pre-validation of Static Jumps
```zig
pub fn prevalidateStaticJumps(code: []const u8, jumpdests: []const u32) !void {
    const jump_types = try classifyJumps(code);
    defer jump_types.deinit();
    
    var pc: usize = 0;
    while (pc < code.len) {
        const opcode = code[pc];
        
        if (opcode == 0x56 or opcode == 0x57) { // JUMP or JUMPI
            if (jump_types.get(pc)) |jump_type| {
                if (jump_type == .Static) {
                    // Extract destination from preceding PUSH
                    const dest = extractPushValue(code, pc) orelse continue;
                    
                    // Validate at analysis time
                    const is_valid = std.sort.binarySearch(
                        u32, 
                        @intCast(u32, dest), 
                        jumpdests, 
                        {}, 
                        comptime std.sort.asc(u32)
                    ) != null;
                    
                    if (!is_valid) {
                        std.log.warn("Invalid static jump at PC={} to {}", .{pc, dest});
                        // Could mark this for special handling
                    }
                }
            }
        }
        
        pc += 1;
        if (opcode >= 0x60 and opcode <= 0x7F) {
            pc += opcode - 0x5F;
        }
    }
}
```

## Testing Requirements

### Unit Tests
```zig
test "binary search jump validation" {
    const jumpdests = [_]u32{10, 50, 100, 200, 500};
    const analysis = JumpAnalysis{
        .jumpdest_offsets = &jumpdests,
        .jumpdest_targets = &jumpdests, // Same for testing
    };
    
    // Valid jumps
    try expect(analysis.isValidJump(50));
    try expect(analysis.isValidJump(200));
    
    // Invalid jumps
    try expect(!analysis.isValidJump(51));
    try expect(!analysis.isValidJump(0));
    try expect(!analysis.isValidJump(1000));
}

test "jump cache effectiveness" {
    var analysis = OptimizedJumpAnalysis{...};
    
    // Simulate loop jumping to same destination
    for (0..1000) |_| {
        const target = analysis.findJumpTarget(100);
        try expectEqual(@as(u32, 50), target.?);
    }
    
    // Cache should make this very fast
}
```

### Performance Tests
1. Compare BitVec vs binary search for various contract sizes
2. Measure cache hit rate for typical contracts
3. Test with contracts having many/few jumpdests

## Success Criteria

### Functional
- [ ] Correct jump validation for all test cases
- [ ] Handles static and dynamic jumps
- [ ] Pre-validation of static jumps works
- [ ] All existing tests pass

### Performance
- [ ] O(log n) jump validation
- [ ] Cache hit rate > 80% for loops
- [ ] Faster than BitVec for typical contracts
- [ ] Minimal memory overhead

### Code Quality
- [ ] Clean integration with block analysis
- [ ] Well-documented binary search optimizations
- [ ] Reusable for both interpreter and advanced modes

## Benchmarking

### Jump Resolution Performance
```zig
fn benchmarkJumpResolution() !void {
    // Create contracts with varying jumpdest counts
    const jumpdest_counts = [_]usize{10, 100, 1000, 10000};
    
    for (jumpdest_counts) |count| {
        // Generate jumpdests
        var jumpdests = try allocator.alloc(u32, count);
        for (jumpdests, 0..) |*dest, i| {
            dest.* = @intCast(u32, i * 100);
        }
        
        // Benchmark BitVec
        var bitvec = try BitVec64.init(allocator, count * 100);
        for (jumpdests) |dest| {
            bitvec.set(dest);
        }
        
        const bitvec_start = std.time.nanoTimestamp();
        for (0..100000) |i| {
            _ = bitvec.isSet(@intCast(usize, i % (count * 100)));
        }
        const bitvec_time = std.time.nanoTimestamp() - bitvec_start;
        
        // Benchmark binary search
        const analysis = JumpAnalysis{ .jumpdest_offsets = jumpdests };
        
        const binary_start = std.time.nanoTimestamp();
        for (0..100000) |i| {
            _ = analysis.isValidJump(@intCast(u32, i % (count * 100)));
        }
        const binary_time = std.time.nanoTimestamp() - binary_start;
        
        std.debug.print("Jumpdests: {}, BitVec: {}ns, Binary: {}ns\n", 
            .{count, bitvec_time, binary_time});
    }
}
```

## Risk Mitigation

### Correctness
- Extensive testing against BitVec implementation
- Fuzzing with random jump patterns
- Verify identical behavior

### Performance
- Profile with real contracts
- Tune cache size based on measurements
- Consider hybrid approach for small contracts

### Memory
- Limit maximum jumpdest count
- Use compact representation (u32 vs u64)
- Share analysis between calls

## Reference Implementation

EVMone's approach:
- `evmone/lib/evmone/advanced_analysis.hpp` - jumpdest arrays
- Binary search in `find_jumpdest()` function
- No caching (we improve with recent jump cache)

## Next Phase Dependencies

This optimization enables:
- Phase 5: Instruction stream (uses jumpdest_targets)
- Phase 6: Advanced execution (needs fast jump resolution)
- Better performance for contracts with many jumps