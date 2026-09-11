# Why this skill is shaped the way it is

Evidence behind the rules in `SKILL.md` and the brief in `bin/codex-review`,
gathered 2026-09-11. Read before relaxing one of them.

## The finding that constrains everything: a second model can make it worse

*Cross-Model LLM Code Review: Should you use Claude to review Codex or vice
versa?* — <https://arxiv.org/html/2607.21656v1>. 116 LiveCodeBench tasks,
Claude Opus 4.7 × Codex GPT-5.5, static review (reviewer sees problem + draft,
cannot run tests).

| Writer → reviewer | Pass rate | Regression rate |
|---|---|---|
| Codex → Claude | 71.6% → 89.7% (p=.001) | 4.3% (26 fixed) |
| Claude → Codex | 91.4% → 82.8% (p=.046) | **11.2%** (13 broken, 3 fixed) |
| Claude → Claude | 91.4% → 91.4% | — |
| Codex → Codex | 71.6% → 84.5% | — |

Read literally, this says "do not let Codex review Claude" — the exact thing
this skill does. The mechanism is what rescues it: the harm came from *reviewers
emitting a replacement program*. Helpful edits "preserve the writer's structure
and patch one flaw"; harmful ones "discard working solutions entirely and
introduce new bugs", and Codex showed the higher rewrite tendency. The authors'
own suggested mitigation is a gate: make the reviewer decide *whether* to
intervene before it writes anything, and default to keeping the writer's
structure.

So the skill removes the mechanism rather than the reviewer:

- Codex runs in a pinned read-only sandbox — it physically cannot rewrite.
- The brief forbids redesign and demands a pointer to the one thing that breaks.
- Claude verifies each finding and writes any patch itself.
- "Keep the change as written unless the finding survives" is that gate.

Caveats worth remembering: one model pair, Python only, no tool use, single
prompt set. Do not read the percentages as this skill's expected numbers.

## False positives dominate, and they have a signature

- *Are LLMs Reliable Code Reviewers? Systematic Overcorrection in Requirement
  Conformance Judgement* — <https://arxiv.org/pdf/2603.00539> (also
  <https://link.springer.com/article/10.1007/s10515-026-00638-5>). LLM
  reviewers systematically flag conformant code as non-conformant; false
  positives outnumber false negatives across models, and larger models
  overcorrect *more*. The dominant bad rationale is Logic Error (48.2%) — "the
  algorithm is wrong" or "steps are missing" with no falsifiable counterexample
  — then Added Requirement (14.1%), Boundary Error (13.2%), Misread Spec
  (11.7%). "Readability Nitpick" is its own category: rejecting on style
  dressed as a conformance failure.

That taxonomy is why the brief refuses any finding without a triggering input
and a consequence, and why SKILL.md's verification step is "reproduce the path
or drop it" rather than "weigh the argument".

- *Building a code review tool: the LLM patterns that actually work* (G-Research)
  — <https://www.gresearch.com/news/building-a-code-review-tool-the-llm-patterns-that-actually-work/>.
  Single-pass review produced 2–3 false positives per 8 findings and burned
  engineer trust. What fixed it was splitting recall and precision into separate
  passes: pass one captures everything, pass two filters. Their targets: zero
  false positives tolerated, >85% precision. They treat the LLM as "an untrusted
  component".

  This skill's two passes are Codex (recall) and Claude's verification
  (precision). That is the whole division of labour.

- *Reducing False Positives in Static Bug Detection with LLMs* —
  <https://arxiv.org/html/2601.18844v1>; *Utilizing Precise and Complete Code
  Context to Guide LLM in Automatic False Positive Mitigation* —
  <https://arxiv.org/html/2411.03079v2>. Surrounding context is the lever that
  removes false positives — hence the brief tells Codex to read callers, tests
  and definitions rather than judging the diff in isolation, and the script
  points it at the live repo instead of pasting a diff.

## The cold read is the asset — so ration context deliberately

- *Refute-or-Promote: An Adversarial Stage-Gated Multi-Agent Review Methodology*
  — <https://arxiv.org/pdf/2604.19049>. Adversarial kill mandate (one agent
  must refute), deliberate **context asymmetry** so claims get justified
  instead of assumed, and a cross-model critic to break echo-chamber
  validation.
- Steve Kinney, *Using Codex from Claude* —
  <https://stevekinney.com/writing/codex-as-a-second-opinion>. Escalate on
  high-reversal-cost decisions, security-sensitive surfaces, non-trivial
  algorithms, and **after two failed fixes**; skip naming debates and style.
  Return the question, Codex's answer, and a synthesis naming which model to
  trust for *this* question — "never launder confidence without examination".
  Fail-warn, never fail-stop.
- Zack Proser, *I Make Codex Review Every Diff Claude Writes* —
  <https://zackproser.com/blog/codex-reviews-claudes-diffs>. Source of the
  hostile-reviewer framing and of the `block` contract: every block must name a
  concrete failure mode — "this could be cleaner" is a comment, not a block.
  Deliberately withholds the drafting transcript and chain-of-thought so the
  reviewer reads cold. Gates on diff size and hot paths to avoid paying latency
  on trivial changes.
- shimo4228, *codex-review* skill — <https://github.com/shimo4228/codex-review>,
  write-up <https://zenn.dev/shimo4228/articles/codex-review-cross-model-decorrelation?locale=en>.
  Nearest prior art: read-only wrapper, pinned `sandbox_mode`/`approval_policy`,
  "decorrelation seam, not a throughput tool", never paste Codex's output into
  the conversation unverified, and the empty-diff pitfall this script guards.
- *Adversarial Coding* — <https://www.subaud.io/adversarial-coding-competing-models-reviewers/>.
  "A different model reviewing the implementation catches things the
  implementing model doesn't, because it isn't agreeable to its own work."
  Reviewers are held to read-only and to actionable findings.
- SmartScope, *Automating the Claude Code × Codex review loop* —
  <https://smartscope.blog/en/blog/claude-code-codex-review-loop-automation-2026/>.
  Level 1 (a skill, invoked deliberately) is where to start; hook-driven loops
  "don't always fire at ideal moments" and the popular plugin defaults to
  `--dangerously-bypass-approvals-and-sandbox`. Also: `codex exec resume` makes
  Codex reluctant to re-raise issues it once called minor, so a converged fix
  loop still wants one fresh-session audit.

## OpenAI's own guidance

- *Best practices* — <https://learn.chatgpt.com/guides/best-practices>: keep
  approval and sandboxing tight by default and loosen only for trusted
  workflows; a prompt wants goal, context, constraints and completion criteria;
  `AGENTS.md` (and a referenced `code_review.md`) is what Codex follows during
  review.
- *Build code review with the Codex SDK* —
  <https://developers.openai.com/cookbook/examples/codex/build_code_review_with_codex_sdk>:
  "Flag only actionable issues introduced by the pull request"; "prioritize
  severe issues and avoid nit-level comments unless they block understanding of
  the diff"; findings carry a priority 0–3 and a confidence score; file and
  line citations must be exactly right or the comment is rejected.
- *Non-interactive mode* / exec JSON event reference —
  <https://developers.openai.com/codex/noninteractive>,
  cheatsheet <https://takopi.dev/reference/runners/codex/exec-json-cheatsheet/>.

## CLI facts verified locally against codex-cli 0.145.0

Re-check these after a `codex` upgrade; they are the script's contract.

- `codex review` **refuses a custom brief together with any scope flag**:
  `error: the argument '--base <BRANCH>' cannot be used with '[PROMPT]'`, same
  for `--commit` and `--uncommitted`. That is a CLI conflict, not a wrapper
  choice, and it is why the script drives `codex exec` — the engineered brief
  matters more than `review` mode's built-in prompt.
- `--base` and `--uncommitted` are mutually exclusive with each other too.
- `codex login status` exits 1 when not logged in — a cheap preflight. Login is
  interactive, so an agent shell cannot do it.
- On auth failure Codex retries the Responses WebSocket 5× (~7s), falls back to
  HTTPS, then fails — noisy and slow, which is the other reason to preflight.
- `codex exec --json` emits JSONL on stdout (logs stay on stderr):
  `thread.started`, `turn.started`, `turn.completed` (with
  `usage.input_tokens` / `cached_input_tokens` / `output_tokens`),
  `turn.failed` (with `error.message`), and `item.completed` items.
- The final answer is `item.completed` where `.item.type == "agent_message"`,
  field `.item.text`. Documentation that says `item_type` /
  `assistant_message` is stale (openai/codex#4776) — the live shape is `type` /
  `agent_message`, confirmed here.
- **A failed turn still emits an `agent_message`** ("Review was interrupted.
  Please re-run /review and wait for it to complete."), so `turn.failed` must
  be checked *before* the message is read, or an error string gets reported as
  findings.
- `codex exec --json review <scope>` parses: `--json` is an exec-level flag and
  may precede the `review` subcommand.
- `-c sandbox_mode=` and `-c approval_policy=` are real keys; a bad value
  errors at launch (`unknown variant ... expected one of read-only,
  workspace-write, danger-full-access`). `--output-schema` only checks that the
  file is readable — schema validity is server-side, so a malformed schema
  fails mid-run.
- `codex exec review` can hang forever when an internal git command fails —
  openai/codex#41984, open as of 0.152.0, "only an external watchdog stops it".
  Hence `timeout` on every run.
- Git reads inside the read-only sandbox want `git --no-optional-locks` so
  nothing tries to refresh `.git/index`.
