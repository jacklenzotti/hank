#!/usr/bin/env bats
# Unit tests for error classification system in Hank

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
    source "${BATS_TEST_DIRNAME}/../../lib/date_utils.sh"
    source "${BATS_TEST_DIRNAME}/../../lib/response_analyzer.sh"
}

teardown() {
    if [[ -n "$TEST_DIR" ]] && [[ -d "$TEST_DIR" ]]; then
        cd /
        rm -rf "$TEST_DIR"
    fi
}

# =============================================================================
# ERROR SIGNATURE GENERATION TESTS
# =============================================================================

@test "generate_error_signature normalizes timestamps" {
    local error1="Error at 2026-02-07 14:30:00: Test failed"
    local error2="Error at 2026-02-07 15:45:12: Test failed"

    sig1=$(generate_error_signature "$error1")
    sig2=$(generate_error_signature "$error2")

    # Signatures should match (timestamps removed)
    [[ "$sig1" == "$sig2" ]] || fail "Signatures should match after timestamp normalization: $sig1 != $sig2"
}

@test "generate_error_signature normalizes line numbers" {
    local error1="Error in file.ts:123: Undefined variable"
    local error2="Error in file.ts:456: Undefined variable"

    sig1=$(generate_error_signature "$error1")
    sig2=$(generate_error_signature "$error2")

    # Signatures should match (line numbers removed)
    [[ "$sig1" == "$sig2" ]] || fail "Signatures should match after line number normalization"
}

@test "generate_error_signature is case insensitive" {
    local error1="ERROR: Connection timeout"
    local error2="error: connection timeout"

    sig1=$(generate_error_signature "$error1")
    sig2=$(generate_error_signature "$error2")

    # Signatures should match (case normalized)
    [[ "$sig1" == "$sig2" ]] || fail "Signatures should match after case normalization"
}

@test "generate_error_signature returns 16-character hash" {
    local error="Test error message"
    sig=$(generate_error_signature "$error")

    # Should be exactly 16 characters
    [[ ${#sig} -eq 16 ]] || fail "Signature should be 16 characters, got ${#sig}"
}

# =============================================================================
# ERROR CLASSIFICATION TESTS
# =============================================================================

@test "classify_error detects rate_limit errors" {
    local error="Error: Rate limit exceeded, try back in 5 hours"
    category=$(classify_error "$error")
    [[ "$category" == "rate_limit" ]] || fail "Expected rate_limit, got: $category"
}

@test "classify_error detects permission_denied errors" {
    local error="Error: permission denied: tool not in --allowedTools"
    category=$(classify_error "$error")
    [[ "$category" == "permission_denied" ]] || fail "Expected permission_denied, got: $category"
}

@test "classify_error detects test_failure errors" {
    local error="FAIL: test_authentication_flow: expected true but got false"
    category=$(classify_error "$error")
    [[ "$category" == "test_failure" ]] || fail "Expected test_failure, got: $category"
}

@test "classify_error detects build_error" {
    local error="SyntaxError: Unexpected token at line 45"
    category=$(classify_error "$error")
    [[ "$category" == "build_error" ]] || fail "Expected build_error, got: $category"
}

@test "classify_error detects dependency_error" {
    local error="Error: Cannot find module 'express'"
    category=$(classify_error "$error")
    [[ "$category" == "dependency_error" ]] || fail "Expected dependency_error, got: $category"
}

@test "classify_error detects context_overflow" {
    local error="Error: Context window exceeded, prompt too long"
    category=$(classify_error "$error")
    [[ "$category" == "context_overflow" ]] || fail "Expected context_overflow, got: $category"
}

@test "classify_error detects api_error" {
    local error="Error: 502 Bad Gateway - API connection timeout"
    category=$(classify_error "$error")
    [[ "$category" == "api_error" ]] || fail "Expected api_error, got: $category"
}

@test "classify_error returns unknown for unclassified errors" {
    local error="Something mysterious went wrong"
    category=$(classify_error "$error")
    [[ "$category" == "unknown" ]] || fail "Expected unknown, got: $category"
}

# =============================================================================
# ERROR CATALOG PERSISTENCE TESTS
# =============================================================================

@test "init_error_catalog creates catalog file" {
    init_error_catalog
    [[ -f "$HANK_DIR/.error_catalog" ]] || fail "Error catalog file not created"

    # Check JSON structure
    local errors=$(jq -r '.errors' "$HANK_DIR/.error_catalog")
    [[ "$errors" == "{}" ]] || fail "Catalog should have empty errors object"
}

@test "record_error creates new entry" {
    init_error_catalog

    local error="Test failed: assertion error"
    record_error "$error" 1

    # Check that catalog has one entry
    local count=$(jq '.errors | length' "$HANK_DIR/.error_catalog")
    [[ "$count" -eq 1 ]] || fail "Expected 1 error in catalog, got $count"
}

@test "record_error increments count for duplicate errors" {
    init_error_catalog

    local error="Test failed: assertion error"
    record_error "$error" 1
    record_error "$error" 2
    record_error "$error" 3

    # Should have only one unique error signature
    local unique_count=$(jq '.errors | length' "$HANK_DIR/.error_catalog")
    [[ "$unique_count" -eq 1 ]] || fail "Expected 1 unique error, got $unique_count"

    # Check count is 3
    local first_sig=$(jq -r '.errors | keys[0]' "$HANK_DIR/.error_catalog")
    local count=$(jq -r ".errors[\"$first_sig\"].count" "$HANK_DIR/.error_catalog")
    [[ "$count" -eq 3 ]] || fail "Expected count=3, got $count"
}

@test "record_error tracks loop numbers" {
    init_error_catalog

    local error="Test failed: assertion error"
    record_error "$error" 1
    record_error "$error" 5
    record_error "$error" 10

    # Check loops array
    local first_sig=$(jq -r '.errors | keys[0]' "$HANK_DIR/.error_catalog")
    local loops=$(jq -r ".errors[\"$first_sig\"].loops | @json" "$HANK_DIR/.error_catalog")
    [[ "$loops" == "[1,5,10]" ]] || fail "Expected loops [1,5,10], got $loops"
}

@test "record_error stores category" {
    init_error_catalog

    local error="Error: Rate limit exceeded"
    record_error "$error" 1

    # Check category
    local first_sig=$(jq -r '.errors | keys[0]' "$HANK_DIR/.error_catalog")
    local category=$(jq -r ".errors[\"$first_sig\"].category" "$HANK_DIR/.error_catalog")
    [[ "$category" == "rate_limit" ]] || fail "Expected rate_limit category, got $category"
}

@test "record_error updates last_seen timestamp" {
    init_error_catalog

    local error="Test error"
    record_error "$error" 1

    local first_sig=$(jq -r '.errors | keys[0]' "$HANK_DIR/.error_catalog")
    local first_seen=$(jq -r ".errors[\"$first_sig\"].first_seen" "$HANK_DIR/.error_catalog")

    # Sleep to ensure timestamp difference
    sleep 1

    record_error "$error" 2

    local last_seen=$(jq -r ".errors[\"$first_sig\"].last_seen" "$HANK_DIR/.error_catalog")

    # last_seen should be after first_seen
    [[ "$last_seen" > "$first_seen" ]] || fail "last_seen should be updated"
}

# =============================================================================
# EXTRACT AND CLASSIFY ERRORS TESTS
# =============================================================================

@test "extract_and_classify_errors finds errors in text output" {
    local output_file="$LOG_DIR/test_output.log"
    cat > "$output_file" << 'EOF'
Running tests...
Error: Test failed - expected 5 but got 3
Error: Rate limit exceeded
Build completed successfully
EOF

    local result=$(extract_and_classify_errors "$output_file" 1)
    local count=$(echo "$result" | jq 'length')

    # Should find 2 errors
    [[ "$count" -eq 2 ]] || fail "Expected 2 errors, got $count"
}

@test "extract_and_classify_errors classifies each error" {
    local output_file="$LOG_DIR/test_output.log"
    cat > "$output_file" << 'EOF'
Error: Test failed - assertion error
Error: Rate limit exceeded, try again later
EOF

    local result=$(extract_and_classify_errors "$output_file" 1)

    # Check first error is test_failure
    local cat1=$(echo "$result" | jq -r '.[0].category')
    [[ "$cat1" == "test_failure" ]] || fail "Expected test_failure, got $cat1"

    # Check second error is rate_limit
    local cat2=$(echo "$result" | jq -r '.[1].category')
    [[ "$cat2" == "rate_limit" ]] || fail "Expected rate_limit, got $cat2"
}

@test "extract_and_classify_errors ignores JSON field errors" {
    local output_file="$LOG_DIR/test_output.log"
    cat > "$output_file" << 'EOF'
{
    "is_error": false,
    "error_count": 0,
    "has_errors": false
}
Error: Real error message
EOF

    local result=$(extract_and_classify_errors "$output_file" 1)
    local count=$(echo "$result" | jq 'length')

    # Should only find 1 real error (not JSON fields)
    [[ "$count" -eq 1 ]] || fail "Expected 1 error, got $count (should ignore JSON fields)"
}

@test "extract_and_classify_errors records errors in catalog" {
    init_error_catalog

    local output_file="$LOG_DIR/test_output.log"
    cat > "$output_file" << 'EOF'
Error: Test failed
EOF

    extract_and_classify_errors "$output_file" 1

    # Check catalog was updated
    local count=$(jq '.errors | length' "$HANK_DIR/.error_catalog")
    [[ "$count" -eq 1 ]] || fail "Error catalog should have 1 entry"
}

# =============================================================================
# DISPLAY ERROR CATALOG TESTS
# =============================================================================

@test "display_error_catalog shows empty catalog message" {
    init_error_catalog

    run display_error_catalog
    assert_success

    # Strip ANSI color codes before checking
    output_plain=$(echo "$output" | sed 's/\x1b\[[0-9;]*m//g')
    [[ "$output_plain" =~ "Error catalog is empty" ]] || fail "Expected 'Error catalog is empty', got: $output_plain"
}

@test "display_error_catalog shows errors grouped by category" {
    init_error_catalog

    record_error "Error: Test 1 failed" 1
    record_error "Error: Test 2 failed" 2
    record_error "Error: Rate limit exceeded" 3

    run display_error_catalog
    assert_success

    # Strip ANSI color codes before checking
    output_plain=$(echo "$output" | sed 's/\x1b\[[0-9;]*m//g')
    [[ "$output_plain" =~ "Category: test_failure" ]] || fail "Should contain test_failure category"
    [[ "$output_plain" =~ "Category: rate_limit" ]] || fail "Should contain rate_limit category"
}

@test "display_error_catalog filters by category" {
    init_error_catalog

    record_error "Error: Test failed" 1
    record_error "Error: Rate limit exceeded" 2

    run display_error_catalog "rate_limit"
    assert_success

    # Strip ANSI color codes before checking
    output_plain=$(echo "$output" | sed 's/\x1b\[[0-9;]*m//g')
    [[ "$output_plain" =~ "Category: rate_limit" ]] || fail "Should contain rate_limit category"

    # Should NOT show test_failure category
    [[ ! "$output_plain" =~ "Category: test_failure" ]] || fail "Should NOT contain test_failure category when filtered"
}

# =============================================================================
# INTEGRATION WITH analyze_response TESTS
# =============================================================================

@test "analyze_response includes classified_errors in JSON output" {
    local output_file="$LOG_DIR/test_output.log"
    cat > "$output_file" << 'EOF'
Error: Test failed
Error: Rate limit exceeded
Implementation complete
EOF

    analyze_response "$output_file" 1 "$HANK_DIR/.response_analysis"

    # Check that classified_errors field exists
    local has_field=$(jq 'has("analysis")' "$HANK_DIR/.response_analysis")
    [[ "$has_field" == "true" ]] || fail "Response analysis should have analysis field"

    local classified=$(jq '.analysis.classified_errors' "$HANK_DIR/.response_analysis")
    [[ "$classified" != "null" ]] || fail "classified_errors field should exist"
}

@test "analyze_response includes error_count in JSON output" {
    local output_file="$LOG_DIR/test_output.log"
    cat > "$output_file" << 'EOF'
Error: Test 1 failed
Error: Test 2 failed
Error: Test 3 failed
EOF

    analyze_response "$output_file" 1 "$HANK_DIR/.response_analysis"

    local error_count=$(jq '.analysis.error_count' "$HANK_DIR/.response_analysis")
    [[ "$error_count" -eq 3 ]] || fail "Expected error_count=3, got $error_count"
}

@test "analyze_response includes error_categories summary" {
    local output_file="$LOG_DIR/test_output.log"
    cat > "$output_file" << 'EOF'
Error: Test failed
Error: Build compilation error
EOF

    analyze_response "$output_file" 1 "$HANK_DIR/.response_analysis"

    local categories=$(jq -r '.analysis.error_categories' "$HANK_DIR/.response_analysis")

    # Should contain both categories
    [[ "$categories" =~ "test_failure" ]] || fail "Should contain test_failure category"
    [[ "$categories" =~ "build_error" ]] || fail "Should contain build_error category"
}
