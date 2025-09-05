package app

import (
	"guillotine-cli/internal/config"
	logs "guillotine-cli/internal/core"
	"guillotine-cli/internal/types"
	"guillotine-cli/internal/ui"

	"github.com/charmbracelet/lipgloss"
)

func (m Model) View() string {
	if m.quitting {
		goodbyeStyle := lipgloss.NewStyle().
			Foreground(config.Amber).
			Bold(true).
			Padding(1, 2)
		return goodbyeStyle.Render(config.GoodbyeMessage)
	}

	if m.width == 0 || m.height == 0 {
		return config.LoadingMessage
	}

	layout := ui.Layout{Width: m.width, Height: m.height}
	
	switch m.state {
	case types.StateMainMenu:
		header := ui.RenderHeader(m.greeting, config.AppSubtitle, config.TitleStyle, config.SubtitleStyle)
		menu := ui.RenderMenu(m.choices, m.cursor)
		help := ui.RenderHelp(types.StateMainMenu)
		content := layout.ComposeVertical(header, menu, help)
		return layout.RenderWithBox(content)
		
	case types.StateCallParameterList:
		header := ui.RenderHeader(config.CallStateTitle, config.CallStateSubtitle, config.TitleStyle, config.SubtitleStyle)
		params := GetCallParams(m.callParams)
		callList := ui.RenderCallParameterList(params, m.callParamCursor, m.validationError)
		help := ui.RenderHelp(types.StateCallParameterList)
		content := layout.ComposeVertical(header, callList, help)
		return layout.RenderWithBox(content)
		
	case types.StateCallParameterEdit, types.StateCallTypeEdit:
		header := ui.RenderHeader(config.CallEditTitle, config.CallEditSubtitle, config.TitleStyle, config.SubtitleStyle)
		editView := ui.RenderCallEdit(m.editingParam, m.textInput, m.validationError, m.callTypeSelector)
		help := ui.RenderHelp(m.state)
		content := layout.ComposeVertical(header, editView, help)
		return layout.RenderWithBox(content)
		
	case types.StateCallExecuting:
		header := ui.RenderHeader(config.CallExecutingTitle, config.CallExecutingSubtitle, config.TitleStyle, config.SubtitleStyle)
		executing := ui.RenderCallExecuting()
		content := layout.ComposeVertical(header, executing, "")
		return layout.RenderWithBox(content)
		
	case types.StateCallResult:
		header := ui.RenderHeader(config.CallResultTitle, config.CallResultSubtitle, config.TitleStyle, config.SubtitleStyle)
		
		// Create pure log display data
		logDisplayData := ui.LogDisplayData{}
		if m.callResult != nil && len(m.callResult.Logs) > 0 {
			// Use a reasonable fixed height for logs that won't cause cropping
			maxLogHeight := (m.height / 2) // Use at most half of screen for logs
			availableHeight := min(maxLogHeight, 15) // Cap at 15 lines for logs
			
			logDisplayData = ui.LogDisplayData{
				Logs:            m.callResult.Logs,
				SelectedIndex:   m.logsTable.Cursor(), // Get current selection from table
				AvailableHeight: availableHeight,
			}
		}
		
		result := ui.RenderCallResult(m.callResult, m.callParams, logDisplayData, m.width-4)
		hasLogs := logs.HasLogs(m.callResult)
		help := ui.RenderHelpWithLogs(types.StateCallResult, hasLogs)
		content := layout.ComposeVertical(header, result, help)
		return layout.RenderWithBox(content)
		
	case types.StateCallHistory:
		header := ui.RenderHeader(config.CallHistoryTitle, config.CallHistorySubtitle, config.TitleStyle, config.SubtitleStyle)
		tableView := m.historyTable.View()
		help := ui.RenderHelp(types.StateCallHistory)
		content := layout.ComposeVertical(header, tableView, help)
		return layout.RenderWithBox(content)
		
	case types.StateCallHistoryDetail:
		header := ui.RenderHeader(config.CallHistoryDetailTitle, config.CallHistoryDetailSubtitle, config.TitleStyle, config.SubtitleStyle)
		entry := m.historyManager.GetCall(m.selectedHistoryID)
		
		// Create pure log display data
		logDisplayData := ui.LogDisplayData{}
		if logs.HasHistoryLogs(entry) {
			// Use a conservative fixed height for logs in history detail view
			// This ensures the content is never cropped at the top
			maxLogHeight := (m.height / 3) // Use at most 1/3 of screen for logs
			availableHeight := min(maxLogHeight, 10) // Cap at 10 lines for logs
			
			logDisplayData = ui.LogDisplayData{
				Logs:            entry.Result.Logs,
				SelectedIndex:   m.logsTable.Cursor(),
				AvailableHeight: availableHeight,
			}
		}
		
		detail := ui.RenderHistoryDetail(entry, logDisplayData, m.width-4)
		hasLogs := logs.HasHistoryLogs(entry)
		help := ui.RenderHelpWithLogs(types.StateCallHistoryDetail, hasLogs)
		content := layout.ComposeVertical(header, detail, help)
		return layout.RenderWithBox(content)
		
	case types.StateContracts:
		header := ui.RenderHeader(config.ContractsTitle, config.ContractsSubtitle, config.TitleStyle, config.SubtitleStyle)
		tableView := m.contractsTable.View()
		help := ui.RenderHelp(types.StateContracts)
		content := layout.ComposeVertical(header, tableView, help)
		return layout.RenderWithBox(content)
		
	case types.StateContractDetail:
		header := ui.RenderHeader(config.ContractDetailTitle, config.ContractDetailSubtitle, config.TitleStyle, config.SubtitleStyle)
		contract := m.historyManager.GetContract(m.selectedContract)
		
		detail := ui.RenderContractDetail(contract, m.width-4, m.height-10)
		help := ui.RenderHelp(types.StateContractDetail)
		content := layout.ComposeVertical(header, detail, help)
		return layout.RenderWithBox(content)
		
	case types.StateConfirmReset:
		header := ui.RenderHeader(config.ResetStateTitle, config.ResetStateSubtitle, config.TitleStyle, config.SubtitleStyle)
		confirmText := lipgloss.NewStyle().
			Bold(true).
			Foreground(config.Destructive).
			Render(config.ResetConfirmMessage)
		help := ui.RenderHelp(types.StateConfirmReset)
		content := layout.ComposeVertical(header, confirmText, help)
		return layout.RenderWithBox(content)
		
	case types.StateLogDetail:
		header := ui.RenderHeader(config.LogDetailTitle, config.LogDetailSubtitle, config.TitleStyle, config.SubtitleStyle)
		
		// Get log using core domain logic
		var selectedHistoryEntry *types.CallHistoryEntry
		if m.selectedHistoryID != "" {
			selectedHistoryEntry = m.historyManager.GetCall(m.selectedHistoryID)
		}
		
		log := logs.GetSelectedLog(m.callResult, selectedHistoryEntry, m.selectedLogIndex)
		detail := ui.RenderLogDetail(log, m.selectedLogIndex, m.width-4)
		help := ui.RenderHelp(types.StateLogDetail)
		content := layout.ComposeVertical(header, detail, help)
		return layout.RenderWithBox(content)
		
	default:
		return "Invalid state"
	}
}