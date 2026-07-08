---
name: force-push-recovery
description: Recover local branches after a remote branch was force-pushed or rebased (history rewritten elsewhere). Use when a branch shows "have diverged" from its upstream, when a pull would duplicate commits, or after an intentional rebase/force-push on another machine. Classifies local commits as re-hashed upstream vs genuinely local-only, preserves unpushed work, then resets cleanly.
---

# Recover from an upstream force-push / rebase

The remote history was rewritten and is authoritative; the local branch is a
stale pre-rewrite copy. Do NOT pull/merge — that creates duplicate-commit
merge soup. Follow this procedure instead.

## 1. Fetch and measure the divergence

```sh
git fetch --all --prune
git rev-list --left-right --count <branch>...<remote>/<branch>
```

Ahead AND behind → diverged. Ahead-only or behind-only is not a force-push
situation (plain push or fast-forward applies; stop here).

## 2. Classify the local-only commits — the critical step

```sh
git cherry -v <remote>/<branch> <branch>
```

- `-` an equivalent patch EXISTS upstream (same change, re-hashed by the
  rebase) — safe to drop.
- `+` NOT upstream by patch-id — investigate each one before anything else.

Commit titles lie (reworded/reworked commits keep their titles); patch-id
equivalence is the only reliable test. For each `+` commit decide
"superseded" vs "unique":

```sh
git show <sha>                                     # what it does
git log --oneline <remote>/<branch> -- <files>     # did upstream rework the same area?
git diff <remote>/<branch> <branch> -- <files>     # net content difference
```

Superseded = upstream contains a different implementation of the same intent
(often a strict superset). Unique = work that exists nowhere upstream.

Report the classification to the user before mutating anything.

## 3a. Nothing unique → reset onto the rewritten remote

```sh
git checkout <branch>
git reset --hard <remote>/<branch>
```

## 3b. Unique commits → replay them on the new tip

```sh
git rebase --onto <remote>/<branch> <old-upstream-base> <branch>
# or cherry-pick just the unique + commits onto <remote>/<branch>
```

## 4. Verify

```sh
git rev-list --left-right --count <branch>...<remote>/<branch>   # 0 0 (case 3a)
git status                                                       # clean tree
```

For 3b, additionally confirm the tree difference vs the remote is exactly the
preserved work: `git diff <remote>/<branch> <branch>`.

## Cautions

- Repeat for EVERY local branch tracking a rewritten remote (e.g. both a main
  and a feature/overlay branch).
- If local work must later be pushed over rewritten history, use
  `git push --force-with-lease`, never bare `--force`.
- `git cherry` cannot see "superseded" (same intent, different patch) — that
  is why step 2 also diffs the touched files instead of trusting `+` alone.
- Uncommitted changes: stash before switching/resetting branches
  (`git stash push`), pop after.
