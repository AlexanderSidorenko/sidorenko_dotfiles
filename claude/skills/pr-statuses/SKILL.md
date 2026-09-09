---
name: pr-statuses
description: Standup of where the user's PRs stand — authored, awaiting their review, and any review they drafted but never submitted. Use when the user asks "where do my PRs stand", "PR status", "/pr-statuses", "anything waiting on me". Read-only; answers whose move it is on each PR and which skill to run next, not what the code says — that is pr-review.
---

# PR standup: authored and reviewing

Produce a decision-ready summary, not a data dump. For every PR the question
is **whose move is it** — answer that explicitly, even when the answer is
"nobody's, it's just waiting on CI". This is the family's entry point, so every
row ends by naming the skill that acts on it.

Default scope is every open PR the user is involved in, across repos. Narrow to
the current repo on request by adding `repo:<owner>/<name>` to the search.

## 1. Collect — one query

```sh
ME=$(gh api user -q .login)
gh api graphql -f q="type:pr state:open involves:$ME" -f query='query($q:String!){
  search(query:$q, type:ISSUE, first:50){
    issueCount
    nodes{ ... on PullRequest {
      number title url isDraft updatedAt baseRefName headRefOid
      repository{ nameWithOwner } author{ login }
      reviewDecision
      drafted: reviews(states:[PENDING], last:1){ nodes{ url updatedAt comments{ totalCount } } }
      recent:  reviews(last:20){ nodes{ author{login} state submittedAt } }
      reviewRequests(first:20){ nodes{ requestedReviewer{ ... on User { login } } } }
      reviewThreads(first:100){ nodes{ isResolved isOutdated path
        comments(last:1){ nodes{ author{login} createdAt } } } }
      commits(last:1){ nodes{ commit{ committedDate statusCheckRollup{ state } } } }
    } } } }'
```

One round trip for both sets and every field: `involves:` already includes the
user's own PRs, so partition on `author.login == $ME` rather than searching
twice. The two `reviews` selections must be aliased as above — GraphQL rejects
the same field twice with different arguments. If `issueCount` exceeds what you
fetched, say so rather than silently reporting a subset.

Stay in GitHub — don't go hunting for context in Slack or DMs.

## 2. Analyze

- **CI** — pass, fail or pending, from the rollup.
- **Your unsubmitted draft** — a non-empty `reviews(states:[PENDING])` means
  the user drafted comments and never submitted them. Nobody else can see
  them, so a forgotten draft looks to everyone else like the user simply never
  reviewed. **Lead with these**: report the comment count and how long it has
  sat, and route to `/pr-publish`.
- **Ball-in-court**, the headline verdict, exactly one per PR:
  - `WAITING ON YOU` — a review is requested and you have none on the current
    head; or someone else spoke last in a thread that asks you something; or
    the author pushed fixes after your changes-requested; or your approval was
    dismissed by a force-push.
  - `WAITING ON <login>` — your threads unanswered, changes-requested
    outstanding, or CI red on their PR.
  - `READY TO MERGE` — approved, CI green, no unresolved threads. Check the
    repo's required-conversation-resolution setting: where it's on, unresolved
    threads block the merge no matter what the approval says.
  - `DRAFT`, or `BLOCKED ON <base PR>` when the base branch is another PR's
    head.
- **Threads** — unresolved count split by who spoke last: "you owe N" vs "they
  owe M". Name the oldest thing waiting on the user, with its age.
- **Review-iteration awareness** — if `refs/claude-review/pr-<n>` exists
  locally and differs from `headRefOid`, note "reviewed at <short>, head moved;
  `/pr-review <n>` will diff the delta". If the user's own latest submitted
  review predates the last commit, flag that the head moved since they looked.
- **Dismissed approvals** — a review of theirs in state `DISMISSED` means a
  force-push ate the approval and it needs re-giving.

## 3. Report

Two sections, **Authored** and **Reviewing**, each a compact table:

| PR | title (short) | CI | decision | threads (you owe / they owe) | draft | verdict | next |

`draft` is the unsubmitted comment count, blank when there is none. `next` is
the skill to run: `/pr-publish` for an unsubmitted draft, `/pr-review` for a
review owed or a moved head, `/pr-comment-sweep` for threads owed,
`/pr-restack` for a stack needing propagation, nothing at all when the ball is
elsewhere.

Then one prioritized action list: unsubmitted drafts first, then everything
`WAITING ON YOU` oldest-debt-first, each with a one-line what-to-do; then items
worth chasing on others; then what's ready to merge. A PR with nothing
actionable gets its table row and no prose.

Close with what changed since the user last looked, where that's detectable —
new commits, new threads, decision flips — rather than restating static facts.

## Hard rules

- Strictly read-only: no comments, no drafts, no resolves, no re-requested
  reviews, nothing written to GitHub or the working tree. Reporting a
  forgotten draft is not permission to submit it.
- When signals conflict, say so instead of picking a verdict — "approved but 4
  unresolved threads, merge-blocked by the conversation rule" is the useful
  answer.
