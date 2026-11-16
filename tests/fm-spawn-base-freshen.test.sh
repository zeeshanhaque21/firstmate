#!/usr/bin/env bash
# Regression tests for the base a new task worktree starts from.
#
# fm-spawn.sh creates every task worktree with the real Worktrunk `wt` on a new
# branch fm/<id>. The base is the FRESHLY FETCHED default branch tip, never a
# stale local one: origin advances while the project's own checkout sits still,
# and a worker that started behind origin would rebase over work it never saw.
# These tests drive the real spawn path (real git, real wt, scratch repos, a fake
# terminal) and prove the new worktree starts at origin's current tip, an
# origin-less project starts from its local default branch, and an origin that
# is unusable stops the spawn before anything is created.
#
# Every repository, wt config and HOME here is a scratch directory; nothing
# touches a real checkout or the operator's wt configuration (fm_test_run_spawn
# pins XDG_CONFIG_HOME and HOME).
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

fm_test_require_wt
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-spawn-base-freshen)

# make_case <name> <id> [default-branch]
# A project with a bare origin, whose default branch then advances in origin only
# (through a publisher clone), so the project's own local branch is stale.
make_case() {
  local name=$1 id=$2 default=${3:-main} case_dir home project origin publisher fakebin initial
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  project="$case_dir/project"
  origin="$case_dir/origin.git"
  publisher="$case_dir/publisher"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_real_wt "$fakebin"

  fm_test_spawn_home "$home" codex
  fm_test_spawn_brief "$home" "$id"

  git init --quiet -b "$default" "$project"
  printf 'base\n' > "$project/README.md"
  git -C "$project" add README.md
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  git clone --quiet --bare "$project" "$origin"
  git -C "$project" remote add origin "file://$origin"
  initial=$(git -C "$project" rev-parse HEAD)

  git clone --quiet "file://$origin" "$publisher"
  printf 'must survive a newly spawned branch\n' > "$publisher/advanced-main.txt"
  git -C "$publisher" add advanced-main.txt
  git -C "$publisher" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm advance-main
  git -C "$publisher" push --quiet origin "$default"

  printf '%s\n' "$case_dir|$home|$project|$fakebin|$initial|$default"
}

# make_originless_case <name> <id>: a local-only project with no origin at all.
make_originless_case() {
  local name=$1 id=$2 case_dir home project fakebin initial
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  project="$case_dir/project"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_real_wt "$fakebin"

  fm_test_spawn_home "$home" codex
  fm_test_spawn_brief "$home" "$id"

  git init --quiet -b main "$project"
  printf 'base\n' > "$project/README.md"
  git -C "$project" add README.md
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  initial=$(git -C "$project" rev-parse HEAD)

  printf '%s\n' "$case_dir|$home|$project|$fakebin|$initial|main"
}

read_case_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJECT_DIR FAKEBIN_DIR INITIAL_SHA DEFAULT_BRANCH <<EOF
$1
EOF
}

# The pane starts in the project and follows the cd spawn types into the worktree
# wt creates (fm_test_run_spawn pins the scratch wt config and the pane file).
run_spawn() {
  local id=$1
  shift
  fm_test_run_spawn "$HOME_DIR" "$PROJECT_DIR" "$FAKEBIN_DIR" \
    "$id" "$PROJECT_DIR" "$@"
}

# The worktree a spawn recorded for <id>.
meta_worktree() {
  sed -n 's/^worktree=//p' "$HOME_DIR/state/$1.meta" | head -n 1
}

branch_exists() { git -C "$PROJECT_DIR" rev-parse --verify --quiet "refs/heads/$1" >/dev/null 2>&1; }

# A refused spawn must leave nothing behind: no task record, no worktree, no branch.
assert_nothing_left_behind() {
  local id=$1
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused spawn published task metadata"
  branch_exists "fm/$id" && fail "refused spawn left branch fm/$id behind"
  git -C "$PROJECT_DIR" worktree list --porcelain | grep -Fxq "branch refs/heads/fm/$id" \
    && fail "refused spawn left a worktree on fm/$id behind"
  return 0
}

test_new_worktree_starts_at_the_fetched_origin_tip() {
  local rec id out status wt current
  id='base-current-r1'
  rec=$(make_case current-base "$id")
  read_case_record "$rec"
  # The project's own local branch is stale on purpose: origin advanced past it.
  [ "$(git -C "$PROJECT_DIR" rev-parse HEAD)" = "$INITIAL_SHA" ] || fail "fixture project is not at the initial commit"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn should start the worktree from the fetched origin tip"$'\n'"$out"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  wt=$(meta_worktree "$id")
  [ -d "$wt" ] || fail "the recorded worktree '$wt' does not exist"
  current=$(git -C "$PROJECT_DIR" rev-parse origin/main)
  [ "$(git -C "$wt" rev-parse HEAD)" = "$current" ] || fail "the new worktree did not start at the fetched origin/main tip"
  [ "$current" != "$INITIAL_SHA" ] || fail "fixture did not prove origin/main advanced past the project's local branch"
  [ "$(git -C "$wt" rev-parse --abbrev-ref HEAD)" = "fm/$id" ] || fail "the new worktree is not on branch fm/$id"
  assert_grep 'must survive a newly spawned branch' "$wt/advanced-main.txt" \
    "the new worktree omitted the content origin advanced"
  git -C "$wt" diff --exit-code origin/main...HEAD >/dev/null \
    || fail "the new branch differs from current origin/main"
  [ "$(git -C "$PROJECT_DIR" rev-parse HEAD)" = "$INITIAL_SHA" ] \
    || fail "spawn moved the project's own checkout"
  pass "a new task worktree starts at the freshly fetched origin tip, not the stale local branch"
}

test_a_second_task_starts_at_the_same_current_tip() {
  local rec id out status wt first_wt current
  id='base-first-r1'
  rec=$(make_case repeat-base "$id")
  read_case_record "$rec"
  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "the first spawn should succeed"$'\n'"$out"
  first_wt=$(meta_worktree "$id")
  current=$(git -C "$PROJECT_DIR" rev-parse origin/main)

  id='base-second-r1'
  fm_test_spawn_brief "$HOME_DIR" "$id"
  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "a second spawn from the same project should succeed"$'\n'"$out"
  wt=$(meta_worktree "$id")
  [ "$wt" != "$first_wt" ] || fail "two tasks were given the same worktree"
  [ "$(git -C "$wt" rev-parse HEAD)" = "$current" ] || fail "the second task did not start at the current origin tip"
  [ "$(git -C "$first_wt" rev-parse HEAD)" = "$current" ] || fail "spawning a second task moved the first task's worktree"
  pass "each task gets its own worktree and branch, both starting at the current origin tip"
}

test_non_main_default_branch_is_resolved_and_fetched() {
  local rec id out status wt current
  id='base-trunk-r2'
  rec=$(make_case current-trunk "$id" trunk)
  read_case_record "$rec"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn should resolve and fetch a non-main default branch"$'\n'"$out"
  wt=$(meta_worktree "$id")
  current=$(git -C "$PROJECT_DIR" rev-parse "origin/$DEFAULT_BRANCH")
  [ "$(git -C "$wt" rev-parse HEAD)" = "$current" ] || fail "the worktree did not start at current origin/$DEFAULT_BRANCH"
  [ "$current" != "$INITIAL_SHA" ] || fail "fixture did not prove origin/$DEFAULT_BRANCH advanced"
  pass "a non-main default branch is resolved and its fetched tip is the base"
}

test_direct_pr_and_scout_start_at_the_fetched_tip() {
  local rec id out status contract current wt
  for contract in direct-pr scout; do
    id="base-${contract}-r3"
    rec=$(make_case "$contract" "$id")
    read_case_record "$rec"
    if [ "$contract" = scout ]; then
      out=$(run_spawn "$id" --scout)
    else
      out=$(run_spawn "$id" --mode direct-PR --yolo off)
    fi
    status=$?
    expect_code 0 "$status" "$contract spawn should start from the fetched tip"$'\n'"$out"
    wt=$(meta_worktree "$id")
    current=$(git -C "$PROJECT_DIR" rev-parse origin/main)
    [ "$(git -C "$wt" rev-parse HEAD)" = "$current" ] \
      || fail "$contract spawn did not start at current origin/main"
    assert_grep 'must survive a newly spawned branch' "$wt/advanced-main.txt" \
      "$contract spawn omitted the advanced content"
  done
  pass "direct-PR ships and scouts both start at the fetched origin tip"
}

test_the_projects_own_uncommitted_work_is_left_alone() {
  local rec id out status wt
  id='base-dirty-project-r4'
  rec=$(make_case dirty-project "$id")
  read_case_record "$rec"
  printf 'keep this local work\n' > "$PROJECT_DIR/uncommitted.txt"
  printf 'edited\n' >> "$PROJECT_DIR/README.md"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "uncommitted work in the project must not block or be touched by a spawn"$'\n'"$out"
  wt=$(meta_worktree "$id")
  assert_grep 'keep this local work' "$PROJECT_DIR/uncommitted.txt" "spawn discarded the project's untracked work"
  assert_grep 'edited' "$PROJECT_DIR/README.md" "spawn discarded the project's tracked edit"
  [ ! -e "$wt/uncommitted.txt" ] || fail "the project's untracked work leaked into the new worktree"
  assert_no_grep 'edited' "$wt/README.md" "the project's tracked edit leaked into the new worktree"
  pass "a spawn leaves the project's own uncommitted work untouched and out of the new worktree"
}

test_originless_project_starts_from_its_local_default_branch() {
  local rec id out status wt
  id='base-originless-r6'
  rec=$(make_originless_case originless "$id")
  read_case_record "$rec"
  ! git -C "$PROJECT_DIR" remote get-url origin >/dev/null 2>&1 \
    || fail "fixture unexpectedly configured an origin remote"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn should launch a local-only project with no origin"$'\n'"$out"
  assert_contains "$out" "spawned $id" "spawn did not report success for the origin-less project"
  assert_not_contains "$out" "could not fetch origin" "spawn attempted a freshness fetch against a nonexistent origin"
  [ ! -e "$PROJECT_DIR/.git/FETCH_HEAD" ] || fail "spawn fetched in a project with no origin"
  wt=$(meta_worktree "$id")
  [ "$(git -C "$wt" rev-parse HEAD)" = "$INITIAL_SHA" ] || fail "the worktree did not start at the project's local default branch"
  pass "an origin-less project starts its worktree from the local default branch with no fetch"
}

# Each of these leaves origin configured but unusable. Spawn must refuse before
# creating anything, and say that it could not fetch.
test_origin_config_without_url_refuses() {
  local rec id out status
  id='base-origin-without-url-r1'
  rec=$(make_originless_case origin-without-url "$id")
  read_case_record "$rec"
  git -C "$PROJECT_DIR" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite an origin configuration with no URL"
  assert_contains "$out" "could not fetch origin" "spawn did not refuse an origin configuration with no URL as unusable"
  assert_nothing_left_behind "$id"
  pass "an origin configuration without a URL refuses the spawn before creating a worktree"
}

test_empty_origin_config_section_refuses() {
  local rec id out status config
  id='base-empty-origin-section-r1'
  rec=$(make_originless_case empty-origin-section "$id")
  read_case_record "$rec"
  config=$(git -C "$PROJECT_DIR" rev-parse --path-format=absolute --git-path config)
  printf '\n[remote "origin"]\n' >> "$config"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite an empty origin configuration section"
  assert_contains "$out" "could not fetch origin" "spawn did not refuse an empty origin configuration section as unusable"
  assert_nothing_left_behind "$id"
  pass "an empty origin configuration section refuses the spawn before creating a worktree"
}

test_empty_only_included_origin_config_section_launches() {
  local rec id out status config included wt
  id='base-empty-only-included-origin-section-r1'
  rec=$(make_originless_case empty-only-included-origin-section "$id")
  read_case_record "$rec"
  config=$(git -C "$PROJECT_DIR" rev-parse --path-format=absolute --git-path config)
  included=$(dirname "$config")/empty-origin.inc
  printf '[remote "origin"]\n' > "$included"
  git -C "$PROJECT_DIR" config include.path "$(basename "$included")"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn should proceed when an included empty origin section is not enumerable"$'\n'"$out"
  assert_contains "$out" "spawned $id" "spawn did not report success for the undetectable included section"
  assert_not_contains "$out" "could not fetch origin" "spawn treated an undetectable included empty section as a configured origin"
  wt=$(meta_worktree "$id")
  [ "$(git -C "$wt" rev-parse HEAD)" = "$INITIAL_SHA" ] || fail "the worktree did not start at the local default branch"
  pass "an empty-only included origin section documents the accepted detection boundary"
}

test_inactive_conditional_origin_include_launches() {
  local rec id out status config included wt
  id='base-inactive-origin-include-r1'
  rec=$(make_originless_case inactive-origin-include "$id")
  read_case_record "$rec"
  config=$(git -C "$PROJECT_DIR" rev-parse --path-format=absolute --git-path config)
  included=$(dirname "$config")/inactive-origin.inc
  printf '[fm-test]\n\tmarker = true\n[remote "origin"]\n' > "$included"
  git -C "$PROJECT_DIR" config 'includeIf.gitdir:/never/matches/this/worktree/.path' "$included"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn should ignore an inactive conditional origin include"$'\n'"$out"
  assert_contains "$out" "spawned $id" "spawn did not report success with an inactive origin include"
  wt=$(meta_worktree "$id")
  [ "$(git -C "$wt" rev-parse HEAD)" = "$INITIAL_SHA" ] || fail "the worktree did not start at the local default branch"
  pass "an inactive conditional origin include leaves the project origin-less"
}

test_unreachable_origin_refuses_a_stale_base() {
  local rec id out status
  id='base-unreachable-origin-r2'
  rec=$(make_case unreachable-origin "$id")
  read_case_record "$rec"
  git -C "$PROJECT_DIR" remote set-url origin "file://$CASE_DIR/missing-origin.git"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite an unreachable origin"
  assert_contains "$out" "could not fetch origin" "spawn did not clearly refuse an unreachable origin"
  [ "$(git -C "$PROJECT_DIR" rev-parse HEAD)" = "$INITIAL_SHA" ] || fail "spawn moved the project after origin became unreachable"
  assert_nothing_left_behind "$id"
  pass "an unreachable origin refuses a potentially stale base and creates nothing"
}

test_unresolved_remote_default_refuses() {
  local rec id out status
  id='base-unresolved-default-r5'
  rec=$(make_case unresolved-default "$id")
  read_case_record "$rec"
  git --git-dir="$CASE_DIR/origin.git" symbolic-ref HEAD refs/heads/missing-default

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite an unresolved remote default branch"
  assert_contains "$out" "could not resolve origin's current default branch" \
    "spawn did not clearly refuse an unresolved remote default branch"
  assert_nothing_left_behind "$id"
  pass "an unresolved remote default branch refuses the spawn before creating a worktree"
}

# A secondmate home is a linked worktree of the firstmate repository, and it spawns
# tasks of its own. The worktree it gets must be a distinct isolated one: never the
# spawning home itself and never the repository's primary checkout, which must keep
# its HEAD, branch, reflog and files.
test_spawn_from_a_linked_home_leaves_the_primary_untouched() {
  local rec id out status primary spawning wt before_reflog
  id='base-linked-home-r12'
  rec=$(make_case linked-home "$id")
  read_case_record "$rec"
  primary=$PROJECT_DIR
  spawning="$CASE_DIR/secondmate"
  git -C "$primary" worktree add --quiet --detach "$spawning" HEAD
  PROJECT_DIR=$spawning
  before_reflog=$(git -C "$primary" reflog)

  out=$(run_spawn "$id" --scout)
  status=$?
  expect_code 0 "$status" "a scout spawned from a linked home should launch"$'\n'"$out"
  wt=$(meta_worktree "$id")
  [ -d "$wt" ] || fail "the recorded worktree '$wt' does not exist"
  [ "$(cd "$wt" && pwd -P)" != "$(cd "$primary" && pwd -P)" ] || fail "spawn recorded the primary checkout as the task worktree"
  [ "$(cd "$wt" && pwd -P)" != "$(cd "$spawning" && pwd -P)" ] || fail "spawn recorded the spawning home as the task worktree"
  [ "$(git -C "$wt" rev-parse --abbrev-ref HEAD)" = "fm/$id" ] || fail "the task worktree is not on branch fm/$id"
  [ "$(git -C "$primary" rev-parse HEAD)" = "$INITIAL_SHA" ] || fail "spawn moved the primary checkout's HEAD"
  [ "$(git -C "$primary" rev-parse --abbrev-ref HEAD)" = main ] || fail "spawn moved the primary checkout off its branch"
  [ -z "$(git -C "$primary" status --porcelain)" ] || fail "spawn dirtied the primary checkout"
  [ "$(git -C "$primary" reflog)" = "$before_reflog" ] || fail "spawn touched the primary reflog from a linked home"
  pass "a spawn from a linked home creates a distinct worktree and leaves the primary checkout untouched"
}

# A remote-routed secondmate home spawns tasks like any other home: the route marker
# only describes where its parent lives and must not change how its tasks start.
test_remote_seeded_home_spawns_its_own_worktree() {
  local rec id out status wt
  id='base-remote-seeded-r13'
  rec=$(make_case remote-seeded "$id")
  read_case_record "$rec"
  cat > "$HOME_DIR/.fm-secondmate-parent" <<'REC'
schema=fm-secondmate-parent.v1
route=remote
parent_host=parent-machine
REC

  out=$(run_spawn "$id" --scout)
  status=$?
  expect_code 0 "$status" "a remote-seeded secondmate home should create a worktree and launch"$'\n'"$out"
  assert_contains "$out" "spawned $id" "the remote-seeded spawn did not report success"
  wt=$(meta_worktree "$id")
  [ -d "$wt" ] || fail "the remote-seeded spawn did not publish a real worktree"
  [ "$(git -C "$wt" rev-parse HEAD)" = "$(git -C "$PROJECT_DIR" rev-parse origin/main)" ] \
    || fail "the remote-seeded spawn did not start at the fetched origin tip"
  pass "a remote-seeded secondmate home creates its task worktree from the fetched origin tip"
}

test_new_worktree_starts_at_the_fetched_origin_tip
test_a_second_task_starts_at_the_same_current_tip
test_non_main_default_branch_is_resolved_and_fetched
test_direct_pr_and_scout_start_at_the_fetched_tip
test_the_projects_own_uncommitted_work_is_left_alone
test_originless_project_starts_from_its_local_default_branch
test_origin_config_without_url_refuses
test_empty_origin_config_section_refuses
test_empty_only_included_origin_config_section_launches
test_inactive_conditional_origin_include_launches
test_unreachable_origin_refuses_a_stale_base
test_unresolved_remote_default_refuses
test_spawn_from_a_linked_home_leaves_the_primary_untouched
test_remote_seeded_home_spawns_its_own_worktree
