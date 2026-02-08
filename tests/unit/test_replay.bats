#!/usr/bin/env bats
# Unit tests for session replay functionality

setup() {
    export TEST_DIR=$(mktemp -d)
    export HANK_DIR="$TEST_DIR/.hank"
    mkdir -p "$HANK_DIR"

    # Source the replay library
    source "$BATS_TEST_DIRNAME/../../lib/replay.sh"
}

teardown() {
    rm -rf "$TEST_DIR"
}

# =============================================================================
# Session Discovery Tests
# =============================================================================

@test "list_sessions returns error when no logs exist" {
    # No log files created
    run list_sessions

    [[ "$status" -ne 0 ]]
    [[ "$output" =~ "No session logs found" ]]
}

@test "list_sessions finds sessions in audit_log.jsonl" {
    # Create audit log with sessions
    cat > "$HANK_DIR/audit_log.jsonl" <<'EOF'
{"timestamp":"2026-02-08T10:00:00Z","event_type":"session_start","session_id":"hank-test-001","data":{}}
{"timestamp":"2026-02-08T10:05:00Z","event_type":"loop_start","session_id":"hank-test-001","data":{"loop":1}}
{"timestamp":"2026-02-08T11:00:00Z","event_type":"session_start","session_id":"hank-test-002","data":{}}
EOF

    run list_sessions

    [[ "$status" -eq 0 ]]
    [[ "$output" =~ "hank-test-001" ]]
    [[ "$output" =~ "hank-test-002" ]]
}

@test "list_sessions finds sessions in cost_log.jsonl" {
    # Create cost log with sessions
    cat > "$HANK_DIR/cost_log.jsonl" <<'EOF'
{"timestamp":"2026-02-08T10:00:00Z","session_id":"hank-test-003","loop":1,"cost_usd":0.05}
{"timestamp":"2026-02-08T10:05:00Z","session_id":"hank-test-003","loop":2,"cost_usd":0.07}
{"timestamp":"2026-02-08T11:00:00Z","session_id":"hank-test-004","loop":1,"cost_usd":0.06}
EOF

    run list_sessions

    [[ "$status" -eq 0 ]]
    [[ "$output" =~ "hank-test-003" ]]
    [[ "$output" =~ "hank-test-004" ]]
}

@test "list_sessions deduplicates sessions from multiple sources" {
    # Create both logs with overlapping sessions
    cat > "$HANK_DIR/audit_log.jsonl" <<'EOF'
{"timestamp":"2026-02-08T10:00:00Z","event_type":"session_start","session_id":"hank-test-005","data":{}}
EOF

    cat > "$HANK_DIR/cost_log.jsonl" <<'EOF'
{"timestamp":"2026-02-08T10:00:00Z","session_id":"hank-test-005","loop":1,"cost_usd":0.05}
{"timestamp":"2026-02-08T11:00:00Z","session_id":"hank-test-006","loop":1,"cost_usd":0.06}
EOF

    run list_sessions

    [[ "$status" -eq 0 ]]
    # Should appear once, not twice
    local count=$(echo "$output" | grep -c "hank-test-005")
    [[ "$count" -eq 1 ]]
    [[ "$output" =~ "hank-test-006" ]]
}

# =============================================================================
# Session Summary Tests
# =============================================================================

@test "show_session_summary displays session metadata" {
    # Create cost log for session
    cat > "$HANK_DIR/cost_log.jsonl" <<'EOF'
{"timestamp":"2026-02-08T10:00:00Z","session_id":"hank-test-007","loop":1,"cost_usd":0.05,"issue_number":"123"}
{"timestamp":"2026-02-08T10:05:00Z","session_id":"hank-test-007","loop":2,"cost_usd":0.07,"issue_number":"123"}
{"timestamp":"2026-02-08T10:10:00Z","session_id":"hank-test-007","loop":3,"cost_usd":0.06,"issue_number":"456"}
EOF

    run show_session_summary "hank-test-007"

    [[ "$status" -eq 0 ]]
    [[ "$output" =~ "Session: hank-test-007" ]]
    [[ "$output" =~ "Loops: 3" ]]
    [[ "$output" =~ "Cost: \$0.18" ]] || [[ "$output" =~ "0.18" ]]
    [[ "$output" =~ "Issues: 123 456" ]]
}

@test "show_session_summary calculates cost correctly" {
    # Create cost log with decimal costs
    cat > "$HANK_DIR/cost_log.jsonl" <<'EOF'
{"timestamp":"2026-02-08T10:00:00Z","session_id":"hank-test-008","loop":1,"cost_usd":0.123}
{"timestamp":"2026-02-08T10:05:00Z","session_id":"hank-test-008","loop":2,"cost_usd":0.456}
{"timestamp":"2026-02-08T10:10:00Z","session_id":"hank-test-008","loop":3,"cost_usd":0.789}
EOF

    run show_session_summary "hank-test-008"

    [[ "$status" -eq 0 ]]
    # Total should be 0.123 + 0.456 + 0.789 = 1.368
    [[ "$output" =~ "1.37" ]] || [[ "$output" =~ "1.36" ]]
}

@test "show_session_summary shows status from audit log" {
    # Create logs with exit signal
    cat > "$HANK_DIR/cost_log.jsonl" <<'EOF'
{"timestamp":"2026-02-08T10:00:00Z","session_id":"hank-test-009","loop":1,"cost_usd":0.05}
EOF

    cat > "$HANK_DIR/audit_log.jsonl" <<'EOF'
{"timestamp":"2026-02-08T10:00:00Z","event_type":"session_start","session_id":"hank-test-009","data":{}}
{"timestamp":"2026-02-08T10:05:00Z","event_type":"exit_signal","session_id":"hank-test-009","data":{"reason":"completed"}}
EOF

    run show_session_summary "hank-test-009"

    [[ "$status" -eq 0 ]]
    [[ "$output" =~ "Status: completed" ]]
}

# =============================================================================
# Session Existence Tests
# =============================================================================

@test "session_exists returns true for existing session in audit log" {
    cat > "$HANK_DIR/audit_log.jsonl" <<'EOF'
{"timestamp":"2026-02-08T10:00:00Z","event_type":"session_start","session_id":"hank-exists-001","data":{}}
EOF

    session_exists "hank-exists-001"
    [[ $? -eq 0 ]]
}

@test "session_exists returns true for existing session in cost log" {
    cat > "$HANK_DIR/cost_log.jsonl" <<'EOF'
{"timestamp":"2026-02-08T10:00:00Z","session_id":"hank-exists-002","loop":1,"cost_usd":0.05}
EOF

    session_exists "hank-exists-002"
    [[ $? -eq 0 ]]
}

@test "session_exists returns false for non-existent session" {
    cat > "$HANK_DIR/audit_log.jsonl" <<'EOF'
{"timestamp":"2026-02-08T10:00:00Z","event_type":"session_start","session_id":"hank-exists-003","data":{}}
EOF

    run session_exists "hank-nonexistent"
    [[ "$status" -ne 0 ]]
}

# =============================================================================
# Timeline Reconstruction Tests
# =============================================================================

@test "replay_session returns error for non-existent session" {
    cat > "$HANK_DIR/audit_log.jsonl" <<'EOF'
{"timestamp":"2026-02-08T10:00:00Z","event_type":"session_start","session_id":"hank-replay-001","data":{}}
EOF

    run replay_session "hank-nonexistent"

    [[ "$status" -ne 0 ]]
    [[ "$output" =~ Session.*not.*found ]]
}

@test "replay_session outputs human-readable format by default" {
    # Create complete session logs
    cat > "$HANK_DIR/audit_log.jsonl" <<'EOF'
{"timestamp":"2026-02-08T10:00:00Z","event_type":"session_start","session_id":"hank-replay-002","data":{"mode":"build","source":"local"}}
{"timestamp":"2026-02-08T10:01:00Z","event_type":"loop_start","session_id":"hank-replay-002","data":{"loop":1}}
EOF

    cat > "$HANK_DIR/cost_log.jsonl" <<'EOF'
{"timestamp":"2026-02-08T10:02:00Z","session_id":"hank-replay-002","loop":1,"cost_usd":0.05,"duration_ms":60000}
EOF

    run replay_session "hank-replay-002" "human"

    [[ "$status" -eq 0 ]]
    [[ "$output" =~ "Session Replay: hank-replay-002" ]]
    [[ "$output" =~ "Session Started" ]]
    [[ "$output" =~ "Loop 1" ]]
}

@test "replay_session outputs JSON format when requested" {
    cat > "$HANK_DIR/audit_log.jsonl" <<'EOF'
{"timestamp":"2026-02-08T10:00:00Z","event_type":"session_start","session_id":"hank-replay-003","data":{"mode":"build"}}
EOF

    run replay_session "hank-replay-003" "json"

    [[ "$status" -eq 0 ]]
    # Output should be valid JSON
    echo "$output" | jq -e '.' >/dev/null
}

@test "replay_session merges events from audit and cost logs" {
    cat > "$HANK_DIR/audit_log.jsonl" <<'EOF'
{"timestamp":"2026-02-08T10:00:00Z","event_type":"session_start","session_id":"hank-replay-004","data":{}}
{"timestamp":"2026-02-08T10:01:30Z","event_type":"error_detected","session_id":"hank-replay-004","data":{"category":"test_failure"}}
EOF

    cat > "$HANK_DIR/cost_log.jsonl" <<'EOF'
{"timestamp":"2026-02-08T10:01:00Z","session_id":"hank-replay-004","loop":1,"cost_usd":0.05}
{"timestamp":"2026-02-08T10:02:00Z","session_id":"hank-replay-004","loop":2,"cost_usd":0.07}
EOF

    run replay_session "hank-replay-004" "json"

    [[ "$status" -eq 0 ]]
    # Should have events from both sources
    local event_count=$(echo "$output" | jq 'length')
    [[ "$event_count" -ge 4 ]]
}

@test "replay_session sorts timeline by timestamp" {
    cat > "$HANK_DIR/audit_log.jsonl" <<'EOF'
{"timestamp":"2026-02-08T10:02:00Z","event_type":"loop_start","session_id":"hank-replay-005","data":{"loop":2}}
{"timestamp":"2026-02-08T10:00:00Z","event_type":"session_start","session_id":"hank-replay-005","data":{}}
{"timestamp":"2026-02-08T10:01:00Z","event_type":"loop_start","session_id":"hank-replay-005","data":{"loop":1}}
EOF

    run replay_session "hank-replay-005" "json"

    [[ "$status" -eq 0 ]]
    # First event should be session_start (earliest timestamp)
    local first_event=$(echo "$output" | jq -r '.[0].event_type')
    [[ "$first_event" == "session_start" ]]
}

@test "replay_session filters by issue number" {
    cat > "$HANK_DIR/cost_log.jsonl" <<'EOF'
{"timestamp":"2026-02-08T10:00:00Z","session_id":"hank-replay-006","loop":1,"cost_usd":0.05,"issue_number":"123"}
{"timestamp":"2026-02-08T10:01:00Z","session_id":"hank-replay-006","loop":2,"cost_usd":0.07,"issue_number":"456"}
{"timestamp":"2026-02-08T10:02:00Z","session_id":"hank-replay-006","loop":3,"cost_usd":0.06,"issue_number":"123"}
EOF

    run replay_session "hank-replay-006" "json" "123"

    [[ "$status" -eq 0 ]]
    # Should only include loops for issue 123
    local event_count=$(echo "$output" | jq '[.[] | select(.event_type == "loop_completed")] | length')
    [[ "$event_count" -eq 2 ]]
}

# =============================================================================
# Timeline Rendering Tests
# =============================================================================

@test "render_timeline_human displays all event types" {
    # Create timeline with various event types
    local timeline='[
        {"timestamp":"2026-02-08T10:00:00Z","event_type":"session_start","data":{"mode":"build"}},
        {"timestamp":"2026-02-08T10:01:00Z","event_type":"loop_completed","data":{"loop":1,"cost_usd":0.05,"duration_ms":60000}},
        {"timestamp":"2026-02-08T10:02:00Z","event_type":"error_detected","data":{"category":"test_failure","message":"Test failed"}},
        {"timestamp":"2026-02-08T10:03:00Z","event_type":"retry_attempt","data":{"attempt":1,"strategy":"retry_with_hint"}},
        {"timestamp":"2026-02-08T10:04:00Z","event_type":"circuit_breaker_state_change","data":{"from_state":"CLOSED","to_state":"OPEN","reason":"max_errors"}},
        {"timestamp":"2026-02-08T10:05:00Z","event_type":"exit_signal","data":{"reason":"completed"}}
    ]'

    run render_timeline_human "$timeline" "hank-test-render"

    [[ "$status" -eq 0 ]]
    [[ "$output" =~ "Session Started" ]]
    [[ "$output" =~ "Loop 1 Completed" ]]
    [[ "$output" =~ "Error Detected: test_failure" ]]
    [[ "$output" =~ "Retry Attempt 1" ]]
    [[ "$output" =~ "Circuit Breaker: CLOSED → OPEN" ]]
    [[ "$output" =~ "Exit Signal: completed" ]]
}

@test "render_timeline_human calculates session summary" {
    local timeline='[
        {"timestamp":"2026-02-08T10:00:00Z","event_type":"loop_completed","data":{"loop":1,"cost_usd":0.05}},
        {"timestamp":"2026-02-08T10:01:00Z","event_type":"loop_completed","data":{"loop":2,"cost_usd":0.07}},
        {"timestamp":"2026-02-08T10:02:00Z","event_type":"loop_completed","data":{"loop":3,"cost_usd":0.08,"issue_number":"123"}}
    ]'

    run render_timeline_human "$timeline" "hank-test-summary"

    [[ "$status" -eq 0 ]]
    [[ "$output" =~ "Total Loops: 3" ]]
    [[ "$output" =~ "Total Cost: \$0.2" ]] || [[ "$output" =~ "0.2" ]]
    [[ "$output" =~ "Issues Worked: 123" ]]
}

# =============================================================================
# Format Timestamp Tests
# =============================================================================

@test "format_timestamp handles ISO 8601 format" {
    local timestamp="2026-02-08T10:30:45Z"

    run format_timestamp "$timestamp"

    # Should format to readable format (exact format depends on system)
    [[ "$status" -eq 0 ]]
    [[ "$output" =~ "2026-02-08" ]]
}

@test "format_timestamp returns input if parsing fails" {
    local invalid_timestamp="not-a-timestamp"

    run format_timestamp "$invalid_timestamp"

    [[ "$status" -eq 0 ]]
    [[ "$output" == "$invalid_timestamp" ]]
}

# =============================================================================
# Integration Tests
# =============================================================================

@test "complete workflow: session with errors and retries" {
    # Create realistic session with errors and retries
    cat > "$HANK_DIR/audit_log.jsonl" <<'EOF'
{"timestamp":"2026-02-08T10:00:00Z","event_type":"session_start","session_id":"hank-integration-001","data":{"mode":"build","source":"github"}}
{"timestamp":"2026-02-08T10:01:00Z","event_type":"loop_start","session_id":"hank-integration-001","data":{"loop":1}}
{"timestamp":"2026-02-08T10:02:30Z","event_type":"error_detected","session_id":"hank-integration-001","data":{"category":"test_failure","message":"auth.test.js failed"}}
{"timestamp":"2026-02-08T10:03:00Z","event_type":"retry_attempt","session_id":"hank-integration-001","data":{"attempt":1,"strategy":"retry_with_hint"}}
{"timestamp":"2026-02-08T10:05:00Z","event_type":"issue_closed","session_id":"hank-integration-001","data":{"issue_number":"123"}}
{"timestamp":"2026-02-08T10:06:00Z","event_type":"exit_signal","session_id":"hank-integration-001","data":{"reason":"all_tasks_completed"}}
EOF

    cat > "$HANK_DIR/cost_log.jsonl" <<'EOF'
{"timestamp":"2026-02-08T10:02:00Z","session_id":"hank-integration-001","loop":1,"cost_usd":0.05,"duration_ms":60000,"issue_number":"123"}
{"timestamp":"2026-02-08T10:04:00Z","session_id":"hank-integration-001","loop":2,"cost_usd":0.07,"duration_ms":65000,"issue_number":"123"}
EOF

    # Test list_sessions
    run list_sessions

    [[ "$status" -eq 0 ]]
    [[ "$output" =~ "hank-integration-001" ]]
    [[ "$output" =~ "Loops: 2" ]]
    [[ "$output" =~ "Issues: 123" ]]

    # Test replay in human format
    run replay_session "hank-integration-001" "human"

    [[ "$status" -eq 0 ]]
    [[ "$output" =~ "Session Replay: hank-integration-001" ]]
    [[ "$output" =~ "Error Detected" ]]
    [[ "$output" =~ "Retry Attempt" ]]
    [[ "$output" =~ "Issue #123 Closed" ]]

    # Test replay in JSON format
    run replay_session "hank-integration-001" "json"

    [[ "$status" -eq 0 ]]
    echo "$output" | jq -e '.' >/dev/null
    local event_count=$(echo "$output" | jq 'length')
    [[ "$event_count" -ge 8 ]]
}
