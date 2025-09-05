package config

// HelpEntry represents a single help item with key and action
type HelpEntry struct {
	Key    string
	Action string
}

// All help entries defined in one place
var HelpCatalog = map[string]HelpEntry{
	// Navigation
	"navigate":     {Key: "↑/k ↓/j", Action: "navigate"},
	"navigate_logs": {Key: "↑/k ↓/j", Action: "navigate logs"},
	
	// Selection and actions
	"select":       {Key: "enter", Action: "select"},
	"enter":        {Key: "enter", Action: "enter"},
	"edit":         {Key: "enter", Action: "edit"},
	"save":         {Key: "enter", Action: "save"},
	"view_details": {Key: "enter", Action: "view details"},
	"view_log_detail": {Key: "enter", Action: "view log details"},
	"continue":     {Key: "enter", Action: "continue"},
	
	// Execution
	"execute":      {Key: "x", Action: "execute"},
	
	// Clipboard
	"paste":        {Key: "ctrl+v", Action: "paste"},
	"copy":         {Key: "c", Action: "copy address"},
	
	// Reset
	"reset":        {Key: "r", Action: "reset"},
	"reset_all":    {Key: "ctrl+r", Action: "reset all"},
	"reset_default": {Key: "r", Action: "reset default"},
	
	// Navigation/Cancel
	"back":         {Key: "esc", Action: "back"},
	"cancel":       {Key: "esc", Action: "cancel"},
	"back_to_menu": {Key: "esc", Action: "back to menu"},
	
	// Quit
	"quit":         {Key: "ctrl+c", Action: "quit"},
}

// Define which help entries to show for each state (using string keys)
var StateHelpEntries = map[string][]string{
	"main_menu": {
		"navigate",
		"select",
		"quit",
	},
	"call_parameter_list": {
		"navigate",
		"edit",
		"execute",
		"reset",
		"reset_all",
		"back",
	},
	"call_parameter_edit": {
		"save",
		"paste",
		"reset_default",
		"cancel",
	},
	"call_type_selection": {
		"navigate",
		"save",
		"reset_default",
		"cancel",
	},
	"call_result": {
		"back_to_menu",
	},
	"call_history": {
		"navigate",
		"view_details",
		"back",
	},
	"call_history_detail": {
		"back",
	},
	"contracts": {
		"navigate",
		"view_details",
		"back",
	},
	"contract_detail": {
		"copy",
		"back",
	},
	"confirm_reset": {
		"enter",
		"cancel",
	},
	"log_detail": {
		"back",
	},
}

// GetHelpForState returns the help entries for a given state key
func GetHelpForState(stateKey string) []HelpEntry {
	keys, exists := StateHelpEntries[stateKey]
	if !exists {
		return nil
	}
	
	entries := make([]HelpEntry, 0, len(keys))
	for _, key := range keys {
		if entry, ok := HelpCatalog[key]; ok {
			entries = append(entries, entry)
		}
	}
	return entries
}

// GetHelpText converts help entries to parallel slices for rendering
func GetHelpText(entries []HelpEntry) ([]string, []string) {
	keys := make([]string, len(entries))
	actions := make([]string, len(entries))
	
	for i, entry := range entries {
		keys[i] = entry.Key
		actions[i] = entry.Action
	}
	
	return keys, actions
}

// GetHelpForStateWithLogs returns help entries for states that may have logs
func GetHelpForStateWithLogs(stateKey string, hasLogs bool) []HelpEntry {
	// Get base entries
	keys, exists := StateHelpEntries[stateKey]
	if !exists {
		return nil
	}
	
	// If there are logs, prepend log navigation entries
	if hasLogs && (stateKey == "call_result" || stateKey == "call_history_detail") {
		// Insert log navigation entries at the beginning
		keys = append([]string{"navigate_logs", "view_log_detail"}, keys...)
	}
	
	entries := make([]HelpEntry, 0, len(keys))
	for _, key := range keys {
		if entry, ok := HelpCatalog[key]; ok {
			entries = append(entries, entry)
		}
	}
	return entries
}