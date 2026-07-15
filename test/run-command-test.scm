;;; run-command-test.scm - exercise the run-command library end to end.
;;;
;;; Run from the repository root:
;;;   steel test/run-command-test.scm
;;;
;;; Requires the steel-test package in ~/.steel/cogs (install with forge, or
;;; copy the package there). Exit code 0 means the suite passed.

(require "steel-test/test.scm")
(require "../run-command.scm")

(define (get r k) (hash-ref r k))

(deftest run-argv-success
  (let ([r (run-argv "echo" (list "hi"))])
    (is (= "hi\n" (get r 'stdout)))
    (is (= 0 (get r 'exit)))
    (is (= #t (get r 'ok)))
    (is (= #f (get r 'timed-out)))))

(deftest run-command-shell-form
  (let ([r (run-command "echo hello")])
    (is (= "hello\n" (get r 'stdout)))
    (is (= #t (get r 'ok)))))

(deftest exit-code-surfaced
  (let ([r (run-command "exit 3")])
    (is (= 3 (get r 'exit)))
    (is (= #f (get r 'ok)))
    (is (= #f (get r 'timed-out)))))

(deftest argv-no-word-splitting
  (let ([r (run-argv "printf" (list "%s" "a b*c"))])
    (is (= "a b*c" (get r 'stdout)))))

(deftest stdin-no-timeout
  (let ([r (run-command "cat" (hash 'stdin "piped\n"))])
    (is (= "piped\n" (get r 'stdout)))))

(deftest env-passed
  (let ([r (run-command "printf %s \"$FOO\"" (hash 'env (hash "FOO" "bar")))])
    (is (= "bar" (get r 'stdout)))))

(deftest timeout-fires
  (let ([r (run-command "sleep 5" (hash 'timeout-ms 200))])
    (is (= #t (get r 'timed-out)))
    (is (= #f (get r 'ok)))))

;; A genuine exit 124 under a generous timeout must not be reported as a timeout.
(deftest exit-124-not-timeout
  (let ([r (run-command "exit 124" (hash 'timeout-ms 5000))])
    (is (= 124 (get r 'exit)))
    (is (= #f (get r 'timed-out)))))

(deftest large-output-no-deadlock
  (let ([r (run-command "yes | head -100000")])
    (is (= #t (get r 'ok)))
    (is (= 200000 (string-length (get r 'stdout))))))

(deftest spawn-failure-as-data
  (let ([r (run-argv "definitely-not-a-binary-xyz" (list))])
    (is (= #f (get r 'ok)))
    (is (= #f (get r 'timed-out)))))

(deftest stderr-captured
  (let ([r (run-command "printf out; printf err 1>&2")])
    (is (= "out" (get r 'stdout)))
    (is (= "err" (get r 'stderr)))))

(deftest stdin-under-timeout
  (let ([r (run-command "cat" (hash 'stdin "under-timeout\n" 'timeout-ms 5000))])
    (is (= "under-timeout\n" (get r 'stdout)))))

(run-tests!)
