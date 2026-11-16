#!/usr/bin/env bash
# fm-spawn.sh on the hc backend: an aborted spawn closes the terminal it
# created, so a retry of the same task id is not refused as a duplicate.
#
# An hc terminal outlives the process that created it, and
# fm_backend_hc_create_task refuses a live duplicate label. spawn_abort_cleanup
# therefore closes the terminal this run created through the guarded kill, but
# only while no task record exists and only while the terminal still carries
# this task's labels. Once the record is published the record owns the
# terminal, and an abort leaves it for teardown and recovery.
#
# Canned/stateful fakes only - never a real hc core, a real pool, or a real
# project.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-hc-abort)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)

# make_hc_case <name>: a home, a project, and a clean leased task copy. The
# fake hc keeps one terminal in <fake>/t1.json whose labels come from `hc run`;
# a `treehouse get` line sent to it moves its foreground cwd into the copy,
# which is what the real shell would do. Every call is logged.
make_hc_case() {
  local name=$1 dir home proj wt d fb
  dir="$TMP_ROOT/$name"
  home="$dir/home"
  proj="$dir/project"
  wt="$dir/slot"
  d="$dir/fake"
  fb="$dir/fakebin"
  mkdir -p "$d" "$fb" "$dir/user-home"
  fm_test_spawn_home "$home" codex
  fm_git_init_commit "$proj"
  git clone -q "$proj" "$wt"
  fm_test_spawn_brief "$home" "$name" "Exercise the hc abort cleanup for $name."
  : > "$d/log"
  printf '%s' "$proj" > "$d/cwd"
  cat > "$fb/hc" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
{ for a in "$@"; do printf '%s ' "$a"; done; printf '\n'; } >> "$D/log"
cmd=${1:-}
case "$cmd" in
  --version) printf 'hc 0.1.21\n' ;;
  server) printf '{"live":0}\n' ;;
  connect) IFS= read -r _req || true; printf '{"jsonrpc":"2.0","id":1,"result":{"generation":1}}\n' ;;
  ls)
    if [ -f "$D/t1.json" ]; then printf '{"terminals":[{"address":"t1"}]}\n'; else printf '{"terminals":[]}\n'; fi ;;
  run)
    task=; home=
    for a in "$@"; do
      case "$a" in
        firstmate.task=*) task=${a#firstmate.task=} ;;
        firstmate.home=*) home=${a#firstmate.home=} ;;
      esac
    done
    jq -n --arg t "$task" --arg h "$home" '{address: "t1", state: "live",
      labels: {"firstmate.task": $t, "firstmate.home": $h}}' > "$D/t1.json"
    printf '{"address":"t1"}\n' ;;
  get)
    [ -f "$D/t1.json" ] || { printf '{"error":{"kind":"not_found"}}\n' >&2; exit 3; }
    jq --arg c "$(cat "$D/cwd")" '. + {foreground: {name: "zsh", argv: ["/bin/zsh"], cwd: $c, pid: 1}}' "$D/t1.json" \
      | if [ -f "$D/stripped" ]; then jq '.labels = {}'; else cat; fi ;;
  read) printf 'screen\n' ;;
  keys) printf '{}\n' ;;
  send)
    last=
    for a in "$@"; do last=$a; done
    case "$last" in
      'treehouse get')
        printf '%s' "$FM_FAKE_SLOT" > "$D/cwd"
        [ ! -f "$D/strip-labels-after-get" ] || : > "$D/stripped" ;;
      '. '*launch*.sh*)
        [ ! -f "$D/launch-send-fails" ] || exit 1 ;;
    esac
    printf '{"started":true,"wait":{"status":"working"}}\n' ;;
  kill) : > "$D/killed"; printf '{}\n' ;;
  rm) rm -f "$D/t1.json"; : > "$D/removed"; printf '{}\n' ;;
  *) printf '{}\n' ;;
esac
SH
  cat > "$fb/treehouse" <<'SH'
#!/usr/bin/env bash
case "$*" in
  'get --lease '*) printf '%s\n' "$FM_FAKE_SLOT" ;;
esac
exit 0
SH
  chmod +x "$fb/hc" "$fb/treehouse"
  fm_test_fake_sleep_noop "$fb"
  printf '%s\n' "$dir"
}

run_hc_spawn() {  # <case-dir> <id> [extra spawn args...]
  local dir=$1 id=$2
  shift 2
  env -u HC_TERMINAL_ID -u HC_TERMINAL_SOCKET -u HC_SCOPE -u HC_SOCKET -u HERDR_ENV \
    PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    FM_FAKE_SLOT="$dir/slot" FM_HC_BIN="$dir/fakebin/hc" HC_SESSION=fmtest \
    HOME="$dir/user-home" CLAUDE_CONFIG_DIR='' FM_SPAWN_NO_GUARD=1 \
    "$SPAWN" "$id" "$dir/project" --backend hc --mode no-mistakes --yolo off "$@" 2>&1
}

# count_calls <case-dir> <verb>: how many times the fake hc ran <verb>.
count_calls() {
  grep -c "^$2 " "$1/fake/log" || true
}

test_abort_before_the_record_closes_the_created_terminal() {
  local id=hc-abort-open dir out status
  dir=$(make_hc_case "$id")
  echo dirty >> "$dir/slot/README.md"
  out=$(run_hc_spawn "$dir" "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn launched into a dirty leased copy"$'\n'"$out"
  [ ! -e "$dir/home/state/$id.meta" ] || fail "the aborted spawn published a task record"
  [ "$(count_calls "$dir" run)" = 1 ] || fail "the spawn did not create exactly one terminal"$'\n'"$out"
  [ "$(count_calls "$dir" kill)" = 1 ] || fail "the abort did not close the created terminal exactly once"$'\n'"$out"
  [ ! -e "$dir/fake/t1.json" ] || fail "the aborted spawn left its hc terminal behind"
  # The retry is no longer refused as a duplicate of the leftover terminal.
  out=$(run_hc_spawn "$dir" "$id")
  assert_not_contains "$out" "already exists" "a retry was refused as a duplicate of the aborted terminal"
  [ "$(count_calls "$dir" run)" = 2 ] || fail "the retry did not create its terminal"$'\n'"$out"
  pass "an aborted hc spawn closes the terminal it created, once, so a retry is not a duplicate"
}

test_abort_does_not_close_a_terminal_that_lost_its_labels() {
  local id=hc-abort-foreign dir out status
  dir=$(make_hc_case "$id")
  echo dirty >> "$dir/slot/README.md"
  # Someone else's terminal now sits behind the recorded address: the fake
  # drops the task's labels once the spawn has typed into it.
  : > "$dir/fake/strip-labels-after-get"
  out=$(run_hc_spawn "$dir" "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn launched into a dirty leased copy"$'\n'"$out"
  [ "$(count_calls "$dir" kill)" = 0 ] || fail "the abort closed a terminal that no longer carries the task's labels"$'\n'"$out"
  [ -e "$dir/fake/t1.json" ] || fail "the foreign terminal was removed"
  assert_contains "$out" "left hc terminal" "the abort did not name the terminal it left in place"
  pass "an aborted hc spawn leaves a terminal that no longer carries its labels, and says so"
}

test_abort_after_the_record_leaves_the_terminal_to_the_record() {
  local id=hc-abort-record dir out status
  dir=$(make_hc_case "$id")
  : > "$dir/fake/launch-send-fails"
  out=$(run_hc_spawn "$dir" "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded although its launch was not delivered"$'\n'"$out"
  [ "$(count_calls "$dir" run)" = 1 ] || fail "the spawn did not create exactly one terminal"$'\n'"$out"
  [ "$(count_calls "$dir" kill)" = 0 ] || fail "an abort after the record was published closed the terminal the record owns"$'\n'"$out"
  [ -e "$dir/fake/t1.json" ] || fail "the terminal of a published record was removed"
  # The spawn keeps the task's scratch root after a delivered launch.
  rm -rf "/tmp/fm-$id" "/tmp/fm-$id"+*
  pass "an abort after the task record was published leaves the terminal to the record"
}

test_abort_before_the_record_closes_the_created_terminal
test_abort_does_not_close_a_terminal_that_lost_its_labels
test_abort_after_the_record_leaves_the_terminal_to_the_record

echo "# all fm-spawn-hc-abort tests passed"
