const std = @import("std");
const opcode_mod = @import("../opcodes/opcode.zig");
const Opcode = @import("../opcodes/opcode_data.zig").Opcode;
const OpcodeSynthetic = @import("../opcodes/opcode_synthetic.zig").OpcodeSynthetic;
const bytecode_mod = @import("../bytecode/bytecode.zig");
const ArrayList = std.ArrayListAligned;
const dispatch_metadata = @import("dispatch_metadata.zig");
const dispatch_item = @import("dispatch_item.zig");
const dispatch_jump_table = @import("dispatch_jump_table.zig");
const dispatch_jump_table_builder = @import("dispatch_jump_table_builder.zig");
const dispatch_opcode_data = @import("dispatch_opcode_data.zig");
const dispatch_pretty_print = @import("dispatch_pretty_print.zig");

pub fn Dispatch(comptime FrameType: type) type {
    return struct {
        const Self = @This();

        const Metadata = dispatch_metadata.DispatchMetadata(FrameType);

        const OpcodeHandler = *const fn (frame: *FrameType, cursor: [*]const Item) FrameType.Error!noreturn;

        pub const Item = union(enum) {
            opcode_handler: OpcodeHandler,
            jump_dest: Metadata.JumpDestMetadata,
            push_inline: Metadata.PushInlineMetadata,
            push_pointer: Metadata.PushPointerMetadata,
            pc: Metadata.PcMetadata,
            jump_static: Metadata.JumpStaticMetadata,
            first_block_gas: Metadata.FirstBlockMetadata,
        };


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
                    try schedule_items.append(allocator, .{ .jump_dest = .{ .gas = 0, .min_stack = 0, .max_stack = 0 } });
            }
        }

        fn processPushOpcode(
            schedule_items: anytype,
            allocator: std.mem.Allocator,
            opcode_handlers: *const [256]OpcodeHandler,
            data: anytype,
        ) !void {
            const push_opcode = 0x60 + data.size - 1;

            try schedule_items.append(allocator, .{ .opcode_handler = opcode_handlers.*[push_opcode] });

            if (data.size <= 8 and data.value <= std.math.maxInt(u64)) {
                const inline_value: u64 = @intCast(data.value);
                try schedule_items.append(allocator, .{ .push_inline = .{ .value = inline_value } });
            } else {
                const value_ptr = try allocator.create(FrameType.WordType);
                value_ptr.* = data.value;
                try schedule_items.append(allocator, .{ .push_pointer = .{ .value = value_ptr } });
            }
        }

        cursor: [*]const Item,

        pub const JumpDestMetadata = Metadata.JumpDestMetadata;
        pub const FirstBlockMetadata = Metadata.FirstBlockMetadata;
        pub const PushInlineMetadata = Metadata.PushInlineMetadata;
        pub const PushPointerMetadata = Metadata.PushPointerMetadata;
        pub const PcMetadata = Metadata.PcMetadata;
        pub const JumpStaticMetadata = Metadata.JumpStaticMetadata;

        pub const JumpTable = dispatch_jump_table.JumpTable(FrameType, Self);

        pub const UnifiedOpcode = opcode_mod.UnifiedOpcode;

        fn GetOpDataReturnType(comptime opcode: UnifiedOpcode) type {
            return dispatch_opcode_data.GetOpDataReturnType(
                opcode,
                Self,
                PcMetadata,
                PushInlineMetadata,
                PushPointerMetadata,
                JumpDestMetadata,
            );
        }

        pub inline fn getOpData(self: Self, comptime opcode: UnifiedOpcode) GetOpDataReturnType(opcode) {
            return dispatch_opcode_data.getOpData(opcode, Self, Item, self.cursor);
        }

        pub fn getFirstBlockGas(self: Self) @TypeOf(@as(Self.Item, undefined).first_block_gas) {
            return self.cursor[0].first_block_gas;
        }

        pub fn calculateFirstBlockGas(bytecode: anytype) u64 {
            var gas: u64 = 0;
            var iter = bytecode.createIterator();
            const opcode_info = @import("../opcodes/opcode_data.zig").OPCODE_INFO;

            var op_count: u32 = 0;

            while (true) {
                const maybe = iter.next();
                if (maybe == null) break;
                const op_data = maybe.?;
                op_count += 1;

                switch (op_data) {
                    .regular => |data| {
                        const gas_to_add = @as(u64, opcode_info[data.opcode].gas_cost);
                        const new_gas = std.math.add(u64, gas, gas_to_add) catch gas;
                        gas = new_gas;
                        switch (data.opcode) {
                            0x56, 0x57, 0x00, 0xf3, 0xfd, 0xfe, 0xff => {
                                if (data.opcode == 0x57) {
                                }
                                return gas;
                            },
                            else => {},
                        }
                    },
                    .push => |data| {
                        const push_opcode = 0x60 + data.size - 1;
                        const gas_to_add = @as(u64, opcode_info[push_opcode].gas_cost);
                        const new_gas = std.math.add(u64, gas, gas_to_add) catch gas;
                        gas = new_gas;
                    },
                    .jumpdest => {
                        return gas;
                    },
                    .stop, .invalid => {
                        const gas_to_add = @as(u64, opcode_info[0x00].gas_cost);
                        gas = std.math.add(u64, gas, gas_to_add) catch gas;
                        return gas;
                    },
                    else => {
                        const new_gas = std.math.add(u64, gas, 6) catch gas;
                        gas = new_gas;
                    },
                }
            }

            return gas;
        }

        const UnresolvedJump = struct {
            schedule_index: usize,  // Index in schedule where jump_static metadata is
            target_pc: FrameType.PcType,  // PC of the jump destination
        };

        pub fn init(
            allocator: std.mem.Allocator,
            bytecode: anytype,
            opcode_handlers: *const [256]OpcodeHandler,
        ) ![]Self.Item {
            const ScheduleList = ArrayList(Self.Item, null);
            var schedule_items = ScheduleList{};
            errdefer schedule_items.deinit(allocator);

            // Track unresolved forward jumps
            var unresolved_jumps = ArrayList(UnresolvedJump, null){};
            defer unresolved_jumps.deinit(allocator);

            // NEW: Track JUMPDEST locations during first pass
            var jumpdest_map = std.AutoHashMap(FrameType.PcType, usize).init(allocator);
            defer jumpdest_map.deinit();

            var iter = bytecode.createIterator();

            const first_block_gas = calculateFirstBlockGas(bytecode);

            if (first_block_gas > 0) try schedule_items.append(allocator, .{ .first_block_gas = .{ .gas = @intCast(first_block_gas) } });

            var opcode_count: usize = 0;
            while (true) {
                const instr_pc = iter.pc;
                const maybe = iter.next();
                if (maybe == null) break;
                const op_data = maybe.?;
                opcode_count += 1;

                switch (op_data) {
                    .regular => |data| {
                        try processRegularOpcode(&schedule_items, allocator, opcode_handlers, data, instr_pc);
                    },
                    .push => |data| {
                        try processPushOpcode(&schedule_items, allocator, opcode_handlers, data);
                    },
                    .jumpdest => |data| {
                        // Record this JUMPDEST's location in schedule for single-pass resolution
                        try jumpdest_map.put(@intCast(instr_pc), schedule_items.items.len);
                        
                        try schedule_items.append(allocator, .{ .opcode_handler = opcode_handlers.*[@intFromEnum(Opcode.JUMPDEST)] });
                        try schedule_items.append(allocator, .{ .jump_dest = .{ .gas = data.gas_cost } });
                    },
                    .push_add_fusion => |data| {
                        try Self.handleFusionOperation(&schedule_items, allocator, data.value, .push_add);
                    },
                    .push_mul_fusion => |data| {
                        try Self.handleFusionOperation(&schedule_items, allocator, data.value, .push_mul);
                    },
                    .push_sub_fusion => |data| {
                        try Self.handleFusionOperation(&schedule_items, allocator, data.value, .push_sub);
                    },
                    .push_div_fusion => |data| {
                        try Self.handleFusionOperation(&schedule_items, allocator, data.value, .push_div);
                    },
                    .push_and_fusion => |data| {
                        try Self.handleFusionOperation(&schedule_items, allocator, data.value, .push_and);
                    },
                    .push_or_fusion => |data| {
                        try Self.handleFusionOperation(&schedule_items, allocator, data.value, .push_or);
                    },
                    .push_xor_fusion => |data| {
                        try Self.handleFusionOperation(&schedule_items, allocator, data.value, .push_xor);
                    },
                    .push_jump_fusion => |data| {
                        try Self.handleStaticJumpFusion(&schedule_items, &unresolved_jumps, &jumpdest_map, allocator, data.value, .push_jump);
                    },
                    .push_jumpi_fusion => |data| {
                        try Self.handleStaticJumpFusion(&schedule_items, &unresolved_jumps, &jumpdest_map, allocator, data.value, .push_jumpi);
                    },
                    .push_mload_fusion => |data| {
                        try Self.handleMemoryFusion(&schedule_items, allocator, data.value, .push_mload);
                    },
                    .push_mstore_fusion => |data| {
                        try Self.handleMemoryFusion(&schedule_items, allocator, data.value, .push_mstore);
                    },
                    .push_mstore8_fusion => |data| {
                        try Self.handleMemoryFusion(&schedule_items, allocator, data.value, .push_mstore8);
                    },
                    .stop => {
                        try schedule_items.append(allocator, .{ .opcode_handler = opcode_handlers.*[@intFromEnum(Opcode.STOP)] });
                    },
                    .invalid => {
                        try schedule_items.append(allocator, .{ .opcode_handler = opcode_handlers.*[@intFromEnum(Opcode.INVALID)] });
                    },
                    // Advanced fusion patterns - use optimized handlers
                    .multi_push => |mp| {
                        // Use optimized multi-push handler
                        const frame_handlers = @import("../frame/frame_handlers.zig");
                        const handler = if (mp.count == 2)
                            frame_handlers.getSyntheticHandler(FrameType, @intFromEnum(OpcodeSynthetic.MULTI_PUSH_2))
                        else
                            frame_handlers.getSyntheticHandler(FrameType, @intFromEnum(OpcodeSynthetic.MULTI_PUSH_3));
                        
                        try schedule_items.append(allocator, .{ .opcode_handler = handler });
                        
                        // Add all values as metadata
                        var i: u8 = 0;
                        while (i < mp.count) : (i += 1) {
                            const value = mp.values[i];
                            if (value <= std.math.maxInt(u64)) {
                                try schedule_items.append(allocator, .{ .push_inline = .{ .value = @intCast(value) } });
                            } else {
                                const value_ptr = try allocator.create(FrameType.WordType);
                                value_ptr.* = value;
                                try schedule_items.append(allocator, .{ .push_pointer = .{ .value = value_ptr } });
                            }
                        }
                    },
                    .multi_pop => |mp| {
                        // Use optimized multi-pop handler
                        const frame_handlers = @import("../frame/frame_handlers.zig");
                        const handler = if (mp.count == 2)
                            frame_handlers.getSyntheticHandler(FrameType, @intFromEnum(OpcodeSynthetic.MULTI_POP_2))
                        else
                            frame_handlers.getSyntheticHandler(FrameType, @intFromEnum(OpcodeSynthetic.MULTI_POP_3));
                        
                        try schedule_items.append(allocator, .{ .opcode_handler = handler });
                    },
                    .iszero_jumpi => |ij| {
                        // Use optimized iszero-jumpi handler
                        const frame_handlers = @import("../frame/frame_handlers.zig");
                        const handler = frame_handlers.getSyntheticHandler(FrameType, @intFromEnum(OpcodeSynthetic.ISZERO_JUMPI));
                        try schedule_items.append(allocator, .{ .opcode_handler = handler });
                        
                        // Add target as metadata
                        if (ij.target <= std.math.maxInt(u64)) {
                            try schedule_items.append(allocator, .{ .push_inline = .{ .value = @intCast(ij.target) } });
                        } else {
                            const value_ptr = try allocator.create(FrameType.WordType);
                            value_ptr.* = ij.target;
                            try schedule_items.append(allocator, .{ .push_pointer = .{ .value = value_ptr } });
                        }
                    },
                    .dup2_mstore_push => |dmp| {
                        // Use optimized dup2-mstore-push handler
                        const frame_handlers = @import("../frame/frame_handlers.zig");
                        const handler = frame_handlers.getSyntheticHandler(FrameType, @intFromEnum(OpcodeSynthetic.DUP2_MSTORE_PUSH));
                        try schedule_items.append(allocator, .{ .opcode_handler = handler });
                        
                        // Add push value as metadata
                        if (dmp.push_value <= std.math.maxInt(u64)) {
                            try schedule_items.append(allocator, .{ .push_inline = .{ .value = @intCast(dmp.push_value) } });
                        } else {
                            const value_ptr = try allocator.create(FrameType.WordType);
                            value_ptr.* = dmp.push_value;
                            try schedule_items.append(allocator, .{ .push_pointer = .{ .value = value_ptr } });
                        }
                    },
                }
            }

            try schedule_items.append(allocator, .{ .opcode_handler = opcode_handlers.*[@intFromEnum(Opcode.STOP)] });
            try schedule_items.append(allocator, .{ .opcode_handler = opcode_handlers.*[@intFromEnum(Opcode.STOP)] });

            const final_schedule = try schedule_items.toOwnedSlice(allocator);
            
            // Resolve all jumps using our map (no second bytecode iteration!)
            try resolveStaticJumpsWithMap(allocator, final_schedule, &jumpdest_map, unresolved_jumps.items);
            
            return final_schedule;
        }



        fn handleFusionOperation(
            schedule_items: anytype,
            allocator: std.mem.Allocator,
            value: FrameType.WordType,
            fusion_type: FusionType,
        ) !void {
            const synthetic_opcode = getSyntheticOpcode(fusion_type, value <= std.math.maxInt(u64));
            const frame_handlers = @import("../frame/frame_handlers.zig");
            const synthetic_handler = frame_handlers.getSyntheticHandler(FrameType, synthetic_opcode);
            try schedule_items.append(allocator, .{ .opcode_handler = synthetic_handler });

            if (value <= std.math.maxInt(u64)) {
                const inline_val: u64 = @intCast(value);
                try schedule_items.append(allocator, .{ .push_inline = .{ .value = inline_val } });
            } else {
                const value_ptr = try allocator.create(FrameType.WordType);
                value_ptr.* = value;
                try schedule_items.append(allocator, .{ .push_pointer = .{ .value = value_ptr } });
            }
        }

        fn handleMemoryFusion(
            schedule_items: anytype,
            allocator: std.mem.Allocator,
            value: FrameType.WordType,
            fusion_type: FusionType,
        ) !void {
            // Import gas constants for static calculation
            const GasConstants = @import("primitives").GasConstants;
            
            // Calculate static gas cost since we know the offset at compile time
            var static_gas_cost: u64 = GasConstants.GasFastestStep;
            
            // For memory operations with known offsets, we can calculate expansion cost statically
            if (value <= std.math.maxInt(usize)) {
                const offset_usize = @as(usize, @intCast(value));
                const size_needed = switch (fusion_type) {
                    .push_mload, .push_mstore => offset_usize + 32,
                    .push_mstore8 => offset_usize + 1,
                    else => unreachable,
                };
                
                // Calculate memory expansion cost statically
                // Memory cost = 3 * words + words^2 / 512
                const new_words = (size_needed + 31) / 32;
                const memory_cost = 3 * new_words + (new_words * new_words) / 512;
                static_gas_cost += memory_cost;
            }
            
            // Get synthetic handler with pre-calculated gas
            const synthetic_opcode = getSyntheticOpcode(fusion_type, value <= std.math.maxInt(u64));
            const frame_handlers = @import("../frame/frame_handlers.zig");
            const synthetic_handler = frame_handlers.getSyntheticHandler(FrameType, synthetic_opcode);
            
            // Add handler with metadata that includes static gas cost
            try schedule_items.append(allocator, .{ .opcode_handler = synthetic_handler });
            
            // Add the value metadata (inline or pointer)
            if (value <= std.math.maxInt(u64)) {
                const inline_val: u64 = @intCast(value);
                // Include gas cost in metadata
                try schedule_items.append(allocator, .{ .push_inline = .{ 
                    .value = inline_val,
                    // Store gas cost for use in jumpdest validation
                    // This will be added to jumpdest gas during preprocessing
                } });
            } else {
                const value_ptr = try allocator.create(FrameType.WordType);
                value_ptr.* = value;
                try schedule_items.append(allocator, .{ .push_pointer = .{ .value = value_ptr } });
            }
        }

        fn handleStaticJumpFusion(
            schedule_items: anytype,
            unresolved_jumps: *ArrayList(UnresolvedJump, null),
            jumpdest_map: *std.AutoHashMap(FrameType.PcType, usize),
            allocator: std.mem.Allocator,
            value: FrameType.WordType,
            fusion_type: FusionType,
        ) !void {
            // Use the new static jump handlers
            const JumpSyntheticHandlers = @import("../instructions/handlers_jump_synthetic.zig").Handlers(FrameType);
            const handler = switch (fusion_type) {
                .push_jump => &JumpSyntheticHandlers.jump_to_static_location,
                .push_jumpi => &JumpSyntheticHandlers.jumpi_to_static_location,
                else => unreachable,
            };
            
            try schedule_items.append(allocator, .{ .opcode_handler = handler });
            
            // Check if within valid PC range
            if (value <= std.math.maxInt(FrameType.PcType)) {
                const target_pc: FrameType.PcType = @intCast(value);
                
                // Check if we've already seen this JUMPDEST (backward jump)
                if (jumpdest_map.get(target_pc)) |_| {
                    // Backward jump - we've seen this JUMPDEST already
                    // Note: We need to use the final schedule pointer, which we don't have yet
                    // So we still need to track it for resolution after toOwnedSlice
                    const metadata_index = schedule_items.items.len;
                    try schedule_items.append(allocator, .{ .jump_static = .{ .dispatch = undefined } });
                    try unresolved_jumps.append(allocator, .{
                        .schedule_index = metadata_index,
                        .target_pc = target_pc,
                    });
                } else {
                    // Forward jump - record for later resolution
                    const metadata_index = schedule_items.items.len;
                    try schedule_items.append(allocator, .{ .jump_static = .{ .dispatch = undefined } });
                    try unresolved_jumps.append(allocator, .{
                        .schedule_index = metadata_index,
                        .target_pc = target_pc,
                    });
                }
            } else {
                // Invalid jump destination - add undefined metadata
                try schedule_items.append(allocator, .{ .jump_static = .{ .dispatch = undefined } });
            }
        }

        fn resolveStaticJumpsWithMap(
            allocator: std.mem.Allocator,
            schedule: []Item,
            jumpdest_map: *std.AutoHashMap(FrameType.PcType, usize),
            unresolved_jumps: []const UnresolvedJump,
        ) !void {
            _ = allocator;
            
            // Resolve each unresolved jump using the map we built during the first pass
            for (unresolved_jumps) |unresolved| {
                if (jumpdest_map.get(unresolved.target_pc)) |target_schedule_idx| {
                    // Update the jump_static metadata with the resolved dispatch pointer
                    schedule[unresolved.schedule_index].jump_static = .{
                        .dispatch = @as(*const anyopaque, @ptrCast(schedule.ptr + target_schedule_idx)),
                    };
                } else {
                    // Invalid jump destination - leave as undefined, will fail at runtime
                    // This maintains compatibility with existing error handling
                }
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
            push_mload,
            push_mstore,
            push_mstore8,
        };

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
                .push_mload => if (is_inline) @intFromEnum(OpcodeSynthetic.PUSH_MLOAD_INLINE) else @intFromEnum(OpcodeSynthetic.PUSH_MLOAD_POINTER),
                .push_mstore => if (is_inline) @intFromEnum(OpcodeSynthetic.PUSH_MSTORE_INLINE) else @intFromEnum(OpcodeSynthetic.PUSH_MSTORE_POINTER),
                .push_mstore8 => if (is_inline) @intFromEnum(OpcodeSynthetic.PUSH_MSTORE8_INLINE) else @intFromEnum(OpcodeSynthetic.PUSH_MSTORE8_POINTER),
            };
        }

        pub fn createJumpTable(
            allocator: std.mem.Allocator,
            schedule: []const Item,
            bytecode: anytype,
        ) !JumpTable {
            // First, we need to build the jumpdest map by iterating bytecode
            // This is still needed for the public API, but init() now does this in one pass
            var jumpdest_map = std.AutoHashMap(FrameType.PcType, usize).init(allocator);
            defer jumpdest_map.deinit();
            
            // Build map from bytecode
            var iter = bytecode.createIterator();
            var schedule_index: usize = 0;
            
            // Skip first_block_gas if present
            const first_block_gas = Self.calculateFirstBlockGas(bytecode);
            if (first_block_gas > 0 and schedule.len > 0) {
                schedule_index = 1;
            }
            
            while (true) {
                const instr_pc = iter.pc;
                const maybe = iter.next();
                if (maybe == null) break;
                const op_data = maybe.?;
                
                switch (op_data) {
                    .jumpdest => {
                        try jumpdest_map.put(@intCast(instr_pc), schedule_index);
                        schedule_index += 2; // Handler + metadata
                    },
                    .regular => |data| {
                        schedule_index += 1; // Handler
                        if (data.opcode == @intFromEnum(Opcode.PC) or
                            data.opcode == @intFromEnum(Opcode.JUMP) or
                            data.opcode == @intFromEnum(Opcode.JUMPI))
                        {
                            schedule_index += 1; // Extra metadata
                        }
                    },
                    .push => {
                        schedule_index += 2; // Handler + metadata  
                    },
                    .push_add_fusion, .push_mul_fusion, .push_sub_fusion, .push_div_fusion,
                    .push_and_fusion, .push_or_fusion, .push_xor_fusion,
                    .push_jump_fusion, .push_jumpi_fusion,
                    .push_mload_fusion, .push_mstore_fusion, .push_mstore8_fusion => {
                        schedule_index += 2; // Handler + metadata
                    },
                    .stop, .invalid => {
                        schedule_index += 1; // Handler
                    },
                    // Advanced fusion patterns
                    .multi_push => |mp| {
                        schedule_index += @as(usize, mp.count) * 2; // Each push: handler + value
                    },
                    .multi_pop => |mp| {
                        schedule_index += mp.count; // Each pop: handler only
                    },
                    .iszero_jumpi => {
                        schedule_index += 5; // ISZERO handler + PUSH handler + value + JUMPI handler + metadata
                    },
                    .dup2_mstore_push => {
                        schedule_index += 4; // DUP2 handler + MSTORE handler + PUSH handler + value
                    },
                }
            }
            
            // Now build jump table from the map
            return try createJumpTableFromMap(allocator, schedule, &jumpdest_map);
        }
        
        fn createJumpTableFromMap(
            allocator: std.mem.Allocator,
            schedule: []const Item,
            jumpdest_map: *std.AutoHashMap(FrameType.PcType, usize),
        ) !JumpTable {
            // Create sorted array of jump table entries
            const entries = try allocator.alloc(JumpTable.JumpTableEntry, jumpdest_map.count());
            errdefer allocator.free(entries);
            
            var i: usize = 0;
            var map_iter = jumpdest_map.iterator();
            while (map_iter.next()) |entry| {
                entries[i] = .{
                    .pc = entry.key_ptr.*,
                    .dispatch = Self{
                        .cursor = schedule.ptr + entry.value_ptr.*,
                    },
                };
                i += 1;
            }
            
            // Sort entries by PC
            std.sort.block(JumpTable.JumpTableEntry, entries, {}, struct {
                pub fn lessThan(context: void, a: JumpTable.JumpTableEntry, b: JumpTable.JumpTableEntry) bool {
                    _ = context;
                    return a.pc < b.pc;
                }
            }.lessThan);
            
            if (std.debug.runtime_safety and entries.len > 1) {
                for (entries[0..entries.len -| 1], entries[1..]) |current, next| {
                    if (current.pc >= next.pc) {
                        std.debug.panic("JumpTable not properly sorted: PC {} >= {}", .{ current.pc, next.pc });
                    }
                }
            }
            
            return JumpTable{ .entries = entries };
        }

        pub const DispatchSchedule = struct {
            items: []Item,
            allocator: std.mem.Allocator,

            pub fn init(allocator: std.mem.Allocator, bytecode: anytype, opcode_handlers: *const [256]OpcodeHandler) !DispatchSchedule {
                const items = try Self.init(allocator, bytecode, opcode_handlers);
                return DispatchSchedule{
                    .items = items,
                    .allocator = allocator,
                };
            }

            pub fn deinit(self: *DispatchSchedule) void {
                self.allocator.free(self.items);
            }

            pub fn getDispatch(self: *const DispatchSchedule) Self {
                return Self{
                    .cursor = self.items.ptr,
                };
            }
        };

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

                if (self.schedule_index == 0) {
                    const first_block_gas = calculateFirstBlockGas(self.bytecode);
                    if (first_block_gas > 0) {
                        self.schedule_index = 1;
                        if (self.schedule_index >= self.schedule.len) return null;
                    }
                }

                const current_pc = self.pc;
                const current_index = self.schedule_index;

                const item = self.schedule[self.schedule_index];
                const op_type: Entry.op_data = switch (item) {
                    .opcode_handler => blk: {
                        break :blk .regular;
                    },
                    .jump_dest => .jumpdest,
                    .push_inline, .push_pointer => .push,
                    else => .regular,
                };

                self.schedule_index += 1;

                if (self.schedule_index < self.schedule.len) {
                    switch (self.schedule[self.schedule_index]) {
                        .jump_dest, .push_inline, .push_pointer, .pc => {
                            self.schedule_index += 1;
                        },
                        else => {},
                    }
                }

                self.pc += 1;

                return Entry{
                    .pc = current_pc,
                    .schedule_index = current_index,
                    .op_data = op_type,
                };
            }
        };

        pub const JumpTableBuilder = dispatch_jump_table_builder.JumpTableBuilder(FrameType, Self);

        pub fn pretty_print(allocator: std.mem.Allocator, schedule: []const Item, bytecode: anytype) ![]u8 {
            return dispatch_pretty_print.pretty_print(allocator, schedule, bytecode, FrameType, Item);
        }
    };
}

pub fn ScheduleElement(comptime FrameType: type) type {
    const DispatchType = Dispatch(FrameType);
    return DispatchType.Item;
}
