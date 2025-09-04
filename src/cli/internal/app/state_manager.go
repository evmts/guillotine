package app

import (
	"fmt"
	"time"

	"guillotine-cli/internal/persistence"
	"guillotine-cli/internal/types"
	"github.com/evmts/guillotine/bindings/go/evm"
	"github.com/google/uuid"
)

type StateManager struct {
	vmManager      *VMManager
	historyManager *HistoryManager
}

func NewStateManager(vmMgr *VMManager, historyMgr *HistoryManager) *StateManager {
	return &StateManager{
		vmManager:      vmMgr,
		historyManager: historyMgr,
	}
}

func (sm *StateManager) ReplayState(calls []persistence.PersistedCall) error {
	for i, call := range calls {
		if err := sm.replayCall(call, i); err != nil {
			fmt.Printf("Warning: Failed to replay call %d: %v\n", i, err)
			continue
		}
	}
	return nil
}

func (sm *StateManager) replayCall(call persistence.PersistedCall, index int) error {
	params := persistence.ConvertToCallParameters(call)
	
	result, err := ExecuteCall(sm.vmManager, params)
	if err != nil {
		result = &evm.CallResult{
			Success:   false,
			ErrorInfo: err.Error(),
			GasLeft:   0,
		}
	}
	
	entry := types.CallHistoryEntry{
		ID:         uuid.New().String(),
		Timestamp:  time.Unix(call.Timestamp, 0),
		Parameters: params,
		Result:     result,
	}
	
	sm.historyManager.AddCall(entry)
	
	return nil
}