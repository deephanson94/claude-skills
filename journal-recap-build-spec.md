# Task: build `qqna` — an out-of-band Q&A console for long-horizon Claude Code runs

**Spec v3.** Supersedes v2 entirely. The design changed shape after measurement: the
expensive "write-time judgment layer" (a Haiku writer emitting journal entries) is
**deleted**, because the session transcript on disk turns out to be a near-live,
queryable record already. What remains is a cheap interactive console plus three
mechanical anchors. See the changelog at the bottom for what was dropped and why.

Everything marked **[verified]** was checked against live Claude Code docs or measured
empirically on 2026-08-18 against Claude Code 2.1.234. Re-confirm against the version
installed on this machine before coding, but do not re-derive from scratch.

---

## Context

I run long-horizon autonomous tasks in Claude Code (~1hr) on a top-tier model. When I
check in — mid-run or ~30min after completion — I'm cold: I don't know what was done,
what needs review, or what's next. Asking the running session for a recap forces a
full-conversation re-read at top-tier rates (prompt cache long expired, fully uncached).

**The fix is a second terminal, not a smarter session.** The live session's transcript
is already on disk and already readable while the session runs. A cheap model can read
a filtered version of it and answer my questions, while the main session keeps working,
untouched and unaware.

**Governing principle: the main session is write-only from my side.** I never ask it
what it did. I ask `qqna`, decide, then send the main session exactly one message: my
verdict.

The workflow, concretely:

```
# terminal 2, any time — session in terminal 1 keeps working, untouched
$ qqna
  seeded from live session 27f1a096 · 703 tool calls · last activity 4s ago

  unclaimed changes (touched, never discussed):  src/render.py, tests/test_dx4.py

  you>  where are we, and what's still unverified?
  you>  why did it pick the stacked chart over the 3-line overlay?
  you>  is the dx4 reconcile actually passing, or did it just say so?
```

Then I go back to terminal 1 and type one message: my verdict and next TODOs.

---

## Current state — inspect before building

I have an existing unstructured journal on this machine (append-only prose, no schema)
and existing hooks and skills. Before writing anything:

1. Read my `CLAUDE.md` and any existing `.claude/` config, hooks, and skills — both
   user-level (`~/.claude/`) and project-level.
2. Find the existing journal file and read its format.
3. Report what you found and how you plan to migrate it. **Do not discard existing
   journal content** — migrate or archive it.

Note that v3 needs far less of a journal than v2 did. Much of the existing prose
journal is probably now redundant with the transcript. Propose what to keep; don't
delete anything without asking.

---

## Verify before you code

Run `claude --version` and check the current hooks + CLI reference. These are the
facts this design rests on:

| Fact | Status |
|---|---|
| Transcripts live at `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl` | **[verified]** |
| cwd encoding: `/` and `_` both become `-` (`/home/u/my_repo` → `-home-u-my-repo`) | **[verified]** |
| Transcript is appended **per message**, asynchronously — an external reader sees mid-turn work within seconds, NOT one turn behind | **[verified — measured]** |
| Docs caveat: writes are async and "may not yet include the current turn's most recent messages" — near-live, not guaranteed-current | **[verified]** |
| `SessionStart` hook stdin includes both `session_id` and `transcript_path` | **[verified]** |
| Hook subprocesses inherit the launching shell's env, including `$TMUX_PANE` | **[verified]** |
| Claude Code sets `CLAUDE_PROJECT_DIR` for hooks; there is no documented `CLAUDE_SESSION_ID` | **[verified]** |
| `PostToolUse` fires on **success only**; failures fire `PostToolUseFailure` | **[verified]** |
| `SessionEnd` **does** fire on Ctrl+C (exit 143); its hooks share a ~1.5s budget (raisable to 60s max) | **[verified]** |
| `Stop` does **not** fire on user interrupts (Esc/Ctrl+C) — only natural turn ends | **[verified]** |
| Prompt-type hooks are evaluation-only and **cannot write files** | **[verified]** |
| No env var suppresses hooks in headless/subordinate sessions; use `--settings '{"disableAllHooks": true}'` | **[verified]** |
| Resuming a **live** session without `--fork-session` interleaves both processes' writes into one transcript | **[verified]** |
| tmux expands `#{...}` formats in `split-window -c` but **NOT** in the shell-command argument | **[verified — measured]** |
| Sonnet 5: 1M context, $3/M in ($2/M intro through **2026-08-31**), $15/M out | **[verified]** |
| Haiku 4.5: **200K context** — too small for large seeds | **[verified]** |

If anything disagrees with the docs on this machine, tell me and adapt.

---

## Architecture

Four pieces. Only the first is new work of any size.

**1. `qqna` — the console.** A shell script on `$PATH` that resolves the live
transcript, filters it to a seed, and launches an interactive read-only Sonnet session
in a scratch directory to answer my questions. Takes **no arguments**.

**2. `.journal/ledger.tsv` — the mechanical index.** `PostToolUse` +
`PostToolUseFailure` command hooks append one line per tool call:
`ts | tool | path | ok|fail`. Zero tokens. Survives crashes. Its job is to be
*complete*, including failures the transcript narration may gloss over.

**3. `.journal/HEAD.md` — the zero-token glance.** Four lines: goal, blocked, next,
review. Injected at `SessionStart`. Answers "where are we" without running anything.

**4. `.journal/base_sha` — the diff anchor.** Enables the single most valuable output
in the system: **files that changed but were never discussed.**

There is **no model-written journal**, no `LOG.md`, no Haiku writer, no emission gate.
The transcript replaces all of it.

---

## `qqna` — the console

### Discovery: no arguments, ever

`qqna` resolves its own target from cwd:

1. Encode `$PWD` → project dir name (`/` and `_` → `-`).
2. In `~/.claude/projects/<encoded>/`, pick the `.jsonl` with the newest mtime.
   Because the transcript updates continuously **[verified]**, newest-mtime reliably
   means "most recently active session in this repo."
3. Print which session it picked, its tool-call count, and **how old the last entry
   is**, so I always know how stale I am.

**Optional hardening (build only if step 2 proves ambiguous in practice):** a
`SessionStart` hook writes `session_id` + `transcript_path` **[verified: both are in
its stdin]** to `.journal/panes/$TMUX_PANE.json` — hooks inherit `$TMUX_PANE`
**[verified]**. This gives exact identification when two sessions share one repo. Do
not build this in v1; note it in the README as the upgrade path.

### The seed filter

Read the transcript JSONL and emit a seed that **keeps verbatim**:

- every assistant text message
- every user turn
- every tool call's **name and target** (not its result body)
- every error / failure

and **drops** tool *result bodies* — file contents and command output — replacing each
with a one-line stub (`<result: 4.2KB, ok>`).

Nothing is summarized. Nothing is compressed by a model. The only lossy step is
omitting tool output, and that omission is **recoverable**: qqna has file access, so if
I ask something that needs `render.py`, it reads `render.py` off disk. That is why this
gets near-full accuracy at a fraction of the bytes.

**Do not compress the seed with a model.** It adds a lossy step to solve a cents-scale
problem.

### Sizing expectations — do not assume a fixed ratio

Measured compression on real sessions ranged **10×–63×**. The ratio is *not* a
constant: the filter keeps assistant prose and drops tool output, so a read-heavy
session compresses enormously while a deliberative, talky session barely compresses.

**Estimate seed size as ≈ total assistant prose + user turns**, not raw bytes ÷ a magic
number. A measured example: a 990KB deliberative transcript produced a 97KB seed
(~28k tokens, 10.2×).

Practical consequence: seeds of 200k–400k tokens are normal for long runs. That is fine
on Sonnet's 1M window and leaves ample room for qqna to go read files.

**Model choice is constrained, not free:** use Sonnet. Haiku 4.5's 200K window
**[verified]** cannot hold a large seed. Do not "optimize" qqna onto Haiku.

### Session launch

Launch an **interactive** `claude --model sonnet`:

- **In a scratch directory**, not the project dir — otherwise qqna's own transcript
  lands in the project's transcript folder and corrupts newest-mtime discovery.
- Pass the project path via env (`QQNA_TARGET`) so helper scripts can run git commands
  against the real repo.
- **`--settings '{"disableAllHooks": true}'`** — my user-level hooks
  (`~/.claude/settings.json`) would otherwise fire inside qqna. Required
  **[verified: no env-var alternative exists]**.
- **Read-only.** Deny `Write` / `Edit` / `NotebookEdit` via settings deny rules, and
  restrict Bash to the read-only helpers below. qqna must be structurally incapable of
  modifying the repo. Verify this, don't assert it.

### Incremental refresh — do not relaunch

The transcript is append-only, so refreshing must cost only the *new* work.

- Record a byte offset per session in `.journal/qqna/<session-id>.offset`.
- Ship a helper `qqna-delta` that prints filtered activity from the stored offset to
  EOF, then advances the offset.
- Tell qqna in its seed header: *"To see what has happened since, run `qqna-delta`."*

Then I keep **one qqna pane open for the whole run** and refresh in place. Refresh cost
scales with work-since-last-check-in, not with total session size — the difference
grows as the run gets longer.

### Print unprompted, before the first prompt

These are the three things I would otherwise always waste questions on:

1. **Freshness** — session id, tool-call count, age of last transcript entry.
2. **Unclaimed changes** — `git diff --name-only $(cat .journal/base_sha)` minus every
   path mentioned anywhere in the seed. Ship this as `qqna-unclaimed`.
3. **Failure tail** — recent `fail` rows from `ledger.tsv`.

**#2 is the accuracy backstop and the highest-value output in the whole system.** A
transcript is a self-report and inherits the agent's blind spots; anything it silently
broke shows up here or nowhere.

---

## tmux integration — the trigger must live outside Claude

**Do not build qqna as a skill or slash command.** A skill invocation *is* a user turn
in the main session, which triggers exactly the expensive cold re-read the whole design
exists to avoid. The trigger has to be outside Claude entirely.

Add to `.tmux.conf`:

```tmux
bind-key q split-window -h -c "#{pane_current_path}" 'qqna'
```

`prefix + q` splits a pane that inherits the source pane's cwd — which is all `qqna`
needs. **[verified: `-c "#{pane_current_path}"` correctly propagates the source pane's
cwd.]** Zero arguments typed, zero tokens spent in terminal 1, and the main session
never learns it happened.

**[verified] Do not try to pass `#{pane_id}` as a command argument** —
`split-window ... "qqna #{pane_id}"` arrives **empty**; tmux expands formats in `-c`
but not in the shell-command string. If pane-keying is ever needed, resolve it inside
the binding via `run-shell` and verify it actually arrives before relying on it.

---

## Hooks to wire (reduced)

- **`SessionStart`** — command hook: stdout `HEAD.md` + `git log --oneline -5`. Stdout
  is injected into context so the agent and I both start oriented. Wire for `startup`,
  `resume`, and `compact` matchers (the `compact` firing re-injects HEAD after
  compaction, which is a feature).
  **base_sha rule:** stamp `git rev-parse HEAD > .journal/base_sha` **only if the file
  is absent**, and only on `startup` / `clear`. A resume must never move the anchor —
  restamping silently shrinks the unclaimed-changes list and guts the backstop.
- **`PostToolUse` + `PostToolUseFailure`** — same ledger script, `ok`/`fail` column
  **[verified: PostToolUse is success-only]**. Fast, non-blocking. Single-line appends
  under PIPE_BUF are atomic; no locking.
- **`SessionEnd`** — mechanical stamp only: append `session_end <reason>` to the ledger.
  It fires on Ctrl+C **[verified]**, but its ~1.5s budget rules out anything heavier.

That is the entire hook surface. **No `Stop` hook. No `PreCompact` hook.** Both existed
in v2 solely to drive the deleted judgment layer.

`HEAD.md` is maintained by me (or by the main session as a normal task), not by a
hooked model. If it goes stale, qqna is the ground truth and HEAD is only the glance.
Keep HEAD writes atomic (`mktemp` + `mv`) wherever they happen, so it can never be
appended to.

---

## Anti-goals — do not build these

- **A qqna skill or slash command.** The trigger must be tmux. See above.
- **A model-written journal / write-time summarizer.** Deleted in v3; the transcript
  replaces it.
- **A post-hoc transcript summarizer.** qqna answers questions; it does not produce
  summaries nobody asked for.
- **Anything MCP-shaped.** Scripts plus a tmux binding is the whole system.
- **`--fork-session` or `--resume` against the live session.** It looks like a
  full-fidelity shortcut and is a trap twice over: resuming a live session without
  forking **interleaves both processes' writes into one transcript** and corrupts
  terminal 1 **[verified]**, and even done safely it loads the entire context — the
  exact cold read being avoided.
- **qqna on Haiku.** 200K context cannot hold the seed.
- **A model-compressed seed.** Lossy step, cents-scale problem.
- **Any qqna write path into the repo.**

---

## Cost model — state this honestly in the README

- **Tier 0 (`cat HEAD.md`)**: free.
- **qqna cold seed**: one Sonnet load. At the measured range, roughly $0.10–$0.80
  depending on session size. Each follow-up question inside the open pane is a fraction
  of that.
- **The verdict is not free.** Returning to terminal 1 and typing my decision lands in
  a session whose cache has expired — one full uncached re-read at top-tier rates. qqna
  does not eliminate that; it changes *when and how often* I pay it. The real wins:
  check-ins ending in "all good, carry on" become **entirely free**, and a
  multi-question check-in collapses from N cold reads to **one**. This is why batching
  the verdict into a single message matters.
- **Decision rule worth documenting:** if qqna reveals a large pivot, killing terminal 1
  and starting a fresh session seeded from `HEAD.md` is often cheaper than resuming the
  old one. This is the main reason HEAD survives into v3.
- **Pricing note:** Sonnet 5's introductory input rate ($2/M) expires **2026-08-31**,
  after which it is $3/M — recompute any figures in the README after that date. I am on
  Bedrock, so absolute figures differ from first-party rates; the ratios hold.

---

## Verification before you call this done

1. **Discovery with zero args:** from the project dir, `qqna` finds the correct live
   session. Show the resolved path and the encoding step.
2. **Liveness:** while a session is mid-turn, show that the seed contains work from the
   current turn, and report the measured age of the last transcript entry. (Expect
   seconds. If you measure turn-scale lag, say so — that contradicts my measurement and
   changes the design's value.)
3. **Seed fidelity:** show raw bytes → seed bytes → seed tokens for one real session,
   and confirm assistant messages survive **verbatim** (diff a sample) while tool result
   bodies are stubbed.
4. **Unclaimed changes:** edit a file the session never touched, then confirm it appears
   in `qqna-unclaimed` output.
5. **Read-only:** attempt a write from inside qqna and show it being refused.
6. **No contamination:** confirm qqna's own transcript does **not** land in the project's
   transcript directory, and that running qqna does not add rows to `ledger.tsv`.
7. **Incremental refresh:** run `qqna-delta` twice; show the second call returns only
   new activity and that the offset advanced.
8. **tmux binding:** `prefix + q` opens a pane in the correct cwd and qqna self-resolves.
9. **Interrupt survival:** Ctrl+C the main session; confirm the SessionEnd stamp landed
   in the ledger and that qqna still reconstructs usable state.

## Report these explicitly when you hand off

1. **Measured seed size and cost** for one real session — raw bytes, seed bytes, seed
   tokens, and the actual cost of the cold load. Not an estimate.
2. **Proof qqna cannot write** — show the deny configuration and the refused attempt.
3. **Proof qqna doesn't pollute discovery** — the scratch-dir isolation, demonstrated.
4. **Every `claude` invocation in the codebase**, with confirmation each carries
   `--settings '{"disableAllHooks": true}'`.

## Deliverables

`qqna` + `qqna-delta` + `qqna-unclaimed` + the ledger hook script, a `.tmux.conf`
fragment, a `settings.json` hooks fragment (match how this machine's config is
organized), and a README covering the migration from my existing journal and the cost
model above.

Ask me before making any decision that would discard existing content or require a
change to how I invoke Claude Code.

---

## Appendix: changelog

### v2 → v3 (the design changed shape)

| v2 | v3 | Why |
|---|---|---|
| Haiku writer at `Stop`/`PreCompact` emitting LOG entries + rewriting HEAD | **Deleted entirely** | The transcript is already a near-live queryable record; a model-written journal was re-deriving, lossily, what was already on disk |
| `LOG.md`, `costs.log`, the 10-tool-call emission gate, the writer prompt | **Deleted** | All existed only to serve the deleted judgment layer |
| `Stop` and `PreCompact` hooks | **Deleted** | Nothing left for them to drive |
| `recap.sh --full` (one-shot, non-interactive) | **`qqna` (interactive, incremental)** | Follow-up questions are the whole point; one-shot forces you to guess your questions in advance |
| "Transcript is one turn behind" (assumed) | **Near-live, per-message** [measured] | Removes the design's main stated limit for mid-run check-ins |
| Seed compresses ~80× | **10×–63×, session-dependent** [measured] | Ratio is set by prose-vs-tool-output mix; budget by assistant prose instead |
| (absent) | **Do not build it as a skill** | A skill invocation is a user turn = the cold read being avoided |
| (absent) | **Do not fork/resume the live session** | Interleaved transcript writes corrupt the main session |
| (absent) | **Scratch-dir isolation for qqna** | Otherwise qqna's transcript breaks newest-mtime discovery |
| (absent) | **Incremental delta refresh** | Refresh cost ∝ new work, not total session size |
| Kept: ledger, HEAD, base_sha, unclaimed-changes | **Kept** | The mechanical anchors were always the sound part |

### v1 → v2 (corrections that still stand)

| v1 | Correction |
|---|---|
| `Stop` as a prompt-type hook writing files | Prompt hooks are evaluation-only; file writes need command hooks |
| "SessionEnd doesn't fire on Ctrl+C; Stop carries the final flush" | Both halves backwards: SessionEnd **does** fire on Ctrl+C; Stop does **not** fire on interrupts |
| `PostToolUse` gives complete coverage | Success-only; `PostToolUseFailure` is a separate event |
| SessionStart stamps `base_sha` every start | Stamp only if absent, only on `startup`/`clear` — restamping guts the unclaimed-changes backstop |
| (absent) | Every subordinate `claude` call needs `--settings '{"disableAllHooks": true}'` |
