package state

import (
	"fmt"
	"time"

	"guillotine-cli/internal/core/evm"
	"guillotine-cli/internal/core/history"
	"guillotine-cli/internal/types"

	guillotine "github.com/evmts/guillotine/sdks/go"
	"github.com/google/uuid"
)

type StateReplayer struct {
	vmManager      *evm.VMManager
	historyManager *history.HistoryManager
}

func NewStateReplayer(vmMgr *evm.VMManager, historyMgr *history.HistoryManager) *StateReplayer {
	return &StateReplayer{
		vmManager:      vmMgr,
		historyManager: historyMgr,
	}
}

func (sm *StateReplayer) ReplayState(calls []PersistedCall) error {
	for i, call := range calls {
		if err := sm.replayCall(call, i); err != nil {
			fmt.Printf("Warning: Failed to replay call %d: %v\n", i, err)
			continue
		}
	}
	return nil
}

func (sm *StateReplayer) replayCall(call PersistedCall, index int) error {
	params := ConvertToCallParameters(call)
	
	result, err := evm.ExecuteCall(sm.vmManager, params)
	if err != nil {
		result = &guillotine.CallResult{
			Success:   false,
			ErrorInfo: err.Error(),
			GasLeft:   0,
		}
	}
	
	// Use the saved timestamp from the persisted call
	savedTime := time.Unix(call.Timestamp, 0)
	
	entry := types.CallHistoryEntry{
		ID:         uuid.New().String(),
		Timestamp:  savedTime,
		Parameters: params,
		Result:     result,
	}
	
	sm.historyManager.AddCall(entry)
	
	return nil
}