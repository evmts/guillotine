package bytecode

/*
#cgo CFLAGS: -I../../../zig-out/include
#cgo LDFLAGS: -L../../../zig-out/lib -lguillotine_ffi
#include <stdlib.h>
#include <string.h>
#include "bytecode.h"
*/
import "C"
import (
	"errors"
	"fmt"
	"math/big"
	"runtime"
	"sync"
	"unsafe"
)

// PrettyPrint formats EVM bytecode with colorized disassembly
func PrettyPrint(bytecode []byte) (string, error) {
	if len(bytecode) == 0 {
		return "", fmt.Errorf("empty bytecode")
	}

	// First call to get required buffer size
	requiredSize := C.evm_bytecode_pretty_print(
		(*C.uchar)(unsafe.Pointer(&bytecode[0])),
		C.size_t(len(bytecode)),
		nil,
		0,
	)

	if requiredSize == 0 {
		return "", fmt.Errorf("failed to pretty print bytecode")
	}

	// Allocate buffer and get the pretty printed output
	buffer := make([]byte, requiredSize)
	actualSize := C.evm_bytecode_pretty_print(
		(*C.uchar)(unsafe.Pointer(&bytecode[0])),
		C.size_t(len(bytecode)),
		(*C.char)(unsafe.Pointer(&buffer[0])),
		C.size_t(len(buffer)),
	)

	if actualSize == 0 {
		return "", fmt.Errorf("failed to pretty print bytecode")
	}

	// Convert to string (actualSize includes null terminator)
	return string(buffer[:actualSize-1]), nil
}

// ========================
// Error Definitions
// ========================

var (
	ErrNullPointer       = errors.New("null pointer")
	ErrInvalidBytecode   = errors.New("invalid bytecode")
	ErrOutOfMemory       = errors.New("out of memory")
	ErrBytecodeTooLarge  = errors.New("bytecode too large")
	ErrInvalidOpcode     = errors.New("invalid opcode")
	ErrOutOfBounds       = errors.New("out of bounds")
	ErrBytecodeDestroyed = errors.New("bytecode handle has been destroyed")
)

// ========================
// Bytecode Handle
// ========================

// Bytecode represents analyzed EVM bytecode
type Bytecode struct {
	ptr *C.BytecodeHandle
	mu  sync.RWMutex
}

// ========================
// Constructor
// ========================

// New creates a new Bytecode instance from raw bytes
func New(data []byte) (*Bytecode, error) {
	// Initialize FFI allocator
	C.guillotine_init()

	// Pin memory for the bytecode data
	var pinner runtime.Pinner
	defer pinner.Unpin()

	var dataPtr *C.uint8_t
	if len(data) > 0 {
		pinner.Pin(&data[0])
		dataPtr = (*C.uint8_t)(unsafe.Pointer(&data[0]))
	}

	ptr := C.evm_bytecode_create(dataPtr, C.size_t(len(data)))
	if ptr == nil {
		errMsg := C.GoString(C.guillotine_get_last_error())
		if errMsg != "" {
			return nil, fmt.Errorf("failed to create bytecode: %s", errMsg)
		}
		return nil, ErrInvalidBytecode
	}

	bc := &Bytecode{ptr: ptr}
	runtime.SetFinalizer(bc, (*Bytecode).finalize)
	return bc, nil
}

// finalize is called by the garbage collector
func (b *Bytecode) finalize() {
	_ = b.Destroy()
}

// Destroy releases the bytecode resources
func (b *Bytecode) Destroy() error {
	b.mu.Lock()
	defer b.mu.Unlock()

	if b.ptr != nil {
		C.evm_bytecode_destroy(b.ptr)
		b.ptr = nil
		runtime.SetFinalizer(b, nil)
		C.guillotine_cleanup()
	}
	return nil
}

// ========================
// Basic Properties
// ========================

// Length returns the runtime bytecode length (excludes metadata)
func (b *Bytecode) Length() (uint64, error) {
	b.mu.RLock()
	defer b.mu.RUnlock()

	if b.ptr == nil {
		return 0, ErrBytecodeDestroyed
	}

	return uint64(C.evm_bytecode_get_length(b.ptr)), nil
}

// RuntimeData returns a copy of the runtime bytecode (excludes metadata)
func (b *Bytecode) RuntimeData() ([]byte, error) {
	b.mu.RLock()
	defer b.mu.RUnlock()

	if b.ptr == nil {
		return nil, ErrBytecodeDestroyed
	}

	length := C.evm_bytecode_get_length(b.ptr)
	if length == 0 {
		return []byte{}, nil
	}

	buffer := make([]byte, length)
	copied := C.evm_bytecode_get_runtime_data(b.ptr, (*C.uint8_t)(unsafe.Pointer(&buffer[0])), length)
	if copied != length {
		return nil, fmt.Errorf("failed to copy runtime data: expected %d, got %d", length, copied)
	}

	return buffer, nil
}

// ========================
// Opcode Operations
// ========================

// OpcodeAt returns the opcode at the given position
func (b *Bytecode) OpcodeAt(position uint64) (uint8, error) {
	b.mu.RLock()
	defer b.mu.RUnlock()

	if b.ptr == nil {
		return 0, ErrBytecodeDestroyed
	}

	opcode := C.evm_bytecode_get_opcode_at(b.ptr, C.size_t(position))
	if opcode == 0xFF {
		length, _ := b.Length()
		if position >= length {
			return 0, ErrOutOfBounds
		}
	}

	return uint8(opcode), nil
}

// ========================
// Advanced Analysis
// ========================

// Analyze performs comprehensive bytecode analysis including fusion detection
func (b *Bytecode) Analyze() (*Analysis, error) {
	b.mu.RLock()
	defer b.mu.RUnlock()

	if b.ptr == nil {
		return nil, ErrBytecodeDestroyed
	}

	var cAnalysis C.CBytecodeAnalysis
	result := C.evm_bytecode_analyze(b.ptr, &cAnalysis)
	if result != 0 {
		return nil, fmt.Errorf("failed to analyze: error code %d", result)
	}
	defer C.evm_bytecode_free_analysis(&cAnalysis)

	analysis := &Analysis{}

	// Copy push PCs
	if cAnalysis.push_pcs_count > 0 {
		pushPCs := (*[1 << 30]C.uint32_t)(unsafe.Pointer(cAnalysis.push_pcs))[:cAnalysis.push_pcs_count:cAnalysis.push_pcs_count]
		analysis.PushPCs = make([]uint32, len(pushPCs))
		for i, pc := range pushPCs {
			analysis.PushPCs[i] = uint32(pc)
		}
	}

	// Copy jump destinations
	if cAnalysis.jumpdests_count > 0 {
		jumpDests := (*[1 << 30]C.uint32_t)(unsafe.Pointer(cAnalysis.jumpdests))[:cAnalysis.jumpdests_count:cAnalysis.jumpdests_count]
		analysis.JumpDests = make([]uint32, len(jumpDests))
		for i, dest := range jumpDests {
			analysis.JumpDests[i] = uint32(dest)
		}
	}

	// Copy basic blocks
	if cAnalysis.basic_blocks_count > 0 {
		blocks := (*[1 << 30]C.CBasicBlock)(unsafe.Pointer(cAnalysis.basic_blocks))[:cAnalysis.basic_blocks_count:cAnalysis.basic_blocks_count]
		analysis.BasicBlocks = make([]BasicBlock, len(blocks))
		for i, block := range blocks {
			analysis.BasicBlocks[i] = BasicBlock{
				Start: uint32(block.start),
				End:   uint32(block.end),
			}
		}
	}

	// Copy jump fusions
	if cAnalysis.jump_fusions_count > 0 {
		jumpFusions := (*[1 << 30]C.CJumpFusion)(unsafe.Pointer(cAnalysis.jump_fusions))[:cAnalysis.jump_fusions_count:cAnalysis.jump_fusions_count]
		analysis.JumpFusions = make([]JumpFusion, len(jumpFusions))
		for i, fusion := range jumpFusions {
			analysis.JumpFusions[i] = JumpFusion{
				SourcePC: uint32(fusion.source_pc),
				TargetPC: uint32(fusion.target_pc),
			}
		}
	}

	// Copy advanced fusions
	if cAnalysis.advanced_fusions_count > 0 {
		advFusions := (*[1 << 30]C.CAdvancedFusion)(unsafe.Pointer(cAnalysis.advanced_fusions))[:cAnalysis.advanced_fusions_count:cAnalysis.advanced_fusions_count]
		analysis.AdvancedFusions = make([]AdvancedFusion, len(advFusions))
		for i, fusion := range advFusions {
			// Reconstruct the 256-bit folded value from 4 uint64 parts
			foldedValue := new(big.Int)
			foldedValue.SetUint64(uint64(fusion.info.folded_value_top))
			foldedValue.Lsh(foldedValue, 64)
			foldedValue.Or(foldedValue, new(big.Int).SetUint64(uint64(fusion.info.folded_value_extra_high)))
			foldedValue.Lsh(foldedValue, 64)
			foldedValue.Or(foldedValue, new(big.Int).SetUint64(uint64(fusion.info.folded_value_high)))
			foldedValue.Lsh(foldedValue, 64)
			foldedValue.Or(foldedValue, new(big.Int).SetUint64(uint64(fusion.info.folded_value_low)))

			analysis.AdvancedFusions[i] = AdvancedFusion{
				PC: uint32(fusion.pc),
				Info: FusionInfo{
					Type:           FusionType(fusion.info.fusion_type),
					OriginalLength: uint32(fusion.info.original_length),
					FoldedValue:    foldedValue,
					Count:          uint8(fusion.info.count),
				},
			}
		}
	}

	return analysis, nil
}

// ========================
// Utility Functions
// ========================

// OpcodeName returns the name of an opcode value
func OpcodeName(opcodeValue uint8) string {
	name := C.evm_bytecode_opcode_name(C.uint8_t(opcodeValue))
	return C.GoString(name)
}

// OpcodeInfo represents opcode metadata
type OpcodeInfoType struct {
	GasCost      uint16 `json:"gas_cost"`
	StackInputs  uint8  `json:"stack_inputs"`
	StackOutputs uint8  `json:"stack_outputs"`
}

// OpcodeInfo returns opcode information for a given opcode value
func OpcodeInfo(opcodeValue uint8) OpcodeInfoType {
	cInfo := C.evm_bytecode_opcode_info(C.uint8_t(opcodeValue))
	return OpcodeInfoType{
		GasCost:      uint16(cInfo.gas_cost),
		StackInputs:  uint8(cInfo.stack_inputs),
		StackOutputs: uint8(cInfo.stack_outputs),
	}
}
