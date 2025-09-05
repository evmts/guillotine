package disassembly

/*
#cgo CFLAGS: -I../../../
#cgo LDFLAGS: -L../../../zig-out/lib -lguillotine

#include <stdint.h>
#include <stdlib.h>

// C-compatible instruction representation (matches CInstruction in bytecode_disassembly_c.zig)
typedef struct {
    uint32_t pc;
    const char* opcode_name;
    uint8_t opcode_hex;
    uint16_t gas_cost;
    uint8_t stack_inputs;
    uint8_t stack_outputs;
    uint64_t push_value_low;
    uint64_t push_value_high;
    uint64_t push_value_extra_high;
    uint64_t push_value_top;
    uint8_t has_push_value;
} CInstruction;

// C-compatible basic block representation
typedef struct {
    uint32_t start;
    uint32_t end;
} CBasicBlock;

// C-compatible statistics structure
typedef struct {
    uint32_t original_size;
    uint32_t dispatch_size;
    uint32_t gas_first_block;
    uint32_t jumpdest_count;
    uint32_t basic_block_count;
} CStats;

// C-compatible complete result structure
typedef struct {
    CInstruction* instructions;
    uint32_t instruction_count;
    uint32_t* jumpdests;
    uint32_t jumpdest_count;
    CBasicBlock* basic_blocks;
    uint32_t basic_block_count;
    CStats stats;
} CResult;

// Error codes (matches BytecodeDisassemblyC constants)
#define EVM_DISASM_SUCCESS 0
#define EVM_DISASM_ERROR_NULL_POINTER -1
#define EVM_DISASM_ERROR_INVALID_BYTECODE -2
#define EVM_DISASM_ERROR_OUT_OF_MEMORY -3

// Function prototypes for the C exports from root.zig
extern int evm_disasm_analyze(const uint8_t* data, size_t data_len, CResult* result_out);
extern void evm_disasm_free_result(CResult* result);
extern const char* evm_disasm_error_string(int error_code);
*/
import "C"
import (
	"fmt"
	"unsafe"
)

// Instruction represents a single EVM instruction
type Instruction struct {
	PC           uint32
	OpcodeName   string
	OpcodeHex    uint8
	GasCost      uint16
	StackInputs  uint8
	StackOutputs uint8
	PushValue    *uint256 // nil if not a PUSH instruction
}

// uint256 represents a 256-bit unsigned integer
type uint256 struct {
	Low       uint64
	High      uint64
	ExtraHigh uint64
	Top       uint64
}

// BasicBlock represents a basic block in the bytecode
type BasicBlock struct {
	Start uint32
	End   uint32
}

// Stats contains statistics about the analyzed bytecode
type Stats struct {
	OriginalSize    uint32
	DispatchSize    uint32
	GasFirstBlock   uint32
	JumpdestCount   uint32
	BasicBlockCount uint32
}

// Result contains the complete analysis result
type Result struct {
	Instructions []Instruction
	Jumpdests    []uint32
	BasicBlocks  []BasicBlock
	Stats        Stats
	cResult      C.CResult // Keep reference for cleanup
}

// Error codes
const (
	Success           = C.EVM_DISASM_SUCCESS
	ErrNullPointer    = C.EVM_DISASM_ERROR_NULL_POINTER
	ErrInvalidBytecode = C.EVM_DISASM_ERROR_INVALID_BYTECODE
	ErrOutOfMemory    = C.EVM_DISASM_ERROR_OUT_OF_MEMORY
)

// Analyze performs bytecode disassembly and analysis
func Analyze(bytecode []byte) (*Result, error) {
	if len(bytecode) == 0 {
		return nil, fmt.Errorf("empty bytecode")
	}

	var cResult C.CResult
	
	// Call the C API
	rc := C.evm_disasm_analyze(
		(*C.uint8_t)(unsafe.Pointer(&bytecode[0])),
		C.size_t(len(bytecode)),
		&cResult,
	)
	
	if rc != Success {
		errorStr := C.GoString(C.evm_disasm_error_string(rc))
		return nil, fmt.Errorf("disassembly failed with code %d: %s", rc, errorStr)
	}
	
	// Convert C result to Go
	result := &Result{
		cResult: cResult,
		Stats: Stats{
			OriginalSize:    uint32(cResult.stats.original_size),
			DispatchSize:    uint32(cResult.stats.dispatch_size),
			GasFirstBlock:   uint32(cResult.stats.gas_first_block),
			JumpdestCount:   uint32(cResult.stats.jumpdest_count),
			BasicBlockCount: uint32(cResult.stats.basic_block_count),
		},
	}
	
	// Convert instructions
	if cResult.instruction_count > 0 {
		instructions := (*[1 << 20]C.CInstruction)(unsafe.Pointer(cResult.instructions))[:cResult.instruction_count:cResult.instruction_count]
		result.Instructions = make([]Instruction, cResult.instruction_count)
		
		for i, cInst := range instructions {
			inst := Instruction{
				PC:           uint32(cInst.pc),
				OpcodeName:   C.GoString(cInst.opcode_name),
				OpcodeHex:    uint8(cInst.opcode_hex),
				GasCost:      uint16(cInst.gas_cost),
				StackInputs:  uint8(cInst.stack_inputs),
				StackOutputs: uint8(cInst.stack_outputs),
			}
			
			if cInst.has_push_value != 0 {
				inst.PushValue = &uint256{
					Low:       uint64(cInst.push_value_low),
					High:      uint64(cInst.push_value_high),
					ExtraHigh: uint64(cInst.push_value_extra_high),
					Top:       uint64(cInst.push_value_top),
				}
			}
			
			result.Instructions[i] = inst
		}
	}
	
	// Convert jumpdests
	if cResult.jumpdest_count > 0 {
		jumpdests := (*[1 << 20]C.uint32_t)(unsafe.Pointer(cResult.jumpdests))[:cResult.jumpdest_count:cResult.jumpdest_count]
		result.Jumpdests = make([]uint32, cResult.jumpdest_count)
		for i, jd := range jumpdests {
			result.Jumpdests[i] = uint32(jd)
		}
	}
	
	// Convert basic blocks
	if cResult.basic_block_count > 0 {
		blocks := (*[1 << 20]C.CBasicBlock)(unsafe.Pointer(cResult.basic_blocks))[:cResult.basic_block_count:cResult.basic_block_count]
		result.BasicBlocks = make([]BasicBlock, cResult.basic_block_count)
		for i, block := range blocks {
			result.BasicBlocks[i] = BasicBlock{
				Start: uint32(block.start),
				End:   uint32(block.end),
			}
		}
	}
	
	return result, nil
}

// Free releases the underlying C memory
func (r *Result) Free() {
	if r != nil {
		C.evm_disasm_free_result(&r.cResult)
	}
}

// GetErrorString returns a human-readable error message for an error code
func GetErrorString(code int) string {
	return C.GoString(C.evm_disasm_error_string(C.int(code)))
}