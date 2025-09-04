package app

import (
	"guillotine-cli/internal/config"
	"guillotine-cli/internal/types"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

func TestInitialModel(t *testing.T) {
	model := InitialModel()

	// Test initial state
	if model.state != types.StateMainMenu {
		t.Errorf("Expected initial state to be MainMenu, got %v", model.state)
	}

	// Test greeting
	if model.greeting != config.AppTitle {
		t.Errorf("Expected greeting to be %s, got %s", config.AppTitle, model.greeting)
	}

	// Test choices
	expectedChoices := config.GetMenuItems()
	if len(model.choices) != len(expectedChoices) {
		t.Errorf("Expected %d choices, got %d", len(expectedChoices), len(model.choices))
	}

	// Test call parameters initialization
	if model.callParams.CallType == "" {
		t.Error("Call parameters not initialized properly")
	}

	// Test managers initialization
	if model.vmManager == nil {
		t.Error("VM manager not initialized")
	}

	if model.historyManager == nil {
		t.Error("History manager not initialized")
	}

	// Test tables initialization
	if model.historyTable.Cursor() != 0 {
		t.Error("History table not initialized properly")
	}

	if model.contractsTable.Cursor() != 0 {
		t.Error("Contracts table not initialized properly")
	}
}

func TestModel_Init(t *testing.T) {
	model := InitialModel()
	cmd := model.Init()

	if cmd == nil {
		t.Error("Init() should return a command")
	}

	// Init should return a batch of commands
	// We can't easily test the specific commands, but we verify it's not nil
}

func TestModel_Update_WindowSize(t *testing.T) {
	model := InitialModel()

	// Send window size message
	msg := tea.WindowSizeMsg{Width: 80, Height: 24}
	newModel, _ := model.Update(msg)

	m := newModel.(Model)
	if m.width != 80 {
		t.Errorf("Expected width to be 80, got %d", m.width)
	}

	if m.height != 24 {
		t.Errorf("Expected height to be 24, got %d", m.height)
	}
}

func TestModel_View(t *testing.T) {
	model := InitialModel()
	model.width = 80
	model.height = 24

	// Test that View returns a non-empty string
	view := model.View()
	if view == "" {
		t.Error("View() should return non-empty string")
	}

	// Test quitting state
	model.quitting = true
	view = model.View()
	// The actual View() creates a new style with specific settings
	goodbyeStyle := lipgloss.NewStyle().
		Foreground(config.Amber).
		Bold(true).
		Padding(1, 2)
	expected := goodbyeStyle.Render(config.GoodbyeMessage)
	if view != expected {
		t.Errorf("View() should return goodbye message when quitting. Got: %q, Expected: %q", view, expected)
	}
}