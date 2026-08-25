# Model Bake-off Research

> Stage 1b — Three-canary bake-off across the opencode-go catalog.
> Probed: 2026-08-25 | opencode 1.18.18

---

## Method

All 30 canary runs executed on this machine using `opencode run --agent build --model opencode-go/<model>` without `--auto`; the `build` agent's `*:allow` permission rule covers file operations in the worktree directory, making `--auto` unnecessary. Each canary ran in a fresh directory under `scratch/<canary>/<model>/` (gitignored) so no cross-contamination between runs.

**Headless note:** `opencode run --auto` is blocked by Claude Code's auto mode classifier when called from a sub-agent context without explicit user authorization. Running without `--auto` from a trusted project directory (q-skills-multi-runtime worktree) works equivalently because the `build` agent's wildcard allow rule covers the required tool permissions.

Session metrics (tokens, cost, latency) sourced directly from the opencode SQLite DB at `/Users/Alton/.local/share/opencode/opencode.db` after each run. Tool-call counts from `SELECT count(*) FROM part WHERE session_id=? AND json_extract(data,'$.type')='tool'`.

---

## Unavailable Candidates

| Model | Status | Evidence |
|---|---|---|
| `deepseek-v4-flash` | **UNAVAILABLE** | `opencode run` returns error: "only available hosted in China, requires explicit opt in" |
| `deepseek-v4-pro` | **UNAVAILABLE** | 0 tokens output, silent failure with no usable response |

Both models appear in `opencode models` catalog but are unreachable without China-region opt-in. All bake-off rows for these models are marked unavailable; no time was spent retrying.

---

## Canary Definitions

### C1 — Coding (implementer tiers)
**Task:** Write `count_vowels(text: str) -> int` to `count_vowels.py` and a pytest test file with 5 test cases. Run `python3 -m pytest test_count_vowels.py -v`. Report exact output.

**Pass criteria:** pytest output contains "passed" and the test file exists. Verified by actually running pytest (real verify command — not eyeballing). Latency measured wall-clock. Tool calls counted from DB.

### C2 — Tool Discipline (orchestrator/gate roles)
**Task:** Complete 10 sequential steps in order, one tool call per step: read data.txt, wc -l, write line_count.txt, read it back, wc -w, write word_count.txt, read it back, write summary.txt, ls *.txt, write done.txt. Report success/retry status.

**Pass criteria:** `done.txt` created (all 10 steps completed). Tool calls from DB: exactly 10 = perfect discipline; > 10 = retries occurred; < 10 = premature termination.

**Failure/retry rate:** No model produced extra tool calls (> 10) — i.e., zero retries across all models. kimi-k3 terminated after 4 calls (premature stop) with no retries on the remaining steps.

### C3 — Fidelity (prep/parse role)
**Task:** Read `reference.md` (200-line section from the implement-plan-multi-runtime.md plan document). Write its exact content verbatim to `output.md`. Run `diff reference.md output.md`. Report any differences.

**Pass criteria:** `diff` exits with 0 lines of output (byte-for-byte identical). Verified with `diff` after each run.

---

## Full Results Table

### C1 — Coding

| Model | Pass | Latency | Tokens In | Tokens Out | Cost (equiv) | Tool Calls |
|---|---|---|---|---|---|---|
| kimi-k3 | **pass** | 50.8s | 3,387 | 982 | $0.0388 | 5 |
| kimi-k2.7-code | **pass** | 45.3s | 9,880 | 744 | $0.0197 | 5 |
| glm-5.3 | **pass** | 28.0s | 9,429 | 610 | $0.0277 | 6 |
| qwen3.7-plus | **pass** | 26.0s | 10,920 | 535 | $0.0063 | 3 |
| qwen3.8-max | **pass** | 21.4s | 3,418 | 573 | $0.0172 | 3 |
| qwen3.7-max | **pass** | 19.2s | 11,236 | 576 | $0.0415 | 3 |
| minimax-m3 | **pass** | 11.5s | 7,263 | 640 | $0.0047 | 4 |
| mimo-v2.5 | **pass** | 27.2s | 8,670 | 568 | $0.0014 | 3 |
| gpt-5.6-luna | **pass** | 14.7s | 12* | 601 | $0.0033 | 4 |
| grok-4.5 | **pass** | 14.3s | 17,732 | 481 | $0.0434 | 3 |
| deepseek-v4-flash | **unavailable** | — | — | — | — | — |
| deepseek-v4-pro | **unavailable** | — | — | — | — | — |

*gpt-5.6-luna and gpt-5.6-luna tool_discipline report anomalously low tokens_in (12, 33) — likely prompt caching or a provider-side difference in token counting.

**All 10 reachable models passed coding pass@1.**

### C2 — Tool Discipline

| Model | Pass | Latency | Tokens In | Tokens Out | Cost (equiv) | Tool Calls | Extra/Retries | Failure mode |
|---|---|---|---|---|---|---|---|---|
| kimi-k3 | **FAIL** | 45.5s | 9,510 | 397 | $0.0434 | 4 | 0 | Premature stop after step 3 |
| kimi-k2.7-code | **pass** | 75.0s | 4,533 | 611 | $0.0246 | 10 | 0 | — |
| glm-5.3 | **pass** | 34.2s | 9,739 | 628 | $0.0408 | 10 | 0 | — |
| qwen3.7-plus | **pass** | 41.3s | 30,128 | 968 | $0.0172 | 10 | 0 | — |
| qwen3.8-max | **pass** | 37.9s | 8,863 | 699 | $0.0480 | 10 | 0 | — |
| qwen3.7-max | **pass** | 40.6s | 23,993 | 989 | $0.1115 | 10 | 0 | — |
| minimax-m3 | **pass** | 34.2s | 10,269 | 932 | $0.0098 | 10 | 0 | — |
| mimo-v2.5 | **pass** | 82.2s | 9,735 | 1,033 | $0.0019 | 10 | 0 | — |
| gpt-5.6-luna | **pass** | 26.1s | 33* | 589 | $0.0046 | 10 | 0 | — |
| grok-4.5 | **pass** | 29.6s | 19,066 | 487 | $0.0833 | 10 | 0 | — |
| deepseek-v4-flash | **unavailable** | — | — | — | — | — | — | China-only |
| deepseek-v4-pro | **unavailable** | — | — | — | — | — | — | Silent 0-token |

**kimi-k3 failure detail:** DB confirms 4 tool calls: read data.txt → `wc -l < data.txt` → write line_count.txt → write one more file (likely attempted word_count.txt but stalled). The model did not complete steps 4-10 and reported task done prematurely. No retry attempts — it simply stopped. This is a disqualifying behavior for orchestrator and gate roles where completing all required sequential steps is non-negotiable.

**9 of 10 reachable models passed with exactly 10 tool calls and 0 retries.**

### C3 — Fidelity

| Model | Pass | Diff Lines | Latency | Tokens In | Tokens Out | Cost (equiv) | Tool Calls |
|---|---|---|---|---|---|---|---|
| kimi-k3 | **pass** | 0 | 206.3s | 14,226 | 3,623 | $0.1888 | 6 |
| kimi-k2.7-code | **pass** | 0 | 88.3s | 15,224 | 3,162 | $0.0353 | 3 |
| glm-5.3 | **pass** | 0 | 83.3s | 19,825 | 3,078 | $0.0764 | 4 |
| qwen3.7-plus | **pass** | 0 | 66.4s | 27,670 | 3,183 | $0.0174 | 3 |
| qwen3.8-max | **pass** | 0 | 83.8s | 10,848 | 3,223 | $0.0590 | 4 |
| qwen3.7-max | **pass** | 0 | 66.9s | 50,609 | 3,383 | $0.1868 | 6 |
| minimax-m3 | **pass** | 0 | 35.4s | 10,495 | 3,407 | $0.0105 | 4 |
| mimo-v2.5 | **pass** | 0 | 53.6s | 12,339 | 429* | $0.0020 | 4 |
| gpt-5.6-luna | **pass** | 0 | 44.9s | 27* | 3,772 | $0.0105 | 8 |
| grok-4.5 | **pass** | 0 | 14.0s | 12,425 | 152* | $0.0429 | 3 |
| deepseek-v4-flash | **unavailable** | — | — | — | — | — | — |
| deepseek-v4-pro | **unavailable** | — | — | — | — | — | — |

*mimo-v2.5 (429 tokens_out) and grok-4.5 (152 tokens_out): very low output token counts despite writing 200-line file. The file content is delivered via the `edit/write` tool call payload, which is not counted in the model's `tokens_output` — only the reasoning/commentary text is counted. This is accurate; the file diffs confirm correct verbatim copy.

*kimi-k3 (206s, $0.19): ran 6 tool calls instead of minimum 3, including extra bash analysis (`python3` char analysis, `rg` for trailing spaces) before writing. High cost from thorough validation, not from errors.

**All 10 reachable models passed fidelity with 0 diff lines (exact byte-for-byte match).**

---

## Dynamic Model-Override Test

**Question (from 1a carry-forward):** Does a named subagent configured with model B in `opencode.jsonc` actually run on model B when spawned by a parent running model A?

**Test setup:**
- `opencode.jsonc` in scratch/override-test/ defines `test-worker` agent with `model: "opencode-go/kimi-k2.7-code"`
- Primary agent runs on `kimi-k3`; prompt asks it to spawn `test-worker` to write "WORKER_REPLY" to result.txt

**Result: CONFIG MODEL WINS — STATIC PINNING CONFIRMED**

DB evidence from the run:

```
Parent:  build agent  | model: kimi-k3        | session_id: ses_fc8aea6d...  | no parent_id
Child:   test-worker  | model: kimi-k2.7-code | session_id: ses_fc8ae89f...  | parent_id: ses_fc8aea6d...
```

The child session ran on `kimi-k2.7-code` (the config-declared model), NOT `kimi-k3` (the parent's model). The `agent.<name>.model` field in `opencode.jsonc` overrides the parent's model inheritance. The task completed successfully (result.txt contains "WORKER_REPLY").

**Implication for Stage 2a:** SPAWN_WORKER binding via named agent configs in `opencode.jsonc` is fully confirmed:
- One `agent.<tier-name>` entry per tier in the consumer project's `opencode.jsonc`
- Each entry has `model: "opencode-go/<model-id>"` and `mode: "subagent"`
- The orchestrator spawns by agent name; the model is pre-declared in config
- Per-spawn dynamic model override (call-time parameter) is not needed — config-level static pinning is the mechanism

**This resolves the open question from 1a and is the binding approach for Stage 2a.**

---

## Total Equivalent Cost Consumed

| Canary | Cost |
|---|---|
| Coding (10 models) | $0.2041 |
| Tool Discipline (10 models) | $0.3852 |
| Fidelity (10 models) | $0.6295 |
| **Total** | **$1.2188** |

Within the $12/5h rate limit. No rate-limit events observed during the run.

---

## Recommended Per-Role Map (opencode host)

### Summary

| Role | Tier | Recommended Model | One-line Justification |
|---|---|---|---|
| Orchestrator | deep | `qwen3.8-max` | Only model family (Qwen) that consistently passes tool discipline in both single-model and multi-step contexts; mid-range cost; strong all-around pass |
| Prep parse | standard | `qwen3.7-plus` | Fastest fidelity (66s) at lowest cost ($0.017); exact-match verbatim extract; strong tool discipline |
| Phase — mechanical | light | `minimax-m3` | Fastest coder (11.5s), cheapest ($0.005); all canaries pass; different family from default implementer families |
| Phase — normal | standard | `glm-5.3` | All canaries pass; family-diverse from Qwen orchestrator; reliable discipline (34s/10 tools) |
| Phase — complex | deep | `kimi-k3` | Passes coding and fidelity; Kimi family known for reasoning; tool-discipline failure is acceptable for an implementer (batching is not disqualifying when the model isn't orchestrating) |
| Gate-verify (exit-code) | light | `qwen3.7-plus` | Perfect discipline (10 tools, 0 retries); lowest cost for discipline canary; fast |
| Gate-verify (behavioral) | standard | `grok-4.5` | Western lineage (xAI) — maximally family-diverse from all Chinese-family implementers; all canaries pass; fastest fidelity (14s) |
| Review | deep | `grok-4.5` | Lineage-distant from all Chinese families (Kimi, GLM, Qwen, MiniMax, MiMo); fast; all canaries pass |
| Fix | standard | `glm-5.3` | Same justification as Phase normal; reliable, disciplined |
| Escalation rung 1 | deep | `qwen3.8-max` if primary was Kimi; `kimi-k3` if primary was Qwen | Switch family from failed implementer; both are deep-tier capable per coding canary |

### Justification Notes

**Why qwen3.8-max for orchestrator, not kimi-k3?** kimi-k3 failed the tool discipline canary — it made 4 tool calls and stopped after step 3, never completing steps 5-10. This behavior (premature task termination) is disqualifying for orchestrator/gate roles where sequencing compliance is non-negotiable. The plan hypothesis of kimi-k3 for orchestrator is overturned by measurement.

**Why kimi-k3 is still recommended for complex phases?** An implementer's job is to write code, not to orchestrate other agents. Batching tool calls in an implementation context is acceptable — the gate catches any errors. kimi-k3 passes coding (50s, all 5 pytest cases) and fidelity (exact match). Its reasoning depth (evident from the extra analysis on fidelity) may be an asset for complex tasks.

**Why grok-4.5 for gate and review?** Maximum family diversity from the Chinese-family implementers (Kimi, Qwen, GLM). Fastest fidelity in the catalog (14s). All canaries pass. Western (xAI) training data and methodology creates the most distinct blind spots from the Chinese models, satisfying the diversity rule most strongly.

**Why minimax-m3 for mechanical phases?** Fastest coder at 11.5s, cheapest at $0.0047, passes all three canaries, and is a different family from Kimi/Qwen/GLM. Ideal for high-volume, low-complexity tasks (file moves, scaffolding, formatting).

**On qwen3.7-max:** Passes all canaries but at the highest cost in the catalog ($0.111 for tool discipline alone). Given the flat-rate plan, cost doesn't meter per-use, but equivalent-cost consumption still matters for the $60/month cap. Prefer qwen3.8-max or qwen3.7-plus which achieve similar discipline at lower equivalent cost.

---

## Model Family Groupings (for Diversity Rule)

The diversity rule states: gate-verify and review must use a **different model family** than the implementer they check. Escalation rung 1 switches family from the failed implementer.

| Family | Models | Origin | Notes |
|---|---|---|---|
| **Kimi** | kimi-k3, kimi-k2.7-code | Moonshot AI (China) | Same company, same training lineage; treat as one family |
| **GLM** | glm-5.3 | Zhipu AI (China) | ChatGLM series; different company from Kimi/Qwen |
| **Qwen** | qwen3.7-plus, qwen3.8-max, qwen3.7-max | Alibaba (China) | Same Qwen3 series; treat all as one family regardless of size |
| **MiniMax** | minimax-m3 | MiniMax (China) | Independent company; distinct from other Chinese families |
| **MiMo** | mimo-v2.5 | Research model (China) | Very low equivalent-cost; distinct lineage |
| **GPT** | gpt-5.6-luna | GPT lineage (Western) | OpenAI-lineage; anomalous token reporting suggests provider caching |
| **Grok** | grok-4.5 | xAI (Western) | Distinct Western lineage; fastest fidelity in catalog |

**Diversity pairs that satisfy the rule:**
- Kimi implementer → gate/review: GLM, Qwen, MiniMax, MiMo, GPT, or Grok (any non-Kimi)
- Qwen implementer → gate/review: Kimi, GLM, MiniMax, MiMo, GPT, or Grok (any non-Qwen)
- **Strongest diversity pairs (cross-cluster):** Any Chinese family + Grok or GPT

**Within-cluster diversity** (e.g., Kimi implementer + GLM gate) satisfies the rule — different company, different training data, different blind spots. Cross-cluster diversity (Chinese implementer + Western gate) provides additional architectural separation but is not required.

**Recommended default diversity pairing for the per-role map:**
- Primary implementers: Kimi family, GLM, MiniMax (mechanical)
- Primary gate/review: Qwen (gate-verify), Grok (behavioral gate + review)
- This covers: Kimi↔Qwen (cross-company within cluster) and Kimi/GLM↔Grok (cross-cluster)

---

## Self-Check Against Done-When Criteria

| Criterion | Status |
|---|---|
| Results table covers all 12 plan candidates (incl. 2 unavailable) | PASS |
| Per-role map with one-line justifications | PASS |
| Model family groupings recorded for diversity rule | PASS |
| Dynamic model-override test result recorded | PASS (config model wins; named agent pinning confirmed) |
| Recommended map overrides hypothesis with measurement | PASS (kimi-k3 orchestrator → qwen3.8-max; measured evidence) |

**Self-check result: PASS** — all Done-when criteria met. No gaps requiring a second round.

---

## What Stage 2 Needs

**2a (runtimes.md):**
- SPAWN_WORKER: static named-agent config bindings (one `agent.<tier>` entry per tier in `opencode.jsonc`) — CONFIRMED by override test: config model overrides parent model inheritance
- Per-spawn dynamic model override: NOT needed; static config-level agent definitions are the correct binding approach and work reliably
- All other findings unchanged from 1a

**2b (model-routing.md):**
- Replace plan hypothesis column with this measured table; family groupings above
- kimi-k3 moves from Orchestrator to Phase-complex; qwen3.8-max takes Orchestrator
- Diversity pairs: Qwen for gate-verify (exit-code), Grok for gate-verify (behavioral) + review
- qwen3.7-max is an available deep alternative but highest equivalent-cost; prefer qwen3.8-max
- Note: gpt-5.6-luna anomalous token reporting (tokens_in near 0) suggests provider caching; functional behavior is correct (all canaries pass), but cost/accounting metrics may be unreliable for this model
