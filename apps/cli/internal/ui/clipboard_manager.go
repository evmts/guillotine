package ui

import (
	"fmt"
	"guillotine-cli/internal/core/evm"
	"regexp"
	"strconv"
	"strings"

	"github.com/atotto/clipboard"
)

type ClipboardManager struct {
	lastCopied string
	lastPasted string
}

var clipboardMgr = &ClipboardManager{}

// GetClipboard returns the raw clipboard content
func GetClipboard() (string, error) {
	content, err := clipboard.ReadAll()
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(content), nil
}

func PasteToField(fieldType string) (string, error) {
	content, err := clipboard.ReadAll()
	if err != nil {
		return "", err
	}

	cleaned := strings.TrimSpace(content)

	switch fieldType {
	case "address":
		if evm.IsValidAddress(cleaned) {
			clipboardMgr.lastPasted = cleaned
			return cleaned, nil
		}
		if addr := extractAddress(cleaned); addr != "" {
			clipboardMgr.lastPasted = addr
			return addr, nil
		}
		return "", fmt.Errorf("invalid address format in clipboard")

	case "hex":
		if evm.IsValidHex(cleaned) {
			return cleaned, nil
		}
		if evm.IsValidHex("0x" + cleaned) {
			return "0x" + cleaned, nil
		}
		return "", fmt.Errorf("invalid hex format in clipboard")

	case "number":
		cleaned = strings.ReplaceAll(cleaned, ",", "")
		cleaned = strings.ReplaceAll(cleaned, "_", "")
		_, err := strconv.ParseUint(cleaned, 10, 64)
		if err == nil {
			return cleaned, nil
		}
		return "", fmt.Errorf("invalid number format in clipboard")

	default:
		return cleaned, nil
	}
}

func extractAddress(text string) string {
	re := regexp.MustCompile(`0x[a-fA-F0-9]{40}`)
	if match := re.FindString(text); match != "" {
		return match
	}
	return ""
}

func CopyWithFeedback(content string) (string, error) {
	err := clipboard.WriteAll(content)
	if err != nil {
		return "✗ Copy failed", err
	}

	clipboardMgr.lastCopied = content

	if len(content) > 42 {
		return fmt.Sprintf("✓ Copied %d bytes", len(content)), nil
	}
	return "✓ Copied to clipboard", nil
}

