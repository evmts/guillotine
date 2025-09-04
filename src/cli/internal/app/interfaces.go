package app

import (
	"guillotine-cli/internal/persistence"
	"guillotine-cli/internal/types"
	"time"

	"github.com/evmts/guillotine/bindings/go/evm"
	"github.com/evmts/guillotine/bindings/go/primitives"
)

// EVMExecutor defines the interface for EVM operations
type EVMExecutor interface {
	GetVM() (*evm.EVM, error)
	Reset() error
	Close()
	GetCode(address string) ([]byte, error)
	SetBalance(address primitives.Address, value primitives.U256) error
}

// CallHistoryManager defines the interface for managing call history
type CallHistoryManager interface {
	AddCall(entry types.CallHistoryEntry)
	GetCall(id string) *types.CallHistoryEntry
	GetAllCalls() []types.CallHistoryEntry
	Clear()
	GetContracts() []types.DeployedContract
	GetContract(address string) *types.DeployedContract
	AddContract(address string, timestamp time.Time)
	AddContractWithBytecode(address string, bytecode []byte, timestamp time.Time)
}

// StateManagerInterface defines the interface for state management
type StateManagerInterface interface {
	ReplayState(calls []persistence.PersistedCall) error
	SaveState() error
	LoadState() error
	ClearState() error
}