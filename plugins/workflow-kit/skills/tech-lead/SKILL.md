---
name: tech-lead
description: |
  Lead a feature from idea through design, delegated planning and implementation, PR review,
  merge follow-up, and retro while keeping resumable state in an Obsidian dossier. Use this
  whenever the user says "/tech-lead <feature>", "be the tech lead for", "start a lead",
  "resume the lead", "rehydrate the lead", "show the board", or "what's the status of
  <feature>". Also use it when supervising an existing tech-lead worker or feature dossier.
---

# Tech Lead

Own one feature while delegating execution. Keep judgment with the user at idea, design, and
PR review boundaries; keep durable state in the dossier so another session can resume safely.

## Invocation

`/workflow-kit:tech-lead [<feature>] [--from <master-plan>]`

Run from the project repository root. `<skill-dir>` is this skill's directory (the one that
holds this `SKILL.md`), not the working directory. Use `python3 <skill-dir>/scripts/dossier.py`
for dossier commands, `python3 <skill-dir>/scripts/launch.py` for launch decisions,
`python3 <skill-dir>/scripts/events.py` for worker events, and
`python3 <skill-dir>/scripts/herdr.py` for the mirror. The short names below (`dossier.py`,
`launch.py`, `events.py`, `herdr.py`) mean these paths.

1. Run `dossier.py resolve-vault --project-dir <repo>`. If it returns `source: none`, ask once
   for the vault path and suggest setting `lead.vault` in `.claude/workflow-kit.json`; do not
   edit that config.
2. With no feature, run `dossier.py list --vault <vault>`, show the leads and their stage
   counts, and stop.
3. With a feature, run `dossier.py list --vault <vault> --match <feature>`. Rehydrate an exact
   match. For an unknown feature, show `closest`, ask once whether to create it, and run
   `dossier.py init --vault <vault> --feature <feature>` only after confirmation.

Use the structure in `references/dossier.md` § "Layout", the initial documents in
`references/dossier.md` § "File templates", and the JSON interface in
`references/dossier.md` § "Command contract". This keeps discovery and creation deterministic.

## Startup

Compare the physical current directory with `git rev-parse --show-toplevel`; refuse to launch
or mutate a dossier unless they are equal. Workers inherit this directory, so starting
elsewhere would attach them to the wrong repository.

Run `herdr.py available --project-dir <repo>` for an optional herdr view of workers
(see `references/workers.md` § "Herdr mirror") and tell the user once whether it is on;
report any `warnings` once. On `skipped` or a `warning`, tell the user once and continue
without the mirror. Report a herdr.py exit 2 stderr message once and continue; it never
blocks a launch.

Run `dossier.py checks --project-dir <repo>` and print every entry in `fixes`. Advise the lead
session to use permission mode `auto`. If `permissionMode` is not `auto`, warn that workers
still launch in `auto` and cross-mode messages can stall. This check reads the configured
default and cannot see the session's actual permission mode (including a CLI override);
continue after the warning. Follow
`references/workers.md` § "Permissions and trust" for the trust and allow-rule setup.

Before each launch, apply `<skill-dir>/../implement-plan/references/routing.md`
§ "Orchestrator gate" via the launch procedure rather than inventing a model or quota rule.

## Rehydrate

Read `<feature>/brief.md`, `<vault>/Features/_project/decisions.md`,
`<feature>/decisions.md`, and the tail of `<feature>/log.md`. Read the generated board and every
active item, using `references/dossier.md` § "Item format" for field meanings. Reconcile each
active item exactly as `references/workers.md` § "Reconcile" specifies; an agent/session state
is evidence, while the item file remains authoritative.

Then print one compact briefing containing:

- the board;
- every paused item and its attach command, using the convention in
  `references/dossier.md` § "Worker names";
- every PR at `pr-ready`, including its `unplanned` count and decisions when nonzero;
- lead decisions made with decide-and-tell since the last log entry; and
- the next unblocked item you suggest.

Append a short rehydrate entry to `log.md`, regenerate the board, and sync. For live
supervision, follow `references/workers.md` § "Watch" and the bounded behavior in
`references/lifecycle.md` § "Monitor loops"; normal polling is unnecessary because the idle
subscription and item file preserve completion.

## Stages 1–3

### Idea and brainstorm (1)

Keep this stage in the lead session with the user. Bring in the brief and both decision logs,
and flag conflicts with approved decisions or active items. Do not automate or skip the
conversation: the user owns what to build.

### Design (2)

For a substantial item, draft a short note under `<feature>/designs/`; for a small item, draft
the outcome as a feature or project decision. Walk the user through
`references/design-review.md` § "Checklist", record every answer in that note or decision,
and wait for an explicit "go". Unknowns are acceptable when recorded because PR review can
then distinguish an expected choice from an unplanned one.

### Handoff plan (3)

After "go", create or update the item, then launch one `plan` worker through
`references/workers.md` § "Launch". Do not answer new questions from intuition: answer the
planner from the dossier, while the handoff worker records assumptions for anything unsettled.
The exact wrapper is documented in `references/workers.md` § "Worker protocol".

When `plan-done` arrives, run `launch.py plan-scope <plan>` and store its `files` and `modules`
arrays on the item with `dossier.py item set`; keep lists in JSON-style inline form. This gives
the overlap gate stable inputs before implementation begins.

## Stages 4–9

Read and follow these procedures rather than duplicating them here:

- stage 4: `references/lifecycle.md` § "Implement (4)";
- stage 5: `references/lifecycle.md` § "PR open (5)";
- stage 6: `references/lifecycle.md` § "Review rounds (6)";
- stage 7: `references/lifecycle.md` § "Merge (7)";
- stage 8: `references/lifecycle.md` § "After merge (8)"; and
- stage 9: `references/lifecycle.md` § "Retro (9)".

The user always reviews the PR and controls merge. These boundaries preserve the user's
judgment while the lead handles routing, CI, comment rounds, bookkeeping, and follow-up.
To drop an item, follow `references/lifecycle.md` § "Drop".

## Lead decisions

Apply decision tiers only to the lead's choices; never turn them into worker rules or approval
gates.

- Ask about a failed quota gate, ordering otherwise-ready overlapping items, and relaunching a
  `stuck` item. Pause that action without stopping unrelated work.
- Decide and tell for most other choices. Include the decision in the next notification or
  rehydrate briefing so the user can reverse it.
- Decide and log for small choices. Default conventions, architecture, tooling, and CI to
  project scope; default feature scope, design, and sequencing to feature scope. Promote a
  project-scope decide-and-log choice to decide-and-tell because it affects other leads.

When the user reverses a lead decision or an unplanned PR decision, log the reversal and ask,
"For this feature or the whole project?" Later design reviews read both decision logs, so the
answer improves future work without blocking current workers.

For a paused worker, expose its options and recommendation and follow
`references/workers.md` § "Resuming a paused worker". Never send to a worker whose agent
status is `waiting`; that reply path belongs to `claude attach`.

## Bootstrap from a master plan

With `--from <master-plan>`, draft the brief from the master plan and draft one item per
unfinished phase or sub-phase. Set each existing phase-plan path in `plan` without moving the
file, and derive `blockedBy` from the plan's ordering. Show the complete draft to the user
before the first vault sync so bootstrap does not silently reinterpret the plan.

After approval, initialize the dossier, create the items, regenerate the board, and sync the
brief, decisions, log, items, and board together.

## Dossier writes and notifications

Send every vault write through the dossier workflow: use `dossier.py item new` or `dossier.py
item set` for structured state instead of reimplementing item parsing, and after authoring a
brief, design note, decision, or log entry include its path in `dossier.py sync --vault <vault>
-m <message> --board <feature-dir> -- <paths...>`. Do not run vault git commands directly.
Treat an `ok:false` conflict or error as a user-visible stop; never force-push. Never hand-edit
`board.md` because the generated view must agree with the item files.

Use only the event names and delivery policy in `references/dossier.md` § "Events". Find the
highest installed dev-toolkit `notify-me.sh`, pass it as `--notify-cmd` to event commands and
`launch.py command`, and
call `PushNotification` only when `events.py` returns a non-null `push`. This gives desktop and
away notifications one deduplicated source. If dev-toolkit is absent, say so once and continue
with the available channel.

## Never

- Never merge a PR or force-push.
- Never skip stage 1 or the user's stage-5 PR review.
- Never pass rules, guardrail paths, or approval gates to a worker; design and PR review are
  the decision boundaries.
- Never send a message to a worker whose agent status is `waiting`.
- Never treat session or GitHub `state` as truth without item and repository evidence.
