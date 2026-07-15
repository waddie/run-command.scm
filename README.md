# run-command.scm

Run commands in Steel Scheme, capturing `stdout`/`stderr` and exit status, with
optional timeout, stdin, and environment.

## Install

Install with [forge](https://github.com/mattwparas/steel), Steel’s package
manager:

```sh
forge pkg install --git https://github.com/waddie/run-command.scm
```

## Usage

```scheme
(require "run-command/run-command.scm")

(run-command "echo hello")
;; => #hash('stdout "hello\n" 'stderr "" 'exit 0 'ok #t 'timed-out #f)

(run-argv "git" (list "status") (hash 'env (hash "GIT_PAGER" "cat")))

(run-command "curl -s https://example.com" (hash 'timeout-ms 5000))
```

Two entry points, both returning the same result hash:

- `(run-command cmd-str [opts])` runs `cmd-str` via `/bin/sh -c`.
- `(run-argv program args [opts])` runs `program` directly with `args` (a list
  of strings), with no shell, so arguments are never word-split or globbed.

Running tests requires [steel-test](https://github.com/waddie/steel-test)
installed.

```sh
steel test/run-command-test.scm
```

### Options

`opts` is an optional hash. All keys are optional:

| key           | type   | effect                                        |
| ------------- | ------ | --------------------------------------------- |
| `'timeout-ms` | int    | kill the command after this many milliseconds |
| `'stdin`      | string | write to the command's stdin, then close it   |
| `'env`        | hash   | string->string environment variables to set   |

### Result hash

| key          | value                                                  |
| ------------ | ------------------------------------------------------ |
| `'stdout`    | captured standard output (string)                      |
| `'stderr`    | captured standard error (string)                       |
| `'exit`      | integer exit code, or `#f` if killed by a signal       |
| `'ok`        | `#t` when the command ran and exited 0, `#f` otherwise |
| `'timed-out` | `#t` when a timeout killed the command, `#f` otherwise |

Errors are returned as data, never thrown: a spawn failure (for example a
missing binary) yields `'ok #f` with the error text in `'stderr`.

`stdout` and `stderr` are drained concurrently on separate threads, so output
larger than the pipe buffer will not deadlock.

### Timeout

The timeout is enforced by an in-shell watchdog rather than by killing the
process from Steel: the shell backgrounds the command, kills it after the
timeout, and `wait`s on it. This avoids leaving zombie processes. A timed-out
command is terminated with `SIGKILL`; `'timed-out` is `#t` and `'exit` is 137.

A command that genuinely exits 124 (or any code below 128) is not misreported as
a timeout. The one ambiguity: a command that is itself killed by a signal while
a timeout is set, or that genuinely exits 137, is reported as `'timed-out #t`.

## Platform

Unix only. Requires `/bin/sh` and POSIX signal semantics; it does not work on
Windows.

## License

Copyright © 2026 Tom Waddington

Distributed under the MIT License. See LICENSE file for details.
