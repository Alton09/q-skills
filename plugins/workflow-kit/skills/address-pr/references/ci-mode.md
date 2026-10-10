# CI Mode

Use this reference for `--ci` in `SKILL.md` Step 4. CI mode reads the PR's checks,
identifies actionable failures, creates `kind: ci` fix jobs (`SKILL.md` § "Fix jobs"), and
returns to the normal Step 5 through Step 8 flow. Every user decision below follows
`SKILL.md` § "Asking the user"; leave the worktree unchanged while waiting.

## Step 4a: Read and normalize checks

Read checks with:

```bash
gh pr view <number> --json statusCheckRollup
```

Do not use `gh pr checks --json`; the supported gh version does not provide it. The
`statusCheckRollup` nodes have two shapes. Normalize each node to:

```text
{name, state, link, kind}
```

where `state` is `failed`, `pending`, or `passing`, and `kind` is `actions` for a
`CheckRun` or `status` for a `StatusContext`.

- For a `CheckRun`, use `name`, `status`, `conclusion`, `detailsUrl`, and `workflowName`.
  Set `name` from `name` and `link` from `detailsUrl`. It is `failed` when `conclusion` is
  `FAILURE`, `TIMED_OUT`, `CANCELLED`, or `ACTION_REQUIRED`; it is `pending` when `status`
  is not `COMPLETED`; otherwise it is `passing`. Retain `workflowName` and the original
  fields as private triage metadata.
- For a `StatusContext`, use `context`, `state`, and `targetUrl`. Set `name` from
  `context` and `link` from `targetUrl`. It is `failed` when its source `state` is
  `FAILURE` or `ERROR`; it is `pending` when that state is `PENDING` or `EXPECTED`;
  otherwise it is `passing`. Retain the source `context` as private triage metadata.

If one or more checks are pending, wait rather than guessing their result. Start this as a
background Bash command, not a foreground wait:

```bash
timeout "${CI_WAIT_TIMEOUT:-30m}" gh pr checks <number> --watch --interval 30
```

When the background command exits, read `statusCheckRollup` again and continue with the
new normalized result. If it timed out, report the pending checks and ask.

**Green rule:** when no check is `failed` (on the first read, or after any wait), report
that CI is green and follow `SKILL.md` § "Early exits". Do not create jobs or post a CI
comment.

## Step 4b: Collect evidence and triage failures

For each failed `CheckRun` whose `detailsUrl` is a GitHub Actions run, extract the run ID
from that URL. Fetch its failed log and save the complete result in this invocation's
scratchpad:

```bash
gh run view <run-id> --log-failed
```

Use only the final 200 lines for each failed job as the evidence passed to triage or in a
fix job payload; the scratchpad remains the complete record. A `CheckRun` with a
non-Actions URL and every `StatusContext` are non-Actions failures: gh cannot retrieve
their logs. In the PR worktree, reproduce one locally by running `CI_REPRO_COMMAND` when
set, otherwise `VERIFY_SKILL`, and save its complete output to the scratchpad.

- When the non-Actions check is red locally, triage its local output as `real`.
- When it is green locally, ask the user why the remote check failed, including that
  check's `link`. Do not create a fix job because the skill has no remote failure evidence.

Classify failure evidence as exactly one of the following:

- `infra` applies only to GitHub Actions: a lost runner, network timeout, cancellation, or
  rate limit. Run `gh run rerun <run-id> --failed` at most once for each run ID during this
  invocation. Record the run ID so the same run cannot be rerun again. Then wait for and
  re-read checks as in Step 4a; do not turn a second infra failure for that run into
  another rerun.
- `base-red` means the same check also fails on the base branch head. For Actions, inspect
  the matching workflow with:

  ```bash
  gh run list --branch <base> --workflow <workflowName> --limit 1 --json conclusion
  ```

  For a commit status, inspect:

  ```bash
  gh api repos/{owner}/{repo}/commits/<base>/status
  ```

  and find the status with the same `context`. This test applies to both `CheckRun` and
  `StatusContext` failures. If it is base-red, report "base branch is red", do not fix it,
  and ask the user.
- `real` is every actionable failure that is neither infra nor base-red. Create one `ci`
  fix job per failed job or check. Its payload includes the check name, the log excerpt or
  local output, and an instruction to reproduce locally through `CI_REPRO_COMMAND`,
  `VERIFY_SKILL`, or the failing command before changing code. Include only files the
  evidence identifies; use an empty `files` list when it identifies none.

## Rounds and Step 8: GitHub write-back

Treat the initial fix attempt as round 1. Send its `real` jobs one at a time through the
serial fix-worker flow in Steps 5 and 6. If the gate passes, Step 7 pushes the branch.
After each push, wait for and re-read CI (Step 4a), then repeat Step 4b for another round
as needed. Run at most `CI_FIX_MAX_ROUNDS` rounds (default `2`). If checks remain red after
that limit, stop and ask; do not make another fix job or push.

After each round that pushed a commit or reran a run, post exactly one PR comment for that
round listing every check
fixed, rerun, or left red, with its link. Include checks left red because they are
base-red, green locally, still pending after the wait, had a failed fix job, or exhausted
the round limit. End the comment with `<!-- address-pr:ci -->`.
