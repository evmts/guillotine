# CLI Code Quality Improvement Plan

## 🔴 Critical Issues (Must Fix)

1. **Remove duplicate validation functions**
   - `ui/clipboard_manager.go` duplicates `isValidAddress()`, `isValidHex()`, `isValidNumber()`
   - Action: Delete these from clipboard_manager.go and import from `utils/parsers.go`

2. **Split oversized model.go (596+ lines)**
   - Action: Extract into separate files:
     - `state_handlers.go` - State transition logic
     - `table_factory.go` - Table creation/update functions
     - `model_core.go` - Keep only Model struct and Init/Update/View

3. **Consolidate validation logic**
   - Validation scattered across 3 files
   - Action: Create `internal/app/validator.go` with centralized validation

## 🟡 Code Duplication Issues

4. **Extract table styling**
   - `createHistoryTable()` and `createContractsTable()` duplicate styling
   - Action: Create `createStyledTable()` helper in ui package

5. **Unify parameter reset logic**
   - `handleResetParameter()` and `handleResetCurrentParameter()` duplicate code
   - Action: Create single `resetParameter(name string)` method

6. **Simplify copy handler**
   - `handleCopy()` has repetitive switch cases
   - Action: Create `getCopyContent()` method per state

## 🟢 Architecture Improvements

7. **Remove unused tab system**
   - Tab-related code exists but never used
   - Action: Either implement tabs properly or remove entirely

8. **Create manager interfaces**
   - Action: Define `StateManager` interface for VMManager/HistoryManager consistency

9. **Centralize type conversions**
   - Action: Create `internal/app/converters.go` for all type conversions

10. **Extract business logic from UI model**
    - Action: Create `internal/app/controller.go` for business operations

## 🔵 Code Organization

11. **Move magic numbers to config**
    - Hardcoded: "100000" gas, table heights, padding
    - Action: Add to `config/defaults.go`

12. **Create proper error hierarchy**
    - Action: Define error types in `config/errors.go`:
      - `ValidationError`, `ExecutionError`, `SystemError`

13. **Consolidate state transitions**
    - Action: Create state machine in `state_transitions.go` already exists - use it!

14. **Extract UI component factory**
    - Action: Create `ui/factory.go` for common UI patterns

## 📊 Missing Quality Controls

15. **Add critical tests**
    - Action: Create tests for:
      - `call_executor_test.go`
      - `vm_manager_test.go`
      - `model_test.go`

16. **Add input sanitization layer**
    - Action: Create `utils/sanitizer.go` for consistent input cleaning

17. **Improve error context**
    - Action: Wrap all errors with context using `fmt.Errorf("context: %w", err)`

## 🧹 Quick Wins

18. **Remove commented code/TODOs**
    - Line 46 in call_executor.go has TODO
    - Action: Address or create issue tracker

19. **Consistent error messages**
    - Action: All user-facing errors through `config/messages.go`

20. **Simplify GetParams() logic**
    - Complex conditional parameter display
    - Action: Use parameter visibility map

## Priority Order:
1. Fix duplicate validation (item 1) - **Immediate**
2. Split model.go (item 2) - **High**
3. Remove unused tabs (item 7) - **High**
4. Extract table styling (item 4) - **Medium**
5. Add tests (item 15) - **Medium**
6. Everything else - **Low/Ongoing**