package history

import (
	"guillotine-cli/internal/types"
	"time"
)

// CreateDeployedContract creates a new deployed contract entry
func CreateDeployedContract(address string, bytecode []byte, timestamp time.Time) *types.DeployedContract {
	return &types.DeployedContract{
		Address:   address,
		Bytecode:  bytecode,
		Timestamp: timestamp,
	}
}