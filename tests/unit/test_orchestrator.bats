#!/usr/bin/env bats
# Tests for lib/orchestrator.sh

setup() {
    # Use a temp directory for test files
    export HANK_DIR=$(mktemp -d)
    export BATS_TEST_DIRNAME_ABS="$BATS_TEST_DIRNAME"

    # Create test repo directories
    export TEST_REPOS_DIR=$(mktemp -d)
    mkdir -p "$TEST_REPOS_DIR/repo-a"
    mkdir -p "$TEST_REPOS_DIR/repo-b"
    mkdir -p "$TEST_REPOS_DIR/repo-c"

    # Source the library under test
    source "$BATS_TEST_DIRNAME/../../lib/orchestrator.sh"
}

teardown() {
    # Clean up temp directories
    rm -rf "$HANK_DIR"
    rm -rf "$TEST_REPOS_DIR"
}

# =============================================================================
# load_repo_config tests
# =============================================================================

@test "load_repo_config validates JSON format" {
    echo "not valid json" > "$HANK_DIR/.repos.json"

    ! load_repo_config "$HANK_DIR/.repos.json"
}

@test "load_repo_config requires array format" {
    echo '{"repos": []}' > "$HANK_DIR/.repos.json"

    ! load_repo_config "$HANK_DIR/.repos.json"
}

@test "load_repo_config validates required fields" {
    cat > "$HANK_DIR/.repos.json" << 'EOF'
[
    {"name": "test", "path": "/tmp"}
]
EOF

    ! load_repo_config "$HANK_DIR/.repos.json"
}

@test "load_repo_config succeeds with valid config" {
    cat > "$HANK_DIR/.repos.json" << EOF
[
    {"name": "repo-a", "path": "$TEST_REPOS_DIR/repo-a", "deps": [], "priority": 1}
]
EOF

    load_repo_config "$HANK_DIR/.repos.json"
}

@test "load_repo_config validates paths exist" {
    cat > "$HANK_DIR/.repos.json" << 'EOF'
[
    {"name": "missing", "path": "/nonexistent/path", "deps": [], "priority": 1}
]
EOF

    ! load_repo_config "$HANK_DIR/.repos.json"
}

@test "load_repo_config returns error for missing file" {
    ! load_repo_config "$HANK_DIR/missing.json"
}

# =============================================================================
# detect_circular_dependencies tests
# =============================================================================

@test "detect_circular_dependencies detects simple cycle" {
    cat > "$HANK_DIR/.repos.json" << EOF
[
    {"name": "a", "path": "$TEST_REPOS_DIR/repo-a", "deps": ["b"]},
    {"name": "b", "path": "$TEST_REPOS_DIR/repo-b", "deps": ["a"]}
]
EOF

    ! detect_circular_dependencies "$HANK_DIR/.repos.json"
}

@test "detect_circular_dependencies detects three-way cycle" {
    cat > "$HANK_DIR/.repos.json" << EOF
[
    {"name": "a", "path": "$TEST_REPOS_DIR/repo-a", "deps": ["b"]},
    {"name": "b", "path": "$TEST_REPOS_DIR/repo-b", "deps": ["c"]},
    {"name": "c", "path": "$TEST_REPOS_DIR/repo-c", "deps": ["a"]}
]
EOF

    ! detect_circular_dependencies "$HANK_DIR/.repos.json"
}

@test "detect_circular_dependencies passes with no cycles" {
    cat > "$HANK_DIR/.repos.json" << EOF
[
    {"name": "a", "path": "$TEST_REPOS_DIR/repo-a", "deps": []},
    {"name": "b", "path": "$TEST_REPOS_DIR/repo-b", "deps": ["a"]},
    {"name": "c", "path": "$TEST_REPOS_DIR/repo-c", "deps": ["b"]}
]
EOF

    detect_circular_dependencies "$HANK_DIR/.repos.json"
}

@test "detect_circular_dependencies handles self-dependency" {
    cat > "$HANK_DIR/.repos.json" << EOF
[
    {"name": "a", "path": "$TEST_REPOS_DIR/repo-a", "deps": ["a"]}
]
EOF

    ! detect_circular_dependencies "$HANK_DIR/.repos.json"
}

@test "detect_circular_dependencies handles complex DAG" {
    cat > "$HANK_DIR/.repos.json" << EOF
[
    {"name": "a", "path": "$TEST_REPOS_DIR/repo-a", "deps": []},
    {"name": "b", "path": "$TEST_REPOS_DIR/repo-b", "deps": ["a"]},
    {"name": "c", "path": "$TEST_REPOS_DIR/repo-c", "deps": ["a"]},
    {"name": "d", "path": "$TEST_REPOS_DIR/repo-a", "deps": ["b", "c"]}
]
EOF

    detect_circular_dependencies "$HANK_DIR/.repos.json"
}

# =============================================================================
# resolve_execution_order tests
# =============================================================================

@test "resolve_execution_order handles linear chain" {
    cat > "$HANK_DIR/.repos.json" << EOF
[
    {"name": "c", "path": "$TEST_REPOS_DIR/repo-c", "deps": ["b"]},
    {"name": "b", "path": "$TEST_REPOS_DIR/repo-b", "deps": ["a"]},
    {"name": "a", "path": "$TEST_REPOS_DIR/repo-a", "deps": []}
]
EOF

    result=$(resolve_execution_order "$HANK_DIR/.repos.json")
    [[ "$result" == "a b c" ]]
}

@test "resolve_execution_order handles no dependencies" {
    cat > "$HANK_DIR/.repos.json" << EOF
[
    {"name": "a", "path": "$TEST_REPOS_DIR/repo-a", "deps": []},
    {"name": "b", "path": "$TEST_REPOS_DIR/repo-b", "deps": []},
    {"name": "c", "path": "$TEST_REPOS_DIR/repo-c", "deps": []}
]
EOF

    result=$(resolve_execution_order "$HANK_DIR/.repos.json")
    # All should be present in some order
    [[ "$result" =~ a ]]
    [[ "$result" =~ b ]]
    [[ "$result" =~ c ]]
}

@test "resolve_execution_order handles diamond dependency" {
    cat > "$HANK_DIR/.repos.json" << EOF
[
    {"name": "d", "path": "$TEST_REPOS_DIR/repo-a", "deps": ["b", "c"]},
    {"name": "b", "path": "$TEST_REPOS_DIR/repo-b", "deps": ["a"]},
    {"name": "c", "path": "$TEST_REPOS_DIR/repo-c", "deps": ["a"]},
    {"name": "a", "path": "$TEST_REPOS_DIR/repo-a", "deps": []}
]
EOF

    result=$(resolve_execution_order "$HANK_DIR/.repos.json")

    # a must come before b and c
    a_pos=$(echo "$result" | tr ' ' '\n' | grep -n '^a$' | cut -d: -f1)
    b_pos=$(echo "$result" | tr ' ' '\n' | grep -n '^b$' | cut -d: -f1)
    c_pos=$(echo "$result" | tr ' ' '\n' | grep -n '^c$' | cut -d: -f1)
    d_pos=$(echo "$result" | tr ' ' '\n' | grep -n '^d$' | cut -d: -f1)

    [[ $a_pos -lt $b_pos ]]
    [[ $a_pos -lt $c_pos ]]
    [[ $b_pos -lt $d_pos ]]
    [[ $c_pos -lt $d_pos ]]
}

@test "resolve_execution_order handles single repo" {
    cat > "$HANK_DIR/.repos.json" << EOF
[
    {"name": "only", "path": "$TEST_REPOS_DIR/repo-a", "deps": []}
]
EOF

    result=$(resolve_execution_order "$HANK_DIR/.repos.json")
    [[ "$result" == "only" ]]
}

# =============================================================================
# init_orchestration_state tests
# =============================================================================

@test "init_orchestration_state creates state file" {
    cat > "$HANK_DIR/.repos.json" << EOF
[
    {"name": "a", "path": "$TEST_REPOS_DIR/repo-a", "deps": []}
]
EOF

    init_orchestration_state "$HANK_DIR/.repos.json"

    [[ -f "$HANK_DIR/.orchestration_state" ]]
}

@test "init_orchestration_state creates valid JSON" {
    cat > "$HANK_DIR/.repos.json" << EOF
[
    {"name": "a", "path": "$TEST_REPOS_DIR/repo-a", "deps": []}
]
EOF

    init_orchestration_state "$HANK_DIR/.repos.json"

    jq -e '.' "$HANK_DIR/.orchestration_state" > /dev/null
}

@test "init_orchestration_state initializes all repos as pending" {
    cat > "$HANK_DIR/.repos.json" << EOF
[
    {"name": "a", "path": "$TEST_REPOS_DIR/repo-a", "deps": []},
    {"name": "b", "path": "$TEST_REPOS_DIR/repo-b", "deps": []}
]
EOF

    init_orchestration_state "$HANK_DIR/.repos.json"

    status_a=$(jq -r '.repos.a.status' "$HANK_DIR/.orchestration_state")
    status_b=$(jq -r '.repos.b.status' "$HANK_DIR/.orchestration_state")

    [[ "$status_a" == "pending" ]]
    [[ "$status_b" == "pending" ]]
}

@test "init_orchestration_state sets active flag" {
    cat > "$HANK_DIR/.repos.json" << EOF
[
    {"name": "a", "path": "$TEST_REPOS_DIR/repo-a", "deps": []}
]
EOF

    init_orchestration_state "$HANK_DIR/.repos.json"

    active=$(jq -r '.active' "$HANK_DIR/.orchestration_state")
    [[ "$active" == "true" ]]
}

# =============================================================================
# get_next_repo tests
# =============================================================================

@test "get_next_repo returns first pending repo" {
    cat > "$HANK_DIR/.orchestration_state" << 'EOF'
{
    "active": true,
    "repos": {
        "a": {"status": "pending", "blocked_by": []},
        "b": {"status": "pending", "blocked_by": []}
    }
}
EOF

    result=$(get_next_repo)
    [[ "$result" == "a" ]]
}

@test "get_next_repo skips completed repos" {
    cat > "$HANK_DIR/.orchestration_state" << 'EOF'
{
    "active": true,
    "repos": {
        "a": {"status": "completed", "blocked_by": []},
        "b": {"status": "pending", "blocked_by": []}
    }
}
EOF

    result=$(get_next_repo)
    [[ "$result" == "b" ]]
}

@test "get_next_repo skips blocked repos" {
    cat > "$HANK_DIR/.orchestration_state" << 'EOF'
{
    "active": true,
    "repos": {
        "a": {"status": "pending", "blocked_by": ["c"]},
        "b": {"status": "pending", "blocked_by": []}
    }
}
EOF

    result=$(get_next_repo)
    [[ "$result" == "b" ]]
}

@test "get_next_repo returns empty when all complete" {
    cat > "$HANK_DIR/.orchestration_state" << 'EOF'
{
    "active": true,
    "repos": {
        "a": {"status": "completed", "blocked_by": []},
        "b": {"status": "completed", "blocked_by": []}
    }
}
EOF

    result=$(get_next_repo)
    [[ -z "$result" ]]
}

@test "get_next_repo respects priority" {
    cat > "$HANK_DIR/.orchestration_state" << 'EOF'
{
    "active": true,
    "repos": {
        "a": {"status": "pending", "blocked_by": [], "priority": 2},
        "b": {"status": "pending", "blocked_by": [], "priority": 1}
    }
}
EOF

    result=$(get_next_repo)
    [[ "$result" == "b" ]]
}

# =============================================================================
# is_repo_blocked tests
# =============================================================================

@test "is_repo_blocked returns false when not blocked" {
    cat > "$HANK_DIR/.orchestration_state" << 'EOF'
{
    "repos": {
        "a": {"blocked_by": []}
    }
}
EOF

    ! is_repo_blocked "a"
}

@test "is_repo_blocked returns true when blocked" {
    cat > "$HANK_DIR/.orchestration_state" << 'EOF'
{
    "repos": {
        "a": {"blocked_by": ["b", "c"]}
    }
}
EOF

    is_repo_blocked "a"
}

# =============================================================================
# mark_repo_complete tests
# =============================================================================

@test "mark_repo_complete updates status" {
    cat > "$HANK_DIR/.orchestration_state" << 'EOF'
{
    "repos": {
        "a": {"status": "in_progress", "loops": 0, "cost_usd": 0, "blocked_by": []}
    },
    "completed_repos": [],
    "total_cost_usd": 0
}
EOF

    mark_repo_complete "a" 5 0.25

    status=$(jq -r '.repos.a.status' "$HANK_DIR/.orchestration_state")
    [[ "$status" == "completed" ]]
}

@test "mark_repo_complete records loops and cost" {
    cat > "$HANK_DIR/.orchestration_state" << 'EOF'
{
    "repos": {
        "a": {"status": "in_progress", "loops": 0, "cost_usd": 0, "blocked_by": []}
    },
    "completed_repos": [],
    "total_cost_usd": 0
}
EOF

    mark_repo_complete "a" 3 0.15

    loops=$(jq -r '.repos.a.loops' "$HANK_DIR/.orchestration_state")
    cost=$(jq -r '.repos.a.cost_usd' "$HANK_DIR/.orchestration_state")

    [[ "$loops" -eq 3 ]]
    [[ "$cost" == "0.15" ]]
}

@test "mark_repo_complete unblocks dependent repos" {
    cat > "$HANK_DIR/.orchestration_state" << 'EOF'
{
    "repos": {
        "a": {"status": "in_progress", "blocked_by": []},
        "b": {"status": "pending", "blocked_by": ["a"]},
        "c": {"status": "pending", "blocked_by": ["a", "d"]}
    },
    "completed_repos": [],
    "total_cost_usd": 0
}
EOF

    mark_repo_complete "a" 1 0.05

    # b should be unblocked
    b_blocked=$(jq -r '.repos.b.blocked_by | length' "$HANK_DIR/.orchestration_state")
    [[ "$b_blocked" -eq 0 ]]

    # c should still be blocked by d
    c_blocked=$(jq -r '.repos.c.blocked_by | length' "$HANK_DIR/.orchestration_state")
    [[ "$c_blocked" -eq 1 ]]
}

@test "mark_repo_complete updates total cost" {
    cat > "$HANK_DIR/.orchestration_state" << 'EOF'
{
    "repos": {
        "a": {"status": "in_progress", "cost_usd": 0, "blocked_by": []},
        "b": {"status": "completed", "cost_usd": 0.10, "blocked_by": []}
    },
    "completed_repos": ["b"],
    "total_cost_usd": 0.10
}
EOF

    mark_repo_complete "a" 2 0.20

    total=$(jq -r '.total_cost_usd' "$HANK_DIR/.orchestration_state")
    # Should be 0.10 + 0.20 = 0.30 (check with awk for float comparison)
    result=$(awk "BEGIN {printf \"%d\", ($total >= 0.29 && $total <= 0.31)}")
    [[ "$result" -eq 1 ]]
}

# =============================================================================
# mark_repo_blocked tests
# =============================================================================

@test "mark_repo_blocked sets blocked status" {
    cat > "$HANK_DIR/.orchestration_state" << 'EOF'
{
    "repos": {
        "a": {"status": "in_progress"}
    },
    "blocked_repos": []
}
EOF

    mark_repo_blocked "a" "Test failure"

    status=$(jq -r '.repos.a.status' "$HANK_DIR/.orchestration_state")
    [[ "$status" == "blocked" ]]
}

@test "mark_repo_blocked records reason" {
    cat > "$HANK_DIR/.orchestration_state" << 'EOF'
{
    "repos": {
        "a": {"status": "in_progress"}
    },
    "blocked_repos": []
}
EOF

    mark_repo_blocked "a" "Circuit breaker opened"

    reason=$(jq -r '.repos.a.block_reason' "$HANK_DIR/.orchestration_state")
    [[ "$reason" == "Circuit breaker opened" ]]
}

# =============================================================================
# Integration tests
# =============================================================================

@test "full orchestration workflow" {
    # Create valid config
    cat > "$HANK_DIR/.repos.json" << EOF
[
    {"name": "shared", "path": "$TEST_REPOS_DIR/repo-a", "deps": [], "priority": 1},
    {"name": "api", "path": "$TEST_REPOS_DIR/repo-b", "deps": ["shared"], "priority": 2},
    {"name": "frontend", "path": "$TEST_REPOS_DIR/repo-c", "deps": ["api"], "priority": 3}
]
EOF

    # Validate config
    load_repo_config "$HANK_DIR/.repos.json"
    detect_circular_dependencies "$HANK_DIR/.repos.json"

    # Resolve order
    order=$(resolve_execution_order "$HANK_DIR/.repos.json")
    [[ "$order" == "shared api frontend" ]]

    # Initialize state
    init_orchestration_state "$HANK_DIR/.repos.json"

    # Process repos in order
    next=$(get_next_repo)
    [[ "$next" == "shared" ]]

    mark_repo_complete "shared" 3 0.10

    # Next should be api (unblocked now)
    next=$(get_next_repo)
    [[ "$next" == "api" ]]

    mark_repo_complete "api" 5 0.25

    # Next should be frontend
    next=$(get_next_repo)
    [[ "$next" == "frontend" ]]

    mark_repo_complete "frontend" 2 0.08

    # All done
    next=$(get_next_repo)
    [[ -z "$next" ]]

    # Check final state
    completed=$(jq -r '.completed_repos | length' "$HANK_DIR/.orchestration_state")
    [[ "$completed" -eq 3 ]]
}
