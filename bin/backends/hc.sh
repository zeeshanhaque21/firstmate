#!/usr/bin/env bash
# bin/backends/hc.sh - the hc (herdr-core) session-provider adapter.
#
# `hc` is the herdr-core terminal multiplexer CLI (binary `herdr-core`, v0.1.21
# verified); it is NOT the `herdr` CLI that bin/backends/herdr.sh drives.
# Sourced only through bin/fm-backend.sh's fm_backend_source, never directly.
# docs/hc-backend.md owns the setup, the verified findings, and the limits.
#
# Identity model: a task is one hc terminal. Its stable id is the LOCAL address
# `t<N>` (create_task prints it; every other function takes it as <target>).
# The terminal is named `fm-<task-id>` and labelled `fm_task=<task-id>`; the
# name is a guard and a lookup aid, never the target. Remote-machine addresses
# (`machine/tN`) are refused everywhere: this cut is local-machine only.
#
# Mechanics verified against hc 0.1.21:
#   - Every hc call goes through fm_backend_hc_cli, the single choke point, so
#     a test shims PATH (or a caller overrides nothing else) in one place.
#   - Errors are JSON on STDERR with `.error.kind` and a nonzero exit; a
#     not-found address exits 3 with kind `not_found`, which is the only
#     definitive "missing". Every other failure is `unreadable`, never `dead`.
#   - `hc get` `.cwd` is frozen at creation; `.foreground.cwd` tracks the live
#     working directory, so current_path reads `.foreground`.
#   - `hc send` pastes text and presses Enter in one call. `hc keys` presses
#     ONE key per argument, so there is no unsubmitted-paste primitive:
#     send_literal types per-key and refuses text it cannot map, and fm-spawn
#     uses send_text_line (paste + Enter) for hc instead.
#   - `hc read --lines N` adds N lines of history ABOVE the screen; capture
#     bounds the combined output to its last N lines.
#
# Not provided in this cut (the dispatcher's generic arms answer unknown or
# fall back to polling): events/push, busy_state, away-mode supervisor.
# shellcheck source=bin/fm-composer-lib.sh
. "$FM_BACKEND_LIB_DIR/fm-composer-lib.sh"
# shellcheck source=bin/fm-agent-process-lib.sh
. "$FM_BACKEND_LIB_DIR/fm-agent-process-lib.sh"

# fm_backend_hc_bin: the hc executable path (herdr-core preferred, then hc).
fm_backend_hc_bin() {
  local found
  if found=$(command -v herdr-core 2>/dev/null) && [ -n "$found" ]; then
    printf '%s' "$found"
  elif found=$(command -v hc 2>/dev/null) && [ -n "$found" ]; then
    printf '%s' "$found"
  else
    return 1
  fi
}

# fm_backend_hc_tool_check: refuse loudly if hc or jq is missing.
fm_backend_hc_tool_check() {
  fm_backend_hc_bin >/dev/null || { echo "error: backend=hc selected but neither 'herdr-core' nor 'hc' is on PATH" >&2; return 1; }
  command -v jq >/dev/null 2>&1 || { echo "error: backend=hc selected but 'jq' is not installed (required to parse hc's JSON output)" >&2; return 1; }
  return 0
}

# fm_backend_hc_cli: the ONE place that invokes hc.
fm_backend_hc_cli() {  # <hc-subcommand-and-args...>
  local bin
  bin=$(fm_backend_hc_bin) || { echo "error: hc executable not found" >&2; return 127; }
  "$bin" "$@"
}

# fm_backend_hc_target_valid: 0 only for a local address `t<N>`. Anything else
# (empty, remote `machine/tN`, a name, path-like text) is refused before hc is
# called, because hc itself resolves names and machine prefixes.
fm_backend_hc_target_valid() {  # <target>
  case "${1:-}" in
    t[0-9]*) ;;
    *) return 1 ;;
  esac
  case "${1#t}" in
    *[!0-9]*) return 1 ;;
  esac
  return 0
}

# fm_backend_hc_get: one terminal's `hc get --json` on stdout. Returns 0 on
# success, 3 when hc definitively reports not_found, 1 on any other failure
# (transport, server, parse). Callers map 3 to missing and 1 to unreadable.
fm_backend_hc_get() {  # <target>
  local target=$1 out rc
  fm_backend_hc_target_valid "$target" || return 1
  out=$(fm_backend_hc_cli get "$target" --json 2>&1) && rc=0 || rc=$?
  if [ "$rc" -eq 0 ]; then
    printf '%s' "$out" | jq -e 'type == "object"' >/dev/null 2>&1 || return 1
    printf '%s' "$out"
    return 0
  fi
  if [ "$rc" -eq 3 ] && [ "$(printf '%s' "$out" | jq -r '.error.kind // empty' 2>/dev/null)" = not_found ]; then
    return 3
  fi
  return 1
}

# fm_backend_hc_resolve_bare_selector: the live-terminal-listing fallback for a
# selector that is neither an explicit target nor a task selector routed
# through meta. Prints the address of the first LIVE local terminal with that
# exact name.
fm_backend_hc_resolve_bare_selector() {  # <name>
  local name=$1 out addr
  out=$(fm_backend_hc_cli ls --json 2>/dev/null) || { echo "error: hc terminal listing failed" >&2; return 1; }
  addr=$(printf '%s' "$out" | jq -r --arg n "$name" \
    '[.terminals[]? | select(.name == $n and .state == "live" and (.address | test("^t[0-9]+$"))) | .address][0] // empty' 2>/dev/null)
  [ -n "$addr" ] || { echo "error: no terminal named $name" >&2; return 1; }
  printf '%s\n' "$addr"
}

# fm_backend_hc_capture: bounded plain-text capture of the screen plus up to
# <lines> lines of history, then only the LAST <lines> lines of that. This
# approximates tmux's `capture-pane -S -N`: hc trims trailing blank rows, so a
# short screen yields fewer lines than tmux would.
fm_backend_hc_capture() {  # <target> <lines>
  local target=$1 lines=${2:-200} out
  fm_backend_hc_target_valid "$target" || return 1
  case "$lines" in ''|*[!0-9]*) lines=200 ;; esac
  out=$(fm_backend_hc_cli read "$target" --lines "$lines" 2>/dev/null) || return 1
  [ -n "$out" ] || return 0
  printf '%s\n' "$out" | tail -n "$lines"
}

# fm_backend_hc_normalize_key: firstmate's key vocabulary onto hc key names.
fm_backend_hc_normalize_key() {  # <key>
  case "$1" in
    Enter|enter) printf 'enter' ;;
    Escape|escape|Esc|esc) printf 'esc' ;;
    C-c|c-c|ctrl+c|Ctrl+C) printf 'ctrl+c' ;;
    C-u|c-u|ctrl+u|Ctrl+U) printf 'ctrl+u' ;;
    Tab|tab) printf 'tab' ;;
    Up|up) printf 'up' ;;
    Down|down) printf 'down' ;;
    Left|left) printf 'left' ;;
    Right|right) printf 'right' ;;
    BSpace|Backspace|backspace) printf 'backspace' ;;
    Space|space) printf 'space' ;;
    *) printf '%s' "$1" ;;
  esac
}

# fm_backend_hc_send_key: one named key; extra caller arguments are ignored.
fm_backend_hc_send_key() {  # <target> <key> [ignored]
  local target=$1 key
  fm_backend_hc_target_valid "$target" || return 1
  [ -n "${2:-}" ] || return 1
  key=$(fm_backend_hc_normalize_key "$2")
  fm_backend_hc_cli keys "$target" "$key" >/dev/null 2>&1
}

# fm_backend_hc_composer_state: thin adapter - plain capture plus a capability
# descriptor in, shared verdict out (bin/fm-composer-lib.sh owns every shape).
# `hc read` is plain text with no cursor row and there is no identity probe, so
# the descriptor is styled=0 cursor=0 identity=0 and the classifier degrades
# ambiguous rows to `unknown`, which callers treat as "do not assume".
fm_backend_hc_composer_state() {  # <target> [ignored] -> empty|pending|pending-unproven|unknown
  local cap verdict
  cap=$(fm_backend_hc_capture "$1" "$FM_COMPOSER_CAPTURE_LINES") || { printf 'unknown'; return 0; }
  verdict=$(fm_composer_classify_screen "$(printf 'styled=0\ncursor=0\nidentity=0\nrows=%s\n' "$FM_COMPOSER_CAPTURE_LINES")" "$cap")
  [ "$verdict" != need-identity ] || verdict=unknown
  printf '%s' "$verdict"
}

# fm_backend_hc_send_text_submit: type <text> ONCE via `hc send` (which pastes
# and presses Enter), then verify the composer with the shared verdict. While it
# still reads proven pending, retry Enter only (`hc keys enter`), never the
# text, up to <retries> extra Enters. Echoes the proof-carrying verdict
# vocabulary the other adapters use: empty|pending|pending-unproven|unknown|
# send-failed. No busy signal exists here, so a pending verdict after the
# retries is reported as pending rather than converted to a queued Enter.
# `hc send` refuses a program that is blocked on a dialog (no --force); that
# surfaces as send-failed.
fm_backend_hc_send_text_submit() {  # <target> <text> <retries> <enter-sleep> <settle> [ignored]
  local target=$1 text=$2 retries=${3:-3} sleep_s=${4:-1} settle=${5:-0} i=0 state
  fm_backend_hc_target_valid "$target" || { printf 'unknown'; return 0; }
  fm_backend_hc_cli send "$target" -- "$text" >/dev/null 2>&1 || { printf 'send-failed'; return 0; }
  sleep "$settle"
  while :; do
    state=$(fm_backend_hc_composer_state "$target")
    case "$state" in
      pending|pending-unproven) ;;
      *) printf '%s' "$state"; return 0 ;;
    esac
    [ "$i" -lt "$retries" ] || { printf '%s' "$state"; return 0; }
    i=$((i + 1))
    fm_backend_hc_send_key "$target" Enter || true
    sleep "$sleep_s"
  done
}

# fm_backend_hc_container_ensure: hc has no session container; print the
# constant the spawn path records as the session.
fm_backend_hc_container_ensure() {
  printf 'hc'
}

# fm_backend_hc_create_task: start the task's terminal in <proj-abs> and print
# its address. <session> is the constant from container_ensure and is unused.
# Refuses a LIVE terminal that already has <name> (hc enforces the same
# uniqueness, but the pre-check gives a clear error and survives a race only
# as hc's own refusal). --no-parent keeps the terminal alive after the caller
# exits; --no-notify keeps hc from notifying the captain about the shell.
fm_backend_hc_create_task() {  # <session> <name> <proj-abs> -> prints address
  local name=$2 proj_abs=$3 listing existing out addr
  case "$name" in
    ''|*[!abcdefghijklmnopqrstuvwxyz0123456789_-]*) echo "error: hc terminal name '$name' must be 1-32 chars of a-z 0-9 - _" >&2; return 1 ;;
  esac
  [ "${#name}" -le 32 ] || { echo "error: hc terminal name '$name' exceeds 32 chars" >&2; return 1; }
  [ -d "$proj_abs" ] || { echo "error: project directory $proj_abs does not exist" >&2; return 1; }
  listing=$(fm_backend_hc_cli ls --json 2>/dev/null) || { echo "error: hc terminal listing failed" >&2; return 1; }
  existing=$(printf '%s' "$listing" | jq -r --arg n "$name" \
    '[.terminals[]? | select(.name == $n and .state == "live") | .address][0] // empty' 2>/dev/null) \
    || { echo "error: unparseable hc terminal listing" >&2; return 1; }
  if [ -n "$existing" ]; then
    echo "error: terminal $name already exists ($existing)" >&2
    return 1
  fi
  out=$(fm_backend_hc_cli run --bg --json --name "$name" --cwd "$proj_abs" --no-parent --no-notify \
    --label "fm_task=${name#fm-}") || return 1
  addr=$(printf '%s' "$out" | jq -r '.address // empty' 2>/dev/null)
  fm_backend_hc_target_valid "$addr" || { echo "error: hc run returned no local address for $name" >&2; return 1; }
  printf '%s\n' "$addr"
}

# fm_backend_hc_current_path: the terminal's live working directory
# (`.foreground.cwd`, NOT the frozen `.cwd`), or empty on any error.
fm_backend_hc_current_path() {  # <target> [ignored]
  local info
  info=$(fm_backend_hc_get "$1") || return 0
  printf '%s' "$info" | jq -r '.foreground.cwd // empty' 2>/dev/null
}

# fm_backend_hc_send_text_line: paste one line of TEXT and press Enter with no
# composer verification (the fixed spawn-time commands).
fm_backend_hc_send_text_line() {  # <target> <text> [ignored]
  fm_backend_hc_target_valid "$1" || return 1
  fm_backend_hc_cli send "$1" -- "$2" >/dev/null 2>&1
}

# fm_backend_hc_send_literal: type TEXT with no submission. hc has no
# unsubmitted-paste primitive and `hc keys` takes one key per argument, so this
# types per key and handles only a-z 0-9 space and - . / = , ' [ ] \ ; `.
# Anything else (uppercase included: hc folds it to lowercase) is refused with
# nonzero before a single key is sent. Callers on hc use send_text_line.
fm_backend_hc_send_literal() {  # <target> <text> [ignored]
  local target=$1 text=${2-} i ch
  local -a keys=()
  fm_backend_hc_target_valid "$target" || return 1
  for ((i = 0; i < ${#text}; i++)); do
    ch=${text:i:1}
    case "$ch" in
      ' ') keys+=(space) ;;
      [abcdefghijklmnopqrstuvwxyz0123456789] | - | . | / | = | , | "'" | '[' | ']' | "\\" | ';' | '`') keys+=("$ch") ;;
      *)
        echo "error: hc send_literal cannot type '$ch' (use send_text_line, which pastes)" >&2
        return 1
        ;;
    esac
  done
  [ "${#keys[@]}" -gt 0 ] || return 0
  fm_backend_hc_cli keys "$target" "${keys[@]}" >/dev/null 2>&1
}

# fm_backend_hc_kill: end one task terminal, best-effort. Refuses (nonzero,
# before ending anything) a target that is not a local `t<N>` address, and one
# that hc reports under a name not starting with `fm-`: addresses can be
# renumbered after a server restart, and this keeps a stale recorded address
# from killing a terminal firstmate never created. A terminal already gone is
# success. An unreadable inventory refuses rather than guessing.
fm_backend_hc_kill() {  # <target> [ignored]
  local target=${1:-} info rc=0 name i=0
  fm_backend_hc_target_valid "$target" || { echo "error: refusing hc kill of '$target' (not a local tN address)" >&2; return 1; }
  info=$(fm_backend_hc_get "$target") || rc=$?
  case "$rc" in
    0) ;;
    3) return 0 ;;
    *) echo "error: cannot read hc terminal $target; not killing" >&2; return 1 ;;
  esac
  name=$(printf '%s' "$info" | jq -r '.name // empty' 2>/dev/null)
  case "$name" in
    fm-*) ;;
    *) echo "error: refusing hc kill of $target (name '$name' is not an fm- task terminal)" >&2; return 1 ;;
  esac
  fm_backend_hc_cli kill "$target" >/dev/null 2>&1 || true
  while [ "$i" -lt 5 ]; do
    fm_backend_hc_cli rm "$target" >/dev/null 2>&1 && return 0
    i=$((i + 1))
    sleep 0.2
  done
  return 0
}

# fm_backend_hc_target_exists: 0 when <target> is a LIVE local terminal.
fm_backend_hc_target_exists() {  # <target> [ignored]
  local info
  info=$(fm_backend_hc_get "$1") || return 1
  [ "$(printf '%s' "$info" | jq -r '.state // empty' 2>/dev/null)" = live ]
}

# fm_backend_hc_agent_state: recovery-grade agent state for one recorded
# target; the contract (alive|dead|missing|ambiguous|unreadable) is owned by
# bin/fm-backend.sh's fm_backend_agent_state. A non-address target is
# unreadable. A definitive not_found or a non-live state is missing. Any
# transport or parse failure is unreadable, never dead, so a transient hc
# problem cannot license a duplicate agent onto a live worktree. The live
# verdict classifies the foreground process (`.foreground` name, argv[0], and
# flattened argv) with the shared classifier: any agent -> alive, only shells ->
# dead, anything else -> ambiguous.
fm_backend_hc_agent_state() {  # <target>
  local target=$1 info rc=0 state fg name argv0 args pid
  fm_backend_hc_target_valid "$target" || { printf 'unreadable'; return 0; }
  info=$(fm_backend_hc_get "$target") || rc=$?
  case "$rc" in
    0) ;;
    3) printf 'missing'; return 0 ;;
    *) printf 'unreadable'; return 0 ;;
  esac
  state=$(printf '%s' "$info" | jq -r '.state // empty' 2>/dev/null) || { printf 'unreadable'; return 0; }
  case "$state" in
    live) ;;
    '') printf 'unreadable'; return 0 ;;
    *) printf 'missing'; return 0 ;;
  esac
  fg=$(printf '%s' "$info" | jq -r '.foreground | if type == "object" then [(.name // ""), (.argv[0]? // ""), ((.argv // []) | map(tostring) | join(" ")), (.pid // "" | tostring)] | join("\u001f") else empty end' 2>/dev/null)
  [ -n "$fg" ] || { printf 'unreadable'; return 0; }
  IFS=$'\037' read -r name argv0 args pid <<EOF
$fg
EOF
  [ -n "$name$argv0" ] || { printf 'unreadable'; return 0; }
  case "$(fm_agent_process_classify "$name" "$argv0" "$args" "$pid")" in
    agent) printf 'alive' ;;
    shell) printf 'dead' ;;
    *) printf 'ambiguous' ;;
  esac
}

# Backward-compatible three-state view; copies the tmux adapter.
fm_backend_hc_agent_alive() {  # <target>
  case "$(fm_backend_hc_agent_state "$1")" in
    alive) printf 'alive' ;;
    dead|missing) printf 'dead' ;;
    *) printf 'unknown' ;;
  esac
}
