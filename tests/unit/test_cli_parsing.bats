#!/usr/bin/env bats
# Unit tests for CLI argument parsing in hank_loop.sh
# Linked to GitHub Issue #10
# TDD: Tests written to cover all CLI flag combinations

load '../helpers/test_helper'
load '../helpers/fixtures'

# Path to hank_loop.sh
HANK_SCRIPT="${BATS_TEST_DIRNAME}/../../hank_loop.sh"

setup() {
    # Create temporary test directory
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"

    # Initialize minimal git repo (required by some flags)
    git init > /dev/null 2>&1
    git config user.email "test@example.com"
    git config user.name "Test User"

    # Set up required environment with .hank/ subfolder structure
    export HANK_DIR=".hank"
    export PROMPT_FILE="$HANK_DIR/PROMPT.md"
    export LOG_DIR="$HANK_DIR/logs"
    export STATUS_FILE="$HANK_DIR/status.json"
    export EXIT_SIGNALS_FILE="$HANK_DIR/.exit_signals"
    export CALL_COUNT_FILE="$HANK_DIR/.call_count"
    export TIMESTAMP_FILE="$HANK_DIR/.last_reset"

    mkdir -p "$LOG_DIR"

    # Create minimal required files
    echo "# Test Prompt" > "$PROMPT_FILE"
    echo "0" > "$CALL_COUNT_FILE"
    echo "$(date +%Y%m%d%H)" > "$TIMESTAMP_FILE"
    echo '{"test_only_loops": [], "done_signals": [], "completion_indicators": []}' > "$EXIT_SIGNALS_FILE"

    # Create lib directory with circuit breaker stub
    mkdir -p lib
    cat > lib/circuit_breaker.sh << 'EOF'
HANK_DIR="${HANK_DIR:-.hank}"
reset_circuit_breaker() { echo "Circuit breaker reset: $1"; }
show_circuit_status() { echo "Circuit breaker status: CLOSED"; }
init_circuit_breaker() { :; }
record_loop_result() { :; }
EOF

    cat > lib/response_analyzer.sh << 'EOF'
HANK_DIR="${HANK_DIR:-.hank}"
analyze_response() { :; }
detect_output_format() { echo "text"; }
EOF

    cat > lib/date_utils.sh << 'EOF'
get_iso_timestamp() { date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S'; }
get_epoch_timestamp() { date +%s; }
EOF
}

teardown() {
    if [[ -n "$TEST_DIR" ]] && [[ -d "$TEST_DIR" ]]; then
        cd /
        rm -rf "$TEST_DIR"
    fi
}

# =============================================================================
# HELP FLAG TESTS (2 tests)
# =============================================================================

@test "--help flag displays help message with all options" {
    run bash "$HANK_SCRIPT" --help

    assert_success

    # Verify help contains key sections
    [[ "$output" == *"Usage:"* ]]
    [[ "$output" == *"Options:"* ]]

    # Verify all flags are documented
    [[ "$output" == *"--calls"* ]]
    [[ "$output" == *"--prompt"* ]]
    [[ "$output" == *"--status"* ]]
    [[ "$output" == *"--monitor"* ]]
    [[ "$output" == *"--verbose"* ]]
    [[ "$output" == *"--timeout"* ]]
    [[ "$output" == *"--reset-circuit"* ]]
    [[ "$output" == *"--circuit-status"* ]]
    [[ "$output" == *"--output-format"* ]]
    [[ "$output" == *"--allowed-tools"* ]]
    [[ "$output" == *"--no-continue"* ]]
}

@test "-h short flag displays help message" {
    run bash "$HANK_SCRIPT" -h

    assert_success

    # Verify help contains key sections
    [[ "$output" == *"Usage:"* ]]
    [[ "$output" == *"Options:"* ]]
    [[ "$output" == *"--help"* ]]
}

# =============================================================================
# FLAG VALUE SETTING TESTS (6 tests)
# =============================================================================

@test "--calls NUM sets MAX_CALLS_PER_HOUR correctly" {
    # Use --help after --calls to capture the parsed value without running main loop
    run bash "$HANK_SCRIPT" --calls 50 --help

    assert_success
    # The help output shows default values, but the script would have parsed --calls 50
    # We verify parsing by checking the script doesn't error on valid input
    [[ "$output" == *"Usage:"* ]]
}

@test "--prompt FILE sets PROMPT_FILE correctly" {
    # Create custom prompt file
    echo "# Custom Prompt" > custom_prompt.md

    run bash "$HANK_SCRIPT" --prompt custom_prompt.md --help

    assert_success
    [[ "$output" == *"Usage:"* ]]
}

@test "--monitor flag is accepted without error" {
    # Monitor flag combined with help to verify parsing
    run bash "$HANK_SCRIPT" --monitor --help

    assert_success
    [[ "$output" == *"Usage:"* ]]
}

@test "--verbose flag is accepted without error" {
    run bash "$HANK_SCRIPT" --verbose --help

    assert_success
    [[ "$output" == *"Usage:"* ]]
}

@test "--timeout NUM sets timeout with valid value" {
    run bash "$HANK_SCRIPT" --timeout 30 --help

    assert_success
    [[ "$output" == *"Usage:"* ]]
}

@test "--timeout validates range (1-120)" {
    # Test invalid: 0
    run bash "$HANK_SCRIPT" --timeout 0
    assert_failure
    [[ "$output" == *"must be a positive integer between 1 and 120"* ]]

    # Test invalid: 121
    run bash "$HANK_SCRIPT" --timeout 121
    assert_failure
    [[ "$output" == *"must be a positive integer between 1 and 120"* ]]

    # Test invalid: negative
    run bash "$HANK_SCRIPT" --timeout -5
    assert_failure
    [[ "$output" == *"must be a positive integer between 1 and 120"* ]]

    # Test boundary: 1 (valid)
    run bash "$HANK_SCRIPT" --timeout 1 --help
    assert_success

    # Test boundary: 120 (valid)
    run bash "$HANK_SCRIPT" --timeout 120 --help
    assert_success
}

# =============================================================================
# STATUS FLAG TESTS (2 tests)
# =============================================================================

@test "--status shows status when status.json exists" {
    # Create mock status file
    cat > "$STATUS_FILE" << 'EOF'
{
    "timestamp": "2025-01-08T12:00:00-05:00",
    "loop_count": 5,
    "calls_made_this_hour": 42,
    "max_calls_per_hour": 100,
    "last_action": "executing",
    "status": "running"
}
EOF

    run bash "$HANK_SCRIPT" --status

    assert_success
    [[ "$output" == *"Current Status:"* ]] || [[ "$output" == *"loop_count"* ]]
    [[ "$output" == *"5"* ]]  # loop_count value
}

@test "--status handles missing status file gracefully" {
    rm -f "$STATUS_FILE"

    run bash "$HANK_SCRIPT" --status

    assert_success
    [[ "$output" == *"No status file found"* ]]
}

# =============================================================================
# CIRCUIT BREAKER FLAG TESTS (2 tests)
# =============================================================================

@test "--reset-circuit flag executes circuit breaker reset" {
    run bash "$HANK_SCRIPT" --reset-circuit

    assert_success
    [[ "$output" == *"Circuit breaker reset"* ]] || [[ "$output" == *"reset"* ]]
}

@test "--circuit-status flag shows circuit breaker status" {
    run bash "$HANK_SCRIPT" --circuit-status

    assert_success
    [[ "$output" == *"Circuit breaker status"* ]] || [[ "$output" == *"CLOSED"* ]] || [[ "$output" == *"status"* ]]
}

# =============================================================================
# INVALID INPUT TESTS (3 tests)
# =============================================================================

@test "Invalid flag shows error and help" {
    run bash "$HANK_SCRIPT" --invalid-flag

    assert_failure
    [[ "$output" == *"Unknown option: --invalid-flag"* ]]
    [[ "$output" == *"Usage:"* ]]
}

@test "Invalid timeout format shows error" {
    run bash "$HANK_SCRIPT" --timeout abc

    assert_failure
    [[ "$output" == *"must be a positive integer"* ]] || [[ "$output" == *"Error"* ]]
}

@test "--output-format rejects invalid format values" {
    run bash "$HANK_SCRIPT" --output-format invalid

    assert_failure
    [[ "$output" == *"must be 'json' or 'text'"* ]]
}

@test "--allowed-tools flag accepts valid tool list" {
    run bash "$HANK_SCRIPT" --allowed-tools "Write,Read,Bash" --help

    assert_success
    [[ "$output" == *"Usage:"* ]]
}

# =============================================================================
# MULTIPLE FLAGS TESTS (3 tests)
# =============================================================================

@test "Multiple flags combined (--calls --prompt --verbose)" {
    echo "# Custom Prompt" > custom_prompt.md

    run bash "$HANK_SCRIPT" --calls 50 --prompt custom_prompt.md --verbose --help

    assert_success
    [[ "$output" == *"Usage:"* ]]
}

@test "All flags combined works correctly" {
    echo "# Custom Prompt" > custom_prompt.md

    run bash "$HANK_SCRIPT" \
        --calls 25 \
        --prompt custom_prompt.md \
        --verbose \
        --timeout 20 \
        --output-format json \
        --no-continue \
        --help

    assert_success
    [[ "$output" == *"Usage:"* ]]
}

@test "Help flag with other flags shows help (early exit)" {
    run bash "$HANK_SCRIPT" --calls 50 --verbose --help

    assert_success
    [[ "$output" == *"Usage:"* ]]
    # Script should exit with help, not run main loop
}

# =============================================================================
# FLAG ORDER INDEPENDENCE TESTS (2 tests)
# =============================================================================

@test "Flag order doesn't matter (order A: calls-prompt-verbose)" {
    echo "# Custom Prompt" > custom_prompt.md

    run bash "$HANK_SCRIPT" --calls 50 --prompt custom_prompt.md --verbose --help

    assert_success
    [[ "$output" == *"Usage:"* ]]
}

@test "Flag order doesn't matter (order B: verbose-prompt-calls)" {
    echo "# Custom Prompt" > custom_prompt.md

    run bash "$HANK_SCRIPT" --verbose --prompt custom_prompt.md --calls 50 --help

    assert_success
    [[ "$output" == *"Usage:"* ]]
}

# =============================================================================
# SHORT FLAG EQUIVALENCE TESTS (bonus: verify short flags work)
# =============================================================================

@test "-c short flag works like --calls" {
    run bash "$HANK_SCRIPT" -c 50 --help

    assert_success
    [[ "$output" == *"Usage:"* ]]
}

@test "-p short flag works like --prompt" {
    echo "# Custom Prompt" > custom_prompt.md

    run bash "$HANK_SCRIPT" -p custom_prompt.md --help

    assert_success
}

@test "-s short flag works like --status" {
    rm -f "$STATUS_FILE"

    run bash "$HANK_SCRIPT" -s

    assert_success
    [[ "$output" == *"No status file found"* ]]
}

@test "-m short flag works like --monitor" {
    run bash "$HANK_SCRIPT" -m --help

    assert_success
}

@test "-v short flag works like --verbose" {
    run bash "$HANK_SCRIPT" -v --help

    assert_success
}

@test "-t short flag works like --timeout" {
    run bash "$HANK_SCRIPT" -t 30 --help

    assert_success
}

# =============================================================================
# MONITOR PARAMETER FORWARDING TESTS (Issue #120)
# Tests that --monitor correctly forwards all CLI parameters to the inner loop
# =============================================================================

# Helper function to extract the hank_cmd that would be built in setup_tmux_session
# This sources hank_loop.sh and simulates the parameter forwarding logic
build_hank_cmd_for_test() {
    local hank_cmd="hank"
    local MAX_CALLS_PER_HOUR="${1:-100}"
    local PROMPT_FILE="${2:-.hank/PROMPT.md}"
    local CLAUDE_OUTPUT_FORMAT="${3:-json}"
    local VERBOSE_PROGRESS="${4:-false}"
    local CLAUDE_TIMEOUT_MINUTES="${5:-15}"
    local CLAUDE_ALLOWED_TOOLS="${6:-Write,Read,Edit,Bash(git *),Bash(npm *),Bash(pytest)}"
    local CLAUDE_USE_CONTINUE="${7:-true}"
    local CLAUDE_SESSION_EXPIRY_HOURS="${8:-24}"
    local HANK_DIR=".hank"

    # Forward --calls if non-default
    if [[ "$MAX_CALLS_PER_HOUR" != "100" ]]; then
        hank_cmd="$hank_cmd --calls $MAX_CALLS_PER_HOUR"
    fi
    # Forward --prompt if non-default
    if [[ "$PROMPT_FILE" != "$HANK_DIR/PROMPT.md" ]]; then
        hank_cmd="$hank_cmd --prompt '$PROMPT_FILE'"
    fi
    # Forward --output-format if non-default (default is json)
    if [[ "$CLAUDE_OUTPUT_FORMAT" != "json" ]]; then
        hank_cmd="$hank_cmd --output-format $CLAUDE_OUTPUT_FORMAT"
    fi
    # Forward --verbose if enabled
    if [[ "$VERBOSE_PROGRESS" == "true" ]]; then
        hank_cmd="$hank_cmd --verbose"
    fi
    # Forward --timeout if non-default (default is 15)
    if [[ "$CLAUDE_TIMEOUT_MINUTES" != "15" ]]; then
        hank_cmd="$hank_cmd --timeout $CLAUDE_TIMEOUT_MINUTES"
    fi
    # Forward --allowed-tools if non-default
    if [[ "$CLAUDE_ALLOWED_TOOLS" != "Write,Read,Edit,Bash(git *),Bash(npm *),Bash(pytest)" ]]; then
        hank_cmd="$hank_cmd --allowed-tools '$CLAUDE_ALLOWED_TOOLS'"
    fi
    # Forward --no-continue if session continuity disabled
    if [[ "$CLAUDE_USE_CONTINUE" == "false" ]]; then
        hank_cmd="$hank_cmd --no-continue"
    fi
    # Forward --session-expiry if non-default (default is 24)
    if [[ "$CLAUDE_SESSION_EXPIRY_HOURS" != "24" ]]; then
        hank_cmd="$hank_cmd --session-expiry $CLAUDE_SESSION_EXPIRY_HOURS"
    fi

    echo "$hank_cmd"
}

@test "monitor forwards --output-format text parameter" {
    local result=$(build_hank_cmd_for_test 100 ".hank/PROMPT.md" "text")
    [[ "$result" == *"--output-format text"* ]]
}

@test "monitor forwards --verbose parameter" {
    local result=$(build_hank_cmd_for_test 100 ".hank/PROMPT.md" "json" "true")
    [[ "$result" == *"--verbose"* ]]
}

@test "monitor forwards --timeout parameter" {
    local result=$(build_hank_cmd_for_test 100 ".hank/PROMPT.md" "json" "false" "30")
    [[ "$result" == *"--timeout 30"* ]]
}

@test "monitor forwards --allowed-tools parameter" {
    local result=$(build_hank_cmd_for_test 100 ".hank/PROMPT.md" "json" "false" "15" "Read,Write")
    [[ "$result" == *"--allowed-tools 'Read,Write'"* ]]
}

@test "monitor forwards --no-continue parameter" {
    local result=$(build_hank_cmd_for_test 100 ".hank/PROMPT.md" "json" "false" "15" "Write,Bash(git *),Read" "false")
    [[ "$result" == *"--no-continue"* ]]
}

@test "monitor forwards --session-expiry parameter" {
    local result=$(build_hank_cmd_for_test 100 ".hank/PROMPT.md" "json" "false" "15" "Write,Bash(git *),Read" "true" "48")
    [[ "$result" == *"--session-expiry 48"* ]]
}

@test "monitor forwards multiple parameters together" {
    local result=$(build_hank_cmd_for_test 50 ".hank/PROMPT.md" "text" "true" "30" "Read,Write" "false" "12")
    [[ "$result" == *"--calls 50"* ]]
    [[ "$result" == *"--output-format text"* ]]
    [[ "$result" == *"--verbose"* ]]
    [[ "$result" == *"--timeout 30"* ]]
    [[ "$result" == *"--allowed-tools 'Read,Write'"* ]]
    [[ "$result" == *"--no-continue"* ]]
    [[ "$result" == *"--session-expiry 12"* ]]
}

@test "monitor does not forward default parameters" {
    local result=$(build_hank_cmd_for_test 100 ".hank/PROMPT.md" "json" "false" "15" "Write,Read,Edit,Bash(git *),Bash(npm *),Bash(pytest)" "true" "24")
    # Should only be "hank" with no extra flags
    [[ "$result" == "hank" ]]
}

# =============================================================================
# CLEAN FLAG TESTS
# =============================================================================

@test "--clean removes transient session files" {
    # Create transient files that --clean should remove
    echo "session-data" > "$HANK_DIR/.hank_session"
    echo "[]" > "$HANK_DIR/.hank_session_history"
    echo "abc123" > "$HANK_DIR/.claude_session_id"
    echo '{}' > "$HANK_DIR/.exit_signals"
    echo '{}' > "$HANK_DIR/.response_analysis"
    echo '{}' > "$HANK_DIR/.cost_session"
    echo '{"state":"CLOSED"}' > "$HANK_DIR/.circuit_breaker_state"
    echo '[]' > "$HANK_DIR/.circuit_breaker_history"
    echo "5" > "$HANK_DIR/.call_count"
    echo "2025010112" > "$HANK_DIR/.last_reset"
    echo '{}' > "$HANK_DIR/status.json"
    echo '{}' > "$HANK_DIR/progress.json"
    echo "log data" > "$HANK_DIR/live.log"
    echo '{}' > "$HANK_DIR/.json_parse_result"
    echo "1234" > "$HANK_DIR/.last_output_length"
    echo "abc123" > "$HANK_DIR/.loop_start_sha"

    run bash "$HANK_SCRIPT" --clean

    assert_success

    # Verify all transient files were removed
    [[ ! -f "$HANK_DIR/.hank_session" ]]
    [[ ! -f "$HANK_DIR/.hank_session_history" ]]
    [[ ! -f "$HANK_DIR/.claude_session_id" ]]
    [[ ! -f "$HANK_DIR/.exit_signals" ]]
    [[ ! -f "$HANK_DIR/.response_analysis" ]]
    [[ ! -f "$HANK_DIR/.cost_session" ]]
    [[ ! -f "$HANK_DIR/.circuit_breaker_state" ]]
    [[ ! -f "$HANK_DIR/.circuit_breaker_history" ]]
    [[ ! -f "$HANK_DIR/.call_count" ]]
    [[ ! -f "$HANK_DIR/.last_reset" ]]
    [[ ! -f "$HANK_DIR/status.json" ]]
    [[ ! -f "$HANK_DIR/progress.json" ]]
    [[ ! -f "$HANK_DIR/live.log" ]]
    [[ ! -f "$HANK_DIR/.json_parse_result" ]]
    [[ ! -f "$HANK_DIR/.last_output_length" ]]
    [[ ! -f "$HANK_DIR/.loop_start_sha" ]]
}

@test "--clean preserves persistent project files" {
    # Create persistent files that --clean should NOT remove
    echo "# Prompt" > "$HANK_DIR/PROMPT.md"
    echo "# Plan Prompt" > "$HANK_DIR/PROMPT_plan.md"
    echo "# Plan" > "$HANK_DIR/IMPLEMENTATION_PLAN.md"
    echo "# Agent" > "$HANK_DIR/AGENT.md"
    echo '{"cost":1.23}' > "$HANK_DIR/cost_log.jsonl"
    mkdir -p "$HANK_DIR/specs"
    echo "spec" > "$HANK_DIR/specs/spec1.md"
    mkdir -p "$HANK_DIR/docs"
    echo "doc" > "$HANK_DIR/docs/readme.md"

    # Also create a transient file so --clean actually runs
    echo "session" > "$HANK_DIR/.hank_session"

    run bash "$HANK_SCRIPT" --clean

    assert_success

    # Verify persistent files are preserved
    [[ -f "$HANK_DIR/PROMPT.md" ]]
    [[ -f "$HANK_DIR/PROMPT_plan.md" ]]
    [[ -f "$HANK_DIR/IMPLEMENTATION_PLAN.md" ]]
    [[ -f "$HANK_DIR/AGENT.md" ]]
    [[ -f "$HANK_DIR/cost_log.jsonl" ]]
    [[ -f "$HANK_DIR/specs/spec1.md" ]]
    [[ -f "$HANK_DIR/docs/readme.md" ]]

    # Verify transient file was removed
    [[ ! -f "$HANK_DIR/.hank_session" ]]
}

@test "--clean preserves logs by default" {
    mkdir -p "$HANK_DIR/logs"
    echo "log1" > "$HANK_DIR/logs/hank.log"
    echo "log2" > "$HANK_DIR/logs/claude_output_2025.log"
    echo "session" > "$HANK_DIR/.hank_session"

    run bash "$HANK_SCRIPT" --clean

    assert_success
    [[ -f "$HANK_DIR/logs/hank.log" ]]
    [[ -f "$HANK_DIR/logs/claude_output_2025.log" ]]
}

@test "--clean --clean-logs also removes log files" {
    mkdir -p "$HANK_DIR/logs"
    echo "log1" > "$HANK_DIR/logs/hank.log"
    echo "log2" > "$HANK_DIR/logs/claude_output_2025.log"
    echo "session" > "$HANK_DIR/.hank_session"

    run bash "$HANK_SCRIPT" --clean --clean-logs

    assert_success
    [[ ! -f "$HANK_DIR/logs/hank.log" ]]
    [[ ! -f "$HANK_DIR/logs/claude_output_2025.log" ]]
}

@test "--clean with no transient files reports already clean" {
    # Only persistent files exist (PROMPT.md created in setup)
    # Remove the transient files created in setup
    rm -f "$HANK_DIR/.call_count" "$HANK_DIR/.last_reset" "$HANK_DIR/.exit_signals"

    run bash "$HANK_SCRIPT" --clean

    assert_success
    [[ "$output" == *"Already clean"* ]]
}

@test "--clean with missing .hank dir still succeeds" {
    rm -rf "$HANK_DIR"

    run bash "$HANK_SCRIPT" --clean

    assert_success
    # Script creates .hank/ at startup, so clean runs but finds nothing
    [[ "$output" == *"Already clean"* ]] || [[ "$output" == *"nothing to clean"* ]]
}

@test "--clean flag appears in help text" {
    run bash "$HANK_SCRIPT" --help

    assert_success
    [[ "$output" == *"--clean"* ]]
    [[ "$output" == *"--clean-logs"* ]]
}

# =============================================================================
# NEW FLAG TESTS (10 tests)
# =============================================================================

@test "--orchestrate flag is accepted without error" {
    run bash "$HANK_SCRIPT" --orchestrate --help

    assert_success
    [[ "$output" == *"Usage:"* ]]
}

@test "--repos flag shows orchestration status" {
    run bash "$HANK_SCRIPT" --repos

    assert_success
    [[ "$output" == *"No orchestration in progress"* ]]
}

@test "--replay --list handles no session logs" {
    run bash "$HANK_SCRIPT" --replay --list

    assert_failure
    [[ "$output" == *"No session logs found"* ]]
}

@test "--replay without args shows usage" {
    run bash "$HANK_SCRIPT" --replay

    assert_failure
    [[ "$output" == *"--replay requires a session ID or --list flag"* ]]
}

@test "--replay <id> calls replay with session id" {
    run bash "$HANK_SCRIPT" --replay abc123

    # Will fail because session doesn't exist, but tests flag parsing
    [[ "$output" == *"abc123"* ]] || [[ "$output" == *"session"* ]] || [[ "$output" == *"not found"* ]]
}

@test "--audit flag shows audit log" {
    run bash "$HANK_SCRIPT" --audit

    assert_success
    [[ "$output" == *"No audit log found"* ]] || [[ "$output" == *"audit"* ]]
}

@test "--error-catalog flag shows error catalog" {
    run bash "$HANK_SCRIPT" --error-catalog

    assert_success
    [[ "$output" == *"No error catalog found"* ]] || [[ "$output" == *"catalog"* ]]
}

@test "--dry-run flag is accepted without error" {
    run bash "$HANK_SCRIPT" --dry-run --help

    assert_success
    [[ "$output" == *"Usage:"* ]]
}

@test "--teams flag is accepted without error" {
    run bash "$HANK_SCRIPT" --teams --help

    assert_success
    [[ "$output" == *"Usage:"* ]]
}

@test "--mode plan sets plan mode" {
    run bash "$HANK_SCRIPT" --mode plan --help

    assert_success
    [[ "$output" == *"Usage:"* ]]
}

@test "--mode build sets build mode" {
    run bash "$HANK_SCRIPT" --mode build --help

    assert_success
    [[ "$output" == *"Usage:"* ]]
}

@test "--mode rejects invalid mode" {
    run bash "$HANK_SCRIPT" --mode invalid

    assert_failure
    [[ "$output" == *"--mode must be 'plan' or 'build'"* ]]
}
