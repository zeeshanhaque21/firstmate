#!/usr/bin/env bash
# Regression tests for cleanup endpoint identity validation and worktree ownership.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-teardown-endpoint-safety)
REAL_TMUX=$(command -v tmux || true)

make_case() {  # <name>
  local dir=$1
  mkdir -p "$TMP_ROOT/$dir/home/state" "$TMP_ROOT/$dir/home/data" \
    "$TMP_ROOT/$dir/home/config" "$TMP_ROOT/$dir/fakebin" \
    "$TMP_ROOT/$dir/worktree" "$TMP_ROOT/$dir/project"
  git init -q "$TMP_ROOT/$dir/project"
  : > "$TMP_ROOT/$dir/worktree/sentinel"
  : > "$TMP_ROOT/$dir/runtime.log"
  cat > "$TMP_ROOT/$dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
printf 'tmux' >> "${FM_RUNTIME_LOG:?}"
printf ' <%s>' "$@" >> "${FM_RUNTIME_LOG:?}"
printf '\n' >> "${FM_RUNTIME_LOG:?}"
exit 0
SH
  # wt only records its calls: these cases are about WHICH worktree a teardown may
  # touch, so the removal itself is observed in the log rather than performed.
  cat > "$TMP_ROOT/$dir/fakebin/wt" <<'SH'
#!/usr/bin/env bash
printf 'wt' >> "${FM_RUNTIME_LOG:?}"
printf ' <%s>' "$@" >> "${FM_RUNTIME_LOG:?}"
printf '\n' >> "${FM_RUNTIME_LOG:?}"
exit 0
SH
  chmod +x "$TMP_ROOT/$dir/fakebin/tmux" "$TMP_ROOT/$dir/fakebin/wt"
  printf '%s\n' "$TMP_ROOT/$dir"
}

# Replace the case's plain worktree directory with a real linked worktree of the
# project (reached through a symlink, as a recorded path may be), so ownership and
# removal are judged on a genuine git worktree.
mark_case_as_linked_worktree() {  # <case>
  local dir=$1
  rm -rf "$dir/worktree"
  mkdir -p "$dir/linked"
  git -C "$dir/project" -c user.name=test -c user.email=test@example.invalid \
    commit --allow-empty -qm worktree-fixture
  git -C "$dir/project" worktree add -q --detach "$dir/linked/project"
  ln -s "linked/project" "$dir/worktree"
  : > "$dir/worktree/sentinel"
}

run_case() {  # <case> <id>
  local dir=$1 id=$2
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" \
  FM_RUNTIME_LOG="$dir/runtime.log" PATH="$dir/fakebin:$PATH" \
    "$TEARDOWN" "$id" --force
}

assert_refused_without_mutation() {  # <case> <id> <description>
  local dir=$1 id=$2 description=$3 rc
  set +e
  run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "$description: teardown unexpectedly succeeded"
  assert_present "$dir/home/state/$id.meta" "$description: metadata changed before refusal"
  assert_present "$dir/worktree/sentinel" "$description: worktree changed before refusal"
  [ ! -s "$dir/runtime.log" ] || fail "$description: runtime command ran before refusal: $(cat "$dir/runtime.log")"
}

test_invalid_endpoint_records_refuse_before_mutation() {
  local dir id=endpoint-a

  dir=$(make_case missing)
  fm_write_meta "$dir/home/state/$id.meta" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  assert_refused_without_mutation "$dir" "$id" "missing endpoint"

  dir=$(make_case empty)
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=" "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  assert_refused_without_mutation "$dir" "$id" "empty endpoint"

  dir=$(make_case malformed)
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=ambient-current-window" "worktree=$dir/worktree" \
    "project=$dir/project" "kind=scout"
  assert_refused_without_mutation "$dir" "$id" "malformed endpoint"

  dir=$(make_case mismatched)
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=isolated:fm-other-task" "endpoint_task_id=other-task" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  assert_refused_without_mutation "$dir" "$id" "task-mismatched endpoint"

  dir=$(make_case empty-binding)
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=isolated:fm-$id" "endpoint_task_id=" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  assert_refused_without_mutation "$dir" "$id" "empty task binding"

  dir=$(make_case duplicate-binding)
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=isolated:fm-$id" "endpoint_task_id=$id" "endpoint_task_id=$id" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  assert_refused_without_mutation "$dir" "$id" "duplicate task binding"

  pass "fm-teardown: missing, empty, malformed, ambiguous, and task-mismatched endpoints refuse before every mutation or runtime call"
}

test_control_lock_contention_refuses_before_mutation() {
  local dir id=locked-task lock holder i=0 rc
  dir=$(make_case control-lock)
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=isolated:fm-$id" "endpoint_task_id=$id" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  lock="$dir/home/state/.control-$id.lock"
  (
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$lock" || exit 1
    sleep 30
  ) &
  holder=$!
  while [ ! -e "$lock" ] && [ "$i" -lt 100 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$lock" ] || {
    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true
    fail "could not stage a held lifecycle lock"
  }
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=isolated:fm-$id" "endpoint_task_id=other-task" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"

  set +e
  run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "teardown unexpectedly succeeded under lifecycle lock contention"
  assert_present "$dir/home/state/$id.meta" "contended teardown removed task metadata"
  assert_present "$dir/worktree/sentinel" "contended teardown changed the worktree"
  assert_present "$lock" "contended teardown removed another action's lock"
  [ ! -s "$dir/runtime.log" ] \
    || fail "contended teardown reached the runtime: $(cat "$dir/runtime.log")"
  assert_contains "$(cat "$dir/stderr")" "another lifecycle action is already running" \
    "contended teardown should serialize before reading mutable task metadata"
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  pass "fm-teardown: a concurrent lifecycle action refuses before mutation"
}

test_teardown_ignores_unrelated_task_publication_locks() {
  local dir id=worktree-independent-task lock ready holder i=0
  dir=$(make_case worktree-independent-task-set-lock)
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=isolated:fm-$id" "endpoint_task_id=$id" \
    "worktree=$dir/missing-worktree" "project=$dir/project" "kind=scout"
  lock="$dir/home/state/.task-set.lock"
  ready="$dir/task-set-lock-ready"
  (
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$lock" || exit 1
    trap 'fm_lock_release "$lock"' EXIT
    : > "$ready"
    sleep 30
  ) &
  holder=$!
  while [ ! -e "$ready" ] && [ "$i" -lt 100 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$ready" ] || {
    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true
    fail "could not stage an in-progress task publication"
  }

  run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr" \
    || fail "worktree-independent teardown was blocked by an unrelated task publication: $(cat "$dir/stderr")"
  assert_absent "$dir/home/state/$id.meta" "worktree-independent teardown left task metadata"
  assert_present "$lock" "worktree-independent teardown removed the publisher's lock"
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  pass "fm-teardown: worktree-independent cleanup ignores unrelated task publication locks"
}

test_metadata_lock_serializes_destructive_cleanup() {
  local dir id=metadata-locked-task lock ready release holder teardown_pid i=0 rc
  dir=$(make_case metadata-lock)
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=isolated:fm-$id" "endpoint_task_id=$id" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  lock="$dir/home/state/.meta-$id.lock"
  ready="$dir/meta-lock-ready"
  release="$dir/meta-lock-release"
  (
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$lock" || exit 1
    trap 'fm_lock_release "$lock"' EXIT
    : > "$ready"
    while [ ! -e "$release" ]; do
      sleep 0.01
    done
  ) &
  holder=$!
  while [ ! -e "$ready" ] && [ "$i" -lt 100 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$ready" ] || {
    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true
    fail "could not stage a held metadata lock"
  }

  run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr" &
  teardown_pid=$!
  sleep 0.2
  if ! kill -0 "$teardown_pid" 2>/dev/null; then
    : > "$release"
    wait "$holder" 2>/dev/null || true
    wait "$teardown_pid" 2>/dev/null || true
    fail "teardown did not wait for the shared metadata writer lock"
  fi
  assert_present "$dir/home/state/$id.meta" "metadata-lock contention removed task metadata"
  assert_present "$dir/worktree/sentinel" "metadata-lock contention changed the worktree"
  [ ! -s "$dir/runtime.log" ] \
    || fail "metadata-lock contention reached the runtime: $(cat "$dir/runtime.log")"

  : > "$release"
  wait "$holder" || fail "metadata lock holder failed"
  wait "$teardown_pid"; rc=$?
  expect_code 0 "$rc" "teardown should complete after the metadata writer releases"
  assert_absent "$dir/home/state/$id.meta" \
    "serialized teardown left a task record that a completed writer could resurrect"
  pass "fm-teardown: destructive cleanup serializes with metadata writers"
}

test_supported_backend_endpoint_records_validate() {
  local dir id backend target
  dir=$(make_case valid-backends)
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-backend.sh"

  id=tmux-task
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" "worktree=$dir/worktree" "project=$dir/project"
  fm_backend_validate_task_endpoint "$dir/home/state/$id.meta" "$id" || fail "valid tmux endpoint refused"
  [ "$FM_BACKEND_VALIDATED_BACKEND:$FM_BACKEND_VALIDATED_TARGET" = "tmux:firstmate:fm-$id" ] || fail "tmux endpoint validation returned wrong identity"

  id=tmux-spaced-session
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=team work:fm-$id" "worktree=$dir/worktree" "project=$dir/project"
  fm_backend_validate_task_endpoint "$dir/home/state/$id.meta" "$id" || fail "valid tmux endpoint with a spaced session name refused"
  [ "$FM_BACKEND_VALIDATED_TARGET" = "team work:fm-$id" ] || fail "tmux validation changed the spaced session identity"

  id=herdr-task
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=lab:w1:p2" "endpoint_task_id=$id" "worktree=$dir/worktree" "project=$dir/project" \
    "backend=herdr" "herdr_session=lab" "herdr_workspace_id=w1" "herdr_tab_id=w1:t2" "herdr_pane_id=w1:p2"
  fm_backend_validate_task_endpoint "$dir/home/state/$id.meta" "$id" || fail "valid Herdr endpoint refused"

  id=zellij-task
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=lab:7" "endpoint_task_id=$id" "worktree=$dir/worktree" "project=$dir/project" \
    "backend=zellij" "zellij_session=lab" "zellij_tab_id=3" "zellij_pane_id=7"
  fm_backend_validate_task_endpoint "$dir/home/state/$id.meta" "$id" || fail "valid Zellij endpoint refused"

  id=orca-task
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=fm-$id" "endpoint_task_id=$id" "terminal=term-7" \
    "worktree=$dir/worktree" "project=$dir/project" "backend=orca" "orca_worktree_id=worktree-9"
  fm_backend_validate_task_endpoint "$dir/home/state/$id.meta" "$id" || fail "valid Orca endpoint refused"
  [ "$FM_BACKEND_VALIDATED_TARGET" = term-7 ] || fail "Orca validation did not select its terminal"

  id=cmux-task
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=workspace-1:surface-2" "endpoint_task_id=$id" "worktree=$dir/worktree" "project=$dir/project" \
    "backend=cmux" "cmux_workspace_id=workspace-1" "cmux_surface_id=surface-2"
  fm_backend_validate_task_endpoint "$dir/home/state/$id.meta" "$id" || fail "valid cmux endpoint refused"

  id=hc-task
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=t7" "endpoint_task_id=$id" "worktree=$dir/worktree" "project=$dir/project" "backend=hc"
  fm_backend_validate_task_endpoint "$dir/home/state/$id.meta" "$id" || fail "valid hc endpoint refused"
  [ "$FM_BACKEND_VALIDATED_TARGET" = t7 ] || fail "hc validation did not select its terminal address"

  for backend in tmux herdr zellij orca cmux hc; do
    set +e
    fm_backend_kill "$backend" "" >/dev/null 2>&1
    target=$?
    set -e
    [ "$target" -ne 0 ] || fail "$backend generic kill accepted an empty target"
  done
  pass "cleanup identity: valid tmux, Herdr, Zellij, Orca, cmux, and hc records validate while every empty backend target refuses"
}

test_tmux_empty_target_refuses_without_invocation() {
  local dir rc
  dir=$(make_case direct-empty)
  set +e
  FM_RUNTIME_LOG="$dir/runtime.log" PATH="$dir/fakebin:$PATH" \
    bash -c '. "$1/bin/fm-backend.sh"; fm_backend_source tmux; fm_backend_tmux_kill ""' _ "$ROOT" \
    > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "direct empty tmux target unexpectedly succeeded"
  [ ! -s "$dir/runtime.log" ] || fail "direct empty tmux target invoked tmux"
  pass "tmux backend: direct empty target returns nonzero without invoking tmux"
}

test_recorded_process_identity_cleanup_is_exact() {
  local dir target_pid control_pid target_record control_record live_command
  dir=$(make_case recorded-process)
  sleep 30 &
  control_pid=$!
  sleep 30 &
  target_pid=$!
  printf '%s\n' "$control_pid" > "$dir/control.pid"
  printf '%s\n' "$target_pid" > "$dir/target.pid"
  target_record=$(cat "$dir/target.pid")
  control_record=$(cat "$dir/control.pid")
  [ "$target_record" = "$target_pid" ] && [ "$control_record" = "$control_pid" ] \
    || fail "recorded process identity changed before cleanup"
  live_command=$(ps -p "$target_record" -o comm= 2>/dev/null | tr -d '[:space:]')
  case "$live_command" in sleep) ;; *) fail "recorded target pid no longer belongs to the expected child" ;; esac
  kill -TERM "$target_record"
  wait "$target_record" 2>/dev/null || true
  kill -0 "$target_record" 2>/dev/null && fail "exact target pid survived cleanup"
  kill -0 "$control_record" 2>/dev/null || fail "independent control process was disturbed"
  kill -TERM "$control_record"
  wait "$control_record" 2>/dev/null || true
  pass "process cleanup: creation-time PID identity removes only the exact child and preserves the control child"
}

isolated_tmux_window_exists() {  # <dir> <socket> <session> <window>
  ( cd "$1" && "$REAL_TMUX" -S "$2" list-windows -t "$3" -F '#{window_name}' 2>/dev/null ) \
    | grep -Fqx "$4"
}

test_isolated_tmux_invalid_and_valid_cleanup() {
  local dir socket socket_id session='endpoint safety' target_id=target control=control target=fm-target
  local prefix_target=fm-prefix prefix_survivor=fm-prefix2 rc
  [ -n "$REAL_TMUX" ] || { echo "skip - tmux not installed"; return 0; }
  dir=$(make_case isolated-real)
  socket=dedicated.sock
  socket_id="$dir/$socket"
  ( cd "$dir" && env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$socket" new-session -d -s "$session" -n "$control" )
  ( cd "$dir" && env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$socket" new-window -d -t "$session:" -n "$target" )
  printf '%s\n' "$socket_id" > "$dir/socket.identity"
  cat > "$dir/fakebin/tmux" <<SH
#!/usr/bin/env bash
set -eu
[ -z "\${TMUX:-}" ] && [ -z "\${TMUX_PANE:-}" ] || exit 91
[ "\${FM_TEST_TMUX_SOCKET:-}" = '$socket_id' ] || exit 92
[ "\$(cat '$dir/socket.identity')" = '$socket_id' ] || exit 93
printf 'tmux' >> "\${FM_RUNTIME_LOG:?}"
printf ' <%s>' "\$@" >> "\${FM_RUNTIME_LOG:?}"
printf '\n' >> "\${FM_RUNTIME_LOG:?}"
cd '$dir'
exec '$REAL_TMUX' -S '$socket' "\$@"
SH
  chmod +x "$dir/fakebin/tmux"

  fm_write_meta "$dir/home/state/invalid.meta" \
    "window=" "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  set +e
  env -u TMUX -u TMUX_PANE FM_TEST_TMUX_SOCKET="$socket_id" \
    FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_RUNTIME_LOG="$dir/runtime.log" \
    PATH="$dir/fakebin:$PATH" "$TEARDOWN" invalid --force \
    > "$dir/invalid.out" 2> "$dir/invalid.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "isolated invalid endpoint unexpectedly succeeded"
  [ ! -s "$dir/runtime.log" ] || fail "isolated invalid endpoint reached tmux"
  isolated_tmux_window_exists "$dir" "$socket" "$session" "$control" || fail "invalid cleanup removed control window"
  isolated_tmux_window_exists "$dir" "$socket" "$session" "$target" || fail "invalid cleanup removed target window"

  set +e
  # shellcheck disable=SC2016 # $1 expands inside the isolated child shell.
  env -u TMUX -u TMUX_PANE FM_TEST_TMUX_SOCKET="$socket_id" FM_RUNTIME_LOG="$dir/runtime.log" \
    PATH="$dir/fakebin:$PATH" bash -c \
    '. "$1/bin/fm-backend.sh"; fm_backend_source tmux; fm_backend_tmux_kill ""' _ "$ROOT" \
    > "$dir/empty.out" 2> "$dir/empty.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "isolated direct empty target unexpectedly succeeded"
  [ ! -s "$dir/runtime.log" ] || fail "isolated direct empty target reached tmux"
  isolated_tmux_window_exists "$dir" "$socket" "$session" "$control" || fail "direct empty cleanup removed control window"
  isolated_tmux_window_exists "$dir" "$socket" "$session" "$target" || fail "direct empty cleanup removed target window"

  ( cd "$dir" && env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$socket" new-window -d -t "=$session:" -n "$prefix_survivor" )
  # shellcheck disable=SC2016 # $1 and $2 expand inside the isolated child shell.
  env -u TMUX -u TMUX_PANE FM_TEST_TMUX_SOCKET="$socket_id" FM_RUNTIME_LOG="$dir/runtime.log" \
    PATH="$dir/fakebin:$PATH" bash -c \
    '. "$1/bin/fm-backend.sh"; fm_backend_source tmux; fm_backend_tmux_kill "$2"' _ "$ROOT" "$session:$prefix_target"
  isolated_tmux_window_exists "$dir" "$socket" "$session" "$prefix_survivor" \
    || fail "missing exact target cleanup removed its prefix-matched neighbor"

  fm_write_meta "$dir/home/state/$target_id.meta" \
    "window=$session:$target" "endpoint_task_id=$target_id" \
    "worktree=$dir/nonexistent-worktree" "project=$dir/nonexistent-project" \
    "kind=scout" "mode=no-mistakes"
  env -u TMUX -u TMUX_PANE FM_TEST_TMUX_SOCKET="$socket_id" \
    FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_RUNTIME_LOG="$dir/runtime.log" \
    PATH="$dir/fakebin:$PATH" "$TEARDOWN" "$target_id" --force \
    > "$dir/valid.out" 2> "$dir/valid.err" \
    || fail "isolated valid endpoint teardown failed: $(cat "$dir/valid.err")"
  isolated_tmux_window_exists "$dir" "$socket" "$session" "$target" \
    && fail "valid cleanup did not remove the exact target window"
  isolated_tmux_window_exists "$dir" "$socket" "$session" "$control" \
    || fail "valid cleanup removed the independent control window"
  grep -Fqx "tmux <kill-window> <-t> <=$session:=$target>" "$dir/runtime.log" \
    || fail "valid cleanup did not invoke exactly the recorded target: $(cat "$dir/runtime.log")"

  ( cd "$dir" && env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$socket" kill-server 2>/dev/null ) || true
  pass "fm-teardown: exact tmux cleanup preserves invalid and prefix-matched neighbors while removing only the recorded target"
}

test_a_worktree_named_by_a_second_task_record_refuses_before_touching_the_other_task() {
  local dir id=stale-task other=live-task worker rc

  dir=$(make_case worktree-collision)
  mark_case_as_linked_worktree "$dir"
  # The reuse collision: the worktree recorded for a finished task has already
  # been recorded for another task, whose worker is live in it right now.
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  fm_write_meta "$dir/home/state/$other.meta" \
    "window=firstmate:fm-$other" "endpoint_task_id=$other" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  # Staged in this shell, not a command substitution: a background child of a
  # $(...) subshell does not outlive it, and the point of this worker is to be
  # alive in the worktree while teardown runs.
  ( cd "$dir/worktree" && exec sleep 30 ) &
  worker=$!

  set +e
  run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e

  [ "$rc" -ne 0 ] || fail "teardown removed a worktree a second task record still holds"
  kill -0 "$worker" 2>/dev/null || fail "teardown killed the worker in the contested worktree"
  assert_present "$dir/worktree/sentinel" "teardown reset a worktree a second task record still holds"
  assert_present "$dir/home/state/$other.meta" "teardown removed the live task's record"
  assert_present "$dir/home/state/$id.meta" "teardown removed the stale task's record before refusing"
  [ ! -s "$dir/runtime.log" ] \
    || fail "teardown reached the runtime on a contested worktree: $(cat "$dir/runtime.log")"
  assert_contains "$(cat "$dir/stderr")" "$other" \
    "refusal should name the other task holding the worktree"
  kill "$worker" 2>/dev/null || true
  wait "$worker" 2>/dev/null || true

  # The same collision recorded on a secondmate home field rather than a task
  # worktree is the same worktree, and refuses the same way.
  dir=$(make_case worktree-collision-home)
  mark_case_as_linked_worktree "$dir"
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  fm_write_meta "$dir/home/state/$other.meta" \
    "window=firstmate:fm-$other" "endpoint_task_id=$other" \
    "worktree=$dir/worktree" "home=$dir/worktree" \
    "project=$dir/project" "kind=secondmate"
  set +e
  run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "teardown removed a worktree a secondmate home record still holds"
  assert_present "$dir/worktree/sentinel" "teardown reset a worktree a secondmate home record still holds"
  assert_present "$dir/home/state/$other.meta" "teardown removed the secondmate record"
  [ ! -s "$dir/runtime.log" ] \
    || fail "teardown reached the runtime on a worktree held by a secondmate home: $(cat "$dir/runtime.log")"

  pass "fm-teardown: a worktree named by a second task record is never removed, killed, or reset"
}

test_cross_home_worktree_collision_refuses() {
  local dir id=stale-task other=secondmate-task second_home second_project rc
  dir=$(make_case worktree-collision-cross-home)
  mark_case_as_linked_worktree "$dir"
  printf 'fixture\n' > "$dir/project/tracked"
  git -C "$dir/project" add tracked
  git -C "$dir/project" -c user.name=test -c user.email=test@example.invalid commit -qm fixture
  second_home="$dir/secondmate-home"
  second_project="$second_home/projects/project"
  mkdir -p "$second_home/projects" "$second_home/state" "$second_home/data"
  git clone -q "$dir/project" "$second_project"
  printf '%s\n' "- mate - fixture (home: $second_home; scope: test; projects: project; added 2026-01-01)" \
    > "$dir/home/data/secondmates.md"
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  fm_write_meta "$second_home/state/$other.meta" \
    "window=firstmate:fm-$other" "endpoint_task_id=$other" \
    "worktree=$dir/worktree" "project=$second_project" "kind=scout"

  set +e
  run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "teardown removed a worktree held by another firstmate home"
  assert_present "$dir/home/state/$id.meta" "cross-home collision removed stale metadata"
  assert_present "$second_home/state/$other.meta" "cross-home collision removed live metadata"
  assert_present "$dir/worktree/sentinel" "cross-home collision reset the shared worktree"
  [ ! -s "$dir/runtime.log" ] \
    || fail "cross-home collision reached the runtime: $(cat "$dir/runtime.log")"
  assert_contains "$(cat "$dir/stderr")" "$other" \
    "cross-home refusal should name the task holding the worktree"
  pass "fm-teardown: a worktree held by another firstmate home is never removed"
}

test_sole_worktree_record_still_tears_down() {
  local dir id=sole-task worker

  dir=$(make_case worktree-sole)
  mark_case_as_linked_worktree "$dir"
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  # A neighbouring task on its OWN worktree must not look like a collision.
  mkdir -p "$dir/other-worktree"
  fm_write_meta "$dir/home/state/neighbour.meta" \
    "window=firstmate:fm-neighbour" "endpoint_task_id=neighbour" \
    "worktree=$dir/other-worktree" "project=$dir/project" "kind=scout"
  ( cd "$dir/other-worktree" && exec sleep 30 ) &
  worker=$!

  run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr" \
    || fail "teardown of a task that solely holds its worktree failed: $(cat "$dir/stderr")"
  assert_absent "$dir/home/state/$id.meta" "uncontested teardown left the task record"
  assert_present "$dir/home/state/neighbour.meta" "uncontested teardown removed the neighbour's record"
  kill -0 "$worker" 2>/dev/null || fail "uncontested teardown killed a worker in a different worktree"
  grep -Fq "wt <-C> <$dir/project> <remove>" "$dir/runtime.log" \
    || fail "uncontested teardown did not remove its own worktree: $(cat "$dir/runtime.log")"
  kill "$worker" 2>/dev/null || true
  wait "$worker" 2>/dev/null || true
  pass "fm-teardown: a task that solely holds its worktree still removes it"
}

test_recorded_endpoint_that_changed_directory_still_tears_down() {
  local dir id=moved-task

  dir=$(make_case worktree-endpoint-moved)
  mark_case_as_linked_worktree "$dir"
  mkdir -p "$dir/other-directory"
  # The exact recorded worker may legitimately cd outside its worktree. Its
  # endpoint identity still owns the lifecycle; cwd alone must not brick it.
  cat > "$dir/fakebin/tmux" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = display-message ]; then
  printf '%s\n' '$dir/other-directory'
  exit 0
fi
printf 'tmux' >> "\${FM_RUNTIME_LOG:?}"
printf ' <%s>' "\$@" >> "\${FM_RUNTIME_LOG:?}"
printf '\n' >> "\${FM_RUNTIME_LOG:?}"
exit 0
SH
  chmod +x "$dir/fakebin/tmux"
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"

  run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr" \
    || fail "teardown refused its recorded endpoint after it changed directory: $(cat "$dir/stderr")"
  assert_absent "$dir/home/state/$id.meta" "moved-endpoint teardown left the task record"
  grep -Fq "tmux <kill-window> <-t> <=firstmate:=fm-$id>" "$dir/runtime.log" \
    || fail "moved-endpoint teardown did not stop the exact recorded worker: $(cat "$dir/runtime.log")"
  grep -Fq "wt <-C> <$dir/project> <remove>" "$dir/runtime.log" \
    || fail "moved-endpoint teardown did not remove its uncontested worktree: $(cat "$dir/runtime.log")"

  pass "fm-teardown: an exact recorded endpoint still tears down after changing cwd outside its worktree"
}

# --- remote-seeded and nested firstmate homes ---------------------------------
#
# A remote parent binding terminates the walk over homes at the home holding it, so
# a task's worktree is checked against every home this machine can reach.

write_local_parent_record() {  # <home> <parent-home>
  cat > "$1/.fm-secondmate-parent" <<REC
schema=fm-secondmate-parent.v1
route=local
parent_home=$2
REC
}

write_remote_parent_record() {  # <home>
  cat > "$1/.fm-secondmate-parent" <<'REC'
schema=fm-secondmate-parent.v1
route=remote
parent_host=machine-a
REC
}

make_home() {  # <path>
  mkdir -p "$1/state" "$1/data" "$1/config" "$1/projects"
}

test_remote_seeded_home_removes_its_uncontested_worktree() {
  local dir id=remote-task rc
  dir=$(make_case remote-home-teardown)
  mark_case_as_linked_worktree "$dir"
  write_remote_parent_record "$dir/home"
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"

  set +e
  run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] \
    || fail "teardown in a remote-seeded home refused its own uncontested worktree: $(cat "$dir/stderr")"
  assert_absent "$dir/home/state/$id.meta" "remote-seeded teardown left the task record"
  grep -Fq "wt <-C> <$dir/project> <remove>" "$dir/runtime.log" \
    || fail "remote-seeded teardown did not remove its own worktree: $(cat "$dir/runtime.log")"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# remote-seeded wt teardown command\n'
    printf '$ FM_HOME=%s bin/fm-teardown.sh %s --force\n' "$dir/home" "$id"
    printf 'stdout:\n'; cat "$dir/stdout"
    printf 'stderr:\n'; cat "$dir/stderr"
    printf 'exit=%s\nruntime calls:\n' "$rc"; cat "$dir/runtime.log"
    printf 'task metadata=%s\nworktree sentinel=%s\n' \
      "$([ -e "$dir/home/state/$id.meta" ] && printf present || printf removed)" \
      "$([ -e "$dir/worktree/sentinel" ] && printf present || printf removed)"
  fi

  pass "fm-teardown: a remote-seeded secondmate home removes its own uncontested worktree"
}

test_remote_seeded_home_still_refuses_a_worktree_its_child_holds() {
  local dir id=remote-stale other=child-task child_home child_project rc
  dir=$(make_case remote-home-collision)
  mark_case_as_linked_worktree "$dir"
  write_remote_parent_record "$dir/home"
  printf 'fixture\n' > "$dir/project/tracked"
  git -C "$dir/project" add tracked
  git -C "$dir/project" -c user.name=test -c user.email=test@example.invalid commit -qm fixture
  child_home="$dir/child-home"
  child_project="$child_home/projects/project"
  make_home "$child_home"
  write_local_parent_record "$child_home" "$dir/home"
  git clone -q "$dir/project" "$child_project"
  printf '%s\n' "- mate - fixture (home: $child_home; scope: test; projects: project; added 2026-01-01)" \
    > "$dir/home/data/secondmates.md"
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  fm_write_meta "$child_home/state/$other.meta" \
    "window=firstmate:fm-$other" "endpoint_task_id=$other" \
    "worktree=$dir/worktree" "project=$child_project" "kind=scout"

  set +e
  run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] \
    || fail "a remote-seeded home removed a worktree its own local child still holds"
  assert_present "$dir/home/state/$id.meta" "remote-layout collision removed stale metadata"
  assert_present "$child_home/state/$other.meta" "remote-layout collision removed live metadata"
  assert_present "$dir/worktree/sentinel" "remote-layout collision reset the shared worktree"
  assert_contains "$(cat "$dir/stderr")" "$other" \
    "remote-layout refusal should name the task holding the worktree"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# remote-seeded cross-home collision command\n'
    printf '$ FM_HOME=%s bin/fm-teardown.sh %s --force\n' "$dir/home" "$id"
    printf 'stderr:\n'; cat "$dir/stderr"
    printf 'exit=%s\nruntime calls=%s\n' "$rc" \
      "$([ -s "$dir/runtime.log" ] && cat "$dir/runtime.log" || printf none)"
    printf 'remote metadata=%s\nchild metadata=%s\nworktree sentinel=%s\n' \
      "$([ -e "$dir/home/state/$id.meta" ] && printf preserved || printf removed)" \
      "$([ -e "$child_home/state/$other.meta" ] && printf preserved || printf removed)" \
      "$([ -e "$dir/worktree/sentinel" ] && printf preserved || printf removed)"
  fi

  pass "fm-teardown: worktree ownership across a remote-seeded home and its local child still refuses"
}

test_invalid_endpoint_records_refuse_before_mutation
test_control_lock_contention_refuses_before_mutation
test_teardown_ignores_unrelated_task_publication_locks
test_metadata_lock_serializes_destructive_cleanup
test_supported_backend_endpoint_records_validate
test_tmux_empty_target_refuses_without_invocation
test_recorded_process_identity_cleanup_is_exact
test_isolated_tmux_invalid_and_valid_cleanup
test_a_worktree_named_by_a_second_task_record_refuses_before_touching_the_other_task
test_cross_home_worktree_collision_refuses
test_sole_worktree_record_still_tears_down
test_recorded_endpoint_that_changed_directory_still_tears_down
test_remote_seeded_home_removes_its_uncontested_worktree
test_remote_seeded_home_still_refuses_a_worktree_its_child_holds
