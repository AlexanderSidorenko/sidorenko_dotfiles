# pr-references — shared assets for the pr-* skills

Not a skill (no SKILL.md on purpose). Reference material shared by
pr-statuses, pr-checkout, pr-review, pr-comment-sweep, pr-publish and
pr-restack, so the contract between them can't drift. Skills reach these
files as `../pr-references/<file>`.

| File | What it holds | Used by |
|---|---|---|
| pending-review.md | The draft-surface invariant, the four layers and what each may write, the pending-review model and its constraints | all |
| severities.md | Severity vocabulary for triage, and the conventional-comment prefix each one publishes as | review, comment-sweep, publish |

The mechanical half lives in `bin/` rather than here, because a tested script
doesn't decay when context is compacted:

| Script | Role |
|---|---|
| `pr-help` | terse map of the whole family — the front door, for humans |
| `pr-draft` | every write to a pending review — the only thing that talks to the review API |
| `pr-prep` | self-cleaning preflight: refuses on real work, clears review residue, checks out |
| `pr-diff` | iterations of a PR, rebase-aware; `last` = your review baseline |
| `pr-threads` | unresolved threads with outdated / file-changed flags |
