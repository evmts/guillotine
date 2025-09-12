#!/bin/bash

# Script to update all instruction handlers to use ghccc calling convention

echo "Updating instruction handlers to use ghccc calling convention..."

# List of files to update
FILES=(
    "src/instructions/handlers_arithmetic.zig"
    "src/instructions/handlers_arithmetic_synthetic.zig"
    "src/instructions/handlers_bitwise.zig"
    "src/instructions/handlers_bitwise_synthetic.zig"
    "src/instructions/handlers_comparison.zig"
    "src/instructions/handlers_context.zig"
    "src/instructions/handlers_jump.zig"
    "src/instructions/handlers_jump_synthetic.zig"
    "src/instructions/handlers_keccak.zig"
    "src/instructions/handlers_log.zig"
    "src/instructions/handlers_memory.zig"
    "src/instructions/handlers_memory_synthetic.zig"
    "src/instructions/handlers_stack.zig"
    "src/instructions/handlers_storage.zig"
    "src/instructions/handlers_system.zig"
    "src/instructions/handlers_advanced_synthetic.zig"
)

for file in "${FILES[@]}"; do
    echo "Processing $file..."
    
    # Replace function signatures to add callconv
    # Pattern: pub fn <name>(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn
    # Replace with: pub fn <name>(self: *FrameType, cursor: [*]const Dispatch.Item) callconv(FrameType.getInterpreterCallConv()) Error!noreturn
    
    sed -i '' 's/pub fn \([a-zA-Z0-9_]*\)(self: \*FrameType, cursor: \[\*\]const Dispatch\.Item) Error!noreturn/pub fn \1(self: *FrameType, cursor: [*]const Dispatch.Item) callconv(FrameType.getInterpreterCallConv()) Error!noreturn/g' "$file"
    
    # Also handle inline functions
    sed -i '' 's/pub inline fn \([a-zA-Z0-9_]*\)(self: \*FrameType, cursor: \[\*\]const Dispatch\.Item) Error!noreturn/pub inline fn \1(self: *FrameType, cursor: [*]const Dispatch.Item) callconv(FrameType.getInterpreterCallConv()) Error!noreturn/g' "$file"
done

echo "Done! All handlers updated to use ghccc calling convention."
echo ""
echo "Note: The next_instruction function should remain inline without callconv,"
echo "as it's inlined into the calling function."