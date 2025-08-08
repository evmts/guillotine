const std = @import("std");
const StaticBitSet = std.bit_set.StaticBitSet;
const DynamicBitSet = std.DynamicBitSet;
const Instruction = @import("instruction.zig").Instruction;
const BlockInfo = @import("instruction.zig").BlockInfo;
const JumpType = @import("instruction.zig").JumpType;
const JumpTarget = @import("instruction.zig").JumpTarget;
const DynamicGas = @import("instruction.zig").DynamicGas;
const DynamicGasFunc = @import("instruction.zig").DynamicGasFunc;
const Opcode = @import("opcodes/opcode.zig");
const jump_table_module = @import("jump_table/jump_table.zig");
const DefaultJumpTable = jump_table_module.DefaultJumpTable;
const ExecutionError = @import("execution/execution_error.zig");
const execution = @import("execution/package.zig");
const Frame = @import("frame.zig").Frame;
const Log = @import("log.zig");
const stack_height_changes = @import("opcodes/stack_height_changes.zig");
const dynamic_gas = @import("gas/dynamic_gas.zig");

/// Optimized code analysis for EVM bytecode execution.
/// Contains only the essential data needed during execution.
/// Generic over config parameter to support different EVM limits and configuration.
pub fn CodeAnalysis(comptime config: anytype) type {
    return struct {
        const Self = @This();

        /// Heap-allocated instruction stream for execution.
        /// Must be freed by caller using deinit().
        instructions: []Instruction,

        /// Heap-allocated bitmap marking all valid JUMPDEST positions in the bytecode.
        /// Required for JUMP/JUMPI validation during execution.
        jumpdest_bitmap: DynamicBitSet,

        /// Allocator used for the instruction array (needed for cleanup)
        allocator: std.mem.Allocator,

        /// Handler for opcodes that should never be executed directly.
        /// Used for JUMP, JUMPI, and PUSH opcodes that are handled inline by the interpreter.
        /// This function should never be called - if it is, there's a bug in the analysis or interpreter.
        pub fn UnreachableHandler(comptime cfg: anytype, frame: *anyopaque) ExecutionError.Error!void {
            _ = cfg;
            _ = frame;
            Log.err("UnreachableHandler called - this indicates a bug where an opcode marked for inline handling was executed through the jump table", .{});
            unreachable;
        }

        /// Handler for BEGINBLOCK instructions that validates an entire basic block upfront.
        /// This performs gas and stack validation for all instructions in the block in one operation,
        /// eliminating the need for per-instruction validation during execution.
        /// 
        /// The block information (gas cost, stack requirements) is stored in the instruction's arg.block_info.
        /// This handler must be called before executing any instructions in the basic block.
        pub fn BeginBlockHandler(comptime cfg: anytype, frame: *anyopaque) ExecutionError.Error!void {
            _ = cfg;
            const actual_frame = @as(*Frame, @ptrCast(@alignCast(frame)));
            // TODO: BeginBlockHandler needs to be redesigned since Frame doesn't have current_instruction
            // For now, just consume a small amount of gas as a placeholder
            // const current_instruction = @as(*const Instruction, @ptrCast(actual_frame.current_instruction));
            // const block = current_instruction.arg.block_info;
            const placeholder_gas = 1; // Placeholder gas cost
            
            // Single gas check for entire block - eliminates per-opcode gas validation
            if (actual_frame.gas_remaining < placeholder_gas) {
                return ExecutionError.Error.OutOfGas;
            }
            actual_frame.gas_remaining -= placeholder_gas;
            
            // TODO: Stack validation also needs the block info
            // Single stack validation for entire block - eliminates per-opcode stack checks
            // const stack_size = @as(u16, @intCast(actual_frame.stack.len()));
            // if (stack_size < block.stack_req) {
            //     return ExecutionError.Error.StackUnderflow;
            // }
            // if (stack_size + block.stack_max_growth > 1024) {
            //     return ExecutionError.Error.StackOverflow;
            // }
            
            // Log.debug("BeginBlock: gas_cost={}, stack_req={}, stack_max_growth={}, current_stack={}", .{
            //     block.gas_cost, block.stack_req, block.stack_max_growth, stack_size
            // });
            Log.debug("BeginBlock: placeholder implementation consuming {} gas", .{placeholder_gas});
        }

        /// Block analysis structure used during instruction stream generation.
        /// Tracks the accumulated requirements for a basic block during analysis.
        const BlockAnalysis = struct {
            /// Total static gas cost accumulated for all instructions in the block
            gas_cost: u32 = 0,
            /// Stack height requirement relative to block start
            stack_req: i16 = 0,
            /// Maximum stack growth during block execution
            stack_max_growth: i16 = 0,
            /// Current stack change from block start
            stack_change: i16 = 0,
            /// Index of the BEGINBLOCK instruction that starts this block
            begin_block_index: usize,
    
            /// Initialize a new block analysis at the given instruction index
            fn init(begin_index: usize) BlockAnalysis {
                return BlockAnalysis{
                    .begin_block_index = begin_index,
                };
            }
    
            /// Close the current block by producing compressed information about the block
            fn close(self: *const BlockAnalysis) BlockInfo {
                return BlockInfo{
                    .gas_cost = self.gas_cost,
                    .stack_req = @intCast(@max(0, self.stack_req)),
                    .stack_max_growth = @intCast(@max(0, self.stack_max_growth)),
                };
            }
    
            /// Update stack tracking for an operation
            fn updateStackTracking(self: *BlockAnalysis, min_stack: u32, max_stack: u32) void {
                const stack_inputs = @as(i16, @intCast(min_stack));
                const stack_outputs: i16 = if (max_stack > min_stack) 1 else 0;
                
                // Calculate requirement relative to block start
                const current_stack_req = stack_inputs - self.stack_change;
                self.stack_req = @max(self.stack_req, current_stack_req);
                
                // Update stack change
                self.stack_change += stack_outputs - stack_inputs;
                self.stack_max_growth = @max(self.stack_max_growth, self.stack_change);
            }
        };

        /// Main public API: Analyzes bytecode and returns optimized CodeAnalysis with instruction stream.
        /// The caller must call deinit() to free the instruction array.
        /// TODO: Add chain_rules parameter to validate EIP-specific opcodes during analysis:
        /// - EIP-3855 (PUSH0): Reject PUSH0 in pre-Shanghai contracts
        /// - EIP-5656 (MCOPY): Reject MCOPY in pre-Cancun contracts
        /// - EIP-3198 (BASEFEE): Reject BASEFEE in pre-London contracts
        pub fn from_code(allocator: std.mem.Allocator, code: []const u8, jump_table: *const DefaultJumpTable) !Self {
            if (code.len > config.max_contract_size) {
                return error.CodeTooLarge;
            }

            // Create temporary analysis data that will be discarded
            var code_segments = try createCodeBitmap(allocator, code);
            defer code_segments.deinit();
            var jumpdest_bitmap = try DynamicBitSet.initEmpty(allocator, code.len);
            errdefer jumpdest_bitmap.deinit();

            if (code.len == 0) {
                // For empty code, just create empty instruction array
                const empty_instructions = try allocator.alloc(Instruction, 0);
                return Self{
                    .instructions = empty_instructions,
                    .jumpdest_bitmap = jumpdest_bitmap,
                    .allocator = allocator,
                };
            }

            // First pass: identify JUMPDESTs and contract properties
            var i: usize = 0;
            var loop_iterations: u32 = 0;
            while (i < code.len) {
                loop_iterations += 1;
                if (loop_iterations > 1_000_000) {
                    Log.warn("JUMPDEST analysis exceeded iteration limit at offset {}", .{i});
                    return error.AnalysisIterationLimit;
                }
                
                const op = Opcode.from_byte(code[i]);
                
                if (op == .JUMPDEST) {
                    jumpdest_bitmap.set(i);
                }
                
                // Skip data bytes after PUSH opcodes
                if (Opcode.is_push(op)) {
                    const push_bytes = Opcode.get_push_size(op);
                    i += 1 + push_bytes;
                } else {
                    i += 1;
                }
            }

            // Second pass: build instruction stream with basic block structure
            var instructions = std.ArrayList(Instruction).init(allocator);
            defer instructions.deinit();
            
            var pc: usize = 0;
            var instruction_count: usize = 0;
            var block = BlockAnalysis.init(0);
            
            // Pre-allocate with a reasonable estimate
            try instructions.ensureTotalCapacity(code.len);
            
            // Start with a BEGINBLOCK for the entry block
            try instructions.append(Instruction{
                .opcode_fn = BeginBlockHandler,
                .arg = .{ .block_info = block.close() },
            });
            instruction_count += 1;
            
            loop_iterations = 0;
            while (pc < code.len) {
                loop_iterations += 1;
                if (loop_iterations > 1_000_000) {
                    Log.warn("Instruction stream generation exceeded iteration limit at PC {}", .{pc});
                    return error.AnalysisIterationLimit;
                }
                
                const opcode_byte = code[pc];
                const opcode = Opcode.from_byte(opcode_byte);
                
                switch (opcode) {
                    .JUMPDEST => {
                        // Close current block
                        const begin_block_idx = block.begin_block_index;
                        instructions.items[begin_block_idx].arg = .{ .block_info = block.close() };
                        
                        // Start new block
                        try instructions.append(Instruction{
                            .opcode_fn = BeginBlockHandler,
                            .arg = .{ .block_info = undefined }, // Will be filled when block closes
                        });
                        block = BlockAnalysis.init(instruction_count);
                        instruction_count += 1;
                        
                        // Add the JUMPDEST instruction to the new block
                        const operation = jump_table.get_operation(opcode_byte);
                        block.gas_cost += @intCast(operation.constant_gas);
                        block.updateStackTracking(operation.min_stack, operation.max_stack);
                        
                        try instructions.append(Instruction{
                            .opcode_fn = operation.execute,
                            .arg = .none,
                        });
                        instruction_count += 1;
                        pc += 1;
                    },
                    
                    // Terminating instructions - end current block
                    .JUMP, .STOP, .RETURN, .REVERT, .SELFDESTRUCT => {
                        const operation = jump_table.get_operation(opcode_byte);
                        block.gas_cost += @intCast(operation.constant_gas);
                        block.updateStackTracking(operation.min_stack, operation.max_stack);
                        
                        if (opcode == .JUMP) {
                            try instructions.append(Instruction{
                                .opcode_fn = UnreachableHandler, // Handled inline by interpreter
                                .arg = .none, // Will be filled with .jump_target during resolveJumpTargets
                            });
                        } else {
                            try instructions.append(Instruction{
                                .opcode_fn = operation.execute,
                                .arg = .none,
                            });
                        }
                        instruction_count += 1;
                        
                        // Close current block
                        const begin_block_idx = block.begin_block_index;
                        instructions.items[begin_block_idx].arg = .{ .block_info = block.close() };
                        
                        // Start new block for instructions after this (if any)
                        if (pc + 1 < code.len) {
                            try instructions.append(Instruction{
                                .opcode_fn = BeginBlockHandler,
                                .arg = .{ .block_info = undefined }, // Will be filled when block closes
                            });
                            block = BlockAnalysis.init(instruction_count);
                            instruction_count += 1;
                        }
                        pc += 1;
                    },
                    
                    .JUMPI => {
                        const operation = jump_table.get_operation(opcode_byte);
                        block.gas_cost += @intCast(operation.constant_gas);
                        block.updateStackTracking(operation.min_stack, operation.max_stack);
                        
                        try instructions.append(Instruction{
                            .opcode_fn = UnreachableHandler, // Handled inline by interpreter
                            .arg = .none, // Will be filled with .conditional_jump during resolveJumpTargets
                        });
                        instruction_count += 1;
                        
                        // Close current block
                        const begin_block_idx = block.begin_block_index;
                        instructions.items[begin_block_idx].arg = .{ .block_info = block.close() };
                        
                        // Start new block for fall-through path
                        try instructions.append(Instruction{
                            .opcode_fn = BeginBlockHandler,
                            .arg = .{ .block_info = undefined }, // Will be filled when block closes
                        });
                        block = BlockAnalysis.init(instruction_count);
                        instruction_count += 1;
                        pc += 1;
                    },
                    
                    .PUSH1, .PUSH2, .PUSH3, .PUSH4, .PUSH5, .PUSH6, .PUSH7, .PUSH8, .PUSH9, .PUSH10, .PUSH11, .PUSH12, .PUSH13, .PUSH14, .PUSH15, .PUSH16, .PUSH17, .PUSH18, .PUSH19, .PUSH20, .PUSH21, .PUSH22, .PUSH23, .PUSH24, .PUSH25, .PUSH26, .PUSH27, .PUSH28, .PUSH29, .PUSH30, .PUSH31, .PUSH32 => {
                        const push_size = Opcode.get_push_size(opcode);
                        const end = pc + 1 + push_size;
                        
                        if (end > code.len) {
                            // Truncated PUSH at end of code
                            var value: u256 = 0;
                            const bytes_available = code.len - pc - 1;
                            var j: usize = 0;
                            while (j < bytes_available) : (j += 1) {
                                value = (value << 8) | code[pc + 1 + j];
                            }
                            
                            const operation = jump_table.get_operation(opcode_byte);
                            block.gas_cost += @intCast(operation.constant_gas);
                            block.updateStackTracking(operation.min_stack, operation.max_stack);
                            
                            try instructions.append(Instruction{
                                .opcode_fn = UnreachableHandler, // Handled inline by interpreter
                                .arg = .{ .push = value },
                            });
                            instruction_count += 1;
                            pc = code.len; // Move to end
                        } else {
                            // Normal PUSH with all bytes available
                            var value: u256 = 0;
                            var j: usize = 0;
                            while (j < push_size) : (j += 1) {
                                value = (value << 8) | code[pc + 1 + j];
                            }
                            
                            const operation = jump_table.get_operation(opcode_byte);
                            block.gas_cost += @intCast(operation.constant_gas);
                            block.updateStackTracking(operation.min_stack, operation.max_stack);
                            
                            try instructions.append(Instruction{
                                .opcode_fn = UnreachableHandler, // Handled inline by interpreter
                                .arg = .{ .push = value },
                            });
                            instruction_count += 1;
                            pc = end;
                        }
                    },
                    
                    else => {
                        // Regular opcode - add to current block
                        const operation = jump_table.get_operation(opcode_byte);
                        block.gas_cost += @intCast(operation.constant_gas);
                        block.updateStackTracking(operation.min_stack, operation.max_stack);
                        
                        try instructions.append(Instruction{
                            .opcode_fn = operation.execute,
                            .arg = .none,
                        });
                        instruction_count += 1;
                        pc += 1;
                    },
                }
            }
            
            // Close the final block if it hasn't been closed
            if (block.begin_block_index < instructions.items.len) {
                const begin_block_idx = block.begin_block_index;
                instructions.items[begin_block_idx].arg = .{ .block_info = block.close() };
            }
            
            // Resolve jump targets now that we have all instructions
            try resolveJumpTargets(&instructions, code, &jumpdest_bitmap);
            
            return Self{
                .instructions = try instructions.toOwnedSlice(),
                .jumpdest_bitmap = jumpdest_bitmap,
                .allocator = allocator,
            };
        }

        /// Clean up allocated instruction array.
        pub fn deinit(self: *Self) void {
            self.allocator.free(self.instructions);
            self.jumpdest_bitmap.deinit();
        }

        /// Resolve jump targets for JUMP/JUMPI instructions.
        /// This maps bytecode offsets to instruction indices.
        fn resolveJumpTargets(instructions: *std.ArrayList(Instruction), code: []const u8, jumpdest_bitmap: *const DynamicBitSet) !void {
            _ = instructions;
            _ = code;
            _ = jumpdest_bitmap;
            // TODO: Implement jump target resolution
            // This needs to:
            // 1. Build a map from bytecode offset to instruction index
            // 2. For each JUMP/JUMPI instruction, resolve its target
            // 3. Update the instruction's arg field with the target information
        }

        /// Create a bitmap marking code segments (vs data segments).
        /// This identifies which bytes are actual opcodes vs data bytes following PUSH instructions.
        fn createCodeBitmap(allocator: std.mem.Allocator, code: []const u8) !DynamicBitSet {
            var bitmap = try DynamicBitSet.initEmpty(allocator, code.len);
            errdefer bitmap.deinit();
            
            var i: usize = 0;
            var loop_iterations: u32 = 0;
            while (i < code.len) {
                loop_iterations += 1;
                if (loop_iterations > 1_000_000) {
                    Log.warn("Code bitmap generation exceeded iteration limit at offset {}", .{i});
                    return error.AnalysisIterationLimit;
                }
                
                bitmap.set(i); // Mark as code
                const op = Opcode.from_byte(code[i]);
                
                if (Opcode.is_push(op)) {
                    const push_bytes = Opcode.get_push_size(op);
                    i += 1;
                    // Skip data bytes (don't mark them as code)
                    i += push_bytes;
                } else {
                    i += 1;
                }
            }
            
            return bitmap;
        }
    };
}