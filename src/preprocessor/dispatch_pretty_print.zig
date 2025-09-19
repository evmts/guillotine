const std = @import("std");
const Opcode = @import("../opcodes/opcode_data.zig").Opcode;
const OpcodeSynthetic = @import("../opcodes/opcode_synthetic.zig").OpcodeSynthetic;
const log = @import("../log.zig");

/// Pretty print functionality for the dispatch instruction stream.
/// Provides human-readable visualization of both original bytecode and optimized dispatch arrays.

/// Debug information structure for dispatch schedule analysis
pub fn DispatchDebugInfo(comptime FrameType: type) type {
    return struct {
        const Self = @This();
        
        handler_map: std.hash_map.HashMap(*const anyopaque, OpcodeInfo, std.hash_map.AutoContext(*const anyopaque), 80),
        schedule_entries: []ScheduleEntry,
        validation_errors: std.ArrayList(ValidationError),
        pc_to_schedule_map: std.hash_map.HashMap(u32, usize, std.hash_map.AutoContext(u32), 80),
        jumpdest_map: std.hash_map.HashMap(u32, usize, std.hash_map.AutoContext(u32), 80),
        allocator: std.mem.Allocator,
        
        pub const OpcodeInfo = struct {
            opcode: ?Opcode,
            synthetic: ?OpcodeSynthetic,
            name: []const u8,
            is_synthetic: bool,
        };
        
        pub const ItemType = enum {
            opcode_handler,
            jump_dest,
            push_inline,
            push_pointer,
            pc,
            jump_static,
            first_block_gas,
            unexpected,
        };
        
        pub const MetadataInfo = union(enum) {
            push_inline: struct { value: u64 },
            push_pointer: struct { value_ptr: *const FrameType.WordType, value: FrameType.WordType },
            jump_dest: struct { 
                gas: u32,
                min_stack: u16,
                max_stack: u16,
                target_pc: ?u32,
                target_idx: ?usize,
            },
            jump_static: struct { 
                dispatch_ptr: *const anyopaque,
                target_pc: ?u32,
                target_idx: ?usize,
            },
            pc: struct { value: u32 },
            first_block_gas: struct { gas: u32 },
        };
        
        pub const ExpectedOp = union(enum) {
            regular: struct {
                opcode: Opcode,
                pc: u32,
            },
            push: struct {
                opcode: Opcode,
                value: FrameType.WordType,
                size: u8,
                pc: u32,
            },
            jumpdest: struct {
                pc: u32,
                gas: u32,
            },
            fusion: struct {
                opcodes: []const Opcode,
                synthetic: OpcodeSynthetic,
                pc: u32,
            },
            stop: void,
            invalid: void,
        };
        
        pub const ValidationStatus = enum {
            valid,
            handler_mismatch,
            metadata_mismatch,
            unexpected_item,
            missing_item,
        };
        
        pub const ScheduleEntry = struct {
            schedule_index: usize,
            pc: ?u32,
            item_type: ItemType,
            handler_ptr: ?*const anyopaque,
            handler_name: ?[]const u8,
            metadata: ?MetadataInfo,
            expected_from_bytecode: ?ExpectedOp,
            validation_status: ValidationStatus,
        };
        
        pub const ValidationError = struct {
            schedule_index: usize,
            pc: ?u32,
            message: []const u8,
            expected: []const u8,
            actual: []const u8,
        };
        
        pub fn deinit(self: *Self) void {
            self.handler_map.deinit();
            self.allocator.free(self.schedule_entries);
            self.validation_errors.deinit(self.allocator);
            self.pc_to_schedule_map.deinit();
            self.jumpdest_map.deinit();
        }
    };
}

/// ANSI color codes for terminal formatting
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

/// Pretty print the dispatch instruction stream in a human-readable format.
/// Shows both the original bytecode and the optimized instruction stream.
/// Returns an allocated string that must be freed by the caller.
///
/// @param allocator - Memory allocator for the output string
/// @param schedule - The dispatch instruction stream to print
/// @param bytecode - The original bytecode object (must have runtime_code field)
/// @param FrameType - The frame type containing PcType definition
/// @param Item - The dispatch item type
/// @return Allocated string containing the formatted output
pub fn pretty_print(
    allocator: std.mem.Allocator,
    schedule: anytype,
    bytecode: anytype,
    comptime FrameType: type,
    comptime ItemType: type, // Item type
) ![]u8 {
    // Handle both error union and direct bytecode types
    const actual_bytecode = if (@typeInfo(@TypeOf(bytecode)) == .error_union)
        try bytecode
    else
        bytecode;
    
    // Get debug info first
    var debug_info = try getDebugInfo(allocator, schedule, actual_bytecode, FrameType, ItemType);
    defer debug_info.deinit();

    var output = std.ArrayList(u8){
        .items = &.{},
        .capacity = 0,
    };
    defer output.deinit(allocator);

    // Header
    try output.writer(allocator).print("{s}=== EVM Dispatch Instruction Stream ==={s}\n", .{ Colors.bold, Colors.reset });
    try output.writer(allocator).print("{s}Original bytecode: {} bytes, Dispatch items: {}{s}\n\n", .{ Colors.dim, actual_bytecode.runtime_code.len, schedule.len, Colors.reset });
    
    // Display validation errors if any
    if (debug_info.validation_errors.items.len > 0) {
        try output.writer(allocator).print("{s}--- VALIDATION ERRORS ---{s}\n", .{ Colors.red, Colors.reset });
        for (debug_info.validation_errors.items) |error_entry| {
            try output.writer(allocator).print("{s}[ERROR]{s} ", .{ Colors.red, Colors.reset });
            if (error_entry.pc) |pc| {
                try output.writer(allocator).print("PC=0x{x:0>4} Schedule[{}]: ", .{ pc, error_entry.schedule_index });
            } else {
                try output.writer(allocator).print("PC=? Schedule[{}]: ", .{error_entry.schedule_index});
            }
            try output.writer(allocator).print("{s}\n", .{error_entry.message});
        }
        try output.writer(allocator).print("\n", .{});
    }

    // Section showing original bytecode
    try output.writer(allocator).print("{s}--- Original Bytecode ---{s}\n", .{ Colors.bold, Colors.reset });
    if (actual_bytecode.runtime_code.len > 0) {
        const runtime_code = actual_bytecode.runtime_code;
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

    // Section showing dispatch instruction stream with debug info
    try output.writer(allocator).print("\n{s}--- Dispatch Instruction Stream ---{s}\n", .{ Colors.bold, Colors.reset });

    // Use debug info entries for enhanced display
    if (debug_info.schedule_entries.len > 0) {
        for (debug_info.schedule_entries) |entry| {
            // Item index
            try output.writer(allocator).print("{s}[{d:3}]:{s} ", .{ Colors.dim, entry.schedule_index, Colors.reset });
            
            // PC if available
            if (entry.pc) |pc| {
                try output.writer(allocator).print("{s}PC=0x{x:0>4}{s} ", .{ Colors.cyan, pc, Colors.reset });
            } else {
                try output.writer(allocator).print("{s}        {s} ", .{ Colors.dim, Colors.reset });
            }
            
            // Item type and details
            switch (entry.item_type) {
                .opcode_handler => {
                    if (entry.handler_name) |name| {
                        try output.writer(allocator).print("{s}{s}{s}", .{ Colors.yellow, name, Colors.reset });
                    } else {
                        try output.writer(allocator).print("{s}HANDLER{s}", .{ Colors.yellow, Colors.reset });
                    }
                },
                .first_block_gas => {
                    try output.writer(allocator).print("{s}FIRST_BLOCK_GAS{s}", .{ Colors.bright_cyan, Colors.reset });
                    if (entry.metadata) |meta| {
                        if (meta == .first_block_gas) {
                            try output.writer(allocator).print(" {s}gas={}{s}", .{ Colors.dim, meta.first_block_gas.gas, Colors.reset });
                        }
                    }
                },
                .jump_dest => {
                    try output.writer(allocator).print("{s}JUMP_DEST{s}", .{ Colors.bright_magenta, Colors.reset });
                    if (entry.metadata) |meta| {
                        if (meta == .jump_dest) {
                            const target_pc = meta.jump_dest.target_pc orelse 0;
                            if (target_pc > 0) {
                                if (debug_info.pc_to_schedule_map.get(target_pc)) |target_idx| {
                                    try output.writer(allocator).print(" {s}→ PC=0x{x:0>4} (Schedule[{}]){s}", .{ Colors.dim, target_pc, target_idx, Colors.reset });
                                } else {
                                    try output.writer(allocator).print(" {s}→ PC=0x{x:0>4}{s}", .{ Colors.dim, target_pc, Colors.reset });
                                }
                            }
                        }
                    }
                },
                .push_inline => {
                    try output.writer(allocator).print("{s}PUSH_INLINE{s}", .{ Colors.green, Colors.reset });
                    if (entry.metadata) |meta| {
                        if (meta == .push_inline) {
                            try output.writer(allocator).print(" {s}value=0x{x}{s}", .{ Colors.dim, meta.push_inline.value, Colors.reset });
                        }
                    }
                },
                .push_pointer => {
                    try output.writer(allocator).print("{s}PUSH_POINTER{s}", .{ Colors.green, Colors.reset });
                    if (entry.metadata) |meta| {
                        if (meta == .push_pointer) {
                            try output.writer(allocator).print(" {s}value=0x{x}{s}", .{ Colors.dim, meta.push_pointer.value, Colors.reset });
                        }
                    }
                },
                .pc => {
                    try output.writer(allocator).print("{s}PC{s}", .{ Colors.blue, Colors.reset });
                    if (entry.pc) |pc_val| {
                        try output.writer(allocator).print(" {s}0x{x:0>4}{s}", .{ Colors.dim, pc_val, Colors.reset });
                    }
                },
                .jump_static => {
                    try output.writer(allocator).print("{s}JUMP_STATIC{s}", .{ Colors.magenta, Colors.reset });
                    if (entry.metadata) |meta| {
                        if (meta == .jump_static) {
                            const target_pc = meta.jump_static.target_pc orelse 0;
                            if (target_pc > 0) {
                                try output.writer(allocator).print(" {s}→ PC=0x{x:0>4}{s}", .{ Colors.dim, target_pc, Colors.reset });
                            }
                        }
                    }
                },
                .unexpected => {
                    try output.writer(allocator).print("{s}UNKNOWN{s}", .{ Colors.red, Colors.reset });
                },
            }
            
            // Show if it's a jumpdest location
            if (entry.pc) |pc| {
                if (debug_info.jumpdest_map.contains(pc)) {
                    try output.writer(allocator).print(" {s}[JUMPDEST]{s}", .{ Colors.bright_green, Colors.reset });
                }
            }
            
            try output.writer(allocator).print("\n", .{});
        }
    } else {
        // Fallback to simple display if no debug entries
        var i: usize = 0;
        while (i < schedule.len) {
            try output.writer(allocator).print("{s}[{d:3}]:{s} {s}@{*}{s} ", .{ Colors.dim, i, Colors.reset, Colors.cyan, &schedule[i], Colors.reset });
            try output.writer(allocator).print("{s}ITEM{s}\n", .{ Colors.blue, Colors.reset });
            i += 1;
        }
    }

    // Summary section
    try output.writer(allocator).print("\n{s}--- Summary ---{s}\n", .{ Colors.bold, Colors.reset });

    const total_items = schedule.len;

    try output.writer(allocator).print("{s}Total dispatch items: {}{s}\n", .{ Colors.dim, total_items, Colors.reset });
    try output.writer(allocator).print("{s}Compression ratio: {d:.2}x (bytecode:{} -> dispatch:{}){s}\n", .{ Colors.dim, if (schedule.len > 0) @as(f64, @floatFromInt(actual_bytecode.runtime_code.len)) / @as(f64, @floatFromInt(schedule.len)) else 0.0, actual_bytecode.runtime_code.len, schedule.len, Colors.reset });

    return output.toOwnedSlice(allocator);
}

/// Get comprehensive debug information about a dispatch schedule
/// This includes validation against bytecode and reverse handler lookups
pub fn getDebugInfo(
    allocator: std.mem.Allocator,
    dispatch_schedule: anytype, // DispatchSchedule type or raw schedule data
    bytecode: anytype,
    comptime FrameType: type,
    comptime Item: type,
) !DispatchDebugInfo(FrameType) {
    // Get schedule items - handle both raw array and struct with items field
    const schedule_items = if (@TypeOf(dispatch_schedule) == []const Item) 
        dispatch_schedule
    else if (@hasField(@TypeOf(dispatch_schedule), "items"))
        dispatch_schedule.items
    else
        @as([]const Item, dispatch_schedule);
    
    log.debug("getDebugInfo: Starting analysis of schedule with {} items", .{schedule_items.len});
    
    const DebugInfo = DispatchDebugInfo(FrameType);
    var debug_info = DebugInfo{
        .handler_map = std.hash_map.HashMap(*const anyopaque, DebugInfo.OpcodeInfo, std.hash_map.AutoContext(*const anyopaque), 80).init(allocator),
        .schedule_entries = undefined,
        .validation_errors = std.ArrayList(DebugInfo.ValidationError){},
        .pc_to_schedule_map = std.hash_map.HashMap(u32, usize, std.hash_map.AutoContext(u32), 80).init(allocator),
        .jumpdest_map = std.hash_map.HashMap(u32, usize, std.hash_map.AutoContext(u32), 80).init(allocator),
        .allocator = allocator,
    };
    errdefer debug_info.deinit();
    
    // Build reverse handler map from opcode handlers
    const frame_handlers = @import("../frame/frame_handlers.zig");
    const opcode_handlers = frame_handlers.getOpcodeHandlers(FrameType);
    
    // Map regular opcodes
    for (0..256) |i| {
        const handler_ptr = @as(*const anyopaque, @ptrCast(opcode_handlers[i]));
        if (std.meta.intToEnum(Opcode, @as(u8, @intCast(i)))) |opcode| {
            try debug_info.handler_map.put(handler_ptr, .{
                .opcode = opcode,
                .synthetic = null,
                .name = @tagName(opcode),
                .is_synthetic = false,
            });
        } else |_| {}
    }
    
    // Map synthetic opcodes
    inline for (std.meta.fields(OpcodeSynthetic)) |field| {
        const synthetic_opcode = @field(OpcodeSynthetic, field.name);
        const handler = frame_handlers.getSyntheticHandler(FrameType, @intFromEnum(synthetic_opcode));
        const handler_ptr = @as(*const anyopaque, @ptrCast(handler));
        try debug_info.handler_map.put(handler_ptr, .{
            .opcode = null,
            .synthetic = synthetic_opcode,
            .name = field.name,
            .is_synthetic = true,
        });
    }
    
    // Allocate schedule entries
    var entries = std.ArrayList(DebugInfo.ScheduleEntry){};
    defer entries.deinit(allocator);
    
    // Create bytecode iterator
    var bytecode_iter = bytecode.createIterator();
    var schedule_idx: usize = 0;
    
    // Check for first_block_gas metadata
    if (schedule_idx < schedule_items.len) {
        if (schedule_items[schedule_idx] == .first_block_gas) {
            const gas_value = schedule_items[schedule_idx].first_block_gas.gas;
            try entries.append(allocator, .{
                .schedule_index = schedule_idx,
                .pc = null,
                .item_type = .first_block_gas,
                .handler_ptr = null,
                .handler_name = null,
                .metadata = .{ .first_block_gas = .{ .gas = gas_value } },
                .expected_from_bytecode = null,
                .validation_status = .valid,
            });
            schedule_idx += 1;
        }
    }
    
    // Iterate through bytecode and validate against schedule
    while (true) {
        const bytecode_pc = bytecode_iter.pc;
        const maybe_op = bytecode_iter.next();
        if (maybe_op == null) break;
        const op_data = maybe_op.?;
        
        // Record PC to schedule mapping
        try debug_info.pc_to_schedule_map.put(@intCast(bytecode_pc), schedule_idx);
        
        switch (op_data) {
            .regular => |data| {
                if (schedule_idx >= schedule_items.len) {
                    try addValidationError(&debug_info, schedule_idx, bytecode_pc, "Schedule underrun", "opcode handler", "end of schedule");
                    break;
                }
                
                const item = schedule_items[schedule_idx];
                if (item != .opcode_handler) {
                    try addValidationError(&debug_info, schedule_idx, bytecode_pc, "Expected opcode handler", "opcode_handler", @tagName(item));
                    try entries.append(allocator, .{
                        .schedule_index = schedule_idx,
                        .pc = @intCast(bytecode_pc),
                        .item_type = switch (item) {
                            .opcode_handler => .opcode_handler,
                            .jump_dest => .jump_dest,
                            .push_inline => .push_inline,
                            .push_pointer => .push_pointer,
                            .pc => .pc,
                            .jump_static => .jump_static,
                            .first_block_gas => .first_block_gas,
                        },
                        .handler_ptr = null,
                        .handler_name = "UNEXPECTED",
                        .metadata = null,
                        .expected_from_bytecode = null,
                        .validation_status = .unexpected_item,
                    });
                } else {
                    const handler_ptr = @as(*const anyopaque, @ptrCast(item.opcode_handler));
                    const handler_info = debug_info.handler_map.get(handler_ptr);
                    const expected_opcode = std.meta.intToEnum(Opcode, data.opcode) catch unreachable;
                    
                    var validation_status: DebugInfo.ValidationStatus = .valid;
                    if (handler_info) |info| {
                        if (info.opcode != expected_opcode) {
                            validation_status = .handler_mismatch;
                            try addValidationError(&debug_info, schedule_idx, bytecode_pc, "Handler mismatch", @tagName(expected_opcode), info.name);
                        }
                    }
                    
                    try entries.append(allocator, .{
                        .schedule_index = schedule_idx,
                        .pc = @intCast(bytecode_pc),
                        .item_type = .opcode_handler,
                        .handler_ptr = handler_ptr,
                        .handler_name = if (handler_info) |info| info.name else "UNKNOWN",
                        .metadata = null,
                        .expected_from_bytecode = .{ .regular = .{
                            .opcode = expected_opcode,
                            .pc = @intCast(bytecode_pc),
                        }},
                        .validation_status = validation_status,
                    });
                }
                schedule_idx += 1;

                // If this opcode carries inline PC metadata in the schedule (PC opcode),
                // consume and record the following .pc metadata item to keep schedule_idx
                // synchronized with subsequent bytecode entries.
                if (std.meta.intToEnum(Opcode, data.opcode) catch unreachable == .PC) {
                    if (schedule_idx < schedule_items.len) {
                        const maybe_meta = schedule_items[schedule_idx];
                        if (maybe_meta == .pc) {
                            const meta = maybe_meta.pc;
                            try entries.append(allocator, .{
                                .schedule_index = schedule_idx,
                                .pc = @intCast(bytecode_pc),
                                .item_type = .pc,
                                .handler_ptr = null,
                                .handler_name = null,
                                .metadata = .{ .pc = .{ .value = meta.value } },
                                .expected_from_bytecode = null,
                                .validation_status = .valid,
                            });
                            schedule_idx += 1;
                        }
                    }
                }
            },
            
            .push => |data| {
                if (schedule_idx >= schedule_items.len) {
                    try addValidationError(&debug_info, schedule_idx, bytecode_pc, "Schedule underrun", "push handler", "end of schedule");
                    break;
                }
                
                // Expect push handler
                const handler_item = schedule_items[schedule_idx];
                if (handler_item != .opcode_handler) {
                    try addValidationError(&debug_info, schedule_idx, bytecode_pc, "Expected push handler", "opcode_handler", @tagName(handler_item));
                } else {
                    const handler_ptr = @as(*const anyopaque, @ptrCast(handler_item.opcode_handler));
                    const handler_info = debug_info.handler_map.get(handler_ptr);
                    
                    try entries.append(allocator, .{
                        .schedule_index = schedule_idx,
                        .pc = @intCast(bytecode_pc),
                        .item_type = .opcode_handler,
                        .handler_ptr = handler_ptr,
                        .handler_name = if (handler_info) |info| info.name else "UNKNOWN",
                        .metadata = null,
                        .expected_from_bytecode = .{ .push = .{
                            .opcode = @enumFromInt(0x60 + data.size - 1),
                            .value = data.value,
                            .size = data.size,
                            .pc = @intCast(bytecode_pc),
                        }},
                        .validation_status = .valid,
                    });
                }
                schedule_idx += 1;
                
                // Expect push metadata
                if (schedule_idx >= schedule_items.len) {
                    try addValidationError(&debug_info, schedule_idx, bytecode_pc, "Schedule underrun", "push metadata", "end of schedule");
                    break;
                }
                
                const metadata_item = schedule_items[schedule_idx];
                switch (metadata_item) {
                    .push_inline => |meta| {
                        try entries.append(allocator, .{
                            .schedule_index = schedule_idx,
                            .pc = @intCast(bytecode_pc),
                            .item_type = .push_inline,
                            .handler_ptr = null,
                            .handler_name = null,
                            .metadata = .{ .push_inline = .{ .value = meta.value } },
                            .expected_from_bytecode = null,
                            .validation_status = if (meta.value == @as(u64, @intCast(data.value))) .valid else .metadata_mismatch,
                        });
                        if (meta.value != @as(u64, @intCast(data.value))) {
                            try addValidationError(&debug_info, schedule_idx, bytecode_pc, "Push value mismatch", 
                                try std.fmt.allocPrint(allocator, "0x{x}", .{data.value}),
                                try std.fmt.allocPrint(allocator, "0x{x}", .{meta.value}));
                        }
                    },
                    .push_pointer => |meta| {
                        // Cannot validate u256 value without access to DispatchSchedule.u256_values
                        try entries.append(allocator, .{
                            .schedule_index = schedule_idx,
                            .pc = @intCast(bytecode_pc),
                            .item_type = .push_pointer,
                            .handler_ptr = null,
                            .handler_name = null,
                            .metadata = .{ .push_pointer = .{ .value_ptr = meta.value_ptr, .value = data.value } }, // Use expected value
                            .expected_from_bytecode = null,
                            .validation_status = .valid, // Assume valid since we can't verify
                        });
                    },
                    else => {
                        try addValidationError(&debug_info, schedule_idx, bytecode_pc, "Expected push metadata", "push_inline or push_pointer", @tagName(metadata_item));
                    },
                }
                schedule_idx += 1;
            },
            
            .jumpdest => |data| {
                // Record jumpdest location
                try debug_info.jumpdest_map.put(@intCast(bytecode_pc), schedule_idx);
                
                if (schedule_idx >= schedule_items.len) {
                    try addValidationError(&debug_info, schedule_idx, bytecode_pc, "Schedule underrun", "jumpdest handler", "end of schedule");
                    break;
                }
                
                // Expect jumpdest handler
                const handler_item = schedule_items[schedule_idx];
                if (handler_item != .opcode_handler) {
                    try addValidationError(&debug_info, schedule_idx, bytecode_pc, "Expected jumpdest handler", "opcode_handler", @tagName(handler_item));
                } else {
                    const handler_ptr = @as(*const anyopaque, @ptrCast(handler_item.opcode_handler));
                    const handler_info = debug_info.handler_map.get(handler_ptr);
                    
                    try entries.append(allocator, .{
                        .schedule_index = schedule_idx,
                        .pc = @intCast(bytecode_pc),
                        .item_type = .opcode_handler,
                        .handler_ptr = handler_ptr,
                        .handler_name = if (handler_info) |info| info.name else "UNKNOWN",
                        .metadata = null,
                        .expected_from_bytecode = .{ .jumpdest = .{
                            .pc = @intCast(bytecode_pc),
                            .gas = data.gas_cost,
                        }},
                        .validation_status = .valid,
                    });
                }
                schedule_idx += 1;
                
                // Expect jump_dest metadata
                if (schedule_idx >= schedule_items.len) {
                    try addValidationError(&debug_info, schedule_idx, bytecode_pc, "Schedule underrun", "jump_dest metadata", "end of schedule");
                    break;
                }
                
                const metadata_item = schedule_items[schedule_idx];
                if (metadata_item != .jump_dest) {
                    try addValidationError(&debug_info, schedule_idx, bytecode_pc, "Expected jump_dest metadata", "jump_dest", @tagName(metadata_item));
                } else {
                    const meta = metadata_item.jump_dest;
                    try entries.append(allocator, .{
                        .schedule_index = schedule_idx,
                        .pc = @intCast(bytecode_pc),
                        .item_type = .jump_dest,
                        .handler_ptr = null,
                        .handler_name = null,
                        .metadata = .{ .jump_dest = .{
                            .gas = meta.gas,
                            .min_stack = 0, // These fields aren't in the current metadata
                            .max_stack = 0,
                            .target_pc = null,
                            .target_idx = null,
                        }},
                        .expected_from_bytecode = null,
                        .validation_status = .valid,
                    });
                }
                schedule_idx += 1;
            },
            
            .push_jump_fusion, .push_jumpi_fusion => {
                if (schedule_idx >= schedule_items.len) {
                    try addValidationError(&debug_info, schedule_idx, bytecode_pc, "Schedule underrun", "fusion handler", "end of schedule");
                    break;
                }
                
                const handler_item = schedule_items[schedule_idx];
                if (handler_item != .opcode_handler) {
                    try addValidationError(&debug_info, schedule_idx, bytecode_pc, "Expected fusion handler", "opcode_handler", @tagName(handler_item));
                } else {
                    const handler_ptr = @as(*const anyopaque, @ptrCast(handler_item.opcode_handler));
                    const handler_info = debug_info.handler_map.get(handler_ptr);
                    
                    const is_jumpi = op_data == .push_jumpi_fusion;
                    const expected_synthetic = if (is_jumpi) OpcodeSynthetic.JUMPI_TO_STATIC_LOCATION else OpcodeSynthetic.JUMP_TO_STATIC_LOCATION;
                    
                    try entries.append(allocator, .{
                        .schedule_index = schedule_idx,
                        .pc = @intCast(bytecode_pc),
                        .item_type = .opcode_handler,
                        .handler_ptr = handler_ptr,
                        .handler_name = if (handler_info) |info| info.name else "UNKNOWN",
                        .metadata = null,
                        .expected_from_bytecode = .{ .fusion = .{
                            .opcodes = if (is_jumpi) &[_]Opcode{ .PUSH1, .SWAP1, .JUMPI } else &[_]Opcode{ .PUSH1, .JUMP },
                            .synthetic = expected_synthetic,
                            .pc = @intCast(bytecode_pc),
                        }},
                        .validation_status = .valid,
                    });
                }
                schedule_idx += 1;
                
                // Expect jump_static metadata
                if (schedule_idx >= schedule_items.len) {
                    try addValidationError(&debug_info, schedule_idx, bytecode_pc, "Schedule underrun", "jump_static metadata", "end of schedule");
                    break;
                }
                
                const metadata_item = schedule_items[schedule_idx];
                if (metadata_item != .jump_static) {
                    try addValidationError(&debug_info, schedule_idx, bytecode_pc, "Expected jump_static metadata", "jump_static", @tagName(metadata_item));
                } else {
                    const meta = metadata_item.jump_static;
                    // Try to find target schedule index from dispatch pointer
                    var target_idx: ?usize = null;
                    var target_pc: ?u32 = null;
                    
                    // Search for the target in schedule
                    const target_ptr = @intFromPtr(meta.dispatch);
                    const schedule_base = @intFromPtr(schedule_items.ptr);
                    if (target_ptr >= schedule_base and target_ptr < schedule_base + schedule_items.len * @sizeOf(Item)) {
                        target_idx = (target_ptr - schedule_base) / @sizeOf(Item);
                        // Look up PC from our map (reverse lookup)
                        var pc_iter = debug_info.pc_to_schedule_map.iterator();
                        while (pc_iter.next()) |entry| {
                            if (entry.value_ptr.* == target_idx.?) {
                                target_pc = entry.key_ptr.*;
                                break;
                            }
                        }
                    }
                    
                    const expected_target = switch (op_data) {
                        .push_jump_fusion => |fusion| @as(u32, @intCast(fusion.value)),
                        .push_jumpi_fusion => |fusion| @as(u32, @intCast(fusion.value)),
                        else => unreachable,
                    };
                    
                    try entries.append(allocator, .{
                        .schedule_index = schedule_idx,
                        .pc = @intCast(bytecode_pc),
                        .item_type = .jump_static,
                        .handler_ptr = null,
                        .handler_name = null,
                        .metadata = .{ .jump_static = .{
                            .dispatch_ptr = meta.dispatch,
                            .target_pc = target_pc,
                            .target_idx = target_idx,
                        }},
                        .expected_from_bytecode = null,
                        .validation_status = if (target_pc == expected_target) .valid else .metadata_mismatch,
                    });
                    
                    if (target_pc != expected_target) {
                        try addValidationError(&debug_info, schedule_idx, bytecode_pc, "Jump target mismatch",
                            try std.fmt.allocPrint(allocator, "PC=0x{x}", .{expected_target}),
                            try std.fmt.allocPrint(allocator, "PC=0x{x}", .{target_pc orelse 0}));
                    }
                }
                schedule_idx += 1;
            },
            
            // Handle other fusion types
            .push_add_fusion, .push_mul_fusion, .push_sub_fusion, .push_div_fusion,
            .push_and_fusion, .push_or_fusion, .push_xor_fusion,
            .push_mload_fusion, .push_mstore_fusion, .push_mstore8_fusion => {
                if (schedule_idx >= schedule_items.len) {
                    try addValidationError(&debug_info, schedule_idx, bytecode_pc, "Schedule underrun", "fusion handler", "end of schedule");
                    break;
                }
                
                const handler_item = schedule_items[schedule_idx];
                if (handler_item != .opcode_handler) {
                    try addValidationError(&debug_info, schedule_idx, bytecode_pc, "Expected fusion handler", "opcode_handler", @tagName(handler_item));
                    try entries.append(allocator, .{
                        .schedule_index = schedule_idx,
                        .pc = @intCast(bytecode_pc),
                        .item_type = switch (handler_item) {
                            .opcode_handler => .opcode_handler,
                            .jump_dest => .jump_dest,
                            .push_inline => .push_inline,
                            .push_pointer => .push_pointer,
                            .pc => .pc,
                            .jump_static => .jump_static,
                            .first_block_gas => .first_block_gas,
                        },
                        .handler_ptr = null,
                        .handler_name = "UNEXPECTED",
                        .metadata = null,
                        .expected_from_bytecode = null,
                        .validation_status = .unexpected_item,
                    });
                } else {
                    const handler_ptr = @as(*const anyopaque, @ptrCast(handler_item.opcode_handler));
                    const handler_info = debug_info.handler_map.get(handler_ptr);

                    try entries.append(allocator, .{
                        .schedule_index = schedule_idx,
                        .pc = @intCast(bytecode_pc),
                        .item_type = .opcode_handler,
                        .handler_ptr = handler_ptr,
                        .handler_name = if (handler_info) |info| info.name else "UNKNOWN",
                        .metadata = null,
                        .expected_from_bytecode = null,
                        .validation_status = .valid,
                    });
                }
                schedule_idx += 1;
                
                // Expect metadata for fusion value
                if (schedule_idx < schedule_items.len) {
                    const metadata_item = schedule_items[schedule_idx];
                    switch (metadata_item) {
                        .push_inline => |meta| {
                            try entries.append(allocator, .{
                                .schedule_index = schedule_idx,
                                .pc = @intCast(bytecode_pc),
                                .item_type = .push_inline,
                                .handler_ptr = null,
                                .handler_name = null,
                                .metadata = .{ .push_inline = .{ .value = meta.value } },
                                .expected_from_bytecode = null,
                                .validation_status = .valid,
                            });
                        },
                        .push_pointer => |meta| {
                            // Cannot access u256 values without DispatchSchedule
                            try entries.append(allocator, .{
                                .schedule_index = schedule_idx,
                                .pc = @intCast(bytecode_pc),
                                .item_type = .push_pointer,
                                .handler_ptr = null,
                                .handler_name = null,
                                .metadata = .{ .push_pointer = .{ .value_ptr = meta.value_ptr, .value = 0 } }, // Can't get actual value
                                .expected_from_bytecode = null,
                                .validation_status = .valid,
                            });
                        },
                        else => {},
                    }
                    schedule_idx += 1;
                }
            },
            
            .stop, .invalid => {
                if (schedule_idx >= schedule_items.len) break;
                
                const handler_item = schedule_items[schedule_idx];
                if (handler_item == .opcode_handler) {
                    const handler_ptr = @as(*const anyopaque, @ptrCast(handler_item.opcode_handler));
                    const handler_info = debug_info.handler_map.get(handler_ptr);
                    
                    try entries.append(allocator, .{
                        .schedule_index = schedule_idx,
                        .pc = @intCast(bytecode_pc),
                        .item_type = .opcode_handler,
                        .handler_ptr = handler_ptr,
                        .handler_name = if (handler_info) |info| info.name else "UNKNOWN",
                        .metadata = null,
                        .expected_from_bytecode = if (op_data == .stop) .{ .stop = {} } else .{ .invalid = {} },
                        .validation_status = .valid,
                    });
                }
                schedule_idx += 1;
            },
            
            else => {
                // Skip other advanced fusion types for now
                schedule_idx += 1;
            },
        }
    }
    
    // Add any remaining schedule items
    while (schedule_idx < schedule_items.len) {
        const item = schedule_items[schedule_idx];
        const entry = switch (item) {
            .opcode_handler => |handler| blk: {
                const handler_ptr = @as(*const anyopaque, @ptrCast(handler));
                const handler_info = debug_info.handler_map.get(handler_ptr);
                break :blk DebugInfo.ScheduleEntry{
                    .schedule_index = schedule_idx,
                    .pc = null,
                    .item_type = .opcode_handler,
                    .handler_ptr = handler_ptr,
                    .handler_name = if (handler_info) |info| info.name else "UNKNOWN",
                    .metadata = null,
                    .expected_from_bytecode = null,
                    .validation_status = .unexpected_item,
                };
            },
            else => DebugInfo.ScheduleEntry{
                .schedule_index = schedule_idx,
                .pc = null,
                .item_type = .unexpected,
                .handler_ptr = null,
                .handler_name = "UNEXPECTED",
                .metadata = null,
                .expected_from_bytecode = null,
                .validation_status = .unexpected_item,
            },
        };
        try entries.append(allocator, entry);
        schedule_idx += 1;
    }
    
    debug_info.schedule_entries = try entries.toOwnedSlice(allocator);
    
    log.debug("getDebugInfo: Completed analysis. Found {} entries, {} errors", .{ 
        debug_info.schedule_entries.len,
        debug_info.validation_errors.items.len 
    });
    
    return debug_info;
}

fn addValidationError(debug_info: anytype, schedule_idx: usize, pc: anytype, message: []const u8, expected: []const u8, actual: []const u8) !void {
    try debug_info.validation_errors.append(debug_info.allocator, .{
        .schedule_index = schedule_idx,
        .pc = if (@TypeOf(pc) == u32) pc else @as(u32, @intCast(pc)),
        .message = message,
        .expected = expected,
        .actual = actual,
    });
}
