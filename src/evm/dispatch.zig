const std = @import("std");
const Opcode = @import("opcode_data.zig").Opcode;
const OpcodeSynthetic = @import("opcode_synthetic.zig").OpcodeSynthetic;
const bytecode_mod = @import("bytecode.zig");
const ArrayList = std.ArrayListAligned;
const dispatch_metadata = @import("dispatch_metadata.zig");
const dispatch_item = @import("dispatch_item.zig");
const dispatch_jump_table = @import("dispatch_jump_table.zig");
const dispatch_jump_table_builder = @import("dispatch_jump_table_builder.zig");

// TODO: Low priority TODO
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

        /// Import builder utilities from dispatch_builder module
        const dispatch_builder = @import("dispatch_builder.zig");
        const DispatchBuilder = dispatch_builder.DispatchBuilder(FrameType, Item);
        
        /// Re-export types for API compatibility
        pub const BuildOwned = DispatchBuilder.BuildOwned;

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

        /// Import utilities from dispatch_utils module
        const dispatch_utils = @import("dispatch_utils.zig");
        
        /// Re-export utilities for API compatibility
        pub const calculateFirstBlockGas = dispatch_utils.calculateFirstBlockGas;
        pub const FusionType = dispatch_utils.FusionType;
        pub const getSyntheticOpcode = dispatch_utils.getSyntheticOpcode;

        // ========================
        // Initialization
        // ========================

        /// Create an optimized dispatch array from bytecode using the builder
        pub fn init(
            allocator: std.mem.Allocator,
            bytecode: anytype,
            opcode_handlers: *const [256]OpcodeHandler,
        ) ![]Self.Item {
            return DispatchBuilder.build(allocator, bytecode, opcode_handlers);
        }

        /// Build schedule and return ownership of auxiliary allocations for safe deallocation
        pub fn initWithOwnership(
            allocator: std.mem.Allocator,
            bytecode: anytype,
            opcode_handlers: *const [256]OpcodeHandler,
        ) !BuildOwned {
            return DispatchBuilder.buildWithOwnership(allocator, bytecode, opcode_handlers);
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

        /// Import schedule utilities from dispatch_schedule module
        const dispatch_schedule = @import("dispatch_schedule.zig");
        
        /// RAII wrapper for dispatch schedule that automatically cleans up push pointers
        pub const DispatchSchedule = struct {
            inner: dispatch_schedule.DispatchSchedule(FrameType, Self),
            
            /// Initialize a dispatch schedule from bytecode with automatic cleanup
            pub fn init(allocator: std.mem.Allocator, bytecode: anytype, opcode_handlers: *const [256]OpcodeHandler) !DispatchSchedule {
                const owned = try Self.initWithOwnership(allocator, bytecode, opcode_handlers);
                const inner = dispatch_schedule.DispatchSchedule(FrameType, Self).fromOwned(allocator, owned);
                return DispatchSchedule{ .inner = inner };
            }

            /// Clean up the schedule including all heap-allocated push pointers
            pub fn deinit(self: *DispatchSchedule) void {
                self.inner.deinit();
            }

            /// Get a Dispatch instance pointing to the start of the schedule
            pub fn getDispatch(self: *const DispatchSchedule) Self {
                return self.inner.getDispatch();
            }
            
            /// Access items for compatibility
            pub fn items(self: *const DispatchSchedule) []const Item {
                return self.inner.items;
            }
        };

        /// Import iterator utilities from dispatch_iterator module  
        const dispatch_iterator = @import("dispatch_iterator.zig");
        
        /// Re-export ScheduleIterator for API compatibility
        pub const ScheduleIterator = dispatch_iterator.ScheduleIterator(FrameType);

        /// Builder for creating jump tables with improved error handling
        pub const JumpTableBuilder = dispatch_jump_table_builder.JumpTableBuilder(FrameType, Self);

        /// Import debug utilities from dispatch_debug module
        const dispatch_debug = @import("dispatch_debug.zig");
        
        /// Re-export pretty print for API compatibility
        pub fn pretty_print(allocator: std.mem.Allocator, schedule: []const Item, bytecode: anytype) ![]u8 {
            return dispatch_debug.pretty_print(FrameType, allocator, schedule, bytecode);
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
