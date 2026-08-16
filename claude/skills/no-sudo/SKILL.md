---
name: no-sudo
description: How to handle anything needing root — the agent's shell has no sudo; the user does. Use whenever a task needs sudo/root — package installs, systemctl, /etc edits, udev/NetworkManager rules, mounts — or when a command fails with "permission denied" and sudo would be the reflex.
---

# Sudo protocol

My shell has no sudo, and a sudo password prompt inside a tool call just
hangs. The user has sudo. Root work is therefore a structured handoff — never
a workaround. Don't hunt for sudo-less ways to mutate system state, don't
edit protected files via other channels, don't retry with variations hoping
one sticks.

## Batch, don't trickle

Collect EVERY privileged command the task needs before asking. One handoff
with five commands beats five interruptions. If later steps depend on the
output of an early privileged command, say so: hand over the read-only
recon batch first, then the state-changing batch after seeing results.

Present the batch as:

1. One copyable block (use the **clip skill** — put it on their clipboard,
   don't make them copy from the terminal).
2. One line of explanation per command: what it does, why this task needs
   it, and what it changes. Every flag that isn't obvious gets a word.
3. What to bring back: the user runs the batch in their own terminal
   (sudo needs its password prompt there — never suggest the `!` prefix,
   it has no interactive console, and never assume passwordless sudo).
   If verification needs root-only output, name the exact lines worth
   pasting back.

After the user runs it, verify with read-only checks I can run without sudo
— never assume the batch worked.

## State changes prefer scripts, not commands

Read-only privileged commands (journalctl, dmidecode, reading /etc/sssd/…)
can be handed over as plain commands.

Anything that MODIFIES state — writing under /etc, systemctl
enable/disable/restart, package installs, udev or NetworkManager rules —
should instead land as an idempotent, version-controlled script the user
runs once:

- A function in `install.sh` when the change should apply to future
  machines (follow its conventions: guard on current state, log what
  happened, safe to re-run — see AGENTS.md).
- A script in `bin/` when it's a standalone operation.

The handoff then becomes "re-run `./install.sh`" or "run `sudo bin/<x>`".
The reasons this is worth the extra minutes: the change is reviewable
before it runs, survives machine rebuilds, self-documents in git history,
and re-running it is safe.

A genuinely one-off state change (a diagnostic toggle, a temporary service
stop) may skip the script — say explicitly that it's deliberately not being
scripted and why, and still batch + explain it.
