# Opcodes Module

## Overview

The Opcodes module defines the complete EVM instruction set with opcode enumeration, metadata, gas cost calculations, and synthetic opcode support for optimization. This module serves as the definitive reference for all EVM opcodes and provides the foundation for instruction dispatch and validation throughout the Guillotine EVM implementation.

The module includes comprehensive opcode definitions according to the Ethereum Yellow Paper, gas cost calculations for different hard forks, and synthetic opcodes for performance optimization in specific execution contexts.

## Core Components

### Primary Files

- `opcode.zig` — Core opcode enumeration (`Opcode`)
- `opcode_data.zig` — Static info table `OPCODE_INFO: [256]OpcodeInfo`
- `opcode_synthetic.zig` — Synthetic opcode definitions for optimization

## Key Data Structures

### Opcode Enumeration
```zig
pub const Opcode = enum(u8) {
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
    CLZ = 0x1e, // EIP-7939, Osaka
    
    // ... (continues for all EVM opcodes)
};
```

### Opcode Information Structure
From `opcode_data.zig`:
```zig
pub const OpcodeInfo = struct {
    gas_cost: u16,
    stack_inputs: u4,
    stack_outputs: u4,
};
pub const OPCODE_INFO: [256]OpcodeInfo = // ...
```

Gas costs encoded here are static base costs. Dynamic gas calculations happen in instruction handlers using hardfork-aware rules.

### Synthetic Opcodes
```zig
pub const OpcodeSynthetic = enum(u16) {
    // Optimized arithmetic combinations
    ADD_POP = 0x1000,              // ADD followed by POP
    MUL_ADD = 0x1001,              // MUL followed by ADD
    DUP_ADD = 0x1002,              // DUP followed by ADD
    
    // Optimized memory operations
    MLOAD_ADD = 0x1100,            // MLOAD followed by ADD
    MSTORE_POP = 0x1101,           // MSTORE followed by POP
    
    // Optimized control flow
    ISZERO_JUMPI = 0x1200,         // ISZERO followed by JUMPI
    EQ_JUMPI = 0x1201,             // EQ followed by JUMPI
    
    // Custom operations
    CUSTOM_START = 0x2000,
};
```

## Performance Considerations

### Lookup Tables
Opcode information uses compile-time generated lookup tables for O(1) access:
```zig
const OPCODE_INFO_TABLE: [256]OpcodeInfo = blk: {
    var table: [256]OpcodeInfo = undefined;
    
    // Initialize with default "invalid" entries
    for (&table) |*entry| {
        entry.* = OpcodeInfo{
            .opcode = @enumFromInt(0xFF), // Invalid
            .name = "INVALID",
            .inputs = 0,
            .outputs = 0,
            .gas_cost = GasCost{ .static = 0 },
            .is_jump = false,
            .is_push = false,
            .push_size = 0,
        };
    }
    
    // Define valid opcodes
    table[0x01] = OpcodeInfo{
        .opcode = .ADD,
        .name = "ADD",
        .inputs = 2,
        .outputs = 1,
        .gas_cost = GasCost{ .static = 3 },
        .is_jump = false,
        .is_push = false,
        .push_size = 0,
    };
    
    // ... (continue for all opcodes)
    
    break :blk table;
};

pub fn get_opcode_info(opcode: u8) OpcodeInfo {
    return OPCODE_INFO_TABLE[opcode];
}
```

### Gas Cost Calculation
Efficient gas cost calculation with hard fork support:
```zig
pub fn calculate_gas_cost(
    opcode: Opcode, 
    context: ExecutionContext,
    hardfork: Hardfork
) u64 {
    const info = get_opcode_info(@intFromEnum(opcode));
    
    switch (info.gas_cost) {
        .static => |cost| return cost,
        .dynamic => |dynamic| {
            var total_cost = dynamic.base;
            
            if (dynamic.memory_expansion) {
                total_cost += calculate_memory_expansion_cost(context);
            }
            
            // Apply hard fork specific modifications
            total_cost = apply_hardfork_gas_changes(total_cost, opcode, hardfork);
            
            return total_cost;
        },
    }
}
```

### Synthetic Opcodes
Synthetic definitions enable planner/dispatch to fuse common patterns (e.g., `ISZERO+JUMPI`). See `opcode_synthetic.zig` for the enum and usage.

## Usage Examples

### Basic Opcode Information
```zig
const opcode_mod = @import("opcode.zig");
const Opcode = opcode_mod.Opcode;

// Get opcode information
const add_info = opcode_mod.get_opcode_info(@intFromEnum(Opcode.ADD));
std.debug.print("ADD: inputs={}, outputs={}, gas={}\n", .{
    add_info.inputs,
    add_info.outputs, 
    add_info.gas_cost.static,
});

// Check opcode properties
if (add_info.is_jump) {
    // Handle jump instruction
}

// Calculate stack change
const stack_delta = add_info.stack_change(); // -1 for ADD (2 inputs, 1 output)
```

### Gas Cost Calculation
```zig
const gas_cost = calculate_gas_cost(.SSTORE, execution_context, .Shanghai);
std.debug.print("SSTORE gas cost: {}\n", .{gas_cost});

// Dynamic gas cost example
const copy_gas = calculate_gas_cost(.CODECOPY, ExecutionContext{
    .memory_size = 1024,
    .copy_size = 64,
}, .London);
```

### Opcode Validation
```zig
pub fn validate_opcode(bytecode: []const u8, pc: usize) bool {
    if (pc >= bytecode.len) return false;
    
    const opcode_byte = bytecode[pc];
    const info = get_opcode_info(opcode_byte);
    
    // Check if opcode is valid
    if (std.mem.eql(u8, info.name, "INVALID")) {
        return false;
    }
    
    // Validate PUSH instruction has enough bytes
    if (info.is_push) {
        const required_bytes = pc + 1 + info.push_size;
        return required_bytes <= bytecode.len;
    }
    
    return true;
}
```

### Synthetic Opcode Usage
```zig
const OpcodeSynthetic = @import("opcode_synthetic.zig").OpcodeSynthetic;

// Check for optimization opportunities
const synthetic = is_synthetic_candidate(bytecode, pc);
if (synthetic) |synth_op| {
    switch (synth_op) {
        .ADD_POP => {
            // Optimized ADD+POP: perform addition and discard result
            execute_add_pop(frame);
            return 2; // Consumed 2 instructions
        },
        .ISZERO_JUMPI => {
            // Optimized ISZERO+JUMPI: conditional jump on zero
            return execute_iszero_jumpi(frame);
        },
        else => {
            // Handle other synthetic opcodes
        },
    }
}
```

## Opcode Categories

### Arithmetic Operations (0x01-0x0B)
Basic arithmetic with overflow/underflow handling:
- `ADD`, `MUL`, `SUB` - Basic operations with wrapping
- `DIV`, `SDIV` - Division (unsigned/signed) 
- `MOD`, `SMOD` - Modulus (unsigned/signed)
- `ADDMOD`, `MULMOD` - Modular arithmetic
- `EXP` - Exponentiation
- `SIGNEXTEND` - Sign extension

### Comparison Operations (0x10-0x15)
Comparison and boolean operations:
- `LT`, `GT`, `SLT`, `SGT` - Less/greater than (unsigned/signed)
- `EQ` - Equality comparison
- `ISZERO` - Zero check

### Bitwise Operations (0x16-0x1D)
Bitwise logic and bit manipulation:
- `AND`, `OR`, `XOR`, `NOT` - Boolean logic
- `BYTE` - Byte extraction
- `SHL`, `SHR`, `SAR` - Bit shifting (logical/arithmetic)
- `CLZ` - Count leading zero bits (Osaka): one stack input replaced by a count from 0 to 256, at five gas. Zero returns 256; earlier forks reject the opcode.

### Environment Operations (0x30-0x3F)
Execution environment queries:
- `ADDRESS`, `BALANCE`, `ORIGIN`, `CALLER` - Address information
- `CALLVALUE`, `CALLDATALOAD`, `CALLDATASIZE` - Call data access
- `GASPRICE`, `EXTCODESIZE`, `EXTCODECOPY` - External queries

### Stack Operations (0x50, 0x60-0x7F, 0x80-0x8F, 0x90-0x9F)
Stack manipulation:
- `POP` - Remove top item
- `PUSH1`-`PUSH32` - Push immediate values
- `DUP1`-`DUP16` - Duplicate stack items
- `SWAP1`-`SWAP16` - Swap stack items

### Memory Operations (0x51-0x59)
Memory access and manipulation:
- `MLOAD`, `MSTORE`, `MSTORE8` - Memory load/store
- `MSIZE` - Memory size query
- Data copying operations

### System Operations (0xF0-0xFF)
High-level system operations:
- `CREATE`, `CREATE2` - Contract creation
- `CALL`, `STATICCALL`, `DELEGATECALL` - External calls
- `RETURN`, `REVERT` - Execution termination
- `SELFDESTRUCT` - Contract destruction

## Hard Fork Support

Opcodes include hard fork compatibility information:
```zig
pub const HardforkIntroduction = enum {
    Frontier,
    Homestead,
    Byzantium,
    Constantinople,
    Istanbul,
    Berlin,
    London,
    Shanghai,
    Cancun,
};

pub fn is_opcode_available(opcode: Opcode, hardfork: Hardfork) bool {
    const info = get_opcode_info(@intFromEnum(opcode));
    return @intFromEnum(hardfork) >= @intFromEnum(info.introduced_in);
}
```

## Integration Notes

### With Instructions Module
Opcodes provide the foundation for instruction handlers:
- Handler function binding through opcode enumeration
- Gas cost calculation for each instruction
- Stack requirement validation
- Control flow analysis

### With Frame Module
Integration supports:
- Opcode dispatch table generation
- Runtime validation of instruction sequences
- Gas accounting for instruction execution
- Stack depth analysis for optimization

### With Dispatch Module  
Opcode information enables:
- Efficient dispatch table construction
- Jump destination pre-validation
- Synthetic opcode pattern recognition
- Performance optimization hints

All opcode operations maintain type safety and comprehensive error handling through Zig's strong type system and error union patterns.
