---
name: pr-restack
description: Propagate an edit through a stacked-PR chain (branch-per-PR, chained bases) — push the edited branch, cascade-rebase every branch above it with one git rebase --update-refs, force-push with lease, re-request review. Use after amending or appending commits to one branch of a stack — "restack", "update the PR and rebase the stack", "propagate this fix up the stack". Restacking only — reviewing is pr-review.
---

# Restack a stacked-PR chain

A stack is branch-per-PR with chained bases; each PR renders `base..head`,
so a change to one branch strands every branch above it until they rebase.

## Procedure

1. **Capture the edited branch's old tip before changing it** —
   `OLD=$(git rev-parse <edited-branch>)`. The cascade rebase needs it, and
   after an amend it only survives in the reflog / `origin/<edited-branch>`.

2. Land the change on the branch whose PR it addresses:
   - review response → **append** a commit: reviewers keep the incremental
     view and their per-file "viewed" state;
   - pre-merge cleanup → amend/fold.

3. Push that branch: appended → plain push; amended → `--force-with-lease`.

4. Cascade in **one** rebase from the **top** branch of the stack:

   ```sh
   git checkout <top-branch>
   git rebase --update-refs --onto <new-tip> $OLD
   ```

   `--update-refs` moves every branch ref inside the rebased range —
   intermediate stack branches and any local alias branches — so there is
   no per-branch rebasing. A wrong `$OLD` silently replays too much or too
   little; verify with `git log --oneline <base>..<top>` afterwards.

5. Force-push all upper branches in one command with `--force-with-lease`.
   This does not disturb their reviews: each upper PR's `base..head` diff
   is unchanged, so GitHub shows reviewers nothing new.

6. A plain push does not re-request reviewers who already reviewed:

   ```sh
   gh api -X POST repos/<owner>/<repo>/pulls/<n>/requested_reviewers \
     -f 'reviewers[]=<login>'
   ```

## Merge flow

Merge bottom-up. When the bottom PR merges and its head branch is deleted,
GitHub retargets the next PR onto the base branch automatically; then
restack the remainder onto the merge result (with squash merges, pass the
merged branch's old tip as `$OLD` so its commits drop out).

## Gotcha: deploying from a stack

A lower stack branch is an incomplete system — later commits may add
access or safety config. Deploying one to a live target can lock you out
(e.g. an image whose access policy arrives two PRs up). Test lower-branch
changes by cherry-picking them onto the stack tip and deploying that.
