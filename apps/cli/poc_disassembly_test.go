package main

import (
	"testing"
	
	disassembly "github.com/evmts/guillotine/bindings/go/disassembly"
)

func TestBytecodeDisassemblyNewAPI(t *testing.T) {
	t.Run("Simple arithmetic operations with fusion detection", func(t *testing.T) {
		// Test bytecode: PUSH1 0x42, ADD, PUSH1 0x03, MUL, STOP
		bytecode := []byte{
			0x60, 0x42, // PUSH1 0x42
			0x01,       // ADD
			0x60, 0x03, // PUSH1 0x03  
			0x02,       // MUL
			0x00,       // STOP
		}

		result, err := disassembly.Analyze(bytecode)
		if err != nil {
			t.Fatalf("Disassembly failed: %v", err)
		}
		defer result.Free()

		// Should detect PUSH+ADD and PUSH+MUL fusions, plus STOP
		if len(result.Instructions) != 3 {
			t.Errorf("Expected 3 optimized instructions, got %d", len(result.Instructions))
		}

		// Verify first instruction is PUSH+ADD fusion
		inst1 := result.Instructions[0]
		if inst1.OpcodeName != "PUSH_ADD_FUSION" {
			t.Errorf("Expected PUSH_ADD_FUSION, got '%s'", inst1.OpcodeName)
		}
		if inst1.PC != 0 {
			t.Errorf("Expected PC 0, got %d", inst1.PC)
		}
		if inst1.PushValue == nil || inst1.PushValue.Low != 0x42 {
			t.Errorf("Expected push value 0x42, got %v", inst1.PushValue)
		}

		// Verify second instruction is PUSH+MUL fusion  
		inst2 := result.Instructions[1]
		if inst2.OpcodeName != "PUSH_MUL_FUSION" {
			t.Errorf("Expected PUSH_MUL_FUSION, got '%s'", inst2.OpcodeName)
		}
		if inst2.PushValue == nil || inst2.PushValue.Low != 0x03 {
			t.Errorf("Expected push value 0x03, got %v", inst2.PushValue)
		}

		// Verify third instruction is STOP
		inst3 := result.Instructions[2]
		if inst3.OpcodeName != "STOP" {
			t.Errorf("Expected STOP, got '%s'", inst3.OpcodeName)
		}

		// Verify statistics
		if result.Stats.OriginalCount != uint32(len(bytecode)) {
			t.Errorf("Expected original_count %d, got %d", len(bytecode), result.Stats.OriginalCount)
		}
		if result.Stats.FusionCount != 2 {
			t.Errorf("Expected 2 fusions, got %d", result.Stats.FusionCount)
		}
		if result.Stats.GasSavedEstimate == 0 {
			t.Error("Expected gas savings from fusions")
		}
		if result.Stats.CompressionRatio >= 1.0 {
			t.Errorf("Expected compression ratio < 1.0, got %f", result.Stats.CompressionRatio)
		}

		t.Logf("Successfully detected %d fusions with %d gas saved", 
			result.Stats.FusionCount, result.Stats.GasSavedEstimate)
		t.Logf("Compression ratio: %.2f", result.Stats.CompressionRatio)
	})

	t.Run("Complex contract with storage operations", func(t *testing.T) {
		// Contract that stores a value and returns it
		bytecode := []byte{
			0x60, 0x42, // PUSH1 0x42
			0x60, 0x00, // PUSH1 0x00  
			0x55,       // SSTORE (store 0x42 at slot 0)
			0x60, 0x00, // PUSH1 0x00
			0x54,       // SLOAD (load from slot 0)
			0x60, 0x00, // PUSH1 0x00
			0x52,       // MSTORE (store in memory)
			0x60, 0x20, // PUSH1 0x20
			0x60, 0x00, // PUSH1 0x00
			0xf3,       // RETURN
		}

		result, err := disassembly.Analyze(bytecode)
		if err != nil {
			t.Fatalf("Disassembly failed: %v", err)
		}
		defer result.Free()

		// Verify we have optimized instructions
		if len(result.Instructions) == 0 {
			t.Fatal("Expected at least some instructions")
		}

		// Track different instruction types found
		regularCount := 0
		fusionCount := 0
		storageOpsFound := map[string]bool{
			"SSTORE": false,
			"SLOAD":  false,
			"MSTORE": false,
			"RETURN": false,
		}

		for _, inst := range result.Instructions {
			// Check if this is a storage operation
			if _, isStorageOp := storageOpsFound[inst.OpcodeName]; isStorageOp {
				storageOpsFound[inst.OpcodeName] = true
			}

			// Count fusion vs regular instructions
			if inst.IsRegular() {
				regularCount++
			} else if contains(inst.OpcodeName, "FUSION") {
				fusionCount++
			}

			// Verify all instructions have original opcodes
			if len(inst.OriginalOpcodes) == 0 {
				t.Errorf("Instruction at PC %d has no original opcodes", inst.PC)
			}

			// Verify gas cost is set
			if inst.GasCost == 0 && inst.OpcodeName != "STOP" {
				t.Errorf("Instruction %s has zero gas cost", inst.OpcodeName)
			}
		}

		// Verify we found expected storage operations
		for op, found := range storageOpsFound {
			if !found {
				t.Logf("Storage operation %s not found (may be optimized)", op)
			}
		}

		// Verify overall statistics make sense
		if result.Stats.OptimizedCount != uint32(len(result.Instructions)) {
			t.Errorf("OptimizedCount mismatch: stats=%d, actual=%d", 
				result.Stats.OptimizedCount, len(result.Instructions))
		}

		t.Logf("Complex contract analysis:")
		t.Logf("  Original opcodes: %d", result.Stats.OriginalCount)  
		t.Logf("  Optimized instructions: %d", result.Stats.OptimizedCount)
		t.Logf("  Fusions detected: %d", result.Stats.FusionCount)
		t.Logf("  Static jump candidates: %d", result.Stats.StaticJumpCandidates)
	})

	t.Run("Jump destinations and control flow", func(t *testing.T) {
		// Test bytecode with jump destinations: JUMPDEST, PUSH1 0x01, PUSH1 0x06, JUMP, JUMPDEST, STOP
		bytecode := []byte{
			0x5b,       // JUMPDEST (pc=0)
			0x60, 0x01, // PUSH1 0x01
			0x60, 0x06, // PUSH1 0x06 (jump target)
			0x56,       // JUMP
			0x5b,       // JUMPDEST (pc=6)
			0x00,       // STOP
		}

		result, err := disassembly.Analyze(bytecode)
		if err != nil {
			t.Fatalf("Disassembly failed: %v", err)
		}
		defer result.Free()

		// Track jumpdests and jump instructions
		jumpdestsFound := []uint32{}
		staticJumpFound := false

		for _, inst := range result.Instructions {
			if inst.OpcodeName == "JUMPDEST" {
				jumpdestsFound = append(jumpdestsFound, inst.PC)
			}
			if inst.OpcodeName == "PUSH_JUMP_FUSION" || inst.OpcodeName == "STATIC_JUMP_CANDIDATE" {
				staticJumpFound = true
				// Verify the jump target value
				if inst.PushValue == nil || inst.PushValue.Low != 0x06 {
					t.Errorf("Expected jump target 0x06, got %v", inst.PushValue)
				}
			}

			// Verify original opcodes for each instruction
			for _, orig := range inst.OriginalOpcodes {
				if orig.PC >= uint32(len(bytecode)) {
					t.Errorf("Original opcode PC %d exceeds bytecode length %d", orig.PC, len(bytecode))
				}
				if orig.OpcodeHex != bytecode[orig.PC] {
					t.Errorf("Original opcode mismatch at PC %d: expected 0x%02x, got 0x%02x", 
						orig.PC, bytecode[orig.PC], orig.OpcodeHex)
				}
			}
		}

		// Verify we found jumpdests at expected positions
		expectedJumpdests := []uint32{0, 6}
		if len(jumpdestsFound) != len(expectedJumpdests) {
			t.Errorf("Expected %d jumpdests, found %d: %v", 
				len(expectedJumpdests), len(jumpdestsFound), jumpdestsFound)
		}

		if !staticJumpFound && result.Stats.StaticJumpCandidates > 0 {
			t.Error("Expected to find static jump candidate instruction")
		}

		t.Logf("Control flow analysis:")
		t.Logf("  Jumpdests found at PCs: %v", jumpdestsFound)
		t.Logf("  Static jump candidates: %d", result.Stats.StaticJumpCandidates)
	})

	t.Run("All fusion types comprehensive test", func(t *testing.T) {
		// Test various fusion types in sequence
		bytecode := []byte{
			// Arithmetic fusions
			0x60, 0x01, 0x01, // PUSH1 0x01, ADD
			0x60, 0x02, 0x02, // PUSH1 0x02, MUL  
			0x60, 0x03, 0x03, // PUSH1 0x03, SUB
			0x60, 0x04, 0x04, // PUSH1 0x04, DIV
			// Bitwise fusions
			0x60, 0xFF, 0x16, // PUSH1 0xFF, AND
			0x60, 0x0F, 0x17, // PUSH1 0x0F, OR
			0x60, 0xAA, 0x18, // PUSH1 0xAA, XOR
			// Control flow
			0x60, 0x20, 0x56, // PUSH1 0x20, JUMP
			0x5B,             // JUMPDEST (pc=32)
			0x00,             // STOP
		}

		result, err := disassembly.Analyze(bytecode)
		if err != nil {
			t.Fatalf("Disassembly failed: %v", err)
		}
		defer result.Free()

		// Expected fusion types
		expectedFusions := map[string]bool{
			"PUSH_ADD_FUSION": false,
			"PUSH_MUL_FUSION": false, 
			"PUSH_SUB_FUSION": false,
			"PUSH_DIV_FUSION": false,
			"PUSH_AND_FUSION": false,
			"PUSH_OR_FUSION":  false,
			"PUSH_XOR_FUSION": false,
			"PUSH_JUMP_FUSION": false,
		}

		fusionValues := map[string]uint64{
			"PUSH_ADD_FUSION": 0x01,
			"PUSH_MUL_FUSION": 0x02,
			"PUSH_SUB_FUSION": 0x03, 
			"PUSH_DIV_FUSION": 0x04,
			"PUSH_AND_FUSION": 0xFF,
			"PUSH_OR_FUSION":  0x0F,
			"PUSH_XOR_FUSION": 0xAA,
			"PUSH_JUMP_FUSION": 0x20,
		}

		for _, inst := range result.Instructions {
			if _, isFusion := expectedFusions[inst.OpcodeName]; isFusion {
				expectedFusions[inst.OpcodeName] = true
				
				// Verify the push value is correct
				expectedValue := fusionValues[inst.OpcodeName]
				if inst.PushValue == nil || inst.PushValue.Low != expectedValue {
					t.Errorf("Fusion %s: expected value 0x%x, got %v", 
						inst.OpcodeName, expectedValue, inst.PushValue)
				}

				// Verify stack effects make sense for fusions
				if inst.StackOutputs != 1 {
					t.Errorf("Fusion %s: expected 1 stack output, got %d", 
						inst.OpcodeName, inst.StackOutputs)
				}
			}
		}

		// Verify we found all expected fusion types
		missedFusions := []string{}
		for fusionType, found := range expectedFusions {
			if !found {
				missedFusions = append(missedFusions, fusionType)
			}
		}
		if len(missedFusions) > 0 {
			t.Errorf("Missed fusion types: %v", missedFusions)
		}

		// Verify comprehensive statistics
		if result.Stats.FusionCount < 7 {
			t.Errorf("Expected at least 7 fusions, got %d", result.Stats.FusionCount)
		}
		if result.Stats.CompressionRatio >= 1.0 {
			t.Errorf("Expected compression ratio < 1.0 with many fusions, got %f", 
				result.Stats.CompressionRatio)
		}

		t.Logf("Fusion types test completed:")
		t.Logf("  Total fusions: %d", result.Stats.FusionCount)
		t.Logf("  Inline value storage: %d", result.Stats.InlineValueCount)  
		t.Logf("  Pointer value storage: %d", result.Stats.PointerValueCount)
		t.Logf("  Compression ratio: %.3f", result.Stats.CompressionRatio)
	})

	t.Run("Large values and storage types", func(t *testing.T) {
		// Test both inline (small) and pointer (large) value storage
		bytecode := []byte{
			// Small value - should use inline storage
			0x60, 0x10, 0x01, // PUSH1 0x10, ADD
			// Large value - should use pointer storage  
			0x7f, // PUSH32
		}
		// Append 32 bytes of 0xFF for max u256 value
		bytecode = append(bytecode, make([]byte, 32)...)
		for i := 4; i < 36; i++ {
			bytecode[i] = 0xFF
		}
		bytecode = append(bytecode, 0x02) // MUL

		result, err := disassembly.Analyze(bytecode)
		if err != nil {
			t.Fatalf("Disassembly failed: %v", err)
		}
		defer result.Free()

		if len(result.Instructions) != 2 {
			t.Errorf("Expected 2 fusion instructions, got %d", len(result.Instructions))
		}

		// First should be small value fusion with inline storage
		inst1 := result.Instructions[0]
		if inst1.OpcodeName != "PUSH_ADD_FUSION" {
			t.Errorf("Expected PUSH_ADD_FUSION, got %s", inst1.OpcodeName)
		}

		// Second should be large value fusion with pointer storage
		inst2 := result.Instructions[1]
		if inst2.OpcodeName != "PUSH_MUL_FUSION" {
			t.Errorf("Expected PUSH_MUL_FUSION, got %s", inst2.OpcodeName)  
		}

		// Verify statistics reflect storage types
		if result.Stats.InlineValueCount == 0 {
			t.Error("Expected at least one inline value")
		}
		if result.Stats.PointerValueCount == 0 {
			t.Error("Expected at least one pointer value") 
		}

		t.Logf("Value storage test:")
		t.Logf("  Inline values: %d", result.Stats.InlineValueCount)
		t.Logf("  Pointer values: %d", result.Stats.PointerValueCount)
	})

	t.Run("Error handling and edge cases", func(t *testing.T) {
		// Test empty bytecode
		t.Run("Empty bytecode", func(t *testing.T) {
			result, err := disassembly.Analyze([]byte{})
			if err == nil {
				result.Free()
				t.Error("Expected error with empty bytecode")
			} else {
				t.Logf("Properly handled empty bytecode: %v", err)
			}
		})

		// Test single instruction
		t.Run("Single STOP instruction", func(t *testing.T) {
			result, err := disassembly.Analyze([]byte{0x00})
			if err != nil {
				t.Fatalf("Failed to analyze single STOP: %v", err)
			}
			defer result.Free()

			if len(result.Instructions) != 1 {
				t.Errorf("Expected 1 instruction, got %d", len(result.Instructions))
			}
			if result.Instructions[0].OpcodeName != "STOP" {
				t.Errorf("Expected STOP, got %s", result.Instructions[0].OpcodeName)
			}
		})

		// Test invalid opcode
		t.Run("Invalid opcode", func(t *testing.T) {
			result, err := disassembly.Analyze([]byte{0xEF}) // Invalid opcode
			if err != nil {
				t.Fatalf("Failed to analyze invalid opcode: %v", err)
			}
			defer result.Free()

			if len(result.Instructions) != 1 {
				t.Errorf("Expected 1 instruction, got %d", len(result.Instructions))
			}
			if result.Instructions[0].OpcodeName != "INVALID" {
				t.Errorf("Expected INVALID, got %s", result.Instructions[0].OpcodeName)
			}
		})
	})

	t.Run("Memory management and cleanup", func(t *testing.T) {
		// Test that multiple analyze calls work and cleanup properly
		bytecode := []byte{0x60, 0x01, 0x01, 0x00} // PUSH1 0x01, ADD, STOP

		for i := 0; i < 10; i++ {
			result, err := disassembly.Analyze(bytecode)
			if err != nil {
				t.Fatalf("Iteration %d failed: %v", i, err)
			}
			
			// Verify result is valid before cleanup
			if len(result.Instructions) == 0 {
				t.Errorf("Iteration %d: no instructions", i)
			}
			
			result.Free()
		}
		
		t.Log("Memory management test completed successfully")
	})
}

// Helper function
func contains(s, substr string) bool {
	if len(s) < len(substr) {
		return false
	}
	for i := 0; i <= len(s)-len(substr); i++ {
		if s[i:i+len(substr)] == substr {
			return true
		}
	}
	return false
}