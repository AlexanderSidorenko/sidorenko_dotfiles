---
name: pr-review
description: Deep local review of a GitHub PR that drafts every finding as a pending review comment — invisible to everyone else until it is submitted. Use when the user asks to review a PR by number or URL ("review PR 61", "/pr-review 61", "do a pass over PR 57"). Iteration-aware — a re-review diffs against the last-reviewed head. Drafts only — submitting is pr-publish.
---

# Deep local PR review

Read the code locally, and leave each finding as a **pending comment on the
PR** — GitHub's own draft surface, visible only to the user until they submit.
They curate it (in the browser, or by telling you to edit it) and then run
`/pr-publish`.

Drafting is therefore cheap: a bad finding costs a `pr-draft drop`, not a
retracted public comment. Write findings freely and let curation do its job.
The contract this shares with the other pr-* skills is in
`../pr-references/pending-review.md`.

## 0. Set up

```sh
pr-prep <n>                   # dotfiles bin/: refuses on real work, else cleans and checks out
pr-draft show <n>             # anything already drafted here?
```

If `pr-prep` refuses, relay why and stop — it found something that isn't
review residue. Skip both if this session already ran `/pr-checkout` for this
PR.

Two things carry over from that context:

- The PR diff is the **only** scope — `<baseRefName>...HEAD`, which on a
  stacked PR is not the default branch. Findings outside it are
  `[pre-existing]` at most, and only when the PR exercises them.
- Other reviewers' open threads are already-said. Don't re-raise a point a
  human or bot already made — reference it ("already flagged by X in
  <thread>") — and on a re-review, check whether those points were addressed.

## 1. Re-review detection

```sh
git rev-parse --verify --quiet refs/claude-review/pr-<n>
```

If the ref exists, or the user already has a submitted GitHub review on the
PR, this is an **iteration**. Read the delta before anything else:

```sh
pr-diff <n>                   # list every pushed iteration
pr-diff <n> last -- --stat    # shape of the delta since your baseline
pr-diff <n> last              # the delta itself
```

Focus effort there, but re-verify every previously flagged item: fixed,
regressed, or unaddressed?

`pr-diff` is rebase-aware: when the two iterations sit on different bases it
replays the older one onto the newer one's base first, so base-branch churn is
already excluded and what you see is the author's own edits. It says so on
stderr when it does that. Reach for `--literal` (raw tree diff) or
`--range-diff` (commit-level, also shows message edits and dropped commits)
when you want the other views.

## 2. Pass 1 — bugs and soundness

Read every hunk **plus its surrounding context** (whole functions and files,
not just the diff lines). For each changed function, trace callers and callees
across the repo with `grep`, not just within the diff. Check:

- error paths (Err/None/timeout/overflow), unit semantics, integer widths and
  casts, ordering and concurrency, resource lifetimes;
- claims against ground truth rather than memory — dependency behavior from
  the actual vendored sources (`cargo fetch`, then read
  `~/.cargo/registry/src/…`; the equivalent for whatever the stack is),
  hardware behavior from the datasheet, protocol conformance from the spec.
  Anything verifiable in ten minutes gets verified, not asserted;
- whatever runs locally: host tests, and a formatter in check mode as a cheap
  parse test. Use CI results for targets that can't build on this machine.

## 3. Pass 2 — consistency

- Comments and docs vs code: does every doc comment still tell the truth after
  this change?
- **Caller/callee semantic drift where the types still match.** If a
  parameter's *meaning* changed (nanoseconds → seconds, both `u64`), grep every
  call site and confirm each was updated semantically, not just type-checked.
  Neither the compiler nor CI can see this class, which makes it the
  highest-value check in the pass.
- Naming vs behavior: a variable named `now_ns` feeding a `now_secs` parameter
  is a finding even when the value happens to be right.
- Intra-PR contradictions: a constant vs its own doc comment, a config value
  vs the comment justifying it — check the justification's logic, not just its
  presence.
- On a stack: changes living in the wrong layer's commits, e.g. library edits
  folded into a task-wiring commit.

## 4. Pass 3 — meta consistency

- PR **title and body vs the actual diff**. Heavy iteration drifts these:
  features described but since removed, refactors added but unmentioned,
  explanations of the fix that are no longer true.
- Commit messages vs their commits' content.
- Description templates left unfilled with the checkboxes ticked anyway.
- Whether iteration changes arrived as separate reviewable commits or were
  folded into rebased ones — worth noting either way.

## 5. Findings → pending comments

One `pr-draft` call per finding. Lead with the finding as a statement, then the
evidence, then a concrete suggestion:

```sh
pr-draft comment <n> <path> <line> <<'MSG'
issue: `deadline_ns` is passed the value of `now_secs`, so the timeout fires
~10^9 times too early. Both are u64, so this type-checks.
Suggestion: multiply at the call site in scheduler.rs:88, or take a Duration.
MSG
```

Publish the **conventional-comment prefix**, never the bracket severity —
`issue:`, `suggestion:`, `nit:`, `question:`, `comment:`, `praise:`. The
mapping and the vocabulary are in `../pr-references/severities.md`; keep the
severities for your own counts in the report.

- A line the diff doesn't touch can't take a line comment. Anchor to the file
  instead — `pr-draft comment <n> <path> --file` — or put it in the body with a
  permalink. Each comment is its own call, so a bad anchor costs that one
  comment and nothing else.
- Findings with no code anchor at all — title/body problems, commit-message
  issues, lockfile-only changes — go in the review body:

  ```sh
  pr-draft body <n> <<'MSG'
  Two things above the code: …
  MSG
  ```

- On an iteration, `pr-draft` adds to the pending review that already exists.
  Read it first (`pr-draft show <n>`) and `pr-draft edit` or `drop` findings
  this iteration fixed — a stale finding sitting next to a fresh one is worse
  than either alone.

The working tree stays clean throughout. Findings live on the PR now, so never
edit source files to record one.

## 6. Record the baseline

```sh
git update-ref refs/claude-review/pr-<n> HEAD
```

This ref means "Claude reviewed here". `pr-diff` shows it as the baseline and
falls back to it for `last` when the user has no submitted GitHub review on the
PR. Idempotent on re-runs.

## 7. Report

Close with: counts by severity, files touched, what you verified clean (so the
user knows what was checked, not only what failed), the pending review's URL,
and the next step — curate it on GitHub or tell you what to change, then
`/pr-publish`.

## Hard rules

- Draft only. Never submit the review and never resolve a thread: both are
  `/pr-publish`, behind an explicit go-ahead.
- Never commit, never push, never record a finding by editing source.
- Nothing outside the PR's own diff is in scope, `[pre-existing]` aside.
