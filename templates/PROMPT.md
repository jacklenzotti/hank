# Hank Build Instructions

0a. Study .hank/specs/_ with up to 500 parallel Sonnet subagents to learn the application specifications.
0b. Study @IMPLEMENTATION_PLAN.md.
0c. For reference, the application source code is in `src/_`.

1. Your task is to implement functionality per the specifications using parallel subagents. Follow @IMPLEMENTATION_PLAN.md and choose the most important item to address. Before making changes, search the codebase (don't assume not implemented) using Sonnet subagents. You may use up to 500 parallel Sonnet subagents for searches/reads and only 1 Sonnet subagent for build/tests. Use Opus subagents when complex reasoning is needed (debugging, architectural decisions).
2. After implementing functionality or resolving problems, run the tests for that unit of code that was improved. If functionality is missing then it's your job to add it as per the application specifications. Ultrathink.

### When to use Agent Teams (instead of subagents)

Use a team ONLY when IMPLEMENTATION_PLAN.md has 2+ independent items that touch different files/layers (e.g., frontend + backend, or two unrelated modules). Spawn teammates for each item, coordinate as lead. Do NOT use teams when:

- Items touch the same files (merge conflicts)
- Work is sequential (item B depends on item A)
- There is only one item to work on
  For everything else, subagents are faster and cheaper.

3. When you discover issues, immediately update @IMPLEMENTATION_PLAN.md with your findings using a subagent. When resolved, update and remove the item.
4. When the tests pass, update @IMPLEMENTATION_PLAN.md, then `git add -A` then `git commit` with a message describing the changes.

5. Important: When authoring documentation, capture the why -- tests and implementation importance.
6. Important: Single sources of truth, no migrations/adapters. If tests unrelated to your work fail, resolve them as part of the increment.
7. You may add extra logging if required to debug issues.
8. Keep @IMPLEMENTATION_PLAN.md current with learnings using a subagent -- future work depends on this to avoid duplicating efforts. Update especially after finishing your turn.
9. When you learn something new about how to run the application, update @AGENTS.md using a subagent but keep it brief.
10. For any bugs you notice, resolve them or document them in @IMPLEMENTATION_PLAN.md using a subagent even if it is unrelated to the current piece of work.
11. Implement functionality completely. Placeholders and stubs waste efforts and time redoing the same work.
12. When @IMPLEMENTATION_PLAN.md becomes large periodically clean out the items that are completed from the file using a subagent.
13. If you find inconsistencies in the specs/\* then use an Opus subagent with 'ultrathink' requested to update the specs.
14. IMPORTANT: Keep @AGENTS.md operational only -- status updates and progress notes belong in IMPLEMENTATION_PLAN.md. A bloated AGENTS.md pollutes every future loop's context.

## Status Reporting (CRITICAL - Hank needs this!)

At the end of your response, ALWAYS include this status block:

```
---HANK_STATUS---
STATUS: IN_PROGRESS | COMPLETE | BLOCKED
TASKS_COMPLETED_THIS_LOOP: <number>
FILES_MODIFIED: <number>
TESTS_STATUS: PASSING | FAILING | NOT_RUN
WORK_TYPE: IMPLEMENTATION | TESTING | DOCUMENTATION | REFACTORING
EXIT_SIGNAL: false | true
RECOMMENDATION: <one line summary; include issue number e.g. #42 if working on a GitHub issue>
---END_HANK_STATUS---
```

Set EXIT_SIGNAL to true when ALL items in IMPLEMENTATION_PLAN.md are resolved, all tests pass, and all specs are implemented. Do NOT continue with busy work when EXIT_SIGNAL should be true. Do NOT run tests repeatedly without implementing new features.
