---
name: skill-sharpener
description: |
  Analyze a Claude Code session transcript to find friction points with skills that
  were used, then propose targeted edits to those skills' SKILL.md files.

  Use this skill whenever the user wants to improve, tune, refine, sharpen,
  retrospect on, or learn from a Claude Code session — especially when they mention
  reviewing skill performance, skills that "didn't work right", skills the user had
  to correct, or anything about making skills better based on real usage. Trigger
  on phrases like "improve the skills I used", "what could my skills do better",
  "review this session for skill issues", "sharpen my skills", "skill retro",
  "tune my skills", or `/skill-sharpener`. Also trigger when the user expresses
  frustration with how a skill behaved and wants to fix it for next time.

  Output is a markdown proposal per skill (problems found + suggested edits) for
  user approval before any SKILL.md changes are written.
---

# Skill Sharpener

Mine session history for evidence of skill friction. Propose fixes. Let user approve before editing.

## Why This Exists

Skills are durable instructions. They get used many times across many sessions. A single bad
instruction or missing guardrail compounds. Real session transcripts contain the best signal
about what skills actually need — better than guessing or asking the user to articulate it.

But session JSONL is noisy. The user changes their mind, asks tangential questions, or
corrects Claude for reasons unrelated to the skill. Auto-editing skills from raw signal
produces churn. So this skill takes a careful approach: gather evidence, present a proposal,
let the human decide.

## Workflow

1. **Locate session** — find the JSONL file the user wants analyzed
2. **Identify skills used** — scan transcript for Skill tool invocations
3. **Gather friction signals** — find moments where the skill underperformed
4. **Group signals by skill** — one analysis per skill
5. **Propose edits** — markdown proposal with problems + suggested SKILL.md changes
6. **Get approval** — user reviews proposal, picks which edits to apply
7. **Apply approved edits** — Edit tool against SKILL.md files

No auto-edits. Every change goes through user review.

## Step 1: Locate Session

Sessions live at `~/.claude/projects/<encoded-project-path>/<session-uuid>.jsonl`.

Default: analyze the **current** session. Find the active JSONL by matching the project's
encoded path (replace `/` with `-`) under `~/.claude/projects/`, then pick the most recently
modified `.jsonl`.

Ask the user to confirm:
```
Analyze current session? (default: yes)
Or provide path to a specific session JSONL:
```

If the user passes a session UUID or partial filename, search and resolve it.

## Step 2: Identify Skills Used

Read the JSONL and scan for Skill tool invocations. The relevant events look like:

```json
{"type":"tool_use","name":"Skill","input":{"skill":"<name>","args":"..."}}
```

Build a list of unique skills invoked in the session. For each, record:
- skill name
- how many times invoked
- args passed each time
- the prompt that preceded each invocation (user's request)
- what happened after (subsequent tool calls, assistant messages, user replies)

If no skills were invoked, report that and stop. Nothing to sharpen.

## Step 3: Gather Friction Signals

For each skill invocation, look at the surrounding turns and flag these signals:

**Strong signals (skill likely needs change):**
- User corrected the assistant immediately after the skill ran ("no, do X instead", "that's wrong", "you forgot Y")
- Skill output ignored a constraint that was clearly stated in the user's prompt
- Tool errors directly traceable to skill instructions (wrong path, wrong command, wrong flag)
- User had to repeat or rephrase the same request after the skill ran
- Assistant deviated from a pattern the skill prescribed and the user accepted that deviation
- Repeated work across invocations (same helper script written twice, same lookup done twice)

**Weak signals (might be skill, might be user):**
- User changed scope mid-task
- User asked tangential questions
- Skill produced output but user picked a different option

**Not signals (ignore):**
- Normal back-and-forth refinement
- User asking for explanations
- Tool errors from environment (network, permissions) unrelated to skill instructions

For each strong signal, capture:
- Skill name
- Quote of the user's correction or the friction moment (short — one or two lines)
- Brief explanation of what the skill could have done differently
- Pointer to the part of SKILL.md that's responsible (or the gap if no instruction exists)

## Step 4: Group Signals by Skill

Skills with zero strong signals get no proposal. Skip them.

For each skill with strong signals, locate its SKILL.md. Skills live in:
- `~/.claude/skills/<name>/SKILL.md` (user-global)
- `~/.claude/plugins/cache/**/skills/<name>/SKILL.md` (plugin-installed)
- `<project>/.claude/skills/<name>/SKILL.md` (project-local)

Read the SKILL.md so the proposal can reference exact sections.

## Step 5: Propose Edits

Output one markdown proposal per skill. Use this template:

```markdown
# Sharpener Proposal: <skill-name>

**Skill path:** <absolute path to SKILL.md>
**Invocations this session:** <count>

## Friction Observed

### 1. <Short title of issue>
**Evidence (from session):**
> <quoted user correction or friction moment>

**Root cause:** <why the skill failed here — missing instruction, ambiguous wording, wrong default, etc.>

**Suggested edit:**
- Section: <heading from SKILL.md, or "new section">
- Change:
  ```
  <before>
  ```
  becomes
  ```
  <after>
  ```
- Rationale: <why this change addresses the root cause without overfitting>

### 2. <Next issue>
...

## Edits NOT Recommended

Things that looked like signals but probably aren't worth changing:
- <signal> — <why it's likely noise, not a skill problem>
```

Show all proposals to the user at once. Then ask:
```
Which edits should I apply? (e.g., "1, 3" or "all" or "none")
```

## Step 6: Apply Approved Edits

For each approved edit, use the Edit tool against the relevant SKILL.md. Make minimal changes —
don't rewrite sections that weren't flagged. Don't add hypothetical guardrails for problems the
session didn't surface.

After applying edits, show the user:
- Files changed
- Diff summary (one line per edit)
- Reminder: skill changes don't apply retroactively to past sessions

## Principles

**Bias toward fewer, better edits.** One precise change beats five speculative ones. If you're
not sure an edit is justified, skip it and tell the user why.

**Quote evidence.** Every proposed edit should cite a specific moment from the transcript. If
you can't quote evidence, you don't have a signal — drop the proposal.

**Explain the why.** Don't just say "add MUST X". Explain why the skill failed, what change
addresses the root cause, and why it won't overfit to this one session.

**Don't oversteer.** Skills get worse when they accumulate rigid `ALWAYS`/`NEVER` rules from
one-off corrections. Prefer reframing or clarifying intent over adding constraints.

**Respect skill scope.** If the friction was outside what the skill is supposed to do, that's
not a skill bug. Note it and move on.

## Edge Cases

- **Session has no Skill invocations** → report and stop. Suggest user invoke skills they want
  to evaluate, then rerun.
- **SKILL.md is read-only or in a plugin cache** → flag clearly. Plugin skills typically
  shouldn't be edited in place; suggest forking to user-global skills instead.
- **Multiple invocations of same skill, conflicting signals** → present both, let user weigh.
- **User wants to analyze a different session than current** → accept path or UUID, validate
  before reading.

## Configuration

- `SHARPENER_SESSIONS_DIR` — override session JSONL location (default: `~/.claude/projects/`)
- `SHARPENER_SKILLS_DIRS` — comma-separated list of skill search paths
