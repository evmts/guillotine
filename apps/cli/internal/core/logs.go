package logs

import (
	gevmTypes "github.com/evmts/guillotine/bindings/go/evm"
	"guillotine-cli/internal/types"
)

// GetSelectedLog returns the log entry for the given context
func GetSelectedLog(callResult *gevmTypes.CallResult, selectedHistoryEntry *types.CallHistoryEntry, logIndex int) *gevmTypes.LogEntry {
	var logs []gevmTypes.LogEntry
	
	// Determine source of logs
	if selectedHistoryEntry != nil && selectedHistoryEntry.Result != nil {
		logs = selectedHistoryEntry.Result.Logs
	} else if callResult != nil {
		logs = callResult.Logs
	}
	
	// Validate index and return log
	if logIndex >= 0 && logIndex < len(logs) {
		return &logs[logIndex]
	}
	
	return nil
}

// HasLogs checks if the given result has any logs
func HasLogs(result *gevmTypes.CallResult) bool {
	return result != nil && len(result.Logs) > 0
}

// HasHistoryLogs checks if the given history entry has any logs
func HasHistoryLogs(entry *types.CallHistoryEntry) bool {
	return entry != nil && entry.Result != nil && len(entry.Result.Logs) > 0
}