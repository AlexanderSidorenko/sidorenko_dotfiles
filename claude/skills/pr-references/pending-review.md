# The draft surface, and who may write what

## The invariant

Every comment this family produces — a reviewer's finding or an author's reply
— is written into the PR's GitHub **pending review**, where it is invisible to
everyone else and freely editable, and it leaves draft only on an explicit
go-ahead.

Safety comes from draft-ness, not from withholding writes. That is why the
drafting skills may write freely and without asking: a pending comment costs
nothing to fix or delete, so there is no reason to make the user paste text by
hand. It is also why exactly two acts are gated — they are the only two that
become visible to other people.

## The four layers

| Layer | Skills | May write |
|---|---|---|
| Read | pr-statuses | nothing, anywhere |
| Setup | pr-checkout | the local clone only — never GitHub |
| Draft | pr-review, pr-comment-sweep | the pending review only — never submit, never resolve |
| Gate | pr-publish | submit and resolve, on an explicit go-ahead |
| Code | pr-restack | commits and branches; each push confirmed |

A skill that finds itself wanting to submit or resolve is in the wrong layer:
hand off to pr-publish instead.

## How pending reviews actually behave

- **One per user per PR.** A second `addPullRequestReview` is rejected, so
  every write reuses the existing pending review. `pr-draft` does this for you;
  it creates one on first write and reuses it after.
- **Visible only to the authenticated user.** Pending comments do not appear to
  anyone else, and the API returns them only to their author — which is why any
  tool inspecting them has to run as the user, and why `pr-threads` cannot see
  them.
- **Editable until submitted.** Any pending comment can be rewritten
  (`pr-draft edit`) or deleted (`pr-draft drop`), including one the user wrote
  in the GitHub UI. Curating in the browser and curating through `pr-draft` are
  the same operation on the same object, so the two mix freely.
- **The review has a body** as well as comments (`pr-draft body`) — that is
  where findings with no code anchor belong.
- **Submitting is one-way.** There is no unsubmit; a submitted review can only
  be superseded. Approving or requesting changes on your own PR is rejected by
  GitHub, so an author submitting drafted replies uses `COMMENT`.
- **Resolving is not draftable.** `resolveReviewThread` takes effect the moment
  it runs, so it belongs behind the same gate as submission — never bundled
  into drafting work.

## Anchoring

A line comment must land on a line the PR's diff touches, on the side you name
(`RIGHT` = post-image, the usual choice; `LEFT` = pre-image). A finding about
untouched code has two homes: anchored to the whole file
(`pr-draft comment … --file`), or written into the review body with a permalink
`https://github.com/<owner>/<repo>/blob/<headRefOid>/<path>#L<line>`.

Because each comment is added by its own call, a bad anchor costs exactly that
one comment — it no longer takes the whole review down with it. Retry it as a
`--file` comment and move on.

## The review baseline

`refs/claude-review/pr-<n>` records the commit a review pass was done at.
`pr-diff` reads it as the `last` keyword and falls back to it when the user has
no submitted GitHub review on the PR. It is local-only, cheap, and idempotent
to re-set.
