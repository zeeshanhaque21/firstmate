#!/usr/bin/env bash
# tests/fm-spawn-wt.test.sh - fm-spawn.sh creates each task worktree with the
# real Worktrunk `wt` and real git (bin/fm-spawn.sh spawn_wt_create).
#
# The panes are fakes (a tmux that follows the `cd` fm-spawn types, and a
# herdr-core shim for the hc abort case); wt and git are real, run against
# throwaway repositories with XDG_CONFIG_HOME pointed at a scratch directory so
# the captain's own wt configuration never applies and a scratch wt config can
# carry a failing or slow pre-start hook.
#
# Covered: the normal create; a failing pre-start hook (wt exits nonzero AFTER
# creating the branch and worktree) leaves nothing behind and a retry of the
# same id succeeds; a slow hook is bounded by FM_SPAWN_WT_CREATE_TIMEOUT; an
# abort after creation removes the worktree and the hc terminal this run
# created; an id that makes an invalid branch name is refused; a project
# reached through a symlink; a project with no origin; an origin whose default
# branch is not main.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

command -v wt >/dev/null 2>&1 || { echo "skip: wt (Worktrunk) not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-spawn-wt)

# A tmux whose pane_current_path follows the last `cd <path>` typed into it.
# FM_FAKE_PANE_START is the path reported before any cd; FM_FAKE_NO_CD=1 pins
# the pane there so the worktree wait times out.
make_wt_fakebin() {  # <dir>
  local fakebin
  fakebin=$(fm_fakebin "$1")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
cdfile=${FM_FAKE_PANE_FILE:?}
case "$*" in
  *"#{pane_current_path}"*)
    if [ -s "$cdfile" ]; then cat "$cdfile"; else printf '%s\n' "${FM_FAKE_PANE_START:-}"; fi
    exit 0
    ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  send-keys)
    for a in "$@"; do
      if [ "${FM_FAKE_NO_CD:-0}" != 1 ]; then
        case "$a" in
          "cd "*) eval "set -- ${a#cd }"; printf '%s\n' "$1" > "$cdfile" ;;
        esac
      fi
    done
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_test_fake_sleep_noop "$fakebin"
  printf '%s\n' "$fakebin"
}

# A herdr-core shim sufficient for fm-spawn's hc path up to the worktree wait:
# it logs every call, lists no terminals, creates t1c named fm-$FM_FAKE_HC_ID,
# and reports the project path as the terminal's live cwd forever.
make_hc_fakebin() {  # <dir> <id> <project>
  local fakebin
  fakebin=$(fm_fakebin "$1")
  cat > "$fakebin/herdr-core" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_FAKE_HC_LOG:?}"
case "${1:-}" in
  ls) printf '{"terminals":[]}\n' ;;
  run) printf '{"address":"t1c","name":"fm-%s","state":"live"}\n' "$FM_FAKE_HC_ID" ;;
  get)
    printf '{"address":"t1c","name":"fm-%s","state":"live","foreground":{"argv":["/bin/zsh"],"cwd":"%s","name":"zsh","pid":1}}\n' "$FM_FAKE_HC_ID" "$FM_FAKE_HC_CWD"
    ;;
  send|keys|kill|rm) ;;
  *) exit 64 ;;
esac
exit 0
SH
  chmod +x "$fakebin/herdr-core"
  fm_test_fake_sleep_noop "$fakebin"
  printf '%s\n' "$fakebin"
}

# new_case <name> -> sets CASE HOME_DIR PROJ XDG FAKEBIN PANEFILE; project is a
# real repo on main with a bare origin.
new_case() {
  CASE="$TMP_ROOT/$1"
  HOME_DIR="$CASE/home"
  PROJ="$CASE/project"
  XDG="$CASE/xdg"
  PANEFILE="$CASE/pane"
  mkdir -p "$XDG/worktrunk"
  : > "$PANEFILE"
  fm_test_spawn_home "$HOME_DIR" codex
  fm_git_init_commit "$PROJ"
  fm_git_add_origin "$PROJ" "$CASE/origin.git"
  FAKEBIN=$(make_wt_fakebin "$CASE/fake")
}

# run_spawn <id> [extra env assignments are inherited]
run_spawn() {
  local id=$1
  shift
  fm_test_spawn_brief "$HOME_DIR" "$id" "Exercise wt worktree creation for $id."
  XDG_CONFIG_HOME="$XDG" FM_FAKE_PANE_FILE="$PANEFILE" FM_FAKE_PANE_START="$PROJ" \
    fm_test_run_spawn "$HOME_DIR" "$PROJ" "$FAKEBIN" "$id" "${SPAWN_PROJ:-$PROJ}" --mode no-mistakes --yolo off "$@"
}

branch_exists() { git -C "$PROJ" rev-parse --verify --quiet "refs/heads/$1" >/dev/null 2>&1; }
worktree_for_branch() { git -C "$PROJ" worktree list --porcelain | grep -Fxq "branch refs/heads/$1"; }

test_normal_create() {
  local id=wt-normal-z1 out status
  new_case normal
  out=$(run_spawn "$id"); status=$?
  expect_code 0 "$status" "spawn should succeed with a real wt"$'\n'"$out"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  branch_exists "fm/$id" || fail "wt did not create branch fm/$id"
  worktree_for_branch "fm/$id" || fail "no worktree on fm/$id"
  assert_grep "worktree=" "$HOME_DIR/state/$id.meta" "meta missing worktree="
  pass "a normal spawn creates fm/<id> through real wt and records the worktree"
}

test_failing_pre_start_hook_leaves_nothing_and_retry_succeeds() {
  local id=wt-hookfail-z2 out status
  new_case hookfail
  printf '[pre-start]\nbroken = "echo hook-says-no >&2; exit 7"\n' > "$XDG/worktrunk/config.toml"
  out=$(run_spawn "$id"); status=$?
  [ "$status" -ne 0 ] || fail "spawn must fail when a pre-start hook fails"$'\n'"$out"
  assert_contains "$out" "wt could not create worktree branch fm/$id" "the refusal must name the wt failure"
  assert_contains "$out" "hook" "the refusal must name the hook failure"
  worktree_for_branch "fm/$id" && fail "M3: the worktree wt created before the hook failed was stranded"
  branch_exists "fm/$id" && fail "M3: the branch wt created before the hook failed was stranded"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "a refused spawn published task metadata"
  : > "$XDG/worktrunk/config.toml"
  out=$(run_spawn "$id"); status=$?
  expect_code 0 "$status" "retry of the same id must succeed after the hook is fixed"$'\n'"$out"
  worktree_for_branch "fm/$id" || fail "retry did not create the worktree"
  pass "a failing pre-start hook strands nothing and the same id can be retried"
}

test_slow_pre_start_hook_times_out_cleanly() {
  local id=wt-hookslow-z3 out status start elapsed
  new_case hookslow
  printf '[pre-start]\nslow = "/bin/sleep 40"\n' > "$XDG/worktrunk/config.toml"
  start=$SECONDS
  out=$(FM_SPAWN_WT_CREATE_TIMEOUT=3 run_spawn "$id"); status=$?
  elapsed=$((SECONDS - start))
  [ "$status" -ne 0 ] || fail "spawn must fail when the wt create exceeds its bound"$'\n'"$out"
  [ "$elapsed" -lt 30 ] || fail "M3: a slow hook was not bounded (took ${elapsed}s)"
  assert_contains "$out" "within 3s" "the refusal must say the bound was hit"
  assert_contains "$out" "FM_SPAWN_WT_CREATE_TIMEOUT" "the refusal must name the override"
  worktree_for_branch "fm/$id" && fail "M3: a timed-out create stranded the worktree"
  branch_exists "fm/$id" && fail "M3: a timed-out create stranded the branch"
  : > "$XDG/worktrunk/config.toml"
  out=$(run_spawn "$id"); status=$?
  expect_code 0 "$status" "retry after a timeout must succeed"$'\n'"$out"
  pass "a slow pre-start hook is bounded, cleaned up, and the id can be retried"
}

test_abort_after_creation_removes_the_worktree() {
  local id=wt-abort-z4 out status
  new_case abort
  out=$(FM_FAKE_NO_CD=1 run_spawn "$id"); status=$?
  [ "$status" -ne 0 ] || fail "spawn must fail when the pane never enters the worktree"$'\n'"$out"
  assert_contains "$out" "did not enter the isolated worktree" "unexpected failure: $out"
  worktree_for_branch "fm/$id" && fail "an aborted spawn stranded its worktree"
  branch_exists "fm/$id" && fail "an aborted spawn stranded its branch"
  out=$(run_spawn "$id"); status=$?
  expect_code 0 "$status" "retry after an abort must succeed"$'\n'"$out"
  pass "a spawn aborted after the worktree was created removes it"
}

test_hc_abort_closes_the_terminal_it_created() {
  local id=wt-hcabort-z5 out status hclog
  new_case hcabort
  hclog="$CASE/hc.log"; : > "$hclog"
  FAKEBIN=$(make_hc_fakebin "$CASE/fakehc" "$id" "$PROJ")
  out=$(FM_FAKE_HC_LOG="$hclog" FM_FAKE_HC_ID="$id" FM_FAKE_HC_CWD="$PROJ" run_spawn "$id" --backend hc); status=$?
  [ "$status" -ne 0 ] || fail "hc spawn must fail when the terminal never enters the worktree"$'\n'"$out"
  grep -Fxq "kill fm-$id" "$hclog" || fail "n1: the aborted spawn did not kill the terminal it created: $(tr '\n' ';' < "$hclog")"
  grep -Fxq "rm t1c" "$hclog" || fail "n1: the aborted spawn did not remove the terminal it created"
  worktree_for_branch "fm/$id" && fail "an aborted hc spawn stranded its worktree"
  # A terminal this run did NOT create is never touched: a relaunch-style
  # failure before creation (name already live) must not kill anything.
  pass "an aborted hc spawn closes only the terminal it created and removes its worktree"
}

test_invalid_branch_name_id_is_refused() {
  local id out status bad
  new_case badid
  for bad in 'bad..name' 'trail.lock' 'sp ace' 'at@{x'; do
    id=$bad
    out=$(run_spawn "$id" 2>&1); status=$?
    [ "$status" -ne 0 ] || fail "spawn accepted task id '$id' that cannot form a branch name"$'\n'"$out"
    printf '# refused %s: %s\n' "$id" "$(printf '%s' "$out" | grep -m1 '^error' | cut -c1-160)"
    [ -z "$(git -C "$PROJ" branch --list 'fm/*')" ] || fail "a refused id '$id' left a branch behind"
    [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "a refused id '$id' published metadata"
  done
  pass "task ids that cannot form a valid fm/<id> branch name are refused"
}

test_symlinked_project_works() {
  local id=wt-symlink-z6 out status
  new_case symlink
  ln -s "$PROJ" "$CASE/project-link"
  out=$(SPAWN_PROJ="$CASE/project-link" run_spawn "$id"); status=$?
  expect_code 0 "$status" "a project reached through a symlink must spawn"$'\n'"$out"
  worktree_for_branch "fm/$id" || fail "no worktree for a symlinked project"
  pass "a project reached through a symlink spawns"
}

test_project_without_origin_uses_local_default() {
  local id=wt-noorigin-z7 out status
  new_case noorigin
  git -C "$PROJ" remote remove origin
  out=$(run_spawn "$id"); status=$?
  expect_code 0 "$status" "a project with no origin must spawn from its local default branch"$'\n'"$out"
  worktree_for_branch "fm/$id" || fail "no worktree for a project without origin"
  pass "a project without origin spawns from the local default branch"
}

test_origin_default_branch_not_main() {
  local id=wt-trunk-z8 out status advanced wt_head
  new_case trunk
  rm -rf "$PROJ" "$CASE/origin.git"
  git init -q -b trunk "$PROJ"
  printf 'one\n' > "$PROJ/f"
  git -C "$PROJ" add f
  git -C "$PROJ" -c user.name=t -c user.email=t@example.invalid commit -qm one
  fm_git_add_origin "$PROJ" "$CASE/origin.git"
  # Origin moves ahead of the local checkout, which sits on another branch.
  git clone -q "$CASE/origin.git" "$CASE/pusher"
  printf 'two\n' > "$CASE/pusher/f"
  git -C "$CASE/pusher" -c user.name=t -c user.email=t@example.invalid commit -qam two
  git -C "$CASE/pusher" push -q origin trunk
  advanced=$(git -C "$CASE/pusher" rev-parse HEAD)
  git -C "$PROJ" checkout -q -b side
  out=$(run_spawn "$id"); status=$?
  expect_code 0 "$status" "an origin whose default branch is not main must spawn"$'\n'"$out"
  wt_head=$(git -C "$PROJ" rev-parse "fm/$id")
  [ "$wt_head" = "$advanced" ] || fail "worktree should start at origin/trunk ($advanced), got $wt_head"
  pass "an origin default branch other than main is the worktree base"
}

test_normal_create
test_failing_pre_start_hook_leaves_nothing_and_retry_succeeds
test_slow_pre_start_hook_times_out_cleanly
test_abort_after_creation_removes_the_worktree
test_hc_abort_closes_the_terminal_it_created
test_invalid_branch_name_id_is_refused
test_symlinked_project_works
test_project_without_origin_uses_local_default
test_origin_default_branch_not_main
