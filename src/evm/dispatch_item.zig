const dispatch_metadata = @import("dispatch_metadata.zig");

/// Creates dispatch item types for a given Frame type
pub fn DispatchItem(comptime FrameType: type) type {
    const Metadata = dispatch_metadata.DispatchMetadata(FrameType);
    
    // Forward declare Item for OpcodeHandler
    const ItemType = union {
        /// Most items are function pointers to an opcode handler
        opcode_handler: *const fn (frame: *FrameType, cursor: [*]const @This()) FrameType.Error!noreturn,
        /// Some opcode handlers are followed by metadata specific to that opcode
        jump_dest: Metadata.JumpDestMetadata,
        push_inline: Metadata.PushInlineMetadata,
        push_pointer: Metadata.PushPointerMetadata,
        pc: Metadata.PcMetadata,
        codesize: Metadata.CodesizeMetadata,
        codecopy: Metadata.CodecopyMetadata,
        first_block_gas: Metadata.FirstBlockMetadata,
        trace_before: Metadata.TraceBeforeMetadata,
        trace_after: Metadata.TraceAfterMetadata,
    };

    comptime {
        if (@sizeOf(ItemType) != 8) @compileError("Item must be 64 bits");
    }

    return ItemType;
}