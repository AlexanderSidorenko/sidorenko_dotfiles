---
name: write-skill
description: Author, improve, review, or rename an Agent Skill in this repo, end to end. Use when the user says /write-skill, "write/make a skill", "turn this into a skill", "review/audit this skill", wants a skill renamed or restructured, or complains a skill isn't triggering.
---

# Write a skill

The invocation argument (everything after `/write-skill`) is the request.
Figure out where the user is — new skill, improving an existing one, or a
triggering complaint — and jump in there.

Ground rule from Anthropic's own guidance: skills exist to be used many
times across unknown future contexts. Generalize; a skill that only fits
today's example is useless.

## 1. Capture intent

If the current conversation already contains the workflow ("turn this into
a skill"), extract it from history first: the steps that worked, tools
used, corrections the user made along the way — those corrections are the
most valuable content. Otherwise interview, briefly:

- What should the skill enable, and what's out of scope?
- When should it trigger — which exact phrases would the user say?
- What does good output look like?
- Is any step mechanical enough to be a script?
- This repo only: does it go on master (generic) or job (work-specific)?
  When unsure, ask — never guess toward master (see AGENTS.md).

## 2. Layout and frontmatter

`claude/skills/<name>/SKILL.md`, optionally `scripts/`, `references/`,
`assets/`. Frontmatter is spec-minimal — `name` + `description` only (repo
convention; claude.ai upload paths hard-reject extension fields, so
spec-minimal is what keeps a skill portable).

- `name`: 1-64 chars, lowercase/digits/hyphens, must equal the directory
  name. Verb-first reads best (`write-skill`, not `skill-writer`).
- `description`: 1-1024 chars — but see below; shorter is better.
- Scripts: executable bit set, no interactive prompts ever (they hang in
  agent shells), `--help` that explains usage, errors that say what to try,
  `--dry-run` where destructive. Solve errors inside the script instead of
  deferring them to the agent.

## 3. The description is the entire trigger

Only name + description are in context before invocation; the body is
invisible until the skill fires. Write the description as:

1. What it does — one clause, third person, front-loaded.
2. "Use when …" — the concrete conditions, including 2-4 phrases quoted
   from how this user actually talks ("do the dance"), symptoms and error
   messages, not abstractions ("manages project operations" never fires).
3. A boundary when sibling skills overlap: "X only — Y is <other-skill>".

Two budget realities shape this. The hard cap is 1024 chars, but all
descriptions share one listing budget (~1% of context in Claude Code) and
the least-used skills get silently evicted from it first — so every extra
word in your description taxes the whole collection. A few verbatim
trigger phrases beat exhaustive keyword lists.

Don't summarize the procedure in the description: an agent that can see
"reviews code twice then merges" may do a one-pass review from the summary
without ever reading the body. Describe when to fire, not how it works.

Err pushy against under-triggering (models under-trigger more than they
over-trigger), but fix over-triggering by narrowing and stating what the
skill does NOT do.

## 4. The body

The reader is already smart. Include only what it would get wrong without
the line — project conventions, non-obvious procedure, gotchas, exact
commands for fragile operations. For each sentence ask: would a fresh
agent botch this without it? If not, cut it.

- Under 500 lines; imperative voice; one term per concept.
- Explain why instead of shouting: ALL-CAPS MUST/NEVER is a yellow flag —
  a reason ("they hang in agent shells") outperforms a decree and
  generalizes to cases you didn't enumerate.
- Give one default, not a menu. Add a one-line escape hatch if needed.
- Calibrate freedom to fragility: heuristics where many approaches work,
  exact copy-paste commands where one wrong flag breaks things.
- Gotchas live in SKILL.md itself; bulky reference material moves to
  `references/` with an explicit load trigger ("read references/x.md when
  <condition>"), one level deep, table of contents if over ~100 lines.
- Prefer a tested script over prose for any mechanical procedure: scripts
  don't decay when context gets compacted, and execution costs no context.
  If testing shows the agent re-deriving the same helper every run, that
  helper wants to be a bundled script (house example: job-branch-sync's
  sync-dance).

## 5. Validate and test — untested skills are untested code

1. Mechanical check: run
   `${CLAUDE_SKILL_DIR}/scripts/validate <skill-dir>`
   (from this skill's scripts/; checks frontmatter rules, name/dir match,
   description budget, spec-only keys, executable bits, body length).
2. Trigger test: give a fresh subagent the full skill *listing* (names +
   descriptions only) plus 4-6 realistic task phrasings — the user's
   likely wording, a vague variant, and at least one near-miss that should
   NOT trigger (an easy negative tests nothing). Ask which skill, if any,
   it would invoke for each. Use a small model as the judge — if Haiku
   routes correctly from the description alone, larger models will too.
   Fix the description, not the phrasing, until the boundary holds.
3. Dry-run the procedure once on a real case and read the transcript, not
   just the output: wrong turns mark unclear instructions; skill text that
   never influenced anything is dead weight — delete it.
4. A session that already loaded the old version won't see edits — retest
   fresh.

For heavyweight iteration (eval suites, baselines, A/B judging,
description-optimization loops), don't reinvent: Anthropic's skill-creator
plugin automates exactly that.

## 6. Ship

Repo flow as usual: classify master vs job, commit with the right prefix
(`[claude/skills]` / `[job][claude/skills]`), push, run the
job-branch-sync dance. Then actually use the skill on its first real task
soon after — first-use feedback is the cheapest improvement pass, and each
correction the user makes belongs back in the skill's gotchas.

Everything above synthesizes the spec, Anthropic's docs and skill-creator,
and community practice as of 2026-08-15. Read `references/sources.md`
when a rule here seems stale or contested, or before re-researching.
