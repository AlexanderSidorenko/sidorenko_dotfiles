---
name: curate-commits
description: Write commit messages and shape commit history so both read as decisions rather than as a diary of arriving at them. Use when writing any commit message, and when asked to clean up, audit, fold, squash or rewrite history — "commit this", "audit the commit history", "clean up these commits", "I hate tiny follow-up commits", "fold these together". Covers message wording, code-comment wording and commit grouping; push and branch policy live elsewhere.
---

# Curate commits

Two rules. Both exist because the log is read years later by someone
reconstructing a decision, not by someone watching you work.

## 1. State the decision, not the journey

A message says what the change does and why that is right. It does not narrate
how it came to be, because `git log` already is the history — re-telling it in
prose costs a reader twice and ages badly the moment the neighbouring commits
are reordered.

```
BAD   Fixing the thing I got wrong in the last commit.
BAD   An earlier version filtered by comment and missed the paired command.
BAD   Turned out the resolver was backwards, so now it resolves forwards.
GOOD  Resolve multi-parent inherits so later parents win.
      The order matters and the failure is silent: CORE One profiles inherit
      from the MK4 line and then override it, so first-parent-wins yields a
      preset that looks plausible while carrying MK4 speeds.
```

The same rule governs code comments and docs. A comment about a past mistake
decays into noise; a comment stating the invariant keeps working:

```
BAD   # 5mm was not enough and the toolhead dragged the blobs off the bed
GOOD  # Blobs droop and lean well outside their nominal height, so this has to
      # be generous - a few mm and the toolhead drags them off the bed.
```

The line is whether the fact belongs to the *system* or to *your process*.
"`M109 R` waits in both directions, so a bare `R` at MBL temperature stalls the
print" is a property of the firmware and belongs in the message. "I left an
`M109` behind when I split the block" is a property of an afternoon and does
not.

Describing a rejected alternative is not narration — "Klicky works but adds a
dock, a cowl change and wiring" is a decision record and belongs.

## 2. Publish logical commits, not the path taken

One commit is one complete decision, working on its own. Before publishing,
fold everything that is an artefact of iterating:

- **fixups** — "fix typo", "actually make it work", "address review"
- **undo pairs** — move a file then move it back; add a thing then delete it.
  Both commits vanish and the file simply lands where it belongs.
- **rebuild churn** — regenerating the same artefact four times as inputs
  settle. Only the last state ever existed as far as the reader is concerned.
- **trailing doc updates** — "update the table now that X landed" belongs
  inside X.
- **late corrections to earlier commits** — a commit that pins links an earlier
  commit left unpinned should disappear into that earlier commit.

Re-authoring commits wholesale is fine and often the right move. What must hold
is the final tree, not the route.

Respect a repo's own granularity rule when it has one — a repo whose
conventions say "one mod, one commit" wants many small *decision* commits, and
that is not churn.

## Doing the rewrite

`git rebase -i` is unavailable in agent shells and `git commit --fixup` still
leaves you needing it. Rebuild the branch instead, and author every commit the
normal way — checked out, `git commit` — so hooks run and the working tree
matches what is committed. Never `git commit-tree` / `git update-ref`.

```sh
scripts/check-rewrite backup <branch>      # snapshot first, always
git checkout -B rewrite <base>
# per logical commit: materialise that group's tree, then
git add -A && git commit -F <message-file>
git branch -M rewrite <branch>
scripts/check-rewrite verify backup/pre-rewrite-<branch> <branch>
```

Materialising a group's tree has two cases. When the new commits are a
contiguous partition of the old ones, check out the old commit that ended each
group — `git checkout <old-sha> -- .` after clearing the worktree — which folds
every intermediate commit for free.

When they are not — because folding an undo pair means a file has to land under
its *final* name in the commit that first adds it, not under the name it
originally had — no old commit has the tree you want. Build a path-to-commit
assignment instead, sourcing content from the final tree:

```sh
# for each commit k, in order:
#   remove the paths that commit deletes, check out the paths it introduces
git rm -q -f -- <paths deleted by k>
git checkout <final-branch> -- <paths introduced by k>
git add -A && git commit -F <message-file>
```

Verify the assignment is *total before touching git*: every path in the final
tree assigned to exactly one commit, and every path that exists upstream but not
in the final tree explained by a commit that removes it. An unassigned path is a
file that silently vanishes.

A logical commit with no file change — a decision recorded in prose and nothing
else — will fail, because `git commit` refuses an empty tree change. Do not
reach for `--allow-empty`: it means the decision has no home in the repo. Give it
one by splitting the document that records it across the commits, so each
decision commit carries the section that states it.

Conform to the repo's own commit conventions rather than to the history you are
replacing. If `CLAUDE.md` says summaries are present-participle and half the old
commits are imperative, the rewrite is when that drift gets fixed — you are
re-authoring every message anyway.

Three traps:

- `git checkout -B` fails if the worktree is dirty, and a failed branch switch
  leaves you committing onto the *current* branch. Verify with
  `git rev-parse --abbrev-ref HEAD` after switching, before committing.
- A rewrite takes minutes and the worktree is not frozen while it runs. If a
  file goes dirty mid-rewrite, read the change before doing anything with it —
  the user may have edited it in another window, and stashing or discarding
  their work to unblock yourself is the worst available outcome. Fold it into
  the commit it belongs to instead.
- Rewriting a branch that others rebase onto reparents them; rebase those after.

`check-rewrite` catches *phrasing* — it greps for narration and unpinned links.
It cannot tell churn from deliberate granularity, because that depends on what
counts as one decision in this repo. Grouping stays a judgement call; the script
only stops the wording slipping through.

## Before publishing

- `scripts/check-rewrite verify` clean — the tree matches, minus changes you
  intended. Add `--links` when messages carry permalinks: a pinned URL that
  404s is worse than an unpinned one, because it looks checked.
- No message narrates the work. Read each one as a stranger.
- Every commit builds and is a decision someone could act on alone.
- A backup ref still exists until the user has looked at the result.
