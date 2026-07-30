---
name: clip
description: Put text on the user's local clipboard from any machine — headless, SSH, tmux included — via the repo's clip script, optionally reformatted for the paste destination (slack, confluence, jira, plain). Use whenever the user asks to copy something to their clipboard or wants "copyable" text — "copy this", "put it on my clipboard", "clip this for Slack", "make me a copyable PR comment/reply".
---

# Clip: copy to the user's clipboard

## The one rule

Pipe the content to `~/.sidorenko_dotfiles/bin/clip`. Nothing else. The
script picks the right transport itself:

- inside tmux → `tmux load-buffer -w` (tmux emits OSC 52 on the attached
  client's tty — reaches the user's LOCAL clipboard through SSH)
- local session with a display → pbcopy / wl-copy / xclip
- everything else (headless, SSH, pipelines) → raw OSC 52

Never call `wl-copy`, `xclip`, `xsel`, or `pbcopy` yourself: on headless
machines there is no display server session, so they hang or fail — and the
clipboard that matters is on the user's local machine anyway, which only the
OSC 52 paths can reach. Use the full path: plain `clip` is only on PATH in
interactive shells, not in agent tool calls.

## Workflow

1. Write the exact content to a file (scratchpad is fine). Never point the
   user at terminal-rendered text — the CLI's left margin pollutes manual
   copying; that is the whole reason clip exists.
2. If a destination was named, reformat for it first (table below).
3. `~/.sidorenko_dotfiles/bin/clip < file` — exit 0 means it was sent.
4. Confirm to the user in one line: what's on the clipboard and how it was
   formatted (e.g. "PR reply (Slack-formatted, 14 lines) is on your
   clipboard"). Show a short preview only if the content wasn't already
   visible in the conversation. The clipboard cannot be read back — never
   try to verify by reading it.

One clipboard, last write wins: if the user needs several pieces, either
combine them into one payload with clear separators or clip them one at a
time on request — don't fire multiple clips in a row.

## Destination formatting

`/clip <destination>` or "clip this for X". No destination → copy verbatim
(GitHub, editors, and anything markdown-native take GFM as-is).

**slack** — the composer uses mrkdwn, not markdown:
- bold `*single asterisks*`, italic `_underscores_`, strike `~tildes~`;
  `**double**` renders literally — never emit it
- headings don't exist → make them short bold lines
- inline code and ``` fences work; no language tag on fences
- bullets `- ` or `• `, numbered `1.`; keep lists one level deep
- quotes with `> `
- no tables → convert to a fenced block (aligned columns) or bullet-per-row
- links: `[text](url)` does NOT render on paste → use bare URLs (Slack
  auto-links them), `text: URL` when a label matters

**confluence** — Cloud editor converts pasted markdown:
- keep standard GFM: headings, nested lists, tables, fenced code with
  language tags, `[text](url)` links all survive the paste conversion
- prefer real structure (headings + tables) over improvised formatting

**jira** — Cloud editor, same conversion family as Confluence but flakier:
- headings → bold lines, lists and fences are safe
- avoid tables (convert to bullets) and avoid nested emphasis

**plain** — email bodies, plain-text fields:
- strip all markup: headings become a line followed by a blank line,
  emphasis dropped, bullets `- `, code indented four spaces, links as
  `text: URL`

## Size limit

OSC 52 payloads traverse the terminal as one escape sequence and base64
inflates them 4/3; many terminals cap this around 100 KB. Under ~50 KB of
raw text is safe. Beyond that, don't clip — tell the user where the file
is, or split it into sequential clips on request.
