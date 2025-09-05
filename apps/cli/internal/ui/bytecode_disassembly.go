package ui

import (
	"fmt"
	"strings"

	"guillotine-cli/internal/config"
	"guillotine-cli/internal/core/disassembly"
	"guillotine-cli/internal/types"

	"github.com/charmbracelet/bubbles/table"
	"github.com/charmbracelet/lipgloss"
)

// DisassemblyDisplayData contains data for rendering bytecode disassembly
type DisassemblyDisplayData struct {
	Result            *types.DisassemblyResult
	CurrentBlockIndex int
	Width             int
	Height            int
}

// RenderBytecodeDisassembly renders the bytecode disassembly result
func RenderBytecodeDisassembly(result *types.DisassemblyResult, width, height int) string {
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

	// Statistics section
	b.WriteString(renderStats(&data.Result.Stats))
	b.WriteString("\n\n")

	// Get instructions for current block
	instructions, blockInfo, _ := disassembly.GetInstructionsForBlock(data.Result, data.CurrentBlockIndex)
	
	// Render instructions as a scrollable table view
	tableView := renderInstructionsAsTable(instructions, data.Result.Jumpdests, 
		data.Width, data.Height-12)  // Reserve space for header, stats and indicator
	b.WriteString(tableView)
	
	// Calculate total gas for the block
	blockGas := disassembly.CalculateBlockGas(instructions)
	
	// Block indicator
	b.WriteString("\n\n")
	b.WriteString(renderBlockIndicator(data.CurrentBlockIndex, len(data.Result.BasicBlocks), blockInfo, blockGas))

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

	// Statistics section
	b.WriteString(renderStats(&data.Result.Stats))
	b.WriteString("\n\n")

	// Render the table view
	b.WriteString(instructionTable.View())
	
	// Get block info for indicator
	instructions, blockInfo, _ := disassembly.GetInstructionsForBlock(data.Result, data.CurrentBlockIndex)
	
	// Calculate total gas for the block
	blockGas := disassembly.CalculateBlockGas(instructions)
	
	// Block indicator
	b.WriteString("\n\n")
	b.WriteString(renderBlockIndicator(data.CurrentBlockIndex, len(data.Result.BasicBlocks), blockInfo, blockGas))

	// Wrap everything in a box without forcing height
	content := b.String()
	boxStyle := config.BoxStyle.Copy().
		Padding(0, 1).        // Only horizontal padding, no vertical
		BorderForeground(config.Amber)
	
	return boxStyle.Render(content)
}

func renderStats(stats *types.BytecodeStats) string {
	statsBox := config.BoxStyle.Copy().
		Padding(0, 1).
		BorderForeground(config.Amber)
	
	// Show actual instruction count, not dispatch size which might be 0
	instrCount := stats.DispatchSize
	if instrCount == 0 && stats.OriginalSize > 0 {
		// Estimate instruction count from bytecode size if dispatch size not set
		instrCount = stats.OriginalSize // This is an approximation
	}
	
	// Fix blocks count - if it's 0 but we have instructions, show 1
	blocksCount := stats.BasicBlockCount
	if blocksCount == 0 && stats.OriginalSize > 0 {
		blocksCount = 1  // At least one block if we have bytecode
	}
	
	statsContent := fmt.Sprintf(
		"%s %d bytes | %s %d | %s %d | %s %d",
		config.LabelStyle.Render(config.DisassemblySizeLabel),
		stats.OriginalSize,
		config.LabelStyle.Render(config.DisassemblyInstructionsLabel),
		instrCount,
		config.LabelStyle.Render(config.DisassemblyBlocksLabel),
		blocksCount,
		config.LabelStyle.Render(config.DisassemblyJumpdestsLabel),
		stats.JumpdestCount,
	)
	
	return statsBox.Render(statsContent)
}

// renderInstructionsAsTable renders instructions in a scrollable table format
func renderInstructionsAsTable(instructions []types.DisassemblyInstruction, jumpdests []uint32, 
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
	header := fmt.Sprintf("%-8s %-12s %-6s %-25s %-5s %-8s", 
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
		} else if disassembly.IsImportantOpcode(inst.OpcodeName) {
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
func ConvertInstructionsToRows(instructions []types.DisassemblyInstruction, jumpdests []uint32) []table.Row {
	// Create jumpdest map for quick lookup
	jumpdestMap := make(map[uint32]bool)
	for _, j := range jumpdests {
		jumpdestMap[j] = true
	}
	
	rows := make([]table.Row, 0, len(instructions))
	
	for _, inst := range instructions {
		// Format gas
		gas := "-"
		if inst.GasCost > 0 {
			gas = fmt.Sprintf("%d", inst.GasCost)
		}
		
		// Format stack I/O
		stack := "-"
		if inst.StackInputs > 0 || inst.StackOutputs > 0 {
			stack = fmt.Sprintf("-%d +%d", inst.StackInputs, inst.StackOutputs)
		}
		
		// Format value/target
		value := ""
		if inst.PushValue != nil {
			if inst.PushValue.High == 0 {
				value = fmt.Sprintf("0x%x", inst.PushValue.Low)
			} else {
				value = fmt.Sprintf("0x%x%016x", inst.PushValue.High, inst.PushValue.Low)
			}
			
			// Check if this push value is a jumpdest target
			if strings.HasPrefix(inst.OpcodeName, "PUSH") {
				targetPC := uint32(inst.PushValue.Low)
				if jumpdestMap[targetPC] {
					value += fmt.Sprintf(" → [JD@%d]", targetPC)
				}
			}
		} else if inst.OpcodeName == "JUMPDEST" {
			value = "[Jump Target]"
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
		{Title: config.DisassemblyHeaderValue, Width: 25},
		{Title: config.DisassemblyHeaderGas, Width: 5},
		{Title: config.DisassemblyHeaderStack, Width: 8},
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


func formatInstructionRow(inst types.DisassemblyInstruction, jumpdestMap map[uint32]bool) string {
	pc := fmt.Sprintf("%-8d", inst.PC)
	hex := fmt.Sprintf("0x%02x", inst.OpcodeHex)
	hex = padRight(hex, 6)
	opcode := padRight(inst.OpcodeName, 12)
	
	// Format gas cost
	gas := "-"
	if inst.GasCost > 0 {
		gas = fmt.Sprintf("%d", inst.GasCost)
	}
	gas = padRight(gas, 5)
	
	// Format stack I/O
	stack := "-"
	if inst.StackInputs > 0 || inst.StackOutputs > 0 {
		stack = fmt.Sprintf("-%d +%d", inst.StackInputs, inst.StackOutputs)
	}
	stack = padRight(stack, 8)
	
	// Format value/target
	value := ""
	if inst.PushValue != nil {
		if inst.PushValue.High == 0 {
			value = fmt.Sprintf("0x%x", inst.PushValue.Low)
		} else {
			value = fmt.Sprintf("0x%x%016x", inst.PushValue.High, inst.PushValue.Low)
		}
		
		// Check if this push value is a jumpdest target
		if strings.HasPrefix(inst.OpcodeName, "PUSH") {
			targetPC := uint32(inst.PushValue.Low)
			if jumpdestMap[targetPC] {
				value += fmt.Sprintf(" → [JD@%d]", targetPC)
			}
		}
	} else if inst.OpcodeName == "JUMPDEST" {
		value = "[Jump Target]"
	}
	
	return fmt.Sprintf("%-8s %-12s %-6s %-25s %-5s %-8s", pc, opcode, hex, value, gas, stack)
}

// renderBlockIndicator shows current block position and gas usage
func renderBlockIndicator(currentBlock int, totalBlocks int, blockInfo string, blockGas uint32) string {
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

