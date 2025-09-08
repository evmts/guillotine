package ui

import (
	"strings"
	"guillotine-cli/internal/config"
	"github.com/charmbracelet/lipgloss"
)

type Layout struct {
	Width  int
	Height int
}

func (l Layout) RenderWithBox(content string) string {
	boxStyle := config.GetBoxStyle(l.Width, l.Height)
	fullContent := boxStyle.Render(content)
	
	fullContent = l.centerHorizontally(fullContent)
	fullContent = l.centerVertically(fullContent)
	
	return fullContent
}

func (l Layout) ComposeVertical(header, menu, help string) string {
	headerHeight := 3
	menuHeight := strings.Count(menu, "\n") + 1
	helpHeight := 1
	contentHeight := headerHeight + menuHeight + helpHeight
	availableSpace := l.Height - 6
	
	spaceBetween := availableSpace - contentHeight
	if spaceBetween < 0 {
		spaceBetween = 1
	}
	
	topSection := header + "\n" + menu
	middleSpace := strings.Repeat("\n", spaceBetween)
	
	return topSection + middleSpace + help
}

func (l Layout) centerHorizontally(content string) string {
	horizontalPadding := (l.Width - lipgloss.Width(content)) / 2
	if horizontalPadding > 0 {
		lines := strings.Split(content, "\n")
		for i, line := range lines {
			if line != "" {
				lines[i] = strings.Repeat(" ", horizontalPadding) + line
			}
		}
		return strings.Join(lines, "\n")
	}
	return content
}

func (l Layout) centerVertically(content string) string {
	// Add just 1 line of margin at the top to keep box on screen
	verticalMargin := 1
	return strings.Repeat("\n", verticalMargin) + content
}