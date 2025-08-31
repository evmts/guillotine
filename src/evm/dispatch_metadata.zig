const std = @import("std");

/// Metadata types for dispatch instruction stream
/// These structs contain pre-computed data that helps opcodes execute more efficiently

/// Creates metadata types for a given Frame type
pub fn DispatchMetadata(comptime FrameType: type) type {
    return struct {
        /// Metadata for JUMPDEST operations containing pre-calculated gas and stack requirements.
        /// This enables efficient block-level gas accounting and stack validation.
        /// Instead of calculating static gas every opcode we precalculate it in analysis and then
        /// Add it in one shot when we land on a new jump destination. This turns N gas calculations into 1
        /// The stack validations allows us to use unsafe stack operations such as pop_unsafe that avoid bounds checking
        /// by prevalidating that the stack won't overflow or underflow on jump destination for all following opcodes
        pub const JumpDestMetadata = packed struct(u64) {
            // note: this could be smaller than u32 in future if we needed more space to fit more data
            /// Total gas cost for the entire basic block starting at this JUMPDEST
            gas: u32 = 0,
            // note: this could be smaller than i16 in future if we needed more space to fit more data
            /// Stack requirements we must be at to not underflow
            min_stack: i16 = 0,
            /// Stack requirements we must be at to not overflow
            max_stack: i16 = 0,
        };

        /// The metadata to validate gas and stack sizes for the first block executed by the bytecode
        /// This is the same validation JumpDestinations do
        pub const FirstBlockMetadata = JumpDestMetadata;

        /// Metadata for PUSH operations with values that fit in 64 bits.
        /// Stored inline in the dispatch array for cache efficiency.
        pub const PushInlineMetadata = packed struct(u64) { value: u64 };

        /// Metadata for PUSH operations with values larger than 64 bits.
        /// Contains a pointer to the heap-allocated u256 value.
        pub const PushPointerMetadata = packed struct(u64) { value: *u256 };

        /// Metadata for PC opcode containing the program counter value.
        /// Our instruction set does not match the actual bytecode 1 to 1 if we do fusions so we don't actually track pc during execution
        /// Thus we must provide as metadata to avoid the expensive process of mapping back our instruction index to what pc it came from
        pub const PcMetadata = packed struct { value: FrameType.PcType };

        /// Metadata for CODESIZE opcode containing the bytecode size.
        /// Only one opcode needs this data so it's better to store it as metadata for that opcode than store on frame
        pub const CodesizeMetadata = packed struct { size: u32 };

        /// Metadata for CODECOPY opcode containing bytecode pointer and size.
        /// Only one opcode needs this data so it's better to store it as metadata for that opcode than store on frame
        pub const CodecopyMetadata = packed struct(u64) {
            /// Direct pointer to bytecode data (null-terminated)
            bytecode_ptr: [*:0]const u8,
        };

        /// Metadata for trace_before_op containing PC and opcode for tracing
        /// When tracing is turned on we insert extra instructions before and after every opcode
        pub const TraceBeforeMetadata = packed struct(u64) {
            pc: FrameType.PcType,
            opcode: u8,
            _padding: std.meta.Int(.unsigned, 64 - @bitSizeOf(FrameType.PcType) - 8) = 0,
        };

        /// Metadata for trace_after_op containing PC and opcode for tracing
        pub const TraceAfterMetadata = packed struct(u64) {
            pc: FrameType.PcType,
            opcode: u8,
            _padding: std.meta.Int(.unsigned, 64 - @bitSizeOf(FrameType.PcType) - 8) = 0,
        };
    };
}