package ui

import (
	"fmt"
	"guillotine-cli/internal/config"
)

type MenuItem struct {
	Label    string
	Action   string
	Selected bool
}

func RenderMenuItem(item MenuItem, isCurrent bool) string {
	cursor := "  "
	
	if isCurrent {
		cursor = config.CursorStyle.Render("▸ ")
		choiceText := config.SelectedItemStyle.Render(" " + item.Label + " ")
		return fmt.Sprintf("%s%s", cursor, choiceText)
	}
	
	return config.NormalItemStyle.Render(fmt.Sprintf("   %s", item.Label))
}

func RenderMenu(items []string, currentIndex int) string {
	menuItems := ""
	for i, choice := range items {
		line := RenderMenuItem(
			MenuItem{Label: choice},
			i == currentIndex,
		)
		menuItems += line + "\n"
	}
	return menuItems
}