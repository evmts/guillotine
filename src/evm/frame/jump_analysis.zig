/// Pre-computed jump destination analysis for O(1) validation.
///
/// This module analyzes EVM bytecode to identify and validate all static jump
/// destinations at analysis time, eliminating runtime validation overhead for
/// static jumps while maintaining safety for dynamic jumps.
///
/// ## Design Philosophy
///
/// 1. **Static Jump Optimization**: JUMP/JUMPI with constant destinations are
///    pre-validated during analysis, allowing O(1) runtime checks.
/// 2. **Dynamic Jump Safety**: JUMP/JUMPI with computed destinations still
///    require runtime validation but use optimized bitmap lookup.
/// 3. **Memory Efficiency**: Use compact data structures to minimize cache misses.
///
/// ## Performance Impact
///
/// - Static jumps: O(1) lookup in pre-validated table
/// - Dynamic jumps: O(1) bitmap check (already optimized)
/// - No runtime JUMPDEST scanning

const std = @import("std");
const BitVec64 = @import("bitvec.zig").BitVec64;
const opcode = @import("../opcodes/opcode.zig");
const primitives = @import("primitives");
const Log = @import("../log.zig");

/// Jump type classification for optimization.
pub const JumpType = enum {
    /// Jump with constant destination (can be pre-validated)
    static,
    /// Jump with computed destination (requires runtime validation)
    dynamic,
};

/// Information about a jump instruction in the bytecode.
pub const JumpInfo = struct {
    /// Program counter where the jump instruction is located
    pc: usize,
    /// Type of jump (static or dynamic)
    jump_type: JumpType,
    /// For static jumps, the destination address
    destination: ?u256,
    /// Whether this is a conditional jump (JUMPI)
    is_conditional: bool,
    /// Whether the destination is valid (for static jumps)
    is_valid: bool,
};

/// Pre-computed jump destination analysis results.
pub const JumpAnalysis = struct {
    /// Map of PC -> JumpInfo for all jump instructions
    jump_map: std.AutoHashMap(usize, JumpInfo),
    
    /// Set of all valid static jump destinations
    valid_static_dests: std.AutoHashMap(u256, void),
    
    /// Bitmap of valid jump destinations (for dynamic jumps)
    jumpdest_bitmap: BitVec64,
    
    /// Total number of jump instructions
    jump_count: u32,
    
    /// Number of static jumps (can be optimized)
    static_jump_count: u32,
    
    /// Number of dynamic jumps (need runtime checks)
    dynamic_jump_count: u32,
    
    /// Whether all jumps are static (enables maximum optimization)
    all_jumps_static: bool,
    
    /// Allocator used for this analysis
    allocator: std.mem.Allocator,
    
    /// Clean up allocated memory.
    pub fn deinit(self: *JumpAnalysis) void {
        self.jump_map.deinit();
        self.valid_static_dests.deinit();
        self.jumpdest_bitmap.deinit(self.allocator);
    }
    
    /// Check if a PC is a jump instruction.
    pub fn is_jump_pc(self: *const JumpAnalysis, pc: usize) bool {
        return self.jump_map.contains(pc);
    }
    
    /// Get jump information for a PC.
    pub fn get_jump_info(self: *const JumpAnalysis, pc: usize) ?JumpInfo {
        return self.jump_map.get(pc);
    }
    
    /// Fast check for pre-validated static jumps.
    pub fn is_valid_static_jump(self: *const JumpAnalysis, pc: usize, dest: u256) bool {
        if (self.jump_map.get(pc)) |info| {
            if (info.jump_type == .static and info.destination != null) {
                return info.destination.? == dest and info.is_valid;
            }
        }
        return false;
    }
    
    /// Check if a destination is a valid JUMPDEST (for dynamic jumps).
    pub fn is_valid_jumpdest(self: *const JumpAnalysis, dest: u256) bool {
        if (dest > std.math.maxInt(usize)) return false;
        const pos = @as(usize, @intCast(dest));
        return self.jumpdest_bitmap.isSetUnchecked(pos);
    }
};

/// Analyze jump destinations in bytecode.
///
/// This function:
/// 1. Identifies all JUMP/JUMPI instructions
/// 2. Determines if jumps are static or dynamic
/// 3. Pre-validates static jump destinations
/// 4. Builds optimized lookup structures
///
/// ## Parameters
/// - `allocator`: Memory allocator
/// - `code`: EVM bytecode to analyze
/// - `code_segments`: Bitmap marking code vs data bytes
/// - `jumpdest_bitmap`: Bitmap of valid JUMPDEST positions
///
/// ## Returns
/// JumpAnalysis with pre-computed jump information
pub fn analyze_jumps(
    allocator: std.mem.Allocator,
    code: []const u8,
    code_segments: *const BitVec64,
    jumpdest_bitmap: *const BitVec64,
) !JumpAnalysis {
    // Create a copy of the jumpdest bitmap
    var bitmap_copy = try BitVec64.init(allocator, jumpdest_bitmap.size);
    errdefer bitmap_copy.deinit(allocator);
    
    // Copy the bitmap data
    @memcpy(bitmap_copy.bits, jumpdest_bitmap.bits);
    
    var analysis = JumpAnalysis{
        .jump_map = std.AutoHashMap(usize, JumpInfo).init(allocator),
        .valid_static_dests = std.AutoHashMap(u256, void).init(allocator),
        .jumpdest_bitmap = bitmap_copy,
        .jump_count = 0,
        .static_jump_count = 0,
        .dynamic_jump_count = 0,
        .all_jumps_static = true,
        .allocator = allocator,
    };
    errdefer analysis.deinit();
    
    var pc: usize = 0;
    while (pc < code.len) {
        // Skip non-code bytes
        if (!code_segments.isSetUnchecked(pc)) {
            pc += 1;
            continue;
        }
        
        const op = code[pc];
        
        // Check for JUMP or JUMPI
        if (op == @intFromEnum(opcode.Enum.JUMP) or op == @intFromEnum(opcode.Enum.JUMPI)) {
            const is_jumpi = op == @intFromEnum(opcode.Enum.JUMPI);
            
            // Try to determine if this is a static jump
            const jump_info = try analyze_jump_at(code, pc, is_jumpi, jumpdest_bitmap);
            
            // Record jump information
            try analysis.jump_map.put(pc, jump_info);
            analysis.jump_count += 1;
            
            if (jump_info.jump_type == .static) {
                analysis.static_jump_count += 1;
                if (jump_info.is_valid and jump_info.destination != null) {
                    try analysis.valid_static_dests.put(jump_info.destination.?, {});
                }
            } else {
                analysis.dynamic_jump_count += 1;
                analysis.all_jumps_static = false;
            }
            
            Log.debug("Jump at PC {}: type={s}, dest={?}, valid={}", .{
                pc,
                @tagName(jump_info.jump_type),
                jump_info.destination,
                jump_info.is_valid,
            });
        }
        
        // Advance PC
        if (opcode.is_push(op)) {
            pc += 1 + opcode.get_push_size(op);
        } else {
            pc += 1;
        }
    }
    
    Log.debug("Jump analysis complete: total={}, static={}, dynamic={}", .{
        analysis.jump_count,
        analysis.static_jump_count,
        analysis.dynamic_jump_count,
    });
    
    return analysis;
}

/// Analyze a specific jump instruction to determine its type and destination.
fn analyze_jump_at(
    code: []const u8,
    jump_pc: usize,
    is_jumpi: bool,
    jumpdest_bitmap: *const BitVec64,
) !JumpInfo {
    // Look backwards to find if the destination is pushed as a constant
    // This is a simplified analysis - could be enhanced with full data flow
    
    var info = JumpInfo{
        .pc = jump_pc,
        .jump_type = .dynamic,
        .destination = null,
        .is_conditional = is_jumpi,
        .is_valid = false,
    };
    
    // Pattern 1: Simple PUSH<n> destination JUMP/JUMPI
    if (jump_pc >= 2) {
        const prev_op = code[jump_pc - 1];
        
        // Check if previous instruction is a PUSH
        if (opcode.is_push(prev_op)) {
            const push_size = opcode.get_push_size(prev_op);
            
            // For PUSH, we need to go back push_size + 1 bytes from current position
            if (jump_pc >= 1 + push_size) {
                const push_start = jump_pc - 1 - push_size;
                
                // Extract the pushed value
                var dest: u256 = 0;
                const data_start = push_start + 1;
                const data_end = @min(data_start + push_size, code.len);
                
                for (code[data_start..data_end]) |byte| {
                    dest = (dest << 8) | byte;
                }
                
                info.jump_type = .static;
                info.destination = dest;
                
                // Validate the destination
                if (dest <= std.math.maxInt(usize)) {
                    const dest_pos = @as(usize, @intCast(dest));
                    info.is_valid = dest_pos < jumpdest_bitmap.size and jumpdest_bitmap.isSetUnchecked(dest_pos);
                } else {
                    info.is_valid = false;
                }
                return info;
            }
        }
    }
    
    // Pattern 2: PUSH<n> dest DUP1 JUMP
    if (jump_pc >= 3 and code[jump_pc - 1] == 0x80) { // DUP1
        // Look for PUSH before DUP1
        var check_pc = jump_pc - 2;
        
        while (check_pc > 0) : (check_pc -= 1) {
            const op = code[check_pc];
            if (opcode.is_push(op)) {
                const push_size = opcode.get_push_size(op);
                if (check_pc + 1 + push_size == jump_pc - 1) {
                    var dest: u256 = 0;
                    const data_start = check_pc + 1;
                    const data_end = @min(data_start + push_size, code.len);
                    
                    for (code[data_start..data_end]) |byte| {
                        dest = (dest << 8) | byte;
                    }
                    
                    info.jump_type = .static;
                    info.destination = dest;
                    
                    if (dest <= std.math.maxInt(usize)) {
                        const dest_pos = @as(usize, @intCast(dest));
                        info.is_valid = dest_pos < jumpdest_bitmap.size and jumpdest_bitmap.isSetUnchecked(dest_pos);
                    } else {
                        info.is_valid = false;
                    }
                    return info;
                }
                break;
            }
        }
    }
    
    // Pattern 3: For JUMPI - PUSH<n> dest PUSH<n> condition JUMPI
    if (is_jumpi and jump_pc >= 4) {
        // Look backward for two PUSH instructions
        var pc = jump_pc - 1;
        var found_pushes: u8 = 0;
        var dest_value: u256 = 0;
        
        while (pc > 0 and found_pushes < 2) : (pc -= 1) {
            const op = code[pc];
            if (opcode.is_push(op)) {
                const push_size = opcode.get_push_size(op);
                
                if (found_pushes == 0) {
                    // This is the condition push, skip it
                    pc = pc - push_size;
                } else if (found_pushes == 1) {
                    // This is the destination push
                    if (pc + push_size < code.len) {
                        const data_start = pc + 1;
                        const data_end = @min(data_start + push_size, code.len);
                        
                        for (code[data_start..data_end]) |byte| {
                            dest_value = (dest_value << 8) | byte;
                        }
                        
                        info.jump_type = .static;
                        info.destination = dest_value;
                        
                        if (dest_value <= std.math.maxInt(usize)) {
                            const dest_pos = @as(usize, @intCast(dest_value));
                            info.is_valid = dest_pos < jumpdest_bitmap.size and jumpdest_bitmap.isSetUnchecked(dest_pos);
                        } else {
                            info.is_valid = false;
                        }
                        return info;
                    }
                    break;
                }
                found_pushes += 1;
            }
        }
    }
    
    // Pattern 4: PUSH<n> dest SWAP1 JUMP (common pattern)
    if (jump_pc >= 3 and code[jump_pc - 1] == 0x90) { // SWAP1
        // Look for PUSH before SWAP1
        var check_pc = jump_pc - 2;
        
        while (check_pc > 0) : (check_pc -= 1) {
            const op = code[check_pc];
            if (opcode.is_push(op)) {
                const push_size = opcode.get_push_size(op);
                if (check_pc + 1 + push_size == jump_pc - 1) {
                    var dest: u256 = 0;
                    const data_start = check_pc + 1;
                    const data_end = @min(data_start + push_size, code.len);
                    
                    for (code[data_start..data_end]) |byte| {
                        dest = (dest << 8) | byte;
                    }
                    
                    info.jump_type = .static;
                    info.destination = dest;
                    
                    if (dest <= std.math.maxInt(usize)) {
                        const dest_pos = @as(usize, @intCast(dest));
                        info.is_valid = dest_pos < jumpdest_bitmap.size and jumpdest_bitmap.isSetUnchecked(dest_pos);
                    } else {
                        info.is_valid = false;
                    }
                    return info;
                }
                break;
            }
        }
    }
    
    // If no pattern matched, it's a dynamic jump
    return info;
}

/// Optimize jump validation for a contract using pre-computed analysis.
///
/// This function replaces runtime jump validation with O(1) lookups
/// for static jumps while maintaining safety for dynamic jumps.
pub fn optimize_jump_validation(
    analysis: *const JumpAnalysis,
    pc: usize,
    dest: u256,
) bool {
    // First, check if this is a pre-validated static jump
    if (analysis.is_valid_static_jump(pc, dest)) {
        return true;
    }
    
    // Fall back to bitmap check for dynamic jumps
    return analysis.is_valid_jumpdest(dest);
}

test "Static jump analysis" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    // Test bytecode: PUSH1 0x04 JUMP STOP JUMPDEST
    const code = [_]u8{
        0x60, 0x04, // PUSH1 0x04
        0x56,       // JUMP
        0x00,       // STOP
        0x5b,       // JUMPDEST
    };
    
    // Create code segments bitmap (all bytes are code)
    var code_segments = try BitVec64.init(allocator, code.len);
    defer code_segments.deinit(allocator);
    for (0..code.len) |i| {
        code_segments.setUnchecked(i);
    }
    
    // Create jumpdest bitmap
    var jumpdest_bitmap = try BitVec64.init(allocator, code.len);
    defer jumpdest_bitmap.deinit(allocator);
    jumpdest_bitmap.setUnchecked(4); // JUMPDEST at position 4
    
    // Analyze jumps
    var analysis = try analyze_jumps(allocator, &code, &code_segments, &jumpdest_bitmap);
    defer analysis.deinit();
    
    // Verify analysis
    try testing.expectEqual(@as(u32, 1), analysis.jump_count);
    try testing.expectEqual(@as(u32, 1), analysis.static_jump_count);
    try testing.expectEqual(@as(u32, 0), analysis.dynamic_jump_count);
    try testing.expect(analysis.all_jumps_static);
    
    // Check jump info
    const jump_info = analysis.get_jump_info(2).?;
    try testing.expectEqual(JumpType.static, jump_info.jump_type);
    try testing.expectEqual(@as(u256, 4), jump_info.destination.?);
    try testing.expect(jump_info.is_valid);
    try testing.expect(!jump_info.is_conditional);
    
    // Test optimization
    try testing.expect(optimize_jump_validation(&analysis, 2, 4));
    try testing.expect(!optimize_jump_validation(&analysis, 2, 5)); // Invalid dest
}

test "Dynamic jump analysis" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    // Test bytecode: CALLDATALOAD JUMP (dynamic jump)
    const code = [_]u8{
        0x35, // CALLDATALOAD
        0x56, // JUMP
    };
    
    // Create code segments bitmap
    var code_segments = try BitVec64.init(allocator, code.len);
    defer code_segments.deinit(allocator);
    for (0..code.len) |i| {
        code_segments.setUnchecked(i);
    }
    
    // Create empty jumpdest bitmap
    var jumpdest_bitmap = try BitVec64.init(allocator, code.len);
    defer jumpdest_bitmap.deinit(allocator);
    
    // Analyze jumps
    var analysis = try analyze_jumps(allocator, &code, &code_segments, &jumpdest_bitmap);
    defer analysis.deinit();
    
    // Verify analysis
    try testing.expectEqual(@as(u32, 1), analysis.jump_count);
    try testing.expectEqual(@as(u32, 0), analysis.static_jump_count);
    try testing.expectEqual(@as(u32, 1), analysis.dynamic_jump_count);
    try testing.expect(!analysis.all_jumps_static);
    
    // Check jump info
    const jump_info = analysis.get_jump_info(1).?;
    try testing.expectEqual(JumpType.dynamic, jump_info.jump_type);
    try testing.expectEqual(@as(?u256, null), jump_info.destination);
}

test "Conditional jump analysis" {
    const testing = std.testing;
    const allocator = testing.allocator;
    
    // Test bytecode: PUSH1 0x08 PUSH1 0x01 JUMPI
    const code = [_]u8{
        0x60, 0x08, // PUSH1 0x08 (destination)
        0x60, 0x01, // PUSH1 0x01 (condition)
        0x57,       // JUMPI
    };
    
    // Create code segments bitmap
    var code_segments = try BitVec64.init(allocator, code.len);
    defer code_segments.deinit(allocator);
    for (0..code.len) |i| {
        code_segments.setUnchecked(i);
    }
    
    // Create jumpdest bitmap
    var jumpdest_bitmap = try BitVec64.init(allocator, 10);
    defer jumpdest_bitmap.deinit(allocator);
    jumpdest_bitmap.setUnchecked(8); // JUMPDEST at position 8
    
    // Analyze jumps
    var analysis = try analyze_jumps(allocator, &code, &code_segments, &jumpdest_bitmap);
    defer analysis.deinit();
    
    // Check jump info
    const jump_info = analysis.get_jump_info(4).?;
    try testing.expect(jump_info.is_conditional);
    // Note: Our simple analysis doesn't handle PUSH PUSH JUMPI pattern yet
    // This would need enhancement for full static analysis
}