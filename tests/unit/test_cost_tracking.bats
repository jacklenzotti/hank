#!/usr/bin/env bats
# Unit tests for cost tracking in Hank

load '../helpers/test_helper'

setup() {
    # Create temporary test directory
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"

    # Initialize git repo for tests
    git init > /dev/null 2>&1
    git config user.email "test@example.com"
    git config user.name "Test User"

    # Set up environment with .hank/ subfolder structure
    export HANK_DIR=".hank"
    export LOG_DIR="$HANK_DIR/logs"

    mkdir -p "$LOG_DIR"

    # Source library components
    source "${BATS_TEST_DIRNAME}/../../lib/response_analyzer.sh"
    source "${BATS_TEST_DIRNAME}/../../lib/cost_tracker.sh"
}

teardown() {
    if [[ -n "$TEST_DIR" ]] && [[ -d "$TEST_DIR" ]]; then
        cd /
        rm -rf "$TEST_DIR"
    fi
}

# =============================================================================
# COST FIELD EXTRACTION TESTS
# =============================================================================

@test "parse_json_response extracts cost_usd from Claude CLI output" {
    local output_file="$LOG_DIR/test_output.log"
    cat > "$output_file" << 'EOF'
{
    "result": "Done",
    "sessionId": "sess-123",
    "cost_usd": 0.0523,
    "total_cost_usd": 0.15,
    "duration_ms": 45000,
    "num_turns": 12,
    "usage": {
        "input_tokens": 15000,
        "output_tokens": 3000,
        "cache_creation_input_tokens": 5000,
        "cache_read_input_tokens": 8000
    }
}
EOF

    run parse_json_response "$output_file" "$HANK_DIR/.json_parse_result"
    assert_success

    # Check cost fields
    local cost=$(jq -r '.cost_usd' "$HANK_DIR/.json_parse_result")
    [[ "$cost" != "0" ]] || fail "cost_usd should be non-zero, got: $cost"

    local total_cost=$(jq -r '.total_cost_usd' "$HANK_DIR/.json_parse_result")
    [[ "$total_cost" != "0" ]] || fail "total_cost_usd should be non-zero, got: $total_cost"
}

@test "parse_json_response extracts token usage" {
    local output_file="$LOG_DIR/test_output.log"
    cat > "$output_file" << 'EOF'
{
    "result": "Done",
    "cost_usd": 0.05,
    "usage": {
        "input_tokens": 15000,
        "output_tokens": 3000,
        "cache_creation_input_tokens": 5000,
        "cache_read_input_tokens": 8000
    }
}
EOF

    run parse_json_response "$output_file" "$HANK_DIR/.json_parse_result"
    assert_success

    local input=$(jq -r '.usage.input_tokens' "$HANK_DIR/.json_parse_result")
    assert_equal "$input" "15000"

    local output=$(jq -r '.usage.output_tokens' "$HANK_DIR/.json_parse_result")
    assert_equal "$output" "3000"

    local cache_create=$(jq -r '.usage.cache_creation_input_tokens' "$HANK_DIR/.json_parse_result")
    assert_equal "$cache_create" "5000"

    local cache_read=$(jq -r '.usage.cache_read_input_tokens' "$HANK_DIR/.json_parse_result")
    assert_equal "$cache_read" "8000"
}

@test "parse_json_response extracts duration_ms and num_turns" {
    local output_file="$LOG_DIR/test_output.log"
    cat > "$output_file" << 'EOF'
{
    "result": "Done",
    "cost_usd": 0.05,
    "duration_ms": 45000,
    "num_turns": 12,
    "usage": {"input_tokens": 100, "output_tokens": 50}
}
EOF

    run parse_json_response "$output_file" "$HANK_DIR/.json_parse_result"
    assert_success

    local duration=$(jq -r '.duration_ms' "$HANK_DIR/.json_parse_result")
    assert_equal "$duration" "45000"

    local turns=$(jq -r '.num_turns' "$HANK_DIR/.json_parse_result")
    assert_equal "$turns" "12"
}

@test "parse_json_response handles missing cost fields with zero defaults" {
    local output_file="$LOG_DIR/test_output.log"
    cat > "$output_file" << 'EOF'
{
    "result": "Done",
    "status": "COMPLETE"
}
EOF

    run parse_json_response "$output_file" "$HANK_DIR/.json_parse_result"
    assert_success

    # cost_usd is sanitized through awk, so 0 becomes 0 or 0.000000
    local cost=$(jq -r '.cost_usd' "$HANK_DIR/.json_parse_result")
    local cost_int=$(echo "$cost" | awk '{printf "%d", $1+0}')
    assert_equal "$cost_int" "0"

    local input=$(jq -r '.usage.input_tokens' "$HANK_DIR/.json_parse_result")
    assert_equal "$input" "0"

    local output=$(jq -r '.usage.output_tokens' "$HANK_DIR/.json_parse_result")
    assert_equal "$output" "0"
}

@test "parse_json_response handles null cost values" {
    local output_file="$LOG_DIR/test_output.log"
    cat > "$output_file" << 'EOF'
{
    "result": "Done",
    "cost_usd": null,
    "total_cost_usd": null,
    "duration_ms": null,
    "usage": null
}
EOF

    run parse_json_response "$output_file" "$HANK_DIR/.json_parse_result"
    assert_success

    # cost_usd is sanitized through awk, so null becomes 0 or 0.000000
    local cost=$(jq -r '.cost_usd' "$HANK_DIR/.json_parse_result")
    local cost_int=$(echo "$cost" | awk '{printf "%d", $1+0}')
    assert_equal "$cost_int" "0"

    local duration=$(jq -r '.duration_ms' "$HANK_DIR/.json_parse_result")
    assert_equal "$duration" "0"
}

@test "parse_json_response extracts cost from array format" {
    local output_file="$LOG_DIR/test_output.log"
    cat > "$output_file" << 'EOF'
[
    {"type": "system", "subtype": "init", "session_id": "sess-arr"},
    {"type": "assistant", "message": "Working..."},
    {"type": "result", "result": "Done", "cost_usd": 0.08, "total_cost_usd": 0.20, "duration_ms": 30000, "num_turns": 5, "usage": {"input_tokens": 10000, "output_tokens": 2000, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0}, "sessionId": "sess-arr"}
]
EOF

    run parse_json_response "$output_file" "$HANK_DIR/.json_parse_result"
    assert_success

    local cost=$(jq -r '.cost_usd' "$HANK_DIR/.json_parse_result")
    [[ "$cost" != "0" ]] || fail "cost_usd should be non-zero in array format, got: $cost"

    local input=$(jq -r '.usage.input_tokens' "$HANK_DIR/.json_parse_result")
    assert_equal "$input" "10000"
}

@test "analyze_response propagates cost fields to analysis JSON" {
    local output_file="$LOG_DIR/test_output.log"
    cat > "$output_file" << 'EOF'
{
    "result": "Implemented feature",
    "cost_usd": 0.05,
    "total_cost_usd": 0.15,
    "duration_ms": 45000,
    "num_turns": 10,
    "usage": {
        "input_tokens": 15000,
        "output_tokens": 3000,
        "cache_creation_input_tokens": 5000,
        "cache_read_input_tokens": 8000
    }
}
EOF

    echo '{"test_only_loops": [], "done_signals": [], "completion_indicators": []}' > "$HANK_DIR/.exit_signals"

    run analyze_response "$output_file" 1 "$HANK_DIR/.response_analysis"
    assert_success

    # Check cost fields in analysis
    local cost=$(jq -r '.analysis.cost_usd' "$HANK_DIR/.response_analysis")
    [[ "$cost" != "0" ]] || fail "cost_usd should be non-zero in analysis, got: $cost"

    local input=$(jq -r '.analysis.usage.input_tokens' "$HANK_DIR/.response_analysis")
    assert_equal "$input" "15000"
}

# =============================================================================
# COST RECORDING TESTS
# =============================================================================

@test "record_loop_cost creates JSONL file" {
    # Create analysis file with cost data
    cat > "$HANK_DIR/.response_analysis" << 'EOF'
{
    "loop_number": 1,
    "analysis": {
        "cost_usd": 0.05,
        "total_cost_usd": 0.05,
        "duration_ms": 45000,
        "num_turns": 10,
        "usage": {
            "input_tokens": 15000,
            "output_tokens": 3000,
            "cache_creation_input_tokens": 0,
            "cache_read_input_tokens": 0
        },
        "session_id": "sess-123"
    }
}
EOF

    run record_loop_cost 1 "$HANK_DIR/.response_analysis" ""
    assert_success

    # JSONL file should exist
    [[ -f "$HANK_DIR/cost_log.jsonl" ]] || fail "cost_log.jsonl should exist"

    # Should contain valid JSON
    local line_count=$(wc -l < "$HANK_DIR/cost_log.jsonl")
    assert_equal "$(echo "$line_count" | tr -d ' ')" "1"

    # Check fields
    local cost=$(jq -r '.cost_usd' "$HANK_DIR/cost_log.jsonl")
    [[ "$cost" != "0" ]] || fail "cost_usd should be non-zero, got: $cost"
}

@test "record_loop_cost appends multiple entries" {
    cat > "$HANK_DIR/.response_analysis" << 'EOF'
{
    "analysis": {
        "cost_usd": 0.05,
        "total_cost_usd": 0.05,
        "duration_ms": 30000,
        "num_turns": 5,
        "usage": {"input_tokens": 10000, "output_tokens": 2000, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0},
        "session_id": ""
    }
}
EOF

    record_loop_cost 1 "$HANK_DIR/.response_analysis" ""

    cat > "$HANK_DIR/.response_analysis" << 'EOF'
{
    "analysis": {
        "cost_usd": 0.08,
        "total_cost_usd": 0.13,
        "duration_ms": 60000,
        "num_turns": 8,
        "usage": {"input_tokens": 20000, "output_tokens": 4000, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0},
        "session_id": ""
    }
}
EOF

    record_loop_cost 2 "$HANK_DIR/.response_analysis" ""

    local line_count=$(wc -l < "$HANK_DIR/cost_log.jsonl" | tr -d ' ')
    assert_equal "$line_count" "2"
}

@test "record_loop_cost includes issue number" {
    cat > "$HANK_DIR/.response_analysis" << 'EOF'
{
    "analysis": {
        "cost_usd": 0.05,
        "total_cost_usd": 0.05,
        "duration_ms": 30000,
        "num_turns": 5,
        "usage": {"input_tokens": 10000, "output_tokens": 2000, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0},
        "session_id": ""
    }
}
EOF

    run record_loop_cost 1 "$HANK_DIR/.response_analysis" "42"
    assert_success

    local issue=$(jq -r '.issue_number' "$HANK_DIR/cost_log.jsonl")
    assert_equal "$issue" "42"
}

@test "record_loop_cost skips when all values are zero" {
    cat > "$HANK_DIR/.response_analysis" << 'EOF'
{
    "analysis": {
        "cost_usd": 0,
        "total_cost_usd": 0,
        "duration_ms": 0,
        "num_turns": 0,
        "usage": {"input_tokens": 0, "output_tokens": 0, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0},
        "session_id": ""
    }
}
EOF

    run record_loop_cost 1 "$HANK_DIR/.response_analysis" ""
    assert_success

    # JSONL file should NOT be created when all values are zero
    [[ ! -f "$HANK_DIR/cost_log.jsonl" ]] || fail "cost_log.jsonl should not exist when all values are zero"
}

@test "record_loop_cost handles missing analysis file" {
    run record_loop_cost 1 "$HANK_DIR/nonexistent_file" ""
    [[ "$status" -ne 0 ]] || fail "Should fail with missing analysis file"
}

# =============================================================================
# SESSION TOTALS TESTS
# =============================================================================

@test "session totals accumulate across loops" {
    cat > "$HANK_DIR/.response_analysis" << 'EOF'
{
    "analysis": {
        "cost_usd": 0.05,
        "total_cost_usd": 0.05,
        "duration_ms": 30000,
        "num_turns": 5,
        "usage": {"input_tokens": 10000, "output_tokens": 2000, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0},
        "session_id": ""
    }
}
EOF

    record_loop_cost 1 "$HANK_DIR/.response_analysis" ""

    cat > "$HANK_DIR/.response_analysis" << 'EOF'
{
    "analysis": {
        "cost_usd": 0.08,
        "total_cost_usd": 0.13,
        "duration_ms": 60000,
        "num_turns": 8,
        "usage": {"input_tokens": 20000, "output_tokens": 4000, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0},
        "session_id": ""
    }
}
EOF

    record_loop_cost 2 "$HANK_DIR/.response_analysis" ""

    # Check session totals
    [[ -f "$HANK_DIR/.cost_session" ]] || fail ".cost_session should exist"

    local total_loops=$(jq -r '.total_loops' "$HANK_DIR/.cost_session")
    assert_equal "$total_loops" "2"

    local total_input=$(jq -r '.total_input_tokens' "$HANK_DIR/.cost_session")
    assert_equal "$total_input" "30000"

    local total_output=$(jq -r '.total_output_tokens' "$HANK_DIR/.cost_session")
    assert_equal "$total_output" "6000"
}

@test "session totals initialize from scratch" {
    _update_session_totals "0.05" "10000" "2000" "30000" "1"

    [[ -f "$HANK_DIR/.cost_session" ]] || fail ".cost_session should exist"

    local total_loops=$(jq -r '.total_loops' "$HANK_DIR/.cost_session")
    assert_equal "$total_loops" "1"

    local total_input=$(jq -r '.total_input_tokens' "$HANK_DIR/.cost_session")
    assert_equal "$total_input" "10000"
}

@test "reset_cost_session clears session but preserves JSONL" {
    # Create both files
    cat > "$HANK_DIR/.response_analysis" << 'EOF'
{
    "analysis": {
        "cost_usd": 0.05,
        "total_cost_usd": 0.05,
        "duration_ms": 30000,
        "num_turns": 5,
        "usage": {"input_tokens": 10000, "output_tokens": 2000, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0},
        "session_id": ""
    }
}
EOF

    record_loop_cost 1 "$HANK_DIR/.response_analysis" ""

    # Both files should exist
    [[ -f "$HANK_DIR/.cost_session" ]] || fail ".cost_session should exist"
    [[ -f "$HANK_DIR/cost_log.jsonl" ]] || fail "cost_log.jsonl should exist"

    # Reset
    reset_cost_session

    # Session file should be gone, JSONL preserved
    [[ ! -f "$HANK_DIR/.cost_session" ]] || fail ".cost_session should be deleted"
    [[ -f "$HANK_DIR/cost_log.jsonl" ]] || fail "cost_log.jsonl should be preserved"
}

# =============================================================================
# SUMMARY DISPLAY TESTS
# =============================================================================

@test "show_cost_summary displays totals" {
    _update_session_totals "0.15" "30000" "6000" "90000" "3"

    run show_cost_summary "false"
    assert_success

    # Should contain cost info
    [[ "$output" == *"0.15"* ]] || fail "Should show total cost"
    [[ "$output" == *"30000"* ]] || fail "Should show input tokens"
    [[ "$output" == *"6000"* ]] || fail "Should show output tokens"
}

@test "show_cost_summary handles no-data case" {
    # No session file exists
    run show_cost_summary "false"
    assert_success

    # Should produce no output (silent)
    assert_equal "$output" ""
}

@test "show_cost_summary shows per-issue breakdown" {
    # Create JSONL with two issues
    echo '{"timestamp":"2026-01-01T00:00:00Z","loop":1,"cost_usd":0.05,"total_cost_usd":0.05,"duration_ms":30000,"num_turns":5,"input_tokens":10000,"output_tokens":2000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"session_id":"","issue_number":"42"}' > "$HANK_DIR/cost_log.jsonl"
    echo '{"timestamp":"2026-01-01T00:01:00Z","loop":2,"cost_usd":0.08,"total_cost_usd":0.13,"duration_ms":60000,"num_turns":8,"input_tokens":20000,"output_tokens":4000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"session_id":"","issue_number":"43"}' >> "$HANK_DIR/cost_log.jsonl"

    _update_session_totals "0.13" "30000" "6000" "90000" "2"

    run show_cost_summary "true"
    assert_success

    [[ "$output" == *"#42"* ]] || fail "Should show issue #42"
    [[ "$output" == *"#43"* ]] || fail "Should show issue #43"
}

# =============================================================================
# GITHUB INTEGRATION TESTS
# =============================================================================

@test "get_issue_cost_summary returns formatted string" {
    echo '{"timestamp":"2026-01-01T00:00:00Z","loop":1,"cost_usd":0.05,"total_cost_usd":0.05,"duration_ms":30000,"num_turns":5,"input_tokens":10000,"output_tokens":2000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"session_id":"","issue_number":"42"}' > "$HANK_DIR/cost_log.jsonl"
    echo '{"timestamp":"2026-01-01T00:01:00Z","loop":2,"cost_usd":0.03,"total_cost_usd":0.08,"duration_ms":20000,"num_turns":3,"input_tokens":5000,"output_tokens":1000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"session_id":"","issue_number":"42"}' >> "$HANK_DIR/cost_log.jsonl"

    run get_issue_cost_summary "42"
    assert_success

    [[ "$output" == *"Cost:"* ]] || fail "Should contain 'Cost:'"
    [[ "$output" == *"2 loops"* ]] || fail "Should show loop count"
    [[ "$output" == *"tokens"* ]] || fail "Should mention tokens"
}

@test "get_issue_cost_summary returns empty for unknown issue" {
    echo '{"timestamp":"2026-01-01T00:00:00Z","loop":1,"cost_usd":0.05,"total_cost_usd":0.05,"duration_ms":30000,"num_turns":5,"input_tokens":10000,"output_tokens":2000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"session_id":"","issue_number":"42"}' > "$HANK_DIR/cost_log.jsonl"

    run get_issue_cost_summary "999"
    assert_success

    assert_equal "$output" ""
}

# =============================================================================
# COST REPORT TESTS
# =============================================================================

@test "show_cost_report displays full report from JSONL" {
    echo '{"timestamp":"2026-01-01T00:00:00Z","loop":1,"cost_usd":0.05,"total_cost_usd":0.05,"duration_ms":30000,"num_turns":5,"input_tokens":10000,"output_tokens":2000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"session_id":"","issue_number":""}' > "$HANK_DIR/cost_log.jsonl"
    echo '{"timestamp":"2026-01-01T00:01:00Z","loop":2,"cost_usd":0.08,"total_cost_usd":0.13,"duration_ms":60000,"num_turns":8,"input_tokens":20000,"output_tokens":4000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"session_id":"","issue_number":""}' >> "$HANK_DIR/cost_log.jsonl"

    run show_cost_report
    assert_success

    [[ "$output" == *"Cost Report"* ]] || fail "Should contain report header"
    [[ "$output" == *"0.13"* ]] || fail "Should show total cost"
}

@test "show_cost_report handles no data" {
    run show_cost_report
    assert_success

    [[ "$output" == *"No cost data"* ]] || fail "Should indicate no data"
}

# =============================================================================
# ANALYSIS TEXT PATH TESTS
# =============================================================================

@test "analyze_response text path includes zero cost defaults" {
    local output_file="$LOG_DIR/test_text_output.log"
    cat > "$output_file" << 'EOF'
Reading PROMPT.md...
Implementing feature X...
All tests passed.
Done.
EOF

    echo '{"test_only_loops": [], "done_signals": [], "completion_indicators": []}' > "$HANK_DIR/.exit_signals"

    run analyze_response "$output_file" 1 "$HANK_DIR/.response_analysis"
    assert_success

    # Should have zero defaults for cost fields
    local cost=$(jq -r '.analysis.cost_usd' "$HANK_DIR/.response_analysis")
    assert_equal "$cost" "0"

    local input=$(jq -r '.analysis.usage.input_tokens' "$HANK_DIR/.response_analysis")
    assert_equal "$input" "0"

    local output_tokens=$(jq -r '.analysis.usage.output_tokens' "$HANK_DIR/.response_analysis")
    assert_equal "$output_tokens" "0"
}
