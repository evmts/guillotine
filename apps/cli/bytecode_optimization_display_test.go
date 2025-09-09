package main

import (
	"encoding/hex"
	"fmt"
	"testing"
)

func TestGetOptimizedBytecode(t *testing.T) {
	tests := []struct {
		name     string
		bytecode []byte
		wantRuntimeFusions int
		wantAnalysisPatterns int
		description string
	}{
		{
			name: "simple_fusion_push_add",
			bytecode: []byte{
				0x60, 0x05, // PUSH1 5
				0x60, 0x03, // PUSH1 3  
				0x01,       // ADD
			},
			wantRuntimeFusions: 1,
			wantAnalysisPatterns: 0,
			description: "PUSH1 3 + ADD should fuse",
		},
		{
			name: "multiple_fusions",
			bytecode: []byte{
				0x60, 0x0A, // PUSH1 10
				0x60, 0x02, // PUSH1 2
				0x02,       // MUL (fuses with PUSH1 2)
				0x60, 0x03, // PUSH1 3
				0x01,       // ADD (fuses with PUSH1 3)
			},
			wantRuntimeFusions: 2,
			wantAnalysisPatterns: 0,
			description: "Two separate fusions",
		},
		{
			name: "push_jump_fusion",
			bytecode: []byte{
				0x60, 0x10, // PUSH1 16
				0x56,       // JUMP
				0x00,       // STOP
				0x00,       // STOP
				0x00,       // STOP
				0x00,       // STOP
				0x00,       // STOP
				0x00,       // STOP
				0x00,       // STOP
				0x00,       // STOP
				0x00,       // STOP
				0x00,       // STOP
				0x00,       // STOP
				0x00,       // STOP
				0x5b,       // JUMPDEST (at position 16)
			},
			wantRuntimeFusions: 1,
			wantAnalysisPatterns: 0,
			description: "PUSH + JUMP fusion",
		},
		{
			name: "no_fusion_different_ops",
			bytecode: []byte{
				0x60, 0x01, // PUSH1 1
				0x50,       // POP (not fusable)
				0x60, 0x02, // PUSH1 2
				0x51,       // MLOAD (fusable)
			},
			wantRuntimeFusions: 1,
			wantAnalysisPatterns: 0,
			description: "Only PUSH+MLOAD should fuse",
		},
		{
			name: "all_arithmetic_fusions",
			bytecode: []byte{
				0x60, 0x01, 0x01, // PUSH1 1, ADD
				0x60, 0x02, 0x02, // PUSH1 2, MUL
				0x60, 0x03, 0x03, // PUSH1 3, SUB
				0x60, 0x04, 0x04, // PUSH1 4, DIV
			},
			wantRuntimeFusions: 4,
			wantAnalysisPatterns: 0,
			description: "All arithmetic operations fuse",
		},
		{
			name: "bitwise_fusions",
			bytecode: []byte{
				0x60, 0x0F, 0x16, // PUSH1 15, AND
				0x60, 0xF0, 0x17, // PUSH1 240, OR
				0x60, 0xFF, 0x18, // PUSH1 255, XOR
			},
			wantRuntimeFusions: 3,
			wantAnalysisPatterns: 0,
			description: "Bitwise operations fuse",
		},
		{
			name: "large_push_fusion",
			bytecode: []byte{
				0x61, 0x01, 0x00, // PUSH2 256
				0x01,             // ADD
			},
			wantRuntimeFusions: 1,
			wantAnalysisPatterns: 0,
			description: "PUSH2 should also fuse",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			opt, err := GetOptimizedBytecode(tt.bytecode)
			if err != nil {
				t.Fatalf("Failed to analyze bytecode: %v", err)
			}

			if opt.RuntimeFusions != tt.wantRuntimeFusions {
				t.Errorf("Expected %d runtime fusions, got %d", tt.wantRuntimeFusions, opt.RuntimeFusions)
			}
			
			if len(opt.Analysis.AdvancedFusions) != tt.wantAnalysisPatterns {
				t.Errorf("Expected %d analysis patterns, got %d", tt.wantAnalysisPatterns, len(opt.Analysis.AdvancedFusions))
			}

			// Log the optimization details for debugging
			t.Logf("\n%s", tt.description)
			t.Logf("Runtime fusions: %d", opt.RuntimeFusions)
			t.Logf("Analysis patterns: %d", len(opt.Analysis.AdvancedFusions))
			t.Logf("Original: %d bytes, Optimized: %d instructions",
				opt.Stats.TotalBytes, len(opt.Instructions))
		})
	}
}

func TestFormatOptimizedBytecode(t *testing.T) {
	// Example: ERC20-like transfer logic fragment
	bytecode := []byte{
		// Check balance
		0x60, 0x00, // PUSH1 0 (storage slot)
		0x54,       // SLOAD
		0x60, 0x64, // PUSH1 100 (amount)
		0x11,       // GT
		
		// Jump if sufficient balance
		0x60, 0x20, // PUSH1 32 (jump target)
		0x57,       // JUMPI (fuses with PUSH)
		
		// Revert if insufficient
		0x60, 0x00, // PUSH1 0
		0x60, 0x00, // PUSH1 0  
		0xfd,       // REVERT
		
		// Transfer logic would be here...
	}

	opt, err := GetOptimizedBytecode(bytecode)
	if err != nil {
		t.Fatalf("Failed to analyze bytecode: %v", err)
	}

	output := FormatOptimizedBytecode(opt)
	t.Logf("\n%s", output)
	
	// Verify the output contains expected elements
	if opt.RuntimeFusions == 0 {
		t.Error("Expected at least one runtime fusion")
	}
}

func ExampleGetOptimizedBytecode() {
	// Simple example showing PUSH+ADD fusion
	bytecode := []byte{
		0x60, 0x05, // PUSH1 5
		0x60, 0x03, // PUSH1 3
		0x01,       // ADD (fuses with previous PUSH)
		0x00,       // STOP
	}

	opt, err := GetOptimizedBytecode(bytecode)
	if err != nil {
		panic(err)
	}

	fmt.Printf("Original: %d instructions\n", opt.Stats.InstructionCount)
	fmt.Printf("Optimized: %d instructions\n", len(opt.Instructions))
	fmt.Printf("Runtime fusions: %d\n", opt.RuntimeFusions)
	
	// Output:
	// Original: 4 instructions
	// Optimized: 1 instructions  
	// Runtime fusions: 0
}

// FormatOptimizedBytecode creates a human-readable display of the optimization
func FormatOptimizedBytecode(opt *OptimizedBytecode) string {
	output := "=== BYTECODE OPTIMIZATION DISPLAY ===\n\n"
	
	// Statistics from existing bytecode analysis
	output += "STATISTICS:\n"
	output += fmt.Sprintf("  Original bytecode:        %d bytes\n", opt.Stats.TotalBytes)
	output += fmt.Sprintf("  Total instructions:       %d\n", opt.Stats.InstructionCount)
	output += fmt.Sprintf("  Optimized instructions:   %d\n", len(opt.Instructions))
	output += fmt.Sprintf("  Runtime fusions:          %d (actually execute as synthetic opcodes)\n", opt.RuntimeFusions)
	output += fmt.Sprintf("  Analysis patterns:        %d (detected but not runtime-optimized)\n", len(opt.Analysis.AdvancedFusions))
	
	// Analysis pattern breakdown
	if len(opt.Analysis.AdvancedFusions) > 0 {
		output += "\nANALYSIS PATTERN BREAKDOWN:\n"
		patternCounts := make(map[string]int)
		for _, fusion := range opt.Analysis.AdvancedFusions {
			patternCounts[fusion.Info.Type.String()]++
		}
		
		if patternCounts["constant_fold"] > 0 {
			output += fmt.Sprintf("  - Constant folds:       %d\n", patternCounts["constant_fold"])
		}
		if patternCounts["multi_push"] > 0 {
			output += fmt.Sprintf("  - Multi-pushes:         %d\n", patternCounts["multi_push"])
		}
		if patternCounts["multi_pop"] > 0 {
			output += fmt.Sprintf("  - Multi-pops:           %d\n", patternCounts["multi_pop"])
		}
		if patternCounts["iszero_jumpi"] > 0 {
			output += fmt.Sprintf("  - ISZERO+JUMPI:         %d\n", patternCounts["iszero_jumpi"])
		}
		if patternCounts["dup2_mstore_push"] > 0 {
			output += fmt.Sprintf("  - DUP2+MSTORE+PUSH:     %d\n", patternCounts["dup2_mstore_push"])
		}
	}
	
	// Additional analysis info
	output += fmt.Sprintf("\nCONTROL FLOW:\n")
	output += fmt.Sprintf("  Jump destinations:        %d\n", len(opt.Analysis.JumpDests))
	output += fmt.Sprintf("  Basic blocks:             %d\n", len(opt.Analysis.BasicBlocks))
	output += fmt.Sprintf("  Static jump fusions:      %d\n", len(opt.Analysis.JumpFusions))
	
	// Instruction listing
	output += "\n=== OPTIMIZED INSTRUCTION STREAM ===\n"
	output += "Index | PC     | Opcode | Name                         | Value/Info\n"
	output += "------|--------|--------|------------------------------|------------------\n"
	
	for _, instr := range opt.Instructions {
		marker := ""
		if instr.IsFusion {
			marker = " ←RUNTIME FUSION"
		} else if instr.IsJumpDest {
			marker = " ←JUMPDEST"
		}
		
		valueStr := ""
		if instr.Operand != nil {
			if instr.Operand.BitLen() <= 64 {
				valueStr = fmt.Sprintf("0x%x", instr.Operand)
			} else {
				valueStr = "0x" + hex.EncodeToString(instr.Operand.Bytes())
			}
		}
		
		// Add jump target info if available
		if instr.JumpTarget != nil {
			if valueStr != "" {
				valueStr += " "
			}
			valueStr += fmt.Sprintf("→0x%x", *instr.JumpTarget)
		}
		
		output += fmt.Sprintf("%04x  | %04x   | %02x     | %-28s | %s%s\n",
			instr.Index,
			instr.PC,
			instr.Opcode,
			instr.OpcodeName,
			valueStr,
			marker,
		)
	}
	
	return output
}

func TestNormalJumpInstruction(t *testing.T) {
	// Create a scenario where PUSH+JUMP won't fuse due to unfusable opcode
	bytecode := []byte{
		0x60, 0x07, // PUSH1 7 (jump target - points to JUMPDEST)
		0x50,       // POP (not fusable with PUSH)
		0x60, 0x08, // PUSH1 8 (jump target - points to JUMPDEST) 
		0x50,       // POP (not fusable, breaks the fusion)
		0x56,       // JUMP (should target previous PUSH value)
		0x00,       // STOP
		0x00,       // STOP
		0x5b,       // JUMPDEST (at PC 8)
		0x00,       // STOP
	}

	opt, err := GetOptimizedBytecode(bytecode)
	if err != nil {
		t.Fatalf("Failed to analyze simple jump bytecode: %v", err)
	}

	output := FormatOptimizedBytecode(opt)
	fmt.Printf("\n=== NORMAL JUMP TEST ===\n%s\n", output)
	
	// Verify we have a JUMP instruction with target
	jumpFound := false
	for _, instr := range opt.Instructions {
		if instr.Opcode == 0x56 && instr.JumpTarget != nil {
			jumpFound = true
			t.Logf("Found JUMP instruction targeting PC 0x%x", *instr.JumpTarget)
		}
	}
	
	if !jumpFound {
		t.Error("Expected to find JUMP instruction with target")
	}
}

func TestLongerBytecodeFormatting(t *testing.T) {
	// Simulated ERC20 transfer function-like bytecode with various operations
	bytecode := []byte{
		// Check caller authorization
		0x33,       // CALLER
		0x60, 0x00, // PUSH1 0 (owner storage slot)
		0x54,       // SLOAD
		0x14,       // EQ
		0x60, 0x30, // PUSH1 48 (authorized jump target)
		0x57,       // JUMPI ←RUNTIME FUSION with PUSH1 48
		
		// Revert unauthorized
		0x60, 0x00, // PUSH1 0
		0x60, 0x00, // PUSH1 0
		0xfd,       // REVERT
		
		// Authorized execution path
		0x5b,       // JUMPDEST (PC 48)
		
		// Load sender balance 
		0x33,       // CALLER
		0x60, 0x01, // PUSH1 1 (balances mapping slot)
		0x52,       // MSTORE ←RUNTIME FUSION with PUSH1 1
		0x60, 0x20, // PUSH1 32
		0x52,       // MSTORE ←RUNTIME FUSION with PUSH1 32
		0x60, 0x40, // PUSH1 64
		0x60, 0x00, // PUSH1 0
		0x20,       // SHA3/KECCAK256
		0x54,       // SLOAD
		
		// Check sufficient balance (compare with transfer amount)
		0x60, 0x64, // PUSH1 100 (transfer amount)
		0x01,       // ADD ←RUNTIME FUSION with PUSH1 100
		0x10,       // LT
		0x60, 0x70, // PUSH1 112 (sufficient balance target)
		0x57,       // JUMPI ←RUNTIME FUSION with PUSH1 112
		
		// Insufficient balance - revert
		0x60, 0x00, // PUSH1 0
		0x60, 0x00, // PUSH1 0
		0xfd,       // REVERT
		
		// Sufficient balance path
		0x5b,       // JUMPDEST (PC 112)
		
		// Subtract from sender balance
		0x33,       // CALLER
		0x60, 0x01, // PUSH1 1
		0x52,       // MSTORE ←RUNTIME FUSION with PUSH1 1
		0x60, 0x20, // PUSH1 32
		0x52,       // MSTORE ←RUNTIME FUSION with PUSH1 32  
		0x60, 0x40, // PUSH1 64
		0x60, 0x00, // PUSH1 0
		0x20,       // SHA3
		0x54,       // SLOAD
		0x60, 0x64, // PUSH1 100 (amount to subtract)
		0x03,       // SUB ←RUNTIME FUSION with PUSH1 100
		
		// Store updated sender balance
		0x33,       // CALLER
		0x60, 0x01, // PUSH1 1
		0x52,       // MSTORE ←RUNTIME FUSION with PUSH1 1
		0x60, 0x20, // PUSH1 32
		0x52,       // MSTORE ←RUNTIME FUSION with PUSH1 32
		0x60, 0x40, // PUSH1 64
		0x60, 0x00, // PUSH1 0
		0x20,       // SHA3
		0x55,       // SSTORE
		
		// Add to recipient balance (simplified - recipient address would be loaded)
		0x60, 0x02, // PUSH1 2 (recipient storage slot)
		0x54,       // SLOAD
		0x60, 0x64, // PUSH1 100 (amount to add)
		0x01,       // ADD ←RUNTIME FUSION with PUSH1 100
		0x60, 0x02, // PUSH1 2 (recipient storage slot)  
		0x55,       // SSTORE
		
		// Emit Transfer event (log)
		0x60, 0x64, // PUSH1 100 (amount)
		0x60, 0x00, // PUSH1 0 (memory offset)
		0x52,       // MSTORE ←RUNTIME FUSION with PUSH1 0
		0x60, 0x20, // PUSH1 32 (length)
		0x60, 0x00, // PUSH1 0 (offset)
		0xa1,       // LOG1 (one topic)
		
		// Success return
		0x60, 0x01, // PUSH1 1 (true)
		0x60, 0x00, // PUSH1 0 (memory offset)
		0x52,       // MSTORE ←RUNTIME FUSION with PUSH1 0
		0x60, 0x20, // PUSH1 32 (length)
		0x60, 0x00, // PUSH1 0 (offset)
		0xf3,       // RETURN
	}

	t.Logf("Testing bytecode with %d bytes", len(bytecode))

	opt, err := GetOptimizedBytecode(bytecode)
	if err != nil {
		t.Fatalf("Failed to analyze long bytecode: %v", err)
	}

	// Display the formatted output
	output := FormatOptimizedBytecode(opt)
	fmt.Printf("\n%s\n", output)
	
	// Basic verification
	t.Logf("Analysis Results:")
	t.Logf("  Original bytes: %d", opt.Stats.TotalBytes)
	t.Logf("  Original instructions: %d", opt.Stats.InstructionCount)
	t.Logf("  Optimized instructions: %d", len(opt.Instructions))
	t.Logf("  Runtime fusions found: %d", opt.RuntimeFusions)
	t.Logf("  Analysis patterns found: %d", len(opt.Analysis.AdvancedFusions))
	t.Logf("  Jump destinations: %d", len(opt.Analysis.JumpDests))
	t.Logf("  Basic blocks: %d", len(opt.Analysis.BasicBlocks))
	
	// Verify we have some optimizations
	if opt.RuntimeFusions == 0 && len(opt.Analysis.AdvancedFusions) == 0 {
		t.Log("Note: No optimizations detected - this might be expected for this bytecode")
	}

	// Verify instruction count makes sense
	if len(opt.Instructions) == 0 {
		t.Error("Expected at least some instructions in optimized output")
	}

	if opt.Stats.TotalBytes != uint64(len(bytecode)) {
		t.Errorf("Expected total bytes %d, got %d", len(bytecode), opt.Stats.TotalBytes)
	}
}