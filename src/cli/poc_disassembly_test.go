package main

import (
	"testing"
	
	disassembly "github.com/evmts/guillotine/bindings/go/disassembly"
)

func TestBytecodeDisassemblyDirectAPI(t *testing.T) {
	t.Run("Simple PUSH and arithmetic operations", func(t *testing.T) {
		// Test bytecode: PUSH1 0x42, PUSH1 0x03, ADD, PUSH1 0x00, MSTORE, PUSH1 0x20, PUSH1 0x00, RETURN
		bytecode := []byte{
			0x60, 0x42, // PUSH1 0x42
			0x60, 0x03, // PUSH1 0x03  
			0x01,       // ADD
			0x60, 0x00, // PUSH1 0x00
			0x52,       // MSTORE
			0x60, 0x20, // PUSH1 0x20
			0x60, 0x00, // PUSH1 0x00
			0xf3,       // RETURN
		}

		result, err := disassembly.Analyze(bytecode)
		if err != nil {
			t.Fatalf("Disassembly failed: %v", err)
		}
		defer result.Free()

		// Verify we got the expected number of instructions
		expectedInstructions := 8 // 8 instructions in the bytecode
		if len(result.Instructions) != expectedInstructions {
			t.Errorf("Expected %d instructions, got %d", expectedInstructions, len(result.Instructions))
		}

		// Verify statistics
		if result.Stats.OriginalSize != uint32(len(bytecode)) {
			t.Errorf("Expected original_size %d, got %d", len(bytecode), result.Stats.OriginalSize)
		}

		// Verify first instruction (PUSH1 0x42)
		if result.Instructions[0].OpcodeHex != 0x60 {
			t.Errorf("Expected first opcode 0x60 (PUSH1), got 0x%02x", result.Instructions[0].OpcodeHex)
		}
		if result.Instructions[0].PushValue == nil {
			t.Errorf("Expected first instruction to have push value")
		} else if result.Instructions[0].PushValue.Low != 0x42 {
			t.Errorf("Expected first instruction push value 0x42, got 0x%x", result.Instructions[0].PushValue.Low)
		}

		// Verify instruction names
		if result.Instructions[0].OpcodeName != "PUSH1" {
			t.Errorf("Expected first instruction name 'PUSH1', got '%s'", result.Instructions[0].OpcodeName)
		}

		// Verify ADD instruction (index 2)
		if result.Instructions[2].OpcodeHex != 0x01 {
			t.Errorf("Expected ADD opcode 0x01, got 0x%02x", result.Instructions[2].OpcodeHex)
		}
		if result.Instructions[2].OpcodeName != "ADD" {
			t.Errorf("Expected ADD instruction name 'ADD', got '%s'", result.Instructions[2].OpcodeName)
		}

		// Verify RETURN instruction (last)
		lastIdx := len(result.Instructions) - 1
		if result.Instructions[lastIdx].OpcodeHex != 0xf3 {
			t.Errorf("Expected RETURN opcode 0xf3, got 0x%02x", result.Instructions[lastIdx].OpcodeHex)
		}

		t.Logf("Successfully disassembled %d instructions", len(result.Instructions))
		t.Logf("Original size: %d bytes, dispatch size: %d", result.Stats.OriginalSize, result.Stats.DispatchSize)
		t.Logf("Basic blocks: %d, jumpdests: %d", result.Stats.BasicBlockCount, result.Stats.JumpdestCount)
	})

	t.Run("Bytecode with JUMPDEST instructions", func(t *testing.T) {
		// Test bytecode with jump destinations: JUMPDEST, PUSH1 0x01, JUMPDEST, STOP
		bytecode := []byte{
			0x5b,       // JUMPDEST (pc=0)
			0x60, 0x01, // PUSH1 0x01
			0x5b,       // JUMPDEST (pc=3)
			0x00,       // STOP
		}

		result, err := disassembly.Analyze(bytecode)
		if err != nil {
			t.Fatalf("Disassembly failed: %v", err)
		}
		defer result.Free()

		// Should have 2 jumpdests
		expectedJumpdests := 2
		if len(result.Jumpdests) != expectedJumpdests {
			t.Errorf("Expected %d jumpdests, got %d", expectedJumpdests, len(result.Jumpdests))
		}

		// Verify jumpdest positions
		if len(result.Jumpdests) >= 2 {
			if result.Jumpdests[0] != 0 {
				t.Errorf("Expected first jumpdest at pc=0, got pc=%d", result.Jumpdests[0])
			}
			if result.Jumpdests[1] != 3 {
				t.Errorf("Expected second jumpdest at pc=3, got pc=%d", result.Jumpdests[1])
			}
			
			t.Logf("Found jumpdests at PC positions: %v", result.Jumpdests)
		}

		// Verify basic block information
		if len(result.BasicBlocks) == 0 {
			t.Error("Expected at least one basic block")
		} else {
			t.Logf("Found %d basic blocks", len(result.BasicBlocks))
			for i, block := range result.BasicBlocks {
				t.Logf("  Block %d: start=%d, end=%d", i, block.Start, block.End)
			}
		}
	})

	t.Run("Complex contract bytecode", func(t *testing.T) {
		// Test more complex bytecode similar to what's used in contract deployment
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

		// Verify we get the right number of instructions
		expectedInstructions := 10
		if len(result.Instructions) != expectedInstructions {
			t.Errorf("Expected %d instructions, got %d", expectedInstructions, len(result.Instructions))
		}

		// Verify storage operations
		sstoreFound := false
		sloadFound := false
		
		for _, inst := range result.Instructions {
			switch inst.OpcodeHex {
			case 0x55: // SSTORE
				if inst.OpcodeName != "SSTORE" {
					t.Errorf("Expected SSTORE name, got '%s'", inst.OpcodeName)
				}
				sstoreFound = true
				t.Logf("Found SSTORE at PC %d", inst.PC)
			case 0x54: // SLOAD
				if inst.OpcodeName != "SLOAD" {
					t.Errorf("Expected SLOAD name, got '%s'", inst.OpcodeName)  
				}
				sloadFound = true
				t.Logf("Found SLOAD at PC %d", inst.PC)
			}
		}

		if !sstoreFound {
			t.Error("Expected to find SSTORE instruction")
		}
		if !sloadFound {
			t.Error("Expected to find SLOAD instruction")
		}

		// Log comprehensive results
		t.Logf("Complex bytecode analysis:")
		t.Logf("  Instructions: %d", len(result.Instructions))
		t.Logf("  Basic blocks: %d", len(result.BasicBlocks))  
		t.Logf("  Jumpdests: %d", len(result.Jumpdests))
		t.Logf("  Original size: %d bytes", result.Stats.OriginalSize)
		t.Logf("  Gas for first block: %d", result.Stats.GasFirstBlock)
	})

	t.Run("Error handling - empty bytecode", func(t *testing.T) {
		// Test error handling with empty bytecode
		result, err := disassembly.Analyze([]byte{})
		
		if err == nil {
			result.Free() // Clean up if it unexpectedly succeeded
			t.Error("Expected failure with empty bytecode, but got success")
		} else {
			t.Logf("Properly handled error case: %v", err)
		}
	})

	t.Run("Minimal bytecode - single STOP", func(t *testing.T) {
		// Test with the simplest possible bytecode
		bytecode := []byte{0x00} // STOP
		
		result, err := disassembly.Analyze(bytecode)
		if err != nil {
			t.Fatalf("Failed to analyze minimal bytecode: %v", err)
		}
		defer result.Free()
		
		if len(result.Instructions) != 1 {
			t.Errorf("Expected 1 instruction, got %d", len(result.Instructions))
		}
		
		if result.Instructions[0].OpcodeHex != 0x00 {
			t.Errorf("Expected STOP opcode 0x00, got 0x%02x", result.Instructions[0].OpcodeHex)
		}
		
		if result.Instructions[0].OpcodeName != "STOP" {
			t.Errorf("Expected STOP name, got '%s'", result.Instructions[0].OpcodeName)
		}
	})
}