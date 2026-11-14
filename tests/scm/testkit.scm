;;; tests/scm/testkit.scm — the shared assertion kit for Scheme tests.
;;;
;;; Backed by standard `(srfi 64)` (`test-assert`, `test-runner-current`,
;;; `test-runner-pass-count`, `test-runner-fail-count`) while preserving the
;;; `tk-reset!`/`tk-record!`/`tk-report!` contract used by the existing suites.

(import (scheme base)
        (srfi 64))

(define *tk-passed* 0)
(define *tk-failures* '())   ; newest first: (label actual expected)

(define (tk-reset!)
  (test-runner-current (test-runner-simple))
  (test-begin "testkit")
  (set! *tk-passed* 0)
  (set! *tk-failures* '()))

;; One verdict, whatever syntax sugared it. `ok` is the truthiness of the
;; check, `actual`/`expected` are kept for the failure diff report.
(define (tk-record! label ok actual expected)
  (if (not (test-runner-current))
      (begin
        (test-runner-current (test-runner-simple))
        (test-begin "testkit")))
  (test-assert label (if ok #t #f))
  (if ok
      (set! *tk-passed* (+ *tk-passed* 1))
      (set! *tk-failures*
            (cons (list label actual expected) *tk-failures*)))
  #t)

;; A named section, purely for the report's readability.
(define (tk-section name) name)

(define (tk-report! suite)
  (if (test-runner-current)
      (test-end "testkit"))
  (let ((n (length *tk-failures*)))
    (if (= n 0)
        (begin (display suite) (display ": all ")
               (display *tk-passed*) (display " checks passed") (newline))
        (begin
          (display suite) (display ": ") (display *tk-passed*)
          (display " passed, ") (display n) (display " FAILED") (newline)
          (for-each
           (lambda (f)
             (display "  FAIL ") (display (car f)) (newline)
             (display "    actual:   ") (write (cadr f)) (newline)
             (display "    expected: ") (write (caddr f)) (newline))
           (reverse *tk-failures*))
          (error (string-append suite ": failed checks") n)))))
