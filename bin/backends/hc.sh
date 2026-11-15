#!/usr/bin/env bash
# bin/backends/hc.sh - the hc (herdr-core) session-provider adapter.
#
# `hc` is the herdr-core terminal multiplexer CLI (binary `herdr-core`, v0.1.21
# verified); it is NOT the `herdr` CLI that bin/backends/herdr.sh drives.
# Sourced only through bin/fm-backend.sh's fm_backend_source, never directly.
# docs/hc-backend.md owns the setup, the verified findings, and the limits.
#
# Identity model: a task is one hc terminal. Its recorded id is the LOCAL address
# `t<N>` (lowercase letters and digits; create_task prints it; every other function
# takes it as <target>). The terminal is named `fm-<task-id>` and labelled
# `fm_task=<task-id>`. Remote-machine addresses (`machine/tN`) are refused
# everywhere: this cut is local-machine only.
#
# Name guard: addresses can be renumbered after an hc server restart, so the
# recorded address alone must never reach a terminal that holds someone else's
# work. Every action that sends input, kills, or reads a screen first confirms
# `hc get <addr>` returns `.name` exactly equal to the caller's expected label
# (`fm-<task-id>`), then confirms `hc get <label>` maps back to the same
# address, and then ACTS ON THE NAME, so the final hc call cannot land on a
# different terminal even if the address is reassigned in between. Actions
# (send, keys, kill) REFUSE when no expected label is supplied. Read-only
# classification (capture, composer_state, current_path, target_exists,
# agent_state) accepts a missing label and then requires only an `fm-` name
# prefix. A present terminal whose name differs is refused (agent_state reports
# `ambiguous`, never `dead`, so it cannot license a relaunch); only a definitive
# not_found is `missing`. Every function takes the label as its LAST optional
# argument, in the position the dispatcher passes it; kill takes it third
# (<target> <tab-id-unused> <label>), as fm_backend_kill's callers pass it.
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

# fm_backend_hc_target_valid: 0 only for a local address `t<N>` where <N> is
# lowercase alphanumeric (observed live: t19, t1b, t1h). Anything else (empty,
# remote `machine/tN`, a name, path-like text) is refused before hc is called,
# because hc itself resolves names and machine prefixes.
fm_backend_hc_target_valid() {  # <target>
  case "${1:-}" in
    t?*) ;;
    *) return 1 ;;
  esac
  case "${1#t}" in
    *[!0123456789abcdefghijklmnopqrstuvwxyz]*) return 1 ;;
  esac
  return 0
}

# fm_backend_hc_label_valid: 0 only for a task terminal name `fm-<id>` (the
# charset hc allows, at most 32 chars). Refusing anything else keeps a label
# from ever being an address, a machine path, or an option.
fm_backend_hc_label_valid() {  # <label>
  case "${1:-}" in
    fm-?*) ;;
    *) return 1 ;;
  esac
  case "$1" in
    *[!abcdefghijklmnopqrstuvwxyz0123456789_-]*) return 1 ;;
  esac
  [ "${#1}" -le 32 ]
}

# fm_backend_hc_get_ref: one terminal's `hc get --json` on stdout for an
# address OR a name. Returns 0 on success, 3 when hc definitively reports
# not_found, 1 on any other failure (transport, server, parse). Callers map 3 to
# missing and 1 to unreadable.
fm_backend_hc_get_ref() {  # <address-or-name>
  local ref=$1 out rc
  [ -n "$ref" ] || return 1
  out=$(fm_backend_hc_cli get "$ref" --json 2>&1) && rc=0 || rc=$?
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

# fm_backend_hc_get: fm_backend_hc_get_ref restricted to a local address.
fm_backend_hc_get() {  # <target>
  fm_backend_hc_target_valid "$1" || return 1
  fm_backend_hc_get_ref "$1"
}

# fm_backend_hc_verify: confirm <target> is the terminal named <label>, and
# print its `hc get` JSON. Returns 0 verified, 3 definitively absent (hc
# not_found), 4 present under a DIFFERENT name (unnamed included), 1 invalid
# input or unreadable. With no <label>, only the `fm-` name prefix is required.
fm_backend_hc_verify() {  # <target> [label]
  local target=$1 label=${2:-} info rc=0 name
  fm_backend_hc_target_valid "$target" || return 1
  if [ -n "$label" ] && ! fm_backend_hc_label_valid "$label"; then
    echo "error: refusing hc terminal $target: '$label' is not an fm-<id> terminal name" >&2
    return 1
  fi
  info=$(fm_backend_hc_get "$target") || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  name=$(printf '%s' "$info" | jq -r '.name // empty' 2>/dev/null) || return 1
  # hc resolves names as well as addresses; the answer must BE the asked address.
  [ "$(printf '%s' "$info" | jq -r '.address // empty' 2>/dev/null)" = "$target" ] || return 1
  if [ -n "$label" ]; then
    [ "$name" = "$label" ] && { printf '%s' "$info"; return 0; }
  else
    case "$name" in fm-?*) printf '%s' "$info"; return 0 ;; esac
  fi
  printf 'error: refusing hc terminal %s: it is named %q, not %s\n' "$target" "$name" "${label:-an fm- task terminal}" >&2
  return 4
}

# fm_backend_hc_ref: the hc argument to ACT on for <target>. mode `act` (send,
# keys, kill) requires <label>, verifies the name, re-verifies that the name
# maps back to <target>, and prints the NAME, which hc resolves at action time.
# mode `read` prints the verified address, or the name when a label is given.
# Nonzero (message on stderr) refuses.
fm_backend_hc_ref() {  # <target> <label> <act|read>
  local target=$1 label=${2:-} mode=$3 byname rc=0 addr
  if [ -z "$label" ] && [ "$mode" = act ]; then
    echo "error: refusing hc action on $target: no expected terminal name (fm-<task-id>) was supplied" >&2
    return 1
  fi
  fm_backend_hc_verify "$target" "$label" >/dev/null || return 1
  if [ -z "$label" ]; then
    printf '%s' "$target"
    return 0
  fi
  byname=$(fm_backend_hc_get_ref "$label") || rc=$?
  [ "$rc" -eq 0 ] || { echo "error: refusing hc terminal $target: could not re-resolve $label by name" >&2; return 1; }
  addr=$(printf '%s' "$byname" | jq -r '.address // empty' 2>/dev/null)
  [ "$addr" = "$target" ] || { echo "error: refusing hc terminal $target: name $label now resolves to '$addr'" >&2; return 1; }
  printf '%s' "$label"
}

# fm_backend_hc_resolve_bare_selector: the live-terminal-listing fallback for a
# selector that is neither an explicit target nor a task selector routed
# through meta. Prints the address of the first LIVE local terminal with that
# exact name.
fm_backend_hc_resolve_bare_selector() {  # <name>
  local name=$1 out addr
  out=$(fm_backend_hc_cli ls --json 2>/dev/null) || { echo "error: hc terminal listing failed" >&2; return 1; }
  addr=$(printf '%s' "$out" | jq -r --arg n "$name" \
    '[.terminals[]? | select(.name == $n and .state == "live" and (.address | test("^t[0-9a-z]+$"))) | .address][0] // empty' 2>/dev/null)
  [ -n "$addr" ] || { echo "error: no terminal named $name" >&2; return 1; }
  printf '%s\n' "$addr"
}

# fm_backend_hc_capture: bounded plain-text capture of the screen plus up to
# <lines> lines of history, then only the LAST <lines> lines of that. This
# approximates tmux's `capture-pane -S -N`: hc trims trailing blank rows, so a
# short screen yields fewer lines than tmux would.
fm_backend_hc_capture() {  # <target> <lines> [expected-label]
  local target=$1 lines=${2:-200} out ref
  fm_backend_hc_target_valid "$target" || return 1
  case "$lines" in ''|*[!0-9]*) lines=200 ;; esac
  ref=$(fm_backend_hc_ref "$target" "${3:-}" read) || return 1
  out=$(fm_backend_hc_cli read "$ref" --lines "$lines" 2>/dev/null) || return 1
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

# fm_backend_hc_send_key: one named key to the terminal named <expected-label>
# (required: see the name guard in the header).
fm_backend_hc_send_key() {  # <target> <key> <expected-label>
  local target=$1 key ref
  fm_backend_hc_target_valid "$target" || return 1
  [ -n "${2:-}" ] || return 1
  key=$(fm_backend_hc_normalize_key "$2")
  ref=$(fm_backend_hc_ref "$target" "${3:-}" act) || return 1
  fm_backend_hc_cli keys "$ref" "$key" >/dev/null 2>&1
}

# fm_backend_hc_native_status: the terminal's native agent identity and state
# from `hc get` `.status` ({"app":"pi","state":"idle|working|done|..."}), which
# hc fills from the harness itself. Prints "<app><TAB><state>"; returns 1 when
# the terminal cannot be verified (name guard) or read. A terminal with no
# reported agent prints an empty app.
fm_backend_hc_native_status() {  # <target> [expected-label]
  local info
  info=$(fm_backend_hc_verify "$1" "${2:-}" 2>/dev/null) || return 1
  printf '%s' "$info" | jq -r '(.status | if type == "object" then [(.app // ""), (.state // "")] else ["", ""] end) | @tsv' 2>/dev/null
}

# fm_backend_hc_composer_state: thin adapter - plain capture plus a capability
# descriptor in, shared verdict out (bin/fm-composer-lib.sh owns every shape).
# `hc read` is plain text with no cursor row, so the descriptor is styled=0
# cursor=0. identity=1, because hc itself reports the agent's identity and
# state (fm_backend_hc_native_status): pi draws a BLANK composer between two
# rules, provable only with an identity that says an idle pi owns the pane, and
# without it every real pi screen read `unknown`. The probe is fetched lazily,
# exactly as the herdr and tmux adapters do, and a missing or unreadable probe
# degrades to `probe-absent`, which keeps the shape `unknown`.
# NOTE for the capture: hc's screen is the terminal's full height (120 rows
# for terminals started by `hc run --bg`), top-anchored, so a short TUI leaves
# the composer at the BOTTOM of mostly blank rows; fm_backend_hc_capture keeps
# the last <rows> lines, which is where the composer lives.
fm_backend_hc_composer_state() {  # <target> [expected-label] -> empty|pending|pending-unproven|unknown
  local cap verdict caps identity
  cap=$(fm_backend_hc_capture "$1" "$FM_COMPOSER_CAPTURE_LINES" "${2:-}") || { printf 'unknown'; return 0; }
  caps=$(printf 'styled=0\ncursor=0\nidentity=1\nrows=%s\n' "$FM_COMPOSER_CAPTURE_LINES")
  verdict=$(fm_composer_classify_screen "$caps" "$cap")
  if [ "$verdict" = need-identity ]; then
    if ! identity=$(fm_backend_hc_native_status "$1" "${2:-}") || [ -z "${identity%%$'\t'*}" ]; then
      identity=probe-absent
    fi
    verdict=$(fm_composer_classify_screen "$caps" "$cap" '' "$identity")
    [ "$verdict" != need-identity ] || verdict=unknown
  fi
  printf '%s' "$verdict"
}

# fm_backend_hc_send_text_submit: type <text> ONCE via `hc send` (which pastes
# and presses Enter), then verify the composer with the shared verdict. While it
# still reads proven pending, retry Enter only (`hc keys enter`), never the
# text, up to <retries> extra Enters. Echoes the proof-carrying verdict
# vocabulary the other adapters use: empty|pending|pending-unproven|unknown|
# send-failed.
#
# Two confirmations come from hc's native agent state, mirroring the tmux
# core's turn-started and queued-Enter rules (bin/fm-tmux-lib.sh):
#   - turn started: a harness whose mid-turn screen cannot be classified (pi
#     replaces its composer rule with a `Working` spinner) reads `unknown`
#     right after a successful submit. When and only when the native state was
#     idle or done BEFORE the text was typed, a later `working` state is proof
#     the submission was accepted, so the verdict is `empty`; polled across the
#     retry budget because the turn takes a beat to start. Without that
#     baseline (already working, or no native state) `unknown` stays `unknown`.
#   - queued Enter: a proven-pending composer that survives the Enter retries
#     while the native state is `working` means the Enter was accepted and
#     queued (fm_composer_queued_enter_verdict).
# `hc send` refuses a program that is blocked on a dialog (no --force); that
# surfaces as send-failed, and so does a name-guard refusal (nothing was typed).
fm_backend_hc_send_text_submit() {  # <target> <text> <retries> <enter-sleep> <settle> <expected-label>
  local target=$1 text=$2 retries=${3:-3} sleep_s=${4:-1} settle=${5:-0} label=${6:-} i=0 j state ref
  local baseline_idle='' native native_state
  fm_backend_hc_target_valid "$target" || { printf 'unknown'; return 0; }
  ref=$(fm_backend_hc_ref "$target" "$label" act) || { printf 'send-failed'; return 0; }
  native=$(fm_backend_hc_native_status "$target" "$label") || native=
  case "${native#*$'\t'}" in idle|done) baseline_idle=1 ;; esac
  fm_backend_hc_cli send "$ref" -- "$text" >/dev/null 2>&1 || { printf 'send-failed'; return 0; }
  sleep "$settle"
  while :; do
    state=$(fm_backend_hc_composer_state "$target" "$label")
    case "$state" in
      pending|pending-unproven) ;;
      unknown)
        if [ -n "$baseline_idle" ]; then
          j=0
          while [ "$j" -lt "$retries" ]; do
            native=$(fm_backend_hc_native_status "$target" "$label") || native=
            if [ "${native#*$'\t'}" = working ]; then
              printf 'empty'
              return 0
            fi
            j=$((j + 1))
            [ "$j" -ge "$retries" ] || sleep "$sleep_s"
          done
        fi
        printf 'unknown'
        return 0
        ;;
      *) printf '%s' "$state"; return 0 ;;
    esac
    if [ "$i" -ge "$retries" ]; then
      native=$(fm_backend_hc_native_status "$target" "$label") || native=
      native_state=idle
      [ "${native#*$'\t'}" != working ] || native_state=busy
      fm_composer_queued_enter_verdict "$state" "$native_state"
      return 0
    fi
    i=$((i + 1))
    fm_backend_hc_send_key "$target" Enter "$label" || true
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
fm_backend_hc_current_path() {  # <target> [expected-label]
  local info
  info=$(fm_backend_hc_verify "$1" "${2:-}" 2>/dev/null) || return 0
  printf '%s' "$info" | jq -r '.foreground.cwd // empty' 2>/dev/null
}

# fm_backend_hc_send_text_line: paste one line of TEXT and press Enter with no
# composer verification (the fixed spawn-time commands).
fm_backend_hc_send_text_line() {  # <target> <text> <expected-label>
  local ref
  fm_backend_hc_target_valid "$1" || return 1
  ref=$(fm_backend_hc_ref "$1" "${3:-}" act) || return 1
  fm_backend_hc_cli send "$ref" -- "$2" >/dev/null 2>&1
}

# fm_backend_hc_send_literal: type TEXT with no submission. hc has no
# unsubmitted-paste primitive and `hc keys` takes one key per argument, so this
# types per key and handles only a-z 0-9 space and - . / = , ' [ ] \ ; `.
# Anything else (uppercase included: hc folds it to lowercase) is refused with
# nonzero before a single key is sent. Callers on hc use send_text_line.
fm_backend_hc_send_literal() {  # <target> <text> <expected-label>
  local target=$1 text=${2-} i ch ref
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
  ref=$(fm_backend_hc_ref "$target" "${3:-}" act) || return 1
  fm_backend_hc_cli keys "$ref" "${keys[@]}" >/dev/null 2>&1
}

# fm_backend_hc_kill: end one task terminal, best-effort. Refuses (nonzero,
# before ending anything) a target that is not a local `t<N>` address, a call
# with no expected label, and a terminal hc reports under any name other than
# the label (see the name guard in the header). The label is the third argument
# (fm_backend_kill's callers pass <target> <tab-id> <label>); a second argument
# that is itself an fm- name is accepted as the label too. The kill acts on the
# verified NAME; the later `rm` re-verifies the finished terminal's name first.
# A terminal already gone is success. An unreadable inventory refuses rather
# than guessing.
fm_backend_hc_kill() {  # <target> [tab-id-unused] <expected-label>
  local target=${1:-} label=${3:-} ref rc=0 i=0
  [ -n "$label" ] || { fm_backend_hc_label_valid "${2:-}" && label=$2; }
  fm_backend_hc_target_valid "$target" || { echo "error: refusing hc kill of '$target' (not a local tN address)" >&2; return 1; }
  [ -n "$label" ] || { echo "error: refusing hc kill of $target: no expected terminal name (fm-<task-id>) was supplied" >&2; return 1; }
  fm_backend_hc_verify "$target" "$label" >/dev/null || rc=$?
  [ "$rc" -ne 3 ] || return 0
  [ "$rc" -eq 0 ] || { echo "error: not killing hc terminal $target (not verified as $label)" >&2; return 1; }
  ref=$(fm_backend_hc_ref "$target" "$label" act) || { echo "error: not killing hc terminal $target" >&2; return 1; }
  fm_backend_hc_cli kill "$ref" >/dev/null 2>&1 || true
  while [ "$i" -lt 5 ]; do
    rc=0
    fm_backend_hc_verify "$target" "$label" >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 0 ] || return 0
    fm_backend_hc_cli rm "$target" >/dev/null 2>&1 && return 0
    i=$((i + 1))
    sleep 0.2
  done
  return 0
}

# fm_backend_hc_target_exists: 0 when <target> is a LIVE local terminal named
# <expected-label> (or, with no label, any `fm-` terminal). A terminal under a
# different name is not this task's endpoint, so it reads absent here.
fm_backend_hc_target_exists() {  # <target> [expected-label]
  local info
  info=$(fm_backend_hc_verify "$1" "${2:-}" 2>/dev/null) || return 1
  [ "$(printf '%s' "$info" | jq -r '.state // empty' 2>/dev/null)" = live ]
}

# fm_backend_hc_group_members: the foreground process group of <pid>, one line
# per live member: pid, comm, argv0, flattened args, separated by US (0x1f).
# Returns 1 when the group cannot be read (pid gone, ps failed, no members).
# This is the hc analogue of the tmux adapter's pty-foreground-group read:
# firstmate wraps the launch line in `/bin/sh -c ...`, so the group leader hc
# reports is the wrapper shell and the agent is its child in the same group.
# Zombies are skipped. Tests redefine this function to stage a group.
fm_backend_hc_group_members() {  # <pid>
  local pid=$1 pgid listing mpid mpgid mstat mcomm args argv0 found=0
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  pgid=$(LC_ALL=C ps -o pgid= -p "$pid" 2>/dev/null) || return 1
  pgid=${pgid//[[:space:]]/}
  [ -n "$pgid" ] || return 1
  listing=$(LC_ALL=C ps -axo pid=,pgid=,stat=,comm= 2>/dev/null) || return 1
  while read -r mpid mpgid mstat mcomm; do
    [ "$mpgid" = "$pgid" ] || continue
    case "$mstat" in Z*) continue ;; esac
    [ -n "$mcomm" ] || continue
    args=$(LC_ALL=C ps -p "$mpid" -o args= 2>/dev/null) || continue
    args=${args#"${args%%[![:space:]]*}"}
    argv0=${args%%[[:space:]]*}
    printf '%s\037%s\037%s\037%s\n' "$mpid" "$mcomm" "$argv0" "$args"
    found=1
  done <<EOF
$listing
EOF
  [ "$found" -eq 1 ]
}

# fm_backend_hc_agent_state: recovery-grade agent state for one recorded
# target; the contract (alive|dead|missing|ambiguous|unreadable) is owned by
# bin/fm-backend.sh's fm_backend_agent_state. A non-address target is
# unreadable. A definitive not_found or a non-live state is missing; a present
# terminal under a different name than <expected-label> is `ambiguous` (see the
# name guard in the header), never `dead`. Any transport or parse failure is
# unreadable, never dead, so a transient hc problem cannot license a duplicate
# agent onto a live worktree.
#
# The live verdict classifies EVERY process in the terminal's foreground process
# group with the shared classifier, not just the leader hc names, because
# fm-spawn wraps the launch in `/bin/sh -c ...` (or `unset TRACEPARENT; ...`):
# the leader is then a shell and the agent is its child. Any agent -> alive
# (positive evidence); only shells -> dead; anything else, or a group that
# cannot be read -> ambiguous.
fm_backend_hc_agent_state() {  # <target> [expected-label]
  local target=$1 info rc=0 state fg name argv0 args pid members line mpid mcomm
  local saw_shell=0 saw_other=0
  fm_backend_hc_target_valid "$target" || { printf 'unreadable'; return 0; }
  info=$(fm_backend_hc_verify "$target" "${2:-}" 2>/dev/null) || rc=$?
  case "$rc" in
    0) ;;
    3) printf 'missing'; return 0 ;;
    4) printf 'ambiguous'; return 0 ;;
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
  # The leader alone settles a positive verdict without touching the process table.
  if [ "$(fm_agent_process_classify "$name" "$argv0" "$args" "$pid")" = agent ]; then
    printf 'alive'
    return 0
  fi
  members=$(fm_backend_hc_group_members "$pid") || { printf 'ambiguous'; return 0; }
  while IFS=$'\037' read -r mpid mcomm argv0 args; do
    [ -n "$mpid" ] || continue
    case "$(fm_agent_process_classify "$mcomm" "$argv0" "$args" "$mpid")" in
      agent) printf 'alive'; return 0 ;;
      shell) saw_shell=1 ;;
      *) saw_other=1 ;;
    esac
  done <<EOF
$members
EOF
  line=ambiguous
  if [ "$saw_other" -eq 0 ] && [ "$saw_shell" -eq 1 ]; then line=dead; fi
  printf '%s' "$line"
}

# Backward-compatible three-state view; copies the tmux adapter.
fm_backend_hc_agent_alive() {  # <target> [expected-label]
  case "$(fm_backend_hc_agent_state "$@")" in
    alive) printf 'alive' ;;
    dead|missing) printf 'dead' ;;
    *) printf 'unknown' ;;
  esac
}
