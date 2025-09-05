package app

import (
	"guillotine-cli/internal/types"

	tea "github.com/charmbracelet/bubbletea"
)

func (m Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height
		// Update table dimensions
		tableHeight := m.height - 10 // Leave room for header and help
		if tableHeight < 5 {
			tableHeight = 5
		}
		m.historyTable.SetHeight(tableHeight)
		m.contractsTable.SetHeight(tableHeight)
		return m, nil
		
	case callResultMsg:
		m.callResult = msg.result
		m.state = types.StateCallResult
		return m, nil

	case resetCompleteMsg:
		m.state = types.StateMainMenu
		return m, nil

	case tea.KeyMsg:
		// Delegate all keyboard handling to state_transitions.go
		return m.handleStateNavigation(msg)
	}

	return m, nil
}