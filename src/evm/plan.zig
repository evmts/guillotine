//! Runtime execution plan for optimized bytecode interpretation.
//!
//! Contains an instruction stream with interleaved handler pointers,
//! metadata, and inline constants for efficient tail-call execution.
const std = @import("std");
const log = @import("log.zig");
const Opcode = @import("opcode.zig").Opcode;
const builtin = @import("builtin");
pub const PlanConfig = @import("plan_config.zig").PlanConfig;
pub const OpcodeSynthetic = @import("opcode_synthetic.zig").OpcodeSynthetic;

/// Metadata for JUMPDEST instructions.
/// On 64-bit systems this fits in usize, on 32-bit it requires pointer.
pub const JumpDestMetadata = packed struct {
    gas: u32,
    min_stack: i16,
    max_stack: i16,
};
comptime {
    std.debug.assert(@sizeOf(JumpDestMetadata) == 8);
    if (@sizeOf(usize) == 8) std.debug.assert(@sizeOf(JumpDestMetadata) <= @sizeOf(usize));
    std.debug.assert(@bitSizeOf(JumpDestMetadata) == 64);
}

/// Handler function type for instruction execution.
/// Takes frame and plan. Uses tail call recursion.
pub const HandlerFn = fn (frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn;

// Fallback end-of-stream handler used when advancing beyond the last instruction
fn end_of_stream_handler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
    _ = frame;
    _ = plan;
    return error.STOP;
}

/// Instruction stream element for 32-bit platforms.
pub const InstructionElement32 = packed union {
    handler: *const HandlerFn,
    jumpdest_pointer: *const JumpDestMetadata,
    inline_value: u32,
    pointer_index: u32,
};

/// Instruction stream element for 64-bit platforms.
pub const InstructionElement64 = packed union {
    handler: *const HandlerFn,
    jumpdest_metadata: JumpDestMetadata,
    inline_value: u64,
    pointer_index: u64,
};

/// Platform-specific instruction element selection.
pub const InstructionElement = if (@sizeOf(usize) == 8)
    InstructionElement64
else if (@sizeOf(usize) == 4)
    InstructionElement32
else
    @compileError("Unsupported platform: usize must be 32 or 64 bits");

// Compile-time verification
comptime {
    if (@sizeOf(InstructionElement) != @sizeOf(usize)) {
        @compileError("InstructionElement must be exactly usize-sized");
    }

    // Verify specific platform sizes
    if (@sizeOf(usize) == 8) {
        std.debug.assert(@sizeOf(InstructionElement64) == 8);
        std.debug.assert(@alignOf(InstructionElement64) == 8);
    } else if (@sizeOf(usize) == 4) {
        std.debug.assert(@sizeOf(InstructionElement32) == 4);
        std.debug.assert(@alignOf(InstructionElement32) == 4);
    }
}

/// Creates a configured plan type.
///
/// The plan is specialized for the target platform with appropriate
/// instruction element types and index sizes based on bytecode limits.
pub fn Plan(comptime cfg: PlanConfig) type {
    comptime cfg.validate();

    return struct {
        pub const PcType = cfg.PcType();
        pub const InstructionIndexType = PcType; // Can only have as many instructions as PCs
        pub const WordType = cfg.WordType;

        const Self = @This();

        /// The instruction stream - mostly handler pointers with inline metadata.
        instructionStream: []InstructionElement,
        /// Constants array for values too large to fit inline.
        u256_constants: []WordType,
        /// Jumpdest metadata backing storage for 32-bit targets.
        /// On 64-bit this remains empty (metadata is inlined in the stream).
        jumpdest_metadata: []JumpDestMetadata,
        /// PC to instruction index mapping for jump operations.
        /// Key is PC value, value is instruction stream index.
        pc_to_instruction_idx: ?std.AutoHashMap(PcType, InstructionIndexType),
        /// Dense PC->instruction index table (fast path). Length equals bytecode length.
        /// Entry is null when PC is not an instruction start (e.g., PUSH data or out of range).
        pc_to_instruction_idx_dense: ?[]?InstructionIndexType = null,

        /// Get metadata for opcodes that have it.
        pub fn getMetadata(
            self: *const Self,
            idx: *InstructionIndexType,
            comptime opcode: anytype,
        ) blk: {
            // Convert opcode to u8 value for uniform handling
            const opcode_value = blk2: {
                break :blk2 if (@TypeOf(opcode) == u8)
                    opcode
                else if (@TypeOf(opcode) == Opcode)
                    @intFromEnum(opcode)
                else if (@TypeOf(opcode) == OpcodeSynthetic)
                    @intFromEnum(opcode)
                else if (@typeInfo(@TypeOf(opcode)) == .enum_literal)
                    @intFromEnum(@field(Opcode, @tagName(opcode)))
                else
                    @compileError("Invalid opcode type");
            };

            // Determine metadata type based on opcode value
            const MetadataType = switch (opcode_value) {
                // PUSH opcodes return different types based on size
                @intFromEnum(Opcode.PUSH1) => u8,
                @intFromEnum(Opcode.PUSH2) => u16,
                @intFromEnum(Opcode.PUSH3) => u24,
                @intFromEnum(Opcode.PUSH4) => u32,
                @intFromEnum(Opcode.PUSH5) => u40,
                @intFromEnum(Opcode.PUSH6) => u48,
                @intFromEnum(Opcode.PUSH7) => u56,
                @intFromEnum(Opcode.PUSH8) => u64,
                // Larger PUSH opcodes return inline or pointer based on platform
                @intFromEnum(Opcode.PUSH9), @intFromEnum(Opcode.PUSH10), @intFromEnum(Opcode.PUSH11), @intFromEnum(Opcode.PUSH12), @intFromEnum(Opcode.PUSH13), @intFromEnum(Opcode.PUSH14), @intFromEnum(Opcode.PUSH15), @intFromEnum(Opcode.PUSH16), @intFromEnum(Opcode.PUSH17), @intFromEnum(Opcode.PUSH18), @intFromEnum(Opcode.PUSH19), @intFromEnum(Opcode.PUSH20), @intFromEnum(Opcode.PUSH21), @intFromEnum(Opcode.PUSH22), @intFromEnum(Opcode.PUSH23), @intFromEnum(Opcode.PUSH24), @intFromEnum(Opcode.PUSH25), @intFromEnum(Opcode.PUSH26), @intFromEnum(Opcode.PUSH27), @intFromEnum(Opcode.PUSH28), @intFromEnum(Opcode.PUSH29), @intFromEnum(Opcode.PUSH30), @intFromEnum(Opcode.PUSH31), @intFromEnum(Opcode.PUSH32) => if (@sizeOf(usize) == 8) inline_value: {
                    const push_bytes = opcode_value - (@intFromEnum(Opcode.PUSH1) - 1);
                    if (push_bytes <= 8) {
                        break :inline_value u64;
                    } else {
                        break :inline_value *const WordType;
                    }
                } else *const WordType,

                // Synthetic fusion opcodes
                @intFromEnum(OpcodeSynthetic.PUSH_ADD_INLINE), @intFromEnum(OpcodeSynthetic.PUSH_MUL_INLINE), @intFromEnum(OpcodeSynthetic.PUSH_DIV_INLINE), @intFromEnum(OpcodeSynthetic.PUSH_JUMP_INLINE), @intFromEnum(OpcodeSynthetic.PUSH_JUMPI_INLINE), @intFromEnum(OpcodeSynthetic.PUSH_MLOAD_INLINE), @intFromEnum(OpcodeSynthetic.PUSH_MSTORE_INLINE), @intFromEnum(OpcodeSynthetic.PUSH_SUB_INLINE), @intFromEnum(OpcodeSynthetic.PUSH_AND_INLINE), @intFromEnum(OpcodeSynthetic.PUSH_OR_INLINE), @intFromEnum(OpcodeSynthetic.PUSH_XOR_INLINE), @intFromEnum(OpcodeSynthetic.PUSH_MSTORE8_INLINE) => if (@sizeOf(usize) == 8) u64 else u32,

                @intFromEnum(OpcodeSynthetic.PUSH_ADD_POINTER), @intFromEnum(OpcodeSynthetic.PUSH_MUL_POINTER), @intFromEnum(OpcodeSynthetic.PUSH_DIV_POINTER), @intFromEnum(OpcodeSynthetic.PUSH_JUMP_POINTER), @intFromEnum(OpcodeSynthetic.PUSH_JUMPI_POINTER), @intFromEnum(OpcodeSynthetic.PUSH_MLOAD_POINTER), @intFromEnum(OpcodeSynthetic.PUSH_MSTORE_POINTER), @intFromEnum(OpcodeSynthetic.PUSH_SUB_POINTER), @intFromEnum(OpcodeSynthetic.PUSH_AND_POINTER), @intFromEnum(OpcodeSynthetic.PUSH_OR_POINTER), @intFromEnum(OpcodeSynthetic.PUSH_XOR_POINTER), @intFromEnum(OpcodeSynthetic.PUSH_MSTORE8_POINTER) => *const WordType,

                // JUMPDEST returns metadata inline or via pointer
                @intFromEnum(Opcode.JUMPDEST) => if (@sizeOf(usize) == 8)
                    JumpDestMetadata
                else
                    *const JumpDestMetadata,

                // PC returns the original PC value
                @intFromEnum(Opcode.PC) => PcType,

                // All other opcodes have no metadata
                else => @compileError("Opcode has no metadata"),
            };
            break :blk MetadataType;
        } {
            // Get metadata from the next element in instruction stream
            const metadata_idx = idx.* + 1;
            if (metadata_idx >= self.instructionStream.len) {
                @panic("getMetadata: trying to read past end of instruction stream");
            }

            const elem = self.instructionStream[metadata_idx];

            // Extract the right type based on compile-time knowledge
            // Need to re-determine the type since we can't access the block expression result
            const opcode_value = comptime blk2: {
                break :blk2 if (@TypeOf(opcode) == u8)
                    opcode
                else if (@TypeOf(opcode) == Opcode)
                    @intFromEnum(opcode)
                else if (@TypeOf(opcode) == OpcodeSynthetic)
                    @intFromEnum(opcode)
                else if (@typeInfo(@TypeOf(opcode)) == .enum_literal)
                    @intFromEnum(@field(Opcode, @tagName(opcode)))
                else
                    @compileError("Invalid opcode type");
            };

            // Return based on the opcode's metadata type
            return switch (comptime opcode_value) {
                @intFromEnum(Opcode.PUSH1) => @as(u8, @truncate(elem.inline_value)),
                @intFromEnum(Opcode.PUSH2) => @as(u16, @truncate(elem.inline_value)),
                @intFromEnum(Opcode.PUSH3) => @as(u24, @truncate(elem.inline_value)),
                @intFromEnum(Opcode.PUSH4) => @as(u32, @truncate(elem.inline_value)),
                @intFromEnum(Opcode.PUSH5) => @as(u40, @truncate(elem.inline_value)),
                @intFromEnum(Opcode.PUSH6) => @as(u48, @truncate(elem.inline_value)),
                @intFromEnum(Opcode.PUSH7) => @as(u56, @truncate(elem.inline_value)),
                @intFromEnum(Opcode.PUSH8) => elem.inline_value,

                // Larger PUSH opcodes
                @intFromEnum(Opcode.PUSH9), @intFromEnum(Opcode.PUSH10), @intFromEnum(Opcode.PUSH11), @intFromEnum(Opcode.PUSH12), @intFromEnum(Opcode.PUSH13), @intFromEnum(Opcode.PUSH14), @intFromEnum(Opcode.PUSH15), @intFromEnum(Opcode.PUSH16), @intFromEnum(Opcode.PUSH17), @intFromEnum(Opcode.PUSH18), @intFromEnum(Opcode.PUSH19), @intFromEnum(Opcode.PUSH20), @intFromEnum(Opcode.PUSH21), @intFromEnum(Opcode.PUSH22), @intFromEnum(Opcode.PUSH23), @intFromEnum(Opcode.PUSH24), @intFromEnum(Opcode.PUSH25), @intFromEnum(Opcode.PUSH26), @intFromEnum(Opcode.PUSH27), @intFromEnum(Opcode.PUSH28), @intFromEnum(Opcode.PUSH29), @intFromEnum(Opcode.PUSH30), @intFromEnum(Opcode.PUSH31), @intFromEnum(Opcode.PUSH32) => blk: {
                    if (@sizeOf(usize) == 8) {
                        const push_bytes = opcode_value - (@intFromEnum(Opcode.PUSH1) - 1);
                        if (push_bytes <= 8) {
                            break :blk elem.inline_value;
                        } else {
                            const pointer_idx = elem.pointer_index;
                            if (pointer_idx >= self.u256_constants.len) {
                                @panic("getMetadata: pointer index out of bounds");
                            }
                            break :blk &self.u256_constants[pointer_idx];
                        }
                    } else {
                        const pointer_idx = elem.pointer_index;
                        if (pointer_idx >= self.u256_constants.len) {
                            @panic("getMetadata: pointer index out of bounds");
                        }
                        break :blk &self.u256_constants[pointer_idx];
                    }
                },

                // Synthetic opcodes
                @intFromEnum(OpcodeSynthetic.PUSH_ADD_INLINE), @intFromEnum(OpcodeSynthetic.PUSH_MUL_INLINE), @intFromEnum(OpcodeSynthetic.PUSH_DIV_INLINE), @intFromEnum(OpcodeSynthetic.PUSH_JUMP_INLINE), @intFromEnum(OpcodeSynthetic.PUSH_JUMPI_INLINE), @intFromEnum(OpcodeSynthetic.PUSH_MLOAD_INLINE), @intFromEnum(OpcodeSynthetic.PUSH_MSTORE_INLINE), @intFromEnum(OpcodeSynthetic.PUSH_SUB_INLINE), @intFromEnum(OpcodeSynthetic.PUSH_AND_INLINE), @intFromEnum(OpcodeSynthetic.PUSH_OR_INLINE), @intFromEnum(OpcodeSynthetic.PUSH_XOR_INLINE), @intFromEnum(OpcodeSynthetic.PUSH_MSTORE8_INLINE) => if (@sizeOf(usize) == 8) elem.inline_value else @as(u32, @intCast(elem.inline_value)),

                @intFromEnum(OpcodeSynthetic.PUSH_ADD_POINTER), @intFromEnum(OpcodeSynthetic.PUSH_MUL_POINTER), @intFromEnum(OpcodeSynthetic.PUSH_DIV_POINTER), @intFromEnum(OpcodeSynthetic.PUSH_JUMP_POINTER), @intFromEnum(OpcodeSynthetic.PUSH_JUMPI_POINTER), @intFromEnum(OpcodeSynthetic.PUSH_MLOAD_POINTER), @intFromEnum(OpcodeSynthetic.PUSH_MSTORE_POINTER), @intFromEnum(OpcodeSynthetic.PUSH_SUB_POINTER), @intFromEnum(OpcodeSynthetic.PUSH_AND_POINTER), @intFromEnum(OpcodeSynthetic.PUSH_OR_POINTER), @intFromEnum(OpcodeSynthetic.PUSH_XOR_POINTER), @intFromEnum(OpcodeSynthetic.PUSH_MSTORE8_POINTER) => blk: {
                    const pointer_idx = elem.pointer_index;
                    if (pointer_idx >= self.u256_constants.len) {
                        @panic("getMetadata: pointer index out of bounds");
                    }
                    break :blk &self.u256_constants[pointer_idx];
                },

                @intFromEnum(Opcode.JUMPDEST) => if (@sizeOf(usize) == 8) elem.jumpdest_metadata else elem.jumpdest_pointer,
                @intFromEnum(Opcode.PC) => @as(PcType, @intCast(elem.inline_value)),

                else => @compileError("Opcode has no metadata"),
            };
        }

        /// Get the next instruction handler and advance the instruction pointer.
        /// Advances idx first (by 1 or 2 based on metadata), then returns the handler at the new idx.
        pub fn getNextInstruction(
            self: *const Self,
            idx: *InstructionIndexType,
            comptime opcode: anytype,
        ) *const HandlerFn {
            // Convert opcode to u8 value for uniform handling
            const opcode_value = blk: {
                break :blk if (@TypeOf(opcode) == u8)
                    opcode
                else if (@TypeOf(opcode) == Opcode)
                    @intFromEnum(opcode)
                else if (@TypeOf(opcode) == OpcodeSynthetic)
                    @intFromEnum(opcode)
                else if (@typeInfo(@TypeOf(opcode)) == .enum_literal)
                    @intFromEnum(@field(Opcode, @tagName(opcode)))
                else
                    @compileError("Invalid opcode type");
            };

            // Check if opcode has metadata
            const has_metadata = comptime switch (opcode_value) {
                // PUSH opcodes have metadata (except PUSH0)
                @intFromEnum(Opcode.PUSH1),
                @intFromEnum(Opcode.PUSH2),
                @intFromEnum(Opcode.PUSH3),
                @intFromEnum(Opcode.PUSH4),
                @intFromEnum(Opcode.PUSH5),
                @intFromEnum(Opcode.PUSH6),
                @intFromEnum(Opcode.PUSH7),
                @intFromEnum(Opcode.PUSH8),
                @intFromEnum(Opcode.PUSH9),
                @intFromEnum(Opcode.PUSH10),
                @intFromEnum(Opcode.PUSH11),
                @intFromEnum(Opcode.PUSH12),
                @intFromEnum(Opcode.PUSH13),
                @intFromEnum(Opcode.PUSH14),
                @intFromEnum(Opcode.PUSH15),
                @intFromEnum(Opcode.PUSH16),
                @intFromEnum(Opcode.PUSH17),
                @intFromEnum(Opcode.PUSH18),
                @intFromEnum(Opcode.PUSH19),
                @intFromEnum(Opcode.PUSH20),
                @intFromEnum(Opcode.PUSH21),
                @intFromEnum(Opcode.PUSH22),
                @intFromEnum(Opcode.PUSH23),
                @intFromEnum(Opcode.PUSH24),
                @intFromEnum(Opcode.PUSH25),
                @intFromEnum(Opcode.PUSH26),
                @intFromEnum(Opcode.PUSH27),
                @intFromEnum(Opcode.PUSH28),
                @intFromEnum(Opcode.PUSH29),
                @intFromEnum(Opcode.PUSH30),
                @intFromEnum(Opcode.PUSH31),
                @intFromEnum(Opcode.PUSH32),
                // Synthetic fusion opcodes all have metadata
                @intFromEnum(OpcodeSynthetic.PUSH_ADD_INLINE),
                @intFromEnum(OpcodeSynthetic.PUSH_ADD_POINTER),
                @intFromEnum(OpcodeSynthetic.PUSH_MUL_INLINE),
                @intFromEnum(OpcodeSynthetic.PUSH_MUL_POINTER),
                @intFromEnum(OpcodeSynthetic.PUSH_DIV_INLINE),
                @intFromEnum(OpcodeSynthetic.PUSH_DIV_POINTER),
                @intFromEnum(OpcodeSynthetic.PUSH_JUMP_INLINE),
                @intFromEnum(OpcodeSynthetic.PUSH_JUMP_POINTER),
                @intFromEnum(OpcodeSynthetic.PUSH_JUMPI_INLINE),
                @intFromEnum(OpcodeSynthetic.PUSH_JUMPI_POINTER),
                // JUMPDEST has metadata
                @intFromEnum(Opcode.JUMPDEST),
                // PC has metadata (the original PC value)
                @intFromEnum(Opcode.PC),
                => true,
                // All other opcodes including PUSH0 have no metadata
                else => false,
            };

            // Advance past current instruction and its metadata
            idx.* += 1;
            if (has_metadata) idx.* += 1;

            // Now return the next handler (or end-of-stream if at end)
            if (idx.* >= self.instructionStream.len) {
                log.warn("getNextInstruction: advanced idx {} beyond stream len {}", .{ idx.*, self.instructionStream.len });
                return &end_of_stream_handler;
            }
            return self.instructionStream[idx.*].handler;
        }

        /// Get instruction index for a given PC value.
        /// Returns null if PC is not a valid instruction start.
        pub fn getInstructionIndexForPc(self: *const Self, pc: PcType) ?InstructionIndexType {
            // Fast path: dense array lookup if available
            if (self.pc_to_instruction_idx_dense) |dense| {
                const idx_usize: usize = @intCast(pc);
                if (idx_usize < dense.len) {
                    if (dense[idx_usize]) |val| return val;
                }
            }
            // Fallback: hashmap lookup
            if (self.pc_to_instruction_idx) |map| {
                return map.get(pc);
            }
            return null;
        }

        /// Debug print the plan structure.
        pub fn debugPrint(self: *const Self) void {
            if (builtin.mode == .Debug and builtin.target.cpu.arch != .wasm32) return;
            log.debug("\n=== Plan Debug Info ===\n", .{});
            log.debug("Instruction Stream Length: {}\n", .{self.instructionStream.len});
            log.debug("Constants Array Length: {}\n", .{self.u256_constants.len});
            if (self.pc_to_instruction_idx) |map| {
                log.debug("PC Mappings: {} entries\n", .{map.count()});
            } else {
                log.debug("PC Mappings: none\n", .{});
            }
            log.debug("\nInstruction Stream:\n", .{});
            var i: InstructionIndexType = 0;
            while (i < self.instructionStream.len) : (i += 1) {
                const elem = self.instructionStream[i];
                if (@intFromPtr(elem.handler) > 0x10000) {
                    log.debug("  [{d:4}] Handler: ", .{i});
                    log.debug("0x{x}\n", .{@intFromPtr(elem.handler)});
                } else {
                    log.debug("  [{d:4}] Metadata: ", .{i});
                    if (@sizeOf(usize) == 8) {
                        const as_u64 = elem.inline_value;
                        if (as_u64 <= 0xFFFFFFFF) {
                            log.debug("inline_value = 0x{x} ({})", .{ as_u64, as_u64 });
                        } else {
                            const as_jumpdest = elem.jumpdest_metadata;
                            log.debug("jumpdest {{ gas: {}, min_stack: {}, max_stack: {} }}", .{
                                as_jumpdest.gas,
                                as_jumpdest.min_stack,
                                as_jumpdest.max_stack,
                            });
                        }
                    } else {
                        if (elem.pointer_index < self.u256_constants.len) {
                            log.debug("pointer_index = {} -> 0x{x}", .{ elem.pointer_index, self.u256_constants[elem.pointer_index] });
                        } else {
                            log.debug("inline_value = 0x{x} ({})", .{ elem.inline_value, elem.inline_value });
                        }
                    }
                    log.debug("\n", .{});
                }
            }

            if (self.u256_constants.len > 0) {
                log.debug("\nConstants Array:\n", .{});
                for (self.u256_constants, 0..) |constant, idx| {
                    log.debug("  [{}] = 0x{x}\n", .{ idx, constant });
                }
            }

            if (self.pc_to_instruction_idx) |map| {
                log.debug("\nPC to Instruction Mappings:\n", .{});
                var iter = map.iterator();
                var entries = std.ArrayList(struct { pc: PcType, idx: InstructionIndexType }){};
                defer entries.deinit(std.heap.page_allocator);

                // Collect entries for sorting
                while (iter.next()) |entry| {
                    entries.append(std.heap.page_allocator, .{ .pc = entry.key_ptr.*, .idx = entry.value_ptr.* }) catch {};
                }

                if (entries.items.len > 0) {
                    // Sort by PC
                    const Entry = @TypeOf(entries.items[0]);
                    std.sort.block(Entry, entries.items, {}, struct {
                        fn lessThan(_: void, a: Entry, b: Entry) bool {
                            return a.pc < b.pc;
                        }
                    }.lessThan);

                    // Print sorted entries
                    for (entries.items) |entry| {
                        log.debug("  PC {d:4} -> Instruction {d:4}\n", .{ entry.pc, entry.idx });
                    }
                }
            }

            log.debug("=================================\n\n", .{});
        }

        /// Free Plan-owned slices.
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            if (self.instructionStream.len > 0) allocator.free(self.instructionStream);
            if (self.u256_constants.len > 0) allocator.free(self.u256_constants);
            if (self.jumpdest_metadata.len > 0) allocator.free(self.jumpdest_metadata);
            if (self.pc_to_instruction_idx) |*map| {
                map.deinit();
                self.pc_to_instruction_idx = null;
            }
            if (self.pc_to_instruction_idx_dense) |dense| {
                allocator.free(dense);
                self.pc_to_instruction_idx_dense = null;
            }
            self.instructionStream = &.{};
            self.u256_constants = &.{};
            self.jumpdest_metadata = &.{};
        }
    };
}

// Test handler function that does nothing (for testing)
fn testHandler(frame: *anyopaque, plan: *const anyopaque) anyerror!noreturn {
    _ = frame;
    _ = plan;
    unreachable; // Test handlers don't actually execute
}

test "JumpDestMetadata size and alignment" {
    // Test that JumpDestMetadata is properly packed
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(JumpDestMetadata));
    // On some platforms, packed structs might have larger alignment than expected
    // Just verify it's a power of 2 and reasonable
    const align_val = @alignOf(JumpDestMetadata);
    try std.testing.expect(align_val >= 1 and align_val <= 8);
    // Check if it's a power of 2
    try std.testing.expect((align_val & (align_val - 1)) == 0);

    // Test field offsets
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(JumpDestMetadata, "gas"));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(JumpDestMetadata, "min_stack"));
    try std.testing.expectEqual(@as(usize, 6), @offsetOf(JumpDestMetadata, "max_stack"));
}

test "InstructionElement size equals usize" {
    try std.testing.expectEqual(@sizeOf(usize), @sizeOf(InstructionElement));

    if (@sizeOf(usize) == 8) {
        try std.testing.expectEqual(@sizeOf(InstructionElement64), @sizeOf(InstructionElement));
    } else if (@sizeOf(usize) == 4) {
        try std.testing.expectEqual(@sizeOf(InstructionElement32), @sizeOf(InstructionElement));
    }
}

test "PlanConfig validation" {
    // Valid configs should not cause compile errors
    const valid_cfg = PlanConfig{
        .WordType = u256,
        .maxBytecodeSize = 24_576,
    };
    comptime valid_cfg.validate();

    // Test PcType selection
    const small_cfg = PlanConfig{
        .maxBytecodeSize = 100,
    };
    try std.testing.expectEqual(u16, small_cfg.PcType());

    const large_cfg = PlanConfig{
        .maxBytecodeSize = 65_535,
    };
    try std.testing.expectEqual(u16, large_cfg.PcType());
}

test "Plan getMetadata for PUSH opcodes" {
    const allocator = std.testing.allocator;
    const TestPlan = Plan(.{});

    // Create a plan with test data
    var stream = std.ArrayList(InstructionElement).init(allocator);
    defer stream.deinit();

    // PUSH1 with value 42
    try stream.append(.{ .handler = &testHandler });
    try stream.append(.{ .inline_value = 42 });

    // PUSH2 with value 0x1234
    try stream.append(.{ .handler = &testHandler });
    try stream.append(.{ .inline_value = 0x1234 });

    // PUSH8 with max value
    try stream.append(.{ .handler = &testHandler });
    try stream.append(.{ .inline_value = std.math.maxInt(u64) });

    var plan = TestPlan{
        .instructionStream = try stream.toOwnedSlice(),
        .u256_constants = &.{},
        .jumpdest_metadata = &.{},
        .pc_to_instruction_idx = null,
    };
    defer plan.deinit(allocator);

    // Test PUSH1
    var idx: TestPlan.InstructionIndexType = 0;
    const push1_val = plan.getMetadata(&idx, .PUSH1);
    try std.testing.expectEqual(@as(u8, 42), push1_val);
    try std.testing.expectEqual(@as(TestPlan.InstructionIndexType, 0), idx); // getMetadata doesn't advance idx

    // Test PUSH2
    idx = 2; // Move to PUSH2 handler position
    const push2_val = plan.getMetadata(&idx, .PUSH2);
    try std.testing.expectEqual(@as(u16, 0x1234), push2_val);
    try std.testing.expectEqual(@as(TestPlan.InstructionIndexType, 2), idx);

    // Test PUSH8
    idx = 4; // Move to PUSH8 handler position
    const push8_val = plan.getMetadata(&idx, .PUSH8);
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), push8_val);
    try std.testing.expectEqual(@as(TestPlan.InstructionIndexType, 4), idx);
}

test "Plan getMetadata for large PUSH opcodes" {
    const allocator = std.testing.allocator;
    const TestPlan = Plan(.{});

    // Create constants array
    var constants = try allocator.alloc(TestPlan.WordType, 2);
    defer allocator.free(constants);
    constants[0] = 0x123456789ABCDEF0123456789ABCDEF0;
    constants[1] = std.math.maxInt(u256);

    // Create instruction stream
    var stream = std.ArrayList(InstructionElement).init(allocator);
    defer stream.deinit();

    // PUSH32 with pointer to first constant
    try stream.append(.{ .handler = &testHandler });
    try stream.append(.{ .pointer_index = 0 });

    // PUSH20 with pointer to second constant
    try stream.append(.{ .handler = &testHandler });
    try stream.append(.{ .pointer_index = 1 });

    var plan = TestPlan{
        .instructionStream = try stream.toOwnedSlice(),
        .u256_constants = constants,
        .jumpdest_metadata = &.{},
        .pc_to_instruction_idx = null,
    };
    defer plan.deinit(allocator);

    // Test PUSH32
    var idx: TestPlan.InstructionIndexType = 0;
    const push32_ptr = plan.getMetadata(&idx, .PUSH32);
    try std.testing.expectEqual(constants[0], push32_ptr.*);

    // Test PUSH20
    idx = 2;
    const push20_ptr = plan.getMetadata(&idx, .PUSH20);
    try std.testing.expectEqual(constants[1], push20_ptr.*);
}

test "Plan getMetadata for synthetic opcodes" {
    const allocator = std.testing.allocator;
    const TestPlan = Plan(.{});

    // Create constants array
    var constants = try allocator.alloc(TestPlan.WordType, 1);
    defer allocator.free(constants);
    constants[0] = 0xDEADBEEF;

    // Create instruction stream
    var stream = std.ArrayList(InstructionElement).init(allocator);
    defer stream.deinit();

    // PUSH_ADD_INLINE with inline value
    try stream.append(.{ .handler = &testHandler });
    try stream.append(.{ .inline_value = 999 });

    // PUSH_MUL_POINTER with pointer
    try stream.append(.{ .handler = &testHandler });
    try stream.append(.{ .pointer_index = 0 });

    var plan = TestPlan{
        .instructionStream = try stream.toOwnedSlice(),
        .u256_constants = constants,
        .jumpdest_metadata = &.{},
        .pc_to_instruction_idx = null,
    };
    defer plan.deinit(allocator);

    // Test PUSH_ADD_INLINE
    var idx: TestPlan.InstructionIndexType = 0;
    const inline_val = plan.getMetadata(&idx, OpcodeSynthetic.PUSH_ADD_INLINE);
    if (@sizeOf(usize) == 8) {
        try std.testing.expectEqual(@as(u64, 999), inline_val);
    } else {
        try std.testing.expectEqual(@as(u32, 999), inline_val);
    }

    // Test PUSH_MUL_POINTER
    idx = 2;
    const ptr_val = plan.getMetadata(&idx, OpcodeSynthetic.PUSH_MUL_POINTER);
    try std.testing.expectEqual(constants[0], ptr_val.*);
}

test "Plan getMetadata for JUMPDEST" {
    const allocator = std.testing.allocator;
    const TestPlan = Plan(.{});

    // Create instruction stream
    var stream = std.ArrayList(InstructionElement).init(allocator);
    defer stream.deinit();

    if (@sizeOf(usize) == 8) {
        // On 64-bit, JUMPDEST metadata fits inline
        try stream.append(.{ .handler = &testHandler });
        try stream.append(.{ .jumpdest_metadata = .{
            .gas = 100,
            .min_stack = -5,
            .max_stack = 10,
        } });
    } else {
        // On 32-bit, need to use pointer (skipping for simplicity in test)
        return;
    }

    var plan = TestPlan{
        .instructionStream = try stream.toOwnedSlice(),
        .u256_constants = &.{},
        .jumpdest_metadata = &.{},
        .pc_to_instruction_idx = null,
    };
    defer plan.deinit(allocator);

    var idx: TestPlan.InstructionIndexType = 0;
    const jumpdest_meta = plan.getMetadata(&idx, .JUMPDEST);
    try std.testing.expectEqual(@as(u32, 100), jumpdest_meta.gas);
    try std.testing.expectEqual(@as(i16, -5), jumpdest_meta.min_stack);
    try std.testing.expectEqual(@as(i16, 10), jumpdest_meta.max_stack);
}

test "Plan getMetadata for PC opcode" {
    const allocator = std.testing.allocator;
    const TestPlan = Plan(.{});

    // Create instruction stream
    var stream = std.ArrayList(InstructionElement).init(allocator);
    defer stream.deinit();

    // PC with original PC value
    try stream.append(.{ .handler = &testHandler });
    try stream.append(.{ .inline_value = 42 }); // Original PC was 42

    var plan = TestPlan{
        .instructionStream = try stream.toOwnedSlice(),
        .u256_constants = &.{},
        .jumpdest_metadata = &.{},
        .pc_to_instruction_idx = null,
    };
    defer plan.deinit(allocator);

    var idx: TestPlan.InstructionIndexType = 0;
    const pc_val = plan.getMetadata(&idx, .PC);
    try std.testing.expectEqual(@as(TestPlan.PcType, 42), pc_val);
}

test "Plan getNextInstruction advances correctly" {
    const allocator = std.testing.allocator;
    const TestPlan = Plan(.{});

    // Create instruction stream
    var stream = std.ArrayList(InstructionElement).init(allocator);
    defer stream.deinit();

    // ADD (no metadata)
    try stream.append(.{ .handler = &testHandler });
    // PUSH1 (has metadata)
    try stream.append(.{ .handler = &testHandler });
    try stream.append(.{ .inline_value = 5 });
    // MUL (no metadata)
    try stream.append(.{ .handler = &testHandler });

    var plan = TestPlan{
        .instructionStream = try stream.toOwnedSlice(),
        .u256_constants = &.{},
        .jumpdest_metadata = &.{},
        .pc_to_instruction_idx = null,
    };
    defer plan.deinit(allocator);

    // Test advancing from ADD (no metadata)
    var idx: TestPlan.InstructionIndexType = 0;
    const handler1 = plan.getNextInstruction(&idx, .ADD);
    try std.testing.expectEqual(@intFromPtr(&testHandler), @intFromPtr(handler1));
    try std.testing.expectEqual(@as(TestPlan.InstructionIndexType, 1), idx);

    // Test advancing from PUSH1 (has metadata)
    const handler2 = plan.getNextInstruction(&idx, .PUSH1);
    try std.testing.expectEqual(@intFromPtr(&testHandler), @intFromPtr(handler2));
    try std.testing.expectEqual(@as(TestPlan.InstructionIndexType, 3), idx); // Skipped metadata

    // Test advancing from MUL (no metadata); next is end-of-stream
    const handler3 = plan.getNextInstruction(&idx, .MUL);
    try std.testing.expectEqual(@intFromPtr(&end_of_stream_handler), @intFromPtr(handler3));
    try std.testing.expectEqual(@as(TestPlan.InstructionIndexType, 4), idx);
}

test "Plan getInstructionIndexForPc" {
    const allocator = std.testing.allocator;
    const TestPlan = Plan(.{});

    // Create PC mapping
    var map = std.AutoHashMap(TestPlan.PcType, TestPlan.InstructionIndexType).init(allocator);
    defer map.deinit();

    try map.put(0, 0); // PC 0 -> Instruction 0
    try map.put(1, 1); // PC 1 -> Instruction 1
    try map.put(3, 3); // PC 3 -> Instruction 3 (skipped PC 2 due to PUSH data)

    var plan = TestPlan{
        .instructionStream = &.{},
        .u256_constants = &.{},
        .jumpdest_metadata = &.{},
        .pc_to_instruction_idx = map,
    };

    // Test valid PCs
    try std.testing.expectEqual(@as(?TestPlan.InstructionIndexType, 0), plan.getInstructionIndexForPc(0));
    try std.testing.expectEqual(@as(?TestPlan.InstructionIndexType, 1), plan.getInstructionIndexForPc(1));
    try std.testing.expectEqual(@as(?TestPlan.InstructionIndexType, 3), plan.getInstructionIndexForPc(3));

    // Test invalid PC
    try std.testing.expectEqual(@as(?TestPlan.InstructionIndexType, null), plan.getInstructionIndexForPc(2));
    try std.testing.expectEqual(@as(?TestPlan.InstructionIndexType, null), plan.getInstructionIndexForPc(99));
}

test "Plan deinit frees resources" {
    const allocator = std.testing.allocator;
    const TestPlan = Plan(.{});

    // Create resources
    const stream = try allocator.alloc(InstructionElement, 10);
    const constants = try allocator.alloc(TestPlan.WordType, 5);
    var map = std.AutoHashMap(TestPlan.PcType, TestPlan.InstructionIndexType).init(allocator);
    try map.put(0, 0);

    var plan = TestPlan{
        .instructionStream = stream,
        .u256_constants = constants,
        .jumpdest_metadata = &.{},
        .pc_to_instruction_idx = map,
    };

    // Deinit should free all resources
    plan.deinit(allocator);

    // Verify fields are reset
    try std.testing.expectEqual(@as(usize, 0), plan.instructionStream.len);
    try std.testing.expectEqual(@as(usize, 0), plan.u256_constants.len);
    try std.testing.expectEqual(@as(?std.AutoHashMap(TestPlan.PcType, TestPlan.InstructionIndexType), null), plan.pc_to_instruction_idx);
}

// Export the factory function for creating Plan types
pub const createPlan = Plan;
