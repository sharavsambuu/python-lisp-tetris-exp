#!/usr/bin/env shs
;;; tests/scm/run-all.scm — the Scheme suites, orchestrated by Scheme itself.
;;;
;;;   SHS_PATH=scheme:tests/scm env/bin/shs run tests/scm/run-all.scm
;;;
;;; One interpreter, all four suites, each `(load ...)`ed in sequence and
;;; isolated by `guard` — a red suite is reported and the walk continues,
;;; and any failure at all ends the run with a raised error, so the exit
;;; code a CI wrapper sees is honest. The suites share one environment:
;;; that is safe because every module `(load ...)` is cached by path (a
;;; second load defines nothing again) and every suite rebuilds its own
;;; shell state (`host-reset!` + `boot!`) before its checks.
;;;
;;; The step budget: the interpreter charges each top-level form its own
;;; hang-detector budget (5M steps by default), and that raise is NOT a
;;; Scheme condition — a hang detector the program could `guard` away would
;;; be no detector at all. So under a bare `shs run` the walk stops at the
;;; first simulation-heavy form with LispBudgetError; the suites themselves
;;; are fine. Raising the ceiling is the embedding host's decision
;;; (`lisp.evaluator.STEPS_BUDGET`): the pytest bootstrap raises it to 50M
;;; (500M for this file's whole walk) before loading it, and a future
;;; `--budget` flag on the interpreter CLI would do the same job.

(import (scheme base)
        (rename (srfi 1) (map srfi-1:map) (for-each srfi-1:for-each)))

(define *ra-failures* '())

;; Load one suite; a raise is the suite's red light, caught here so the
;; remaining suites still get their say.
(define (ra-run! name file)
  (display "=== ") (display name) (display " ===") (newline)
  (guard (e (#t
             (display "  SUITE FAILED: ") (write e) (newline)
             (set! *ra-failures* (cons name *ra-failures*))
             #f))
    (load file)
    #t))

(ra-run! "domain"   "domain-tests.scm")
(ra-run! "gameplay" "gameplay-tests.scm")
(ra-run! "ui"       "ui-tests.scm")
(ra-run! "shell"    "shell-tests.scm")

(if (null? *ra-failures*)
    (display "run-all: all suites passed\n")
    (begin
      (display "run-all: FAILED suites:") 
      (for-each (lambda (name) (display " ") (display name))
                (reverse *ra-failures*))
      (newline)
      ;; A raise, not a quiet exit: the interpreter's error path is what
      ;; turns one of these into a non-zero process status.
      (error "run-all: failing suites" (length *ra-failures*))))
