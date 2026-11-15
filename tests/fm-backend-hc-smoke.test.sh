#!/usr/bin/env bash
# tests/fm-backend-hc-smoke.test.sh - LIVE smoke test for the hc session-provider
# adapter (bin/backends/hc.sh; docs/hc-backend.md). Unlike the offline suite
# (tests/fm-backend-hc.test.sh) it talks to the REAL hc server, which holds the
# operator's own terminals, so it is built around three safeguards:
#   1. It skips cleanly (SKIP, exit 0) unless HC_TERMINAL_ID is set (we are
#      running inside an hc terminal, so a server exists) and the binary and jq
#      are present. It never starts, stops, or updates a server, never touches a
#      remote machine, and never uses --on.
#   2. It creates exactly one terminal, named fm-test-smoke-<pid>. EVERY
#      destructive or typing call (send, keys, kill) goes through `guarded`,
#      which re-reads `hc get` and refuses unless the address is the one this
#      test created AND its name starts with fm-test-.
#   3. A before/after `hc ls` tripwire: the set of addresses at the end must
#      equal the set at the start and no fm-test-* terminal may remain. The EXIT
#      trap cleans up through the same guard and then runs the tripwire.
# All waiting is a bounded poll that exits on timeout; there is no unbounded loop.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

skip() { printf 'SKIP: %s\n' "$1"; exit 0; }
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }

[ -n "${HC_TERMINAL_ID:-}" ] || skip "HC_TERMINAL_ID is unset (not inside an hc terminal)"
command -v jq >/dev/null 2>&1 || skip "jq not found"
command -v herdr-core >/dev/null 2>&1 || command -v hc >/dev/null 2>&1 || skip "herdr-core/hc binary not found"

export FM_BACKEND_LIB_DIR="$ROOT/bin"
# shellcheck source=bin/backends/hc.sh
. "$ROOT/bin/backends/hc.sh"
fm_backend_hc_tool_check || skip "hc adapter tool check failed"

addresses() {
  fm_backend_hc_cli ls --json 2>/dev/null | jq -r '[.terminals[].address] | sort | join(",")'
}
fm_test_names() {
  fm_backend_hc_cli ls --json 2>/dev/null | jq -r '[.terminals[] | select((.name // "") | startswith("fm-test-")) | .address] | join(",")'
}

START_SET=$(addresses)
[ -n "$START_SET" ] || skip "hc ls returned no terminals or failed; refusing to run without a baseline"
SCRATCH=$(mktemp -d) || fail "mktemp failed"
SCRATCH=$(cd "$SCRATCH" && pwd -P)
mkdir -p "$SCRATCH/a" "$SCRATCH/b"
NAME="fm-test-smoke-$$"
ADDR=''

# guarded <cmd...>: the mandatory guard for anything that types into, signals,
# or removes a terminal. Refuses unless $ADDR is the terminal this test created
# and hc reports a name starting with fm-test-.
guarded() {
  local name
  [ -n "$ADDR" ] || fail "guard: no created address yet"
  name=$(fm_backend_hc_cli get "$ADDR" --json 2>/dev/null | jq -r '.name // empty')
  case "$name" in
    fm-test-*) ;;
    *) fail "guard: refusing $* on $ADDR (name '$name' is not fm-test-*)" ;;
  esac
  "$@"
}

# poll <seconds> <cmd...>: run cmd every 0.3s until it succeeds or time runs out.
poll() {
  local limit=$1 i=0 max
  shift
  max=$((limit * 3))
  while [ "$i" -lt "$max" ]; do
    "$@" && return 0
    i=$((i + 1))
    sleep 0.3
  done
  return 1
}

cleanup() {
  local rc=$? end_set leftover
  if [ -n "$ADDR" ]; then
    # Best-effort teardown through the guard-equivalent check (no `fail` here:
    # an EXIT trap must not recurse).
    if [ "$(fm_backend_hc_cli get "$ADDR" --json 2>/dev/null | jq -r '.name // empty')" = "$NAME" ]; then
      fm_backend_hc_kill "$ADDR" >/dev/null 2>&1
    fi
  fi
  rm -rf "$SCRATCH"
  end_set=$(addresses)
  leftover=$(fm_test_names)
  if [ "$end_set" != "$START_SET" ] || [ -n "$leftover" ]; then
    printf 'not ok - tripwire: start=[%s] end=[%s] leftover fm-test=[%s]\n' "$START_SET" "$end_set" "$leftover" >&2
    exit 1
  fi
  [ "$rc" -ne 0 ] || printf 'ok - tripwire: hc ls addresses unchanged (%s), no fm-test-* terminal left\n' "$end_set"
  exit "$rc"
}
trap cleanup EXIT

# --- create_task --------------------------------------------------------------

ADDR=$(fm_backend_hc_create_task hc "$NAME" "$SCRATCH/a") || fail "create_task failed"
fm_backend_hc_target_valid "$ADDR" || fail "create_task returned a non-address: '$ADDR'"
pass "create_task created $NAME at $ADDR"

if fm_backend_hc_create_task hc "$NAME" "$SCRATCH/a" >/dev/null 2>&1; then
  fail "create_task must refuse a live duplicate name"
fi
pass "create_task refuses a live duplicate name"

fm_backend_hc_target_exists "$ADDR" || fail "target_exists should be true for the new terminal"
[ "$(fm_backend_hc_resolve_bare_selector "$NAME")" = "$ADDR" ] || fail "resolve_bare_selector did not find $NAME"
[ "$(fm_backend_hc_cli get "$ADDR" --json | jq -r '.labels.fm_task // empty')" = "${NAME#fm-}" ] || fail "label fm_task not set"
pass "target_exists, resolve_bare_selector, and the fm_task label"

# --- agent_state: idle shell => dead ------------------------------------------

state_is() { [ "$(fm_backend_hc_agent_state "$ADDR")" = "$1" ]; }
poll 10 state_is dead || fail "idle shell should be dead, got '$(fm_backend_hc_agent_state "$ADDR")'"
[ "$(fm_backend_hc_agent_alive "$ADDR")" = dead ] || fail "agent_alive of an idle shell should be dead"
pass "agent_state: idle shell reads dead"

# --- send_text_line + current_path (cd tracking) ------------------------------

path_is() { [ "$(fm_backend_hc_current_path "$ADDR")" = "$1" ]; }
poll 10 path_is "$SCRATCH/a" || fail "current_path should start at $SCRATCH/a, got '$(fm_backend_hc_current_path "$ADDR")'"
guarded fm_backend_hc_send_text_line "$ADDR" "cd $SCRATCH/b" || fail "send_text_line cd failed"
poll 10 path_is "$SCRATCH/b" || fail "current_path did not follow the cd to $SCRATCH/b (got '$(fm_backend_hc_current_path "$ADDR")')"
[ "$(fm_backend_hc_cli get "$ADDR" --json | jq -r '.cwd')" = "$SCRATCH/a" ] || fail "frozen .cwd should still be $SCRATCH/a"
pass "current_path follows cd via .foreground.cwd while .cwd stays frozen"

# --- capture ------------------------------------------------------------------

# shellcheck disable=SC2016  # the shell inside the terminal must expand the arithmetic
guarded fm_backend_hc_send_text_line "$ADDR" 'echo FM_SMOKE_$((6*7))' || fail "send_text_line echo failed"
saw_marker() { fm_backend_hc_capture "$ADDR" 40 | grep -qx 'FM_SMOKE_42'; }
poll 10 saw_marker || fail "capture never showed the echoed marker"
[ "$(fm_backend_hc_capture "$ADDR" 3 | wc -l | tr -d ' ')" -le 3 ] || fail "capture 3 returned more than 3 lines"
pass "send_text_line runs a command; capture sees its output and bounds lines"

# --- agent_state with a foreground job, send_key ------------------------------

guarded fm_backend_hc_send_text_line "$ADDR" 'sleep 60' || fail "send_text_line sleep failed"
poll 10 state_is ambiguous || fail "a foreground sleep should read ambiguous, got '$(fm_backend_hc_agent_state "$ADDR")'"
guarded fm_backend_hc_send_key "$ADDR" C-c || fail "send_key C-c failed"
poll 10 state_is dead || fail "after C-c the shell should read dead again, got '$(fm_backend_hc_agent_state "$ADDR")'"
pass "agent_state: foreground job is ambiguous; send_key C-c returns the shell to dead"

# --- send_literal + C-u -------------------------------------------------------

guarded fm_backend_hc_send_literal "$ADDR" 'echo typed-only' || fail "send_literal failed"
typed_visible() { fm_backend_hc_capture "$ADDR" 5 | grep -q 'echo typed-only'; }
poll 10 typed_visible || fail "send_literal text never appeared"
if fm_backend_hc_capture "$ADDR" 40 | grep -qx 'typed-only'; then fail "send_literal must not submit"; fi
guarded fm_backend_hc_send_key "$ADDR" C-u || fail "send_key C-u failed"
if guarded fm_backend_hc_send_literal "$ADDR" 'Upper$' 2>/dev/null; then fail "send_literal must refuse unmappable text"; fi
pass "send_literal types without submitting; C-u clears; unmappable text is refused"

# --- send_text_submit ---------------------------------------------------------

verdict=$(guarded fm_backend_hc_send_text_submit "$ADDR" 'echo submitted-ok' 2 0.3 0.3) || fail "send_text_submit errored"
case "$verdict" in
  empty|unknown) ;;
  *) fail "send_text_submit verdict '$verdict' unexpected for a shell (want empty|unknown)" ;;
esac
saw_submit() { fm_backend_hc_capture "$ADDR" 60 | grep -qx 'submitted-ok'; }
poll 10 saw_submit || fail "submitted text never ran"
[ "$(fm_backend_hc_capture "$ADDR" 120 | grep -cx 'submitted-ok')" = 1 ] || fail "submitted text must run exactly once"
pass "send_text_submit typed once and ran once (verdict=$verdict)"

# --- kill ---------------------------------------------------------------------

guarded fm_backend_hc_kill "$ADDR" || fail "kill failed"
gone() { [ "$(fm_backend_hc_agent_state "$ADDR")" = missing ]; }
poll 10 gone || fail "killed terminal should read missing, got '$(fm_backend_hc_agent_state "$ADDR")'"
if fm_backend_hc_target_exists "$ADDR"; then fail "target_exists should be false after kill"; fi
pass "kill ends and removes the terminal; agent_state reads missing"
# The EXIT trap now asserts the before/after tripwire.
