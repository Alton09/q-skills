# Comment Mode

Use this reference for the default mode in `SKILL.md` Step 4. This mode produces
zero or more `fix job` values with the shape
`{id, kind: comments|ci|conflict|verify, files, payload}` and does its GitHub
write-back in Step 8.

## Step 4: Fetch

Fetch the PR data with `gh api graphql`. Use one query, initially with
`$threadCursor: null`, and request these exact fields:

```graphql
query CommentMode($owner: String!, $repo: String!, $number: Int!, $threadCursor: String) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      reviewThreads(first: 100, after: $threadCursor) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id
          isResolved
          isOutdated
          path
          line
          diffSide
          comments(first: 50) {
            nodes {
              id
              databaseId
              author { login }
              body
              createdAt
              url
              diffHunk
            }
          }
        }
      }
      reviews(last: 50) {
        nodes { id author { login } state body submittedAt }
      }
      comments(last: 100) {
        nodes { body createdAt }
      }
    }
  }
}
```

If `reviewThreads.pageInfo.hasNextPage` is true, repeat the query with
`$threadCursor` set to `endCursor` and continue until it is false. Retain the
reviews and PR comments from the first response; append every page of thread
nodes. Write the raw GraphQL result(s) to the session scratchpad, not to the
transcript. Use the scratchpad data for every later decision in this mode.

The PR `comments` field finds the newest previous round-summary comment whose
body contains `<!-- address-pr -->`. Its `createdAt` is the review-body cutoff.
If no marked round-summary comment exists, this is the first run and there is no
cutoff.

## Step 4: Needs action and triage

The marker is `<!-- address-pr -->`. A review thread needs action only when all
of the following are true:

- It is unresolved.
- Its last comment does not contain the marker.
- The actionable comment's author is a human, or its GraphQL `author.login` is listed in
  `PR_BOT_ALLOWLIST`. The default allowlist recognizes both login forms:
  `copilot-pull-request-reviewer,copilot-pull-request-reviewer[bot],coderabbitai,coderabbitai[bot]`.

Skip comments from bots not in that allowlist. A marked reply is the reliable
record that this skill already handled the thread, even when the user's `gh`
account is also the reviewer's account.

Treat each non-empty review summary `body` from `reviews(last:50)` as needing
action when `submittedAt` is after the newest marked round-summary comment's
`createdAt`. On a first run, every such review body needs action. Apply the same
human-or-allowlisted-bot author rule to review summaries.

If no thread or review summary needs action, report that there is nothing to address and
follow `SKILL.md` § "Early exits": skip Steps 5–8, release the lock, and run Step 9's
report, including `address-pr: done #<number> no-push` under `--worker`. Do not start
workers, push, reply to threads, or post a round-summary comment.

Classify every actionable thread or review body as exactly one of:

- `fix`: code must change.
- `answer`: it is a question or is already addressed; reply only and make no
  code change. Outdated threads are still triaged, and an outdated thread whose
  code is already fixed is a valid `answer`.
- `pushback`: the request is wrong, outside the plan or scope, or conflicts with
  the plan or design. State the specific reason; offer a follow-up issue for an
  out-of-scope request.
- `ask-user`: the skill cannot settle the item.

If this skill has already pushed back once on a thread and the reviewer comments
again, classify it as `ask-user`. Never push back twice on one thread.

Before any push, collect every `ask-user` item into one Ask tier question round,
following `SKILL.md` § "Asking the user". Convert the answers into fixes or
replies in this same round. In a `--worker` invocation, preserve the lock while
waiting as that section requires.

## Step 4: Fix jobs

Group `fix` items by file path and create one `kind: comments` fix job per
group. Its `files` value contains that file, and its `payload` carries, for each
thread, the thread `path`, `line`, `diffHunk`, full comment text, and thread
`id`. Give the job a stable `id`. Do not create a fix job for `answer`,
`pushback`, or `ask-user` items that resolve as replies.

Send these jobs through the serial fix-worker flow in `SKILL.md` Steps 5--7.
Respect its router decisions and report each router `warnings` entry once in the
terminal report; comment mode does not alter the Ask tier or GitHub push rules.

## Step 8: GitHub write-back

Only after the successful push, reply to every handled thread using
`addPullRequestReviewThreadReply`:

```graphql
mutation ReplyToThread($threadId: ID!, $body: String!) {
  addPullRequestReviewThreadReply(
    input: { pullRequestReviewThreadId: $threadId, body: $body }
  ) {
    comment { id }
  }
}
```

For a fix, the reply text is `Fixed in <short sha>: <one line>`. For an answer,
use the answer; for a pushback, use the specific pushback reason. End every
reply with the marker on its own line:

```html
<!-- address-pr -->
```

Do not resolve any review thread; the reviewer resolves it. Then post one
round-summary PR comment with `gh pr comment`. Include the count for each
triage class, every `ask-user` item and its answer, and the marker. This summary
is the marked round-summary comment used as the next run's review-body cutoff.
