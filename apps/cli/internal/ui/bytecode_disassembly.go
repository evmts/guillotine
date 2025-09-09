package ui

import (
	"fmt"
	"strings"

	"guillotine-cli/internal/config"
	"guillotine-cli/internal/core/bytecode"

	"github.com/charmbracelet/bubbles/table"
	"github.com/charmbracelet/lipgloss"
)

// DisassemblyDisplayData contains data for rendering bytecode disassembly
type DisassemblyDisplayData struct {
	Result            *bytecode.DisassemblyResult
	CurrentBlockIndex int
	Width             int
	Height            int
}

// RenderBytecodeDisassembly renders the bytecode disassembly result
func RenderBytecodeDisassembly(result *bytecode.DisassemblyResult, width, height int) string {
	data := DisassemblyDisplayData{
		Result:            result,
		CurrentBlockIndex: 0,
		Width:             width,
		Height:            height,
	}
	return RenderBytecodeDisassemblyWithNavigation(data)
}

// RenderBytecodeDisassemblyWithNavigation renders disassembly with block navigation
func RenderBytecodeDisassemblyWithNavigation(data DisassemblyDisplayData) string {
	if data.Result == nil {
		return config.DimmedStyle.Render(config.NoDisassemblyAvailable)
	}

	var b strings.Builder

	// Title
	b.WriteString(config.SubtitleStyle.Render(config.BytecodeDisassemblyTitle))
	b.WriteString("\n")

	// Get instructions for current block
	instructions, blockInfo, _ := bytecode.GetInstructionsForBlock(data.Result, data.CurrentBlockIndex)
	
	// Render instructions as a scrollable table view
	tableView := renderInstructionsAsTable(instructions, data.Result.Analysis.JumpDests, 
		data.Width, data.Height-12)  // Reserve space for header, stats and indicator
	b.WriteString(tableView)
	
	// Calculate total gas for the block
	blockGas := bytecode.CalculateBlockGas(instructions)
	
	// Block indicator
	b.WriteString("\n\n")
	b.WriteString(renderBlockIndicator(data.CurrentBlockIndex, len(data.Result.Analysis.BasicBlocks), blockInfo, blockGas))

	return b.String()
}

// RenderBytecodeDisassemblyWithTable renders disassembly using a table component
func RenderBytecodeDisassemblyWithTable(data DisassemblyDisplayData, instructionTable table.Model) string {
	if data.Result == nil {
		return config.DimmedStyle.Render(config.NoDisassemblyAvailable)
	}

	var b strings.Builder

	// Title
	b.WriteString(config.SubtitleStyle.Render(config.BytecodeDisassemblyTitle))
	b.WriteString("\n")

	// Render the table view
	b.WriteString(instructionTable.View())
	
	// Get block info for indicator
	instructions, blockInfo, _ := bytecode.GetInstructionsForBlock(data.Result, data.CurrentBlockIndex)
	
	// Calculate total gas for the block
	blockGas := bytecode.CalculateBlockGas(instructions)
	
	// Block indicator
	b.WriteString("\n\n")
	b.WriteString(renderBlockIndicator(data.CurrentBlockIndex, len(data.Result.Analysis.BasicBlocks), blockInfo, blockGas))

	// Wrap everything in a box without forcing height
	content := b.String()
	boxStyle := config.BoxStyle.Copy().
		Padding(0, 1).        // Only horizontal padding, no vertical
		BorderForeground(config.Amber)
	
	return boxStyle.Render(content)
}

// renderInstructionsAsTable renders instructions in a scrollable table format
func renderInstructionsAsTable(instructions []bytecode.Instruction, jumpdests []uint32, 
	width, availableHeight int) string {
	
	if len(instructions) == 0 {
		return config.DimmedStyle.Render(config.NoInstructionsInBlock)
	}
	
	// Create jumpdest map for quick lookup
	jumpdestMap := make(map[uint32]bool)
	for _, j := range jumpdests {
		jumpdestMap[j] = true
	}
	
	var content strings.Builder
	
	// Table header
	headerStyle := lipgloss.NewStyle().Bold(true).Foreground(config.Amber)
	header := fmt.Sprintf("%-8s %-12s %-6s %-20s %-8s %-10s", 
		config.DisassemblyHeaderPC, config.DisassemblyHeaderOpcode, config.DisassemblyHeaderHex, 
		config.DisassemblyHeaderValue, config.DisassemblyHeaderGas, config.DisassemblyHeaderStack)
	content.WriteString(headerStyle.Render(header))
	content.WriteString("\n")
	
	// Calculate visible rows (account for header and some padding)
	maxRows := max(availableHeight - 2, 1)
	
	// Simple scrolling - show first N instructions
	// In the actual implementation with table component, scrolling will be handled by the table
	endIdx := min(len(instructions), maxRows)
	
	for i := 0; i < endIdx; i++ {
		inst := instructions[i]
		row := formatInstructionRow(inst, jumpdestMap)
		
		// Highlight based on opcode type
		rowStyle := config.NormalStyle
		if inst.OpcodeName == "JUMPDEST" {
			rowStyle = config.SuccessStyle
		} else if bytecode.ShouldHighlightOpcode(inst.OpcodeName) {
			rowStyle = config.AccentStyle
		} else if strings.HasPrefix(inst.OpcodeName, "JUMP") || inst.OpcodeName == "PC" {
			rowStyle = config.AccentStyle
		}
		
		content.WriteString(rowStyle.Render(row))
		if i < endIdx-1 {
			content.WriteString("\n")
		}
	}
	
	// Show scroll indicator if there are more instructions
	if len(instructions) > maxRows {
		content.WriteString("\n")
		content.WriteString(config.DimmedStyle.Render(
			fmt.Sprintf("... %d more instructions (use ↑/↓ to scroll)", len(instructions)-maxRows)))
	}
	
	return content.String()
}

// ConvertInstructionsToRows converts instructions to table rows for table component
func ConvertInstructionsToRows(instructions []bytecode.Instruction, jumpdests []uint32) []table.Row {
	// Create jumpdest map for quick lookup
	jumpdestMap := make(map[uint32]bool)
	for _, j := range jumpdests {
		jumpdestMap[j] = true
	}
	
	rows := make([]table.Row, 0, len(instructions))
	
	for i, inst := range instructions {
		// Format gas
		gas := "-"
		if inst.GasCost != nil && *inst.GasCost > 0 {
			gas = fmt.Sprintf("%d", *inst.GasCost)
		}
		
		// Format stack I/O
		stack := "-"
		if inst.StackInputs != nil || inst.StackOutputs != nil {
			inputs := uint8(0)
			outputs := uint8(0)
			if inst.StackInputs != nil {
				inputs = *inst.StackInputs
			}
			if inst.StackOutputs != nil {
				outputs = *inst.StackOutputs
			}
			if inputs > 0 || outputs > 0 {
				stack = fmt.Sprintf("-%d +%d", inputs, outputs)
			}
		}
		
		// Format value/target
		value := ""
		if inst.PushValue != nil {
			value = *inst.PushValue
			
			// Check if this push value is a jumpdest target
			if strings.HasPrefix(inst.OpcodeName, "PUSH") && inst.PushValueDecimal != nil {
				targetPC := uint32(*inst.PushValueDecimal)
				if jumpdestMap[targetPC] {
					value += fmt.Sprintf(" → [JD@%d]", targetPC)
				}
			}
		} else if inst.OpcodeName == "JUMPDEST" {
			value = "[Jump Target]"
		} else if bytecode.IsJumpInstruction(inst.OpcodeName) {
			// Show if jump destination can be determined (for display purposes)
			if dest := bytecode.GetJumpDestination(instructions, i); dest != nil {
				value = fmt.Sprintf("→ PC %d", *dest)
			} else {
				value = "[dynamic]"
			}
		}
		
		row := table.Row{
			fmt.Sprintf("%d", inst.PC),
			inst.OpcodeName,
			fmt.Sprintf("0x%02x", inst.OpcodeHex),
			value,
			gas,
			stack,
		}
		rows = append(rows, row)
	}
	
	return rows
}

// CreateInstructionsTable creates a table component for instructions
func CreateInstructionsTable(height int) table.Model {
	columns := []table.Column{
		{Title: config.DisassemblyHeaderPC, Width: 8},
		{Title: config.DisassemblyHeaderOpcode, Width: 12},
		{Title: config.DisassemblyHeaderHex, Width: 6},
		{Title: config.DisassemblyHeaderValue, Width: 20},
		{Title: config.DisassemblyHeaderGas, Width: 8},
		{Title: config.DisassemblyHeaderStack, Width: 10},
	}
	
	t := table.New(
		table.WithColumns(columns),
		table.WithRows([]table.Row{}),  // Start with empty rows
		table.WithFocused(true),
		table.WithHeight(height),
	)
	
	// Apply styles
	s := table.DefaultStyles()
	s.Header = s.Header.
		BorderStyle(lipgloss.NormalBorder()).
		BorderForeground(config.Amber).
		BorderBottom(true).
		Bold(false)
	s.Selected = s.Selected.
		Foreground(config.Background).
		Background(config.Amber).
		Bold(true)
	
	// Remove cell transformation - will handle dimming in row data instead
	
	t.SetStyles(s)
	return t
}


func formatInstructionRow(inst bytecode.Instruction, jumpdestMap map[uint32]bool) string {
	pc := fmt.Sprintf("%-8d", inst.PC)
	hex := fmt.Sprintf("0x%02x", inst.OpcodeHex)
	hex = padRight(hex, 6)
	opcode := padRight(inst.OpcodeName, 12)
	
	// Format gas cost
	gas := "-"
	if inst.GasCost != nil && *inst.GasCost > 0 {
		gas = fmt.Sprintf("%d", *inst.GasCost)
	}
	gas = padRight(gas, 8)
	
	// Format stack I/O
	stack := "-"
	if inst.StackInputs != nil || inst.StackOutputs != nil {
		inputs := uint8(0)
		outputs := uint8(0)
		if inst.StackInputs != nil {
			inputs = *inst.StackInputs
		}
		if inst.StackOutputs != nil {
			outputs = *inst.StackOutputs
		}
		if inputs > 0 || outputs > 0 {
			stack = fmt.Sprintf("-%d +%d", inputs, outputs)
		}
	}
	stack = padRight(stack, 10)
	
	// Format value/target
	value := ""
	if inst.PushValue != nil {
		value = *inst.PushValue
		
		// Check if this push value is a jumpdest target
		if strings.HasPrefix(inst.OpcodeName, "PUSH") {
			targetPC := uint32(*inst.PushValueDecimal)
			if jumpdestMap[targetPC] {
				value += fmt.Sprintf(" → [JD@%d]", targetPC)
			}
		}
	} else if inst.OpcodeName == "JUMPDEST" {
		value = "[Jump Target]"
	}
	
	return fmt.Sprintf("%-8s %-12s %-6s %-20s %-8s %-10s", pc, opcode, hex, value, gas, stack)
}

// renderBlockIndicator shows current block position and gas usage
func renderBlockIndicator(currentBlock int, totalBlocks int, blockInfo string, blockGas uint64) string {
	if totalBlocks == 0 {
		gasInfo := ""
		if blockGas > 0 {
			gasInfo = fmt.Sprintf(" • Gas: %d", blockGas)
		}
		return config.DimmedStyle.Render(config.AllInstructionsLabel + " " + blockInfo + gasInfo)
	}
	
	indicator := fmt.Sprintf("Block %d/%d • %s", currentBlock+1, totalBlocks, blockInfo)
	if blockGas > 0 {
		indicator += fmt.Sprintf(" • Gas: %d", blockGas)
	}
	
	return config.SubtitleStyle.Render(indicator)
}

// RenderBytecodeDisassemblyError renders an error message when bytecode analysis fails
func RenderBytecodeDisassemblyError(err error) string {
	var b strings.Builder
	
	// Title
	b.WriteString(config.SubtitleStyle.Render(config.BytecodeDisassemblyTitle))
	b.WriteString("\n\n")
	
	// Error message
	b.WriteString(config.ErrorStyle.Render("Bytecode Analysis Failed"))
	b.WriteString("\n\n")
	b.WriteString(config.NormalStyle.Render(fmt.Sprintf("Error: %v", err)))
	
	// Helpful message
	b.WriteString("\n\n")
	b.WriteString(config.DimmedStyle.Render("This could be due to:"))
	b.WriteString("\n")
	b.WriteString(config.DimmedStyle.Render("• Empty or invalid bytecode"))
	b.WriteString("\n")
	b.WriteString(config.DimmedStyle.Render("• Unsupported bytecode format"))
	b.WriteString("\n")
	b.WriteString(config.DimmedStyle.Render("• Contract with only metadata (no runtime code)"))
	
	// Wrap in box
	content := b.String()
	boxStyle := config.BoxStyle.Copy().
		Padding(0, 1).
		BorderForeground(config.Amber)
	
	return boxStyle.Render(content)
}

