const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const Frame = @import("../frame.zig").Frame;
const Evm = @import("../evm.zig");
const DebugShadow = @import("shadow.zig");
const execute_mini_block = @import("../evm/execute_mini_block.zig");
const ExecutionError = @import("../execution/execution_error.zig");
const Instruction = @import("../instruction.zig").Instruction;
const CodeAnalysis = @import("../analysis.zig").CodeAnalysis;
const Log = @import("../log.zig");

/// Information about an instruction block for shadow comparison
pub const BlockInfo = struct {
    /// Starting PC of the block
    start_pc: usize,
    /// Ending PC of the block (exclusive)
    end_pc: usize,
    /// Number of instructions in the block
    instruction_count: usize,
};

/// Get block information from the current instruction in the analysis
pub fn get_block_info(
    inst: *const Instruction,
    analysis: *const CodeAnalysis,
) ?BlockInfo {
    // Get the index of the current instruction
    const base: [*]const @TypeOf(inst.*) = analysis.instructions.ptr;
    const current_idx = (@intFromPtr(inst) - @intFromPtr(base)) / @sizeOf(@TypeOf(inst.*));
    
    // Get PC of current instruction
    const start_pc_u16 = analysis.inst_to_pc[current_idx];
    if (start_pc_u16 == std.math.maxInt(u16)) return null;
    const start_pc = @as(usize, start_pc_u16);
    
    // Find the end of the block by looking for the next instruction's PC
    // or a control flow change
    var end_pc = start_pc + 1; // Default to single instruction
    var instruction_count: usize = 1;
    
    // Scan forward to find block boundary
    var idx = current_idx + 1;
    while (idx < analysis.instructions.len) : (idx += 1) {
        const next_pc_u16 = analysis.inst_to_pc[idx];
        if (next_pc_u16 != std.math.maxInt(u16)) {
            end_pc = @as(usize, next_pc_u16);
            break;
        }
        instruction_count += 1;
    }
    
    // If we didn't find another PC, the block extends to the end of code
    if (idx >= analysis.instructions.len) {
        end_pc = analysis.code.len;
    }
    
    return BlockInfo{
        .start_pc = start_pc,
        .end_pc = end_pc,
        .instruction_count = instruction_count,
    };
}

/// Shadow comparison helper for per-block execution
/// This function is called after the main interpreter executes an instruction block
pub inline fn shadow_compare_block(
    self: *Evm,
    frame: *Frame,
    inst: *const Instruction,
    analysis: *const CodeAnalysis,
) void {
    // Only compile this code if shadow comparison is enabled
    if (!comptime (@hasDecl(build_options, "enable_shadow_compare") and
                   build_options.enable_shadow_compare)) return;
    
    // Only run if shadow mode is per_block (used by tracer)
    // Note: per_call mode is handled separately in system.zig
    if (self.shadow_mode != .per_block) return;
    
    // Get block information
    const block_info = get_block_info(inst, analysis) orelse {
        Log.debug("[shadow_compare_block] Could not determine block info", .{});
        return;
    };
    
    Log.debug("[shadow_compare_block] Comparing block from PC {} to {}", .{
        block_info.start_pc,
        block_info.end_pc,
    });
    
    // Create a mini frame for comparison (clones stack and memory)
    var mini_frame = Frame.init(
        frame.gas_remaining,
        frame.is_static,
        frame.depth,
        frame.contract_address,
        frame.caller,
        frame.value,
        frame.analysis,
        frame.host,
        frame.state,
        self.allocator,
    ) catch {
        Log.err("[shadow_compare_block] Failed to create mini frame", .{});
        return;
    };
    defer mini_frame.deinit(self.allocator);
    
    // Copy stack state
    const stack_size = frame.stack.size();
    @memcpy(mini_frame.stack.data[0..stack_size], frame.stack.data[0..stack_size]);
    mini_frame.stack.current = mini_frame.stack.base + stack_size;
    
    // Copy memory state
    if (frame.memory.size() > 0) {
        const mem_size = frame.memory.size();
        const src = frame.memory.get_slice(0, mem_size) catch {
            Log.err("[shadow_compare_block] Failed to get source memory", .{});
            return;
        };
        mini_frame.memory.set_data(0, src) catch {
            Log.err("[shadow_compare_block] Failed to set mini memory", .{});
            return;
        };
    }
    
    // Copy I/O buffers (contract address and caller were set during init)
    mini_frame.input_buffer = frame.input_buffer;
    mini_frame.output_buffer = frame.output_buffer;
    
    // Execute the entire block in mini EVM
    const result = execute_mini_block.execute_mini_block(
        self,
        &mini_frame,
        block_info.start_pc,
        block_info.end_pc,
        analysis.code,
    );
    
    Log.debug("[shadow_compare_block] Block execution result: opcodes_executed={}, error={s}", .{
        result.opcodes_executed,
        if (result.@"error") |e| @errorName(e) else "none",
    });
    
    // Compare states if block executed successfully or with expected termination
    const should_compare = if (result.@"error") |err| 
        err == ExecutionError.Error.STOP or
        err == ExecutionError.Error.RETURN or
        err == ExecutionError.Error.REVERT
    else 
        true; // No error
    
    if (should_compare) {
        
        // Compare execution state
        const mismatch = DebugShadow.compare_block(
            frame,
            &mini_frame,
            block_info.start_pc,
            block_info.end_pc,
            self.shadow_cfg,
            self.allocator,
        ) catch null;
        
        if (mismatch) |m| {
            // Store mismatch
            if (self.last_shadow_mismatch) |old| {
                var mutable = old;
                mutable.deinit(self.allocator);
            }
            self.last_shadow_mismatch = m;
            
            Log.err("[shadow_compare_block] Mismatch in block {}-{}: field={s}, main={s}, mini={s}", .{
                block_info.start_pc,
                block_info.end_pc,
                @tagName(m.field),
                m.lhs_summary,
                m.rhs_summary,
            });
            
            // In debug mode, fail immediately
            if (comptime builtin.mode == .Debug) {
                @panic("Shadow block mismatch detected!");
            }
        } else {
            Log.debug("[shadow_compare_block] Block comparison passed", .{});
        }
    } else if (result.@"error") |err| {
        Log.err("[shadow_compare_block] Mini EVM error in block {}-{}: {s}", .{
            block_info.start_pc,
            block_info.end_pc,
            @errorName(err),
        });
    }
}