# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This is the Hank for Claude Code repository - an autonomous AI development loop system that enables continuous development cycles with intelligent exit detection and rate limiting.

See [README.md](README.md) for version info, changelog, and user documentation.

## Core Architecture

The system consists of four main bash scripts and a modular library system:

### Main Scripts

1. **hank_loop.sh** - The main autonomous loop that executes Claude Code repeatedly
2. **hank_monitor.sh** - Live monitoring dashboard for tracking loop status
3. **setup.sh** - Project initialization script for new Hank projects
4. **create_files.sh** - Bootstrap script that creates the entire Hank system
5. **hank_import.sh** - PRD/specification import tool that converts documents to Hank format
   - Uses modern Claude Code CLI with `--output-format json` for structured responses
   - Implements `detect_response_format()` and `parse_conversion_response()` for JSON parsing
   - Backward compatible with older CLI versions (automatic text fallback)
6. **hank_enable.sh** - Interactive wizard for enabling Hank in existing projects
   - Multi-step wizard with environment detection, task source selection, configuration
   - Imports tasks from beads, GitHub Issues, or PRD documents
   - Generates `.hankrc` project configuration file
7. **hank_enable_ci.sh** - Non-interactive version for CI/automation
   - Same functionality as interactive version with CLI flags
   - JSON output mode for machine parsing
   - Exit codes: 0 (success), 1 (error), 2 (already enabled)

### Library Components (lib/)

The system uses a modular architecture with reusable components in the `lib/` directory:

1. **lib/circuit_breaker.sh** - Circuit breaker pattern implementation
   - Prevents runaway loops by detecting stagnation
   - Three states: CLOSED (normal), HALF_OPEN (monitoring), OPEN (halted)
   - Configurable thresholds for no-progress and error detection
   - Automatic state transitions and recovery

2. **lib/response_analyzer.sh** - Intelligent response analysis
   - Analyzes Claude Code output for completion signals
   - **JSON output format detection and parsing** (with text fallback)
   - Supports both flat JSON format and Claude CLI format (`result`, `sessionId`, `metadata`)
   - Extracts structured fields: status, exit_signal, work_type, files_modified
   - **Session management**: `store_session_id()`, `get_last_session_id()`, `should_resume_session()`
   - Automatic session persistence to `.hank/.claude_session_id` file with 24-hour expiration
   - Session lifecycle: `get_session_id()`, `reset_session()`, `log_session_transition()`, `init_session_tracking()`
   - Session history tracked in `.hank/.hank_session_history` (last 50 transitions)
   - Session auto-reset on: circuit breaker open, manual interrupt, project completion
   - Detects test-only loops and stuck error patterns
   - Two-stage error filtering to eliminate false positives
   - Multi-line error matching for accurate stuck loop detection
   - Confidence scoring for exit decisions

3. **lib/date_utils.sh** - Cross-platform date utilities
   - ISO timestamp generation for logging
   - Epoch time calculations for rate limiting

4. **lib/timeout_utils.sh** - Cross-platform timeout command utilities
   - Detects and uses appropriate timeout command for the platform
   - Linux: Uses standard `timeout` from GNU coreutils
   - macOS: Uses `gtimeout` from Homebrew coreutils
   - `portable_timeout()` function for seamless cross-platform execution
   - Automatic detection with caching for performance

5. **lib/enable_core.sh** - Shared logic for hank enable commands
   - Idempotency checks: `check_existing_hank()`, `is_hank_enabled()`
   - Safe file operations: `safe_create_file()`, `safe_create_dir()`
   - Project detection: `detect_project_context()`, `detect_git_info()`, `detect_task_sources()`
   - Template generation: `generate_prompt_md()`, `generate_agent_md()`, `generate_fix_plan_md()`, `generate_hankrc()`

6. **lib/wizard_utils.sh** - Interactive prompt utilities for enable wizard
   - User prompts: `confirm()`, `prompt_text()`, `prompt_number()`
   - Selection utilities: `select_option()`, `select_multiple()`, `select_with_default()`
   - Output formatting: `print_header()`, `print_bullet()`, `print_success/warning/error/info()`

7. **lib/task_sources.sh** - Task import from external sources
   - Beads integration: `check_beads_available()`, `fetch_beads_tasks()`, `get_beads_count()`
   - GitHub integration: `check_github_available()`, `fetch_github_tasks()`, `get_github_issue_count()`
   - PRD extraction: `extract_prd_tasks()`, supports checkbox and numbered list formats
   - Task normalization: `normalize_tasks()`, `prioritize_tasks()`, `import_tasks_from_sources()`

## Key Commands

### Installation
```bash
# Install Hank globally (run once)
./install.sh

# Uninstall Hank
./install.sh uninstall
```

### Setting Up a New Project
```bash
# Create a new Hank-managed project (run from anywhere)
hank-setup my-project-name
cd my-project-name
```

### Migrating Existing Projects
```bash
# Migrate from flat structure to .hank/ subfolder (v0.10.0+)
cd existing-project
hank-migrate
```

### Enabling Hank in Existing Projects
```bash
# Interactive wizard (recommended for humans)
cd existing-project
hank-enable

# With specific task source
hank-enable --from beads
hank-enable --from github --label "sprint-1"
hank-enable --from prd ./docs/requirements.md

# Force overwrite existing .hank/
hank-enable --force

# Non-interactive for CI/scripts
hank-enable-ci                              # Sensible defaults
hank-enable-ci --from github               # With task source
hank-enable-ci --project-type typescript   # Override detection
hank-enable-ci --json                      # Machine-readable output
```

### Running the Hank Loop
```bash
# Start with integrated tmux monitoring (recommended)
hank --monitor

# Start without monitoring
hank

# With custom parameters and monitoring
hank --monitor --calls 50 --prompt my_custom_prompt.md

# Check current status
hank --status

# Circuit breaker management
hank --reset-circuit
hank --circuit-status

# Session management
hank --reset-session    # Reset session state manually
```

### Monitoring
```bash
# Integrated tmux monitoring (recommended)
hank --monitor

# Manual monitoring in separate terminal
hank-monitor

# tmux session management
tmux list-sessions
tmux attach -t <session-name>
```

### Running Tests
```bash
# Run all tests (420 tests)
npm test

# Run specific test suites
npm run test:unit
npm run test:integration

# Run individual test files
bats tests/unit/test_cli_parsing.bats
bats tests/unit/test_json_parsing.bats
bats tests/unit/test_cli_modern.bats
bats tests/unit/test_enable_core.bats
bats tests/unit/test_task_sources.bats
bats tests/unit/test_hank_enable.bats
```

## Hank Loop Configuration

The loop is controlled by several key files and environment variables within the `.hank/` subfolder:

- **.hank/PROMPT.md** - Main prompt file that drives each loop iteration
- **.hank/fix_plan.md** - Prioritized task list that Hank follows
- **.hank/AGENT.md** - Build and run instructions maintained by Hank
- **.hank/status.json** - Real-time status tracking (JSON format)
- **.hank/logs/** - Execution logs for each loop iteration

### Rate Limiting
- Default: 100 API calls per hour (configurable via `--calls` flag)
- Automatic hourly reset with countdown display
- Call tracking persists across script restarts

### Modern CLI Configuration (Phase 1.1)

Hank uses modern Claude Code CLI flags for structured communication:

**Configuration Variables:**
```bash
CLAUDE_OUTPUT_FORMAT="json"           # Output format: json (default) or text
CLAUDE_ALLOWED_TOOLS="Write,Read,Edit,Bash(git *),Bash(npm *),Bash(pytest)"  # Allowed tool permissions
CLAUDE_USE_CONTINUE=true              # Enable session continuity
CLAUDE_MIN_VERSION="2.0.76"           # Minimum Claude CLI version
```

**CLI Options:**
- `--output-format json|text` - Set Claude output format (default: json)
- `--allowed-tools "Write,Read,Bash(git *)"` - Restrict allowed tools
- `--no-continue` - Disable session continuity, start fresh each loop

**Loop Context:**
Each loop iteration injects context via `build_loop_context()`:
- Current loop number
- Remaining tasks from fix_plan.md
- Circuit breaker state (if not CLOSED)
- Previous loop work summary

**Session Continuity:**
- Sessions are preserved in `.hank/.claude_session_id`
- Use `--continue` flag to maintain context across loops
- Disable with `--no-continue` for isolated iterations

### Intelligent Exit Detection
The loop uses a dual-condition check to prevent premature exits during productive iterations:

**Exit requires BOTH conditions:**
1. `recent_completion_indicators >= 2` (heuristic-based detection from natural language patterns)
2. Claude's explicit `EXIT_SIGNAL: true` in the HANK_STATUS block

The `EXIT_SIGNAL` value is read from `.hank/.response_analysis` (at `.analysis.exit_signal`) which is populated by `response_analyzer.sh` from Claude's HANK_STATUS output block.

**Other exit conditions (checked before completion indicators):**
- Multiple consecutive "done" signals from Claude Code (`done_signals >= 2`)
- Too many test-only loops indicating feature completeness (`test_loops >= 3`)
- All items in .hank/fix_plan.md marked as completed

**Example behavior when EXIT_SIGNAL is false:**
```
Loop 5: Claude outputs "Phase complete, moving to next feature"
        → completion_indicators: 3 (high confidence from patterns)
        → EXIT_SIGNAL: false (Claude explicitly says more work needed)
        → Result: CONTINUE (respects Claude's explicit intent)

Loop 8: Claude outputs "All tasks complete, project ready"
        → completion_indicators: 4
        → EXIT_SIGNAL: true (Claude confirms project is done)
        → Result: EXIT with "project_complete"
```

**Rationale:** Natural language patterns like "done" or "complete" can trigger false positives during productive work (e.g., "feature done, moving to tests"). By requiring Claude's explicit EXIT_SIGNAL confirmation, Hank avoids exiting mid-iteration when Claude is still working.

## CI/CD Pipeline

Hank uses GitHub Actions for continuous integration:

### Workflows (`.github/workflows/`)

1. **test.yml** - Main test suite
   - Runs on push to `main`/`develop` and PRs to `main`
   - Executes unit, integration, and E2E tests
   - Coverage reporting with kcov (informational only)
   - Uploads coverage artifacts

2. **claude.yml** - Claude Code GitHub Actions integration
   - Automated code review capabilities

3. **claude-code-review.yml** - PR code review workflow
   - Automated review on pull requests

### Coverage Note
Bash code coverage measurement with kcov has fundamental limitations when tracing subprocess executions. The `COVERAGE_THRESHOLD` is set to 0 (disabled) because kcov cannot instrument subprocesses spawned by bats. **Test pass rate (100%) is the quality gate.** See [bats-core#15](https://github.com/bats-core/bats-core/issues/15) for details.

## Project Structure for Hank-Managed Projects

Each project created with `./setup.sh` follows this structure with a `.hank/` subfolder:
```
project-name/
├── .hank/                # Hank configuration and state (hidden folder)
│   ├── PROMPT.md          # Main development instructions
│   ├── fix_plan.md       # Prioritized TODO list
│   ├── AGENT.md          # Build/run instructions
│   ├── specs/             # Project specifications
│   ├── examples/          # Usage examples
│   ├── logs/              # Loop execution logs
│   └── docs/generated/    # Auto-generated documentation
└── src/                   # Source code (at project root)
```

> **Migration**: Existing projects can be migrated with `hank-migrate`.

## Template System

Templates in `templates/` provide starting points for new projects:
- **PROMPT.md** - Instructions for Hank's autonomous behavior
- **fix_plan.md** - Initial task structure
- **AGENT.md** - Build system template

## File Naming Conventions

- Hank control files (`fix_plan.md`, `AGENT.md`, `PROMPT.md`) reside in the `.hank/` directory
- Hidden files within `.hank/` (e.g., `.hank/.call_count`, `.hank/.exit_signals`) track loop state
- `.hank/logs/` contains timestamped execution logs
- `.hank/docs/generated/` for Hank-created documentation
- `docs/code-review/` for code review reports (at project root)

## Global Installation

Hank installs to:
- **Commands**: `~/.local/bin/` (hank, hank-monitor, hank-setup, hank-import, hank-migrate, hank-enable, hank-enable-ci)
- **Templates**: `~/.hank/templates/`
- **Scripts**: `~/.hank/` (hank_loop.sh, hank_monitor.sh, setup.sh, hank_import.sh, migrate_to_hank_folder.sh, hank_enable.sh, hank_enable_ci.sh)
- **Libraries**: `~/.hank/lib/` (circuit_breaker.sh, response_analyzer.sh, date_utils.sh, timeout_utils.sh, enable_core.sh, wizard_utils.sh, task_sources.sh)

After installation, the following global commands are available:
- `hank` - Start the autonomous development loop
- `hank-monitor` - Launch the monitoring dashboard
- `hank-setup` - Create a new Hank-managed project
- `hank-import` - Import PRD/specification documents to Hank format
- `hank-migrate` - Migrate existing projects from flat structure to `.hank/` subfolder
- `hank-enable` - Interactive wizard to enable Hank in existing projects
- `hank-enable-ci` - Non-interactive version for CI/automation

## Integration Points

Hank integrates with:
- **Claude Code CLI**: Uses `npx @anthropic/claude-code` as the execution engine
- **tmux**: Terminal multiplexer for integrated monitoring sessions
- **Git**: Expects projects to be git repositories
- **jq**: For JSON processing of status and exit signals
- **GitHub Actions**: CI/CD pipeline for automated testing
- **Standard Unix tools**: bash, grep, date, etc.

## Exit Conditions and Thresholds

Hank uses multiple mechanisms to detect when to exit:

### Exit Detection Thresholds
- `MAX_CONSECUTIVE_TEST_LOOPS=3` - Exit if too many test-only iterations
- `MAX_CONSECUTIVE_DONE_SIGNALS=2` - Exit on repeated completion signals
- `TEST_PERCENTAGE_THRESHOLD=30%` - Flag if testing dominates recent loops
- Completion detection via .hank/fix_plan.md checklist items

### Completion Indicators with EXIT_SIGNAL Gate

The `completion_indicators` exit condition requires dual verification:

| completion_indicators | EXIT_SIGNAL | .response_analysis | Result |
|-----------------------|-------------|-------------------|--------|
| >= 2 | `true` | exists | **Exit** ("project_complete") |
| >= 2 | `false` | exists | **Continue** (Claude still working) |
| >= 2 | N/A | missing | **Continue** (defaults to false) |
| >= 2 | N/A | malformed | **Continue** (defaults to false) |
| < 2 | `true` | exists | **Continue** (threshold not met) |

**Implementation** (`hank_loop.sh:312-327`):
```bash
local claude_exit_signal="false"
if [[ -f "$HANK_DIR/.response_analysis" ]]; then
    claude_exit_signal=$(jq -r '.analysis.exit_signal // false' "$HANK_DIR/.response_analysis" 2>/dev/null || echo "false")
fi

if [[ $recent_completion_indicators -ge 2 ]] && [[ "$claude_exit_signal" == "true" ]]; then
    echo "project_complete"
    return 0
fi
```

**Conflict Resolution:** When `STATUS: COMPLETE` but `EXIT_SIGNAL: false` in HANK_STATUS, the explicit EXIT_SIGNAL takes precedence. This allows Claude to mark a phase complete while indicating more phases remain.

### Circuit Breaker Thresholds
- `CB_NO_PROGRESS_THRESHOLD=3` - Open circuit after 3 loops with no file changes
- `CB_SAME_ERROR_THRESHOLD=5` - Open circuit after 5 loops with repeated errors
- `CB_OUTPUT_DECLINE_THRESHOLD=70%` - Open circuit if output declines by >70%
- `CB_PERMISSION_DENIAL_THRESHOLD=2` - Open circuit after 2 loops with permission denials (Issue #101)

### Permission Denial Detection (Issue #101)

When Claude Code is denied permission to execute commands (e.g., `npm install`), Hank detects this from the `permission_denials` array in the JSON output and halts the loop immediately:

1. **Detection**: The `parse_json_response()` function extracts `permission_denials` from Claude Code output
2. **Fields tracked**:
   - `has_permission_denials` (boolean)
   - `permission_denial_count` (integer)
   - `denied_commands` (array of command strings)
3. **Exit behavior**: When `has_permission_denials=true`, Hank exits with reason "permission_denied"
4. **User guidance**: Hank displays instructions to update `ALLOWED_TOOLS` in `.hankrc`

**Example `.hankrc` tool patterns:**
```bash
# Broad patterns (recommended for development)
ALLOWED_TOOLS="Write,Read,Edit,Bash(git *),Bash(npm *),Bash(pytest)"

# Specific patterns (more restrictive)
ALLOWED_TOOLS="Write,Read,Edit,Bash(git commit),Bash(npm install)"
```

### Error Detection

Hank uses advanced error detection with two-stage filtering to eliminate false positives:

**Stage 1: JSON Field Filtering**
- Filters out JSON field patterns like `"is_error": false` that contain the word "error" but aren't actual errors
- Pattern: `grep -v '"[^"]*error[^"]*":'`

**Stage 2: Actual Error Detection**
- Detects real error messages in specific contexts:
  - Error prefixes: `Error:`, `ERROR:`, `error:`
  - Context-specific errors: `]: error`, `Link: error`
  - Error occurrences: `Error occurred`, `failed with error`
  - Exceptions: `Exception`, `Fatal`, `FATAL`
- Pattern: `grep -cE '(^Error:|^ERROR:|^error:|\]: error|Link: error|Error occurred|failed with error|[Ee]xception|Fatal|FATAL)'`

**Multi-line Error Matching**
- Detects stuck loops by verifying ALL error lines appear in ALL recent history files
- Uses literal fixed-string matching (`grep -qF`) to avoid regex edge cases
- Prevents false negatives when multiple distinct errors occur simultaneously

## Test Suite

### Test Files (420 tests total)

| File | Tests | Description |
|------|-------|-------------|
| `test_cli_parsing.bats` | 27 | CLI argument parsing for all 12 flags |
| `test_cli_modern.bats` | 29 | Modern CLI commands (Phase 1.1) + build_claude_command fix |
| `test_json_parsing.bats` | 45 | JSON output format parsing + Claude CLI format + session management + array format |
| `test_session_continuity.bats` | 28 | Session lifecycle management + circuit breaker integration + issue #91 fix |
| `test_exit_detection.bats` | 53 | Exit signal detection + EXIT_SIGNAL-based completion indicators + progress detection |
| `test_rate_limiting.bats` | 15 | Rate limiting behavior |
| `test_loop_execution.bats` | 20 | Integration tests |
| `test_edge_cases.bats` | 20 | Edge case handling |
| `test_installation.bats` | 14 | Global installation/uninstall workflows |
| `test_project_setup.bats` | 36 | Project setup (setup.sh) validation |
| `test_prd_import.bats` | 33 | PRD import (hank_import.sh) workflows + modern CLI tests |
| `test_enable_core.bats` | 30 | Enable core library (idempotency, project detection, template generation) |
| `test_task_sources.bats` | 23 | Task sources (beads, GitHub, PRD extraction, normalization) |
| `test_hank_enable.bats` | 22 | Hank enable integration tests (wizard, CI version, JSON output) |
| `test_wizard_utils.bats` | 20 | Wizard utility functions (stdout/stderr separation, prompt functions) |

### Running Tests
```bash
# All tests
npm test

# Unit tests only
npm run test:unit

# Specific test file
bats tests/unit/test_cli_parsing.bats
```

## Feature Development Quality Standards

**CRITICAL**: All new features MUST meet the following mandatory requirements before being considered complete.

### Testing Requirements

- **Test Pass Rate**: 100% - all tests must pass, no exceptions
- **Test Types Required**:
  - Unit tests for bash script functions (if applicable)
  - Integration tests for Hank loop behavior
  - End-to-end tests for full development cycles
- **Test Quality**: Tests must validate behavior, not just achieve coverage metrics
- **Test Documentation**: Complex test scenarios must include comments explaining the test strategy

> **Note on Coverage**: The 85% coverage threshold is aspirational for bash scripts. Due to kcov subprocess limitations, test pass rate is the enforced quality gate.

### Git Workflow Requirements

Before moving to the next feature, ALL changes must be:

1. **Committed with Clear Messages**:
   ```bash
   git add .
   git commit -m "feat(module): descriptive message following conventional commits"
   ```
   - Use conventional commit format: `feat:`, `fix:`, `docs:`, `test:`, `refactor:`, etc.
   - Include scope when applicable: `feat(loop):`, `fix(monitor):`, `test(setup):`
   - Write descriptive messages that explain WHAT changed and WHY

2. **Pushed to Remote Repository**:
   ```bash
   git push origin <branch-name>
   ```
   - Never leave completed features uncommitted
   - Push regularly to maintain backup and enable collaboration
   - Ensure CI/CD pipelines pass before considering feature complete

3. **Branch Hygiene**:
   - Work on feature branches, never directly on `main`
   - Branch naming convention: `feature/<feature-name>`, `fix/<issue-name>`, `docs/<doc-update>`
   - Create pull requests for all significant changes

4. **Hank Integration**:
   - Update .hank/fix_plan.md with new tasks before starting work
   - Mark items complete in .hank/fix_plan.md upon completion
   - Update .hank/PROMPT.md if Hank's behavior needs modification
   - Test Hank loop with new features before completion

### Documentation Requirements

**ALL implementation documentation MUST remain synchronized with the codebase**:

1. **Script Documentation**:
   - Bash: Comments for all functions and complex logic
   - Update inline comments when implementation changes
   - Remove outdated comments immediately

2. **Implementation Documentation**:
   - Update relevant sections in this CLAUDE.md file
   - Keep template files in `templates/` current
   - Update configuration examples when defaults change
   - Document breaking changes prominently

3. **README Updates**:
   - Keep feature lists current
   - Update setup instructions when commands change
   - Maintain accurate command examples
   - Update version compatibility information

4. **Template Maintenance**:
   - Update template files when new patterns are introduced
   - Keep PROMPT.md template current with best practices
   - Update AGENT.md template with new build patterns
   - Document new Hank configuration options

5. **CLAUDE.md Maintenance**:
   - Add new commands to "Key Commands" section
   - Update "Exit Conditions and Thresholds" when logic changes
   - Keep installation instructions accurate and tested
   - Document new Hank loop behaviors or quality gates

### Feature Completion Checklist

Before marking ANY feature as complete, verify:

- [ ] All tests pass (if applicable)
- [ ] Script functionality manually tested
- [ ] All changes committed with conventional commit messages
- [ ] All commits pushed to remote repository
- [ ] CI/CD pipeline passes
- [ ] .hank/fix_plan.md task marked as complete
- [ ] Implementation documentation updated
- [ ] Inline code comments updated or added
- [ ] CLAUDE.md updated (if new patterns introduced)
- [ ] Template files updated (if applicable)
- [ ] Breaking changes documented
- [ ] Hank loop tested with new features
- [ ] Installation process verified (if applicable)

### Rationale

These standards ensure:
- **Quality**: Thorough testing prevents regressions in Hank's autonomous behavior
- **Traceability**: Git commits and fix_plan.md provide clear history of changes
- **Maintainability**: Current documentation reduces onboarding time and prevents knowledge loss
- **Collaboration**: Pushed changes enable team visibility and code review
- **Reliability**: Consistent quality gates maintain Hank loop stability
- **Automation**: Hank integration ensures continuous development practices

**Enforcement**: AI agents should automatically apply these standards to all feature development tasks without requiring explicit instruction for each task.
