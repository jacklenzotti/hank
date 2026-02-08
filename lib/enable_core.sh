#!/usr/bin/env bash

# enable_core.sh - Shared logic for hank enable commands
# Provides idempotency checks, safe file creation, and project detection
#
# Used by:
#   - hank_enable.sh (interactive wizard)
#   - hank_enable_ci.sh (non-interactive CI version)

# Exit codes - specific codes for different failure types
export ENABLE_SUCCESS=0           # Successful completion
export ENABLE_ERROR=1             # General error
export ENABLE_ALREADY_ENABLED=2   # Hank already enabled (use --force)
export ENABLE_INVALID_ARGS=3      # Invalid command line arguments
export ENABLE_FILE_NOT_FOUND=4    # Required file not found (e.g., PRD file)
export ENABLE_DEPENDENCY_MISSING=5 # Required dependency missing (e.g., jq for --json)
export ENABLE_PERMISSION_DENIED=6 # Cannot create files/directories

# Colors (can be disabled for non-interactive mode)
export ENABLE_USE_COLORS="${ENABLE_USE_COLORS:-true}"

_color() {
    if [[ "$ENABLE_USE_COLORS" == "true" ]]; then
        echo -e "$1"
    else
        echo -e "$2"
    fi
}

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Logging function
enable_log() {
    local level=$1
    local message=$2
    local color=""

    case $level in
        "INFO")  color=$BLUE ;;
        "WARN")  color=$YELLOW ;;
        "ERROR") color=$RED ;;
        "SUCCESS") color=$GREEN ;;
        "SKIP") color=$CYAN ;;
    esac

    if [[ "$ENABLE_USE_COLORS" == "true" ]]; then
        echo -e "${color}[$level]${NC} $message"
    else
        echo "[$level] $message"
    fi
}

# =============================================================================
# IDEMPOTENCY CHECKS
# =============================================================================

# check_existing_hank - Check if .hank directory exists and its state
#
# Returns:
#   0 - No .hank directory, safe to proceed
#   1 - .hank exists but incomplete (partial setup)
#   2 - .hank exists and fully initialized
#
# Outputs:
#   Sets global HANK_STATE: "none" | "partial" | "complete"
#   Sets global HANK_MISSING_FILES: array of missing files if partial
#
check_existing_hank() {
    HANK_STATE="none"
    HANK_MISSING_FILES=()

    if [[ ! -d ".hank" ]]; then
        HANK_STATE="none"
        return 0
    fi

    # Check for required files
    # Accept either IMPLEMENTATION_PLAN.md (new) or fix_plan.md (legacy)
    local required_files=(
        ".hank/PROMPT.md"
        ".hank/AGENT.md"
    )
    local has_plan=false
    if [[ -f ".hank/IMPLEMENTATION_PLAN.md" ]] || [[ -f ".hank/fix_plan.md" ]]; then
        has_plan=true
    fi

    local missing=()
    local found=0

    for file in "${required_files[@]}"; do
        if [[ -f "$file" ]]; then
            found=$((found + 1))
        else
            missing+=("$file")
        fi
    done

    # Add plan file to missing if neither variant exists
    if [[ "$has_plan" == "false" ]]; then
        missing+=(".hank/IMPLEMENTATION_PLAN.md")
    else
        found=$((found + 1))
    fi

    HANK_MISSING_FILES=("${missing[@]}")

    if [[ $found -eq 0 ]]; then
        HANK_STATE="none"
        return 0
    elif [[ ${#missing[@]} -gt 0 ]]; then
        HANK_STATE="partial"
        return 1
    else
        HANK_STATE="complete"
        return 2
    fi
}

# is_hank_enabled - Simple check if Hank is fully enabled
#
# Returns:
#   0 - Hank is fully enabled
#   1 - Hank is not enabled or only partially
#
is_hank_enabled() {
    check_existing_hank || true
    [[ "$HANK_STATE" == "complete" ]]
}

# =============================================================================
# SAFE FILE OPERATIONS
# =============================================================================

# safe_create_file - Create a file only if it doesn't exist (or force overwrite)
#
# Parameters:
#   $1 (target) - Target file path
#   $2 (content) - Content to write (can be empty string)
#
# Environment:
#   ENABLE_FORCE - If "true", overwrites existing files instead of skipping
#
# Returns:
#   0 - File created/overwritten successfully
#   1 - File already exists (skipped, only when ENABLE_FORCE is not true)
#   2 - Error creating file
#
# Side effects:
#   Logs [CREATE], [OVERWRITE], or [SKIP] message
#
safe_create_file() {
    local target=$1
    local content=$2
    local force="${ENABLE_FORCE:-false}"

    if [[ -f "$target" ]]; then
        if [[ "$force" == "true" ]]; then
            # Force mode: overwrite existing file
            enable_log "INFO" "Overwriting $target (--force)"
        else
            # Normal mode: skip existing file
            enable_log "SKIP" "$target already exists"
            return 1
        fi
    fi

    # Create parent directory if needed
    local parent_dir
    parent_dir=$(dirname "$target")
    if [[ ! -d "$parent_dir" ]]; then
        if ! mkdir -p "$parent_dir" 2>/dev/null; then
            enable_log "ERROR" "Failed to create directory: $parent_dir"
            return 2
        fi
    fi

    # Write content to file using printf to avoid shell injection
    # printf '%s\n' is safer than echo for arbitrary content (handles backslashes, -n, etc.)
    if printf '%s\n' "$content" > "$target" 2>/dev/null; then
        if [[ -f "$target" ]] && [[ "$force" == "true" ]]; then
            enable_log "SUCCESS" "Overwrote $target"
        else
            enable_log "SUCCESS" "Created $target"
        fi
        return 0
    else
        enable_log "ERROR" "Failed to create: $target"
        return 2
    fi
}

# safe_create_dir - Create a directory only if it doesn't exist
#
# Parameters:
#   $1 (target) - Target directory path
#
# Returns:
#   0 - Directory created or already exists
#   1 - Error creating directory
#
safe_create_dir() {
    local target=$1

    if [[ -d "$target" ]]; then
        return 0
    fi

    if mkdir -p "$target" 2>/dev/null; then
        enable_log "SUCCESS" "Created directory: $target"
        return 0
    else
        enable_log "ERROR" "Failed to create directory: $target"
        return 1
    fi
}

# =============================================================================
# DIRECTORY STRUCTURE
# =============================================================================

# create_hank_structure - Create the .hank/ directory structure
#
# Creates:
#   .hank/
#   .hank/specs/
#   .hank/examples/
#   .hank/logs/
#   .hank/docs/generated/
#
# Returns:
#   0 - Structure created successfully
#   1 - Error creating structure
#
create_hank_structure() {
    local dirs=(
        ".hank"
        ".hank/specs"
        ".hank/examples"
        ".hank/logs"
        ".hank/docs/generated"
    )

    for dir in "${dirs[@]}"; do
        if ! safe_create_dir "$dir"; then
            return 1
        fi
    done

    return 0
}

# =============================================================================
# PROJECT DETECTION
# =============================================================================

# Exported detection results
export DETECTED_PROJECT_NAME=""
export DETECTED_PROJECT_TYPE=""
export DETECTED_FRAMEWORK=""
export DETECTED_BUILD_CMD=""
export DETECTED_TEST_CMD=""
export DETECTED_RUN_CMD=""

# detect_project_context - Detect project type, name, and build commands
#
# Detects:
#   - Project type: javascript, typescript, python, rust, go, unknown
#   - Framework: nextjs, fastapi, express, etc.
#   - Build/test/run commands based on detected tooling
#
# Sets globals:
#   DETECTED_PROJECT_NAME - Project name (from package.json, folder, etc.)
#   DETECTED_PROJECT_TYPE - Language/type
#   DETECTED_FRAMEWORK - Framework if detected
#   DETECTED_BUILD_CMD - Build command
#   DETECTED_TEST_CMD - Test command
#   DETECTED_RUN_CMD - Run/start command
#
detect_project_context() {
    # Reset detection results
    DETECTED_PROJECT_NAME=""
    DETECTED_PROJECT_TYPE="unknown"
    DETECTED_FRAMEWORK=""
    DETECTED_BUILD_CMD=""
    DETECTED_TEST_CMD=""
    DETECTED_RUN_CMD=""

    # Detect from package.json (JavaScript/TypeScript)
    if [[ -f "package.json" ]]; then
        DETECTED_PROJECT_TYPE="javascript"

        # Check for TypeScript
        if grep -q '"typescript"' package.json 2>/dev/null || \
           [[ -f "tsconfig.json" ]]; then
            DETECTED_PROJECT_TYPE="typescript"
        fi

        # Extract project name
        if command -v jq &>/dev/null; then
            DETECTED_PROJECT_NAME=$(jq -r '.name // empty' package.json 2>/dev/null)
        else
            # Fallback: grep for name field
            DETECTED_PROJECT_NAME=$(grep -m1 '"name"' package.json | sed 's/.*: *"\([^"]*\)".*/\1/' 2>/dev/null)
        fi

        # Detect framework
        if grep -q '"next"' package.json 2>/dev/null; then
            DETECTED_FRAMEWORK="nextjs"
        elif grep -q '"express"' package.json 2>/dev/null; then
            DETECTED_FRAMEWORK="express"
        elif grep -q '"react"' package.json 2>/dev/null; then
            DETECTED_FRAMEWORK="react"
        elif grep -q '"vue"' package.json 2>/dev/null; then
            DETECTED_FRAMEWORK="vue"
        fi

        # Set build commands
        DETECTED_BUILD_CMD="npm run build"
        DETECTED_TEST_CMD="npm test"
        DETECTED_RUN_CMD="npm start"

        # Check for yarn
        if [[ -f "yarn.lock" ]]; then
            DETECTED_BUILD_CMD="yarn build"
            DETECTED_TEST_CMD="yarn test"
            DETECTED_RUN_CMD="yarn start"
        fi

        # Check for pnpm
        if [[ -f "pnpm-lock.yaml" ]]; then
            DETECTED_BUILD_CMD="pnpm build"
            DETECTED_TEST_CMD="pnpm test"
            DETECTED_RUN_CMD="pnpm start"
        fi
    fi

    # Detect from pyproject.toml or setup.py (Python)
    if [[ -f "pyproject.toml" ]] || [[ -f "setup.py" ]]; then
        DETECTED_PROJECT_TYPE="python"

        # Extract project name from pyproject.toml
        if [[ -f "pyproject.toml" ]]; then
            DETECTED_PROJECT_NAME=$(grep -m1 '^name' pyproject.toml | sed 's/.*= *"\([^"]*\)".*/\1/' 2>/dev/null)

            # Detect framework
            if grep -q 'fastapi' pyproject.toml 2>/dev/null; then
                DETECTED_FRAMEWORK="fastapi"
            elif grep -q 'django' pyproject.toml 2>/dev/null; then
                DETECTED_FRAMEWORK="django"
            elif grep -q 'flask' pyproject.toml 2>/dev/null; then
                DETECTED_FRAMEWORK="flask"
            fi
        fi

        # Set build commands (prefer uv if detected)
        if [[ -f "uv.lock" ]] || command -v uv &>/dev/null; then
            DETECTED_BUILD_CMD="uv sync"
            DETECTED_TEST_CMD="uv run pytest"
            DETECTED_RUN_CMD="uv run python -m ${DETECTED_PROJECT_NAME:-main}"
        else
            DETECTED_BUILD_CMD="pip install -e ."
            DETECTED_TEST_CMD="pytest"
            DETECTED_RUN_CMD="python -m ${DETECTED_PROJECT_NAME:-main}"
        fi
    fi

    # Detect from Cargo.toml (Rust)
    if [[ -f "Cargo.toml" ]]; then
        DETECTED_PROJECT_TYPE="rust"
        DETECTED_PROJECT_NAME=$(grep -m1 '^name' Cargo.toml | sed 's/.*= *"\([^"]*\)".*/\1/' 2>/dev/null)
        DETECTED_BUILD_CMD="cargo build"
        DETECTED_TEST_CMD="cargo test"
        DETECTED_RUN_CMD="cargo run"
    fi

    # Detect from go.mod (Go)
    if [[ -f "go.mod" ]]; then
        DETECTED_PROJECT_TYPE="go"
        DETECTED_PROJECT_NAME=$(head -1 go.mod | sed 's/module //' 2>/dev/null)
        DETECTED_BUILD_CMD="go build"
        DETECTED_TEST_CMD="go test ./..."
        DETECTED_RUN_CMD="go run ."
    fi

    # Fallback project name to folder name
    if [[ -z "$DETECTED_PROJECT_NAME" ]]; then
        DETECTED_PROJECT_NAME=$(basename "$(pwd)")
    fi
}

# detect_git_info - Detect git repository information
#
# Sets globals:
#   DETECTED_GIT_REPO - true if in git repo
#   DETECTED_GIT_REMOTE - Remote URL (origin)
#   DETECTED_GIT_GITHUB - true if GitHub remote
#
export DETECTED_GIT_REPO="false"
export DETECTED_GIT_REMOTE=""
export DETECTED_GIT_GITHUB="false"

detect_git_info() {
    DETECTED_GIT_REPO="false"
    DETECTED_GIT_REMOTE=""
    DETECTED_GIT_GITHUB="false"

    # Check if in git repo
    if git rev-parse --git-dir &>/dev/null; then
        DETECTED_GIT_REPO="true"

        # Get remote URL
        DETECTED_GIT_REMOTE=$(git remote get-url origin 2>/dev/null || echo "")

        # Check if GitHub
        if [[ "$DETECTED_GIT_REMOTE" == *"github.com"* ]]; then
            DETECTED_GIT_GITHUB="true"
        fi
    fi
}

# detect_task_sources - Detect available task sources
#
# Sets globals:
#   DETECTED_BEADS_AVAILABLE - true if .beads directory exists
#   DETECTED_GITHUB_AVAILABLE - true if GitHub remote detected
#   DETECTED_PRD_FILES - Array of potential PRD files found
#
export DETECTED_BEADS_AVAILABLE="false"
export DETECTED_GITHUB_AVAILABLE="false"
declare -a DETECTED_PRD_FILES=()

detect_task_sources() {
    DETECTED_BEADS_AVAILABLE="false"
    DETECTED_GITHUB_AVAILABLE="false"
    DETECTED_PRD_FILES=()

    # Check for beads
    if [[ -d ".beads" ]]; then
        DETECTED_BEADS_AVAILABLE="true"
    fi

    # Check for GitHub (reuse git detection)
    detect_git_info
    DETECTED_GITHUB_AVAILABLE="$DETECTED_GIT_GITHUB"

    # Search for PRD/spec files
    local search_dirs=("docs" "specs" "." "requirements")
    local prd_patterns=("*prd*.md" "*PRD*.md" "*requirements*.md" "*spec*.md" "*specification*.md")

    for dir in "${search_dirs[@]}"; do
        if [[ -d "$dir" ]]; then
            for pattern in "${prd_patterns[@]}"; do
                while IFS= read -r -d '' file; do
                    DETECTED_PRD_FILES+=("$file")
                done < <(find "$dir" -maxdepth 2 -name "$pattern" -print0 2>/dev/null)
            done
        fi
    done
}

# =============================================================================
# TEMPLATE GENERATION
# =============================================================================

# get_templates_dir - Get the templates directory path
#
# Returns:
#   Echoes the path to templates directory
#   Returns 1 if not found
#
get_templates_dir() {
    # Check global installation first
    if [[ -d "$HOME/.hank/templates" ]]; then
        echo "$HOME/.hank/templates"
        return 0
    fi

    # Check local installation (development)
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ -d "$script_dir/../templates" ]]; then
        echo "$script_dir/../templates"
        return 0
    fi

    return 1
}

# generate_prompt_md - Generate PROMPT.md with project context
#
# Parameters:
#   $1 (project_name) - Project name
#   $2 (project_type) - Project type (typescript, python, etc.)
#   $3 (framework) - Framework if any (optional)
#   $4 (objectives) - Custom objectives (optional, newline-separated)
#
# Outputs to stdout
#
generate_prompt_md() {
    local project_name="${1:-$(basename "$(pwd)")}"
    local project_type="${2:-unknown}"
    local framework="${3:-}"
    local objectives="${4:-}"

    cat << 'PROMPTEOF'
# Hank Build Instructions

0a. Study .hank/specs/* with up to 500 parallel Sonnet subagents to learn the application specifications.
0b. Study @IMPLEMENTATION_PLAN.md.
0c. For reference, the application source code is in `src/*`.

1. Your task is to implement functionality per the specifications using parallel subagents. Follow @IMPLEMENTATION_PLAN.md and choose the most important item to address. Before making changes, search the codebase (don't assume not implemented) using Sonnet subagents. You may use up to 500 parallel Sonnet subagents for searches/reads and only 1 Sonnet subagent for build/tests. Use Opus subagents when complex reasoning is needed (debugging, architectural decisions).
2. After implementing functionality or resolving problems, run the tests for that unit of code that was improved. If functionality is missing then it's your job to add it as per the application specifications. Ultrathink.

### When to use Agent Teams (instead of subagents)
Use a team ONLY when IMPLEMENTATION_PLAN.md has 2+ independent items that touch different files/layers (e.g., frontend + backend, or two unrelated modules). Spawn teammates for each item, coordinate as lead. Do NOT use teams when:
- Items touch the same files (merge conflicts)
- Work is sequential (item B depends on item A)
- There is only one item to work on
For everything else, subagents are faster and cheaper.

3. When you discover issues, immediately update @IMPLEMENTATION_PLAN.md with your findings using a subagent. When resolved, update and remove the item.
4. When the tests pass, update @IMPLEMENTATION_PLAN.md, then `git add -A` then `git commit` with a message describing the changes.

5. Important: When authoring documentation, capture the why -- tests and implementation importance.
6. Important: Single sources of truth, no migrations/adapters. If tests unrelated to your work fail, resolve them as part of the increment.
7. You may add extra logging if required to debug issues.
8. Keep @IMPLEMENTATION_PLAN.md current with learnings using a subagent -- future work depends on this to avoid duplicating efforts. Update especially after finishing your turn.
9. When you learn something new about how to run the application, update @AGENTS.md using a subagent but keep it brief.
10. For any bugs you notice, resolve them or document them in @IMPLEMENTATION_PLAN.md using a subagent even if it is unrelated to the current piece of work.
11. Implement functionality completely. Placeholders and stubs waste efforts and time redoing the same work.
12. When @IMPLEMENTATION_PLAN.md becomes large periodically clean out the items that are completed from the file using a subagent.
13. If you find inconsistencies in the specs/* then use an Opus subagent with 'ultrathink' requested to update the specs.
14. IMPORTANT: Keep @AGENTS.md operational only -- status updates and progress notes belong in IMPLEMENTATION_PLAN.md. A bloated AGENTS.md pollutes every future loop's context.

## Status Reporting (CRITICAL - Hank needs this!)

At the end of your response, ALWAYS include this status block:

```
---HANK_STATUS---
STATUS: IN_PROGRESS | COMPLETE | BLOCKED
TASKS_COMPLETED_THIS_LOOP: <number>
FILES_MODIFIED: <number>
TESTS_STATUS: PASSING | FAILING | NOT_RUN
WORK_TYPE: IMPLEMENTATION | TESTING | DOCUMENTATION | REFACTORING
EXIT_SIGNAL: false | true
RECOMMENDATION: <one line summary; include issue number e.g. #42 if working on a GitHub issue>
---END_HANK_STATUS---
```

Set EXIT_SIGNAL to true when ALL items in IMPLEMENTATION_PLAN.md are resolved, all tests pass, and all specs are implemented. Do NOT continue with busy work when EXIT_SIGNAL should be true. Do NOT run tests repeatedly without implementing new features.
PROMPTEOF
}

# generate_prompt_plan_md - Generate PROMPT_plan.md for planning mode
#
# Outputs to stdout
#
generate_prompt_plan_md() {
    cat << 'PLANEOF'
# Hank Planning Instructions

0a. Study .hank/specs/* with up to 250 parallel Sonnet subagents to learn the application specifications.
0b. Study @IMPLEMENTATION_PLAN.md (if present) to understand the plan so far.
0c. Study `src/lib/*` with up to 250 parallel Sonnet subagents to understand shared utilities & components.
0d. For reference, the application source code is in `src/*`.

1. Use an Agent Team for parallel research when the project has both specs and existing source code:
   - Spawn a team with a "specs researcher" (reads all specs, extracts requirements) and a "code auditor" (reads all src/*, finds TODOs, placeholders, skipped tests, inconsistent patterns). Both report findings to the lead.
   - The lead (you) synthesizes findings, prioritizes tasks, and creates/updates @IMPLEMENTATION_PLAN.md as a bullet point list sorted by priority.
   - If the project is small (< 10 files), skip the team and use subagents directly instead.
2. Ultrathink. Consider TODO, minimal implementations, placeholders, skipped/flaky tests, and inconsistent patterns. Study @IMPLEMENTATION_PLAN.md to determine starting point for research and keep it up to date with items considered complete/incomplete.

IMPORTANT: Plan only. Do NOT implement anything. Do NOT assume functionality is missing; confirm with code search first. Treat `src/lib` as the project's standard library for shared utilities and components. Prefer consolidated, idiomatic implementations there over ad-hoc copies.

## Status Reporting (CRITICAL - Hank needs this!)

At the end of your response, ALWAYS include this status block:

```
---HANK_STATUS---
STATUS: IN_PROGRESS | COMPLETE | BLOCKED
TASKS_COMPLETED_THIS_LOOP: <number>
FILES_MODIFIED: <number>
TESTS_STATUS: NOT_RUN
WORK_TYPE: DOCUMENTATION
EXIT_SIGNAL: true
RECOMMENDATION: <one line summary of planning results>
---END_HANK_STATUS---
```

Planning mode always sets EXIT_SIGNAL: true (single iteration).
PLANEOF
}

# generate_agent_md - Generate AGENT.md with detected build commands
#
# Parameters:
#   $1 (build_cmd) - Build command
#   $2 (test_cmd) - Test command
#   $3 (run_cmd) - Run command
#
# Outputs to stdout
#
generate_agent_md() {
    local build_cmd="${1:-echo 'No build command configured'}"
    local test_cmd="${2:-echo 'No test command configured'}"
    local run_cmd="${3:-echo 'No run command configured'}"

    cat << AGENTEOF
## Build & Run

Install: \`${build_cmd}\`
Build: \`${build_cmd}\`
Run: \`${run_cmd}\`

## Validation

Run these after implementing to get immediate feedback:

- Tests: \`${test_cmd}\`

## Operational Notes

<!-- Hank updates this section automatically with learnings -->
AGENTEOF
}

# generate_fix_plan_md - Generate fix_plan.md with imported tasks
#
# Parameters:
#   $1 (tasks) - Tasks to include (newline-separated, markdown checkbox format)
#
# Outputs to stdout
#
generate_fix_plan_md() {
    # Legacy wrapper - calls generate_implementation_plan_md
    generate_implementation_plan_md "$@"
}

# generate_implementation_plan_md - Generate IMPLEMENTATION_PLAN.md
#
# Parameters:
#   $1 (tasks) - Tasks to include (newline-separated, bullet format)
#
# Outputs to stdout
#
generate_implementation_plan_md() {
    local tasks="${1:-}"

    if [[ -n "$tasks" ]]; then
        cat << IMPLPLANEOF
# Implementation Plan

${tasks}
IMPLPLANEOF
    else
        cat << 'IMPLPLANEOF'
<!-- Generated by LLM with content and structure it deems most appropriate -->
<!-- Run: hank --mode plan to populate this file -->
IMPLPLANEOF
    fi
}

# generate_hankrc - Generate .hankrc configuration file
#
# Parameters:
#   $1 (project_name) - Project name
#   $2 (project_type) - Project type
#   $3 (task_sources) - Task sources (local, beads, github)
#
# Outputs to stdout
#
generate_hankrc() {
    local project_name="${1:-$(basename "$(pwd)")}"
    local project_type="${2:-unknown}"
    local task_sources="${3:-local}"

    cat << HANKRCEOF
# .hankrc - Hank project configuration
# Generated by: hank enable
# Documentation: https://github.com/jacklenzotti/hank

# Project identification
PROJECT_NAME="${project_name}"
PROJECT_TYPE="${project_type}"

# Loop settings
MAX_CALLS_PER_HOUR=100
CLAUDE_TIMEOUT_MINUTES=15
CLAUDE_OUTPUT_FORMAT="json"

# Tool permissions
# Comma-separated list of allowed tools
ALLOWED_TOOLS="Write,Read,Edit,Bash(git *),Bash(npm *),Bash(pytest)"

# Session management
SESSION_CONTINUITY=true
SESSION_EXPIRY_HOURS=24

# Task sources (for hank enable --sync)
# Options: local, beads, github (comma-separated for multiple)
TASK_SOURCES="${task_sources}"
GITHUB_TASK_LABEL="hank-task"
BEADS_FILTER="status:open"

# Circuit breaker thresholds
CB_NO_PROGRESS_THRESHOLD=3
CB_SAME_ERROR_THRESHOLD=5
CB_OUTPUT_DECLINE_THRESHOLD=70

# Retry strategy configuration
RETRY_MAX_ATTEMPTS=3
RETRY_BACKOFF_INITIAL_SEC=30
RETRY_BACKOFF_MAX_SEC=300
RETRY_BACKOFF_MULTIPLIER=2
HANKRCEOF
}

# =============================================================================
# MAIN ENABLE LOGIC
# =============================================================================

# enable_hank_in_directory - Main function to enable Hank in current directory
#
# Parameters:
#   $1 (options) - JSON-like options string or empty
#       force: true/false - Force overwrite existing
#       skip_tasks: true/false - Skip task import
#       project_name: string - Override project name
#       task_content: string - Pre-imported task content
#
# Returns:
#   0 - Success
#   1 - Error
#   2 - Already enabled (and no force flag)
#
enable_hank_in_directory() {
    local force="${ENABLE_FORCE:-false}"
    local skip_tasks="${ENABLE_SKIP_TASKS:-false}"
    local project_name="${ENABLE_PROJECT_NAME:-}"
    local project_type="${ENABLE_PROJECT_TYPE:-}"
    local task_content="${ENABLE_TASK_CONTENT:-}"

    # Check existing state (use || true to prevent set -e from exiting)
    check_existing_hank || true

    if [[ "$HANK_STATE" == "complete" && "$force" != "true" ]]; then
        enable_log "INFO" "Hank is already enabled in this project"
        enable_log "INFO" "Use --force to overwrite existing configuration"
        return $ENABLE_ALREADY_ENABLED
    fi

    # Detect project context
    detect_project_context

    # Use detected or provided project name
    if [[ -z "$project_name" ]]; then
        project_name="$DETECTED_PROJECT_NAME"
    fi

    # Use detected or provided project type
    if [[ -n "$project_type" ]]; then
        DETECTED_PROJECT_TYPE="$project_type"
    fi

    enable_log "INFO" "Enabling Hank for: $project_name"
    enable_log "INFO" "Project type: $DETECTED_PROJECT_TYPE"
    if [[ -n "$DETECTED_FRAMEWORK" ]]; then
        enable_log "INFO" "Framework: $DETECTED_FRAMEWORK"
    fi

    # Create directory structure
    if ! create_hank_structure; then
        enable_log "ERROR" "Failed to create .hank/ structure"
        return $ENABLE_ERROR
    fi

    # Generate and create files
    local prompt_content
    prompt_content=$(generate_prompt_md "$project_name" "$DETECTED_PROJECT_TYPE" "$DETECTED_FRAMEWORK")
    safe_create_file ".hank/PROMPT.md" "$prompt_content"

    local agent_content
    agent_content=$(generate_agent_md "$DETECTED_BUILD_CMD" "$DETECTED_TEST_CMD" "$DETECTED_RUN_CMD")
    safe_create_file ".hank/AGENT.md" "$agent_content"

    # Create IMPLEMENTATION_PLAN.md (Playbook-style task state)
    local impl_plan_content
    impl_plan_content=$(generate_implementation_plan_md "$task_content")
    safe_create_file ".hank/IMPLEMENTATION_PLAN.md" "$impl_plan_content"

    # Create PROMPT_plan.md for planning mode
    local plan_prompt_content
    plan_prompt_content=$(generate_prompt_plan_md)
    safe_create_file ".hank/PROMPT_plan.md" "$plan_prompt_content"

    # Detect task sources for .hankrc
    detect_task_sources
    local task_sources="local"
    if [[ "$DETECTED_BEADS_AVAILABLE" == "true" ]]; then
        task_sources="beads,$task_sources"
    fi
    if [[ "$DETECTED_GITHUB_AVAILABLE" == "true" ]]; then
        task_sources="github,$task_sources"
        # Create hank labels on GitHub repo for --source github mode
        if command -v gh &>/dev/null; then
            setup_github_labels 2>/dev/null || true
            enable_log "INFO" "Created hank labels on GitHub repo"
        fi
    fi

    # Generate .hankrc
    local hankrc_content
    hankrc_content=$(generate_hankrc "$project_name" "$DETECTED_PROJECT_TYPE" "$task_sources")
    safe_create_file ".hankrc" "$hankrc_content"

    enable_log "SUCCESS" "Hank enabled successfully!"

    return $ENABLE_SUCCESS
}

# Export functions for use in other scripts
export -f enable_log
export -f check_existing_hank
export -f is_hank_enabled
export -f safe_create_file
export -f safe_create_dir
export -f create_hank_structure
export -f detect_project_context
export -f detect_git_info
export -f detect_task_sources
export -f get_templates_dir
export -f generate_prompt_md
export -f generate_prompt_plan_md
export -f generate_agent_md
export -f generate_fix_plan_md
export -f generate_implementation_plan_md
export -f generate_hankrc
export -f enable_hank_in_directory
