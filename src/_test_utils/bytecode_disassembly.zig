const std = @import("std");
const Opcode = @import("opcode.zig").Opcode;
const OpcodeSynthetic = @import("opcode_synthetic.zig").OpcodeSynthetic;
const OPCODE_INFO = @import("opcode_data.zig").OPCODE_INFO;
const dispatch_mod = @import("dispatch.zig");
const frame_handlers_mod = @import("frame_handlers.zig");
const bytecodeAnalyze = @import("bytecode_analyze.zig").bytecodeAnalyze;
const BytecodeConfig = @import("bytecode_config.zig").BytecodeConfig;
const Bytecode = @import("bytecode.zig").Bytecode;

/// This module provides structured analysis of bytecode with optimization information.
/// Designed for minimal code addition while maximizing reuse of existing infrastructure.

/// Fusion information for advanced bytecode analysis
const FusionInfo = struct {
    fusion_type: FusionType,
    original_length: u32,
    folded_value: u256 = 0,
    count: u8 = 0,
    
    pub const FusionType = enum {
        constant_fold,
        multi_push,
        multi_pop,
        iszero_jumpi,
        dup2_mstore_push,
    };
};

/// Basic block information
const BasicBlock = struct {
    start: u32,
    end: u32,
    is_reachable: bool = true,
};

/// Main bytecode disassembly API
pub const BytecodeDisassembly = struct {
    /// Analysis instruction representation showing fusion patterns
    pub const AnalysisInstruction = struct {
        /// PC in original bytecode where this starts
        original_pc: u32,
        
        /// The optimized instruction type  
        type: InstructionType,
        
        /// Gas cost after optimization
        gas_cost: u32,
        
        /// Stack effects
        stack_inputs: u8,
        stack_outputs: u8,
        
        /// Original opcodes this represents
        original_opcodes: []const OriginalOpcode,
        
        pub const OriginalOpcode = struct {
            pc: u32,
            opcode: u8,
            name: []const u8,
            push_value: ?u256 = null,
        };
        
        pub const InstructionType = union(enum) {
            // Regular unoptimized opcode
            regular: struct {
                opcode: u8,
                name: []const u8,
            },
            
            // Iterator fusions (9 types from bytecode.zig)
            push_add_fusion: FusionData,
            push_mul_fusion: FusionData,
            push_sub_fusion: FusionData,
            push_div_fusion: FusionData,
            push_and_fusion: FusionData,
            push_or_fusion: FusionData,
            push_xor_fusion: FusionData,
            push_jump_fusion: FusionData,
            push_jumpi_fusion: FusionData,
            
            // Advanced fusions (5 types from bytecode_analyze.zig)
            constant_fold: struct {
                folded_value: u256,
                original_length: u8,
                operation: []const u8,
            },
            multi_push: struct {
                count: u8,
                original_length: u8,
            },
            multi_pop: struct {
                count: u8,
                original_length: u8,
            },
            iszero_jumpi: struct {
                original_length: u8,
            },
            dup2_mstore_push: struct {
                original_length: u8,
            },
            
            // Static jump candidate
            static_jump_candidate: struct {
                target_pc: u32,
            },
        };
        
        const ValueStorage = enum { inline_64bit, pointer_large };
        
        pub const FusionData = struct {
            value: u256,
            value_storage: ValueStorage,
        };
    };

    /// Complete disassembly result
    pub const AnalysisResult = struct {
        instructions: []AnalysisInstruction,
        stats: Stats,
        allocator: std.mem.Allocator,
        
        pub const Stats = struct {
            original_count: usize,
            optimized_count: usize,
            fusion_count: usize,
            inline_value_count: usize,
            pointer_value_count: usize,
            static_jump_candidates: usize,
            gas_saved_estimate: u32,
            compression_ratio: f32,
        };
        
        pub fn deinit(self: *AnalysisResult) void {
            for (self.instructions) |*instr| {
                self.allocator.free(instr.original_opcodes);
            }
            self.allocator.free(self.instructions);
        }
    };

    /// Analyze bytecode with optimization information
    pub fn analyze(
        allocator: std.mem.Allocator,
        bytecode: Bytecode(BytecodeConfig{}),
    ) !AnalysisResult {

        // Handle empty bytecode first
        if (bytecode.runtime_code.len == 0) {
            return AnalysisResult{
                .instructions = &.{},
                .stats = .{
                    .original_count = 0,
                    .optimized_count = 0,
                    .fusion_count = 0,
                    .inline_value_count = 0,
                    .pointer_value_count = 0,
                    .static_jump_candidates = 0,
                    .gas_saved_estimate = 0,
                    .compression_ratio = 1.0,
                },
                .allocator = allocator,
            };
        }


        // Get advanced fusion analysis
        var analysis = try bytecodeAnalyze(
            u32,
            BasicBlock,
            FusionInfo,
            allocator,
            bytecode.runtime_code,
        );
        defer {
            allocator.free(analysis.push_pcs);
            allocator.free(analysis.jumpdests);
            allocator.free(analysis.basic_blocks);
            analysis.jump_fusions.deinit();
            analysis.advanced_fusions.deinit();
        }

        // Build optimized instructions
        var optimized = std.ArrayList(AnalysisInstruction){};
        defer optimized.deinit(allocator);

        var iter = bytecode.createIterator();
        var stats = AnalysisResult.Stats{
            .original_count = 0,
            .optimized_count = 0,
            .fusion_count = 0,
            .inline_value_count = 0,
            .pointer_value_count = 0,
            .static_jump_candidates = 0,
            .gas_saved_estimate = 0,
            .compression_ratio = 1.0,
        };

        // Track processed PCs to avoid double-processing
        var processed_pcs = std.AutoHashMap(u32, void).init(allocator);
        defer processed_pcs.deinit();

        while (iter.next()) |op_data| {
            const current_pc = @as(u32, @intCast(iter.pc));

            // Skip if already processed by advanced fusion
            if (processed_pcs.contains(current_pc)) {
                continue;
            }

            // Check for advanced fusion at this PC
            if (analysis.advanced_fusions.get(current_pc)) |fusion| {
                // Verify fusion doesn't exceed bytecode bounds
                if (current_pc + fusion.original_length > bytecode.runtime_code.len) {
                    std.log.warn("Advanced fusion at pc={} claims length {} but only {} bytes remain", .{
                        current_pc, fusion.original_length, bytecode.runtime_code.len - current_pc
                    });
                    continue;
                }
                const instr = try createAdvancedFusionInstruction(
                    allocator,
                    current_pc,
                    fusion,
                    bytecode.runtime_code,
                );
                try optimized.append(allocator, instr);
                stats.fusion_count += 1;

                // Mark all bytes consumed by this fusion as processed
                var i: u32 = 0;
                while (i < fusion.original_length) : (i += 1) {
                    try processed_pcs.put(current_pc + i, {});
                }
                continue;
            }

            // Map OpcodeData from iterator to AnalysisInstruction
            const instr = switch (op_data) {
                .push_add_fusion => |data| blk: {
                    stats.fusion_count += 1;
                    break :blk try createIteratorFusion(allocator, current_pc, .push_add_fusion, data.value, bytecode.runtime_code);
                },
                .push_mul_fusion => |data| blk: {
                    stats.fusion_count += 1;
                    break :blk try createIteratorFusion(allocator, current_pc, .push_mul_fusion, data.value, bytecode.runtime_code);
                },
                .push_sub_fusion => |data| blk: {
                    stats.fusion_count += 1;
                    break :blk try createIteratorFusion(allocator, current_pc, .push_sub_fusion, data.value, bytecode.runtime_code);
                },
                .push_div_fusion => |data| blk: {
                    stats.fusion_count += 1;
                    break :blk try createIteratorFusion(allocator, current_pc, .push_div_fusion, data.value, bytecode.runtime_code);
                },
                .push_and_fusion => |data| blk: {
                    stats.fusion_count += 1;
                    break :blk try createIteratorFusion(allocator, current_pc, .push_and_fusion, data.value, bytecode.runtime_code);
                },
                .push_or_fusion => |data| blk: {
                    stats.fusion_count += 1;
                    break :blk try createIteratorFusion(allocator, current_pc, .push_or_fusion, data.value, bytecode.runtime_code);
                },
                .push_xor_fusion => |data| blk: {
                    stats.fusion_count += 1;
                    break :blk try createIteratorFusion(allocator, current_pc, .push_xor_fusion, data.value, bytecode.runtime_code);
                },
                .push_jump_fusion => |data| blk: {
                    stats.fusion_count += 1;
                    stats.static_jump_candidates += 1;
                    break :blk try createIteratorFusion(allocator, current_pc, .push_jump_fusion, data.value, bytecode.runtime_code);
                },
                .push_jumpi_fusion => |data| blk: {
                    stats.fusion_count += 1;
                    break :blk try createIteratorFusion(allocator, current_pc, .push_jumpi_fusion, data.value, bytecode.runtime_code);
                },
                
                .push => |data| blk: {
                    // Regular PUSH instruction
                    if (isStaticJumpCandidate(current_pc, data.value, bytecode.runtime_code)) {
                        stats.static_jump_candidates += 1;
                        break :blk try createStaticJumpCandidate(allocator, current_pc, data.value, data.size, bytecode.runtime_code);
                    }
                    break :blk try createPushInstruction(allocator, current_pc, data.value, data.size, bytecode.runtime_code);
                },
                
                .regular => |data| try createRegularInstruction(allocator, current_pc, data.opcode, bytecode.runtime_code),
                .jumpdest => |data| blk: {
                    _ = data; // jumpdest has gas_cost field we don't need
                    break :blk try createJumpdestInstruction(allocator, current_pc, bytecode.runtime_code);
                },
                .stop => try createStopInstruction(allocator, current_pc),
                .invalid => try createInvalidInstruction(allocator, current_pc),
            };

            try optimized.append(allocator, instr);
        }

        // Calculate statistics
        const instructions = try optimized.toOwnedSlice(allocator);
        stats.optimized_count = instructions.len;

        // Count original instructions and calculate gas savings
        for (instructions) |instr| {
            stats.original_count += instr.original_opcodes.len;

            // Calculate value storage stats
            switch (instr.type) {
                .push_add_fusion, .push_mul_fusion, .push_sub_fusion, .push_div_fusion,
                .push_and_fusion, .push_or_fusion, .push_xor_fusion, 
                .push_jump_fusion, .push_jumpi_fusion => |fusion| {
                    if (fusion.value_storage == .inline_64bit) {
                        stats.inline_value_count += 1;
                    } else {
                        stats.pointer_value_count += 1;
                    }
                },
                else => {},
            }
        }

        // Calculate gas savings and compression ratio
        stats.gas_saved_estimate = calculateGasSavings(instructions);
        if (stats.original_count > 0) {
            stats.compression_ratio = @as(f32, @floatFromInt(stats.optimized_count)) / 
                                     @as(f32, @floatFromInt(stats.original_count));
        }

        return AnalysisResult{
            .instructions = instructions,
            .stats = stats,
            .allocator = allocator,
        };
    }
};

// Helper functions for optimized analysis

fn isStaticJumpCandidate(pc: u32, value: u256, bytecode: []const u8) bool {
    const next_pc = pc + 1 + calculateMinimalPushSize(value);
    if (next_pc >= bytecode.len) return false;
    const next_op = bytecode[next_pc];
    return next_op == @intFromEnum(Opcode.JUMP) or next_op == @intFromEnum(Opcode.JUMPI);
}

fn createRegularInstruction(allocator: std.mem.Allocator, pc: u32, opcode: u8, bytecode: []const u8) !BytecodeDisassembly.AnalysisInstruction {
    _ = bytecode;
    const info = OPCODE_INFO[opcode];
    const opcode_enum = std.meta.intToEnum(Opcode, opcode) catch Opcode.INVALID;
    
    var original = try allocator.alloc(BytecodeDisassembly.AnalysisInstruction.OriginalOpcode, 1);
    original[0] = .{
        .pc = pc,
        .opcode = opcode,
        .name = @tagName(opcode_enum),
        .push_value = null,
    };
    
    return BytecodeDisassembly.AnalysisInstruction{
        .original_pc = pc,
        .type = .{ .regular = .{ .opcode = opcode, .name = @tagName(opcode_enum) } },
        .gas_cost = info.gas_cost,
        .stack_inputs = info.stack_inputs,
        .stack_outputs = info.stack_outputs,
        .original_opcodes = original,
    };
}

fn createPushInstruction(allocator: std.mem.Allocator, pc: u32, value: u256, size: u8, bytecode: []const u8) !BytecodeDisassembly.AnalysisInstruction {
    _ = bytecode;
    const opcode = 0x60 + size - 1; // PUSH1 = 0x60, PUSH2 = 0x61, etc.
    const info = OPCODE_INFO[opcode];
    
    var original = try allocator.alloc(BytecodeDisassembly.AnalysisInstruction.OriginalOpcode, 1);
    const name = try std.fmt.allocPrint(allocator, "PUSH{}", .{size});
    defer allocator.free(name);
    
    original[0] = .{
        .pc = pc,
        .opcode = opcode,
        .name = try allocator.dupe(u8, name),
        .push_value = value,
    };
    
    return BytecodeDisassembly.AnalysisInstruction{
        .original_pc = pc,
        .type = .{ .regular = .{ .opcode = opcode, .name = original[0].name } },
        .gas_cost = info.gas_cost,
        .stack_inputs = 0,
        .stack_outputs = 1,
        .original_opcodes = original,
    };
}

fn createJumpdestInstruction(allocator: std.mem.Allocator, pc: u32, bytecode: []const u8) !BytecodeDisassembly.AnalysisInstruction {
    _ = bytecode;
    var original = try allocator.alloc(BytecodeDisassembly.AnalysisInstruction.OriginalOpcode, 1);
    original[0] = .{ .pc = pc, .opcode = 0x5B, .name = "JUMPDEST", .push_value = null };
    return BytecodeDisassembly.AnalysisInstruction{
        .original_pc = pc,
        .type = .{ .regular = .{ .opcode = 0x5B, .name = "JUMPDEST" } },
        .gas_cost = 1,
        .stack_inputs = 0,
        .stack_outputs = 0,
        .original_opcodes = original,
    };
}

fn createStopInstruction(allocator: std.mem.Allocator, pc: u32) !BytecodeDisassembly.AnalysisInstruction {
    var original = try allocator.alloc(BytecodeDisassembly.AnalysisInstruction.OriginalOpcode, 1);
    original[0] = .{ .pc = pc, .opcode = 0x00, .name = "STOP", .push_value = null };
    return BytecodeDisassembly.AnalysisInstruction{
        .original_pc = pc,
        .type = .{ .regular = .{ .opcode = 0x00, .name = "STOP" } },
        .gas_cost = 0,
        .stack_inputs = 0,
        .stack_outputs = 0,
        .original_opcodes = original,
    };
}

fn createInvalidInstruction(allocator: std.mem.Allocator, pc: u32) !BytecodeDisassembly.AnalysisInstruction {
    var original = try allocator.alloc(BytecodeDisassembly.AnalysisInstruction.OriginalOpcode, 1);
    original[0] = .{ .pc = pc, .opcode = 0xFE, .name = "INVALID", .push_value = null };
    return BytecodeDisassembly.AnalysisInstruction{
        .original_pc = pc,
        .type = .{ .regular = .{ .opcode = 0xFE, .name = "INVALID" } },
        .gas_cost = 0,
        .stack_inputs = 0,
        .stack_outputs = 0,
        .original_opcodes = original,
    };
}

fn createStaticJumpCandidate(allocator: std.mem.Allocator, pc: u32, value: u256, size: u8, bytecode: []const u8) !BytecodeDisassembly.AnalysisInstruction {
    const push_instr = try createPushInstruction(allocator, pc, value, size, bytecode);
    // Change type to indicate static jump candidate
    var result = push_instr;
    result.type = .{ .static_jump_candidate = .{ .target_pc = @intCast(value) } };
    return result;
}

fn createIteratorFusion(
    allocator: std.mem.Allocator,
    pc: u32,
    fusion_type: std.meta.Tag(BytecodeDisassembly.AnalysisInstruction.InstructionType),
    value: u256,
    bytecode: []const u8,
) !BytecodeDisassembly.AnalysisInstruction {
    const push_size = calculateMinimalPushSize(value);
    const total_length = 1 + push_size + 1; // PUSH + data + operation
    
    // Extract original opcodes
    const original_opcodes = try extractOriginalOpcodes(allocator, pc, total_length, bytecode);
    
    // Determine value storage  
    const value_storage: BytecodeDisassembly.AnalysisInstruction.ValueStorage = if (value <= std.math.maxInt(u64))
        .inline_64bit
    else
        .pointer_large;
    
    // Calculate gas cost (fusion typically saves gas)
    const original_gas = calculateOriginalGas(original_opcodes);
    const optimized_gas = if (original_gas > 2) original_gas - 2 else 0; // Typical fusion saves ~2 gas
    
    // Build the instruction based on type
    const instr_type = switch (fusion_type) {
        .push_add_fusion => BytecodeDisassembly.AnalysisInstruction.InstructionType{ 
            .push_add_fusion = .{ .value = value, .value_storage = value_storage }
        },
        .push_mul_fusion => BytecodeDisassembly.AnalysisInstruction.InstructionType{
            .push_mul_fusion = .{ .value = value, .value_storage = value_storage }
        },
        .push_sub_fusion => BytecodeDisassembly.AnalysisInstruction.InstructionType{
            .push_sub_fusion = .{ .value = value, .value_storage = value_storage }
        },
        .push_div_fusion => BytecodeDisassembly.AnalysisInstruction.InstructionType{
            .push_div_fusion = .{ .value = value, .value_storage = value_storage }
        },
        .push_and_fusion => BytecodeDisassembly.AnalysisInstruction.InstructionType{
            .push_and_fusion = .{ .value = value, .value_storage = value_storage }
        },
        .push_or_fusion => BytecodeDisassembly.AnalysisInstruction.InstructionType{
            .push_or_fusion = .{ .value = value, .value_storage = value_storage }
        },
        .push_xor_fusion => BytecodeDisassembly.AnalysisInstruction.InstructionType{
            .push_xor_fusion = .{ .value = value, .value_storage = value_storage }
        },
        .push_jump_fusion => BytecodeDisassembly.AnalysisInstruction.InstructionType{
            .push_jump_fusion = .{ .value = value, .value_storage = value_storage }
        },
        .push_jumpi_fusion => BytecodeDisassembly.AnalysisInstruction.InstructionType{
            .push_jumpi_fusion = .{ .value = value, .value_storage = value_storage }
        },
        else => unreachable,
    };
    
    return BytecodeDisassembly.AnalysisInstruction{
        .original_pc = pc,
        .type = instr_type,
        .gas_cost = optimized_gas,
        .stack_inputs = 0,
        .stack_outputs = 1,
        .original_opcodes = original_opcodes,
    };
}

fn createAdvancedFusionInstruction(
    allocator: std.mem.Allocator,
    pc: u32,
    fusion: FusionInfo,
    bytecode: []const u8,
) !BytecodeDisassembly.AnalysisInstruction {
    const original_opcodes = try extractOriginalOpcodes(
        allocator,
        pc,
        fusion.original_length,
        bytecode,
    );
    
    const instr_type = switch (fusion.fusion_type) {
        .constant_fold => BytecodeDisassembly.AnalysisInstruction.InstructionType{
            .constant_fold = .{
                .folded_value = fusion.folded_value,
                .original_length = @intCast(fusion.original_length),
                .operation = "CONST_FOLD",
            },
        },
        .multi_push => BytecodeDisassembly.AnalysisInstruction.InstructionType{
            .multi_push = .{
                .count = fusion.count,
                .original_length = @intCast(fusion.original_length),
            },
        },
        .multi_pop => BytecodeDisassembly.AnalysisInstruction.InstructionType{
            .multi_pop = .{
                .count = fusion.count,
                .original_length = @intCast(fusion.original_length),
            },
        },
        .iszero_jumpi => BytecodeDisassembly.AnalysisInstruction.InstructionType{
            .iszero_jumpi = .{
                .original_length = @intCast(fusion.original_length),
            },
        },
        .dup2_mstore_push => BytecodeDisassembly.AnalysisInstruction.InstructionType{
            .dup2_mstore_push = .{
                .original_length = @intCast(fusion.original_length),
            },
        },
    };
    
    const gas_cost = calculateOptimizedGasForFusion(fusion, original_opcodes);
    
    return BytecodeDisassembly.AnalysisInstruction{
        .original_pc = pc,
        .type = instr_type,
        .gas_cost = gas_cost,
        .stack_inputs = calculateStackInputs(fusion),
        .stack_outputs = calculateStackOutputs(fusion),
        .original_opcodes = original_opcodes,
    };
}

fn calculateMinimalPushSize(value: u256) u8 {
    if (value == 0) return 1;
    
    var bytes_needed: u8 = 0;
    var temp = value;
    while (temp > 0) : (temp >>= 8) {
        bytes_needed += 1;
    }
    
    return bytes_needed;
}

fn extractOriginalOpcodes(
    allocator: std.mem.Allocator,
    start_pc: u32,
    length: u32,
    bytecode: []const u8,
) ![]BytecodeDisassembly.AnalysisInstruction.OriginalOpcode {
    var opcodes = std.ArrayList(BytecodeDisassembly.AnalysisInstruction.OriginalOpcode){};
    defer opcodes.deinit(allocator);
    
    var pc = start_pc;
    const end_pc = start_pc + length;
    
    while (pc < end_pc and pc < bytecode.len) {
        const opcode = bytecode[pc];
        const opcode_enum = std.meta.intToEnum(Opcode, opcode) catch {
            try opcodes.append(allocator, .{
                .pc = pc,
                .opcode = opcode,
                .name = "INVALID",
                .push_value = null,
            });
            pc += 1;
            continue;
        };
        
        if (opcode >= @intFromEnum(Opcode.PUSH1) and opcode <= @intFromEnum(Opcode.PUSH32)) { // PUSH1-PUSH32
            const push_size = opcode - 0x5F;
            var value: u256 = 0;
            
            for (1..push_size + 1) |i| {
                if (pc + i < bytecode.len) {
                    value = (value << 8) | bytecode[pc + i];
                }
            }
            
            try opcodes.append(allocator, .{
                .pc = pc,
                .opcode = opcode,
                .name = @tagName(opcode_enum),
                .push_value = value,
            });
            
            pc += 1 + push_size;
        } else {
            try opcodes.append(allocator, .{
                .pc = pc,
                .opcode = opcode,
                .name = @tagName(opcode_enum),
                .push_value = null,
            });
            pc += 1;
        }
    }
    
    return try opcodes.toOwnedSlice(allocator);
}

fn calculateOriginalGas(opcodes: []const BytecodeDisassembly.AnalysisInstruction.OriginalOpcode) u32 {
    var total: u32 = 0;
    for (opcodes) |op| {
        const info = OPCODE_INFO[op.opcode];
        total += info.gas_cost;
    }
    return total;
}

fn calculateOptimizedGasForFusion(fusion: FusionInfo, original_opcodes: []const BytecodeDisassembly.AnalysisInstruction.OriginalOpcode) u32 {
    const original_gas = calculateOriginalGas(original_opcodes);
    return switch (fusion.fusion_type) {
        .constant_fold => OPCODE_INFO[@intFromEnum(Opcode.PUSH1)].gas_cost, // Just the cost of pushing the result
        .multi_push => if (fusion.count > 1) original_gas - @as(u32, fusion.count - 1) else original_gas,
        .multi_pop => if (fusion.count > 1) original_gas - @as(u32, fusion.count - 1) else original_gas,
        .iszero_jumpi => if (original_gas > 1) original_gas - 1 else 0,
        .dup2_mstore_push => if (original_gas > 2) original_gas - 2 else 0,
    };
}

fn calculateGasSavings(instructions: []const BytecodeDisassembly.AnalysisInstruction) u32 {
    var saved: u32 = 0;
    for (instructions) |instr| {
        switch (instr.type) {
            .push_add_fusion, .push_mul_fusion, .push_sub_fusion, .push_div_fusion,
            .push_and_fusion, .push_or_fusion, .push_xor_fusion => saved += 2,
            .push_jump_fusion, .push_jumpi_fusion => saved += 1,
            .constant_fold => |fold| saved += @as(u32, fold.original_length) * 3 - 3,
            .multi_push => |multi| saved += multi.count - 1,
            .multi_pop => |multi| saved += multi.count - 1,
            .iszero_jumpi, .dup2_mstore_push => saved += 2,
            else => {},
        }
    }
    return saved;
}

fn calculateStackInputs(fusion: FusionInfo) u8 {
    return switch (fusion.fusion_type) {
        .constant_fold => 0,
        .multi_push => 0,
        .multi_pop => fusion.count,
        .iszero_jumpi => 1,
        .dup2_mstore_push => 2,
    };
}

fn calculateStackOutputs(fusion: FusionInfo) u8 {
    return switch (fusion.fusion_type) {
        .constant_fold => 1,
        .multi_push => fusion.count,
        .multi_pop => 0,
        .iszero_jumpi => 0,
        .dup2_mstore_push => 0,
    };
}

const testing = std.testing;

test "optimized analysis - empty bytecode" {
    const allocator = testing.allocator;

    const BytecodeType = @import("bytecode.zig").Bytecode(@import("bytecode_config.zig").BytecodeConfig{});
    const bytecode = BytecodeType.init(allocator, &.{}) catch |e| {
        std.debug.panic("Failed to create bytecode: {}", .{e});
    };
    defer bytecode.deinit();

    var result = try BytecodeDisassembly.analyze(allocator, bytecode);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 0), result.instructions.len);
    try testing.expectEqual(@as(usize, 0), result.stats.original_count);
    try testing.expectEqual(@as(usize, 0), result.stats.optimized_count);
    try testing.expectEqual(@as(usize, 0), result.stats.fusion_count);
    try testing.expectEqual(@as(f32, 1.0), result.stats.compression_ratio);
}

test "optimized analysis - single regular instruction ADD" {
    const allocator = testing.allocator;

    const code = [_]u8{@intFromEnum(Opcode.ADD)};

    const BytecodeType = @import("bytecode.zig").Bytecode(@import("bytecode_config.zig").BytecodeConfig{});
    const bytecode = BytecodeType.init(allocator, &code) catch |e| {
        std.debug.panic("Failed to create bytecode: {}", .{e});
    };
    defer bytecode.deinit();

    var result = try BytecodeDisassembly.analyze(allocator, bytecode);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 1), result.instructions.len);
    try testing.expectEqual(@as(u32, 0), result.instructions[0].original_pc);
    try testing.expectEqual(@as(u32, 3), result.instructions[0].gas_cost); // ADD costs 3 gas
    try testing.expectEqual(@as(u8, 2), result.instructions[0].stack_inputs);
    try testing.expectEqual(@as(u8, 1), result.instructions[0].stack_outputs);
    
    // Check it's a regular instruction
    try testing.expect(result.instructions[0].type == .regular);
    try testing.expectEqual(@as(u8, @intFromEnum(Opcode.ADD)), result.instructions[0].type.regular.opcode);
    try testing.expectEqualStrings("ADD", result.instructions[0].type.regular.name);
    
    // Stats
    try testing.expectEqual(@as(usize, 1), result.stats.original_count);
    try testing.expectEqual(@as(usize, 1), result.stats.optimized_count);
    try testing.expectEqual(@as(usize, 0), result.stats.fusion_count);
}

test "optimized analysis - PUSH1 with inline storage" {
    const allocator = testing.allocator;

    const code = [_]u8{ @intFromEnum(Opcode.PUSH1), 0x42 };

    const BytecodeType = @import("bytecode.zig").Bytecode(@import("bytecode_config.zig").BytecodeConfig{});
    const bytecode = BytecodeType.init(allocator, &code) catch |e| {
        std.debug.panic("Failed to create bytecode: {}", .{e});
    };
    defer bytecode.deinit();

    var result = try BytecodeDisassembly.analyze(allocator, bytecode);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 1), result.instructions.len);
    try testing.expectEqual(@as(u32, 0), result.instructions[0].original_pc);
    
    // Check original opcodes
    try testing.expectEqual(@as(usize, 1), result.instructions[0].original_opcodes.len);
    try testing.expectEqual(@as(u32, 0), result.instructions[0].original_opcodes[0].pc);
    try testing.expectEqual(@as(u8, @intFromEnum(Opcode.PUSH1)), result.instructions[0].original_opcodes[0].opcode);
    try testing.expectEqual(@as(?u256, 0x42), result.instructions[0].original_opcodes[0].push_value);
}

test "optimized analysis - PUSH32 with pointer storage" {
    const allocator = testing.allocator;

    const code = [_]u8{@intFromEnum(Opcode.PUSH32)} ++ [_]u8{0xFF} ** 32;

    const BytecodeType = @import("bytecode.zig").Bytecode(@import("bytecode_config.zig").BytecodeConfig{});
    const bytecode = BytecodeType.init(allocator, &code) catch |e| {
        std.debug.panic("Failed to create bytecode: {}", .{e});
    };
    defer bytecode.deinit();

    var result = try BytecodeDisassembly.analyze(allocator, bytecode);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 1), result.instructions.len);
    try testing.expectEqual(@as(u32, 0), result.instructions[0].original_pc);
    
    // Check original opcodes have max u256 value
    const expected_value = std.math.maxInt(u256);
    try testing.expectEqual(@as(?u256, expected_value), result.instructions[0].original_opcodes[0].push_value);
}

test "optimized analysis - PUSH+ADD fusion" {
    const allocator = testing.allocator;

    const code = [_]u8{
        @intFromEnum(Opcode.PUSH1), 0x10,
        @intFromEnum(Opcode.ADD),
    };

    const BytecodeType = @import("bytecode.zig").Bytecode(@import("bytecode_config.zig").BytecodeConfig{});
    const bytecode = BytecodeType.init(allocator, &code) catch |e| {
        std.debug.panic("Failed to create bytecode: {}", .{e});
    };
    defer bytecode.deinit();

    var result = try BytecodeDisassembly.analyze(allocator, bytecode);
    defer result.deinit();

    // Should detect push_add_fusion
    try testing.expectEqual(@as(usize, 1), result.instructions.len);
    try testing.expect(result.instructions[0].type == .push_add_fusion);
    try testing.expectEqual(@as(u256, 0x10), result.instructions[0].type.push_add_fusion.value);
    try testing.expect(result.instructions[0].type.push_add_fusion.value_storage == .inline_64bit);
    
    // Stats should show fusion
    try testing.expectEqual(@as(usize, 1), result.stats.fusion_count);
    try testing.expectEqual(@as(usize, 1), result.stats.inline_value_count);
    try testing.expect(result.stats.gas_saved_estimate > 0);
}

test "optimized analysis - PUSH+MUL fusion" {
    const allocator = testing.allocator;

    const code = [_]u8{
        @intFromEnum(Opcode.PUSH2), 0x01, 0x00,
        @intFromEnum(Opcode.MUL),
    };

    const BytecodeType = @import("bytecode.zig").Bytecode(@import("bytecode_config.zig").BytecodeConfig{});
    const bytecode = BytecodeType.init(allocator, &code) catch |e| {
        std.debug.panic("Failed to create bytecode: {}", .{e});
    };
    defer bytecode.deinit();

    var result = try BytecodeDisassembly.analyze(allocator, bytecode);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 1), result.instructions.len);
    try testing.expect(result.instructions[0].type == .push_mul_fusion);
    try testing.expectEqual(@as(u256, 0x100), result.instructions[0].type.push_mul_fusion.value);
}

test "optimized analysis - PUSH+SUB fusion" {
    const allocator = testing.allocator;

    const code = [_]u8{
        @intFromEnum(Opcode.PUSH1), 0x05,
        @intFromEnum(Opcode.SUB),
    };

    const BytecodeType = @import("bytecode.zig").Bytecode(@import("bytecode_config.zig").BytecodeConfig{});
    const bytecode = BytecodeType.init(allocator, &code) catch |e| {
        std.debug.panic("Failed to create bytecode: {}", .{e});
    };
    defer bytecode.deinit();

    var result = try BytecodeDisassembly.analyze(allocator, bytecode);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 1), result.instructions.len);
    try testing.expect(result.instructions[0].type == .push_sub_fusion);
}

test "optimized analysis - PUSH+DIV fusion" {
    const allocator = testing.allocator;

    const code = [_]u8{
        @intFromEnum(Opcode.PUSH1), 0x02,
        @intFromEnum(Opcode.DIV),
    };

    const BytecodeType = @import("bytecode.zig").Bytecode(@import("bytecode_config.zig").BytecodeConfig{});
    const bytecode = BytecodeType.init(allocator, &code) catch |e| {
        std.debug.panic("Failed to create bytecode: {}", .{e});
    };
    defer bytecode.deinit();

    var result = try BytecodeDisassembly.analyze(allocator, bytecode);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 1), result.instructions.len);
    try testing.expect(result.instructions[0].type == .push_div_fusion);
}

test "optimized analysis - PUSH+AND fusion" {
    const allocator = testing.allocator;

    const code = [_]u8{
        @intFromEnum(Opcode.PUSH1), 0xFF,
        @intFromEnum(Opcode.AND),
    };

    const BytecodeType = @import("bytecode.zig").Bytecode(@import("bytecode_config.zig").BytecodeConfig{});
    const bytecode = BytecodeType.init(allocator, &code) catch |e| {
        std.debug.panic("Failed to create bytecode: {}", .{e});
    };
    defer bytecode.deinit();

    var result = try BytecodeDisassembly.analyze(allocator, bytecode);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 1), result.instructions.len);
    try testing.expect(result.instructions[0].type == .push_and_fusion);
}

test "optimized analysis - PUSH+OR fusion" {
    const allocator = testing.allocator;

    const code = [_]u8{
        @intFromEnum(Opcode.PUSH1), 0x0F,
        @intFromEnum(Opcode.OR),
    };

    const BytecodeType = @import("bytecode.zig").Bytecode(@import("bytecode_config.zig").BytecodeConfig{});
    const bytecode = BytecodeType.init(allocator, &code) catch |e| {
        std.debug.panic("Failed to create bytecode: {}", .{e});
    };
    defer bytecode.deinit();

    var result = try BytecodeDisassembly.analyze(allocator, bytecode);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 1), result.instructions.len);
    try testing.expect(result.instructions[0].type == .push_or_fusion);
}

test "optimized analysis - PUSH+XOR fusion" {
    const allocator = testing.allocator;

    const code = [_]u8{
        @intFromEnum(Opcode.PUSH1), 0xAA,
        @intFromEnum(Opcode.XOR),
    };

    const BytecodeType = @import("bytecode.zig").Bytecode(@import("bytecode_config.zig").BytecodeConfig{});
    const bytecode = BytecodeType.init(allocator, &code) catch |e| {
        std.debug.panic("Failed to create bytecode: {}", .{e});
    };
    defer bytecode.deinit();

    var result = try BytecodeDisassembly.analyze(allocator, bytecode);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 1), result.instructions.len);
    try testing.expect(result.instructions[0].type == .push_xor_fusion);
}

test "optimized analysis - PUSH+JUMP fusion" {
    const allocator = testing.allocator;

    const code = [_]u8{
        @intFromEnum(Opcode.PUSH1), 0x10,
        @intFromEnum(Opcode.JUMP),
    };

    const BytecodeType = @import("bytecode.zig").Bytecode(@import("bytecode_config.zig").BytecodeConfig{});
    const bytecode = BytecodeType.init(allocator, &code) catch |e| {
        std.debug.panic("Failed to create bytecode: {}", .{e});
    };
    defer bytecode.deinit();

    var result = try BytecodeDisassembly.analyze(allocator, bytecode);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 1), result.instructions.len);
    try testing.expect(result.instructions[0].type == .push_jump_fusion);
    try testing.expectEqual(@as(usize, 1), result.stats.static_jump_candidates);
}

test "optimized analysis - PUSH+JUMPI fusion" {
    const allocator = testing.allocator;

    const code = [_]u8{
        @intFromEnum(Opcode.PUSH1), 0x20,
        @intFromEnum(Opcode.JUMPI),
    };

    const BytecodeType = @import("bytecode.zig").Bytecode(@import("bytecode_config.zig").BytecodeConfig{});
    const bytecode = BytecodeType.init(allocator, &code) catch |e| {
        std.debug.panic("Failed to create bytecode: {}", .{e});
    };
    defer bytecode.deinit();

    var result = try BytecodeDisassembly.analyze(allocator, bytecode);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 1), result.instructions.len);
    try testing.expect(result.instructions[0].type == .push_jumpi_fusion);
}

test "optimized analysis - static jump candidate" {
    const allocator = testing.allocator;

    // PUSH without fusion but followed by JUMP should be marked as static jump candidate
    const code = [_]u8{
        @intFromEnum(Opcode.PUSH1), 0x10,
        @intFromEnum(Opcode.DUP1), // Interrupt the fusion
        @intFromEnum(Opcode.PUSH1), 0x20,
        @intFromEnum(Opcode.JUMP), // This makes previous PUSH a static jump candidate
    };

    const BytecodeType = @import("bytecode.zig").Bytecode(@import("bytecode_config.zig").BytecodeConfig{});
    const bytecode = BytecodeType.init(allocator, &code) catch |e| {
        std.debug.panic("Failed to create bytecode: {}", .{e});
    };
    defer bytecode.deinit();

    var result = try BytecodeDisassembly.analyze(allocator, bytecode);
    defer result.deinit();

    // Should have PUSH, DUP1, then PUSH+JUMP fusion
    try testing.expectEqual(@as(usize, 3), result.instructions.len);
    
    // Last should be push_jump_fusion
    try testing.expect(result.instructions[2].type == .push_jump_fusion);
}

test "optimized analysis - JUMPDEST handling" {
    const allocator = testing.allocator;

    const code = [_]u8{
        @intFromEnum(Opcode.JUMPDEST),
        @intFromEnum(Opcode.PUSH1), 0x01,
        @intFromEnum(Opcode.JUMPDEST),
    };

    const BytecodeType = @import("bytecode.zig").Bytecode(@import("bytecode_config.zig").BytecodeConfig{});
    const bytecode = BytecodeType.init(allocator, &code) catch |e| {
        std.debug.panic("Failed to create bytecode: {}", .{e});
    };
    defer bytecode.deinit();

    var result = try BytecodeDisassembly.analyze(allocator, bytecode);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 3), result.instructions.len);
    
    // First and last should be JUMPDEST
    try testing.expect(result.instructions[0].type == .regular);
    try testing.expectEqual(@as(u8, @intFromEnum(Opcode.JUMPDEST)), result.instructions[0].type.regular.opcode);
    try testing.expect(result.instructions[2].type == .regular);
    try testing.expectEqual(@as(u8, @intFromEnum(Opcode.JUMPDEST)), result.instructions[2].type.regular.opcode);
}

test "optimized analysis - STOP instruction" {
    const allocator = testing.allocator;

    const code = [_]u8{@intFromEnum(Opcode.STOP)};

    const BytecodeType = @import("bytecode.zig").Bytecode(@import("bytecode_config.zig").BytecodeConfig{});
    const bytecode = BytecodeType.init(allocator, &code) catch |e| {
        std.debug.panic("Failed to create bytecode: {}", .{e});
    };
    defer bytecode.deinit();

    var result = try BytecodeDisassembly.analyze(allocator, bytecode);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 1), result.instructions.len);
    try testing.expect(result.instructions[0].type == .regular);
    try testing.expectEqual(@as(u8, 0x00), result.instructions[0].type.regular.opcode);
    try testing.expectEqualStrings("STOP", result.instructions[0].type.regular.name);
    try testing.expectEqual(@as(u32, 0), result.instructions[0].gas_cost);
}

test "optimized analysis - invalid opcode" {
    const allocator = testing.allocator;

    const code = [_]u8{0xEF}; // Invalid opcode

    const BytecodeType = @import("bytecode.zig").Bytecode(@import("bytecode_config.zig").BytecodeConfig{});
    const bytecode = BytecodeType.init(allocator, &code) catch |e| {
        std.debug.panic("Failed to create bytecode: {}", .{e});
    };
    defer bytecode.deinit();

    var result = try BytecodeDisassembly.analyze(allocator, bytecode);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 1), result.instructions.len);
    try testing.expect(result.instructions[0].type == .regular);
    try testing.expectEqualStrings("INVALID", result.instructions[0].type.regular.name);
}

test "optimized analysis - mixed optimizations" {
    const allocator = testing.allocator;

    const code = [_]u8{
        // Regular instruction
        @intFromEnum(Opcode.CALLDATASIZE),
        // PUSH+ADD fusion
        @intFromEnum(Opcode.PUSH1), 0x10,
        @intFromEnum(Opcode.ADD),
        // Regular PUSH
        @intFromEnum(Opcode.PUSH2), 0x01, 0x00,
        // PUSH+MUL fusion
        @intFromEnum(Opcode.PUSH1), 0x02,
        @intFromEnum(Opcode.MUL),
        // STOP
        @intFromEnum(Opcode.STOP),
    };

    const BytecodeType = @import("bytecode.zig").Bytecode(@import("bytecode_config.zig").BytecodeConfig{});
    const bytecode = BytecodeType.init(allocator, &code) catch |e| {
        std.debug.panic("Failed to create bytecode: {}", .{e});
    };
    defer bytecode.deinit();

    var result = try BytecodeDisassembly.analyze(allocator, bytecode);
    defer result.deinit();

    // Should have: CALLDATASIZE, PUSH+ADD fusion, PUSH2, PUSH+MUL fusion, STOP = 5 instructions
    try testing.expectEqual(@as(usize, 5), result.instructions.len);
    
    // Verify instruction types
    try testing.expect(result.instructions[0].type == .regular); // CALLDATASIZE
    try testing.expect(result.instructions[1].type == .push_add_fusion);
    try testing.expect(result.instructions[2].type == .regular); // PUSH2
    try testing.expect(result.instructions[3].type == .push_mul_fusion);
    try testing.expect(result.instructions[4].type == .regular); // STOP
    
    // Stats
    try testing.expectEqual(@as(usize, 2), result.stats.fusion_count);
    try testing.expect(result.stats.gas_saved_estimate > 0);
}

test "optimized analysis - gas savings calculation" {
    const allocator = testing.allocator;

    // Multiple fusions to test gas savings
    const code = [_]u8{
        @intFromEnum(Opcode.PUSH1), 0x10, @intFromEnum(Opcode.ADD),
        @intFromEnum(Opcode.PUSH1), 0x20, @intFromEnum(Opcode.MUL),
        @intFromEnum(Opcode.PUSH1), 0x30, @intFromEnum(Opcode.SUB),
    };

    const BytecodeType = @import("bytecode.zig").Bytecode(@import("bytecode_config.zig").BytecodeConfig{});
    const bytecode = BytecodeType.init(allocator, &code) catch |e| {
        std.debug.panic("Failed to create bytecode: {}", .{e});
    };
    defer bytecode.deinit();

    var result = try BytecodeDisassembly.analyze(allocator, bytecode);
    defer result.deinit();

    // Each fusion saves ~2 gas
    try testing.expectEqual(@as(usize, 3), result.stats.fusion_count);
    try testing.expect(result.stats.gas_saved_estimate >= 6); // 3 fusions * 2 gas each
}

test "optimized analysis - compression ratio" {
    const allocator = testing.allocator;

    // Code with multiple fusions
    const code = [_]u8{
        @intFromEnum(Opcode.PUSH1), 0x10, @intFromEnum(Opcode.ADD), // 3 opcodes → 1 fusion
        @intFromEnum(Opcode.PUSH1), 0x20, @intFromEnum(Opcode.MUL), // 3 opcodes → 1 fusion
        @intFromEnum(Opcode.DUP1), // 1 opcode → 1 instruction
    };

    const BytecodeType = @import("bytecode.zig").Bytecode(@import("bytecode_config.zig").BytecodeConfig{});
    const bytecode = BytecodeType.init(allocator, &code) catch |e| {
        std.debug.panic("Failed to create bytecode: {}", .{e});
    };
    defer bytecode.deinit();

    var result = try BytecodeDisassembly.analyze(allocator, bytecode);
    defer result.deinit();

    // Original: 7 opcodes (PUSH1+val+ADD, PUSH1+val+MUL, DUP1)
    // Optimized: 3 instructions (2 fusions + 1 regular)
    try testing.expectEqual(@as(usize, 3), result.stats.optimized_count);
    // Compression ratio should be 3/7 ≈ 0.43
    try testing.expect(result.stats.compression_ratio < 0.5);
    try testing.expect(result.stats.compression_ratio > 0.4);
}

test "optimized analysis - inline vs pointer storage" {
    const allocator = testing.allocator;

    // Small value (inline) and large value (pointer)
    const code = [_]u8{
        @intFromEnum(Opcode.PUSH1), 0x10, @intFromEnum(Opcode.ADD), // Small value - inline
        @intFromEnum(Opcode.PUSH32),
    } ++ [_]u8{0xFF} ** 32 ++ // Large value - pointer
        [_]u8{@intFromEnum(Opcode.MUL)};

    const BytecodeType = @import("bytecode.zig").Bytecode(@import("bytecode_config.zig").BytecodeConfig{});
    const bytecode = BytecodeType.init(allocator, &code) catch |e| {
        std.debug.panic("Failed to create bytecode: {}", .{e});
    };
    defer bytecode.deinit();

    var result = try BytecodeDisassembly.analyze(allocator, bytecode);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 2), result.instructions.len);
    
    // First fusion should use inline storage (value = 0x10)
    try testing.expect(result.instructions[0].type == .push_add_fusion);
    try testing.expect(result.instructions[0].type.push_add_fusion.value_storage == .inline_64bit);
    
    // Second fusion should use pointer storage (value = max u256)
    try testing.expect(result.instructions[1].type == .push_mul_fusion);
    try testing.expect(result.instructions[1].type.push_mul_fusion.value_storage == .pointer_large);
    
    // Stats
    try testing.expectEqual(@as(usize, 1), result.stats.inline_value_count);
    try testing.expectEqual(@as(usize, 1), result.stats.pointer_value_count);
}

test "optimized analysis - original opcodes extraction" {
    const allocator = testing.allocator;

    const code = [_]u8{
        @intFromEnum(Opcode.PUSH2), 0x12, 0x34,
        @intFromEnum(Opcode.ADD),
    };

    const BytecodeType = @import("bytecode.zig").Bytecode(@import("bytecode_config.zig").BytecodeConfig{});
    const bytecode = BytecodeType.init(allocator, &code) catch |e| {
        std.debug.panic("Failed to create bytecode: {}", .{e});
    };
    defer bytecode.deinit();

    var result = try BytecodeDisassembly.analyze(allocator, bytecode);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 1), result.instructions.len);
    
    // Check original opcodes were properly extracted
    const orig = result.instructions[0].original_opcodes;
    try testing.expectEqual(@as(usize, 2), orig.len); // PUSH2 and ADD
    
    // First original: PUSH2
    try testing.expectEqual(@as(u32, 0), orig[0].pc);
    try testing.expectEqual(@as(u8, @intFromEnum(Opcode.PUSH2)), orig[0].opcode);
    try testing.expectEqualStrings("PUSH2", orig[0].name);
    try testing.expectEqual(@as(?u256, 0x1234), orig[0].push_value);
    
    // Second original: ADD
    try testing.expectEqual(@as(u32, 3), orig[1].pc); // PC after PUSH2 (1) + data (2)
    try testing.expectEqual(@as(u8, @intFromEnum(Opcode.ADD)), orig[1].opcode);
    try testing.expectEqualStrings("ADD", orig[1].name);
    try testing.expectEqual(@as(?u256, null), orig[1].push_value);
}

test "optimized analysis - stack effects" {
    const allocator = testing.allocator;

    const code = [_]u8{
        @intFromEnum(Opcode.PUSH1), 0x10, @intFromEnum(Opcode.ADD), // Inputs: 1 (from stack) + push, Outputs: 1
        @intFromEnum(Opcode.DUP1), // Inputs: 1, Outputs: 2
        @intFromEnum(Opcode.SWAP1), // Inputs: 2, Outputs: 2
        @intFromEnum(Opcode.POP), // Inputs: 1, Outputs: 0
    };

    const BytecodeType = @import("bytecode.zig").Bytecode(@import("bytecode_config.zig").BytecodeConfig{});
    const bytecode = BytecodeType.init(allocator, &code) catch |e| {
        std.debug.panic("Failed to create bytecode: {}", .{e});
    };
    defer bytecode.deinit();

    var result = try BytecodeDisassembly.analyze(allocator, bytecode);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 4), result.instructions.len);
    
    // PUSH+ADD fusion: takes nothing from stack initially (fusion provides the push value)
    try testing.expectEqual(@as(u8, 0), result.instructions[0].stack_inputs);
    try testing.expectEqual(@as(u8, 1), result.instructions[0].stack_outputs);
    
    // DUP1
    try testing.expectEqual(@as(u8, 1), result.instructions[1].stack_inputs);
    try testing.expectEqual(@as(u8, 2), result.instructions[1].stack_outputs);
    
    // SWAP1
    try testing.expectEqual(@as(u8, 2), result.instructions[2].stack_inputs);
    try testing.expectEqual(@as(u8, 2), result.instructions[2].stack_outputs);
    
    // POP
    try testing.expectEqual(@as(u8, 1), result.instructions[3].stack_inputs);
    try testing.expectEqual(@as(u8, 0), result.instructions[3].stack_outputs);
}

test "optimized analysis - multiple PUSH sizes" {
    const allocator = testing.allocator;

    const code = [_]u8{
        @intFromEnum(Opcode.PUSH1), 0xFF,
        @intFromEnum(Opcode.PUSH2), 0x12, 0x34,
        @intFromEnum(Opcode.PUSH4), 0xAB, 0xCD, 0xEF, 0x01,
        @intFromEnum(Opcode.PUSH8), 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
    };

    const BytecodeType = @import("bytecode.zig").Bytecode(@import("bytecode_config.zig").BytecodeConfig{});
    const bytecode = BytecodeType.init(allocator, &code) catch |e| {
        std.debug.panic("Failed to create bytecode: {}", .{e});
    };
    defer bytecode.deinit();

    var result = try BytecodeDisassembly.analyze(allocator, bytecode);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 4), result.instructions.len);
    
    // Verify each PUSH was recognized
    for (result.instructions) |instr| {
        try testing.expect(instr.type == .regular);
        try testing.expect(instr.original_opcodes[0].push_value != null);
    }
    
    // Check values
    try testing.expectEqual(@as(?u256, 0xFF), result.instructions[0].original_opcodes[0].push_value);
    try testing.expectEqual(@as(?u256, 0x1234), result.instructions[1].original_opcodes[0].push_value);
    try testing.expectEqual(@as(?u256, 0xABCDEF01), result.instructions[2].original_opcodes[0].push_value);
    try testing.expectEqual(@as(?u256, 0x0102030405060708), result.instructions[3].original_opcodes[0].push_value);
}

test "optimized analysis - complex control flow" {
    const allocator = testing.allocator;

    const code = [_]u8{
        // Block 1
        @intFromEnum(Opcode.PUSH1), 0x08, // Jump target
        @intFromEnum(Opcode.PUSH1), 0x01, // Condition
        @intFromEnum(Opcode.JUMPI), // Conditional jump
        // Block 2 (skipped if jump taken)
        @intFromEnum(Opcode.PUSH1), 0x00,
        @intFromEnum(Opcode.RETURN),
        // Block 3 (jump target)
        @intFromEnum(Opcode.JUMPDEST), // PC = 8
        @intFromEnum(Opcode.PUSH1), 0x01,
        @intFromEnum(Opcode.RETURN),
    };

    const BytecodeType = @import("bytecode.zig").Bytecode(@import("bytecode_config.zig").BytecodeConfig{});
    const bytecode = BytecodeType.init(allocator, &code) catch |e| {
        std.debug.panic("Failed to create bytecode: {}", .{e});
    };
    defer bytecode.deinit();

    var result = try BytecodeDisassembly.analyze(allocator, bytecode);
    defer result.deinit();

    // Should have optimized some parts while preserving control flow
    try testing.expect(result.instructions.len > 0);
    
    // Find the JUMPDEST
    var found_jumpdest = false;
    for (result.instructions) |instr| {
        if (instr.type == .regular and instr.type.regular.opcode == @intFromEnum(Opcode.JUMPDEST)) {
            found_jumpdest = true;
            try testing.expectEqual(@as(u32, 8), instr.original_pc);
        }
    }
    try testing.expect(found_jumpdest);
}

test "optimized analysis - memory cleanup" {
    const allocator = testing.allocator;

    // Test that deinit properly frees memory
    const code = [_]u8{
        @intFromEnum(Opcode.PUSH1), 0x10, @intFromEnum(Opcode.ADD),
        @intFromEnum(Opcode.PUSH2), 0x20, 0x30, @intFromEnum(Opcode.MUL),
    };

    const BytecodeType = @import("bytecode.zig").Bytecode(@import("bytecode_config.zig").BytecodeConfig{});
    const bytecode = BytecodeType.init(allocator, &code) catch |e| {
        std.debug.panic("Failed to create bytecode: {}", .{e});
    };
    defer bytecode.deinit();

    var result = try BytecodeDisassembly.analyze(allocator, bytecode);
    
    // Verify we have results before cleanup
    try testing.expect(result.instructions.len > 0);
    for (result.instructions) |instr| {
        try testing.expect(instr.original_opcodes.len > 0);
    }
    
    // Clean up - should not crash
    result.deinit();
    
    // After deinit, pointers are freed but structure remains
    try testing.expectEqual(allocator, result.allocator);
}

test "optimized analysis - all fusion types stress test" {
    const allocator = testing.allocator;

    // Test with many different fusion types in sequence
    const code = [_]u8{
        // Various iterator fusions
        @intFromEnum(Opcode.PUSH1), 0x01, @intFromEnum(Opcode.ADD),
        @intFromEnum(Opcode.PUSH1), 0x02, @intFromEnum(Opcode.MUL),
        @intFromEnum(Opcode.PUSH1), 0x03, @intFromEnum(Opcode.SUB),
        @intFromEnum(Opcode.PUSH1), 0x04, @intFromEnum(Opcode.DIV),
        @intFromEnum(Opcode.PUSH1), 0x05, @intFromEnum(Opcode.AND),
        @intFromEnum(Opcode.PUSH1), 0x06, @intFromEnum(Opcode.OR),
        @intFromEnum(Opcode.PUSH1), 0x07, @intFromEnum(Opcode.XOR),
        @intFromEnum(Opcode.PUSH1), 0x08, @intFromEnum(Opcode.JUMP),
        @intFromEnum(Opcode.JUMPDEST), // Jump target
        @intFromEnum(Opcode.PUSH1), 0x09, @intFromEnum(Opcode.JUMPI),
        @intFromEnum(Opcode.STOP),
    };

    const BytecodeType = @import("bytecode.zig").Bytecode(@import("bytecode_config.zig").BytecodeConfig{});
    const bytecode = BytecodeType.init(allocator, &code) catch |e| {
        std.debug.panic("Failed to create bytecode: {}", .{e});
    };
    defer bytecode.deinit();

    var result = try BytecodeDisassembly.analyze(allocator, bytecode);
    defer result.deinit();

    // Should have detected many fusions
    try testing.expect(result.stats.fusion_count >= 9);
    
    // Should have good compression
    try testing.expect(result.stats.compression_ratio < 0.6);
    
    // Should calculate gas savings
    try testing.expect(result.stats.gas_saved_estimate > 0);
    
    // All fusions should use inline storage (small values)
    try testing.expectEqual(result.stats.fusion_count, result.stats.inline_value_count);
    try testing.expectEqual(@as(usize, 0), result.stats.pointer_value_count);
}
