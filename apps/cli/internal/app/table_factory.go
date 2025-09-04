package app

import (
	"fmt"
	"guillotine-cli/internal/config"
	"strconv"

	"github.com/charmbracelet/bubbles/table"
	"github.com/charmbracelet/lipgloss"
)

// createHistoryTable creates a new styled table for history display
func createHistoryTable() table.Model {
	columns := []table.Column{
		{Title: "Time", Width: 15},
		{Title: "Type", Width: 12},
		{Title: "From", Width: 20},
		{Title: "To", Width: 20},
		{Title: "Status", Width: 10},
		{Title: "Gas", Width: 10},
	}

	return createStyledTable(columns, config.DefaultTableHeight)
}

// createContractsTable creates a new styled table for contracts display
func createContractsTable() table.Model {
	columns := []table.Column{
		{Title: "Address", Width: 42},
		{Title: "Deployed", Width: 20},
	}

	return createStyledTable(columns, config.DefaultTableHeight)
}

// createStyledTable creates a table with common styling
func createStyledTable(columns []table.Column, height int) table.Model {
	t := table.New(
		table.WithColumns(columns),
		table.WithRows([]table.Row{}),
		table.WithFocused(true),
		table.WithHeight(height),
		table.WithKeyMap(table.DefaultKeyMap()),
	)

	s := table.DefaultStyles()
	s.Header = s.Header.
		BorderStyle(lipgloss.NormalBorder()).
		BorderForeground(config.Muted).
		BorderBottom(true).
		Foreground(config.Amber).
		Bold(true)
	s.Selected = s.Selected.
		Foreground(config.Background).
		Background(config.Amber).
		Bold(false)

	t.SetStyles(s)
	return t
}

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
			entry.Timestamp.Format("15:04:05"),
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