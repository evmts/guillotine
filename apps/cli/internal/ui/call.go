package ui

import (
	"fmt"
	"guillotine-cli/internal/config"
	"guillotine-cli/internal/types"
	"strconv"
	"strings"

	"github.com/charmbracelet/lipgloss"
	guillotine "github.com/evmts/guillotine/sdks/go"
)

func RenderCallParameterList(params []types.CallParameter, cursor int, validationError string) string {
	var items []string
	
	for i, param := range params {
		prefix := "  "
		if i == cursor {
			prefix = "▸ "
		}
		
		nameStyle := lipgloss.NewStyle().Bold(true).Foreground(config.Amber)
		valueStyle := lipgloss.NewStyle().Foreground(lipgloss.Color("#888888"))
		
		name := nameStyle.Render(param.Name)
		value := valueStyle.Render(param.Value)
		
		if i == cursor {
			name = lipgloss.NewStyle().Bold(true).Foreground(config.Background).Background(config.Amber).Render(param.Name)
		}
		
		line := prefix + name + " : " + value
		items = append(items, line)
	}
	
	content := strings.Join(items, "\n")
	
	// Add validation error if present
	if validationError != "" {
		content += "\n\n"
		errorStyle := lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("#FF6B6B"))
		content += errorStyle.Render("Error: " + validationError)
	}
	
	return content
}

func RenderCallParameterEdit(paramName, currentValue string) string {
	titleStyle := lipgloss.NewStyle().Bold(true).Foreground(config.Amber)
	title := titleStyle.Render("Edit " + paramName)
	
	inputStyle := lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(config.ChartGreen).
		Padding(0, 1).
		Width(50)
	
	input := inputStyle.Render(currentValue + "_")
	
	content := title + "\n\n" + input
	
	boxStyle := lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(config.Amber).
		Padding(2).
		Width(60)
	
	return boxStyle.Render(content)
}

func RenderCallResult(result *guillotine.CallResult, params types.CallParametersStrings) string {
	var content strings.Builder
	
	successStyle := lipgloss.NewStyle().Bold(true).Foreground(config.ChartGreen)
	errorStyle := lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("#FF6B6B"))
	labelStyle := lipgloss.NewStyle().Bold(true)
	
	if result.Success {
		content.WriteString(successStyle.Render("✓ Call Successful"))
	} else {
		content.WriteString(errorStyle.Render("✗ Call Failed"))
	}
	
	content.WriteString("\n\n")
	
	// Always show gas used
	content.WriteString(labelStyle.Render("Gas Used: "))
	if gasLimit, err := strconv.ParseUint(params.GasLimit, 10, 64); err == nil {
		gasUsed := gasLimit - result.GasLeft
		content.WriteString(lipgloss.NewStyle().Render(formatNumber(gasUsed)))
	} else {
		content.WriteString(lipgloss.NewStyle().Render("0"))
	}
	content.WriteString("\n")
	
	// Show error first if failed
	if !result.Success && result.ErrorInfo != "" {
		content.WriteString("\n")
		content.WriteString(errorStyle.Render("Error: "))
		content.WriteString(lipgloss.NewStyle().Foreground(lipgloss.Color("#FF6B6B")).Render(result.ErrorInfo))
		content.WriteString("\n")
	}
	
	// Show output if available (even for failed calls)
	if len(result.Output) > 0 {
		content.WriteString("\n")
		content.WriteString(labelStyle.Render("Output: "))
		content.WriteString(lipgloss.NewStyle().Foreground(lipgloss.Color("#888888")).Render(formatHex(result.Output)))
		content.WriteString("\n")
	}
	
	// Show logs if available
	if len(result.Logs) > 0 {
		content.WriteString("\n")
		content.WriteString(labelStyle.Render("Logs: "))
		content.WriteString(lipgloss.NewStyle().Render(formatNumber(uint64(len(result.Logs)))))
		content.WriteString(" entries\n")
	}
	
	// Show created address for CREATE/CREATE2
	if result.CreatedAddress != nil {
		content.WriteString("\n")
		content.WriteString(labelStyle.Render("Created Address: "))
		content.WriteString(lipgloss.NewStyle().Foreground(config.ChartGreen).Render(result.CreatedAddress.String()))
		content.WriteString("\n")
	}
	
	return content.String()
}

func formatNumber(n uint64) string {
	return lipgloss.NewStyle().Render(fmt.Sprintf("%d", n))
}

func formatHex(data []byte) string {
	if len(data) == 0 {
		return "0x"
	}
	
	return fmt.Sprintf("0x%x", data)
}