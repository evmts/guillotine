package ui

import (
	"guillotine-cli/internal/config"
	"strings"

	"github.com/charmbracelet/bubbles/textinput"
	"github.com/charmbracelet/lipgloss"
)

// ComponentFactory provides factory methods for creating UI components
type ComponentFactory struct{}

// NewComponentFactory creates a new component factory
func NewComponentFactory() *ComponentFactory {
	return &ComponentFactory{}
}

// CreateStyledTextInput creates a configured text input component
// (Note: CreateTextInput already exists in call_input.go)
func (cf *ComponentFactory) CreateStyledTextInput(placeholder, initialValue string) textinput.Model {
	ti := textinput.New()
	ti.Placeholder = placeholder
	ti.SetValue(initialValue)
	ti.Focus()
	ti.CharLimit = 256
	ti.Width = 60
	return ti
}

// CreateBox creates a styled box with content
func (cf *ComponentFactory) CreateBox(content string, width int) string {
	boxStyle := config.BoxStyle.Copy().Width(width)
	return boxStyle.Render(content)
}

// CreateList creates a formatted list from items
func (cf *ComponentFactory) CreateList(items []string, selectedIndex int) string {
	var builder strings.Builder
	for i, item := range items {
		if i == selectedIndex {
			builder.WriteString(config.SelectedItemStyle.Render("> " + item))
		} else {
			builder.WriteString(config.NormalStyle.Render("  " + item))
		}
		if i < len(items)-1 {
			builder.WriteString("\n")
		}
	}
	return builder.String()
}

// CreateHeader creates a styled header with title and subtitle
func (cf *ComponentFactory) CreateHeader(title, subtitle string) string {
	titleStyle := config.TitleStyle.Copy()
	subtitleStyle := config.SubtitleStyle.Copy()
	
	titleLine := titleStyle.Render(title)
	subtitleLine := ""
	if subtitle != "" {
		subtitleLine = "\n" + subtitleStyle.Render(subtitle)
	}
	
	return titleLine + subtitleLine
}

// CreateErrorMessage creates a formatted error message
func (cf *ComponentFactory) CreateErrorMessage(err error) string {
	if err == nil {
		return ""
	}
	errorStyle := lipgloss.NewStyle().
		Foreground(config.Destructive).
		Bold(true)
	return errorStyle.Render("❌ " + err.Error())
}

// CreateSuccessMessage creates a formatted success message
func (cf *ComponentFactory) CreateSuccessMessage(msg string) string {
	successStyle := lipgloss.NewStyle().
		Foreground(config.Success).
		Bold(true)
	return successStyle.Render("✓ " + msg)
}

// CreateWarningMessage creates a formatted warning message
func (cf *ComponentFactory) CreateWarningMessage(msg string) string {
	warningStyle := lipgloss.NewStyle().
		Foreground(config.Amber).
		Bold(true)
	return warningStyle.Render("⚠ " + msg)
}

// CreateKeyValue creates a formatted key-value pair display
func (cf *ComponentFactory) CreateKeyValue(key, value string) string {
	keyStyle := lipgloss.NewStyle().
		Foreground(config.Amber).
		Bold(true)
	valueStyle := config.NormalStyle.Copy()
	
	return keyStyle.Render(key+":") + " " + valueStyle.Render(value)
}

// CreateSection creates a section with title and content
func (cf *ComponentFactory) CreateSection(title, content string) string {
	sectionStyle := lipgloss.NewStyle().
		BorderStyle(lipgloss.NormalBorder()).
		BorderForeground(config.Muted).
		Padding(1).
		MarginTop(1)
	
	titleStyle := lipgloss.NewStyle().
		Foreground(config.Amber).
		Bold(true).
		MarginBottom(1)
	
	return sectionStyle.Render(
		titleStyle.Render(title) + "\n" + content,
	)
}

// CreateProgressBar creates a simple progress bar
func (cf *ComponentFactory) CreateProgressBar(current, total, width int) string {
	if total == 0 {
		return ""
	}
	
	filled := (current * width) / total
	if filled > width {
		filled = width
	}
	
	bar := strings.Repeat("█", filled)
	empty := strings.Repeat("░", width-filled)
	
	progressStyle := lipgloss.NewStyle().
		Foreground(config.Success)
	emptyStyle := lipgloss.NewStyle().
		Foreground(config.Muted)
	
	return progressStyle.Render(bar) + emptyStyle.Render(empty)
}