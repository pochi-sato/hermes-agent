#!/usr/bin/env bash
# Safe update flow for the pochinin fork's runtime branch.
#
# Problem this exists to prevent: the live gateway checkout
# (~/.hermes/hermes-agent) sits on a branch, `hermes update` auto-stashes any
# uncommitted local work before fast-forwarding, and nothing ever restores that
# stash.  Fork-local fixes therefore survive only as orphan stash entries while
# the running gateway quietly loses them.  See docs/pochinin-runtime-update.md.
#
# The flow here keeps the live checkout READ-ONLY.  Everything that mutates git
# happens in a separate staging worktree; switching the live checkout and
# restarting the gateway stay manual, printed as copy-pasteable commands.
#
# This script never runs: stash pop/drop, reset --hard, clean, checkout of the
# live checkout, or push --force.  If a step would need one of those, it stops
# and reports instead.
#
# Usage:
#   scripts/pochinin-runtime-update.sh status
#   scripts/pochinin-runtime-update.sh stash-audit
#   scripts/pochinin-runtime-update.sh preflight
#   scripts/pochinin-runtime-update.sh prepare [--dry-run] [--push] [--no-tests]

set -euo pipefail

LIVE_CHECKOUT="${HERMES_LIVE_CHECKOUT:-$HOME/.hermes/hermes-agent}"
STAGING_WORKTREE="${HERMES_RUNTIME_STAGING:-$HOME/.hermes/worktrees/hermes-runtime-update}"
RUNTIME_BRANCH="${HERMES_RUNTIME_BRANCH:-pochinin/runtime}"
STAGING_BRANCH="${HERMES_RUNTIME_STAGING_BRANCH:-pochinin/runtime-staging}"
UPSTREAM_REMOTE="${HERMES_UPSTREAM_REMOTE:-upstream}"
UPSTREAM_BRANCH="${HERMES_UPSTREAM_BRANCH:-main}"
ORIGIN_REMOTE="${HERMES_ORIGIN_REMOTE:-origin}"

# Focused tests that guard the fork-local behavior. Override with a
# space-separated list when the runtime branch grows new fork-local patches.
FOCUSED_TESTS="${HERMES_RUNTIME_TESTS:-tests/gateway/test_discord_free_response.py tests/gateway/test_restart_service_detection.py}"

DRY_RUN=0
DO_PUSH=0
RUN_TESTS=1

say() { printf '%s\n' "$*"; }
section() { printf '\n== %s ==\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

live_git() { git -C "$LIVE_CHECKOUT" "$@"; }

# Every mutating command goes through here so --dry-run is honored uniformly.
run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '  [dry-run] %s\n' "$*"
    return 0
  fi
  printf '  + %s\n' "$*"
  "$@"
}

require_live_checkout() {
  [ -d "$LIVE_CHECKOUT/.git" ] || [ -f "$LIVE_CHECKOUT/.git" ] \
    || fail "live checkout not found at $LIVE_CHECKOUT (set HERMES_LIVE_CHECKOUT)"
}

# `prepare` must not run from inside the live checkout: that checkout is the
# thing being protected, and a mutating flow driven from it invites exactly the
# accidental switch/stash this script exists to avoid.
refuse_when_inside_live_checkout() {
  local here live
  here="$(cd "$PWD" && pwd -P)"
  live="$(cd "$LIVE_CHECKOUT" && pwd -P)"
  case "$here" in
    "$live" | "$live"/*)
      say "FAIL: run this from a staging worktree, not from the live checkout."
      say ""
      say "  live checkout : $live"
      say "  create one    : git -C \"$live\" worktree add \"$STAGING_WORKTREE\" -b $STAGING_BRANCH $ORIGIN_REMOTE/$RUNTIME_BRANCH"
      say "  then          : cd \"$STAGING_WORKTREE\" && scripts/pochinin-runtime-update.sh prepare"
      exit 1
      ;;
  esac
}

live_dirty_count() {
  live_git status --porcelain=v1 | wc -l | tr -d ' '
}

cmd_status() {
  require_live_checkout

  section "live checkout ($LIVE_CHECKOUT)"
  say "branch      : $(live_git rev-parse --abbrev-ref HEAD)"
  say "HEAD        : $(live_git log --oneline -1)"
  say "dirty paths : $(live_dirty_count)"
  say "stashes     : $(live_git stash list | wc -l | tr -d ' ')"

  section "remotes"
  live_git remote -v | awk '$3 == "(fetch)" { print "  " $1 " -> " $2 }'

  section "branch positions (no fetch; run 'prepare' to refresh)"
  local runtime_ref="$ORIGIN_REMOTE/$RUNTIME_BRANCH"
  local upstream_ref="$UPSTREAM_REMOTE/$UPSTREAM_BRANCH"
  if live_git rev-parse --verify --quiet "$runtime_ref" >/dev/null; then
    say "$runtime_ref : $(live_git log --oneline -1 "$runtime_ref")"
  else
    say "$runtime_ref : MISSING"
  fi
  if live_git rev-parse --verify --quiet "$upstream_ref" >/dev/null; then
    say "$upstream_ref : $(live_git log --oneline -1 "$upstream_ref")"
  else
    say "$upstream_ref : MISSING"
  fi
  if live_git rev-parse --verify --quiet "$runtime_ref" >/dev/null \
    && live_git rev-parse --verify --quiet "$upstream_ref" >/dev/null; then
    local counts
    counts="$(live_git rev-list --left-right --count "$runtime_ref...$upstream_ref")"
    say "runtime ahead/behind upstream : $counts (ahead<TAB>behind)"
  fi

  section "is the live checkout running the runtime branch?"
  local head_sha runtime_sha
  head_sha="$(live_git rev-parse HEAD)"
  if runtime_sha="$(live_git rev-parse --verify --quiet "$runtime_ref")"; then
    if [ "$head_sha" = "$runtime_sha" ]; then
      say "yes — live HEAD == $runtime_ref"
    elif live_git merge-base --is-ancestor "$runtime_sha" "$head_sha"; then
      say "no — live HEAD is ahead of $runtime_ref (fork patches may be unpushed)"
    else
      say "no — live HEAD differs from $runtime_ref; fork patches are NOT running"
    fi
  fi
}

# Read-only: classifies every live stash entry against the runtime branch so a
# human can decide whether dropping it loses anything. Never drops.
#
# Classification compares three blobs per path — the stash's base (what the file
# looked like before the stashed edit), the stashed content, and the runtime
# branch's content:
#   RESCUED  stash content == runtime content, the change is already on the branch
#   MISSING  runtime content == base content, the branch has none of the change
#   DRIFT    all three differ, usually because upstream also moved the file
cmd_stash_audit() {
  require_live_checkout
  local target="$ORIGIN_REMOTE/$RUNTIME_BRANCH"
  live_git rev-parse --verify --quiet "$target" >/dev/null \
    || fail "$target not found in $LIVE_CHECKOUT — fetch it first"

  local stashes
  stashes="$(live_git stash list --format='%gd|%gs')"
  if [ -z "$stashes" ]; then
    say "no stash entries in $LIVE_CHECKOUT"
    return 0
  fi

  local ref subject files untracked path
  while IFS='|' read -r ref subject; do
    [ -n "$ref" ] || continue
    section "$ref — $subject"

    # Tracked changes carried by the stash commit, plus untracked files (the
    # third parent, present only when the stash was taken with -u).
    files="$(live_git diff --name-only "$ref^" "$ref" || true)"
    untracked=""
    if live_git rev-parse --verify --quiet "$ref^3" >/dev/null; then
      untracked="$(live_git ls-tree -r --name-only "$ref^3")"
    fi

    if [ -z "$files$untracked" ]; then
      say "  (empty stash)"
      continue
    fi

    while IFS= read -r path; do
      [ -n "$path" ] || continue
      classify_stash_path "$ref:$path" "$ref^:$path" "$target:$path" "$path" ""
    done <<EOF
$files
EOF

    while IFS= read -r path; do
      [ -n "$path" ] || continue
      classify_stash_path "$ref^3:$path" "" "$target:$path" "$path" " (untracked)"
    done <<EOF
$untracked
EOF
  done <<EOF
$stashes
EOF

  say ""
  say "MISSING/DRIFT entries are not automatically lost work — a change can be"
  say "superseded by a different upstream fix. Inspect before deciding:"
  say "  git -C \"$LIVE_CHECKOUT\" diff '<stash>^' '<stash>' -- '<path>'"
  say "Nothing is dropped by this script. Drop only once every path is either"
  say "committed to $RUNTIME_BRANCH or recorded as deliberately discarded."
}

# Blob id at <rev>:<path>, empty when the path is absent there. ``--verify
# --quiet`` matters: a bare ``git rev-parse`` echoes its argument on stdout for
# a path that does not exist, which would read as a blob id.
blob_at() {
  live_git rev-parse --verify --quiet "$1" 2>/dev/null || true
}

# Args: stash-rev base-rev (may be empty) target-rev path label-suffix
classify_stash_path() {
  local stash_rev="$1" base_rev="$2" target_rev="$3" path="$4" suffix="$5"
  local stash_blob base_blob target_blob
  stash_blob="$(blob_at "$stash_rev")"
  target_blob="$(blob_at "$target_rev")"
  base_blob=""
  [ -n "$base_rev" ] && base_blob="$(blob_at "$base_rev")"

  if [ -n "$stash_blob" ] && [ "$stash_blob" = "$target_blob" ]; then
    say "  RESCUED   $path$suffix — identical in $ORIGIN_REMOTE/$RUNTIME_BRANCH"
  elif [ -z "$target_blob" ]; then
    say "  MISSING   $path$suffix — absent from $ORIGIN_REMOTE/$RUNTIME_BRANCH"
  elif [ -n "$base_blob" ] && [ "$base_blob" = "$target_blob" ]; then
    say "  MISSING   $path$suffix — branch still at the pre-stash content"
  else
    say "  DRIFT     $path$suffix — branch moved too; diff by hand"
  fi
}

cmd_preflight() {
  require_live_checkout
  local problems=0

  section "preflight"

  local dirty
  dirty="$(live_dirty_count)"
  if [ "$dirty" -ne 0 ]; then
    say "FAIL live checkout has $dirty modified/untracked path(s)."
    say "     'hermes update' would auto-stash them and never restore them."
    say "     Commit them onto $RUNTIME_BRANCH from a worktree first:"
    say "       git -C \"$LIVE_CHECKOUT\" worktree add \"$STAGING_WORKTREE\" -b $STAGING_BRANCH $ORIGIN_REMOTE/$RUNTIME_BRANCH"
    problems=$((problems + 1))
  else
    say "OK   live checkout is clean"
  fi

  local stashes
  stashes="$(live_git stash list | wc -l | tr -d ' ')"
  if [ "$stashes" -ne 0 ]; then
    say "WARN $stashes stash entrie(s) still present — run 'stash-audit' before dropping any"
  else
    say "OK   no leftover stashes"
  fi

  local remote
  for remote in "$ORIGIN_REMOTE" "$UPSTREAM_REMOTE"; do
    if live_git remote get-url "$remote" >/dev/null 2>&1; then
      say "OK   remote '$remote' configured"
    else
      say "FAIL remote '$remote' missing"
      problems=$((problems + 1))
    fi
  done

  if [ "$problems" -ne 0 ]; then
    say ""
    fail "preflight found $problems blocking problem(s)"
  fi
  say ""
  say "preflight passed"
}

ensure_staging_worktree() {
  if [ -d "$STAGING_WORKTREE/.git" ] || [ -f "$STAGING_WORKTREE/.git" ]; then
    local dirty
    dirty="$(git -C "$STAGING_WORKTREE" status --porcelain=v1 | wc -l | tr -d ' ')"
    [ "$dirty" -eq 0 ] \
      || fail "staging worktree $STAGING_WORKTREE is dirty — resolve it by hand first"
    say "  reusing staging worktree $STAGING_WORKTREE"
    return 0
  fi
  say "  creating staging worktree $STAGING_WORKTREE"
  run git -C "$LIVE_CHECKOUT" worktree add "$STAGING_WORKTREE" \
    -B "$STAGING_BRANCH" "$ORIGIN_REMOTE/$RUNTIME_BRANCH"
}

cmd_prepare() {
  require_live_checkout
  refuse_when_inside_live_checkout
  cmd_preflight

  section "fetch"
  run git -C "$LIVE_CHECKOUT" fetch "$ORIGIN_REMOTE" "$RUNTIME_BRANCH"
  run git -C "$LIVE_CHECKOUT" fetch "$UPSTREAM_REMOTE" "$UPSTREAM_BRANCH"

  section "staging worktree"
  ensure_staging_worktree

  if [ "$DRY_RUN" -eq 1 ]; then
    section "dry run"
    say "  would reset $STAGING_BRANCH onto $ORIGIN_REMOTE/$RUNTIME_BRANCH,"
    say "  merge $UPSTREAM_REMOTE/$UPSTREAM_BRANCH into it, run: $FOCUSED_TESTS"
    [ "$DO_PUSH" -eq 1 ] && say "  then push to $ORIGIN_REMOTE/$RUNTIME_BRANCH (fast-forward only)"
    say ""
    say "no changes were made"
    return 0
  fi

  section "sync staging branch"
  # ``checkout -B`` throws away whatever the staging branch pointed at. That is
  # fine for a scratch branch, and data loss for one carrying an unpushed fix —
  # so refuse rather than repeat the very failure this script exists to prevent.
  if git -C "$STAGING_WORKTREE" rev-parse --verify --quiet \
    "refs/heads/$STAGING_BRANCH" >/dev/null; then
    local unpushed
    unpushed="$(git -C "$STAGING_WORKTREE" rev-list --count \
      "$ORIGIN_REMOTE/$RUNTIME_BRANCH..refs/heads/$STAGING_BRANCH")"
    if [ "$unpushed" -ne 0 ]; then
      say "  $STAGING_BRANCH has $unpushed commit(s) missing from $ORIGIN_REMOTE/$RUNTIME_BRANCH:"
      git -C "$STAGING_WORKTREE" log --oneline \
        "$ORIGIN_REMOTE/$RUNTIME_BRANCH..refs/heads/$STAGING_BRANCH" | sed 's/^/    /'
      fail "push or delete those commits first — refusing to reset $STAGING_BRANCH"
    fi
  fi
  run git -C "$STAGING_WORKTREE" checkout -B "$STAGING_BRANCH" \
    "$ORIGIN_REMOTE/$RUNTIME_BRANCH"

  section "merge $UPSTREAM_REMOTE/$UPSTREAM_BRANCH"
  if git -C "$STAGING_WORKTREE" merge --no-edit \
    "$UPSTREAM_REMOTE/$UPSTREAM_BRANCH"; then
    say "  merge clean"
  else
    git -C "$STAGING_WORKTREE" merge --abort || true
    say ""
    say "Merge conflicts between the fork patches and upstream."
    say "Resolve them by hand in $STAGING_WORKTREE, then rerun with --no-tests"
    say "skipped so the focused tests still gate the result."
    fail "upstream merge conflicted — live checkout untouched"
  fi

  if [ "$RUN_TESTS" -eq 1 ]; then
    section "focused tests"
    # FOCUSED_TESTS is a space-separated path list, so it must word-split.
    # shellcheck disable=SC2086
    if ! (cd "$STAGING_WORKTREE" && uv run --extra dev pytest $FOCUSED_TESTS -q); then
      fail "focused tests failed in $STAGING_WORKTREE — live checkout untouched"
    fi
  else
    section "focused tests"
    say "  skipped (--no-tests)"
  fi

  if [ "$DO_PUSH" -eq 1 ]; then
    section "push"
    # No --force: a non-fast-forward here means someone else moved the branch.
    run git -C "$STAGING_WORKTREE" push "$ORIGIN_REMOTE" \
      "HEAD:refs/heads/$RUNTIME_BRANCH"
  fi

  section "next steps (manual — this script never touches the live checkout)"
  say "  1. git -C \"$LIVE_CHECKOUT\" status --porcelain    # must print nothing"
  say "  2. hermes update --branch $RUNTIME_BRANCH"
  say "  3. hermes gateway restart"
  say "  4. scripts/pochinin-runtime-update.sh status       # confirm live HEAD == runtime"
  say ""
  say "Verified candidate: $(git -C "$STAGING_WORKTREE" log --oneline -1)"
}

main() {
  local cmd="${1:-help}"
  shift || true
  local arg
  for arg in "$@"; do
    case "$arg" in
      --dry-run) DRY_RUN=1 ;;
      --push) DO_PUSH=1 ;;
      --no-tests) RUN_TESTS=0 ;;
      *) fail "unknown option: $arg" ;;
    esac
  done

  case "$cmd" in
    status) cmd_status ;;
    stash-audit) cmd_stash_audit ;;
    preflight) cmd_preflight ;;
    prepare) cmd_prepare ;;
    help | -h | --help)
      sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
      ;;
    *) fail "unknown command: $cmd (try 'help')" ;;
  esac
}

main "$@"
