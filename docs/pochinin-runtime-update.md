# Updating the pochinin runtime fork

How to pull upstream changes into the live Hermes gateway on this machine
without losing the fork-local patches — and why the obvious way loses them.

Everything here is driven by `scripts/pochinin-runtime-update.sh`.

## The failure this replaces

The live gateway runs from a single checkout, `~/.hermes/hermes-agent`.
`hermes update` fetches `origin/<branch>` and fast-forwards that checkout in
place, and before it does, it auto-stashes anything uncommitted
(`hermes-update-autostash-<timestamp>`). Nothing ever pops that stash back.

So a fix edited directly in the live checkout survives one update as a stash
entry, then sits there. By 2026-08-15 the checkout had seven such entries going
back to May, and the live checkout was on `main` at `upstream/main` — meaning
the fork's own Discord routing fix was on `origin/pochinin/runtime` and *not
running*.

Two rules follow, and the script enforces both:

1. **Fork-local changes belong in a commit on `pochinin/runtime`**, never as
   uncommitted work in the live checkout.
2. **The live checkout is read-only to tooling.** Verification happens in a
   staging worktree; switching the live checkout and restarting the gateway are
   manual steps a human runs.

## The pieces

| Name | What it is |
| --- | --- |
| live checkout | `~/.hermes/hermes-agent` — what the running gateway executes |
| `origin` | `pochi-sato/hermes-agent`, the fork |
| `upstream` | `NousResearch/hermes-agent` |
| `pochinin/runtime` | fork branch: `upstream/main` plus the fork-local patches |
| staging worktree | `~/.hermes/worktrees/hermes-runtime-update`, scratch space |

Every path and branch above is overridable by environment variable
(`HERMES_LIVE_CHECKOUT`, `HERMES_RUNTIME_BRANCH`, `HERMES_RUNTIME_STAGING`,
`HERMES_UPSTREAM_REMOTE`, …) — see the top of the script.

## Commands

```bash
scripts/pochinin-runtime-update.sh status       # read-only: where is everything?
scripts/pochinin-runtime-update.sh stash-audit  # read-only: what is in the stashes?
scripts/pochinin-runtime-update.sh preflight    # gate: is an update safe to start?
scripts/pochinin-runtime-update.sh prepare [--dry-run] [--push] [--no-tests]
```

`status`, `stash-audit`, and `preflight` only read. `prepare` is the only
mutating command, and it refuses to run from inside the live checkout — it
prints how to create the staging worktree instead.

The script never runs `git stash pop/drop`, `reset --hard`, `clean`, a checkout
of the live checkout, or `push --force`. When a step would need one of those, it
stops and reports.

## Standard update

```bash
# 1. Look before touching anything.
scripts/pochinin-runtime-update.sh status

# 2. Preflight. Fails if the live checkout is dirty — commit that work onto
#    pochinin/runtime from a worktree first, or the update will stash it away.
scripts/pochinin-runtime-update.sh preflight

# 3. Rehearse, then run for real from the staging worktree.
cd ~/.hermes/worktrees/hermes-runtime-update
scripts/pochinin-runtime-update.sh prepare --dry-run
scripts/pochinin-runtime-update.sh prepare --push
```

`prepare` fetches both remotes, resets the staging branch onto
`origin/pochinin/runtime`, merges `upstream/main` into it, and runs the focused
tests (`HERMES_RUNTIME_TESTS` to override the list). A merge conflict aborts the
merge and stops; a test failure stops. Either way the live checkout is
untouched. With `--push` the verified result goes to `origin/pochinin/runtime`
as a plain fast-forward.

Then, by hand:

```bash
git -C ~/.hermes/hermes-agent status --porcelain   # must print nothing
hermes update --branch pochinin/runtime
hermes gateway restart
scripts/pochinin-runtime-update.sh status          # live HEAD == runtime branch
```

`hermes update --branch pochinin/runtime` is what keeps the live checkout on the
fork branch — plain `hermes update` targets `main` and silently drops the fork
patches out of the running gateway.

## Stash triage

`stash-audit` classifies every path in every stash entry against
`origin/pochinin/runtime` by comparing three blobs — the stashed content, the
content it was edited from, and what the branch has now:

- `RESCUED` — the branch already has exactly this content. Nothing to save.
- `MISSING` — the branch has none of the change (absent, or still at the
  pre-stash content).
- `DRIFT` — stash and branch both moved. Needs a human diff.

Caveat: while `pochinin/runtime` lags upstream by hundreds of commits, most
paths report `DRIFT` simply because upstream rewrote them. Sync the branch
first, then audit — the classification is only sharp against a current branch.

Policy: **never drop a stash the script has not shown to be `RESCUED`, or that
has not been read and deliberately written off.** Record the write-off decision
somewhere durable (this document, or the commit that supersedes it).

## Case record: 2026-08-15 stash rescue

`stash@{0}` (`pre-loop-update-20260815-212600`), the entry that triggered this
work:

| Path | Verdict |
| --- | --- |
| `plugins/platforms/discord/adapter.py` | already rescued — the stashed `skip_thread` hunk is commit `886ce965e` on `pochinin/runtime`; the file otherwise differs only by upstream drift |
| `tests/gateway/test_discord_free_response.py` | already rescued — byte-identical to `886ce965e` |
| `tests/gateway/test_launchd_restart_detection.py` | superseded — not restored |

The launchd test imports `gateway.run._running_under_launchd_gateway_service`,
a helper that exists in no branch here and in no commit reachable from
`upstream/main`. Its supervisor detection now lives in
`gateway/restart.py::is_gateway_supervisor_process`, covered by
`tests/gateway/test_restart_service_detection.py`, and that implementation
deliberately treats *any* `XPC_SERVICE_NAME` other than `"0"` as supervised —
whereas the stashed test asserts a label allowlist (`ai.hermes.gateway*` yes,
`com.googlecode.iterm2` no) and a `platform=` argument the current helper does
not take. Restoring it would assert behavior the shipped code deliberately does
not have. It was archived to `~/.hermes/rescue/stash-20260815-212600/` and left
in the stash.

So `stash@{0}` carries nothing that still needs rescuing. `stash@{1}`–`{6}`
have not been triaged; run `stash-audit` after the branch is synced to upstream
before deciding anything about them.
