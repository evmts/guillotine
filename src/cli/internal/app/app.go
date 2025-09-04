package app

import (
	"fmt"
	"guillotine-cli/internal/config"
	"guillotine-cli/internal/core/history"
	"guillotine-cli/internal/core/state"
	"guillotine-cli/internal/core/evm"
	"guillotine-cli/internal/types"
	"guillotine-cli/internal/ui"

	tea "github.com/charmbracelet/bubbletea"
)

func InitialModel() Model {
	vmMgr, err := evm.GetVMManager()
	if err != nil {
		panic(fmt.Sprintf("Failed to initialize VM: %v", err))
	}
	
	historyMgr := history.NewHistoryManager(1000)
	
	// Load and replay state
	if stateFile, err := state.LoadStateFile(state.GetStateFilePath()); err == nil {
		stateReplayer := state.NewStateReplayer(vmMgr, historyMgr)
		if err := stateReplayer.ReplayState(stateFile.Calls); err != nil {
			fmt.Printf("Warning: Failed to replay some calls: %v\n", err)
		}
	}
	
	return Model{
		greeting:    config.AppTitle,
		choices:     config.GetMenuItems(),
		state:       types.StateMainMenu,
		callParams:  NewCallParameters(),
		vmManager:      vmMgr,
		historyManager: historyMgr,
		historyTable:   ui.CreateHistoryTable(),
		contractsTable: ui.CreateContractsTable(),
	}
}

func (m Model) Init() tea.Cmd {
	return tea.Batch(
		tea.EnterAltScreen,
		tea.ClearScreen,
	)
}