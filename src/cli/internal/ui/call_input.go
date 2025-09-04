package ui

import (
	"guillotine-cli/internal/config"

	"github.com/charmbracelet/lipgloss"
)

// CallInputData represents the data needed to render the call input form
type CallInputData struct {
	From  string
	To    string
	Value string
	Data  string
}

// RenderCallInputForm renders a minimal call input form for demo purposes
// TODO: Add field navigation, input validation, error display
// TODO: Add proper form styling and layout
// TODO: Connect to Zig CallParams for actual execution
func RenderCallInputForm(data CallInputData) string {
	formStyle := lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(config.Amber).
		Padding(1, 2)
		
	labelStyle := lipgloss.NewStyle().
		Bold(true).
		Foreground(config.ChartGreen)
		
	// Simple form layout - in real implementation would have:
	// - Field navigation (Tab/Shift+Tab)  
	// - Input validation and error display
	// - Auto-completion for addresses
	// - Unit conversion for value (wei/gwei/ether)
	content := lipgloss.JoinVertical(lipgloss.Left,
		labelStyle.Render("📞 Make EVM Call"),
		"",
		labelStyle.Render("From:"),
		"  " + data.From + " (TODO: hex address validation)",
		"",
		labelStyle.Render("To:"),
		"  " + data.To + " (TODO: hex address validation)",
		"",
		labelStyle.Render("Value:"), 
		"  " + data.Value + " (TODO: u256 parsing & unit conversion)",
		"",
		labelStyle.Render("Calldata:"),
		"  " + data.Data + " (TODO: hex bytes validation)",
		"",
		config.HelpStyle.Render("TODO: Press Enter to execute call"),
		config.HelpStyle.Render("TODO: ESC to return to menu"),
	)
	
	return formStyle.Render(content)
}

// CallParamsConversion demonstrates how this would connect to Zig EVM
// TODO: Bridge to call_params.zig - example conversion:
//
//   zigCallParams := CallParams{
//     .call = .{
//       .caller = parseAddress(data.From),     // Address validation
//       .to = parseAddress(data.To),           // Address validation  
//       .value = parseU256(data.Value),        // Wei amount parsing
//       .input = parseHexBytes(data.Data),     // Calldata validation
//       .gas = DEFAULT_GAS_LIMIT,              // Gas estimation/manual
//     },
//   }
//
// TODO: Call evm.execute(zigCallParams) and display CallResult
// TODO: Show gas usage, return data, execution trace, etc.