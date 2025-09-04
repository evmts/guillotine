package ui

import (
	"fmt"
	"strings"

	"guillotine-cli/internal/config"
	"guillotine-cli/internal/types"
)

func RenderContractList(contracts []*types.DeployedContract, selectedIndex int, width int) string {
	if len(contracts) == 0 {
		emptyStyle := config.DimmedStyle
		return emptyStyle.Render("No contracts deployed yet. Deploy contracts to see them here.")
	}

	var b strings.Builder

	headerStyle := config.LabelStyle.Copy().
		Bold(true).
		Underline(true)

	headers := []string{
		padRight("Label", 15),
		padRight("Address", 42),
		padRight("Deploy Time", 12),
	}
	b.WriteString(headerStyle.Render(strings.Join(headers, " ")))
	b.WriteString("\n")

	for i, contract := range contracts {
		isSelected := i == selectedIndex
		item := formatContractEntry(contract, i, isSelected, width)
		b.WriteString(item)
		if i < len(contracts)-1 {
			b.WriteString("\n")
		}
	}

	return b.String()
}

func formatContractEntry(contract *types.DeployedContract, index int, isSelected bool, width int) string {
	timeStr := contract.Timestamp.Format("15:04:05")

	cols := []string{
		padRight(contract.Address, 42),
		padRight(timeStr, 12),
	}

	row := strings.Join(cols, " ")

	itemStyle := config.NormalStyle
	if isSelected {
		itemStyle = config.SelectedStyle
	}

	entryBox := itemStyle.
		Width(width - 4).
		Padding(0, 1)

	return entryBox.Render(row)
}

func RenderContractDetail(contract *types.DeployedContract, width, height int) string {
	if contract == nil {
		return config.DimmedStyle.Render("No contract selected")
	}

	var b strings.Builder

	b.WriteString(config.LabelStyle.Render("Address: "))
	b.WriteString(config.AccentStyle.Render(contract.Address))
	b.WriteString("\n")

	b.WriteString(config.LabelStyle.Render("Deployed: "))
	b.WriteString(contract.Timestamp.Format("2006-01-02 15:04:05"))
	b.WriteString("\n")

	// Show bytecode if available
	if len(contract.Bytecode) > 0 {
		b.WriteString(config.LabelStyle.Render("Bytecode Size: "))
		b.WriteString(formatBytecodeSize(len(contract.Bytecode)))
		b.WriteString("\n")

		// Show bytecode
		b.WriteString("\n")
		b.WriteString(config.SubtitleStyle.Render("Bytecode"))
		b.WriteString("\n")
		
		bytecodeHex := fmt.Sprintf("0x%x", contract.Bytecode)
		lines := wrapHex(bytecodeHex, width-8)
		maxLines := 10 // Show first 10 lines
		if len(lines) < maxLines {
			maxLines = len(lines)
		}
		
		for i := 0; i < maxLines; i++ {
			b.WriteString(config.CodeStyle.Render(lines[i]))
			b.WriteString("\n")
		}
		
		if len(lines) > maxLines {
			b.WriteString(config.DimmedStyle.Render(fmt.Sprintf("... (%d more lines)", len(lines)-maxLines)))
		}
	} else {
		b.WriteString("\n")
		b.WriteString(config.DimmedStyle.Render("No bytecode found at this address"))
	}

	return b.String()
}

func RenderContractBytecode(contract *types.DeployedContract, scrollOffset int, width, height int) string {
	if contract == nil {
		return config.DimmedStyle.Render("No bytecode available")
	}

	// This function is no longer used since we show bytecode in detail view
	return ""
}

func formatBytecodeSize(bytes int) string {
	if bytes < 1024 {
		return fmt.Sprintf("%d B", bytes)
	}
	return fmt.Sprintf("%.1f KB", float64(bytes)/1024)
}

func wrapHex(hex string, maxWidth int) []string {
	if maxWidth < 20 {
		maxWidth = 20
	}

	var lines []string
	for i := 0; i < len(hex); i += maxWidth {
		end := min(i+maxWidth, len(hex))
		lines = append(lines, hex[i:end])
	}
	return lines
}

func padRight(s string, width int) string {
	if len(s) >= width {
		return s[:width]
	}
	return s + strings.Repeat(" ", width-len(s))
}

func truncate(s string, maxLen int) string {
	if len(s) <= maxLen {
		return s
	}
	if maxLen < 3 {
		return s[:maxLen]
	}
	return s[:maxLen-3] + "..."
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}