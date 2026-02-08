#!/bin/bash
# Audit Log Component for Hank
# Structured JSONL event logging for session tracking and analysis

# Source date utilities for cross-platform compatibility
source "$(dirname "${BASH_SOURCE[0]}")/date_utils.sh"

# Use HANK_DIR if set by main script, otherwise default to .hank
HANK_DIR="${HANK_DIR:-.hank}"

# Audit log file locations
AUDIT_LOG_FILE="$HANK_DIR/audit_log.jsonl"
AUDIT_LOG_ARCHIVE="$HANK_DIR/audit_log.jsonl.1"

# Maximum number of events to keep in the active log
MAX_AUDIT_EVENTS=10000

# Colors for output
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m'

# =============================================================================
# AUDIT LOG INITIALIZATION
# =============================================================================

# Initialize audit log file
# Creates the log file if it doesn't exist
init_audit_log() {
    # Ensure .hank directory exists
    mkdir -p "$HANK_DIR"

    # Create log file if it doesn't exist
    if [[ ! -f "$AUDIT_LOG_FILE" ]]; then
        touch "$AUDIT_LOG_FILE"
    fi

    return 0
}

# =============================================================================
# AUDIT EVENT RECORDING
# =============================================================================

# Record an audit event
# Args: $1 = event_type, $2 = details_json (optional)
# Event types:
#   - session_start: Hank session begins
#   - session_reset: Session manually reset
#   - loop_start: Loop iteration begins
#   - loop_complete: Loop iteration completes
#   - error_detected: Error classified during analysis
#   - retry_triggered: Retry strategy invoked
#   - circuit_breaker_state_change: Circuit breaker state transition
#   - task_sync: GitHub issues synced
#   - issue_closed: GitHub issue completed
#   - exit_signal: Exit condition triggered
audit_event() {
    local event_type=$1
    local details_json=${2:-"{}"}

    # Validate event_type
    if [[ -z "$event_type" ]]; then
        echo "ERROR: audit_event requires event_type" >&2
        return 1
    fi

    # Initialize log if needed
    init_audit_log

    # Get current session ID and loop number from state files
    local session_id=""
    local loop_number=0

    if [[ -f "$HANK_DIR/.claude_session_id" ]]; then
        session_id=$(jq -r '.session_id // ""' "$HANK_DIR/.claude_session_id" 2>/dev/null || echo "")
    fi

    if [[ -f "$HANK_DIR/.loop_number" ]]; then
        loop_number=$(cat "$HANK_DIR/.loop_number" 2>/dev/null || echo "0")
    fi

    # Validate details_json is valid JSON (use jq to validate)
    if ! echo "$details_json" | jq empty 2>/dev/null; then
        echo "ERROR: audit_event details_json is not valid JSON" >&2
        return 1
    fi

    # Build event using jq for safe JSON construction
    local event
    event=$(jq -n \
        --arg timestamp "$(get_iso_timestamp)" \
        --arg event_type "$event_type" \
        --arg session_id "$session_id" \
        --argjson loop_number "$loop_number" \
        --argjson details "$details_json" \
        '{
            timestamp: $timestamp,
            event_type: $event_type,
            session_id: $session_id,
            loop_number: $loop_number,
            details: $details
        }')

    # Append event to log (compact JSONL format)
    echo "$event" | jq -c '.' >> "$AUDIT_LOG_FILE"

    return 0
}

# =============================================================================
# LOG ROTATION
# =============================================================================

# Rotate audit log when it exceeds MAX_AUDIT_EVENTS
# Keeps the most recent MAX_AUDIT_EVENTS in the active log
# Archives older events to audit_log.jsonl.1
rotate_audit_log() {
    if [[ ! -f "$AUDIT_LOG_FILE" ]]; then
        return 0
    fi

    # Count events in log
    local event_count=$(wc -l < "$AUDIT_LOG_FILE" 2>/dev/null || echo "0")
    event_count=$((event_count + 0))

    # Check if rotation is needed
    if [[ $event_count -le $MAX_AUDIT_EVENTS ]]; then
        return 0
    fi

    # Archive old events (move current archive to backup)
    if [[ -f "$AUDIT_LOG_ARCHIVE" ]]; then
        rm -f "$AUDIT_LOG_ARCHIVE"
    fi

    # Keep last MAX_AUDIT_EVENTS in active log, archive the rest
    local temp_file=$(mktemp)
    tail -n "$MAX_AUDIT_EVENTS" "$AUDIT_LOG_FILE" > "$temp_file"

    # Archive older events
    head -n "$((event_count - MAX_AUDIT_EVENTS))" "$AUDIT_LOG_FILE" > "$AUDIT_LOG_ARCHIVE"

    # Replace active log with rotated version
    mv "$temp_file" "$AUDIT_LOG_FILE"

    return 0
}

# Check if rotation is needed and rotate
# This is called periodically during session execution
check_and_rotate() {
    rotate_audit_log
}

# =============================================================================
# AUDIT LOG QUERYING
# =============================================================================

# Display audit log with optional filtering
# Args: $1 = options array (filter_type, filter_session, filter_since, limit)
# Flags:
#   --type <event_type>: Filter by event type
#   --session <session_id>: Filter by session ID
#   --since <time_spec>: Filter by time (e.g., "2h", "1d", "30m")
#   --limit <n>: Limit to n most recent events (default: 20)
display_audit_log() {
    if [[ ! -f "$AUDIT_LOG_FILE" ]]; then
        echo -e "${YELLOW}No audit log found${NC}"
        return 0
    fi

    local filter_type=""
    local filter_session=""
    local filter_since=""
    local limit=20

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --type)
                filter_type="$2"
                shift 2
                ;;
            --session)
                filter_session="$2"
                shift 2
                ;;
            --since)
                filter_since="$2"
                shift 2
                ;;
            --limit)
                limit="$2"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done

    # Build jq filter
    local jq_filter="."

    # Filter by event type
    if [[ -n "$filter_type" ]]; then
        jq_filter="$jq_filter | select(.event_type == \"$filter_type\")"
    fi

    # Filter by session ID
    if [[ -n "$filter_session" ]]; then
        jq_filter="$jq_filter | select(.session_id == \"$filter_session\")"
    fi

    # Filter by time (if --since provided)
    if [[ -n "$filter_since" ]]; then
        local cutoff_timestamp=$(parse_relative_time "$filter_since")
        if [[ -n "$cutoff_timestamp" ]]; then
            jq_filter="$jq_filter | select(.timestamp >= \"$cutoff_timestamp\")"
        fi
    fi

    # Apply filters and limit
    local filtered_events
    filtered_events=$(cat "$AUDIT_LOG_FILE" | jq -c "$jq_filter" 2>/dev/null | tail -n "$limit")

    # Count results
    local event_count=$(echo "$filtered_events" | grep -c . || echo "0")

    if [[ "$event_count" -eq 0 ]]; then
        echo -e "${YELLOW}No events match the filter criteria${NC}"
        return 0
    fi

    # Display header
    echo -e "${BLUE}=== Audit Log (${event_count} events) ===${NC}"
    echo ""

    # Display events in human-readable format
    echo "$filtered_events" | while IFS= read -r event; do
        if [[ -z "$event" ]]; then
            continue
        fi

        local timestamp=$(echo "$event" | jq -r '.timestamp')
        local event_type=$(echo "$event" | jq -r '.event_type')
        local session_id=$(echo "$event" | jq -r '.session_id // "N/A"')
        local loop_number=$(echo "$event" | jq -r '.loop_number // 0')
        local details=$(echo "$event" | jq -c '.details')

        echo -e "${GREEN}[$timestamp]${NC} ${YELLOW}$event_type${NC}"
        echo "  Session: $session_id | Loop: $loop_number"

        # Pretty-print details if not empty
        if [[ "$details" != "{}" && "$details" != "null" ]]; then
            echo "  Details: $(echo "$details" | jq -c '.')"
        fi
        echo ""
    done

    return 0
}

# Parse relative time specification to ISO timestamp
# Args: $1 = time spec (e.g., "2h", "1d", "30m")
# Returns: ISO timestamp string
parse_relative_time() {
    local time_spec=$1

    # Extract number and unit
    local number=$(echo "$time_spec" | grep -oE '^[0-9]+')
    local unit=$(echo "$time_spec" | grep -oE '[a-z]+$')

    if [[ -z "$number" || -z "$unit" ]]; then
        echo ""
        return 1
    fi

    # Convert to seconds
    local seconds=0
    case "$unit" in
        m|min|minutes)
            seconds=$((number * 60))
            ;;
        h|hour|hours)
            seconds=$((number * 3600))
            ;;
        d|day|days)
            seconds=$((number * 86400))
            ;;
        *)
            echo ""
            return 1
            ;;
    esac

    # Calculate cutoff timestamp
    local now=$(get_epoch_seconds)
    local cutoff=$((now - seconds))

    # Convert back to ISO format
    if command -v gdate &>/dev/null; then
        # macOS with coreutils
        gdate -u -d "@$cutoff" +"%Y-%m-%dT%H:%M:%SZ"
    elif date --version 2>&1 | grep -q GNU; then
        # GNU date (Linux)
        date -u -d "@$cutoff" +"%Y-%m-%dT%H:%M:%SZ"
    else
        # BSD date (macOS without coreutils)
        date -u -r "$cutoff" +"%Y-%m-%dT%H:%M:%SZ"
    fi

    return 0
}

# Export functions for use in other scripts
export -f init_audit_log
export -f audit_event
export -f rotate_audit_log
export -f check_and_rotate
export -f display_audit_log
export -f parse_relative_time
