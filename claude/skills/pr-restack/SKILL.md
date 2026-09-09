---
name: pr-restack
description: Propagate an edit through a stacked-PR chain (branch-per-PR, chained bases) — push the edited branch, cascade-rebase every branch above it with one git rebase --update-refs, force-push with lease, re-request review. Use after amending or appending commits to one branch of a stack — "restack", "update the PR and rebase the stack", "propagate this fix up the stack". Restacking only — reviewing is pr-review.
---

# Restack a stacked-PR chain

A stack is branch-per-PR with chained bases; each PR renders `base..head`,
so a change to one branch strands every branch above it until they rebase.

This skill moves code and never touches review comments: findings are
`/pr-review`, thread work `/pr-comment-sweep`, publishing `/pr-publish`. The
layer each sits in is in `../pr-references/pending-review.md`.

## Procedure

1. **Capture old tips before changing anything** — the edited branch's, and
   every branch above it:

   ```sh
   OLD=$(git rev-parse <edited-branch>)
   for b in <upper-branches>; do echo "$b $(git rev-parse "$b")"; done
   ```

   The cascade rebase needs `$OLD`, and after an amend it only survives in the
   reflog / `origin/<edited-branch>`. The upper tips are what the force-push
   leases get pinned to in step 5 — capture them now or that safety is gone.

2. Land the change on the branch whose PR it addresses:
   - review response → **append** a commit: reviewers keep the incremental
     view and their per-file "viewed" state;
   - pre-merge cleanup → amend/fold.

3. Push that branch — appended → plain push; amended → lease pinned to the
   sha from step 1:

   ```sh
   git push --force-with-lease=<edited-branch>:$OLD origin <edited-branch>
   ```

4. Cascade in **one** rebase from the **top** branch of the stack:

   ```sh
   git checkout <top-branch>
   git rebase --update-refs --onto <new-tip> $OLD
   ```

   `--update-refs` moves every branch ref inside the rebased range —
   intermediate stack branches and any local alias branches — so there is
   no per-branch rebasing. A wrong `$OLD` silently replays too much or too
   little; verify with `git log --oneline <base>..<top>` afterwards.

5. Force-push every upper branch in one command, each lease pinned to that
   branch's captured tip:

   ```sh
   git push origin \
     --force-with-lease=<b2>:<old-b2> --force-with-lease=<b3>:<old-b3> \
     <b2> <b3>
   ```

   A valueless `--force-with-lease` leases against the remote-tracking ref,
   which every `git fetch` in this procedure has just refreshed — so it would
   happily overwrite a colleague's push while reporting itself as safe. Pin it.

   This does not disturb their reviews: each upper PR's `base..head` diff
   is unchanged, so GitHub shows reviewers nothing new.

6. A plain push does not re-request reviewers who already reviewed:

   ```sh
   gh pr view <n> --json reviews --jq '[.reviews[].author.login]|unique'
   gh api -X POST repos/<owner>/<repo>/pulls/<n>/requested_reviewers \
     -f 'reviewers[]=<login>'
   ```

## Merge flow

Merge bottom-up. When the bottom PR merges and its head branch is deleted,
GitHub retargets the next PR onto the base branch automatically; then
restack the remainder onto the merge result (with squash merges, pass the
merged branch's old tip as `$OLD` so its commits drop out).

## Hard rules

- Every step here publishes, and two rewrite remote history. Confirm each push
  with the user before running it. The dotfiles repo's push-freely policy is
  about that repo; it does not reach PR repos.
- `--force-with-lease` with the lease pinned to a captured sha, never a bare
  `--force`.
- Push the whole cascade or none of it. An edited lower branch pushed while the
  branches above it sit unrebased leaves every upper PR showing a diff nobody
  wrote — worse than not having started.

## Gotcha: deploying from a stack

A lower stack branch is an incomplete system — later commits may add
access or safety config. Deploying one to a live target can lock you out
(e.g. an image whose access policy arrives two PRs up). Test lower-branch
changes by cherry-picking them onto the stack tip and deploying that.
