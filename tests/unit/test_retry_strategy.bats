#!/usr/bin/env bats
# Tests for lib/retry_strategy.sh

setup() {
    # Use a temp directory for test files
    export HANK_DIR=$(mktemp -d)
    export BATS_TEST_DIRNAME_ABS="$BATS_TEST_DIRNAME"

    # Source the library under test
    source "$BATS_TEST_DIRNAME/../../lib/retry_strategy.sh"

    # Set test configuration
    export RETRY_MAX_ATTEMPTS=3
    export RETRY_BACKOFF_INITIAL_SEC=30
    export RETRY_BACKOFF_MAX_SEC=300
    export RETRY_BACKOFF_MULTIPLIER=2
}

teardown() {
    # Clean up temp directory
    rm -rf "$HANK_DIR"
}

# =============================================================================
# get_retry_strategy tests
# =============================================================================

@test "get_retry_strategy returns wait_and_retry for rate_limit" {
    result=$(get_retry_strategy "rate_limit")
    [[ "$result" == "wait_and_retry" ]]
}

@test "get_retry_strategy returns halt for permission_denied" {
    result=$(get_retry_strategy "permission_denied")
    [[ "$result" == "halt" ]]
}

@test "get_retry_strategy returns retry_with_hint for test_failure" {
    result=$(get_retry_strategy "test_failure")
    [[ "$result" == "retry_with_hint" ]]
}

@test "get_retry_strategy returns retry_with_hint for build_error" {
    result=$(get_retry_strategy "build_error")
    [[ "$result" == "retry_with_hint" ]]
}

@test "get_retry_strategy returns retry_with_hint for dependency_error" {
    result=$(get_retry_strategy "dependency_error")
    [[ "$result" == "retry_with_hint" ]]
}

@test "get_retry_strategy returns reset_session for context_overflow" {
    result=$(get_retry_strategy "context_overflow")
    [[ "$result" == "reset_session" ]]
}

@test "get_retry_strategy returns wait_and_retry for api_error" {
    result=$(get_retry_strategy "api_error")
    [[ "$result" == "wait_and_retry" ]]
}

@test "get_retry_strategy returns no_retry for unknown" {
    result=$(get_retry_strategy "unknown")
    [[ "$result" == "no_retry" ]]
}

@test "get_retry_strategy returns no_retry for invalid category" {
    result=$(get_retry_strategy "invalid_category")
    [[ "$result" == "no_retry" ]]
}

# =============================================================================
# get_retry_hint tests
# =============================================================================

@test "get_retry_hint returns hint for test_failure" {
    result=$(get_retry_hint "test_failure")
    [[ "$result" =~ "Focus on fixing the failing test" ]]
}

@test "get_retry_hint returns hint for build_error" {
    result=$(get_retry_hint "build_error")
    [[ "$result" =~ "Check build output" ]]
}

@test "get_retry_hint returns hint for dependency_error" {
    result=$(get_retry_hint "dependency_error")
    [[ "$result" =~ "Install missing dependency" ]]
}

@test "get_retry_hint returns empty for rate_limit" {
    result=$(get_retry_hint "rate_limit")
    [[ -z "$result" ]]
}

@test "get_retry_hint returns empty for unknown" {
    result=$(get_retry_hint "unknown")
    [[ -z "$result" ]]
}

# =============================================================================
# calculate_backoff tests
# =============================================================================

@test "calculate_backoff returns initial wait time for attempt 1" {
    result=$(calculate_backoff 1)
    [[ "$result" -eq 30 ]]
}

@test "calculate_backoff applies exponential backoff for attempt 2" {
    result=$(calculate_backoff 2)
    [[ "$result" -eq 60 ]]
}

@test "calculate_backoff applies exponential backoff for attempt 3" {
    result=$(calculate_backoff 3)
    [[ "$result" -eq 120 ]]
}

@test "calculate_backoff caps at max wait time" {
    result=$(calculate_backoff 10)
    [[ "$result" -le 300 ]]
}

@test "calculate_backoff respects RETRY_BACKOFF_MAX_SEC" {
    export RETRY_BACKOFF_MAX_SEC=120
    result=$(calculate_backoff 5)
    [[ "$result" -le 120 ]]
}

@test "calculate_backoff respects RETRY_BACKOFF_MULTIPLIER" {
    export RETRY_BACKOFF_MULTIPLIER=3
    export RETRY_BACKOFF_INITIAL_SEC=10
    result=$(calculate_backoff 2)
    [[ "$result" -eq 30 ]]
}

# =============================================================================
# should_retry tests
# =============================================================================

@test "should_retry returns true when attempts below max" {
    should_retry "test_failure" 1
}

@test "should_retry returns false when attempts at max" {
    ! should_retry "test_failure" 3
}

@test "should_retry returns false when attempts exceed max" {
    ! should_retry "test_failure" 5
}

@test "should_retry returns false for halt strategy" {
    ! should_retry "permission_denied" 0
}

@test "should_retry returns false for no_retry strategy" {
    ! should_retry "unknown" 0
}

@test "should_retry handles zero attempts correctly" {
    should_retry "test_failure" 0
}

@test "should_retry respects RETRY_MAX_ATTEMPTS" {
    export RETRY_MAX_ATTEMPTS=5
    should_retry "test_failure" 4
}

# =============================================================================
# get_retry_state tests
# =============================================================================

@test "get_retry_state returns default when state file missing" {
    result=$(get_retry_state 1 "sig123")
    [[ "$result" == '{"attempt_count":0}' ]]
}

@test "get_retry_state returns state for existing error" {
    # Create state file with an error
    echo '{"errors":{"sig123":{"attempt_count":2,"category":"test_failure"}}}' > "$HANK_DIR/.retry_state"

    result=$(get_retry_state 1 "sig123")
    attempt_count=$(echo "$result" | jq -r '.attempt_count')
    [[ "$attempt_count" -eq 2 ]]
}

@test "get_retry_state returns default for unknown signature" {
    echo '{"errors":{"sig999":{"attempt_count":2}}}' > "$HANK_DIR/.retry_state"

    result=$(get_retry_state 1 "sig123")
    attempt_count=$(echo "$result" | jq -r '.attempt_count')
    [[ "$attempt_count" -eq 0 ]]
}

# =============================================================================
# update_retry_state tests
# =============================================================================

@test "update_retry_state creates state file if missing" {
    update_retry_state 1 "sig123" "test_failure" "pending"

    [[ -f "$HANK_DIR/.retry_state" ]]
}

@test "update_retry_state increments attempt count" {
    update_retry_state 1 "sig123" "test_failure" "pending"

    attempt_count=$(jq -r '.errors.sig123.attempt_count' "$HANK_DIR/.retry_state")
    [[ "$attempt_count" -eq 1 ]]
}

@test "update_retry_state increments existing attempt count" {
    echo '{"errors":{"sig123":{"attempt_count":2}}}' > "$HANK_DIR/.retry_state"

    update_retry_state 1 "sig123" "test_failure" "pending"

    attempt_count=$(jq -r '.errors.sig123.attempt_count' "$HANK_DIR/.retry_state")
    [[ "$attempt_count" -eq 3 ]]
}

@test "update_retry_state stores outcome" {
    update_retry_state 1 "sig123" "test_failure" "success"

    outcome=$(jq -r '.errors.sig123.last_outcome' "$HANK_DIR/.retry_state")
    [[ "$outcome" == "success" ]]
}

@test "update_retry_state stores timestamp" {
    update_retry_state 1 "sig123" "test_failure" "pending"

    timestamp=$(jq -r '.errors.sig123.last_attempt_timestamp' "$HANK_DIR/.retry_state")
    [[ -n "$timestamp" ]]
}

# =============================================================================
# reset_retry_state tests
# =============================================================================

@test "reset_retry_state clears state file" {
    # Create state file with data
    echo '{"errors":{"sig123":{"attempt_count":5}}}' > "$HANK_DIR/.retry_state"

    reset_retry_state

    result=$(cat "$HANK_DIR/.retry_state")
    [[ "$result" == '{"errors":{}}' ]]
}

@test "reset_retry_state creates empty state if file missing" {
    reset_retry_state

    [[ -f "$HANK_DIR/.retry_state" ]]
    result=$(cat "$HANK_DIR/.retry_state")
    [[ "$result" == '{"errors":{}}' ]]
}

# =============================================================================
# log_retry_attempt tests
# =============================================================================

@test "log_retry_attempt creates JSONL log file" {
    log_retry_attempt 1 "test_failure" 1 "retry_with_hint" "pending"

    [[ -f "$HANK_DIR/.retry_log" ]]
}

@test "log_retry_attempt writes valid JSONL" {
    log_retry_attempt 1 "test_failure" 1 "retry_with_hint" "pending"

    jq -e '.' "$HANK_DIR/.retry_log" > /dev/null
}

@test "log_retry_attempt includes all fields" {
    log_retry_attempt 5 "build_error" 2 "wait_and_retry" "success"

    entry=$(cat "$HANK_DIR/.retry_log")

    echo "$entry" | jq -e '.timestamp'
    echo "$entry" | jq -e '.loop == 5'
    echo "$entry" | jq -e '.error_category == "build_error"'
    echo "$entry" | jq -e '.attempt == 2'
    echo "$entry" | jq -e '.strategy == "wait_and_retry"'
    echo "$entry" | jq -e '.outcome == "success"'
}

@test "log_retry_attempt appends to existing log" {
    log_retry_attempt 1 "test_failure" 1 "retry_with_hint" "pending"
    log_retry_attempt 2 "build_error" 1 "wait_and_retry" "success"

    line_count=$(wc -l < "$HANK_DIR/.retry_log")
    [[ "$line_count" -eq 2 ]]
}

# =============================================================================
# execute_retry tests
# =============================================================================

@test "execute_retry wait_and_retry returns success" {
    # Mock sleep to avoid waiting
    sleep() { :; }
    export -f sleep

    execute_retry "wait_and_retry" 1 "rate_limit" 1
}

@test "execute_retry retry_with_hint returns success" {
    execute_retry "retry_with_hint" 1 "test_failure" 1
}

@test "execute_retry retry_with_hint writes hint file" {
    execute_retry "retry_with_hint" 1 "test_failure" 1

    [[ -f "$HANK_DIR/.retry_hint" ]]
}

@test "execute_retry reset_session returns success" {
    execute_retry "reset_session" 1 "context_overflow" 1
}

@test "execute_retry reset_session writes action file" {
    execute_retry "reset_session" 1 "context_overflow" 1

    [[ -f "$HANK_DIR/.retry_action" ]]
    action=$(cat "$HANK_DIR/.retry_action")
    [[ "$action" == "reset_session" ]]
}

@test "execute_retry halt returns failure" {
    ! execute_retry "halt" 1 "permission_denied" 1
}

@test "execute_retry no_retry returns failure" {
    ! execute_retry "no_retry" 1 "unknown" 1
}

@test "execute_retry logs retry attempt" {
    sleep() { :; }
    export -f sleep

    execute_retry "wait_and_retry" 2 "api_error" 5

    [[ -f "$HANK_DIR/.retry_log" ]]
    entry=$(cat "$HANK_DIR/.retry_log")
    echo "$entry" | jq -e '.loop == 5'
    echo "$entry" | jq -e '.attempt == 2'
}

# =============================================================================
# Integration tests
# =============================================================================

@test "full retry workflow: get strategy, check if should retry, execute" {
    local error_category="test_failure"
    local loop_number=1
    local signature="test_sig_123"

    # Step 1: Get strategy
    strategy=$(get_retry_strategy "$error_category")
    [[ "$strategy" == "retry_with_hint" ]]

    # Step 2: Check if should retry
    should_retry "$error_category" 0

    # Step 3: Execute retry
    execute_retry "$strategy" 1 "$error_category" "$loop_number"

    # Step 4: Update state
    update_retry_state "$loop_number" "$signature" "$error_category" "success"

    # Verify state
    state=$(get_retry_state "$loop_number" "$signature")
    attempt_count=$(echo "$state" | jq -r '.attempt_count')
    [[ "$attempt_count" -eq 1 ]]
}

@test "retry exhaustion: after max attempts, should_retry returns false" {
    local error_category="build_error"
    local signature="build_sig_456"

    # Simulate 3 retries
    for attempt in 1 2 3; do
        update_retry_state 1 "$signature" "$error_category" "failure"
    done

    # After 3 attempts, should not retry
    ! should_retry "$error_category" 3
}

@test "halt strategy never retries regardless of attempt count" {
    ! should_retry "permission_denied" 0
    ! should_retry "permission_denied" 1
    ! should_retry "permission_denied" 10
}
