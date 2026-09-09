---
name: pr-checkout
description: Check out a GitHub PR into the local clone and brief the user on where it stands. Use when the user gives a PR number or URL and wants the agent set up on it ("checkout PR 61", "/pr-checkout 61", "get me set up on PR 57"). Orientation only — never writes to GitHub, never reviews the code; the review pass is pr-review.
---

# Check out a PR and get oriented

Put the local clone on the PR head, build situational awareness — what the
change does, where it stands — then brief the user and **stand by**. This
skill produces context, not opinions: no review pass, no edits, no
unsolicited findings.

The invocation may carry extra context after the PR ref ("focus on the driver
changes") — honor it.

## 1. Check out

```sh
pr-prep <n>                   # dotfiles bin/
```

`pr-prep` owns the preflight, so don't re-implement it: it refuses if the PR
doesn't resolve in this repo (the wrong-repo tripwire), if the branch has
unpushed commits, or if anything in the dirty tree isn't recognizable review
residue — and otherwise clears the residue and checks the head out.

**If it refuses, relay the reason and stop.** It found something that looks
like real work, and the refusal is the whole point of running it. `--dry-run`
shows the partition without touching anything; `--force` clears unrecognized
dirt and is the user's call to make, not yours.

## 2. Gather context (read-only)

```sh
gh pr view <n> --json title,body,author,baseRefName,headRefName,state,commits
gh pr checks <n>              # CI covers targets that don't build locally
gh pr diff <n>
pr-threads <n>                # unresolved threads + outdated/file-changed flags
pr-draft show <n>             # anything already drafted here, by you or them
```

Read the base from `gh pr view`: on a stacked PR the change's own scope is
`<baseRefName>...HEAD`, and diffing against the repo's default branch instead
silently pulls in the whole PR underneath.

## 3. Orient

Read the description and the full diff, then skim enough of the surrounding
code to say what the change actually does — not just which files moved.

```sh
git rev-parse --verify --quiet refs/claude-review/pr-<n>
```

If that ref exists, a prior review pass happened: say so, and report what
`pr-diff <n> last -- --stat` shows as the delta since. Re-verifying the old
findings is pr-review's job, not this skill's.

## 4. Brief and stand by

A compact brief, then stop and await instructions:

- what the PR does and why — its claim, in your own words;
- shape of the diff (files, subsystems, anything stacked);
- CI state and open threads;
- **an unsubmitted pending review, if `pr-draft show` found one** — how many
  comments and when they were drafted. Nobody else can see them, so an
  unnoticed draft is how a review gets done twice or never sent;
- anything odd noticed in passing, flagged as observation, not finding;
- prior-review state if any (baseline, delta since).

Point sideways where relevant: a structured review is `/pr-review`, thread work
is `/pr-comment-sweep`, submitting a draft is `/pr-publish`.

## Hard rules

- Never commit, never push, never write anything to GitHub — not even a
  pending comment. Drafting findings is `/pr-review`.
- Never start reviewing or editing unprompted — brief, then stand by.
- Never work around a `pr-prep` refusal by cleaning the tree yourself.
