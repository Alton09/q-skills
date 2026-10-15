# Design review

Use this review in stage 2 before the user says "go". Its purpose is to settle visible choices
while changes are still cheap and to make later unplanned decisions easy to spot.

## Checklist

Ask and record an answer to each question:

1. Does the item contradict the brief, an approved design note, or either `decisions.md`?
2. Does it change architecture, CI, lint, build or dependency files, or module layout? If so,
   which paths should the PR touch?
3. Is any part hard to reverse, such as a data or schema migration, a public API or module
   boundary, a removed feature, or an action outside the repository?
4. What changes for users in behavior, UX, or public API naming?
5. Does it add dependencies or need an unusual amount of quota?
6. Does it affect authentication, secrets, permissions, cryptography, or another security
   boundary?

Put every answer in the design note for a substantial item or in the appropriate
`decisions.md` for a small item. Record expected paths from question 2 so stage-5 PR review can
compare intent with the diff. Mark unknowns explicitly instead of guessing; the implementation
worker reports choices it makes later under `### Unplanned Decisions` in the PR body.
