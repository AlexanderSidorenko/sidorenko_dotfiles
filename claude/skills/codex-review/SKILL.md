---
name: codex-review
description: Run OpenAI Codex read-only over work Claude just produced, for a second opinion from a different model family. Use on "have codex review this", "get codex to check my work", "second opinion", "cross-check with another model"; before committing something expensive to get wrong (auth, migrations, concurrency, irreversible); after two of your own fixes failed; or to refute a plan before code exists. Cross-model only — Claude’s own review pass is code-review, drafting PR comments is pr-review.
---

# Cross-model review: Codex reads what Claude wrote

## Run the script

```sh
~/.sidorenko_dotfiles/claude/skills/codex-review/bin/codex-review \
  --goal "<what the change was supposed to accomplish>"
```

With no scope flag it reviews uncommitted changes when the tree is dirty, else
the current branch against its base, and prints which it chose. Other scopes:
`--uncommitted`, `--base <ref>`, `--commit <sha>`, `--plan <file>`. `--focus
"<text>"` adds pressure points. `--help` has the rest.

Do not hand-roll `codex exec` instead. The script pins the read-only sandbox
and `approval_policy=never` over whatever `~/.codex/config.toml` says, wraps
the run in a watchdog, and checks `turn.failed` before reading the message —
skip any of those and you get an edit you did not ask for, a hang, or an error
string parsed as findings.

**`--goal` is the goal, never your reasoning.** A reviewer that reads why you
chose an approach starts defending it, and the cold read is the whole reason to
call a second model. Say what the change had to do; let Codex decide whether it
does it.

## Codex flags; you decide

Its output is untrusted input to a decision you own — not a verdict to relay.
Wrong findings outnumber right ones in every published evaluation of LLM
reviewers, and the characteristic failure is confident overcorrection: a claim
that the logic is wrong, with no case that actually breaks it.

Work each finding before it reaches the user:

1. **Reproduce the failure mode from the code.** The brief makes Codex state
   an input or state, what goes wrong, and what it costs. Trace that path
   yourself. If the path does not exist — the caller already guards it, the
   type forbids it, the test covers it — the finding is dead. Drop it and do
   not mention it.
2. **Prefer a test over an argument** where one is cheap. A failing test
   settles it; so does a passing test over the exact input Codex named.
3. **Keep the change as written unless the finding survives.** Rewriting
   working code on a reviewer's say-so is how a second opinion makes things
   worse — it measurably regresses more often than it helps. Patch the one
   thing that broke; leave the structure alone.
4. **Fix scope, not taste.** Style, naming and "could be cleaner" findings are
   out of contract for this skill; the brief tells Codex to suppress them, and
   any that leak through get dropped, not debated.

## Report it as a disagreement, not as an oracle

Give the user, per surviving finding: what Codex claimed, what you found when
you checked, and your call with the reason. Where you and Codex disagree, say
so explicitly and say which of you to trust *for this specific question* —
laundering its confidence into your own voice is the failure mode. Findings you
killed are worth one line each, so the user can overrule you.

Confirmed critical findings are a stop signal: surface them before committing
or pushing, not after.

## When it earns its cost, and when it does not

Reach for it when being wrong is expensive or hard to reverse: auth, crypto,
untrusted input, migrations, concurrency, money, deletes. Also after two of
your own fixes have failed — that is the signal that the blind spot is yours.
And on a plan, before the code exists, where a refutation costs a paragraph
instead of a day (`--plan`).

Skip it for renames, formatting, docs, config tweaks and anything you can
settle by reading the code. This is a decorrelation seam, not a throughput
tool: value comes from one different model reading cold, so running it twice,
or running it on everything, buys noise. Your own subagents are the throughput
answer.

## Gotchas

| Symptom | What it means |
|---|---|
| exit 5, "not logged in" | `codex login` is interactive and cannot run from an agent shell. Ask the user to run `! codex login` in this session; `codex doctor` diagnoses the rest. |
| exit 7, watchdog killed it | Usually [openai/codex#41984](https://github.com/openai/codex/issues/41984): a failed internal git command never ends the turn, so an external timeout is the only thing that stops it. Retry with a smaller scope. |
| exit 7, "run failed" | Codex emits an `agent_message` even when the turn fails ("Review was interrupted…"), so that text is never findings. The script checks `turn.failed` first; keep that order if you ever parse the stream yourself. |
| exit 6, nothing to review | The scope resolved empty — commonly `--base` on a branch already merged, or a clean tree. Pick the scope explicitly. |
| exit 3, no `codex` | It is in `nix-packages.sh`; `nix_install` restores it. |
| Codex is missing, unauthenticated, or times out | Fail warn, never fail stop: continue with your own review and tell the user the cross-model pass did not run. Never silently skip it — a review the user thinks happened is worse than none. |
| Reviewing this repo's `job` branch against `master` | That diff is the entire work overlay, not your change. Use `--uncommitted` or `--commit`. |

Two flags that look useful and are not: `codex review` cannot take a custom
brief together with any scope flag (the CLI refuses the combination), which is
why the script drives `codex exec` instead; and `--output-schema` is validated
server-side only, so a malformed schema fails at runtime rather than at launch.

`references/sources.md` has the evidence behind the framing choices above —
read it before relaxing one of them, or before re-researching this.
