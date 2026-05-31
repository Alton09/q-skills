# Android Example Skills for workflow-kit

These are reference implementations of the delegate skills that [workflow-kit](../../plugins/workflow-kit/) requires for a modern Android project (Kotlin, Gradle KTS, Jetpack Compose, Hilt, Clean Architecture).

## What are delegate skills?

workflow-kit's core skills (`/feature-plan`, `/implement-plan`, `/deep-dive`) delegate to project-local skills that you supply. Each consumer project provides its own versions because what "verify" or "create-worktree" means depends on your stack. These examples show what that looks like for Android.

## How to use

Copy the skill directories you need into your project's `.claude/skills/` directory:

```bash
# Ensure the destination exists first
mkdir -p ~/your-project/.claude/skills/

# Copy a single skill
cp -r examples/android/verify ~/your-project/.claude/skills/

# Or copy all four at once
cp -r examples/android/verify \
       examples/android/clean-architecture \
       examples/android/create-worktree \
       examples/android/research \
       ~/your-project/.claude/skills/
```

Then adapt each `SKILL.md` to match your project's module layout, Gradle commands, and conventions. These are starting points, not drop-in-final solutions — your project's Gradle task names, module paths, and architecture decisions may differ.

## Skills

| Skill | Required | What it does |
|---|---|---|
| [`/verify`](./verify/SKILL.md) | Required | Runs Gradle quality gates (ktlint, detekt, unit tests, compile check). Returns `pass` or `fail` with raw output. |
| [`/clean-architecture`](./clean-architecture/SKILL.md) | Required | Loads layer rules (presentation/domain/data), naming conventions, and NEVER constraints into context once before implementation begins. |
| [`/create-worktree`](./create-worktree/SKILL.md) | Required | Creates an isolated git worktree + branch and copies `local.properties` so the worktree builds. Returns the worktree path. |
| [`/research`](./research/SKILL.md) | **Optional** | Looks up Android API surfaces using the `android` CLI. Requires `android` CLI installed on PATH. feature-plan degrades gracefully if absent. |

## Notes

- **Adapt, don't drop in.** Check Gradle task names (`testDebugUnitTest` vs `test`), module paths, and ktlint/detekt configuration against your project before running.
- **`/research` needs the `android` CLI.** Install it from the Android Studio SDK tools or your package manager. If it's not available, skip this skill — workflow-kit will proceed without research output.
- **`local.properties` is the key Android gotcha.** It's gitignored and contains your SDK path. The `/create-worktree` skill copies it for you — see that skill's README for details.
