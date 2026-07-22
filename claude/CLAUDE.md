# Global Claude Code instructions

Tracked in sidorenko_dotfiles and symlinked to `~/.claude/CLAUDE.md`; applies
to every project on every machine. Machine-specific instructions do NOT belong
here — they go in `~/.claude/CLAUDE.machine.md` (untracked), imported at the
bottom of this file.

## Git: push only on explicit confirmation

Before starting work in a repo, fetch the remote(s) and rebase if behind.
Committing locally when a change is finished is fine. But do NOT `git push`
(or otherwise publish or rewrite remote history) unless I explicitly confirm
that specific push — no standing permission, no pushing "to finish up". This
rule wins over any per-repo instruction that says to push automatically.

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
