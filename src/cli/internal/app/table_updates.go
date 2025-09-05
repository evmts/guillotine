package app

import (
	"fmt"
	"strconv"

	"github.com/charmbracelet/bubbles/table"
)

// updateHistoryTable updates the history table with current data
func (m *Model) updateHistoryTable() {
	history := m.historyManager.GetAllCalls()
	rows := []table.Row{}
	
	for _, entry := range history {
		status := "✓"
		if entry.Result == nil || !entry.Result.Success {
			status = "✗"
		}
		
		gasUsed := "0"
		if entry.Result != nil {
			if gasLimit, err := strconv.ParseUint(entry.Parameters.GasLimit, 10, 64); err == nil {
				gasUsedVal := gasLimit - entry.Result.GasLeft
				gasUsed = fmt.Sprintf("%d", gasUsedVal)
			}
		}
		
		// Safely truncate addresses
		caller := entry.Parameters.Caller
		if len(caller) > 10 {
			caller = caller[:10] + "..."
		}
		target := entry.Parameters.Target
		if len(target) > 10 {
			target = target[:10] + "..."
		}
		
		rows = append(rows, table.Row{
			entry.Timestamp.Format("15:04:05 01/02"),
			entry.Parameters.CallType,
			caller,
			target,
			status,
			gasUsed,
		})
	}
	
	m.historyTable.SetRows(rows)
	if len(rows) > 0 {
		m.historyTable.SetCursor(0)
	}
}

// updateContractsTable updates the contracts table with current data
func (m *Model) updateContractsTable() {
	contracts := m.historyManager.GetContracts()
	rows := []table.Row{}
	
	for _, contract := range contracts {
		rows = append(rows, table.Row{
			contract.Address,
			contract.Timestamp.Format("15:04:05 01/02"),
		})
	}
	
	m.contractsTable.SetRows(rows)
	if len(rows) > 0 {
		m.contractsTable.SetCursor(0)
	}
}