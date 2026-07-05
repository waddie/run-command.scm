;;; run-command.scm - run commands with capture, optional timeout, stdin, and env.
;;;
;;; Usage:
;;;   (require "run-command/run-command.scm")
;;;
;;;   (run-command "curl -s https://example.com")
;;;   (run-command "curl -s https://example.com" (hash 'timeout-ms 5000))
;;;   (run-argv "git" (list "status") (hash 'env (hash "GIT_PAGER" "cat")))
;;;
;;; Both return a result hash:
;;;   'stdout    captured standard output (string)
;;;   'stderr    captured standard error (string)
;;;   'exit      integer exit code, or #f if killed by a signal
;;;   'ok        #t when the command ran and exited 0, #f otherwise
;;;   'timed-out #t when a timeout killed the command, #f otherwise
;;;
;;; Errors are returned as data: a spawn failure yields 'ok #f with the error
;;; text in 'stderr. Nothing is thrown.

(require-builtin steel/process)

(provide run-command run-argv)

;; Timeout is enforced by an in-shell watchdog rather than Steel's `kill`.
;;
;; Steel's `kill` does Child.take() then SIGKILLs and drops the handle WITHOUT
;; reaping, leaving nothing to `wait` on, so every killed process becomes a
;; zombie (no PID is exposed to reap it out-of-band). Instead the command runs
;; under a shell watchdog: the shell backgrounds the command, kills it after
;; the timeout, and `wait`s on it, so the shell reaps the command. Steel's
;; `wait` then reaps the shell.
;;
;; The watchdog passes the command as positional argv (`"$@"`), so `run-argv`
;; arguments are never re-split by the shell. $1 is the timeout in (fractional)
;; seconds; the remaining positionals are the program and its arguments.
;;
;; The watchdog passes the child's real exit status straight through (`exit
;; "$status"`). A command SIGKILLed by the watchdog reports 128+9 = 137, which
;; is how a timeout is detected. A command that genuinely exits 124 (or any
;; code < 128) is therefore NOT misread as a timeout.
;;
;; STDIN-REDIRECT is the redirection applied to the backgrounded command's
;; stdin. POSIX assigns an asynchronous (`&`) command /dev/null stdin unless it
;; is explicitly redirected, so piped input must be reconnected with `<&0`.
(define (make-watchdog stdin-redirect)
  (string-append
    "timeout=\"$1\"; shift\n"
    "\"$@\" "
    stdin-redirect
    " &\n"
    "cpid=$!\n"
    "( sleep \"$timeout\"; kill -9 \"$cpid\" 2>/dev/null ) >/dev/null 2>&1 &\n"
    "wpid=$!\n"
    "wait \"$cpid\"; status=$?\n"
    "kill \"$wpid\" 2>/dev/null; wait \"$wpid\" 2>/dev/null\n"
    "exit \"$status\"\n"))

;; Feed the shell's own stdin (piped input) to the backgrounded command.
(define watchdog-stdin (make-watchdog "<&0"))
;; No input: give the backgrounded command an immediate-EOF stdin.
(define watchdog-no-stdin (make-watchdog "</dev/null"))

;; Exit status of a command terminated by SIGKILL (128 + 9). The watchdog's
;; timeout kill produces this, so it marks a timeout.
(define sigkill-exit-code 137)

;; Build the uniform result hash. `ok` is derived from a clean zero exit.
(define (make-result stdout stderr exit timed-out)
  (hash 'stdout stdout
    'stderr
    stderr
    'exit
    exit
    'ok
    (equal? exit 0)
    'timed-out
    timed-out))

;; Read KEY from an options hash, falling back to DEFAULT when absent.
(define (option-ref opts key default)
  (if (and (hash? opts) (hash-contains? opts key))
    (hash-ref opts key)
    default))

;; Merge a string->string env hash onto the command's environment.
(define (apply-env! cmd env)
  (when (hash? env)
    (for-each (lambda (k) (set-env-var! cmd k (hash-ref env k)))
      (hash-keys->list env)))
  cmd)

;; Spawn the built CMD, optionally feed STDIN-INPUT (a string) and close it,
;; drain stdout and stderr concurrently on native threads (so output larger
;; than the pipe buffer cannot deadlock), then `wait` to reap. TIMED-OUT-FN
;; maps the exit code to the timed-out flag. Errors are returned as data.
(define (capture cmd stdin-input timed-out-fn)
  (with-handler
    (lambda (err) (make-result "" (to-string err) #f #f))
    (let ([spawn-result (spawn-process cmd)])
      (if (Err? spawn-result)
        (make-result "" (to-string (Err->value spawn-result)) #f #f)
        (let* ([child (Ok->value spawn-result)]
               ;; Feed stdin first (and close it) so a command reading from `-`
               ;; sees EOF and proceeds before we drain stdout.
               [_ (when (string? stdin-input)
                   (let ([sin (child-stdin child)])
                     (when sin
                       (display stdin-input sin)
                       (close-output-port sin))))]
               [out-box (box "")]
               [err-box (box "")]
               ;; Each reader returns on its pipe's EOF, so neither can wedge
               ;; the other. Reap only once both pipes have closed.
               [out-t (spawn-native-thread
                       (lambda ()
                         (set-box! out-box
                           (let ([o (child-stdout child)])
                             (if o (read-port-to-string o) "")))))]
               [err-t (spawn-native-thread
                       (lambda ()
                         (set-box! err-box
                           (let ([e (child-stderr child)])
                             (if e (read-port-to-string e) "")))))]
               [_ (thread-join! out-t)]
               [_ (thread-join! err-t)]
               [wait-result (wait child)]
               [exit (if (Ok? wait-result) (Ok->value wait-result) #f)])
          (make-result (unbox out-box) (unbox err-box) exit
            (timed-out-fn exit)))))))

;; No timeout: spawn PROGRAM/ARGS directly (no shell for `run-argv`).
(define (run-direct program args stdin-input env)
  (let ([cmd (command program args)])
    (apply-env! cmd env)
    (set-piped-stdout! cmd)
    (capture cmd stdin-input (lambda (exit) #f))))

;; With a timeout: run PROGRAM/ARGS under the shell watchdog.
(define (run-with-timeout program args timeout-ms stdin-input env)
  (let* ([wd (if (string? stdin-input) watchdog-stdin watchdog-no-stdin)]
         [seconds (number->string (exact->inexact (/ timeout-ms 1000)))]
         [cmd (command "/bin/sh"
               (append (list "-c" wd "sh" seconds program) args))])
    (apply-env! cmd env)
    (set-piped-stdout! cmd)
    (capture cmd stdin-input
      (lambda (exit) (equal? exit sigkill-exit-code)))))

;; Dispatch on whether a timeout was requested.
(define (run-process program args opts)
  (let ([timeout-ms (option-ref opts 'timeout-ms #f)]
        [stdin-input (option-ref opts 'stdin #f)]
        [env (option-ref opts 'env #f)])
    (if timeout-ms
      (run-with-timeout program args timeout-ms stdin-input env)
      (run-direct program args stdin-input env))))

;;@doc
;; Run CMD-STR via `/bin/sh -c`, returning a result hash (see below).
;;
;; An optional OPTS hash may carry:
;;   'timeout-ms  integer - kill the command after this many milliseconds
;;   'stdin       string  - write to the command's stdin, then close it
;;   'env         hash    - string->string environment variables to set
;;
;; The result hash has:
;;   'stdout    captured stdout (string)
;;   'stderr    captured stderr (string)
;;   'exit      integer exit code, or #f if killed by a signal
;;   'ok        #t when the command ran and exited 0
;;   'timed-out #t when a timeout killed the command
;;
;; stdout and stderr are drained concurrently, so output larger than the pipe
;; buffer will not deadlock. A spawn failure returns 'ok #f with the error text
;; in 'stderr rather than throwing.
(define (run-command cmd-str . opts)
  (run-process "/bin/sh" (list "-c" cmd-str)
    (if (null? opts) (hash) (car opts))))

;;@doc
;; As `run-command`, but run PROGRAM directly with ARGS (a list of strings),
;; with no shell, so arguments are never subject to word-splitting or globbing.
;; Accepts the same optional OPTS hash and returns the same result hash.
(define (run-argv program args . opts)
  (run-process program args
    (if (null? opts) (hash) (car opts))))
