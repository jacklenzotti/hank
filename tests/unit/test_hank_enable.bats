#!/usr/bin/env bats
# Integration tests for hank_enable.sh and hank_enable_ci.sh
# Tests the full enable wizard flow and CI version

load '../helpers/test_helper'
load '../helpers/fixtures'

# Paths to scripts
HANK_ENABLE="${BATS_TEST_DIRNAME}/../../hank_enable.sh"
HANK_ENABLE_CI="${BATS_TEST_DIRNAME}/../../hank_enable_ci.sh"

setup() {
    # Create temporary test directory
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"

    # Initialize git repo (required by some detection)
    git init > /dev/null 2>&1
    git config user.email "test@example.com"
    git config user.name "Test User"
}

teardown() {
    if [[ -n "$TEST_DIR" ]] && [[ -d "$TEST_DIR" ]]; then
        cd /
        rm -rf "$TEST_DIR"
    fi
}

# =============================================================================
# HELP AND VERSION (4 tests)
# =============================================================================

@test "hank enable --help shows usage information" {
    run bash "$HANK_ENABLE" --help

    assert_success
    [[ "$output" =~ "Usage:" ]]
    [[ "$output" =~ "--from" ]]
    [[ "$output" =~ "--force" ]]
}

@test "hank enable --version shows version" {
    run bash "$HANK_ENABLE" --version

    assert_success
    [[ "$output" =~ "version" ]]
}

@test "hank enable-ci --help shows usage information" {
    run bash "$HANK_ENABLE_CI" --help

    assert_success
    [[ "$output" =~ "Usage:" ]]
    [[ "$output" =~ "Exit Codes:" ]]
}

@test "hank enable-ci --version shows version" {
    run bash "$HANK_ENABLE_CI" --version

    assert_success
    [[ "$output" =~ "version" ]]
}

# =============================================================================
# CI VERSION TESTS (8 tests)
# =============================================================================

@test "hank enable-ci creates .hank structure in empty directory" {
    run bash "$HANK_ENABLE_CI" --from none

    assert_success
    [[ -d ".hank" ]]
    [[ -f ".hank/PROMPT.md" ]]
    [[ -f ".hank/IMPLEMENTATION_PLAN.md" ]]
    [[ -f ".hank/PROMPT_plan.md" ]]
    [[ -f ".hank/AGENT.md" ]]
}

@test "hank enable-ci creates .hankrc configuration" {
    run bash "$HANK_ENABLE_CI" --from none

    assert_success
    [[ -f ".hankrc" ]]
}

@test "hank enable-ci detects TypeScript project" {
    cat > package.json << 'EOF'
{
    "name": "test-ts-project",
    "devDependencies": {
        "typescript": "^5.0.0"
    }
}
EOF

    run bash "$HANK_ENABLE_CI" --from none

    assert_success
    grep -q "PROJECT_TYPE=\"typescript\"" .hankrc
}

@test "hank enable-ci detects Python project" {
    cat > pyproject.toml << 'EOF'
[project]
name = "test-python-project"
EOF

    run bash "$HANK_ENABLE_CI" --from none

    assert_success
    grep -q "PROJECT_TYPE=\"python\"" .hankrc
}

@test "hank enable-ci respects --project-name override" {
    run bash "$HANK_ENABLE_CI" --from none --project-name "custom-name"

    assert_success
    grep -q "PROJECT_NAME=\"custom-name\"" .hankrc
}

@test "hank enable-ci respects --project-type override" {
    run bash "$HANK_ENABLE_CI" --from none --project-type "rust"

    assert_success
    grep -q "PROJECT_TYPE=\"rust\"" .hankrc
}

@test "hank enable-ci returns exit code 2 when already enabled" {
    # First enable
    bash "$HANK_ENABLE_CI" --from none >/dev/null 2>&1

    # Second enable without force
    run bash "$HANK_ENABLE_CI" --from none

    assert_equal "$status" 2
}

@test "hank enable-ci --force overwrites existing configuration" {
    # First enable
    bash "$HANK_ENABLE_CI" --from none --project-name "old-name" >/dev/null 2>&1

    # Second enable with force
    run bash "$HANK_ENABLE_CI" --from none --force --project-name "new-name"

    assert_success
}

# =============================================================================
# JSON OUTPUT TESTS (3 tests)
# =============================================================================

@test "hank enable-ci --json outputs valid JSON on success" {
    run bash "$HANK_ENABLE_CI" --from none --json

    assert_success
    # Validate JSON structure
    echo "$output" | jq -e '.success == true'
    echo "$output" | jq -e '.project_name'
    echo "$output" | jq -e '.files_created'
}

@test "hank enable-ci --json includes project info" {
    cat > package.json << 'EOF'
{"name": "json-test"}
EOF

    run bash "$HANK_ENABLE_CI" --from none --json

    assert_success
    echo "$output" | jq -e '.project_name == "json-test"'
}

@test "hank enable-ci --json returns proper structure when already enabled" {
    bash "$HANK_ENABLE_CI" --from none >/dev/null 2>&1

    run bash "$HANK_ENABLE_CI" --from none --json

    assert_equal "$status" 2
    echo "$output" | jq -e '.code == 2'
}

# =============================================================================
# PRD IMPORT TESTS (2 tests)
# =============================================================================

@test "hank enable-ci imports tasks from PRD file" {
    mkdir -p docs
    cat > docs/requirements.md << 'EOF'
# Project Requirements

- [ ] Implement user authentication
- [ ] Add API endpoints
- [ ] Create database schema
EOF

    run bash "$HANK_ENABLE_CI" --from prd --prd docs/requirements.md

    assert_success
    # Check that tasks were imported
    grep -q "authentication\|API\|database" .hank/IMPLEMENTATION_PLAN.md
}

@test "hank enable-ci fails gracefully with missing PRD file" {
    run bash "$HANK_ENABLE_CI" --from prd --prd nonexistent.md

    assert_failure
}

# =============================================================================
# IDEMPOTENCY TESTS (3 tests)
# =============================================================================

@test "hank enable-ci is idempotent with force flag" {
    bash "$HANK_ENABLE_CI" --from none >/dev/null 2>&1

    # Add a file to .hank
    echo "custom file" > .hank/custom.txt

    run bash "$HANK_ENABLE_CI" --from none --force

    assert_success
    # Custom file should still exist (we don't delete extra files)
    [[ -f ".hank/custom.txt" ]]
}

@test "hank enable-ci preserves existing .hank subdirectories" {
    bash "$HANK_ENABLE_CI" --from none >/dev/null 2>&1

    # Add custom content
    echo "spec content" > .hank/specs/custom_spec.md

    run bash "$HANK_ENABLE_CI" --from none --force

    assert_success
    [[ -f ".hank/specs/custom_spec.md" ]]
}

@test "hank enable-ci does not overwrite existing files without force" {
    mkdir -p .hank
    echo "original prompt" > .hank/PROMPT.md
    echo "original fix plan" > .hank/fix_plan.md
    echo "original agent" > .hank/AGENT.md

    run bash "$HANK_ENABLE_CI" --from none

    assert_equal "$status" 2
    # Verify original content preserved
    assert_equal "$(cat .hank/PROMPT.md)" "original prompt"
}

# =============================================================================
# QUIET MODE TESTS (2 tests)
# =============================================================================

@test "hank enable-ci --quiet suppresses output" {
    run bash "$HANK_ENABLE_CI" --from none --quiet

    assert_success
    # Output should be minimal
    [[ -z "$output" ]] || [[ ! "$output" =~ "Detected" ]]
}

@test "hank enable-ci --quiet still creates files" {
    run bash "$HANK_ENABLE_CI" --from none --quiet

    assert_success
    [[ -f ".hank/PROMPT.md" ]]
}
