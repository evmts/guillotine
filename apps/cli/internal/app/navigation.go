package app

import (
	"guillotine-cli/internal/config"
	"guillotine-cli/internal/core/bytecode"
	"guillotine-cli/internal/core/utils"
	"guillotine-cli/internal/types"
	"guillotine-cli/internal/ui"

	tea "github.com/charmbracelet/bubbletea"
)

// handleStateNavigation handles state-based navigation for keyboard input
func (m *Model) handleStateNavigation(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	msgStr := msg.String()
	
	// Handle quit
	if config.IsKey(msgStr, config.KeyQuit) {
		m.quitting = true
		return m, tea.Batch(tea.ExitAltScreen, tea.Quit)
	}
	
	// Handle clipboard shortcuts
	if config.IsKey(msgStr, config.KeyCopy) {
		return m.handleCopy()
	}
	
	// Handle navigation keys based on current state
	switch m.state {
	case types.StateMainMenu:
		return m.handleMainMenuNavigation(msgStr)
		
	case types.StateCallParameterList:
		return m.handleCallParamListNavigation(msgStr)
		
	case types.StateCallParameterEdit:
		return m.handleCallParamEditNavigation(msgStr, msg)
		
	case types.StateCallTypeEdit:
		return m.handleCallTypeEditNavigation(msgStr)
		
	case types.StateCallResult:
		return m.handleCallResultNavigation(msgStr, msg)
		
	case types.StateCallHistory:
		return m.handleCallHistoryNavigation(msgStr, msg)
		
	case types.StateCallHistoryDetail:
		return m.handleHistoryDetailNavigation(msgStr, msg)
		
	case types.StateLogDetail:
		return m.handleLogDetailNavigation(msgStr)
		
	case types.StateContracts:
		return m.handleContractsNavigation(msgStr, msg)
		
	case types.StateContractDetail:
		return m.handleContractDetailNavigation(msgStr, msg)
		
	case types.StateConfirmReset:
		return m.handleConfirmResetNavigation(msgStr)
	}
	
	return m, nil
}

// handleMainMenuNavigation handles navigation in main menu state
func (m *Model) handleMainMenuNavigation(msgStr string) (tea.Model, tea.Cmd) {
	if config.IsKey(msgStr, config.KeyUp) {
		if m.cursor > 0 {
			m.cursor--
		}
	} else if config.IsKey(msgStr, config.KeyDown) {
		if m.cursor < len(m.choices)-1 {
			m.cursor++
		}
	} else if config.IsKey(msgStr, config.KeySelect) {
		return m.handleMainMenuSelect()
	}
	return m, nil
}

// handleCallParamListNavigation handles navigation in call parameter list state
func (m *Model) handleCallParamListNavigation(msgStr string) (tea.Model, tea.Cmd) {
	if config.IsKey(msgStr, config.KeyUp) {
		if m.callParamCursor > 0 {
			m.callParamCursor--
		}
	} else if config.IsKey(msgStr, config.KeyDown) {
		params := GetCallParams(m.callParams)
		if m.callParamCursor < len(params)-1 {
			m.callParamCursor++
		}
	} else if config.IsKey(msgStr, config.KeySelect) {
		m.validationError = "" // Clear validation errors when navigating to edit
		return m.handleCallParamSelect()
	} else if config.IsKey(msgStr, config.KeyBack) {
		m.state = types.StateMainMenu
		return m, nil
	} else if config.IsKey(msgStr, config.KeyExecute) {
		return m.handleCallExecute()
	} else if config.IsKey(msgStr, config.KeyReset) {
		return m.handleResetParameter()
	} else if config.IsKey(msgStr, config.KeyResetAll) {
		return m.handleResetAllParameters()
	}
	return m, nil
}

// handleCallParamEditNavigation handles navigation in call parameter edit state
func (m *Model) handleCallParamEditNavigation(msgStr string, msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	// Handle paste specially to get clipboard content
	if config.IsKey(msgStr, config.KeyPaste) {
		if m.editingParam != config.CallParamCallType {
			if content, err := ui.GetClipboard(); err == nil {
				// Clean multi-line content for single-line input
				cleanedContent := utils.CleanMultilineForInput(content)
				m.textInput.SetValue(cleanedContent)
				// IMPORTANT: Also update the cursor position to the end
				m.textInput.CursorEnd()
			}
		}
		return m, nil
	}
	
	if config.IsKey(msgStr, config.KeySelect) {
		return m.handleCallEditSave()
	} else if config.IsKey(msgStr, config.KeyBack) {
		m.state = types.StateCallParameterList
		return m, nil
	} else if config.IsKey(msgStr, config.KeyReset) {
		return m.handleResetCurrentParameter()
	} else {
		// Pass all other keys to text input
		var cmd tea.Cmd
		m.textInput, cmd = m.textInput.Update(msg)
		return m, cmd
	}
}

// handleCallTypeEditNavigation handles navigation in call type edit state
func (m *Model) handleCallTypeEditNavigation(msgStr string) (tea.Model, tea.Cmd) {
	if config.IsKey(msgStr, config.KeyUp) {
		if m.callTypeSelector > 0 {
			m.callTypeSelector--
		}
	} else if config.IsKey(msgStr, config.KeyDown) {
		options := types.GetCallTypeOptions()
		if m.callTypeSelector < len(options)-1 {
			m.callTypeSelector++
		}
	} else if config.IsKey(msgStr, config.KeySelect) {
		return m.handleCallEditSave()
	} else if config.IsKey(msgStr, config.KeyBack) {
		m.state = types.StateCallParameterList
		return m, nil
	} else if config.IsKey(msgStr, config.KeyReset) {
		return m.handleResetCurrentParameter()
	}
	return m, nil
}

// handleCallResultNavigation handles navigation in call result state
func (m *Model) handleCallResultNavigation(msgStr string, msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	hasLogs := m.callResult != nil && len(m.callResult.Logs) > 0
	
	if hasLogs {
		// Direct log navigation - no activation needed
		if config.IsKey(msgStr, config.KeySelect) {
			if m.logsTable.Cursor() < len(m.callResult.Logs) {
				m.selectedLogIndex = m.logsTable.Cursor()
				m.state = types.StateLogDetail
				return m, nil
			}
		}
		
		// Let table handle navigation
		if config.IsKey(msgStr, config.KeyUp) || config.IsKey(msgStr, config.KeyDown) {
			var cmd tea.Cmd
			m.logsTable, cmd = m.logsTable.Update(msg)
			return m, cmd
		}
	}
	
	// Non-log navigation (only back is allowed)
	if config.IsKey(msgStr, config.KeyBack) {
		m.state = types.StateCallParameterList
		return m, nil
	}
	
	return m, nil
}

// handleCallHistoryNavigation handles navigation in call history state
func (m *Model) handleCallHistoryNavigation(msgStr string, msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	if config.IsKey(msgStr, config.KeySelect) {
		history := m.historyManager.GetAllCalls()
		selectedRow := m.historyTable.SelectedRow()
		if len(selectedRow) > 0 && m.historyTable.Cursor() < len(history) {
			m.selectedHistoryID = history[m.historyTable.Cursor()].ID
			m.state = types.StateCallHistoryDetail
			
			// Populate logs table for the history entry
			entry := &history[m.historyTable.Cursor()]
			if entry.Result != nil && len(entry.Result.Logs) > 0 {
				rows := ui.ConvertLogsToRows(entry.Result.Logs)
				m.logsTable.SetRows(rows)
			}
		}
		return m, nil
	} else if config.IsKey(msgStr, config.KeyBack) {
		m.state = types.StateMainMenu
		return m, nil
	} else {
		// Let table handle navigation
		var cmd tea.Cmd
		m.historyTable, cmd = m.historyTable.Update(msg)
		return m, cmd
	}
}

// handleHistoryDetailNavigation handles navigation in history detail state
func (m *Model) handleHistoryDetailNavigation(msgStr string, msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	// Get the selected history entry to check for logs
	entry := m.historyManager.GetCall(m.selectedHistoryID)
	hasLogs := entry != nil && entry.Result != nil && len(entry.Result.Logs) > 0
	
	if hasLogs {
		// Direct log navigation - no activation needed
		if config.IsKey(msgStr, config.KeySelect) {
			if m.logsTable.Cursor() < len(entry.Result.Logs) {
				m.selectedLogIndex = m.logsTable.Cursor()
				m.state = types.StateLogDetail
				return m, nil
			}
		}
		
		// Let table handle navigation
		if config.IsKey(msgStr, config.KeyUp) || config.IsKey(msgStr, config.KeyDown) {
			var cmd tea.Cmd
			m.logsTable, cmd = m.logsTable.Update(msg)
			return m, cmd
		}
	}
	
	if config.IsKey(msgStr, config.KeyBack) {
		m.state = types.StateCallHistory
		m.updateHistoryTable()
		return m, nil
	}
	
	return m, nil
}

// handleContractsNavigation handles navigation in contracts state
func (m *Model) handleContractsNavigation(msgStr string, msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	if config.IsKey(msgStr, config.KeySelect) {
		contracts := m.historyManager.GetContracts()
		selectedRow := m.contractsTable.SelectedRow()
		if len(selectedRow) > 0 && m.contractsTable.Cursor() < len(contracts) {
			m.selectedContract = contracts[m.contractsTable.Cursor()].Address
			m.state = types.StateContractDetail
			// Load disassembly for the selected contract
			contract := m.historyManager.GetContract(m.selectedContract)
			if contract != nil && len(contract.Bytecode) > 0 {
				return m, m.loadDisassemblyCmd(contract.Bytecode)
			}
		}
		return m, nil
	} else if config.IsKey(msgStr, config.KeyBack) {
		m.state = types.StateMainMenu
		return m, nil
	} else {
		// Let table handle navigation
		var cmd tea.Cmd
		m.contractsTable, cmd = m.contractsTable.Update(msg)
		return m, cmd
	}
}

// handleContractDetailNavigation handles navigation in contract detail state
func (m *Model) handleContractDetailNavigation(msgStr string, msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	// Handle disassembly navigation if available
	if m.disassemblyResult != nil {
		// Jump to destination when 'g' is pressed on a jump instruction
		if config.IsKey(msgStr, config.KeyJumpToDestination) {
			m.handleJumpToDestination()
			return m, nil
		}
		
		// Left/Right to navigate between blocks
		if config.IsKey(msgStr, config.KeyLeft) {
			if m.currentBlockIndex > 0 {
				m.currentBlockIndex--
				// Update table with new block's instructions
				m.updateInstructionsTable()
			}
		} else if config.IsKey(msgStr, config.KeyRight) {
			if m.currentBlockIndex < len(m.disassemblyResult.Analysis.BasicBlocks)-1 {
				m.currentBlockIndex++
				// Update table with new block's instructions
				m.updateInstructionsTable()
			}
		}
		
		// Up/Down handled by the table component
		if config.IsKey(msgStr, config.KeyUp) || config.IsKey(msgStr, config.KeyDown) {
			var cmd tea.Cmd
			m.instructionsTable, cmd = m.instructionsTable.Update(msg)
			return m, cmd
		}
	}
	
	if config.IsKey(msgStr, config.KeyBack) {
		m.state = types.StateContracts
		m.disassemblyResult = nil  // Clear disassembly when going back
		m.disassemblyError = nil   // Clear error state
		m.currentBlockIndex = 0     // Reset block index
		m.updateContractsTable()
		return m, nil
	}
	return m, nil
}

// updateInstructionsTable updates the instructions table with current block data
func (m *Model) updateInstructionsTable() {
	if m.disassemblyResult == nil {
		return
	}
	
	instructions, _, err := bytecode.GetInstructionsForBlock(m.disassemblyResult, m.currentBlockIndex)
	if err != nil {
		// Handle error case - could log or show error state
		return
	}
	
	if len(instructions) > 0 {
		rows := ui.ConvertInstructionsToRows(instructions, m.disassemblyResult.Analysis.JumpDests)
		m.instructionsTable.SetRows(rows)
		// Reset cursor to top when changing blocks
		m.instructionsTable.SetCursor(0)
	}
}

// handleConfirmResetNavigation handles navigation in confirm reset state
func (m *Model) handleConfirmResetNavigation(msgStr string) (tea.Model, tea.Cmd) {
	if config.IsKey(msgStr, config.KeySelect) {
		return m, m.executeReset()
	} else if config.IsKey(msgStr, config.KeyBack) {
		m.state = types.StateMainMenu
		return m, nil
	}
	return m, nil
}

// handleLogDetailNavigation handles navigation in log detail state
func (m *Model) handleLogDetailNavigation(msgStr string) (tea.Model, tea.Cmd) {
	if config.IsKey(msgStr, config.KeyBack) {
		// Return to previous state
		if m.state == types.StateLogDetail {
			// Determine which state to return to based on context
			if m.selectedHistoryID != "" {
				m.state = types.StateCallHistoryDetail
			} else {
				m.state = types.StateCallResult
			}
		}
		return m, nil
	}
	return m, nil
}

// handleJumpToDestination navigates to the jump destination of the currently selected instruction
func (m *Model) handleJumpToDestination() {
	if m.disassemblyResult == nil {
		return
	}
	
	// Get current block's instructions
	instructions, _, err := bytecode.GetInstructionsForBlock(m.disassemblyResult, m.currentBlockIndex)
	if err != nil {
		return
	}
	
	// Get the cursor position in the table
	cursorPos := m.instructionsTable.Cursor()
	if cursorPos < 0 || cursorPos >= len(instructions) {
		return
	}
	
	// Check if current instruction is a jump and get its destination
	jumpDest := bytecode.GetJumpDestination(instructions, cursorPos)
	if jumpDest == nil {
		return
	}
	
	// Find which block contains the jump destination
	targetBlockIndex := bytecode.FindBlockContainingPC(m.disassemblyResult.Analysis, *jumpDest)
	if targetBlockIndex == -1 {
		return
	}
	
	// Navigate to the target block
	m.currentBlockIndex = targetBlockIndex
	m.updateInstructionsTable()
	
	// Try to position the cursor at the jump destination instruction
	targetInstructions, _, _ := bytecode.GetInstructionsForBlock(m.disassemblyResult, targetBlockIndex)
	if targetInstructions != nil {
		targetInstIndex := bytecode.FindInstructionIndexByPC(targetInstructions, *jumpDest)
		if targetInstIndex >= 0 {
			m.instructionsTable.SetCursor(targetInstIndex)
		}
	}
}
