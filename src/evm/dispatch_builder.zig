const std = @import("std");
const Opcode = @import("opcode_data.zig").Opcode;
const ArrayList = std.ArrayListAligned;
const dispatch_utils = @import("dispatch_utils.zig");

/// Builder for creating dispatch schedules from bytecode
pub fn DispatchBuilder(comptime FrameType: type, comptime ItemType: type) type {
    return struct {
        const Self = @This();
        
        /// Result that carries both schedule items and ownership of associated allocations
        pub const BuildOwned = struct {
            items: []ItemType,
            push_pointers: []*FrameType.WordType,
        };
        
        /// Structure to track memory allocations during schedule creation
        pub const AllocatedMemory = struct {
            pointers: ArrayList(*FrameType.WordType, null),

            pub fn init() AllocatedMemory {
                return .{
                    .pointers = ArrayList(*FrameType.WordType, null){},
                };
            }

            pub fn deinit(self: *AllocatedMemory, allocator: std.mem.Allocator) void {
                for (self.pointers.items) |ptr| {
                    allocator.destroy(ptr);
                }
                self.pointers.deinit(allocator);
            }
        };
        
        /// Create an optimized dispatch array from bytecode
        pub fn build(
            allocator: std.mem.Allocator,
            bytecode: anytype,
            opcode_handlers: anytype,
        ) ![]ItemType {
            const owned = try buildWithOwnership(allocator, bytecode, opcode_handlers);
            
            // Free push pointers since caller doesn't need them in simple build
            for (owned.push_pointers) |ptr| {
                allocator.destroy(ptr);
            }
            if (owned.push_pointers.len > 0) allocator.free(owned.push_pointers);
            
            return owned.items;
        }
        
        /// Build schedule and return ownership of auxiliary allocations for safe deallocation
        pub fn buildWithOwnership(
            allocator: std.mem.Allocator,
            bytecode: anytype,
            opcode_handlers: anytype,
        ) !BuildOwned {
            const ScheduleList = ArrayList(ItemType, null);
            var schedule_items = ScheduleList{};
            errdefer schedule_items.deinit(allocator);

            var allocated_memory = AllocatedMemory.init();
            errdefer allocated_memory.deinit(allocator);

            var iter = bytecode.createIterator();
            const first_block_gas = dispatch_utils.calculateFirstBlockGas(bytecode);
            
            // Add first_block_gas entry if there's any gas to charge
            if (first_block_gas > 0) {
                try schedule_items.append(allocator, @unionInit(ItemType, "first_block_gas", .{ .gas = @intCast(first_block_gas) }));
            }

            while (true) {
                const instr_pc = iter.pc;
                const maybe = iter.next();
                if (maybe == null) break;
                const op_data = maybe.?;

                switch (op_data) {
                    .regular => |data| {
                        try processRegularOpcode(&schedule_items, allocator, opcode_handlers, data, instr_pc);
                    },
                    .push => |data| {
                        try processPushOpcode(&schedule_items, allocator, &allocated_memory, opcode_handlers, data);
                    },
                    .jumpdest => |data| {
                        try schedule_items.append(allocator, @unionInit(ItemType, "opcode_handler", opcode_handlers.*[@intFromEnum(Opcode.JUMPDEST)]));
                        try schedule_items.append(allocator, @unionInit(ItemType, "jump_dest", .{ .gas = data.gas_cost }));
                    },
                    .stop => {
                        try schedule_items.append(allocator, @unionInit(ItemType, "opcode_handler", opcode_handlers.*[@intFromEnum(Opcode.STOP)]));
                    },
                    .invalid => {
                        try schedule_items.append(allocator, @unionInit(ItemType, "opcode_handler", opcode_handlers.*[@intFromEnum(Opcode.INVALID)]));
                    },
                    else => {
                        // Handle fusion operations with simplified approach
                        try schedule_items.append(allocator, @unionInit(ItemType, "opcode_handler", opcode_handlers.*[@intFromEnum(Opcode.STOP)]));
                    },
                }
            }

            // Safety: Append two STOP handlers as terminators
            try schedule_items.append(allocator, @unionInit(ItemType, "opcode_handler", opcode_handlers.*[@intFromEnum(Opcode.STOP)]));
            try schedule_items.append(allocator, @unionInit(ItemType, "opcode_handler", opcode_handlers.*[@intFromEnum(Opcode.STOP)]));

            const items = try schedule_items.toOwnedSlice(allocator);
            const push_ptrs = try allocated_memory.pointers.toOwnedSlice(allocator);
            
            // Clear allocated_memory to prevent double-free in errdefer
            allocated_memory = AllocatedMemory.init();
            
            return BuildOwned{ .items = items, .push_pointers = push_ptrs };
        }
        
        /// Process a regular opcode and add to schedule
        fn processRegularOpcode(
            schedule_items: *ArrayList(ItemType, null),
            allocator: std.mem.Allocator,
            opcode_handlers: anytype,
            data: anytype,
            instr_pc: anytype,
        ) !void {
            const handler = opcode_handlers.*[data.opcode];
            try schedule_items.append(allocator, @unionInit(ItemType, "opcode_handler", handler));

            if (data.opcode == @intFromEnum(Opcode.PC)) {
                try schedule_items.append(allocator, @unionInit(ItemType, "pc", .{ .value = @intCast(instr_pc) }));
            } else if (data.opcode == @intFromEnum(Opcode.JUMP) or data.opcode == @intFromEnum(Opcode.JUMPI)) {
                // JUMP/JUMPI need access to jump table - store placeholder
                try schedule_items.append(allocator, @unionInit(ItemType, "jump_dest", .{ .gas = 0 }));
            }
        }
        
        /// Process a PUSH opcode and add to schedule
        fn processPushOpcode(
            schedule_items: *ArrayList(ItemType, null),
            allocator: std.mem.Allocator,
            allocated_memory: *AllocatedMemory,
            opcode_handlers: anytype,
            data: anytype,
        ) !void {
            const push_opcode = 0x60 + data.size - 1; // PUSH1 = 0x60, etc.
            try schedule_items.append(allocator, @unionInit(ItemType, "opcode_handler", opcode_handlers.*[push_opcode]));

            if (data.size <= 8 and data.value <= std.math.maxInt(u64)) {
                // Inline value for small pushes that fit in u64
                const inline_value: u64 = @intCast(data.value);
                try schedule_items.append(allocator, @unionInit(ItemType, "push_inline", .{ .value = inline_value }));
            } else {
                // Pointer to value for large pushes
                const value_ptr = try allocator.create(FrameType.WordType);
                errdefer allocator.destroy(value_ptr);
                value_ptr.* = data.value;
                try allocated_memory.pointers.append(allocator, value_ptr);
                try schedule_items.append(allocator, @unionInit(ItemType, "push_pointer", .{ .value = value_ptr }));
            }
        }
    };
}