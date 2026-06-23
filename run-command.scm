;;; run-command.scm - run a shell command with timeout, capturing stdout/stderr.
;;;
;;; Usage:
;;;   (require "run-command.scm")
;;;   (run-command "curl -s https://example.com" 5000)
;;;     ; => (Ok (cons stdout-string stderr-string))
;;;     ; => (Err "Command timed out after 5000ms")   on timeout
;;;     ; => (Err <spawn error>)                       if the shell can't start

(require-builtin steel/process)
(require-builtin steel/time)

(provide run-command)

;; Timeout is enforced inside the shell rather than with steel's `kill`.
;;
;; Steel's `kill` does Child.take() then SIGKILLs and drops the handle WITHOUT
;; reaping, and leaves nothing to `wait` on afterwards, so every killed process
;; becomes a zombie (no PID is exposed to reap it out-of-band). Instead we run
;; the command under an in-shell watchdog: the shell backgrounds the command,
;; kills it after the timeout, and `wait`s on it, so the shell reaps the
;; command. Steel's `wait` then reaps the shell.
;;
;; The watchdog exits 124 on timeout (matching timeout(1)). $1 is the command
;; string, $2 the timeout in (fractional) seconds.
(define watchdog
  (string-append
    "sh -c \"$1\" &\n"
    "cpid=$!\n"
    "( sleep \"$2\"; kill -9 \"$cpid\" 2>/dev/null ) >/dev/null 2>&1 &\n"
    "wpid=$!\n"
    "wait \"$cpid\"; status=$?\n"
    "kill \"$wpid\" 2>/dev/null; wait \"$wpid\" 2>/dev/null\n"
    "if [ \"$status\" -ge 128 ]; then exit 124; else exit \"$status\"; fi\n"))

;; Exit code the watchdog uses to signal a timeout.
(define timeout-exit-code 124)

(define (run-command cmd-str timeout-ms)
  "Run CMD-STR via /bin/sh with a TIMEOUT-MS millisecond timeout.
   Returns (Result (cons stdout stderr)); Err on spawn failure or timeout.

   stdout/stderr are drained through their child ports on reader threads (not
   `wait->stdout`, which would seize the child handle), then `wait` reaps the
   shell once both pipes hit EOF."
  (let [(child-result (->
                       (command "/bin/sh"
                         (list "-c" watchdog "sh" cmd-str
                           (number->string (/ timeout-ms 1000))))
                       (set-piped-stdout!)
                       (spawn-process)))]
    (if (Err? child-result)
      child-result
      (let* ([child (Ok->value child-result)]
             [out-port (child-stdout child)]
             [err-port (child-stderr child)]
             [out-box (box "")]
             [err-box (box "")]
             ;; Drain both streams concurrently; each returns on pipe EOF, i.e.
             ;; once the shell (and its command) has exited.
             [out-t (spawn-native-thread
                     (lambda ()
                       (set-box! out-box (if out-port
                                          (read-port-to-string out-port)
                                          ""))))]
             [err-t (spawn-native-thread
                     (lambda ()
                       (set-box! err-box (if err-port
                                          (read-port-to-string err-port)
                                          ""))))])
        (thread-join! out-t)
        (thread-join! err-t)
        ;; `wait` reaps the shell and yields its exit code (as a Result).
        (let ([code (Ok->value (wait child))])
          (if (equal? code timeout-exit-code)
            (Err (string-append "Command timed out after "
                  (number->string timeout-ms)
                  "ms"))
            (Ok (cons (unbox out-box) (unbox err-box)))))))))
