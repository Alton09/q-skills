# Quota-Aware Routing

Referenced from `SKILL.md` Steps 1, 5, 6, and 8. Before each worker spawn, the orchestrator
runs `scripts/route-target.sh`, which reads the merged `routing` lists through
`scripts/config.py` and quota through `quota-axi --json`, and returns the first target in the
role's ordered list that still has budget. Every role has a shipped list in `config.py`, so
routing runs with or without a config file. The orchestrator itself is never re-routed; it
runs on the session model.

The target choice is made by the script, not by orchestrator judgment. Use the `target` it
returns; do not redo its quota math.

## Config file

The routing part of `workflow-kit.json` (schema v2), shown with the shipped lists from
`config.py`:

```json
{
  "version": 2,
  "minBudgetPercent": 15,
  "minBudgetPercentByRole": { "review": 25, "orchestrator": 10 },
  "routing": {
    "phase": {
      "light":    ["claude:haiku"],
      "standard": ["claude:sonnet"],
      "deep":     ["claude:opus"]
    },
    "gateVerify":   ["claude:sonnet"],
    "review":       ["claude:opus"],
    "prep":         ["claude:sonnet"],
    "e2e":          ["claude:sonnet"],
    "orchestrator": ["claude:opus"]
  }
}
```

An ordered fallback list puts the preferred target first, for example
`"standard": ["codex:gpt-5.6-terra", "claude:sonnet"]`. § "Example lists" has blocks to copy.
`routing.prFix` has no shipped list (see `prFix` below).

- Locations: user file `~/.claude/workflow-kit.json`; project file
  `<repo>/.claude/workflow-kit.json`. `config.py` is the one reader and merger; the router
  reads its `dump`. `version` may be `1`, `2`, or absent; a v1 file's keys are a subset of v2.
- Merge: objects merge key by key, project over user over shipped defaults. Lists replace
  whole, never inside a list: a project `routing.phase.light` replaces the user and shipped
  `light` lists, while `standard` and `deep` still come from the user file or the defaults.
  `minBudgetPercent` and each `minBudgetPercentByRole.<role>` key replace the same way.
- Pins: a list with one target is a pin, for example `"review": ["claude:opus"]`. A pin still
  passes the quota check: the router reads its quota, reports it, and adds the usual
  warnings, then picks it because it is the last (only) target. No variable pins a role.
- Targets use the `executor:model` syntax from `references/executors.md`; the executor is
  `claude`, `pi`, or `codex`. An unprefixed target means `claude:<id>`. `config.py` rejects
  an unknown executor or an empty model.
- Roles: `phase` (per tier), `gateVerify`, `review`, `prFix`, `orchestrator`, `prep`, and
  `e2e`. `prep` routes the Step 1 plan-parse agent; its targets must be `claude:*` because
  the prep agent runs through the Agent tool. `e2e` routes the Step 8 E2E worker; any
  executor is allowed, the fresh-evidence check in `references/review-autofix.md` guards
  foreign targets, and a codex target follows `implementPlan.e2e.codexDeviceMode`.
- Valid role keys for `minBudgetPercentByRole` are the seven roles above.
- Threshold for a role: a file-set `minBudgetPercentByRole[role]`, else a file-set
  `minBudgetPercent`, else the shipped `minBudgetPercentByRole[role]` (25 for `review`, 10 for
  `orchestrator`), else the shipped `minBudgetPercent` (15). Review needs the headroom: one
  full-diff Codex review took 22% of a Plus 5-hour window (measured 2026-09-18).
- Fix workers use the list of the phase tier they fix. Escalation is not in the file.
- `prFix` is the role for the `address-pr` skill's fix workers (it calls the router with
  `--role prFix`). It has no tier. Resolution: the merged `routing.prFix` from either file,
  else the merged `routing.phase.standard` (project, user, or shipped). A dedicated `prFix`
  list in either file beats a `phase.standard` list in either file. When the fallback
  `phase.standard` list came from a file, the router adds the warning `no routing.prFix list;
  using routing.phase.standard`. Its threshold key is `minBudgetPercentByRole.prFix`, else
  `minBudgetPercent`, else 15.

## Precedence

Highest first, per key:

1. Project file (`<repo>/.claude/workflow-kit.json`).
2. User file (`~/.claude/workflow-kit.json`).
3. Shipped defaults in `scripts/config.py` (`config.py defaults` prints them).

Nothing else sets a target: no environment variable, CLAUDE.md line, or invocation flag pins
a role, and every routed spawn calls the router. `config.py legacy-check` (SKILL.md Step 0)
warns when an old variable is still named; the run ignores it.

## Calling the router

**When.** Before every prep, phase, retry, fix, gate-verify, review, and E2E spawn. The
escalation rescue is the only worker spawn without a router call. Never once per run: a long run can use up Codex partway through, and a fresh read
before each spawn moves the remaining work to the fallback. Parallel phases call it once
each; they may see the same snapshot and all pick the same target.

**How.** One call per spawn:

```bash
<skill-dir>/scripts/route-target.sh --role phase|gateVerify|review|prFix|orchestrator|prep|e2e [--tier light|standard|deep] \
  [--exclude-executor <claude|pi|codex>]... \
  --project-dir <run-root> [--user-config <file>] [--quota-json <file>]
```

`<run-root>` is the repo root the run started from, resolved once at startup. Always pass it.

- `--role` is `phase`, `gateVerify`, `review`, `prFix`, `orchestrator`, `prep`, or `e2e`. Fix
  workers use `--role phase` with the tier of the work they fix.
- `--tier` is required with `--role phase` and rejected for the other roles, `prFix`,
  `orchestrator`, `prep`, and `e2e` included.
- `--exclude-executor` removes every target of that executor before evaluation; repeat the
  flag for more than one. On the `review` call, pass `--exclude-executor codex` whenever any
  phase or fix spawn record in this run used a `codex:*` target, so routing cannot produce a
  reviewer the codex reviewer refusal would reject.
- Codex-only reviewer: when every target in the merged `routing.review` list is `codex:*`,
  the reviewer is certain to be codex and the review call cannot exclude it. Pass
  `--exclude-executor codex` on every `--role phase` call instead (phase, retry, and fix
  spawns), so routing cannot put a codex implementer under that reviewer. When a phase tier
  list is also all `codex:*`, the run is refused at startup (SKILL.md § "Reviewer diversity").
- `--project-dir` is always passed, as `<run-root>`. Without it the script defaults to the git
  toplevel of the current directory, which is a child or integration worktree that lacks an
  uncommitted `<run-root>/.claude/workflow-kit.json`, so the project file would be skipped
  silently. The default (empty outside a repo) exists for by-hand checks only.
- `--user-config` defaults to `$HOME/.claude/workflow-kit.json`.
- `--quota-json` reads quota-axi output from a file instead of running quota-axi. It exists
  for tests and by-hand checks; the orchestrator does not pass it in a real run.
- A usage error (or missing `jq` or `python3`) exits 2 with a message on stderr. Every other
  handled outcome, a `config.py` error included, exits 0 and prints exactly one JSON line on
  stdout. An unexpected crash can exit
  non-zero or leave stdout empty; see § "Fail-safe". The script never spawns anything and never
  writes files.

**Output.** One line, for example:

```json
{"target":"claude:sonnet","source":"user","quota":"ok","percent":85,
 "reason":"preferred codex:gpt-5.6-terra, skipped: codex 9% < 15%",
 "skipped":[{"target":"codex:gpt-5.6-terra","why":"codex 9% < 15%"}],
 "warnings":[],"usable":true,"resetsAt":"2026-10-07T10:03:45.000Z"}
```

| Field | Meaning |
|---|---|
| `target` | Chosen `executor:model`. `null` only when no targets remain after `--exclude-executor`; the caller then uses the role's first target from `config.py defaults`. |
| `source` | `project`, `user`, or `default`: the layer this call's list came from (for the `prFix` fallback, the layer of `routing.phase.standard`). `default` also after a `config.py` error. |
| `quota` | `ok` or `unavailable` (quota-axi could not be read). |
| `percent` | The chosen target's effective percent remaining, or `null`. |
| `reason` | Text for the report parenthesis. First target wins: `<provider> <percent>%` (for example `opencode-go 54%`). Earlier target skipped: `preferred <first target>, skipped: <why of first skip>`. |
| `skipped` | List of `{"target","why"}` for each target passed over. |
| `warnings` | List of one-line strings. |
| `usable` | `true` when the chosen target passed the budget rules. `false` when it was taken as the last-target fallback (all targets below budget) or as an unknown-state last target. `null` when `target` is null or quota is unavailable. |
| `resetsAt` | For a known claude or codex target, the `resetsAt` of the window named first in the chosen entry's `limitingWindowIds`. `null` otherwise. |

**Using the result.**

- `target` non-null: spawn it through the executor registry in `references/executors.md`.
- `target: null`: use the role's first target from `config.py defaults`
  (`routing.phase.<tier>[0]` for a phase or fix call), and record `shipped default` as the
  reason.
- Non-zero exit, empty stdout, or a stdout line that is not JSON: print stderr once and use
  the same shipped default (§ "Fail-safe").
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

## Orchestrator gate

`--role orchestrator` is for the pm (project manager) skill. It checks Claude quota before the lead
launches a `claude --bg` worker. implement-plan never re-routes its own orchestrator: only the
lead calls this role, once before each launch.

- It takes no `--tier` (exit 2 if given).
- List resolution: the merged `routing.orchestrator` (project, user, then the shipped
  `["claude:opus"]` with `source: "default"`), like every other role.
- Every target must be `claude:*`, because `claude --bg` runs only Claude models. A
  `routing.orchestrator` entry with another executor is a `config.py` error, so the router
  warns and routes on the shipped lists (§ "Fail-safe").
- Threshold: `minBudgetPercentByRole.orchestrator`, then `minBudgetPercent`, then the built-in
  10. The general `minBudgetPercent` comes before the built-in 10, as for every other role.
- The lead reads `usable` and `resetsAt`. `usable: false` means the quota gate failed: the
  lead does not launch and says, for example, "Claude at 8%, resets in 3h", using `percent`
  and `resetsAt`. `usable: null` means quota could not be read; the lead treats that as not
  blocked and notes it.

## Fail-safe

Routing never stops a run.

- Router crash: on a non-zero exit, empty stdout, or a non-JSON line, print its stderr once
  and use the role's first target from `config.py defaults`, with a routing warning in the
  report. This covers usage errors, a missing `jq` or `python3` (exit 2), and mid-script
  crashes.
- `config.py` error (a file edited into an invalid state after pre-flight): the router adds
  the warning `invalid config: <file>: <key>: <problem>; using shipped defaults`, routes on the
  shipped lists, and reports `source: "default"`. A mid-run edit never stops a run; the same
  error at Step 0 stops pre-flight instead (SKILL.md Step 0).
- quota-axi missing, non-zero exit, timeout, or unparseable output: `quota` is
  `unavailable`, the first target in the list is chosen, and the warning is
  `quota-axi unavailable: <short cause>; using first target`.
- Every target below budget: the last target is chosen (the Claude fallback in the usual mix)
  with a warning.
- A real rate limit mid-worker stays with the runaway guard (`references/runaway-guard.md`)
  and escalation; routing does not handle it.

## What routing does not change

- Escalation stays forced `claude:opus` (`references/escalation.md`); the file does not route
  it.
- E2E is routed: the Step 8 worker comes from `routing.e2e` (`--role e2e`), shipped
  `["claude:sonnet"]`.
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

A spawn the router did not choose prints why instead: `(escalation)` for the forced
`claude:opus` rescue, `(shipped default)` after `target: null` or a router crash. List any
`warnings` the router returned for the run. F3 still applies: the model id comes from the spawn record, never
from the config file or a default.

## Example lists

Copy a block into the project or user file. Each one replaces only the lists it names; the
others keep their merged values. Add a Claude target at the end of any list to fall back when
that provider runs low, as in § "Config file".

pi workers with a Grok reviewer. Grok is family-diverse from every pi phase model here
(MiniMax, GLM, Qwen). `grok-4.6` was not in the bake-off (`grok-4.5`, which passed all three
canaries, is not exposed by pi):

```json
{
  "version": 2,
  "routing": {
    "phase": {
      "light":    ["pi:opencode-go/minimax-m3"],
      "standard": ["pi:opencode-go/glm-5.3"],
      "deep":     ["pi:opencode-go/qwen3.8-max"]
    },
    "review": ["pi:opencode-go/grok-4.6"]
  }
}
```

codex workers. Keep the shipped `claude:opus` reviewer: a codex reviewer may not check codex
implementers (SKILL.md § "Reviewer diversity"):

```json
{
  "version": 2,
  "routing": {
    "phase": {
      "light":    ["codex:gpt-5.6-luna"],
      "standard": ["codex:gpt-5.6-terra"],
      "deep":     ["codex:gpt-5.6-sol"]
    }
  }
}
```

A codex reviewer over pi workers, the cheap family-diverse pairing to evaluate: the pi phase
block above with `"review": ["codex:gpt-5.6-sol"]` (not `gpt-6-astra`, for the Plus-window cost
in § "Config file").
