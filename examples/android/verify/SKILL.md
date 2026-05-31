---
name: verify
description: >
  Run quality gates and return pass or fail with raw output.
  Use this skill to verify, check quality, run checks, or validate the build
  after implementation — called automatically by implement-plan after each phase.
---

# Verify

Run Android project quality gates sequentially. Stop on first failure. Return `pass` or `fail`.

## Gate Order

Run each gate in order. If a gate fails, stop immediately — do not proceed to the next gate.

### Gate 1: Static Analysis

```bash
./gradlew ktlintCheck detekt
```

Catches formatting violations (ktlint) and code-smell issues (detekt). Both run in one Gradle invocation.

### Gate 2: Unit Tests

```bash
./gradlew testDebugUnitTest
```

Runs all JVM unit tests in the `debug` variant. Fast — no emulator needed.

### Gate 3: Compile Check

```bash
./gradlew assembleDebug
```

Confirms the project compiles. Catches type errors and missing symbols that tests may not exercise.

## Excluded: `connectedAndroidTest`

Do **not** run `connectedAndroidTest` (instrumented tests). These require a running emulator or physical
device, take several minutes, and are unsuitable for the automated verify loop that implement-plan
calls after each phase. Run them manually before merging.

## Return Values

**On failure** — return `fail` followed by the raw Gradle output verbatim. Do not summarize or truncate.
implement-plan retries up to 3x on fail; deep-dive reads the raw output to diagnose the issue.

```
fail

> Task :app:ktlintMainSourceSetCheck FAILED
FAILURE: Build failed with an exception.
...
```

**On all-green** — return:

```
pass
```

## Assumptions

- `./gradlew` exists at the project root (standard Android project layout).
- The caller runs this skill from the project root directory.
- `local.properties` is present (needed for SDK path — see `/create-worktree` for the worktree copy step).
