# CLAUDE.md - Bytecode Module

## MISSION CRITICAL: Bytecode Analysis and Optimization
**Bytecode parsing/analysis errors cause incorrect execution or exploits.** Must maintain perfect EVM specification compliance.

## EVM Bytecode Specs (IMMUTABLE)
- **Instruction Encoding**: Single-byte opcodes (0x00-0xFF)
- **PUSH Instructions**: Immediate data follows opcode (PUSH1-PUSH32)
- **Jump Destinations**: Only JUMPDEST (0x5B) opcodes valid
- **Code Limits**: 24,576 bytes per contract, 49,152 bytes init code

## Core Responsibilities
- **Parsing**: Extract opcodes and immediate values
- **Jump Analysis**: Identify valid JUMPDEST locations
- **Pattern Recognition**: Detect optimization opportunities
- **Validation**: Ensure bytecode follows EVM rules
- **Fusion Optimization**: Combine common instruction patterns

## Bytecode Parsing
```zig
pub fn parse_bytecode(code: []const u8) !BytecodeAnalysis {
    var analysis = BytecodeAnalysis.init();
    var pc: usize = 0;

    while (pc < code.len) {
        const opcode = code[pc];
        try analysis.instructions.append(.{ .opcode = opcode, .pc = pc, .gas_cost = get_base_gas_cost(opcode) });

        // Handle PUSH immediate data
        if (opcode >= 0x60 and opcode <= 0x7F) { // PUSH1-PUSH32
            const push_size = opcode - 0x5F;
            if (pc + push_size >= code.len) return BytecodeError.TruncatedPushData;
            pc += push_size; // Skip immediate data
        }
        pc += 1;
    }
    return analysis;
}
```

## JUMPDEST Validation (CONSENSUS CRITICAL)
```zig
pub fn analyze_jump_destinations(code: []const u8) !JumpTable {
    var jump_table = JumpTable.init();
    var pc: usize = 0;

    while (pc < code.len) {
        const opcode = code[pc];
        if (opcode == 0x5B) try jump_table.add_destination(pc); // JUMPDEST

        // Skip PUSH immediate data (not valid jump targets)
        if (opcode >= 0x60 and opcode <= 0x7F) {
            pc += opcode - 0x5F;
        }
        pc += 1;
    }
    return jump_table;
}
```

## Optimization Engine

**Fusion Patterns**:
```zig
pub const FusionPattern = struct {
    pattern: []const u8,     // Opcodes to match
    replacement: OpcodeSynthetic, // Synthetic replacement
    gas_saving: u32,         // Gas saved per execution
    stack_effect: i8,        // Net stack change
};

// Example: PUSH1 x + ADD -> PUSH_ADD_INLINE x
.{ .pattern = &[_]u8{ 0x60, 0x01 }, .replacement = .PUSH_ADD_INLINE, .gas_saving = 2, .stack_effect = -1 }
```

**Fusion Safety**:
```zig
pub fn validate_fusion_safety(original_ops: []const Instruction, fused_op: OpcodeSynthetic) !void {
    // CRITICAL: Verify gas costs match exactly
    var original_gas: u32 = 0;
    for (original_ops) |op| original_gas += op.gas_cost;

    const fused_gas = get_synthetic_gas_cost(fused_op);
    if (original_gas != fused_gas) return BytecodeError.FusionGasMismatch;

    // CRITICAL: Verify stack effects match exactly
    var original_stack_effect: i8 = 0;
    for (original_ops) |op| original_stack_effect += get_stack_effect(op.opcode);

    const fused_stack_effect = get_synthetic_stack_effect(fused_op);
    if (original_stack_effect != fused_stack_effect) return BytecodeError.FusionStackMismatch;
}
```

## Security Analysis
```zig
pub const SecurityIssue = struct {
    type: enum { UnreachableCode, InfiniteLoop, StackUnderflow, InvalidJump, GasExhaustion },
    location: usize,
    severity: enum { Low, Medium, High, Critical },
    description: []const u8,
};

// Detect dangerous patterns: unreachable code, infinite loops, stack issues
pub fn analyze_security_issues(analysis: *const BytecodeAnalysis) ![]SecurityIssue;
```

## Performance Optimization
- **Caching**: HashMap of code_hash -> BytecodeAnalysis
- **Jump Tables**: Binary search for large destination sets
- **Control Flow**: Basic block analysis for complex optimizations
- **Gas Estimation**: Dynamic cost calculation with runtime context

## Code Size Validation
```zig
// EIP-170 and EIP-3860 limits
pub const MAX_CODE_SIZE = 24_576;      // 24KB
pub const MAX_INITCODE_SIZE = 49_152;  // 48KB

pub fn validate_code_size(code: []const u8, is_init_code: bool) !void {
    const limit = if (is_init_code) MAX_INITCODE_SIZE else MAX_CODE_SIZE;
    if (code.len > limit) return BytecodeError.CodeTooLarge;
}
```

## Critical Errors
```zig
pub const BytecodeError = error{
    TruncatedPushData,    // PUSH extends beyond code end
    InvalidOpcode,        // Undefined opcode
    CodeTooLarge,        // Exceeds size limits
    JumpTableOverflow,   // Too many jump destinations
    FusionGasMismatch,   // Optimization changes gas costs
    FusionStackMismatch, // Optimization changes stack effects
};
```

## Emergency Procedures
1. **Analysis Failure**: Fallback to safe mode (no optimizations)
2. **Fusion Bug**: Disable affected patterns, re-analyze cached bytecode
3. **Code Validation**: Verify EVM specification compliance

**Bytecode analysis affects every contract execution. Prioritize correctness over performance.**