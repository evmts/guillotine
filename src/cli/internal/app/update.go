package app

import (
	"guillotine-cli/internal/config"
	"guillotine-cli/internal/core/evm"
	"guillotine-cli/internal/types"
	"time"

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
		
		// If this was a successful CREATE or CREATE2, add the deployed contract
		if msg.result != nil && msg.result.Success {
			if msg.params.CallType == config.CallTypeCreate || msg.params.CallType == config.CallTypeCreate2 {
				converter := evm.NewTypeConverter()
				address, err := converter.ConvertAddressFromOutput(msg.result.Output)
				if err == nil {
					// Get deployed bytecode from the VM
					bytecode, err := m.vmManager.GetCode(address)
					if err == nil {
						m.historyManager.AddContractWithBytecode(address, bytecode, time.Now())
					} else {
						// Fallback: add contract without bytecode
						m.historyManager.AddContract(address, time.Now())
					}
				}
			}
		}
		
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