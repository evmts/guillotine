package utils

import (
	"strings"
)

// InputSanitizer provides consistent input sanitization
type InputSanitizer struct{}

// NewInputSanitizer creates a new sanitizer instance
func NewInputSanitizer() *InputSanitizer {
	return &InputSanitizer{}
}

// SanitizeAddress cleans and normalizes Ethereum addresses
func (s *InputSanitizer) SanitizeAddress(address string) string {
	// Remove spaces and convert to lowercase
	cleaned := strings.TrimSpace(strings.ToLower(address))
	
	// Add 0x prefix if missing
	if len(cleaned) == 40 && !strings.HasPrefix(cleaned, "0x") {
		cleaned = "0x" + cleaned
	}
	
	return cleaned
}

// SanitizeHexData cleans and normalizes hex data
func (s *InputSanitizer) SanitizeHexData(data string) string {
	// Remove spaces and convert to lowercase
	cleaned := strings.TrimSpace(strings.ToLower(data))
	
	// Handle empty data
	if cleaned == "" || cleaned == "0x" {
		return "0x"
	}
	
	// Add 0x prefix if missing
	if !strings.HasPrefix(cleaned, "0x") {
		cleaned = "0x" + cleaned
	}
	
	// Remove any non-hex characters after 0x
	if len(cleaned) > 2 {
		hexPart := cleaned[2:]
		validHex := ""
		for _, c := range hexPart {
			if (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') {
				validHex += string(c)
			}
		}
		cleaned = "0x" + validHex
	}
	
	return cleaned
}

// SanitizeNumeric removes non-numeric characters
func (s *InputSanitizer) SanitizeNumeric(value string) string {
	// Remove spaces
	cleaned := strings.TrimSpace(value)
	
	// Remove commas and underscores (common separators)
	cleaned = strings.ReplaceAll(cleaned, ",", "")
	cleaned = strings.ReplaceAll(cleaned, "_", "")
	cleaned = strings.ReplaceAll(cleaned, " ", "")
	
	// Extract only digits
	result := ""
	for _, c := range cleaned {
		if c >= '0' && c <= '9' {
			result += string(c)
		}
	}
	
	// Handle empty result
	if result == "" {
		return "0"
	}
	
	return result
}

// SanitizeSalt cleans and normalizes salt values for CREATE2
func (s *InputSanitizer) SanitizeSalt(salt string) string {
	// Use hex sanitization
	cleaned := s.SanitizeHexData(salt)
	
	// Pad with zeros if needed (salt should be 32 bytes = 64 hex chars)
	if len(cleaned) > 2 {
		hexPart := cleaned[2:]
		if len(hexPart) < 64 {
			hexPart = strings.Repeat("0", 64-len(hexPart)) + hexPart
		}
		cleaned = "0x" + hexPart
	} else {
		// Default salt if empty
		cleaned = "0x" + strings.Repeat("0", 64)
	}
	
	return cleaned
}

// SanitizeAll applies all appropriate sanitization based on field type
func (s *InputSanitizer) SanitizeAll(fieldType, value string) string {
	switch fieldType {
	case "address", "caller", "target":
		return s.SanitizeAddress(value)
	case "hex", "input", "data", "bytecode":
		return s.SanitizeHexData(value)
	case "salt":
		return s.SanitizeSalt(value)
	case "number", "gas", "value", "gas_limit":
		return s.SanitizeNumeric(value)
	default:
		return strings.TrimSpace(value)
	}
}