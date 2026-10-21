---
status: planned
---
# [Plan Title]
<!-- Use a short title, at most one line. Keep the whole Overview to about one screen. -->

> **Goal:** [What the change achieves; one sentence.]
> **Size:** [Phase count · task count · affected areas; one line.]

## Summary
<!-- Explain the problem, the change, and why it matters in 2–4 sentences. -->

## What changes
<!-- List visible changes and affected areas in 3–6 short bullets. Put any Overview file detail here only. -->

- **Changed:** [Area and resulting behavior.]
- **New:** [Area and new capability.]

## Approach
<!-- Give one row per phase. Add at most one focused Mermaid diagram if it helps explain the flow. -->

| Phase | Outcome | Depends on |
|---|---|---|
| 1. [Name] | [Result] | — |
| 2. [Name] | [Result] | Phase 1 |

## Decisions & risks
<!-- Use one short bullet per decision, assumption, or risk. Omit empty categories; keep assumptions in handoff mode. -->

- **Decide before building:** [Open decision and its effect.]
- **Assumed**: **A1** [Decision the input did not state]. Source: [design note | brief | decisions | codebase | default].
- **Risk:** [Issue or edge case and how to address it.]

---

## Agent Notes
<!-- Optional: give shared codebase facts and gotchas in short bullets, one fact per bullet. Omit if none. -->

- [Fact that more than one task needs.]

## Implementation Checklist
<!-- Include every task under a phase heading. Keep each task to one responsibility and its fields to short bullets. -->

### Phase 1 — [Name]
<!-- State this phase's outcome in at most one sentence if the name needs explanation. -->

- [ ] **Task 1: [Name]**
  - **Module**: `path/`
  - **Files**: `a`, `b`
  - **Do**:
    - [What to build and why; one short bullet per action.]
    - [Input/output contract with other tasks.]
    - [What not to touch.]
  - **Done when**:
    - [ ] [Specific, verifiable criterion; one condition per line.]

- [ ] **Task 2: [Name]**
  - **Module**: `path/`
  - **Files**:
    - `c`
    - `d`
  - **Depends on**: Task 1
  - **Do**:
    - [Action that needs Task 1's output; one short bullet per action.]
  - **Done when**:
    - [ ] [Specific, verifiable criterion; one condition per line.]

### Phase 2 — [Name] (depends on Phase 1)
<!-- State this phase's outcome in at most one sentence if the name needs explanation. -->

- [ ] **Task 3: [Name]**
  - **Module**: `path/`
  - **Files**: `e`
  - **Do**:
    - [Action using Phase 1's contract; one short bullet per action.]
  - **Done when**:
    - [ ] [Specific, verifiable criterion; one condition per line.]
    - [ ] Sample recipes still render after a cleared database [e2e]

## Verification
<!-- List how to check that all pieces fit together in 2–5 short bullets, including commands and expected results. -->

- [Integration check and expected result.]

<!-- End of plan template. The rules below guide writing; do not copy them into the plan. -->

## Overview rules

Write for a reader who will not read the checklist. Use plain language. Keep the Overview
to about one screen, from the title through Decisions & risks. Use only `#` and `##`
headings there. Include no checkboxes. Keep file-level detail in What changes bullets.

Start the plan with the YAML front matter shown above. Its fences are not the
Overview/checklist divider; parsers skip front matter before finding that divider.
New plans use `status: planned`. implement-plan owns the change to `status: complete`.

## Checklist rules

Use `### Phase N — Name` headings under Implementation Checklist. Append dependencies as
` (depends on Phase X, Phase Y)` when needed. Phase headings are the source of truth;
repeat the same dependencies in the Approach table.

Use a top-level `- [ ] **Task N: Name**` line for each task. Indent field bullets two
spaces, in this order: **Module**, **Files**, **Depends on** (optional), **Do**,
**Done when**. Keep Module on one line. List backticked Files on one line or in deeper
nested bullets with one backticked path per line. Include Depends on only for tasks
in the same phase. Express cross-phase dependencies in phase headings.

Write short nested Do bullets instead of paragraphs. Put facts more than one task needs
in Agent Notes. Give each Done when criterion a nested checkbox. Keep a trailing `[e2e]`
only for a criterion that requires a running app.

Tick a criterion when it is verified. Tick a task line when all its criteria are ticked.
A phase is complete when all its task lines are ticked.

## Writing a Good Architecture Diagram

Put an optional Mermaid diagram under Approach. Include one when the dependency structure
or data flow would take a paragraph to describe. Good signals: 3+ new components interacting,
a non-obvious flow (bidirectional streams or multi-source merges), or a reader would draw
it on a whiteboard.

Skip it for a local change: patching one class, adding a model field, or wiring an endpoint
into an established pattern documented elsewhere. Use real class names from research.
Focus on the new or changed flow. Do not diagram the entire app.

- `graph TD` — component dependencies or data flow.
- `sequenceDiagram` — async interactions, such as WebSocket or multi-step auth.
- `stateDiagram-v2` — state transitions.
