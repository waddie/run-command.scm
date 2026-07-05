;;; run-command-test.scm - exercise the run-command library end to end.
;;;
;;; Run from the repository root:
;;;   steel test/run-command-test.scm

(require "../run-command.scm")

(define failures (box 0))

(define (check label actual expected)
  (if (equal? actual expected)
    (displayln (string-append "ok    " label))
    (begin
      (set-box! failures (+ (unbox failures) 1))
      (displayln (string-append "FAIL  " label))
      (displayln (string-append "        expected: " (to-string expected)))
      (displayln (string-append "        actual:   " (to-string actual))))))

(define (get r k) (hash-ref r k))

;; 1. run-argv success
(let ([r (run-argv "echo" (list "hi"))])
  (check "argv echo stdout" (get r 'stdout) "hi\n")
  (check "argv echo exit" (get r 'exit) 0)
  (check "argv echo ok" (get r 'ok) #t)
  (check "argv echo timed-out" (get r 'timed-out) #f))

;; 2. run-command shell form
(let ([r (run-command "echo hello")])
  (check "shell echo stdout" (get r 'stdout) "hello\n")
  (check "shell echo ok" (get r 'ok) #t))

;; 3. exit code surfaced
(let ([r (run-command "exit 3")])
  (check "exit3 exit" (get r 'exit) 3)
  (check "exit3 ok" (get r 'ok) #f)
  (check "exit3 timed-out" (get r 'timed-out) #f))

;; 4. argv: no shell word-splitting/globbing
(let ([r (run-argv "printf" (list "%s" "a b*c"))])
  (check "argv no-split stdout" (get r 'stdout) "a b*c"))

;; 5. stdin (no timeout)
(let ([r (run-command "cat" (hash 'stdin "piped\n"))])
  (check "stdin cat" (get r 'stdout) "piped\n"))

;; 6. env
(let ([r (run-command "printf %s \"$FOO\"" (hash 'env (hash "FOO" "bar")))])
  (check "env FOO" (get r 'stdout) "bar"))

;; 7. timeout fires
(let ([r (run-command "sleep 5" (hash 'timeout-ms 200))])
  (check "timeout timed-out" (get r 'timed-out) #t)
  (check "timeout ok" (get r 'ok) #f))

;; 8. genuine exit 124 under a generous timeout is not a timeout
(let ([r (run-command "exit 124" (hash 'timeout-ms 5000))])
  (check "exit124 exit" (get r 'exit) 124)
  (check "exit124 timed-out" (get r 'timed-out) #f))

;; 9. large output does not deadlock
(let ([r (run-command "yes | head -100000")])
  (check "large output ok" (get r 'ok) #t)
  (check "large output length" (string-length (get r 'stdout)) 200000))

;; 10. spawn failure returned as data
(let ([r (run-argv "definitely-not-a-binary-xyz" (list))])
  (check "spawn-fail ok" (get r 'ok) #f)
  (check "spawn-fail timed-out" (get r 'timed-out) #f))

;; 11. stderr captured alongside stdout
(let ([r (run-command "printf out; printf err 1>&2")])
  (check "stderr stdout" (get r 'stdout) "out")
  (check "stderr stderr" (get r 'stderr) "err"))

;; 12. stdin under a timeout still delivered
(let ([r (run-command "cat" (hash 'stdin "under-timeout\n" 'timeout-ms 5000))])
  (check "stdin+timeout" (get r 'stdout) "under-timeout\n"))

(if (= (unbox failures) 0)
  (displayln "\nAll checks passed.")
  (begin
    (displayln (string-append "\n" (to-string (unbox failures)) " check(s) failed."))
    (error "test failures")))
