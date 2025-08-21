#!/usr/bin/env python3
"""
Analyze EVM bytecode to determine suitability for register-based execution.

This tool examines bytecode characteristics to identify patterns that would
benefit from register allocation vs traditional stack-based execution.
"""

import sys
import os
from dataclasses import dataclass, field
from typing import List, Dict, Set, Tuple
from collections import defaultdict, Counter

# EVM Opcode definitions
OPCODES = {
    0x00: ("STOP", 0, 0),
    0x01: ("ADD", 2, 1),
    0x02: ("MUL", 2, 1),
    0x03: ("SUB", 2, 1),
    0x04: ("DIV", 2, 1),
    0x05: ("SDIV", 2, 1),
    0x06: ("MOD", 2, 1),
    0x07: ("SMOD", 2, 1),
    0x08: ("ADDMOD", 3, 1),
    0x09: ("MULMOD", 3, 1),
    0x0a: ("EXP", 2, 1),
    0x0b: ("SIGNEXTEND", 2, 1),
    0x10: ("LT", 2, 1),
    0x11: ("GT", 2, 1),
    0x12: ("SLT", 2, 1),
    0x13: ("SGT", 2, 1),
    0x14: ("EQ", 2, 1),
    0x15: ("ISZERO", 1, 1),
    0x16: ("AND", 2, 1),
    0x17: ("OR", 2, 1),
    0x18: ("XOR", 2, 1),
    0x19: ("NOT", 1, 1),
    0x1a: ("BYTE", 2, 1),
    0x1b: ("SHL", 2, 1),
    0x1c: ("SHR", 2, 1),
    0x1d: ("SAR", 2, 1),
    0x20: ("KECCAK256", 2, 1),
    0x30: ("ADDRESS", 0, 1),
    0x31: ("BALANCE", 1, 1),
    0x32: ("ORIGIN", 0, 1),
    0x33: ("CALLER", 0, 1),
    0x34: ("CALLVALUE", 0, 1),
    0x35: ("CALLDATALOAD", 1, 1),
    0x36: ("CALLDATASIZE", 0, 1),
    0x37: ("CALLDATACOPY", 3, 0),
    0x38: ("CODESIZE", 0, 1),
    0x39: ("CODECOPY", 3, 0),
    0x3a: ("GASPRICE", 0, 1),
    0x3b: ("EXTCODESIZE", 1, 1),
    0x3c: ("EXTCODECOPY", 4, 0),
    0x3d: ("RETURNDATASIZE", 0, 1),
    0x3e: ("RETURNDATACOPY", 3, 0),
    0x3f: ("EXTCODEHASH", 1, 1),
    0x40: ("BLOCKHASH", 1, 1),
    0x41: ("COINBASE", 0, 1),
    0x42: ("TIMESTAMP", 0, 1),
    0x43: ("NUMBER", 0, 1),
    0x44: ("DIFFICULTY", 0, 1),
    0x45: ("GASLIMIT", 0, 1),
    0x46: ("CHAINID", 0, 1),
    0x47: ("SELFBALANCE", 0, 1),
    0x48: ("BASEFEE", 0, 1),
    0x50: ("POP", 1, 0),
    0x51: ("MLOAD", 1, 1),
    0x52: ("MSTORE", 2, 0),
    0x53: ("MSTORE8", 2, 0),
    0x54: ("SLOAD", 1, 1),
    0x55: ("SSTORE", 2, 0),
    0x56: ("JUMP", 1, 0),
    0x57: ("JUMPI", 2, 0),
    0x58: ("PC", 0, 1),
    0x59: ("MSIZE", 0, 1),
    0x5a: ("GAS", 0, 1),
    0x5b: ("JUMPDEST", 0, 0),
    0x5f: ("PUSH0", 0, 1),
    0xf3: ("RETURN", 2, 0),
    0xfd: ("REVERT", 2, 0),
    0xfe: ("INVALID", 0, 0),
    0xff: ("SELFDESTRUCT", 1, 0),
}

# DUP and SWAP opcodes
for i in range(1, 17):
    OPCODES[0x80 + i - 1] = (f"DUP{i}", i, i + 1)
    OPCODES[0x90 + i - 1] = (f"SWAP{i}", i + 1, i + 1)

# PUSH opcodes
for i in range(1, 33):
    OPCODES[0x60 + i - 1] = (f"PUSH{i}", 0, 1)

# LOG opcodes
for i in range(0, 5):
    OPCODES[0xa0 + i] = (f"LOG{i}", i + 2, 0)

# CALL opcodes
OPCODES[0xf0] = ("CREATE", 3, 1)
OPCODES[0xf1] = ("CALL", 7, 1)
OPCODES[0xf2] = ("CALLCODE", 7, 1)
OPCODES[0xf4] = ("DELEGATECALL", 6, 1)
OPCODES[0xf5] = ("CREATE2", 4, 1)
OPCODES[0xfa] = ("STATICCALL", 6, 1)


@dataclass
class BasicBlock:
    """Represents a basic block of EVM bytecode."""
    start_pc: int
    end_pc: int
    instructions: List[Tuple[int, str, bytes]]  # (pc, opcode_name, raw_bytes)
    successors: List[int] = field(default_factory=list)
    predecessors: List[int] = field(default_factory=list)
    
    # Analysis results
    max_stack_depth: int = 0
    stack_depth_variance: int = 0
    arithmetic_density: float = 0.0
    memory_operations: int = 0
    storage_operations: int = 0
    complex_stack_ops: int = 0  # DUP/SWAP operations
    
    def __len__(self):
        return len(self.instructions)


@dataclass
class LoopInfo:
    """Information about detected loops."""
    header_pc: int
    back_edge_pc: int
    blocks: List[int]  # Block indices in the loop
    depth: int  # Nesting depth
    iteration_estimate: int = 0


@dataclass
class BytecodeAnalysis:
    """Complete analysis results for a contract."""
    name: str
    total_instructions: int
    basic_blocks: List[BasicBlock]
    loops: List[LoopInfo]
    
    # Global metrics
    total_arithmetic_ops: int = 0
    total_memory_ops: int = 0
    total_storage_ops: int = 0
    total_stack_manipulation: int = 0
    max_stack_depth: int = 0
    
    # Suitability scores (0-100)
    register_suitability_score: float = 0.0
    hot_path_percentage: float = 0.0
    
    # Detailed characteristics
    opcode_distribution: Dict[str, int] = field(default_factory=dict)
    block_size_distribution: List[int] = field(default_factory=list)


def parse_bytecode(hex_str: str) -> bytes:
    """Parse hex string bytecode into bytes."""
    hex_str = hex_str.strip()
    if hex_str.startswith('0x'):
        hex_str = hex_str[2:]
    return bytes.fromhex(hex_str)


def identify_basic_blocks(bytecode: bytes) -> List[BasicBlock]:
    """Identify basic blocks in bytecode."""
    blocks = []
    leaders = {0}  # Set of block start addresses
    
    pc = 0
    while pc < len(bytecode):
        opcode = bytecode[pc]
        
        if opcode == 0x56:  # JUMP
            # Next instruction after JUMP is a leader
            if pc + 1 < len(bytecode):
                leaders.add(pc + 1)
        elif opcode == 0x57:  # JUMPI
            # Next instruction after JUMPI is a leader
            if pc + 1 < len(bytecode):
                leaders.add(pc + 1)
        elif opcode == 0x5b:  # JUMPDEST
            # JUMPDEST is always a leader
            leaders.add(pc)
        
        # Handle PUSH instructions
        if 0x60 <= opcode <= 0x7f:
            push_size = opcode - 0x5f
            pc += push_size
        
        pc += 1
    
    # Sort leaders and create blocks
    sorted_leaders = sorted(leaders)
    for i, start_pc in enumerate(sorted_leaders):
        end_pc = sorted_leaders[i + 1] if i + 1 < len(sorted_leaders) else len(bytecode)
        
        # Extract instructions for this block
        instructions = []
        pc = start_pc
        while pc < end_pc:
            opcode = bytecode[pc]
            opcode_info = OPCODES.get(opcode, ("UNKNOWN", 0, 0))
            
            raw_bytes = bytes([opcode])
            if 0x60 <= opcode <= 0x7f:
                push_size = opcode - 0x5f
                raw_bytes = bytecode[pc:pc + 1 + push_size]
                pc += push_size
            
            instructions.append((pc, opcode_info[0], raw_bytes))
            pc += 1
            
            # Stop at control flow instructions
            if opcode in [0x00, 0x56, 0x57, 0xf3, 0xfd, 0xff]:  # STOP, JUMP, JUMPI, RETURN, REVERT, SELFDESTRUCT
                break
        
        block = BasicBlock(start_pc=start_pc, end_pc=pc, instructions=instructions)
        blocks.append(block)
    
    return blocks


def analyze_stack_depth(block: BasicBlock) -> Tuple[int, int]:
    """Analyze stack depth changes in a block."""
    current_depth = 0
    max_depth = 0
    min_depth = 0
    
    for pc, opcode_name, _ in block.instructions:
        if opcode_name == "UNKNOWN":
            continue
            
        # Get stack effect
        for opcode_byte, (name, inputs, outputs) in OPCODES.items():
            if name == opcode_name:
                current_depth -= inputs
                min_depth = min(min_depth, current_depth)
                current_depth += outputs
                max_depth = max(max_depth, current_depth)
                break
    
    variance = max_depth - min_depth
    return max_depth, variance


def analyze_block_characteristics(block: BasicBlock) -> None:
    """Analyze characteristics of a basic block."""
    arithmetic_ops = {"ADD", "SUB", "MUL", "DIV", "MOD", "ADDMOD", "MULMOD", "EXP", 
                     "LT", "GT", "SLT", "SGT", "EQ", "AND", "OR", "XOR", "NOT", "SHL", "SHR", "SAR"}
    memory_ops = {"MLOAD", "MSTORE", "MSTORE8", "KECCAK256"}
    storage_ops = {"SLOAD", "SSTORE"}
    stack_manipulation = set()
    
    for i in range(1, 17):
        stack_manipulation.add(f"DUP{i}")
        stack_manipulation.add(f"SWAP{i}")
    
    arithmetic_count = 0
    memory_count = 0
    storage_count = 0
    stack_manip_count = 0
    
    for pc, opcode_name, _ in block.instructions:
        if opcode_name in arithmetic_ops:
            arithmetic_count += 1
        elif opcode_name in memory_ops:
            memory_count += 1
        elif opcode_name in storage_ops:
            storage_count += 1
        elif opcode_name in stack_manipulation:
            stack_manip_count += 1
    
    block.arithmetic_density = arithmetic_count / len(block) if len(block) > 0 else 0
    block.memory_operations = memory_count
    block.storage_operations = storage_count
    block.complex_stack_ops = stack_manip_count
    
    max_depth, variance = analyze_stack_depth(block)
    block.max_stack_depth = max_depth
    block.stack_depth_variance = variance


def detect_loops(blocks: List[BasicBlock], bytecode: bytes) -> List[LoopInfo]:
    """Detect loops in the control flow graph."""
    loops = []
    
    # Build CFG edges
    for i, block in enumerate(blocks):
        if not block.instructions:
            continue
            
        last_pc, last_opcode, last_bytes = block.instructions[-1]
        
        # For JUMP/JUMPI, look for preceding PUSH to find target
        if last_opcode in ["JUMP", "JUMPI"]:
            # Look backwards for a PUSH instruction
            target = None
            for j in range(len(block.instructions) - 2, -1, -1):
                inst_pc, inst_opcode, inst_bytes = block.instructions[j]
                if inst_opcode.startswith("PUSH") and len(inst_bytes) > 1:
                    # Extract target from PUSH data
                    target = int.from_bytes(inst_bytes[1:], 'big')
                    break
            
            if target is not None:
                # Find target block
                for j, target_block in enumerate(blocks):
                    if target_block.start_pc == target or (target_block.start_pc < target < target_block.end_pc and bytecode[target] == 0x5b):
                        block.successors.append(j)
                        target_block.predecessors.append(i)
                        
                        # Check for back edge (loop)
                        if j <= i:
                            loops.append(LoopInfo(
                                header_pc=target,
                                back_edge_pc=last_pc,
                                blocks=list(range(j, i + 1)),
                                depth=1
                            ))
        
        # Handle fall-through for non-terminating instructions
        if last_opcode not in ["JUMP", "RETURN", "REVERT", "STOP", "SELFDESTRUCT", "INVALID"]:
            if i + 1 < len(blocks):
                block.successors.append(i + 1)
                blocks[i + 1].predecessors.append(i)
    
    return loops


def calculate_register_suitability(analysis: BytecodeAnalysis) -> float:
    """Calculate overall suitability score for register-based execution."""
    score = 0.0
    
    # Factor 1: Arithmetic density in hot paths (40%)
    hot_arithmetic = 0
    total_hot_instructions = 0
    
    for loop in analysis.loops:
        for block_idx in loop.blocks:
            block = analysis.basic_blocks[block_idx]
            hot_arithmetic += block.arithmetic_density * len(block)
            total_hot_instructions += len(block)
    
    if total_hot_instructions > 0:
        arithmetic_score = (hot_arithmetic / total_hot_instructions) * 40
    else:
        # No loops, check overall arithmetic density
        arithmetic_score = (analysis.total_arithmetic_ops / analysis.total_instructions) * 20
    
    score += arithmetic_score
    
    # Factor 2: Stack depth stability (20%)
    avg_variance = sum(b.stack_depth_variance for b in analysis.basic_blocks) / len(analysis.basic_blocks)
    if avg_variance < 4:
        score += 20
    elif avg_variance < 8:
        score += 10
    
    # Factor 3: Block size (20%)
    avg_block_size = sum(len(b) for b in analysis.basic_blocks) / len(analysis.basic_blocks)
    if avg_block_size > 10:
        score += 20
    elif avg_block_size > 5:
        score += 10
    
    # Factor 4: Low stack manipulation overhead (20%)
    stack_overhead = analysis.total_stack_manipulation / analysis.total_instructions
    if stack_overhead < 0.1:
        score += 20
    elif stack_overhead < 0.2:
        score += 10
    
    return score


def analyze_bytecode_file(filepath: str, name: str) -> BytecodeAnalysis:
    """Analyze a bytecode file and return analysis results."""
    with open(filepath, 'r') as f:
        hex_str = f.read().strip()
    
    bytecode = parse_bytecode(hex_str)
    blocks = identify_basic_blocks(bytecode)
    
    analysis = BytecodeAnalysis(
        name=name,
        total_instructions=sum(len(b) for b in blocks),
        basic_blocks=blocks,
        loops=[]
    )
    
    # Analyze each block
    opcode_counter = Counter()
    for block in blocks:
        analyze_block_characteristics(block)
        
        # Update global counters
        analysis.total_arithmetic_ops += sum(1 for _, op, _ in block.instructions 
                                           if op in {"ADD", "SUB", "MUL", "DIV", "MOD", "LT", "GT", "EQ"})
        analysis.total_memory_ops += block.memory_operations
        analysis.total_storage_ops += block.storage_operations
        analysis.total_stack_manipulation += block.complex_stack_ops
        analysis.max_stack_depth = max(analysis.max_stack_depth, block.max_stack_depth)
        
        # Count opcodes
        for _, opcode_name, _ in block.instructions:
            opcode_counter[opcode_name] += 1
    
    analysis.opcode_distribution = dict(opcode_counter)
    analysis.block_size_distribution = [len(b) for b in blocks]
    
    # Detect loops
    analysis.loops = detect_loops(blocks, bytecode)
    
    # Calculate hot path percentage
    hot_instructions = 0
    for loop in analysis.loops:
        for block_idx in loop.blocks:
            hot_instructions += len(blocks[block_idx])
    
    analysis.hot_path_percentage = (hot_instructions / analysis.total_instructions) * 100 if analysis.total_instructions > 0 else 0
    
    # Calculate suitability score
    analysis.register_suitability_score = calculate_register_suitability(analysis)
    
    return analysis


def print_analysis_summary(analysis: BytecodeAnalysis):
    """Print a summary of the analysis results."""
    print(f"\n{'='*60}")
    print(f"Contract: {analysis.name}")
    print(f"{'='*60}")
    
    # Add stack depth distribution analysis
    if analysis.name == "snailtracer":
        depth_distribution = defaultdict(int)
        for block in analysis.basic_blocks:
            depth_distribution[block.max_stack_depth] += len(block)
        
        below_8 = sum(count for depth, count in depth_distribution.items() if depth <= 8)
        total = sum(depth_distribution.values())
        
        print(f"\nStack Depth Distribution:")
        for depth in sorted(depth_distribution.keys()):
            instructions = depth_distribution[depth]
            percentage = (instructions / total) * 100
            print(f"  Depth {depth}: {instructions} instructions ({percentage:.1f}%)")
        
        print(f"\nInstructions with stack depth <= 8: {below_8}/{total} ({below_8/total*100:.1f}%)")
    print(f"Total Instructions: {analysis.total_instructions}")
    print(f"Basic Blocks: {len(analysis.basic_blocks)}")
    print(f"Loops Detected: {len(analysis.loops)}")
    print(f"Hot Path Coverage: {analysis.hot_path_percentage:.1f}%")
    print(f"\nCharacteristics:")
    print(f"  Arithmetic Operations: {analysis.total_arithmetic_ops} ({analysis.total_arithmetic_ops/analysis.total_instructions*100:.1f}%)")
    print(f"  Memory Operations: {analysis.total_memory_ops}")
    print(f"  Storage Operations: {analysis.total_storage_ops}")
    print(f"  Stack Manipulation: {analysis.total_stack_manipulation} ({analysis.total_stack_manipulation/analysis.total_instructions*100:.1f}%)")
    print(f"  Max Stack Depth: {analysis.max_stack_depth}")
    
    if analysis.loops:
        print(f"\nLoop Analysis:")
        for i, loop in enumerate(analysis.loops):
            loop_size = sum(len(analysis.basic_blocks[idx]) for idx in loop.blocks)
            print(f"  Loop {i+1}: {len(loop.blocks)} blocks, {loop_size} instructions")
    
    print(f"\nRegister Suitability Score: {analysis.register_suitability_score:.1f}/100")
    
    if analysis.register_suitability_score >= 70:
        print("  ✓ HIGHLY SUITABLE for register-based execution")
    elif analysis.register_suitability_score >= 40:
        print("  ~ MODERATELY SUITABLE for register-based execution")
    else:
        print("  ✗ Better suited for stack-based execution")
    
    # Top opcodes
    print(f"\nTop 10 Opcodes:")
    sorted_opcodes = sorted(analysis.opcode_distribution.items(), key=lambda x: x[1], reverse=True)[:10]
    for opcode, count in sorted_opcodes:
        print(f"  {opcode}: {count}")


def main():
    """Main entry point."""
    cases_dir = "/Users/williamcory/guillotine/bench/official/cases"
    
    # Key benchmarks to analyze
    benchmarks = [
        "snailtracer",
        "ten-thousand-hashes",
        "erc20-transfer",
        "opcodes-arithmetic",
        "opcodes-memory",
        "opcodes-storage-warm"
    ]
    
    all_analyses = []
    
    for benchmark in benchmarks:
        bytecode_path = os.path.join(cases_dir, benchmark, "bytecode.txt")
        if os.path.exists(bytecode_path):
            analysis = analyze_bytecode_file(bytecode_path, benchmark)
            all_analyses.append(analysis)
            print_analysis_summary(analysis)
    
    # Overall summary
    print(f"\n{'='*60}")
    print("OVERALL SUMMARY")
    print(f"{'='*60}")
    
    suitable_count = sum(1 for a in all_analyses if a.register_suitability_score >= 70)
    moderate_count = sum(1 for a in all_analyses if 40 <= a.register_suitability_score < 70)
    
    print(f"Highly Suitable: {suitable_count}/{len(all_analyses)}")
    print(f"Moderately Suitable: {moderate_count}/{len(all_analyses)}")
    print(f"Stack-Based Better: {len(all_analyses) - suitable_count - moderate_count}/{len(all_analyses)}")
    
    print("\nRecommendation:")
    if suitable_count >= len(all_analyses) // 2:
        print("✓ Register-based execution would provide significant benefits for these benchmarks!")
        print("  Focus on loop-heavy and arithmetic-intensive code paths.")
    else:
        print("~ Mixed approach recommended:")
        print("  - Use register allocation for hot loops and arithmetic sequences")
        print("  - Keep stack-based execution for complex control flow and deep stack usage")


if __name__ == "__main__":
    main()