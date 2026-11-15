#!/usr/bin/env bash
# tests/fm-backend-hc.test.sh - offline unit tests for the hc (herdr-core)
# session-provider adapter (bin/backends/hc.sh; docs/hc-backend.md). A fake
# `herdr-core` shim is placed first on PATH: it logs every invocation (one line,
# unit-separated args, to $FM_HC_LOG) and answers from canned files in
# $FM_HC_RESP, so no real hc server is touched. The live counterpart is
# tests/fm-backend-hc-smoke.test.sh. jq is real (the adapter requires it).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the hc adapter)"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-backend-hc-tests)
FAKEBIN="$TMP_ROOT/fakebin"
FM_HC_RESP="$TMP_ROOT/resp"
FM_HC_LOG="$TMP_ROOT/hc.log"
export FM_HC_RESP FM_HC_LOG
mkdir -p "$FAKEBIN" "$FM_HC_RESP"

# The shim's response contract (all files under $FM_HC_RESP, all optional):
#   get.<addr>        stdout of `get <addr> --json`; absent => not_found (exit 3)
#   get.<addr>.exit   forced exit code for that get (stdout/stderr from the file)
#   ls.json / ls.exit run.json / run.exit   likewise for `ls` and `run`
#   read.<addr>[.<n>] screen text for the nth read of <addr>, else read.<addr>
#   <cmd>.exit        exit code for send/keys/kill/rm (default 0)
cat > "$FAKEBIN/herdr-core" <<'SH'
#!/usr/bin/env bash
set -u
R=${FM_HC_RESP:?}
{
  printf '%s' "${1:-}"
  shift_first=1
  for a in "$@"; do
    if [ "$shift_first" = 1 ]; then shift_first=0; continue; fi
    printf '\x1f%s' "$a"
  done
  printf '\n'
} >> "${FM_HC_LOG:?}"
cmd=${1:-}
code_of() { [ -f "$R/$1.exit" ] && cat "$R/$1.exit" || echo 0; }
case "$cmd" in
  get)
    addr=${2:-}
    if [ -f "$R/get.$addr.exit" ]; then
      [ -f "$R/get.$addr" ] && cat "$R/get.$addr"
      exit "$(cat "$R/get.$addr.exit")"
    fi
    if [ -f "$R/get.$addr" ]; then cat "$R/get.$addr"; exit 0; fi
    echo '{"error":{"kind":"not_found","message":"no terminal"}}' >&2
    exit 3
    ;;
  ls) [ -f "$R/ls.json" ] && cat "$R/ls.json"; exit "$(code_of ls)" ;;
  run) [ -f "$R/run.json" ] && cat "$R/run.json"; exit "$(code_of run)" ;;
  read)
    addr=${2:-}
    n=$(( $(cat "$R/.rc.$addr" 2>/dev/null || echo 0) + 1 ))
    echo "$n" > "$R/.rc.$addr"
    if [ -f "$R/read.$addr.$n" ]; then cat "$R/read.$addr.$n"
    elif [ -f "$R/read.$addr" ]; then cat "$R/read.$addr"
    else echo '{"error":{"kind":"not_found"}}' >&2; exit 3; fi
    exit 0
    ;;
  send|keys|kill|rm) exit "$(code_of "$cmd")" ;;
  *) exit 64 ;;
esac
SH
chmod +x "$FAKEBIN/herdr-core"

export FM_BACKEND_LIB_DIR="$ROOT/bin"
ORIG_PATH=$PATH
PATH="$FAKEBIN:$ORIG_PATH"
# shellcheck source=bin/backends/hc.sh
. "$ROOT/bin/backends/hc.sh"

reset() {
  rm -rf "$FM_HC_RESP"
  mkdir -p "$FM_HC_RESP"
  : > "$FM_HC_LOG"
}

# logline: the exact unit-separated line the shim writes for one call.
logline() { local IFS=$'\x1f'; printf '%s' "$*"; }
log_count() { grep -c "^$1" "$FM_HC_LOG" || true; }
log_has() { grep -Fxq -- "$(logline "$@")" "$FM_HC_LOG"; }
log_empty() { [ ! -s "$FM_HC_LOG" ]; }

get_json() {  # <addr> <name> <state> <fg-json>
  printf '{"address":"%s","name":"%s","state":"%s","cwd":"/frozen","foreground":%s}\n' "$1" "$2" "$3" "$4" > "$FM_HC_RESP/get.$1"
  # hc also resolves a terminal by its (unique) name; the shim mirrors that.
  [ -z "$2" ] || cp "$FM_HC_RESP/get.$1" "$FM_HC_RESP/get.$2"
}
get_json_unnamed() {  # <addr> <state> <fg-json> - real hc reports "name":null
  printf '{"address":"%s","name":null,"state":"%s","cwd":"/frozen","foreground":%s}\n' "$1" "$2" "$3" > "$FM_HC_RESP/get.$1"
}

# The process-table seam: tests stage the foreground group instead of reading ps.
# STUB_GROUP holds US-separated lines (pid, comm, argv0, args); STUB_GROUP_FAIL=1
# makes the group unreadable. The real function is restored for the real-process test.
REAL_GROUP_DEF=$(declare -f fm_backend_hc_group_members)
STUB_GROUP=
STUB_GROUP_FAIL=0
stub_group_members() {
  [ "$STUB_GROUP_FAIL" = 0 ] || return 1
  [ -n "$STUB_GROUP" ] || return 1
  printf '%s\n' "$STUB_GROUP"
}
use_stub_group() { fm_backend_hc_group_members() { stub_group_members "$@"; }; }
use_real_group() { eval "$REAL_GROUP_DEF"; }
member() {  # <pid> <comm> <argv0> <args>
  printf '%s\037%s\037%s\037%s' "$1" "$2" "$3" "$4"
}

PI_FG='{"argv":["pi","",""],"cwd":"/live","name":"node","pid":4242}'
ZSH_FG='{"argv":["/bin/zsh","-l"],"cwd":"/live","name":"zsh","pid":4243}'
SLEEP_FG='{"argv":["sleep","40"],"cwd":"/live","name":"sleep","pid":4244}'

BOX_EMPTY=$'out\n╭────────────────╮\n│ >              │\n╰────────────────╯\n'
BOX_TEXT=$'out\n╭────────────────╮\n│ > hello there  │\n╰────────────────╯\n'

test_bin_lookup() {
  local d="$TMP_ROOT/binlookup" got
  mkdir -p "$d/a" "$d/b" "$d/none"
  printf '#!/bin/sh\n' > "$d/a/herdr-core"; chmod +x "$d/a/herdr-core"
  printf '#!/bin/sh\n' > "$d/a/hc"; chmod +x "$d/a/hc"
  printf '#!/bin/sh\n' > "$d/b/hc"; chmod +x "$d/b/hc"
  got=$(PATH="$d/a" fm_backend_hc_bin) || fail "bin: herdr-core on PATH not found"
  [ "$got" = "$d/a/herdr-core" ] || fail "bin should prefer herdr-core over hc, got '$got'"
  got=$(PATH="$d/b" fm_backend_hc_bin) || fail "bin: hc fallback not found"
  [ "$got" = "$d/b/hc" ] || fail "bin should fall back to hc, got '$got'"
  if PATH="$d/none" fm_backend_hc_bin >/dev/null 2>&1; then fail "bin should return 1 when neither binary exists"; fi
  if PATH="$d/none" fm_backend_hc_tool_check >/dev/null 2>&1; then fail "tool_check should fail without a binary"; fi
  fm_backend_hc_tool_check || fail "tool_check should pass with the shim and jq"
  pass "bin prefers herdr-core, falls back to hc, fails with neither; tool_check follows"
}

test_target_valid() {
  local ok bad
  for ok in t0 t7 t12345 t1b t1c tff t0a9; do fm_backend_hc_target_valid "$ok" || fail "target_valid rejected $ok"; done
  for bad in '' t T7 t7x tt7 omarchy/t7 t7/ ../x 'fm-x' ' t7' 't 7' 't7;x' tG1 t1B 'fm-abc' 'name'; do
    if fm_backend_hc_target_valid "$bad"; then fail "target_valid accepted '$bad'"; fi
  done
  pass "target_valid accepts only local tN addresses (lowercase hex, as hc hands out t1b)"
}

test_create_task_success_passes_safe_flags() {
  local dir="$TMP_ROOT/proj" out
  mkdir -p "$dir"; reset
  printf '{"terminals":[{"address":"t3","name":"other","state":"live"}],"machines":[]}' > "$FM_HC_RESP/ls.json"
  printf '{"address":"t8","agent":"zsh","name":"fm-abc","state":"live","turn":0}' > "$FM_HC_RESP/run.json"
  out=$(fm_backend_hc_create_task hc fm-abc "$dir") || fail "create_task failed"
  [ "$out" = t8 ] || fail "create_task should print the address, got '$out'"
  log_has run --bg --json --name fm-abc --cwd "$dir" --no-parent --no-notify --label fm_task=abc \
    || fail "create_task run argv wrong: $(tr '\037' ' ' < "$FM_HC_LOG")"
  pass "create_task prints the address and always passes --no-parent --no-notify"
}

test_create_task_refuses_live_name_collision() {
  local dir="$TMP_ROOT/proj" rc=0
  mkdir -p "$dir"; reset
  printf '{"terminals":[{"address":"t3","name":"fm-abc","state":"live"}]}' > "$FM_HC_RESP/ls.json"
  printf '{"address":"t9","state":"live"}' > "$FM_HC_RESP/run.json"
  fm_backend_hc_create_task hc fm-abc "$dir" >/dev/null 2>"$TMP_ROOT/err" || rc=$?
  [ "$rc" -ne 0 ] || fail "create_task must refuse a live same-name terminal"
  grep -q 'already exists' "$TMP_ROOT/err" || fail "collision error text missing"
  [ "$(log_count run)" = 0 ] || fail "run must not be called on a name collision"
  # A finished terminal with the same name is not a collision.
  printf '{"terminals":[{"address":"t3","name":"fm-abc","state":"finished"}]}' > "$FM_HC_RESP/ls.json"
  printf '{"address":"t9","state":"live"}' > "$FM_HC_RESP/run.json"
  fm_backend_hc_create_task hc fm-abc "$dir" >/dev/null || fail "finished same-name terminal must not block create"
  pass "create_task refuses a live name collision, ignores finished ones"
}

test_create_task_refuses_bad_results_and_inputs() {
  local dir="$TMP_ROOT/proj" rc
  mkdir -p "$dir"; reset
  printf '{"terminals":[]}' > "$FM_HC_RESP/ls.json"
  printf '{"address":"omarchy/t8"}' > "$FM_HC_RESP/run.json"
  rc=0; fm_backend_hc_create_task hc fm-abc "$dir" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "create_task must refuse a non-t address result"
  printf '{"nope":1}' > "$FM_HC_RESP/run.json"
  rc=0; fm_backend_hc_create_task hc fm-abc "$dir" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "create_task must refuse a result with no address"
  printf '{"address":"t8"}' > "$FM_HC_RESP/run.json"; echo 1 > "$FM_HC_RESP/run.exit"
  rc=0; fm_backend_hc_create_task hc fm-abc "$dir" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "create_task must propagate a run failure"
  rm -f "$FM_HC_RESP/run.exit"
  reset
  rc=0; fm_backend_hc_create_task hc 'Bad Name' "$dir" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "create_task must refuse an invalid name"
  rc=0; fm_backend_hc_create_task hc fm-abcdefghijklmnopqrstuvwxyz0123456789 "$dir" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "create_task must refuse a name over 32 chars"
  rc=0; fm_backend_hc_create_task hc fm-abc "$TMP_ROOT/does-not-exist" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "create_task must refuse a missing project directory"
  log_empty || fail "input refusals must not call hc"
  printf '{"terminals":[]}' > "$FM_HC_RESP/ls.json"; echo 1 > "$FM_HC_RESP/ls.exit"
  rc=0; fm_backend_hc_create_task hc fm-abc "$dir" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "create_task must refuse when the listing fails"
  [ "$(log_count run)" = 0 ] || fail "run must not be called when the listing fails"
  pass "create_task refuses non-local, missing, failed, and invalid cases"
}

test_kill_refuses_non_local_addresses_before_calling_hc() {
  local bad rc
  reset
  for bad in t7/../x omarchy/t7 '' t 'name' 't7x' '../x'; do
    rc=0; fm_backend_hc_kill "$bad" >/dev/null 2>&1 || rc=$?
    [ "$rc" -ne 0 ] || fail "kill must refuse '$bad'"
  done
  log_empty || fail "kill refusals must not invoke hc: $(tr '\037' ' ' < "$FM_HC_LOG")"
  pass "kill refuses non-tN targets without calling hc"
}

test_kill_guards_on_task_name_and_cleans_up() {
  local rc
  reset
  # Unnamed and foreign-named terminals are refused (M2), whatever the address.
  get_json_unnamed t7 live "$ZSH_FG"
  rc=0; fm_backend_hc_kill t7 '' fm-abc >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "kill must refuse an UNNAMED terminal"
  get_json t7 captain-shell live "$ZSH_FG"
  rc=0; fm_backend_hc_kill t7 '' fm-abc >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "kill must refuse a terminal whose name is not the expected label"
  get_json t7 fm-other live "$ZSH_FG"
  rc=0; fm_backend_hc_kill t7 '' fm-task1 >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "kill must refuse an fm- terminal that belongs to a DIFFERENT task"
  [ "$(log_count kill)" = 0 ] && [ "$(log_count rm)" = 0 ] || fail "no kill or rm for a mismatched terminal"
  rc=0; fm_backend_hc_kill t7 >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "kill must refuse when no expected label is supplied"
  [ "$(log_count kill)" = 0 ] || fail "no kill without a label"
  reset
  get_json t8 fm-abc live "$ZSH_FG"
  fm_backend_hc_kill t8 '' fm-abc || fail "kill of the expected terminal failed"
  log_has kill fm-abc || fail "kill must act on the verified NAME, log: $(tr '\037' ' ' < "$FM_HC_LOG")"
  log_has rm t8 || fail "kill did not call hc rm t8"
  reset
  get_json t8 fm-abc live "$ZSH_FG"
  fm_backend_hc_kill t8 fm-abc || fail "a label passed as the second argument is accepted"
  log_has kill fm-abc || fail "second-argument label kill"
  # The address was renumbered: the recorded address now holds ANOTHER fm- terminal.
  reset
  get_json t8 fm-zzz live "$ZSH_FG"
  rc=0; fm_backend_hc_kill t8 '' fm-abc >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] && [ "$(log_count kill)" = 0 ] || fail "renumbered address must not be killed"
  # The name resolves to a different address than the recorded one.
  reset
  get_json t8 fm-abc live "$ZSH_FG"
  get_json t9 fm-abc live "$ZSH_FG"
  rc=0; fm_backend_hc_kill t8 '' fm-abc >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] && [ "$(log_count kill)" = 0 ] || fail "a name that maps elsewhere must refuse the kill"
  reset
  rc=0; fm_backend_hc_kill t9 '' fm-abc || rc=$?
  [ "$rc" -eq 0 ] || fail "kill of an already-gone terminal is success"
  [ "$(log_count kill)" = 0 ] || fail "must not kill a not_found terminal"
  reset
  get_json t8 fm-abc live "$ZSH_FG"; echo 7 > "$FM_HC_RESP/get.t8.exit"
  rc=0; fm_backend_hc_kill t8 '' fm-abc >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "kill must refuse when the terminal cannot be read"
  [ "$(log_count kill)" = 0 ] || fail "must not kill an unreadable terminal"
  reset
  rc=0; fm_backend_hc_kill t8 '' 't9' >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "a label that is an address must be refused"
  pass "kill requires the exact expected name, acts on the name, tolerates gone terminals"
}

test_actions_refuse_unexpected_names_before_sending_input() {
  local rc v name
  # M2 reproductions: unnamed t7; fm-other for task1; address renumbered.
  for name in unnamed other renumbered; do
    reset
    case "$name" in
      unnamed) get_json_unnamed t7 live "$ZSH_FG" ;;
      other) get_json t7 fm-other live "$ZSH_FG" ;;
      renumbered) get_json t7 fm-task1 live "$PI_FG"; get_json t9 fm-task1 live "$PI_FG" ;;  # t7 verifies, but the name now maps to t9
    esac
    rc=0; fm_backend_hc_send_key t7 Enter fm-task1 >/dev/null 2>&1 || rc=$?
    [ "$rc" -ne 0 ] || fail "send_key into $name terminal must be refused"
    rc=0; fm_backend_hc_send_text_line t7 'rm -rf x' fm-task1 >/dev/null 2>&1 || rc=$?
    [ "$rc" -ne 0 ] || fail "send_text_line into $name terminal must be refused"
    rc=0; fm_backend_hc_send_literal t7 'ls' fm-task1 >/dev/null 2>&1 || rc=$?
    [ "$rc" -ne 0 ] || fail "send_literal into $name terminal must be refused"
    v=$(fm_backend_hc_send_text_submit t7 'steer' 3 0 0 fm-task1 2>/dev/null)
    [ "$v" = send-failed ] || fail "send_text_submit into $name terminal must report send-failed, got '$v'"
    if fm_backend_hc_capture t7 20 fm-task1 >/dev/null 2>&1; then fail "capture of $name terminal must be refused"; fi
    [ "$(log_count send)" = 0 ] && [ "$(log_count keys)" = 0 ] && [ "$(log_count read)" = 0 ] \
      || fail "$name terminal received hc input/reads: $(tr '\037' ' ' < "$FM_HC_LOG")"
    [ "$name" = renumbered ] && continue
    [ "$(fm_backend_hc_agent_state t7 fm-task1)" = ambiguous ] || fail "$name terminal must read ambiguous, never dead"
    if fm_backend_hc_target_exists t7 fm-task1; then fail "target_exists must be false for $name terminal"; fi
  done
  # No label at all: every action refuses; read-only calls require an fm- prefix.
  reset
  get_json t8 fm-abc live "$ZSH_FG"
  rc=0; fm_backend_hc_send_key t8 Enter >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "send_key without a label must be refused"
  rc=0; fm_backend_hc_send_text_line t8 x >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "send_text_line without a label must be refused"
  v=$(fm_backend_hc_send_text_submit t8 x 3 0 0 2>/dev/null)
  [ "$v" = send-failed ] || fail "send_text_submit without a label must report send-failed, got '$v'"
  [ "$(log_count send)" = 0 ] && [ "$(log_count keys)" = 0 ] || fail "label-less actions must send nothing"
  get_json_unnamed t7 live "$ZSH_FG"
  [ "$(fm_backend_hc_agent_state t7)" = ambiguous ] || fail "unnamed terminal with no label must read ambiguous"
  get_json t7 captain live "$ZSH_FG"
  [ "$(fm_backend_hc_agent_state t7)" = ambiguous ] || fail "non-fm terminal with no label must read ambiguous"
  # A definitively absent address stays `missing`.
  rm -f "$FM_HC_RESP/get.t7"
  [ "$(fm_backend_hc_agent_state t7 fm-task1)" = missing ] || fail "not_found must read missing"
  # The matching terminal receives input, addressed by NAME.
  reset
  get_json t7 fm-task1 live "$ZSH_FG"
  fm_backend_hc_send_text_line t7 'echo hi' fm-task1 || fail "send_text_line to the expected terminal failed"
  log_has send fm-task1 -- 'echo hi' || fail "text must go to the NAME, log: $(tr '\037' ' ' < "$FM_HC_LOG")"
  pass "every input/read action is refused for unnamed, foreign, renumbered, or label-less terminals before hc is asked to act"
}

test_send_key_mapping() {
  local pair k want
  get_json t8 fm-abc live "$ZSH_FG"
  for pair in Enter:enter Escape:esc Esc:esc C-c:ctrl+c C-u:ctrl+u Tab:tab Up:up Space:space BSpace:backspace f5:f5; do
    k=${pair%%:*}; want=${pair#*:}
    : > "$FM_HC_LOG"
    fm_backend_hc_send_key t8 "$k" fm-abc || fail "send_key $k failed"
    log_has keys fm-abc "$want" || fail "send_key $k should press '$want' on the NAME, log: $(tr '\037' ' ' < "$FM_HC_LOG")"
  done
  : > "$FM_HC_LOG"
  if fm_backend_hc_send_key omarchy/t8 Enter fm-abc; then fail "send_key must refuse a remote target"; fi
  if fm_backend_hc_send_key t8 '' fm-abc; then fail "send_key must refuse an empty key"; fi
  [ "$(log_count keys)" = 0 ] || fail "send_key refusals must press nothing"
  echo 11 > "$FM_HC_RESP/keys.exit"
  if fm_backend_hc_send_key t8 Enter fm-abc; then fail "send_key must propagate an hc failure"; fi
  pass "send_key maps Enter/Escape/C-c/C-u and refuses bad targets"
}

test_capture_bounds_lines() {
  local out
  reset
  get_json t8 fm-abc live "$ZSH_FG"
  printf 'l1\nl2\nl3\nl4\nl5\nl6\n' > "$FM_HC_RESP/read.t8"
  out=$(fm_backend_hc_capture t8 3) || fail "capture failed"
  [ "$out" = $'l4\nl5\nl6' ] || fail "capture should keep the last 3 lines, got '$out'"
  log_has read t8 --lines 3 || fail "capture should pass --lines 3 to hc read"
  out=$(fm_backend_hc_capture t8 100) || fail "capture 100 failed"
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 6 ] || fail "short screens return all lines"
  fm_backend_hc_capture t8 abc >/dev/null || fail "non-numeric lines should default"
  log_has read t8 --lines 200 || fail "non-numeric lines should default to 200"
  cp "$FM_HC_RESP/read.t8" "$FM_HC_RESP/read.fm-abc"
  fm_backend_hc_capture t8 3 fm-abc >/dev/null || fail "labelled capture failed"
  log_has read fm-abc --lines 3 || fail "labelled capture should read by NAME"
  : > "$FM_HC_LOG"
  if fm_backend_hc_capture 't8;x' 3 >/dev/null 2>&1; then fail "capture must refuse a bad target"; fi
  if fm_backend_hc_capture t8 3 fm-nope >/dev/null 2>&1; then fail "capture must refuse a different name"; fi
  get_json_unnamed t8 live "$ZSH_FG"
  if fm_backend_hc_capture t8 3 >/dev/null 2>&1; then fail "capture must refuse an unnamed terminal (a captain's private screen)"; fi
  [ "$(log_count read)" = 0 ] || fail "no screen may be read from a mismatched terminal"
  if fm_backend_hc_capture t9 3 >/dev/null 2>&1; then fail "capture must fail when the terminal is gone"; fi
  pass "capture bounds output to the last N lines, reads only name-verified terminals"
}

test_current_path_reads_foreground_cwd() {
  local out
  reset
  get_json t8 fm-abc live "$ZSH_FG"
  out=$(fm_backend_hc_current_path t8 fm-abc)
  [ "$out" = /live ] || fail "current_path should read .foreground.cwd, got '$out'"
  out=$(fm_backend_hc_current_path t8 fm-other)
  [ -z "$out" ] || fail "current_path must be empty for a different name, got '$out'"
  get_json t8 fm-abc finished null
  out=$(fm_backend_hc_current_path t8)
  [ -z "$out" ] || fail "current_path must be empty with no foreground, got '$out'"
  out=$(fm_backend_hc_current_path t9)
  [ -z "$out" ] || fail "current_path must be empty for a missing terminal"
  pass "current_path reads .foreground.cwd, never the frozen .cwd"
}

assert_state() {  # <expected> <label> [target] [expected-label]
  local want=$1 label=$2 got
  got=$(fm_backend_hc_agent_state "${3-t8}" "${4-fm-abc}")
  [ "$got" = "$want" ] || fail "agent_state $label: want $want, got '$got'"
}

test_agent_state_matrix() {
  use_stub_group
  reset
  STUB_GROUP_FAIL=0
  STUB_GROUP=$(member 4243 /bin/zsh /bin/zsh '/bin/zsh -l')
  get_json t8 fm-abc live "$ZSH_FG";   assert_state dead "idle zsh"
  get_json t8 fm-abc live "$PI_FG";    STUB_GROUP_FAIL=1; assert_state alive "pi under node (argv0) needs no ps"; STUB_GROUP_FAIL=0
  get_json t8 fm-abc live '{"argv":["/opt/bin/claude","--x"],"cwd":"/l","name":"claude","pid":1}'
  STUB_GROUP_FAIL=1; assert_state alive "claude by name"; STUB_GROUP_FAIL=0
  STUB_GROUP=$(member 4244 sleep sleep 'sleep 40')
  get_json t8 fm-abc live "$SLEEP_FG"; assert_state ambiguous "non-shell non-agent foreground"
  STUB_GROUP=$(member 2 /bin/sh /bin/sh '/bin/sh /x/script')
  get_json t8 fm-abc live '{"argv":["/bin/sh","/x/script"],"cwd":"/l","name":"bash","pid":2}'
  assert_state dead "sh script is shell-only"
  # M1: the wrapper shell leads the group and the agent is its child.
  STUB_GROUP=$(member 20 /bin/sh /bin/sh '/bin/sh -c claude --x')$'\n'$(member 21 /opt/bin/claude claude 'claude --x')
  get_json t8 fm-abc live '{"argv":["/bin/sh","-c","claude --x"],"cwd":"/l","name":"bash","pid":20}'
  assert_state alive "agent child under an sh -c wrapper leader"
  STUB_GROUP=$(member 20 /bin/sh /bin/sh '/bin/sh -c x')$'\n'$(member 21 /usr/bin/node pi 'pi')
  assert_state alive "agent argv0 child under a wrapper leader"
  STUB_GROUP=$(member 20 /bin/sh /bin/sh '/bin/sh -c x')$'\n'$(member 22 /bin/sleep sleep 'sleep 9')
  assert_state ambiguous "wrapper shell plus a non-agent child"
  STUB_GROUP=$(member 20 /bin/sh /bin/sh '/bin/sh -c x')$'\n'$(member 23 /bin/bash -bash '-bash')
  assert_state dead "only shells in the whole group"
  STUB_GROUP_FAIL=1
  assert_state ambiguous "unreadable process group is never dead"
  STUB_GROUP_FAIL=0
  # Mismatched or missing names (M2).
  get_json t8 fm-other live "$ZSH_FG";  assert_state ambiguous "different fm- name"
  get_json_unnamed t8 live "$ZSH_FG";   assert_state ambiguous "unnamed terminal"
  get_json t8 fm-abc live "$ZSH_FG"
  get_json t8 fm-abc finished null;    assert_state missing "finished"
  rm -f "$FM_HC_RESP/get.t8";          assert_state missing "not_found"
  printf 'not json' > "$FM_HC_RESP/get.t8"; assert_state unreadable "malformed JSON"
  printf '[]' > "$FM_HC_RESP/get.t8";  assert_state unreadable "non-object JSON"
  get_json t8 fm-abc live null;        assert_state unreadable "live without foreground"
  STUB_GROUP=$(member 4243 /bin/zsh /bin/zsh '/bin/zsh -l')
  get_json t8 fm-abc live "$ZSH_FG"; echo 5 > "$FM_HC_RESP/get.t8.exit"
  assert_state unreadable "nonzero exit"
  echo 3 > "$FM_HC_RESP/get.t8.exit"
  assert_state unreadable "exit 3 without a not_found body"
  rm -f "$FM_HC_RESP/get.t8.exit"
  assert_state unreadable "remote target" omarchy/t1
  assert_state unreadable "name target" fm-abc
  assert_state unreadable "empty target" ''
  get_json t8 fm-abc live "$ZSH_FG"
  get_json t1b fm-hex live "$ZSH_FG";  assert_state dead "hex address" t1b fm-hex
  get_json t8 fm-abc live "$PI_FG";     [ "$(fm_backend_hc_agent_alive t8 fm-abc)" = alive ] || fail "agent_alive alive"
  get_json t8 fm-abc live "$ZSH_FG";    [ "$(fm_backend_hc_agent_alive t8 fm-abc)" = dead ] || fail "agent_alive dead"
  rm -f "$FM_HC_RESP/get.t8";           [ "$(fm_backend_hc_agent_alive t8 fm-abc)" = dead ] || fail "agent_alive missing -> dead"
  get_json t8 fm-abc live "$SLEEP_FG"
  STUB_GROUP=$(member 4244 sleep sleep 'sleep 40')
  [ "$(fm_backend_hc_agent_alive t8 fm-abc)" = unknown ] || fail "agent_alive ambiguous -> unknown"
  printf 'x' > "$FM_HC_RESP/get.t8";     [ "$(fm_backend_hc_agent_alive t8 fm-abc)" = unknown ] || fail "agent_alive unreadable -> unknown"
  use_real_group
  pass "agent_state: dead/alive/missing/ambiguous/unreadable matrix (never dead on failure or a foreign name)"
}

# M1 reproduced with REAL processes: a fake agent (argv[0] `claude`) that is the
# child of a `/bin/sh -c` wrapper, both in one process group led by the wrapper -
# exactly the shape fm-spawn's launch line produces. The old leader-only
# classifier read the wrapper shell and reported `dead`.
test_agent_state_real_wrapped_process_group() {
  local d="$TMP_ROOT/realgrp" pid dead_pid=0 i got fifo
  mkdir -p "$d"; reset
  use_real_group
  # wrapper sh (leader) -> bash exec'ing sleep as argv0 `claude`
  pid=$( set -m; /bin/sh -c 'bash -c "exec -a claude sleep 30"; true' </dev/null >/dev/null 2>&1 & echo $! )
  get_json t8 fm-abc live "{\"argv\":[\"/bin/sh\",\"-c\",\"x\"],\"cwd\":\"/l\",\"name\":\"sh\",\"pid\":$pid}"
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    got=$(fm_backend_hc_group_members "$pid" | wc -l | tr -d ' ')
    [ "${got:-0}" -ge 2 ] && break
    sleep 0.25
  done
  [ "${got:-0}" -ge 2 ] || fail "test setup: wrapper group never showed 2 members ($(fm_backend_hc_group_members "$pid" | tr '\037' ' '))"
  [ "$(fm_backend_hc_agent_state t8 fm-abc)" = alive ] \
    || fail "M1: agent child of an sh -c wrapper must read alive, got $(fm_backend_hc_agent_state t8 fm-abc)"
  kill -TERM -"$pid" 2>/dev/null
  # A group that is only an idle shell (blocked on a fifo read) reads dead.
  fifo="$d/f"; mkfifo "$fifo"
  dead_pid=$( set -m; bash -c 'exec 3<>"$1"; read -t 60 -u 3 x' _ "$fifo" </dev/null >/dev/null 2>&1 & echo $! )
  get_json t8 fm-abc live "{\"argv\":[\"bash\"],\"cwd\":\"/l\",\"name\":\"bash\",\"pid\":$dead_pid}"
  sleep 0.5
  [ "$(fm_backend_hc_agent_state t8 fm-abc)" = dead ] || fail "an idle-shell-only group must read dead, got $(fm_backend_hc_agent_state t8 fm-abc)"
  # The leader is gone entirely: the group is unreadable, never dead.
  kill -TERM "$dead_pid" 2>/dev/null; dead_pid=0; sleep 0.5
  [ "$(fm_backend_hc_agent_state t8 fm-abc)" = ambiguous ] || fail "a vanished group must read ambiguous, got $(fm_backend_hc_agent_state t8 fm-abc)"
  pass "agent_state classifies the whole foreground group with real processes (sh -c wrapper -> alive)"
}

test_target_exists() {
  reset
  get_json t8 fm-abc live "$ZSH_FG"
  fm_backend_hc_target_exists t8 fm-abc || fail "target_exists: live terminal"
  fm_backend_hc_target_exists t8 || fail "target_exists: live fm- terminal with no label"
  if fm_backend_hc_target_exists t8 fm-other; then fail "target_exists: other name"; fi
  get_json_unnamed t8 live "$ZSH_FG"
  if fm_backend_hc_target_exists t8; then fail "target_exists: unnamed terminal"; fi
  get_json t8 fm-abc finished null
  if fm_backend_hc_target_exists t8 fm-abc; then fail "target_exists: finished terminal"; fi
  if fm_backend_hc_target_exists t9 fm-abc; then fail "target_exists: not found"; fi
  if fm_backend_hc_target_exists omarchy/t8 fm-abc; then fail "target_exists: remote"; fi
  pass "target_exists is true only for a live, name-verified local terminal"
}

test_send_text_line_and_literal() {
  # shellcheck disable=SC2016  # literal $HOME is the point: it must reach hc unexpanded
  local dollar_text='echo "hi" $HOME'
  reset
  get_json t8 fm-abc live "$ZSH_FG"
  fm_backend_hc_send_text_line t8 "$dollar_text" fm-abc || fail "send_text_line failed"
  log_has send fm-abc -- "$dollar_text" || fail "send_text_line should paste via hc send --"
  : > "$FM_HC_LOG"
  fm_backend_hc_send_text_line t8 '-n lead dash' fm-abc >/dev/null || fail "dash text"
  log_has send fm-abc -- '-n lead dash' || fail "leading-dash text must follow --"
  if fm_backend_hc_send_text_line omarchy/t8 x fm-abc; then fail "send_text_line must refuse remote"; fi
  : > "$FM_HC_LOG"
  fm_backend_hc_send_literal t8 "ls -la/x='y';" fm-abc || fail "send_literal of mappable text failed"
  log_has keys fm-abc l s space - l a / x = "'" y "'" ';' || fail "send_literal key list wrong: $(tr '\037' ' ' < "$FM_HC_LOG")"
  : > "$FM_HC_LOG"
  if fm_backend_hc_send_literal t8 'Echo' fm-abc 2>/dev/null; then fail "send_literal must refuse uppercase"; fi
  # shellcheck disable=SC2016
  if fm_backend_hc_send_literal t8 'a$b' fm-abc 2>/dev/null; then fail "send_literal must refuse \$"; fi
  if fm_backend_hc_send_literal t8 'a_b' fm-abc 2>/dev/null; then fail "send_literal must refuse _"; fi
  [ "$(log_count keys)" = 0 ] || fail "send_literal refusals must send no keys"
  pass "send_text_line pastes after --, send_literal types per key and refuses the rest"
}

test_send_text_submit_types_once_and_retries_enter_only() {
  local v
  reset
  get_json t8 fm-abc live "$ZSH_FG"
  printf '%s' "$BOX_TEXT" > "$FM_HC_RESP/read.fm-abc.1"
  printf '%s' "$BOX_EMPTY" > "$FM_HC_RESP/read.fm-abc.2"
  printf '%s' "$BOX_EMPTY" > "$FM_HC_RESP/read.fm-abc"
  v=$(fm_backend_hc_send_text_submit t8 'hello there' 3 0 0 fm-abc) || fail "submit failed"
  [ "$v" = empty ] || fail "submit verdict should be empty after the retry, got '$v'"
  [ "$(log_count send)" = 1 ] || fail "text must be sent exactly once"
  if [ "$(log_count keys)" != 1 ] || ! log_has keys fm-abc enter; then fail "one Enter retry expected"; fi
  reset
  get_json t8 fm-abc live "$ZSH_FG"
  printf '%s' "$BOX_TEXT" > "$FM_HC_RESP/read.fm-abc"
  v=$(fm_backend_hc_send_text_submit t8 'hello there' 3 0 0 fm-abc)
  [ "$v" = pending ] || fail "stuck composer should report pending, got '$v'"
  [ "$(log_count send)" = 1 ] || fail "never retype: sends=$(log_count send)"
  [ "$(log_count keys)" = 3 ] || fail "exactly <retries> Enter retries expected, got $(log_count keys)"
  reset
  get_json t8 fm-abc live "$ZSH_FG"
  printf '%s' "$BOX_EMPTY" > "$FM_HC_RESP/read.fm-abc"
  v=$(fm_backend_hc_send_text_submit t8 'x' 3 0 0 fm-abc)
  [ "$v" = empty ] && [ "$(log_count keys)" = 0 ] || fail "a cleared composer needs no extra Enter (v=$v)"
  reset
  get_json t8 fm-abc live "$ZSH_FG"
  echo 9 > "$FM_HC_RESP/send.exit"
  v=$(fm_backend_hc_send_text_submit t8 'x' 3 0 0 fm-abc)
  [ "$v" = send-failed ] && [ "$(log_count keys)" = 0 ] || fail "send failure => send-failed, no Enter (v=$v)"
  reset
  v=$(fm_backend_hc_send_text_submit omarchy/t8 'x' 3 0 0 fm-abc)
  if [ "$v" != unknown ] || ! log_empty; then fail "remote target => unknown without calling hc (v=$v)"; fi
  reset
  get_json t8 fm-abc live "$ZSH_FG"
  printf 'plain shell $ \n' > "$FM_HC_RESP/read.fm-abc"
  v=$(fm_backend_hc_send_text_submit t8 'x' 3 0 0 fm-abc)
  [ "$v" = unknown ] && [ "$(log_count keys)" = 0 ] || fail "unreadable composer => unknown with no blind Enter (v=$v)"
  pass "send_text_submit types once, retries Enter only, returns the shared verdicts"
}

test_misc_contracts() {
  local out
  [ "$(fm_backend_hc_container_ensure)" = hc ] || fail "container_ensure should print hc"
  reset
  printf '{"terminals":[{"address":"omarchy/t1","name":"fm-q","state":"live"},{"address":"t4","name":"fm-q","state":"finished"},{"address":"t5","name":"fm-q","state":"live"}]}' > "$FM_HC_RESP/ls.json"
  out=$(fm_backend_hc_resolve_bare_selector fm-q) || fail "resolve_bare_selector failed"
  [ "$out" = t5 ] || fail "resolve should pick the live local terminal, got '$out'"
  if fm_backend_hc_resolve_bare_selector fm-nope 2>/dev/null; then fail "unknown name must fail"; fi
  pass "container_ensure and resolve_bare_selector contracts"
}

test_bin_lookup
test_target_valid
test_create_task_success_passes_safe_flags
test_create_task_refuses_live_name_collision
test_create_task_refuses_bad_results_and_inputs
test_kill_refuses_non_local_addresses_before_calling_hc
test_kill_guards_on_task_name_and_cleans_up
test_actions_refuse_unexpected_names_before_sending_input
test_send_key_mapping
test_capture_bounds_lines
test_current_path_reads_foreground_cwd
test_agent_state_matrix
test_agent_state_real_wrapped_process_group
test_target_exists
test_send_text_line_and_literal
test_send_text_submit_types_once_and_retries_enter_only
test_misc_contracts
