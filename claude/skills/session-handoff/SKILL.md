---
name: session-handoff
description: Briefing on everything this session worked on — each thread's state, what is committed, pushed or only in the working tree, machine state left changed, open questions, ordered next steps. Use when the user asks "where are we", "status of everything we worked on", "what do we have uncommitted", "what's left", or before a long break or a context handoff. Read-only: it proposes commits, never makes them. This session's work only — open PRs are pr-statuses, an all-clones audit is audit-repos.
---

# Session handoff

Write for someone acting on this cold — the user after a night's sleep, or a
fresh agent with none of the context. State the **position**: what each thread
is in now, where the work physically lives, what the next move is. How the
session arrived there is noise (`curate-commits` applies the same rule to
commit messages).

## 1. Collect the facts; do not recall them

Recollection of a long session is systematically optimistic: a commit you
*planned* and a commit you *made* leave the same trace in a summary, and the
`gitStatus` in your context is a snapshot from session start that the harness
never updates.

```sh
~/.claude/skills/session-handoff/scripts/asks                     # the user's own turns = the agenda
~/.claude/skills/session-handoff/scripts/repo-state --since <window start>
```

`asks` reads this session's own transcript (`$CLAUDE_CODE_SESSION_ID`) and
prints every message the user typed, slash commands included; its `window:`
line feeds `--since`. Use the window's **first** turn, not the last compaction
boundary — everything after it is this session's work.

Read it even when you think you remember the session. Each
`-- compaction boundary --` marks a point where your context was summarised,
and the threads above the last one are exactly the ones missing from your head.

**A compaction continues the session; a `/clear` ends it.** The user clears so
that the old threads stop following them, and a handoff that digs them back up
undoes the clear. `asks` prints nothing above the last `/clear`, and Claude
Code starts a fresh transcript at each one, so the transcript the same pane
wrote before it belongs to a finished session: do not open it, `asks` it, or
carry its threads or its earlier handoff into this report. Pass `asks` a
session id only when the user names a session to report on.

If `asks` prints `window: empty`, or lists nothing but the handoff request and
housekeeping commands like `/model`, the whole report is one line, such as
*"Nothing since the /clear at 22:20, so there is nothing to hand off."* Skip
repo-state, the tree and the machine checks: everything they would show
predates the session.

`repo-state` fetches, then reports ahead/behind, commits made in the window
(each marked pushed or NOT PUSHED), commits that exist only locally, and every
dirty path with its mtime. Run it in each repo the session touched — a change
to `~/.sidorenko_dotfiles` or another clone is invisible from this one.

Then re-run the cheap checks behind anything you are about to call green:
`systemctl --failed`, the container list, the subsystem's own status script. A
remembered green is the one line in a briefing that makes the user stop
looking.

## 2. Separate this session's work from the rest of the tree

A clone is shared — other Claude sessions, the user's editor, another tmux
pane. A dirty file is yours only if your own transcript touched it; an mtime
older than the session's first turn settles it the other way, and
`repo-state --since` flags those `pre-window`.

List them, in their own bucket, labelled as not from this session. Merging
them in silently is worse than omitting them: the user commits a stranger's
half-finished edit believing it is yours.

## 3. Work lives in four places, and they disagree

Report all four for every thread. Each adjacent pair is a way to lose work:

| Where | What it means | How it bites |
|---|---|---|
| working tree | uncommitted | a careless checkout, and it is gone |
| local commit | not on the remote | no other clone can see it |
| pushed | on the remote | — |
| the running machine | applied, or not | see below |

Anything that configures a running system has that fourth axis, and both
directions are worth a line. **Applied but uncommitted**: the machine runs
behaviour no commit contains, and the next build from git silently reverts it.
**Committed but not applied**: the file claims behaviour the machine does not
have until someone rebuilds or reboots. Name the check you ran —
`systemctl is-active`, the current generation, the service's own status view.

Then the delta the session left on the machine, re-read now rather than
remembered: anything stopped, masked, unmounted, rate-limited, or started for
a test, plus whatever you left running — a background shell, a subagent, a
scheduled wakeup, an armed loop. *"I stopped the collectors to measure
something"* is the highest-cost line to omit from a handoff.

Work that exists only in the scratchpad dies with the session. Say so, and
write its full absolute path.

## 4. One state per thread, from a fixed vocabulary

- **done, verified** — and the measurement or command that proves it
- **done, unverified** — and the check that would prove it
- **needs the user** — the exact action: a sudo command, an apply, a reboot, a
  cable
- **blocked** — on which question, from §5
- **dropped** — and why, so it is not silently retried

Avoid "in progress": at a handoff it describes nothing. Name the next concrete
step instead. A tool call that succeeded is not a thread that is done — done
means the user's goal holds, checked.

## 5. Questions: at most a few, each with a default

A question earns a place only if the answer changes what happens next. Give
each one the default you will take if the user says nothing — a question
without one makes them supply both the decision and the fallback, which is
why those go unanswered.

Everything else that is merely interesting is a note in the report, not an
ask. Use `AskUserQuestion` only where an answer genuinely unblocks the next
step; otherwise plain prose, which the user can skip.

## 6. Next steps, ordered by what is lost if forgotten

Not by effort, and not by what you find interesting. Uncommitted work and
machine-only state first, then what only the user can do, then the work you
would pick up. Name the single thing you would do first.

## 7. The report

Terminal markdown, read now by the person who was there — so no artifact
unless they ask for one or it is going to someone else, and `clip` if they
want to carry it elsewhere. A long session still fits on a page: anything
re-derivable from one command is a line, not a section.

1. **The verdict, one line** — is anything broken, at risk, or waiting right
   now.
2. **Threads** — a compact table: thread | state (§4) | where it lives (§3).
3. **Committed** — one row per commit, short sha and subject, pushed or not.
4. **Uncommitted** — grouped by thread, with the not-from-this-session bucket
   separate, and for each group the commit it would become if asked.
5. **Machine state** — only what the session changed and what it is now.
6. **Questions** (§5), then **next steps** (§6).

If the user already asked for status earlier in the session, lead with what
changed since that answer instead of restating it. A handoff from before the
last `/clear` is not one of those; the user cleared it.

## Hard rules

- Read-only. No commits, no pushes, no applies, no restarts, no tidying of
  stray files. Reporting that something is uncommitted is not permission to
  commit it — that needs the user's explicit go-ahead, and then
  `curate-commits` writes it.
- Never report a state you did not just observe. What you cannot check — it
  needs sudo, or the user's eyes — is reported as unverified, with the check
  named.
- Never claim a commit exists without its sha out of `git log`.
- A repo's own commit or push policy tells you how to *describe* the state,
  never that it is time to act on it.
