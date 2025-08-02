const std = @import("std");
const opcode = @import("../opcodes/opcode.zig");
const Operation = @import("../opcodes/operation.zig");
const CodeAnalysis = @import("code_analysis.zig");
const ExtendedPcToOpEntry = CodeAnalysis.ExtendedPcToOpEntry;
const InstructionArg = CodeAnalysis.InstructionArg;
const JumpTable = @import("../jump_table/jump_table.zig");
const bitvec = @import("bitvec.zig");
const Log = @import("../log.zig");

/// Analyze bytecode and build extended entries with pre-extracted arguments
pub fn analyzeExtended(
    allocator: std.mem.Allocator,
    code: []const u8,
    code_hash: [32]u8,
    jump_table: *const JumpTable.JumpTable,
    jumpdests: []const u32,
    blocks: []const CodeAnalysis.BlockInfo,
) !struct {
    extended_entries: []ExtendedPcToOpEntry,
    large_push_values: []u256,
} {
    _ = code_hash;
    
    // Pre-allocate arrays
    var extended_entries = try allocator.alloc(ExtendedPcToOpEntry, code.len);
    errdefer allocator.free(extended_entries);
    
    var large_push_values = std.ArrayList(u256).init(allocator);
    defer large_push_values.deinit();
    
    // Build PC to block mapping for quick lookup
    var pc_to_block = std.AutoHashMap(u32, u32).init(allocator);
    defer pc_to_block.deinit();
    
    for (blocks, 0..) |block, idx| {
        if (block.start_pc < code.len) {
            try pc_to_block.put(block.start_pc, @intCast(idx));
        }
    }
    
    // Build jumpdest set for quick lookup
    var jumpdest_set = std.AutoHashMap(u32, void).init(allocator);
    defer jumpdest_set.deinit();
    
    for (jumpdests) |dest| {
        try jumpdest_set.put(dest, {});
    }
    
    // Single pass through bytecode
    var i: usize = 0;
    while (i < code.len) {
        const op = code[i];
        const operation = jump_table.table[op];
        
        // Initialize entry with basic operation data
        var entry = ExtendedPcToOpEntry{
            .operation = operation,
            .opcode_byte = op,
            .min_stack = operation.min_stack,
            .max_stack = operation.max_stack,
            .constant_gas = operation.constant_gas,
            .undefined = operation.undefined,
            .arg = .{ .none = {} },
            .size = 1,
        };
        
        // Extract arguments based on opcode
        switch (op) {
            @intFromEnum(opcode.Enum.PUSH1)...@intFromEnum(opcode.Enum.PUSH32) => {
                const push_size = op - @intFromEnum(opcode.Enum.PUSH0);
                entry.size = @intCast(1 + push_size);
                
                if (i + push_size < code.len) {
                    if (push_size <= 8) {
                        // Small push - store directly
                        var value: u64 = 0;
                        for (0..push_size) |j| {
                            if (i + 1 + j < code.len) {
                                value = (value << 8) | code[i + 1 + j];
                            }
                        }
                        entry.arg = .{ .small_push = value };
                        Log.debug("PUSH{} at pc={}: small_push value=0x{x}", .{ push_size, i, value });
                    } else {
                        // Large push - store separately
                        var value: u256 = 0;
                        for (0..push_size) |j| {
                            if (i + 1 + j < code.len) {
                                value = (value << 8) | code[i + 1 + j];
                            }
                        }
                        entry.arg = .{ .large_push_idx = @intCast(large_push_values.items.len) };
                        try large_push_values.append(value);
                        Log.debug("PUSH{} at pc={}: large_push_idx={}, value=0x{x}", .{ push_size, i, large_push_values.items.len - 1, value });
                    }
                }
            },
            
            @intFromEnum(opcode.Enum.JUMP) => {
                // Check if previous instruction was a PUSH with constant
                if (i > 0) {
                    const prev_entry = extended_entries[i - 1];
                    if (canExtractStaticJump(prev_entry, i, extended_entries)) {
                        const dest = extractStaticJumpDest(extended_entries, i);
                        if (jumpdest_set.contains(dest)) {
                            entry.arg = .{ .static_jump = dest };
                            Log.debug("JUMP at pc={}: static_jump dest={}", .{ i, dest });
                        }
                    }
                }
            },
            
            else => {
                // Check if this is a block start
                if (pc_to_block.get(@intCast(i))) |block_idx| {
                    entry.arg = .{ .block = .{
                        .block_idx = block_idx,
                        .is_block_start = true,
                    }};
                    Log.debug("Block start at pc={}: block_idx={}", .{ i, block_idx });
                }
            },
        }
        
        // Store entry
        extended_entries[i] = entry;
        
        // Fill data bytes with placeholder entries
        for (1..entry.size) |offset| {
            if (i + offset < code.len) {
                extended_entries[i + offset] = ExtendedPcToOpEntry{
                    .operation = &Operation.INVALID_OPERATION,
                    .opcode_byte = code[i + offset],
                    .min_stack = 0,
                    .max_stack = 0,
                    .constant_gas = 0,
                    .undefined = true,
                    .arg = .{ .none = {} },
                    .size = 0,
                };
            }
        }
        
        i += entry.size;
    }
    
    return .{
        .extended_entries = extended_entries,
        .large_push_values = try large_push_values.toOwnedSlice(),
    };
}

/// Check if we can extract a static jump destination
fn canExtractStaticJump(prev_entry: ExtendedPcToOpEntry, current_pc: usize, entries: []ExtendedPcToOpEntry) bool {
    _ = current_pc;
    _ = entries;
    
    // Check if previous instruction was a PUSH with a constant value
    switch (prev_entry.arg) {
        .small_push => return true,
        .large_push_idx => return true,
        else => return false,
    }
}

/// Extract static jump destination from previous PUSH
fn extractStaticJumpDest(entries: []ExtendedPcToOpEntry, jump_pc: usize) u32 {
    if (jump_pc == 0) return 0;
    
    const prev_entry = entries[jump_pc - 1];
    switch (prev_entry.arg) {
        .small_push => |value| return @intCast(@min(value, std.math.maxInt(u32))),
        .large_push_idx => {
            // For large push, we'd need access to the large_push_values array
            // For now, return 0 as we can't extract it here
            return 0;
        },
        else => return 0,
    }
}