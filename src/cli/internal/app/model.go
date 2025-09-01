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
			if m.choices[m.cursor] == config.MenuExit {
				m.quitting = true
				return m, tea.Batch(
					tea.ExitAltScreen,
					tea.Quit,
				)
			}
			_, ok := m.selected[m.cursor]
			if ok {
				delete(m.selected, m.cursor)
			} else {
				m.selected[m.cursor] = struct{}{}
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
	menu := ui.RenderMenu(m.choices, m.cursor, m.selected)
	help := ui.RenderHelpText()
	
	content := layout.ComposeVertical(header, menu, help)
	
	return layout.RenderWithBox(content)
}