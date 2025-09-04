package ui

import (
	"fmt"
	"strings"

	"guillotine-cli/internal/config"

	"github.com/charmbracelet/lipgloss"
)

// CarouselContext represents the context for rendering the opcode carousel
type CarouselContext struct {
	Previous   *ExecutionStep
	Current    *ExecutionStep
	Next       *ExecutionStep
	Progress   float64
	StepInfo   string
	IsPlaying  bool
	TotalSteps int
	CurrentIdx int
}

// ExecutionStep represents a single EVM execution step for UI rendering
type ExecutionStep struct {
	PC          uint32
	Opcode      uint8
	OpcodeName  string
	GasBefore   uint64
	GasAfter    uint64
	GasConsumed uint64
	StackDepth  int
	MemorySize  int
}

// RenderOpcodeCarousel renders the main opcode carousel interface
func RenderOpcodeCarousel(ctx CarouselContext) string {
	var sections []string

	// Title
	title := config.TitleStyle.Render("Opcode Carousel")
	sections = append(sections, title)
	sections = append(sections, "")

	// Progress bar
	progressBar := renderProgressBar(ctx.Progress, ctx.CurrentIdx+1, ctx.TotalSteps)
	sections = append(sections, progressBar)
	sections = append(sections, "")

	// Main carousel display
	carouselDisplay := renderCarouselDisplay(ctx)
	sections = append(sections, carouselDisplay)
	sections = append(sections, "")

	// Current step details
	if ctx.Current != nil {
		stepDetails := renderStepDetails(*ctx.Current)
		sections = append(sections, stepDetails)
		sections = append(sections, "")
	}

	// Gas tracker
	if ctx.Current != nil {
		gasTracker := renderGasTracker(*ctx.Current)
		sections = append(sections, gasTracker)
		sections = append(sections, "")
	}

	// Controls
	controls := renderCarouselControls(ctx.IsPlaying)
	sections = append(sections, controls)

	return lipgloss.JoinVertical(lipgloss.Left, sections...)
}

// renderCarouselDisplay renders the three-step carousel (previous, current, next)
func renderCarouselDisplay(ctx CarouselContext) string {
	var parts []string

	// Previous opcode (dimmed)
	if ctx.Previous != nil {
		prevStyle := lipgloss.NewStyle().
			Foreground(config.Muted).
			Padding(0, 2).
			Border(lipgloss.RoundedBorder()).
			BorderForeground(config.Muted)
		
		prevContent := fmt.Sprintf("← %s\nPC:%d", ctx.Previous.OpcodeName, ctx.Previous.PC)
		parts = append(parts, prevStyle.Render(prevContent))
	} else {
		// Empty placeholder
		emptyStyle := lipgloss.NewStyle().
			Foreground(config.Muted).
			Padding(0, 2).
			Border(lipgloss.RoundedBorder()).
			BorderForeground(config.Muted)
		parts = append(parts, emptyStyle.Render("   \n   "))
	}

	// Current opcode (highlighted)
	if ctx.Current != nil {
		currentStyle := lipgloss.NewStyle().
			Foreground(config.Background).
			Background(config.Amber).
			Bold(true).
			Padding(0, 2).
			Border(lipgloss.ThickBorder()).
			BorderForeground(config.Amber)
		
		currentContent := fmt.Sprintf("● %s\nPC:%d", ctx.Current.OpcodeName, ctx.Current.PC)
		parts = append(parts, currentStyle.Render(currentContent))
	} else {
		// No current step
		noStepStyle := lipgloss.NewStyle().
			Foreground(lipgloss.Color("9")).
			Padding(0, 2).
			Border(lipgloss.RoundedBorder()).
			BorderForeground(lipgloss.Color("9"))
		parts = append(parts, noStepStyle.Render("No Step\n      "))
	}

	// Next opcode (normal)
	if ctx.Next != nil {
		nextStyle := lipgloss.NewStyle().
			Foreground(config.Foreground).
			Padding(0, 2).
			Border(lipgloss.RoundedBorder()).
			BorderForeground(config.Border)
		
		nextContent := fmt.Sprintf("%s →\nPC:%d", ctx.Next.OpcodeName, ctx.Next.PC)
		parts = append(parts, nextStyle.Render(nextContent))
	} else {
		// Empty placeholder
		emptyStyle := lipgloss.NewStyle().
			Foreground(config.Muted).
			Padding(0, 2).
			Border(lipgloss.RoundedBorder()).
			BorderForeground(config.Muted)
		parts = append(parts, emptyStyle.Render("   \n   "))
	}

	return lipgloss.JoinHorizontal(lipgloss.Center, parts...)
}

// renderProgressBar renders a progress bar for the execution steps
func renderProgressBar(progress float64, current, total int) string {
	barWidth := 50
	filledWidth := int(progress / 100 * float64(barWidth))
	
	filled := strings.Repeat("█", filledWidth)
	empty := strings.Repeat("░", barWidth-filledWidth)
	
	progressStyle := lipgloss.NewStyle().
		Foreground(config.Amber)
	
	emptyStyle := lipgloss.NewStyle().
		Foreground(config.Muted)
	
	bar := progressStyle.Render(filled) + emptyStyle.Render(empty)
	
	info := fmt.Sprintf("Step %d/%d (%.1f%%)", current, total, progress)
	
	return lipgloss.JoinVertical(lipgloss.Left,
		bar,
		config.SubtitleStyle.Render(info),
	)
}

// renderStepDetails renders detailed information about the current step
func renderStepDetails(step ExecutionStep) string {
	detailsStyle := config.BoxStyle.
		Width(80).
		BorderForeground(config.ChartBlue)
	
	var details strings.Builder
	details.WriteString(fmt.Sprintf("Opcode Details\n"))
	details.WriteString(fmt.Sprintf("  Name: %s (0x%02X)\n", step.OpcodeName, step.Opcode))
	details.WriteString(fmt.Sprintf("  PC: %d\n", step.PC))
	details.WriteString(fmt.Sprintf("  Stack Depth: %d items\n", step.StackDepth))
	details.WriteString(fmt.Sprintf("  Memory Size: %d bytes", step.MemorySize))
	
	return detailsStyle.Render(details.String())
}

// renderGasTracker renders gas consumption information
func renderGasTracker(step ExecutionStep) string {
	gasStyle := config.BoxStyle.
		Width(80).
		BorderForeground(config.ChartGreen)
	
	var gasInfo strings.Builder
	gasInfo.WriteString(fmt.Sprintf("Gas Tracking\n"))
	gasInfo.WriteString(fmt.Sprintf("  Before: %d\n", step.GasBefore))
	gasInfo.WriteString(fmt.Sprintf("  After:  %d\n", step.GasAfter))
	gasInfo.WriteString(fmt.Sprintf("  Used:   %d", step.GasConsumed))
	
	// Color code based on gas usage
	var usageColor lipgloss.Color
	if step.GasConsumed == 0 {
		usageColor = config.ChartBlue
	} else if step.GasConsumed <= 10 {
		usageColor = config.ChartGreen
	} else if step.GasConsumed <= 100 {
		usageColor = config.ChartYellow
	} else {
		usageColor = config.ChartOrange
	}
	
	gasUsageStyle := lipgloss.NewStyle().
		Foreground(usageColor).
		Bold(true)
	
	gasInfo.WriteString(gasUsageStyle.Render(fmt.Sprintf(" (%s)", getGasUsageLabel(step.GasConsumed))))
	
	return gasStyle.Render(gasInfo.String())
}

// getGasUsageLabel returns a descriptive label for gas usage
func getGasUsageLabel(gasUsed uint64) string {
	switch {
	case gasUsed == 0:
		return "FREE"
	case gasUsed <= 3:
		return "LOW"
	case gasUsed <= 10:
		return "MEDIUM"
	case gasUsed <= 100:
		return "HIGH"
	default:
		return "EXPENSIVE"
	}
}

// renderCarouselControls renders the control instructions
func renderCarouselControls(isPlaying bool) string {
	var controls []string
	
	controls = append(controls, "Navigation:")
	controls = append(controls, "  ←/h: Previous step")
	controls = append(controls, "  →/l: Next step")
	controls = append(controls, "  Home: First step")
	controls = append(controls, "  End: Last step")
	
	controls = append(controls, "")
	controls = append(controls, "Playback:")
	
	if isPlaying {
		controls = append(controls, "  Space: ⏸️  Pause automatic playback")
	} else {
		controls = append(controls, "  Space: ▶️  Start automatic playback")
	}
	
	controls = append(controls, "  +/-: Adjust playback speed")
	controls = append(controls, "")
	controls = append(controls, "  Esc: Back to menu")
	
	return config.HelpStyle.Render(strings.Join(controls, "\n"))
}

// RenderCarouselNoData renders a message when no execution data is available
func RenderCarouselNoData() string {
	noDataStyle := lipgloss.NewStyle().
		Foreground(config.Muted).
		Border(lipgloss.RoundedBorder()).
		BorderForeground(config.Muted).
		Padding(2, 4).
		Align(lipgloss.Center)
	
	content := "No execution trace available\n\nLoad a contract and execute some operations\nto see the opcode carousel in action."
	
	return noDataStyle.Render(content)
}

// RenderCarouselLoading renders a loading state
func RenderCarouselLoading() string {
	loadingStyle := lipgloss.NewStyle().
		Foreground(config.ChartBlue).
		Border(lipgloss.RoundedBorder()).
		BorderForeground(config.ChartBlue).
		Padding(2, 4).
		Align(lipgloss.Center).
		Bold(true)
	
	content := "🔄 Loading execution trace...\n\nPlease wait while the EVM executes\nthe bytecode and generates steps."
	
	return loadingStyle.Render(content)
}