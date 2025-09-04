package ui

import (
	"fmt"
	"strings"

	"guillotine-cli/internal/config"

	"github.com/charmbracelet/lipgloss"
)

// InputField represents a form input field type
type InputField int

const (
	FromField InputField = iota
	ToField
	ValueField
	CalldataField
	GasField
)

// CallInputState represents the state for call input form
type CallInputState struct {
	FromAddress string
	ToAddress   string
	Value       string
	Calldata    string
	Gas         string
	ActiveField InputField
	Errors      map[InputField]string
}

// RenderCallInputForm renders the call input form
func RenderCallInputForm(state CallInputState) string {
	var sections []string

	// Title
	title := config.TitleStyle.Render("Make Call")
	sections = append(sections, title)
	sections = append(sections, "")

	// From Address field
	sections = append(sections, renderInputField("From Address:", state.FromAddress, FromField, state.ActiveField, state.Errors))

	// To Address field
	sections = append(sections, renderInputField("To Address:", state.ToAddress, ToField, state.ActiveField, state.Errors))

	// Value field
	sections = append(sections, renderInputField("Value (wei):", state.Value, ValueField, state.ActiveField, state.Errors))

	// Calldata field
	sections = append(sections, renderInputField("Calldata:", state.Calldata, CalldataField, state.ActiveField, state.Errors))

	// Gas field
	sections = append(sections, renderInputField("Gas:", state.Gas, GasField, state.ActiveField, state.Errors))

	// Instructions
	sections = append(sections, "")
	instructions := []string{
		"Tab: Next field",
		"Shift+Tab: Previous field",
		"Enter: Execute call",
		"Esc: Back to menu",
	}
	instructionsText := config.HelpStyle.Render(strings.Join(instructions, "  •  "))
	sections = append(sections, instructionsText)

	return lipgloss.JoinVertical(lipgloss.Left, sections...)
}

// renderInputField renders a single input field with label, value, and error state
func renderInputField(label, value string, field, activeField InputField, errors map[InputField]string) string {
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
	if err, hasError := errors[field]; hasError {
		inputStyle = inputStyle.BorderForeground(lipgloss.Color("9")) // Red
		value = value + fmt.Sprintf(" (%s)", err)
	}

	// Add cursor if this is the active field
	displayValue := value
	if field == activeField && len(errors) == 0 {
		displayValue = value + "█"
	}

	inputBox := inputStyle.
		Width(60).
		Height(1).
		Padding(0, 1).
		Render(displayValue)
	sections = append(sections, inputBox)
	sections = append(sections, "")

	return lipgloss.JoinVertical(lipgloss.Left, sections...)
}

// RenderCallInputError renders an error message for the call input form
func RenderCallInputError(err string) string {
	errorStyle := lipgloss.NewStyle().
		Foreground(lipgloss.Color("9")).
		Bold(true).
		Padding(1, 2)

	return errorStyle.Render("Error: " + err)
}

// RenderCallInputSuccess renders a success message
func RenderCallInputSuccess(message string) string {
	successStyle := lipgloss.NewStyle().
		Foreground(lipgloss.Color("10")).
		Bold(true).
		Padding(1, 2)

	return successStyle.Render("Success: " + message)
}