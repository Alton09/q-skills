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

#### Composable Skills

workflow-kit skills delegate to project-local skills that you supply. These must exist in
your project's `.claude/skills/` before running implement-plan or feature-plan:

| Skill | Required | Contract |
|---|---|---|
| `/verify` | Required | Run quality gates; return `pass` or `fail` with raw output verbatim on failure |
| `/create-worktree` | Required | Create an isolated git worktree and branch; return its path |
| `/clean-architecture` | Required | Load layer rules and naming conventions into context |
| `/research` | **Optional** | Look up latest API docs for a given surface; return findings as text. Skipped gracefully if absent. |
| `/create-pr` | **Optional** | Open a **draft** PR for the finished worktree branch, non-interactively, and return its URL. implement-plan's final step delegates here; skipped gracefully if absent. |

See [`examples/android/`](examples/android/) for a working reference implementation targeting
Kotlin, Gradle KTS, Jetpack Compose, Hilt, and Clean Architecture. Copy and adapt those
skills as a starting point for your own project.

### dev-toolkit

Standalone dev utilities that work independently of any planning pipeline.

**Skills included:**

| Skill | Command | Description |
|-------|---------|-------------|
| pr-review | `/dev-toolkit:pr-review` | Project-aware GitHub PR review with focused, numbered findings |
| skill-sharpener | `/dev-toolkit:skill-sharpener` | Analyze session transcripts to find and fix skill friction |
| notify-me | `/dev-toolkit:notify-me` | Send macOS system notifications during long-running tasks (macOS only) |

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

## Using implement-plan on opencode

> Claude Code is the default and unchanged host for all workflow-kit skills.
> `workflow-kit:implement-plan` also runs natively on **opencode** — launch the skill
> inside an opencode session and the entire run stays on that host. No Claude Code
> involvement required unless escalation rung 2 is reached (see below).

### Install and authenticate

Install the opencode CLI and subscribe to OpenCode Go (flat-rate, $10/month):

- See [opencode.ai/docs](https://opencode.ai/docs) for the current install command.
- Sign up for OpenCode Go at [opencode.ai/docs/go](https://opencode.ai/docs/go);
  credentials are written to `~/.local/share/opencode/auth.json` on first login.

Verify your subscription is active:

```bash
opencode providers list
# Expected: ● OpenCode Go [api]  1 credentials
```

### Launch opencode from the workspace parent (required)

opencode confines every tool call a subagent makes to the **session root** — the directory
passed as `--dir`. A call targeting a path outside that root never completes: no error, no
permission prompt, no timeout. `implement-plan` creates its integration worktree as a
sibling of your project repo (and parallel-group child worktrees as siblings of that), so
the session root must be the directory that contains them all:

```
workspace/               <- run opencode here
  my-project/            <- your repo, with the plan in it
  my-project-feature/    <- integration worktree, created by /create-worktree
  .wt/<phase-slug>/      <- child worktrees, if a phase group runs in parallel
```

```bash
cd /path/to/workspace
opencode --dir /path/to/workspace
# then, inside the session:
#   use implement-plan on my-project/docs/plans/<plan>.md
```

Put your `opencode.jsonc` at that workspace root as well, so it applies to the session.

The skill verifies this at Step 0.5 and halts with an explicit message if the session root
cannot hold the worktrees — it will not start work it would deadlock on.

### Register skills in opencode.jsonc

opencode loads skills from `skills.paths`. **Critical: a project-local `opencode.jsonc`
with `skills.paths` overrides the global config entirely — it does not merge.** Every
path you need must appear in one place.

Add to `~/.config/opencode/opencode.jsonc` (global, recommended) or to your project's
`opencode.jsonc`, listing **both** this repo's skills directories **and** your consumer
project's own skills directory:

```jsonc
{
  "skills": {
    "paths": [
      "/path/to/q-skills/plugins/workflow-kit/skills",
      "/path/to/q-skills/plugins/dev-toolkit/skills",
      "/your/project/.claude/skills"
    ]
  }
}
```

> If you place this in a project-local `opencode.jsonc`, the global `skills.paths` list
> disappears. Include every path you need in that one file — the q-skills plugin
> directories and your own project's skills (`/verify`, `/create-worktree`, etc.).

Named subagent definitions are required for per-role model routing. Add these to the
same file (values shown are the bake-off-measured defaults):

```jsonc
{
  "agent": {
    "phase-light": {
      "model": "opencode-go/minimax-m3",
      "mode": "subagent",
      "description": "Light-tier phase worker (mechanical tasks)"
    },
    "phase-standard": {
      "model": "opencode-go/glm-5.3",
      "mode": "subagent",
      "description": "Standard-tier phase worker (normal tasks)"
    },
    "phase-deep": {
      "model": "opencode-go/kimi-k3",
      "mode": "subagent",
      "description": "Deep-tier phase worker (complex tasks)"
    },
    "gate-verify": {
      "model": "opencode-go/grok-4.6",
      "mode": "subagent",
      "description": "Behavioral gate-verify — family-diverse from all implementers"
    },
    "review": {
      "model": "opencode-go/grok-4.6",
      "mode": "subagent",
      "description": "Post-plan review — family-diverse from all implementers"
    }
  }
}
```

### Model overrides

Per-role models can be overridden via environment variables (same surface as Claude Code):

```bash
ORCHESTRATOR_MODEL=opencode-go/qwen3.8-max
PHASE_MODEL_LIGHT=opencode-go/minimax-m3
PHASE_MODEL_STANDARD=opencode-go/glm-5.3
PHASE_MODEL_DEEP=opencode-go/kimi-k3
VERIFY_MODEL=opencode-go/grok-4.6
REVIEW_MODEL=opencode-go/grok-4.6
FIX_MODEL=opencode-go/glm-5.3
```

Use `opencode-go/<model-id>` format for flat-rate models. Unknown model ids halt
the run immediately with an explicit error — no silent substitution.

### What's weaker on opencode

The following capabilities are degraded relative to Claude Code. The skill discloses
them at Step 2 before any work starts:

- **No first-class worker cancellation.** The `STOP_WORKER` primitive is unavailable
  from within a running skill. A runaway subagent burns to completion before the token
  ceiling stops its successor — the runaway guard is post-hoc only.
- **Parallel phase groups demote to sequential.** Sibling subagents *can* execute
  concurrently on opencode (measured), but the `task` tool has no background-run
  equivalent, so control never returns to the orchestrator mid-flight: a running group
  cannot be watched, and — with no `STOP_WORKER` — cannot be stopped. Rather than run
  unsupervised concurrency, the skill runs phases one at a time. Expect a longer wall
  clock than Claude Code on plans with independent phases.
- **Model pinning is static config only.** Per-spawn model override at call time is
  not supported. Named subagent definitions in `opencode.jsonc` (see above) are the
  only pinning mechanism and must be defined before the run begins.
- **Escalation rung 2 is a manual handoff.** When automatic rung-1 rescue exhausts
  its budget, the skill halts and emits a "Resume in Claude Code" block with the
  worktree path and relaunch instruction. You reopen that worktree in Claude Code to
  continue with full capabilities.

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
/dev-toolkit:pr-review          # Review a GitHub PR
/dev-toolkit:skill-sharpener    # Improve skills from session data
/dev-toolkit:notify-me          # Send macOS notification
```

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
    dev-toolkit/
      .claude-plugin/
        plugin.json           # Plugin manifest (v1.0.0)
      skills/
        pr-review/            # GitHub PR review skill
        skill-sharpener/      # Skill improvement skill
        notify-me/            # macOS notification skill
```

## License

See [LICENSE](LICENSE) for details.
