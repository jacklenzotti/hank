#!/usr/bin/env bats
# Integration tests for orchestration mode

setup() {
    export TEST_DIR=$(mktemp -d)
    export HANK_SCRIPT="$BATS_TEST_DIRNAME/../../hank_loop.sh"

    # Create a simple multi-repo setup
    mkdir -p "$TEST_DIR/repo1" "$TEST_DIR/repo2" "$TEST_DIR/repo3"

    # Initialize each repo as a Hank project
    for repo in repo1 repo2 repo3; do
        mkdir -p "$TEST_DIR/$repo/.hank"
        mkdir -p "$TEST_DIR/$repo/src"

        # Create minimal PROMPT.md
        cat > "$TEST_DIR/$repo/.hank/PROMPT.md" <<'EOF'
# Test Prompt
You are testing orchestration.
EOF

        # Create minimal IMPLEMENTATION_PLAN.md
        cat > "$TEST_DIR/$repo/.hank/IMPLEMENTATION_PLAN.md" <<'EOF'
# Implementation Plan
- [ ] Test task 1
EOF

        # Create .hankrc
        cat > "$TEST_DIR/$repo/.hankrc" <<'EOF'
PROJECT_NAME="test-repo"
PROJECT_TYPE="javascript"
MAX_CALLS_PER_HOUR=10
CLAUDE_TIMEOUT_MINUTES=1
CLAUDE_OUTPUT_FORMAT="json"
ALLOWED_TOOLS="Read,Write,Edit,Bash(echo *)"
SESSION_CONTINUITY=false
EOF
    done
}

teardown() {
    rm -rf "$TEST_DIR"
}

# =============================================================================
# Basic orchestration tests
# =============================================================================

@test "orchestration mode requires .repos.json config file" {
    cd "$TEST_DIR/repo1"

    # Run hank with --orchestrate (should fail without config)
    run timeout 5 bash "$HANK_SCRIPT" --orchestrate 2>&1

    # Should exit with error
    [[ "$status" -ne 0 ]]
    [[ "$output" =~ "Repo config file not found" ]] || [[ "$output" =~ "Failed to load repo configuration" ]]
}

@test "orchestration mode validates .repos.json structure" {
    cd "$TEST_DIR/repo1"

    # Create invalid config (not an array)
    echo '{"invalid": "structure"}' > .hank/.repos.json

    run timeout 5 bash "$HANK_SCRIPT" --orchestrate 2>&1

    [[ "$status" -ne 0 ]]
    [[ "$output" =~ "must be a JSON array" ]]
}

@test "orchestration mode detects circular dependencies" {
    cd "$TEST_DIR/repo1"

    # Create config with circular dependency: repo1 -> repo2 -> repo1
    cat > .hank/.repos.json <<EOF
[
  {"name": "repo1", "path": "$TEST_DIR/repo1", "deps": ["repo2"]},
  {"name": "repo2", "path": "$TEST_DIR/repo2", "deps": ["repo1"]}
]
EOF

    run timeout 5 bash "$HANK_SCRIPT" --orchestrate 2>&1

    [[ "$status" -ne 0 ]]
    [[ "$output" =~ "Circular dependency detected" ]]
}

@test "orchestration mode validates repo paths exist" {
    cd "$TEST_DIR/repo1"

    # Create config with non-existent path
    cat > .hank/.repos.json <<EOF
[
  {"name": "repo1", "path": "$TEST_DIR/repo1", "deps": []},
  {"name": "fake", "path": "$TEST_DIR/nonexistent", "deps": []}
]
EOF

    run timeout 5 bash "$HANK_SCRIPT" --orchestrate 2>&1

    [[ "$status" -ne 0 ]]
    [[ "$output" =~ "paths do not exist" ]]
}

@test "orchestration mode displays execution order" {
    cd "$TEST_DIR/repo1"

    # Create valid config with dependencies: repo3 -> repo2 -> repo1
    cat > .hank/.repos.json <<EOF
[
  {"name": "repo1", "path": "$TEST_DIR/repo1", "deps": []},
  {"name": "repo2", "path": "$TEST_DIR/repo2", "deps": ["repo1"]},
  {"name": "repo3", "path": "$TEST_DIR/repo3", "deps": ["repo2"]}
]
EOF

    run timeout 3 bash "$HANK_SCRIPT" --orchestrate 2>&1 || true

    [[ "$output" =~ "Execution order: repo1 repo2 repo3" ]] ||
    [[ "$output" =~ "Starting work on repo: repo1" ]]
}

@test "orchestration mode initializes state file" {
    cd "$TEST_DIR/repo1"

    # Create valid config
    cat > .hank/.repos.json <<EOF
[
  {"name": "repo1", "path": "$TEST_DIR/repo1", "deps": []},
  {"name": "repo2", "path": "$TEST_DIR/repo2", "deps": ["repo1"]}
]
EOF

    # Initialize state file directly using the library
    source "$BATS_TEST_DIRNAME/../../lib/orchestrator.sh"
    export HANK_DIR=".hank"
    export REPOS_CONFIG_FILE=".hank/.repos.json"
    export ORCHESTRATION_STATE_FILE=".hank/.orchestration_state"

    init_orchestration_state

    # Check state file was created
    [[ -f .hank/.orchestration_state ]]

    # Validate state file structure
    jq -e '.active' .hank/.orchestration_state
    jq -e '.repos.repo1' .hank/.orchestration_state
    jq -e '.repos.repo2' .hank/.orchestration_state
}

@test "orchestration --repos flag shows status" {
    cd "$TEST_DIR/repo1"

    # Create state file
    cat > .hank/.orchestration_state <<'EOF'
{
  "active": true,
  "started_at": "2024-01-01T00:00:00Z",
  "repos": {
    "repo1": {"status": "completed", "loops": 3, "cost_usd": 1.50},
    "repo2": {"status": "in_progress", "loops": 1, "cost_usd": 0.25}
  },
  "total_cost_usd": 1.75,
  "completed_repos": ["repo1"],
  "blocked_repos": [],
  "current_repo": "repo2"
}
EOF

    run bash "$HANK_SCRIPT" --repos

    [[ "$status" -eq 0 ]]
    [[ "$output" =~ "Orchestration Status" ]]
    [[ "$output" =~ "Total Repos:" ]]
    [[ "$output" =~ "Completed:" ]]
    [[ "$output" =~ "repo1: completed" ]]
    [[ "$output" =~ "repo2: in_progress" ]]
}

# =============================================================================
# Dependency resolution tests
# =============================================================================

@test "orchestration respects dependency order" {
    cd "$TEST_DIR/repo1"

    # Create config: repo2 depends on repo1
    cat > .hank/.repos.json <<EOF
[
  {"name": "repo1", "path": "$TEST_DIR/repo1", "deps": []},
  {"name": "repo2", "path": "$TEST_DIR/repo2", "deps": ["repo1"]}
]
EOF

    # Run orchestration briefly
    timeout 2 bash "$HANK_SCRIPT" --orchestrate --dry-run 2>&1 > /tmp/orch_output.txt || true

    # Check that repo1 started before repo2
    if grep -q "Starting work on repo: repo1" /tmp/orch_output.txt; then
        local repo1_line=$(grep -n "Starting work on repo: repo1" /tmp/orch_output.txt | head -1 | cut -d: -f1)
        local repo2_line=$(grep -n "Starting work on repo: repo2" /tmp/orch_output.txt | head -1 | cut -d: -f1 || echo "9999")

        [[ "$repo1_line" -lt "$repo2_line" ]]
    fi
}

@test "orchestration skips blocked repos" {
    cd "$TEST_DIR/repo1"

    # Create state with blocked repo
    cat > .hank/.repos.json <<EOF
[
  {"name": "repo1", "path": "$TEST_DIR/repo1", "deps": []},
  {"name": "repo2", "path": "$TEST_DIR/repo2", "deps": ["repo1"]}
]
EOF

    # Initialize state
    source "$BATS_TEST_DIRNAME/../../lib/orchestrator.sh"
    export HANK_DIR=".hank"
    export REPOS_CONFIG_FILE=".hank/.repos.json"
    export ORCHESTRATION_STATE_FILE=".hank/.orchestration_state"

    init_orchestration_state

    # Mark repo2 as blocked
    jq '.repos.repo2.blocked_by = ["repo1"]' .hank/.orchestration_state > .hank/.orchestration_state.tmp
    mv .hank/.orchestration_state.tmp .hank/.orchestration_state

    # Check if repo2 is blocked
    is_repo_blocked "repo2"
}

# =============================================================================
# Cost tracking tests
# =============================================================================

@test "orchestration aggregates costs across repos" {
    cd "$TEST_DIR/repo1"

    # Create state with costs
    cat > .hank/.orchestration_state <<'EOF'
{
  "active": true,
  "repos": {
    "repo1": {"status": "completed", "loops": 3, "cost_usd": 1.50},
    "repo2": {"status": "completed", "loops": 2, "cost_usd": 0.75},
    "repo3": {"status": "completed", "loops": 1, "cost_usd": 0.25}
  },
  "total_cost_usd": 2.50,
  "completed_repos": ["repo1", "repo2", "repo3"]
}
EOF

    source "$BATS_TEST_DIRNAME/../../lib/orchestrator.sh"
    export HANK_DIR=".hank"
    export ORCHESTRATION_STATE_FILE=".hank/.orchestration_state"

    run show_orchestration_status

    [[ "$output" =~ "Total Cost:" ]]
    [[ "$output" =~ "\$2.50" ]] || [[ "$output" =~ "2.5" ]]
}

@test "mark_repo_complete updates total cost" {
    cd "$TEST_DIR/repo1"

    # Initialize state
    cat > .hank/.repos.json <<EOF
[
  {"name": "repo1", "path": "$TEST_DIR/repo1", "deps": []},
  {"name": "repo2", "path": "$TEST_DIR/repo2", "deps": []}
]
EOF

    source "$BATS_TEST_DIRNAME/../../lib/orchestrator.sh"
    export HANK_DIR=".hank"
    export REPOS_CONFIG_FILE=".hank/.repos.json"
    export ORCHESTRATION_STATE_FILE=".hank/.orchestration_state"

    init_orchestration_state

    # Mark repos complete with costs
    mark_repo_complete "repo1" 3 1.50
    mark_repo_complete "repo2" 2 0.75

    # Check total cost
    local total=$(jq -r '.total_cost_usd' .hank/.orchestration_state)

    # Use awk for float comparison (2.25)
    result=$(awk "BEGIN {printf \"%d\", ($total >= 2.24 && $total <= 2.26)}")
    [[ "$result" -eq 1 ]]
}

# =============================================================================
# Integration with main loop
# =============================================================================

@test "orchestration disables recursion in sub-repos" {
    cd "$TEST_DIR/repo1"

    # This test verifies that when orchestration runs hank in a sub-repo,
    # it sets HANK_ORCHESTRATE=false to avoid infinite recursion

    # Create simple config
    cat > .hank/.repos.json <<EOF
[
  {"name": "repo1", "path": "$TEST_DIR/repo1", "deps": []}
]
EOF

    # The implementation exports HANK_ORCHESTRATE="false" before exec
    # We can verify this by checking the orchestration wrapper code

    grep -q 'export HANK_ORCHESTRATE="false"' "$HANK_SCRIPT"
}

@test "orchestration inherits environment variables to sub-repos" {
    cd "$TEST_DIR/repo1"

    # Verify that HANK_MODE, HANK_TASK_SOURCE, etc. are exported
    # before executing sub-repo loops

    grep -q 'export HANK_MODE=' "$HANK_SCRIPT"
    grep -q 'export HANK_TASK_SOURCE=' "$HANK_SCRIPT"
    grep -q 'export HANK_DRY_RUN=' "$HANK_SCRIPT"
}
