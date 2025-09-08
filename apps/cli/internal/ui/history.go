package ui

import (
	"fmt"
	"strconv"
	"strings"

	"guillotine-cli/internal/config"
	"guillotine-cli/internal/types"
)

func RenderHistoryList(entries []types.CallHistoryEntry, selectedIndex int, width int) string {
	if len(entries) == 0 {
		emptyStyle := config.DimmedStyle
		return emptyStyle.Render("No call history yet. Execute some calls to see them here.")
	}

	var b strings.Builder

	for i, entry := range entries {
		isSelected := i == selectedIndex
		item := formatHistoryEntry(entry, isSelected, width)
		b.WriteString(item)
		if i < len(entries)-1 {
			b.WriteString("\n")
		}
	}

	return b.String()
}

func formatHistoryEntry(entry types.CallHistoryEntry, isSelected bool, width int) string {
	icon := getStatusIcon(entry.Result != nil && entry.Result.Success)
	timeStr := entry.Timestamp.Format("15:04:05")
	callType := entry.Parameters.CallType

	from := formatAddress(entry.Parameters.Caller, 6)
	to := formatAddress(entry.Parameters.Target, 6)

	title := fmt.Sprintf("%s %s %s %s→%s", icon, timeStr, callType, from, to)

	var details []string
	if entry.Result != nil {
		if gasLimit, err := strconv.ParseUint(entry.Parameters.GasLimit, 10, 64); err == nil {
			gasUsed := gasLimit - entry.Result.GasLeft
			gas := formatGas(gasUsed)
			if gas != "" {
				details = append(details, fmt.Sprintf("Gas: %s", gas))
			}
		}
	}
	if entry.Parameters.Value != "" && entry.Parameters.Value != "0" {
		details = append(details, fmt.Sprintf("Value: %s", entry.Parameters.Value))
	}

	description := ""
	if len(details) > 0 {
		description = strings.Join(details, " • ")
	}

	itemStyle := config.NormalStyle
	if isSelected {
		itemStyle = config.SelectedStyle
	}

	entryBox := itemStyle.
		Width(width - 4).
		Padding(0, 1)

	var content strings.Builder
	content.WriteString(title)
	if description != "" {
		content.WriteString("\n")
		content.WriteString(config.DimmedStyle.Render("  " + description))
	}

	return entryBox.Render(content.String())
}

func getStatusIcon(success bool) string {
	if success {
		return config.SuccessStyle.Render("✓")
	}
	return config.ErrorStyle.Render("✗")
}

func formatAddress(addr string, chars int) string {
	if len(addr) < 2*chars+5 {
		return addr
	}
	if !strings.HasPrefix(addr, "0x") {
		addr = "0x" + addr
	}
	return fmt.Sprintf("%s…%s", addr[:2+chars], addr[len(addr)-chars:])
}

func formatGas(gas uint64) string {
	if gas < 1000 {
		return fmt.Sprintf("%d", gas)
	}
	if gas < 1000000 {
		return fmt.Sprintf("%.1fk", float64(gas)/1000)
	}
	return fmt.Sprintf("%.2fM", float64(gas)/1000000)
}

func RenderHistoryDetail(entry *types.CallHistoryEntry, width, height int) string {
	if entry == nil {
		return config.DimmedStyle.Render("No entry selected")
	}

	var b strings.Builder

	b.WriteString(config.LabelStyle.Render("Timestamp: "))
	b.WriteString(entry.Timestamp.Format("2006-01-02 15:04:05"))
	b.WriteString("\n\n")

	b.WriteString(config.LabelStyle.Render("Call Type: "))
	b.WriteString(entry.Parameters.CallType)
	b.WriteString("\n")

	b.WriteString(config.LabelStyle.Render("From: "))
	b.WriteString(entry.Parameters.Caller)
	b.WriteString("\n")

	if entry.Parameters.Target != "" {
		b.WriteString(config.LabelStyle.Render("To: "))
		b.WriteString(entry.Parameters.Target)
		b.WriteString("\n")
	}

	if entry.Parameters.Value != "" && entry.Parameters.Value != "0" {
		b.WriteString(config.LabelStyle.Render("Value: "))
		b.WriteString(entry.Parameters.Value)
		b.WriteString(" Wei")
		b.WriteString("\n")
	}

	b.WriteString("\n")
	b.WriteString(config.SubtitleStyle.Render("Result"))
	b.WriteString("\n")

	if entry.Result != nil {
		statusIcon := getStatusIcon(entry.Result.Success)
		b.WriteString(config.LabelStyle.Render("Status: "))
		b.WriteString(statusIcon)
		if entry.Result.Success {
			b.WriteString(" Success")
		} else {
			b.WriteString(" Failed")
		}
		b.WriteString("\n")

		b.WriteString(config.LabelStyle.Render("Gas Used: "))
		if gasLimit, err := strconv.ParseUint(entry.Parameters.GasLimit, 10, 64); err == nil {
			gasUsed := gasLimit - entry.Result.GasLeft
			b.WriteString(formatGas(gasUsed))
		} else {
			b.WriteString("0")
		}
		b.WriteString("\n")

		if entry.Result.ErrorInfo != "" {
			b.WriteString(config.LabelStyle.Render("Error: "))
			b.WriteString(config.ErrorStyle.Render(entry.Result.ErrorInfo))
			b.WriteString("\n")
		}

		outputData := entry.Result.Output
		if len(outputData) > 0 {
			b.WriteString("\n")
			b.WriteString(config.LabelStyle.Render("Output:"))
			b.WriteString("\n")
			outputHex := fmt.Sprintf("0x%x", outputData)
			b.WriteString(config.DimmedStyle.Render(outputHex))
			b.WriteString("\n")
		}

		if len(entry.Result.Logs) > 0 {
			b.WriteString("\n")
			b.WriteString(config.LabelStyle.Render(fmt.Sprintf("Logs (%d):", len(entry.Result.Logs))))
			b.WriteString("\n")
			for i, log := range entry.Result.Logs {
				b.WriteString(config.DimmedStyle.Render(fmt.Sprintf("  [%d] Topics: %d, Data: %d bytes", 
					i, len(log.Topics), len(log.Data))))
				b.WriteString("\n")
			}
		}
	}

	return b.String()
}