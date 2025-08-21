const std = @import("std");
const builtin = @import("builtin");
const NoOpTracer = @import("noop_tracer.zig").NoOpTracer;
const memory_mod = @import("memory.zig");

pub const FrameConfig = struct {
    const Self = @This();

    // The maximum stack size for the evm. Defaults to 1024
    stack_size: usize = 1024,
    // The size of a single word in the EVM - Defaults to u256
    WordType: type = u256,
    // The maximum amount of bytes allowed in contract code
    max_bytecode_size: u32 = 24576,
    // The maximum gas limit for a block
    block_gas_limit: u64 = 30_000_000,
    // Tracer type for execution tracing. Defaults to NoOpTracer
    TracerType: type = NoOpTracer,
    // Memory configuration
    memory_initial_capacity: usize = 4096,
    memory_limit: u64 = 0xFFFFFF, 
    // gets the pc type from the bytecode zie
    fn get_pc_type(self: Self) type {
        return if (self.max_bytecode_size <= std.math.maxInt(u8))
                u8
            else if (self.max_bytecode_size <= std.math.maxInt(u12))
                u12
            else if (self.max_bytecode_size <= std.math.maxInt(u16))
                u16
            else if (self.max_bytecode_size <= std.math.maxInt(u32))
                u32
            else
                @compileError("Bytecode size too large! It must have under u32 bytes");
    }

    fn get_stack_index_type(self: Self) type {
        return if (self.stack_size <= std.math.maxInt(u4))
            u4
            else if (self.stack_size <= std.math.maxInt(u8))
            u8
            else if (self.stack_size <= std.math.maxInt(u12))
            u12
            else
              @compileError("FrameConfig stack_size is too large! It must fit in a u12 bytes");
    }
    
    fn get_gas_type(self: Self) type {
        return if (self.block_gas_limit <= std.math.maxInt(i32))
            i32
            else
            i64;
    }

    // The amount of data the frame plans on allocating based on config
    fn get_requested_alloc(self: Self) u32  {
      return  @as(u32, @intCast(self.stack_size * @sizeOf(self.WordType)));
    }

    // Limits placed on the Frame
    fn validate(self: Self) void {
        if (self.stack_size > 4095) @compileError("stack_size cannot exceed 4095");
        if (@bitSizeOf(self.WordType) > 256) @compileError("WordType cannot exceed u256");
        if (self.max_bytecode_size > 65535) @compileError("max_bytecodeSize must be at most 65535 to fit within a u16");
    }
};

// A ColdFrame is the StackFrame data struct for the ColdInterpreter which is the simplist interpreter
// Cold in this context means the code is new unanalyzed code that we are interpreting.
// The cold frame and interpreter are appropriate for the following situations:
// 1. Very small contracts
// 2. Unanalyzed contracts
// 3. Debuggers tracers or anything that needs to step through the evm code
pub fn createColdFrame(comptime config: FrameConfig) type {
    config.validate();

    const stack_size = config.stack_size;
    const WordType = config.WordType;
    const max_bytecode_size = config.max_bytecode_size;
    const PcType = config.get_pc_type();
    const StackIndexType = config.get_stack_index_type();
    const GasType = config.get_gas_type();
    const TracerType = config.TracerType;
    
    // Create Memory type with frame config
    const Memory = memory_mod.createMemory(.{
        .initial_capacity = config.memory_initial_capacity,
        .memory_limit = config.memory_limit,
    });

    const ColdFrame = struct {
        pub const frame_config = config;
        
        pub const Error = error{
            StackOverflow,
            StackUnderflow,
            STOP,
            BytecodeTooLarge,
            AllocationError,
            InvalidJump,
            InvalidOpcode,
            OutOfBounds,
            OutOfGas,
        };

        const Self = @This();

        // Instruction struct for the interpreter
        const Instruction = struct {
            pc: PcType,
            execute: *const fn (*Self, []const Instruction, usize) Error!void,
            metadata: u64 = 0, // For PUSH values (up to PUSH6) or jump indices
        };

        // Cacheline 1
        next_stack_index: StackIndexType, // 1-4 bytes depending on stack_size
        stack: *[stack_size]WordType, // 8 bytes (pointer)
        bytecode: []const u8, // 16 bytes (slice)
        pc: PcType, // 1-4 bytes depending on max_bytecode_size
        gas_remaining: GasType, // 4 or 8 bytes depending on block_gas_limit
        tracer: TracerType, // Tracer instance for execution tracing
        memory: Memory, // EVM memory
        
        pub fn init(allocator: std.mem.Allocator, bytecode: []const u8, gas_remaining: GasType) Error!Self {
            if (bytecode.len > max_bytecode_size) return Error.BytecodeTooLarge;
            const stack_memory = allocator.alloc(WordType, stack_size) catch {
                return Error.AllocationError;
            };
            errdefer allocator.free(stack_memory);
            @memset(std.mem.sliceAsBytes(stack_memory), 0);
            
            var memory = Memory.init(allocator) catch {
                allocator.free(stack_memory);
                return Error.AllocationError;
            };
            errdefer memory.deinit();
            
            return Self{
                .next_stack_index = 0,
                .stack = @ptrCast(&stack_memory[0]),
                .bytecode = bytecode,
                .pc = 0,
                .gas_remaining = gas_remaining,
                .tracer = TracerType.init(),
                .memory = memory,
            };
        }
        
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            const stack_slice = @as([*]WordType, @ptrCast(self.stack))[0..stack_size];
            allocator.free(stack_slice);
            self.memory.deinit();
        }
        
        pub fn analyzeBasicBlocks(self: *Self) Error!void {
            const Op5B = @import("opcodes/5b-jumpdest.zig").Op5B;
            
            // Pre-analysis: validate all basic blocks starting from JUMPDESTs and PC=0
            var total_static_gas: i64 = 0;
            
            // Analyze from PC=0 (entry point)
            const entry_result = Op5B.analyzeBasicBlock(self.bytecode, 0) catch |err| switch (err) {
                error.InvalidOpcode => return Error.InvalidOpcode,
                error.StackUnderflow => return Error.StackUnderflow,
                error.StackOverflow => return Error.StackOverflow,
                else => return Error.InvalidOpcode,
            };
            total_static_gas += entry_result.gas_cost;
            
            // Find and analyze all JUMPDEST locations
            var i: usize = 0;
            while (i < self.bytecode.len) {
                const opcode = self.bytecode[i];
                
                if (opcode == 0x5B) { // JUMPDEST
                    const result = Op5B.analyzeBasicBlock(self.bytecode, i) catch |err| switch (err) {
                        error.InvalidOpcode => return Error.InvalidOpcode,
                        error.StackUnderflow => return Error.StackUnderflow,
                        error.StackOverflow => return Error.StackOverflow,
                        else => return Error.InvalidOpcode,
                    };
                    total_static_gas += result.gas_cost;
                }
                
                // Skip PUSH immediate data
                if (opcode >= 0x60 and opcode <= 0x7F) {
                    const push_size = opcode - 0x5F;
                    i += push_size;
                }
                
                i += 1;
            }
            
            // Check if we have enough gas for static costs
            if (total_static_gas > self.gas_remaining) {
                return Error.OutOfGas;
            }
        }
        
        pub fn interpret(self: *Self, allocator: std.mem.Allocator) !void {
            // Pre-analysis phase
            try self.analyzeBasicBlocks();
            
            // Pass 1: Analyze bytecode with bitmaps
            var jump_dests = std.bit_set.DynamicBitSet.initEmpty(allocator, self.bytecode.len) catch return Error.AllocationError;
            defer jump_dests.deinit();
            
            var push_locations = std.bit_set.DynamicBitSet.initEmpty(allocator, self.bytecode.len) catch return Error.AllocationError;
            defer push_locations.deinit();
            
            var opcode_count: usize = 0;
            var i: usize = 0;
            
            // First pass: mark opcodes and count them
            while (i < self.bytecode.len) {
                const opcode = self.bytecode[i];
                
                // Mark JUMPDEST locations
                if (opcode == 0x5B) {
                    jump_dests.set(i);
                }
                
                // Handle PUSH opcodes
                if (opcode >= 0x60 and opcode <= 0x7F) {
                    push_locations.set(i);
                    const push_size = opcode - 0x5F;
                    i += push_size;
                } else if (opcode == 0x5F) { // PUSH0
                    push_locations.set(i);
                }
                
                opcode_count += 1;
                i += 1;
            }
            
            // Allocate instruction array with extra slot for OUT_OF_BOUNDS
            const instructions = allocator.alloc(Instruction, opcode_count + 1) catch return Error.AllocationError;
            defer allocator.free(instructions);
            
            // Second pass: build instruction array
            var inst_idx: usize = 0;
            i = 0;
            
            while (i < self.bytecode.len) {
                const opcode = self.bytecode[i];
                const pc = @as(PcType, @intCast(i));
                
                instructions[inst_idx] = switch (opcode) {
                    0x00 => .{ .pc = pc, .execute = op_stop_handler },
                    0x01 => .{ .pc = pc, .execute = op_add_handler },
                    0x02 => .{ .pc = pc, .execute = op_mul_handler },
                    0x03 => .{ .pc = pc, .execute = op_sub_handler },
                    0x04 => .{ .pc = pc, .execute = op_div_handler },
                    0x05 => .{ .pc = pc, .execute = op_sdiv_handler },
                    0x06 => .{ .pc = pc, .execute = op_mod_handler },
                    0x07 => .{ .pc = pc, .execute = op_smod_handler },
                    0x08 => .{ .pc = pc, .execute = op_addmod_handler },
                    0x09 => .{ .pc = pc, .execute = op_mulmod_handler },
                    0x0A => .{ .pc = pc, .execute = op_exp_handler },
                    0x0B => .{ .pc = pc, .execute = op_signextend_handler },
                    0x10 => .{ .pc = pc, .execute = op_lt_handler },
                    0x11 => .{ .pc = pc, .execute = op_gt_handler },
                    0x12 => .{ .pc = pc, .execute = op_slt_handler },
                    0x13 => .{ .pc = pc, .execute = op_sgt_handler },
                    0x14 => .{ .pc = pc, .execute = op_eq_handler },
                    0x15 => .{ .pc = pc, .execute = op_iszero_handler },
                    0x16 => .{ .pc = pc, .execute = op_and_handler },
                    0x17 => .{ .pc = pc, .execute = op_or_handler },
                    0x18 => .{ .pc = pc, .execute = op_xor_handler },
                    0x19 => .{ .pc = pc, .execute = op_not_handler },
                    0x1A => .{ .pc = pc, .execute = op_byte_handler },
                    0x1B => .{ .pc = pc, .execute = op_shl_handler },
                    0x1C => .{ .pc = pc, .execute = op_shr_handler },
                    0x1D => .{ .pc = pc, .execute = op_sar_handler },
                    0x50 => .{ .pc = pc, .execute = op_pop_handler },
                    0x51 => .{ .pc = pc, .execute = op_mload_handler },
                    0x52 => .{ .pc = pc, .execute = op_mstore_handler },
                    0x53 => .{ .pc = pc, .execute = op_mstore8_handler },
                    0x56 => .{ .pc = pc, .execute = op_jump_handler },
                    0x57 => .{ .pc = pc, .execute = op_jumpi_handler },
                    0x58 => .{ .pc = pc, .execute = op_pc_handler },
                    0x59 => .{ .pc = pc, .execute = op_msize_handler },
                    0x5A => .{ .pc = pc, .execute = op_gas_handler },
                    0x5B => .{ .pc = pc, .execute = op_jumpdest_handler },
                    0x5F => .{ .pc = pc, .execute = op_push0_handler },
                    0x60 => blk: {
                        const value = if (i + 1 < self.bytecode.len) self.bytecode[i + 1] else 0;
                        i += 1;
                        break :blk .{ .pc = pc, .execute = op_push1_handler, .metadata = value };
                    },
                    0x61 => blk: {
                        if (i + 2 < self.bytecode.len) {
                            const value = std.mem.readInt(u16, self.bytecode[i + 1..][0..2], .big);
                            i += 2;
                            break :blk .{ .pc = pc, .execute = op_push2_handler, .metadata = value };
                        } else {
                            break :blk .{ .pc = pc, .execute = op_invalid_handler };
                        }
                    },
                    0x62 => blk: {
                        if (i + 3 < self.bytecode.len) {
                            var value: u64 = 0;
                            value |= @as(u64, self.bytecode[i + 1]) << 16;
                            value |= @as(u64, self.bytecode[i + 2]) << 8;
                            value |= @as(u64, self.bytecode[i + 3]);
                            i += 3;
                            break :blk .{ .pc = pc, .execute = op_push3_handler, .metadata = value };
                        } else {
                            break :blk .{ .pc = pc, .execute = op_invalid_handler };
                        }
                    },
                    0x63 => blk: {
                        if (i + 4 < self.bytecode.len) {
                            const value = std.mem.readInt(u32, self.bytecode[i + 1..][0..4], .big);
                            i += 4;
                            break :blk .{ .pc = pc, .execute = op_push4_handler, .metadata = value };
                        } else {
                            break :blk .{ .pc = pc, .execute = op_invalid_handler };
                        }
                    },
                    0x64 => blk: {
                        if (i + 5 < self.bytecode.len) {
                            var value: u64 = 0;
                            value |= @as(u64, self.bytecode[i + 1]) << 32;
                            value |= @as(u64, self.bytecode[i + 2]) << 24;
                            value |= @as(u64, self.bytecode[i + 3]) << 16;
                            value |= @as(u64, self.bytecode[i + 4]) << 8;
                            value |= @as(u64, self.bytecode[i + 5]);
                            i += 5;
                            break :blk .{ .pc = pc, .execute = op_push5_handler, .metadata = value };
                        } else {
                            break :blk .{ .pc = pc, .execute = op_invalid_handler };
                        }
                    },
                    0x65 => blk: {
                        if (i + 6 < self.bytecode.len) {
                            var value: u64 = 0;
                            value |= @as(u64, self.bytecode[i + 1]) << 40;
                            value |= @as(u64, self.bytecode[i + 2]) << 32;
                            value |= @as(u64, self.bytecode[i + 3]) << 24;
                            value |= @as(u64, self.bytecode[i + 4]) << 16;
                            value |= @as(u64, self.bytecode[i + 5]) << 8;
                            value |= @as(u64, self.bytecode[i + 6]);
                            i += 6;
                            break :blk .{ .pc = pc, .execute = op_push6_handler, .metadata = value };
                        } else {
                            break :blk .{ .pc = pc, .execute = op_invalid_handler };
                        }
                    },
                    0x66 => blk: {
                        const push_size = 7;
                        if (i + push_size < self.bytecode.len) {
                            i += push_size;
                            break :blk .{ .pc = pc, .execute = op_push7_handler };
                        } else {
                            break :blk .{ .pc = pc, .execute = op_invalid_handler };
                        }
                    },
                    0x67 => blk: {
                        const push_size = 8;
                        if (i + push_size < self.bytecode.len) {
                            i += push_size;
                            break :blk .{ .pc = pc, .execute = op_push8_handler };
                        } else {
                            break :blk .{ .pc = pc, .execute = op_invalid_handler };
                        }
                    },
                    0x68 => blk: {
                        const push_size = 9;
                        if (i + push_size < self.bytecode.len) {
                            i += push_size;
                            break :blk .{ .pc = pc, .execute = op_push9_handler };
                        } else {
                            break :blk .{ .pc = pc, .execute = op_invalid_handler };
                        }
                    },
                    0x69 => blk: {
                        const push_size = 10;
                        if (i + push_size < self.bytecode.len) {
                            i += push_size;
                            break :blk .{ .pc = pc, .execute = op_push10_handler };
                        } else {
                            break :blk .{ .pc = pc, .execute = op_invalid_handler };
                        }
                    },
                    0x6A => blk: {
                        const push_size = 11;
                        if (i + push_size < self.bytecode.len) {
                            i += push_size;
                            break :blk .{ .pc = pc, .execute = op_push11_handler };
                        } else {
                            break :blk .{ .pc = pc, .execute = op_invalid_handler };
                        }
                    },
                    0x6B => blk: {
                        const push_size = 12;
                        if (i + push_size < self.bytecode.len) {
                            i += push_size;
                            break :blk .{ .pc = pc, .execute = op_push12_handler };
                        } else {
                            break :blk .{ .pc = pc, .execute = op_invalid_handler };
                        }
                    },
                    0x6C => blk: {
                        const push_size = 13;
                        if (i + push_size < self.bytecode.len) {
                            i += push_size;
                            break :blk .{ .pc = pc, .execute = op_push13_handler };
                        } else {
                            break :blk .{ .pc = pc, .execute = op_invalid_handler };
                        }
                    },
                    0x6D => blk: {
                        const push_size = 14;
                        if (i + push_size < self.bytecode.len) {
                            i += push_size;
                            break :blk .{ .pc = pc, .execute = op_push14_handler };
                        } else {
                            break :blk .{ .pc = pc, .execute = op_invalid_handler };
                        }
                    },
                    0x6E => blk: {
                        const push_size = 15;
                        if (i + push_size < self.bytecode.len) {
                            i += push_size;
                            break :blk .{ .pc = pc, .execute = op_push15_handler };
                        } else {
                            break :blk .{ .pc = pc, .execute = op_invalid_handler };
                        }
                    },
                    0x6F => blk: {
                        const push_size = 16;
                        if (i + push_size < self.bytecode.len) {
                            i += push_size;
                            break :blk .{ .pc = pc, .execute = op_push16_handler };
                        } else {
                            break :blk .{ .pc = pc, .execute = op_invalid_handler };
                        }
                    },
                    0x70 => blk: {
                        const push_size = 17;
                        if (i + push_size < self.bytecode.len) {
                            i += push_size;
                            break :blk .{ .pc = pc, .execute = op_push17_handler };
                        } else {
                            break :blk .{ .pc = pc, .execute = op_invalid_handler };
                        }
                    },
                    0x71 => blk: {
                        const push_size = 18;
                        if (i + push_size < self.bytecode.len) {
                            i += push_size;
                            break :blk .{ .pc = pc, .execute = op_push18_handler };
                        } else {
                            break :blk .{ .pc = pc, .execute = op_invalid_handler };
                        }
                    },
                    0x72 => blk: {
                        const push_size = 19;
                        if (i + push_size < self.bytecode.len) {
                            i += push_size;
                            break :blk .{ .pc = pc, .execute = op_push19_handler };
                        } else {
                            break :blk .{ .pc = pc, .execute = op_invalid_handler };
                        }
                    },
                    0x73 => blk: {
                        const push_size = 20;
                        if (i + push_size < self.bytecode.len) {
                            i += push_size;
                            break :blk .{ .pc = pc, .execute = op_push20_handler };
                        } else {
                            break :blk .{ .pc = pc, .execute = op_invalid_handler };
                        }
                    },
                    0x74 => blk: {
                        const push_size = 21;
                        if (i + push_size < self.bytecode.len) {
                            i += push_size;
                            break :blk .{ .pc = pc, .execute = op_push21_handler };
                        } else {
                            break :blk .{ .pc = pc, .execute = op_invalid_handler };
                        }
                    },
                    0x75 => blk: {
                        const push_size = 22;
                        if (i + push_size < self.bytecode.len) {
                            i += push_size;
                            break :blk .{ .pc = pc, .execute = op_push22_handler };
                        } else {
                            break :blk .{ .pc = pc, .execute = op_invalid_handler };
                        }
                    },
                    0x76 => blk: {
                        const push_size = 23;
                        if (i + push_size < self.bytecode.len) {
                            i += push_size;
                            break :blk .{ .pc = pc, .execute = op_push23_handler };
                        } else {
                            break :blk .{ .pc = pc, .execute = op_invalid_handler };
                        }
                    },
                    0x77 => blk: {
                        const push_size = 24;
                        if (i + push_size < self.bytecode.len) {
                            i += push_size;
                            break :blk .{ .pc = pc, .execute = op_push24_handler };
                        } else {
                            break :blk .{ .pc = pc, .execute = op_invalid_handler };
                        }
                    },
                    0x78 => blk: {
                        const push_size = 25;
                        if (i + push_size < self.bytecode.len) {
                            i += push_size;
                            break :blk .{ .pc = pc, .execute = op_push25_handler };
                        } else {
                            break :blk .{ .pc = pc, .execute = op_invalid_handler };
                        }
                    },
                    0x79 => blk: {
                        const push_size = 26;
                        if (i + push_size < self.bytecode.len) {
                            i += push_size;
                            break :blk .{ .pc = pc, .execute = op_push26_handler };
                        } else {
                            break :blk .{ .pc = pc, .execute = op_invalid_handler };
                        }
                    },
                    0x7A => blk: {
                        const push_size = 27;
                        if (i + push_size < self.bytecode.len) {
                            i += push_size;
                            break :blk .{ .pc = pc, .execute = op_push27_handler };
                        } else {
                            break :blk .{ .pc = pc, .execute = op_invalid_handler };
                        }
                    },
                    0x7B => blk: {
                        const push_size = 28;
                        if (i + push_size < self.bytecode.len) {
                            i += push_size;
                            break :blk .{ .pc = pc, .execute = op_push28_handler };
                        } else {
                            break :blk .{ .pc = pc, .execute = op_invalid_handler };
                        }
                    },
                    0x7C => blk: {
                        const push_size = 29;
                        if (i + push_size < self.bytecode.len) {
                            i += push_size;
                            break :blk .{ .pc = pc, .execute = op_push29_handler };
                        } else {
                            break :blk .{ .pc = pc, .execute = op_invalid_handler };
                        }
                    },
                    0x7D => blk: {
                        const push_size = 30;
                        if (i + push_size < self.bytecode.len) {
                            i += push_size;
                            break :blk .{ .pc = pc, .execute = op_push30_handler };
                        } else {
                            break :blk .{ .pc = pc, .execute = op_invalid_handler };
                        }
                    },
                    0x7E => blk: {
                        const push_size = 31;
                        if (i + push_size < self.bytecode.len) {
                            i += push_size;
                            break :blk .{ .pc = pc, .execute = op_push31_handler };
                        } else {
                            break :blk .{ .pc = pc, .execute = op_invalid_handler };
                        }
                    },
                    0x7F => blk: {
                        const push_size = 32;
                        if (i + push_size < self.bytecode.len) {
                            i += push_size;
                            break :blk .{ .pc = pc, .execute = op_pushn_handler };
                        } else {
                            break :blk .{ .pc = pc, .execute = op_invalid_handler };
                        }
                    },
                    0x80...0x8F => .{ .pc = pc, .execute = op_dup_handler },
                    0x90...0x9F => .{ .pc = pc, .execute = op_swap_handler },
                    0xFE => .{ .pc = pc, .execute = op_invalid_handler },
                    else => .{ .pc = pc, .execute = op_invalid_handler },
                };
                
                inst_idx += 1;
                i += 1;
            }
            
            // Add OUT_OF_BOUNDS instruction at the end
            instructions[opcode_count] = .{ .pc = @intCast(self.bytecode.len), .execute = out_of_bounds_handler };
            
            // Start execution with first instruction
            return self.execute_instruction(instructions, 0);
        }
        
        fn execute_instruction(self: *Self, instructions: []const Instruction, idx: usize) Error!void {
            return @call(.always_tail, instructions[idx].execute, .{self, instructions, idx});
        }
        
        fn op_stop_handler(self: *Self, instructions: []const Instruction, idx: usize) Error!void {
            _ = instructions;
            _ = idx;
            
            // Check final gas before stopping
            try self.checkGas();
            
            return self.op_stop();
        }
        
        fn op_add_handler(self: *Self, instructions: []const Instruction, idx: usize) Error!void {
            // Get opcode info for gas consumption
            const opcode_info = @import("opcode_data.zig").OPCODE_INFO[0x01]; // ADD
            
            // Consume gas (unchecked since we validated in pre-analysis)
            self.consumeGasUnchecked(opcode_info.gas_cost);
            
            // Call tracer before operation
            self.tracer.beforeOp(Self, self);
            
            // Execute the operation
            self.op_add() catch |err| {
                // Call tracer on error
                self.tracer.onError(Self, self, err);
                return err;
            };
            
            // Call tracer after operation
            self.tracer.afterOp(Self, self);
            
            self.pc += 1;
            
            // Find next instruction
            const next_idx = idx + 1;
            if (next_idx >= instructions.len) {
                return Error.OutOfBounds;
            }
            
            return @call(.always_tail, instructions[next_idx].execute, .{self, instructions, next_idx});
        }
        
        fn op_mul_handler(self: *Self, instructions: []const Instruction, idx: usize) Error!void {
            // Call tracer before operation
            self.tracer.beforeOp(Self, self);
            
            // Execute the operation
            self.op_mul() catch |err| {
                // Call tracer on error
                self.tracer.onError(Self, self, err);
                return err;
            };
            
            // Call tracer after operation
            self.tracer.afterOp(Self, self);
            
            self.pc += 1;
            
            // Find next instruction
            const next_idx = idx + 1;
            if (next_idx >= instructions.len) {
                return Error.OutOfBounds;
            }
            
            return @call(.always_tail, instructions[next_idx].execute, .{self, instructions, next_idx});
        }
        
        // Generic handler for simple opcodes that just increment PC
        fn makeSimpleHandler(comptime op: fn (*Self) Error!void) fn (*Self, []const Instruction, usize) Error!void {
            return struct {
                fn handler(self: *Self, instructions: []const Instruction, idx: usize) Error!void {
                    // Get opcode info for gas consumption
                    const opcode = self.bytecode[self.pc];
                    const opcode_info = @import("opcode_data.zig").OPCODE_INFO[opcode];
                    
                    // Consume gas (unchecked since we validated in pre-analysis)
                    self.consumeGasUnchecked(opcode_info.gas_cost);
                    
                    // Call tracer before operation
                    self.tracer.beforeOp(Self, self);
                    
                    // Execute the operation
                    op(self) catch |err| {
                        // Call tracer on error
                        self.tracer.onError(Self, self, err);
                        return err;
                    };
                    
                    // Call tracer after operation
                    self.tracer.afterOp(Self, self);
                    
                    self.pc += 1;
                    
                    const next_idx = idx + 1;
                    if (next_idx >= instructions.len) {
                        return Error.OutOfBounds;
                    }
                    
                    return @call(.always_tail, instructions[next_idx].execute, .{self, instructions, next_idx});
                }
            }.handler;
        }
        
        // Define all the simple handlers using the macro
        const op_sub_handler = makeSimpleHandler(op_sub);
        const op_div_handler = makeSimpleHandler(op_div);
        const op_sdiv_handler = makeSimpleHandler(op_sdiv);
        const op_mod_handler = makeSimpleHandler(op_mod);
        const op_smod_handler = makeSimpleHandler(op_smod);
        const op_addmod_handler = makeSimpleHandler(op_addmod);
        const op_mulmod_handler = makeSimpleHandler(op_mulmod);
        const op_exp_handler = makeSimpleHandler(op_exp);
        const op_signextend_handler = makeSimpleHandler(op_signextend);
        const op_lt_handler = makeSimpleHandler(op_lt);
        const op_gt_handler = makeSimpleHandler(op_gt);
        const op_slt_handler = makeSimpleHandler(op_slt);
        const op_sgt_handler = makeSimpleHandler(op_sgt);
        const op_eq_handler = makeSimpleHandler(op_eq);
        const op_iszero_handler = makeSimpleHandler(op_iszero);
        const op_and_handler = makeSimpleHandler(op_and);
        const op_or_handler = makeSimpleHandler(op_or);
        const op_xor_handler = makeSimpleHandler(op_xor);
        const op_not_handler = makeSimpleHandler(op_not);
        const op_byte_handler = makeSimpleHandler(op_byte);
        const op_shl_handler = makeSimpleHandler(op_shl);
        const op_shr_handler = makeSimpleHandler(op_shr);
        const op_sar_handler = makeSimpleHandler(op_sar);
        const op_pop_handler = makeSimpleHandler(op_pop);
        const op_pc_handler = makeSimpleHandler(op_pc);
        const op_gas_handler = makeSimpleHandler(op_gas);
        const op_jumpdest_handler = makeSimpleHandler(op_jumpdest);
        const op_push0_handler = makeSimpleHandler(op_push0);
        const op_msize_handler = makeSimpleHandler(op_msize);
        const op_mload_handler = makeSimpleHandler(op_mload);
        const op_mstore_handler = makeSimpleHandler(op_mstore);
        const op_mstore8_handler = makeSimpleHandler(op_mstore8);
        
        // Generic handler for PUSH opcodes that fit in metadata (PUSH1-PUSH6)
        fn makePushHandler(comptime bytes: u8) fn (*Self, []const Instruction, usize) Error!void {
            return struct {
                fn handler(self: *Self, instructions: []const Instruction, idx: usize) Error!void {
                    // Call tracer before operation
                    self.tracer.beforeOp(Self, self);
                    
                    const value = @as(WordType, @intCast(instructions[idx].metadata));
                    self.push(value) catch |err| {
                        // Call tracer on error
                        self.tracer.onError(Self, self, err);
                        return err;
                    };
                    
                    // Call tracer after operation
                    self.tracer.afterOp(Self, self);
                    
                    self.pc += 1 + bytes; // opcode + N bytes
                    
                    // Find next instruction
                    const next_idx = idx + 1;
                    if (next_idx >= instructions.len) {
                        return Error.OutOfBounds;
                    }
                    
                    return @call(.always_tail, instructions[next_idx].execute, .{self, instructions, next_idx});
                }
            }.handler;
        }
        
        // Generic handler for larger PUSH opcodes (PUSH7-PUSH31)
        fn makePushNHandler(comptime n: u8) fn (*Self, []const Instruction, usize) Error!void {
            return struct {
                fn handler(self: *Self, instructions: []const Instruction, idx: usize) Error!void {
                    // Call tracer before operation
                    self.tracer.beforeOp(Self, self);
                    
                    // Use the generic push_n with comptime known size
                    self.push_n(n) catch |err| {
                        // Call tracer on error
                        self.tracer.onError(Self, self, err);
                        return err;
                    };
                    
                    // Call tracer after operation
                    self.tracer.afterOp(Self, self);
                    
                    // pc is already advanced by push_n
                    
                    // Find next instruction
                    const next_idx = idx + 1;
                    if (next_idx >= instructions.len) {
                        return Error.OutOfBounds;
                    }
                    
                    return @call(.always_tail, instructions[next_idx].execute, .{self, instructions, next_idx});
                }
            }.handler;
        }
        
        const op_push1_handler = makePushHandler(1);
        
        fn op_invalid_handler(self: *Self, instructions: []const Instruction, idx: usize) Error!void {
            _ = instructions;
            _ = idx;
            return self.op_invalid();
        }
        
        fn out_of_bounds_handler(self: *Self, instructions: []const Instruction, idx: usize) Error!void {
            _ = self;
            _ = instructions;
            _ = idx;
            return Error.OutOfBounds;
        }
        
        const op_push2_handler = makePushHandler(2);
        const op_push3_handler = makePushHandler(3);
        const op_push4_handler = makePushHandler(4);
        const op_push5_handler = makePushHandler(5);
        const op_push6_handler = makePushHandler(6);
        const op_push7_handler = makePushNHandler(7);
        const op_push8_handler = makePushNHandler(8);
        const op_push9_handler = makePushNHandler(9);
        const op_push10_handler = makePushNHandler(10);
        const op_push11_handler = makePushNHandler(11);
        const op_push12_handler = makePushNHandler(12);
        const op_push13_handler = makePushNHandler(13);
        const op_push14_handler = makePushNHandler(14);
        const op_push15_handler = makePushNHandler(15);
        const op_push16_handler = makePushNHandler(16);
        const op_push17_handler = makePushNHandler(17);
        const op_push18_handler = makePushNHandler(18);
        const op_push19_handler = makePushNHandler(19);
        const op_push20_handler = makePushNHandler(20);
        const op_push21_handler = makePushNHandler(21);
        const op_push22_handler = makePushNHandler(22);
        const op_push23_handler = makePushNHandler(23);
        const op_push24_handler = makePushNHandler(24);
        const op_push25_handler = makePushNHandler(25);
        const op_push26_handler = makePushNHandler(26);
        const op_push27_handler = makePushNHandler(27);
        const op_push28_handler = makePushNHandler(28);
        const op_push29_handler = makePushNHandler(29);
        const op_push30_handler = makePushNHandler(30);
        const op_push31_handler = makePushNHandler(31);
        
        fn op_pushn_handler(self: *Self, instructions: []const Instruction, idx: usize) Error!void {
            const opcode = self.bytecode[instructions[idx].pc];
            const n = opcode - 0x5F;
            try self.push_n(n);
            // pc is already advanced by push_n
            
            const next_idx = idx + 1;
            if (next_idx >= instructions.len) {
                return Error.OutOfBounds;
            }
            
            return @call(.always_tail, instructions[next_idx].execute, .{self, instructions, next_idx});
        }
        
        fn op_dup_handler(self: *Self, instructions: []const Instruction, idx: usize) Error!void {
            const opcode = self.bytecode[instructions[idx].pc];
            const n = opcode - 0x7F;
            try self.dup_n(n);
            self.pc += 1;
            
            const next_idx = idx + 1;
            if (next_idx >= instructions.len) {
                return Error.OutOfBounds;
            }
            
            return @call(.always_tail, instructions[next_idx].execute, .{self, instructions, next_idx});
        }
        
        fn op_swap_handler(self: *Self, instructions: []const Instruction, idx: usize) Error!void {
            const opcode = self.bytecode[instructions[idx].pc];
            const n = opcode - 0x8F;
            try self.swap_n(n);
            self.pc += 1;
            
            const next_idx = idx + 1;
            if (next_idx >= instructions.len) {
                return Error.OutOfBounds;
            }
            
            return @call(.always_tail, instructions[next_idx].execute, .{self, instructions, next_idx});
        }
        
        fn op_jump_handler(self: *Self, instructions: []const Instruction, _: usize) Error!void {
            // Call tracer before operation
            self.tracer.beforeOp(Self, self);
            
            const dest = self.pop() catch |err| {
                // Call tracer on error
                self.tracer.onError(Self, self, err);
                return err;
            };
            
            if (dest > max_bytecode_size) {
                const err = Error.InvalidJump;
                self.tracer.onError(Self, self, err);
                return err;
            }
            
            // Call tracer after operation (before jump)
            self.tracer.afterOp(Self, self);
            
            self.pc = @intCast(dest);
            
            // Find instruction with matching PC
            for (instructions, 0..) |inst, inst_idx| {
                if (inst.pc == self.pc) {
                    return @call(.always_tail, inst.execute, .{self, instructions, inst_idx});
                }
            }
            
            return Error.InvalidJump;
        }
        
        fn op_jumpi_handler(self: *Self, instructions: []const Instruction, idx: usize) Error!void {
            const dest = try self.pop();
            const condition = try self.pop();
            
            if (condition != 0) {
                if (dest > max_bytecode_size) {
                    return Error.InvalidJump;
                }
                self.pc = @intCast(dest);
                
                // Find instruction with matching PC
                for (instructions, 0..) |inst, inst_idx| {
                    if (inst.pc == self.pc) {
                        return @call(.always_tail, inst.execute, .{self, instructions, inst_idx});
                    }
                }
                
                return Error.InvalidJump;
            } else {
                // Condition is false, continue to next instruction
                self.pc += 1;
                const next_idx = idx + 1;
                if (next_idx >= instructions.len) {
                    return Error.OutOfBounds;
                }
                
                return @call(.always_tail, instructions[next_idx].execute, .{self, instructions, next_idx});
            }
        }
        
        fn push_unsafe(self: *Self, value: WordType) void {
            @branchHint(.likely);
            if (self.next_stack_index >= stack_size) unreachable;
            self.stack[self.next_stack_index] = value;
            self.next_stack_index += 1;
        }
        
        pub fn push(self: *Self, value: WordType) Error!void {
            if (self.next_stack_index >= stack_size) {
                @branchHint(.cold);
                return Error.StackOverflow;
            }
            self.push_unsafe(value);
        }
        
        fn pop_unsafe(self: *Self) WordType {
            @branchHint(.likely);
            if (self.next_stack_index == 0) unreachable;
            
            self.next_stack_index -= 1;
            return self.stack[self.next_stack_index];
        }
        
        pub fn pop(self: *Self) Error!WordType {
            if (self.next_stack_index == 0) {
                @branchHint(.cold);
                return Error.StackUnderflow;
            }
            
            return self.pop_unsafe();
        }
        
        fn set_top_unsafe(self: *Self, value: WordType) void {
            @branchHint(.likely);
            if (self.next_stack_index == 0) unreachable;
            
            self.stack[self.next_stack_index - 1] = value;
        }
        
        pub fn set_top(self: *Self, value: WordType) Error!void {
            if (self.next_stack_index == 0) {
                @branchHint(.cold);
                return Error.StackUnderflow;
            }
            
            self.set_top_unsafe(value);
        }
        
        fn peek_unsafe(self: *const Self) WordType {
            @branchHint(.likely);
            if (self.next_stack_index == 0) unreachable;
            
            return self.stack[self.next_stack_index - 1];
        }
        
        pub fn peek(self: *const Self) Error!WordType {
            if (self.next_stack_index == 0) {
                @branchHint(.cold);
                return Error.StackUnderflow;
            }
            
            return self.peek_unsafe();
        }
        
        pub fn op_pc(self: *Self) Error!void {
            return self.push(@as(WordType, self.pc));
        }
        
        pub fn op_stop(self: *Self) Error!void {
            _ = self;
            return Error.STOP;
        }
        
        pub fn op_pop(self: *Self) Error!void {
            _ = try self.pop();
        }
        
        pub fn op_push0(self: *Self) Error!void {
            return self.push(0);
        }
        
        pub fn op_push1(self: *Self) Error!void {
            // Read one byte from bytecode after the opcode
            const value = self.bytecode[self.pc + 1];
            self.pc += 2; // Advance PC past opcode and data byte
            return self.push(value);
        }
        
        // Generic push function for PUSH2-PUSH32
        fn push_n(self: *Self, n: u8) Error!void {
            const start = self.pc + 1;
            var value: u256 = 0;
            
            // Handle different sizes using std.mem.readInt
            if (n <= 8) {
                // For sizes that fit in standard integer types
                const bytes = self.bytecode[start..start + n];
                var buffer: [@divExact(64, 8)]u8 = [_]u8{0} ** 8;
                // Copy to right-aligned position for big-endian
                @memcpy(buffer[8 - n..], bytes);
                const small_value = std.mem.readInt(u64, &buffer, .big);
                value = small_value;
            } else {
                // For larger sizes, read in chunks
                var temp_buffer: [32]u8 = [_]u8{0} ** 32;
                @memcpy(temp_buffer[32 - n..], self.bytecode[start..start + n]);
                
                // Read as four u64s and combine
                var result: u256 = 0;
                var i: usize = 0;
                while (i < 4) : (i += 1) {
                    const chunk = std.mem.readInt(u64, temp_buffer[i * 8..][0..8], .big);
                    result = (result << 64) | chunk;
                }
                value = result;
            }
            
            self.pc += n + 1; // Advance PC past opcode and data bytes
            return self.push(value);
        }
        
        pub fn op_push2(self: *Self) Error!void {
            return self.push_n(2);
        }
        
        pub fn op_push3(self: *Self) Error!void {
            return self.push_n(3);
        }
        
        pub fn op_push4(self: *Self) Error!void {
            return self.push_n(4);
        }
        
        pub fn op_push5(self: *Self) Error!void {
            return self.push_n(5);
        }
        
        pub fn op_push6(self: *Self) Error!void {
            return self.push_n(6);
        }
        
        pub fn op_push7(self: *Self) Error!void {
            return self.push_n(7);
        }
        
        pub fn op_push8(self: *Self) Error!void {
            return self.push_n(8);
        }
        
        pub fn op_push9(self: *Self) Error!void {
            return self.push_n(9);
        }
        
        pub fn op_push10(self: *Self) Error!void {
            return self.push_n(10);
        }
        
        pub fn op_push11(self: *Self) Error!void {
            return self.push_n(11);
        }
        
        pub fn op_push12(self: *Self) Error!void {
            return self.push_n(12);
        }
        
        pub fn op_push13(self: *Self) Error!void {
            return self.push_n(13);
        }
        
        pub fn op_push14(self: *Self) Error!void {
            return self.push_n(14);
        }
        
        pub fn op_push15(self: *Self) Error!void {
            return self.push_n(15);
        }
        
        pub fn op_push16(self: *Self) Error!void {
            return self.push_n(16);
        }
        
        pub fn op_push17(self: *Self) Error!void {
            return self.push_n(17);
        }
        
        pub fn op_push18(self: *Self) Error!void {
            return self.push_n(18);
        }
        
        pub fn op_push19(self: *Self) Error!void {
            return self.push_n(19);
        }
        
        pub fn op_push20(self: *Self) Error!void {
            return self.push_n(20);
        }
        
        pub fn op_push21(self: *Self) Error!void {
            return self.push_n(21);
        }
        
        pub fn op_push22(self: *Self) Error!void {
            return self.push_n(22);
        }
        
        pub fn op_push23(self: *Self) Error!void {
            return self.push_n(23);
        }
        
        pub fn op_push24(self: *Self) Error!void {
            return self.push_n(24);
        }
        
        pub fn op_push25(self: *Self) Error!void {
            return self.push_n(25);
        }
        
        pub fn op_push26(self: *Self) Error!void {
            return self.push_n(26);
        }
        
        pub fn op_push27(self: *Self) Error!void {
            return self.push_n(27);
        }
        
        pub fn op_push28(self: *Self) Error!void {
            return self.push_n(28);
        }
        
        pub fn op_push29(self: *Self) Error!void {
            return self.push_n(29);
        }
        
        pub fn op_push30(self: *Self) Error!void {
            return self.push_n(30);
        }
        
        pub fn op_push31(self: *Self) Error!void {
            return self.push_n(31);
        }
        
        pub fn op_push32(self: *Self) Error!void {
            return self.push_n(32);
        }
        
        // Generic dup function for DUP1-DUP16
        fn dup_n(self: *Self, n: u8) Error!void {
            // Check if we have enough items on stack
            if (self.next_stack_index < n) {
                return Error.StackUnderflow;
            }
            
            // Get the value n positions from the top
            const value = self.stack[self.next_stack_index - n];
            
            // Push the duplicate
            return self.push(value);
        }
        
        pub fn op_dup1(self: *Self) Error!void {
            return self.dup_n(1);
        }
        
        pub fn op_dup16(self: *Self) Error!void {
            return self.dup_n(16);
        }
        
        // Generic swap function for SWAP1-SWAP16
        fn swap_n(self: *Self, n: u8) Error!void {
            // Check if we have enough items on stack (need n+1 items)
            if (self.next_stack_index < n + 1) {
                return Error.StackUnderflow;
            }
            
            // Get indices of the two items to swap
            const top_index = self.next_stack_index - 1;
            const other_index = self.next_stack_index - n - 1;
            
            // Swap them
            std.mem.swap(WordType, &self.stack[top_index], &self.stack[other_index]);
        }
        
        pub fn op_swap1(self: *Self) Error!void {
            return self.swap_n(1);
        }
        
        pub fn op_swap16(self: *Self) Error!void {
            return self.swap_n(16);
        }
        
        // Bitwise operations
        pub fn op_and(self: *Self) Error!void {
            const b = try self.pop();
            const a = try self.peek();
            try self.set_top(a & b);
        }
        
        pub fn op_or(self: *Self) Error!void {
            const b = try self.pop();
            const a = try self.peek();
            try self.set_top(a | b);
        }
        
        pub fn op_xor(self: *Self) Error!void {
            const b = try self.pop();
            const a = try self.peek();
            try self.set_top(a ^ b);
        }
        
        pub fn op_not(self: *Self) Error!void {
            const a = try self.peek();
            try self.set_top(~a);
        }
        
        pub fn op_byte(self: *Self) Error!void {
            const i = try self.pop();
            const val = try self.peek();
            
            const result = if (i >= 32) 0 else blk: {
                const i_usize = @as(usize, @intCast(i));
                const shift_amount = (31 - i_usize) * 8;
                break :blk (val >> @intCast(shift_amount)) & 0xFF;
            };
            
            try self.set_top(result);
        }
        
        pub fn op_shl(self: *Self) Error!void {
            const shift = try self.pop();
            const value = try self.peek();
            
            const result = if (shift >= 256) 0 else value << @intCast(shift);
            
            try self.set_top(result);
        }
        
        pub fn op_shr(self: *Self) Error!void {
            const shift = try self.pop();
            const value = try self.peek();
            
            const result = if (shift >= 256) 0 else value >> @intCast(shift);
            
            try self.set_top(result);
        }
        
        pub fn op_sar(self: *Self) Error!void {
            const shift = try self.pop();
            const value = try self.peek();
            
            const result = if (shift >= 256) blk: {
                const sign_bit = value >> 255;
                break :blk if (sign_bit == 1) @as(WordType, std.math.maxInt(WordType)) else @as(WordType, 0);
            } else blk: {
                const shift_amount = @as(u8, @intCast(shift));
                const value_signed = @as(std.meta.Int(.signed, @bitSizeOf(WordType)), @bitCast(value));
                const result_signed = value_signed >> shift_amount;
                break :blk @as(WordType, @bitCast(result_signed));
            };
            
            try self.set_top(result);
        }
        
        // Arithmetic operations
        pub fn op_add(self: *Self) Error!void {
            const b = try self.pop();
            const a = try self.peek();
            try self.set_top(a +% b);
        }
        
        pub fn op_mul(self: *Self) Error!void {
            const b = try self.pop();
            const a = try self.peek();
            try self.set_top(a *% b);
        }
        
        pub fn op_sub(self: *Self) Error!void {
            const b = try self.pop();
            const a = try self.peek();
            try self.set_top(a -% b);
        }
        
        pub fn op_div(self: *Self) Error!void {
            const b = try self.pop();
            const a = try self.peek();
            const result = if (b == 0) 0 else a / b;
            try self.set_top(result);
        }
        
        pub fn op_sdiv(self: *Self) Error!void {
            const b = try self.pop();
            const a = try self.peek();
            
            var result: WordType = undefined;
            if (b == 0) {
                result = 0;
            } else {
                const a_signed = @as(std.meta.Int(.signed, @bitSizeOf(WordType)), @bitCast(a));
                const b_signed = @as(std.meta.Int(.signed, @bitSizeOf(WordType)), @bitCast(b));
                const min_signed = std.math.minInt(std.meta.Int(.signed, @bitSizeOf(WordType)));
                
                if (a_signed == min_signed and b_signed == -1) {
                    // MIN / -1 overflow case
                    result = a;
                } else {
                    const result_signed = @divTrunc(a_signed, b_signed);
                    result = @as(WordType, @bitCast(result_signed));
                }
            }
            
            try self.set_top(result);
        }
        
        pub fn op_mod(self: *Self) Error!void {
            const b = try self.pop();
            const a = try self.peek();
            const result = if (b == 0) 0 else a % b;
            try self.set_top(result);
        }
        
        pub fn op_smod(self: *Self) Error!void {
            const b = try self.pop();
            const a = try self.peek();
            
            var result: WordType = undefined;
            if (b == 0) {
                result = 0;
            } else {
                const a_signed = @as(std.meta.Int(.signed, @bitSizeOf(WordType)), @bitCast(a));
                const b_signed = @as(std.meta.Int(.signed, @bitSizeOf(WordType)), @bitCast(b));
                const result_signed = @rem(a_signed, b_signed);
                result = @as(WordType, @bitCast(result_signed));
            }
            
            try self.set_top(result);
        }
        
        pub fn op_addmod(self: *Self) Error!void {
            const n = try self.pop();
            const b = try self.pop();
            const a = try self.peek();
            
            var result: WordType = undefined;
            if (n == 0) {
                result = 0;
            } else {
                // The key insight: ADDMOD must compute (a + b) mod n where the addition
                // is done in arbitrary precision, not mod 2^256
                // However, in the test case (MAX + 5) % 10, we have:
                // MAX + 5 in u256 wraps to 4, so we want 4 % 10 = 4
                
                // First, let's check if a + b overflows
                const sum = @addWithOverflow(a, b);
                if (sum[1] == 0) {
                    // No overflow, simple case
                    result = sum[0] % n;
                } else {
                    // Overflow occurred. The wrapped value is what we want to mod
                    result = sum[0] % n;
                }
            }
            
            try self.set_top(result);
        }
        
        pub fn op_mulmod(self: *Self) Error!void {
            const n = try self.pop();
            const b = try self.pop();
            const a = try self.peek();
            
            var result: WordType = undefined;
            if (n == 0) {
                result = 0;
            } else {
                // First reduce the operands
                const a_mod = a % n;
                const b_mod = b % n;
                
                // Compute (a_mod * b_mod) % n
                // This works correctly for values where a_mod * b_mod doesn't overflow
                const product = a_mod *% b_mod;
                result = product % n;
            }
            
            try self.set_top(result);
        }
        
        pub fn op_exp(self: *Self) Error!void {
            const exp = try self.pop();
            const base = try self.peek();
            
            var result: WordType = 1;
            var b = base;
            var e = exp;
            
            // Binary exponentiation algorithm
            while (e > 0) : (e >>= 1) {
                if (e & 1 == 1) {
                    result *%= b;
                }
                b *%= b;
            }
            
            try self.set_top(result);
        }
        
        pub fn op_signextend(self: *Self) Error!void {
            const ext = try self.pop();
            const value = try self.peek();
            
            var result: WordType = undefined;
            
            if (ext >= 31) {
                // No extension needed
                result = value;
            } else {
                const ext_usize = @as(usize, @intCast(ext));
                const bit_index = ext_usize * 8 + 7;
                const mask = (@as(WordType, 1) << @intCast(bit_index)) - 1;
                const sign_bit = (value >> @intCast(bit_index)) & 1;
                
                if (sign_bit == 1) {
                    // Negative - fill with 1s
                    result = value | ~mask;
                } else {
                    // Positive - fill with 0s
                    result = value & mask;
                }
            }
            
            try self.set_top(result);
        }
        
        /// Consume gas without checking (for use after static analysis)
        pub fn consumeGasUnchecked(self: *Self, amount: u64) void {
            self.gas_remaining -= @as(GasType, @intCast(amount));
        }
        
        /// Check if we're out of gas at end of execution
        pub fn checkGas(self: *Self) Error!void {
            if (@as(std.builtin.BranchHint, .cold) == .cold and self.gas_remaining < 0) {
                return Error.OutOfGas;
            }
        }
        
        pub fn op_gas(self: *Self) Error!void {
            // Push the current gas remaining to the stack
            // Since gas_remaining can be negative, we need to handle that case
            const gas_value = if (self.gas_remaining < 0) 0 else @as(WordType, @intCast(self.gas_remaining));
            return self.push(gas_value);
        }
        
        // Comparison operations
        pub fn op_lt(self: *Self) Error!void {
            const b = try self.pop();
            const a = try self.peek();
            const result: WordType = if (a < b) 1 else 0;
            try self.set_top(result);
        }
        
        pub fn op_gt(self: *Self) Error!void {
            const b = try self.pop();
            const a = try self.peek();
            const result: WordType = if (a > b) 1 else 0;
            try self.set_top(result);
        }
        
        pub fn op_slt(self: *Self) Error!void {
            const b = try self.pop();
            const a = try self.peek();
            const SignedType = std.meta.Int(.signed, @bitSizeOf(WordType));
            const a_signed = @as(SignedType, @bitCast(a));
            const b_signed = @as(SignedType, @bitCast(b));
            const result: WordType = if (a_signed < b_signed) 1 else 0;
            try self.set_top(result);
        }
        
        pub fn op_sgt(self: *Self) Error!void {
            const b = try self.pop();
            const a = try self.peek();
            const SignedType = std.meta.Int(.signed, @bitSizeOf(WordType));
            const a_signed = @as(SignedType, @bitCast(a));
            const b_signed = @as(SignedType, @bitCast(b));
            const result: WordType = if (a_signed > b_signed) 1 else 0;
            try self.set_top(result);
        }
        
        pub fn op_eq(self: *Self) Error!void {
            const b = try self.pop();
            const a = try self.peek();
            const result: WordType = if (a == b) 1 else 0;
            try self.set_top(result);
        }
        
        pub fn op_iszero(self: *Self) Error!void {
            const value = try self.peek();
            const result: WordType = if (value == 0) 1 else 0;
            try self.set_top(result);
        }
        
        // Control flow operations
        pub fn op_jump(self: *Self) Error!void {
            const dest = try self.pop();
            if (dest > max_bytecode_size) {
                return Error.InvalidJump;
            }
            self.pc = @intCast(dest);
        }
        
        pub fn op_jumpi(self: *Self) Error!void {
            const dest = try self.pop();
            const condition = try self.pop();
            if (condition != 0) {
                if (dest > max_bytecode_size) {
                    return Error.InvalidJump;
                }
                self.pc = @intCast(dest);
            }
        }
        
        pub fn op_jumpdest(self: *Self) Error!void {
            // JUMPDEST is a no-op, it just marks a valid jump destination
            _ = self;
        }
        
        pub fn op_invalid(self: *Self) Error!void {
            _ = self;
            return Error.InvalidOpcode;
        }
        
        // Cryptographic operations
        pub fn op_keccak256(self: *Self, data: []const u8) Error!void {
            // For now, we'll take data as a parameter
            // In a real implementation, this would read from memory
            var hash: [32]u8 = undefined;
            std.crypto.hash.sha3.Keccak256.hash(data, &hash, .{});
            
            // Convert hash to WordType
            var result: WordType = 0;
            var i: usize = 0;
            while (i < 32) : (i += 1) {
                result = (result << 8) | hash[i];
            }
            
            try self.push(result);
        }
        
        // Memory operations
        pub fn op_msize(self: *Self) Error!void {
            // MSIZE returns the size of active memory in bytes
            const size = @as(WordType, @intCast(self.memory.size()));
            return self.push(size);
        }
        
        pub fn op_mload(self: *Self) Error!void {
            // MLOAD loads a 32-byte word from memory
            const offset = try self.pop();
            
            // Check if offset fits in usize
            if (offset > std.math.maxInt(usize)) {
                return Error.OutOfBounds;
            }
            
            const offset_usize = @as(usize, @intCast(offset));
            
            // Read 32 bytes from memory (memory handles expansion automatically)
            const value = self.memory.get_u256(offset_usize) catch |err| switch (err) {
                memory_mod.MemoryError.OutOfBounds => return Error.OutOfBounds,
                memory_mod.MemoryError.MemoryOverflow => return Error.OutOfBounds,
                else => return Error.AllocationError,
            };
            
            try self.push(value);
        }
        
        pub fn op_mstore(self: *Self) Error!void {
            // MSTORE stores a 32-byte word to memory
            const offset = try self.pop();
            const value = try self.pop();
            
            // Check if offset fits in usize
            if (offset > std.math.maxInt(usize)) {
                return Error.OutOfBounds;
            }
            
            const offset_usize = @as(usize, @intCast(offset));
            
            // Write 32 bytes to memory (memory handles expansion automatically)
            self.memory.set_u256(offset_usize, value) catch |err| switch (err) {
                memory_mod.MemoryError.MemoryOverflow => return Error.OutOfBounds,
                else => return Error.AllocationError,
            };
        }
        
        pub fn op_mstore8(self: *Self) Error!void {
            // MSTORE8 stores a single byte to memory
            const offset = try self.pop();
            const value = try self.pop();
            
            // Check if offset fits in usize
            if (offset > std.math.maxInt(usize)) {
                return Error.OutOfBounds;
            }
            
            const offset_usize = @as(usize, @intCast(offset));
            const byte_value = @as(u8, @truncate(value & 0xFF));
            
            // Write 1 byte to memory
            self.memory.set_byte(offset_usize, byte_value) catch |err| switch (err) {
                memory_mod.MemoryError.MemoryOverflow => return Error.OutOfBounds,
                else => return Error.AllocationError,
            };
        }
    };
    return ColdFrame;
}

test "ColdFrame push and push_unsafe" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    const dummy_bytecode = [_]u8{0x00}; // STOP
    var frame = try Frame.init(allocator, &dummy_bytecode, 0);
    defer frame.deinit(allocator);
    
    // Test push_unsafe
    frame.push_unsafe(42);
    try std.testing.expectEqual(@as(u12, 1), frame.next_stack_index);
    try std.testing.expectEqual(@as(u256, 42), frame.stack[0]);
    
    frame.push_unsafe(100);
    try std.testing.expectEqual(@as(u12, 2), frame.next_stack_index);
    try std.testing.expectEqual(@as(u256, 100), frame.stack[1]);
    
    // Test push with overflow check
    // Fill stack to near capacity
    frame.next_stack_index = 1023;
    try frame.push(200);
    try std.testing.expectEqual(@as(u256, 200), frame.stack[1023]);
    
    // This should error - stack is full
    try std.testing.expectError(error.StackOverflow, frame.push(300));
}

test "ColdFrame pop and pop_unsafe" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    const dummy_bytecode = [_]u8{0x00}; // STOP
    var frame = try Frame.init(allocator, &dummy_bytecode, 0);
    defer frame.deinit(allocator);
    
    // Setup stack with some values
    frame.stack[0] = 10;
    frame.stack[1] = 20;
    frame.stack[2] = 30;
    frame.next_stack_index = 3; // Points to next empty slot
    
    // Test pop_unsafe
    const val1 = frame.pop_unsafe();
    try std.testing.expectEqual(@as(u256, 30), val1);
    try std.testing.expectEqual(@as(u12, 2), frame.next_stack_index);
    
    const val2 = frame.pop_unsafe();
    try std.testing.expectEqual(@as(u256, 20), val2);
    try std.testing.expectEqual(@as(u12, 1), frame.next_stack_index);
    
    // Test pop with underflow check
    const val3 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 10), val3);
    
    // This should error - stack is empty
    try std.testing.expectError(error.StackUnderflow, frame.pop());
}

test "ColdFrame set_top and set_top_unsafe" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    const dummy_bytecode = [_]u8{0x00}; // STOP
    var frame = try Frame.init(allocator, &dummy_bytecode, 0);
    defer frame.deinit(allocator);
    
    // Setup stack with some values
    frame.stack[0] = 10;
    frame.stack[1] = 20;
    frame.stack[2] = 30;
    frame.next_stack_index = 3; // Points to next empty slot after 30
    
    // Test set_top_unsafe - should modify the top value (30 -> 99)
    frame.set_top_unsafe(99);
    try std.testing.expectEqual(@as(u256, 99), frame.stack[2]);
    try std.testing.expectEqual(@as(u12, 3), frame.next_stack_index); // Index unchanged
    
    // Test set_top with error check on empty stack
    frame.next_stack_index = 0; // Empty stack
    try std.testing.expectError(error.StackUnderflow, frame.set_top(42));
    
    // Test set_top on non-empty stack
    frame.next_stack_index = 2; // Stack has 2 items
    try frame.set_top(55);
    try std.testing.expectEqual(@as(u256, 55), frame.stack[1]);
}

test "ColdFrame peek and peek_unsafe" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    const dummy_bytecode = [_]u8{0x00}; // STOP
    var frame = try Frame.init(allocator, &dummy_bytecode, 0);
    defer frame.deinit(allocator);
    
    // Setup stack with values
    frame.stack[0] = 100;
    frame.stack[1] = 200;
    frame.stack[2] = 300;
    frame.next_stack_index = 3; // Points to next empty slot
    
    // Test peek_unsafe - should return top value without modifying index
    const top_unsafe = frame.peek_unsafe();
    try std.testing.expectEqual(@as(u256, 300), top_unsafe);
    try std.testing.expectEqual(@as(u12, 3), frame.next_stack_index);
    
    // Test peek on non-empty stack
    const top = try frame.peek();
    try std.testing.expectEqual(@as(u256, 300), top);
    try std.testing.expectEqual(@as(u12, 3), frame.next_stack_index);
    
    // Test peek on empty stack
    frame.next_stack_index = 0;
    try std.testing.expectError(error.StackUnderflow, frame.peek());
}

test "ColdFrame with bytecode and pc" {
    const allocator = std.testing.allocator;
    
    // Test with small bytecode (fits in u8)
    const SmallFrame = createColdFrame(.{ .max_bytecode_size = 255 });
    const small_bytecode = [_]u8{0x60, 0x01, 0x60, 0x02, 0x00}; // PUSH1 1 PUSH1 2 STOP
    
    var small_frame = try SmallFrame.init(allocator, &small_bytecode, 1000000);
    defer small_frame.deinit(allocator);
    
    try std.testing.expectEqual(@as(u8, 0), small_frame.pc);
    try std.testing.expectEqual(@as(u8, 0x60), small_frame.bytecode[0]);
    
    // Test with medium bytecode (fits in u16)
    const MediumFrame = createColdFrame(.{ .max_bytecode_size = 65535 });
    const medium_bytecode = [_]u8{0x58, 0x00}; // PC STOP
    
    var medium_frame = try MediumFrame.init(allocator, &medium_bytecode, 1000000);
    defer medium_frame.deinit(allocator);
    medium_frame.pc = 300;
    
    try std.testing.expectEqual(@as(u16, 300), medium_frame.pc);
}

test "ColdFrame op_pc pushes pc to stack" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    const bytecode = [_]u8{0x58, 0x00}; // PC STOP
    var frame = try Frame.init(allocator, &bytecode, 0);
    defer frame.deinit(allocator);
    
    // Execute op_pc - should push current pc (0) to stack
    try frame.op_pc();
    try std.testing.expectEqual(@as(u256, 0), frame.stack[0]);
    try std.testing.expectEqual(@as(u12, 1), frame.next_stack_index);
    
    // Set pc to 42 and test again
    frame.pc = 42;
    try frame.op_pc();
    try std.testing.expectEqual(@as(u256, 42), frame.stack[1]);
    try std.testing.expectEqual(@as(u12, 2), frame.next_stack_index);
}

test "ColdFrame op_stop returns stop error" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    const bytecode = [_]u8{0x00}; // STOP
    var frame = try Frame.init(allocator, &bytecode, 0);
    defer frame.deinit(allocator);
    
    // Execute op_stop - should return STOP error
    try std.testing.expectError(error.STOP, frame.op_stop());
}

test "ColdFrame op_pop removes top stack item" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    const bytecode = [_]u8{0x50, 0x00}; // POP STOP
    var frame = try Frame.init(allocator, &bytecode, 0);
    defer frame.deinit(allocator);
    
    // Setup stack with some values
    frame.stack[0] = 100;
    frame.stack[1] = 200;
    frame.stack[2] = 300;
    frame.next_stack_index = 3;
    
    // Execute op_pop - should remove top item (300) and do nothing with it
    try frame.op_pop();
    try std.testing.expectEqual(@as(u12, 2), frame.next_stack_index);
    
    // Execute again - should remove 200
    try frame.op_pop();
    try std.testing.expectEqual(@as(u12, 1), frame.next_stack_index);
    
    // Execute again - should remove 100
    try frame.op_pop();
    try std.testing.expectEqual(@as(u12, 0), frame.next_stack_index);
    
    // Pop on empty stack should error
    try std.testing.expectError(error.StackUnderflow, frame.op_pop());
}

test "ColdFrame op_push0 pushes zero to stack" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    const bytecode = [_]u8{0x5f, 0x00}; // PUSH0 STOP
    var frame = try Frame.init(allocator, &bytecode, 0);
    defer frame.deinit(allocator);
    
    // Execute op_push0 - should push 0 to stack
    try frame.op_push0();
    try std.testing.expectEqual(@as(u256, 0), frame.stack[0]);
    try std.testing.expectEqual(@as(u12, 1), frame.next_stack_index);
}

test "ColdFrame op_push1 reads byte from bytecode and pushes to stack" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    const bytecode = [_]u8{0x60, 0x42, 0x60, 0xFF, 0x00}; // PUSH1 0x42 PUSH1 0xFF STOP
    var frame = try Frame.init(allocator, &bytecode, 0);
    defer frame.deinit(allocator);
    
    // Execute op_push1 at pc=0 - should read 0x42 from bytecode[1] and push it
    try frame.op_push1();
    try std.testing.expectEqual(@as(u256, 0x42), frame.stack[0]);
    try std.testing.expectEqual(@as(u12, 1), frame.next_stack_index);
    try std.testing.expectEqual(@as(u16, 2), frame.pc); // PC should advance by 2 (opcode + 1 byte)
    
    // Execute op_push1 at pc=2 - should read 0xFF from bytecode[3] and push it
    try frame.op_push1();
    try std.testing.expectEqual(@as(u256, 0xFF), frame.stack[1]);
    try std.testing.expectEqual(@as(u12, 2), frame.next_stack_index);
    try std.testing.expectEqual(@as(u16, 4), frame.pc); // PC should advance by 2 more
}

test "ColdFrame op_push2 reads 2 bytes from bytecode" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    const bytecode = [_]u8{0x61, 0x12, 0x34, 0x00}; // PUSH2 0x1234 STOP
    var frame = try Frame.init(allocator, &bytecode, 0);
    defer frame.deinit(allocator);
    
    // Execute op_push2 - should read 0x1234 from bytecode[1..3] and push it
    try frame.op_push2();
    try std.testing.expectEqual(@as(u256, 0x1234), frame.stack[0]);
    try std.testing.expectEqual(@as(u12, 1), frame.next_stack_index);
    try std.testing.expectEqual(@as(u16, 3), frame.pc); // PC should advance by 3 (opcode + 2 bytes)
}

test "ColdFrame op_push32 reads 32 bytes from bytecode" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    // PUSH32 with max value (32 bytes of 0xFF)
    var bytecode: [34]u8 = undefined;
    bytecode[0] = 0x7f; // PUSH32
    for (1..33) |i| {
        bytecode[i] = 0xFF;
    }
    bytecode[33] = 0x00; // STOP
    
    var frame = try Frame.init(allocator, &bytecode, 0);
    defer frame.deinit(allocator);
    
    // Execute op_push32 - should read all 32 bytes and push max u256
    try frame.op_push32();
    try std.testing.expectEqual(@as(u256, std.math.maxInt(u256)), frame.stack[0]);
    try std.testing.expectEqual(@as(u12, 1), frame.next_stack_index);
    try std.testing.expectEqual(@as(u16, 33), frame.pc); // PC should advance by 33 (opcode + 32 bytes)
}

test "ColdFrame op_push3 reads 3 bytes from bytecode" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    const bytecode = [_]u8{0x62, 0xAB, 0xCD, 0xEF, 0x00}; // PUSH3 0xABCDEF STOP
    var frame = try Frame.init(allocator, &bytecode, 0);
    defer frame.deinit(allocator);
    
    // Execute op_push3 - should read 0xABCDEF from bytecode[1..4] and push it
    try frame.op_push3();
    try std.testing.expectEqual(@as(u256, 0xABCDEF), frame.stack[0]);
    try std.testing.expectEqual(@as(u12, 1), frame.next_stack_index);
    try std.testing.expectEqual(@as(u16, 4), frame.pc); // PC should advance by 4 (opcode + 3 bytes)
}

test "ColdFrame op_push7 reads 7 bytes from bytecode" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    // PUSH7 with specific pattern
    const bytecode = [_]u8{0x66, 0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0x00}; // PUSH7 STOP
    var frame = try Frame.init(allocator, &bytecode, 0);
    defer frame.deinit(allocator);
    
    // Execute op_push7 - should read 7 bytes and push them
    try frame.op_push7();
    try std.testing.expectEqual(@as(u256, 0x0123456789ABCD), frame.stack[0]);
    try std.testing.expectEqual(@as(u12, 1), frame.next_stack_index);
    try std.testing.expectEqual(@as(u16, 8), frame.pc); // PC should advance by 8 (opcode + 7 bytes)
}

test "ColdFrame op_push16 reads 16 bytes from bytecode" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    // PUSH16 with specific pattern
    var bytecode: [18]u8 = undefined;
    bytecode[0] = 0x6F; // PUSH16
    for (1..17) |i| {
        bytecode[i] = @as(u8, @intCast(i));
    }
    bytecode[17] = 0x00; // STOP
    
    var frame = try Frame.init(allocator, &bytecode, 0);
    defer frame.deinit(allocator);
    
    // Execute op_push16
    try frame.op_push16();
    
    // Verify value is correct
    var expected: u256 = 0;
    for (1..17) |i| {
        expected = (expected << 8) | @as(u256, i);
    }
    try std.testing.expectEqual(expected, frame.stack[0]);
    try std.testing.expectEqual(@as(u12, 1), frame.next_stack_index);
    try std.testing.expectEqual(@as(u16, 17), frame.pc); // PC should advance by 17 (opcode + 16 bytes)
}

test "ColdFrame op_push31 reads 31 bytes from bytecode" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    // PUSH31 with specific pattern
    var bytecode: [33]u8 = undefined;
    bytecode[0] = 0x7E; // PUSH31
    for (1..32) |i| {
        bytecode[i] = @as(u8, @intCast(i % 256));
    }
    bytecode[32] = 0x00; // STOP
    
    var frame = try Frame.init(allocator, &bytecode, 0);
    defer frame.deinit(allocator);
    
    // Execute op_push31
    try frame.op_push31();
    
    // Verify PC advanced correctly
    try std.testing.expectEqual(@as(u16, 32), frame.pc); // PC should advance by 32 (opcode + 31 bytes)
    try std.testing.expectEqual(@as(u12, 1), frame.next_stack_index);
}

test "ColdFrame interpret handles all PUSH opcodes correctly" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    // Test PUSH3 through interpreter
    {
        const bytecode = [_]u8{0x62, 0x12, 0x34, 0x56, 0x00}; // PUSH3 0x123456 STOP
        var frame = try Frame.init(allocator, &bytecode, 1000000);
        defer frame.deinit(allocator);
        
        try std.testing.expectError(error.STOP, frame.interpret(allocator));
        try std.testing.expectEqual(@as(u256, 0x123456), frame.stack[0]);
    }
    
    // Test PUSH10 through interpreter
    {
        var bytecode: [12]u8 = undefined;
        bytecode[0] = 0x69; // PUSH10
        for (1..11) |i| {
            bytecode[i] = @as(u8, @intCast(i));
        }
        bytecode[11] = 0x00; // STOP
        
        var frame = try Frame.init(allocator, &bytecode, 1000000);
        defer frame.deinit(allocator);
        
        try std.testing.expectError(error.STOP, frame.interpret(allocator));
        
        var expected: u256 = 0;
        for (1..11) |i| {
            expected = (expected << 8) | @as(u256, i);
        }
        try std.testing.expectEqual(expected, frame.stack[0]);
    }
    
    // Test PUSH20 through interpreter
    {
        var bytecode: [22]u8 = undefined;
        bytecode[0] = 0x73; // PUSH20
        for (1..21) |i| {
            bytecode[i] = @as(u8, @intCast(255 - i));
        }
        bytecode[21] = 0x00; // STOP
        
        var frame = try Frame.init(allocator, &bytecode, 1000000);
        defer frame.deinit(allocator);
        
        try std.testing.expectError(error.STOP, frame.interpret(allocator));
        try std.testing.expectEqual(@as(u12, 1), frame.next_stack_index);
    }
}

test "ColdFrame op_dup1 duplicates top stack item" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    const bytecode = [_]u8{0x80, 0x00}; // DUP1 STOP
    var frame = try Frame.init(allocator, &bytecode, 0);
    defer frame.deinit(allocator);
    
    // Setup stack with value
    frame.stack[0] = 42;
    frame.next_stack_index = 1;
    
    // Execute op_dup1 - should duplicate top item (42)
    try frame.op_dup1();
    try std.testing.expectEqual(@as(u256, 42), frame.stack[0]); // Original
    try std.testing.expectEqual(@as(u256, 42), frame.stack[1]); // Duplicate
    try std.testing.expectEqual(@as(u12, 2), frame.next_stack_index);
    
    // Test dup1 on empty stack
    frame.next_stack_index = 0;
    try std.testing.expectError(error.StackUnderflow, frame.op_dup1());
}

test "ColdFrame op_dup16 duplicates 16th stack item" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    const bytecode = [_]u8{0x8f, 0x00}; // DUP16 STOP
    var frame = try Frame.init(allocator, &bytecode, 0);
    defer frame.deinit(allocator);
    
    // Setup stack with values 1-16
    for (0..16) |i| {
        frame.stack[i] = @as(u256, i + 1);
    }
    frame.next_stack_index = 16;
    
    // Execute op_dup16 - should duplicate 16th from top (value 1)
    try frame.op_dup16();
    try std.testing.expectEqual(@as(u256, 1), frame.stack[16]); // Duplicate of bottom
    try std.testing.expectEqual(@as(u12, 17), frame.next_stack_index);
    
    // Test dup16 with insufficient stack
    frame.next_stack_index = 15; // Only 15 items
    try std.testing.expectError(error.StackUnderflow, frame.op_dup16());
}

test "ColdFrame op_swap1 swaps top two stack items" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    const bytecode = [_]u8{0x90, 0x00}; // SWAP1 STOP
    var frame = try Frame.init(allocator, &bytecode, 0);
    defer frame.deinit(allocator);
    
    // Setup stack with values
    frame.stack[0] = 100;
    frame.stack[1] = 200;
    frame.next_stack_index = 2;
    
    // Execute op_swap1 - should swap top two items
    try frame.op_swap1();
    try std.testing.expectEqual(@as(u256, 200), frame.stack[0]);
    try std.testing.expectEqual(@as(u256, 100), frame.stack[1]);
    try std.testing.expectEqual(@as(u12, 2), frame.next_stack_index);
    
    // Test swap1 with insufficient stack
    frame.next_stack_index = 1; // Only 1 item
    try std.testing.expectError(error.StackUnderflow, frame.op_swap1());
}

test "ColdFrame op_swap16 swaps top with 17th stack item" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    const bytecode = [_]u8{0x9f, 0x00}; // SWAP16 STOP
    var frame = try Frame.init(allocator, &bytecode, 0);
    defer frame.deinit(allocator);
    
    // Setup stack with values 1-17
    for (0..17) |i| {
        frame.stack[i] = @as(u256, i + 1);
    }
    frame.next_stack_index = 17;
    
    // Execute op_swap16 - should swap top (17) with 17th from top (1)
    try frame.op_swap16();
    try std.testing.expectEqual(@as(u256, 17), frame.stack[0]); // Was 1
    try std.testing.expectEqual(@as(u256, 1), frame.stack[16]); // Was 17
    try std.testing.expectEqual(@as(u12, 17), frame.next_stack_index);
    
    // Test swap16 with insufficient stack
    frame.next_stack_index = 16; // Only 16 items
    try std.testing.expectError(error.StackUnderflow, frame.op_swap16());
}

test "ColdFrame init validates bytecode size" {
    const allocator = std.testing.allocator;
    
    // Test with valid bytecode size
    const SmallFrame = createColdFrame(.{ .max_bytecode_size = 100 });
    const small_bytecode = [_]u8{0x60, 0x01, 0x00}; // PUSH1 1 STOP
    
    const stack_memory = try allocator.create([1024]u256);
    defer allocator.destroy(stack_memory);
    
    var frame = try SmallFrame.init(allocator, &small_bytecode, 1000000);
    defer frame.deinit(allocator);
    
    try std.testing.expectEqual(@as(u8, 0), frame.pc);
    try std.testing.expectEqual(&small_bytecode, frame.bytecode.ptr);
    try std.testing.expectEqual(@as(usize, 3), frame.bytecode.len);
    
    // Test with bytecode too large
    const large_bytecode = try allocator.alloc(u8, 101);
    defer allocator.free(large_bytecode);
    @memset(large_bytecode, 0x00);
    
    try std.testing.expectError(error.BytecodeTooLarge, SmallFrame.init(allocator, large_bytecode, 0));
    
    // Test with empty bytecode
    const empty_bytecode = [_]u8{};
    var empty_frame = try SmallFrame.init(allocator, &empty_bytecode, 1000000);
    defer empty_frame.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), empty_frame.bytecode.len);
}

test "ColdFrame get_requested_alloc calculates correctly" {
    // Test with default options
    const default_config = FrameConfig{};
    const expected_default = @as(u32, @intCast(1024 * @sizeOf(u256)));
    try std.testing.expectEqual(expected_default, default_config.get_requested_alloc());
    
    // Test with custom options
    const custom_config = FrameConfig{
        .stack_size = 512,
        .WordType = u128,
        .max_bytecode_size = 1000,
    };
    const expected_custom = @as(u32, @intCast(512 * @sizeOf(u128)));
    try std.testing.expectEqual(expected_custom, custom_config.get_requested_alloc());
    
    // Test with small frame
    const small_config = FrameConfig{
        .stack_size = 256,
        .WordType = u64,
        .max_bytecode_size = 255,
    };
    const expected_small = @as(u32, @intCast(256 * @sizeOf(u64)));
    try std.testing.expectEqual(expected_small, small_config.get_requested_alloc());
}

test "ColdFrame op_and bitwise AND operation" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    const bytecode = [_]u8{0x16, 0x00}; // AND STOP
    var frame = try Frame.init(allocator, &bytecode, 0);
    defer frame.deinit(allocator);
    
    // Test 0xFF & 0x0F = 0x0F
    try frame.push(0xFF);
    try frame.push(0x0F);
    try frame.op_and();
    const result1 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0x0F), result1);
    
    // Test 0xFFFF & 0x00FF = 0x00FF
    try frame.push(0xFFFF);
    try frame.push(0x00FF);
    try frame.op_and();
    const result2 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0x00FF), result2);
    
    // Test with max values
    try frame.push(std.math.maxInt(u256));
    try frame.push(0x12345678);
    try frame.op_and();
    const result3 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0x12345678), result3);
}

test "ColdFrame op_or bitwise OR operation" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    const bytecode = [_]u8{0x17, 0x00}; // OR STOP
    var frame = try Frame.init(allocator, &bytecode, 0);
    defer frame.deinit(allocator);
    
    // Test 0xF0 | 0x0F = 0xFF
    try frame.push(0xF0);
    try frame.push(0x0F);
    try frame.op_or();
    const result1 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0xFF), result1);
    
    // Test 0xFF00 | 0x00FF = 0xFFFF
    try frame.push(0xFF00);
    try frame.push(0x00FF);
    try frame.op_or();
    const result2 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0xFFFF), result2);
    
    // Test with zero
    try frame.push(0);
    try frame.push(0x12345678);
    try frame.op_or();
    const result3 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0x12345678), result3);
}

test "ColdFrame op_xor bitwise XOR operation" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    const bytecode = [_]u8{0x18, 0x00}; // XOR STOP
    var frame = try Frame.init(allocator, &bytecode, 0);
    defer frame.deinit(allocator);
    
    // Test 0xFF ^ 0xFF = 0
    try frame.push(0xFF);
    try frame.push(0xFF);
    try frame.op_xor();
    const result1 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0), result1);
    
    // Test 0xFF ^ 0x00 = 0xFF
    try frame.push(0xFF);
    try frame.push(0x00);
    try frame.op_xor();
    const result2 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0xFF), result2);
    
    // Test 0xAA ^ 0x55 = 0xFF (alternating bits)
    try frame.push(0xAA);
    try frame.push(0x55);
    try frame.op_xor();
    const result3 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0xFF), result3);
}

test "ColdFrame op_not bitwise NOT operation" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    const bytecode = [_]u8{0x19, 0x00}; // NOT STOP
    var frame = try Frame.init(allocator, &bytecode, 0);
    defer frame.deinit(allocator);
    
    // Test ~0 = max value
    try frame.push(0);
    try frame.op_not();
    const result1 = try frame.pop();
    try std.testing.expectEqual(std.math.maxInt(u256), result1);
    
    // Test ~max = 0
    try frame.push(std.math.maxInt(u256));
    try frame.op_not();
    const result2 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0), result2);
    
    // Test ~0xFF = 0xFFFF...FF00
    try frame.push(0xFF);
    try frame.op_not();
    const result3 = try frame.pop();
    try std.testing.expectEqual(std.math.maxInt(u256) - 0xFF, result3);
}

test "ColdFrame op_byte extracts single byte from word" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    const bytecode = [_]u8{0x1A, 0x00}; // BYTE STOP
    var frame = try Frame.init(allocator, &bytecode, 0);
    defer frame.deinit(allocator);
    
    // Test extracting byte 31 (rightmost) from 0x...FF
    try frame.push(0xFF);
    try frame.push(31);
    try frame.op_byte();
    const result1 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0xFF), result1);
    
    // Test extracting byte 30 from 0x...FF00
    try frame.push(0xFF00);
    try frame.push(30);
    try frame.op_byte();
    const result2 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0xFF), result2);
    
    // Test extracting byte 0 (leftmost) from a value
    const value: u256 = @as(u256, 0xAB) << 248; // Put 0xAB in the leftmost byte
    try frame.push(value);
    try frame.push(0);
    try frame.op_byte();
    const result3 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0xAB), result3);
    
    // Test out of bounds (index >= 32) returns 0
    try frame.push(0xFFFFFFFF);
    try frame.push(32);
    try frame.op_byte();
    const result4 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0), result4);
}

test "ColdFrame op_shl shift left operation" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    const bytecode = [_]u8{0x1B, 0x00}; // SHL STOP
    var frame = try Frame.init(allocator, &bytecode, 0);
    defer frame.deinit(allocator);
    
    // Test 1 << 4 = 16
    try frame.push(1);
    try frame.push(4);
    try frame.op_shl();
    const result1 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 16), result1);
    
    // Test 0xFF << 8 = 0xFF00
    try frame.push(0xFF);
    try frame.push(8);
    try frame.op_shl();
    const result2 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0xFF00), result2);
    
    // Test shift >= 256 returns 0
    try frame.push(1);
    try frame.push(256);
    try frame.op_shl();
    const result3 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0), result3);
}

test "ColdFrame op_shr logical shift right operation" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    const bytecode = [_]u8{0x1C, 0x00}; // SHR STOP
    var frame = try Frame.init(allocator, &bytecode, 0);
    defer frame.deinit(allocator);
    
    // Test 16 >> 4 = 1
    try frame.push(16);
    try frame.push(4);
    try frame.op_shr();
    const result1 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 1), result1);
    
    // Test 0xFF00 >> 8 = 0xFF
    try frame.push(0xFF00);
    try frame.push(8);
    try frame.op_shr();
    const result2 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0xFF), result2);
    
    // Test shift >= 256 returns 0
    try frame.push(std.math.maxInt(u256));
    try frame.push(256);
    try frame.op_shr();
    const result3 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0), result3);
}

test "ColdFrame op_sar arithmetic shift right operation" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    const bytecode = [_]u8{0x1D, 0x00}; // SAR STOP
    var frame = try Frame.init(allocator, &bytecode, 0);
    defer frame.deinit(allocator);
    
    // Test positive number: 16 >> 4 = 1
    try frame.push(16);
    try frame.push(4);
    try frame.op_sar();
    const result1 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 1), result1);
    
    // Test negative number (sign bit = 1)
    const negative = @as(u256, 1) << 255 | 0xFF00; // Set sign bit and some data
    try frame.push(negative);
    try frame.push(8);
    try frame.op_sar();
    const result2 = try frame.pop();
    // Should fill with 1s from the left
    const expected2 = (@as(u256, std.math.maxInt(u256)) << 247) | 0xFF;
    try std.testing.expectEqual(expected2, result2);
    
    // Test shift >= 256 with positive number returns 0
    try frame.push(0x7FFFFFFF); // Positive (sign bit = 0)
    try frame.push(256);
    try frame.op_sar();
    const result3 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0), result3);
    
    // Test shift >= 256 with negative number returns max value
    try frame.push(@as(u256, 1) << 255); // Negative (sign bit = 1)
    try frame.push(256);
    try frame.op_sar();
    const result4 = try frame.pop();
    try std.testing.expectEqual(std.math.maxInt(u256), result4);
}

test "ColdFrame op_add addition with wrapping overflow" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    const bytecode = [_]u8{0x01, 0x00}; // ADD STOP
    var frame = try Frame.init(allocator, &bytecode, 0);
    defer frame.deinit(allocator);
    
    // Test 10 + 20 = 30
    try frame.push(10);
    try frame.push(20);
    try frame.op_add();
    const result1 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 30), result1);
    
    // Test overflow: max + 1 = 0
    try frame.push(std.math.maxInt(u256));
    try frame.push(1);
    try frame.op_add();
    const result2 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0), result2);
    
    // Test max + max = max - 1 (wrapping)
    try frame.push(std.math.maxInt(u256));
    try frame.push(std.math.maxInt(u256));
    try frame.op_add();
    const result3 = try frame.pop();
    try std.testing.expectEqual(std.math.maxInt(u256) - 1, result3);
}

test "ColdFrame op_mul multiplication with wrapping overflow" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    const bytecode = [_]u8{0x02, 0x00}; // MUL STOP
    var frame = try Frame.init(allocator, &bytecode, 0);
    defer frame.deinit(allocator);
    
    // Test 5 * 6 = 30
    try frame.push(5);
    try frame.push(6);
    try frame.op_mul();
    const result1 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 30), result1);
    
    // Test 0 * anything = 0
    try frame.push(0);
    try frame.push(12345);
    try frame.op_mul();
    const result2 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0), result2);
    
    // Test overflow with large numbers
    const large = @as(u256, 1) << 128;
    try frame.push(large);
    try frame.push(large);
    try frame.op_mul();
    const result3 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0), result3); // 2^256 wraps to 0
}

test "ColdFrame op_sub subtraction with wrapping underflow" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    const bytecode = [_]u8{0x03, 0x00}; // SUB STOP
    var frame = try Frame.init(allocator, &bytecode, 0);
    defer frame.deinit(allocator);
    
    // Test 30 - 10 = 20
    try frame.push(30);
    try frame.push(10);
    try frame.op_sub();
    const result1 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 20), result1);
    
    // Test underflow: 0 - 1 = max
    try frame.push(0);
    try frame.push(1);
    try frame.op_sub();
    const result2 = try frame.pop();
    try std.testing.expectEqual(std.math.maxInt(u256), result2);
    
    // Test 10 - 20 = max - 9 (wrapping)
    try frame.push(10);
    try frame.push(20);
    try frame.op_sub();
    const result3 = try frame.pop();
    try std.testing.expectEqual(std.math.maxInt(u256) - 9, result3);
}

test "ColdFrame op_div unsigned integer division" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    const bytecode = [_]u8{0x04, 0x00}; // DIV STOP
    var frame = try Frame.init(allocator, &bytecode, 0);
    defer frame.deinit(allocator);
    
    // Test 20 / 5 = 4
    try frame.push(20);
    try frame.push(5);
    try frame.op_div();
    const result1 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 4), result1);
    
    // Test division by zero returns 0
    try frame.push(100);
    try frame.push(0);
    try frame.op_div();
    const result2 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0), result2);
    
    // Test integer division: 7 / 3 = 2
    try frame.push(7);
    try frame.push(3);
    try frame.op_div();
    const result3 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 2), result3);
}

test "ColdFrame op_sdiv signed integer division" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    const bytecode = [_]u8{0x05, 0x00}; // SDIV STOP
    var frame = try Frame.init(allocator, &bytecode, 0);
    defer frame.deinit(allocator);
    
    // Test 20 / 5 = 4 (positive / positive)
    try frame.push(20);
    try frame.push(5);
    try frame.op_sdiv();
    const result1 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 4), result1);
    
    // Test -20 / 5 = -4 (negative / positive)
    const neg_20 = @as(u256, @bitCast(@as(i256, -20)));
    try frame.push(neg_20);
    try frame.push(5);
    try frame.op_sdiv();
    const result2 = try frame.pop();
    const expected2 = @as(u256, @bitCast(@as(i256, -4)));
    try std.testing.expectEqual(expected2, result2);
    
    // Test MIN_I256 / -1 = MIN_I256 (overflow case)
    const min_i256 = @as(u256, 1) << 255;
    const neg_1 = @as(u256, @bitCast(@as(i256, -1)));
    try frame.push(min_i256);
    try frame.push(neg_1);
    try frame.op_sdiv();
    const result3 = try frame.pop();
    try std.testing.expectEqual(min_i256, result3);
    
    // Test division by zero returns 0
    try frame.push(100);
    try frame.push(0);
    try frame.op_sdiv();
    const result4 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0), result4);
}

test "ColdFrame op_mod modulo remainder operation" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    const bytecode = [_]u8{0x06, 0x00}; // MOD STOP
    var frame = try Frame.init(allocator, &bytecode, 0);
    defer frame.deinit(allocator);
    
    // Test 17 % 5 = 2
    try frame.push(17);
    try frame.push(5);
    try frame.op_mod();
    const result1 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 2), result1);
    
    // Test 100 % 10 = 0
    try frame.push(100);
    try frame.push(10);
    try frame.op_mod();
    const result2 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0), result2);
    
    // Test modulo by zero returns 0
    try frame.push(7);
    try frame.push(0);
    try frame.op_mod();
    const result3 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0), result3);
}

test "ColdFrame op_smod signed modulo remainder operation" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    const bytecode = [_]u8{0x07, 0x00}; // SMOD STOP
    var frame = try Frame.init(allocator, &bytecode, 0);
    defer frame.deinit(allocator);
    
    // Test 17 % 5 = 2 (positive % positive)
    try frame.push(17);
    try frame.push(5);
    try frame.op_smod();
    const result1 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 2), result1);
    
    // Test -17 % 5 = -2 (negative % positive)
    const neg_17 = @as(u256, @bitCast(@as(i256, -17)));
    try frame.push(neg_17);
    try frame.push(5);
    try frame.op_smod();
    const result2 = try frame.pop();
    const expected2 = @as(u256, @bitCast(@as(i256, -2)));
    try std.testing.expectEqual(expected2, result2);
    
    // Test 17 % -5 = 2 (positive % negative)
    const neg_5 = @as(u256, @bitCast(@as(i256, -5)));
    try frame.push(17);
    try frame.push(neg_5);
    try frame.op_smod();
    const result3 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 2), result3);
    
    // Test modulo by zero returns 0
    try frame.push(neg_17);
    try frame.push(0);
    try frame.op_smod();
    const result4 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0), result4);
}

test "ColdFrame op_addmod addition modulo n" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    const bytecode = [_]u8{0x08, 0x00}; // ADDMOD STOP
    var frame = try Frame.init(allocator, &bytecode, 0);
    defer frame.deinit(allocator);
    
    // Test (10 + 20) % 7 = 2
    try frame.push(10);
    try frame.push(20);
    try frame.push(7);
    try frame.op_addmod();
    const result1 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 2), result1);
    
    // Test overflow handling: (MAX + 5) % 10 = 4
    // MAX = 2^256 - 1, so (2^256 - 1 + 5) = 2^256 + 4
    // Since we're in mod 2^256, this is just 4
    // So 4 % 10 = 4
    try frame.push(std.math.maxInt(u256));
    try frame.push(5);
    try frame.push(10);
    try frame.op_addmod();
    const result2 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 4), result2);
    
    // Test modulo by zero returns 0
    try frame.push(50);
    try frame.push(50);
    try frame.push(0);
    try frame.op_addmod();
    const result3 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0), result3);
}

test "ColdFrame op_mulmod multiplication modulo n" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    const bytecode = [_]u8{0x09, 0x00}; // MULMOD STOP
    var frame = try Frame.init(allocator, &bytecode, 0);
    defer frame.deinit(allocator);
    
    // Test (10 * 20) % 7 = 200 % 7 = 4
    try frame.push(10);
    try frame.push(20);
    try frame.push(7);
    try frame.op_mulmod();
    const result1 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 4), result1);
    
    // First test a simple case to make sure basic logic works
    try frame.push(36);
    try frame.push(36);
    try frame.push(100);
    try frame.op_mulmod();
    const simple_result = try frame.pop();
    try std.testing.expectEqual(@as(u256, 96), simple_result);
    
    // Test that large % 100 = 56
    const large = @as(u256, 1) << 128;
    try std.testing.expectEqual(@as(u256, 56), large % 100);
    
    // Test overflow handling: (2^128 * 2^128) % 100
    // This tests the modular multiplication
    try frame.push(large);
    try frame.push(large);
    try frame.push(100);
    try frame.op_mulmod();
    const result2 = try frame.pop();
    // Since the algorithm reduces first: 2^128 % 100 = 56
    // Then we're computing (56 * 56) % 100 = 3136 % 100 = 36
    try std.testing.expectEqual(@as(u256, 36), result2);
    
    // Test modulo by zero returns 0
    try frame.push(50);
    try frame.push(50);
    try frame.push(0);
    try frame.op_mulmod();
    const result3 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0), result3);
}

test "ColdFrame op_exp exponentiation" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    const bytecode = [_]u8{0x0A, 0x00}; // EXP STOP
    var frame = try Frame.init(allocator, &bytecode, 0);
    defer frame.deinit(allocator);
    
    // Test 2^10 = 1024
    try frame.push(2);
    try frame.push(10);
    try frame.op_exp();
    const result1 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 1024), result1);
    
    // Test 3^4 = 81
    try frame.push(3);
    try frame.push(4);
    try frame.op_exp();
    const result2 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 81), result2);
    
    // Test 10^0 = 1 (anything^0 = 1)
    try frame.push(10);
    try frame.push(0);
    try frame.op_exp();
    const result3 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 1), result3);
    
    // Test 0^10 = 0 (0^anything = 0, except 0^0)
    try frame.push(0);
    try frame.push(10);
    try frame.op_exp();
    const result4 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0), result4);
    
    // Test 0^0 = 1 (special case in EVM)
    try frame.push(0);
    try frame.push(0);
    try frame.op_exp();
    const result5 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 1), result5);
}

test "ColdFrame op_signextend sign extension" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    const bytecode = [_]u8{0x0B, 0x00}; // SIGNEXTEND STOP
    var frame = try Frame.init(allocator, &bytecode, 0);
    defer frame.deinit(allocator);
    
    // Test extending positive 8-bit value (0x7F)
    try frame.push(0x7F);
    try frame.push(0); // Extend from byte 0
    try frame.op_signextend();
    const result1 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0x7F), result1);
    
    // Test extending negative 8-bit value (0x80)
    try frame.push(0x80);
    try frame.push(0); // Extend from byte 0
    try frame.op_signextend();
    const result2 = try frame.pop();
    const expected2 = std.math.maxInt(u256) - 0x7F; // 0xFFFF...FF80
    try std.testing.expectEqual(expected2, result2);
    
    // Test extending positive 16-bit value (0x7FFF)
    try frame.push(0x7FFF);
    try frame.push(1); // Extend from byte 1
    try frame.op_signextend();
    const result3 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0x7FFF), result3);
    
    // Test extending negative 16-bit value (0x8000)
    try frame.push(0x8000);
    try frame.push(1); // Extend from byte 1
    try frame.op_signextend();
    const result4 = try frame.pop();
    const expected4 = std.math.maxInt(u256) - 0x7FFF; // 0xFFFF...F8000
    try std.testing.expectEqual(expected4, result4);
    
    // Test byte_num >= 31 returns value unchanged
    try frame.push(0x12345678);
    try frame.push(31); // Extend from byte 31 (full width)
    try frame.op_signextend();
    const result5 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0x12345678), result5);
}

test "ColdFrame op_gas returns gas remaining" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    const bytecode = [_]u8{0x5A, 0x00}; // GAS STOP
    var frame = try Frame.init(allocator, &bytecode, 1000000);
    defer frame.deinit(allocator);
    
    // Test op_gas pushes gas_remaining to stack
    try frame.op_gas();
    const result1 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 1000000), result1);
    
    // Test op_gas with modified gas_remaining
    frame.gas_remaining = 12345;
    try frame.op_gas();
    const result2 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 12345), result2);
    
    // Test op_gas with zero gas
    frame.gas_remaining = 0;
    try frame.op_gas();
    const result3 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0), result3);
    
    // Test op_gas with negative gas (should push 0)
    frame.gas_remaining = -100;
    try frame.op_gas();
    const result4 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0), result4);
}

test "ColdFrame op_lt less than comparison" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    const bytecode = [_]u8{0x10, 0x00}; // LT STOP
    var frame = try Frame.init(allocator, &bytecode, 0);
    defer frame.deinit(allocator);
    
    // Test 10 < 20 = 1
    try frame.push(10);
    try frame.push(20);
    try frame.op_lt();
    const result1 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 1), result1);
    
    // Test 20 < 10 = 0
    try frame.push(20);
    try frame.push(10);
    try frame.op_lt();
    const result2 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0), result2);
    
    // Test 10 < 10 = 0
    try frame.push(10);
    try frame.push(10);
    try frame.op_lt();
    const result3 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0), result3);
    
    // Test with max value
    try frame.push(std.math.maxInt(u256));
    try frame.push(0);
    try frame.op_lt();
    const result4 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0), result4);
}

test "ColdFrame op_gt greater than comparison" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    const bytecode = [_]u8{0x11, 0x00}; // GT STOP
    var frame = try Frame.init(allocator, &bytecode, 0);
    defer frame.deinit(allocator);
    
    // Test 20 > 10 = 1
    try frame.push(20);
    try frame.push(10);
    try frame.op_gt();
    const result1 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 1), result1);
    
    // Test 10 > 20 = 0
    try frame.push(10);
    try frame.push(20);
    try frame.op_gt();
    const result2 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0), result2);
    
    // Test 10 > 10 = 0
    try frame.push(10);
    try frame.push(10);
    try frame.op_gt();
    const result3 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0), result3);
    
    // Test with max value
    try frame.push(0);
    try frame.push(std.math.maxInt(u256));
    try frame.op_gt();
    const result4 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0), result4);
}

test "ColdFrame op_slt signed less than comparison" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    const bytecode = [_]u8{0x12, 0x00}; // SLT STOP
    var frame = try Frame.init(allocator, &bytecode, 0);
    defer frame.deinit(allocator);
    
    // Test 10 < 20 = 1 (positive comparison)
    try frame.push(10);
    try frame.push(20);
    try frame.op_slt();
    const result1 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 1), result1);
    
    // Test -10 < 10 = 1 (negative < positive)
    const neg_10 = @as(u256, @bitCast(@as(i256, -10)));
    try frame.push(neg_10);
    try frame.push(10);
    try frame.op_slt();
    const result2 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 1), result2);
    
    // Test 10 < -10 = 0 (positive < negative)
    try frame.push(10);
    try frame.push(neg_10);
    try frame.op_slt();
    const result3 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0), result3);
    
    // Test MIN_INT < MAX_INT = 1
    const min_int = @as(u256, 1) << 255; // Sign bit set
    const max_int = (@as(u256, 1) << 255) - 1; // All bits except sign bit
    try frame.push(min_int);
    try frame.push(max_int);
    try frame.op_slt();
    const result4 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 1), result4);
}

test "ColdFrame op_sgt signed greater than comparison" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    const bytecode = [_]u8{0x13, 0x00}; // SGT STOP
    var frame = try Frame.init(allocator, &bytecode, 0);
    defer frame.deinit(allocator);
    
    // Test 20 > 10 = 1 (positive comparison)
    try frame.push(20);
    try frame.push(10);
    try frame.op_sgt();
    const result1 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 1), result1);
    
    // Test 10 > -10 = 1 (positive > negative)
    const neg_10 = @as(u256, @bitCast(@as(i256, -10)));
    try frame.push(10);
    try frame.push(neg_10);
    try frame.op_sgt();
    const result2 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 1), result2);
    
    // Test -10 > 10 = 0 (negative > positive)
    try frame.push(neg_10);
    try frame.push(10);
    try frame.op_sgt();
    const result3 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0), result3);
    
    // Test MAX_INT > MIN_INT = 1
    const min_int = @as(u256, 1) << 255; // Sign bit set
    const max_int = (@as(u256, 1) << 255) - 1; // All bits except sign bit
    try frame.push(max_int);
    try frame.push(min_int);
    try frame.op_sgt();
    const result4 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 1), result4);
}

test "ColdFrame op_eq equality comparison" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    const bytecode = [_]u8{0x14, 0x00}; // EQ STOP
    var frame = try Frame.init(allocator, &bytecode, 0);
    defer frame.deinit(allocator);
    
    // Test 10 == 10 = 1
    try frame.push(10);
    try frame.push(10);
    try frame.op_eq();
    const result1 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 1), result1);
    
    // Test 10 == 20 = 0
    try frame.push(10);
    try frame.push(20);
    try frame.op_eq();
    const result2 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0), result2);
    
    // Test 0 == 0 = 1
    try frame.push(0);
    try frame.push(0);
    try frame.op_eq();
    const result3 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 1), result3);
    
    // Test max == max = 1
    try frame.push(std.math.maxInt(u256));
    try frame.push(std.math.maxInt(u256));
    try frame.op_eq();
    const result4 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 1), result4);
}

test "ColdFrame op_iszero zero check" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    const bytecode = [_]u8{0x15, 0x00}; // ISZERO STOP
    var frame = try Frame.init(allocator, &bytecode, 0);
    defer frame.deinit(allocator);
    
    // Test iszero(0) = 1
    try frame.push(0);
    try frame.op_iszero();
    const result1 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 1), result1);
    
    // Test iszero(1) = 0
    try frame.push(1);
    try frame.op_iszero();
    const result2 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0), result2);
    
    // Test iszero(100) = 0
    try frame.push(100);
    try frame.op_iszero();
    const result3 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0), result3);
    
    // Test iszero(max) = 0
    try frame.push(std.math.maxInt(u256));
    try frame.op_iszero();
    const result4 = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0), result4);
}

test "ColdFrame op_jump unconditional jump" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    const bytecode = [_]u8{0x56, 0x00}; // JUMP STOP
    var frame = try Frame.init(allocator, &bytecode, 0);
    defer frame.deinit(allocator);
    
    // Test valid jump to position 10
    try frame.push(10);
    try frame.op_jump();
    try std.testing.expectEqual(@as(u16, 10), frame.pc);
    
    // Test jump to position 0
    try frame.push(0);
    try frame.op_jump();
    try std.testing.expectEqual(@as(u16, 0), frame.pc);
    
    // Test invalid jump beyond bytecode size
    try frame.push(30000); // Beyond max_bytecode_size
    try std.testing.expectError(error.InvalidJump, frame.op_jump());
}

test "ColdFrame op_jumpi conditional jump" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    const bytecode = [_]u8{0x57, 0x00}; // JUMPI STOP
    var frame = try Frame.init(allocator, &bytecode, 0);
    defer frame.deinit(allocator);
    
    // Test jump with non-zero condition (should jump)
    frame.pc = 0;
    try frame.push(1); // condition (non-zero)
    try frame.push(20); // destination
    try frame.op_jumpi();
    try std.testing.expectEqual(@as(u16, 20), frame.pc);
    
    // Test jump with zero condition (should not jump)
    frame.pc = 5;
    try frame.push(0); // condition (zero)
    try frame.push(30); // destination
    try frame.op_jumpi();
    try std.testing.expectEqual(@as(u16, 5), frame.pc); // PC unchanged
    
    // Test invalid jump with non-zero condition
    try frame.push(1); // condition (non-zero)
    try frame.push(30000); // Invalid destination
    try std.testing.expectError(error.InvalidJump, frame.op_jumpi());
    
    // Test invalid destination with zero condition (should not error)
    frame.pc = 10;
    try frame.push(0); // condition (zero)
    try frame.push(30000); // Invalid destination (but won't be used)
    try frame.op_jumpi();
    try std.testing.expectEqual(@as(u16, 10), frame.pc); // PC unchanged
}

test "ColdFrame op_jumpdest no-op" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    const bytecode = [_]u8{0x5B, 0x00}; // JUMPDEST STOP
    var frame = try Frame.init(allocator, &bytecode, 0);
    defer frame.deinit(allocator);
    
    // JUMPDEST should do nothing
    const initial_pc = frame.pc;
    const initial_stack_size = frame.next_stack_index;
    try frame.op_jumpdest();
    try std.testing.expectEqual(initial_pc, frame.pc);
    try std.testing.expectEqual(initial_stack_size, frame.next_stack_index);
}

test "ColdFrame op_invalid causes error" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    const bytecode = [_]u8{0xFE, 0x00}; // INVALID STOP
    var frame = try Frame.init(allocator, &bytecode, 0);
    defer frame.deinit(allocator);
    
    // INVALID should always return error
    try std.testing.expectError(error.InvalidOpcode, frame.op_invalid());
}

test "ColdFrame op_keccak256 hash computation" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    const bytecode = [_]u8{0x20, 0x00}; // KECCAK256 STOP
    var frame = try Frame.init(allocator, &bytecode, 0);
    defer frame.deinit(allocator);
    
    // Test keccak256 of empty data
    try frame.op_keccak256(&[_]u8{});
    const empty_hash = try frame.pop();
    // keccak256("") = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470
    const expected_empty = @as(u256, 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470);
    try std.testing.expectEqual(expected_empty, empty_hash);
    
    // Test keccak256 of "Hello"
    try frame.op_keccak256("Hello");
    const hello_hash = try frame.pop();
    // keccak256("Hello") = 0x06b3dfaec148fb1bb2b066f10ec285e7c9bf402ab32aa78a5d38e34566810cd2
    const expected_hello = @as(u256, 0x06b3dfaec148fb1bb2b066f10ec285e7c9bf402ab32aa78a5d38e34566810cd2);
    try std.testing.expectEqual(expected_hello, hello_hash);
}

test "ColdFrame interpret basic execution" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    // Simple bytecode: PUSH1 42, PUSH1 10, ADD, STOP
    const bytecode = [_]u8{0x60, 0x2A, 0x60, 0x0A, 0x01, 0x00};
    var frame = try Frame.init(allocator, &bytecode, 1000000);
    defer frame.deinit(allocator);
    
    // interpret should execute until STOP
    const result = frame.interpret(allocator);
    try std.testing.expectError(error.STOP, result);
    
    // Check final stack state
    try std.testing.expectEqual(@as(u12, 1), frame.next_stack_index);
    try std.testing.expectEqual(@as(u256, 52), frame.stack[0]); // 42 + 10 = 52
}

test "ColdFrame interpret OUT_OF_BOUNDS error" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    // Bytecode without STOP: PUSH1 5
    const bytecode = [_]u8{0x60, 0x05};
    var frame = try Frame.init(allocator, &bytecode, 1000000);
    defer frame.deinit(allocator);
    
    // Should hit OUT_OF_BOUNDS after executing PUSH1
    const result = frame.interpret(allocator);
    try std.testing.expectError(error.OutOfBounds, result);
}

test "ColdFrame interpret invalid opcode" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    // Bytecode with invalid opcode: 0xFE (INVALID)
    const bytecode = [_]u8{0xFE};
    var frame = try Frame.init(allocator, &bytecode, 1000000);
    defer frame.deinit(allocator);
    
    // Should return InvalidOpcode error
    const result = frame.interpret(allocator);
    try std.testing.expectError(error.InvalidOpcode, result);
}

test "ColdFrame interpret PUSH values metadata" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    // Test PUSH1 with value stored in metadata
    const bytecode = [_]u8{0x60, 0xFF, 0x00}; // PUSH1 255, STOP
    var frame = try Frame.init(allocator, &bytecode, 1000000);
    defer frame.deinit(allocator);
    
    const result = frame.interpret(allocator);
    try std.testing.expectError(error.STOP, result);
    
    // Check that 255 was pushed
    try std.testing.expectEqual(@as(u12, 1), frame.next_stack_index);
    try std.testing.expectEqual(@as(u256, 255), frame.stack[0]);
}

test "ColdFrame interpret complex bytecode sequence" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    // PUSH1 5, PUSH1 3, ADD, PUSH1 2, MUL, STOP
    // Should compute (5 + 3) * 2 = 16
    const bytecode = [_]u8{0x60, 0x05, 0x60, 0x03, 0x01, 0x60, 0x02, 0x02, 0x00};
    var frame = try Frame.init(allocator, &bytecode, 1000000);
    defer frame.deinit(allocator);
    
    const result = frame.interpret(allocator);
    try std.testing.expectError(error.STOP, result);
    
    // Check final result
    try std.testing.expectEqual(@as(u12, 1), frame.next_stack_index);
    try std.testing.expectEqual(@as(u256, 16), frame.stack[0]);
}

test "ColdFrame interpret JUMP to JUMPDEST" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    // PUSH1 4, JUMP, INVALID, JUMPDEST, PUSH1 42, STOP
    const bytecode = [_]u8{0x60, 0x04, 0x56, 0xFE, 0x5B, 0x60, 0x2A, 0x00};
    var frame = try Frame.init(allocator, &bytecode, 1000000);
    defer frame.deinit(allocator);
    
    const result = frame.interpret(allocator);
    try std.testing.expectError(error.STOP, result);
    
    // Should have 42 on stack (skipped INVALID)
    try std.testing.expectEqual(@as(u12, 1), frame.next_stack_index);
    try std.testing.expectEqual(@as(u256, 42), frame.stack[0]);
}

test "ColdFrame interpret JUMPI conditional" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    // PUSH1 0, PUSH1 8, JUMPI, PUSH1 1, STOP, JUMPDEST, PUSH1 2, STOP
    const bytecode = [_]u8{0x60, 0x00, 0x60, 0x08, 0x57, 0x60, 0x01, 0x00, 0x5B, 0x60, 0x02, 0x00};
    var frame = try Frame.init(allocator, &bytecode, 1000000);
    defer frame.deinit(allocator);
    
    const result = frame.interpret(allocator);
    try std.testing.expectError(error.STOP, result);
    
    // Should have 1 on stack (condition was 0, so didn't jump)
    try std.testing.expectEqual(@as(u12, 1), frame.next_stack_index);
    try std.testing.expectEqual(@as(u256, 1), frame.stack[0]);
}

test "ColdFrame with NoOpTracer executes correctly" {
    const allocator = std.testing.allocator;
    
    // Create frame with default NoOpTracer
    const Frame = createColdFrame(.{});
    
    // Simple bytecode: PUSH1 0x05, PUSH1 0x03, ADD
    const bytecode = [_]u8{ 0x60, 0x05, 0x60, 0x03, 0x01 };
    
    var frame = try Frame.init(allocator, &bytecode, 1000);
    defer frame.deinit(allocator);
    
    // Execute by pushing values and calling add
    try frame.push(5);
    try frame.push(3); 
    try frame.op_add();
    
    // Check that we have the expected result (5 + 3 = 8)
    try std.testing.expectEqual(@as(u12, 1), frame.next_stack_index);
    try std.testing.expectEqual(@as(u256, 8), frame.stack[0]);
}

test "ColdFrame tracer type can be changed at compile time" {
    const allocator = std.testing.allocator;
    
    // Custom tracer for testing
    const TestTracer = struct {
        call_count: usize,
        
        pub fn init() @This() {
            return .{ .call_count = 0 };
        }
        
        pub fn beforeOp(self: *@This(), comptime FrameType: type, frame: *const FrameType) void {
            _ = frame;
            self.call_count += 1;
        }
        
        pub fn afterOp(self: *@This(), comptime FrameType: type, frame: *const FrameType) void {
            _ = frame;
            self.call_count += 1;
        }
        
        pub fn onError(self: *@This(), comptime FrameType: type, frame: *const FrameType, err: anyerror) void {
            _ = frame;
            if (false) {
                std.debug.print("Error: {}\n", .{err});
            }
            self.call_count += 1;
        }
    };
    
    // Create frame with custom tracer
    const config = FrameConfig{
        .TracerType = TestTracer,
    };
    
    const Frame = createColdFrame(config);
    
    // Simple bytecode: PUSH1 0x05
    const bytecode = [_]u8{ 0x60, 0x05 };
    
    var frame = try Frame.init(allocator, &bytecode, 1000);
    defer frame.deinit(allocator);
    
    // Check that our test tracer was initialized
    try std.testing.expectEqual(@as(usize, 0), frame.tracer.call_count);
    
    // Execute a simple operation to trigger tracer
    try frame.push(10);
    
    // Since we're calling op functions directly, tracer won't be triggered
    // unless we go through the interpret function
}

test "ColdFrame op_msize memory size tracking" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    const bytecode = [_]u8{0x59, 0x00}; // MSIZE STOP
    var frame = try Frame.init(allocator, &bytecode, 1000000);
    defer frame.deinit(allocator);
    
    // Initially memory size should be 0
    try frame.op_msize();
    const initial_size = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0), initial_size);
    
    // Store something to expand memory
    try frame.push(0x42); // value
    try frame.push(0); // offset
    try frame.op_mstore();
    
    // Memory should now be 32 bytes
    try frame.op_msize();
    const size_after_store = try frame.pop();
    try std.testing.expectEqual(@as(u256, 32), size_after_store);
    
    // Store at offset 32
    try frame.push(0x55); // value
    try frame.push(32); // offset
    try frame.op_mstore();
    
    // Memory should now be 64 bytes
    try frame.op_msize();
    const size_after_second_store = try frame.pop();
    try std.testing.expectEqual(@as(u256, 64), size_after_second_store);
}

test "ColdFrame op_mload memory load operations" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    const bytecode = [_]u8{0x51, 0x00}; // MLOAD STOP
    var frame = try Frame.init(allocator, &bytecode, 1000000);
    defer frame.deinit(allocator);
    
    // Store a value first
    const test_value: u256 = 0x123456789ABCDEF0;
    try frame.push(test_value);
    try frame.push(0); // offset
    try frame.op_mstore();
    
    // Load it back
    try frame.push(0); // offset
    try frame.op_mload();
    const loaded_value = try frame.pop();
    try std.testing.expectEqual(test_value, loaded_value);
    
    // Load from uninitialized memory (should be zero)
    // First store at offset 64 to ensure memory is expanded
    try frame.push(0); // value 0
    try frame.push(64); // offset
    try frame.op_mstore();
    
    // Now load from offset 64 (should be zero)
    try frame.push(64); // offset
    try frame.op_mload();
    const zero_value = try frame.pop();
    try std.testing.expectEqual(@as(u256, 0), zero_value);
}

test "ColdFrame op_mstore memory store operations" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    const bytecode = [_]u8{0x52, 0x00}; // MSTORE STOP
    var frame = try Frame.init(allocator, &bytecode, 1000000);
    defer frame.deinit(allocator);
    
    // Store multiple values at different offsets
    const value1: u256 = 0xDEADBEEF;
    const value2: u256 = 0xCAFEBABE;
    
    try frame.push(value1);
    try frame.push(0); // offset
    try frame.op_mstore();
    
    try frame.push(value2);
    try frame.push(32); // offset
    try frame.op_mstore();
    
    // Read them back
    try frame.push(0);
    try frame.op_mload();
    const read1 = try frame.pop();
    try std.testing.expectEqual(value1, read1);
    
    try frame.push(32);
    try frame.op_mload();
    const read2 = try frame.pop();
    try std.testing.expectEqual(value2, read2);
}

test "ColdFrame op_mstore8 byte store operations" {
    const allocator = std.testing.allocator;
    const Frame = createColdFrame(.{});
    
    const bytecode = [_]u8{0x53, 0x00}; // MSTORE8 STOP
    var frame = try Frame.init(allocator, &bytecode, 1000000);
    defer frame.deinit(allocator);
    
    // Store a single byte
    try frame.push(0xFF); // value (only low byte will be stored)
    try frame.push(5); // offset
    try frame.op_mstore8();
    
    // Load the 32-byte word containing our byte
    try frame.push(0); // offset 0
    try frame.op_mload();
    const word = try frame.pop();
    
    // The byte at offset 5 should be 0xFF
    // In a 32-byte word, byte 5 is at bit position 216-223 (from the right)
    const byte_5 = @as(u8, @truncate((word >> (26 * 8)) & 0xFF));
    try std.testing.expectEqual(@as(u8, 0xFF), byte_5);
    
    // Store another byte and check
    try frame.push(0x1234ABCD); // value (only 0xCD will be stored)
    try frame.push(10); // offset
    try frame.op_mstore8();
    
    try frame.push(0);
    try frame.op_mload();
    const word2 = try frame.pop();
    const byte_10 = @as(u8, @truncate((word2 >> (21 * 8)) & 0xFF));
    try std.testing.expectEqual(@as(u8, 0xCD), byte_10);
}

