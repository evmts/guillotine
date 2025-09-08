package history

import (
	"sync"
	"time"

	"guillotine-cli/internal/config"
	"guillotine-cli/internal/types"

	"github.com/google/uuid"
)

type HistoryManager struct {
	mu             sync.RWMutex
	calls          []types.CallHistoryEntry
	contracts      map[string]*types.DeployedContract
	callIndex      map[string]*types.CallHistoryEntry
	maxEntries     int
	rotationPolicy RotationPolicy
}

func NewHistoryManager(maxEntries int) *HistoryManager {
	return &HistoryManager{
		calls:          make([]types.CallHistoryEntry, 0, maxEntries),
		contracts:      make(map[string]*types.DeployedContract),
		callIndex:      make(map[string]*types.CallHistoryEntry),
		maxEntries:     maxEntries,
		rotationPolicy: KeepLast100,
	}
}

func (h *HistoryManager) AddCall(entry types.CallHistoryEntry) {
	h.mu.Lock()
	defer h.mu.Unlock()

	if entry.ID == "" {
		entry.ID = uuid.New().String()
	}
	if entry.Timestamp.IsZero() {
		entry.Timestamp = time.Now()
	}

	if len(h.calls) >= h.maxEntries && h.rotationPolicy != KeepAll {
		removed := h.calls[0]
		delete(h.callIndex, removed.ID)
		h.calls = h.calls[1:]
	}

	h.calls = append(h.calls, entry)
	h.callIndex[entry.ID] = &h.calls[len(h.calls)-1]

	// Track deployed contracts for successful CREATE/CREATE2 operations
	if entry.Parameters.CallType == config.CallTypeCreate || entry.Parameters.CallType == config.CallTypeCreate2 {
		if entry.Result != nil && entry.Result.Success && entry.Result.CreatedAddress != nil {
			// Get the created contract address
			address := entry.Result.CreatedAddress.Hex()
			
			// The output field contains the deployed bytecode for successful CREATE/CREATE2
			bytecode := entry.Result.Output
			
			// Store the deployed contract with the same timestamp as the CREATE call
			contract := &types.DeployedContract{
				Address:   address,
				Bytecode:  bytecode,
				Timestamp: entry.Timestamp,
			}
			
			
			h.contracts[address] = contract
		}
	}
}

func (h *HistoryManager) GetCallsPaginated(page, pageSize int) ([]types.CallHistoryEntry, int) {
	h.mu.RLock()
	defer h.mu.RUnlock()

	start := page * pageSize
	end := min(start+pageSize, len(h.calls))

	if start >= len(h.calls) {
		return nil, len(h.calls)
	}

	result := make([]types.CallHistoryEntry, end-start)
	for i := range result {
		result[i] = h.calls[len(h.calls)-1-start-i]
	}

	return result, len(h.calls)
}

func (h *HistoryManager) GetAllCalls() []types.CallHistoryEntry {
	h.mu.RLock()
	defer h.mu.RUnlock()

	result := make([]types.CallHistoryEntry, len(h.calls))
	for i := range result {
		result[i] = h.calls[len(h.calls)-1-i]
	}
	return result
}

func (h *HistoryManager) GetCall(id string) *types.CallHistoryEntry {
	h.mu.RLock()
	defer h.mu.RUnlock()

	if entry, ok := h.callIndex[id]; ok {
		copy := *entry
		return &copy
	}
	return nil
}

func (h *HistoryManager) GetContracts() []*types.DeployedContract {
	h.mu.RLock()
	defer h.mu.RUnlock()

	result := make([]*types.DeployedContract, 0, len(h.contracts))
	for _, contract := range h.contracts {
		result = append(result, contract)
	}
	
	// Sort by timestamp, most recent first
	for i := 0; i < len(result)-1; i++ {
		for j := i + 1; j < len(result); j++ {
			if result[i].Timestamp.Before(result[j].Timestamp) {
				result[i], result[j] = result[j], result[i]
			}
		}
	}
	
	return result
}

func (h *HistoryManager) GetContract(address string) *types.DeployedContract {
	h.mu.RLock()
	defer h.mu.RUnlock()

	return h.contracts[address]
}

func (h *HistoryManager) Clear() {
	h.mu.Lock()
	defer h.mu.Unlock()

	h.calls = make([]types.CallHistoryEntry, 0, h.maxEntries)
	h.callIndex = make(map[string]*types.CallHistoryEntry)
	h.contracts = make(map[string]*types.DeployedContract)
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}