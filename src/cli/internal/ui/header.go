package ui

import (
	"github.com/charmbracelet/lipgloss"
)

func RenderHeader(title, subtitle string, titleStyle, subtitleStyle lipgloss.Style) string {
	header := lipgloss.JoinHorizontal(
		lipgloss.Center,
		titleStyle.Render(" " + title + " "),
	)
	
	subtitleRendered := subtitleStyle.Render(subtitle)
	
	return header + "\n" + subtitleRendered
}