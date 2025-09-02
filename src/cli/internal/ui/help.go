package ui

import (
	"guillotine-cli/internal/config"
	"github.com/charmbracelet/lipgloss"
)

func RenderHelpText() string {
	displayKeys, actions := config.GetHelpText()
	return renderHelpTextFromKeysAndActions(displayKeys, actions)
}

func renderHelpTextFromKeysAndActions(keys, actions []string) string {
	helpText := ""
	for i, key := range keys {
		if i > 0 {
			helpText += " • "
		}
		keyStyle := lipgloss.NewStyle().Foreground(config.Amber)
		actionStyle := lipgloss.NewStyle().Foreground(config.Muted)
		helpText += keyStyle.Render(key) + " " + actionStyle.Render(actions[i])
	}
	return helpText
}

func RenderCallParameterListHelp() string {
	keys := []string{"↑/↓", "enter", "x", "r", "ctrl+r", "esc"}
	actions := []string{"navigate", "edit", "execute", "reset", "reset all", "back"}
	return renderHelpTextFromKeysAndActions(keys, actions)
}

func RenderCallEditHelp() string {
	keys := []string{"enter", "r", "esc"}
	actions := []string{"save", "reset default", "cancel"}
	return renderHelpTextFromKeysAndActions(keys, actions)
}

func RenderCallEditTypeHelp() string {
	keys := []string{"↑/↓", "enter", "r", "esc"}
	actions := []string{"select", "save", "reset default", "cancel"}
	return renderHelpTextFromKeysAndActions(keys, actions)
}

func RenderCallResultHelp() string {
	keys := []string{"enter", "esc"}
	actions := []string{"continue", "back to menu"}
	return renderHelpTextFromKeysAndActions(keys, actions)
}