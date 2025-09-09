package bytecode

import (
	"fmt"

	"github.com/evmts/guillotine/sdks/go/bytecode"
)

// Instruction represents a single EVM instruction with metadata
type Instruction struct {
	LineNumber      int      `json:"line_number"`
	PC              uint64   `json:"pc"`
	IsJumpDest      bool     `json:"is_jump_dest"`
	HexBytes        []string `json:"hex_bytes"`
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

