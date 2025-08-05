const std = @import("std");
const ExecutionError = @import("../execution/execution_error.zig");
const Contract = @import("../frame/contract.zig");
const RunResult = @import("run_result.zig").RunResult;
const Vm = @import("../evm.zig");

/// Dispatch to the appropriate interpreter based on available optimizations.
///
/// This function checks if block metadata is available and routes to either:
/// - Block-based interpreter (optimized) if block metadata exists
/// - Regular interpreter (fallback) otherwise
///
/// This allows gradual adoption of the optimization while maintaining
/// compatibility with contracts that haven't been analyzed yet.
pub fn interpret(self: *Vm, contract: *Contract, input: []const u8, is_static: bool) ExecutionError.Error!RunResult {
    // Check if we have block analysis with metadata
    if (contract.analysis) |analysis| {
        if (analysis.block_metadata.len > 0 and analysis.pc_to_block.len > 0) {
            // Use optimized block-based interpreter
            return @import("interpret_block.zig").interpret_block(self, contract, input, is_static);
        }
    }
    
    // Fall back to regular interpreter
    return @import("interpret.zig").interpret(self, contract, input, is_static);
}