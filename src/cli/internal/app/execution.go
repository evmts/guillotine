package app

import (
	"fmt"
	"strings"
)

// ExecutionStep represents a single EVM execution step
type ExecutionStep struct {
	PC          uint32 `json:"pc"`
	Opcode      uint8  `json:"opcode"`
	OpcodeName  string `json:"opcode_name"`
	GasBefore   uint64 `json:"gas_before"`
	GasAfter    uint64 `json:"gas_after"`
	GasConsumed uint64 `json:"gas_consumed"`
	StackDepth  int    `json:"stack_depth"`
	MemorySize  int    `json:"memory_size"`
}

// ExecutionTrace represents a complete execution trace
type ExecutionTrace struct {
	Steps       []ExecutionStep `json:"steps"`
	CurrentStep int             `json:"current_step"`
}

// CarouselState represents the opcode carousel UI state
type CarouselState struct {
	trace        ExecutionTrace
	currentIndex int
	playing      bool
	speed        int // milliseconds between steps
}

// NewCarouselState creates a new carousel state
func NewCarouselState() CarouselState {
	return CarouselState{
		trace: ExecutionTrace{
			Steps:       []ExecutionStep{},
			CurrentStep: 0,
		},
		currentIndex: 0,
		playing:      false,
		speed:        1000, // 1 second between steps
	}
}

// LoadMockTrace loads a mock execution trace for demonstration
func (c *CarouselState) LoadMockTrace() {
	// Mock bytecode execution: PUSH1 0x42, PUSH1 0x24, ADD, POP
	mockSteps := []ExecutionStep{
		{
			PC:          0,
			Opcode:      0x60, // PUSH1
			OpcodeName:  "PUSH1",
			GasBefore:   1000000,
			GasAfter:    999997,
			GasConsumed: 3,
			StackDepth:  0,
			MemorySize:  0,
		},
		{
			PC:          2,
			Opcode:      0x60, // PUSH1
			OpcodeName:  "PUSH1",
			GasBefore:   999997,
			GasAfter:    999994,
			GasConsumed: 3,
			StackDepth:  1,
			MemorySize:  0,
		},
		{
			PC:          4,
			Opcode:      0x01, // ADD
			OpcodeName:  "ADD",
			GasBefore:   999994,
			GasAfter:    999991,
			GasConsumed: 3,
			StackDepth:  2,
			MemorySize:  0,
		},
		{
			PC:          5,
			Opcode:      0x50, // POP
			OpcodeName:  "POP",
			GasBefore:   999991,
			GasAfter:    999989,
			GasConsumed: 2,
			StackDepth:  1,
			MemorySize:  0,
		},
		{
			PC:          6,
			Opcode:      0x00, // STOP
			OpcodeName:  "STOP",
			GasBefore:   999989,
			GasAfter:    999989,
			GasConsumed: 0,
			StackDepth:  0,
			MemorySize:  0,
		},
	}

	c.trace.Steps = mockSteps
	c.currentIndex = 0
}

// GetCurrentStep returns the current execution step
func (c *CarouselState) GetCurrentStep() *ExecutionStep {
	if len(c.trace.Steps) == 0 || c.currentIndex >= len(c.trace.Steps) {
		return nil
	}
	return &c.trace.Steps[c.currentIndex]
}

// GetPreviousStep returns the previous execution step
func (c *CarouselState) GetPreviousStep() *ExecutionStep {
	if len(c.trace.Steps) == 0 || c.currentIndex <= 0 {
		return nil
	}
	return &c.trace.Steps[c.currentIndex-1]
}

// GetNextStep returns the next execution step
func (c *CarouselState) GetNextStep() *ExecutionStep {
	if len(c.trace.Steps) == 0 || c.currentIndex >= len(c.trace.Steps)-1 {
		return nil
	}
	return &c.trace.Steps[c.currentIndex+1]
}

// StepForward moves to the next step
func (c *CarouselState) StepForward() bool {
	if c.currentIndex < len(c.trace.Steps)-1 {
		c.currentIndex++
		return true
	}
	return false
}

// StepBackward moves to the previous step
func (c *CarouselState) StepBackward() bool {
	if c.currentIndex > 0 {
		c.currentIndex--
		return true
	}
	return false
}

// JumpToStart jumps to the first step
func (c *CarouselState) JumpToStart() {
	c.currentIndex = 0
}

// JumpToEnd jumps to the last step
func (c *CarouselState) JumpToEnd() {
	if len(c.trace.Steps) > 0 {
		c.currentIndex = len(c.trace.Steps) - 1
	}
}

// TogglePlayback toggles automatic playback
func (c *CarouselState) TogglePlayback() {
	c.playing = !c.playing
}

// IsPlaying returns whether automatic playback is active
func (c *CarouselState) IsPlaying() bool {
	return c.playing
}

// GetProgress returns the current progress as a percentage
func (c *CarouselState) GetProgress() float64 {
	if len(c.trace.Steps) == 0 {
		return 0.0
	}
	return float64(c.currentIndex) / float64(len(c.trace.Steps)-1) * 100.0
}

// GetStepInfo returns formatted information about the current step
func (c *CarouselState) GetStepInfo() string {
	current := c.GetCurrentStep()
	if current == nil {
		return "No execution steps available"
	}

	var info strings.Builder
	info.WriteString(fmt.Sprintf("Step %d/%d (%.1f%%)\n", 
		c.currentIndex+1, len(c.trace.Steps), c.GetProgress()))
	info.WriteString(fmt.Sprintf("PC: %d\n", current.PC))
	info.WriteString(fmt.Sprintf("Opcode: %s (0x%02X)\n", current.OpcodeName, current.Opcode))
	info.WriteString(fmt.Sprintf("Gas: %d → %d (-%d)\n", 
		current.GasBefore, current.GasAfter, current.GasConsumed))
	info.WriteString(fmt.Sprintf("Stack Depth: %d\n", current.StackDepth))

	return info.String()
}

// CarouselContext provides context for rendering the carousel
type CarouselContext struct {
	Previous    *ExecutionStep
	Current     *ExecutionStep  
	Next        *ExecutionStep
	Progress    float64
	StepInfo    string
	IsPlaying   bool
	TotalSteps  int
	CurrentIdx  int
}

// GetCarouselContext returns context for UI rendering
func (c *CarouselState) GetCarouselContext() CarouselContext {
	return CarouselContext{
		Previous:   c.GetPreviousStep(),
		Current:    c.GetCurrentStep(),
		Next:       c.GetNextStep(),
		Progress:   c.GetProgress(),
		StepInfo:   c.GetStepInfo(),
		IsPlaying:  c.IsPlaying(),
		TotalSteps: len(c.trace.Steps),
		CurrentIdx: c.currentIndex,
	}
}

// OpcodeCarouselMode represents the carousel UI mode
type OpcodeCarouselMode int

const (
	CarouselMainView OpcodeCarouselMode = iota
	CarouselDetailView
)

// CarouselUIState represents the carousel user interface state
type CarouselUIState struct {
	carousel CarouselState
	mode     OpcodeCarouselMode
	loaded   bool
}

// NewCarouselUIState creates a new carousel UI state
func NewCarouselUIState() CarouselUIState {
	return CarouselUIState{
		carousel: NewCarouselState(),
		mode:     CarouselMainView,
		loaded:   false,
	}
}