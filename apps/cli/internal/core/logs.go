package logs

import (
	"guillotine-cli/internal/types"

	guillotine "github.com/evmts/guillotine/sdks/go"
)

// GetSelectedLog returns the log entry for the given context
func GetSelectedLog(callResult *guillotine.CallResult, selectedHistoryEntry *types.CallHistoryEntry, logIndex int) *guillotine.LogEntry {
	var logs []guillotine.LogEntry
	
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
func HasLogs(result *guillotine.CallResult) bool {
	return result != nil && len(result.Logs) > 0
}

// HasHistoryLogs checks if the given history entry has any logs
func HasHistoryLogs(entry *types.CallHistoryEntry) bool {
	return entry != nil && entry.Result != nil && len(entry.Result.Logs) > 0
}