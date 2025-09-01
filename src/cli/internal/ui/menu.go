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

func RenderMenuItem(item MenuItem, isCurrent bool, isChecked bool) string {
	cursor := "  "
	checked := " "
	
	if isChecked {
		checked = config.CheckedStyle.Render("✓")
	}
	
	if isCurrent {
		cursor = config.CursorStyle.Render("▸ ")
		choiceText := config.SelectedItemStyle.Render(" " + item.Label + " ")
		return fmt.Sprintf("%s[%s] %s", cursor, checked, choiceText)
	}
	
	return config.NormalItemStyle.Render(fmt.Sprintf("  [%s] %s", checked, item.Label))
}

func RenderMenu(items []string, currentIndex int, selected map[int]struct{}) string {
	menuItems := ""
	for i, choice := range items {
		_, isSelected := selected[i]
		line := RenderMenuItem(
			MenuItem{Label: choice},
			i == currentIndex,
			isSelected,
		)
		menuItems += line + "\n"
	}
	return menuItems
}