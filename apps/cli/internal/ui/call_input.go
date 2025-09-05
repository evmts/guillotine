package ui

import (
	"guillotine-cli/internal/config"
	"guillotine-cli/internal/types"
	"strings"

	"github.com/charmbracelet/bubbles/textinput"
	"github.com/charmbracelet/lipgloss"
)

func CreateTextInput(paramName, currentValue string) textinput.Model {
	ti := textinput.New()
	ti.Focus()
	ti.Width = 50
	ti.SetValue(currentValue)
	
	switch paramName {
	case config.CallParamCallType:
		ti.CharLimit = 20
	case config.CallParamCaller, config.CallParamTarget:
		ti.CharLimit = 42
		ti.Placeholder = "0x1234567890abcdef..."
	case config.CallParamValue:
		ti.CharLimit = 30
		ti.Placeholder = "0"
	case config.CallParamGasLimit:
		ti.CharLimit = 10
		ti.Placeholder = "100000"
	case config.CallParamInput, config.CallParamInputDeploy:
		ti.CharLimit = 0 // No limit for input data
		ti.Placeholder = "0x"
	case config.CallParamSalt:
		ti.CharLimit = 66
		ti.Placeholder = "0x0000..."
	default:
		ti.CharLimit = 256 // Default for unknown parameters
	}
	
	return ti
}

func RenderCallEdit(paramName string, input textinput.Model, validationError string, callTypeSelector int) string {
	var content strings.Builder
	
	titleStyle := lipgloss.NewStyle().Bold(true).Foreground(config.Amber)
	content.WriteString(titleStyle.Render(config.CallEditTitle))
	content.WriteString("\n\n")
	
	labelStyle := lipgloss.NewStyle().Bold(true).Foreground(config.Foreground)
	content.WriteString(labelStyle.Render(paramName + ":"))
	content.WriteString("\n")
	
	if paramName == config.CallParamCallType {
		content.WriteString(renderCallTypeSelector(callTypeSelector))
	} else {
		content.WriteString(input.View())
	}
	
	if validationError != "" {
		content.WriteString("\n")
		errorStyle := lipgloss.NewStyle().Foreground(config.Destructive)
		content.WriteString(errorStyle.Render("Error: " + validationError))
	}
	
	return content.String()
}

func renderCallTypeSelector(selectedIndex int) string {
	options := types.GetCallTypeOptions()
	var items []string
	
	for i, option := range options {
		prefix := "  "
		style := lipgloss.NewStyle().Foreground(config.Foreground)
		
		if i == selectedIndex {
			prefix = "▸ "
			style = lipgloss.NewStyle().Bold(true).Foreground(config.Amber)
		}
		
		items = append(items, prefix+style.Render(option))
	}
	
	return strings.Join(items, "\n")
}

func RenderCallExecuting() string {
	titleStyle := lipgloss.NewStyle().Bold(true).Foreground(config.Amber)
	title := titleStyle.Render(config.CallExecutingTitle)
	
	spinnerStyle := lipgloss.NewStyle().Foreground(config.ChartBlue)
	spinner := spinnerStyle.Render("●")
	
	messageStyle := lipgloss.NewStyle().Foreground(config.Foreground)
	message := messageStyle.Render(config.CallExecutingMsg)
	
	content := title + "\n\n" + spinner + " " + message
	
	return content
}