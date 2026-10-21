---
name: feature-plan
description: >
  Create structured implementation plans for features and bug fixes, saved for use
  with the implement-plan skill.
  Use this skill whenever the user asks to "create a plan", "make an implementation plan",
  "plan this feature", "plan this work", "break this into tasks", "help me plan", or any
  request involving planning, task decomposition, or organizing work into parallelizable steps
  — even if they don't say "plan" explicitly but are describing a multi-step change they want
  broken down first before building. Also use it for "plan from this design note", "handoff plan",
  or to plan for the project manager without questions.
---

# Feature Plan

Create a plan with a short Overview for people and an Implementation Checklist for agents.
Save it so the `implement-plan` skill can pick it up.

## Invocation

```
/workflow-kit:feature-plan [--handoff <design-note-path | summary text>] [--context <path>]... [--out <path>] [--worker]
```

- `--handoff`: Use handoff mode. The input is a design note file or a short summary.
- `--context <path>`: Read extra files, for example the brief and `decisions.md`.
- `--out <path>`: Save the plan there. It wins over `/save-plan` and the cwd fallback.
- `--worker`: The lead launched this run. It changes only how this skill asks, as described in
  `../implement-plan/references/worker-mode.md` § "Asking the user". Handoff mode asks
  nothing, so this changes only how a non-handoff run asks.

## Step 1: Gather Context

In handoff mode, ask no questions. Read the `--handoff` input and every `--context` file. If a
fact is missing, decide it and record the decision as an assumption in the plan.

Outside handoff mode, if the user already described the feature or bug in their message, proceed
directly to research. Otherwise, ask:

1. What needs to be built or changed?
2. Any known modules, files, or tickets involved?

Keep it to 1–2 questions max. CLAUDE.md and the codebase are often enough context.

## Step 2: Research

Before writing a single task, understand the scope:

1. Read `CLAUDE.md` — source of truth for architecture rules, quality thresholds, and conventions
2. Invoke `/clean-architecture` — get the latest layer rules, patterns, and conventions for
   this codebase before making any structural decisions. Task instructions should reference
   `/clean-architecture` rather than restating its rules.
3. Read relevant source files for the feature area
4. Identify which components need to be created vs modified
5. Identify dependencies between components — which tasks must finish before others can start

The research phase exists so the plan contains real file paths and real class names, not
placeholders. A plan that says "create a service" is less useful than one that says
"create `PropertyDetailsService` in `src/services/`".

**API research (conditional):** After reading source files, check whether the plan
touches any external APIs, libraries, or framework-specific patterns that may have
version-sensitive behavior. Skip entirely for pure business logic changes.

If API surface is involved and `/research` is available:

1. Invoke `/research` for each distinct API surface to check for latest docs,
   deprecated alternatives, migration paths, and version-specific constraints.
2. Incorporate findings into task instructions.

If `/research` is not available, skip the lookup and record it under **Risk** in
Decisions & risks.

## Step 3: Write the Plan

Derive a plan key from the title — lowercase kebab-case, 3–5 words
(e.g., `add-saved-search-alerts`, `fix-notes-persistence`, `websocket-gating`).

Read `references/plan-template.md`. Copy the template from its front matter through
Verification, then follow its Overview rules, Checklist rules, and diagram guidance.
Keep the Overview to about one screen. Put execution detail in the checklist.

Put context in Summary. Record assumptions under **Assumed** in Decisions & risks;
keep `A<n>` identifiers and sources, required in handoff mode. Put integration checks in
Verification. Put risks and considerations under **Risk** in Decisions & risks.

## Writing Good Task Instructions

Write as if handing off to a capable engineer who hasn't seen the rest of the conversation:

- Write short **Do** bullets with real file paths, class names, and function names from research
- Write verifiable **Done when** criteria as nested checkboxes
- Define input/output contracts between tasks so sequential work integrates cleanly
- Call out what NOT to change if there's risk of overlap with sibling tasks
- Keep scope tight — one clear responsibility per task
- Do not plan a guard test (Konsist, lint, ArchUnit) that only bans a dependency the same plan
  removes. Once the dependency is gone, the compiler already rejects its imports, so the test
  guards nothing

Tag a **Done when** criterion with a trailing `[e2e]` when only a running app can settle it:

```markdown
  - **Done when**:
    - [ ] Sample recipes still render after a cleared database [e2e]
```

Do not tag criteria that a build, unit test, or static check can settle.

## Step 4: Save the Plan

If `--out` is present, save the plan there. It wins over `/save-plan` and the cwd fallback.
When saving through `--out`, feature-plan never runs git in the plan's directory; the lead
commits and pushes the plan.

Otherwise, invoke `/save-plan` with the plan key and plan content.

If `/save-plan` is not available, fall back to writing the plan to the working directory:

```bash
<plan-key>.md  # in current working directory
```

Tell the user which path was used.

## Step 5: Report

After saving, tell the user:
1. Where the plan was saved
2. Brief Overview summary and checklist counts: phases, tasks, and what each phase covers
3. Any risks or open questions they should decide before implementing
4. In handoff mode, how many assumptions the plan records

With `--worker`, end the final reply with this line:

```
feature-plan: done <plan path>
```
