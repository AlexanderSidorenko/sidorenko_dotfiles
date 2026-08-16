# Sources behind this skill's guidance

Researched 2026-08-15. Read this file when a rule in SKILL.md seems stale
or contested, or before re-researching skill-authoring practice — start
here, not from scratch. One line per source on what it uniquely
contributes.

## Official

- <https://agentskills.io/specification> — the format spec: field
  constraints (name 64, description 1024, compatibility 500), progressive
  disclosure levels with token numbers, 500-line body guidance,
  `skills-ref validate`.
- <https://agentskills.io/skill-creation/best-practices> — body doctrine:
  "Claude is already very smart" cut-test, freedom-to-fragility
  calibration, defaults-not-menus, gotchas-in-SKILL.md, load triggers for
  reference files.
- <https://agentskills.io/skill-creation/optimizing-descriptions> —
  description-as-trigger, deliberate pushiness against under-triggering,
  trigger-eval methodology (near-miss negatives, 60/40 train/validation,
  run each query 3x).
- <https://agentskills.io/skill-creation/evaluating-skills> — output-eval
  loop: baselines, evidence-based assertions, pattern analysis, "if pass
  rates plateau, try REMOVING instructions".
- <https://agentskills.io/skill-creation/using-scripts> — agent-friendly
  CLI rules: never interactive, --help as discovery, structured stdout,
  distinct exit codes, --dry-run, predictable output size.
- <https://platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices>
  — third-person descriptions, one-level-deep references, TOC for >100-line
  files, Claude-A-authors/Claude-B-tests loop, pre-share checklist.
- <https://code.claude.com/docs/en/skills> — Claude Code specifics: the
  ~1%-of-context listing budget, eviction of least-used descriptions,
  1536-char listing truncation, frontmatter extensions (and that upload
  paths hard-reject them — why we stay spec-minimal), $ARGUMENTS.
- <https://www.anthropic.com/engineering/equipping-agents-for-the-real-world-with-agent-skills>
  — bundled context is effectively unbounded; ask the agent to
  self-reflect failures back into the skill.
- <https://github.com/anthropics/skills> — skill-creator meta-skill: the
  interview questions, "make descriptions a little pushy", the writing-style
  section (explain why "in lieu of heavy-handed musty MUSTs"; ALL-CAPS as
  yellow flag), full eval/description-optimization machinery we deliberately
  did not duplicate.

## Community

- <https://blog.fsck.com/2025/12/17/claude-code-skills-not-triggering/> —
  silent listing truncation at the shared char budget; skills become
  invisible with no warning; SLASH_COMMAND_TOOL_CHAR_BUDGET.
- <https://happyskills.ai/blog/why-your-skill-never-fires/> — eviction
  dynamics: longer descriptions make eviction MORE likely, so keyword
  stuffing backfires; five-part description grammar.
- <https://github.com/obra/superpowers> (skills/writing-skills) — "NO
  SKILL WITHOUT A FAILING TEST FIRST"; pressure-testing; describe WHEN to
  use, never the workflow (agents shortcut from summaries); anti-pattern
  list.
- <https://blog.fsck.com/2025/10/09/superpowers/> and
  <https://blog.fsck.com/2025/10/16/skills-for-claude/> — bootstrap /
  mandatory-use framing; skills are prompt injection by design, treat
  third-party skills as untrusted code.
- <https://simonwillison.net/2025/Oct/16/claude-skills/> — token
  economics: skills cost dozens of startup tokens where MCP costs tens of
  thousands.
- <https://codemeetai.substack.com/p/how-to-create-a-claude-code-skill> —
  field lessons: abstract descriptions never fire, edited SKILL.md isn't
  reloaded mid-session, template-vs-reference confusion, skill rot.
