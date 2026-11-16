#!/usr/bin/env bash
# tests/secondmate-helpers.sh - shared fixtures and mocks for the secondmate
# suites (fm-secondmate-lifecycle-e2e and fm-secondmate-safety).
#
# These mocks encode secondmate-lifecycle behavior (fake tmux that logs window
# ops, fake no-mistakes that records init/doctor), so they live here rather than
# in the generic tests/lib.sh. The generic git/identity/meta primitives come from
# lib.sh, which this file pulls in.
#
# Secondmate homes are Worktrunk worktrees of a firstmate repository, created and
# removed by the REAL wt and git. A suite that seeds one MUST point the seed at a
# scratch firstmate repository (fm_test_scratch_firstmate_root, passed as
# FM_ROOT_OVERRIDE): left unset, the seed treats the repository hosting the tests
# as the firstmate repository and creates its fm-home/<id> branch and worktree
# there. Sourcing this file arms the real-repository tripwire from lib.sh so a
# suite that forgets fails loudly instead of leaking.

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_test_arm_repo_tripwire

# fm_test_scratch_firstmate_root <dest>
# Builds a throwaway firstmate git repository at <dest> (branch main, one commit,
# no remote) holding a copy of this checkout's files, working-tree edits included,
# so the scripts a seed runs from FM_ROOT are the ones under test. wt creates
# secondmate homes beside it in <dest>-worktrees/. Echoes the physical path.
fm_test_scratch_firstmate_root() {
  local dest=$1 f
  mkdir -p "$dest"
  while IFS= read -r -d '' f; do
    [ -f "$ROOT/$f" ] || continue
    mkdir -p "$dest/$(dirname "$f")"
    cp -p "$ROOT/$f" "$dest/$f"
  done < <(git -C "$ROOT" ls-files -z --cached --others --exclude-standard -- . ':!tests')
  git -C "$dest" init -q -b main
  git -C "$dest" add -A
  git -C "$dest" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm 'scratch firstmate root'
  (cd "$dest" && pwd -P)
}

# fm_test_scratch_home_path <scratch-root> <id>
# The path wt gave the fm-home/<id> worktree of a scratch root, read from git.
fm_test_scratch_home_path() {
  git -C "$1" worktree list --porcelain | awk -v b="refs/heads/fm-home/$2" '
    /^worktree /{p=substr($0,10)} $0=="branch " b {print p}'
}

# A fake tmux (window ops are logged to FM_FAKE_TMUX_LOG, list-windows returns
# FM_FAKE_TMUX_WINDOW, capture-pane echoes FM_FAKE_TMUX_CAPTURE). Echoes the
# fakebin dir.
make_fake_tmux() {
  local dir=$1 fakebin capture
  fakebin=$(fm_fakebin "$dir")
  capture="$dir/pane.txt"
  # A real, positively identified empty agent composer. A blank capture is
  # deliberately unknown under the fleet-wide strict blank-row posture.
  printf '❯\n' > "$capture"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  has-session|new-session|new-window|send-keys|kill-window)
    printf '%s\n' "$*" >> "$FM_FAKE_TMUX_LOG"
    exit 0
    ;;
  list-windows)
    session=
    prev=
    for arg in "$@"; do
      if [ "$prev" = -t ]; then session=$arg; break; fi
      prev=$arg
    done
    while IFS= read -r recorded; do
      [ -n "$recorded" ] || continue
      if [ -z "$session" ]; then
        printf '%s\n' "$recorded"
        continue
      fi
      case "$recorded" in
        "$session":*) printf '%s\n' "${recorded#*:}" ;;
        *:*) ;;
        *) printf '%s\n' "$recorded" ;;
      esac
    done <<EOF
${FM_FAKE_TMUX_WINDOW:-}
EOF
    exit 0
    ;;
  display-message)
    case "$*" in
      *'#{cursor_y}'*) printf '0\n' ;;
      *) printf 'firstmate\n' ;;
    esac
    exit 0
    ;;
  capture-pane)
    printf '%s\n' "$*" >> "$FM_FAKE_TMUX_LOG"
    cat "$FM_FAKE_TMUX_CAPTURE"
    exit 0
    ;;
esac
exit 1
SH
  chmod +x "$fakebin/tmux"
  : > "$dir/tmux.log"
  printf '%s\n' "$fakebin"
}

# A fake no-mistakes that touches .no-mistakes-init / .no-mistakes-doctor markers.
make_fake_no_mistakes() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -eu
case "${1:-}" in
  init) touch .no-mistakes-init ;;
  doctor) touch .no-mistakes-doctor ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$fakebin/no-mistakes"
  printf '%s\n' "$fakebin"
}

# A fake no-mistakes that records each "<pwd>\t<verb>" call to
# FM_FAKE_NO_MISTAKES_LOG and fails for the project named FM_FAKE_NO_MISTAKES_FAIL_PROJECT.
make_recording_no_mistakes() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\t%s\n' "$PWD" "${1:-}" >> "$FM_FAKE_NO_MISTAKES_LOG"
if [ "$(basename "$PWD")" = "${FM_FAKE_NO_MISTAKES_FAIL_PROJECT:-}" ]; then
  exit 1
fi
case "${1:-}" in
  init) touch .no-mistakes-init ;;
  doctor) touch .no-mistakes-doctor ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$fakebin/no-mistakes"
  printf '%s\n' "$fakebin"
}

# Make a directory look like a minimal firstmate home (AGENTS.md + bin/).
mark_firstmate_home() {
  local home=$1
  mkdir -p "$home/bin"
  printf '# Firstmate\n' > "$home/AGENTS.md"
}

# A firstmate home that is also a real git repo (so it can host detached
# worktrees for teardown/lease tests).
make_firstmate_git_root() {
  local home=$1
  mkdir -p "$home/bin"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  cat > "$home/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$home/bin/fm-guard.sh"
  git -C "$home" init -q
  git -C "$home" add AGENTS.md bin/fm-guard.sh
  git -C "$home" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
}

# Scaffold a filled secondmate charter brief under <home>/data/<id>/brief.md.
# Args: home id charter [project...]
scaffold_secondmate_charter() {
  local home=$1 id=$2 charter=$3
  shift 3
  FM_HOME="$home" FM_SECONDMATE_CHARTER="$charter" "$ROOT/bin/fm-brief.sh" "$id" --secondmate "$@" >/dev/null
}

# Make a directory look like a genuine seeded secondmate home (for handoff tests).
seed_secondmate_home_marker() {
  local home=$1 id=$2
  mark_firstmate_home "$home"
  mkdir -p "$home/data"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
}

# Wait up to <limit> 0.1s ticks while <pid> stays alive. Returns 1 if it dies.
wait_live() {
  local pid=$1 limit=${2:-30} i=0
  while [ "$i" -lt "$limit" ]; do
    if ! kill -0 "$pid" 2>/dev/null; then
      return 1
    fi
    sleep 0.1
    i=$((i + 1))
  done
  return 0
}
