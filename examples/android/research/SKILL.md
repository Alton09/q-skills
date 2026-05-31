---
name: research
description: >
  Research Android API surfaces using the android CLI and return findings as text.
  Use this skill to look up API docs, find latest documentation, research Android APIs,
  check for deprecations, or discover migration paths before planning implementation.
---

# Research

Look up an Android API surface using the `android` CLI's docs commands. Return findings
as text for the caller (feature-plan) to fold into task instructions.

## Two-Step Flow

### Step 1: Search

```bash
android docs search "<query>"
```

Returns ranked results with `kb://...` knowledge-base URLs. Use a focused query — the API
class or concept name, optionally with a relevant keyword (e.g. `"WorkManager constraints"`,
`"Compose LazyColumn performance"`).

### Step 2: Fetch

```bash
android docs fetch "<kb-url>"
```

Fetches the full doc content for a specific `kb://` URL from the search results.

Fetch the **top 1–3 most relevant** results from Step 1. Skip results that are clearly
off-topic (changelogs, unrelated modules).

## Return Format

Return a summary with these sections (omit any that have no content):

- **Latest API** — current recommended approach, key types and methods
- **Deprecated alternatives** — what the old way was and when it was deprecated
- **Migration paths** — steps to move from deprecated to current
- **Version constraints** — minimum API level, library version requirements (e.g. `compileSdk 34`, `lifecycle:2.7+`)

Keep findings focused on what the caller needs to write accurate task instructions.
Do not reproduce entire doc pages — extract the actionable signal.

## Dependency and Fallback

This skill requires the `android` CLI to be installed and available on PATH.

**If `android docs search` is unavailable:** Return `no findings — android CLI not installed`.
The caller (feature-plan) degrades gracefully: `/research` is an optional delegate and
feature-plan will proceed without research output. Do not block or error — just report the gap.
