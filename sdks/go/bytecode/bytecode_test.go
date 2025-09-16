package bytecode_test

import (
	"testing"

	"github.com/evmts/guillotine/sdks/go/bytecode"
)

func TestBytecodeBasics(t *testing.T) {
	// Simple bytecode: PUSH1 0x01 PUSH1 0x02 ADD
	code := []byte{0x60, 0x01, 0x60, 0x02, 0x01}

	bc, err := bytecode.New(code)
	if err != nil {
		t.Fatalf("Failed to create bytecode: %v", err)
	}
	defer bc.Destroy()

	// Test length
	length, err := bc.Length()
	if err != nil {
		t.Fatalf("Failed to get length: %v", err)
	}
	if length != uint64(len(code)) {
		t.Errorf("Expected length %d, got %d", len(code), length)
	}

	// Test opcode retrieval
	opcode, err := bc.OpcodeAt(0)
	if err != nil {
		t.Fatalf("Failed to get opcode at 0: %v", err)
	}
	if opcode != 0x60 { // PUSH1
		t.Errorf("Expected opcode 0x60 at position 0, got 0x%02x", opcode)
	}

	// Runtime data should match the original input
	runtime, err := bc.RuntimeData()
	if err != nil {
		t.Fatalf("Failed to get runtime data: %v", err)
	}
	if len(runtime) != len(code) {
		t.Fatalf("Expected runtime length %d, got %d", len(code), len(runtime))
	}
	for i, b := range runtime {
		if b != code[i] {
			t.Errorf("Runtime mismatch at %d: expected %02x, got %02x", i, code[i], b)
		}
	}
}

func TestBytecodeAnalysisJumpDests(t *testing.T) {
	// Bytecode with JUMPDEST: PUSH1 0x04 JUMP INVALID JUMPDEST STOP
	code := []byte{0x60, 0x04, 0x56, 0xFE, 0x5B, 0x00}

	bc, err := bytecode.New(code)
	if err != nil {
		t.Fatalf("Failed to create bytecode: %v", err)
	}
	defer bc.Destroy()

	analysis, err := bc.Analyze()
	if err != nil {
		t.Fatalf("Failed to analyze bytecode: %v", err)
	}

	if len(analysis.JumpDests) != 1 || analysis.JumpDests[0] != 4 {
		t.Errorf("Expected jump dest at position 4, got %v", analysis.JumpDests)
	}
}

func TestEmptyBytecode(t *testing.T) {
	bc, err := bytecode.New([]byte{})
	if err != nil {
		t.Fatalf("Failed to create empty bytecode: %v", err)
	}
	defer bc.Destroy()

	length, err := bc.Length()
	if err != nil {
		t.Fatalf("Failed to get length: %v", err)
	}
	if length != 0 {
		t.Errorf("Expected length 0 for empty bytecode, got %d", length)
	}

	runtime, err := bc.RuntimeData()
	if err != nil {
		t.Fatalf("Failed to get runtime data: %v", err)
	}
	if len(runtime) != 0 {
		t.Errorf("Expected empty runtime data, got %d bytes", len(runtime))
	}
}

func TestOpcodeName(t *testing.T) {
	tests := []struct {
		opcode uint8
		name   string
	}{
		{0x00, "STOP"},
		{0x01, "ADD"},
		{0x02, "MUL"},
		{0x56, "JUMP"},
		{0x57, "JUMPI"},
		{0x5B, "JUMPDEST"},
		{0x60, "PUSH1"},
		{0x61, "PUSH2"},
		{0xFE, "INVALID"},
	}

	for _, test := range tests {
		name := bytecode.OpcodeName(test.opcode)
		if name != test.name {
			t.Errorf("Opcode 0x%02x: expected name %s, got %s", test.opcode, test.name, name)
		}
	}
}

func TestBytecodeWithMetadata(t *testing.T) {
	// Simple bytecode without metadata
	code := []byte{
		0x60, 0x01, // PUSH1 0x01
		0x60, 0x02, // PUSH1 0x02
		0x01, // ADD
		0x00, // STOP
	}

	bc, err := bytecode.New(code)
	if err != nil {
		t.Fatalf("Failed to create bytecode: %v", err)
	}
	defer bc.Destroy()
}
