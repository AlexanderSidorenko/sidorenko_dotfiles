---
name: pr-publish
description: Submit a PR's pending review — the one gate where drafted findings and replies stop being private and become visible to everyone — and resolve the threads that were actually addressed. Use after curating what /pr-review or /pr-comment-sweep drafted ("publish the review", "/pr-publish", "submit my comments", "resolve those threads"). Nothing is submitted or resolved without an explicit go-ahead.
---

# Publish a pending review

The only skill in the family that makes anything public. Everything upstream
of it drafts into the PR's pending review, where only the user can see it; this
skill turns that into a submitted review and, separately, resolves the threads
the work addressed. Both acts are irreversible in practice — a submitted review
can only be superseded, and a resolve is visible the instant it lands — which
is why neither happens without the user saying so in this turn.

Serves both roles: a reviewer submitting findings, or an author submitting
replies. The mechanics are the same; only the verdict differs.

## 1. Show the user exactly what will go out

```sh
pr-draft show <n>
```

Read the whole thing back — review body, every pending comment with its
`path:line`, every pending reply — and present it as the summary. The user may
have drafted or edited some of it in the browser since you last looked, so
**the API's copy is authoritative, never your memory of what you wrote.**

Flag anything that looks unfinished before asking for a verdict: a comment that
is a placeholder, a reply that contradicts one further up, a finding the latest
push has already fixed. Offer `pr-draft edit` / `pr-draft drop` and let them
decide. It costs nothing now and cannot be taken back afterwards.

## 2. Ask for the verdict

Never infer it — not from the severity mix, not from the user's enthusiasm.
Ask with AskUserQuestion:

- **Comment** — findings without a merge judgment. The only valid choice when
  the user is the PR's author, because GitHub rejects approving or requesting
  changes on your own PR.
- **Request changes** — something must change before merge.
- **Approve** — good to merge. Never select this on the user's behalf.

## 3. Submit

```sh
pr-draft submit <n> --event COMMENT --yes      # or REQUEST_CHANGES / APPROVE
```

Without `--yes` it prints what it would do and exits, which makes it a safe
thing to run first if you want the count confirmed. Print the resulting URL.

If it fails, the review is still pending and nothing is public — say so
explicitly, re-read with `pr-draft show <n>`, and fix the cause rather than
retrying blind.

## 4. Resolve the threads that were addressed

Separate act, separate go-ahead. Resolving is not draftable, so there is no
undo-by-editing.

```sh
pr-draft resolve <thread-id> --reason ADDRESSED --yes
```

Only resolve a thread the user confirms is settled, and prefer to let the
person who *raised* a thread be the one to close it — resolving someone else's
open question reads as ending the conversation, whatever the reason code says.
`WONT_FIX` and `INVALID` are the honest reasons when that is the outcome; using
`ADDRESSED` for a thread nobody addressed is the failure mode here.

## 5. Clean up

Offer, don't do: nothing local needs removing any more, but if
`refs/claude-review/pr-<n>` is stale relative to a head that has since moved,
say so — `/pr-review` will re-baseline it on the next pass. Leave the ref
alone otherwise; it is the next iteration's starting point.

## Hard rules

- No submit and no resolve without an explicit go-ahead in this turn. Approval
  of the draft is not approval to publish it.
- Never choose the verdict, and never approve on the user's behalf.
- The user's wording is final. Fix a factual error by telling them, or by
  editing only what they asked you to edit — do not tidy their prose on the way
  out the door.
- Report the true end state on any failure: what was submitted, what is still
  pending, what was resolved. A blind retry is how a PR ends up with two
  reviews.
