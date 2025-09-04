package app

import (
	"guillotine-cli/internal/core/evm"
	"guillotine-cli/internal/core/history"
	"guillotine-cli/internal/types"

	"github.com/charmbracelet/bubbles/table"
	"github.com/charmbracelet/bubbles/textinput"
	guillotine "github.com/evmts/guillotine/sdks/go"
)

type Model struct {
	greeting string
	cursor   int
	choices  []string
	quitting bool
	width    int
	height   int
	
	// Call-related state
	state             types.AppState
	callParams        types.CallParametersStrings
	callParamCursor   int
	editingParam      string
	textInput         textinput.Model
	validationError   string
	callResult        *guillotine.CallResult
	callTypeSelector  int
	
	// Managers
	vmManager      *evm.VMManager
	historyManager *history.HistoryManager
	
	// View states
	historyTable       table.Model
	contractsTable     table.Model
	selectedHistoryID  string
	selectedContract   string
	
	// UI state
	showCopyFeedback   bool
	copyFeedbackMsg    string
}
