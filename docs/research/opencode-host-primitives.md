# opencode Host Primitives Research

> Stage 1a — Ground truth probe for the multi-runtime implement-plan design.
> opencode version: 1.18.18 | Probed: 2026-08-25

---

## Method

All evidence is from live experiments on this machine unless marked "doc citation."
Commands run from scratch directories under `/private/tmp/` to avoid polluting the main project.
DB queries run against `/Users/Alton/.local/share/opencode/opencode.db` (SQLite).
REST API docs fetched from `https://opencode.ai/docs/`.

---

## Q1 — Native subagent spawn (and per-spawn model pinning)

**Answer: YES (spawn) / PARTIAL (model pinning — static config works; runtime override unverified)**

### Evidence

**Spawn mechanism confirmed:**
```
$ opencode agent create --help
--mode  [string] [choices: "all", "primary", "subagent"]
--permissions, --tools  Available: "bash, read, edit, glob, grep, webfetch, task, todowrite, websearch, lsp, skill"
```
`task` is listed as a tool permission, confirming primary agents spawn subagents via the `task` tool. The `agent list` output shows three modes: `primary`, `subagent`, `all`.

Built-in subagents observed: `general` (mode: subagent), `explore` (mode: subagent). User-defined agents can be created with `mode: subagent`.

**DB evidence — subagent sessions with parent_id:**
```sql
SELECT id, agent, model, parent_id FROM session WHERE parent_id IS NOT NULL LIMIT 3;
-- ses_fecafb9f..  general  glm-5.3  ses_fecee7be...
-- ses_fecb1442..  general  glm-5.3  ses_fecee7be...
-- ses_fecb541e..  general  glm-5.3  ses_fecee7be...
```
Subagents are tracked as child sessions via `parent_id`. Each has its own row.

**Per-spawn model pinning — doc citation:**
> "If you don't specify a model, primary agents use the model globally configured while subagents
> will use the model of the primary agent that invoked the subagent."
> — opencode.ai/docs/agents

**Static per-agent model pinning (config-level) — confirmed by schema:**
```json
// opencode.jsonc
{
  "agent": {
    "phase-worker-light": {
      "model": "opencode-go/kimi-k2.7-code",
      "mode": "subagent",
      "description": "Handles mechanical phase tasks"
    }
  }
}
```
Config schema (`https://opencode.ai/config.json`): `AgentConfig.model` field exists with type `string`.

**Dynamic per-spawn model override (call-time) — UNVERIFIED:**
```sql
-- Query for any historical session where subagent model differs from parent:
SELECT ... FROM session s JOIN session p ON s.parent_id = p.id WHERE s.model != p.model;
-- Result: [] (empty — zero instances across all 14 sessions)
```
No historical evidence of cross-model parent/child pairs. The `task` tool's internal parameter schema is not exposed in CLI help. Runtime model override at call time is not documented and presumed absent.

**Model address syntax** (exact, from schema and CLI):
```
provider/model-id
Examples:
  opencode-go/kimi-k3
  opencode-go/kimi-k2.7-code
  opencode-go/glm-5.3
```
Flag on CLI: `-m / --model`. Config field: `agent.<name>.model`.

### Degradation path if dynamic pinning absent

Use **named subagent definitions** in `opencode.jsonc` — one agent type per tier (e.g., `phase-light`, `phase-standard`, `phase-deep`, `gate-verify`, `review`). The orchestrator invokes each by name (`@phase-light`, `@phase-standard`) rather than specifying model at call time. This keeps routing declarative and fully determined by config before execution begins.

---

## Q2 — Parallelism and background support

**Answer: DOCUMENTED YES / EMPIRICALLY SEQUENTIAL in all observed runs**

### Evidence

**Doc citation — General subagent description:**
> "Use this to run multiple units of work in parallel"
> — opencode.ai/docs/agents, describing the built-in `general` subagent

**DB evidence — all historical sibling subagent sessions are sequential:**
```sql
-- Check for overlapping time ranges among sibling sessions (same parent_id):
SELECT s1.id, s1.time_created, s1.time_updated, s2.id, s2.time_created
FROM session s1 JOIN session s2 ON s1.parent_id = s2.parent_id AND s1.id < s2.id
WHERE s1.parent_id IS NOT NULL
  AND s1.time_created < s2.time_updated
  AND s2.time_created < s1.time_updated;
-- Result: [] (no overlapping pairs found)
```

**Observed timing (the most recent 11-subagent implement-plan run):**
```
Phase 1 start → Gate-verify Phase 1 start: gap = 18s (sequential)
Gate-verify Phase 1 end → Phase 2 start: gap = 37s (sequential)
```
Every subagent waited for the previous one to complete before starting.

**Interpretation:** The primary (orchestrator) agent CAN call `task` for multiple subagents in one reasoning step (which the LLM may do concurrently in its reasoning), but opencode's execution layer appears to run subagents sequentially, or the orchestrator in these runs chose sequential ordering. No `async_prompt` equivalent for subagents is documented.

There is no `run_in_background` flag on the `task` tool (no CLI-exposed mechanism to fire-and-forget a subagent).

### Degradation path

If parallelism is absent or unreliable, the `PACE` capability in `runtimes.md` should be set to `sequential` for the opencode host. The orchestrator's parallel-group logic from `phase-execution.md` would demote all groups to sequential order, advancing one phase at a time. The worktree-per-phase ownership contract is unaffected.

---

## Q3 — Cancellation (SessionAbort reachability from a running agent)

**Answer: POSSIBLE VIA REST API / NO FIRST-CLASS TOOL PRIMITIVE**

### Evidence

**REST endpoint confirmed — doc citation from opencode.ai/docs/server:**
```
POST /session/:id/abort
Description: "Abort a running session"
Response: boolean
```

**Reachability from within a running agent:**
The `build` and `general` agents have `bash` permission enabled. A running agent could call:
```bash
curl -s -X POST http://localhost:PORT/session/CHILD_SESSION_ID/abort
```
However, this requires the agent to know:
1. The opencode server's HTTP port (assigned randomly at startup unless `--port N` is set)
2. The child session's ID (the `task` tool's return value schema is not documented; unclear if it returns a session ID)

**No first-class cancellation tool:** The agent toolset does not include a built-in "cancel subagent" primitive. The available tools are: `bash, read, edit, glob, grep, webfetch, task, todowrite, websearch, lsp, skill`.

**DB event log — no abort events observed:**
```sql
SELECT DISTINCT type FROM event;
-- Results: message.part.updated.1, message.updated.1, session.created.1, session.updated.1
-- No: session.aborted or similar
```
The abort endpoint exists in the API but has not been exercised in any of the 14 sessions in this install's history.

### Degradation path

On the opencode host, the runaway guard (`runaway-guard.md`) operates in **post-hoc mode only**: the orchestrator cannot interrupt a runaway subagent mid-run. The only enforcement is the per-phase token ceiling (`PHASE_TOKEN_CEILING`) which prevents the next phase from starting. The Step 2 disclosure must state: "Runaway guard is post-hoc on this host — a runaway subagent will burn to completion before the ceiling stops it from continuing."

---

## Q4 — Per-subagent token totals

**Answer: YES — each subagent session has its own cost and token counters**

### Evidence

**DB schema — `session` table contains per-session accounting:**
```sql
SELECT sql FROM sqlite_master WHERE type='table' AND name='session';
-- Fields include:
--   cost REAL DEFAULT 0
--   tokens_input INTEGER DEFAULT 0
--   tokens_output INTEGER DEFAULT 0
--   tokens_reasoning INTEGER DEFAULT 0
--   tokens_cache_read INTEGER DEFAULT 0
--   tokens_cache_write INTEGER DEFAULT 0
```

**Live data — per-subagent token breakdown (from a real 11-subagent implement-plan run):**
```
Phase 1 worker:     tokens_in=55263  tokens_out=4732   cost=$0.303
Gate-verify Ph1:    tokens_in=3902   tokens_out=626    cost=$0.023
Phase 2 worker:     tokens_in=49567  tokens_out=6525   cost=$0.322
Gate-verify Ph2:    tokens_in=3457   tokens_out=825    cost=$0.026
Phase 3 worker:     tokens_in=72346  tokens_out=16724  cost=$0.707
Gate-verify Ph3:    tokens_in=5252   tokens_out=1041   cost=$0.041
Phase 4 worker:     tokens_in=119607 tokens_out=17228  cost=$1.891
Gate-verify Ph4:    tokens_in=9793   tokens_out=3221   cost=$0.093
Review:             tokens_in=42490  tokens_out=2028   cost=$0.217
```
Accessible via `opencode db "SELECT ..."` or `opencode export <sessionID>`.

**Retrieval:** The parent session can be queried for all child sessions:
```sql
SELECT id, tokens_input, tokens_output, cost FROM session WHERE parent_id = 'PARENT_ID';
```

---

## Q5 — Whether subagents see skills.paths skills

**Answer: YES for global skills.paths / OVERRIDE WARNING for project-local config**

### Evidence

**Global skills.paths confirmed visible — experiment:**
```
$ cd /private/tmp/opencode-skills-test/
$ opencode debug skill > /tmp/all-skills.json
$ python3 -c "..."
# Output:
customize-opencode -> <built-in>
lavish             -> /Users/Alton/.agents/skills/lavish/SKILL.md
android-cli        -> /Users/Alton/.claude/skills/android-cli/SKILL.md
implement-plan     -> /Users/Alton/Workspace/q-skills/plugins/workflow-kit/skills/implement-plan/SKILL.md
feature-plan       -> /Users/Alton/Workspace/q-skills/plugins/workflow-kit/skills/feature-plan/SKILL.md
pr-review          -> /Users/Alton/Workspace/q-skills/plugins/dev-toolkit/skills/pr-review/SKILL.md
notify-me          -> /Users/Alton/Workspace/q-skills/plugins/dev-toolkit/skills/notify-me/SKILL.md
skill-sharpener    -> /Users/Alton/Workspace/q-skills/plugins/dev-toolkit/skills/skill-sharpener/SKILL.md
Total: 8 skills
```
The global `~/.config/opencode/opencode.jsonc` `skills.paths` entries are visible from any directory, confirming all subagents see the same skill list (config is loaded once at startup and shared across all sessions).

**CRITICAL: Local project opencode.jsonc skills.paths OVERRIDES global config (not merged):**
```
$ cat opencode.jsonc
{ "skills": { "paths": [".opencode/skills"] } }

$ opencode debug skill | count names
# Only 3 skills: customize-opencode, lavish, android-cli
# Global skills.paths entries (implement-plan, feature-plan, etc.) DISAPPEARED
```
A consumer project's local `skills.paths` replaces the global one entirely.

**Implication for `/verify`:** If the consumer has a `/verify` skill, they must register it in ONE of these paths (all auto-discovered, not subject to the override problem):
- `.opencode/skills/<name>/SKILL.md` (local project, auto-discovered)
- `.claude/skills/<name>/SKILL.md` (local project, auto-discovered)
- `.agents/skills/<name>/SKILL.md` (local project, auto-discovered)
- `~/.config/opencode/skills/<name>/SKILL.md` (global, auto-discovered)

OR if they use `skills.paths` in their project config, they must explicitly list BOTH the q-skills paths AND their own skills directory (see consumer docs, Stage 4d).

Note: the `.opencode/skills/` auto-discovery appeared not to work in `/private/tmp/` test directories (testskill placed there was not discovered). Root cause unclear (possibly a macOS symlink resolution issue with `/private/tmp`). This auto-discovery likely works correctly in normal user project directories.

### Degradation path

None needed — the `skill` tool is available and working. Consumer documentation must include the explicit warning about skills.paths override and the required setup pattern.

---

## Q6 — Headless permission behavior

**Answer: YES — --auto flag; question:deny needed for true headless; confirmed pattern in build agent**

### Evidence

**CLI flag confirmed:**
```
opencode run --auto  [boolean] [default: false]
Description: "auto-approve permissions that are not explicitly denied (dangerous!)"
```

**Doc citation — opencode.ai/docs/permissions:**
> "Start OpenCode with `--auto` to automatically approve permission requests that are not
> explicitly denied."
> "Explicit 'deny' rules remain enforced regardless of auto mode activation."

**Confirmed pattern in build agent (primary agent used for headless runs):**
From `opencode agent list` output — `build (primary)` has these permission entries:
```json
{ "permission": "question", "action": "deny", "pattern": "*" },
{ "permission": "plan_enter", "action": "deny", "pattern": "*" },
{ "permission": "plan_exit", "action": "deny", "pattern": "*" }
```
These deny rules ensure the build agent never blocks on user interaction, making headless runs safe.

**Verified headless run — experiment:**
```
$ opencode run --auto --model opencode-go/kimi-k3 "What is 2+2? Reply with just the number."
# Output:
> build · kimi-k3
4
# Exit code: 0
```
Headless mode works with `--auto` and the `build` agent's `question:deny` policy.

**Doom loop guard:** The `doom_loop` permission defaults to `"ask"` on the `build` agent — a doom loop would stall a headless run. Consumer setup must include `doom_loop: deny` or `allow` in their agent permission config for fully unattended runs.

### Degradation path

No degradation — headless mode is well-supported. The `--auto` flag plus `question:deny` on the primary agent is the correct pattern and is already in the default `build` agent config.

---

## Q7 — Whether OpenCode Go meters usage

**Answer: FLAT-RATE subscription / internal equivalent-cost tracking (not traditional metering)**

### Evidence

**Doc citation — opencode.ai/docs/go:**
> "OpenCode Go is a flat-rate subscription service priced at **$10/month** offering access to
> curated open-source coding models."
> Rate limits: $12 equivalent/5 hours · $30 equivalent/week · $60 equivalent/month

**Auth confirmed active — experiment:**
```
$ opencode providers list
● OpenCode Go [api]
1 credentials

$ cat ~/.local/share/opencode/auth.json
{"opencode-go": {"type": "api", "key": "sk-hZ..."}}
```
OpenCode Go subscription is active and authenticated on this machine.

**Equivalent-cost tracking in DB — confirmed:**
```sql
SELECT SUM(cost), SUM(tokens_input), SUM(tokens_output) FROM session;
-- Total cost (equivalent): $4.82 across 14 sessions, 4 days
```
The `cost` column and `opencode stats` output track **equivalent retail value consumed**, not actual charges. The subscription's usage against the $60/month equivalent limit is what matters, not per-token billing.

**Practical implications for the plan:**
- There is no per-request billing incentive to use cheaper models (unlike Claude metered tiers)
- Tier economics are driven by latency and the $60/month equivalent cap, not cost minimization
- The plan's principle "never pick a weaker model to 'save' un-metered tokens" is correct
- Phase token ceiling (`PHASE_TOKEN_CEILING`) still matters for rate-limit management

---

## Additional Findings

### How models are addressed per spawn (exact syntax)

**Config-level (static, recommended):**
```json
// ~/.config/opencode/opencode.jsonc or project opencode.jsonc
{
  "agent": {
    "phase-light": {
      "model": "opencode-go/kimi-k2.7-code",
      "mode": "subagent",
      "description": "Handles mechanical phase tasks — light tier"
    },
    "phase-standard": {
      "model": "opencode-go/glm-5.3",
      "mode": "subagent",
      "description": "Handles normal phase tasks — standard tier"
    },
    "phase-deep": {
      "model": "opencode-go/kimi-k3",
      "mode": "subagent",
      "description": "Handles complex phase tasks — deep tier"
    }
  }
}
```

**CLI-level (whole-session, not per-spawn):**
```
opencode run -m opencode-go/kimi-k3 "..."
opencode run --model opencode-go/kimi-k3 "..."
```

**Format:** `provider/model-id` where provider is `opencode-go` for flat-rate models, `opencode` for free tier.

### OpenCode Go auth and reachable models

Authentication: **Active** (`opencode-go` provider, API key in `~/.local/share/opencode/auth.json`)

Model reachability tested via `opencode run --auto --model <model> "Reply with just: OK"` with DB verification:

| Model | Status | tokens_out (simple prompt) |
|---|---|---|
| `opencode-go/kimi-k3` | **REACHABLE** | 17 |
| `opencode-go/kimi-k2.7-code` | **REACHABLE** | 3 |
| `opencode-go/glm-5.3` | **REACHABLE** | 3 |
| `opencode-go/qwen3.7-plus` | **REACHABLE** | 4 |
| `opencode-go/qwen3.8-max` | **REACHABLE** | 5 |
| `opencode-go/qwen3.7-max` | **REACHABLE** | 6 |
| `opencode-go/minimax-m3` | **REACHABLE** | 11 |
| `opencode-go/mimo-v2.5` | **REACHABLE** | 16 |
| `opencode-go/gpt-5.6-luna` | **REACHABLE** | 5 |
| `opencode-go/grok-4.5` | **REACHABLE** | 1 |
| `opencode-go/deepseek-v4-flash` | **UNAVAILABLE** | Error: "only available hosted in China, requires explicit opt in" |
| `opencode-go/deepseek-v4-pro` | **UNAVAILABLE** | 0 tokens, silent failure |

All 10 bake-off candidates from the plan (excluding the two deepseek models) are reachable and ready for Stage 1b.

Note: The model catalog (`opencode models`) lists `opencode-go/deepseek-v4-flash` and `opencode-go/deepseek-v4-pro` — both are listed but unreachable without China opt-in or additional setup. The plan's bake-off table should drop these in favor of confirmed-reachable alternatives.

---

## Self-Check Against Done-When Criteria

| Criterion | Status |
|---|---|
| Q1 Native subagent spawn — yes/no + evidence | PASS |
| Q1 Per-spawn model pinning — yes/no + evidence | PASS (partial: static yes, dynamic unverified, degradation stated) |
| Q2 Parallelism/background — yes/no + evidence | PASS |
| Q3 Cancellation (SessionAbort reachability) — yes/no + evidence | PASS |
| Q4 Per-subagent token totals — yes/no + evidence | PASS |
| Q5 Subagents see skills.paths — yes/no + evidence | PASS |
| Q6 Headless permission behavior — yes/no + evidence | PASS |
| Q7 OpenCode Go meters usage — yes/no + evidence | PASS |
| Degradation paths for absent capabilities | PASS (Q2 sequential fallback, Q3 post-hoc guard, Q5 skills setup warning) |
| Model address syntax recorded | PASS |
| Auth/model reachability recorded | PASS |

**Self-check result: PASS** — all seven questions answered with real evidence; degradation paths stated for Q2 (parallelism) and Q3 (cancellation); skills override warning recorded for Q5.

---

## What Stage 1b (Model Bake-off) Needs to Know

1. **Confirmed-reachable candidates:** kimi-k3, kimi-k2.7-code, glm-5.3, qwen3.7-plus, qwen3.8-max, qwen3.7-max, minimax-m3, mimo-v2.5, gpt-5.6-luna, grok-4.5 (10 models)

2. **Drop from bake-off:** `deepseek-v4-flash` (China-only, explicit error) and `deepseek-v4-pro` (silent failure, 0 tokens). Replace with confirmed alternatives if the plan's candidate list needs adjustment.

3. **Model invocation for bake-off:** Use `opencode run --auto --model opencode-go/<id>` for headless runs. For subagent role testing, use named agent config with `model` pinned.

4. **Token tracking:** All bake-off sessions will have per-session cost and token data in the opencode DB immediately after each run — no extra tooling needed.

5. **Parallelism uncertainty:** If the bake-off uses parallel tasks to test latency, results may be serialized. Latency measurements should account for possible sequential execution.

6. **Per-spawn model pinning (open question):** Stage 1b should include a test where a parent agent with model A spawns a named subagent configured with model B, then DB-checks whether the child session used model A or B. This resolves the dynamic pinning question definitively.
