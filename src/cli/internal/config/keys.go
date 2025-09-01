package config

type KeyBinding struct {
	Key         string
	Description string
}

var (
	KeyQuit   = []string{"ctrl+c", "q"}
	KeyUp     = []string{"up", "k"}
	KeyDown   = []string{"down", "j"}
	KeySelect = []string{"enter", " "}
)

// HelpBindings defines what we show in the help text at the bottom
var HelpBindings = []KeyBinding{
	{Key: "↑/k", Description: "up"},
	{Key: "↓/j", Description: "down"},
	{Key: "space", Description: "select"},
	{Key: "q", Description: "quit"},
}

func IsKey(msg string, keys []string) bool {
	for _, k := range keys {
		if msg == k {
			return true
		}
	}
	return false
}

func GetHelpText() ([]string, []string) {
	keys := make([]string, len(HelpBindings))
	descriptions := make([]string, len(HelpBindings))
	
	for i, binding := range HelpBindings {
		keys[i] = binding.Key
		descriptions[i] = binding.Description
	}
	
	return keys, descriptions
}