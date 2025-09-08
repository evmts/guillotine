package config

import (
	"github.com/charmbracelet/lipgloss"
)

var (
	Background = lipgloss.Color("#000000")
	Foreground = lipgloss.Color("#FAFAFA")
	Muted      = lipgloss.Color("#A1A1A1")
	Border     = lipgloss.Color("237")
	
	Amber      = lipgloss.Color("#FCD34D")
	AmberDark  = lipgloss.Color("#92400E")
	AmberLight = lipgloss.Color("#FEF3C7")
	
	ChartBlue   = lipgloss.Color("#3B82F6")
	ChartGreen  = lipgloss.Color("#84CC16")
	ChartYellow = lipgloss.Color("#EAB308")
	ChartPurple = lipgloss.Color("#9333EA")
	ChartOrange = lipgloss.Color("#F97316")
	
	Destructive = lipgloss.Color("#DC2626")
)

var (
	TitleStyle = lipgloss.NewStyle().
		Bold(true).
		Foreground(Background).
		Background(Amber).
		Padding(0, 3).
		MarginBottom(1)

	BoxStyle = lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(lipgloss.Color("236")).
		Padding(1, 3)

	SelectedItemStyle = lipgloss.NewStyle().
		Foreground(Background).
		Background(Amber).
		Bold(true).
		Padding(0, 1)

	NormalItemStyle = lipgloss.NewStyle().
		Foreground(Foreground)

	CheckedStyle = lipgloss.NewStyle().
		Foreground(ChartGreen).
		Bold(true)

	CursorStyle = lipgloss.NewStyle().
		Foreground(Amber).
		Bold(true)

	HelpStyle = lipgloss.NewStyle().
		Foreground(Muted).
		MarginTop(2)

	SubtitleStyle = lipgloss.NewStyle().
		Foreground(Muted).
		MarginBottom(1)
	
	LogoStyle = lipgloss.NewStyle().
		Foreground(Amber).
		Bold(true)
	
	IconStyle = lipgloss.NewStyle().
		Foreground(AmberLight)
)

func GetBoxStyle(width, height int) lipgloss.Style {
	return BoxStyle.
		Width(width - 4).
		Height(height - 4)
}

func GetGradientBorder() lipgloss.Style {
	return lipgloss.NewStyle().
		Border(lipgloss.DoubleBorder()).
		BorderForeground(Amber).
		BorderBackground(AmberDark)
}

func GetStatusStyle(status string) lipgloss.Style {
	switch status {
	case "success":
		return lipgloss.NewStyle().Foreground(ChartGreen)
	case "error":
		return lipgloss.NewStyle().Foreground(Destructive)
	case "warning":
		return lipgloss.NewStyle().Foreground(ChartOrange)
	case "info":
		return lipgloss.NewStyle().Foreground(ChartBlue)
	default:
		return lipgloss.NewStyle().Foreground(Muted)
	}
}