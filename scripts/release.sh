#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# release.sh — Two-step plugin release tool for the q-skills mono-repo.
#
# USAGE
#   Step 1 (on main, before PR):
#     ./scripts/release.sh prepare <plugin> <version>
#       Bumps the version in both plugins/<name>/.claude-plugin/plugin.json
#       and .claude-plugin/marketplace.json, commits with subject
#       "release <plugin>--v<version>", pushes a release branch, and opens
#       a PR. Review the PR and SQUASH-MERGE it — do not change the PR title.
#
#   Step 2 (on freshly-pulled main, after squash-merge):
#     git switch main && git pull
#     ./scripts/release.sh tag
#       Parses the HEAD commit subject via RELEASE_RE, validates both
#       manifests were touched, and pushes an annotated tag <name>--vX.Y.Z.
#
# KEY CONSTRAINTS
#   - PR title must equal the commit subject ("release <plugin>--v<version>").
#     Squash-merge appends "(#N)", which RELEASE_RE tolerates — but a manually
#     edited PR title will break `tag`'s regex parse.
#   - `tag` asserts HEAD == origin/main; always run after `git pull`.
#   - Tags follow the <name>--vX.Y.Z convention, feeding Claude Code's
#     {name}--v* dependency resolver and #ref pinning.
#   - `prepare` updates both plugin.json and marketplace.json in one commit
#     to prevent version drift between the two files.
#
# AVAILABLE PLUGINS: workflow-kit  dev-toolkit
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Shared constants
# ---------------------------------------------------------------------------

ROOT="$(git rev-parse --show-toplevel)"
PLUGINS=("workflow-kit" "dev-toolkit")
MARKETPLACE="$ROOT/.claude-plugin/marketplace.json"

# Matches commit subjects produced by the release workflow:
#   release <plugin>--v<semver>
#   release <plugin>--v<semver> (#N)   ← squash-merge suffix
RELEASE_RE='^release ([a-z-]+)--v([0-9]+\.[0-9]+\.[0-9]+)( \(#[0-9]+\))?$'

# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------

# Print message to stderr and exit 1.
die() {
    echo "error: $*" >&2
    exit 1
}

# Print full help text to stdout and exit 0 (explicit help request).
help() {
    cat <<EOF
release.sh — Two-step plugin release tool for the q-skills mono-repo.

USAGE
  ./scripts/release.sh <subcommand> [args]
  ./scripts/release.sh help | -h | --help

SUBCOMMANDS
  prepare <plugin> <version>
      Bump the version in both plugin.json and marketplace.json, commit with
      subject "release <plugin>--v<version>", push a release branch, and open
      a PR. If plugin or version are omitted, an interactive prompt is shown.

      After the PR is open: review it and SQUASH-MERGE it. Do NOT edit the
      PR title — tag parses the squash-merge subject via regex.

  tag
      Run on freshly-pulled main after the squash-merge. Parses the HEAD
      commit subject, validates both manifests were touched, and pushes an
      annotated tag <plugin>--vX.Y.Z.

AVAILABLE PLUGINS
  ${PLUGINS[*]}

TWO-STEP FLOW
  1. ./scripts/release.sh prepare <plugin> <version>
       -> review & squash-merge the PR (do not change the PR title)
  2. git switch main && git pull
     ./scripts/release.sh tag

EXAMPLES
  ./scripts/release.sh prepare workflow-kit 1.1.0
  ./scripts/release.sh prepare dev-toolkit 2.0.0
  ./scripts/release.sh tag
EOF
    exit 0
}

# Print usage hint to stderr and exit non-zero (misuse / unknown subcommand).
usage() {
    cat >&2 <<EOF
Usage: release.sh <subcommand> [args]

Subcommands:
  prepare <plugin> <version>   Bump versions, commit, push branch, open PR
  tag                          Parse HEAD release commit and push the plugin tag

Available plugins: ${PLUGINS[*]}

Run 'release.sh help' for full documentation.
EOF
    exit 1
}

# Return 0 if $1 is a member of PLUGINS, non-zero otherwise.
is_valid_plugin() {
    local plugin="$1"
    local p
    for p in "${PLUGINS[@]}"; do
        [[ "$p" == "$plugin" ]] && return 0
    done
    return 1
}

# Return 0 if $1 matches a three-part semver string (e.g. 1.2.3).
is_semver() {
    [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

# Echo the path to a plugin's manifest file.
plugin_manifest() {
    echo "$ROOT/plugins/$1/.claude-plugin/plugin.json"
}

# Echo the current version field from a plugin's manifest.
current_version() {
    jq -r .version "$(plugin_manifest "$1")"
}

# Die if the working tree has uncommitted changes (staged or unstaged).
require_clean_tree() {
    git diff --quiet && git diff --cached --quiet \
        || die "working tree is not clean — commit or stash changes first"
}

# Die if the current branch is not $1.
require_branch() {
    local expected="$1"
    local actual
    actual="$(git rev-parse --abbrev-ref HEAD)"
    [[ "$actual" == "$expected" ]] \
        || die "must be on branch '$expected' (currently on '$actual')"
}

# Die with a clear message if jq or gh are not found on PATH.
require_tools() {
    local missing=()
    command -v jq &>/dev/null || missing+=("jq")
    command -v gh &>/dev/null || missing+=("gh")
    if [[ ${#missing[@]} -gt 0 ]]; then
        die "required tool(s) not found: ${missing[*]} — please install them and ensure they are on PATH"
    fi
}

# ---------------------------------------------------------------------------
# Subcommand stubs  (bodies implemented in later phases)
# ---------------------------------------------------------------------------

cmd_prepare() {
    local plugin="${1:-}"
    local version="${2:-}"

    # -------------------------------------------------------------------------
    # 1. Resolve plugin
    # -------------------------------------------------------------------------
    if [[ -z "$plugin" ]]; then
        echo "Select a plugin:" >&2
        select plugin in "${PLUGINS[@]}"; do
            [[ -n "$plugin" ]] && break
            echo "Invalid selection. Try again." >&2
        done
    fi
    is_valid_plugin "$plugin" || die "unknown plugin '$plugin'. Valid plugins: ${PLUGINS[*]}"

    # -------------------------------------------------------------------------
    # 2. Current version
    # -------------------------------------------------------------------------
    local cur
    cur="$(current_version "$plugin")"

    # -------------------------------------------------------------------------
    # 3. Resolve target version
    # -------------------------------------------------------------------------
    if [[ -z "$version" ]]; then
        # Compute next patch / minor / major suggestions
        local major minor patch
        IFS='.' read -r major minor patch <<< "$cur"
        local next_patch="${major}.${minor}.$((patch + 1))"
        local next_minor="${major}.$((minor + 1)).0"
        local next_major="$((major + 1)).0.0"

        echo "Current version of $plugin: $cur" >&2
        echo "Select next version:" >&2
        PS3="Choice (or 4 to enter manually): "
        select choice in "$next_patch" "$next_minor" "$next_major" "Enter manually"; do
            case "$REPLY" in
                1) version="$next_patch"; break ;;
                2) version="$next_minor"; break ;;
                3) version="$next_major"; break ;;
                4)
                    read -rp "Enter version (x.y.z): " version
                    break
                    ;;
                *) echo "Invalid selection. Try again." >&2 ;;
            esac
        done
    fi

    is_semver "$version" || die "invalid semver '$version' — must match x.y.z"

    # -------------------------------------------------------------------------
    # 4. Guard rails
    # -------------------------------------------------------------------------
    [[ "$version" != "$cur" ]] \
        || die "version $version is the same as the current version — nothing to release"

    local higher
    higher="$(printf '%s\n%s\n' "$cur" "$version" | sort -V | tail -1)"
    [[ "$higher" == "$version" && "$higher" != "$cur" ]] \
        || die "version $version is not strictly greater than current version $cur — downgrade/duplicate not allowed"

    local tag_ref="$plugin--v$version"
    git rev-parse -q --verify "refs/tags/$tag_ref" &>/dev/null \
        && die "tag '$tag_ref' already exists — has this version already been released?"

    # -------------------------------------------------------------------------
    # 5. Preconditions (run BEFORE any file changes)
    # -------------------------------------------------------------------------
    require_clean_tree
    require_branch main
    git fetch
    local behind
    behind="$(git rev-list --count HEAD..origin/main)"
    [[ "$behind" -eq 0 ]] \
        || die "local main is $behind commit(s) behind origin/main — run 'git pull' first"

    # -------------------------------------------------------------------------
    # 6. Create release branch
    # -------------------------------------------------------------------------
    local branch="release/$plugin--v$version"
    git switch -c "$branch"

    # -------------------------------------------------------------------------
    # 7. Update both manifests
    # -------------------------------------------------------------------------
    local plugin_json
    plugin_json="$(plugin_manifest "$plugin")"
    local tmp
    tmp="$(mktemp)"

    # Update plugin.json
    jq --arg v "$version" '.version = $v' "$plugin_json" > "$tmp" \
        && mv "$tmp" "$plugin_json"

    # Update marketplace.json
    jq --arg p "$plugin" --arg v "$version" \
        '(.plugins[] | select(.name == $p) | .version) |= $v' \
        "$MARKETPLACE" > "$tmp" \
        && mv "$tmp" "$MARKETPLACE"

    # -------------------------------------------------------------------------
    # 8. Commit
    # -------------------------------------------------------------------------
    local commit_subject="release $plugin--v$version"
    git add "$plugin_json" "$MARKETPLACE"
    git commit -m "$commit_subject"

    # -------------------------------------------------------------------------
    # 9. Push branch
    # -------------------------------------------------------------------------
    git push -u origin "$branch"

    # -------------------------------------------------------------------------
    # 10. Open PR
    # -------------------------------------------------------------------------
    local pr_url
    pr_url="$(gh pr create \
        --base main \
        --head "$branch" \
        --title "$commit_subject" \
        --body "$(cat <<EOF
## Version bump: $plugin $cur → $version

- Updated \`plugins/$plugin/.claude-plugin/plugin.json\` version to \`$version\`
- Updated \`.claude-plugin/marketplace.json\` entry for \`$plugin\` to \`$version\`

---
*Generated by \`release.sh prepare\`*
EOF
)")"

    # -------------------------------------------------------------------------
    # 11. Print PR URL
    # -------------------------------------------------------------------------
    echo "$pr_url"
}

cmd_tag() {
    # -------------------------------------------------------------------------
    # 1. Preconditions
    # -------------------------------------------------------------------------
    require_branch main
    require_clean_tree
    git fetch

    local head origin
    head="$(git rev-parse HEAD)"
    origin="$(git rev-parse origin/main)"
    [[ "$head" == "$origin" ]] \
        || die "HEAD is not at origin/main — run 'git pull' first (local: ${head:0:7}, origin: ${origin:0:7})"

    # -------------------------------------------------------------------------
    # 2. Parse HEAD commit subject
    # -------------------------------------------------------------------------
    local subject
    subject="$(git log -1 --pretty=%s)"
    [[ "$subject" =~ $RELEASE_RE ]] \
        || die "HEAD is not a release commit (got: $subject)"

    # -------------------------------------------------------------------------
    # 3. Extract plugin and version from regex match
    # -------------------------------------------------------------------------
    local plugin version tag
    plugin="${BASH_REMATCH[1]}"
    version="${BASH_REMATCH[2]}"
    tag="$plugin--v$version"

    # -------------------------------------------------------------------------
    # 4. Diff guard — release commit must touch both manifests
    # -------------------------------------------------------------------------
    local changed_files
    changed_files="$(git show --name-only --pretty=format: HEAD)"

    echo "$changed_files" | grep -qF "plugins/$plugin/.claude-plugin/plugin.json" \
        || die "release commit did not modify plugins/$plugin/.claude-plugin/plugin.json"
    echo "$changed_files" | grep -qF ".claude-plugin/marketplace.json" \
        || die "release commit did not modify .claude-plugin/marketplace.json"

    # -------------------------------------------------------------------------
    # 5. Sanity: version in plugin.json must match commit subject
    # -------------------------------------------------------------------------
    local actual_version
    actual_version="$(current_version "$plugin")"
    [[ "$actual_version" == "$version" ]] \
        || die "plugin.json version ($actual_version) does not match commit subject version ($version)"

    # -------------------------------------------------------------------------
    # 6. Assert tag does not already exist
    # -------------------------------------------------------------------------
    git rev-parse -q --verify "refs/tags/$tag" &>/dev/null \
        && die "tag '$tag' already exists — has this version already been released?"

    # -------------------------------------------------------------------------
    # 7. Create annotated tag
    # -------------------------------------------------------------------------
    git tag -a "$tag" -m "Release $plugin v$version" HEAD

    # -------------------------------------------------------------------------
    # 8. Push tag
    # -------------------------------------------------------------------------
    git push origin "$tag"

    # -------------------------------------------------------------------------
    # 9. Confirm
    # -------------------------------------------------------------------------
    local short_sha
    short_sha="$(git rev-parse --short HEAD)"
    echo "Tagged $tag → $short_sha"
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

require_tools

case "${1:-}" in
    prepare)        shift; cmd_prepare "$@" ;;
    tag)            shift; cmd_tag     "$@" ;;
    help|-h|--help) help ;;
    "")             usage ;;
    *)              echo "error: unknown subcommand '${1}'" >&2; echo >&2; usage ;;
esac
