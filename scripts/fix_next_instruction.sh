#!/bin/bash

# Fix next_instruction functions to be inline without callconv

echo "Fixing next_instruction functions to remain inline..."

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
    
    # Fix next_instruction to be inline without callconv
    sed -i '' 's/pub inline fn next_instruction(self: \*FrameType, cursor: \[\*\]const Dispatch\.Item) callconv(FrameType\.getInterpreterCallConv()) Error!noreturn/pub inline fn next_instruction(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn/g' "$file"
done

echo "Done! next_instruction functions fixed."