# q-skills

A collection of project-agnostic Claude Code plugins for structured development workflows.

## Plugins

### workflow-kit

Project-agnostic Claude Code plugins for the full feature lifecycle: structured planning, verified implementation, and PR review.

**Skills included:**

| Skill | Command | Description |
|-------|---------|-------------|
| feature-plan | `/workflow-kit:feature-plan` | Create structured implementation plans with phases, tasks, and acceptance criteria |
| implement-plan | `/workflow-kit:implement-plan` | Execute a plan end-to-end with dependency-graph parallel phases, two-tier verification, an opus escalation rescue, and a post-plan review + auto-fix, then a draft PR opened via the project's `/create-pr` |
| address-pr | `/workflow-kit:address-pr` | Address PR comments, fix CI, update a PR with main, or resolve conflicts on an open pull request |
| pm | `/workflow-kit:pm [<feature>] [--from <master-plan>]` | Project manager that supervises every feature and standalone item in a repo, with resumable dossiers and background workers |

#### Composable Skills

workflow-kit skills delegate to project-local skills that you supply. These must exist in
your project's `.claude/skills/` before running implement-plan or feature-plan:

| Skill | Required | Contract |
|---|---|---|
| `/verify` | Required | Run quality gates; return `pass` or `fail` with raw output verbatim on failure |
| `/create-worktree` | Required | Create an isolated git worktree and branch, or check out an existing PR branch for address-pr; return its path |
| `/clean-architecture` | Required | Load layer rules and naming conventions into context |
| `/research` | **Optional** | Look up latest API docs for a given surface; return findings as text. Skipped gracefully if absent. |
| `/create-pr` | **Optional** | Open a **draft** PR for the finished worktree branch, non-interactively, include the report at the supplied plan-file path in the PR body, and return its URL. implement-plan delegates here; skipped gracefully if absent. |

See [`examples/android/`](examples/android/) for a working reference implementation targeting
Kotlin, Gradle KTS, Jetpack Compose, Hilt, and Clean Architecture. Copy and adapt those
skills as a starting point for your own project.

#### Lead inputs

With `--worker`, a run launched by a lead does not ask interactively. An implement-plan run
requires a plan path; missing paths or inline content stop at pre-flight. A Codex
`full-access` device request falls back to `reserved-device` without confirmation. The run
pauses with `implement-plan: needs input` only when an exhausted escalation or a runaway-guard
trip needs the user. See
[`worker-mode.md`](plugins/workflow-kit/skills/implement-plan/references/worker-mode.md) for
the block format. Completed runs use their skill's `done` line (for
example, `feature-plan: done <plan path>` or `implement-plan: done <plan-key> <PR url | pr-skipped>`);
an implement-plan stop uses `implement-plan: stopped <plan-key> <phase | pre-flight | step-9>`.
Feature planning
also supports `--handoff <path-or-summary>` to plan from a design handoff, repeatable
`--context <path>` inputs, and `--out <path>` for the plan destination.

#### Project manager

Run `/workflow-kit:pm [<feature>] [--from <master-plan>]` from the project repository
root. The lead stores resumable state in `<vault>/Features/<feature>/`: `brief.md`, append-only
`decisions.md` and `log.md`, generated `board.md`, item files under `items/`, and design and
handoff-plan folders. Project-wide decisions live in `<vault>/Features/_project/decisions.md`.

Configure the dossier and worker cap in `~/.claude/workflow-kit.json` or the project's
`.claude/workflow-kit.json`; project `pm` keys override the user keys. The lead does not write
this configuration itself.

```json
{
  "pm": {
    "maxWorkers": 2,
    "vault": "/absolute/path/to/project-vault"
  }
}
```

Run the lead in `auto` permission mode. Trust the workspace and add the one-time
`Bash(claude --bg *)` allow rule: worker commands begin with `claude --bg`, so wrapping them in
`cd ... &&` prevents that rule from matching. The lead launches workers in `auto` too.

Workers receive no rules, guardrail paths, or approval gates. Design review and the user's PR
review are the checkpoints; implementation choices that survive review are recorded under
`### Unplanned Decisions` in the PR body and then logged to the dossier after merge. When
available, the optional dev-toolkit plugin supplies desktop notifications, PR review, and retro.

### dev-toolkit

Standalone dev utilities that work independently of any planning pipeline.

**Skills included:**

| Skill | Command | Description |
|-------|---------|-------------|
| pr-review | `/dev-toolkit:pr-review` | Project-aware GitHub PR review with focused, numbered findings |
| pr-retro | `/dev-toolkit:pr-retro` | Post-merge retro: mine PR comments, CI and linked sessions for skill, harness and lint-rule improvements. |
| notify-me | `/dev-toolkit:notify-me` | Send macOS or Linux system notifications during long-running tasks |

#### SessionStart Nudge Hook

`dev-toolkit` includes a SessionStart hook that nudges you when a merged PR has not yet been retrospectively analyzed. When you start a session in a GitHub repository where you have authored merged PRs, the hook checks for any that have not yet been analyzed with `/dev-toolkit:pr-retro` or skipped, and displays:

```
PR #432 "Feature name" merged with no retro. Run /dev-toolkit:pr-retro 432, or /dev-toolkit:pr-retro --skip 432.
```

The hook queries GitHub at most once per hour per repository, and fails silently if offline or if `gh` is not installed. To opt out of nudges, set the environment variable `PR_RETRO_NUDGE=0`.

Per-repository state is stored in `~/.claude/pr-retro/<owner>__<repo>/`, including a baseline timestamp and the list of PRs already retro'd or skipped.

## Installation

1. Add the marketplace directly from GitHub (no clone required):

```bash
claude plugin marketplace add Alton09/q-skills
```

   The `owner/repo` shorthand above works, as does the full URL:

```bash
claude plugin marketplace add https://github.com/Alton09/q-skills
```

2. Install each plugin:

```bash
claude plugin install workflow-kit
claude plugin install dev-toolkit
```

3. Reload plugins in Claude Code:

```
/reload-plugins
```

Run `/doctor` to confirm no errors.

### Local development install

Developing the plugins locally? Point the marketplace at your working copy instead:

```bash
git clone https://github.com/Alton09/q-skills.git ~/Workspace/q-skills
claude plugin marketplace add ~/Workspace/q-skills
claude plugin install workflow-kit
claude plugin install dev-toolkit
```

## Swappable phase executors

`implement-plan` always orchestrates from Claude Code; an executor changes only the
harness used for an individual phase, retry, review, or fix worker. Keeping scheduling,
worktrees, pacing, gate verification, notifications, and decisions in Claude Code avoids
the foreign-orchestrator failures observed in F1-F5 while still allowing worker choice.

The default is Claude workers. You choose executors with `routing.phase` lists in
`.claude/workflow-kit.json`: each tier (`light`, `standard`, `deep`) takes an ordered list of
`executor:model` targets, where the executor is `claude`, `pi`, or `codex`. The shipped
defaults are:

| Executor | Light | Standard | Deep |
|---|---|---|---|
| `claude` (default) | `claude:haiku` | `claude:sonnet` | `claude:opus` |

To run pi workers with a Grok reviewer, put this in `<repo>/.claude/workflow-kit.json`:

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

For codex workers, keep the Claude reviewer (a Codex reviewer cannot review a Codex
implementer):

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

The per-worker wall-clock budget is `implementPlan.phase.timeBudget` (default 30 minutes).
Every other setting (verify skill, self-verify limit, review, E2E, PR creation, address-pr
and pm options) lives in the same file; the key tables in the `implement-plan` and
`address-pr` SKILL.md files list them all.

For pi, install the `pi` CLI and authenticate its `opencode-go` provider. For Codex,
install the Codex CLI and sign in with a ChatGPT plan. The orchestrator creates the
per-worktree `.agents/skills` link Codex needs; no manual skill-link setup is required.

The gate-verify role defaults to `claude:sonnet` (use `claude:haiku` only for a
deterministic exit-code gate) and is set with `routing.gateVerify`. The reviewer is
`routing.review`, which defaults to `claude:opus`. Reviewers should differ from each
implementer by executor or model family whenever the configured pool permits it, and a
Codex reviewer cannot review a Codex implementer.

Foreign workers may not cover device work during their warm self-verify: Codex workers
skip that half, while pi workers may or may not run it. The independent gate covers device
criteria in either case.

Pi's flat-rate accounting is retail-equivalent value, not metered cash; its provider
five-hour cap is the binding limit. Codex reports tokens and plan-window share, not dollars;
ChatGPT Plus has both five-hour and weekly windows.

### Quota-aware routing

Every role takes an ordered fallback list, and nothing is pinned outside the file. Before
every phase, fix, gate-verify, and review spawn, `implement-plan` reads local quota and
uses the first target in the role's list that still has budget. A one-target list is a pin
that still reports its quota:

```json
{
  "version": 2,
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
    "prFix":      ["codex:gpt-5.6-terra", "claude:sonnet"],
    "orchestrator": ["claude:opus"]
  }
}
```

Put it at `~/.claude/workflow-kit.json` (your default) or `<repo>/.claude/workflow-kit.json`
(per project). Precedence, highest first, per key: the project file, then the user file,
then the shipped defaults in `config.py`. Objects merge key by key; lists and scalars
replace whole. Routing needs `quota-axi`, `jq`, and `python3` on `PATH`; without
`quota-axi` it falls back safely to the first target in each list. Escalation stays on
`claude:opus`. The run report shows why each target was chosen. Full rules, including more
example lists: `plugins/workflow-kit/skills/implement-plan/references/routing.md`.

The address-pr fix workers use `routing.prFix`, falling back to `routing.phase.standard` when no
`prFix` list is configured.

`routing.orchestrator` is the pm launch gate. It accepts only `claude:*` targets and
defaults to `claude:opus`; its threshold is `minBudgetPercentByRole.orchestrator`, then
`minBudgetPercent`, then 10%. Before each `claude --bg` launch, pm reads the router's
`usable` and `resetsAt` fields. A false `usable` queues the item and asks whether to wait or
start despite the quota gate; unavailable quota is fail-safe and does not block the launch.

## Upgrading to 4.0.0

workflow-kit 4.0.0 moves every setting into `workflow-kit.json` (`version: 2`). The old
environment variables and CLAUDE.md lines are ignored. Run
`plugins/workflow-kit/skills/implement-plan/scripts/config.py legacy-check --project-dir .`
to get one warning per stale name with its new key. The same old-name to new-key map is in
the key tables of the `implement-plan` and `address-pr` SKILL.md files. For example,
`PHASE_EXECUTOR=codex` becomes the codex `routing.phase` lists above, and `SELF_VERIFY_LIMIT`
becomes `selfVerifyLimit`.

## Updating

```bash
# Check your exact plugin identifier
claude plugins list

# Update using the name shown (e.g. workflow-kit@q-skills)
claude plugins update workflow-kit@<marketplace-name>
claude plugins update dev-toolkit@<marketplace-name>
```

Restart Claude Code after updating to apply changes.

## Usage

After installation, skills are available as slash commands:

```
/workflow-kit:feature-plan      # Plan a feature
/workflow-kit:implement-plan    # Execute a plan
/workflow-kit:address-pr 123    # Address PR comments (comment mode)
/workflow-kit:address-pr 123 --ci # Fix actionable CI failures (CI mode)
/workflow-kit:address-pr 123 --sync # Update the PR with its base branch (sync mode)
/workflow-kit:pm my-feature # Manage the project with resumable dossiers
/dev-toolkit:pr-review          # Review a GitHub PR
/dev-toolkit:pr-retro           # Post-merge retrospective on PR comments, CI, and linked sessions
/dev-toolkit:notify-me          # Send macOS or Linux notification
```

Use `--worker` when another agent session launches the run in the background and answers its questions, and `--worktree <path>` to select the PR worktree explicitly.

## Project Structure

```
q-skills/
  .claude-plugin/
    marketplace.json          # Marketplace registry (lists both plugins)
  plugins/
    workflow-kit/
      .claude-plugin/
        plugin.json           # Plugin manifest (v1.1.0)
      skills/
        feature-plan/         # Feature planning skill
        implement-plan/       # Plan execution skill (with built-in opus escalation rescue)
        address-pr/           # PR comment, CI, and branch sync skill
        pm/                   # Project management with resumable dossiers and background workers
    dev-toolkit/
      .claude-plugin/
        plugin.json           # Plugin manifest (v1.0.0)
      skills/
        pr-review/            # GitHub PR review skill
        pr-retro/             # Post-merge retrospective skill
        notify-me/            # macOS and Linux notification skill
      hooks/
        hooks.json            # SessionStart hook for nudging unretro'd PRs
        pr-retro-nudge.sh     # Nudge script
```

## License

See [LICENSE](LICENSE) for details.
