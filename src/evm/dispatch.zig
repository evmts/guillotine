const std = @import("std");
const Opcode = @import("opcode_data.zig").Opcode;
const OpcodeSynthetic = @import("opcode_synthetic.zig").OpcodeSynthetic;
const bytecode_mod = @import("bytecode.zig");
const ArrayList = std.ArrayListAligned;
const dispatch_metadata = @import("dispatch_metadata.zig");
const dispatch_item = @import("dispatch_item.zig");
const dispatch_jump_table = @import("dispatch_jump_table.zig");
const dispatch_jump_table_builder = @import("dispatch_jump_table_builder.zig");

// See issue #650 for dispatch optimization opportunities
// Currently our architecture assumes 64 byte cpu. It will still be functional for 32 byte cpu or 128 byte cpu but potentially not optimal
// In future we should consider benchmarking other cpu architectures. It's possible we want our metadata to be dynamic based on usize
// For example, we might want to only store 32 byte inline values on a 32 byte machines rather than 64
// THis can easily be done by just using the comptime FrameType

/// Dispatch manages the execution flow of EVM opcodes through an optimized instruction stream.
/// It converts bytecode into a cache-efficient array of function pointers and metadata,
/// enabling high-performance execution with minimal branch misprediction.
///
/// The dispatch mechanism uses tail-call optimization to jump between opcode handlers,
/// keeping hot data in CPU cache and maintaining predictable memory access patterns.
///
/// Here is what the data structure looks like in pseudocode
///
///
/// const cursors: []const u64 = [pushPointer, thePushValueAsMetadata, pushPointer, thePushValueAsMetadata, addPointer, returnPointer]
///
/// Because bytecode usually flows from left to right creating a heterogenous array of pointers and metadata is highly cache efficient
/// The CPU will most of the time load the metadata or function pointer it needs into the cache just because it's the next sequential item
///
/// Opcode handlers execute their functionality and then call the next opcode. For example, ADD will pop 2 items off the stock, add them, push
/// to the stack and then do a @call(.tailcall_only, next_cursor, {frame, next_cursor}) where next_cursor is just current_cursor + 1
///
/// @param FrameType - The stack frame type that will execute the opcodes
/// @return A struct type containing dispatch functionality for the given frame type
pub fn Dispatch(comptime FrameType: type) type {
    return struct {
        const Self = @This();

        // Import metadata types from dispatch_metadata module
        const Metadata = dispatch_metadata.DispatchMetadata(FrameType);
        
        /// Define Item inline to avoid circular dependency
        pub const Item = union {
            /// Most items are function pointers to an opcode handler
            opcode_handler: *const fn (frame: *FrameType, cursor: [*]const Item) FrameType.Error!noreturn,
            /// Some opcode handlers are followed by metadata specific to that opcode
            jump_dest: Metadata.JumpDestMetadata,
            push_inline: Metadata.PushInlineMetadata,
            push_pointer: Metadata.PushPointerMetadata,
            pc: Metadata.PcMetadata,
            first_block_gas: Metadata.FirstBlockMetadata,
        };
        
        /// The shared interface of any opcode handler
        const OpcodeHandler = @TypeOf(@as(Item, undefined).opcode_handler);

        /// Structure to track memory allocations during schedule creation
        const AllocatedMemory = struct {
            pointers: ArrayList(*FrameType.WordType, null),

            fn init() AllocatedMemory {
                return .{
                    .pointers = ArrayList(*FrameType.WordType, null){},
                };
            }

            fn deinit(self: *AllocatedMemory, allocator: std.mem.Allocator) void {
                for (self.pointers.items) |ptr| {
                    allocator.destroy(ptr);
                }
                self.pointers.deinit(allocator);
            }
        };

        /// Process a regular opcode and add to schedule
        fn processRegularOpcode(
            schedule_items: *ArrayList(Self.Item, null),
            allocator: std.mem.Allocator,
            opcode_handlers: *const [256]OpcodeHandler,
            data: anytype,
            instr_pc: anytype,
        ) !void {
            const handler = opcode_handlers.*[data.opcode];
            try schedule_items.append(allocator, .{ .opcode_handler = handler });

            if (data.opcode == @intFromEnum(Opcode.PC)) {
                try schedule_items.append(allocator, .{ .pc = .{ .value = @intCast(instr_pc) } });
            } else if (data.opcode == @intFromEnum(Opcode.JUMP) or data.opcode == @intFromEnum(Opcode.JUMPI)) {
                // JUMP/JUMPI need access to jump table - store placeholder that will be filled later
                try schedule_items.append(allocator, .{ .jump_dest = .{ .gas = 0, .min_stack = 0, .max_stack = 0 } });
            }
        }

        /// Process a PUSH opcode and add to schedule
        fn processPushOpcode(
            schedule_items: anytype,
            allocator: std.mem.Allocator,
            allocated_memory: *AllocatedMemory,
            opcode_handlers: *const [256]OpcodeHandler,
            data: anytype,
        ) !void {
            const push_opcode = 0x60 + data.size - 1; // PUSH1 = 0x60, PUSH2 = 0x61, etc.

            try schedule_items.append(allocator, .{ .opcode_handler = opcode_handlers.*[push_opcode] });

            if (data.size <= 8 and data.value <= std.math.maxInt(u64)) {
                // Inline value for small pushes that fit in u64
                const inline_value: u64 = @intCast(data.value);
                try schedule_items.append(allocator, .{ .push_inline = .{ .value = inline_value } });
            } else {
                // Pointer to value for large pushes
                const value_ptr = try allocator.create(FrameType.WordType);
                errdefer allocator.destroy(value_ptr);
                value_ptr.* = data.value;
                try allocated_memory.pointers.append(allocator, value_ptr);
                try schedule_items.append(allocator, .{ .push_pointer = .{ .value = value_ptr } });
            }
        }

        /// The optimized instruction stream containing opcode handlers and their metadata.
        /// Each item is exactly 64 bits for optimal cache line usage.
        ///
        /// Layout example: [push_ptr, push_value_as_metadata, push_ptr, push_value_as_metadata, add_ptr, return_ptr]
        ///
        /// Critical safety/performance property: Always terminated with 2 STOP handlers so accessing cursor[n+1]
        /// or cursor[n+2] is safe without bounds checking.
        cursor: [*]const Item,

        // ========================
        // Metadata Types
        // ========================
        // Re-export metadata types for convenience
        pub const JumpDestMetadata = Metadata.JumpDestMetadata;
        pub const FirstBlockMetadata = Metadata.FirstBlockMetadata;
        pub const PushInlineMetadata = Metadata.PushInlineMetadata;
        pub const PushPointerMetadata = Metadata.PushPointerMetadata;
        pub const PcMetadata = Metadata.PcMetadata;

        // Performance note: JumpTable is a compact array of structs rather than a sparse bitmap. A sparse bitmap would provide O(1) lookups
        // But at the cost of cpu cache utilization. For the scale of how many jump destinations contracts have it is more performant to
        // Create a compact data structure where all to most of the items fit in a single cache line and can be quickly binary searched
        /// Jump table for dynamic JUMP/JUMPI operations
        /// Sorted array of jump destinations for binary search lookup
        /// Most jumps are done with known constants and validated at analysis time with the jump location pushed as trusted metadata
        /// If a jump is done dynamically based on the stack value at runtime (rare) we then rely on dynamically finding the jump destination
        pub const JumpTable = dispatch_jump_table.JumpTable(FrameType, Self);

        // ========================
        // Metadata Access Methods
        // ========================
        // To prevent details of how dispatch structures it's instruction stream from being tightly coupled throughout
        // The entire EVM we encapsulate how to get the next opcode or how to get metadata into opaque methods that hide
        // the details of how the stream is structured.

        /// Unified opcode enum that combines regular and synthetic opcodes
        pub const UnifiedOpcode = union(enum) {
            regular: Opcode,
            synthetic: OpcodeSynthetic,

            /// Convert from regular Opcode
            pub fn fromOpcode(opcode: Opcode) UnifiedOpcode {
                return .{ .regular = opcode };
            }

            /// Convert from synthetic OpcodeSynthetic
            pub fn fromSynthetic(opcode: OpcodeSynthetic) UnifiedOpcode {
                return .{ .synthetic = opcode };
            }
        };

        /// A generic type that casts the 64 byte value to the correct type depending on the opcode
        /// NOTE: The metadata is not tagged (to save cacheline space) so this working safely depends on us always
        /// Constructing the instruction stream correctly with the expected metadata consistentally in the expected spots based on opcode!
        /// We also assume every opcode will correctly pass in the correct enum type for their opcode
        fn GetOpDataReturnType(comptime opcode: UnifiedOpcode) type {
            return switch (opcode) {
                .regular => |op| switch (op) {
                    .PC => struct { metadata: PcMetadata, next: Self },
                    .PUSH1, .PUSH2, .PUSH3, .PUSH4, .PUSH5, .PUSH6, .PUSH7, .PUSH8 => struct { metadata: PushInlineMetadata, next: Self },
                    .PUSH9, .PUSH10, .PUSH11, .PUSH12, .PUSH13, .PUSH14, .PUSH15, .PUSH16, .PUSH17, .PUSH18, .PUSH19, .PUSH20, .PUSH21, .PUSH22, .PUSH23, .PUSH24, .PUSH25, .PUSH26, .PUSH27, .PUSH28, .PUSH29, .PUSH30, .PUSH31, .PUSH32 => struct { metadata: PushPointerMetadata, next: Self },
                    .JUMPDEST => struct { metadata: JumpDestMetadata, next: Self },
                    else => struct { next: Self },
                },
                .synthetic => |op| switch (op) {
                    .PUSH_ADD_INLINE, .PUSH_MUL_INLINE, .PUSH_DIV_INLINE, .PUSH_SUB_INLINE, .PUSH_AND_INLINE, .PUSH_OR_INLINE, .PUSH_XOR_INLINE, .PUSH_JUMP_INLINE, .PUSH_JUMPI_INLINE, .PUSH_MLOAD_INLINE, .PUSH_MSTORE_INLINE, .PUSH_MSTORE8_INLINE => struct { metadata: PushInlineMetadata, next: Self },
                    .PUSH_ADD_POINTER, .PUSH_MUL_POINTER, .PUSH_DIV_POINTER, .PUSH_SUB_POINTER, .PUSH_AND_POINTER, .PUSH_OR_POINTER, .PUSH_XOR_POINTER, .PUSH_JUMP_POINTER, .PUSH_JUMPI_POINTER, .PUSH_MLOAD_POINTER, .PUSH_MSTORE_POINTER, .PUSH_MSTORE8_POINTER => struct { metadata: PushPointerMetadata, next: Self },
                },
            };
        }

        /// Get opcode data including metadata and next dispatch position.
        /// This is a comptime-optimized method for specific opcodes.
        pub fn getOpData(self: Self, comptime opcode: UnifiedOpcode) GetOpDataReturnType(opcode) {
            return switch (opcode) {
                .regular => |op| switch (op) {
                    .PC => .{
                        .metadata = self.cursor[1].pc,
                        .next = Self{ .cursor = self.cursor + 2 },
                    },
                    .PUSH1, .PUSH2, .PUSH3, .PUSH4, .PUSH5, .PUSH6, .PUSH7, .PUSH8 => .{
                        .metadata = self.cursor[1].push_inline,
                        .next = Self{ .cursor = self.cursor + 2 },
                    },
                    .PUSH9, .PUSH10, .PUSH11, .PUSH12, .PUSH13, .PUSH14, .PUSH15, .PUSH16, .PUSH17, .PUSH18, .PUSH19, .PUSH20, .PUSH21, .PUSH22, .PUSH23, .PUSH24, .PUSH25, .PUSH26, .PUSH27, .PUSH28, .PUSH29, .PUSH30, .PUSH31, .PUSH32 => .{
                        .metadata = self.cursor[1].push_pointer,
                        .next = Self{ .cursor = self.cursor + 2 },
                    },
                    .JUMPDEST => .{
                        .metadata = self.cursor[1].jump_dest,
                        .next = Self{ .cursor = self.cursor + 2 },
                    },
                    else => .{
                        .next = Self{ .cursor = self.cursor + 1 },
                    },
                },
                .synthetic => |op| switch (op) {
                    .PUSH_ADD_INLINE, .PUSH_MUL_INLINE, .PUSH_DIV_INLINE, .PUSH_SUB_INLINE, .PUSH_AND_INLINE, .PUSH_OR_INLINE, .PUSH_XOR_INLINE, .PUSH_JUMP_INLINE, .PUSH_JUMPI_INLINE, .PUSH_MLOAD_INLINE, .PUSH_MSTORE_INLINE, .PUSH_MSTORE8_INLINE => .{
                        .metadata = self.cursor[1].push_inline,
                        .next = Self{ .cursor = self.cursor + 2 },
                    },
                    .PUSH_ADD_POINTER, .PUSH_MUL_POINTER, .PUSH_DIV_POINTER, .PUSH_SUB_POINTER, .PUSH_AND_POINTER, .PUSH_OR_POINTER, .PUSH_XOR_POINTER, .PUSH_JUMP_POINTER, .PUSH_JUMPI_POINTER, .PUSH_MLOAD_POINTER, .PUSH_MSTORE_POINTER, .PUSH_MSTORE8_POINTER => .{
                        .metadata = self.cursor[1].push_pointer,
                        .next = Self{ .cursor = self.cursor + 2 },
                    },
                },
            };
        }

        /// Get first block gas metadata from the current position.
        /// Assumes the caller verified this is a first_block_gas item.
        pub fn getFirstBlockGas(self: Self) @TypeOf(@as(Self.Item, undefined).first_block_gas) {
            // Access the first_block_gas metadata directly
            return self.cursor[0].first_block_gas;
        }

        // ========================
        // Helper Functions
        // ========================

        /// Calculate gas cost for the first basic block of bytecode.
        /// Returns the total gas cost from the start until the first JUMPDEST, terminator opcode, or end of bytecode.
        pub fn calculateFirstBlockGas(bytecode: anytype) u64 {
            var gas: u64 = 0;
            var iter = bytecode.createIterator();
            const opcode_info = @import("opcode_data.zig").OPCODE_INFO;

            var op_count: u32 = 0;
            
            while (true) {
                const maybe = iter.next();
                if (maybe == null) break;
                const op_data = maybe.?;
                op_count += 1;

                switch (op_data) {
                    .regular => |data| {
                        const gas_to_add = @as(u64, opcode_info[data.opcode].gas_cost);
                        // Don't return maxInt on overflow - just return current gas
                        const new_gas = std.math.add(u64, gas, gas_to_add) catch gas;
                        gas = new_gas;
                        // Stop at JUMP/JUMPI/STOP/RETURN/REVERT/INVALID/SELFDESTRUCT
                        switch (data.opcode) {
                            0x56, 0x57, 0x00, 0xf3, 0xfd, 0xfe, 0xff => {
                                // Debug: log when we encounter a terminator
                                if (data.opcode == 0x57) {
                                    log.debug("calculateFirstBlockGas: Found JUMPI at op_count={}, gas={}", .{op_count, gas});
                                }
                                return gas;
                            },
                            else => {},
                        }
                    },
                    .push => |data| {
                        const push_opcode = 0x60 + data.size - 1;
                        const gas_to_add = @as(u64, opcode_info[push_opcode].gas_cost);
                        // Don't return maxInt on overflow - just return current gas
                        const new_gas = std.math.add(u64, gas, gas_to_add) catch gas;
                        gas = new_gas;
                    },
                    .jumpdest => {
                        // JUMPDEST terminates the block but its gas is not included
                        return gas;
                    },
                    .stop, .invalid => {
                        const gas_to_add = @as(u64, opcode_info[0x00].gas_cost); // STOP gas cost
                        gas = std.math.add(u64, gas, gas_to_add) catch gas;
                        return gas;
                    },
                    else => {
                        // For fusion operations, approximate gas cost
                        const new_gas = std.math.add(u64, gas, 6) catch gas;
                        gas = new_gas;
                    },
                }
            }

            // Log if gas consumption seems excessive
            if (gas > 10000 or op_count > 100) {
                // log.warn("calculateFirstBlockGas: First block gas={}, op_count={}, bytecode_len={}", .{ gas, op_count, bytecode.len() });
            }
            
            return gas;
        }

        // ========================
        // Initialization
        // ========================

        /// Create an optimized dispatch array from bytecode.
        ///
        /// This function analyzes the bytecode and generates an efficient instruction
        /// stream with inline metadata, leveraging opcode fusion opportunities.
        /// Returns just the schedule slice. For owning deallocation of auxiliary
        /// allocations (push pointers, code copies), use initWithOwnership/DispatchSchedule.
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
            // log.debug("Starting to parse bytecode with {} bytes", .{bytecode.runtime_code.len});

            const ScheduleList = ArrayList(Self.Item, null);
            var schedule_items = ScheduleList{};
            errdefer schedule_items.deinit(allocator);

            // Track allocated memory for cleanup
            var allocated_memory = AllocatedMemory.init();
            errdefer allocated_memory.deinit(allocator);

            // Create iterator to traverse bytecode
            var iter = bytecode.createIterator();

            // Calculate gas cost for first basic block
            const first_block_gas = calculateFirstBlockGas(bytecode);

            // Add first_block_gas entry if there's any gas to charge
            if (first_block_gas > 0) {
                try schedule_items.append(allocator, .{ .first_block_gas = .{ .gas = @intCast(first_block_gas) } });
                // log.debug("Added first_block_gas: {d}", .{first_block_gas});
                // TEMPORARY DEBUG: Log expected gas for our test bytecode
                if (bytecode.runtime_code.len == 38) { // Our specific test case
                    // log.warn("DEBUG: This looks like PUSH32+PUSH1+SDIV bytecode, first_block_gas={}", .{first_block_gas});
                }
            }

            var opcode_count: usize = 0;
            while (true) {
                const instr_pc = iter.pc;
                const maybe = iter.next();
                if (maybe == null) {
                    break;
                }
                const op_data = maybe.?;
                opcode_count += 1;

                // DEBUG: Log all opcodes being parsed
                // Commented out for performance

                switch (op_data) {
                    .regular => |data| {
                        // DEBUG: Log specific opcodes we're interested in
                        if (data.opcode == 0x08) {
                            // log.debug("DISPATCH DEBUG: Found ADDMOD (0x08) at PC {d}, adding handler", .{instr_pc});
                        } else if (data.opcode == 0x09) {
                            // log.debug("DISPATCH DEBUG: Found MULMOD (0x09) at PC {d}, adding handler", .{instr_pc});
                        } else if (data.opcode == 0x0a) {
                            // log.debug("DISPATCH DEBUG: Found EXP (0x0a) at PC {d}, adding handler", .{instr_pc});
                        }

                        // Also log ALL opcodes to see what we're parsing
                        // log.debug("DISPATCH DEBUG: Parsing opcode 0x{x:0>2} at PC {d}", .{ data.opcode, instr_pc });

                        try processRegularOpcode(&schedule_items, allocator, opcode_handlers, data, instr_pc);
                    },
                    .push => |data| {
                        try processPushOpcode(&schedule_items, allocator, &allocated_memory, opcode_handlers, data);
                    },
                    .jumpdest => |data| {
                        // JUMPDEST - add handler first, then metadata
                        try schedule_items.append(allocator, .{ .opcode_handler = opcode_handlers.*[@intFromEnum(Opcode.JUMPDEST)] });
                        try schedule_items.append(allocator, .{ .jump_dest = .{ .gas = data.gas_cost } });
                    },
                    .push_add_fusion => |data| {
                        try Self.handleFusionOperation(&schedule_items, allocator, &allocated_memory, data.value, .push_add);
                    },
                    .push_mul_fusion => |data| {
                        try Self.handleFusionOperation(&schedule_items, allocator, &allocated_memory, data.value, .push_mul);
                    },
                    .push_sub_fusion => |data| {
                        try Self.handleFusionOperation(&schedule_items, allocator, &allocated_memory, data.value, .push_sub);
                    },
                    .push_div_fusion => |data| {
                        try Self.handleFusionOperation(&schedule_items, allocator, &allocated_memory, data.value, .push_div);
                    },
                    .push_and_fusion => |data| {
                        try Self.handleFusionOperation(&schedule_items, allocator, &allocated_memory, data.value, .push_and);
                    },
                    .push_or_fusion => |data| {
                        try Self.handleFusionOperation(&schedule_items, allocator, &allocated_memory, data.value, .push_or);
                    },
                    .push_xor_fusion => |data| {
                        try Self.handleFusionOperation(&schedule_items, allocator, &allocated_memory, data.value, .push_xor);
                    },
                    .push_jump_fusion => |data| {
                        try Self.handleFusionOperation(&schedule_items, allocator, &allocated_memory, data.value, .push_jump);
                    },
                    .push_jumpi_fusion => |data| {
                        try Self.handleFusionOperation(&schedule_items, allocator, &allocated_memory, data.value, .push_jumpi);
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
            return final_schedule;
        }

        /// Result that carries both schedule items and ownership of associated allocations.
        pub const BuildOwned = struct {
            items: []Self.Item,
            push_pointers: []*FrameType.WordType,
        };

        /// Build schedule and return ownership of auxiliary allocations for safe deallocation.
        pub fn initWithOwnership(
            allocator: std.mem.Allocator,
            bytecode: anytype,
            opcode_handlers: *const [256]OpcodeHandler,
        ) !BuildOwned {

            const ScheduleList = ArrayList(Self.Item, null);
            var schedule_items = ScheduleList{};
            errdefer schedule_items.deinit(allocator);

            var allocated_memory = AllocatedMemory.init();
            errdefer allocated_memory.deinit(allocator);

            var iter = bytecode.createIterator();
            const first_block_gas = calculateFirstBlockGas(bytecode);
            if (first_block_gas > 0) {
                try schedule_items.append(allocator, .{ .first_block_gas = .{ .gas = @intCast(first_block_gas) } });
                // log.debug("Added first_block_gas: {d}", .{first_block_gas});
            }

            var opcode_count: usize = 0;
            while (true) {
                const instr_pc = iter.pc;
                const maybe = iter.next();
                if (maybe == null) break;
                const op_data = maybe.?;
                opcode_count += 1;

                switch (op_data) {
                    .regular => |data| try processRegularOpcode(&schedule_items, allocator, opcode_handlers, data, instr_pc),
                    .push => |data| try processPushOpcode(&schedule_items, allocator, &allocated_memory, opcode_handlers, data),
                    .jumpdest => |data| {
                        try schedule_items.append(allocator, .{ .opcode_handler = opcode_handlers.*[@intFromEnum(Opcode.JUMPDEST)] });
                        try schedule_items.append(allocator, .{ .jump_dest = .{ .gas = data.gas_cost } });
                    },
                    .push_add_fusion => |data| try Self.handleFusionOperation(&schedule_items, allocator, &allocated_memory, data.value, .push_add),
                    .push_mul_fusion => |data| try Self.handleFusionOperation(&schedule_items, allocator, &allocated_memory, data.value, .push_mul),
                    .push_sub_fusion => |data| try Self.handleFusionOperation(&schedule_items, allocator, &allocated_memory, data.value, .push_sub),
                    .push_div_fusion => |data| try Self.handleFusionOperation(&schedule_items, allocator, &allocated_memory, data.value, .push_div),
                    .push_and_fusion => |data| try Self.handleFusionOperation(&schedule_items, allocator, &allocated_memory, data.value, .push_and),
                    .push_or_fusion => |data| try Self.handleFusionOperation(&schedule_items, allocator, &allocated_memory, data.value, .push_or),
                    .push_xor_fusion => |data| try Self.handleFusionOperation(&schedule_items, allocator, &allocated_memory, data.value, .push_xor),
                    .push_jump_fusion => |data| try Self.handleFusionOperation(&schedule_items, allocator, &allocated_memory, data.value, .push_jump),
                    .push_jumpi_fusion => |data| try Self.handleFusionOperation(&schedule_items, allocator, &allocated_memory, data.value, .push_jumpi),
                    .stop => try schedule_items.append(allocator, .{ .opcode_handler = opcode_handlers.*[@intFromEnum(Opcode.STOP)] }),
                    .invalid => try schedule_items.append(allocator, .{ .opcode_handler = opcode_handlers.*[@intFromEnum(Opcode.INVALID)] }),
                }
            }

            try schedule_items.append(allocator, .{ .opcode_handler = opcode_handlers.*[@intFromEnum(Opcode.STOP)] });
            try schedule_items.append(allocator, .{ .opcode_handler = opcode_handlers.*[@intFromEnum(Opcode.STOP)] });

            const items = try schedule_items.toOwnedSlice(allocator);
            const push_ptrs = try allocated_memory.pointers.toOwnedSlice(allocator);
            // allocated_memory's arrays are now owned by slices; prevent double free
            allocated_memory = AllocatedMemory.init();
            return BuildOwned{ .items = items, .push_pointers = push_ptrs };
        }

        /// Helper function to handle fusion operations consistently.
        /// This reduces code duplication and centralizes fusion logic.
        fn handleFusionOperation(
            schedule_items: anytype,
            allocator: std.mem.Allocator,
            allocated_memory: *AllocatedMemory,
            value: FrameType.WordType,
            fusion_type: FusionType,
        ) !void {
            // Use proper synthetic opcode handler based on value size and fusion type
            const synthetic_opcode = getSyntheticOpcode(fusion_type, value <= std.math.maxInt(u64));
            const frame_handlers = @import("frame_handlers.zig");
            const synthetic_handler = frame_handlers.getSyntheticHandler(FrameType, synthetic_opcode);
            try schedule_items.append(allocator, .{ .opcode_handler = synthetic_handler });

            if (value <= std.math.maxInt(u64)) {
                const inline_val: u64 = @intCast(value);
                try schedule_items.append(allocator, .{ .push_inline = .{ .value = inline_val } });
            } else {
                const value_ptr = try allocator.create(FrameType.WordType);
                errdefer allocator.destroy(value_ptr);
                value_ptr.* = value;
                try allocated_memory.pointers.append(allocator, value_ptr);
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
            // log.debug("createJumpTable starting, schedule len: {}, bytecode len: {}", .{ schedule.len, bytecode.len() });

            var builder = JumpTableBuilder.init(allocator);
            defer builder.deinit();

            // Build from schedule without tracing considerations
            try builder.buildFromSchedule(schedule, bytecode);

            // Use finalizeWithSchedule to set dispatch pointers correctly
            const jump_table = try builder.finalizeWithSchedule(schedule);

            // Validate sorting (debug builds only)
            if (std.debug.runtime_safety and jump_table.entries.len > 1) {
                for (jump_table.entries[0..jump_table.entries.len -| 1], jump_table.entries[1..]) |current, next| {
                    if (current.pc >= next.pc) {
                        std.debug.panic("JumpTable not properly sorted: PC {} >= {}", .{ current.pc, next.pc });
                    }
                }
            }

            return jump_table;
        }

        /// Clean up heap-allocated push pointer values and bytecode copies in the schedule
        /// Since Item is an untagged union here, we cannot introspect metadata variants.
        /// This retains the current behavior of freeing only the schedule slice.
        pub fn deinitSchedule(allocator: std.mem.Allocator, schedule: []const Item) void {
            allocator.free(schedule);
        }

        /// RAII wrapper for dispatch schedule that automatically cleans up push pointers
        pub const DispatchSchedule = struct {
            items: []Item,
            allocator: std.mem.Allocator,
            push_pointers: []const *FrameType.WordType = &.{},

            /// Initialize a dispatch schedule from bytecode with automatic cleanup
            pub fn init(allocator: std.mem.Allocator, bytecode: anytype, opcode_handlers: *const [256]OpcodeHandler) !DispatchSchedule {
                const owned = try Self.initWithOwnership(allocator, bytecode, opcode_handlers);
                return DispatchSchedule{
                    .items = owned.items,
                    .allocator = allocator,
                    .push_pointers = owned.push_pointers,
                };
            }

            /// Clean up the schedule including all heap-allocated push pointers
            pub fn deinit(self: *DispatchSchedule) void {
                // Free push pointers
                for (self.push_pointers) |ptr| {
                    self.allocator.destroy(ptr);
                }
                if (self.push_pointers.len > 0) self.allocator.free(self.push_pointers);

                // Free schedule itself
                Self.deinitSchedule(self.allocator, self.items);
            }

            /// Get a Dispatch instance pointing to the start of the schedule
            pub fn getDispatch(self: *const DispatchSchedule) Self {
                return Self{
                    .cursor = self.items.ptr,
                };
            }
        };

        /// Iterator for traversing schedule alongside bytecode
        pub const ScheduleIterator = struct {
            schedule: []const Item,
            bytecode: *const anyopaque,
            pc: FrameType.PcType = 0,
            schedule_index: usize = 0,

            pub const Entry = struct {
                pc: FrameType.PcType,
                schedule_index: usize,
                op_data: enum { regular, push, jumpdest, stop, invalid, fusion },
            };

            pub fn init(schedule: []const Item, bytecode: anytype) ScheduleIterator {
                return .{
                    .schedule = schedule,
                    .bytecode = bytecode,
                    .pc = 0,
                    .schedule_index = 0,
                };
            }

            pub fn next(self: *ScheduleIterator) ?Entry {
                if (self.schedule_index >= self.schedule.len) return null;

                // Skip first_block_gas if present
                if (self.schedule_index == 0) {
                    // First_block_gas is only added if calculateFirstBlockGas(bytecode) > 0
                    const first_block_gas = calculateFirstBlockGas(self.bytecode);
                    if (first_block_gas > 0) {
                        self.schedule_index = 1;
                        if (self.schedule_index >= self.schedule.len) return null;
                    }
                }

                const current_pc = self.pc;
                const current_index = self.schedule_index;

                // Determine operation type from schedule
                const item = self.schedule[self.schedule_index];
                const op_type: Entry.op_data = switch (item) {
                    .opcode_handler => blk: {
                        // Look at the actual bytecode to determine type
                        // This is simplified - in real implementation would need proper bytecode access
                        break :blk .regular;
                    },
                    .jump_dest => .jumpdest,
                    .push_inline, .push_pointer => .push,
                    else => .regular,
                };

                // Advance schedule index
                self.schedule_index += 1;

                // Skip metadata items
                if (self.schedule_index < self.schedule.len) {
                    switch (self.schedule[self.schedule_index]) {
                        .jump_dest, .push_inline, .push_pointer, .pc => {
                            self.schedule_index += 1;
                        },
                        else => {},
                    }
                }

                // Update PC based on operation type
                // This is simplified - would need actual bytecode parsing
                self.pc += 1;

                return Entry{
                    .pc = current_pc,
                    .schedule_index = current_index,
                    .op_data = op_type,
                };
            }
        };

        /// Builder for creating jump tables with improved error handling
        pub const JumpTableBuilder = dispatch_jump_table_builder.JumpTableBuilder(FrameType, Self);

        /// Pretty print the dispatch instruction stream in a human-readable format
        /// Shows both the original bytecode and the optimized instruction stream
        /// Returns an allocated string that must be freed by the caller
        pub fn pretty_print(allocator: std.mem.Allocator, schedule: []const Item, bytecode: anytype) ![]u8 {
            var output = std.ArrayListAligned(u8, null){
                .items = &.{},
                .capacity = 0,
            };
            defer output.deinit(allocator);

            // ANSI color codes for formatting
            const Colors = struct {
                const reset = "\x1b[0m";
                const bold = "\x1b[1m";
                const dim = "\x1b[2m";
                const red = "\x1b[31m";
                const green = "\x1b[32m";
                const yellow = "\x1b[33m";
                const blue = "\x1b[34m";
                const magenta = "\x1b[35m";
                const cyan = "\x1b[36m";
                const white = "\x1b[37m";
                const bright_red = "\x1b[91m";
                const bright_green = "\x1b[92m";
                const bright_yellow = "\x1b[93m";
                const bright_blue = "\x1b[94m";
                const bright_magenta = "\x1b[95m";
                const bright_cyan = "\x1b[96m";
            };

            // Header
            try output.writer(allocator).print("{s}=== EVM Dispatch Instruction Stream ==={s}\n", .{ Colors.bold, Colors.reset });
            try output.writer(allocator).print("{s}Original bytecode: {} bytes, Dispatch items: {}{s}\n\n", .{ Colors.dim, bytecode.runtime_code.len, schedule.len, Colors.reset });

            // Section showing original bytecode
            try output.writer(allocator).print("{s}--- Original Bytecode ---{s}\n", .{ Colors.bold, Colors.reset });
            if (bytecode.runtime_code.len > 0) {
                const runtime_code = bytecode.runtime_code;
                var bytecode_pc: FrameType.PcType = 0;
                while (bytecode_pc < runtime_code.len) {
                    const opcode_byte = runtime_code[bytecode_pc];

                    // Show PC and hex
                    try output.writer(allocator).print("{s}0x{x:0>4}:{s} {s}{x:0>2}{s}", .{ Colors.cyan, bytecode_pc, Colors.reset, Colors.dim, opcode_byte, Colors.reset });

                    // Try to interpret the opcode
                    if (std.meta.intToEnum(Opcode, opcode_byte)) |opcode| {
                        try output.writer(allocator).print("  {s}{s}{s}", .{ Colors.white, @tagName(opcode), Colors.reset });

                        // Handle PUSH instructions specially
                        switch (opcode) {
                            .PUSH1, .PUSH2, .PUSH3, .PUSH4, .PUSH5, .PUSH6, .PUSH7, .PUSH8, .PUSH9, .PUSH10, .PUSH11, .PUSH12, .PUSH13, .PUSH14, .PUSH15, .PUSH16, .PUSH17, .PUSH18, .PUSH19, .PUSH20, .PUSH21, .PUSH22, .PUSH23, .PUSH24, .PUSH25, .PUSH26, .PUSH27, .PUSH28, .PUSH29, .PUSH30, .PUSH31, .PUSH32 => {
                                const push_size = @intFromEnum(opcode) - @intFromEnum(Opcode.PUSH1) + 1;
                                var value: u256 = 0;
                                const end_pc = @min(bytecode_pc + 1 + push_size, @as(FrameType.PcType, @intCast(runtime_code.len)));

                                // Collect push data
                                try output.writer(allocator).print(" {s}", .{Colors.bright_magenta});
                                for (bytecode_pc + 1..end_pc) |i| {
                                    value = (value << 8) | runtime_code[i];
                                    try output.writer(allocator).print("{x:0>2}", .{runtime_code[i]});
                                }
                                try output.writer(allocator).print("{s} {s}(0x{x}){s}", .{ Colors.reset, Colors.dim, value, Colors.reset });

                                bytecode_pc = end_pc;
                                continue;
                            },
                            else => {},
                        }
                    } else |_| {
                        try output.writer(allocator).print("  {s}INVALID{s}", .{ Colors.bright_red, Colors.reset });
                    }

                    try output.writer(allocator).print("\n", .{});
                    bytecode_pc += 1;
                }
            } else {
                try output.writer(allocator).print("{s}(empty){s}\n", .{ Colors.dim, Colors.reset });
            }

            // Section showing dispatch instruction stream
            try output.writer(allocator).print("\n{s}--- Dispatch Instruction Stream ---{s}\n", .{ Colors.bold, Colors.reset });

            var i: usize = 0;
            while (i < schedule.len) {
                // Item index and address
                try output.writer(allocator).print("{s}[{d:3}]:{s} {s}@{*}{s} ", .{ Colors.dim, i, Colors.reset, Colors.cyan, &schedule[i], Colors.reset });

                // For now, just show as handler or metadata based on index patterns
                // (handlers are typically followed by metadata)
                try output.writer(allocator).print("{s}ITEM{s}", .{ Colors.blue, Colors.reset });

                try output.writer(allocator).print("\n", .{});
                i += 1;
            }

            // Summary section
            try output.writer(allocator).print("\n{s}--- Summary ---{s}\n", .{ Colors.bold, Colors.reset });

            const total_items = schedule.len;

            try output.writer(allocator).print("{s}Total dispatch items: {}{s}\n", .{ Colors.dim, total_items, Colors.reset });
            try output.writer(allocator).print("{s}Compression ratio: {d:.2}x (bytecode:{} -> dispatch:{}){s}\n", .{ Colors.dim, if (schedule.len > 0) @as(f64, @floatFromInt(bytecode.runtime_code.len)) / @as(f64, @floatFromInt(schedule.len)) else 0.0, bytecode.runtime_code.len, schedule.len, Colors.reset });

            return output.toOwnedSlice(allocator);
        }
    };
}

// ============================
// Test Support
// ============================

/// Helper type for tests that represents a scheduled element
/// This is exported for test files to use
pub fn ScheduleElement(comptime FrameType: type) type {
    const DispatchType = Dispatch(FrameType);
    return DispatchType.Item;
}
