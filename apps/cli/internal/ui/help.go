package ui

import (
	"guillotine-cli/internal/config"
	"github.com/charmbracelet/lipgloss"
)

func RenderHelpText() string {
	displayKeys, actions := config.GetHelpText()
	
	helpText := ""
	for i, key := range displayKeys {
		if i > 0 {
			helpText += " • "
		}
		keyStyle := lipgloss.NewStyle().Foreground(config.Amber)
		actionStyle := lipgloss.NewStyle().Foreground(config.Muted)
		helpText += keyStyle.Render(key) + " " + actionStyle.Render(actions[i])
	}
	
	return helpText
}