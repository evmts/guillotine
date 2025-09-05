package utils

import "strings"

// CleanMultilineForInput cleans multi-line content for single-line text input
func CleanMultilineForInput(content string) string {
	// First trim any leading/trailing whitespace
	cleaned := strings.TrimSpace(content)
	
	// Remove newlines and carriage returns
	cleaned = strings.ReplaceAll(cleaned, "\n", "")
	cleaned = strings.ReplaceAll(cleaned, "\r", "")
	
	// For hex strings (starting with 0x), don't modify internal content
	if strings.HasPrefix(cleaned, "0x") || strings.HasPrefix(cleaned, "0X") {
		// Just remove tabs and ensure it's properly trimmed
		cleaned = strings.ReplaceAll(cleaned, "\t", "")
		return cleaned
	}
	
	// For non-hex content, replace tabs with spaces and collapse multiple spaces
	cleaned = strings.ReplaceAll(cleaned, "\t", " ")
	for strings.Contains(cleaned, "  ") {
		cleaned = strings.ReplaceAll(cleaned, "  ", " ")
	}
	
	return cleaned
}