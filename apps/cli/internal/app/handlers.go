package app

import (
	"fmt"
	"guillotine-cli/internal/config"
	"guillotine-cli/internal/core/evm"
	"guillotine-cli/internal/core/state"
	"guillotine-cli/internal/types"
	"guillotine-cli/internal/ui"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	guillotine "github.com/evmts/guillotine/sdks/go"
)

// Message types for tea commands
type resetCompleteMsg struct{}
type callResultMsg struct {
	result *guillotine.CallResult
	params types.CallParametersStrings
}
type copyFeedbackMsg struct {
	message string
}

// handleMainMenuSelect handles menu item selection on the main menu
func (m Model) handleMainMenuSelect() (tea.Model, tea.Cmd) {
	switch m.choices[m.cursor] {
	case config.MenuMakeCall:
		m.state = types.StateCallParameterList
		m.callParamCursor = 0
		return m, nil
	case config.MenuCallHistory:
		m.state = types.StateCallHistory
		m.updateHistoryTable()
		return m, nil
	case config.MenuContracts:
		m.state = types.StateContracts
		m.updateContractsTable()
		return m, nil
	case config.MenuResetState:
		return m.handleResetState()
	case config.MenuExit:
		m.quitting = true
		// Perform cleanup before exiting
		if m.vmManager != nil {
			m.vmManager.Close()
		}
		return m, tea.Batch(tea.ExitAltScreen, tea.Quit)
	default:
		return m, nil
	}
}

// handleCallParamSelect handles selecting a call parameter for editing
func (m Model) handleCallParamSelect() (tea.Model, tea.Cmd) {
	params := GetCallParams(m.callParams)
	if m.callParamCursor >= len(params) {
		return m, nil
	}
	
	param := params[m.callParamCursor]
	m.editingParam = param.Name
	
	if param.Name == config.CallParamCallType {
		// Initialize call type selector with current value
		options := types.GetCallTypeOptions()
		m.callTypeSelector = 0
		for i, opt := range options {
			if opt == param.Value {
				m.callTypeSelector = i
				break
			}
		}
		m.state = types.StateCallTypeEdit
	} else {
		m.textInput = ui.CreateTextInput(param.Name, param.Value)
		m.state = types.StateCallParameterEdit
	}
	
	m.validationError = ""
	
	return m, nil
}

// handleCallEditSave handles saving an edited call parameter
func (m Model) handleCallEditSave() (tea.Model, tea.Cmd) {
	if m.editingParam == config.CallParamCallType {
		// Handle call type selection
		options := types.GetCallTypeOptions()
		if m.callTypeSelector >= 0 && m.callTypeSelector < len(options) {
			selectedType := options[m.callTypeSelector]
			SetCallParam(&m.callParams, m.editingParam, selectedType)
		}
		m.state = types.StateCallParameterList
		return m, nil
	}
	
	// Handle text input fields
	value := m.textInput.Value()
	
	// Field-specific validation
	validator := evm.NewCallValidator()
	if err := validator.ValidateField(m.editingParam, value); err != nil {
		// Use UIError for better user experience in UI context
		if inputErr, ok := err.(types.InputParamError); ok {
			m.validationError = inputErr.UIError()
		} else {
			m.validationError = err.Error()
		}
		return m, nil
	}
	
	SetCallParam(&m.callParams, m.editingParam, value)
	m.state = types.StateCallParameterList
	return m, nil
}

// handleCallExecute handles executing the EVM call
func (m Model) handleCallExecute() (tea.Model, tea.Cmd) {
	validator := evm.NewCallValidator()
	if err := validator.ValidateCallParameters(m.callParams); err != nil {
		m.validationError = err.Error()
		return m, nil
	}
	
	m.state = types.StateCallExecuting
	return m, m.executeCallCmd(m.callParams)
}

// executeCallCmd creates a command to execute an EVM call asynchronously
func (m *Model) executeCallCmd(params types.CallParametersStrings) tea.Cmd {
	return func() tea.Msg {
		result, err := evm.ExecuteCall(m.vmManager, params)
		if err != nil {
			result = &guillotine.CallResult{
				Success:   false,
				ErrorInfo: err.Error(),
				GasLeft:   0,
			}
		}
		
		// Create timestamp once for both persistence and history
		executionTime := time.Now()
		
		// Persist call parameters after execution (non-blocking)
		persistedCall := state.ConvertFromCallParameters(params, executionTime)
		go func() {
			if err := state.AppendCall(state.GetStateFilePath(), persistedCall); err != nil {
				fmt.Printf("Warning: Failed to persist call: %v\n", err)
			}
		}()
		
		entry := types.CallHistoryEntry{
			Parameters: params,
			Result:     result,
			Timestamp:  executionTime,
		}
		m.historyManager.AddCall(entry)
		
		return callResultMsg{result: result, params: params}
	}
}

// resetParameter resets a parameter to its default value
func (m *Model) resetParameter(paramName string, updateInput bool) {
	defaults := config.GetCallDefaults()
	
	defaultValue := ""
	switch paramName {
	case config.CallParamCallType:
		defaultValue = types.CallTypeToString(defaults.CallType)
	case config.CallParamCaller:
		defaultValue = defaults.CallerAddr
	case config.CallParamTarget:
		defaultValue = defaults.TargetAddr
	case config.CallParamValue:
		defaultValue = defaults.Value
	case config.CallParamGasLimit:
		defaultValue = config.DefaultGasLimit
	case config.CallParamInput, config.CallParamInputDeploy:
		defaultValue = defaults.InputData
	case config.CallParamSalt:
		defaultValue = defaults.Salt
	}
	
	// Update the parameter value
	SetCallParam(&m.callParams, paramName, defaultValue)
	
	// Update UI inputs if requested
	if updateInput {
		if paramName == config.CallParamCallType {
			options := types.GetCallTypeOptions()
			for i, opt := range options {
				if opt == defaultValue {
					m.callTypeSelector = i
					break
				}
			}
		} else if m.textInput.Value() != "" {
			m.textInput.SetValue(defaultValue)
		}
	}
	
	m.validationError = ""
}

// handleResetParameter handles resetting the current parameter to default
func (m Model) handleResetParameter() (tea.Model, tea.Cmd) {
	params := GetCallParams(m.callParams)
	if m.callParamCursor >= len(params) {
		return m, nil
	}
	
	param := params[m.callParamCursor]
	m.resetParameter(param.Name, false)
	return m, nil
}

// handleResetCurrentParameter handles resetting the currently editing parameter
func (m Model) handleResetCurrentParameter() (tea.Model, tea.Cmd) {
	m.resetParameter(m.editingParam, true)
	return m, nil
}

// handleResetAllParameters handles resetting all parameters to defaults
func (m Model) handleResetAllParameters() (tea.Model, tea.Cmd) {
	m.callParams = NewCallParameters()
	return m, nil
}

// handleResetState handles the reset state menu option
func (m Model) handleResetState() (tea.Model, tea.Cmd) {
	m.state = types.StateConfirmReset
	return m, nil
}

// executeReset performs the actual state reset
func (m Model) executeReset() tea.Cmd {
	return func() tea.Msg {
		// Clear state file
		state.ClearStateFile(state.GetStateFilePath())
		
		// Create fresh VM manager
		newVmManager, err := evm.GetVMManager()
		if err == nil {
			// Clean up old VM
			if m.vmManager != nil {
				m.vmManager.Close()
			}
			m.vmManager = newVmManager
		}
		
		// Clear history
		m.historyManager.Clear()
		
		// Reset call parameters
		m.callParams = NewCallParameters()
		
		return resetCompleteMsg{}
	}
}

// getCopyContent returns the content to copy based on current state
func (m *Model) getCopyContent() string {
	switch m.state {
	case types.StateContractDetail:
		contract := m.historyManager.GetContract(m.selectedContract)
		if contract != nil {
			return contract.Address
		}
	}
	
	return ""
}

// handleCopy handles copying content to clipboard based on current state
func (m Model) handleCopy() (tea.Model, tea.Cmd) {
	content := m.getCopyContent()
	
	if content != "" {
		msg, _ := ui.CopyWithFeedback(content)
		m.showCopyFeedback = true
		m.copyFeedbackMsg = msg
		return m, tea.Tick(time.Second*2, func(time.Time) tea.Msg {
			return copyFeedbackMsg{message: ""}
		})
	}
	
	return m, nil
}