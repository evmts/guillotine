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
	"fmt"
	"unsafe"
	"errors"
	"math/big"
	"runtime"
	"sync"
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
	ErrNullPointer      = errors.New("null pointer")
	ErrInvalidBytecode  = errors.New("invalid bytecode")
	ErrOutOfMemory      = errors.New("out of memory")
	ErrBytecodeTooLarge = errors.New("bytecode too large")
	ErrInvalidOpcode    = errors.New("invalid opcode")
	ErrOutOfBounds      = errors.New("out of bounds")
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

// FullLength returns the full bytecode length (includes metadata if present)
func (b *Bytecode) FullLength() (uint64, error) {
	b.mu.RLock()
	defer b.mu.RUnlock()
	
	if b.ptr == nil {
		return 0, ErrBytecodeDestroyed
	}
	
	return uint64(C.evm_bytecode_get_full_length(b.ptr)), nil
}

// Data returns a copy of the full bytecode data
func (b *Bytecode) Data() ([]byte, error) {
	b.mu.RLock()
	defer b.mu.RUnlock()
	
	if b.ptr == nil {
		return nil, ErrBytecodeDestroyed
	}
	
	length := C.evm_bytecode_get_full_length(b.ptr)
	if length == 0 {
		return []byte{}, nil
	}
	
	buffer := make([]byte, length)
	copied := C.evm_bytecode_get_data(b.ptr, (*C.uint8_t)(unsafe.Pointer(&buffer[0])), length)
	if copied != length {
		return nil, fmt.Errorf("failed to copy bytecode data: expected %d, got %d", length, copied)
	}
	
	return buffer, nil
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

// IsJumpDest checks if the position is a valid jump destination
func (b *Bytecode) IsJumpDest(position uint64) (bool, error) {
	b.mu.RLock()
	defer b.mu.RUnlock()
	
	if b.ptr == nil {
		return false, ErrBytecodeDestroyed
	}
	
	result := C.evm_bytecode_is_jump_dest(b.ptr, C.size_t(position))
	return result != 0, nil
}

// FindJumpDests returns all jump destinations in the bytecode
func (b *Bytecode) FindJumpDests() ([]uint32, error) {
	b.mu.RLock()
	defer b.mu.RUnlock()
	
	if b.ptr == nil {
		return nil, ErrBytecodeDestroyed
	}
	
	// First, get the count
	var count C.uint32_t
	maxDests := C.uint32_t(65536) // Max reasonable number of jump dests
	buffer := make([]C.uint32_t, maxDests)
	
	result := C.evm_bytecode_find_jump_dests(b.ptr, &buffer[0], maxDests, &count)
	if result != 0 {
		return nil, fmt.Errorf("failed to find jump destinations: error code %d", result)
	}
	
	// Convert to Go slice
	jumpDests := make([]uint32, count)
	for i := uint32(0); i < uint32(count); i++ {
		jumpDests[i] = uint32(buffer[i])
	}
	
	return jumpDests, nil
}

// CountInvalidOpcodes returns the number of invalid opcodes
func (b *Bytecode) CountInvalidOpcodes() (uint32, error) {
	b.mu.RLock()
	defer b.mu.RUnlock()
	
	if b.ptr == nil {
		return 0, ErrBytecodeDestroyed
	}
	
	return uint32(C.evm_bytecode_count_invalid_opcodes(b.ptr)), nil
}

// ========================
// Metadata
// ========================

// GetMetadata returns the Solidity metadata information
func (b *Bytecode) GetMetadata() (*Metadata, error) {
	b.mu.RLock()
	defer b.mu.RUnlock()
	
	if b.ptr == nil {
		return nil, ErrBytecodeDestroyed
	}
	
	metadata := &Metadata{}
	
	// Check if metadata exists
	hasMetadata := C.evm_bytecode_has_metadata(b.ptr)
	metadata.HasMetadata = hasMetadata != 0
	
	if !metadata.HasMetadata {
		return metadata, nil
	}
	
	// Get metadata length
	metadata.MetadataLength = uint64(C.evm_bytecode_get_metadata_length(b.ptr))
	
	// Get IPFS hash (34 bytes)
	ipfsHash := make([]byte, 34)
	copied := C.evm_bytecode_get_metadata_ipfs(b.ptr, (*C.uint8_t)(unsafe.Pointer(&ipfsHash[0])), 34)
	if copied == 34 {
		metadata.IPFSHash = ipfsHash
	}
	
	// Get Solc version
	var major, minor, patch C.uint8_t
	if C.evm_bytecode_get_metadata_solc_version(b.ptr, &major, &minor, &patch) != 0 {
		metadata.SolcVersion.Major = uint8(major)
		metadata.SolcVersion.Minor = uint8(minor)
		metadata.SolcVersion.Patch = uint8(patch)
	}
	
	return metadata, nil
}

// ========================
// Statistics
// ========================

// GetStats returns comprehensive bytecode statistics
func (b *Bytecode) GetStats() (*Stats, error) {
	b.mu.RLock()
	defer b.mu.RUnlock()
	
	if b.ptr == nil {
		return nil, ErrBytecodeDestroyed
	}
	
	var cStats C.CBytecodeStats
	result := C.evm_bytecode_get_stats(b.ptr, &cStats)
	if result != 0 {
		return nil, fmt.Errorf("failed to get stats: error code %d", result)
	}
	
	return &Stats{
		TotalBytes:             uint64(cStats.total_bytes),
		InstructionCount:       uint32(cStats.instruction_count),
		JumpDestCount:          uint32(cStats.jump_dest_count),
		InvalidOpcodeCount:     uint32(cStats.invalid_opcode_count),
		PushInstructionCount:   uint32(cStats.push_instruction_count),
		JumpInstructionCount:   uint32(cStats.jump_instruction_count),
		CallInstructionCount:   uint32(cStats.call_instruction_count),
		CreateInstructionCount: uint32(cStats.create_instruction_count),
		ComplexityScore:        uint64(cStats.complexity_score),
	}, nil
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