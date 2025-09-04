package config

// Key bindings for the application
var (
	KeyQuit      = []string{"ctrl+c"}
	KeyUp        = []string{"up", "k"}
	KeyDown      = []string{"down", "j"}
	KeySelect    = []string{"enter", " "}
	KeyBack      = []string{"esc"}
	KeyExecute   = []string{"x", "ctrl+enter"}
	KeyEdit      = []string{"enter"}
	KeySave      = []string{"enter"}
	KeyCancel    = []string{"esc"}
	KeyReset     = []string{"r"}
	KeyResetAll  = []string{"ctrl+r"}
	KeyPaste     = []string{"ctrl+v"}
	KeyCopy      = []string{"c", "ctrl+c"}
)

// IsKey checks if a message matches any of the given key bindings
func IsKey(msg string, keys []string) bool {
	for _, k := range keys {
		if msg == k {
			return true
		}
	}
	return false
}