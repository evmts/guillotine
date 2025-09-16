package bytecode

import (
	"encoding/json"
	"testing"

	"github.com/evmts/guillotine/sdks/go/bytecode"
)

func TestAnalyzeBytecode_SimpleContract(t *testing.T) {
	// Simple ERC20-like bytecode: constructor + basic storage operations
	// PUSH1 0x80, PUSH1 0x40, MSTORE (setup free memory pointer)
	// PUSH2 0x03e8, PUSH1 0x00, SSTORE (store 1000 at slot 0 - total supply) 
	// PUSH1 0x05, JUMPDEST, PUSH1 0x01, ADD, DUP1, PUSH1 0x0a, LT, PUSH1 0x05, JUMPI (simple loop)
	// STOP
	code := []byte{
		0x60, 0x80, // PUSH1 0x80
		0x60, 0x40, // PUSH1 0x40  
		0x52,       // MSTORE
		0x61, 0x03, 0xe8, // PUSH2 0x03e8 (1000)
		0x60, 0x00, // PUSH1 0x00
		0x55,       // SSTORE
		0x60, 0x05, // PUSH1 0x05 (loop start address)
		0x5b,       // JUMPDEST (PC 11)
		0x60, 0x01, // PUSH1 0x01
		0x01,       // ADD
		0x80,       // DUP1
		0x60, 0x0a, // PUSH1 0x0a (10)
		0x10,       // LT
		0x60, 0x05, // PUSH1 0x05 (jump back to loop)
		0x57,       // JUMPI  
		0x00,       // STOP
	}

	bc, err := bytecode.New(code)
	if err != nil {
		t.Fatalf("Failed to create bytecode: %v", err)
	}
	defer bc.Destroy()

	result, err := AnalyzeBytecode(bc)
	if err != nil {
		t.Fatalf("Failed to pretty print: %v", err)
	}

	// Basic validation
	if result.Length != uint64(len(code)) {
		t.Errorf("Expected length %d, got %d", len(code), result.Length)
	}

	if len(result.Instructions) == 0 {
		t.Fatal("No instructions found")
	}

	// Check that we have the expected number of instructions (not bytes)
	expectedInstructions := []struct {
		pc     uint64
		opcode string
		size   int
	}{
		{0, "PUSH1", 2},   // PUSH1 0x80
		{2, "PUSH1", 2},   // PUSH1 0x40
		{4, "MSTORE", 1},  // MSTORE
		{5, "PUSH2", 3},   // PUSH2 0x03e8
		{8, "PUSH1", 2},   // PUSH1 0x00
		{10, "SSTORE", 1}, // SSTORE
		{11, "PUSH1", 2},  // PUSH1 0x05
		{13, "JUMPDEST", 1}, // JUMPDEST
		{14, "PUSH1", 2},  // PUSH1 0x01
		{16, "ADD", 1},    // ADD
		{17, "DUP1", 1},   // DUP1
		{18, "PUSH1", 2},  // PUSH1 0x0a
		{20, "LT", 1},     // LT
		{21, "PUSH1", 2},  // PUSH1 0x05
		{23, "JUMPI", 1},  // JUMPI
		{24, "STOP", 1},   // STOP
	}

	if len(result.Instructions) != len(expectedInstructions) {
		t.Errorf("Expected %d instructions, got %d", len(expectedInstructions), len(result.Instructions))
	}

	// Verify each instruction
	for i, expected := range expectedInstructions {
		if i >= len(result.Instructions) {
			t.Errorf("Missing instruction at index %d", i)
			continue
		}

		instr := result.Instructions[i]
		
		if instr.PC != expected.pc {
			t.Errorf("Instruction %d: expected PC %d, got %d", i, expected.pc, instr.PC)
		}

		if instr.OpcodeName != expected.opcode {
			t.Errorf("Instruction %d: expected opcode %s, got %s", i, expected.opcode, instr.OpcodeName)
		}

		if len(instr.HexBytes) != expected.size {
			t.Errorf("Instruction %d: expected size %d, got %d", i, expected.size, len(instr.HexBytes))
		}

		// Check line numbers are sequential
		if instr.LineNumber != i+1 {
			t.Errorf("Instruction %d: expected line number %d, got %d", i, i+1, instr.LineNumber)
		}
	}

	// Check jump destinations
	jumpDestFound := false
	for _, instr := range result.Instructions {
		if instr.IsJumpDest {
			jumpDestFound = true
			if instr.PC != 13 { // JUMPDEST should be at PC 13
				t.Errorf("Expected JUMPDEST at PC 13, found at PC %d", instr.PC)
			}
		}
	}

	if !jumpDestFound {
		t.Error("No jump destinations found, expected one JUMPDEST")
	}

	if result.JumpDestCount != 1 {
		t.Errorf("Expected 1 jump destination, got %d", result.JumpDestCount)
	}

	// Check PUSH values
	pushInstructions := []struct {
		pc    uint64
		value string
		decimal *uint64
	}{
		{0, "0x80", func() *uint64 { v := uint64(0x80); return &v }()},
		{2, "0x40", func() *uint64 { v := uint64(0x40); return &v }()},
		{5, "0x3e8", func() *uint64 { v := uint64(0x3e8); return &v }()}, // 1000
		{8, "0x0", func() *uint64 { v := uint64(0x0); return &v }()},
		{11, "0x5", func() *uint64 { v := uint64(0x5); return &v }()},
		{14, "0x1", func() *uint64 { v := uint64(0x1); return &v }()},
		{18, "0xa", func() *uint64 { v := uint64(0xa); return &v }()}, // 10
		{21, "0x5", func() *uint64 { v := uint64(0x5); return &v }()},
	}

	for _, expected := range pushInstructions {
		var found *Instruction
		for _, instr := range result.Instructions {
			if instr.PC == expected.pc {
				found = &instr
				break
			}
		}

		if found == nil {
			t.Errorf("PUSH instruction not found at PC %d", expected.pc)
			continue
		}

		if found.PushValue == nil || *found.PushValue != expected.value {
			t.Errorf("PC %d: expected push value %s, got %v", expected.pc, expected.value, found.PushValue)
		}

		if expected.decimal != nil {
			if found.PushValueDecimal == nil || *found.PushValueDecimal != *expected.decimal {
				t.Errorf("PC %d: expected decimal value %d, got %v", expected.pc, *expected.decimal, found.PushValueDecimal)
			}
		}
	}

	// Check gas costs are present for key instructions
	gasChecks := map[uint64]uint64{
		4:  3,   // MSTORE
		10: 100, // SSTORE (warm access cost)  
		16: 3,   // ADD
		20: 3,   // LT
		23: 10,  // JUMPI
	}

	for pc, expectedGas := range gasChecks {
		var found *Instruction
		for _, instr := range result.Instructions {
			if instr.PC == pc {
				found = &instr
				break
			}
		}

		if found == nil {
			t.Errorf("Instruction not found at PC %d", pc)
			continue
		}

		if found.GasCost == nil {
			t.Errorf("PC %d: no gas cost found", pc)
			continue
		}

		if *found.GasCost != expectedGas {
			t.Errorf("PC %d: expected gas cost %d, got %d", pc, expectedGas, *found.GasCost)
		}
	}

	// Verify JSON serialization works
	jsonData, err := json.Marshal(result)
	if err != nil {
		t.Errorf("Failed to marshal to JSON: %v", err)
	}

	if len(jsonData) == 0 {
		t.Error("Empty JSON output")
	}

	// Verify we can unmarshal it back
	var unmarshaled DisassemblyResult
	if err := json.Unmarshal(jsonData, &unmarshaled); err != nil {
		t.Errorf("Failed to unmarshal JSON: %v", err)
	}

	if unmarshaled.Length != result.Length {
		t.Errorf("JSON roundtrip failed: length mismatch")
	}

	// Test BasicBlocks are populated and make sense
	if len(result.Analysis.BasicBlocks) == 0 {
		t.Error("No basic blocks found, expected at least one")
	} else {
		// Verify basic blocks have valid ranges
		for i, block := range result.Analysis.BasicBlocks {
			if block.Start > block.End {
				t.Errorf("BasicBlock %d: invalid range, start %d > end %d", i, block.Start, block.End)
			}
			
			// Check that basic blocks don't overlap with next block (allow adjacent blocks)
			if i < len(result.Analysis.BasicBlocks)-1 {
				nextBlock := result.Analysis.BasicBlocks[i+1]
				if block.End > nextBlock.Start {
					t.Errorf("BasicBlocks %d and %d overlap: block %d ends at %d, block %d starts at %d", 
						i, i+1, i, block.End, i+1, nextBlock.Start)
				}
			}
			
			// Verify that basic blocks are within reasonable bounds
			// Note: End might be exclusive (one past last PC) or inclusive
			if block.End > uint32(len(code)) {
				t.Errorf("BasicBlock %d: end %d exceeds bytecode length %d", i, block.End, len(code))
			}
		}
		
		// First basic block should start at 0
		if result.Analysis.BasicBlocks[0].Start != 0 {
			t.Errorf("First basic block should start at 0, got %d", result.Analysis.BasicBlocks[0].Start)
		}
		
		// Check if our loop creates expected basic blocks
		// We expect blocks to be separated by jumps/jump destinations
		// Block 1: 0-10 (before JUMPDEST at PC 13)
		// Block 2: 11-23 (JUMPDEST to JUMPI) 
		// Block 3: 24-24 (STOP)
		if len(result.Analysis.BasicBlocks) < 2 {
			t.Errorf("Expected at least 2 basic blocks for this bytecode pattern, got %d", len(result.Analysis.BasicBlocks))
		}
	}
}

func TestAnalyzeBytecode_EmptyBytecode(t *testing.T) {
	bc, err := bytecode.New([]byte{})
	if err != nil {
		t.Fatalf("Failed to create empty bytecode: %v", err)
	}
	defer bc.Destroy()

	result, err := AnalyzeBytecode(bc)
	if err != nil {
		t.Fatalf("Failed to pretty print empty bytecode: %v", err)
	}

	if result.Length != 0 {
		t.Errorf("Expected length 0, got %d", result.Length)
	}

	if len(result.Instructions) != 0 {
		t.Errorf("Expected 0 instructions, got %d", len(result.Instructions))
	}

	if result.JumpDestCount != 0 {
		t.Errorf("Expected 0 jump destinations, got %d", result.JumpDestCount)
	}

	if result.TotalInstructions != 0 {
		t.Errorf("Expected 0 total instructions, got %d", result.TotalInstructions)
	}

	// Empty bytecode should have no basic blocks
	if len(result.Analysis.BasicBlocks) != 0 {
		t.Errorf("Expected 0 basic blocks for empty bytecode, got %d", len(result.Analysis.BasicBlocks))
	}
}

func TestAnalyzeBytecode_PUSHVariations(t *testing.T) {
	// Test different PUSH sizes
	code := []byte{
		0x5f,             // PUSH0
		0x60, 0xff,       // PUSH1 0xff
		0x61, 0x12, 0x34, // PUSH2 0x1234
		0x7f, // PUSH32 followed by 32 bytes
		0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
		0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x10,
		0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18,
		0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f, 0x20,
		0x00, // STOP
	}

	bc, err := bytecode.New(code)
	if err != nil {
		t.Fatalf("Failed to create bytecode: %v", err)
	}
	defer bc.Destroy()

	result, err := AnalyzeBytecode(bc)
	if err != nil {
		t.Fatalf("Failed to pretty print: %v", err)
	}

	if len(result.Instructions) != 5 { // PUSH0, PUSH1, PUSH2, PUSH32, STOP
		t.Errorf("Expected 5 instructions, got %d", len(result.Instructions))
	}

	// Check PUSH0
	push0 := result.Instructions[0]
	if push0.OpcodeName != "PUSH0" {
		t.Errorf("Expected PUSH0, got %s", push0.OpcodeName)
	}
	if push0.PushValue == nil || *push0.PushValue != "0x0" {
		t.Errorf("PUSH0 should have value 0x0, got %v", push0.PushValue)
	}
	if push0.PushValueDecimal == nil || *push0.PushValueDecimal != 0 {
		t.Errorf("PUSH0 should have decimal value 0, got %v", push0.PushValueDecimal)
	}

	// Check PUSH1
	push1 := result.Instructions[1]
	if push1.OpcodeName != "PUSH1" {
		t.Errorf("Expected PUSH1, got %s", push1.OpcodeName)
	}
	if push1.PushValue == nil || *push1.PushValue != "0xff" {
		t.Errorf("PUSH1 should have value 0xff, got %v", push1.PushValue)
	}

	// Check PUSH2
	push2 := result.Instructions[2]
	if push2.OpcodeName != "PUSH2" {
		t.Errorf("Expected PUSH2, got %s", push2.OpcodeName)
	}
	if push2.PushValue == nil || *push2.PushValue != "0x1234" {
		t.Errorf("PUSH2 should have value 0x1234, got %v", push2.PushValue)
	}

	// Check PUSH32 - should have large value, no decimal
	push32 := result.Instructions[3]
	if push32.OpcodeName != "PUSH32" {
		t.Errorf("Expected PUSH32, got %s", push32.OpcodeName)
	}
	if push32.PushValue == nil {
		t.Error("PUSH32 should have a push value")
	}
	if push32.PushValueDecimal != nil {
		t.Error("PUSH32 should not have decimal value (too large)")
	}
	if len(push32.HexBytes) != 33 { // 1 opcode + 32 data bytes
		t.Errorf("PUSH32 should have 33 hex bytes, got %d", len(push32.HexBytes))
	}

	// Test BasicBlocks for simple sequential code (no jumps)
	// Should have one basic block covering the entire sequence
	if len(result.Analysis.BasicBlocks) == 0 {
		t.Error("Expected at least one basic block")
	} else {
		// Should start at 0 and cover the entire bytecode
		firstBlock := result.Analysis.BasicBlocks[0]
		if firstBlock.Start != 0 {
			t.Errorf("First basic block should start at 0, got %d", firstBlock.Start)
		}
		
		// For sequential code with no jumps, we might have one or more blocks
		// Just ensure they cover the range properly
		if len(result.Analysis.BasicBlocks) >= 1 {
			lastBlock := result.Analysis.BasicBlocks[len(result.Analysis.BasicBlocks)-1]
			if lastBlock.End > uint32(len(code)) {
				t.Errorf("Last basic block end %d exceeds bytecode length %d", 
					lastBlock.End, len(code))
			}
		}
	}
}