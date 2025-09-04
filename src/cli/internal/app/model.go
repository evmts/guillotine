package app

import (
	"guillotine-cli/internal/config"
	"guillotine-cli/internal/ui"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

type Model struct {
	greeting     string
	cursor       int
	choices      []string
	selected     map[int]struct{}
	quitting     bool
	width        int
	height       int
	mode         AppMode
	callInput    CallInputState
	rpcInput     RPCInputState
	carousel     CarouselUIState
	sourceViewer SourceVisualizationState
}

func InitialModel() Model {
	return Model{
		greeting:     config.AppTitle,
		choices:      config.GetMenuItems(),
		selected:     make(map[int]struct{}),
		mode:         MenuMode,
		callInput:    NewCallInputState(),
		rpcInput:     NewRPCInputState(),
		carousel:     NewCarouselUIState(),
		sourceViewer: NewSourceVisualizationState(),
	}
}

func (m Model) Init() tea.Cmd {
	return tea.Batch(
		tea.EnterAltScreen,
		tea.ClearScreen,
	)
}

func (m Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height
		return m, nil

	case tea.KeyMsg:
		msgStr := msg.String()
		
		if config.IsKey(msgStr, config.KeyQuit) {
			m.quitting = true
			return m, tea.Batch(
				tea.ExitAltScreen,
				tea.Quit,
			)
		}

		// Handle different modes
		switch m.mode {
		case MenuMode:
			return m.handleMenuMode(msg)
		case CallInputMode:
			return m.handleCallInputMode(msg)
		case RPCInputMode:
			return m.handleRPCInputMode(msg)
		case CarouselMode:
			return m.handleCarouselMode(msg)
		}
	}

	return m, nil
}

// handleMenuMode handles navigation in menu mode
func (m Model) handleMenuMode(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	msgStr := msg.String()

	if config.IsKey(msgStr, config.KeyUp) {
		if m.cursor > 0 {
			m.cursor--
		}
	}

	if config.IsKey(msgStr, config.KeyDown) {
		if m.cursor < len(m.choices)-1 {
			m.cursor++
		}
	}

	if config.IsKey(msgStr, config.KeySelect) {
		switch m.choices[m.cursor] {
		case config.MenuMakeCall:
			m.mode = CallInputMode
			m.callInput = NewCallInputState()
			return m, tea.ClearScreen
		case config.MenuLoadBytecode:
			m.mode = RPCInputMode
			m.rpcInput = NewRPCInputState()
			return m, tea.ClearScreen
		case config.MenuOpcodeCarousel:
			m.mode = CarouselMode
			m.carousel = NewCarouselUIState()
			m.carousel.carousel.LoadMockTrace() // Load mock data for demo
			m.carousel.loaded = true
			return m, tea.ClearScreen
		case config.MenuExit:
			m.quitting = true
			return m, tea.Batch(
				tea.ExitAltScreen,
				tea.Quit,
			)
		default:
			// Handle other menu items
			_, ok := m.selected[m.cursor]
			if ok {
				delete(m.selected, m.cursor)
			} else {
				m.selected[m.cursor] = struct{}{}
			}
		}
	}

	return m, nil
}

// handleCallInputMode handles input in call input mode
func (m Model) handleCallInputMode(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	msgStr := msg.String()

	// ESC to go back to menu
	if config.IsKey(msgStr, "esc") {
		m.mode = MenuMode
		return m, tea.ClearScreen
	}

	// Tab navigation between fields
	if msg.Type == tea.KeyTab {
		m.callInput.activeField = m.callInput.nextField()
		return m, nil
	}

	if msg.Type == tea.KeyShiftTab {
		m.callInput.activeField = m.callInput.previousField()
		return m, nil
	}

	// Handle text input
	if msg.Type == tea.KeyRunes {
		currentValue := m.callInput.getFieldValue(m.callInput.activeField)
		newValue := currentValue + string(msg.Runes)
		m.callInput.setFieldValue(m.callInput.activeField, newValue)
		return m, nil
	}

	// Handle backspace
	if msg.Type == tea.KeyBackspace {
		currentValue := m.callInput.getFieldValue(m.callInput.activeField)
		if len(currentValue) > 0 {
			newValue := currentValue[:len(currentValue)-1]
			m.callInput.setFieldValue(m.callInput.activeField, newValue)
		}
		return m, nil
	}

	// Handle enter to submit/execute call
	if msg.Type == tea.KeyEnter {
		if err := m.callInput.Validate(); err == nil {
			// TODO: Execute the call
			// For now, just go back to menu
			m.mode = MenuMode
			return m, tea.ClearScreen
		}
	}

	return m, nil
}

// handleRPCInputMode handles input in RPC bytecode loading mode
func (m Model) handleRPCInputMode(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	msgStr := msg.String()

	// ESC to go back to menu
	if config.IsKey(msgStr, "esc") {
		m.mode = MenuMode
		return m, tea.ClearScreen
	}

	// Tab navigation between fields
	if msg.Type == tea.KeyTab {
		m.rpcInput.activeField = m.rpcInput.nextField()
		return m, nil
	}

	if msg.Type == tea.KeyShiftTab {
		m.rpcInput.activeField = m.rpcInput.previousField()
		return m, nil
	}

	// Handle text input
	if msg.Type == tea.KeyRunes {
		currentValue := m.rpcInput.getFieldValue(m.rpcInput.activeField)
		newValue := currentValue + string(msg.Runes)
		m.rpcInput.setFieldValue(m.rpcInput.activeField, newValue)
		return m, nil
	}

	// Handle backspace
	if msg.Type == tea.KeyBackspace {
		currentValue := m.rpcInput.getFieldValue(m.rpcInput.activeField)
		if len(currentValue) > 0 {
			newValue := currentValue[:len(currentValue)-1]
			m.rpcInput.setFieldValue(m.rpcInput.activeField, newValue)
		}
		return m, nil
	}

	// Handle enter to load bytecode
	if msg.Type == tea.KeyEnter {
		if err := m.rpcInput.Validate(); err == nil {
			// TODO: Load bytecode from RPC
			// For now, just go back to menu
			m.mode = MenuMode
			return m, tea.ClearScreen
		}
	}

	return m, nil
}

// handleCarouselMode handles input in opcode carousel mode
func (m Model) handleCarouselMode(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	msgStr := msg.String()

	// ESC to go back to menu
	if config.IsKey(msgStr, "esc") {
		m.mode = MenuMode
		return m, tea.ClearScreen
	}

	// Navigation controls
	if config.IsKey(msgStr, "left") || config.IsKey(msgStr, "h") {
		m.carousel.carousel.StepBackward()
		return m, nil
	}

	if config.IsKey(msgStr, "right") || config.IsKey(msgStr, "l") {
		m.carousel.carousel.StepForward()
		return m, nil
	}

	if config.IsKey(msgStr, "home") {
		m.carousel.carousel.JumpToStart()
		return m, nil
	}

	if config.IsKey(msgStr, "end") {
		m.carousel.carousel.JumpToEnd()
		return m, nil
	}

	// Playback controls
	if config.IsKey(msgStr, " ") { // Space to toggle playback
		m.carousel.carousel.TogglePlayback()
		return m, nil
	}

	// Speed controls
	if config.IsKey(msgStr, "+") || config.IsKey(msgStr, "=") {
		if m.carousel.carousel.speed > 100 {
			m.carousel.carousel.speed -= 100
		}
		return m, nil
	}

	if config.IsKey(msgStr, "-") || config.IsKey(msgStr, "_") {
		if m.carousel.carousel.speed < 3000 {
			m.carousel.carousel.speed += 100
		}
		return m, nil
	}

	return m, nil
}

func (m Model) View() string {
	if m.quitting {
		goodbyeStyle := lipgloss.NewStyle().
			Foreground(config.Amber).
			Bold(true).
			Padding(1, 2)
		return goodbyeStyle.Render(config.GoodbyeMessage)
	}

	if m.width == 0 || m.height == 0 {
		return config.LoadingMessage
	}

	layout := ui.Layout{Width: m.width, Height: m.height}
	
	switch m.mode {
	case MenuMode:
		return m.renderMenuMode(layout)
	case CallInputMode:
		return m.renderCallInputMode(layout)
	case RPCInputMode:
		return m.renderRPCInputMode(layout)
	case CarouselMode:
		return m.renderCarouselMode(layout)
	default:
		return config.LoadingMessage
	}
}

// renderMenuMode renders the main menu
func (m Model) renderMenuMode(layout ui.Layout) string {
	header := ui.RenderHeader(m.greeting, config.AppSubtitle, config.TitleStyle, config.SubtitleStyle)
	menu := ui.RenderMenu(m.choices, m.cursor, m.selected)
	help := ui.RenderHelpText()
	
	content := layout.ComposeVertical(header, menu, help)
	return layout.RenderWithBox(content)
}

// renderCallInputMode renders the call input form
func (m Model) renderCallInputMode(layout ui.Layout) string {
	// Convert internal CallInputState to UI CallInputState
	uiState := ui.CallInputState{
		FromAddress: m.callInput.fromAddress,
		ToAddress:   m.callInput.toAddress,
		Value:       m.callInput.value,
		Calldata:    m.callInput.calldata,
		Gas:         m.callInput.gas,
		ActiveField: ui.InputField(m.callInput.activeField),
		Errors:      make(map[ui.InputField]string),
	}
	
	// Convert errors
	for field, err := range m.callInput.errors {
		uiState.Errors[ui.InputField(field)] = err
	}
	
	content := ui.RenderCallInputForm(uiState)
	return layout.RenderWithBox(content)
}

// renderRPCInputMode renders the RPC bytecode loading form
func (m Model) renderRPCInputMode(layout ui.Layout) string {
	// Convert internal RPCInputState to UI RPCInputState
	uiState := ui.RPCInputState{
		Endpoint:    m.rpcInput.endpoint,
		Address:     m.rpcInput.address,
		Block:       m.rpcInput.block,
		ActiveField: ui.RPCInputField(m.rpcInput.activeField),
		Errors:      make(map[ui.RPCInputField]string),
		Loading:     m.rpcInput.loading,
	}
	
	// Convert errors
	for field, err := range m.rpcInput.errors {
		uiState.Errors[ui.RPCInputField(field)] = err
	}
	
	content := ui.RenderRPCInputForm(uiState)
	return layout.RenderWithBox(content)
}

// renderCarouselMode renders the opcode carousel
func (m Model) renderCarouselMode(layout ui.Layout) string {
	if !m.carousel.loaded {
		content := ui.RenderCarouselNoData()
		return layout.RenderWithBox(content)
	}

	// Convert internal execution steps to UI types
	carouselCtx := m.carousel.carousel.GetCarouselContext()
	uiCtx := ui.CarouselContext{
		Previous:   convertExecutionStepToUI(carouselCtx.Previous),
		Current:    convertExecutionStepToUI(carouselCtx.Current),
		Next:       convertExecutionStepToUI(carouselCtx.Next),
		Progress:   carouselCtx.Progress,
		StepInfo:   carouselCtx.StepInfo,
		IsPlaying:  carouselCtx.IsPlaying,
		TotalSteps: carouselCtx.TotalSteps,
		CurrentIdx: carouselCtx.CurrentIdx,
	}

	content := ui.RenderOpcodeCarousel(uiCtx)
	return layout.RenderWithBox(content)
}

// convertExecutionStepToUI converts app ExecutionStep to UI ExecutionStep
func convertExecutionStepToUI(step *ExecutionStep) *ui.ExecutionStep {
	if step == nil {
		return nil
	}
	return &ui.ExecutionStep{
		PC:          step.PC,
		Opcode:      step.Opcode,
		OpcodeName:  step.OpcodeName,
		GasBefore:   step.GasBefore,
		GasAfter:    step.GasAfter,
		GasConsumed: step.GasConsumed,
		StackDepth:  step.StackDepth,
		MemorySize:  step.MemorySize,
	}
}