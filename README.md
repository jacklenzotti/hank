# Hank

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![GitHub Issues](https://img.shields.io/github/issues/jacklenzotti/hank)](https://github.com/jacklenzotti/hank/issues)

> **Autonomous AI development loop for Claude Code with intelligent orchestration**

Hank wraps Claude Code in a persistent outer loop that runs autonomously until your project is done. It manages rate limits, detects stalls, preserves session context, and coordinates work across planning and building phases — so you can walk away and come back to committed code.

Based on [Geoffrey Huntley's technique](https://ghuntley.com/specs-hierarchical-task-network/) for continuous Claude Code execution.

## What Makes This Fork Different

This fork adds three major capabilities on top of the core Hank engine:

### Playbook-Style Prompts

Two-mode prompt system (`--mode plan` and `--mode build`) with specialized instructions for each phase:

- **Plan mode**: Research specs, audit existing code, produce an `IMPLEMENTATION_PLAN.md`
- **Build mode**: Execute the plan with a structured subagent hierarchy — up to 500 parallel Sonnet subagents for reads/searches, 1 Sonnet subagent for writes, Opus subagents for complex reasoning
- Lean `AGENTS.md` kept operational-only
- `IMPLEMENTATION_PLAN.md` as the single source of truth for task state

### Agent Teams Support

When `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` is set, the prompts guide Claude Code to use Agent Teams for genuinely parallel work:

- **Plan mode**: Spawns a specs researcher + code auditor team for parallel analysis
- **Build mode**: Uses teams when 2+ independent items touch different files/layers (e.g., frontend + backend)
- Falls back to subagents when items touch the same files or work is sequential

### GitHub Issues as Task Source

Run `hank --source github` to use GitHub Issues as your task manager instead of a static plan file:

- Issues labeled `hank` are synced to `IMPLEMENTATION_PLAN.md` before each loop
- Priority labels (`hank:next`, `hank:p1`, `hank:p2`) control execution order
- Hank comments on issues with progress and closes them on completion
- Labels track state: `hank:in-progress`, `hank:blocked`
- Create issues from your phone, Hank picks them up on the next iteration

## Quick Start

### Install

```bash
git clone https://github.com/jacklenzotti/hank.git
cd hank
./install.sh
```

This adds `hank`, `hank-monitor`, `hank-setup`, `hank-import`, `hank-enable`, and `hank-enable-ci` to your PATH.

### Enable in an Existing Project

```bash
cd my-project
hank-enable              # Interactive wizard — detects project type, imports tasks
hank --monitor           # Start the autonomous loop with tmux dashboard
```

### Or Import a PRD

```bash
hank-import requirements.md my-project
cd my-project
hank --monitor
```

### Or Create from Scratch

```bash
hank-setup my-project
cd my-project
# Edit .hank/PROMPT.md and .hank/specs/
hank --monitor
```

### GitHub Issues Workflow

```bash
cd my-project
hank-enable --from github    # Sets up labels and syncs issues
hank --source github         # Pulls issues each loop, reports back
```

## How It Works

Hank operates a simple cycle:

1. **Sync tasks** — From `IMPLEMENTATION_PLAN.md` or GitHub Issues
2. **Execute Claude Code** — With the current prompt and context
3. **Analyze response** — Parse the `HANK_STATUS` block for progress signals
4. **Evaluate exit** — Dual-condition gate: completion indicators AND explicit `EXIT_SIGNAL: true`
5. **Repeat** — Until done, rate-limited, or circuit breaker trips

### Exit Detection

Exit requires **both** conditions:

- `completion_indicators >= 2` (heuristic from natural language patterns)
- Claude's explicit `EXIT_SIGNAL: true` in the HANK_STATUS block

This prevents premature exits during productive iterations where Claude says "phase complete" but has more work to do.

### Circuit Breaker

Automatically detects and halts:

- 3 loops with no file changes (stagnation)
- 5 loops with the same error (stuck)
- Output declining by >70% (degradation)
- Recovers gradually with half-open monitoring

### Rate Limiting

- Default: 100 calls/hour with automatic countdown
- 5-hour API limit detection with wait/exit prompt
- Configurable via `--calls` flag or `.hankrc`

## Configuration

### Project Config (.hankrc)

```bash
PROJECT_NAME="my-project"
PROJECT_TYPE="typescript"
MAX_CALLS_PER_HOUR=100
CLAUDE_TIMEOUT_MINUTES=15
CLAUDE_OUTPUT_FORMAT="json"
ALLOWED_TOOLS="Write,Read,Edit,Bash(git *),Bash(npm *),Bash(pytest)"
SESSION_CONTINUITY=true
SESSION_EXPIRY_HOURS=24
```

### Project Structure

```
my-project/
├── .hank/
│   ├── PROMPT.md              # Instructions for Claude Code
│   ├── IMPLEMENTATION_PLAN.md # Task state (or synced from GitHub Issues)
│   ├── AGENTS.md              # Build/test commands (auto-maintained)
│   ├── specs/                 # Detailed requirements
│   └── logs/                  # Execution logs
├── .hankrc                    # Project settings
└── src/                       # Your code
```

### Session Management

Sessions persist context across loop iterations:

```bash
hank --monitor             # Uses session continuity (default)
hank --no-continue         # Fresh context each loop
hank --reset-session       # Clear session manually
hank --resume <id>         # Resume a specific session
```

Sessions auto-reset on circuit breaker trip, manual interrupt, or expiration (default: 24 hours).

## Command Reference

```bash
# Installation
./install.sh                    # Install globally
./uninstall.sh                  # Remove from system

# Project setup
hank-setup <name>               # New project from scratch
hank-enable                     # Enable in existing project (interactive)
hank-enable-ci                  # Enable in existing project (non-interactive)
hank-import <file> [name]       # Convert PRD/specs to Hank project

# Running
hank [OPTIONS]
  --monitor                     # tmux dashboard (recommended)
  --live                        # Stream Claude Code output in real-time
  --source github               # Pull tasks from GitHub Issues
  --mode plan|build             # Set prompt mode
  --calls NUM                   # Max API calls per hour
  --timeout MIN                 # Execution timeout (1-120 minutes)
  --prompt FILE                 # Custom prompt file
  --verbose                     # Detailed progress output
  --output-format json|text     # Response format
  --no-continue                 # Disable session continuity
  --reset-session               # Clear session state
  --reset-circuit               # Reset circuit breaker
  --status                      # Show current status
  --help                        # Show help

# Monitoring
hank-monitor                    # Live dashboard in separate terminal
tmux list-sessions              # View active Hank sessions
tmux attach -t <name>           # Reattach to session
```

## System Requirements

- **Bash 4.0+**
- **Claude Code CLI** — `npm install -g @anthropic-ai/claude-code`
- **tmux** — For integrated monitoring
- **jq** — JSON processing
- **Git**
- **GNU coreutils** — macOS: `brew install coreutils`

## Testing

```bash
npm install
npm test    # Runs all BATS tests
```

## Acknowledgments

- [Geoffrey Huntley](https://ghuntley.com/specs-hierarchical-task-network/) — Original technique
- [Claude Code](https://claude.ai/code) by Anthropic
- [frankbria/ralph-claude-code](https://github.com/frankbria/ralph-claude-code) — Upstream project

## License

MIT — see [LICENSE](LICENSE).
