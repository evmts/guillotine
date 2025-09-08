package app

import (
	"fmt"
	"guillotine-cli/internal/config"
	"guillotine-cli/internal/types"
	"guillotine-cli/internal/ui"
	"strconv"
	"encoding/hex"
	"math/big"
	"strings"

	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	guillotine "github.com/evmts/guillotine/sdks/go"
	"github.com/evmts/guillotine/sdks/go/evm"
	"github.com/evmts/guillotine/sdks/go/primitives"
)

type Model struct {
	greeting string
	cursor   int
	choices  []string
	selected map[int]struct{}
	quitting bool
	width    int
	height   int
	
	// Call-related state
	state             types.AppState
	callParams        types.CallParametersStrings
	callParamCursor   int
	editingParam      string
	textInput         textinput.Model
	validationError   string
	callResult        *guillotine.CallResult
	callTypeSelector  int
}

func InitialModel() Model {
	return Model{
		greeting:    config.AppTitle,
		choices:     config.GetMenuItems(),
		selected:    make(map[int]struct{}),
		state:       types.StateMainMenu,
		callParams:  types.NewCallParametersStrings(),
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
		
	case callResultMsg:
		m.callResult = msg.result
		m.state = types.StateCallResult
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

		if config.IsKey(msgStr, config.KeyUp) {
			switch m.state {
			case types.StateMainMenu:
				if m.cursor > 0 {
					m.cursor--
				}
			case types.StateCallParameterList:
				if m.callParamCursor > 0 {
					m.callParamCursor--
				}
			case types.StateCallParameterEdit:
				if m.editingParam == config.CallParamCallType {
					if m.callTypeSelector > 0 {
						m.callTypeSelector--
					}
					return m, nil
				}
			}
		}

		if config.IsKey(msgStr, config.KeyDown) {
			switch m.state {
			case types.StateMainMenu:
				if m.cursor < len(m.choices)-1 {
					m.cursor++
				}
			case types.StateCallParameterList:
				params := m.callParams.GetParams()
				if m.callParamCursor < len(params)-1 {
					m.callParamCursor++
				}
			case types.StateCallParameterEdit:
				if m.editingParam == config.CallParamCallType {
					options := types.GetCallTypeOptions()
					if m.callTypeSelector < len(options)-1 {
						m.callTypeSelector++
					}
					return m, nil
				}
			}
		}

		if config.IsKey(msgStr, config.KeySelect) {
			switch m.state {
			case types.StateMainMenu:
				return m.handleMainMenuSelect()
			case types.StateCallParameterList:
				m.validationError = "" // Clear validation errors when navigating to edit
				return m.handleCallParamSelect()
			case types.StateCallParameterEdit:
				return m.handleCallEditSave()
			case types.StateCallResult:
				m.state = types.StateMainMenu
				return m, nil
			}
		}
		
		if config.IsKey(msgStr, config.KeyBack) {
			switch m.state {
			case types.StateCallParameterList:
				m.state = types.StateMainMenu
				return m, nil
			case types.StateCallParameterEdit:
				m.state = types.StateCallParameterList
				return m, nil
			case types.StateCallResult:
				m.state = types.StateCallParameterList
				return m, nil
			}
		}
		
		if config.IsKey(msgStr, config.KeyExecute) && m.state == types.StateCallParameterList {
			return m.handleCallExecute()
		}
		
		if config.IsKey(msgStr, config.KeyReset) {
			switch m.state {
			case types.StateCallParameterList:
				return m.handleResetParameter()
			case types.StateCallParameterEdit:
				return m.handleResetCurrentParameter()
			}
		}
		
		if config.IsKey(msgStr, config.KeyResetAll) && m.state == types.StateCallParameterList {
			return m.handleResetAllParameters()
		}
		
		if m.state == types.StateCallParameterEdit {
			var cmd tea.Cmd
			m.textInput, cmd = m.textInput.Update(msg)
			return m, cmd
		}
	}

	return m, nil
}

func validateField(fieldName, value string) error {
	switch fieldName {
	case config.CallParamCaller:
		if _, err := primitives.AddressFromHex(value); err != nil {
			return config.NewInputParamError(config.ErrorInvalidCallerAddress, fieldName)
		}
	case config.CallParamTarget:
		if _, err := primitives.AddressFromHex(value); err != nil {
			return config.NewInputParamError(config.ErrorInvalidTargetAddress, fieldName)
		}
	case config.CallParamValue:
		if _, err := strconv.ParseUint(value, 10, 64); err != nil {
			return config.NewInputParamError(config.ErrorInvalidValue, fieldName)
		}
	case config.CallParamGasLimit:
		if _, err := strconv.ParseUint(value, 10, 64); err != nil {
			return config.NewInputParamError(config.ErrorInvalidGasLimit, fieldName)
		}
	case config.CallParamInput, config.CallParamInputDeploy:
		clean := strings.TrimPrefix(value, "0x")
		if clean != "" {
			if _, err := hex.DecodeString(clean); err != nil {
				return config.NewInputParamError(config.ErrorInvalidInputData, fieldName)
			}
		}
	case config.CallParamSalt:
		clean := strings.TrimPrefix(value, "0x")
		if _, err := hex.DecodeString(clean); err != nil {
			return config.NewInputParamError(config.ErrorInvalidSalt, fieldName)
		}
	}
	return nil
}

func (m Model) handleMainMenuSelect() (tea.Model, tea.Cmd) {
	switch m.choices[m.cursor] {
	case config.MenuMakeCall:
		m.state = types.StateCallParameterList
		m.callParamCursor = 0
		return m, nil
	case config.MenuExit:
		m.quitting = true
		return m, tea.Batch(tea.ExitAltScreen, tea.Quit)
	default:
		_, ok := m.selected[m.cursor]
		if ok {
			delete(m.selected, m.cursor)
		} else {
			m.selected[m.cursor] = struct{}{}
		}
		return m, nil
	}
}

func (m Model) handleCallParamSelect() (tea.Model, tea.Cmd) {
	params := m.callParams.GetParams()
	if m.callParamCursor >= len(params) {
		return m, nil
	}
	
	param := params[m.callParamCursor]
	m.editingParam = param.Name
	
	if param.Name == config.CallParamCallType {
		// Initialize call type selector with current value
		options := types.GetCallTypeOptions()
		m.callTypeSelector = 0
		for i, opt := range options {
			if opt == param.Value {
				m.callTypeSelector = i
				break
			}
		}
	} else {
		m.textInput = ui.CreateTextInput(param.Name, param.Value)
	}
	
	m.state = types.StateCallParameterEdit
	m.validationError = ""
	
	return m, nil
}

func (m Model) handleCallEditSave() (tea.Model, tea.Cmd) {
	if m.editingParam == config.CallParamCallType {
		// Handle call type selection
		options := types.GetCallTypeOptions()
		if m.callTypeSelector >= 0 && m.callTypeSelector < len(options) {
			selectedType := options[m.callTypeSelector]
			m.callParams.SetParam(m.editingParam, selectedType)
		}
		m.state = types.StateCallParameterList
		return m, nil
	}
	
	// Handle text input fields
	value := m.textInput.Value()
	
	// Field-specific validation
	if err := validateField(m.editingParam, value); err != nil {
		// Use UIError for better user experience in UI context
		if inputErr, ok := err.(config.InputParamError); ok {
			m.validationError = inputErr.UIError()
		} else {
			m.validationError = err.Error()
		}
		return m, nil
	}
	
	m.callParams.SetParam(m.editingParam, value)
	m.state = types.StateCallParameterList
	return m, nil
}

func (m Model) handleCallExecute() (tea.Model, tea.Cmd) {
	if err := validateCallParameters(m.callParams); err != nil {
		m.validationError = err.Error()
		return m, nil
	}
	
	m.state = types.StateCallExecuting
	return m, executeCallCmd(m.callParams)
}

func executeCallCmd(params types.CallParametersStrings) tea.Cmd {
	return func() tea.Msg {
		result, err := executeCall(params)
		if err != nil {
			result = &guillotine.CallResult{
				Success:   false,
				GasLeft:   0,
				Output:    nil,
				ErrorInfo: err.Error(),
				Logs:      nil,
			}
		}
		return callResultMsg{result: result}
	}
}

func (m Model) handleResetParameter() (tea.Model, tea.Cmd) {
	params := m.callParams.GetParams()
	if m.callParamCursor >= len(params) {
		return m, nil
	}
	
	param := params[m.callParamCursor]
	defaults := config.GetCallDefaults()
	
	switch param.Name {
	case config.CallParamCallType:
		m.callParams.SetParam(param.Name, types.CallTypeToString(defaults.CallType))
	case config.CallParamCaller:
		m.callParams.SetParam(param.Name, defaults.CallerAddr)
	case config.CallParamTarget:
		m.callParams.SetParam(param.Name, defaults.TargetAddr)
	case config.CallParamValue:
		m.callParams.SetParam(param.Name, defaults.Value)
	case config.CallParamGasLimit:
		m.callParams.SetParam(param.Name, "100000")
	case config.CallParamInput:
		m.callParams.SetParam(param.Name, defaults.InputData)
	case config.CallParamSalt:
		m.callParams.SetParam(param.Name, defaults.Salt)
	}
	
	return m, nil
}

func (m Model) handleResetCurrentParameter() (tea.Model, tea.Cmd) {
	defaults := config.GetCallDefaults()
	
	switch m.editingParam {
	case config.CallParamCallType:
		options := types.GetCallTypeOptions()
		defaultType := types.CallTypeToString(defaults.CallType)
		for i, opt := range options {
			if opt == defaultType {
				m.callTypeSelector = i
				break
			}
		}
	case config.CallParamCaller:
		m.textInput.SetValue(defaults.CallerAddr)
	case config.CallParamTarget:
		m.textInput.SetValue(defaults.TargetAddr)
	case config.CallParamValue:
		m.textInput.SetValue(defaults.Value)
	case config.CallParamGasLimit:
		m.textInput.SetValue("100000")
	case config.CallParamInput:
		m.textInput.SetValue(defaults.InputData)
	case config.CallParamSalt:
		m.textInput.SetValue(defaults.Salt)
	}
	
	m.validationError = ""
	return m, nil
}

func (m Model) handleResetAllParameters() (tea.Model, tea.Cmd) {
	m.callParams = types.NewCallParametersStrings()
	return m, nil
}

type callResultMsg struct {
	result *guillotine.CallResult
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
	
	switch m.state {
	case types.StateMainMenu:
		header := ui.RenderHeader(m.greeting, config.AppSubtitle, config.TitleStyle, config.SubtitleStyle)
		menu := ui.RenderMenu(m.choices, m.cursor, m.selected)
		help := ui.RenderHelpText()
		content := layout.ComposeVertical(header, menu, help)
		return layout.RenderWithBox(content)
		
	case types.StateCallParameterList:
		header := ui.RenderHeader(config.CallStateTitle, "", config.TitleStyle, config.SubtitleStyle)
		params := m.callParams.GetParams()
		callList := ui.RenderCallParameterList(params, m.callParamCursor, m.validationError)
		help := ui.RenderCallParameterListHelp()
		content := layout.ComposeVertical(header, callList, help)
		return layout.RenderWithBox(content)
		
	case types.StateCallParameterEdit:
		header := ui.RenderHeader(config.CallEditTitle, "", config.TitleStyle, config.SubtitleStyle)
		editView := ui.RenderCallEdit(m.editingParam, m.textInput, m.validationError, m.callTypeSelector)
		var help string
		if m.editingParam == config.CallParamCallType {
			help = ui.RenderCallEditTypeHelp()
		} else {
			help = ui.RenderCallEditHelp()
		}
		content := layout.ComposeVertical(header, editView, help)
		return layout.RenderWithBox(content)
		
	case types.StateCallExecuting:
		header := ui.RenderHeader(config.CallExecutingTitle, "", config.TitleStyle, config.SubtitleStyle)
		executing := ui.RenderCallExecuting()
		content := layout.ComposeVertical(header, executing, "")
		return layout.RenderWithBox(content)
		
	case types.StateCallResult:
		header := ui.RenderHeader(config.CallResultTitle, "", config.TitleStyle, config.SubtitleStyle)
		result := ui.RenderCallResult(m.callResult)
		help := ui.RenderCallResultHelp()
		content := layout.ComposeVertical(header, result, help)
		return layout.RenderWithBox(content)
		
	default:
		return "Invalid state"
	}
}

// validateCallParameters validates all parameters for an EVM call
func validateCallParameters(params types.CallParametersStrings) error {
	if params.CallType == "" {
		return config.NewInputParamError(config.ErrorCallTypeRequired, "call_type")
	}
	
	if _, err := primitives.AddressFromHex(params.Caller); err != nil {
		return config.NewInputParamError(config.ErrorInvalidCallerAddress, "caller")
	}
	
	if params.CallType != config.CallTypeCreate && params.CallType != config.CallTypeCreate2 {
		if _, err := primitives.AddressFromHex(params.Target); err != nil {
			return config.NewInputParamError(config.ErrorInvalidTargetAddress, "target")
		}
	}
	
	if _, err := strconv.ParseUint(params.GasLimit, 10, 64); err != nil {
		return config.NewInputParamError(config.ErrorInvalidGasLimit, "gas_limit")
	}
	
	if _, err := strconv.ParseUint(params.Value, 10, 64); err != nil {
		return config.NewInputParamError(config.ErrorInvalidValue, "value")
	}
	
	clean := strings.TrimPrefix(params.InputData, "0x")
	if clean != "" {
		if _, err := hex.DecodeString(clean); err != nil {
			return config.NewInputParamError(config.ErrorInvalidInputData, "input_data")
		}
	}
	
	if (params.CallType == config.CallTypeCreate2) {
		clean := strings.TrimPrefix(params.Salt, "0x")
		if _, err := hex.DecodeString(clean); err != nil {
			return config.NewInputParamError(config.ErrorInvalidSalt, "salt")
		}
	}
	
	return nil
}

// executeCall performs an EVM call using the SDK directly
func executeCall(params types.CallParametersStrings) (*guillotine.CallResult, error) {
	if err := validateCallParameters(params); err != nil {
		return nil, err
	}
	
	vm, err := evm.New()
	if err != nil {
		return nil, fmt.Errorf("failed to create EVM: %w", err)
	}
	defer vm.Destroy()
	
	caller, err := primitives.AddressFromHex(params.Caller)
	if err != nil {
		return nil, fmt.Errorf("invalid caller address: %w", err)
	}
	
	valueUint, _ := strconv.ParseUint(params.Value, 10, 64)
	value := big.NewInt(int64(valueUint))
	gasLimit, err := strconv.ParseUint(params.GasLimit, 10, 64)
	if err != nil {
		return nil, fmt.Errorf("invalid gas limit: %w", err)
	}
	
	clean := strings.TrimPrefix(params.InputData, "0x")
	var inputData []byte
	if clean != "" {
		var err error
		inputData, err = hex.DecodeString(clean)
		if err != nil {
			return nil, fmt.Errorf("invalid input data: %w", err)
		}
	}
	
	// Set caller balance
	if err := vm.SetBalance(caller, big.NewInt(1000000)); err != nil {
		return nil, fmt.Errorf("failed to set caller balance: %w", err)
	}
	
	callType := types.CallTypeFromString(params.CallType)
	var result *guillotine.CallResult
	
	switch callType {
	case guillotine.CallTypeCall:
		var target primitives.Address
		target, err = primitives.AddressFromHex(params.Target)
		if err != nil {
			return nil, fmt.Errorf("invalid target address: %w", err)
		}
		result, err = vm.Call(evm.Call{
			Caller: caller,
			To:     target,
			Value:  value,
			Input:  inputData,
			Gas:    gasLimit,
		})
		
	case guillotine.CallTypeCallcode:
		var target primitives.Address
		target, err = primitives.AddressFromHex(params.Target)
		if err != nil {
			return nil, fmt.Errorf("invalid target address: %w", err)
		}
		result, err = vm.Call(evm.Callcode{
			Caller: caller,
			To:     target,
			Value:  value,
			Input:  inputData,
			Gas:    gasLimit,
		})
		
	case guillotine.CallTypeStaticcall:
		var target primitives.Address
		target, err = primitives.AddressFromHex(params.Target)
		if err != nil {
			return nil, fmt.Errorf("invalid target address: %w", err)
		}
		result, err = vm.Call(evm.Staticcall{
			Caller: caller,
			To:     target,
			Input:  inputData,
			Gas:    gasLimit,
		})
		
	case guillotine.CallTypeDelegatecall:
		var target primitives.Address
		target, err = primitives.AddressFromHex(params.Target)
		if err != nil {
			return nil, fmt.Errorf("invalid target address: %w", err)
		}
		result, err = vm.Call(evm.Delegatecall{
			Caller: caller,
			To:     target,
			Input:  inputData,
			Gas:    gasLimit,
		})
		
	case guillotine.CallTypeCreate:
		result, err = vm.Call(evm.Create{
			Caller:   caller,
			Value:    value,
			InitCode: inputData,
			Gas:      gasLimit,
		})
		
	case guillotine.CallTypeCreate2:
		cleanSalt := strings.TrimPrefix(params.Salt, "0x")
		var saltBytes []byte
		saltBytes, err = hex.DecodeString(cleanSalt)
		if err != nil {
			return nil, fmt.Errorf("invalid salt: %w", err)
		}
		saltBig := big.NewInt(0).SetBytes(saltBytes)
		result, err = vm.Call(evm.Create2{
			Caller:   caller,
			Value:    value,
			InitCode: inputData,
			Salt:     saltBig,
			Gas:      gasLimit,
		})
		
	default:
		return nil, config.NewInputParamError(config.ErrorUnsupportedCallType, "call_type")
	}
	
	if err != nil {
		return &guillotine.CallResult{
			Success:   false,
			GasLeft:   0,
			Output:    nil,
			ErrorInfo: err.Error(),
			Logs:      nil,
		}, nil
	}
	
	return result, nil
}

