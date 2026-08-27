# Dual-Host Runtime Validation

> Stage 5 of the multi-runtime plan (`docs/plans/implement-plan-multi-runtime.md`).
> End-to-end validation of `workflow-kit:implement-plan` on both supported hosts,
> against a throwaway project with a real `/verify`.
>
> Date: 2026-08-25 · Claude Code 2.1.241 · opencode 1.18.18
> Skill under test: the **worktree** copy at
> `plugins/workflow-kit/skills/implement-plan` — never the installed
> `workflow-kit@q-skills` v2.1.0 plugin (see *Harness* for how that is guaranteed).
>
> **Findings are filed, never patched.** Nothing in `SKILL.md` or `references/` was
> edited to make a run pass. Every deviation below is recorded with its evidence
> and left for Stage 6 to triage.

---

## Summary

| | Run 1 | Run 2 | Run 3 | Run 3-rescue |
|---|---|---|---|---|
| Host | claude-code | opencode | opencode | claude-code |
| Scenario | baseline regression | baseline, new path | forced failure | rung-2 manual resume |
| Plan | 4 phases (mechanical, normal, disjoint parallel pair) | same | 2 phases (mechanical + poisoned) | resumes Run 3 |
| Outcome | **pass** — all phases green, 0 retries | **pass** — all phases green, 0 retries | **HALTED as designed** — rung 1 exhausted, rescue block emitted | **pass** — both phases finished, suite green |
| Wall clock | 427 s | 650 s | 1335 s | 649 s |
| Cost | **$2.4117** metered | **$0.5707** equivalent (flat-rate, $0 marginal) | **$0.8520** equivalent | **$2.4204** metered |

Three runs executed. Nine findings filed: **1 high, 4 medium, 2 low, 2 informational.**
The high finding (F1) is a hard blocker: as specified, `implement-plan` cannot complete
on opencode at all.

---

## Scratch Project and Throwaway Plan

`wordkit` — a ~40-line pure-Python package with a real verification command:

```
verify.sh          → python3 -m pytest -q          (the actual gate; no mocking)
wordkit/           → package under construction
tests/             → pytest suite
.claude/skills/    → verify · create-worktree · notify-me · code-review
```

The four skills are real, minimal, and non-interactive. `/create-pr` is deliberately
**absent** so the Step 9 skip-and-report path is exercised.

**Baseline plan** (Runs 1 and 2) — four phases in the checkbox format, with a
`## Task Dependency Graph` block:

| Phase | Character | Files | Scheduling |
|---|---|---|---|
| 1 — Constants module | mechanical | `wordkit/constants.py`, `tests/test_constants.py` | sequential |
| 2 — Slugify | normal | `wordkit/slugify.py`, `tests/test_slugify.py` | sequential, depends on 1 |
| 3 — Word count | mechanical | `wordkit/wordcount.py`, `tests/test_wordcount.py` | **parallel pair** with 4 |
| 4 — Title case | mechanical | `wordkit/titlecase.py`, `tests/test_titlecase.py` | **parallel pair** with 3 |

Phases 3 and 4 declare pairwise-disjoint `**Files**:` lists, so they are a legitimate
parallel group under the 5a.1 file-overlap rule.

**Forced-failure plan** (Run 3) — Phases 1 and 2 only, plus a committed frozen
contract test the implementer is told not to edit:

```python
def test_contract_hyphen_form():
    assert slugify("Hello World") == "hello-world"

def test_contract_underscore_form():
    assert slugify("Hello World") == "hello_world"
```

Unsatisfiable by construction. No implementer at any tier can pass this gate by editing
the implementation — which is the point: it makes the escalation ladder fire
deterministically instead of probabilistically.

---

## Run 1 — Claude Code, regression

**Question:** is behavior after Stages 3–4 identical to the pre-change contract?
There is no pre-change transcript to diff against, so the judgement is made two ways:
against the current `SKILL.md` contract clause by clause, and against a mechanical
pre/post diff of every documented default.

### Defaults, pre vs post

Extracted from `git show f75a0d8:…/SKILL.md` (last commit before the Stage 3 rewrite)
and the current file:

| Knob | Pre | Post |
|---|---|---|
| `SELF_VERIFY_LIMIT` | 2 | 2 |
| `PHASE_TOKEN_CEILING` | 80k / 150k / 250k | 80k / 150k / 250k |
| `PHASE_TIME_BUDGET` | 15 min | 15 min |
| `ESCALATION_ATTEMPTS` | 2 | 2 |
| `ESCALATION_TOKEN_CEILING` | 400k | 400k |
| `ESCALATION_TIME_BUDGET` | 30 min | 30 min |
| `MAX_PARALLEL_AGENTS` | 3 | 3 |
| `RUN_REVIEW` / `CREATE_PR` | true / true | true / true |
| `REVIEW_MAX_ROUNDS` | 2 | 2 |

**No default changed.** Stage 3's "behavior changes zero" claim holds for the config surface.

### Observed execution

Nine sub-agent spawns, extracted verbatim from the session transcript:

| # | Spawn | Model | Backgrounded |
|---|---|---|---|
| 1 | Parse plan into extract (prep) | `sonnet` | no |
| 2 | Phase 1 constants module | `haiku` | yes |
| 3 | Gate-verify phase 1 | `haiku` | no |
| 4 | Phase 2 slugify | `sonnet` | yes |
| 5 | Gate-verify phase 2 | `haiku` | no |
| 6 | Phase 3 word count | `haiku` | yes |
| 7 | Phase 4 title case | `haiku` | yes |
| 8 | Integration gate-verify group 3+4 | `haiku` | no |
| 9 | Review wordkit plan diff | `opus` | yes |

Every model matches `model-routing.md`'s Claude Code column for its tier. No spawn
passed `isolation`, so no worker created a worktree of its own — the
worktree-ownership rule in 5a.2 held.

**Parallel group.** Phase 3 spawned at 05:54:38 and Phase 4 at 05:54:50, both
backgrounded, both still running — genuinely concurrent, 12 s apart. They ran in
sibling child worktrees `.wt/phase3-wordcount` and `.wt/phase4-titlecase` (the
`<integration>/../.wt/<slug>` shape 5a.3 specifies), were merged `--no-ff` in declared
order, gate-verified **once** on the merged state, advanced atomically, then cleaned up
with `worktree remove` + `branch -d`. Both branch deletes succeeded, which is 5a.4's
tripwire confirming the merges landed.

**Contract clauses verified:**

- Step 0.5 — host detected as `claude-code` from `Agent` tool presence; `HOST_RUNTIME` unset.
- Step 2 — disclosure block emitted verbatim in the runtimes.md format, with
  `Degraded capabilities on this host: (none)`.
- Step 3 — integration worktree created at `project-wordkit` on `feat/wordkit`.
- Step 5 — tiers auto-classified with no user prompt; commit-per-phase honored (4 phase
  commits + 2 merge commits + 1 checkbox commit).
- Step 6 — gate-verify delegated every time, `light` tier chosen because `verify.sh` is a
  deterministic exit-code gate; 4 gates, all pass, 0 retries, 0 escalations.
- Step 7 — all 8 checkboxes flipped to `- [x]`.
- Step 8 — `opus` reviewer, 9 findings, **0** at/above `REVIEW_AUTOFIX_SEVERITY`, so no
  fix sub-agent spawned and the round loop stopped early (1 of 2).
- Step 9 — skipped and reported: no `/create-pr` skill in the project.
- Step 10 — report emitted with the mandatory `Runtime & Models` section.
- Final state: worktree clean, 16 tests green, `.wt/` gone.

**Verdict: regression pass**, with two low-severity deviations (F6, F7).

---

## Run 2 — opencode, new path

**Question:** does the new host path work at all, and does it do what the bindings say?

This run took **three attempts**. Attempts 1 and 2 both deadlocked at the first phase
agent and are the evidence for **F1**; only attempt 3, launched with a session root that
contains both worktrees, completed. The deadlock is a finding, not a harness bug — see F1.

### Observed execution (attempt 3)

Ten opencode sessions, from the DB:

| Role | Agent | Model | tok in | tok out | cost equiv |
|---|---|---|---|---|---|
| orchestrator | `build` | `qwen3.8-max` | 51,741 | 8,657 | $0.3967 |
| prep parse | `prep` | `qwen3.7-plus` | 10,295 | 1,043 | $0.0061 |
| Phase 1 (light) | `phase-light` | `kimi-k2.7-code` | 5,410 | 896 | $0.0181 |
| gate 1 | `gate-verify` | `qwen3.7-plus` | 9,114 | 133 | $0.0042 |
| Phase 2 (standard) | `phase-standard` | `glm-5.3` | 12,818 | 1,492 | $0.0506 |
| gate 2 | `gate-verify` | `qwen3.7-plus` | 2,589 | 130 | $0.0019 |
| Phase 3 (light) | `phase-light` | `kimi-k2.7-code` | 9,801 | 1,025 | $0.0231 |
| Phase 4 (light) | `phase-light` | `kimi-k2.7-code` | 10,604 | 1,178 | $0.0245 |
| integration gate | `gate-verify` | `qwen3.7-plus` | 9,121 | 128 | $0.0042 |
| review | `review` | `grok-4.5` | 10,390 | 718 | $0.0414 |
| **total (10 sessions)** | | | **131,883** | **15,400** | **$0.5707** |

`phase-light` was pinned to `kimi-k2.7-code` rather than the table default
`minimax-m3` — see *Model override* below.

**Checklist from the Stage 5 task:**

| Requirement | Result |
|---|---|
| Host detection | **pass** — "`task` tool present, no `Agent` tool → opencode"; `HOST_RUNTIME` unset |
| Step 2 disclosure | **pass** — emitted before any work, listing both opencode degradations verbatim |
| Per-role models | **pass in execution** — every named subagent ran on its pinned model (DB-confirmed); **fail in reporting** — see F3 |
| Parallel behavior per 1a | **pass** — Phases 3+4 demoted to sequential, run in the integration worktree, no child worktrees created, single integration gate-verify, atomic advance. (Whether the demotion is *warranted* is F2.) |
| Diversity rule | **pass** — implementers Kimi (`kimi-k2.7-code`) and GLM (`glm-5.3`); gate Qwen (`qwen3.7-plus`); review Grok (`grok-4.5`). Gate and reviewer are family-diverse from every implementer. |
| Checkboxes | **pass** — all 8 flipped, though in the wrong copy of the plan (F5) |
| `Runtime & Models` report | **present** — with two content errors (F3, F4) |

**Per-spawn model pinning resolved.** Stage 1a Q1 left dynamic per-spawn pinning
"UNVERIFIED". This run settles the practical question: with named subagents in
`opencode.jsonc`, a parent on `qwen3.8-max` spawned children on `qwen3.7-plus`,
`kimi-k2.7-code`, `glm-5.3` and `grok-4.5` — four distinct child models under one
parent. The config-level mechanism `runtimes.md` prescribes works exactly as written.

**Model override.** Attempt 1 used the table default `minimax-m3` for the light tier and
hung; attempt 2 used `kimi-k2.7-code` and hung identically. Because the hang reproduced
across two unrelated model families, it is not a model defect — it is F1. Attempt 3 kept
`kimi-k2.7-code` (via the harness's `OC_LIGHT` knob) purely to avoid re-testing a
variable that had already been ruled out. `minimax-m3` was separately confirmed healthy
both as a primary agent and as a spawned subagent inside the session root.

---

## Run 3 — opencode, forced failure and rung-2 rescue

**Question:** does the escalation ladder fire, switch family at rung 1, and hand off
correctly when it exhausts?

### Ladder execution

| Step | Agent | Model | Family | Outcome |
|---|---|---|---|---|
| Phase 1, attempt 1 | `phase-light` | `kimi-k2.7-code` | Kimi | self-verify fail → gate fail |
| Phase 1, attempt 2 (retry) | `phase-light` | `kimi-k2.7-code` | Kimi | gate fail |
| **Rung 1, attempt 1** | `escalation` | `qwen3.8-max` | **Qwen** | gate fail |
| **Rung 1, attempt 2** | `escalation` | `qwen3.8-max` | **Qwen** | gate fail |
| Rung 2 | — | — | — | HALTED + rescue block + notify |

- `SELF_VERIFY_LIMIT` = 2 → exactly 2 phase attempts. **Correct.**
- `ESCALATION_ATTEMPTS` = 2 → exactly 2 rung-1 attempts. **Correct.**
- Family switch Kimi → Qwen matches `model-routing.md`'s opencode rule
  ("failed implementer was Kimi family → escalation model is `qwen3.8-max`"). **Correct.**
- BLOCKED callout written to the plan *before* the escalation pass, then replaced by
  HALTED on exhaustion. **Correct** (modulo which copy — F5).
- `/notify-me` paged on hard stop with an error summary. **Correct.**

The HALTED callout was well-formed and, notably, correctly diagnosed the planted
contradiction rather than flailing:

```
> 🛑 HALTED: escalation exhausted `ESCALATION_ATTEMPTS` rung-1 rescue attempts.
> Last error: … the contract itself asserts two contradictory values for
>   slugify("Hello World") ("hello-world" and "hello_world"), proven unsatisfiable
>   by two independent deep-tier rescues.
> Worktree: …/opencode-forced-failure/project-wordkit
> Rungs run:
>   - Rung 1, attempt 1: opencode-go/qwen3.8-max (Qwen)
>   - Rung 1, attempt 2: opencode-go/qwen3.8-max (Qwen)
> Resume in Claude Code:
>   Worktree: …/opencode-forced-failure/project-wordkit
>   Failed phase: Phase 1 — Constants module
>   Models already run (rung 1): opencode-go/qwen3.8-max (Qwen), …
>   Relaunch: Open this worktree in Claude Code and run `/implement-plan` to continue
>   from this phase with full Claude Code capabilities.
```

Every element `escalation.md` requires of the rung-2 block is present.

**Scenario artifact, disclosed:** the failure trips at **Phase 1**, not Phase 2. The
frozen contract test imports `wordkit.slugify`, which Phase 2 creates, so pytest
collection fails from the very first gate. The escalation machinery is exercised
identically; only the phase the marker attaches to is an artifact of the plant.

### The manual rescue

The rung-2 instruction was then followed literally: the halted worktree was reopened in
Claude Code (`claude -p`, opus, worktree skill visible) carrying the user's decision —
that the frozen contract is genuinely self-contradictory and the resuming session is
authorized to correct it. This is the "user fixes the issue in the worktree, signals
ready to retry" step of `escalation.md`'s user-wait procedure, with the fix delegated.

**Result: the manual rung-2 rescue works end to end.** The Claude Code session picked
up the halted worktree, finished both phases, and left the plan green:

| | |
|---|---|
| Phases completed | Phase 1 (`light`/`haiku`, commit `6bd7858`), Phase 2 (`standard`/`sonnet`, commit `8984b65`) |
| Gates | 2 independent gate-verifies, both pass, 0 retries, 0 escalations |
| Checkboxes | all 5 tasks `- [x]`, committed as `5e4b230` |
| Final verify | `./verify.sh` → **9 passed**, exit 0, with the contract file collected |
| Review | `opus`, 3 findings, all below threshold → no fix pass |
| Cost | **$2.4204** metered, 649 s wall |
| Runtime & Models | present, `Degradations active: none` |

Three things about this session are worth recording because they were not scripted:

1. **It refused to fake the pass.** It had the Phase 2 agent and then the gate agent
   audit specifically against a rigged green — and reported that *a prior rescue attempt
   had tried an `__eq__` override*. That prior attempt was one of Run 3's opencode rung-1
   escalations, and the opencode gate had correctly rejected it. The two-tier gate did its
   job on both hosts; it is worth noting that a deep-tier opencode rescue reached for a
   cheat while the deep-tier Claude rescue reached for an audit.
2. **It found a second, independent defect in the plant.** The contract file imports
   `wordkit.slugify`, a Phase 2 deliverable, so Phase 1's gate was unpassable regardless
   of the contradiction. It scoped that one file out of *Phase 1's gate only*, ran Phase 2's
   gate on the full unmodified `./verify.sh`, and said so.
3. **It independently reported F5.** Unprompted: *"The previous run wrote its callout to
   the main checkout's copy … rather than the worktree's — an uncommitted edit on `main`."*
   It had to go looking for the HALTED block because the worktree it was told to open did
   not contain one.

The rung-2 boundary is therefore validated as designed: opencode detected an impasse it
could not clear, emitted a complete and accurate handoff, and a Claude Code session
resumed from that handoff and finished the work. The one defect in the chain is *where*
the handoff was written (F5), not what it said.


---

## Findings

Severity is about the finding's effect on a real run, not about how hard it is to fix.

### F1 — [high] opencode: tool calls outside the session root hang forever, and `implement-plan`'s worktree contract guarantees they happen

**Files:** `references/runtimes.md` (opencode column: `WORKTREE_CREATE`, `SPAWN_WORKER`);
`references/phase-execution.md` (worktree-ownership rule);
`docs/research/opencode-host-primitives.md` (no session-root question was asked).

opencode scopes tool execution to the session root passed as `--dir`. A **subagent** tool
call targeting a path outside that root never completes: no error, no permission prompt,
no timeout — the part row simply sits at `status: running` forever, even under `--auto`.

`implement-plan` guarantees this situation. `/create-worktree` creates the integration
worktree as a **sibling** of the project directory, and every phase agent is then pointed
at that sibling. So the first phase agent's first tool call is out of scope, and the run
deadlocks before a single line of code is written.

**Evidence.**

1. Two full runs deadlocked at Phase 1 on two unrelated model families
   (`minimax-m3`, then `kimi-k2.7-code`) — over 11 and over 7 minutes respectively, with
   zero tokens recorded, before being killed manually.
2. The stuck parts, straight from the DB:
   ```
   {"type":"tool","tool":"bash","callID":"bash_0","state":{"status":"running",
    "input":{"command":"ls -la","workdir":".../project-wordkit"}, …}}
   {"type":"tool","tool":"read","callID":"read_1","state":{"status":"running",
    "input":{"filePath":".../project-wordkit/docs/plans/wordkit.md"}, …}}
   ```
   Both remained `running` indefinitely.
3. Minimal reproduction: a parent on `qwen3.8-max` with `--dir <proj>` delegates to a
   subagent told to `ls -la` in the sibling worktree `<proj>-x` → hangs. The **identical**
   delegation with `--dir` set to the parent directory containing both → succeeds in ~30 s.

**Why it is high.** It is not a degradation, it is a deadlock, and `STOP_WORKER` is
unavailable on opencode — so the orchestrator can neither detect nor cancel it. The
runaway guard's honest weakness (documented, correctly) turns a config gap into an
unbounded hang. Run 2 attempt 1 burned 11 minutes of wall clock and produced nothing,
with the orchestrator none the wiser.

**Not fixed here.** The workaround the harness uses — launch opencode with `--dir` at a
directory containing both the project and its worktrees, and put `opencode.jsonc` there —
is a *harness* setting, not a skill edit. The binding document is what needs the rule.

---

### F2 — [medium] opencode `PACE` is bound as unavailable, but sibling subagents demonstrably run concurrently

**Files:** `references/runtimes.md` (`PACE` row, *Parallel-Group Availability* table);
`references/phase-execution.md` (PACE demotion paragraph);
`references/runaway-guard.md` (opencode section);
`docs/research/opencode-host-primitives.md` Q2.

Stage 1a Q2 concluded "empirically sequential" from the absence of overlapping sibling
sessions in 14 historical DB rows. Absence of evidence was read as evidence of absence.

**Evidence to the contrary.** A parent on `qwen3.8-max` asked to delegate two independent
tasks produced two overlapping child sessions:

```
phase-light  minimax-m3      created 1787638165834   updated 1787638173826
phase-alt    kimi-k2.7-code  created 1787638167970   updated 1787638185585
```

`phase-alt` started 2.14 s **after** `phase-light` started and 5.86 s **before** it
finished — the two overlapped for 5.86 s. The opencode CLI also rendered both as in-flight simultaneously.

**Important nuance — do not over-correct.** This proves concurrent *execution* of sibling
subagents. It does **not** demonstrate a fire-and-forget/background primitive that returns
control to the orchestrator mid-flight, which is what the 5b wall-clock guard needs. The
`PACE` capability currently bundles two distinct things:

- *parallel-group execution* — evidence says **available**;
- *timed check-ins on a running worker* — still unevidenced.

Recommend splitting the capability before changing any binding; flipping `PACE` wholesale
on this evidence would silently claim a guard that does not exist.

**Consequence today.** Run 2 never exercised the parallel-group path on opencode — no
child worktrees, no `--no-ff` merge, no atomic group advance. That entire branch of
`phase-execution.md` remains unvalidated on opencode, and opencode runs are slower than
they need to be (650 s vs 427 s for the same plan).

---

### F3 — [medium] the `Runtime & Models` report lists routing-table defaults, not the models actually used

**File:** `SKILL.md` Step 10; `references/runtimes.md` (*Step 10 — Runtime & Models Report Section*).

Run 2's report:

```
Phase 1 (light): opencode-go/minimax-m3
Phase 3 (light): opencode-go/minimax-m3
Phase 4 (light): opencode-go/minimax-m3
```

The DB for the same run shows all three ran on `opencode-go/kimi-k2.7-code` — the value
pinned in `agent.phase-light.model`. The orchestrator transcribed `model-routing.md`
instead of reading the binding it actually dispatched through.

The section exists to make routing auditable. It is unreliable exactly when an override
is in play, which is the only case where auditing matters. It also undercuts the
"unknown model ids error loudly, never substitute" principle: a report that echoes the
table can never reveal a substitution.

---

### F4 — [medium] the flat-rate cost line was fabricated, off by 13×

**File:** `SKILL.md` Step 10 Cost line; `references/runtimes.md` Step 10 spec.

Run 2 reported:

```
Cost: opencode — equivalent consumed: $7.42 of $60/mo cap
```

`SELECT SUM(cost) FROM session` over that run's 10 rows: **$0.5707**.

`runtimes.md` says where the number lives (`TOKEN_ACCOUNTING` → the opencode DB) but
never says the orchestrator must *query* it rather than estimate. Run 3's orchestrator
did query the DB (its transcript notes "Token accounting is working via `opencode db`"),
so the mechanism is reachable — the instruction is just not binding.

---

### F5 — [medium] which copy of the plan file gets updated differs per host, and it breaks the rung-2 handoff

**Files:** `SKILL.md` Step 7; `references/escalation.md` step 2.

Step 7 says "update the plan file locally … in your working directory" without naming a
copy. With an integration worktree there are always two.

- Run 1 (claude-code) wrote checkboxes to the **integration worktree** copy; the original
  repo's copy stayed unchecked.
- Runs 2 and 3 (opencode) wrote checkboxes — and the BLOCKED/HALTED callouts — to the
  **original repository** copy; the worktree copy stayed unchecked.

In Run 3 this is not cosmetic. The HALTED block instructs the user to "open this worktree
in Claude Code", but the worktree's plan contains **no HALTED marker at all**
(`grep -c HALTED` in the worktree copy: `0`). The rung-2 handoff points a resuming session
at a tree with no record of the failure it is being asked to resume from.

---

### F6 — [low] claude-code: Step 3 inlined `/create-worktree` instead of invoking it

**File:** `references/runtimes.md` (`WORKTREE_CREATE`, claude-code cell — "`Skill` tool invocation").

Run 1's transcript contains exactly one `Skill` call for the whole run (`implement-plan`).
The worktree was created by reading the skill file and running its commands directly:

```
$ … cat .claude/skills/create-worktree/SKILL.md
$ REPO="$(git rev-parse --show-toplevel)"; NAME="wordkit"; git -C "$REPO" worktree add …
```

The outcome was correct and the project's strategy was respected, so this is low. But the
binding table states a mechanism that the run did not use — either the cell should describe
the delegation loosely, or the invocation should be normative in Step 3.

---

### F7 — [low] Run 1's final report misstated the test count

The report claims "Final suite: 13 tests green via `./verify.sh`". The worktree runs
**16**. Small, but the report is the artifact the user trusts without re-checking, and no
sub-agent ran after the count that could explain the drift.

---

### F8 — [info] `SKILL.md` Step 10 carries a stale reconciliation note

Step 10 says: *"it is the section `references/runtimes.md` specifies for the final report
(that file calls it the 'Step 9' report section; this file's report is Step 10 — same
section)."* `grep -n "Step 9" references/runtimes.md` returns nothing — that file now says
Step 10. Stage 4c's harmonization fixed the reference and left the note explaining the
mismatch behind.

---

### F9 — [info] gate-verify sub-agents are spawned in the foreground; the guard's coverage of them is undefined

Run 1 spawned phase and review agents with `run_in_background: true` and every
gate-verify agent with `run_in_background: false`. `runaway-guard.md` opens by scoping
itself to "phase, retry, escalation, review, and fix agents" — gate-verify is not in the
list, so this is not a violation. But `SKILL.md` Step 6 does not say either way, so
whether the 5b guard covers the gate is undecided rather than decided. Worth one sentence.

---

## Cost and Token Totals

Per-run, measured — not estimated.

| Run | Host | Sessions / spawns | Tokens in | Tokens out | Cost | Wall |
|---|---|---|---|---|---|---|
| 1 — baseline | claude-code | 9 sub-agents | 149,769 cache-read + 3,518 cache-write + 4 | 3,816 (orchestrator) | **$2.4117 metered** | 427 s |
| 2 — baseline | opencode | 10 sessions | 131,883 | 15,400 | **$0.5707 equivalent** | 650 s |
| 3 — forced failure | opencode | 10 sessions | 161,614 | 21,435 | **$0.8520 equivalent** | 1335 s |
| 3-rescue — rung 2 | claude-code | 6 sub-agents | 169,969 cache-read + 2,623 cache-write + 4 | 3,448 (orchestrator) | **$2.4204 metered** | 649 s |

The Claude Code token columns cover the **orchestrator session only** — that host's JSON
envelope does not aggregate sub-agent usage, though `total_cost_usd` does. Sub-agent
tokens, as each run's own report accounted them: Run 1 — **158,786 across 9 spawns**
(prep 21.4k, phases 76.1k, gates 43.4k, review 17.9k); Run 3-rescue — **111,608 across 6**
(prep 19.6k, Phase 1 16.6k, gate-1 16.8k, Phase 2 22.3k, gate-2 18.5k, review 17.9k). The
opencode columns already include every child session, because each one is its own DB row —
which is why that host's accounting is the more trustworthy of the two.

Sources: Claude Code — `--output-format json` `total_cost_usd`, cross-checked against the
run's own report ($2.30 at report time, before the final turns). opencode — `SUM(cost)`
over the run's session rows in `~/.local/share/opencode/opencode.db`.

**The savings claim, measured.** Same plan, same phase shape, same real verify command:

- claude-code: **$2.41 of real metered spend**.
- opencode: **$0.57 of equivalent retail value**, against a $60/month flat-rate cap —
  i.e. **$0 marginal cash**, and ~1 % of the monthly equivalent budget.

So the flat-rate host is ~4.2× cheaper in equivalent terms and free at the margin. Two
honest caveats: opencode took **52 % longer** (650 s vs 427 s) for the same work, largely
because the parallel pair was demoted to sequential (F2 says that demotion may be
unnecessary); and this excludes the two deadlocked attempts, which on a real run would
have cost 11 minutes and produced nothing (F1).

Claude Code's `--output-format json` reports `duration_ms: 48552` and `num_turns: 2` for a
run that actually took 427 s across dozens of turns — those two fields describe the final
turn only. `total_cost_usd` is whole-session and is the number used above.

---

## Coverage — what was and was not exercised

Honest partial coverage, stated plainly.

**Not exercised, by nature of headless runs:**

- **Interactive prompts.** Steps 1, 2 and 3 ask the user questions. Both hosts were driven
  headless, so those answers were pre-supplied in the driver prompt. The
  question-and-answer path itself — `AskUserQuestion`-style interaction, and the Step 2
  "press enter to continue" confirmation — was **not** exercised on either host. What was
  exercised is that the steps run, in order, and gate the rest of the workflow.
- **User-wait resumption.** `escalation.md`'s "wait for user intervention → user signals
  ready → skill resumes" loop cannot run unattended. Run 3 reached the wait state and
  emitted the page; the wait itself was replaced by a fresh rescue session.

**Not exercised, by scenario design:**

- **opencode parallel groups** — demoted to sequential per the binding, so child
  worktrees, `--no-ff` merge, conflict handling and atomic group advance are unvalidated
  on opencode. (Fully validated on claude-code in Run 1.)
- **Claude Code escalation ladder** — Run 1 had no gate failures, and Run 3's ladder ran
  on opencode. Rung 1 on claude-code (deep-tier re-run, family switch a no-op) is
  untested end-to-end.
- **Review auto-fix** — both baseline runs produced only below-threshold findings, so the
  fix sub-agent and the review↔fix round loop never ran. Triage and threshold gating
  *were* exercised, including the early stop at round 1 of 2.
- **Step 9 `/create-pr`** — no such skill in the scratch project. The skip-and-report path
  was exercised on both hosts; the delegation path was not.
- **Runaway guard trips** — no phase approached `PHASE_TOKEN_CEILING` or
  `PHASE_TIME_BUDGET` (largest phase: 20.3k against an 80k light ceiling). The guard's
  *absence* on opencode was however observed live and expensively (F1).
- **`HOST_RUNTIME` override and the loud-failure paths** — detection was exercised only
  via toolset inspection, with `HOST_RUNTIME` unset on both hosts. Unknown-host,
  ambiguous-toolset, and unknown-model-id halts are unvalidated.

**Method caveats:**

- Run 1's regression verdict is against the `SKILL.md` contract plus a pre/post diff of
  documented defaults — not a transcript diff, because no pre-change transcript exists.
- Run 3's planted failure trips at Phase 1 rather than Phase 2 (see above). The ladder is
  exercised identically; the attachment point is an artifact.
- The opencode `PACE` counter-evidence (F2) comes from a purpose-built canary, not from a
  full `implement-plan` run. No run has yet executed a parallel group on opencode.

**Whole validation pass:** $4.83 of real metered Claude spend + $1.42 of opencode
equivalent (billed $0), 3,061 s of wall clock, four host sessions. That is the recurring
cost of re-validating any future change to this skill — which is what the harness exists
to keep bounded.

---

## Harness

`scripts/validate-runtimes.sh` — the whole loop in one script, so re-validating after any
skill change is one command per host.

```
scripts/validate-runtimes.sh <host> [scenario] [command]

  host      claude-code | opencode
  scenario  baseline | forced-failure | resume
  command   all (default) | setup | run | collect
```

It scaffolds the `wordkit` project with its real skills, writes the throwaway plan for the
scenario, configures the host, runs it headless under a portable wall-clock cap, and
collects observable evidence — worktrees, branches, commits, checkbox state, a real
`./verify.sh` in every worktree, notifications, and per-run cost.

**The property that matters most:** it always runs the **worktree** copy of the skill,
never the installed plugin.

- claude-code: symlinks `plugins/workflow-kit/skills/implement-plan` into the scratch
  project's `.claude/skills/`, and passes `--setting-sources project` so user settings —
  and with them the installed `workflow-kit@q-skills` v2.1.0 plugin and the global
  `prefer-cheap-subagents` hook — are not loaded at all. Verified: a probe session resolved
  `implement-plan` to the worktree path and listed no other q-skills plugin skills.
- opencode: writes an `opencode.jsonc` whose `skills.paths` lists the worktree's skill
  directories **and** the project's own — because a project-local `skills.paths` *replaces*
  the global one rather than merging. Verified: `opencode debug skill` resolved
  `implement-plan` to the worktree path.

Per-role opencode models are pinned as named subagents and are individually overridable
(`OC_PREP`, `OC_LIGHT`, `OC_STANDARD`, `OC_DEEP`, `OC_VERIFY`, `OC_REVIEW`, `OC_FIX`,
`OC_ESCALATION`) so a catalog regression can be routed around without touching the skill.

The opencode session root is `RUN_DIR`, the parent of both the project and its worktrees —
this is the F1 workaround, and it is commented as such in the script so nobody "cleans it
up" back into a deadlock.

**Adding a host** takes four functions: `configure_<host>`, `run_<host>`, `cost_<host>`,
and the name in `KNOWN_HOSTS`. Nothing else in the script is host-specific.

Smoke status: `bash -n` clean; dry-run scaffold verified for both hosts × both scenarios,
and argument validation rejects unknown hosts, scenarios and commands. Exercised for real
six times: three completed runs, the rung-2 rescue, and the two opencode attempts that
surfaced F1.

---

## Re-validation after fix commit 270089f

> Date: 2026-08-27 · Claude Code 2.1.247 · opencode 1.18.18  
> Skill under test: worktree copy at `plugins/workflow-kit/skills/implement-plan` (commit 270089f)  
> Fix under test: F1–F5 + F8 (committed 2026-08-27 09:25 CDT)  
> Harness: `scripts/validate-runtimes.sh` (updated by the same commit — no harness bugs blocked any run)

The four confirmations called for by the fix author were executed in this order:

| Run | Label | Host | Scenario | Wall | Cost |
|---|---|---|---|---|---|
| RV3 | rv3-opencode-narrow | opencode | narrow halt (F1 halt path) | 204 s | $0.189 equiv |
| RV1 | rv1-claude-code-baseline | claude-code | regression | 454 s | **$3.0612 metered** |
| RV2 | rv2-opencode-baseline | opencode | baseline + OC_LIGHT override | 744 s | $0.7144 equiv |
| — | (initial RV2 attempt, killed by tool timeout) | opencode | — | ~590 s | $0.5322 equiv |

**All four confirmations pass.** One new finding (F10) was filed: catalog drift in the opencode review model.

---

### Confirmation 1 — F1 (opencode): end-to-end and halt path

**F1 end-to-end (RV2).** The harness launched opencode with `--dir rv2-opencode-baseline`
(the parent directory containing both `project/` and the sibling worktrees it creates). All
four phases completed; 19 tests passed; no subagent deadlock.

Evidence from RV2 `collected.txt`:

```
project-wordkit  18525c3 [feat/wordkit]
19 passed in 0.03s
```

Phase-1 gate-verify session in DB:
```
ses_fbc46711bffe | gate-verify | qwen3.7-plus | tok_in: 4369, tok_out: 229 | $0.0030
```

The session root check at Step 0.5 correctly fired a PASS note — not a halt:

```
Session root /private/tmp/.../rv2-opencode-baseline contains project/ and its worktree
siblings → PATH_SCOPE precondition is satisfied.
```

**F1 halt path (RV3 — brand new, first exercise).** A deliberately-narrow run was launched
with `--dir` pointing at the project directory itself (not its parent). The skill halted at
Step 0.5, before any plan parse, worktree creation, or worker spawn, in **204 s** (well
inside the 5-minute wall-clock cap). Timeout = regression-to-hang; no timeout occurred.

Exact halt output from `artifacts/report.txt`:

```
Step 0.5 PATH_SCOPE precondition **failed** — the run halts here, before plan parse,
worktree creation, or any worker spawn.

Session root does not contain the project's worktree parent — this host confines every
worker tool call to the session root, and implement-plan's worktrees are siblings of the
project repo. Relaunch with the session root set to the directory containing both
(opencode: `--dir <parent-of-project>`). Halt.
```

Evidence detail:
- Session root checked: `.../rv3-opencode-narrow/project`
- Project git toplevel resolved to same path; its parent `.../rv3-opencode-narrow` is
  outside the root
- No child sessions spawned (DB: one `build` session, $0.189 equiv, 0 child rows)
- Recovery instructions in report correctly name the parent path

**Verdict: PASS (both sub-tests).**

---

### Confirmation 2 — F5 (both hosts): worktree copy is the one that gets updated

Checked on RV1 (claude-code) and RV2 (opencode) via harness `collect` grep output.

**Claude Code (RV1):**
```
--- project/docs/plans/wordkit.md        ← original checkout
- [ ] Create wordkit/constants.py …     ← all unchecked
- [ ] Implement slugify …
…
--- project-wordkit/docs/plans/wordkit.md ← integration worktree
- [x] Create wordkit/constants.py …     ← all checked
- [x] Implement slugify …
…
```

Commit `89f3f94` ("plan: check off Phases 3 and 4") is on `feat/wordkit` — the worktree
branch — not on `main`. The original checkout's plan file is entirely unchecked.

**opencode (RV2):**
```
--- project/docs/plans/wordkit.md        ← original checkout
- [ ] Create wordkit/constants.py …     ← all unchecked
…
--- project-wordkit/docs/plans/wordkit.md ← integration worktree
- [x] Create wordkit/constants.py …     ← all checked
…
```

Commit `18525c3` ("Mark all phases complete") is on `feat/wordkit`. The orchestrator's
mid-run transcript confirms: "Checking off Phase 1 (Step 7) in the worktree's plan copy."
Original checkout unchanged.

This is the direct reversal of the Stage 5 F5 finding, where opencode wrote to the original
checkout and the worktree had no HALTED marker.

**Verdict: PASS on both hosts.**

---

### Confirmation 3 — F3/F4 (opencode with OC_LIGHT override): actual model reported; cost from DB

RV2 was launched with `OC_LIGHT=opencode-go/kimi-k2.7-code`. The routing table default for
the light tier is `minimax-m3`. The Step 10 `Runtime & Models` section of the RV2 report:

```
Per-phase models (actual, cross-checked against opencode DB session rows):
  Phase 1 (light): opencode-go/kimi-k2.7-code (configured routing default: minimax-m3 — local opencode.jsonc override)
  Phase 2 (standard): opencode-go/glm-5.3
  Phase 3 (light): opencode-go/kimi-k2.7-code (configured routing default: minimax-m3 — local override)
  Phase 4 (light): opencode-go/kimi-k2.7-code (configured routing default: minimax-m3 — local override)
Gate-verify: opencode-go/qwen3.7-plus (all 5 gate runs)
```

DB cross-check — every `phase-light` row:
```
ses_fbc4728f7ffe | phase-light | kimi-k2.7-code | $0.0212
ses_fbc43d47dffe | phase-light | kimi-k2.7-code | $0.0230
ses_fbc429c39ffe | phase-light | kimi-k2.7-code | $0.0293
```

All three phase-light sessions ran on `kimi-k2.7-code` (not `minimax-m3`). The report
correctly identifies the override with the exact format `(configured routing default: minimax-m3)`.

Cost line from report:
```
Cost: $0.6180 measured across this run's 11 DB sessions (equivalent consumed of $60/mo
flat-rate cap, not billed): $0.4689 orchestrator (mid-run figure — turns after the query
not included) + $0.1491 sub-agents.
```

DB total post-run: `SUM(cost) = $0.7144` across 11 sessions. The $0.0964 difference is the
orchestrator's final turns writing the report — not an estimation error, but the honest
mid-run read the spec describes. The report explicitly labels this: "mid-run figure — turns
after the query not included."

**Verdict: PASS.** The F3 fix (report actual model, not routing table) and the F4 fix
(cost from DB, not estimated) both hold under an override.

---

### Confirmation 4 — Claude Code regression (RV1)

RV1 ran the full 4-phase baseline on claude-code (model: opus).

**Step 0.5 path-scope check:** No "Session root" line appeared in the disclosure; no halt
triggered. Report disclosure block:

```
Degradations active: none
```

The spec requires claude-code to skip the `PATH_SCOPE` check entirely (unrestricted host).
That is what happened — no check, no halt, no disclosure line for the session root. ✓

**Actual models reported (F3):** Every model in the Step 10 section was an actual model name,
not a tier alias transcribed from the routing table:

```
Orchestrator: opus
Prep parse: sonnet
Phase 1 (light):    haiku
Phase 2 (standard): sonnet
Phase 3 (light):    haiku
Phase 4 (light):    haiku
Gate-verify: haiku
Review: opus
```

Note: "All models that actually ran match the configured routing for this host — no overrides
or substitutions occurred." So there is no `(configured: …)` suffix here — correctly absent
when actual == configured.

**Measured cost (F4):**
```
Cost: $2.93 measured session spend (harness budget meter) … Per-sub-agent token totals
(measured, from completion notifications): 154,009 tokens across 9 sub-agents …
```

Final harness-measured total: `total_cost_usd: $3.0612` (includes orchestrator turns written
after the in-skill report read). The report's $2.93 is a partial, correctly labeled. ✓

**F5 (worktree copy):** See Confirmation 2 above — claude-code now writes to the worktree
copy. Confirmed.

**Everything else behaviorally unchanged:** 4 phases, 9 sub-agents, parallel Phases 3+4 in
sibling child worktrees (`.wt/phase-3-wordcount`, `.wt/phase-4-titlecase`), merged `--no-ff`,
`branch -d` confirmed on both after merge, single integration gate-verify, 16 tests pass,
review ran (0 auto-fixes, 6 below-threshold findings), Step 9 skipped (no `/create-pr`).

**Verdict: PASS.** Regression holds; no behavioral regressions introduced.

---

### F10 — [low] opencode: `grok-4.5` model catalog drift; `grok-4.6` required

**Observed in:** RV2 (rv2-opencode-baseline), Step 8.

The harness default for `OC_REVIEW` is `opencode-go/grok-4.5`. When the review subagent was
spawned, opencode returned: *"Model not found: opencode-go/grok-4.5. Did you mean: grok-4.6?"*

The skill **correctly applied the loud-failure rule** ("unknown model ids error loudly and are
never substituted") — Step 8 was halted entirely rather than falling back to an undocumented
substitute. Report excerpt:

```
Review: FAILED TO SPAWN — configured REVIEW_MODEL opencode-go/grok-4.5 is unknown to the
host catalog (host suggests grok-4.6). Halted per the loud-failure rule: unknown model ids
error loudly and are never substituted. Step 8 was not run; no silent fallback occurred.
```

DB confirmation: `review | grok-4.5 | tokens_in: 0, tokens_out: 0, cost: $0.000` — the
session row was created but zero tokens consumed, consistent with an immediate spawn error.

**Impact:** Implementation phases completed correctly; only the post-implementation review was
skipped. The loud-failure mechanism is validated as working. The underlying issue is catalog
drift: `grok-4.5` has been superseded by `grok-4.6` in the opencode catalog.

**Harness workaround** (per harness design — routed around without touching the skill):
`OC_REVIEW=opencode-go/grok-4.6`. The fix for future validation runs is to update the
`OC_REVIEW` default in `scripts/validate-runtimes.sh` and the `model-routing.md` opencode
review default. Filed here; not patched.

---

### Parallel groups on opencode — out of scope (noted, not tested)

The `PACE` binding for opencode deliberately stays sequential (binding rationale recorded in
`references/runtimes.md` *Parallel-Group Availability*). The parallel-group path on opencode
(child worktrees, `--no-ff` merge, atomic advance) remains unvalidated on that host. No test
was run for this; the out-of-scope decision was the fix author's. Noted here for completeness.

---

### Updated cost table

Full per-run cost history including this revalidation pass.

| Run | Host | Scenario | Sessions | Tokens in | Tokens out | Cost | Wall |
|---|---|---|---|---|---|---|---|
| 1 — baseline | claude-code | regression | 9 sub-agents | 149,769 cache-read + 3,518 cache-write + 4 | 3,816 orch | **$2.4117 metered** | 427 s |
| 2 — baseline | opencode | new path (attempt 3) | 10 sessions | 131,883 | 15,400 | **$0.5707 equiv** | 650 s |
| 3 — forced failure | opencode | escalation | 10 sessions | 161,614 | 21,435 | **$0.8520 equiv** | 1335 s |
| 3-rescue — rung 2 | claude-code | manual rescue | 6 sub-agents | 169,969 cache-read + 2,623 cache-write + 4 | 3,448 orch | **$2.4204 metered** | 649 s |
| RV1 — baseline | claude-code | regression (post-fix) | 9 sub-agents | 176,862 cache-read + 3,959 cache-write + 4 | 4,226 orch | **$3.0612 metered** | 454 s |
| RV2 — baseline | opencode | new path + OC_LIGHT override | 11 sessions | 118,419 | 17,251 | **$0.7144 equiv** | 744 s |
| RV3 — narrow halt | opencode | F1 halt path (1 orch session) | 1 session | 40,210 | 1,778 | **$0.189 equiv** | 204 s |
| (initial RV2, killed) | opencode | — | 11 sessions | 112,900 | 14,413 | **$0.5322 equiv** | ~590 s |

**This revalidation pass total:** $3.0612 metered Claude + $1.4356 opencode equivalent (billed $0), ~1,990 s wall clock.

**Cumulative total (all passes):** $7.8933 metered Claude + $3.6605 opencode equivalent (billed $0), ~5,051 s wall clock.

---

### Self-check

| Check | Result | Evidence |
|---|---|---|
| Confirmation 1a — F1 end-to-end | **PASS** | RV2: 4 phases, 19 tests, no deadlock; session root precondition logged as satisfied |
| Confirmation 1b — F1 narrow halt | **PASS** | RV3: halted at Step 0.5 in 204 s with exact spec message; no workers spawned |
| Confirmation 2 — F5 worktree copy | **PASS** | RV1 + RV2: original checkout all `[ ]`, worktree copy all `[x]`, checkbox commit on worktree branch |
| Confirmation 3 — F3/F4 model+cost | **PASS** | RV2: light-tier phases show `kimi-k2.7-code (configured: minimax-m3)`; cost $0.618 from DB |
| Confirmation 4 — Claude Code regression | **PASS** | RV1: no path-scope halt; actual models in report; $2.93 measured (final $3.06) |
| New finding filed | **DONE** | F10: grok-4.5 catalog drift; loud-failure rule applied correctly |
| No SKILL.md or references/ edits | **DONE** | Only this addendum committed |

All four confirmations have explicit pass/fail + evidence. No gaps remaining.
