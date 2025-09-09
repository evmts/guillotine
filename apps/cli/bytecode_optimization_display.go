package main

import (
	"fmt"
	"math/big"

	"github.com/evmts/guillotine/sdks/go/bytecode"
)

// OptimizedInstruction represents a single instruction in the optimized bytecode
type OptimizedInstruction struct {
	Index       uint32   // Index in the optimized instruction stream
	PC          uint32   // PC in the original bytecode  
	Opcode      uint8    // The opcode (regular or synthetic)
	OpcodeName  string   // Human-readable name
	Operand     *big.Int // Optional operand for PUSH instructions or fusions
	IsFusion    bool     // Whether this is a fused instruction
	IsJumpDest  bool     // Whether this is a valid jump destination
	JumpTarget  *uint32  // Target index for JUMP/JUMPI instructions (nil if not a jump)
}


// OptimizedBytecode represents the complete optimization analysis
type OptimizedBytecode struct {
	Instructions    []OptimizedInstruction
	Stats           *bytecode.Stats    // Bytecode statistics from existing analysis
	Analysis        *bytecode.Analysis // The raw analysis from bytecode
	RuntimeFusions  int                // Count of runtime fusions detected
}

// GetOptimizedBytecode shows what the bytecode would look like if optimized
// Uses existing analysis data instead of re-parsing bytecode
func GetOptimizedBytecode(code []byte) (*OptimizedBytecode, error) {
	// Create bytecode handle
	bc, err := bytecode.New(code)
	if err != nil {
		return nil, fmt.Errorf("failed to create bytecode: %w", err)
	}
	defer bc.Destroy()

	// Get the existing analysis and stats
	analysis, err := bc.Analyze()
	if err != nil {
		return nil, fmt.Errorf("failed to analyze: %w", err)
	}

	stats, err := bc.GetStats()
	if err != nil {
		return nil, fmt.Errorf("failed to get stats: %w", err)
	}

	result := &OptimizedBytecode{
		Instructions:   make([]OptimizedInstruction, 0),
		Analysis:       analysis,
		Stats:          stats,
		RuntimeFusions: 0,
	}

	// Find runtime fusions at PUSH locations
	// Note: analysis.PushPCs only contains PUSHes NOT covered by analysis patterns
	runtimeFusions := make(map[uint32]struct {
		pushSize int
		nextOp   uint8
		length   uint32
	})
	
	for _, pushPC := range analysis.PushPCs {
		if pushPC >= uint32(len(code)) {
			continue
		}
		
		opcode := code[pushPC]
		if opcode < 0x60 || opcode > 0x7f { // not a PUSH
			continue
		}
		
		pushSize := int(opcode - 0x5f)
		nextOpPC := pushPC + uint32(1 + pushSize)
		
		if nextOpPC < uint32(len(code)) && isRuntimeFusable(code[nextOpPC]) {
			runtimeFusions[pushPC] = struct {
				pushSize int
				nextOp   uint8
				length   uint32
			}{pushSize, code[nextOpPC], uint32(1 + pushSize + 1)}
			result.RuntimeFusions++
		}
	}

	// Build instruction stream in PC order
	instrIndex := uint32(0)
	originalPC := uint32(0)

	// Build a map from original JUMPDEST PCs to instruction index for jump target resolution
	jumpDestToIndex := make(map[uint32]uint32)

	for originalPC < uint32(len(code)) {
		// Check for runtime fusion starting at this PC  
		if fusion, hasRuntimeFusion := runtimeFusions[originalPC]; hasRuntimeFusion {
			value := extractPushValue(code, originalPC, fusion.pushSize)
			syntheticOp, name := getSyntheticOpcodeInfo(fusion.nextOp, value)
			
			result.Instructions = append(result.Instructions, OptimizedInstruction{
				Index:      instrIndex,
				PC:         originalPC,
				Opcode:     syntheticOp,
				OpcodeName: name,
				Operand:    value,
				IsFusion:   true,
			})
			instrIndex++
			originalPC += fusion.length
			continue
		}

		// Regular instruction (including those in analysis patterns)
		opcode := code[originalPC]
		// Get push value if it is a PUSH
		var operand *big.Int
		if opcode >= 0x60 && opcode <= 0x7f {
			operand = extractPushValue(code, originalPC, int(opcode - 0x5f))
		}

		// Check if this PC is a jump destination and map it to instruction index
		isJumpDest := false
		for _, jd := range analysis.JumpDests {
			if jd == originalPC {
				isJumpDest = true
				jumpDestToIndex[originalPC] = instrIndex
				break
			}
		}

		result.Instructions = append(result.Instructions, OptimizedInstruction{
			Index:      instrIndex,
			PC:         originalPC,
			Opcode:     opcode,
			OpcodeName: bytecode.OpcodeName(opcode),
			Operand:    operand,
			IsFusion:   false,
			IsJumpDest: isJumpDest,
		})
		instrIndex++
		originalPC++
	}

	// Second pass: resolve jump targets now that we have the JUMPDEST mapping
	for i := range result.Instructions {
		instr := &result.Instructions[i]
		
		// Handle fused jump instructions
		if instr.IsFusion && instr.Operand != nil {
			if instr.OpcodeName == "PUSH_JUMP_INLINE" || instr.OpcodeName == "PUSH_JUMPI_INLINE" {
				if instr.Operand.IsUint64() && instr.Operand.Uint64() <= 0xFFFFFFFF {
					originalTarget := uint32(instr.Operand.Uint64())
					if targetIndex, exists := jumpDestToIndex[originalTarget]; exists {
						instr.JumpTarget = &targetIndex
					}
				}
			}
		}
		
		// Handle regular JUMP/JUMPI instructions
		if instr.Opcode == 0x56 || instr.Opcode == 0x57 { // JUMP or JUMPI
			// Look backward for the last PUSH instruction
			for j := i - 1; j >= 0; j-- {
				prevInstr := &result.Instructions[j]
				if prevInstr.Operand != nil && !prevInstr.IsFusion {
					if prevInstr.Operand.IsUint64() && prevInstr.Operand.Uint64() <= 0xFFFFFFFF {
						originalTarget := uint32(prevInstr.Operand.Uint64())
						if targetIndex, exists := jumpDestToIndex[originalTarget]; exists {
							instr.JumpTarget = &targetIndex
						}
					}
					break
				}
			}
		}
	}

	return result, nil
}

// isRuntimeFusable checks if an opcode can be fused at runtime
func isRuntimeFusable(opcode uint8) bool {
	switch opcode {
	case 0x01, // ADD
		0x02,  // MUL
		0x03,  // SUB
		0x04,  // DIV
		0x16,  // AND
		0x17,  // OR
		0x18,  // XOR
		0x51,  // MLOAD
		0x52,  // MSTORE
		0x53,  // MSTORE8
		0x56,  // JUMP
		0x57:  // JUMPI
		return true
	}
	return false
}

// getSyntheticOpcodeInfo returns the synthetic opcode and name for a fusion
func getSyntheticOpcodeInfo(opcode uint8, value *big.Int) (uint8, string) {
	isInline := value.BitLen() <= 64 // Can fit in 8 bytes
	
	switch opcode {
	case 0x01: // ADD
		if isInline {
			return 0xA5, "PUSH_ADD_INLINE"
		}
		return 0xA6, "PUSH_ADD_POINTER"
	case 0x02: // MUL
		if isInline {
			return 0xA7, "PUSH_MUL_INLINE"
		}
		return 0xA8, "PUSH_MUL_POINTER"
	case 0x03: // SUB
		if isInline {
			return 0xAF, "PUSH_SUB_INLINE"
		}
		return 0xB0, "PUSH_SUB_POINTER"
	case 0x04: // DIV
		if isInline {
			return 0xA9, "PUSH_DIV_INLINE"
		}
		return 0xAA, "PUSH_DIV_POINTER"
	case 0x16: // AND
		if isInline {
			return 0xB5, "PUSH_AND_INLINE"
		}
		return 0xB6, "PUSH_AND_POINTER"
	case 0x17: // OR
		if isInline {
			return 0xB7, "PUSH_OR_INLINE"
		}
		return 0xB8, "PUSH_OR_POINTER"
	case 0x18: // XOR
		if isInline {
			return 0xB9, "PUSH_XOR_INLINE"
		}
		return 0xBA, "PUSH_XOR_POINTER"
	case 0x51: // MLOAD
		if isInline {
			return 0xB1, "PUSH_MLOAD_INLINE"
		}
		return 0xB2, "PUSH_MLOAD_POINTER"
	case 0x52: // MSTORE
		if isInline {
			return 0xB3, "PUSH_MSTORE_INLINE"
		}
		return 0xB4, "PUSH_MSTORE_POINTER"
	case 0x53: // MSTORE8
		if isInline {
			return 0xBB, "PUSH_MSTORE8_INLINE"
		}
		return 0xBC, "PUSH_MSTORE8_POINTER"
	case 0x56: // JUMP
		if isInline {
			return 0xAB, "PUSH_JUMP_INLINE"
		}
		return 0xAC, "PUSH_JUMP_POINTER"
	case 0x57: // JUMPI
		if isInline {
			return 0xAD, "PUSH_JUMPI_INLINE"
		}
		return 0xAE, "PUSH_JUMPI_POINTER"
	}
	
	return opcode, bytecode.OpcodeName(opcode) // Should never reach here
}

// extractPushValue extracts the value from a PUSH instruction
func extractPushValue(code []byte, pc uint32, size int) *big.Int {
	value := new(big.Int)
	for i := 1; i <= size && pc+uint32(i) < uint32(len(code)); i++ {
		value.Lsh(value, 8)
		value.Or(value, big.NewInt(int64(code[pc+uint32(i)])))
	}
	return value
}

