---
name: pr-comment-sweep
description: Work a PR's open review threads — decode what the other side is really asking, prototype the proposals locally to find out whether they actually work, then draft or fix the replies as pending comments. Use for "sweep the comments on PR 61", "/pr-comment-sweep 61", "double-check my draft replies". Drafts only — submitting is pr-publish.
---

# Sweep a PR's review threads

Serves whichever side of the PR the user is on. The threads that need work are
the ones where **the last word is not the user's** — reviewers waiting on the
author, or an author's replies waiting on the reviewer who raised them. Plus
any reply the user has already drafted and wants checked.

Everything this skill writes goes into the PR's pending review, so it is
invisible to everyone else until `/pr-publish` submits it — see
`../pr-references/pending-review.md`. That is what makes it safe to draft
replies outright instead of handing back text to paste.

Two deliverables, split by whether a draft reply already exists.

1. **Threads with a pending draft reply** → audit it. The user is asking
   "double-check me", not "praise me": verify every factual claim against the
   actual code, and where one is wrong or misleading, fix it in place and show
   what changed. Where a draft is correct but misses the strongest argument —
   often one already written down in the code — supply it.
2. **Threads where the other side spoke last** → for each: explain what the
   comment is really asking, decoding intent rather than paraphrasing words;
   then **actually try the proposal** and draft a reply reporting *verified
   works* or *verified fails* with the evidence. Never settle a "would this
   work?" from theory when a two-minute experiment answers it.

## 1. Collect

```sh
pr-threads <n>        # unresolved threads, with outdated / file-changed flags
pr-draft show <n>     # the pending review: every drafted reply, with ids
```

`pr-threads` cannot see pending comments — the API returns those only to their
author — which is why the drafted half comes from `pr-draft show`. The flags
from `pr-threads` matter for the other half: they say whether the code moved
under a thread since the comment was written, which often *is* the answer.

Partition the unresolved threads into has-a-pending-reply vs other-side-last.
Pure praise ("nice", ":)") needs no work, but list it as no-action so the
counts reconcile and the user can see nothing was skipped.

## 2. Audit the drafted replies

Read the code each thread anchors to — at the PR head, not the default branch,
or the line numbers point at the wrong thing. Classify each draft:

- **correct** — the claims check out; leave it alone;
- **correct but weak** — misses the strongest argument. The common case: the
  real rationale is already in a doc comment near the anchor. Quote it back;
- **wrong** — a claim contradicts the code or reality. Rewrite it:
  `pr-draft edit <comment-id>`;
- **question back to the other side** — legitimate, but if their intent is
  decodable, offer an interpretation so the thread stops ping-ponging.

These are the user's own words, so anything you rewrite gets reported as a
before/after. The gate is submission, not each edit — but they still have to be
able to see what moved without diffing it themselves.

## 3. Prototype the unanswered proposals

Experiments go in a scratch worktree, never the main tree. Put it under a
`claude-review` path so an abandoned one gets reaped by `pr-prep` later:

```sh
git worktree add "$(git rev-parse --git-common-dir)/claude-review/pr-<n>" <head-sha>
git worktree remove --force <that-path>    # --force: trials leave it dirty
```

Revert between trials with `git checkout -- .` so experiments don't compound.

- "Could we do X instead?" → implement X, run the narrowest test set that
  would catch breakage, widen to dependents if it passes.
- "Is Y needed?" → remove Y, build and test.
- API-shape proposals that cross into a third-party library → read that
  library's real source first (for Rust, the registry sources under
  `~/.cargo/registry/src/`). Type-system objections like a missing impl or an
  orphan-rule violation are provable with a tiny throwaway crate even when the
  real target can't build on this machine.
- Record evidence verbatim — test totals, exact error codes (`E0277`, `E0117`).
  "Verified" means a command ran and you read its output.
- Watch for asymmetric verifiability: when half the change lives in
  target-only code this box can't compile, say which half you proved and which
  half CI has to confirm. Silently proving the easy half is the failure mode.

Then draft the reply into the thread:

```sh
pr-draft reply <n> <thread-id> <<'MSG'
Tried it — `Vec<u8>` there hits the orphan rule (E0117), because …
MSG
```

## 4. Report

One section per thread, grouped **Drafted** then **Unanswered**:

```
[T<n>] <path>:<line> — <one-line gist of the other side's point>
  verdict: correct | correct-but-weak | rewritten | no-action | works | fails
  <what it means / what the experiment showed / what you changed and why>
```

Close with an action list: fixes worth folding into the PR now and which commit
owns each, threads that look resolvable (for `/pr-publish` to actually
resolve), and anything that changes another PR in the stack.

## Hard rules

- Draft only. Never submit the review, and never resolve a thread even when the
  answer is obvious — resolving is immediately public, so it lives behind
  `/pr-publish`'s gate.
- A real defect found mid-sweep — a reviewer nit that turns out to be a live CI
  failure — leads the report, before the per-thread detail.
- The main working tree stays untouched; experiments live and die in the
  scratch worktree.
