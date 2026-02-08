#!/bin/bash
# Retry Strategy Component for Hank
# Intelligent retry logic based on error classification

# Source date utilities for cross-platform compatibility
source "$(dirname "${BASH_SOURCE[0]}")/date_utils.sh"

# Source audit_log.sh if not already sourced (for audit_event)
if ! declare -f audit_event >/dev/null 2>&1; then
    source "$(dirname "${BASH_SOURCE[0]}")/audit_log.sh"
fi

# Use HANK_DIR if set by main script, otherwise default to .hank
HANK_DIR="${HANK_DIR:-.hank}"

# Retry configuration files
RETRY_LOG_FILE="$HANK_DIR/.retry_log"
RETRY_STATE_FILE="$HANK_DIR/.retry_state"

# Default retry configuration (can be overridden in .hankrc)
RETRY_MAX_ATTEMPTS="${RETRY_MAX_ATTEMPTS:-3}"
RETRY_BACKOFF_INITIAL_SEC="${RETRY_BACKOFF_INITIAL_SEC:-30}"
RETRY_BACKOFF_MAX_SEC="${RETRY_BACKOFF_MAX_SEC:-300}"
RETRY_BACKOFF_MULTIPLIER="${RETRY_BACKOFF_MULTIPLIER:-2}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# get_retry_strategy - Determine retry strategy based on error category
#
# Parameters:
#   $1 (error_category) - Error category from error classification
#
# Returns:
#   Strategy string: wait_and_retry | retry_with_hint | reset_session | halt | no_retry
#
get_retry_strategy() {
    local error_category="$1"

    case "$error_category" in
        rate_limit)
            echo "wait_and_retry"
            ;;
        permission_denied)
            echo "halt"
            ;;
        test_failure)
            echo "retry_with_hint"
            ;;
        build_error)
            echo "retry_with_hint"
            ;;
        dependency_error)
            echo "retry_with_hint"
            ;;
        context_overflow)
            echo "reset_session"
            ;;
        api_error)
            echo "wait_and_retry"
            ;;
        unknown|*)
            echo "no_retry"
            ;;
    esac
}

# get_retry_hint - Get context-specific hint for retry based on error category
#
# Parameters:
#   $1 (error_category) - Error category
#
# Returns:
#   Hint string to pass to Claude
#
get_retry_hint() {
    local error_category="$1"

    case "$error_category" in
        test_failure)
            echo "Focus on fixing the failing test. Review the test output carefully and address the specific assertion that failed."
            ;;
        build_error)
            echo "Check build output carefully. Resolve any compilation errors, type mismatches, or missing imports."
            ;;
        dependency_error)
            echo "Install missing dependency. Check package.json/requirements.txt/Cargo.toml and run the appropriate install command."
            ;;
        *)
            echo ""
            ;;
    esac
}

# calculate_backoff - Calculate exponential backoff wait time
#
# Parameters:
#   $1 (attempt_number) - Current retry attempt (1-indexed)
#
# Returns:
#   Wait time in seconds
#
calculate_backoff() {
    local attempt_number="$1"

    # Exponential backoff: initial * (multiplier ^ (attempt - 1))
    local wait_time=$RETRY_BACKOFF_INITIAL_SEC
    for ((i = 1; i < attempt_number; i++)); do
        wait_time=$((wait_time * RETRY_BACKOFF_MULTIPLIER))
    done

    # Cap at max
    if [[ $wait_time -gt $RETRY_BACKOFF_MAX_SEC ]]; then
        wait_time=$RETRY_BACKOFF_MAX_SEC
    fi

    echo "$wait_time"
}

# should_retry - Determine if we should retry based on attempt count
#
# Parameters:
#   $1 (error_category) - Error category
#   $2 (attempt_count) - Number of attempts so far
#
# Returns:
#   0 - Should retry
#   1 - Should not retry (max attempts exceeded)
#
should_retry() {
    local error_category="$1"
    local attempt_count="${2:-0}"

    # Convert to integer safely
    attempt_count=$((attempt_count + 0))

    # Get strategy to see if retries are allowed
    local strategy=$(get_retry_strategy "$error_category")

    case "$strategy" in
        halt|no_retry)
            return 1  # Never retry
            ;;
        *)
            # Check max attempts
            if [[ $attempt_count -ge $RETRY_MAX_ATTEMPTS ]]; then
                return 1  # Max attempts exceeded
            else
                return 0  # Should retry
            fi
            ;;
    esac
}

# get_retry_state - Get current retry state for loop/error
#
# Parameters:
#   $1 (loop_number) - Current loop number
#   $2 (error_signature) - Error signature from classification
#
# Returns:
#   JSON object with retry state: {attempt_count, last_attempt_timestamp, ...}
#
get_retry_state() {
    local loop_number="$1"
    local error_signature="$2"

    if [[ ! -f "$RETRY_STATE_FILE" ]]; then
        echo '{"attempt_count":0}'
        return 0
    fi

    # Read state for this error signature
    local state=$(jq -r --arg sig "$error_signature" '.errors[$sig] // {attempt_count: 0}' "$RETRY_STATE_FILE" 2>/dev/null)
    if [[ -z "$state" || "$state" == "null" ]]; then
        echo '{"attempt_count":0}'
    else
        echo "$state"
    fi
}

# update_retry_state - Update retry state after an attempt
#
# Parameters:
#   $1 (loop_number) - Current loop number
#   $2 (error_signature) - Error signature
#   $3 (error_category) - Error category
#   $4 (outcome) - success | failure
#
update_retry_state() {
    local loop_number="$1"
    local error_signature="$2"
    local error_category="$3"
    local outcome="$4"

    # Initialize state file if missing
    if [[ ! -f "$RETRY_STATE_FILE" ]]; then
        echo '{"errors":{}}' > "$RETRY_STATE_FILE"
    fi

    # Get current state
    local current_state=$(get_retry_state "$loop_number" "$error_signature")
    local attempt_count=$(echo "$current_state" | jq -r '.attempt_count // 0')
    attempt_count=$((attempt_count + 1))

    # Update state
    local updated_state=$(jq \
        --arg sig "$error_signature" \
        --arg cat "$error_category" \
        --argjson attempts "$attempt_count" \
        --arg ts "$(get_iso_timestamp)" \
        --argjson loop "$loop_number" \
        --arg outcome "$outcome" \
        '.errors[$sig] = {
            category: $cat,
            attempt_count: $attempts,
            last_attempt_timestamp: $ts,
            last_loop: $loop,
            last_outcome: $outcome
        }' "$RETRY_STATE_FILE")

    echo "$updated_state" > "$RETRY_STATE_FILE"
}

# reset_retry_state - Clear retry state (e.g., after successful recovery)
#
reset_retry_state() {
    rm -f "$RETRY_STATE_FILE" 2>/dev/null
    echo '{"errors":{}}' > "$RETRY_STATE_FILE"
}

# log_retry_attempt - Record retry attempt to JSONL log
#
# Parameters:
#   $1 (loop_number) - Current loop
#   $2 (error_category) - Error category
#   $3 (attempt_number) - Attempt number
#   $4 (strategy) - Retry strategy
#   $5 (outcome) - success | failure | pending
#
log_retry_attempt() {
    local loop_number="$1"
    local error_category="$2"
    local attempt_number="$3"
    local strategy="$4"
    local outcome="${5:-pending}"

    # Append to JSONL log
    jq -n -c \
        --arg timestamp "$(get_iso_timestamp)" \
        --argjson loop "$loop_number" \
        --arg category "$error_category" \
        --argjson attempt "$attempt_number" \
        --arg strategy "$strategy" \
        --arg outcome "$outcome" \
        '{
            timestamp: $timestamp,
            loop: $loop,
            error_category: $category,
            attempt: $attempt,
            strategy: $strategy,
            outcome: $outcome
        }' >> "$RETRY_LOG_FILE"

    # Record audit event
    if declare -f audit_event >/dev/null 2>&1; then
        audit_event "retry_triggered" "{\"category\":\"$error_category\",\"attempt\":$attempt_number,\"strategy\":\"$strategy\",\"loop\":$loop_number}"
    fi
}

# execute_retry - Execute retry strategy
#
# Parameters:
#   $1 (strategy) - Retry strategy
#   $2 (attempt_number) - Current attempt number
#   $3 (error_category) - Error category
#   $4 (loop_number) - Current loop number
#
# Returns:
#   0 - Retry executed
#   1 - Cannot retry
#
execute_retry() {
    local strategy="$1"
    local attempt_number="$2"
    local error_category="$3"
    local loop_number="${4:-0}"

    case "$strategy" in
        wait_and_retry)
            local wait_time=$(calculate_backoff "$attempt_number")
            echo -e "${YELLOW}⏳ Retry strategy: Wait and retry (attempt $attempt_number/$RETRY_MAX_ATTEMPTS)${NC}"
            echo -e "${YELLOW}Waiting ${wait_time}s before retry...${NC}"
            sleep "$wait_time"
            log_retry_attempt "$loop_number" "$error_category" "$attempt_number" "$strategy" "pending"
            return 0
            ;;

        retry_with_hint)
            local hint=$(get_retry_hint "$error_category")
            echo -e "${YELLOW}🔄 Retry strategy: Retry with hint (attempt $attempt_number/$RETRY_MAX_ATTEMPTS)${NC}"
            if [[ -n "$hint" ]]; then
                echo -e "${YELLOW}Hint: $hint${NC}"
                # Store hint in temp file for main loop to inject
                echo "$hint" > "$HANK_DIR/.retry_hint"
            fi
            log_retry_attempt "$loop_number" "$error_category" "$attempt_number" "$strategy" "pending"
            return 0
            ;;

        reset_session)
            echo -e "${YELLOW}🔄 Retry strategy: Reset session (clear context overflow)${NC}"
            # Signal to main loop to reset session
            echo "reset_session" > "$HANK_DIR/.retry_action"
            log_retry_attempt "$loop_number" "$error_category" "$attempt_number" "$strategy" "pending"
            return 0
            ;;

        halt)
            echo -e "${RED}🛑 Retry strategy: Halt (manual intervention required)${NC}"
            log_retry_attempt "$loop_number" "$error_category" "$attempt_number" "$strategy" "halt"
            return 1
            ;;

        no_retry)
            echo -e "${YELLOW}⚠️  No retry strategy for error category: $error_category${NC}"
            return 1
            ;;

        *)
            return 1
            ;;
    esac
}

# Export functions
export -f get_retry_strategy
export -f get_retry_hint
export -f calculate_backoff
export -f should_retry
export -f get_retry_state
export -f update_retry_state
export -f reset_retry_state
export -f log_retry_attempt
export -f execute_retry
