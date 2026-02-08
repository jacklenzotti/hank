# CLAUDE.md

This file provides guidance to Claude Code when working in this repository.

## Repository Overview

Hank is an autonomous outer loop for Claude Code. It runs Claude Code repeatedly against your project, managing rate limits, detecting stalls, preserving session context, and coordinating work across planning and building phases.

Fork of [frankbria/ralph-claude-code](https://github.com/frankbria/ralph-claude-code) with added Playbook-style prompts, Agent Teams support, GitHub Issues integration, and dry-run mode.

## Core Architecture

### Main Scripts

| Script              | Purpose                                                                                            |
| ------------------- | -------------------------------------------------------------------------------------------------- |
| `hank_loop.sh`      | Main autonomous loop — CLI parsing, task sync, Claude execution, response analysis, exit detection |
| `setup.sh`          | Project initialization for new Hank projects                                                       |
| `hank_import.sh`    | PRD/spec import — converts documents to Hank format using Claude CLI JSON output                   |
| `hank_enable.sh`    | Interactive wizard for enabling Hank in existing projects                                          |
| `hank_enable_ci.sh` | Non-interactive version for CI/automation (exit codes: 0=success, 1=error, 2=already enabled)      |

### Library Components (lib/)

| Library                | Purpose                                                                                                           |
| ---------------------- | ----------------------------------------------------------------------------------------------------------------- |
| `circuit_breaker.sh`   | Three-state circuit breaker (CLOSED → HALF_OPEN → OPEN) preventing runaway loops                                  |
| `response_analyzer.sh` | Analyzes Claude output for completion signals, JSON parsing, session management                                   |
| `task_sources.sh`      | GitHub Issues sync (`sync_github_issues`), progress reporting (`report_to_github`), label setup, beads/PRD import |
| `enable_core.sh`       | Project detection, template generation (`generate_prompt_md`, `generate_agent_md`), idempotency checks            |
| `wizard_utils.sh`      | Interactive prompt utilities for the enable wizard                                                                |
| `date_utils.sh`        | Cross-platform date/timestamp utilities                                                                           |
| `timeout_utils.sh`     | Cross-platform timeout command (Linux `timeout` / macOS `gtimeout`)                                               |
| `cost_tracker.sh`      | Cost logging (JSONL), session totals, summary display, per-issue cost tracking                                    |
| `retry_strategy.sh`    | Retry strategy engine with exponential backoff, error classification, state tracking                              |
| `orchestrator.sh`      | Multi-repo orchestration, dependency resolution (topological sort), circular dependency detection                 |
| `audit_log.sh`         | Structured JSONL event logging, automatic rotation, audit trail for all major operations                          |
| `replay.sh`            | Session replay, timeline reconstruction from audit/cost logs                                                      |

### Templates (templates/)

| Template         | Purpose                                                                                |
| ---------------- | -------------------------------------------------------------------------------------- |
| `PROMPT.md`      | Build mode prompt — subagent hierarchy, Agent Teams guidance, HANK_STATUS block format |
| `PROMPT_plan.md` | Plan mode prompt — Agent Teams for parallel research, produces IMPLEMENTATION_PLAN.md  |
| `AGENT.md`       | Operational build/test commands only (no status bloat)                                 |

## Execution Modes

### `--mode build` (default)

Continuous loop. Each iteration: sync tasks → execute Claude → analyze response → check exit conditions → repeat.

### `--mode plan`

Single iteration. Claude researches the codebase and produces/updates `IMPLEMENTATION_PLAN.md`.

### `--dry-run`

Single read-only iteration. Tools restricted to `Read,Glob,Grep,Bash(git status),Bash(git log),Bash(git diff)`. Claude analyzes without modifying files.

### `--source github`

Syncs GitHub Issues labeled `hank` into `IMPLEMENTATION_PLAN.md` before each iteration. Reports progress back as comments, closes issues on completion. Priority labels: `hank:next` > `hank:p1` > `hank:p2`.

### `--orchestrate` (Orchestration Mode)

Execute Hank across multiple repositories in dependency order. Requires `.hank/.repos.json` config file.

**Features:**

- Validates repo configuration and detects circular dependencies
- Resolves execution order via topological sort (Kahn's algorithm)
- Executes Hank loop in each repo sequentially based on dependencies
- Tracks per-repo status, loops, and costs
- Aggregates total cost across all repos
- Skips blocked repos and unblocks dependents on completion

**Configuration (`.hank/.repos.json`):**

```json
[
  { "name": "core", "path": "/path/to/core", "deps": [], "priority": 1 },
  { "name": "api", "path": "/path/to/api", "deps": ["core"], "priority": 2 },
  { "name": "ui", "path": "/path/to/ui", "deps": ["api"], "priority": 3 }
]
```

**State Tracking (`.hank/.orchestration_state`):**

- Per-repo status: `pending`, `in_progress`, `completed`, `blocked`
- Loop counts and cost accumulation
- Dependency blocking/unblocking
- Current repo in progress

**Usage:**

```bash
hank --orchestrate              # Run orchestration mode
hank --repos                    # Show orchestration status
```

## Key Commands

```bash
# Installation
./install.sh                        # Install globally
./uninstall.sh                      # Remove from system

# Project setup
hank-setup my-project               # New project
hank-enable                         # Enable in existing project (interactive)
hank-enable-ci                      # Enable in existing project (non-interactive)
hank-import prd.md my-project       # Import PRD/specs

# Running
hank --monitor                      # tmux dashboard (recommended)
hank --mode plan                    # Generate IMPLEMENTATION_PLAN.md
hank --source github                # Pull tasks from GitHub Issues
hank --dry-run                      # Read-only preview
hank --live                         # Stream Claude output in real-time
hank --calls 50 --timeout 30        # Custom rate limit and timeout

# Session management
hank --stop                         # Stop all running Hank sessions
hank --reset-session                # Clear session state
hank --no-continue                  # Fresh context each loop
hank --reset-circuit                # Reset circuit breaker
hank --cost-summary                 # Show cost report from all sessions

# Orchestration (multi-repo)
hank --orchestrate                  # Run across multiple repos in dependency order
hank --repos                        # Show orchestration status

# Session replay
hank --replay --list                # List all recorded sessions
hank --replay <session_id>          # Replay session timeline
hank --replay <id> --json           # JSON output format
hank --replay <id> --issue 123      # Filter by issue number

# Testing
npm test                            # All tests
npm run test:unit                   # Unit tests only
bats tests/unit/test_cli_parsing.bats  # Single file
```

## Project Structure (Hank-managed projects)

```
my-project/
├── .hank/
│   ├── PROMPT.md              # Build mode instructions
│   ├── PROMPT_plan.md         # Plan mode instructions
│   ├── IMPLEMENTATION_PLAN.md # Task state (or synced from GitHub Issues)
│   ├── AGENTS.md              # Build/test commands (auto-maintained)
│   ├── cost_log.jsonl         # Per-loop cost/token data (persistent)
│   ├── specs/                 # Detailed requirements
│   └── logs/                  # Execution logs
├── .hankrc                    # Project config (tools, timeouts, format)
└── src/                       # Your code
```

## HANK_STATUS Block

Claude outputs this structured block at the end of each response for the engine to parse:

```
<!-- HANK_STATUS
STATUS: IN_PROGRESS | COMPLETE
TASKS_COMPLETED: <what was done>
FILES_MODIFIED: <list of files>
TESTS_STATUS: PASS | FAIL | NOT_RUN
WORK_TYPE: feature | fix | test | refactor | docs
EXIT_SIGNAL: true | false
RECOMMENDATION: <next step; include issue number e.g. #42 if working on a GitHub issue>
-->
```

## Exit Detection

**Dual-condition gate** — exit requires BOTH:

1. `completion_indicators >= 2` (heuristic from natural language)
2. `EXIT_SIGNAL: true` in the HANK_STATUS block

Other exit conditions:

- `done_signals >= 2` (repeated completion signals)
- `test_loops >= 3` (test-only iterations)
- All items in IMPLEMENTATION_PLAN.md completed
- Circuit breaker opens (stagnation/errors)

## Circuit Breaker Thresholds

| Threshold                        | Default | Trigger                    |
| -------------------------------- | ------- | -------------------------- |
| `CB_NO_PROGRESS_THRESHOLD`       | 3       | Loops with no file changes |
| `CB_SAME_ERROR_THRESHOLD`        | 5       | Loops with same error      |
| `CB_OUTPUT_DECLINE_THRESHOLD`    | 70%     | Output size decline        |
| `CB_PERMISSION_DENIAL_THRESHOLD` | 2       | Permission denied loops    |

## Retry Strategy

Sits between error detection and the circuit breaker. When an error is classified, the retry engine determines whether to retry and how long to wait before the next attempt.

### Configuration (.hankrc)

| Variable                    | Default | Description                     |
| --------------------------- | ------- | ------------------------------- |
| `RETRY_MAX_ATTEMPTS`        | 3       | Max retries per error signature |
| `RETRY_BACKOFF_INITIAL_SEC` | 30      | Initial backoff delay (seconds) |
| `RETRY_BACKOFF_MAX_SEC`     | 300     | Maximum backoff delay (seconds) |
| `RETRY_BACKOFF_MULTIPLIER`  | 2       | Exponential backoff multiplier  |

### Strategy Mapping

| Error Category      | Strategy          | Behavior                                  |
| ------------------- | ----------------- | ----------------------------------------- |
| `rate_limit`        | `wait_and_retry`  | Exponential backoff, then retry           |
| `api_error`         | `wait_and_retry`  | Exponential backoff, then retry           |
| `test_failure`      | `retry_with_hint` | Retry with context hint about the failure |
| `build_error`       | `retry_with_hint` | Retry with context hint about the failure |
| `dependency_error`  | `retry_with_hint` | Retry with context hint about the failure |
| `context_overflow`  | `reset_session`   | Reset session context, then retry         |
| `permission_denied` | `halt`            | Stop immediately (no retry)               |
| `unknown`           | `no_retry`        | No automatic retry                        |

State files: `.hank/.retry_state` (JSON), `.hank/.retry_log` (JSONL).

## Error Classification

Errors detected in Claude output are automatically classified into categories for retry strategy selection and catalog tracking.

### Categories

`rate_limit`, `permission_denied`, `context_overflow`, `api_error`, `dependency_error`, `build_error`, `test_failure`, `unknown`

### Error Catalog

Persistent record of all classified errors stored in `.hank/.error_catalog` (JSONL). Each entry tracks the error signature, category, occurrence count, and loop numbers where it appeared.

```bash
hank --error-catalog              # Show all classified errors
hank --error-catalog rate_limit   # Filter by category
```

## Audit Log

Structured JSONL event log for all major operations, stored at `.hank/audit_log.jsonl`. Automatically rotates at 10,000 events (archived to `audit_log.jsonl.1`).

### Event Types

`session_start`, `session_reset`, `loop_start`, `loop_complete`, `error_detected`, `retry_triggered`, `circuit_breaker_state_change`, `task_sync`, `issue_closed`, `exit_signal`

### Querying

```bash
hank --audit                          # Show recent events (default: 20)
hank --audit --type error_detected    # Filter by event type
hank --audit --session <id>           # Filter by session ID
hank --audit --since 2h               # Events from last 2 hours
hank --audit --limit 50               # Show more events
```

## Session Replay

Reconstructs a timeline from audit and cost logs for debugging and post-mortem analysis. Available via `lib/replay.sh`.

```bash
hank --replay --list               # List all recorded sessions
hank --replay <session_id>         # Replay session timeline (human-readable)
hank --replay <id> --json          # JSON output format
hank --replay <id> --issue 123     # Filter by issue number
```

Merges events from `audit_log.jsonl` and `cost_log.jsonl` into a sorted timeline showing loops, errors, retries, circuit breaker transitions, and cost data.

## Configuration (.hankrc)

```bash
PROJECT_NAME="my-project"
PROJECT_TYPE="typescript"
MAX_CALLS_PER_HOUR=100
CLAUDE_TIMEOUT_MINUTES=15
CLAUDE_OUTPUT_FORMAT="json"
ALLOWED_TOOLS="Write,Read,Edit,Bash(git *),Bash(npm *),Bash(pytest)"
SESSION_CONTINUITY=true
SESSION_EXPIRY_HOURS=24
RETRY_MAX_ATTEMPTS=3
RETRY_BACKOFF_INITIAL_SEC=30
RETRY_BACKOFF_MAX_SEC=300
RETRY_BACKOFF_MULTIPLIER=2
```

## Agent Teams

Enabled via `hank --teams` flag (off by default). When active, Hank:

- Exports `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` to the Claude process
- Adds team tools (`TeamCreate`, `TeamDelete`, `SendMessage`, `TaskCreate`, `TaskUpdate`, `TaskList`, `TaskGet`) to `--allowedTools`

Behavior when teams are enabled:

- **Plan mode**: Spawns specs researcher + code auditor team for parallel analysis
- **Build mode**: Uses teams for 2+ independent items touching different files/layers
- Falls back to subagents when items overlap or work is sequential

## Companion Dashboard

[hank-dash](https://github.com/jacklenzotti/hank-dash) is a separate repo providing a live web dashboard that reads `.hank/` data files via file watchers and renders real-time charts, process monitoring, and stall detection in the browser. It is not part of this repository but consumes the same data files Hank writes.

## Global Installation Paths

- **Commands**: `~/.local/bin/` (hank, hank-setup, hank-import, hank-enable, hank-enable-ci)
- **Scripts**: `~/.hank/` (hank_loop.sh, etc.)
- **Libraries**: `~/.hank/lib/`
- **Templates**: `~/.hank/templates/`

## Testing

Tests use BATS (Bash Automated Testing System). 100% pass rate is the quality gate.

```bash
npm test                            # All tests
npm run test:unit                   # Unit tests only
npm run test:integration            # Integration tests only
```

## Development Standards

- All new features must include tests
- Conventional commit format: `feat(scope):`, `fix(scope):`, `test(scope):`
- 100% test pass rate required before merge
- Update CLAUDE.md when adding new patterns or commands
