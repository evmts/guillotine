package app

import (
	"guillotine-cli/internal/config"
	"guillotine-cli/internal/ui"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

type Model struct {
	greeting string
	cursor   int
	choices  []string
	selected map[int]struct{}
	quitting bool
	width    int
	height   int
	
	// Call Input state - minimal devtool demo
	showCallInput bool
	callFrom      string  // TODO: Validate as hex address
	callTo        string  // TODO: Validate as hex address  
	callValue     string  // TODO: Parse as u256
	callData      string  // TODO: Validate as hex bytes
}

func InitialModel() Model {
	return Model{
		greeting: config.AppTitle,
		choices:  config.GetMenuItems(),
		selected: make(map[int]struct{}),
	}
}

func (m Model) Init() tea.Cmd {
	return tea.Batch(
		tea.EnterAltScreen,
		tea.ClearScreen,
	)
}

func (m Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height
		return m, nil

	case tea.KeyMsg:
		msgStr := msg.String()
		
		if config.IsKey(msgStr, config.KeyQuit) {
			m.quitting = true
			return m, tea.Batch(
				tea.ExitAltScreen,
				tea.Quit,
			)
		}

		if config.IsKey(msgStr, config.KeyUp) {
			if m.cursor > 0 {
				m.cursor--
			}
		}

		if config.IsKey(msgStr, config.KeyDown) {
			if m.cursor < len(m.choices)-1 {
				m.cursor++
			}
		}

		if config.IsKey(msgStr, config.KeySelect) {
			switch m.choices[m.cursor] {
			case config.MenuExit:
				m.quitting = true
				return m, tea.Batch(
					tea.ExitAltScreen,
					tea.Quit,
				)
			case config.MenuMakeCall:
				// TODO: Implement full call input form with navigation
				// TODO: Add input validation and error handling
				// TODO: Bridge to Zig EVM CallParams system
				m.showCallInput = !m.showCallInput  // Simple toggle for demo
			default:
				// Original selection behavior for other menu items
				_, ok := m.selected[m.cursor]
				if ok {
					delete(m.selected, m.cursor)
				} else {
					m.selected[m.cursor] = struct{}{}
				}
			}
		}
	}

	return m, nil
}

func (m Model) View() string {
	if m.quitting {
		goodbyeStyle := lipgloss.NewStyle().
			Foreground(config.Amber).
			Bold(true).
			Padding(1, 2)
		return goodbyeStyle.Render(config.GoodbyeMessage)
	}

	if m.width == 0 || m.height == 0 {
		return config.LoadingMessage
	}

	layout := ui.Layout{Width: m.width, Height: m.height}
	
	header := ui.RenderHeader(m.greeting, config.AppSubtitle, config.TitleStyle, config.SubtitleStyle)
	
	var content string
	if m.showCallInput {
		// Show call input form - minimal demo implementation
		// TODO: Add proper form state management
		// TODO: Handle keyboard input for form fields  
		// TODO: Add field validation and error display
		callData := ui.CallInputData{
			From:  m.callFrom,   // TODO: Default to user's address
			To:    m.callTo,     // TODO: Support ENS resolution  
			Value: m.callValue,  // TODO: Support unit conversion
			Data:  m.callData,   // TODO: Support function selector encoding
		}
		callForm := ui.RenderCallInputForm(callData)
		content = layout.ComposeVertical(header, callForm)
	} else {
		// Show regular menu
		menu := ui.RenderMenu(m.choices, m.cursor, m.selected)
		help := ui.RenderHelpText()
		content = layout.ComposeVertical(header, menu, help)
	}
	
	return layout.RenderWithBox(content)
}