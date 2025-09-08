// Package guillotine provides the core FFI layer for Guillotine EVM.
//
// This file contains the single source of truth for all public API types:
//    - Complete support for all EVM call types (CALL, DELEGATECALL, CREATE, CREATE2, etc.)
//    - Comprehensive execution results including logs, selfdestructs, accessed addresses/storage
//    - Direct mapping to Zig CallParams enum and CallResult struct
package guillotine

import (
	"math/big"
	
	"github.com/evmts/guillotine/sdks/go/primitives"
)

// ========================
// Call Types and Parameters
// ========================

// CallType represents the type of EVM call operation
type CallType uint8

const (
	CallTypeCall CallType = iota
	CallTypeCallcode
	CallTypeDelegatecall
	CallTypeStaticcall
	CallTypeCreate
	CallTypeCreate2
)

// CallParams holds complete parameters for EVM execution
// This is the comprehensive parameter structure supporting all call types
type CallParams struct {
	CallType CallType
	Caller   primitives.Address
	To       primitives.Address // Zero for CREATE/CREATE2
	Value    *big.Int          // Zero for DELEGATECALL/STATICCALL
	Input    []byte            // init_code for CREATE/CREATE2
	Gas      uint64
	Salt     *big.Int          // Only used for CREATE2
}

// ========================
// Execution Results
// ========================

// LogEntry represents an EVM event log
type LogEntry struct {
	Address primitives.Address
	Topics  []*big.Int
	Data    []byte
}

// SelfDestructRecord represents a self-destruct operation
type SelfDestructRecord struct {
	Contract    primitives.Address
	Beneficiary primitives.Address
}

// StorageAccessRecord represents a storage slot access
type StorageAccessRecord struct {
	Address primitives.Address
	Slot    *big.Int
}

// CallResult contains complete execution results
type CallResult struct {
	Success           bool
	GasLeft           uint64
	Output            []byte
	Logs              []LogEntry
	SelfDestructs     []SelfDestructRecord
	AccessedAddresses []primitives.Address
	AccessedStorage   []StorageAccessRecord
	ErrorInfo         string
	CreatedAddress    *primitives.Address // Address of created contract (for CREATE/CREATE2)
}