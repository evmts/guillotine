package ui

import (
	"strings"
	
	"github.com/charmbracelet/lipgloss"
)

// RenderSplitPanel renders content in a two-column layout
func RenderSplitPanel(leftContent, rightContent string, totalWidth, height int) string {
	// Calculate panel widths (40/60 split for left/right)
	leftWidth := totalWidth * 40 / 100
	rightWidth := totalWidth - leftWidth - 3 // -3 for separator and padding
	
	if leftWidth < 30 {
		leftWidth = 30
	}
	if rightWidth < 40 {
		rightWidth = 40
	}
	
	// Create styles for each panel
	leftPanelStyle := lipgloss.NewStyle().
		Width(leftWidth).
		Height(height).
		AlignVertical(lipgloss.Top).
		Padding(0, 1)
	
	rightPanelStyle := lipgloss.NewStyle().
		Width(rightWidth).
		MaxHeight(height).
		AlignVertical(lipgloss.Top).
		Padding(0, 1)
	
	// Render panels
	leftPanel := leftPanelStyle.Render(leftContent)
	rightPanel := rightPanelStyle.Render(rightContent)
	
	// Join panels horizontally
	return lipgloss.JoinHorizontal(lipgloss.Top, leftPanel, rightPanel)
}

// RenderContractDetailSplit renders contract details with disassembly side-by-side
func RenderContractDetailSplit(leftContent, rightContent string, totalWidth, height int, hasDisassembly bool) string {
	if !hasDisassembly {
		// If no disassembly, use full width for contract details
		return leftContent
	}
	
	// Split the view
	return RenderSplitPanel(leftContent, rightContent, totalWidth, height)
}

// TruncateLines ensures content fits within the specified height
func TruncateLines(content string, maxLines int) string {
	lines := strings.Split(content, "\n")
	if len(lines) <= maxLines {
		return content
	}
	
	truncated := lines[:maxLines]
	return strings.Join(truncated, "\n")
}