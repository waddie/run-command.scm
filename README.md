# run-command.scm

Run a shell command in Steel Scheme, capturing `stdout`/`stderr`, with timeout.

## Install

Install with [forge](https://github.com/mattwparas/steel), Steel’s package manager:

```sh
forge pkg install --git https://github.com/waddie/run-command.scm
```

## Usage

```scheme
(require "run-command/run-command.scm")

(run-command "echo hello" 5000)
;; => (Ok (cons "hello\n" ""))
```

`(run-command cmd-str timeout-ms)` runs `cmd-str` via `/bin/sh -c` with a
timeout of `timeout-ms` milliseconds. It returns a `Result`:

- `(Ok (cons stdout stderr))` on completion, where both are strings.
- `(Err "Command timed out after <n>ms")` if the command exceeds the timeout.
- `(Err <spawn error>)` if the shell fails to start.

`stdout` and `stderr` are drained concurrently on separate threads, so output
larger than the pipe buffer will not deadlock.

The timeout is enforced by an in-shell watchdog rather than by killing the
process from Steel: the shell backgrounds the command, kills it after the
timeout, and `wait`s on it. This avoids leaving zombie processes.

## License

Copyright © 2026 Tom Waddington

Distributed under the MIT License. See LICENSE file for details.
