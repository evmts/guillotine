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

func convertStats(stats disassembly.Stats) types.BytecodeStats {
	return types.BytecodeStats{
		OriginalSize:    stats.OriginalSize,
		DispatchSize:    stats.DispatchSize,
		BasicBlockCount: stats.BasicBlockCount,
		JumpdestCount:   stats.JumpdestCount,
		GasFirstBlock:   stats.GasFirstBlock,
	}
}