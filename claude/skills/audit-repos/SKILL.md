---
name: audit-repos
description: Audit every git clone gitpane tracks: which are missing the self-hosted forgejo remote, which still carry a deprecated bitbucket or a github remote, and which are dirty or hold work that exists nowhere else. Use for "audit my repos", "check all my clones", "are all my repos on forgejo", "which repos aren't backed up", "any bitbucket remotes left". Every tracked repo at once — the branches inside one repo are sweep-branches.
---

# Audit the tracked repos

`bin/audit-repos` does the measuring. Do not hand-roll a `find` over `~/code`:
the set under audit has to be gitpane's set, read from its `config.toml`
(`root_dirs`, `scan_depth`, `excluded_repos`), or the answer is about a
different list of repos than the one the user looks at every day.

## 1. Run it

```sh
audit-repos              # repos with something to report, from local refs
audit-repos --fetch      # refresh remote-tracking refs first (network, parallel)
audit-repos --all        # every tracked repo, clean ones included
audit-repos --md         # markdown table, for a client that renders one
audit-repos --tsv        # one row per repo, for filtering
```

Read-only: it never writes to a repo, and without `--fetch` it never touches the
network. The column vocabulary is in `audit-repos --help`; below is how to judge
what it prints.

## 2. `!!` is a rule broken, `!` is a mark to interpret

`!!` means `FORGE` is `NO`, or bitbucket survives — the two stated rules. `!` is
everything else the table bothered to print: a github remote, a dirty tree,
branches on no remote. Those mean *look at this*, not *this is wrong*. Report
them as such; calling a deliberate github remote a violation trains the user to
ignore the audit.

## 3. github never excuses a missing forgejo

The rule is forgejo on **every** clone, with no exceptions — not for vendor
clones, not for forks, not for repos deliberately published from github. What
is case-by-case is whether the *github* remote should stay, never whether
forgejo is still required:

- **Alongside forgejo** — a mirror, or the public face of a repo distributed
  from github (`~/.sidorenko_dotfiles`). Fine. Note it and move on.
- **A fork's upstream** — `upstream` tracking the project the fork follows
  (`~/code/Voron-Avtomat-0` follows VoronDesign/Voron-0). Keep it; that is how
  the fork pulls. It still needs its own forgejo origin.
- **The only remote** (`~/code/disk_bench`) — the sole copy lives on a host the
  user does not run. The gap the audit exists to find.

Do not talk yourself out of a `no-forgejo` because the repo looks vendored,
published, or like someone else's work. Distributed from github is not the same
as backed up, and an auditor that excuses repos on its own assumption makes the
whole roster a lie. Report it; let the user decide.

## 4. no-forgejo: verify before proposing anything

- **Read the NOTES cell before believing `FORGE NO`.** A row with `FORGE NO`
  carries where its remotes actually point. `origin→github` is a real gap;
  a bare hostname (`origin→git.lan`) means the forge pattern missed and the
  remote was there all along — fix `AUDIT_REPOS_FORGEJO` in `~/.bashrc.local`,
  never in this public repo, and re-run. Adding a second remote to "fix" one of
  those is wrong.
- **`no-remotes` outranks a merely-missing forge**: nothing about that clone
  exists anywhere else. It is the first thing to say, not one row among eight.
- **Check there is something to save** before proposing a remote:
  `git -C <repo> log --oneline | head` and the flags. An empty scratch repo is
  not a backup gap.
- Adding the remote is the easy half. **Pushing it is publishing** — it needs a
  repo created on the forge and an explicit go-ahead for that specific push.
  The auto-push policy in this repo's AGENTS.md is about *this* repo only; every
  other clone follows the global default of asking first.

## 5. bitbucket: prove it is redundant before removing it

The script finds bitbucket on a `pushurl` and behind `url.<base>.insteadOf`, not
just on `origin` — so show the user where it actually is before touching it:

```sh
git -C <repo> remote -v
git -C <repo> config --get-regexp 'insteadOf$'
```

A bitbucket remote is only safe to drop once the commits exist on forgejo.
Compare refs; do not infer it from the remote merely being present. If forgejo
is behind, the fix is a push, and the removal waits for it.

## 5b. Remote hygiene: dup, multi-url, push→

These three are quiet because `git remote -v` makes none of them look odd:

- **`dup:a,b`** — two names, one URL. Usually a rename that left the old name
  behind. Harmless until a push or a prune picks the one you did not mean, and
  it makes every count of "where does this repo go" wrong. Deleting the spare is
  local and reversible, but confirm which name the user's muscle memory uses.
- **`multi-url:r`** — one remote holding several URLs, so every push goes to all
  of them. Deliberate for a mirror, a surprise otherwise; show
  `git remote get-url --all <r>` before proposing anything.
- **`push→X`** — fetches from one host, pushes to another. Correct for a fork
  workflow, a quiet disaster when it is not intended. Ask which it is rather
  than assuming.

## 6. Read the columns by what is actually at risk

**`L-BR` / `L-CMT` first.** Commits reachable from no remote ref are the only
thing on the table that a dead disk destroys outright — `1 / 21` means one
branch carrying twenty-one commits that exist nowhere but here. `AHEAD` is the
milder version of the same thing. Everything else is recoverable.

`CNF` next: a non-zero conflict count means a merge or rebase stopped in the
middle and was left there, so the worktree is in a state the user probably does
not remember being in. `MOD`/`DEL`/`ADD`/`UNT` are ordinary work in progress —
mention them, do not alarm about them. `BEHIND` costs nothing and loses nothing.

`gone:` in NOTES is an upstream deleted from under local commits; that is
[force-push-recovery] territory and never fixed by pushing. A `mid-*` note means
an operation was abandoned part-way — read `git status` in that repo before
anything else, because the user has probably forgotten it is parked there.

**`fetch-failed` invalidates that row's AHEAD/BEHIND**, whatever the header
says. Never report a repo as up to date on numbers from a fetch that did not
land; say the remote was unreachable and why it matters.

Without `--fetch`, `AHEAD`/`BEHIND` are as old as that repo's last fetch and the
header prints the oldest age. A three-week-old zero is not a fresh one — say
which mode produced the numbers, or re-run with `--fetch`, before telling anyone
their work is pushed.

## 7. Relay the table. All of it. Verbatim.

**Paste the table through, every row and every column.** Do not re-narrate it as
prose and do not rank the rows into a bulleted list — that reports what you
judged important, which is exactly the editorial step an audit exists to remove.
The reader wants to scan for a repo by name and read its own numbers.

**Pick the format for where it will be read.** A fenced block of the default
output holds its columns in a terminal and collapses on a phone; `--md` renders
as a real table in any client that speaks markdown, and is the better default
whenever the user is not obviously looking at a terminal. Either way it is the
script's output pasted through, never a table you retyped by hand — hand-copying
thirteen columns across eight rows is how a number quietly changes.

Commentary goes **after** the table and stays short: what to do about the worst
rows. A footnote to the table, never a replacement for it.

The default already hides the clean repos, which is what makes the table worth
reading — do not re-add them unasked. Reach for `--all` when the user asks about
a specific clean repo or wants the whole roster, and paste that table the same
way.

State the blind spot when it matters: a repo outside `root_dirs` or deeper than
`scan_depth` is not audited and cannot be reported missing — "all 61 are fine"
means all 61 gitpane can see.

## 8. Fix one at a time

Propose the findings grouped, then apply singly on an explicit go-ahead. The
fixes are not one kind of action — adding a remote and pushing publishes,
dropping a bitbucket remote is local and reversible, committing dirty work is
the user's call alone — and a bulk "fix all" silently mixes them.

[force-push-recovery]: ../force-push-recovery/SKILL.md
