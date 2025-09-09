package app

import (
	"guillotine-cli/internal/core/bytecode"
	"guillotine-cli/internal/types"
	"guillotine-cli/internal/ui"

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
		
		// Populate logs table if there are logs
		if msg.result != nil && len(msg.result.Logs) > 0 {
			rows := ui.ConvertLogsToRows(msg.result.Logs)
			m.logsTable.SetRows(rows)
		}
		
		return m, nil

	case resetCompleteMsg:
		m.state = types.StateMainMenu
		return m, nil

	case disassemblyResultMsg:
		if msg.error != nil {
			// Store error message for display
			m.disassemblyResult = nil
			m.disassemblyError = msg.error
		} else {
			m.disassemblyError = nil
			m.disassemblyResult = msg.result
			m.currentBlockIndex = 0
			
			// Initialize the instructions table with the first block's instructions
			if m.disassemblyResult != nil {
				// Calculate available height for disassembly area
				headerHeight := 4 // Header height
				helpHeight := 3   // Help height
				boxPadding := 4   // Box padding
				availableHeight := m.height - headerHeight - helpHeight - boxPadding
				
				// Account for: title (1), stats box (4), spacing (2), block indicator (2), box borders (2)
				tableHeight := availableHeight - 11
				tableHeight = max(8, tableHeight)  // Use more space, minimum 8 lines
				m.instructionsTable = ui.CreateInstructionsTable(tableHeight)
				
				// Load instructions for the first block
				instructions, _, err := bytecode.GetInstructionsForBlock(m.disassemblyResult, m.currentBlockIndex)
				if err == nil && len(instructions) > 0 {
					rows := ui.ConvertInstructionsToRows(instructions, m.disassemblyResult.Analysis.JumpDests)
					m.instructionsTable.SetRows(rows)
				}
			}
		}
		return m, nil

	case tea.KeyMsg:
		// Delegate all keyboard handling to state_transitions.go
		return m.handleStateNavigation(msg)
	}

	return m, nil
}