# Task: build `qqna` — an out-of-band Q&A console for long-horizon Claude Code runs

**Spec v3.** Supersedes v2 entirely. The design changed shape after measurement: the
expensive "write-time judgment layer" (a Haiku writer emitting journal entries) is
**deleted**, because the session transcript on disk turns out to be a near-live,
queryable record already. What remains is a cheap interactive console plus one anchor
file — and two optional extras that should stay unbuilt unless they earn their way in.
See the changelog at the bottom for what was dropped and why.

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

**Build these two. Nothing else is required for the system to work.**

**1. `qqna` — the console.** A shell script on `$PATH` that resolves the live
transcript, filters it to a seed, and launches an interactive read-only Sonnet session
in a scratch directory to answer my questions. Takes **no arguments**.

**2. `.journal/base_sha` — the diff anchor.** One file, one line, written once per
task. Enables the single most valuable output in the system: **files that changed but
were never discussed.**

That is the whole core: one script and one anchor file. The transcript supplies
everything else.

There is **no model-written journal**, no `LOG.md`, no Haiku writer, no emission gate.

**Two further features are specified below under "Supplementary" — a status note and a
tool-call ledger. Do not build them as part of this task.** Each has an explicit
trigger condition; build one only if its condition is actually met in practice, and
only after the core is working. If in doubt, leave them unbuilt — the core does not
depend on either.

---

## `qqna` — the console

### Discovery: no arguments, ever

`qqna` resolves its own target from cwd:

1. Encode `$PWD` → project dir name (`/` and `_` → `-`).
2. In `~/.claude/projects/<encoded>/`, pick the `.jsonl` with the newest mtime.
   Because the transcript updates continuously **[verified]**, newest-mtime reliably
   means "most recently active session in this repo."
3. **Fallback — required, not optional.** If the encoded directory does not exist, or
   contains no `.jsonl`, do **not** fail. Scan every `~/.claude/projects/*/` for the
   newest transcript across all repos, use it, and say loudly which repo it resolved to.
   **Exclude qqna's own scratch project directories from this scan.** qqna runs an
   interactive session in a scratch dir, which creates its own
   `~/.claude/projects/<encoded-scratch>/` entry — and that entry is, by construction,
   the newest transcript on the system. Without an exclusion the fallback resolves to
   the previous qqna session instead of the work session. Use a fixed, recognisable
   scratch path prefix and filter it out explicitly.
   This is the common case when I press the tmux binding from a pane that isn't
   terminal 1 (see tmux section) — the tool should still do the useful thing.
4. Print which session it picked, **which repo it belongs to**, its tool-call count, and
   **how old the last entry is**. The repo name is what makes a wrong pick instantly
   visible, so print it every time, not just on fallback.
5. Accept an optional explicit path argument (`qqna /path/to/repo`) as the manual
   override. Never require it.

**Optional hardening (build only if step 2 proves ambiguous in practice):** a
`SessionStart` hook writes `session_id` + `transcript_path` **[verified: both are in
its stdin]** to `.journal/panes/$TMUX_PANE.json` — hooks inherit `$TMUX_PANE`
**[verified]**. This gives exact identification when two sessions share one repo. Do
not build this in v1; note it in the README as the upgrade path.

### The seed filter

Read the transcript JSONL and emit a seed that **keeps verbatim**:

- every assistant **text** block
- every user **text** turn
- every tool call's **name and target** (not its input body — a `Write` call's input is
  the whole file)
- every error / failure

and **stubs or drops** everything else. **[verified — measured on a real 1.35MB
transcript]** the bulk is not where v2 assumed:

| Block | Share of file | Action |
|---|---|---|
| `user/image` (pasted screenshots, base64) | **44.1%** | **stub** — `<image, 290KB>` |
| `assistant/thinking` | **10.0%** | **drop entirely** — see below, it is empty |
| `attachment` (file contents attached to turns) | 6.5% | stub with path + size |
| `assistant/tool_use` (inputs incl. full file bodies) | 4.5% | keep name + target only |
| `user/tool_result` | 1.0% | stub — `<result: 4.2KB, ok>` |
| `assistant/text` | **2.2%** | **keep verbatim** |
| `user/text` | 5.6% | **keep verbatim** |

**A naive "keep every user turn verbatim" rule is a bug**: on the measured session it
would have carried 595KB of base64 screenshots into the seed, making it ~6.5× larger
than a correct filter produces (704KB vs 109KB). Images and attachments live in *user*
messages, not tool results, so the v2 rule missed them.

Nothing is summarized. Nothing is compressed by a model. The only lossy step is
omitting tool output, and that omission is **recoverable**: qqna has file access, so if
I ask something that needs `render.py`, it reads `render.py` off disk. That is why this
gets near-full accuracy at a fraction of the bytes.

**Do not compress the seed with a model.** It adds a lossy step to solve a cents-scale
problem.

### What the record does NOT contain — design against this

**[verified — measured] Extended-thinking blocks are present but empty.** On the
measured session all 23 `thinking` blocks carried zero text while occupying 10% of the
file: current models default to `display: "omitted"`, so the raw reasoning is never
written to the transcript. Two consequences:

1. **Drop thinking blocks from the seed.** They are pure overhead — signatures and
   metadata with no content.
2. **The reasoning behind a decision is recoverable only if the model said it out
   loud.** If a choice was made silently in thinking and the visible text merely states
   the conclusion, that "why" is *gone* — not compressed, not summarized, absent.

This is the single most important honesty constraint in the system. **State it as a
hard rule in qqna's prompt:**

> The record contains what was said and done, not what was thought. If it does not
> state why a choice was made, say "the record doesn't say" and cite what it does show.
> Never infer or reconstruct motive.

Without this rule qqna will fluently invent rationales, which is strictly worse than
admitting ignorance — a confident wrong "why" is exactly what would make me approve
something I should have questioned.

**Investigate before building:** check whether this Claude Code version can be
configured to persist summarized thinking. If it can, enabling it materially increases
what qqna can answer, and is worth doing. Report what you find either way.

### Subagents — a real blind spot

**[verified]** Subagent work is written to **separate transcripts** at
`~/.claude/projects/<encoded>/<session-id>/subagents/agent-*.jsonl`; the parent
transcript contained **zero** sidechain rows. From the main transcript alone, an hour
of delegated work looks like "spawned agent → received report."

For a long-horizon autonomous run this is the difference between seeing the work and
seeing a receipt — and files edited by a subagent surface in unclaimed-changes with
nothing in the seed to explain them.

**Required:** enumerate the `subagents/` directory for the resolved session, apply the
same filter to each agent transcript, and either fold them into the seed (labelled by
agent) or list them in the seed header with their paths so qqna can read one on demand.
At minimum the seed must say how many subagent transcripts exist and where — never
silently omit them.

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
- **Read-only — and Bash is the hole, not the edit tools.** Denying `Write` / `Edit` /
  `NotebookEdit` is necessary and *not sufficient*: a shell is a write tool. Bash must
  be restricted to an **allowlist** of the specific helper commands (`qqna-delta`,
  `qqna-unclaimed`, `git log|diff|status|show`) rather than merely deny-listing edits.
  This matters because the seed contains untrusted content the main session ingested
  (web pages, dependency files, error text); qqna is an agent reading attacker-
  influenceable text with a shell attached. Treat it as such. Verify by attempting a
  write from inside qqna and showing the refusal.

### Incremental refresh — do not relaunch

The transcript is append-only, so refreshing must cost only the *new* work.

- Record a byte offset per session in `.journal/qqna/<session-id>.offset`.
  **Guard the offset**: (a) only ever advance to the last **complete** line — the file
  is being appended to live, so the tail can be a torn, unparseable fragment; (b) if the
  file has *shrunk* below the stored offset, or the stored session id no longer matches,
  discard the offset and re-seed rather than reading garbage.
- Ship a helper `qqna-delta` that prints filtered activity from the stored offset to
  EOF, then advances the offset.
- Tell qqna in its seed header: *"To see what has happened since, run `qqna-delta`."*

Then I keep **one qqna pane open for the whole run** and refresh in place. Refresh cost
scales with work-since-last-check-in, not with total session size — the difference
grows as the run gets longer.

### Print unprompted, before the first prompt

These are the three things I would otherwise always waste questions on:

1. **Freshness** — session id, tool-call count, age of last transcript entry.
2. **Unclaimed changes** — changed paths minus every path mentioned anywhere in the
   seed. Ship this as `qqna-unclaimed`.

   **[verified] `git diff --name-only` alone is wrong — it omits untracked files.** A
   brand-new file the agent created and never mentioned is both the most likely thing
   to be missed and the most important thing to catch, and the naive command silently
   drops it. Use the union:

   ```sh
   { git diff --name-only "$(cat .journal/base_sha)"
     git ls-files --others --exclude-standard; } | sort -u
   ```

   Normalise paths before subtracting: the seed may refer to a file as an absolute
   path, a repo-relative path, or a bare basename. Compare on repo-relative form, and
   when in doubt report the file as unclaimed — a false positive costs me five seconds,
   a false negative is the failure this whole feature exists to prevent.
3. **Failure tail** — recent tool failures. Source these **from the transcript**, which
   records failed calls alongside successful ones. (If the supplementary ledger is ever
   built, read them from there instead — but do not make this output depend on it.)

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
needs. Zero arguments typed, zero tokens spent in terminal 1, and the main session
never learns it happened.

**[verified — measured against the real workflow]** The sequence *start tmux in `$HOME`
→ `cd` into the repo → run `claude` → split* propagates correctly. tmux tracks the
`cd` (`pane_current_path` moved from `/root` to `/home/user/claude-skills`), still
reports it correctly while a long-running foreground process occupies the pane, and the
split inherits it. The mechanism reads **the shell's** cwd, not the claude process's, so
nothing Claude Code does to its own working directory during the session can move it.

**Known limitation — this is why the discovery fallback above is mandatory.** The
binding resolves the cwd of *whichever pane the key was pressed in*. Pressing it from
terminal 1's pane is correct; pressing it from an unrelated pane sitting in `$HOME`
resolves to the wrong place. Handle it by falling back to a global newest-transcript
scan and printing the repo, not by failing.

**[verified] Do not try to pass `#{pane_id}` as a command argument** —
`split-window ... "qqna #{pane_id}"` arrives **empty**; tmux expands formats in `-c`
but not in the shell-command string. If pane-keying is ever needed, resolve it inside
the binding via `run-shell` and verify it actually arrives before relying on it.

---

## Hooks to wire — exactly one

The core needs a **single** hook, and it does one mechanical thing:

- **`SessionStart`** — stamp `git rev-parse HEAD > .journal/base_sha` **only if the file
  is absent**, and only on the `startup` / `clear` matchers. It writes nothing to stdout
  and injects nothing into context.

  A resume must never move the anchor — restamping silently shrinks the
  unclaimed-changes list and guts the backstop. This is why the anchor is stamped by a
  hook rather than by `qqna` itself: it must record where the *session* began, not where
  I happened to first check in.

Also ship `scripts/journal-reset.sh` — restamps `base_sha` and archives the old one, run
by me at real task boundaries, never automatically.

**No `Stop`, no `PreCompact`, no `PostToolUse`, no `SessionEnd` hook.** The first two
existed only to drive the deleted judgment layer; the latter two belong to the
supplementary ledger and are not part of this build.

---

## Supplementary features — do not build unless the trigger fires

Both of these were core in earlier drafts and were demoted deliberately. They are
specified here so the option stays open, **not** as part of this build. Each states the
condition that would justify it. **Absent that condition, leaving it unbuilt is the
correct outcome, not a shortcut** — report it as "not needed" rather than building it
to be thorough.

### S1. Status note (`.journal/HEAD.md`)

**What it would be:** a few lines — goal, blocked, next, review — printed by the
`SessionStart` hook so a new session and I both start oriented at zero token cost.

**Why it is not core:** v2 had a cheap model keeping it current. That writer is deleted,
so nothing would keep it accurate. A stale note injected into context at every session
start is *worse than no note* — it is a confident, wrong orientation that both I and the
agent will act on. An unmaintained status file is a liability, not a neutral extra.

**Build only if** I find myself repeatedly starting fresh sessions that need
cross-session context, and `qqna` is too heavy for that particular need.

**If built, build it in this shape — do not build the hand-maintained version:**

- **One hand-written line: `goal:`.** I write it once when I kick off a task. It does
  not rot, because the goal is the goal for the whole run.
- **Everything else generated mechanically** at `SessionStart` from the previous
  session's transcript tail: its last assistant text block (truncated) plus the last
  few tool calls. Zero tokens, no writer, cannot go stale — it is a direct quote of what
  actually happened.

Keep any write to it atomic (`mktemp` + `mv`) so it can never be appended to.

### S2. Tool-call ledger (`.journal/ledger.tsv`)

**What it would be:** `PostToolUse` + `PostToolUseFailure` hooks appending
`ts | tool | path | ok|fail` per tool call, plus a `SessionEnd` line. Zero tokens.

**Why it is not core:** the transcript already records every tool call and its outcome,
so this is a second copy of data I already have — and two sources of truth that can
disagree is a defect to design out, not a feature to add.

**Build only if** one of these is true — verify, do not assume:

1. **`PostToolUse` hooks fire for tool calls made inside subagents.** If they do, the
   ledger becomes the only *complete, single-file* index of a delegating run, which is
   real value given that subagent work otherwise hides in separate transcripts. **This
   is the deciding question — answer it explicitly and report the answer either way.**
2. I start needing a durable record that outlives transcript retention (transcripts are
   cleaned up on a retention period; a file in the repo is not).

**If built:** keep it minimal, fast, and non-blocking (single-line appends under
PIPE_BUF are atomic; no locking). `qqna` must continue to treat the **transcript** as
the source of truth and the ledger only as a cross-check — do not make any core output
depend on it.

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
- **Building the supplementary features "while we're here."** Their triggers are
  conditions to be checked, not boxes to tick.
- **qqna speculating about intent.** If the record doesn't say why, the answer is "the
  record doesn't say." A plausible invented rationale is the most dangerous output this
  system can produce.

---

## Cost model — state this honestly in the README

- **Glance**: free (`git log`, the ledger or status note if ever built — no model).
- **qqna cold seed**: one Sonnet load. At the measured range, roughly $0.10–$0.80
  depending on session size.
- **Follow-ups are cheap only inside the cache window.** Every turn resends the whole
  context; it is discounted only on a prompt-cache hit. Questions asked back-to-back are
  a fraction of the seed cost. A question asked after a long idle gap is **not** — it
  re-reads the seed *plus* all accumulated Q&A, which is strictly more than a fresh
  seed would cost.
  **Measure the effective cache TTL before recommending a pane lifetime**, and set the
  README's advice by the result:
  - long TTL (~1hr): one pane for the whole run is fine, refresh in place via `qqna-delta`.
  - short TTL (~5min): **one pane per check-in, closed afterwards.** A long-lived pane
    silently gets *more* expensive as its history grows.
  Do not assert either without measuring — this determines whether the headline
  workflow is "leave it open" or "fire it per check-in".
- **The verdict is not free.** Returning to terminal 1 and typing my decision lands in
  a session whose cache has expired — one full uncached re-read at top-tier rates. qqna
  does not eliminate that; it changes *when and how often* I pay it. The real wins:
  check-ins ending in "all good, carry on" become **entirely free**, and a
  multi-question check-in collapses from N cold reads to **one**. This is why batching
  the verdict into a single message matters.
- **Decision rule worth documenting:** if qqna reveals a large pivot, killing terminal 1
  and starting a fresh session seeded from a short hand-written brief is often cheaper
  than resuming the old one.
- **Pricing note:** Sonnet 5's introductory input rate ($2/M) expires **2026-08-31**,
  after which it is $3/M — recompute any figures in the README after that date. I am on
  Bedrock, so absolute figures differ from first-party rates; the ratios hold.

---

## Verification before you call this done

1. **Discovery with zero args:** from the project dir, `qqna` finds the correct live
   session. Show the resolved path and the encoding step.
1b. **Discovery fallback:** run `qqna` from `$HOME` (a directory with no matching
   project dir) and confirm it still resolves to the most recently active session,
   names the repo it picked, and does not error.
2. **Liveness:** while a session is mid-turn, show that the seed contains work from the
   current turn, and report the measured age of the last transcript entry. (Expect
   seconds. If you measure turn-scale lag, say so — that contradicts my measurement and
   changes the design's value.)
3. **Seed fidelity:** show raw bytes → seed bytes → seed tokens for one real session,
   and confirm assistant messages survive **verbatim** (diff a sample) while tool result
   bodies are stubbed.
4. **Unclaimed changes:** edit a file the session never touched, then confirm it appears
   in `qqna-unclaimed` output.
5. **Read-only:** attempt a write from inside qqna and show it being refused —
   including via **Bash**, not just via `Write`/`Edit`.
5b. **Untracked files:** create a new file the session never mentioned and confirm it
   appears in `qqna-unclaimed` (this fails with a bare `git diff --name-only`).
5c. **Seed hygiene:** on a transcript containing a pasted image, show the image is
   stubbed and report seed size with and without the fix.
5d. **Subagents:** run a session that spawns a subagent and show whether qqna's seed
   accounts for the subagent's work. **Separately, answer the S2 trigger question:** do
   `PostToolUse` hooks fire for tool calls made inside a subagent? Report the answer —
   it decides whether the ledger is ever worth building.
5e. **Fallback isolation:** run qqna twice from a non-project directory and confirm the
   second run resolves to the work session, **not** to the first qqna session.
6. **No contamination:** confirm qqna's own transcript does **not** land in the project's
   transcript directory, and that running qqna leaves no trace in the work repo.
7. **Incremental refresh:** run `qqna-delta` twice; show the second call returns only
   new activity and that the offset advanced.
8. **tmux binding:** `prefix + q` opens a pane in the correct cwd and qqna self-resolves.
9. **Interrupt survival:** Ctrl+C the main session and confirm qqna still reconstructs
   usable state from the transcript plus `git diff`.

## Report these explicitly when you hand off

1. **Measured seed size and cost** for one real session — raw bytes, seed bytes, seed
   tokens, and the actual cost of the cold load. Not an estimate.
2. **Proof qqna cannot write** — show the deny configuration and the refused attempt.
3. **Proof qqna doesn't pollute discovery** — the scratch-dir isolation, demonstrated.
4. **Every `claude` invocation in the codebase**, with confirmation each carries
   `--settings '{"disableAllHooks": true}'`.

## Deliverables

**Core (build this):** `qqna` + `qqna-delta` + `qqna-unclaimed` +
`scripts/journal-reset.sh`, a `.tmux.conf` fragment, a `settings.json` fragment for the
single `SessionStart` base_sha hook (match how this machine's config is organized), and
a README covering the migration from my existing journal and the cost model above.

**Supplementary (do not build):** the README should note S1 and S2 exist as documented
options with their trigger conditions, so future-me knows they were considered and
deliberately deferred.

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
| Kept: ledger, HEAD, base_sha, unclaimed-changes | **base_sha + unclaimed-changes kept as core; ledger and HEAD demoted to supplementary** | Only the anchor is load-bearing; the other two duplicate the transcript or rot without a writer (see Supplementary) |

### v3 adversarial pass (findings from trying to break v3)

| Finding | Severity | Resolution |
|---|---|---|
| Reasoning is absent — thinking blocks are 10% of bytes and **100% empty** (`display: omitted`) | **critical** | qqna must never infer motive; drop thinking blocks from the seed; investigate persisting summarized thinking |
| Seed filter kept pasted images verbatim — **44% of the measured transcript** was 2 screenshots | **critical** | stub images and attachments; correct filter yields 109KB vs 704KB naive |
| `git diff --name-only` **omits untracked files** — the backstop missed brand-new files | **critical** | union with `git ls-files --others --exclude-standard` |
| Global discovery fallback would resolve to **qqna's own scratch session** (newest by construction) | **critical** | exclude the scratch path prefix from the scan |
| Subagent work lives in **separate transcripts**; parent had zero sidechain rows | serious | enumerate and fold in `subagents/*.jsonl`, or list them for on-demand reading |
| "Read-only" enforced by denying Write/Edit — **Bash is the hole** | serious | allowlist specific helper commands; qqna is an agent reading untrusted text with a shell |
| Long-lived pane may cost *more* than re-seeding once cache TTL expires | serious | measure TTL; pane lifetime advice follows from it |
| Nothing keeps `HEAD.md` fresh after v3 deleted the writer | moderate | propose mechanical alternative: inject previous transcript tail + ledger tail |
| Byte offsets break on torn tail / file shrink | moderate | advance only to last complete line; re-seed on shrink or id mismatch |
| Ledger is largely redundant with the transcript | moderate | verify whether PostToolUse fires in subagents; that decides if it is load-bearing |

### v1 → v2 (corrections that still stand)

| v1 | Correction |
|---|---|
| `Stop` as a prompt-type hook writing files | Prompt hooks are evaluation-only; file writes need command hooks |
| "SessionEnd doesn't fire on Ctrl+C; Stop carries the final flush" | Both halves backwards: SessionEnd **does** fire on Ctrl+C; Stop does **not** fire on interrupts |
| `PostToolUse` gives complete coverage | Success-only; `PostToolUseFailure` is a separate event |
| SessionStart stamps `base_sha` every start | Stamp only if absent, only on `startup`/`clear` — restamping guts the unclaimed-changes backstop |
| (absent) | Every subordinate `claude` call needs `--settings '{"disableAllHooks": true}'` |
