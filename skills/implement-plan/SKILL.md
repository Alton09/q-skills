---
name: implement-plan
description: |
  Execute a plan end-to-end with automatic quality verification and task tracking.
  
  Use this skill whenever you have a structured implementation plan (markdown with 
  phases and checkboxes) and want to implement it in an isolated worktree with full 
  verification and automatic task tracking. The skill reads plans from Obsidian 
  (RDC vault by default), implements phase-by-phase sequentially, delegates quality 
  verification to the project's /verify skill, and automatically checks off completed 
  tasks in the plan document.
  
  Perfect for feature implementations, refactors, and bug fixes where you need 
  quality gates and progress visibility.
---

# Implement Plan

Turn a plan into working, verified, tested code with automatic task tracking.

## Workflow Overview

1. **Plan Selection** — read from Obsidian vault (RDC/Plans)
2. **Model Selection** — pick Sonnet (default), Haiku, or Opus
3. **Worktree Setup** — delegate to `/create-worktree` skill
4. **Phase-by-Phase Implementation** — sequential execution
5. **Quality Verification** — delegate to project's `/verify` skill
6. **Task Tracking** — check off completed phases in plan
7. **Report** — summary, worktree path, status

## Step 1: Plan Selection

List available plans from Obsidian vault:

```bash
obsidian vault=RDC files folder=Plans
```

Prompt user:
```
Available plans:
  1. add-recipe-favorites-feature
  2. fix-note-deletion-persistence
  3. offline-recipe-support

Which plan? (Enter number, or paste plan content):
```

If user already named a plan or pasted content, skip prompt and proceed.

Once selected, fetch and read the full plan:

```bash
obsidian vault=RDC read path="Plans/<plan-name>.md"
```

## Step 2: Model Selection

Prompt:
```
Which model?
  1. Sonnet 4.6 (default) — balanced speed & quality
  2. Haiku — fast, cost-effective
  3. Opus — maximum quality for complex work

Enter choice (default: 1):
```

Use selected model for implementation phase. Store choice for reference in final report.

## Step 3: Worktree Setup

Ask: "Should I create a new worktree? (y/n, default: y)"

If yes, call `/create-worktree` skill. Let the project implement worktree creation strategy (branch naming, isolation, etc.).

Confirm worktree path with user before proceeding.

## Step 4: Read Plan Structure

Plans must have this structure:

```markdown
# Feature Name

## Overview
Brief description of what's being implemented.

## Phases

### Phase 1: Foundation Setup
- [ ] Task 1a: description
- [ ] Task 1b: description

### Phase 2: Core Implementation
- [ ] Task 2a: description
- [ ] Task 2b: description
- [ ] Task 2c: description

## Tests
List of expected test coverage.

## Edge Cases
Known edge cases to handle.
```

Key: Each phase is a section with checkboxes for tasks. The skill tracks and updates these.

## Step 5: Phase-by-Phase Implementation

For each phase in the plan:

1. Read the phase tasks
2. Implement all tasks in the phase
3. After implementation, run quality verification (Step 6)
4. If verification passes, check off the phase
5. If verification fails, retry (Step 6)

**No parallelization** — phases run sequentially, one at a time.

**No sub-agents** — implement directly, inline.

## Step 6: Quality Verification

After each phase is implemented, call the project's `/verify` skill:

```
/verify
```

Expect response: `pass` or `fail`.

**Retry Logic:**
- Fail → fix issues → rerun `/verify`
- Max 3 attempts per phase
- 3rd failure → hard stop

**On Hard Stop (3x failure):**

1. Report what failed (capture error output from `/verify`)
2. Call `/notify-me` with error summary:
   ```
   /notify-me "implement-plan hard stop: Phase <N> failed verification 3x. Error: <summary>"
   ```
3. Wait for user intervention — do NOT check off phase or continue
4. User fixes issue, signals ready to retry
5. Skill resumes from the failed phase

## Step 7: Task Tracking

When a phase passes verification, check off the phase in the Obsidian plan:

```bash
obsidian vault=RDC read path="Plans/<plan-name>.md"
# (Read current content, update checkbox to [x], write back)
obsidian vault=RDC create path="Plans/<plan-name>.md" content="<updated>" overwrite silent
```

After checking off, call `/save-plan` skill (project implements):

```
/save-plan <plan-name>
```

Expect response: `pass` or `fail`. If fail, report error and stop.

Print updated plan state so user can see progress:

```
Phases completed:
✓ Phase 1: Foundation Setup
✓ Phase 2: Core Implementation
- Phase 3: Testing & Refinement (in progress)
- Phase 4: Documentation (pending)
```

## Step 8: Final Report

Once all phases are checked off:

```markdown
# Implementation Summary

**Plan:** <plan-name>
**Model:** <selected model>
**Worktree:** <path>
**Branch:** <branch-name>

## Phases Completed
- Phase 1: <description>
- Phase 2: <description>
- Phase 3: <description>

## Verification Status
✓ All phases passed verification

## What's Next
- Worktree is ready at <path>
- Review code and decide: merge, iterate, or cleanup
- Skill does NOT auto-merge or cleanup — that's your call
```

If hard-stopped due to failure:

```markdown
# Implementation Stopped

**Plan:** <plan-name>
**Failed Phase:** <phase-name>
**Failure Point:** 3x verification failure

## Error Summary
<error output from last /verify call>

## Recovery
- Review the error above
- Fix the issue manually in the worktree
- Signal ready to retry
- Skill will rerun verification on the failed phase
```

## Configuration

Projects can configure via environment or project CLAUDE.md:

- `OBSIDIAN_VAULT` — Obsidian vault name (default: `RDC`)
- `VERIFY_SKILL` — verify skill name (default: `/verify`)
- `SAVE_PLAN_SKILL` — save-plan skill name (default: `/save-plan`)
- `NOTIFY_SKILL` — notification skill (default: `/notify-me`)

## Plan Format Example

```markdown
# Feature: Recipe Favorites

## Overview
Add ability to mark recipes as favorites and filter by them.

## Phases

### Phase 1: Domain Layer
- [ ] Create Favorite use case in domain/favorites/
- [ ] Create FavoritesRepository interface
- [ ] Add unit tests for use case

### Phase 2: Data Layer
- [ ] Implement FavoritesRepositoryImpl
- [ ] Add Room entity and DAO
- [ ] Add data layer tests

### Phase 3: UI Layer
- [ ] Create FavoritesViewModel with UDF state
- [ ] Build Favorites Compose screens
- [ ] Add UI tests

### Phase 4: Integration
- [ ] Wire up navigation
- [ ] Integration tests across layers
- [ ] Manual testing (happy path + edge cases)

## Tests
- FavoritesUseCaseTest: ≥80% coverage
- FavoritesRepositoryImplTest: ≥80% coverage
- FavoritesViewModelTest: ≥80% coverage

## Edge Cases
- Favorite a recipe, then delete it from system
- Toggle favorite state rapidly
- Sync favorites across multiple devices (if applicable)
```

## Notes

- **No auto-cleanup** — worktree stays on disk until you decide (merge, delete, etc.)
- **No auto-commit** — all code is staged/uncommitted in the worktree, ready for your review
- **User review is required** — don't merge automatically, inspect first
- **Skill failures are explicit** — hard stops make it clear when user input is needed
