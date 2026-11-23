const std = @import("std");
const Opcode = @import("../opcodes/opcode_data.zig").Opcode;
const OpcodeSynthetic = @import("../opcodes/opcode_synthetic.zig").OpcodeSynthetic;

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
                min_stack: i16,
                max_stack: i16,
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
    const items = scheduleItems(ItemType, schedule);

    var output = std.ArrayList(u8){
        .items = &.{},
        .capacity = 0,
    };
    defer output.deinit(allocator);

    // Header
    try output.writer(allocator).print("{s}=== EVM Dispatch Instruction Stream ==={s}\n", .{ Colors.bold, Colors.reset });
    try output.writer(allocator).print("{s}Original bytecode: {} bytes, Dispatch items: {}{s}\n\n", .{ Colors.dim, actual_bytecode.runtime_code.len, items.len, Colors.reset });
    
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
                            try output.writer(allocator).print(" {s}gas={} min_stack={} max_stack={}{s}", .{
                                Colors.dim, meta.jump_dest.gas, meta.jump_dest.min_stack, meta.jump_dest.max_stack, Colors.reset,
                            });
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
                            if (meta.jump_static.target_pc) |target_pc| {
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
        while (i < items.len) {
            try output.writer(allocator).print("{s}[{d:3}]:{s} {s}@{*}{s} ", .{ Colors.dim, i, Colors.reset, Colors.cyan, &items[i], Colors.reset });
            try output.writer(allocator).print("{s}ITEM{s}\n", .{ Colors.blue, Colors.reset });
            i += 1;
        }
    }

    // Summary section
    try output.writer(allocator).print("\n{s}--- Summary ---{s}\n", .{ Colors.bold, Colors.reset });

    const total_items = items.len;

    try output.writer(allocator).print("{s}Total dispatch items: {}{s}\n", .{ Colors.dim, total_items, Colors.reset });
    try output.writer(allocator).print("{s}Compression ratio: {d:.2}x (bytecode:{} -> dispatch:{}){s}\n", .{ Colors.dim, if (items.len > 0) @as(f64, @floatFromInt(actual_bytecode.runtime_code.len)) / @as(f64, @floatFromInt(items.len)) else 0.0, actual_bytecode.runtime_code.len, items.len, Colors.reset });

    return output.toOwnedSlice(allocator);
}

fn scheduleItems(comptime Item: type, schedule: anytype) []const Item {
    return if (@typeInfo(@TypeOf(schedule)) == .@"struct") schedule.items else schedule;
}

/// Inspect the schedule with its debug kinds when available. Raw slices and
/// optimized schedules use the same layout replay as the legacy jump table.
pub fn getDebugInfo(
    allocator: std.mem.Allocator,
    dispatch_schedule: anytype,
    bytecode: anytype,
    comptime FrameType: type,
    comptime Item: type,
) !DispatchDebugInfo(FrameType) {
    const Dispatch = FrameType.Dispatch;
    const schedule = scheduleItems(Item, dispatch_schedule);
    const has_sidecar = @typeInfo(@TypeOf(dispatch_schedule)) == .@"struct";
    const kinds: []const Dispatch.ItemKind = if (has_sidecar) dispatch_schedule.item_kinds else &.{};

    const DebugInfo = DispatchDebugInfo(FrameType);
    var debug_info = DebugInfo{
        .handler_map = std.hash_map.HashMap(*const anyopaque, DebugInfo.OpcodeInfo, std.hash_map.AutoContext(*const anyopaque), 80).init(allocator),
        .schedule_entries = &.{},
        .validation_errors = .empty,
        .pc_to_schedule_map = std.hash_map.HashMap(u32, usize, std.hash_map.AutoContext(u32), 80).init(allocator),
        .jumpdest_map = std.hash_map.HashMap(u32, usize, std.hash_map.AutoContext(u32), 80).init(allocator),
        .allocator = allocator,
    };
    errdefer debug_info.deinit();

    // Build reverse handler map from opcode handlers
    const frame_handlers = @import("../frame/frame_handlers.zig");
    const opcode_handlers = frame_handlers.getOpcodeHandlers(FrameType, &.{});
    
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
    
    var iter = Dispatch.scheduleIterator(bytecode);
    if (has_sidecar and dispatch_schedule.has_first_block_gas != iter.has_first_block_gas) {
        try addValidationError(&debug_info, 0, null, "First block metadata mismatch", "bytecode layout", "schedule flag");
        return debug_info;
    }

    var layout = iter;
    while (try layout.next()) |entry| {
        const pc: u32 = @intCast(entry.pc);
        try debug_info.pc_to_schedule_map.put(pc, entry.schedule_index);
        if (entry.op == .jumpdest) try debug_info.jumpdest_map.put(pc, entry.schedule_index);
    }

    const implicit_stop_index = layout.schedule_index;
    const expected_len = implicit_stop_index + Dispatch.terminal_item_count;
    if (schedule.len != expected_len or (kinds.len != 0 and kinds.len != schedule.len)) {
        try addValidationError(&debug_info, @min(schedule.len, expected_len), null, "Schedule length mismatch", "bytecode layout", "schedule items or kinds");
        if (kinds.len == 0 or kinds.len != schedule.len) return debug_info;
    }

    var entries: std.ArrayList(DebugInfo.ScheduleEntry) = .empty;
    defer entries.deinit(allocator);

    if (iter.has_first_block_gas and schedule.len != 0) {
        try appendEntry(FrameType, &debug_info, &entries, schedule, kinds, 0, null, .first_block_gas, null);
    }

    while (try iter.next()) |entry| {
        var index = entry.schedule_index;
        if (index >= schedule.len) break;
        const pc: u32 = @intCast(entry.pc);
        const expected: ?DebugInfo.ExpectedOp = switch (entry.op) {
            .push => |data| .{ .push = .{
                .opcode = @enumFromInt(0x5f + data.size),
                .value = @intCast(data.value),
                .size = data.size,
                .pc = pc,
            } },
            .jumpdest => |data| .{ .jumpdest = .{ .pc = pc, .gas = data.gas_cost } },
            .stop => .{ .stop = {} },
            .invalid => .{ .invalid = {} },
            .push_jump_fusion => .{ .fusion = .{
                .opcodes = &.{ .PUSH1, .JUMP },
                .synthetic = .JUMP_TO_STATIC_LOCATION,
                .pc = pc,
            } },
            .push_jumpi_fusion => .{ .fusion = .{
                .opcodes = &.{ .PUSH1, .JUMPI },
                .synthetic = .JUMPI_TO_STATIC_LOCATION,
                .pc = pc,
            } },
            .regular, .pc, .jump, .jumpi => if (std.meta.intToEnum(Opcode, bytecode.runtime_code[pc])) |opcode|
                .{ .regular = .{ .opcode = opcode, .pc = pc } }
            else |_|
                null,
            else => null,
        };
        try appendEntry(FrameType, &debug_info, &entries, schedule, kinds, index, pc, .opcode_handler, expected);
        index += 1;
        for (entry.metadata) |maybe_kind| {
            const kind = maybe_kind orelse break;
            if (index >= schedule.len) break;
            try appendEntry(FrameType, &debug_info, &entries, schedule, kinds, index, pc, kind, null);
            const item = &entries.items[entries.items.len - 1];
            if (item.metadata) |meta| switch (entry.op) {
                .push => |data| {
                    const actual = switch (meta) {
                        .push_inline => |push| @as(FrameType.WordType, @intCast(push.value)),
                        .push_pointer => |push| push.value,
                        else => unreachable,
                    };
                    if (actual != data.value) {
                        item.validation_status = .metadata_mismatch;
                        try addValidationError(&debug_info, index, pc, "Push value mismatch", "bytecode immediate", "schedule value");
                    }
                },
                inline .push_jump_fusion, .push_jumpi_fusion => |data| {
                    const expected_index = if (std.math.cast(u32, data.value)) |target|
                        debug_info.jumpdest_map.get(target) orelse implicit_stop_index + 1
                    else
                        implicit_stop_index + 1;
                    if (meta.jump_static.target_idx != expected_index) {
                        item.validation_status = .metadata_mismatch;
                        try addValidationError(&debug_info, index, pc, "Jump target mismatch", "bytecode jump target", "schedule target");
                    }
                },
                else => {},
            };
            index += 1;
        }
        if (entry.has_fallthrough_block and index + 1 < schedule.len) {
            try appendEntry(FrameType, &debug_info, &entries, schedule, kinds, index, null, .opcode_handler, null);
            try appendEntry(FrameType, &debug_info, &entries, schedule, kinds, index + 1, null, .jump_dest, null);
        }
    }

    for (implicit_stop_index..@max(implicit_stop_index, @min(expected_len, schedule.len))) |index| {
        const expected: ?DebugInfo.ExpectedOp = if (index == implicit_stop_index + 1) null else .{ .stop = {} };
        try appendEntry(FrameType, &debug_info, &entries, schedule, kinds, index, null, .opcode_handler, expected);
    }
    debug_info.schedule_entries = try entries.toOwnedSlice(allocator);
    return debug_info;
}

fn appendEntry(
    comptime FrameType: type,
    debug_info: *DispatchDebugInfo(FrameType),
    entries: *std.ArrayList(DispatchDebugInfo(FrameType).ScheduleEntry),
    schedule: []const FrameType.Dispatch.Item,
    kinds: []const FrameType.Dispatch.ItemKind,
    index: usize,
    pc: ?u32,
    kind: FrameType.Dispatch.ItemKind,
    expected: ?DispatchDebugInfo(FrameType).ExpectedOp,
) !void {
    const DebugInfo = DispatchDebugInfo(FrameType);
    var entry: DebugInfo.ScheduleEntry = .{
        .schedule_index = index,
        .pc = pc,
        .item_type = switch (kind) {
            inline else => |value| @field(DebugInfo.ItemType, @tagName(value)),
        },
        .handler_ptr = null,
        .handler_name = null,
        .metadata = null,
        .expected_from_bytecode = expected,
        .validation_status = .valid,
    };
    if (kinds.len != 0 and kinds[index] != kind) {
        entry.item_type = .unexpected;
        entry.validation_status = .unexpected_item;
        try addValidationError(debug_info, index, pc, "Unexpected schedule item", @tagName(kind), @tagName(kinds[index]));
        try entries.append(debug_info.allocator, entry);
        return;
    }

    const item = schedule[index];
    entry.metadata = switch (kind) {
        .opcode_handler => blk: {
            const handler_ptr: *const anyopaque = @ptrCast(item.opcode_handler);
            entry.handler_ptr = handler_ptr;
            if (debug_info.handler_map.get(handler_ptr)) |info| entry.handler_name = info.name;
            if (expected) |op| {
                const opcode: ?Opcode = switch (op) {
                    .regular => |data| data.opcode,
                    .push => |data| data.opcode,
                    .jumpdest => .JUMPDEST,
                    .stop => .STOP,
                    .invalid => .INVALID,
                    .fusion => null,
                };
                if (opcode) |value| {
                    if (item.opcode_handler != FrameType.opcode_handlers[@intFromEnum(value)]) {
                        entry.validation_status = .handler_mismatch;
                        try addValidationError(debug_info, index, pc, "Handler mismatch", @tagName(value), entry.handler_name orelse "UNKNOWN");
                    }
                } else if (op == .fusion) {
                    const synthetic = op.fusion.synthetic;
                    const actual = debug_info.handler_map.get(handler_ptr);
                    if (actual == null or actual.?.synthetic != synthetic) {
                        entry.validation_status = .handler_mismatch;
                        try addValidationError(debug_info, index, pc, "Handler mismatch", @tagName(synthetic), entry.handler_name orelse "UNKNOWN");
                    }
                }
            }
            break :blk null;
        },
        .first_block_gas => .{ .first_block_gas = .{ .gas = item.first_block_gas.gas } },
        .jump_dest => .{ .jump_dest = .{
            .gas = item.jump_dest.gas,
            .min_stack = item.jump_dest.min_stack,
            .max_stack = item.jump_dest.max_stack,
            .target_pc = null,
            .target_idx = null,
        } },
        .push_inline => .{ .push_inline = .{ .value = item.push_inline.value } },
        .push_pointer => .{ .push_pointer = .{ .value_ptr = item.push_pointer.value_ptr, .value = item.push_pointer.value_ptr.* } },
        .pc => .{ .pc = .{ .value = item.pc.value } },
        .jump_static => blk: {
            const base = @intFromPtr(schedule.ptr);
            const target = @intFromPtr(item.jump_static.dispatch);
            var target_idx: ?usize = null;
            var target_pc: ?u32 = null;
            if (target >= base) {
                const offset = target - base;
                const item_size = @sizeOf(FrameType.Dispatch.Item);
                const idx = offset / item_size;
                if (offset % item_size == 0 and idx < schedule.len) {
                    target_idx = idx;
                    var jumpdests = debug_info.jumpdest_map.iterator();
                    while (jumpdests.next()) |dest| {
                        if (dest.value_ptr.* == idx) {
                            target_pc = dest.key_ptr.*;
                            break;
                        }
                    }
                }
            }
            break :blk .{ .jump_static = .{
                .dispatch_ptr = item.jump_static.dispatch,
                .target_pc = target_pc,
                .target_idx = target_idx,
            } };
        },
    };
    try entries.append(debug_info.allocator, entry);
}

fn addValidationError(debug_info: anytype, schedule_idx: usize, pc: ?u32, message: []const u8, expected: []const u8, actual: []const u8) !void {
    try debug_info.validation_errors.append(debug_info.allocator, .{
        .schedule_index = schedule_idx,
        .pc = pc,
        .message = message,
        .expected = expected,
        .actual = actual,
    });
}
