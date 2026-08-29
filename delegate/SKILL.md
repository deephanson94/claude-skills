---
name: delegate
description: Delegate an implementation task to a cheaper worker CLI (agy/Gemini or opencode), then verify and review the result yourself. Use when the user asks to delegate, hand off, or offload coding work, or says "/delegate". Plans the work, runs the worker, gates on tests you run yourself, and reviews the diff.
---

# delegate

You are the senior engineer. A worker CLI writes the code; you plan it, gate it, and review it.
You never trust the worker's self-report.

## Backends

| backend | strengths | notes |
|---|---|---|
| `agy` | Gemini 3.1 Pro, spawns parallel subagents | shell limited to the allowlist in `~/.gemini/antigravity-cli/settings.json`; returns `status:ERROR` on a permission denial even when its code is correct |
| `opencode` | free models (`muse-spark-1.2-contributor-free`), self-verifies | `--auto` approves everything — it will `pip install` system-wide if left unsandboxed |
| `claude` | escape hatch for work the others fail | costs the quota you are trying to save; use last |

Default to `opencode` for mechanical work, `agy` when the task needs fan-out.

## Two modes — pick one before you start

Only Claude's tokens are worth optimising; the worker's own spend is free. Reviewing a
finished diff costs a small fraction of writing the same code, and the *driving* — writing
the plan, polling, re-reading the tree between rounds — sits between the two. So the only
real question is how much of the driving Claude does.

| mode | Claude does | use when |
|---|---|---|
| **driven** | the whole loop below, polling included | the user is away, or you expect the retry path to run |
| **hand-off** | writes `plan.md`, then stops. The user launches the worker and watches it. Claude comes back for steps 4 and 5. | the user is at the keyboard |

Hand-off drops the polling and the between-round tree re-reads, which is most of the
driving overhead. It does not *remove* the retry path — it moves it to the user, who now
owns the reset-and-fresh-session dance by hand. That makes it the wrong choice for a task
you expect to need a round 2.

**Steps 4 and 5 are unconditional in both modes.** They are where the value is. Skipping
the plan is a real trade; skipping the gate or the review is not.

## Layout — get this right or the retry path eats itself

```
runs/<task>/
├── repo/        the work tree. ONLY worker changes live here.
├── plan.md      outside repo/ - the retry reset would delete it
├── out/r1/      one out-dir PER ROUND - never reuse one
│   └── result.json, raw.json, stderr.log
├── out/r2/      round 2 writes here, so r1's result can never be mistaken for it
└── launch.log
```

**One out-dir per round is not cosmetic.** `worker.sh` clears `result.json` at startup,
but a poller that starts the instant you background the worker reads round 1's file
before that `rm -f` lands, and gates round 2 against round 1's answer. Observed exactly
that: the gate ran on a stale result while round 2 was still working, and reported the
baseline red as round 2's outcome. Per-round dirs make the stale file unreachable.

`worker.sh` refuses to run if the plan or out-dir is inside the repo. That guard exists
because the retry reset (`git checkout . && git clean -fd`) previously deleted the plan
and the session id it was about to reuse.

## Loop

**1. Scope and isolate.**
Clone or copy into `runs/<task>/repo`, never the user's main tree. The baseline must be
committed so the diff shows only worker changes. If the repo has git-ignored dependencies
(`node_modules`, `.venv`), a fresh worktree will not have them — symlink or copy them in,
or the worker's verify fails and `--auto` will install them globally to "fix" it.

**2. Write `plan.md` beside the repo, not in it.**
A plan the worker cannot misread:
- exact files it may create or edit, and an explicit "do not touch anything else"
- the function signature
- numbered semantics covering every edge case, not prose
- a worked-examples table
- the verify command, and "iterate until green"
- a changed-line budget (default 300; smaller is better)

Vague plans are the main failure mode. Fan-out amplifies vagueness.

**3. Run the worker. Always backgrounded.**

Scripts live beside this file, not in the project you are working on:
```sh
SK=~/.claude/skills/delegate/scripts   # this skill's own directory
```
```sh
N=1   # round number; round 2 uses out/r2, and so on
nohup bash "$SK/worker.sh" <backend> <run>/plan.md <run>/repo <run>/out/r$N \
  > <run>/launch.log 2>&1 < /dev/null &
```
Implementation turns routinely exceed the 10-minute Bash cap. Poll for
`<run>/out/r$N/result.json` — and never poll a directory a previous round wrote to.
`< /dev/null` is required — opencode blocks forever on a tty.

To watch it work, open a read-only pane right after the `nohup`:
```sh
tmux split-window -d -v -l 15 \
  "bash $SK/watch.sh $PWD/<run> <backend>; read -r -t 600 _"
```
Absolute paths for both the script and the run dir: a new pane starts in the tmux
*session's* cwd, not yours. The trailing
`read` keeps the pane alive after the viewer exits — `remain-on-exit` is off by default,
so otherwise the pane vanishes with the `done:` line still on it.
`-d` keeps focus. It exits on its own when `result.json` appears. It is strictly
read-only and has no path back to the worker. **Watching is not verifying** — seeing a
worker narrate its way to green feels like evidence and is not. Step 4 still runs.

opencode streams real tool calls, file paths and exit codes. agy does not — its
`stream-json` emits only a step counter — so for agy the viewer polls `git status`
instead. If you want to watch, prefer opencode.

A watchdog kills the worker at `WORKER_TIMEOUT_SECS` (default 1200) and writes
`status:TIMEOUT`; a worker that dies without a result leaves `status:DIED`. Either way
`result.json` always appears, so the poll always terminates.

**3b. Check containment before you trust anything.**
`out/r$N/result.json` carries `repo_changed`, counted against `base_sha`. If it is `0` while the
worker reports success, the worker wrote somewhere else.

Observed: agy resolved to a *persisted project* whose workspace was the fixture, did the
whole job there — including really running `npm test` — and reported that tree's green
as if it were ours, while the run repo sat empty. The output was real; the tree was
wrong. That is the threat model: **not a worker that invents results, but one that
produces genuine results somewhere you did not ask.** `--new-project` closes that path
for agy; the check stays because the next backend will find another one.

Also confirm the source you cloned from is still clean, and never hand a worker a
symlink that points outside the run dir — `npm install`/`prune` writes straight through
it.

**4. Gate on tests YOU run.**
Run the verify command yourself in `<run>/repo`. Not optional, not delegable.
Ignore `result.json`'s `status` when deciding — it has reported `ERROR` on correct code
and `SUCCESS` on unverified code. The test run is the truth.

Red → go to step 3 with a **reset tree and a fresh session**:
```sh
BASE=$(jq -r .base_sha <run>/out/r$N/result.json)
(cd <run>/repo && git reset --hard "$BASE" && git clean -fd)
tail -n 80 <failure output> >> <run>/plan.md    # cap it; the plan travels as one argv string
N=$((N+1))                                      # NEW out-dir, or you will read the old result
```
Verified against the worst case: a round-1 worker that **committed** its wrong answer.
`git status` showed 0 lines and plain `git diff` showed 0 lines — "nothing to review" —
while `git diff $BASE` showed 2 files and the tests were red. `git reset --hard $BASE`
restored the exact baseline; round 2 then went 14/14.
`git checkout . && git clean -fd` is **not** a reset and must not be used here. It
restores from the index, so anything the worker staged survives; and if you ran step 5's
`git add -N .` to look at the failing diff, `clean -fd` now considers the worker's new
files tracked and keeps them. If the worker committed, neither command touches anything.
Always reset to the recorded `base_sha`.
Do **not** reset the tree and then resume the worker's session. The resumed session
remembers files the reset just deleted and will make incremental edits against a tree
that no longer has them. Reset means fresh session; the full plan is re-sent anyway.
Max 2 rounds, then stop and hand it to the user.

**5. Review the diff — including files that do not exist yet.**
```sh
BASE=$(jq -r .base_sha <run>/out/r$N/result.json)
(cd <run>/repo && git add -N . && git diff "$BASE")
```
Diff against `base_sha`, not the working tree. A worker that commits its work leaves
`git status` empty and `git diff` empty — you would see "nothing to review" next to green
tests and ship it unread.
**Plain `git diff` never shows untracked files.** A worker's main deliverable is usually a
NEW file, so an unstaged diff shows you the one-line export edit and hides the 60-line
implementation. `git add -N .` (intent-to-add) makes new files appear in the diff.

Review against the user's original request and the tests, *not* against your own `plan.md`.
You wrote the plan, so checking code against it just confirms your own assumptions and
misses spec-level errors. Observed: three real bugs (non-finite config accepted silently)
sat in code that matched the plan perfectly.

Look for: edge cases the tests miss, scope creep beyond the allowed files, new dependencies,
and anything the worker did that it did not mention. Probe edges the tests do not cover —
NaN, Infinity, empty, negative, backwards time.

Write findings to `<run>/REVIEW.md`. Report test counts, diff size, and what you'd change.

**6. Record what produced the diff.**
`runs/` is scratch, so the answer to "which agent wrote this?" has to leave it. `result.json`
already carries `backend`, `model`, `base_sha` and `session_id`:
```sh
jq -r '"Delegated-To: \(.model) (\(.backend))\nDelegated-Base: \(.base_sha)"' <run>/out/r$N/result.json
# Delegated-To: gemini-3.1-pro-high (agy)
# Delegated-Base: 4f2a1c…
```
Put those in the commit trailer or the PR body — somewhere that outlives the run dir. Two
agents committing under the same git identity are otherwise indistinguishable downstream,
and prose style is not attribution: a worker's summary can read exactly like your own.
Without this line, "how well does delegation actually work?" stops being answerable the
moment you delete `runs/`.

## Rules

- Never run the backend CLI by hand, in either mode — always go through `worker.sh`. A
  hand-run worker writes no `result.json`, so the containment check and every `base_sha`
  reset have nothing to read; it has no watchdog, so a hung run never terminates; and it
  gets none of the sandbox env vars, so `--auto` installs globally. `watch.sh` tails
  `out/raw.json`, so it cannot watch a hand-run worker either — the live view *requires*
  `worker.sh`.
- Never let the worker touch test files or config. Check the diff for it.
  One sanctioned exception, if all four hold: the repo has a mutation harness; `plan.md`
  names one mutant per guard **up front**; the worker may only **add** test files, never
  modify an existing test, the harness config, or the mutation config; and you run the
  mutation suite yourself in step 4. That converts "did it write real tests?" from a
  judgement into a command. Naming the mutants afterwards does not count — the worker will
  pick mutants its own tests already catch. And mutation proves the tests *bite*, not that
  the spec is right: step 5 still reviews against the user's request.
- Never accept a worker's "all tests pass" without running them.
- Watch for side effects outside the repo — package installs, global config writes.
- Report what you delegated and what you verified. Do not present a worker's output as your own review.
