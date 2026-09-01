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

To materialise a group's tree when rewriting an existing history, check out the
old commit that ended that group — `git checkout <old-sha> -- .` after clearing
the worktree — which folds every intermediate commit in that group for free.

Two traps:

- `git checkout -B` fails if the worktree is dirty, and a failed branch switch
  leaves you committing onto the *current* branch. Verify with
  `git rev-parse --abbrev-ref HEAD` after switching, before committing.
- Rewriting a branch that others rebase onto reparents them; rebase those after.

`check-rewrite` catches *phrasing* — it greps for narration and unpinned links.
It cannot tell churn from deliberate granularity, because that depends on what
counts as one decision in this repo. Grouping stays a judgement call; the script
only stops the wording slipping through.

## Before publishing

- `scripts/check-rewrite verify` clean — the tree matches, minus changes you
  intended.
- No message narrates the work. Read each one as a stranger.
- Every commit builds and is a decision someone could act on alone.
- A backup ref still exists until the user has looked at the result.
