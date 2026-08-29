# Report Formats (Step 10)

Referenced from `SKILL.md` Step 10. Emit the applicable block at the end of the run.

## Implementation Summary

Emit when all phases are checked off:

```markdown
# Implementation Summary

**Plan:** <plan-name>
**Orchestrator:** <tier> / <model>
**Worktree:** <path>
**Branch:** <branch-name>
**PR:** <url, or `skipped — <reason>`>

## Phases Completed
- Phase 1: <description> — sub-agent: <tier> / <model>
- Phase 2: <description> — sub-agent: <tier> / <model>
- Phase 3: <description> — sub-agent: <tier> / <model>

## Verification Status
✓ All phases passed verification

## Runtime & Models

Host: <host>
Orchestrator: <model-id>
Per-phase models:
  Phase <N> (<tier>): <model-id actually used> [ (configured: <routed-model-id>) if different ]
  …
Gate-verify: <model-id actually used>
Review: <model-id actually used>
Degradations active: <list from Step 2, or "none">
Cost: <read from TOKEN_ACCOUNTING for this run — metered spend on a metered host, or the
flat-rate equivalent-consumed note on a flat-rate host, per `references/runtimes.md`; emit
"token accounting unavailable on this host" when `TOKEN_ACCOUNTING` is unavailable. Never
estimated>

## Review & Auto-fix
- Reviewer: <tier> / <model> on `<base>...HEAD` via <REVIEW_SKILL>
- Findings: <N total> — <M auto-fixed & verified> / <K left for you>
- Auto-fixed: <one line each, file:line + what changed> — fix sub-agent: <tier> / <model>
- Left for you (below threshold): <one line each, severity + file:line + problem>
- Rounds: <R> of <REVIEW_MAX_ROUNDS>

## What's Next
- Worktree is ready at <path>
- Review code and decide: merge, iterate, or cleanup
- Skill does NOT auto-merge or cleanup — that's your call
```

## Implementation Stopped

Emit when the run hard-stopped at a phase:

```markdown
# Implementation Stopped

**Plan:** <plan-name>
**Failed Phase:** <phase-name>
**Failure Point:** verification failed every gate attempt (SELF_VERIFY_LIMIT) + escalation halted

## Error Summary
<error output from last /verify call>

## Recovery
- Review the error above
- Fix the issue manually in the worktree
- Signal ready to retry
- Skill will rerun verification on the failed phase
```
