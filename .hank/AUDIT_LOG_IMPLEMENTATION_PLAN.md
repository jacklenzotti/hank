# Audit Log Implementation Plan - Issue #12

## Overview

Add a structured audit log that records every significant event during Hank execution, replacing unstructured log output with queryable JSONL events.

---

## 1. Create `lib/audit_log.sh`

### Location

`/Users/jack/code/hank/lib/audit_log.sh`

### Function: `audit_event()`

**Signature:**

```bash
audit_event() {
    local event_type=$1
    local details_json=${2:-"{}"}
}
```

**Implementation Details:**

- Appends JSONL events to `.hank/audit_log.jsonl`
- Generates ISO timestamp using `get_iso_timestamp()` from `date_utils.sh`
- Reads session ID from `$HANK_SESSION_FILE` (`.hank/.hank_session`)
- Reads loop number from global variable or environment
- Uses `jq` to construct JSON safely
- Atomic append using `>>` redirection
- No locking needed (single-writer pattern)

**Event Format:**

```json
{
  "timestamp": "2026-02-07T20:30:00Z",
  "event_type": "loop_complete",
  "session_id": "hank-1707341400-12345",
  "loop_number": 5,
  "details": {
    "files_changed": 3,
    "cost_usd": 0.015,
    "exit_signal": false,
    "issue_number": "123"
  }
}
```

**Event Types:**

- `session_start` - Hank session initialization
- `session_reset` - Session manually reset via --reset-session
- `loop_start` - Beginning of Claude execution loop
- `loop_complete` - End of Claude execution loop
- `error_detected` - Error classification system detected error
- `retry_triggered` - Rate limit or error retry
- `circuit_breaker_state_change` - CB state transition (CLOSED ↔ HALF_OPEN ↔ OPEN)
- `task_sync` - GitHub issues synced to IMPLEMENTATION_PLAN.md
- `issue_closed` - GitHub issue closed by Hank
- `exit_signal` - Exit condition detected

**Helper Functions:**

```bash
# Initialize audit log file
init_audit_log() {
    local audit_file="${HANK_DIR}/audit_log.jsonl"
    if [[ ! -f "$audit_file" ]]; then
        touch "$audit_file"
    fi
}

# Rotate audit log (keep last 10,000 events)
rotate_audit_log() {
    local audit_file="${HANK_DIR}/audit_log.jsonl"
    local line_count
    line_count=$(wc -l < "$audit_file" 2>/dev/null || echo "0")

    if [[ $line_count -gt 10000 ]]; then
        # Archive old logs
        tail -n 10000 "$audit_file" > "${audit_file}.tmp"
        mv "$audit_file" "${audit_file}.1"
        mv "${audit_file}.tmp" "$audit_file"
    fi
}

# Get current session ID from Hank session file
_get_current_session_id() {
    if [[ -f "$HANK_SESSION_FILE" ]]; then
        jq -r '.session_id // ""' "$HANK_SESSION_FILE" 2>/dev/null || echo ""
    else
        echo ""
    fi
}

# Export functions
export -f audit_event
export -f init_audit_log
export -f rotate_audit_log
export -f _get_current_session_id
```

---

## 2. Instrumentation Points

### 2.1 `hank_loop.sh` Instrumentation

**File:** `/Users/jack/code/hank/hank_loop.sh`

#### Location 1: Session Start (Line ~1599)

**Before:**

```bash
loop_count=0

# Main loop
while true; do
```

**Add:**

```bash
# Source audit log library
source "$SCRIPT_DIR/lib/audit_log.sh"
init_audit_log

# Log session start
audit_event "session_start" "$(jq -n \
    --arg mode "$HANK_MODE" \
    --arg source "$HANK_TASK_SOURCE" \
    --argjson dry_run "$HANK_DRY_RUN" \
    --argjson use_teams "$HANK_USE_TEAMS" \
    --argjson max_calls "$MAX_CALLS_PER_HOUR" \
    '{
        mode: $mode,
        source: $source,
        dry_run: $dry_run,
        use_teams: $use_teams,
        max_calls_per_hour: $max_calls
    }')"

loop_count=0
```

#### Location 2: Session Reset (search for `--reset-session` handler)

**Pattern to find:** `grep -n "reset.*session\|RESET.*SESSION" hank_loop.sh`

**Add after session reset logic:**

```bash
audit_event "session_reset" "$(jq -n \
    --arg reason "${1:-manual}" \
    '{reason: $reason}')"
```

#### Location 3: Loop Start (Line ~1688)

**Before:**

```bash
loop_count=$((loop_count + 1))
```

**Add after:**

```bash
# Record loop start SHA for commit tracking
git rev-parse HEAD > "$HANK_DIR/.loop_start_sha" 2>/dev/null || true

# Log loop start
audit_event "loop_start" "$(jq -n \
    --argjson loop "$loop_count" \
    '{loop: $loop}')"
```

#### Location 4: Loop Complete (search for `analyze_response` calls)

**Pattern to find:** `grep -n "analyze_response" hank_loop.sh`

**Add after response analysis:**

```bash
# Extract details from response analysis
if [[ -f "$RESPONSE_ANALYSIS_FILE" ]]; then
    local files_changed=$(jq -r '.analysis.files_modified // 0' "$RESPONSE_ANALYSIS_FILE")
    local cost_usd=$(jq -r '.analysis.cost_usd // 0' "$RESPONSE_ANALYSIS_FILE")
    local exit_signal=$(jq -r '.analysis.exit_signal // false' "$RESPONSE_ANALYSIS_FILE")
    local has_errors=$(jq -r '.analysis.error_count > 0' "$RESPONSE_ANALYSIS_FILE")
    local issue_num=$(extract_issue_number "$(jq -r '.analysis.work_summary // ""' "$RESPONSE_ANALYSIS_FILE")")

    audit_event "loop_complete" "$(jq -n \
        --argjson files_changed "$files_changed" \
        --arg cost_usd "$cost_usd" \
        --argjson exit_signal "$exit_signal" \
        --argjson has_errors "$has_errors" \
        --arg issue_number "${issue_num:-}" \
        '{
            files_changed: $files_changed,
            cost_usd: ($cost_usd | tonumber),
            exit_signal: $exit_signal,
            has_errors: $has_errors,
            issue_number: $issue_number
        }')"
fi
```

#### Location 5: Exit Detection (search for `should_exit_gracefully`)

**Pattern to find:** `grep -n "should_exit_gracefully\|EXIT_REASON" hank_loop.sh`

**Add when exit condition is met:**

```bash
local exit_reason=$(should_exit_gracefully)
if [[ -n "$exit_reason" ]]; then
    audit_event "exit_signal" "$(jq -n \
        --arg reason "$exit_reason" \
        --argjson loop "$loop_count" \
        '{
            reason: $reason,
            loop: $loop
        }')"
    break
fi
```

#### Location 6: Rate Limit Wait (in `wait_for_reset` function, line ~413)

**Add at start of function:**

```bash
audit_event "retry_triggered" "$(jq -n \
    --arg reason "rate_limit" \
    --argjson calls_made "$(cat "$CALL_COUNT_FILE" 2>/dev/null || echo 0)" \
    --argjson max_calls "$MAX_CALLS_PER_HOUR" \
    '{
        reason: $reason,
        calls_made: $calls_made,
        max_calls_per_hour: $max_calls
    }')"
```

### 2.2 `lib/circuit_breaker.sh` Instrumentation

**File:** `/Users/jack/code/hank/lib/circuit_breaker.sh`

#### Location: `log_circuit_transition` function (Line 260)

**Before:**

```bash
log_circuit_transition() {
    local from_state=$1
    local to_state=$2
    local reason=$3
    local loop_number=$4
```

**Add after history logging (after line 276):**

```bash
# Source audit_log.sh if not already sourced
if ! type -t audit_event &>/dev/null; then
    source "$(dirname "${BASH_SOURCE[0]}")/audit_log.sh"
fi

# Log to audit log
audit_event "circuit_breaker_state_change" "$(jq -n \
    --arg from_state "$from_state" \
    --arg to_state "$to_state" \
    --arg reason "$reason" \
    --argjson loop "$loop_number" \
    '{
        from_state: $from_state,
        to_state: $to_state,
        reason: $reason,
        loop: $loop
    }')"
```

### 2.3 `lib/response_analyzer.sh` Instrumentation

**File:** `/Users/jack/code/hank/lib/response_analyzer.sh`

#### Location 1: Error Detection in `extract_and_classify_errors` (Line 1175)

**Add at end of function, after recording errors:**

```bash
# Log to audit if errors detected
if [[ $(echo "$classified_errors" | jq 'length') -gt 0 ]]; then
    # Source audit_log.sh if not already sourced
    if ! type -t audit_event &>/dev/null; then
        source "$(dirname "${BASH_SOURCE[0]}")/audit_log.sh"
    fi

    local error_count=$(echo "$classified_errors" | jq 'length')
    local error_categories=$(echo "$classified_errors" | jq -r '[.[].category] | unique | join(", ")')

    audit_event "error_detected" "$(jq -n \
        --argjson loop "$loop_number" \
        --argjson error_count "$error_count" \
        --arg categories "$error_categories" \
        --argjson errors "$classified_errors" \
        '{
            loop: $loop,
            error_count: $error_count,
            categories: $categories,
            errors: $errors
        }')"
fi
```

### 2.4 `lib/task_sources.sh` Instrumentation

**File:** `/Users/jack/code/hank/lib/task_sources.sh`

#### Location 1: `sync_github_issues` function (Line 576)

**Add at end of successful sync (before return 0):**

```bash
# Source audit_log.sh if not already sourced
if ! type -t audit_event &>/dev/null; then
    source "$(dirname "${BASH_SOURCE[0]}")/audit_log.sh"
fi

# Count issues
local issue_count=$(echo "$issues" | wc -l | tr -d ' ')

audit_event "task_sync" "$(jq -n \
    --arg source "github" \
    --arg label "$label_filter" \
    --argjson count "$issue_count" \
    '{
        source: $source,
        label: $label,
        issue_count: $count
    }')"
```

#### Location 2: `report_to_github` function (Line 632)

**Add when issue is closed (line ~667):**

```bash
COMPLETE)
    # Source audit_log.sh if not already sourced
    if ! type -t audit_event &>/dev/null; then
        source "$(dirname "${BASH_SOURCE[0]}")/audit_log.sh"
    fi

    audit_event "issue_closed" "$(jq -n \
        --arg issue_number "$issue_number" \
        --argjson loop "$loop_count" \
        '{
            issue_number: $issue_number,
            loop: $loop
        }')"

    gh issue close "$issue_number" \
        --comment "Completed by Hank (loop $loop_count)" 2>/dev/null || true
```

### 2.5 `lib/cost_tracker.sh` Instrumentation

**No changes needed** - Cost data is already captured in loop_complete events via response_analysis.

---

## 3. CLI Command: `hank --audit`

### 3.1 Add CLI Flag Parsing

**File:** `/Users/jack/code/hank/hank_loop.sh`

**Location:** Add to argument parsing section (search for `while [[ $# -gt 0 ]]`)

```bash
--audit)
    HANK_SHOW_AUDIT=true
    AUDIT_FILTER_TYPE=""
    AUDIT_FILTER_SESSION=""
    AUDIT_FILTER_SINCE=""
    shift
    ;;
--audit-type)
    AUDIT_FILTER_TYPE="$2"
    shift 2
    ;;
--audit-session)
    AUDIT_FILTER_SESSION="$2"
    shift 2
    ;;
--audit-since)
    AUDIT_FILTER_SINCE="$2"
    shift 2
    ;;
```

### 3.2 Add Audit Display Function

**Add to `lib/audit_log.sh`:**

```bash
# display_audit_log - Show audit events with optional filtering
#
# Parameters:
#   $1 (type_filter) - Filter by event_type (optional)
#   $2 (session_filter) - Filter by session_id (optional)
#   $3 (since_filter) - Filter by time (e.g., "2h", "1d") (optional)
#   $4 (limit) - Max events to show (default: 20)
#
display_audit_log() {
    local type_filter="${1:-}"
    local session_filter="${2:-}"
    local since_filter="${3:-}"
    local limit="${4:-20}"

    local audit_file="${HANK_DIR}/audit_log.jsonl"

    if [[ ! -f "$audit_file" ]]; then
        echo "No audit log found at $audit_file"
        return 0
    fi

    # Build jq filter
    local jq_filter="."

    # Type filter
    if [[ -n "$type_filter" ]]; then
        jq_filter="$jq_filter | select(.event_type == \"$type_filter\")"
    fi

    # Session filter
    if [[ -n "$session_filter" ]]; then
        jq_filter="$jq_filter | select(.session_id == \"$session_filter\")"
    fi

    # Time filter (parse human-readable format like "2h", "1d")
    if [[ -n "$since_filter" ]]; then
        # Parse time units
        local time_value="${since_filter//[^0-9]/}"
        local time_unit="${since_filter//[0-9]/}"
        local seconds=0

        case "$time_unit" in
            h) seconds=$((time_value * 3600)) ;;
            d) seconds=$((time_value * 86400)) ;;
            m) seconds=$((time_value * 60)) ;;
            *) seconds=$time_value ;;
        esac

        # Calculate cutoff timestamp
        local cutoff_ts
        cutoff_ts=$(date -u -d "@$(($(date +%s) - seconds))" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || \
                    date -u -v-${seconds}S +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null)

        if [[ -n "$cutoff_ts" ]]; then
            jq_filter="$jq_filter | select(.timestamp >= \"$cutoff_ts\")"
        fi
    fi

    # Apply filters and format output
    echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║           Audit Log                                       ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"

    if [[ -n "$type_filter" ]]; then
        echo -e "${YELLOW}Filter by type:${NC} $type_filter"
    fi
    if [[ -n "$session_filter" ]]; then
        echo -e "${YELLOW}Filter by session:${NC} ${session_filter:0:20}..."
    fi
    if [[ -n "$since_filter" ]]; then
        echo -e "${YELLOW}Filter by time:${NC} last $since_filter"
    fi
    echo ""

    # Display events (reverse chronological, limited)
    jq -r "$jq_filter |
        \"[\(.timestamp)] \(.event_type) (loop \(.loop_number // 0)) - \(.details | tostring)\"" \
        "$audit_file" 2>/dev/null | tail -n "$limit" | tac

    echo ""
    echo -e "${BLUE}Showing last $limit events${NC}"
    echo -e "${BLUE}Log file:${NC} $audit_file"
}

export -f display_audit_log
```

### 3.3 Add Audit Command Handler

**File:** `/Users/jack/code/hank/hank_loop.sh`

**Location:** Add before main loop starts (after argument parsing)

```bash
# Handle --audit flag
if [[ "$HANK_SHOW_AUDIT" == "true" ]]; then
    source "$SCRIPT_DIR/lib/audit_log.sh"
    display_audit_log "$AUDIT_FILTER_TYPE" "$AUDIT_FILTER_SESSION" "$AUDIT_FILTER_SINCE" 20
    exit 0
fi
```

---

## 4. Log Rotation

### 4.1 Rotation Strategy

**File:** `lib/audit_log.sh`

**Function:** `rotate_audit_log()` (see implementation in section 1)

**Trigger Points:**

1. On session start (in `hank_loop.sh` session initialization)
2. Periodic check every 100 loops

### 4.2 Rotation Implementation

**Add to `hank_loop.sh` main loop:**

```bash
# Rotate audit log every 100 loops
if [[ $((loop_count % 100)) -eq 0 ]]; then
    rotate_audit_log
fi
```

---

## 5. Testing

### 5.1 Create `tests/unit/test_audit_log.bats`

**File:** `/Users/jack/code/hank/tests/unit/test_audit_log.bats`

```bash
#!/usr/bin/env bats

load '../test_helper'

setup() {
    # Create temporary test directory
    TEST_DIR=$(mktemp -d)
    cd "$TEST_DIR"

    # Initialize .hank directory
    HANK_DIR=".hank"
    mkdir -p "$HANK_DIR"

    # Source audit_log.sh
    source "$BATS_TEST_DIRNAME/../../lib/audit_log.sh"
    source "$BATS_TEST_DIRNAME/../../lib/date_utils.sh"

    # Initialize audit log
    init_audit_log
}

teardown() {
    rm -rf "$TEST_DIR"
}

@test "audit_event writes JSONL event" {
    audit_event "test_event" '{"key": "value"}'

    [ -f "$HANK_DIR/audit_log.jsonl" ]

    # Verify JSON structure
    jq -e '.event_type == "test_event"' "$HANK_DIR/audit_log.jsonl"
    jq -e '.details.key == "value"' "$HANK_DIR/audit_log.jsonl"
}

@test "audit_event includes timestamp" {
    audit_event "test_event" '{}'

    # Verify timestamp exists and is valid ISO format
    jq -e '.timestamp | test("[0-9]{4}-[0-9]{2}-[0-9]{2}T")' "$HANK_DIR/audit_log.jsonl"
}

@test "audit_event includes loop_number" {
    loop_count=5
    audit_event "test_event" '{}'

    jq -e '.loop_number == 5' "$HANK_DIR/audit_log.jsonl"
}

@test "rotate_audit_log keeps last 10000 events" {
    # Create 10500 events
    for i in {1..10500}; do
        echo '{"timestamp":"2026-01-01T00:00:00Z","event_type":"test","loop_number":1,"details":{}}' >> "$HANK_DIR/audit_log.jsonl"
    done

    rotate_audit_log

    local count
    count=$(wc -l < "$HANK_DIR/audit_log.jsonl")
    [ "$count" -eq 10000 ]

    # Verify archive exists
    [ -f "$HANK_DIR/audit_log.jsonl.1" ]
}

@test "display_audit_log filters by type" {
    audit_event "session_start" '{}'
    audit_event "loop_complete" '{}'
    audit_event "session_start" '{}'

    run display_audit_log "session_start" "" "" 10

    # Output should only contain session_start events
    [[ "$output" == *"session_start"* ]]
    [[ "$output" != *"loop_complete"* ]]
}

@test "display_audit_log shows last N events" {
    # Create 50 events
    for i in {1..50}; do
        audit_event "test_event_$i" '{}'
    done

    run display_audit_log "" "" "" 20

    # Should show exactly 20 events
    local event_count
    event_count=$(echo "$output" | grep -c "test_event" || true)
    [ "$event_count" -eq 20 ]
}
```

### 5.2 Integration Tests

**Add to `tests/integration/test_loop_execution.bats`:**

```bash
@test "loop execution creates audit events" {
    # Run single loop (mocked)
    # Verify audit_log.jsonl contains:
    # - session_start
    # - loop_start
    # - loop_complete

    run grep -c '"event_type":"session_start"' .hank/audit_log.jsonl
    [ "$output" -eq 1 ]

    run grep -c '"event_type":"loop_start"' .hank/audit_log.jsonl
    [ "$output" -ge 1 ]
}
```

---

## 6. Documentation Updates

### 6.1 Update `CLAUDE.md`

**Add section:**

````markdown
## Audit Log

Hank records all significant events to a structured JSONL audit log at `.hank/audit_log.jsonl`.

### Event Types

- `session_start` - Hank session initialization
- `session_reset` - Session manually reset
- `loop_start` - Beginning of Claude execution loop
- `loop_complete` - End of Claude execution loop
- `error_detected` - Error classification system detected error
- `retry_triggered` - Rate limit or error retry
- `circuit_breaker_state_change` - Circuit breaker state transition
- `task_sync` - GitHub issues synced
- `issue_closed` - GitHub issue closed by Hank
- `exit_signal` - Exit condition detected

### Viewing Audit Events

```bash
# Show last 20 events
hank --audit

# Filter by event type
hank --audit --type loop_complete

# Filter by session ID
hank --audit --session <session-id>

# Filter by time (last 2 hours)
hank --audit --since 2h

# Combine filters
hank --audit --type error_detected --since 1d
```
````

### Log Rotation

The audit log automatically rotates when it exceeds 10,000 events. Old events are archived to `audit_log.jsonl.1`.

````

### 6.2 Update README.md

**Add to CLI commands table:**

```markdown
| `hank --audit` | Show audit log (last 20 events) |
| `hank --audit --type <type>` | Filter by event type |
| `hank --audit --session <id>` | Filter by session ID |
| `hank --audit --since <time>` | Filter by time (e.g., "2h", "1d") |
````

---

## 7. Acceptance Criteria Checklist

- [ ] All significant events recorded to `audit_log.jsonl`
- [ ] Events are structured JSON with consistent schema
- [ ] `hank --audit` displays events with filtering options
- [ ] Log rotation keeps file size manageable (10,000 events)
- [ ] Audit logging does not impact loop performance
- [ ] BATS tests verify event recording and querying
- [ ] Documentation updated in CLAUDE.md and README.md

---

## 8. Implementation Order

1. **Phase 1: Core Infrastructure** (1-2 hours)

   - Create `lib/audit_log.sh` with core functions
   - Add `audit_event()`, `init_audit_log()`, `rotate_audit_log()`
   - Write unit tests for core functions

2. **Phase 2: Instrumentation** (2-3 hours)

   - Add audit calls to `hank_loop.sh` (session, loop events)
   - Add audit calls to `lib/circuit_breaker.sh` (state changes)
   - Add audit calls to `lib/response_analyzer.sh` (errors)
   - Add audit calls to `lib/task_sources.sh` (GitHub sync)

3. **Phase 3: CLI Command** (1-2 hours)

   - Add `--audit` flag parsing
   - Implement `display_audit_log()` with filtering
   - Add time-based filtering logic

4. **Phase 4: Testing** (2-3 hours)

   - Write comprehensive unit tests
   - Add integration tests
   - Verify all event types are recorded

5. **Phase 5: Documentation** (1 hour)
   - Update CLAUDE.md
   - Update README.md
   - Add inline code comments

**Total Estimated Time:** 7-11 hours

---

## 9. Performance Considerations

### Impact Analysis

- **Append overhead:** Minimal (<1ms per event, JSONL append)
- **jq processing:** ~5-10ms per event construction
- **Disk I/O:** Sequential writes, no blocking
- **Memory:** Zero retention (immediate flush to disk)

### Optimization Strategies

- Use `jq -c` (compact) for JSONL output
- Avoid reading entire log file in hot path
- Batch rotation checks (every 100 loops)
- No synchronous locking (single writer)

### Expected Impact

**Total loop overhead:** <15ms per loop (negligible compared to Claude API calls ~10-60s)

---

## 10. Files Modified/Created

### New Files

- `/Users/jack/code/hank/lib/audit_log.sh`
- `/Users/jack/code/hank/tests/unit/test_audit_log.bats`
- `/Users/jack/code/hank/.hank/AUDIT_LOG_IMPLEMENTATION_PLAN.md` (this file)

### Modified Files

- `/Users/jack/code/hank/hank_loop.sh` (8 instrumentation points)
- `/Users/jack/code/hank/lib/circuit_breaker.sh` (1 instrumentation point)
- `/Users/jack/code/hank/lib/response_analyzer.sh` (1 instrumentation point)
- `/Users/jack/code/hank/lib/task_sources.sh` (2 instrumentation points)
- `/Users/jack/code/hank/CLAUDE.md` (documentation)
- `/Users/jack/code/hank/README.md` (documentation)
- `/Users/jack/code/hank/tests/integration/test_loop_execution.bats` (integration tests)

### Runtime Files (Generated)

- `.hank/audit_log.jsonl` (primary log)
- `.hank/audit_log.jsonl.1` (rotated archive)

---

## 11. Example Usage Scenarios

### Scenario 1: Debugging Stuck Loop

```bash
# Check last 50 events
hank --audit --since 1h | tail -50

# Look for errors
hank --audit --type error_detected --since 1h

# Check circuit breaker activity
hank --audit --type circuit_breaker_state_change
```

### Scenario 2: Cost Analysis

```bash
# Get all loop_complete events with cost data
jq 'select(.event_type == "loop_complete") | {loop: .loop_number, cost: .details.cost_usd}' \
    .hank/audit_log.jsonl
```

### Scenario 3: Session Replay

```bash
# Get session ID from last session_start
SESSION_ID=$(jq -r 'select(.event_type == "session_start") | .session_id' \
    .hank/audit_log.jsonl | tail -1)

# Replay all events from that session
hank --audit --session "$SESSION_ID"
```

---

## 12. Future Enhancements (Out of Scope)

- JSON output format for `--audit` (machine-readable)
- Event streaming webhook support
- Grafana/Prometheus metrics export
- Audit event compression (gzip archives)
- Distributed tracing integration (OpenTelemetry)
- Real-time event filtering CLI (interactive mode)
