# Quota-Aware Routing

Referenced from `SKILL.md` Steps 5, 6, and 8. Before each worker spawn, the orchestrator
runs `scripts/route-target.sh`, which reads a JSON routing config and `quota-axi --json`, and
returns the first target in the role's ordered list that still has budget. Routing is off
when no config file exists: with neither file present, every role resolves exactly as it did
before routing. The orchestrator itself is never re-routed; it runs on the session model.

The target choice is made by the script, not by orchestrator judgment. Use the `target` it
returns; do not redo its quota math.

## Config file

Version 1 schema, with the shipped model ids:

```json
{
  "version": 1,
  "minBudgetPercent": 15,
  "minBudgetPercentByRole": { "review": 25 },
  "routing": {
    "phase": {
      "light":    ["codex:gpt-5.6-luna",  "claude:haiku"],
      "standard": ["codex:gpt-5.6-terra", "claude:sonnet"],
      "deep":     ["codex:gpt-5.6-sol",   "claude:opus"]
    },
    "gateVerify": ["codex:gpt-5.6-luna", "claude:sonnet"],
    "review":     ["pi:opencode-go/grok-4.6", "claude:opus"],
    "prFix":      ["codex:gpt-5.6-terra", "claude:sonnet"]
  }
}
```

- Locations: user file `~/.claude/workflow-kit.json`; project file
  `<repo>/.claude/workflow-kit.json`. The project file overrides the user file.
- Override is at list level, never inside a list. Each of `routing.phase.light`,
  `routing.phase.standard`, `routing.phase.deep`, `routing.gateVerify`, `routing.review`, and `routing.prFix`
  that the project file defines replaces the user value; lists it omits still come from the
  user file. `minBudgetPercent` and each `minBudgetPercentByRole.<role>` key replace the same
  way.
- Targets use the `executor:model` syntax from `references/executors.md`; the executor is
  `claude`, `pi`, or `codex`. An unprefixed target means `claude:<id>`.
- Valid role keys for `minBudgetPercentByRole` are `phase`, `gateVerify`, `review`, and `prFix`.
- Threshold for a role: `minBudgetPercentByRole[role]`, else `minBudgetPercent`, else the
  shipped defaults: 15 for every role, 25 for `review`. Review needs the headroom: one
  full-diff Codex review took 22% of a Plus 5-hour window (measured 2026-09-18).
- Fix workers use the list of the phase tier they fix. Escalation is not in the file.
- `prFix` is the role for the `address-pr` skill's fix workers (it calls the router with
  `--role prFix`). It has no tier. Resolution order: project `routing.prFix`, user
  `routing.prFix`, project `routing.phase.standard`, user `routing.phase.standard`. A dedicated
  `prFix` list in either file beats a `phase.standard` list in either file. On fallback to
  `phase.standard` the router adds the warning `no routing.prFix list; using
  routing.phase.standard`. Its threshold key is `minBudgetPercentByRole.prFix`, else
  `minBudgetPercent`, else 15.

## Precedence

Highest first:

1. Explicit per-role settings: `PHASE_MODEL_<TIER>` for that tier, `PHASE_EXECUTOR` for all
   tiers, `VERIFY_AGENT_MODEL`, `REVIEW_MODEL` or `REVIEW_EXECUTOR`. Source: the environment,
   the invocation, or project CLAUDE.md. A set value pins that role to one target with no
   quota check; do not call the router for it.
2. Project file (`<repo>/.claude/workflow-kit.json`).
3. User file (`~/.claude/workflow-kit.json`).
4. Shipped defaults (SKILL.md Configuration).

## Calling the router

**When.** Before every phase, retry, fix, gate-verify, and review spawn that no explicit
setting pins. Never once per run: a long run can use up Codex partway through, and a fresh read
before each spawn moves the remaining work to the fallback. Parallel phases call it once
each; they may see the same snapshot and all pick the same target.

**How.** One call per spawn:

```bash
<skill-dir>/scripts/route-target.sh --role phase|gateVerify|review|prFix [--tier light|standard|deep] \
  [--exclude-executor <claude|pi|codex>]... \
  --project-dir <run-root> [--user-config <file>] [--quota-json <file>]
```

`<run-root>` is the repo root the run started from, resolved once at startup. Always pass it.

- `--role` is `phase`, `gateVerify`, `review`, or `prFix`. Fix workers use `--role phase` with the
  tier of the work they fix.
- `--tier` is required with `--role phase` and rejected for the other roles, `prFix` included.
- `--exclude-executor` removes every target of that executor before evaluation; repeat the
  flag for more than one. On the `review` call, pass `--exclude-executor codex` whenever any
  phase or fix spawn record in this run used a `codex:*` target, so routing cannot produce a
  reviewer the codex reviewer refusal would reject.
- Pinned codex reviewer: when the resolved reviewer is pinned to codex (`REVIEW_EXECUTOR=codex`
  or a `codex:*` `REVIEW_MODEL`), the review call is skipped, so the rule above never fires.
  Pass `--exclude-executor codex` on every `--role phase` call instead (phase, retry, and fix
  spawns), so routing cannot put a codex implementer under the pinned codex reviewer. The
  startup refusal cannot catch this: it runs before any phase has been routed.
- `--project-dir` is always passed, as `<run-root>`. Without it the script defaults to the git
  toplevel of the current directory, which is a child or integration worktree that lacks an
  uncommitted `<run-root>/.claude/workflow-kit.json`, so the project file would be skipped
  silently. The default (empty outside a repo) exists for by-hand checks only.
- `--user-config` defaults to `$HOME/.claude/workflow-kit.json`.
- `--quota-json` reads quota-axi output from a file instead of running quota-axi. It exists
  for tests and by-hand checks; the orchestrator does not pass it in a real run.
- A usage error (or missing `jq`) exits 2 with a message on stderr. Every other handled
  outcome exits 0 and prints exactly one JSON line on stdout. An unexpected crash can exit
  non-zero or leave stdout empty; see § "Fail-safe". The script never spawns anything and never
  writes files.

**Output.** One line, for example:

```json
{"target":"claude:sonnet","source":"user","quota":"ok","percent":85,
 "reason":"preferred codex:gpt-5.6-terra, skipped: codex 9% < 15%",
 "skipped":[{"target":"codex:gpt-5.6-terra","why":"codex 9% < 15%"}],
 "warnings":[]}
```

| Field | Meaning |
|---|---|
| `target` | Chosen `executor:model`, or `null` when the caller must use its shipped default (no config, invalid config, no list for this role, or the list is empty after exclusions). |
| `source` | `project`, `user`, `none`, or `invalid`. `project` only when this call's resolved list came from the project file. |
| `quota` | `ok` or `unavailable` (quota-axi could not be read). |
| `percent` | The chosen target's effective percent remaining, or `null`. |
| `reason` | Text for the report parenthesis. First target wins: `<provider> <percent>%` (for example `opencode-go 54%`). Earlier target skipped: `preferred <first target>, skipped: <why of first skip>`. |
| `skipped` | List of `{"target","why"}` for each target passed over. |
| `warnings` | List of one-line strings. |

**Using the result.**

- `target` non-null: spawn it through the executor registry in `references/executors.md`,
  exactly as if the user had set it.
- `target: null`: resolve as before routing, from the shipped defaults.
- Non-zero exit, empty stdout, or a stdout line that is not JSON: print stderr once and treat
  the result as `target: null` (§ "Fail-safe").
- Print each entry in `warnings` once, as a single line. Do not repeat a warning that already
  printed earlier in the run.
- Record `target`, `reason`, and `warnings` in the spawn record, beside the model. The Step 10
  report reads them from there.

## Budget rules

Per target, after `--exclude-executor` matches are removed:

- **Provider mapping.** `claude:*` maps to quota-axi provider `claude`; `codex:*` to `codex`;
  `pi:<prov>/<model>` to `<prov>` (for example `opencode-go`). A pi provider that quota-axi
  does not report is unknown state.
- **One quota read per call:**
  `timeout 20 quota-axi --json --no-credential-refresh --provider <comma list of mapped providers>`.
  `--no-credential-refresh` is mandatory: a worker spawn must not trigger a vendor login
  renewal as a side effect. No other quota-axi invocation is allowed.
- **Provider state.** Provider absent from the output, `state.status` not `fresh`, or
  `state.stale` true: the target is unknown, not out of budget. Why text:
  `<provider> state <status>`. An unknown target is skipped unless it is the last one in the
  list.
- **Claude and Codex** (`quotaSemantics.status` is `known`): use the first
  `effectiveAvailability` entry with `scope` `all_models`, else the first entry. Percent is
  `effectivePercentRemaining` (already the worst of the 5-hour and weekly windows); runway is
  `runway.status`.
- **OpenCode Go** (`quotaSemantics.status` is not `known`): percent is the minimum
  `percentRemaining` across `windows`; runway is `unknown`. No windows: unknown state.
  Measured 2026-10-05: rolling 100%, weekly 100%, monthly 54%, so effective 54%.
- **Usable** when percent is at or above the role's threshold and runway is not
  `exhausted_now`. Skip why texts: `<provider> <p>% < <threshold>%` or
  `<provider> exhausted_now`.
- **Runway values** (quota-axi 0.1.44 `dist/src/types.d.ts`, checked 2026-10-06):
  - `through_reset`: every window reaches its reset before running out. Usable.
  - `projected_exhaustion`: at the current pace quota runs out before reset. Usable above
    the threshold, because one worker spawn is short next to the runway; the script adds the
    warning `<provider> projected to exhaust before reset`.
  - `exhausted_now`: skip.
  - `unknown`: percentage check alone.
- **Selection.** Pick the first usable target. If nothing is usable, pick the last target
  and add the warning `all targets below budget; using last target <target>`.

## Fail-safe

Routing never stops a run.

- Router failure: on a non-zero exit, empty stdout, or a non-JSON line, print its stderr once
  and treat the result as `target: null`, resolving from the shipped defaults. This covers
  usage errors, a missing `jq` (exit 2), and mid-script crashes.
- quota-axi missing, non-zero exit, timeout, or unparseable output: `quota` is
  `unavailable`, the first target in the list is chosen, and the warning is
  `quota-axi unavailable: <short cause>; using first target`.
- Every target below budget: the last target is chosen (the Claude fallback in the usual mix)
  with a warning.
- Invalid config: `source` is `invalid`, `target` is `null`, and one warning names the file
  and the problem. Invalid means the file does not parse, `version` is not 1, a list is not
  an array of strings, or a target names an executor other than `claude`, `pi`, or `codex`.
  Resolve from the shipped defaults.
- A real rate limit mid-worker stays with the runaway guard (`references/runaway-guard.md`)
  and escalation; routing does not handle it.

## What routing does not change

- Escalation stays forced `claude:opus` (`references/escalation.md`); the file does not route
  it.
- E2E keeps `E2E_MODEL`.
- The orchestrator model is untouched.
- Reviewer diversity still applies after routing: the codex reviewer refusal (a resolved
  codex reviewer may not check a `codex:*` implementer) and the pi family-switch rule are
  checked on the routed target, and the policy cannot route around them. Gate verify is the
  exception: the list order wins, so the same executor may implement and verify.
- Codex device reservation rules (`references/executors.md` § "Executor entries") apply to
  whatever codex target routing picks.

## Report format

The router's `reason` goes in parentheses on the Step 10 model lines:

```
Phase 3 (standard): claude:sonnet (preferred codex:gpt-5.6-terra, skipped: codex 9% < 15%)
Review: pi:opencode-go/grok-4.6 (opencode-go 54%)
```

A role pinned by an explicit setting prints `(pinned)` instead. List any `warnings` the
router returned for the run. F3 still applies: the model id comes from the spawn record, never
from the config file or a default.
