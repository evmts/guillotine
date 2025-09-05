package disassembly

import (
	"fmt"
	"guillotine-cli/internal/types"
	
	"github.com/evmts/guillotine/bindings/go/disassembly"
)

// AnalyzeBytecode analyzes EVM bytecode and returns disassembly information
func AnalyzeBytecode(bytecode []byte) (*types.DisassemblyResult, error) {
	if len(bytecode) == 0 {
		return nil, fmt.Errorf("empty bytecode")
	}
	
	// Call the disassembly API
	analysis, err := disassembly.Analyze(bytecode)
	if err != nil {
		return nil, fmt.Errorf("disassembly failed: %w", err)
	}
	defer analysis.Free()
	
	// Convert to our internal type
	result := &types.DisassemblyResult{
		Instructions:    make([]types.DisassemblyInstruction, len(analysis.Instructions)),
		Jumpdests:       analysis.Jumpdests,
		BasicBlocks:     make([]types.BasicBlock, len(analysis.BasicBlocks)),
		Stats:           convertStats(analysis.Stats),
	}
	
	// Convert instructions
	for i, inst := range analysis.Instructions {
		var pushValue *types.PushValue
		if inst.PushValue != nil {
			pushValue = &types.PushValue{
				Low:  inst.PushValue.Low,
				High: inst.PushValue.High,
			}
		}
		
		result.Instructions[i] = types.DisassemblyInstruction{
			PC:           inst.PC,
			OpcodeHex:    inst.OpcodeHex,
			OpcodeName:   inst.OpcodeName,
			PushValue:    pushValue,
			GasCost:      inst.GasCost,
			StackInputs:  inst.StackInputs,
			StackOutputs: inst.StackOutputs,
		}
	}
	
	// Convert basic blocks
	for i, block := range analysis.BasicBlocks {
		result.BasicBlocks[i] = types.BasicBlock{
			Start: block.Start,
			End:   block.End,
		}
	}
	
	return result, nil
}

// GetInstructionsForBlock returns instructions for a specific block or all if no blocks
func GetInstructionsForBlock(result *types.DisassemblyResult, blockIndex int) ([]types.DisassemblyInstruction, string, error) {
	if result == nil || len(result.Instructions) == 0 {
		return nil, "", fmt.Errorf("no disassembly result available")
	}
	
	// If no blocks defined, return all instructions
	if len(result.BasicBlocks) == 0 {
		blockInfo := fmt.Sprintf("PC 0-%d", len(result.Instructions)-1)
		return result.Instructions, blockInfo, nil
	}
	
	// Validate block index
	if blockIndex < 0 || blockIndex >= len(result.BasicBlocks) {
		return nil, "", fmt.Errorf("invalid block index: %d", blockIndex)
	}
	
	block := result.BasicBlocks[blockIndex]
	
	// Find instructions in this block's PC range
	var blockInstructions []types.DisassemblyInstruction
	for _, inst := range result.Instructions {
		if inst.PC >= block.Start && inst.PC <= block.End {
			blockInstructions = append(blockInstructions, inst)
		}
	}
	
	blockInfo := fmt.Sprintf("PC %d-%d", block.Start, block.End)
	return blockInstructions, blockInfo, nil
}

// CalculateBlockGas calculates total gas cost for a set of instructions
func CalculateBlockGas(instructions []types.DisassemblyInstruction) uint32 {
	var totalGas uint32
	for _, inst := range instructions {
		totalGas += uint32(inst.GasCost)
	}
	return totalGas
}

// IsImportantOpcode determines if an opcode should be highlighted
func IsImportantOpcode(opcode string) bool {
	important := []string{
		"CALL", "STATICCALL", "DELEGATECALL", "CREATE", "CREATE2",
		"SELFDESTRUCT", "REVERT", "INVALID", "STOP", "RETURN",
		"SSTORE", "SLOAD", "LOG0", "LOG1", "LOG2", "LOG3", "LOG4",
	}
	
	for _, op := range important {
		if opcode == op {
			return true
		}
	}
	return false
}

func convertStats(stats disassembly.Stats) types.BytecodeStats {
	return types.BytecodeStats{
		OriginalSize:    stats.OriginalSize,
		DispatchSize:    stats.DispatchSize,
		BasicBlockCount: stats.BasicBlockCount,
		JumpdestCount:   stats.JumpdestCount,
		GasFirstBlock:   stats.GasFirstBlock,
	}
}