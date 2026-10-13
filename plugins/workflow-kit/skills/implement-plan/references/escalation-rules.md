This is about when to stop and ask the user; `references/escalation.md` is the opus rescue after failed gates.

## Rules files

Use this format:

```markdown
## Escalation
### Ask
- New Room migrations need my sign-off.
### Guardrail paths
- `konsist/` — Konsist architecture rules
### Loosen
- `settings.gradle.kts` — designs/kmp-module-layout.md
```

If a file has a `## Escalation` heading, read only that section, up to the next `## ` heading. Otherwise read the whole file. This lets a brief and a standalone `_project/escalation.md` share one format.

`### Ask` has one free-text rule per bullet. `### Guardrail paths` bullets start with a backticked pattern; text after it is a note. `### Loosen` bullets are a backticked guardrail pattern or a free-text Ask rule, then ` — ` (or ` -- `), then a design-note path relative to the rules file.

Match headings case-insensitively. Treat unknown `###` headings and malformed bullets as warnings, not errors.

## Pattern syntax

Use a gitignore-like subset. A pattern with no `/` except a trailing one matches at any depth: `build.gradle.kts` hits `app/build.gradle.kts`. A trailing `/` matches everything under that directory. `**` matches zero or more path segments. `*` and `?` match within one segment. Paths are repo-relative with `/`.

## Layers

Pass `--rules <path>` repeatedly, lowest layer first. The lead passes `Features/_project/escalation.md`, then `Features/<feature>/brief.md`. Shipped defaults are always the bottom layer when any `--rules` is present. With no `--rules`, no rule applies and the skill behaves as before this change.

Layers add up. A later layer removes an exact earlier Ask rule or guardrail pattern only through `### Loosen`, and only when the cited design note exists; the merge result retains it in `loosened` as a record. A missing `--rules` file is an error: stop and report it; do not run without it.

## Defaults

### Ask

- A decision contradicts the brief, the approved design note, or a `decisions.md`.
- A decision changes architecture or CI or lint guardrails that the design did not agree to.
- A decision is hard to reverse: data or schema migrations, public API or module boundaries, removing features, force-push, closing a PR, or actions outside the repo.
- A decision affects user-visible behaviour, UX, or naming in public APIs.
- A decision spends something shared: new dependencies, the quota gate, or a second rescue on the same item.
- A decision follows no progress: stuck after the opus rescue, or the same choice reversed twice.
- A decision touches security: auth, secrets, permissions, or crypto.

### Guardrail paths

- `.github/workflows/` — CI
- `.github/actions/` — CI
- `bitrise.yml` — CI
- `.gitlab-ci.yml` — CI
- `.circleci/` — CI
- `detekt*.yml` — Lint and format
- `lint.xml` — Lint and format
- `.editorconfig` — Lint and format
- `.eslintrc*` — Lint and format
- `eslint.config.*` — Lint and format
- `ruff.toml` — Lint and format
- `.pre-commit-config.yaml` — Lint and format
- `build.gradle` — Build and dependencies
- `build.gradle.kts` — Build and dependencies
- `settings.gradle` — Build and dependencies
- `settings.gradle.kts` — Build and dependencies
- `gradle/libs.versions.toml` — Build and dependencies
- `gradle.properties` — Build and dependencies
- `package.json` — Build and dependencies
- `pyproject.toml` — Build and dependencies
- `Cargo.toml` — Build and dependencies
- `go.mod` — Build and dependencies
- `CLAUDE.md` — Agent rules
- `.claude/settings.json` — Agent rules
- `.claude/skills/` — Agent rules

## Tiers

Ask: the item blocks until the user answers, with no timeout. Decide and tell: go ahead and list it in the report. Decide and log: go ahead and list it in the report for the lead to append to `decisions.md`.

A decision is tell when its suggested scope is project (conventions, architecture, tooling, CI) or it departs from the plan text. Otherwise it is log. Skills never write `decisions.md`.

## Matching

Ask rules are judgment. Match a proposed decision against each rule and name the rule and layer that matched. Guardrail paths are mechanical: run the script's `check` and treat every hit as an Ask.

A worker meets most decisions. Every worker handoff carries the merged rules: the Ask rules with their layers, the guardrail patterns, and the named paths. Tell the worker to stop before making a matching change and return `needs_decision` `{question, options, recommendation, rule, layer}`.

## Asking the user

Standalone runs use `AskUserQuestion`, up to four questions per call. With `--worker`, do not use `AskUserQuestion`. First let in-flight sub-agents of the current step finish and stop their runaway-guard timers, so no task notification starts a new turn. Then end the turn with this block:

```
<skill>: needs input <id>
Rule: <rule> (<layer>)
Question: <one line>
Options:
1. <option> — <what the skill does next>
2. <option> — <what the skill does next>
Recommendation: <option number and one-line reason>
```

Put several questions in one numbered block. The next turn, typed with `claude attach` or sent by the lead with `SendMessage`, is the answer. Resume from the step that asked. If that turn is not an answer, handle it and end the turn with the same block again. Restate what happens for every option so compaction cannot lose it.

## Rules updates mid-run

In a `--worker` run, a message starting `rules-update:` adds the rest as an Ask rule in a top `lead` layer for the remaining work. It can only add; it never loosens. Record it in the report.
