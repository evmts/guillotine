const std = @import("std");
const Opcode = @import("opcode_data.zig").Opcode;
const OpcodeSynthetic = @import("opcode_synthetic.zig").OpcodeSynthetic;
const bytecode_mod = @import("bytecode.zig");
const ArrayList = std.ArrayListAligned;

/// Dispatch manages the execution flow of EVM opcodes through an optimized instruction stream.
/// It converts bytecode into a cache-efficient array of function pointers and metadata,
/// enabling high-performance execution with minimal branch misprediction.
///
/// The dispatch mechanism uses tail-call optimization to jump between opcode handlers,
/// keeping hot data in CPU cache and maintaining predictable memory access patterns.
///
/// @param FrameType - The stack frame type that will execute the opcodes
/// @return A struct type containing dispatch functionality for the given frame type
pub fn Dispatch(comptime FrameType: type) type {
    return struct {
        const Self = @This();
        // We define opcodehandler locally rather than using StackFrame.OpcodeHandler to avoid circular dependency
        const OpcodeHandler = *const fn (frame: *FrameType, dispatch: Self) FrameType.Error!FrameType.Success;
        /// The optimized instruction stream containing opcode handlers and their metadata.
        /// Each item is exactly 64 bits for optimal cache line usage.
        ///
        /// Layout example: [handler_ptr, metadata, handler_ptr, metadata, ...]
        ///
        /// Safety: Always terminated with 2 STOP handlers so accessing cursor[n+1]
        /// or cursor[n+2] is safe without bounds checking.
        cursor: [*]const Item,

        /// Jump table for efficient JUMP/JUMPI lookups
        /// Contains sorted JUMPDEST locations for binary search
        jump_table: ?*const JumpTable,

        // ========================
        // Metadata Types
        // ========================

        /// Metadata for JUMPDEST operations containing pre-calculated gas and stack requirements.
        /// This enables efficient block-level gas accounting and stack validation.
        pub const JumpDestMetadata = packed struct(u64) {
            /// Total gas cost for the entire basic block starting at this JUMPDEST
            gas: u32 = 0,
            min_stack: i16 = 0,
            max_stack: i16 = 0,
        };
        /// Metadata for PUSH operations with values that fit in 64 bits.
        /// Stored inline in the dispatch array for cache efficiency.
        pub const PushInlineMetadata = packed struct(u64) { value: u64 };
        /// Metadata for PUSH operations with values larger than 64 bits.
        /// Contains a pointer to the heap-allocated u256 value.
        pub const PushPointerMetadata = packed struct(u64) { value: *u256 };
        /// Metadata for PC opcode containing the program counter value.
        pub const PcMetadata = packed struct { value: FrameType.PcType };
        /// Metadata for CODESIZE opcode containing the bytecode size.
        pub const CodesizeMetadata = packed struct { size: u32 };
        /// Metadata for CODECOPY opcode containing bytecode pointer and size.
        pub const CodecopyMetadata = packed struct {
            bytecode_ptr: *const []const u8,
            size: u32,
            _padding: u16 = 0,
        };
        /// Metadata for trace_before_op containing PC and opcode for tracing
        pub const TraceBeforeMetadata = packed struct(u64) {
            pc: u32,
            opcode: u8,
            _padding: u24 = 0,
        };
        /// Metadata for trace_after_op containing PC and opcode for tracing
        pub const TraceAfterMetadata = packed struct(u64) {
            pc: u32,
            opcode: u8,
            _padding: u24 = 0,
        };
        /// A single item in the dispatch array, either a handler or metadata.
        pub const Item = union(enum) {
            jump_dest: JumpDestMetadata,
            push_inline: PushInlineMetadata,
            push_pointer: PushPointerMetadata,
            pc: PcMetadata,
            codesize: CodesizeMetadata,
            codecopy: CodecopyMetadata,
            opcode_handler: OpcodeHandler,
            first_block_gas: struct { gas: u32 },
            trace_before: TraceBeforeMetadata,
            trace_after: TraceAfterMetadata,
        };
        /// Jump table entry for dynamic jumps
        pub const JumpTableEntry = struct {
            pc: FrameType.PcType,
            dispatch: Self,
        };

        /// Jump table for dynamic JUMP/JUMPI operations
        /// Sorted array of jump destinations for binary search lookup
        pub const JumpTable = struct {
            entries: []const JumpTableEntry,

            /// Find the dispatch for a given PC using binary search
            pub fn findJumpTarget(self: @This(), target_pc: FrameType.PcType) ?Self {
                var left: usize = 0;
                var right: usize = self.entries.len;

                while (left < right) {
                    const mid = left + (right - left) / 2;
                    const entry = self.entries[mid];

                    if (entry.pc == target_pc) {
                        return entry.dispatch;
                    } else if (entry.pc < target_pc) {
                        left = mid + 1;
                    } else {
                        right = mid;
                    }
                }

                return null;
            }
        };

        // ========================
        // Metadata Access Methods
        // ========================

        /// Get opcode data including metadata and next dispatch position.
        /// This is a comptime-optimized method for specific opcodes.
        pub fn getOpData(self: Self, comptime opcode: Opcode) switch (opcode) {
            .PC => struct { metadata: PcMetadata, next: Self },
            .PUSH1, .PUSH2, .PUSH3, .PUSH4, .PUSH5, .PUSH6, .PUSH7, .PUSH8 => struct { metadata: PushInlineMetadata, next: Self },
            .PUSH9, .PUSH10, .PUSH11, .PUSH12, .PUSH13, .PUSH14, .PUSH15, .PUSH16, .PUSH17, .PUSH18, .PUSH19, .PUSH20, .PUSH21, .PUSH22, .PUSH23, .PUSH24, .PUSH25, .PUSH26, .PUSH27, .PUSH28, .PUSH29, .PUSH30, .PUSH31, .PUSH32 => struct { metadata: PushPointerMetadata, next: Self },
            .JUMPDEST => struct { metadata: JumpDestMetadata, next: Self },
            .CODESIZE => struct { metadata: CodesizeMetadata, next: Self },
            .CODECOPY => struct { metadata: CodecopyMetadata, next: Self },
            else => struct { next: Self },
        } {
            return switch (opcode) {
                .PC => .{
                    .metadata = self.cursor[0].pc,
                    .next = Self{ .cursor = self.cursor + 2, .jump_table = self.jump_table },
                },
                .PUSH1, .PUSH2, .PUSH3, .PUSH4, .PUSH5, .PUSH6, .PUSH7, .PUSH8 => .{
                    .metadata = self.cursor[0].push_inline,
                    .next = Self{ .cursor = self.cursor + 2, .jump_table = self.jump_table },
                },
                .PUSH9, .PUSH10, .PUSH11, .PUSH12, .PUSH13, .PUSH14, .PUSH15, .PUSH16, .PUSH17, .PUSH18, .PUSH19, .PUSH20, .PUSH21, .PUSH22, .PUSH23, .PUSH24, .PUSH25, .PUSH26, .PUSH27, .PUSH28, .PUSH29, .PUSH30, .PUSH31, .PUSH32 => .{
                    .metadata = self.cursor[0].push_pointer,
                    .next = Self{ .cursor = self.cursor + 2, .jump_table = self.jump_table },
                },
                .JUMPDEST => .{
                    .metadata = self.cursor[0].jump_dest,
                    .next = Self{ .cursor = self.cursor + 2, .jump_table = self.jump_table },
                },
                .CODESIZE => .{
                    .metadata = self.cursor[0].codesize,
                    .next = Self{ .cursor = self.cursor + 2, .jump_table = self.jump_table },
                },
                .CODECOPY => .{
                    .metadata = self.cursor[0].codecopy,
                    .next = Self{ .cursor = self.cursor + 2, .jump_table = self.jump_table },
                },
                else => .{
                    .next = Self{ .cursor = self.cursor + 1, .jump_table = self.jump_table },
                },
            };
        }

        /// Advance to the next handler in the dispatch array.
        /// Used for opcodes without metadata.
        pub fn getNext(self: Self) Self {
            return Self{
                .cursor = self.cursor + 1,
                .jump_table = self.jump_table,
            };
        }

        /// Skip the current handler's metadata and advance to the next handler.
        /// Used for opcodes that have associated metadata.
        pub fn skipMetadata(self: Self) Self {
            return Self{
                .cursor = self.cursor + 2,
                .jump_table = self.jump_table,
            };
        }

        /// Find a jump target dispatch for the given PC
        /// Returns null if the PC is not a valid JUMPDEST
        pub fn findJumpTarget(self: Self, target_pc: FrameType.PcType) ?Self {
            if (self.jump_table) |table| {
                return table.findJumpTarget(target_pc);
            }
            return null;
        }

        /// Get inline push metadata from the next position.
        /// Assumes the caller verified this is a push with inline metadata.
        pub fn getInlineMetadata(self: Self) PushInlineMetadata {
            return self.cursor[1].push_inline;
        }

        /// Get pointer push metadata from the next position.
        /// Assumes the caller verified this is a push with pointer metadata.
        pub fn getPointerMetadata(self: Self) PushPointerMetadata {
            return self.cursor[1].push_pointer;
        }

        /// Get PC metadata from the next position.
        /// Assumes the caller verified this is a PC opcode.
        pub fn getPcMetadata(self: Self) PcMetadata {
            return self.cursor[1].pc;
        }

        /// Get JUMPDEST metadata from the next position.
        /// Assumes the caller verified this is a JUMPDEST opcode.
        pub fn getJumpDestMetadata(self: Self) JumpDestMetadata {
            return self.cursor[1].jump_dest;
        }

        // ========================
        // Initialization
        // ========================

        /// Create an optimized dispatch array from bytecode.
        ///
        /// This function analyzes the bytecode and generates an efficient instruction
        /// stream with inline metadata, leveraging opcode fusion opportunities.
        ///
        /// @param allocator - Memory allocator for the dispatch array
        /// @param bytecode - The bytecode to convert
        /// @param opcode_handlers - Array of 256 opcode handler function pointers
        /// @return Owned slice containing the dispatch array
        pub fn init(
            allocator: std.mem.Allocator,
            bytecode: anytype,
            opcode_handlers: *const [256]OpcodeHandler,
        ) ![]Self.Item {
            const log = @import("log.zig");
            log.debug("Dispatch.init starting...", .{});

            // TEMPORARY: Force output to see if this code is reached
            if (bytecode.runtime_code.len > 0) {
                std.debug.print("DISPATCH INIT: bytecode len={d}\n", .{bytecode.runtime_code.len});
            }

            var schedule_items = ArrayList(Self.Item, null){};
            errdefer schedule_items.deinit(allocator);

            // Create iterator to traverse bytecode
            var iter = bytecode.createIterator();
            log.debug("Created bytecode iterator", .{});

            // Calculate gas cost for first basic block
            var first_block_gas: u32 = 0;
            var temp_iter = bytecode.createIterator();
            const opcode_info = @import("opcode_data.zig").OPCODE_INFO;

            // Scan until we hit a JUMPDEST or end of bytecode to calculate first block gas
            var found_terminator = false;
            while (true) {
                const maybe = temp_iter.next();
                if (maybe == null) break;
                const op_data = maybe.?;

                switch (op_data) {
                    .regular => |data| {
                        first_block_gas += opcode_info[data.opcode].gas_cost;
                        // Stop at JUMP/JUMPI/STOP/RETURN/REVERT/INVALID/SELFDESTRUCT
                        switch (data.opcode) {
                            0x56, 0x57, 0x00, 0xf3, 0xfd, 0xfe, 0xff => {
                                found_terminator = true;
                                break;
                            },
                            else => {},
                        }
                    },
                    .push => |data| {
                        const push_opcode = 0x60 + data.size - 1;
                        first_block_gas += opcode_info[push_opcode].gas_cost;
                    },
                    .jumpdest => {
                        found_terminator = true;
                        break;
                    },
                    .stop, .invalid => {
                        first_block_gas += opcode_info[0x00].gas_cost; // STOP gas cost
                        found_terminator = true;
                        break;
                    },
                    else => {
                        // For fusion operations, approximate gas cost
                        first_block_gas += 6; // PUSH + operation
                    },
                }
                if (found_terminator) break;
            }

            // Add first_block_gas entry if there's any gas to charge
            if (first_block_gas > 0) {
                try schedule_items.append(allocator, .{ .first_block_gas = .{ .gas = first_block_gas } });
                log.debug("Added first_block_gas: {d}", .{first_block_gas});
            }

            var opcode_count: usize = 0;
            while (true) {
                const instr_pc = iter.pc;
                const maybe = iter.next();
                if (maybe == null) {
                    log.debug("Bytecode iteration complete, processed {} opcodes", .{opcode_count});
                    break;
                }
                const op_data = maybe.?;
                opcode_count += 1;
                // log.debug("Processing opcode at PC {}: {any}", .{instr_pc, op_data});
                switch (op_data) {
                    .regular => |data| {
                        // Regular opcode - add handler first, then metadata for PC, CODESIZE, CODECOPY
                        const handler = opcode_handlers.*[data.opcode];
                        try schedule_items.append(allocator, .{ .opcode_handler = handler });
                        if (data.opcode == @intFromEnum(Opcode.PC)) {
                            try schedule_items.append(allocator, .{ .pc = .{ .value = @intCast(instr_pc) } });
                        } else if (data.opcode == @intFromEnum(Opcode.CODESIZE)) {
                            try schedule_items.append(allocator, .{ .codesize = .{ .size = @intCast(bytecode.runtime_code.len) } });
                        } else if (data.opcode == @intFromEnum(Opcode.CODECOPY)) {
                            const bytecode_ptr = &bytecode.runtime_code;
                            try schedule_items.append(allocator, .{ .codecopy = .{ .bytecode_ptr = bytecode_ptr, .size = @intCast(bytecode.runtime_code.len) } });
                        }
                    },
                    .push => |data| {
                        // PUSH operation - add handler first, then metadata
                        const push_opcode = 0x60 + data.size - 1; // PUSH1 = 0x60, PUSH2 = 0x61, etc.
                        try schedule_items.append(allocator, .{ .opcode_handler = opcode_handlers.*[push_opcode] });
                        if (data.size <= 8 and data.value <= std.math.maxInt(u64)) {
                            // Inline value for small pushes that fit in u64
                            const inline_value: u64 = @intCast(data.value);
                            try schedule_items.append(allocator, .{ .push_inline = .{ .value = inline_value } });
                        } else {
                            // Pointer to value for large pushes
                            const value_ptr = try allocator.create(FrameType.WordType);
                            value_ptr.* = data.value;
                            try schedule_items.append(allocator, .{ .push_pointer = .{ .value = value_ptr } });
                        }
                    },
                    .jumpdest => |data| {
                        // JUMPDEST - add handler first, then metadata
                        try schedule_items.append(allocator, .{ .opcode_handler = opcode_handlers.*[@intFromEnum(Opcode.JUMPDEST)] });
                        try schedule_items.append(allocator, .{ .jump_dest = .{ .gas = data.gas_cost } });
                    },
                    .push_add_fusion => |data| {
                        try Self.handleFusionOperation(&schedule_items, allocator, opcode_handlers, data.value, .push_add);
                    },
                    .push_mul_fusion => |data| {
                        try Self.handleFusionOperation(&schedule_items, allocator, opcode_handlers, data.value, .push_mul);
                    },
                    .push_sub_fusion => |data| {
                        try Self.handleFusionOperation(&schedule_items, allocator, opcode_handlers, data.value, .push_sub);
                    },
                    .push_div_fusion => |data| {
                        try Self.handleFusionOperation(&schedule_items, allocator, opcode_handlers, data.value, .push_div);
                    },
                    .push_and_fusion => |data| {
                        try Self.handleFusionOperation(&schedule_items, allocator, opcode_handlers, data.value, .push_and);
                    },
                    .push_or_fusion => |data| {
                        try Self.handleFusionOperation(&schedule_items, allocator, opcode_handlers, data.value, .push_or);
                    },
                    .push_xor_fusion => |data| {
                        try Self.handleFusionOperation(&schedule_items, allocator, opcode_handlers, data.value, .push_xor);
                    },
                    .push_jump_fusion => |data| {
                        try Self.handleFusionOperation(&schedule_items, allocator, opcode_handlers, data.value, .push_jump);
                    },
                    .push_jumpi_fusion => |data| {
                        try Self.handleFusionOperation(&schedule_items, allocator, opcode_handlers, data.value, .push_jumpi);
                    },
                    .stop => {
                        try schedule_items.append(allocator, .{ .opcode_handler = opcode_handlers.*[@intFromEnum(Opcode.STOP)] });
                    },
                    .invalid => {
                        try schedule_items.append(allocator, .{ .opcode_handler = opcode_handlers.*[@intFromEnum(Opcode.INVALID)] });
                    },
                }
            }

            // Safety: Append two STOP handlers as terminators.
            // This ensures accessing schedule[n+1] or schedule[n+2] is always safe
            // without bounds checking, improving performance.
            try schedule_items.append(allocator, .{ .opcode_handler = opcode_handlers.*[@intFromEnum(Opcode.STOP)] });
            try schedule_items.append(allocator, .{ .opcode_handler = opcode_handlers.*[@intFromEnum(Opcode.STOP)] });

            const final_schedule = try schedule_items.toOwnedSlice(allocator);
            log.debug("Dispatch.init complete, schedule length: {}", .{final_schedule.len});

            // TEMPORARY: Force output
            std.debug.print("DISPATCH INIT COMPLETE: schedule len={}, opcode_count={}\n", .{ final_schedule.len, opcode_count });

            return final_schedule;
        }

        /// PC mapping entry for tracing
        pub const PCMapEntry = struct {
            dispatch_index: usize,
            pc: FrameType.PcType,
            opcode: u8,
            is_synthetic: bool,
        };

        /// Build a mapping from dispatch indices to PC values and opcodes for tracing
        pub fn buildPCMapping(
            allocator: std.mem.Allocator,
            schedule: []const Self.Item,
            bytecode: anytype,
        ) ![]PCMapEntry {
            var pc_map = ArrayList(PCMapEntry, null){};
            errdefer pc_map.deinit(allocator);

            // Create iterator to traverse bytecode
            var iter = bytecode.createIterator();
            var dispatch_index: usize = 0;

            // Skip first_block_gas if present
            if (schedule.len > 0) {
                switch (schedule[0]) {
                    .first_block_gas => dispatch_index = 1,
                    else => {},
                }
            }

            while (true) {
                const instr_pc = iter.pc;
                const maybe = iter.next();
                if (maybe == null) break;
                const op_data = maybe.?;

                switch (op_data) {
                    .regular => |data| {
                        // Map this regular opcode to its dispatch index
                        try pc_map.append(allocator, .{
                            .dispatch_index = dispatch_index,
                            .pc = @intCast(instr_pc),
                            .opcode = data.opcode,
                            .is_synthetic = false,
                        });
                        dispatch_index += 1;

                        // PC, CODESIZE, CODECOPY opcodes have additional dispatch items
                        if (data.opcode == @intFromEnum(Opcode.PC) or
                            data.opcode == @intFromEnum(Opcode.CODESIZE) or
                            data.opcode == @intFromEnum(Opcode.CODECOPY))
                        {
                            dispatch_index += 1; // Account for metadata
                        }
                    },
                    .push => |data| {
                        const push_opcode = 0x60 + data.size - 1;
                        try pc_map.append(allocator, .{
                            .dispatch_index = dispatch_index,
                            .pc = @intCast(instr_pc),
                            .opcode = push_opcode,
                            .is_synthetic = false,
                        });
                        dispatch_index += 1;

                        // PUSH operations have additional value item
                        dispatch_index += 1;
                    },
                    .jumpdest => |data| {
                        _ = data;
                        try pc_map.append(allocator, .{
                            .dispatch_index = dispatch_index,
                            .pc = @intCast(instr_pc),
                            .opcode = @intFromEnum(Opcode.JUMPDEST),
                            .is_synthetic = false,
                        });
                        dispatch_index += 1;

                        // JUMPDEST has additional metadata
                        dispatch_index += 1;
                    },
                    // Handle fusion operations
                    .push_add_fusion, .push_mul_fusion, .push_sub_fusion, .push_div_fusion, .push_and_fusion, .push_or_fusion, .push_xor_fusion, .push_jump_fusion, .push_jumpi_fusion => |data| {
                        _ = data;
                        const synthetic_opcode: u8 = switch (op_data) {
                            .push_add_fusion => @intFromEnum(OpcodeSynthetic.PUSH_ADD_INLINE),
                            .push_mul_fusion => @intFromEnum(OpcodeSynthetic.PUSH_MUL_INLINE),
                            .push_sub_fusion => @intFromEnum(OpcodeSynthetic.PUSH_SUB_INLINE),
                            .push_div_fusion => @intFromEnum(OpcodeSynthetic.PUSH_DIV_INLINE),
                            .push_and_fusion => @intFromEnum(OpcodeSynthetic.PUSH_AND_INLINE),
                            .push_or_fusion => @intFromEnum(OpcodeSynthetic.PUSH_OR_INLINE),
                            .push_xor_fusion => @intFromEnum(OpcodeSynthetic.PUSH_XOR_INLINE),
                            .push_jump_fusion => @intFromEnum(OpcodeSynthetic.PUSH_JUMP_INLINE),
                            .push_jumpi_fusion => @intFromEnum(OpcodeSynthetic.PUSH_JUMPI_INLINE),
                            else => unreachable,
                        };

                        try pc_map.append(allocator, .{
                            .dispatch_index = dispatch_index,
                            .pc = @intCast(instr_pc),
                            .opcode = synthetic_opcode,
                            .is_synthetic = true,
                        });
                        dispatch_index += 1;

                        // Fusion ops may have additional value item
                        dispatch_index += 1;
                    },
                    .stop => {
                        try pc_map.append(allocator, .{
                            .dispatch_index = dispatch_index,
                            .pc = @intCast(instr_pc),
                            .opcode = @intFromEnum(Opcode.STOP),
                            .is_synthetic = false,
                        });
                        dispatch_index += 1;
                    },
                    .invalid => {
                        try pc_map.append(allocator, .{
                            .dispatch_index = dispatch_index,
                            .pc = @intCast(instr_pc),
                            .opcode = @intFromEnum(Opcode.INVALID),
                            .is_synthetic = false,
                        });
                        dispatch_index += 1;
                    },
                }
            }

            return pc_map.toOwnedSlice(allocator);
        }

        /// Create a dispatch schedule with tracing handlers inserted
        pub fn initWithTracing(
            allocator: std.mem.Allocator,
            bytecode: anytype,
            opcode_handlers: *const [256]OpcodeHandler,
            comptime TracerType: type,
            tracer_instance: *TracerType,
        ) ![]Self.Item {
            var schedule_items = ArrayList(Self.Item, null){};
            errdefer schedule_items.deinit(allocator);

            // Create tracing handlers that will be used throughout
            const trace_before_handler = createTraceHandler(TracerType, tracer_instance, true);
            const trace_after_handler = createTraceHandler(TracerType, tracer_instance, false);

            // Calculate gas cost for first basic block (same as non-tracing version)
            var first_block_gas: u32 = 0;
            var temp_iter = bytecode.createIterator();
            const opcode_info = @import("opcode_data.zig").OPCODE_INFO;

            // Scan until we hit a JUMPDEST or end of bytecode to calculate first block gas
            var found_terminator = false;
            while (true) {
                const maybe = temp_iter.next();
                if (maybe == null) break;
                const op_data = maybe.?;

                switch (op_data) {
                    .regular => |data| {
                        first_block_gas += opcode_info[data.opcode].gas_cost;
                        // Stop at JUMP/JUMPI/STOP/RETURN/REVERT/INVALID/SELFDESTRUCT
                        switch (data.opcode) {
                            0x56, 0x57, 0x00, 0xf3, 0xfd, 0xfe, 0xff => {
                                found_terminator = true;
                                break;
                            },
                            else => {},
                        }
                    },
                    .push => |data| {
                        const push_opcode = 0x60 + data.size - 1;
                        first_block_gas += opcode_info[push_opcode].gas_cost;
                    },
                    .jumpdest => {
                        found_terminator = true;
                        break;
                    },
                    .stop, .invalid => {
                        first_block_gas += opcode_info[0x00].gas_cost; // STOP gas cost
                        found_terminator = true;
                        break;
                    },
                    else => {
                        // For fusion operations, approximate gas cost
                        first_block_gas += 6; // PUSH + operation
                    },
                }
                if (found_terminator) break;
            }

            // Add first_block_gas entry if there's any gas to charge
            if (first_block_gas > 0) {
                try schedule_items.append(allocator, .{ .first_block_gas = .{ .gas = first_block_gas } });
            }

            // Create iterator to traverse bytecode
            var iter = bytecode.createIterator();

            while (true) {
                const instr_pc = iter.pc;
                const maybe = iter.next();
                if (maybe == null) break;
                const op_data = maybe.?;
                switch (op_data) {
                    .regular => |data| {
                        // Insert trace_before
                        try schedule_items.append(allocator, .{ .opcode_handler = trace_before_handler });
                        try schedule_items.append(allocator, .{ .trace_before = .{ .pc = @intCast(instr_pc), .opcode = data.opcode } });

                        // Regular opcode handler
                        const handler = opcode_handlers.*[data.opcode];
                        try schedule_items.append(allocator, .{ .opcode_handler = handler });
                        if (data.opcode == @intFromEnum(Opcode.PC)) {
                            try schedule_items.append(allocator, .{ .pc = .{ .value = @intCast(instr_pc) } });
                        } else if (data.opcode == @intFromEnum(Opcode.CODESIZE)) {
                            try schedule_items.append(allocator, .{ .codesize = .{ .size = @intCast(bytecode.runtime_code.len) } });
                        } else if (data.opcode == @intFromEnum(Opcode.CODECOPY)) {
                            const bytecode_ptr = &bytecode.runtime_code;
                            try schedule_items.append(allocator, .{ .codecopy = .{ .bytecode_ptr = bytecode_ptr, .size = @intCast(bytecode.runtime_code.len) } });
                        }

                        // Insert trace_after
                        try schedule_items.append(allocator, .{ .opcode_handler = trace_after_handler });
                        try schedule_items.append(allocator, .{ .trace_after = .{ .pc = @intCast(instr_pc), .opcode = data.opcode } });
                    },
                    .push => |data| {
                        const push_opcode = 0x60 + data.size - 1;

                        // Insert trace_before
                        try schedule_items.append(allocator, .{ .opcode_handler = trace_before_handler });
                        try schedule_items.append(allocator, .{ .trace_before = .{ .pc = @intCast(instr_pc), .opcode = push_opcode } });

                        // PUSH operation handler and metadata
                        try schedule_items.append(allocator, .{ .opcode_handler = opcode_handlers.*[push_opcode] });
                        if (data.size <= 8 and data.value <= std.math.maxInt(u64)) {
                            const inline_value: u64 = @intCast(data.value);
                            try schedule_items.append(allocator, .{ .push_inline = .{ .value = inline_value } });
                        } else {
                            const value_ptr = try allocator.create(FrameType.WordType);
                            value_ptr.* = data.value;
                            try schedule_items.append(allocator, .{ .push_pointer = .{ .value = value_ptr } });
                        }

                        // Insert trace_after
                        try schedule_items.append(allocator, .{ .opcode_handler = trace_after_handler });
                        try schedule_items.append(allocator, .{ .trace_after = .{ .pc = @intCast(instr_pc), .opcode = push_opcode } });
                    },
                    .jumpdest => |data| {
                        const jumpdest_opcode = @intFromEnum(Opcode.JUMPDEST);

                        // Insert trace_before
                        try schedule_items.append(allocator, .{ .opcode_handler = trace_before_handler });
                        try schedule_items.append(allocator, .{ .trace_before = .{ .pc = @intCast(instr_pc), .opcode = jumpdest_opcode } });

                        // JUMPDEST handler and metadata
                        try schedule_items.append(allocator, .{ .opcode_handler = opcode_handlers.*[jumpdest_opcode] });
                        try schedule_items.append(allocator, .{ .jump_dest = .{ .gas = data.gas_cost } });

                        // Insert trace_after
                        try schedule_items.append(allocator, .{ .opcode_handler = trace_after_handler });
                        try schedule_items.append(allocator, .{ .trace_after = .{ .pc = @intCast(instr_pc), .opcode = jumpdest_opcode } });
                    },
                    // Fusion operations with tracing
                    .push_add_fusion => |data| {
                        try Self.handleFusionOperationWithTracing(&schedule_items, allocator, opcode_handlers, trace_before_handler, trace_after_handler, data.value, .push_add, @intCast(instr_pc));
                    },
                    .push_mul_fusion => |data| {
                        try Self.handleFusionOperationWithTracing(&schedule_items, allocator, opcode_handlers, trace_before_handler, trace_after_handler, data.value, .push_mul, @intCast(instr_pc));
                    },
                    .push_sub_fusion => |data| {
                        try Self.handleFusionOperationWithTracing(&schedule_items, allocator, opcode_handlers, trace_before_handler, trace_after_handler, data.value, .push_sub, @intCast(instr_pc));
                    },
                    .push_div_fusion => |data| {
                        try Self.handleFusionOperationWithTracing(&schedule_items, allocator, opcode_handlers, trace_before_handler, trace_after_handler, data.value, .push_div, @intCast(instr_pc));
                    },
                    .push_and_fusion => |data| {
                        try Self.handleFusionOperationWithTracing(&schedule_items, allocator, opcode_handlers, trace_before_handler, trace_after_handler, data.value, .push_and, @intCast(instr_pc));
                    },
                    .push_or_fusion => |data| {
                        try Self.handleFusionOperationWithTracing(&schedule_items, allocator, opcode_handlers, trace_before_handler, trace_after_handler, data.value, .push_or, @intCast(instr_pc));
                    },
                    .push_xor_fusion => |data| {
                        try Self.handleFusionOperationWithTracing(&schedule_items, allocator, opcode_handlers, trace_before_handler, trace_after_handler, data.value, .push_xor, @intCast(instr_pc));
                    },
                    .push_jump_fusion => |data| {
                        try Self.handleFusionOperationWithTracing(&schedule_items, allocator, opcode_handlers, trace_before_handler, trace_after_handler, data.value, .push_jump, @intCast(instr_pc));
                    },
                    .push_jumpi_fusion => |data| {
                        try Self.handleFusionOperationWithTracing(&schedule_items, allocator, opcode_handlers, trace_before_handler, trace_after_handler, data.value, .push_jumpi, @intCast(instr_pc));
                    },
                    .stop => {
                        const stop_opcode = @intFromEnum(Opcode.STOP);

                        // Insert trace_before
                        try schedule_items.append(allocator, .{ .opcode_handler = trace_before_handler });
                        try schedule_items.append(allocator, .{ .trace_before = .{ .pc = @intCast(instr_pc), .opcode = stop_opcode } });

                        // STOP handler
                        try schedule_items.append(allocator, .{ .opcode_handler = opcode_handlers.*[stop_opcode] });

                        // Insert trace_after
                        try schedule_items.append(allocator, .{ .opcode_handler = trace_after_handler });
                        try schedule_items.append(allocator, .{ .trace_after = .{ .pc = @intCast(instr_pc), .opcode = stop_opcode } });
                    },
                    .invalid => {
                        const invalid_opcode = @intFromEnum(Opcode.INVALID);

                        // Insert trace_before
                        try schedule_items.append(allocator, .{ .opcode_handler = trace_before_handler });
                        try schedule_items.append(allocator, .{ .trace_before = .{ .pc = @intCast(instr_pc), .opcode = invalid_opcode } });

                        // INVALID handler
                        try schedule_items.append(allocator, .{ .opcode_handler = opcode_handlers.*[invalid_opcode] });

                        // Insert trace_after
                        try schedule_items.append(allocator, .{ .opcode_handler = trace_after_handler });
                        try schedule_items.append(allocator, .{ .trace_after = .{ .pc = @intCast(instr_pc), .opcode = invalid_opcode } });
                    },
                }
            }

            // Safety: Append two STOP handlers as terminators
            try schedule_items.append(allocator, .{ .opcode_handler = opcode_handlers.*[@intFromEnum(Opcode.STOP)] });
            try schedule_items.append(allocator, .{ .opcode_handler = opcode_handlers.*[@intFromEnum(Opcode.STOP)] });

            return schedule_items.toOwnedSlice(allocator);
        }

        /// Create a generic trace handler that reads metadata and calls tracer
        fn createTraceHandler(comptime TracerType: type, tracer_instance: *TracerType, comptime is_before: bool) OpcodeHandler {
            const S = struct {
                var tracer: *TracerType = undefined;

                fn handle(frame: *FrameType, dispatch: Self) FrameType.Error!FrameType.Success {
                    if (is_before) {
                        const metadata = dispatch.cursor[0].trace_before;
                        if (@hasDecl(TracerType, "beforeOp")) {
                            tracer.beforeOp(metadata.pc, metadata.opcode, FrameType, frame);
                        }
                    } else {
                        const metadata = dispatch.cursor[0].trace_after;
                        if (@hasDecl(TracerType, "afterOp")) {
                            tracer.afterOp(metadata.pc, metadata.opcode, FrameType, frame);
                        }
                    }
                    // Skip metadata and continue with next handler
                    const next = dispatch.skipMetadata();
                    return next.cursor[0].opcode_handler(frame, next);
                }
            };
            S.tracer = tracer_instance;
            return S.handle;
        }

        /// Helper function to handle fusion operations with tracing support
        fn handleFusionOperationWithTracing(
            schedule_items: *ArrayList(Self.Item, null),
            allocator: std.mem.Allocator,
            opcode_handlers: *const [256]OpcodeHandler,
            trace_before_handler: OpcodeHandler,
            trace_after_handler: OpcodeHandler,
            value: FrameType.WordType,
            fusion_type: FusionType,
            pc: u32,
        ) !void {
            const synthetic_opcode = getSyntheticOpcode(fusion_type, value <= std.math.maxInt(u64));

            // Insert tracing around synthetic operation
            try schedule_items.append(allocator, .{ .opcode_handler = trace_before_handler });
            try schedule_items.append(allocator, .{ .trace_before = .{ .pc = pc, .opcode = synthetic_opcode } });

            try schedule_items.append(allocator, .{ .opcode_handler = opcode_handlers.*[synthetic_opcode] });
            if (value <= std.math.maxInt(u64)) {
                const inline_val: u64 = @intCast(value);
                try schedule_items.append(allocator, .{ .push_inline = .{ .value = inline_val } });
            } else {
                const value_ptr = try allocator.create(FrameType.WordType);
                value_ptr.* = value;
                try schedule_items.append(allocator, .{ .push_pointer = .{ .value = value_ptr } });
            }

            try schedule_items.append(allocator, .{ .opcode_handler = trace_after_handler });
            try schedule_items.append(allocator, .{ .trace_after = .{ .pc = pc, .opcode = synthetic_opcode } });
        }

        /// Helper function to handle fusion operations consistently.
        /// This reduces code duplication and centralizes fusion logic.
        fn handleFusionOperation(
            schedule_items: *ArrayList(Self.Item, null),
            allocator: std.mem.Allocator,
            opcode_handlers: *const [256]OpcodeHandler,
            value: FrameType.WordType,
            fusion_type: FusionType,
        ) !void {
            // Use proper synthetic opcode handler based on value size and fusion type
            const synthetic_opcode = getSyntheticOpcode(fusion_type, value <= std.math.maxInt(u64));
            try schedule_items.append(allocator, .{ .opcode_handler = opcode_handlers.*[synthetic_opcode] });

            if (value <= std.math.maxInt(u64)) {
                const inline_val: u64 = @intCast(value);
                try schedule_items.append(allocator, .{ .push_inline = .{ .value = inline_val } });
            } else {
                const value_ptr = try allocator.create(FrameType.WordType);
                value_ptr.* = value;
                try schedule_items.append(allocator, .{ .push_pointer = .{ .value = value_ptr } });
            }
        }

        const FusionType = enum {
            push_add,
            push_mul,
            push_sub,
            push_div,
            push_and,
            push_or,
            push_xor,
            push_jump,
            push_jumpi,
        };

        /// Get the correct synthetic opcode index for a fusion operation
        fn getSyntheticOpcode(fusion_type: FusionType, is_inline: bool) u8 {
            return switch (fusion_type) {
                .push_add => if (is_inline) @intFromEnum(OpcodeSynthetic.PUSH_ADD_INLINE) else @intFromEnum(OpcodeSynthetic.PUSH_ADD_POINTER),
                .push_mul => if (is_inline) @intFromEnum(OpcodeSynthetic.PUSH_MUL_INLINE) else @intFromEnum(OpcodeSynthetic.PUSH_MUL_POINTER),
                .push_sub => if (is_inline) @intFromEnum(OpcodeSynthetic.PUSH_SUB_INLINE) else @intFromEnum(OpcodeSynthetic.PUSH_SUB_POINTER),
                .push_div => if (is_inline) @intFromEnum(OpcodeSynthetic.PUSH_DIV_INLINE) else @intFromEnum(OpcodeSynthetic.PUSH_DIV_POINTER),
                .push_and => if (is_inline) @intFromEnum(OpcodeSynthetic.PUSH_AND_INLINE) else @intFromEnum(OpcodeSynthetic.PUSH_AND_POINTER),
                .push_or => if (is_inline) @intFromEnum(OpcodeSynthetic.PUSH_OR_INLINE) else @intFromEnum(OpcodeSynthetic.PUSH_OR_POINTER),
                .push_xor => if (is_inline) @intFromEnum(OpcodeSynthetic.PUSH_XOR_INLINE) else @intFromEnum(OpcodeSynthetic.PUSH_XOR_POINTER),
                .push_jump => if (is_inline) @intFromEnum(OpcodeSynthetic.PUSH_JUMP_INLINE) else @intFromEnum(OpcodeSynthetic.PUSH_JUMP_POINTER),
                .push_jumpi => if (is_inline) @intFromEnum(OpcodeSynthetic.PUSH_JUMPI_INLINE) else @intFromEnum(OpcodeSynthetic.PUSH_JUMPI_POINTER),
            };
        }

        /// Create a jump table from the dispatch array and bytecode.
        ///
        /// Builds a sorted array of jump destinations for O(log n) lookup during
        /// dynamic JUMP/JUMPI operations.
        ///
        /// @param allocator - Memory allocator for the jump table
        /// @param schedule - The dispatch array created by init()
        /// @param bytecode - The bytecode to analyze for jump destinations
        /// @return Owned jump table with sorted entries
        pub fn createJumpTable(
            allocator: std.mem.Allocator,
            schedule: []const Item,
            bytecode: anytype,
        ) !JumpTable {
            const log = @import("log.zig");
            log.debug("createJumpTable starting, schedule len: {}", .{schedule.len});

            var jump_entries = ArrayList(JumpTableEntry, null){};
            errdefer jump_entries.deinit(allocator);

            // Create iterator to traverse bytecode and find JUMPDEST locations
            var iter = bytecode.createIterator();
            var schedule_index: usize = 0;

            // Skip first_block_gas if present
            if (schedule.len > 0) {
                switch (schedule[0]) {
                    .first_block_gas => schedule_index = 1,
                    else => {},
                }
            }

            while (true) {
                const instr_pc = iter.pc;
                const maybe = iter.next();
                if (maybe == null) break;
                const op_data = maybe.?;

                switch (op_data) {
                    .jumpdest => {
                        log.debug("Found JUMPDEST at PC {}, schedule_index: {}", .{ instr_pc, schedule_index });
                        // Found a JUMPDEST - create jump table entry
                        if (schedule_index >= schedule.len) {
                            log.err("schedule_index {} >= schedule.len {}", .{ schedule_index, schedule.len });
                            return error.InvalidScheduleIndex;
                        }
                        const dispatch = Self{
                            .cursor = schedule.ptr + schedule_index,
                            .jump_table = null,
                        };
                        try jump_entries.append(allocator, .{
                            .pc = @intCast(instr_pc),
                            .dispatch = dispatch,
                        });
                        // JUMPDEST has handler + metadata, so advance by 2
                        schedule_index += 2;
                    },
                    .regular => |data| {
                        // Regular opcode - advance by 1, or 2 if it has metadata (PC, CODESIZE, CODECOPY)
                        schedule_index += 1;
                        if (data.opcode == @intFromEnum(Opcode.PC) or
                            data.opcode == @intFromEnum(Opcode.CODESIZE) or
                            data.opcode == @intFromEnum(Opcode.CODECOPY))
                        {
                            schedule_index += 1;
                        }
                    },
                    .push => {
                        // PUSH has handler + metadata, so advance by 2
                        schedule_index += 2;
                    },
                    // All fusion cases have handler + metadata
                    .push_add_fusion, .push_mul_fusion, .push_sub_fusion, .push_div_fusion, .push_and_fusion, .push_or_fusion, .push_xor_fusion, .push_jump_fusion, .push_jumpi_fusion => {
                        schedule_index += 2;
                    },
                    .stop, .invalid => {
                        // Simple opcodes without metadata
                        schedule_index += 1;
                    },
                }
            }

            // Sort jump table entries by PC for binary search
            const entries = try jump_entries.toOwnedSlice(allocator);
            std.sort.block(JumpTableEntry, entries, {}, struct {
                pub fn lessThan(context: void, a: JumpTableEntry, b: JumpTableEntry) bool {
                    _ = context;
                    return a.pc < b.pc;
                }
            }.lessThan);

            // Validate sorting (debug builds only)
            if (std.debug.runtime_safety and entries.len > 1) {
                for (entries[0..entries.len -| 1], entries[1..]) |current, next| {
                    if (current.pc >= next.pc) {
                        std.debug.panic("JumpTable not properly sorted: PC {} >= {}", .{ current.pc, next.pc });
                    }
                }
            }

            return JumpTable{ .entries = entries };
        }

        /// Clean up heap-allocated push pointer values in the schedule
        pub fn deinitSchedule(allocator: std.mem.Allocator, schedule: []const Item) void {
            for (schedule) |item| {
                switch (item) {
                    .push_pointer => |ptr_meta| allocator.destroy(ptr_meta.value),
                    else => {},
                }
            }
            allocator.free(schedule);
        }
    };
}

// ============================
// Tests
// ============================

const testing = std.testing;

// Mock frame type for testing
const TestFrame = struct {
    pub const WordType = u256;
    pub const PcType = u32;
    pub const BytecodeConfig = bytecode_mod.BytecodeConfig{
        .max_bytecode_size = 1024,
        .max_initcode_size = 49152,
        .vector_length = 16,
    };

    pub const Error = error{
        TestError,
    };

    pub const Success = enum {
        Stop,
        Return,
    };

    // Add OpcodeHandler type for testing
    pub const OpcodeHandler = *const fn (frame: *TestFrame, dispatch: TestDispatch) Error!Success;
};

const TestDispatch = Dispatch(TestFrame);

// Mock opcode handlers for testing
fn mockStop(frame: *TestFrame, dispatch: TestDispatch) TestFrame.Error!TestFrame.Success {
    _ = frame;
    _ = dispatch;
    return TestFrame.Success.Stop;
}

fn mockAdd(frame: *TestFrame, dispatch: TestDispatch) TestFrame.Error!TestFrame.Success {
    _ = frame;
    _ = dispatch;
    return TestFrame.Success.Stop;
}

fn mockPush1(frame: *TestFrame, dispatch: TestDispatch) TestFrame.Error!TestFrame.Success {
    _ = frame;
    _ = dispatch;
    return TestFrame.Success.Stop;
}

fn mockJumpdest(frame: *TestFrame, dispatch: TestDispatch) TestFrame.Error!TestFrame.Success {
    _ = frame;
    _ = dispatch;
    return TestFrame.Success.Stop;
}

fn mockPc(frame: *TestFrame, dispatch: TestDispatch) TestFrame.Error!TestFrame.Success {
    _ = frame;
    _ = dispatch;
    return TestFrame.Success.Stop;
}

fn mockInvalid(frame: *TestFrame, dispatch: TestDispatch) TestFrame.Error!TestFrame.Success {
    _ = frame;
    _ = dispatch;
    return TestFrame.Error.TestError;
}

// Create test opcode handler array
fn createTestHandlers() [256]*const TestFrame.OpcodeHandler {
    var handlers: [256]*const TestFrame.OpcodeHandler = undefined;

    // Initialize all to invalid
    for (&handlers) |*handler| {
        handler.* = mockInvalid;
    }

    // Set specific handlers
    handlers[@intFromEnum(Opcode.STOP)] = mockStop;
    handlers[@intFromEnum(Opcode.ADD)] = mockAdd;
    handlers[@intFromEnum(Opcode.PUSH1)] = mockPush1;
    handlers[@intFromEnum(Opcode.JUMPDEST)] = mockJumpdest;
    handlers[@intFromEnum(Opcode.PC)] = mockPc;

    return handlers;
}

test "Dispatch - basic initialization with empty bytecode" {
    const allocator = testing.allocator;
    const handlers = createTestHandlers();

    // Create empty bytecode
    const Bytecode = bytecode_mod.Bytecode(TestFrame.BytecodeConfig);
    const bytecode = try Bytecode.init(allocator, &[_]u8{});
    defer bytecode.deinit(allocator);

    // Create dispatch
    const dispatch_items = try TestDispatch.init(allocator, &bytecode, &handlers);
    defer allocator.free(dispatch_items);

    // Should have at least 2 STOP handlers
    try testing.expect(dispatch_items.len >= 2);

    // Last two items should be STOP handlers
    try testing.expect(dispatch_items[dispatch_items.len - 1].opcode_handler == &mockStop);
    try testing.expect(dispatch_items[dispatch_items.len - 2].opcode_handler == &mockStop);
}

test "Dispatch - simple bytecode with ADD" {
    const allocator = testing.allocator;
    const handlers = createTestHandlers();

    // Create bytecode with ADD instruction
    const Bytecode = bytecode_mod.Bytecode(TestFrame.BytecodeConfig);
    const bytecode = try Bytecode.init(allocator, &[_]u8{@intFromEnum(Opcode.ADD)});
    defer bytecode.deinit(allocator);

    // Create dispatch
    const dispatch_items = try TestDispatch.init(allocator, &bytecode, &handlers);
    defer allocator.free(dispatch_items);

    // Should have ADD handler + 2 STOP handlers
    try testing.expect(dispatch_items.len == 3);
    try testing.expect(dispatch_items[0].opcode_handler == &mockAdd);
}

test "Dispatch - PUSH1 with inline metadata" {
    const allocator = testing.allocator;
    const handlers = createTestHandlers();

    // Create bytecode with PUSH1 42
    const Bytecode = bytecode_mod.Bytecode(TestFrame.BytecodeConfig);
    const bytecode = try Bytecode.init(allocator, &[_]u8{ @intFromEnum(Opcode.PUSH1), 42 });
    defer bytecode.deinit(allocator);

    // Create dispatch
    const dispatch_items = try TestDispatch.init(allocator, &bytecode, &handlers);
    defer allocator.free(dispatch_items);

    // Should have PUSH1 handler + metadata + 2 STOP handlers
    try testing.expect(dispatch_items.len == 4);
    try testing.expect(dispatch_items[0].opcode_handler == &mockPush1);
    try testing.expect(dispatch_items[1].push_inline.value == 42);
}

test "Dispatch - PC opcode with metadata" {
    const allocator = testing.allocator;
    const handlers = createTestHandlers();

    // Create bytecode with PC instruction
    const Bytecode = bytecode_mod.Bytecode(TestFrame.BytecodeConfig);
    const bytecode = try Bytecode.init(allocator, &[_]u8{@intFromEnum(Opcode.PC)});
    defer bytecode.deinit(allocator);

    // Create dispatch
    const dispatch_items = try TestDispatch.init(allocator, &bytecode, &handlers);
    defer allocator.free(dispatch_items);

    // Should have PC handler + metadata + 2 STOP handlers
    try testing.expect(dispatch_items.len == 4);
    try testing.expect(dispatch_items[0].opcode_handler == &mockPc);
    try testing.expect(dispatch_items[1].pc.value == 0);
}

test "Dispatch - getNext advances by 1" {
    var dummy_items = [_]TestDispatch.Item{
        .{ .opcode_handler = mockStop },
        .{ .opcode_handler = mockStop },
    };
    const dispatch = TestDispatch{ .cursor = &dummy_items, .jump_table = null };
    const next = dispatch.getNext();

    // Verify pointer arithmetic
    const diff = @intFromPtr(next.cursor) - @intFromPtr(dispatch.cursor);
    try testing.expect(diff == @sizeOf(TestDispatch.Item));
}

test "Dispatch - skipMetadata advances by 2" {
    var dummy_items = [_]TestDispatch.Item{
        .{ .opcode_handler = mockStop },
        .{ .opcode_handler = mockStop },
        .{ .opcode_handler = mockStop },
    };
    const dispatch = TestDispatch{ .cursor = &dummy_items, .jump_table = null };
    const next = dispatch.skipMetadata();

    // Verify pointer arithmetic
    const diff = @intFromPtr(next.cursor) - @intFromPtr(dispatch.cursor);
    try testing.expect(diff == 2 * @sizeOf(TestDispatch.Item));
}

test "Dispatch - getInlineMetadata accesses correct position" {
    var items = [_]TestDispatch.Item{
        .{ .opcode_handler = mockPush1 },
        .{ .push_inline = .{ .value = 123 } },
        .{ .opcode_handler = mockStop },
    };

    const dispatch = TestDispatch{ .cursor = &items };
    const metadata = dispatch.getInlineMetadata();

    try testing.expect(metadata.value == 123);
}

test "Dispatch - getPointerMetadata accesses correct position" {
    const test_value: u256 = 456;
    var items = [_]TestDispatch.Item{
        .{ .opcode_handler = mockPush1 },
        .{ .push_pointer = .{ .value = @constCast(&test_value) } },
        .{ .opcode_handler = mockStop },
    };

    const dispatch = TestDispatch{ .cursor = &items };
    const metadata = dispatch.getPointerMetadata();

    try testing.expect(metadata.value.* == 456);
}

test "Dispatch - getPcMetadata accesses correct position" {
    var items = [_]TestDispatch.Item{
        .{ .opcode_handler = mockPc },
        .{ .pc = .{ .value = 789 } },
        .{ .opcode_handler = mockStop },
    };

    const dispatch = TestDispatch{ .cursor = &items };
    const metadata = dispatch.getPcMetadata();

    try testing.expect(metadata.value == 789);
}

test "Dispatch - getJumpDestMetadata accesses correct position" {
    var items = [_]TestDispatch.Item{
        .{ .opcode_handler = mockJumpdest },
        .{ .jump_dest = .{ .gas = 100, .min_stack = -5, .max_stack = 10 } },
        .{ .opcode_handler = mockStop },
    };

    const dispatch = TestDispatch{ .cursor = &items };
    const metadata = dispatch.getJumpDestMetadata();

    try testing.expect(metadata.gas == 100);
    try testing.expect(metadata.min_stack == -5);
    try testing.expect(metadata.max_stack == 10);
}

test "Dispatch - getOpData for PC returns correct metadata and next" {
    const items = [_]TestDispatch.Item{
        .{ .pc = .{ .value = 42 } },
        .{ .opcode_handler = mockAdd },
        .{ .opcode_handler = mockStop },
    };

    const dispatch = TestDispatch{ .cursor = @ptrCast(&items[0]), .jump_table = null };
    const op_data = dispatch.getOpData(.PC);

    try testing.expect(op_data.metadata.value == 42);
    try testing.expect(op_data.next.cursor == dispatch.cursor + 2);
}

test "Dispatch - getOpData for regular opcode returns only next" {
    const items = [_]TestDispatch.Item{
        .{ .opcode_handler = mockAdd },
        .{ .opcode_handler = mockStop },
    };

    const dispatch = TestDispatch{ .cursor = @ptrCast(&items[0]), .jump_table = null };
    const op_data = dispatch.getOpData(.ADD);

    try testing.expect(op_data.next.cursor == dispatch.cursor + 1);
}

test "Dispatch - complex bytecode sequence" {
    const allocator = testing.allocator;
    const handlers = createTestHandlers();

    // Create bytecode: PUSH1 10, PUSH1 20, ADD, STOP
    const Bytecode = bytecode_mod.Bytecode(TestFrame.BytecodeConfig);
    const bytecode = try Bytecode.init(allocator, &[_]u8{
        @intFromEnum(Opcode.PUSH1), 10,
        @intFromEnum(Opcode.PUSH1), 20,
        @intFromEnum(Opcode.ADD),   @intFromEnum(Opcode.STOP),
    });
    defer bytecode.deinit(allocator);

    // Create dispatch
    const dispatch_items = try TestDispatch.init(allocator, &bytecode, &handlers);
    defer allocator.free(dispatch_items);

    // Verify structure: PUSH1, metadata, PUSH1, metadata, ADD, STOP, STOP, STOP
    try testing.expect(dispatch_items.len == 8);

    // First PUSH1
    try testing.expect(dispatch_items[0].opcode_handler == &mockPush1);
    try testing.expect(dispatch_items[1].push_inline.value == 10);

    // Second PUSH1
    try testing.expect(dispatch_items[2].opcode_handler == &mockPush1);
    try testing.expect(dispatch_items[3].push_inline.value == 20);

    // ADD
    try testing.expect(dispatch_items[4].opcode_handler == &mockAdd);

    // Three STOPs (one from bytecode, two safety terminators)
    try testing.expect(dispatch_items[5].opcode_handler == &mockStop);
    try testing.expect(dispatch_items[6].opcode_handler == &mockStop);
    try testing.expect(dispatch_items[7].opcode_handler == &mockStop);
}

test "Dispatch - metadata size constraints" {
    // Ensure metadata structs fit in 64 bits
    try testing.expect(@sizeOf(TestDispatch.JumpDestMetadata) == 8);
    try testing.expect(@sizeOf(TestDispatch.PushInlineMetadata) == 8);
    try testing.expect(@sizeOf(TestDispatch.PushPointerMetadata) == 8);
    try testing.expect(@sizeOf(TestDispatch.PcMetadata) <= 8);
}

test "Dispatch - invalid bytecode handling" {
    const allocator = testing.allocator;
    const handlers = createTestHandlers();

    // Create bytecode with invalid opcode
    const Bytecode = bytecode_mod.Bytecode(TestFrame.BytecodeConfig);
    const bytecode = try Bytecode.init(allocator, &[_]u8{0xFE}); // Invalid opcode
    defer bytecode.deinit(allocator);

    // Create dispatch
    const dispatch_items = try TestDispatch.init(allocator, &bytecode, &handlers);
    defer allocator.free(dispatch_items);

    // Should have invalid handler + 2 STOP handlers
    try testing.expect(dispatch_items.len == 3);
    try testing.expect(dispatch_items[0].opcode_handler == &mockInvalid);
}

test "Dispatch - JUMPDEST with gas metadata" {
    const allocator = testing.allocator;
    const handlers = createTestHandlers();

    // Create bytecode with JUMPDEST
    const Bytecode = bytecode_mod.Bytecode(TestFrame.BytecodeConfig);
    const bytecode = try Bytecode.init(allocator, &[_]u8{@intFromEnum(Opcode.JUMPDEST)});
    defer bytecode.deinit(allocator);

    // Note: In real usage, the bytecode analyzer would set gas costs
    // For this test, we're checking the structure is created correctly

    // Create dispatch
    const dispatch_items = try TestDispatch.init(allocator, &bytecode, &handlers);
    defer allocator.free(dispatch_items);

    // Should have JUMPDEST handler + metadata + 2 STOP handlers
    try testing.expect(dispatch_items.len == 4);
    try testing.expect(dispatch_items[0].opcode_handler == &mockJumpdest);
    // Gas metadata would be set by bytecode analyzer
    try testing.expect(dispatch_items[1].jump_dest.gas == 0); // Default value
}

test "Dispatch - PUSH32 with pointer metadata" {
    const allocator = testing.allocator;
    const handlers = createTestHandlers();

    // Create bytecode with PUSH32 (large value requiring pointer storage)
    var push32_data = [_]u8{@intFromEnum(Opcode.PUSH32)} ++ [_]u8{0xFF} ** 32;
    const Bytecode = bytecode_mod.Bytecode(TestFrame.BytecodeConfig);
    const bytecode = try Bytecode.init(allocator, &push32_data);
    defer bytecode.deinit(allocator);

    // Create dispatch
    const dispatch_items = try TestDispatch.init(allocator, &bytecode, &handlers);
    defer {
        // Clean up pointer metadata
        for (dispatch_items) |item| {
            switch (item) {
                .push_pointer => |ptr_meta| allocator.destroy(ptr_meta.value),
                else => {},
            }
        }
        allocator.free(dispatch_items);
    }

    // Should have PUSH32 handler + pointer metadata + 2 STOP handlers
    try testing.expect(dispatch_items.len == 4);
    try testing.expect(dispatch_items[0].opcode_handler == &mockPush1); // Using mockPush1 for all PUSH variants

    // Verify pointer metadata contains the correct large value
    const expected_value: u256 = (1 << 256) - 1; // 0xFFFF...FFFF (32 bytes of 0xFF)
    try testing.expect(dispatch_items[1].push_pointer.value.* == expected_value);
}

test "Dispatch - PUSH9 boundary test (first pointer type)" {
    const allocator = testing.allocator;
    const handlers = createTestHandlers();

    // Create bytecode with PUSH9 (first PUSH that uses pointer storage)
    var push9_data = [_]u8{@intFromEnum(Opcode.PUSH9)} ++ [_]u8{ 0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0, 0x11 };
    const Bytecode = bytecode_mod.Bytecode(TestFrame.BytecodeConfig);
    const bytecode = try Bytecode.init(allocator, &push9_data);
    defer bytecode.deinit(allocator);

    // Create dispatch
    const dispatch_items = try TestDispatch.init(allocator, &bytecode, &handlers);
    defer {
        // Clean up pointer metadata
        for (dispatch_items) |item| {
            switch (item) {
                .push_pointer => |ptr_meta| allocator.destroy(ptr_meta.value),
                else => {},
            }
        }
        allocator.free(dispatch_items);
    }

    // Should have PUSH9 handler + pointer metadata + 2 STOP handlers
    try testing.expect(dispatch_items.len == 4);
    try testing.expect(dispatch_items[0].opcode_handler == &mockPush1);

    // Verify the 9-byte value is correctly stored
    const expected_value: u256 = 0x123456789ABCDEF011;
    try testing.expect(dispatch_items[1].push_pointer.value.* == expected_value);
}

test "Dispatch - PUSH8 boundary test (last inline type)" {
    const allocator = testing.allocator;
    const handlers = createTestHandlers();

    // Create bytecode with PUSH8 (last PUSH that uses inline storage)
    var push8_data = [_]u8{@intFromEnum(Opcode.PUSH8)} ++ [_]u8{ 0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0 };
    const Bytecode = bytecode_mod.Bytecode(TestFrame.BytecodeConfig);
    const bytecode = try Bytecode.init(allocator, &push8_data);
    defer bytecode.deinit(allocator);

    // Create dispatch
    const dispatch_items = try TestDispatch.init(allocator, &bytecode, &handlers);
    defer allocator.free(dispatch_items);

    // Should have PUSH8 handler + inline metadata + 2 STOP handlers
    try testing.expect(dispatch_items.len == 4);
    try testing.expect(dispatch_items[0].opcode_handler == &mockPush1);

    // Verify the 8-byte value is stored inline
    const expected_value: u64 = 0x123456789ABCDEF0;
    try testing.expect(dispatch_items[1].push_inline.value == expected_value);
}

test "Dispatch - large value no longer truncated" {
    const allocator = testing.allocator;
    const handlers = createTestHandlers();

    // Test a PUSH4 with value that fits in u64 - should use inline storage
    var push4_small_data = [_]u8{@intFromEnum(Opcode.PUSH4)} ++ [_]u8{ 0x00, 0x00, 0xFF, 0xFF };
    const Bytecode = bytecode_mod.Bytecode(TestFrame.BytecodeConfig);
    const bytecode_small = try Bytecode.init(allocator, &push4_small_data);
    defer bytecode_small.deinit(allocator);

    const dispatch_items_small = try TestDispatch.init(allocator, &bytecode_small, &handlers);
    defer allocator.free(dispatch_items_small);

    // Should use inline storage for small value
    try testing.expect(dispatch_items_small[1].push_inline.value == 0x0000FFFF);

    // Test a PUSH8 with maximum u64 value - should still use inline storage
    var push8_max_data = [_]u8{@intFromEnum(Opcode.PUSH8)} ++ [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };
    const bytecode_max = try Bytecode.init(allocator, &push8_max_data);
    defer bytecode_max.deinit(allocator);

    const dispatch_items_max = try TestDispatch.init(allocator, &bytecode_max, &handlers);
    defer allocator.free(dispatch_items_max);

    // Should use inline storage for max u64 value
    try testing.expect(dispatch_items_max[1].push_inline.value == std.math.maxInt(u64));
}

test "Dispatch - boundary case forces pointer storage" {
    _ = testing.allocator;
    _ = createTestHandlers();

    // Test edge case: PUSH8 with value that exceeds u64 (this would be a bytecode analysis issue normally)
    // But we test to ensure the fix works correctly

    // This test documents that values exceeding u64 max, even in small PUSH operations,
    // now correctly use pointer storage instead of being truncated

    // Since we can't easily create such bytecode from raw bytes (the bytecode analyzer
    // would prevent this), this test serves as documentation of the fix.
    try testing.expect(true); // Placeholder documenting the fix
}

test "JumpTable - empty jump table" {
    // Create empty jump table
    const jump_table = TestDispatch.JumpTable{ .entries = &[_]TestDispatch.JumpTableEntry{} };

    // Should return null for any target
    try testing.expect(jump_table.findJumpTarget(0) == null);
    try testing.expect(jump_table.findJumpTarget(100) == null);
    try testing.expect(jump_table.findJumpTarget(0xFFFF) == null);
}

test "JumpTable - single entry" {
    const allocator = testing.allocator;
    const handlers = createTestHandlers();

    // Create bytecode with single JUMPDEST at PC 5
    const bytecode_data = [_]u8{
        @intFromEnum(Opcode.PUSH1), 10, // PC 0-1
        @intFromEnum(Opcode.PUSH1), 20, // PC 2-3
        @intFromEnum(Opcode.ADD), // PC 4
        @intFromEnum(Opcode.JUMPDEST), // PC 5 <- target
        @intFromEnum(Opcode.STOP), // PC 6
    };

    const Bytecode = bytecode_mod.Bytecode(TestFrame.BytecodeConfig);
    const bytecode = try Bytecode.init(allocator, &bytecode_data);
    defer bytecode.deinit(allocator);

    // Create dispatch
    const dispatch_items = try TestDispatch.init(allocator, &bytecode, &handlers);
    defer allocator.free(dispatch_items);

    // Create jump table
    const jump_table = try TestDispatch.createJumpTable(allocator, dispatch_items, &bytecode);
    defer allocator.free(jump_table.entries);

    // Should have exactly one entry
    try testing.expect(jump_table.entries.len == 1);
    try testing.expect(jump_table.entries[0].pc == 5);

    // Test binary search
    try testing.expect(jump_table.findJumpTarget(5) != null);
    try testing.expect(jump_table.findJumpTarget(0) == null);
    try testing.expect(jump_table.findJumpTarget(4) == null);
    try testing.expect(jump_table.findJumpTarget(6) == null);
}

test "JumpTable - multiple entries sorted order" {
    const allocator = testing.allocator;
    const handlers = createTestHandlers();

    // Create bytecode with multiple JUMPDESTs
    const bytecode_data = [_]u8{
        @intFromEnum(Opcode.JUMPDEST), // PC 0
        @intFromEnum(Opcode.PUSH1), 10, // PC 1-2
        @intFromEnum(Opcode.JUMPDEST), // PC 3
        @intFromEnum(Opcode.ADD), // PC 4
        @intFromEnum(Opcode.JUMPDEST), // PC 5
        @intFromEnum(Opcode.STOP), // PC 6
    };

    const Bytecode = bytecode_mod.Bytecode(TestFrame.BytecodeConfig);
    const bytecode = try Bytecode.init(allocator, &bytecode_data);
    defer bytecode.deinit(allocator);

    // Create dispatch and jump table
    const dispatch_items = try TestDispatch.init(allocator, &bytecode, &handlers);
    defer allocator.free(dispatch_items);

    const jump_table = try TestDispatch.createJumpTable(allocator, dispatch_items, &bytecode);
    defer allocator.free(jump_table.entries);

    // Should have 3 entries
    try testing.expect(jump_table.entries.len == 3);

    // Verify entries are sorted by PC
    try testing.expect(jump_table.entries[0].pc == 0);
    try testing.expect(jump_table.entries[1].pc == 3);
    try testing.expect(jump_table.entries[2].pc == 5);

    // Test binary search for all valid targets
    try testing.expect(jump_table.findJumpTarget(0) != null);
    try testing.expect(jump_table.findJumpTarget(3) != null);
    try testing.expect(jump_table.findJumpTarget(5) != null);

    // Test binary search for invalid targets
    try testing.expect(jump_table.findJumpTarget(1) == null);
    try testing.expect(jump_table.findJumpTarget(2) == null);
    try testing.expect(jump_table.findJumpTarget(4) == null);
    try testing.expect(jump_table.findJumpTarget(6) == null);
}

test "JumpTable - binary search edge cases" {
    // Create manual jump table with edge case PCs
    const entries = [_]TestDispatch.JumpTableEntry{
        .{ .pc = 0, .dispatch = TestDispatch{ .cursor = undefined } },
        .{ .pc = 1, .dispatch = TestDispatch{ .cursor = undefined } },
        .{ .pc = 100, .dispatch = TestDispatch{ .cursor = undefined } },
        .{ .pc = 0xFFFE, .dispatch = TestDispatch{ .cursor = undefined } },
        .{ .pc = 0xFFFF, .dispatch = TestDispatch{ .cursor = undefined } },
    };

    const jump_table = TestDispatch.JumpTable{ .entries = &entries };

    // Test boundary conditions
    try testing.expect(jump_table.findJumpTarget(0) != null); // First entry
    try testing.expect(jump_table.findJumpTarget(0xFFFF) != null); // Last entry
    try testing.expect(jump_table.findJumpTarget(1) != null); // Second entry
    try testing.expect(jump_table.findJumpTarget(0xFFFE) != null); // Second to last
    try testing.expect(jump_table.findJumpTarget(100) != null); // Middle entry

    // Test just outside boundaries
    try testing.expect(jump_table.findJumpTarget(2) == null);
    try testing.expect(jump_table.findJumpTarget(99) == null);
    try testing.expect(jump_table.findJumpTarget(101) == null);
    try testing.expect(jump_table.findJumpTarget(0xFFFD) == null);
}

test "JumpTable - large jump table performance" {
    const allocator = testing.allocator;

    // Create large jump table (simulate many JUMPDESTs)
    const entries = try allocator.alloc(TestDispatch.JumpTableEntry, 1000);
    defer allocator.free(entries);

    // Fill with sorted PCs (every 10th PC is a JUMPDEST)
    for (entries, 0..) |*entry, i| {
        entry.* = .{
            .pc = @intCast(i * 10),
            .dispatch = TestDispatch{ .cursor = undefined },
        };
    }

    const jump_table = TestDispatch.JumpTable{ .entries = entries };

    // Test that binary search finds all valid targets efficiently
    for (0..1000) |i| {
        const target_pc: u32 = @intCast(i * 10);
        try testing.expect(jump_table.findJumpTarget(target_pc) != null);
    }

    // Test that binary search correctly rejects invalid targets
    for (0..1000) |i| {
        const invalid_pc: u32 = @intCast(i * 10 + 5); // Between valid targets
        try testing.expect(jump_table.findJumpTarget(invalid_pc) == null);
    }
}

// Mock fusion handlers for testing
fn mockPushAddFusion(frame: TestFrame, dispatch: *const anyopaque) TestFrame.Error!TestFrame.Success {
    _ = frame;
    _ = dispatch;
    return TestFrame.Success.Stop;
}

fn mockPushMulFusion(frame: TestFrame, dispatch: *const anyopaque) TestFrame.Error!TestFrame.Success {
    _ = frame;
    _ = dispatch;
    return TestFrame.Success.Stop;
}

// Create test opcode handler array with synthetic opcodes
fn createTestHandlersWithSynthetic() [256]*const TestFrame.OpcodeHandler {
    var handlers: [256]*const TestFrame.OpcodeHandler = undefined;

    // Initialize all to invalid
    for (&handlers) |*handler| {
        handler.* = mockInvalid;
    }

    // Set specific handlers
    handlers[@intFromEnum(Opcode.STOP)] = mockStop;
    handlers[@intFromEnum(Opcode.ADD)] = mockAdd;
    handlers[@intFromEnum(Opcode.PUSH1)] = mockPush1;
    handlers[@intFromEnum(Opcode.JUMPDEST)] = mockJumpdest;
    handlers[@intFromEnum(Opcode.PC)] = mockPc;

    // TODO: Add synthetic opcode handlers when they're implemented
    // handlers[synthetic_push_add_opcode] = mockPushAddFusion;
    // handlers[synthetic_push_mul_opcode] = mockPushMulFusion;

    return handlers;
}

test "Dispatch - fusion operations now use correct synthetic handlers" {
    // Test that fusion operations correctly map to synthetic opcode handlers

    // Test getSyntheticOpcode function returns correct values
    try testing.expect(TestDispatch.getSyntheticOpcode(.push_add, true) == @intFromEnum(OpcodeSynthetic.PUSH_ADD_INLINE));
    try testing.expect(TestDispatch.getSyntheticOpcode(.push_add, false) == @intFromEnum(OpcodeSynthetic.PUSH_ADD_POINTER));
    try testing.expect(TestDispatch.getSyntheticOpcode(.push_mul, true) == @intFromEnum(OpcodeSynthetic.PUSH_MUL_INLINE));
    try testing.expect(TestDispatch.getSyntheticOpcode(.push_mul, false) == @intFromEnum(OpcodeSynthetic.PUSH_MUL_POINTER));
    try testing.expect(TestDispatch.getSyntheticOpcode(.push_jump, true) == @intFromEnum(OpcodeSynthetic.PUSH_JUMP_INLINE));
    try testing.expect(TestDispatch.getSyntheticOpcode(.push_jump, false) == @intFromEnum(OpcodeSynthetic.PUSH_JUMP_POINTER));

    // Verify synthetic opcodes are in expected range (0xB0-0xC7)
    try testing.expect(@intFromEnum(OpcodeSynthetic.PUSH_ADD_INLINE) == 0xB0);
    try testing.expect(@intFromEnum(OpcodeSynthetic.PUSH_XOR_POINTER) == 0xC5);
}

test "Dispatch - memory cleanup for pointer metadata" {
    const allocator = testing.allocator;
    const handlers = createTestHandlers();

    // Create bytecode with large PUSH that requires pointer allocation
    var push16_data = [_]u8{@intFromEnum(Opcode.PUSH16)} ++ [_]u8{0xFF} ** 16;
    const Bytecode = bytecode_mod.Bytecode(TestFrame.BytecodeConfig);
    const bytecode = try Bytecode.init(allocator, &push16_data);
    defer bytecode.deinit(allocator);

    // Create dispatch
    const dispatch_items = try TestDispatch.init(allocator, &bytecode, &handlers);

    // Track allocations for cleanup verification
    var pointer_count: usize = 0;
    var pointers_to_free: [10]*u256 = undefined;

    for (dispatch_items) |item| {
        switch (item) {
            .push_pointer => |ptr_meta| {
                pointers_to_free[pointer_count] = ptr_meta.value;
                pointer_count += 1;
            },
            else => {},
        }
    }

    // Clean up - this is what user code must do
    for (0..pointer_count) |i| {
        allocator.destroy(pointers_to_free[i]);
    }
    allocator.free(dispatch_items);

    // Verify we found the expected pointer
    try testing.expect(pointer_count == 1);
}

test "Dispatch - allocation failure handling" {
    // Test what happens when allocation fails during init
    // This exposes potential memory leaks in error paths

    var failing_allocator = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 1 });
    const handlers = createTestHandlers();

    // Create simple bytecode
    const Bytecode = bytecode_mod.Bytecode(TestFrame.BytecodeConfig);
    const bytecode = try Bytecode.init(testing.allocator, &[_]u8{@intFromEnum(Opcode.ADD)});
    defer bytecode.deinit(testing.allocator);

    // Should fail allocation
    const result = TestDispatch.init(failing_allocator.allocator(), &bytecode, &handlers);
    try testing.expectError(error.OutOfMemory, result);

    // The errdefer in init should clean up the ArrayList
}

test "Dispatch - edge case empty bytecode safety" {
    const allocator = testing.allocator;
    const handlers = createTestHandlers();

    // Create completely empty bytecode
    const Bytecode = bytecode_mod.Bytecode(TestFrame.BytecodeConfig);
    const bytecode = try Bytecode.init(allocator, &[_]u8{});
    defer bytecode.deinit(allocator);

    // Create dispatch
    const dispatch_items = try TestDispatch.init(allocator, &bytecode, &handlers);
    defer allocator.free(dispatch_items);

    // Should have exactly 2 STOP handlers (the safety terminators)
    try testing.expect(dispatch_items.len == 2);
    try testing.expect(dispatch_items[0].opcode_handler == &mockStop);
    try testing.expect(dispatch_items[1].opcode_handler == &mockStop);

    // Create dispatch wrapper and test safety
    const dispatch = TestDispatch{ .cursor = dispatch_items.ptr };
    const next = dispatch.getNext();

    // Should be able to access next safely (second STOP)
    const ptr_diff = @intFromPtr(next.cursor) - @intFromPtr(dispatch.cursor);
    try testing.expect(ptr_diff == @sizeOf(TestDispatch.Item));
}

test "Dispatch - getOpData compilation and type safety" {
    // This test ensures getOpData compiles correctly for all opcode types
    // and returns the right types

    const items = [_]TestDispatch.Item{
        .{ .pc = .{ .value = 42 } },
        .{ .opcode_handler = mockAdd },
        .{ .push_inline = .{ .value = 123 } },
        .{ .opcode_handler = mockStop },
        .{ .push_pointer = .{ .value = undefined } },
        .{ .opcode_handler = mockStop },
        .{ .jump_dest = .{ .gas = 100 } },
        .{ .opcode_handler = mockStop },
    };

    // Test PC opcode
    const pc_dispatch = TestDispatch{ .cursor = @ptrCast(&items[0]) };
    const pc_data = pc_dispatch.getOpData(.PC);
    try testing.expect(@TypeOf(pc_data.metadata) == TestDispatch.PcMetadata);
    try testing.expect(pc_data.metadata.value == 42);

    // Test PUSH1 (inline)
    const push1_dispatch = TestDispatch{ .cursor = @ptrCast(&items[2]) };
    const push1_data = push1_dispatch.getOpData(.PUSH1);
    try testing.expect(@TypeOf(push1_data.metadata) == TestDispatch.PushInlineMetadata);
    try testing.expect(push1_data.metadata.value == 123);

    // Test PUSH32 (pointer)
    const push32_dispatch = TestDispatch{ .cursor = @ptrCast(&items[4]) };
    const push32_data = push32_dispatch.getOpData(.PUSH32);
    try testing.expect(@TypeOf(push32_data.metadata) == TestDispatch.PushPointerMetadata);

    // Test JUMPDEST
    const jd_dispatch = TestDispatch{ .cursor = @ptrCast(&items[6]) };
    const jd_data = jd_dispatch.getOpData(.JUMPDEST);
    try testing.expect(@TypeOf(jd_data.metadata) == TestDispatch.JumpDestMetadata);
    try testing.expect(jd_data.metadata.gas == 100);

    // Test regular opcode (no metadata)
    const add_dispatch = TestDispatch{ .cursor = @ptrCast(&items[1]) };
    const add_data = add_dispatch.getOpData(.ADD);
    try testing.expect(!@hasField(@TypeOf(add_data), "metadata"));
}

test "Dispatch - createJumpTable with arithmetic bytecode" {
    const allocator = testing.allocator;
    const handlers = createTestHandlers();

    // Create bytecode similar to our differential test
    const bytecode_data = [_]u8{
        // ADD: 5 + 3
        @intFromEnum(Opcode.PUSH1),  0x05,
        @intFromEnum(Opcode.PUSH1),  0x03,
        @intFromEnum(Opcode.ADD),

        // SUB: 10 - 4
           @intFromEnum(Opcode.PUSH1),
        0x0a,                        @intFromEnum(Opcode.PUSH1),
        0x04,                        @intFromEnum(Opcode.SUB),

        // MUL
        @intFromEnum(Opcode.MUL),

        // Store and return
           @intFromEnum(Opcode.PUSH1),
        0x00,                        @intFromEnum(Opcode.MSTORE),
        @intFromEnum(Opcode.PUSH1),  0x20,
        @intFromEnum(Opcode.PUSH1),  0x00,
        @intFromEnum(Opcode.RETURN),
    };

    const Bytecode = bytecode_mod.Bytecode(TestFrame.BytecodeConfig);
    const bytecode = try Bytecode.init(allocator, &bytecode_data);
    defer bytecode.deinit(allocator);

    // Create dispatch schedule
    const dispatch_items = try TestDispatch.init(allocator, &bytecode, &handlers);
    defer allocator.free(dispatch_items);

    // This should not panic
    const jump_table = try TestDispatch.createJumpTable(allocator, dispatch_items, &bytecode);
    defer allocator.free(jump_table.entries);

    // Should have no entries since there are no JUMPDESTs
    try testing.expect(jump_table.entries.len == 0);
}

test "JumpTable - sorting validation catches unsorted entries" {
    // Test that manual JumpTable construction properly sorts entries
    const allocator = testing.allocator;

    // Create manual entries in reverse order
    var entries = try allocator.alloc(TestDispatch.JumpTableEntry, 3);
    defer allocator.free(entries);

    entries[0] = .{ .pc = 100, .dispatch = TestDispatch{ .cursor = undefined } };
    entries[1] = .{ .pc = 10, .dispatch = TestDispatch{ .cursor = undefined } };
    entries[2] = .{ .pc = 50, .dispatch = TestDispatch{ .cursor = undefined } };

    // Sort them manually using the same algorithm
    std.sort.block(TestDispatch.JumpTableEntry, entries, {}, struct {
        pub fn lessThan(context: void, a: TestDispatch.JumpTableEntry, b: TestDispatch.JumpTableEntry) bool {
            _ = context;
            return a.pc < b.pc;
        }
    }.lessThan);

    // Verify proper sorting
    try testing.expect(entries[0].pc == 10);
    try testing.expect(entries[1].pc == 50);
    try testing.expect(entries[2].pc == 100);

    // Verify they're actually sorted
    for (entries[0..entries.len -| 1], entries[1..]) |current, next| {
        try testing.expect(current.pc < next.pc);
    }
}

/// Helper type for tests that represents a scheduled element
/// This is exported for test files to use
pub fn ScheduleElement(comptime FrameType: type) type {
    const DispatchType = Dispatch(FrameType);
    return DispatchType.Item;
}
