package ui

import (
	"guillotine-cli/internal/config"
	"guillotine-cli/internal/types"
	"github.com/charmbracelet/lipgloss"
)

// Map AppState to string keys for help lookup
var stateToHelpKey = map[types.AppState]string{
	types.StateMainMenu:           "main_menu",
	types.StateCallParameterList:  "call_parameter_list",
	types.StateCallParameterEdit:  "call_parameter_edit",
	types.StateCallTypeEdit:       "call_type_selection",
	types.StateCallResult:         "call_result",
	types.StateCallHistory:        "call_history",
	types.StateCallHistoryDetail:  "call_history_detail",
	types.StateContracts:          "contracts",
	types.StateContractDetail:     "contract_detail",
	types.StateConfirmReset:       "confirm_reset",
	types.StateLogDetail:          "log_detail",
}

// RenderHelp renders help text for the given state
func RenderHelp(state types.AppState) string {
	stateKey, exists := stateToHelpKey[state]
	if !exists {
		return ""
	}
	return renderHelpForKey(stateKey)
}

// RenderHelpForContractDetail renders help for contract detail with conditional disassembly navigation
func RenderHelpForContractDetail(hasDisassembly bool) string {
	entries := config.GetHelpForContractDetail(hasDisassembly)
	keys, actions := config.GetHelpText(entries)
	return renderHelpText(keys, actions)
}

// RenderHelpWithLogs renders help text for states that may have logs
func RenderHelpWithLogs(state types.AppState, hasLogs bool) string {
	stateKey, exists := stateToHelpKey[state]
	if !exists {
		return ""
	}
	
	entries := config.GetHelpForStateWithLogs(stateKey, hasLogs)
	keys, actions := config.GetHelpText(entries)
	return renderHelpText(keys, actions)
}

// renderHelpForKey renders help for a given state key
func renderHelpForKey(stateKey string) string {
	entries := config.GetHelpForState(stateKey)
	keys, actions := config.GetHelpText(entries)
	return renderHelpText(keys, actions)
}

// renderHelpText renders the actual help text from keys and actions
func renderHelpText(keys, actions []string) string {
	helpText := ""
	keyStyle := lipgloss.NewStyle().Foreground(config.Amber)
	actionStyle := lipgloss.NewStyle().Foreground(config.Muted)
	
	for i, key := range keys {
		if i > 0 {
			helpText += " • "
		}
		helpText += keyStyle.Render(key) + " " + actionStyle.Render(actions[i])
	}
	
	// Apply the HelpStyle which should handle positioning
	return config.HelpStyle.Render(helpText)
}