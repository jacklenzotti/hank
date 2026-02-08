#!/usr/bin/env bats
# Tests for audit log functionality

load '../helpers/test_helper'

setup() {
    # Create temporary test directory
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"

    # Set up environment
    export HANK_DIR=".hank"
    mkdir -p "$HANK_DIR"

    # Source the audit log library from the repo root
    source "$BATS_TEST_DIRNAME/../../lib/audit_log.sh"
}

teardown() {
    # Clean up temporary directory
    rm -rf "$TEST_DIR"
}

# =============================================================================
# INITIALIZATION TESTS
# =============================================================================

@test "init_audit_log creates audit log file" {
    init_audit_log

    [[ -f "$HANK_DIR/audit_log.jsonl" ]]
}

@test "init_audit_log is idempotent" {
    init_audit_log
    init_audit_log

    [[ -f "$HANK_DIR/audit_log.jsonl" ]]
}

@test "init_audit_log creates HANK_DIR if missing" {
    rm -rf "$HANK_DIR"
    init_audit_log

    [[ -d "$HANK_DIR" ]]
    [[ -f "$HANK_DIR/audit_log.jsonl" ]]
}

# =============================================================================
# EVENT RECORDING TESTS
# =============================================================================

@test "audit_event writes valid JSONL event" {
    init_audit_log

    audit_event "session_start" '{"mode": "build"}'

    # Check file has exactly 1 line
    local line_count=$(wc -l < "$HANK_DIR/audit_log.jsonl")
    [[ "$line_count" -eq 1 ]]

    # Verify JSON is valid
    jq empty "$HANK_DIR/audit_log.jsonl"
}

@test "audit_event includes all required fields" {
    init_audit_log

    audit_event "loop_complete" '{"files_changed": 3}'

    local event=$(cat "$HANK_DIR/audit_log.jsonl")

    # Check required fields exist
    echo "$event" | jq -e '.timestamp' >/dev/null
    echo "$event" | jq -e '.event_type' >/dev/null
    echo "$event" | jq -e '.session_id' >/dev/null
    echo "$event" | jq -e '.loop_number' >/dev/null
    echo "$event" | jq -e '.details' >/dev/null
}

@test "audit_event sets correct event_type" {
    init_audit_log

    audit_event "error_detected" '{}'

    local event_type=$(jq -r '.event_type' "$HANK_DIR/audit_log.jsonl")
    [[ "$event_type" == "error_detected" ]]
}

@test "audit_event includes details JSON" {
    init_audit_log

    audit_event "loop_complete" '{"files_changed": 5, "cost_usd": 0.02}'

    local details=$(jq -r '.details' "$HANK_DIR/audit_log.jsonl")
    local files=$(echo "$details" | jq -r '.files_changed')
    local cost=$(echo "$details" | jq -r '.cost_usd')

    [[ "$files" == "5" ]]
    [[ "$cost" == "0.02" ]]
}

@test "audit_event handles empty details" {
    init_audit_log

    audit_event "session_reset"

    local details=$(jq -r '.details' "$HANK_DIR/audit_log.jsonl")
    [[ "$details" == "{}" ]]
}

@test "audit_event fails with missing event_type" {
    init_audit_log

    run audit_event ""
    [[ "$status" -eq 1 ]]
}

@test "audit_event fails with invalid JSON details" {
    init_audit_log

    run audit_event "test_event" "not valid json"
    [[ "$status" -eq 1 ]]
}

@test "audit_event reads session_id from state file" {
    init_audit_log

    # Create session state file
    echo '{"session_id": "test-session-123", "timestamp": "2026-02-07T20:00:00Z"}' \
        > "$HANK_DIR/.claude_session_id"

    audit_event "loop_start" '{}'

    local session_id=$(jq -r '.session_id' "$HANK_DIR/audit_log.jsonl")
    [[ "$session_id" == "test-session-123" ]]
}

@test "audit_event reads loop_number from state file" {
    init_audit_log

    # Create loop number file
    echo "5" > "$HANK_DIR/.loop_number"

    audit_event "loop_complete" '{}'

    local loop_number=$(jq -r '.loop_number' "$HANK_DIR/audit_log.jsonl")
    [[ "$loop_number" -eq 5 ]]
}

@test "audit_event appends multiple events" {
    init_audit_log

    audit_event "session_start" '{}'
    audit_event "loop_start" '{}'
    audit_event "loop_complete" '{}'

    local event_count=$(wc -l < "$HANK_DIR/audit_log.jsonl")
    [[ "$event_count" -eq 3 ]]
}

@test "audit_event writes compact JSONL" {
    init_audit_log

    audit_event "test_event" '{"key": "value"}'

    # Check that output is single-line (no pretty-printing)
    local event=$(cat "$HANK_DIR/audit_log.jsonl")
    [[ ! "$event" =~ $'\n' ]]
}

# =============================================================================
# LOG ROTATION TESTS
# =============================================================================

@test "rotate_audit_log does nothing when under limit" {
    init_audit_log

    # Add 100 events
    for i in {1..100}; do
        audit_event "test_event" "{\"count\": $i}"
    done

    rotate_audit_log

    # All events should still be in main log
    local event_count=$(wc -l < "$HANK_DIR/audit_log.jsonl")
    [[ "$event_count" -eq 100 ]]
    [[ ! -f "$HANK_DIR/audit_log.jsonl.1" ]]
}

@test "rotate_audit_log keeps last 10000 events" {
    init_audit_log

    # Add 11000 events (over the limit)
    for i in {1..11000}; do
        echo "{\"timestamp\":\"2026-02-07T20:00:00Z\",\"event_type\":\"test\",\"session_id\":\"\",\"loop_number\":$i,\"details\":{}}" \
            >> "$HANK_DIR/audit_log.jsonl"
    done

    rotate_audit_log

    # Main log should have exactly 10000 events
    local event_count=$(wc -l < "$HANK_DIR/audit_log.jsonl")
    [[ "$event_count" -eq 10000 ]]

    # Archive should have 1000 events
    local archive_count=$(wc -l < "$HANK_DIR/audit_log.jsonl.1")
    [[ "$archive_count" -eq 1000 ]]
}

@test "rotate_audit_log keeps most recent events" {
    init_audit_log

    # Add events with incrementing loop numbers
    for i in {1..11000}; do
        echo "{\"timestamp\":\"2026-02-07T20:00:00Z\",\"event_type\":\"test\",\"session_id\":\"\",\"loop_number\":$i,\"details\":{}}" \
            >> "$HANK_DIR/audit_log.jsonl"
    done

    rotate_audit_log

    # Check that the last event has loop_number 11000
    local last_loop=$(tail -1 "$HANK_DIR/audit_log.jsonl" | jq -r '.loop_number')
    [[ "$last_loop" -eq 11000 ]]

    # Check that the first event has loop_number 1001 (after removing first 1000)
    local first_loop=$(head -1 "$HANK_DIR/audit_log.jsonl" | jq -r '.loop_number')
    [[ "$first_loop" -eq 1001 ]]
}

@test "rotate_audit_log replaces old archive" {
    init_audit_log

    # Create old archive
    echo "old archive content" > "$HANK_DIR/audit_log.jsonl.1"

    # Add events over limit
    for i in {1..11000}; do
        echo "{\"timestamp\":\"2026-02-07T20:00:00Z\",\"event_type\":\"test\",\"session_id\":\"\",\"loop_number\":$i,\"details\":{}}" \
            >> "$HANK_DIR/audit_log.jsonl"
    done

    rotate_audit_log

    # Archive should contain new events, not old content
    local archive_first_line=$(head -1 "$HANK_DIR/audit_log.jsonl.1")
    [[ "$archive_first_line" != "old archive content" ]]
}

@test "check_and_rotate calls rotate_audit_log" {
    init_audit_log

    # Add events over limit
    for i in {1..11000}; do
        echo "{\"timestamp\":\"2026-02-07T20:00:00Z\",\"event_type\":\"test\",\"session_id\":\"\",\"loop_number\":$i,\"details\":{}}" \
            >> "$HANK_DIR/audit_log.jsonl"
    done

    check_and_rotate

    # Should have rotated
    local event_count=$(wc -l < "$HANK_DIR/audit_log.jsonl")
    [[ "$event_count" -eq 10000 ]]
}

# =============================================================================
# QUERY/DISPLAY TESTS
# =============================================================================

@test "display_audit_log shows events" {
    init_audit_log

    audit_event "session_start" '{}'
    audit_event "loop_complete" '{}'

    run display_audit_log
    [[ "$status" -eq 0 ]]
    [[ "$output" =~ "session_start" ]]
    [[ "$output" =~ "loop_complete" ]]
}

@test "display_audit_log filters by event type" {
    init_audit_log

    audit_event "session_start" '{}'
    audit_event "loop_complete" '{}'
    audit_event "error_detected" '{}'

    run display_audit_log --type "error_detected"
    [[ "$status" -eq 0 ]]
    [[ "$output" =~ "error_detected" ]]
    [[ ! "$output" =~ "session_start" ]]
    [[ ! "$output" =~ "loop_complete" ]]
}

@test "display_audit_log filters by session ID" {
    init_audit_log

    # Create session state
    echo '{"session_id": "session-A", "timestamp": "2026-02-07T20:00:00Z"}' \
        > "$HANK_DIR/.claude_session_id"
    audit_event "loop_start" '{}'

    # Change session
    echo '{"session_id": "session-B", "timestamp": "2026-02-07T21:00:00Z"}' \
        > "$HANK_DIR/.claude_session_id"
    audit_event "loop_start" '{}'

    run display_audit_log --session "session-A"
    [[ "$status" -eq 0 ]]
    # Should show 1 event
    local event_count=$(echo "$output" | grep -c "loop_start" || echo "0")
    [[ "$event_count" -eq 1 ]]
}

@test "display_audit_log limits output" {
    init_audit_log

    # Add 50 events
    for i in {1..50}; do
        audit_event "test_event" "{\"count\": $i}"
    done

    run display_audit_log --limit 10
    [[ "$status" -eq 0 ]]

    # Count events in output (should be at most 10)
    local event_count=$(echo "$output" | grep -c "test_event" || echo "0")
    [[ "$event_count" -le 10 ]]
}

@test "display_audit_log shows no events message when empty" {
    init_audit_log

    run display_audit_log
    [[ "$status" -eq 0 ]]
    [[ "$output" =~ "No events match the filter criteria" ]]
}

@test "display_audit_log shows no audit log message when file missing" {
    # Don't initialize log
    run display_audit_log
    [[ "$status" -eq 0 ]]
    [[ "$output" =~ "No audit log found" ]]
}

# =============================================================================
# TIME PARSING TESTS
# =============================================================================

@test "parse_relative_time handles minutes" {
    local result=$(parse_relative_time "30m")
    [[ -n "$result" ]]
    # Result should be ISO timestamp
    [[ "$result" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

@test "parse_relative_time handles hours" {
    local result=$(parse_relative_time "2h")
    [[ -n "$result" ]]
    [[ "$result" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

@test "parse_relative_time handles days" {
    local result=$(parse_relative_time "1d")
    [[ -n "$result" ]]
    [[ "$result" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

@test "parse_relative_time rejects invalid format" {
    local result=$(parse_relative_time "invalid")
    [[ -z "$result" ]]
}

@test "parse_relative_time rejects missing number" {
    local result=$(parse_relative_time "h")
    [[ -z "$result" ]]
}

@test "parse_relative_time rejects missing unit" {
    local result=$(parse_relative_time "30")
    [[ -z "$result" ]]
}

# =============================================================================
# INTEGRATION TESTS
# =============================================================================

@test "full workflow: init, record, query" {
    init_audit_log

    # Record session
    echo '{"session_id": "test-session", "timestamp": "2026-02-07T20:00:00Z"}' \
        > "$HANK_DIR/.claude_session_id"

    audit_event "session_start" '{"mode": "build"}'
    audit_event "loop_start" '{}'
    audit_event "loop_complete" '{"files_changed": 3}'

    # Query
    run display_audit_log
    [[ "$status" -eq 0 ]]
    [[ "$output" =~ "session_start" ]]
    [[ "$output" =~ "loop_complete" ]]
}

@test "event types: session_start" {
    init_audit_log
    audit_event "session_start" '{"mode": "build", "max_calls": 50}'

    local event_type=$(jq -r '.event_type' "$HANK_DIR/audit_log.jsonl")
    [[ "$event_type" == "session_start" ]]
}

@test "event types: session_reset" {
    init_audit_log
    audit_event "session_reset" '{"reason": "manual"}'

    local event_type=$(jq -r '.event_type' "$HANK_DIR/audit_log.jsonl")
    [[ "$event_type" == "session_reset" ]]
}

@test "event types: loop_start" {
    init_audit_log
    audit_event "loop_start" '{}'

    local event_type=$(jq -r '.event_type' "$HANK_DIR/audit_log.jsonl")
    [[ "$event_type" == "loop_start" ]]
}

@test "event types: loop_complete" {
    init_audit_log
    audit_event "loop_complete" '{"files_changed": 2, "exit_signal": false}'

    local event_type=$(jq -r '.event_type' "$HANK_DIR/audit_log.jsonl")
    [[ "$event_type" == "loop_complete" ]]
}

@test "event types: error_detected" {
    init_audit_log
    audit_event "error_detected" '{"category": "test_failure", "signature": "abc123"}'

    local event_type=$(jq -r '.event_type' "$HANK_DIR/audit_log.jsonl")
    [[ "$event_type" == "error_detected" ]]
}

@test "event types: circuit_breaker_state_change" {
    init_audit_log
    audit_event "circuit_breaker_state_change" '{"from": "CLOSED", "to": "OPEN"}'

    local event_type=$(jq -r '.event_type' "$HANK_DIR/audit_log.jsonl")
    [[ "$event_type" == "circuit_breaker_state_change" ]]
}

@test "event types: task_sync" {
    init_audit_log
    audit_event "task_sync" '{"source": "github", "issues_synced": 5}'

    local event_type=$(jq -r '.event_type' "$HANK_DIR/audit_log.jsonl")
    [[ "$event_type" == "task_sync" ]]
}

@test "event types: issue_closed" {
    init_audit_log
    audit_event "issue_closed" '{"issue_number": 123}'

    local event_type=$(jq -r '.event_type' "$HANK_DIR/audit_log.jsonl")
    [[ "$event_type" == "issue_closed" ]]
}

@test "event types: exit_signal" {
    init_audit_log
    audit_event "exit_signal" '{"reason": "completion", "exit_signal": true}'

    local event_type=$(jq -r '.event_type' "$HANK_DIR/audit_log.jsonl")
    [[ "$event_type" == "exit_signal" ]]
}
