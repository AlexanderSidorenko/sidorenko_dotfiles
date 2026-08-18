# Global Claude Code instructions

Tracked in sidorenko_dotfiles and symlinked to `~/.claude/CLAUDE.md`; applies
to every project on every machine. Machine-specific instructions do NOT belong
here — they go in `~/.claude/CLAUDE.machine.md` (untracked), imported at the
bottom of this file.

## Git: push only on explicit confirmation, unless the repo says otherwise

Before starting work in a repo, fetch the remote(s) and rebase if behind.
Committing locally when a change is finished is fine. By default do NOT `git push`
(or otherwise publish or rewrite remote history) unless I explicitly confirm that
specific push — no standing permission, no pushing "to finish up".

A repo overrides this only by stating its own push policy in its CLAUDE.md or
AGENTS.md; that statement then wins for that repo. The override has to be an
explicit policy, not an offhand remark about pushing "automatically" — absent
one, the default above applies. `sidorenko_dotfiles` has such a policy: anything
committed there is pushed immediately.

## Git: commit by checking out the branch, never with plumbing

To put a commit on a branch, check that branch out and run `git commit`. Carry
dirty state across the switch with an explicit `git stash push` /
`git stash pop --index`.

Never author a commit with plumbing (`git commit-tree`, `git hash-object` +
`git update-ref`, `git branch -f`), and never from a path that leaves the working
tree on a different branch than the one receiving the commit. Hooks do not run,
so message and content guards silently stop applying; the committed content never
lands in the working tree, so anything reading files rather than git sees no
change at all; and a branch moves with nothing in `HEAD`'s reflog to show it.

## Clipboard

To put text on the user's local clipboard, pipe it to
`~/.sidorenko_dotfiles/bin/clip`:

```sh
clip < file.md          # on PATH in interactive shells
~/.sidorenko_dotfiles/bin/clip < file.md   # full path is safer from agents
```

It picks the right transport automatically: inside tmux it uses
`tmux load-buffer -w` (tmux emits OSC 52 on the attached client's tty),
otherwise it emits OSC 52 itself. Both work even when stdout is not a
terminal, so it works from Claude Code's Bash tool.

When the user asks for "copyable" text (e.g. a drafted PR comment), write it
to a file and run `clip` on the file — text rendered in the terminal picks up
the CLI's left margin and is not cleanly copyable.

The **clip skill** has the full procedure plus destination-aware formatting
(slack, confluence, jira, plain) — use it whenever copying for a named
destination.

## Machine-local instructions

Imported if present on this machine (a missing import is silently skipped):

@~/.claude/CLAUDE.machine.md
