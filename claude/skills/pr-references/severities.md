# Severities and how they publish

Severity is for triage — ordering the work and reporting counts. What reaches
GitHub is the conventional-comment prefix, because that is what reviewers and
tooling in the wild already read. The bracket tags are internal and never
appear in published text.

| Severity | Publishes as | Means |
|---|---|---|
| `[critical]` | `issue:` | wrong results, data loss, a crash, a security hole |
| `[medium]` | `issue:` | a real defect on a reachable path |
| `[minor]` | `suggestion:` | works, but there is a clearly better form |
| `[nit]` | `nit:` | style or naming; the author may decline without argument |
| `[question]` | `question:` | you cannot tell from the code whether it is right |
| `[note]` | `comment:` | context worth recording, no action implied |
| `[verified]` | `praise:` | subtle correctness you independently confirmed |
| `[pre-existing]` | parenthetical | composable with the others: "(pre-existing, but this PR exercises it)" |

`[verified]` earns its place: a review that only lists faults tells the author
nothing about what was actually checked, and the subtle-but-correct cases are
exactly the ones a later reader will want to know someone looked at.

Write the finding as a statement, not a puzzle: one sentence saying what is
wrong, then the evidence, then a concrete suggestion. The author is the reader
— not a log file, and not you six months from now.
