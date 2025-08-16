/// Shadow execution framework for comparing main EVM with Mini EVM
/// 
/// This module provides continuous differential validation of the primary EVM
/// against the simpler Mini EVM reference implementation. It compares execution
/// results either per-call (default) or per-step (debug mode) to detect divergences.

const std = @import("std");
const builtin = @import("builtin");
const ExecutionError = @import("../execution/execution_error.zig");
const Frame = @import("../frame.zig").Frame;
const CallResult = @import("../evm/call_result.zig");

/// Shadow execution modes
pub const ShadowMode = enum { 
    off,        // No shadow execution
    per_call,   // Compare only call results (default for Debug builds)
    per_block   // Compare after each instruction block (for tracing/debugging)
};

/// Configuration for shadow execution behavior
pub const ShadowConfig = struct {
    mode: ShadowMode = if (builtin.mode == .Debug) .per_call else .off,
    
    // Comparison limits to prevent excessive memory usage
    stack_compare_limit: usize = 64,    // Top N stack elements to compare
    max_summary_length: usize = 128,    // Max length for diff summaries
    
    // Performance toggles
    compare_memory: bool = true,         // Compare memory size
    compare_memory_content: bool = false, // Compare memory content (expensive)
    compare_storage: bool = false,       // Compare storage (very expensive)
    max_memory_compare: usize = 256,     // Maximum memory bytes to compare
    fail_fast: bool = true,              // Stop on first mismatch
};

/// Types of mismatches that can occur
pub const MismatchField = enum { 
    success,     // Call success flag differs
    gas_left,    // Remaining gas differs  
    output,      // Output data differs
    logs,        // Log events differ
    storage,     // Storage writes differ
    stack,       // Stack state differs
    memory,      // Memory state differs
    pc           // Program counter differs
};

/// Context for the mismatch
pub const MismatchContext = enum { per_call, per_block };

/// Detailed mismatch information with memory management
pub const ShadowMismatch = struct {
    context: MismatchContext,
    op_pc: usize = 0,           // PC where mismatch occurred (per_step only)
    field: MismatchField,
    
    // Owned string data - must be freed by caller
    lhs_summary: []u8,          // Main EVM state summary
    rhs_summary: []u8,          // Mini EVM state summary
    
    // Optional detailed diff information
    diff_index: ?usize = null,  // First differing index (for arrays)
    diff_count: ?usize = null,  // Number of differing elements
    
    /// Free allocated summary strings
    pub fn deinit(self: *ShadowMismatch, allocator: std.mem.Allocator) void {
        allocator.free(self.lhs_summary);
        allocator.free(self.rhs_summary);
    }
    
    /// Create a mismatch with allocated summaries
    pub fn create(
        context: MismatchContext,
        op_pc: usize,
        field: MismatchField,
        lhs_data: []const u8,
        rhs_data: []const u8,
        allocator: std.mem.Allocator,
    ) !ShadowMismatch {
        const lhs_summary = try allocator.dupe(u8, lhs_data[0..@min(lhs_data.len, 128)]);
        errdefer allocator.free(lhs_summary);
        
        const rhs_summary = try allocator.dupe(u8, rhs_data[0..@min(rhs_data.len, 128)]);
        errdefer allocator.free(rhs_summary);
        
        return ShadowMismatch{
            .context = context,
            .op_pc = op_pc,
            .field = field,
            .lhs_summary = lhs_summary,
            .rhs_summary = rhs_summary,
        };
    }
};

/// Compare two CallResult structures for differences
pub fn compare_call_results(
    lhs: CallResult,
    rhs: CallResult,
    allocator: std.mem.Allocator,
) !?ShadowMismatch {
    // Success flag comparison
    if (lhs.success != rhs.success) {
        const lhs_str = if (lhs.success) "true" else "false";
        const rhs_str = if (rhs.success) "true" else "false";
        return try ShadowMismatch.create(.per_call, 0, .success, lhs_str, rhs_str, allocator);
    }
    
    // Gas comparison
    if (lhs.gas_left != rhs.gas_left) {
        var lhs_buf: [32]u8 = undefined;
        var rhs_buf: [32]u8 = undefined;
        const lhs_str = try std.fmt.bufPrint(&lhs_buf, "{}", .{lhs.gas_left});
        const rhs_str = try std.fmt.bufPrint(&rhs_buf, "{}", .{rhs.gas_left});
        return try ShadowMismatch.create(.per_call, 0, .gas_left, lhs_str, rhs_str, allocator);
    }
    
    // Output comparison
    const lhs_output = lhs.output orelse &.{};
    const rhs_output = rhs.output orelse &.{};
    
    if (lhs_output.len != rhs_output.len) {
        var lhs_buf: [64]u8 = undefined;
        var rhs_buf: [64]u8 = undefined;
        const lhs_str = try std.fmt.bufPrint(&lhs_buf, "len={}", .{lhs_output.len});
        const rhs_str = try std.fmt.bufPrint(&rhs_buf, "len={}", .{rhs_output.len});
        return try ShadowMismatch.create(.per_call, 0, .output, lhs_str, rhs_str, allocator);
    }
    
    if (!std.mem.eql(u8, lhs_output, rhs_output)) {
        // Find first differing byte for detailed reporting
        for (lhs_output, rhs_output, 0..) |l, r, i| {
            if (l != r) {
                var lhs_buf: [128]u8 = undefined;
                var rhs_buf: [128]u8 = undefined;
                const lhs_str = try std.fmt.bufPrint(&lhs_buf, "diff@{}: 0x{x:0>2}", .{i, l});
                const rhs_str = try std.fmt.bufPrint(&rhs_buf, "diff@{}: 0x{x:0>2}", .{i, r});
                var mismatch = try ShadowMismatch.create(.per_call, 0, .output, lhs_str, rhs_str, allocator);
                mismatch.diff_index = i;
                return mismatch;
            }
        }
    }
    
    return null; // No differences found
}

/// Compare execution state after executing a block of instructions
pub fn compare_block(
    main_frame: *const Frame,
    mini_frame: *const Frame,
    block_start_pc: usize,
    block_end_pc: usize,
    config: ShadowConfig,
    allocator: std.mem.Allocator,
) !?ShadowMismatch {
    _ = block_end_pc; // May be used for future enhancements
    
    // Gas comparison
    if (main_frame.gas_remaining != mini_frame.gas_remaining) {
        const main_str = try std.fmt.allocPrint(allocator, "{}", .{main_frame.gas_remaining});
        const mini_str = try std.fmt.allocPrint(allocator, "{}", .{mini_frame.gas_remaining});
        return try ShadowMismatch.create(
            .per_block,
            block_start_pc,
            .gas_left,
            main_str,
            mini_str,
            allocator,
        );
    }
    
    // Stack size comparison
    if (main_frame.stack.size() != mini_frame.stack.size()) {
        const main_str = try std.fmt.allocPrint(allocator, "size={}", .{main_frame.stack.size()});
        const mini_str = try std.fmt.allocPrint(allocator, "size={}", .{mini_frame.stack.size()});
        return try ShadowMismatch.create(
            .per_block,
            block_start_pc,
            .stack,
            main_str,
            mini_str,
            allocator,
        );
    }
    
    // Stack content comparison
    const stack_size = main_frame.stack.size();
    const compare_count = @min(config.stack_compare_limit, stack_size);
    
    var i: usize = 0;
    while (i < compare_count) : (i += 1) {
        const main_val = main_frame.stack.data[stack_size - 1 - i];
        const mini_val = mini_frame.stack.data[stack_size - 1 - i];
        
        if (main_val != mini_val) {
            const main_str = try std.fmt.allocPrint(allocator, "stack[{}]=0x{x}", .{ i, main_val });
            const mini_str = try std.fmt.allocPrint(allocator, "stack[{}]=0x{x}", .{ i, mini_val });
            var mismatch = try ShadowMismatch.create(
                .per_block,
                block_start_pc,
                .stack,
                main_str,
                mini_str,
                allocator,
            );
            mismatch.diff_index = i;
            return mismatch;
        }
    }
    
    // Memory size comparison (if configured)
    if (config.compare_memory) {
        if (main_frame.memory.size() != mini_frame.memory.size()) {
            const main_str = try std.fmt.allocPrint(allocator, "size={}", .{main_frame.memory.size()});
            const mini_str = try std.fmt.allocPrint(allocator, "size={}", .{mini_frame.memory.size()});
            return try ShadowMismatch.create(
                .per_block,
                block_start_pc,
                .memory,
                main_str,
                mini_str,
                allocator,
            );
        }
        
        // Memory content comparison (first N bytes if configured)
        if (config.compare_memory_content) {
            const mem_size = @min(config.max_memory_compare, main_frame.memory.size());
            const main_mem = main_frame.memory.get_slice(0, mem_size) catch &.{};
            const mini_mem = mini_frame.memory.get_slice(0, mem_size) catch &.{};
            
            for (main_mem, mini_mem, 0..) |main_byte, mini_byte, offset| {
                if (main_byte != mini_byte) {
                    const main_str = try std.fmt.allocPrint(allocator, "mem[{}]=0x{x:0>2}", .{ offset, main_byte });
                    const mini_str = try std.fmt.allocPrint(allocator, "mem[{}]=0x{x:0>2}", .{ offset, mini_byte });
                    return try ShadowMismatch.create(
                        .per_block,
                        block_start_pc,
                        .memory,
                        main_str,
                        mini_str,
                        allocator,
                    );
                }
            }
        }
    }
    
    return null; // No mismatch
}

// Tests
test "ShadowMismatch create and cleanup" {
    const allocator = std.testing.allocator;
    
    var mismatch = try ShadowMismatch.create(.per_call, 0, .success, "true", "false", allocator);
    defer mismatch.deinit(allocator);
    
    try std.testing.expectEqual(MismatchContext.per_call, mismatch.context);
    try std.testing.expectEqual(MismatchField.success, mismatch.field);
    try std.testing.expectEqualStrings("true", mismatch.lhs_summary);
    try std.testing.expectEqualStrings("false", mismatch.rhs_summary);
}

test "compare_call_results success mismatch" {
    const allocator = std.testing.allocator;
    
    const lhs = CallResult{ .success = true, .gas_left = 1000, .output = null };
    const rhs = CallResult{ .success = false, .gas_left = 1000, .output = null };
    
    if (try compare_call_results(lhs, rhs, allocator)) |m| {
        var mismatch = m;
        defer mismatch.deinit(allocator);
        try std.testing.expectEqual(MismatchField.success, mismatch.field);
        try std.testing.expectEqualStrings("true", mismatch.lhs_summary);
        try std.testing.expectEqualStrings("false", mismatch.rhs_summary);
    } else {
        try std.testing.expect(false); // Should have found mismatch
    }
}

test "compare_call_results gas mismatch" {
    const allocator = std.testing.allocator;
    
    const lhs = CallResult{ .success = true, .gas_left = 1000, .output = null };
    const rhs = CallResult{ .success = true, .gas_left = 500, .output = null };
    
    if (try compare_call_results(lhs, rhs, allocator)) |m| {
        var mismatch = m;
        defer mismatch.deinit(allocator);
        try std.testing.expectEqual(MismatchField.gas_left, mismatch.field);
        try std.testing.expectEqualStrings("1000", mismatch.lhs_summary);
        try std.testing.expectEqualStrings("500", mismatch.rhs_summary);
    } else {
        try std.testing.expect(false); // Should have found mismatch
    }
}

test "compare_call_results output length mismatch" {
    const allocator = std.testing.allocator;
    
    const lhs_output = [_]u8{0x01, 0x02};
    const rhs_output = [_]u8{0x01};
    
    const lhs = CallResult{ .success = true, .gas_left = 1000, .output = &lhs_output };
    const rhs = CallResult{ .success = true, .gas_left = 1000, .output = &rhs_output };
    
    if (try compare_call_results(lhs, rhs, allocator)) |m| {
        var mismatch = m;
        defer mismatch.deinit(allocator);
        try std.testing.expectEqual(MismatchField.output, mismatch.field);
        try std.testing.expectEqualStrings("len=2", mismatch.lhs_summary);
        try std.testing.expectEqualStrings("len=1", mismatch.rhs_summary);
    } else {
        try std.testing.expect(false); // Should have found mismatch
    }
}

test "compare_call_results output content mismatch" {
    const allocator = std.testing.allocator;
    
    const lhs_output = [_]u8{0x01, 0x02};
    const rhs_output = [_]u8{0x01, 0x03};
    
    const lhs = CallResult{ .success = true, .gas_left = 1000, .output = &lhs_output };
    const rhs = CallResult{ .success = true, .gas_left = 1000, .output = &rhs_output };
    
    if (try compare_call_results(lhs, rhs, allocator)) |m| {
        var mismatch = m;
        defer mismatch.deinit(allocator);
        try std.testing.expectEqual(MismatchField.output, mismatch.field);
        try std.testing.expectEqual(@as(usize, 1), mismatch.diff_index.?);
        try std.testing.expect(std.mem.indexOf(u8, mismatch.lhs_summary, "0x02") != null);
        try std.testing.expect(std.mem.indexOf(u8, mismatch.rhs_summary, "0x03") != null);
    } else {
        try std.testing.expect(false); // Should have found mismatch
    }
}

test "compare_call_results no mismatch" {
    const allocator = std.testing.allocator;
    
    const output = [_]u8{0x01, 0x02};
    const lhs = CallResult{ .success = true, .gas_left = 1000, .output = &output };
    const rhs = CallResult{ .success = true, .gas_left = 1000, .output = &output };
    
    const result = try compare_call_results(lhs, rhs, allocator);
    try std.testing.expect(result == null); // Should be no mismatch
}