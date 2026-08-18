# Task: build a write-time journal + recap harness for long-horizon runs

**Spec v2.** The v1 spec was reviewed against the live Claude Code hooks documentation
(installed version 2.1.234, 2026-08-18) and the corrections are baked in below. Three
v1 claims were refuted by the docs — prompt-type hooks writing files, SessionEnd not
firing on Ctrl+C, and Stop covering interrupts — see the changelog at the bottom.
Everything marked **[verified]** was checked against the docs; still re-run the
"verify before you code" step against the version installed on *this* machine.

## Context

I run long-horizon autonomous tasks in Claude Code (~1hr) on a top-tier model. When I
check in — mid-run or ~30min after completion — I'm cold: I don't know what was done,
what needs review, or what's next. Today I ask the running session for a recap, which
forces an expensive full-conversation re-read (prompt cache long expired, fully
uncached input).

The fix is NOT a better post-hoc summarizer. It's moving summary production to
**write time**: the session journals as it works, and recaps are served from that
journal by a cheap model, out of band.

**Governing principle: the journal is the only interface. From the user's side the
main session is write-only.** I never ask it what it did.

## Current state — inspect before building

I already have a journal on this machine, but it's unstructured (append-only prose,
no schema). Before writing anything:

1. Read my `CLAUDE.md` and any existing `.claude/` config, hooks, and skills — both
   user-level (`~/.claude/`) and project-level.
2. Find the existing journal file and read its format.
3. Report what you found and how you plan to migrate it. **Do not discard existing
   journal content** — migrate or archive it.

This is a modification of an existing setup, not a greenfield build.

## Verify before you code

Hook event names, handler types, and stdin payloads change between Claude Code
versions. Run `claude --version`, check the current hooks reference, and confirm the
**[verified]** facts below still hold. If anything disagrees, tell me and adapt —
don't code against this spec if the docs on this machine's version disagree.

Facts already verified against 2.1.234 — re-confirm, don't re-derive:

- Events `SessionStart`, `PostToolUse`, `PostToolUseFailure`, `Stop`, `PreCompact`,
  `SessionEnd` all exist.
- Prompt-type hooks are **evaluation-only** (they return an ok/reason decision and
  cannot write files or run commands). Anything that writes the journal must be a
  **command hook**.
- Stop hook stdin includes `last_assistant_message` directly, plus `session_id`,
  `transcript_path`, `stop_hook_active`. Stop does **not** fire on user interrupts
  (Esc / Ctrl+C) — only when a turn finishes naturally.
- SessionEnd **does** fire on Ctrl+C (turn aborts, SessionEnd hooks run, exit 143).
  Its hooks share a ~1.5s budget, raisable via the hook's `timeout` field to at most
  60s — enough for a mechanical stamp, not a model call.
- `PostToolUse` fires only on **success**; failures fire `PostToolUseFailure`.
- SessionStart supports matchers `startup` / `resume` / `clear` / `compact` / `fork`,
  but the source is **not** in the hook's input JSON — distinguish by wiring separate
  hook entries per matcher.
- `claude -p --output-format json` reports per-invocation usage and cost.
  `--model haiku` is a valid alias.
- There is no env var to suppress hooks in headless mode; use
  `--settings '{"disableAllHooks": true}'`.

## Architecture

Two layers, deliberately separated:

**Mechanical layer — no model, zero tokens.**
`PostToolUse` **and** `PostToolUseFailure` command hooks (same script) append one
line per tool call to `.journal/ledger.tsv`:
`ts | tool | path | ok|fail`. Complete coverage — success *and* failure — never read
by a human. This is ground truth and it survives crashes.

**Judgment layer — cheap model, rare, mechanically gated.**
Fires only at real boundaries, and only when the gate passes (below). Emits at most
one LOG entry and rewrites HEAD.

## File layout

`.journal/` contains **separate files** — this is deliberate, not stylistic:

```
.journal/
├── HEAD.md       <- FULL REWRITE every flush, via temp file + atomic mv. Never appended.
├── LOG.md        <- append-only
├── ledger.tsv    <- mechanical layer
├── base_sha      <- diff anchor (see stamping rule)
└── costs.log     <- one line per Haiku invocation: ts, input/output tokens, cost
```

`HEAD.md`:

```
goal:     <current objective>
blocked:  <blocker or none>
next:     <immediate next step>
review:   <numbered open items needing human review>
```

`LOG.md` entries:

```
### <ts> <one-line intent>
did:        <action + outcome>
touched:    <paths>
confidence: high | shaky | guessed
review:     <what a human must check, or none>
```

HEAD must answer "where are we" in ~200 tokens without reading LOG at all.

**Why separate files:** the v1 failure mode was HEAD going stale because a writer
appends to LOG but forgets to overwrite HEAD. With HEAD as its own file written by
`mv $(mktemp) HEAD.md`, appending to HEAD is structurally impossible, LOG stays
append-only with no rewrite risk, and Tier 0 recap is literally `cat`.

## Hooks to wire

- **`SessionStart`** — command hook: stdout `HEAD.md` + `git log --oneline -5`
  (stdout is injected into context, so the agent and I both start oriented). Wire it
  for the `startup`, `resume`, and `compact` matchers — the `compact` firing
  re-injects HEAD after compaction, which is a feature.
  **base_sha stamping rule:** stamp `git rev-parse HEAD > .journal/base_sha` **only
  if the file is absent**, and only in the `startup` / `clear` matcher entries. A
  resume or a second session mid-task must NOT move the anchor — restamping silently
  shrinks the unclaimed-changes list, which is the accuracy backstop.
- **`PostToolUse` + `PostToolUseFailure`** — the ledger append. Command type, same
  script, status column `ok`/`fail`. Must be fast and must never block. Single-line
  appends under PIPE_BUF are atomic; no locking needed.
- **`Stop`** — command hook running the **writer wrapper** (below). Stop fires at
  every natural turn end, so the wrapper's mechanical gate does the filtering.
- **`PreCompact`** — the same wrapper with `--force` (bypasses the gate). Highest-
  value trigger: compaction is lossy and the journal is the only thing that
  outlives it.
- **`SessionEnd`** — mechanical stamp only: append a `session_end <reason>` line to
  the ledger. It fires on Ctrl+C **[verified]**, but its time budget rules out a
  model call — never put the Haiku writer here.

**Interrupt semantics (accepted degradation):** Stop does not fire on Esc/Ctrl+C, so
an interrupted turn gets no judgment flush. Recovery on interrupt is
ledger + `git diff` — that path is exercised by verification step 4.

## The writer wrapper (Stop / PreCompact)

A shell script. In order:

1. **Mechanical gate:** count ledger lines since the last flush marker. Fewer than
   10 and not `--force` → `exit 0` without invoking any model. This enforces the
   "<1 entry per 10 tool calls" target structurally and makes most Stop firings cost
   zero tokens.
2. **Bound the input:** read the hook's stdin JSON; extract `last_assistant_message`.
   Feed the Haiku call **exactly**: `last_assistant_message` + the ledger tail since
   the last flush + current `HEAD.md`. **Never pass or read `transcript_path`.** The
   stdin payload makes this easy — there is no reason for the writer to ever touch
   the transcript. If it can read the transcript it will, and you've reinvented the
   expensive problem inside the cheap layer.
3. **Invoke:**
   `claude -p --model haiku --settings '{"disableAllHooks": true}' --output-format json`
4. **Apply output mechanically:** the model returns (as structured text) an optional
   LOG entry and a full new HEAD. The *script* appends to `LOG.md` and atomically
   `mv`s the new `HEAD.md` — the model never writes files.
5. **Record cost:** parse usage from the JSON output into `.journal/costs.log`.
6. Write a flush marker line into the ledger.

Emission rule, stated strictly in the Haiku prompt:

> Emit NOTHING unless one of these occurred: a decision with rejected alternatives,
> an assumption left unverified, a discovery that invalidates the plan, or a blocker.
> Log deltas, not progress. If an entry wouldn't change what a returning human would
> DO, don't write it. Always return the full rewritten HEAD regardless.

## Hard invariant: recursion guard

Every headless `claude -p` this system spawns — the writer wrapper AND
`recap.sh --full` — runs in the same project directory and would therefore load the
project's hooks: the journaling hooks would fire inside the journaling system
(recap tool calls polluting the ledger, nested Stop flushes). **Every headless
invocation must pass `--settings '{"disableAllHooks": true}'`.** No exceptions.
This is the design's biggest silent-failure risk; treat a missing guard as a bug.

## Recap consumer — `scripts/recap.sh`

Standalone. Must run with the main session untouched and still working.

- **Tier 0:** no args → `cat .journal/HEAD.md`. Zero model tokens.
- **Tier 1:** `--full` → one-shot
  `claude -p --model haiku --settings '{"disableAllHooks": true}'`, fed HEAD + LOG +
  `git diff --stat $(cat .journal/base_sha)` + ledger.

Tier 1's job is **reconciliation, not summarization**. It must:

1. Output a review queue ordered by risk (`confidence: guessed` ranks highest).
2. Explicitly flag **files that changed but appear in no LOG entry.**

That second output is the accuracy backstop. A self-reported journal inherits the
agent's blind spots — anything it silently broke shows up there or nowhere.

## `scripts/journal-reset.sh`

Explicit task-boundary script (since base_sha must not auto-restamp): archives
`LOG.md` and the ledger to `.journal/archive/<ts>/`, writes a fresh HEAD, restamps
`base_sha`. Run by me, never automatically.

## Anti-goals — do not build these

- An entry per `PostToolUse`. That's the noise source; the ledger covers it.
- A transcript reducer / post-hoc summarizer. Out of scope.
- Anything MCP-shaped. Files plus shell scripts is the whole system.
- A recap path that runs inside the main session.
- A prompt-type hook doing the writing — it can't write files; don't try.
- A model call in `SessionEnd` — the time budget forbids it.

## Housekeeping

- Decide and justify: gitignore `.journal/` vs commit it. Default to gitignoring the
  ledger and costs.log to avoid diff noise; flag the tradeoff either way.
- Add a `CLAUDE.md` line only if a hook can't enforce something. Prefer hooks over
  instructions — instructions get forgotten mid-run, hooks don't.

## Verification before you call this done

1. Simulate each hook with a synthetic stdin payload; show me the output. Include a
   `PostToolUseFailure` payload and a Stop payload carrying `last_assistant_message`.
2. Prove HEAD is rewritten, not appended, across three consecutive flushes.
3. Edit a file outside the journal's knowledge, then run `recap.sh --full` and
   confirm it appears in the unclaimed-changes list.
4. Kill a session with Ctrl+C; confirm the SessionEnd stamp landed in the ledger and
   that ledger + git diff reconstruct usable state (no Stop flush will have run —
   that's expected).
5. Prove the gate: a Stop firing with <10 ledger lines since last flush must produce
   zero model invocations (show the wrapper exiting before any `claude -p`).
6. Report actual token cost of one gated-through `Stop` invocation, read from
   `costs.log` (which the wrapper fills from `--output-format json`), not estimated.

## Report these two explicitly when you hand off

**1. Is HEAD genuinely a full rewrite?** Show the file contents after three
consecutive flushes, and show the code path (mktemp + atomic `mv`) that makes
appending to HEAD impossible rather than merely discouraged.

**2. What does one `Stop` invocation actually cost?** Measured input tokens from the
JSON output, not an estimate. If it exceeds a few thousand, the writer is reading
something it shouldn't — trace and report exactly what was on its stdin. Also
confirm every headless call in the codebase carries the `disableAllHooks` guard
(grep for `claude -p` and show each call site).

## Deliverables

Skill/scripts directory + hook config (`settings.json` fragment or direct edit —
match how this machine's config is organized) + `scripts/recap.sh` +
`scripts/journal-reset.sh` + ledger and writer scripts, plus a short README covering
the migration from my existing journal.

Ask me before making any decision that would discard existing content or require a
change to how I invoke Claude Code.

---

## Appendix: v1 → v2 changelog

| v1 said | v2 says | Why |
|---|---|---|
| Stop is a prompt-type hook that "runs Haiku and rewrites HEAD" | Stop is a command hook wrapping `claude -p --model haiku`; the script does all file writes | Prompt hooks are evaluation-only; they cannot write files |
| "SessionEnd doesn't fire on Ctrl+C… make Stop carry the final flush" | SessionEnd DOES fire on Ctrl+C (mechanical stamp there); Stop does NOT fire on interrupts at all | Both halves of the v1 claim were backwards per current docs |
| Writer input: "last assistant message + ledger tail" (extraction unspecified) | `last_assistant_message` comes directly from Stop's stdin JSON; transcript never touched | Removes the only reason the wrapper might have opened the transcript |
| `PostToolUse` ledger = "complete coverage" | `PostToolUse` + `PostToolUseFailure`, with an ok/fail column | PostToolUse fires on success only |
| Emission restraint enforced by prompt wording | Mechanical gate in the wrapper: <10 ledger lines since last flush → no model call (PreCompact `--force` bypasses) | Structural enforcement beats prompt-based; most Stop firings become free |
| "regenerate the whole file, or write HEAD to its own file" | HEAD.md is its own file, written via mktemp + atomic mv | Makes append structurally impossible; Tier 0 = `cat` |
| SessionStart stamps base_sha every start | Stamp only if absent, only on `startup`/`clear` matchers; `journal-reset.sh` for task boundaries | Restamping on resume moves the diff anchor and silently guts the unclaimed-changes backstop |
| (absent) | Hard invariant: every headless call passes `--settings '{"disableAllHooks": true}'` | Headless sessions load project hooks → the system would journal itself recursively |
