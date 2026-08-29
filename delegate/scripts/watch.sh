#!/usr/bin/env bash
# Read-only live view of a delegated worker run.
#
#   watch.sh <run-dir> [backend]
#
# THIS IS NOT VERIFICATION. It answers "where is it, what did it touch, where did it
# stall" - never "is it right". The worker's own narration is dimmed and labelled
# `says:` on purpose: "all tests pass" in prose is not evidence. The gate is the test
# run the driver does itself, in step 4 of SKILL.md.
#
# Strictly one direction: this script only ever reads. It has no path back to the
# worker - no stdin, no signals to it - so a crashed viewer can never affect a run.
set -uo pipefail

RUN="${1:?usage: watch.sh <run-dir> [backend]}"
# The out-dir is per round (out/r1, out/r2, ...) — worker.sh refuses to reuse one, so
# `$RUN/out/raw.json` does not exist and following it would hang until the pane's read
# timeout. Take the highest-numbered round, which is the one just launched; fall back to
# a flat out/ for a run that predates the per-round layout.
OUTDIR=$(ls -d "$RUN"/out/r[0-9]* 2>/dev/null | sort -V | tail -1)
OUTDIR="${OUTDIR:-$RUN/out}"
RAW="$OUTDIR/raw.json"; RESULT="$OUTDIR/result.json"
REPO=$(cd "$RUN/repo" 2>/dev/null && pwd -P) || REPO="$RUN/repo"

BACKEND="${2:-}"
if [ -z "$BACKEND" ]; then
  if [ ! -s "$RAW" ]; then BACKEND=agy          # agy buffers; an empty raw.json means a live agy run
  elif head -c 400 "$RAW" | grep -q 'conversation_id\|"event"'; then BACKEND=agy
  else BACKEND=opencode; fi
fi

if [ -t 1 ]; then DIM=$'\033[2m'; BOLD=$'\033[1m'; OFF=$'\033[0m'; else DIM=''; BOLD=''; OFF=''; fi
T0=$(date +%s)
el() { printf '[%4ds]' $(( $(date +%s) - T0 )); }

# Field separator US(\037) and embedded-newline marker RS(\036): a shell command can
# contain '|' or ':', so a printable delimiter corrupts the parse. Multi-line tool
# output is folded onto one line here and unfolded at print time - otherwise each
# output line is read as a new record and renders as a fake event.
US=$'\037'; RS=$'\036'

printf '%swatching %s (%s) - read-only, not verification%s\n' "$DIM" "$(basename "$RUN")" "$BACKEND" "$OFF"

FIFO=""
cleanup() { [ -n "$FIFO" ] && rm -f "$FIFO"; [ -n "${TAIL_PID:-}" ] && kill "$TAIL_PID" 2>/dev/null; }
trap cleanup EXIT

render() {
  jq -r --arg repo "$REPO" --arg us "$US" --arg rs "$RS" '
    def clip($n): if (.|length) > $n then .[0:$n] + "…" else . end;
    if .type=="tool_use" and .part.state.status=="completed" then
      (.part.tool) as $t
      | ((.part.state.input.filePath // .part.state.input.command // .part.state.title // "")
         | ltrimstr($repo + "/") | gsub("\n"; " ")
         | gsub("\u001b\\[[0-9;]*[A-Za-z]"; "")) as $tgt
      | if $t=="bash" then
          [ "bash", ($tgt|clip(66)), "exit=\(.part.state.metadata.exit // "?")",
            ((.part.state.metadata.output // "") | split("\n") | map(select(length>0)) | .[-6:]
             | map(gsub("\u001b\\[[0-9;]*[A-Za-z]"; "") | clip(76)) | join($rs)) ] | join($us)
        else
          [ $t, ($tgt|clip(66)), "", "" ] | join($us)
        end
    elif .type=="text" then
      [ "says", ((.part.text // "")|gsub("\n";" ")|clip(94)), "", "" ] | join($us)
    else empty end' 2>/dev/null
}

emit() {
  local tool tgt xit out
  while IFS="$US" read -r tool tgt xit out; do
    [ -z "${tool:-}" ] && continue
    if [ "$tool" = "says" ]; then
      printf '%s %ssays: %s%s\n' "$(el)" "$DIM" "$tgt" "$OFF"
    else
      printf '%s %-6s %s %s%s%s\n' "$(el)" "$tool" "$tgt" "$BOLD" "${xit:-}" "$OFF"
    fi
    if [ -n "${out:-}" ]; then
      printf '%s\n' "$out" | tr "$RS" '\n' | sed "s/^/           ${DIM}| /;s/\$/${OFF}/"
    fi
  done
}

# ---------------------------------------------------------------- opencode: real stream
stream_opencode() {
  # tail -F follows by NAME. worker.sh rm -f's raw.json at start, so following by
  # descriptor would pin the deleted inode and show nothing forever.
  # The FIFO exists so we hold tail's real PID: `tail | while` makes tail a grandchild
  # that survives killing the loop, and the viewer then never exits.
  FIFO=$(mktemp -u /tmp/watch.XXXXXX); mkfifo "$FIFO"
  tail -n +1 -F "$RAW" 2>/dev/null > "$FIFO" &
  TAIL_PID=$!
  disown "$TAIL_PID" 2>/dev/null    # else bash prints "Terminated: 15" when it is killed
  # Drain-then-stop, never kill-on-a-timer: a timer cuts a fast replay off mid-stream
  # and drops exactly the events you want (the final test run and summary).
  while :; do
    if IFS= read -r -t 1 line; then
      [ -z "$line" ] && continue
      printf '%s' "$line" | jq -e . >/dev/null 2>&1 || continue  # drop half-written lines
      printf '%s' "$line" | render | emit
    else
      [ -s "$RESULT" ] && break                                  # quiet AND finished
    fi
  done < "$FIFO"
  kill "$TAIL_PID" 2>/dev/null
}

# ------------------------------------------------- agy: no usable stream, watch the tree
# agy's stream-json emits only {init, step_update{step_index,state,step_type}, result} -
# a step counter, no tool names or paths. Its brain transcript has the detail but only as
# prose under a path named .system_generated, which is not a contract. So watch the
# filesystem: backend-agnostic, and the same ground truth the gate uses.
stream_agy() {
  local prev="" cur
  printf '%s%s  (agy exposes no tool stream - showing file changes instead)%s\n' "$(el)" "$DIM" "$OFF"
  while [ ! -s "$RESULT" ]; do
    cur=$(git -C "$REPO" status --short 2>/dev/null)
    if [ "$cur" != "$prev" ]; then
      comm -13 <(printf '%s\n' "$prev" | sort) <(printf '%s\n' "$cur" | sort) 2>/dev/null \
        | while IFS= read -r l; do [ -n "$l" ] && printf '%s %s\n' "$(el)" "$l"; done
      prev="$cur"
    fi
    sleep 2
  done
}

# A finished run renders identically: tail -n +1 -F replays the whole file, and the
# loop only exits once the stream has gone quiet AND result.json exists.
case "$BACKEND" in
  opencode) stream_opencode ;;
  *)        stream_agy ;;
esac

printf '%s────── %s\n' "$(el)" "$(jq -r '"done: \(.status)  exit=\(.exit_code)"' "$RESULT" 2>/dev/null)"
printf '%sgate not yet run - green here proves nothing until the driver runs the tests%s\n' "$DIM" "$OFF"
