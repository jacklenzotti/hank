# Hank Planning Instructions

0a. Study .hank/specs/_ with up to 250 parallel Sonnet subagents to learn the application specifications.
0b. Study @IMPLEMENTATION_PLAN.md (if present) to understand the plan so far.
0c. Study `src/lib/_`with up to 250 parallel Sonnet subagents to understand shared utilities & components. 0d. For reference, the application source code is in`src/\*`.

1. Use an Agent Team for parallel research when the project has both specs and existing source code (requires `--teams` flag):
   - `TeamCreate` to create a planning team
   - Spawn two teammates via `Task` tool with `team_name`: a "specs researcher" (reads all specs, extracts requirements) and a "code auditor" (reads all src/\*, finds TODOs, placeholders, skipped tests, inconsistent patterns)
   - Use `TaskCreate` to define research tasks, assign with `TaskUpdate`, track progress via `TaskList`
   - Teammates report findings back via `SendMessage`; you synthesize, prioritize, and create/update @IMPLEMENTATION_PLAN.md
   - When done, send `shutdown_request` via `SendMessage` and `TeamDelete` to clean up
   - If the project is small (< 10 files) or teams are not enabled, skip the team and use subagents directly instead.
2. Ultrathink. Consider TODO, minimal implementations, placeholders, skipped/flaky tests, and inconsistent patterns. Study @IMPLEMENTATION_PLAN.md to determine starting point for research and keep it up to date with items considered complete/incomplete.

IMPORTANT: Plan only. Do NOT implement anything. Do NOT assume functionality is missing; confirm with code search first. Treat `src/lib` as the project's standard library for shared utilities and components. Prefer consolidated, idiomatic implementations there over ad-hoc copies.

## Status Reporting (CRITICAL - Hank needs this!)

At the end of your response, ALWAYS include this status block:

```
---HANK_STATUS---
STATUS: IN_PROGRESS | COMPLETE | BLOCKED
TASKS_COMPLETED_THIS_LOOP: <number>
FILES_MODIFIED: <number>
TESTS_STATUS: NOT_RUN
WORK_TYPE: DOCUMENTATION
EXIT_SIGNAL: true
RECOMMENDATION: <one line summary of planning results>
---END_HANK_STATUS---
```

Planning mode always sets EXIT_SIGNAL: true (single iteration).
