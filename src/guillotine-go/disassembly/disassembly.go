package disassembly

/*
#cgo CFLAGS: -I../../../
#cgo LDFLAGS: -L../../../zig-out/lib -lguillotine

#include <stdint.h>
#include <stdlib.h>

// Instruction type enumeration (matches Zig InstructionType union tags)
typedef enum {
    INSTRUCTION_TYPE_REGULAR = 0,
    INSTRUCTION_TYPE_PUSH_ADD_FUSION = 1,
    INSTRUCTION_TYPE_PUSH_MUL_FUSION = 2,
    INSTRUCTION_TYPE_PUSH_SUB_FUSION = 3,
    INSTRUCTION_TYPE_PUSH_DIV_FUSION = 4,
    INSTRUCTION_TYPE_PUSH_AND_FUSION = 5,
    INSTRUCTION_TYPE_PUSH_OR_FUSION = 6,
    INSTRUCTION_TYPE_PUSH_XOR_FUSION = 7,
    INSTRUCTION_TYPE_PUSH_JUMP_FUSION = 8,
    INSTRUCTION_TYPE_PUSH_JUMPI_FUSION = 9,
    INSTRUCTION_TYPE_CONSTANT_FOLD = 10,
    INSTRUCTION_TYPE_MULTI_PUSH = 11,
    INSTRUCTION_TYPE_MULTI_POP = 12,
    INSTRUCTION_TYPE_ISZERO_JUMPI = 13,
    INSTRUCTION_TYPE_DUP2_MSTORE_PUSH = 14,
    INSTRUCTION_TYPE_STATIC_JUMP_CANDIDATE = 15,
} CInstructionType;

// Value storage type (matches Zig ValueStorage enum)
typedef enum {
    VALUE_STORAGE_INLINE_64BIT = 0,
    VALUE_STORAGE_POINTER_LARGE = 1,
} CValueStorage;

// Original opcode representation (matches Zig OriginalOpcode)
typedef struct {
    uint32_t pc;
    uint8_t opcode;
    const char* name;
    uint64_t push_value_low;
    uint64_t push_value_high;
    uint64_t push_value_extra_high;
    uint64_t push_value_top;
    uint8_t has_push_value;
} COriginalOpcode;

// Analysis instruction (matches Zig AnalysisInstruction)
typedef struct {
    uint32_t original_pc;
    CInstructionType instruction_type;
    uint32_t gas_cost;
    uint8_t stack_inputs;
    uint8_t stack_outputs;
    
    // Regular instruction data
    uint8_t regular_opcode;
    const char* regular_name;
    
    // Fusion value data (for push fusions)
    uint64_t fusion_value_low;
    uint64_t fusion_value_high;
    uint64_t fusion_value_extra_high;
    uint64_t fusion_value_top;
    uint8_t has_fusion_value;
    CValueStorage value_storage;
    
    // Advanced fusion data
    uint64_t folded_value_low;
    uint64_t folded_value_high;
    uint64_t folded_value_extra_high;
    uint64_t folded_value_top;
    uint8_t fusion_count;
    uint8_t original_length;
    uint32_t target_pc; // for static jump candidates
    const char* operation_name;
    
    // Original opcodes array
    COriginalOpcode* original_opcodes;
    uint32_t original_opcodes_count;
} CAnalysisInstruction;

// Analysis statistics (matches Zig Stats)
typedef struct {
    uint32_t original_count;
    uint32_t optimized_count;
    uint32_t fusion_count;
    uint32_t inline_value_count;
    uint32_t pointer_value_count;
    uint32_t static_jump_candidates;
    uint32_t gas_saved_estimate;
    float compression_ratio;
} CAnalysisStats;

// Analysis result (matches Zig AnalysisResult)
typedef struct {
    CAnalysisInstruction* instructions;
    uint32_t instruction_count;
    CAnalysisStats stats;
} CAnalysisResult;

// Error codes
#define BYTECODE_ANALYSIS_SUCCESS 0
#define BYTECODE_ANALYSIS_ERROR_NULL_POINTER -1
#define BYTECODE_ANALYSIS_ERROR_INVALID_BYTECODE -2
#define BYTECODE_ANALYSIS_ERROR_OUT_OF_MEMORY -3

// Function prototypes for the C exports
extern int evm_disasm_analyze(const uint8_t* data, size_t data_len, CAnalysisResult* result_out);
extern void evm_disasm_free_result(CAnalysisResult* result);
extern const char* evm_disasm_error_string(int error_code);
*/
import "C"
import (
	"fmt"
	"unsafe"
)

// InstructionType represents the type of instruction or optimization
type InstructionType int

const (
	InstructionTypeRegular             InstructionType = C.INSTRUCTION_TYPE_REGULAR
	InstructionTypePushAddFusion       InstructionType = C.INSTRUCTION_TYPE_PUSH_ADD_FUSION
	InstructionTypePushMulFusion       InstructionType = C.INSTRUCTION_TYPE_PUSH_MUL_FUSION
	InstructionTypePushSubFusion       InstructionType = C.INSTRUCTION_TYPE_PUSH_SUB_FUSION
	InstructionTypePushDivFusion       InstructionType = C.INSTRUCTION_TYPE_PUSH_DIV_FUSION
	InstructionTypePushAndFusion       InstructionType = C.INSTRUCTION_TYPE_PUSH_AND_FUSION
	InstructionTypePushOrFusion        InstructionType = C.INSTRUCTION_TYPE_PUSH_OR_FUSION
	InstructionTypePushXorFusion       InstructionType = C.INSTRUCTION_TYPE_PUSH_XOR_FUSION
	InstructionTypePushJumpFusion      InstructionType = C.INSTRUCTION_TYPE_PUSH_JUMP_FUSION
	InstructionTypePushJumpiFusion     InstructionType = C.INSTRUCTION_TYPE_PUSH_JUMPI_FUSION
	InstructionTypeConstantFold        InstructionType = C.INSTRUCTION_TYPE_CONSTANT_FOLD
	InstructionTypeMultiPush           InstructionType = C.INSTRUCTION_TYPE_MULTI_PUSH
	InstructionTypeMultiPop            InstructionType = C.INSTRUCTION_TYPE_MULTI_POP
	InstructionTypeIszeroJumpi         InstructionType = C.INSTRUCTION_TYPE_ISZERO_JUMPI
	InstructionTypeDup2MstorePush      InstructionType = C.INSTRUCTION_TYPE_DUP2_MSTORE_PUSH
	InstructionTypeStaticJumpCandidate InstructionType = C.INSTRUCTION_TYPE_STATIC_JUMP_CANDIDATE
)

// ValueStorage represents how fusion values are stored
type ValueStorage int

const (
	ValueStorageInline64Bit   ValueStorage = C.VALUE_STORAGE_INLINE_64BIT
	ValueStoragePointerLarge  ValueStorage = C.VALUE_STORAGE_POINTER_LARGE
)

// String representations for instruction types
func (it InstructionType) String() string {
	switch it {
	case InstructionTypeRegular:
		return "REGULAR"
	case InstructionTypePushAddFusion:
		return "PUSH_ADD_FUSION"
	case InstructionTypePushMulFusion:
		return "PUSH_MUL_FUSION"
	case InstructionTypePushSubFusion:
		return "PUSH_SUB_FUSION"
	case InstructionTypePushDivFusion:
		return "PUSH_DIV_FUSION"
	case InstructionTypePushAndFusion:
		return "PUSH_AND_FUSION"
	case InstructionTypePushOrFusion:
		return "PUSH_OR_FUSION"
	case InstructionTypePushXorFusion:
		return "PUSH_XOR_FUSION"
	case InstructionTypePushJumpFusion:
		return "PUSH_JUMP_FUSION"
	case InstructionTypePushJumpiFusion:
		return "PUSH_JUMPI_FUSION"
	case InstructionTypeConstantFold:
		return "CONSTANT_FOLD"
	case InstructionTypeMultiPush:
		return "MULTI_PUSH"
	case InstructionTypeMultiPop:
		return "MULTI_POP"
	case InstructionTypeIszeroJumpi:
		return "ISZERO_JUMPI"
	case InstructionTypeDup2MstorePush:
		return "DUP2_MSTORE_PUSH"
	case InstructionTypeStaticJumpCandidate:
		return "STATIC_JUMP_CANDIDATE"
	default:
		return "UNKNOWN"
	}
}

// uint256 represents a 256-bit unsigned integer
type uint256 struct {
	Low       uint64
	High      uint64
	ExtraHigh uint64
	Top       uint64
}

// OriginalOpcode represents an original EVM opcode before fusion
type OriginalOpcode struct {
	PC          uint32
	OpcodeHex   uint8
	OpcodeName  string
	PushValue   *uint256 // nil if not a PUSH instruction
}

// Instruction represents an analyzed EVM instruction with fusion information
type Instruction struct {
	PC           uint32
	OpcodeName   string
	OpcodeHex    uint8
	GasCost      uint32
	StackInputs  uint8
	StackOutputs uint8
	FusionType   InstructionType
	
	// Fusion data
	PushValue     *uint256      // For push fusions
	ValueStorage  ValueStorage  // How the fusion value is stored
	
	// Advanced fusion data
	FoldedValue     *uint256 // For constant fold
	FusionCount     uint8    // For multi operations
	OriginalLength  uint8    // Original bytecode length
	TargetPC        uint32   // For static jump candidates
	OperationName   string   // For advanced fusions
	
	// Original opcodes that were fused into this instruction
	OriginalOpcodes []OriginalOpcode
}

// Stats contains comprehensive analysis statistics
type Stats struct {
	OriginalCount        uint32  // Number of original opcodes
	OptimizedCount       uint32  // Number of optimized instructions
	FusionCount          uint32  // Number of fusions performed
	InlineValueCount     uint32  // Number of inline-stored fusion values
	PointerValueCount    uint32  // Number of pointer-stored fusion values
	StaticJumpCandidates uint32  // Number of static jump candidates
	GasSavedEstimate     uint32  // Estimated gas savings from optimizations
	CompressionRatio     float32 // Compression ratio (optimized/original)
}

// Result contains the complete bytecode analysis result
type Result struct {
	Instructions []Instruction
	Stats        Stats
	cResult      C.CAnalysisResult // Keep reference for cleanup
}

// Error codes
const (
	Success              = C.BYTECODE_ANALYSIS_SUCCESS
	ErrNullPointer       = C.BYTECODE_ANALYSIS_ERROR_NULL_POINTER
	ErrInvalidBytecode   = C.BYTECODE_ANALYSIS_ERROR_INVALID_BYTECODE
	ErrOutOfMemory       = C.BYTECODE_ANALYSIS_ERROR_OUT_OF_MEMORY
)

// Analyze performs comprehensive bytecode analysis with fusion detection
func Analyze(bytecode []byte) (*Result, error) {
	if len(bytecode) == 0 {
		return nil, fmt.Errorf("empty bytecode")
	}

	var cResult C.CAnalysisResult
	
	// Call the C API
	rc := C.evm_disasm_analyze(
		(*C.uint8_t)(unsafe.Pointer(&bytecode[0])),
		C.size_t(len(bytecode)),
		&cResult,
	)
	
	if rc != Success {
		errorStr := C.GoString(C.evm_disasm_error_string(rc))
		return nil, fmt.Errorf("bytecode analysis failed with code %d: %s", rc, errorStr)
	}
	
	// Convert C result to Go
	result := &Result{
		cResult: cResult,
		Stats: Stats{
			OriginalCount:        uint32(cResult.stats.original_count),
			OptimizedCount:       uint32(cResult.stats.optimized_count),
			FusionCount:          uint32(cResult.stats.fusion_count),
			InlineValueCount:     uint32(cResult.stats.inline_value_count),
			PointerValueCount:    uint32(cResult.stats.pointer_value_count),
			StaticJumpCandidates: uint32(cResult.stats.static_jump_candidates),
			GasSavedEstimate:     uint32(cResult.stats.gas_saved_estimate),
			CompressionRatio:     float32(cResult.stats.compression_ratio),
		},
	}
	
	// Convert instructions
	if cResult.instruction_count > 0 {
		instructions := (*[1 << 20]C.CAnalysisInstruction)(unsafe.Pointer(cResult.instructions))[:cResult.instruction_count:cResult.instruction_count]
		result.Instructions = make([]Instruction, cResult.instruction_count)
		
		for i, cInst := range instructions {
			inst := Instruction{
				PC:           uint32(cInst.original_pc),
				GasCost:      uint32(cInst.gas_cost),
				StackInputs:  uint8(cInst.stack_inputs),
				StackOutputs: uint8(cInst.stack_outputs),
				FusionType:   InstructionType(cInst.instruction_type),
			}
			
			// Set opcode name based on instruction type
			if cInst.instruction_type == C.INSTRUCTION_TYPE_REGULAR {
				inst.OpcodeName = C.GoString(cInst.regular_name)
				inst.OpcodeHex = uint8(cInst.regular_opcode)
			} else {
				inst.OpcodeName = InstructionType(cInst.instruction_type).String()
			}
			
			// Handle fusion value (for push fusions)
			if cInst.has_fusion_value != 0 {
				inst.PushValue = &uint256{
					Low:       uint64(cInst.fusion_value_low),
					High:      uint64(cInst.fusion_value_high),
					ExtraHigh: uint64(cInst.fusion_value_extra_high),
					Top:       uint64(cInst.fusion_value_top),
				}
				inst.ValueStorage = ValueStorage(cInst.value_storage)
			}
			
			// Handle advanced fusion data
			switch InstructionType(cInst.instruction_type) {
			case InstructionTypeConstantFold:
				inst.FoldedValue = &uint256{
					Low:       uint64(cInst.folded_value_low),
					High:      uint64(cInst.folded_value_high),
					ExtraHigh: uint64(cInst.folded_value_extra_high),
					Top:       uint64(cInst.folded_value_top),
				}
				if cInst.operation_name != nil {
					inst.OperationName = C.GoString(cInst.operation_name)
				}
			case InstructionTypeMultiPush, InstructionTypeMultiPop:
				inst.FusionCount = uint8(cInst.fusion_count)
			case InstructionTypeStaticJumpCandidate:
				inst.TargetPC = uint32(cInst.target_pc)
			}
			
			inst.OriginalLength = uint8(cInst.original_length)
			
			// Convert original opcodes
			if cInst.original_opcodes_count > 0 {
				origOpcodes := (*[1 << 20]C.COriginalOpcode)(unsafe.Pointer(cInst.original_opcodes))[:cInst.original_opcodes_count:cInst.original_opcodes_count]
				inst.OriginalOpcodes = make([]OriginalOpcode, cInst.original_opcodes_count)
				
				for j, cOrig := range origOpcodes {
					orig := OriginalOpcode{
						PC:         uint32(cOrig.pc),
						OpcodeHex:  uint8(cOrig.opcode),
						OpcodeName: C.GoString(cOrig.name),
					}
					
					if cOrig.has_push_value != 0 {
						orig.PushValue = &uint256{
							Low:       uint64(cOrig.push_value_low),
							High:      uint64(cOrig.push_value_high),
							ExtraHigh: uint64(cOrig.push_value_extra_high),
							Top:       uint64(cOrig.push_value_top),
						}
					}
					
					inst.OriginalOpcodes[j] = orig
				}
			}
			
			result.Instructions[i] = inst
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

// Convenience methods for checking instruction types
func (inst *Instruction) IsRegular() bool {
	return inst.FusionType == InstructionTypeRegular
}

func (inst *Instruction) IsPushFusion() bool {
	return inst.FusionType >= InstructionTypePushAddFusion && inst.FusionType <= InstructionTypePushJumpiFusion
}

func (inst *Instruction) IsAdvancedFusion() bool {
	return inst.FusionType >= InstructionTypeConstantFold && inst.FusionType <= InstructionTypeDup2MstorePush
}

func (inst *Instruction) IsStaticJumpCandidate() bool {
	return inst.FusionType == InstructionTypeStaticJumpCandidate
}