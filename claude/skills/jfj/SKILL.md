---
name: jfj
description: Sweep source files for `jfj` markers — the user's inline notes to the agent — answering the questions in chat, doing the requested edits, and deleting each marker once handled. Use when the user says "/jfj", "answer my jfj notes", "I left some jfjs", "do a jfj pass", or otherwise points at jfj comments in the code.
---

# jfj: inline notes to the agent

`jfj` is a fast-to-type marker the user drops into source files while
reading. Each one is a note addressed to me, of one of two kinds, told
apart by wording:

- **Question** — answer it in the chat reply, never in the file.
- **Request** — make the edit.

Either kind is deleted once handled: the file ends the pass clean.

## The pass

1. **Find**: `rg -in jfj` from the repo root — whole repo, unless the
   invocation names a path or file, then only that. Case-insensitive; the
   marker may be bare (`# jfj why this order?`) or punctuated
   (`// jfj: drop this branch`). In this repo, skip hits under
   `claude/skills/jfj/` — that is this skill talking about itself.
2. **Classify** each hit from its wording: interrogative → question,
   imperative → request. Genuinely ambiguous → answer it as a question and
   say which reading you took.
3. **Handle**: answer the questions; make exactly the edits the requests
   ask for and nothing more — a marker is not an invitation to refactor
   around it. A question whose real answer is a code change still gets an
   answer, not an edit.
4. **Delete** the marker: the whole comment, block comments included, with
   its comment leader — no stray blank line, no empty `//` left behind. A
   marker appended to a line of code loses only the comment, not the code.
5. **Report** one line per marker, grouped by file:
   `path:line — <the note, abbreviated> → <answer, or what changed>`.
   Finding zero markers is a valid result; say so rather than hunting for
   work.

Handled markers vanish, so that report is the only surviving record of the
pass — write it so the user can see what happened without re-reading the
diff.
