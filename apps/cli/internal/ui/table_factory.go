package ui

import (
	"guillotine-cli/internal/config"

	"github.com/charmbracelet/bubbles/table"
	"github.com/charmbracelet/lipgloss"
)

// CreateHistoryTable creates a new styled table for history display
func CreateHistoryTable() table.Model {
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

// CreateContractsTable creates a new styled table for contracts display
func CreateContractsTable() table.Model {
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
