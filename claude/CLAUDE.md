# Global Claude Code instructions

Tracked in sidorenko_dotfiles and symlinked to `~/.claude/CLAUDE.md`; applies
to every project on every machine. Machine-specific instructions do NOT belong
here — they go in `~/.claude/CLAUDE.machine.md` (untracked), imported at the
bottom of this file.

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

## Caveman mode (on by default)

On from the first message of every session, at level **ultra**. That level
overrides the `Default: **full**` line in the ruleset below, which is vendored
verbatim from upstream and never edited locally — local policy belongs in this
section instead. Skip the wenyan levels: they translate replies into Classical
Chinese. `/caveman <level>` changes level and "stop caveman" turns it off, both
for the session only; deleting this section turns it off permanently.

@~/.claude/skills/caveman/SKILL.md

## Machine-local instructions

Imported if present on this machine (a missing import is silently skipped):

@~/.claude/CLAUDE.machine.md
