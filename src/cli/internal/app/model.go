package app

import (
	"guillotine-cli/internal/core/evm"
	"guillotine-cli/internal/core/history"
	"guillotine-cli/internal/types"

	"github.com/charmbracelet/bubbles/table"
	"github.com/charmbracelet/bubbles/textinput"
	gevmTypes "github.com/evmts/guillotine/bindings/go/evm"
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
	callParams        types.CallParameters
	callParamCursor   int
	editingParam      string
	textInput         textinput.Model
	validationError   string
	callResult        *gevmTypes.CallResult
	callTypeSelector  int
	
	// Managers
	vmManager      *evm.VMManager
	historyManager *history.HistoryManager
	
	// View states
	historyTable       table.Model
	contractsTable     table.Model
	logsTable          table.Model
	selectedHistoryID  string
	selectedContract   string
	selectedLogIndex   int
	
	// UI state
	showCopyFeedback   bool
	copyFeedbackMsg    string
}