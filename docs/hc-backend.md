# hc backend

The `hc` backend drives firstmate tasks as terminals on an `hc` (herdr-core) server.
It is a different tool from the `herdr` CLI that [`herdr-backend.md`](herdr-backend.md) covers, with a different command set and no shared code.
The adapter is `bin/backends/hc.sh`; its header comment owns the mechanics.

## Setup

Install the `herdr-core` binary (also invoked as `hc`) and `jq`.
The adapter prefers `herdr-core` on `PATH` and falls back to `hc`.
Every hc call goes through one function, `fm_backend_hc_cli`, so a test can shim the binary in one place.
The adapter was verified against hc 0.1.21.

## Detection

A shell running inside an hc terminal has `HC_TERMINAL_ID` set (for example `t5`).
That variable is the signal that an hc server exists and the session is attached to it.
It is not consent to touch the server: the live smoke test runs only when `FM_HC_LIVE=1` is also set.

## Identity model

A task is one hc terminal.
Its recorded id is the local address `t<N>`, which `create_task` prints and every other function takes as the target.
`<N>` is lowercase letters and digits (live addresses include `t19`, `t1b`, `t1h`).
The terminal is named `fm-<task-id>` and labelled `fm_task=<task-id>`.
Remote-machine addresses (`machine/tN`) and names are refused as targets.
A name is 1-32 characters from a-z 0-9 - _, and only live terminals compete for a name.

## Name guard

hc can renumber addresses after a server restart, so a recorded address alone must never reach a terminal that holds someone else's work.
Every action that sends input, kills, or reads a screen first confirms that `hc get <addr>` returns a `.name` exactly equal to the expected label `fm-<task-id>`.
It then confirms that `hc get <label>` maps back to the same address, and acts on the NAME, so the final call cannot land on a different terminal.
Every call, read-only ones included, refuses when no expected label is supplied; `agent_state` then reports `unreadable`.
A present terminal under another name, or no name, is refused and `agent_state` reports `ambiguous`, never `dead`, so it cannot license a relaunch.
Only a definitive `not_found` is `missing`.
The expected label is the last optional argument of every adapter function, as the dispatcher in `bin/fm-backend.sh` passes it (`kill` takes it third: target, unused tab id, label).

## Verified findings (hc 0.1.21)

- `hc run --bg --json --name N --cwd DIR --no-parent --no-notify` with no command starts the machine's login shell and prints JSON with the new address.
  `--no-parent` is required when firstmate itself runs inside an hc terminal, otherwise the child dies with its parent.
- `hc get <addr> --json` `.cwd` is frozen at creation.
  `.foreground.cwd` follows a plain `cd` in the shell, so `current_path` reads `.foreground.cwd`.
  Evidence: after `cd` into a second directory `.cwd` stayed the first directory while `.foreground.cwd` became the second.
- `.foreground` is `{argv, cwd, name, pid}` for the foreground process.
  An idle shell is `name=zsh`, `argv=["/bin/zsh","-l"]`.
  A running `sleep 40` is `name=sleep`.
  A node-hosted `pi` is `name=node`, `argv[0]=pi`, which the shared classifier recognises through argv[0].
  An interpreted script run as `sh script` shows the interpreter, not the script name.
  `.foreground.pid` is the leader of the terminal's foreground process group.
  A launch wrapped in `/bin/sh -c ...` makes the wrapper shell the leader and the agent its child in the same group, so classifying the leader alone misreads a live agent as an idle shell.
- `.status` is `{"app":"pi","state":"idle|working|done"}` for a harness hc recognises, and null otherwise.
  It is the native agent identity and state probe behind the composer verdict for pi.
- `hc read` prints the whole screen (120 rows for a terminal started by `hc run --bg`), top-anchored.
  A short TUI therefore sits at the BOTTOM of mostly blank rows: pi draws its composer as a blank row between two rules just above a two-line footer.
- Addresses are not decimal: after `t19` hc handed out `t1b` through `t1h`.
- `.foreground` is null once a terminal has finished, and `.state` is then `finished`.
- Errors are JSON on stderr with `.error.kind` and a nonzero exit.
  A missing address is exit 3 with kind `not_found` (an unknown machine prefix is exit 4, an empty address exit 7, input to a finished terminal exit 11).
  Only the `not_found` case is treated as definitively missing; everything else is unreadable.
- `hc send <addr> -- <text>` pastes the text and presses Enter in one call.
  Quotes, `$`, and repeated spaces survive.
  The `--` is needed so text with a leading dash is not parsed as an option.
- `hc keys <addr> <key>...` presses one key per argument.
  A multi-character argument is rejected with `invalid_params`, so there is no unsubmitted-paste primitive.
  Accepted single characters: a-z, 0-9, `- . / = , ' [ ] \ ; backquote`, and `space`.
  Rejected: `_ : ~ " $ * @ # % & ( ) { } < > | ! ? + ^`.
  An uppercase letter is accepted but was observed typed as lowercase.
  Named keys that work: `enter esc tab up down left right backspace space home end delete pageup ctrl+c ctrl+u ctrl+d ctrl+a ctrl+e ctrl+l ctrl+w shift+tab`.
  `bspace` is rejected, so the adapter maps `BSpace` to `backspace`.
- `hc read <addr> --lines N` prints the screen plus N lines of history above it.
  Trailing blank rows are trimmed, so a short screen can yield fewer lines than tmux would.
  The adapter keeps the last N lines of the combined output, which is where the composer lives.
- `hc kill <addr>` prints the terminal's JSON and ends it.
  `hc rm <addr>` removes a finished terminal and printed `{"removed":"tN"}`.
  Running `rm` right after `kill` worked in testing, and the adapter retries it briefly.
- `hc send` refuses a program blocked on a dialog unless `--force` is given.
  The adapter never passes `--force`, so a blocked worker surfaces as `send-failed` instead of having a dialog answered by accident.

## Adapter contract

The adapter exports these functions with the `fm_backend_hc_` prefix: `bin`, `tool_check`, `cli`, `target_valid`, `label_valid`, `get`, `get_ref`, `verify`, `ref`, `native_status`, `resolve_bare_selector`, `capture`, `normalize_key`, `send_key`, `composer_state`, `send_text_submit`, `container_ensure`, `create_task`, `current_path`, `send_text_line`, `send_literal`, `kill`, `target_exists`, `group_members`, `agent_state`, and `agent_alive`.
`create_task` refuses a live terminal with the same name and any result that is not a local address.
`kill` follows the name guard above, ends the terminal by name, and removes it only while its name is still the expected one.
A spawn that aborts closes the terminal that very run created, and only while the name is still `fm-<task-id>`.
`agent_state` never reports `dead` on a transport or parse failure.
`agent_state` classifies every process in the foreground process group of `.foreground.pid` with the shared classifier: any agent is `alive`, only shells is `dead`, anything else is `ambiguous`, and an unreadable group is `ambiguous`.
A login shell that is still running its startup files reads `ambiguous` until it settles.
`composer_state` reads hc's native `.status` as the agent identity, so a pi composer is `empty` for an idle or done pi, `pending` while it holds text, and `unknown` while the pi works or when no identity is reported.
`send_text_submit` types once with `hc send`, then retries Enter only (`hc keys enter`) while the shared composer verdict reads pending.
It also confirms a send to an idle or done agent when hc then reports it `working` (the turn started), and reads a pending composer as queued while the agent works; without an idle baseline an `unknown` stays `unknown`.
`send_literal` types per key, handles only the accepted characters above, and refuses everything else before sending any key.
Spawn code should use `send_text_line` (paste plus Enter) for hc instead.

## Active limits

- Local machine only; remote-machine addresses are refused.
- No events or push stream and no busy-state dispatch.
  Because `hc read` is plain text, a composer holding text reads `unknown` for harnesses that need styling to separate ghost text from typed text, so a submit to those is reported unconfirmed rather than delivered.
- No away-mode supervisor on this backend.
- `hc send` without `--force` will not type into a blocked program.

## Tests

- `bash tests/fm-backend-hc.test.sh` runs the offline suite against a fake `herdr-core` on `PATH`, plus real processes for the foreground-group case and real pi screens captured from a live hc terminal (`tests/assets/hc-pi/`, scrubbed above the composer).
- `bash tests/fm-spawn-wt.test.sh` runs `fm-spawn.sh` against real `wt` and git, including a failing and a slow pre-start hook.
- `FM_HC_LIVE=1 bash tests/fm-backend-hc-smoke.test.sh` runs live against the real server and creates one terminal named `fm-test-smoke-<pid>`.
  It prints SKIP and exits 0 unless `FM_HC_LIVE=1` is set and the binary is present.
  Every typing or killing call goes through a guard that requires the terminal to be the one the test created and its name to start with `fm-test-`.
  An exit trap cleans up and compares the `hc ls` address set before and after.
