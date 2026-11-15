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
The live smoke test skips unless it is set.

## Identity model

A task is one hc terminal.
Its stable id is the local address `t<N>`, which `create_task` prints and every other function takes as the target.
The terminal is named `fm-<task-id>` and labelled `fm_task=<task-id>`.
The name is a guard and a lookup aid, never the target.
Remote-machine addresses (`machine/tN`) and names are refused as targets.
A name is 1-32 characters from a-z 0-9 - _, and only live terminals compete for a name.

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
  Trailing blank rows are trimmed, so a short screen yields fewer lines than tmux would.
  The adapter keeps the last N lines of the combined output.
- `hc kill <addr>` prints the terminal's JSON and ends it.
  `hc rm <addr>` removes a finished terminal and printed `{"removed":"tN"}`.
  Running `rm` right after `kill` worked in testing, and the adapter retries it briefly.
- `hc send` refuses a program blocked on a dialog unless `--force` is given.
  The adapter never passes `--force`, so a blocked worker surfaces as `send-failed` instead of having a dialog answered by accident.

## Adapter contract

The adapter exports these functions with the `fm_backend_hc_` prefix: `bin`, `tool_check`, `cli`, `target_valid`, `get`, `resolve_bare_selector`, `capture`, `normalize_key`, `send_key`, `composer_state`, `send_text_submit`, `container_ensure`, `create_task`, `current_path`, `send_text_line`, `send_literal`, `kill`, `target_exists`, `agent_state`, and `agent_alive`.
`create_task` refuses a live terminal with the same name and any result that is not a local address.
`kill` refuses anything that is not a local `tN` address, and also any terminal whose name does not start with `fm-`, because addresses can be renumbered after a server restart.
`agent_state` never reports `dead` on a transport or parse failure.
`send_text_submit` types once with `hc send`, then retries Enter only (`hc keys enter`) while the shared composer verdict reads pending.
`send_literal` types per key, handles only the accepted characters above, and refuses everything else before sending any key.
Spawn code should use `send_text_line` (paste plus Enter) for hc instead.

## Active limits

- Local machine only; remote-machine addresses are refused.
- No events or push stream, no busy-state detection, and no composer identity probe.
  Because `hc read` is plain text, a composer holding text reads `unknown` for most agents and the separated Pi composer reads `unknown`, so a submit to those is reported unconfirmed rather than delivered.
- No away-mode supervisor on this backend.
- `hc send` without `--force` will not type into a blocked program.

## Tests

- `bash tests/fm-backend-hc.test.sh` runs the offline suite against a fake `herdr-core` on `PATH`.
- `bash tests/fm-backend-hc-smoke.test.sh` runs live against the real server and creates one terminal named `fm-test-smoke-<pid>`.
  It skips when `HC_TERMINAL_ID` is unset or the binary is missing.
  Every typing or killing call goes through a guard that requires the terminal to be the one the test created and its name to start with `fm-test-`.
  An exit trap cleans up and compares the `hc ls` address set before and after.
