package ui

import (
	"fmt"
	"strings"

	"guillotine-cli/internal/config"

	"github.com/charmbracelet/lipgloss"
)

// SourceFile represents a source code file for UI rendering
type SourceFile struct {
	ID       int
	Path     string
	Content  []string
	Language string
}

// SourceLocation represents a location in source code for UI rendering
type SourceLocation struct {
	Line     int
	Column   int
	Length   int
	SourceID int
	FileName string
}

// SourceVisualizationContext provides context for rendering source visualization
type SourceVisualizationContext struct {
	SourceFile      SourceFile
	HighlightLine   int
	HighlightColumn int
	HighlightLength int
	CurrentPC       uint32
	Location        SourceLocation
	HasSourceMap    bool
	ViewMode        SourceViewMode
}

type SourceViewMode int

const (
	SourceMainView SourceViewMode = iota
	SourceFullscreenView
)

// RenderSourceVisualization renders the main source code visualization
func RenderSourceVisualization(ctx SourceVisualizationContext) string {
	var sections []string

	// Title
	title := config.TitleStyle.Render("Source Code Visualization")
	sections = append(sections, title)
	sections = append(sections, "")

	if !ctx.HasSourceMap {
		return renderNoSourceMap()
	}

	// File header
	fileHeader := renderFileHeader(ctx.SourceFile, ctx.CurrentPC, ctx.Location)
	sections = append(sections, fileHeader)
	sections = append(sections, "")

	// Source code with highlighting
	sourceCode := renderSourceCodeWithHighlight(ctx.SourceFile, ctx.HighlightLine, ctx.HighlightColumn, ctx.HighlightLength)
	sections = append(sections, sourceCode)
	sections = append(sections, "")

	// Current location info
	if ctx.HighlightLine >= 0 {
		locationInfo := renderLocationInfo(ctx.Location, ctx.CurrentPC)
		sections = append(sections, locationInfo)
		sections = append(sections, "")
	}

	// Controls
	controls := renderSourceControls()
	sections = append(sections, controls)

	return lipgloss.JoinVertical(lipgloss.Left, sections...)
}

// renderFileHeader renders the file information header
func renderFileHeader(file SourceFile, pc uint32, location SourceLocation) string {
	headerStyle := config.BoxStyle.
		BorderForeground(config.ChartBlue).
		Width(80)

	var headerInfo strings.Builder
	headerInfo.WriteString(fmt.Sprintf("File: %s (%s)\n", file.Path, file.Language))
	headerInfo.WriteString(fmt.Sprintf("Lines: %d | Current PC: %d", len(file.Content), pc))

	if location.Line >= 0 {
		headerInfo.WriteString(fmt.Sprintf(" | Line: %d, Column: %d", location.Line+1, location.Column+1))
	}

	return headerStyle.Render(headerInfo.String())
}

// renderSourceCodeWithHighlight renders source code with syntax highlighting
func renderSourceCodeWithHighlight(file SourceFile, highlightLine, highlightCol, highlightLen int) string {
	if len(file.Content) == 0 {
		return config.SubtitleStyle.Render("No source code available")
	}

	var lines []string
	
	// Calculate visible range (show 10 lines around highlight)
	startLine := 0
	endLine := len(file.Content)
	
	if highlightLine >= 0 {
		startLine = max(0, highlightLine-5)
		endLine = min(len(file.Content), highlightLine+6)
	} else if len(file.Content) > 20 {
		// Show first 20 lines if no highlight
		endLine = 20
	}

	for i := startLine; i < endLine; i++ {
		line := file.Content[i]
		lineNum := i + 1
		
		// Line number
		lineNumStyle := config.SubtitleStyle
		if i == highlightLine {
			lineNumStyle = lineNumStyle.Foreground(config.Amber)
		}
		lineNumStr := lineNumStyle.Render(fmt.Sprintf("%4d │ ", lineNum))
		
		// Line content
		var lineContent string
		if i == highlightLine && highlightCol >= 0 && highlightLen > 0 {
			// Highlight specific part of the line
			lineContent = renderHighlightedLine(line, highlightCol, highlightLen)
		} else if i == highlightLine {
			// Highlight entire line
			lineStyle := lipgloss.NewStyle().
				Background(config.AmberLight).
				Foreground(config.Background)
			lineContent = lineStyle.Render(line)
		} else {
			// Normal line
			lineContent = line
		}
		
		fullLine := lineNumStr + lineContent
		lines = append(lines, fullLine)
	}

	// Show ellipsis if truncated
	if startLine > 0 {
		ellipsis := config.SubtitleStyle.Render("   ... (lines 1-" + fmt.Sprintf("%d", startLine) + " hidden)")
		lines = append([]string{ellipsis}, lines...)
	}
	if endLine < len(file.Content) {
		ellipsis := config.SubtitleStyle.Render("   ... (" + fmt.Sprintf("%d", len(file.Content)-endLine) + " more lines)")
		lines = append(lines, ellipsis)
	}

	sourceStyle := config.BoxStyle.
		BorderForeground(config.Border).
		Width(90).
		Height(min(20, len(lines)+2))

	return sourceStyle.Render(strings.Join(lines, "\n"))
}

// renderHighlightedLine renders a line with a specific section highlighted
func renderHighlightedLine(line string, highlightCol, highlightLen int) string {
	if highlightCol < 0 || highlightCol >= len(line) {
		// Highlight entire line if column is out of bounds
		highlightStyle := lipgloss.NewStyle().
			Background(config.AmberLight).
			Foreground(config.Background)
		return highlightStyle.Render(line)
	}

	endCol := min(highlightCol+highlightLen, len(line))
	
	before := line[:highlightCol]
	highlighted := line[highlightCol:endCol]
	after := line[endCol:]

	highlightStyle := lipgloss.NewStyle().
		Background(config.Amber).
		Foreground(config.Background).
		Bold(true)

	return before + highlightStyle.Render(highlighted) + after
}

// renderLocationInfo renders information about the current source location
func renderLocationInfo(location SourceLocation, pc uint32) string {
	locationStyle := config.BoxStyle.
		BorderForeground(config.ChartGreen).
		Width(80)

	var locationInfo strings.Builder
	locationInfo.WriteString(fmt.Sprintf("Execution Context\n"))
	locationInfo.WriteString(fmt.Sprintf("  PC: %d → Line %d, Column %d\n", pc, location.Line+1, location.Column+1))
	locationInfo.WriteString(fmt.Sprintf("  File: %s", location.FileName))
	
	if location.Length > 0 {
		locationInfo.WriteString(fmt.Sprintf("\n  Highlighted: %d characters", location.Length))
	}

	return locationStyle.Render(locationInfo.String())
}

// renderSourceControls renders control instructions for source visualization
func renderSourceControls() string {
	var controls []string
	
	controls = append(controls, "Source Navigation:")
	controls = append(controls, "  ↑/k: Scroll up")
	controls = append(controls, "  ↓/j: Scroll down")
	controls = append(controls, "  Home: Go to top")
	controls = append(controls, "  End: Go to bottom")
	controls = append(controls, "")
	controls = append(controls, "Execution:")
	controls = append(controls, "  →/l: Next execution step")
	controls = append(controls, "  ←/h: Previous execution step")
	controls = append(controls, "  Space: Toggle follow mode")
	controls = append(controls, "")
	controls = append(controls, "  f: Toggle fullscreen")
	controls = append(controls, "  Esc: Back to menu")
	
	return config.HelpStyle.Render(strings.Join(controls, "\n"))
}

// renderNoSourceMap renders a message when no source map is available
func renderNoSourceMap() string {
	noSourceStyle := lipgloss.NewStyle().
		Foreground(config.Muted).
		Border(lipgloss.RoundedBorder()).
		BorderForeground(config.Muted).
		Padding(3, 6).
		Align(lipgloss.Center)

	content := "No Source Map Available\n\n" +
		"Source code visualization requires:\n" +
		"• Contract source code\n" +
		"• Solidity source map\n" +
		"• Debug information\n\n" +
		"Load a contract with source maps to\n" +
		"visualize execution on source code."

	return noSourceStyle.Render(content)
}

// renderSourceLoading renders loading state for source visualization
func renderSourceLoading() string {
	loadingStyle := lipgloss.NewStyle().
		Foreground(config.ChartBlue).
		Border(lipgloss.RoundedBorder()).
		BorderForeground(config.ChartBlue).
		Padding(2, 4).
		Align(lipgloss.Center).
		Bold(true)

	content := "🔄 Loading Source Maps...\n\n" +
		"Parsing source code and building\n" +
		"PC → source line mappings."

	return loadingStyle.Render(content)
}

// Helper functions
func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}

func max(a, b int) int {
	if a > b {
		return a
	}
	return b
}