package main

import (
	"fmt"
	"os"

	"guillotine-cli/internal/app"

	tea "github.com/charmbracelet/bubbletea"
)

func main() {
	p := tea.NewProgram(app.InitialModel())
	if _, err := p.Run(); err != nil {
		fmt.Printf("Error running Guillotine CLI: %v", err)
		os.Exit(1)
	}
}