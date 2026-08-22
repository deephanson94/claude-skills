#!/usr/bin/env bash
# Run one implementation turn on a delegated worker CLI.
#
#   worker.sh <backend> <plan-file> <repo-dir> <out-dir> [session-id]
#
# backend: agy | opencode | claude
# Writes <out-dir>/result.json (normalized) and <out-dir>/raw.json (backend's own output).
# Normalized: {backend, status, session_id, text, error, exit_code}
#
# <plan-file> and <out-dir> MUST live OUTSIDE <repo-dir>. The retry path resets the
# repo with `git checkout . && git clean -fd`, which would otherwise delete the plan
# and the result holding the session id.
#
# Always run backgrounded — implementation turns routinely exceed 10 minutes.
set -uo pipefail

BACKEND="${1:?backend required: agy|opencode|claude}"
PLAN="${2:?plan file required}"
REPO="${3:?repo dir required}"
OUT="${4:?out dir required}"
SESSION="${5:-}"

case "$BACKEND" in agy|opencode|claude) ;; *) echo "unknown backend: $BACKEND" >&2; exit 2 ;; esac

AGY_BIN="${AGY_BIN:-$HOME/.local/bin/agy}"
OC_BIN="${OC_BIN:-$HOME/.opencode/bin/opencode}"
CLAUDE_BIN="${CLAUDE_BIN:-$HOME/.local/bin/claude}"
AGY_MODEL="${AGY_MODEL:-gemini-3.1-pro-high}"
OC_MODEL="${OC_MODEL:-opencode/muse-spark-1.2-contributor-free}"
CLAUDE_MODEL="${CLAUDE_MODEL:-}"
TIMEOUT_SECS="${WORKER_TIMEOUT_SECS:-1200}"
MAX_PLAN_BYTES="${MAX_PLAN_BYTES:-200000}"

[ -f "$PLAN" ] || { echo "plan not found: $PLAN" >&2; exit 2; }
[ -d "$REPO" ] || { echo "repo not found: $REPO" >&2; exit 2; }

# The plan travels as one argv string. ARG_MAX is 1 MiB including the environment,
# and a retry that appends raw test output can grow it without bound.
PLAN_BYTES=$(wc -c < "$PLAN" | tr -d ' ')
if [ "$PLAN_BYTES" -gt "$MAX_PLAN_BYTES" ]; then
  echo "plan is ${PLAN_BYTES}B, over MAX_PLAN_BYTES=${MAX_PLAN_BYTES}. Trim appended output." >&2
  exit 2
fi

# The plan must not live inside the repo, or the retry reset destroys it.
case "$(cd "$(dirname "$PLAN")" && pwd -P)/" in
  "$(cd "$REPO" && pwd -P)"/*) echo "plan must live outside repo: $PLAN" >&2; exit 2 ;;
esac
case "$(mkdir -p "$OUT" && cd "$OUT" && pwd -P)/" in
  "$(cd "$REPO" && pwd -P)"/*) echo "out-dir must live outside repo: $OUT" >&2; exit 2 ;;
esac

RAW="$OUT/raw.json"
RESULT="$OUT/result.json"

# A stale result.json from a previous round makes a poller return instantly with
# last round's answer. Clear both before starting.
rm -f "$RESULT" "$RAW" "$OUT/stderr.log"

# If we die for any reason without writing a result, leave a sentinel so a poller
# waiting on result.json terminates instead of hanging forever.
sentinel() {
  [ -s "$RESULT" ] && return 0
  jq -n --arg b "$BACKEND" --arg s "${1:-DIED}" \
    '{backend:$b, status:$s, session_id:"", text:"", error:"worker exited without a result", exit_code:124}' \
    > "$RESULT" 2>/dev/null
}
trap 'kill ${CHILD:-} ${WATCHDOG:-} 2>/dev/null; [ -n "${CHILD:-}" ] && pkill -P "$CHILD" 2>/dev/null; sentinel DIED' EXIT
trap 'exit 143' TERM HUP INT

# stdin MUST be /dev/null. Without it opencode blocks forever waiting on a tty.
case "$BACKEND" in
  agy)
    set -- "$AGY_BIN" -p "$(cat "$PLAN")" --add-dir "$REPO" --mode accept-edits \
           --model "$AGY_MODEL" --output-format json --print-timeout "${TIMEOUT_SECS}s"
    # --new-project stops agy resolving to a persisted project it has seen before and
    # editing THERE (observed: it worked in fixtures/ratekit/repo, ran the tests there
    # for real, and reported that tree's green as if it were ours).
    # It is mutually exclusive with --conversation: the conversation belongs to the old
    # project. Retry policy is a fresh session, so --new-project wins.
    if [ -n "$SESSION" ]; then set -- "$@" --conversation "$SESSION"; else set -- "$@" --new-project; fi
    ;;
  opencode)
    set -- "$OC_BIN" run --dir "$REPO" --auto --format json -m "$OC_MODEL"
    [ -n "$SESSION" ] && set -- "$@" -s "$SESSION"
    set -- "$@" "$(cat "$PLAN")"          # positional last: -f/-s are array flags and eat it
    ;;
  claude)
    set -- "$CLAUDE_BIN" -p "$(cat "$PLAN")" --output-format json \
           --permission-mode acceptEdits --add-dir "$REPO"
    [ -n "$CLAUDE_MODEL" ] && set -- "$@" --model "$CLAUDE_MODEL"
    [ -n "$SESSION" ] && set -- "$@" --resume "$SESSION"
    ;;
esac

# cwd matters, and differently per backend:
#   agy      - must NOT run with cwd inside $REPO; it then rejects writes as invalid
#              artifact paths. Launch from $HOME and let --add-dir scope it.
#   opencode - takes --dir, cwd irrelevant.
#   claude   - infers the repo from cwd, so cd in.
if [ "$BACKEND" = "claude" ]; then RUN_CWD="$REPO"; else RUN_CWD="$HOME"; fi

# A worker reaching for a global install should fail loudly, not succeed quietly.
# opencode --auto has already been seen running `pip install` into system python.
export PIP_REQUIRE_VIRTUALENV=1
export npm_config_prefix="$OUT/npm-global"

# Baseline commit, captured BEFORE the worker runs. Everything downstream diffs against
# this rather than against the working tree, because a worker that stages or commits
# makes `git status` and `git checkout .` both lie.
BASE=$(git -C "$REPO" rev-parse HEAD 2>/dev/null || echo "")

# macOS ships no timeout(1)/gtimeout, so run a watchdog. exec makes $CHILD the real
# binary's pid, so the kill lands on it rather than on a wrapper shell.
( cd "$RUN_CWD" && exec "$@" ) > "$RAW" 2>"$OUT/stderr.log" < /dev/null &
CHILD=$!
( sleep "$TIMEOUT_SECS"; pkill -P "$CHILD" 2>/dev/null; kill -TERM "$CHILD" 2>/dev/null
  sleep 10; pkill -9 -P "$CHILD" 2>/dev/null; kill -KILL "$CHILD" 2>/dev/null ) &
WATCHDOG=$!
wait "$CHILD"; CODE=$?
kill "$WATCHDOG" 2>/dev/null; wait "$WATCHDOG" 2>/dev/null
# 143=SIGTERM, 137=SIGKILL: the watchdog fired.
TIMED_OUT=no
case "$CODE" in 143|137) TIMED_OUT=yes ;; esac

# Normalize. Each backend reports differently; agy in particular returns
# status=ERROR when it merely hit a permission wall, so status is a hint, never a gate.
case "$BACKEND" in
  agy)
    jq -n --arg b agy --argjson c "$CODE" --slurpfile r "$RAW" \
      '{backend:$b, status:($r[0].status // "UNKNOWN"),
        session_id:($r[0].conversation_id // ""),
        text:($r[0].response // ""), error:($r[0].error // ""), exit_code:$c}' > "$RESULT" 2>/dev/null
    ;;
  opencode)
    # Parse as JSON, not grep: a tool result echoing a line containing "type":"text"
    # would otherwise be picked up as the worker's own message.
    TEXT=$(jq -rs 'map(select(.type=="text")) | last | .part.text // ""' "$RAW" 2>/dev/null)
    SID=$(jq -rs 'map(select(.sessionID != null)) | first | .sessionID // ""' "$RAW" 2>/dev/null)
    jq -n --arg b opencode --argjson c "$CODE" --arg t "${TEXT:-}" --arg s "${SID:-}" \
      '{backend:$b, status:(if $c==0 then "SUCCESS" else "ERROR" end),
        session_id:$s, text:$t, error:"", exit_code:$c}' > "$RESULT"
    ;;
  claude)
    jq -n --arg b claude --argjson c "$CODE" --slurpfile r "$RAW" \
      '{backend:$b, status:(if ($r[0].is_error // false) then "ERROR" else ($r[0].subtype // "unknown") end),
        session_id:($r[0].session_id // ""),
        text:($r[0].result // ""), error:"", exit_code:$c}' > "$RESULT" 2>/dev/null
    ;;
esac

CHANGED=$( { [ -n "$BASE" ] && git -C "$REPO" diff --name-only "$BASE" 2>/dev/null
             git -C "$REPO" ls-files --others --exclude-standard 2>/dev/null; } \
           | sort -u | grep -vc '^$' | tr -d ' ')
if [ -s "$RESULT" ]; then
  jq --argjson n "${CHANGED:-0}" --arg b "${BASE:-}" '.repo_changed=$n | .base_sha=$b' \
    "$RESULT" > "$RESULT.tmp" && mv "$RESULT.tmp" "$RESULT"
fi

[ -s "$RESULT" ] || jq -n --arg b "$BACKEND" --argjson c "$CODE" \
  '{backend:$b, status:"UNPARSEABLE", session_id:"", text:"", error:"see raw.json", exit_code:$c}' > "$RESULT"

if [ "$TIMED_OUT" = "yes" ]; then
  jq '.status="TIMEOUT" | .error="killed by watchdog after '"$TIMEOUT_SECS"'s"' "$RESULT" > "$RESULT.tmp" \
    && mv "$RESULT.tmp" "$RESULT"
fi

trap - EXIT
jq -r '"[\(.backend)] status=\(.status) exit=\(.exit_code) session=\(.session_id)"' "$RESULT"
exit "$CODE"
