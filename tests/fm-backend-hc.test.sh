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
  for ok in t0 t7 t12345; do fm_backend_hc_target_valid "$ok" || fail "target_valid rejected $ok"; done
  for bad in '' t T7 t7x tt7 omarchy/t7 t7/ ../x 'fm-x' ' t7' 't 7' 't7;x'; do
    if fm_backend_hc_target_valid "$bad"; then fail "target_valid accepted '$bad'"; fi
  done
  pass "target_valid accepts only local tN addresses"
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
  get_json t7 captain-shell live "$ZSH_FG"
  rc=0; fm_backend_hc_kill t7 >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "kill must refuse a terminal whose name is not fm-*"
  [ "$(log_count kill)" = 0 ] && [ "$(log_count rm)" = 0 ] || fail "no kill or rm for a non-fm terminal"
  reset
  get_json t8 fm-abc live "$ZSH_FG"
  fm_backend_hc_kill t8 || fail "kill of an fm- terminal failed"
  log_has kill t8 || fail "kill did not call hc kill t8"
  log_has rm t8 || fail "kill did not call hc rm t8"
  reset
  rc=0; fm_backend_hc_kill t9 || rc=$?
  [ "$rc" -eq 0 ] || fail "kill of an already-gone terminal is success"
  [ "$(log_count kill)" = 0 ] || fail "must not kill a not_found terminal"
  reset
  echo 7 > "$FM_HC_RESP/get.t8.exit"
  rc=0; fm_backend_hc_kill t8 >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "kill must refuse when the terminal cannot be read"
  [ "$(log_count kill)" = 0 ] || fail "must not kill an unreadable terminal"
  pass "kill checks the fm- name, tolerates gone terminals, refuses unreadable ones"
}

test_send_key_mapping() {
  local pair k want
  for pair in Enter:enter Escape:esc Esc:esc C-c:ctrl+c C-u:ctrl+u Tab:tab Up:up Space:space BSpace:backspace f5:f5; do
    k=${pair%%:*}; want=${pair#*:}
    reset
    fm_backend_hc_send_key t8 "$k" extra-label || fail "send_key $k failed"
    log_has keys t8 "$want" || fail "send_key $k should press '$want', log: $(tr '\037' ' ' < "$FM_HC_LOG")"
  done
  reset
  if fm_backend_hc_send_key omarchy/t8 Enter; then fail "send_key must refuse a remote target"; fi
  if fm_backend_hc_send_key t8 ''; then fail "send_key must refuse an empty key"; fi
  log_empty || fail "send_key refusals must not call hc"
  echo 11 > "$FM_HC_RESP/keys.exit"
  if fm_backend_hc_send_key t8 Enter; then fail "send_key must propagate an hc failure"; fi
  pass "send_key maps Enter/Escape/C-c/C-u and refuses bad targets"
}

test_capture_bounds_lines() {
  local out
  reset
  printf 'l1\nl2\nl3\nl4\nl5\nl6\n' > "$FM_HC_RESP/read.t8"
  out=$(fm_backend_hc_capture t8 3) || fail "capture failed"
  [ "$out" = $'l4\nl5\nl6' ] || fail "capture should keep the last 3 lines, got '$out'"
  log_has read t8 --lines 3 || fail "capture should pass --lines 3 to hc read"
  out=$(fm_backend_hc_capture t8 100) || fail "capture 100 failed"
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 6 ] || fail "short screens return all lines"
  fm_backend_hc_capture t8 abc >/dev/null || fail "non-numeric lines should default"
  log_has read t8 --lines 200 || fail "non-numeric lines should default to 200"
  reset
  if fm_backend_hc_capture 't8;x' 3 >/dev/null 2>&1; then fail "capture must refuse a bad target"; fi
  if fm_backend_hc_capture t9 3 >/dev/null 2>&1; then fail "capture must fail when hc read fails"; fi
  pass "capture bounds output to the last N lines and refuses bad targets"
}

test_current_path_reads_foreground_cwd() {
  local out
  reset
  get_json t8 fm-abc live "$ZSH_FG"
  out=$(fm_backend_hc_current_path t8 fm-abc)
  [ "$out" = /live ] || fail "current_path should read .foreground.cwd, got '$out'"
  get_json t8 fm-abc finished null
  out=$(fm_backend_hc_current_path t8)
  [ -z "$out" ] || fail "current_path must be empty with no foreground, got '$out'"
  out=$(fm_backend_hc_current_path t9)
  [ -z "$out" ] || fail "current_path must be empty for a missing terminal"
  pass "current_path reads .foreground.cwd, never the frozen .cwd"
}

assert_state() {  # <expected> <label> [target]
  local want=$1 label=$2 got
  got=$(fm_backend_hc_agent_state "${3-t8}")
  [ "$got" = "$want" ] || fail "agent_state $label: want $want, got '$got'"
}

test_agent_state_matrix() {
  reset
  get_json t8 fm-abc live "$ZSH_FG";   assert_state dead "idle zsh"
  get_json t8 fm-abc live "$PI_FG";    assert_state alive "pi under node (argv0)"
  get_json t8 fm-abc live '{"argv":["/opt/bin/claude","--x"],"cwd":"/l","name":"claude","pid":1}'
  assert_state alive "claude by name"
  get_json t8 fm-abc live "$SLEEP_FG"; assert_state ambiguous "non-shell non-agent foreground"
  get_json t8 fm-abc live '{"argv":["/bin/sh","/x/script"],"cwd":"/l","name":"bash","pid":2}'
  assert_state dead "sh script is shell-only"
  get_json t8 fm-abc finished null;    assert_state missing "finished"
  rm -f "$FM_HC_RESP/get.t8";          assert_state missing "not_found"
  printf 'not json' > "$FM_HC_RESP/get.t8"; assert_state unreadable "malformed JSON"
  printf '[]' > "$FM_HC_RESP/get.t8";  assert_state unreadable "non-object JSON"
  get_json t8 fm-abc live null;        assert_state unreadable "live without foreground"
  get_json t8 fm-abc live "$ZSH_FG"; echo 5 > "$FM_HC_RESP/get.t8.exit"
  assert_state unreadable "nonzero exit"
  echo 3 > "$FM_HC_RESP/get.t8.exit"
  assert_state unreadable "exit 3 without a not_found body"
  rm -f "$FM_HC_RESP/get.t8.exit"
  assert_state unreadable "remote target" omarchy/t1
  assert_state unreadable "name target" fm-abc
  assert_state unreadable "empty target" ''
  get_json t8 fm-abc live "$PI_FG";     [ "$(fm_backend_hc_agent_alive t8)" = alive ] || fail "agent_alive alive"
  get_json t8 fm-abc live "$ZSH_FG";    [ "$(fm_backend_hc_agent_alive t8)" = dead ] || fail "agent_alive dead"
  rm -f "$FM_HC_RESP/get.t8";           [ "$(fm_backend_hc_agent_alive t8)" = dead ] || fail "agent_alive missing -> dead"
  get_json t8 fm-abc live "$SLEEP_FG";  [ "$(fm_backend_hc_agent_alive t8)" = unknown ] || fail "agent_alive ambiguous -> unknown"
  printf 'x' > "$FM_HC_RESP/get.t8";     [ "$(fm_backend_hc_agent_alive t8)" = unknown ] || fail "agent_alive unreadable -> unknown"
  pass "agent_state: dead/alive/missing/ambiguous/unreadable matrix (never dead on failure)"
}

test_target_exists() {
  reset
  get_json t8 fm-abc live "$ZSH_FG"
  fm_backend_hc_target_exists t8 || fail "target_exists: live terminal"
  get_json t8 fm-abc finished null
  if fm_backend_hc_target_exists t8; then fail "target_exists: finished terminal"; fi
  if fm_backend_hc_target_exists t9; then fail "target_exists: not found"; fi
  if fm_backend_hc_target_exists omarchy/t8; then fail "target_exists: remote"; fi
  pass "target_exists is true only for a live local terminal"
}

test_send_text_line_and_literal() {
  # shellcheck disable=SC2016  # literal $HOME is the point: it must reach hc unexpanded
  local dollar_text='echo "hi" $HOME'
  reset
  fm_backend_hc_send_text_line t8 "$dollar_text" label || fail "send_text_line failed"
  log_has send t8 -- "$dollar_text" || fail "send_text_line should paste via hc send --"
  reset
  fm_backend_hc_send_text_line t8 '-n lead dash' >/dev/null || fail "dash text"
  log_has send t8 -- '-n lead dash' || fail "leading-dash text must follow --"
  if fm_backend_hc_send_text_line omarchy/t8 x; then fail "send_text_line must refuse remote"; fi
  reset
  fm_backend_hc_send_literal t8 "ls -la/x='y';" || fail "send_literal of mappable text failed"
  log_has keys t8 l s space - l a / x = "'" y "'" ';' || fail "send_literal key list wrong: $(tr '\037' ' ' < "$FM_HC_LOG")"
  reset
  if fm_backend_hc_send_literal t8 'Echo' 2>/dev/null; then fail "send_literal must refuse uppercase"; fi
  # shellcheck disable=SC2016
  if fm_backend_hc_send_literal t8 'a$b' 2>/dev/null; then fail "send_literal must refuse \$"; fi
  if fm_backend_hc_send_literal t8 'a_b' 2>/dev/null; then fail "send_literal must refuse _"; fi
  log_empty || fail "send_literal refusals must send no keys"
  pass "send_text_line pastes after --, send_literal types per key and refuses the rest"
}

test_send_text_submit_types_once_and_retries_enter_only() {
  local v
  reset
  printf '%s' "$BOX_TEXT" > "$FM_HC_RESP/read.t8.1"
  printf '%s' "$BOX_EMPTY" > "$FM_HC_RESP/read.t8.2"
  printf '%s' "$BOX_EMPTY" > "$FM_HC_RESP/read.t8"
  v=$(fm_backend_hc_send_text_submit t8 'hello there' 3 0 0) || fail "submit failed"
  [ "$v" = empty ] || fail "submit verdict should be empty after the retry, got '$v'"
  [ "$(log_count send)" = 1 ] || fail "text must be sent exactly once"
  if [ "$(log_count keys)" != 1 ] || ! log_has keys t8 enter; then fail "one Enter retry expected"; fi
  reset
  printf '%s' "$BOX_TEXT" > "$FM_HC_RESP/read.t8"
  v=$(fm_backend_hc_send_text_submit t8 'hello there' 3 0 0)
  [ "$v" = pending ] || fail "stuck composer should report pending, got '$v'"
  [ "$(log_count send)" = 1 ] || fail "never retype: sends=$(log_count send)"
  [ "$(log_count keys)" = 3 ] || fail "exactly <retries> Enter retries expected, got $(log_count keys)"
  reset
  printf '%s' "$BOX_EMPTY" > "$FM_HC_RESP/read.t8"
  v=$(fm_backend_hc_send_text_submit t8 'x' 3 0 0)
  [ "$v" = empty ] && [ "$(log_count keys)" = 0 ] || fail "a cleared composer needs no extra Enter (v=$v)"
  reset
  echo 9 > "$FM_HC_RESP/send.exit"
  v=$(fm_backend_hc_send_text_submit t8 'x' 3 0 0)
  [ "$v" = send-failed ] && [ "$(log_count keys)" = 0 ] || fail "send failure => send-failed, no Enter (v=$v)"
  reset
  v=$(fm_backend_hc_send_text_submit omarchy/t8 'x' 3 0 0)
  if [ "$v" != unknown ] || ! log_empty; then fail "remote target => unknown without calling hc (v=$v)"; fi
  reset
  printf 'plain shell $ \n' > "$FM_HC_RESP/read.t8"
  v=$(fm_backend_hc_send_text_submit t8 'x' 3 0 0)
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
test_send_key_mapping
test_capture_bounds_lines
test_current_path_reads_foreground_cwd
test_agent_state_matrix
test_target_exists
test_send_text_line_and_literal
test_send_text_submit_types_once_and_retries_enter_only
test_misc_contracts
