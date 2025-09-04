package ui

import (
	"fmt"
	"strings"

	"guillotine-cli/internal/config"

	"github.com/charmbracelet/lipgloss"
)

// RPCInputField represents an RPC input field type
type RPCInputField int

const (
	EndpointField RPCInputField = iota
	AddressField
	BlockField
)

// RPCInputState represents the state for RPC bytecode loading form
type RPCInputState struct {
	Endpoint    string
	Address     string
	Block       string
	ActiveField RPCInputField
	Errors      map[RPCInputField]string
	Loading     bool
}

// RenderRPCInputForm renders the RPC bytecode loading form
func RenderRPCInputForm(state RPCInputState) string {
	var sections []string

	// Title
	title := config.TitleStyle.Render("Load Bytecode from RPC")
	sections = append(sections, title)
	sections = append(sections, "")

	// Loading state
	if state.Loading {
		loadingStyle := lipgloss.NewStyle().
			Foreground(config.ChartBlue).
			Bold(true)
		sections = append(sections, loadingStyle.Render("🔄 Loading bytecode..."))
		sections = append(sections, "")
	}

	// RPC Endpoint field
	sections = append(sections, renderRPCInputField("RPC Endpoint:", state.Endpoint, EndpointField, state.ActiveField, state.Errors))

	// Contract Address field
	sections = append(sections, renderRPCInputField("Contract Address:", state.Address, AddressField, state.ActiveField, state.Errors))

	// Block field
	sections = append(sections, renderRPCInputField("Block:", state.Block, BlockField, state.ActiveField, state.Errors))

	// Instructions
	sections = append(sections, "")
	instructions := []string{
		"Tab: Next field",
		"Shift+Tab: Previous field", 
		"Enter: Load bytecode",
		"Esc: Back to menu",
	}
	instructionsText := config.HelpStyle.Render(strings.Join(instructions, "  •  "))
	sections = append(sections, instructionsText)

	// Examples
	sections = append(sections, "")
	examples := []string{
		"Example addresses:",
		"• USDC: 0xA0b86a33E6441C8C06DD3E7D1A0b5FD0D65bDe8F",
		"• WETH: 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2",
		"• Uniswap V2: 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f",
	}
	examplesText := config.SubtitleStyle.Render(strings.Join(examples, "\n"))
	sections = append(sections, examplesText)

	return lipgloss.JoinVertical(lipgloss.Left, sections...)
}

// renderRPCInputField renders a single RPC input field
func renderRPCInputField(label, value string, field, activeField RPCInputField, errors map[RPCInputField]string) string {
	var sections []string

	// Label
	labelStyle := config.SubtitleStyle
	if field == activeField {
		labelStyle = labelStyle.Foreground(config.Amber)
	}
	sections = append(sections, labelStyle.Render(label))

	// Input box
	inputStyle := config.BoxStyle
	if field == activeField {
		inputStyle = inputStyle.BorderForeground(config.Amber)
	}

	// Check for error
	displayValue := value
	if err, hasError := errors[field]; hasError {
		inputStyle = inputStyle.BorderForeground(lipgloss.Color("9")) // Red
		displayValue = fmt.Sprintf("%s ❌ %s", value, err)
	}

	// Add cursor if this is the active field and no error
	if field == activeField && len(errors) == 0 {
		displayValue = value + "█"
	}

	// Set appropriate width based on field type
	width := 60
	if field == EndpointField {
		width = 80 // RPC endpoints can be longer
	}

	inputBox := inputStyle.
		Width(width).
		Height(1).
		Padding(0, 1).
		Render(displayValue)
	sections = append(sections, inputBox)
	sections = append(sections, "")

	return lipgloss.JoinVertical(lipgloss.Left, sections...)
}

// RenderRPCLoadingState renders a loading indicator
func RenderRPCLoadingState(address string) string {
	loadingStyle := lipgloss.NewStyle().
		Foreground(config.ChartBlue).
		Bold(true).
		Padding(1, 2).
		Border(lipgloss.RoundedBorder()).
		BorderForeground(config.ChartBlue)

	content := fmt.Sprintf("🔄 Loading bytecode for:\n%s\n\nThis may take a few seconds...", address)
	return loadingStyle.Render(content)
}

// RenderRPCSuccess renders success message with bytecode info
func RenderRPCSuccess(address, bytecode string) string {
	successStyle := lipgloss.NewStyle().
		Foreground(config.ChartGreen).
		Bold(true).
		Padding(1, 2).
		Border(lipgloss.RoundedBorder()).
		BorderForeground(config.ChartGreen)

	// Show first 50 chars of bytecode
	preview := bytecode
	if len(preview) > 50 {
		preview = preview[:50] + "..."
	}

	content := fmt.Sprintf("✅ Successfully loaded bytecode!\n\nAddress: %s\nSize: %d bytes\nPreview: %s", 
		address, len(bytecode)/2-1, preview) // -1 for 0x prefix, /2 for hex
	
	return successStyle.Render(content)
}

// RenderRPCError renders error message
func RenderRPCError(err string) string {
	errorStyle := lipgloss.NewStyle().
		Foreground(lipgloss.Color("9")).
		Bold(true).
		Padding(1, 2).
		Border(lipgloss.RoundedBorder()).
		BorderForeground(lipgloss.Color("9"))

	content := fmt.Sprintf("❌ Failed to load bytecode:\n\n%s", err)
	return errorStyle.Render(content)
}