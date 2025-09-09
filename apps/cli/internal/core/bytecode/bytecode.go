package bytecode

import (
	"fmt"
	"strings"

	"github.com/evmts/guillotine/sdks/go/bytecode"
)

// Instruction represents a single EVM instruction with metadata
type Instruction struct {
	LineNumber      int      `json:"line_number"`
	PC              uint64   `json:"pc"`
	IsJumpDest      bool     `json:"is_jump_dest"`
	HexBytes        []string `json:"hex_bytes"`
	OpcodeHex       uint8    `json:"opcode_hex"`
	OpcodeName      string   `json:"opcode_name"`
	PushValue       *string  `json:"push_value,omitempty"`
	PushValueDecimal *uint64 `json:"push_value_decimal,omitempty"`
	GasCost         *uint64  `json:"gas_cost,omitempty"`
	StackInputs     *uint8   `json:"stack_inputs,omitempty"`
	StackOutputs    *uint8   `json:"stack_outputs,omitempty"`
}

// DisassemblyResult represents the complete disassembly output
type DisassemblyResult struct {
	Length           uint64        `json:"length"`
	Instructions     []Instruction `json:"instructions"`
	JumpDestCount    uint32        `json:"jump_dest_count"`
	TotalInstructions uint32       `json:"total_instructions"`
	Analysis      *bytecode.Analysis `json:"analysis"`
}

// AnalyzeBytecode returns structured bytecode disassembly
func AnalyzeBytecode(bc *bytecode.Bytecode) (*DisassemblyResult, error) {
	if bc == nil {
		return nil, fmt.Errorf("bytecode is nil")
	}

	length, err := bc.Length()
	if err != nil {
		return nil, fmt.Errorf("failed to get bytecode length: %w", err)
	}

	data, err := bc.RuntimeData()
	if err != nil {
		return nil, fmt.Errorf("failed to get runtime data: %w", err)
	}

	analysis, err := bc.Analyze()
	if err != nil {
		return nil, fmt.Errorf("failed to analyze bytecode: %w", err)
	}

	result := &DisassemblyResult{
		Length:       length,
		Instructions: make([]Instruction, 0),
		Analysis: analysis,
	}

	var pc uint64 = 0
	var lineNum int = 1
	
	// Create a map for fast jump destination lookup
	jumpDestMap := make(map[uint64]bool)
	for _, dest := range analysis.JumpDests {
		jumpDestMap[uint64(dest)] = true
	}
	jumpDestCount := uint32(len(analysis.JumpDests))

	for pc < length {
		opcodeValue, err := bc.OpcodeAt(pc)
		if err != nil {
			return nil, fmt.Errorf("failed to get opcode at PC %d: %w", pc, err)
		}

		// Check if this is a jump destination using pre-computed map
		isJumpDest := jumpDestMap[pc]

		// Get instruction size
		instructionSize := getInstructionSize(opcodeValue)
		
		// Build hex bytes
		hexBytes := make([]string, 0, instructionSize)
		for i := uint64(0); i < instructionSize && pc+i < length; i++ {
			if pc+i < uint64(len(data)) {
				hexBytes = append(hexBytes, fmt.Sprintf("%02x", data[pc+i]))
			}
		}

		// Get opcode name
		opcodeName := bytecode.OpcodeName(opcodeValue)

		instruction := Instruction{
			LineNumber: lineNum,
			PC:         pc,
			IsJumpDest: isJumpDest,
			HexBytes:   hexBytes,
			OpcodeHex:  opcodeValue,
			OpcodeName: opcodeName,
		}

		// Handle PUSH instructions
		if isPushOpcode(opcodeValue) {
			pushSize := getPushSize(opcodeValue)
			
			// Handle PUSH0 special case
			if opcodeValue == 0x5F { // PUSH0
				pushValue := "0x0"
				pushDecimal := uint64(0)
				instruction.PushValue = &pushValue
				instruction.PushValueDecimal = &pushDecimal
			} else if pushSize > 0 && pushSize <= 32 {
				// Extract push value
				value := extractPushValue(data, pc+1, pushSize, length)
				pushValueHex := fmt.Sprintf("0x%x", value)
				instruction.PushValue = &pushValueHex
				
				// Add decimal for small values
				if value <= 0xFFFF {
					instruction.PushValueDecimal = &value
				}
			}
		}

		// Add opcode info from SDK
		opcodeInfo := bytecode.OpcodeInfo(opcodeValue)
		if opcodeInfo.GasCost > 0 {
			gasCost := uint64(opcodeInfo.GasCost)
			instruction.GasCost = &gasCost
		}
		if opcodeInfo.StackInputs > 0 {
			instruction.StackInputs = &opcodeInfo.StackInputs
		}
		if opcodeInfo.StackOutputs > 0 {
			instruction.StackOutputs = &opcodeInfo.StackOutputs
		}

		result.Instructions = append(result.Instructions, instruction)
		pc += instructionSize
		lineNum++
	}

	result.JumpDestCount = jumpDestCount
	result.TotalInstructions = uint32(lineNum - 1)

	return result, nil
}

func AnalyzeBytecodeFromBytes(bc []byte) (*DisassemblyResult, error) {
	bytecode, err := bytecode.New(bc)
	if err != nil {
		return nil, fmt.Errorf("failed to create bytecode: %w", err)
	}
	return AnalyzeBytecode(bytecode)
}

// Return instructions that belong in a specific block
func GetInstructionsForBlock(dr *DisassemblyResult, blockIndex int) ([]Instruction, string, error) {
	if dr.Analysis == nil {
		return nil, "", fmt.Errorf("analysis is nil")
	}
	
	// Check bounds
	if blockIndex < 0 || blockIndex >= len(dr.Analysis.BasicBlocks) {
		return nil, "", fmt.Errorf("block index %d out of range [0, %d)", blockIndex, len(dr.Analysis.BasicBlocks))
	}
	
	// Get the boundaries of the block
	block := dr.Analysis.BasicBlocks[blockIndex]
	startPC := block.Start
	endPC := block.End

	blockInfo := fmt.Sprintf("PC %d-%d", startPC, endPC)
	
	// Convert PC range to instruction indices
	startIdx := -1
	endIdx := len(dr.Instructions)
	
	for i, instruction := range dr.Instructions {
		if instruction.PC == uint64(startPC) && startIdx == -1 {
			startIdx = i
		}
		if instruction.PC >= uint64(endPC) && endIdx == len(dr.Instructions) {
			endIdx = i
			break
		}
	}
	
	// Handle edge cases
	if startIdx == -1 {
		return nil, blockInfo, fmt.Errorf("start PC %d not found in instructions", startPC)
	}
	
	// Get the instructions that belong in the block
	return dr.Instructions[startIdx:endIdx], blockInfo, nil
}

func CalculateBlockGas(instructions []Instruction) uint64 {
	gas := uint64(0)
	for _, instruction := range instructions {
		if instruction.GasCost != nil {
			gas += *instruction.GasCost
		}
	}
	return gas
}

func ShouldHighlightOpcode(opcode string) bool {
	return opcode == "CALL" || opcode == "STATICCALL" || opcode == "DELEGATECALL" || opcode == "CREATE" || opcode == "CREATE2" || opcode == "SELFDESTRUCT" || opcode == "REVERT" || opcode == "INVALID" || opcode == "STOP" || opcode == "RETURN" || opcode == "SSTORE" || opcode == "SLOAD"
}

// IsJumpInstruction checks if an opcode is a JUMP or JUMPI instruction
func IsJumpInstruction(opcodeName string) bool {
	return opcodeName == "JUMP" || opcodeName == "JUMPI"
}

// GetJumpDestination extracts the jump destination from a sequence of instructions
// This only works for the common pattern where a PUSH immediately precedes the JUMP/JUMPI
// Returns nil if the destination cannot be reliably determined
func GetJumpDestination(instructions []Instruction, instructionIndex int) *uint64 {
	if instructionIndex < 0 || instructionIndex >= len(instructions) {
		return nil
	}
	
	// Check if current instruction is a jump
	if !IsJumpInstruction(instructions[instructionIndex].OpcodeName) {
		return nil
	}
	
	// For JUMPI, we need the second-to-last value on the stack (condition is on top)
	// For JUMP, we need the top value on the stack
	// Only handle the simple case: PUSH followed immediately by JUMP/JUMPI
	
	if instructions[instructionIndex].OpcodeName == "JUMP" {
		// For JUMP, check if the previous instruction is a PUSH with a value
		if instructionIndex > 0 {
			prev := &instructions[instructionIndex-1]
			if strings.HasPrefix(prev.OpcodeName, "PUSH") && prev.PushValueDecimal != nil {
				return prev.PushValueDecimal
			}
		}
	} else if instructions[instructionIndex].OpcodeName == "JUMPI" {
		// For JUMPI, we need to find the destination (not the condition)
		// Common patterns:
		// 1. PUSH dest, PUSH condition, JUMPI
		// 2. PUSH dest, <compute condition>, JUMPI
		
		// Check if previous instruction is a PUSH (likely the condition)
		if instructionIndex > 0 {
			prev := &instructions[instructionIndex-1]
			if strings.HasPrefix(prev.OpcodeName, "PUSH") {
				// Previous is a PUSH, check the one before that for destination
				if instructionIndex > 1 {
					prevPrev := &instructions[instructionIndex-2]
					if strings.HasPrefix(prevPrev.OpcodeName, "PUSH") && prevPrev.PushValueDecimal != nil {
						return prevPrev.PushValueDecimal
					}
				}
			} else {
				// Previous is not a PUSH, might be a computed condition
				// Look for the most recent PUSH before the condition computation
				for i := instructionIndex - 1; i >= 0 && i >= instructionIndex-3; i-- {
					inst := &instructions[i]
					if strings.HasPrefix(inst.OpcodeName, "PUSH") && inst.PushValueDecimal != nil {
						return inst.PushValueDecimal
					}
				}
			}
		}
	}
	
	return nil
}

// FindBlockContainingPC finds which block index contains the given PC
func FindBlockContainingPC(analysis *bytecode.Analysis, targetPC uint64) int {
	if analysis == nil || len(analysis.BasicBlocks) == 0 {
		return -1
	}
	
	for i, block := range analysis.BasicBlocks {
		if targetPC >= uint64(block.Start) && targetPC < uint64(block.End) {
			return i
		}
	}
	
	return -1
}

// FindInstructionIndexByPC finds the index of instruction with given PC within a block
func FindInstructionIndexByPC(instructions []Instruction, targetPC uint64) int {
	for i, inst := range instructions {
		if inst.PC == targetPC {
			return i
		}
	}
	return -1
}

// Helper functions

func getInstructionSize(opcode uint8) uint64 {
	if opcode >= 0x60 && opcode <= 0x7F { // PUSH1-PUSH32
		return 1 + uint64(opcode-0x5F)
	}
	return 1
}

func isPushOpcode(opcode uint8) bool {
	return opcode >= 0x5F && opcode <= 0x7F // PUSH0-PUSH32
}

func getPushSize(opcode uint8) uint8 {
	if opcode == 0x5F { // PUSH0
		return 0
	}
	if opcode >= 0x60 && opcode <= 0x7F { // PUSH1-PUSH32
		return opcode - 0x5F
	}
	return 0
}

func extractPushValue(data []byte, start uint64, size uint8, maxLen uint64) uint64 {
	var value uint64 = 0
	end := start + uint64(size)
	if end > maxLen {
		end = maxLen
	}
	
	for i := start; i < end && i < uint64(len(data)); i++ {
		value = (value << 8) | uint64(data[i])
	}
	
	return value
}

