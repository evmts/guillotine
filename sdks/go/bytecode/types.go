// Package bytecode provides bytecode analysis and statistics functionality.
//
// This file contains the single source of truth for all bytecode-related types:
//   - Bytecode statistics and metadata structures
//   - Control flow analysis (basic blocks, jump patterns)
//   - Fusion optimization detection types
//   - Comprehensive bytecode analysis results
package bytecode

import (
	"math/big"
)

// ========================
// Control Flow Analysis Types
// ========================

// BasicBlock represents a basic block in the control flow graph
type BasicBlock struct {
	Start uint32 // Starting program counter
	End   uint32 // Ending program counter (inclusive)
}

// JumpFusion represents a jump fusion optimization
// This occurs when a jump target can be statically determined
type JumpFusion struct {
	SourcePC uint32 // Program counter of the jump instruction
	TargetPC uint32 // Target program counter
}

// ========================
// Fusion Optimization Types
// ========================

// FusionType represents the type of bytecode fusion optimization
type FusionType uint8

const (
	// FusionConstantFold indicates constant folding optimization
	// Example: PUSH1 2 PUSH1 3 ADD -> PUSH1 5
	FusionConstantFold FusionType = 0
	
	// FusionMultiPush indicates multiple consecutive PUSH operations
	// Can be optimized into a single compound operation
	FusionMultiPush FusionType = 1
	
	// FusionMultiPop indicates multiple consecutive POP operations
	// Can be optimized into a single stack adjustment
	FusionMultiPop FusionType = 2
	
	// FusionIszeroJumpi indicates ISZERO followed by JUMPI pattern
	// Common pattern that can be optimized
	FusionIszeroJumpi FusionType = 3
	
	// FusionDup2MstorePush indicates DUP2 MSTORE PUSH pattern
	// Memory operation pattern that can be optimized
	FusionDup2MstorePush FusionType = 4
)

// FusionInfo contains detailed information about a bytecode fusion
type FusionInfo struct {
	Type           FusionType // Type of fusion detected
	OriginalLength uint32     // Original bytecode length before fusion
	FoldedValue    *big.Int   // Folded constant value (for constant folding)
	Count          uint8      // Number of operations fused
}

// AdvancedFusion represents an advanced fusion pattern detection
type AdvancedFusion struct {
	PC   uint32     // Program counter where fusion starts
	Info FusionInfo // Detailed fusion information
}

// ========================
// Comprehensive Analysis Result
// ========================

// Analysis contains comprehensive bytecode analysis results
type Analysis struct {
	// Program counter arrays
	PushPCs   []uint32 // Program counters of all PUSH instructions
	JumpDests []uint32 // Program counters of all JUMPDEST instructions
	
	// Control flow analysis
	BasicBlocks []BasicBlock // Basic blocks in the control flow graph
	JumpFusions []JumpFusion // Detected jump fusion optimizations
	
	// Advanced optimizations
	AdvancedFusions []AdvancedFusion // Detected advanced fusion patterns
}

// String returns a string representation of FusionType
func (ft FusionType) String() string {
	switch ft {
	case FusionConstantFold:
		return "constant_fold"
	case FusionMultiPush:
		return "multi_push"
	case FusionMultiPop:
		return "multi_pop"
	case FusionIszeroJumpi:
		return "iszero_jumpi"
	case FusionDup2MstorePush:
		return "dup2_mstore_push"
	default:
		return "unknown"
	}
}