---
name: sweep-branches
description: Audit every branch in a repo: which are redundant (merged, rebase-merged, squash-merged, or a patch-identical copy of another branch), which hold commits found nowhere else, and which local branches track the wrong remote or none. Use to find or delete stale branches, or when two branches may be the same work: "which branches can I nuke", "sweep the branches", "clean up my branches", "why isn't this tracking origin". Recovering a branch whose remote was rewritten is force-push-recovery.
---

# Sweep a repo's branches

`bin/sweep-branches` does the measuring. Do not hand-roll this with
`git branch --merged`: ancestry only sees merge-commit merges, while most
branches go stale by squash-merge, rebase-merge or a cherry-pick landing
elsewhere — none of which leave ancestry behind, all of which the script
catches by comparing patch-ids.

## 1. Sweep

```sh
sweep-branches                    # dotfiles bin/; cwd, fetches --all --prune first
sweep-branches ~/src/thing        # some other repo
sweep-branches --base job         # when the interesting baseline is not the default branch
sweep-branches --local            # ignore remote-tracking branches
```

It is read-only: it prints delete commands, it never runs them. `--help` has
the rest.

## 2. Read the verdicts

It reports **branch lines**, not refs — `foo` and `origin/foo` are one line,
judged by whichever ref is furthest ahead, and the gap between them is a
tracking question instead.

- **REDUNDANT** — every commit on it exists somewhere else. The delete candidates.
- **OVERLAPPING** — partly shared with a surviving line. Usually a branch that
  wants rebasing, or one layer of a stack. Never bulk-delete from here.
- **UNIQUE** — carries work nothing else has. Keep.
- **TRACKING** — missing, gone, or lagging upstreams.
- **SKIPPED** — the base, plus anything it could not compare. A skipped branch
  is unexamined, not safe.

## 3. Verify before proposing a single deletion

The sweep is a filter, not an oracle. For each REDUNDANT line:

- **Follow the container.** "every one also on X" is only reassuring while X
  survives. If X is itself listed redundant, chase the chain to a line that is
  actually staying.
- **Twins.** For identical work the script keeps the published copy and marks
  the rest. Confirm that is the one the user is working on — it picks by
  publication, not by which one they have open.
- **An open PR means not stale**, whatever the patch-ids say:
  `gh pr list --head <branch> --state all`.
- **`gone` upstream plus unique commits** means the remote branch was deleted
  out from under work that is still only local. Read those commits before
  touching it.
- **Long-lived parallel lines** — a `job` overlay, `release/*`, `gh-pages` —
  are permanently "redundant" or permanently "unique" by construction. They are
  never delete candidates; recognize them and say so.

## 4. Propose, then delete

Relay the groups and a proposed delete list, and wait for an explicit
go-ahead — branch by branch, or "all of the redundant ones", the user's call.

Then, for local branches:

```sh
git branch -d <branch>            # where the report offers -d
git branch -D <branch>            # only where it explains why -d refuses
git branch <branch> <sha>         # undo: the sha is in the report's detail line
```

A deleted branch takes its reflog with it, so capture the report (or
`git for-each-ref --format='%(objectname) %(refname)' refs/heads`) before a
bulk delete — the objects survive until gc, but only if you kept the sha.

**Deleting a remote branch is publishing.** It needs its own explicit
confirmation for each branch, even in a repo whose policy pushes commits
without asking, because everyone else sees it and it can orphan an open PR.
Never delete a remote branch you did not create without asking first.

## 5. Tracking fixes

The `--set-upstream-to` commands in the TRACKING section are non-destructive —
apply them and mention it in the summary. Two exceptions: a branch reported as
*diverged* is not a tracking bug, it is [force-push-recovery] territory, and
re-pointing an upstream is never the fix for it.

## Limits worth stating out loud

- `--limit` (default 400) caps both the base-history corpus and per-branch
  comparison. Branches older or longer than that land in SKIPPED as
  too-divergent; raise it rather than guessing.
- Squash detection matches the branch's *cumulative* diff against one commit in
  the base, so a squash-merge that was edited on the way in (conflicts resolved,
  review fixups) will not match and the branch reads as unique.
- Patch-ids ignore commit messages and authorship. "Identical work" means an
  identical diff, which is what matters for deletion, but say so when the user
  is deciding which of two twins to keep.

[force-push-recovery]: ../force-push-recovery/SKILL.md
