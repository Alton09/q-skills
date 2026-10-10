# Comment Mode

Use this reference for the default mode in `SKILL.md` Step 4. It produces `kind: comments`
fix jobs (`SKILL.md` § "Fix jobs") and does its GitHub write-back in Step 8. Markers are
defined in `SKILL.md` § "Markers".

## Step 4a: Fetch

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
          comments(last: 100) {
            nodes {
              id
              databaseId
              author { login __typename }
              body
              createdAt
              url
              diffHunk
            }
          }
        }
      }
      reviews(last: 50) {
        nodes { id url author { login __typename } state body submittedAt }
      }
      comments(last: 100) {
        nodes { body createdAt }
      }
    }
  }
}
```

`comments(last: 100)` on a thread returns the newest comments, so the last node is the
thread's last comment even on a long thread. If `reviewThreads.pageInfo.hasNextPage` is
true, repeat the query with `$threadCursor` set to `endCursor` and continue until it is
false. Retain the reviews and PR comments from the first response; append every page of
thread nodes. Write the raw GraphQL result(s) to the session scratchpad, not to the
transcript. Use the scratchpad data for every later decision in this mode.

The **review-summary cutoff** is the `createdAt` of the newest PR comment whose body
contains `<!-- address-pr:comments -->`. Only comment-mode round summaries carry that
marker, so CI and sync comments never move the cutoff. If no such comment exists, this is
the first run and there is no cutoff.

## Step 4b: Needs action and triage

An author is a **bot** when GraphQL `author.__typename` is `Bot`. GraphQL returns a bot's
login without the `[bot]` suffix, so the login alone cannot identify one. An author is
**eligible** when it is not a bot, or when its `author.login` is in `PR_BOT_ALLOWLIST`.

A review thread needs action only when all of the following are true:

- It is unresolved.
- Its last comment does not contain `<!-- address-pr:` (this skill has not replied last).
- Its last comment's author is eligible.

A non-empty review summary `body` from `reviews(last: 50)` needs action when its author is
eligible and its `submittedAt` is after the review-summary cutoff. On a first run, every
eligible non-empty review summary needs action.

If nothing needs action, report that there is nothing to address and follow `SKILL.md`
§ "Early exits".

Classify every actionable thread or review summary as exactly one of:

- `fix`: code must change.
- `answer`: it is a question or is already addressed; reply only and make no
  code change. Outdated threads are still triaged, and an outdated thread whose
  code is already fixed is a valid `answer`.
- `pushback`: the request is wrong, outside the plan or scope, or conflicts with
  the plan or design. State the specific reason; offer a follow-up issue for an
  out-of-scope request.
- `ask-user`: the skill cannot settle the item.

If a thread already has a comment containing `<!-- address-pr:pushback -->` and the reviewer
has commented after it, classify the thread as `ask-user`. Never push back twice on one
thread: a second pushback is an argument the user must settle.

A review summary has no file path to group by and no thread to reply to. Classify it as
`fix` only when its text names the files to change; otherwise a summary that asks for a
change is `ask-user`.

Before any push, collect every `ask-user` item into one question round, following
`SKILL.md` § "Asking the user". Convert each answer into a `fix`, `answer`, or `pushback`
item in this same round.

## Step 4c: Fix jobs

Group `fix` items by file path and create one `kind: comments` fix job per group. Its
`files` value contains that file, and its `payload` carries, for each thread, the thread
`path`, `line`, `diffHunk`, full comment text, and thread `id`. A `fix` review summary joins
the group of each file it names, with its body and review `url` in the payload. Do not
create a fix job for `answer` or `pushback` items.

Send these jobs through the serial fix-worker flow in `SKILL.md` Steps 5–7.

## Step 8: GitHub write-back

Reply to every handled thread using `addPullRequestReviewThreadReply`:

```graphql
mutation ReplyToThread($threadId: ID!, $body: String!) {
  addPullRequestReviewThreadReply(
    input: { pullRequestReviewThreadId: $threadId, body: $body }
  ) {
    comment { id }
  }
}
```

| Outcome | Reply text | Marker |
| --- | --- | --- |
| fix job `fixed` | `Fixed in <short sha>: <one line>` | `<!-- address-pr:fix -->` |
| `answer` | the answer | `<!-- address-pr:answer -->` |
| `pushback` | the specific pushback reason | `<!-- address-pr:pushback -->` |
| fix job `failed` | no reply | — |

A thread whose fix job failed gets no reply, so its last comment stays unmarked and the next
run picks it up again. Never post `Fixed in` for a failed job. A failed review summary is
not retried, because this round's summary moves the cutoff past it; list it in the Step 9
report as needing the user.

Do not resolve any review thread; the reviewer resolves it. Then post one round-summary PR
comment with `gh pr comment`. Include:

- the count for each triage class;
- every failed fix, with the worker's `note`;
- every `ask-user` item and its answer;
- each handled review summary, linked by its `url`, with its outcome (the fix SHA, the
  answer, or the pushback reason), because review summaries cannot take a thread reply.

End it with `<!-- address-pr:comments -->`. This comment sets the next run's review-summary
cutoff.
