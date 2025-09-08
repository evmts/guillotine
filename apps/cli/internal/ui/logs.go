package ui

import (
	"fmt"
	"strings"

	"guillotine-cli/internal/config"

	"github.com/charmbracelet/bubbles/table"
	"github.com/charmbracelet/lipgloss"
	guillotine "github.com/evmts/guillotine/sdks/go"
)

// LogDisplayData contains pure data for log display
type LogDisplayData struct {
	Logs             []guillotine.LogEntry
	SelectedIndex    int
	AvailableHeight  int
}

// RenderLogsDisplay renders logs as a table if space allows, otherwise as simple list
func RenderLogsDisplay(displayData LogDisplayData, width int) string {
	if len(displayData.Logs) == 0 {
		return ""
	}
	
	if displayData.AvailableHeight > 5 {
		return "\n\n" + RenderLogsAsTable(displayData.Logs, displayData.SelectedIndex, width, displayData.AvailableHeight)
	} else {
		return "\n\n" + RenderLogsSection(displayData.Logs, width)
	}
}

// RenderLogsAsTable renders logs in a pure table format with proper scrolling
func RenderLogsAsTable(logs []guillotine.LogEntry, selectedIndex int, width, availableHeight int) string {
	if len(logs) == 0 {
		emptyStyle := config.DimmedStyle
		return emptyStyle.Render("No logs emitted")
	}

	var content strings.Builder
	
	// Logs title
	titleStyle := lipgloss.NewStyle().Bold(true).Foreground(config.Amber)
	content.WriteString(titleStyle.Render(fmt.Sprintf("Logs (%d):", len(logs))))
	content.WriteString("\n\n")
	
	// Table header with proper alignment
	headerStyle := lipgloss.NewStyle().Bold(true).Foreground(config.Amber)
	// Use consistent formatting for header to match data rows
	header := fmt.Sprintf("%-4s %-16s %-7s %s", "#", "Address", "Topics", "Data")
	content.WriteString(headerStyle.Render(header))
	content.WriteString("\n")
	
	// Calculate scrolling viewport (account for title, header and some padding)
	maxRows := max(availableHeight - 4, 1)
	
	// Ensure selectedIndex is within bounds
	selectedIndex = min(selectedIndex, len(logs) - 1)
	selectedIndex = max(selectedIndex, 0)
	
	// Calculate scroll offset to keep selected item visible
	var startIndex int
	if len(logs) <= maxRows {
		// All logs fit, show everything
		startIndex = 0
	} else {
		// Calculate offset to center selected item when possible
		centerOffset := maxRows / 2
		
		if selectedIndex < centerOffset {
			// Near the beginning, show from start
			startIndex = 0
		} else if selectedIndex >= len(logs)-centerOffset {
			// Near the end, show the last maxRows entries
			startIndex = len(logs) - maxRows
		} else {
			// In the middle, center the selected item
			startIndex = selectedIndex - centerOffset
		}
		
		// Ensure startIndex is within bounds
		if startIndex < 0 {
			startIndex = 0
		}
		if startIndex+maxRows > len(logs) {
			startIndex = len(logs) - maxRows
		}
	}
	
	// Calculate end index
	endIndex := startIndex + maxRows
	endIndex = min(endIndex, len(logs))
	
	// Render visible rows
	for i := startIndex; i < endIndex; i++ {
		log := logs[i]
		
		rowStyle := config.DimmedStyle
		if i == selectedIndex {
			rowStyle = lipgloss.NewStyle().Bold(true).Background(config.Amber).Foreground(config.Background)
		}
		
		// Format address to exactly 16 chars for alignment
		addr := formatFixedAddress(log.Address.String(), 16)
		data := formatLogData(log.Data, 30)
		
		row := fmt.Sprintf("%-4d %-16s %-7d %s", 
			i, 
			addr,
			len(log.Topics),
			data)
		
		content.WriteString(rowStyle.Render(row))
		content.WriteString("\n")
	}
	
	return content.String()
}

// RenderLogsSection renders a simple logs section without a table (for when table is not available)
func RenderLogsSection(logs []guillotine.LogEntry, width int) string {
	if len(logs) == 0 {
		return ""
	}
	
	var b strings.Builder
	
	labelStyle := config.LabelStyle
	b.WriteString(labelStyle.Render(fmt.Sprintf("Logs (%d entries):", len(logs))))
	b.WriteString("\n\n")
	
	for i, log := range logs {
		b.WriteString(renderLogEntry(i, log, width))
		if i < len(logs)-1 {
			b.WriteString("\n")
		}
	}
	
	return b.String()
}

// ConvertLogsToRows converts log entries to table rows
func ConvertLogsToRows(logs []guillotine.LogEntry) []table.Row {
	rows := make([]table.Row, 0, len(logs))
	
	for i, log := range logs {
		row := table.Row{
			fmt.Sprintf("%d", i),
			formatFixedAddress(log.Address.String(), 16),
			fmt.Sprintf("%d", len(log.Topics)),
			formatLogData(log.Data, 40),
		}
		rows = append(rows, row)
	}
	
	return rows
}

func renderLogEntry(index int, log guillotine.LogEntry, width int) string {
	var b strings.Builder
	
	indexStyle := lipgloss.NewStyle().Bold(true).Foreground(config.Amber)
	b.WriteString(indexStyle.Render(fmt.Sprintf("[%d]", index)))
	b.WriteString(" ")
	
	// Address
	b.WriteString(config.LabelStyle.Render("Address: "))
	b.WriteString(formatFixedAddress(log.Address.String(), 10))
	b.WriteString("\n")
	
	// Topics
	if len(log.Topics) > 0 {
		b.WriteString("    ")
		b.WriteString(config.LabelStyle.Render("Topics: "))
		for i, topic := range log.Topics {
			if i > 0 {
				b.WriteString("\n            ")
			}
			b.WriteString(config.DimmedStyle.Render(formatTopic(topic.String(), width-12)))
		}
		b.WriteString("\n")
	}
	
	// Data
	data := log.Data
	if len(data) > 0 {
		b.WriteString("    ")
		b.WriteString(config.LabelStyle.Render("Data: "))
		b.WriteString(config.DimmedStyle.Render(formatLogData(data, width-10)))
		b.WriteString("\n")
	}
	
	return b.String()
}


func formatTopic(topic string, maxWidth int) string {
	if !strings.HasPrefix(topic, "0x") {
		topic = "0x" + topic
	}
	if len(topic) <= maxWidth {
		return topic
	}
	if maxWidth < 20 {
		return topic[:maxWidth]
	}
	return fmt.Sprintf("%s…%s", topic[:maxWidth/2], topic[len(topic)-maxWidth/2+1:])
}

// formatFixedAddress formats an address to exactly the specified width
func formatFixedAddress(addr string, width int) string {
	if !strings.HasPrefix(addr, "0x") {
		addr = "0x" + addr
	}
	
	// If address is shorter than width, pad it
	if len(addr) <= width {
		return addr + strings.Repeat(" ", width-len(addr))
	}
	
	// If we need to truncate, use ellipsis but ensure fixed width
	if width < 8 {
		return addr[:width]
	}
	
	// Show beginning and end with ellipsis in middle
	prefixLen := (width - 3) / 2  // Reserve 3 chars for "..."
	suffixLen := width - 3 - prefixLen
	return addr[:prefixLen] + "..." + addr[len(addr)-suffixLen:]
}

func formatLogData(data []byte, maxChars int) string {
	if len(data) == 0 {
		return "0x"
	}
	
	hex := fmt.Sprintf("0x%x", data)
	if len(hex) <= maxChars {
		return hex
	}
	
	if maxChars < 10 {
		return hex[:maxChars]
	}
	
	// Use three dots instead of ellipsis character for consistent width
	return fmt.Sprintf("%s...%s", hex[:maxChars/2-1], hex[len(hex)-maxChars/2+2:])
}


// RenderLogDetail renders detailed view of a single log entry
func RenderLogDetail(log *guillotine.LogEntry, index int, width int) string {
	if log == nil {
		return config.DimmedStyle.Render("No log selected")
	}
	
	var b strings.Builder
	
	// Title
	titleStyle := lipgloss.NewStyle().Bold(true).Foreground(config.Amber)
	b.WriteString(titleStyle.Render(fmt.Sprintf("Log Entry #%d", index)))
	b.WriteString("\n\n")
	
	// Address - always show full on one line
	b.WriteString(config.LabelStyle.Render("Address:"))
	b.WriteString("\n")
	b.WriteString(config.DimmedStyle.Render(log.Address.String()))
	b.WriteString("\n\n")
	
	// Topics - always show full on one line each
	if len(log.Topics) > 0 {
		b.WriteString(config.LabelStyle.Render(fmt.Sprintf("Topics (%d):", len(log.Topics))))
		b.WriteString("\n")
		for i, topic := range log.Topics {
			b.WriteString(config.DimmedStyle.Render(fmt.Sprintf("  [%d] %s", i, topic.String())))
			b.WriteString("\n")
		}
		b.WriteString("\n")
	}
	
	// Data - intelligently wrap based on terminal width
	data := log.Data
	if len(data) > 0 {
		b.WriteString(config.LabelStyle.Render("Data:"))
		b.WriteString("\n")
		
		hex := fmt.Sprintf("0x%x", data)
		
		// Account for margins and indentation (approximately 4 chars)
		availableWidth := width - 4
		
		if len(hex) <= availableWidth {
			// Fits on one line
			b.WriteString(config.DimmedStyle.Render(hex))
			b.WriteString("\n")
		} else {
			// Need to wrap - break on byte boundaries
			// Skip "0x" prefix for wrapping calculation
			hexData := hex[2:]
			
			// Each byte is 2 hex chars, calculate chars per line
			// Make it even to avoid breaking bytes
			charsPerLine := availableWidth - 2 // Reserve space for "0x" on first line
			if charsPerLine%2 != 0 {
				charsPerLine--
			}
			
			// First line with 0x prefix
			b.WriteString(config.DimmedStyle.Render("0x" + hexData[:min(charsPerLine, len(hexData))]))
			b.WriteString("\n")
			
			// Subsequent lines without prefix, indented by 2 spaces
			for i := charsPerLine; i < len(hexData); i += charsPerLine + 2 {
				end := min(i+charsPerLine+2, len(hexData))
				b.WriteString(config.DimmedStyle.Render("  " + hexData[i:end]))
				b.WriteString("\n")
			}
		}
		
		// Show data size
		b.WriteString("\n")
		b.WriteString(config.LabelStyle.Render("Data Size: "))
		b.WriteString(config.DimmedStyle.Render(fmt.Sprintf("%d bytes", len(data))))
		b.WriteString("\n")
	}
	
	return b.String()
}