;;; tests/scm/testkit.scm — the shared assertion kit for Scheme tests.
;;;
;;; Unlike the domain tests (which raise on the first failure), this kit
;;; COLLECTS failures: a UI or gameplay suite has many independent checks,
;;; and a red suite should say everything it saw, not just its first
;;; surprise. `tk-report!` ends the file: it prints the tally and raises if
;;; anything failed, so a clean load is still the green light.
;;;
;;; One loader quirk shapes this file: `define-syntax` does not cross a
;;; file boundary here, but procedures do. So the sugar (tk-check/tk-assert)
;;; is defined in each suite as a two-line macro over `tk-record!`, and all
;;; the state and the reporting live here.

(define *tk-passed* 0)
(define *tk-failures* '())   ; newest first: (label actual expected)

(define (tk-reset!)
  (set! *tk-passed* 0)
  (set! *tk-failures* '()))

;; One verdict, whatever syntax sugared it. `ok` is the truthiness of the
;; check, `actual`/`expected` are kept for the report.
(define (tk-record! label ok actual expected)
  (if ok
      (set! *tk-passed* (+ *tk-passed* 1))
      (set! *tk-failures*
            (cons (list label actual expected) *tk-failures*)))
  #t)

;; A named section, purely for the report's readability.
(define (tk-section name) name)

(define (tk-report! suite)
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
          (error (string-append suite ": failed checks")
                 (length *tk-failures*))))))
