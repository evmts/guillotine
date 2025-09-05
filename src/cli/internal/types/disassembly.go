package types

// DisassemblyResult holds the result of bytecode disassembly analysis
type DisassemblyResult struct {
	Instructions []DisassemblyInstruction
	Jumpdests    []uint32
	BasicBlocks  []BasicBlock
	Stats        BytecodeStats
}

// DisassemblyInstruction represents a single EVM instruction
type DisassemblyInstruction struct {
	PC           uint32
	OpcodeHex    uint8
	OpcodeName   string
	PushValue    *PushValue
	GasCost      uint16
	StackInputs  uint8
	StackOutputs uint8
}

// PushValue represents a 256-bit push value
type PushValue struct {
	Low  uint64
	High uint64
}

// BasicBlock represents a basic block in the bytecode
type BasicBlock struct {
	Start uint32
	End   uint32
}

// BytecodeStats contains statistics about the bytecode
type BytecodeStats struct {
	OriginalSize    uint32
	DispatchSize    uint32
	BasicBlockCount uint32
	JumpdestCount   uint32
	GasFirstBlock   uint32
}