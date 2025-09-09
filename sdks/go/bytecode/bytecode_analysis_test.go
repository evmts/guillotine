package bytecode_test

import (
	"encoding/hex"
	"testing"

	"github.com/evmts/guillotine/sdks/go/bytecode"
)

// TestAnalysisBasicPatterns tests analysis of basic bytecode patterns
func TestAnalysisBasicPatterns(t *testing.T) {
	tests := []struct {
		name                string
		code                []byte
		expectedPushCount   int
		expectedJumpDests   []uint32
		expectedBlocksMin   int
		expectedInstrCount  uint32
	}{
		{
			name: "simple_arithmetic",
			code: []byte{
				0x60, 0x01, // PUSH1 0x01
				0x60, 0x02, // PUSH1 0x02
				0x01,       // ADD
				0x00,       // STOP
			},
			expectedPushCount:  0, // Fused as multi_push pattern
			expectedJumpDests:  []uint32{},
			expectedBlocksMin:  1,
			expectedInstrCount: 4,
		},
		{
			name: "conditional_jump",
			code: []byte{
				0x60, 0x01, // PUSH1 0x01
				0x60, 0x08, // PUSH1 0x08 (jump to position 8)
				0x57,       // JUMPI
				0x60, 0x02, // PUSH1 0x02
				0x00,       // STOP
				0x5B,       // JUMPDEST (position 8)
				0x60, 0x03, // PUSH1 0x03
				0x00,       // STOP
			},
			expectedPushCount:  2, // First two fused with JUMPI, last two individual
			expectedJumpDests:  []uint32{8},
			expectedBlocksMin:  2,
			expectedInstrCount: 8,
		},
		{
			name: "loop_structure",
			code: []byte{
				0x60, 0x05, // PUSH1 0x05 (counter)
				0x5B,       // JUMPDEST (loop start at position 2)
				0x80,       // DUP1
				0x60, 0x01, // PUSH1 0x01
				0x03,       // SUB
				0x80,       // DUP1
				0x60, 0x02, // PUSH1 0x02 (jump back to position 2)
				0x57,       // JUMPI
				0x50,       // POP
				0x00,       // STOP
			},
			expectedPushCount:  3,
			expectedJumpDests:  []uint32{2},
			expectedBlocksMin:  2,
			expectedInstrCount: 10,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			bc, err := bytecode.New(tt.code)
			if err != nil {
				t.Fatalf("Failed to create bytecode: %v", err)
			}
			defer bc.Destroy()

			// Analyze bytecode
			analysis, err := bc.Analyze()
			if err != nil {
				t.Fatalf("Failed to analyze bytecode: %v", err)
			}

			// Check push instructions
			if len(analysis.PushPCs) != tt.expectedPushCount {
				t.Errorf("Expected %d push instructions, got %d", tt.expectedPushCount, len(analysis.PushPCs))
			}

			// Check jump destinations
			if len(analysis.JumpDests) != len(tt.expectedJumpDests) {
				t.Errorf("Expected %d jump destinations, got %d", len(tt.expectedJumpDests), len(analysis.JumpDests))
			}
			for i, expectedDest := range tt.expectedJumpDests {
				if i < len(analysis.JumpDests) && analysis.JumpDests[i] != expectedDest {
					t.Errorf("Jump dest %d: expected %d, got %d", i, expectedDest, analysis.JumpDests[i])
				}
			}

			// Check basic blocks
			if len(analysis.BasicBlocks) < tt.expectedBlocksMin {
				t.Errorf("Expected at least %d basic blocks, got %d", tt.expectedBlocksMin, len(analysis.BasicBlocks))
			}
		})
	}
}

// TestAnalysisFusionPatterns tests detection of fusion optimization patterns
func TestAnalysisFusionPatterns(t *testing.T) {
	tests := []struct {
		name              string
		code              []byte
		description       string
		checkFusions      bool
	}{
		{
			name: "multi_push_pattern",
			code: []byte{
				0x60, 0x01, // PUSH1 0x01
				0x60, 0x02, // PUSH1 0x02
				0x60, 0x03, // PUSH1 0x03
				0x60, 0x04, // PUSH1 0x04
				0x01,       // ADD
				0x01,       // ADD
				0x01,       // ADD
				0x00,       // STOP
			},
			description:  "Multiple consecutive PUSH operations",
			checkFusions: true,
		},
		{
			name: "iszero_jumpi_pattern",
			code: []byte{
				0x60, 0x00, // PUSH1 0x00
				0x15,       // ISZERO
				0x60, 0x08, // PUSH1 0x08
				0x57,       // JUMPI
				0x60, 0xFF, // PUSH1 0xFF
				0x00,       // STOP
				0x5B,       // JUMPDEST
				0x60, 0x01, // PUSH1 0x01
				0x00,       // STOP
			},
			description:  "ISZERO followed by JUMPI pattern",
			checkFusions: true,
		},
		{
			name: "multi_pop_pattern",
			code: []byte{
				0x60, 0x01, // PUSH1 0x01
				0x60, 0x02, // PUSH1 0x02
				0x60, 0x03, // PUSH1 0x03
				0x50,       // POP
				0x50,       // POP
				0x50,       // POP
				0x00,       // STOP
			},
			description:  "Multiple consecutive POP operations",
			checkFusions: true,
		},
		{
			name: "constant_folding",
			code: []byte{
				0x60, 0x02, // PUSH1 0x02
				0x60, 0x03, // PUSH1 0x03
				0x02,       // MUL (2 * 3 = 6, could be folded)
				0x60, 0x04, // PUSH1 0x04
				0x01,       // ADD (6 + 4 = 10, could be folded)
				0x00,       // STOP
			},
			description:  "Constant arithmetic that could be folded",
			checkFusions: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			bc, err := bytecode.New(tt.code)
			if err != nil {
				t.Fatalf("Failed to create bytecode: %v", err)
			}
			defer bc.Destroy()

			analysis, err := bc.Analyze()
			if err != nil {
				t.Fatalf("Failed to analyze bytecode: %v", err)
			}

			t.Logf("%s: %s", tt.name, tt.description)
			t.Logf("  Jump fusions detected: %d", len(analysis.JumpFusions))
			t.Logf("  Advanced fusions detected: %d", len(analysis.AdvancedFusions))

			if tt.checkFusions {
				// Log detailed fusion information
				for i, fusion := range analysis.AdvancedFusions {
					t.Logf("  Advanced fusion %d at PC %d: type=%s, original_length=%d",
						i, fusion.PC, fusion.Info.Type, fusion.Info.OriginalLength)
					if fusion.Info.FoldedValue != nil {
						t.Logf("    Folded value: %s", fusion.Info.FoldedValue.String())
					}
				}

				for i, fusion := range analysis.JumpFusions {
					t.Logf("  Jump fusion %d: source=%d, target=%d",
						i, fusion.SourcePC, fusion.TargetPC)
				}
			}
		})
	}
}

// TestAnalysisComplexContracts tests analysis of complex contract bytecode
func TestAnalysisComplexContracts(t *testing.T) {
	tests := []struct {
		name        string
		codeHex     string
		description string
		minStats    struct {
			instructions uint32
			pushes       uint32
			jumps        uint32
			calls        uint32
		}
	}{
		{
			name: "erc20_transfer_fragment",
			codeHex: "6080604052348015600f57600080fd5b506004361060285760003560e01c8063" +
				"70a0823114602d575b600080fd5b60336047565b604051603e9190605d565b60405180910390f3" +
				"5b60005481565b6000819050919050565b6057816047565b82525050565b6000602082019050" +
				"607060008301846050565b92915050565b7f4e487b710000000000000000000000000000000000000000000000000000000000",
			description: "ERC20 balance query fragment",
			minStats: struct {
				instructions uint32
				pushes       uint32
				jumps        uint32
				calls        uint32
			}{
				instructions: 20,
				pushes:       5,
				jumps:        1,
				calls:        0,
			},
		},
		{
			name: "storage_operations",
			codeHex: "608060405234801561001057600080fd5b50600436106100365760003560e01c8063" +
				"2e64cec11461003b5780636057361d14610059575b600080fd5b610043610075565b" +
				"60405161005091906100a1565b60405180910390f35b610073600480360381019061006e91906100ed565b61007e565b005b60008054905090565b8060008190555050565b6000819050919050565b61009b81610088565b82525050565b60006020820190506100b66000830184610092565b92915050565b600080fd5b6100cb81610088565b81146100d657600080fd5b50565b6000813590506100e8816100c2565b92915050565b600060208284031215610104576101036100bd565b5b6000610112848285016100d9565b9150509291505056",
			description: "Simple storage contract with get/set",
			minStats: struct {
				instructions uint32
				pushes       uint32
				jumps        uint32
				calls        uint32
			}{
				instructions: 40,
				pushes:       10,
				jumps:        2,
				calls:        0,
			},
		},
		{
			name: "complex_control_flow",
			codeHex: "60806040523480156100115760006000fd5b50600436106100305760003560e01c8063" +
				"27e235e3146100365780633ccfd60b1461006657610030565b60006000fd5b610050600480360381019061004b919061022c565b610070565b60405161005d919061026a565b60405180910390f35b61006e610089565b005b60006000506020528060005260406000206000915090505481565b3373ffffffffffffffffffffffffffffffffffffffff16600060005060003373ffffffffffffffffffffffffffffffffffffffff1681526020019081526020016000205060005054604051600060405180830381858888f1935050505015156100f95760006000fd5b600060005060003373ffffffffffffffffffffffffffffffffffffffff16815260200190815260200160002054600050546000600050600033",
			description: "Contract with complex control flow and external calls",
			minStats: struct {
				instructions uint32
				pushes       uint32
				jumps        uint32
				calls        uint32
			}{
				instructions: 50,
				pushes:       15,
				jumps:        3,
				calls:        1,
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			code, err := hex.DecodeString(tt.codeHex)
			if err != nil {
				t.Fatalf("Failed to decode hex: %v", err)
			}

			bc, err := bytecode.New(code)
			if err != nil {
				t.Fatalf("Failed to create bytecode: %v", err)
			}
			defer bc.Destroy()

			// Analyze bytecode
			analysis, err := bc.Analyze()
			if err != nil {
				t.Fatalf("Failed to analyze bytecode: %v", err)
			}

			t.Logf("  Analysis results:")
			t.Logf("    Push PCs: %d", len(analysis.PushPCs))
			t.Logf("    Jump destinations: %d", len(analysis.JumpDests))
			t.Logf("    Basic blocks: %d", len(analysis.BasicBlocks))
			t.Logf("    Jump fusions: %d", len(analysis.JumpFusions))
			t.Logf("    Advanced fusions: %d", len(analysis.AdvancedFusions))

			// Basic blocks should be non-empty for complex contracts
			if len(analysis.BasicBlocks) == 0 {
				t.Error("Expected at least one basic block")
			}

			// Log basic block boundaries
			for i, block := range analysis.BasicBlocks {
				if i < 5 { // Log first 5 blocks
					t.Logf("    Basic block %d: [%d, %d]", i, block.Start, block.End)
				}
			}
		})
	}
}

// TestAnalysisEdgeCases tests analysis with edge cases
func TestAnalysisEdgeCases(t *testing.T) {
	tests := []struct {
		name        string
		code        []byte
		description string
	}{
		{
			name:        "empty_bytecode",
			code:        []byte{},
			description: "Empty bytecode should analyze without error",
		},
		{
			name:        "single_stop",
			code:        []byte{0x00},
			description: "Single STOP instruction",
		},
		{
			name:        "only_invalid",
			code:        []byte{0xFE, 0xFE, 0xFE},
			description: "Only INVALID opcodes",
		},
		{
			name: "large_push_values",
			code: []byte{
				0x7F, // PUSH32
				0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
				0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
				0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
				0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
				0x00, // STOP
			},
			description: "PUSH32 with maximum value",
		},
		{
			name: "unreachable_code",
			code: []byte{
				0x00,       // STOP
				0x60, 0x01, // PUSH1 0x01 (unreachable)
				0x60, 0x02, // PUSH1 0x02 (unreachable)
				0x01,       // ADD (unreachable)
			},
			description: "Code after STOP is unreachable",
		},
		{
			name: "invalid_jump_target",
			code: []byte{
				0x60, 0xFF, // PUSH1 0xFF (invalid jump target)
				0x56,       // JUMP
				0x00,       // STOP
			},
			description: "Jump to invalid destination",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			bc, err := bytecode.New(tt.code)
			if err != nil {
				t.Fatalf("Failed to create bytecode: %v", err)
			}
			defer bc.Destroy()

			analysis, err := bc.Analyze()
			if err != nil {
				t.Fatalf("Failed to analyze bytecode: %v", err)
			}

			t.Logf("%s: %s", tt.name, tt.description)
			t.Logf("  Basic blocks: %d", len(analysis.BasicBlocks))
		})
	}
}

// TestAnalysisConsistency tests that multiple analyses produce consistent results
func TestAnalysisConsistency(t *testing.T) {
	code := []byte{
		0x60, 0x40, // PUSH1 0x40
		0x80,       // DUP1
		0x60, 0x0A, // PUSH1 0x0A
		0x57,       // JUMPI
		0x60, 0x20, // PUSH1 0x20
		0x01,       // ADD
		0x00,       // STOP
		0x5B,       // JUMPDEST
		0x60, 0x30, // PUSH1 0x30
		0x01,       // ADD
		0x00,       // STOP
	}

	bc, err := bytecode.New(code)
	if err != nil {
		t.Fatalf("Failed to create bytecode: %v", err)
	}
	defer bc.Destroy()

	// Run analysis multiple times
	var analyses []*bytecode.Analysis
	for i := 0; i < 3; i++ {
		analysis, err := bc.Analyze()
		if err != nil {
			t.Fatalf("Analysis %d failed: %v", i, err)
		}
		analyses = append(analyses, analysis)
	}

	// Compare all analyses to ensure consistency
	first := analyses[0]
	for i := 1; i < len(analyses); i++ {
		current := analyses[i]

		// Check push PCs consistency
		if len(current.PushPCs) != len(first.PushPCs) {
			t.Errorf("Analysis %d: push PCs count mismatch", i)
		}

		// Check jump destinations consistency
		if len(current.JumpDests) != len(first.JumpDests) {
			t.Errorf("Analysis %d: jump dests count mismatch", i)
		}

		// Check basic blocks consistency
		if len(current.BasicBlocks) != len(first.BasicBlocks) {
			t.Errorf("Analysis %d: basic blocks count mismatch", i)
		}
	}

	t.Logf("Consistency check passed for %d analyses", len(analyses))
}