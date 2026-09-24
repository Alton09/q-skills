# E2E Contract

Referenced by implement-plan Step 8. A consumer project's `/e2e` skill runs the slow,
device-bound checks after implementation. It runs unattended and returns a compact verdict.

## Runs Unattended

Do not prompt. Select a device or emulator, boot it when needed, install the build from the
current worktree, and clear app state where a suite or criterion needs a first launch.

The skill owns device selection. Do not reuse a device that another run is using. Reserve the
selected device for this run before installing or testing. If no unreserved device is available,
return `env-error`.

## Input

Accept:

- The absolute worktree path.
- An optional list of plan acceptance criteria tagged `[e2e]`. Check these after the normal
  suite. A plan with no tagged criteria still runs the suite.

## Hand-back

Return exactly this shape and nothing else:

```
status: pass | fail | env-error
passed: <n>/<total>
failed: <test or [e2e] criterion names, one per line; empty on pass>
flaky: <names; empty if none>
evidence: <run output directory; for Maestro, the run directory under ~/.maestro/tests/>
```

Do not include passing-test names, failure messages, command output, logs, or prose in the
hand-back. Keep verbatim failures in files under `evidence`. A fix sub-agent reads those files;
the orchestrator does not.

## Flakes

Re-run every failed test once. A test that passes on its re-run is `flaky`, not `fail`. List it
under `flaky`. Flaky tests do not fail this step.

## Environment Errors

Return `env-error` for no device, an emulator boot failure, or an install failure. Do not report
these as test failures. The fix loop never runs on `env-error`.
