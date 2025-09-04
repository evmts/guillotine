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

        /// Unified opcode enum that combines regular and synthetic opcodes into a flat enum
        /// for improved performance and reduced memory usage.
        /// Regular opcodes: 0x00-0xFF, Synthetic opcodes: 0x100+
        pub const UnifiedOpcode = enum(u16) {
            // 0x00s: Stop and Arithmetic Operations
            STOP = 0x00,
            ADD = 0x01,
            MUL = 0x02,
            SUB = 0x03,
            DIV = 0x04,
            SDIV = 0x05,
            MOD = 0x06,
            SMOD = 0x07,
            ADDMOD = 0x08,
            MULMOD = 0x09,
            EXP = 0x0a,
            SIGNEXTEND = 0x0b,
            // 0x10s: Comparison & Bitwise Logic Operations
            LT = 0x10,
            GT = 0x11,
            SLT = 0x12,
            SGT = 0x13,
            EQ = 0x14,
            ISZERO = 0x15,
            AND = 0x16,
            OR = 0x17,
            XOR = 0x18,
            NOT = 0x19,
            BYTE = 0x1a,
            SHL = 0x1b,
            SHR = 0x1c,
            SAR = 0x1d,
            // 0x20s: Crypto
            KECCAK256 = 0x20,
            // 0x30s: Environmental Information
            ADDRESS = 0x30,
            BALANCE = 0x31,
            ORIGIN = 0x32,
            CALLER = 0x33,
            CALLVALUE = 0x34,
            CALLDATALOAD = 0x35,
            CALLDATASIZE = 0x36,
            CALLDATACOPY = 0x37,
            CODESIZE = 0x38,
            CODECOPY = 0x39,
            GASPRICE = 0x3a,
            EXTCODESIZE = 0x3b,
            EXTCODECOPY = 0x3c,
            RETURNDATASIZE = 0x3d,
            RETURNDATACOPY = 0x3e,
            EXTCODEHASH = 0x3f,
            // 0x40s: Block Information
            BLOCKHASH = 0x40,
            COINBASE = 0x41,
            TIMESTAMP = 0x42,
            NUMBER = 0x43,
            DIFFICULTY = 0x44,
            GASLIMIT = 0x45,
            CHAINID = 0x46,
            SELFBALANCE = 0x47,
            BASEFEE = 0x48,
            BLOBHASH = 0x49,
            BLOBBASEFEE = 0x4a,
            // 0x50s: Stack, Memory, Storage and Flow Operations
            POP = 0x50,
            MLOAD = 0x51,
            MSTORE = 0x52,
            MSTORE8 = 0x53,
            SLOAD = 0x54,
            SSTORE = 0x55,
            JUMP = 0x56,
            JUMPI = 0x57,
            PC = 0x58,
            MSIZE = 0x59,
            GAS = 0x5a,
            JUMPDEST = 0x5b,
            TLOAD = 0x5c,
            TSTORE = 0x5d,
            MCOPY = 0x5e,
            PUSH0 = 0x5f,
            // 0x60-0x7f: PUSH1-PUSH32
            PUSH1 = 0x60,
            PUSH2 = 0x61,
            PUSH3 = 0x62,
            PUSH4 = 0x63,
            PUSH5 = 0x64,
            PUSH6 = 0x65,
            PUSH7 = 0x66,
            PUSH8 = 0x67,
            PUSH9 = 0x68,
            PUSH10 = 0x69,
            PUSH11 = 0x6a,
            PUSH12 = 0x6b,
            PUSH13 = 0x6c,
            PUSH14 = 0x6d,
            PUSH15 = 0x6e,
            PUSH16 = 0x6f,
            PUSH17 = 0x70,
            PUSH18 = 0x71,
            PUSH19 = 0x72,
            PUSH20 = 0x73,
            PUSH21 = 0x74,
            PUSH22 = 0x75,
            PUSH23 = 0x76,
            PUSH24 = 0x77,
            PUSH25 = 0x78,
            PUSH26 = 0x79,
            PUSH27 = 0x7a,
            PUSH28 = 0x7b,
            PUSH29 = 0x7c,
            PUSH30 = 0x7d,
            PUSH31 = 0x7e,
            PUSH32 = 0x7f,
            // 0x80s: DUP1-DUP16
            DUP1 = 0x80,
            DUP2 = 0x81,
            DUP3 = 0x82,
            DUP4 = 0x83,
            DUP5 = 0x84,
            DUP6 = 0x85,
            DUP7 = 0x86,
            DUP8 = 0x87,
            DUP9 = 0x88,
            DUP10 = 0x89,
            DUP11 = 0x8a,
            DUP12 = 0x8b,
            DUP13 = 0x8c,
            DUP14 = 0x8d,
            DUP15 = 0x8e,
            DUP16 = 0x8f,
            // 0x90s: SWAP1-SWAP16
            SWAP1 = 0x90,
            SWAP2 = 0x91,
            SWAP3 = 0x92,
            SWAP4 = 0x93,
            SWAP5 = 0x94,
            SWAP6 = 0x95,
            SWAP7 = 0x96,
            SWAP8 = 0x97,
            SWAP9 = 0x98,
            SWAP10 = 0x99,
            SWAP11 = 0x9a,
            SWAP12 = 0x9b,
            SWAP13 = 0x9c,
            SWAP14 = 0x9d,
            SWAP15 = 0x9e,
            SWAP16 = 0x9f,
            // 0xa0s: LOG0-LOG4
            LOG0 = 0xa0,
            LOG1 = 0xa1,
            LOG2 = 0xa2,
            LOG3 = 0xa3,
            LOG4 = 0xa4,
            // 0xf0s: System Operations
            CREATE = 0xf0,
            CALL = 0xf1,
            CALLCODE = 0xf2,
            RETURN = 0xf3,
            DELEGATECALL = 0xf4,
            CREATE2 = 0xf5,
            AUTH = 0xf6,
            AUTHCALL = 0xf7,
            STATICCALL = 0xfa,
            REVERT = 0xfd,
            INVALID = 0xfe,
            SELFDESTRUCT = 0xff,
            
            // Synthetic opcodes (0x100+) - mapped from OpcodeSynthetic 0xA5-0xBC range
            PUSH_ADD_INLINE = 0x100,      // was OpcodeSynthetic.PUSH_ADD_INLINE (0xA5)
            PUSH_ADD_POINTER = 0x101,     // was OpcodeSynthetic.PUSH_ADD_POINTER (0xA6)
            PUSH_MUL_INLINE = 0x102,      // was OpcodeSynthetic.PUSH_MUL_INLINE (0xA7)
            PUSH_MUL_POINTER = 0x103,     // was OpcodeSynthetic.PUSH_MUL_POINTER (0xA8)
            PUSH_DIV_INLINE = 0x104,      // was OpcodeSynthetic.PUSH_DIV_INLINE (0xA9)
            PUSH_DIV_POINTER = 0x105,     // was OpcodeSynthetic.PUSH_DIV_POINTER (0xAA)
            PUSH_JUMP_INLINE = 0x106,     // was OpcodeSynthetic.PUSH_JUMP_INLINE (0xAB)
            PUSH_JUMP_POINTER = 0x107,    // was OpcodeSynthetic.PUSH_JUMP_POINTER (0xAC)
            PUSH_JUMPI_INLINE = 0x108,    // was OpcodeSynthetic.PUSH_JUMPI_INLINE (0xAD)
            PUSH_JUMPI_POINTER = 0x109,   // was OpcodeSynthetic.PUSH_JUMPI_POINTER (0xAE)
            PUSH_SUB_INLINE = 0x10A,      // was OpcodeSynthetic.PUSH_SUB_INLINE (0xAF)
            PUSH_SUB_POINTER = 0x10B,     // was OpcodeSynthetic.PUSH_SUB_POINTER (0xB0)
            PUSH_MLOAD_INLINE = 0x10C,    // was OpcodeSynthetic.PUSH_MLOAD_INLINE (0xB1)
            PUSH_MLOAD_POINTER = 0x10D,   // was OpcodeSynthetic.PUSH_MLOAD_POINTER (0xB2)
            PUSH_MSTORE_INLINE = 0x10E,   // was OpcodeSynthetic.PUSH_MSTORE_INLINE (0xB3)
            PUSH_MSTORE_POINTER = 0x10F,  // was OpcodeSynthetic.PUSH_MSTORE_POINTER (0xB4)
            PUSH_AND_INLINE = 0x110,      // was OpcodeSynthetic.PUSH_AND_INLINE (0xB5)
            PUSH_AND_POINTER = 0x111,     // was OpcodeSynthetic.PUSH_AND_POINTER (0xB6)
            PUSH_OR_INLINE = 0x112,       // was OpcodeSynthetic.PUSH_OR_INLINE (0xB7)
            PUSH_OR_POINTER = 0x113,      // was OpcodeSynthetic.PUSH_OR_POINTER (0xB8)
            PUSH_XOR_INLINE = 0x114,      // was OpcodeSynthetic.PUSH_XOR_INLINE (0xB9)
            PUSH_XOR_POINTER = 0x115,     // was OpcodeSynthetic.PUSH_XOR_POINTER (0xBA)
            PUSH_MSTORE8_INLINE = 0x116,  // was OpcodeSynthetic.PUSH_MSTORE8_INLINE (0xBB)
            PUSH_MSTORE8_POINTER = 0x117, // was OpcodeSynthetic.PUSH_MSTORE8_POINTER (0xBC)

            /// Convert from regular Opcode enum
            pub fn fromRegular(opcode: Opcode) UnifiedOpcode {
                return @enumFromInt(@intFromEnum(opcode));
            }

            /// Convert from synthetic OpcodeSynthetic enum
            pub fn fromSynthetic(opcode: OpcodeSynthetic) UnifiedOpcode {
                // Map from 0xA5-0xBC range to 0x100-0x117 range
                const synthetic_base = @intFromEnum(opcode);
                const unified_value = 0x100 + (synthetic_base - 0xA5);
                return @enumFromInt(unified_value);
            }
            
            /// Check if opcode is a regular EVM opcode (0x00-0xFF)
            pub fn isRegular(self: UnifiedOpcode) bool {
                return @intFromEnum(self) <= 0xFF;
            }
            
            /// Check if opcode is a synthetic/fused opcode (0x100+)
            pub fn isSynthetic(self: UnifiedOpcode) bool {
                return @intFromEnum(self) >= 0x100;
            }
        };

        /// A generic type that casts the 64 byte value to the correct type depending on the opcode
        /// NOTE: The metadata is not tagged (to save cacheline space) so this working safely depends on us always
        /// Constructing the instruction stream correctly with the expected metadata consistentally in the expected spots based on opcode!
        /// We also assume every opcode will correctly pass in the correct enum type for their opcode
        fn GetOpDataReturnType(comptime opcode: UnifiedOpcode) type {
            return switch (opcode) {
                // Regular opcodes requiring metadata
                .PC => struct { metadata: PcMetadata, next: Self },
                .PUSH1, .PUSH2, .PUSH3, .PUSH4, .PUSH5, .PUSH6, .PUSH7, .PUSH8 => 
                    struct { metadata: PushInlineMetadata, next: Self },
                .PUSH9, .PUSH10, .PUSH11, .PUSH12, .PUSH13, .PUSH14, .PUSH15, .PUSH16, 
                .PUSH17, .PUSH18, .PUSH19, .PUSH20, .PUSH21, .PUSH22, .PUSH23, .PUSH24,
                .PUSH25, .PUSH26, .PUSH27, .PUSH28, .PUSH29, .PUSH30, .PUSH31, .PUSH32 => 
                    struct { metadata: PushPointerMetadata, next: Self },
                .JUMPDEST => struct { metadata: JumpDestMetadata, next: Self },
                
                // Synthetic opcodes with inline metadata
                .PUSH_ADD_INLINE, .PUSH_MUL_INLINE, .PUSH_DIV_INLINE, .PUSH_SUB_INLINE, 
                .PUSH_AND_INLINE, .PUSH_OR_INLINE, .PUSH_XOR_INLINE, .PUSH_JUMP_INLINE, 
                .PUSH_JUMPI_INLINE, .PUSH_MLOAD_INLINE, .PUSH_MSTORE_INLINE, .PUSH_MSTORE8_INLINE => 
                    struct { metadata: PushInlineMetadata, next: Self },
                
                // Synthetic opcodes with pointer metadata  
                .PUSH_ADD_POINTER, .PUSH_MUL_POINTER, .PUSH_DIV_POINTER, .PUSH_SUB_POINTER, 
                .PUSH_AND_POINTER, .PUSH_OR_POINTER, .PUSH_XOR_POINTER, .PUSH_JUMP_POINTER, 
                .PUSH_JUMPI_POINTER, .PUSH_MLOAD_POINTER, .PUSH_MSTORE_POINTER, .PUSH_MSTORE8_POINTER => 
                    struct { metadata: PushPointerMetadata, next: Self },
                
                // All other opcodes (no metadata)
                else => struct { next: Self },
            };
        }

        /// Get opcode data including metadata and next dispatch position.
        /// This is a comptime-optimized method for specific opcodes.
        pub fn getOpData(self: Self, comptime opcode: UnifiedOpcode) GetOpDataReturnType(opcode) {
            return switch (opcode) {
                // Regular opcodes requiring metadata
                .PC => .{
                    .metadata = self.cursor[1].pc,
                    .next = Self{ .cursor = self.cursor + 2 },
                },
                .PUSH1, .PUSH2, .PUSH3, .PUSH4, .PUSH5, .PUSH6, .PUSH7, .PUSH8 => .{
                    .metadata = self.cursor[1].push_inline,
                    .next = Self{ .cursor = self.cursor + 2 },
                },
                .PUSH9, .PUSH10, .PUSH11, .PUSH12, .PUSH13, .PUSH14, .PUSH15, .PUSH16, 
                .PUSH17, .PUSH18, .PUSH19, .PUSH20, .PUSH21, .PUSH22, .PUSH23, .PUSH24,
                .PUSH25, .PUSH26, .PUSH27, .PUSH28, .PUSH29, .PUSH30, .PUSH31, .PUSH32 => .{
                    .metadata = self.cursor[1].push_pointer,
                    .next = Self{ .cursor = self.cursor + 2 },
                },
                .JUMPDEST => .{
                    .metadata = self.cursor[1].jump_dest,
                    .next = Self{ .cursor = self.cursor + 2 },
                },
                
                // Synthetic opcodes with inline metadata
                .PUSH_ADD_INLINE, .PUSH_MUL_INLINE, .PUSH_DIV_INLINE, .PUSH_SUB_INLINE, 
                .PUSH_AND_INLINE, .PUSH_OR_INLINE, .PUSH_XOR_INLINE, .PUSH_JUMP_INLINE, 
                .PUSH_JUMPI_INLINE, .PUSH_MLOAD_INLINE, .PUSH_MSTORE_INLINE, .PUSH_MSTORE8_INLINE => .{
                    .metadata = self.cursor[1].push_inline,
                    .next = Self{ .cursor = self.cursor + 2 },
                },
                
                // Synthetic opcodes with pointer metadata
                .PUSH_ADD_POINTER, .PUSH_MUL_POINTER, .PUSH_DIV_POINTER, .PUSH_SUB_POINTER, 
                .PUSH_AND_POINTER, .PUSH_OR_POINTER, .PUSH_XOR_POINTER, .PUSH_JUMP_POINTER, 
                .PUSH_JUMPI_POINTER, .PUSH_MLOAD_POINTER, .PUSH_MSTORE_POINTER, .PUSH_MSTORE8_POINTER => .{
                    .metadata = self.cursor[1].push_pointer,
                    .next = Self{ .cursor = self.cursor + 2 },
                },
                
                // All other opcodes (no metadata)
                else => .{
                    .next = Self{ .cursor = self.cursor + 1 },
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
                                    // log.debug("calculateFirstBlockGas: Found JUMPI at op_count={}, gas={}", .{op_count, gas});
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

        /// Get the correct synthetic opcode for a fusion operation
        fn getSyntheticOpcode(fusion_type: FusionType, is_inline: bool) UnifiedOpcode {
            return switch (fusion_type) {
                .push_add => if (is_inline) .PUSH_ADD_INLINE else .PUSH_ADD_POINTER,
                .push_mul => if (is_inline) .PUSH_MUL_INLINE else .PUSH_MUL_POINTER,
                .push_sub => if (is_inline) .PUSH_SUB_INLINE else .PUSH_SUB_POINTER,
                .push_div => if (is_inline) .PUSH_DIV_INLINE else .PUSH_DIV_POINTER,
                .push_and => if (is_inline) .PUSH_AND_INLINE else .PUSH_AND_POINTER,
                .push_or => if (is_inline) .PUSH_OR_INLINE else .PUSH_OR_POINTER,
                .push_xor => if (is_inline) .PUSH_XOR_INLINE else .PUSH_XOR_POINTER,
                .push_jump => if (is_inline) .PUSH_JUMP_INLINE else .PUSH_JUMP_POINTER,
                .push_jumpi => if (is_inline) .PUSH_JUMPI_INLINE else .PUSH_JUMPI_POINTER,
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
